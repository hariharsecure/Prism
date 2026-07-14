import CoreGraphics
import CoreVideo
import Foundation

/// Which components of the beat pulse are applied to a layer.
public enum BeatPulseStyle: String, Sendable, CaseIterable {
    /// Scale bump only (the layer "booms" on the beat).
    case bump
    /// Decaying positional shake only (no scale change).
    case shake
    /// Both a scale bump and a decaying shake.
    case bumpShake

    var hasBump: Bool { self == .bump || self == .bumpShake }
    var hasShake: Bool { self == .shake || self == .bumpShake }
}

/// The per-frame transform envelope produced by `BeatPulse` for one beat phase.
/// `scale` is a uniform scale about the layer center (≥ 1 — the pulse only ever
/// grows, never shrinks); `dx`/`dy` are shake offsets as a fraction of the
/// canvas width/height (`dy` positive = screen-down), matching the sign
/// convention of `LayerTransform.tx`/`ty`.
public struct BeatPulseTransform: Sendable, Equatable {
    /// Uniform scale about the layer center (1 = rest).
    public var scale: Double
    /// Horizontal shake offset, fraction of canvas width.
    public var dx: Double
    /// Vertical shake offset, fraction of canvas height (positive = down).
    public var dy: Double

    public init(scale: Double = 1, dx: Double = 0, dy: Double = 0) {
        self.scale = scale; self.dx = dx; self.dy = dy
    }

    public static let identity = BeatPulseTransform()

    /// Shake displacement magnitude (fraction of canvas), for verification.
    public var shakeMagnitude: Double { (dx * dx + dy * dy).squareRoot() }

    /// Bridge to the shared `LayerTransform` so the beat pulse can be fed into
    /// the same per-layer transform path the anime keyframe evaluator drives.
    public var layerTransform: LayerTransform {
        LayerTransform(tx: dx, ty: dy, scale: scale)
    }
}

/// Beat-synced "boom": maps a beat phase (0→1, 0 = the downbeat) + an intensity
/// to a `BeatPulseTransform` — a scale bump that is maximal on the downbeat and
/// decays back to rest by the next beat, plus an optional decaying shake.
///
/// Pure and deterministic: the result is a function of `phase` + `intensity`
/// only (no `Date`, no `Math.random`). The shake direction is derived
/// deterministically from the phase, so the same inputs always give the same
/// offset. Reuses the module's easing/decay style (see `Easing`).
///
/// Envelope math (see `pulse(phase:intensity:style:)`):
///  - a normalized exponential decay `env(p)` with `env(0)=1`, `env(1)=0`,
///    strictly decreasing — snappy attack on the beat, tail off before the next;
///  - `scale = 1 + intensity·env(p)` (peak `1+intensity` at the downbeat);
///  - shake `= amplitude·intensity·env(p)·(cos θ, sin θ)` where `θ` rotates with
///    phase, so the shake *magnitude* equals the envelope (peaks on the beat,
///    decays) while its direction jitters back and forth deterministically.
public struct BeatPulse: Sendable {
    /// Exponential steepness of the decay (higher = snappier attack/decay).
    public var decay: Double
    /// Peak shake displacement as a fraction of the canvas, at full intensity.
    public var shakeAmplitude: Double
    /// Shake direction rotations across one beat (higher = faster jitter).
    public var shakeFrequency: Double
    /// Upper clamp on `intensity` (kept to a sane range so scale can't blow up).
    public var maxIntensity: Double

    public init(decay: Double = 5, shakeAmplitude: Double = 0.02,
                shakeFrequency: Double = 4, maxIntensity: Double = 2) {
        self.decay = max(decay, 0.0001)
        self.shakeAmplitude = max(shakeAmplitude, 0)
        self.shakeFrequency = shakeFrequency
        self.maxIntensity = max(maxIntensity, 0)
    }

    /// A sensible default pulse.
    public static let `default` = BeatPulse()

    /// Normalized exponential decay: `env(0)=1`, `env(1)=0`, strictly decreasing.
    func envelope(_ phase: Double) -> Double {
        let p = min(max(phase - floor(phase), 0), 1)   // wrap into 0…1
        let k = decay
        let e0 = exp(-k)                                 // value at p = 1
        return (exp(-k * p) - e0) / (1 - e0)
    }

    /// Evaluate the pulse for a beat `phase` (0→1, 0 = downbeat) and `intensity`.
    /// `intensity` is clamped to `0…maxIntensity`.
    public func pulse(phase: Double, intensity: Double, style: BeatPulseStyle = .bump) -> BeatPulseTransform {
        let i = min(max(intensity, 0), maxIntensity)
        let env = envelope(phase)

        let scale = style.hasBump ? 1 + i * env : 1

        var dx = 0.0, dy = 0.0
        if style.hasShake {
            let p = phase - floor(phase)
            let theta = 2 * .pi * shakeFrequency * p
            let amp = shakeAmplitude * i * env       // magnitude == amp (|cos,sin| = 1)
            dx = amp * cos(theta)
            dy = amp * sin(theta)
        }
        return BeatPulseTransform(scale: scale, dx: dx, dy: dy)
    }
}

/// Rasterizes a source frame under a `BeatPulseTransform` — scale about the
/// canvas center plus a shake offset — into an IOSurface-backed BGRA canvas
/// (the CPU reference the live compositor mirrors on the GPU layer quad). The
/// scale is uniform (`scaleBy` equal in x/y about the center), so the image is
/// never distorted; the same source aspect is preserved.
public final class BeatPulseRenderer {
    private let canvas: FXCanvas
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) throws {
        self.canvas = try FXCanvas(width: width, height: height)
        self.width = width
        self.height = height
    }

    /// Render `source` transformed by `t` over `background`. `source` is drawn
    /// to fill the canvas; scaling is about the center so the layer "booms" in
    /// place. Areas uncovered by the (offset) source show `background`.
    ///
    /// `background` defaults to **`.clear`** so the pass PRESERVES the source's
    /// alpha (the CPU oracle for `SourceEffectGPU.beatPulse`): a transparent
    /// source pixel, and any region the offset/scaled source does not cover,
    /// stays transparent `(0,0,0,0)` — NOT opaque black — so a transparent/keyed/
    /// cutout source composites over lower layers instead of blacking them out.
    /// Pass an opaque `background` to opt into flattening onto a colour.
    public func render(source: CVPixelBuffer, transform t: BeatPulseTransform,
                       background: RGBA = .clear) throws -> CVPixelBuffer {
        let img = try FXCanvas.cgImage(from: source)
        let w = CGFloat(width), h = CGFloat(height)
        let center = CGPoint(x: w / 2, y: h / 2)
        return try canvas.render { ctx in
            ctx.setFillColor(background.cg)
            ctx.fill(canvas.rect)

            ctx.saveGState()
            // Shake offset (dy positive = screen-down → −y in bottom-left context).
            ctx.translateBy(x: CGFloat(t.dx) * w, y: -CGFloat(t.dy) * h)
            // Uniform scale about the canvas center (no distortion).
            ctx.translateBy(x: center.x, y: center.y)
            ctx.scaleBy(x: CGFloat(t.scale), y: CGFloat(t.scale))
            ctx.translateBy(x: -center.x, y: -center.y)
            ctx.draw(img, in: canvas.rect)
            ctx.restoreGState()
        }
    }
}
