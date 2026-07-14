import CoreGraphics
import CoreMedia
import CoreVideo
import Metal
import XCTest

import PrismCompositor
import PrismCore

/// sol #8 — the FULL legal-CGColorSpace-NAME classification table + the last
/// pre-clamp of a nonlinear extended-range highlight.
///
///  - **#5** every legal name-only CGColorSpace must classify to the right
///    (transfer, primaries) instead of falling through to Rec.709. Sol named the
///    holes (`extendedDisplayP3`, `extendedITUR_2020`, `itur_2020_sRGBGamma`,
///    `itur_709_HLG`, `itur_709_PQ`); this suite pins the ENTIRE enumerated table.
///  - **#6** a NONLINEAR extended-range (`extendedSRGB` / `extendedITUR_2020` /
///    `extendedDisplayP3`) highlight > 1 was saturated to 1.0 BEFORE decode, so a
///    legal `extendedSRGB` 1.5 @25% opacity emitted **756** (the pre-clamp result)
///    instead of the correct **937** (CI-linear 2.537 → blend 0.634 → HLG).
///  - **#7** an explicit Rec.709 matrix on a name-only HDR source was overwritten
///    (conflated with absent) during materialization.
///
/// ── INDEPENDENCE OF THE ORACLE ──────────────────────────────────────────────
/// Every expected value is computed HERE, in Double, from the PUBLISHED formulas
/// (sRGB / BT.709 EOTF, BT.2100 HLG OETF & inverse-OETF, ST 2084 PQ EOTF, the
/// sRGB→P3/2020 primary matrices) — never by calling the shader — and each target
/// also asserts the measured pixel is FAR from the specific pre-fix wrong value.
final class HDRColorNameCompletenessTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    // MARK: - Independent from-spec references (Double) --------------------------

    private func eotf709(_ v: Double) -> Double { v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1.0 / 0.45) }
    private func srgbEOTF(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    private func hlgOETF(_ e: Double) -> Double {
        let e = max(e, 0)
        return e <= 1.0 / 12.0 ? (3 * e).squareRoot()
                               : 0.17883277 * log(12 * e - 0.28466892) + 0.55991073
    }
    private func hlgInverseOETF(_ v: Double) -> Double {
        v <= 0.5 ? (v * v) / 3.0 : (exp((v - 0.55991073) / 0.17883277) + 0.28466892) / 12.0
    }
    private func pqEOTFNorm(_ v: Double) -> Double {
        let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let vp = pow(max(v, 0), 1.0 / m2)
        let y = pow(max(vp - c1, 0) / max(c2 - c3 * vp, 1e-6), 1.0 / m1)
        return min(max(y * 10.0, 0), 1)
    }
    private func sat(_ v: Double) -> Double { min(max(v, 0), 1) }
    private func code(_ v: Double) -> Int { Int((sat(v) * 1023).rounded()) }

    /// sRGB(709) linear → Rec.2020 linear (rows sum to 1 — neutral preserved).
    private func rot709to2020(_ c: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(0.627404 * c.x + 0.329283 * c.y + 0.043313 * c.z,
              0.069097 * c.x + 0.919540 * c.y + 0.011362 * c.z,
              0.016391 * c.x + 0.088013 * c.y + 0.895595 * c.z)
    }
    /// Display-P3 linear → Rec.2020 linear (the compositor's exact P3→2020 matrix).
    private func rotP3to2020(_ c: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(0.753833 * c.x + 0.198597 * c.y + 0.047570 * c.z,
              0.045744 * c.x + 0.941777 * c.y + 0.012479 * c.z,
             -0.001210 * c.x + 0.017602 * c.y + 0.983609 * c.z)
    }

    // MARK: - Fixtures / probe --------------------------------------------------

    private func makeBGRANameOnly(_ w: Int, _ h: Int, r: UInt8, g: UInt8, b: UInt8, csName: CFString) throws -> CVPixelBuffer {
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
        guard let cs = CGColorSpace(name: csName) else { throw XCTSkip("colorspace \(csName) unavailable") }
        CVBufferSetAttachment(buf, kCVImageBufferCGColorSpaceKey, cs, .shouldPropagate)
        // Deliberately NO discrete transfer / primaries / matrix — the name is the only signal.
        return buf
    }

    private func makeBGRAGrayNameOnly(_ w: Int, _ h: Int, gray: UInt8, csName: CFString) throws -> CVPixelBuffer {
        try makeBGRANameOnly(w, h, r: gray, g: gray, b: gray, csName: csName)
    }

    /// A neutral `64RGBAHalf` buffer at extended-range float value `v`, α=1, carrying
    /// ONLY a named CGColorSpace attachment (a name-only extended-range HDR frame).
    private func makeHalfGrayNameOnly(_ w: Int, _ h: Int, v: Double, csName: CFString) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_64RGBAHalf,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else {
            throw XCTSkip("could not allocate 64RGBAHalf")
        }
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let px: [Float16] = [Float16(v), Float16(v), Float16(v), Float16(1)]
        for row in 0..<h {
            let p = (base + row * bpr).assumingMemoryBound(to: Float16.self)
            for col in 0..<w { for k in 0..<4 { p[col * 4 + k] = px[k] } }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        guard let cs = CGColorSpace(name: csName) else { throw XCTSkip("colorspace \(csName) unavailable") }
        CVBufferSetAttachment(pb, kCVImageBufferCGColorSpaceKey, cs, .shouldPropagate)
        return pb
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

    private func compositeSingle(_ buf: CVPixelBuffer, w: Int, h: Int) throws -> (b: Int, g: Int, r: Int) {
        let compositor = try MetalCompositor(device: try device(), width: w, height: h, colorMode: .hdr)
        let sid = SourceID("s")
        let scene = Scene(name: "s", layers: [Layer(sourceID: sid, premultipliedAlpha: false)])
        let prog = try compositor.composite(frames: [sid: VideoFrame(pixelBuffer: buf, pts: HouseClock.now(), source: sid)],
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
            Layer(sourceID: tID, opacity: topOpacity, zIndex: 1, premultipliedAlpha: false),
        ])
        let now = HouseClock.now()
        let prog = try compositor.composite(
            frames: [bID: VideoFrame(pixelBuffer: bottom, pts: now, source: bID),
                     tID: VideoFrame(pixelBuffer: top, pts: now, source: tID)],
            scene: scene, pts: now)
        return read10(prog, x: w / 2, y: h / 2)
    }

    private func makeBGRA(_ w: Int, _ h: Int, r: UInt8, g: UInt8, b: UInt8) throws -> CVPixelBuffer {
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
        return buf
    }

    // MARK: - #5: the FULL enumerated name → (transfer, primaries) table -----------

    /// transfer codes: 0=709 · 1=HLG · 2=PQ · 3=sRGB · 4=Linear.
    /// primaries codes: 0=709 · 1=2020 · 2=P3.  extended = the transfer can carry >1.
    private struct NameCase { let name: CFString; let t: UInt32; let p: UInt32; let ext: Bool; let label: String }
    private var fullTable: [NameCase] {
        [
            // Rec.709 primaries
            NameCase(name: CGColorSpace.itur_709,            t: 0, p: 0, ext: false, label: "itur_709"),
            NameCase(name: CGColorSpace.sRGB,                t: 3, p: 0, ext: false, label: "sRGB"),
            NameCase(name: CGColorSpace.extendedSRGB,        t: 3, p: 0, ext: true,  label: "extendedSRGB"),
            NameCase(name: CGColorSpace.linearSRGB,          t: 4, p: 0, ext: false, label: "linearSRGB"),
            NameCase(name: CGColorSpace.extendedLinearSRGB,  t: 4, p: 0, ext: true,  label: "extendedLinearSRGB"),
            // sol wave-10 #4: genericRGBLinear is the Generic-RGB gamut (primaries
            // code 3), NOT Rec.709 — corrected from the wave-9 p:0 misclassification.
            NameCase(name: CGColorSpace.genericRGBLinear,    t: 4, p: 3, ext: false, label: "genericRGBLinear"),
            NameCase(name: CGColorSpace.itur_709_HLG,        t: 1, p: 0, ext: false, label: "itur_709_HLG"),
            NameCase(name: CGColorSpace.itur_709_PQ,         t: 2, p: 0, ext: false, label: "itur_709_PQ"),
            // Rec.2020 primaries
            NameCase(name: CGColorSpace.itur_2020,           t: 0, p: 1, ext: false, label: "itur_2020"),
            NameCase(name: CGColorSpace.extendedITUR_2020,   t: 0, p: 1, ext: true,  label: "extendedITUR_2020"),
            NameCase(name: CGColorSpace.linearITUR_2020,     t: 4, p: 1, ext: false, label: "linearITUR_2020"),
            NameCase(name: CGColorSpace.extendedLinearITUR_2020, t: 4, p: 1, ext: true, label: "extendedLinearITUR_2020"),
            NameCase(name: CGColorSpace.itur_2020_sRGBGamma, t: 3, p: 1, ext: false, label: "itur_2020_sRGBGamma"),
            NameCase(name: CGColorSpace.itur_2100_HLG,       t: 1, p: 1, ext: false, label: "itur_2100_HLG"),
            NameCase(name: CGColorSpace.itur_2100_PQ,        t: 2, p: 1, ext: false, label: "itur_2100_PQ"),
            // Display-P3 primaries
            NameCase(name: CGColorSpace.displayP3,           t: 3, p: 2, ext: false, label: "displayP3"),
            NameCase(name: CGColorSpace.extendedDisplayP3,   t: 3, p: 2, ext: true,  label: "extendedDisplayP3"),
            NameCase(name: CGColorSpace.linearDisplayP3,     t: 4, p: 2, ext: false, label: "linearDisplayP3"),
            NameCase(name: CGColorSpace.extendedLinearDisplayP3, t: 4, p: 2, ext: true, label: "extendedLinearDisplayP3"),
            NameCase(name: CGColorSpace.displayP3_HLG,       t: 1, p: 2, ext: false, label: "displayP3_HLG"),
            NameCase(name: CGColorSpace.displayP3_PQ,        t: 2, p: 2, ext: false, label: "displayP3_PQ"),
        ]
    }

    func testFullNameTableClassifiesToOracle() throws {
        for c in fullTable {
            let buf = try makeBGRAGrayNameOnly(2, 2, gray: 128, csName: c.name)
            XCTAssertNil(CVBufferCopyAttachment(buf, kCVImageBufferTransferFunctionKey, nil),
                         "\(c.label): test buffer unexpectedly carries a discrete transfer attachment")
            XCTAssertEqual(YCbCrTags.transferCode(for: buf), c.t, "\(c.label): transferCode wrong")
            XCTAssertEqual(YCbCrTags.primariesCode(for: buf), c.p, "\(c.label): primariesCode wrong")
            // rotation: 0 already-2020 (p1) · 2 P3→2020 (p2) · 3 Generic-RGB→2020 (p3,
            // sol wave-10 #4) · 1 709→2020 (p0).
            let expectedRotation: UInt32 = c.p == 1 ? 0 : (c.p == 2 ? 2 : (c.p == 3 ? 3 : 1))
            XCTAssertEqual(YCbCrTags.primariesRotationCode(for: buf), expectedRotation, "\(c.label): rotation wrong")
            XCTAssertEqual(YCbCrTags.isRec2020(for: buf), c.p == 1, "\(c.label): isRec2020 wrong")
            XCTAssertEqual(YCbCrTags.extendedRangeCode(for: buf), c.ext ? 1 : 0, "\(c.label): extendedRange wrong")
        }
    }

    /// The specific composite values sol named for the previously-missing names.
    func testNewNamesCompositeToSpec() throws {
        let w = 32, h = 32
        let v = 128.0 / 255.0

        // extendedDisplayP3 gray → sRGB-transfer + P3 primaries → 726 (NOT the
        // mis-classified-709 765).
        do {
            let got = try compositeSingle(try makeBGRAGrayNameOnly(w, h, gray: 128, csName: CGColorSpace.extendedDisplayP3), w: w, h: h)
            let lin = rotP3to2020(SIMD3(repeating: srgbEOTF(v)))       // gray → neutral preserved
            let correct = code(hlgOETF(lin.x))                          // ≈726
            let bug709 = code(hlgOETF(eotf709(v)))                      // ≈765
            for ch in [got.b, got.g, got.r] {
                XCTAssertLessThanOrEqual(abs(ch - correct), 10, "extDisplayP3 gray \(ch) ≠ \(correct)")
                XCTAssertGreaterThan(abs(ch - bug709), 25, "extDisplayP3 gray matches 709 bug \(bug709)")
            }
        }

        // extendedDisplayP3 RED → the P3 red primary rotated to Rec.2020 → (970,379,0).
        do {
            let got = try compositeSingle(try makeBGRANameOnly(w, h, r: 255, g: 0, b: 0, csName: CGColorSpace.extendedDisplayP3), w: w, h: h)
            let lin = rotP3to2020(SIMD3(srgbEOTF(1.0), srgbEOTF(0.0), srgbEOTF(0.0)))
            let cr = code(hlgOETF(lin.x)), cg = code(hlgOETF(lin.y)), cb = code(hlgOETF(lin.z))
            XCTAssertEqual(cr, 970, "red-primary oracle drift"); XCTAssertEqual(cg, 379); XCTAssertEqual(cb, 0)
            XCTAssertLessThanOrEqual(abs(got.r - cr), 10, "extDisplayP3 red R \(got.r) ≠ \(cr)")
            XCTAssertLessThanOrEqual(abs(got.g - cg), 10, "extDisplayP3 red G \(got.g) ≠ \(cg)")
            XCTAssertLessThanOrEqual(abs(got.b - cb), 6,  "extDisplayP3 red B \(got.b) ≠ \(cb)")
            // Pre-fix (709 primaries, sRGB transfer) red was ≈(935,466,227).
            XCTAssertGreaterThan(abs(got.g - 466), 40, "green matches the 709-primaries bug 466")
        }

        // itur_709_HLG gray → HLG signal round-trips through inverse-then-forward-OETF
        // (709 primaries; rotation preserves neutral) → ≈514 (NOT 765).
        do {
            let got = try compositeSingle(try makeBGRAGrayNameOnly(w, h, gray: 128, csName: CGColorSpace.itur_709_HLG), w: w, h: h)
            let lin = rot709to2020(SIMD3(repeating: hlgInverseOETF(v)))
            let correct = code(hlgOETF(lin.x))                          // ≈514
            let bug709 = code(hlgOETF(eotf709(v)))                      // ≈765
            XCTAssertGreaterThan(abs(correct - bug709), 100, "oracle discriminator too weak")
            for ch in [got.b, got.g, got.r] {
                XCTAssertLessThanOrEqual(abs(ch - correct), 10, "itur_709_HLG gray \(ch) ≠ \(correct)")
                XCTAssertGreaterThan(abs(ch - bug709), 60, "itur_709_HLG matches 765 bug")
            }
        }

        // itur_709_PQ gray → ST 2084 EOTF (×10 nominal norm) → ≈542 (NOT 765).
        do {
            let got = try compositeSingle(try makeBGRAGrayNameOnly(w, h, gray: 128, csName: CGColorSpace.itur_709_PQ), w: w, h: h)
            let lin = rot709to2020(SIMD3(repeating: pqEOTFNorm(v)))
            let correct = code(hlgOETF(lin.x))                          // PQ oracle (~538–542)
            let bug709 = code(hlgOETF(eotf709(v)))                      // ≈765
            XCTAssertGreaterThan(abs(correct - bug709), 100, "oracle discriminator too weak")
            for ch in [got.b, got.g, got.r] {
                XCTAssertLessThanOrEqual(abs(ch - correct), 12, "itur_709_PQ gray \(ch) ≠ \(correct)")
                XCTAssertGreaterThan(abs(ch - bug709), 60, "itur_709_PQ matches 765 bug")
            }
        }

        // itur_2020_sRGBGamma gray → sRGB transfer + Rec.2020 primaries (no rotate) → 726.
        do {
            let got = try compositeSingle(try makeBGRAGrayNameOnly(w, h, gray: 128, csName: CGColorSpace.itur_2020_sRGBGamma), w: w, h: h)
            let correct = code(hlgOETF(srgbEOTF(v)))                    // ≈726 (no rotation on neutral)
            for ch in [got.b, got.g, got.r] {
                XCTAssertLessThanOrEqual(abs(ch - correct), 10, "itur_2020_sRGBGamma gray \(ch) ≠ \(correct)")
            }
        }
    }

    // MARK: - #6: nonlinear extended-range highlight NOT pre-clamped ---------------

    func testExtendedSRGBHighlightNotPreClamped() throws {
        let w = 32, h = 32
        // A name-only extendedSRGB half-float highlight 1.5 (legal extended range) at
        // 25% opacity over black.
        let top = try makeHalfGrayNameOnly(w, h, v: 1.5, csName: CGColorSpace.extendedSRGB)
        let black = try makeBGRA(w, h, r: 0, g: 0, b: 0)
        let got = try compositeOver(top: top, topOpacity: 0.25, bottom: black, w: w, h: h)

        // Independent oracle: extended sRGB EOTF(1.5) = 2.537 CI-linear; 709→2020 keeps
        // neutral; blend 2.537·0.25 = 0.634; encode ONCE → HLG.
        let lin = rot709to2020(SIMD3(repeating: srgbEOTF(1.5))).x
        let correct = code(hlgOETF(lin * 0.25))                        // ≈937
        let preClampBug = code(hlgOETF(srgbEOTF(1.0) * 0.25))          // ≈756 (1.5 saturated → 1.0)
        XCTAssertGreaterThan(abs(correct - preClampBug), 120, "oracle discriminator too weak (\(correct) vs \(preClampBug))")
        for ch in [got.b, got.g, got.r] {
            XCTAssertLessThanOrEqual(abs(ch - correct), 12, "extendedSRGB 1.5@25% channel \(ch) ≠ EDR oracle \(correct)")
            XCTAssertGreaterThan(abs(ch - preClampBug), 60, "channel \(ch) matches the pre-clamp bug \(preClampBug)")
        }
        XCTAssertLessThanOrEqual(abs(got.r - got.g) + abs(got.g - got.b), 4, "not neutral: \(got)")
    }

    /// In-range extendedSRGB (≤1) is UNCHANGED — only values > 1 differ from the
    /// pre-fix pre-clamp behavior, so true-SDR stays byte-identical.
    func testInRangeExtendedSRGBUnchanged() throws {
        let w = 32, h = 32
        let top = try makeHalfGrayNameOnly(w, h, v: 0.5, csName: CGColorSpace.extendedSRGB)
        let got = try compositeSingle(top, w: w, h: h)
        let correct = code(hlgOETF(rot709to2020(SIMD3(repeating: srgbEOTF(0.5))).x))
        for ch in [got.b, got.g, got.r] {
            XCTAssertLessThanOrEqual(abs(ch - correct), 10, "in-range extendedSRGB 0.5 channel \(ch) ≠ \(correct)")
        }
    }

    // MARK: - #7: explicit Rec.709 matrix preserved through materialization ---------

    func testExplicitRec709MatrixPreserved() throws {
        // Source: an HLG NAME (implies Rec.2020) + an EXPLICIT Rec.709 matrix, but NO
        // discrete primaries and NO discrete transfer.
        var srcPB: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &srcPB)
        let src = try XCTUnwrap(srcPB)
        guard let cs = CGColorSpace(name: CGColorSpace.itur_2100_HLG) else { throw XCTSkip("HLG colorspace unavailable") }
        CVBufferSetAttachment(src, kCVImageBufferCGColorSpaceKey, cs, .shouldPropagate)
        CVBufferSetAttachment(src, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        XCTAssertNotNil(CVBufferCopyAttachment(src, kCVImageBufferYCbCrMatrixKey, nil))
        XCTAssertNil(CVBufferCopyAttachment(src, kCVImageBufferColorPrimariesKey, nil))
        XCTAssertNil(CVBufferCopyAttachment(src, kCVImageBufferTransferFunctionKey, nil))

        var destPB: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &destPB)
        let dest = try XCTUnwrap(destPB)
        YCbCrTags.propagateColorTags(from: src, to: dest)

        // The EXPLICIT Rec.709 matrix must be preserved (present discrete fields win),
        // NOT overwritten to Rec.2020 by the HLG-name-derived primaries.
        let mtx = try XCTUnwrap(CVBufferCopyAttachment(dest, kCVImageBufferYCbCrMatrixKey, nil),
                                "materialization dropped the matrix")
        XCTAssertTrue(CFEqual(mtx as AnyObject, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
                      "explicit Rec.709 matrix was overwritten (bug: conflated with absent → Rec.2020)")
        // Primaries were genuinely absent → still materialize from the HLG name (Rec.2020).
        let prim = try XCTUnwrap(CVBufferCopyAttachment(dest, kCVImageBufferColorPrimariesKey, nil),
                                 "absent primaries were not materialized from the name")
        XCTAssertTrue(CFEqual(prim as AnyObject, kCVImageBufferColorPrimaries_ITU_R_2020),
                      "absent primaries should materialize Rec.2020 from the HLG name")
    }

    /// A genuinely-absent matrix still materializes from the classified primaries.
    func testAbsentMatrixMaterializesFromPrimaries() throws {
        var srcPB: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &srcPB)
        let src = try XCTUnwrap(srcPB)
        guard let cs = CGColorSpace(name: CGColorSpace.itur_2100_HLG) else { throw XCTSkip("HLG colorspace unavailable") }
        CVBufferSetAttachment(src, kCVImageBufferCGColorSpaceKey, cs, .shouldPropagate)
        XCTAssertNil(CVBufferCopyAttachment(src, kCVImageBufferYCbCrMatrixKey, nil))

        var destPB: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &destPB)
        let dest = try XCTUnwrap(destPB)
        YCbCrTags.propagateColorTags(from: src, to: dest)
        let mtx = try XCTUnwrap(CVBufferCopyAttachment(dest, kCVImageBufferYCbCrMatrixKey, nil))
        XCTAssertTrue(CFEqual(mtx as AnyObject, kCVImageBufferYCbCrMatrix_ITU_R_2020),
                      "absent matrix should materialize Rec.2020 from the HLG name")
    }
}
