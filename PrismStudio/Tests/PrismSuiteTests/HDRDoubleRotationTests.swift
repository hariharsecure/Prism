import CoreMedia
import CoreVideo
import Metal
import XCTest

import PrismCompositor
import PrismCore

/// N4 (CONFIRMED regression) — a tagged **Rec.2020** YUV source was decoded with
/// its 2020 matrix (correct), then UNCONDITIONALLY passed through the 709→2020
/// gamut rotation, so a legal Rec.2020 red was rotated a SECOND time (≈(0.792,
/// 0.231, 0.074) before HLG) — a desaturated, hue-shifted red. The fix gates the
/// rotation on the source color space: a source already in Rec.2020 passes
/// through WITHOUT re-rotation; a Rec.709 source is still correctly rotated up.
///
/// Oracle is an INDEPENDENT from-spec computation: the YCbCr→RGB inverse is
/// re-derived from the ITU luma weights (Kr/Kb), not copied from the shader's
/// rounded coefficients; the 709→2020 primary matrix + BT.709 transfer + BT.2100
/// HLG OETF are the published constants. NON-TAUTOLOGY: the 2020 output matches
/// the NO-rotation oracle and is measurably far from the double-rotated value.
final class HDRDoubleRotationTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    // MARK: - Independent from-spec oracle

    private func eotf709(_ v: Double) -> Double { v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1.0 / 0.45) }
    private func hlgOETF(_ e: Double) -> Double {
        let e = max(e, 0)
        return e <= 1.0 / 12.0 ? (3 * e).squareRoot()
                               : 0.17883277 * log(12 * e - 0.28466892) + 0.55991073
    }
    private func sat(_ v: Double) -> Double { min(max(v, 0), 1) }
    /// finding-10 transfer: display 709 gamma triple → LINEAR (rotate in linear).
    private func sceneLinear2020(_ rgb: (Double, Double, Double), rotate: Bool) -> (Double, Double, Double) {
        var (r, g, b) = (eotf709(rgb.0), eotf709(rgb.1), eotf709(rgb.2))
        if rotate {
            (r, g, b) = (0.627404 * r + 0.329283 * g + 0.043313 * b,
                         0.069097 * r + 0.919540 * g + 0.011362 * b,
                         0.016391 * r + 0.088013 * g + 0.895595 * b)
        }
        return (sat(r), sat(g), sat(b))
    }
    /// Full-range YCbCr→display-RGB, inverse RE-DERIVED from Kr/Kb (first
    /// principles, not the shader's rounded constants).
    private func decodeFull(kr: Double, kb: Double, y: Int, cb: Int, cr: Int) -> (Double, Double, Double) {
        let kg = 1 - kr - kb
        let yf = Double(y) / 255.0
        let cbf = Double(cb) / 255.0 - 0.5
        let crf = Double(cr) / 255.0 - 0.5
        let r = yf + 2 * (1 - kr) * crf
        let b = yf + 2 * (1 - kb) * cbf
        let g = (yf - kr * r - kb * b) / kg
        return (sat(r), sat(g), sat(b))
    }
    /// Full-range RGB→YCbCr bytes (also from Kr/Kb) — builds the fixture.
    private func encodeFull(kr: Double, kb: Double, r: Double, g: Double, b: Double) -> (UInt8, UInt8, UInt8) {
        let kg = 1 - kr - kb
        let y = kr * r + kg * g + kb * b
        let cb = (b - y) / (2 * (1 - kb)) + 0.5
        let cr = (r - y) / (2 * (1 - kr)) + 0.5
        func q(_ v: Double) -> UInt8 { UInt8(min(max((v * 255).rounded(), 0), 255)) }
        return (q(y), q(cb), q(cr))
    }
    /// display 709 triple → expected 10-bit (B,G,R): LINEAR (rotate?) → HLG OETF.
    private func encode(_ disp: (Double, Double, Double), rotate: Bool) -> (b: Int, g: Int, r: Int) {
        let lin = sceneLinear2020(disp, rotate: rotate)
        func ch(_ v: Double) -> Int { Int((hlgOETF(v) * 1023).rounded()) }
        return (ch(lin.2), ch(lin.1), ch(lin.0))
    }

    // MARK: - fixtures

    private func makeYUVRed(w: Int, h: Int, matrix: CFString, primaries: CFString?,
                            yByte: UInt8, cbByte: UInt8, crByte: UInt8) throws -> VideoFrame {
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        var pb: CVPixelBuffer?
        let st = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                     kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                     attrs as CFDictionary, &pb)
        guard st == kCVReturnSuccess, let buffer = pb else { throw XCTSkip("no biplanar buffer (\(st))") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let lb = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lbpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<h { for x in 0..<w { lb[y * lbpr + x] = yByte } }
        let cb = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let cbpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for cy in 0..<(h / 2) { for cx in 0..<(w / 2) {
            cb[cy * cbpr + cx * 2 + 0] = cbByte
            cb[cy * cbpr + cx * 2 + 1] = crByte
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        if let primaries {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        }
        return VideoFrame(pixelBuffer: buffer, pts: HouseClock.now(), source: SourceID("yuv"))
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

    private func compositeHDR(_ frame: VideoFrame, w: Int, h: Int) throws -> (b: Int, g: Int, r: Int) {
        let compositor = try MetalCompositor(device: try device(), width: w, height: h, colorMode: .hdr)
        let sid = SourceID("yuv")
        let scene = Scene(name: "s", layers: [Layer(sourceID: sid)])
        let prog = try compositor.composite(frames: [sid: frame], scene: scene, pts: HouseClock.now())
        XCTAssertEqual(prog.pixelFormat, kCVPixelFormatType_ARGB2101010LEPacked)
        return read10(prog, x: w / 2, y: h / 2)
    }

    // MARK: - tests

    /// A Rec.2020-tagged primary red passes through WITHOUT re-rotation: the HDR
    /// output matches the no-rotation oracle and is far from the double-rotated
    /// (desaturated) value the bug produced.
    func testRec2020RedIsNotDoubleRotated() throws {
        let w = 64, h = 64
        let (kr, kb) = (0.2627, 0.0593) // BT.2020
        let (yB, cbB, crB) = encodeFull(kr: kr, kb: kb, r: 1, g: 0, b: 0)
        let frame = try makeYUVRed(w: w, h: h,
                                   matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
                                   primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                                   yByte: yB, cbByte: cbB, crByte: crB)
        let got = try compositeHDR(frame, w: w, h: h)

        // Independent oracle: decode the SAME bytes with the 2020 inverse; the
        // source is ALREADY 2020 → no rotation → HLG OETF directly.
        let disp = decodeFull(kr: kr, kb: kb, y: Int(yB), cb: Int(cbB), cr: Int(crB))
        let correct = encode(disp, rotate: false)              // already 2020 → no rotation
        // The bug rotated it a SECOND time (709→2020) before HLG.
        let buggy = encode(disp, rotate: true)

        // R rides the HLG log region (stable) → match the no-rotation oracle
        // tightly. G/B sit on the HLG sqrt TOE, where sub-code decode rounding is
        // amplified into tens of code values, so the discriminating claim is that
        // they stay SATURATED-red-small (near black), not an exact ±few match.
        XCTAssertLessThanOrEqual(abs(got.r - correct.r), 12, "R \(got) vs no-rotation oracle \(correct)")
        XCTAssertLessThan(got.g, 250, "2020 red's green channel too high — it was double-rotated (\(got))")
        XCTAssertLessThan(got.b, 250, "2020 red's blue channel too high — it was double-rotated (\(got))")
        // And the buggy double-rotation would have lifted G/B far past that bound.
        XCTAssertGreaterThan(buggy.g, 400, "sanity: double-rotated green should be large (\(buggy))")

        // Non-tautology: correct and double-rotated are far apart, so matching one
        // genuinely rules out the other.
        let sep = abs(correct.g - buggy.g) + abs(correct.b - buggy.b)
        XCTAssertGreaterThan(sep, 300, "no-rotation vs double-rotation oracle too close (\(correct) vs \(buggy))")
    }

    /// A Rec.709-tagged primary red IS still rotated up to Rec.2020 — the fix
    /// does not disable the rotation for content that genuinely needs it.
    func testRec709RedIsStillRotatedTo2020() throws {
        let w = 64, h = 64
        let (kr, kb) = (0.2126, 0.0722) // BT.709
        let (yB, cbB, crB) = encodeFull(kr: kr, kb: kb, r: 1, g: 0, b: 0)
        let frame = try makeYUVRed(w: w, h: h,
                                   matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                                   primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                                   yByte: yB, cbByte: cbB, crByte: crB)
        let got = try compositeHDR(frame, w: w, h: h)

        let disp = decodeFull(kr: kr, kb: kb, y: Int(yB), cb: Int(cbB), cr: Int(crB))
        let rotated = encode(disp, rotate: true)               // 709 → rotate
        let naive = encode(disp, rotate: false)                // no rotation

        XCTAssertLessThanOrEqual(abs(got.r - rotated.r), 12, "R \(got) vs rotated oracle \(rotated)")
        XCTAssertLessThanOrEqual(abs(got.g - rotated.g), 12, "G \(got) vs rotated oracle \(rotated)")
        XCTAssertLessThanOrEqual(abs(got.b - rotated.b), 12, "B \(got) vs rotated oracle \(rotated)")
        // The rotation actually moved the pixel (709 red ≠ naive no-rotation).
        let delta = abs(rotated.g - naive.g) + abs(rotated.b - naive.b)
        XCTAssertGreaterThan(delta, 150, "709 red rotation had no effect in the oracle (\(rotated) vs \(naive))")
    }
}
