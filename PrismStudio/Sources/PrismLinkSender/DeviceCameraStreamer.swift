#if os(iOS)
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Network
import PrismCore
import PrismLink

/// iOS capture orchestration: AVCaptureSession → `LowLatencyEncoder` →
/// `LinkClient`. Thin by design — capture in, encoded datagrams out, state
/// and tally surfaced through callbacks. No UIKit/SwiftUI; the app layer
/// owns all presentation (and the camera-permission prompt: request
/// `AVCaptureDevice.requestAccess(for: .video)` before `connect`).
public final class DeviceCameraStreamer: NSObject, @unchecked Sendable {

    // MARK: Types

    public enum Lens: String, CaseIterable, Sendable {
        case back, front
    }

    public enum State: Sendable, Equatable {
        case idle
        case discovering
        case connecting
        case streaming
        case failed(String)
    }

    public enum StreamerError: Error {
        case cameraUnavailable(String)
        case cannotAddInput
        case cannotAddOutput
    }

    public struct Configuration {
        /// Name shown in the Mac's source list (e.g. the user's device name).
        public var deviceName: String
        public var lens: Lens
        public var preset: AVCaptureSession.Preset
        /// Capture fps until the Mac's sessionConfig says otherwise.
        public var fps: Int
        /// Pairing code shown by the Mac (v1 PSK bootstrap), passed through
        /// to `LinkClient`. Update later via `setPairingCode(_:)`.
        public var pairingCode: String?
        /// TLS pinning hook, passed through to `LinkClient`.
        public var verifyPeer: ((SecTrust) -> Bool)?

        public init(deviceName: String,
                    lens: Lens = .back,
                    preset: AVCaptureSession.Preset = .hd1920x1080,
                    fps: Int = 30,
                    pairingCode: String? = nil,
                    verifyPeer: ((SecTrust) -> Bool)? = nil) {
            self.deviceName = deviceName
            self.lens = lens
            self.preset = preset
            self.fps = fps
            self.pairingCode = pairingCode
            self.verifyPeer = verifyPeer
        }
    }

    // MARK: Callbacks (invoked on internal queues; hop to the main actor for UI)

    public var onStateChange: ((State) -> Void)?
    /// Tally from the Mac (program/preview) — drive the on-screen indicator.
    public var onTally: ((LinkTally) -> Void)?
    public var onServersChanged: (([LinkClient.DiscoveredServer]) -> Void)?

    // MARK: Public surface

    public private(set) var state: State = .idle
    /// The underlying transport, exposed for stats/clock HUDs.
    public let client: LinkClient

    private let log = EngineLog.logger("link.sender.camera")
    private let queue = DispatchQueue(label: "studio.prism.sender.streamer")
    private let captureQueue = DispatchQueue(label: "studio.prism.sender.capture")
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private let encoderLock = NSLock()
    private var encoderStorage: LowLatencyEncoder?
    private var configuration: Configuration
    private var currentSessionConfig: LinkSessionConfig

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.currentSessionConfig = LinkSessionConfig(fps: configuration.fps)
        let hasTorch = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                               position: .back)?.hasTorch ?? false
        let hello = LinkHello(name: configuration.deviceName,
                              model: Self.modelIdentifier(),
                              hasTorch: hasTorch,
                              lenses: Self.availableLenses())
        self.client = LinkClient(configuration: .init(hello: hello,
                                                      pairingCode: configuration.pairingCode,
                                                      verifyPeer: configuration.verifyPeer))
        super.init()
        wireClient()
    }

    /// Update the pairing code used by future connects (user edited the
    /// code field). Takes effect on the next `connect(to:)`.
    public func setPairingCode(_ code: String?) {
        client.setPairingCode(code)
    }

    // MARK: Lifecycle

    /// Start Bonjour discovery of Macs running Prism.
    public func startDiscovery() {
        queue.async { [self] in
            setState(.discovering)
            client.startBrowsing()
        }
    }

    public func stopDiscovery() {
        client.stopBrowsing()
    }

    /// Connect to a discovered Mac and start streaming when the link is up.
    public func connect(to endpoint: NWEndpoint) {
        queue.async { [self] in
            setState(.connecting)
            client.connect(to: endpoint)
        }
    }

    /// Stop capture and tear the link down.
    public func stop() {
        queue.async { [self] in
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
            encoder?.invalidate()
            encoder = nil
            client.disconnect()
            setState(.idle)
        }
    }

    // MARK: Camera controls

    public func setLens(_ lens: Lens) {
        queue.async { [self] in
            configuration.lens = lens
            guard state == .streaming else { return }
            do {
                try configureCaptureSession(lens: lens)
                encoder?.forceKeyframe() // new lens = new scene; resync fast
            } catch {
                log.error("lens switch failed: \(String(describing: error))")
            }
        }
    }

    public func setTorch(_ on: Bool) {
        queue.async { [self] in
            guard let device = videoInput?.device, device.hasTorch else { return }
            configureDevice(device) { $0.torchMode = on ? .on : .off }
        }
    }

    public func setExposureLocked(_ locked: Bool) {
        queue.async { [self] in
            guard let device = videoInput?.device else { return }
            let mode: AVCaptureDevice.ExposureMode = locked ? .locked : .continuousAutoExposure
            guard device.isExposureModeSupported(mode) else { return }
            configureDevice(device) { $0.exposureMode = mode }
        }
    }

    public func setFocusLocked(_ locked: Bool) {
        queue.async { [self] in
            guard let device = videoInput?.device else { return }
            let mode: AVCaptureDevice.FocusMode = locked ? .locked : .continuousAutoFocus
            guard device.isFocusModeSupported(mode) else { return }
            configureDevice(device) { $0.focusMode = mode }
        }
    }

    // MARK: Client wiring

    private func wireClient() {
        client.onServersChanged = { [weak self] servers in
            self?.onServersChanged?(servers)
        }
        client.onStateChange = { [weak self] linkState in
            guard let self else { return }
            self.queue.async {
                switch linkState {
                case .connected:
                    self.startStreamingPipeline()
                case .disconnected:
                    if self.state == .streaming || self.state == .connecting {
                        self.stopCaptureOnly()
                        self.setState(.failed("link disconnected"))
                    }
                case .idle, .connecting:
                    break
                }
            }
        }
        client.onSessionConfig = { [weak self] config in
            self?.queue.async { self?.apply(sessionConfig: config) }
        }
        client.onKeyframeRequest = { [weak self] in
            self?.encoder?.forceKeyframe()
        }
        client.onBitrateChange = { [weak self] bps in
            self?.encoder?.setBitrate(bps)
        }
        client.onTally = { [weak self] tally in
            self?.onTally?(tally)
        }
        client.onCameraControl = { [weak self] control in
            self?.queue.async { self?.apply(cameraControl: control) }
        }
    }

    // MARK: Pipeline

    private func startStreamingPipeline() {
        guard state == .connecting || state == .discovering else { return }
        do {
            try configureCaptureSession(lens: configuration.lens)
            try rebuildEncoder()
        } catch {
            log.error("pipeline start failed: \(String(describing: error))")
            setState(.failed(String(describing: error)))
            client.disconnect()
            return
        }
        let session = captureSession
        captureQueue.async {
            if !session.isRunning {
                session.startRunning() // blocking; never on the caller's queue
            }
        }
        setState(.streaming)
    }

    private func stopCaptureOnly() {
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        encoder?.invalidate()
        encoder = nil
    }

    private func configureCaptureSession(lens: Lens) throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        if captureSession.canSetSessionPreset(configuration.preset) {
            captureSession.sessionPreset = configuration.preset
        }
        if let existing = videoInput {
            captureSession.removeInput(existing)
            videoInput = nil
        }
        let position: AVCaptureDevice.Position = (lens == .back) ? .back : .front
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                   position: position) else {
            throw StreamerError.cameraUnavailable(lens.rawValue)
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else { throw StreamerError.cannotAddInput }
        captureSession.addInput(input)
        videoInput = input

        if !captureSession.outputs.contains(videoOutput) {
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = true // mailbox semantics: never queue deep
            videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
            guard captureSession.canAddOutput(videoOutput) else { throw StreamerError.cannotAddOutput }
            captureSession.addOutput(videoOutput)
        }
        applyFrameRate(device: device, fps: currentSessionConfig.fps)
    }

    private func applyFrameRate(device: AVCaptureDevice, fps: Int) {
        guard fps > 0 else { return }
        let supported = device.activeFormat.videoSupportedFrameRateRanges
            .contains { Int($0.minFrameRate.rounded()) <= fps && fps <= Int($0.maxFrameRate.rounded()) }
        guard supported else {
            log.warning("fps \(fps) unsupported by the active format — leaving device default")
            return
        }
        configureDevice(device) {
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            $0.activeVideoMinFrameDuration = duration
            $0.activeVideoMaxFrameDuration = duration
        }
    }

    private func rebuildEncoder() throws {
        encoder?.invalidate()
        let config = LowLatencyEncoder.Configuration(
            width: currentSessionConfig.width,
            height: currentSessionConfig.height,
            fps: currentSessionConfig.fps,
            averageBitrateBps: currentSessionConfig.targetBitrateBps,
            keyframeIntervalSeconds: currentSessionConfig.keyframeIntervalSeconds)
        let encoder = try LowLatencyEncoder(configuration: config)
        encoder.onEncodedFrame = { [weak self] frame in
            self?.client.send(encoded: frame.annexB, pts: frame.pts, isKeyframe: frame.isKeyframe)
        }
        self.encoder = encoder
    }

    // MARK: Inbound config/control application

    private func apply(sessionConfig: LinkSessionConfig) {
        let previous = currentSessionConfig
        currentSessionConfig = sessionConfig
        guard state == .streaming else { return } // picked up when the pipeline starts
        if sessionConfig.width != previous.width || sessionConfig.height != previous.height {
            do {
                try rebuildEncoder() // resolution change needs a new session
            } catch {
                log.error("encoder rebuild for sessionConfig failed: \(String(describing: error))")
                return
            }
        } else {
            encoder?.setBitrate(sessionConfig.targetBitrateBps)
            encoder?.setExpectedFPS(sessionConfig.fps)
        }
        if let device = videoInput?.device {
            applyFrameRate(device: device, fps: sessionConfig.fps)
        }
    }

    private func apply(cameraControl control: LinkCameraControl) {
        if let lensName = control.lens, let lens = Lens(rawValue: lensName) {
            setLens(lens)
        }
        guard let device = videoInput?.device else { return }
        configureDevice(device) { device in
            if let torch = control.torch, device.hasTorch {
                device.torchMode = torch ? .on : .off
            }
            if let zoom = control.zoomFactor {
                device.videoZoomFactor = min(max(CGFloat(zoom), device.minAvailableVideoZoomFactor),
                                             device.maxAvailableVideoZoomFactor)
            }
            if let bias = control.exposureBiasEV {
                let clamped = min(max(Float(bias), device.minExposureTargetBias),
                                  device.maxExposureTargetBias)
                device.setExposureTargetBias(clamped)
            }
        }
    }

    // MARK: Helpers

    private var encoder: LowLatencyEncoder? {
        get {
            encoderLock.lock(); defer { encoderLock.unlock() }
            return encoderStorage
        }
        set {
            encoderLock.lock(); defer { encoderLock.unlock() }
            encoderStorage = newValue
        }
    }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        onStateChange?(new)
    }

    private func configureDevice(_ device: AVCaptureDevice,
                                 _ body: (AVCaptureDevice) -> Void) {
        do {
            try device.lockForConfiguration()
            body(device)
            device.unlockForConfiguration()
        } catch {
            log.warning("device configuration failed: \(String(describing: error))")
        }
    }

    private static func modelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    private static func availableLenses() -> [String] {
        let mapping: [(AVCaptureDevice.DeviceType, String)] = [
            (.builtInWideAngleCamera, "wide"),
            (.builtInUltraWideCamera, "ultraWide"),
            (.builtInTelephotoCamera, "tele"),
        ]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: mapping.map(\.0),
                                                         mediaType: .video, position: .back)
        return discovery.devices.compactMap { device in
            mapping.first { $0.0 == device.deviceType }?.1
        }
    }
}

// MARK: - Capture delegate

extension DeviceCameraStreamer: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // AVCapture PTS is already device host-clock time (§3.3): pass through.
        encoder?.encode(pixelBuffer: pixelBuffer,
                        pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                        duration: CMSampleBufferGetDuration(sampleBuffer))
    }
}
#endif
