import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import XCTest

@testable import PrismCapture
import PrismLink
@testable import PrismScreen

/// Stage N — the capture SOURCES must PREFER a 10-bit format when the source really
/// provides 10-bit/HDR, and cleanly fall back to 8-bit for SDR. The end-to-end HDR
/// path for CameraSource (a real HDR camera) and ScreenSource (a real HDR display)
/// is UNVERIFIED-until-hardware; what IS software-verifiable is the *decision* each
/// source makes about the output format. These tests drive those pure decisions
/// (Camera / Screen) and the real HEVC SPS bit-depth parse that Link keys off.
final class TenBitSourceSelectionTests: XCTestCase {

    // MARK: - CameraSource: prefer 10-bit output when the device format is 10-bit

    func testCameraTenBitSubtypeClassification() {
        XCTAssertTrue(CameraSource.isTenBitBiplanar(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange), "'x420' is 10-bit")
        XCTAssertTrue(CameraSource.isTenBitBiplanar(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange), "'xf20' is 10-bit")
        XCTAssertFalse(CameraSource.isTenBitBiplanar(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange), "'420f' is 8-bit")
        XCTAssertFalse(CameraSource.isTenBitBiplanar(kCVPixelFormatType_32BGRA), "BGRA is 8-bit")
    }

    func testCameraSelects10BitOverEightWhenDeviceIs10Bit() {
        let both = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        // Device format is 10-bit AND output advertises 10-bit → 10-bit video-range.
        XCTAssertEqual(CameraSource.preferredOutputFormat(activeIsTenBit: true, available: both),
                       kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                       "a 10-bit device format was truncated to 8-bit")
        // Only full-range 10-bit available → pick it.
        XCTAssertEqual(CameraSource.preferredOutputFormat(activeIsTenBit: true,
                                                          available: [kCVPixelFormatType_420YpCbCr10BiPlanarFullRange]),
                       kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
    }

    func testCameraFallsBackToEightBit() {
        // SDR device (8-bit format) → 8-bit even though a 10-bit output exists (no
        // false HDR: don't up-sample an 8-bit sensor).
        XCTAssertEqual(CameraSource.preferredOutputFormat(activeIsTenBit: false,
                                                          available: [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                                                      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]),
                       CameraSource.outputPixelFormat)
        // 10-bit device but the output can't deliver 10-bit → graceful 8-bit fallback.
        XCTAssertEqual(CameraSource.preferredOutputFormat(activeIsTenBit: true,
                                                          available: [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]),
                       CameraSource.outputPixelFormat)
    }

    // MARK: - ScreenSource: HDR → 10-bit 'l10r', SDR default unchanged

    func testScreenHDRPicks10BitPacked() {
        XCTAssertEqual(ScreenSource.streamPixelFormat(preferHDR: true, hdrSupported: true),
                       kCVPixelFormatType_ARGB2101010LEPacked,
                       "HDR screen capture must request 10-bit 'l10r'")
    }

    func testScreenSDRDefaultsStayEightBit() {
        // Default (no HDR requested) → 8-bit '420f' (byte-identical SDR path).
        XCTAssertEqual(ScreenSource.streamPixelFormat(preferHDR: false, hdrSupported: true),
                       kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        // HDR requested but unsupported OS → fall back to 8-bit (no crash / no 10-bit).
        XCTAssertEqual(ScreenSource.streamPixelFormat(preferHDR: true, hdrSupported: false),
                       kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    }

    // MARK: - Link: HEVC SPS bit-depth drives the decode output format

    /// Independent oracle: encode REAL HEVC (8-bit) and HEVC **Main10** clips with
    /// VideoToolbox, extract the SPS Apple's encoder produced, and assert our parser
    /// reads the correct luma bit depth — so Link decodes a 10-bit peer at 10-bit.
    func testHEVCSPSBitDepthParsedFromRealEncoders() throws {
        let eightSPS = try realSPS(main10: false)
        XCTAssertEqual(HEVCAnnexB.bitDepthLuma(sps: eightSPS), 8,
                       "8-bit HEVC SPS misparsed — Link would wrongly pick a 10-bit output")

        let tenSPS = try realSPS(main10: true)
        XCTAssertEqual(HEVCAnnexB.bitDepthLuma(sps: tenSPS), 10,
                       "10-bit HEVC Main10 SPS misparsed as 8-bit — Link would truncate a real 10-bit stream")
    }

    func testHEVCSPSMalformedIsNil() {
        XCTAssertNil(HEVCAnnexB.bitDepthLuma(sps: Data([0x42])), "1-byte junk must not parse")
        XCTAssertNil(HEVCAnnexB.bitDepthLuma(sps: Data()), "empty must not parse")
    }

    // MARK: - real SPS extraction

    private final class DescBox: @unchecked Sendable { var descs: [CMFormatDescription] = [] }

    private func realSPS(main10: Bool) throws -> Data {
        let url = try writeHEVC(main10: main10)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let sem = DispatchSemaphore(value: 0)
        var track: AVAssetTrack?
        asset.loadTracks(withMediaType: .video) { t, _ in track = t?.first; sem.signal() }
        _ = sem.wait(timeout: .now() + 15)
        guard let track else { throw XCTSkip("no video track") }
        let fsem = DispatchSemaphore(value: 0)
        let descBox = DescBox()
        Task {
            descBox.descs = (try? await track.load(.formatDescriptions)) ?? []
            fsem.signal()
        }
        _ = fsem.wait(timeout: .now() + 15)
        guard let desc = descBox.descs.first else { throw XCTSkip("no format description") }

        // SPS is HEVC parameter-set index 1 (0=VPS, 1=SPS, 2=PPS).
        var count = 0
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(desc, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr, count >= 2 else {
            throw XCTSkip("HEVC parameter sets unavailable")
        }
        var ptr: UnsafePointer<UInt8>?
        var size = 0
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(desc, parameterSetIndex: 1,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr else {
            throw XCTSkip("SPS unavailable")
        }
        return Data(bytes: ptr, count: size)
    }

    private func writeHEVC(main10: Bool) throws -> URL {
        let w = 64, h = 64
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hevc\(main10 ? "10" : "8").\(UUID().uuidString).mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            throw XCTSkip("no AVAssetWriter")
        }
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
        ]
        let srcFormat: OSType
        if main10 {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
            settings[AVVideoCompressionPropertiesKey] = [
                kVTCompressionPropertyKey_ProfileLevel as String: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
            ]
            srcFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        } else {
            srcFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: srcFormat,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ])
        guard writer.canAdd(input) else { throw XCTSkip("HEVC\(main10 ? " Main10" : "") unavailable on this host") }
        writer.add(input)
        guard writer.startWriting() else { throw XCTSkip("writer refused to start") }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<4 {
            guard let pool = adaptor.pixelBufferPool else { throw XCTSkip("no pool") }
            var pbOut: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else {
                throw XCTSkip("no buffer")
            }
            fillNeutral(pb, tenBit: main10)
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        let done = XCTestExpectation(description: "hevc")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 15)
        guard writer.status == .completed else { throw XCTSkip("HEVC write failed: \(String(describing: writer.error))") }
        return url
    }

    private func fillNeutral(_ buf: CVPixelBuffer, tenBit: Bool) {
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let yBase = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!
        let yBpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
        let yw = CVPixelBufferGetWidthOfPlane(buf, 0), yh = CVPixelBufferGetHeightOfPlane(buf, 0)
        let cBase = CVPixelBufferGetBaseAddressOfPlane(buf, 1)!
        let cBpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
        let cw = CVPixelBufferGetWidthOfPlane(buf, 1), ch = CVPixelBufferGetHeightOfPlane(buf, 1)
        if tenBit {
            let yVal = UInt16(truncatingIfNeeded: 600 << 6), cVal = UInt16(truncatingIfNeeded: 512 << 6)
            for row in 0..<yh { let p = (yBase + row * yBpr).assumingMemoryBound(to: UInt16.self); for c in 0..<yw { p[c] = yVal } }
            for row in 0..<ch { let p = (cBase + row * cBpr).assumingMemoryBound(to: UInt16.self); for c in 0..<cw { p[c*2] = cVal; p[c*2+1] = cVal } }
        } else {
            for row in 0..<yh { let p = (yBase + row * yBpr).assumingMemoryBound(to: UInt8.self); for c in 0..<yw { p[c] = 150 } }
            for row in 0..<ch { let p = (cBase + row * cBpr).assumingMemoryBound(to: UInt8.self); for c in 0..<cw { p[c*2] = 128; p[c*2+1] = 128 } }
        }
    }
}
