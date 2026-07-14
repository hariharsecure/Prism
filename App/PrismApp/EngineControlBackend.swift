import Foundation
import PrismCompositor
import PrismControl

/// obs-websocket seam (DESIGN §2.7): maps ControlServer requests onto the
/// AppEngine. "Scenes" are the layout presets (SetCurrentProgramScene now
/// routes through the animated transition path); record and stream start/stop
/// are both real. StartStream uses the engine's configured RTMP target.
final class EngineControlBackend: ControlBackend, @unchecked Sendable {

    /// Set once at engine init, then read-only; AppEngine is @MainActor and
    /// every use below hops there.
    weak var engine: AppEngine?

    private func withEngine<T>(_ body: @MainActor (AppEngine) throws -> T) async throws -> T {
        guard let engine else { throw ControlBackendError.notReady }
        return try await MainActor.run { try body(engine) }
    }

    func sceneList() async -> [String] {
        ScenePreset.allCases.map(\.rawValue)
    }

    func currentProgramScene() async -> String {
        (try? await withEngine { $0.selectedPreset.rawValue }) ?? ScenePreset.fullscreen.rawValue
    }

    func setCurrentProgramScene(_ name: String) async throws {
        guard let preset = ScenePreset(rawValue: name) else {
            throw ControlBackendError.sceneNotFound(name)
        }
        try await withEngine { $0.applyPreset(preset) }
    }

    func startRecord() async throws {
        try await withEngine { engine in
            guard !engine.isRecording else { throw ControlBackendError.outputRunning }
            try engine.startRecording()
        }
    }

    func stopRecord() async throws -> String? {
        // Codex #5: the isRecording guard and the stop must be one atomic claim.
        // Two concurrent StopRecord requests both passed a separate-hop guard and
        // both reported success. Now the engine's synchronous claim decides the
        // single winner; the loser gets stopped == false → outputNotRunning.
        guard let engine else { throw ControlBackendError.notReady }
        let result = await engine.stopRecordingReportingClaim()
        guard result.stopped else { throw ControlBackendError.outputNotRunning }
        return result.path
    }

    func startStream() async throws {
        try await withEngine { engine in
            guard !engine.isStreaming else { throw ControlBackendError.outputRunning }
            do {
                try engine.startConfiguredStream()
            } catch {
                throw ControlBackendError.failed(error.localizedDescription)
            }
        }
    }

    func stopStream() async throws {
        try await withEngine { engine in
            guard engine.isStreaming else { throw ControlBackendError.outputNotRunning }
            engine.stopStream()
        }
    }

    func recordStatus() async -> RecordStatus {
        (try? await withEngine { engine in
            RecordStatus(active: engine.isRecording,
                         paused: false,
                         // Clamp against a backward wall-clock change (Codex).
                         durationSeconds: engine.recordStartDate.map { max(0, -$0.timeIntervalSinceNow) } ?? 0,
                         bytes: UInt64(max(0, engine.recordByteCount)))
        }) ?? RecordStatus()
    }

    func streamStatus() async -> StreamStatus {
        (try? await withEngine { engine in
            StreamStatus(active: engine.isStreaming,
                         reconnecting: engine.streamStateDescription.hasPrefix("reconnecting"),
                         // Clamp against a backward wall-clock change (Codex).
                         durationSeconds: engine.streamStartDate.map { max(0, -$0.timeIntervalSinceNow) } ?? 0,
                         congestion: 0,
                         bytes: UInt64(max(0, engine.streamBytesOut)),
                         skippedFrames: engine.streamDroppedAppends,
                         totalFrames: engine.streamTotalFrames)
        }) ?? StreamStatus()
    }

    func stats() async -> EngineStats {
        let loopStats = (try? await withEngine { $0.renderLoop?.stats }) ?? nil
        let disk = (try? URL(filePath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0
        return EngineStats(cpuUsage: 0,
                           memoryUsageMB: 0,
                           availableDiskSpaceMB: Double(disk) / 1_048_576,
                           activeFps: 60,
                           averageFrameRenderTimeMs: 0,
                           renderSkippedFrames: loopStats?.lateTicks ?? 0,
                           renderTotalFrames: loopStats?.ticks ?? 0,
                           outputSkippedFrames: 0,
                           outputTotalFrames: loopStats?.framesDelivered ?? 0)
    }
}
