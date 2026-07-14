import AVFAudio
import Foundation
import PrismAudio
import PrismCore
import os

/// Background-music loop player: gapless looping of a loopable sound, crossfade
/// between beds, and volume — into its OWN `AudioMixer` channel so the existing
/// `AudioMixer.setDucking(target:key:)` can dip it under the mic.
///
/// Uses two voices of a `SamplePlaybackEngine` (A/B) so a crossfade can overlap
/// the outgoing and incoming bed.
public final class MusicBed: @unchecked Sendable {
    public enum MusicBedError: Error, CustomStringConvertible {
        case notLoaded(String)
        public var description: String {
            switch self { case .notLoaded(let id): return "bed '\(id)' is not loaded" }
        }
    }

    /// Default decoded-bed cache budget (128 MiB): a hard safety ceiling above
    /// the count cap for pathologically long beds.
    public static let defaultCacheBudgetBytes = 128 * 1024 * 1024
    /// Default resident-bed count cap. A MusicBed only ever needs the ACTIVE bed
    /// plus (during a crossfade) the incoming TARGET bed — the pair it is really
    /// playing. Auditioning many beds therefore does not retain them all; a
    /// re-selected bed re-decodes from the library on demand (preload-on-miss).
    public static let defaultCacheCountCap = 2

    public let channelID: SourceID
    public let engine: SamplePlaybackEngine
    private let library: SoundLibrary?
    private let log = EngineLog.logger("sound.musicbed")

    private let stateLock = OSAllocatedUnfairLock(initialState: State())
    private struct State { var activeVoice = 0; var volume: Float = 0.8 }
    // A7: `beds` is mutated by load/register (control thread) while play/crossfade
    // read it — all access is under this lock (mirrors `Soundboard.cache`). It is
    // a bounded LRU (`LRUBufferCache`), NOT an unbounded dict, so auditioning many
    // beds cannot retain them all: it holds at most the active/crossfade pair. The
    // engine voices retain the buffers they are actually playing independently of
    // this cache, so eviction never interrupts gapless playback or a crossfade.
    private let beds: OSAllocatedUnfairLock<LRUBufferCache>
    private var fadeTimer: DispatchSourceTimer?

    public init(mixer: AudioMixer, library: SoundLibrary?,
                channelID: SourceID = SourceID("sound.musicbed"),
                cacheBudgetBytes: Int = MusicBed.defaultCacheBudgetBytes,
                cacheCountCap: Int = MusicBed.defaultCacheCountCap) throws {
        self.channelID = channelID
        self.library = library
        self.beds = OSAllocatedUnfairLock(
            initialState: LRUBufferCache(budgetBytes: cacheBudgetBytes, countCap: cacheCountCap))
        self.engine = try SamplePlaybackEngine(sourceID: channelID, voiceCount: 2)
        // A8: `AudioMixer.addChannel(format:)` is a dead param (it always uses the
        // mixer's internalFormat and builds converters lazily on ingest), so we
        // drop the misleading argument rather than imply it's honored.
        let channel = try mixer.addChannel(id: channelID)
        engine.sinkChannel = channel
    }

    /// Approximate resident decoded-bed PCM bytes. Bounded to the active/crossfade
    /// pair (see `defaultCacheCountCap`) — NOT the number of beds ever auditioned.
    public var residentBedBytes: Int { beds.withLock { $0.totalBytes } }
    /// Number of decoded beds currently resident (bounded, not cumulative).
    public var residentBedCount: Int { beds.withLock { $0.count } }

    /// Master bed volume (0…1).
    public var volume: Float {
        get { stateLock.withLock { $0.volume } }
        set {
            let v = max(0, min(1, newValue))
            let voice = stateLock.withLock { st -> Int in st.volume = v; return st.activeVoice }
            engine.setVoiceVolume(v, onVoice: voice)
        }
    }

    // MARK: Loading

    @discardableResult
    public func preload(id: String) throws -> AVAudioPCMBuffer {
        guard let url = library?.url(forID: id) else { throw MusicBedError.notLoaded(id) }
        let buf = try engine.loadFile(url)
        beds.withLock { _ = $0.insert(id, buffer: buf) }
        return buf
    }

    public func register(id: String, buffer: AVAudioPCMBuffer) {
        beds.withLock { _ = $0.insert(id, buffer: buffer) }
    }
    /// Fetch a resident bed, marking it most-recently-used. `nil` if it was never
    /// loaded or has been evicted under the cache bound — use `preload`/`play`
    /// (which re-decode on miss) to bring it back.
    public func buffer(id: String) -> AVAudioPCMBuffer? { beds.withLock { $0.get(id) } }

    /// Resolve `id` to a decoded buffer: cache hit (marked MRU) or re-decode from
    /// the library on a miss (preload-on-miss). Throws `.notLoaded` only when no
    /// library entry resolves the id at all.
    private func resolve(_ id: String) throws -> AVAudioPCMBuffer {
        if let hit = beds.withLock({ $0.get(id) }) { return hit }
        return try preload(id: id)
    }

    // MARK: Lifecycle

    public func startLive() throws { try engine.startLive() }
    public func startManual(maximumFrameCount: AVAudioFrameCount = 4096) throws {
        try engine.startManual(maximumFrameCount: maximumFrameCount)
    }
    public func stop() { fadeTimer?.cancel(); fadeTimer = nil; engine.stop() }

    // MARK: Playback

    /// Start (or hard-switch to) a bed, gaplessly looped, on the active voice.
    /// A bed evicted under the cache bound is transparently re-decoded here.
    public func play(id: String) throws {
        playBuffer(try resolve(id))
    }

    public func playBuffer(_ buffer: AVAudioPCMBuffer) {
        let (voice, vol) = stateLock.withLock { ($0.activeVoice, $0.volume) }
        engine.play(buffer, onVoice: voice, loop: true, volume: vol)
    }

    /// Crossfade from the current bed to `id` over `duration` seconds.
    public func crossfade(toID id: String, duration: TimeInterval = 2.0) throws {
        crossfade(to: try resolve(id), duration: duration)
    }

    /// Crossfade to a new bed buffer over `duration` seconds (equal-ish power).
    public func crossfade(to buffer: AVAudioPCMBuffer, duration: TimeInterval = 2.0) {
        fadeTimer?.cancel()
        let (fromVoice, target) = stateLock.withLock { st -> (Int, Float) in (st.activeVoice, st.volume) }
        let toVoice = 1 - fromVoice
        engine.play(buffer, onVoice: toVoice, loop: true, volume: 0)

        let steps = max(1, Int(duration / 0.02))
        var i = 0
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "sound.musicbed.fade"))
        t.schedule(deadline: .now(), repeating: .milliseconds(20))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            i += 1
            let p = Float(i) / Float(steps)
            self.engine.setVoiceVolume(target * min(1, p), onVoice: toVoice)
            self.engine.setVoiceVolume(target * max(0, 1 - p), onVoice: fromVoice)
            if i >= steps {
                self.engine.stopVoice(fromVoice)
                self.stateLock.withLock { $0.activeVoice = toVoice }
                t.cancel()
            }
        }
        fadeTimer = t
        t.resume()
    }

    /// Render `frames` in manual mode (for verification); returns the block.
    @discardableResult
    public func render(frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        try engine.render(frameCount: frameCount)
    }

    // MARK: Synthesized beds (no files needed)

    /// A seamless chord loop in engine format (48 kHz stereo) — a gapless bed for
    /// tests or a default music bed.
    ///
    /// A1: a length that is an integer number of *fundamental* periods does NOT
    /// make the loop sample-continuous — the tempered third/fifth/octave partials
    /// (non-integer frequency ratios) don't complete whole cycles in that span, so
    /// last→first jumps. We therefore synthesize a slightly-long buffer and run a
    /// real equal-power loop crossfade (`loopify`) so the cyclic boundary is
    /// continuous regardless of the intervals' tuning.
    public static func synthesizeChordBed(rootMidi: Int = 48, minor: Bool = false,
                                          approxSeconds: Double = 4.0) -> AVAudioPCMBuffer {
        let sr = 48_000.0
        let frames = max(1, Int((approxSeconds * sr).rounded()))
        let intervals = minor ? [0, 3, 7, 12] : [0, 4, 7, 12]
        var chL = [Float](repeating: 0, count: frames)
        var chR = [Float](repeating: 0, count: frames)
        for k in 0..<frames {
            let t = Double(k) / sr
            var s = 0.0
            for iv in intervals {
                let hz = DSP.midiToHz(Double(rootMidi + iv))
                s += sin(2 * .pi * hz * t)
            }
            let v = Float(s / Double(intervals.count)) * 0.6
            chL[k] = v
            chR[k] = v
        }
        // Real loop crossfade → sample-continuous seam for any interval tuning.
        let looped = loopify([chL, chR], sampleRate: Int(sr))
        let outN = looped.first?.count ?? frames
        let buffer = AVAudioPCMBuffer(pcmFormat: SamplePlaybackEngine.internalFormat,
                                      frameCapacity: AVAudioFrameCount(outN))!
        buffer.frameLength = AVAudioFrameCount(outN)
        let L = buffer.floatChannelData![0]
        let R = buffer.floatChannelData![1]
        for k in 0..<outN { L[k] = looped[0][k]; R[k] = looped[1][k] }
        return buffer
    }
}
