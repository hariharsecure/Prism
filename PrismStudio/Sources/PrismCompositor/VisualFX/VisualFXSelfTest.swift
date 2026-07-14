import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import PrismCore

/// Headless self-verification of the visual-FX engine (DESIGN.md §1–§4):
/// renders real transition / animation / meme sequences over two generated
/// image sources, asserts correctness on the pixels, and dumps every frame as a
/// PNG for the lead to eyeball.
///
/// `run()` is exposed so the lead can wire it into `prism-dev selftest`.
public enum VisualFXSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case setup(String)
        case assertion(String)
        public var description: String {
            switch self {
            case .setup(let s): return "visualfx self-test setup failed: \(s)"
            case .assertion(let s): return "visualfx self-test assertion failed: \(s)"
            }
        }
    }

    /// Default PNG dump directory (overridable).
    public static var defaultOutputDir: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("prism_visualfx")
    }

    /// Run every check. Writes PNGs to `outputDir`. Throws on the first failure.
    /// Returns the list of PNG paths written (for reporting).
    @discardableResult
    public static func run(outputDir: URL? = nil, width: Int = 480, height: Int = 270) throws -> [URL] {
        let dir = outputDir ?? defaultOutputDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var written: [URL] = []

        // Two distinct "image sources": warm gradient (A) vs cool gradient (B).
        let canvas = try FXCanvas(width: width, height: height)
        let a = try canvas.verticalGradient(top: RGBA(r: 1.0, g: 0.55, b: 0.1), bottom: RGBA(r: 0.85, g: 0.1, b: 0.15))
        let b = try canvas.verticalGradient(top: RGBA(r: 0.1, g: 0.85, b: 0.95), bottom: RGBA(r: 0.1, g: 0.2, b: 0.8))
        written.append(try FXCanvas.writePNG(a, to: dir.appendingPathComponent("_sourceA.png")))
        written.append(try FXCanvas.writePNG(b, to: dir.appendingPathComponent("_sourceB.png")))

        let baseDiff = FXCanvas.meanDiff(a, b)
        guard baseDiff > 0.1 else { throw SelfTestError.setup("A and B too similar (diff \(baseDiff))") }

        try written.append(contentsOf: checkTransitions(a: a, b: b, width: width, height: height, dir: dir, baseDiff: baseDiff))
        try written.append(contentsOf: checkAnime(width: width, height: height, dir: dir))
        try written.append(contentsOf: checkMemes(a: a, b: b, width: width, height: height, dir: dir))
        try written.append(contentsOf: checkTemplates(dir: dir))

        print("VisualFXSelfTest: all checks passed — \(written.count) PNGs in \(dir.path)")
        return written
    }

    // MARK: - §1 Transitions

    private static func checkTransitions(a: CVPixelBuffer, b: CVPixelBuffer,
                                         width: Int, height: Int, dir: URL, baseDiff: Double) throws -> [URL] {
        let r = try TransitionRenderer(width: width, height: height)
        var written: [URL] = []
        let kinds: [TransitionKind] = [
            .dissolve, .wipe(.left), .wipe(.down), .push(.left), .push(.up),
            .iris, .zoomBlur, .glitch, .animeFlash, .speedline,
        ]
        let stops = [0.0, 0.25, 0.5, 0.75, 1.0]
        for kind in kinds {
            let spec = TransitionSpec(kind: kind, duration: 0.5, easing: .linear)
            var frames: [CVPixelBuffer] = []
            for (i, p) in stops.enumerated() {
                let f = try r.render(a: a, b: b, spec: spec, progress: p)
                frames.append(f)
                written.append(try FXCanvas.writePNG(f, to: dir.appendingPathComponent("t_\(kind.label)_\(i)_p\(Int(p * 100)).png")))
            }
            // Endpoints: p0 == A, p1 == B.
            let d0 = FXCanvas.meanDiff(frames[0], a), d1 = FXCanvas.meanDiff(frames[4], b)
            guard d0 < 0.02 else { throw SelfTestError.assertion("\(kind.label): progress 0 ≠ A (diff \(d0))") }
            guard d1 < 0.02 else { throw SelfTestError.assertion("\(kind.label): progress 1 ≠ B (diff \(d1))") }
            // Midpoint is a genuine blend (differs from both A and B).
            let mA = FXCanvas.meanDiff(frames[2], a), mB = FXCanvas.meanDiff(frames[2], b)
            guard mA > 0.03, mB > 0.03 else {
                throw SelfTestError.assertion("\(kind.label): midpoint not a genuine blend (dA \(mA), dB \(mB))")
            }
            // Kind-specific — DIRECTION + geometry (B10), not just "boundary
            // moved" (a dissolve or a reversed wipe passes that identically).
            let mid = frames[2]   // p = 0.5
            switch kind {
            case .wipe(let edge):
                try assertWipeDirection(mid, a: a, b: b, edge: edge)
            case .push(let edge):
                try assertPushDirection(mid, a: a, edge: edge)
            case .iris:
                try assertIrisDirection(mid, a: a, b: b)
            case .animeFlash:
                // A white flash frame exists at the midpoint.
                let luma = FXCanvas.meanLuma(frames[2])
                guard luma > 0.75 else { throw SelfTestError.assertion("animeFlash midpoint not a white flash (luma \(luma))") }
            default: break
            }
        }
        print("  ✓ §1 transitions: \(kinds.count) kinds, endpoints exact, midpoints blend, wipe/iris/push DIRECTION verified, flash frame present")
        return written
    }

    // MARK: - §1 direction/geometry assertions (B10)

    /// Mean per-channel color difference (0…1) over a normalized sub-region of a
    /// frame vs a reference buffer (grid-sampled). Small = the region matches the
    /// reference there.
    private static func regionDiff(_ f: CVPixelBuffer, _ ref: CVPixelBuffer,
                                   x xr: ClosedRange<Double>, y yr: ClosedRange<Double>) -> Double {
        let w = min(CVPixelBufferGetWidth(f), CVPixelBufferGetWidth(ref))
        let h = min(CVPixelBufferGetHeight(f), CVPixelBufferGetHeight(ref))
        let x0 = max(0, Int(xr.lowerBound * Double(w))), x1 = min(w, Int(xr.upperBound * Double(w)))
        let y0 = max(0, Int(yr.lowerBound * Double(h))), y1 = min(h, Int(yr.upperBound * Double(h)))
        var sum = 0.0, n = 0
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                let pf = FXCanvas.pixel(f, x: x, y: y), pr = FXCanvas.pixel(ref, x: x, y: y)
                sum += abs(pf.r - pr.r) + abs(pf.g - pr.g) + abs(pf.b - pr.b)
                n += 3
                x += 8
            }
            y += 8
        }
        return n > 0 ? sum / Double(n) : 0
    }

    /// At p=0.5 the incoming B occupies the side the wipe reveals from; the
    /// outgoing A holds the complementary side. Wipe does not translate content,
    /// so each region can be compared to the un-shifted A / B directly.
    private static func assertWipeDirection(_ mid: CVPixelBuffer, a: CVPixelBuffer, b: CVPixelBuffer,
                                            edge: FXDirection) throws {
        let band = 0.25...0.75
        let lo = 0.02...0.35, hi = 0.65...0.98
        // (B-region, A-region), each as (xRange, yRange).
        let bRegion: (ClosedRange<Double>, ClosedRange<Double>)
        let aRegion: (ClosedRange<Double>, ClosedRange<Double>)
        switch edge {
        case .left:  bRegion = (lo, band); aRegion = (hi, band)   // B grows from left
        case .right: bRegion = (hi, band); aRegion = (lo, band)
        case .up:    bRegion = (band, lo); aRegion = (band, hi)   // B grows from top
        case .down:  bRegion = (band, hi); aRegion = (band, lo)
        }
        let bToB = regionDiff(mid, b, x: bRegion.0, y: bRegion.1)
        let bToA = regionDiff(mid, a, x: bRegion.0, y: bRegion.1)
        guard bToB < bToA else {
            throw SelfTestError.assertion("wipe_\(edge.rawValue): reveal side is not B (dB \(bToB) ≥ dA \(bToA))")
        }
        let aToA = regionDiff(mid, a, x: aRegion.0, y: aRegion.1)
        let aToB = regionDiff(mid, b, x: aRegion.0, y: aRegion.1)
        guard aToA < aToB else {
            throw SelfTestError.assertion("wipe_\(edge.rawValue): outgoing side is not A (dA \(aToA) ≥ dB \(aToB))")
        }
    }

    /// At p=0.5 the incoming B is revealed through the growing centre circle;
    /// the corners still show outgoing A.
    private static func assertIrisDirection(_ mid: CVPixelBuffer, a: CVPixelBuffer, b: CVPixelBuffer) throws {
        let center = (0.44...0.56, 0.44...0.56)
        let corner = (0.0...0.12, 0.0...0.12)
        let cToB = regionDiff(mid, b, x: center.0, y: center.1)
        let cToA = regionDiff(mid, a, x: center.0, y: center.1)
        guard cToB < cToA else {
            throw SelfTestError.assertion("iris: centre is not B (dB \(cToB) ≥ dA \(cToA))")
        }
        let kToA = regionDiff(mid, a, x: corner.0, y: corner.1)
        let kToB = regionDiff(mid, b, x: corner.0, y: corner.1)
        guard kToA < kToB else {
            throw SelfTestError.assertion("iris: corner is not A (dA \(kToA) ≥ dB \(kToB))")
        }
    }

    /// At p=0.5 the incoming B has entered from the edge OPPOSITE `edge` (A
    /// exits toward `edge`). Push translates content along the motion axis, so
    /// rather than compare to un-shifted A/B we assert the entering edge changed
    /// far more from the original A than the exiting edge did — i.e. new content
    /// arrived from the correct side.
    private static func assertPushDirection(_ mid: CVPixelBuffer, a: CVPixelBuffer, edge: FXDirection) throws {
        let band = 0.2...0.8
        let near = 0.01...0.15, far = 0.85...0.99
        // Entering strip (where B arrives) vs exiting strip (where A leaves).
        let entering: (ClosedRange<Double>, ClosedRange<Double>)
        let exiting: (ClosedRange<Double>, ClosedRange<Double>)
        switch edge {
        case .left:  entering = (far, band);  exiting = (near, band)   // A exits left, B enters right
        case .right: entering = (near, band); exiting = (far, band)
        case .up:    entering = (band, far);  exiting = (band, near)   // A exits up, B enters bottom
        case .down:  entering = (band, near); exiting = (band, far)
        }
        let enterChange = regionDiff(mid, a, x: entering.0, y: entering.1)
        let exitChange  = regionDiff(mid, a, x: exiting.0,  y: exiting.1)
        guard enterChange > exitChange + 0.03 else {
            throw SelfTestError.assertion(
                "push_\(edge.rawValue): B did not enter from the expected edge (enterΔA \(enterChange) ≤ exitΔA \(exitChange))")
        }
    }

    // MARK: - §2 Anime keyframe animations

    private static func checkAnime(width: Int, height: Int, dir: URL) throws -> [URL] {
        let renderer = try LayerAnimationRenderer(width: width, height: height)
        // A sprite with BOTH horizontal and vertical structure so translation /
        // shake / rotation are visible in the pixels (a gradient that varies on
        // one axis would hide a shift along the other).
        let spriteCanvas = try FXCanvas(width: 256, height: 256)
        let sprite = try spriteCanvas.render { ctx in
            let colors = [RGBA(r: 0.95, g: 0.3, b: 0.2), RGBA(r: 0.2, g: 0.8, b: 0.4),
                          RGBA(r: 0.2, g: 0.5, b: 0.95), RGBA(r: 0.95, g: 0.85, b: 0.2)]
            let quads = [CGRect(x: 0, y: 128, width: 128, height: 128), CGRect(x: 128, y: 128, width: 128, height: 128),
                         CGRect(x: 0, y: 0, width: 128, height: 128), CGRect(x: 128, y: 0, width: 128, height: 128)]
            for (c, q) in zip(colors, quads) { ctx.setFillColor(c.cg); ctx.fill(q) }
            ctx.setFillColor(RGBA(r: 1, g: 1, b: 1).cg)
            ctx.fillEllipse(in: CGRect(x: 96, y: 96, width: 64, height: 64))   // asymmetric mark
        }
        let spriteImg = try FXCanvas.cgImage(from: sprite)
        let restRect = CGRect(x: 0.32, y: 0.28, width: 0.36, height: 0.44)
        let bg = RGBA(r: 0.08, g: 0.09, b: 0.12)
        var written: [URL] = []

        for preset in AnimePreset.allCases {
            let track = preset.track(duration: 0.6)
            let fractions = [0.0, 0.25, 0.5, 0.75, 1.0]
            var frames: [CVPixelBuffer] = []
            var transforms: [LayerTransform] = []
            for (i, f) in fractions.enumerated() {
                let x = track.sample(atFraction: f)
                transforms.append(x)
                let frame = try renderer.render(sprite: spriteImg, restRect: restRect, background: bg, transform: x)
                frames.append(frame)
                written.append(try FXCanvas.writePNG(frame, to: dir.appendingPathComponent("a_\(preset.rawValue)_\(i).png")))
            }
            // Frames change over time (animation actually animates). Use the max
            // pairwise diff — a single pair can land on two same-phase samples
            // (e.g. shake crossing zero at both f=0 and f=0.5).
            var motion = 0.0
            for i in 0..<frames.count { for j in (i + 1)..<frames.count {
                motion = max(motion, FXCanvas.meanDiff(frames[i], frames[j]))
            } }
            // `shake` is a subtle, localized accent: its whole-canvas mean diff is
            // small but far above the numerical-noise floor (~5e-6). Big-motion
            // presets clear the higher bar.
            let floor = preset == .shake ? 0.003 : 0.01
            guard motion > floor else { throw SelfTestError.assertion("\(preset.rawValue): no motion (max diff \(motion), floor \(floor))") }

            // Per-preset structural checks. Sample the track finely (the 5
            // render frames can skip a sharp early peak like impact-pop's).
            let fine = stride(from: 0.0, through: 1.0, by: 0.01).map { track.sample(atFraction: $0) }
            switch preset {
            case .bounceIn, .popSpin, .impactPop:
                let peakScale = fine.map(\.scale).max() ?? 0
                guard peakScale > 1.05 else { throw SelfTestError.assertion("\(preset.rawValue): expected scale overshoot (peak \(peakScale))") }
            case .slideOvershoot:
                // Overshoots past the rest x=0 (a positive tx sample).
                guard transforms.contains(where: { $0.tx > 0.001 }) else {
                    throw SelfTestError.assertion("slideOvershoot: no overshoot past rest")
                }
            case .shake:
                let sampled = stride(from: 0.0, through: 1.0, by: 0.05).map { track.sample(atFraction: $0).tx }
                guard sampled.contains(where: { $0 > 0.001 }), sampled.contains(where: { $0 < -0.001 }) else {
                    throw SelfTestError.assertion("shake: tx did not oscillate sign")
                }
            }
            if preset == .impactPop {
                let flashes = stride(from: 0.0, through: 1.0, by: 0.02).map { track.sample(atFraction: $0).flash }
                guard flashes.contains(where: { $0 > 0.5 }) else {
                    throw SelfTestError.assertion("impactPop: no flash accent frame")
                }
            }
        }
        print("  ✓ §2 anime: \(AnimePreset.allCases.count) presets, motion present, overshoot/shake/flash verified")
        return written
    }

    // MARK: - §4 MemeBoard modes

    private static func checkMemes(a: CVPixelBuffer, b: CVPixelBuffer, width: Int, height: Int, dir: URL) throws -> [URL] {
        let canvas = try FXCanvas(width: width, height: height)
        var written: [URL] = []

        // A meme "media" buffer distinct from A and B.
        let memeMedia = try canvas.solid(RGBA(r: 0.95, g: 0.85, b: 0.1))
        let aID = SourceID("A"), memeID = SourceID("meme")
        let frames: [SourceID: CVPixelBuffer] = [aID: a, memeID: memeMedia]
        let base = Scene(name: "program", layers: [Layer(sourceID: aID)])

        // --- cut-to: takes full screen then auto-returns ---
        let director = MemeDirector()
        let cut = MemeItem(name: "cut", mediaURL: URL(fileURLWithPath: "/dev/null"),
                           sourceID: memeID, mode: .cutTo, holdSec: 1.0, placement: .fullscreen)
        director.trigger(cut, at: 10.0)
        let before = director.program(at: 9.5, base: base)
        let during = director.program(at: 10.5, base: base)
        guard during.layers.count == 1, during.layers[0].sourceID == memeID else {
            throw SelfTestError.assertion("meme cutTo: program not taken full-screen by meme")
        }
        let after = director.program(at: 11.5, base: base)
        guard after.layers.map(\.sourceID) == base.layers.map(\.sourceID) else {
            throw SelfTestError.assertion("meme cutTo: program did not auto-return to base")
        }
        guard before.layers.map(\.sourceID) == base.layers.map(\.sourceID) else {
            throw SelfTestError.assertion("meme cutTo: program taken before start")
        }
        written.append(try FXCanvas.writePNG(try canvas.renderScene(before, frames: frames), to: dir.appendingPathComponent("m_cutto_0_before.png")))
        written.append(try FXCanvas.writePNG(try canvas.renderScene(during, frames: frames), to: dir.appendingPathComponent("m_cutto_1_during.png")))
        written.append(try FXCanvas.writePNG(try canvas.renderScene(after, frames: frames), to: dir.appendingPathComponent("m_cutto_2_after.png")))

        // --- insert: overlays a placed layer, base still present ---
        let director2 = MemeDirector()
        let ins = MemeItem(name: "insert", mediaURL: URL(fileURLWithPath: "/dev/null"),
                           sourceID: memeID, mode: .insert, holdSec: 1.0, placement: .corner(.topRight))
        director2.trigger(ins, at: 0.0)
        let overlay = director2.program(at: 0.2, base: base)
        guard overlay.layers.count == 2, overlay.layers.contains(where: { $0.sourceID == memeID }),
              overlay.layers.contains(where: { $0.sourceID == aID }) else {
            throw SelfTestError.assertion("meme insert: overlay layer not added over base")
        }
        let overlayGone = director2.program(at: 1.2, base: base)
        guard overlayGone.layers.count == 1 else { throw SelfTestError.assertion("meme insert: overlay did not auto-remove") }
        written.append(try FXCanvas.writePNG(try canvas.renderScene(overlay, frames: frames), to: dir.appendingPathComponent("m_insert_0_active.png")))
        written.append(try FXCanvas.writePNG(try canvas.renderScene(overlayGone, frames: frames), to: dir.appendingPathComponent("m_insert_1_gone.png")))

        // --- stinger: item plays over the cut, program swaps A→B at the cue ---
        let sr = try StingerRenderer(width: width, height: height)
        let sting = StingerTransition.panel(color: RGBA(r: 0.1, g: 0.1, b: 0.12), direction: .left,
                                            duration: 0.7, cueProgress: 0.5)
        let stops = [0.0, 0.25, 0.5, 0.75, 1.0]
        var sFrames: [CVPixelBuffer] = []
        for (i, p) in stops.enumerated() {
            let f = try sr.render(a: a, b: b, stinger: sting, progress: p)
            sFrames.append(f)
            written.append(try FXCanvas.writePNG(f, to: dir.appendingPathComponent("s_stinger_\(i)_p\(Int(p * 100)).png")))
        }
        guard FXCanvas.meanDiff(sFrames[0], a) < 0.02 else { throw SelfTestError.assertion("stinger p0 ≠ A") }
        guard FXCanvas.meanDiff(sFrames[4], b) < 0.02 else { throw SelfTestError.assertion("stinger p1 ≠ B") }
        // At the cue the overlay dominates → differs from both program scenes.
        guard FXCanvas.meanDiff(sFrames[2], a) > 0.1, FXCanvas.meanDiff(sFrames[2], b) > 0.1 else {
            throw SelfTestError.assertion("stinger cue: overlay does not cover the cut")
        }
        // After the cue the program shows B (not A): the 0.75 frame is closer to B.
        guard FXCanvas.meanDiff(sFrames[3], b) < FXCanvas.meanDiff(sFrames[3], a) else {
            throw SelfTestError.assertion("stinger did not swap A→B at the cue")
        }
        print("  ✓ §4 memeboard: cutTo takes+returns, insert overlays+removes, stinger covers cut and swaps A→B")
        return written
    }

    // MARK: - §4 Procedural templates (copyright-safe)

    private static func checkTemplates(dir: URL) throws -> [URL] {
        let tdir = dir.appendingPathComponent("templates")
        let templates = try MemeTemplateGenerator.generateDefaults(into: tdir, width: 960, height: 540)
        guard templates.count == 4 else { throw SelfTestError.assertion("expected 4 templates, got \(templates.count)") }
        for t in templates {
            let attrs = try FileManager.default.attributesOfItem(atPath: t.url.path)
            let size = (attrs[.size] as? Int) ?? 0
            guard size > 1000 else { throw SelfTestError.assertion("template \(t.name) too small (\(size) bytes)") }
        }
        // B7: the reaction card is the MULTI-LINE template ("WHEN THE" /
        // "BUILD PASSES"). The original bug measured line 2 from line 1's
        // trailing text position, driving its origin.x strongly negative and
        // pushing it off-screen right (only "ES" visible). A >1000-byte file
        // check passes anyway, so assert BOTH lines' rendered ink is actually
        // horizontally centered on the read-back pixels.
        guard let card = templates.first(where: { $0.name == "reaction-card" })?.url else {
            throw SelfTestError.assertion("reaction-card template missing")
        }
        try assertBothLinesCentered(card)
        print("  ✓ §4 templates: \(templates.count) royalty-free format PNGs generated (\(tdir.lastPathComponent)/); reaction_card lines centered")
        return templates.map(\.url)
    }

    /// B7: load the generated `reaction_card.png`, cluster its near-white text
    /// pixels into horizontal line-bands, and assert EACH band's ink x-center is
    /// within a few px of the image center. Fails if a line ran off-screen (the
    /// original bug: line 2 drifted right → wrong center / only one band found).
    private static func assertBothLinesCentered(_ url: URL) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw SelfTestError.assertion("reaction_card: could not load \(url.path)")
        }
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { throw SelfTestError.assertion("reaction_card: empty image") }
        let bpr = w * 4
        let data = UnsafeMutableRawPointer.allocate(byteCount: bpr * h, alignment: 16)
        defer { data.deallocate() }
        memset(data, 0, bpr * h)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: data, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bpr, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SelfTestError.assertion("reaction_card: readback context failed")
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = data.assumingMemoryBound(to: UInt8.self)   // RGBA, top-left origin

        // Per-row near-white (text) ink extent.
        var rowMinX = [Int](repeating: Int.max, count: h)
        var rowMaxX = [Int](repeating: -1, count: h)
        var rowCount = [Int](repeating: 0, count: h)
        for y in 0..<h {
            let base = y * bpr
            for x in 0..<w {
                let o = base + x * 4
                if p[o] > 200, p[o + 1] > 200, p[o + 2] > 200 {   // near-white
                    rowCount[y] += 1
                    if x < rowMinX[y] { rowMinX[y] = x }
                    if x > rowMaxX[y] { rowMaxX[y] = x }
                }
            }
        }
        // Cluster consecutive text rows (min 4 ink px/row) into line bands,
        // tolerating small vertical gaps within a line.
        struct Band { var minX: Int; var maxX: Int }
        var bands: [Band] = []
        var cur: Band?
        var gap = 0
        for y in 0..<h {
            if rowCount[y] >= 4 {
                if cur == nil { cur = Band(minX: rowMinX[y], maxX: rowMaxX[y]) }
                else { cur!.minX = min(cur!.minX, rowMinX[y]); cur!.maxX = max(cur!.maxX, rowMaxX[y]) }
                gap = 0
            } else if cur != nil {
                gap += 1
                if gap > 3 { bands.append(cur!); cur = nil }
            }
        }
        if let c = cur { bands.append(c) }

        guard bands.count == 2 else {
            throw SelfTestError.assertion(
                "reaction_card: expected 2 centered text lines, found \(bands.count) (B7: a line ran off-screen)")
        }
        let cx = Double(w) / 2
        let tol = Double(w) * 0.02   // a few px (≈19px @960): line 1 vs line 2 ink centers must both land here
        for (i, b) in bands.enumerated() {
            let center = Double(b.minX + b.maxX) / 2
            guard abs(center - cx) <= tol else {
                throw SelfTestError.assertion(
                    "reaction_card line \(i + 1) not centered: ink center x \(center) vs image center \(cx) " +
                    "(tol \(tol); minX \(b.minX) maxX \(b.maxX)) — B7 off-center regression")
            }
        }
    }
}
