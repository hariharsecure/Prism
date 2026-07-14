import CoreVideo
import Metal
import XCTest

import PrismCompositor
import PrismCore

/// sol #5 finding 4 — the per-source strobe/pulse effects mixed a RAW sRGB UI colour
/// straight into the source-coded frame, then `SourceEffectGPU` propagated the
/// SOURCE's HLG/Rec.2020 tags. So a full-red strobe on an HLG/Rec.2020 source emitted
/// an sRGB red (1,0,0) FALSELY tagged 2020/HLG → the compositor read it as a pure
/// Rec.2020-HLG red (1023,0,0) instead of the correctly-converted sRGB red
/// ≈(935,466,227) in the 2020/HLG container.
///
/// FIX: the UI colour is converted INTO the source's coded colorspace (primaries +
/// transfer) BEFORE mixing, so the mixed output is homogeneous and the propagated
/// SOURCE tags are truthful. A 709 / SDR source's colour is unchanged.
///
/// Oracle is independent from-spec (sRGB EOTF, Rec.709→2020 matrix, BT.2100 HLG
/// OETF) in Double — never the shader. Red isolates the primary rotation.
final class SourceEffectStrobeTransferTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    // independent from-spec oracle -------------------------------------------------
    private func srgbEOTF(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    private func hlgOETF(_ e: Double) -> Double {
        let e = max(e, 0)
        return e <= 1.0 / 12.0 ? (3 * e).squareRoot() : 0.17883277 * log(12 * e - 0.28466892) + 0.55991073
    }
    private func code(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 1023).rounded()) }
    private func convertedRed() -> (b: Int, g: Int, r: Int) {
        var (r, g, b) = (srgbEOTF(1), srgbEOTF(0), srgbEOTF(0))
        (r, g, b) = (0.627404 * r + 0.329283 * g + 0.043313 * b,
                     0.069097 * r + 0.919540 * g + 0.011362 * b,
                     0.016391 * r + 0.088013 * g + 0.895595 * b)
        return (code(hlgOETF(b)), code(hlgOETF(g)), code(hlgOETF(r)))   // ≈(227,466,935)
    }

    // fixtures ---------------------------------------------------------------------
    private func makeHalf(_ w: Int, _ h: Int, v: Float, tagHDR: Bool) throws -> CVPixelBuffer {
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
        if tagHDR {
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        }
        return pb
    }

    private func makeBGRA709(_ w: Int, _ h: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pb else { throw XCTSkip("no bgra buffer") }
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        for row in 0..<h { for col in 0..<w {
            let p = base + row * bpr + col * 4
            p[0] = 80; p[1] = 80; p[2] = 80; p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb   // untagged → SDR / Rec.709
    }

    private func read10(_ buf: CVPixelBuffer, x: Int, y: Int) -> (b: Int, g: Int, r: Int) {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let word = CVPixelBufferGetBaseAddress(buf)!
            .advanced(by: y * CVPixelBufferGetBytesPerRow(buf) + x * 4).loadUnaligned(as: UInt32.self)
        return (Int(word & 0x3FF), Int((word >> 10) & 0x3FF), Int((word >> 20) & 0x3FF))
    }
    private func rawBGRA(_ buf: CVPixelBuffer, x: Int, y: Int) -> (b: Int, g: Int, r: Int) {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            + y * CVPixelBufferGetBytesPerRow(buf) + x * 4
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }

    private func compositeHDR(_ frame: VideoFrame, w: Int, h: Int) throws -> (b: Int, g: Int, r: Int) {
        let compositor = try MetalCompositor(device: try device(), width: w, height: h, colorMode: .hdr)
        let sid = frame.source
        let scene = Scene(name: "s", layers: [Layer(sourceID: sid)])
        let prog = try compositor.composite(frames: [sid: frame], scene: scene, pts: HouseClock.now())
        return read10(prog.pixelBuffer, x: w / 2, y: h / 2)
    }

    // MARK: - HLG source: a red strobe is CONVERTED, not falsely pure-2020 ---------

    func testRedStrobeOnHLGSourceConverted() throws {
        let w = 32, h = 32
        let gpu = try SourceEffectGPU(device: try device(), width: w, height: h)
        let src = try makeHalf(w, h, v: 0.3, tagHDR: true)      // HLG/Rec.2020 source
        // Full flash (phase 0, intensity 1) fully replaces the pixel with the flash colour.
        let strobed = try gpu.strobe(source: src, phase: 0, intensity: 1, color: RGBA(r: 1, g: 0, b: 0))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(strobed), kCVPixelFormatType_64RGBAHalf)
        // Truthful tag: the converted colour is genuinely in the source's 2020 space.
        XCTAssertTrue(YCbCrTags.isRec2020(for: strobed), "strobe output dropped the source's 2020 tag")

        let got = try compositeHDR(VideoFrame(pixelBuffer: strobed, pts: HouseClock.now(), source: SourceID("s")), w: w, h: h)
        let converted = convertedRed()                          // ≈(227,466,935)
        let falsePure2020 = (b: 0, g: 0, r: 1023)               // pre-fix: raw sRGB red tagged 2020
        XCTAssertGreaterThan(abs(converted.g - falsePure2020.g), 200, "oracle discriminator weak")

        XCTAssertLessThanOrEqual(abs(got.g - converted.g), 40, "strobe red G \(got) ≠ converted oracle \(converted)")
        XCTAssertLessThanOrEqual(abs(got.b - converted.b), 40, "strobe red B \(got) ≠ converted oracle \(converted)")
        XCTAssertGreaterThan(got.g, 300, "strobe red green ≈0 — false pure-Rec.2020 red (\(got))")
        XCTAssertLessThan(got.r, 1010, "strobe red R maxed to 1023 — false pure-Rec.2020 red (\(got))")
    }

    // MARK: - 709 / SDR source: the flash colour is UNCHANGED (identity conversion) -

    func testRedStrobeOn709SourceUnchanged() throws {
        let w = 32, h = 32
        let gpu = try SourceEffectGPU(device: try device(), width: w, height: h)
        let src = try makeBGRA709(w, h)                         // untagged SDR / Rec.709
        let strobed = try gpu.strobe(source: src, phase: 0, intensity: 1, color: RGBA(r: 1, g: 0, b: 0))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(strobed), kCVPixelFormatType_32BGRA)
        // The SDR flash colour is untouched: a pure red pixel (r≈255, g≈0, b≈0).
        let px = rawBGRA(strobed, x: w / 2, y: h / 2)
        XCTAssertGreaterThan(px.r, 245, "SDR strobe red R changed (\(px)) — conversion should be identity")
        XCTAssertLessThan(px.g, 12, "SDR strobe red G lifted (\(px))")
        XCTAssertLessThan(px.b, 12, "SDR strobe red B lifted (\(px))")
    }
}
