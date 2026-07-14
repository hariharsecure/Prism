import CoreVideo
import Metal
import XCTest

import PrismColor
import PrismCore

/// sol #5 finding 2 — `ColorProcessor` (grade) and `RelightProcessor` linearized
/// the source with a HARDCODED 2.2 power regardless of the source's transfer
/// function, so the linear-light leg (exposure / white-balance / relight) of an
/// **HLG / PQ / Linear** source computed on the wrong domain (an HLG signal +1 stop
/// over-brightened and clipped; a Linear source was treated as 2.2-gamma-coded).
///
/// The fix decodes to TRUE linear per the source's `transferCode`, does the math in
/// linear, and re-encodes with the SAME transfer. A 709 / sRGB (SDR) source keeps
/// the v0 2.2 approximation — byte-identical, UNCHANGED.
///
/// ── INDEPENDENCE OF THE ORACLE ──────────────────────────────────────────────
/// The expected value is computed HERE in Double from the PUBLISHED transfer
/// formulas (BT.2100 HLG OETF + inverse, SMPTE ST 2084 PQ EOTF + inverse), applying
/// the SAME +1-stop exposure as a plain ×2 in linear — never by calling the shader.
/// Each case also asserts the measured value is FAR from the specific pre-fix
/// 2.2-hardcode value, so matching the oracle genuinely rules out the bug.
final class ColorTransferGradeTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    // MARK: - independent from-spec transfer oracle

    private func hlgInvOETF(_ v: Double) -> Double {
        v <= 0.5 ? (v * v) / 3.0 : (exp((v - 0.55991073) / 0.17883277) + 0.28466892) / 12.0
    }
    private func hlgOETF(_ e: Double) -> Double {
        let e = max(e, 0)
        return e <= 1.0 / 12.0 ? (3 * e).squareRoot()
                               : 0.17883277 * log(12 * e - 0.28466892) + 0.55991073
    }
    private func pqEOTF(_ v: Double) -> Double {
        let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let vp = pow(max(v, 0), 1.0 / m2)
        return pow(max(vp - c1, 0) / max(c2 - c3 * vp, 1e-8), 1.0 / m1)
    }
    private func pqOETF(_ l: Double) -> Double {
        let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let lp = pow(max(l, 0), m1)
        return pow((c1 + c2 * lp) / (1.0 + c3 * lp), m2)
    }
    private func sat(_ v: Double) -> Double { min(max(v, 0), 1) }
    /// The PRE-FIX bug: linearize with 2.2, ×gain, re-encode with 1/2.2 (clamped).
    private func gamma22Bug(_ v: Double, gain: Double) -> Double { sat(pow(pow(v, 2.2) * gain, 1.0 / 2.2)) }

    // MARK: - fixture / probe

    /// A neutral-gray `64RGBAHalf` buffer (value `v` on all channels, α=1) tagged
    /// with the given transfer + Rec.2020 primaries/matrix. Feeding a half-float
    /// input lets the grade see the EXACT value (no 8-bit quantization).
    private func makeTaggedHalf(_ w: Int, _ h: Int, v: Double, transfer: CFString) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_64RGBAHalf, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pb else { throw XCTSkip("no half buffer") }
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let hv = Float16(v)
        for row in 0..<h { for col in 0..<w {
            let p = (base + row * bpr + col * 8).assumingMemoryBound(to: Float16.self)
            p[0] = hv; p[1] = hv; p[2] = hv; p[3] = 1.0
        } }
        CVPixelBufferUnlockBaseAddress(pb, [])
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return pb
    }

    private func readHalfG(_ buf: CVPixelBuffer, x: Int, y: Int) -> Double {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(buf)!
            .advanced(by: y * CVPixelBufferGetBytesPerRow(buf) + x * 8)
            .assumingMemoryBound(to: Float16.self)
        return Double(p[1])
    }

    /// Grade `v` (tagged `transfer`) with `exposure` stops and return the output
    /// signal (all other grade params identity).
    private func gradedSignal(v: Double, transfer: CFString, exposure: Double = 1.0) throws -> Double {
        let w = 16, h = 16
        let proc = try ColorProcessor(device: try device())
        let src = try makeTaggedHalf(w, h, v: v, transfer: transfer)
        let out = try proc.process(VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("g")),
                                   grade: ColorGrade(exposure: exposure), lut: nil)
        XCTAssertEqual(out.pixelFormat, kCVPixelFormatType_64RGBAHalf, "expected a 64RGBAHalf grade output")
        return readHalfG(out.pixelBuffer, x: w / 2, y: h / 2)
    }

    // MARK: - HLG / PQ / Linear graded in TRUE linear -----------------------------

    func testHLGSourceGradedInLinear() throws {
        let v = 0.75
        let got = try gradedSignal(v: v, transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG)
        let correct = sat(hlgOETF(hlgInvOETF(v) * 2))          // ≈0.883 (transfer-correct)
        let bug = gamma22Bug(v, gain: 2)                        // ≈1.0 (2.2 over-brightens → clip)
        XCTAssertGreaterThan(abs(correct - bug), 0.08, "HLG oracle discriminator weak (\(correct) vs \(bug))")
        XCTAssertLessThanOrEqual(abs(got - correct), 0.012, "HLG +1 stop \(got) ≠ transfer-correct \(correct)")
        XCTAssertGreaterThan(abs(got - bug), 0.06, "HLG +1 stop \(got) matches the 2.2-hardcode bug \(bug)")
    }

    func testPQSourceGradedInLinear() throws {
        let v = 0.5
        let got = try gradedSignal(v: v, transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
        let correct = sat(pqOETF(pqEOTF(v) * 2))               // ≈0.574 (transfer-correct)
        let bug = gamma22Bug(v, gain: 2)                        // ≈0.685 (2.2)
        XCTAssertGreaterThan(abs(correct - bug), 0.08, "PQ oracle discriminator weak (\(correct) vs \(bug))")
        XCTAssertLessThanOrEqual(abs(got - correct), 0.012, "PQ +1 stop \(got) ≠ transfer-correct \(correct)")
        XCTAssertGreaterThan(abs(got - bug), 0.06, "PQ +1 stop \(got) matches the 2.2-hardcode bug \(bug)")
    }

    func testLinearSourceGradedInLinear() throws {
        let v = 0.68
        let got = try gradedSignal(v: v, transfer: kCVImageBufferTransferFunction_Linear)
        // sol #6 finding 6: Linear is EXTENDED range — ×2 of 0.68 is 1.36 and must NOT
        // clamp to white (a legal EDR highlight; the 64RGBAHalf output holds it). The
        // final clamp is deferred to the output encode. (Pre-sol#6 the shader clamped
        // this to 1.0, which THIS test's oracle wrongly baked in as `sat(v*2)`.)
        let correct = v * 2                                     // 1.36 (unclamped EDR)
        let bug = gamma22Bug(v, gain: 2)                        // ≈0.932 (2.2 → not yet clipped)
        XCTAssertGreaterThan(abs(correct - bug), 0.05, "Linear oracle discriminator weak (\(correct) vs \(bug))")
        XCTAssertLessThanOrEqual(abs(got - correct), 0.012, "Linear +1 stop \(got) ≠ transfer-correct \(correct)")
        XCTAssertGreaterThan(abs(got - bug), 0.04, "Linear +1 stop \(got) matches the 2.2-hardcode bug \(bug)")
    }

    // MARK: - Relight also decodes per transfer (ambient=2 == a ×2 linear scale) ---

    func testRelightHLGSourceInLinear() throws {
        let w = 16, h = 16, v = 0.75
        let relight = try RelightProcessor(device: try device())
        relight.ambient = 2      // base × ambient in LINEAR (no lights) — a ×2 linear scale
        relight.depthScale = 0   // flat depth → no normal shading contribution
        // A flat depth map (relight samples it normalized; value is irrelevant at scale 0).
        var depth: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_OneComponent8,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &depth)
        guard let depth else { throw XCTSkip("no depth buffer") }
        CVPixelBufferLockBaseAddress(depth, [])
        let db = CVPixelBufferGetBaseAddress(depth)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { memset(db + y * CVPixelBufferGetBytesPerRow(depth), 128, w) }
        CVPixelBufferUnlockBaseAddress(depth, [])

        let src = try makeTaggedHalf(w, h, v: v, transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG)
        let out = try relight.process(frame: VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("r")),
                                      depth: depth, lights: [])
        let got = readHalfG(out.pixelBuffer, x: w / 2, y: h / 2)
        let correct = sat(hlgOETF(hlgInvOETF(v) * 2))          // relight in TRUE linear
        let bug = gamma22Bug(v, gain: 2)                        // the 2.2-hardcode relight
        XCTAssertLessThanOrEqual(abs(got - correct), 0.02, "relight HLG \(got) ≠ transfer-correct \(correct)")
        XCTAssertGreaterThan(abs(got - bug), 0.06, "relight HLG \(got) matches the 2.2-hardcode bug \(bug)")
    }

    // MARK: - control: a 709 / sRGB SDR source is UNCHANGED (still the 2.2 path) ---

    func test709SourceUnchanged() throws {
        let v = 0.5
        let got709 = try gradedSignal(v: v, transfer: kCVImageBufferTransferFunction_ITU_R_709_2)
        let got_sRGB = try gradedSignal(v: v, transfer: kCVImageBufferTransferFunction_sRGB)
        let expected = gamma22Bug(v, gain: 2)                   // the v0 2.2 approximation (unchanged)
        XCTAssertLessThanOrEqual(abs(got709 - expected), 0.012, "709 source changed by the fix (\(got709) vs \(expected))")
        // sRGB is treated the same 2.2 approximation as 709 (finding: 709/sRGB unchanged).
        XCTAssertLessThanOrEqual(abs(got_sRGB - expected), 0.012, "sRGB source changed by the fix (\(got_sRGB) vs \(expected))")
    }

    // MARK: - sol #6 finding 6: Linear EDR highlights (> 1) are NOT pre-clamped -----

    /// A legal Linear EDR value of 1.5 with −1 stop (×0.5) must emit 0.75 — the value
    /// flows through grade in extended range. Pre-fix the input `saturate` clamped 1.5
    /// to 1.0 BEFORE the exposure math, so it emitted 0.5. (A Linear source is the
    /// engine's extended-range float working space; a 64RGBAHalf output holds > 1.)
    func testLinearEDRHighlightNotPreClampedInGrade() throws {
        let got = try gradedSignal(v: 1.5, transfer: kCVImageBufferTransferFunction_Linear, exposure: -1.0)
        let correct = 0.75                                       // 1.5 × 0.5, unclamped
        let preClampBug = 0.5                                    // saturate(1.5)=1.0 → ×0.5
        XCTAssertGreaterThan(abs(correct - preClampBug), 0.2, "oracle discriminator weak")
        XCTAssertLessThanOrEqual(abs(got - correct), 0.01, "Linear 1.5 −1 stop \(got) ≠ 0.75 (pre-clamped)")
        XCTAssertGreaterThan(abs(got - preClampBug), 0.1, "Linear 1.5 −1 stop \(got) matches the pre-clamp bug 0.5")
    }

    /// The IN-RANGE Linear case is unchanged: 0.5 with −1 stop → 0.25 (no clamp
    /// involved either way, so the fix must not perturb it).
    func testLinearInRangeGradeUnchanged() throws {
        let got = try gradedSignal(v: 0.5, transfer: kCVImageBufferTransferFunction_Linear, exposure: -1.0)
        XCTAssertLessThanOrEqual(abs(got - 0.25), 0.01, "in-range Linear 0.5 −1 stop \(got) ≠ 0.25")
    }

    /// Relight has the same defect: a Linear 1.5 base with a ½ (ambient 0.5, no lights)
    /// shade must emit 0.75, not the pre-clamped 0.5.
    func testLinearEDRHighlightNotPreClampedInRelight() throws {
        let w = 16, h = 16, v = 1.5
        let relight = try RelightProcessor(device: try device())
        relight.ambient = 0.5    // base × ambient in LINEAR (no lights) — a ×0.5 linear scale
        relight.depthScale = 0   // flat depth → no normal shading contribution
        var depth: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_OneComponent8,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &depth)
        guard let depth else { throw XCTSkip("no depth buffer") }
        CVPixelBufferLockBaseAddress(depth, [])
        let db = CVPixelBufferGetBaseAddress(depth)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { memset(db + y * CVPixelBufferGetBytesPerRow(depth), 128, w) }
        CVPixelBufferUnlockBaseAddress(depth, [])

        let src = try makeTaggedHalf(w, h, v: v, transfer: kCVImageBufferTransferFunction_Linear)
        let out = try relight.process(frame: VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("r")),
                                      depth: depth, lights: [])
        let got = readHalfG(out.pixelBuffer, x: w / 2, y: h / 2)
        XCTAssertLessThanOrEqual(abs(got - 0.75), 0.02, "relight Linear 1.5 ×0.5 \(got) ≠ 0.75 (pre-clamped)")
        XCTAssertGreaterThan(abs(got - 0.5), 0.1, "relight Linear 1.5 ×0.5 \(got) matches the pre-clamp bug 0.5")
    }
}
