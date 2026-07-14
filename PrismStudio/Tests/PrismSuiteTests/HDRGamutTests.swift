import CoreMedia
import CoreVideo
import Foundation
import Metal
import XCTest

import PrismCompositor
import PrismCore

/// MED-10 — the HDR compositor tagged its output Rec.2020 / BT.2100-HLG but did
/// NO Rec.709→Rec.2020 gamut conversion, so a downstream HDR consumer read
/// 709-primary pixels as if they were Rec.2020 (wrong hue/saturation). The fix
/// gamut-rotates 709→2020 primaries in linear light before the HLG OETF, making
/// the Rec.2020 tag TRUE while preserving the neutral axis and transfer.
///
/// Oracle is an INDEPENDENT hand-derived pipeline (709 EOTF → 709→2020 matrix →
/// 709 OETF → HLG OETF), not the shader. NON-TAUTOLOGY: a chromatic color's
/// output matches the ROTATED oracle and is measurably DIFFERENT from the
/// unrotated (naive) value; a neutral gray is unchanged by the rotation.
final class HDRGamutTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    // Independent transfer/gamut oracle -----------------------------------------
    // finding-10: the transfer is decode-to-LINEAR → (rotate in linear) → HLG OETF
    // on the LINEAR value (NO 709-OETF re-encode before HLG).
    private func eotf709(_ v: Double) -> Double { v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1.0 / 0.45) }
    private func sat(_ v: Double) -> Double { min(max(v, 0), 1) }
    private func hlgOETF(_ e: Double) -> Double {
        let e = max(e, 0)
        return e <= 1.0 / 12.0 ? (3 * e).squareRoot()
                               : 0.17883277 * log(12 * e - 0.28466892) + 0.55991073
    }
    /// Display-referred 709 gamma triple → LINEAR Rec.2020 (rotate) or LINEAR 709.
    private func sceneLinear2020(_ rgb: (Double, Double, Double), rotate: Bool) -> (Double, Double, Double) {
        var (r, g, b) = (eotf709(rgb.0), eotf709(rgb.1), eotf709(rgb.2))
        if rotate {
            (r, g, b) = (0.627404 * r + 0.329283 * g + 0.043313 * b,
                         0.069097 * r + 0.919540 * g + 0.011362 * b,
                         0.016391 * r + 0.088013 * g + 0.895595 * b)
        }
        return (sat(r), sat(g), sat(b))
    }
    /// Full oracle: BGRA bytes → expected 10-bit (B,G,R) channels of the HDR output.
    private func oracle(r: Int, g: Int, b: Int, rotate: Bool) -> (b: Int, g: Int, r: Int) {
        let lin = sceneLinear2020((Double(r) / 255, Double(g) / 255, Double(b) / 255), rotate: rotate)
        func ch(_ v: Double) -> Int { Int((hlgOETF(v) * 1023).rounded()) }
        return (ch(lin.2), ch(lin.1), ch(lin.0)) // packed order B,G,R
    }

    // ---------------------------------------------------------------------------
    private func fillBGRA(_ buffer: CVPixelBuffer, r: UInt8, g: UInt8, b: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<CVPixelBufferGetHeight(buffer) {
            for col in 0..<CVPixelBufferGetWidth(buffer) {
                let p = base + row * bpr + col * 4
                p[0] = b; p[1] = g; p[2] = r; p[3] = 255
            }
        }
    }
    private func read10(_ frame: VideoFrame, x: Int, y: Int) -> (b: Int, g: Int, r: Int) {
        let buf = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let word = CVPixelBufferGetBaseAddress(buf)!
            .advanced(by: y * CVPixelBufferGetBytesPerRow(buf) + x * 4)
            .loadUnaligned(as: UInt32.self)
        return (Int(word & 0x3FF), Int((word >> 10) & 0x3FF), Int((word >> 20) & 0x3FF))
    }

    private func compositeHDR(_ compositor: MetalCompositor, w: Int, h: Int,
                              r: UInt8, g: UInt8, b: UInt8) throws -> (b: Int, g: Int, r: Int) {
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_32BGRA)
        let buf = try pool.makeBuffer()
        fillBGRA(buf, r: r, g: g, b: b)
        let sid = SourceID("c")
        let scene = Scene(name: "s", layers: [Layer(sourceID: sid)])
        let prog = try compositor.composite(frames: [sid: VideoFrame(pixelBuffer: buf, pts: HouseClock.now(), source: sid)],
                                            scene: scene, pts: HouseClock.now())
        XCTAssertEqual(prog.pixelFormat, kCVPixelFormatType_ARGB2101010LEPacked)
        return read10(prog, x: w / 2, y: h / 2)
    }

    /// A chromatic 709 input's HDR output matches the ROTATED (709→2020) oracle
    /// and is measurably different from the unrotated value — proving the pixels
    /// are now consistent with the Rec.2020 primaries tag.
    func testChromaticOutputMatchesRotatedOracleNotNaive() throws {
        let w = 64, h = 64
        let compositor = try MetalCompositor(device: try device(), width: w, height: h, colorMode: .hdr)

        for (r, g, b) in [(230, 40, 40), (40, 210, 60), (50, 60, 220), (200, 180, 40)] {
            let got = try compositeHDR(compositor, w: w, h: h, r: UInt8(r), g: UInt8(g), b: UInt8(b))
            let rotated = oracle(r: r, g: g, b: b, rotate: true)
            let naive = oracle(r: r, g: g, b: b, rotate: false)

            XCTAssertLessThanOrEqual(abs(got.r - rotated.r), 8, "R \(got) vs rotated oracle \(rotated) for (\(r),\(g),\(b))")
            XCTAssertLessThanOrEqual(abs(got.g - rotated.g), 8, "G \(got) vs rotated oracle \(rotated)")
            XCTAssertLessThanOrEqual(abs(got.b - rotated.b), 8, "B \(got) vs rotated oracle \(rotated)")

            // Non-tautology: the rotation actually changed the pixels (a chromatic
            // color differs from the naive no-rotation encode by a real margin).
            let delta = abs(rotated.r - naive.r) + abs(rotated.g - naive.g) + abs(rotated.b - naive.b)
            XCTAssertGreaterThan(delta, 20, "rotated vs naive oracle too close (\(rotated) vs \(naive)) — not a real test")
        }
    }

    /// The neutral axis is preserved: a gray 709 input encodes identically whether
    /// or not the gamut rotation runs (709 and 2020 share the D65 white point), so
    /// the HLG mid-tone proof is unaffected.
    func testNeutralGrayUnchangedByGamutRotation() throws {
        let w = 32, h = 32
        let compositor = try MetalCompositor(device: try device(), width: w, height: h, colorMode: .hdr)
        let got = try compositeHDR(compositor, w: w, h: h, r: 128, g: 128, b: 128)
        let rotated = oracle(r: 128, g: 128, b: 128, rotate: true)
        let naive = oracle(r: 128, g: 128, b: 128, rotate: false)
        XCTAssertEqual(rotated.r, naive.r, "gray must be a rotation no-op in the oracle")
        for (got, want) in [(got.b, rotated.b), (got.g, rotated.g), (got.r, rotated.r)] {
            XCTAssertLessThanOrEqual(abs(got - want), 6, "gray channel \(got) vs oracle \(want)")
        }
    }
}
