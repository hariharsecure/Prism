import AVFoundation
import CoreMedia
import CoreVideo
import XCTest

import PrismCore
import PrismOutput
@testable import Prism

/// sol wave-16 — the App half of the completed ISO fix:
///
///  #1 An ISO source armed BEFORE its first frame must not freeze a canvas-sized
///     SDR/H.264 fallback. `startISOIfArmed` DEFERS such a source's recorder to its
///     first real frame, so the FIRST take is recorded at the source's native
///     resolution + dynamic range (HEVC Main10 HLG for an HLG source).
///
///  #2 `deliverSourceFrame(feedISO:)` — a Presenter Cutout's processed program
///     frame must NOT be routed to the clean ISO tap (the ISO is fed the upstream
///     raw separately). `feedISO: false` suppresses the processed-frame ISO append.
///
/// Each has a firing negative control reproducing the pre-fix defect.
@MainActor
final class SolWave16ISODeferTests: XCTestCase {

    private func makeHLG10(_ w: Int, _ h: Int, source: SourceID) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_ARGB2101010LEPacked)
        let buf = try pool.makeBuffer()
        CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return VideoFrame(pixelBuffer: buf, pts: HouseClock.now(), source: source)
    }

    private func makeBGRA(_ w: Int, _ h: Int, source: SourceID) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_32BGRA)
        let buf = try pool.makeBuffer()
        return VideoFrame(pixelBuffer: buf, pts: HouseClock.now(), source: source)
    }

    private func trackNaturalSize(_ url: URL) async throws -> CGSize {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        return try await track.load(.naturalSize)
    }

    private func trackSubType(_ url: URL) async throws -> CMVideoCodecType {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let fmts = try await track.load(.formatDescriptions)
        let fdesc = try XCTUnwrap(fmts.first)
        return CMFormatDescriptionGetMediaSubType(fdesc)
    }

    // MARK: - #1 deferred first take is native + HDR (not frozen canvas-SDR)

    func testISOArmedBeforeFirstFrameDefersToNativeHDRFirstTake() async throws {
        let engine = AppEngine()
        let id = SourceID("iso.defer.hlg")
        engine._test_addSyntheticISOSourceNoFrame(id: id)      // armed, NO frame yet
        try engine.startRecording()
        // No recorder yet — deferred until the first frame.
        XCTAssertNil(engine._test_isoRecorderSettings(for: id), "recorder must be deferred before the first frame")

        // First frame arrives AFTER start (the async-source-start window).
        let base = HouseClock.now()
        let fps = 30
        for i in 0..<15 {
            var f = try makeHLG10(1280, 720, source: id)
            f = VideoFrame(pixelBuffer: f.pixelBuffer,
                           pts: CMTimeAdd(base, CMTime(value: Int64(i), timescale: CMTimeScale(fps))),
                           duration: CMTime(value: 1, timescale: CMTimeScale(fps)), source: id)
            engine._test_feedISOFrame(f)
        }
        let s = engine._test_isoRecorderSettings(for: id)
        XCTAssertEqual(s?.width, 1280, "first take is the source's native width")
        XCTAssertEqual(s?.height, 720, "first take is the source's native height")
        XCTAssertEqual(s?.dynamicRange, .hdr, "first take records HDR (HEVC Main10 HLG), not the SDR fallback")

        _ = await engine.stopRecording()
        let url = try XCTUnwrap(engine._test_lastISOFile(for: id), "finalized ISO file for the deferred source")
        let size = try await trackNaturalSize(url)
        let subType = try await trackSubType(url)
        XCTAssertEqual(size, CGSize(width: 1280, height: 720), "finalized first-take file is native 1280×720")
        XCTAssertEqual(subType, kCMVideoCodecType_HEVC, "finalized first-take file is HEVC Main10 (HDR), not H.264")
        await engine.shutdown()
    }

    func testNegativeControlImmediateCanvasFallbackFreezesFirstTake1080pSDR() async throws {
        // NEGATIVE CONTROL: force the pre-fix immediate canvas-SDR fallback for the
        // no-frame source. The SAME 1280×720 HLG frames record 1920×1080 SDR H.264.
        AppEngine._test_forceISOImmediateCanvasFallback = true
        defer { AppEngine._test_forceISOImmediateCanvasFallback = false }
        let engine = AppEngine()
        let id = SourceID("iso.defer.neg")
        engine._test_addSyntheticISOSourceNoFrame(id: id)
        try engine.startRecording()
        let s = engine._test_isoRecorderSettings(for: id)
        XCTAssertEqual(s?.width, 1920, "negative control freezes canvas width")
        XCTAssertEqual(s?.height, 1080, "negative control freezes canvas height (1080p upscale)")
        XCTAssertEqual(s?.dynamicRange, .sdr, "negative control flattens to SDR on the first take")
        let base = HouseClock.now()
        for i in 0..<15 {
            var f = try makeHLG10(1280, 720, source: id)
            f = VideoFrame(pixelBuffer: f.pixelBuffer,
                           pts: CMTimeAdd(base, CMTime(value: Int64(i), timescale: 30)),
                           duration: CMTime(value: 1, timescale: 30), source: id)
            engine._test_feedISOFrame(f)
        }
        _ = await engine.stopRecording()
        let url = try XCTUnwrap(engine._test_lastISOFile(for: id))
        let size = try await trackNaturalSize(url)
        let subType = try await trackSubType(url)
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080), "negative control: finalized file upscaled to 1080p")
        XCTAssertEqual(subType, kCMVideoCodecType_H264, "negative control: finalized file flattened to 8-bit H.264 SDR")
        await engine.shutdown()
    }

    // MARK: - #2 feedISO:false suppresses the processed-frame ISO append (cutout routing)

    func testDeliverSourceFrameFeedISOFalseSuppressesProcessedISOAppend() throws {
        let id = SourceID("iso.cutout.route")
        let raw = try makeBGRA(320, 240, source: id)

        var isoBuffers: [CVPixelBuffer] = []
        AppEngine._test_isoRoutedFrame = { isoBuffers.append($0.pixelBuffer) }
        defer { AppEngine._test_isoRoutedFrame = nil }

        // A Presenter Cutout's PROGRAM sink passes feedISO:false — the processed
        // frame must NOT reach the ISO tap (ISO is fed the upstream raw separately).
        AppEngine.deliverSourceFrame(raw, pipeline: nil, monitor: nil, isoTap: ISOTap(),
                                     verticalTap: LatestFrameTap(), directorTap: DirectorTap(),
                                     sid: id, mailbox: FrameMailbox(), feedISO: false)
        XCTAssertTrue(isoBuffers.isEmpty, "feedISO:false must NOT route the processed frame to the clean ISO")

        // NEGATIVE CONTROL: the default (feedISO:true) routes the frame — the pre-fix
        // cutout path used this, baking the processed cutout into the ISO.
        AppEngine.deliverSourceFrame(raw, pipeline: nil, monitor: nil, isoTap: ISOTap(),
                                     verticalTap: LatestFrameTap(), directorTap: DirectorTap(),
                                     sid: id, mailbox: FrameMailbox())
        XCTAssertEqual(isoBuffers.count, 1, "negative control: feedISO:true routes the frame to ISO")
        XCTAssertTrue(isoBuffers.first === raw.pixelBuffer)
    }
}
