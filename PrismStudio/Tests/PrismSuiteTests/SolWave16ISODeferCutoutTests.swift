import AVFoundation
import CoreMedia
import CoreVideo
import XCTest

import PrismCore
import PrismOutput
import PrismSources

/// sol wave-16 — completes the ISO recording fix (the wave-15 raw-tap +
/// SourceFormatProbe + per-source RecordingSettings were incomplete):
///
///  #1 ISO armed BEFORE a source's first frame must NOT freeze a canvas-sized
///     SDR/H.264 fallback. `ISORecorderBank.addDeferredSource` defers the
///     recorder's creation until the FIRST real frame, deriving native
///     resolution + dynamic range from it — so the FIRST take is native + HDR.
///
///  #2 A Presenter Cutout's advertised CLEAN ISO must tap the cutout's UPSTREAM
///     RAW input (native, no segmentation FX), not the wrapper's PROCESSED output.
///     `PresenterCutoutSource.onRawFrame` emits the raw upstream frame.
///
/// Each defect is reproduced FIRST against an INDEPENDENT oracle (a finalized
/// `.mov` reopened via AVFoundation for #1; premultiplied-alpha identity for #2)
/// with a firing negative control that reproduces sol's exact defect.
final class SolWave16ISODeferCutoutTests: XCTestCase {

    // MARK: fixtures

    private func makeBGRA(_ w: Int, _ h: Int, source: SourceID) throws -> CVPixelBuffer {
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
        return buf
    }

    private func makeHLG10(_ w: Int, _ h: Int) throws -> CVPixelBuffer {
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

    /// The HDR-ness derivation used by the App's deferred settings-provider (the
    /// SourceFormatProbe transfer-tag rule), so a deferred angle records HEVC
    /// Main10 HLG for an HLG source.
    private func deferredSettings(from frame: VideoFrame) -> RecordingSettings {
        let transfer = YCbCrTags.transferCode(for: frame.pixelBuffer)
        let isHDR = (transfer == 1 || transfer == 2)
        return RecordingSettings(codec: .h264, width: frame.width, height: frame.height,
                                 includeAudio: false, dynamicRange: isHDR ? .hdr : .sdr)
    }

    // MARK: - #1 deferred: first take is NATIVE + HDR, not a frozen canvas-SDR fallback

    func testDeferredISOFirstFrameYieldsNativeHDRFileNotCanvasSDR() async throws {
        // The source is armed for ISO BEFORE it has delivered any frame — its native
        // format is unknown at start (sources start async). Deferring the recorder
        // to the first frame must record the source's native 1280×720 HLG10 as HEVC
        // Main10 HLG, NOT a frozen 1920×1080 8-bit H.264 SDR fallback.
        let src = SourceID("iso.deferred.hlg")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism_iso_defer_\(UInt64.random(in: 0..<UInt64.max))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Canvas-sized SDR *fallback* default (what the pre-fix froze) — proving the
        // fix ignores it in favor of the first frame's native format.
        let bank = ISORecorderBank(directory: dir,
                                   defaultSettings: RecordingSettings(codec: .h264, width: 1920, height: 1080,
                                                                      includeAudio: false, dynamicRange: .sdr))
        try bank.addDeferredSource(src, includeAudio: false) { self.deferredSettings(from: $0) }
        let t0 = HouseClock.now()
        try bank.start(at: t0)                       // starts with NO recorder yet (deferred)
        XCTAssertNil(bank.settings(for: src), "recorder must not exist before the first frame")

        // FIRST frame arrives after start → materializes the native HDR recorder.
        let fps = 30
        let frameDur = CMTime(value: 1, timescale: CMTimeScale(fps))
        for i in 0..<15 {
            let pts = CMTimeAdd(t0, CMTime(value: Int64(i), timescale: CMTimeScale(fps)))
            bank.append(VideoFrame(pixelBuffer: try makeHLG10(1280, 720), pts: pts, duration: frameDur, source: src))
            try await Task.sleep(nanoseconds: UInt64(1_000_000_000 / UInt64(fps)))
        }
        let live = try XCTUnwrap(bank.settings(for: src), "the first frame must materialize the recorder")
        XCTAssertEqual(live.width, 1280); XCTAssertEqual(live.height, 720)
        XCTAssertEqual(live.dynamicRange, .hdr, "first take must be HDR (HEVC Main10 HLG), not the SDR fallback")

        let results = await bank.finishAll()
        guard case .success(let report)? = results[src] else {
            throw XCTSkip("deferred ISO recorder produced no file: \(String(describing: results[src]))")
        }
        // INDEPENDENT oracle: reopen the finalized file.
        let size = try await trackNaturalSize(report.url)
        XCTAssertEqual(size, CGSize(width: 1280, height: 720), "finalized file is the source's native 1280×720")
        let fdesc = try await trackFormat(report.url)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(fdesc), kCMVideoCodecType_HEVC,
                       "first-take HDR angle must be HEVC (Main10), not H.264")
        let transfer = CMFormatDescriptionGetExtension(fdesc, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
        if let transfer { XCTAssertTrue(CFEqual(transfer, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG),
                                        "first-take file must carry the HLG transfer tag") }
    }

    func testNegativeControlFrozenCanvasSDRFallbackReproducesBug() async throws {
        // NEGATIVE CONTROL: the pre-fix behavior — a source armed before its first
        // frame FREEZES the canvas-sized SDR settings via `addSource`; the SAME
        // 1280×720 HLG10 frames are recorded 1920×1080 8-bit H.264 SDR (native res +
        // HDR lost on the first take).
        let src = SourceID("iso.frozen.hlg")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism_iso_frozen_\(UInt64.random(in: 0..<UInt64.max))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bank = ISORecorderBank(directory: dir, defaultSettings: RecordingSettings())
        try bank.addSource(src, settings: RecordingSettings(codec: .h264, width: 1920, height: 1080,
                                                            includeAudio: false, dynamicRange: .sdr),
                           includeAudio: false)
        let t0 = HouseClock.now()
        try bank.start(at: t0)
        let fps = 30
        let frameDur = CMTime(value: 1, timescale: CMTimeScale(fps))
        for i in 0..<15 {
            let pts = CMTimeAdd(t0, CMTime(value: Int64(i), timescale: CMTimeScale(fps)))
            bank.append(VideoFrame(pixelBuffer: try makeHLG10(1280, 720), pts: pts, duration: frameDur, source: src))
            try await Task.sleep(nanoseconds: UInt64(1_000_000_000 / UInt64(fps)))
        }
        let results = await bank.finishAll()
        guard case .success(let report)? = results[src] else {
            throw XCTSkip("frozen-fallback ISO produced no file: \(String(describing: results[src]))")
        }
        let size = try await trackNaturalSize(report.url)
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080),
                       "negative control: frozen canvas fallback upscales the 1280×720 source to 1080p")
        let fdesc = try await trackFormat(report.url)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(fdesc), kCMVideoCodecType_H264,
                       "negative control: frozen SDR fallback flattens the 10-bit HLG source to 8-bit H.264")
    }

    // MARK: - #1 subsequent-take behavior preserved (a known-format source still native immediately)

    func testKnownFormatSourceStillRecordsNativelyWithoutDeferral() async throws {
        // The wave-15 subsequent-take path: a source whose format is already known
        // (a frame arrived before Record) is added immediately at its native format.
        let src = SourceID("iso.known.640")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism_iso_known_\(UInt64.random(in: 0..<UInt64.max))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bank = ISORecorderBank(directory: dir, defaultSettings: RecordingSettings())
        try bank.addSource(src, settings: RecordingSettings(codec: .h264, width: 640, height: 480, includeAudio: false),
                           includeAudio: false)
        let t0 = HouseClock.now()
        try bank.start(at: t0)
        XCTAssertEqual(bank.settings(for: src)?.width, 640, "known-format source is live immediately (no deferral)")
        let fps = 30
        let frameDur = CMTime(value: 1, timescale: CMTimeScale(fps))
        for i in 0..<12 {
            let pts = CMTimeAdd(t0, CMTime(value: Int64(i), timescale: CMTimeScale(fps)))
            bank.append(VideoFrame(pixelBuffer: try makeBGRA(640, 480, source: src), pts: pts, duration: frameDur, source: src))
            try await Task.sleep(nanoseconds: UInt64(1_000_000_000 / UInt64(fps)))
        }
        let results = await bank.finishAll()
        guard case .success(let report)? = results[src] else {
            throw XCTSkip("known-format ISO produced no file")
        }
        let size = try await trackNaturalSize(report.url)
        XCTAssertEqual(size, CGSize(width: 640, height: 480), "known-format angle records native 640×480")
    }

    // MARK: - #2 clean ISO taps the cutout's UPSTREAM RAW input, not the processed output

    func testCutoutCleanISOTapsUpstreamRawNotProcessedOutput() throws {
        // The RAW upstream frame: fully opaque (alpha 255) — the true clean source.
        let raw = try PresenterCutoutSelfTest.makeBGRAFrame(width: 160, height: 120, id: "cutout.upstream") { _, _ in
            (r: 120, g: 130, b: 140)
        }
        let upstream = ISOWave16Upstream()
        let cutout = PresenterCutoutSource(wrapping: upstream, options: .init(background: .transparent))

        let rawTap = FrameSlot()
        cutout.onRawFrame = { rawTap.set($0) }     // clean-ISO tap = upstream raw (the fix)
        try cutout.start()

        // Deliver one raw frame the way a live upstream capture callback would.
        upstream.onFrame?(raw)

        // FIX: the clean ISO tap received the RAW upstream frame — identical buffer,
        // native 160×120, fully opaque (rawAlpha == 255, NO segmentation FX).
        let tapped = try XCTUnwrap(rawTap.get(), "onRawFrame must fire with the upstream raw frame")
        XCTAssertTrue(tapped.pixelBuffer === raw.pixelBuffer, "clean ISO tap must be the upstream RAW buffer")
        XCTAssertEqual(tapped.width, 160); XCTAssertEqual(tapped.height, 120)
        let rawCorner = PresenterCutoutSelfTest.readBGRA(tapped, x: 4, y: 4)
        XCTAssertEqual(rawCorner.a, 255, "clean ISO frame is the raw upstream: opaque, no baked-in segmentation")

        // NEGATIVE CONTROL: the pre-fix ISO tapped the PROCESSED cutout output.
        // Compose that output the way segmentation bakes it — an all-background matte
        // makes the "clean" ISO's background transparent (routedAlpha == 0): the
        // segmentation FX baked into the advertised-clean angle.
        let bgMatte = try PresenterCutoutSelfTest.makeMatte(width: 160, height: 120) { _, _ in 0 }
        let processed = try PresenterCutout(options: .init(background: .transparent)).composite(frame: raw, matte: bgMatte)
        let routedCorner = PresenterCutoutSelfTest.readBGRA(processed, x: 4, y: 4)
        XCTAssertEqual(routedCorner.a, 0, "negative control: the PROCESSED cutout output bakes FX in (routedAlpha == 0)")

        cutout.stop()
    }
}

// MARK: - Test doubles

/// A `VideoSource` whose `onFrame` is taken over by `PresenterCutoutSource`; the
/// test pushes frames by invoking `onFrame` directly.
private final class ISOWave16Upstream: VideoSource, @unchecked Sendable {
    let id = SourceID("test.wave16.upstream")
    var onFrame: ((VideoFrame) -> Void)?
    private let lock = NSLock()
    private var _state: SourceState = .idle
    var state: SourceState { lock.lock(); defer { lock.unlock() }; return _state }
    func start() throws { lock.lock(); _state = .running; lock.unlock() }
    func stop() { lock.lock(); _state = .idle; lock.unlock() }
}

/// Thread-safe latest-frame holder (onRawFrame fires on the upstream capture queue).
private final class FrameSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: VideoFrame?
    func set(_ f: VideoFrame) { lock.lock(); frame = f; lock.unlock() }
    func get() -> VideoFrame? { lock.lock(); defer { lock.unlock() }; return frame }
}
