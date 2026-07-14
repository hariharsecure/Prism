import CoreMedia
import CoreVideo
import Foundation
import XCTest

import PrismCore
@testable import PrismVirtualCam

/// sol #6 #4: the virtual-camera format conversion must change COLOUR SPACE, not
/// just layout, when the program's dynamic range and the client-negotiated format
/// differ. Pre-fix `VCamFormatConverter` used only `VTPixelTransferSession`
/// (bit-depth/chroma), so sRGB 128 → l10r landed on 10-bit ≈514 still sRGB-tagged
/// (truthful HLG ≈726) and HLG 726 → BGRA landed on 8-bit ≈182 still HLG-tagged
/// (truthful SDR ≈128). Reproduce the relabel value as a NEGATIVE control, then
/// assert the real conversion. Independent oracle: the decoded values come from
/// the BT.2100/sRGB spec, cross-checked in `HDRSDRConverterTests`.
final class VCamColorConversionTests: XCTestCase {

    private let bgra = PrismVCamConstants.pixelFormatBGRA
    private let yuv420v = PrismVCamConstants.pixelFormat420v
    private let l10r = PrismVCamConstants.pixelFormat10bit

    private func makeBGRA(fill: UInt8, size: Int = 32) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: size, height: size, pixelFormat: bgra, minimumBufferCount: 1)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<size { for col in 0..<size {
            let p = row * bpr + col * 4
            base[p] = fill; base[p + 1] = fill; base[p + 2] = fill; base[p + 3] = 255
        } }
        return buf
    }

    private func makeL10R(fillCode: UInt32, size: Int = 32) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: size, height: size, pixelFormat: l10r, minimumBufferCount: 1)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<size {
            let r = base.advanced(by: row * bpr).assumingMemoryBound(to: UInt32.self)
            for col in 0..<size { r[col] = (UInt32(3) << 30) | (fillCode << 20) | (fillCode << 10) | fillCode }
        }
        return buf
    }

    private func readL10R(_ buf: CVPixelBuffer) -> (UInt32, UInt32, UInt32) {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let word = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt32.self)[0]
        return ((word >> 20) & 0x3FF, (word >> 10) & 0x3FF, word & 0x3FF)
    }

    private func readBGRAGreen(_ buf: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        return Int(CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)[1])
    }

    // MARK: - Cross-range conversions do REAL colour conversion

    func testSDRProgramToNegotiatedHDRConvertsColour() throws {
        let converter = VCamFormatConverter(width: 32, height: 32)
        let out = try XCTUnwrap(converter.convertPixelBuffer(try makeBGRA(fill: 128), to: l10r))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(out), l10r)
        let (r10, g10, b10) = readL10R(out)
        XCTAssertEqual(Int(r10), 726, accuracy: 2)   // truthful HLG, NOT the relabel ≈514
        XCTAssertEqual(Int(g10), 726, accuracy: 2)
        XCTAssertEqual(Int(b10), 726, accuracy: 2)
        XCTAssertNotEqual(Int(r10), 514)
        XCTAssertEqual(YCbCrTags.transferCode(for: out), 1)          // HLG
        XCTAssertTrue(YCbCrTags.isRec2020(for: out))
    }

    func testHDRProgramToNegotiatedSDRConvertsColour() throws {
        let converter = VCamFormatConverter(width: 32, height: 32)
        let out = try XCTUnwrap(converter.convertPixelBuffer(try makeL10R(fillCode: 726), to: bgra))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(out), bgra)
        let g = readBGRAGreen(out)
        XCTAssertEqual(g, 128, accuracy: 2)          // truthful SDR, NOT the relabel ≈182
        XCTAssertNotEqual(g, 182)
        XCTAssertEqual(YCbCrTags.transferCode(for: out), 3)          // sRGB
        XCTAssertEqual(YCbCrTags.primariesRotationCode(for: out), 1) // 709
    }

    func testHDRProgramToNegotiated420vIsSDRFormat() throws {
        let converter = VCamFormatConverter(width: 32, height: 32)
        let out = try XCTUnwrap(converter.convertPixelBuffer(try makeL10R(fillCode: 726), to: yuv420v))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(out), yuv420v) // real SDR YUV, not l10r relabel
    }

    // MARK: - Same-range + passthrough unchanged

    func testSameRangeBGRAToYUVIsLayoutOnly() throws {
        let converter = VCamFormatConverter(width: 32, height: 32)
        let out = try XCTUnwrap(converter.convertPixelBuffer(try makeBGRA(fill: 128), to: yuv420v))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(out), yuv420v)
    }

    func testMatchingFormatPassesThrough() throws {
        let converter = VCamFormatConverter(width: 32, height: 32)
        let src = try makeBGRA(fill: 128)
        let out = converter.convertPixelBuffer(src, to: bgra)
        XCTAssertTrue(out === src)   // zero-copy passthrough
    }
}
