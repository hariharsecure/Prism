import CoreMedia
import Foundation

/// Lifecycle state every source reports.
public enum SourceState: String, Sendable {
    case idle, starting, running, stopping, failed
}

/// Kinds of sources, OBS-style taxonomy.
public enum SourceKind: String, Codable, Sendable {
    case camera          // AVCaptureDevice video (built-in, USB/UVC capture card, Continuity Camera)
    case microphone      // AVCaptureDevice / CoreAudio input
    case display         // ScreenCaptureKit display
    case window          // ScreenCaptureKit window
    case application     // ScreenCaptureKit app (video and/or audio)
    case systemAudio     // CATap system-wide audio
    case media           // file playback
    case network         // PrismLink (iOS companion) feed
    case virtual         // generated (test pattern, color, text)
}

/// A discoverable device/content item shown in the "add source" UI.
public struct SourceDescriptor: Sendable, Codable, Hashable {
    public let kind: SourceKind
    /// Unique, stable identifier (AVCaptureDevice.uniqueID, SCK window/display ID, link peer ID…).
    public let id: String
    public let name: String
    /// Human info: model, app bundle id, resolution, etc.
    public let detail: String?

    public init(kind: SourceKind, id: String, name: String, detail: String? = nil) {
        self.kind = kind
        self.id = id
        self.name = name
        self.detail = detail
    }
}

/// A running video source. Implementations push house-timestamped,
/// IOSurface-backed frames into `onFrame` from their own capture queue.
public protocol VideoSource: AnyObject {
    var id: SourceID { get }
    var state: SourceState { get }
    /// Set before start(). Called on the source's capture queue.
    var onFrame: ((VideoFrame) -> Void)? { get set }
    func start() throws
    func stop()
}

/// A running audio source. PTS in house time.
public protocol AudioSource: AnyObject {
    var id: SourceID { get }
    var state: SourceState { get }
    var onAudio: ((AudioPacket) -> Void)? { get set }
    func start() throws
    func stop()
}

/// Hot-plug events, OBS-style: sources appear/disappear as hardware connects.
public enum DeviceEvent: Sendable {
    case added(SourceDescriptor)
    case removed(id: String)
}
