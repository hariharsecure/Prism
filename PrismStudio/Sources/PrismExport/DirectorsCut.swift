import Foundation
import PrismCore

/// Capture-time metadata that turns a bare multicam export into a **metadata-rich
/// Final Cut handoff** (WORLD_CLASS_VISION "Director's Cut"; DESIGN §2.5). Prism
/// knows things a downstream editor never gets — where the live cuts happened, which
/// moments the auto-director flagged (and *why*), the live transcript, and the
/// separate audio stems behind the baked mix. This struct carries that so the
/// exporter can pre-annotate the first cut.
///
/// It is **decoupled from the App**: it uses only `PrismCore` + Foundation types, so
/// it is populated by the App (mapping `HighlightDirector.Highlight`, `CaptionUpdate`,
/// the program-switch log, and the recorded stem files onto these fields) but tested
/// here without any App or capture hardware.
///
/// All `atSeconds` are **timeline seconds** — offsets from the session's shared start
/// (`MulticamSession.sessionStart`), the same zero the multicam angles are placed on.
public struct DirectorsCut: Sendable {
    /// The live program cuts, in the order they occurred. Each defines a segment
    /// boundary of the editable multicam and gets a chapter marker.
    public var programSwitches: [ProgramSwitch]
    /// Auto-director highlight candidates. Each becomes a labeled marker (score +
    /// reason) and a browser keyword range.
    public var highlights: [Highlight]
    /// The live-caption transcript, one cue per line, aligned to its timecode.
    public var captions: [Caption]
    /// The separated audio stems (mic / soundboard / music / master) behind the mix.
    public var audioStems: [AudioStem]

    public init(programSwitches: [ProgramSwitch] = [],
                highlights: [Highlight] = [],
                captions: [Caption] = [],
                audioStems: [AudioStem] = []) {
        self.programSwitches = programSwitches
        self.highlights = highlights
        self.captions = captions
        self.audioStems = audioStems
    }

    /// True when there is nothing to enrich — the exporter then emits the plain,
    /// backward-compatible single-clip multicam.
    public var isEmpty: Bool {
        programSwitches.isEmpty && highlights.isEmpty && captions.isEmpty && audioStems.isEmpty
    }
}

/// One live program cut: at `atSeconds` the switcher put `source` on the program.
/// Drives both a chapter marker (labeled `sourceName`) and a cut point in the
/// editable multicam (the segment that starts here selects `source`'s angle).
public struct ProgramSwitch: Sendable {
    /// Timeline seconds at which the cut happened.
    public var atSeconds: Double
    /// Human-readable name of the source that went live (the chapter-marker label).
    public var sourceName: String
    /// Which angle became live, so a downstream editor's segment re-selects it.
    /// `nil` falls back to the program angle.
    public var source: SourceID?

    public init(atSeconds: Double, sourceName: String, source: SourceID? = nil) {
        self.atSeconds = atSeconds
        self.sourceName = sourceName
        self.source = source
    }
}

/// One auto-director highlight candidate. `score`/`reason` map from
/// `HighlightDirector.Highlight.score` / `.dominantSignal`.
public struct Highlight: Sendable {
    /// Peak instant (timeline seconds) — where the marker lands.
    public var atSeconds: Double
    /// The hype window length (marker/keyword duration).
    public var durationSeconds: Double
    /// Peak momentary score (higher = hotter).
    public var score: Double
    /// Why it was flagged (the dominant signal), e.g. "crowd cheer".
    public var reason: String

    public init(atSeconds: Double, durationSeconds: Double, score: Double, reason: String) {
        self.atSeconds = atSeconds
        self.durationSeconds = durationSeconds
        self.score = score
        self.reason = reason
    }
}

/// One live-caption cue: `text` shown from `atSeconds` for `durationSeconds`.
public struct Caption: Sendable {
    public var atSeconds: Double
    public var durationSeconds: Double
    public var text: String

    public init(atSeconds: Double, durationSeconds: Double, text: String) {
        self.atSeconds = atSeconds
        self.durationSeconds = durationSeconds
        self.text = text
    }
}

/// One separated audio stem recorded alongside the show — the raw ingredient behind
/// the baked program mix. Each maps to a labeled FCPXML audio role + lane.
public struct AudioStem: Sendable {
    /// The stem family. The raw value is the FCPXML subrole; `mainRole` is the
    /// standard main role it nests under.
    public enum Kind: String, Sendable, CaseIterable {
        case mic, soundboard, music, master

        /// Standard FCPXML main audio role this stem nests under. `dialogue` /
        /// `music` / `effects` are FCP built-ins (Resolve maps roles → tracks);
        /// `mix` is a custom main role for the full master.
        public var mainRole: String {
            switch self {
            case .mic:        return "dialogue"
            case .soundboard: return "effects"
            case .music:      return "music"
            case .master:     return "mix"
            }
        }

        /// The `main.sub` FCPXML role string, e.g. `dialogue.mic`.
        public var role: String { "\(mainRole).\(rawValue)" }
    }

    public var kind: Kind
    /// Display name for the clip (defaults to the kind if empty).
    public var name: String
    /// The recorded stem `.mov` / `.caf` / `.wav` on disk.
    public var url: URL
    /// Channel count of the stem file.
    public var channels: Int
    /// Stem duration in seconds; `nil` means "spans the whole session".
    public var durationSeconds: Double?

    public init(kind: Kind, name: String, url: URL, channels: Int = 2, durationSeconds: Double? = nil) {
        self.kind = kind
        self.name = name
        self.url = url
        self.channels = channels
        self.durationSeconds = durationSeconds
    }
}
