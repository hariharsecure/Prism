import CoreMIDI
import Foundation

/// Headless self-verification of the control-surface layer (no MIDI hardware,
/// no TCC). It:
///   (a) builds real ``MIDIPacketList``s from synthetic bytes and runs them
///       through ``MIDIEngine``'s packet iterator + parser, asserting the
///       parsed ``MIDIMessage``s (noteOn/off, CC, pitch-bend, program change,
///       running status, multi-message packets, multi-packet lists, real-time
///       interleave);
///   (b) exercises ``MIDIActionMap`` learn, dispatch, unmapped no-op and the
///       CC→normalized fader value;
///   (c) round-trips a mapping through Codable;
///   (d) attempts to create a real `MIDIClientRef` and reports the outcome.
///
/// `run()` throws with a precise message on the first mismatch.
public enum ControlSurfaceSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case mismatch(String)
        case setup(String)
        public var description: String {
            switch self {
            case .mismatch(let s): return "control-surface self-test mismatch: \(s)"
            case .setup(let s): return "control-surface self-test setup failed: \(s)"
            }
        }
    }

    private static func expect(_ cond: Bool, _ msg: @autoclosure () -> String) throws {
        if !cond { throw SelfTestError.mismatch(msg()) }
    }

    /// Run all checks. Returns a short human-readable report (also covers the
    /// real-MIDIClient probe, which is best-effort).
    @discardableResult
    public static func run() throws -> String {
        try testParsing()
        try testRunningStatusAndMultiMessage()
        try testMultiPacketList()
        try testLearnAndDispatch()
        try testUnmappedNoOp()
        try testFaderNormalization()
        try testCodableRoundTrip()
        let clientReport = probeRealClient()
        print("ControlSurfaceSelfTest: all logic checks passed")
        print("ControlSurfaceSelfTest: \(clientReport)")
        return clientReport
    }

    // MARK: (a) Parsing via a real MIDIPacketList

    private static func testParsing() throws {
        // Each message routed through a fresh engine/source so running status is clean.
        try expect(parseOne([0x90, 0x3C, 0x64]) == .noteOn(note: 60, velocity: 100, channel: 0),
                   "noteOn parse")
        try expect(parseOne([0x80, 0x3C, 0x40]) == .noteOff(note: 60, velocity: 64, channel: 0),
                   "noteOff parse")
        try expect(parseOne([0x90, 0x3C, 0x00]) == .noteOff(note: 60, velocity: 0, channel: 0),
                   "noteOn velocity 0 → noteOff")
        try expect(parseOne([0xB0, 0x07, 0x40]) == .controlChange(cc: 7, value: 64, channel: 0),
                   "CC parse")
        try expect(parseOne([0xB3, 0x0A, 0x7F]) == .controlChange(cc: 10, value: 127, channel: 3),
                   "CC channel parse")
        try expect(parseOne([0xC1, 0x05]) == .programChange(program: 5, channel: 1),
                   "programChange parse")
        // Pitch bend: LSB=0x00, MSB=0x40 → 8192 (centre).
        try expect(parseOne([0xE0, 0x00, 0x40]) == .pitchBend(value: 8192, channel: 0),
                   "pitchBend centre parse")
        try expect(parseOne([0xE2, 0x7F, 0x7F]) == .pitchBend(value: 16383, channel: 2),
                   "pitchBend max parse")
    }

    private static func testRunningStatusAndMultiMessage() throws {
        // Running status: one status byte, two note-ons in a single packet.
        let running = parsePacket([0x90, 0x3C, 0x40, 0x3E, 0x50])
        try expect(running == [.noteOn(note: 60, velocity: 64, channel: 0),
                               .noteOn(note: 62, velocity: 80, channel: 0)],
                   "running status: \(running)")

        // Two distinct messages in one packet.
        let multi = parsePacket([0x90, 0x3C, 0x40, 0xB0, 0x07, 0x7F])
        try expect(multi == [.noteOn(note: 60, velocity: 64, channel: 0),
                             .controlChange(cc: 7, value: 127, channel: 0)],
                   "multi-message packet: \(multi)")

        // System Real-Time (0xF8 clock) interleaved mid-message must not disturb it.
        let interleaved = parsePacket([0x90, 0x3C, 0xF8, 0x40])
        try expect(interleaved == [.noteOn(note: 60, velocity: 64, channel: 0)],
                   "realtime interleave: \(interleaved)")
    }

    private static func testMultiPacketList() throws {
        // Two separate MIDIPackets in one list — exercises MIDIPacketNext walking
        // the real list memory.
        var out: [MIDIMessage] = []
        withPacketList([[0x90, 0x3C, 0x40], [0xB0, 0x07, 0x7F]]) { list in
            let engine = MIDIEngine()
            out = engine.parse(packetList: list, source: 7)
        }
        try expect(out == [.noteOn(note: 60, velocity: 64, channel: 0),
                           .controlChange(cc: 7, value: 127, channel: 0)],
                   "multi-packet list: \(out)")
    }

    // MARK: (b) Learn + dispatch

    private static func testLearnAndDispatch() throws {
        var map = MIDIActionMap()
        map.beginLearn(for: .startStream)

        let learnMsg = MIDIMessage.controlChange(cc: 20, value: 100, channel: 0)
        let duringLearn = map.process(learnMsg)
        try expect(duringLearn == nil, "learn message should not dispatch, got \(String(describing: duringLearn))")
        try expect(map.bindings[.cc(cc: 20, channel: 0)] == .startStream, "CC 20 should be bound to startStream")
        try expect(!map.isLearning, "learn should clear after capture")

        // Same CC again → fires the action.
        let fired = map.process(MIDIMessage.controlChange(cc: 20, value: 100, channel: 0))
        try expect(fired == .startStream, "bound CC should fire startStream, got \(String(describing: fired))")

        // A note bound to a discrete action fires on the down edge, not the up.
        map.bind(.startRecord, to: .note(note: 36, channel: 9))
        let down = map.process(MIDIMessage.noteOn(note: 36, velocity: 127, channel: 9))
        try expect(down == .startRecord, "noteOn down edge should fire startRecord")
        let up = map.process(MIDIMessage.noteOff(note: 36, velocity: 0, channel: 9))
        try expect(up == nil, "noteOff up edge should not fire, got \(String(describing: up))")
    }

    private static func testUnmappedNoOp() throws {
        var map = MIDIActionMap()
        map.bind(.startStream, to: .cc(cc: 20, channel: 0))
        let none = map.process(MIDIMessage.controlChange(cc: 99, value: 100, channel: 0))
        try expect(none == nil, "unmapped CC must fire nothing, got \(String(describing: none))")
    }

    private static func testFaderNormalization() throws {
        var map = MIDIActionMap()
        map.beginLearn(for: .setGain(channel: 1, value: 0))
        _ = map.process(MIDIMessage.controlChange(cc: 7, value: 64, channel: 0)) // learn

        let action = map.process(MIDIMessage.controlChange(cc: 7, value: 64, channel: 0))
        guard case let .setGain(channel, value)? = action else {
            throw SelfTestError.mismatch("fader should map to setGain, got \(String(describing: action))")
        }
        try expect(channel == 1, "fader channel preserved")
        // 64/127 = 0.503937...
        try expect(abs(value - 0.5039) < 0.001, "CC 64 → ~0.504, got \(value)")

        // Full-scale endpoints.
        let maxAction = map.process(MIDIMessage.controlChange(cc: 7, value: 127, channel: 0))
        guard case let .setGain(_, maxV)? = maxAction else {
            throw SelfTestError.mismatch("fader max should map to setGain")
        }
        try expect(abs(maxV - 1.0) < 0.0001, "CC 127 → 1.0, got \(maxV)")
    }

    // MARK: (c) Codable round-trip

    private static func testCodableRoundTrip() throws {
        var map = MIDIActionMap()
        map.bind(.switchScene(index: 2), to: .note(note: 60, channel: 0))
        map.bind(.setGain(channel: 3, value: 0), to: .cc(cc: 7, channel: 1))
        map.bind(.toggleMute(channel: 4), to: .cc(cc: 8, channel: 1))
        map.bind(.saveReplay, to: .programChange(program: 1, channel: 2))
        map.bind(.custom(id: "flair"), to: .pitchBend(channel: 5))

        let data = try map.jsonData()
        let restored = try MIDIActionMap(jsonData: data)

        try expect(restored.bindings.count == map.bindings.count, "binding count survives round-trip")
        for (trigger, action) in map.bindings {
            try expect(restored.bindings[trigger] == action,
                       "binding \(trigger)→\(action) survives round-trip (got \(String(describing: restored.bindings[trigger])))")
        }

        // Bytes should be stable (sorted output) across two encodes.
        let data2 = try restored.jsonData()
        try expect(data == data2, "encoding is deterministic")
    }

    // MARK: (d) Real MIDIClient probe (best-effort)

    private static func probeRealClient() -> String {
        let engine = MIDIEngine(clientName: "PrismControlSurfaceSelfTest")
        do {
            try engine.start()
            let sources = engine.connectedSourceCount
            engine.stop()
            return "real MIDIClient created OK headless (sources connected=\(sources))"
        } catch {
            return "real MIDIClient UNVERIFIED (headless start failed: \(error))"
        }
    }

    // MARK: Helpers

    /// Parse a single packet's bytes through the real MIDIEngine packet path.
    private static func parsePacket(_ bytes: [UInt8]) -> [MIDIMessage] {
        var out: [MIDIMessage] = []
        withPacketList([bytes]) { list in
            let engine = MIDIEngine()
            out = engine.parse(packetList: list, source: 1)
        }
        return out
    }

    /// Parse a packet expected to yield exactly one message.
    private static func parseOne(_ bytes: [UInt8]) -> MIDIMessage? {
        parsePacket(bytes).first
    }

    /// Build a real `MIDIPacketList` (one packet per element, distinct
    /// timestamps) and hand a pointer to `body`.
    private static func withPacketList(_ packets: [[UInt8]], _ body: (UnsafePointer<MIDIPacketList>) -> Void) {
        let capacity = 2048
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: capacity,
            alignment: MemoryLayout<MIDIPacketList>.alignment)
        defer { raw.deallocate() }
        let listPtr = raw.assumingMemoryBound(to: MIDIPacketList.self)

        var curPacket = MIDIPacketListInit(listPtr)
        var ts: MIDITimeStamp = 1
        for pkt in packets {
            curPacket = pkt.withUnsafeBufferPointer { buf in
                MIDIPacketListAdd(listPtr, capacity, curPacket, ts, buf.count, buf.baseAddress!)
            }
            ts &+= 1000
        }
        body(UnsafePointer(listPtr))
    }
}
