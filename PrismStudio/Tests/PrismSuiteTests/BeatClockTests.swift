import AVFAudio
import PrismAudio
import XCTest
@testable import PrismSound

/// Deterministic tests for the beat-sync primitive: `BeatClock` phase math driven
/// by fixed host-time inputs (no real-time playback ⇒ no flakiness), plus the
/// `BeatSequencer` downbeat classification that the live `onBeat`/`onBar`
/// callbacks fire from.
final class BeatClockTests: XCTestCase {

    // 120 BPM ⇒ 0.5 s / beat; 4 beats / bar ⇒ 2.0 s / bar. Anchored away from 0.
    private let anchor = 1000.0
    private func clock120() -> BeatClock { BeatClock(bpm: 120, beatsPerBar: 4, anchorHostSeconds: anchor) }

    func testBeatAndBarSeconds() {
        let c = clock120()
        XCTAssertEqual(c.beatSeconds, 0.5, accuracy: 1e-12)
        XCTAssertEqual(c.barSeconds, 2.0, accuracy: 1e-12)
    }

    func testBeatPhaseAdvancesAndWraps() {
        let c = clock120()
        // 0 → 1 across the 0.5 s beat.
        XCTAssertEqual(c.beatPhase(atHostSeconds: anchor + 0.0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(c.beatPhase(atHostSeconds: anchor + 0.125), 0.25, accuracy: 1e-9)
        XCTAssertEqual(c.beatPhase(atHostSeconds: anchor + 0.25), 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.beatPhase(atHostSeconds: anchor + 0.375), 0.75, accuracy: 1e-9)
        XCTAssertEqual(c.beatPhase(atHostSeconds: anchor + 0.499), 0.998, accuracy: 1e-6)
        // Wrap: exactly one beat later phase returns to 0.
        XCTAssertEqual(c.beatPhase(atHostSeconds: anchor + 0.5), 0.0, accuracy: 1e-9)
        XCTAssertEqual(c.beatPhase(atHostSeconds: anchor + 0.625), 0.25, accuracy: 1e-9)
    }

    func testBeatPhaseMonotonicWithinBeat() {
        let c = clock120()
        var prev = -1.0
        var s = 0.0
        while s < 0.5 - 1e-9 {
            let ph = c.beatPhase(atHostSeconds: anchor + s)
            XCTAssertGreaterThan(ph, prev, "phase must rise within a beat (t=\(s))")
            prev = ph
            s += 0.01
        }
    }

    func testBeatIndexIncrementsOncePerBeat() {
        let c = clock120()
        var last = -1
        var distinct = 0
        // 4 s = 8 beats, sampled at 20 ms.
        for k in 0..<200 {
            let idx = c.beatIndex(atHostSeconds: anchor + Double(k) * 0.02)
            if idx != last {
                if last >= 0 { XCTAssertEqual(idx, last + 1, "beatIndex must step by exactly 1") }
                distinct += 1
                last = idx
            }
        }
        XCTAssertEqual(distinct, 8)
        XCTAssertEqual(last, 7)
    }

    func testBarPhaseSpansBarAndWraps() {
        let c = clock120()
        XCTAssertEqual(c.barPhase(atHostSeconds: anchor + 0.0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(c.barPhase(atHostSeconds: anchor + 1.0), 0.5, accuracy: 1e-9)   // half a 2 s bar
        XCTAssertEqual(c.barPhase(atHostSeconds: anchor + 1.5), 0.75, accuracy: 1e-9)
        XCTAssertEqual(c.barPhase(atHostSeconds: anchor + 2.0), 0.0, accuracy: 1e-9)   // bar line ⇒ wrap
        XCTAssertEqual(c.barIndex(atHostSeconds: anchor + 1.0), 0)
        XCTAssertEqual(c.barIndex(atHostSeconds: anchor + 2.0), 1)
        XCTAssertEqual(c.barIndex(atHostSeconds: anchor + 4.0), 2)
    }

    func testPhaseContinuousAcrossBarLine() {
        // Single continuous clock ⇒ no discontinuity at the bar boundary.
        let c = clock120()
        let before = c.beatPhase(atHostSeconds: anchor + 2.0 - 1e-5)
        let after = c.beatPhase(atHostSeconds: anchor + 2.0 + 1e-5)
        XCTAssertGreaterThan(before, 0.9999)
        XCTAssertLessThan(after, 0.0001)
    }

    func testStoppedAndZeroBPMAreGraceful() {
        for c in [BeatClock.stopped, BeatClock(bpm: 0, beatsPerBar: 4, anchorHostSeconds: anchor)] {
            XCTAssertEqual(c.beatPhase(atHostSeconds: anchor + 3.7), 0.0)
            XCTAssertEqual(c.barPhase(atHostSeconds: anchor + 3.7), 0.0)
            XCTAssertEqual(c.beatIndex(atHostSeconds: anchor + 3.7), 0)
            XCTAssertEqual(c.barIndex(atHostSeconds: anchor + 3.7), 0)
        }
    }

    func testBeforeAnchorReadsZero() {
        let c = clock120()
        XCTAssertEqual(c.beatPhase(atHostSeconds: anchor - 5.0), 0.0)
        XCTAssertEqual(c.beatIndex(atHostSeconds: anchor - 5.0), 0)
    }

    func testNonFiniteBPMIsStopped() {
        let c = BeatClock(bpm: .infinity, beatsPerBar: 4, anchorHostSeconds: anchor)
        XCTAssertEqual(c.beatSeconds, 0)
        XCTAssertEqual(c.beatPhase(atHostSeconds: anchor + 1.0), 0.0)
    }

    func testBeatsPerBarClampedAtLeastOne() {
        let c = BeatClock(bpm: 120, beatsPerBar: 0, anchorHostSeconds: anchor)
        XCTAssertEqual(c.beatsPerBar, 1)
        XCTAssertEqual(c.barSeconds, 0.5, accuracy: 1e-12)   // 1 beat/bar
    }

    // MARK: Swing — the sequencer, not the clock, carries swing.

    func testSwingDelaysOddSixteenthsLeavesDownbeatsOnGrid() {
        let p = BeatPattern(bpm: 120, swing: 0.6, stepCount: 16)
        let step = p.stepSeconds
        XCTAssertEqual(p.onsetSeconds(step: 0, bar: 0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(p.onsetSeconds(step: 1, bar: 0), step + 0.6 * step, accuracy: 1e-9) // odd ⇒ swung
        XCTAssertEqual(p.onsetSeconds(step: 2, bar: 0), 2 * step, accuracy: 1e-9)          // even ⇒ on-grid
        XCTAssertEqual(p.onsetSeconds(step: 3, bar: 0), 3 * step + 0.6 * step, accuracy: 1e-9)
        // Every quarter-note downbeat (steps 0,4,8,12) is even ⇒ unswung.
        for beatStep in [0, 4, 8, 12] {
            XCTAssertEqual(p.onsetSeconds(step: beatStep, bar: 0), Double(beatStep) * step, accuracy: 1e-9,
                           "downbeat at step \(beatStep) must not be swung")
        }
    }

    // MARK: onBeat / onBar downbeat classification (what the live scheduler fires).

    func testBeatInfoClassifiesDownbeats() {
        // 16-step 4/4: beats at global steps 0,4,8,12,16,…; bars at 0,16,32,…
        XCTAssertNil(BeatSequencer.beatInfo(forGlobalStep: 1, stepCount: 16))
        XCTAssertNil(BeatSequencer.beatInfo(forGlobalStep: 5, stepCount: 16))
        let b0 = BeatSequencer.beatInfo(forGlobalStep: 0, stepCount: 16)
        XCTAssertEqual(b0?.beatIndex, 0); XCTAssertEqual(b0?.barIndex, 0); XCTAssertEqual(b0?.firstBeatOfBar, true)
        let b1 = BeatSequencer.beatInfo(forGlobalStep: 4, stepCount: 16)
        XCTAssertEqual(b1?.beatIndex, 1); XCTAssertEqual(b1?.barIndex, 0); XCTAssertEqual(b1?.firstBeatOfBar, false)
        let b4 = BeatSequencer.beatInfo(forGlobalStep: 16, stepCount: 16)
        XCTAssertEqual(b4?.beatIndex, 4); XCTAssertEqual(b4?.barIndex, 1); XCTAssertEqual(b4?.firstBeatOfBar, true)
    }

    /// Drive the SAME lookahead cursor the live clock uses and apply `beatInfo` —
    /// asserts onBeat/onBar fire exactly once per beat, in order, across N bars.
    /// Swing (0.3) is present to prove downbeats fire regardless.
    func testOnBeatFiresOncePerBeatViaScheduler() {
        let bars = 3
        let pat = BeatPattern(bpm: 140, swing: 0.3, stepCount: 16)
        // Drain exactly `bars` bars — up to (but not including) the downbeat that
        // *starts* the next bar, which the cursor emits at onset == barSeconds*bars.
        let target = pat.barSeconds * Double(bars)
        var cursor = BeatScheduleCursor()
        var beats: [Int] = []
        var barFirsts: [Int] = []
        var horizon = 0.0
        while horizon < target {                       // coarse steps, mirroring the live wake
            horizon = min(horizon + 0.05, target)
            for onset in cursor.drain(pattern: pat, upTo: horizon) {
                if let bi = BeatSequencer.beatInfo(forGlobalStep: onset.globalStep, stepCount: pat.safeStepCount) {
                    beats.append(bi.beatIndex)
                    if bi.firstBeatOfBar { barFirsts.append(bi.barIndex) }
                }
            }
        }
        XCTAssertEqual(beats, Array(0..<(4 * bars)))   // once each, in order
        XCTAssertEqual(barFirsts, Array(0..<bars))
    }

    // MARK: F1 — onBeat/onBar fire at the audio onset host-time, not lookahead-early.

    /// The bug: the drain loop invoked onBeat/onBar inline when it DRAINED an onset,
    /// which happens up to `lookahead` (~50 ms) before the onset's real host time, so
    /// callbacks led the audio. The fix schedules each callback (via asyncAfter) at
    /// the SAME host time the audio sample is scheduled at. We assert the *pure*
    /// onset→fire-time mapping (`onsetHostTime`) equals the audio onset host-time for
    /// every onset — deterministic, no wall-clock timing. (Real elapsed delivery is
    /// only structurally verified: same deadline domain as the audio schedule.)
    func testBeatCallbackScheduledAtAudioOnsetHostTimeNotEarly() {
        let startHostTicks: UInt64 = 1_000_000_000
        let lookahead = 0.05
        let pat = BeatPattern(bpm: 128, swing: 0.4, stepCount: 16)   // swing present
        var cursor = BeatScheduleCursor()
        let onsets = cursor.drain(pattern: pat, upTo: pat.barSeconds * 2)   // 2 bars
        XCTAssertFalse(onsets.isEmpty)

        var lastFire: UInt64 = 0
        var beatCount = 0
        for onset in onsets {
            // The audio layer schedules the sample at exactly this host time
            // (BeatSequencer.play), so the callback must match it.
            let audioHost = startHostTicks &+ AVAudioTime.hostTime(forSeconds: onset.onsetSeconds)
            let fireHost = BeatSequencer.onsetHostTime(startHostTicks: startHostTicks,
                                                       onsetSeconds: onset.onsetSeconds)
            XCTAssertEqual(fireHost, audioHost,
                           "beat callback host-time must equal the audio onset host-time")

            // It maps back to the onset's own time — NOT the (onset − lookahead)
            // drain time it used to fire at.
            let recovered = AVAudioTime.seconds(forHostTime: fireHost &- startHostTicks)
            XCTAssertEqual(recovered, onset.onsetSeconds, accuracy: 1e-6)
            if onset.onsetSeconds > lookahead {
                let earlyDrainHost = startHostTicks &+
                    AVAudioTime.hostTime(forSeconds: onset.onsetSeconds - lookahead)
                XCTAssertGreaterThan(fireHost, earlyDrainHost,
                                     "fire time must be the onset, not ~lookahead early")
            }
            // Monotonic fire times ⇒ the serial clock queue delivers beats in order.
            XCTAssertGreaterThanOrEqual(fireHost, lastFire)
            lastFire = fireHost

            if BeatSequencer.beatInfo(forGlobalStep: onset.globalStep,
                                      stepCount: pat.safeStepCount) != nil { beatCount += 1 }
        }
        XCTAssertEqual(beatCount, 8)   // 2 bars × 4 beats, each classified exactly once
    }

    /// The DispatchTime deadline used for the callback is derived from the same host
    /// time as the audio — same monotonic domain, so it lands with the sound.
    func testDispatchDeadlineRoundTripsHostTime() {
        let startHostTicks: UInt64 = 5_000_000_000
        let host = BeatSequencer.onsetHostTime(startHostTicks: startHostTicks, onsetSeconds: 0.375)
        let deadline = BeatSequencer.dispatchDeadline(forHostTime: host)
        let backSeconds = Double(deadline.uptimeNanoseconds) / 1_000_000_000
        let hostSeconds = AVAudioTime.seconds(forHostTime: host)
        XCTAssertEqual(backSeconds, hostSeconds, accuracy: 1e-6)
    }

    // MARK: F2 — barPhase / onBar agree for stepCounts that aren't multiples of 4.

    /// Before the fix `beatsPerBar = stepCount / 4` integer-truncated (e.g. 14 → 3),
    /// so `BeatClock.barPhase`/`barIndex` described a 3-beat bar while the real loop
    /// and `onBar` (g % stepCount) used a 14-step bar. `safeStepCount` now snaps the
    /// loop to a whole number of beats, so the two ALWAYS describe the same bar.
    func testBarPhaseAndOnBarAgreeForNonMultipleOfFourStepCount() {
        for raw in [13, 14, 15, 18, 22] {
            let pat = BeatPattern(bpm: 120, swing: 0, stepCount: raw)
            let sc = pat.safeStepCount
            XCTAssertEqual(sc % BeatSequencer.sixteenthsPerBeat, 0,
                           "safeStepCount (\(sc)) must be a whole number of beats [raw \(raw)]")

            // Build the clock exactly as BeatSequencer.beatClock does.
            let bpb = max(1, sc / BeatSequencer.sixteenthsPerBeat)
            let anchor = 500.0
            let clock = BeatClock(bpm: pat.safeBPM, beatsPerBar: bpb, anchorHostSeconds: anchor)

            // onBar fires every `sc` sixteenths ⇒ its bar length in seconds…
            let barSecondsFromLoop = Double(sc) * pat.stepSeconds
            // …must equal the clock's bar length (no truncation disagreement).
            XCTAssertEqual(clock.barSeconds, barSecondsFromLoop, accuracy: 1e-12,
                           "BeatClock bar must equal the sequencer loop [raw \(raw), sc \(sc)]")

            // barPhase wraps to 0 at every onBar downbeat and reads 0.5 mid-bar.
            for barIdx in 0..<4 {
                let tBar = anchor + Double(barIdx) * barSecondsFromLoop
                XCTAssertEqual(clock.barPhase(atHostSeconds: tBar + 1e-9), 0.0, accuracy: 1e-6,
                               "barPhase ~0 at onBar downbeat (bar \(barIdx), raw \(raw))")
                XCTAssertEqual(clock.barIndex(atHostSeconds: tBar + 1e-9), barIdx)
                let tHalf = tBar + barSecondsFromLoop / 2
                XCTAssertEqual(clock.barPhase(atHostSeconds: tHalf), 0.5, accuracy: 1e-6)
            }

            // And the discrete classifier: firstBeatOfBar exactly at multiples of sc.
            for g in stride(from: 0, to: sc * 3, by: BeatSequencer.sixteenthsPerBeat) {
                let info = BeatSequencer.beatInfo(forGlobalStep: g, stepCount: sc)
                XCTAssertEqual(info?.firstBeatOfBar, g % sc == 0,
                               "onBar/barPhase disagree at g=\(g) [raw \(raw), sc \(sc)]")
            }
        }
    }

    // MARK: Sequencer beatClock plumbing (no audio required).

    func testSequencerBeatClockStoppedByDefault() throws {
        let seq = try makeSilentSequencer()
        try seq.load(pattern: BeatSequencer.basicPattern(kick: kickID, snare: snareID, hat: hatID, bpm: 128))
        // Not playing ⇒ stopped clock, phase 0.
        XCTAssertEqual(seq.beatClock, .stopped)
        XCTAssertEqual(seq.beatPhase(), 0.0)
        XCTAssertEqual(seq.barPhase(), 0.0)
    }

    // MARK: helpers

    private let kickID = "k", snareID = "s", hatID = "h"

    /// A sequencer whose track buffers are pre-registered synth buffers, so no
    /// SoundLibrary/disk is needed. We never call `startLive()`/`play()` here, so
    /// no audio hardware is touched.
    private func makeSilentSequencer() throws -> BeatSequencer {
        let mixer = AudioMixer(configuration: AudioMixer.Configuration())
        let seq = try BeatSequencer(mixer: mixer, library: nil)
        for id in [kickID, snareID, hatID] {
            if let buf = AVAudioPCMBuffer(pcmFormat: SamplePlaybackEngine.internalFormat, frameCapacity: 64) {
                buf.frameLength = 64
                seq.registerBuffer(id: id, buffer: buf)
            }
        }
        return seq
    }
}
