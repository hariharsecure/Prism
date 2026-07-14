import Foundation

/// Easing curves shared by the transition library (§1) and the anime keyframe
/// evaluator (§2). Pure functions of normalized time `t ∈ 0…1`; each maps the
/// endpoints to themselves (`f(0)=0`, `f(1)=1`) except `backOut`/`bounceOut`
/// which overshoot in the interior (that overshoot *is* the anime feel).
public enum Easing: Sendable, Equatable {
    case linear
    case easeIn          // quadratic ease-in
    case easeOut         // quadratic ease-out
    case easeInOut       // cubic in-out (smoothstep-ish)
    /// Overshoots past 1 near the end then settles — the classic "back" curve.
    /// `overshoot` is the tension (1.70158 ≈ ~10% overshoot).
    case backOut(overshoot: Double)
    /// Decaying bounce landing on 1 (three-stage bounce).
    case bounceOut

    /// Evaluate the curve. `t` is clamped to 0…1 before shaping; the *result*
    /// may exceed 0…1 for `backOut`/`bounceOut` (intended overshoot).
    public func apply(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        switch self {
        case .linear:
            return x
        case .easeIn:
            return x * x
        case .easeOut:
            return 1 - (1 - x) * (1 - x)
        case .easeInOut:
            return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
        case .backOut(let s):
            let c1 = s
            let c3 = c1 + 1
            let p = x - 1
            return 1 + c3 * p * p * p + c1 * p * p
        case .bounceOut:
            let n1 = 7.5625, d1 = 2.75
            var u = x
            if u < 1 / d1 { return n1 * u * u }
            else if u < 2 / d1 { u -= 1.5 / d1; return n1 * u * u + 0.75 }
            else if u < 2.5 / d1 { u -= 2.25 / d1; return n1 * u * u + 0.9375 }
            else { u -= 2.625 / d1; return n1 * u * u + 0.984375 }
        }
    }

    /// A sensible default overshoot for anime entrances.
    public static let backOutDefault = Easing.backOut(overshoot: 1.70158)
}

/// Linear interpolation helper.
@inline(__always) func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
