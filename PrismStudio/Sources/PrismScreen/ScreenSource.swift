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
    private let target: ScreenTarget
    private var stream: SCStream?
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

        Task { [weak self] in
            await self?.resolveAndStart()
        }
    }

    /// Non-blocking. Stops the stream on a background task, then → `.idle`.
    public func stop() {
        let shouldStop = stateLock.withLock { state -> Bool in
            guard state == .starting || state == .running else { return false }
            state = .stopping
            return true
        }
        guard shouldStop else { return }

        let stream = self.stream
        self.stream = nil
        Task { [weak self] in
            if let stream {
                do { try await stream.stopCapture() }
                catch { self?.log.debug("stopCapture: \(error.localizedDescription) (already stopped?)") }
            }
            self?.setState(.idle)
        }
    }

    // MARK: - Async start path

    private func resolveAndStart() async {
        do {
            // Off-screen windows included so minimized/occluded windows stay capturable.
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            let filter = try makeFilter(content: content)
            let streamConfig = makeStreamConfiguration(filter: filter)

            // stop() may have raced us while we were resolving.
            guard state == .starting else { return }

            let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
            if configuration.videoEnabled {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            }
            if configuration.capturesAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            }
            self.stream = stream
            try await stream.startCapture()

            guard state == .starting else {
                // stop() raced startCapture; unwind.
                try? await stream.stopCapture()
                return
            }
            setState(.running)
            onStarted?()
            log.info("running: \(self.descriptor.id) \(streamConfig.width)x\(streamConfig.height) @\(self.configuration.targetFPS)fps audio=\(self.configuration.capturesAudio)")
        } catch {
            self.stream = nil
            setState(.failed)
            log.error("start failed for \(self.descriptor.id): \(error.localizedDescription)")
            onError?(error)
        }
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
}

// MARK: - SCStreamOutput / SCStreamDelegate

extension ScreenSource: SCStreamOutput, SCStreamDelegate {

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
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
        self.stream = nil
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
