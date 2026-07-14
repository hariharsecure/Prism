import CoreMedia
import CoreVideo
import Metal
import XCTest

import PrismCompositor
import PrismCore
@testable import PrismSources

/// sol #4 finding 3 — the engine's colour model was BINARY: primaries were
/// "Rec.2020 OR assume 709" and transfers were "HLG/PQ OR assume 709". So three
/// explicitly-advertised inputs were mis-decoded in the HDR compositor:
///
///  1. **Rec.2020 + Linear** gray 128 was classified transfer-0 (709 EOTF) →
///     emitted **765/1023**; a LINEAR source must SKIP the EOTF → **892**.
///  2. **generated sRGB** gray 128 was decoded with the 709 EOTF → **765**; the
///     sRGB EOTF (distinct curve) gives **726**.
///  3. **DisplayP3** red was rotated with the 709→2020 matrix → **(935,466,227)**;
///     the P3→2020 matrix maps it near HLG10 **(970,379,0)**.
///
/// FIX: a proper model — PRIMARIES {Rec709, Rec2020, DisplayP3} (sRGB ≡ 709
/// primaries) and TRANSFER {Rec709, sRGB, Linear, HLG, PQ}, classified from the CV
/// attachments and plumbed into the per-layer linear decode (correct EOTF) and the
/// primary rotation (709→2020 / P3→2020 / none).
///
/// ── INDEPENDENCE ─ the P3→2020 matrix is RE-DERIVED here from the published
/// ITU-R BT.2020 / SMPTE-RP-431 (Display P3) chromaticities via a 3×3 solve — NOT
/// copied from the shader constants. The EOTFs are the published closed forms. Each
/// target also asserts it is FAR from the specific pre-fix wrong value sol measured.
final class ColorModelPrimariesTransferTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    // MARK: - independent transfer functions (published closed forms)

    private func eotf709(_ v: Double) -> Double { v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1.0 / 0.45) }
    private func eotfSRGB(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    private func hlgOETF(_ e: Double) -> Double {
        let e = max(e, 0)
        return e <= 1.0 / 12.0 ? (3 * e).squareRoot()
                               : 0.17883277 * log(12 * e - 0.28466892) + 0.55991073
    }
    private func code(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 1023).rounded()) }

    // MARK: - independent primary-matrix derivation from chromaticities

    /// RGB→XYZ for primaries (rx,ry),(gx,gy),(bx,by) and white (wx,wy).
    private func rgbToXYZ(_ r: (Double, Double), _ g: (Double, Double), _ b: (Double, Double),
                          _ w: (Double, Double)) -> [[Double]] {
        func xyz(_ c: (Double, Double)) -> [Double] { [c.0 / c.1, 1.0, (1 - c.0 - c.1) / c.1] }
        let R = xyz(r), G = xyz(g), B = xyz(b), W = xyz(w)
        let M = [[R[0], G[0], B[0]], [R[1], G[1], B[1]], [R[2], G[2], B[2]]]
        let s = mul(inv3(M), W)             // per-primary scale so M·s = white
        return [[R[0] * s[0], G[0] * s[1], B[0] * s[2]],
                [R[1] * s[0], G[1] * s[1], B[1] * s[2]],
                [R[2] * s[0], G[2] * s[1], B[2] * s[2]]]
    }
    private func inv3(_ m: [[Double]]) -> [[Double]] {
        let a = m[0][0], b = m[0][1], c = m[0][2]
        let d = m[1][0], e = m[1][1], f = m[1][2]
        let g = m[2][0], h = m[2][1], i = m[2][2]
        let A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g
        let det = a * A + b * B + c * C
        let D = -(b * i - c * h), E = a * i - c * g, F = -(a * h - b * g)
        let G = b * f - c * e, H = -(a * f - c * d), I = a * e - b * d
        return [[A / det, D / det, G / det], [B / det, E / det, H / det], [C / det, F / det, I / det]]
    }
    private func mul(_ m: [[Double]], _ v: [Double]) -> [Double] {
        [m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
         m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
         m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2]]
    }
    private func matmul(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        var o = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { o[i][j] += a[i][k] * b[k][j] } } }
        return o
    }

    private let D65 = (0.3127, 0.3290)
    private lazy var M2020 = rgbToXYZ((0.708, 0.292), (0.170, 0.797), (0.131, 0.046), D65)
    private lazy var M709 = rgbToXYZ((0.640, 0.330), (0.300, 0.600), (0.150, 0.060), D65)
    private lazy var MP3 = rgbToXYZ((0.680, 0.320), (0.265, 0.690), (0.150, 0.060), D65)
    private lazy var P3to2020 = matmul(inv3(M2020), MP3)
    private lazy var R709to2020 = matmul(inv3(M2020), M709)

    // MARK: - fixtures / probe

    private func makeBGRA(_ w: Int, _ h: Int, r: UInt8, g: UInt8, b: UInt8,
                          transfer: CFString?, primaries: CFString?, matrix: CFString?) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_32BGRA)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<h { for col in 0..<w {
            let p = base + row * bpr + col * 4
            p[0] = b; p[1] = g; p[2] = r; p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        if let transfer { CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate) }
        if let primaries { CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate) }
        if let matrix { CVBufferSetAttachment(buf, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate) }
        return buf
    }

    private func read10(_ buf: CVPixelBuffer, x: Int, y: Int) -> (b: Int, g: Int, r: Int) {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let word = CVPixelBufferGetBaseAddress(buf)!
            .advanced(by: y * CVPixelBufferGetBytesPerRow(buf) + x * 4)
            .loadUnaligned(as: UInt32.self)
        return (Int(word & 0x3FF), Int((word >> 10) & 0x3FF), Int((word >> 20) & 0x3FF))
    }

    private func compositeHDR(_ buf: CVPixelBuffer, w: Int, h: Int) throws -> (b: Int, g: Int, r: Int) {
        let compositor = try MetalCompositor(device: try device(), width: w, height: h, colorMode: .hdr)
        let sid = SourceID("s")
        let scene = Scene(name: "s", layers: [Layer(sourceID: sid)])
        let prog = try compositor.composite(frames: [sid: VideoFrame(pixelBuffer: buf, pts: HouseClock.now(), source: sid)],
                                            scene: scene, pts: HouseClock.now())
        XCTAssertEqual(prog.pixelFormat, kCVPixelFormatType_ARGB2101010LEPacked)
        return read10(prog.pixelBuffer, x: w / 2, y: h / 2)
    }

    // MARK: - (1) Rec.2020 + Linear: skip the EOTF → 892, NOT 765

    func testRec2020LinearSkipsEOTF() throws {
        let w = 32, h = 32
        let buf = try makeBGRA(w, h, r: 128, g: 128, b: 128,
                               transfer: kCVImageBufferTransferFunction_Linear,
                               primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                               matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020)
        let got = try compositeHDR(buf, w: w, h: h)
        let g = 128.0 / 255.0
        let correct = code(hlgOETF(g))               // linear (no EOTF), no rotate → 892
        let bug765 = code(hlgOETF(eotf709(g)))       // the binary-model 709-EOTF bug → 765
        XCTAssertGreaterThan(abs(correct - bug765), 100, "oracle discriminator weak (\(correct) vs \(bug765))")
        for ch in [got.b, got.g, got.r] {
            XCTAssertLessThanOrEqual(abs(ch - correct), 10, "2020+Linear channel \(ch) ≠ linear oracle \(correct)")
            XCTAssertGreaterThan(abs(ch - bug765), 60, "channel \(ch) matches the 709-EOTF bug \(bug765)")
        }
        XCTAssertLessThanOrEqual(abs(got.r - got.g) + abs(got.g - got.b), 4, "not neutral: \(got)")
    }

    // MARK: - (2) sRGB transfer uses the sRGB EOTF → 726, NOT the 709 EOTF's 765

    func testSRGBTransferUsesSRGBEOTF() throws {
        let w = 32, h = 32
        let buf = try makeBGRA(w, h, r: 128, g: 128, b: 128,
                               transfer: kCVImageBufferTransferFunction_sRGB,
                               primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                               matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        let got = try compositeHDR(buf, w: w, h: h)
        let g = 128.0 / 255.0
        let correct = code(hlgOETF(eotfSRGB(g)))     // sRGB EOTF, rotate neutral-preserving → 726
        let bug765 = code(hlgOETF(eotf709(g)))       // 709 EOTF → 765
        XCTAssertGreaterThan(abs(correct - bug765), 25, "oracle discriminator weak (\(correct) vs \(bug765))")
        for ch in [got.b, got.g, got.r] {
            XCTAssertLessThanOrEqual(abs(ch - correct), 8, "sRGB channel \(ch) ≠ sRGB-EOTF oracle \(correct)")
            XCTAssertGreaterThan(abs(ch - bug765), 20, "channel \(ch) matches the 709-EOTF bug \(bug765)")
        }
    }

    // MARK: - (3) DisplayP3 red rotates P3→2020 → ≈(970,379,0), NOT 709's (935,466,227)

    func testDisplayP3RedRotatesP3Not709() throws {
        let w = 32, h = 32
        let buf = try makeBGRA(w, h, r: 255, g: 0, b: 0,
                               transfer: kCVImageBufferTransferFunction_sRGB,
                               primaries: kCVImageBufferColorPrimaries_P3_D65,
                               matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        let got = try compositeHDR(buf, w: w, h: h)
        // Independent oracle: sRGB EOTF(1,0,0)=(1,0,0), rotate by the RE-DERIVED P3→2020.
        let redP3 = mul(P3to2020, [1, 0, 0])
        let correct = (b: code(hlgOETF(redP3[2])), g: code(hlgOETF(redP3[1])), r: code(hlgOETF(redP3[0])))
        let red709 = mul(R709to2020, [1, 0, 0])      // the WRONG 709-matrix rotation
        let bug = (b: code(hlgOETF(red709[2])), g: code(hlgOETF(red709[1])), r: code(hlgOETF(red709[0])))
        XCTAssertGreaterThan(abs(correct.g - bug.g), 60, "oracle discriminator weak (\(correct) vs \(bug))")
        XCTAssertLessThanOrEqual(abs(got.r - correct.r), 10, "P3 red R \(got) ≠ P3 oracle \(correct)")
        XCTAssertLessThanOrEqual(abs(got.g - correct.g), 12, "P3 red G \(got) ≠ P3 oracle \(correct) (709-matrix bug \(bug))")
        XCTAssertLessThanOrEqual(got.b, 10, "P3 red B \(got) not ≈0 (oracle \(correct))")
        XCTAssertGreaterThan(abs(got.g - bug.g), 50, "P3 red G matches the 709-matrix bug \(bug)")
    }

    // MARK: - (regression) untagged / 2020-HLG unchanged by the extended model

    func testUntaggedSDRStillUpMaps765() throws {
        let w = 32, h = 32
        // No tags → 709 primaries + 709 EOTF (unchanged binary-model default).
        let got = try compositeHDR(try makeBGRA(w, h, r: 128, g: 128, b: 128,
                                                transfer: nil, primaries: nil, matrix: nil), w: w, h: h)
        let correct = code(hlgOETF(eotf709(128.0 / 255.0)))     // 765
        for ch in [got.b, got.g, got.r] {
            XCTAssertLessThanOrEqual(abs(ch - correct), 10, "untagged SDR channel \(ch) ≠ 709 up-map \(correct)")
        }
    }

    // MARK: - (finding 3 case 2 wiring) generated canvas content is tagged sRGB

    func testGeneratedCanvasIsTaggedSRGB() throws {
        let canvas = try SourceRenderCanvas(size: CanvasSize(width: 16, height: 16))
        let buf = try canvas.render { ctx in
            ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        // Generated sRGB content must carry its OWN sRGB transfer (finding 3), so the
        // HDR compositor decodes it with the sRGB EOTF — not left untagged (709 EOTF).
        XCTAssertEqual(YCbCrTags.transferCode(for: buf), 3, "generated canvas not tagged sRGB transfer")
        XCTAssertFalse(YCbCrTags.isRec2020(for: buf), "generated canvas wrongly reads as Rec.2020")
    }
}
