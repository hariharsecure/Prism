import CoreGraphics
import CoreMedia
import CoreVideo
import Metal
import XCTest

import PrismColor
import PrismCore
import PrismVision

/// sol #11 #3 + #4 (both MEDIUM, pre-existing alpha-handling bugs) — reproduced FIRST
/// at sol's exact wrong values against an INDEPENDENT from-spec Double oracle, then
/// fixed.
///
///  #3 GRADE — `prism_grade_bgra` graded the PREMULTIPLIED sampled rgb (rgb·α) as if it
///     were straight, so an alpha-bearing source was graded on its α-DARKENED color: a
///     valid HLG overlay at straight signal 0.75 / α0.25 (stored premult 0.1875) at
///     +1 stop stored 0.265137 (downstream 756) instead of the correct 0.220635 (622).
///     FIX: un-premultiply to straight (α>0 ? rgb/α : rgb) BEFORE the grade, re-premultiply
///     the graded rgb by α. Opaque (α==1) + YUV (α always 1) divide by one → byte-identical.
///
///  #4 BACKGROUND REMOVE — `prism_bg_bgra` remove emitted (rgb·m, m), REPLACING the
///     source α with the matte, so an alpha-bearing source acquired OPAQUE regions under
///     background removal: an all-person matte (m=1) over an input α0.25 emitted output
///     α1.0 instead of 0.25. FIX: intersect — output α = m·srcA, rgb = premult·m. A
///     fully-opaque source (srcA==1) and YUV are byte-identical.
///
/// ── INDEPENDENT ORACLE ──────────────────────────────────────────────────────
///  #3: the HLG OETF / inverse-OETF are re-derived HERE in Double from BT.2100 / ARIB
///      STD-B67 (never the shader); the correct stored value is `HLG_OETF(HLG_invOETF(0.75)·2)·α`,
///      and each assertion also pins the measured value FAR from the pre-fix bug 0.265137.
///  #4: the remove coverage is the intersection m·srcA (m=1 all-person → α = srcA = 0.25),
///      pinned FAR from the pre-fix bug 1.0.
final class SolGradeBgAlphaTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    // MARK: - from-spec HLG oracle (BT.2100 / ARIB STD-B67), never the shader ------

    private func hlgInvOETF(_ v: Double) -> Double {
        v <= 0.5 ? (v * v) / 3.0 : (exp((v - 0.55991073) / 0.17883277) + 0.28466892) / 12.0
    }
    private func hlgOETF(_ e: Double) -> Double {
        let e = max(e, 0)
        return e <= 1.0 / 12.0 ? (3 * e).squareRoot()
                               : 0.17883277 * log(12 * e - 0.28466892) + 0.55991073
    }
    private func sat(_ v: Double) -> Double { min(max(v, 0), 1) }

    // MARK: - Fixtures ----------------------------------------------------------

    /// A `64RGBAHalf` holding an already-**premultiplied** pixel (stored rgb = straight·α,
    /// stored α = α — an ordinary premultiplied-alpha frame), optionally colorimetry-tagged.
    private func makePremultHalf(_ w: Int, _ h: Int,
                                 straightR: Double, straightG: Double, straightB: Double,
                                 alpha: Double,
                                 transfer: CFString? = nil, csName: CFString? = nil) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_64RGBAHalf,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else {
            throw XCTSkip("could not allocate 64RGBAHalf")
        }
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let px: [Float16] = [Float16(straightR * alpha), Float16(straightG * alpha),
                             Float16(straightB * alpha), Float16(alpha)]
        for row in 0..<h {
            let p = (base + row * bpr).assumingMemoryBound(to: Float16.self)
            for col in 0..<w { for k in 0..<4 { p[col * 4 + k] = px[k] } }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        if let transfer {
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        }
        if let csName, let cs = CGColorSpace(name: csName) {
            CVBufferSetAttachment(pb, kCVImageBufferCGColorSpaceKey, cs, .shouldPropagate)
        }
        return pb
    }

    /// A neutral `64RGBAHalf`, α=1, tagged with `transfer` + Rec.2020 (the OPAQUE control).
    private func makeTaggedHalf(_ w: Int, _ h: Int, v: Double, transfer: CFString) throws -> CVPixelBuffer {
        try makePremultHalf(w, h, straightR: v, straightG: v, straightB: v, alpha: 1.0, transfer: transfer)
    }

    /// An OPAQUE (α=255) 32BGRA fill.
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

    /// A OneComponent8 matte filled with `value` (255 = all-person, 0 = all-background).
    private func makeMatte(_ w: Int, _ h: Int, value: UInt8, pts: CMTime) throws -> SegmentationMatte {
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_OneComponent8, minimumBufferCount: 1)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<h { for col in 0..<w { base[row * bpr + col] = value } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return SegmentationMatte(pixelBuffer: buf, pts: pts, source: SourceID("m"))
    }

    // MARK: - Read helpers ------------------------------------------------------

    private func readHalf(_ frame: VideoFrame, x: Int, y: Int, ch: Int) -> Double {
        let buf = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(buf)!
            .advanced(by: y * CVPixelBufferGetBytesPerRow(buf) + x * 8)
            .assumingMemoryBound(to: Float16.self)
        return Double(p[ch])
    }
    private func readBGRA(_ frame: VideoFrame, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let buf = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            + y * CVPixelBufferGetBytesPerRow(buf) + x * 4
        return (Int(p[2]), Int(p[1]), Int(p[0]), Int(p[3]))
    }

    // MARK: - #3 GRADE un-premultiply -------------------------------------------

    /// sol's exact case: a valid HLG overlay, straight signal 0.75 / α0.25, +1 stop. The
    /// straight color must be graded (→ HLG 0.8825) and re-premultiplied by α (→ 0.2206).
    /// Pre-fix graded the premult 0.1875 as straight → 0.2651 (downstream 756 not 622).
    func testGradePartialAlphaUnpremultiplied() throws {
        let w = 16, h = 16
        let alpha = 0.25, straight = 0.75
        let src = try makePremultHalf(w, h, straightR: straight, straightG: straight, straightB: straight,
                                      alpha: alpha, transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG)
        let out = try ColorProcessor(device: try device()).process(
            VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("gpa")),
            grade: ColorGrade(exposure: 1.0), lut: nil)
        XCTAssertEqual(out.pixelFormat, kCVPixelFormatType_64RGBAHalf)

        // Oracle (Double, from BT.2100 HLG): grade the STRAIGHT color, then re-premultiply.
        let straightGraded = sat(hlgOETF(hlgInvOETF(straight) * 2))     // ≈ 0.8825
        let correct = straightGraded * alpha                            // ≈ 0.2206
        // The pre-fix bug: grade the PREMULT rgb (0.1875) as straight, carry α unchanged.
        let bug = sat(hlgOETF(hlgInvOETF(straight * alpha) * 2))        // ≈ 0.2651
        XCTAssertGreaterThan(abs(correct - bug), 0.03, "grade oracle discriminator weak (\(correct) vs \(bug))")

        let gotG = readHalf(out, x: w / 2, y: h / 2, ch: 1)             // premultiplied stored green
        XCTAssertLessThanOrEqual(abs(gotG - correct), 0.01,
                                 "partial-α grade \(gotG) ≠ straight-graded·α \(correct)")
        XCTAssertGreaterThan(abs(gotG - bug), 0.02,
                             "partial-α grade \(gotG) matches the pre-fix premult-as-straight bug \(bug) (≈0.265137)")
        // Alpha carried through unchanged.
        XCTAssertLessThanOrEqual(abs(readHalf(out, x: w / 2, y: h / 2, ch: 3) - alpha), 0.005, "grade dropped α")
    }

    /// Un-premultiply recovers the SAME straight grade an opaque source gets: the α0.25
    /// premult output ÷ 0.25 equals the α1 opaque grade (byte-identical straight math).
    func testGradeOpaqueControlByteIdentical() throws {
        let w = 16, h = 16
        let straight = 0.75
        let opaque = try makeTaggedHalf(w, h, v: straight, transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG)
        let cp = try ColorProcessor(device: try device())
        let opaqueOut = try cp.process(VideoFrame(pixelBuffer: opaque, pts: HouseClock.now(), source: SourceID("op")),
                                       grade: ColorGrade(exposure: 1.0), lut: nil)
        let opaqueG = readHalf(opaqueOut, x: w / 2, y: h / 2, ch: 1)    // straight-graded (α=1, no-op)

        let premult = try makePremultHalf(w, h, straightR: straight, straightG: straight, straightB: straight,
                                          alpha: 0.25, transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG)
        let premultOut = try cp.process(VideoFrame(pixelBuffer: premult, pts: HouseClock.now(), source: SourceID("pm")),
                                        grade: ColorGrade(exposure: 1.0), lut: nil)
        let recoveredStraight = readHalf(premultOut, x: w / 2, y: h / 2, ch: 1) / 0.25
        XCTAssertLessThanOrEqual(abs(recoveredStraight - opaqueG), 0.01,
                                 "un-premult grade \(recoveredStraight) ≠ opaque grade \(opaqueG)")
        XCTAssertGreaterThanOrEqual(opaqueG, 0.85, "HLG +1 stop opaque control not ≈0.8825 (got \(opaqueG))")
    }

    /// wave-11 EDR carry preserved: an OPAQUE (α=1) extendedSRGB 1.5 identity-grades to a
    /// value > 1 (the >1 highlight survives — the un-premult by 1 is a no-op on the EDR path).
    func testGradeEDRUnchanged() throws {
        let w = 16, h = 16
        let src = try makePremultHalf(w, h, straightR: 1.5, straightG: 1.5, straightB: 1.5,
                                      alpha: 1.0, csName: CGColorSpace.extendedSRGB)
        let out = try ColorProcessor(device: try device()).process(
            VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("edr")),
            grade: ColorGrade(), lut: nil)
        XCTAssertGreaterThan(readHalf(out, x: w / 2, y: h / 2, ch: 1), 1.4, "extendedSRGB 1.5 EDR carry regressed")
    }

    // MARK: - #4 BACKGROUND REMOVE intersects source α --------------------------

    /// sol's exact case: an all-person matte (m=1) over an input α0.25 must KEEP α0.25 —
    /// removal intersects the matte with the source's existing coverage. Pre-fix REPLACED
    /// α with the matte → α1.0 (an alpha-bearing source became opaque under removal).
    func testRemovePreservesSourceAlpha() throws {
        let w = 16, h = 16
        let pts = HouseClock.now()
        let src = try makePremultHalf(w, h, straightR: 0.6, straightG: 0.4, straightB: 0.2, alpha: 0.25)
        let matte = try makeMatte(w, h, value: 255, pts: pts)             // identity oracle: all-person
        let out = try BackgroundEffect(device: try device()).apply(
            frame: VideoFrame(pixelBuffer: src, pts: pts, source: SourceID("rm")), matte: matte, mode: .remove)
        XCTAssertEqual(out.pixelFormat, kCVPixelFormatType_64RGBAHalf)
        // Oracle: output α = m·srcA = 1·0.25 = 0.25.
        let gotA = readHalf(out, x: w / 2, y: h / 2, ch: 3)
        XCTAssertLessThanOrEqual(abs(gotA - 0.25), 0.01, "remove did not preserve source α (got \(gotA))")
        XCTAssertGreaterThan(abs(gotA - 1.0), 0.5, "α matches the pre-fix overwrite bug 1.0")
        // Premult rgb = straight·α·m = straight·0.25 (m=1) — unchanged, still consistent with α.
        XCTAssertLessThanOrEqual(abs(readHalf(out, x: w / 2, y: h / 2, ch: 0) - 0.6 * 0.25), 0.01, "remove premult r wrong")
    }

    /// A fully-OPAQUE source is byte-identical: all-person matte → α255; the removed
    /// (matte 0) region → α0 for both opaque and alpha-bearing sources.
    func testRemoveOpaqueControlAndRemovedRegion() throws {
        let w = 16, h = 16
        let pts = HouseClock.now()
        let be = try BackgroundEffect(device: try device())

        // Opaque BGRA, all-person matte → α255 (unchanged).
        let opaque = try makeBGRA(w, h, r: 200, g: 100, b: 50)
        let keptOut = try be.apply(frame: VideoFrame(pixelBuffer: opaque, pts: pts, source: SourceID("ok")),
                                   matte: try makeMatte(w, h, value: 255, pts: pts), mode: .remove)
        XCTAssertEqual(keptOut.pixelFormat, kCVPixelFormatType_32BGRA)
        let kept = readBGRA(keptOut, x: w / 2, y: h / 2)
        XCTAssertGreaterThanOrEqual(kept.a, 254, "opaque foreground α not kept: \(kept)")
        XCTAssertEqual(kept.r, 200, "opaque foreground color lost: \(kept)")

        // Opaque BGRA, all-background matte → α0.
        let removedOut = try be.apply(frame: VideoFrame(pixelBuffer: try makeBGRA(w, h, r: 200, g: 100, b: 50),
                                                        pts: pts, source: SourceID("orm")),
                                      matte: try makeMatte(w, h, value: 0, pts: pts), mode: .remove)
        XCTAssertLessThanOrEqual(readBGRA(removedOut, x: w / 2, y: h / 2).a, 1, "opaque removed region not transparent")

        // Alpha-bearing source, all-background matte → α0 (m·srcA = 0).
        let alphaRemoved = try be.apply(
            frame: VideoFrame(pixelBuffer: try makePremultHalf(w, h, straightR: 0.6, straightG: 0.4, straightB: 0.2, alpha: 0.25),
                              pts: pts, source: SourceID("arm")),
            matte: try makeMatte(w, h, value: 0, pts: pts), mode: .remove)
        XCTAssertLessThanOrEqual(readHalf(alphaRemoved, x: w / 2, y: h / 2, ch: 3), 0.01, "alpha-source removed region not transparent")
    }
}
