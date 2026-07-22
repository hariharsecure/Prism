import Foundation
import PrismCore

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

    // MARK: Extended perf instrumentation (Phase 1d).
    // These are additive: the obs-websocket `GetStats` payload keeps its exact
    // original shape (only the fields above are mapped there). These carry the
    // real distribution/queue/GPU signal for the app's own telemetry.

    /// Total per-frame CPU work distribution (ms).
    public var frameWorkP50Ms: Double
    public var frameWorkP95Ms: Double
    public var frameWorkP99Ms: Double
    public var frameWorkMaxMs: Double
    /// Frame-budget remaining before the next tick (ms); `min` is the worst
    /// (most negative = deepest overrun) frame in the window.
    public var deadlineSlackP50Ms: Double
    public var deadlineSlackMinMs: Double
    /// Per-subsystem GPU time (ms, p95): primary compositor and transition passes.
    public var gpuCompositorP95Ms: Double
    public var gpuTransitionP95Ms: Double
    /// Metal-allocated resource size (`MTLDevice.currentAllocatedSize`, MB).
    public var metalAllocatedMB: Double
    /// Render-mailbox queue depth (p95 across the window).
    public var renderQueueDepthItems: Int
    public var renderQueueDepthBytes: Int
    public var renderQueueOldestAgeMs: Double
    /// Frames dropped at the render mailbox (queue overflow, newest-wins).
    public var renderQueueDroppedFrames: UInt64

    public init(cpuUsage: Double = 0, memoryUsageMB: Double = 0, availableDiskSpaceMB: Double = 0,
                activeFps: Double = 0, averageFrameRenderTimeMs: Double = 0,
                renderSkippedFrames: UInt64 = 0, renderTotalFrames: UInt64 = 0,
                outputSkippedFrames: UInt64 = 0, outputTotalFrames: UInt64 = 0,
                frameWorkP50Ms: Double = 0, frameWorkP95Ms: Double = 0,
                frameWorkP99Ms: Double = 0, frameWorkMaxMs: Double = 0,
                deadlineSlackP50Ms: Double = 0, deadlineSlackMinMs: Double = 0,
                gpuCompositorP95Ms: Double = 0, gpuTransitionP95Ms: Double = 0,
                metalAllocatedMB: Double = 0,
                renderQueueDepthItems: Int = 0, renderQueueDepthBytes: Int = 0,
                renderQueueOldestAgeMs: Double = 0, renderQueueDroppedFrames: UInt64 = 0) {
        self.cpuUsage = cpuUsage
        self.memoryUsageMB = memoryUsageMB
        self.availableDiskSpaceMB = availableDiskSpaceMB
        self.activeFps = activeFps
        self.averageFrameRenderTimeMs = averageFrameRenderTimeMs
        self.renderSkippedFrames = renderSkippedFrames
        self.renderTotalFrames = renderTotalFrames
        self.outputSkippedFrames = outputSkippedFrames
        self.outputTotalFrames = outputTotalFrames
        self.frameWorkP50Ms = frameWorkP50Ms
        self.frameWorkP95Ms = frameWorkP95Ms
        self.frameWorkP99Ms = frameWorkP99Ms
        self.frameWorkMaxMs = frameWorkMaxMs
        self.deadlineSlackP50Ms = deadlineSlackP50Ms
        self.deadlineSlackMinMs = deadlineSlackMinMs
        self.gpuCompositorP95Ms = gpuCompositorP95Ms
        self.gpuTransitionP95Ms = gpuTransitionP95Ms
        self.metalAllocatedMB = metalAllocatedMB
        self.renderQueueDepthItems = renderQueueDepthItems
        self.renderQueueDepthBytes = renderQueueDepthBytes
        self.renderQueueOldestAgeMs = renderQueueOldestAgeMs
        self.renderQueueDroppedFrames = renderQueueDroppedFrames
    }
}

public extension EngineStats {
    /// Build a stats snapshot from the live render-metrics aggregator, folding in
    /// the frame counters the loop tracks separately. This is the single mapping
    /// used by `EngineControlBackend.stats()` — and the one the tests pin — so the
    /// "real numbers, not zeros" contract lives in exactly one place.
    ///
    /// - `averageFrameRenderTimeMs` = frame-work p50 (median), the robust central
    ///   render cost. `cpuUsage` = whole-process CPU% if sampled, else the render
    ///   duty cycle (frame-work p50 / frame interval) so it is never a flat zero
    ///   once the loop has run.
    init(perf: RenderMetrics.Snapshot,
         availableDiskSpaceMB: Double,
         activeFps: Double,
         frameIntervalMs: Double,
         renderSkippedFrames: UInt64,
         renderTotalFrames: UInt64,
         outputSkippedFrames: UInt64,
         outputTotalFrames: UInt64) {
        let fw = perf.frameWork
        let slack = perf.deadlineSlack
        let dutyCycle = frameIntervalMs > 0 ? min(100, fw.p50Ms / frameIntervalMs * 100) : 0
        self.init(
            cpuUsage: perf.cpuPercent > 0 ? perf.cpuPercent : dutyCycle,
            memoryUsageMB: perf.physFootprintMB,
            availableDiskSpaceMB: availableDiskSpaceMB,
            activeFps: activeFps,
            averageFrameRenderTimeMs: fw.p50Ms,
            renderSkippedFrames: renderSkippedFrames,
            renderTotalFrames: renderTotalFrames,
            outputSkippedFrames: outputSkippedFrames,
            outputTotalFrames: outputTotalFrames,
            frameWorkP50Ms: fw.p50Ms,
            frameWorkP95Ms: fw.p95Ms,
            frameWorkP99Ms: fw.p99Ms,
            frameWorkMaxMs: fw.maxMs,
            deadlineSlackP50Ms: slack.p50Ms,
            deadlineSlackMinMs: slack.minMs,
            gpuCompositorP95Ms: perf.gpu(.compositor).p95Ms,
            gpuTransitionP95Ms: perf.gpu(.transition).p95Ms,
            metalAllocatedMB: perf.metalAllocatedMB,
            renderQueueDepthItems: Int(perf.queueItems.p95),
            renderQueueDepthBytes: Int(perf.queueBytes.p95),
            renderQueueOldestAgeMs: Double(perf.queueAgeUs.p95) / 1000.0,
            renderQueueDroppedFrames: perf.dropped(.queueOverflow))
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
