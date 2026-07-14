import CryptoKit
import Foundation
import Network
import PrismCore
import Security

// MARK: - LinkServer

/// Mac-side receiver of the PrismLink transport (DESIGN.md §3.4).
///
/// QUIC listener (ALPN "prism/1") advertised over Bonjour as "_prism._udp".
/// Each connecting device arrives as an `NWConnectionGroup` (one QUIC tunnel):
/// its reliable streams surface via the group's new-connection handler and its
/// RFC 9221 datagrams via the group receive handler. QUIC datagram support IS
/// available in this SDK (`NWProtocolQUIC.Options.maxDatagramFrameSize`,
/// macOS 13+; our floor is 14) — no UDP fallback listener is needed. Because
/// every wire record is self-delimiting (see LinkProtocol.swift), control and
/// media lanes are parsed by the same `LinkFrameParser` regardless of which
/// lane bytes arrive on.
public final class LinkServer: @unchecked Sendable {
    public struct Configuration {
        /// Bonjour instance name (defaults to the host name).
        public var name: String
        /// UDP port; 0 lets the system pick (Bonjour carries the port).
        public var port: UInt16
        /// Server TLS identity. QUIC requires one at handshake time; leave
        /// nil with `pairingCode` set and `start()` generates an ephemeral
        /// self-signed identity (`LinkIdentity.createEphemeral`, macOS).
        /// nil + nil compiles and listens, but device handshakes will fail
        /// until credentials exist.
        public var identity: SecIdentity?
        /// Pairing bootstrap (DESIGN.md §3.4): the short code shown on the
        /// Mac. When set, every device must complete the v2 challenge
        /// round-trip — the server answers its hello with a random nonce and
        /// requires `LinkPairing.pairingProof(code:serverCertificateDER:nonce:)`
        /// back before the peer is activated (media and telemetry from an
        /// unverified peer are dropped). LAN-MVP security — see LinkPairing's
        /// honest-scope note. (TLS-layer PSK was the original design;
        /// Network.framework can't do TLS-1.3 PSK — see `LinkPairing.apply`.)
        public var pairingCode: String?
        /// Custom peer-certificate check (pinning). nil = accept any peer
        /// (pairing-layer security TODO; do not ship nil beyond the LAN MVP).
        public var verifyPeer: ((SecTrust) -> Bool)?
        /// A3 footgun guard: with no `pairingCode` AND no `verifyPeer`, the
        /// server would accept ANY device on the network. `start()` refuses
        /// that combination unless this is explicitly set to true (e.g. a
        /// closed test bench). Default false; the app always sets a code.
        public var allowUnpaired: Bool
        /// Session config pushed to every device right after its hello.
        public var sessionConfig: LinkSessionConfig
        public var maxDatagramFrameSize: Int
        /// Advertise over Bonjour. Disable for tests/headless use — Bonjour
        /// advertisement engages the Local Network privacy machinery.
        public var advertise: Bool

        /// Default server display name. `Host`/NSHost is macOS-only; other
        /// platforms (the package also builds for iOS) fall back to a constant.
        public static var defaultName: String {
            #if os(macOS)
            Host.current().localizedName ?? "Prism"
            #else
            "Prism"
            #endif
        }

        public init(name: String = Configuration.defaultName,
                    port: UInt16 = 0,
                    identity: SecIdentity? = nil,
                    pairingCode: String? = nil,
                    verifyPeer: ((SecTrust) -> Bool)? = nil,
                    allowUnpaired: Bool = false,
                    sessionConfig: LinkSessionConfig = LinkSessionConfig(),
                    maxDatagramFrameSize: Int = 65_527,
                    advertise: Bool = true) {
            self.name = name
            self.port = port
            self.identity = identity
            self.pairingCode = pairingCode
            self.verifyPeer = verifyPeer
            self.allowUnpaired = allowUnpaired
            self.sessionConfig = sessionConfig
            self.maxDatagramFrameSize = maxDatagramFrameSize
            self.advertise = advertise
        }
    }

    public enum ServerError: Error {
        case listenerFailed(Error)
        /// pairingCode was set, identity was nil, and the ephemeral identity
        /// could not be generated (keychain problem / non-macOS platform).
        case identityUnavailable(Error)
        /// No pairingCode, no verifyPeer, and `allowUnpaired` not set — this
        /// configuration would accept any device on the network (A3).
        case pairingRequired
        /// The pairing code is empty/too short (`LinkPairing.PairingError`).
        case invalidPairingCode(Error)
    }

    public var onPeerConnected: ((LinkPeer) -> Void)?
    public var onPeerDisconnected: ((LinkPeer) -> Void)?
    /// Fires on every listener state transition, with the bound UDP port when
    /// the state is `.ready` (useful when Configuration.port was 0; nil in
    /// all other states). Invoked on the server's internal queue.
    public var onListenerStateChange: ((NWListener.State, UInt16?) -> Void)?

    private let log = EngineLog.logger("link")
    private let queue = DispatchQueue(label: "studio.prism.link")
    private let configuration: Configuration
    private var listener: NWListener?
    private var peersByGroup: [ObjectIdentifier: LinkPeer] = [:]
    /// Pairing material every peer's challenge round-trip verifies against
    /// (set in `start()` when a pairing code is configured).
    private var pairing: LinkPeer.PairingContext?
    /// True when `start()` generated the ephemeral keychain identity — then
    /// `stop()` removes it (the key is kSecAttrIsPermanent; A8).
    private var ownsEphemeralIdentity = false

    struct IdentityMissing: Error {}

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public var peers: [LinkPeer] {
        queue.sync { Array(peersByGroup.values) }
    }

    /// The UDP port actually bound (nil until the listener is ready).
    /// Don't call from the server's own callbacks — they run on its queue.
    public var boundPort: UInt16? {
        queue.sync { listener?.port?.rawValue }
    }

    public func start() throws {
        // A3: refuse a configuration that would accept ANY device (no code,
        // no peer-cert check) unless the caller explicitly opted in.
        if configuration.pairingCode == nil, configuration.verifyPeer == nil {
            guard configuration.allowUnpaired else {
                log.error("start refused: no pairingCode and no verifyPeer — set allowUnpaired: true only if you really want an open server")
                throw ServerError.pairingRequired
            }
            log.warning("SECURITY: allowUnpaired server — ANY device on the network can attach")
        }
        // A6: reject empty/degenerate codes before anything derives from them.
        if let code = configuration.pairingCode {
            do { _ = try LinkPairing.derivePSK(code: code) }
            catch { throw ServerError.invalidPairingCode(error) }
        }
        // Resolve TLS credentials: an explicit identity wins; pairing mode
        // with no identity generates an ephemeral self-signed one (QUIC
        // cannot handshake without TLS credentials).
        var identity = configuration.identity
        if configuration.pairingCode != nil, identity == nil {
            do {
                identity = try LinkIdentity.createEphemeral()
                ownsEphemeralIdentity = true
            } catch { throw ServerError.identityUnavailable(error) }
        }
        if let code = configuration.pairingCode {
            guard let identity, let der = LinkIdentity.certificateDER(of: identity) else {
                throw ServerError.identityUnavailable(IdentityMissing())
            }
            pairing = LinkPeer.PairingContext(code: code, certificateDER: der)
        }
        let parameters = NWParameters(quic: makeQUICOptions(identity: identity))
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters,
                                      on: NWEndpoint.Port(rawValue: configuration.port) ?? .any)
        } catch {
            throw ServerError.listenerFailed(error)
        }

        if configuration.advertise {
            var txt = NWTXTRecord()
            txt["name"] = configuration.name
            txt["version"] = "\(LinkProtocol.version)"
            listener.service = NWListener.Service(name: configuration.name,
                                                  type: LinkProtocol.bonjourServiceType,
                                                  txtRecord: txt.data)
        }

        listener.newConnectionGroupHandler = { [weak self] group in
            self?.queue.async { self?.accept(group) }
        }
        // Do NOT also set newConnectionHandler: a QUIC listener with BOTH
        // handlers set fails at bind with EINVAL (verified empirically on
        // macOS 26 — this, not missing TLS credentials, was why the listener
        // never bound). Group handler alone is correct for QUIC.
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let port = self?.listener?.port?.rawValue
                self?.log.info("link listener ready on UDP \(port ?? 0)")
                self?.onListenerStateChange?(state, port)
            case .failed(let error):
                self?.log.error("link listener failed: \(error)")
                self?.onListenerStateChange?(state, nil)
            case .waiting(let error):
                // e.g. Local Network privacy not yet granted; Network.framework
                // retries by itself once the blocker clears.
                self?.log.warning("link listener waiting: \(error)")
                self?.onListenerStateChange?(state, nil)
            default:
                self?.onListenerStateChange?(state, nil)
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for peer in peersByGroup.values { peer.teardown() }
            peersByGroup.removeAll()
            // A8: the ephemeral identity's private key was created with
            // kSecAttrIsPermanent (SecIdentity requires a keychain-resident
            // key) — remove it so stopped servers don't accrete keys in the
            // user's keychain. Only when WE generated it, never for an
            // app-supplied identity.
            if ownsEphemeralIdentity {
                LinkIdentity.removeEphemeral()
                ownsEphemeralIdentity = false
            }
        }
    }

    private func makeQUICOptions(identity: SecIdentity?) -> NWProtocolQUIC.Options {
        let options = NWProtocolQUIC.Options(alpn: [LinkProtocol.alpn])
        options.direction = .bidirectional
        options.maxDatagramFrameSize = configuration.maxDatagramFrameSize
        options.idleTimeout = 15_000 // ms; devices ping every ~2 s (clock sync)

        if let identity, let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)
        }
        if let verifyPeer = configuration.verifyPeer {
            sec_protocol_options_set_peer_authentication_required(options.securityProtocolOptions, true)
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                complete(verifyPeer(trust))
            }, queue)
        }
        return options
    }

    private func accept(_ group: NWConnectionGroup) {
        let peer = LinkPeer(group: group, queue: queue,
                            sessionConfig: configuration.sessionConfig,
                            pairing: pairing)
        peersByGroup[ObjectIdentifier(group)] = peer
        log.info("peer connecting: \(peer.id)")

        group.stateUpdateHandler = { [weak self, weak group, weak peer] state in
            guard let self, let group, let peer else { return }
            switch state {
            case .ready:
                self.onPeerConnected?(peer)
            case .failed(let error):
                self.log.warning("peer \(peer.id) failed: \(error)")
                fallthrough
            case .cancelled:
                // The group is already dead — don't re-cancel it from inside
                // its own state callback. Guard against double delivery
                // (.failed is followed by .cancelled).
                peer.teardown(cancelGroup: false)
                if self.peersByGroup.removeValue(forKey: ObjectIdentifier(group)) != nil {
                    self.onPeerDisconnected?(peer)
                }
            default:
                break
            }
        }
        // Inbound reliable streams (the device opens the control stream first).
        group.newConnectionHandler = { [weak peer] connection in
            peer?.adopt(stream: connection)
        }
        // Inbound QUIC datagrams (the media lane).
        group.setReceiveHandler { [weak peer] _, content, _ in
            if let content {
                peer?.ingestMedia(content)
            }
        }
        group.start(queue: queue)
    }
}

// MARK: - LinkPeer

/// One connected device: its control stream, clock sync, media reassembly,
/// decoder, and `VideoSource` façade.
public final class LinkPeer: @unchecked Sendable {
    public enum State: Sendable {
        case connecting
        /// Hello received; capabilities known; media may flow.
        case active
        case disconnected
    }

    public let id: SourceID
    public private(set) var state: State = .connecting
    /// Device identity/capabilities (nil until its hello arrives).
    public private(set) var hello: LinkHello?
    /// Engine-facing video source for this peer.
    public let videoSource: NetworkVideoSource

    public var onStateChange: ((State) -> Void)?
    /// Telemetry from the device (thermal, encoder queue…), post-decode of stats messages.
    public var onStats: ((LinkStats) -> Void)?

    /// Pairing material (server code + server leaf cert DER) a peer must
    /// prove knowledge of via the v2 challenge round-trip.
    struct PairingContext {
        let code: String
        let certificateDER: Data
    }

    /// Progress of the v2 pairing sub-handshake for this peer.
    private enum PairingPhase {
        /// No pairing configured — the hello alone activates the peer.
        case notRequired
        /// Waiting for the hello; nothing but hello/clockPing is processed.
        case awaitingHello
        /// Challenge sent; waiting for the proof (bounded by `pairingTimeout`).
        case challenged(nonce: Data)
        /// Proof verified — peer fully active.
        case verified
    }

    /// How long a peer may sit unverified after its hello before being cut.
    private static let pairingTimeout: TimeInterval = 10

    private let log = EngineLog.logger("link.peer")
    private let group: NWConnectionGroup
    private let queue: DispatchQueue
    private let sessionConfig: LinkSessionConfig
    private let pairing: PairingContext?
    private var pairingPhase: PairingPhase
    private var controlStream: NWConnection?
    private var mediaParser = LinkFrameParser()
    private let reassembler = FrameReassembler()
    private let decoder: VideoFrameDecoder
    private var skewEstimator = ClockSkewEstimator()
    private var lastKeyframeRequest: TimeInterval = 0
    private var lastCompletedFrameID: UInt32?
    private var audioPacketsReceived: UInt64 = 0

    init(group: NWConnectionGroup, queue: DispatchQueue, sessionConfig: LinkSessionConfig,
         pairing: PairingContext? = nil) {
        let sourceID = SourceID("link:\(UUID().uuidString)")
        self.id = sourceID
        self.group = group
        self.queue = queue
        self.sessionConfig = sessionConfig
        self.pairing = pairing
        self.pairingPhase = pairing == nil ? .notRequired : .awaitingHello
        self.videoSource = NetworkVideoSource(id: sourceID)
        self.decoder = VideoFrameDecoder(source: sourceID)

        decoder.onFrame = { [weak self] frame in
            self?.videoSource.deliver(frame)
        }
        decoder.onNeedsKeyframe = { [weak self] in
            guard let self else { return }
            self.queue.async { self.requestKeyframe() }
        }
        // Proactive IDR recovery from the reassembler side: a dropped/evicted
        // datagram set requests a keyframe before the decoder even sees the gap
        // (B17). Reassembler runs on `queue`, so call directly.
        reassembler.onKeyframeNeeded = { [weak self] in
            self?.requestKeyframe()
        }
    }

    /// Datagram reassembly / loss counters for the stats HUD + bitrate feedback.
    public var mediaStats: ReassemblyStats {
        queue.sync { reassembler.stats }
    }

    /// Latest clock offset/skew estimate from the device's reported measurements.
    public var clockEstimate: ClockSkewEstimator.Estimate? {
        queue.sync { skewEstimator.estimate() }
    }

    // MARK: Outbound control

    public func send(tally: LinkTally) {
        sendControl(.tally, tally)
    }

    public func send(cameraControl: LinkCameraControl) {
        sendControl(.cameraControl, cameraControl)
    }

    public func send(sessionConfig: LinkSessionConfig) {
        sendControl(.sessionConfig, sessionConfig)
    }

    /// Feedback that drives the device's encoder bitrate ladder (§3.4).
    public func send(feedback: LinkStats) {
        sendControl(.stats, feedback)
    }

    /// Ask the device for an immediate IDR. Rate-limited to 1/second.
    public func requestKeyframe() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastKeyframeRequest >= 1.0 else { return }
        lastKeyframeRequest = now
        sendControl(.keyframeRequest, LinkKeyframeRequest(lastCompletedFrameID: lastCompletedFrameID))
    }

    private func sendControl<T: Encodable>(_ type: ControlMessageType, _ body: T) {
        guard let controlStream else {
            log.warning("peer \(self.id): dropping \(type.rawValue) — no control stream yet")
            return
        }
        do {
            let frame = try encodeControlMessage(type, body)
            controlStream.send(content: frame, completion: .contentProcessed { [weak self] error in
                if let error, let self {
                    self.log.warning("peer \(self.id): send \(type.rawValue) failed: \(String(describing: error))")
                }
            })
        } catch {
            log.error("peer \(self.id): control encode failed: \(String(describing: error))")
        }
    }

    // MARK: Inbound plumbing (called on the server queue)

    /// Every inbound stream runs the same self-delimiting parser; the stream
    /// the HELLO arrives on is promoted to control stream.
    ///
    /// Why content-based, not first-come: with datagrams negotiated, the
    /// peer's QUIC **datagram flow surfaces here as an extra inbound
    /// connection too** (verified empirically on macOS 26 — it arrives
    /// before the device's control stream, carries no stream bytes, and hits
    /// EOF early). Adopting "the first stream" as control therefore bound the
    /// control lane to a dead flow and every reply (sessionConfig, pongs)
    /// went nowhere. `NWProtocolQUIC.Metadata` exposes no stream type in
    /// Swift (`nw_quic_get_stream_type` is C-only), so identifying control by
    /// its first frame is the robust move — and only a control-stream death
    /// tears the peer down.
    func adopt(stream connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .failed(let error) = state {
                guard let self else { return }
                self.log.warning("peer \(self.id) stream failed: \(error)")
                if let connection, connection === self.controlStream {
                    self.teardown()
                }
            }
        }
        connection.start(queue: queue)
        receiveLoop(connection, parser: LinkFrameParser())
    }

    func ingestMedia(_ data: Data) {
        do {
            for item in try mediaParser.feed(data) {
                handle(item, from: nil)
            }
        } catch {
            log.error("peer \(self.id): media lane framing error: \(String(describing: error))")
            mediaParser = LinkFrameParser() // datagrams: safe to resync on the next one
        }
    }

    /// Idempotent. `cancelGroup: false` when the group is already
    /// failed/cancelled (tearing down from inside its own state callback).
    func teardown(cancelGroup: Bool = true) {
        guard state != .disconnected else { return }
        state = .disconnected
        videoSource.markFailed()
        controlStream?.cancel()
        controlStream = nil
        if cancelGroup { group.cancel() }
        onStateChange?(.disconnected)
    }

    /// One receive loop per inbound stream, each with its own parser (streams
    /// interleave; a shared parser would corrupt framing).
    private func receiveLoop(_ connection: NWConnection, parser: LinkFrameParser) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            var parser = parser
            if let data, !data.isEmpty {
                do {
                    for item in try parser.feed(data) {
                        self.handle(item, from: connection)
                    }
                } catch {
                    // A corrupted reliable stream can't resync. Fatal only if
                    // it was (or could still become) the control stream.
                    self.log.error("peer \(self.id): stream framing error: \(String(describing: error))")
                    if self.controlStream == nil || connection === self.controlStream {
                        self.teardown()
                    } else {
                        connection.cancel()
                    }
                    return
                }
            }
            if error != nil || isComplete {
                // The datagram flow (or a media fallback stream) closing is
                // not fatal; the control stream closing is the peer leaving.
                if connection === self.controlStream { self.teardown() }
                return
            }
            self.receiveLoop(connection, parser: parser)
        }
    }

    // MARK: Message handling

    /// True when pairing is enforced and this peer has not yet proven the
    /// code — nothing but the pairing sub-handshake (and clock pings, which
    /// are a stateless echo) may be processed from it.
    private var isUnverified: Bool {
        switch pairingPhase {
        case .notRequired, .verified: return false
        case .awaitingHello, .challenged: return true
        }
    }

    private func handle(_ item: LinkParsedItem, from connection: NWConnection?) {
        switch item {
        case .media(let header, let payload):
            guard !isUnverified else { return } // no media from unpaired peers
            let now = ProcessInfo.processInfo.systemUptime
            if let frame = reassembler.ingest(header: header, payload: payload, at: now) {
                lastCompletedFrameID = frame.frameID
                if frame.isAudio {
                    audioPacketsReceived += 1
                    // TODO(audio): AAC-ELD decode → AudioPacket via an
                    // AudioSource façade (AudioConverter, house-time PTS).
                } else {
                    decoder.decode(frame)
                }
            }
        case .control(let type, let payload):
            // The stream carrying the hello IS the control stream (see adopt).
            if type == .hello, controlStream == nil, let connection {
                controlStream = connection
            }
            handleControl(type: type, payload: payload)
        case .unknownControl(let type, _):
            log.info("peer \(self.id): ignoring unknown control type \(type)")
        }
    }

    private func handleControl(type: ControlMessageType, payload: Data) {
        do {
            switch type {
            case .hello:
                let hello = try JSONDecoder().decode(LinkHello.self, from: payload)
                if pairing != nil {
                    guard case .awaitingHello = pairingPhase else {
                        log.warning("peer \(self.id): duplicate hello during pairing — dropping")
                        teardown()
                        return
                    }
                    // Wire-compat cut (documented in LinkPairing): a legacy
                    // v1 static proof is replayable — refuse it outright
                    // rather than downgrade to the pre-nonce handshake.
                    guard hello.pairingProof == nil else {
                        log.warning("peer \(self.id): legacy static pairing proof (pre-v2 sender) — unsupported, dropping")
                        teardown()
                        return
                    }
                    self.hello = hello
                    sendPairingChallenge()
                    return // NOT active yet — activation happens on a valid proof
                }
                self.hello = hello
                activate()
            case .pairingResponse:
                guard let pairing, case .challenged(let nonce) = pairingPhase else {
                    log.warning("peer \(self.id): unexpected pairingResponse — dropping")
                    teardown()
                    return
                }
                let response = try JSONDecoder().decode(LinkPairingResponse.self, from: payload)
                let expected = try LinkPairing.pairingProof(code: pairing.code,
                                                            serverCertificateDER: pairing.certificateDER,
                                                            nonce: nonce)
                // Double-hash before comparing so `==`'s early exit can't
                // leak proof bytes through timing.
                guard let proof = Data(base64Encoded: response.proof),
                      SHA256.hash(data: proof) == SHA256.hash(data: expected) else {
                    log.warning("peer \(self.id): pairing proof invalid (wrong code?) — dropping")
                    teardown()
                    return
                }
                pairingPhase = .verified
                activate()
            case .clockPing:
                // Stamp house time immediately — this is the sync-critical path.
                let t2 = LinkClock.houseNanos()
                let ping = try JSONDecoder().decode(LinkClockPing.self, from: payload)
                let pong = LinkClock.pong(for: ping, receivedAtHouseNanos: t2,
                                          sendingAtHouseNanos: LinkClock.houseNanos())
                sendControl(.clockPong, pong)
            case .stats:
                guard !isUnverified else { return } // no telemetry from unpaired peers
                let stats = try JSONDecoder().decode(LinkStats.self, from: payload)
                if let device = stats.deviceClockNanos, let offset = stats.clockOffsetNanos {
                    skewEstimator.add(deviceNanos: device, offsetNanos: offset)
                }
                onStats?(stats)
            case .keyframeRequest, .sessionConfig, .cameraControl, .tally, .clockPong,
                 .pairingChallenge:
                // Mac→device message types; a device echoing them is a no-op.
                break
            }
        } catch {
            log.warning("peer \(self.id): bad \(type.rawValue) payload: \(String(describing: error))")
        }
    }

    // MARK: Pairing sub-handshake (v2, challenge–response)

    /// Answers the hello with a fresh random nonce and arms the pairing
    /// timeout. The proof the device must return is
    /// `HMAC(HKDF(code), context ‖ serverCertDER ‖ nonce)` — per-session, so
    /// a proof harvested from another connection fails here (replay defense).
    private func sendPairingChallenge() {
        var nonce = Data(count: 32)
        let status = nonce.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            // Never challenge with a predictable nonce.
            log.error("peer \(self.id): SecRandomCopyBytes failed (\(status)) — dropping")
            teardown()
            return
        }
        // Mutual auth (v2): if the device sent a nonce in its hello, prove WE
        // know the code too — HMAC over our own cert + the device's nonce — so
        // the device can confirm it is talking to a real Prism, not a spoof,
        // before it streams. Best-effort: a device that didn't request it (nil
        // nonce) gets the classic one-way challenge unchanged.
        var serverProofB64: String?
        if let pairing, let clientNonceB64 = hello?.clientNonce,
           let clientNonce = Data(base64Encoded: clientNonceB64) {
            do {
                serverProofB64 = try LinkPairing.serverProof(
                    code: pairing.code,
                    serverCertificateDER: pairing.certificateDER,
                    clientNonce: clientNonce).base64EncodedString()
            } catch {
                log.warning("peer \(self.id): could not compute server proof: \(String(describing: error))")
            }
        }
        pairingPhase = .challenged(nonce: nonce)
        sendControl(.pairingChallenge,
                    LinkPairingChallenge(nonce: nonce.base64EncodedString(), serverProof: serverProofB64))
        queue.asyncAfter(deadline: .now() + Self.pairingTimeout) { [weak self] in
            guard let self, self.isUnverified, self.state != .disconnected else { return }
            self.log.warning("peer \(self.id): pairing not completed within \(Self.pairingTimeout)s — dropping")
            self.teardown()
        }
    }

    /// Hello (and, when pairing is on, proof) accepted: the peer is live.
    private func activate() {
        state = .active
        log.info("peer \(self.id) hello: \(self.hello?.name ?? "?") (\(self.hello?.model ?? "?"))")
        send(sessionConfig: sessionConfig)
        onStateChange?(.active)
    }
}
