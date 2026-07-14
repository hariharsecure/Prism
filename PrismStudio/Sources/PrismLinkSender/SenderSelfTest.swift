import CoreMedia
import CoreVideo
import Foundation
import PrismCore
import PrismLink

/// Headless self-verification of the sender module (no camera, no network,
/// no TCC). Two tiers:
///
///  - `run()` — pure logic: Annex-B conversion round-trip against PrismLink's
///    `HEVCAnnexB` helpers, datagram fragmentation round-trip against
///    PrismLink's actual `FrameReassembler` + `LinkFrameParser`, device
///    clock-sync regression math, bitrate-ladder stepping.
///  - `runEncodeLoop()` — real VideoToolbox: LowLatencyEncoder on synthetic
///    frames → fragment → reassemble → PrismLink's `VideoFrameDecoder`,
///    i.e. the full sender→wire→receiver media path in one process.
///
/// Wire either into prism-dev or an XCTest target; both throw with a precise
/// message on the first mismatch.
public enum SenderSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case setupFailed(String)
        case mismatch(String)
        public var description: String {
            switch self {
            case .setupFailed(let s): return "sender self-test setup failed: \(s)"
            case .mismatch(let s): return "sender self-test mismatch: \(s)"
            }
        }
    }

    public static func run() throws {
        try testAnnexBConversion()
        try testFragmentationRoundTrip()
        try testFragmenterEdgeCases()
        try testDeviceClockSync()
        try testBitrateLadder()
        print("SenderSelfTest: all pure-logic checks passed")
    }

    private static func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw SelfTestError.mismatch(message()) }
    }

    // MARK: - 1. Annex-B conversion (length-prefixed → start codes + param sets)

    private static func testAnnexBConversion() throws {
        // NAL headers: nal_unit_type = (byte0 >> 1) & 0x3F.
        let vps = Data([0x40, 0x01, 0x0C, 0x11])              // type 32
        let sps = Data([0x42, 0x01, 0x22, 0x33, 0x44])        // type 33
        let pps = Data([0x44, 0x01, 0x55])                    // type 34
        let idr = Data([0x26, 0x01] + (0..<600).map { UInt8(($0 % 254) + 1) }) // type 19 (IDR_W_RADL)
        let sei = Data([0x4E, 0x01, 0x05, 0x11])              // type 39 prefix SEI

        let lengthPrefixed = HEVCAnnexB.lengthPrefixed([sei, idr])
        guard let annexB = LowLatencyEncoder.annexB(fromLengthPrefixed: lengthPrefixed,
                                                    nalUnitHeaderLength: 4,
                                                    prepending: [vps, sps, pps]) else {
            throw SelfTestError.mismatch("annexB conversion returned nil for valid input")
        }

        // Round-trip through the DECODER's own splitter — this is the exact
        // parse the Mac performs on our payload.
        let nals = HEVCAnnexB.splitNALUnits(annexB)
        try require(nals == [vps, sps, pps, sei, idr],
                    "split NALs != [vps, sps, pps, sei, idr] (got \(nals.count) NALs)")
        try require(HEVCAnnexB.parameterSets(in: nals) != nil,
                    "decoder would not find vps/sps/pps in a keyframe payload")
        try require(HEVCAnnexB.NALType.isKeyframe(HEVCAnnexB.nalType(idr)),
                    "IDR NAL not classified as keyframe")

        // Non-keyframe: no parameter sets prepended.
        let pFrame = Data([0x02, 0x01, 0x77, 0x88])           // type 1 (TRAIL_R)
        guard let pAnnexB = LowLatencyEncoder.annexB(fromLengthPrefixed: HEVCAnnexB.lengthPrefixed([pFrame]),
                                                     nalUnitHeaderLength: 4, prepending: []) else {
            throw SelfTestError.mismatch("annexB conversion returned nil for P-frame")
        }
        let pNALs = HEVCAnnexB.splitNALUnits(pAnnexB)
        try require(pNALs == [pFrame], "P-frame round-trip mismatch")
        try require(HEVCAnnexB.parameterSets(in: pNALs) == nil,
                    "P-frame payload should not contain parameter sets")

        // 2-byte length prefixes are also legal in hvcC.
        var twoByte = Data()
        twoByte.append(contentsOf: [0x00, 0x04])
        twoByte.append(sei)
        guard let converted = LowLatencyEncoder.annexB(fromLengthPrefixed: twoByte,
                                                       nalUnitHeaderLength: 2, prepending: []),
              HEVCAnnexB.splitNALUnits(converted) == [sei] else {
            throw SelfTestError.mismatch("2-byte length-prefix conversion failed")
        }

        // Malformed inputs must return nil, not garbage.
        try require(LowLatencyEncoder.annexB(fromLengthPrefixed: Data([0x00, 0x00, 0x00, 0x09, 0x01]),
                                             nalUnitHeaderLength: 4, prepending: []) == nil,
                    "truncated NAL accepted")
        try require(LowLatencyEncoder.annexB(fromLengthPrefixed: Data([0x00, 0x00, 0x00, 0x00]),
                                             nalUnitHeaderLength: 4, prepending: []) == nil,
                    "zero-length NAL accepted")
        try require(LowLatencyEncoder.annexB(fromLengthPrefixed: lengthPrefixed,
                                             nalUnitHeaderLength: 5, prepending: []) == nil,
                    "nalUnitHeaderLength 5 accepted")
    }

    // MARK: - 2. Fragmentation round-trip vs the receiver's FrameReassembler

    private static func testFragmentationRoundTrip() throws {
        var fragmenter = MediaFragmenter()
        let reassembler = FrameReassembler()
        let maxDatagramSize = 1200
        let chunk = MediaFragmenter.chunkSize(maxDatagramSize: maxDatagramSize)
        try require(chunk == 1175, "chunk size for 1200-byte budget should be 1175, got \(chunk)")

        // Deterministic pseudo-random payloads (LCG) — reproducible run to run.
        var seed: UInt64 = 0x5EED_1234
        func nextByte() -> UInt8 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: seed >> 32)
        }

        let sizes = [1, 500, chunk, chunk + 1, 5_000, 200_000]
        var now: TimeInterval = 0
        for (index, size) in sizes.enumerated() {
            let payload = Data((0..<size).map { _ in nextByte() })
            let pts = Int64(1_000_000_000) + Int64(index) * 16_666_667
            let isKeyframe = index % 2 == 0
            let datagrams = fragmenter.fragment(payload: payload, ptsHouseNanos: pts,
                                                flags: isKeyframe ? [.keyframe] : [],
                                                maxDatagramSize: maxDatagramSize)
            let expectedParts = (size + chunk - 1) / chunk
            try require(datagrams.count == expectedParts,
                        "size \(size): \(datagrams.count) parts, expected \(expectedParts)")
            try require(datagrams.allSatisfy { $0.count <= maxDatagramSize },
                        "size \(size): a datagram exceeds the budget")

            // Deliver out of order (deterministic reversal), one datagram per
            // parser feed — exactly how the server's datagram path works.
            var completed: ReassembledFrame?
            for datagram in datagrams.reversed() {
                var parser = LinkFrameParser()
                let items = try parser.feed(datagram)
                try require(items.count == 1, "datagram parsed to \(items.count) items")
                guard case .media(let header, let part) = items[0] else {
                    throw SelfTestError.mismatch("datagram did not parse as media")
                }
                try require(Int(header.payloadLength) == part.count, "payloadLength mismatch")
                if let frame = reassembler.ingest(header: header, payload: part, at: now) {
                    try require(completed == nil, "frame completed twice")
                    completed = frame
                }
            }
            guard let frame = completed else {
                throw SelfTestError.mismatch("size \(size): frame never completed")
            }
            try require(frame.payload == payload, "size \(size): payload corrupted in round-trip")
            try require(frame.ptsHouseNanos == pts, "size \(size): pts corrupted")
            try require(frame.isKeyframe == isKeyframe, "size \(size): keyframe flag corrupted")
            try require(!frame.isAudio, "size \(size): audio flag set on video")
            now += 0.01
        }
        try require(reassembler.stats.framesCompleted == UInt64(sizes.count),
                    "reassembler completed \(reassembler.stats.framesCompleted)/\(sizes.count)")
        try require(reassembler.stats.framesDropped == 0, "reassembler dropped frames")
        try require(reassembler.stats.estimatedDatagramsLost == 0,
                    "loss estimator sees loss on a lossless run — seq numbering is broken")

        // Coalesced delivery (reliable-stream fallback): all datagrams in one buffer.
        var fragmenter2 = MediaFragmenter()
        let payload = Data((0..<10_000).map { _ in nextByte() })
        let datagrams = fragmenter2.fragment(payload: payload, ptsHouseNanos: 7,
                                             flags: [.keyframe], maxDatagramSize: maxDatagramSize)
        var stream = Data()
        for d in datagrams { stream.append(d) }
        var parser = LinkFrameParser()
        let items = try parser.feed(stream)
        try require(items.count == datagrams.count,
                    "coalesced parse: \(items.count) items from \(datagrams.count) records")
    }

    private static func testFragmenterEdgeCases() throws {
        var fragmenter = MediaFragmenter()
        try require(fragmenter.fragment(payload: Data(), ptsHouseNanos: 0, flags: [],
                                        maxDatagramSize: 1200).isEmpty,
                    "empty payload should produce no datagrams")
        try require(fragmenter.fragment(payload: Data([1]), ptsHouseNanos: 0, flags: [],
                                        maxDatagramSize: LinkProtocol.mediaHeaderSize).isEmpty,
                    "header-only budget should produce no datagrams")
        // > 65535 parts must be refused (partCount is u16).
        let big = Data(count: 70_000)
        try require(fragmenter.fragment(payload: big, ptsHouseNanos: 0, flags: [],
                                        maxDatagramSize: LinkProtocol.mediaHeaderSize + 1).isEmpty,
                    "70000-part frame accepted")
        // Sequence numbers monotonic across frames; frameID increments by 1.
        let a = fragmenter.fragment(payload: Data(count: 3000), ptsHouseNanos: 1, flags: [],
                                    maxDatagramSize: 1200)
        let b = fragmenter.fragment(payload: Data(count: 3000), ptsHouseNanos: 2, flags: [],
                                    maxDatagramSize: 1200)
        let headerA = try MediaDatagramHeader.parse(a[0])
        let headerALast = try MediaDatagramHeader.parse(a[a.count - 1])
        let headerB = try MediaDatagramHeader.parse(b[0])
        try require(headerB.frameID == headerA.frameID + 1, "frameID did not increment")
        try require(headerALast.seq == headerA.seq + UInt32(a.count - 1), "seq not consecutive in frame")
        try require(headerB.seq == headerALast.seq + 1, "seq not consecutive across frames")
    }

    // MARK: - 3. Device clock sync (offset + skew regression, outlier rejection)

    private static func testDeviceClockSync() throws {
        var sync = DeviceClockSync()
        try require(sync.houseNanos(forDeviceNanos: 123) == nil, "translation before any pong")

        // Simulated truth: house = device + o0 + skew·device, skew = +20 ppm.
        let o0: Int64 = 5_000_000_000_000
        let skewPPM = 20.0
        func trueOffset(atDevice m: Int64) -> Int64 { o0 + Int64(Double(m) * skewPPM / 1e6) }
        func houseAt(device m: Int64) -> Int64 { m + trueOffset(atDevice: m) }

        var device = Int64(1_000_000_000_000)
        var lastT4 = device
        var rejected = 0
        var outliersInjected = 0
        for i in 0..<32 {
            let t1 = device
            let uplink = Int64(1_500_000 + (i % 5) * 100_000)        // 1.5–1.9 ms
            let downlink = Int64(1_500_000 + ((i + 2) % 5) * 100_000)
            let spike: Int64 = (i % 9 == 8) ? 40_000_000 : 0          // 40 ms asymmetric queueing
            if spike > 0 { outliersInjected += 1 }
            let processing: Int64 = 200_000

            let arriveDevice = t1 + uplink + spike
            let t2 = houseAt(device: arriveDevice)
            let t3 = t2 + processing
            let t4 = arriveDevice + processing + downlink
            let accepted = sync.ingest(pong: LinkClockPong(seq: UInt32(i), t1: t1, t2: t2, t3: t3),
                                       receivedAtDeviceNanos: t4)
            if !accepted { rejected += 1 }
            if spike > 0 {
                try require(!accepted, "40 ms RTT outlier was accepted (sample \(i))")
            }
            lastT4 = t4
            device += 2_000_000_000 // one ping every 2 s
        }
        try require(rejected == outliersInjected,
                    "rejected \(rejected) samples, expected exactly the \(outliersInjected) outliers")

        guard let estimate = sync.estimate() else {
            throw SelfTestError.mismatch("no estimate after 30+ accepted samples")
        }
        let offsetError = abs(estimate.offsetNanos - trueOffset(atDevice: lastT4))
        try require(offsetError < 1_000_000,
                    "offset error \(offsetError) ns ≥ 1 ms (LAN target is sub-millisecond)")
        try require(abs(estimate.skewPPM - skewPPM) < 10,
                    "skew estimate \(estimate.skewPPM) ppm not within ±10 of true 20 ppm")

        // Translate a capture PTS 1 s in the future (regression extrapolates).
        let future = lastT4 + 1_000_000_000
        guard let translated = sync.houseNanos(forDeviceNanos: future) else {
            throw SelfTestError.mismatch("translation returned nil after sync")
        }
        let translationError = abs(translated - houseAt(device: future))
        try require(translationError < 1_000_000,
                    "house-time translation error \(translationError) ns ≥ 1 ms")
    }

    // MARK: - 4. Bitrate ladder

    private static func testBitrateLadder() throws {
        var ladder = BitrateLadder() // 20/12/8/5/3, start at 12
        try require(ladder.currentBps == 12_000_000, "ladder should start at 12 Mbps")

        try require(ladder.apply(feedback: LinkStats(lossPercent: 5), at: 100) == 8_000_000,
                    "loss 5% should step 12 → 8")
        try require(ladder.apply(feedback: LinkStats(lossPercent: 5), at: 101) == nil,
                    "step-down inside the 3 s cooldown")
        try require(ladder.apply(feedback: LinkStats(lossPercent: 5), at: 104) == 5_000_000,
                    "loss after cooldown should step 8 → 5")
        try require(ladder.apply(feedback: LinkStats(lossPercent: 0), at: 105) == nil,
                    "clean sample should not step up immediately")
        try require(ladder.apply(feedback: LinkStats(lossPercent: 0), at: 116) == 8_000_000,
                    "10 s clean should step 5 → 8")
        try require(ladder.apply(feedback: LinkStats(lossPercent: 0), at: 117) == nil,
                    "clean window must restart after a step up")
        try require(ladder.apply(feedback: LinkStats(jitterMs: 3), at: 118) == nil,
                    "feedback without lossPercent must be ignored")

        // Clamps.
        var floor = BitrateLadder(startIndex: 4)
        try require(floor.currentBps == 3_000_000, "startIndex 4 should be 3 Mbps")
        try require(floor.stepDown(at: 0) == nil, "must clamp at the bottom rung")
        var ceiling = BitrateLadder(startIndex: 0)
        try require(ceiling.stepUp(at: 0) == nil, "must clamp at the top rung")

        // sessionConfig snapping.
        var snap = BitrateLadder()
        try require(snap.select(closestTo: 21_000_000) == 20_000_000, "snap 21 → 20 Mbps")
        try require(snap.select(closestTo: 6_400_000) == 5_000_000, "snap 6.4 → 5 Mbps")
    }

    // MARK: - 5. Real VideoToolbox loop (encoder → wire → PrismLink decoder)

    /// Exercises the actual media path end-to-end in one process:
    /// synthetic 1280×720 frames → `LowLatencyEncoder` (HEVC low-latency) →
    /// `MediaFragmenter` → `LinkFrameParser`/`FrameReassembler` →
    /// PrismLink `VideoFrameDecoder` → decoded `VideoFrame`s.
    ///
    /// TEST CODE ONLY: locks pixel-buffer base addresses to synthesize input —
    /// forbidden on the engine hot path, explicitly allowed in self-tests.
    public static func runEncodeLoop() throws {
        let width = 1280, height = 720, frameCount = 30
        let encoder = try LowLatencyEncoder(configuration: .init(
            width: width, height: height, fps: 30,
            averageBitrateBps: 4_000_000, keyframeIntervalSeconds: 2))

        let encodedLock = NSLock()
        var encoded: [LowLatencyEncoder.EncodedFrame] = []
        encoder.onEncodedFrame = { frame in
            encodedLock.lock()
            encoded.append(frame)
            encodedLock.unlock()
        }

        let pool = try PixelBufferPool(width: width, height: height,
                                       pixelFormat: kCVPixelFormatType_32BGRA)
        for i in 0..<frameCount {
            let buffer = try pool.makeBuffer()
            fill(buffer, seed: UInt8(i * 8)) // moving gradient so P-frames have content
            if i == 15 { encoder.forceKeyframe() }
            encoder.encode(pixelBuffer: buffer,
                           pts: CMTime(value: CMTimeValue(i), timescale: 30),
                           duration: CMTime(value: 1, timescale: 30))
        }
        encoder.flush()

        encodedLock.lock()
        let frames = encoded.sorted { CMTimeCompare($0.pts, $1.pts) < 0 }
        encodedLock.unlock()

        try require(frames.count == frameCount,
                    "encoded \(frames.count)/\(frameCount) frames (dropped: \(encoder.framesDropped))")
        try require(frames[0].isKeyframe, "first encoded frame is not a keyframe")
        let forced = frames.first { $0.pts == CMTime(value: 15, timescale: 30) }
        try require(forced?.isKeyframe == true, "forceKeyframe() did not force frame 15")

        for frame in frames {
            let nals = HEVCAnnexB.splitNALUnits(frame.annexB)
            try require(!nals.isEmpty, "frame parsed to zero NALs")
            let hasParamSets = HEVCAnnexB.parameterSets(in: nals) != nil
            try require(hasParamSets == frame.isKeyframe,
                        "parameter sets present=\(hasParamSets) but keyframe=\(frame.isKeyframe)")
        }

        // Wire + decode: exactly what LinkServer's peer does with our datagrams.
        var fragmenter = MediaFragmenter()
        let reassembler = FrameReassembler()
        let decoder = VideoFrameDecoder(source: SourceID("selftest:sender"))
        let decodedLock = NSLock()
        var decodedCount = 0
        var decodedSizeOK = true
        let done = DispatchSemaphore(value: 0)
        decoder.onFrame = { frame in
            decodedLock.lock()
            decodedCount += 1
            if frame.width != width || frame.height != height { decodedSizeOK = false }
            let count = decodedCount
            decodedLock.unlock()
            if count == frameCount { done.signal() }
        }

        var now: TimeInterval = 0
        for frame in frames {
            let ptsNanos = CMTimeConvertScale(frame.pts, timescale: 1_000_000_000,
                                              method: .default).value
            let datagrams = fragmenter.fragment(payload: frame.annexB, ptsHouseNanos: ptsNanos,
                                                flags: frame.isKeyframe ? [.keyframe] : [],
                                                maxDatagramSize: 1200)
            try require(!datagrams.isEmpty, "encoded frame failed to fragment")
            for datagram in datagrams {
                var parser = LinkFrameParser()
                guard case .media(let header, let part) = try parser.feed(datagram)[0] else {
                    throw SelfTestError.mismatch("datagram did not parse as media")
                }
                if let whole = reassembler.ingest(header: header, payload: part, at: now) {
                    try require(whole.payload == frame.annexB, "wire round-trip corrupted a frame")
                    decoder.decode(whole)
                }
            }
            now += 1.0 / 30.0
        }

        try require(done.wait(timeout: .now() + 15) == .success,
                    "decoder produced \(decodedCount)/\(frameCount) frames within 15 s")
        try require(decodedSizeOK, "decoded frame size != \(width)x\(height)")
        print("SenderSelfTest: encode loop passed — \(frames.count) frames encoded, "
              + "\(decodedCount) decoded through the PrismLink receiver path")
    }

    /// TEST ONLY (see note on `runEncodeLoop`).
    private static func fill(_ buffer: CVPixelBuffer, seed: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let p = row.advanced(by: x * 4)
                p[0] = UInt8((x &+ Int(seed)) & 0xFF)         // B
                p[1] = UInt8((y &+ Int(seed) &* 2) & 0xFF)    // G
                p[2] = seed                                    // R
                p[3] = 255                                     // A
            }
        }
    }
}
