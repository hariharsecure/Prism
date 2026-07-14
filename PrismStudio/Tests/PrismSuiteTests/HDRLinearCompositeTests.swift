import CoreMedia
import CoreVideo
import Metal
import XCTest

import PrismCompositor
import PrismCore

/// sol #3 — the HDR output path composited in the WRONG space. Two confirmed,
/// pixel-probed defects this suite reproduces then locks down:
///
///  1. **Layers were blended on HLG-ENCODED values.** A 50%-opacity white over
///     black emitted **511/1023** (half the SIGNAL). The physically-correct result
///     blends half the LIGHT then encodes: HLG_OETF(0.5) ≈ **892/1023**.
///  2. **Every source was decoded with the Rec.709 EOTF**, ignoring its transfer
///     tag. A TRUE-HLG gray 192/255 (an HLG SIGNAL) emitted **916/1023**; decoded
///     correctly with the HLG inverse-OETF it round-trips to **≈771/1023**.
///
/// The rebuild establishes a Rec.2020 LINEAR working space, decodes each layer to
/// linear per its OWN transfer tag (709 EOTF / HLG inverse-OETF / PQ EOTF), rotates
/// primaries to 2020 in linear, blends opacity+premultiplied-alpha in LINEAR, and
/// applies the BT.2100 HLG OETF ONCE at the end.
///
/// ── INDEPENDENCE OF THE ORACLE ──────────────────────────────────────────────
/// The expected values are computed HERE, in Double, from the PUBLISHED formulas
/// (BT.709 EOTF, ARIB STD-B67 / BT.2100 HLG OETF *and its inverse*, the
/// Rec.709→2020 primary matrix) — NOT by calling the shader. Crucially the
/// COMPOSITE itself is done with the test's own arithmetic (e.g. `0.5·white +
/// 0.5·black` computed in linear Double), so a bug shared between the shader's
/// blend and its oracle is impossible: the test never runs the code under test to
/// produce its reference. Each correctness target also explicitly asserts the
/// measured pixel is FAR from the specific pre-fix wrong value sol found (511 /
/// 916 / the encoded-space blend), so matching the oracle genuinely rules out the
/// bug rather than merely being "close enough".
///
/// DOCUMENTED RESIDUAL (asserted, not hidden): the encode is display-referred with
/// NO scene-referred OOTF / system-gamma (reference γ = 1), matching the shader's
/// documented scope — which is exactly why these spec targets are exact.
final class HDRLinearCompositeTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    // MARK: - Independent from-spec references (Double) --------------------------

    /// BT.709 EOTF: display (gamma-coded) → linear.
    private func eotf709(_ v: Double) -> Double { v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1.0 / 0.45) }
    /// BT.2100 / ARIB STD-B67 HLG OETF: scene-linear → HLG signal.
    private func hlgOETF(_ e: Double) -> Double {
        let e = max(e, 0)
        return e <= 1.0 / 12.0 ? (3 * e).squareRoot()
                               : 0.17883277 * log(12 * e - 0.28466892) + 0.55991073
    }
    /// BT.2100 HLG inverse-OETF: HLG signal → scene-linear (exact inverse above).
    private func hlgInverseOETF(_ v: Double) -> Double {
        v <= 0.5 ? (v * v) / 3.0 : (exp((v - 0.55991073) / 0.17883277) + 0.28466892) / 12.0
    }
    private func sat(_ v: Double) -> Double { min(max(v, 0), 1) }
    private func code(_ v: Double) -> Int { Int((sat(v) * 1023).rounded()) }
    /// Rec.709→Rec.2020 primary rotation in LINEAR light (rows sum to 1).
    private func rotate709to2020(_ c: (Double, Double, Double)) -> (Double, Double, Double) {
        (0.627404 * c.0 + 0.329283 * c.1 + 0.043313 * c.2,
         0.069097 * c.0 + 0.919540 * c.1 + 0.011362 * c.2,
         0.016391 * c.0 + 0.088013 * c.1 + 0.895595 * c.2)
    }

    // MARK: - Fixtures / probe --------------------------------------------------

    private func makeBGRA(_ w: Int, _ h: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255,
                          transfer: CFString? = nil, primaries: CFString? = nil,
                          matrix: CFString? = nil) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_32BGRA)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<h { for col in 0..<w {
            let p = base + row * bpr + col * 4
            p[0] = b; p[1] = g; p[2] = r; p[3] = a
        } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        if let transfer { CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate) }
        if let primaries { CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate) }
        if let matrix { CVBufferSetAttachment(buf, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate) }
        return buf
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

    /// Composite a single full-canvas layer for `buf`, read the centre 10-bit pixel.
    private func compositeSingle(_ buf: CVPixelBuffer, w: Int, h: Int,
                                 premultiplied: Bool = false) throws -> (b: Int, g: Int, r: Int) {
        let compositor = try MetalCompositor(device: try device(), width: w, height: h, colorMode: .hdr)
        let sid = SourceID("s")
        let scene = Scene(name: "s", layers: [Layer(sourceID: sid, premultipliedAlpha: premultiplied)])
        let prog = try compositor.composite(frames: [sid: VideoFrame(pixelBuffer: buf, pts: HouseClock.now(), source: sid)],
                                            scene: scene, pts: HouseClock.now())
        XCTAssertEqual(prog.pixelFormat, kCVPixelFormatType_ARGB2101010LEPacked)
        return read10(prog, x: w / 2, y: h / 2)
    }

    /// Composite `top` (opacity `topOpacity`) over full-canvas opaque `bottom`.
    private func compositeOver(top: CVPixelBuffer, topOpacity: Float, bottom: CVPixelBuffer,
                               w: Int, h: Int) throws -> (b: Int, g: Int, r: Int) {
        let compositor = try MetalCompositor(device: try device(), width: w, height: h, colorMode: .hdr)
        let bID = SourceID("bottom"), tID = SourceID("top")
        let scene = Scene(name: "over", layers: [
            Layer(sourceID: bID, zIndex: 0),
            Layer(sourceID: tID, opacity: topOpacity, zIndex: 1),
        ])
        let now = HouseClock.now()
        let prog = try compositor.composite(
            frames: [bID: VideoFrame(pixelBuffer: bottom, pts: now, source: bID),
                     tID: VideoFrame(pixelBuffer: top, pts: now, source: tID)],
            scene: scene, pts: now)
        return read10(prog, x: w / 2, y: h / 2)
    }

    // MARK: - (a) 50% white over black → linear ≈892, NOT encoded-space 511 -------

    func testFiftyPercentWhiteOverBlack_LinearComposite() throws {
        let w = 32, h = 32
        let white = try makeBGRA(w, h, r: 255, g: 255, b: 255)
        let black = try makeBGRA(w, h, r: 0, g: 0, b: 0)
        let got = try compositeOver(top: white, topOpacity: 0.5, bottom: black, w: w, h: h)

        // Independent oracle: blend 0.5·(white linear) + 0.5·(black linear) = 0.5
        // light (white 709-EOTF/2020-rotate stays 1 on the neutral axis), encode once.
        let correct = code(hlgOETF(0.5))                  // ≈892
        let encodedSpaceBug = code(hlgOETF(1.0) * 0.5)    // ≈511 (blend of HLG signals)
        XCTAssertGreaterThan(abs(correct - encodedSpaceBug), 200, "oracle discriminator too weak (\(correct) vs \(encodedSpaceBug))")

        for ch in [got.b, got.g, got.r] {
            XCTAssertLessThanOrEqual(abs(ch - correct), 12, "50% white/black channel \(ch) ≠ linear-composite oracle \(correct)")
            XCTAssertGreaterThan(abs(ch - encodedSpaceBug), 200, "channel \(ch) matches the OLD encoded-space blend \(encodedSpaceBug)")
        }
        XCTAssertLessThanOrEqual(abs(got.r - got.g) + abs(got.g - got.b), 4, "not neutral: \(got)")
    }

    // MARK: - (b) true-HLG gray 192/255 decoded correctly → ≈771, NOT 916 ---------

    func testTrueHLGGrayDecodedWithHLGInverseNot709() throws {
        let w = 32, h = 32
        // A TRUE-HLG source: value 192 is an HLG SIGNAL, tagged BT.2100-HLG / Rec.2020.
        let hlg = try makeBGRA(w, h, r: 192, g: 192, b: 192,
                               transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                               primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                               matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020)
        let got = try compositeSingle(hlg, w: w, h: h)

        let sig = 192.0 / 255.0
        // Correct: HLG inverse-OETF → scene-linear → (already 2020, no rotate) →
        // HLG OETF → round-trips to the input signal.
        let correct = code(hlgOETF(hlgInverseOETF(sig)))          // ≈771 (≈ sig·1023)
        // OLD BUG: decode a true-HLG signal with the 709 EOTF, then HLG-encode.
        let bug709 = code(hlgOETF(eotf709(sig)))                  // ≈916
        XCTAssertGreaterThan(abs(correct - bug709), 100, "oracle discriminator too weak (\(correct) vs \(bug709))")

        for ch in [got.b, got.g, got.r] {
            XCTAssertLessThanOrEqual(abs(ch - correct), 8, "true-HLG gray channel \(ch) ≠ HLG-inverse round-trip \(correct)")
            XCTAssertGreaterThan(abs(ch - bug709), 60, "channel \(ch) matches the OLD 709-EOTF-decode bug \(bug709)")
        }
        XCTAssertLessThanOrEqual(abs(got.r - got.g) + abs(got.g - got.b), 4, "not neutral: \(got)")
    }

    // MARK: - (c) neutral axis preserved ----------------------------------------

    func testNeutralAxisPreserved() throws {
        let w = 32, h = 32
        let black = try compositeSingle(try makeBGRA(w, h, r: 0, g: 0, b: 0), w: w, h: h)
        for ch in [black.b, black.g, black.r] { XCTAssertLessThanOrEqual(ch, 8, "black \(ch) not ≈0") }

        let white = try compositeSingle(try makeBGRA(w, h, r: 255, g: 255, b: 255), w: w, h: h)
        for ch in [white.b, white.g, white.r] { XCTAssertGreaterThanOrEqual(ch, 1015, "white \(ch) not ≈1023") }

        let gray = try compositeSingle(try makeBGRA(w, h, r: 128, g: 128, b: 128), w: w, h: h)
        XCTAssertLessThanOrEqual(abs(gray.r - gray.g) + abs(gray.g - gray.b), 4, "gray not neutral: \(gray)")
        XCTAssertGreaterThan(gray.g, 8); XCTAssertLessThan(gray.g, 1015) // genuinely a mid-tone
    }

    // MARK: - (d) saturated Rec.2020 primary stays in-gamut / correct ------------

    func testSaturatedRec2020PrimaryInGamut() throws {
        let w = 32, h = 32
        // A true Rec.2020/HLG green primary (signal 1.0 on G): must NOT be re-rotated
        // (it is already 2020) — it stays a single maxed channel.
        let green = try makeBGRA(w, h, r: 0, g: 255, b: 0,
                                 transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                                 primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                                 matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020)
        let got = try compositeSingle(green, w: w, h: h)

        // Oracle: HLG signal (0,1,0) → inverse-OETF (0,1,0) → no rotation → HLG OETF.
        let want = (b: code(hlgOETF(hlgInverseOETF(0))),
                    g: code(hlgOETF(hlgInverseOETF(1))),
                    r: code(hlgOETF(hlgInverseOETF(0))))
        XCTAssertGreaterThanOrEqual(got.g, 1015, "2020 green G \(got.g) not maxed (oracle \(want.g))")
        XCTAssertLessThanOrEqual(got.r, 8, "2020 green picked up R — it was rotated/desaturated (\(got))")
        XCTAssertLessThanOrEqual(got.b, 8, "2020 green picked up B — it was rotated/desaturated (\(got))")
    }

    // MARK: - (e) an SDR source in an HDR show is correctly up-mapped ------------

    func testSDRSourceInHDRShowUpMapped() throws {
        let w = 32, h = 32
        // Untagged SDR gray (709) composited into an HLG program → EOTF709→linear→
        // rotate→HLG. The standard SDR-in-HDR up-map (≈765), not gamma-into-HLG 892.
        let got = try compositeSingle(try makeBGRA(w, h, r: 128, g: 128, b: 128), w: w, h: h)
        let sdr = 128.0 / 255.0
        let correct = code(hlgOETF(eotf709(sdr)))          // ≈765
        let gammaIntoHLGBug = code(hlgOETF(sdr))           // ≈892
        XCTAssertGreaterThan(abs(correct - gammaIntoHLGBug), 100, "oracle discriminator too weak")
        for ch in [got.b, got.g, got.r] {
            XCTAssertLessThanOrEqual(abs(ch - correct), 10, "SDR-in-HDR channel \(ch) ≠ up-map oracle \(correct)")
            XCTAssertGreaterThan(abs(ch - gammaIntoHLGBug), 60, "channel \(ch) matches the gamma-into-HLG bug \(gammaIntoHLGBug)")
        }
    }

    // MARK: - (f) alpha composite in linear (negative control vs encoded-space) --

    func testMidGrayOverBlackAlpha_LinearNotEncodedSpace() throws {
        let w = 32, h = 32
        let gray = try makeBGRA(w, h, r: 128, g: 128, b: 128)
        let black = try makeBGRA(w, h, r: 0, g: 0, b: 0)
        let got = try compositeOver(top: gray, topOpacity: 0.5, bottom: black, w: w, h: h)

        let grayLin = eotf709(128.0 / 255.0)               // ≈0.2616
        // LINEAR-CORRECT: 0.5·grayLin over black = 0.1308 light → HLG OETF → ≈619.
        let correct = code(hlgOETF(0.5 * grayLin))
        // NEGATIVE CONTROL — encoded-space blend: HLG(grayLin)·0.5 → ≈382.
        let encodedSpaceBug = code(hlgOETF(grayLin) * 0.5)
        XCTAssertGreaterThan(abs(correct - encodedSpaceBug), 150, "control discriminator too weak (\(correct) vs \(encodedSpaceBug))")
        for ch in [got.b, got.g, got.r] {
            XCTAssertLessThanOrEqual(abs(ch - correct), 12, "alpha-linear channel \(ch) ≠ linear oracle \(correct)")
            XCTAssertGreaterThan(abs(ch - encodedSpaceBug), 120, "channel \(ch) matches the encoded-space blend \(encodedSpaceBug)")
        }
    }
}
