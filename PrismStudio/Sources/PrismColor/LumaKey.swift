import Foundation

/// Configuration for the Metal luma keyer (`LumaKeyProcessor`) — the
/// luminance-based sibling of `ChromaKey` in DESIGN.md §2.3's
/// "Chroma/luma key" line, run as a standalone GPU pass.
///
/// Where `ChromaKey` mattes on distance in the chroma (Cb,Cr) plane (colour),
/// a luma key mattes on **brightness**: every pixel whose BT.709 luma falls
/// inside the band `[lowLuma, highLuma]` is treated as background and keyed to
/// α = 0; pixels outside the band are kept (α = 1). This is the tool for
/// keying a white/black backdrop, a projected light, a hard-light silhouette,
/// or pulling a matte from a printed alpha/fill pass — cases where the backdrop
/// is separated by tone, not hue.
///
/// Luma is measured on gamma-encoded values (matching the grade/stats kernels),
/// so `lowLuma`/`highLuma` correspond directly to an 8-bit histogram position
/// (0.5 ≈ code 128). The band edges are feathered by `smoothness` with a
/// `smoothstep`, giving a soft matte edge and anti-aliased silhouettes.
public struct LumaKey: Equatable, Sendable {
    /// Lower luma bound of the keyed (background) band, 0…1. Pixels darker than
    /// this — minus the feather — are kept as foreground.
    public var lowLuma: Double
    /// Upper luma bound of the keyed (background) band, 0…1. Pixels brighter
    /// than this — plus the feather — are kept as foreground.
    public var highLuma: Double
    /// Feather width applied to *both* band edges over which α ramps between 0
    /// and 1. Larger = softer matte edge. Typical 0.02…0.15.
    public var smoothness: Double
    /// Invert the matte: keep the band and key everything *outside* it. Lets one
    /// config key a dark subject on a bright field vs. a bright subject on a
    /// dark field without recomputing bounds.
    public var invert: Bool

    public init(lowLuma: Double = 0.75,
                highLuma: Double = 1.01,
                smoothness: Double = 0.08,
                invert: Bool = false) {
        // Normalize ordering so a crossed band (low > high) can't describe an
        // empty keep-region that keys the whole source away (re-verify #10
        // engine defense-in-depth; presets intentionally use ±0.01 open ends, so
        // we swap rather than clamp to [0,1]).
        self.lowLuma = min(lowLuma, highLuma)
        self.highLuma = max(lowLuma, highLuma)
        self.smoothness = smoothness
        self.invert = invert
    }

    /// Convenience: key everything **at or above** `threshold` luma (a bright
    /// backdrop). Equivalent to a band `[threshold, ∞)`.
    public static func brighterThan(_ threshold: Double, smoothness: Double = 0.08) -> LumaKey {
        LumaKey(lowLuma: threshold, highLuma: 1.01, smoothness: smoothness)
    }

    /// Convenience: key everything **at or below** `threshold` luma (a dark
    /// backdrop). Equivalent to a band `(−∞, threshold]`.
    public static func darkerThan(_ threshold: Double, smoothness: Double = 0.08) -> LumaKey {
        LumaKey(lowLuma: -0.01, highLuma: threshold, smoothness: smoothness)
    }

    /// Standard bright-backdrop preset (keys the top ~25% of the luma range).
    public static let brightBackground = LumaKey.brighterThan(0.75)
    /// Standard dark-backdrop preset (keys the bottom ~20% of the luma range).
    public static let darkBackground = LumaKey.darkerThan(0.20)
}
