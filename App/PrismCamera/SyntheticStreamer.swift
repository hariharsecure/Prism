#if os(iOS)
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Network
import PrismLink
import PrismLinkSender

/// Headless / synthetic-frame streamer used to verify the PrismLink transport
/// end-to-end **without a camera** — e.g. in the iOS Simulator (where
/// `AVCaptureSession` has no device) or in CI.
///
/// It drives the SAME real transport the shipping app uses — `LinkClient`
/// (Bonjour discovery + QUIC/TLS-1.3 pairing) feeding a `LowLatencyEncoder`
/// (VideoToolbox HEVC) — but sources its `CVPixelBuffer`s from an animated
/// synthetic pattern instead of `AVCaptureVideoDataOutput`. Nothing here
/// touches `DeviceCameraStreamer`; the production camera path is unchanged.
///
/// Gated entirely by `PRISM_CAMERA_SYNTHETIC=1` (see `PrismCameraApp`), so a
/// normal device build never instantiates it.
///
/// Connection: if `host`/`port` are supplied it dials `127.0.0.1:<port>`
/// directly (Bonjour-independent — the reliable path across the Simulator
/// network boundary); otherwise it browses Bonjour `_prism._udp` and connects
/// to the first Mac it finds.
final class SyntheticStreamer: @unchecked Sendable {

    struct Options {
        var deviceName: String
        var pairingCode: String
        /// Direct-connect endpoint (skips Bonjour). Nil ⇒ browse.
        var host: String?
        var port: UInt16?
        var width: Int
        var height: Int
        var fps: Int
    }

    private let options: Options
    private let client: LinkClient
    private let queue = DispatchQueue(label: "studio.prism.camera.synthetic")
    private var encoder: SyntheticEncoder?
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var frameIndex: UInt64 = 0
    private var didConnect = false

    /// Coarse status for the on-screen label (optional UI mirror).
    private(set) var status = "starting"

    init(options: Options) {
        self.options = options
        let hello = LinkHello(name: options.deviceName,
                              model: "ios-simulator-synthetic",
                              maxWidth: options.width,
                              maxHeight: options.height,
                              maxFps: options.fps)
        self.client = LinkClient(configuration: .init(
            hello: hello,
            pairingCode: options.pairingCode.isEmpty ? nil : options.pairingCode))
        wire()
    }

    // MARK: Lifecycle

    func start() {
        log("synthetic mode: device=\(options.deviceName) \(options.width)x\(options.height)@\(options.fps) code=\(options.pairingCode.isEmpty ? "<none>" : "set")")
        if let host = options.host, let port = options.port,
           let nwPort = NWEndpoint.Port(rawValue: port) {
            log("direct connect → \(host):\(port) (bypassing Bonjour)")
            status = "connecting (direct)"
            client.connect(to: .hostPort(host: NWEndpoint.Host(host), port: nwPort))
        } else {
            log("browsing Bonjour _prism._udp for a Prism Mac…")
            status = "browsing"
            client.startBrowsing()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel(); timer = nil
            encoder?.invalidate(); encoder = nil
        }
        client.disconnect()
    }

    // MARK: Client wiring

    private func wire() {
        client.onServersChanged = { [weak self] servers in
            guard let self, self.options.host == nil, !self.didConnect,
                  let first = servers.first else { return }
            self.didConnect = true
            self.log("Bonjour found \(servers.count) server(s); connecting to \"\(first.name)\"")
            self.status = "connecting (\(first.name))"
            self.client.connect(to: first.endpoint)
        }
        client.onStateChange = { [weak self] state in
            guard let self else { return }
            self.log("link state → \(state)")
            switch state {
            case .connected:
                self.status = "connected — streaming synthetic HEVC"
                self.startEncoding()
            case .disconnected:
                self.status = "disconnected"
                self.queue.async { self.timer?.cancel(); self.timer = nil
                                   self.encoder?.invalidate(); self.encoder = nil }
            default:
                break
            }
        }
        client.onSessionConfig = { [weak self] config in
            self?.log("sessionConfig ← \(config.codec) \(config.width)x\(config.height)@\(config.fps) target=\(config.targetBitrateBps)bps")
        }
        // The synthetic encoder emits a keyframe every second by construction;
        // Mac keyframe requests / ladder steps are just logged here (the
        // shipping DeviceCameraStreamer honours them via LowLatencyEncoder).
        client.onKeyframeRequest = { [weak self] in self?.log("keyframeRequest ← (synthetic: IDR every 1s)") }
        client.onBitrateChange = { [weak self] bps in self?.log("bitrate ladder → \(bps)bps (synthetic: fixed)") }
        client.onTrustFailure = { [weak self] error in
            self?.log("TRUST FAILURE: \(error)")
        }
    }

    // MARK: Synthetic encode loop

    private func startEncoding() {
        queue.async { [self] in
            guard timer == nil else { return }
            guard let encoder = SyntheticEncoder(
                width: options.width, height: options.height,
                fps: options.fps, bitrateBps: 6_000_000) else {
                log("ENCODER CREATION FAILED — no HEVC/H.264 encoder in this environment")
                status = "encoder unavailable"
                return
            }
            encoder.onEncodedFrame = { [weak self] frame in
                self?.client.send(encoded: frame.annexB, pts: frame.pts,
                                  isKeyframe: frame.isKeyframe)
            }
            self.encoder = encoder
            log("synthetic encoder ready: codec=\(encoder.codecName)" +
                (encoder.codecName == "hevc" ? "" : " (Mac decoder is HEVC-only: media lane proven, decode won't complete)"))

            let t = DispatchSource.makeTimerSource(queue: queue)
            let interval = 1.0 / Double(max(1, options.fps))
            t.schedule(deadline: .now(), repeating: interval)
            t.setEventHandler { [weak self] in self?.emitFrame() }
            timer = t
            t.resume()
            log("synthetic encode loop running at \(options.fps) fps")
        }
    }

    private func emitFrame() {
        guard let encoder, let pixelBuffer = nextPixelBuffer() else { return }
        // Capture PTS on the device host clock (== LinkClock house clock);
        // LinkClient translates it to Mac house time via clock-sync.
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        encoder.encode(pixelBuffer: pixelBuffer, pts: pts,
                       duration: CMTime(value: 1, timescale: CMTimeScale(options.fps)))
        frameIndex &+= 1
        if frameIndex % UInt64(max(1, options.fps)) == 0 {
            let s = client.sendStats
            log("~\(frameIndex / UInt64(max(1, options.fps)))s: datagramsSent=\(s.datagramsSent) bytesSent=\(s.bytesSent) droppedAwaitingClock=\(s.framesDroppedAwaitingClock) sendErrors=\(s.datagramSendErrors)")
        }
    }

    // MARK: Synthetic frame source

    private func nextPixelBuffer() -> CVPixelBuffer? {
        if pool == nil { pool = makePool() }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess,
              let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)

        // Animated BGRA: a hue that cycles frame-to-frame + a vertical band
        // that sweeps across — guarantees real inter-frame motion so the
        // encoder produces non-trivial P-frames (proves the pipe, not a freeze).
        let phase = Double(frameIndex) * 0.06
        var bg = bgra(r: UInt8((sin(phase) * 0.5 + 0.5) * 200) + 30,
                      g: UInt8((sin(phase + 2.09) * 0.5 + 0.5) * 200) + 30,
                      b: UInt8((sin(phase + 4.18) * 0.5 + 0.5) * 200) + 30)
        for y in 0..<height {
            memset_pattern4(base + y * rowBytes, &bg, width * 4)
        }
        let bandWidth = max(4, width / 10)
        let bandX = Int(frameIndex % UInt64(width))
        let w = min(bandWidth, width - bandX)
        if w > 0 {
            var white: UInt32 = 0xFFFF_FFFF
            for y in 0..<height {
                memset_pattern4(base + y * rowBytes + bandX * 4, &white, w * 4)
            }
        }
        return buffer
    }

    private func bgra(r: UInt8, g: UInt8, b: UInt8) -> UInt32 {
        // Little-endian 32BGRA memory order: B, G, R, A
        UInt32(b) | (UInt32(g) << 8) | (UInt32(r) << 16) | (UInt32(0xFF) << 24)
    }

    private func makePool() -> CVPixelBufferPool? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: options.width,
            kCVPixelBufferHeightKey as String: options.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        if status != kCVReturnSuccess { log("pixel-buffer pool creation failed: \(status)") }
        return pool
    }

    private func log(_ message: String) {
        NSLog("[synthetic] \(message)")
    }
}
#endif
