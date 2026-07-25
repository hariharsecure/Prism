import CryptoKit
import Foundation

/// Pure obs-websocket 5.x protocol logic: envelope encode/decode, the auth
/// string computation, RequestStatus codes and EventSubscription intents.
/// No I/O in this file — everything here is unit-exercisable in isolation.
///
/// Reference: obs-websocket protocol.md (v5). Envelope shape:
///   { "op": <opcode int>, "d": <object> }
public enum OBSWS {
    /// Protocol version we speak. rpcVersion is negotiated to exactly 1.
    public static let rpcVersion = 1
    /// Reported as `obsWebSocketVersion` in Hello/GetVersion.
    public static let serverVersion = "5.3.0"
    public static let subprotocolJSON = "obswebsocket.json"

    // MARK: Opcodes

    public enum OpCode: Int {
        case hello = 0
        case identify = 1
        case identified = 2
        case reidentify = 3
        case event = 5
        case request = 6
        case requestResponse = 7
        case requestBatch = 8
        case requestBatchResponse = 9
    }

    // MARK: RequestStatus codes (subset we emit)

    public enum RequestStatusCode: Int {
        case success = 100
        case unknownRequestType = 204
        case genericError = 205
        case notReady = 207
        case missingRequestField = 300
        case outputRunning = 500
        case outputNotRunning = 501
        case resourceNotFound = 600
    }

    // MARK: EventSubscription intent bits

    public struct EventSubscription: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let general = EventSubscription(rawValue: 1 << 0)
        public static let config = EventSubscription(rawValue: 1 << 1)
        public static let scenes = EventSubscription(rawValue: 1 << 2)
        public static let inputs = EventSubscription(rawValue: 1 << 3)
        public static let transitions = EventSubscription(rawValue: 1 << 4)
        public static let filters = EventSubscription(rawValue: 1 << 5)
        public static let outputs = EventSubscription(rawValue: 1 << 6)
        public static let sceneItems = EventSubscription(rawValue: 1 << 7)
        public static let mediaInputs = EventSubscription(rawValue: 1 << 8)
        public static let vendors = EventSubscription(rawValue: 1 << 9)
        public static let ui = EventSubscription(rawValue: 1 << 10)
        /// Default when Identify omits eventSubscriptions (all non-high-volume).
        public static let all = EventSubscription(rawValue: (1 << 11) - 1)
    }

    /// WebSocket close codes defined by obs-websocket.
    public enum CloseReason: UInt16 {
        case unknownOpCode = 4005
        case notIdentified = 4006
        case alreadyIdentified = 4007
        case authenticationFailed = 4009
        case unsupportedRpcVersion = 4010
        case sessionInvalidated = 4011
    }

    // MARK: Authentication

    /// obs-websocket auth string:
    ///   secret       = base64( SHA256( password + salt ) )
    ///   authResponse = base64( SHA256( secret + challenge ) )
    /// (string concatenation of UTF-8 text; the base64 *text* of the first
    /// hash is what gets concatenated with the challenge.)
    public static func authResponse(password: String, salt: String, challenge: String) -> String {
        let secret = Data(SHA256.hash(data: Data((password + salt).utf8))).base64EncodedString()
        return Data(SHA256.hash(data: Data((secret + challenge).utf8))).base64EncodedString()
    }

    /// Constant-time string equality for the auth check: folds the length check
    /// and every byte comparison into a single accumulator so it never
    /// short-circuits on the first mismatch, denying an attacker a timing oracle
    /// on how many leading characters of the expected auth response matched.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        var diff = UInt8(ab.count == bb.count ? 0 : 1)
        let n = Swift.max(ab.count, bb.count)
        var i = 0
        while i < n {
            let x = i < ab.count ? ab[i] : 0
            let y = i < bb.count ? bb[i] : 0
            diff |= (x ^ y)
            i += 1
        }
        return diff == 0
    }

    /// Random base64 token for Hello's salt/challenge.
    public static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
    }

    // MARK: Envelope encode/decode (JSONSerialization; payloads are open-shaped)

    public enum ProtocolError: Error {
        case notAnObject
        case missingOp
        case unknownOp(Int)
        case missingData
    }

    public struct Envelope {
        public let op: OpCode
        public let d: [String: Any]
        public init(op: OpCode, d: [String: Any]) {
            self.op = op
            self.d = d
        }
    }

    public static func decodeEnvelope(_ data: Data) throws -> Envelope {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProtocolError.notAnObject
        }
        guard let opRaw = obj["op"] as? Int else { throw ProtocolError.missingOp }
        guard let op = OpCode(rawValue: opRaw) else { throw ProtocolError.unknownOp(opRaw) }
        guard let d = obj["d"] as? [String: Any] else { throw ProtocolError.missingData }
        return Envelope(op: op, d: d)
    }

    public static func encodeEnvelope(_ envelope: Envelope) -> Data {
        let object: [String: Any] = ["op": envelope.op.rawValue, "d": envelope.d]
        if let data = try? JSONSerialization.data(withJSONObject: object) { return data }
        // A value slipped through un-sanitized (e.g. a non-finite Double that
        // JSONSerialization rejects). Retry with a sanitized payload so the client
        // still gets a WELL-FORMED envelope carrying its requestId (L2) instead of
        // a bare `{}` that discards the whole response.
        let sanitized: [String: Any] = ["op": envelope.op.rawValue, "d": sanitizedForJSON(envelope.d)]
        if let data = try? JSONSerialization.data(withJSONObject: sanitized) { return data }
        // Last resort: a valid envelope preserving the op (and requestId, if any).
        var minimal: [String: Any] = ["op": envelope.op.rawValue]
        var inner: [String: Any] = [:]
        if let id = envelope.d["requestId"] as? String { inner["requestId"] = id }
        minimal["d"] = inner
        return (try? JSONSerialization.data(withJSONObject: minimal))
            ?? Data("{\"op\":\(envelope.op.rawValue),\"d\":{}}".utf8)
    }

    /// Recursively replaces JSON-illegal numbers (non-finite `Double`/`Float`, or
    /// NSNumber-wrapped non-finite doubles) with `0` so a single NaN/inf backend
    /// field can't collapse the whole response to `{}` (L2). Applied at the
    /// response-mapping boundary (`requestResponse`/`event`) and again as a
    /// backstop in `encodeEnvelope`.
    static func sanitizedForJSON(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.mapValues { sanitizedForJSON($0) }
        case let array as [Any]:
            return array.map { sanitizedForJSON($0) }
        case let n as NSNumber:
            // Swift Double/Float/Int/Bool all bridge to NSNumber here. Only a
            // non-finite FLOATING value is illegal for JSON; replace just those
            // with 0 and leave everything else (integers, bools, finite doubles)
            // EXACTLY as-is so numeric types and precision are preserved.
            return n.doubleValue.isFinite ? value : 0.0
        default:
            return value
        }
    }

    // MARK: Message builders (pure)

    public static func hello(authentication: (challenge: String, salt: String)?) -> Envelope {
        var d: [String: Any] = [
            "obsWebSocketVersion": serverVersion,
            "rpcVersion": rpcVersion,
        ]
        if let auth = authentication {
            d["authentication"] = ["challenge": auth.challenge, "salt": auth.salt]
        }
        return Envelope(op: .hello, d: d)
    }

    public static func identified() -> Envelope {
        Envelope(op: .identified, d: ["negotiatedRpcVersion": rpcVersion])
    }

    public static func event(type: String, intent: EventSubscription, data: [String: Any]?) -> Envelope {
        var d: [String: Any] = ["eventType": type, "eventIntent": intent.rawValue]
        if let data { d["eventData"] = sanitizedForJSON(data) }
        return Envelope(op: .event, d: d)
    }

    public static func requestResponse(requestType: String, requestId: String,
                                       code: RequestStatusCode, comment: String? = nil,
                                       responseData: [String: Any]? = nil) -> Envelope {
        var status: [String: Any] = [
            "result": code == .success,
            "code": code.rawValue,
        ]
        if let comment { status["comment"] = comment }
        var d: [String: Any] = [
            "requestType": requestType,
            "requestId": requestId,
            "requestStatus": status,
        ]
        // Sanitize at the mapping boundary: a non-finite backend double (NaN/inf
        // congestion, fps, …) must not make the whole response un-encodable (L2).
        if let responseData { d["responseData"] = sanitizedForJSON(responseData) }
        return Envelope(op: .requestResponse, d: d)
    }

    /// Maps a backend error onto the RequestStatus code + comment it should produce.
    public static func status(for error: Error) -> (code: RequestStatusCode, comment: String?) {
        guard let e = error as? ControlBackendError else {
            return (.genericError, String(describing: error))
        }
        switch e {
        case .sceneNotFound(let name): return (.resourceNotFound, "No scene named '\(name)'.")
        case .outputRunning: return (.outputRunning, "The output is already active.")
        case .outputNotRunning: return (.outputNotRunning, "The output is not active.")
        case .notReady: return (.notReady, "The engine is not ready.")
        case .failed(let why): return (.genericError, why)
        }
    }

    /// Formats seconds as an OBS timecode string "HH:MM:SS.mmm".
    public static func timecode(seconds: Double) -> String {
        let clamped = max(0, seconds)
        let totalMs = Int((clamped * 1000).rounded())
        let ms = totalMs % 1000
        let s = (totalMs / 1000) % 60
        let m = (totalMs / 60_000) % 60
        let h = totalMs / 3_600_000
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}
