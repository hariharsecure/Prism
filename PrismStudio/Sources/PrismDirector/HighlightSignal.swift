import CoreMedia
import Foundation

/// One time-stamped evidence event fed to the `HighlightDirector` scoring engine
/// (the "Director's Cut" flagship — see `WORLD_CLASS_VISION.md`).
///
/// This is a **decoupled** value type: the live signal sources never reach into
/// the director and the director never imports them. Each source translates its
/// own native event into a `HighlightSignal` and **pushes** it in via
/// `HighlightDirector.ingest(_:)`, so the engine is unit-testable against a
/// synthetic event stream with no audio/Vision/compositor plumbing.
///
/// ## Timing
/// `pts` is house-time (`HouseClock`), exactly the PTS the source already
/// carries (`TransientInfo.pts`, `CaptionUpdate.hostSeconds`, a
/// `DirectorDecision.atSeconds`, a `LoudnessMeter` sample time). The engine reads
/// time **only** from these stamps — never wall-clock — so a scripted stream is
/// deterministic and replayable (same contract as `AutoDirector`).
///
/// ## Magnitude
/// `magnitude` is a normalized 0…1 intensity for *this* event. Each source maps
/// its native scale into 0…1 (see the factory helpers below); the engine then
/// multiplies by the per-kind `weight` and a time-decay to accumulate a score.
public struct HighlightSignal: Sendable, Equatable {

    /// The evidence channels the director scores. Each maps 1:1 to a real signal
    /// source already in the engine (cited on each case); `chatVelocity` is the
    /// one forward-looking channel (accepted now, unweighted by default) so the
    /// creator-economy chat feed can push in later with no API change.
    public enum Kind: String, Sendable, CaseIterable, Codable {
        /// An audio onset / "hit" — `PrismAudio.TransientDetector.onTransient`
        /// (`TransientInfo`). magnitude ← `TransientInfo.strength` (already 0…1).
        case audioTransient
        /// Program loudness/energy — `PrismAudio.LoudnessMeter.measurement`
        /// (momentary/short-term LUFS). magnitude ← `normalizeLoudness(...)`.
        case loudness
        /// A program cut / scene switch — `PrismDirector.AutoDirector.onDecision`
        /// (`DirectorDecision`) or a compositor transition. An impulse cue.
        case sceneCut
        /// An excitement/keyword hit parsed from a caption line —
        /// `PrismAudio.LiveCaptioner.onCaption` (`CaptionUpdate.text`).
        case captionKeyword
        /// Laughter detected in a caption line ("haha", "lol", "😂", …) —
        /// also derived from `CaptionUpdate`.
        case captionLaughter
        /// Chat-message velocity (future creator-economy feed). Accepted now so
        /// wiring is a no-op later; default weight 0 (contributes nothing until
        /// a weight is configured).
        case chatVelocity
    }

    /// Which evidence channel produced this event.
    public let kind: Kind
    /// House-time PTS of the moment this event describes.
    public let pts: CMTime
    /// Normalized 0…1 intensity of this event (clamped on init).
    public let magnitude: Double

    /// Presentation time in seconds (derived from `pts`; the engine's math clock).
    public var seconds: Double { pts.seconds }

    public init(kind: Kind, pts: CMTime, magnitude: Double) {
        self.kind = kind
        self.pts = pts
        self.magnitude = Swift.min(1, Swift.max(0, magnitude))
    }

    // MARK: - Source adapters (plain-scalar factories — zero coupling)
    //
    // The next slice wires each live source with a one-liner that maps its native
    // event into one of these. None of them reference a PrismAudio/PrismVision
    // type, so `PrismDirector` gains no new module dependency.

    /// From `TransientDetector` → `onTransient` (`TransientInfo`).
    /// Wiring: `director.ingest(.audioTransient(strength: info.strength, at: info.pts))`.
    public static func audioTransient(strength: Double, at pts: CMTime) -> HighlightSignal {
        HighlightSignal(kind: .audioTransient, pts: pts, magnitude: strength)
    }

    /// From a `LoudnessMeter.Measurement` sample. `energy` is a pre-normalized
    /// 0…1 value; use `normalizeLoudness(momentaryLUFS:)` to derive it.
    /// Wiring: sample the meter on a timer and push `normalizeLoudness(...)`.
    public static func loudness(energy: Double, at pts: CMTime) -> HighlightSignal {
        HighlightSignal(kind: .loudness, pts: pts, magnitude: energy)
    }

    /// From `AutoDirector` → `onDecision` (`DirectorDecision`) or a compositor
    /// transition. A cut is an impulse; default full magnitude.
    /// Wiring: `director.ingest(.sceneCut(at: CMTime(seconds: d.atSeconds, ...)))`.
    public static func sceneCut(at pts: CMTime, magnitude: Double = 1.0) -> HighlightSignal {
        HighlightSignal(kind: .sceneCut, pts: pts, magnitude: magnitude)
    }

    /// From `LiveCaptioner` → `onCaption`, after keyword/excitement scoring of
    /// `CaptionUpdate.text`. `intensity` 0…1.
    public static func captionKeyword(intensity: Double, at pts: CMTime) -> HighlightSignal {
        HighlightSignal(kind: .captionKeyword, pts: pts, magnitude: intensity)
    }

    /// From `LiveCaptioner` → `onCaption`, when laughter tokens are found.
    public static func captionLaughter(intensity: Double, at pts: CMTime) -> HighlightSignal {
        HighlightSignal(kind: .captionLaughter, pts: pts, magnitude: intensity)
    }

    /// From a future chat feed. Normalized message-rate 0…1.
    public static func chatVelocity(normalized: Double, at pts: CMTime) -> HighlightSignal {
        HighlightSignal(kind: .chatVelocity, pts: pts, magnitude: normalized)
    }

    // MARK: - Loudness normalization (pure — the canonical LUFS → 0…1 mapping)

    /// Maps a momentary/short-term LUFS reading to a 0…1 energy magnitude by
    /// linearly ranking it in a `[floor, ceil]` LUFS window (values below `floor`
    /// or `-inf`/silence → 0, at/above `ceil` → 1).
    ///
    /// Defaults bracket a typical stream master: −40 LUFS (a quiet bed) → 0,
    /// −10 LUFS (a loud, hot moment) → 1. Pure and unit-testable so the wiring
    /// layer and tests share one mapping (mirrors `LiveCaptioner.resolveReadiness`).
    public static func normalizeLoudness(momentaryLUFS lufs: Double,
                                         floor: Double = -40,
                                         ceil: Double = -10) -> Double {
        guard lufs.isFinite, ceil > floor else { return 0 }
        let t = (lufs - floor) / (ceil - floor)
        return Swift.min(1, Swift.max(0, t))
    }
}
