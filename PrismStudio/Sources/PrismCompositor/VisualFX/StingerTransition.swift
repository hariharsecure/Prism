import CoreGraphics
import CoreVideo
import Foundation

/// The OBS-style **stinger** transition (DESIGN.md §1, the headline): a chosen
/// image / GIF / video *source* plays OVER the cut, and program A→B swaps at a
/// configured **cue** (the progress at which the stinger fully covers screen).
///
/// The overlay is described by a `draw` closure (progress → paint over the
/// program), so any source — a procedural panel, a still image/GIF frame, or a
/// meme item (see `MemeBoard`) — can be a stinger. The cut is instantaneous at
/// `cueProgress`; the overlay hides it.
public struct StingerTransition: Sendable {
    /// Paint the stinger overlay over the program for a progress (0…1) on a
    /// `size`-pixel, bottom-left-origin context. Draw nothing to show program.
    public typealias Draw = @Sendable (_ ctx: CGContext, _ progress: Double, _ size: CGSize) -> Void

    public var duration: Double
    /// Progress (0…1) at which the program hard-cuts A→B. Should be the moment
    /// the overlay fully covers the screen (default 0.5).
    public var cueProgress: Double
    public let draw: Draw

    public init(duration: Double = 0.7, cueProgress: Double = 0.5, draw: @escaping Draw) {
        self.duration = duration
        self.cueProgress = min(max(cueProgress, 0), 1)
        self.draw = draw
    }

    // MARK: - Built-in stingers

    /// A solid panel that slides fully across to cover the screen by `cueProgress`,
    /// then slides off the opposite edge — the canonical stinger shape.
    public static func panel(color: RGBA, direction: FXDirection = .left, duration: Double = 0.7,
                             cueProgress: Double = 0.5) -> StingerTransition {
        // B6: sanitize the cue ONCE and capture the SAME value in both the struct
        // and the draw closure — a raw out-of-range cue captured only by the
        // closure desyncs from `self.cueProgress` (which StingerRenderer uses to
        // pick the base scene) and breaks the endpoints.
        let cue = min(max(cueProgress, 0.0001), 0.9999)
        return StingerTransition(duration: duration, cueProgress: cue) { ctx, p, size in
            // 0→cue: cover fraction 0→1. cue→1: uncover on the far side 0→1.
            let covering = p <= cue
            let phase = covering ? p / cue : (p - cue) / (1 - cue)
            ctx.setFillColor(color.cg)
            let w = size.width, h = size.height
            if covering {
                // Leading edge advances across; panel occupies [0, phase*extent] from `direction`.
                switch direction {
                case .left:  ctx.fill(CGRect(x: 0, y: 0, width: w * CGFloat(phase), height: h))
                case .right: ctx.fill(CGRect(x: w * (1 - CGFloat(phase)), y: 0, width: w * CGFloat(phase), height: h))
                case .down:  ctx.fill(CGRect(x: 0, y: 0, width: w, height: h * CGFloat(phase)))
                case .up:    ctx.fill(CGRect(x: 0, y: h * (1 - CGFloat(phase)), width: w, height: h * CGFloat(phase)))
                }
            } else {
                // Trailing edge exits the opposite side; panel occupies the shrinking remainder.
                switch direction {
                case .left:  ctx.fill(CGRect(x: w * CGFloat(phase), y: 0, width: w * (1 - CGFloat(phase)), height: h))
                case .right: ctx.fill(CGRect(x: 0, y: 0, width: w * (1 - CGFloat(phase)), height: h))
                case .down:  ctx.fill(CGRect(x: 0, y: h * CGFloat(phase), width: w, height: h * (1 - CGFloat(phase))))
                case .up:    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h * (1 - CGFloat(phase))))
                }
            }
        }
    }

    /// A full-frame media image (a meme, a bumper, a GIF frame) that fades to
    /// fully opaque by `cueProgress`, then fades back out — the "media cover"
    /// stinger. This is how a `MemeItem` becomes a stinger.
    public static func mediaCover(image: CGImage, duration: Double = 0.7,
                                  cueProgress: Double = 0.5) -> StingerTransition {
        // CGImage is Sendable-safe to capture here (immutable, effect path).
        let boxed = ImageBox(image)
        // B6: one sanitized cue, shared by the struct and the closure.
        let cue = min(max(cueProgress, 0.0001), 0.9999)
        return StingerTransition(duration: duration, cueProgress: cue) { ctx, p, size in
            let alpha = p <= cue ? p / cue : (1 - (p - cue) / (1 - cue))
            ctx.setAlpha(CGFloat(min(max(alpha, 0), 1)))
            ctx.draw(boxed.image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            ctx.setAlpha(1)
        }
    }
}

/// Renders stinger frames over image sources — base program A/B with the
/// overlay painted on top, swapping A→B at the cue.
public final class StingerRenderer {
    private let canvas: FXCanvas
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) throws {
        self.canvas = try FXCanvas(width: width, height: height)
        self.width = width
        self.height = height
    }

    /// One stinger frame at raw `progress` (0…1). Program shows A before the
    /// cue and B at/after it; the overlay is painted on top.
    public func render(a: CVPixelBuffer, b: CVPixelBuffer, stinger: StingerTransition, progress rawT: Double) throws -> CVPixelBuffer {
        let t = min(max(rawT, 0), 1)
        // B6: exact endpoints regardless of any interior cue math — p≤0 is
        // pure program A, p≥1 is pure program B (the overlay is fully off).
        if t <= 0 { return try copy(a) }
        if t >= 1 { return try copy(b) }
        let base = t < stinger.cueProgress ? a : b
        let img = try FXCanvas.cgImage(from: base)
        let size = CGSize(width: width, height: height)
        return try canvas.render { ctx in
            ctx.draw(img, in: canvas.rect)
            stinger.draw(ctx, t, size)
        }
    }

    /// Exact copy of a program buffer into a fresh FX buffer (for the 0/1 endpoints).
    private func copy(_ src: CVPixelBuffer) throws -> CVPixelBuffer {
        let img = try FXCanvas.cgImage(from: src)
        return try canvas.render { ctx in ctx.draw(img, in: canvas.rect) }
    }
}

/// `@unchecked Sendable` box for an immutable `CGImage` captured in a stinger
/// draw closure (CGImage is not declared Sendable; it is treated immutable here).
struct ImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
