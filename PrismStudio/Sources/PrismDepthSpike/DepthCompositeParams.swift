import Foundation

/// Declared policy for the depth-aware composite pass
/// (`docs/UNREAL_AR_3D_CHARACTER_DESIGN.md`, "The depth-aware Metal pass").
///
/// Occlusion decision at each character pixel, from the axial depths:
///
///     delta      = sceneZ − charZ                    (meters)
///     visibility = 0                        if delta − epsilon ≤ −feather
///                = 1                        if delta − epsilon ≥ +feather
///                = ramp((delta − epsilon)/(2·feather) + 0.5)  in the band
///
/// So the character is fully visible when it is `feather` in front of the scene,
/// fully occluded when `feather` behind, and linearly feathered only inside the
/// **declared feather band** — pixel-exact (hard 0/1) everywhere outside it.
///
/// Validity / fallback (design order):
///  1. character coverage `alpha ≤ 0`            → contributes nothing (vis 0)
///  2. character depth invalid (NaN)             → `charInvalidVisibility`
///     (conservative default 0 = hide)
///  3. scene depth invalid (NaN)                 → `sceneInvalidFallback`
///     (default 1 = draw the character flat, i.e. "in front")
///  4. otherwise                                 → the feather ramp above
public struct DepthCompositeParams: Sendable, Equatable {
    public enum Fallback: Int32, Sendable { case hide = 0, show = 1 }

    /// Half-width of the feather band, in meters. `0` = hard step (pixel-exact
    /// everywhere; the design's "exact hard decision" gate).
    public var featherMeters: Float
    /// Decision bias, in meters (design's depth-dependent epsilon, here scalar).
    public var epsilonMeters: Float
    /// What to do when the SCENE depth pixel is invalid.
    public var sceneInvalidFallback: Fallback
    /// What to do when the CHARACTER depth pixel is invalid (but covered).
    public var charInvalidVisibility: Fallback

    public init(featherMeters: Float = 0,
                epsilonMeters: Float = 0,
                sceneInvalidFallback: Fallback = .show,
                charInvalidVisibility: Fallback = .hide) {
        self.featherMeters = featherMeters
        self.epsilonMeters = epsilonMeters
        self.sceneInvalidFallback = sceneInvalidFallback
        self.charInvalidVisibility = charInvalidVisibility
    }

    /// Independent Double oracle for the visibility decision — used by the tests
    /// (they must NOT call the kernel's own code). Mirrors the MSL exactly.
    /// `charZ`/`sceneZ` are `nil` for invalid (NaN) samples.
    public func visibility(charAlpha: Double, charZ: Double?, sceneZ: Double?) -> Double {
        if charAlpha <= 0 { return 0 }
        guard let cz = charZ else { return Double(charInvalidVisibility.rawValue) }
        guard let sz = sceneZ else { return Double(sceneInvalidFallback.rawValue) }
        let delta = sz - cz
        let f = Double(featherMeters)
        let eps = Double(epsilonMeters)
        if f <= 0 { return (delta - eps > 0) ? 1 : 0 }
        let t = (delta - eps) / (2 * f) + 0.5
        return min(max(t, 0), 1)
    }
}
