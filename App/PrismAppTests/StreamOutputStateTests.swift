import XCTest
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
        state = StreamOutputState.reduce(state, on: .requestStart(hasPrimary: true))
        XCTAssertEqual(state, .preparing, "go-live with a single-RTMP primary is REQUESTED, not yet confirmed")
        state = StreamOutputState.reduce(state, on: .socketPublishing)
        XCTAssertEqual(state, .live, "socket publishing CONFIRMS the stream is live")
        state = StreamOutputState.reduce(state, on: .requestStop)
        XCTAssertEqual(state, .stopping, "stop request enters the tearing-down state")
        state = StreamOutputState.reduce(state, on: .closed)
        XCTAssertEqual(state, .idle, "a clean close returns to the resting state")
    }

    /// A destinations-only broadcast has no single-RTMP primary to confirm, so it
    /// is CONFIRMED live the moment its encoder runs.
    func testDestinationsOnlyIsLiveImmediately() {
        let state = StreamOutputState.reduce(.idle, on: .requestStart(hasPrimary: false))
        XCTAssertEqual(state, .live, "destinations-only broadcast is live without a socket-confirmation step")
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
}

/// Minimal thread-safe boolean for asserting a background close ran. (Avoids a
/// dependency on swift-atomics in the test target.)
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func set() { lock.lock(); _value = true; lock.unlock() }
}
