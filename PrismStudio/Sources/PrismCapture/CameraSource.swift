import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import PrismCore

/// One supported device format (dimensions + fps ranges), stable-indexed
/// into `AVCaptureDevice.formats`.
public struct CameraFormatDescriptor: Sendable, CustomStringConvertible {
    /// Index into the device's `formats` array — pass back to `select(formatIndex:frameRate:)`.
    public let index: Int
    public let width: Int
    public let height: Int
    /// Native media subtype of the format (e.g. '420v', '420f'). The data
    /// output still delivers `CameraSource.outputPixelFormat` regardless.
    public let mediaSubType: OSType
    public let frameRateRanges: [FrameRateRange]

    public struct FrameRateRange: Sendable, Codable, Hashable {
        public let min: Double
        public let max: Double
    }

    public var maxFrameRate: Double { frameRateRanges.map(\.max).max() ?? 0 }

    public var description: String {
        let fps = frameRateRanges
            .map { $0.min == $0.max ? "\(Int($0.max))" : "\(Int($0.min))–\(Int($0.max))" }
            .joined(separator: ",")
        return "[\(index)] \(width)×\(height) '\(FourCC.string(mediaSubType))' \(fps) fps"
    }
}

/// A Mac camera (built-in, USB/UVC capture card, Continuity Camera) as a
/// `VideoSource`: one `AVCaptureSession` + `AVCaptureVideoDataOutput` per device.
///
/// Output: `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` ('420f'),
/// IOSurface-backed and Metal-compatible; late frames are discarded
/// (live compositing never queues deep — DESIGN.md §3.3).
///
/// Clock rule (§3.3): emitted PTS are house time. AVCaptureSession normally
/// synchronizes to the host clock already; the delegate checks
/// `session.synchronizationClock` each callback and converts with
/// `CMSyncConvertTime` if it ever differs, so the invariant holds even on
/// exotic device clocks.
///
/// Thread model: call `start()`/`stop()`/`select(...)` from one control
/// thread. `onFrame` fires on the source's private capture queue.
/// `start()` blocks until the session is running and WILL trigger the
/// camera TCC prompt on first use.
public final class CameraSource: NSObject, VideoSource {
    /// The SDR default / fallback capture format ('420f', 8-bit full range).
    /// Stage N: when the device's selected format is itself 10-bit (HDR / wide-gamut)
    /// and the data output advertises a 10-bit type, the source instead requests a
    /// 10-bit output (`x420`/`xf20`) — see `preferredOutputFormat`. The device's
    /// colorimetry attachments ride the delivered buffers unchanged either way.
    public static let outputPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

    /// The 10-bit 4:2:0 bi-planar capture subtypes ('x420' video-range / 'xf20'
    /// full-range) — a device advertising one of these natively produces 10-bit.
    static func isTenBitBiplanar(_ subtype: OSType) -> Bool {
        subtype == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || subtype == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    }

    /// Choose the capture output pixel format (pure — unit-tested without hardware).
    /// Prefer a 10-bit output ONLY when the selected device format is itself 10-bit
    /// AND the data output advertises a 10-bit type, so a real 10-bit HDR/wide-gamut
    /// device is not force-truncated to 8-bit; otherwise the SDR default. Video-range
    /// 10-bit is preferred (HDR/broadcast is video range), then full-range.
    static func preferredOutputFormat(activeIsTenBit: Bool, available: [OSType]) -> OSType {
        guard activeIsTenBit else { return outputPixelFormat }
        if available.contains(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) {
            return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
        if available.contains(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange) {
            return kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        }
        return outputPixelFormat
    }

    /// The pixel format the running session was configured to deliver (SDR '420f'
    /// until `start()` selects a 10-bit output for a 10-bit device format).
    public private(set) var activeOutputFormat: OSType = CameraSource.outputPixelFormat

    public let id: SourceID
    public private(set) var state: SourceState = .idle
    public var onFrame: ((VideoFrame) -> Void)?

    /// UI-facing descriptor for this device (name/model/capabilities).
    public var descriptor: SourceDescriptor { CaptureDeviceManager.descriptor(for: device) }

    private let device: AVCaptureDevice
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let captureQueue: DispatchQueue
    private let log = EngineLog.logger("capture.camera")
    private let signposter = EngineLog.signposter("capture.camera")

    private var configured = false
    private var runtimeErrorObserver: NSObjectProtocol?
    private var selectedFormatIndex: Int?
    private var selectedFrameRate: Double?
    private var warnedNonIOSurface = false
    private var warnedClockConversion = false

    /// - Parameter deviceID: `AVCaptureDevice.uniqueID` (the `SourceDescriptor.id`
    ///   from `CaptureDeviceManager.videoDevices()`).
    public init(deviceID: String) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID), device.hasMediaType(.video) else {
            throw CaptureError.deviceNotFound(uniqueID: deviceID)
        }
        self.device = device
        self.id = SourceID(deviceID)
        self.captureQueue = DispatchQueue(label: "studio.prism.capture.camera.\(deviceID)")
        super.init()
    }

    /// Wrap an already-resolved device (e.g. straight from a discovery session).
    public convenience init(device: AVCaptureDevice) throws {
        try self.init(deviceID: device.uniqueID)
    }

    deinit {
        if let token = runtimeErrorObserver { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: - Formats

    /// The device's supported formats (dims/fps), in device order.
    public var formats: [CameraFormatDescriptor] {
        Self.formatDescriptors(for: device)
    }

    /// Whether the format we will capture with (the selected index, else the
    /// device's current active format) natively produces 10-bit samples.
    private func probedFormatIsTenBit() -> Bool {
        let format = selectedFormatIndex.flatMap {
            device.formats.indices.contains($0) ? device.formats[$0] : nil
        } ?? device.activeFormat
        return Self.isTenBitBiplanar(CMFormatDescriptionGetMediaSubType(format.formatDescription))
    }

    public static func formatDescriptors(for device: AVCaptureDevice) -> [CameraFormatDescriptor] {
        device.formats.enumerated().map { index, format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return CameraFormatDescriptor(
                index: index,
                width: Int(dims.width),
                height: Int(dims.height),
                mediaSubType: CMFormatDescriptionGetMediaSubType(format.formatDescription),
                frameRateRanges: format.videoSupportedFrameRateRanges.map {
                    .init(min: $0.minFrameRate, max: $0.maxFrameRate)
                }
            )
        }
    }

    /// Select a device format (by `CameraFormatDescriptor.index`) and optional
    /// fixed frame rate. Applies immediately when possible and is re-applied
    /// during `start()` (adding an input can reset a device's active format).
    /// Pass `formatIndex: nil` to keep the device's current format and only
    /// pin the frame rate.
    public func select(formatIndex: Int?, frameRate: Double? = nil) throws {
        if let idx = formatIndex {
            guard device.formats.indices.contains(idx) else {
                throw CaptureError.formatIndexOutOfRange(idx)
            }
        }
        selectedFormatIndex = formatIndex
        selectedFrameRate = frameRate
        try applySelection()
    }

    private func applySelection() throws {
        guard selectedFormatIndex != nil || selectedFrameRate != nil else { return }
        do {
            try device.lockForConfiguration()
        } catch {
            throw CaptureError.configurationFailed(device: device.localizedName, underlying: error)
        }
        defer { device.unlockForConfiguration() }

        if let idx = selectedFormatIndex {
            guard device.formats.indices.contains(idx) else {
                throw CaptureError.formatIndexOutOfRange(idx)
            }
            device.activeFormat = device.formats[idx]
        }
        if let fps = selectedFrameRate {
            try Self.applyFrameRate(fps, to: device)
        }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        log.info("format applied: \(dims.width)×\(dims.height) fps=\(self.selectedFrameRate.map(String.init(describing:)) ?? "device-default", privacy: .public)")
        // sol #5 #8: the output's requested pixel format was chosen ONCE at first
        // configuration; a later SDR↔10-bit reselection left the stale format.
        // Re-apply it from the CURRENT selection on every format change.
        reapplyOutputFormatIfNeeded()
    }

    /// Re-resolve the data output's requested pixel format from the *current*
    /// selected/active device format and re-apply it if it changed (sol #5 #8).
    /// No-op until the session is configured (the output exists) and when the
    /// format is unchanged (the steady-state fast path). The session is
    /// re-configured around the mutation so it is safe while running.
    private func reapplyOutputFormatIfNeeded() {
        guard configured else { return }
        let available = output.availableVideoPixelFormatTypes
        let chosen = Self.preferredOutputFormat(activeIsTenBit: probedFormatIsTenBit(), available: available)
        guard available.contains(chosen), chosen != activeOutputFormat else { return }
        session.beginConfiguration()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: chosen,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        session.commitConfiguration()
        activeOutputFormat = chosen
        log.info("camera output format re-applied on reselection: '\(FourCC.string(chosen), privacy: .public)'")
    }

    /// Pin the frame duration for `fps` on the device's *active* format.
    /// Caller must hold `lockForConfiguration`.
    private static func applyFrameRate(_ fps: Double, to device: AVCaptureDevice) throws {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        let epsilon = 0.01
        guard let range = ranges.first(where: {
            fps >= $0.minFrameRate - epsilon && fps <= $0.maxFrameRate + epsilon
        }) else {
            throw CaptureError.frameRateUnsupported(fps)
        }
        // Use the range's exact endpoint durations when fps matches an endpoint
        // (avoids float-rounding rejections for rates like 29.97).
        let duration: CMTime
        if abs(fps - range.maxFrameRate) < epsilon {
            duration = range.minFrameDuration
        } else if abs(fps - range.minFrameRate) < epsilon {
            duration = range.maxFrameDuration
        } else {
            duration = CMTime(value: 1000, timescale: CMTimeScale((fps * 1000).rounded()))
        }
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    // MARK: - Lifecycle

    /// Configure and start the capture session. Blocks until running.
    /// Triggers the camera TCC prompt on first use — never call in automated
    /// verification.
    public func start() throws {
        guard state == .idle || state == .failed else { return }
        state = .starting
        do {
            try configureSessionIfNeeded()
            try applySelection()
        } catch {
            state = .failed
            throw error
        }
        session.startRunning()
        state = .running
        log.info("camera running: \(self.device.localizedName, privacy: .public)")
    }

    /// Whether `stop()` performs session teardown when called in `state`.
    /// `.failed` tears down too: a runtime error marks the source failed but
    /// can leave the AVCaptureSession running — stop() must release it.
    public static func stopPerformsTeardown(from state: SourceState) -> Bool {
        state == .running || state == .starting || state == .failed
    }

    public func stop() {
        guard Self.stopPerformsTeardown(from: state) else { return }
        state = .stopping
        session.stopRunning() // no-op if the session already halted
        state = .idle
        log.info("camera stopped: \(self.device.localizedName, privacy: .public)")
    }

    #if DEBUG
    /// Headless-verification seam (DEBUG builds only): force the lifecycle
    /// state without touching the capture session. Never call in production.
    public func _test_forceState(_ newState: SourceState) { state = newState }
    #endif

    private func configureSessionIfNeeded() throws {
        guard !configured else { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Note: .inputPriority is iOS-only. On macOS, explicitly setting the
        // device's activeFormat is honored; `start()` re-applies the selection
        // after the input is added (adding an input can reset the format).

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CaptureError.inputCreationFailed(device: device.localizedName, underlying: error)
        }
        guard session.canAddInput(input) else {
            throw CaptureError.cannotAddInput(device: device.localizedName)
        }
        session.addInput(input)

        // Stage N: prefer a 10-bit output when the selected/active device format is
        // itself 10-bit HDR/wide-gamut and the output advertises a 10-bit type.
        let available = output.availableVideoPixelFormatTypes
        let chosen = Self.preferredOutputFormat(activeIsTenBit: probedFormatIsTenBit(),
                                                available: available)
        guard available.contains(chosen) else {
            throw CaptureError.pixelFormatUnavailable(chosen)
        }
        activeOutputFormat = chosen
        if chosen != Self.outputPixelFormat {
            log.info("camera 10-bit output selected: '\(FourCC.string(chosen), privacy: .public)'")
        }
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: chosen,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)

        guard session.canAddOutput(output) else {
            throw CaptureError.cannotAddOutput(device: device.localizedName)
        }
        session.addOutput(output)

        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session, queue: nil
        ) { [weak self] note in
            guard let self else { return }
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self.log.error("session runtime error on \(self.device.localizedName, privacy: .public): \(err?.localizedDescription ?? "unknown", privacy: .public)")
            self.state = .failed
        }

        configured = true
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Zero-copy invariant (§3.5): only IOSurface-backed buffers enter the graph.
        guard CVPixelBufferGetIOSurface(pixelBuffer) != nil else {
            if !warnedNonIOSurface {
                warnedNonIOSurface = true
                log.error("dropping non-IOSurface frame from \(self.device.localizedName, privacy: .public) — zero-copy violation")
            }
            return
        }

        var pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Clock rule (§3.3): PTS must be house time. AVCaptureSession's
        // synchronizationClock is normally the host clock; if it ever differs
        // (device-specific clocks), convert.
        if let syncClock = session.synchronizationClock, !CFEqual(syncClock, HouseClock.clock) {
            pts = CMSyncConvertTime(pts, from: syncClock, to: HouseClock.clock)
            if !warnedClockConversion {
                warnedClockConversion = true
                log.notice("session clock ≠ house clock for \(self.device.localizedName, privacy: .public); converting PTS via CMSyncConvertTime")
            }
        }

        onFrame?(VideoFrame(
            pixelBuffer: pixelBuffer,
            pts: pts,
            duration: CMSampleBufferGetDuration(sampleBuffer),
            source: id
        ))
    }
}
