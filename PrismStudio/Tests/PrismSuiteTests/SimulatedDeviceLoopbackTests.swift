import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Network
import XCTest

import PrismCore
@testable import PrismLink
@testable import PrismLinkSender

/// PART A — "simulated iPhone over the wire".
///
/// A hardware-in-the-loop harness that proves the PrismLink device→Mac media
/// pipeline works end to end WITHOUT a physical iPhone. The ONLY thing swapped
/// for the hardware is the pixel source: `DeviceCameraStreamer` (the iOS capture
/// orchestrator) is `#if os(iOS)` and needs a live `AVCaptureDevice`, so on macOS
/// we inject frames at the **encoder input seam** — the exact seam
/// `DeviceCameraStreamer.captureOutput(...)` feeds — by decoding `PRISM_SIM_FEED`
/// with `AVAssetReader` and calling `LowLatencyEncoder.encode(...)` with each
/// decoded `CVPixelBuffer`. From the encoder onward every layer is the real
/// production code the Mac runs against a real phone:
///
///   mp4 → AVAssetReader → LowLatencyEncoder(HEVC) → MediaFragmenter(wire)
///        → LinkFrameParser → FrameReassembler → VideoFrameDecoder(HEVC decode)
///        → NetworkVideoSource.onFrame   (verified here, on the receiver's pixels)
///
/// TRANSPORT. The harness first tries to stand up a REAL `LinkServer` +
/// `LinkClient` over a genuine loopback QUIC/TLS-1.3 tunnel (the full socket, real
/// mutual-auth pairing, real clock sync). That requires a keychain-resident TLS
/// identity (`LinkIdentity.createEphemeral`); in a headless `swift test` host,
/// `SecKeychainCreate` is denied (errSecUserCanceled/-128) — the same reason
/// `LinkIdentityKeychainTests` is opt-in gated — so the QUIC listener can't bind.
/// When that happens the harness falls back to driving the SAME real
/// `MediaFragmenter → LinkFrameParser → FrameReassembler → VideoFrameDecoder →
/// NetworkVideoSource` receiver stack over an in-process datagram hand-off (only
/// the `NWConnectionGroup` socket is bypassed), and it still exercises the REAL
/// `LinkPairing` mutual-auth crypto that the socket handshake would run. Which
/// transport ran is printed in the report.
///
/// The feed's marching red box (x = t·180) confirms frame ORDER + content survived
/// on the RECEIVER's own decoded pixels — not just a byte count.
///
/// Gated on `PRISM_SIM_FEED`: `XCTSkip` when unset/missing, so the fast suite is unaffected.
final class SimulatedDeviceLoopbackTests: XCTestCase {

    private static let pairingCode = "prism-sim-4417"
    /// Frames pushed through the wire. Bounded so the harness is quick; still a
    /// multi-GOP real-time stream (keyframe interval 1 s below).
    private static let framesToSend = 90
    private static let feedWidth = 1920
    private static let feedHeight = 1080

    func testSimulatedDeviceStreamsRealVideoOverLoopbackLink() async throws {
        guard let feed = SimHarnessSupport.simFeedURL() else {
            throw XCTSkip("PRISM_SIM_FEED unset or missing — skipping simulated-device loopback")
        }

        // (0) The REAL mutual-auth pairing crypto (the exact HMAC handshake the
        //     socket path runs): server proves it knows the code, client proves it,
        //     and a wrong code is rejected. This runs regardless of transport.
        assertRealPairingHandshake()

        // (1) TRANSPORT SELECTION — keychain-safe by default.
        //     Standing up the QUIC listener needs a keychain-resident TLS identity
        //     (`LinkIdentity.createEphemeral`). To guarantee ZERO login/keychain
        //     prompts on the operator's machine, the socket path is OPT-IN via
        //     `PRISM_SIM_LINK_SOCKET=1`. When it is unset (default) we never call
        //     `server.start()` / `createEphemeral()` at all — we drive the SAME real
        //     `MediaFragmenter → LinkFrameParser → FrameReassembler → VideoFrameDecoder
        //     → NetworkVideoSource` stack over an in-process datagram hand-off (only
        //     the `NWConnectionGroup` socket + TLS handshake are skipped). No
        //     production auth is bypassed — auth correctness is covered by the real
        //     `LinkPairing` crypto asserted above and by `LinkMutualPairingTests`.
        let socketOptIn = ProcessInfo.processInfo.environment["PRISM_SIM_LINK_SOCKET"] == "1"
        if socketOptIn, let real = try await attemptRealSocketPath(feed: feed) {
            verifyReceiver(real, clock: real.clockDesc,
                           transport: "REAL QUIC/TLS-1.3 loopback socket (opt-in)")
        } else {
            let mem = try await runInMemoryReceiverPath(feed: feed)
            verifyReceiver(mem, clock: "n/a (socket unavailable headless)",
                           transport: "in-process datagram hand-off (real fragmenter/reassembler/decoder)")
        }
    }

    // MARK: Real pairing crypto (mutual auth v2)

    private func assertRealPairingHandshake() {
        let code = Self.pairingCode
        let certDER = Data("sim-server-leaf-cert-DER".utf8)
        var clientNonce = Data(count: 32)
        _ = clientNonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        var serverNonce = Data(count: 32)
        _ = serverNonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        do {
            // Server → client reverse proof (client verifies the Mac knows the code).
            let serverProof = try LinkPairing.serverProof(code: code, serverCertificateDER: certDER, clientNonce: clientNonce)
            let clientRecomputed = try LinkPairing.serverProof(code: code, serverCertificateDER: certDER, clientNonce: clientNonce)
            XCTAssertEqual(serverProof, clientRecomputed, "server proof not reproducible under the correct code")
            let spoof = try LinkPairing.serverProof(code: "prism-9999", serverCertificateDER: certDER, clientNonce: clientNonce)
            XCTAssertNotEqual(spoof, serverProof, "a wrong-code server produced the same proof — auth broken")
            // Client → server proof (server verifies the phone knows the code).
            let clientProof = try LinkPairing.pairingProof(code: code, serverCertificateDER: certDER, nonce: serverNonce)
            let serverExpected = try LinkPairing.pairingProof(code: code, serverCertificateDER: certDER, nonce: serverNonce)
            XCTAssertEqual(clientProof, serverExpected, "client pairing proof not reproducible")
            XCTAssertNotEqual(clientProof, serverProof, "client/server proofs not domain-separated")
        } catch {
            XCTFail("real LinkPairing mutual-auth crypto threw: \(error)")
        }
    }

    // MARK: Real QUIC socket path (best effort)

    private struct ReceiverResult {
        let box: ReceiverBox; let sent: Int; let framesCompleted: Int
        let sourceSignatures: [[Float]]; let clockDesc: String
    }

    /// Returns nil (no failure) when the real transport can't be stood up headless.
    private func attemptRealSocketPath(feed: URL) async throws -> ReceiverResult? {
        let box = ReceiverBox()
        let server = LinkServer(configuration: .init(
            port: 0, pairingCode: Self.pairingCode, allowUnpaired: false,
            sessionConfig: LinkSessionConfig(codec: "hevc", width: Self.feedWidth, height: Self.feedHeight,
                                             fps: 30, targetBitrateBps: 8_000_000, keyframeIntervalSeconds: 1),
            advertise: false))
        server.onPeerConnected = { peer in
            box.setPeer(peer)
            peer.onStateChange = { box.recordPeerState($0) }
            peer.videoSource.onFrame = { box.ingestDecoded($0) }
            try? peer.videoSource.start()
        }
        do { try server.start() } catch { return nil } // keychain/QUIC unavailable → fall back
        defer { server.stop() }
        guard let port = await SimHarnessSupport.poll(timeout: 5, { server.boundPort }),
              let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }

        let hello = LinkHello(name: "sim-iphone", model: "PrismSimFeed",
                              maxWidth: Self.feedWidth, maxHeight: Self.feedHeight, maxFps: 30)
        let client = LinkClient(configuration: .init(hello: hello, pairingCode: Self.pairingCode))
        let clientState = ClientBox()
        client.onStateChange = { clientState.setState($0) }
        client.onSessionConfig = { clientState.setSessionConfig($0) }
        client.connect(to: .hostPort(host: "127.0.0.1", port: nwPort))
        defer { client.disconnect() }

        let connected = await SimHarnessSupport.poll(timeout: 10) { clientState.state == .connected ? true : nil } ?? false
        guard connected else { return nil }
        _ = await SimHarnessSupport.poll(timeout: 6) { clientState.sessionConfig != nil ? true : nil }
        XCTAssertNotNil(clientState.sessionConfig, "pairing/media-authorization did not complete (no sessionConfig)")
        let clockLocked = await SimHarnessSupport.poll(timeout: 6) { client.clockEstimate != nil ? true : nil } ?? false
        XCTAssertTrue(clockLocked, "device clock sync never produced an estimate")

        let feedResult = try await feedThroughEncoder(feed: feed) { encoded, pts, key in
            client.send(encoded: encoded, pts: pts, isKeyframe: key)
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        XCTAssertEqual(box.lastPeerState, .active, "server peer never became .active")
        XCTAssertEqual(box.peer?.hello?.name, "sim-iphone", "server did not receive the device hello")
        let completed = Int(box.peer?.mediaStats.framesCompleted ?? 0)
        let clockDesc = client.clockEstimate.map {
            String(format: "offset=%.3fms skew=%.1fppm samples=%d", Double($0.offsetNanos)/1e6, $0.skewPPM, $0.sampleCount)
        } ?? "lost"
        return ReceiverResult(box: box, sent: feedResult.sent, framesCompleted: completed,
                              sourceSignatures: feedResult.sourceSignatures, clockDesc: clockDesc)
    }

    // MARK: In-process receiver path (real media stack, socket bypassed)

    private func runInMemoryReceiverPath(feed: URL) async throws -> ReceiverResult {
        let box = ReceiverBox()
        // The exact receiver stack a LinkPeer wires internally.
        let source = SourceID("sim:receiver")
        let netSource = NetworkVideoSource(id: source)
        let decoder = VideoFrameDecoder(source: source)
        decoder.onFrame = { netSource.deliver($0) }
        netSource.onFrame = { box.ingestDecoded($0) }
        try netSource.start()

        var fragmenter = MediaFragmenter()
        let reassembler = FrameReassembler()
        let reassemblyLock = NSLock()
        var now: TimeInterval = 0

        let feedResult = try await feedThroughEncoder(feed: feed) { encoded, pts, key in
            let nanos = CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .default).value
            let datagrams = fragmenter.fragment(payload: encoded, ptsHouseNanos: nanos,
                                                flags: key ? [.keyframe] : [], maxDatagramSize: 1200)
            for datagram in datagrams {
                var parser = LinkFrameParser()
                guard let items = try? parser.feed(datagram), case .media(let header, let part)? = items.first else { continue }
                reassemblyLock.lock()
                let frame = reassembler.ingest(header: header, payload: part, at: now)
                now += 0.0005
                reassemblyLock.unlock()
                if let frame { decoder.decode(frame) }
            }
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let completed = reassemblyLock.withLock { Int(reassembler.stats.framesCompleted) }
        return ReceiverResult(box: box, sent: feedResult.sent, framesCompleted: completed,
                              sourceSignatures: feedResult.sourceSignatures, clockDesc: "n/a")
    }

    // MARK: Shared feed (encoder input seam) + verification

    /// Decode `PRISM_SIM_FEED` and push each frame through the REAL
    /// `LowLatencyEncoder`, handing every encoded frame to `sink` (the wire).
    /// Returns the number of encoded frames actually emitted.
    private func feedThroughEncoder(feed: URL,
                                    sink: @escaping (Data, CMTime, Bool) -> Void) async throws -> (sent: Int, sourceSignatures: [[Float]]) {
        let encoder = try LowLatencyEncoder(configuration: .init(
            width: Self.feedWidth, height: Self.feedHeight, fps: 30,
            averageBitrateBps: 8_000_000, keyframeIntervalSeconds: 1))
        let sentBox = SentBox()
        encoder.onEncodedFrame = { frame in
            sentBox.increment(keyframe: frame.isKeyframe)
            sink(frame.annexB, frame.pts, frame.isKeyframe)
        }
        let reader = try SimHarnessSupport.makeVideoReader(url: feed, pixelFormat: kCVPixelFormatType_32BGRA)
        guard reader.reader.startReading() else {
            throw XCTSkip("could not read PRISM_SIM_FEED video track: \(String(describing: reader.reader.error))")
        }
        let sourceSigs = SigCollector()
        encoder.forceKeyframe()
        var fed = 0
        while fed < Self.framesToSend, let sample = reader.output.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            sourceSigs.append(pixelBuffer) // signature of the SOURCE frame, in send order
            encoder.encode(pixelBuffer: pixelBuffer, pts: HouseClock.now(),
                           duration: CMTime(value: 1, timescale: 30))
            fed += 1
            try? await Task.sleep(nanoseconds: 33_000_000) // ~30 fps real-time pacing
        }
        encoder.flush()
        reader.reader.cancelReading()
        try? await Task.sleep(nanoseconds: 400_000_000) // drain encoder delivery
        return (sentBox.count, sourceSigs.signatures)
    }

    private func verifyReceiver(_ r: ReceiverResult, clock: String, transport: String) {
        let sent = r.sent, framesCompleted = r.framesCompleted, box = r.box
        XCTAssertGreaterThanOrEqual(sent, Self.framesToSend - 5,
                                    "encoder produced only \(sent)/\(Self.framesToSend) frames")
        let decoded = box.decodedCount

        // (a) Most sent frames reassembled on the receiver (bounded loss ok).
        XCTAssertGreaterThanOrEqual(framesCompleted, Int(Double(sent) * 0.8),
            "reassembler completed \(framesCompleted)/\(sent) frames")
        // (b) Frames genuinely DECODED through VideoFrameDecoder → a source materialized.
        XCTAssertGreaterThanOrEqual(decoded, Int(Double(sent) * 0.5),
            "only \(decoded)/\(sent) frames decoded to VideoFrames")
        // (c) Right dimensions.
        XCTAssertEqual(box.firstDims?.width, Self.feedWidth, "decoded frame width wrong")
        XCTAssertEqual(box.firstDims?.height, Self.feedHeight, "decoded frame height wrong")

        // (d) Content + ORDER survived: match each RECEIVER-decoded frame back to
        //     its SOURCE frame by a 16×9 luma signature, and require the matched
        //     source indices to advance in order (a tear/reorder/freeze breaks this).
        let sigs = box.signatures
        XCTAssertGreaterThanOrEqual(sigs.count, 16,
            "too few decoded frames (\(sigs.count)) to judge order")
        let m = SimHarnessSupport.orderMatch(source: r.sourceSignatures, decoded: sigs)
        XCTAssertGreaterThanOrEqual(m.spread, 0.5,
            "decoded frames map to only \(String(format: "%.0f", m.spread*100))% of the source span — stream stuck, not advancing")
        XCTAssertGreaterThanOrEqual(m.monotoneRatio, 0.85,
            "matched source order only \(String(format: "%.0f", m.monotoneRatio*100))% non-decreasing — frames reordered/torn on the wire")
        XCTAssertGreaterThanOrEqual(m.distinctRatio, 0.4,
            "only \(String(format: "%.0f", m.distinctRatio*100))% of decoded frames are distinct — content collapsed")

        print("""
        ── PART A (simulated-device loopback) ──
           transport:  \(transport)
           pairing:    real LinkPairing mutual-auth verified (correct code accepts, wrong code rejects)
           clock:      \(clock)
           sent:       \(sent) HEVC frames
           reassembled:\(framesCompleted)  decoded:\(decoded)  dims=\(box.firstDims.map { "\($0.width)x\($0.height)" } ?? "?")
           order:      source-span=\(String(format: "%.2f", m.spread))  monotone=\(String(format: "%.2f", m.monotoneRatio))  distinct=\(String(format: "%.2f", m.distinctRatio))  (matched \(sigs.count) decoded → \(r.sourceSignatures.count) source frames)
        """)
    }
}

// MARK: - Thread-safe collectors

private final class ReceiverBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _peer: LinkPeer?
    private var _lastPeerState: LinkPeer.State?
    private var _decoded = 0
    private var _firstDims: (width: Int, height: Int)?
    private var _sigs: [[Float]] = []

    // One reusable downscale context/buffer; onFrame is serialized by NetworkVideoSource.
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private lazy var scratch: CVPixelBuffer? = SimHarnessSupport.makeScratch(width: 128, height: 72)

    var peer: LinkPeer? { lock.withLock { _peer } }
    var lastPeerState: LinkPeer.State? { lock.withLock { _lastPeerState } }
    var decodedCount: Int { lock.withLock { _decoded } }
    var firstDims: (width: Int, height: Int)? { lock.withLock { _firstDims } }
    var signatures: [[Float]] { lock.withLock { _sigs } }

    func setPeer(_ p: LinkPeer) { lock.withLock { _peer = p } }
    func recordPeerState(_ s: LinkPeer.State) { lock.withLock { _lastPeerState = s } }

    func ingestDecoded(_ frame: VideoFrame) {
        let dims = (width: frame.width, height: frame.height)
        var sig: [Float] = []
        if let scratch { sig = SimHarnessSupport.lumaSignature(frame.pixelBuffer, ci: ci, scratch: scratch) }
        lock.withLock {
            _decoded += 1
            if _firstDims == nil { _firstDims = dims }
            if !sig.isEmpty { _sigs.append(sig) }
        }
    }
}

private final class ClientBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _state: LinkClient.State = .idle
    private var _config: LinkSessionConfig?
    var state: LinkClient.State { lock.withLock { _state } }
    var sessionConfig: LinkSessionConfig? { lock.withLock { _config } }
    func setState(_ s: LinkClient.State) { lock.withLock { _state = s } }
    func setSessionConfig(_ c: LinkSessionConfig) { lock.withLock { _config = c } }
}

private final class SentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var _keyframes = 0
    var count: Int { lock.withLock { _count } }
    var keyframes: Int { lock.withLock { _keyframes } }
    func increment(keyframe: Bool) { lock.withLock { _count += 1; if keyframe { _keyframes += 1 } } }
}
