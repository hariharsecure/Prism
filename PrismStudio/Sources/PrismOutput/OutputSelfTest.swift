import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import PrismCore
import VideoToolbox

/// Headless self-verification for the output module's replay-buffer and ISO
/// control surfaces (no TCC, no capture hardware — VideoToolbox *encode* needs
/// no permission).
///
/// TEST CODE ONLY: fills pixel buffers on the CPU to synthesize program frames.
/// That is allowed here and forbidden on the engine hot path.
///
/// The integrator can wire `OutputSelfTest.run()` into prism-dev / XCTest, or
/// exercise it standalone via the `.build` object-link pattern documented in
/// the module summary. Each check throws with a precise message on first
/// failure and returns human-readable evidence lines on success.
public enum OutputSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case setupFailed(String)
        case assertion(String)
        public var description: String {
            switch self {
            case .setupFailed(let s): return "output self-test setup failed: \(s)"
            case .assertion(let s): return "output self-test assertion failed: \(s)"
            }
        }
    }

    /// Runs every check; returns all evidence lines.
    public static func run() async throws -> [String] {
        var lines: [String] = []
        lines.append("── ReplayBuffer")
        lines += try await runReplayBuffer()
        lines.append("── ReplayBuffer.saveHighlight (recent tail after wrap)")
        lines += try await runSaveHighlight()
        lines.append("── ReplayBuffer (with straddling audio)")
        lines += try await runReplayBufferWithAudio()
        lines.append("── ISORecorderBank")
        lines += try await runISO()
        return lines
    }

    // MARK: - ReplayBuffer

    /// Feeds 10 s of encoded frames (30 fps, 1 s keyframe interval) into a 5 s
    /// buffer, saves the clip, reopens it and asserts: 1 video track, duration
    /// ≈ 5 s (± one keyframe interval, GOP alignment), first sample is a sync
    /// sample, and the reader decodes from frame 0 to completion.
    public static func runReplayBuffer() async throws -> [String] {
        var lines: [String] = []
        let w = 320, h = 240, fps = 30, seconds = 10, window = 5.0
        let encoder = ProgramEncoder(settings: .init(
            codec: .h264, width: w, height: h, averageBitrate: 2_000_000,
            keyframeInterval: 1.0, expectedFrameRate: Double(fps), lowLatencyRateControl: false))
        let replay = ReplayBuffer(seconds: window, fragmentInterval: 0.5)
        encoder.onEncodedFrame = { replay.append($0) }
        do { try encoder.start() } catch {
            throw SelfTestError.setupFailed("VT encoder start (hardware H.264 encode required): \(error)")
        }

        let pool: PixelBufferPool
        do { pool = try PixelBufferPool(width: w, height: h) }
        catch { throw SelfTestError.setupFailed("pixel pool: \(error)") }

        let total = seconds * fps
        let src = SourceID("selftest.replay")
        for i in 0..<total {
            let pts = CMTime(value: Int64(i), timescale: CMTimeScale(fps))
            let phase = UInt8((i * 9) % 255)
            let frame = try fillFrame(pool: pool, gray: phase, pts: pts,
                                      duration: CMTime(value: 1, timescale: CMTimeScale(fps)), source: src)
            try encoder.encode(frame)
        }
        encoder.flush()
        encoder.stop() // drains delivery — all appends have landed

        let st = replay.status
        lines.append(String(format: "   fed %d frames (%ds @%dfps) → buffer holds %d frames / %d keyframes, span=%.3fs bytes=%d leadsKey=%@",
                            total, seconds, fps, st.frameCount, st.keyframeCount,
                            st.bufferedDuration.seconds, st.bytesBuffered, st.leadsWithKeyframe ? "yes" : "no"))
        guard st.frameCount > 0 else { throw SelfTestError.assertion("buffer empty after feeding — encoder produced no output") }
        guard st.leadsWithKeyframe else { throw SelfTestError.assertion("buffer does not lead with a keyframe") }
        // The retained span must cover the window (≥) but not the whole 10 s.
        guard st.bufferedDuration.seconds >= window - 0.2 else {
            throw SelfTestError.assertion(String(format: "buffered span %.3fs < window %.1fs", st.bufferedDuration.seconds, window))
        }
        guard st.bufferedDuration.seconds <= window + 1.5 else {
            throw SelfTestError.assertion(String(format: "buffered span %.3fs kept far more than the window (%.1fs) — eviction not trimming", st.bufferedDuration.seconds, window))
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism_replay_selftest_\(UInt64.random(in: 0..<UInt64.max)).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try await replay.saveClip(to: url)
        lines.append("   saveClip → \(report)")

        // Reopen the finished file and verify independently.
        let asset = AVURLAsset(url: url)
        let dur = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
        lines.append(String(format: "   reopened: duration=%.3fs videoTracks=%d bytes=%d", dur, tracks.count, size))
        guard tracks.count == 1 else { throw SelfTestError.assertion("expected 1 video track, got \(tracks.count)") }
        guard dur >= window - 0.3, dur <= window + 1.5 else {
            throw SelfTestError.assertion(String(format: "reopened duration %.3fs not ≈ %.1fs (window + up to 1 keyframe interval)", dur, window))
        }

        // First sample must be a sync sample; reader must decode from the start.
        guard let track = tracks.first else { throw SelfTestError.assertion("no video track to read") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil) // passthrough encoded samples
        guard reader.canAdd(output) else { throw SelfTestError.assertion("reader cannot add track output") }
        reader.add(output)
        guard reader.startReading() else {
            throw SelfTestError.assertion("reader failed to start: \(String(describing: reader.error))")
        }
        guard let firstSample = output.copyNextSampleBuffer() else {
            throw SelfTestError.assertion("reader yielded no samples from the start")
        }
        let firstIsSync = ReplayBuffer.isSyncSample(firstSample)
        var readCount = 1
        while let next = output.copyNextSampleBuffer() { _ = next; readCount += 1 }
        lines.append("   AVAssetReader: firstSampleIsSync=\(firstIsSync) samplesReadFromStart=\(readCount) status=\(reader.status.rawValue)")
        guard firstIsSync else { throw SelfTestError.assertion("clip does not start on a sync sample — would not decode from frame 0") }
        guard reader.status == .completed else {
            throw SelfTestError.assertion("reader did not complete from the start (status \(reader.status.rawValue), \(String(describing: reader.error)))")
        }
        guard readCount >= report.frameCount else {
            throw SelfTestError.assertion("read \(readCount) samples but saved \(report.frameCount)")
        }
        lines.append("   PASS")
        return lines
    }

    // MARK: - ReplayBuffer.saveHighlight (recent tail)

    /// Feeds 90 solid frames whose gray level encodes the frame INDEX
    /// (`gray = 20 + index*2`) at 30 fps with a forced keyframe every 15 frames
    /// into a 2 s buffer (so the ring WRAPS and the oldest frames are evicted),
    /// then `saveHighlight(lastSeconds: 1.0)`. Reopens the clip, decodes the
    /// first and last frame's gray level back to an index, and asserts the saved
    /// window is the recent TAIL (indices ≈ 60…89), not the head. Also checks the
    /// clamp path (lastSeconds ≫ buffered → whole buffer) and the empty-buffer
    /// error.
    public static func runSaveHighlight() async throws -> [String] {
        var lines: [String] = []
        let w = 160, h = 120, fps = 30, total = 90, gop = 15, window = 2.0
        let base = 20, step = 2
        let encoder = ProgramEncoder(settings: .init(
            codec: .h264, width: w, height: h, averageBitrate: 4_000_000,
            keyframeInterval: 100.0, expectedFrameRate: Double(fps), lowLatencyRateControl: false))
        let replay = ReplayBuffer(seconds: window, fragmentInterval: 0.5)
        encoder.onEncodedFrame = { replay.append($0) }
        do { try encoder.start() } catch {
            throw SelfTestError.setupFailed("VT encoder start (hardware H.264 encode required): \(error)")
        }
        let pool: PixelBufferPool
        do { pool = try PixelBufferPool(width: w, height: h) }
        catch { throw SelfTestError.setupFailed("pixel pool: \(error)") }

        let src = SourceID("selftest.highlight")
        let frameDur = CMTime(value: 1, timescale: CMTimeScale(fps))
        for i in 0..<total {
            if i % gop == 0 { encoder.forceKeyframe() }
            let pts = CMTime(value: Int64(i), timescale: CMTimeScale(fps))
            let gray = UInt8(base + i * step)
            try encoder.encode(try fillSolid(pool: pool, gray: gray, pts: pts, duration: frameDur, source: src))
        }
        encoder.flush()
        encoder.stop() // drains delivery — all appends have landed

        let st = replay.status
        lines.append(String(format: "   fed %d frames (%ds worth @%dfps, window %.0fs) → ring holds %d frames / %d keyframes span=%.3fs (wrapped: oldest evicted)",
                            total, total / fps, fps, window, st.frameCount, st.keyframeCount, st.bufferedDuration.seconds))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism_highlight_selftest_\(UInt64.random(in: 0..<UInt64.max)).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try await replay.saveHighlight(lastSeconds: 1.0, to: url)
        lines.append("   saveHighlight(1.0s) → \(report)")

        // Independently reopen + decode indices from gray level.
        let indices = try await decodeIndices(url: url, base: base, step: step)
        guard let firstIdx = indices.first, let lastIdx = indices.last else {
            throw SelfTestError.assertion("no frames decoded from saved highlight")
        }
        let minIdx = indices.min() ?? -1, maxIdx = indices.max() ?? -1
        lines.append(String(format: "   decoded %d frames, recovered index range [%d…%d], first=%d last=%d",
                            indices.count, minIdx, maxIdx, firstIdx, lastIdx))

        // ~1 s at 30 fps = 30 frames (GOP-aligned start may add up to one GOP).
        guard (30...46).contains(report.frameCount) else {
            throw SelfTestError.assertion("highlight frameCount \(report.frameCount) not ≈ 30 (1s@30fps, +≤1 GOP)")
        }
        guard indices.count == report.frameCount else {
            throw SelfTestError.assertion("decoded \(indices.count) frames but report says \(report.frameCount)")
        }
        guard report.duration.seconds >= 0.95, report.duration.seconds <= 1.6 else {
            throw SelfTestError.assertion(String(format: "highlight duration %.3fs not ≈ 1.0s", report.duration.seconds))
        }
        // The TAIL proof: recovered indices are the most-recent ones. Index 89 is
        // newest; the ring head after wrap is ~15; index 0 is long gone.
        guard lastIdx >= 84 else { throw SelfTestError.assertion("last saved index \(lastIdx) is not the newest frame (~89) — did not save the tail") }
        guard minIdx >= 48 else { throw SelfTestError.assertion("min saved index \(minIdx) too low — saved head/evicted frames, not the recent tail") }
        // Order preserved (allow ±1 decode jitter on the ×2 luma step).
        for i in 1..<indices.count where indices[i] < indices[i - 1] - 1 {
            throw SelfTestError.assertion("saved frames out of order at \(i): \(indices[i]) < \(indices[i - 1])")
        }

        // Clamp: lastSeconds ≫ buffered → whole buffer, no error.
        let clampURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism_highlight_clamp_\(UInt64.random(in: 0..<UInt64.max)).mov")
        defer { try? FileManager.default.removeItem(at: clampURL) }
        let clamp = try await replay.saveHighlight(lastSeconds: 999.0, to: clampURL)
        lines.append("   saveHighlight(999s) clamps → \(clamp) (== whole ring \(st.frameCount) frames)")
        guard clamp.frameCount == st.frameCount else {
            throw SelfTestError.assertion("clamp saved \(clamp.frameCount) frames, expected whole ring \(st.frameCount)")
        }
        guard clamp.frameCount > report.frameCount else {
            throw SelfTestError.assertion("clamp did not save more than the 1s highlight")
        }

        // Empty-buffer error path (typed, no crash).
        let empty = ReplayBuffer(seconds: window)
        do {
            _ = try await empty.saveHighlight(lastSeconds: 1.0, to: url)
            throw SelfTestError.assertion("saveHighlight on empty buffer did not throw")
        } catch ReplayBuffer.ReplayError.empty {
            lines.append("   empty buffer → ReplayError.empty (typed, no crash) ✓")
        }
        lines.append("   PASS")
        return lines
    }

    /// Reopens a saved clip, decodes every frame to BGRA and recovers the
    /// frame index from its (solid) gray level: `index = round((gray−base)/step)`.
    static func decodeIndices(url: URL, base: Int, step: Int) async throws -> [Int] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw SelfTestError.assertion("saved clip has no video track")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        guard reader.canAdd(output) else { throw SelfTestError.assertion("cannot add decode output") }
        reader.add(output)
        guard reader.startReading() else {
            throw SelfTestError.assertion("reader failed to start: \(String(describing: reader.error))")
        }
        var indices: [Int] = []
        while let sb = output.copyNextSampleBuffer() {
            guard let img = CMSampleBufferGetImageBuffer(sb) else { continue }
            CVPixelBufferLockBaseAddress(img, .readOnly)
            let bpr = CVPixelBufferGetBytesPerRow(img)
            let hh = CVPixelBufferGetHeight(img), ww = CVPixelBufferGetWidth(img)
            let row = CVPixelBufferGetBaseAddress(img)!.advanced(by: (hh / 2) * bpr).assumingMemoryBound(to: UInt8.self)
            let x = ww / 2
            let avg = (Int(row[x * 4 + 0]) + Int(row[x * 4 + 1]) + Int(row[x * 4 + 2])) / 3
            CVPixelBufferUnlockBaseAddress(img, .readOnly)
            indices.append(Int((Double(avg - base) / Double(step)).rounded()))
        }
        guard reader.status == .completed else {
            throw SelfTestError.assertion("decode did not complete (status \(reader.status.rawValue))")
        }
        return indices
    }

    /// Test-only CPU solid-color fill: every pixel = `gray` (BGRA). Used so the
    /// decoded gray level uniquely identifies the source frame index.
    static func fillSolid(pool: PixelBufferPool, gray: UInt8, pts: CMTime,
                          duration: CMTime, source: SourceID) throws -> VideoFrame {
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let hh = CVPixelBufferGetHeight(buf), ww = CVPixelBufferGetWidth(buf)
        for y in 0..<hh {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
            for x in 0..<ww {
                row[x * 4 + 0] = gray; row[x * 4 + 1] = gray
                row[x * 4 + 2] = gray; row[x * 4 + 3] = 255
            }
        }
        return VideoFrame(pixelBuffer: buf, pts: pts, duration: duration, source: source)
    }

    // MARK: - ReplayBuffer with straddling audio (finding #3)

    /// Feeds 2 s of encoded video (window 5 s, so nothing is evicted → clip
    /// origin is the frame-0 keyframe at PTS 0) plus audio whose FIRST buffer
    /// **straddles** that origin (pts −0.1 s, end +0.4 s → pts < origin < end).
    /// Left untrimmed, `EncodedClipWriter.retime` subtracts the origin → a
    /// negative PTS → `AVAssetWriterInput.append` rejects it → `saveClip` throws
    /// (finding #3). Asserts `saveClip` SUCCEEDS and yields an audio track that
    /// begins at ~0 (the straddling buffer trimmed to the origin, not dropped).
    public static func runReplayBufferWithAudio() async throws -> [String] {
        var lines: [String] = []
        let w = 320, h = 240, fps = 30, seconds = 2, window = 5.0
        let encoder = ProgramEncoder(settings: .init(
            codec: .h264, width: w, height: h, averageBitrate: 2_000_000,
            keyframeInterval: 1.0, expectedFrameRate: Double(fps), lowLatencyRateControl: false))
        let replay = ReplayBuffer(seconds: window, fragmentInterval: 0.5)
        encoder.onEncodedFrame = { replay.append($0) }
        do { try encoder.start() } catch {
            throw SelfTestError.setupFailed("VT encoder start (hardware H.264 encode required): \(error)")
        }

        let pool: PixelBufferPool
        do { pool = try PixelBufferPool(width: w, height: h) }
        catch { throw SelfTestError.setupFailed("pixel pool: \(error)") }

        let total = seconds * fps
        let src = SourceID("selftest.replay.audio")
        for i in 0..<total {
            let pts = CMTime(value: Int64(i), timescale: CMTimeScale(fps))
            let frame = try fillFrame(pool: pool, gray: UInt8((i * 9) % 255), pts: pts,
                                      duration: CMTime(value: 1, timescale: CMTimeScale(fps)), source: src)
            try encoder.encode(frame)
        }
        encoder.flush()
        encoder.stop() // drains delivery — origin is now the frame-0 keyframe (PTS 0)

        // Audio on the SAME house timeline. First buffer starts at −0.1 s so it
        // straddles the origin (0 s); 0.5 s buffers thereafter up to the video end.
        let audioBufDur = 0.5
        var apts = CMTime(seconds: -0.1, preferredTimescale: 48_000)
        let audioEndExclusive = CMTime(seconds: Double(seconds), preferredTimescale: 48_000)
        var fedAudio = 0
        while CMTimeCompare(apts, audioEndExclusive) < 0 {
            guard let sb = Self.makeSilentAudio(pts: apts, seconds: audioBufDur) else {
                throw SelfTestError.setupFailed("audio sample synthesis failed")
            }
            replay.appendAudio(sb)
            fedAudio += 1
            apts = CMTimeAdd(apts, CMTime(seconds: audioBufDur, preferredTimescale: 48_000))
        }
        lines.append("   fed \(total) video frames + \(fedAudio) audio buffers (first straddles origin: pts=-0.100s)")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism_replay_audio_selftest_\(UInt64.random(in: 0..<UInt64.max)).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        // The fix under test: this must NOT throw on the negative-PTS straddler.
        let report = try await replay.saveClip(to: url)
        lines.append("   saveClip → \(report)")
        guard report.audioSampleCount > 0 else {
            throw SelfTestError.assertion("saved clip has no audio samples — the straddling buffer was dropped entirely (fix regressed)")
        }

        let asset = AVURLAsset(url: url)
        let vtracks = try await asset.loadTracks(withMediaType: .video)
        let atracks = try await asset.loadTracks(withMediaType: .audio)
        lines.append("   reopened: videoTracks=\(vtracks.count) audioTracks=\(atracks.count)")
        guard vtracks.count == 1 else { throw SelfTestError.assertion("expected 1 video track, got \(vtracks.count)") }
        guard atracks.count == 1 else { throw SelfTestError.assertion("expected 1 audio track (with-sound replay), got \(atracks.count)") }
        guard let atrack = atracks.first else { throw SelfTestError.assertion("no audio track to read") }
        let range = try await atrack.load(.timeRange)
        let startS = range.start.seconds
        lines.append(String(format: "   audio track timeRange start=%.4fs duration=%.3fs (trimmed straddler → starts at ~0)", startS, range.duration.seconds))
        guard startS >= -0.0005, startS < 0.5 else {
            throw SelfTestError.assertion(String(format: "audio track starts at %.4fs — expected ~0 (straddler trimmed to origin, not negative/dropped)", startS))
        }
        lines.append("   PASS")
        return lines
    }

    /// Silent interleaved mono Float32 LPCM `CMSampleBuffer` with a real
    /// (zero-filled) data block — appendable to a passthrough `AVAssetWriterInput`.
    private static func makeSilentAudio(pts: CMTime, seconds: Double, sampleRate: Double = 48_000) -> CMSampleBuffer? {
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

    // MARK: - ISORecorderBank

    /// Two-source bank: verifies pending/active source lists, live per-source
    /// status mid-recording, and time-aligned finish (both files ≈ equal
    /// duration, sharing one house-time zero).
    public static func runISO() async throws -> [String] {
        var lines: [String] = []
        let w = 320, h = 240, fps = 30
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism_iso_selftest_\(UInt64.random(in: 0..<UInt64.max))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let settings = RecordingSettings(codec: .h264, width: w, height: h, videoBitrate: 2_000_000,
                                         expectedFrameRate: Double(fps), fragmentInterval: 0.5, includeAudio: false)
        let bank = ISORecorderBank(directory: dir, defaultSettings: settings)
        let a = SourceID("iso.A"), b = SourceID("iso.B"), c = SourceID("iso.C")

        try bank.addSource(a)
        try bank.addSource(b)
        try bank.addSource(c)
        try bank.removeSource(c) // per-source disable before start
        let pending = bank.pendingSourceIDs.map { $0.raw }.sorted()
        lines.append("   pending after arm A,B,C then removeSource(C): \(pending)")
        guard pending == ["iso.A", "iso.B"] else { throw SelfTestError.assertion("pending list wrong: \(pending)") }

        let t0 = HouseClock.now()
        do { try bank.start(at: t0) } catch {
            throw SelfTestError.setupFailed("ISO bank start (hardware H.264 encode via AVAssetWriter): \(error)")
        }
        let active = bank.activeSourceIDs.map { $0.raw }.sorted()
        lines.append("   active after start: \(active) sharedZero=\(String(format: "%.3f", (bank.startTime ?? .zero).seconds))s")
        guard active == ["iso.A", "iso.B"] else { throw SelfTestError.assertion("active list wrong: \(active)") }

        let pool = try PixelBufferPool(width: w, height: h)
        let frames = 60
        let frameDur = CMTime(value: 1, timescale: CMTimeScale(fps))
        for i in 0..<frames {
            let pts = CMTimeAdd(t0, CMTime(value: Int64(i + 1), timescale: CMTimeScale(fps)))
            let phase = UInt8((i * 7) % 255)
            bank.append(try fillFrame(pool: pool, gray: phase, pts: pts, duration: frameDur, source: a))
            bank.append(try fillFrame(pool: pool, gray: 255 &- phase, pts: pts, duration: frameDur, source: b))
            if i == frames / 2 {
                // Live status mid-recording.
                let sa = bank.status(for: a)
                let sb = bank.status(for: b)
                lines.append("   mid status A: state=\(sa?.state.rawValue ?? "nil") frames=\(sa?.videoFramesWritten ?? 0) dropped=\(sa?.videoFramesDropped ?? 0) bytes=\(sa?.bytesWritten ?? 0)")
                lines.append("   mid status B: state=\(sb?.state.rawValue ?? "nil") frames=\(sb?.videoFramesWritten ?? 0) dropped=\(sb?.videoFramesDropped ?? 0) bytes=\(sb?.bytesWritten ?? 0)")
                guard sa?.state == .recording, sb?.state == .recording else {
                    throw SelfTestError.assertion("mid-recording status not .recording")
                }
            }
            try await Task.sleep(nanoseconds: UInt64(1_000_000_000 / UInt64(fps)))
        }

        let results = await bank.finishAll()
        var durs: [String: Double] = [:]
        for id in [a, b] {
            switch results[id] {
            case .success(let rep):
                durs[id.raw] = rep.duration.seconds
                // Reopen for independent duration.
                let asset = AVURLAsset(url: rep.url)
                let reopened = try await asset.load(.duration).seconds
                lines.append(String(format: "   %@: report=%.3fs reopened=%.3fs frames=%d dropped=%d bytes=%d",
                                    id.raw, rep.duration.seconds, reopened, rep.videoFramesWritten, rep.videoFramesDropped, rep.bytesWritten))
            case .failure(let e):
                throw SelfTestError.assertion("source \(id.raw) finish failed: \(e)")
            case .none:
                throw SelfTestError.assertion("no result for source \(id.raw)")
            }
        }
        guard let da = durs["iso.A"], let db = durs["iso.B"] else {
            throw SelfTestError.assertion("missing durations")
        }
        let skew = abs(da - db)
        lines.append(String(format: "   aligned finish: |durA−durB|=%.4fs (shared house-time zero)", skew))
        guard skew < 0.2 else { throw SelfTestError.assertion(String(format: "ISO files not aligned: skew %.4fs", skew)) }
        guard da > 0.5, db > 0.5 else { throw SelfTestError.assertion("ISO durations implausibly short") }
        lines.append("   PASS")
        return lines
    }

    // MARK: - test-only CPU frame fill

    private static func fillFrame(pool: PixelBufferPool, gray: UInt8, pts: CMTime,
                                  duration: CMTime, source: SourceID) throws -> VideoFrame {
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let hh = CVPixelBufferGetHeight(buf), ww = CVPixelBufferGetWidth(buf)
        for y in 0..<hh {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
            // A moving diagonal + varying gray so successive frames differ
            // (real P-frames, real keyframes at the interval).
            let bias = UInt8((y &+ Int(gray)) & 0xFF)
            for x in 0..<ww {
                let v = gray &+ UInt8((x &+ Int(bias)) & 0x3F)
                row[x * 4 + 0] = v; row[x * 4 + 1] = bias
                row[x * 4 + 2] = gray; row[x * 4 + 3] = 255
            }
        }
        return VideoFrame(pixelBuffer: buf, pts: pts, duration: duration, source: source)
    }
}
