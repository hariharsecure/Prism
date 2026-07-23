import Foundation
import PrismOutput

// MARK: - Deliverable B: persisted multi-destination restream targets

/// Codable mirror of `PrismOutput.Destination` (which is deliberately not
/// Codable — it is a runtime value the broadcaster builds outputs from). This
/// is the on-disk shape; `destination` maps it back to the engine type.
struct PersistedDestination: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// "rtmp" or "srt" — stored as a string so an unknown future proto in an
    /// older file decodes (and is dropped) rather than failing the whole load.
    var proto: String
    var url: String
    var key: String
    var enabled: Bool

    init(id: UUID = UUID(), name: String, proto: Destination.Proto,
         url: String, key: String = "", enabled: Bool = true) {
        self.id = id
        self.name = name
        self.proto = proto.rawValue
        self.url = url
        self.key = key
        self.enabled = enabled
    }

    init(_ destination: Destination) {
        self.id = destination.id
        self.name = destination.name
        self.proto = destination.proto.rawValue
        self.url = destination.url
        self.key = destination.key
        self.enabled = destination.enabled
    }

    /// The runtime `Destination`, or nil for an unrecognized protocol.
    var destination: Destination? {
        guard let proto = Destination.Proto(rawValue: proto) else { return nil }
        return Destination(id: id, name: name, proto: proto,
                           url: url, key: key, enabled: enabled)
    }
}

/// JSON persistence for the restream destinations, under Application Support —
/// same pattern as `SceneCollectionStore`. The on-disk file is the source of
/// truth restored at every launch.
enum StreamDestinationsStore {
    /// Test seam: the Keychain writer (default = the real Keychain). A headless
    /// test — where the live Keychain isn't writable under ad-hoc signing —
    /// substitutes a stub that returns `false` to simulate a write failure and
    /// assert the fail-closed contract (no plaintext key ever lands in JSON).
    /// Signature mirrors `KeychainStore.set(_:for:)` → returns write success.
    static var keychainSet: (_ value: String, _ account: String) -> Bool = {
        KeychainStore.set($0, for: $1)
    }

    /// Test seam: the Keychain reader (default = the real Keychain), so the
    /// load-time legacy-plaintext migration can be exercised headlessly.
    static var keychainGet: (_ account: String) -> String? = { KeychainStore.get($0) }

    /// Set by `save` when one or more stream keys could NOT be persisted to the
    /// Keychain. Fail-closed: those keys stay ONLY in memory for this session
    /// (never written to JSON) and won't survive relaunch. `nil` = clean save.
    static private(set) var lastError: String?

    /// `~/Library/Application Support/studio.prism.app/StreamDestinations.json`.
    static var fileURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("studio.prism.app", isDirectory: true)
        return dir.appendingPathComponent("StreamDestinations.json")
    }

    /// Codex #9: a row decoder that yields nil (instead of throwing) on a malformed
    /// entry, so ONE bad row is skipped rather than dropping the whole list.
    private struct LenientRow: Decodable {
        let value: PersistedDestination?
        init(from decoder: Decoder) throws {
            value = try? PersistedDestination(from: decoder)
        }
    }

    /// Load persisted destinations (missing file = first launch → empty).
    ///
    /// Codex #9: rows are decoded one-by-one — a single malformed entry is skipped,
    /// not the entire array. Only a top-level shape that isn't even an array is
    /// sidecar'd to `.corrupt.json` (so the next save can't atomically clobber
    /// recoverable data — Codex F6 pattern).
    ///
    /// Codex #8: the stream key/streamid is NOT read from the JSON — it lives in
    /// the Keychain (keyed by the destination id). Any legacy plaintext `key` in an
    /// old file is migrated into the Keychain once, then dropped on the next save.
    static func load() -> [Destination] { load(from: fileURL) }

    /// Testable overload: load from an explicit URL (default path = `fileURL`).
    static func load(from url: URL) -> [Destination] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let rows = try? JSONDecoder().decode([LenientRow].self, from: data) else {
            sidecarCorruptFile(at: url) // not an array at all → preserve + start empty
            return []
        }
        return rows.compactMap { row -> Destination? in
            guard let persisted = row.value,                 // #9: skip one bad row
                  var dest = persisted.destination else { return nil } // + unknown proto
            let account = persisted.id.uuidString
            if let secret = keychainGet(account) {
                dest.key = secret
            } else if !persisted.key.isEmpty {
                // Legacy plaintext key on disk → migrate into the Keychain once.
                _ = keychainSet(persisted.key, account)
                dest.key = persisted.key
            } else {
                dest.key = ""
            }
            return dest
        }
    }

    /// Write destinations atomically (creating the directory as needed).
    ///
    /// Codex #8: each secret is stored in the Keychain (keyed by the destination
    /// id); the JSON row keeps only the reference — its `key` field is written
    /// EMPTY so no secret ever touches the plaintext file.
    ///
    /// FAIL-CLOSED (Phase 5a): a stream key is a credential. On a Keychain WRITE
    /// FAILURE we do NOT fall back to writing plaintext into the JSON (a
    /// screen-shared setup would leak it) — the JSON `key` is ALWAYS written
    /// empty, exactly as the success path. The unsaved key survives only in the
    /// in-memory `Destination.key` for this session; a warning is logged and
    /// surfaced via `lastError` so the operator knows it won't survive relaunch.
    static func save(_ destinations: [Destination]) throws {
        try save(destinations, to: fileURL)
    }

    /// Testable overload: write to an explicit URL (default path = `fileURL`).
    static func save(_ destinations: [Destination], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var failedNames: [String] = []
        let rows = destinations.map { dest -> PersistedDestination in
            let hasKey = !dest.key.isEmpty
            let stored = keychainSet(dest.key, dest.id.uuidString)
            // A non-empty key that the Keychain refused → it lives in memory only.
            if hasKey && !stored { failedNames.append(dest.name) }
            var row = PersistedDestination(dest)
            // Always blank the JSON key — fail CLOSED. Never persist a stream key
            // as plaintext, even when the Keychain write failed (re-verify: the
            // old plaintext fallback leaked the credential to the on-disk file).
            row.key = ""
            return row
        }
        if failedNames.isEmpty {
            lastError = nil
        } else {
            let names = failedNames.joined(separator: ", ")
            let message = "Stream key for \(names) couldn't be saved to the Keychain; "
                + "it works this session but must be re-entered after relaunch."
            lastError = message
            NSLog("StreamDestinationsStore: %@", message)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rows)
        try data.write(to: url, options: .atomic)
    }

    /// Copy an undecodable file aside so an atomic save can't clobber it.
    private static func sidecarCorruptFile(at url: URL) {
        let dir = url.deletingLastPathComponent()
        var n = 0
        var backup = dir.appendingPathComponent("StreamDestinations.corrupt.json")
        while FileManager.default.fileExists(atPath: backup.path) {
            n += 1
            backup = dir.appendingPathComponent("StreamDestinations.corrupt-\(n).json")
        }
        try? FileManager.default.copyItem(at: url, to: backup)
    }
}
