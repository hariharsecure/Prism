import os
import XCTest

import PrismCore
@testable import PrismScreen

/// sol #6 — ScreenSource start-after-shutdown / erase-successor races.
///
/// The async start path (`resolveAndStart`) publishes `self.stream` and awaits
/// `startCapture()` OFF the control thread, so a `stop()`/`stop()+restart()` can
/// interleave with it. Two holes:
///  (a) a start that passed its early generation check but hadn't published yet
///      could install + start a capture AFTER the shutdown teardown had already
///      completed (a live capture leaked past the barrier);
///  (b) a retired start's completion UNCONDITIONALLY cleared `self.stream`, so it
///      erased a fast successor's freshly-published stream — after which every
///      successor sample failed the identity check while its SCStream stayed open.
///
/// FIX: one lifecycle lock serializes the published stream (tagged with its
/// generation), the in-flight start task, and the teardown task. A retiring path
/// clears the published stream ONLY when it still owns it, and a teardown AWAITS
/// the in-flight start task before finishing.
///
/// ScreenCaptureKit can't run headless (TCC + real displays), so the LIFECYCLE
/// DECISIONS are exercised as pure seams, and the "teardown awaits start" ordering
/// is driven with an injected in-flight task — no SCStream required.
final class ScreenSourceLifecycleRaceTests: XCTestCase {

    private func displaySource() throws -> ScreenSource {
        let descriptor = SourceDescriptor(kind: .display, id: "display:1", name: "Display 1")
        return try ScreenSource(descriptor: descriptor)
    }

    // MARK: Lifecycle-decision seams

    /// A start awaited across a stop/restart may commit ONLY while its captured
    /// generation is still live.
    func testRetiredStartMayNotCommit() {
        // gen G armed; a stop+restart bumps live past it.
        let g: UInt64 = 5
        XCTAssertTrue(ScreenSource.startMayCommit(captured: g, live: g))
        XCTAssertFalse(ScreenSource.startMayCommit(captured: g, live: g + 2),
                       "sol #6: a retired start (stop/restart bumped past it) must not commit")
    }

    /// sol #6 race (b): a retired start must NOT clear a successor's stream, but it
    /// MUST clear its own on failure/retirement.
    func testRetiredStartClearsOnlyItsOwnStream() {
        // Retired start owns generation G; a successor B published its stream at G+2.
        let retired: UInt64 = 3
        let successorPublished: UInt64 = 5
        XCTAssertFalse(
            ScreenSource.mayClearPublishedStream(publishedGeneration: successorPublished,
                                                 retiringGeneration: retired),
            "sol #6 race (b): a retired start erased the successor's published stream")
        XCTAssertTrue(
            ScreenSource.mayClearPublishedStream(publishedGeneration: retired,
                                                 retiringGeneration: retired),
            "a retired start must still unwind its OWN published stream")
    }

    /// A stop teardown tears down the published stream ONLY when it belongs to a
    /// retired run — never a fast successor's live stream.
    func testTeardownStopsOnlyRetiredStream() {
        // A successor B is live (live == its published generation) → leave it.
        XCTAssertFalse(
            ScreenSource.teardownMayStopPublishedStream(publishedGeneration: 7, live: 7),
            "sol #6: a stop teardown tore down a fast successor's LIVE stream")
        // A retired run's stream is still published while live moved on → tear it down.
        XCTAssertTrue(
            ScreenSource.teardownMayStopPublishedStream(publishedGeneration: 5, live: 7),
            "a retired run's still-published stream must be torn down by the teardown")
    }

    // MARK: Teardown awaits the in-flight START (race (a))

    /// A teardown must JOIN a start that is mid-`startCapture()` before completing,
    /// so `awaitTeardown()` (the shutdown barrier) never returns while a start is
    /// still in flight — the fix for a capture installed after the barrier.
    func testTeardownAwaitsInFlightStart() async throws {
        let src = try displaySource()

        // A controllable "in-flight start": it does not finish until released.
        let released = OSAllocatedUnfairLock(initialState: false)
        let startTask = Task { () -> Void in
            while !released.withLock({ $0 }) {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        src._test_setInFlightStartTask(startTask)
        src._test_beginTeardownAwaitingStart()

        // awaitTeardown() must remain pending while the start is in flight.
        let teardownDone = OSAllocatedUnfairLock(initialState: false)
        let waiter = Task {
            await src.awaitTeardown()
            teardownDone.withLock { $0 = true }
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(teardownDone.withLock { $0 },
                       "sol #6 race (a): teardown completed while a start was still in flight (capture could leak past the barrier)")

        // Release the start → the teardown joins it and finishes to .idle.
        released.withLock { $0 = true }
        await waiter.value
        XCTAssertTrue(teardownDone.withLock { $0 }, "teardown must complete once the in-flight start finishes")
        XCTAssertEqual(src.state, .idle, "teardown must land the source at .idle")
    }
}
