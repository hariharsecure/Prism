import CoreMedia
import XCTest

import PrismAudio
import PrismCore

/// Deterministic verification of `TransientDetector` (Sources/PrismAudio).
///
/// Every signal is synthesised (no real time, no hardware) and fed through the
/// detector in mixer-sized packets via `TransientSelfTest.run(detector:signal:)`.
/// Asserts: N clicks → N fires at the right times with monotonic strength;
/// steady tone / noise / silence → zero fires; two hits inside the debounce →
/// one fire; a slow swell → no sharp-onset fires.
final class TransientDetectorTests: XCTestCase {

    private let sr = 48_000.0
    private lazy var blockSec = 512.0 / sr

    // MARK: N clicks → N fires, right times, louder = stronger

    func testClicksFireExactlyAtKnownPositions() throws {
        let total = Int(sr) // 1 second
        let positions = [Int(0.15 * sr), Int(0.45 * sr), Int(0.75 * sr)]
        let amps: [Float] = [0.9, 0.5, 0.3]
        let signal = TransientSelfTest.bedWithClicks(
            totalSamples: total, bedAmplitude: 0.02,
            clicks: zip(positions, amps).map { ($0.0, $0.1, 256) },
            sampleRate: sr)

        let det = TransientDetector(sampleRate: sr)
        let fires = try TransientSelfTest.run(detector: det, signal: signal, sampleRate: sr)

        report("clicks", fires, expected: positions.map { Double($0) / sr })
        XCTAssertEqual(fires.count, 3, "expected one fire per click")

        for (fire, pos) in zip(fires, positions) {
            let expected = Double(pos) / sr
            XCTAssertEqual(fire.hostSeconds, expected, accuracy: 2 * blockSec,
                           "fire should land within a block of its click")
        }
        // Louder hit → higher strength.
        XCTAssertGreaterThan(fires[0].strength, fires[1].strength)
        XCTAssertGreaterThan(fires[1].strength, fires[2].strength)
        // Strengths are normalised 0…1.
        for f in fires { XCTAssertTrue(f.strength > 0 && f.strength <= 1) }
        // PTS matches hostSeconds.
        for f in fires { XCTAssertEqual(f.pts.seconds, f.hostSeconds, accuracy: 1e-6) }
    }

    // MARK: Steady tone / noise / silence → zero false positives

    func testSteadyToneNoFire() throws {
        let signal = TransientSelfTest.sine(count: Int(sr), amplitude: 0.5, frequency: 440, sampleRate: sr)
        let det = TransientDetector(sampleRate: sr)
        let fires = try TransientSelfTest.run(detector: det, signal: signal, sampleRate: sr)
        report("steady tone", fires, expected: [])
        XCTAssertEqual(fires.count, 0, "a steady tone is not an onset")
    }

    func testSteadyNoiseNoFire() throws {
        let signal = TransientSelfTest.noise(count: Int(sr), amplitude: 0.3)
        let det = TransientDetector(sampleRate: sr)
        let fires = try TransientSelfTest.run(detector: det, signal: signal, sampleRate: sr)
        report("steady noise", fires, expected: [])
        XCTAssertEqual(fires.count, 0, "steady noise must not false-trigger")
    }

    func testSilenceNoFire() throws {
        let signal = [Float](repeating: 0, count: Int(sr))
        let det = TransientDetector(sampleRate: sr)
        let fires = try TransientSelfTest.run(detector: det, signal: signal, sampleRate: sr)
        report("silence", fires, expected: [])
        XCTAssertEqual(fires.count, 0, "silence must not fire")
    }

    // MARK: Debounce collapses close hits

    func testDebounceCollapsesCloseHits() throws {
        let total = Int(sr)
        let signal = TransientSelfTest.bedWithClicks(
            totalSamples: total, bedAmplitude: 0.02,
            clicks: [(Int(0.30 * sr), 0.8, 256), (Int(0.34 * sr), 0.8, 256)], // 40 ms apart
            sampleRate: sr)

        var cfg = TransientDetector.Configuration()
        cfg.minIntervalSeconds = 0.15 // 150 ms > 40 ms gap
        let det = TransientDetector(sampleRate: sr, configuration: cfg)
        let fires = try TransientSelfTest.run(detector: det, signal: signal, sampleRate: sr)

        report("debounce (two hits 40ms apart, 150ms min-interval)", fires, expected: [0.30])
        XCTAssertEqual(fires.count, 1, "two hits within the debounce collapse to one")
    }

    /// The same two hits, but spaced *beyond* the debounce, fire twice.
    func testHitsBeyondDebounceFireTwice() throws {
        let total = Int(sr)
        let signal = TransientSelfTest.bedWithClicks(
            totalSamples: total, bedAmplitude: 0.02,
            clicks: [(Int(0.30 * sr), 0.8, 256), (Int(0.60 * sr), 0.8, 256)], // 300 ms apart
            sampleRate: sr)

        var cfg = TransientDetector.Configuration()
        cfg.minIntervalSeconds = 0.10
        let det = TransientDetector(sampleRate: sr, configuration: cfg)
        let fires = try TransientSelfTest.run(detector: det, signal: signal, sampleRate: sr)

        report("beyond-debounce (300ms apart)", fires, expected: [0.30, 0.60])
        XCTAssertEqual(fires.count, 2, "hits spaced beyond the debounce both fire")
    }

    // MARK: Slow swell → not an onset

    func testSlowSwellFewOrNoFires() throws {
        let signal = TransientSelfTest.swell(count: Int(sr), peakAmplitude: 0.8, frequency: 220, sampleRate: sr)
        let det = TransientDetector(sampleRate: sr)
        let fires = try TransientSelfTest.run(detector: det, signal: signal, sampleRate: sr)
        report("slow swell", fires, expected: [])
        // C5 (STRICT): the crest-factor gate makes a smooth swell impossible to
        // fire. Pre-fix, the baseline lagged the ramp and tripped the ratio test.
        XCTAssertEqual(fires.count, 0, "a gradual swell has no sharp onset")
    }

    // MARK: C6 — a genuine opening hit in the FIRST block fires once

    func testFirstBlockOnsetFires() throws {
        // A sharp click entirely inside the first analysis block over silence.
        // Pre-fix, the first block only SEEDED the baseline → this click was missed
        // (0 fires). Post-fix, the first block is evaluated → exactly one fire.
        let total = Int(sr) / 4
        let signal = TransientSelfTest.bedWithClicks(
            totalSamples: total, bedAmplitude: 0.0,
            clicks: [(20, 0.8, 256)], sampleRate: sr)
        let det = TransientDetector(sampleRate: sr)
        let fires = try TransientSelfTest.run(detector: det, signal: signal, sampleRate: sr)
        report("first-block onset", fires, expected: [0.0])
        XCTAssertEqual(fires.count, 1, "an opening hit inside the first block must fire once")
        XCTAssertLessThan(fires[0].hostSeconds, blockSec, "the opening fire lands in the first block")
    }

    // MARK: C7 — a PTS gap with leftover samples re-times to house time

    func testPTSGapRetimesFiresToHouseTime() throws {
        let det = TransientDetector(sampleRate: sr)
        let box = FireCollector()
        det.onTransient = { box.append($0) }

        // Pre-gap: quiet bed fed in NON-block-multiple (700-frame) packets, leaving
        // a partial block buffered (so the head-PTS can't trivially re-sync).
        let bed = TransientSelfTest.sine(count: 700, amplitude: 0.02, frequency: 220, sampleRate: sr)
        var start = 0
        for _ in 0..<5 {
            let pkt = try TransientSelfTest.makeProgramPacket(
                signal: bed, channelCount: 2, sampleRate: sr, startSample: start)
            det.process(pkt)
            start += 700
        }
        // Intentional PTS discontinuity: jump far ahead, with a click at the head.
        let gapStart = 100_000
        let clickBuf = TransientSelfTest.bedWithClicks(
            totalSamples: 1024, bedAmplitude: 0.0, clicks: [(10, 0.8, 256)], sampleRate: sr)
        let gapPkt = try TransientSelfTest.makeProgramPacket(
            signal: clickBuf, channelCount: 2, sampleRate: sr, startSample: gapStart)
        det.process(gapPkt)
        det.onTransient = nil

        let fires = box.drain()
        report("PTS gap", fires, expected: [Double(gapStart) / sr])
        XCTAssertEqual(fires.count, 1, "the post-gap click fires once")
        // Pre-fix this reported ~0.06s (the stale pre-gap timeline); post-fix it is
        // reported at the NEW house time (~2.083s).
        XCTAssertEqual(fires[0].hostSeconds, Double(gapStart) / sr, accuracy: 3 * blockSec,
                       "post-gap fire is reported at the incoming house time, not the stale timeline")
    }

    // MARK: C8 — a padded interleaved ASBD is rejected safely

    func testPaddedInterleavedRejectedSafely() throws {
        let frames = 2048
        let signal = TransientSelfTest.bedWithClicks(
            totalSamples: frames, bedAmplitude: 0.0, clicks: [(200, 0.9, 256)], sampleRate: sr)

        // Padded stride (mBytesPerFrame = channels*4 + 4, not packed) → unsupported.
        let padded = try TransientSelfTest.makePaddedInterleavedPacket(
            signal: signal, channelCount: 2, sampleRate: sr, startSample: 0)
        let detP = TransientDetector(sampleRate: sr)
        let boxP = FireCollector(); detP.onTransient = { boxP.append($0) }
        detP.process(padded); detP.onTransient = nil
        XCTAssertEqual(boxP.drain().count, 0,
                       "a padded interleaved ASBD must be safely rejected (no mis-indexed fire/crash)")

        // The SAME click as a PACKED interleaved packet DOES fire — proving the
        // guard rejects the unsupported stride specifically, not the content.
        let packed = try TransientSelfTest.makeProgramPacket(
            signal: signal, channelCount: 2, sampleRate: sr, startSample: 0)
        let detOK = TransientDetector(sampleRate: sr)
        let boxOK = FireCollector(); detOK.onTransient = { boxOK.append($0) }
        detOK.process(packed); detOK.onTransient = nil
        XCTAssertEqual(boxOK.drain().count, 1, "the packed equivalent fires once")
    }

    /// Thread-safe collector for fired transients.
    private final class FireCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var fires: [TransientInfo] = []
        func append(_ i: TransientInfo) { lock.lock(); fires.append(i); lock.unlock() }
        func drain() -> [TransientInfo] { lock.lock(); defer { lock.unlock() }; return fires }
    }

    // MARK: reset() clears running stats

    func testResetClearsState() throws {
        let total = Int(sr) / 2
        let signal = TransientSelfTest.bedWithClicks(
            totalSamples: total, bedAmplitude: 0.02,
            clicks: [(Int(0.20 * sr), 0.8, 256)], sampleRate: sr)
        let det = TransientDetector(sampleRate: sr)
        let first = try TransientSelfTest.run(detector: det, signal: signal, sampleRate: sr)
        XCTAssertEqual(first.count, 1)
        det.reset()
        // After reset, feeding the same signal fires the same way (no leftover
        // baseline/timeline from the previous run).
        let second = try TransientSelfTest.run(detector: det, signal: signal, sampleRate: sr)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(first[0].hostSeconds, second[0].hostSeconds, accuracy: 1e-9)
    }

    // MARK: helpers

    private func report(_ label: String, _ fires: [TransientInfo], expected: [Double]) {
        let times = fires.map { String(format: "%.3f", $0.hostSeconds) }.joined(separator: ", ")
        let strengths = fires.map { String(format: "%.2f", $0.strength) }.joined(separator: ", ")
        let exp = expected.map { String(format: "%.3f", $0) }.joined(separator: ", ")
        print("  [\(label)] fires=\(fires.count) times=[\(times)] strength=[\(strengths)] expected≈[\(exp)]")
    }
}
