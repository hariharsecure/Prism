import CoreVideo
import Foundation
import Metal
import XCTest

import PrismCompositor
import PrismCore

/// F4 regression — **BeatPulse must preserve source alpha**.
///
/// The defect: `SourceEffectGPU.beatPulse` (and its CPU oracle
/// `BeatPulseRenderer`) defaulted to an **opaque black** background, so a
/// transparent / keyed / cutout source's transparent texels — and any region the
/// scaled/shaken source did not cover — came out `out.a = 1` with black RGB. Fed
/// as a premultiplied overlay, that painted an opaque black box over the layers
/// beneath instead of letting them show through.
///
/// This drives the **real two-layer alpha composite** through `MetalCompositor`
/// (a transparent-surround source pulsed over a solid lower layer) and asserts
/// the transparent region reveals the LOWER layer, not black. A GPU-vs-CPU parity
/// test is blind to this because the CPU oracle shared the same bug — so this is
/// a live composite, not a parity check.
final class BeatPulseAlphaCompositeTests: XCTestCase {

    private static let dumpDir = URL(fileURLWithPath:
        "/tmp/prism_f4_fix")

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

    /// A transparent-surround source: a fully-cleared canvas with a single opaque
    /// red box in the middle. Everything outside the box is premultiplied clear
    /// `(0,0,0,0)` — the "transparent PNG / text surround / cutout background".
    private func transparentSource(_ canvas: FXCanvas) throws -> CVPixelBuffer {
        let w = Double(canvas.width), h = Double(canvas.height)
        return try canvas.render { ctx in
            // canvas.render already `ctx.clear`ed the whole surface → transparent.
            ctx.setFillColor(RGBA(r: 0.95, g: 0.15, b: 0.10).cg)
            ctx.fill(CGRect(x: w * 0.40, y: h * 0.40, width: w * 0.20, height: h * 0.20))
        }
    }

    func testBeatPulsePreservesAlphaOverLowerLayer() throws {
        let W = 640, H = 360
        let dev = try device()
        let gpu = try SourceEffectGPU(device: dev, width: W, height: H)
        let compositor = try MetalCompositor(device: dev, width: W, height: H)
        let canvas = try FXCanvas(width: W, height: H)

        let src = try transparentSource(canvas)

        // A shake-only pulse (scale == 1) so BOTH failure surfaces are present:
        // the transparent surround texels AND an edge strip the offset source no
        // longer covers. With the fix both stay premultiplied-transparent.
        let t = BeatPulse.default.pulse(phase: 0.05, intensity: 1.0, style: .shake)
        XCTAssertEqual(t.scale, 1, accuracy: 1e-9, "shake style must not scale (so an uncovered strip exists)")
        let pulsed = try gpu.beatPulse(source: src, transform: t)   // default background == .clear

        // Lower layer: a solid, distinctly-blue frame.
        let lower = RGBA(r: 0.20, g: 0.50, b: 0.90)
        let expLowerB = Int((0.90 * 255).rounded()), expLowerG = Int((0.50 * 255).rounded()), expLowerR = Int((0.20 * 255).rounded())
        let bgID = SourceID("f4.lower"), topID = SourceID("f4.pulse")
        let scene = Scene(name: "f4", layers: [
            Layer(sourceID: bgID, zIndex: 0),
            Layer(sourceID: topID, zIndex: 1, premultipliedAlpha: true),
        ])
        let program = try compositor.composite(
            frames: [
                bgID: VideoFrame(pixelBuffer: try canvas.solid(lower), pts: HouseClock.now(), source: bgID),
                topID: VideoFrame(pixelBuffer: pulsed, pts: HouseClock.now(), source: topID),
            ],
            scene: scene, pts: HouseClock.now())

        // The four corners are in the transparent surround → must show the LOWER
        // layer, never opaque black. (On the buggy engine these were opaque black.)
        for (name, x, y) in [("TL", 6, 6), ("TR", W - 7, 6), ("BL", 6, H - 7), ("BR", W - 7, H - 7)] {
            let px = rawBGRA(program.pixelBuffer, x: x, y: y)
            let isBlack = px.b < 12 && px.g < 12 && px.r < 12
            XCTAssertFalse(isBlack, "F4 \(name) corner (\(px.b),\(px.g),\(px.r)) is black — BeatPulse blacked out the transparent surround")
            XCTAssertLessThanOrEqual(abs(px.b - expLowerB), 4, "F4 \(name) B should be the lower layer, got \(px)")
            XCTAssertLessThanOrEqual(abs(px.g - expLowerG), 4, "F4 \(name) G should be the lower layer, got \(px)")
            XCTAssertLessThanOrEqual(abs(px.r - expLowerR), 4, "F4 \(name) R should be the lower layer, got \(px)")
        }

        // The centre box is opaque → shows the (red) source over the lower layer.
        let mid = rawBGRA(program.pixelBuffer, x: W / 2, y: H / 2)
        XCTAssertGreaterThan(mid.r, 180, "F4 centre must show the opaque red source, got \(mid)")
        XCTAssertLessThan(mid.b, 60, "F4 centre must be red (low blue), got \(mid)")

        // Eyeball dump for the lead: transparent pulse over a coloured layer.
        try? FileManager.default.createDirectory(at: Self.dumpDir, withIntermediateDirectories: true)
        _ = try? FXCanvas.writePNG(program.pixelBuffer,
                                   to: Self.dumpDir.appendingPathComponent("beatpulse_transparent_over_blue.png"))
        _ = try? FXCanvas.writePNG(pulsed,
                                   to: Self.dumpDir.appendingPathComponent("beatpulse_transparent_alpha_only.png"))
        print("F4: wrote transparent-pulse-over-layer PNG to \(Self.dumpDir.path)")
    }
}
