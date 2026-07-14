import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os
import PrismCore

/// Headless lifecycle / timing / edge-case verification of `MovieSource` — the
/// bugs the happy-path self-test is blind to (MOVIESOURCE_FIX_LEDGER M1–M10).
///
/// Every check is deterministic and network-/hardware-free: it synthesizes its
/// own tiny fixtures (A/V clip, audio-only clip, rotated clip, truncated/corrupt
/// clip). Lives in the source module so it can drive `MovieSource`'s `internal`
/// diagnostics + test hooks without widening the public API.
public enum MovieSourceLifecycleTests {
    public enum Failure: Error, CustomStringConvertible {
        case setup(String)
        case assertion(String)
        public var description: String {
            switch self {
            case .setup(let s): return "movie lifecycle setup failed: \(s)"
            case .assertion(let s): return "movie lifecycle assertion failed: \(s)"
            }
        }
    }

    public static func run() throws {
        try testAudioHouseTimePTS()          // M1
        try testAVStartSkew()                // M2
        try testStopFromCallbackNoDeadlock() // M3
        try testCorruptFileNoBusySpin()      // M4
        try testEOFTerminalStateRestart()    // M5
        try testConcurrentStartStopStress()  // M6
        try testAudioOnlyTypedError()        // M7
        try testLateDecodeNoCatchUpBurst()   // M9
        try testRotatedNativeSize()          // M10
        print("MovieSourceLifecycleTests: all checks passed")
    }

    // MARK: - Helpers

    private static func tempURL(_ ext: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_movie_lifecycle_\(UUID().uuidString).\(ext)")
    }

    @discardableResult
    private static func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline { return predicate() }
            usleep(5_000)
        }
        return true
    }

    private static func assert(_ cond: Bool, _ msg: @autoclosure () -> String) throws {
        if !cond { throw Failure.assertion(msg()) }
    }

    // Thread-safe capture of (pts, wall-now) pairs for audio/video callbacks.
    private final class Stamps: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: [(pts: CMTime, now: CMTime)]())
        func add(_ pts: CMTime, _ now: CMTime) { lock.withLock { $0.append((pts, now)) } }
        var all: [(pts: CMTime, now: CMTime)] { lock.withLock { $0 } }
        var count: Int { lock.withLock { $0.count } }
    }

    // MARK: - M1: audio packets carry HOUSE time, monotonic across a loop seam

    private static func testAudioHouseTimePTS() throws {
        let url = tempURL("mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeClip(to: url, videoFrames: 24, size: CGSize(width: 160, height: 120),
                      fps: 24, transform: .identity, audioSeconds: 0.5)

        let src = try MovieSource(id: SourceID("lifecycle.m1"), fileURL: url, loop: true)
        try assert(src.hasAudioTrack, "M1: fixture has no audio track")
        let stamps = Stamps()
        src.onAudio = { pkt in stamps.add(pkt.pts, HouseClock.now()) }
        try src.start()
        defer { src.stop() }

        // Collect > 0.5 s of audio so we cross at least one loop seam.
        _ = waitUntil(timeout: 6.0) { stamps.count >= 12 }
        src.stop()
        let all = stamps.all
        try assert(all.count >= 6, "M1: only \(all.count) audio packets emitted")

        // (a) Each packet's PTS ≈ house time at the callback (was asset-relative,
        // starting ~0 → off by ~boot-seconds from the house clock).
        var maxSkewMs = 0.0
        for s in all {
            let skewMs = abs(CMTimeSubtract(s.pts, s.now).seconds) * 1000.0
            maxSkewMs = max(maxSkewMs, skewMs)
        }
        try assert(maxSkewMs < 250, "M1: audio PTS not house time (max |pts-now| = \(Int(maxSkewMs))ms)")

        // (b) Strictly increasing across the loop seam (asset PTS reset to ~0 each
        // loop → would go BACKWARDS; house-time retiming must not).
        var prev = CMTime.negativeInfinity
        for s in all {
            try assert(CMTimeCompare(s.pts, prev) > 0,
                       "M1: audio PTS not strictly increasing across loop seam (\(s.pts.seconds) after \(prev.seconds))")
            prev = s.pts
        }
        print(String(format: "  ✓ M1 audio house-time: %d packets, max|pts-now|=%.0fms, monotonic across loop seam",
                     all.count, maxSkewMs))
    }

    // MARK: - M2: single source, video/audio start A/V-aligned

    private static func testAVStartSkew() throws {
        let url = tempURL("mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeClip(to: url, videoFrames: 24, size: CGSize(width: 160, height: 120),
                      fps: 24, transform: .identity, audioSeconds: 1.0)

        let src = try MovieSource(id: SourceID("lifecycle.m2"), fileURL: url, loop: true)
        try assert(src.hasAudioTrack, "M2: fixture has no audio track")
        let firstVideo = OSAllocatedUnfairLock<CMTime?>(initialState: nil)
        let firstAudio = OSAllocatedUnfairLock<CMTime?>(initialState: nil)
        src.onFrame = { f in firstVideo.withLock { if $0 == nil { $0 = f.pts } } }
        src.onAudio = { p in firstAudio.withLock { if $0 == nil { $0 = p.pts } } }
        try src.start()
        defer { src.stop() }

        _ = waitUntil(timeout: 6.0) {
            firstVideo.withLock { $0 != nil } && firstAudio.withLock { $0 != nil }
        }
        src.stop()
        guard let v = firstVideo.withLock({ $0 }), let a = firstAudio.withLock({ $0 }) else {
            throw Failure.assertion("M2: never got both a first video frame and a first audio packet")
        }
        let skewMs = abs(CMTimeSubtract(v, a).seconds) * 1000.0
        let frameMs = 1000.0 / 24.0
        try assert(skewMs < frameMs, "M2: first-video vs first-audio skew \(String(format: "%.1f", skewMs))ms ≥ 1 frame (\(String(format: "%.1f", frameMs))ms)")
        print(String(format: "  ✓ M2 A/V start sync: single source, first-frame skew %.1fms < 1 frame (%.1fms)", skewMs, frameMs))
    }

    // MARK: - M3: stop() from inside onFrame must not deadlock

    private static func testStopFromCallbackNoDeadlock() throws {
        let url = tempURL("mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeClip(to: url, videoFrames: 24, size: CGSize(width: 160, height: 120),
                      fps: 24, transform: .identity, audioSeconds: nil)

        let src = try MovieSource(id: SourceID("lifecycle.m3"), fileURL: url, loop: true)
        let stopped = DispatchSemaphore(value: 0)
        src.onFrame = { [weak src] _ in
            src?.stop()      // stop from within the frame callback (the deadlock case)
            stopped.signal()
        }
        try src.start()
        // If stop() sync-deadlocks on its own decode queue, this times out.
        let ok = stopped.wait(timeout: .now() + 5.0)
        try assert(ok == .success, "M3: stop() from onFrame DEADLOCKED (no completion within 5 s)")
        // Give the loop a beat to unwind, then confirm a clean terminal state.
        _ = waitUntil(timeout: 2.0) { src.state == .idle }
        try assert(src.state == .idle, "M3: state after callback-stop is \(src.state), expected .idle")
        print("  ✓ M3 stop-from-callback: no deadlock, state → .idle")
    }

    // MARK: - M4: corrupt / zero-sample file must not busy-spin

    private static func testCorruptFileNoBusySpin() throws {
        let url = tempURL("mov")
        defer { try? FileManager.default.removeItem(at: url) }
        // Faststart clip (moov at the front) so tracks LOAD at init, then truncate
        // the mdat payload so decoding yields no frames — the busy-spin trigger.
        try writeClip(to: url, videoFrames: 30, size: CGSize(width: 160, height: 120),
                      fps: 24, transform: .identity, audioSeconds: nil, optimizeForStreaming: true)
        try truncateMdatPayload(url)

        // Init may succeed (tracks loaded) or throw typed — both are acceptable and
        // neither busy-spins. If it threw, that already satisfies "terminal + typed".
        let src: MovieSource
        do {
            src = try MovieSource(id: SourceID("lifecycle.m4"), fileURL: url, loop: true)
        } catch let e as SourceError {
            print("  ✓ M4 corrupt file: rejected at init (typed) — \(e)")
            return
        }
        src.onFrame = { _ in }
        try? src.start()
        // With loop:true and no decodable frames, the BUG rebuilds readers forever.
        // The fix must reach a terminal .failed with a BOUNDED reader count.
        let reachedTerminal = waitUntil(timeout: 4.0) { src.state == .failed || src.state == .idle }
        // Snapshot BEFORE stop() — stop() clears a .failed state back to .idle.
        let terminalState = src.state
        let creations = src.videoReaderCreations.withLock { $0 }
        let lastErr = src.lastError
        src.stop()
        try assert(reachedTerminal, "M4: corrupt file never reached a terminal state (busy-spin) — state \(terminalState)")
        try assert(terminalState == .failed, "M4: corrupt file state \(terminalState), expected .failed")
        try assert(creations <= 3, "M4: created \(creations) video readers for a corrupt file (busy-spin — expected ≤ 3)")
        try assert(lastErr != nil, "M4: no typed lastError recorded on failure")
        print("  ✓ M4 corrupt file: terminal .failed, \(creations) reader(s) created (bounded), lastError set")
    }

    // MARK: - M5: natural EOF → terminal state, restartable

    private static func testEOFTerminalStateRestart() throws {
        let url = tempURL("mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeClip(to: url, videoFrames: 12, size: CGSize(width: 160, height: 120),
                      fps: 24, transform: .identity, audioSeconds: nil)

        let src = try MovieSource(id: SourceID("lifecycle.m5"), fileURL: url, loop: false)
        let count1 = OSAllocatedUnfairLock(initialState: 0)
        src.onFrame = { _ in count1.withLock { $0 += 1 } }
        try src.start()
        // 12 frames @ 24fps = 0.5 s of content; wait comfortably past EOF.
        _ = waitUntil(timeout: 4.0) { src.state != .running && src.state != .starting }
        try assert(src.state != .running, "M5: past EOF the source still reports .running")
        try assert(src.state == .idle, "M5: past EOF state \(src.state), expected .idle (restartable)")
        let firstFrames = count1.withLock { $0 }
        try assert(firstFrames > 0, "M5: no frames on first play")

        // Restart must work (the bug left it 'running' so start() no-op'd forever).
        let count2 = OSAllocatedUnfairLock(initialState: 0)
        src.onFrame = { _ in count2.withLock { $0 += 1 } }
        try src.start()
        _ = waitUntil(timeout: 3.0) { count2.withLock { $0 } > 0 }
        src.stop()
        try assert(count2.withLock { $0 } > 0, "M5: restart after EOF produced no frames")
        print("  ✓ M5 EOF terminal: play → .idle (\(firstFrames) frames), restart works (\(count2.withLock { $0 }) frames)")
    }

    // MARK: - M6: concurrent start()/stop() must stay atomic

    private static func testConcurrentStartStopStress() throws {
        let url = tempURL("mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeClip(to: url, videoFrames: 24, size: CGSize(width: 160, height: 120),
                      fps: 24, transform: .identity, audioSeconds: nil)

        let src = try MovieSource(id: SourceID("lifecycle.m6"), fileURL: url, loop: true)
        src.onFrame = { _ in }

        // Hammer start()/stop() from many threads at once. The invariant: no crash,
        // no deadlock, and the source always lands in a VALID state (never a torn
        // half-launched one). A serial lifecycle + CAS guarantees this.
        let group = DispatchGroup()
        for i in 0..<64 {
            group.enter()
            DispatchQueue.global().async {
                if i % 2 == 0 { try? src.start() } else { src.stop() }
                group.leave()
            }
        }
        let done = group.wait(timeout: .now() + 10.0)
        try assert(done == .success, "M6: concurrent start/stop DEADLOCKED (10 s)")

        // Quiesce, then a definitive stop → must be idle and re-startable.
        src.stop()
        let valid: Set<SourceState> = [.idle, .failed]
        try assert(valid.contains(src.state), "M6: post-stress final state \(src.state) is not a clean terminal")
        try src.start()
        _ = waitUntil(timeout: 2.0) { src.state == .running }
        try assert(src.state == .running, "M6: source not restartable after stress (\(src.state))")
        src.stop()
        try assert(src.state == .idle, "M6: not idle after final stop (\(src.state))")
        print("  ✓ M6 concurrent start/stop: 64-way stress, no deadlock/tear, restartable")
    }

    // MARK: - M7: audio-only media surfaces .mediaHasNoVideoTrack (typed)

    private static func testAudioOnlyTypedError() throws {
        let url = tempURL("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeAudioOnly(to: url, seconds: 0.4)

        var threwTyped = false
        do {
            _ = try MovieSource(id: SourceID("lifecycle.m7"), fileURL: url, loop: false)
        } catch let e as SourceError {
            if case .mediaHasNoVideoTrack = e { threwTyped = true }
            else { throw Failure.assertion("M7: audio-only threw \(e), expected .mediaHasNoVideoTrack") }
        }
        try assert(threwTyped, "M7: audio-only file did not throw .mediaHasNoVideoTrack")
        print("  ✓ M7 audio-only: init throws typed .mediaHasNoVideoTrack (no blanket .mediaLoadFailed)")
    }

    // MARK: - M9: a stall must drop stale backlog, not replay it (no catch-up burst)

    private static func testLateDecodeNoCatchUpBurst() throws {
        let url = tempURL("mov")
        defer { try? FileManager.default.removeItem(at: url) }
        // ~2 s clip so there's plenty of backlog to (wrongly) burst through.
        try writeClip(to: url, videoFrames: 48, size: CGSize(width: 160, height: 120),
                      fps: 24, transform: .identity, audioSeconds: nil)

        let src = try MovieSource(id: SourceID("lifecycle.m9"), fileURL: url, loop: false)
        let emitTimes = OSAllocatedUnfairLock(initialState: [CFAbsoluteTime]())
        src.onFrame = { _ in emitTimes.withLock { $0.append(CFAbsoluteTimeGetCurrent()) } }
        // Inject a one-shot 0.4 s stall at frame 6 — wall time races ahead of the
        // anchor, so frames 6…N become "late". The fix drops them instead of
        // decoding+emitting the whole backlog instantly.
        let stalled = OSAllocatedUnfairLock(initialState: false)
        src.videoSampleHook = { idx in
            if idx == 6, !stalled.withLock({ let was = $0; $0 = true; return was }) {
                Thread.sleep(forTimeInterval: 0.4)
            }
        }
        try src.start()
        _ = waitUntil(timeout: 6.0) { src.state != .running && src.state != .starting }
        src.stop()

        let dropped = src.lateFramesDropped.withLock { $0 }
        try assert(dropped > 3, "M9: only \(dropped) late frames dropped after a 0.4s stall — backlog was replayed (catch-up burst)")

        // No burst: after the stall, emits must stay spaced ~frame-duration apart,
        // not fire many-at-once. Count the largest cluster within any 50 ms window.
        let times = emitTimes.withLock { $0 }.sorted()
        var maxCluster = 0
        for i in times.indices {
            var j = i, c = 0
            while j < times.count && times[j] - times[i] <= 0.05 { c += 1; j += 1 }
            maxCluster = max(maxCluster, c)
        }
        try assert(maxCluster <= 4, "M9: \(maxCluster) frames emitted within a 50ms window — that IS a catch-up burst")
        print("  ✓ M9 late-decode: 0.4s stall → \(dropped) frames dropped, max \(maxCluster) emits/50ms (no burst)")
    }

    // MARK: - M10: nativeSize is display-oriented (preferredTransform applied)

    private static func testRotatedNativeSize() throws {
        let url = tempURL("mov")
        defer { try? FileManager.default.removeItem(at: url) }
        // Encode 320x180 but tag a 90° rotation → display is 180x320.
        let w = 320, h = 180
        try writeClip(to: url, videoFrames: 6, size: CGSize(width: w, height: h),
                      fps: 24, transform: CGAffineTransform(rotationAngle: .pi / 2), audioSeconds: nil)

        let src = try MovieSource(id: SourceID("lifecycle.m10"), fileURL: url, loop: false)
        try assert(Int(src.nativeSize.width) == h && Int(src.nativeSize.height) == w,
                   "M10: rotated clip nativeSize \(Int(src.nativeSize.width))x\(Int(src.nativeSize.height)), expected \(h)x\(w) (display-oriented)")
        print("  ✓ M10 nativeSize: rotated \(w)x\(h) clip reports display size \(Int(src.nativeSize.width))x\(Int(src.nativeSize.height))")
    }

    // MARK: - Fixture writers

    /// Write a synthetic .mov with a moving-content video track and, optionally,
    /// an audio track (interleaved Float32 sine). `transform` tags the video
    /// track's `preferredTransform`. `optimizeForStreaming` puts the moov at the
    /// front (for the M4 truncation fixture).
    private static func writeClip(to url: URL, videoFrames: Int, size: CGSize, fps: Double,
                                  transform: CGAffineTransform, audioSeconds: Double?,
                                  optimizeForStreaming: Bool = false) throws {
        try? FileManager.default.removeItem(at: url)
        let w = Int(size.width), h = Int(size.height)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mov) }
        catch { throw Failure.setup("AVAssetWriter: \(error)") }
        writer.shouldOptimizeForNetworkUse = optimizeForStreaming

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ])
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ])
        guard writer.canAdd(videoInput) else { throw Failure.setup("cannot add video input") }
        writer.add(videoInput)

        let sampleRate = 44_100.0, channels = 2
        var audioInput: AVAssetWriterInput?
        if audioSeconds != nil {
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 96_000,
            ])
            ai.expectsMediaDataInRealTime = false
            guard writer.canAdd(ai) else { throw Failure.setup("cannot add audio input") }
            writer.add(ai)
            audioInput = ai
        }

        guard writer.startWriting() else {
            throw Failure.setup("startWriting: \(String(describing: writer.error))")
        }
        writer.startSession(atSourceTime: .zero)

        // --- video ---
        let pool = try PixelBufferPool(width: w, height: h)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let scale = CMTimeScale(600)
        for i in 0..<videoFrames {
            let buffer = try pool.makeBuffer()
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer),
               let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                   space: colorSpace, bitmapInfo: bitmapInfo) {
                let t = Double(i) / Double(max(videoFrames - 1, 1))
                ctx.setFillColor(CGColor(srgbRed: CGFloat(t), green: CGFloat(1 - t), blue: 0.4, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                let barX = CGFloat(t) * CGFloat(w - 30)
                ctx.fill(CGRect(x: barX, y: 0, width: 30, height: CGFloat(h)))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !videoInput.isReadyForMoreMediaData { usleep(2_000) }
            let pts = CMTime(value: CMTimeValue(Double(i) / fps * Double(scale)), timescale: scale)
            guard adaptor.append(buffer, withPresentationTime: pts) else {
                throw Failure.setup("video append failed at frame \(i): \(String(describing: writer.error))")
            }
        }
        videoInput.markAsFinished()

        // --- audio (optional) ---
        if let ai = audioInput, let secs = audioSeconds,
           let fmt = makeLPCMFormat(sampleRate: sampleRate, channels: channels) {
            let chunk = 1024
            let totalFrames = Int(secs * sampleRate)
            var frame = 0
            while frame < totalFrames {
                let n = min(chunk, totalFrames - frame)
                if let sb = makeSineSampleBuffer(format: fmt, sampleRate: sampleRate,
                                                 channels: channels, frameCount: n, startFrame: frame) {
                    while !ai.isReadyForMoreMediaData { usleep(2_000) }
                    guard ai.append(sb) else {
                        throw Failure.setup("audio append failed at frame \(frame): \(String(describing: writer.error))")
                    }
                }
                frame += n
            }
            ai.markAsFinished()
        }

        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed else {
            throw Failure.setup("finishWriting status \(writer.status.rawValue): \(String(describing: writer.error))")
        }
    }

    /// Audio-only .m4a (AAC) — no video track (M7 fixture).
    private static func writeAudioOnly(to url: URL, seconds: Double) throws {
        try? FileManager.default.removeItem(at: url)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .m4a) }
        catch { throw Failure.setup("AVAssetWriter(m4a): \(error)") }
        let sampleRate = 44_100.0, channels = 2
        let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 96_000,
        ])
        ai.expectsMediaDataInRealTime = false
        guard writer.canAdd(ai) else { throw Failure.setup("cannot add audio input") }
        writer.add(ai)
        guard writer.startWriting() else { throw Failure.setup("startWriting(m4a): \(String(describing: writer.error))") }
        writer.startSession(atSourceTime: .zero)
        guard let fmt = makeLPCMFormat(sampleRate: sampleRate, channels: channels) else {
            throw Failure.setup("LPCM format")
        }
        let chunk = 1024, totalFrames = Int(seconds * sampleRate)
        var frame = 0
        while frame < totalFrames {
            let n = min(chunk, totalFrames - frame)
            if let sb = makeSineSampleBuffer(format: fmt, sampleRate: sampleRate,
                                             channels: channels, frameCount: n, startFrame: frame) {
                while !ai.isReadyForMoreMediaData { usleep(2_000) }
                guard ai.append(sb) else { throw Failure.setup("audio append failed: \(String(describing: writer.error))") }
            }
            frame += n
        }
        ai.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed else {
            throw Failure.setup("finishWriting(m4a) status \(writer.status.rawValue): \(String(describing: writer.error))")
        }
    }

    private static func makeLPCMFormat(sampleRate: Double, channels: Int) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)
        var fmt: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                                    layoutSize: 0, layout: nil, magicCookieSize: 0,
                                                    magicCookie: nil, extensions: nil,
                                                    formatDescriptionOut: &fmt)
        return status == noErr ? fmt : nil
    }

    private static func makeSineSampleBuffer(format: CMAudioFormatDescription, sampleRate: Double,
                                             channels: Int, frameCount: Int, startFrame: Int) -> CMSampleBuffer? {
        let byteCount = frameCount * channels * 4
        var samples = [Float](repeating: 0, count: frameCount * channels)
        for i in 0..<frameCount {
            let t = Double(startFrame + i) / sampleRate
            let s = Float(sin(2.0 * Double.pi * 440.0 * t)) * 0.2
            for c in 0..<channels { samples[i * channels + c] = s }
        }
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &blockBuffer) == noErr,
            let blockBuffer else { return nil }
        let ok = samples.withUnsafeBytes { raw -> Bool in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: byteCount) == noErr
        }
        guard ok else { return nil }
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid)
        var sampleSize = 4 * channels
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
            sampleCount: frameCount, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer) == noErr else {
            return nil
        }
        return sampleBuffer
    }

    /// Corrupt a faststart .mov by truncating the file at the start of the `mdat`
    /// payload — the moov (at the front) still parses so tracks LOAD, but no
    /// sample data can be read (the M4 no-busy-spin fixture).
    private static func truncateMdatPayload(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        let needle: [UInt8] = Array("mdat".utf8)
        var idx: Int? = nil
        if data.count > needle.count {
            for i in 0...(data.count - needle.count) {
                if data[i] == needle[0], data[i+1] == needle[1], data[i+2] == needle[2], data[i+3] == needle[3] {
                    idx = i; break
                }
            }
        }
        guard let mdat = idx else { throw Failure.setup("mdat atom not found for truncation") }
        // Keep the 4-byte size + 'mdat' fourcc header, drop the payload.
        let keep = min(data.count, mdat + 4 + 8)
        try data.prefix(keep).write(to: url)
    }
}
