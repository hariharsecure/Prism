import XCTest
@testable import PrismOutput

/// #20 — configuring ZERO reconnect attempts must actually mean "no reconnect".
/// The pre-fix disconnect loop was `for attempt in 1...max(1, maxReconnectAttempts)`,
/// which clamped a configured 0 UP to 1 and always retried exactly once —
/// contradicting the setting. The fix routes the loop through
/// `reconnectAttempts(max:)`, which is EMPTY for 0 so the loop never runs.
///
/// This is the pure, socket-free seam the disconnect handler now iterates, so the
/// "0 → zero attempts" contract is checked deterministically for both transports.
final class ReconnectAttemptsClampTests: XCTestCase {

    /// RTMP: 0 configured → the reconnect sequence is EMPTY (zero attempts).
    func testRTMPZeroReconnectAttemptsMakesEmptySequence() {
        let attempts = RTMPStreamOutput.reconnectAttempts(max: 0)
        XCTAssertTrue(attempts.isEmpty, "#20: 0 configured attempts must retry ZERO times, not once")
        XCTAssertEqual(Array(attempts).count, 0)
        // A negative (shouldn't occur; setter clamps to 0) is also no-reconnect.
        XCTAssertTrue(RTMPStreamOutput.reconnectAttempts(max: -3).isEmpty)
    }

    /// RTMP: a positive N yields exactly N attempts numbered 1…N (unchanged).
    func testRTMPPositiveReconnectAttemptsPreserved() {
        XCTAssertEqual(Array(RTMPStreamOutput.reconnectAttempts(max: 1)), [1])
        XCTAssertEqual(Array(RTMPStreamOutput.reconnectAttempts(max: 3)), [1, 2, 3])
        XCTAssertEqual(Array(RTMPStreamOutput.reconnectAttempts(max: 5)), [1, 2, 3, 4, 5])
    }

    /// SRT: same contract — 0 configured → empty sequence (zero attempts).
    func testSRTZeroReconnectAttemptsMakesEmptySequence() {
        let attempts = SRTStreamOutput.reconnectAttempts(max: 0)
        XCTAssertTrue(attempts.isEmpty, "#20: 0 configured attempts must retry ZERO times, not once")
        XCTAssertTrue(SRTStreamOutput.reconnectAttempts(max: -1).isEmpty)
    }

    /// SRT: a positive N yields exactly N attempts numbered 1…N (unchanged).
    func testSRTPositiveReconnectAttemptsPreserved() {
        XCTAssertEqual(Array(SRTStreamOutput.reconnectAttempts(max: 1)), [1])
        XCTAssertEqual(Array(SRTStreamOutput.reconnectAttempts(max: 4)), [1, 2, 3, 4])
    }
}
