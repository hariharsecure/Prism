import CoreMedia
import CoreVideo
import VideoToolbox
import XCTest

import PrismCore
@testable import Prism

/// sol #12 #2 (gpt-5.6-sol, HIGH) — Link/peer Main10 was DOWNCONVERTED to 8-bit before composition.
///
/// `LinkFrameNormalizer.compositorFormats` was a STALE 8-bit-only allowlist (BGRA / 420v / 420f), so
/// a peer's decoded 10-bit `x420` (Main10) frame — which the wave-5b[M] compositor decodes NATIVELY
/// (r16Unorm, precision-preserving) — was not on the allowlist and got run through
/// `VTPixelTransferSession` into 8-bit `420v` on every frame. Distinct 10-bit luma codes collapsed
/// into a single 8-bit bucket: 10-bit precision irreversibly lost BEFORE the compositor ever saw it.
///
/// FIX: the allowlist now PASSES THROUGH the 10-bit formats (x420/xf20/l10r + the 64RGBAHalf float
/// output) so peer Main10 reaches composition at 10-bit; genuine 8-bit peers are unchanged; a truly
/// unsupported/compressed format still normalizes to 420v.
final class SolWave13LinkMain10Tests: XCTestCase {

    /// A 10-bit `x420` (P010-style) buffer whose 4 luma pixels carry 4 DISTINCT 10-bit codes; the
    /// code sits in the HIGH 10 bits of each 16-bit sample (`code << 6`).
    private func makeX420(codes: [Int]) throws -> CVPixelBuffer {
        let w = codes.count, h = 2
        let pool = try PixelBufferPool(width: w, height: h,
                                       pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let yBase = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!
        let yBpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
        let yw = CVPixelBufferGetWidthOfPlane(buf, 0), yh = CVPixelBufferGetHeightOfPlane(buf, 0)
        for row in 0..<yh {
            let p = (yBase + row * yBpr).assumingMemoryBound(to: UInt16.self)
            for col in 0..<yw { p[col] = UInt16(truncatingIfNeeded: codes[col % codes.count] << 6) }
        }
        // Neutral chroma (512).
        let cBase = CVPixelBufferGetBaseAddressOfPlane(buf, 1)!
        let cBpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
        let cw = CVPixelBufferGetWidthOfPlane(buf, 1), ch = CVPixelBufferGetHeightOfPlane(buf, 1)
        let mid = UInt16(truncatingIfNeeded: 512 << 6)
        for row in 0..<ch {
            let p = (cBase + row * cBpr).assumingMemoryBound(to: UInt16.self)
            for col in 0..<cw { p[col * 2] = mid; p[col * 2 + 1] = mid }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    private func makeYUV8(y: UInt8) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: 4, height: 2,
                                       pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let yBase = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!.assumingMemoryBound(to: UInt8.self)
        let yBpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
        let yw = CVPixelBufferGetWidthOfPlane(buf, 0), yh = CVPixelBufferGetHeightOfPlane(buf, 0)
        for row in 0..<yh { for col in 0..<yw { (yBase + row * yBpr)[col] = y } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    /// Read back the first row's DISTINCT high-10-bit luma codes from a 10-bit plane.
    private func distinct10BitLuma(_ buf: CVPixelBuffer) -> Set<Int> {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!
        let w = CVPixelBufferGetWidthOfPlane(buf, 0)
        let p = base.assumingMemoryBound(to: UInt16.self)
        return Set((0..<w).map { Int(p[$0]) >> 6 })
    }

    /// Read back the DISTINCT 8-bit luma codes from an 8-bit plane.
    private func distinct8BitLuma(_ buf: CVPixelBuffer) -> Set<Int> {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!.assumingMemoryBound(to: UInt8.self)
        let w = CVPixelBufferGetWidthOfPlane(buf, 0)
        return Set((0..<w).map { Int(base[$0]) })
    }

    /// A peer Main10 (`x420`) frame reaches composition at 10-bit — the normalizer PASSES IT THROUGH
    /// unchanged (still `x420`, all 4 distinct codes intact), NOT collapsed to 8-bit `420v`.
    func testPeerMain10PassesThroughAt10Bit() throws {
        let codes = [512, 513, 514, 515]   // 4 distinct 10-bit codes (all share the 8-bit bucket 128)
        let input = try makeX420(codes: codes)
        let frame = VideoFrame(pixelBuffer: input, pts: CMTime(value: 1, timescale: 600),
                               source: SourceID("peer.main10"))
        let out = LinkFrameNormalizer().normalize(frame)

        XCTAssertEqual(out.pixelFormat, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                       "#12.2: peer Main10 was downconverted off the native 10-bit x420 path")
        XCTAssertNotEqual(out.pixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                          "#12.2: peer Main10 collapsed to 8-bit 420v before composition")
        XCTAssertEqual(distinct10BitLuma(out.pixelBuffer), Set(codes),
                       "#12.2: 10-bit precision lost — the 4 distinct codes did not survive normalization")
    }

    /// Independent oracle proving the loss the fix AVOIDS is real (non-vacuous): the SAME x420 input,
    /// run through the pre-fix 8-bit downconvert (a direct VTPixelTransfer to 420v), collapses all 4
    /// distinct 10-bit codes into ONE 8-bit bucket.
    func testEightBitDownconvertWouldCollapseTheCodes() throws {
        let codes = [512, 513, 514, 515]
        let input = try makeX420(codes: codes)
        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        let s = try XCTUnwrap(session)
        let pool = try PixelBufferPool(width: codes.count, height: 2,
                                       pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let out = try pool.makeBuffer()
        XCTAssertEqual(VTPixelTransferSessionTransferImage(s, from: input, to: out), noErr)
        XCTAssertEqual(distinct8BitLuma(out).count, 1,
                       "oracle vacuous: the codes did not actually collapse under an 8-bit downconvert")
    }

    /// A genuine 8-bit peer (`420v`) is unchanged — pass-through, same buffer, still 420v.
    func testEightBitPeerUnchanged() throws {
        let input = try makeYUV8(y: 128)
        let frame = VideoFrame(pixelBuffer: input, pts: CMTime(value: 1, timescale: 600),
                               source: SourceID("peer.sdr"))
        let out = LinkFrameNormalizer().normalize(frame)
        XCTAssertEqual(out.pixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                       "an 8-bit peer must stay 8-bit 420v")
        XCTAssertTrue(CVPixelBufferGetBaseAddress(out.pixelBuffer) == CVPixelBufferGetBaseAddress(input),
                      "an 8-bit peer must pass through untouched (same buffer)")
    }
}
