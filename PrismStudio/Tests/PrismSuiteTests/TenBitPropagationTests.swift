import CoreMedia
import CoreVideo
import Metal
import XCTest

import PrismColor
import PrismCompositor
import PrismCore
import PrismVision

/// wave-5b — the per-source FX (`SourceEffectGPU`), Vision (`BackgroundEffect`) and
/// Color (`ColorProcessor`) stages ACCEPT real 10-bit input and PRESERVE its
/// precision: they decode the P010-style buffer at 16-bit, process in half-float,
/// and emit a `64RGBAHalf` frame (the compositor now folds that in) — NO silent
/// downconvert-to-8-bit, NO dropped frame. Pre-fix these stages accepted only 8-bit
/// (BGRA8 / `420v` / `420f`) and threw `unsupported*Format` on a 10-bit buffer.
///
/// Oracle independence (Class I): the expected RGB is the from-spec BT.2020
/// video-range decode of the KNOWN 10-bit codes — `(Y-64)/876`, neutral chroma —
/// computed in the test, not by any shader.
///
/// SOFTWARE-VERIFIED ONLY: synthetic 10-bit buffers verify the software path; a
/// real 10-bit HDR camera end-to-end is UNVERIFIED-until-hardware.
final class TenBitPropagationTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    // A solid 10-bit `x420`/`xf20` (P010-style) buffer, tagged Rec.2020.
    private func makeYUV10(_ w: Int, _ h: Int, y: Int, cb: Int = 512, cr: Int = 512,
                           fullRange: Bool = false) throws -> CVPixelBuffer {
        let fmt = fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                            : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: fmt)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let yBase = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!
        let yBpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
        for row in 0..<CVPixelBufferGetHeightOfPlane(buf, 0) {
            let p = (yBase + row * yBpr).assumingMemoryBound(to: UInt16.self)
            for col in 0..<CVPixelBufferGetWidthOfPlane(buf, 0) { p[col] = UInt16(truncatingIfNeeded: y << 6) }
        }
        let cBase = CVPixelBufferGetBaseAddressOfPlane(buf, 1)!
        let cBpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
        for row in 0..<CVPixelBufferGetHeightOfPlane(buf, 1) {
            let p = (cBase + row * cBpr).assumingMemoryBound(to: UInt16.self)
            for col in 0..<CVPixelBufferGetWidthOfPlane(buf, 1) {
                p[col * 2] = UInt16(truncatingIfNeeded: cb << 6); p[col * 2 + 1] = UInt16(truncatingIfNeeded: cr << 6)
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return buf
    }

    private func readHalf(_ buf: CVPixelBuffer, x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(buf)!
            .advanced(by: y * CVPixelBufferGetBytesPerRow(buf) + x * 8)
        let r = p.loadUnaligned(fromByteOffset: 0, as: Float16.self)
        let g = p.loadUnaligned(fromByteOffset: 2, as: Float16.self)
        let b = p.loadUnaligned(fromByteOffset: 4, as: Float16.self)
        return (Double(r), Double(g), Double(b))
    }

    /// Video-range BT.2020 neutral gray decode (independent of the shader).
    private func neutral(_ y: Int) -> Double { Double(y - 64) / 876.0 }

    // MARK: - SourceEffectGPU (FX pre-pass) --------------------------------------

    func testFXAccepts10BitEmitsHalfPrecise() throws {
        let W = 64, H = 48
        let gpu = try SourceEffectGPU(device: try device(), width: W, height: H)
        // videoWall 1×1 = identity passthrough → isolates the decode + precision.
        let out = try gpu.videoWall(source: try makeYUV10(W, H, y: 768), rows: 1, cols: 1, mirror: false)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(out), kCVPixelFormatType_64RGBAHalf,
                       "10-bit FX output collapsed to 8-bit (or dropped)")
        let got = readHalf(out, x: W / 2, y: H / 2)
        let want = neutral(768)
        for (name, ch) in [("r", got.r), ("g", got.g), ("b", got.b)] {
            XCTAssertLessThanOrEqual(abs(ch - want), 0.01, "FX 10-bit \(name) \(ch) ≠ from-spec \(want)")
        }
        // Precision: two sub-8-bit-distinct codes (share 8-bit bucket) stay distinct.
        let lo = readHalf(try gpu.videoWall(source: try makeYUV10(W, H, y: 513, fullRange: true), rows: 1, cols: 1, mirror: false), x: W / 2, y: H / 2)
        let hi = readHalf(try gpu.videoWall(source: try makeYUV10(W, H, y: 515, fullRange: true), rows: 1, cols: 1, mirror: false), x: W / 2, y: H / 2)
        XCTAssertGreaterThan(hi.g, lo.g, "FX collapsed sub-8-bit codes 513/515 (\(lo.g) == \(hi.g))")
    }

    // MARK: - ColorProcessor (grade) --------------------------------------------

    func testColorAccepts10BitEmitsHalfPrecise() throws {
        let W = 64, H = 48
        let proc = try ColorProcessor(device: try device())
        let out = try proc.process(VideoFrame(pixelBuffer: try makeYUV10(W, H, y: 768),
                                              pts: HouseClock.now(), source: SourceID("c")),
                                   grade: .identity, lut: nil)
        XCTAssertEqual(out.pixelFormat, kCVPixelFormatType_64RGBAHalf, "10-bit grade output collapsed to 8-bit")
        let got = readHalf(out.pixelBuffer, x: W / 2, y: H / 2)
        let want = neutral(768)   // identity grade is a passthrough
        for (name, ch) in [("r", got.r), ("g", got.g), ("b", got.b)] {
            XCTAssertLessThanOrEqual(abs(ch - want), 0.01, "grade 10-bit \(name) \(ch) ≠ from-spec \(want)")
        }
    }

    // MARK: - BackgroundEffect (Vision decode) -----------------------------------

    func testVisionAccepts10BitEmitsHalf() throws {
        let W = 64, H = 48
        let effect = try BackgroundEffect(device: try device())
        // All-person matte → `.remove` keeps the foreground = the source colour.
        let mattePool = try PixelBufferPool(width: W, height: H, pixelFormat: kCVPixelFormatType_OneComponent8)
        let matte = try mattePool.makeBuffer()
        CVPixelBufferLockBaseAddress(matte, [])
        let mBase = CVPixelBufferGetBaseAddress(matte)!.assumingMemoryBound(to: UInt8.self)
        let mBpr = CVPixelBufferGetBytesPerRow(matte)
        for row in 0..<H { for col in 0..<W { (mBase + row * mBpr)[col] = 255 } }
        CVPixelBufferUnlockBaseAddress(matte, [])

        let frame = VideoFrame(pixelBuffer: try makeYUV10(W, H, y: 768), pts: HouseClock.now(), source: SourceID("v"))
        let out = try effect.apply(frame: frame,
                                   matte: SegmentationMatte(pixelBuffer: matte, pts: frame.pts, source: frame.source),
                                   mode: .remove)
        XCTAssertEqual(out.pixelFormat, kCVPixelFormatType_64RGBAHalf, "10-bit Vision output collapsed to 8-bit")
        let got = readHalf(out.pixelBuffer, x: W / 2, y: H / 2)
        let want = neutral(768)
        for (name, ch) in [("r", got.r), ("g", got.g), ("b", got.b)] {
            XCTAssertLessThanOrEqual(abs(ch - want), 0.02, "Vision 10-bit \(name) \(ch) ≠ from-spec \(want)")
        }
    }
}
