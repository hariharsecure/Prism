import XCTest
@testable import PrismVirtualCam

/// THE BUG (VirtualCameraFeeder):
///  1. A repeat "vcam on" called `start()` again, which unconditionally set the
///     state to `.searching`. Because the sink was already attached,
///     `attemptAttach()` short-circuited and never restored `.feeding` — frames
///     kept flowing but Prism reported off-air indefinitely (non-idempotency).
///  2. Each off/on cycle added a DAL device-list listener that `stop()` never
///     actually removed (it only flipped a flag), so listeners accumulated — a
///     permanent per-cycle leak.
///
/// THE FIX: the start/stop state transition and the DAL-listener accounting were
/// extracted into `VCamLifecycleModel`, a pure/total value type (the live feeder
/// can't run headless — no CMIO extension, no DAL device — exactly like the
/// `VCamSinkAuthorizationTests` seam). These tests exercise that model:
///   - repeat `start()` while attached stays `.feeding`,
///   - a full off→on→off cycle leaves ZERO net listeners,
///   - a first `start()` still transitions `.searching` → (attach) → `.feeding`.
final class VCamLifecycleModelTests: XCTestCase {

    // MARK: Bug 1 — idempotency

    /// A first start() begins searching and installs exactly one listener;
    /// attaching then transitions to feeding. (Correct first-start behavior — a
    /// regression guard that the fix preserves it.)
    func testFirstStartSearchesThenAttachesToFeeding() {
        var m = VCamLifecycleModel()
        XCTAssertEqual(m.phase, .idle)

        let needsListener = m.start()
        XCTAssertTrue(needsListener, "first start must install a DAL listener")
        XCTAssertEqual(m.phase, .searching, "first start transitions idle → searching")
        XCTAssertFalse(m.attached)
        XCTAssertEqual(m.listenerCount, 1)

        m.attach()
        XCTAssertEqual(m.phase, .feeding, "attaching the sink transitions searching → feeding")
        XCTAssertTrue(m.attached)
    }

    /// THE reproducer: once feeding, a repeat start() must NOT drop to
    /// `.searching`. Pre-fix this left Prism stuck reporting off-air.
    func testRepeatStartWhileFeedingStaysFeeding() {
        var m = VCamLifecycleModel()
        m.start()
        m.attach()
        XCTAssertEqual(m.phase, .feeding)

        let needsListener = m.start()   // the repeat "vcam on"
        XCTAssertEqual(m.phase, .feeding, "repeat start while attached must KEEP .feeding")
        XCTAssertTrue(m.attached)
        XCTAssertFalse(needsListener, "repeat start must not register a duplicate listener")
        XCTAssertEqual(m.listenerCount, 1, "listener count must stay at 1 across repeat starts")
    }

    /// Even many repeat starts while feeding never perturb the phase or the
    /// listener count.
    func testManyRepeatStartsAreNoOps() {
        var m = VCamLifecycleModel()
        m.start()
        m.attach()
        for _ in 0..<10 {
            XCTAssertFalse(m.start(), "no repeat start should ask for a new listener")
            XCTAssertEqual(m.phase, .feeding)
            XCTAssertEqual(m.listenerCount, 1)
        }
    }

    // MARK: Bug 2 — DAL listener leak

    /// A full off→on→off cycle must net ZERO listeners. Pre-fix each cycle added
    /// one that was never removed.
    func testOffOnOffLeavesZeroNetListeners() {
        var m = VCamLifecycleModel()

        // on
        XCTAssertTrue(m.start(), "start installs a listener")
        m.attach()
        XCTAssertEqual(m.listenerCount, 1)

        // off
        XCTAssertTrue(m.stop(), "stop must remove the registered listener")
        XCTAssertEqual(m.listenerCount, 0, "no leaked listener after stop")
        XCTAssertEqual(m.phase, .stopped)
        XCTAssertFalse(m.attached)

        // on again
        XCTAssertTrue(m.start(), "re-start installs a fresh listener")
        m.attach()
        XCTAssertEqual(m.listenerCount, 1)

        // off again
        XCTAssertTrue(m.stop())
        XCTAssertEqual(m.listenerCount, 0, "still zero after a second full cycle")
    }

    /// Repeated off/on cycles never accumulate listeners (the leak would have
    /// grown listenerCount unboundedly).
    func testRepeatedCyclesNeverAccumulateListeners() {
        var m = VCamLifecycleModel()
        for _ in 0..<25 {
            m.start()
            m.attach()
            m.stop()
            XCTAssertLessThanOrEqual(m.listenerCount, 1)
        }
        XCTAssertEqual(m.listenerCount, 0, "off→on cycles must not leak DAL listeners")
    }

    /// stop() with nothing registered is a safe no-op (no negative accounting,
    /// no phantom removal).
    func testStopWithoutStartIsSafe() {
        var m = VCamLifecycleModel()
        XCTAssertFalse(m.stop(), "nothing to remove when never started")
        XCTAssertEqual(m.listenerCount, 0)
        XCTAssertEqual(m.phase, .stopped)
    }

    // MARK: Listener install-failure accounting

    /// If the DAL install fails, the accounting is undone so a later start
    /// retries and stop() won't attempt a phantom removal.
    func testListenerInstallFailureIsUndone() {
        var m = VCamLifecycleModel()
        XCTAssertTrue(m.start())
        XCTAssertEqual(m.listenerCount, 1)

        m.listenerInstallFailed()
        XCTAssertEqual(m.listenerCount, 0, "failed install must not leave a phantom listener")

        // A later start retries the install.
        XCTAssertTrue(m.start(), "after a failed install, the next start retries")
        XCTAssertEqual(m.listenerCount, 1)
    }

    /// Detach (device vanished mid-run) clears attachment but keeps the feeder
    /// searching — the listener stays registered so it re-attaches on return.
    func testDetachClearsAttachmentButKeepsListener() {
        var m = VCamLifecycleModel()
        m.start()
        m.attach()
        m.detach()
        XCTAssertFalse(m.attached)
        XCTAssertEqual(m.listenerCount, 1, "detach must not drop the watching listener")

        // Re-attaching returns to feeding without a new listener.
        XCTAssertFalse(m.start(), "still watching — no new listener needed")
        m.attach()
        XCTAssertEqual(m.phase, .feeding)
        XCTAssertEqual(m.listenerCount, 1)
    }
}
