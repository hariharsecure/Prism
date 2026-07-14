import AppIntents
import Foundation

// MARK: - App Intents / Shortcuts (control tier)
//
// Exposes Prism's transport to macOS Shortcuts, Focus filters, and system
// automation. Each intent reaches the live engine through `AppEngine.current`
// (a weak reference set in `AppEngine.init`). The action intents set
// `openAppWhenRun = true` so Shortcuts launches Prism first when it isn't
// already running — by the time `perform()` runs, `AppEngine.init` has set
// `current`, so the engine is reachable.
//
// All engine calls hop to the main actor (AppEngine is `@MainActor`).

/// Typed failures surfaced to Shortcuts as readable errors.
enum PrismIntentError: Error, CustomLocalizedStringResourceConvertible {
    case engineUnavailable
    case sceneNotFound(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .engineUnavailable:
            return "Prism isn't ready yet. Open Prism and try again."
        case .sceneNotFound(let name):
            return "Prism has no scene named \"\(name)\"."
        }
    }
}

/// Fetch the live engine on the main actor, or throw a readable error.
@MainActor
private func currentEngine() throws -> AppEngine {
    guard let engine = AppEngine.current else { throw PrismIntentError.engineUnavailable }
    return engine
}

// MARK: - Scene entity (parameterizes SwitchSceneIntent)

/// A selectable program scene (backed by `ScenePreset`) for the Shortcuts
/// scene picker. Its query enumerates the layout presets.
struct SceneEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Scene" }
    static var defaultQuery = SceneQuery()

    var id: String        // == ScenePreset.rawValue
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(preset: ScenePreset) {
        id = preset.rawValue
        name = preset.rawValue
    }
}

struct SceneQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SceneEntity] {
        ScenePreset.allCases.filter { identifiers.contains($0.rawValue) }.map(SceneEntity.init)
    }

    func suggestedEntities() async throws -> [SceneEntity] {
        ScenePreset.allCases.map(SceneEntity.init)
    }
}

// MARK: - Transport intents

struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Recording"
    static var description = IntentDescription("Start recording the Prism program to ~/Movies/Prism.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        try await MainActor.run {
            let engine = try currentEngine()
            guard !engine.isRecording else { return }
            try engine.startRecording()
        }
        return .result()
    }
}

struct StopRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Recording"
    static var description = IntentDescription("Stop the current Prism recording and finalize the file.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        let engine = try await MainActor.run { try currentEngine() }
        if await engine.isRecording { _ = await engine.stopRecording() }
        return .result()
    }
}

struct StartStreamIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Streaming"
    static var description = IntentDescription("Start streaming the Prism program to the configured RTMP target.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        try await MainActor.run {
            let engine = try currentEngine()
            guard !engine.isStreaming else { return }
            try engine.startConfiguredStream()
        }
        return .result()
    }
}

struct StopStreamIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Streaming"
    static var description = IntentDescription("Stop the current Prism stream.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        try await MainActor.run {
            let engine = try currentEngine()
            guard engine.isStreaming else { return }
            engine.stopStream()
        }
        return .result()
    }
}

struct SwitchSceneIntent: AppIntent {
    static var title: LocalizedStringResource = "Switch Scene"
    static var description = IntentDescription("Switch Prism's program to a layout scene.")
    static var openAppWhenRun = true

    @Parameter(title: "Scene")
    var scene: SceneEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Switch Prism to \(\.$scene)")
    }

    func perform() async throws -> some IntentResult {
        try await MainActor.run {
            let engine = try currentEngine()
            guard let preset = ScenePreset(rawValue: scene.id) else {
                throw PrismIntentError.sceneNotFound(scene.id)
            }
            engine.applyPreset(preset)
        }
        return .result()
    }
}

struct SetVirtualCameraIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Virtual Camera"
    static var description = IntentDescription("Turn Prism's virtual camera output on or off.")
    static var openAppWhenRun = true

    @Parameter(title: "Enabled", default: true)
    var enabled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Set Prism virtual camera to \(\.$enabled)")
    }

    func perform() async throws -> some IntentResult {
        try await MainActor.run {
            let engine = try currentEngine()
            engine.setVirtualCameraOutput(enabled)
        }
        return .result()
    }
}

struct SaveReplayIntent: AppIntent {
    static var title: LocalizedStringResource = "Save Replay"
    static var description = IntentDescription("Save the buffered instant-replay window to ~/Movies/Prism/Replays.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        // Codex #6: await the real save so Shortcuts sees success/failure, rather
        // than reporting success while an unstructured task fails later.
        let engine = try await MainActor.run { try currentEngine() }
        _ = try await engine.saveReplayAsync()
        return .result()
    }
}

// MARK: - App Shortcuts (headline, zero-config voice/Spotlight phrases)

struct PrismAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(),
                    phrases: ["Start recording in \(.applicationName)"],
                    shortTitle: "Start Recording",
                    systemImageName: "record.circle")
        AppShortcut(intent: StopRecordingIntent(),
                    phrases: ["Stop recording in \(.applicationName)"],
                    shortTitle: "Stop Recording",
                    systemImageName: "stop.circle")
        AppShortcut(intent: StartStreamIntent(),
                    phrases: ["Start streaming in \(.applicationName)"],
                    shortTitle: "Start Streaming",
                    systemImageName: "antenna.radiowaves.left.and.right")
        AppShortcut(intent: StopStreamIntent(),
                    phrases: ["Stop streaming in \(.applicationName)"],
                    shortTitle: "Stop Streaming",
                    systemImageName: "antenna.radiowaves.left.and.right")
        AppShortcut(intent: SwitchSceneIntent(),
                    phrases: ["Switch scene in \(.applicationName)"],
                    shortTitle: "Switch Scene",
                    systemImageName: "rectangle.on.rectangle")
    }
}
