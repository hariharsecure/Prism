import CoreVideo
import XCTest

import PrismCompositor
import PrismCore
import PrismSources

/// Verification for `TextSource`'s animated reveal (typewriter / word-by-word /
/// bounce-in), wiring the `PrismCompositor.TextReveal` engine into the text
/// source so its string animates in.
///
/// All checks are DETERMINISTIC — they render explicit `progress` values through
/// the `_test_renderReveal` hook (no house clock, no `Date`, no RNG). Asserts:
///  - progress ~0: few/no glyphs painted (painted-pixel count low),
///  - mid-reveal: a partial set (0 < painted < full),
///  - progress 1: the full string, painted count within tolerance of a plain
///    statically-rendered reference frame,
///  - typewriter reveals LEFT→RIGHT (rightmost region empty early, fills by end).
///
/// A PNG sequence (typewriter @ 0 / 0.3 / 0.6 / 1.0 and word-by-word) is dumped
/// for the lead to eyeball to:
///   /tmp/prism_textreveal_src/
final class TextRevealSourceTests: XCTestCase {

    private static let outputDir = URL(fileURLWithPath:
        "/tmp/prism_textreveal_src")

    private let W = 640, H = 200

    // MARK: - Painted-pixel readback (locks base address once)

    /// Count pixels whose alpha exceeds `thresh` within an x-range (memory/top
    /// origin coords) — the inked-glyph count of a transparent overlay.
    private func paintedCount(_ buffer: CVPixelBuffer, xRange: Range<Int>? = nil,
                              alphaThresh: Int = 40, step: Int = 1) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let x0 = max(0, xRange?.lowerBound ?? 0), x1 = min(w, xRange?.upperBound ?? w)
        var count = 0, y = 0
        while y < h {
            var x = x0
            while x < x1 {
                if Int(base[y * bpr + x * 4 + 3]) > alphaThresh { count += 1 }
                x += step
            }
            y += step
        }
        return count
    }

    private func makeSource(_ text: String = "HELLO WORLD",
                            align: TextSource.HorizontalAlignment = .left) throws -> TextSource {
        // Transparent overlay (no background) so alpha == inked glyphs.
        let style = TextSource.Style(fontSize: 56, weight: .bold, color: .white,
                                     horizontalAlignment: align, verticalAlignment: .center)
        return try TextSource(id: SourceID("test.text.reveal"), text: text, style: style,
                              canvasSize: CanvasSize(width: W, height: H), fps: 30)
    }

    // MARK: - Tests

    func testTypewriterProgressPaintsMoreOverTime() throws {
        let src = try makeSource()
        let p0 = paintedCount(try src._test_renderReveal(progress: 0, style: .typewriter))
        let p03 = paintedCount(try src._test_renderReveal(progress: 0.3, style: .typewriter))
        let p06 = paintedCount(try src._test_renderReveal(progress: 0.6, style: .typewriter))
        let p1 = paintedCount(try src._test_renderReveal(progress: 1, style: .typewriter))

        XCTAssertLessThanOrEqual(p0, 8, "progress 0 should paint ~no glyphs (got \(p0))")
        XCTAssertGreaterThan(p03, p0, "0.3 should paint more than 0")
        XCTAssertGreaterThan(p06, p03, "0.6 should paint more than 0.3")
        XCTAssertGreaterThan(p1, p06, "1.0 should paint more than 0.6")
        XCTAssertGreaterThan(p1, 0)
    }

    func testProgressOneMatchesStaticReference() throws {
        let src = try makeSource()
        let p1 = paintedCount(try src._test_renderReveal(progress: 1, style: .typewriter))
        let ref = paintedCount(try src._test_renderStatic())
        // Single-line reveal vs. framesetter static differ only by kerning/layout;
        // the inked area must match within tolerance.
        let tol = Double(ref) * 0.30
        XCTAssertEqual(Double(p1), Double(ref), accuracy: tol,
                       "progress-1 painted \(p1) should be within 30% of static ref \(ref)")
    }

    /// Rightmost painted column (memory x), or -1 if nothing painted.
    private func rightmostPaintedX(_ buffer: CVPixelBuffer, alphaThresh: Int = 40) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var maxX = -1, y = 0
        while y < h {
            var x = w - 1
            while x > maxX {
                if Int(base[y * bpr + x * 4 + 3]) > alphaThresh { maxX = x; break }
                x -= 1
            }
            y += 1
        }
        return maxX
    }

    func testTypewriterRevealsLeftToRight() throws {
        let src = try makeSource(align: .left)
        // Left→right: the inked region's right edge advances with progress. The
        // rightmost painted column early must be strictly left of the settled one.
        let rEarly = rightmostPaintedX(try src._test_renderReveal(progress: 0.25, style: .typewriter))
        let rEnd = rightmostPaintedX(try src._test_renderReveal(progress: 1, style: .typewriter))
        XCTAssertGreaterThan(rEarly, 0, "some glyphs painted at 0.25")
        XCTAssertGreaterThan(rEnd, rEarly, "typewriter must fill left→right (right edge advances)")
    }

    func testMidRevealIsPartialUnitCount() throws {
        // ⌈p·N⌉ units visible: at p=0.5 of an 11-char string, ~6 chars in.
        let full = "HELLO WORLD"
        let mid = TextReveal.reveal(full, progress: 0.5, style: .typewriter)
        XCTAssertGreaterThan(mid.visibleCount, 0)
        XCTAssertLessThan(mid.visibleCount, full.count)
        XCTAssertEqual(mid.visibleCount, Int((0.5 * Double(full.count)).rounded(.up)))
    }

    func testWordByWordGrowsAndSettles() throws {
        let src = try makeSource()
        let wb0 = paintedCount(try src._test_renderReveal(progress: 0, style: .wordByWord))
        let wbMid = paintedCount(try src._test_renderReveal(progress: 0.5, style: .wordByWord))
        let wb1 = paintedCount(try src._test_renderReveal(progress: 1, style: .wordByWord))
        XCTAssertLessThanOrEqual(wb0, 8)
        XCTAssertGreaterThan(wbMid, wb0)
        XCTAssertGreaterThan(wb1, wbMid)
    }

    // MARK: - F18: multi-line reveal at progress 1 == static multi-line render

    /// Min/max painted row (memory-top origin) and the count of painted rows —
    /// the VERTICAL extent of the inked glyphs. A single-baseline (one CTLine)
    /// render occupies ~one line height; a wrapped multi-line render spans several.
    private func verticalExtent(_ buffer: CVPixelBuffer, alphaThresh: Int = 40) -> (minY: Int, maxY: Int, rows: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var minY = h, maxY = -1, rows = 0
        for y in 0..<h {
            var painted = false
            var x = 0
            while x < w { if Int(base[y * bpr + x * 4 + 3]) > alphaThresh { painted = true; break }; x += 1 }
            if painted { minY = min(minY, y); maxY = max(maxY, y); rows += 1 }
        }
        return (minY, maxY, rows)
    }

    private func makeMultilineSource() throws -> (TextSource, Double) {
        // Hard newlines guarantee THREE lines regardless of font metrics; the
        // pre-fix single-CTLine reveal collapses them onto one baseline.
        let fontSize = 40.0
        let style = TextSource.Style(fontSize: fontSize, weight: .bold, color: .white,
                                     horizontalAlignment: .left, verticalAlignment: .center)
        let src = try TextSource(id: SourceID("test.text.reveal.multiline"),
                                 text: "LINE ONE\nLINE TWO\nLINE THREE", style: style,
                                 canvasSize: CanvasSize(width: W, height: H), fps: 30)
        return (src, fontSize)
    }

    func testMultilineRevealProgressOneEqualsStatic() throws {
        let (src, fontSize) = try makeMultilineSource()
        let staticBuf = try src._test_renderStatic()
        let p1Buf = try src._test_renderReveal(progress: 1, style: .typewriter)

        let staticExt = verticalExtent(staticBuf)
        let p1Ext = verticalExtent(p1Buf)
        let staticCount = paintedCount(staticBuf)
        let p1Count = paintedCount(p1Buf)

        // Sanity: the STATIC render really is multi-line (spans well over one line).
        XCTAssertGreaterThan(staticExt.maxY - staticExt.minY, Int(fontSize * 2.2),
            "static render should wrap to multiple lines (extent \(staticExt.maxY - staticExt.minY)px)")

        // The reveal at progress 1 must span the SAME vertical extent (multi-line),
        // not collapse to one baseline. Pre-fix this is ~one line and fails.
        XCTAssertEqual(Double(p1Ext.maxY - p1Ext.minY), Double(staticExt.maxY - staticExt.minY), accuracy: fontSize * 0.5,
            "progress-1 reveal must span the multi-line extent, not one baseline (reveal \(p1Ext.maxY - p1Ext.minY)px vs static \(staticExt.maxY - staticExt.minY)px)")
        // And paint the same region (delegates to the static path at settle).
        XCTAssertEqual(Double(p1Count), Double(staticCount), accuracy: Double(staticCount) * 0.05,
            "progress-1 reveal painted \(p1Count) should match static \(staticCount)")
    }

    /// Painted-pixel count restricted to a memory-top-origin row band [y0, y1).
    private func paintedCountInRows(_ buffer: CVPixelBuffer, y0: Int, y1: Int,
                                    alphaThresh: Int = 40) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let yl = max(0, y0), yh = min(h, y1)
        var count = 0
        var y = yl
        while y < yh {
            var x = 0
            while x < w { if Int(base[y * bpr + x * 4 + 3]) > alphaThresh { count += 1 }; x += 1 }
            y += 1
        }
        return count
    }

    /// F18 REPRODUCTION — a word-reveal unit that straddles a HARD newline must
    /// paint its later-line glyphs mid-progress, not drop them.
    ///
    /// `"AAA\nBBB CCC"` splits (on spaces) into two reveal words: `"AAA\nBBB"`
    /// (which the framesetter wraps across line 1 = "AAA" and line 2 = "BBB") and
    /// `"CCC"`. At progress 0.4 only the FIRST word is revealed. The correct
    /// render paints "AAA" on line 1 AND "BBB" on line 2. The pre-fix reveal only
    /// draws the portion of the unit on the line it *starts* on (line 1), so "BBB"
    /// on line 2 is silently omitted until the progress-1 static shortcut. Oracle:
    /// the STATIC (full) render establishes where line 2 lives; the reveal must
    /// have inked pixels in that lower band. Pre-fix that band is empty → fails.
    func testWordRevealSpanningNewlineDoesNotDropLaterLine() throws {
        let H2 = 260
        let style = TextSource.Style(fontSize: 40, weight: .bold, color: .white,
                                     horizontalAlignment: .left, verticalAlignment: .center)
        let src = try TextSource(id: SourceID("test.text.reveal.newline-word"),
                                 text: "AAA\nBBB CCC", style: style,
                                 canvasSize: CanvasSize(width: W, height: H2), fps: 30)

        // Independent oracle: the static render tells us the two lines' extent.
        let staticExt = verticalExtent(try src._test_renderStatic())
        XCTAssertGreaterThan(staticExt.maxY - staticExt.minY, 40,
            "static render must genuinely span two lines (extent \(staticExt.maxY - staticExt.minY)px)")
        let mid = (staticExt.minY + staticExt.maxY) / 2   // splits line 1 / line 2

        // At p=0.4, exactly the first word ("AAA\nBBB") is revealed.
        let reveal = try src._test_renderReveal(progress: 0.4, style: .wordByWord)
        let lowerBandPaint = paintedCountInRows(reveal, y0: mid, y1: H2)

        XCTAssertGreaterThan(lowerBandPaint, 20,
            "the revealed word straddles a newline; its line-2 glyphs (\"BBB\") must be painted, not dropped (lower-band paint \(lowerBandPaint))")
    }

    /// F18 (REAL ORACLE) — `TextReveal.reveal(...)` word style must PRESERVE the
    /// original whitespace/layout of the string. This calls `reveal()` DIRECTLY
    /// and asserts on ITS `visibleString`, so the assertion cannot be satisfied by
    /// the renderer's `progress >= 1 → static render()` shortcut (which bypasses
    /// `reveal()` entirely — that is exactly how the old pixel-equality test was
    /// tautological). The independent oracle here is the ORIGINAL input string
    /// itself: at progress 1 the reveal must reproduce it byte-for-byte.
    func testWordRevealVisibleStringPreservesWhitespaceAtProgressOne() throws {
        // Leading (2) + interior repeated (2) spaces + a newline + trailing (2).
        // Old code split(" ")/join(" ") → "A B\nC" (collapsed). Must stay exact.
        let full = "  A  B\nC  "
        for style in [TextRevealStyle.wordByWord, .bounceInWord] {
            let r1 = TextReveal.reveal(full, progress: 1, style: style)
            XCTAssertEqual(r1.visibleString, full,
                "\(style): progress-1 word reveal must equal the ORIGINAL string byte-for-byte, " +
                "not a normalized token join (got \(r1.visibleString.debugDescription))")
        }
    }

    /// F18 (all-whitespace / empty edge) — `words()` splits on spaces with
    /// `omittingEmptySubsequences: true`, so a pure-whitespace or empty input has
    /// ZERO word units. The old guard returned `visibleString == ""`, which at
    /// progress 1 violated the public "== full string at progress 1" contract:
    /// `reveal("   ", 1, .word)` dropped the three spaces. With no word units every
    /// progress is trivially "all units revealed", so the visibleString must equal
    /// the ORIGINAL string exactly — including all-whitespace and empty. Oracle: the
    /// original input string itself (calls `reveal()` directly — no renderer
    /// shortcut, so this cannot be satisfied by the p>=1 static-render path).
    func testWordRevealAllWhitespaceOrEmptyEqualsOriginalAtProgressOne() throws {
        for full in ["   ", "", " A ", "\n", "  \t  ", " "] {
            for style in [TextRevealStyle.wordByWord, .bounceInWord] {
                let r1 = TextReveal.reveal(full, progress: 1, style: style)
                XCTAssertEqual(r1.visibleString, full,
                    "\(style): progress-1 reveal of \(full.debugDescription) must equal the ORIGINAL exactly " +
                    "(got \(r1.visibleString.debugDescription)) — all-whitespace/empty must not collapse to \"\"")
            }
        }
        // A string with NO word units also has no revealable content at ANY
        // progress, so it stays whole throughout (nothing to progressively reveal).
        for p in stride(from: 0.0, through: 1.0, by: 0.25) {
            let r = TextReveal.reveal("   ", progress: p, style: .wordByWord)
            XCTAssertEqual(r.visibleString, "   ",
                "all-whitespace reveal must stay whole at p=\(p) (got \(r.visibleString.debugDescription))")
            XCTAssertTrue(r.units.isEmpty, "all-whitespace input yields no reveal units")
        }
    }

    /// F18 (REAL ORACLE) — at an INTERMEDIATE progress the word reveal must (a)
    /// preserve the leading + interior whitespace of already-revealed content, (b)
    /// drop no already-revealed characters, and (c) be a monotonic growing PREFIX
    /// of the original string. Calls `reveal()` directly (no renderer shortcut).
    func testWordRevealVisibleStringIsMonotonicWhitespacePreservingPrefix() throws {
        let full = "  ONE  TWO   THREE  FOUR  "   // leading/interior/trailing runs
        var prev = ""
        for p in stride(from: 0.0, through: 1.0, by: 0.1) {
            let r = TextReveal.reveal(full, progress: p, style: .wordByWord)
            let vis = r.visibleString
            // (c) monotonic growing prefix of the ORIGINAL string.
            XCTAssertTrue(full.hasPrefix(vis),
                "visibleString must be a prefix of the original (p=\(p), got \(vis.debugDescription))")
            XCTAssertGreaterThanOrEqual(vis.count, prev.count,
                "reveal must be monotonic (p=\(p): \(vis.count) < \(prev.count))")
            XCTAssertTrue(vis.hasPrefix(prev),
                "each step must extend the previous prefix (p=\(p))")
            prev = vis
        }
        // (a) Once the first word is revealed, its LEADING whitespace is intact.
        let firstIn = TextReveal.reveal(full, progress: 0.3, style: .wordByWord)
        XCTAssertTrue(firstIn.visibleString.hasPrefix("  ONE"),
            "leading whitespace of revealed content must be intact (got \(firstIn.visibleString.debugDescription))")
        // (b) With ≥2 words revealed, the INTERIOR run between them is intact.
        let twoIn = TextReveal.reveal(full, progress: 0.5, style: .wordByWord)
        XCTAssertTrue(twoIn.visibleString.contains("ONE  TWO"),
            "interior repeated whitespace between revealed words must be intact (got \(twoIn.visibleString.debugDescription))")
    }

    /// The RENDER path also stays whole at progress 1 (multi-line + whitespace):
    /// the settled reveal frame equals the static framesetter layout. This is a
    /// legitimate render-level check (it verifies the p>=1 settle delegates to the
    /// static path) — distinct from the `reveal()` oracle above, which is what
    /// actually guards the whitespace contract.
    func testWordRevealRenderProgressOneEqualsStaticWithWhitespace() throws {
        let H2 = 260
        let style = TextSource.Style(fontSize: 40, weight: .bold, color: .white,
                                     horizontalAlignment: .left, verticalAlignment: .center)
        let src = try TextSource(id: SourceID("test.text.reveal.ws"),
                                 text: "  A  B\nC  ", style: style,
                                 canvasSize: CanvasSize(width: W, height: H2), fps: 30)
        let staticBuf = try src._test_renderStatic()
        let p1Buf = try src._test_renderReveal(progress: 1, style: .wordByWord)

        CVPixelBufferLockBaseAddress(staticBuf, .readOnly)
        CVPixelBufferLockBaseAddress(p1Buf, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(staticBuf, .readOnly)
            CVPixelBufferUnlockBaseAddress(p1Buf, .readOnly)
        }
        let w = CVPixelBufferGetWidth(staticBuf), h = CVPixelBufferGetHeight(staticBuf)
        let bprS = CVPixelBufferGetBytesPerRow(staticBuf), bprP = CVPixelBufferGetBytesPerRow(p1Buf)
        let bs = CVPixelBufferGetBaseAddress(staticBuf)!.assumingMemoryBound(to: UInt8.self)
        let bp = CVPixelBufferGetBaseAddress(p1Buf)!.assumingMemoryBound(to: UInt8.self)
        var mismatches = 0
        for y in 0..<h {
            for x in 0..<(w * 4) where bs[y * bprS + x] != bp[y * bprP + x] { mismatches += 1 }
        }
        XCTAssertEqual(mismatches, 0,
            "progress-1 word reveal must equal the static layout exactly (mismatched bytes \(mismatches))")
    }

    /// Dump the F18 proof (multiline reveal @1 vs static) into the lead's dir.
    func testDumpMultilineRevealProof() throws {
        let fontSize = 40.0
        let style = TextSource.Style(fontSize: fontSize, weight: .bold, color: .white,
                                     horizontalAlignment: .left, verticalAlignment: .center,
                                     background: RGBAColor(r: 0.06, g: 0.07, b: 0.12, a: 1))
        let src = try TextSource(id: SourceID("test.text.reveal.multiline.dump"),
                                 text: "LINE ONE\nLINE TWO\nLINE THREE", style: style,
                                 canvasSize: CanvasSize(width: W, height: H), fps: 30)
        let leadDir = URL(fileURLWithPath:
            "/tmp/prism_srcfix")
        try? FileManager.default.createDirectory(at: leadDir, withIntermediateDirectories: true)
        _ = try FXCanvas.writePNG(try src._test_renderStatic(),
                                  to: leadDir.appendingPathComponent("F18_multiline_static.png"))
        _ = try FXCanvas.writePNG(try src._test_renderReveal(progress: 1, style: .typewriter),
                                  to: leadDir.appendingPathComponent("F18_multiline_reveal_p1.png"))
        _ = try FXCanvas.writePNG(try src._test_renderReveal(progress: 0.6, style: .wordByWord),
                                  to: leadDir.appendingPathComponent("F18_multiline_reveal_p06_wordByWord.png"))
    }

    func testDeterministicAcrossRenders() throws {
        let src = try makeSource()
        let a = paintedCount(try src._test_renderReveal(progress: 0.4, style: .typewriter))
        let b = paintedCount(try src._test_renderReveal(progress: 0.4, style: .typewriter))
        XCTAssertEqual(a, b, "reveal render must be deterministic for a fixed progress")
    }

    func testBuffersAreIOSurfaceBackedBGRA() throws {
        let src = try makeSource()
        let buf = try src._test_renderReveal(progress: 0.5, style: .bounceInWord)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(buf), "reveal buffer must be IOSurface-backed")
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buf), kCVPixelFormatType_32BGRA)
    }

    // MARK: - PNG dump for eyeballing

    func testDumpRevealPNGSequence() throws {
        // Opaque dark backing so the white glyphs are legible in a PNG viewer
        // (the live overlay is transparent — verified separately above).
        let dumpStyle = TextSource.Style(fontSize: 56, weight: .bold, color: .white,
                                         horizontalAlignment: .left, verticalAlignment: .center,
                                         background: RGBAColor(r: 0.06, g: 0.07, b: 0.12, a: 1))
        let src = try TextSource(id: SourceID("test.text.reveal.dump"), text: "HELLO WORLD",
                                 style: dumpStyle,
                                 canvasSize: CanvasSize(width: W, height: H), fps: 30)
        for p in [0.0, 0.3, 0.6, 1.0] {
            let buf = try src._test_renderReveal(progress: p, style: .typewriter)
            _ = try FXCanvas.writePNG(buf, to: Self.outputDir.appendingPathComponent(
                String(format: "typewriter_%.2f.png", p)))
        }
        for p in [0.0, 0.3, 0.6, 1.0] {
            let buf = try src._test_renderReveal(progress: p, style: .wordByWord)
            _ = try FXCanvas.writePNG(buf, to: Self.outputDir.appendingPathComponent(
                String(format: "wordByWord_%.2f.png", p)))
        }
        for p in [0.3, 0.6] {
            let buf = try src._test_renderReveal(progress: p, style: .bounceInWord)
            _ = try FXCanvas.writePNG(buf, to: Self.outputDir.appendingPathComponent(
                String(format: "bounceInWord_%.2f.png", p)))
        }
    }
}
