import CoreGraphics
import CoreVideo
import Foundation

/// A composable per-layer transform sampled by the anime keyframe evaluator
/// (DESIGN.md §2). All fields are independent so multiple layers animate
/// separately ("like anime"). Offsets are normalized to the canvas.
public struct LayerTransform: Sendable, Equatable {
    /// Horizontal offset from the layer's rest position, fraction of canvas width.
    public var tx: Double
    /// Vertical offset, fraction of canvas height (positive = down, screen-space).
    public var ty: Double
    /// Uniform scale about the layer center (1 = rest).
    public var scale: Double
    /// Rotation about the layer center, radians.
    public var rotation: Double
    /// Layer opacity 0…1.
    public var opacity: Double
    /// Full-frame white flash accent 0…1 (the anime "impact" pop).
    public var flash: Double
    /// Radial speedline accent 0…1 drawn behind the layer center.
    public var accent: Double

    public init(tx: Double = 0, ty: Double = 0, scale: Double = 1, rotation: Double = 0,
                opacity: Double = 1, flash: Double = 0, accent: Double = 0) {
        self.tx = tx; self.ty = ty; self.scale = scale; self.rotation = rotation
        self.opacity = opacity; self.flash = flash; self.accent = accent
    }

    public static let identity = LayerTransform()

    static func interpolate(_ a: LayerTransform, _ b: LayerTransform, _ t: Double) -> LayerTransform {
        LayerTransform(tx: lerp(a.tx, b.tx, t), ty: lerp(a.ty, b.ty, t),
                       scale: lerp(a.scale, b.scale, t), rotation: lerp(a.rotation, b.rotation, t),
                       opacity: lerp(a.opacity, b.opacity, t), flash: lerp(a.flash, b.flash, t),
                       accent: lerp(a.accent, b.accent, t))
    }
}

/// One keyframe: the transform to reach at normalized `time` (0…1 of the
/// animation duration), and the easing used on the segment *ending* here.
public struct Keyframe: Sendable, Equatable {
    public var time: Double
    public var transform: LayerTransform
    public var easing: Easing
    public init(time: Double, transform: LayerTransform, easing: Easing = .easeInOut) {
        self.time = time; self.transform = transform; self.easing = easing
    }
}

/// A keyframe track: `time → LayerTransform`, the small evaluator that drives
/// the multi-stage anime animations. Keyframes are sorted by time on init.
public struct AnimTrack: Sendable, Equatable {
    public let keyframes: [Keyframe]
    /// Animation length in seconds (for time-based sampling).
    public let duration: Double

    public init(keyframes: [Keyframe], duration: Double) {
        self.keyframes = keyframes.sorted { $0.time < $1.time }
        self.duration = duration
    }

    /// Sample at normalized fraction `f` (0…1). Holds the endpoints outside range.
    public func sample(atFraction f: Double) -> LayerTransform {
        guard let first = keyframes.first, let last = keyframes.last else { return .identity }
        if f <= first.time { return first.transform }
        if f >= last.time { return last.transform }
        for i in 0..<(keyframes.count - 1) {
            let lo = keyframes[i], hi = keyframes[i + 1]
            if f >= lo.time && f <= hi.time {
                let span = hi.time - lo.time
                let local = span > 0 ? (f - lo.time) / span : 1
                let eased = hi.easing.apply(local)
                return LayerTransform.interpolate(lo.transform, hi.transform, eased)
            }
        }
        return last.transform
    }

    /// Sample at absolute `seconds` since the animation started.
    public func sample(atTime seconds: Double) -> LayerTransform {
        sample(atFraction: duration > 0 ? seconds / duration : 1)
    }
}

/// The anime-styled entrance/accent presets (DESIGN.md §2). Each builds a
/// multi-keyframe `AnimTrack` for the given duration.
public enum AnimePreset: String, Sendable, CaseIterable {
    /// Drops in from above, overshoots below rest, settles (overshoot + settle).
    case bounceIn
    /// Scale-punch past 1 with a white flash + speedline accent frame, then settle.
    case impactPop
    /// Decaying horizontal shake around rest.
    case shake
    /// Slides in from the left, overshoots past rest, settles.
    case slideOvershoot
    /// Spins in from nothing (rotation + scale up), settles upright.
    case popSpin

    public func track(duration: Double = 0.6) -> AnimTrack {
        switch self {
        case .bounceIn:
            return AnimTrack(keyframes: [
                Keyframe(time: 0.0, transform: LayerTransform(ty: -0.6, scale: 0.7, opacity: 0)),
                Keyframe(time: 0.55, transform: LayerTransform(ty: 0.05, scale: 1.10, opacity: 1), easing: .easeOut),
                Keyframe(time: 0.78, transform: LayerTransform(ty: -0.02, scale: 0.97, opacity: 1), easing: .easeInOut),
                Keyframe(time: 1.0, transform: LayerTransform(opacity: 1), easing: .easeOut),
            ], duration: duration)

        case .impactPop:
            return AnimTrack(keyframes: [
                Keyframe(time: 0.0, transform: LayerTransform(scale: 0.2, opacity: 0)),
                Keyframe(time: 0.14, transform: LayerTransform(scale: 1.32, opacity: 1, flash: 1.0, accent: 1.0), easing: .easeOut),
                Keyframe(time: 0.32, transform: LayerTransform(scale: 0.92, opacity: 1, flash: 0.08, accent: 0.25), easing: .easeInOut),
                Keyframe(time: 1.0, transform: LayerTransform(scale: 1.0, opacity: 1), easing: .easeOut),
            ], duration: duration)

        case .shake:
            // Programmatic decaying oscillation — many keyframes so tx flips sign.
            var kfs: [Keyframe] = []
            let n = 13
            for i in 0...n {
                let f = Double(i) / Double(n)
                let tx = 0.06 * sin(f * 40) * (1 - f)   // decays to 0
                kfs.append(Keyframe(time: f, transform: LayerTransform(tx: tx, opacity: 1), easing: .linear))
            }
            return AnimTrack(keyframes: kfs, duration: duration)

        case .slideOvershoot:
            return AnimTrack(keyframes: [
                Keyframe(time: 0.0, transform: LayerTransform(tx: -0.6, opacity: 0)),
                Keyframe(time: 0.7, transform: LayerTransform(tx: 0.06, opacity: 1), easing: .easeOut),
                Keyframe(time: 1.0, transform: LayerTransform(tx: 0, opacity: 1), easing: .easeInOut),
            ], duration: duration)

        case .popSpin:
            return AnimTrack(keyframes: [
                Keyframe(time: 0.0, transform: LayerTransform(scale: 0.0, rotation: -2 * .pi, opacity: 0)),
                Keyframe(time: 0.6, transform: LayerTransform(scale: 1.12, rotation: 0.18, opacity: 1), easing: .backOutDefault),
                Keyframe(time: 1.0, transform: LayerTransform(scale: 1.0, rotation: 0, opacity: 1), easing: .easeOut),
            ], duration: duration)
        }
    }
}

/// Rasterizes an animated layer: a sprite placed at a normalized rest rect,
/// transformed by a `LayerTransform`, over a background — the CPU reference for
/// §2 (produces the assertable / eyeball-able frames). The same `LayerTransform`
/// would drive the GPU layer quad in the live compositor.
public final class LayerAnimationRenderer {
    private let canvas: FXCanvas
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) throws {
        self.canvas = try FXCanvas(width: width, height: height)
        self.width = width
        self.height = height
    }

    /// - Parameters:
    ///   - sprite: the layer image.
    ///   - restRect: normalized rest placement, top-left origin (matches `Layer.frame`).
    ///   - background: solid fill behind the sprite.
    ///   - transform: sampled `LayerTransform`.
    public func render(sprite: CGImage, restRect: CGRect, background: RGBA, transform x: LayerTransform) throws -> CVPixelBuffer {
        let w = CGFloat(width), h = CGFloat(height)
        // Convert the top-left-origin rest rect to the bottom-left CG context.
        let restCG = CGRect(x: restRect.minX * w,
                            y: (1 - restRect.minY - restRect.height) * h,
                            width: restRect.width * w, height: restRect.height * h)
        let center = CGPoint(x: restCG.midX, y: restCG.midY)
        return try canvas.render { ctx in
            ctx.setFillColor(background.cg)
            ctx.fill(canvas.rect)

            // Radial speedline accent behind the sprite center.
            if x.accent > 0.01 {
                drawAccent(ctx, center: center, strength: x.accent)
            }

            ctx.saveGState()
            // Offset (ty positive = screen-down → −y in bottom-left context).
            ctx.translateBy(x: CGFloat(x.tx) * w, y: -CGFloat(x.ty) * h)
            // Scale + rotate about the sprite center.
            ctx.translateBy(x: center.x, y: center.y)
            ctx.scaleBy(x: CGFloat(x.scale), y: CGFloat(x.scale))
            ctx.rotate(by: CGFloat(x.rotation))
            ctx.translateBy(x: -center.x, y: -center.y)
            ctx.setAlpha(CGFloat(min(max(x.opacity, 0), 1)))
            ctx.draw(sprite, in: restCG)
            ctx.restoreGState()

            // Full-frame white flash accent on top.
            if x.flash > 0.01 {
                ctx.setFillColor(RGBA(r: 1, g: 1, b: 1, a: 1).cg)
                ctx.setAlpha(CGFloat(min(x.flash, 1)))
                ctx.fill(canvas.rect)
            }
        }
    }

    private func drawAccent(_ ctx: CGContext, center: CGPoint, strength: Double) {
        let reach = hypot(CGFloat(width), CGFloat(height))
        let count = 40
        ctx.setFillColor(RGBA(r: 1, g: 1, b: 0.85, a: 1).cg)
        for i in 0..<count {
            let a0 = (Double(i) / Double(count)) * 2 * .pi
            let half = 0.02 * strength
            let inner = reach * 0.12
            let p0 = CGPoint(x: center.x + cos(a0) * inner, y: center.y + sin(a0) * inner)
            let p1 = CGPoint(x: center.x + cos(a0 - half) * reach, y: center.y + sin(a0 - half) * reach)
            let p2 = CGPoint(x: center.x + cos(a0 + half) * reach, y: center.y + sin(a0 + half) * reach)
            ctx.beginPath(); ctx.move(to: p0); ctx.addLine(to: p1); ctx.addLine(to: p2); ctx.closePath()
            ctx.setAlpha(CGFloat(0.6 * strength))
            ctx.fillPath()
        }
        ctx.setAlpha(1)
    }
}
