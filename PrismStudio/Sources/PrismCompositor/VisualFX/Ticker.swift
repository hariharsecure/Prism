import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import PrismCore

/// Where the ticker bar sits on the canvas.
public enum TickerPosition: String, Sendable, CaseIterable {
    /// Bar across the top third's lower edge.
    case top
    /// Bar across the bottom third.
    case bottom
}

/// Look of the horizontal news-crawl (`Ticker`).
public struct TickerStyle: Sendable, Equatable {
    public var position: TickerPosition
    /// Bar height as a fraction of canvas height.
    public var barHeightFraction: Double
    /// Bar fill (translucent lets a hint of program show).
    public var barColor: RGBA
    /// Leading accent block color (drawn at the bar's leading edge).
    public var accentColor: RGBA
    /// Text color.
    public var textColor: RGBA
    /// Font size as a fraction of the bar height.
    public var fontFraction: Double
    /// Gap (in text-em multiples) inserted between the string and its repeat, so
    /// the wrap has breathing room and the loop reads cleanly.
    public var gapEms: Double
    /// Optional separator glyph appended to the string (e.g. "   •   ").
    public var separator: String
    /// Draw the leading accent block.
    public var showAccent: Bool

    public init(position: TickerPosition = .bottom, barHeightFraction: Double = 0.11,
                barColor: RGBA = RGBA(r: 0.06, g: 0.07, b: 0.10, a: 0.92),
                accentColor: RGBA = RGBA(r: 0.90, g: 0.16, b: 0.20),
                textColor: RGBA = .white, fontFraction: Double = 0.52,
                gapEms: Double = 3, separator: String = "   •   ", showAccent: Bool = true) {
        self.position = position
        self.barHeightFraction = max(barHeightFraction, 0.001)
        self.barColor = barColor
        self.accentColor = accentColor
        self.textColor = textColor
        self.fontFraction = max(fontFraction, 0.001)
        self.gapEms = max(gapEms, 0)
        self.separator = separator
        self.showAccent = showAccent
    }
}

/// A horizontal news-crawl: a bar carrying text that scrolls right→left as the
/// caller advances `offset` (pixels) by `speed·dt` (DESIGN.md §2). The crawl is
/// SEAMLESS: internally `offset` wraps modulo the loop length (`loopLength` =
/// one copy of the string + its gap), and enough copies are tiled to always fill
/// the bar — so the frame at `offset` and the frame at `offset + loopLength` are
/// pixel-identical (no gap or jump at the wrap).
public final class Ticker {
    private let canvas: FXCanvas
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) throws {
        self.canvas = try FXCanvas(width: width, height: height)
        self.width = width
        self.height = height
    }

    private func font(_ style: TickerStyle) -> CTFont {
        let barH = style.barHeightFraction * Double(height)
        return Self.systemFont(size: barH * style.fontFraction, weight: 0.5)
    }

    /// One loop length in pixels: the ink width of `text + separator` plus the
    /// gap. Advancing `offset` by exactly this returns to an identical frame.
    public func loopLength(text: String, style: TickerStyle) -> Double {
        let f = font(style)
        let unit = text + style.separator
        let line = Self.ctLine(unit, font: f, color: style.textColor)
        let em = Double(CTFontGetSize(f))
        return Double(Self.inkWidth(line)) + style.gapEms * em
    }

    /// Render the crawl at the given horizontal `offset` (pixels scrolled).
    public func render(text: String, offset: Double, style: TickerStyle) throws -> CVPixelBuffer {
        let w = Double(width), h = Double(height)
        let barH = style.barHeightFraction * h
        let barY = style.position == .bottom ? 0.06 * h : (h - 0.06 * h - barH)
        let bar = CGRect(x: 0, y: barY, width: w, height: barH)

        let f = font(style)
        let unit = text + style.separator
        let line = Self.ctLine(unit, font: f, color: style.textColor)
        let em = Double(CTFontGetSize(f))
        let unitW = Double(Self.inkWidth(line))
        let loop = unitW + style.gapEms * em
        let accentW = style.showAccent ? barH * 0.28 : 0

        // Wrap the offset so any offset gives an identical frame one loop apart.
        let off = loop > 0 ? offset.truncatingRemainder(dividingBy: loop) : 0
        // Text enters at the right edge and scrolls left, exiting under the
        // leading accent block on the left.
        let startX = w
        // First copy's left edge; step back by whole loops so nothing pops in.
        var firstX = startX - off
        while firstX > 0 { firstX -= loop }

        // Baseline: vertically center the ink in the bar.
        let ink = Self.ctLine(unit, font: f, color: style.textColor)
        let ib = Self.inkBounds(ink)
        let baseline = bar.midY - Double(ib.height) / 2 - Double(ib.origin.y)

        return try canvas.render { ctx in
            // Bar.
            ctx.setFillColor(style.barColor.cg)
            ctx.fill(bar)
            // Tile the string across the whole bar so the crawl never shows a gap.
            var x = firstX
            while x < w {
                ctx.textPosition = CGPoint(x: x, y: baseline)
                CTLineDraw(line, ctx)
                x += loop
            }
            // Leading accent block on the left, drawn last so text scrolls under
            // it as it exits (a clean edge, like a broadcast category tag).
            if accentW > 0 {
                ctx.setFillColor(style.accentColor.cg)
                ctx.fill(CGRect(x: bar.minX, y: barY, width: accentW, height: barH))
            }
        }
    }

    // MARK: - CoreText helpers

    /// Build a single left-to-right `CTLine` for `s` in `font`/`color`.
    public static func ctLine(_ s: String, font: CTFont, color: RGBA) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): color.cg,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    }

    /// Typographic advance width — the correct step for tiling scroll copies.
    public static func inkWidth(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// The line's inked image bounds (for centering).
    public static func inkBounds(_ line: CTLine) -> CGRect {
        CTLineGetImageBounds(line, nil)
    }

    /// A weighted system font at `size` points.
    public static func systemFont(size: Double, weight: Double) -> CTFont {
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

// MARK: - Credits roll

/// Look of the vertical credits roll (`CreditsRoll`).
public struct CreditsStyle: Sendable, Equatable {
    /// Line height (baseline-to-baseline) as a fraction of canvas height.
    public var lineHeightFraction: Double
    /// Font size as a fraction of the line height.
    public var fontFraction: Double
    public var textColor: RGBA
    /// Vertical extent (top & bottom) over which lines fade, fraction of canvas.
    public var edgeFadeFraction: Double

    public init(lineHeightFraction: Double = 0.09, fontFraction: Double = 0.62,
                textColor: RGBA = .white, edgeFadeFraction: Double = 0.16) {
        self.lineHeightFraction = max(lineHeightFraction, 0.001)
        self.fontFraction = max(fontFraction, 0.001)
        self.textColor = textColor
        self.edgeFadeFraction = max(edgeFadeFraction, 0)
    }
}

/// A vertical end-of-stream credits roll: multi-line text scrolling bottom→top
/// as the caller advances `offset` (pixels). Lines enter at the bottom and exit
/// at the top; both edges fade over `edgeFadeFraction` of the canvas so lines
/// dissolve in/out rather than clip (DESIGN.md §2). Transparent premultiplied.
public final class CreditsRoll {
    private let canvas: FXCanvas
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) throws {
        self.canvas = try FXCanvas(width: width, height: height)
        self.width = width
        self.height = height
    }

    /// Total scroll distance (pixels) for all `lines` to travel from fully-below
    /// to fully-above the canvas — the natural end of the roll.
    public func rollLength(lineCount: Int, style: CreditsStyle) -> Double {
        let h = Double(height)
        let lineH = style.lineHeightFraction * h
        return h + Double(max(lineCount, 0)) * lineH
    }

    /// Render the roll at vertical `offset` (pixels scrolled up). At `offset 0`
    /// the first line sits just below the bottom edge; increasing `offset` lifts
    /// the block upward.
    public func render(lines: [String], offset: Double, style: CreditsStyle) throws -> CVPixelBuffer {
        let w = Double(width), h = Double(height)
        let lineH = style.lineHeightFraction * h
        let f = Ticker.systemFont(size: lineH * style.fontFraction, weight: 0.5)
        let fade = style.edgeFadeFraction * h

        // Precompute each line's centered CTLine + its ink metrics.
        let built: [(CTLine, CGRect)] = lines.map { s in
            let line = Ticker.ctLine(s, font: f, color: style.textColor)
            return (line, Ticker.inkBounds(line))
        }

        return try canvas.render { ctx in
            for (i, (line, ib)) in built.enumerated() {
                // Screen-top-origin y of the line center: first line starts just
                // below the bottom (y = h + lineH/2) and rises as offset grows.
                let yTopOrigin = h + lineH * 0.5 + Double(i) * lineH - offset
                if yTopOrigin < -lineH || yTopOrigin > h + lineH { continue }  // off-screen
                // Edge fade: full alpha in the middle band, ramps to 0 at both edges.
                let alpha = Self.edgeAlpha(yTopOrigin, height: h, fade: fade)
                if alpha <= 0.003 { continue }
                // Bottom-left-origin baseline, horizontally centered.
                let yBL = h - yTopOrigin        // convert center to bottom-left origin
                let baseline = yBL - Double(ib.height) / 2 - Double(ib.origin.y)
                let x = (w - Double(ib.width)) / 2 - Double(ib.origin.x)
                ctx.setAlpha(CGFloat(alpha))
                ctx.textPosition = CGPoint(x: x, y: baseline)
                CTLineDraw(line, ctx)
            }
            ctx.setAlpha(1)
        }
    }

    /// Alpha for a line whose center is at top-origin `y`: 1 in the middle,
    /// linearly fading to 0 within `fade` of the top and bottom edges.
    public static func edgeAlpha(_ y: Double, height: Double, fade: Double) -> Double {
        guard fade > 0 else { return (y >= 0 && y <= height) ? 1 : 0 }
        let dTop = y                 // distance from top edge
        let dBottom = height - y     // distance from bottom edge
        let d = min(dTop, dBottom)
        if d <= 0 { return 0 }
        return min(d / fade, 1)
    }
}
