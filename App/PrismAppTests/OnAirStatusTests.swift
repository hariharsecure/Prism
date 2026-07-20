import XCTest
@testable import Prism

/// THE BUG (found by cross-lineage review, 2026-07): `isOnAir` was
/// `isRecording || vcamOutputEnabled` — it OMITTED streaming. So while actively
/// broadcasting to RTMP/SRT (but not recording and not running the virtual
/// camera), the app reported "not on air" — a false operator status on the one
/// indicator a live producer trusts most.
///
/// THE FIX: fold `isStreaming` into the predicate, extracted pure as
/// `AppEngine.computeOnAir(recording:vcam:streaming:)` so this contract is
/// guarded and a future refactor can't silently drop an output again.
@MainActor
final class OnAirStatusTests: XCTestCase {

    /// The regression itself: streaming alone must read as on-air.
    func testStreamingAloneIsOnAir() {
        XCTAssertTrue(AppEngine.computeOnAir(recording: false, vcam: false, streaming: true),
                      "broadcasting to RTMP/SRT must count as on-air")
    }

    /// Each live output independently makes the app on-air.
    func testEachOutputCountsOnAir() {
        XCTAssertTrue(AppEngine.computeOnAir(recording: true, vcam: false, streaming: false))
        XCTAssertTrue(AppEngine.computeOnAir(recording: false, vcam: true, streaming: false))
        XCTAssertTrue(AppEngine.computeOnAir(recording: false, vcam: false, streaming: true))
    }

    /// Only when NOTHING is live is the app off-air.
    func testNoOutputIsOffAir() {
        XCTAssertFalse(AppEngine.computeOnAir(recording: false, vcam: false, streaming: false))
    }

    /// A freshly-constructed engine is off-air.
    func testFreshEngineIsOffAir() {
        let engine = AppEngine()
        XCTAssertFalse(engine.isOnAir, "a just-launched engine has no live output")
    }
}
