import Foundation
import simd

/// One red/green/blue value triple for the DaVinci-style wheels.
public struct GradeTriple: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Same value on all three channels.
    public init(_ value: Double) { self.init(red: value, green: value, blue: value) }

    public static let zero = GradeTriple(0)
    public static let one = GradeTriple(1)
}

/// A DaVinci-style per-source color grade. Plain value type, `Codable`,
/// **identity by default** — `ColorGrade()` passes pixels through unchanged.
///
/// Working spaces (v0 contract, stated honestly — enforced by `ColorProcessor`):
/// - `exposure` (stops) and `temperature`/`tint` apply in **linear light**,
///   obtained from gamma-encoded BT.709 by a pure 2.2 power — an
///   approximation of the BT.709/sRGB display chain, chosen for v0 because
///   it is invertible and cheap; the piecewise curve is a later refinement.
/// - `lift`/`gamma`/`gain`, `contrast` (pivot 0.5) and `saturation` apply on
///   **gamma-encoded** values, matching grading-tool convention.
///
/// Processing order (matches the fused GPU kernel):
/// `linearize → exposure×WB → re-encode → lift/gamma/gain → contrast → saturation → LUT`.
public struct ColorGrade: Codable, Equatable, Sendable {
    /// Exposure in stops: ×2^stops in linear light. 0 = identity.
    public var exposure: Double
    /// Contrast about pivot 0.5 in gamma space. 1 = identity.
    public var contrast: Double
    /// Saturation against BT.709 luma. 1 = identity, 0 = grayscale.
    public var saturation: Double
    /// White-balance temperature, nominally −1…1. Positive = warmer
    /// (red gain up, blue gain down). Applied as luma-preserving linear gains.
    public var temperature: Double
    /// White-balance tint, nominally −1…1. Positive = magenta, negative =
    /// green (Lightroom sign convention). Luma-preserving linear gains.
    public var tint: Double
    /// Shadows wheel, gamma space: `out = gain · (in + lift·(1 − in))`.
    /// Identity = 0.
    public var lift: GradeTriple
    /// Midtones wheel: `out = out^(1/gamma)`; values > 1 brighten mids.
    /// Identity = 1.
    public var gamma: GradeTriple
    /// Highlights wheel: per-channel multiplier. Identity = 1.
    public var gain: GradeTriple

    public init(exposure: Double = 0,
                contrast: Double = 1,
                saturation: Double = 1,
                temperature: Double = 0,
                tint: Double = 0,
                lift: GradeTriple = .zero,
                gamma: GradeTriple = .one,
                gain: GradeTriple = .one) {
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.temperature = temperature
        self.tint = tint
        self.lift = lift
        self.gamma = gamma
        self.gain = gain
    }

    /// The identity grade (what `ColorGrade()` gives you).
    public static let identity = ColorGrade()

    /// True when every parameter is at its identity value.
    public var isIdentity: Bool { self == .identity }
}

// MARK: - White-balance model (shared by the GPU kernel and AutoColor)

/// The temperature/tint → linear-gain model. One definition, used both to
/// *apply* WB (ColorProcessor) and to *invert* measured channel gains back
/// into temperature/tint (AutoColor) — so suggestions round-trip exactly.
enum WhiteBalanceModel {
    /// temp = 1 → red gain ×2, blue gain ÷2 before luma normalization —
    /// roughly a full tungsten↔daylight swing at full deflection.
    static let temperatureStrength: Double = 1.0
    /// tint = 1 (magenta) → green gain ÷2 before luma normalization.
    static let tintStrength: Double = 1.0

    /// BT.709 luminance weights (correct on linear RGB).
    static let lumaWeights = SIMD3<Double>(0.2126, 0.7152, 0.0722)

    /// Linear RGB gains for a temperature/tint pair, normalized so that
    /// BT.709 luminance is preserved (WB never changes exposure).
    static func linearGains(temperature: Double, tint: Double) -> SIMD3<Double> {
        var g = SIMD3<Double>(exp2(temperatureStrength * temperature),
                              exp2(-tintStrength * tint),
                              exp2(-temperatureStrength * temperature))
        let luma = simd_dot(g, lumaWeights)
        if luma > 1e-6 { g /= luma }
        return g
    }

    /// Inverse of `linearGains`: recover (temperature, tint) from a desired
    /// linear gain triple. Any uniform scale on the gains cancels out.
    static func temperatureTint(forGains g: SIMD3<Double>) -> (temperature: Double, tint: Double) {
        let eps = 1e-6
        let lr = log2(max(g.x, eps))
        let lg = log2(max(g.y, eps))
        let lb = log2(max(g.z, eps))
        let temperature = (lr - lb) / (2 * temperatureStrength)
        let tint = -(lg - 0.5 * (lr + lb)) / tintStrength
        return (temperature, tint)
    }
}
