import CoreGraphics
import CoreMedia
import CoreVideo
import Metal
import XCTest

import PrismCompositor
import PrismCore

/// sol #7 — the last color-completeness edges of the linear-light HDR path.
/// Three runtime-confirmed defects this suite reproduces (at sol's exact wrong
/// value, against an INDEPENDENT from-spec oracle) then locks down:
///
///  - **#5new** the COMPOSITOR saturates a Linear (extended-range EDR) layer to 1.0
///    BEFORE the opacity/blend, so a Linear 1.5 layer at 50% opacity composited to
///    HLG **892** (== the pre-blend-clamp result HLG_OETF(0.5)) instead of the
///    correct **969** (HLG_OETF(1.5·0.5) = HLG_OETF(0.75)). The extended range must
///    survive the linear blend and be clamped ONLY at the final output encode.
///  - **#7** a name-only `extendedLinearDisplayP3` colorspace is misclassified as
///    Rec.709/nonlinear → composited to **765** instead of the Linear/Display-P3
///    **892** (Linear transfer skips the EOTF; P3 primaries rotate P3→2020).
///  - **#10** `propagateColorTags` materialized the full discrete set only when the
///    transfer attachment was ABSENT — a source with a NAME + an explicit discrete
///    transfer still exited WITHOUT discrete primaries/matrix.
///
/// ── INDEPENDENCE OF THE ORACLE ──────────────────────────────────────────────
/// Every expected value is computed HERE, in Double, from the PUBLISHED formulas
/// (BT.709 EOTF, sRGB EOTF, BT.2100 HLG OETF) and the composite arithmetic is done
/// by the test — never by calling the shader. Each correctness target also asserts
/// the measured pixel is FAR from the specific pre-fix wrong value sol found.
final class ColorCompletenessEdgesTests: XCTestCase {

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
    private func sat(_ v: Double) -> Double { min(max(v, 0), 1) }
    private func code(_ v: Double) -> Int { Int((sat(v) * 1023).rounded()) }

    // MARK: - Fixtures / probe --------------------------------------------------

    /// A neutral `64RGBAHalf` buffer at extended-range float value `v` on RGB, α=1.
    private func makeHalfGray(_ w: Int, _ h: Int, v: Double,
                             transfer: CFString? = nil, primaries: CFString? = nil,
                             matrix: CFString? = nil) throws -> CVPixelBuffer {
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
        if let transfer { CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate) }
        if let primaries { CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate) }
        if let matrix { CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate) }
        return pb
    }

    /// A solid BGRA8 buffer carrying ONLY a named CGColorSpace attachment.
    private func makeBGRANameOnly(_ w: Int, _ h: Int, gray: UInt8, csName: CFString) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_32BGRA)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<h { for col in 0..<w {
            let p = base + row * bpr + col * 4
            p[0] = gray; p[1] = gray; p[2] = gray; p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        guard let cs = CGColorSpace(name: csName) else { throw XCTSkip("colorspace \(csName) unavailable") }
        CVBufferSetAttachment(buf, kCVImageBufferCGColorSpaceKey, cs, .shouldPropagate)
        // Deliberately NO discrete transfer / primaries / matrix — the name is the only signal.
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

    // MARK: - #5new: Linear EDR carried through the blend, clamped only at encode --

    func testLinearEDRHighlightNotPreClampedBeforeBlend() throws {
        let w = 32, h = 32
        // A Linear (scene-linear) Rec.2020 EDR layer at value 1.5 — a legal extended-
        // range highlight (only a float texture can carry it). Composited at 50%
        // opacity over black.
        let edr = try makeHalfGray(w, h, v: 1.5)
        YCbCrTags.stampLinearRec2020(edr)   // Linear transfer (skip EOTF) + Rec.2020 (no re-rotate)
        let black = try makeBGRA(w, h, r: 0, g: 0, b: 0)
        let got = try compositeOver(top: edr, topOpacity: 0.5, bottom: black, w: w, h: h)

        // Independent oracle: blend 1.5·0.5 = 0.75 LIGHT (Linear, no EOTF; Rec.2020,
        // no rotate) over black, encode ONCE at output.
        let correct = code(hlgOETF(0.75))               // ≈969
        let preClampBug = code(hlgOETF(0.5))            // ≈892 (1.5 saturated to 1.0 first)
        XCTAssertGreaterThan(abs(correct - preClampBug), 60, "oracle discriminator too weak (\(correct) vs \(preClampBug))")

        for ch in [got.b, got.g, got.r] {
            XCTAssertLessThanOrEqual(abs(ch - correct), 12, "Linear-1.5@50% channel \(ch) ≠ EDR-blend oracle \(correct)")
            XCTAssertGreaterThan(abs(ch - preClampBug), 40, "channel \(ch) matches the pre-blend-clamp bug \(preClampBug)")
        }
        XCTAssertLessThanOrEqual(abs(got.r - got.g) + abs(got.g - got.b), 4, "not neutral: \(got)")
    }

    /// A Linear layer at value 1.0 (in-range) is UNCHANGED — the fix only affects
    /// values > 1, so the existing in-range Linear behavior stays byte-identical.
    func testLinearInRangeUnchanged() throws {
        let w = 32, h = 32
        let lin = try makeHalfGray(w, h, v: 0.5)
        YCbCrTags.stampLinearRec2020(lin)
        let got = try compositeSingle(lin, w: w, h: h)
        let correct = code(hlgOETF(0.5))                // ≈892 (Linear 0.5 → HLG)
        for ch in [got.b, got.g, got.r] {
            XCTAssertLessThanOrEqual(abs(ch - correct), 10, "in-range Linear 0.5 channel \(ch) ≠ \(correct)")
        }
    }

    // MARK: - #7: name-only extendedLinearDisplayP3 → Linear + Display-P3 ---------

    func testExtendedLinearDisplayP3NameClassifiesLinearP3() throws {
        // A buffer that advertises extendedLinearDisplayP3 by NAME alone.
        let buf = try makeBGRANameOnly(2, 2, gray: 128, csName: CGColorSpace.extendedLinearDisplayP3)
        XCTAssertNil(CVBufferCopyAttachment(buf, kCVImageBufferTransferFunctionKey, nil),
                     "test buffer unexpectedly carries a discrete transfer attachment")
        XCTAssertEqual(YCbCrTags.transferCode(for: buf), 4, "extendedLinearDisplayP3 name not classified Linear (fell back to 709)")
        XCTAssertEqual(YCbCrTags.primariesCode(for: buf), 2, "extendedLinearDisplayP3 name not classified Display-P3")
        XCTAssertEqual(YCbCrTags.primariesRotationCode(for: buf), 2, "extendedLinearDisplayP3 not rotated P3→2020")
    }

    func testExtendedLinearDisplayP3CompositesLinearNot709() throws {
        let w = 32, h = 32
        let buf = try makeBGRANameOnly(w, h, gray: 128, csName: CGColorSpace.extendedLinearDisplayP3)
        let got = try compositeSingle(buf, w: w, h: h)

        let v = 128.0 / 255.0
        // Correct: Linear (skip EOTF) → P3→2020 (neutral preserved) → HLG OETF.
        let correct = code(hlgOETF(v))                  // ≈892
        // BUG: misclassified Rec.709 → 709 EOTF → 709→2020 → HLG OETF.
        let bug709 = code(hlgOETF(eotf709(v)))          // ≈765
        XCTAssertGreaterThan(abs(correct - bug709), 100, "oracle discriminator too weak (\(correct) vs \(bug709))")
        for ch in [got.b, got.g, got.r] {
            XCTAssertLessThanOrEqual(abs(ch - correct), 10, "extLinearP3 channel \(ch) ≠ Linear oracle \(correct)")
            XCTAssertGreaterThan(abs(ch - bug709), 60, "channel \(ch) matches the mis-classified-709 bug \(bug709)")
        }
    }

    /// The existing HLG / PQ name fallbacks are unchanged by the added names.
    func testExistingNameFallbacksUnchanged() throws {
        let hlg = try makeBGRANameOnly(2, 2, gray: 128, csName: CGColorSpace.itur_2100_HLG)
        XCTAssertEqual(YCbCrTags.transferCode(for: hlg), 1, "HLG name fallback regressed")
        XCTAssertEqual(YCbCrTags.primariesRotationCode(for: hlg), 0)
        let pq = try makeBGRANameOnly(2, 2, gray: 128, csName: CGColorSpace.itur_2100_PQ)
        XCTAssertEqual(YCbCrTags.transferCode(for: pq), 2, "PQ name fallback regressed")
        // extendedLinearITUR_2020 → Linear + Rec.2020; extendedLinearSRGB → Linear + 709.
        let lin2020 = try makeBGRANameOnly(2, 2, gray: 128, csName: CGColorSpace.extendedLinearITUR_2020)
        XCTAssertEqual(YCbCrTags.transferCode(for: lin2020), 4)
        XCTAssertEqual(YCbCrTags.primariesRotationCode(for: lin2020), 0, "extendedLinearITUR_2020 should be already-2020")
        let linSRGB = try makeBGRANameOnly(2, 2, gray: 128, csName: CGColorSpace.extendedLinearSRGB)
        XCTAssertEqual(YCbCrTags.transferCode(for: linSRGB), 4)
        XCTAssertEqual(YCbCrTags.primariesRotationCode(for: linSRGB), 1, "extendedLinearSRGB should rotate 709→2020")
    }

    // MARK: - #10: named + explicit-transfer source fully materialized ------------

    func testNamedPlusExplicitTransferMaterializesPrimariesAndMatrix() throws {
        // Source: a CGColorSpace NAME (implies Rec.2020) + an EXPLICIT discrete
        // transfer attachment, but NO discrete primaries / matrix.
        var srcPB: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &srcPB)
        let src = try XCTUnwrap(srcPB)
        guard let cs = CGColorSpace(name: CGColorSpace.itur_2100_HLG) else { throw XCTSkip("HLG colorspace unavailable") }
        CVBufferSetAttachment(src, kCVImageBufferCGColorSpaceKey, cs, .shouldPropagate)
        CVBufferSetAttachment(src, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        // Preconditions: a discrete transfer, but NO discrete primaries / matrix.
        XCTAssertNotNil(CVBufferCopyAttachment(src, kCVImageBufferTransferFunctionKey, nil))
        XCTAssertNil(CVBufferCopyAttachment(src, kCVImageBufferColorPrimariesKey, nil))
        XCTAssertNil(CVBufferCopyAttachment(src, kCVImageBufferYCbCrMatrixKey, nil))

        var destPB: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &destPB)
        let dest = try XCTUnwrap(destPB)
        YCbCrTags.propagateColorTags(from: src, to: dest)

        // The full discrete set must now ride on the output — a stage that reads only
        // discrete attachments must still see Rec.2020 primaries + matrix.
        let prim = CVBufferCopyAttachment(dest, kCVImageBufferColorPrimariesKey, nil)
        let mtx = CVBufferCopyAttachment(dest, kCVImageBufferYCbCrMatrixKey, nil)
        let tf = CVBufferCopyAttachment(dest, kCVImageBufferTransferFunctionKey, nil)
        XCTAssertNotNil(prim, "named+explicit-transfer source did NOT emit discrete primaries (#10)")
        XCTAssertNotNil(mtx, "named+explicit-transfer source did NOT emit discrete matrix (#10)")
        XCTAssertNotNil(tf, "transfer attachment lost")
        if let prim { XCTAssertTrue(CFEqual(prim as AnyObject, kCVImageBufferColorPrimaries_ITU_R_2020),
                                    "materialized primaries not Rec.2020") }
        if let mtx { XCTAssertTrue(CFEqual(mtx as AnyObject, kCVImageBufferYCbCrMatrix_ITU_R_2020),
                                   "materialized matrix not Rec.2020") }
        if let tf { XCTAssertTrue(CFEqual(tf as AnyObject, kCVImageBufferTransferFunction_ITU_R_2100_HLG),
                                  "transfer changed from HLG") }
        // Downstream reads it as Rec.2020 (would have double-rotated if left untagged).
        XCTAssertTrue(YCbCrTags.isRec2020(for: dest))
    }

    /// A fully-untagged source (no name, no discrete) stays untagged — the fix only
    /// fires when a colorspace NAME is present.
    func testFullyUntaggedStaysUntagged() throws {
        var srcPB: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &srcPB)
        let src = try XCTUnwrap(srcPB)
        var destPB: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &destPB)
        let dest = try XCTUnwrap(destPB)
        YCbCrTags.propagateColorTags(from: src, to: dest)
        XCTAssertNil(CVBufferCopyAttachment(dest, kCVImageBufferColorPrimariesKey, nil), "untagged source gained primaries")
        XCTAssertNil(CVBufferCopyAttachment(dest, kCVImageBufferTransferFunctionKey, nil), "untagged source gained transfer")
    }
}
