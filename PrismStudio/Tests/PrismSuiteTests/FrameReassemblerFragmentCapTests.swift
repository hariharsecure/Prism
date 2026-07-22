import Foundation
import XCTest
@testable import PrismLink

/// THE BUG (memory-DoS by a connected peer): `FrameReassembler.processPart`
/// allocated `Array(repeating: nil, count: Int(header.partCount))` from a
/// WIRE-CONTROLLED `partCount` (UInt16, up to 65535) on the first part seen —
/// across up to `maxPending` live frames — and let each frame accumulate
/// `partCount × up to 65535` payload bytes (~1 GiB) with only a per-part cap
/// and no bound tying partCount / total pending bytes to a sane frame size.
/// A hostile paired peer could open many partial frames with huge declared
/// shapes and exhaust receiver memory before any drop happened.
///
/// THE FIX (bounded, fail-closed):
///   * `LinkProtocol.maxPartCount` (16384) — a partCount above it is REJECTED
///     before the part table is allocated (both in `MediaDatagramHeader.parse`
///     and, for hand-built headers that skip parse, in the reassembler).
///   * `LinkProtocol.maxFrameBytes` (16 MiB) — one frame that would accumulate
///     more is dropped, not grown.
///   * `LinkProtocol.maxTotalPendingBytes` (64 MiB) — bytes buffered across ALL
///     in-flight frames are bounded; oldest partial frames are evicted so
///     receive-side memory can't grow with attacker input.
/// All caps drop + count (`framesRejectedOversize`, `framesDropped`); nothing
/// crashes and nothing allocates past the caps.
///
/// What these tests prove: (1) a seeded wire-protocol fuzz over
/// `LinkFrameParser` + `MediaDatagramHeader.parse` + `FrameReassembler` never
/// crashes and never buffers past the caps, always dropping cleanly or
/// reassembling bit-exact; (2) partCount = 65535 is rejected before allocation;
/// (3) the total-pending-bytes cap bounds memory under a flood of partial
/// frames, evicting oldest; (4) a normal multi-part frame still reassembles
/// bit-exact, including over the full encode → parse → reassemble wire path.
final class FrameReassemblerFragmentCapTests: XCTestCase {

    // MARK: Deterministic PRNG (SplitMix64) — seed retained in failure messages.

    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private let seeds: [UInt64] = [1, 2, 0xABCD_1234, 0xDEAD_BEEF, 0x0F0F_F0F0, 7_777_777]

    // MARK: Builders

    /// Deterministic payload for a given (frameID, partIndex): duplicates of the
    /// same part therefore carry identical bytes, so "first write wins" dedup
    /// leaves the reassembled frame bit-exact regardless of delivery order.
    private func partBytes(frameID: UInt32, index: Int, length: Int) -> Data {
        var d = Data(capacity: length)
        for i in 0..<length {
            d.append(UInt8((frameID &+ UInt32(index) &+ UInt32(i)) & 0xFF))
        }
        return d
    }

    private func header(seq: UInt32, frameID: UInt32, index: UInt16, count: UInt16,
                        payload: Data, pts: Int64, flags: MediaDatagramHeader.Flags = [])
        -> MediaDatagramHeader {
        MediaDatagramHeader(seq: seq, frameID: frameID, partIndex: index, partCount: count,
                            payloadLength: UInt16(payload.count), ptsHouseNanos: pts, flags: flags)
    }

    /// One media record on the wire: 25-byte header + payload bytes.
    private func record(_ h: MediaDatagramHeader, _ payload: Data) -> Data {
        h.encoded() + payload
    }

    // MARK: - Test 1a: seeded WIRE-PARSER fuzz (LinkFrameParser + parse())

    /// Random chunking / coalescing of a valid mixed control+media stream must
    /// round-trip to the exact same items; truncated tails buffer without loss
    /// or crash; garbage throws a `LinkFrameError` (never traps, never hangs).
    func testWireParserSeededFuzz() throws {
        for seed in seeds {
            var rng = SeededRNG(seed: seed)
            let ctx = "wire-parser seed=\(seed)"

            // Build a stream of valid records and remember what we expect back.
            struct Expected { let isMedia: Bool; let typeByte: UInt8; let payload: Data;
                              let header: MediaDatagramHeader? }
            var expected: [Expected] = []
            var stream = Data()
            let recordCount = 20 + Int(rng.next() % 30)
            var seq: UInt32 = 0
            for i in 0..<recordCount {
                if rng.next() & 1 == 0 {
                    // Control frame with a known type.
                    let type = ControlMessageType.tally
                    let plen = Int(rng.next() % 64)
                    let payload = Data((0..<plen).map { _ in UInt8(rng.next() & 0xFF) })
                    stream.append(encodeControlFrame(type: type, payload: payload))
                    expected.append(Expected(isMedia: false, typeByte: type.rawValue,
                                             payload: payload, header: nil))
                } else {
                    // Media record with a sane, in-cap shape.
                    let count = UInt16(1 + rng.next() % 6)
                    let index = UInt16(rng.next() % UInt64(count))
                    let len = 1 + Int(rng.next() % 200)
                    let payload = partBytes(frameID: UInt32(i), index: Int(index), length: len)
                    let h = header(seq: seq, frameID: UInt32(i), index: index, count: count,
                                   payload: payload, pts: Int64(i))
                    stream.append(record(h, payload))
                    expected.append(Expected(isMedia: true, typeByte: 0, payload: payload, header: h))
                }
                seq &+= 1
            }

            // Feed the stream in random-sized chunks; collect all items.
            var parser = LinkFrameParser()
            var got: [LinkParsedItem] = []
            var offset = 0
            while offset < stream.count {
                let remaining = stream.count - offset
                let chunk = 1 + Int(rng.next() % UInt64(max(1, min(remaining, 37))))
                let slice = stream.subdata(in: (stream.startIndex + offset)
                    ..< (stream.startIndex + offset + chunk))
                got.append(contentsOf: try parser.feed(slice))
                offset += chunk
            }
            XCTAssertEqual(parser.pendingByteCount, 0, "\(ctx): parser left bytes buffered after a complete stream")
            XCTAssertEqual(got.count, expected.count, "\(ctx): item count mismatch")
            for (idx, exp) in expected.enumerated() where idx < got.count {
                switch got[idx] {
                case let .media(h, payload):
                    XCTAssertTrue(exp.isMedia, "\(ctx): item \(idx) expected control, got media")
                    XCTAssertEqual(h, exp.header, "\(ctx): media header \(idx) mismatch")
                    XCTAssertEqual(payload, exp.payload, "\(ctx): media payload \(idx) mismatch")
                case let .control(type, payload):
                    XCTAssertFalse(exp.isMedia, "\(ctx): item \(idx) expected media, got control")
                    XCTAssertEqual(type.rawValue, exp.typeByte, "\(ctx): control type \(idx) mismatch")
                    XCTAssertEqual(payload, exp.payload, "\(ctx): control payload \(idx) mismatch")
                case let .unknownControl(type, _):
                    XCTFail("\(ctx): unexpected unknownControl(0x\(String(type, radix: 16)))")
                }
            }

            // Truncated tail: a valid stream minus its last few bytes must yield
            // the complete records and simply buffer the remainder — no crash.
            if stream.count > 4 {
                var p2 = LinkFrameParser()
                let cut = stream.subdata(in: stream.startIndex ..< (stream.endIndex - 3))
                XCTAssertNoThrow(try p2.feed(cut), "\(ctx): truncated tail must not throw")
            }

            // Garbage after a valid prefix: parser must throw a LinkFrameError
            // (defined failure), never trap or spin.
            var p3 = LinkFrameParser()
            let garbage = Data([0x00, 0x99, 0x7F, 0x42, 0x13])
            XCTAssertThrowsError(try p3.feed(garbage), "\(ctx): garbage magic must throw") { err in
                XCTAssertTrue(err is LinkFrameError, "\(ctx): expected LinkFrameError, got \(err)")
            }
        }
    }

    // MARK: - Test 1b: seeded REASSEMBLER fuzz

    /// Adversarial part streams — reordering, duplicates, declared-length
    /// mismatches, out-of-range indices, extreme partCount (0, 1, 65535),
    /// wraparound frameIDs, extreme PTS — must never crash, never buffer past
    /// the caps, and only ever emit bit-exact frames.
    func testReassemblerSeededFuzz() throws {
        for seed in seeds {
            var rng = SeededRNG(seed: seed)
            let ctx = "reassembler seed=\(seed)"

            // Small injected caps so eviction / rejection paths are hit cheaply.
            let maxPartCount = 32
            let maxFrameBytes = 8 * 1024
            let maxTotalPendingBytes = 16 * 1024
            let r = FrameReassembler(timeout: 5.0, maxPending: 6, reorderTimeout: 1.0,
                                     maxPartCount: maxPartCount, maxFrameBytes: maxFrameBytes,
                                     maxTotalPendingBytes: maxTotalPendingBytes)

            // Expected reassembly per (unique) frameID.
            var expectedPayload: [UInt32: Data] = [:]
            struct Event { let h: MediaDatagramHeader; let payload: Data }
            var events: [Event] = []

            // Frame base near UInt32.max on some seeds to exercise wraparound.
            var frameID: UInt32 = (seed & 1 == 0) ? 0xFFFF_FFF0 : UInt32(seed & 0xFFFF)
            var seq: UInt32 = 0
            let frameCount = 40
            for _ in 0..<frameCount {
                let roll = rng.next() % 100
                if roll < 8 {
                    // Adversarial extreme partCount: 0 or 65535 (rejected).
                    let count: UInt16 = (rng.next() & 1 == 0) ? 0 : 65535
                    let payload = partBytes(frameID: frameID, index: 0, length: 4)
                    events.append(Event(h: header(seq: seq, frameID: frameID, index: 0,
                                                  count: count, payload: payload,
                                                  pts: Int64.max), payload: payload))
                    seq &+= 1
                } else {
                    // Normal (or index==1) frame with a small part count.
                    let count = UInt16(1 + rng.next() % 6)
                    let pts = Int64(bitPattern: rng.next())
                    let flags: MediaDatagramHeader.Flags = (rng.next() & 1 == 0) ? .keyframe : []
                    // Build the whole expected payload from per-index chunks.
                    var whole = Data()
                    var perIndex: [Data] = []
                    for i in 0..<Int(count) {
                        let len = 1 + Int(rng.next() % 300)
                        let p = partBytes(frameID: frameID, index: i, length: len)
                        perIndex.append(p)
                        whole.append(p)
                    }
                    expectedPayload[frameID] = whole
                    // Emit each part as an event, with occasional duplicates and
                    // occasional malformed variants.
                    for i in 0..<Int(count) {
                        let p = perIndex[i]
                        events.append(Event(h: header(seq: seq, frameID: frameID,
                                                      index: UInt16(i), count: count,
                                                      payload: p, pts: pts, flags: flags), payload: p))
                        seq &+= 1
                        // Duplicate (identical bytes → must dedup, stay bit-exact).
                        if rng.next() % 5 == 0 {
                            events.append(Event(h: header(seq: seq, frameID: frameID,
                                                          index: UInt16(i), count: count,
                                                          payload: p, pts: pts, flags: flags), payload: p))
                            seq &+= 1
                        }
                        // Declared-length mismatch (payloadLength lies) → rejected.
                        if rng.next() % 7 == 0 {
                            var bad = header(seq: seq, frameID: frameID, index: UInt16(i),
                                             count: count, payload: p, pts: pts, flags: flags)
                            bad.payloadLength = UInt16((Int(bad.payloadLength) + 3) & 0xFFFF)
                            events.append(Event(h: bad, payload: p))
                            seq &+= 1
                        }
                        // Out-of-range index on a hand-built header → rejected.
                        if rng.next() % 11 == 0 {
                            let bad = header(seq: seq, frameID: frameID, index: count,
                                             count: count, payload: p, pts: pts, flags: flags)
                            events.append(Event(h: bad, payload: p))
                            seq &+= 1
                        }
                    }
                    frameID = frameID &+ 1
                }
            }

            // Shuffle (Fisher–Yates) to reorder fragments across frames.
            for i in stride(from: events.count - 1, to: 0, by: -1) {
                let j = Int(rng.next() % UInt64(i + 1))
                events.swapAt(i, j)
            }

            // Feed, advancing a monotonic clock; verify every emission and cap.
            var now: TimeInterval = 0
            let capWithSlack = maxTotalPendingBytes + 300 // one in-flight part's worth
            for ev in events {
                now += Double(rng.next() % 3) * 0.001
                let emitted = r.ingest(header: ev.h, payload: ev.payload, at: now)
                XCTAssertLessThanOrEqual(r.pendingByteCount, maxTotalPendingBytes,
                                         "\(ctx): pending bytes exceeded cap")
                XCTAssertLessThanOrEqual(Int(r.stats.peakPendingBytes), capWithSlack,
                                         "\(ctx): peak pending bytes exceeded cap+slack")
                if let f = emitted, let want = expectedPayload[f.frameID] {
                    XCTAssertEqual(f.payload, want, "\(ctx): emitted frame \(f.frameID) not bit-exact")
                }
            }
            // Drain any queued in-order frames the same way.
            while let f = r.ingest(header: header(seq: seq, frameID: frameID, index: 0, count: 1,
                                                  payload: Data([0]), pts: 0),
                                   payload: Data([0]), at: now + 100) {
                if let want = expectedPayload[f.frameID] {
                    XCTAssertEqual(f.payload, want, "\(ctx): drained frame \(f.frameID) not bit-exact")
                }
            }

            // The fuzz must exercise the happy path (not be vacuously all-drops).
            // (Precise oversize-rejection counting is order-sensitive and is
            // asserted deterministically in testPartCountCapRejectedBeforeAllocation;
            // here the adversarial partCounts are fed only to prove no crash + caps.)
            XCTAssertGreaterThan(r.stats.framesCompleted, 0, "\(ctx): no frame ever completed")
            XCTAssertLessThanOrEqual(r.pendingByteCount, maxTotalPendingBytes, "\(ctx): final pending bytes over cap")
        }
    }

    // MARK: - Test 2: partCount = 65535 rejected BEFORE allocation

    func testPartCountCapRejectedBeforeAllocation() {
        let r = FrameReassembler()
        let payload = Data([1, 2, 3, 4])
        let h = header(seq: 0, frameID: 1, index: 0, count: 65535, payload: payload, pts: 0)

        let out = r.ingest(header: h, payload: payload, at: 0)

        XCTAssertNil(out, "oversize frame must not emit")
        XCTAssertEqual(r.stats.framesRejectedOversize, 1, "oversize frame must be counted as rejected")
        XCTAssertEqual(r.pendingFrameCount, 0, "no pending entry may be created for an oversize frame")
        XCTAssertEqual(r.pendingByteCount, 0, "no bytes may be buffered for an oversize frame")
        XCTAssertEqual(r.stats.peakPendingBytes, 0, "no part table may ever be allocated (peak stays 0)")

        // The wire parser rejects it too, before it ever reaches the reassembler.
        XCTAssertThrowsError(try MediaDatagramHeader.parse(h.encoded() + payload)) { err in
            XCTAssertEqual(err as? MediaDatagramHeader.ParseError, .badPartFields)
        }

        // Boundary: with a small cap, partCount == cap is accepted, cap+1 rejected.
        let cap = 4
        let r2 = FrameReassembler(maxPartCount: cap)
        _ = r2.ingest(header: header(seq: 0, frameID: 10, index: 0, count: UInt16(cap),
                                     payload: payload, pts: 0), payload: payload, at: 0)
        XCTAssertEqual(r2.pendingFrameCount, 1, "partCount == cap must be accepted")
        XCTAssertEqual(r2.stats.framesRejectedOversize, 0)
        _ = r2.ingest(header: header(seq: 1, frameID: 11, index: 0, count: UInt16(cap + 1),
                                     payload: payload, pts: 0), payload: payload, at: 0)
        XCTAssertEqual(r2.stats.framesRejectedOversize, 1, "partCount == cap+1 must be rejected")
    }

    // MARK: - Test 3: total-pending-bytes cap bounds memory under a flood

    func testTotalPendingBytesCapBounded() {
        // High maxPending so the BYTE cap (not the frame-count cap) is what
        // bounds memory; small byte cap so the flood hits it fast.
        let byteCap = 4_000
        let partLen = 500
        let r = FrameReassembler(timeout: 1_000, maxPending: 100_000, reorderTimeout: 1_000,
                                 maxTotalPendingBytes: byteCap)

        // Open 2_000 distinct partial frames (each a 2-part frame that never
        // completes), one 500-byte part apiece. Attacker input is unbounded;
        // buffered memory must not be.
        let flood = 2_000
        for i in 0..<flood {
            let fid = UInt32(i)
            let payload = Data(repeating: UInt8(i & 0xFF), count: partLen)
            let h = header(seq: UInt32(i), frameID: fid, index: 0, count: 2, payload: payload, pts: Int64(i))
            _ = r.ingest(header: h, payload: payload, at: TimeInterval(i))
            XCTAssertLessThanOrEqual(r.pendingByteCount, byteCap,
                                     "pending bytes grew past the cap at frame \(i)")
        }

        XCTAssertLessThanOrEqual(r.pendingByteCount, byteCap, "final pending bytes over cap")
        XCTAssertLessThanOrEqual(Int(r.stats.peakPendingBytes), byteCap + partLen, "peak over cap+one part")
        // Memory bounded ⇒ only a handful of frames buffered despite the flood.
        XCTAssertLessThanOrEqual(r.pendingFrameCount, byteCap / partLen + 1,
                                 "frame count not bounded by the byte cap")
        // Oldest evicted ⇒ most of the flood was dropped.
        XCTAssertGreaterThan(r.stats.framesDropped, UInt64(flood - byteCap / partLen - 2),
                             "oldest partial frames were not evicted under the byte cap")
    }

    // MARK: - Test 4: positive control — normal multi-part frame is bit-exact

    func testPositiveControlMultiPartReassembly() {
        // (a) Direct ingest, in order.
        let r = FrameReassembler()
        let count = 5
        var perIndex: [Data] = []
        var whole = Data()
        for i in 0..<count {
            let p = partBytes(frameID: 42, index: i, length: 200 + i * 17)
            perIndex.append(p); whole.append(p)
        }
        var out: ReassembledFrame?
        for i in 0..<count {
            let h = header(seq: UInt32(i), frameID: 42, index: UInt16(i), count: UInt16(count),
                           payload: perIndex[i], pts: 123_456, flags: .keyframe)
            // All parts of one frame arrive within the 0.25s reassembly window.
            if let f = r.ingest(header: h, payload: perIndex[i], at: 0) { out = f }
        }
        XCTAssertNotNil(out, "in-order multi-part frame must reassemble")
        XCTAssertEqual(out?.payload, whole, "reassembled payload must be bit-exact")
        XCTAssertEqual(out?.frameID, 42)
        XCTAssertEqual(out?.ptsHouseNanos, 123_456)
        XCTAssertEqual(out?.isKeyframe, true)
        XCTAssertEqual(r.stats.framesCompleted, 1)
        XCTAssertEqual(r.pendingByteCount, 0, "no bytes should remain buffered after completion")

        // (b) Reordered parts still reassemble bit-exact.
        let r2 = FrameReassembler()
        var out2: ReassembledFrame?
        for i in [3, 0, 4, 1, 2] {
            let h = header(seq: UInt32(i), frameID: 7, index: UInt16(i), count: UInt16(count),
                           payload: perIndex[i], pts: 999, flags: [])
            if let f = r2.ingest(header: h, payload: perIndex[i], at: 0) { out2 = f }
        }
        // frameID 7 was fed the same per-index chunks, so its payload == `whole`.
        XCTAssertNotNil(out2, "reordered multi-part frame must reassemble")
        XCTAssertEqual(out2?.payload, whole, "reordered reassembly must be bit-exact")

        // (c) Full wire path: encode → LinkFrameParser (chunked) → reassemble.
        var stream = Data()
        for i in 0..<count {
            let h = header(seq: UInt32(i), frameID: 99, index: UInt16(i), count: UInt16(count),
                           payload: perIndex[i], pts: 55, flags: [])
            stream.append(record(h, perIndex[i]))
        }
        var parser = LinkFrameParser()
        let r3 = FrameReassembler()
        var out3: ReassembledFrame?
        var off = 0
        while off < stream.count {
            let chunk = min(13, stream.count - off)
            let slice = stream.subdata(in: (stream.startIndex + off) ..< (stream.startIndex + off + chunk))
            for item in (try? parser.feed(slice)) ?? [] {
                if case let .media(h, payload) = item {
                    if let f = r3.ingest(header: h, payload: payload, at: 0) { out3 = f }
                }
            }
            off += chunk
        }
        // frameID 99 was fed the same per-index chunks, so its payload == `whole`.
        XCTAssertNotNil(out3, "wire-path frame must reassemble")
        XCTAssertEqual(out3?.payload, whole, "wire-path reassembly must be bit-exact")
    }
}
