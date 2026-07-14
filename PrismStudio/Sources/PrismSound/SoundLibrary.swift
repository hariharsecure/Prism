import Foundation
import PrismCore

/// One catalogued sound in the generated library (`library.json` element).
public struct SoundEntry: Codable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let category: String
    public let tags: [String]
    public let durationSec: Double
    public let channels: Int
    public let sampleRate: Int
    /// File name relative to the library root (e.g. `drums/kick_0007.wav`).
    public let file: String

    public init(id: String, name: String, category: String, tags: [String],
                durationSec: Double, channels: Int, sampleRate: Int, file: String) {
        self.id = id; self.name = name; self.category = category; self.tags = tags
        self.durationSec = durationSec; self.channels = channels
        self.sampleRate = sampleRate; self.file = file
    }

    public var isLoopable: Bool { tags.contains("loop") || tags.contains("loopable") }
}

/// Read-only catalog over a generated sound library: loads `library.json`,
/// resolves file URLs, and searches by category / tag / name.
public final class SoundLibrary: @unchecked Sendable {
    public enum LibraryError: Error, CustomStringConvertible {
        case manifestMissing(URL)
        case decodeFailed(String)
        public var description: String {
            switch self {
            case .manifestMissing(let u): return "library.json not found at \(u.path)"
            case .decodeFailed(let w): return "library.json decode failed: \(w)"
            }
        }
    }

    public let rootURL: URL
    public let entries: [SoundEntry]
    private let byID: [String: SoundEntry]
    private let log = EngineLog.logger("sound.library")

    /// The default install location under Application Support.
    public static var defaultRootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("studio.prism.app/SoundLibrary", isDirectory: true)
    }

    public init(rootURL: URL, entries: [SoundEntry]) {
        self.rootURL = rootURL
        self.entries = entries
        self.byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Load a library from a root directory containing `library.json`.
    public convenience init(root: URL) throws {
        let manifest = root.appendingPathComponent("library.json")
        guard let data = try? Data(contentsOf: manifest) else {
            throw LibraryError.manifestMissing(manifest)
        }
        do {
            let entries = try JSONDecoder().decode([SoundEntry].self, from: data)
            self.init(rootURL: root, entries: entries)
        } catch {
            throw LibraryError.decodeFailed(String(describing: error))
        }
    }

    /// Load from the default install path; if absent, fall back to
    /// `bundledFallback` (a bundled default library) when provided. Returns nil
    /// only if neither exists — callers degrade gracefully.
    public static func loadDefault(bundledFallback: URL? = nil) -> SoundLibrary? {
        if let lib = try? SoundLibrary(root: defaultRootURL) { return lib }
        if let fb = bundledFallback, let lib = try? SoundLibrary(root: fb) { return lib }
        return nil
    }

    // MARK: Lookup

    public func entry(id: String) -> SoundEntry? { byID[id] }

    /// Absolute URL of a sound's WAV file.
    public func url(for entry: SoundEntry) -> URL { rootURL.appendingPathComponent(entry.file) }
    public func url(forID id: String) -> URL? { byID[id].map { url(for: $0) } }

    /// Distinct categories present, sorted.
    public var categories: [String] { Array(Set(entries.map(\.category))).sorted() }

    /// Distinct tags present, sorted.
    public var allTags: [String] { Array(Set(entries.flatMap(\.tags))).sorted() }

    public func entries(inCategory category: String) -> [SoundEntry] {
        entries.filter { $0.category == category }
    }

    public func entries(withTag tag: String) -> [SoundEntry] {
        let t = tag.lowercased()
        return entries.filter { $0.tags.contains { $0.lowercased() == t } }
    }

    public var loopable: [SoundEntry] { entries.filter(\.isLoopable) }

    /// Free-text search over name, category and tags (case-insensitive AND of terms).
    public func search(_ query: String) -> [SoundEntry] {
        let terms = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        guard !terms.isEmpty else { return entries }
        return entries.filter { e in
            let hay = ([e.name, e.category] + e.tags).joined(separator: " ").lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
    }

    /// Category → count, for reporting.
    public var countsByCategory: [(category: String, count: Int)] {
        var counts: [String: Int] = [:]
        for e in entries { counts[e.category, default: 0] += 1 }
        return counts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}
