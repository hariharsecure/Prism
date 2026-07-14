import CoreGraphics
import CoreMedia
import Foundation
import PrismCore

/// Per-source activity signal produced by `DirectorAnalyzer` for one analyzed
/// frame. This is the *input* to the policy engine (`AutoDirector`) and the
/// framer (`AutoFramer`); it carries everything the director needs to decide
/// **who to cut to** and **how to frame them**, and nothing about pixels.
///
/// Geometry convention matches `PrismCompositor.Layer`: `faceBounds` is a
/// normalized (0…1) rect with a **top-left origin, y-down** — the same space
/// `Layer.crop`/`Layer.frame` live in — so the framer's output drops straight
/// into a layer with no flip.
public struct SourceSignal: Sendable, Equatable {
    /// The source this signal describes.
    public let source: SourceID
    /// House-time PTS of the frame this signal was computed from. The policy
    /// engine uses these timestamps as its clock (never wall-clock), so a
    /// scripted sequence is fully deterministic and replayable.
    public let pts: CMTime

    /// A face/person was detected above the analyzer's confidence floor.
    public var facePresent: Bool
    /// Detection confidence of the chosen face, 0…1 (0 when absent).
    public var faceConfidence: Float
    /// Largest detected face, normalized top-left-origin within the source
    /// frame; `nil` when no face is present. Feeds `AutoFramer`.
    public var faceBounds: CGRect?
    /// Frame-difference magnitude 0…1 (mean absolute luma delta vs the previous
    /// analyzed frame from this source), a cheap "is something moving" proxy.
    public var motionEnergy: Float
    /// Optional audio-level hook, 0…1 (loudness of this source's mic). `nil`
    /// when audio isn't wired in. When present it dominates the activity score
    /// — audio is the truest "who is speaking" signal (DESIGN §3.3: audio is
    /// master). This is a stub the app fills in; the analyzer never sets it.
    public var audioLevel: Float?

    public init(source: SourceID,
                pts: CMTime,
                facePresent: Bool = false,
                faceConfidence: Float = 0,
                faceBounds: CGRect? = nil,
                motionEnergy: Float = 0,
                audioLevel: Float? = nil) {
        self.source = source
        self.pts = pts
        self.facePresent = facePresent
        self.faceConfidence = faceConfidence
        self.faceBounds = faceBounds
        self.motionEnergy = motionEnergy
        self.audioLevel = audioLevel
    }

    /// The scalar the policy engine ranks sources by, 0…1.
    ///
    /// Semantics: a source is a switch candidate when a person is present
    /// and/or audible. Presence alone earns a low baseline (so a silent
    /// on-screen guest still beats an empty frame), while **speaking** (audio)
    /// and **movement** push a source to the top — that is what makes it the
    /// one worth cutting to. The terms combine by `max`, not sum, so a single
    /// strong cue (a loud speaker) reads as high activity without needing all
    /// three to line up.
    public var activity: Float {
        let audio = clamp01(audioLevel ?? 0)
        let motion = clamp01(motionEnergy)
        let presence: Float = facePresent ? (0.20 + 0.30 * clamp01(faceConfidence)) : 0
        // Combine by max so any single strong cue reads as high activity. Motion
        // is a first-class cue: a pure-motion source (no face, no audio) still
        // scores via the motion term. A truly-idle source — no face, no audio,
        // no motion — falls out to 0 naturally (max of three zeros).
        return max(presence, audio, 0.7 * motion)
    }

    private func clamp01(_ v: Float) -> Float { min(1, max(0, v)) }
}

extension CGRect {
    /// Normalized area (unitless when the rect is in 0…1 space).
    var normalizedArea: CGFloat { max(0, width) * max(0, height) }
}
