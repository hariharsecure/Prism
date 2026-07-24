import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import PrismCore
import ScreenCaptureKit
import os

/// Tuning knobs for a `ScreenSource`. Defaults match the program target
/// (1080p60 pipeline, DESIGN.md §3.5).
public struct ScreenCaptureConfiguration: Sendable {
    /// Target capture rate → `SCStreamConfiguration.minimumFrameInterval`.
    public var targetFPS: Int
    /// Draw the cursor into captured frames.
    public var showsCursor: Bool
    /// Capture app audio alongside video (`SCStreamConfiguration.capturesAudio`).
    public var capturesAudio: Bool
    /// Keep our own process out of the captured mix (avoids feedback loops).
    public var excludesCurrentProcessAudio: Bool
    /// Audio sample rate (SCK supports 48000/24000/16000/8000).
    public var audioSampleRate: Int
    /// Audio channel count (1 or 2).
    public var audioChannelCount: Int
    /// SCK internal frame queue depth. 5 = SCK's recommended live default:
    /// deep enough to absorb render-loop jitter, shallow enough not to add latency.
    public var queueDepth: Int
    /// When false, no video output is attached and the stream is configured
    /// minimal (2×2 @1fps) — used for app-audio-only capture.
    public var videoEnabled: Bool
    /// Stage N: request HDR / 10-bit capture when supported (macOS 15+). When on and
    /// available, the stream captures 10-bit packed `l10r` in HDR dynamic range
    /// (`SCCaptureDynamicRange.hdrLocalDisplay`), tagged HLG/Rec.2020, instead of
    /// forcing 8-bit `420f`. Off (default) keeps the byte-identical SDR path — HDR
    /// preservation only kicks in for a real HDR display, so SDR shows never regress.
    public var preferHDR: Bool

    public init(
        targetFPS: Int = 60,
        showsCursor: Bool = true,
        capturesAudio: Bool = true,
        excludesCurrentProcessAudio: Bool = true,
        audioSampleRate: Int = 48_000,
        audioChannelCount: Int = 2,
        queueDepth: Int = 5,
        videoEnabled: Bool = true,
        preferHDR: Bool = false
    ) {
        self.targetFPS = max(1, targetFPS)
        self.showsCursor = showsCursor
        self.capturesAudio = capturesAudio
        self.excludesCurrentProcessAudio = excludesCurrentProcessAudio
        self.audioSampleRate = audioSampleRate
        self.audioChannelCount = audioChannelCount
        self.queueDepth = max(3, queueDepth)
        self.videoEnabled = videoEnabled
        self.preferHDR = preferHDR
    }
}

/// ScreenCaptureKit ingest: one class captures a display, an independent
/// window, or an application (video and/or app audio) selected by a
/// `SourceDescriptor` from `ScreenContentBrowser`.
///
/// Emits:
///  - `VideoFrame` per complete SCK frame (`onFrame`) — `420f` bi-planar YUV,
///    IOSurface-backed (SCK guarantees this), PTS passed through untouched
///    (SCK stamps on the host clock == `HouseClock.clock`).
///  - `AudioPacket` per audio buffer (`onAudio`) when `capturesAudio` is on.
///
/// Pixel format is `420f` (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange):
/// DESIGN.md §3.5 — the compositor samples bi-planar YUV directly in the
/// fragment shader, and 4:2:0 is half the memory bandwidth of BGRA at 4K60.
/// Stage N: with `preferHDR` on and macOS 15+, an HDR display is instead captured
/// as 10-bit packed `l10r` in HDR dynamic range (tagged HLG/Rec.2020) so real HDR
/// reaches the compositor; SDR captures stay on the byte-identical `420f` path.
///
/// Lifecycle: `start()` is non-blocking — it resolves shareable content and
/// starts the SCStream on a background task (`.starting` → `.running`, or
/// `.failed` + `onError` on any failure, including mid-capture stops via
/// `SCStreamDelegate`). Starting triggers the Screen Recording TCC prompt
/// on first use.
public final class ScreenSource: NSObject, VideoSource, AudioSource, @unchecked Sendable {

    // MARK: Identity & configuration

    public let id: SourceID
    public let descriptor: SourceDescriptor
    public let configuration: ScreenCaptureConfiguration

    // MARK: Callbacks (set before start(); invoked on the capture queues)

    /// Video frames. Called on the video sample-handler queue.
    public var onFrame: ((VideoFrame) -> Void)?
    /// App audio packets. Called on the audio sample-handler queue.
    public var onAudio: ((AudioPacket) -> Void)?
    /// Async failures: start failure or mid-capture stop (`didStopWithError`).
    public var onError: ((Error) -> Void)?
    /// Async success: the SCStream's `startCapture()` completed and the source is
    /// `.running`. Lets a caller keep a working predecessor alive until the
    /// replacement's async start CONFIRMS success (sol #6 #7), rather than tearing
    /// the old one down up-front and being left with nothing if the start fails.
    public var onStarted: (() -> Void)?

    // MARK: State

    public var state: SourceState { stateLock.withLock { $0 } }

    private let stateLock = OSAllocatedUnfairLock<SourceState>(initialState: .idle)
    /// Monotonic lifecycle generation. `start()` arms a fresh generation and hands
    /// it to the async `resolveAndStart`; `stop()` retires it. Because the start
    /// path is async, a `stop()`+`start()` can race an in-flight `resolveAndStart`:
    /// the retired task would otherwise pass the bare `state == .starting` check
    /// (the RESTART set `.starting` again) and commit its stale stream over the
    /// live one. Gating every async step on the captured generation drops the
    /// retired task instead. It also drops SCK samples that a torn-down stream
    /// keeps delivering across the boundary.
    private let generation = GenerationGate()
    /// The generation the CURRENTLY-running stream belongs to (read on the sample
    /// queues, written when a start commits to `.running`).
    private let runningGeneration = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    /// sol #6 — ONE lifecycle box serializing the published stream, the in-flight
    /// START task, and the teardown (stop) task under a single lock. Folding these
    /// together closes the start-after-shutdown / erase-successor races:
    ///  - the published stream is tagged with the generation it belongs to, so a
    ///    retiring start / a stop teardown clears it ONLY when it is that run's
    ///    stream (never a fast successor's), and
    ///  - a teardown AWAITS the in-flight start task (not just a stop task), so a
    ///    start that is mid-`startCapture()` past the shutdown barrier is joined
    ///    instead of leaking a live capture past process exit.
    private struct LifecycleBoxes {
        /// The currently-published SCStream (nil until a start publishes, cleared on
        /// teardown / a retired start's self-cleanup).
        var stream: SCStream?
        /// The generation `stream` was published under — the identity a retiring
        /// path matches on so it never clears a successor's stream.
        var streamGeneration: UInt64 = 0
        /// The most recent in-flight START task (awaited by a teardown so the barrier
        /// joins a start mid-`startCapture()`).
        var startTask: Task<Void, Never>?
        /// The most recent teardown task (awaited by `awaitTeardown()`).
        var stopTask: Task<Void, Never>?
    }
    private let lifecycle = OSAllocatedUnfairLock<LifecycleBoxes>(initialState: LifecycleBoxes())
    private let target: ScreenTarget
    private let videoQueue = DispatchQueue(label: "studio.prism.screen.video")
    private let audioQueue = DispatchQueue(label: "studio.prism.screen.audio")
    private let log = EngineLog.logger("screen")

    // MARK: Init

    /// Build a source from a browser descriptor. Throws `.invalidDescriptor`
    /// if the descriptor isn't a screen kind or its id doesn't parse.
    public init(descriptor: SourceDescriptor,
                configuration: ScreenCaptureConfiguration = ScreenCaptureConfiguration()) throws {
        self.target = try ScreenTarget(descriptor: descriptor)
        self.descriptor = descriptor
        self.configuration = configuration
        self.id = SourceID(descriptor.id)
        super.init()
    }

    /// Convenience: capture ONLY the audio of one application — no video
    /// output, minimal (2×2 @1fps) video config under the hood. The class
    /// still conforms to `VideoSource` but `onFrame` never fires.
    public static func appAudioOnly(bundleID: String,
                                    name: String? = nil,
                                    excludesCurrentProcessAudio: Bool = true) throws -> ScreenSource {
        let descriptor = SourceDescriptor(
            kind: .application,
            id: "app:\(bundleID)",
            name: name ?? bundleID,
            detail: "audio-only"
        )
        var config = ScreenCaptureConfiguration()
        config.videoEnabled = false
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = excludesCurrentProcessAudio
        return try ScreenSource(descriptor: descriptor, configuration: config)
    }

    // MARK: Lifecycle

    /// Non-blocking. Transitions `.idle/.failed` → `.starting`, then resolves
    /// content and starts the SCStream asynchronously (→ `.running` or
    /// `.failed` + `onError`).
    public func start() throws {
        let ok = stateLock.withLock { state -> Bool in
            guard state == .idle || state == .failed else { return false }
            state = .starting
            return true
        }
        guard ok else { throw ScreenSourceError.notIdle(state) }

        // Arm a fresh generation for THIS start and hand it to the async task so a
        // stop/restart that races the resolve retires this attempt (the successor
        // owns a newer generation). Store the task under the lifecycle lock so a
        // concurrent stop can AWAIT it (sol #6 — teardown joins an in-flight start).
        let gen = generation.bump()
        let task = Task { [weak self] () -> Void in
            await self?.resolveAndStart(generation: gen)
        }
        lifecycle.withLock { $0.startTask = task }
    }

    /// Non-blocking. Stops the stream on a background task, then → `.idle`. sol #6:
    /// the teardown AWAITS the in-flight start task before tearing down, so a start
    /// that is mid-`startCapture()` is joined (never left to install + start a
    /// capture AFTER the shutdown barrier), and it stops the published stream ONLY
    /// when that stream still belongs to a RETIRED run (never a fast successor's).
    public func stop() {
        let shouldStop = stateLock.withLock { state -> Bool in
            guard state == .starting || state == .running else { return false }
            state = .stopping
            return true
        }
        guard shouldStop else { return }

        // Retire the running generation: an in-flight `resolveAndStart` and any
        // sample a torn-down stream still delivers now fail the generation check.
        generation.bump()

        let inFlightStart = lifecycle.withLock { $0.startTask }
        let task = Task { [weak self] in
            // Join the in-flight start FIRST (sol #6 race (a)): a start past its early
            // generation check must finish (and, being retired, unwind its own stream)
            // before the barrier completes — never install a live capture afterwards.
            await inFlightStart?.value
            guard let self else { return }
            // Take the published stream ONLY if it is a retired run's — a fast
            // successor (a restart that already re-published) owns the live one.
            let live = self.generation.current
            let stream = self.lifecycle.withLock { boxes -> SCStream? in
                guard let s = boxes.stream,
                      Self.teardownMayStopPublishedStream(publishedGeneration: boxes.streamGeneration,
                                                          live: live) else { return nil }
                boxes.stream = nil
                return s
            }
            if let stream {
                do { try await stream.stopCapture() }
                catch { self.log.debug("stopCapture: \(error.localizedDescription) (already stopped?)") }
            }
            self.setState(.idle)
        }
        lifecycle.withLock { $0.stopTask = task }
    }

    /// Await the async SCStream teardown kicked off by the most recent `stop()`
    /// (2c external-output barrier). Because the teardown task itself awaits the
    /// in-flight START task, this transitively joins a start that is mid-
    /// `startCapture()` (sol #6). Returns immediately when no stop is in flight.
    /// Safe to call after `stop()` on any actor/thread.
    public func awaitTeardown() async {
        let task = lifecycle.withLock { $0.stopTask }
        await task?.value
    }

    // MARK: - Async start path

    private func resolveAndStart(generation gen: UInt64) async {
        // The stream THIS attempt published (nil until publication). A retiring path
        // clears `lifecycle.stream` ONLY when it still holds this exact stream —
        // matched on the generation it was published under — so a slow/retired start
        // can never erase a successor's freshly-published stream (sol #6 race (b)).
        var ourStream: SCStream?

        do {
            // Off-screen windows included so minimized/occluded windows stay capturable.
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            let filter = try makeFilter(content: content)
            let streamConfig = makeStreamConfiguration(filter: filter)

            // A stop() — or a stop()+restart() — may have retired this attempt while
            // we were resolving. Gate on the generation, not the bare state: a
            // RESTART sets `.starting` again, so `state == .starting` would wrongly
            // let this retired task proceed and commit its stale stream.
            guard Self.startMayCommit(captured: gen, live: generation.current) else { return }

            let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
            ourStream = stream
            if configuration.videoEnabled {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            }
            if configuration.capturesAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            }

            // Publish under the lifecycle lock, but ONLY if still current. A stop()
            // that bumped the generation retires us here → do not publish; unwind.
            let published = lifecycle.withLock { boxes -> Bool in
                guard Self.startMayCommit(captured: gen, live: generation.current) else { return false }
                boxes.stream = stream
                boxes.streamGeneration = gen
                return true
            }
            guard published else {
                try? await stream.stopCapture()   // never went live; symmetric cleanup
                return
            }

            try await stream.startCapture()

            // Re-check after the async start. If retired mid-`startCapture()`, clear
            // ONLY our own published stream and tear it down (never a successor's).
            let stillCurrent = lifecycle.withLock { boxes -> Bool in
                guard Self.startMayCommit(captured: gen, live: generation.current) else {
                    if boxes.stream === stream,
                       Self.mayClearPublishedStream(publishedGeneration: boxes.streamGeneration,
                                                    retiringGeneration: gen) {
                        boxes.stream = nil
                    }
                    return false
                }
                return true
            }
            guard stillCurrent else {
                try? await stream.stopCapture()
                return
            }
            // Publish the generation frames must match BEFORE going live.
            runningGeneration.withLock { $0 = gen }
            setState(.running)
            onStarted?()
            log.info("running: \(self.descriptor.id) \(streamConfig.width)x\(streamConfig.height) @\(self.configuration.targetFPS)fps audio=\(self.configuration.capturesAudio)")
        } catch {
            // A retired attempt that failed must not clobber the live run's state or
            // fire a stale onError into the successor — but it must still unwind its
            // OWN published stream.
            clearStreamIfStillPublished(ourStream, retiringGeneration: gen)
            guard Self.startMayCommit(captured: gen, live: generation.current) else { return }
            setState(.failed)
            log.error("start failed for \(self.descriptor.id): \(error.localizedDescription)")
            onError?(error)
        }
    }

    /// Clear `lifecycle.stream` ONLY when it still holds the exact stream `s` this
    /// attempt published (matched on the retiring generation) — never a successor's.
    private func clearStreamIfStillPublished(_ s: SCStream?, retiringGeneration gen: UInt64) {
        guard let s else { return }
        lifecycle.withLock { boxes in
            if boxes.stream === s,
               Self.mayClearPublishedStream(publishedGeneration: boxes.streamGeneration,
                                            retiringGeneration: gen) {
                boxes.stream = nil
            }
        }
    }

    // MARK: - Pure lifecycle decisions (sol #6 — unit-testable without ScreenCaptureKit)

    /// A resumed/awaited start attempt may COMMIT (publish its stream, go running)
    /// ONLY while its captured generation is still the live one; a retired attempt
    /// (a stop/restart bumped past it) must drop.
    static func startMayCommit(captured: UInt64, live: UInt64) -> Bool {
        GenerationGate.accepts(live: live, captured: captured)
    }

    /// A retiring START (or its failure path) may clear the published stream ONLY
    /// when that stream is the one THIS attempt published — never a successor's.
    /// The generation the stream was published under is the identity (each
    /// generation publishes at most one stream, so this matches object identity).
    static func mayClearPublishedStream(publishedGeneration: UInt64, retiringGeneration: UInt64) -> Bool {
        publishedGeneration == retiringGeneration
    }

    /// A stop TEARDOWN may stop the published stream ONLY when it belongs to a
    /// RETIRED run (not a fast successor that already re-published the live one).
    static func teardownMayStopPublishedStream(publishedGeneration: UInt64, live: UInt64) -> Bool {
        !GenerationGate.accepts(live: live, captured: publishedGeneration)
    }

    private func makeFilter(content: SCShareableContent) throws -> SCContentFilter {
        switch target {
        case .display(let displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenSourceError.contentNotFound(descriptor.id)
            }
            return SCContentFilter(display: display, excludingWindows: [])

        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw ScreenSourceError.contentNotFound(descriptor.id)
            }
            return SCContentFilter(desktopIndependentWindow: window)

        case .application(let bundleID):
            guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
                throw ScreenSourceError.contentNotFound(descriptor.id)
            }
            // App capture is anchored on a display; prefer the main one.
            let display = content.displays.first(where: { CGDisplayIsMain($0.displayID) != 0 })
                ?? content.displays.first
            guard let display else { throw ScreenSourceError.noDisplayAvailable }
            return SCContentFilter(display: display, including: [app], exceptingWindows: [])
        }
    }

    /// Whether ScreenCaptureKit HDR capture is available on this OS (macOS 15+).
    static var hdrCaptureSupported: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// The capture pixel format (pure — unit-tested): 10-bit packed `l10r` when HDR
    /// is requested AND supported, else 8-bit `420f`. `l10r` is what the compositor's
    /// wave-5b ingest gate accepts for ScreenCaptureKit HDR.
    static func streamPixelFormat(preferHDR: Bool, hdrSupported: Bool) -> OSType {
        (preferHDR && hdrSupported) ? kCVPixelFormatType_ARGB2101010LEPacked
                                    : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    private func makeStreamConfiguration(filter: SCContentFilter) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        // SDR: '420f' (see class doc). HDR (macOS 15+, preferHDR): 10-bit 'l10r'.
        // SCK delivers both IOSurface-backed.
        let useHDR = configuration.videoEnabled && configuration.preferHDR && Self.hdrCaptureSupported
        config.pixelFormat = Self.streamPixelFormat(preferHDR: configuration.videoEnabled && configuration.preferHDR,
                                                    hdrSupported: Self.hdrCaptureSupported)
        config.queueDepth = configuration.queueDepth
        config.showsCursor = configuration.showsCursor

        if useHDR, #available(macOS 15.0, *) {
            // Capture the display's true dynamic range; SCK stamps the buffers with
            // HLG / Rec.2020 colorimetry, which flows through to the compositor tags.
            config.captureDynamicRange = .hdrLocalDisplay
            config.colorSpaceName = CGColorSpace.itur_2100_HLG
        }

        if configuration.videoEnabled {
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.targetFPS))
            // Native pixel size of the filtered content (points × backing scale),
            // rounded down to even — 4:2:0 chroma wants even dimensions.
            let scale = CGFloat(filter.pointPixelScale)
            let width = Int(filter.contentRect.width * scale) & ~1
            let height = Int(filter.contentRect.height * scale) & ~1
            config.width = max(2, width)
            config.height = max(2, height)
        } else {
            // Audio-only: keep the mandatory video path as cheap as possible.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.showsCursor = false
        }

        if configuration.capturesAudio {
            config.capturesAudio = true
            config.sampleRate = configuration.audioSampleRate
            config.channelCount = configuration.audioChannelCount
            config.excludesCurrentProcessAudio = configuration.excludesCurrentProcessAudio
        }
        return config
    }

    // MARK: - Helpers

    private func setState(_ new: SourceState) {
        stateLock.withLock { $0 = new }
    }

    #if DEBUG
    /// The live lifecycle generation (proves a stop→start advances it).
    public var _test_generation: UInt64 { generation.current }

    /// sol #6 test seam (headless — no ScreenCaptureKit): inject a fake in-flight
    /// START task so a test can prove a teardown/`awaitTeardown()` JOINS it before
    /// completing (a start that is mid-`startCapture()` past the shutdown barrier).
    public func _test_setInFlightStartTask(_ task: Task<Void, Never>) {
        lifecycle.withLock { $0.startTask = task }
    }

    /// sol #6 test seam (headless): run the SAME teardown ordering as `stop()` — bump
    /// the generation, capture the in-flight start task, then a stop task that AWAITS
    /// it before finishing to `.idle` — WITHOUT touching a real SCStream. Lets a test
    /// assert `awaitTeardown()` does not return until the injected start completes.
    public func _test_beginTeardownAwaitingStart() {
        stateLock.withLock { $0 = .stopping }
        generation.bump()
        let inFlightStart = lifecycle.withLock { $0.startTask }
        let task = Task { [weak self] in
            await inFlightStart?.value
            self?.setState(.idle)
        }
        lifecycle.withLock { $0.stopTask = task }
    }
    #endif
}

// MARK: - SCStreamOutput / SCStreamDelegate

extension ScreenSource: SCStreamOutput, SCStreamDelegate {

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Drop a sample that crossed a stop/restart boundary: it must come from the
        // live stream AND the running generation, or it is a straggler from a
        // retired run posting into the successor.
        let live = lifecycle.withLock { $0.stream }
        guard stream === live else { return }
        let armed = runningGeneration.withLock { $0 }
        guard generation.isCurrent(armed) else { return }
        guard state == .running, CMSampleBufferIsValid(sampleBuffer) else { return }
        switch type {
        case .screen:
            handleVideo(sampleBuffer)
        case .audio:
            onAudio?(AudioPacket(sampleBuffer: sampleBuffer, source: id))
        default:
            break // .microphone (macOS 15+) — not used by this source
        }
    }

    /// Mid-capture stop (window closed, app quit, permission revoked, display
    /// disconnected) → `.failed` + `onError`.
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Only the live stream may fail the source: a retired stream's async stop
        // error must not knock down the successor run. Clear the published stream
        // ONLY when it is this exact live stream AND its run is still current.
        let armed = runningGeneration.withLock { $0 }
        let cleared = lifecycle.withLock { boxes -> Bool in
            guard boxes.stream === stream, generation.isCurrent(armed) else { return false }
            boxes.stream = nil
            return true
        }
        guard cleared else { return }
        setState(.failed)
        log.error("stream stopped: \(self.descriptor.id): \(error.localizedDescription)")
        onError?(error)
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        // SCK marks non-content frames via SCStreamFrameInfo.status; only
        // .complete carries real pixels (skip .idle, .blank, .started, …).
        guard
            let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]])?.first,
            let statusRaw = attachments[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRaw),
            status == .complete
        else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard CVPixelBufferGetIOSurface(pixelBuffer) != nil else {
            // Should never happen — SCK frames are IOSurface-backed. Guard so a
            // pathological frame is dropped instead of tripping the graph assert.
            log.fault("dropped non-IOSurface frame from \(self.descriptor.id)")
            return
        }

        // PTS is SCK's host-clock stamp == house time (DESIGN.md §3.3): pass through.
        let frame = VideoFrame(
            pixelBuffer: pixelBuffer,
            pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            duration: CMSampleBufferGetDuration(sampleBuffer),
            source: id
        )
        onFrame?(frame)
    }
}
