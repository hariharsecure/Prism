import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import os
import PrismCore

/// A **video-file** source (DESIGN.md §2.1 — "Media sources: … movie files"):
/// decodes a downloaded video FILE and re-emits its frames as a live,
/// real-time-paced source so a clip can be used exactly like a camera in the
/// compositor / stream / record graph.
///
/// Guarantees (the pipeline contract):
///  - **IOSurface-backed at canvas size.** Decoded frames are fitted into a
///    `SourceRenderCanvas` (a `PixelBufferPool` of IOSurface buffers), so every
///    emitted `VideoFrame` satisfies `VideoFrame`'s IOSurface assertion regardless
///    of whether the decoder handed back an IOSurface buffer. An **SDR** clip is
///    fitted into 8-bit **BGRA** (byte-identical to before). A real **HDR** clip
///    (tagged HLG/PQ or Rec.2020, `isHDR`) is decoded to native 10-bit and fitted
///    into a **`64RGBAHalf`** canvas in scene-linear Rec.2020 (tagged Linear/2020),
///    so its full dynamic range + colorimetry reach the HDR compositor instead of
///    being crushed to 8-bit.
///  - **Real-time pacing.** Emission is paced to the file's presentation
///    timestamps relative to `HouseClock` — playback speed, not decode-as-fast.
///  - **Seamless loop** (default): at end-of-file the reader is rebuilt from the
///    top and the house-time anchor advances by the clip's played length, so the
///    source is a continuous feed for streaming / recording.
///  - **Upright, correct fit.** The clip's native (display-oriented) size is
///    fitted into the canvas with the chosen `ContentMode`, the track's
///    `preferredTransform` (rotation metadata) is applied, and the draw path is
///    CoreGraphics' bottom-left-origin `ctx.draw` — identical to `ImageSource`,
///    whose orientation is self-tested — so frames are right-side up.
///
/// **Audio (secondary):** if the file has an audio track and an `onAudio` hook is
/// set before `start()`, the track is decoded to interleaved Float32 LPCM
/// `AudioPacket`s (passthrough of the file's format) on a second paced queue, so
/// a caller can feed a mixer channel for a full A/V stream. Every audio packet is
/// **re-stamped to house time** (`CMSampleBufferCreateCopyWithNewTiming`) so it
/// obeys the `AudioPacket = house-time` contract, continuous across loops. When
/// both `onFrame` and `onAudio` are set on ONE instance, video and audio share a
/// single house-time anchor captured at `start()`, so the two tracks start
/// A/V-aligned (single-reader-equivalent sync). Audio decoding is skipped when
/// there is no audio track or no `onAudio` consumer.
///
/// Thread model: `init(…)` (throws on a missing/undecodable file), `start()` and
/// `stop()` from any control thread (atomic — safe under concurrent/nested
/// calls, including `stop()` from inside `onFrame`/`onAudio`); `onFrame`/`onAudio`
/// fire on the source's own serial decode queues.
public final class MovieSource: VideoSource, AudioSource, @unchecked Sendable {

    /// Reuse `ImageSource`'s fitting modes (fit / fill / stretch).
    public typealias ContentMode = ImageSource.ContentMode

    // MARK: Public surface

    public let id: SourceID
    /// Set before `start()`. Video frames fire on the video decode queue.
    public var onFrame: ((VideoFrame) -> Void)?
    /// Set before `start()`. Audio packets fire on the audio decode queue.
    public var onAudio: ((AudioPacket) -> Void)?

    public var state: SourceState { lifecycleState.withLock { $0.state } }

    /// Whether the file carries a decodable audio track.
    public var hasAudioTrack: Bool { audioTrack != nil }
    /// The clip's native (display-oriented) pixel size — `naturalSize` with the
    /// track's `preferredTransform` applied (rotated clips report swapped W/H).
    public let nativeSize: CGSize
    /// The clip's nominal frame rate (fps), for a fallback frame duration.
    public let nominalFrameRate: Double
    /// True when the clip's codec carries a real alpha channel (ProRes 4444 /
    /// 4444 XQ, or a format that declares an alpha component). The App marks such a
    /// source's scene layer premultiplied so the compositor honors its alpha
    /// (Class C — otherwise a transparent pixel composites as opaque black).
    public let hasAlphaChannel: Bool
    /// True when the clip is real HDR / wide-gamut (tagged HLG or PQ transfer, or
    /// Rec.2020 primaries). Stage N: such a source is decoded to native 10-bit and
    /// its frames are delivered as `64RGBAHalf` in **scene-linear Rec.2020** (tagged
    /// Linear/Rec.2020) instead of being down-converted to 8-bit BGRA — so its real
    /// dynamic range and colorimetry reach the HDR compositor. An SDR clip stays on
    /// the byte-identical 8-bit BGRA path (no regression). The App can read this to
    /// select the compositor's HDR colour mode for the show.
    public let isHDR: Bool

    // MARK: Config

    private let log = EngineLog.logger("sources.movie")
    private let fileURL: URL
    private let canvas: SourceRenderCanvas
    private let contentMode: ContentMode
    private let background: RGBAColor
    private let loop: Bool

    private let asset: AVURLAsset
    private let videoTrack: AVAssetTrack
    private let audioTrack: AVAssetTrack?
    private let preferredTransform: CGAffineTransform
    private let ciContext: CIContext
    private let frameDurationFallback: CMTime
    private let frameDurationSeconds: Double

    // Stage N (10-bit HDR ingest). Present only for an HDR clip: a 64RGBAHalf
    // canvas pool + a colour-managed CIContext whose working space is extendedLinear
    // Rec.2020 and whose OUTPUT space MATCHES the clip's transfer (itur_2100_HLG for an
    // HLG clip, itur_2100_PQ for a PQ clip — sol #6 finding 1), so a decoded frame is
    // fit into the canvas as an HLG or PQ SIGNAL in Rec.2020 primaries (never routed
    // through the 8-bit BGRA canvas, and never PQ→HLG tone-mapped). The compositor then
    // decodes it with its OWN validated BT.2100 transfer, matching the native x420 path.
    private let hdrCanvasPool: PixelBufferPool?
    private let hdrCIContext: CIContext?
    /// Output colour space of the HDR fit pass — `itur_2100_HLG` for an HLG clip,
    /// `itur_2100_PQ` for a PQ clip (sol #6 finding 1). The buffer is tagged to match
    /// (`YCbCrTags.stampHLGRec2020` / `stampPQRec2020`).
    private let hdrOutputColorSpace: CGColorSpace?
    /// The HLG output space — kept for a PQ clip too so the `_test_forceHLGCanvasForPQ`
    /// reproduction seam can force the pre-fix HLG canvas. Same object as
    /// `hdrOutputColorSpace` for an HLG clip.
    private let hdrHLGColorSpace: CGColorSpace?
    /// True when the clip's transfer is PQ (ST 2084) rather than HLG — selects the PQ
    /// output space + `stampPQRec2020` tag so a PQ movie composites as PQ (sol #6 f1).
    private let hdrIsPQ: Bool

    // MARK: State

    /// State, run identity, and loop accounting are one atomic snapshot. Keeping
    /// the generation beside the state is important: separate locks could let an
    /// old loop observe a new run's `.running` bit between two reads.
    private struct LifecycleState {
        var state: SourceState = .idle
        var generation: UInt64 = 0
        var activeLoops = 0
        var pendingStopDrains = 0
    }
    private let lifecycleState = OSAllocatedUnfairLock(initialState: LifecycleState())
    /// The error that moved the source to `.failed` (for callers / tests).
    private let lastErrorBox = OSAllocatedUnfairLock<SourceError?>(initialState: nil)
    public var lastError: SourceError? { lastErrorBox.withLock { $0 } }

    private let videoQueue = DispatchQueue(label: "studio.prism.source.movie.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "studio.prism.source.movie.audio", qos: .userInitiated)
    /// Serializes lifecycle transitions. Delivery queues are never drained while
    /// this queue is held; otherwise a callback-originated stop can form a cycle.
    private let lifecycleQueue = DispatchQueue(label: "studio.prism.source.movie.lifecycle")
    private let videoQueueKey = DispatchSpecificKey<UInt8>()
    private let audioQueueKey = DispatchSpecificKey<UInt8>()

    // MARK: Diagnostics / test injection (internal — exercised by the self-tests)

    /// Total `AVAssetReader`s created for the video track (bounded-restart proof,
    /// M4): a corrupt/empty file must not spin creating readers.
    let videoReaderCreations = OSAllocatedUnfairLock<Int>(initialState: 0)
    /// Video frames dropped because their presentation target was already in the
    /// past by more than a small margin (M9: stay live, no catch-up burst).
    let lateFramesDropped = OSAllocatedUnfairLock<Int>(initialState: 0)
    /// Times the video anchor was re-seated because it fell catastrophically
    /// behind wall time (M9 severe-lag recovery).
    let anchorReseats = OSAllocatedUnfairLock<Int>(initialState: 0)
    /// Called on the video queue with the sample index just after decode, before
    /// pacing — tests inject a stall here to force lateness (M9).
    var videoSampleHook: ((Int) -> Void)?
    /// Consecutive render failures before the source fails terminally (M12).
    let renderFailureLimit = 12
    /// Outstanding phase-two stop drains for deterministic lifecycle regressions.
    var pendingStopDrainCount: Int { lifecycleState.withLock { $0.pendingStopDrains } }

    // MARK: Init

    /// - Parameters:
    ///   - fileURL: the video file to play.
    ///   - canvasSize: output dimensions (frames are fitted into this).
    ///   - contentMode: how the clip's native size fits the canvas.
    ///   - background: fill behind a letterboxed clip. Default `.clear` (F23/F17)
    ///     so an alpha-bearing / aspect-fit clip stays an overlay rather than a
    ///     silent opaque-black rectangle; pass an opaque colour for a full backdrop.
    ///   - loop: restart at end-of-file for a continuous feed (default true).
    /// - Throws: `SourceError.mediaLoadFailed` (missing/unreadable),
    ///   `.mediaHasNoVideoTrack`, or `.canvasCreationFailed`.
    public init(id: SourceID = SourceID("movie.\(UUID().uuidString)"),
                fileURL: URL,
                canvasSize: CanvasSize = .hd,
                contentMode: ContentMode = .aspectFit,
                background: RGBAColor = .clear,
                loop: Bool = true) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SourceError.mediaLoadFailed(path: fileURL.path, underlying: nil)
        }
        self.id = id
        self.fileURL = fileURL
        self.contentMode = contentMode
        self.background = background
        self.loop = loop
        self.canvas = try SourceRenderCanvas(size: canvasSize)
        self.asset = AVURLAsset(url: fileURL)
        self.ciContext = CIContext(options: [.cacheIntermediates: false])

        let loaded = try Self.loadTracks(asset: asset, path: fileURL.path)
        self.videoTrack = loaded.video
        self.audioTrack = loaded.audio
        self.preferredTransform = loaded.transform
        // M10: report the DISPLAY-oriented size (naturalSize through the
        // preferredTransform), so a 90°-rotated clip reports swapped W/H.
        let displayRect = CGRect(origin: .zero, size: loaded.naturalSize)
            .applying(loaded.transform).standardized
        self.nativeSize = CGSize(width: abs(displayRect.width.rounded()),
                                 height: abs(displayRect.height.rounded()))
        let fps = loaded.frameRate > 0 ? Double(loaded.frameRate) : 24.0
        self.nominalFrameRate = fps
        self.hasAlphaChannel = loaded.hasAlpha
        self.frameDurationSeconds = 1.0 / fps
        self.frameDurationFallback = CMTime(seconds: 1.0 / fps, preferredTimescale: 600)

        // Stage N: an HDR clip carries alpha essentially never, so preferring the
        // 10-bit HDR path over the alpha (BGRA) path is safe. Build the HDR fit
        // resources once; if any fail to construct we fall back to the SDR path.
        let hdr = loaded.isHDR
        self.isHDR = hdr
        let isPQ = loaded.hdrIsPQ
        self.hdrIsPQ = isPQ
        if hdr,
           let workingLinear2020 = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020),
           let hlg2020 = CGColorSpace(name: CGColorSpace.itur_2100_HLG),
           let pool = try? PixelBufferPool(width: canvas.width, height: canvas.height,
                                           pixelFormat: kCVPixelFormatType_64RGBAHalf,
                                           minimumBufferCount: 4) {
            self.hdrCanvasPool = pool
            self.hdrHLGColorSpace = hlg2020
            // sol #5 finding 1 / sol #6 finding 1: the fitted canvas is HDR-ENCODED in
            // the clip's OWN transfer (output colour space itur_2100_HLG for HLG,
            // itur_2100_PQ for PQ) + tagged to match, so the compositor decodes it with
            // its OWN validated BT.2100 transfer (matching the native x420 path) — NOT
            // Core Image's DISPLAY-linear `extendedLinearITUR_2020` (over-brightened HLG
            // 0.5→≈766), and — for PQ — NOT the HLG canvas (which PQ→HLG tone-mapped a
            // PQ Y10 512 to ≈650 vs the native-PQ ≈565).
            let pq2020 = isPQ ? CGColorSpace(name: CGColorSpace.itur_2100_PQ) : nil
            self.hdrOutputColorSpace = (isPQ ? pq2020 : nil) ?? hlg2020
            self.hdrCIContext = CIContext(options: [
                .cacheIntermediates: false,
                .workingColorSpace: workingLinear2020,
                .workingFormat: CIFormat.RGBAh,
            ])
        } else {
            self.hdrCanvasPool = nil
            self.hdrOutputColorSpace = nil
            self.hdrHLGColorSpace = nil
            self.hdrCIContext = nil
        }

        videoQueue.setSpecific(key: videoQueueKey, value: 1)
        audioQueue.setSpecific(key: audioQueueKey, value: 1)
    }

    /// Convenience for a filesystem path.
    public convenience init(id: SourceID = SourceID("movie.\(UUID().uuidString)"),
                            path: String,
                            canvasSize: CanvasSize = .hd,
                            contentMode: ContentMode = .aspectFit,
                            // F23/F17: MATCH the `fileURL:` init default (`.clear`).
                            background: RGBAColor = .clear,
                            loop: Bool = true) throws {
        try self.init(id: id, fileURL: URL(fileURLWithPath: path),
                      canvasSize: canvasSize, contentMode: contentMode,
                      background: background, loop: loop)
    }

    // MARK: Lifecycle (atomic — M3 nested-stop safe, M6 concurrent-safe)

    /// sol #8: validate that decoding can BEGIN (a video reader is creatable) WITHOUT
    /// launching the delivery loops or wiring callbacks — so a transactional
    /// reconfigure can confirm the replacement is good BEFORE retiring the
    /// predecessor, yet not feed the shared effect pipeline / mixer channel until the
    /// predecessor has drained. Mirrors the fail-fast `start()` performs; a reader
    /// built here is discarded (nothing is started).
    public func validateStartable() throws {
        _ = try makeVideoReader()
    }

    public func start() throws {
        let onVideoQueue = DispatchQueue.getSpecific(key: videoQueueKey) != nil
        let onAudioQueue = DispatchQueue.getSpecific(key: audioQueueKey) != nil

        // A decode failure invalidates the run immediately, but its sibling
        // delivery loop can still be unwinding. Reuse the two-phase stop barrier
        // before accepting a restart so no old-generation callback can cross the
        // new start() boundary.
        let failedRunPlan = lifecycleQueue.sync { () -> StopPlan? in
            guard lifecycleState.withLock({ $0.state == .failed }) else { return nil }
            return prepareStop(onVideoQueue: onVideoQueue, onAudioQueue: onAudioQueue)
        }
        if let failedRunPlan {
            drainAndFinishStop(failedRunPlan)
        }

        try lifecycleQueue.sync { try startLocked() }
    }

    private func startLocked() throws {
        // Compare-and-set: only one caller wins the .idle → .starting move.
        // Failed runs are first quiesced by `start()` above.
        let generation: UInt64? = lifecycleState.withLock { lifecycle in
            guard lifecycle.state == .idle else { return nil }
            lifecycle.generation &+= 1
            if lifecycle.generation == 0 { lifecycle.generation = 1 }
            lifecycle.activeLoops = 0
            lifecycle.pendingStopDrains = 0
            lifecycle.state = .starting
            return lifecycle.generation
        }
        guard let generation else { return }
        lastErrorBox.withLock { $0 = nil }

        // Fail fast if a reader can't even be created for this asset.
        do { _ = try makeVideoReader() }
        catch {
            lifecycleState.withLock { lifecycle in
                if lifecycle.generation == generation, lifecycle.state == .starting {
                    lifecycle.state = .failed
                }
            }
            lastErrorBox.withLock { $0 = (error as? SourceError) }
            throw error
        }

        // Capture the single shared house-time anchor for BOTH tracks (M2).
        let anchor = HouseClock.now()

        let wantVideo = onFrame != nil
        let wantAudio = audioTrack != nil && onAudio != nil

        let launched: Bool = lifecycleState.withLock { lifecycle in
            guard lifecycle.generation == generation, lifecycle.state == .starting else {
                return false
            }
            lifecycle.activeLoops = (wantVideo ? 1 : 0) + (wantAudio ? 1 : 0)
            lifecycle.state = .running
            return true
        }
        guard launched else { return }

        if wantVideo {
            videoQueue.async { [self] in
                runVideoLoop(generation: generation, anchor: anchor)
            }
        }
        if wantAudio {
            audioQueue.async { [self] in
                runAudioLoop(generation: generation, anchor: anchor)
            }
        }
    }

    public func stop() {
        let onVideoQueue = DispatchQueue.getSpecific(key: videoQueueKey) != nil
        let onAudioQueue = DispatchQueue.getSpecific(key: audioQueueKey) != nil
        let plan = lifecycleQueue.sync {
            prepareStop(onVideoQueue: onVideoQueue, onAudioQueue: onAudioQueue)
        }
        guard let plan else { return }

        drainAndFinishStop(plan)
    }

    private func drainAndFinishStop(_ plan: StopPlan) {
        // Phase two deliberately happens without lifecycleQueue. An external
        // stop may now wait for callbacks, while callback-originated repeat stops
        // can enter lifecycleQueue, see `.stopping`, and return immediately.
        if plan.drainVideo { videoQueue.sync {} }
        if plan.drainAudio { audioQueue.sync {} }

        finishStop(plan)
    }

    private struct StopPlan {
        let generation: UInt64
        let drainVideo: Bool
        let drainAudio: Bool
    }

    /// Lifecycle phase one. A callback that loses the transition race must not
    /// drain either queue: the winning external/callback stop is already doing
    /// that work, and waiting here would recreate the cross-queue lock cycle.
    private func prepareStop(onVideoQueue: Bool, onAudioQueue: Bool) -> StopPlan? {
        lifecycleState.withLock { lifecycle in
            let onDeliveryQueue = onVideoQueue || onAudioQueue
            switch lifecycle.state {
            case .running, .starting, .failed:
                lifecycle.state = .stopping
                lifecycle.pendingStopDrains += 1
                return StopPlan(
                    generation: lifecycle.generation,
                    drainVideo: !onVideoQueue,
                    drainAudio: audioTrack != nil && !onAudioQueue
                )
            case .stopping:
                // Repeat callback stops are nonblocking. Repeat external stops
                // still drain both queues so their return is a quiescence barrier.
                guard !onDeliveryQueue else { return nil }
                lifecycle.pendingStopDrains += 1
                return StopPlan(
                    generation: lifecycle.generation,
                    drainVideo: true,
                    drainAudio: audioTrack != nil
                )
            case .idle:
                return nil
            }
        }
    }

    /// Complete one phase-two drain. `.idle` is not published until every stop
    /// plan for this generation has drained, so no restart can be queued in front
    /// of a slower concurrent stopper.
    private func finishStop(_ plan: StopPlan) {
        lifecycleQueue.sync {
            lifecycleState.withLock { lifecycle in
                guard lifecycle.generation == plan.generation,
                      lifecycle.state == .stopping,
                      lifecycle.pendingStopDrains > 0 else { return }
                lifecycle.pendingStopDrains -= 1
                guard lifecycle.pendingStopDrains == 0 else { return }
                lifecycle.activeLoops = 0
                lifecycle.state = .idle
            }
        }
    }

    /// A loop belongs to exactly one start. A later run's `.running` state can
    /// never revive work queued by an earlier generation.
    private func isRunning(generation: UInt64) -> Bool {
        lifecycleState.withLock {
            $0.state == .running && $0.generation == generation
        }
    }

    // MARK: Terminal-state finalization (M5)

    /// A loop reached natural end-of-file. The LAST track to finish moves the
    /// source to a restartable terminal state (`.idle`).
    private func loopFinishedEOF(generation: UInt64) {
        lifecycleQueue.sync {
            lifecycleState.withLock { lifecycle in
                guard lifecycle.generation == generation else { return }
                if lifecycle.activeLoops > 0 { lifecycle.activeLoops -= 1 }
                if lifecycle.activeLoops == 0, lifecycle.state == .running {
                    lifecycle.state = .idle
                }
            }
        }
    }

    /// A loop exited because `stop()` was called — `stop()` owns the transition.
    private func loopFinishedStopped(generation: UInt64) {
        lifecycleQueue.sync {
            lifecycleState.withLock { lifecycle in
                guard lifecycle.generation == generation else { return }
                if lifecycle.activeLoops > 0 { lifecycle.activeLoops -= 1 }
            }
        }
    }

    /// A loop hit an unrecoverable decode/reader/render error. Terminal `.failed`
    /// immediately (which also unwinds the sibling track, M5).
    private func loopFailed(_ err: SourceError, generation: UInt64) {
        lifecycleQueue.sync {
            let applies = lifecycleState.withLock { lifecycle -> Bool in
                guard lifecycle.generation == generation,
                      lifecycle.state == .running || lifecycle.state == .starting else {
                    return false
                }
                if lifecycle.activeLoops > 0 { lifecycle.activeLoops -= 1 }
                lifecycle.state = .failed
                return true
            }
            if applies {
                lastErrorBox.withLock { if $0 == nil { $0 = err } }
            }
        }
    }

    // MARK: Video decode + emit

    private enum LoopExit { case stopped, eof, failed(SourceError) }

    private func runVideoLoop(generation: UInt64, anchor: CMTime) {
        var loopBase = anchor
        if loopBase == .invalid { loopBase = HouseClock.now() }
        var consecutiveRenderFailures = 0
        var sampleIndex = 0
        let exit = videoPlaythroughs(loopBase: &loopBase,
                                     consecutiveRenderFailures: &consecutiveRenderFailures,
                                     sampleIndex: &sampleIndex,
                                     generation: generation)
        switch exit {
        case .stopped:       loopFinishedStopped(generation: generation)
        case .eof:           loopFinishedEOF(generation: generation)
        case .failed(let e): loopFailed(e, generation: generation)
        }
    }

    // Split out so the outer loop stays readable; returns why it exited.
    private func videoPlaythroughs(loopBase: inout CMTime,
                                   consecutiveRenderFailures: inout Int,
                                   sampleIndex: inout Int,
                                   generation: UInt64) -> LoopExit {
        let maxLate = max(2 * frameDurationSeconds, 0.05)   // drop past-due frames beyond this
        let severeLate = 1.0                                 // re-anchor if this far behind

        while isRunning(generation: generation) {
            let reader: AVAssetReader
            let output: AVAssetReaderTrackOutput
            do { (reader, output) = try makeVideoReader() }
            catch {
                return .failed((error as? SourceError) ?? .mediaReaderFailed(reason: "\(error)"))
            }
            guard reader.startReading() else {
                return .failed(.mediaReaderFailed(reason: "video startReading: \(String(describing: reader.error))"))
            }

            var firstPTS = CMTime.invalid
            var playedEnd = CMTime.zero
            var emittedThisPass = 0

            innerLoop: while isRunning(generation: generation) {
                guard let sample = output.copyNextSampleBuffer() else { break }  // EOF or error
                videoSampleHook?(sampleIndex)
                sampleIndex += 1
                guard isRunning(generation: generation) else { break innerLoop }
                guard let pixel = CMSampleBufferGetImageBuffer(sample) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if firstPTS == .invalid { firstPTS = pts }
                let offset = CMTimeSubtract(pts, firstPTS)
                var target = CMTimeAdd(loopBase, offset)
                let sampleDur = CMSampleBufferGetDuration(sample)
                let dur = sampleDur.isNumeric && sampleDur.value > 0 ? sampleDur : frameDurationFallback

                // M9: stay live. If this frame's target is already well in the
                // past, don't replay stale backlog — drop it (never a catch-up
                // burst). If catastrophically behind, re-seat the anchor to now.
                let late = CMTimeSubtract(HouseClock.now(), target).seconds
                if late.isFinite && late > severeLate {
                    let jump = CMTime(seconds: late, preferredTimescale: 600)
                    loopBase = CMTimeAdd(loopBase, jump)
                    target = CMTimeAdd(target, jump)
                    anchorReseats.withLock { $0 += 1 }
                    lateFramesDropped.withLock { $0 += 1 }
                    playedEnd = CMTimeAdd(offset, dur)
                    continue
                }
                if late.isFinite && late > maxLate {
                    lateFramesDropped.withLock { $0 += 1 }
                    playedEnd = CMTimeAdd(offset, dur)
                    continue
                }

                paceUntil(target, generation: generation)
                if !isRunning(generation: generation) { break innerLoop }
                let emitted = emitVideo(
                    pixel,
                    houseTime: target,
                    duration: dur,
                    generation: generation
                )
                // A stop (and possibly a restart) may have happened inside the
                // callback. Do not let that new run revive this playthrough.
                if !isRunning(generation: generation) { break innerLoop }
                if emitted {
                    consecutiveRenderFailures = 0
                    emittedThisPass += 1
                } else {
                    consecutiveRenderFailures += 1
                    if consecutiveRenderFailures >= renderFailureLimit {
                        // M12: don't spin frameless in silence — fail terminally.
                        return .failed(.imageDecodeFailed(path: fileURL.path))
                    }
                }
                playedEnd = CMTimeAdd(offset, dur)
            }

            // Inspect the reader OUTSIDE the running check — a mid-file corrupt
            // read surfaces as .failed even though copyNextSampleBuffer returned nil.
            let status = reader.status
            let readerError = reader.error
            reader.cancelReading()

            if !isRunning(generation: generation) { return .stopped }

            if status == .failed {
                return .failed(.mediaReaderFailed(reason: "video reader failed: \(String(describing: readerError))"))
            }
            // M4: a file that yields no frames / zero played duration is corrupt or
            // empty — do NOT immediately rebuild a reader (tight spin). Fail typed.
            if emittedThisPass == 0 || CMTimeCompare(playedEnd, .zero) <= 0 {
                return .failed(.mediaReaderFailed(reason: "video track produced no playable frames"))
            }

            guard loop else { return .eof }
            // Advance the anchor so the next loop continues seamlessly; never let
            // it fall behind wall time (avoids a catch-up burst after a long clip).
            loopBase = CMTimeAdd(loopBase, playedEnd)
            let now = HouseClock.now()
            if CMTimeCompare(loopBase, now) < 0 { loopBase = now }
        }
        return .stopped
    }

    /// Render + emit one frame. Returns `false` on a render failure (M12 tracks
    /// persistent failures to a terminal state instead of spinning silently).
    private func emitVideo(
        _ pixel: CVImageBuffer,
        houseTime: CMTime,
        duration: CMTime,
        generation: UInt64
    ) -> Bool {
        guard isRunning(generation: generation) else { return true }
        do {
            let buffer = deliversTenBit ? try renderFittedHDR(pixel) : try renderFitted(pixel)
            // Rendering can be expensive. Re-check after it so a stop that
            // landed during rendering suppresses delivery of the completed frame.
            guard isRunning(generation: generation) else { return true }
            let frame = VideoFrame(pixelBuffer: buffer, pts: houseTime, duration: duration, source: id)
            onFrame?(frame)
            return true
        } catch {
            log.error("movie frame render failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Fit a decoded frame into the canvas (upright, letterboxed) and return the
    /// canvas-sized IOSurface-backed BGRA buffer.
    private func renderFitted(_ pixel: CVImageBuffer) throws -> CVPixelBuffer {
        var ci = CIImage(cvImageBuffer: pixel)
        if !preferredTransform.isIdentity {
            ci = ci.transformed(by: preferredTransform)
            // Re-seat to a non-negative origin so `createCGImage(from: extent)` is correct.
            ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x,
                                                      y: -ci.extent.origin.y))
        }
        guard ci.extent.width >= 1, ci.extent.height >= 1,
              let cg = ciContext.createCGImage(ci, from: ci.extent) else {
            throw SourceError.imageDecodeFailed(path: fileURL.path)
        }
        // Same fit + upright draw path as ImageSource (row 0 → visual top).
        let dest = ImageSource.fittedRect(imageW: cg.width, imageH: cg.height,
                                          canvasW: canvas.width, canvasH: canvas.height,
                                          mode: contentMode)
        return try canvas.render { ctx in
            ctx.setFillColor(background.cgColor)
            ctx.fill(canvas.canvasRect)
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: dest)
        }
    }

    /// Stage N — fit a decoded 10-bit HDR frame into the canvas WITHOUT collapsing
    /// to 8-bit. Same upright/letterbox geometry as `renderFitted`, but the pass is
    /// colour-managed: the decoded HLG/PQ frame is fit + composited over the
    /// background and rendered into a `64RGBAHalf` buffer whose OUTPUT colour space
    /// is extendedLinear Rec.2020, then tagged Linear/Rec.2020. CoreImage reads the
    /// source's colorimetry off the decoded buffer and converts it into scene-linear
    /// Rec.2020, so the compositor folds the half-float layer straight into its
    /// Rec.2020 linear working target (no re-decode, no 8-bit round-trip). Falls back
    /// to the SDR path if the HDR resources are absent.
    private func renderFittedHDR(_ pixel: CVImageBuffer) throws -> CVPixelBuffer {
        guard let pool = hdrCanvasPool, let ctx = hdrCIContext, var outSpace = hdrOutputColorSpace else {
            return try renderFitted(pixel)
        }
        // sol #6 finding 1: a PQ clip goes to a PQ-tagged canvas, an HLG clip to an
        // HLG-tagged canvas — so the compositor decodes each with the matching transfer
        // and a PQ movie composites to the SAME value as a native PQ source (≈565), not
        // the PQ→HLG tone-mapped ≈650.
        var stampPQ = hdrIsPQ
        #if DEBUG
        if _test_forceHLGCanvasForPQ, let hlg = hdrHLGColorSpace { outSpace = hlg; stampPQ = false }
        #endif
        var ci = CIImage(cvImageBuffer: pixel)
        if !preferredTransform.isIdentity {
            ci = ci.transformed(by: preferredTransform)
            ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x,
                                                      y: -ci.extent.origin.y))
        }
        let imgW = ci.extent.width, imgH = ci.extent.height
        guard imgW >= 1, imgH >= 1 else { throw SourceError.imageDecodeFailed(path: fileURL.path) }

        // Same fit rect as the SDR path (centered → origin-convention agnostic).
        let dest = ImageSource.fittedRect(imageW: Int(imgW.rounded()), imageH: Int(imgH.rounded()),
                                          canvasW: canvas.width, canvasH: canvas.height,
                                          mode: contentMode)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: dest.width / imgW,
                                                          y: dest.height / imgH))
        let placed = scaled.transformed(by: CGAffineTransform(translationX: dest.origin.x - scaled.extent.origin.x,
                                                              y: dest.origin.y - scaled.extent.origin.y))
        // Background fill (default .clear → transparent letterbox surround, Class C).
        // sol #7 #6: `RGBAColor` components are sRGB (see `RGBAColor`), so the letterbox
        // `CIColor` MUST be qualified with the sRGB colorspace — otherwise Core Image
        // reads the raw components in this pass's linear-Rec.2020 working space and a
        // public sRGB gray 0.5 bar composited to ≈369 instead of the correct ≈724.
        let canvasRect = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        var bgColor = CGColorSpace(name: CGColorSpace.sRGB).flatMap {
            CIColor(red: background.r, green: background.g, blue: background.b, alpha: background.a, colorSpace: $0)
        } ?? CIColor(red: background.r, green: background.g, blue: background.b, alpha: background.a)
        #if DEBUG
        // Reproduce the DEFECT MECHANISM the finding describes: the letterbox colour
        // interpreted in the linear-Rec.2020 CANVAS working space instead of sRGB. (A
        // plain unqualified `CIColor` defaults to sRGB on some macOS versions, so the
        // literal pre-fix code is only wrong where the default differs — this seam pins
        // the wrong-space interpretation so the negative control is deterministic.)
        if _test_unqualifiedLetterboxColor, let working = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020),
           let wrong = CIColor(red: background.r, green: background.g, blue: background.b, alpha: background.a, colorSpace: working) {
            bgColor = wrong
        }
        #endif
        let bg = CIImage(color: bgColor).cropped(to: canvasRect)
        let composed = placed.composited(over: bg)

        let out: CVPixelBuffer
        do { out = try pool.makeBuffer() }
        catch { throw SourceError.canvasCreationFailed(reason: "\(error)") }
        ctx.render(composed, to: out, bounds: canvasRect, colorSpace: outSpace)
        // sol #5 finding 1 / sol #6 finding 1: the buffer now holds an HDR SIGNAL in
        // Rec.2020 primaries in the clip's OWN transfer (the CI pass output colour space
        // is itur_2100_HLG or itur_2100_PQ) — tag it to MATCH so the compositor decodes
        // it with its OWN validated BT.2100 transfer (already-2020 → no re-rotate),
        // compositing to the SAME value as the direct native x420 path.
        if stampPQ { YCbCrTags.stampPQRec2020(out) } else { YCbCrTags.stampHLGRec2020(out) }
        return out
    }

    #if DEBUG
    /// Reproduction seam (DEBUG only): force a PQ clip through the pre-sol#6 HLG canvas
    /// (+ HLG tag), so a test can assert the SAME PQ movie diverges from the native PQ
    /// path with the seam ON (Core Image PQ→HLG tone-map ≈650) and matches it with the
    /// seam OFF (PQ-tagged ≈565). No effect on an HLG clip. Never set in prod.
    public var _test_forceHLGCanvasForPQ = false
    #endif

    #if DEBUG
    /// Reproduction seam (DEBUG only): force the pre-sol#7#6 UNQUALIFIED letterbox
    /// `CIColor` (raw components read in the linear-Rec.2020 working space), so a test
    /// can assert the SAME sRGB-gray background diverges from the sRGB oracle with the
    /// seam ON (≈369) and matches it with the seam OFF (≈724). Never set in prod.
    public var _test_unqualifiedLetterboxColor = false
    #endif

    #if DEBUG
    /// Reproduction seam (DEBUG only): force the pre-stage-N behaviour — decode +
    /// deliver an HDR clip as 8-bit BGRA (the old `makeVideoReader` BGRA8 + untagged
    /// canvas). Lets a test assert the SAME 10-bit HDR movie arrives 8-bit here and
    /// 10-bit tagged with the seam off (a live negative control). Never set in prod.
    public var _test_forceEightBitDownconvert = false
    #endif

    /// Whether this instance actually delivers 10-bit (HDR resources constructed).
    /// `isHDR` is the DETECTION result; if the 64RGBAHalf pool / CIContext failed to
    /// build we degrade to the SDR path, and this is false.
    private var deliversTenBit: Bool {
        #if DEBUG
        if _test_forceEightBitDownconvert { return false }
        #endif
        return hdrCanvasPool != nil && hdrCIContext != nil
    }

    /// sol #5 finding 5: an HDR clip that ALSO carries alpha (a legal HLG/PQ
    /// ProRes 4444 overlay). The plain HDR path decodes native `x420`, which has NO
    /// alpha — so a transparent HDR overlay silently became opaque (covered the
    /// layers beneath with black). Such a clip is decoded through the ALPHA-bearing
    /// wide `64RGBAHalf` reader format (AVAssetReader preserves the HLG/PQ SIGNAL +
    /// Rec.2020 tags + the real alpha channel — verified: an HLG box round-trips its
    /// signal and the transparent surround keeps α=0) and fitted (premultiplied) into
    /// the same HLG-tagged canvas, so its transparency AND its HDR colour both survive.
    /// (The alpha-less `x420` YUV path cannot carry the alpha at all.)
    private var deliversAlphaHDR: Bool {
        deliversTenBit && hasAlphaChannel
    }

    private func makeVideoReader() throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        videoReaderCreations.withLock { $0 += 1 }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw SourceError.mediaReaderFailed(reason: "AVAssetReader: \(error)") }
        // Stage N: an HDR clip is decoded to native 10-bit YUV ('x420', video-range —
        // HLG/PQ are always video range) so the real code values and the source's
        // colorimetry attachments survive the decode (CoreImage then converts them
        // into the HLG-tagged Rec.2020 canvas in `renderFittedHDR`). An SDR clip stays
        // BGRA8.
        //
        // sol #5 finding 5: an HDR clip that ALSO carries alpha (ProRes 4444 HLG/PQ)
        // must NOT take the `x420` path — `x420` has no alpha, so a transparent HDR
        // overlay would flatten to opaque. It is decoded through the alpha-bearing wide
        // `64RGBAHalf` format (AVAssetReader preserves the HLG/PQ SIGNAL + Rec.2020 tags
        // + the real alpha), then fitted premultiplied into the HLG canvas by CoreImage.
        let pixelFormat: OSType
        if deliversAlphaHDR {
            pixelFormat = kCVPixelFormatType_64RGBAHalf
        } else if deliversTenBit {
            pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        } else {
            pixelFormat = kCVPixelFormatType_32BGRA
        }
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw SourceError.mediaReaderFailed(reason: "cannot add video output")
        }
        reader.add(output)
        return (reader, output)
    }

    // MARK: Audio decode + emit (secondary)

    private func runAudioLoop(generation: UInt64, anchor: CMTime) {
        guard let audioTrack else {
            loopFinishedStopped(generation: generation)
            return
        }
        var loopBase = anchor
        if loopBase == .invalid { loopBase = HouseClock.now() }
        let exit = audioPlaythroughs(
            track: audioTrack,
            loopBase: &loopBase,
            generation: generation
        )
        switch exit {
        case .stopped:       loopFinishedStopped(generation: generation)
        case .eof:           loopFinishedEOF(generation: generation)
        case .failed(let e): loopFailed(e, generation: generation)
        }
    }

    private func audioPlaythroughs(
        track: AVAssetTrack,
        loopBase: inout CMTime,
        generation: UInt64
    ) -> LoopExit {
        while isRunning(generation: generation) {
            let reader: AVAssetReader
            let output: AVAssetReaderTrackOutput
            do { (reader, output) = try makeAudioReader(track: track) }
            catch {
                return .failed((error as? SourceError) ?? .mediaReaderFailed(reason: "\(error)"))
            }
            guard reader.startReading() else {
                return .failed(.mediaReaderFailed(reason: "audio startReading: \(String(describing: reader.error))"))
            }
            var firstPTS = CMTime.invalid
            var playedEnd = CMTime.zero
            var emittedThisPass = 0
            while isRunning(generation: generation) {
                guard let sample = output.copyNextSampleBuffer() else { break }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if firstPTS == .invalid { firstPTS = pts }
                let offset = CMTimeSubtract(pts, firstPTS)
                let target = CMTimeAdd(loopBase, offset)
                let dur = CMSampleBufferGetDuration(sample)
                paceUntil(target, generation: generation)
                if !isRunning(generation: generation) { break }
                // M1: re-stamp the buffer to its scheduled HOUSE time (the
                // AudioPacket contract), continuous across loops.
                let houseSample = retimed(sample, to: target, duration: dur)
                guard isRunning(generation: generation) else { break }
                onAudio?(AudioPacket(sampleBuffer: houseSample, source: id))
                emittedThisPass += 1
                if dur.isNumeric { playedEnd = CMTimeAdd(offset, dur) }
            }
            let status = reader.status
            let readerError = reader.error
            reader.cancelReading()

            if !isRunning(generation: generation) { return .stopped }
            if status == .failed {
                return .failed(.mediaReaderFailed(reason: "audio reader failed: \(String(describing: readerError))"))
            }
            if emittedThisPass == 0 {
                return .failed(.mediaReaderFailed(reason: "audio track produced no samples"))
            }
            guard loop else { return .eof }
            loopBase = CMTimeAdd(loopBase, playedEnd)
            let now = HouseClock.now()
            if CMTimeCompare(loopBase, now) < 0 { loopBase = now }
        }
        return .stopped
    }

    /// Copy `sample` with its presentation timestamp replaced by `target` (house
    /// time), preserving duration. One uniform timing entry re-stamps the whole
    /// buffer. Falls back to the original buffer if the copy fails.
    private func retimed(_ sample: CMSampleBuffer, to target: CMTime, duration: CMTime) -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: duration.isNumeric ? duration : .invalid,
                                        presentationTimeStamp: target,
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &out)
        if status == noErr, let out { return out }
        return sample
    }

    private func makeAudioReader(track: AVAssetTrack) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw SourceError.mediaReaderFailed(reason: "AVAssetReader(audio): \(error)") }
        // Interleaved Float32 LPCM — MixerChannel.ingest accepts any LPCM and
        // resamples to its internal 48 kHz stereo float.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else {
            throw SourceError.mediaReaderFailed(reason: "cannot add audio output")
        }
        reader.add(output)
        return (reader, output)
    }

    // MARK: Pacing

    /// Block the decode queue until house time reaches `target` (in small steps
    /// so `stop()` is observed promptly). Returns immediately if already due.
    private func paceUntil(_ target: CMTime, generation: UInt64) {
        while isRunning(generation: generation) {
            let delta = CMTimeSubtract(target, HouseClock.now()).seconds
            if !delta.isFinite || delta <= 0.0005 { return }
            Thread.sleep(forTimeInterval: min(delta, 0.05))
        }
    }

    // MARK: Async track loading (bridged to the sync init without deprecated APIs)

    private struct LoadedTracks {
        let video: AVAssetTrack
        let audio: AVAssetTrack?
        let transform: CGAffineTransform
        let naturalSize: CGSize
        let frameRate: Float
        let hasAlpha: Bool
        let isHDR: Bool
        let hdrIsPQ: Bool
    }

    /// Stage N: whether the video track is real HDR / wide-gamut — tagged with an
    /// HLG or PQ transfer function, or Rec.2020 primaries. Derived from the track's
    /// format-description colorimetry extensions (the same attachments AVFoundation
    /// puts on decoded buffers), a different signal than the codec/bit-depth alone.
    private static func detectHDR(formatDescriptions: [CMFormatDescription]) -> Bool {
        for desc in formatDescriptions {
            if let tf = CMFormatDescriptionGetExtension(
                desc, extensionKey: kCMFormatDescriptionExtension_TransferFunction) {
                let t = tf as AnyObject
                if CFEqual(t, kCVImageBufferTransferFunction_ITU_R_2100_HLG)
                    || CFEqual(t, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) { return true }
            }
            if let prim = CMFormatDescriptionGetExtension(
                desc, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) {
                if CFEqual(prim as AnyObject, kCVImageBufferColorPrimaries_ITU_R_2020) { return true }
            }
        }
        return false
    }

    /// sol #6 finding 1: whether the HDR clip's transfer is **PQ** (SMPTE ST 2084),
    /// as opposed to HLG or an untagged-transfer Rec.2020 clip. A PQ clip must be
    /// delivered PQ-tagged (not forced through the HLG canvas, which PQ→HLG
    /// tone-maps it); a Rec.2020-primaries-only clip (no HDR transfer tag) stays on
    /// the HLG default. Derived from the same format-description transfer extension.
    private static func detectPQ(formatDescriptions: [CMFormatDescription]) -> Bool {
        for desc in formatDescriptions {
            if let tf = CMFormatDescriptionGetExtension(
                desc, extensionKey: kCMFormatDescriptionExtension_TransferFunction),
               CFEqual(tf as AnyObject, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) {
                return true
            }
        }
        return false
    }

    /// Whether the video track's codec carries a real alpha channel (ProRes 4444 /
    /// 4444 XQ, or a format description that declares an alpha component). The App
    /// uses this to set the source's scene `Layer.premultipliedAlpha` — otherwise a
    /// transparent ProRes 4444 clip's alpha is forced to 1 by the compositor and it
    /// covers the layers beneath with opaque black (Class C). Derived once at load.
    private static func detectAlpha(formatDescriptions: [CMFormatDescription]) -> Bool {
        for desc in formatDescriptions {
            let codec = CMFormatDescriptionGetMediaSubType(desc)
            // ProRes 4444 ('ap4h') and ProRes 4444 XQ ('ap4x') carry alpha.
            if codec == kCMVideoCodecType_AppleProRes4444
                || codec == kCMVideoCodecType_AppleProRes4444XQ { return true }
            // Any format that explicitly declares it contains an alpha channel.
            if let ext = CMFormatDescriptionGetExtension(
                desc, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel),
               let flag = ext as? Bool, flag { return true }
        }
        return false
    }

    private final class ResultBox<T>: @unchecked Sendable { var value: Result<T, Error>? }

    /// Loads the tracks + orientation props via the modern async `load` API and
    /// blocks the (setup-time, not hot-path) caller on a semaphore — avoids the
    /// deprecated synchronous `AVAsset`/`AVAssetTrack` accessors (zero warnings).
    private static func loadTracks(asset: AVURLAsset, path: String) throws -> LoadedTracks {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<LoadedTracks>()
        Task {
            do {
                let videos = try await asset.loadTracks(withMediaType: .video)
                guard let video = videos.first else {
                    throw SourceError.mediaHasNoVideoTrack(path: path)
                }
                let audios = try await asset.loadTracks(withMediaType: .audio)
                let transform = try await video.load(.preferredTransform)
                let natural = try await video.load(.naturalSize)
                let rate = try await video.load(.nominalFrameRate)
                let formats = (try? await video.load(.formatDescriptions)) ?? []
                let hasAlpha = detectAlpha(formatDescriptions: formats)
                let isHDR = detectHDR(formatDescriptions: formats)
                let hdrIsPQ = detectPQ(formatDescriptions: formats)
                box.value = .success(LoadedTracks(video: video, audio: audios.first,
                                                  transform: transform, naturalSize: natural,
                                                  frameRate: rate, hasAlpha: hasAlpha,
                                                  isHDR: isHDR, hdrIsPQ: hdrIsPQ))
            } catch {
                box.value = .failure(error)
            }
            sem.signal()
        }
        sem.wait()
        switch box.value {
        case .success(let v): return v
        // M7: preserve typed SourceError cases (e.g. `.mediaHasNoVideoTrack`)
        // instead of blanket-wrapping them as `.mediaLoadFailed`.
        case .failure(let e as SourceError): throw e
        case .failure(let e): throw SourceError.mediaLoadFailed(path: path, underlying: e)
        case .none: throw SourceError.mediaLoadFailed(path: path, underlying: nil)
        }
    }
}
