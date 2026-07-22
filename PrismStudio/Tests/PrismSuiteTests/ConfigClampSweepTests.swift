import AVFAudio
import CoreMedia
import XCTest

@testable import PrismAudio
@testable import PrismOutput
import PrismCore

/// Config-clamp sweep (Roadmap Phase 1c). Invalid values passed to public config
/// setters/inits in PrismAudio + PrismOutput used to HANG or ABORT the process —
/// a live-show hazard. Each `BUG`/`FIX` below documents the pre-fix failure, then
/// proves the invalid input is now safely clamped (or throws a typed error) and
/// that a valid input still behaves exactly as before. All deterministic and
/// hardware-free (no device start, synthesized signals only).
final class ConfigClampSweepTests: XCTestCase {

    private let sr = 48_000.0

    // MARK: - TransientDetector.Configuration.blockSize (audio-callback HANG)
    //
    // BUG: `Configuration.blockSize` is a mutable `public var`, and the
    // `configuration` setter stored a replacement WITHOUT re-normalizing. Setting
    // `blockSize = 0` (legal Swift) made `process` enter
    // `while cursor + 0 <= pending.count`, never advance the cursor, and append
    // packets to `pending` without bound on the audio-callback thread → hang/OOM.
    //
    // FIX: the setter + init normalize every replacement, and `process` clamps the
    // hop into `[minimumBlockSize, maximumBlockSize]` (`effectiveBlockSize`) — the
    // floor makes the loop terminate, the ceiling keeps `pending` bounded.

    func testTransientEffectiveBlockSizeNeverSpins() {
        let minB = TransientDetector.minimumBlockSize
        let maxB = TransientDetector.maximumBlockSize
        XCTAssertEqual(TransientDetector.effectiveBlockSize(0), minB, "zero hop floors to the minimum")
        XCTAssertEqual(TransientDetector.effectiveBlockSize(-1), minB, "negative hop floors to the minimum")
        XCTAssertEqual(TransientDetector.effectiveBlockSize(Int.min), minB, "extreme-negative floors to the minimum")
        XCTAssertEqual(TransientDetector.effectiveBlockSize(512), 512, "a valid hop is used unchanged")
        XCTAssertEqual(TransientDetector.effectiveBlockSize(Int.max), maxB, "Int.max hop caps to the maximum")
        XCTAssertEqual(TransientDetector.effectiveBlockSize(maxB + 1), maxB, "just above the maximum caps down")
        XCTAssertGreaterThan(maxB, minB, "the ceiling is above the floor")
    }

    /// The reproducing mutation: build a `Configuration`, then set `blockSize = 0`
    /// directly (bypassing `init`) and install it through the PUBLIC setter. The
    /// stored value must be normalized in range — pre-fix it was stored raw as 0.
    func testTransientSetterNormalizesMutatedBlockSize() {
        let det = TransientDetector(sampleRate: sr)
        let minB = TransientDetector.minimumBlockSize
        for bad in [0, -1, Int.min] {
            var cfg = TransientDetector.Configuration()
            cfg.blockSize = bad
            det.configuration = cfg
            XCTAssertGreaterThanOrEqual(det.configuration.blockSize, minB,
                                        "mutated blockSize \(bad) must be normalized to >= \(minB)")
        }
        // Int.max must be CAPPED (not preserved) so `pending` can fill a block.
        var huge = TransientDetector.Configuration()
        huge.blockSize = .max
        det.configuration = huge
        XCTAssertLessThanOrEqual(det.configuration.blockSize, TransientDetector.maximumBlockSize)
    }

    /// End-to-end anti-hang: after installing the worst-case mutated config
    /// (`blockSize = 0`) through the public setter, feeding a large signal must
    /// TERMINATE quickly under a wall-clock watchdog. Pre-fix this never returned.
    func testTransientProcessTerminatesUnderZeroBlockSize() throws {
        let det = TransientDetector(sampleRate: sr)
        var cfg = TransientDetector.Configuration()
        cfg.blockSize = 0
        det.configuration = cfg

        let done = DispatchSemaphore(value: 0)
        DispatchQueue(label: "clamp.transient.watchdog").async {
            let tone = TransientSelfTest.sine(count: Int(self.sr * 2), amplitude: 0.9,
                                              frequency: 440, sampleRate: self.sr)
            var idx = 0
            let packetFrames = 1024
            while idx < tone.count {
                let n = min(packetFrames, tone.count - idx)
                let slice = Array(tone[idx..<(idx + n)])
                if let pkt = try? TransientSelfTest.makeProgramPacket(
                    signal: slice, channelCount: 2, sampleRate: self.sr, startSample: idx) {
                    det.process(pkt)
                }
                idx += n
            }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "process must terminate — a zero hop must not hang the audio callback")
    }

    /// An `Int.max` blockSize set through the public API must keep `pending`
    /// bounded (a block that never completes would append every packet forever).
    func testTransientExtremeBlockSizeKeepsPendingBounded() throws {
        let det = TransientDetector(sampleRate: sr)
        var cfg = TransientDetector.Configuration()
        cfg.blockSize = .max
        det.configuration = cfg

        let totalFrames = Int(sr * 5) // 240k frames fed
        var idx = 0
        let packetFrames = 1024
        while idx < totalFrames {
            let n = min(packetFrames, totalFrames - idx)
            let slice = TransientSelfTest.sine(count: n, amplitude: 0.5, frequency: 220, sampleRate: sr)
            if let pkt = try? TransientSelfTest.makeProgramPacket(
                signal: slice, channelCount: 2, sampleRate: sr, startSample: idx) {
                det.process(pkt)
            }
            idx += n
        }
        let pending = det._test_pendingSampleCount
        XCTAssertLessThan(pending, 200_000,
                          "pending must stay bounded under Int.max blockSize (held \(pending) of \(totalFrames))")
    }

    func testTransientSampleRateRejectsInvalid() {
        for bad in [0.0, -48_000.0, .nan, .infinity, -.infinity] as [Double] {
            let det = TransientDetector(sampleRate: bad)
            XCTAssertTrue(det.sampleRate.isFinite && det.sampleRate > 0,
                          "invalid sampleRate \(bad) must be replaced with a valid one")
        }
        XCTAssertEqual(TransientDetector(sampleRate: 44_100).sampleRate, 44_100, accuracy: 1e-9)
    }

    /// VALID input unchanged: a normal mutated config (blockSize 1024) is stored
    /// verbatim and still detects a click exactly as before.
    func testTransientValidConfigBehavesIdentically() throws {
        var cfg = TransientDetector.Configuration()
        cfg.blockSize = 1024
        let det = TransientDetector(sampleRate: sr, configuration: cfg)
        XCTAssertEqual(det.configuration.blockSize, 1024, "a valid blockSize is stored unchanged")

        let signal = TransientSelfTest.bedWithClicks(
            totalSamples: Int(sr), bedAmplitude: 0.02,
            clicks: [(Int(0.3 * sr), 0.9, 256)], sampleRate: sr)
        let fires = try TransientSelfTest.run(detector: det, signal: signal, sampleRate: sr)
        XCTAssertEqual(fires.count, 1, "a valid config still detects the click")
    }

    // MARK: - AudioMixer.Configuration.sampleRate (graph-construction ABORT)
    //
    // BUG: `sampleRate = 0` reached `AVAudioFormat(standardFormatWithSampleRate:…)`
    // which returns nil → the mixer's init hit `preconditionFailure` (exit 134).
    // A non-finite `ringSeconds` would later crash `Int(_:)` in `addChannel`.
    //
    // FIX: `Configuration.normalized()` clamps every field; the init sanitizes
    // before building the graph and never aborts.

    func testMixerConfigurationNormalizesUnsafeFields() {
        var cfg = AudioMixer.Configuration()
        cfg.sampleRate = 0
        cfg.channelCount = 0
        cfg.ringSeconds = .nan
        cfg.tapBufferFrames = 0
        cfg.maximumInitialAlignmentSeconds = .infinity
        let n = cfg.normalized()
        XCTAssertTrue(n.sampleRate.isFinite && n.sampleRate > 0, "sampleRate 0 rejected")
        XCTAssertGreaterThanOrEqual(n.channelCount, 1, "channelCount floored to >= 1")
        XCTAssertTrue(n.ringSeconds.isFinite && n.ringSeconds > 0, "non-finite ringSeconds rejected")
        XCTAssertGreaterThanOrEqual(n.tapBufferFrames, 1, "tapBufferFrames floored to >= 1")
        XCTAssertTrue(n.maximumInitialAlignmentSeconds.isFinite, "non-finite alignment rejected")
    }

    /// The reproducing input: constructing a mixer with `sampleRate = 0` must NOT
    /// abort (pre-fix: exit 134). The internal format falls back to a valid rate.
    func testMixerConstructsWithZeroSampleRate() throws {
        var cfg = AudioMixer.Configuration()
        cfg.sampleRate = 0
        cfg.ringSeconds = .nan
        let mixer = AudioMixer(configuration: cfg)
        XCTAssertGreaterThan(mixer.internalFormat.sampleRate, 0, "internal format has a valid rate")
        XCTAssertGreaterThan(mixer.configuration.sampleRate, 0, "stored config has a valid rate")
        // Exercise the `Int(sampleRate * ringSeconds)` path that would crash on a
        // non-finite ringSeconds — headless graph attach only, no device start.
        XCTAssertNoThrow(try mixer.addChannel(id: SourceID("clamp.test")))
    }

    /// VALID input unchanged: a normal 44.1 kHz mono config is used verbatim.
    func testMixerValidConfigurationUnchanged() {
        var cfg = AudioMixer.Configuration()
        cfg.sampleRate = 44_100
        cfg.channelCount = 1
        let mixer = AudioMixer(configuration: cfg)
        XCTAssertEqual(mixer.configuration.sampleRate, 44_100, accuracy: 1e-9)
        XCTAssertEqual(mixer.configuration.channelCount, 1)
        XCTAssertEqual(mixer.internalFormat.sampleRate, 44_100, accuracy: 1e-9)
        XCTAssertEqual(mixer.internalFormat.channelCount, 1)
    }

    // MARK: - PCMRingBuffer.init (precondition ABORT)
    //
    // BUG: `init(channelCount:capacityFrames:)` had `precondition(channelCount >= 1
    // && capacityFrames >= 1)` → a 0/negative dimension aborted the process.
    //
    // FIX: clamp both to a floor of 1; valid dimensions are used unchanged.

    func testRingBufferClampsZeroDimensions() {
        let ring = PCMRingBuffer(channelCount: 0, capacityFrames: 0)
        XCTAssertEqual(ring.channelCount, 1, "channelCount floored to 1")
        XCTAssertEqual(ring.capacityFrames, 1, "capacityFrames floored to 1")
        // A write must not crash on the clamped 1x1 ring.
        let samples: [Float] = [0.5]
        samples.withUnsafeBufferPointer { p in
            ring.write(interleaved: p.baseAddress!, sourceChannelCount: 1, frameCount: 1)
        }
        XCTAssertLessThanOrEqual(ring.bufferedFrames, ring.capacityFrames)

        let neg = PCMRingBuffer(channelCount: -4, capacityFrames: -100)
        XCTAssertEqual(neg.channelCount, 1)
        XCTAssertEqual(neg.capacityFrames, 1)
    }

    /// VALID input unchanged: (2, 100) is used verbatim and round-trips a write.
    func testRingBufferValidDimensionsUnchanged() {
        let ring = PCMRingBuffer(channelCount: 2, capacityFrames: 100)
        XCTAssertEqual(ring.channelCount, 2)
        XCTAssertEqual(ring.capacityFrames, 100)
        let frames = 8
        let samples = [Float](repeating: 0.25, count: frames * 2)
        samples.withUnsafeBufferPointer { p in
            ring.write(interleaved: p.baseAddress!, sourceChannelCount: 2, frameCount: frames)
        }
        XCTAssertEqual(ring.bufferedFrames, frames, "a valid ring buffers the written frames")
    }

    // MARK: - ReplayBuffer.init(seconds:) (precondition ABORT)
    //
    // BUG: `precondition(seconds > 0, …)` aborted the process on a non-positive or
    // non-finite replay window (invalid public input on a live show).
    //
    // FIX: clamp the window into `[minimumDurationSeconds, maximumDurationSeconds]`;
    // realistic windows are unchanged.

    func testReplayInitClampsUnsafeSeconds() {
        for bad in [0.0, -5.0, .nan, -.infinity] as [Double] {
            let replay = ReplayBuffer(seconds: bad)
            XCTAssertGreaterThanOrEqual(replay.duration.seconds, ReplayBuffer.minimumDurationSeconds,
                                        "window \(bad) clamped to >= minimum, no abort")
            XCTAssertTrue(replay.duration.isValid && replay.duration.seconds.isFinite,
                          "clamped duration is a valid finite CMTime")
        }
        // An absurdly large window is capped, not left to overflow CMTimeValue.
        let big = ReplayBuffer(seconds: 1e18)
        XCTAssertLessThanOrEqual(big.duration.seconds, ReplayBuffer.maximumDurationSeconds)
    }

    func testReplayClampDurationBounds() {
        XCTAssertEqual(ReplayBuffer.clampDuration(.nan), 30, "non-finite falls back to the default")
        XCTAssertEqual(ReplayBuffer.clampDuration(.infinity), 30, "±infinity is non-finite → default")
        XCTAssertEqual(ReplayBuffer.clampDuration(-.infinity), 30, "±infinity is non-finite → default")
        XCTAssertEqual(ReplayBuffer.clampDuration(0), ReplayBuffer.minimumDurationSeconds)
        XCTAssertEqual(ReplayBuffer.clampDuration(-9), ReplayBuffer.minimumDurationSeconds)
        XCTAssertEqual(ReplayBuffer.clampDuration(1e18), ReplayBuffer.maximumDurationSeconds, "an absurd finite window caps to max")
        XCTAssertEqual(ReplayBuffer.clampDuration(30), 30, "a valid window is unchanged")
    }

    /// VALID input unchanged: a normal 30 s window is stored verbatim.
    func testReplayInitValidSecondsUnchanged() {
        let replay = ReplayBuffer(seconds: 30)
        XCTAssertEqual(replay.duration.seconds, 30, accuracy: 1e-6, "a valid window is preserved exactly")
    }

    // MARK: - ReplayBuffer.saveHighlight(lastSeconds:) (precondition ABORT)
    //
    // BUG: `precondition(lastSeconds > 0, …)` fired BEFORE the empty-buffer check,
    // so a non-positive request aborted the process.
    //
    // FIX: clamp the request to a positive value; the empty buffer then throws the
    // typed `ReplayError.empty` — never aborts. Positive requests are unchanged.

    func testSaveHighlightNonPositiveLastSecondsDoesNotAbort() async {
        let replay = ReplayBuffer(seconds: 10)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clamp-highlight-\(UUID().uuidString).mov")
        for bad in [0.0, -5.0, .nan] as [Double] {
            do {
                _ = try await replay.saveHighlight(lastSeconds: bad, to: url)
                XCTFail("expected ReplayError.empty on an empty buffer")
            } catch let error as ReplayBuffer.ReplayError {
                guard case .empty = error else {
                    return XCTFail("expected .empty, got \(error)")
                }
                // Reached the typed error instead of aborting — the fix works.
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }
}
