import CoreVideo
import Foundation
import Metal
import XCTest

import PrismCompositor
import PrismCore

/// GPU-vs-CPU verification + timing for the per-source effect stages moved from
/// CoreGraphics to the GPU (`SourceEffectGPU`). Proves the optimization two ways:
///
///  1. **Correctness**: each GPU pass MATCHES its CPU reference renderer
///     (`TileMask` / `StrobeEffect` / `BeatPulseRenderer` / `TileRepeatRenderer`)
///     within a mean per-channel diff tolerance at representative params.
///  2. **Timing**: the GPU pass is well under the CPU stage per frame at 1080p
///     and 4K (target sub-ms vs the measured 17–67 ms).
///
/// Also dumps a PNG of each GPU effect for the lead to eyeball.
final class SourceEffectGPUTests: XCTestCase {

    private static let dumpDir = URL(fileURLWithPath:
        "/tmp/prism_gpu_srcfx")

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    /// An eyeball-friendly, asymmetric BGRA source: a vertical gradient with an
    /// off-centre red disc and four distinct corner squares — so a scale, a
    /// mirror, or a tile reveal is obvious in the dump and a wrong resample shifts
    /// visible content.
    private func patternSource(_ canvas: FXCanvas) throws -> CVPixelBuffer {
        let w = Double(canvas.width), h = Double(canvas.height)
        return try canvas.render { ctx in
            // Vertical gradient background (teal top → dark navy bottom).
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            if let grad = CGGradient(colorsSpace: cs,
                                     colors: [RGBA(r: 0.05, g: 0.10, b: 0.30).cg,
                                              RGBA(r: 0.10, g: 0.75, b: 0.75).cg] as CFArray,
                                     locations: [0, 1]) {
                ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h), options: [])
            } else {
                ctx.setFillColor(RGBA(r: 0.1, g: 0.4, b: 0.5).cg); ctx.fill(canvas.rect)
            }
            // Off-centre red disc.
            ctx.setFillColor(RGBA(r: 0.95, g: 0.15, b: 0.10).cg)
            ctx.fillEllipse(in: CGRect(x: w * 0.30, y: h * 0.45, width: w * 0.30, height: h * 0.30))
            // Corner squares: TL yellow, TR magenta, BL green, BR white (bottom-left origin).
            let sq = min(w, h) * 0.14
            let corners: [(Double, Double, RGBA)] = [
                (0, h - sq, RGBA(r: 1, g: 0.9, b: 0.1)),   // visual top-left
                (w - sq, h - sq, RGBA(r: 1, g: 0.1, b: 0.9)), // visual top-right
                (0, 0, RGBA(r: 0.1, g: 0.9, b: 0.2)),      // visual bottom-left
                (w - sq, 0, RGBA(r: 1, g: 1, b: 1)),       // visual bottom-right
            ]
            for (x, y, c) in corners {
                ctx.setFillColor(c.cg)
                ctx.fill(CGRect(x: x, y: y, width: sq, height: sq))
            }
        }
    }

    /// Median wall-clock ms of `block` over `iters` (one warmup discarded).
    private func medianMS(_ iters: Int, _ block: () throws -> Void) rethrows -> Double {
        try block()   // warmup
        var samples: [Double] = []
        for _ in 0..<iters {
            let t0 = DispatchTime.now().uptimeNanoseconds
            try block()
            let t1 = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(t1 - t0) / 1_000_000)
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    // MARK: - Correctness: GPU matches the CPU reference renderers

    func testTileMaskGPUMatchesCPU() throws {
        let W = 640, H = 360, rows = 6, cols = 8
        let gpu = try SourceEffectGPU(device: device(), width: W, height: H)
        let canvas = try FXCanvas(width: W, height: H)
        let cpu = try TileMask(width: W, height: H)
        let src = try patternSource(canvas)

        let cases: [(String, TileMaskMode, Double, Double)] = [
            ("blockDissolve", .blockDissolve(seed: 42), 0.5, 0.0),
            ("gridWipe.right", .gridWipe(direction: .right), 0.5, 0.1),
            ("checkerboard", .checkerboard, 0.5, 0.0),
            ("tileReveal", .tileReveal, 0.5, 0.2),
            ("tileFlicker", .tileFlicker(seed: 5), 0.35, 0.1),
        ]
        for (name, mode, phase, soft) in cases {
            let g = try gpu.tileMask(source: src, rows: rows, cols: cols, mode: mode, phase: phase, softness: soft)
            let c = try cpu.apply(to: src, rows: rows, cols: cols, mode: mode, phase: phase, softness: soft)
            // ALPHA-AWARE: guards the premultiplied transparent-hole invariant —
            // a hole clobbered to opaque black keeps near-black BGR and would slip
            // past the BGR-only meanDiff, but spikes the alpha channel here.
            let d = FXCanvas.meanDiffWithAlpha(g, c, step: 4)
            print("TileMask \(name): GPU-vs-CPU meanDiffWithAlpha \(d)")
            XCTAssertLessThan(d, 0.005, "TileMask \(name) GPU-vs-CPU meanDiffWithAlpha \(d) too high")
        }
    }

    func testStrobeGPUMatchesCPU() throws {
        let W = 640, H = 360
        let gpu = try SourceEffectGPU(device: device(), width: W, height: H)
        let canvas = try FXCanvas(width: W, height: H)
        let cpu = try StrobeEffect(width: W, height: H)
        let src = try patternSource(canvas)

        for (phase, intensity, color, name) in [
            (0.0, 0.8, RGBA.white, "downbeat white 0.8"),
            (0.3, 1.0, RGBA(r: 1, g: 0.2, b: 0.2), "phase0.3 red"),
            (0.6, 0.5, RGBA.white, "phase0.6 white 0.5"),
        ] as [(Double, Double, RGBA, String)] {
            let g = try gpu.strobe(source: src, phase: phase, intensity: intensity, color: color)
            let c = try cpu.apply(to: src, phase: phase, intensity: intensity, color: color)
            let d = FXCanvas.meanDiff(g, c, step: 4)
            print("Strobe \(name): GPU-vs-CPU meanDiff \(d)")
            XCTAssertLessThan(d, 0.005, "Strobe \(name) GPU-vs-CPU meanDiff \(d) too high")
        }
    }

    func testBeatPulseGPUMatchesCPU() throws {
        let W = 640, H = 360
        let gpu = try SourceEffectGPU(device: device(), width: W, height: H)
        let canvas = try FXCanvas(width: W, height: H)
        let cpu = try BeatPulseRenderer(width: W, height: H)
        let src = try patternSource(canvas)
        let pulse = BeatPulse.default

        for (phase, intensity, style, name) in [
            (0.0, 1.0, BeatPulseStyle.bump, "downbeat bump"),
            (0.1, 1.5, BeatPulseStyle.bumpShake, "phase0.1 bumpShake"),
            (0.05, 1.0, BeatPulseStyle.shake, "phase0.05 shake"),
        ] {
            let t = pulse.pulse(phase: phase, intensity: intensity, style: style)
            let g = try gpu.beatPulse(source: src, transform: t)
            let c = try cpu.render(source: src, transform: t)
            let d = FXCanvas.meanDiff(g, c, step: 4)
            print("BeatPulse \(name) scale=\(t.scale) dx=\(t.dx) dy=\(t.dy): GPU-vs-CPU meanDiff \(d)")
            XCTAssertLessThan(d, 0.005, "BeatPulse \(name) GPU-vs-CPU meanDiff \(d) too high")
        }
    }

    func testVideoWallGPUMatchesCPU() throws {
        let W = 640, H = 360
        let gpu = try SourceEffectGPU(device: device(), width: W, height: H)
        let canvas = try FXCanvas(width: W, height: H)
        let cpu = try TileRepeatRenderer(width: W, height: H)
        let src = try patternSource(canvas)

        for (rows, cols, mirror, name) in [
            (3, 4, false, "3x4 plain"),
            (3, 4, true, "3x4 mirror"),
            (2, 2, true, "2x2 mirror"),
        ] {
            let g = try gpu.videoWall(source: src, rows: rows, cols: cols, mirror: mirror)
            let c = try cpu.render(source: src, rows: rows, cols: cols, mirror: mirror)
            let d = FXCanvas.meanDiff(g, c, step: 4)
            print("VideoWall \(name): GPU-vs-CPU meanDiff \(d)")
            XCTAssertLessThan(d, 0.005, "VideoWall \(name) GPU-vs-CPU meanDiff \(d) too high")
        }
    }

    // MARK: - YUV input (live camera/screen/link) — the missing coverage

    /// A live camera/screen/link source emits bi-planar 420v/420f, NOT BGRA. The
    /// effect must BT.709-decode it to BGRA first (byte-exact with the
    /// compositor's own layer decode) before the tile/strobe/pulse/wall math —
    /// else luma is read as BGRA and color+alpha corrupt. These feed a known solid
    /// 420f AND 420v frame through every effect and check the decoded BGRA color,
    /// the transparent tile holes (alpha-aware), and agreement with the
    /// compositor's layer path.

    /// BT.709 decode mirror (matches `prism_srcfx_yuv_to_bgra` / the compositor's
    /// `prism_layer_fragment_yuv`) → straight BGRA bytes, for absolute assertions.
    private static func expectedBGRA(fullRange: Bool, luma: Int, cb: Int, cr: Int) -> (b: Int, g: Int, r: Int) {
        let y = Double(luma) / 255, x = Double(cb - 128) / 255, z = Double(cr - 128) / 255
        let r: Double, g: Double, bb: Double
        if fullRange {
            r = y + 1.5748 * z; g = y - 0.1873 * x - 0.4681 * z; bb = y + 1.8556 * x
        } else {
            let yv = 1.1644 * (y - 16.0 / 255)
            r = yv + 1.7927 * z; g = yv - 0.2132 * x - 0.5329 * z; bb = yv + 2.1124 * x
        }
        func b8(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return (b8(bb), b8(g), b8(r))
    }

    /// Build a solid bi-planar YUV frame (420f full-range or 420v video-range),
    /// IOSurface-backed via `PixelBufferPool`.
    private func makeYUV(_ w: Int, _ h: Int, fullRange: Bool,
                         luma: UInt8, cb: UInt8, cr: UInt8) throws -> CVPixelBuffer {
        let fmt = fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: fmt, minimumBufferCount: 1)
        let buffer = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<h { memset(yBase + y * yRow, Int32(luma), w) }
        let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let cRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let cW = (w + 1) / 2, cH = (h + 1) / 2
        for y in 0..<cH { let row = cBase + y * cRow; for x in 0..<cW { row[x * 2] = cb; row[x * 2 + 1] = cr } }
        return buffer
    }

    /// Raw (premultiplied) BGRA bytes at a pixel — for exact color/alpha reads.
    private func rawBGRA(_ buf: CVPixelBuffer, x: Int, y: Int) -> (b: Int, g: Int, r: Int, a: Int) {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let p = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self) + y * bpr + x * 4
        return (Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3]))
    }

    /// A YUV frame run through an identity-ish effect must decode to the RIGHT
    /// opaque BGRA color — matching both the closed-form BT.709 result AND the
    /// compositor's own YUV layer composite of the same frame.
    func testYUVDecodeColorMatchesExpectedAndCompositor() throws {
        let W = 320, H = 240
        let dev = try device()
        let gpu = try SourceEffectGPU(device: dev, width: W, height: H)
        let compositor = try MetalCompositor(device: dev, width: W, height: H)

        // (label, fullRange, Y, Cb, Cr)
        let cases: [(String, Bool, UInt8, UInt8, UInt8)] = [
            ("420f reddish", true, 128, 100, 200),
            ("420v teal-ish", false, 140, 112, 160),
            ("420f gray", true, 180, 128, 128),
        ]
        for (name, full, y, cb, cr) in cases {
            let yuv = try makeYUV(W, H, fullRange: full, luma: y, cb: cb, cr: cr)
            // Identity effect: 1×1 videoWall samples the full decoded frame → the
            // decoded color, alpha forced opaque.
            let out = try gpu.videoWall(source: yuv, rows: 1, cols: 1, mirror: false)
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(out), kCVPixelFormatType_32BGRA)
            let got = rawBGRA(out, x: W / 2, y: H / 2)
            let exp = Self.expectedBGRA(fullRange: full, luma: Int(y), cb: Int(cb), cr: Int(cr))
            print("YUV \(name): decoded BGRA=(\(got.b),\(got.g),\(got.r)) a=\(got.a) expected=(\(exp.b),\(exp.g),\(exp.r))")
            XCTAssertEqual(got.a, 255, "YUV \(name) must decode opaque")
            XCTAssertLessThanOrEqual(abs(got.b - exp.b), 2, "YUV \(name) B off")
            XCTAssertLessThanOrEqual(abs(got.g - exp.g), 2, "YUV \(name) G off")
            XCTAssertLessThanOrEqual(abs(got.r - exp.r), 2, "YUV \(name) R off")

            // Agreement with the compositor's own YUV layer path: composite the
            // same frame as a single opaque full-screen layer, compare centre.
            let id = SourceID("yuv.\(name)")
            let scene = Scene(name: name, layers: [Layer(sourceID: id, zIndex: 0)])
            let program = try compositor.composite(
                frames: [id: VideoFrame(pixelBuffer: yuv, pts: HouseClock.now(), source: id)],
                scene: scene, pts: HouseClock.now())
            let comp = rawBGRA(program.pixelBuffer, x: W / 2, y: H / 2)
            XCTAssertLessThanOrEqual(abs(got.b - comp.b), 2, "YUV \(name) B ≠ compositor layer")
            XCTAssertLessThanOrEqual(abs(got.g - comp.g), 2, "YUV \(name) G ≠ compositor layer")
            XCTAssertLessThanOrEqual(abs(got.r - comp.r), 2, "YUV \(name) R ≠ compositor layer")
        }
    }

    /// Every effect (tileMask/strobe/beatPulse/videoWall) on a 420f AND a 420v
    /// frame must equal that effect run on the SAME frame decoded to BGRA — i.e.
    /// the YUV pre-pass changes nothing but the input format. For tileMask this is
    /// ALPHA-AWARE, so a hole clobbered to opaque black (instead of true alpha-0)
    /// fails; it also asserts genuine transparent holes are present.
    func testYUVPathMatchesCPUOnDecodedForAllEffects() throws {
        let W = 320, H = 240, rows = 4, cols = 5
        let dev = try device()
        let gpu = try SourceEffectGPU(device: dev, width: W, height: H)
        let tile = try TileMask(width: W, height: H)
        let strobeCPU = try StrobeEffect(width: W, height: H)
        let pulseCPU = try BeatPulseRenderer(width: W, height: H)
        let wallCPU = try TileRepeatRenderer(width: W, height: H)

        for (label, full, y, cb, cr) in [
            ("420f", true, UInt8(128), UInt8(100), UInt8(200)),
            ("420v", false, UInt8(140), UInt8(112), UInt8(160)),
        ] {
            let yuv = try makeYUV(W, H, fullRange: full, luma: y, cb: cb, cr: cr)
            // The decoded BGRA reference (identity YUV→BGRA), used as the CPU input
            // so any residual diff is the effect math alone, not the color decode.
            let decoded = try gpu.videoWall(source: yuv, rows: 1, cols: 1, mirror: false)

            // TileMask (checkerboard fully removes half the tiles → true alpha-0).
            let gTile = try gpu.tileMask(source: yuv, rows: rows, cols: cols, mode: .checkerboard, phase: 0.5, softness: 0)
            let cTile = try tile.apply(to: decoded, rows: rows, cols: cols, mode: .checkerboard, phase: 0.5, softness: 0)
            let dTile = FXCanvas.meanDiffWithAlpha(gTile, cTile, step: 2)
            print("YUV \(label) tileMask meanDiffWithAlpha=\(dTile)")
            XCTAssertLessThan(dTile, 0.005, "YUV \(label) tileMask ≠ CPU-on-decoded (color or hole alpha)")
            // Genuine transparent holes present (not opaque black).
            var minA = 255, holeIsBlack = false
            for gy in stride(from: 0, to: H, by: 3) {
                for gx in stride(from: 0, to: W, by: 3) {
                    let px = rawBGRA(gTile, x: gx, y: gy)
                    minA = min(minA, px.a)
                    if px.a == 255 && px.b == 0 && px.g == 0 && px.r == 0 { holeIsBlack = true }
                }
            }
            XCTAssertEqual(minA, 0, "YUV \(label) tileMask holes must be TRUE alpha-0 (transparent)")
            XCTAssertFalse(holeIsBlack, "YUV \(label) tileMask hole rendered opaque black — the premult regression")

            // Strobe (opaque flash).
            let gStr = try gpu.strobe(source: yuv, phase: 0.3, intensity: 0.8, color: RGBA(r: 1, g: 0.2, b: 0.2))
            let cStr = try strobeCPU.apply(to: decoded, phase: 0.3, intensity: 0.8, color: RGBA(r: 1, g: 0.2, b: 0.2))
            let dStr = FXCanvas.meanDiffWithAlpha(gStr, cStr, step: 2)
            print("YUV \(label) strobe meanDiffWithAlpha=\(dStr)")
            XCTAssertLessThan(dStr, 0.005, "YUV \(label) strobe ≠ CPU-on-decoded")

            // BeatPulse (opaque scale+shake).
            let t = BeatPulse.default.pulse(phase: 0.1, intensity: 1.5, style: .bumpShake)
            let gBP = try gpu.beatPulse(source: yuv, transform: t)
            let cBP = try pulseCPU.render(source: decoded, transform: t)
            let dBP = FXCanvas.meanDiffWithAlpha(gBP, cBP, step: 2)
            print("YUV \(label) beatPulse meanDiffWithAlpha=\(dBP)")
            XCTAssertLessThan(dBP, 0.005, "YUV \(label) beatPulse ≠ CPU-on-decoded")

            // VideoWall (opaque repeat).
            let gVW = try gpu.videoWall(source: yuv, rows: 3, cols: 4, mirror: true)
            let cVW = try wallCPU.render(source: decoded, rows: 3, cols: 4, mirror: true)
            let dVW = FXCanvas.meanDiffWithAlpha(gVW, cVW, step: 2)
            print("YUV \(label) videoWall meanDiffWithAlpha=\(dVW)")
            XCTAssertLessThan(dVW, 0.005, "YUV \(label) videoWall ≠ CPU-on-decoded")
        }
    }

    /// An unsupported pixel format must THROW (so the app can fall back), never
    /// silently corrupt.
    func testUnsupportedFormatThrows() throws {
        let W = 64, H = 48
        let gpu = try SourceEffectGPU(device: try device(), width: W, height: H)
        // 422 is neither BGRA nor the supported biplanar 420 pair.
        let pool = try PixelBufferPool(width: W, height: H,
                                       pixelFormat: kCVPixelFormatType_422YpCbCr8,
                                       minimumBufferCount: 1)
        let buf = try pool.makeBuffer()
        XCTAssertThrowsError(try gpu.strobe(source: buf, phase: 0, intensity: 0.5)) { err in
            guard case CompositorError.unsupportedInputFormat = err else {
                return XCTFail("expected .unsupportedInputFormat, got \(err)")
            }
        }
    }

    // MARK: - Timing: GPU pass vs CPU stage at 1080p and 4K

    func testTimingCPUvsGPU() throws {
        let dev = try device()
        let iters = 9
        struct Row { let effect: String; let res: String; let cpu: Double; let gpu: Double }
        var rowsOut: [Row] = []

        for (label, W, H) in [("1080p", 1920, 1080), ("4K", 3840, 2160)] {
            let canvas = try FXCanvas(width: W, height: H)
            let src = try patternSource(canvas)
            let gpu = try SourceEffectGPU(device: dev, width: W, height: H)

            // TileMask
            let tmCPU = try TileMask(width: W, height: H)
            let cTM = try medianMS(iters) { _ = try tmCPU.apply(to: src, rows: 6, cols: 8,
                                                                mode: .gridWipe(direction: .right), phase: 0.5, softness: 0.1) }
            let gTM = try medianMS(iters) { _ = try gpu.tileMask(source: src, rows: 6, cols: 8,
                                                                mode: .gridWipe(direction: .right), phase: 0.5, softness: 0.1) }
            rowsOut.append(Row(effect: "TileMask", res: label, cpu: cTM, gpu: gTM))

            // Strobe
            let stCPU = try StrobeEffect(width: W, height: H)
            let cST = try medianMS(iters) { _ = try stCPU.apply(to: src, phase: 0.2, intensity: 0.8) }
            let gST = try medianMS(iters) { _ = try gpu.strobe(source: src, phase: 0.2, intensity: 0.8) }
            rowsOut.append(Row(effect: "Strobe", res: label, cpu: cST, gpu: gST))

            // BeatPulse
            let bpCPU = try BeatPulseRenderer(width: W, height: H)
            let t = BeatPulse.default.pulse(phase: 0.1, intensity: 1.5, style: .bumpShake)
            let cBP = try medianMS(iters) { _ = try bpCPU.render(source: src, transform: t) }
            let gBP = try medianMS(iters) { _ = try gpu.beatPulse(source: src, transform: t) }
            rowsOut.append(Row(effect: "BeatPulse", res: label, cpu: cBP, gpu: gBP))

            // VideoWall
            let vwCPU = try TileRepeatRenderer(width: W, height: H)
            let cVW = try medianMS(iters) { _ = try vwCPU.render(source: src, rows: 3, cols: 4, mirror: true) }
            let gVW = try medianMS(iters) { _ = try gpu.videoWall(source: src, rows: 3, cols: 4, mirror: true) }
            rowsOut.append(Row(effect: "VideoWall", res: label, cpu: cVW, gpu: gVW))
        }

        print("── Per-source effect timing (median ms/frame) ──")
        print("effect      res     CPU(ms)     GPU(ms)   speedup")
        for r in rowsOut {
            print(String(format: "%-10@ %-6@ %10.3f %10.3f %7.1fx",
                         r.effect as NSString, r.res as NSString, r.cpu, r.gpu, r.cpu / max(r.gpu, 1e-6)))
            // The win: GPU is faster than CPU and comfortably under a 60fps budget.
            XCTAssertLessThan(r.gpu, r.cpu, "\(r.effect) @\(r.res): GPU (\(r.gpu)ms) not faster than CPU (\(r.cpu)ms)")
            XCTAssertLessThan(r.gpu, 8.0, "\(r.effect) @\(r.res): GPU pass \(r.gpu)ms exceeds an 8ms/frame budget")
        }
    }

    // MARK: - PNG dumps for the lead to eyeball

    func testDumpGPUEffectPNGs() throws {
        let W = 640, H = 360
        let dev = try device()
        let gpu = try SourceEffectGPU(device: dev, width: W, height: H)
        let canvas = try FXCanvas(width: W, height: H)
        let src = try patternSource(canvas)
        try? FileManager.default.createDirectory(at: Self.dumpDir, withIntermediateDirectories: true)
        _ = try? FXCanvas.writePNG(src, to: Self.dumpDir.appendingPathComponent("00_source.png"))

        // TileMask holes composited over an opaque orange background (so the
        // reveal is visible, not just transparent PNG).
        let compositor = try MetalCompositor(device: dev, width: W, height: H)
        let bgID = SourceID("srcfx.bg"), topID = SourceID("srcfx.top")
        let bg = VideoFrame(pixelBuffer: try canvas.solid(RGBA(r: 0.95, g: 0.55, b: 0.10)),
                            pts: HouseClock.now(), source: bgID)
        for (name, mode, phase, soft) in [
            ("gridwipe_right_p50", TileMaskMode.gridWipe(direction: .right), 0.5, 0.1),
            ("blockdissolve_s42_p50", TileMaskMode.blockDissolve(seed: 42), 0.5, 0.0),
            ("tileflicker_s5_p35", TileMaskMode.tileFlicker(seed: 5), 0.35, 0.1),
        ] as [(String, TileMaskMode, Double, Double)] {
            let holed = try gpu.tileMask(source: src, rows: 6, cols: 8, mode: mode, phase: phase, softness: soft)
            let scene = Scene(name: name, layers: [
                Layer(sourceID: bgID, zIndex: 0),
                Layer(sourceID: topID, zIndex: 1, premultipliedAlpha: true),
            ])
            let program = try compositor.composite(
                frames: [bgID: bg, topID: VideoFrame(pixelBuffer: holed, pts: HouseClock.now(), source: topID)],
                scene: scene, pts: HouseClock.now())
            _ = try? FXCanvas.writePNG(program.pixelBuffer, to: Self.dumpDir.appendingPathComponent("tilemask_\(name)_over_orange.png"))
        }

        // Strobe / BeatPulse / VideoWall are opaque — dump directly.
        let strobe = try gpu.strobe(source: src, phase: 0.0, intensity: 0.85)
        _ = try? FXCanvas.writePNG(strobe, to: Self.dumpDir.appendingPathComponent("strobe_downbeat_white.png"))

        let t = BeatPulse.default.pulse(phase: 0.0, intensity: 1.4, style: .bumpShake)
        let pulse = try gpu.beatPulse(source: src, transform: t)
        _ = try? FXCanvas.writePNG(pulse, to: Self.dumpDir.appendingPathComponent("beatpulse_downbeat_scale.png"))

        let wall = try gpu.videoWall(source: src, rows: 3, cols: 4, mirror: true)
        _ = try? FXCanvas.writePNG(wall, to: Self.dumpDir.appendingPathComponent("videowall_3x4_mirror.png"))

        print("GPU source-FX PNGs written to \(Self.dumpDir.path)")
    }
}
