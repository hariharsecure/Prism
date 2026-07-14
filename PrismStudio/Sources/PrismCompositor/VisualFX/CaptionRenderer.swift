import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import PrismCore

/// Renders a rolling live-caption / subtitle overlay into a transparent,
/// IOSurface-backed BGRA buffer that burns straight over the program (the same
/// zero-copy premultiplied-first contract as `MotionGraphics` / `FXCanvas`).
///
/// The overlay is the classic broadcast subtitle: the last N caption lines in a
/// semi-opaque backing bar anchored to the **bottom third**, word-wrapped to the
/// safe width so long hypotheses never clip off-screen. Only the bar + text carry
/// alpha; everywhere else the frame is fully transparent (`FXCanvas.render` clears
/// to zero), so it composites without an opaque box. CoreGraphics stores every
/// fill/text draw premultiplied, so the compositor's premultiplied-alpha invariant
/// holds by construction.
///
/// Pure and deterministic (no `Date`, no hardware): the same `lines` + `style`
/// always produce the same pixels, which is what makes it headlessly verifiable.
public final class CaptionRenderer {
    private let canvas: FXCanvas
    public let width: Int
    public let height: Int

    /// Visual style for the caption overlay. All spatial fields are **fractions**
    /// of the canvas (width or height / font size) so one style renders correctly
    /// at any resolution.
    public struct Style: Sendable, Equatable {
        /// Font cap-size as a fraction of canvas height.
        public var fontSizeFraction: Double
        /// CoreText weight (-1…1); ~0.3 = medium, legible over video.
        public var fontWeight: Double
        /// Rolling window: keep only the last N wrapped display lines.
        public var maxLines: Int
        /// Text fill color.
        public var textColor: RGBA
        /// Semi-opaque backing-bar color (alpha < 1 keeps a hint of program).
        public var barColor: RGBA
        /// Clear margin kept on each side, as a fraction of width.
        public var sideMarginFraction: Double
        /// Gap below the bar to the frame bottom, as a fraction of height.
        public var bottomMarginFraction: Double
        /// Baseline-to-baseline spacing as a multiple of font size.
        public var lineSpacing: Double
        /// Horizontal padding inside the bar, as a fraction of width.
        public var textInsetFraction: Double
        /// Top/bottom padding inside the bar, as a multiple of font size.
        public var verticalPadFraction: Double
        /// Bar corner radius as a fraction of the bar height.
        public var cornerRadiusFraction: Double
        /// Soft dark drop-shadow blur behind the glyphs, as a fraction of font
        /// size, for legibility on bright video; 0 disables. (A drop shadow is used
        /// rather than a CoreText fill+stroke, which leaves a mid-glyph seam.)
        public var shadowBlurFraction: Double

        public init(fontSizeFraction: Double = 0.052,
                    fontWeight: Double = 0.3,
                    maxLines: Int = 2,
                    textColor: RGBA = .white,
                    barColor: RGBA = RGBA(r: 0, g: 0, b: 0, a: 0.55),
                    sideMarginFraction: Double = 0.08,
                    bottomMarginFraction: Double = 0.07,
                    lineSpacing: Double = 1.28,
                    textInsetFraction: Double = 0.022,
                    verticalPadFraction: Double = 0.42,
                    cornerRadiusFraction: Double = 0.18,
                    shadowBlurFraction: Double = 0.10) {
            self.fontSizeFraction = max(fontSizeFraction, 0.01)
            self.fontWeight = min(max(fontWeight, -1), 1)
            self.maxLines = max(maxLines, 1)
            self.textColor = textColor
            self.barColor = barColor
            self.sideMarginFraction = min(max(sideMarginFraction, 0), 0.4)
            self.bottomMarginFraction = min(max(bottomMarginFraction, 0), 0.5)
            self.lineSpacing = max(lineSpacing, 1.0)
            self.textInsetFraction = min(max(textInsetFraction, 0), 0.2)
            self.verticalPadFraction = max(verticalPadFraction, 0)
            self.cornerRadiusFraction = min(max(cornerRadiusFraction, 0), 0.5)
            self.shadowBlurFraction = max(shadowBlurFraction, 0)
        }
    }

    public init(width: Int, height: Int) throws {
        self.canvas = try FXCanvas(width: width, height: height)
        self.width = width
        self.height = height
    }

    /// Render the rolling caption overlay for `lines` (already the caption
    /// history — typically the committed line plus the live partial). Each input
    /// line is word-wrapped to the safe width; the last `style.maxLines` display
    /// lines are drawn in a bottom-third backing bar. Empty / all-blank input
    /// yields a fully transparent frame (no bar).
    public func render(lines: [String], style: Style = Style()) throws -> CVPixelBuffer {
        let w = Double(width), h = Double(height)
        let fontSize = max(style.fontSizeFraction * h, 6)
        let font = Self.font(size: fontSize, weight: style.fontWeight)
        let sideMargin = style.sideMarginFraction * w
        let textInset = style.textInsetFraction * w
        let maxTextWidth = max(w - 2 * sideMargin - 2 * textInset, fontSize)

        let display = Self.wrap(lines: lines, font: font,
                                maxWidth: maxTextWidth, maxLines: style.maxLines)

        return try canvas.render { ctx in
            guard !display.isEmpty else { return } // transparent frame, no bar

            let ascent = Double(CTFontGetAscent(font))
            let descent = Double(CTFontGetDescent(font))
            let lineH = fontSize * style.lineSpacing
            let padY = style.verticalPadFraction * fontSize
            let n = display.count

            // Build glyph lines and measure the widest for a content-fit bar.
            let ctLines = display.map { Self.ctLine($0, font: font, color: style.textColor) }
            var widest = 0.0
            for l in ctLines { widest = max(widest, Self.lineWidth(l)) }

            let textBlockH = Double(n - 1) * lineH + ascent + descent
            let barH = textBlockH + 2 * padY
            let maxBarW = w - 2 * sideMargin
            let barW = min(max(widest + 2 * textInset, 0.24 * w), maxBarW)
            let barLeftX = (w - barW) / 2 // centered

            // Anchor to the bottom third; clamp so the bar never leaves the frame.
            var barBottomY = style.bottomMarginFraction * h
            if barBottomY + barH > h { barBottomY = max(0, h - barH) }

            // Backing bar (semi-opaque, rounded).
            let barRect = CGRect(x: barLeftX, y: barBottomY, width: barW, height: barH)
            let radius = min(style.cornerRadiusFraction * barH, barH / 2)
            let path = CGPath(roundedRect: barRect, cornerWidth: CGFloat(radius),
                              cornerHeight: CGFloat(radius), transform: nil)
            ctx.setFillColor(style.barColor.cg)
            ctx.addPath(path)
            ctx.fillPath()

            // Soft dark drop-shadow under the glyphs for legibility over bright
            // video (offset slightly downward in this bottom-left-origin context).
            if style.shadowBlurFraction > 0 {
                let blur = style.shadowBlurFraction * fontSize
                ctx.setShadow(offset: CGSize(width: 0, height: -blur * 0.35),
                              blur: CGFloat(blur),
                              color: RGBA(r: 0, g: 0, b: 0, a: 0.9).cg)
            }

            // First (top) display line baseline; subsequent lines step downward.
            let firstBaseline = barBottomY + barH - padY - ascent
            for (i, line) in ctLines.enumerated() {
                let lw = Self.lineWidth(line)
                let x = barLeftX + (barW - lw) / 2 // centered per line
                let baseline = firstBaseline - Double(i) * lineH
                ctx.textPosition = CGPoint(x: x, y: baseline)
                CTLineDraw(line, ctx)
            }
        }
    }

    /// The exact display lines `render` will draw for `lines` under `style`:
    /// input word-wrapped to the safe width, then the last `maxLines` kept. Public
    /// so callers/tests can assert the rolling/wrapping behavior deterministically.
    public func wrappedLines(_ lines: [String], style: Style = Style()) -> [String] {
        let w = Double(width), h = Double(height)
        let fontSize = max(style.fontSizeFraction * h, 6)
        let font = Self.font(size: fontSize, weight: style.fontWeight)
        let sideMargin = style.sideMarginFraction * w
        let textInset = style.textInsetFraction * w
        let maxTextWidth = max(w - 2 * sideMargin - 2 * textInset, fontSize)
        return Self.wrap(lines: lines, font: font, maxWidth: maxTextWidth, maxLines: style.maxLines)
    }

    // MARK: - Word wrapping

    /// Greedy word-wrap of each input line to `maxWidth`, then keep the last
    /// `maxLines` produced display lines. A single word wider than `maxWidth` is
    /// hard-broken by characters so nothing ever exceeds the safe width.
    private static func wrap(lines: [String], font: CTFont,
                             maxWidth: Double, maxLines: Int) -> [String] {
        var out: [String] = []
        for raw in lines {
            let words = raw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                .map(String.init)
            if words.isEmpty { continue }
            var current = ""
            for word in words {
                let candidate = current.isEmpty ? word : current + " " + word
                if measure(candidate, font) <= maxWidth {
                    current = candidate
                } else if current.isEmpty {
                    // Single word too wide for an empty line → hard-break it.
                    let pieces = hardBreak(word, font: font, maxWidth: maxWidth)
                    out.append(contentsOf: pieces.dropLast())
                    current = pieces.last ?? ""
                } else {
                    out.append(current)
                    if measure(word, font) <= maxWidth {
                        current = word
                    } else {
                        let pieces = hardBreak(word, font: font, maxWidth: maxWidth)
                        out.append(contentsOf: pieces.dropLast())
                        current = pieces.last ?? ""
                    }
                }
            }
            if !current.isEmpty { out.append(current) }
        }
        if out.count > maxLines { out = Array(out.suffix(maxLines)) }
        return out
    }

    /// Break one over-long token into character chunks that each fit `maxWidth`.
    private static func hardBreak(_ word: String, font: CTFont, maxWidth: Double) -> [String] {
        var pieces: [String] = []
        var current = ""
        for ch in word {
            let candidate = current + String(ch)
            if current.isEmpty || measure(candidate, font) <= maxWidth {
                current = candidate
            } else {
                pieces.append(current)
                current = String(ch)
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.isEmpty ? [word] : pieces
    }

    // MARK: - CoreText helpers (bottom-left-origin CG context)

    private static func measure(_ s: String, _ font: CTFont) -> Double {
        lineWidth(ctLine(s, font: font, color: .white))
    }

    private static func lineWidth(_ line: CTLine) -> Double {
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        return CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
    }

    private static func ctLine(_ s: String, font: CTFont, color: RGBA) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): color.cg,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
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
