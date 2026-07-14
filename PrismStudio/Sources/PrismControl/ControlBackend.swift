import Foundation

/// Snapshot of the record output, mirroring obs-websocket `GetRecordStatus`.
public struct RecordStatus: Sendable {
    public var active: Bool
    public var paused: Bool
    /// Seconds the output has been running.
    public var durationSeconds: Double
    public var bytes: UInt64

    public init(active: Bool = false, paused: Bool = false, durationSeconds: Double = 0, bytes: UInt64 = 0) {
        self.active = active
        self.paused = paused
        self.durationSeconds = durationSeconds
        self.bytes = bytes
    }
}

/// Snapshot of the stream output, mirroring obs-websocket `GetStreamStatus`.
public struct StreamStatus: Sendable {
    public var active: Bool
    public var reconnecting: Bool
    public var durationSeconds: Double
    public var congestion: Double
    public var bytes: UInt64
    public var skippedFrames: UInt64
    public var totalFrames: UInt64

    public init(active: Bool = false, reconnecting: Bool = false, durationSeconds: Double = 0,
                congestion: Double = 0, bytes: UInt64 = 0, skippedFrames: UInt64 = 0, totalFrames: UInt64 = 0) {
        self.active = active
        self.reconnecting = reconnecting
        self.durationSeconds = durationSeconds
        self.congestion = congestion
        self.bytes = bytes
        self.skippedFrames = skippedFrames
        self.totalFrames = totalFrames
    }
}

/// Engine performance snapshot, mirroring obs-websocket `GetStats`.
public struct EngineStats: Sendable {
    public var cpuUsage: Double
    public var memoryUsageMB: Double
    public var availableDiskSpaceMB: Double
    public var activeFps: Double
    public var averageFrameRenderTimeMs: Double
    public var renderSkippedFrames: UInt64
    public var renderTotalFrames: UInt64
    public var outputSkippedFrames: UInt64
    public var outputTotalFrames: UInt64

    public init(cpuUsage: Double = 0, memoryUsageMB: Double = 0, availableDiskSpaceMB: Double = 0,
                activeFps: Double = 0, averageFrameRenderTimeMs: Double = 0,
                renderSkippedFrames: UInt64 = 0, renderTotalFrames: UInt64 = 0,
                outputSkippedFrames: UInt64 = 0, outputTotalFrames: UInt64 = 0) {
        self.cpuUsage = cpuUsage
        self.memoryUsageMB = memoryUsageMB
        self.availableDiskSpaceMB = availableDiskSpaceMB
        self.activeFps = activeFps
        self.averageFrameRenderTimeMs = averageFrameRenderTimeMs
        self.renderSkippedFrames = renderSkippedFrames
        self.renderTotalFrames = renderTotalFrames
        self.outputSkippedFrames = outputSkippedFrames
        self.outputTotalFrames = outputTotalFrames
    }
}

/// Typed failures the engine can report for control requests. `ControlServer`
/// maps each case onto the matching obs-websocket RequestStatus code.
public enum ControlBackendError: Error, Sendable {
    /// Named scene does not exist → 600 ResourceNotFound.
    case sceneNotFound(String)
    /// Output already running (StartRecord/StartStream while active) → 500 OutputRunning.
    case outputRunning
    /// Output not running (StopRecord/StopStream while idle) → 501 OutputNotRunning.
    case outputNotRunning
    /// Engine not ready to service the request → 207 NotReady.
    case notReady
    /// Anything else → 205 GenericError (uses `description` as the comment).
    case failed(String)
}

/// Events the engine pushes so `ControlServer` can broadcast op-5 Event
/// messages to identified obs-websocket clients.
public enum ControlEvent: Sendable {
    /// → `CurrentProgramSceneChanged` (Scenes intent).
    case currentProgramSceneChanged(sceneName: String)
    /// → `RecordStateChanged` (Outputs intent). `state` is an OBS output state
    /// string, e.g. "OBS_WEBSOCKET_OUTPUT_STARTED"; helpers on `OutputRunState`.
    case recordStateChanged(active: Bool, state: OutputRunState, outputPath: String?)
    /// → `StreamStateChanged` (Outputs intent).
    case streamStateChanged(active: Bool, state: OutputRunState)
}

/// OBS output run-state vocabulary used inside `RecordStateChanged` / `StreamStateChanged`.
public enum OutputRunState: String, Sendable {
    case starting = "OBS_WEBSOCKET_OUTPUT_STARTING"
    case started = "OBS_WEBSOCKET_OUTPUT_STARTED"
    case stopping = "OBS_WEBSOCKET_OUTPUT_STOPPING"
    case stopped = "OBS_WEBSOCKET_OUTPUT_STOPPED"
    case paused = "OBS_WEBSOCKET_OUTPUT_PAUSED"
    case resumed = "OBS_WEBSOCKET_OUTPUT_RESUMED"
}

/// The engine-facing seam. `ControlServer` never touches the engine directly;
/// the engine implements this and later calls `ControlServer.publish(_:)` to
/// push events. All methods are async so the engine can hop to its own actors.
public protocol ControlBackend: AnyObject, Sendable {
    /// Ordered scene names (index 0 = top of the list, OBS-style).
    func sceneList() async -> [String]
    /// Name of the current program scene.
    func currentProgramScene() async -> String
    func setCurrentProgramScene(_ name: String) async throws
    func startRecord() async throws
    /// Returns the finished recording's output path, if known.
    func stopRecord() async throws -> String?
    func startStream() async throws
    func stopStream() async throws
    func recordStatus() async -> RecordStatus
    func streamStatus() async -> StreamStatus
    func stats() async -> EngineStats
}
