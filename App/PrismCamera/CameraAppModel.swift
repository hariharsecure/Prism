@preconcurrency import AVFoundation
import Combine
import Foundation
import Network
import PrismLink
import PrismLinkSender
import SwiftUI

/// A discovered Mac running Prism, list-friendly.
struct ServerItem: Identifiable {
    let server: LinkClient.DiscoveredServer
    var id: String { server.name + String(describing: server.endpoint) }
    var name: String { server.name }
}

/// App model for Prism Camera: owns the DeviceCameraStreamer (capture →
/// HEVC → QUIC while connected) and a local AVCaptureSession used for the
/// viewfinder while NOT streaming. The camera is exclusive on iOS, so the
/// preview session stops before the streamer takes over, and restarts after.
@MainActor
final class CameraAppModel: ObservableObject {

    // MARK: Published UI state

    @Published private(set) var servers: [ServerItem] = []
    @Published private(set) var state: DeviceCameraStreamer.State = .idle
    @Published private(set) var onAir = false            // tally from the Mac
    @Published private(set) var connectedMacName: String?
    @Published private(set) var lens: DeviceCameraStreamer.Lens = .back
    @Published private(set) var torchOn = false
    @Published private(set) var cameraDenied = false

    /// The pairing code shown in Prism's sidebar on the Mac (v1 PSK
    /// bootstrap). Persisted so pairing survives relaunches; every edit is
    /// pushed to the streamer and used by the next connect.
    @Published var pairingCode: String {
        didSet {
            UserDefaults.standard.set(pairingCode, forKey: Self.pairingCodeDefaultsKey)
            streamer.setPairingCode(normalizedPairingCode)
        }
    }
    private static let pairingCodeDefaultsKey = "studio.prism.camera.pairingCode"
    private var normalizedPairingCode: String? {
        let normalized = LinkPairing.normalize(pairingCode)
        return normalized.isEmpty ? nil : normalized
    }
    var pairingCodeLooksComplete: Bool {
        LinkPairing.normalize(pairingCode).count == LinkPairing.codeLength
    }

    var isStreaming: Bool { state == .streaming }
    var isBusy: Bool { state == .connecting }

    var statusText: String {
        switch state {
        case .idle: return "Not connected"
        case .discovering: return "Looking for Prism on your network…"
        case .connecting: return "Connecting to \(connectedMacName ?? "Mac")…"
        case .streaming: return "Streaming to \(connectedMacName ?? "Mac")"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    // MARK: Streaming engine

    private let streamer: DeviceCameraStreamer

    // MARK: Local viewfinder (only while not streaming)

    let previewSession = AVCaptureSession()
    private let previewQueue = DispatchQueue(label: "studio.prism.camera.preview")
    private var previewInput: AVCaptureDeviceInput?

    init() {
        let storedCode = UserDefaults.standard.string(forKey: Self.pairingCodeDefaultsKey) ?? ""
        pairingCode = storedCode
        let normalized = LinkPairing.normalize(storedCode)
        streamer = DeviceCameraStreamer(
            configuration: .init(deviceName: UIDevice.current.name,
                                 pairingCode: normalized.isEmpty ? nil : normalized))

        streamer.onServersChanged = { [weak self] discovered in
            DispatchQueue.main.async {
                self?.servers = discovered.map(ServerItem.init(server:))
            }
        }
        streamer.onStateChange = { [weak self] newState in
            DispatchQueue.main.async { self?.handleStateChange(newState) }
        }
        streamer.onTally = { [weak self] tally in
            DispatchQueue.main.async { self?.onAir = tally.program }
        }
    }

    // MARK: Lifecycle

    func start() {
        streamer.startDiscovery()
        Task { @MainActor in
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted {
                self.configurePreview(lens: self.lens)
                self.setPreviewRunning(true)
            } else {
                self.cameraDenied = true
            }
        }
    }

    func connect(_ item: ServerItem) {
        connectedMacName = item.name
        setPreviewRunning(false)          // hand the camera to the streamer
        streamer.connect(to: item.server.endpoint)
    }

    func disconnect() {
        streamer.stop()
        onAir = false
        connectedMacName = nil
        streamer.startDiscovery()
        if !cameraDenied {
            setPreviewRunning(true)       // take the camera back for the viewfinder
        }
    }

    private func handleStateChange(_ newState: DeviceCameraStreamer.State) {
        state = newState
        if case .failed = newState {
            onAir = false
            if !cameraDenied { setPreviewRunning(true) }
        }
    }

    // MARK: Camera controls

    func toggleLens() {
        let newLens: DeviceCameraStreamer.Lens = (lens == .back) ? .front : .back
        lens = newLens
        if torchOn, newLens == .front { torchOn = false }
        if isStreaming || isBusy {
            streamer.setLens(newLens)
        } else {
            configurePreview(lens: newLens)
        }
    }

    func toggleTorch() {
        guard lens == .back else { return }
        let newValue = !torchOn
        torchOn = newValue
        if isStreaming || isBusy {
            streamer.setTorch(newValue)
        } else if let device = previewInput?.device, device.hasTorch {
            previewQueue.async {
                try? device.lockForConfiguration()
                device.torchMode = newValue ? .on : .off
                device.unlockForConfiguration()
            }
        }
    }

    // MARK: Viewfinder session plumbing

    private func configurePreview(lens: DeviceCameraStreamer.Lens) {
        let position: AVCaptureDevice.Position = (lens == .back) ? .back : .front
        previewSession.beginConfiguration()
        defer { previewSession.commitConfiguration() }
        if let existing = previewInput {
            previewSession.removeInput(existing)
            previewInput = nil
        }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              previewSession.canAddInput(input) else { return } // e.g. simulator
        previewSession.addInput(input)
        previewInput = input
    }

    private func setPreviewRunning(_ running: Bool) {
        let session = previewSession
        previewQueue.async {   // startRunning blocks; never on the main thread
            if running {
                if !session.isRunning { session.startRunning() }
            } else if session.isRunning {
                session.stopRunning()
            }
        }
    }
}
