import Foundation

/// A timing function mapping normalized progress `t ∈ [0, 1]` to eased
/// progress. All curves satisfy `apply(0) == 0` and `apply(1) == 1`
/// (springs by clamped construction, see `spring`).
///
/// Pure math — no Core Animation, no rendering (DESIGN.md §3.7).
public enum Easing: Codable, Equatable, Sendable {
    case linear
    case quadIn
    case quadOut
    case quadInOut
    case cubicIn
    case cubicOut
    case cubicInOut
    /// CSS-style cubic bezier timing: control points (p1x, p1y), (p2x, p2y)
    /// with endpoints fixed at (0,0) and (1,1). `p1x`/`p2x` are clamped to
    /// [0, 1] so x(t) is invertible (same rule as CSS). Solved for t via
    /// Newton–Raphson with a bisection fallback (WebKit `UnitBezier` method).
    case cubicBezier(p1x: Double, p1y: Double, p2x: Double, p2y: Double)
    /// Duration-normalized damped spring toward 1.0 (unit mass).
    ///
    /// Physical model: `x'' + damping·x' + stiffness·(x − 1) = 0`,
    /// `x(0) = 0`, `x'(0) = initialVelocity` (units of 1/normalized-duration).
    /// The closed-form solution (under-, critically-, or over-damped) is
    /// evaluated over the settle interval where the envelope decays below
    /// 0.1 %, remapped so `t = 1` is the settle point. `apply(t)` for
    /// `t ≥ 1` returns exactly 1 (residual ≤ 0.001 is truncated).
    case spring(damping: Double, stiffness: Double, initialVelocity: Double)

    /// CSS `ease` — cubicBezier(0.25, 0.1, 0.25, 1).
    public static let ease = Easing.cubicBezier(p1x: 0.25, p1y: 0.1, p2x: 0.25, p2y: 1.0)
    /// A gentle default spring (ζ = 0.5, mild overshoot).
    public static let defaultSpring = Easing.spring(damping: 10, stiffness: 100, initialVelocity: 0)

    /// Eased progress for `t`. Input outside [0, 1] is clamped.
    public func apply(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch self {
        case .linear:
            return t
        case .quadIn:
            return t * t
        case .quadOut:
            return t * (2 - t)
        case .quadInOut:
            return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        case .cubicIn:
            return t * t * t
        case .cubicOut:
            let u = 1 - t
            return 1 - u * u * u
        case .cubicInOut:
            return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case let .cubicBezier(p1x, p1y, p2x, p2y):
            return Easing.solveBezier(p1x: p1x, p1y: p1y, p2x: p2x, p2y: p2y, x: t)
        case let .spring(damping, stiffness, initialVelocity):
            return Easing.solveSpring(damping: damping, stiffness: stiffness,
                                      initialVelocity: initialVelocity, t: t)
        }
    }

    // MARK: - Cubic bezier (CSS timing-function semantics)

    private static func solveBezier(p1x: Double, p1y: Double, p2x: Double, p2y: Double, x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        // Clamp control-point x to [0,1] so sampleX is monotonic/invertible.
        let p1x = min(max(p1x, 0), 1), p2x = min(max(p2x, 0), 1)

        // Polynomial coefficients (Horner form), endpoints (0,0)/(1,1).
        let cx = 3 * p1x
        let bx = 3 * (p2x - p1x) - cx
        let ax = 1 - cx - bx
        let cy = 3 * p1y
        let by = 3 * (p2y - p1y) - cy
        let ay = 1 - cy - by

        func sampleX(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
        func sampleY(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
        func sampleDX(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }

        // Newton–Raphson.
        var t = x
        for _ in 0..<8 {
            let err = sampleX(t) - x
            if abs(err) < 1e-7 { return sampleY(t) }
            let d = sampleDX(t)
            if abs(d) < 1e-6 { break }
            t -= err / d
        }
        // Bisection fallback (sampleX is monotonic on [0,1]).
        var lo = 0.0, hi = 1.0
        t = x
        while hi - lo > 1e-7 {
            t = (lo + hi) / 2
            if sampleX(t) < x { lo = t } else { hi = t }
        }
        return sampleY(t)
    }

    // MARK: - Spring (closed form, duration-normalized)

    /// Envelope threshold that defines "settled".
    private static let springEpsilon = 1e-3

    private static func solveSpring(damping: Double, stiffness: Double,
                                    initialVelocity: Double, t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        // Degenerate parameters: fall back to linear rather than trap/NaN.
        guard stiffness > 0, damping > 0 else { return t }

        let w0 = stiffness.squareRoot()          // natural frequency
        let zeta = damping / (2 * w0)            // damping ratio
        let v0 = initialVelocity
        let eps = springEpsilon

        // Solve for y = x − 1 (so y(0) = −1, y'(0) = v0, y → 0), with a
        // settle duration derived from the *amplitude-aware* envelope so
        // |y(settle)| ≤ ε in every damping regime — a plain e^(−ζω₀s)
        // bound under-shoots for critical/near-critical damping, where a
        // polynomial factor slows the decay.
        let settleDuration: Double
        let solution: (Double) -> Double
        if zeta < 1 {
            let wd = w0 * (1 - zeta * zeta).squareRoot()
            let a = -1.0
            let b = (v0 - zeta * w0) / wd
            let amplitude = max((a * a + b * b).squareRoot(), 1)
            settleDuration = log(amplitude / eps) / (zeta * w0)
            solution = { s in exp(-zeta * w0 * s) * (a * cos(wd * s) + b * sin(wd * s)) }
        } else if zeta == 1 {
            let a = -1.0
            let b = v0 - w0
            // Solve (|a| + |b|·s)·e^(−ω₀s) = ε by fixed-point iteration
            // (converges fast: s appears only inside a log).
            var s = log(1 / eps) / w0
            for _ in 0..<8 { s = log((abs(a) + abs(b) * s) / eps) / w0 }
            settleDuration = s
            solution = { s in (a + b * s) * exp(-w0 * s) }
        } else {
            let disc = (zeta * zeta - 1).squareRoot()
            let r1 = -w0 * (zeta - disc)   // slow root
            let r2 = -w0 * (zeta + disc)   // fast root
            let c1 = (v0 + r2) / (r1 - r2)   // from c1+c2 = −1, c1·r1+c2·r2 = v0
            let c2 = -1 - c1
            let amplitude = max(abs(c1) + abs(c2), 1)
            settleDuration = log(amplitude / eps) / abs(r1)
            solution = { s in c1 * exp(r1 * s) + c2 * exp(r2 * s) }
        }
        return 1 + solution(t * settleDuration)
    }
}
