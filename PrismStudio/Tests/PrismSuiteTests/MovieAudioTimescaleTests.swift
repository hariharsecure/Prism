import AVFoundation
import CoreMedia
import Foundation
import XCTest

import PrismCore
@testable import PrismOutput
@testable import PrismSources

/// Reproduce-first + fix proof for the mixed-timescale movie-audio timing defect.
///
/// `MovieSource.retimed` re-stamps every decoded audio buffer to house time. The
/// PTS (`target`) is house time — the host clock, whose timescale is ≈ 1e9 — but
/// the file's native audio `duration` is in the sample-rate timescale (48 000), so
/// pre-fix the emitted `AudioPacket` carried PTS and duration in DIFFERENT
/// timescales. That packet is fed RAW (bypassing the resampling `AudioMixer`) into
/// the multitrack recorder the app's `multitrackTap` installs:
/// `AudioTrackRecorderBank` → `AudioTrackRecorder` (the audio analogue of
/// `ISORecorderBank`; movie-source audio flows through THIS bank, not the video
/// `ISORecorderBank`, per `AppEngine.registerMovie`).
///
/// FINDING (see the report): the real `AudioTrackRecorder`/AVAssetWriter path
/// TOLERATES the incoherence — `AVAssetWriter` re-derives the muxed audio track's
/// timing from the LPCM format + sample count, so the finalized .mov decodes to a
/// correct ≈10 s / all-samples-readable track for BOTH mixed and coherent input.
/// So the corruption is **LATENT** on the real production sink, not live. The fix
/// still belongs in `MovieSource`: the `AudioPacket = house-time` contract requires
/// a coherent timing entry, and any less-tolerant raw consumer (or a downstream
/// metric that reads the buffer's own duration field) would mis-time the audio.
///
/// These tests: (1) drive the ACTUAL `AudioTrackRecorderBank` with the exact
/// mixed-timescale packet `retimed` produced pre-fix and document that the muxed
/// file is tolerated (latent); (2) prove the post-fix coherent packet muxes a
/// correct, fully-readable track through the same real path; (3) unit-test the
/// exact timing helper `retimed` uses for coherence + value preservation.
final class MovieAudioTimescaleTests: XCTestCase {

    private static let sampleRate = 48_000.0
    private static let framesPerPacket = 1024
    private static let totalFrames = 480_000        // 10 s @ 48 kHz
    private static let toneHz = 440.0

    // MARK: - STEP 1: reproduce against the real recorder path (latency characterization)

    /// The pre-fix MIXED-timescale packet is genuinely incoherent (PTS.timescale ≠
    /// duration.timescale) — the defect — yet driven through the REAL
    /// `AudioTrackRecorderBank` the finalized .mov still decodes to a correct ≈10 s,
    /// fully-readable track: the production sink TOLERATES it, so the bug is LATENT.
    /// (Negative control at the packet-timing level; documents the real-path result.)
    func testMixedTimescalePacketIsIncoherentButRealRecorderTolerates() async throws {
        // (a) the defect: the exact packet MovieSource.retimed emitted pre-fix mixes
        //     the host-clock PTS timescale with the 48 kHz duration timescale.
        let target = CMTimeAdd(HouseClock.now(),
                               CMTime(value: 0, timescale: CMTimeScale(Self.sampleRate)))
        let nativeDur = CMTime(value: Int64(Self.framesPerPacket), timescale: CMTimeScale(Self.sampleRate))
        XCTAssertNotEqual(target.timescale, nativeDur.timescale,
            "precondition: the pre-fix packet must mix timescales (the defect under test)")

        // (b) the real-path outcome: tolerated → correct file (latent).
        let stats = try await recordTone(coherent: false)
        print("""
        ── mixed-timescale (PRE-FIX) real AudioTrackRecorder output ──
           report.duration = \(String(format: "%.3f", stats.reportSeconds)) s   ← unreliable metric (host-clock rounding; same post-fix)
           decoded FILE span = \(String(format: "%.3f", stats.decodedSpanSeconds)) s   ← AVAssetWriter re-derives → correct
           re-readable samples = \(stats.sampleCount) (\(String(format: "%.3f", stats.contentSeconds)) s content, expected ≈\(Self.totalFrames))
           buffers written/dropped = \(stats.buffersWritten)/\(stats.buffersDropped)
        """)
        let expected = Double(Self.totalFrames) / Self.sampleRate   // 10 s
        XCTAssertEqual(stats.decodedSpanSeconds, expected, accuracy: 0.25,
            "real recorder tolerates the incoherence: decoded FILE span should still be ≈\(expected)s (LATENT), got \(stats.decodedSpanSeconds)s")
        XCTAssertEqual(stats.contentSeconds, expected, accuracy: 0.25,
            "real recorder tolerates the incoherence: all samples should still be readable (LATENT), got \(stats.sampleCount)")
    }

    // MARK: - STEP 3: the fix keeps the real path correct + fully readable

    /// COHERENT timescale (post-fix `retimed`/`houseAudioTiming` output) → the
    /// finalized .mov audio track has ≈10 s duration and every sample re-readable,
    /// with the 440 Hz tone intact — the fix keeps the real production path correct.
    func testCoherentTimescaleAudioRecordsCorrectly() async throws {
        let stats = try await recordTone(coherent: true)
        print("""
        ── coherent (POST-FIX) real AudioTrackRecorder output ──
           report.duration = \(String(format: "%.3f", stats.reportSeconds)) s
           decoded FILE span = \(String(format: "%.3f", stats.decodedSpanSeconds)) s
           re-readable samples = \(stats.sampleCount) (\(String(format: "%.3f", stats.contentSeconds)) s content)
           dominant = \(String(format: "%.1f", stats.dominantHz)) Hz  rms = \(String(format: "%.3f", stats.rms))
           buffers written/dropped = \(stats.buffersWritten)/\(stats.buffersDropped)
        """)
        let expected = Double(Self.totalFrames) / Self.sampleRate   // 10 s
        XCTAssertEqual(stats.decodedSpanSeconds, expected, accuracy: 0.25,
            "post-fix decoded FILE span \(stats.decodedSpanSeconds)s should be ≈\(expected)s")
        XCTAssertEqual(stats.contentSeconds, expected, accuracy: 0.25,
            "post-fix should retain ≈all \(Self.totalFrames) samples, got \(stats.sampleCount)")
        XCTAssertGreaterThan(stats.rms, 0.05, "post-fix audio is silent (rms=\(stats.rms))")
        XCTAssertEqual(stats.dominantHz, Self.toneHz, accuracy: 25,
            "post-fix dominant tone \(stats.dominantHz)Hz, expected ≈\(Self.toneHz)Hz")
    }

    // MARK: - STEP 3: MovieSource-level unit test (timing coherence + value preserved)

    /// `houseAudioTiming` — the exact helper `MovieSource.retimed` uses — must emit
    /// a timing entry whose PTS and duration share ONE timescale, with the duration
    /// still representing the same wall-clock length (accuracy preserved).
    func testHouseAudioTimingIsCoherentAndPreservesValue() {
        // target: house time (host clock, ≈1e9 timescale). A file's native audio
        // duration: the sample-rate timescale (48 000). Pre-fix these differed.
        let target = CMTimeAdd(HouseClock.now(),
                               CMTime(value: 512, timescale: CMTimeScale(Self.sampleRate)))
        let nativeDuration = CMTime(value: Int64(Self.framesPerPacket),
                                    timescale: CMTimeScale(Self.sampleRate)) // 1024/48000 s

        let timing = MovieSource.houseAudioTiming(target: target, duration: nativeDuration)

        // (a) PTS unchanged (house-time contract preserved).
        XCTAssertEqual(CMTimeCompare(timing.presentationTimeStamp, target), 0,
            "PTS must remain the house-time target")
        // (b) coherent: duration shares the PTS timescale.
        XCTAssertEqual(timing.duration.timescale, timing.presentationTimeStamp.timescale,
            "duration timescale (\(timing.duration.timescale)) must match PTS timescale (\(timing.presentationTimeStamp.timescale))")
        // (c) value preserved: same wall-clock length to sub-microsecond.
        XCTAssertEqual(timing.duration.seconds, nativeDuration.seconds, accuracy: 1e-6,
            "duration wall-clock length must be preserved")
    }

    // MARK: - Drive the real AudioTrackRecorderBank end to end

    private struct DecodedAudio {
        let reportSeconds: Double       // AudioTrackRecorder.Report.duration
        let decodedSpanSeconds: Double  // container PTS span (last end − first pts)
        let contentSeconds: Double      // sampleCount / sampleRate
        let sampleCount: Int
        let rms: Double
        let dominantHz: Double
        let buffersWritten: UInt64
        let buffersDropped: UInt64
    }

    /// Feeds a 10 s 440 Hz tone, chunked exactly as `MovieSource` emits it, into a
    /// live `AudioTrackRecorderBank`, finalizes, then decodes the resulting .mov.
    /// `coherent == false` reproduces the pre-fix mixed timescale; `true` uses the
    /// fixed `MovieSource.houseAudioTiming`.
    private func recordTone(coherent: Bool) async throws -> DecodedAudio {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-audiotimescale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = SourceID("movie-clip")
        // Mirror production: the house-time anchor for the movie source's first
        // packet, shared with the bank's session start (multitrack start(at:)).
        let houseZero = HouseClock.now()

        // Uncompressed Float32 LPCM: no AAC encoder queue, so `append` isn't dropped
        // for encoder backpressure — the muxed timeline reflects the timing we feed,
        // not a test-harness overrun. (The bug is timescale coherence, not codec.)
        let settings = AudioTrackSettings(format: .pcmFloat32)
        let bank = AudioTrackRecorderBank(directory: dir, defaultSettings: settings)
        try bank.addSource(source)
        try bank.start(at: houseZero)

        var frameIndex = 0
        var expectedWritten: UInt64 = 0
        while frameIndex < Self.totalFrames {
            let n = min(Self.framesPerPacket, Self.totalFrames - frameIndex)
            let offset = CMTime(value: Int64(frameIndex), timescale: CMTimeScale(Self.sampleRate))
            let target = CMTimeAdd(houseZero, offset)                       // house-time PTS (≈1e9 ts)
            let nativeDur = CMTime(value: Int64(n), timescale: CMTimeScale(Self.sampleRate)) // ts 48 000
            let timing: CMSampleTimingInfo = coherent
                ? MovieSource.houseAudioTiming(target: target, duration: nativeDur)   // FIXED path
                : CMSampleTimingInfo(duration: nativeDur,                              // PRE-FIX mixed
                                     presentationTimeStamp: target, decodeTimeStamp: .invalid)
            guard let buffer = Self.makeTone(frames: n, startFrame: frameIndex, timing: timing) else {
                XCTFail("failed to build tone buffer at frame \(frameIndex)")
                throw NSError(domain: "MovieAudioTimescaleTests", code: 1)
            }
            // Retry the SAME buffer until it is accepted, so a transient
            // !isReadyForMoreMediaData never silently drops a packet (which would
            // confound the timeline measurement with harness overrun rather than the
            // timescale bug). A genuine drop leaves lastPTS unchanged, so re-appending
            // the same (still-monotonic) PTS is safe.
            expectedWritten += 1
            var attempts = 0
            while (bank.status(for: source)?.buffersWritten ?? 0) < expectedWritten {
                bank.append(AudioPacket(sampleBuffer: buffer, source: source))
                if (bank.status(for: source)?.buffersWritten ?? 0) >= expectedWritten { break }
                attempts += 1
                if attempts > 400 { break }
                usleep(500)
            }
            frameIndex += n
        }

        let results = await bank.finishAll()
        guard case .success(let report)? = results[source] else {
            throw NSError(domain: "MovieAudioTimescaleTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "recorder did not finish: \(String(describing: results[source]))"])
        }
        let decoded = try await Self.decodeAudio(url: report.url)
        return DecodedAudio(reportSeconds: report.duration.seconds,
                            decodedSpanSeconds: decoded.spanSeconds,
                            contentSeconds: Double(decoded.sampleCount) / Self.sampleRate,
                            sampleCount: decoded.sampleCount, rms: decoded.rms,
                            dominantHz: decoded.dominantHz,
                            buffersWritten: report.buffersWritten, buffersDropped: report.buffersDropped)
    }

    // MARK: - Tone buffer (mono Float32 LPCM, the movie-reader format) + decode

    /// A mono Float32 LPCM buffer of a 440 Hz sine, `frames` long, with the exact
    /// single-entry `timing` that `MovieSource.retimed` stamps.
    private static func makeTone(frames: Int, startFrame: Int, timing: CMSampleTimingInfo) -> CMSampleBuffer? {
        let bytesPerFrame = 4
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame), mChannelsPerFrame: 1,
            mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format) == noErr, let format else { return nil }

        var samples = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let t = Double(startFrame + i) / sampleRate
            samples[i] = Float(0.5 * sin(2.0 * Double.pi * toneHz * t))
        }
        let dataSize = frames * bytesPerFrame
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: dataSize,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer) == noErr,
            let blockBuffer else { return nil }
        let ok = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: dataSize) == noErr
        }
        guard ok else { return nil }

        var t = timing
        var sampleSize = bytesPerFrame
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &t,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sb) == noErr,
            let sb else { return nil }
        return sb
    }

    private struct AudioDecode { let spanSeconds: Double; let sampleCount: Int; let rms: Double; let dominantHz: Double }

    private static func decodeAudio(url: URL) async throws -> AudioDecode {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { return AudioDecode(spanSeconds: 0, sampleCount: 0, rms: 0, dominantHz: 0) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { return AudioDecode(spanSeconds: 0, sampleCount: 0, rms: 0, dominantHz: 0) }
        reader.add(output)
        guard reader.startReading() else { return AudioDecode(spanSeconds: 0, sampleCount: 0, rms: 0, dominantHz: 0) }

        var samples: [Float] = []
        var firstPTS = CMTime.invalid, lastEnd = CMTime.zero
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if firstPTS == .invalid { firstPTS = pts }
            let dur = CMSampleBufferGetDuration(sample)
            lastEnd = dur.isNumeric ? CMTimeAdd(pts, dur) : pts
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let n = CMBlockBufferGetDataLength(block)
            guard n >= MemoryLayout<Float>.size else { continue }
            var bytes = [UInt8](repeating: 0, count: n)
            _ = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n, destination: $0.baseAddress!)
            }
            bytes.withUnsafeBytes { samples.append(contentsOf: $0.bindMemory(to: Float.self)) }
        }
        let span = firstPTS == .invalid ? 0 : CMTimeSubtract(lastEnd, firstPTS).seconds
        guard !samples.isEmpty else { return AudioDecode(spanSeconds: span, sampleCount: 0, rms: 0, dominantHz: 0) }
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        var crossings = 0
        for i in 1..<samples.count where (samples[i - 1] < 0) != (samples[i] < 0) { crossings += 1 }
        let seconds = Double(samples.count) / sampleRate
        let dominantHz = seconds > 0 ? Double(crossings) / (2.0 * seconds) : 0
        return AudioDecode(spanSeconds: span, sampleCount: samples.count, rms: rms, dominantHz: dominantHz)
    }
}
