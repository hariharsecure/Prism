import CoreMedia
import CoreVideo
import Metal
import XCTest

import PrismCompositor
import PrismCore
import PrismVision

/// sol #5 finding 4 (supersedes sol #4 finding 2) — `BackgroundEffect.replace`
/// mixed a RAW sRGB replacement colour straight into the source-coded frame. The
/// interim fix stamped the OUTPUT sRGB so the compositor converted the background
/// red correctly — but the KEPT FOREGROUND (genuinely in the source's Rec.2020/HLG
/// space) was then ALSO mis-tagged sRGB → double-rotated 709→2020. The FULL fix
/// converts the sRGB replacement colour INTO the source's coded colorspace
/// (primaries + transfer) BEFORE mixing, so the whole buffer — replaced background
/// AND kept foreground — is ONE homogeneous colorspace and the propagated SOURCE
/// tags (Rec.2020/HLG) are truthful. The composited background red is STILL the
/// correctly-converted ≈(935,466,227); the foreground is now also correct.
///
/// Oracle is independent from-spec (BT.709 EOTF, Rec.709→2020 matrix, BT.2100 HLG
/// OETF), computed in Double — never the shader. Red is chosen so the sRGB-vs-709
/// EOTF is a no-op on {0,1}: the test isolates the PRIMARY handling (rotate vs
/// pass-through) which is exactly what the conversion controls.
final class BackgroundReplaceColorTagTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    private func eotf709(_ v: Double) -> Double { v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1.0 / 0.45) }
    private func hlgOETF(_ e: Double) -> Double {
        let e = max(e, 0)
        return e <= 1.0 / 12.0 ? (3 * e).squareRoot()
                               : 0.17883277 * log(12 * e - 0.28466892) + 0.55991073
    }
    private func code(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 1023).rounded()) }
    private func encodeRed(rotate: Bool) -> (b: Int, g: Int, r: Int) {
        var (r, g, b) = (eotf709(1), eotf709(0), eotf709(0))
        if rotate {
            (r, g, b) = (0.627404 * r + 0.329283 * g + 0.043313 * b,
                         0.069097 * r + 0.919540 * g + 0.011362 * b,
                         0.016391 * r + 0.088013 * g + 0.895595 * b)
        }
        func ch(_ v: Double) -> Int { code(hlgOETF(v)) }
        return (ch(b), ch(g), ch(r))
    }

    private func makeTagged2020HLGBGRA(_ w: Int, _ h: Int, r: UInt8, g: UInt8, b: UInt8) throws -> CVPixelBuffer {
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
        CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return buf
    }

    /// An all-background matte (person=0) so the whole frame is the replacement colour.
    private func emptyMatte(_ w: Int, _ h: Int) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: w, height: h,
                                       pixelFormat: kCVPixelFormatType_OneComponent8, minimumBufferCount: 1)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<h { memset(base + y * row, 0, w) }
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

    private func hasPrimaries(_ buf: CVPixelBuffer, _ p: CFString) -> Bool {
        guard let raw = CVBufferCopyAttachment(buf, kCVImageBufferColorPrimariesKey, nil) else { return false }
        return CFEqual(raw as AnyObject, p)
    }

    private func replaceOutput(color: SIMD3<Float>, w: Int, h: Int) throws -> VideoFrame {
        // A Rec.2020/HLG source (green FG, irrelevant behind an empty matte) whose
        // background is REPLACED with a straight sRGB colour.
        let src = try makeTagged2020HLGBGRA(w, h, r: 0, g: 255, b: 0)
        let effect = try BackgroundEffect(device: try device())
        let matte = try emptyMatte(w, h)
        return try effect.apply(
            frame: VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("bg")),
            matte: SegmentationMatte(pixelBuffer: matte, pts: HouseClock.now(), source: SourceID("bg")),
            mode: .replace(color: color))
    }

    private func compositeHDR(_ out: VideoFrame, w: Int, h: Int) throws -> (b: Int, g: Int, r: Int) {
        let compositor = try MetalCompositor(device: try device(), width: w, height: h, colorMode: .hdr)
        let sid = out.source
        let scene = Scene(name: "s", layers: [Layer(sourceID: sid)])
        let prog = try compositor.composite(frames: [sid: out], scene: scene, pts: HouseClock.now())
        XCTAssertEqual(prog.pixelFormat, kCVPixelFormatType_ARGB2101010LEPacked)
        return read10(prog.pixelBuffer, x: w / 2, y: h / 2)
    }

    // MARK: - the full-fix test

    func testReplaceColorConvertedInShaderAndSourceTagsTruthful() throws {
        let w = 32, h = 32
        let out = try replaceOutput(color: SIMD3(1, 0, 0), w: w, h: h)  // sRGB red

        // Full fix: the colour was converted INTO the source's coded space in-shader,
        // so the whole buffer is genuinely Rec.2020/HLG → the SOURCE tags are truthful.
        XCTAssertTrue(hasPrimaries(out.pixelBuffer, kCVImageBufferColorPrimaries_ITU_R_2020),
                      "replace output must carry the source's Rec.2020 primaries (homogeneous colorspace)")
        XCTAssertTrue(YCbCrTags.isRec2020(for: out.pixelBuffer), "replace output dropped the source's 2020 tag")

        // The composited background red is STILL the correctly-CONVERTED sRGB red
        // (rotate 709→2020, HLG-encoded) — NOT a pure Rec.2020 red, and NOT double-
        // rotated. Because the colour is pre-converted AND the buffer is truthfully
        // 2020-tagged (compositor does not re-rotate), the round-trip lands on the same
        // ≈(935,466,227) the interim sRGB-tag path produced for the background.
        let got = try compositeHDR(out, w: w, h: h)
        let converted = encodeRed(rotate: true)   // sRGB red → 709→2020 ≈(b227,g466,r935)
        let pure2020 = encodeRed(rotate: false)   // false pure-2020 red → (0,0,1023)
        XCTAssertGreaterThan(abs(converted.g - pure2020.g), 200, "oracle discriminator weak (\(converted) vs \(pure2020))")

        XCTAssertLessThanOrEqual(abs(got.g - converted.g), 30, "replace red G \(got) ≠ converted oracle \(converted)")
        XCTAssertLessThanOrEqual(abs(got.b - converted.b), 30, "replace red B \(got) ≠ converted oracle \(converted)")
        XCTAssertGreaterThan(got.g, 300, "replace red green ≈0 — false pure-Rec.2020 red (\(got))")
        XCTAssertLessThan(got.r, 1010, "replace red R maxed to 1023 — false pure-Rec.2020 red (\(got))")
    }

    // MARK: - negative control: remove mode STILL keeps the source's 2020 tags

    func testRemoveModeStillPropagatesSourceTags() throws {
        let w = 32, h = 32
        let src = try makeTagged2020HLGBGRA(w, h, r: 0, g: 255, b: 0)
        let effect = try BackgroundEffect(device: try device())
        let matte = try emptyMatte(w, h)
        let out = try effect.apply(
            frame: VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("bg")),
            matte: SegmentationMatte(pixelBuffer: matte, pts: HouseClock.now(), source: SourceID("bg")),
            mode: .remove)
        XCTAssertTrue(hasPrimaries(out.pixelBuffer, kCVImageBufferColorPrimaries_ITU_R_2020),
                      "remove mode must keep the source's Rec.2020 primaries (output IS the source colorspace)")
        XCTAssertTrue(YCbCrTags.isRec2020(for: out.pixelBuffer), "remove mode dropped 2020 tag")
    }
}
