import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import PrismCore

/// Headless verification of multitrack audio recording (`AudioTrackRecorder` /
/// `AudioTrackRecorderBank`) and replay-buffer audio retention. AAC/PCM encode
/// via AVAssetWriter and VideoToolbox H.264 encode need no TCC permission.
///
/// TEST CODE ONLY synthesizes PCM (CPU) and pixel buffers — allowed here,
/// forbidden on the engine hot path.
public enum MultitrackAudioSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case setupFailed(String)
        case assertion(String)
        public var description: String {
            switch self {
            case .setupFailed(let s): return "multitrack self-test setup failed: \(s)"
            case .assertion(let s): return "multitrack self-test assertion failed: \(s)"
            }
        }
    }

    public static func run() async throws -> [String] {
        var lines: [String] = []
        lines.append("── AudioTrackRecorderBank (multitrack)")
        lines += try await runMultitrack()
        lines.append("── ReplayBuffer (audio)")
        lines += try await runReplayAudio()
        return lines
    }

    // MARK: - Multitrack

    /// Two audio sources + the master mix → three per-track recorders sharing
    /// one house-time zero. Finish, reopen each file (AVURLAsset) and assert
    /// every file has exactly one audio track of ≈ equal duration (aligned).
    static func runMultitrack() async throws -> [String] {
        var lines: [String] = []
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism_multitrack_selftest_\(UInt64.random(in: 0..<UInt64.max))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sr = 48_000.0, channels = 2
        let settings = AudioTrackSettings(format: .aac(bitrate: 160_000), sampleRate: sr,
                                          channels: channels, fragmentInterval: 0.5)
        let bank = AudioTrackRecorderBank(directory: dir, defaultSettings: settings)
        let srcA = SourceID("mic.A"), srcB = SourceID("mic.B"), master = SourceID("mixer.master")
        try bank.addSource(srcA)
        try bank.addSource(srcB)
        try bank.addSource(master)

        let t0 = CMTime(value: 0, timescale: CMTimeScale(sr)) // shared zero (house time in production)
        do { try bank.start(at: t0) } catch {
            throw SelfTestError.setupFailed("audio bank start (AAC encode): \(error)")
        }
        let active = bank.activeSourceIDs.map { $0.raw }.sorted()
        lines.append("   active tracks: \(active) sharedZero=\(String(format: "%.3f", (bank.startTime ?? .zero).seconds))s")
        guard active == ["mic.A", "mic.B", "mixer.master"] else {
            throw SelfTestError.assertion("active track list wrong: \(active)")
        }

        // Feed ~0.5 s of tone to each in ~10 ms buffers, PTS from the shared zero.
        let blockFrames = 480 // 10 ms @ 48 k
        let blocks = 50
        var phA = 0.0, phB = 0.0, phM = 0.0
        for i in 0..<blocks {
            let pts = CMTimeAdd(t0, CMTime(value: Int64(i * blockFrames), timescale: CMTimeScale(sr)))
            bank.append(try makePCM(frames: blockFrames, sr: sr, channels: channels,
                                    freq: 220, amp: 0.6, phase: &phA, pts: pts), source: srcA)
            bank.append(try makePCM(frames: blockFrames, sr: sr, channels: channels,
                                    freq: 440, amp: 0.6, phase: &phB, pts: pts), source: srcB)
            bank.append(try makePCM(frames: blockFrames, sr: sr, channels: channels,
                                    freq: 660, amp: 0.5, phase: &phM, pts: pts), source: master)
        }
        let mid = bank.status(for: srcA)
        lines.append("   mid status mic.A: state=\(mid?.state.rawValue ?? "nil") buffers=\(mid?.buffersWritten ?? 0) dropped=\(mid?.buffersDropped ?? 0)")

        let results = await bank.finishAll()
        var durations: [String: Double] = [:]
        for id in [srcA, srcB, master] {
            switch results[id] {
            case .success(let rep):
                let asset = AVURLAsset(url: rep.url)
                let reopened = try await asset.load(.duration).seconds
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                durations[id.raw] = reopened
                lines.append(String(format: "   %@: report=%.3fs reopened=%.3fs audioTracks=%d videoTracks=%d written=%d bytes=%d",
                                    id.raw, rep.duration.seconds, reopened, audioTracks.count,
                                    videoTracks.count, rep.buffersWritten, rep.bytesWritten))
                guard audioTracks.count == 1 else {
                    throw SelfTestError.assertion("\(id.raw): expected 1 audio track, got \(audioTracks.count)")
                }
                guard videoTracks.isEmpty else {
                    throw SelfTestError.assertion("\(id.raw): audio-only file has \(videoTracks.count) video tracks")
                }
                guard rep.buffersWritten >= UInt64(blocks - 2) else {
                    throw SelfTestError.assertion("\(id.raw): only \(rep.buffersWritten)/\(blocks) buffers written")
                }
            case .failure(let e): throw SelfTestError.assertion("source \(id.raw) finish failed: \(e)")
            case .none: throw SelfTestError.assertion("no result for source \(id.raw)")
            }
        }
        let ds = durations.values.sorted()
        let skew = (ds.last ?? 0) - (ds.first ?? 0)
        lines.append(String(format: "   aligned finish: max|Δdur|=%.4fs across %d tracks", skew, durations.count))
        guard skew < 0.1 else { throw SelfTestError.assertion(String(format: "tracks not aligned: skew %.4fs", skew)) }
        guard (ds.first ?? 0) > 0.3 else { throw SelfTestError.assertion("track durations implausibly short") }
        lines.append("   PASS")
        return lines
    }

    // MARK: - Replay audio

    /// Feeds video (H.264) + PCM audio into a ReplayBuffer, saves a clip, then
    /// reopens it and asserts BOTH a video and an audio track covering the
    /// window.
    static func runReplayAudio() async throws -> [String] {
        var lines: [String] = []
        let w = 320, h = 240, fps = 30, seconds = 8
        let window = 4.0, sr = 48_000.0, channels = 2
        let encoder = ProgramEncoder(settings: .init(
            codec: .h264, width: w, height: h, averageBitrate: 2_000_000,
            keyframeInterval: 1.0, expectedFrameRate: Double(fps), lowLatencyRateControl: false))
        let replay = ReplayBuffer(seconds: window, fragmentInterval: 0.5)
        encoder.onEncodedFrame = { replay.append($0) }
        do { try encoder.start() } catch {
            throw SelfTestError.setupFailed("VT encoder start: \(error)")
        }
        let pool: PixelBufferPool
        do { pool = try PixelBufferPool(width: w, height: h) }
        catch { throw SelfTestError.setupFailed("pixel pool: \(error)") }

        let src = SourceID("selftest.replayav")
        let total = seconds * fps
        // Audio in ~21.3 ms blocks (1024 frames) spanning the same wall window.
        let audioBlock = 1024
        var audioPhase = 0.0
        var audioPTS = CMTime.zero
        let audioEnd = CMTime(value: Int64(seconds), timescale: 1)
        for i in 0..<total {
            let vpts = CMTime(value: Int64(i), timescale: CMTimeScale(fps))
            let frame = try fillFrame(pool: pool, gray: UInt8((i * 9) % 255), pts: vpts,
                                      duration: CMTime(value: 1, timescale: CMTimeScale(fps)), source: src)
            try encoder.encode(frame)
            // Interleave audio blocks so audio PTS tracks video wall time.
            while CMTimeCompare(audioPTS, CMTimeAdd(vpts, CMTime(value: 1, timescale: CMTimeScale(fps)))) < 0,
                  CMTimeCompare(audioPTS, audioEnd) < 0 {
                replay.appendAudio(try makePCM(frames: audioBlock, sr: sr, channels: channels,
                                               freq: 440, amp: 0.6, phase: &audioPhase, pts: audioPTS))
                audioPTS = CMTimeAdd(audioPTS, CMTime(value: Int64(audioBlock), timescale: CMTimeScale(sr)))
            }
        }
        encoder.flush()
        encoder.stop()

        let st = replay.status
        lines.append(String(format: "   fed %d video frames + audio → buffer holds %d frames / %d keyframes, span=%.3fs",
                            total, st.frameCount, st.keyframeCount, st.bufferedDuration.seconds))
        guard st.frameCount > 0 else { throw SelfTestError.assertion("video buffer empty") }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism_replayav_selftest_\(UInt64.random(in: 0..<UInt64.max)).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try await replay.saveClip(to: url)
        lines.append("   saveClip → \(report)")
        guard report.audioSampleCount > 0 else {
            throw SelfTestError.assertion("clip saved with no audio samples (audio ring not retained)")
        }

        let asset = AVURLAsset(url: url)
        let dur = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var audioDur = 0.0
        if let at = audioTracks.first {
            audioDur = try await at.load(.timeRange).duration.seconds
        }
        lines.append(String(format: "   reopened: duration=%.3fs videoTracks=%d audioTracks=%d audioTrackDur=%.3fs",
                            dur, videoTracks.count, audioTracks.count, audioDur))
        guard videoTracks.count == 1 else { throw SelfTestError.assertion("expected 1 video track, got \(videoTracks.count)") }
        guard audioTracks.count == 1 else { throw SelfTestError.assertion("expected 1 audio track, got \(audioTracks.count)") }
        guard dur >= window - 0.3 else {
            throw SelfTestError.assertion(String(format: "clip duration %.3fs < window %.1fs", dur, window))
        }
        guard audioDur >= window - 0.5 else {
            throw SelfTestError.assertion(String(format: "audio track %.3fs does not cover window %.1fs", audioDur, window))
        }
        lines.append("   PASS")
        return lines
    }

    // MARK: - test-only synthesizers

    /// Interleaved Float32 LPCM sine → CMSampleBuffer (phase kept across calls).
    static func makePCM(frames: Int, sr: Double, channels: Int, freq: Double, amp: Double,
                        phase: inout Double, pts: CMTime) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sr, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        var fd: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        guard status == noErr, let fd else {
            throw SelfTestError.setupFailed("CMAudioFormatDescriptionCreate \(status)")
        }

        let step = 2.0 * .pi * freq / sr
        var samples = [Float](repeating: 0, count: frames * channels)
        for f in 0..<frames {
            let v = Float(sin(phase) * amp)
            for c in 0..<channels { samples[f * channels + c] = v }
            phase += step
            if phase > 2.0 * .pi { phase -= 2.0 * .pi }
        }

        let byteCount = frames * channels * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else {
            throw SelfTestError.setupFailed("CMBlockBufferCreateWithMemoryBlock \(status)")
        }
        status = samples.withUnsafeBufferPointer {
            CMBlockBufferReplaceDataBytes(with: UnsafeRawPointer($0.baseAddress!), blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == kCMBlockBufferNoErr else {
            throw SelfTestError.setupFailed("CMBlockBufferReplaceDataBytes \(status)")
        }
        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fd,
            sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else {
            throw SelfTestError.setupFailed("CMAudioSampleBufferCreateReady \(status)")
        }
        return sampleBuffer
    }

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
