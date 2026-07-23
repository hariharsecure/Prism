import AVFoundation
import CoreMedia
import Foundation
import PrismCore

/// A Mac audio input (built-in or external mic) as an `AudioSource`:
/// one `AVCaptureSession` + `AVCaptureAudioDataOutput` per device.
///
/// Clock rule (DESIGN.md §3.3): emitted packets carry house-time PTS.
/// AVCaptureSession normally synchronizes to the host clock; the delegate
/// checks `session.synchronizationClock` and, if it differs, retimes the
/// sample buffer via `CMSyncConvertTime` + `CMSampleBufferCreateCopyWithNewTiming`
/// (a timing-header copy — sample data is not copied).
///
/// Thread model: call `start()`/`stop()` from one control thread. `onAudio`
/// fires on the source's private capture queue. `start()` blocks until the
/// session is running and WILL trigger the microphone TCC prompt on first use.
public final class MicrophoneSource: NSObject, AudioSource {
    public let id: SourceID
    public private(set) var state: SourceState = .idle
    public var onAudio: ((AudioPacket) -> Void)?

    /// UI-facing descriptor for this device (name/model/capabilities).
    public var descriptor: SourceDescriptor { CaptureDeviceManager.descriptor(for: device) }

    private let device: AVCaptureDevice
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let captureQueue: DispatchQueue
    private let log = EngineLog.logger("capture.microphone")

    private var configured = false
    private var runtimeErrorObserver: NSObjectProtocol?
    private var warnedClockConversion = false
    private var warnedRetimeFailure = false

    /// - Parameter deviceID: `AVCaptureDevice.uniqueID` (the `SourceDescriptor.id`
    ///   from `CaptureDeviceManager.audioDevices()`).
    public init(deviceID: String) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID), device.hasMediaType(.audio) else {
            throw CaptureError.deviceNotFound(uniqueID: deviceID)
        }
        self.device = device
        self.id = SourceID(deviceID)
        self.captureQueue = DispatchQueue(label: "studio.prism.capture.mic.\(deviceID)")
        super.init()
    }

    /// Wrap an already-resolved device (e.g. straight from a discovery session).
    public convenience init(device: AVCaptureDevice) throws {
        try self.init(deviceID: device.uniqueID)
    }

    deinit {
        if let token = runtimeErrorObserver { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: - Lifecycle

    /// Configure and start the capture session. Blocks until running.
    /// Triggers the microphone TCC prompt on first use — never call in
    /// automated verification.
    public func start() throws {
        guard state == .idle || state == .failed else { return }
        state = .starting
        do {
            try configureSessionIfNeeded()
        } catch {
            state = .failed
            throw error
        }
        session.startRunning()
        state = .running
        log.info("microphone running: \(self.device.localizedName, privacy: .private)")
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
        log.info("microphone stopped: \(self.device.localizedName, privacy: .private)")
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

        // Device-native format; per-source resample/drift handling is the
        // audio engine's job (§3.3 — audio is master, micro-resample there).
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
            self.log.error("session runtime error on \(self.device.localizedName, privacy: .private): \(err?.localizedDescription ?? "unknown", privacy: .public)")
            self.state = .failed
        }

        configured = true
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension MicrophoneSource: AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        var buffer = sampleBuffer

        // Clock rule (§3.3): PTS must be house time. Normally the session's
        // synchronizationClock IS the host clock and this is a no-op.
        if let syncClock = session.synchronizationClock, !CFEqual(syncClock, HouseClock.clock) {
            if let retimed = Self.retimed(sampleBuffer, from: syncClock, to: HouseClock.clock) {
                buffer = retimed
                if !warnedClockConversion {
                    warnedClockConversion = true
                    log.notice("session clock ≠ house clock for \(self.device.localizedName, privacy: .private); retiming packets via CMSyncConvertTime")
                }
            } else {
                if !warnedRetimeFailure {
                    warnedRetimeFailure = true
                    log.error("failed to retime audio from \(self.device.localizedName, privacy: .private); dropping packets to protect the house-time invariant")
                }
                return
            }
        }

        onAudio?(AudioPacket(sampleBuffer: buffer, source: id))
    }

    /// Copy `sampleBuffer` with its PTS converted between clocks. Copies the
    /// timing header only — the audio data block is shared, not duplicated.
    private static func retimed(
        _ sampleBuffer: CMSampleBuffer,
        from source: CMClock,
        to destination: CMClock
    ) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing) == noErr else {
            return nil
        }
        timing.presentationTimeStamp = CMSyncConvertTime(
            timing.presentationTimeStamp, from: source, to: destination)

        var retimed: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimed
        )
        guard status == noErr, let retimed else { return nil }
        return retimed
    }
}
