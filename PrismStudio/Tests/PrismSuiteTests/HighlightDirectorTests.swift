import CoreMedia
import XCTest

@testable import PrismDirector

/// Deterministic verification of the "Director's Cut" highlight-scoring engine
/// `HighlightDirector` (flagship slice 1). Every test drives a **synthetic**
/// stream of `HighlightSignal`s (no audio/Vision/compositor) and asserts the
/// scoring, top-N selection, decay, min-gap non-overlap and threshold callback
/// against an **independent hand-computed oracle** — the engine's score formula
/// is `Σ weight·magnitude·2^(−Δt/halfLife)` over a rolling window, so each
/// expected value is recomputed here from first principles, never by re-running
/// the engine against itself.
final class HighlightDirectorTests: XCTestCase {

    private func pts(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

    /// Independent oracle: the momentary score the engine *should* produce at
    /// time `t` for a set of (kind, time, magnitude) events under `config`.
    private func oracleScore(_ events: [(HighlightSignal.Kind, Double, Double)],
                             at t: Double, config: HighlightDirector.Config) -> Double {
        var total = 0.0
        for (kind, time, mag) in events {
            let dt = t - time
            guard dt >= 0, dt <= config.windowSeconds else { continue }
            total += (config.weights[kind] ?? 0) * mag * pow(2, -dt / config.halfLifeSeconds)
        }
        return total
    }

    // MARK: - Empty / single / reset

    func testEmptyInput() {
        let d = HighlightDirector()
        XCTAssertTrue(d.topHighlights.isEmpty)
        XCTAssertEqual(d.currentScore, 0)
        XCTAssertEqual(d.score(at: 5), 0)
    }

    func testSingleEvent() {
        let d = HighlightDirector()
        d.ingest(.audioTransient(strength: 1.0, at: pts(1)))
        // weight 1.0 · mag 1.0 · decay(0) = 1.0
        XCTAssertEqual(d.score(at: 1), 1.0, accuracy: 1e-9)
        XCTAssertEqual(d.currentScore, 1.0, accuracy: 1e-9)
        let top = d.topHighlights
        XCTAssertEqual(top.count, 1)
        XCTAssertEqual(top[0].score, 1.0, accuracy: 1e-9)
        XCTAssertEqual(top[0].dominantSignal, .audioTransient)
        XCTAssertEqual(top[0].peakSeconds, 1, accuracy: 1e-9)
        // Clip window = peak ± highlightDuration/2 (default 12 → ±6).
        XCTAssertEqual(top[0].startPTS.seconds, 1 - 6, accuracy: 1e-6)
        XCTAssertEqual(top[0].endPTS.seconds, 1 + 6, accuracy: 1e-6)
    }

    func testResetClears() {
        let d = HighlightDirector()
        d.ingest(.audioTransient(strength: 1.0, at: pts(1)))
        XCTAssertFalse(d.topHighlights.isEmpty)
        d.reset()
        XCTAssertTrue(d.topHighlights.isEmpty)
        XCTAssertEqual(d.currentScore, 0)
        XCTAssertEqual(d.score(at: 1), 0)
    }

    // MARK: - Co-occurrence beats steady loudness

    func testCoOccurrenceOutscoresSteadyLoudness() {
        let cfg = HighlightDirector.Config()  // defaults: transient/laughter 1.0, loudness 0.5
        let d = HighlightDirector(config: cfg)
        // A: a hit landing WITH laughter at t=10 → 1.0 + 1.0 = 2.0.
        d.ingest(.audioTransient(strength: 1.0, at: pts(10)))
        d.ingest(.captionLaughter(intensity: 1.0, at: pts(10)))
        // B: steady loudness bed at t=30,30.5,31 (well past the min-gap of 15).
        d.ingest(.loudness(energy: 1.0, at: pts(30)))
        d.ingest(.loudness(energy: 1.0, at: pts(30.5)))
        d.ingest(.loudness(energy: 1.0, at: pts(31)))

        let coScore = oracleScore([(.audioTransient, 10, 1), (.captionLaughter, 10, 1)], at: 10, config: cfg)
        let loudScore = oracleScore([(.loudness, 30, 1), (.loudness, 30.5, 1), (.loudness, 31, 1)], at: 31, config: cfg)
        XCTAssertEqual(coScore, 2.0, accuracy: 1e-9)
        XCTAssertGreaterThan(coScore, loudScore)   // oracle: co-occurrence wins

        let top = d.topHighlights
        XCTAssertEqual(top.count, 2)
        XCTAssertEqual(top[0].peakSeconds, 10, accuracy: 1e-9)      // co-occurrence ranks first
        XCTAssertEqual(top[0].score, coScore, accuracy: 1e-9)
        XCTAssertEqual(top[1].score, loudScore, accuracy: 1e-9)     // steady loudness peak is its last sample
        XCTAssertGreaterThan(top[0].score, top[1].score)
    }

    // MARK: - Decay drops an old spike

    func testDecayDropsOldSpike() {
        let cfg = HighlightDirector.Config()  // window 6, halfLife 2
        let d = HighlightDirector(config: cfg)
        d.ingest(.audioTransient(strength: 1.0, at: pts(0)))
        XCTAssertEqual(d.score(at: 0), 1.0, accuracy: 1e-9)        // decay(0)=1
        XCTAssertEqual(d.score(at: 2), 0.5, accuracy: 1e-9)        // decay(1 half-life)=0.5
        XCTAssertEqual(d.score(at: 4), 0.25, accuracy: 1e-9)       // decay(2)=0.25
        XCTAssertEqual(d.score(at: 6), 0.125, accuracy: 1e-9)      // decay(3)=0.125, dt=6==window
        XCTAssertEqual(d.score(at: 6.001), 0, accuracy: 1e-12)     // aged past the window → gone
        // Strictly decreasing while inside the window.
        XCTAssertGreaterThan(d.score(at: 0), d.score(at: 2))
        XCTAssertGreaterThan(d.score(at: 2), d.score(at: 4))
    }

    // MARK: - Min-gap prevents overlapping highlights

    func testMinGapMergesNearbyIntoOnePeak() {
        let cfg = HighlightDirector.Config(minGapSeconds: 15)
        let d = HighlightDirector(config: cfg)
        d.ingest(.audioTransient(strength: 1.0, at: pts(10)))
        d.ingest(.audioTransient(strength: 1.0, at: pts(12)))   // within 15s of 10 → same cluster
        d.ingest(.audioTransient(strength: 1.0, at: pts(40)))   // 28s from 12 → new cluster

        let top = d.topHighlights
        XCTAssertEqual(top.count, 2, "two nearby hits must merge into one highlight")
        // The peak of the first cluster moves to t=12: score = 1.0 + 1.0·decay(1)=0.5 → 1.5.
        let firstPeak = top.first(where: { abs($0.peakSeconds - 12) < 1e-6 })
        XCTAssertNotNil(firstPeak)
        XCTAssertEqual(firstPeak?.score ?? 0, 1.5, accuracy: 1e-9)
        // No two highlights are closer than the min-gap.
        let times = top.map { $0.peakSeconds }.sorted()
        for i in 1..<times.count { XCTAssertGreaterThanOrEqual(times[i] - times[i - 1], 15) }
    }

    // MARK: - Top-N are the highest-scoring non-overlapping windows

    func testTopNSelectsHighestNonOverlapping() {
        let cfg = HighlightDirector.Config(topN: 2, minGapSeconds: 5,
                                           highlightDurationSeconds: 4, threshold: 100)
        let d = HighlightDirector(config: cfg)
        // Four well-separated (>5s) transients of different strengths.
        d.ingest(.audioTransient(strength: 0.5, at: pts(0)))
        d.ingest(.audioTransient(strength: 1.0, at: pts(10)))
        d.ingest(.audioTransient(strength: 0.8, at: pts(20)))
        d.ingest(.audioTransient(strength: 0.3, at: pts(30)))

        let top = d.topHighlights
        XCTAssertEqual(top.count, 2)                                  // capped at topN
        XCTAssertEqual(top[0].peakSeconds, 10, accuracy: 1e-9)        // strongest
        XCTAssertEqual(top[1].peakSeconds, 20, accuracy: 1e-9)        // 2nd strongest
        XCTAssertGreaterThan(top[0].score, top[1].score)
    }

    // MARK: - Ties

    func testTiesRetainedAndOrderedByTime() {
        let d = HighlightDirector(config: .init(threshold: 100))
        d.ingest(.audioTransient(strength: 1.0, at: pts(10)))
        d.ingest(.audioTransient(strength: 1.0, at: pts(40)))   // equal score, far apart
        let top = d.topHighlights
        XCTAssertEqual(top.count, 2)
        XCTAssertEqual(top[0].score, top[1].score, accuracy: 1e-9)   // a genuine tie
        XCTAssertEqual(top[0].peakSeconds, 10, accuracy: 1e-9)       // earlier peak first
        XCTAssertEqual(top[1].peakSeconds, 40, accuracy: 1e-9)
    }

    // MARK: - Threshold callback

    func testThresholdFiresOncePerCrossingCluster() {
        let cfg = HighlightDirector.Config(minGapSeconds: 15, threshold: 1.0)
        let d = HighlightDirector(config: cfg)
        let fired = Locked<[HighlightDirector.Highlight]>([])
        d.onHighlight = { h in fired.mutate { $0.append(h) } }

        d.ingest(.audioTransient(strength: 0.5, at: pts(5)))    // 0.5 < 1.0 → no fire
        d.ingest(.audioTransient(strength: 1.0, at: pts(25)))   // 1.0 ≥ 1.0 → FIRE
        d.ingest(.audioTransient(strength: 0.2, at: pts(27)))   // near 25, weaker → suppressed, no fire
        d.ingest(.audioTransient(strength: 1.0, at: pts(60)))   // new cluster ≥ 1.0 → FIRE

        let events = fired.value
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].peakSeconds, 25, accuracy: 1e-9)
        XCTAssertEqual(events[1].peakSeconds, 60, accuracy: 1e-9)
    }

    func testThresholdCrossingByAccumulationFiresOnce() {
        let cfg = HighlightDirector.Config(minGapSeconds: 15, threshold: 1.0)
        let d = HighlightDirector(config: cfg)
        let count = Locked<Int>(0)
        d.onHighlight = { _ in count.mutate { $0 += 1 } }

        d.ingest(.audioTransient(strength: 0.6, at: pts(100)))  // cluster @ 0.6, below threshold
        // score@101 = 0.6 + 0.6·2^(-1/2) = 0.6 + 0.6·0.707 ≈ 1.024 ≥ 1 → crosses → FIRE once
        d.ingest(.audioTransient(strength: 0.6, at: pts(101)))
        d.ingest(.audioTransient(strength: 0.6, at: pts(102)))  // already fired → no second fire
        XCTAssertEqual(count.value, 1)
    }

    // MARK: - Weights change the ranking predictably

    func testWeightsChangeRanking() {
        let events: (HighlightDirector) -> Void = { d in
            d.ingest(.loudness(energy: 1.0, at: self.pts(10)))
            d.ingest(.sceneCut(at: self.pts(40), magnitude: 1.0))
        }
        // Default: loudness 0.5 > sceneCut 0.4 → loudness ranks first.
        let d1 = HighlightDirector(config: .init(threshold: 100))
        events(d1)
        XCTAssertEqual(d1.topHighlights.first?.dominantSignal, .loudness)

        // Reweight so a cut dominates → ranking flips.
        var w = HighlightDirector.Config.defaultWeights
        w[.loudness] = 0.1; w[.sceneCut] = 1.0
        let d2 = HighlightDirector(config: .init(weights: w, threshold: 100))
        events(d2)
        XCTAssertEqual(d2.topHighlights.first?.dominantSignal, .sceneCut)
    }

    // MARK: - Chat velocity is accepted but unweighted by default

    func testChatVelocityUnweightedByDefault() {
        let d = HighlightDirector()
        d.ingest(.chatVelocity(normalized: 1.0, at: pts(5)))
        XCTAssertTrue(d.topHighlights.isEmpty, "weight 0 → no highlight")
        XCTAssertEqual(d.score(at: 5), 0, accuracy: 1e-12)

        // Wire a weight in → the same event now scores.
        var w = HighlightDirector.Config.defaultWeights
        w[.chatVelocity] = 1.0
        let d2 = HighlightDirector(config: .init(weights: w))
        d2.ingest(.chatVelocity(normalized: 1.0, at: pts(5)))
        XCTAssertEqual(d2.topHighlights.count, 1)
        XCTAssertEqual(d2.topHighlights[0].dominantSignal, .chatVelocity)
    }

    // MARK: - Flood: dense burst collapses; spread-out flood respects top-N

    func testDenseFloodCollapsesToOneHighlight() {
        let cfg = HighlightDirector.Config(minGapSeconds: 15)
        let d = HighlightDirector(config: cfg)
        // 1000 hits packed into a 10s span (all within the 15s min-gap).
        for i in 0..<1000 { d.ingest(.audioTransient(strength: 0.5, at: pts(Double(i) * 0.01))) }
        XCTAssertEqual(d.topHighlights.count, 1, "a single dense burst is one highlight")
        XCTAssertTrue(d.currentScore.isFinite)
    }

    func testSpreadFloodRespectsTopNAndPicksStrongest() {
        let cfg = HighlightDirector.Config(topN: 5, minGapSeconds: 15,
                                           highlightDurationSeconds: 10, threshold: 100)
        let d = HighlightDirector(config: cfg)
        // 300 well-separated hits (20s apart). Strength peaks in the middle so the
        // strongest five are known independently.
        let n = 300
        for i in 0..<n {
            let mag = 0.2 + 0.7 * (1 - abs(Double(i) - Double(n) / 2) / (Double(n) / 2))
            d.ingest(.audioTransient(strength: mag, at: pts(Double(i) * 20)))
        }
        let top = d.topHighlights
        XCTAssertEqual(top.count, 5)                    // bounded to topN
        // Each separated hit is its own cluster → score == its magnitude (decay(0)).
        // The five strongest cluster at the middle index; scores must be descending.
        for i in 1..<top.count { XCTAssertGreaterThanOrEqual(top[i - 1].score, top[i].score) }
        XCTAssertEqual(top[0].peakSeconds, Double(n / 2) * 20, accuracy: 1e-6)
    }

    // MARK: - Loudness LUFS normalization (the wiring mapping)

    func testLoudnessNormalizationMapping() {
        XCTAssertEqual(HighlightSignal.normalizeLoudness(momentaryLUFS: -40), 0, accuracy: 1e-9)
        XCTAssertEqual(HighlightSignal.normalizeLoudness(momentaryLUFS: -10), 1, accuracy: 1e-9)
        XCTAssertEqual(HighlightSignal.normalizeLoudness(momentaryLUFS: -25), 0.5, accuracy: 1e-9)
        XCTAssertEqual(HighlightSignal.normalizeLoudness(momentaryLUFS: -.infinity), 0) // silence
        XCTAssertEqual(HighlightSignal.normalizeLoudness(momentaryLUFS: 0), 1)          // above ceil clamps
    }

    // MARK: - Out-of-order (late) events are scored at their own PTS

    func testLateEventScoredAtOwnPTS() {
        let cfg = HighlightDirector.Config()
        let d = HighlightDirector(config: cfg)
        d.ingest(.audioTransient(strength: 1.0, at: pts(10)))
        d.ingest(.audioTransient(strength: 1.0, at: pts(9)))   // arrives late, older PTS
        // score(at: 10) must include BOTH the @10 hit (decay 0) and the @9 hit
        // (decay 0.5 half-life) regardless of arrival order.
        let expected = oracleScore([(.audioTransient, 10, 1), (.audioTransient, 9, 1)], at: 10, config: cfg)
        XCTAssertEqual(d.score(at: 10), expected, accuracy: 1e-9)
    }
}

/// Minimal thread-safe box for capturing callback output in tests.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&_value); lock.unlock() }
}
