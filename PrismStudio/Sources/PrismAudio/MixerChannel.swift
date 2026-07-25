import AVFAudio
import AudioToolbox
import CoreMedia
import Foundation
import PrismCore
import os

/// Shared solo bookkeeping across a mixer's channels: when any channel is
/// soloed, every non-solo channel is silenced. Read on the audio thread.
final class SoloState: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Int>(initialState: 0)
    func adjust(_ delta: Int) { lock.withLock { $0 += delta } }
    var isActive: Bool { lock.withLock { $0 > 0 } }
}

/// One input strip of the `AudioMixer`.
///
/// Push model: capture code calls `ingest(_:)` with `AudioPacket`s in any PCM
/// format; the packet is converted (AVAudioConverter, lazily built per input
/// format) to the mixer's internal format and lands in a drop-oldest ring
/// buffer. An `AVAudioSourceNode` drains the ring on the audio render thread,
/// applying gain/mute/solo and metering the post-fader peak. Underruns render
/// silence — a stalled source never stalls the mix.
public final class MixerChannel: @unchecked Sendable {
    public let id: SourceID

    // MARK: Controls (thread-safe, audio thread reads under the same lock)

    /// Linear gain (1.0 = unity). Applied on the render thread.
    public var gain: Float {
        get { params.withLock { $0.gain } }
        set { params.withLock { $0.gain = max(0, newValue) } }
    }

    /// Hard mute for this channel.
    public var isMuted: Bool {
        get { params.withLock { $0.muted } }
        set { params.withLock { $0.muted = newValue } }
    }

    /// Solo. While any channel of the mixer is soloed, all non-solo channels
    /// are silenced in the mix.
    public var isSolo: Bool {
        get { params.withLock { $0.solo } }
        set {
            let changed = params.withLock { p -> Bool in
                guard p.solo != newValue else { return false }
                p.solo = newValue
                return true
            }
            if changed { soloState.adjust(newValue ? 1 : -1) }
        }
    }

    /// Post-fader peak since the previous call (read-and-reset).
    public func peakLevel() -> AudioLevel {
        AudioLevel(linear: peak.withLock { p in
            defer { p = 0 }
            return p
        })
    }

    /// Ring-buffer health: frames dropped (overflow) / zero-filled (underrun).
    public var bufferStats: (dropped: UInt64, underruns: UInt64) { ring.stats }

    /// PTS-continuity health: gaps detected in the incoming packet timeline
    /// and internal-rate silence frames inserted to cover them.
    public var timingStats: (gapsDetected: UInt64, silenceFramesInserted: UInt64) {
        timing.withLock { ($0.gaps, $0.silenceFrames) }
    }

    /// Frames currently buffered ahead of the render thread.
    public var bufferedFrames: Int { ring.bufferedFrames }

    // MARK: Internals

    private struct Params {
        var gain: Float = 1.0
        var muted = false
        var solo = false
    }

    private struct Timing {
        var gaps: UInt64 = 0
        var silenceFrames: UInt64 = 0
    }

    private let params = OSAllocatedUnfairLock<Params>(initialState: Params())
    private let peak = OSAllocatedUnfairLock<Float>(initialState: 0)
    private let timing = OSAllocatedUnfairLock<Timing>(initialState: Timing())
    private let soloState: SoloState

    /// This channel's most recent post-fader block level, published every
    /// render block so it can drive a `Ducker` on another channel (sidechain).
    let sidechainLevel = SidechainLevel()
    /// Optional sidechain ducker: when set, its gain is applied to this
    /// channel's output each block (this channel is the *target*).
    private let ducker = OSAllocatedUnfairLock<Ducker?>(initialState: nil)

    /// Attach/detach a sidechain ducker keyed off another channel's level.
    func setSidechainDucker(_ d: Ducker?) { ducker.withLock { $0 = d } }
    private let ring: PCMRingBuffer
    private let internalFormat: AVAudioFormat
    private let maximumInitialAlignmentFrames: Int
    private let timeline: MixerTimeline
    private let log: Logger

    /// Serializes initial/discontinuity placement with this channel's render
    /// callback. The render thread performs only bounded lock/index work here.
    private struct PlacementState {
        var renderedThroughFrame: Int64?
        var needsAbsolutePlacement = true
        var terminal = false
        var warnedAlignmentCap = false
        var ptsAdjustment: CMTime = .zero
    }
    private let placement = OSAllocatedUnfairLock<PlacementState>(initialState: PlacementState())

    /// The node the mixer connects into its graph.
    let sourceNode: AVAudioSourceNode

    // Ingest-side scratch (ingest is externally serialized per channel — one
    // capture queue per source, same model as the rest of the engine).
    private var inputBuffer: AVAudioPCMBuffer?
    private var convertedBuffer: AVAudioPCMBuffer?
    private var converter: AVAudioConverter?

    // PTS continuity (B18): where the incoming timeline should resume if the
    // source is gapless. Ingest-side state — same serialization as above.
    private var expectedNextPTS: CMTime = .invalid
    private var silenceScratch: [Float] = []
    private var warnedBackwardPTS = false
    /// Gaps smaller than this are treated as jitter, not discontinuity.
    private static let gapThresholdSeconds = 0.03
    /// Never synthesize more than this much silence per gap (a huge PTS jump
    /// is a stream reset, not a hole worth filling).
    private static let maxGapSilenceSeconds = 1.0

    init(id: SourceID,
         internalFormat: AVAudioFormat,
         ringCapacityFrames: Int,
         maximumInitialAlignmentFrames: Int,
         timeline: MixerTimeline,
         soloState: SoloState) {
        self.id = id
        self.internalFormat = internalFormat
        self.maximumInitialAlignmentFrames = maximumInitialAlignmentFrames
        self.timeline = timeline
        self.soloState = soloState
        self.ring = PCMRingBuffer(channelCount: Int(internalFormat.channelCount),
                                  capacityFrames: ringCapacityFrames)
        self.log = EngineLog.logger("audio.mixer.\(id.raw)")

        // Local lets so the render block doesn't retain `self` before init completes.
        let ring = self.ring
        let params = self.params
        let peak = self.peak
        let solo = soloState
        let sidechainLevel = self.sidechainLevel
        let ducker = self.ducker
        let placement = self.placement
        let timeline = self.timeline

        self.sourceNode = AVAudioSourceNode(format: internalFormat) { isSilence, timestamp, frameCount, audioBufferList -> OSStatus in
            let frames = Int(frameCount)
            let timestampFrame = timeline.sourceRenderFrame(for: timestamp.pointee)
            // Keep cursor publication and FIFO consumption atomic against the
            // first-packet commit. This closes the ingest/render boundary race.
            placement.withLockUnchecked { state in
                _ = ring.read(into: audioBufferList, frameCount: frames)
                let start = timestampFrame
                    ?? state.renderedThroughFrame
                    ?? timeline.currentRenderFrame
                let (end, overflow) = start.addingReportingOverflow(Int64(frames))
                if !overflow { state.renderedThroughFrame = end }
            }

            let p = params.withLock { $0 }
            let effectivelyMuted = p.muted || (solo.isActive && !p.solo)

            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            if effectivelyMuted {
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
                sidechainLevel.set(0)
                isSilence.pointee = true
                return noErr
            }

            // Sidechain ducking: effective gain = fader × duck gain (this
            // channel is the target; the ducker keys off another channel).
            // Advance the envelope *inside* the lock so the Ducker reference
            // never leaves the lock's protection — the render thread takes no
            // transient retain/release on it, so a concurrent detach can never
            // trigger the Ducker's final release (dealloc) on the audio thread.
            // The only contender for this lock is `setSidechainDucker` (a rare
            // control-thread swap); `process` is bounded, allocation-free work.
            let duck = ducker.withLock { $0?.process(frameCount: frames) ?? 1.0 }
            let effGain = p.gain * duck

            var framePeak: Float = 0
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                if effGain == 1.0 {
                    for i in 0..<sampleCount { framePeak = max(framePeak, abs(data[i])) }
                } else {
                    for i in 0..<sampleCount {
                        let s = data[i] * effGain
                        data[i] = s
                        framePeak = max(framePeak, abs(s))
                    }
                }
            }
            let observedPeak = framePeak
            peak.withLock { $0 = max($0, observedPeak) }
            sidechainLevel.set(framePeak)
            return noErr
        }
    }

    /// Detach-time cleanup: a soloed channel must not leave the solo latch on.
    func willRemoveFromMixer() {
        isSolo = false
        placement.withLock { state in
            state.terminal = true
            ring.reset()
        }
    }

    /// Engine sample time restarts at zero, so buffered PCM and channel-local
    /// timing must restart with the mixer-wide epoch.
    func resetForMixerRestart() {
        placement.withLock { state in
            ring.reset()
            state = PlacementState()
            expectedNextPTS = .invalid
            warnedBackwardPTS = false
            converter = nil
            convertedBuffer?.frameLength = 0
        }
    }

    // MARK: Ingest

    /// Push one packet of PCM into the channel. Any LPCM format; converted to
    /// the mixer's internal 48 kHz stereo float as needed. Call from the
    /// source's capture queue (one caller at a time per channel).
    public func ingest(_ packet: AudioPacket) {
        guard !placement.withLock({ $0.terminal }) else { return }
        let sampleBuffer = packet.sampleBuffer
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM,
              let inputFormat = AVAudioFormat(streamDescription: asbd) else {
            log.error("ingest: dropped non-LPCM or malformed packet from \(self.id.raw)")
            return
        }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        resetConverterForDiscontinuityIfNeeded(pts: pts)

        // Reusable staging buffer in the packet's own format.
        if inputBuffer == nil
            || inputBuffer!.format != inputFormat
            || inputBuffer!.frameCapacity < AVAudioFrameCount(frames) {
            inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                           frameCapacity: max(AVAudioFrameCount(frames), 4096))
            converter = nil // format changed; rebuild lazily below
        }
        guard let staging = inputBuffer else { return }
        staging.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: staging.mutableAudioBufferList
        )
        guard status == noErr else {
            log.error("ingest: CMSampleBufferCopyPCMDataIntoAudioBufferList failed (\(status))")
            return
        }

        if inputFormat == internalFormat {
            commit(staging, pts: pts, sourceFrames: frames, inputRate: inputFormat.sampleRate)
            return
        }
        convertAndCommit(staging, from: inputFormat, pts: pts, sourceFrames: frames)
    }

    /// A stateful resampler must not leak filter/queued samples across a PTS
    /// discontinuity. Detection happens before conversion; commit later applies
    /// the corresponding FIFO placement and source-local rebase.
    private func resetConverterForDiscontinuityIfNeeded(pts: CMTime) {
        guard pts.isValid, pts.isNumeric,
              expectedNextPTS.isValid, expectedNextPTS.isNumeric else { return }
        let gap = CMTimeSubtract(pts, expectedNextPTS).seconds
        if abs(gap) > Self.gapThresholdSeconds { converter?.reset() }
    }

    private func convertAndCommit(_ staging: AVAudioPCMBuffer,
                                  from inputFormat: AVAudioFormat,
                                  pts: CMTime,
                                  sourceFrames: Int) {
        if converter == nil {
            converter = AVAudioConverter(from: inputFormat, to: internalFormat)
            if converter == nil {
                log.error("ingest: no converter \(inputFormat) → internal format")
                return
            }
        }
        guard let converter else { return }

        let ratio = internalFormat.sampleRate / inputFormat.sampleRate
        let needed = AVAudioFrameCount((Double(staging.frameLength) * ratio).rounded(.up)) + 64
        if convertedBuffer == nil || convertedBuffer!.frameCapacity < needed {
            convertedBuffer = AVAudioPCMBuffer(pcmFormat: internalFormat,
                                               frameCapacity: max(needed, 4096))
        }
        guard let converted = convertedBuffer else { return }
        converted.frameLength = 0

        var consumed = false
        var conversionError: NSError?
        let outcome = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow // keep resampler state for the next packet
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return staging
        }
        if outcome == .error {
            log.error("ingest: conversion failed: \(conversionError?.localizedDescription ?? "unknown")")
            return
        }
        if converted.frameLength > 0 {
            commit(converted, pts: pts, sourceFrames: sourceFrames,
                   inputRate: inputFormat.sampleRate)
        }
    }

    private func writeToRing(_ buffer: AVAudioPCMBuffer, sourceFrameOffset: Int = 0) {
        guard let channels = buffer.floatChannelData else { return }
        let available = max(0, Int(buffer.frameLength) - sourceFrameOffset)
        ring.write(deinterleaved: channels,
                   sourceChannelCount: Int(buffer.format.channelCount),
                   sourceFrameOffset: sourceFrameOffset,
                   frameCount: available)
    }

    // MARK: PTS continuity (B18)

    /// Commit converted PCM to the time-blind FIFO. The first surviving packet
    /// is placed absolutely in the shared epoch; later packets retain B18's
    /// per-source gap behavior. A gap after the ring has already underrun is a
    /// source restart, so it is re-placed instead of replaying the pause twice.
    private func commit(_ buffer: AVAudioPCMBuffer,
                        pts: CMTime,
                        sourceFrames: Int,
                        inputRate: Double) {
        placement.withLock { state in
            guard !state.terminal else { return }

            var gap: Double?
            if pts.isValid, pts.isNumeric, inputRate > 0 {
                let expected = expectedNextPTS
                expectedNextPTS = CMTimeAdd(
                    pts,
                    CMTime(value: CMTimeValue(sourceFrames),
                           timescale: CMTimeScale(inputRate.rounded()))
                )
                if expected.isValid, expected.isNumeric {
                    gap = CMTimeSubtract(pts, expected).seconds
                }
            }

            if !state.needsAbsolutePlacement, let gap {
                if gap > Self.gapThresholdSeconds {
                    let alreadyRenderedPause = ring.bufferedFrames == 0
                        && ring.stats.underruns > 0
                    timing.withLock { $0.gaps += 1 }
                    if alreadyRenderedPause {
                        state.needsAbsolutePlacement = true
                        // A house-time forward restart wants ~zero offset. Clear any
                        // stale rebase left by an EARLIER backward-PTS jump whose
                        // placement never cleared it (e.g. trim-debt retry) — otherwise
                        // this restart packet is misplaced by the stale offset (spurious
                        // ~1 s silence, or the whole packet trimmed/dropped).
                        state.ptsAdjustment = .zero
                        log.notice("ingest: \(String(format: "%.1f", gap * 1_000)) ms source restart from \(self.id.raw, privacy: .public) — re-aligned to house time")
                    } else {
                        let silenceFrames = Int((min(gap, Self.maxGapSilenceSeconds)
                                                 * internalFormat.sampleRate).rounded())
                        insertSilence(frames: silenceFrames)
                        timing.withLock { $0.silenceFrames += UInt64(silenceFrames) }
                        log.notice("ingest: \(String(format: "%.1f", gap * 1_000)) ms PTS gap from \(self.id.raw, privacy: .public) — inserted \(silenceFrames) silence frames")
                    }
                } else if gap < -Self.gapThresholdSeconds {
                    // A source-local PTS reset must never move the mixer epoch.
                    // Drop queued old-epoch PCM and locally rebase the reset
                    // stream at the current render frame.
                    ring.reset()
                    state.needsAbsolutePlacement = true
                    let renderFrame = state.renderedThroughFrame ?? timeline.currentRenderFrame
                    if let housePTS = timeline.presentationTime(for: renderFrame) {
                        state.ptsAdjustment = CMTimeSubtract(housePTS, pts)
                    }
                    if !warnedBackwardPTS {
                        warnedBackwardPTS = true
                        log.notice("ingest: backward PTS jump (\(String(format: "%.1f", gap * 1_000)) ms) from \(self.id.raw, privacy: .public) — channel rebased without resetting house time (logged once)")
                    }
                }
            }

            guard state.needsAbsolutePlacement else {
                writeToRing(buffer)
                return
            }
            let adjustedPTS = CMTimeAdd(pts, state.ptsAdjustment)
            placeAbsolutely(buffer, pts: adjustedPTS, state: &state)
            // The rebase offset was computed for THIS one packet. Once the packet is
            // actually placed (absolute mode cleared), drop it so it never bleeds
            // onto a later absolute placement (e.g. a forward source-restart). A
            // trim-debt retry keeps `needsAbsolutePlacement` true and re-maps the
            // next packet afresh, so it must retain the offset — hence the guard.
            if !state.needsAbsolutePlacement { state.ptsAdjustment = .zero }
        }
    }

    private func placeAbsolutely(_ buffer: AVAudioPCMBuffer,
                                 pts: CMTime,
                                 state: inout PlacementState) {
        let packetFrames = Int(buffer.frameLength)
        guard packetFrames > 0 else { return }
        let renderFrame = state.renderedThroughFrame ?? timeline.currentRenderFrame
        let availableLead = max(0, ring.capacityFrames - packetFrames)
        let maximumLead = min(maximumInitialAlignmentFrames, availableLead)
        guard let mapped = timeline.placement(
            for: pts,
            at: renderFrame,
            packetFrames: packetFrames,
            maximumLeadingFrames: maximumLead
        ) else {
            // Invalid PTS cannot participate in cross-source alignment. Preserve
            // the historical behavior for malformed callers and resume FIFO mode.
            writeToRing(buffer)
            state.needsAbsolutePlacement = false
            return
        }

        if mapped.wasCapped, !state.warnedAlignmentCap {
            state.warnedAlignmentCap = true
            log.notice("ingest: initial PTS lead from \(self.id.raw, privacy: .public) exceeded bound — capped at \(maximumLead) frames")
        }
        if mapped.frameOffset > 0 { insertSilence(frames: mapped.frameOffset) }

        let trim = max(0, -mapped.frameOffset)
        guard trim < packetFrames else {
            // Rendering may advance before the next packet. Keep absolute mode
            // and map that packet afresh instead of carrying a stale trim debt.
            return
        }
        writeToRing(buffer, sourceFrameOffset: trim)
        state.needsAbsolutePlacement = false
    }

    /// Zero-fill the ring for `frames` frames of the internal format. Chunked
    /// through a reusable scratch buffer; never allocates past the first gap.
    private func insertSilence(frames: Int) {
        guard frames > 0 else { return }
        let channels = Int(internalFormat.channelCount)
        let chunkFrames = 4_096
        if silenceScratch.count < chunkFrames * channels {
            silenceScratch = [Float](repeating: 0, count: chunkFrames * channels)
        }
        var remaining = frames
        silenceScratch.withUnsafeBufferPointer { buf in
            while remaining > 0 {
                let n = min(remaining, chunkFrames)
                ring.write(interleaved: buf.baseAddress!, sourceChannelCount: channels, frameCount: n)
                remaining -= n
            }
        }
    }

    // MARK: AUv3 inserts + voice isolation (§2.4 "Channel inserts", "Voice isolation")
    //
    // Each channel can host an ordered chain of Audio Unit v3 effects
    // (EQ/comp/limiter/3rd-party) spliced between its source node and the
    // mixer's master bus:
    //
    //     sourceNode → [voice-isolation] → [insert 0] → [insert 1] … → masterBus
    //
    // Graph mutation happens on the control thread (never the render thread):
    // the ring/source-node render path is untouched, so re-wiring an insert
    // chain does not tear down or restart the engine — the other channels keep
    // rendering. All node bookkeeping is guarded by `chain`; the audio render
    // block never takes that lock.

    /// One discoverable Audio Unit effect (data source for a plugin picker UI).
    public struct AudioEffectComponent: Sendable {
        public let name: String
        public let manufacturer: String
        public let description: AudioComponentDescription
    }

    private struct ChainState {
        /// Fallback voice-isolation DSP node (built lazily, retained across toggles).
        var voiceIso: AVAudioUnit?
        var voiceIsoEnabled = false
        /// User inserts, in signal order.
        var inserts: [AVAudioUnit] = []
        /// Nodes currently attached+connected in the live graph (for teardown).
        var attached: [AVAudioUnit] = []
        /// TERMINAL flag: once `detachFromGraph()` has run this channel is
        /// permanently removed from the engine. Any later `rebuildChainLocked` /
        /// `setInserts` / `setVoiceIsolation` MUST bail — reconnecting a detached
        /// source node throws an AVAudioEngine NSException and leaks AU nodes
        /// (finding #2). Guarded by `chain`, so the check and the graph mutation
        /// are atomic against a late async `setInserts` completion.
        var detached = false
    }

    private let chain = OSAllocatedUnfairLock<ChainState>(initialState: ChainState())
    // Engine + destination are owned by the `AudioMixer`; a channel only ever
    // outlives neither, so unowned references avoid a retain cycle.
    private weak var boundEngine: AVAudioEngine?
    private weak var destinationNode: AVAudioNode?

    /// Binds this channel's insert subgraph to the mixer's engine. Called by
    /// `AudioMixer.addChannel` right after the source node is attached and
    /// connected to `destination` (the master bus). Enables later dynamic
    /// insert / voice-isolation re-wiring without tearing the engine down.
    func bindGraph(engine: AVAudioEngine, destination: AVAudioNode) {
        boundEngine = engine
        destinationNode = destination
    }

    /// Tears the whole subgraph down (inserts + source node) and moves the
    /// channel to a TERMINAL detached state. Called by `AudioMixer.removeChannel`
    /// before the channel is dropped.
    ///
    /// All graph mutation happens under `chain`'s lock and sets `st.detached`, so
    /// a concurrent/late `setInserts` (or `setVoiceIsolation`) can never
    /// interleave a reconnect onto a node we just detached (finding #2): it will
    /// see `detached == true` and no-op.
    func detachFromGraph() {
        chain.withLock { st in
            guard !st.detached else { return }
            st.detached = true
            guard let engine = boundEngine else { return }
            engine.disconnectNodeOutput(sourceNode)
            for node in st.attached {
                engine.disconnectNodeOutput(node)
                engine.detach(node)
            }
            st.attached = []
            engine.detach(sourceNode)
        }
    }

    /// Number of user inserts currently loaded on this channel.
    public var insertCount: Int { chain.withLock { $0.inserts.count } }

    /// Whether the voice-isolation stage is engaged.
    public var isVoiceIsolationEnabled: Bool { chain.withLock { $0.voiceIsoEnabled } }

    /// Loads (or replaces) this channel's ordered insert chain from Audio Unit
    /// component descriptions and splices it into the live graph. Pass `[]` to
    /// clear all inserts. AU instantiation is asynchronous (3rd-party AUv3
    /// effects load out-of-process), so this is an `async` call; the graph
    /// re-wire itself is a quick, allocation-bounded control-thread operation.
    ///
    /// - Throws: the instantiation error if any component fails to load. On a
    ///   throw the existing chain is left intact (no partial re-wire).
    public func setInserts(_ descriptions: [AudioComponentDescription]) async throws {
        var units: [AVAudioUnit] = []
        units.reserveCapacity(descriptions.count)
        for description in descriptions {
            units.append(try await Self.instantiateAudioUnit(description))
        }
        let loaded = units
        let applied: Bool = chain.withLock { st in
            // Terminal detached channel: never reconnect. The AUs in `loaded`
            // were instantiated but never attached to any engine, so they simply
            // deallocate on return — no engine mutation, no leak (finding #2).
            guard !st.detached else { return false }
            st.inserts = loaded
            rebuildChainLocked(&st)
            return true
        }
        if applied {
            log.info("channel \(self.id.raw, privacy: .public): \(loaded.count) insert(s) active")
        } else {
            log.info("channel \(self.id.raw, privacy: .public): setInserts ignored — channel detached")
        }
    }

    /// Toggles per-source voice isolation / ML noise removal (§2.4).
    ///
    /// Production intent: Apple's voice-processing I/O
    /// (`AVAudioInputNode.setVoiceProcessingEnabled`) or the newer speech-audio
    /// denoise. Those hang off the *input node* / hardware I/O, so they are not
    /// reachable from an arbitrary node inside a headless
    /// manual-rendering graph. To keep the plumbing honest and testable, the
    /// v1 fallback inserts a real, deterministic DSP node (a high-pass to strip
    /// low-frequency rumble/hum + a gentle top-end low-pass to tame hiss above
    /// the voice band). A production build swaps `makeVoiceIsolationNode()` for
    /// the Apple voice-processing unit while keeping this exact toggle API and
    /// graph slot. The DSP is engaged at the head of the chain (before inserts).
    public func setVoiceIsolation(_ enabled: Bool) {
        chain.withLock { st in
            guard !st.detached else { return } // don't allocate a node for a dead channel (re-verify)
            if enabled, st.voiceIso == nil {
                st.voiceIso = Self.makeVoiceIsolationNode()
            }
            st.voiceIsoEnabled = enabled
            rebuildChainLocked(&st)
        }
        log.info("channel \(self.id.raw, privacy: .public): voice isolation \(enabled ? "on" : "off", privacy: .public)")
    }

    /// Re-wires `sourceNode → [voice-iso?] → [inserts…] → destination`.
    /// Must be called under `chain`'s lock; runs on the control thread only.
    private func rebuildChainLocked(_ st: inout ChainState) {
        // A detached channel is terminal — never re-attach/re-connect its nodes.
        guard !st.detached, let engine = boundEngine, let destination = destinationNode else { return }
        let effects: [AVAudioUnit] =
            (st.voiceIsoEnabled ? (st.voiceIso.map { [$0] } ?? []) : []) + st.inserts
        let keep = Set(effects.map(ObjectIdentifier.init))

        // Detach any node that dropped out of the chain.
        for node in st.attached where !keep.contains(ObjectIdentifier(node)) {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }

        // Re-thread the chain. Disconnecting the source output first leaves the
        // render graph momentarily short a tail, but the master tap simply sees
        // that block as silence for this channel — no crash, no engine restart.
        engine.disconnectNodeOutput(sourceNode)
        var prev: AVAudioNode = sourceNode
        for node in effects {
            if node.engine == nil { engine.attach(node) }
            engine.disconnectNodeOutput(node)
            engine.connect(prev, to: node, format: internalFormat)
            prev = node
        }
        engine.connect(prev, to: destination, format: internalFormat)
        st.attached = effects
    }

    /// Fallback voice-isolation DSP (see `setVoiceIsolation`): a high-pass at
    /// 120 Hz (rumble/hum) plus a 12 kHz low-pass (hiss above the voice band).
    private static func makeVoiceIsolationNode() -> AVAudioUnit {
        let eq = AVAudioUnitEQ(numberOfBands: 2)
        let highPass = eq.bands[0]
        highPass.filterType = .highPass
        highPass.frequency = 120
        highPass.bypass = false
        let lowPass = eq.bands[1]
        lowPass.filterType = .lowPass
        lowPass.frequency = 12_000
        lowPass.bypass = false
        eq.globalGain = 0
        return eq
    }

    /// Async AU instantiation (handles both in-process Apple effects and
    /// out-of-process 3rd-party AUv3 plugins).
    private static func instantiateAudioUnit(_ description: AudioComponentDescription) async throws -> AVAudioUnit {
        try await withCheckedThrowingContinuation { continuation in
            AVAudioUnit.instantiate(with: description, options: []) { unit, error in
                if let unit {
                    continuation.resume(returning: unit)
                } else {
                    continuation.resume(throwing: error ?? PrismAudioError.invalidState("AU instantiation returned nil"))
                }
            }
        }
    }

    /// Discovers installed Audio Unit **effects** (AUv3 + hosted v2) via
    /// `AVAudioUnitComponentManager` — the data source for a plugin-picker UI.
    public static func availableEffectComponents() -> [AudioEffectComponent] {
        let query = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0,
            componentManufacturer: 0,
            componentFlags: 0,
            componentFlagsMask: 0)
        return AVAudioUnitComponentManager.shared().components(matching: query).map {
            AudioEffectComponent(name: $0.name,
                                 manufacturer: $0.manufacturerName,
                                 description: $0.audioComponentDescription)
        }
    }
}
