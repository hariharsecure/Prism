import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import os
import PrismCompositor
import PrismCore

/// A styled text / title source (DESIGN.md §2.1 — "Text/title source: SF fonts,
/// live variables: clock, counters") — lower-thirds without a browser.
///
/// Renders a string via CoreText/CoreGraphics into an IOSurface-backed BGRA
/// buffer and emits it at the configured fps. Re-renders only when the content
/// changes (text, counter, style) — otherwise the timer re-emits the cached
/// buffer with a fresh house-time PTS. The `{time}` token forces a re-render
/// every tick so the clock stays live.
///
/// Thread model: create/`start()`/`stop()` from one control thread. Mutators
/// (`setText`, `setCounter`, `increment`, `setStyle`) are safe from any thread.
/// `onFrame` fires on the source's serial queue.
public final class TextSource: TimedVideoSource {
    public enum HorizontalAlignment: Sendable { case left, center, right
        var ct: CTTextAlignment {
            switch self { case .left: return .left; case .center: return .center; case .right: return .right }
        }
    }
    public enum VerticalAlignment: Sendable { case top, center, bottom }

    public enum FontWeight: Sendable {
        case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black
        /// CoreText weight trait (−1…1), matching Apple's SF weight mapping.
        var trait: CGFloat {
            switch self {
            case .ultraLight: return -0.8
            case .thin:       return -0.6
            case .light:      return -0.4
            case .regular:    return  0.0
            case .medium:     return  0.23
            case .semibold:   return  0.3
            case .bold:       return  0.4
            case .heavy:      return  0.56
            case .black:      return  0.62
            }
        }
    }

    /// Immutable-at-init visual style; mutate live via `setStyle`.
    public struct Style: Sendable {
        /// Font family/PostScript name (e.g. "Helvetica Neue"); `nil` = SF system font.
        public var fontName: String?
        public var fontSize: Double
        public var weight: FontWeight
        public var color: RGBAColor
        public var horizontalAlignment: HorizontalAlignment
        public var verticalAlignment: VerticalAlignment
        /// Optional filled background (its `a` sets the opacity); `nil` = transparent.
        public var background: RGBAColor?
        /// Inset from the canvas edges, in pixels.
        public var padding: Double

        public init(fontName: String? = nil,
                    fontSize: Double = 72,
                    weight: FontWeight = .semibold,
                    color: RGBAColor = .white,
                    horizontalAlignment: HorizontalAlignment = .left,
                    verticalAlignment: VerticalAlignment = .center,
                    background: RGBAColor? = nil,
                    padding: Double = 24) {
            self.fontName = fontName
            self.fontSize = fontSize
            self.weight = weight
            self.color = color
            self.horizontalAlignment = horizontalAlignment
            self.verticalAlignment = verticalAlignment
            self.background = background
            self.padding = padding
        }
    }

    private let log = EngineLog.logger("sources.text")
    private let canvas: SourceRenderCanvas

    // All mutable content lives under one lock (mutators race the timer tick).
    private struct Content {
        var text: String
        var counter: Int
        var variables: [String: String]
        var style: Style
        var timeFormat: String
        var dirty: Bool = true
        /// Bumped on every mutation. `tick()` captures it before rendering and
        /// only clears `dirty` if it is unchanged afterward, so a `setText`/
        /// `setStyle`/… that lands *during* a render is not lost (F4).
        var generation: UInt64 = 0
        var cached: PixelBox?
        var lastResolved: String?

        // MARK: Animated reveal (nil style = classic static render)
        /// When non-nil, the text animates in with this reveal; nil = full static.
        var revealStyle: TextRevealStyle?
        /// Seconds over which `progress` sweeps 0→1.
        var revealDuration: Double = 1.2
        /// House-clock seconds at which the reveal was cued; `nil` = cue on the
        /// next tick (a fresh `cue()`/style change re-arms the animation).
        var cueHostSeconds: Double?
        /// Set once the reveal has reached progress 1 and the settled frame is
        /// cached, so subsequent ticks re-emit the still instead of re-rendering.
        var settledRendered: Bool = false
    }
    private let lock: OSAllocatedUnfairLock<Content>
    private let formatter = DateFormatter()

    /// - Parameters:
    ///   - text: template string; supports `{time}`, `{counter}` and any
    ///     `{key}` present in `variables`.
    ///   - canvasSize: output dimensions.
    ///   - fps: emit rate (a still title is cheap; 30 is plenty).
    ///   - timeFormat: `DateFormatter` pattern for `{time}` (default `HH:mm:ss`).
    public init(id: SourceID = SourceID("text.\(UUID().uuidString)"),
                text: String,
                style: Style = Style(),
                canvasSize: CanvasSize = .hd,
                variables: [String: String] = [:],
                counter: Int = 0,
                timeFormat: String = "HH:mm:ss",
                fps: Double = 30,
                revealStyle: TextRevealStyle? = nil,
                revealDuration: Double = 1.2) throws {
        self.canvas = try SourceRenderCanvas(size: canvasSize)
        var initial = Content(text: text, counter: counter, variables: variables,
                              style: style, timeFormat: timeFormat)
        initial.revealStyle = revealStyle
        initial.revealDuration = max(revealDuration, 0.0001)
        self.lock = OSAllocatedUnfairLock(initialState: initial)
        super.init(id: id, fps: fps, label: "studio.prism.source.text")
    }

    // MARK: - Live mutation

    public func setText(_ text: String) {
        lock.withLock { $0.text = text; $0.dirty = true; $0.generation &+= 1 }
    }
    public func setStyle(_ style: Style) {
        lock.withLock { $0.style = style; $0.dirty = true; $0.generation &+= 1 }
    }
    public func setCounter(_ value: Int) {
        lock.withLock { $0.counter = value; $0.dirty = true; $0.generation &+= 1 }
    }
    /// Increment the `{counter}` variable (default +1).
    public func increment(by delta: Int = 1) {
        lock.withLock { $0.counter += delta; $0.dirty = true; $0.generation &+= 1 }
    }
    public func setVariable(_ key: String, _ value: String) {
        lock.withLock { $0.variables[key] = value; $0.dirty = true; $0.generation &+= 1 }
    }

    // MARK: - Animated reveal

    /// The active reveal animation (`nil` = classic full static text). Setting a
    /// value (re-)arms the animation: the text sweeps in over `revealDuration`
    /// from the next tick. Setting `nil` restores the static render.
    public var revealStyle: TextRevealStyle? {
        get { lock.withLock { $0.revealStyle } }
        set {
            lock.withLock {
                $0.revealStyle = newValue
                $0.cueHostSeconds = nil       // re-cue from the next tick
                $0.settledRendered = false
                $0.dirty = true
                $0.generation &+= 1
            }
        }
    }

    /// Seconds over which the reveal `progress` sweeps 0→1.
    public var revealDuration: Double {
        get { lock.withLock { $0.revealDuration } }
        set {
            lock.withLock {
                $0.revealDuration = max(newValue, 0.0001)
                $0.settledRendered = false
                $0.dirty = true
                $0.generation &+= 1
            }
        }
    }

    /// Replay the reveal from the start (re-arms `progress` to 0 on the next
    /// tick). No-op visually if `revealStyle == nil`.
    public func cue() {
        lock.withLock {
            $0.cueHostSeconds = nil
            $0.settledRendered = false
            $0.dirty = true
            $0.generation &+= 1
        }
    }

    /// The current substituted string (for tests / UI preview).
    public func resolvedText() -> String {
        lock.withLock { resolve($0) }
    }

    // MARK: - Rendering

    private func resolve(_ c: Content) -> String {
        var out = c.text
        if out.contains("{time}") {
            formatter.dateFormat = c.timeFormat
            out = out.replacingOccurrences(of: "{time}", with: formatter.string(from: Date()))
        }
        if out.contains("{counter}") {
            out = out.replacingOccurrences(of: "{counter}", with: String(c.counter))
        }
        for (k, v) in c.variables {
            out = out.replacingOccurrences(of: "{\(k)}", with: v)
        }
        return out
    }

    /// One tick's render plan, decided under the lock.
    private struct TickPlan {
        var needsRender: Bool
        var resolved: String
        var style: Style
        var gen: UInt64
        /// Non-nil while the reveal animates; drives the per-unit render. `nil`
        /// once settled (progress 1) or when no reveal is configured.
        var reveal: (style: TextRevealStyle, progress: Double)?
    }

    override func tick() {
        // Decide under lock; render outside; publish cache under lock.
        let plan: TickPlan = lock.withLock { (c: inout Content) in
            let hasTime = c.text.contains("{time}")
            let resolved = resolve(c)
            let contentChanged = c.dirty || resolved != c.lastResolved || c.cached == nil

            guard let rs = c.revealStyle else {
                return TickPlan(needsRender: contentChanged || hasTime,
                                resolved: resolved, style: c.style,
                                gen: c.generation, reveal: nil)
            }

            // Reveal mode: progress = clamp(elapsedSinceCue / duration, 0…1),
            // paced off the house clock (never Date/rand).
            if c.cueHostSeconds == nil { c.cueHostSeconds = HouseClock.nowSeconds() }
            let elapsed = HouseClock.nowSeconds() - (c.cueHostSeconds ?? 0)
            let progress = min(max(elapsed / max(c.revealDuration, 0.0001), 0), 1)

            if progress < 1 {
                // Still animating: re-render every tick.
                return TickPlan(needsRender: true, resolved: resolved, style: c.style,
                                gen: c.generation, reveal: (rs, progress))
            }
            // Settled: render the full string once, then re-emit the still.
            if contentChanged || !c.settledRendered {
                return TickPlan(needsRender: true, resolved: resolved, style: c.style,
                                gen: c.generation, reveal: (rs, 1))
            }
            return TickPlan(needsRender: false, resolved: resolved, style: c.style,
                            gen: c.generation, reveal: nil)
        }

        if !plan.needsRender, let cached = lock.withLock({ $0.cached }) {
            emit(cached.buffer)
            return
        }

        do {
            let buffer: CVPixelBuffer
            if let reveal = plan.reveal {
                buffer = try renderReveal(resolved: plan.resolved, style: plan.style,
                                          progress: reveal.progress, revealStyle: reveal.style)
            } else {
                buffer = try render(resolved: plan.resolved, style: plan.style)
            }
            let box = PixelBox(buffer: buffer)
            lock.withLock {
                $0.cached = box
                $0.lastResolved = plan.resolved
                // Mark the settled still as cached once we render progress 1 so
                // later ticks re-emit it instead of re-rendering.
                if let reveal = plan.reveal, reveal.progress >= 1 { $0.settledRendered = true }
                // Compare-and-clear: only mark clean if no mutation landed while
                // we were rendering; otherwise leave `dirty` set so the next tick
                // re-renders the newer content (F4 lost-update fix).
                if $0.generation == plan.gen { $0.dirty = false }
            }
            emit(buffer)
        } catch {
            log.error("text render failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func render(resolved: String, style: Style) throws -> CVPixelBuffer {
        let font = Self.makeFont(style)
        return try canvas.render { ctx in
            if let bg = style.background {
                ctx.setFillColor(bg.cgColor)
                ctx.fill(canvas.canvasRect)
            }

            var alignment = style.horizontalAlignment.ct
            // The setting copies `valueSize` bytes from `value` during
            // CTParagraphStyleCreate, so the pointer only needs to outlive that
            // call — bind it to a scoped buffer instead of a temporary `&`.
            let paragraph = withUnsafeBytes(of: &alignment) { raw -> CTParagraphStyle in
                let setting = CTParagraphStyleSetting(
                    spec: .alignment,
                    valueSize: MemoryLayout<CTTextAlignment>.size,
                    value: raw.baseAddress!)
                return CTParagraphStyleCreate([setting], 1)
            }

            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.color.cgColor,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
            ]
            let attributed = NSAttributedString(string: resolved, attributes: attrs)
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)

            let pad = CGFloat(style.padding)
            let maxW = CGFloat(canvas.width) - 2 * pad
            let maxH = CGFloat(canvas.height) - 2 * pad
            let fit = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRangeMake(0, 0), nil,
                CGSize(width: maxW, height: .greatestFiniteMagnitude), nil)
            let textH = min(ceil(fit.height), maxH)

            // Position the text box vertically (context is bottom-left origin).
            let originY: CGFloat
            switch style.verticalAlignment {
            case .top:    originY = CGFloat(canvas.height) - pad - textH
            case .center: originY = (CGFloat(canvas.height) - textH) / 2
            case .bottom: originY = pad
            }
            let textRect = CGRect(x: pad, y: originY, width: maxW, height: textH)
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
            CTFrameDraw(frame, ctx)
        }
    }

    // MARK: - Animated reveal rendering

    /// UTF-16 span (within `full`) of each reveal unit, in unit order — chars for
    /// `typewriter`, whitespace-omitting words for the word styles. Matches
    /// `TextReveal`'s own splitting so `ranges[i]` aligns with `units[i]`.
    private static func unitRanges(_ full: String, style: TextRevealStyle) -> [(start: Int, end: Int)] {
        var ranges: [(start: Int, end: Int)] = []
        switch style {
        case .typewriter:
            var idx = 0
            for ch in full {
                let len = String(ch).utf16.count
                ranges.append((idx, idx + len))
                idx += len
            }
        case .wordByWord, .bounceInWord:
            // Non-empty runs between single spaces (== split(" ", omittingEmpty)).
            var idx = 0
            var wordStart = -1
            for ch in full {
                let len = String(ch).utf16.count
                if ch == " " {
                    if wordStart >= 0 { ranges.append((wordStart, idx)); wordStart = -1 }
                } else if wordStart < 0 {
                    wordStart = idx
                }
                idx += len
            }
            if wordStart >= 0 { ranges.append((wordStart, idx)) }
        }
        return ranges
    }

    /// Render `resolved` with `revealStyle` applied at `progress`, drawing ONLY
    /// the visible units — each with its per-unit alpha / slide-offset / scale.
    ///
    /// F18: the layout is driven off the SAME `CTFramesetter` the static `render`
    /// uses, so the reveal wraps across the ACTUAL multi-line layout instead of
    /// collapsing to one baseline (long/multiline titles no longer clip). Each
    /// reveal unit is positioned on the wrapped line it belongs to, using the
    /// frame's own line origins + `CTLineGetOffsetForStringIndex` — the original
    /// string ranges, so inter-word/leading/repeated whitespace is honoured
    /// exactly. At `progress >= 1` we draw the settled string through the static
    /// `render` path, so **progress 1 == the static multi-line render** (the
    /// public contract). Transparent premultiplied overlay, upright, IOSurface.
    private func renderReveal(resolved: String, style: Style,
                              progress: Double, revealStyle: TextRevealStyle) throws -> CVPixelBuffer {
        // Settled: identical to the static render (multi-line wrap + exact
        // whitespace). This is the F18 progress-1 == static guarantee.
        if progress >= 1 { return try render(resolved: resolved, style: style) }

        let result = TextReveal.reveal(resolved, progress: progress, style: revealStyle)
        let ranges = Self.unitRanges(resolved, style: revealStyle)
        let font = Self.makeFont(style)

        // Same paragraph style + attributes the static render lays out with, so the
        // framesetter wraps the reveal to the identical set of lines.
        var alignment = style.horizontalAlignment.ct
        let paragraph = withUnsafeBytes(of: &alignment) { raw -> CTParagraphStyle in
            let setting = CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size,
                value: raw.baseAddress!)
            return CTParagraphStyleCreate([setting], 1)
        }
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.color.cgColor,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ]

        return try canvas.render { ctx in
            if let bg = style.background {
                ctx.setFillColor(bg.cgColor)
                ctx.fill(canvas.canvasRect)
            }
            guard !resolved.isEmpty else { return }

            // Build the SAME wrapped frame the static render uses (identical
            // framesetter, constraints and text rect) so the reveal lands on the
            // real multi-line layout.
            let attributed = NSAttributedString(string: resolved, attributes: attrs)
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let pad = CGFloat(style.padding)
            let maxW = CGFloat(canvas.width) - 2 * pad
            let maxH = CGFloat(canvas.height) - 2 * pad
            let fit = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRangeMake(0, 0), nil,
                CGSize(width: maxW, height: .greatestFiniteMagnitude), nil)
            let textH = min(ceil(fit.height), maxH)
            let originY: CGFloat
            switch style.verticalAlignment {
            case .top:    originY = CGFloat(canvas.height) - pad - textH
            case .center: originY = (CGFloat(canvas.height) - textH) / 2
            case .bottom: originY = pad
            }
            let textRect = CGRect(x: pad, y: originY, width: maxW, height: textH)
            let path = CGPath(rect: textRect, transform: nil)
            let ctFrame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
            guard let lines = CTFrameGetLines(ctFrame) as? [CTLine], !lines.isEmpty else { return }
            var lineOrigins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(ctFrame, CFRangeMake(0, 0), &lineOrigins)

            let ns = resolved as NSString

            for (i, unit) in result.units.enumerated() where unit.isVisible {
                guard i < ranges.count else { break }
                let r = ranges[i]   // UTF-16 [start,end) in the ORIGINAL string

                // A reveal unit (a word) can straddle a HARD newline — e.g.
                // "AAA\nBBB" wraps onto two lines. Draw the unit's glyphs on EVERY
                // wrapped line its range intersects, not only the line it begins
                // on: clipping to the first line silently dropped the later-line
                // glyphs ("BBB") until the progress-1 static shortcut (F18). Each
                // per-line segment carries the unit's own alpha / slide / scale.
                for (lineIndex, line) in lines.enumerated() {
                    let sr = CTLineGetStringRange(line)
                    let startIdx = max(r.start, sr.location)
                    let endIdx = min(r.end, sr.location + sr.length)
                    guard endIdx > startIdx else { continue }

                    var la: CGFloat = 0, ld: CGFloat = 0, ll: CGFloat = 0
                    CTLineGetTypographicBounds(line, &la, &ld, &ll)
                    let xStart = CTLineGetOffsetForStringIndex(line, startIdx, nil)
                    let xEnd = CTLineGetOffsetForStringIndex(line, endIdx, nil)
                    let unitW = xEnd - xStart
                    let unitH = la + ld
                    // Line origin is relative to the frame path rect's origin.
                    let baseX = textRect.minX + lineOrigins[lineIndex].x + xStart
                    let baseY = textRect.minY + lineOrigins[lineIndex].y

                    // Slide: offsetX is a fraction of unit width; offsetY (>0 =
                    // below, per TextReveal) is a fraction of unit height →
                    // downward here (bottom-left origin) is negative y.
                    let dx = CGFloat(unit.offsetX) * unitW
                    let dy = -CGFloat(unit.offsetY) * unitH
                    let cx = baseX + unitW / 2
                    let cy = baseY + (la - ld) / 2   // glyph vertical center

                    let sub = ns.substring(with: NSRange(location: startIdx, length: endIdx - startIdx))
                    let unitLine = CTLineCreateWithAttributedString(
                        NSAttributedString(string: sub, attributes: attrs))
                    ctx.saveGState()
                    ctx.setAlpha(CGFloat(unit.alpha))
                    // Scale about the unit center, then apply the slide offset.
                    ctx.translateBy(x: cx + dx, y: cy + dy)
                    ctx.scaleBy(x: CGFloat(unit.scale), y: CGFloat(unit.scale))
                    ctx.translateBy(x: -cx, y: -cy)
                    ctx.textPosition = CGPoint(x: baseX, y: baseY)
                    CTLineDraw(unitLine, ctx)
                    ctx.restoreGState()
                }
            }
        }
    }

    #if DEBUG
    /// TEST HOOK: deterministically render the current text/style with the given
    /// reveal `style` at an explicit `progress` (no clock, no Date/rand). Returns
    /// the IOSurface-backed BGRA buffer for pixel readback.
    public func _test_renderReveal(progress: Double, style revealStyle: TextRevealStyle) throws -> CVPixelBuffer {
        let (resolved, style) = lock.withLock { (resolve($0), $0.style) }
        return try renderReveal(resolved: resolved, style: style,
                                progress: progress, revealStyle: revealStyle)
    }

    /// TEST HOOK: the classic static (non-reveal) render, for a reference frame.
    public func _test_renderStatic() throws -> CVPixelBuffer {
        let (resolved, style) = lock.withLock { (resolve($0), $0.style) }
        return try render(resolved: resolved, style: style)
    }
    #endif

    private static func makeFont(_ style: Style) -> CTFont {
        let traits: [CFString: Any] = [kCTFontWeightTrait: style.weight.trait]
        var attrs: [CFString: Any] = [
            kCTFontSizeAttribute: style.fontSize,
            kCTFontTraitsAttribute: traits,
        ]
        if let name = style.fontName {
            attrs[kCTFontNameAttribute] = name
        } else {
            // System (SF) family; CoreText substitutes a fallback if unavailable.
            attrs[kCTFontFamilyNameAttribute] = ".AppleSystemUIFont"
        }
        let desc = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
        return CTFontCreateWithFontDescriptor(desc, CGFloat(style.fontSize), nil)
    }
}
