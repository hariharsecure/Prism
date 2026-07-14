import CoreGraphics
import CoreVideo
import Foundation
import XCTest

import PrismCompositor
import PrismCore

/// Verification for the animation-enhancement renderers (DESIGN.md §1 logo,
/// §2 ticker/credits, §4 layer motion, §5 text reveal): `AnimatedLogo`,
/// `Ticker`, `CreditsRoll`, `LayerMotion`, `TextReveal`.
///
/// Asserts each renderer's contract on real pixels / values and DUMPS PNGs the
/// lead can eyeball to:
///   /tmp/prism_anim/
final class AnimationEnhancementsTests: XCTestCase {

    private static let outputDir = URL(fileURLWithPath:
        "/tmp/prism_anim")

    private let W = 640, H = 360

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: Self.outputDir, withIntermediateDirectories: true)
    }

    // MARK: - 1. AnimatedLogo

    func testAnimatedLogoEntranceIdleAndTransparency() throws {
        let logo = Self.donutLogo(size: 240)          // opaque ring, transparent hole + corners
        let renderer = try AnimatedLogo(width: W, height: H)

        // Slide entrance from the left, anchored center, no idle (isolate entrance).
        var style = LogoStyle(anchor: .center, sizeFraction: 0.5, margin: 0.04,
                              entrance: .slide(.left), idle: .none)

        let p0 = try renderer.render(logo: logo, progress: 0, idlePhase: 0, style: style)
        let p03 = try renderer.render(logo: logo, progress: 0.3, idlePhase: 0, style: style)
        let p06 = try renderer.render(logo: logo, progress: 0.6, idlePhase: 0, style: style)
        let p1 = try renderer.render(logo: logo, progress: 1.0, idlePhase: 0, style: style)

        // Entrance: fully off-screen at progress 0 → essentially nothing on canvas.
        XCTAssertLessThan(Self.maxAlpha(p0), 0.02, "logo should be off-screen at progress 0 (maxAlpha≈0)")
        // On-screen and opaque somewhere by mid + rest.
        XCTAssertGreaterThan(Self.maxAlpha(p06), 0.5, "logo should be visible at progress 0.6")
        XCTAssertGreaterThan(Self.maxAlpha(p1), 0.5, "logo should be visible at rest")

        // Moves off→on: the opaque centroid slides rightward toward its rest x.
        let cMid = Self.opaqueCentroid(p06)
        let cRest = Self.opaqueCentroid(p1)
        XCTAssertNotNil(cMid); XCTAssertNotNil(cRest)
        XCTAssertLessThan(cMid!.x, cRest!.x - 5, "sliding-in logo should be left of its rest position at mid")
        XCTAssertEqual(cRest!.x, Double(W) / 2, accuracy: Double(W) * 0.06, "rest centroid ≈ canvas center x")

        // Background transparency + the logo's OWN transparency are preserved:
        // canvas corner is transparent (alpha 0, NOT opaque black), the ring hole
        // (== canvas center at rest) is transparent, and the ring itself is opaque.
        let corner = FXCanvas.pixel(p1, x: 4, y: 4)
        XCTAssertLessThan(corner.a, 0.02, "canvas corner must be transparent, not an opaque box")
        let hole = FXCanvas.pixel(p1, x: W / 2, y: H / 2)
        XCTAssertLessThan(hole.a, 0.05, "ring hole must stay transparent (own alpha preserved)")
        let ringPt = FXCanvas.pixel(p1, x: W / 2 + 100, y: H / 2)   // 100px ≈ mid-band of the ring
        XCTAssertGreaterThan(ringPt.a, 0.7, "the ring itself must be opaque")

        // Idle actually animates frame-to-frame (float bob at rest).
        style.idle = .float
        let idleA = try renderer.render(logo: logo, progress: 1, idlePhase: 0.25, style: style)
        let idleB = try renderer.render(logo: logo, progress: 1, idlePhase: 0.75, style: style)
        XCTAssertGreaterThan(FXCanvas.meanDiff(idleA, idleB), 0.001, "idle float must change pixels frame-to-frame")

        // Bug mode: idle-only watermark is visible even at progress 0.
        let bugStyle = LogoStyle.bug(anchor: .bottomRight, sizeFraction: 0.12, idle: .pulse)
        let bug = try renderer.render(logo: logo, progress: 0, idlePhase: 0.3, style: bugStyle)
        XCTAssertGreaterThan(Self.maxAlpha(bug), 0.5, "bug watermark must be persistent (visible at progress 0)")

        // Exit is the entrance in reverse: render is a pure function of progress,
        // so playing progress 1→0 replays these same frames backwards. As a proxy,
        // on-canvas coverage grows monotonically 0→0.6 (and would shrink on exit).
        XCTAssertLessThan(Self.opaqueCount(p0), Self.opaqueCount(p03))
        XCTAssertLessThan(Self.opaqueCount(p03), Self.opaqueCount(p06))

        // PNG dump: entrance sweep (composited over gray so the logo reads), plus idle + a shimmer + bug.
        let bg = RGBA(r: 0.20, g: 0.22, b: 0.26, a: 1)
        try Self.dumpOver(p0, bg: bg, to: Self.outputDir.appendingPathComponent("logo_entrance_0.png"))
        try Self.dumpOver(p03, bg: bg, to: Self.outputDir.appendingPathComponent("logo_entrance_030.png"))
        try Self.dumpOver(p06, bg: bg, to: Self.outputDir.appendingPathComponent("logo_entrance_060.png"))
        try Self.dumpOver(p1, bg: bg, to: Self.outputDir.appendingPathComponent("logo_entrance_100.png"))
        try Self.dumpOver(idleA, bg: bg, to: Self.outputDir.appendingPathComponent("logo_idle_float.png"))
        let shimmerStyle = LogoStyle(anchor: .center, sizeFraction: 0.5, entrance: .fade, idle: .shimmer, idleAmplitude: 1)
        let shimmer = try renderer.render(logo: Self.badgeLogo(size: 260), progress: 1, idlePhase: 0.5, style: shimmerStyle)
        try Self.dumpOver(shimmer, bg: bg, to: Self.outputDir.appendingPathComponent("logo_idle_shimmer.png"))
        try Self.dumpOver(bug, bg: bg, to: Self.outputDir.appendingPathComponent("logo_bug.png"))
    }

    // MARK: - 2. Ticker (seamless horizontal crawl)

    func testTickerSeamlessScroll() throws {
        let ticker = try Ticker(width: W, height: H)
        let style = TickerStyle(position: .bottom)
        let text = "BREAKING — Prism ships animated overlays and a seamless news crawl"

        let loop = ticker.loopLength(text: text, style: style)
        XCTAssertGreaterThan(loop, 0)

        let f0 = try ticker.render(text: text, offset: 0, style: style)
        let fLoop = try ticker.render(text: text, offset: loop, style: style)          // one full loop later
        let fAdvance = try ticker.render(text: text, offset: loop * 0.13, style: style) // partial advance

        // Seamless wrap: a whole loop later is pixel-identical (no gap/jump).
        let wrapDiff = FXCanvas.meanDiff(f0, fLoop)
        XCTAssertLessThan(wrapDiff, 0.001, "ticker must wrap seamlessly (offset 0 ≈ offset loopLength)")
        // Advancing the offset genuinely moves the text.
        let advDiff = FXCanvas.meanDiff(f0, fAdvance)
        XCTAssertGreaterThan(advDiff, 0.001, "advancing offset must scroll the text")
        XCTAssertGreaterThan(advDiff, wrapDiff, "an advance must differ more than a full-loop wrap")

        // Two-loops-later is also identical (wrap holds at any multiple).
        let f2Loop = try ticker.render(text: text, offset: loop * 2, style: style)
        XCTAssertLessThan(FXCanvas.meanDiff(f0, f2Loop), 0.001, "wrap holds at multiples of loopLength")

        // Transparent above the bar (overlay, not a full-frame box).
        XCTAssertLessThan(FXCanvas.pixel(f0, x: W / 2, y: H / 5).a, 0.02, "area above the ticker bar must be transparent")

        let bg = RGBA(r: 0.10, g: 0.12, b: 0.16, a: 1)
        try Self.dumpOver(f0, bg: bg, to: Self.outputDir.appendingPathComponent("ticker_offset_0.png"))
        try Self.dumpOver(fAdvance, bg: bg, to: Self.outputDir.appendingPathComponent("ticker_offset_adv.png"))
    }

    // MARK: - 2b. CreditsRoll (vertical roll with edge fade)

    func testCreditsRoll() throws {
        let credits = try CreditsRoll(width: W, height: H)
        let style = CreditsStyle()
        let lines = ["PRISM STUDIO", "Directed by June", "Compositor — VisualFX",
                     "Motion — LayerMotion", "Text — TextReveal", "Ticker — Prism", "Thanks for watching"]
        let roll = credits.rollLength(lineCount: lines.count, style: style)

        let start = try credits.render(lines: lines, offset: 0, style: style)          // block below screen
        let mid = try credits.render(lines: lines, offset: roll * 0.5, style: style)   // block on screen
        let end = try credits.render(lines: lines, offset: roll, style: style)         // block above screen

        let cStart = Self.opaqueCount(start)
        let cMid = Self.opaqueCount(mid)
        let cEnd = Self.opaqueCount(end)
        XCTAssertGreaterThan(cMid, cStart + 100, "credits should be off-screen at start, on-screen mid-roll")
        XCTAssertGreaterThan(cMid, cEnd + 100, "credits should have rolled off the top by the end")

        // y-offset advances: a fixed line's centroid rises (top-origin y decreases) as offset grows.
        let a = try credits.render(lines: lines, offset: roll * 0.45, style: style)
        let b = try credits.render(lines: lines, offset: roll * 0.55, style: style)
        let ca = Self.opaqueCentroid(a), cb = Self.opaqueCentroid(b)
        XCTAssertNotNil(ca); XCTAssertNotNil(cb)
        XCTAssertLessThan(cb!.y, ca!.y - 3, "increasing offset must scroll lines upward")

        // Edge fade: the fade ramp is 0 at the very edges, 1 in the middle band.
        XCTAssertEqual(CreditsRoll.edgeAlpha(0, height: Double(H), fade: 40), 0, accuracy: 0.001)
        XCTAssertEqual(CreditsRoll.edgeAlpha(Double(H) / 2, height: Double(H), fade: 40), 1, accuracy: 0.001)
        XCTAssertLessThan(CreditsRoll.edgeAlpha(10, height: Double(H), fade: 40), 0.5, "near-edge line must be faded")

        let bg = RGBA(r: 0.05, g: 0.05, b: 0.07, a: 1)
        try Self.dumpOver(mid, bg: bg, to: Self.outputDir.appendingPathComponent("credits_mid.png"))
    }

    // MARK: - 3. LayerMotion (parametric / keyframed path)

    func testLayerMotionPaths() throws {
        // Deterministic: same input → same output (no Date/rand).
        let orbit = LayerMotion(path: .orbit(center: CGPoint(x: 0, y: 0), radius: 0.3))
        XCTAssertEqual(orbit.transform(at: 0.37), orbit.transform(at: 0.37))

        // Orbit follows the circle and loops seamlessly.
        let o0 = orbit.transform(at: 0.0)
        let oQuarter = orbit.transform(at: 0.25)
        let o1 = orbit.transform(at: 1.0)
        XCTAssertEqual(o0.tx, 0.3, accuracy: 1e-9); XCTAssertEqual(o0.ty, 0.0, accuracy: 1e-9)   // angle 0 → (r,0)
        XCTAssertEqual(oQuarter.tx, 0.0, accuracy: 1e-9); XCTAssertEqual(oQuarter.ty, 0.3, accuracy: 1e-9) // 90° → (0,r)
        XCTAssertEqual(o0.tx, o1.tx, accuracy: 1e-9); XCTAssertEqual(o0.ty, o1.ty, accuracy: 1e-9)  // seamless loop

        // Line one-shot: exact endpoints (easing maps 0→0, 1→1).
        let line = LayerMotion(path: .line(from: CGPoint(x: -0.4, y: 0.1), to: CGPoint(x: 0.4, y: -0.1)))
        XCTAssertEqual(line.transform(at: 0).tx, -0.4, accuracy: 1e-9)
        XCTAssertEqual(line.transform(at: 1).tx, 0.4, accuracy: 1e-9)
        // Progresses monotonically along x over time.
        XCTAssertLessThan(line.transform(at: 0.25).tx, line.transform(at: 0.75).tx)

        // Bounce: parabola hop, 0 at the ends, peak (up = negative ty) at the middle; seamless.
        let bounce = LayerMotion(path: .bounce(height: 0.5))
        XCTAssertEqual(bounce.transform(at: 0).ty, 0, accuracy: 1e-9)
        XCTAssertEqual(bounce.transform(at: 1).ty, 0, accuracy: 1e-9)
        XCTAssertEqual(bounce.transform(at: 0.5).ty, -0.5, accuracy: 1e-9)

        // Float: seamless loop.
        let float = LayerMotion(path: .float(amplitude: 0.05))
        XCTAssertEqual(float.transform(at: 0).ty, float.transform(at: 1).ty, accuracy: 1e-9)

        // Keyframed: ties LayerMotion to KeyframeAnimation (samples the AnimTrack).
        let track = AnimTrack(keyframes: [
            Keyframe(time: 0, transform: LayerTransform(tx: -0.5, opacity: 0)),
            Keyframe(time: 1, transform: LayerTransform(tx: 0, opacity: 1), easing: .easeOut),
        ], duration: 1)
        let kf = LayerMotion(path: .keyframed(track))
        XCTAssertEqual(kf.transform(at: 0).tx, -0.5, accuracy: 1e-9)
        XCTAssertEqual(kf.transform(at: 1).opacity, 1, accuracy: 1e-9)

        // PNG dump: an orbit rendered as a moving dot over a background, sampled around the loop.
        try Self.dumpMotionStrip(orbit, name: "layermotion_orbit.png")
        try Self.dumpMotionStrip(bounce, name: "layermotion_bounce.png")
    }

    // MARK: - 4. TextReveal

    func testTextReveal() throws {
        let full = "PRISM MAKES MOTION EASY"       // 4 words

        // Typewriter: at progress p, ~ceil(p·N) chars visible; final = full string.
        let chars = full.count
        let r0 = TextReveal.reveal(full, progress: 0, style: .typewriter)
        XCTAssertEqual(r0.visibleCount, 0, "nothing visible at progress 0")
        XCTAssertEqual(r0.visibleString, "")
        let rHalf = TextReveal.reveal(full, progress: 0.5, style: .typewriter)
        XCTAssertEqual(rHalf.visibleCount, Int((0.5 * Double(chars)).rounded(.up)), "≈ceil(p·N) chars visible")
        XCTAssertEqual(rHalf.visibleString, String(Array(full)[0..<rHalf.visibleCount]))
        let r1 = TextReveal.reveal(full, progress: 1, style: .typewriter)
        XCTAssertEqual(r1.visibleString, full, "typewriter reveals the full string at progress 1")
        XCTAssertTrue(r1.units.allSatisfy { $0.alpha > 0.99 }, "all chars fully in at progress 1")

        // Word-by-word: ceil(p·M) words visible; final = full string.
        let words = full.split(separator: " ").count      // 4
        let w0 = TextReveal.reveal(full, progress: 0, style: .wordByWord)
        XCTAssertEqual(w0.visibleCount, 0)
        let wHalf = TextReveal.reveal(full, progress: 0.5, style: .wordByWord)
        XCTAssertEqual(wHalf.visibleCount, Int((0.5 * Double(words)).rounded(.up)), "≈ceil(p·M) words visible")
        XCTAssertEqual(wHalf.visibleString, "PRISM MAKES")
        let w1 = TextReveal.reveal(full, progress: 1, style: .wordByWord)
        XCTAssertEqual(w1.visibleString, full)
        // The newest revealed word slides up (offsetY > 0) mid-reveal.
        let wEdge = TextReveal.reveal(full, progress: 0.3, style: .wordByWord)
        XCTAssertTrue(wEdge.units.contains { $0.isVisible && $0.offsetY > 0.001 }, "mid-reveal word should slide")

        // Bounce-in-word: the leading word overshoots/undershoots scale (≠1) mid-reveal.
        let bEdge = TextReveal.reveal(full, progress: 0.3, style: .bounceInWord)
        XCTAssertTrue(bEdge.units.contains { $0.isVisible && abs($0.scale - 1) > 0.01 }, "bounce word should scale ≠ 1")
        let b1 = TextReveal.reveal(full, progress: 1, style: .bounceInWord)
        XCTAssertEqual(b1.visibleString, full)
        XCTAssertTrue(b1.units.allSatisfy { abs($0.scale - 1) < 0.01 }, "words settle to scale 1 at progress 1")

        // PNG dump: a typewriter sequence rasterized so the lead can eyeball the reveal.
        try Self.dumpRevealSequence(full, style: .typewriter, name: "textreveal_typewriter.png")
        try Self.dumpRevealSequence(full, style: .wordByWord, name: "textreveal_wordbyword.png")
    }

    // MARK: - Pixel-readback helpers (top-origin memory coords)

    private static func maxAlpha(_ buffer: CVPixelBuffer, step: Int = 3) -> Double {
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

    private static func opaqueCount(_ buffer: CVPixelBuffer, thresh: Double = 0.15, step: Int = 2) -> Int {
        opaqueScan(buffer, thresh: thresh, step: step).0
    }

    private static func opaqueCentroid(_ buffer: CVPixelBuffer, thresh: Double = 0.15, step: Int = 2) -> (x: Double, y: Double)? {
        let (n, sx, sy) = opaqueScan(buffer, thresh: thresh, step: step)
        return n > 0 ? (sx / Double(n), sy / Double(n)) : nil
    }

    private static func opaqueScan(_ buffer: CVPixelBuffer, thresh: Double, step: Int) -> (Int, Double, Double) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var n = 0; var sx = 0.0; var sy = 0.0
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                if Double((base + y * bpr + x * 4)[3]) / 255 > thresh { n += 1; sx += Double(x); sy += Double(y) }
                x += step
            }
            y += step
        }
        return (n, sx, sy)
    }

    // MARK: - PNG dump helpers

    /// Composite a transparent overlay over an opaque background and write a PNG
    /// (so the overlay's content reads clearly for the lead).
    private static func dumpOver(_ overlay: CVPixelBuffer, bg: RGBA, to url: URL) throws {
        let w = CVPixelBufferGetWidth(overlay), h = CVPixelBufferGetHeight(overlay)
        let canvas = try FXCanvas(width: w, height: h)
        let img = try FXCanvas.cgImage(from: overlay)
        let out = try canvas.render { ctx in
            ctx.setFillColor(bg.cg)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        try FXCanvas.writePNG(out, to: url)
    }

    /// Render a horizontal strip: the same motion sampled at several phases as a
    /// bright dot over a dark background, to eyeball the path.
    private static func dumpMotionStrip(_ motion: LayerMotion, name: String) throws {
        let w = 640, h = 200, samples = 8
        let canvas = try FXCanvas(width: w, height: h)
        let out = try canvas.render { ctx in
            ctx.setFillColor(RGBA(r: 0.06, g: 0.07, b: 0.10, a: 1).cg)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            for i in 0..<samples {
                let u = Double(i) / Double(samples)
                let t = motion.transform(at: u)
                // Map normalized offsets (fraction of canvas) around the center.
                let cx = Double(w) / 2 + t.tx * Double(w)
                let cy = Double(h) / 2 - t.ty * Double(h)   // ty + = down → −y bottom-left
                let bright = 0.4 + 0.6 * u
                ctx.setFillColor(RGBA(r: bright, g: 0.6, b: 1 - bright, a: 1).cg)
                let r = 14.0
                ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
            }
        }
        try FXCanvas.writePNG(out, to: Self.outputDir.appendingPathComponent(name))
    }

    /// Rasterize a text reveal at several progresses (one row each) so the lead
    /// can eyeball the reveal order + per-unit alpha.
    private static func dumpRevealSequence(_ full: String, style: TextRevealStyle, name: String) throws {
        let w = 720, h = 300
        let canvas = try FXCanvas(width: w, height: h)
        let rows = [0.25, 0.5, 0.75, 1.0]
        let font = Ticker.systemFont(size: 34, weight: 0.6)
        let out = try canvas.render { ctx in
            ctx.setFillColor(RGBA(r: 0.08, g: 0.09, b: 0.12, a: 1).cg)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            for (ri, p) in rows.enumerated() {
                let res = TextReveal.reveal(full, progress: p, style: style)
                let baseY = Double(h) - 60 - Double(ri) * 60   // bottom-left origin rows
                var penX = 40.0
                for u in res.units where u.isVisible {
                    let line = Ticker.ctLine(u.text + (style == .typewriter ? "" : " "), font: font,
                                             color: RGBA(r: 1, g: 1, b: 1, a: 1))
                    ctx.setAlpha(CGFloat(min(max(u.alpha, 0), 1)))
                    ctx.textPosition = CGPoint(x: penX, y: baseY + u.offsetY * 20)
                    CTLineDraw(line, ctx)
                    penX += Double(Ticker.inkWidth(line))
                }
                ctx.setAlpha(1)
            }
        }
        try FXCanvas.writePNG(out, to: Self.outputDir.appendingPathComponent(name))
    }

    // MARK: - Synthetic logo images (with alpha)

    /// An opaque colored ring with a TRANSPARENT center hole and transparent
    /// corners — exercises "the logo's own transparency is preserved".
    private static func donutLogo(size: Int) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
        let c = CGPoint(x: Double(size) / 2, y: Double(size) / 2)
        let outer = Double(size) * 0.46, inner = Double(size) * 0.17
        // Outer disk (teal), then punch a transparent hole with .clear blend.
        ctx.setFillColor(RGBA(r: 0.15, g: 0.75, b: 0.85, a: 1).cg)
        ctx.fillEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: 2 * outer, height: 2 * outer))
        // A brighter top wedge so idle/shimmer motion is visible.
        ctx.setFillColor(RGBA(r: 0.95, g: 0.95, b: 0.55, a: 1).cg)
        ctx.fillEllipse(in: CGRect(x: c.x - outer * 0.9, y: c.y + outer * 0.1, width: outer * 0.5, height: outer * 0.5))
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: 2 * inner, height: 2 * inner))
        ctx.setBlendMode(.normal)
        return ctx.makeImage()!
    }

    /// A filled rounded badge with a play triangle on a transparent field — a
    /// nicer logo for the eyeball dumps.
    private static func badgeLogo(size: Int) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
        let inset = Double(size) * 0.14
        let r = CGRect(x: inset, y: inset, width: Double(size) - 2 * inset, height: Double(size) - 2 * inset)
        let path = CGPath(roundedRect: r, cornerWidth: r.width * 0.22, cornerHeight: r.width * 0.22, transform: nil)
        ctx.setFillColor(RGBA(r: 0.20, g: 0.45, b: 0.95, a: 1).cg)
        ctx.addPath(path); ctx.fillPath()
        // White play triangle.
        let cx = r.midX, cy = r.midY, tr = r.width * 0.22
        ctx.setFillColor(RGBA(r: 1, g: 1, b: 1, a: 1).cg)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: cx - tr * 0.7, y: cy + tr))
        ctx.addLine(to: CGPoint(x: cx - tr * 0.7, y: cy - tr))
        ctx.addLine(to: CGPoint(x: cx + tr, y: cy))
        ctx.closePath(); ctx.fillPath()
        return ctx.makeImage()!
    }
}
