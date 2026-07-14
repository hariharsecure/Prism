import AVFAudio
import Foundation
import PrismAudio
import PrismCore
import os

// MARK: - Pattern model (Codable — save/load)

public struct BeatStep: Codable, Sendable, Hashable {
    public var on: Bool
    public var velocity: Float   // 0…1
    public init(on: Bool = false, velocity: Float = 1.0) { self.on = on; self.velocity = velocity }
}

public struct BeatTrack: Codable, Sendable, Hashable {
    public var name: String
    /// Library sound id (kick/snare/hat/clap/perc) this track triggers.
    public var soundID: String
    public var steps: [BeatStep]
    public var muted: Bool
    public var gain: Float
    public init(name: String, soundID: String, steps: [BeatStep], muted: Bool = false, gain: Float = 1.0) {
        self.name = name; self.soundID = soundID; self.steps = steps; self.muted = muted; self.gain = gain
    }
}

public struct BeatPattern: Codable, Sendable, Hashable {
    public var bpm: Double
    public var swing: Double      // 0…0.6 — delays odd 16ths
    public var stepCount: Int     // typically 16
    public var tracks: [BeatTrack]

    public init(bpm: Double = 120, swing: Double = 0, stepCount: Int = 16, tracks: [BeatTrack] = []) {
        self.bpm = bpm; self.swing = swing; self.stepCount = stepCount; self.tracks = tracks
    }

    // A5: validated accessors. The raw `var`s stay public/mutable (Codable +
    // UI-bindable), but ALL timing math goes through these clamps so a stray
    // bpm=0 (÷0 → ∞), a negative stepCount, or swing≥1 (steps overtake the next
    // 16th and collide) can never poison the live scheduler.
    /// bpm clamped to a musically-sane, division-safe range.
    public var safeBPM: Double { min(999, max(20, bpm.isFinite ? bpm : 120)) }
    /// swing clamped to [0, 0.75] — beyond that an odd 16th would reach/overtake
    /// the following even 16th.
    public var safeSwing: Double { min(0.75, max(0, swing.isFinite ? swing : 0)) }
    /// stepCount clamped to [4, 64] AND snapped to a whole number of quarter-note
    /// beats (a multiple of `BeatSequencer.sixteenthsPerBeat` = 4).
    ///
    /// F2: the visual `BeatClock` counts *integer* quarter-note beats per bar
    /// (`beatsPerBar`), so a loop whose length is not a whole number of beats —
    /// e.g. 14 sixteenths = 3.5 beats — makes `BeatClock.barPhase`/`barIndex`
    /// (which use `beatsPerBar`) disagree with the sequencer's real loop and
    /// `onBar` (which use `g % stepCount`). Snapping the loop length to a multiple
    /// of 4 keeps the audio loop and the visual bar clock in lock-step for every
    /// value: `barSeconds == beatsPerBar · beatSeconds == stepCount · stepSeconds`.
    public var safeStepCount: Int {
        let per = BeatSequencer.sixteenthsPerBeat            // 4 sixteenths / beat
        let clamped = min(64, max(per, stepCount))
        // Round to the nearest whole beat (ties → up), then re-clamp to [4, 64].
        let snapped = ((clamped + per / 2) / per) * per
        return min(64, max(per, snapped))
    }

    /// Sixteenth-note duration in seconds.
    public var stepSeconds: Double { 60.0 / safeBPM / 4.0 }
    /// One bar (stepCount sixteenths) in seconds.
    public var barSeconds: Double { stepSeconds * Double(safeStepCount) }

    /// Onset time (seconds) of `step` within `bar`, including swing.
    public func onsetSeconds(step: Int, bar: Int) -> Double {
        let swingOffset = (step % 2 == 1) ? safeSwing * stepSeconds : 0
        return Double(bar) * barSeconds + Double(step) * stepSeconds + swingOffset
    }

    /// Absolute onset (seconds since pattern start) of the *global* step index
    /// `g = bar*stepCount + step`. Strictly increasing in `g` (given the swing
    /// clamp), which is exactly what the live lookahead scheduler relies on to
    /// fire each step once, at its exact time, without collisions (A5).
    public func absoluteOnsetSeconds(globalStep g: Int) -> Double {
        let sc = safeStepCount
        let bar = g >= 0 ? g / sc : 0
        let step = g >= 0 ? g % sc : 0
        return onsetSeconds(step: step, bar: bar)
    }

    public func makeCodableData() throws -> Data { try JSONEncoder().encodePretty(self) }
    public static func fromData(_ data: Data) throws -> BeatPattern { try JSONDecoder().decode(BeatPattern.self, from: data) }
}

/// Pure, testable lookahead-scheduler cursor (A5). The live clock keeps one of
/// these; every timer wake it calls `drain(pattern:upTo:)` with the horizon it
/// wants scheduled (elapsed + lookahead). Each global step is emitted exactly
/// once, at its exact swung onset — the audio layer then schedules the sample at
/// that host time, so timer jitter never moves a hit (the old half-step polling
/// window fired swung steps a whole tick late and could collide).
public struct BeatScheduleCursor: Sendable {
    public private(set) var nextGlobalStep = 0
    public init() {}

    /// One scheduled onset.
    public struct Onset: Sendable, Equatable {
        public let globalStep: Int
        public let step: Int
        public let bar: Int
        public let onsetSeconds: Double
    }

    /// Emit every not-yet-emitted step whose onset is < `horizonSeconds`,
    /// advancing the cursor. Deterministic and allocation-bounded.
    public mutating func drain(pattern: BeatPattern, upTo horizonSeconds: Double) -> [Onset] {
        let sc = pattern.safeStepCount
        var out: [Onset] = []
        // Cap the batch so a huge horizon (or a paused clock resuming) can't spin
        // unbounded; the caller re-drains on the next wake.
        var guardCount = 0
        while guardCount < sc * 64 {
            let g = nextGlobalStep
            let onset = pattern.absoluteOnsetSeconds(globalStep: g)
            if onset >= horizonSeconds { break }
            out.append(Onset(globalStep: g, step: g % sc, bar: g / sc, onsetSeconds: onset))
            nextGlobalStep += 1
            guardCount += 1
        }
        return out
    }
}

// MARK: - Sequencer

/// 16-step × N-track drum sequencer. Preloads each track's sample and plays the
/// pattern into an `AudioMixer` channel via a `SamplePlaybackEngine`. Supports
/// real-time playback (`start`/`stop`) and a headless offline render used for
/// verification and bounce.
public final class BeatSequencer: @unchecked Sendable {
    public enum SequencerError: Error, CustomStringConvertible {
        case sampleMissing(String)
        public var description: String {
            switch self { case .sampleMissing(let id): return "track sample '\(id)' could not be loaded" }
        }
    }

    public let channelID: SourceID
    public let engine: SamplePlaybackEngine
    private let library: SoundLibrary?
    private let log = EngineLog.logger("sound.beats")

    private let state = OSAllocatedUnfairLock(initialState: BeatPattern())
    // A7: read on the sequencer clock thread (`fireStep`) while load/register
    // mutate it — guard like `Soundboard.buffers`.
    private let trackBuffers = OSAllocatedUnfairLock<[String: AVAudioPCMBuffer]>(initialState: [:])
    private var timer: DispatchSourceTimer?

    // MARK: Beat clock (visual-sync primitive)
    // House-time (seconds) of beat 0, captured when `play()` starts. `nil` while
    // stopped ⇒ `beatClock` reports a stopped clock (phase 0, no beats). Stable
    // across bars so `BeatClock` phase is continuous.
    private let anchorHostSeconds = OSAllocatedUnfairLock<Double?>(initialState: nil)
    // onBeat/onBar are set from the UI thread and read on the clock queue; the
    // lock keeps that handoff data-race-free (Swift-6 @Sendable).
    private let beatCallbacks = OSAllocatedUnfairLock<
        (onBeat: (@Sendable (Int) -> Void)?, onBar: (@Sendable (Int) -> Void)?)
    >(initialState: (nil, nil))
    // F1: bumped by every `stopClock()`/`play()`. A beat/bar callback is scheduled
    // (via `queue.asyncAfter`) at its onset's playback host-time, which can be up
    // to `lookahead` (~50 ms) in the future; if the clock stops in that window the
    // still-pending closure must NOT fire. Each closure captures the generation it
    // was scheduled under and no-ops once the generation moves on — so stop() (and
    // a fast stop→play restart) cleanly cancels pending callbacks.
    private let runGeneration = OSAllocatedUnfairLock(initialState: 0)

    /// Sixteenths per quarter-note beat — the sequencer grid is 16ths, a beat is a quarter.
    public static let sixteenthsPerBeat = 4

    public var pattern: BeatPattern {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    /// Fired on each quarter-note downbeat while the live clock runs, with the
    /// monotonic beat index (0-based since `play()`). Invoked on the sequencer's
    /// clock queue. Swing does not move downbeats, so this is swing-correct.
    public var onBeat: (@Sendable (Int) -> Void)? {
        get { beatCallbacks.withLock { $0.onBeat } }
        set { beatCallbacks.withLock { $0.onBeat = newValue } }
    }
    /// Fired on the first beat of each bar while running, with the monotonic bar index.
    public var onBar: (@Sendable (Int) -> Void)? {
        get { beatCallbacks.withLock { $0.onBar } }
        set { beatCallbacks.withLock { $0.onBar = newValue } }
    }

    /// A snapshot tempo clock consumers can read phase from without importing the
    /// sequencer. Reflects the current bpm/beats-per-bar and the play anchor; when
    /// stopped it is `.stopped` (phase 0, no beats). Swing is intentionally not
    /// carried — it never shifts a quarter-note beat.
    public var beatClock: BeatClock {
        let p = pattern
        // F2: safeStepCount is snapped to a multiple of sixteenthsPerBeat, so this
        // divide is EXACT — the resulting bar (beatsPerBar quarter-notes) is the
        // same length as the sequencer's real loop and `onBar` (g % stepCount).
        let bpb = max(1, p.safeStepCount / BeatSequencer.sixteenthsPerBeat)
        guard let anchor = anchorHostSeconds.withLock({ $0 }) else { return .stopped }
        return BeatClock(bpm: p.safeBPM, beatsPerBar: bpb, anchorHostSeconds: anchor)
    }

    /// Position within the current beat (0→1) at house-now. 0 when stopped.
    public func beatPhase() -> Double { beatClock.beatPhase(atHostSeconds: HouseClock.nowSeconds()) }
    /// Position within the current bar (0→1) at house-now. 0 when stopped.
    public func barPhase() -> Double { beatClock.barPhase(atHostSeconds: HouseClock.nowSeconds()) }

    /// Pure classification of a global 16th-step: if it lands on a quarter-note
    /// downbeat, its monotonic `beatIndex`/`barIndex` and whether it's the bar's
    /// first beat; otherwise `nil`. Single source of truth shared by the live
    /// scheduler (`onBeat`/`onBar`) and the tests, so they can never disagree.
    public static func beatInfo(forGlobalStep g: Int, stepCount: Int)
        -> (beatIndex: Int, barIndex: Int, firstBeatOfBar: Bool)? {
        guard g >= 0, g % sixteenthsPerBeat == 0 else { return nil }
        let sc = max(1, stepCount)
        return (beatIndex: g / sixteenthsPerBeat, barIndex: g / sc, firstBeatOfBar: g % sc == 0)
    }

    /// Pure F1 mapping: the host time (mach ticks) at which the onset `onsetSeconds`
    /// (seconds since the play anchor) occurs, given the run's `startHostTicks`
    /// epoch. This is the EXACT host time the audio sample is scheduled at, and now
    /// also the time `onBeat`/`onBar` fire — so the callback lands *with* the sound
    /// instead of ~`lookahead` (50 ms) early at drain time. Testable in isolation.
    public static func onsetHostTime(startHostTicks: UInt64, onsetSeconds: Double) -> UInt64 {
        startHostTicks &+ AVAudioTime.hostTime(forSeconds: onsetSeconds)
    }

    /// Convert an AVAudioTime host-time (mach ticks, e.g. from `onsetHostTime`) to
    /// the `DispatchTime` deadline at the same instant, so a beat callback can be
    /// `asyncAfter`-scheduled to fire exactly when the audio plays (F1). Both the
    /// host clock and DispatchTime derive from the same monotonic mach clock.
    static func dispatchDeadline(forHostTime hostTime: UInt64) -> DispatchTime {
        let ns = AVAudioTime.seconds(forHostTime: hostTime) * 1_000_000_000
        return DispatchTime(uptimeNanoseconds: ns > 0 ? UInt64(ns) : 0)
    }

    public init(mixer: AudioMixer, library: SoundLibrary?,
                channelID: SourceID = SourceID("sound.beats"), voiceCount: Int = 12) throws {
        self.channelID = channelID
        self.library = library
        self.engine = try SamplePlaybackEngine(sourceID: channelID, voiceCount: voiceCount)
        // A8: drop the dead `format:` arg (AudioMixer ignores it, converting lazily).
        let channel = try mixer.addChannel(id: channelID)
        engine.sinkChannel = channel
    }

    /// Load a pattern and preload every track's sample buffer (off the RT path).
    public func load(pattern: BeatPattern) throws {
        let existing = trackBuffers.withLock { $0 }
        var bufs: [String: AVAudioPCMBuffer] = [:]
        for track in pattern.tracks where bufs[track.soundID] == nil {
            if let buf = existing[track.soundID] { bufs[track.soundID] = buf; continue }
            guard let url = library?.url(forID: track.soundID) else { throw SequencerError.sampleMissing(track.soundID) }
            do { bufs[track.soundID] = try engine.loadFile(url) }
            catch { throw SequencerError.sampleMissing(track.soundID) }
        }
        let loaded = bufs
        trackBuffers.withLock { $0 = loaded }
        self.pattern = pattern
    }

    /// Register an already-decoded buffer for a track sound id (test / synth).
    public func registerBuffer(id: String, buffer: AVAudioPCMBuffer) { trackBuffers.withLock { $0[id] = buffer } }

    // MARK: Live playback

    public func startLive() throws { try engine.startLive() }

    /// Start real-time step playback (loops the pattern). Requires `startLive()`.
    ///
    /// A5: a lookahead scheduler, not a polling clock. A coarse timer wakes every
    /// ~15 ms and asks the cursor for every onset due within the next 50 ms; each
    /// onset is handed to the audio layer as an exact host-time `AVAudioTime`, so
    /// the AVAudioPlayerNode plays the sample at that sample — timer jitter and
    /// the old half-step grid can no longer make a swung step fire a tick late or
    /// collide with its neighbour.
    public func play(queue: DispatchQueue = DispatchQueue(label: "sound.beats.clock", qos: .userInteractive)) {
        stopClock()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let wakeNanos = 15_000_000            // 15 ms coarse wake
        let lookahead = 0.05                  // schedule 50 ms ahead (> wake interval)
        t.schedule(deadline: .now(), repeating: .nanoseconds(wakeNanos), leeway: .milliseconds(2))
        let startHostTicks = mach_absolute_time()
        let startUptime = Double(DispatchTime.now().uptimeNanoseconds)
        // Anchor the beat clock to house-now (same host-clock epoch as the audio
        // schedule below), stable for the whole run so BeatClock phase is continuous.
        anchorHostSeconds.withLock { $0 = HouseClock.nowSeconds() }
        // F1: tag this run so callbacks scheduled ahead of time are cancelled if the
        // clock stops before their onset (stopClock() bumps the generation).
        let gen = runGeneration.withLock { $0 }
        let cursor = OSAllocatedUnfairLock(initialState: BeatScheduleCursor())
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let p = self.pattern
            let elapsed = (Double(DispatchTime.now().uptimeNanoseconds) - startUptime) / 1_000_000_000
            let onsets = cursor.withLock { $0.drain(pattern: p, upTo: elapsed + lookahead) }
            for onset in onsets {
                let whenHost = BeatSequencer.onsetHostTime(startHostTicks: startHostTicks,
                                                           onsetSeconds: onset.onsetSeconds)
                self.fireStep(onset.step, pattern: p, at: AVAudioTime(hostTime: whenHost))
                // F1: the cursor drains each onset up to `lookahead` (~50 ms) BEFORE
                // its actual host time, so firing onBeat/onBar inline here led the
                // audio. Instead schedule the callback on the clock queue to fire at
                // the SAME `whenHost` the sample plays. Driven off the same once-per-
                // step cursor ⇒ exactly-once per beat; monotonically increasing
                // deadlines on the serial queue ⇒ in-order delivery.
                guard let bi = BeatSequencer.beatInfo(forGlobalStep: onset.globalStep,
                                                      stepCount: p.safeStepCount) else { continue }
                queue.asyncAfter(deadline: BeatSequencer.dispatchDeadline(forHostTime: whenHost)) { [weak self] in
                    guard let self, self.runGeneration.withLock({ $0 }) == gen else { return }
                    let cb = self.beatCallbacks.withLock { $0 }
                    cb.onBeat?(bi.beatIndex)
                    if bi.firstBeatOfBar { cb.onBar?(bi.barIndex) }
                }
            }
        }
        timer = t
        t.resume()
    }

    private func fireStep(_ step: Int, pattern p: BeatPattern, at when: AVAudioTime? = nil) {
        let bufs = trackBuffers.withLock { $0 }
        for track in p.tracks where !track.muted {
            guard step < track.steps.count, track.steps[step].on,
                  let buf = bufs[track.soundID] else { continue }
            engine.play(buf, at: when, loop: false, volume: track.steps[step].velocity * track.gain)
        }
    }

    private func stopClock() {
        timer?.cancel(); timer = nil
        // F1: invalidate the current run so any beat/bar callback already scheduled
        // (queue.asyncAfter) but still pending does NOT fire after we stop — its
        // captured generation no longer matches. Also covers a fast stop→play.
        runGeneration.withLock { $0 &+= 1 }
        // Drop the anchor so `beatClock` reports a stopped clock (phase 0, no beats).
        anchorHostSeconds.withLock { $0 = nil }
    }

    public func stop() { stopClock(); engine.stop() }

    // MARK: Offline render (verification / bounce)

    public struct BeatRenderResult: Sendable {
        public let blockPeaks: [Float]     // master peak per rendered block
        public let onsetBlocks: [Int]      // block index of each active step onset
        public let blockFrames: Int
        public let sampleRate: Double
    }

    /// Render `bars` of the loaded pattern through `mixer` in manual mode (both
    /// this engine and the mixer must already be in manual-render mode, and the
    /// mixer must contain this sequencer's channel). Returns master peak per
    /// block plus the block index of each on-step onset for verification.
    public func renderOffline(bars: Int, mixer: AudioMixer,
                              blockFrames: AVAudioFrameCount = 256) throws -> BeatRenderResult {
        let p = pattern
        let sr = SamplePlaybackEngine.internalFormat.sampleRate
        let totalFrames = Int(p.barSeconds * Double(bars) * sr)
        var peaks: [Float] = []
        var onsetBlocks: [Int] = []

        // Precompute onset sample positions of active steps.
        var onsets: [(sample: Int, step: Int, bar: Int)] = []
        for bar in 0..<bars {
            for step in 0..<p.stepCount {
                let active = p.tracks.contains { !$0.muted && step < $0.steps.count && $0.steps[step].on }
                if active { onsets.append((Int(p.onsetSeconds(step: step, bar: bar) * sr), step, bar)) }
            }
        }
        var onsetIdx = 0
        var cursor = 0
        let block = Int(blockFrames)
        while cursor < totalFrames {
            // Fire any onsets that begin within this block.
            while onsetIdx < onsets.count && onsets[onsetIdx].sample < cursor + block {
                fireStep(onsets[onsetIdx].step, pattern: p)
                onsetBlocks.append(peaks.count)
                onsetIdx += 1
            }
            try engine.render(frameCount: blockFrames)           // renders + ingests into the channel
            _ = try mixer.renderManually(frameCount: blockFrames) // drains channel → master
            // Channel peak is updated every render block (unlike the master tap,
            // which flushes on its own buffer granularity) — per-block accurate.
            peaks.append(engine.sinkChannel?.peakLevel().linear ?? mixer.masterPeakLevel().linear)
            cursor += block
        }
        return BeatRenderResult(blockPeaks: peaks, onsetBlocks: onsetBlocks,
                                blockFrames: block, sampleRate: sr)
    }

    // MARK: Convenience patterns

    /// A classic 4/4 house-ish starter pattern using the given track sound ids.
    public static func basicPattern(kick: String, snare: String, hat: String,
                                    bpm: Double = 120) -> BeatPattern {
        func steps(_ ons: [Int], vel: Float = 1) -> [BeatStep] {
            (0..<16).map { BeatStep(on: ons.contains($0), velocity: vel) }
        }
        return BeatPattern(bpm: bpm, swing: 0, stepCount: 16, tracks: [
            BeatTrack(name: "Kick", soundID: kick, steps: steps([0, 4, 8, 12])),
            BeatTrack(name: "Snare", soundID: snare, steps: steps([4, 12])),
            BeatTrack(name: "Hat", soundID: hat, steps: steps([0, 2, 4, 6, 8, 10, 12, 14], vel: 0.7)),
        ])
    }
}
