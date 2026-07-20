import Foundation
import PrismCore
import os

// MARK: - Source persistence (closes the "a saved show can't reopen" gap)
//
// THE GAP: before this file, `SettingsPersistence.swift` restored the SCENE
// (layers/frames/z-order) but NOT the sources those layers reference — the app
// admitted as much. So a relaunched show pointed at sources that no longer
// existed until the operator manually re-added every camera/mic/screen/clip.
// A live-production app must reopen the SAME show.
//
// WHAT IS PERSISTED: the five re-addable source kinds, each by a STABLE identity
// (never a display name, which changes):
//   • camera / microphone → AVCaptureDevice.uniqueID (SourceDescriptor.id)
//   • screen/window/app    → the SCK display/window id (best-effort; screens are
//                            inherently ephemeral, so a stale id degrades, never
//                            crashes)
//   • image / movie        → a SECURITY-SCOPED BOOKMARK (reusing the same
//                            make/resolveBookmark helpers as the meme tiles), plus
//                            the movie's `loop` flag.
// Each entry also keeps the user-facing name so an ABSENT device/file can still
// be shown/logged.
//
// STORAGE: mirrors `SceneCollectionStore` exactly — a Codable array as JSON in
// Application Support, atomic write, and corrupt-file → sidecar-then-empty so a
// save can't clobber recoverable data.
//
// GRACEFUL DEGRADATION (the mandatory judgment part) lives in the PURE
// `PersistedSource.plan(from:availableDeviceIDs:)` planner: it classifies each
// entry as "restore this" or "unavailable — keep it" WITHOUT touching hardware,
// so it is unit-testable. A camera whose device is unplugged, or a movie whose
// file was deleted, is skipped (never force-unwrapped, never crashes) and the
// entry is RETAINED on disk so it reappears when the device/file returns — the
// same "a dangling ref is harmless" philosophy the stinger/meme media already
// use. One failed source never aborts the rest of the restore.

/// Add-time capture of a file source's backing so it can be persisted as a
/// bookmark (the runtime `SourceDescriptor.id` of a media source is a throwaway
/// `SourceID`, so the file identity has to be recorded when the source is added).
struct PersistableSourceFile {
    var bookmark: Data
    var isMovie: Bool
    var loop: Bool?
}

// MARK: DTO

/// One persisted source: its kind, a stable identity, and per-kind settings.
/// Codable so it round-trips through JSON on disk. Everything that identifies a
/// source across relaunches lives here; the ephemeral runtime object does not.
struct PersistedSource: Codable, Equatable {
    enum Kind: String, Codable {
        case camera, microphone, screen, image, movie
    }

    /// Which addX entry point restores this.
    var kind: Kind
    /// User-facing name — shown/logged when the device or file is absent.
    var name: String
    /// Stable device identity: AVCaptureDevice.uniqueID for camera/mic, or the
    /// SCK display/window id for a screen. `nil` for file sources.
    var deviceID: String?
    /// The original `SourceKind.rawValue` for a screen source (display / window /
    /// application), so the descriptor is rebuilt with the right kind. `nil`
    /// otherwise.
    var screenKind: String?
    /// Whether a screen source also captured its app/system audio. `nil` for
    /// non-screen sources (restore defaults screens to `true`, matching `addScreen`).
    var captureAudio: Bool?
    /// Security-scoped bookmark to the backing file for image/movie sources.
    /// `nil` for device sources.
    var bookmark: Data?
    /// Movie loop flag. `nil` for non-movie sources.
    var loop: Bool?

    // MARK: Identity (for de-duping the on-disk set)

    /// A stable key used to avoid persisting the same source twice when the
    /// live set and the retained-absent set are merged.
    var identityKey: String {
        switch kind {
        case .camera, .microphone, .screen:
            return "\(kind.rawValue):\(deviceID ?? name)"
        case .image, .movie:
            // Bookmarks to the same file are byte-identical when produced the same
            // way; hashing the bytes is a good-enough stable key.
            return "\(kind.rawValue):\(bookmark?.hashValue ?? name.hashValue)"
        }
    }
}

// MARK: - Restore plan (pure, hardware-free — the graceful-degradation core)

/// What the planner decided to do with one persisted entry.
enum SourceRestoreOutcome: Equatable {
    /// The source can be recreated now: replay through the paired addX entry point.
    case restore(SourceRestoreAction)
    /// The device/file is absent or the identity is unusable — SKIP creating it
    /// but KEEP the entry (it reappears when the device/file returns). Never a crash.
    case unavailable(reason: String)
}

/// The concrete recreate instruction for an available source. Carries resolved,
/// ready-to-use values (a matched descriptor / an existing file URL) so the
/// engine side just calls the matching addX with them.
enum SourceRestoreAction: Equatable {
    case camera(deviceID: String)
    case microphone(deviceID: String)
    case screen(descriptorID: String, kind: SourceKind, captureAudio: Bool)
    case image(url: URL)
    case movie(url: URL, loop: Bool)
}

/// A planner decision paired with the entry it came from.
struct SourceRestorePlan: Equatable {
    let source: PersistedSource
    let outcome: SourceRestoreOutcome
}

extension PersistedSource {
    /// PURE classification of a persisted set into restore/keep decisions — the
    /// heart of graceful degradation, deliberately free of any live AppEngine or
    /// real hardware so it is unit-testable.
    ///
    /// - `availableDeviceIDs`: the uniqueIDs of cameras + mics currently present.
    /// - `resolveBookmark`: injected file-bookmark resolver (defaults to the app's
    ///   security-scoped resolver); a `nil` result OR a resolved-but-missing file
    ///   both classify as "unavailable, keep".
    /// - `fileExists`: injected existence check (defaults to `FileManager`), so a
    ///   deleted-file case is testable deterministically.
    ///
    /// Screens are inherently ephemeral: a screen entry with an id is always
    /// planned for a best-effort restore (the `addScreen` path itself degrades
    /// gracefully if the display is gone); an id-less screen is kept as unavailable.
    static func plan(
        from sources: [PersistedSource],
        availableDeviceIDs: Set<String>,
        resolveBookmark: (Data) -> URL? = AppEngine.resolveBookmark,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [SourceRestorePlan] {
        sources.map { source in
            SourceRestorePlan(source: source,
                              outcome: source.outcome(availableDeviceIDs: availableDeviceIDs,
                                                       resolveBookmark: resolveBookmark,
                                                       fileExists: fileExists))
        }
    }

    private func outcome(
        availableDeviceIDs: Set<String>,
        resolveBookmark: (Data) -> URL?,
        fileExists: (URL) -> Bool
    ) -> SourceRestoreOutcome {
        switch kind {
        case .camera:
            guard let id = deviceID else { return .unavailable(reason: "camera has no device id") }
            guard availableDeviceIDs.contains(id) else {
                return .unavailable(reason: "camera absent: \(name)")
            }
            return .restore(.camera(deviceID: id))

        case .microphone:
            guard let id = deviceID else { return .unavailable(reason: "microphone has no device id") }
            guard availableDeviceIDs.contains(id) else {
                return .unavailable(reason: "microphone absent: \(name)")
            }
            return .restore(.microphone(deviceID: id))

        case .screen:
            guard let id = deviceID else { return .unavailable(reason: "screen has no id") }
            let kind = screenKind.flatMap(SourceKind.init(rawValue:)) ?? .display
            return .restore(.screen(descriptorID: id, kind: kind, captureAudio: captureAudio ?? true))

        case .image:
            guard let bookmark, let url = resolveBookmark(bookmark), fileExists(url) else {
                return .unavailable(reason: "image file missing: \(name)")
            }
            return .restore(.image(url: url))

        case .movie:
            guard let bookmark, let url = resolveBookmark(bookmark), fileExists(url) else {
                return .unavailable(reason: "video file missing: \(name)")
            }
            return .restore(.movie(url: url, loop: loop ?? true))
        }
    }
}

// MARK: - Disk store (mirrors SceneCollectionStore)

/// JSON persistence for the active-source set, under Application Support. The
/// on-disk file is the source of truth restored at every launch.
enum PersistedSourceStore {
    /// `~/Library/Application Support/studio.prism.app/Sources.json`.
    static var fileURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("studio.prism.app", isDirectory: true)
        return dir.appendingPathComponent("Sources.json")
    }

    /// Load the persisted sources. A missing file is a normal first launch (→
    /// empty). A file that EXISTS but fails to decode is corrupt: sidecar it to
    /// `Sources.corrupt-<n>.json` before returning [] so the next save can't
    /// overwrite (and destroy) recoverable data — the same robustness as
    /// `SceneCollectionStore`.
    static func load() -> [PersistedSource] {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else { return [] } // missing = first launch
        if let decoded = try? JSONDecoder().decode([PersistedSource].self, from: data) {
            return decoded
        }
        let dir = url.deletingLastPathComponent()
        var n = 0
        var backup = dir.appendingPathComponent("Sources.corrupt.json")
        while FileManager.default.fileExists(atPath: backup.path) {
            n += 1
            backup = dir.appendingPathComponent("Sources.corrupt-\(n).json")
        }
        try? FileManager.default.copyItem(at: url, to: backup)
        return []
    }

    /// Write the sources atomically (creating the directory as needed).
    static func save(_ sources: [PersistedSource]) throws {
        let url = fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sources)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - AppEngine wiring (save-on-change + restore-on-launch)

extension AppEngine {
    private static let sourcePersistLog = EngineLog.logger("app.sourcePersistence")

    /// True inside an XCTest host: skip both disk writes AND the live restore so
    /// unit tests stay hardware-free and never touch real Application Support or
    /// trip a capture-permission prompt. (The DTO + planner are tested directly.)
    private var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // MARK: Save

    /// Serialize the current active-source set to disk. Called whenever
    /// `activeSources` changes (see the `didSet`). Merges the live sources with
    /// the entries that were RETAINED because their device/file was absent at
    /// restore, so an unplugged device is not dropped from the file — it stays so
    /// it can reappear later. De-duped by `identityKey` (a live source wins over a
    /// retained one). Best-effort: a serialization failure is logged, never fatal.
    func persistActiveSources() {
        guard !isRunningUnitTests, !isSourcePersistenceSuspended else { return }
        var out: [PersistedSource] = []
        var seen = Set<String>()
        for active in activeSources {
            guard let dto = persistedSource(for: active) else { continue }
            if seen.insert(dto.identityKey).inserted { out.append(dto) }
        }
        for retained in retainedAbsentSources where seen.insert(retained.identityKey).inserted {
            out.append(retained)
        }
        do {
            try PersistedSourceStore.save(out)
        } catch {
            Self.sourcePersistLog.error("persistActiveSources failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Build the persisted DTO for a live source, or `nil` for a kind that is not
    /// re-addable from persistence (text/browser/GIF/link/system-audio) — those
    /// are intentionally out of scope.
    private func persistedSource(for active: ActiveSource) -> PersistedSource? {
        let d = active.descriptor
        switch active.backing {
        case .camera:
            return PersistedSource(kind: .camera, name: d.name, deviceID: d.id)
        case .microphone:
            return PersistedSource(kind: .microphone, name: d.name, deviceID: d.id)
        case .screen(let screen):
            return PersistedSource(kind: .screen, name: d.name, deviceID: d.id,
                                   screenKind: d.kind.rawValue,
                                   captureAudio: screen.configuration.capturesAudio)
        case .movie:
            // The stable identity of a file source is its bookmark, captured at
            // add-time in `persistableSourceFiles` (the descriptor.id is a random
            // runtime SourceID, useless across relaunches).
            guard let file = persistableSourceFiles[active.id] else { return nil }
            return PersistedSource(kind: .movie, name: d.name, bookmark: file.bookmark,
                                   loop: file.loop ?? true)
        case .generated:
            // Only IMAGE generated sources are persistable; text/browser/GIF are not,
            // so gate on the presence of a recorded file bookmark.
            guard let file = persistableSourceFiles[active.id], !file.isMovie else { return nil }
            return PersistedSource(kind: .image, name: d.name, bookmark: file.bookmark)
        case .link, .systemAudio:
            return nil
        }
    }

    /// Record the backing file for an image/movie source so it can be persisted
    /// as a bookmark. Called from `addImageSource` / `addMovieSource` right after
    /// the source is created. A URL that can't be bookmarked is simply not
    /// recorded (that source won't persist) — never fatal.
    func registerPersistableSourceFile(id: SourceID, url: URL, isMovie: Bool, loop: Bool?) {
        guard let bookmark = Self.makeBookmark(url) else { return }
        persistableSourceFiles[id] = PersistableSourceFile(bookmark: bookmark, isMovie: isMovie, loop: loop)
    }

    // MARK: Restore

    /// Restore the persisted sources at launch. Decodes the store, plans each
    /// entry via the PURE planner (so availability is decided hardware-free), then
    /// replays only the AVAILABLE ones through their addX entry point. Absent
    /// entries are retained (so a later save keeps them) and logged — never
    /// dropped, never force-unwrapped, never allowed to abort the whole restore.
    ///
    /// Must be called AFTER `refreshDevices()` (so `cameras`/`microphones` are
    /// populated) and is a no-op under XCTest (no capture prompts in unit tests).
    func restorePersistedSources() {
        guard !isRunningUnitTests else { return }
        let stored = PersistedSourceStore.load()
        guard !stored.isEmpty else { return }

        let available = Set(cameras.map(\.id)).union(microphones.map(\.id))
        let plans = PersistedSource.plan(from: stored, availableDeviceIDs: available)

        // Suspend save-on-change while we replay, so each addX doesn't rewrite the
        // file mid-restore; we retain the absent set and save ONCE at the end.
        isSourcePersistenceSuspended = true
        retainedAbsentSources = []
        for plan in plans {
            switch plan.outcome {
            case .unavailable(let reason):
                retainedAbsentSources.append(plan.source)
                Self.sourcePersistLog.info("source kept (unavailable): \(reason, privacy: .public)")
            case .restore(let action):
                applyRestore(action, name: plan.source.name)
            }
        }
        isSourcePersistenceSuspended = false
        persistActiveSources() // one consolidated save: live sources + retained-absent
    }

    /// Replay one available source through its matching addX entry point. Any
    /// failure inside an addX is already contained there (it sets `lastError`,
    /// never crashes), so one bad source can't abort the loop.
    private func applyRestore(_ action: SourceRestoreAction, name: String) {
        switch action {
        case .camera(let deviceID):
            let descriptor = cameras.first { $0.id == deviceID }
                ?? SourceDescriptor(kind: .camera, id: deviceID, name: name)
            addCamera(descriptor)
        case .microphone(let deviceID):
            let descriptor = microphones.first { $0.id == deviceID }
                ?? SourceDescriptor(kind: .microphone, id: deviceID, name: name)
            addMicrophone(descriptor)
        case .screen(let descriptorID, let kind, let captureAudio):
            addScreen(SourceDescriptor(kind: kind, id: descriptorID, name: name),
                      captureAudio: captureAudio)
        case .image(let url):
            // Image data is cached synchronously by ImageSource, so the scoped
            // grant can be released right after (matches restoreUserMemes).
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            addImageSource(fileURL: url)
        case .movie(let url, let loop):
            // addMovieSource re-acquires and HOLDS its own scoped grant for the
            // clip's lifetime, so no wrapping scope here.
            addMovieSource(fileURL: url, loop: loop)
        }
    }
}
