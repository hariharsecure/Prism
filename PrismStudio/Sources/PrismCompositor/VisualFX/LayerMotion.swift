import CoreGraphics
import Foundation

/// A parametric or keyframed path a layer's transform follows over time
/// (DESIGN.md §4). Positions are normalized offsets from the layer's rest
/// position — `(tx, ty)` in the same convention as `LayerTransform` (fraction of
/// canvas, `ty` positive = screen-down). Angles are radians. All are pure
/// functions of the normalized parameter `u` — deterministic, no `Date`/random.
public enum MotionPath: Sendable, Equatable {
    /// Straight glide from `from` to `to` (one-shot; eased by the caller's easing).
    case line(from: CGPoint, to: CGPoint)
    /// Sweep along a circle arc from `startAngle` to `endAngle` (one-shot).
    case arc(center: CGPoint, radius: Double, startAngle: Double, endAngle: Double)
    /// A full circular orbit about `center` (seamless loop: `u=0` ≡ `u=1`).
    case orbit(center: CGPoint, radius: Double)
    /// An in-place vertical hop of `height` (seamless loop; a parabola up & back).
    case bounce(height: Double)
    /// A gentle sine bob of `amplitude` with a tiny sway (seamless loop).
    case float(amplitude: Double)
    /// A fully custom keyframed track (ties `LayerMotion` to `KeyframeAnimation`).
    case keyframed(AnimTrack)
}

/// Drives ANY layer's `LayerTransform` along a `MotionPath` (DESIGN.md §4). The
/// app wires this to a per-layer motion picker (None / Glide / Orbit / Bounce /
/// Float); here it is the pure, testable evaluator. Looped paths (`orbit`,
/// `bounce`, `float`) satisfy `transform(0) == transform(1)` so a wrapped phase
/// never jumps; one-shot paths (`line`, `arc`) are meant to be fed a clamped
/// progress `0…1`.
public struct LayerMotion: Sendable, Equatable {
    public var path: MotionPath
    /// Easing applied to the parameter for the one-shot paths (`line`/`arc`).
    /// Looped paths use the raw phase so the loop stays seamless.
    public var easing: Easing
    /// Extra uniform scale multiplied onto the resolved transform.
    public var scale: Double
    /// Constant opacity for the resolved transform.
    public var opacity: Double

    public init(path: MotionPath, easing: Easing = .easeInOut, scale: Double = 1, opacity: Double = 1) {
        self.path = path
        self.easing = easing
        self.scale = scale
        self.opacity = opacity
    }

    /// Whether this path is meant to loop seamlessly (vs. a one-shot glide).
    public var isLooping: Bool {
        switch path {
        case .orbit, .bounce, .float: return true
        case .line, .arc: return false
        case .keyframed: return false
        }
    }

    /// Resolve the transform at normalized parameter `u`. For looped paths pass a
    /// wrapping phase; for one-shot paths pass a clamped progress `0…1`.
    public func transform(at u: Double) -> LayerTransform {
        var t = LayerTransform(scale: scale, opacity: opacity)
        switch path {
        case .line(let from, let to):
            let e = easing.apply(min(max(u, 0), 1))
            t.tx = lerp(Double(from.x), Double(to.x), e)
            t.ty = lerp(Double(from.y), Double(to.y), e)

        case .arc(let c, let r, let a0, let a1):
            let e = easing.apply(min(max(u, 0), 1))
            let ang = lerp(a0, a1, e)
            t.tx = Double(c.x) + r * cos(ang)
            t.ty = Double(c.y) + r * sin(ang)

        case .orbit(let c, let r):
            let p = u - floor(u)                 // wrap into 0…1
            let ang = 2 * .pi * p
            t.tx = Double(c.x) + r * cos(ang)
            t.ty = Double(c.y) + r * sin(ang)

        case .bounce(let height):
            let p = u - floor(u)
            // Parabola: 0 at p=0 and p=1, peak at p=0.5 → seamless in-place hop.
            // Up is screen-up = negative ty.
            t.ty = -height * 4 * p * (1 - p)

        case .float(let amp):
            let p = u - floor(u)
            let w = 2 * .pi * p
            t.ty = amp * sin(w)
            t.rotation = amp * 0.5 * sin(w)      // subtle coupled sway
            t.tx = amp * 0.25 * sin(2 * w)       // gentle horizontal drift (period-1)

        case .keyframed(let track):
            var kt = track.sample(atFraction: u)
            kt.scale *= scale                     // fold the extra scale in
            kt.opacity *= opacity
            return kt
        }
        return t
    }
}
