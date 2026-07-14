import Foundation
import XCTest

@testable import Prism

/// Peer-connect (PrismLink) is OPT-IN, OFF BY DEFAULT.
///
/// Root cause fixed here: the Link server used to be started UNCONDITIONALLY
/// from `AppEngine.init` (`startLinkServer()`), so every launch created a TLS
/// identity (`LinkIdentity.createEphemeral` → macOS keychain prompt) and
/// advertised over Bonjour even when the user never used peer connect.
///
/// The fix gates the server behind `linkEnabled` (default false) + a
/// `setLinkEnabled(_:)` toggle. These tests validate the gate three ways:
///  1. Default construction does NOT start the server (no listener, no
///     identity path, no advertisement).
///  2. The toggle starts/stops the server and is idempotent both directions.
///  3. When enabled the listener actually binds + reaches "ready" (proving the
///     identity/QUIC path still runs exactly as before — the feature works).
@MainActor
final class LinkOptInGateTests: XCTestCase {

    /// (1) Default-off: constructing the engine must NOT start the Link server.
    /// Observable seam: `linkEnabled == false`, listener state is the inert
    /// "off" (never "starting"/"ready"), no bound port, advertising is off.
    /// If the server had started, `linkListenerState` would be "starting"/…
    /// and the identity/keychain path would have run.
    func testDefaultDoesNotStartLinkServer() {
        let engine = AppEngine()
        XCTAssertFalse(engine.linkEnabled,
                       "peer-connect must be OFF by default")
        XCTAssertEqual(engine.linkListenerState, "off",
                       "no listener may run on launch — state must be inert 'off', not 'starting'")
        XCTAssertNil(engine.linkPort,
                     "no port may be bound while peer-connect is off")
        XCTAssertFalse(engine.linkAdvertising,
                       "Bonjour must not advertise while peer-connect is off")
    }

    /// (2) The toggle starts the server, and is idempotent + reversible.
    /// Gated: enabling runs the real `LinkIdentity.createEphemeral` keychain +
    /// signing path, which prompts/blocks until the key-ACL fix lands (runtime
    /// is off-by-default so unaffected). Run with `PRISM_TEST_LINK_KEYCHAIN=1`.
    func testSetLinkEnabledTogglesAndIsIdempotent() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PRISM_TEST_LINK_KEYCHAIN"] == "1",
                          "skipped: enabling Link runs the interactive keychain path — set PRISM_TEST_LINK_KEYCHAIN=1")
        let engine = AppEngine()

        // Enable → server starts (state leaves "off", advertising turns on).
        engine.setLinkEnabled(true)
        XCTAssertTrue(engine.linkEnabled)
        XCTAssertNotEqual(engine.linkListenerState, "off",
                          "enabling must start the listener (state transitions off → starting/ready)")
        XCTAssertTrue(engine.linkAdvertising,
                      "enabling opts into Bonjour advertisement")

        // Enabling again is a no-op (does not double-start / crash).
        engine.setLinkEnabled(true)
        XCTAssertTrue(engine.linkEnabled)

        // Disable → server stops, state returns to inert "off", port cleared.
        engine.setLinkEnabled(false)
        XCTAssertFalse(engine.linkEnabled)
        XCTAssertEqual(engine.linkListenerState, "off")
        XCTAssertNil(engine.linkPort)
        XCTAssertFalse(engine.linkAdvertising)

        // Disabling again is a no-op.
        engine.setLinkEnabled(false)
        XCTAssertFalse(engine.linkEnabled)
        XCTAssertEqual(engine.linkListenerState, "off")
    }

    /// (3) When opted in, the listener actually binds and reaches "ready" —
    /// proving the full start path (QUIC listener + ephemeral identity) still
    /// runs exactly as before. Reaching "ready" fires only after the identity
    /// is created and the listener binds, so this is a live end-to-end signal.
    func testEnabledListenerReachesReady() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PRISM_TEST_LINK_KEYCHAIN"] == "1",
                          "skipped: enabling Link runs the interactive keychain path — set PRISM_TEST_LINK_KEYCHAIN=1")
        let engine = AppEngine()
        let ready = expectation(description: "link listener reaches ready")

        // Poll the published state (updated on the main actor by the listener
        // state-change callback) until it binds.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                if engine.linkListenerState == "ready", engine.linkPort != nil {
                    ready.fulfill()
                }
            }
        }
        engine.setLinkEnabled(true)
        wait(for: [ready], timeout: 15)
        timer.invalidate()

        XCTAssertEqual(engine.linkListenerState, "ready")
        XCTAssertNotNil(engine.linkPort, "a ready listener must report a bound UDP port")

        engine.setLinkEnabled(false) // tear down (removes the ephemeral identity)
    }
}
