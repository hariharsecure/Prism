import CoreMedia
import XCTest

import PrismAudio
import PrismCore

/// Deterministic verification of `AudioEnvelopeFollower` (Sources/PrismAudio) —
/// the audio side of character lip-sync (program loudness → mouth-openness 0…1).
///
/// Every signal is synthesised (no real time, no hardware) and fed through the
/// follower in mixer-sized packets via `EnvelopeFollowerSelfTest.trace(...)`,
/// which returns the per-block openness trace. Asserts: silence → ≈ 0; a quiet
/// bed under the noise floor → ≈ 0 (gate); a loud sustained tone → rises toward
/// ~1 and stays high; attack (rise-time) is faster than release (fall-time); and
/// the output is continuous (bounded per-block slew, never an instant jump).
final class AudioEnvelopeFollowerTests: XCTestCase {

    private let sr = 48_000.0
    private lazy var blockSec = 512.0 / sr

    // MARK: Silence → closed mouth

    func testSilenceStaysClosed() throws {
        let f = AudioEnvelopeFollower(sampleRate: sr)
        let tr = try EnvelopeFollowerSelfTest.trace(
            follower: f, signal: [Float](repeating: 0, count: Int(sr)), sampleRate: sr)
        let maxV = tr.max() ?? 0
        print(String(format: "  [silence] max openness=%.6f polled=%.6f", maxV, f.openness))
        XCTAssertLessThan(maxV, 1e-4, "silence must read as a closed mouth")
        XCTAssertLessThan(f.openness, 1e-4, "polled openness after silence is ≈ 0")
    }

    // MARK: Quiet bed under the noise floor → gated to ≈ 0

    func testQuietBedGatedClosed() throws {
        let f = AudioEnvelopeFollower(sampleRate: sr) // default noiseFloor 0.010
        // amplitude 0.008 → RMS ≈ 0.0057, below the 0.010 floor.
        let bed = EnvelopeFollowerSelfTest.sine(count: Int(sr), amplitude: 0.008, sampleRate: sr)
        let tr = try EnvelopeFollowerSelfTest.trace(follower: f, signal: bed, sampleRate: sr)
        let maxV = tr.max() ?? 0
        print(String(format: "  [quiet bed] max openness=%.6f (RMS≈0.0057 < floor 0.010)", maxV))
        XCTAssertLessThan(maxV, 1e-3, "a quiet-room bed under the floor must stay closed")
    }

    // MARK: Loud sustained tone → opens toward ~1 and stays high

    func testLoudToneOpensAndHolds() throws {
        let f = AudioEnvelopeFollower(sampleRate: sr)
        let tone = EnvelopeFollowerSelfTest.sine(count: Int(sr), amplitude: 0.7, sampleRate: sr)
        let tr = try EnvelopeFollowerSelfTest.trace(follower: f, signal: tone, sampleRate: sr)
        let steady = tr.suffix(20).reduce(0, +) / 20.0
        print(String(format: "  [loud tone] steady openness=%.4f polled=%.4f", steady, f.openness))
        XCTAssertGreaterThan(steady, 0.9, "a loud sustained tone opens the mouth wide")
        XCTAssertGreaterThan(f.openness, 0.9, "polled openness stays high during the tone")
        XCTAssertLessThanOrEqual(steady, 1.0, "openness is clamped to 1")
    }

    // MARK: Attack faster than release (burst then silence)

    func testAttackFasterThanRelease() throws {
        let f = AudioEnvelopeFollower(sampleRate: sr)
        // 100 ms silence, 300 ms loud burst, 400 ms trailing silence.
        let sig = EnvelopeFollowerSelfTest.onset(
            silence: Int(0.10 * sr), burst: Int(0.30 * sr), burstAmplitude: 0.7, sampleRate: sr)
            + [Float](repeating: 0, count: Int(0.40 * sr))
        let tr = try EnvelopeFollowerSelfTest.trace(follower: f, signal: sig, sampleRate: sr)

        let peak = tr.max() ?? 0
        let peakIdx = tr.firstIndex(of: peak) ?? 0

        // Rise: measured from the onset block (silence occupies the first ~100 ms).
        let onsetBlock = Int((0.10 * sr) / 512.0)
        let burstTrace = Array(tr[onsetBlock...])
        let rise = EnvelopeFollowerSelfTest.riseTime(
            burstTrace, steady: peak, fraction: 0.9, blockSeconds: blockSec)
        // Fall: from the peak down to 10% of it.
        let fall = EnvelopeFollowerSelfTest.fallTime(
            tr, from: peakIdx, peak: peak, fraction: 0.1, blockSeconds: blockSec)

        let riseV = try XCTUnwrap(rise, "openness should reach 90% during the burst")
        let fallV = try XCTUnwrap(fall, "openness should decay to 10% during the trailing silence")
        print(String(format: "  [attack/release] peak=%.3f rise(10→90%%→0.9·peak)=%.1fms fall(→0.1·peak)=%.1fms",
                     peak, riseV * 1000, fallV * 1000))
        XCTAssertLessThan(riseV, fallV, "attack must be faster than release (mouth opens promptly, closes slowly)")
    }

    // MARK: Continuous / slew-limited (no per-block jump straight to full)

    func testOpennessIsContinuous() throws {
        let f = AudioEnvelopeFollower(sampleRate: sr)
        // A hard step into a loud tone: the worst case for an instant jump.
        let sig = EnvelopeFollowerSelfTest.onset(
            silence: Int(0.05 * sr), burst: Int(0.45 * sr), burstAmplitude: 0.9, sampleRate: sr)
        let tr = try EnvelopeFollowerSelfTest.trace(follower: f, signal: sig, sampleRate: sr)

        var maxStep = 0.0
        for i in 1..<tr.count { maxStep = max(maxStep, abs(tr[i] - tr[i - 1])) }
        print(String(format: "  [continuity] max per-block step=%.4f over %d blocks", maxStep, tr.count))
        // One-pole attack (τ=20ms, hop≈10.7ms) moves ≈41% of the remaining distance
        // per block — well under a full jump. Assert a comfortable bound.
        XCTAssertLessThan(maxStep, 0.5, "the envelope is slew-limited, not an instant jump to full")
        XCTAssertGreaterThan(maxStep, 0.0, "the envelope does move")
    }

    // MARK: reset() closes the mouth and clears state

    func testResetClosesAndClears() throws {
        let f = AudioEnvelopeFollower(sampleRate: sr)
        let tone = EnvelopeFollowerSelfTest.sine(count: Int(sr) / 2, amplitude: 0.7, sampleRate: sr)
        _ = try EnvelopeFollowerSelfTest.trace(follower: f, signal: tone, sampleRate: sr)
        XCTAssertGreaterThan(f.openness, 0.9, "tone opened the mouth")
        f.reset()
        XCTAssertEqual(f.openness, 0.0, accuracy: 1e-9, "reset closes the mouth")

        // After reset the same tone reproduces the same steady value (no leftover state).
        let a = try EnvelopeFollowerSelfTest.trace(follower: f, signal: tone, sampleRate: sr)
        f.reset()
        let b = try EnvelopeFollowerSelfTest.trace(follower: f, signal: tone, sampleRate: sr)
        XCTAssertEqual(a.last!, b.last!, accuracy: 1e-9, "deterministic across resets")
    }

    // MARK: The runnable self-test passes end to end

    func testSelfTestSuitePasses() throws {
        XCTAssertNoThrow(try EnvelopeFollowerSelfTest.run())
    }
}
