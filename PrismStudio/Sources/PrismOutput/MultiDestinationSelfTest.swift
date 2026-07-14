import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import PrismCore
import os

/// Headless self-verification for `MultiDestinationBroadcaster` — proves the
/// encode-once → fan-to-many contract and its fault isolation *without any real
/// server* (no network side effects). Uses in-process `FakeDestination` stubs
/// substituted through the `StreamDestination` protocol seam, so the real
/// broadcaster code path is exercised exactly as it would be with RTMP/SRT.
///
/// Run standalone via the `.build` object-link pattern (see the module summary)
/// or from XCTest. Throws with a precise message on first failure; returns
/// human-readable evidence lines on success.
public enum MultiDestinationSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case setupFailed(String)
        case assertion(String)
        public var description: String {
            switch self {
            case .setupFailed(let s): return "multi-dest self-test setup failed: \(s)"
            case .assertion(let s): return "multi-dest self-test assertion failed: \(s)"
            }
        }
    }

    /// An in-process `StreamDestination` double. Counts what it receives; in
    /// "disconnected" mode it *raises on every frame* (contained in its own
    /// do/catch) to prove a throwing/dead destination cannot perturb siblings
    /// or the broadcaster's fan-out loop.
    actor FakeDestination: StreamDestination {
        struct StubDisconnected: Error {}

        let name: String
        private let recv = OSAllocatedUnfairLock<(video: UInt64, audio: UInt64, dropped: UInt64)>(initialState: (0, 0, 0))
        private let down = OSAllocatedUnfairLock<Bool>(initialState: false)

        init(name: String) { self.name = name }

        nonisolated func setDisconnected(_ value: Bool) { down.withLock { $0 = value } }
        nonisolated var counts: (video: UInt64, audio: UInt64, dropped: UInt64) { recv.withLock { $0 } }

        nonisolated func append(encodedVideo sampleBuffer: CMSampleBuffer) {
            if down.withLock({ $0 }) {
                do { throw StubDisconnected() }        // a real throw…
                catch { recv.withLock { $0.dropped &+= 1 } } // …contained here.
                return
            }
            recv.withLock { $0.video &+= 1 }
        }

        nonisolated func append(audio sampleBuffer: CMSampleBuffer) {
            if down.withLock({ $0 }) { recv.withLock { $0.dropped &+= 1 }; return }
            recv.withLock { $0.audio &+= 1 }
        }

        func destinationStats() async -> StreamDestinationStats {
            let (v, a, d) = recv.withLock { $0 }
            return StreamDestinationStats(
                state: down.withLock { $0 } ? .failed(reason: "stub-disconnected") : .publishing,
                bytesOut: Int(v) * 1_000,
                bytesOutPerSecond: 0,
                videoFramesAppended: v,
                audioBuffersAppended: a,
                appendsDropped: d,
                reconnects: 0)
        }

        func teardown() async {}
    }

    public static func run() async throws -> [String] {
        var lines: [String] = []
        let w = 320, h = 240, fps = 30
        let n = 4                // destinations
        let framesA = 45         // phase A: all healthy
        let framesB = 30         // phase B: one destination disconnected

        // Single encoder — the "encode once" source.
        let encoder = ProgramEncoder(settings: .init(
            codec: .h264, width: w, height: h, averageBitrate: 2_000_000,
            keyframeInterval: 1.0, expectedFrameRate: Double(fps), lowLatencyRateControl: false))
        do { try encoder.start() } catch {
            throw SelfTestError.setupFailed("VT encoder start (hardware H.264 encode required): \(error)")
        }
        defer { encoder.stop() }

        // N fake destinations behind the protocol seam.
        let stubs = (0..<n).map { FakeDestination(name: "dest\($0)") }
        let broadcaster = MultiDestinationBroadcaster()
        for (i, stub) in stubs.enumerated() {
            await broadcaster.addDestination(stub, as: Destination(
                name: stub.name, proto: i.isMultiple(of: 2) ? .rtmp : .srt, url: "stub://\(stub.name)"))
        }
        // Encode once → fan to many.
        await broadcaster.attach(to: encoder)

        let pool: PixelBufferPool
        do { pool = try PixelBufferPool(width: w, height: h) }
        catch { throw SelfTestError.setupFailed("pixel pool: \(error)") }

        let frameDur = CMTime(value: 1, timescale: CMTimeScale(fps))
        func feed(_ range: Range<Int>) throws {
            for i in range {
                let pts = CMTime(value: Int64(i), timescale: CMTimeScale(fps))
                let frame = try fillFrame(pool: pool, gray: UInt8((i * 9) % 255), pts: pts, duration: frameDur)
                try encoder.encode(frame)
            }
        }
        func drain() async { encoder.flush(); try? await Task.sleep(nanoseconds: 300_000_000) }

        // ── Phase A: all destinations healthy.
        try feed(0..<framesA)
        await drain()
        let deliveredA = await broadcaster.fanOutStats().videoFramesFanned
        lines.append("── Phase A (encode once → fan to \(n))")
        lines.append("   encoder delivered \(deliveredA) encoded frame(s); each fanned to \(n) destinations")
        guard deliveredA > 0 else { throw SelfTestError.assertion("encoder produced no encoded frames") }
        for stub in stubs {
            let c = stub.counts
            lines.append("   \(stub.name): received=\(c.video) dropped=\(c.dropped)")
            guard c.video == deliveredA else {
                throw SelfTestError.assertion("\(stub.name) received \(c.video) but \(deliveredA) were fanned — fan-out not reaching every destination")
            }
        }

        // ── Phase B: disconnect ONE destination, keep streaming.
        let dead = stubs[1]
        dead.setDisconnected(true)
        try feed(framesA..<(framesA + framesB))
        await drain()
        let deliveredTotal = await broadcaster.fanOutStats().videoFramesFanned
        lines.append("── Phase B (dest '\(dead.name)' disconnected; \(deliveredTotal - deliveredA) more frames fanned)")
        guard deliveredTotal > deliveredA else { throw SelfTestError.assertion("no frames fanned in phase B") }

        for stub in stubs {
            let c = stub.counts
            lines.append("   \(stub.name): received=\(c.video) dropped=\(c.dropped)")
            if stub === dead {
                // The dead destination froze at phase-A count; every phase-B
                // frame was thrown/dropped on its own queue.
                guard c.video == deliveredA else {
                    throw SelfTestError.assertion("disconnected \(stub.name) still received frames (\(c.video) > \(deliveredA))")
                }
                guard c.dropped == deliveredTotal - deliveredA else {
                    throw SelfTestError.assertion("disconnected \(stub.name) dropped \(c.dropped), expected \(deliveredTotal - deliveredA)")
                }
            } else {
                // Every healthy destination kept receiving ALL frames — one dead
                // destination did not stall the others.
                guard c.video == deliveredTotal else {
                    throw SelfTestError.assertion("healthy \(stub.name) received \(c.video) but \(deliveredTotal) were fanned — a dead destination stalled a live one")
                }
            }
        }

        // Per-destination stats are independent.
        let stats = await broadcaster.statsByDestination()
        let healthyOut = stats.values.filter { $0.state.isLive }.map { $0.videoFramesAppended }
        let deadOut = stats.values.first { !$0.state.isLive }
        lines.append("── Independent per-destination stats")
        lines.append("   live destinations report videoFramesAppended=\(healthyOut.sorted()); dead reports appended=\(deadOut?.videoFramesAppended ?? 0) dropped=\(deadOut?.appendsDropped ?? 0)")
        guard let deadOut, deadOut.videoFramesAppended == deliveredA, deadOut.appendsDropped == deliveredTotal - deliveredA else {
            throw SelfTestError.assertion("dead destination stats not independent/consistent")
        }
        guard healthyOut.allSatisfy({ $0 == deliveredTotal }), healthyOut.count == n - 1 else {
            throw SelfTestError.assertion("live destination stats inconsistent: \(healthyOut)")
        }

        // ── Phase B2 (#11): AUDIO fan-out — each live destination receives audio.
        // The prior phases fanned only video; this proves `broadcast(audio:)`
        // reaches every enabled destination (and that a down destination drops
        // audio on its own queue without stalling the fan-out).
        let audioCount = 10
        for i in 0..<audioCount {
            guard let sb = makeAudioSample(pts: CMTime(value: Int64(i * 1024), timescale: 48_000)) else {
                throw SelfTestError.setupFailed("audio sample synth failed")
            }
            broadcaster.broadcast(audio: sb) // FakeDestination.append(audio:) counts synchronously
        }
        let audioFanned = await broadcaster.fanOutStats().audioBuffersFanned
        lines.append("── Phase B2 (audio fan-out): fed \(audioCount) program-audio buffers; broadcaster fanned \(audioFanned)")
        guard audioFanned == UInt64(audioCount) else {
            throw SelfTestError.assertion("broadcaster fanned \(audioFanned) audio buffers, expected \(audioCount)")
        }
        for stub in stubs {
            let c = stub.counts
            if stub === dead {
                guard c.audio == 0 else {
                    throw SelfTestError.assertion("disconnected \(stub.name) received audio (\(c.audio)) — should have dropped it")
                }
                lines.append("   \(stub.name) (down): audio received=\(c.audio) (dropped on its own queue, did not stall peers)")
            } else {
                guard c.audio == UInt64(audioCount) else {
                    throw SelfTestError.assertion("healthy \(stub.name) received \(c.audio) audio buffers but \(audioCount) were fanned — audio fan-out not reaching every live destination")
                }
                lines.append("   \(stub.name): audio received=\(c.audio)")
            }
        }

        await broadcaster.shutdown()

        // ── Phase C: lifecycle recovery (C4/C5) + C1 expected-medias unit check.
        try await runLifecycleChecks(&lines)

        lines.append("   PASS")
        return lines
    }

    /// Proves the streaming-output lifecycle fixes with no real server, driving
    /// the REAL `add()` / `setEnabled()` connect paths against a concrete
    /// `SRTStreamOutput` whose connect fails fast (an invalid URL is rejected by
    /// `SRTStreamOutput.buildURL` before any socket work).
    ///
    ///  - C5: `add()` with a failing connect must NOT leave the destination in
    ///    the live fan-out snapshot.
    ///  - C4: after a `setEnabled(true)` that fails to connect, a *second*
    ///    `setEnabled(true)` must actually re-attempt (throw again), not
    ///    short-circuit as a no-op.
    ///  - C1: `SRTStreamOutput.expectedMedias(includeAudio:)` selects `[.video]`
    ///    when audio is off (the set that makes `TSWriter.canWriteFor` admit a
    ///    video-only stream) and `[.video, .audio]` when on.
    private static func runLifecycleChecks(_ lines: inout [String]) async throws {
        lines.append("── Phase C: streaming lifecycle recovery (C4/C5) + C1 SRT video-always invariant")

        // C1 — SRT ALWAYS declares [.video] (finding #1/#5). Never [.video,.audio].
        let medias = SRTStreamOutput.expectedMediasForPublish()
        guard medias == [.video] else {
            throw SelfTestError.assertion("C1: expectedMediasForPublish() must be [.video], got \(medias)")
        }
        // Structural proof against a faithful local model of TSWriter.canWriteFor
        // (vendored SRTHaishinKit/Sources/TS/TSWriter.swift:56-70). Proves that a
        // [.video] declaration admits packets on videoFormat alone and is NEVER
        // gated on audio — so BOTH the video-only case and the mismatched-audio
        // case transmit video, while the old [.video,.audio] declaration stalled.
        func canWriteFor(_ expected: Set<AVMediaType>, videoSet: Bool, audioSet: Bool) -> Bool {
            if expected.isEmpty { return true }                                   // :57-59
            if expected.contains(.audio) && expected.contains(.video) {          // :60-61
                return audioSet && videoSet
            }
            if expected.contains(.video) { return videoSet }                     // :63-64
            if expected.contains(.audio) { return audioSet }                     // :66-67
            return false
        }
        // video-only publish, no audio ever: video transmits.
        guard canWriteFor([.video], videoSet: true, audioSet: false) else {
            throw SelfTestError.assertion("C1: [.video] must admit video with NO audio (the invariant)")
        }
        // mismatched: audio arrives late → still transmits (upgrades PMT).
        guard canWriteFor([.video], videoSet: true, audioSet: true) else {
            throw SelfTestError.assertion("C1: [.video] must admit video+audio")
        }
        // and video is never blocked before its own format is set (sanity).
        guard canWriteFor([.video], videoSet: false, audioSet: false) == false else {
            throw SelfTestError.assertion("C1 model wrong: [.video] needs videoFormat")
        }
        // The removed bug: [.video,.audio] blocks ALL packets (video too) until an
        // audioFormat a video-only source never sets.
        guard canWriteFor([.video, .audio], videoSet: true, audioSet: false) == false else {
            throw SelfTestError.assertion("C1 model wrong: [.video,.audio] should block on absent audio")
        }
        lines.append("   C1: SRT declares [.video] always → video transmits video-only AND with mismatched/late audio (TSWriter.canWriteFor :63-64); the old [.video,.audio] blocked ALL packets on absent audioFormat (:60-61) — removed")

        // A URL that fails `SRTStreamOutput.buildURL` → connect throws instantly,
        // no network. (scheme != "srt")
        let badURL = "not-a-srt-url"
        let bcast = MultiDestinationBroadcaster()

        // C5 — add() with a failing connect.
        var addThrew = false
        do {
            _ = try await bcast.add(Destination(name: "c5", proto: .srt, url: badURL))
        } catch {
            addThrew = true
        }
        guard addThrew else { throw SelfTestError.assertion("C5: add() with bad URL did not throw") }
        let liveAfterAdd = await bcast.liveDestinationCount()
        let statsAfterAdd = await bcast.fanOutStats()
        guard liveAfterAdd == 0 else {
            throw SelfTestError.assertion("C5: failed destination left in live fan-out set (liveCount=\(liveAfterAdd))")
        }
        guard statsAfterAdd.destinationCount == 1, statsAfterAdd.enabledCount == 0 else {
            throw SelfTestError.assertion("C5: expected registered-but-disabled (count=1, enabled=0), got count=\(statsAfterAdd.destinationCount) enabled=\(statsAfterAdd.enabledCount)")
        }
        lines.append("   C5: failed add() → registered but disabled, NOT in live set (liveCount=0, enabledCount=0)")

        // C4 — a disabled destination (add() with enabled:false registers a real
        // SRTStreamOutput without connecting), then two setEnabled(true) that
        // both fail their connect.
        let bcast2 = MultiDestinationBroadcaster()
        let id = try await bcast2.add(Destination(name: "c4", proto: .srt, url: badURL, enabled: false))

        var enable1Threw = false
        do { try await bcast2.setEnabled(true, id: id) } catch { enable1Threw = true }
        guard enable1Threw else { throw SelfTestError.assertion("C4: first setEnabled(true) did not throw on bad connect") }
        let liveAfter1 = await bcast2.liveDestinationCount()
        let stats1 = await bcast2.fanOutStats()
        guard liveAfter1 == 0, stats1.enabledCount == 0 else {
            throw SelfTestError.assertion("C4: after failed enable, reverted state expected (live=0,enabled=0), got live=\(liveAfter1) enabled=\(stats1.enabledCount)")
        }

        // The proof: a SECOND setEnabled(true) must RE-ATTEMPT (throw again). The
        // pre-fix bug left `enabled = true`, so this call would short-circuit on
        // the `enabled != enabled` guard and return WITHOUT throwing (a silent
        // no-op that can never recover).
        var enable2Threw = false
        do { try await bcast2.setEnabled(true, id: id) } catch { enable2Threw = true }
        guard enable2Threw else {
            throw SelfTestError.assertion("C4: second setEnabled(true) was a no-op (did not retry) — destination wedged")
        }
        lines.append("   C4: after a failed setEnabled(true), a 2nd setEnabled(true) re-attempts (throws again) — not a silent no-op")

        await bcast.shutdown()
        await bcast2.shutdown()
    }

    // MARK: - test-only CPU frame fill

    private static func fillFrame(pool: PixelBufferPool, gray: UInt8, pts: CMTime, duration: CMTime) throws -> VideoFrame {
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
        return VideoFrame(pixelBuffer: buf, pts: pts, duration: duration, source: SourceID("selftest.multidest"))
    }

    /// Minimal interleaved-Float32 LPCM audio `CMSampleBuffer` (no sample data
    /// needed — the fan-out stubs only count buffers). Used to exercise the
    /// audio fan-out path (#11).
    private static func makeAudioSample(pts: CMTime, frames: Int = 1024, sampleRate: Double = 48_000) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: Int64(frames), timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}
