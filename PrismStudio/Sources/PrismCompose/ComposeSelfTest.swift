import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Metal
import PrismCompositor
import PrismCore

/// Headless self-verification of PrismCompose (no TCC, no hardware capture).
///
/// TEST CODE ONLY: locks pixel-buffer base addresses to fill synthetic inputs
/// and read back program output — allowed here, forbidden on the engine hot
/// path (the compositor never touches pixels on the CPU).
///
/// The integrator wires `ComposeSelfTest.run()` into prism-dev or an XCTest
/// target; it throws with a precise message on the first mismatch.
public enum ComposeSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case setupFailed(String)
        case mismatch(String)
        public var description: String {
            switch self {
            case .setupFailed(let s): return "compose self-test setup failed: \(s)"
            case .mismatch(let s): return "compose self-test mismatch: \(s)"
            }
        }
    }

    // Vertical canvas under test.
    static let vW = 1080, vH = 1920

    public static func run() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SelfTestError.setupFailed("no Metal device")
        }
        let secondary = try SecondaryComposition(device: device, width: vW, height: vH)

        // --- Synthetic solid-color BGRA sources (640x360, 16:9) ---
        let srcW = 640, srcH = 360
        let pool = try PixelBufferPool(width: srcW, height: srcH, pixelFormat: kCVPixelFormatType_32BGRA)
        let heroBuf = try pool.makeBuffer(); fillBGRA(heroBuf, b: 255, g: 0, r: 0)   // blue hero
        let otherBuf = try pool.makeBuffer(); fillBGRA(otherBuf, b: 0, g: 0, r: 255) // red other
        let greenBuf = try pool.makeBuffer(); fillBGRA(greenBuf, b: 0, g: 255, r: 0) // green

        let heroID = SourceID("compose.hero.blue")
        let otherID = SourceID("compose.other.red")
        let greenID = SourceID("compose.green")
        let t0 = HouseClock.now()
        let heroFrame = VideoFrame(pixelBuffer: heroBuf, pts: t0, source: heroID)
        let otherFrame = VideoFrame(pixelBuffer: otherBuf, pts: t0, source: otherID)
        let greenFrame = VideoFrame(pixelBuffer: greenBuf, pts: t0, source: greenID)

        var results: [String] = []

        // ============================================================
        // (a) .fill / hero — full-bleed hero, others hidden.
        // Scene: red full-canvas (z0), blue full-canvas (z1 = top → hero).
        // Default heroFill map: top-zIndex hero .fill, others .hidden.
        // ============================================================
        let sceneAB = Scene(name: "dual", layers: [
            Layer(sourceID: otherID, zIndex: 0),
            Layer(sourceID: heroID, zIndex: 1),
        ])
        let progFill = try secondary.composite(frames: [heroID: heroFrame, otherID: otherFrame],
                                               scene: sceneAB, reframe: .heroFill, pts: t0)
        guard progFill.width == vW, progFill.height == vH,
              progFill.pixelFormat == kCVPixelFormatType_32BGRA else {
            throw SelfTestError.mismatch("(a) output is \(progFill.width)x\(progFill.height) fmt \(progFill.pixelFormat), expected \(vW)x\(vH) BGRA")
        }
        // Hero (blue) full-bleed: center + top + bottom all blue; red never shows.
        try expect(progFill, x: vW / 2, y: vH / 2, r: 0, g: 0, b: 255, tol: 2, what: "(a) fill: center = hero blue")
        try expect(progFill, x: vW / 2, y: 40, r: 0, g: 0, b: 255, tol: 2, what: "(a) fill: top = hero blue (full-bleed, no letterbox)")
        try expect(progFill, x: vW / 2, y: vH - 40, r: 0, g: 0, b: 255, tol: 2, what: "(a) fill: bottom = hero blue (full-bleed)")
        try expect(progFill, x: 40, y: vH / 2, r: 0, g: 0, b: 255, tol: 2, what: "(a) fill: left edge = hero blue")
        results.append("(a) .fill/hero: 1080×1920 output, center+edges = hero blue, red hidden — PASS")

        // ============================================================
        // (b) .fit — letterbox: black bars top/bottom, content centered.
        // Single green source, fitAll.
        // ============================================================
        let sceneG = Scene(name: "solo", layers: [Layer(sourceID: greenID)])
        let progFit = try secondary.composite(frames: [greenID: greenFrame],
                                              scene: sceneG, reframe: .fitAll(), pts: t0)
        try expect(progFit, x: vW / 2, y: vH / 2, r: 0, g: 255, b: 0, tol: 2, what: "(b) fit: center = green content")
        try expect(progFit, x: vW / 2, y: 20, r: 0, g: 0, b: 0, tol: 2, what: "(b) fit: top = black letterbox bar")
        try expect(progFit, x: vW / 2, y: vH - 20, r: 0, g: 0, b: 0, tol: 2, what: "(b) fit: bottom = black letterbox bar")
        // Band math: 16:9 source fits to height Av/As of the canvas, centered.
        // Av/As = (9/16)/(16/9) = 0.31640625 → band y ∈ [0.3418, 0.6582].
        let bandTopY = Int((0.3418 * Double(vH)).rounded()) // ≈ 656
        try expect(progFit, x: vW / 2, y: bandTopY + 30, r: 0, g: 255, b: 0, tol: 2, what: "(b) fit: just inside top of band = green")
        try expect(progFit, x: vW / 2, y: bandTopY - 30, r: 0, g: 0, b: 0, tol: 2, what: "(b) fit: just above band = black")
        results.append("(b) .fit: green band centered (y≈656–1264), black bars above/below — PASS")

        // ============================================================
        // (c) .custom(rect) — explicit vertical-canvas placement.
        // Red source at (0.25,0.25,0.5,0.5): pixels x∈[270,810], y∈[480,1440].
        // ============================================================
        let rect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let customMap = ReframeMap(hero: .none, others: .custom(rect))
        let progCustom = try secondary.composite(frames: [otherID: otherFrame],
                                                 scene: Scene(name: "pip", layers: [Layer(sourceID: otherID)]),
                                                 reframe: customMap, pts: t0)
        try expect(progCustom, x: vW / 2, y: vH / 2, r: 255, g: 0, b: 0, tol: 2, what: "(c) custom: center (inside rect) = red")
        try expect(progCustom, x: 400, y: 600, r: 255, g: 0, b: 0, tol: 2, what: "(c) custom: (400,600) inside rect = red")
        try expect(progCustom, x: 100, y: 100, r: 0, g: 0, b: 0, tol: 2, what: "(c) custom: (100,100) outside rect = black")
        try expect(progCustom, x: 900, y: vH / 2, r: 0, g: 0, b: 0, tol: 2, what: "(c) custom: (900,·) right of rect = black")
        results.append("(c) .custom: red placed at (0.25,0.25,0.5,0.5), black outside — PASS")

        // ============================================================
        // (d) VerticalScene transform geometry (pure, no GPU).
        // Full-frame horizontal layer mapped per mode.
        // ============================================================
        let s = SourceID("d.src")
        let fullLayer = Layer(sourceID: s) // frame (0,0,1,1), crop (0,0,1,1)
        let fullScene = Scene(name: "d", layers: [fullLayer])
        let geo = ReframeGeometry.standard
        let AvOverAh = geo.verticalAspect / geo.horizontalAspect // (9/16)/(16/9) = 0.31640625

        // .fill → frame full, crop centered horizontally to width Av/Ah.
        let vFill = VerticalScene(from: fullScene, using: ReframeMap(hero: .none, others: .fill))
        try one(vFill, "(d) fill layer count") { $0.layers.count == 1 }
        let fl = vFill.layers[0]
        try approxRect(fl.frame, CGRect(x: 0, y: 0, width: 1, height: 1), tol: 1e-4, what: "(d) fill: frame = full canvas")
        try approxRect(fl.crop, CGRect(x: (1 - AvOverAh) / 2, y: 0, width: AvOverAh, height: 1), tol: 1e-4,
                       what: "(d) fill: crop = centered width Av/Ah")

        // .fit → crop unchanged, frame = centered band of height Av/Ah.
        let vFit = VerticalScene(from: fullScene, using: ReframeMap(hero: .none, others: .fit))
        let ftl = vFit.layers[0]
        try approxRect(ftl.frame, CGRect(x: 0, y: (1 - AvOverAh) / 2, width: 1, height: AvOverAh), tol: 1e-4,
                       what: "(d) fit: frame = centered band")
        try approxRect(ftl.crop, CGRect(x: 0, y: 0, width: 1, height: 1), tol: 1e-4, what: "(d) fit: crop unchanged")

        // .custom → frame = rect exactly.
        let vCustom = VerticalScene(from: fullScene, using: ReframeMap(hero: .none, others: .custom(rect)))
        try approxRect(vCustom.layers[0].frame, rect, tol: 1e-9, what: "(d) custom: frame = rect")

        // .hidden / default heroFill on a 2-layer scene → only hero survives.
        let vHero = VerticalScene(from: sceneAB, using: .heroFill)
        try one(vHero, "(d) heroFill keeps only hero (top-zIndex) layer") {
            $0.layers.count == 1 && $0.layers[0].sourceID == heroID
        }
        // .follow pins an explicit hero even when it is NOT top-zIndex.
        let vFollow = VerticalScene(from: sceneAB, using: .follow(otherID))
        try one(vFollow, "(d) follow(other) keeps only the pinned hero") {
            $0.layers.count == 1 && $0.layers[0].sourceID == otherID
        }
        results.append("(d) VerticalScene transform: fill/fit/custom rects + hero selection (topZIndex & follow) — PASS")

        // ============================================================
        // (e) Pre-cropped layer (F1). A layer already carrying a non-full
        // crop=(0.25,0,0.5,1) shows content whose *visible* aspect is
        // As·(0.5/1), not As. .fill/.fit must frame from that effective aspect
        // and .fill must COMPOSE with (not replace) the existing crop.
        // ============================================================
        let Ah = geo.horizontalAspect                    // source aspect (default 16/9)
        let Av = geo.verticalAspect                       // vertical canvas aspect (9/16)
        let preCrop = CGRect(x: 0.25, y: 0, width: 0.5, height: 1)
        let Ae = Ah * (preCrop.width / preCrop.height)   // effective visible aspect
        var croppedLayer = Layer(sourceID: SourceID("e.src"))
        croppedLayer.crop = preCrop
        let croppedScene = Scene(name: "e", layers: [croppedLayer])

        // .fill: frame full; crop center-cropped WITHIN the existing crop to the
        // visible aspect. Correct width = existing.width·(Av/Ae); the buggy
        // (full-source-aspect) path would give existing.width·(Av/Ah) — half as
        // wide — so 1e-4 tol distinguishes the fix from the bug.
        let eFill = VerticalScene(from: croppedScene, using: ReframeMap(hero: .none, others: .fill))
        try one(eFill, "(e) fill pre-cropped: 1 layer") { $0.layers.count == 1 }
        let efl = eFill.layers[0]
        let fillW = preCrop.width * (Av / Ae)
        let fillX = preCrop.origin.x + (preCrop.width - fillW) / 2
        try approxRect(efl.frame, CGRect(x: 0, y: 0, width: 1, height: 1), tol: 1e-4,
                       what: "(e) fill pre-cropped: frame = full canvas")
        try approxRect(efl.crop, CGRect(x: fillX, y: 0, width: fillW, height: 1), tol: 1e-4,
                       what: "(e) fill pre-cropped: crop composed from visible aspect (stays inside existing crop)")
        // Guard: the composed crop must remain within the original crop bounds.
        guard efl.crop.minX >= preCrop.minX - 1e-6, efl.crop.maxX <= preCrop.maxX + 1e-6 else {
            throw SelfTestError.mismatch("(e) fill pre-cropped: composed crop \(efl.crop) escaped existing crop \(preCrop)")
        }

        // .fit: crop unchanged; frame = centered band of the *visible* aspect.
        // Since the crop halves the width, visible content is twice as tall as
        // the full source → the fit band is twice the un-cropped band height.
        let eFit = VerticalScene(from: croppedScene, using: ReframeMap(hero: .none, others: .fit))
        let eftl = eFit.layers[0]
        let fitH = Av / Ae
        try approxRect(eftl.frame, CGRect(x: 0, y: (1 - fitH) / 2, width: 1, height: fitH), tol: 1e-4,
                       what: "(e) fit pre-cropped: band = centered visible aspect")
        try approxRect(eftl.crop, preCrop, tol: 1e-4, what: "(e) fit pre-cropped: crop unchanged")
        results.append("(e) pre-cropped layer: .fill composes crop (w=\(String(format: "%.4f", fillW))), .fit bands the visible aspect (h=\(String(format: "%.4f", fitH))) — PASS")

        // ============================================================
        // (f) F8: a degenerate sourceAspect must not yield NaN/zero uniforms.
        // A 0 / NaN / inf per-source aspect falls back to the geometry default.
        // ============================================================
        for bad in [CGFloat(0), -4, .nan, .infinity] {
            let geoBad = ReframeGeometry(sourceAspect: [SourceID("f.src"): bad])
            let resolved = geoBad.aspect(for: SourceID("f.src"))
            guard resolved.isFinite, resolved > 0, resolved == geoBad.horizontalAspect else {
                throw SelfTestError.mismatch("(f) bad sourceAspect \(bad) resolved to \(resolved), expected fallback \(geoBad.horizontalAspect)")
            }
            let crop = Reframe.fillCrop(existing: CGRect(x: 0, y: 0, width: 1, height: 1),
                                        sourceAspect: bad, verticalAspect: Av)
            guard crop.width.isFinite, crop.height.isFinite, crop.width > 0, crop.height > 0 else {
                throw SelfTestError.mismatch("(f) fillCrop(bad=\(bad)) produced degenerate crop \(crop)")
            }
        }
        results.append("(f) F8 aspect validation: 0/neg/NaN/inf sourceAspect → geometry-default fallback, no NaN crop — PASS")

        print("ComposeSelfTest: ALL PASS")
        for r in results { print("  \(r)") }
    }

    // MARK: - Test-only helpers

    private static func fillBGRA(_ buffer: CVPixelBuffer, b: UInt8, g: UInt8, r: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        for row in 0..<h {
            let rb = base + row * bpr
            for col in 0..<w {
                let p = rb + col * 4
                p[0] = b; p[1] = g; p[2] = r; p[3] = 255
            }
        }
    }

    private static func expect(_ frame: VideoFrame, x: Int, y: Int,
                               r: Int, g: Int, b: Int, tol: Int, what: String) throws {
        let buffer = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw SelfTestError.setupFailed("no base address on program buffer")
        }
        let p = base.assumingMemoryBound(to: UInt8.self) + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        let (gotB, gotG, gotR) = (Int(p[0]), Int(p[1]), Int(p[2]))
        guard abs(gotR - r) <= tol, abs(gotG - g) <= tol, abs(gotB - b) <= tol else {
            throw SelfTestError.mismatch("\(what) at (\(x),\(y)): got RGB(\(gotR),\(gotG),\(gotB)), expected RGB(\(r),\(g),\(b)) ±\(tol)")
        }
    }

    private static func approxRect(_ got: CGRect, _ want: CGRect, tol: CGFloat, what: String) throws {
        guard abs(got.origin.x - want.origin.x) <= tol, abs(got.origin.y - want.origin.y) <= tol,
              abs(got.size.width - want.size.width) <= tol, abs(got.size.height - want.size.height) <= tol else {
            throw SelfTestError.mismatch("\(what): got \(got), expected \(want) ±\(tol)")
        }
    }

    private static func one(_ scene: Scene, _ what: String, _ pred: (Scene) -> Bool) throws {
        guard pred(scene) else { throw SelfTestError.mismatch("\(what): scene layers = \(scene.layers.map(\.sourceID))") }
    }
}
