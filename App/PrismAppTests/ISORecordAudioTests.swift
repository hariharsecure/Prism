import CoreMedia
import CoreVideo
import Metal
import XCTest

import PrismColor
import PrismCore
import PrismOutput
@testable import Prism

/// sol #1 + #2 — ISO recording is CLEAN + NATIVE + HDR-correct, and the program
/// recording captures the PROGRAM MASTER MIX (not just `activeSources` audio).
///
/// Each defect is reproduced FIRST with a firing `#if DEBUG` negative control that
/// reverts ONLY the fix, then the fixed path is asserted. Oracles are real engine
/// state / real pixel-buffer identity — not tautologies.
@MainActor
final class ISORecordAudioTests: XCTestCase {

    // MARK: fixtures

    private func makeBGRA(_ w: Int, _ h: Int, source: SourceID) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_32BGRA)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<h {
            let p = (base + row * bpr).assumingMemoryBound(to: UInt8.self)
            for col in 0..<w { p[col * 4 + 0] = 30; p[col * 4 + 1] = 180; p[col * 4 + 2] = 60; p[col * 4 + 3] = 255 }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return VideoFrame(pixelBuffer: buf, pts: HouseClock.now(), source: source)
    }

    private func makeHLG10(_ w: Int, _ h: Int, source: SourceID) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_ARGB2101010LEPacked)
        let buf = try pool.makeBuffer()
        CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return VideoFrame(pixelBuffer: buf, pts: HouseClock.now(), source: source)
    }

    // MARK: - #1 native resolution (derived from the source frame, not hardcoded)

    func testISOSettingsAreNativeResolutionNotHardcoded1080p() async throws {
        let engine = AppEngine()
        let id = SourceID("iso.cam480")
        try engine._test_addSyntheticISOSource(id: id, nativeFrame: makeBGRA(640, 480, source: id))
        try engine.startRecording()
        let s = engine._test_isoRecorderSettings(for: id)
        XCTAssertEqual(s?.width, 640, "ISO width must be the source's native 640")
        XCTAssertEqual(s?.height, 480, "ISO height must be the source's native 480")
        XCTAssertEqual(s?.dynamicRange, .sdr)
        _ = await engine.stopRecording()

        // NEGATIVE CONTROL: pre-fix hardcoded 1920×1080.
        AppEngine._test_forceISOHardcodedSettings = true
        defer { AppEngine._test_forceISOHardcodedSettings = false }
        try engine.startRecording()
        let neg = engine._test_isoRecorderSettings(for: id)
        XCTAssertEqual(neg?.width, 1920)
        XCTAssertEqual(neg?.height, 1080, "negative control reproduces the hardcoded 1080p upscale")
        _ = await engine.stopRecording()
        await engine.shutdown()
    }

    // MARK: - #1 native HDR format (HDR source → .hdr → HEVC Main10 HLG)

    func testISOSettingsAreHDRForAnHLGSource() async throws {
        let engine = AppEngine()
        let id = SourceID("iso.hlg")
        try engine._test_addSyntheticISOSource(id: id, nativeFrame: makeHLG10(1280, 720, source: id))
        try engine.startRecording()
        let s = engine._test_isoRecorderSettings(for: id)
        // .hdr maps (in MovieRecorder) to HEVC Main10 + Rec.2020/HLG — file-verified
        // in ISONativeFormatFileTests / HDRRecorderSelfTest.
        XCTAssertEqual(s?.dynamicRange, .hdr, "a 10-bit HLG source must record HDR (HEVC Main10 HLG)")
        XCTAssertEqual(s?.width, 1280)
        XCTAssertEqual(s?.height, 720)
        _ = await engine.stopRecording()

        // NEGATIVE CONTROL: hardcoded path forces SDR H.264 (flattens the HDR source).
        AppEngine._test_forceISOHardcodedSettings = true
        defer { AppEngine._test_forceISOHardcodedSettings = false }
        try engine.startRecording()
        XCTAssertEqual(engine._test_isoRecorderSettings(for: id)?.dynamicRange, .sdr,
                       "negative control flattens the HLG source to SDR")
        _ = await engine.stopRecording()
        await engine.shutdown()
    }

    // MARK: - #1 clean: ISO gets the RAW frame, not the processed (graded) frame

    func testISORoutesRawFrameNotProcessed() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let id = SourceID("iso.clean")
        let raw = try makeBGRA(320, 240, source: id)
        let pipeline = SourceEffectPipeline(device: device, sourceID: id)
        pipeline.update(SourceEffects(grade: ColorGrade(exposure: 1.5))) // non-identity → allocates a NEW output buffer

        var isoBuffer: CVPixelBuffer?
        AppEngine._test_isoRoutedFrame = { isoBuffer = $0.pixelBuffer }
        defer { AppEngine._test_isoRoutedFrame = nil }

        AppEngine.deliverSourceFrame(raw, pipeline: pipeline, monitor: nil, isoTap: ISOTap(),
                                     verticalTap: LatestFrameTap(), directorTap: DirectorTap(),
                                     sid: id, mailbox: FrameMailbox())
        XCTAssertTrue(isoBuffer === raw.pixelBuffer,
                      "ISO must record the CLEAN raw frame (identical buffer), not the graded output")

        // NEGATIVE CONTROL: route the processed frame — ISO now gets the graded
        // (distinct) output buffer, the pre-fix behavior.
        AppEngine._test_isoUsesProcessedFrame = true
        defer { AppEngine._test_isoUsesProcessedFrame = false }
        isoBuffer = nil
        AppEngine.deliverSourceFrame(raw, pipeline: pipeline, monitor: nil, isoTap: ISOTap(),
                                     verticalTap: LatestFrameTap(), directorTap: DirectorTap(),
                                     sid: id, mailbox: FrameMailbox())
        XCTAssertNotNil(isoBuffer)
        XCTAssertFalse(isoBuffer === raw.pixelBuffer,
                       "negative control routes the PROCESSED frame (a different buffer)")
    }

    // MARK: - #2 record captures the program master mix (not gated on activeSources)

    func testRecordAlwaysWritesMasterMixAudioTrack() async throws {
        let engine = AppEngine()
        // A VIDEO-ONLY source (no audio source): soundboard/music/beat live in the
        // mixer, NOT `activeSources`. The recording must still write the master-mix
        // audio track (and a mic added AFTER start flows through it and is captured).
        engine.addTextSource(text: "video only")
        try engine.startRecording()
        XCTAssertEqual(engine._test_programRecorderSettings?.includeAudio, true,
                       "record must always write the program master-mix audio track")
        XCTAssertTrue(engine._test_fanOutWantsAudio,
                      "the master-mix tap must be armed to feed the recorder")
        _ = await engine.stopRecording()

        // NEGATIVE CONTROL: the pre-fix gate on `activeSources` — a video-only
        // source creates NO audio input, so mixer-only audio (and any late mic) is
        // discarded and the recording is silent.
        AppEngine._test_gateRecordAudioOnActiveSources = true
        defer { AppEngine._test_gateRecordAudioOnActiveSources = false }
        try engine.startRecording()
        XCTAssertEqual(engine._test_programRecorderSettings?.includeAudio, false,
                       "negative control: activeSources-gated start drops the master mix (silent recording)")
        XCTAssertFalse(engine._test_fanOutWantsAudio)
        _ = await engine.stopRecording()
        await engine.shutdown()
    }
}
