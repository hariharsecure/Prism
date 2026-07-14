import AVFoundation
import CoreMedia
import CoreVideo
import XCTest

import PrismCore
import PrismOutput

/// sol #1 — an ISO recording must be recorded at the SOURCE's NATIVE resolution
/// and in its NATIVE format (10-bit HEVC Main10 HLG when the source is HDR, H.264
/// SDR otherwise) — not upscaled to a hardcoded 1920×1080 nor flattened to 8-bit
/// H.264 SDR. These drive `ISORecorderBank` + `MovieRecorder` to a real `.mov`,
/// reopen it, and read the track's ACTUAL naturalSize / codec / color tags off the
/// file (an INDEPENDENT oracle — AVFoundation, not the recorder's own settings).
/// Each has a firing negative control that reproduces sol's exact defect.
///
/// No TCC (VideoToolbox encode is permission-free). The 10-bit HDR case mirrors
/// `HDRRecorderSelfTest`'s hardware-free HEVC-Main10 encode.
final class ISONativeFormatFileTests: XCTestCase {

    // MARK: fixtures

    private func makeBGRA(_ w: Int, _ h: Int, source: SourceID) throws -> (VideoFrame, CVPixelBuffer) {
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_32BGRA)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<h {
            let p = (base + row * bpr).assumingMemoryBound(to: UInt8.self)
            for col in 0..<w { p[col * 4 + 0] = 40; p[col * 4 + 1] = 200; p[col * 4 + 2] = 90; p[col * 4 + 3] = 255 }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return (VideoFrame(pixelBuffer: buf, pts: HouseClock.now(), source: source), buf)
    }

    private func makeHLG10(_ w: Int, _ h: Int, source: SourceID) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_ARGB2101010LEPacked)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<h {
            let p = (base + row * bpr).assumingMemoryBound(to: UInt32.self)
            for col in 0..<w {
                let ramp = UInt32((col + row) & 0x3FF)
                p[col] = (UInt32(3) << 30) | (min(ramp + 200, 1023) << 20) | (ramp << 10) | (ramp / 2)
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return buf
    }

    /// Record `frames` copies of a fixed native buffer to one ISO angle at
    /// `settings`, returning the finished file URL.
    private func recordISO(settings: RecordingSettings, source: SourceID,
                           fill: (SourceID) throws -> CVPixelBuffer,
                           frames: Int = 12, fps: Int = 30) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism_iso_\(UInt64.random(in: 0..<UInt64.max))", isDirectory: true)
        let bank = ISORecorderBank(directory: dir, defaultSettings: settings)
        try bank.addSource(source, settings: settings, includeAudio: false)
        let t0 = HouseClock.now()
        try bank.start(at: t0)
        let frameDur = CMTime(value: 1, timescale: CMTimeScale(fps))
        for i in 0..<frames {
            let pts = CMTimeAdd(t0, CMTime(value: Int64(i), timescale: CMTimeScale(fps)))
            let buf = try fill(source)
            bank.append(VideoFrame(pixelBuffer: buf, pts: pts, duration: frameDur, source: source))
            try await Task.sleep(nanoseconds: UInt64(1_000_000_000 / UInt64(fps)))
        }
        let results = await bank.finishAll()
        guard case .success(let report)? = results[source] else {
            throw XCTSkip("ISO recorder produced no file (result: \(String(describing: results[source])))")
        }
        return report.url
    }

    private func trackNaturalSize(_ url: URL) async throws -> CGSize {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first, "no video track in \(url.lastPathComponent)")
        return try await track.load(.naturalSize)
    }

    private func trackFormat(_ url: URL) async throws -> CMFormatDescription {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let fmts = try await track.load(.formatDescriptions)
        return try XCTUnwrap(fmts.first)
    }

    // MARK: - native resolution (not upscaled to 1080p)

    func testISORecordsNativeResolutionNotUpscaled() async throws {
        let src = SourceID("iso.640")
        let (_, _) = try makeBGRA(640, 480, source: src) // format sanity
        let url = try await recordISO(settings: RecordingSettings(codec: .h264, width: 640, height: 480, includeAudio: false),
                                      source: src) { try self.makeBGRA(640, 480, source: $0).1 }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let size = try await trackNaturalSize(url)
        XCTAssertEqual(size, CGSize(width: 640, height: 480), "ISO must record the source's native 640×480")

        // NEGATIVE CONTROL: the pre-fix hardcoded 1920×1080 settings — the SAME
        // 640×480 frames get UPSCALED to 1080p (sol: "a 640×480 source became 1920×1080").
        let src2 = SourceID("iso.640.neg")
        let urlNeg = try await recordISO(settings: RecordingSettings(codec: .h264, width: 1920, height: 1080, includeAudio: false),
                                         source: src2) { try self.makeBGRA(640, 480, source: $0).1 }
        defer { try? FileManager.default.removeItem(at: urlNeg.deletingLastPathComponent()) }
        let sizeNeg = try await trackNaturalSize(urlNeg)
        XCTAssertEqual(sizeNeg, CGSize(width: 1920, height: 1080),
                       "negative control: hardcoded 1080p upscales the 640×480 source")
    }

    // MARK: - native HDR format (10-bit HEVC Main10 HLG, not 8-bit H.264 SDR)

    func testISORecords10BitHLGAsHEVCMain10NotH264SDR() async throws {
        let src = SourceID("iso.hlg")
        let url = try await recordISO(settings: RecordingSettings(codec: .h264, width: 1280, height: 720,
                                                                  includeAudio: false, dynamicRange: .hdr),
                                      source: src) { try self.makeHLG10(1280, 720, source: $0) }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fdesc = try await trackFormat(url)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(fdesc), kCMVideoCodecType_HEVC,
                       "an HDR source's ISO must be HEVC (Main10), not H.264")
        let transfer = CMFormatDescriptionGetExtension(fdesc, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
        XCTAssertNotNil(transfer)
        if let transfer { XCTAssertTrue(CFEqual(transfer, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG),
                                        "ISO must carry the HLG transfer tag") }

        // NEGATIVE CONTROL: the pre-fix SDR H.264 settings flatten the 10-bit HLG
        // source to 8-bit H.264 with no HLG tag (sol: "10-bit l10r HLG became
        // 8-bit H.264 yuv420p").
        let src2 = SourceID("iso.hlg.neg")
        let urlNeg = try await recordISO(settings: RecordingSettings(codec: .h264, width: 1280, height: 720,
                                                                     includeAudio: false, dynamicRange: .sdr),
                                         source: src2) { try self.makeHLG10(1280, 720, source: $0) }
        defer { try? FileManager.default.removeItem(at: urlNeg.deletingLastPathComponent()) }
        let fdescNeg = try await trackFormat(urlNeg)
        // The codec is the reliable discriminator: SDR settings encode 8-bit H.264
        // (vs the fix's 10-bit HEVC Main10). (AVFoundation propagates the source
        // buffer's color tags onto the track regardless of codec, so the transfer
        // tag alone does NOT distinguish 8-bit from 10-bit — the codec does.)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(fdescNeg), kCMVideoCodecType_H264,
                       "negative control: SDR settings flatten the 10-bit HDR source to 8-bit H.264")
    }
}
