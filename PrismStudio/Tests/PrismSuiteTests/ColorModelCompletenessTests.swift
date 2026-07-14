import CoreGraphics
import CoreVideo
import Metal
import XCTest

import PrismColor
import PrismCompositor
import PrismCore

/// sol #6 — the wave-6 colour-model fixes were correct for HLG but WRONG for the
/// PQ / Rec.709 / name-only edge cases. This suite reproduces the exact wrong values
/// against INDEPENDENT from-spec oracles, then locks in the corrected behaviour.
///
///  - #2 `YCbCrTags.srgbColor(_:inSpaceOf:)` — a UI/sRGB colour must be re-encoded
///    into EACH target transfer. For **PQ** it must invert the compositor's ×10
///    nominal-nit normalization (a full sRGB gray strobe over a PQ source emitted a
///    clipped 1023 instead of the correct ≈726); for **Rec.709** it must apply the
///    sRGB→709 transfer (0.5 → 0.45019), NOT return the value unchanged. HLG stays
///    correct.
///  - #3 `propagateColorTags` — a NAME-ONLY HDR source (CGColorSpace name, no discrete
///    transfer attachment) lost its colorimetry across a derived stage (exited
///    transferCode 0 / Rec.709). The colorimetry must be carried forward so a name-only
///    HLG source keeps HLG classification on its output.
///
/// Oracles are published closed-form transfer functions computed HERE in Double, never
/// the shader/library math they check.
final class ColorModelCompletenessTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    // MARK: - independent from-spec oracle -----------------------------------------

    private func srgbEOTF(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    private func oetf709(_ v: Double) -> Double { v < 0.018 ? 4.5 * v : 1.099 * pow(max(v, 0), 0.45) - 0.099 }
    private func hlgOETF(_ e: Double) -> Double {
        let e = max(e, 0)
        return e <= 1.0 / 12.0 ? (3 * e).squareRoot() : 0.17883277 * log(12 * e - 0.28466892) + 0.55991073
    }
    private func code(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 1023).rounded()) }

    // MARK: - fixtures -------------------------------------------------------------

    /// A neutral `64RGBAHalf` gray buffer with DISCRETE transfer/primaries/matrix tags.
    private func makeTaggedHalf(_ w: Int, _ h: Int, v: Float, transfer: CFString, primaries: CFString) throws -> CVPixelBuffer {
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
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        let matrix = CFEqual(primaries, kCVImageBufferColorPrimaries_ITU_R_2020)
            ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        return pb
    }

    /// An untagged SDR / Rec.709 half buffer (no colorimetry attachments).
    private func makeUntaggedHalf(_ w: Int, _ h: Int, v: Float) throws -> CVPixelBuffer {
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
        return pb
    }

    private func read10G(_ buf: CVPixelBuffer, x: Int, y: Int) -> Int {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let word = CVPixelBufferGetBaseAddress(buf)!
            .advanced(by: y * CVPixelBufferGetBytesPerRow(buf) + x * 4).loadUnaligned(as: UInt32.self)
        return Int((word >> 10) & 0x3FF)
    }

    private func compositeHDRCenterG(_ buf: CVPixelBuffer, w: Int, h: Int) throws -> Int {
        let compositor = try MetalCompositor(device: try device(), width: w, height: h, colorMode: .hdr)
        let sid = SourceID("s")
        let scene = Scene(name: "s", layers: [Layer(sourceID: sid)])
        let prog = try compositor.composite(frames: [sid: VideoFrame(pixelBuffer: buf, pts: HouseClock.now(), source: sid)],
                                            scene: scene, pts: HouseClock.now())
        return read10G(prog.pixelBuffer, x: w / 2, y: h / 2)
    }

    // MARK: - #2 srgbColor: Rec.709 applies the sRGB→709 transfer (not identity) ----

    func testSrgbColorRec709AppliesTransferNotIdentity() throws {
        let src = try makeTaggedHalf(4, 4, v: 0.2, transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
                                     primaries: kCVImageBufferColorPrimaries_ITU_R_709_2)
        let out = YCbCrTags.srgbColor(SIMD3<Float>(0.5, 0.5, 0.5), inSpaceOf: src)
        let correct = oetf709(srgbEOTF(0.5))                    // ≈0.45019
        XCTAssertEqual(Double(out.x), correct, accuracy: 0.003, "709 srgbColor \(out.x) ≠ sRGB→709 \(correct)")
        XCTAssertGreaterThan(abs(Double(out.x) - 0.5), 0.04, "709 srgbColor returned 0.5 unchanged (pre-fix identity)")
    }

    /// A pure red UI colour on a Rec.709 source is a FIXED POINT of both curves
    /// (sRGB and 709 agree at 0 and 1), so it must stay unchanged — the transfer
    /// re-encode only bends mid-tones (regression guard for the SDR strobe path).
    func testSrgbColorRec709RedFixedPointUnchanged() throws {
        let src = try makeUntaggedHalf(4, 4, v: 0.2)            // untagged → Rec.709
        let out = YCbCrTags.srgbColor(SIMD3<Float>(1, 0, 0), inSpaceOf: src)
        XCTAssertEqual(Double(out.x), 1.0, accuracy: 0.002, "red R changed")
        XCTAssertEqual(Double(out.y), 0.0, accuracy: 0.002, "red G lifted")
        XCTAssertEqual(Double(out.z), 0.0, accuracy: 0.002, "red B lifted")
    }

    /// HLG is unchanged from wave-6: an sRGB gray 0.5 into an HLG source encodes to the
    /// from-spec sRGB-EOTF → HLG-OETF value (rotation is neutral for gray).
    func testSrgbColorHLGUnchanged() throws {
        let src = try makeTaggedHalf(4, 4, v: 0.2, transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                                     primaries: kCVImageBufferColorPrimaries_ITU_R_2020)
        let out = YCbCrTags.srgbColor(SIMD3<Float>(0.5, 0.5, 0.5), inSpaceOf: src)
        let correct = hlgOETF(srgbEOTF(0.5))                    // ≈0.7076
        XCTAssertEqual(Double(out.x), correct, accuracy: 0.01, "HLG srgbColor \(out.x) ≠ \(correct)")
    }

    // MARK: - #2 GPU probe: sRGB gray strobe over a PQ source composites to ≈726 -----

    /// sol's exact probe: a full sRGB-gray-0.5 strobe over a PQ source. Pre-fix the PQ
    /// encode did NOT invert the compositor's ×10 normalization, so the strobe wrote a
    /// PQ code that decoded to ≈2140 nits and HLG-clipped to 1023. Correct ≈726 (the
    /// same value the sRGB gray would reach through any HDR container).
    func testSrgbGrayStrobeOverPQSourceComposites726() throws {
        let w = 32, h = 32
        let gpu = try SourceEffectGPU(device: try device(), width: w, height: h)
        let src = try makeTaggedHalf(w, h, v: 0.3, transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                                     primaries: kCVImageBufferColorPrimaries_ITU_R_2020)
        // Full flash (phase 0, intensity 1) replaces the pixel with the converted colour.
        let strobed = try gpu.strobe(source: src, phase: 0, intensity: 1, color: RGBA(r: 0.5, g: 0.5, b: 0.5))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(strobed), kCVPixelFormatType_64RGBAHalf)

        let got = try compositeHDRCenterG(strobed, w: w, h: h)
        let correct = code(hlgOETF(srgbEOTF(0.5)))              // ≈726 (gray: rotation neutral)
        XCTAssertLessThanOrEqual(abs(got - correct), 30, "PQ strobe composited \(got) ≠ ≈\(correct)")
        XCTAssertLessThan(got, 900, "PQ strobe clipped to \(got) — the pre-fix ×10 over-normalization (1023)")
    }

    // MARK: - #3 name-only HDR classification survives a derived stage --------------

    /// A name-only HLG buffer (CGColorSpace attachment, NO discrete transfer) fed
    /// through `ColorProcessor` must EXIT still classified HLG. Pre-fix
    /// `propagateColorTags` copied only discrete attachments (none present) → the
    /// output was untagged and re-decoded Rec.709 downstream.
    func testNameOnlyHLGSurvivesColorProcessor() throws {
        let w = 8, h = 8
        let src = try makeUntaggedHalf(w, h, v: 0.4)
        guard let hlg = CGColorSpace(name: CGColorSpace.itur_2100_HLG) else { throw XCTSkip("no HLG colorspace") }
        CVBufferSetAttachment(src, kCVImageBufferCGColorSpaceKey, hlg, .shouldPropagate)

        // Precondition: the source is genuinely NAME-ONLY — no discrete transfer
        // attachment — yet classifies HLG via the name fallback.
        XCTAssertNil(CVBufferCopyAttachment(src, kCVImageBufferTransferFunctionKey, nil),
                     "fixture unexpectedly has a discrete transfer attachment")
        XCTAssertEqual(YCbCrTags.transferCode(for: src), 1, "name-only source not classified HLG")

        let proc = try ColorProcessor(device: try device())
        let out = try proc.process(VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("n")),
                                   grade: .identity, lut: nil)

        // The derived output keeps HLG classification (transferCode 1, not 0) AND now
        // carries a DISCRETE HLG transfer attachment for stages that read only discrete.
        XCTAssertEqual(YCbCrTags.transferCode(for: out.pixelBuffer), 1,
                       "name-only HLG lost its classification across the grade (re-decoded Rec.709)")
        XCTAssertNotNil(CVBufferCopyAttachment(out.pixelBuffer, kCVImageBufferTransferFunctionKey, nil),
                        "output has no discrete transfer attachment (name-only wasn't materialized)")
        XCTAssertTrue(YCbCrTags.isRec2020(for: out.pixelBuffer), "output lost Rec.2020 primaries")
    }

    /// A truly untagged source (no name, no discrete) still exits untagged — the fix
    /// must not fabricate tags where there is no colorimetry signal at all.
    func testUntaggedSourceStaysUntagged() throws {
        let w = 8, h = 8
        let src = try makeUntaggedHalf(w, h, v: 0.4)
        let proc = try ColorProcessor(device: try device())
        let out = try proc.process(VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("u")),
                                   grade: .identity, lut: nil)
        XCTAssertNil(CVBufferCopyAttachment(out.pixelBuffer, kCVImageBufferTransferFunctionKey, nil),
                     "untagged source gained a fabricated transfer attachment")
        XCTAssertNil(CVBufferCopyAttachment(out.pixelBuffer, kCVImageBufferCGColorSpaceKey, nil),
                     "untagged source gained a fabricated CGColorSpace attachment")
    }
}
