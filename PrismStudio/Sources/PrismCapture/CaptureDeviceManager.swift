import AVFoundation
import CoreMedia
import Foundation
import PrismCore

/// Enumerates AVFoundation capture hardware (cameras + microphones) and
/// reports hot-plug events — the OBS-style "device layer" (DESIGN.md §3.2).
///
/// Covered video devices: built-in cameras, external/USB/UVC devices
/// (HDMI capture cards appear as external cameras), Desk View, and
/// Continuity Camera. Covered audio devices: built-in and external inputs.
///
/// Enumeration does NOT trigger TCC prompts; only starting a session does.
///
/// Thread model: `videoDevices()`/`audioDevices()` are safe from any thread.
/// Hot-plug notifications arrive on an arbitrary thread; `onDeviceEvent` is
/// invoked from that context — hop queues in the handler if you need to.
public final class CaptureDeviceManager {
    private static let log = EngineLog.logger("capture.devices")

    /// Hot-plug callback. Set before events are wanted; may be replaced at any time.
    public var onDeviceEvent: ((DeviceEvent) -> Void)?

    private var observers: [NSObjectProtocol] = []

    public init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil, queue: nil
        ) { [weak self] note in
            self?.handleConnection(note, connected: true)
        })
        observers.append(center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil, queue: nil
        ) { [weak self] note in
            self?.handleConnection(note, connected: false)
        })
    }

    deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: - Enumeration

    private static let videoDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera,   // built-in FaceTime/Studio Display cameras
        .continuityCamera,         // iPhone as camera
        .deskViewCamera,           // Continuity Desk View
        .external,                 // USB/UVC — HDMI capture cards land here
    ]

    private static let audioDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .microphone,               // built-in + system-recognized mics
        .external,                 // external/USB audio inputs
    ]

    /// All connected video capture devices as add-source descriptors (kind `.camera`).
    public func videoDevices() -> [SourceDescriptor] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: Self.videoDeviceTypes, mediaType: .video, position: .unspecified)
        return session.devices.map { Self.descriptor(for: $0) }
    }

    /// All connected audio input devices as add-source descriptors (kind `.microphone`).
    public func audioDevices() -> [SourceDescriptor] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: Self.audioDeviceTypes, mediaType: .audio, position: .unspecified)
        return session.devices.map { Self.descriptor(for: $0) }
    }

    /// Video + audio devices in one list.
    public func allDevices() -> [SourceDescriptor] {
        videoDevices() + audioDevices()
    }

    // MARK: - Descriptor building

    /// Build the UI-facing descriptor for a device (id = `uniqueID`,
    /// detail = type/model/format-capability summary).
    public static func descriptor(for device: AVCaptureDevice) -> SourceDescriptor {
        let kind: SourceKind = device.hasMediaType(.video) ? .camera : .microphone
        return SourceDescriptor(
            kind: kind,
            id: device.uniqueID,
            name: device.localizedName,
            detail: kind == .camera ? videoDetail(for: device) : audioDetail(for: device)
        )
    }

    private static func typeLabel(for device: AVCaptureDevice) -> String {
        switch device.deviceType {
        case .continuityCamera: return "Continuity Camera"
        case .deskViewCamera: return "Desk View"
        case .external: return "External"
        case .builtInWideAngleCamera: return "Built-in"
        case .microphone: return "Microphone"
        default: return device.deviceType.rawValue
        }
    }

    private static func videoDetail(for device: AVCaptureDevice) -> String {
        var maxW: Int32 = 0, maxH: Int32 = 0
        var maxFPS: Double = 0
        var fourCCs: Set<String> = []
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            if Int(dims.width) * Int(dims.height) > Int(maxW) * Int(maxH) {
                maxW = dims.width; maxH = dims.height
            }
            for range in format.videoSupportedFrameRateRanges {
                maxFPS = max(maxFPS, range.maxFrameRate)
            }
            fourCCs.insert(FourCC.string(CMFormatDescriptionGetMediaSubType(format.formatDescription)))
        }
        var parts = [typeLabel(for: device), "model \(device.modelID)"]
        if !device.formats.isEmpty {
            parts.append("\(device.formats.count) formats")
            parts.append("up to \(maxW)×\(maxH)@\(Int(maxFPS.rounded()))")
            parts.append(fourCCs.sorted().joined(separator: "/"))
        }
        return parts.joined(separator: " · ")
    }

    private static func audioDetail(for device: AVCaptureDevice) -> String {
        var maxRate: Double = 0
        var maxChannels: UInt32 = 0
        for format in device.formats {
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format.formatDescription)?.pointee {
                maxRate = max(maxRate, asbd.mSampleRate)
                maxChannels = max(maxChannels, asbd.mChannelsPerFrame)
            }
        }
        var parts = [typeLabel(for: device), "model \(device.modelID)"]
        if maxRate > 0 {
            parts.append("up to \(Int(maxRate)) Hz · \(maxChannels)ch")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Hot-plug

    private func handleConnection(_ note: Notification, connected: Bool) {
        guard let device = note.object as? AVCaptureDevice else { return }
        // Only surface devices this layer owns (video or audio inputs).
        guard device.hasMediaType(.video) || device.hasMediaType(.audio) else { return }
        let event: DeviceEvent
        if connected {
            event = .added(Self.descriptor(for: device))
            Self.log.info("device connected: \(device.localizedName, privacy: .private) [\(LogRedact.hashID(device.uniqueID), privacy: .public)]")
        } else {
            event = .removed(id: device.uniqueID)
            Self.log.info("device disconnected: \(device.localizedName, privacy: .private) [\(LogRedact.hashID(device.uniqueID), privacy: .public)]")
        }
        onDeviceEvent?(event)
    }
}
