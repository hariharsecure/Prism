import XCTest
import PrismOutput
@testable import Prism

/// Phase 2f — REQUESTED vs CONFIRMED streaming output state, and Phase 2c — the
/// BOUNDED external-output shutdown barrier. These live in `PrismAppTests`
/// (target `PrismTests`) alongside `OnAirStatusTests` so they run in the app's
/// default test scheme.
///
/// 2f generalizes the `isOnAir` fix: instead of loose booleans + a free-form
/// status string that could diverge from reality, the streaming output has ONE
/// state (`StreamOutputState`) that `isStreaming` / `isOnAir` /
/// `streamStateDescription` all derive from. The transition table is a PURE
/// reducer, so it is checked here without a live socket.
@MainActor
final class StreamOutputStateTests: XCTestCase {

    // MARK: 2f — pure requested→confirmed lifecycle

    /// The spec's canonical path: a single-RTMP go-live is REQUESTED
    /// (`preparing`), CONFIRMED when the socket publishes (`live`), then stops
    /// (`stopping` → `idle`). Reproduce-first: this is the seam the engine funnels
    /// every real RTMP event through.
    func testRequestedToLiveToStoppedLifecycle() {
        var state = StreamOutputState.idle
        state = StreamOutputState.reduce(state, on: .requestStart)
        XCTAssertEqual(state, .preparing, "go-live with a single-RTMP primary is REQUESTED, not yet confirmed")
        state = StreamOutputState.reduce(state, on: .socketPublishing)
        XCTAssertEqual(state, .live, "socket publishing CONFIRMS the stream is live")
        state = StreamOutputState.reduce(state, on: .requestStop)
        XCTAssertEqual(state, .stopping, "stop request enters the tearing-down state")
        state = StreamOutputState.reduce(state, on: .closed)
        XCTAssertEqual(state, .idle, "a clean close returns to the resting state")
    }

    /// #9: a destinations-only broadcast is REQUESTED (`.preparing`) on go-live —
    /// it is NOT live the instant its encoder runs. It stays `.preparing` until a
    /// destination actually reports publishing (was: reduced straight to `.live`,
    /// so a blank destinations-only broadcast reported "live" with nothing
    /// connected).
    func testDestinationsOnlyStaysPreparingUntilPublish() {
        let state = StreamOutputState.reduce(.idle, on: .requestStart)
        XCTAssertEqual(state, .preparing, "#9: destinations-only go-live is REQUESTED, not immediately live")
    }

    /// A drop while live goes to `reconnecting`, and a re-publish returns to live.
    func testReconnectThenRepublish() {
        var state = StreamOutputState.live
        state = StreamOutputState.reduce(state, on: .socketReconnecting(attempt: 2))
        XCTAssertEqual(state, .reconnecting(attempt: 2))
        state = StreamOutputState.reduce(state, on: .socketPublishing)
        XCTAssertEqual(state, .live)
    }

    /// A connect failure is terminal `failed`, which is NOT an active output.
    func testFailedIsTerminalAndNotActive() {
        let state = StreamOutputState.reduce(.preparing, on: .failed(reason: "no server"))
        XCTAssertEqual(state, .failed(reason: "no server"))
        XCTAssertFalse(state.isActiveOutput, "a failed stream is not on-air")
    }

    // MARK: 2f — derived surfaces (single source of truth)

    /// `isActiveOutput` (which backs `isStreaming` and the streaming half of
    /// `isOnAir`) is true for every requested/confirmed/tearing-down state and
    /// false only at rest or after a terminal failure — preserving the pre-2f
    /// `isStreaming` semantics (connecting already read as on-air).
    func testIsActiveOutputMapping() {
        XCTAssertTrue(StreamOutputState.preparing.isActiveOutput)
        XCTAssertTrue(StreamOutputState.live.isActiveOutput)
        XCTAssertTrue(StreamOutputState.reconnecting(attempt: 1).isActiveOutput)
        XCTAssertTrue(StreamOutputState.degraded(reason: "x").isActiveOutput)
        XCTAssertTrue(StreamOutputState.stopping.isActiveOutput)
        XCTAssertFalse(StreamOutputState.idle.isActiveOutput)
        XCTAssertFalse(StreamOutputState.failed(reason: "x").isActiveOutput)
    }

    /// `streamStateDescription` derives from the state; the `reconnecting` prefix
    /// is load-bearing (obs `streamStatus()` reads it).
    func testDescriptionStrings() {
        XCTAssertEqual(StreamOutputState.idle.description, "idle")
        XCTAssertEqual(StreamOutputState.preparing.description, "connecting")
        XCTAssertEqual(StreamOutputState.live.description, "live")
        XCTAssertTrue(StreamOutputState.reconnecting(attempt: 3).description.hasPrefix("reconnecting"),
                      "obs streamStatus() keys off the 'reconnecting' prefix")
        XCTAssertEqual(StreamOutputState.failed(reason: "boom").description, "failed: boom")
    }

    /// The 2f contract wired through to `isOnAir`: live reads on-air, idle does
    /// not (streaming derived from the state, not a separate boolean).
    func testOnAirDerivesFromStreamState() {
        XCTAssertTrue(AppEngine.computeOnAir(recording: false, vcam: false,
                                             streaming: StreamOutputState.live.isActiveOutput),
                      "a live stream must read on-air")
        XCTAssertFalse(AppEngine.computeOnAir(recording: false, vcam: false,
                                              streaming: StreamOutputState.idle.isActiveOutput),
                       "an idle stream must read off-air")
    }

    @MainActor
    func testFreshEngineStreamStateIsIdle() {
        let engine = AppEngine()
        XCTAssertEqual(engine.streamOutputState, .idle)
        XCTAssertFalse(engine.isStreaming)
        XCTAssertEqual(engine.streamStateDescription, "idle")
    }

    // MARK: 2c — bounded external-output barrier

    /// The barrier WAITS: with a close that finishes inside the bound, the
    /// barrier returns only after the close completed, and reports "not timed
    /// out". Reproduce-first for "shutdown awaits the output close before
    /// returning".
    func testBarrierAwaitsCloseThatFinishesInTime() async {
        let closed = ManagedAtomicFlag()
        let handle = Task { @Sendable in
            try? await Task.sleep(for: .milliseconds(50))
            closed.set()
        }
        let timedOut = await AppEngine.awaitAll([handle], timeout: .seconds(5))
        XCTAssertFalse(timedOut, "the close finished within the bound")
        XCTAssertTrue(closed.value, "the barrier returned only AFTER the output close completed")
    }

    /// The barrier is BOUNDED: a close that never finishes does not hang the
    /// barrier — past the deadline it returns, reporting a timeout.
    func testBarrierIsBoundedWhenCloseHangs() async {
        let hanging = Task { @Sendable () -> Void in
            // Far longer than the bound; simulates a wedged socket close.
            try? await Task.sleep(for: .seconds(60))
        }
        let start = ContinuousClock.now
        let timedOut = await AppEngine.awaitAll([hanging], timeout: .milliseconds(100))
        let elapsed = start.duration(to: .now)
        hanging.cancel()
        XCTAssertTrue(timedOut, "a wedged close must trip the bound, not hang shutdown")
        XCTAssertLessThan(elapsed, .seconds(2), "the barrier returned near its bound, not at the close's duration")
    }

    /// No handles → nothing to await → returns immediately, not timed out.
    func testBarrierNoHandlesReturnsImmediately() async {
        let timedOut = await AppEngine.awaitAll([], timeout: .milliseconds(10))
        XCTAssertFalse(timedOut)
    }

    // MARK: #5 — a cancelled observer must not tear down its successor

    /// THE RACE: stream A's `.failed` wins the yield/cancel race and its main-actor
    /// job queues; stop-A/start-B runs first (current output is now B); then the
    /// stale A job executes. Pre-fix it applied A's `.failed` → tore down B
    /// (final current = nil). The guard drops any event whose generation or output
    /// identity no longer matches the current stream, so B survives.
    func testCancelledObserverEventForSupersededStreamIsDropped() {
        let outA = RTMPStreamOutput()
        let outB = RTMPStreamOutput()
        // A's observer was started at generation 5; the engine has since torn A
        // down and started B (generation 7, current output B).
        XCTAssertFalse(AppEngine.streamEventIsCurrent(eventGeneration: 5, currentGeneration: 7,
                                                      eventOutput: outA, currentOutput: outB),
                       "#5: a stale A event (superseded generation) must be DROPPED, not applied to B")
        // Even if the generation counter happened to coincide, a DIFFERENT output
        // instance than the current one is still dropped (identity guard).
        XCTAssertFalse(AppEngine.streamEventIsCurrent(eventGeneration: 7, currentGeneration: 7,
                                                      eventOutput: outA, currentOutput: outB),
                       "#5: an event for a different output instance must be dropped")
        // B's OWN observer event (same generation, same output) is applied.
        XCTAssertTrue(AppEngine.streamEventIsCurrent(eventGeneration: 7, currentGeneration: 7,
                                                     eventOutput: outB, currentOutput: outB),
                      "#5: the current stream's own event must still be applied")
        // A late event after everything torn down (current output nil) is dropped.
        XCTAssertFalse(AppEngine.streamEventIsCurrent(eventGeneration: 7, currentGeneration: 7,
                                                      eventOutput: outB, currentOutput: nil))
    }

    // MARK: #9 — destinations-only never reports live with zero connected

    /// canGoLive requires a VALID target: an enabled BLANK destination (empty URL)
    /// does not count, so Go Live can no longer start a destinations-only broadcast
    /// with nothing to publish.
    func testCanGoLiveRequiresAValidTarget() {
        // The "Add" default: enabled but blank → not publishable.
        let blank = Destination(name: "New", proto: .rtmp, url: "", key: "", enabled: true)
        XCTAssertFalse(blank.isPublishable, "#9: an enabled BLANK destination is not publishable")
        XCTAssertFalse(AppEngine.canGoLive(primaryURL: "", primaryKey: "", destinations: [blank]),
                       "#9: a blank primary + blank destination must NOT be able to go live")
        // A destination with a URL is publishable → can go live.
        let real = Destination(name: "YT", proto: .rtmp, url: "rtmp://a.rtmp.youtube.com/live2",
                               key: "k", enabled: true)
        XCTAssertTrue(real.isPublishable)
        XCTAssertTrue(AppEngine.canGoLive(primaryURL: "", primaryKey: "", destinations: [real]))
        // A disabled destination (even with a URL) doesn't count.
        var disabled = real; disabled.enabled = false
        XCTAssertFalse(disabled.isPublishable)
        XCTAssertFalse(AppEngine.canGoLive(primaryURL: "", primaryKey: "", destinations: [disabled]))
        // A complete primary alone is enough.
        XCTAssertTrue(AppEngine.canGoLive(primaryURL: "rtmp://x/app", primaryKey: "k", destinations: []))
        // A primary with an empty key is NOT (unpublishable, W9).
        XCTAssertFalse(AppEngine.canGoLive(primaryURL: "rtmp://x/app", primaryKey: "", destinations: []))
    }

    /// The destinations-only aggregate transitions (#9), each independently:
    /// nothing published → stay `.preparing`; ≥1 published → `.live`; a partial
    /// set (some published, some failed) → `.degraded`; every one failed →
    /// `.failed`.
    func testDestinationsOnlyAggregateTransitions() {
        func stateAfter(published: Int, failed: Int, total: Int) -> StreamOutputState {
            guard let ev = AppEngine.destinationsOnlyEvent(published: published, failed: failed, total: total)
            else { return .preparing }   // nil → no transition yet
            return StreamOutputState.reduce(.preparing, on: ev)
        }
        // Nothing has resolved yet → still REQUESTED.
        XCTAssertNil(AppEngine.destinationsOnlyEvent(published: 0, failed: 0, total: 2),
                     "#9: with nothing published the broadcast stays .preparing (was: instantly .live)")
        XCTAssertEqual(stateAfter(published: 0, failed: 0, total: 2), .preparing)
        // At least one publishing, none failed → LIVE.
        XCTAssertEqual(stateAfter(published: 1, failed: 0, total: 2), .live,
                       "#9: a destination reporting publishing confirms live")
        XCTAssertEqual(stateAfter(published: 2, failed: 0, total: 2), .live)
        // Partial: one up, one failed → DEGRADED.
        XCTAssertEqual(stateAfter(published: 1, failed: 1, total: 2), .degraded(reason: "1 of 2 destination(s) failed"),
                       "#9: a partial destination set is degraded, not plain live")
        // Every destination failed → FAILED.
        XCTAssertEqual(stateAfter(published: 0, failed: 2, total: 2), .failed(reason: "all 2 destination(s) failed to connect"),
                       "#9: all-failed is terminal .failed, not a phantom .live")
    }

    // MARK: #10 — stop enters .stopping and serializes an overlapping restart

    /// The serialization rule: a go-live that lands while the lifecycle is
    /// `.stopping` (A's socket still closing) must be QUEUED behind the close, not
    /// run immediately.
    func testStartDuringStoppingIsQueued() {
        XCTAssertTrue(AppEngine.startShouldQueueBehindStop(currentState: .stopping),
                      "#10: a start during .stopping must be serialized behind the close")
        XCTAssertFalse(AppEngine.startShouldQueueBehindStop(currentState: .idle))
        XCTAssertFalse(AppEngine.startShouldQueueBehindStop(currentState: .live))
        XCTAssertFalse(AppEngine.startShouldQueueBehindStop(currentState: .preparing))
    }

    /// Reproduce-first at the engine level (#10): while `.stopping`, the app is
    /// still `isStreaming` (the socket hasn't closed), and a go-live is HELD as a
    /// pending restart rather than starting a second stream into A's open socket.
    func testRestartDuringStopIsHeldNotStarted() {
        let engine = AppEngine()
        engine._test_setStreamOutputState(.stopping)   // A is still closing its socket
        XCTAssertTrue(engine.isStreaming,
                      "#10: isStreaming must stay true through .stopping until the socket closes")
        engine.goLive(rtmpURL: "rtmp://a.rtmp.youtube.com/live2", streamKey: "k")  // B requested mid-stop
        XCTAssertTrue(engine._test_pendingStreamStartQueued,
                      "#10: a go-live during .stopping must be QUEUED, not run")
        XCTAssertEqual(engine.streamOutputState, .stopping,
                       "#10: the queued restart must not have started a second stream while A closes")
    }
}

/// Minimal thread-safe boolean for asserting a background close ran. (Avoids a
/// dependency on swift-atomics in the test target.)
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func set() { lock.lock(); _value = true; lock.unlock() }
}
