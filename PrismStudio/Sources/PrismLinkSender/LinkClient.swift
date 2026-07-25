import CoreMedia
import CryptoKit
import Foundation
import Network
import PrismCore
import PrismLink
import Security

/// Device-side counterpart of PrismLink's `LinkServer` (DESIGN.md §3.4).
///
/// Discovery: NWBrowser over Bonjour "_prism._udp". Connection: one QUIC
/// tunnel (ALPN "prism/1", TLS 1.3, datagrams negotiated). The control
/// stream is whichever stream carries the hello (the server identifies it
/// by content, not arrival order — the tunnel's datagram flow also surfaces
/// as a stream on the server); the hello goes out the moment the first
/// stream is ready. When a code is set the server answers with a
/// pairingChallenge nonce and this client returns the code-derived,
/// cert+nonce-bound proof in a pairingResponse (LinkPairing v2). Clock
/// sync then runs continuously (8-ping burst at connect, one ping every
/// ~2 s after), and media rides the `mediaLane` (datagram flow when the OS
/// cooperates, reliable-stream fallback otherwise) as records fragmented
/// per `MediaDatagramHeader`, capture PTS translated to Mac house time.
public final class LinkClient: @unchecked Sendable {

    // MARK: Types

    /// A Mac running LinkServer, seen via Bonjour.
    public struct DiscoveredServer {
        /// Display name (TXT "name" if present, else the Bonjour instance name).
        public let name: String
        public let endpoint: NWEndpoint
    }

    public struct Configuration {
        /// Identity + capabilities sent as the hello.
        public var hello: LinkHello
        /// Pairing bootstrap (DESIGN.md §3.4): the short code the user
        /// typed / QR-scanned from the Mac's Prism window. When set, the
        /// server's (self-signed) certificate is accepted at the TLS layer
        /// subject to TOFU pinning (`trustedServerStore`), and the client
        /// answers the server's `pairingChallenge` with
        /// `LinkPairing.pairingProof(code:serverCertificateDER:nonce:)` —
        /// the server drops the peer if it doesn't match its own code +
        /// nonce. Can be updated after init via `setPairingCode(_:)`;
        /// the value in effect when `connect(to:)` runs is used.
        public var pairingCode: String?
        /// Custom peer-certificate check (pinning). When set it decides
        /// acceptance even in pairing mode (the certificate is still
        /// captured for the proof) and the built-in TOFU pinning is
        /// bypassed — the app owns trust entirely.
        public var verifyPeer: ((SecTrust) -> Bool)?
        /// A1 TOFU pinning: where the server's SPKI-SHA256 is pinned per
        /// pairing code. The first SUCCESSFUL pairing for a code stores the
        /// hash; later connects for that code reject a server whose leaf
        /// SPKI differs (`TrustError.pinnedCertificateMismatch` via
        /// `onTrustFailure`). Defaults to a fresh in-memory store (pins live
        /// for this process only); the app should inject a persistent
        /// (UserDefaults/file-backed) implementation. First contact remains
        /// trust-on-first-use — see `TrustedServerStore`.
        public var trustedServerStore: TrustedServerStore
        /// Total bytes per media datagram (header + payload). QUIC datagrams
        /// (RFC 9221) must fit in one QUIC packet, so this must stay under
        /// path MTU minus QUIC/UDP/IP overhead; 1200 is the standards-safe
        /// default. Raise only on a LAN you have measured.
        public var maxDatagramSize: Int
        /// Steady-state clock ping cadence (a burst of 8 runs at connect).
        public var clockPingInterval: TimeInterval
        public var bitrateLadder: BitrateLadder

        public init(hello: LinkHello,
                    pairingCode: String? = nil,
                    verifyPeer: ((SecTrust) -> Bool)? = nil,
                    trustedServerStore: TrustedServerStore = InMemoryTrustedServerStore(),
                    maxDatagramSize: Int = 1200,
                    clockPingInterval: TimeInterval = 2,
                    bitrateLadder: BitrateLadder = BitrateLadder()) {
            self.hello = hello
            self.pairingCode = pairingCode
            self.verifyPeer = verifyPeer
            self.trustedServerStore = trustedServerStore
            self.maxDatagramSize = max(LinkProtocol.mediaHeaderSize + 1, maxDatagramSize)
            self.clockPingInterval = clockPingInterval
            self.bitrateLadder = bitrateLadder
        }
    }

    /// Server-trust failures surfaced by the TOFU pinning check (A1). The
    /// connection is refused at the TLS layer when one of these fires.
    public enum TrustError: Error, Equatable {
        /// The server presented a leaf certificate whose SPKI-SHA256 differs
        /// from the one pinned for this pairing code — either a fake server,
        /// or the real Mac legitimately regenerated its (ephemeral) identity.
        /// The app decides: warn the user, and clear the pin only on an
        /// explicit re-pair.
        case pinnedCertificateMismatch(pinnedSPKISHA256: Data, presentedSPKISHA256: Data)
        /// The presented certificate could not be parsed for its SPKI —
        /// treated as failure, never as "skip pinning".
        case spkiExtractionFailed
    }

    public enum State: Sendable, Equatable {
        case idle
        case connecting
        /// Control stream open + hello sent. Media flows once the clock locks
        /// (first pong, typically well under a second after connect).
        case connected
        case disconnected
    }

    /// Send-side counters (monotonic since connect).
    public struct SendStats: Sendable {
        public var datagramsSent: UInt64 = 0
        public var bytesSent: UInt64 = 0
        /// Frames dropped because no clock estimate existed yet — sending an
        /// untranslated PTS would violate the house-time invariant (§3.3).
        public var framesDroppedAwaitingClock: UInt64 = 0
        public var datagramSendErrors: UInt64 = 0
    }

    // MARK: Callbacks (all invoked on the client's internal serial queue —
    // do not call the synchronous accessors from inside them)

    public var onServersChanged: (([DiscoveredServer]) -> Void)?
    public var onStateChange: ((State) -> Void)?
    /// Mac pushed a session config: apply bitrate/fps (and resolution) to the encoder.
    public var onSessionConfig: ((LinkSessionConfig) -> Void)?
    public var onTally: ((LinkTally) -> Void)?
    /// Mac wants an IDR now — wire to `LowLatencyEncoder.forceKeyframe()`.
    public var onKeyframeRequest: (() -> Void)?
    public var onCameraControl: ((LinkCameraControl) -> Void)?
    /// The bitrate ladder stepped on receiver feedback: apply to the encoder.
    public var onBitrateChange: ((Int) -> Void)?
    /// Raw Mac→device feedback (loss/jitter), after the ladder consulted it.
    public var onFeedback: ((LinkStats) -> Void)?
    /// TOFU pinning rejected the server's certificate (see `TrustError`).
    /// Fires just before the TLS handshake is refused; the tunnel then fails
    /// and `onStateChange(.disconnected)` follows.
    public var onTrustFailure: ((TrustError) -> Void)?

    // MARK: State

    private let log = EngineLog.logger("link.sender")
    private let queue = DispatchQueue(label: "studio.prism.link.sender")
    private let configuration: Configuration

    private var pairingCodeStorage: String?
    /// Leaf certificate the server presented, captured in the TLS verify
    /// block; the challenge proof is bound to these bytes.
    private var serverCertificateDER: Data?
    /// The pairing code in effect for the CURRENT connection attempt
    /// (snapshotted in `connect(to:)` so a mid-flight `setPairingCode` can't
    /// desynchronize proof and pin bookkeeping).
    private var activePairingCode: String?
    /// SPKI-SHA256 of the presented certificate, pending TOFU commit — it is
    /// pinned only when pairing SUCCEEDS (sessionConfig received), so a
    /// wrong-code or dropped handshake never pins an untrusted server.
    private var candidateSPKIHash: Data?
    /// Pairing v2 mutual auth. `clientNonce` is the fresh nonce we put in the
    /// hello when a pairing code is set; `mediaAuthorized` gates all media send
    /// — it stays false until the server returns a valid `serverProof` over that
    /// nonce (proving it knows the code), so a spoof first-contact server can
    /// never harvest our camera. Unpaired mode authorizes immediately.
    private var clientNonce: Data?
    private var mediaAuthorized = false
    private var browser: NWBrowser?
    private var group: NWConnectionGroup?
    private var controlStream: NWConnection?
    /// The lane media records ride on: ideally the tunnel's RFC 9221 datagram
    /// flow (`isDatagram = true`), else a reliable QUIC stream (§3.4's
    /// designed-in fallback — the server parses self-delimiting media records
    /// on any lane). On macOS 26 the datagram path is broken OS-side
    /// (verified: an explicit datagram flow dies instantly with ENETDOWN no
    /// matter when/how it's opened, and `NWConnectionGroup.send` delivers a
    /// handful of datagrams then fails ECANCELED), so in practice the
    /// datagram attempt fails over to the stream within milliseconds.
    private var mediaLane: NWConnection?
    private var controlParser = LinkFrameParser()
    private var fragmenter = MediaFragmenter()
    private var clockSync = DeviceClockSync()
    private var ladder: BitrateLadder

    private var stateStorage: State = .idle
    private var serversStorage: [DiscoveredServer] = []
    private var sendStatsStorage = SendStats()
    private var lastSessionConfigStorage: LinkSessionConfig?

    private var pingSeq: UInt32 = 0
    private var burstRemaining = 0
    private var pingGeneration = 0
    private var bytesSinceLastStats: UInt64 = 0
    private var lastStatsUptime: TimeInterval?
    private var loggedSendError = false

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.pairingCodeStorage = configuration.pairingCode
        self.ladder = configuration.bitrateLadder
    }

    /// Update the pairing code used by FUTURE `connect(to:)` calls (the app
    /// stores the user-entered code and may change it between attempts). Does
    /// not affect a tunnel already connecting/connected.
    public func setPairingCode(_ code: String?) {
        queue.async { self.pairingCodeStorage = code }
    }

    // MARK: Synchronous accessors (never call from a callback — deadlock)

    public var state: State { queue.sync { stateStorage } }
    public var servers: [DiscoveredServer] { queue.sync { serversStorage } }
    public var sendStats: SendStats { queue.sync { sendStatsStorage } }
    public var lastSessionConfig: LinkSessionConfig? { queue.sync { lastSessionConfigStorage } }
    /// Latest device-clock sync estimate (offset + skew), nil before first pong.
    public var clockEstimate: ClockSkewEstimator.Estimate? { queue.sync { clockSync.estimate() } }
    public var currentLadderBps: Int { queue.sync { ladder.currentBps } }

    // MARK: Discovery

    public func startBrowsing() {
        queue.async { [self] in
            guard browser == nil else { return }
            let parameters = NWParameters()
            parameters.includePeerToPeer = true
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: LinkProtocol.bonjourServiceType, domain: nil),
                using: parameters)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.updateServers(results) // browser handlers run on `queue`
            }
            browser.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.log.error("browser failed: \(String(describing: error))")
                }
            }
            browser.start(queue: queue)
            self.browser = browser
        }
    }

    public func stopBrowsing() {
        queue.async { [self] in
            browser?.cancel()
            browser = nil
        }
    }

    private func updateServers(_ results: Set<NWBrowser.Result>) {
        var found: [DiscoveredServer] = []
        for result in results {
            var name: String
            if case .service(let serviceName, _, _, _) = result.endpoint {
                name = serviceName
            } else {
                name = "\(result.endpoint)"
            }
            if case .bonjour(let txt) = result.metadata, let advertised = txt["name"] {
                name = advertised
            }
            found.append(DiscoveredServer(name: name, endpoint: result.endpoint))
        }
        serversStorage = found.sorted { $0.name < $1.name }
        onServersChanged?(serversStorage)
    }

    // MARK: Connection lifecycle

    /// Opens the QUIC tunnel to a discovered server (or any endpoint).
    public func connect(to endpoint: NWEndpoint) {
        queue.async { [self] in
            guard group == nil else {
                log.warning("connect ignored — already connected/connecting")
                return
            }
            setState(.connecting)
            activePairingCode = pairingCodeStorage

            let options = NWProtocolQUIC.Options(alpn: [LinkProtocol.alpn])
            options.direction = .bidirectional
            options.maxDatagramFrameSize = 65_527
            options.idleTimeout = 15_000 // matches the server; pings keep it alive
            // Pairing mode and/or pinning: install a verify block that
            // captures the server's leaf certificate (the challenge proof is
            // bound to it). With a custom verifyPeer, IT decides acceptance
            // (the app owns trust). Pairing-only applies TOFU pinning (A1):
            // the first successful pairing for a code pins the server's
            // SPKI-SHA256 in `trustedServerStore`; a later connect for that
            // code rejects a different SPKI. First contact (no pin yet) is
            // still accept-any — trust-on-first-use, documented in
            // `TrustedServerStore` and LinkPairing's honest-scope note.
            if pairingCodeStorage != nil || configuration.verifyPeer != nil {
                let verifyPeer = configuration.verifyPeer
                let store = configuration.trustedServerStore
                let pinnedHash = activePairingCode.flatMap {
                    store.trustedSPKIHash(forCode: LinkPairing.normalize($0))
                }
                sec_protocol_options_set_verify_block(options.securityProtocolOptions,
                                                      { [weak self] _, secTrust, complete in
                    let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                    var leafDER: Data?
                    if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                       let leaf = chain.first {
                        leafDER = SecCertificateCopyData(leaf) as Data
                        self?.serverCertificateDER = leafDER
                    }
                    if let verifyPeer {
                        complete(verifyPeer(trust))
                        return
                    }
                    // TOFU path (pairing mode, no custom verifier).
                    guard let leafDER, let spkiHash = ServerTrust.spkiSHA256(fromCertificateDER: leafDER) else {
                        self?.log.error("server certificate rejected: SPKI could not be extracted")
                        self?.onTrustFailure?(.spkiExtractionFailed)
                        complete(false)
                        return
                    }
                    if let pinnedHash, pinnedHash != spkiHash {
                        self?.log.error("server certificate rejected: SPKI does not match the pin for this pairing code (fake server, or the Mac re-generated its identity — re-pair explicitly to reset)")
                        self?.onTrustFailure?(.pinnedCertificateMismatch(
                            pinnedSPKISHA256: pinnedHash, presentedSPKISHA256: spkiHash))
                        complete(false)
                        return
                    }
                    self?.candidateSPKIHash = spkiHash
                    complete(true)
                }, queue)
            }

            let group = NWConnectionGroup(with: NWMultiplexGroup(to: endpoint),
                                          using: NWParameters(quic: options))
            group.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.openControlStream()
                case .failed(let error):
                    self.log.error("QUIC tunnel failed: \(String(describing: error))")
                    self.teardown()
                case .cancelled:
                    self.teardown()
                default:
                    break
                }
            }
            // Media is device→Mac only; drain anything unexpected defensively.
            group.setReceiveHandler { _, _, _ in }
            group.start(queue: queue)
            self.group = group
        }
    }

    public func disconnect() {
        queue.async { self.teardown() }
    }

    private func teardown() {
        guard group != nil || controlStream != nil else { return }
        pingGeneration += 1 // invalidates the ping chain
        let stream = controlStream
        let lane = mediaLane
        let tunnel = group
        controlStream = nil
        mediaLane = nil
        group = nil
        stream?.cancel()
        lane?.cancel()
        tunnel?.cancel()
        controlParser = LinkFrameParser()
        fragmenter = MediaFragmenter()
        clockSync = DeviceClockSync()
        serverCertificateDER = nil
        activePairingCode = nil
        candidateSPKIHash = nil
        clientNonce = nil
        mediaAuthorized = false
        sendStatsStorage = SendStats()
        bytesSinceLastStats = 0
        lastStatsUptime = nil
        burstRemaining = 0
        loggedSendError = false
        setState(.disconnected)
    }

    private func setState(_ new: State) {
        guard stateStorage != new else { return }
        stateStorage = new
        onStateChange?(new)
    }

    // MARK: Control stream

    private func openControlStream() {
        guard let group, controlStream == nil else { return }
        // Server contract: the FIRST stream the device opens is control.
        guard let stream = NWConnection(from: group) else {
            log.error("could not open the control stream")
            teardown()
            return
        }
        controlStream = stream
        stream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.controlStreamReady()
            case .failed(let error):
                self.log.error("control stream failed: \(String(describing: error))")
                self.teardown()
            default:
                break
            }
        }
        stream.start(queue: queue)
        receiveLoop(stream)
    }

    /// Opens the media lane: try the datagram flow first, fail over to a
    /// reliable stream (see `mediaLane` docs). Called at control-stream
    /// ready, so the fallback has settled long before media starts flowing
    /// (media waits for the first clock estimate, ~1 s).
    private func openMediaLane() {
        guard let group, mediaLane == nil else { return }
        let options = NWProtocolQUIC.Options()
        options.isDatagram = true
        options.maxDatagramFrameSize = 65_527
        guard let flow = NWConnection(from: group, using: options) else {
            openReliableMediaLane()
            return
        }
        mediaLane = flow
        flow.stateUpdateHandler = { [weak self, weak flow] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.log.info("media lane: QUIC datagram flow ready")
            case .failed(let error):
                if let flow, self.mediaLane === flow {
                    self.log.warning("datagram flow failed (\(String(describing: error), privacy: .public)) — media falls back to a reliable QUIC stream")
                    self.mediaLane = nil
                    self.openReliableMediaLane()
                }
            default:
                break
            }
        }
        flow.start(queue: queue)
    }

    private func openReliableMediaLane() {
        guard let group, mediaLane == nil else { return }
        guard let stream = NWConnection(from: group) else {
            log.error("could not open a media stream — media cannot be sent")
            return
        }
        mediaLane = stream
        stream.stateUpdateHandler = { [weak self, weak stream] state in
            guard let self else { return }
            if case .failed(let error) = state, let stream, self.mediaLane === stream {
                self.log.error("media stream failed: \(String(describing: error), privacy: .public)")
                self.mediaLane = nil // next media send retries the ladder
            }
        }
        stream.start(queue: queue)
    }

    private func controlStreamReady() {
        guard stateStorage == .connecting else { return }
        if activePairingCode != nil {
            // Mutual auth (v2): mint a fresh nonce and require the server to
            // prove it knows the code (bound to its cert + our nonce) BEFORE we
            // open the media lane. Until then media is withheld (`mediaAuthorized`
            // false), so a spoof first-contact server cannot harvest the camera.
            var nonce = Data(count: 32)
            let status = nonce.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
            }
            guard status == errSecSuccess else {
                log.error("SecRandomCopyBytes failed (\(status)) — cannot pair safely, disconnecting")
                teardown()
                return
            }
            clientNonce = nonce
            mediaAuthorized = false
            var hello = configuration.hello
            hello.clientNonce = nonce.base64EncodedString()
            sendControl(.hello, hello)
            setState(.connected)   // control up; media stays gated until verified
            startClockSync()
            log.info("connected; hello+nonce sent, awaiting server proof before streaming")
        } else {
            // Unpaired (opt-in allowUnpaired): there is no code to verify a
            // server against — classic path, media authorized immediately.
            mediaAuthorized = true
            sendControl(.hello, configuration.hello)
            openMediaLane()
            setState(.connected)
            startClockSync()
            log.info("connected; hello sent as \(self.configuration.hello.name)")
        }
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            if let data, !data.isEmpty {
                do {
                    for item in try self.controlParser.feed(data) {
                        self.handle(item)
                    }
                } catch {
                    // A corrupted reliable stream can't resync — drop the link.
                    self.log.error("control framing error: \(String(describing: error))")
                    self.teardown()
                    return
                }
            }
            if error != nil || isComplete {
                self.teardown()
                return
            }
            self.receiveLoop(connection)
        }
    }

    private func sendControl<T: Encodable>(_ type: ControlMessageType, _ body: T) {
        guard let controlStream else { return }
        do {
            let frame = try encodeControlMessage(type, body)
            controlStream.send(content: frame, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.log.warning("send \(type.rawValue) failed: \(String(describing: error))")
                }
            })
        } catch {
            log.error("control encode failed: \(String(describing: error))")
        }
    }

    // MARK: Inbound control handling

    private func handle(_ item: LinkParsedItem) {
        switch item {
        case .control(let type, let payload):
            handleControl(type: type, payload: payload)
        case .unknownControl(let type, _):
            log.info("ignoring unknown control type \(type)")
        case .media:
            log.warning("unexpected media record on the control stream — ignoring")
        }
    }

    private func handleControl(type: ControlMessageType, payload: Data) {
        do {
            switch type {
            case .clockPong:
                // Stamp device time immediately — this is the sync-critical path.
                let t4 = LinkClock.houseNanos() // host clock; on the device this IS device time
                let pong = try JSONDecoder().decode(LinkClockPong.self, from: payload)
                clockSync.ingest(pong: pong, receivedAtDeviceNanos: t4)
            case .pairingChallenge:
                let challenge = try JSONDecoder().decode(LinkPairingChallenge.self, from: payload)
                guard let code = activePairingCode else {
                    log.warning("server sent a pairing challenge but no pairing code is set — disconnecting")
                    teardown()
                    return
                }
                guard let der = serverCertificateDER,
                      let nonce = Data(base64Encoded: challenge.nonce) else {
                    log.error("pairing challenge unanswerable (no captured certificate / bad nonce encoding) — disconnecting")
                    teardown()
                    return
                }
                // Mutual auth (v2): before we respond OR stream, require the
                // server to prove IT knows the code — HMAC over its cert + the
                // nonce WE minted. A spoof first-contact server can't produce it,
                // so it never receives our camera. (Skipped only in unpaired mode
                // where clientNonce is nil and there is no code to verify.)
                if let clientNonce {
                    guard let proofB64 = challenge.serverProof,
                          let serverProof = Data(base64Encoded: proofB64) else {
                        log.error("server returned no proof (spoof server, or pre-v2 Mac) — refusing to stream, disconnecting")
                        teardown()
                        return
                    }
                    do {
                        let expected = try LinkPairing.serverProof(code: code,
                                                                   serverCertificateDER: der,
                                                                   clientNonce: clientNonce)
                        // Double-hash compare so `==`'s early exit can't leak bytes.
                        guard SHA256.hash(data: serverProof) == SHA256.hash(data: expected) else {
                            log.error("server proof invalid (fake Mac / wrong code) — disconnecting")
                            teardown()
                            return
                        }
                    } catch {
                        log.error("server proof check failed (\(String(describing: error))) — disconnecting")
                        teardown()
                        return
                    }
                }
                do {
                    // Throws on short codes (A6) and short nonces (a hostile
                    // server must not be able to downgrade the challenge).
                    let proof = try LinkPairing.pairingProof(code: code,
                                                             serverCertificateDER: der,
                                                             nonce: nonce)
                    sendControl(.pairingResponse,
                                LinkPairingResponse(proof: proof.base64EncodedString()))
                    // Server authenticated → now it is safe to stream.
                    mediaAuthorized = true
                    openMediaLane()
                } catch {
                    log.error("pairing proof failed (\(String(describing: error))) — disconnecting")
                    teardown()
                }
            case .sessionConfig:
                let config = try JSONDecoder().decode(LinkSessionConfig.self, from: payload)
                // sessionConfig is the server's "pairing accepted" — commit the
                // TOFU pin now (first successful pairing for this code). Gated on
                // `mediaAuthorized` so ONLY a server that already proved it knows
                // the code can pin: otherwise a spoof could send sessionConfig
                // pre-proof and poison the pin, later locking out the real Mac.
                if mediaAuthorized, let code = activePairingCode, let candidate = candidateSPKIHash,
                   configuration.verifyPeer == nil {
                    let normalized = LinkPairing.normalize(code)
                    if configuration.trustedServerStore.trustedSPKIHash(forCode: normalized) == nil {
                        configuration.trustedServerStore.setTrustedSPKIHash(candidate, forCode: normalized)
                        log.info("TOFU: pinned server SPKI for this pairing code")
                    }
                }
                lastSessionConfigStorage = config
                ladder.select(closestTo: config.targetBitrateBps)
                onSessionConfig?(config)
            case .tally:
                let tally = try JSONDecoder().decode(LinkTally.self, from: payload)
                onTally?(tally)
            case .keyframeRequest:
                onKeyframeRequest?()
            case .cameraControl:
                let control = try JSONDecoder().decode(LinkCameraControl.self, from: payload)
                onCameraControl?(control)
            case .stats:
                let feedback = try JSONDecoder().decode(LinkStats.self, from: payload)
                if let newBps = ladder.apply(feedback: feedback,
                                             at: ProcessInfo.processInfo.systemUptime) {
                    log.info("bitrate ladder → \(newBps) bps (loss \(feedback.lossPercent ?? -1)%)")
                    onBitrateChange?(newBps)
                }
                onFeedback?(feedback)
            case .hello, .clockPing, .pairingResponse:
                break // device→Mac message types; a server echoing them is a no-op
            }
        } catch {
            log.warning("bad \(type.rawValue) payload: \(String(describing: error))")
        }
    }

    // MARK: Clock sync loop

    private func startClockSync() {
        burstRemaining = 8 // §3.4: 8-ping burst at connect, outlier-rejected
        pingGeneration += 1
        sendClockPing()
        scheduleNextPing()
    }

    private func scheduleNextPing() {
        let generation = pingGeneration
        let delay = burstRemaining > 0 ? 0.12 : configuration.clockPingInterval
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.pingGeneration == generation, self.controlStream != nil else { return }
            self.sendClockPing()
            if self.burstRemaining == 0 {
                self.sendPeriodicStats()
            }
            self.scheduleNextPing()
        }
    }

    private func sendClockPing() {
        if burstRemaining > 0 { burstRemaining -= 1 }
        pingSeq &+= 1
        let ping = LinkClockPing(seq: pingSeq, t1: LinkClock.houseNanos())
        // Record before sending so the matching pong correlates (a pong that
        // does not echo a ping we sent is dropped in ingest).
        clockSync.registerPing(seq: ping.seq, t1: ping.t1)
        sendControl(.clockPing, ping)
    }

    /// Telemetry the server folds into its skew view + HUD: current clock
    /// measurement, thermal state, achieved send bitrate.
    private func sendPeriodicStats() {
        let nowNanos = LinkClock.houseNanos()
        guard let estimate = clockSync.estimate(atDeviceNanos: nowNanos) else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        var sendBitrateBps: Int?
        if let last = lastStatsUptime, uptime > last {
            sendBitrateBps = Int(Double(bytesSinceLastStats) * 8 / (uptime - last))
        }
        lastStatsUptime = uptime
        bytesSinceLastStats = 0
        sendControl(.stats, LinkStats(thermalState: ProcessInfo.processInfo.thermalState.rawValue,
                                      sendBitrateBps: sendBitrateBps,
                                      deviceClockNanos: nowNanos,
                                      clockOffsetNanos: estimate.offsetNanos))
    }

    /// Device → Mac telemetry (also sent automatically every ping interval).
    public func send(stats: LinkStats) {
        queue.async { self.sendControl(.stats, stats) }
    }

    // MARK: Media send

    /// Fragments one encoded frame into QUIC datagrams per
    /// `MediaDatagramHeader` and sends them. `pts` is the capture timestamp
    /// (device host clock) — it is translated to Mac house time here using
    /// the live clock-sync offset. Frames arriving before the first clock
    /// estimate are dropped (counted in `sendStats`) rather than sent with a
    /// wrong-epoch PTS.
    public func send(encoded: Data, pts: CMTime, isKeyframe: Bool) {
        queue.async { [self] in
            // `mediaAuthorized` is the mutual-auth gate: in pairing mode it is
            // false until the server proved it knows the code, so pre-auth frames
            // (capture starts on `.connected`) are dropped, not leaked to a spoof.
            guard group != nil, stateStorage == .connected, mediaAuthorized else { return }
            if mediaLane == nil { openMediaLane() } // lane died: retry the ladder
            guard let mediaLane else {
                sendStatsStorage.datagramSendErrors &+= 1
                return
            }
            let deviceNanos = CMTimeConvertScale(pts, timescale: 1_000_000_000,
                                                 method: .default).value
            guard let houseNanos = clockSync.houseNanos(forDeviceNanos: deviceNanos) else {
                sendStatsStorage.framesDroppedAwaitingClock &+= 1
                return
            }
            let flags: MediaDatagramHeader.Flags = isKeyframe ? [.keyframe] : []
            let datagrams = fragmenter.fragment(payload: encoded, ptsHouseNanos: houseNanos,
                                                flags: flags,
                                                maxDatagramSize: configuration.maxDatagramSize)
            guard !datagrams.isEmpty else {
                log.warning("frame not sendable (\(encoded.count) bytes) — dropped")
                return
            }
            for datagram in datagrams {
                mediaLane.send(content: datagram, completion: .contentProcessed { [weak self] error in
                    guard let self, error != nil else { return }
                    self.sendStatsStorage.datagramSendErrors &+= 1
                    if !self.loggedSendError {
                        self.loggedSendError = true
                        self.log.warning("datagram send failed: \(String(describing: error), privacy: .public) (further errors counted, not logged)")
                    }
                })
                sendStatsStorage.datagramsSent &+= 1
                sendStatsStorage.bytesSent &+= UInt64(datagram.count)
                bytesSinceLastStats &+= UInt64(datagram.count)
            }
        }
    }
}
