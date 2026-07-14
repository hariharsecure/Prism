import Foundation
import XCTest
@testable import PrismVirtualCam

/// THE BUG: the virtual-camera SINK (`PrismExtensionStreamSink`) returned `true`
/// from `authorizedToStartStream(for:)` for EVERY client — any local process
/// could open the CMIO sink and inject frames onto the "Prism Camera" that
/// Zoom/Meet/FaceTime consume.
///
/// THE FIX: gate the sink on `client.signingID` — only a client whose signing ID
/// carries Prism's bundle prefix (the app is `studio.prism.app`) may feed. The
/// decision is `PrismVCamConstants.isAuthorizedSinkClient(signingID:)`, extracted
/// pure so it can be unit-tested (a live `CMIOExtensionClient` cannot be built
/// headless). This test proves the predicate; it cannot exercise the OS callback.
///
/// Honest scope: CMIO surfaces only `signingID` here, not a full `SecCode`, so
/// this is a bundle-prefix gate, not a team-ID/cdhash designated requirement — it
/// blocks casual/foreign injection, not a process forging this exact signing ID.
final class VCamSinkAuthorizationTests: XCTestCase {

    func testPrismAppIsAuthorized() {
        XCTAssertTrue(PrismVCamConstants.isAuthorizedSinkClient(signingID: "studio.prism.app"))
    }

    func testPrismFirstPartyHelpersAuthorized() {
        XCTAssertTrue(PrismVCamConstants.isAuthorizedSinkClient(signingID: "studio.prism.PrismStudio.vcam"))
        XCTAssertTrue(PrismVCamConstants.isAuthorizedSinkClient(signingID: "studio.prism.camera"))
    }

    func testForeignClientRejected() {
        XCTAssertFalse(PrismVCamConstants.isAuthorizedSinkClient(signingID: "com.evil.injector"))
        XCTAssertFalse(PrismVCamConstants.isAuthorizedSinkClient(signingID: "studio.prismatic.app"),
                       "a look-alike prefix that isn't 'studio.prism.' must not pass")
    }

    func testMissingOrEmptySigningIDRejected() {
        XCTAssertFalse(PrismVCamConstants.isAuthorizedSinkClient(signingID: nil))
        XCTAssertFalse(PrismVCamConstants.isAuthorizedSinkClient(signingID: ""))
    }
}
