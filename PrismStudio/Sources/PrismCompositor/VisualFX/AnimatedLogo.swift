import CoreGraphics
import CoreVideo
import Foundation
import PrismCore

/// Which canvas edge a slide entrance travels in from.
public enum LogoEdge: String, Sendable, CaseIterable {
    case left, right, top, bottom
}

/// Screen anchor for a logo (also the corner a slide entrance defaults toward).
public enum LogoAnchor: String, Sendable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight, center

    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isRight: Bool { self == .topRight || self == .bottomRight }
    var isTop: Bool { self == .topLeft || self == .topRight }
    var isBottom: Bool { self == .bottomLeft || self == .bottomRight }
}

/// Entrance animation for a logo, driven by a single `progress ∈ 0…1`
/// (0 = fully off/invisible, 1 = at rest). The **exit** is the same animation
/// run in reverse — feed `progress` from `1 → 0` (DESIGN.md §1 "exit = reverse").
public enum LogoEntrance: Sendable, Equatable {
    /// Opacity `0 → 1`.
    case fade
    /// Slides in from the given canvas edge (opacity ramps too).
    case slide(LogoEdge)
    /// Scale-pop `0.3 → 1` with a `backOut` overshoot.
    case scalePop
    /// Spins in: rotation `−2π → 0` and scale `0 → 1`.
    case spinIn
    /// Blurs in: a decaying multi-tap blur radius `→ 0` with a slight scale settle.
    case blurIn
}

/// Idle loop applied while the logo is at rest, driven by a phase `∈ 0…1` that
/// wraps every loop period. All are subtle and periodic (`phase 0 == phase 1`),
/// so the loop is seamless (DESIGN.md §1 idle).
public enum LogoIdle: String, Sendable, CaseIterable {
    /// No idle motion (static at rest).
    case none
    /// Sine vertical bob.
    case float
    /// Scale "breathe" in and out.
    case pulse
    /// A diagonal highlight sweep across the logo (clipped to its alpha).
    case shimmer
    /// A small rotational sway.
    case sway
}

/// Parameters for `AnimatedLogo.render`. Durations are the caller's concern
/// (`progress`/`idlePhase` arrive pre-normalized — see `LogoTiming`); everything
/// here is spatial/stylistic.
public struct LogoStyle: Sendable, Equatable {
    /// Screen anchor.
    public var anchor: LogoAnchor
    /// Logo width as a fraction of canvas width (aspect preserved from the image).
    public var sizeFraction: Double
    /// Inset from the anchored edges, fraction of the canvas.
    public var margin: Double
    /// Entrance style (exit = the same run in reverse).
    public var entrance: LogoEntrance
    /// Idle-loop style.
    public var idle: LogoIdle
    /// Scales the idle motion amplitude (1 = default).
    public var idleAmplitude: Double
    /// Bug mode: a persistent corner watermark — entrance/exit are skipped
    /// (`progress` treated as 1) and the idle runs at a low amplitude.
    public var isBug: Bool

    public init(anchor: LogoAnchor = .topRight, sizeFraction: Double = 0.18,
                margin: Double = 0.04, entrance: LogoEntrance = .fade,
                idle: LogoIdle = .float, idleAmplitude: Double = 1, isBug: Bool = false) {
        self.anchor = anchor
        self.sizeFraction = max(sizeFraction, 0.001)
        self.margin = max(margin, 0)
        self.entrance = entrance
        self.idle = idle
        self.idleAmplitude = max(idleAmplitude, 0)
        self.isBug = isBug
    }

    /// A ready-made always-on corner watermark (idle-only, low amplitude).
    public static func bug(anchor: LogoAnchor = .bottomRight, sizeFraction: Double = 0.10,
                           idle: LogoIdle = .float) -> LogoStyle {
        LogoStyle(anchor: anchor, sizeFraction: sizeFraction, margin: 0.03,
                  entrance: .fade, idle: idle, idleAmplitude: 0.4, isBug: true)
    }
}

/// A pure entrance/hold/exit + idle clock for a logo (DESIGN.md §1). Maps a time
/// `t` (seconds since cue) to the `progress` and `idlePhase` that `render`
/// consumes. Deterministic — no `Date` (mirrors `MGTiming`).
public struct LogoTiming: Sendable, Equatable {
    public var inSec: Double
    public var holdSec: Double
    public var outSec: Double
    /// Seconds per idle loop.
    public var idlePeriod: Double

    public init(inSec: Double = 0.6, holdSec: Double = 4, outSec: Double = 0.6, idlePeriod: Double = 3) {
        self.inSec = max(inSec, 0.0001)
        self.holdSec = max(holdSec, 0)
        self.outSec = max(outSec, 0.0001)
        self.idlePeriod = max(idlePeriod, 0.0001)
    }

    public var totalSec: Double { inSec + holdSec + outSec }

    /// Entrance progress (0 = off, 1 = at rest) at `t`. Ramps up over `inSec`,
    /// holds at 1, ramps back to 0 over `outSec` (the reverse = exit).
    public func progress(at t: Double) -> Double {
        if t <= 0 { return 0 }
        if t < inSec { return t / inSec }
        if t < inSec + holdSec { return 1 }
        if t < totalSec { return 1 - (t - inSec - holdSec) / outSec }
        return 0
    }

    /// Idle phase `∈ 0…1`, wrapping every `idlePeriod` seconds.
    public func idlePhase(at t: Double) -> Double {
        let p = t / idlePeriod
        return p - floor(p)
    }
}

/// The resolved per-frame transform for the logo (entrance ⊕ idle folded
/// together). Exposed so the same values could drive a GPU layer quad; `render`
/// applies it on the CPU raster path.
public struct LogoTransform: Sendable, Equatable {
    public var tx: Double        // horizontal offset, fraction of canvas width
    public var ty: Double        // vertical offset, fraction of canvas height (+ = down)
    public var scale: Double
    public var rotation: Double  // radians
    public var opacity: Double
    public var blur: Double      // blur radius, fraction of the logo's width (0 = sharp)

    public init(tx: Double = 0, ty: Double = 0, scale: Double = 1, rotation: Double = 0,
                opacity: Double = 1, blur: Double = 0) {
        self.tx = tx; self.ty = ty; self.scale = scale; self.rotation = rotation
        self.opacity = opacity; self.blur = blur
    }
}

/// Renders a caller-supplied logo (`CGImage`, with its own alpha) into a
/// transparent, premultiplied IOSurface-backed BGRA overlay (DESIGN.md §1).
///
/// One `progress ∈ 0…1` drives the entrance (0 = off, 1 = at rest); feeding it
/// `1 → 0` plays the exit (the reverse). `idlePhase ∈ 0…1` drives the looped
/// idle motion, whose amplitude is scaled by the entrance progress so it fades
/// in with the logo. The logo's own transparency is preserved: the background is
/// left clear by `FXCanvas.render` and only the logo's premultiplied pixels are
/// drawn.
public final class AnimatedLogo {
    private let canvas: FXCanvas
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) throws {
        self.canvas = try FXCanvas(width: width, height: height)
        self.width = width
        self.height = height
    }

    /// Resolve the entrance ⊕ idle transform for the given drivers (pure — no
    /// drawing; useful for tests and for a GPU port).
    public func transform(progress: Double, idlePhase: Double, style: LogoStyle) -> LogoTransform {
        let e = style.isBug ? 1 : min(max(progress, 0), 1)
        var t = Self.entranceTransform(style.entrance, e: e)
        // Idle amplitude follows the entrance so it eases in with the logo.
        let amp = style.idleAmplitude * (style.isBug ? 0.5 : e)
        Self.applyIdle(style.idle, phase: idlePhase, amp: amp, into: &t)
        return t
    }

    /// Render one frame. `logo` is drawn upright, anchored per `style`, with the
    /// resolved entrance ⊕ idle transform applied. Transparent premultiplied BGRA.
    public func render(logo: CGImage, progress: Double, idlePhase: Double,
                       style: LogoStyle) throws -> CVPixelBuffer {
        let e = style.isBug ? 1 : min(max(progress, 0), 1)
        let t = transform(progress: progress, idlePhase: idlePhase, style: style)
        let w = Double(width), h = Double(height)

        // Rest rect (bottom-left origin), width = sizeFraction·canvas, aspect kept.
        let imgW = Double(logo.width), imgH = Double(logo.height)
        let aspect = imgW > 0 ? imgH / imgW : 1
        let restW = style.sizeFraction * w
        let restH = restW * aspect
        let m = style.margin * min(w, h)
        let restX: Double
        if style.anchor.isLeft { restX = m }
        else if style.anchor.isRight { restX = w - m - restW }
        else { restX = (w - restW) / 2 }
        let restY: Double   // bottom-left origin
        if style.anchor.isBottom { restY = m }
        else if style.anchor.isTop { restY = h - m - restH }
        else { restY = (h - restH) / 2 }
        let restRect = CGRect(x: restX, y: restY, width: restW, height: restH)
        let center = CGPoint(x: restRect.midX, y: restRect.midY)

        // The shimmer sweep position (0…1 across the logo) — only for that idle.
        let shimmerP = (style.idle == .shimmer) ? (idlePhase - floor(idlePhase)) : -1
        let shimmerStrength = (style.idle == .shimmer)
            ? style.idleAmplitude * (style.isBug ? 0.5 : e) : 0

        return try canvas.render { ctx in
            ctx.saveGState()
            // Offset (ty positive = screen-down → −y in the bottom-left context).
            ctx.translateBy(x: CGFloat(t.tx) * w, y: -CGFloat(t.ty) * h)
            // Scale + rotate about the logo center.
            ctx.translateBy(x: center.x, y: center.y)
            ctx.scaleBy(x: CGFloat(t.scale), y: CGFloat(t.scale))
            ctx.rotate(by: CGFloat(t.rotation))
            ctx.translateBy(x: -center.x, y: -center.y)
            let baseAlpha = min(max(t.opacity, 0), 1)
            ctx.setAlpha(CGFloat(baseAlpha))
            ctx.interpolationQuality = .high

            if t.blur > 0.001 {
                // Cheap deterministic blur: ring of offset taps at reduced alpha.
                Self.drawBlurred(ctx, logo, in: restRect, radius: t.blur * restW, baseAlpha: baseAlpha)
            } else {
                ctx.draw(logo, in: restRect)
            }

            // Highlight sweep, clipped to the logo's own alpha shape.
            if shimmerP >= 0 && shimmerStrength > 0.001 {
                ctx.saveGState()
                ctx.clip(to: restRect, mask: logo)   // logo alpha = the mask
                Self.drawShimmer(ctx, rect: restRect, phase: shimmerP, strength: shimmerStrength)
                ctx.restoreGState()
            }
            ctx.setAlpha(1)
            ctx.restoreGState()
        }
    }

    // MARK: - Entrance / idle math

    private static func entranceTransform(_ entrance: LogoEntrance, e: Double) -> LogoTransform {
        switch entrance {
        case .fade:
            return LogoTransform(opacity: Easing.easeOut.apply(e))
        case .slide(let edge):
            let s = Easing.easeOut.apply(e)
            let off = 1 - s          // 1 fully off → 0 at rest (fraction of canvas)
            switch edge {
            case .left:   return LogoTransform(tx: -off, opacity: s)
            case .right:  return LogoTransform(tx: off, opacity: s)
            case .top:    return LogoTransform(ty: -off, opacity: s)
            case .bottom: return LogoTransform(ty: off, opacity: s)
            }
        case .scalePop:
            let pop = Easing.backOutDefault.apply(e)      // may overshoot > 1
            return LogoTransform(scale: 0.3 + 0.7 * pop, opacity: Easing.easeOut.apply(e))
        case .spinIn:
            let s = Easing.easeOut.apply(e)
            return LogoTransform(scale: s, rotation: -2 * .pi * (1 - s), opacity: s)
        case .blurIn:
            let s = Easing.easeOut.apply(e)
            return LogoTransform(scale: 1.05 - 0.05 * s, opacity: s, blur: 0.20 * (1 - s))
        }
    }

    private static func applyIdle(_ idle: LogoIdle, phase: Double, amp: Double, into t: inout LogoTransform) {
        guard amp > 0 else { return }
        let p = phase - floor(phase)
        let w = 2 * Double.pi * p
        switch idle {
        case .none, .shimmer:
            break                                   // shimmer is a draw-time overlay
        case .float:
            t.ty += amp * 0.02 * sin(w)             // ±2% of height at amp 1
        case .pulse:
            t.scale *= 1 + amp * 0.04 * (0.5 - 0.5 * cos(w))   // breathe 0…+4%
        case .sway:
            t.rotation += amp * 0.06 * sin(w)       // ±0.06 rad at amp 1
        }
    }

    // MARK: - Draw helpers

    /// Ring-tap blur approximation (premultiplied-safe; deterministic).
    private static func drawBlurred(_ ctx: CGContext, _ img: CGImage, in rect: CGRect,
                                    radius: Double, baseAlpha: Double) {
        let taps = 8
        let a = CGFloat(baseAlpha)
        ctx.setAlpha(a / CGFloat(taps + 1))
        ctx.draw(img, in: rect)                      // center tap
        for i in 0..<taps {
            let ang = Double(i) / Double(taps) * 2 * .pi
            let dx = CGFloat(cos(ang) * radius), dy = CGFloat(sin(ang) * radius)
            ctx.draw(img, in: rect.offsetBy(dx: dx, dy: dy))
        }
        ctx.setAlpha(a)
    }

    /// A soft diagonal white highlight band centered at `phase` across the rect,
    /// drawn additively (`.plusLighter`) so it brightens the logo without a box.
    private static func drawShimmer(_ ctx: CGContext, rect: CGRect, phase: Double, strength: Double) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let a = min(strength, 1) * 0.55
        let colors = [RGBA(r: 1, g: 1, b: 1, a: 0).cg,
                      RGBA(r: 1, g: 1, b: 1, a: a).cg,
                      RGBA(r: 1, g: 1, b: 1, a: 0).cg] as CFArray
        guard let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 0.5, 1]) else { return }
        // Band travels left→right; widen the travel so it enters and exits fully.
        let bandW = rect.width * 0.45
        let travel = rect.width + bandW
        let cx = rect.minX - bandW / 2 + phase * travel
        // Diagonal: shift the band top vs bottom for the classic slanted sheen.
        let slant = rect.height * 0.5
        ctx.setBlendMode(.plusLighter)
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: cx - bandW / 2 - slant, y: rect.minY),
                               end: CGPoint(x: cx + bandW / 2 + slant, y: rect.maxY),
                               options: [])
        ctx.setBlendMode(.normal)
    }
}
