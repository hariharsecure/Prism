import CoreGraphics
import Foundation
import PrismCompositor
import PrismCore

/// A simple RGBA color for `dipToColor` (0…1 components). Placeholder until
/// the compositor's mix stage defines its own color plumbing.
public struct TransitionColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = TransitionColor(red: 0, green: 0, blue: 0)
}

/// Direction of *motion* for slide transitions: `.left` means content moves
/// leftward — the outgoing scene exits via the left edge and the incoming
/// scene enters from the right.
public enum SlideDirection: String, Codable, Equatable, Sendable {
    case left, right, up, down

    /// Edge the outgoing scene exits through.
    var exitEdge: CanvasEdge {
        switch self {
        case .left: return .left
        case .right: return .right
        case .up: return .top
        case .down: return .bottom
        }
    }

    /// Edge the incoming scene enters from (opposite the motion).
    var enterEdge: CanvasEdge {
        switch self {
        case .left: return .right
        case .right: return .left
        case .up: return .bottom
        case .down: return .top
        }
    }
}

/// A description of an animated switch between two scenes. Pure data + math;
/// the render loop owns the wall-clock anchor and the compositor's future
/// mix stage does the pixels.
///
/// ## The compositor seam (DESIGN.md §3.7)
/// During a transition the render loop evaluates *both* scenes per frame:
///
/// 1. `progress(at: houseSeconds - transitionStart)` → one eased scalar
///    0…1. The mix stage consumes this directly: `crossfade` blends
///    program = lerp(outgoing, incoming, progress); `dipToColor` maps
///    progress 0→0.5→1 to outgoing→color→incoming.
/// 2. For kinds that *move layers* (`slide`), `outgoingAnimations(for:)` /
///    `incomingAnimations(for:)` produce per-layer `LayerAnimation`s; wrap
///    each scene in an `AnimatedScene` (same start time, `.hold`) and feed
///    the two evaluated plain `Scene`s to the mix stage, which composites
///    outgoing-over-incoming with no extra blend (the motion itself reveals
///    the incoming scene).
public struct SceneTransition: Codable, Equatable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        /// Blend outgoing → incoming by `progress`.
        case crossfade
        /// Push: outgoing slides out, incoming slides in, in one motion.
        case slide(direction: SlideDirection)
        /// Fade outgoing → solid color → incoming. Placeholder: the mix
        /// stage does the color leg; no layer animations are generated.
        case dipToColor(TransitionColor)
    }

    /// Total transition length in seconds.
    public var duration: Double
    /// Timing curve shaping `progress` (and the generated layer moves).
    public var curve: Easing
    public var kind: Kind

    public init(kind: Kind, duration: Double, curve: Easing = .ease) {
        self.kind = kind
        self.duration = max(duration, 0)
        self.curve = curve
    }

    /// Eased progress for `elapsed` seconds since the transition started.
    /// Clamped: ≤ 0 → 0, ≥ `duration` → 1 (also 1 for zero duration — a
    /// degenerate transition is an instant cut).
    public func progress(at elapsed: Double) -> Double {
        guard duration > 0 else { return elapsed >= 0 ? 1 : 0 }
        return curve.apply(elapsed / duration)
    }

    /// Layer animations for the scene being switched *away from*.
    /// Empty for kinds the mix stage handles purely by `progress`.
    public func outgoingAnimations(for scene: Scene) -> [SourceID: LayerAnimation] {
        switch kind {
        case .crossfade, .dipToColor:
            return [:]
        case .slide(let direction):
            return animations(for: scene) {
                LayerExit.slideOut(to: direction.exitEdge)
                    .animation(for: $0, duration: duration, easing: curve)
            }
        }
    }

    /// Layer animations for the scene being switched *to*.
    public func incomingAnimations(for scene: Scene) -> [SourceID: LayerAnimation] {
        switch kind {
        case .crossfade, .dipToColor:
            return [:]
        case .slide(let direction):
            return animations(for: scene) {
                LayerEntrance.slideIn(from: direction.enterEdge)
                    .animation(for: $0, duration: duration, easing: curve)
            }
        }
    }

    private func animations(for scene: Scene,
                            _ make: (Layer) -> LayerAnimation) -> [SourceID: LayerAnimation] {
        var result: [SourceID: LayerAnimation] = [:]
        for layer in scene.layers where !layer.isHidden {
            result[layer.sourceID] = make(layer)
        }
        return result
    }
}
