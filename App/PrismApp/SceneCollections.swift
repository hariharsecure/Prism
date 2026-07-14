import Foundation
import PrismAnimation
import PrismCompositor

// MARK: - v2 deliverable 1: Scene collection model + disk store

/// A persisted named layout: a snapshot of the program `Scene` (its layers,
/// frames, z-order, opacity, visibility — all `Codable`) plus the scene preset
/// that was active. Saved to Application Support as JSON and restored at launch.
struct SceneCollection: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// The compositor scene snapshot (PrismCompositor.Scene is Codable).
    var scene: ProgramScene
    /// The `ScenePreset` that was selected, by raw value (kept as a string so a
    /// future preset rename doesn't fail decoding older files).
    var presetRawValue: String
    var savedAt: Date

    init(id: UUID = UUID(), name: String, scene: ProgramScene,
         presetRawValue: String, savedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.scene = scene
        self.presetRawValue = presetRawValue
        self.savedAt = savedAt
    }
}

/// JSON persistence for the scene collections, under Application Support.
/// Everything round-trips through the filesystem — the on-disk file is the
/// source of truth restored at every launch.
enum SceneCollectionStore {
    /// `~/Library/Application Support/studio.prism.app/SceneCollections.json`.
    static var fileURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("studio.prism.app", isDirectory: true)
        return dir.appendingPathComponent("SceneCollections.json")
    }

    /// Load the persisted collections. A missing file is a normal first launch
    /// (→ empty). A file that EXISTS but fails to decode is corrupt: rather than
    /// silently returning [] — which the next save would atomically overwrite,
    /// destroying recoverable data (Codex F6) — we sidecar the bad file to
    /// `SceneCollections.corrupt-<n>.json` so a save can't clobber it.
    static func load() -> [SceneCollection] {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else { return [] } // missing = first launch
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([SceneCollection].self, from: data) {
            return decoded
        }
        // Corrupt: preserve it before anything overwrites the original.
        let dir = url.deletingLastPathComponent()
        var n = 0
        var backup = dir.appendingPathComponent("SceneCollections.corrupt.json")
        while FileManager.default.fileExists(atPath: backup.path) {
            n += 1
            backup = dir.appendingPathComponent("SceneCollections.corrupt-\(n).json")
        }
        try? FileManager.default.copyItem(at: url, to: backup)
        return []
    }

    /// Write the collections atomically (creating the directory as needed).
    static func save(_ collections: [SceneCollection]) throws {
        let url = fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(collections)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - v2 deliverable 3: layer-entrance preset (UI ↔ PrismAnimation bridge)

/// A picker-friendly wrapper over `PrismAnimation.LayerEntrance`, so the layer
/// inspector can offer the four entrance styles with sensible default
/// parameters and map each to the engine's `LayerEntrance` factory.
enum LayerEntrancePreset: String, CaseIterable, Identifiable {
    case slideIn = "Slide In"
    case fadeIn = "Fade In"
    case scaleIn = "Scale In"
    case pop = "Pop"

    var id: String { rawValue }

    /// SF Symbol shown alongside the entry in menus.
    var systemImage: String {
        switch self {
        case .slideIn: return "arrow.right.to.line"
        case .fadeIn: return "circle.dotted"
        case .scaleIn: return "arrow.up.left.and.arrow.down.right"
        case .pop: return "sparkles"
        }
    }

    /// The engine-level entrance, with reasonable default parameters.
    var entrance: LayerEntrance {
        switch self {
        case .slideIn: return .slideIn(from: .left)
        case .fadeIn: return .fadeIn
        case .scaleIn: return .scaleIn(fromScale: 0.5)
        case .pop: return .pop
        }
    }
}
