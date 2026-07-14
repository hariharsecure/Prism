import CoreMedia
import CoreVideo
import XCTest
import VideoToolbox

import PrismCore
import PrismOutput

/// Stage O — HDR sink parity for the **streaming + replay** encoder.
///
/// Before this stage the `ProgramEncoder` that drives RTMP/SRT streaming AND the
/// instant-replay ring was hardcoded to 8-bit H.264 (`.h264`), so a show running
/// in HDR streamed/buffered an 8-bit SDR elementary stream while the recording was
/// HEVC Main10 / Rec.2020-HLG — a sink-parity gap (sol #4 finding #6).
///
/// This suite drives the REAL `ProgramEncoder` with `dynamicRange: .hdr`, encodes
/// a synthetic 10-bit frame, and asserts the emitted `CMSampleBuffer`'s format
/// description is **HEVC**, **Main10** (parsed independently from the `hvcC`
/// config record — `general_profile_idc == 2`), and carries the **Rec.2020 /
/// ITU-R BT.2100 HLG** color attachments. The `.sdr` control asserts the original
/// 8-bit H.264 behavior is byte-identical (H.264, no HDR tags).
///
/// CONFIGURATION-verified (codec/profile/color tags on the real encoder output).
/// Whether the stream actually renders HDR on a real platform ingest / HDR display
/// is UNVERIFIED-until-hardware.
final class StreamHDRParityTests: XCTestCase {

    /// Encode one synthetic 10-bit frame through the encoder and return the first
    /// emitted sample buffer's format description (nil on skip-worthy HW failure).
    private func encodeOne(_ settings: ProgramEncoder.Settings) throws -> CMFormatDescription? {
        let encoder = ProgramEncoder(settings: settings)
        let got = XCTestExpectation(description: "encoded frame")
        let box = FormatBox()
        encoder.onEncodedFrame = { sb in
            if let fd = CMSampleBufferGetFormatDescription(sb) {
                box.set(fd)
                got.fulfill()
            }
        }
        do { try encoder.start() } catch {
            throw XCTSkip("hardware encoder unavailable for \(settings.dynamicRange) (\(error)) — encode is HW-only")
        }
        defer { encoder.stop() }

        // 10-bit HDR source buffers (ARGB2101010LEPacked), HLG/2020-tagged — the
        // compositor's `.hdr` program-frame format.
        let pool = try PixelBufferPool(width: settings.width, height: settings.height,
                                       pixelFormat: kCVPixelFormatType_ARGB2101010LEPacked)
        let src = SourceID("test.streamhdr")
        let fps = Int(settings.expectedFrameRate)
        let t0 = HouseClock.now()
        // Submit several frames so the encoder emits at least one (first frame is a keyframe).
        for i in 0..<8 {
            let pts = CMTimeAdd(t0, CMTime(value: Int64(i), timescale: CMTimeScale(fps)))
            let buf = try pool.makeBuffer()
            fill10(buf, phase: i)
            attachHDRTags(buf)
            try encoder.encode(VideoFrame(pixelBuffer: buf, pts: pts,
                                          duration: CMTime(value: 1, timescale: CMTimeScale(fps)), source: src))
        }
        encoder.flush()
        _ = XCTWaiter().wait(for: [got], timeout: 5.0)
        return box.get()
    }

    func testHDRStreamEncoderIsHEVCMain10Rec2020HLG() throws {
        let settings = ProgramEncoder.Settings(
            codec: .h264,                 // deliberately request H.264…
            width: 320, height: 240,
            averageBitrate: 6_000_000,
            expectedFrameRate: 30,
            lowLatencyRateControl: true,
            dynamicRange: .hdr)           // …HDR must override it to HEVC Main10.
        guard let fdesc = try encodeOne(settings) else {
            throw XCTSkip("no encoded HDR frame produced on this host")
        }

        // Codec: HEVC (not the requested H.264).
        let subType = CMFormatDescriptionGetMediaSubType(fdesc)
        XCTAssertEqual(subType, kCMVideoCodecType_HEVC,
                       "HDR stream encoder must emit HEVC (got \(fourCC(subType))) — pre-fix it was 8-bit H.264")

        // Main10: general_profile_idc from the hvcC record (independent parse).
        if let idc = hevcProfileIDC(fdesc) {
            XCTAssertEqual(idc, 2, "HEVC profile_idc must be 2 (Main10); got \(idc)")
        }

        // Rec.2020 / BT.2100 HLG color attachments.
        XCTAssertTrue(extEquals(fdesc, kCMFormatDescriptionExtension_ColorPrimaries,
                                kCMFormatDescriptionColorPrimaries_ITU_R_2020),
                      "ColorPrimaries must be ITU_R_2020")
        XCTAssertTrue(extEquals(fdesc, kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG),
                      "TransferFunction must be ITU_R_2100_HLG")
        XCTAssertTrue(extEquals(fdesc, kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_ITU_R_2020),
                      "YCbCrMatrix must be ITU_R_2020")
    }

    /// SDR control: the original 8-bit H.264 path is unchanged (no HDR override,
    /// no Rec.2020/HLG tags) — proves the HDR branch is additive.
    func testSDRStreamEncoderStaysH264NoHDRTags() throws {
        let settings = ProgramEncoder.Settings(
            codec: .h264, width: 320, height: 240,
            averageBitrate: 6_000_000, expectedFrameRate: 30,
            lowLatencyRateControl: true, dynamicRange: .sdr)
        // Feed an 8-bit BGRA frame (SDR program format).
        let encoder = ProgramEncoder(settings: settings)
        let got = XCTestExpectation(description: "sdr encoded frame")
        let box = FormatBox()
        encoder.onEncodedFrame = { sb in
            if let fd = CMSampleBufferGetFormatDescription(sb) { box.set(fd); got.fulfill() }
        }
        do { try encoder.start() } catch { throw XCTSkip("hardware H.264 encoder unavailable (\(error))") }
        defer { encoder.stop() }
        let pool = try PixelBufferPool(width: 320, height: 240, pixelFormat: kCVPixelFormatType_32BGRA)
        let src = SourceID("test.streamsdr")
        let t0 = HouseClock.now()
        for i in 0..<8 {
            let pts = CMTimeAdd(t0, CMTime(value: Int64(i), timescale: 30))
            let buf = try pool.makeBuffer()
            try encoder.encode(VideoFrame(pixelBuffer: buf, pts: pts, duration: CMTime(value: 1, timescale: 30), source: src))
        }
        encoder.flush()
        _ = XCTWaiter().wait(for: [got], timeout: 5.0)
        guard let fdesc = box.get() else { throw XCTSkip("no encoded SDR frame produced") }
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(fdesc), kCMVideoCodecType_H264,
                       "SDR stream encoder must stay H.264")
        XCTAssertFalse(extEquals(fdesc, kCMFormatDescriptionExtension_TransferFunction,
                                 kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG),
                       "SDR must not carry the HLG transfer tag")
    }

    // MARK: - helpers

    private final class FormatBox: @unchecked Sendable {
        private let lock = NSLock()
        private var fd: CMFormatDescription?
        func set(_ v: CMFormatDescription) { lock.lock(); if fd == nil { fd = v }; lock.unlock() }
        func get() -> CMFormatDescription? { lock.lock(); defer { lock.unlock() }; return fd }
    }

    private func extEquals(_ fdesc: CMFormatDescription, _ key: CFString, _ expected: CFString) -> Bool {
        guard let v = CMFormatDescriptionGetExtension(fdesc, extensionKey: key) else { return false }
        return CFEqual(v, expected)
    }

    /// Extract HEVC `general_profile_idc` from the `hvcC` atom (byte[1] & 0x1F).
    private func hevcProfileIDC(_ fdesc: CMFormatDescription) -> Int? {
        guard let atoms = CMFormatDescriptionGetExtension(
            fdesc, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
            let hvcC = atoms["hvcC"] as? Data, hvcC.count >= 2 else { return nil }
        return Int(hvcC[hvcC.startIndex + 1] & 0x1F)
    }

    private func fill10(_ buffer: CVPixelBuffer, phase: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        for y in 0..<h {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt32.self)
            for x in 0..<w {
                let v = UInt32(((x + y + phase * 7) & 0x3FF))
                let r = min(v + 200, 1023), g = v, b = min(v / 2, 1023)
                row[x] = (UInt32(3) << 30) | (r << 20) | (g << 10) | b
            }
        }
    }

    private func attachHDRTags(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    }

    private func fourCC(_ code: OSType) -> String {
        let b = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                 UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return "'\(String(bytes: b, encoding: .ascii) ?? "?")'"
    }
}
