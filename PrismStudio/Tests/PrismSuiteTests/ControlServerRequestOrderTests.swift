import Foundation
import XCTest
@testable import PrismControl
import PrismCore

/// Final-hunt M1: the obs-websocket control server preserves per-session request
/// ORDER. Previously each op-6 request spawned an independent unstructured Task,
/// so a client's `StopStream` then `StartStream` could interleave and leave the
/// stream STARTED when the user meant stopped. The fix chains each request behind
/// the session's previous one (a serial per-session queue), so backend calls
/// apply — and responses are emitted — in requestId order.
///
/// This is a real loopback integration test: a `URLSessionWebSocketTask` speaks
/// the obs-websocket handshake to a live `ControlServer`, and a mock backend
/// whose `stopStream` is deliberately SLOW records the true apply order.
final class ControlServerRequestOrderTests: XCTestCase {

    /// Records the order backend mutations actually apply. `stopStream` sleeps so
    /// that, absent serialization, the immediate `startStream` would record first.
    private final class OrderRecordingBackend: ControlBackend, @unchecked Sendable {
        let lock = NSLock()
        private(set) var calls: [String] = []
        let stopDelay: TimeInterval
        init(stopDelay: TimeInterval) { self.stopDelay = stopDelay }

        private func record(_ s: String) { lock.lock(); calls.append(s); lock.unlock() }
        func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return calls }

        func stopStream() async throws {
            try? await Task.sleep(nanoseconds: UInt64(stopDelay * 1_000_000_000))
            record("stop")
        }
        func startStream() async throws { record("start") }

        // Unused-by-this-test surface.
        func sceneList() async -> [String] { [] }
        func currentProgramScene() async -> String { "" }
        func setCurrentProgramScene(_ name: String) async throws {}
        func startRecord() async throws {}
        func stopRecord() async throws -> String? { nil }
        func recordStatus() async -> RecordStatus { RecordStatus() }
        func streamStatus() async -> StreamStatus { StreamStatus() }
        func stats() async -> EngineStats { EngineStats() }
    }

    private func envelope(_ op: Int, _ d: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["op": op, "d": d])
        return String(decoding: data, as: UTF8.self)
    }

    /// Send `text` and wait for the next inbound message's decoded op.
    private func exchange(_ task: URLSessionWebSocketTask, send text: String? = nil,
                          timeout: TimeInterval = 5) throws -> [String: Any] {
        if let text { sendAndWait(task, text: text) }
        let sem = DispatchSemaphore(value: 0)
        var received: [String: Any] = [:]
        task.receive { result in
            if case .success(.string(let s)) = result,
               let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] {
                received = obj
            }
            sem.signal()
        }
        XCTAssertEqual(sem.wait(timeout: .now() + timeout), .success, "timed out waiting for a WS message")
        return received
    }

    private func sendAndWait(_ task: URLSessionWebSocketTask, text: String) {
        let sem = DispatchSemaphore(value: 0)
        task.send(.string(text)) { _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 5)
    }

    func testStopThenStartAppliesInOrder() throws {
        let port: UInt16 = 47_820
        let server = ControlServer(port: port)   // loopback, no password
        let backend = OrderRecordingBackend(stopDelay: 0.20)
        server.backend = backend
        try server.start()
        defer { server.stop() }

        let url = URL(string: "ws://127.0.0.1:\(port)")!
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        // op 0 Hello → op 1 Identify → op 2 Identified.
        let hello = try exchange(task)
        XCTAssertEqual(hello["op"] as? Int, OBSWS.OpCode.hello.rawValue)
        let identified = try exchange(task, send: envelope(1, ["rpcVersion": OBSWS.rpcVersion]))
        XCTAssertEqual(identified["op"] as? Int, OBSWS.OpCode.identified.rawValue)

        // Fire StopStream then StartStream back-to-back (the reproduce sequence).
        sendAndWait(task, text: envelope(6, ["requestType": "StopStream", "requestId": "r1"]))
        sendAndWait(task, text: envelope(6, ["requestType": "StartStream", "requestId": "r2"]))

        // Collect both op-7 responses; assert they arrive in requestId order.
        let resp1 = try exchange(task)
        let resp2 = try exchange(task)
        let id1 = (resp1["d"] as? [String: Any])?["requestId"] as? String
        let id2 = (resp2["d"] as? [String: Any])?["requestId"] as? String
        XCTAssertEqual([id1, id2], ["r1", "r2"], "responses must arrive in requestId order")

        // The decisive assertion: the SLOW stop applied BEFORE the fast start.
        XCTAssertEqual(backend.snapshot(), ["stop", "start"],
                       "StopStream must fully apply before StartStream — no interleave")
    }
}
