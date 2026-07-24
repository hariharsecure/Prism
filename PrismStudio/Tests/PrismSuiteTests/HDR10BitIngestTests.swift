import CoreMedia
import CoreVideo
import Metal
import XCTest

import PrismCompositor
import PrismCore

/// wave-5b — the compositor + color engine now ACCEPT and correctly process real
/// 10-bit HDR input, not just synthetic 8-bit buffers tagged HDR. Before this stage
/// sol #4 confirmed the format gate accepted ONLY 8-bit (BGRA8 / `420v` / `420f`),
/// so a real 10-bit `x420` / `xf20` (P010-style) or `l10r` packed source hit the
/// unsupported/default path and was silently DROPPED — the HDR path was only ever
/// exercised on synthetic 8-bit buffers.
///
/// This suite drives the REAL `MetalCompositor` with synthetic 10-bit buffers of
/// KNOWN Y'CbCr / RGB codes and asserts:
///   (a) a 10-bit source is ACCEPTED where the pre-fix gate dropped it (a `#if DEBUG`
///       negative-control seam reproduces the drop → opaque black).
///   (b) 10-bit PRECISION is preserved — two sources one 10-bit code apart survive to
///       DISTINCT output where a naive 8-bit downconvert (`code >> 2`) collapses them.
///   (c) a tagged 10-bit Rec.2020/HLG source composites to the CORRECT HDR value,
///       reusing the 892/770-class targets adapted to 10-bit input.
///   (d) the 8-bit paths are unchanged (the existing 272-test suite; plus a parity
///       assertion here that an 8-bit `420v` gray still round-trips as before).
///
/// ── INDEPENDENCE OF THE ORACLE (Class I) ────────────────────────────────────
/// Expected values are re-derived HERE in Double from the PUBLISHED specs — the
/// 10-bit de-quantization (video: (Y-64)/876, (C-512)/896; full: Y/1023), the
/// BT.2020 normalized matrix, the BT.2100 HLG OETF *and its inverse* — NOT by
/// calling the shader. The 10-bit decode arithmetic in the test uses the clean
/// from-spec normalized form, a DIFFERENT expression from the shader's folded
/// constants, so a shared bug is impossible.
///
/// SOFTWARE-VERIFIED ONLY: these synthetic 10-bit buffers verify the compositor's
/// software decode/composite. A REAL 10-bit HDR camera / movie end-to-end and an
/// HDR display remain UNVERIFIED-until-hardware (stage N sources + the operator's HDR
/// hardware pass).
final class HDR10BitIngestTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    // MARK: - Independent from-spec references (Double) --------------------------

    private func hlgOETF(_ e: Double) -> Double {
        let e = max(e, 0)
        return e <= 1.0 / 12.0 ? (3 * e).squareRoot()
                               : 0.17883277 * log(12 * e - 0.28466892) + 0.55991073
    }
    private func hlgInverseOETF(_ v: Double) -> Double {
        v <= 0.5 ? (v * v) / 3.0 : (exp((v - 0.55991073) / 0.17883277) + 0.28466892) / 12.0
    }
    private func eotf709(_ v: Double) -> Double { v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1.0 / 0.45) }
    private func sat(_ v: Double) -> Double { min(max(v, 0), 1) }
    private func code(_ v: Double) -> Int { Int((sat(v) * 1023).rounded()) }

    /// From-spec BT.2020 decode of a NEUTRAL 10-bit gray (Cb=Cr=512 → 0 chroma), so
    /// R=G=B=Y'. Video: (Y-64)/876. Full: Y/1023. An independent form (not the
    /// shader's folded code/1020 · 1.1644 constants).
    private func decodeNeutral(y: Int, fullRange: Bool) -> Double {
        fullRange ? Double(y) / 1023.0 : Double(y - 64) / 876.0
    }

    // MARK: - Fixtures ----------------------------------------------------------

    /// A solid 10-bit bi-planar `x420`/`xf20` (P010-style) buffer: the 10-bit code
    /// occupies the HIGH 10 bits of each 16-bit sample (`code << 6`).
    private func makeYUV10(_ w: Int, _ h: Int, y: Int, cb: Int = 512, cr: Int = 512,
                           fullRange: Bool = false,
                           transfer: CFString? = nil, primaries: CFString? = nil,
                           matrix: CFString? = nil) throws -> CVPixelBuffer {
        let fmt = fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                            : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: fmt)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let yBase = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!
        let yBpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
        let yw = CVPixelBufferGetWidthOfPlane(buf, 0), yh = CVPixelBufferGetHeightOfPlane(buf, 0)
        let yVal = UInt16(truncatingIfNeeded: y << 6)
        for row in 0..<yh {
            let p = (yBase + row * yBpr).assumingMemoryBound(to: UInt16.self)
            for col in 0..<yw { p[col] = yVal }
        }
        let cBase = CVPixelBufferGetBaseAddressOfPlane(buf, 1)!
        let cBpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
        let cw = CVPixelBufferGetWidthOfPlane(buf, 1), ch = CVPixelBufferGetHeightOfPlane(buf, 1)
        let cbVal = UInt16(truncatingIfNeeded: cb << 6), crVal = UInt16(truncatingIfNeeded: cr << 6)
        for row in 0..<ch {
            let p = (cBase + row * cBpr).assumingMemoryBound(to: UInt16.self)
            for col in 0..<cw { p[col * 2] = cbVal; p[col * 2 + 1] = crVal }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        tag(buf, transfer, primaries, matrix)
        return buf
    }

    /// A solid 8-bit bi-planar `420v`/`420f` buffer (for the parity check).
    private func makeYUV8(_ w: Int, _ h: Int, y: UInt8, cb: UInt8 = 128, cr: UInt8 = 128,
                          fullRange: Bool = false,
                          transfer: CFString? = nil, primaries: CFString? = nil,
                          matrix: CFString? = nil) throws -> CVPixelBuffer {
        let fmt = fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: fmt)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let yBase = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!.assumingMemoryBound(to: UInt8.self)
        let yBpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
        let yw = CVPixelBufferGetWidthOfPlane(buf, 0), yh = CVPixelBufferGetHeightOfPlane(buf, 0)
        for row in 0..<yh { for col in 0..<yw { (yBase + row * yBpr)[col] = y } }
        let cBase = CVPixelBufferGetBaseAddressOfPlane(buf, 1)!.assumingMemoryBound(to: UInt8.self)
        let cBpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
        let cw = CVPixelBufferGetWidthOfPlane(buf, 1), ch = CVPixelBufferGetHeightOfPlane(buf, 1)
        for row in 0..<ch { for col in 0..<cw { (cBase + row * cBpr)[col * 2] = cb; (cBase + row * cBpr)[col * 2 + 1] = cr } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        tag(buf, transfer, primaries, matrix)
        return buf
    }

    /// A solid 10-bit `l10r` packed-RGB buffer (ARGB2101010 LE: A<<30|R<<20|G<<10|B).
    private func makePacked10(_ w: Int, _ h: Int, r: Int, g: Int, b: Int, a: Int = 3,
                              transfer: CFString? = nil, primaries: CFString? = nil,
                              matrix: CFString? = nil) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_ARGB2101010LEPacked)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let word = UInt32(a & 3) << 30 | UInt32(r & 0x3FF) << 20 | UInt32(g & 0x3FF) << 10 | UInt32(b & 0x3FF)
        for row in 0..<h {
            let p = (base + row * bpr).assumingMemoryBound(to: UInt32.self)
            for col in 0..<w { p[col] = word }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        tag(buf, transfer, primaries, matrix)
        return buf
    }

    /// A solid `64RGBAHalf` buffer (higher-precision straight RGBA), simulating a
    /// 10-bit FX / Vision / Color output the compositor must fold in.
    private func makeRGBAHalf(_ w: Int, _ h: Int, r: Double, g: Double, b: Double, a: Double = 1,
                              transfer: CFString? = nil, primaries: CFString? = nil,
                              matrix: CFString? = nil) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_64RGBAHalf)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let px: [Float16] = [Float16(r), Float16(g), Float16(b), Float16(a)]
        for row in 0..<h {
            let p = (base + row * bpr).assumingMemoryBound(to: Float16.self)
            for col in 0..<w { for k in 0..<4 { p[col * 4 + k] = px[k] } }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        tag(buf, transfer, primaries, matrix)
        return buf
    }

    private func tag(_ buf: CVPixelBuffer, _ transfer: CFString?, _ primaries: CFString?, _ matrix: CFString?) {
        if let transfer { CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate) }
        if let primaries { CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate) }
        if let matrix { CVBufferSetAttachment(buf, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate) }
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

    /// Composite a single full-canvas HDR layer for `buf`; read the centre pixel.
    private func compositeSingle(_ buf: CVPixelBuffer, w: Int, h: Int, premultiplied: Bool = false,
                                 drop10Bit: Bool = false) throws -> (b: Int, g: Int, r: Int) {
        let compositor = try MetalCompositor(device: try device(), width: w, height: h, colorMode: .hdr)
        #if DEBUG
        compositor._test_drop10BitFormats = drop10Bit
        #endif
        let sid = SourceID("s")
        let scene = Scene(name: "s", layers: [Layer(sourceID: sid, premultipliedAlpha: premultiplied)])
        let prog = try compositor.composite(
            frames: [sid: VideoFrame(pixelBuffer: buf, pts: HouseClock.now(), source: sid)],
            scene: scene, pts: HouseClock.now())
        XCTAssertEqual(prog.pixelFormat, kCVPixelFormatType_ARGB2101010LEPacked)
        return read10(prog, x: w / 2, y: h / 2)
    }

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

    // MARK: - (a) accepted where pre-fix DROPPED (negative control) --------------

    func testTenBitBiplanarAcceptedNotDropped() throws {
        let w = 32, h = 32
        // Video-range Rec.2020/HLG gray, Y=768 (= 8-bit 192·4), neutral chroma.
        let gray = try makeYUV10(w, h, y: 768, fullRange: false,
                                 transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                                 primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                                 matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020)
        let accepted = try compositeSingle(gray, w: w, h: h)
        // Decoded + HLG round-tripped mid-tone — clearly not black, clearly not white.
        XCTAssertGreaterThan(accepted.g, 400, "10-bit source produced near-black — was it dropped? \(accepted)")
        XCTAssertLessThan(accepted.g, 1000, "10-bit gray came out white \(accepted)")

        #if DEBUG
        // Negative control: with the drop-seam ON, the SAME buffer hits the pre-fix
        // unsupported path (layer skipped) → the scene clears to opaque black.
        let dropped = try compositeSingle(gray, w: w, h: h, drop10Bit: true)
        for ch in [dropped.b, dropped.g, dropped.r] {
            XCTAssertLessThanOrEqual(ch, 8, "pre-fix drop did not yield black \(dropped)")
        }
        XCTAssertGreaterThan(accepted.g - dropped.g, 300, "accepted 10-bit indistinguishable from the dropped control")
        #endif
    }

    func testTenBitPackedAndHalfAccepted() throws {
        let w = 16, h = 16
        // l10r packed gray (mid code) tagged HLG/2020 — must be accepted + decoded.
        let packed = try makePacked10(w, h, r: 700, g: 700, b: 700,
                                      transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                                      primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                                      matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020)
        let gotP = try compositeSingle(packed, w: w, h: h)
        XCTAssertGreaterThan(gotP.g, 400, "l10r packed dropped/near-black \(gotP)")
        XCTAssertLessThanOrEqual(abs(gotP.r - gotP.g) + abs(gotP.g - gotP.b), 6, "packed gray not neutral \(gotP)")

        // 64RGBAHalf straight gray tagged HLG/2020 — must be accepted + decoded.
        let half = try makeRGBAHalf(w, h, r: 0.7, g: 0.7, b: 0.7,
                                    transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                                    primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                                    matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020)
        let gotH = try compositeSingle(half, w: w, h: h)
        XCTAssertGreaterThan(gotH.g, 400, "64RGBAHalf dropped/near-black \(gotH)")
        XCTAssertLessThanOrEqual(abs(gotH.r - gotH.g) + abs(gotH.g - gotH.b), 6, "half gray not neutral \(gotH)")
    }

    // MARK: - (b) 10-bit precision preserved (sub-8-bit codes survive) -----------

    func testTenBitPrecisionNotCollapsedToEightBit() throws {
        let w = 16, h = 16
        // Full-range HLG so the luma code maps directly to the signal (Y/1023).
        // 513 and 515 differ by 2 at 10-bit but a naive 8-bit downconvert (code >> 2)
        // maps BOTH to 128 — a genuinely sub-8-bit distinction.
        XCTAssertEqual(513 >> 2, 515 >> 2, "test codes must share an 8-bit bucket")
        func compose(_ yc: Int) throws -> (b: Int, g: Int, r: Int) {
            let buf = try makeYUV10(w, h, y: yc, fullRange: true,
                                    transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                                    primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                                    matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020)
            return try compositeSingle(buf, w: w, h: h)
        }
        let lo = try compose(513), hi = try compose(515)
        // The two sub-8-bit-distinct sources reach DISTINCT output — an 8-bit
        // downconvert would have collapsed them to the identical value.
        XCTAssertGreaterThan(hi.g, lo.g, "10-bit codes 513 vs 515 collapsed to the same output (\(lo.g) == \(hi.g)) — precision lost")
        // Both land near their from-spec HLG round-trip (≈ Y/1023 · 1023 = Y).
        XCTAssertLessThanOrEqual(abs(lo.g - code(hlgOETF(hlgInverseOETF(513.0 / 1023.0)))), 3, "lo off-spec \(lo)")
        XCTAssertLessThanOrEqual(abs(hi.g - code(hlgOETF(hlgInverseOETF(515.0 / 1023.0)))), 3, "hi off-spec \(hi)")
    }

    // MARK: - (c) tagged 10-bit Rec.2020/HLG composites CORRECTLY ----------------

    func testTenBitVideoRangeHLGGrayCorrect() throws {
        let w = 32, h = 32
        // Video-range Y=768 (8-bit 192·4), tagged Rec.2020/HLG → decode (768-64)/876,
        // HLG inverse-OETF → linear → (already 2020) → HLG OETF → round-trips.
        let gray = try makeYUV10(w, h, y: 768, fullRange: false,
                                 transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                                 primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                                 matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020)
        let got = try compositeSingle(gray, w: w, h: h)
        let sig = decodeNeutral(y: 768, fullRange: false)           // 704/876 ≈ 0.8037
        let correct = code(hlgOETF(hlgInverseOETF(sig)))            // ≈822
        for ch in [got.b, got.g, got.r] {
            XCTAssertLessThanOrEqual(abs(ch - correct), 6, "10-bit HLG gray channel \(ch) ≠ from-spec \(correct)")
        }
        XCTAssertLessThanOrEqual(abs(got.r - got.g) + abs(got.g - got.b), 4, "not neutral: \(got)")
    }

    func testTenBitWhiteOverBlack_Linear892() throws {
        let w = 32, h = 32
        // Reuse the 892 headline with 10-bit INPUT: full-range HLG white (Y=1023,
        // signal 1.0, linear 1.0) at 0.5 opacity over 10-bit black → 0.5 LIGHT →
        // HLG OETF(0.5) ≈ 892 (the linear-light composite target, wave-4b).
        let white = try makeYUV10(w, h, y: 1023, fullRange: true,
                                  transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                                  primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                                  matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020)
        let black = try makeYUV10(w, h, y: 0, fullRange: true,
                                  transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                                  primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                                  matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020)
        let got = try compositeOver(top: white, topOpacity: 0.5, bottom: black, w: w, h: h)
        let correct = code(hlgOETF(0.5))                            // ≈892
        let encodedSpaceBug = code(hlgOETF(1.0) * 0.5)              // ≈511 (blend of HLG signals)
        XCTAssertGreaterThan(abs(correct - encodedSpaceBug), 200, "oracle discriminator too weak")
        for ch in [got.b, got.g, got.r] {
            XCTAssertLessThanOrEqual(abs(ch - correct), 12, "10-bit 50% white/black \(ch) ≠ linear oracle \(correct)")
            XCTAssertGreaterThan(abs(ch - encodedSpaceBug), 200, "channel \(ch) matches the OLD encoded-space blend")
        }
    }

    func testTenBitSaturatedRec2020GreenStaysInGamut() throws {
        let w = 16, h = 16
        // Full-range Rec.2020 green primary via YUV: G maxed, B/R zero. In BT.2020,
        // pure green is Y≈0.678·1023, Cb below-neutral, Cr below-neutral — build it
        // directly in packed RGB to avoid chroma-rounding, tagged 2020/HLG.
        let green = try makePacked10(w, h, r: 0, g: 1023, b: 0,
                                     transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                                     primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                                     matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020)
        let got = try compositeSingle(green, w: w, h: h)
        XCTAssertGreaterThanOrEqual(got.g, 1015, "2020 green not maxed (\(got)) — rotated/desaturated?")
        XCTAssertLessThanOrEqual(got.r, 8, "2020 green picked up R \(got)")
        XCTAssertLessThanOrEqual(got.b, 8, "2020 green picked up B \(got)")
    }

    // MARK: - (d) 8-bit path parity (unchanged) ----------------------------------

    func testEightBitVideoRangeGrayUnchanged() throws {
        let w = 32, h = 32
        // The SAME conceptual gray as the 10-bit video test but 8-bit (Y=192): the
        // 8-bit path must still round-trip through the HDR pipeline exactly as before.
        let gray = try makeYUV8(w, h, y: 192, fullRange: false,
                                transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                                primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                                matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020)
        let got = try compositeSingle(gray, w: w, h: h)
        let sig = Double(192 - 16) / 219.0                          // 8-bit video decode
        let correct = code(hlgOETF(hlgInverseOETF(sig)))
        for ch in [got.b, got.g, got.r] {
            XCTAssertLessThanOrEqual(abs(ch - correct), 6, "8-bit HLG gray \(ch) ≠ \(correct) (regression)")
        }
        // 8-bit video Y=192 and 10-bit video Y=768 decode to the SAME signal → SAME
        // output: the two bit-depths agree (10-bit is a higher-precision encoding).
        let tenBit = try compositeSingle(
            try makeYUV10(w, h, y: 768, fullRange: false,
                          transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                          primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                          matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020), w: w, h: h)
        XCTAssertLessThanOrEqual(abs(got.g - tenBit.g), 4, "8-bit \(got.g) vs 10-bit \(tenBit.g) disagree on the same color")
    }
}
