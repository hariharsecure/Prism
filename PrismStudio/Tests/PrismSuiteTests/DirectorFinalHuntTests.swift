import CoreMedia
import XCTest
@testable import PrismDirector
import PrismCore

/// Final-hunt fixes in `PrismDirector`:
///  - L1: a source that emits a non-finite-PTS signal then vanishes must NOT stay
///    a cut target forever (`AutoDirector` staleness filter + `DirectorController`
///    prune).
///  - M4: `HighlightDirector` must bound the in-window event buffer under a burst
///    (coalesce same-instant + count cap), keeping scoring correct.
///  - M2 (functional): `DirectorController.activeSource` still reflects the
///    committed source after the lock was added to its read.
///
/// Every test drives the pure engines with scripted signals (no Vision/pixels)
/// and checks against a hand-computed expectation — never the engine judging
/// itself.
final class DirectorFinalHuntTests: XCTestCase {

    private func pts(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }
    private func sid(_ s: String) -> SourceID { SourceID(s) }

    /// A high-activity signal (loud audio) for `source` at time `t`.
    private func loud(_ source: String, _ t: Double, level: Float = 0.95) -> SourceSignal {
        SourceSignal(source: sid(source), pts: pts(t), audioLevel: level)
    }

    /// A high-activity signal with a NON-FINITE PTS (the L1 failure input).
    private func loudNonFinite(_ source: String, _ ptsSeconds: Double, level: Float = 0.95) -> SourceSignal {
        SourceSignal(source: sid(source), pts: CMTime(seconds: ptsSeconds, preferredTimescale: 600),
                     audioLevel: level)
    }

    // MARK: - L1: non-finite-PTS dead source is not cuttable (AutoDirector)

    /// REPRODUCE: without the fix, a source that emitted a single NaN/inf-PTS
    /// signal (which can't be aged out) out-ranks the live active source forever.
    /// With the fix a non-finite-PTS signal is treated as stale/ineligible, so the
    /// live source keeps the program.
    func testNonFinitePTSSignalIsNotCuttable() {
        let cfg = AutoDirectorConfig(sensitivity: 0.5, minShotSeconds: 0.1,
                                     leadWindowSeconds: 0.1, cutCooldownSeconds: 0.1,
                                     stalenessSeconds: 1.0)
        let d = AutoDirector(config: cfg)

        // Acquire A on program with finite time.
        _ = d.ingest([loud("A", 0.0)])
        XCTAssertEqual(d.currentActiveSource, sid("A"))

        // B emits ONE inf-PTS signal (higher activity), then time marches on with A
        // still live. B must never become cuttable off a non-finite PTS.
        let inf = Double.infinity
        for t in stride(from: 1.0, through: 5.0, by: 0.25) {
            let decision = d.ingest([loud("A", t, level: 0.4),
                                     loudNonFinite("B", inf, level: 1.0)])
            XCTAssertNil(decision, "a non-finite-PTS source must not trigger a cut (t=\(t))")
        }
        XCTAssertEqual(d.currentActiveSource, sid("A"), "program must stay on the live source A")
    }

    /// A NaN PTS is likewise ineligible (the other non-finite form).
    func testNaNPTSSignalIsIneligible() {
        let cfg = AutoDirectorConfig(minShotSeconds: 0.1, leadWindowSeconds: 0.1, cutCooldownSeconds: 0.1)
        let d = AutoDirector(config: cfg)
        _ = d.ingest([loud("A", 0.0)])
        for t in stride(from: 1.0, through: 4.0, by: 0.25) {
            _ = d.ingest([loud("A", t, level: 0.3), loudNonFinite("B", Double.nan, level: 1.0)])
        }
        XCTAssertEqual(d.currentActiveSource, sid("A"))
    }

    /// NEGATIVE CONTROL: a genuine finite-PTS decisive lead STILL cuts — the L1
    /// fix must not suppress legitimate switching.
    func testFinitePTSDecisiveLeadStillCuts() {
        let cfg = AutoDirectorConfig(sensitivity: 0.8, minShotSeconds: 0.1,
                                     leadWindowSeconds: 0.1, cutCooldownSeconds: 0.1,
                                     stalenessSeconds: 5.0)
        let d = AutoDirector(config: cfg)
        _ = d.ingest([loud("A", 0.0, level: 0.4)])
        XCTAssertEqual(d.currentActiveSource, sid("A"))
        var cut = false
        for t in stride(from: 0.5, through: 3.0, by: 0.25) {
            if d.ingest([loud("A", t, level: 0.2), loud("B", t, level: 0.95)]) != nil { cut = true }
        }
        XCTAssertTrue(cut, "a sustained finite-PTS lead must still produce a cut")
        XCTAssertEqual(d.currentActiveSource, sid("B"))
    }

    // MARK: - L1 + M2: DirectorController prunes non-finite, reports active source

    /// M2 smoke: `activeSource` is now read under `lock`, so a reader racing the
    /// analyzer-side writers (`setEnabled` → `director.reset()`) is serialized —
    /// no torn read of the heap `String`. Assert nil before any acquire and that
    /// hammering the read alongside enable/disable churn never crashes.
    func testActiveSourceLockedReadIsRaceSafe() {
        let controller = DirectorController(config: DirectorConfig(autoFrameEnabled: false), enabled: true)
        XCTAssertNil(controller.activeSource, "no program before first acquire")

        let iterations = 5_000
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            for i in 0..<iterations { controller.setEnabled(i % 2 == 0) }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            for _ in 0..<iterations { _ = controller.activeSource; _ = controller.isEnabled }
            group.leave()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
    }

    // MARK: - M4: HighlightDirector burst is bounded, scoring stays correct

    /// REPRODUCE: a same-instant burst of 100k signals. Pre-fix this grew the
    /// event buffer to 100k (O(N²) ingest + O(N) memory). Post-fix the buffer
    /// coalesces to a single event and the score is EXACT (contributions sum).
    func testSameInstantBurstIsCoalescedAndScoreExact() {
        let d = HighlightDirector()
        let n = 100_000
        for _ in 0..<n {
            d.ingest(.audioTransient(strength: 1.0, at: pts(1.0)))
        }
        // audioTransient weight 1.0, magnitude 1.0 each, decay(0)=1 → Σ = n.
        XCTAssertEqual(d.currentScore, Double(n), accuracy: 1e-6)
        XCTAssertLessThanOrEqual(d._test_eventCount, 4, "same-instant burst must coalesce, not accumulate")
    }

    /// A DISTINCT-timestamp flood inside one window must be capped by count (the
    /// backstop against an adversarial spread-out burst).
    func testDistinctTimestampFloodIsCountCapped() {
        let cfg = HighlightDirector.Config(windowSeconds: 1000)
        let d = HighlightDirector(config: cfg)
        // 6000 events (> the 4096 cap) at distinct times, all inside the window.
        for i in 0..<6_000 {
            let t = 1.0 + Double(i) * 0.01   // 10 ms apart → distinct, > coalesce epsilon
            d.ingest(.audioTransient(strength: 0.5, at: pts(t)))
        }
        XCTAssertEqual(d._test_eventCount, 4096, "distinct-timestamp flood must be capped at maxEvents")
    }

    /// NEGATIVE CONTROL: ordinary, well-spaced events are NEITHER coalesced nor
    /// dropped, and the score matches an independent oracle.
    func testNormalEventsAreNeitherCoalescedNorDropped() {
        let cfg = HighlightDirector.Config(windowSeconds: 100, halfLifeSeconds: 2)
        let d = HighlightDirector(config: cfg)
        let times = [0.0, 1.0, 2.0, 3.0, 4.0]
        for t in times { d.ingest(.audioTransient(strength: 1.0, at: pts(t))) }
        XCTAssertEqual(d._test_eventCount, times.count, "distinct well-spaced events must be retained")
        // Oracle score at t=4: Σ 1.0·2^(−(4−t)/2).
        let oracle = times.reduce(0.0) { $0 + pow(2, -(4.0 - $1) / 2.0) }
        XCTAssertEqual(d.currentScore, oracle, accuracy: 1e-9)
    }
}
