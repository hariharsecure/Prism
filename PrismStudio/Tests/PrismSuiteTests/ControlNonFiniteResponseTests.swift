import Foundation
import XCTest
@testable import PrismControl

/// Final-hunt L2 + cheap hardening in the obs-websocket protocol layer:
///  - L2: a non-finite backend Double (NaN/inf congestion, fps, …) must NOT
///    collapse the whole response to a bare `{}` that discards the requestId.
///    It is sanitized at the mapping boundary, and `encodeEnvelope` never emits a
///    bare `{}` for a request.
///  - Constant-time auth compare exists and is correct.
final class ControlNonFiniteResponseTests: XCTestCase {

    private func decode(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - L2: non-finite doubles sanitized, requestId preserved

    /// REPRODUCE: a GetStats-shaped response carrying a NaN field. Pre-fix,
    /// `encodeEnvelope` hit JSONSerialization's non-finite rejection and returned
    /// `Data("{}")` — the client got an empty object with NO requestId. Post-fix,
    /// the response is well-formed, carries the requestId, and the NaN became a
    /// finite 0.
    func testNaNStatsFieldYieldsValidResponseWithRequestId() throws {
        let env = OBSWS.requestResponse(
            requestType: "GetStats", requestId: "req-42", code: .success,
            responseData: ["cpuUsage": Double.nan,
                           "activeFps": Double.infinity,
                           "memoryUsage": -Double.infinity,
                           "renderTotalFrames": 120])
        let data = OBSWS.encodeEnvelope(env)

        XCTAssertNotEqual(String(decoding: data, as: UTF8.self), "{}", "must not collapse to a bare {}")
        let obj = try XCTUnwrap(decode(data), "response must be valid JSON")
        XCTAssertEqual(obj["op"] as? Int, OBSWS.OpCode.requestResponse.rawValue)
        let d = try XCTUnwrap(obj["d"] as? [String: Any])
        XCTAssertEqual(d["requestId"] as? String, "req-42", "requestId must survive")
        let rd = try XCTUnwrap(d["responseData"] as? [String: Any])
        // NaN/inf were sanitized to finite 0; the finite field passes through.
        XCTAssertEqual(rd["cpuUsage"] as? Double, 0)
        XCTAssertEqual(rd["activeFps"] as? Double, 0)
        XCTAssertEqual((rd["renderTotalFrames"] as? NSNumber)?.intValue, 120)
    }

    /// The direct sanitizer contract, including nested containers.
    func testSanitizerReplacesNonFiniteRecursively() {
        let input: [String: Any] = [
            "a": Double.nan,
            "b": [Double.infinity, 1.5, -Double.infinity] as [Any],
            "c": ["inner": Float.nan, "ok": 3] as [String: Any],
            "d": "text",
            "e": true,
        ]
        let out = OBSWS.sanitizedForJSON(input) as? [String: Any]
        XCTAssertEqual(out?["a"] as? Double, 0)
        let arr = out?["b"] as? [Any]
        XCTAssertEqual(arr?[0] as? Double, 0)
        XCTAssertEqual(arr?[1] as? Double, 1.5)
        XCTAssertEqual(arr?[2] as? Double, 0)
        let inner = out?["c"] as? [String: Any]
        XCTAssertEqual(inner?["ok"] as? Int, 3)
        XCTAssertEqual(out?["d"] as? String, "text")
        XCTAssertEqual(out?["e"] as? Bool, true)
        // The whole thing must now be JSON-encodable.
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: out as Any))
    }

    /// A GetStreamStatus-shaped response with a NaN congestion still encodes.
    func testStreamStatusNaNCongestionEncodes() throws {
        let env = OBSWS.requestResponse(
            requestType: "GetStreamStatus", requestId: "s1", code: .success,
            responseData: ["outputActive": true, "outputCongestion": Double.nan,
                           "outputBytes": 4096])
        let data = OBSWS.encodeEnvelope(env)
        let obj = try XCTUnwrap(decode(data))
        let d = try XCTUnwrap(obj["d"] as? [String: Any])
        XCTAssertEqual(d["requestId"] as? String, "s1")
        let rd = try XCTUnwrap(d["responseData"] as? [String: Any])
        XCTAssertEqual(rd["outputCongestion"] as? Double, 0)
        XCTAssertEqual(rd["outputActive"] as? Bool, true)
    }

    /// NEGATIVE CONTROL: an all-finite response is byte-identical in shape — the
    /// sanitizer must not perturb legitimate numbers.
    func testFiniteResponseUnchanged() throws {
        let env = OBSWS.requestResponse(
            requestType: "GetStats", requestId: "ok", code: .success,
            responseData: ["cpuUsage": 42.5, "activeFps": 60.0])
        let obj = try XCTUnwrap(decode(OBSWS.encodeEnvelope(env)))
        let rd = try XCTUnwrap((obj["d"] as? [String: Any])?["responseData"] as? [String: Any])
        XCTAssertEqual(rd["cpuUsage"] as? Double, 42.5)
        XCTAssertEqual(rd["activeFps"] as? Double, 60.0)
    }

    // MARK: - Constant-time auth compare

    func testConstantTimeEqualsMatchesEquality() {
        XCTAssertTrue(OBSWS.constantTimeEquals("", ""))
        XCTAssertTrue(OBSWS.constantTimeEquals("abc123", "abc123"))
        XCTAssertFalse(OBSWS.constantTimeEquals("abc123", "abc124"))
        XCTAssertFalse(OBSWS.constantTimeEquals("abc", "abcd"))      // length differs
        XCTAssertFalse(OBSWS.constantTimeEquals("abcd", "abc"))
        XCTAssertFalse(OBSWS.constantTimeEquals("secret", ""))
        // A realistic auth-response pair (base64 SHA256 shapes).
        let a = OBSWS.authResponse(password: "pw", salt: "salt", challenge: "chal")
        let b = OBSWS.authResponse(password: "pw", salt: "salt", challenge: "chal")
        XCTAssertTrue(OBSWS.constantTimeEquals(a, b))
        let c = OBSWS.authResponse(password: "pw2", salt: "salt", challenge: "chal")
        XCTAssertFalse(OBSWS.constantTimeEquals(a, c))
    }
}
