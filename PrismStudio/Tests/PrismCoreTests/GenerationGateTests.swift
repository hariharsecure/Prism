import XCTest
@testable import PrismCore

/// 2b — GENERATION TOKENS (suppress stale capture/screen callbacks).
///
/// BUG: capture (camera) and screen sources deliver frames and lifecycle
/// callbacks asynchronously. A callback armed under one run can fire AFTER a
/// `stop()` (or a `stop()`+`start()`) retired it — a frame/asset from a retired
/// generation crossing the stop/restart boundary — and, unread, it posts into the
/// SUCCESSOR run (ScreenSource additionally has an async-start race where the
/// retired `resolveAndStart` passes the bare `state == .starting` check because
/// the RESTART set `.starting` again, then commits its stale stream).
///
/// FIX: a monotonically-incrementing `GenerationGate` per source. Every
/// `start()`/`stop()` bumps the generation; each async callback captures the live
/// generation at arm time and NO-OPs unless it still matches. This test drives the
/// PURE gate logic directly (no source, no hardware) and models the exact
/// stale-vs-current callback scenario the sources rely on.
final class GenerationGateTests: XCTestCase {

    // MARK: Pure decision

    func testPureAcceptsOnlyMatchingGeneration() {
        // A captured generation is applied ONLY when it equals the live one.
        XCTAssertTrue(GenerationGate.accepts(live: 7, captured: 7))
        XCTAssertFalse(GenerationGate.accepts(live: 8, captured: 7), "a stale (older) capture must be rejected")
        XCTAssertFalse(GenerationGate.accepts(live: 7, captured: 9), "a mismatched capture must be rejected")
    }

    // MARK: bump() monotonicity — models stop→start incrementing the generation

    func testBumpIsMonotonicAndRetiresPriorCaptures() {
        let gate = GenerationGate()
        XCTAssertEqual(gate.current, 0)

        // start() → arm generation 1.
        let armedAtStart = gate.bump()
        XCTAssertEqual(armedAtStart, 1)
        XCTAssertTrue(gate.isCurrent(armedAtStart), "a fresh start's callbacks are live")

        // stop() → retire it (bump). The still-armed value is now stale.
        _ = gate.bump()
        XCTAssertFalse(gate.isCurrent(armedAtStart),
                       "after stop(), a callback captured at start must be dropped")

        // start() again → the generation strictly advanced across stop→start.
        let armedAtRestart = gate.bump()
        XCTAssertGreaterThan(armedAtRestart, armedAtStart,
                             "a stop→start must increment the generation")
        XCTAssertTrue(gate.isCurrent(armedAtRestart))
        XCTAssertFalse(gate.isCurrent(armedAtStart),
                       "the predecessor generation stays retired after the restart")
    }

    // MARK: The scenario a source implements — stale callback drops, current applies

    /// A tiny stand-in for a source that mutates state ONLY when the gate accepts a
    /// callback's captured generation. Proves a stale-generation callback causes no
    /// mutation while a current-generation one is applied.
    private final class GatedSink {
        let gate = GenerationGate()
        private(set) var applied = 0
        /// Deliver a callback that was armed at `captured`. No-ops if retired.
        func deliver(capturedAt captured: UInt64) {
            guard gate.isCurrent(captured) else { return }   // stale ⇒ drop, no mutation
            applied += 1
        }
    }

    func testStaleCallbackDroppedCurrentApplied() {
        let sink = GatedSink()

        // Run 1: start arms gen 1; a frame captured at gen 1 is live.
        let gen1 = sink.gate.bump()
        sink.deliver(capturedAt: gen1)
        XCTAssertEqual(sink.applied, 1, "a current-generation callback must be applied")

        // stop()+start(): the run is retired then a new one armed (gen advances).
        _ = sink.gate.bump()             // stop
        let gen2 = sink.gate.bump()      // start

        // A straggler frame from run 1 crosses the boundary — it must be DROPPED.
        sink.deliver(capturedAt: gen1)
        XCTAssertEqual(sink.applied, 1, "a stale-generation callback must NOT mutate state")

        // A frame from the live run 2 is applied.
        sink.deliver(capturedAt: gen2)
        XCTAssertEqual(sink.applied, 2, "the current-generation callback must be applied")
    }
}
