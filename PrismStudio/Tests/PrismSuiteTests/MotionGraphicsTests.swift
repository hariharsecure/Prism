import CoreGraphics
import CoreVideo
import XCTest

import PrismCompositor
import PrismCore

/// Verification for the motion-graphics overlay pack (`MotionGraphics`) and the
/// full-frame `StrobeEffect`.
///
/// Asserts the overlays are IOSurface-backed BGRA at canvas size with a genuinely
/// TRANSPARENT background (alpha 0 outside the graphic — premultiplied-correct,
/// not opaque black), that graphic pixels land where the layout says, that the
/// entrance animation MOVES (off-screen at progress 0, on-screen by 1), that the
/// countdown shows different digits over time, and that the strobe is brightest
/// on the downbeat and returns to the source by the end of the beat.
///
/// PNG sequences (lower-third slide-in, countdown 3→2→1, subscribe pop, name-tag,
/// strobe phases) are dumped for the lead to eyeball to:
///   /tmp/prism_motiongfx/
final class MotionGraphicsTests: XCTestCase {

    private static let outputDir = URL(fileURLWithPath:
        "/tmp/prism_motiongfx")

    private let W = 640, H = 360

    // MARK: - Region readback helper (locks base address once)

    /// Opaque-pixel stats over a rect (memory / top-origin coords): count of
    /// pixels with alpha above `alphaThresh`, plus their centroid.
    private struct OpaqueStats { var count: Int; var cx: Double; var cy: Double }

    private func opaqueStats(_ buffer: CVPixelBuffer, rect: CGRect, alphaThresh: Double = 0.15,
                             step: Int = 2) -> OpaqueStats {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let x0 = max(0, Int(rect.minX)), x1 = min(w, Int(rect.maxX))
        let y0 = max(0, Int(rect.minY)), y1 = min(h, Int(rect.maxY))
        var count = 0, sx = 0.0, sy = 0.0
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                let a = Double((base + y * bpr + x * 4)[3]) / 255
                if a > alphaThresh { count += 1; sx += Double(x); sy += Double(y) }
                x += step
            }
            y += step
        }
        return count > 0 ? OpaqueStats(count: count, cx: sx / Double(count), cy: sy / Double(count))
                         : OpaqueStats(count: 0, cx: 0, cy: 0)
    }

    /// Max alpha over the whole frame (0 == fully transparent everywhere).
    private func maxAlpha(_ buffer: CVPixelBuffer, step: Int = 3) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var m = 0
        var y = 0
        while y < h {
            var x = 0
            while x < w { m = max(m, Int((base + y * bpr + x * 4)[3])); x += step }
            y += step
        }
        return Double(m) / 255
    }

    private func assertBGRACanvas(_ buffer: CVPixelBuffer, _ msg: String = "") {
        XCTAssertNotNil(CVPixelBufferGetIOSurface(buffer), "IOSurface-backed \(msg)")
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_32BGRA, "BGRA \(msg)")
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), W, "width \(msg)")
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), H, "height \(msg)")
    }

    // MARK: - Lower-third: transparent bg + positioned graphic

    func testLowerThirdTransparentAndPositioned() throws {
        let mg = try MotionGraphics(width: W, height: H)
        let frame = try mg.lowerThird(name: "AVERY CHEN", subtitle: "Field Correspondent",
                                      corner: .bottomLeft, progress: 1.0)
        assertBGRACanvas(frame, "lower-third")

        // Outside the bar (top half) must be fully transparent (premultiplied
        // alpha correct — NOT opaque black).
        let top = opaqueStats(frame, rect: CGRect(x: 0, y: 0, width: W, height: H / 3))
        XCTAssertEqual(top.count, 0, "top third is transparent (no opaque box)")

        // The bar sits in the lower-left: opaque pixels present and centroid there.
        let lower = opaqueStats(frame, rect: CGRect(x: 0, y: H * 2 / 3, width: W, height: H / 3))
        XCTAssertGreaterThan(lower.count, 200, "lower-third bar pixels present")
        XCTAssertLessThan(lower.cx, Double(W) * 0.6, "bar is anchored left")
        XCTAssertGreaterThan(lower.cy, Double(H) * 0.6, "bar is anchored to the bottom")
    }

    // MARK: - Lower-third: entrance MOVES (off at 0, on by 1)

    func testLowerThirdEntranceMoves() throws {
        let mg = try MotionGraphics(width: W, height: H)
        let off = try mg.lowerThird(name: "AVERY CHEN", subtitle: "Live", corner: .bottomLeft, progress: 0.0)
        let mid = try mg.lowerThird(name: "AVERY CHEN", subtitle: "Live", corner: .bottomLeft, progress: 0.5)
        let rest = try mg.lowerThird(name: "AVERY CHEN", subtitle: "Live", corner: .bottomLeft, progress: 1.0)

        // At progress 0 the whole canvas is transparent (fully off-screen + faded).
        XCTAssertLessThan(maxAlpha(off), 0.02, "off-screen at progress 0")

        // Mid-entrance the graphic is on-screen.
        let barBand = CGRect(x: 0, y: H * 2 / 3, width: W, height: H / 3)
        XCTAssertGreaterThan(opaqueStats(mid, rect: barBand).count, 100, "on-screen mid-entrance")

        // The animation genuinely moves the pixels across progress.
        XCTAssertGreaterThan(FXCanvas.meanDiff(off, rest), 0.01, "entrance moves 0→1")
        XCTAssertGreaterThan(FXCanvas.meanDiff(mid, rest), 0.005, "still sliding at 0.5")

        // Sliding in from the LEFT: bar centroid at 0.5 is left of its rest x.
        let cxMid = opaqueStats(mid, rect: barBand).cx
        let cxRest = opaqueStats(rest, rect: barBand).cx
        XCTAssertLessThan(cxMid, cxRest, "bar slides in from the left")
    }

    // MARK: - Name-tag pill

    func testNameTagRendersPill() throws {
        let mg = try MotionGraphics(width: W, height: H)
        let frame = try mg.nameTag(name: "DR. RAO", corner: .topRight, progress: 1.0)
        assertBGRACanvas(frame, "name-tag")
        // Pill anchored top-right; opposite corner (bottom-left) transparent.
        XCTAssertEqual(opaqueStats(frame, rect: CGRect(x: 0, y: H * 2 / 3, width: W / 3, height: H / 3)).count, 0,
                       "bottom-left transparent")
        let tr = opaqueStats(frame, rect: CGRect(x: W / 2, y: 0, width: W / 2, height: H / 2))
        XCTAssertGreaterThan(tr.count, 100, "pill pixels present top-right")
        XCTAssertGreaterThan(tr.cx, Double(W) * 0.5, "pill anchored right")
        XCTAssertLessThan(tr.cy, Double(H) * 0.5, "pill anchored top")

        // Pop-in: invisible at progress 0.
        let pop0 = try mg.nameTag(name: "DR. RAO", corner: .topRight, progress: 0.0)
        XCTAssertLessThan(maxAlpha(pop0), 0.02, "name-tag invisible at progress 0")
    }

    // MARK: - Countdown: different digits + tick animation

    func testCountdownDigitsAndTick() throws {
        let mg = try MotionGraphics(width: W, height: H)
        let three = try mg.countdown(secondsRemaining: 3, tickProgress: 0.5)
        let two = try mg.countdown(secondsRemaining: 2, tickProgress: 0.5)
        let one = try mg.countdown(secondsRemaining: 1, tickProgress: 0.5)
        assertBGRACanvas(three, "countdown")

        // Different digits → different pixels.
        XCTAssertGreaterThan(FXCanvas.meanDiff(three, two), 0.003, "3 vs 2 differ")
        XCTAssertGreaterThan(FXCanvas.meanDiff(two, one), 0.003, "2 vs 1 differ")

        // The number is centered.
        let discR = 0.30 * Double(H)
        let ctr = opaqueStats(three, rect: CGRect(x: 0, y: 0, width: W, height: H))
        XCTAssertLessThan(abs(ctr.cx - Double(W) / 2), Double(W) * 0.06, "countdown centered X")
        XCTAssertLessThan(abs(ctr.cy - Double(H) / 2), Double(H) * 0.06, "countdown centered Y")
        // Corner well outside the disc is transparent.
        XCTAssertLessThan(Double(discR), Double(H) / 2)   // sanity: disc fits
        XCTAssertEqual(opaqueStats(three, rect: CGRect(x: 0, y: 0, width: 40, height: 40)).count, 0,
                       "corner transparent")

        // Tick animation moves (digit pops across the second).
        let tickA = try mg.countdown(secondsRemaining: 3, tickProgress: 0.0)
        let tickB = try mg.countdown(secondsRemaining: 3, tickProgress: 0.85)
        XCTAssertGreaterThan(FXCanvas.meanDiff(tickA, tickB), 0.002, "tick animation moves")
    }

    // MARK: - CTA / subscribe bug

    func testCtaBugPops() throws {
        let mg = try MotionGraphics(width: W, height: H)
        let pop0 = try mg.ctaBug(corner: .bottomRight, progress: 0.0)
        let pop1 = try mg.ctaBug(corner: .bottomRight, progress: 1.0)
        assertBGRACanvas(pop1, "cta")
        XCTAssertLessThan(maxAlpha(pop0), 0.02, "CTA invisible at progress 0")
        let br = opaqueStats(pop1, rect: CGRect(x: W / 2, y: H / 2, width: W / 2, height: H / 2))
        XCTAssertGreaterThan(br.count, 100, "CTA badge pixels present bottom-right")
        XCTAssertGreaterThan(br.cx, Double(W) * 0.5, "CTA anchored right")
        XCTAssertGreaterThan(br.cy, Double(H) * 0.5, "CTA anchored bottom")
        // It grows during the pop.
        let half = try mg.ctaBug(corner: .bottomRight, progress: 0.5)
        XCTAssertGreaterThan(FXCanvas.meanDiff(pop1, half), 0.001, "CTA pop moves")
    }

    // MARK: - Strobe: envelope + brightness

    func testStrobeEnvelopeAndBrightness() throws {
        let strobe = try StrobeEffect(width: W, height: H)

        // Envelope: peak on the downbeat, decays to ~0 by the next beat.
        let a0 = strobe.flashAmount(phase: 0, intensity: 0.9)
        let a9 = strobe.flashAmount(phase: 0.9, intensity: 0.9)
        let aEnd = strobe.flashAmount(phase: 0.99, intensity: 0.9)
        XCTAssertGreaterThan(a0, a9, "flash peaks on the downbeat")
        XCTAssertGreaterThan(a9, aEnd, "flash decays across the beat")
        XCTAssertLessThan(aEnd, 0.01, "flash ~0 by the end of the beat")
        // Clamped 0…1.
        XCTAssertLessThanOrEqual(strobe.flashAmount(phase: 0, intensity: 999), 1.0, "flash clamped")
        XCTAssertEqual(strobe.flashAmount(phase: 0, intensity: -5), 0, "negative intensity → no flash")

        // Render: a mid-gray source flashes brighter (toward white) on the beat.
        let canvas = try FXCanvas(width: W, height: H)
        let source = try canvas.solid(RGBA(r: 0.4, g: 0.4, b: 0.4))
        let onBeat = try strobe.apply(to: source, phase: 0, intensity: 0.9, color: .white)
        let between = try strobe.apply(to: source, phase: 0.9, intensity: 0.9, color: .white)
        let returned = try strobe.apply(to: source, phase: 0.99, intensity: 0.9, color: .white)
        assertBGRACanvas(onBeat, "strobe")

        XCTAssertGreaterThan(FXCanvas.meanLuma(onBeat), FXCanvas.meanLuma(between),
                             "brighter on the downbeat than between")
        XCTAssertGreaterThan(FXCanvas.meanLuma(between), FXCanvas.meanLuma(source, step: 16) - 0.01,
                             "still ≥ source between beats")
        // Returns to the source by the end of the beat.
        XCTAssertLessThan(FXCanvas.meanDiff(returned, source), 0.01, "returns to source by beat end")
        XCTAssertGreaterThan(FXCanvas.meanDiff(onBeat, source), 0.1, "clearly flashed on the beat")

        // Color flash: a red flash pushes the frame toward red, not white.
        let redFlash = try strobe.apply(to: source, phase: 0, intensity: 1.0,
                                        color: RGBA(r: 1, g: 0, b: 0))
        let px = FXCanvas.pixel(redFlash, x: W / 2, y: H / 2)
        XCTAssertGreaterThan(px.r, px.g, "red flash is redder than green")
        XCTAssertGreaterThan(px.r, px.b, "red flash is redder than blue")
    }

    // MARK: - PNG dumps (eyeball)

    func testDumpPNGSequences() throws {
        try? FileManager.default.createDirectory(at: Self.outputDir, withIntermediateDirectories: true)
        let mg = try MotionGraphics(width: W, height: H)

        // Lower-third slide-in.
        for p in [0.0, 0.3, 0.6, 1.0] {
            let f = try mg.lowerThird(name: "AVERY CHEN", subtitle: "Field Correspondent",
                                      corner: .bottomLeft, progress: p)
            try FXCanvas.writePNG(f, to: Self.outputDir.appendingPathComponent(
                String(format: "mg_lowerthird_%.2f.png", p)))
        }
        // Name-tag pill.
        try FXCanvas.writePNG(try mg.nameTag(name: "DR. RAO", corner: .topRight, progress: 1.0),
                              to: Self.outputDir.appendingPathComponent("mg_nametag.png"))
        // Countdown 3 → 2 → 1.
        for n in [3, 2, 1] {
            try FXCanvas.writePNG(try mg.countdown(secondsRemaining: n, tickProgress: 0.12),
                                  to: Self.outputDir.appendingPathComponent("mg_countdown_\(n).png"))
        }
        // Subscribe / CTA pop.
        for p in [0.35, 0.7, 1.0] {
            try FXCanvas.writePNG(try mg.ctaBug(corner: .bottomRight, progress: p),
                                  to: Self.outputDir.appendingPathComponent(
                                    String(format: "mg_subscribe_%.2f.png", p)))
        }
        // Strobe phases over a visual source.
        let strobe = try StrobeEffect(width: W, height: H)
        let src = try makeVisualSource()
        for p in [0.0, 0.1, 0.3, 0.6, 0.9] {
            let f = try strobe.apply(to: src, phase: p, intensity: 0.9, color: .white)
            try FXCanvas.writePNG(f, to: Self.outputDir.appendingPathComponent(
                String(format: "mg_strobe_%.2f.png", p)))
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: Self.outputDir.path)
            .filter { $0.hasPrefix("mg_") }
        XCTAssertEqual(files.count, 4 + 1 + 3 + 3 + 5, "all PNG frames landed")
    }

    /// A colorful gradient with shapes so the strobe flash is visible on eyeball.
    private func makeVisualSource() throws -> CVPixelBuffer {
        let canvas = try FXCanvas(width: W, height: H)
        let w = CGFloat(W), h = CGFloat(H)
        return try canvas.render { ctx in
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            if let g = CGGradient(colorsSpace: cs,
                                  colors: [RGBA(r: 0.10, g: 0.20, b: 0.45).cg,
                                           RGBA(r: 0.55, g: 0.25, b: 0.10).cg] as CFArray,
                                  locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: w, y: h), options: [])
            }
            ctx.setFillColor(RGBA(r: 0.9, g: 0.85, b: 0.2).cg)
            ctx.fillEllipse(in: CGRect(x: w * 0.30, y: h * 0.30, width: w * 0.40, height: h * 0.40))
            ctx.setFillColor(RGBA(r: 0.1, g: 0.1, b: 0.12).cg)
            ctx.fill(CGRect(x: w * 0.44, y: h * 0.10, width: w * 0.12, height: h * 0.8))
        }
    }
}
