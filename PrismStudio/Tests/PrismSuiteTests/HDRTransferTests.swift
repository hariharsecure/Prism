import CoreMedia
import CoreVideo
import Metal
import XCTest

import PrismCompositor
import PrismCore

/// finding-10 — the HLG transfer was wrong. The shader decoded to linear, rotated
/// primaries, then RE-ENCODED with the BT.709 OETF and fed that GAMMA-CODED value
/// into the HLG OETF (which expects a LINEAR scene value). For code-value gray 128
/// that yielded ≈892/1023 instead of the standards-correct linearized-709→HLG
/// ≈765/1023. The fix decodes to LINEAR, rotates in linear light, and applies the
/// BT.2100 HLG OETF DIRECTLY to the LINEAR value (no 709-OETF re-encode).
///
/// The oracle is an INDEPENDENT from-spec computation authored HERE — the BT.709
/// EOTF, the BT.709→2020 primary matrix, and the ARIB STD-B67 / BT.2100 HLG OETF
/// as published — NOT a copy of the shader (the flagged tautology was a test that
/// reimplemented the shader's OWN gamma-into-HLG approximation).
///
/// DOCUMENTED SCOPE (asserted, not silently approximated): this is a display-
/// referred HLG encode — the [0,1] display-linear value is treated as the HLG
/// scene value, with NO scene-referred OOTF / system-gamma tone-map.
final class HDRTransferTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    // Independent from-spec references -------------------------------------------
    /// BT.709 EOTF (display gamma → linear).
    private func eotf709(_ v: Double) -> Double { v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1.0 / 0.45) }
    /// BT.2100 / ARIB STD-B67 HLG OETF on a SCENE-LINEAR value.
    private func hlgOETF(_ e: Double) -> Double {
        let e = max(e, 0)
        return e <= 1.0 / 12.0 ? (3 * e).squareRoot()
                               : 0.17883277 * log(12 * e - 0.28466892) + 0.55991073
    }
    private func sat(_ v: Double) -> Double { min(max(v, 0), 1) }
    /// The CORRECT transfer: display 709 → LINEAR → (rotate 709→2020) → HLG code.
    private func correctCode(_ disp: Double) -> Int { Int((hlgOETF(eotf709(disp)) * 1023).rounded()) }
    /// The OLD BUG: gamma-coded display value fed straight into the HLG OETF.
    private func buggyGammaIntoHLGCode(_ disp: Double) -> Int { Int((hlgOETF(disp) * 1023).rounded()) }

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
        let prog = try compositor.composite(frames: [sid: VideoFrame(pixelBuffer: buf, pts: HouseClock.now(), source: sid)],
                                            scene: Scene(name: "s", layers: [Layer(sourceID: sid)]), pts: HouseClock.now())
        XCTAssertEqual(prog.pixelFormat, kCVPixelFormatType_ARGB2101010LEPacked)
        return read10(prog, x: w / 2, y: h / 2)
    }

    /// Code-value gray 128 encodes via the LINEAR→HLG transfer (≈765), NOT the old
    /// gamma-into-HLG value (≈892). This is the headline non-tautology.
    func testGray128LinearizedNotGammaIntoHLG() throws {
        let w = 32, h = 32
        let compositor = try MetalCompositor(device: try device(), width: w, height: h, colorMode: .hdr)
        let got = try compositeHDR(compositor, w: w, h: h, r: 128, g: 128, b: 128)

        let correct = correctCode(128.0 / 255.0)     // ≈765
        let buggy = buggyGammaIntoHLGCode(128.0 / 255.0) // ≈892
        // Sanity: the two references are genuinely far apart (a real discriminator).
        XCTAssertGreaterThan(abs(correct - buggy), 100, "correct(\(correct)) vs bug(\(buggy)) too close")

        for ch in [got.b, got.g, got.r] {
            XCTAssertLessThanOrEqual(abs(ch - correct), 8, "gray channel \(ch) ≠ linear→HLG oracle \(correct)")
            XCTAssertGreaterThan(abs(ch - buggy), 60, "gray channel \(ch) matches the OLD gamma-into-HLG bug \(buggy)")
        }
        // Neutral axis: gray stays neutral (all three channels equal within rounding).
        XCTAssertLessThanOrEqual(abs(got.r - got.g) + abs(got.g - got.b), 4, "gray not neutral: \(got)")
    }

    /// The neutral axis endpoints are preserved: white → ≈1023 (HLG(EOTF(1))=1),
    /// black → ≈0, both neutral.
    func testNeutralAxisEndpointsPreserved() throws {
        let w = 32, h = 32
        let compositor = try MetalCompositor(device: try device(), width: w, height: h, colorMode: .hdr)
        let white = try compositeHDR(compositor, w: w, h: h, r: 255, g: 255, b: 255)
        for ch in [white.b, white.g, white.r] {
            XCTAssertGreaterThanOrEqual(ch, 1015, "white channel \(ch) not ≈1023 (HLG OETF(1) must be 1)")
        }
        let black = try compositeHDR(compositor, w: w, h: h, r: 0, g: 0, b: 0)
        for ch in [black.b, black.g, black.r] {
            XCTAssertLessThanOrEqual(ch, 8, "black channel \(ch) not ≈0")
        }
    }

    /// A saturated 709 primary (green) matches the full from-spec linear→2020→HLG
    /// oracle (transfer AND gamut both correct), and differs from the old
    /// gamma-into-HLG value on the dominant channel.
    func testSaturatedPrimaryMatchesLinearGamutOracle() throws {
        let w = 32, h = 32
        let compositor = try MetalCompositor(device: try device(), width: w, height: h, colorMode: .hdr)
        let got = try compositeHDR(compositor, w: w, h: h, r: 0, g: 255, b: 0)

        // Independent oracle: 709 (0,1,0) → linear (0,1,0) → 2020 linear → HLG.
        let lin709 = (eotf709(0), eotf709(1), eotf709(0))
        let l2020 = (sat(0.627404 * lin709.0 + 0.329283 * lin709.1 + 0.043313 * lin709.2),
                     sat(0.069097 * lin709.0 + 0.919540 * lin709.1 + 0.011362 * lin709.2),
                     sat(0.016391 * lin709.0 + 0.088013 * lin709.1 + 0.895595 * lin709.2))
        func code(_ v: Double) -> Int { Int((hlgOETF(v) * 1023).rounded()) }
        let want = (b: code(l2020.2), g: code(l2020.1), r: code(l2020.0))

        XCTAssertLessThanOrEqual(abs(got.r - want.r), 10, "green R \(got) vs oracle \(want)")
        XCTAssertLessThanOrEqual(abs(got.g - want.g), 10, "green G \(got) vs oracle \(want)")
        XCTAssertLessThanOrEqual(abs(got.b - want.b), 10, "green B \(got) vs oracle \(want)")
        // (The transfer discriminator lives in `testGray128…`: a near-saturated
        // primary channel sits where the gamma and linear curves both approach 1,
        // so it can't separate the transfer — a mid-tone can, and does there.)
    }
}
