import AVFoundation
import CoreMedia
import CoreVideo
import PrismCore
import XCTest

@testable import PrismOutput

/// Deterministic verification of the auto-highlight extractor
/// `ReplayBuffer.saveHighlight(lastSeconds:to:)` — the "clip that moment"
/// button. Synthesizes DISTINCT frames whose solid gray level encodes the frame
/// index (`gray = base + index*step`), pushes more than the buffer's capacity so
/// the ring WRAPS, saves a highlight of the last N seconds, then reopens the
/// clip and decodes the saved frames' gray levels back to indices — proving the
/// clip is the recent TAIL (and the ring wrapped correctly), not the head.
///
/// Needs the hardware VideoToolbox H.264 *encoder* (no TCC / capture
/// permission) and the decoder; both are available on the CI Mac.
final class ReplayHighlightTests: XCTestCase {

    // Encoding of index → gray level (solid frame). Kept coarse (×2) so the
    // lossy H.264 round-trip can't confuse adjacent indices, and bounded well
    // inside limited luma range so nothing clips.
    private let base = 20
    private let step = 2

    private let width = 160
    private let height = 120
    private let fps = 30
    private let gop = 15          // forced keyframe cadence (0.5 s)
    private let windowSeconds = 2.0
    private let totalFrames = 90  // 3 s of frames into a 2 s ring → wraps

    // MARK: - Tail-after-wrap (the core proof)

    func testSaveHighlightSavesRecentTailAfterWrap() async throws {
        let replay = try feedWrappingBuffer()

        let status = replay.status
        print("[replay] ring after wrap: \(status.frameCount) frames / \(status.keyframeCount) keyframes, " +
              "span=\(String(format: "%.3f", status.bufferedDuration.seconds))s leadsKey=\(status.leadsWithKeyframe)")
        XCTAssertTrue(status.leadsWithKeyframe, "ring must lead with a keyframe")
        // Wrapped: a 2 s window can't hold all 3 s (90 frames) of program.
        XCTAssertLessThan(status.frameCount, totalFrames, "ring did not wrap — nothing was evicted")

        let url = tempURL("tail")
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try await replay.saveHighlight(lastSeconds: 1.0, to: url)
        print("[replay] saveHighlight(1.0s) → \(report)")

        // File exists + is decodable, and we recover an index per frame.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "highlight file missing")
        let indices = try await decodeIndices(url: url)
        XCTAssertFalse(indices.isEmpty, "no frames decoded")

        let firstIdx = indices.first!, lastIdx = indices.last!
        let minIdx = indices.min()!, maxIdx = indices.max()!
        print("[replay] decoded \(indices.count) frames; recovered index range [\(minIdx)…\(maxIdx)] " +
              "first=\(firstIdx) last=\(lastIdx); duration=\(String(format: "%.3f", report.duration.seconds))s")

        // ~1 s @ 30 fps = 30 frames; a GOP-aligned start may add up to one GOP.
        XCTAssertGreaterThanOrEqual(report.frameCount, 30, "highlight shorter than 1 s")
        XCTAssertLessThanOrEqual(report.frameCount, 46, "highlight far longer than 1 s + one GOP")
        XCTAssertEqual(indices.count, report.frameCount, "decoded frame count ≠ report")
        XCTAssertGreaterThanOrEqual(report.duration.seconds, 0.95)
        XCTAssertLessThanOrEqual(report.duration.seconds, 1.6)

        // THE TAIL PROOF: recovered indices are the most-recent frames.
        //  - newest source frame is index 89 → last saved index must be ~89.
        //  - ring head after wrap sits at ~index 15; index 0 is long evicted.
        //    A min recovered index far above the head proves we saved the tail.
        XCTAssertGreaterThanOrEqual(lastIdx, 84, "last saved frame is not the newest (~89) — did not save the tail")
        XCTAssertGreaterThanOrEqual(minIdx, 48, "saved head/evicted frames — not the recent tail")
        XCTAssertGreaterThan(lastIdx - firstIdx, 20, "saved window suspiciously narrow for a 1 s clip")

        // Order preserved (allow ±1 decode jitter on the ×2 luma step).
        for i in 1..<indices.count {
            XCTAssertGreaterThanOrEqual(indices[i], indices[i - 1] - 1,
                                        "frames out of order at \(i): \(indices[i]) < \(indices[i - 1])")
        }
    }

    // MARK: - Windowed extractor (Director's Cut moment + post-roll)

    /// `saveHighlight(from:to:)` pins BOTH edges to absolute house PTS, so a
    /// mid-buffer window `[a, b]` selects the frames straddling `a…b` (keyframe-led)
    /// — the run-up AND payoff around a peak, not a trailing tail. Feeds an
    /// un-wrapped 3 s buffer (indices 0…89 @ 30 fps → PTS = index/30) and asks for
    /// the window [1.0 s, 2.0 s] (indices ~30…60); reopens + decodes to prove the
    /// recovered indices sit inside that window (leading GOP alignment allowed).
    func testSaveHighlightWindowSelectsInteriorSpan() async throws {
        let encoder = ProgramEncoder(settings: .init(
            codec: .h264, width: width, height: height, averageBitrate: 4_000_000,
            keyframeInterval: 100.0, expectedFrameRate: Double(fps), lowLatencyRateControl: false))
        let replay = ReplayBuffer(seconds: 10, fragmentInterval: 0.5)  // 10 s ring → nothing evicted
        encoder.onEncodedFrame = { replay.append($0) }
        try encoder.start()
        let pool = try PixelBufferPool(width: width, height: height)
        let src = SourceID("test.window")
        let frameDur = CMTime(value: 1, timescale: CMTimeScale(fps))
        for i in 0..<totalFrames {                       // 90 frames = 3 s
            if i % gop == 0 { encoder.forceKeyframe() }
            let pts = CMTime(value: Int64(i), timescale: CMTimeScale(fps))
            try encoder.encode(makeSolidFrame(pool: pool, gray: UInt8(base + i * step),
                                              pts: pts, duration: frameDur, source: src))
        }
        encoder.flush(); encoder.stop()

        // Coverage spans the whole 3 s.
        let cover = try XCTUnwrap(replay.coveredWindow)
        XCTAssertEqual(cover.start.seconds, 0, accuracy: 0.05)
        XCTAssertGreaterThan(cover.end.seconds, 2.9)

        let url = tempURL("window")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = CMTime(seconds: 1.0, preferredTimescale: 600)
        let b = CMTime(seconds: 2.0, preferredTimescale: 600)
        let report = try await replay.saveHighlight(from: a, to: b, to: url)
        print("[replay] saveHighlight(1.0→2.0s) → \(report)")

        let indices = try await decodeIndices(url: url)
        XCTAssertFalse(indices.isEmpty)
        let minIdx = indices.min()!, maxIdx = indices.max()!
        // Window [1.0, 2.0] s = indices 30…60. Leading edge may back up to the GOP
        // keyframe (≤ index 30, ≥ 15 with gop=15); it must NOT include the head (0)
        // nor the tail (89).
        XCTAssertGreaterThanOrEqual(minIdx, 15, "leading edge older than one GOP before the window")
        XCTAssertLessThanOrEqual(minIdx, 32, "leading edge should be near the window start")
        XCTAssertGreaterThanOrEqual(maxIdx, 55, "window did not reach ~2.0 s")
        XCTAssertLessThanOrEqual(maxIdx, 62, "window overran past ~2.0 s")
        XCTAssertLessThan(maxIdx, 89, "must not include the newest tail frame")
    }

    /// A window whose end runs past the newest buffered frame CLAMPS to the ring
    /// (no throw) — the post-roll not-yet-arrived / shutdown-truncated case.
    func testSaveHighlightWindowClampsPastEnd() async throws {
        let replay = try feedWrappingBuffer()
        let cover = try XCTUnwrap(replay.coveredWindow)
        let url = tempURL("windowclamp")
        defer { try? FileManager.default.removeItem(at: url) }
        // Ask well past the newest frame → clamps to coverage, still decodable.
        let report = try await replay.saveHighlight(
            from: CMTime(seconds: cover.start.seconds + 0.1, preferredTimescale: 600),
            to: CMTime(seconds: cover.end.seconds + 999, preferredTimescale: 600), to: url)
        XCTAssertGreaterThan(report.frameCount, 0)
        XCTAssertLessThanOrEqual(report.duration.seconds, cover.end.seconds - cover.start.seconds + 0.5)
    }

    // MARK: - Clamp (lastSeconds > buffered)

    func testSaveHighlightClampsToWholeBufferWhenOverBuffered() async throws {
        let replay = try feedWrappingBuffer()
        let whole = replay.status.frameCount

        let clampURL = tempURL("clamp")
        defer { try? FileManager.default.removeItem(at: clampURL) }
        let clamp = try await replay.saveHighlight(lastSeconds: 999.0, to: clampURL)
        print("[replay] saveHighlight(999s) clamps → \(clamp) (whole ring = \(whole) frames)")

        XCTAssertEqual(clamp.frameCount, whole, "clamp did not save the whole buffer")
        // Duration ≈ the full retained span (2 s window + GOP alignment).
        XCTAssertGreaterThan(clamp.duration.seconds, windowSeconds - 0.2)
        XCTAssertLessThan(clamp.duration.seconds, windowSeconds + 1.5)

        // And it saved more than a 1 s highlight would.
        let shortURL = tempURL("short")
        defer { try? FileManager.default.removeItem(at: shortURL) }
        let short = try await replay.saveHighlight(lastSeconds: 1.0, to: shortURL)
        XCTAssertGreaterThan(clamp.frameCount, short.frameCount, "clamp not larger than the 1 s highlight")
    }

    // MARK: - Empty buffer

    func testSaveHighlightOnEmptyBufferThrowsTyped() async throws {
        let replay = ReplayBuffer(seconds: windowSeconds)
        let url = tempURL("empty")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await replay.saveHighlight(lastSeconds: 1.0, to: url)
            XCTFail("expected ReplayError.empty")
        } catch ReplayBuffer.ReplayError.empty {
            // Expected — typed error, no crash.
            print("[replay] empty buffer → ReplayError.empty ✓")
        }
    }

    // MARK: - Audio trailing-edge trim (audio must not outlast the video window)

    /// Regression for the adversarial-review finding: `mux` kept every audio
    /// buffer overlapping the clip window but trimmed only the LEADING edge, so a
    /// buffer with `pts < clipEnd < end` was written in FULL and the saved audio
    /// track ran PAST the video clip (and past `ClipReport.duration`).
    ///
    /// Feeds 2 s of video into a 5 s ring (nothing evicted → clip origin 0,
    /// clipEnd 2.0 s) plus audio buffers up to 1.5 s, then a deliberately LONG
    /// final buffer (pts 1.5 s, dur 3.0 s → end 4.5 s) straddling the trailing
    /// edge. Reopens the file and asserts the AUDIO track ends at ≤ the video
    /// clip duration + epsilon. PRE-FIX the audio end is ~4.5 s ≫ 2.0 s → FAILS;
    /// with the trailing trim it is bounded to ~2.0 s.
    func testSavedClipAudioDoesNotExtendPastVideoWindow() async throws {
        let w = 320, h = 240, fps = 30, videoSeconds = 2, window = 5.0
        let encoder = ProgramEncoder(settings: .init(
            codec: .h264, width: w, height: h, averageBitrate: 2_000_000,
            keyframeInterval: 1.0, expectedFrameRate: Double(fps), lowLatencyRateControl: false))
        let replay = ReplayBuffer(seconds: window, fragmentInterval: 0.5)
        encoder.onEncodedFrame = { replay.append($0) }
        try encoder.start()

        let pool = try PixelBufferPool(width: w, height: h)
        let src = SourceID("test.audioendtrim")
        let frameDur = CMTime(value: 1, timescale: CMTimeScale(fps))
        for i in 0..<(videoSeconds * fps) {
            let pts = CMTime(value: Int64(i), timescale: CMTimeScale(fps))
            try encoder.encode(makeSolidFrame(pool: pool, gray: UInt8(20 + i), pts: pts,
                                              duration: frameDur, source: src))
        }
        encoder.flush()
        encoder.stop() // drains delivery — clip end = 60/30 = 2.0 s

        // Audio on the same house timeline: 0.5 s buffers to 1.5 s, then a LONG
        // 3.0 s buffer (end 4.5 s) that overshoots the 2.0 s video window.
        for t in [0.0, 0.5, 1.0] {
            let sb = try XCTUnwrap(makeSilentAudio(pts: CMTime(seconds: t, preferredTimescale: 48_000), seconds: 0.5))
            replay.appendAudio(sb)
        }
        let longBuf = try XCTUnwrap(makeSilentAudio(pts: CMTime(seconds: 1.5, preferredTimescale: 48_000), seconds: 3.0))
        replay.appendAudio(longBuf)

        let url = tempURL("audioendtrim")
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try await replay.saveClip(to: url)
        print("[replay] saveClip(long-final-audio) → \(report)")
        XCTAssertGreaterThan(report.audioSampleCount, 0, "no audio muxed — straddler dropped entirely (regressed)")

        let asset = AVURLAsset(url: url)
        let atracks = try await asset.loadTracks(withMediaType: .audio)
        let atrack = try XCTUnwrap(atracks.first, "saved clip has no audio track")
        let range = try await atrack.load(.timeRange)
        let audioEnd = (range.start + range.duration).seconds
        let videoDur = report.duration.seconds
        print("[replay] audio end=\(String(format: "%.4f", audioEnd))s  video clip dur=\(String(format: "%.4f", videoDur))s")

        // THE END-TRIM PROOF: audio must not outlast the video window.
        XCTAssertLessThanOrEqual(audioEnd, videoDur + 0.05,
            "saved audio (end \(audioEnd)s) extends past the video clip window (\(videoDur)s) — trailing trim missing")
        // And it must still cover the window (not over-trimmed to nothing).
        XCTAssertGreaterThanOrEqual(audioEnd, Double(videoSeconds) - 0.1,
            "audio over-trimmed — ends well before the video window")
    }

    /// Silent interleaved mono Float32 LPCM `CMSampleBuffer` with a real
    /// (zero-filled) data block — appendable to a passthrough audio input.
    private func makeSilentAudio(pts: CMTime, seconds: Double, sampleRate: Double = 48_000) -> CMSampleBuffer? {
        let frames = Int((seconds * sampleRate).rounded())
        guard frames > 0 else { return nil }
        let bytesPerFrame = 4 // mono Float32
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame), mChannelsPerFrame: 1,
            mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format) == noErr, let format else { return nil }

        let dataSize = frames * bytesPerFrame
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: dataSize,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer) == noErr,
            let blockBuffer else { return nil }
        guard CMBlockBufferFillDataBytes(with: 0, blockBuffer: blockBuffer,
                                         offsetIntoDestination: 0, dataLength: dataSize) == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleSize = bytesPerFrame
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: format, sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sb) == noErr, let sb else { return nil }
        return sb
    }

    // MARK: - Fixtures

    /// Encodes `totalFrames` DISTINCT solid frames (gray encodes the index) at
    /// `fps`, forcing a keyframe every `gop`, into a `windowSeconds` ring so it
    /// wraps. Returns the warmed buffer (all deliveries drained).
    private func feedWrappingBuffer() throws -> ReplayBuffer {
        let encoder = ProgramEncoder(settings: .init(
            codec: .h264, width: width, height: height, averageBitrate: 4_000_000,
            keyframeInterval: 100.0, // only forced keyframes → deterministic GOPs
            expectedFrameRate: Double(fps), lowLatencyRateControl: false))
        let replay = ReplayBuffer(seconds: windowSeconds, fragmentInterval: 0.5)
        encoder.onEncodedFrame = { replay.append($0) }
        try encoder.start()

        let pool = try PixelBufferPool(width: width, height: height)
        let src = SourceID("test.highlight")
        let frameDur = CMTime(value: 1, timescale: CMTimeScale(fps))
        for i in 0..<totalFrames {
            if i % gop == 0 { encoder.forceKeyframe() }
            let pts = CMTime(value: Int64(i), timescale: CMTimeScale(fps))
            let gray = UInt8(base + i * step)
            try encoder.encode(makeSolidFrame(pool: pool, gray: gray, pts: pts, duration: frameDur, source: src))
        }
        encoder.flush()
        encoder.stop() // drains delivery — every append has landed
        return replay
    }

    /// Solid BGRA frame, every pixel = `gray` (TEST-ONLY CPU fill).
    private func makeSolidFrame(pool: PixelBufferPool, gray: UInt8, pts: CMTime,
                                duration: CMTime, source: SourceID) throws -> VideoFrame {
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let addr = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let hh = CVPixelBufferGetHeight(buf), ww = CVPixelBufferGetWidth(buf)
        for y in 0..<hh {
            let row = addr.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
            for x in 0..<ww {
                row[x * 4 + 0] = gray; row[x * 4 + 1] = gray
                row[x * 4 + 2] = gray; row[x * 4 + 3] = 255
            }
        }
        return VideoFrame(pixelBuffer: buf, pts: pts, duration: duration, source: source)
    }

    /// Reopens the clip, decodes each frame to BGRA and recovers the encoded
    /// index from the center pixel's gray level: `round((gray − base) / step)`.
    private func decodeIndices(url: URL) async throws -> [Int] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first
        let vtrack = try XCTUnwrap(track, "saved clip has no video track")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: vtrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading(), "reader failed: \(String(describing: reader.error))")

        var indices: [Int] = []
        while let sb = output.copyNextSampleBuffer() {
            guard let img = CMSampleBufferGetImageBuffer(sb) else { continue }
            CVPixelBufferLockBaseAddress(img, .readOnly)
            let bpr = CVPixelBufferGetBytesPerRow(img)
            let hh = CVPixelBufferGetHeight(img), ww = CVPixelBufferGetWidth(img)
            let row = CVPixelBufferGetBaseAddress(img)!
                .advanced(by: (hh / 2) * bpr).assumingMemoryBound(to: UInt8.self)
            let x = ww / 2
            let avg = (Int(row[x * 4 + 0]) + Int(row[x * 4 + 1]) + Int(row[x * 4 + 2])) / 3
            CVPixelBufferUnlockBaseAddress(img, .readOnly)
            indices.append(Int((Double(avg - base) / Double(step)).rounded()))
        }
        XCTAssertEqual(reader.status, .completed, "decode did not complete")
        return indices
    }

    private func tempURL(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("prism_highlight_\(tag)_\(UInt64.random(in: 0..<UInt64.max)).mov")
    }
}
