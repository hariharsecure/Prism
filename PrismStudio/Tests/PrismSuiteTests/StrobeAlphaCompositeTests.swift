import CoreVideo
import Foundation
import Metal
import XCTest

import PrismCompositor
import PrismCore

/// N3 regression — **strobe must preserve source alpha** (Class C), the same
/// principle F4 fixed for BeatPulse.
///
/// The defect: `prism_srcfx_strobe` computed `alpha = c.a·(1−a) + a`, so a
/// fully-transparent source texel (`c.a == 0`) came out with `alpha = a` (the
/// flash amount) and a flash-coloured RGB on the beat — a keyed / cutout source's
/// transparent background flashed and partially covered the layers beneath every
/// beat. The fix modulates colour only, scaled by the source's own alpha, so a
/// transparent texel stays premultiplied-transparent while an opaque texel is
/// unchanged.
///
/// This drives the **real two-layer alpha composite** through `MetalCompositor`
/// (a keyed source strobed over a solid lower layer) and asserts the transparent
/// region reveals the LOWER layer, never the flash colour. It is a live composite,
/// not a GPU-vs-CPU parity check (the CPU oracle shared the same bug pre-fix).
final class StrobeAlphaCompositeTests: XCTestCase {

    private static let dumpDir = URL(fileURLWithPath:
        "/tmp/prism_n3_strobe")

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    /// Raw (premultiplied) BGRA bytes at a pixel.
    private func rawBGRA(_ buf: CVPixelBuffer, x: Int, y: Int) -> (b: Int, g: Int, r: Int, a: Int) {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let p = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self) + y * bpr + x * 4
        return (Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3]))
    }

    /// A keyed source: a fully-cleared (transparent) canvas with one opaque red
    /// box in the middle. Everything outside the box is premultiplied clear
    /// `(0,0,0,0)` — the "cutout / transparent-PNG background".
    private func keyedSource(_ canvas: FXCanvas) throws -> CVPixelBuffer {
        let w = Double(canvas.width), h = Double(canvas.height)
        return try canvas.render { ctx in
            ctx.setFillColor(RGBA(r: 0.95, g: 0.15, b: 0.10).cg)
            ctx.fill(CGRect(x: w * 0.40, y: h * 0.40, width: w * 0.20, height: h * 0.20))
        }
    }

    func testStrobePreservesAlphaOverLowerLayer() throws {
        let W = 640, H = 360
        let dev = try device()
        let gpu = try SourceEffectGPU(device: dev, width: W, height: H)
        let compositor = try MetalCompositor(device: dev, width: W, height: H)
        let canvas = try FXCanvas(width: W, height: H)

        let src = try keyedSource(canvas)

        // Brightest flash: phase 0 (downbeat), full intensity, white — the worst
        // case for the transparent surround (max `amount`).
        let strobed = try gpu.strobe(source: src, phase: 0.0, intensity: 1.0, color: .white)

        // Lower layer: a solid, distinctly-blue frame.
        let lower = RGBA(r: 0.20, g: 0.50, b: 0.90)
        let expLowerB = Int((0.90 * 255).rounded())
        let expLowerG = Int((0.50 * 255).rounded())
        let expLowerR = Int((0.20 * 255).rounded())
        let bgID = SourceID("n3.lower"), topID = SourceID("n3.strobe")
        let scene = Scene(name: "n3", layers: [
            Layer(sourceID: bgID, zIndex: 0),
            Layer(sourceID: topID, zIndex: 1, premultipliedAlpha: true),
        ])
        let program = try compositor.composite(
            frames: [
                bgID: VideoFrame(pixelBuffer: try canvas.solid(lower), pts: HouseClock.now(), source: bgID),
                topID: VideoFrame(pixelBuffer: strobed, pts: HouseClock.now(), source: topID),
            ],
            scene: scene, pts: HouseClock.now())

        // The four corners are in the transparent surround → must show the LOWER
        // layer, never the (white) flash. (On the buggy shader these flashed white.)
        for (name, x, y) in [("TL", 6, 6), ("TR", W - 7, 6), ("BL", 6, H - 7), ("BR", W - 7, H - 7)] {
            let px = rawBGRA(program.pixelBuffer, x: x, y: y)
            let isFlash = px.b > 160 && px.g > 160 && px.r > 160   // whitish flash leak
            XCTAssertFalse(isFlash, "N3 \(name) corner (\(px.b),\(px.g),\(px.r)) flashed white — strobe covered the transparent surround")
            XCTAssertLessThanOrEqual(abs(px.b - expLowerB), 4, "N3 \(name) B should be the lower layer, got \(px)")
            XCTAssertLessThanOrEqual(abs(px.g - expLowerG), 4, "N3 \(name) G should be the lower layer, got \(px)")
            XCTAssertLessThanOrEqual(abs(px.r - expLowerR), 4, "N3 \(name) R should be the lower layer, got \(px)")
        }

        // The centre box is opaque → it DOES flash toward white (bright, opaque).
        let mid = rawBGRA(program.pixelBuffer, x: W / 2, y: H / 2)
        XCTAssertGreaterThan(mid.r, 180, "N3 centre opaque source must still flash bright, got \(mid)")
        XCTAssertGreaterThan(mid.g, 120, "N3 centre must brighten toward white, got \(mid)")

        try? FileManager.default.createDirectory(at: Self.dumpDir, withIntermediateDirectories: true)
        _ = try? FXCanvas.writePNG(program.pixelBuffer,
                                   to: Self.dumpDir.appendingPathComponent("strobe_keyed_over_blue.png"))
    }

    /// The common case (a fully-opaque source) must be visually unchanged by the
    /// alpha-preserving fix: the flash still brightens the pixels and the output
    /// stays fully opaque (alpha 255).
    func testStrobeOnOpaqueSourceStaysOpaqueAndFlashes() throws {
        let W = 320, H = 180
        let dev = try device()
        let gpu = try SourceEffectGPU(device: dev, width: W, height: H)
        let canvas = try FXCanvas(width: W, height: H)

        let base = RGBA(r: 0.20, g: 0.30, b: 0.40)
        let opaque = try canvas.solid(base)

        // No flash (phase ~1 → envelope ≈ 0): output equals the source, opaque.
        let noFlash = try gpu.strobe(source: opaque, phase: 0.999, intensity: 1.0, color: .white)
        let n = rawBGRA(noFlash, x: W / 2, y: H / 2)
        XCTAssertEqual(n.a, 255, "opaque source must stay opaque with no flash")
        XCTAssertEqual(n.r, Int((0.20 * 255).rounded()), accuracy: 3, "no-flash output must equal the source")

        // Full flash (phase 0): brightens toward white, still fully opaque.
        let flash = try gpu.strobe(source: opaque, phase: 0.0, intensity: 1.0, color: .white)
        let f = rawBGRA(flash, x: W / 2, y: H / 2)
        XCTAssertEqual(f.a, 255, "opaque source must stay opaque under a full flash")
        XCTAssertGreaterThan(f.r, n.r, "the flash must brighten an opaque source")
        XCTAssertGreaterThan(f.b, n.b, "the flash must brighten an opaque source")
    }
}
