import Foundation
import XCTest
@testable import PrismControl

/// THE BUG: the obs-websocket control server (`ControlServer`) defaulted to NO
/// password and bound ALL interfaces. Any device on the LAN could connect and
/// drive `StartRecord`/`StopRecord`/`StartStream`/`StopStream` unauthenticated.
///
/// THE FIX: bind loopback-only by default (same-Mac Stream Deck/Companion still
/// work), and fail-closed — refuse to start a network-reachable (non-loopback)
/// bind unless a password is set (`ServerError.passwordRequiredForNetworkBind`).
///
/// What this proves: the default is safe, and the network-bind footgun is
/// refused without a password. (Actual reachability of a bound socket is an
/// OS/integration concern; here we lock the construction/start contract.)
final class ControlServerAuthBindTests: XCTestCase {

    /// Pick a high port unlikely to collide so start() can bind in CI.
    private func port() -> UInt16 { 47_800 }

    /// Default construction is loopback-only + no password → start() succeeds
    /// (same-Mac control surface keeps working).
    func testDefaultLoopbackStartsWithoutPassword() throws {
        let server = ControlServer(port: port())
        defer { server.stop() }
        XCTAssertNoThrow(try server.start(), "loopback default must start without a password")
    }

    /// A network-reachable bind with no password is refused — fail closed.
    func testNetworkBindWithoutPasswordThrows() {
        let server = ControlServer(port: port() &+ 1, password: nil, bindLoopbackOnly: false)
        defer { server.stop() }
        XCTAssertThrowsError(try server.start()) { error in
            guard case ControlServer.ServerError.passwordRequiredForNetworkBind = error else {
                return XCTFail("expected passwordRequiredForNetworkBind, got \(error)")
            }
        }
    }

    /// A network-reachable bind WITH a password is allowed (the user opted in).
    func testNetworkBindWithPasswordStarts() throws {
        let server = ControlServer(port: port() &+ 2, password: "s3cret", bindLoopbackOnly: false)
        defer { server.stop() }
        XCTAssertNoThrow(try server.start())
    }
}
