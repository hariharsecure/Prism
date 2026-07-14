import CoreMedia
import XCTest

@testable import PrismAudio
import PrismCore

/// Regression tests for finding **F10** — a mutable `AudioEnvelopeFollower`
/// configuration that could hang and exhaust memory.
///
/// Pre-fix, `Configuration`'s fields were public `var`s and the `configuration`
/// setter stored a replacement WITHOUT re-normalizing. Setting `blockSize = 0`
/// (legal Swift) then made `process` enter `while cursor + 0 <= pending.count`,
/// never advance the cursor, and append envelope updates without bound on the
/// audio callback → hang + OOM.
///
/// The fix makes every `Configuration` field immutable (`let`, clamped once in
/// `init`), normalizes every replacement installed through the `configuration`
/// setter, validates `sampleRate`, and clamps the hop to
/// `[minimumBlockSize, maximumBlockSize]` wherever `process` uses it
/// (`effectiveBlockSize`) — the floor stops an infinite spin, the ceiling stops
/// the pending buffer growing without bound. These tests lock in each invariant.
///
/// Note on "the reproducing mutation": the exact pre-fix reproducer
/// `follower.configuration.blockSize = 0` (and building a `Configuration` whose
/// stored `blockSize` is 0) NO LONGER COMPILES — the fields are now `let`. That
/// compile-time removal IS the primary fix. The runtime anti-hang floor that
/// backs it is exercised directly below via `effectiveBlockSize` and an
/// end-to-end watchdog on `process`.
final class AudioEnvelopeFollowerMutationTests: XCTestCase {

    private let sr = 48_000.0

    // MARK: The anti-hang floor (the invariant that makes the loop terminate)

    /// `process` never uses a hop below `minimumBlockSize`, so the block loop
    /// always advances the cursor. Zero/negative/extreme all floor to the
    /// minimum; a valid value passes through unchanged. Pre-fix, `process` used
    /// the raw configured value, so 0 here would have spun forever.
    func testEffectiveBlockSizeNeverSpins() {
        let minB = AudioEnvelopeFollower.minimumBlockSize
        XCTAssertEqual(AudioEnvelopeFollower.effectiveBlockSize(0), minB, "zero hop must floor to the minimum")
        XCTAssertEqual(AudioEnvelopeFollower.effectiveBlockSize(-1), minB, "negative hop must floor to the minimum")
        XCTAssertEqual(AudioEnvelopeFollower.effectiveBlockSize(Int.min), minB, "extreme-negative hop must floor to the minimum")
        XCTAssertEqual(AudioEnvelopeFollower.effectiveBlockSize(minB - 1), minB, "just below the minimum floors up")
        XCTAssertEqual(AudioEnvelopeFollower.effectiveBlockSize(512), 512, "a valid hop is used unchanged")
        XCTAssertGreaterThan(AudioEnvelopeFollower.effectiveBlockSize(0), 0, "the effective hop is strictly positive")

        // Ceiling: an extreme hop must be capped so the pending buffer stays
        // bounded (it would otherwise never fill a block and grow forever).
        let maxB = AudioEnvelopeFollower.maximumBlockSize
        XCTAssertEqual(AudioEnvelopeFollower.effectiveBlockSize(Int.max), maxB, "Int.max hop must cap to the maximum")
        XCTAssertEqual(AudioEnvelopeFollower.effectiveBlockSize(maxB + 1), maxB, "just above the maximum caps down")
        XCTAssertEqual(AudioEnvelopeFollower.effectiveBlockSize(maxB), maxB, "the maximum itself is used unchanged")
        XCTAssertGreaterThan(maxB, minB, "the ceiling is above the floor")
    }

    // MARK: Configuration clamps every unsafe input at construction

    func testConfigurationClampsUnsafeBlockSize() {
        let minB = AudioEnvelopeFollower.minimumBlockSize
        XCTAssertGreaterThanOrEqual(AudioEnvelopeFollower.Configuration(blockSize: 0).blockSize, minB)
        XCTAssertGreaterThanOrEqual(AudioEnvelopeFollower.Configuration(blockSize: -100).blockSize, minB)
        XCTAssertGreaterThanOrEqual(AudioEnvelopeFollower.Configuration(blockSize: Int.min).blockSize, minB)
        // Extreme-large must be CLAMPED to the finite ceiling — NOT preserved.
        // Preserving Int.max lets `process` never fill a block and append the
        // pending buffer without bound (~192 KB/s until OOM). Assert the clamp,
        // not the identity (the old test blessed Int.max — a tautology).
        let maxB = AudioEnvelopeFollower.maximumBlockSize
        XCTAssertEqual(AudioEnvelopeFollower.Configuration(blockSize: Int.max).blockSize, maxB,
                       "Int.max blockSize must clamp to the ceiling, not be preserved")
        XCTAssertEqual(AudioEnvelopeFollower.Configuration(blockSize: maxB + 1).blockSize, maxB)
        XCTAssertLessThanOrEqual(AudioEnvelopeFollower.Configuration(blockSize: Int.max).blockSize, maxB,
                                 "no configured blockSize may exceed the ceiling")
    }

    func testConfigurationRejectsNonFiniteAndNegativeDoubles() {
        let c = AudioEnvelopeFollower.Configuration(
            attackSeconds: .nan, releaseSeconds: .infinity,
            noiseFloor: -.infinity, gain: .nan, blockSize: 0)
        XCTAssertTrue(c.attackSeconds.isFinite && c.attackSeconds > 0)
        XCTAssertTrue(c.releaseSeconds.isFinite && c.releaseSeconds > 0)
        XCTAssertTrue(c.noiseFloor.isFinite && c.noiseFloor >= 0 && c.noiseFloor <= 1)
        XCTAssertTrue(c.gain.isFinite && c.gain >= 0)
        XCTAssertGreaterThanOrEqual(c.blockSize, AudioEnvelopeFollower.minimumBlockSize)

        // Negative time constants clamp to a small positive value.
        let neg = AudioEnvelopeFollower.Configuration(attackSeconds: -5, releaseSeconds: -5, gain: -5)
        XCTAssertGreaterThan(neg.attackSeconds, 0)
        XCTAssertGreaterThan(neg.releaseSeconds, 0)
        XCTAssertGreaterThanOrEqual(neg.gain, 0)
    }

    // MARK: The configuration setter normalizes every replacement

    func testSetterNormalizesReplacementConfiguration() {
        let f = AudioEnvelopeFollower(sampleRate: sr)
        let minB = AudioEnvelopeFollower.minimumBlockSize

        // Install a series of extreme configurations through the PUBLIC mutation
        // path and confirm the stored value is always normalized in range.
        for bad in [0, -1, Int.min, minB - 1] {
            f.configuration = AudioEnvelopeFollower.Configuration(blockSize: bad)
            XCTAssertGreaterThanOrEqual(
                f.configuration.blockSize, minB,
                "replacement blockSize \(bad) must be normalized to >= \(minB)")
        }

        f.configuration = AudioEnvelopeFollower.Configuration(
            attackSeconds: .nan, releaseSeconds: -1, noiseFloor: 5, gain: -1, blockSize: 0)
        let stored = f.configuration
        XCTAssertTrue(stored.attackSeconds.isFinite && stored.attackSeconds > 0)
        XCTAssertTrue(stored.releaseSeconds.isFinite && stored.releaseSeconds > 0)
        XCTAssertTrue(stored.noiseFloor >= 0 && stored.noiseFloor <= 1)
        XCTAssertGreaterThanOrEqual(stored.gain, 0)
        XCTAssertGreaterThanOrEqual(stored.blockSize, minB)
    }

    // MARK: sampleRate validation

    func testSampleRateRejectsInvalidValues() {
        for bad in [0.0, -48_000.0, .nan, .infinity, -.infinity] as [Double] {
            let f = AudioEnvelopeFollower(sampleRate: bad)
            XCTAssertTrue(f.sampleRate.isFinite && f.sampleRate > 0,
                          "invalid sampleRate \(bad) must be replaced with a valid one")
        }
        // A valid rate is preserved.
        XCTAssertEqual(AudioEnvelopeFollower(sampleRate: 44_100).sampleRate, 44_100, accuracy: 1e-9)
    }

    // MARK: End-to-end — process TERMINATES and stays bounded under abuse

    /// Drive `process` with a large multi-packet signal after installing the most
    /// hostile configurations the public API allows, all under a wall-clock
    /// watchdog. Pre-fix, a `blockSize = 0` reachable through the mutable field
    /// would make this never return (infinite loop, unbounded `emitted`/callback
    /// growth); post-fix it completes quickly and the envelope stays finite.
    func testProcessTerminatesAndIsBoundedUnderExtremeConfig() throws {
        let f = AudioEnvelopeFollower(sampleRate: sr)

        // Worst case for spinning: smallest legal hop (max number of blocks), and
        // a config that went through every clamp via the public setter.
        f.configuration = AudioEnvelopeFollower.Configuration(
            attackSeconds: -1, releaseSeconds: -1, noiseFloor: -1, gain: 1e9,
            blockSize: 0) // normalized to the minimum hop

        // Count envelope callbacks — bounded output is the memory-safety proof.
        let counter = CallbackCounter()
        f.onEnvelope = { _ in counter.bump() }

        let done = DispatchSemaphore(value: 0)
        let work = DispatchQueue(label: "f10.process.watchdog")
        work.async {
            // ~2 seconds of loud audio in mixer-sized packets.
            let tone = EnvelopeFollowerSelfTest.sine(count: Int(self.sr * 2), amplitude: 0.9, sampleRate: self.sr)
            var idx = 0
            let packetFrames = 1024
            while idx < tone.count {
                let n = min(packetFrames, tone.count - idx)
                let slice = Array(tone[idx..<(idx + n)])
                if let packet = try? EnvelopeFollowerSelfTest.makeProgramPacket(
                    signal: slice, channelCount: 2, sampleRate: self.sr, startSample: idx) {
                    f.process(packet)
                }
                idx += n
            }
            done.signal()
        }

        // If the loop ever spins, this wait times out → test fails (no hang).
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "process must terminate — a zero/extreme hop must not hang the audio callback")

        // Bounded output: 2 s at a 32-frame hop is at most ~3000 blocks. A spinning
        // loop would produce (or try to allocate) unbounded updates; assert a sane cap.
        let count = counter.value
        XCTAssertGreaterThan(count, 0, "the follower did advance and emit")
        XCTAssertLessThan(count, 10_000, "envelope updates are bounded (no runaway growth)")
        XCTAssertTrue(f.openness.isFinite && f.openness >= 0 && f.openness <= 1,
                      "openness stays finite and in range under extreme gain")
    }

    // MARK: Extreme blockSize must not grow the pending buffer without bound

    /// Reproduction for the unbounded-memory finding: a **legal** `blockSize`
    /// of `Int.max` is set through the public API. Pre-fix `.normalized()` only
    /// FLOORED the hop, so `Int.max` was preserved; `process`'s block threshold
    /// (`pending.count >= Int.max`) is then never reached, so every packet is
    /// appended to `pending` forever — ~192 KB/s at 48 kHz mono until OOM. After
    /// the clamp, `pending` never exceeds a couple of analysis blocks.
    func testExtremeBlockSizeKeepsPendingBufferBounded() throws {
        let f = AudioEnvelopeFollower(sampleRate: sr)
        f.configuration = AudioEnvelopeFollower.Configuration(blockSize: .max)

        // Feed ~10 s of audio in mixer-sized packets — far past any sane hop.
        let totalFrames = Int(sr * 10)     // 480_000 mono frames fed
        let packetFrames = 1024
        var idx = 0
        while idx < totalFrames {
            let n = min(packetFrames, totalFrames - idx)
            let slice = EnvelopeFollowerSelfTest.sine(count: n, amplitude: 0.5, sampleRate: sr)
            if let packet = try? EnvelopeFollowerSelfTest.makeProgramPacket(
                signal: slice, channelCount: 2, sampleRate: sr, startSample: idx) {
                f.process(packet)
            }
            idx += n
        }

        // Independent bound (does not reference the ceiling constant): the buffer
        // must be a small fraction of what was fed. Pre-fix it holds ALL 480_000.
        let pending = f._test_pendingSampleCount
        XCTAssertLessThan(pending, 200_000,
            "pending buffer must stay bounded under Int.max blockSize (held \(pending) of \(totalFrames) fed)")
    }

    private final class CallbackCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
}
