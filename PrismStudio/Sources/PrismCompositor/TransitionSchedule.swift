import CoreMedia
import Foundation

/// A module-neutral description of an animated scene switch, consumed by
/// `RenderLoop.switchScene(to:transition:completion:)`.
///
/// ## The dependency inversion (DESIGN.md §3.7)
/// The animation system (PrismAnimation) depends on this module, not the
/// other way around — the compositor never learns about keyframes, easing, or
/// `SceneTransition`. This struct is the seam: PrismAnimation (or the app)
/// wraps its typed transition into plain closures:
///
/// ```swift
/// // Crossfade — one eased scalar drives the mix stage:
/// let t = SceneTransition(kind: .crossfade, duration: 0.5)
/// loop.switchScene(to: next, transition: TransitionSchedule(
///     duration: t.duration,
///     blend: .crossfade,
///     progress: { t.progress(at: $0) }))
///
/// // Slide — per-tick evaluated AnimatedScenes move the layers, and the
/// // compositor stacks outgoing over incoming with no extra blend. The scene
/// // closures receive `elapsed` (seconds since the transition started) — the
/// // RenderLoop is the ONE clock, so nothing captures its own start time:
/// loop.switchScene(to: next, transition: TransitionSchedule(
///     duration: t.duration,
///     blend: .overlay,
///     progress: { t.progress(at: $0) },
///     outgoingScene: { elapsed in out.evaluate(at: elapsed) },
///     incomingScene: { elapsed in inc.evaluate(at: elapsed) }))
/// ```
/// A GPU pixel/tile transition effect run by the compositor's FX pass — the
/// live-GPU home of the `iris` / `zoomBlur` / `glitch` / `animeFlash` /
/// `speedline` pixel-effects and the `blockDissolve` / `gridWipe` /
/// `checkerboard` / `tileReveal` / `tileFlicker` tile family. Carries exactly
/// the parameters the `prism_fx_fragment` shader needs; the shader math MATCHES
/// the CPU `TransitionRenderer` / `TileSchedule` ground truth.
///
/// `kind.rawValue` is the shader's `kind` selector (see `FXUniforms`).
public struct CompositorEffect: Equatable, Sendable {
    public enum Kind: UInt32, Equatable, Sendable {
        case iris = 0, zoomBlur = 1, glitch = 2, animeFlash = 3, speedline = 4
        case blockDissolve = 5, gridWipe = 6, checkerboard = 7, tileReveal = 8, tileFlicker = 9
    }
    public var kind: Kind
    /// Tile grid (already `TileSchedule.clampGrid`-clamped); 1×1 for pixel kinds.
    public var rows: UInt32
    public var cols: UInt32
    /// Deterministic seed for `blockDissolve` / `tileFlicker` (ignored otherwise).
    public var seed: UInt64
    /// Tile hole-edge feather 0…1 (tile kinds).
    public var softness: Float
    /// `gridWipe` sweep direction: 0 left, 1 right, 2 up, 3 down.
    public var direction: UInt32
    /// `tileFlicker` is a CONTINUOUS blink — it must NOT short-circuit its 0/1
    /// endpoints to A/B (they are the same loop point). One-shot kinds do.
    public var continuous: Bool

    public init(kind: Kind, rows: UInt32 = 1, cols: UInt32 = 1, seed: UInt64 = 0,
                softness: Float = 0, direction: UInt32 = 0, continuous: Bool = false) {
        self.kind = kind
        self.rows = rows
        self.cols = cols
        self.seed = seed
        self.softness = softness
        self.direction = direction
        self.continuous = continuous
    }
}

public struct TransitionSchedule: Sendable {
    /// How the two scenes combine each tick.
    public enum Blend: Equatable, Sendable {
        /// True crossfade: `program = lerp(render(outgoing), render(incoming),
        /// progress)` via the compositor's intermediate-texture mix stage.
        case crossfade
        /// Outgoing composited *over* incoming in one pass, no blend — for
        /// motion transitions (slide/push) where the scene providers move the
        /// layers and the motion itself reveals the incoming scene.
        case overlay
        /// Per-pixel/tile GPU effect: render(outgoing)→A, render(incoming)→B,
        /// then the `prism_fx_fragment` shader blends them for `effect.kind` at
        /// the tick's progress. This is what makes the pixel/tile kinds run
        /// NATIVELY in the live compositor instead of degrading to a crossfade.
        case effect(CompositorEffect)
    }

    /// Total transition length in house-time seconds. `<= 0` is a hard cut.
    public var duration: Double
    public var blend: Blend
    /// Eased mix for `elapsed` seconds since the transition started
    /// (house time). The consumer supplies the curve — e.g.
    /// `SceneTransition.progress(at:)`. Results are clamped to 0…1.
    public var progress: @Sendable (_ elapsed: Double) -> Double
    /// Optional per-tick outgoing scene, as a function of `elapsed` seconds since
    /// the transition started (B4). The RenderLoop is the single transition
    /// clock and supplies this `elapsed` — the closure MUST NOT capture its own
    /// `HouseClock` start, or it desyncs from the loop. `nil` = the loop's
    /// current scene, frozen.
    public var outgoingScene: (@Sendable (_ elapsed: Double) -> Scene)?
    /// Optional per-tick incoming scene, as a function of `elapsed` seconds since
    /// the transition started. `nil` = the target scene, static.
    public var incomingScene: (@Sendable (_ elapsed: Double) -> Scene)?
    /// RAW (pre-easing) clamped progress for the `.effect` blend — the `glitch`
    /// channel-split amount and the `tileFlicker` loop phase ride the raw phase
    /// (matching `TransitionRenderer`, which eases the base but uses raw `t` for
    /// those). `nil` = use `progress` (fine for kinds that ignore raw).
    public var rawProgress: (@Sendable (_ elapsed: Double) -> Double)?

    public init(duration: Double,
                blend: Blend = .crossfade,
                progress: @escaping @Sendable (_ elapsed: Double) -> Double,
                outgoingScene: (@Sendable (_ elapsed: Double) -> Scene)? = nil,
                incomingScene: (@Sendable (_ elapsed: Double) -> Scene)? = nil,
                rawProgress: (@Sendable (_ elapsed: Double) -> Double)? = nil) {
        self.duration = duration
        self.blend = blend
        self.progress = progress
        self.outgoingScene = outgoingScene
        self.incomingScene = incomingScene
        self.rawProgress = rawProgress
    }

    /// A plain linear crossfade (no PrismAnimation required).
    public static func crossfade(duration: Double) -> TransitionSchedule {
        TransitionSchedule(duration: duration) { elapsed in
            duration > 0 ? min(max(elapsed / duration, 0), 1) : 1
        }
    }
}
