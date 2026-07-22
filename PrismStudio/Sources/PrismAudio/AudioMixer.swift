import AVFAudio
import CoreMedia
import Foundation
import PrismCore
import os

/// AVAudioEngine-based N-channel program mixer (DESIGN.md §2.4, §3.3).
///
/// Graph:
/// ```
/// MixerChannel.sourceNode ─┐
/// MixerChannel.sourceNode ─┼→ masterBus (AVAudioMixerNode, tapped) → mainMixer → output
/// MixerChannel.sourceNode ─┘         │
///                                    └── onMasterMix: interleaved CMSampleBuffers, house PTS
/// ```
/// - Internal format: 48 kHz stereo Float32 (deinterleaved); inputs in other
///   PCM formats are converted per channel on ingest.
/// - The **master tap** on `masterBus` is the program feed for recorder/stream:
///   interleaved Float32 `CMSampleBuffer`s stamped in house time (host clock).
/// - **Monitoring** (mix → default output device) rides `mainMixer.outputVolume`,
///   so toggling it never disturbs the program feed. Off by default.
/// - Two run modes: `start()` (live, opens the output device — TCC/device side
///   effects) and `startManualRendering()` + `renderManually(frameCount:)`
///   (headless, no hardware; used by `AudioMixerSelfCheck`).
public final class AudioMixer: @unchecked Sendable {
    // MARK: Configuration

    public struct Configuration: Sendable {
        /// Internal mix sample rate.
        public var sampleRate: Double = 48_000
        /// Internal mix channel count.
        public var channelCount: AVAudioChannelCount = 2
        /// Per-channel ring depth in seconds (drop-oldest beyond this).
        public var ringSeconds: Double = 0.5
        /// Master tap granularity in frames.
        public var tapBufferFrames: AVAudioFrameCount = 1024
        /// Maximum silence synthesized to place a channel's first packet in the
        /// future. The actual lead is also limited by that channel's fixed ring.
        public var maximumInitialAlignmentSeconds: Double = 1.0

        public init() {}

        /// Re-applies safe clamps so an out-of-range field can never reach graph
        /// construction. In particular `sampleRate = 0` makes
        /// `AVAudioFormat(standardFormatWithSampleRate:channels:)` return `nil`
        /// and the mixer's `init` used to abort (`preconditionFailure`,
        /// exit 134); a non-finite `ringSeconds` would crash `Int(_:)` in
        /// `addChannel`. Invalid values fall back to the documented defaults;
        /// every valid configuration passes through unchanged.
        func normalized() -> Configuration {
            var c = self
            c.sampleRate = (sampleRate.isFinite && sampleRate > 0) ? sampleRate : 48_000
            c.channelCount = max(channelCount, 1)
            c.ringSeconds = (ringSeconds.isFinite && ringSeconds > 0) ? ringSeconds : 0.5
            c.tapBufferFrames = max(tapBufferFrames, 1)
            c.maximumInitialAlignmentSeconds = maximumInitialAlignmentSeconds.isFinite
                ? max(maximumInitialAlignmentSeconds, 0) : 1.0
            return c
        }
    }

    /// Where the master-mix packets claim to come from.
    public static let masterSourceID = SourceID("mixer.master")

    public let configuration: Configuration
    /// The mixer's internal processing format (48 kHz stereo float, deinterleaved).
    public let internalFormat: AVAudioFormat

    /// Program feed: interleaved Float32 CMSampleBuffers with house-time PTS.
    /// Called on the engine's tap-delivery thread. Set before `start()`.
    public var onMasterMix: ((AudioPacket) -> Void)?

    /// Route the mix to the engine output (default output device in live mode).
    /// Off by default so a headless mixer makes no sound.
    public var isMonitoringEnabled: Bool {
        get { engine.mainMixerNode.outputVolume > 0 }
        set { engine.mainMixerNode.outputVolume = newValue ? 1 : 0 }
    }

    /// Master peak since the previous call (read-and-reset), post-channel-faders,
    /// pre-monitor-volume.
    public func masterPeakLevel() -> AudioLevel {
        AudioLevel(linear: masterPeak.withLock { p in
            defer { p = 0 }
            return p
        })
    }

    /// Attach (or detach) a BS.1770 loudness meter fed from the master tap.
    /// Additive to the existing peak metering / `onMasterMix` — set before
    /// `start()`; the tap feeds it every callback.
    public func setLoudnessMeter(_ meter: LoudnessMeter?) {
        masterLoudness.withLock { $0 = meter }
    }

    /// The attached loudness meter, if any (to read its `measurement`).
    public var loudnessMeter: LoudnessMeter? { masterLoudness.withLock { $0 } }

    /// Sidechain ducking: attenuate `target`'s output when `key`'s level
    /// crosses `config.thresholdDB`, with attack/release smoothing. Both
    /// channels must already exist. Re-calling replaces the target's ducker;
    /// `clearDucking(target:)` removes it.
    public func setDucking(target: SourceID, key: SourceID, config: DuckingConfig) throws {
        guard let targetChannel = channel(id: target) else {
            throw PrismAudioError.invalidState("ducking target \(target) not found")
        }
        guard let keyChannel = channel(id: key) else {
            throw PrismAudioError.invalidState("ducking key \(key) not found")
        }
        let ducker = Ducker(config: config, keyLevel: keyChannel.sidechainLevel,
                            sampleRate: configuration.sampleRate)
        targetChannel.setSidechainDucker(ducker)
        duckingRules.withLock { $0[target] = key }
        log.info("ducking: \(target.raw) ducked by \(key.raw)")
    }

    /// Remove sidechain ducking from `target`.
    public func clearDucking(target: SourceID) {
        channel(id: target)?.setSidechainDucker(nil)
        duckingRules.withLock { _ = $0.removeValue(forKey: target) }
    }

    // MARK: State

    private let engine = AVAudioEngine()
    private let masterBus = AVAudioMixerNode()
    private let channelsLock = OSAllocatedUnfairLock<[SourceID: MixerChannel]>(initialState: [:])
    /// Active ducking rules, `target → key` (control-thread bookkeeping so
    /// `removeChannel` can tear a rule down when either side disappears).
    private let duckingRules = OSAllocatedUnfairLock<[SourceID: SourceID]>(initialState: [:])
    private let soloState = SoloState()
    private let masterPeak = OSAllocatedUnfairLock<Float>(initialState: 0)
    private let masterLoudness = OSAllocatedUnfairLock<LoudnessMeter?>(initialState: nil)
    private let log = EngineLog.logger("audio.mixer")
    private let timeline: MixerTimeline

    private var running = false
    private var manualMode = false
    private var manualRenderBuffer: AVAudioPCMBuffer?
    private var masterFormatDescription: CMAudioFormatDescription?
    private var interleaveScratch: UnsafeMutablePointer<Float>
    private var interleaveScratchFrames: Int
    private var manualSampleTime: Int64 = 0

    public init(configuration rawConfiguration: Configuration = Configuration()) {
        // Sanitize at the boundary: clamp every field into a safe range so bad
        // public input (e.g. `sampleRate = 0`) can NEVER abort graph construction.
        let configuration = rawConfiguration.normalized()
        self.configuration = configuration
        // After normalization the rate/channels are valid; still fall back to a
        // guaranteed-valid 48 kHz stereo format rather than aborting if AVAudio
        // ever rejects the request — never crash on public input.
        let format = AVAudioFormat(standardFormatWithSampleRate: configuration.sampleRate,
                                   channels: configuration.channelCount)
            ?? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        self.internalFormat = format
        self.timeline = MixerTimeline(sampleRate: configuration.sampleRate)

        // Scratch for interleaving master-tap buffers (tap thread, no per-callback allocation).
        let scratchFrames = Int(configuration.tapBufferFrames) * 4
        self.interleaveScratchFrames = scratchFrames
        self.interleaveScratch = .allocate(capacity: scratchFrames * Int(configuration.channelCount))

        engine.attach(masterBus)
        engine.connect(masterBus, to: engine.mainMixerNode, format: internalFormat)
        engine.mainMixerNode.outputVolume = 0 // monitoring off by default
    }

    deinit {
        stop()
        interleaveScratch.deallocate()
    }

    // MARK: Channels

    /// Add an input strip. `format` is the *expected* incoming format (used to
    /// pre-build the converter path); packets in any other LPCM format still
    /// convert on the fly. Channels may be added before or while running.
    @discardableResult
    public func addChannel(id: SourceID, format: AVAudioFormat? = nil) throws -> MixerChannel {
        let ringFrames = max(Int(configuration.sampleRate * configuration.ringSeconds), 4800)
        let configuredAlignmentFrames = configuration.maximumInitialAlignmentSeconds.isFinite
            ? max(0, configuration.maximumInitialAlignmentSeconds * configuration.sampleRate)
            : 0
        // Clamp in Double space to the already-bounded ring before converting;
        // even an extreme finite configuration cannot overflow Int here.
        let maximumAlignmentFrames = Int(min(Double(ringFrames), configuredAlignmentFrames))
        let channel = MixerChannel(id: id,
                                   internalFormat: internalFormat,
                                   ringCapacityFrames: ringFrames,
                                   maximumInitialAlignmentFrames: maximumAlignmentFrames,
                                   timeline: timeline,
                                   soloState: soloState)
        _ = format // expected-format hint; converters build lazily on first mismatched packet

        let inserted = channelsLock.withLock { channels -> Bool in
            guard channels[id] == nil else { return false }
            channels[id] = channel
            return true
        }
        guard inserted else {
            throw PrismAudioError.invalidState("channel \(id) already exists")
        }

        engine.attach(channel.sourceNode)
        engine.connect(channel.sourceNode, to: masterBus, format: internalFormat)
        // Hand the channel its graph handles so it can splice AUv3 inserts /
        // voice-isolation between the source node and the master bus without
        // tearing the engine down (§2.4).
        channel.bindGraph(engine: engine, destination: masterBus)
        log.info("added channel \(id.raw)")
        return channel
    }

    /// Remove an input strip (releases its solo latch if held).
    ///
    /// Ducking teardown (C3): a removed channel may be the *key* or the
    /// *target* of a ducking rule. Without teardown, removing a key would leave
    /// its target's `Ducker` reading a frozen `SidechainLevel` — if the key was
    /// loud at removal, the target stays ducked forever. So for every rule the
    /// removed channel participates in we drop the rule and detach the target's
    /// ducker, and we neutralize the removed channel's published level so any
    /// ducker still holding a reference recovers to unity.
    public func removeChannel(id: SourceID) {
        guard let removed = channelsLock.withLock({ $0.removeValue(forKey: id) }) else { return }
        removed.willRemoveFromMixer()

        let targetsKeyedByRemoved: [SourceID] = duckingRules.withLock { rules in
            let keyed = rules.compactMap { $0.value == id ? $0.key : nil }
            for t in keyed { rules.removeValue(forKey: t) }
            _ = rules.removeValue(forKey: id) // if the removed channel was itself a target
            return keyed
        }
        // Belt-and-suspenders: a target's ducker may still reference the removed
        // channel's SidechainLevel for one render block — force it to silence so
        // it can't hold a stale-loud value.
        removed.sidechainLevel.set(0)
        for t in targetsKeyedByRemoved { channel(id: t)?.setSidechainDucker(nil) }

        // Tear down the channel's whole subgraph (any inserts + its source node).
        removed.detachFromGraph()
        log.info("removed channel \(id.raw)")
    }

    public func channel(id: SourceID) -> MixerChannel? {
        channelsLock.withLock { $0[id] }
    }

    public var channelIDs: [SourceID] {
        channelsLock.withLock { Array($0.keys) }
    }

    // MARK: Lifecycle

    /// Start live: pulls the graph against the default output device.
    /// Device side effect — do not call from verification/headless code.
    public func start() throws {
        guard !running else { return }
        manualMode = false
        timeline.beginRun(manual: false)
        try installMasterTap()
        engine.prepare()
        do {
            try engine.start()
        } catch {
            removeMasterTap()
            throw error
        }
        running = true
        log.info("mixer started (live, monitoring \(self.isMonitoringEnabled ? "on" : "off"))")
    }

    /// Start headless: manual rendering mode, no audio hardware touched.
    /// Drive it with `renderManually(frameCount:)`.
    public func startManualRendering(maximumFrameCount: AVAudioFrameCount = 4096) throws {
        guard !running else { return }
        manualMode = true
        manualSampleTime = 0
        timeline.beginRun(manual: true)
        try engine.enableManualRenderingMode(.offline, format: internalFormat,
                                             maximumFrameCount: maximumFrameCount)
        try installMasterTap()
        do {
            try engine.start()
        } catch {
            removeMasterTap()
            engine.disableManualRenderingMode()
            throw error
        }
        manualRenderBuffer = AVAudioPCMBuffer(pcmFormat: internalFormat,
                                              frameCapacity: maximumFrameCount)
        running = true
        log.info("mixer started (manual rendering)")
    }

    /// Pull one block in manual mode. Returns the rendered master mix
    /// (post-monitor-volume — enable monitoring to inspect the mix here;
    /// the master tap fires regardless).
    @discardableResult
    public func renderManually(frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard running, manualMode else {
            throw PrismAudioError.invalidState("renderManually outside manual mode")
        }
        guard let buffer = manualRenderBuffer, frameCount <= buffer.frameCapacity else {
            throw PrismAudioError.invalidState("frameCount exceeds maximumFrameCount")
        }
        let status = try engine.renderOffline(frameCount, to: buffer)
        guard status == .success else {
            throw PrismAudioError.invalidState("renderOffline returned \(String(describing: status))")
        }
        manualSampleTime += Int64(frameCount)
        timeline.publishManualRenderCompleted(manualSampleTime)
        return buffer
    }

    public func stop() {
        guard running else { return }
        removeMasterTap()
        engine.stop()
        if manualMode {
            engine.disableManualRenderingMode()
            manualMode = false
        }
        running = false
        timeline.reset()
        for channel in channelsLock.withLock({ Array($0.values) }) {
            channel.resetForMixerRestart()
        }
        log.info("mixer stopped")
    }

    // MARK: Master tap

    private func installMasterTap() throws {
        let formatDescription = try AudioSampleBufferFactory.interleavedFloatFormatDescription(
            sampleRate: configuration.sampleRate,
            channelCount: Int(configuration.channelCount)
        )
        masterFormatDescription = formatDescription

        masterBus.installTap(onBus: 0,
                             bufferSize: configuration.tapBufferFrames,
                             format: internalFormat) { [weak self] buffer, when in
            self?.handleMasterTap(buffer: buffer, when: when)
        }
    }

    private func removeMasterTap() {
        masterBus.removeTap(onBus: 0)
        masterFormatDescription = nil
    }

    private func handleMasterTap(buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let masterTiming = timeline.observeMasterRender(when: when, frameCount: frames)

        // Master peak meter.
        var framePeak: Float = 0
        for ch in 0..<channelCount {
            let data = channels[ch]
            for f in 0..<frames { framePeak = max(framePeak, abs(data[f])) }
        }
        let observedPeak = framePeak
        masterPeak.withLock { $0 = max($0, observedPeak) }

        // Feed the optional loudness meter (additive; independent of the peak
        // meter and onMasterMix). Deinterleaved Float32, straight from the tap.
        if let meter = masterLoudness.withLock({ $0 }) {
            meter.process(channels, channelCount: channelCount, frameCount: frames)
        }

        guard let onMasterMix, let masterFormatDescription else { return }

        // Interleave into the reusable scratch (grow only on the rare oversized callback).
        if frames > interleaveScratchFrames {
            interleaveScratch.deallocate()
            interleaveScratchFrames = frames
            interleaveScratch = .allocate(capacity: frames * channelCount)
        }
        for ch in 0..<channelCount {
            let data = channels[ch]
            for f in 0..<frames { interleaveScratch[f * channelCount + ch] = data[f] }
        }

        // Project the master render position through the shared mixer epoch.
        // In manual mode the first input packet lazily establishes that epoch.
        let pts: CMTime
        if let mappedPTS = masterTiming.pts {
            pts = mappedPTS
        } else if manualMode {
            // Until an input establishes the manual PTS epoch, publishing
            // sample-time fallback packets would make the later epoch switch
            // discontinuous. Keep metering/rendering, but withhold program PCM.
            return
        } else if when.isHostTimeValid {
            pts = CMClockMakeHostTimeFromSystemUnits(when.hostTime)
        } else if when.isSampleTimeValid {
            pts = CMTime(value: CMTimeValue(when.sampleTime), timescale: CMTimeScale(when.sampleRate.rounded()))
        } else {
            pts = HouseClock.now()
        }

        do {
            let sampleBuffer = try AudioSampleBufferFactory.makeInterleavedSampleBuffer(
                samples: interleaveScratch,
                frameCount: frames,
                channelCount: channelCount,
                formatDescription: masterFormatDescription,
                pts: pts
            )
            onMasterMix(AudioPacket(sampleBuffer: sampleBuffer, source: Self.masterSourceID))
        } catch {
            log.error("master tap: sample buffer creation failed: \(String(describing: error))")
        }
    }
}
