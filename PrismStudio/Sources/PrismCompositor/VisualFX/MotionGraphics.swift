import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import PrismCore

/// Which screen corner a motion-graphic anchors to (and slides in from). Left
/// anchors slide in from the left edge, right anchors from the right; the
/// vertical half only positions the graphic, it does not change the slide axis.
public enum MGCorner: String, Sendable, CaseIterable {
    case bottomLeft, bottomRight, topLeft, topRight

    var isLeft: Bool { self == .bottomLeft || self == .topLeft }
    var isBottom: Bool { self == .bottomLeft || self == .bottomRight }
}

/// A time-driven entrance/hold/exit envelope for a motion-graphic overlay.
///
/// One time input (`t` seconds since the graphic was cued) maps to an
/// **entrance progress** `∈ 0…1`: it ramps `0→1` over `inSec` (the slide/pop-in),
/// holds at `1` for `holdSec`, then ramps `1→0` over `outSec` (the slide/pop-out).
/// This is how the classic broadcast "slide in, hold, slide out" lifecycle is
/// driven from a single clock — the renderer's `progress` parameter is exactly
/// this value. Pure and deterministic (no `Date`).
public struct MGTiming: Sendable, Equatable {
    public var inSec: Double
    public var holdSec: Double
    public var outSec: Double

    public init(inSec: Double = 0.5, holdSec: Double = 3.0, outSec: Double = 0.5) {
        self.inSec = max(inSec, 0.0001)
        self.holdSec = max(holdSec, 0)
        self.outSec = max(outSec, 0.0001)
    }

    /// Total on-air lifetime in seconds.
    public var totalSec: Double { inSec + holdSec + outSec }

    /// Entrance progress (0 = fully off, 1 = at rest) at `t` seconds.
    public func entranceProgress(at t: Double) -> Double {
        if t <= 0 { return 0 }
        if t < inSec { return t / inSec }
        if t < inSec + holdSec { return 1 }
        if t < totalSec { return 1 - (t - inSec - holdSec) / outSec }
        return 0
    }
}

/// Renders animated broadcast overlay graphics — lower-thirds, name-tags,
/// countdowns and CTA bugs — into transparent IOSurface-backed BGRA buffers that
/// composite directly over the program (DESIGN.md VisualFX). Every frame is a
/// premultiplied-first BGRA canvas whose background is left fully transparent by
/// `FXCanvas.render` (`ctx.clear`), so only the graphic's pixels carry alpha and
/// the overlay drops onto the program without an opaque box. CoreGraphics stores
/// every fill/stroke/text draw premultiplied, so the premultiplied-alpha
/// invariant the compositor requires holds by construction.
///
/// The entrance animation is driven by a single `progress ∈ 0…1` (see
/// `MGTiming.entranceProgress(at:)`): `0` = fully off-screen/invisible, `1` = at
/// rest. The slide offset and fade are eased with the shared `Easing` curves, so
/// the same value the app feeds the GPU layer would reproduce these frames.
public final class MotionGraphics {
    private let canvas: FXCanvas
    public let width: Int
    public let height: Int

    /// Default dark bar/plate fill (translucent so a hint of program shows).
    public static let barFill = RGBA(r: 0.06, g: 0.07, b: 0.10, a: 0.92)
    /// Default accent (broadcast blue).
    public static let defaultAccent = RGBA(r: 0.15, g: 0.55, b: 0.95)

    public init(width: Int, height: Int) throws {
        self.canvas = try FXCanvas(width: width, height: height)
        self.width = width
        self.height = height
    }

    // MARK: - Lower-third

    /// A broadcast lower-third: a bar carrying a bold `name` and a smaller
    /// `subtitle`, with a colored accent stripe, that slides in from the anchored
    /// corner's horizontal edge and fades up as `progress` goes `0→1`.
    ///
    /// - Parameters:
    ///   - name: primary line (bold).
    ///   - subtitle: secondary line (smaller).
    ///   - corner: which corner it anchors to (and the edge it slides in from).
    ///   - accent: accent-stripe color.
    ///   - progress: entrance progress `0…1` (0 = fully off-screen, 1 = at rest).
    public func lowerThird(name: String, subtitle: String, corner: MGCorner = .bottomLeft,
                           accent: RGBA = MotionGraphics.defaultAccent,
                           progress: Double) throws -> CVPixelBuffer {
        let e = min(max(progress, 0), 1)
        let slide = Easing.easeOut.apply(e)
        let fade = Easing.easeOut.apply(e)
        let w = Double(width), h = Double(height)

        let margin = 0.05 * w
        let barW = 0.56 * w
        let barH = 0.17 * h
        let accentW = 0.018 * w
        let barLeftX = corner.isLeft ? margin : (w - margin - barW)
        let barBottomY = corner.isBottom ? 0.11 * h : (h - 0.11 * h - barH)
        // Fully-off translation at progress 0, eased to 0 at rest.
        let offDX = corner.isLeft ? -(barLeftX + barW + 4) : (w - barLeftX + 4)
        let dx = (1 - slide) * offDX

        let bar = CGRect(x: barLeftX, y: barBottomY, width: barW, height: barH)
        let textX = barLeftX + accentW + 0.03 * w
        let nameFont = Self.font(size: barH * 0.42, weight: 0.62)
        let subFont = Self.font(size: barH * 0.26, weight: 0.30)

        return try canvas.render { ctx in
            ctx.saveGState()
            ctx.translateBy(x: dx, y: 0)
            ctx.setAlpha(CGFloat(fade))
            // Bar + accent stripe.
            Self.fillRound(ctx, bar, radius: barH * 0.14, color: Self.barFill)
            ctx.setFillColor(accent.cg)
            ctx.fill(CGRect(x: barLeftX, y: barBottomY, width: accentW, height: barH))
            // Name (baseline in the upper half) + subtitle (lower half).
            let nameLine = Self.ctLine(name, font: nameFont, color: .white, stroke: nil)
            Self.drawLeft(ctx, nameLine, x: textX, baseline: barBottomY + barH * 0.54)
            let subLine = Self.ctLine(subtitle, font: subFont,
                                      color: RGBA(r: 0.82, g: 0.86, b: 0.92), stroke: nil)
            Self.drawLeft(ctx, subLine, x: textX, baseline: barBottomY + barH * 0.18)
            ctx.setAlpha(1)
            ctx.restoreGState()
        }
    }

    // MARK: - Name-tag / nameplate

    /// A compact pill nameplate (for PiP presenters): a capsule filled with the
    /// accent color carrying a centered `name`, that pops in (scale + fade) as
    /// `progress` goes `0→1` with a slight overshoot.
    public func nameTag(name: String, corner: MGCorner = .bottomLeft,
                        accent: RGBA = MotionGraphics.defaultAccent,
                        progress: Double) throws -> CVPixelBuffer {
        let e = min(max(progress, 0), 1)
        let pop = Easing.backOutDefault.apply(e)      // may overshoot > 1
        let scale = 0.6 + 0.4 * pop
        let fade = Easing.easeOut.apply(e)
        let w = Double(width), h = Double(height)

        let ph = 0.10 * h
        let padX = 0.035 * w
        let font = Self.font(size: ph * 0.5, weight: 0.60)
        let margin = 0.05 * w

        return try canvas.render { ctx in
            let line = Self.ctLine(name, font: font, color: .white,
                                   stroke: RGBA(r: 0, g: 0, b: 0, a: 0.35))
            ctx.textPosition = .zero
            let ink = CTLineGetImageBounds(line, ctx)
            let pw = max(Double(ink.width) + 2 * padX, 0.16 * w)
            let pillLeftX = corner.isLeft ? margin : (w - margin - pw)
            let pillBottomY = corner.isBottom ? 0.08 * h : (h - 0.08 * h - ph)
            let pill = CGRect(x: pillLeftX, y: pillBottomY, width: pw, height: ph)
            let center = CGPoint(x: pill.midX, y: pill.midY)

            ctx.saveGState()
            ctx.setAlpha(CGFloat(fade))
            ctx.translateBy(x: center.x, y: center.y)
            ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            ctx.translateBy(x: -center.x, y: -center.y)
            Self.fillRound(ctx, pill, radius: ph * 0.5, color: accent)
            Self.drawCentered(ctx, line, center: center, in: ctx)
            ctx.setAlpha(1)
            ctx.restoreGState()
        }
    }

    // MARK: - Countdown

    /// A big centered countdown number with a depleting accent ring and a
    /// per-second "tick" pop.
    ///
    /// - Parameters:
    ///   - secondsRemaining: the number to show (clamped `≥ 0`).
    ///   - tickProgress: progress `0…1` through the CURRENT second. The number
    ///     pops (scales `~1.3→1`) as this goes `0→1`, and the ring depletes from
    ///     full (`0`) to empty (`1`).
    ///   - accent: ring color.
    public func countdown(secondsRemaining: Int, tickProgress: Double,
                          accent: RGBA = MotionGraphics.defaultAccent) throws -> CVPixelBuffer {
        let n = max(secondsRemaining, 0)
        let tp = min(max(tickProgress, 0), 1)
        let pop = 1 + 0.30 * (1 - Easing.easeOut.apply(tp))   // 1.30 → 1.0
        let w = Double(width), h = Double(height)
        let center = CGPoint(x: w / 2, y: h / 2)
        let discR = 0.30 * h
        let ringR = discR * 0.86
        let ringWidth = 0.020 * h
        let font = Self.font(size: 0.34 * h, weight: 0.66)
        let remaining = 1 - tp

        return try canvas.render { ctx in
            // Dim backdrop disc (translucent — keeps the overlay legible; outside
            // the disc stays transparent).
            ctx.setFillColor(RGBA(r: 0, g: 0, b: 0, a: 0.45).cg)
            ctx.fillEllipse(in: CGRect(x: center.x - discR, y: center.y - discR,
                                       width: discR * 2, height: discR * 2))
            // Faint full ring.
            ctx.setStrokeColor(RGBA(r: 1, g: 1, b: 1, a: 0.18).cg)
            ctx.setLineWidth(CGFloat(ringWidth))
            ctx.addArc(center: center, radius: CGFloat(ringR), startAngle: 0,
                       endAngle: CGFloat(2 * Double.pi), clockwise: false)
            ctx.strokePath()
            // Accent arc for the remaining fraction, from the top, clockwise.
            if remaining > 0.001 {
                ctx.setStrokeColor(accent.cg)
                ctx.setLineWidth(CGFloat(ringWidth))
                ctx.setLineCap(.round)
                let start = CGFloat(Double.pi / 2)
                let end = start - CGFloat(remaining * 2 * Double.pi)
                ctx.addArc(center: center, radius: CGFloat(ringR), startAngle: start,
                           endAngle: end, clockwise: true)
                ctx.strokePath()
            }
            // The number, popping about the center.
            let line = Self.ctLine("\(n)", font: font, color: .white,
                                   stroke: RGBA(r: 0, g: 0, b: 0, a: 0.5))
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.scaleBy(x: CGFloat(pop), y: CGFloat(pop))
            ctx.translateBy(x: -center.x, y: -center.y)
            Self.drawCentered(ctx, line, center: center, in: ctx)
            ctx.restoreGState()
        }
    }

    // MARK: - Subscribe / CTA bug

    /// A small call-to-action badge (e.g. "SUBSCRIBE") with a leading play glyph
    /// that pops in (scale + fade, slight overshoot) as `progress` goes `0→1`.
    public func ctaBug(text: String = "SUBSCRIBE", corner: MGCorner = .bottomRight,
                       accent: RGBA = RGBA(r: 0.90, g: 0.16, b: 0.20),
                       progress: Double) throws -> CVPixelBuffer {
        let e = min(max(progress, 0), 1)
        let pop = Easing.backOutDefault.apply(e)
        let scale = 0.5 + 0.5 * pop
        let fade = Easing.easeOut.apply(e)
        let w = Double(width), h = Double(height)

        let bh = 0.12 * h
        let padX = 0.030 * w
        let glyphW = bh * 0.55
        let gap = 0.018 * w
        let font = Self.font(size: bh * 0.42, weight: 0.64)
        let margin = 0.05 * w

        return try canvas.render { ctx in
            let line = Self.ctLine(text, font: font, color: .white, stroke: nil)
            ctx.textPosition = .zero
            let ink = CTLineGetImageBounds(line, ctx)
            let bw = Double(ink.width) + glyphW + gap + 2 * padX
            let bLeftX = corner.isLeft ? margin : (w - margin - bw)
            let bBottomY = corner.isBottom ? 0.08 * h : (h - 0.08 * h - bh)
            let badge = CGRect(x: bLeftX, y: bBottomY, width: bw, height: bh)
            let center = CGPoint(x: badge.midX, y: badge.midY)

            ctx.saveGState()
            ctx.setAlpha(CGFloat(fade))
            ctx.translateBy(x: center.x, y: center.y)
            ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            ctx.translateBy(x: -center.x, y: -center.y)
            Self.fillRound(ctx, badge, radius: bh * 0.28, color: accent)
            // Leading white play triangle.
            let gx = bLeftX + padX
            let gcy = badge.midY
            ctx.setFillColor(RGBA.white.cg)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: gx, y: gcy + glyphW * 0.5))
            ctx.addLine(to: CGPoint(x: gx, y: gcy - glyphW * 0.5))
            ctx.addLine(to: CGPoint(x: gx + glyphW, y: gcy))
            ctx.closePath()
            ctx.fillPath()
            // Label baseline vertically centered on the ink.
            let baseline = badge.midY - Double(ink.height) / 2 - Double(ink.origin.y)
            Self.drawLeft(ctx, line, x: gx + glyphW + gap, baseline: baseline)
            ctx.setAlpha(1)
            ctx.restoreGState()
        }
    }

    // MARK: - Drawing helpers (bottom-left-origin CG context)

    private static func fillRound(_ ctx: CGContext, _ r: CGRect, radius: Double, color: RGBA) {
        let p = CGPath(roundedRect: r, cornerWidth: CGFloat(radius), cornerHeight: CGFloat(radius),
                       transform: nil)
        ctx.setFillColor(color.cg)
        ctx.addPath(p)
        ctx.fillPath()
    }

    private static func ctLine(_ s: String, font: CTFont, color: RGBA, stroke: RGBA?) -> CTLine {
        var attrs: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): color.cg,
        ]
        if let stroke {
            // Negative width = fill + stroke (CoreText convention).
            attrs[.init(kCTStrokeWidthAttributeName as String)] = -4.0
            attrs[.init(kCTStrokeColorAttributeName as String)] = stroke.cg
        }
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    }

    /// Draw a line left-aligned with its pen origin at `(x, baseline)`.
    private static func drawLeft(_ ctx: CGContext, _ line: CTLine, x: Double, baseline: Double) {
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, ctx)
    }

    /// Draw a line centered (both axes) on `center`. Bounds are measured with the
    /// text position reset to `.zero` so they are position-independent (the
    /// MemeBoard B7 gotcha).
    private static func drawCentered(_ ctx: CGContext, _ line: CTLine, center: CGPoint,
                                     in measureCtx: CGContext) {
        measureCtx.textPosition = .zero
        let b = CTLineGetImageBounds(line, measureCtx)
        ctx.textPosition = CGPoint(x: center.x - b.width / 2 - b.origin.x,
                                   y: center.y - b.height / 2 - b.origin.y)
        CTLineDraw(line, ctx)
    }

    private static func font(size: Double, weight: Double) -> CTFont {
        let traits: [CFString: Any] = [kCTFontWeightTrait: weight]
        let attrs: [CFString: Any] = [
            kCTFontFamilyNameAttribute: ".AppleSystemUIFont",
            kCTFontSizeAttribute: size,
            kCTFontTraitsAttribute: traits,
        ]
        let desc = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
        return CTFontCreateWithFontDescriptor(desc, CGFloat(size), nil)
    }
}
