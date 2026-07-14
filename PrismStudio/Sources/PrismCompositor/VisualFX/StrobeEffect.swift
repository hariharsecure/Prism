import CoreGraphics
import CoreVideo
import Foundation
import PrismCore

/// A full-frame flash / strobe: blends the source frame toward a flash `color`
/// (white by default), peaking on the beat downbeat (`phase 0`) and decaying back
/// to the untouched source by the next beat.
///
/// The envelope reuses the `BeatPulse` idea — a normalized exponential decay
/// `env(0)=1`, `env(1)=0`, strictly decreasing — but drives a **color flash**
/// (an alpha-`env` composite of `color` over the source) instead of a scale bump.
/// Pure and deterministic in its envelope: the flash amount is a function of
/// `phase` + `intensity` only (no `Date`, no RNG), and is clamped to `0…1` so the
/// result never over-flashes. Beat-drivable later by the app via `phase`, exactly
/// like `BeatPulse`.
///
/// Rendering blends in the premultiplied-first BGRA canvas and PRESERVES the
/// source's alpha (Class C): the flash is applied `.sourceAtop`, so the output
/// alpha equals the source's and the flash colour is scaled by it. At `a = 0`
/// the output equals the source; at `a = 1` an opaque texel becomes the pure
/// flash colour while a transparent/keyed texel stays transparent (it never
/// flashes an opaque region over the layers beneath). The output is an
/// IOSurface-backed BGRA buffer identical in layout to every other frame.
public final class StrobeEffect {
    private let canvas: FXCanvas
    public let width: Int
    public let height: Int

    /// Exponential steepness of the decay (higher = snappier flash/decay).
    public var decay: Double
    /// Upper clamp on `intensity` (peak flash alpha at the downbeat). Kept ≤ 1 so
    /// a full flash never exceeds the pure `color`.
    public var maxIntensity: Double

    public init(width: Int, height: Int, decay: Double = 6, maxIntensity: Double = 1) throws {
        self.canvas = try FXCanvas(width: width, height: height)
        self.width = width
        self.height = height
        self.decay = max(decay, 0.0001)
        self.maxIntensity = min(max(maxIntensity, 0), 1)
    }

    /// Normalized exponential decay: `env(0)=1`, `env(1)=0`, strictly decreasing.
    /// `phase` is wrapped into `0…1` (so `phase 1.0` is the next downbeat, `= 1`).
    func envelope(_ phase: Double) -> Double {
        let p = min(max(phase - floor(phase), 0), 1)
        let k = decay
        let e0 = exp(-k)
        return (exp(-k * p) - e0) / (1 - e0)
    }

    /// The flash alpha (`0…1`) at a beat `phase` (`0` = downbeat) and `intensity`.
    /// Pure — the app can call this to drive a GPU flash without rendering.
    public func flashAmount(phase: Double, intensity: Double) -> Double {
        let i = min(max(intensity, 0), maxIntensity)
        return min(max(i * envelope(phase), 0), 1)
    }

    /// Flash `source` toward `color` by the phase-driven envelope. `phase 0` gives
    /// the brightest flash toward `color`; by the end of the beat the output
    /// returns to `source`.
    ///
    /// - Parameters:
    ///   - source: the program frame (IOSurface-backed BGRA).
    ///   - phase: beat phase `0→1` (`0` = downbeat).
    ///   - intensity: peak flash strength (clamped `0…maxIntensity`).
    ///   - color: flash target color (white by default). Its own alpha scales the
    ///     flash further (a translucent color flashes less).
    public func apply(to source: CVPixelBuffer, phase: Double, intensity: Double,
                      color: RGBA = .white) throws -> CVPixelBuffer {
        let a = flashAmount(phase: phase, intensity: intensity) * min(max(color.a, 0), 1)
        // sol #5 f4 / #6 f2: convert the sRGB flash colour INTO the source's coded
        // space (sRGB EOTF → source primaries/transfer) before mixing, exactly as the
        // GPU `SourceEffectGPU.strobe` does — so this CPU fallback stays pixel-parity
        // with the GPU. A genuine sRGB source is unchanged; a Rec.709 source gets the
        // sRGB→709 re-encode (mid-tones bend), an HDR source the full conversion.
        let flash = YCbCrTags.srgbColor(SIMD3(Float(color.r), Float(color.g), Float(color.b)),
                                        inSpaceOf: source)
        let img = try FXCanvas.cgImage(from: source)
        return try canvas.render { ctx in
            ctx.draw(img, in: canvas.rect)
            if a > 0.0001 {
                // Class C: PRESERVE source alpha. `.sourceAtop` keeps the drawn
                // source's alpha (Da' = Da) and scales the flash by it
                // (Dc' = Sc·Da + Dc·(1−Sa)), so a transparent/keyed region stays
                // transparent instead of flashing an opaque colour over the layers
                // beneath. An opaque source (Da = 1) is byte-identical to the
                // prior straight source-over — the common case is unchanged.
                ctx.setBlendMode(.sourceAtop)
                ctx.setFillColor(RGBA(r: Double(flash.x), g: Double(flash.y), b: Double(flash.z), a: a).cg)
                ctx.fill(canvas.rect)
            }
        }
    }
}
