import CryptoKit
import Foundation
import Network
import PrismCore

/// obs-websocket 5.x–compatible control server (DESIGN.md §2.7): Stream Deck,
/// Bitfocus Companion, chat bots and every other OBS-ecosystem tool connect to
/// Prism unchanged on the standard port 4455.
///
/// Transport: Network.framework — NWListener with NWProtocolWebSocket over TCP.
/// Protocol: JSON envelopes `{op, d}`; op 0 Hello → op 1 Identify → op 2
/// Identified, then op 6 Request / op 7 RequestResponse and op 5 Event pushes.
/// The engine plugs in via `ControlBackend` and pushes state changes through
/// `publish(_:)`.
public final class ControlServer: @unchecked Sendable {
    public enum ServerError: Error {
        case invalidPort
        case listenerFailed(Error)
        /// A network-reachable (non-loopback) bind was requested without a
        /// password. The control surface can start/stop recording+streaming, so
        /// exposing it to the LAN unauthenticated is refused (fail-closed).
        case passwordRequiredForNetworkBind
    }

    /// Requests implemented today; also reported by GetVersion.availableRequests.
    public static let supportedRequests: [String] = [
        "GetVersion", "GetStats",
        "GetSceneList", "GetCurrentProgramScene", "SetCurrentProgramScene",
        "StartRecord", "StopRecord", "GetRecordStatus",
        "StartStream", "StopStream", "GetStreamStatus",
    ]

    /// The engine seam. Set before (or after) `start()`; requests arriving
    /// while nil are answered with 207 NotReady.
    public var backend: ControlBackend? {
        get { queue.sync { _backend } }
        set { queue.sync { _backend = newValue } }
    }

    private let log = EngineLog.logger("control")
    private let queue = DispatchQueue(label: "studio.prism.control")
    private let port: NWEndpoint.Port
    private let password: String?
    /// When true (default), the listener binds loopback only — same-Mac tools
    /// (Stream Deck, Companion) work; LAN clients cannot reach it. Set false to
    /// expose it on the network, which then REQUIRES a password.
    private let bindLoopbackOnly: Bool
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var _backend: ControlBackend?

    /// - Parameters:
    ///   - port: TCP port, default 4455 (the obs-websocket standard).
    ///   - password: when non-nil, Hello carries an auth challenge and Identify
    ///     must present base64(sha256(base64(sha256(password+salt))+challenge)).
    ///   - bindLoopbackOnly: default true — bind 127.0.0.1 only. Pass false for a
    ///     LAN-reachable bind, which requires a non-nil `password` (else `start()`
    ///     throws `passwordRequiredForNetworkBind`).
    public init(port: UInt16 = 4455, password: String? = nil, bindLoopbackOnly: Bool = true) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 4455
        self.password = (password?.isEmpty ?? true) ? nil : password
        self.bindLoopbackOnly = bindLoopbackOnly
    }

    // MARK: Lifecycle

    public func start() throws {
        // Fail-closed: a network-reachable control surface without a password
        // would let any LAN peer start/stop recording+streaming.
        guard bindLoopbackOnly || password != nil else {
            throw ServerError.passwordRequiredForNetworkBind
        }
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        // Accept obs-websocket's JSON subprotocol; we do not speak msgpack.
        wsOptions.setClientRequestHandler(queue) { subprotocols, _ in
            if subprotocols.contains(OBSWS.subprotocolJSON) {
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: OBSWS.subprotocolJSON)
            }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback-only bind (default): restrict to the loopback interface so the
        // control surface is reachable only from the same Mac.
        if bindLoopbackOnly {
            parameters.requiredInterfaceType = .loopback
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            throw ServerError.listenerFailed(error)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.log.info("control server listening on \(self?.port.rawValue ?? 0)")
            case .failed(let error): self?.log.error("control listener failed: \(error)")
            default: break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for session in sessions.values { session.connection.cancel() }
            sessions.removeAll()
        }
    }

    /// Engine → clients: broadcast an op-5 Event to every identified session
    /// whose eventSubscriptions include the event's intent bit.
    public func publish(_ event: ControlEvent) {
        let (type, intent, data) = Self.materialize(event)
        let envelope = OBSWS.event(type: type, intent: intent, data: data)
        queue.async { [self] in
            for session in sessions.values where session.identified && session.subscriptions.contains(intent) {
                send(envelope, to: session)
            }
        }
    }

    static func materialize(_ event: ControlEvent) -> (String, OBSWS.EventSubscription, [String: Any]) {
        switch event {
        case .currentProgramSceneChanged(let sceneName):
            return ("CurrentProgramSceneChanged", .scenes,
                    ["sceneName": sceneName, "sceneUuid": Self.sceneUuid(sceneName)])
        case .recordStateChanged(let active, let state, let outputPath):
            var d: [String: Any] = ["outputActive": active, "outputState": state.rawValue]
            d["outputPath"] = outputPath ?? NSNull()
            return ("RecordStateChanged", .outputs, d)
        case .streamStateChanged(let active, let state):
            return ("StreamStateChanged", .outputs,
                    ["outputActive": active, "outputState": state.rawValue])
        }
    }

    /// Stable per-name UUID so v5 clients that key on sceneUuid work. Prism has
    /// no persistent scene UUIDs yet, so derive one from the name (SHA256 → v4 shape).
    static func sceneUuid(_ name: String) -> String {
        let digest = Array(SHA256.hash(data: Data(name.utf8)))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x40 // version 4 shape
        b[8] = (b[8] & 0x3F) | 0x80 // RFC variant
        let uuid = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                               b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
        return uuid.uuidString.lowercased()
    }

    // MARK: Sessions

    /// All mutable state is confined to the server queue; connections are
    /// thread-safe by contract. Hence `@unchecked Sendable`.
    private final class Session: @unchecked Sendable {
        let connection: NWConnection
        var identified = false
        var subscriptions: OBSWS.EventSubscription = .all
        var challenge: String = ""
        var salt: String = ""
        var incomingMessages: UInt64 = 0
        var outgoingMessages: UInt64 = 0
        /// Tail of this session's serial request chain (M1). Each op-6 request
        /// awaits the previous request's task before touching the backend and
        /// before emitting its response, so a client's ordered requests
        /// (e.g. StopStream then StartStream) apply and respond in requestId order
        /// instead of interleaving. Confined to the server `queue`.
        var requestTail: Task<Void, Never>?
        init(connection: NWConnection) { self.connection = connection }
    }

    private func accept(_ connection: NWConnection) {
        let session = Session(connection: connection)
        sessions[ObjectIdentifier(connection)] = session
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.sendHello(to: session)
                self.receiveNext(session)
            case .failed, .cancelled:
                self.sessions.removeValue(forKey: ObjectIdentifier(connection))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func sendHello(to session: Session) {
        var auth: (challenge: String, salt: String)? = nil
        if password != nil {
            session.challenge = OBSWS.randomToken()
            session.salt = OBSWS.randomToken()
            auth = (session.challenge, session.salt)
        }
        send(OBSWS.hello(authentication: auth), to: session)
    }

    private func receiveNext(_ session: Session) {
        session.connection.receiveMessage { [weak self, weak session] data, context, _, error in
            guard let self, let session else { return }
            if error != nil {
                session.connection.cancel()
                return
            }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            if let meta, meta.opcode == .close {
                session.connection.cancel()
                return
            }
            if let data, !data.isEmpty, meta == nil || meta!.opcode == .text || meta!.opcode == .binary {
                session.incomingMessages += 1
                self.handleMessage(data, from: session)
            }
            self.receiveNext(session)
        }
    }

    private func close(_ session: Session, reason: OBSWS.CloseReason) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        if let code = try? NWProtocolWebSocket.CloseCode(rawValue: reason.rawValue) {
            metadata.closeCode = code
        }
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        session.connection.send(content: nil, contentContext: context, isComplete: true,
                                completion: .contentProcessed { [weak session] _ in
            session?.connection.cancel()
        })
    }

    private func send(_ envelope: OBSWS.Envelope, to session: Session) {
        sendRaw(OBSWS.encodeEnvelope(envelope), to: session)
    }

    private func sendRaw(_ data: Data, to session: Session) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        session.outgoingMessages += 1
        session.connection.send(content: data, contentContext: context, isComplete: true,
                                completion: .contentProcessed { _ in })
    }

    // MARK: Protocol state machine

    private func handleMessage(_ data: Data, from session: Session) {
        let envelope: OBSWS.Envelope
        do {
            envelope = try OBSWS.decodeEnvelope(data)
        } catch {
            log.warning("unparseable message from client: \(String(describing: error))")
            close(session, reason: .unknownOpCode)
            return
        }
        switch envelope.op {
        case .identify:
            handleIdentify(envelope.d, session: session)
        case .reidentify:
            guard session.identified else { return close(session, reason: .notIdentified) }
            applySubscriptions(envelope.d, to: session)
            send(OBSWS.identified(), to: session)
        case .request:
            guard session.identified else { return close(session, reason: .notIdentified) }
            handleRequest(envelope.d, session: session)
        case .requestBatch:
            // Not implemented yet; spec-shaped empty failure is worse than closing —
            // batch is rare from control surfaces. Respond per-op unsupported.
            guard session.identified else { return close(session, reason: .notIdentified) }
            let id = envelope.d["requestId"] as? String ?? ""
            send(OBSWS.requestResponse(requestType: "RequestBatch", requestId: id,
                                       code: .unknownRequestType,
                                       comment: "Request batches are not supported yet."), to: session)
        default:
            close(session, reason: .unknownOpCode)
        }
    }

    private func handleIdentify(_ d: [String: Any], session: Session) {
        guard !session.identified else { return close(session, reason: .alreadyIdentified) }
        guard let rpc = d["rpcVersion"] as? Int, rpc == OBSWS.rpcVersion else {
            return close(session, reason: .unsupportedRpcVersion)
        }
        if let password {
            let expected = OBSWS.authResponse(password: password, salt: session.salt,
                                              challenge: session.challenge)
            guard let presented = d["authentication"] as? String,
                  OBSWS.constantTimeEquals(presented, expected) else {
                log.warning("client failed authentication")
                return close(session, reason: .authenticationFailed)
            }
        }
        applySubscriptions(d, to: session)
        session.identified = true
        send(OBSWS.identified(), to: session)
    }

    private func applySubscriptions(_ d: [String: Any], to session: Session) {
        if let raw = d["eventSubscriptions"] as? Int {
            session.subscriptions = OBSWS.EventSubscription(rawValue: raw)
        } else {
            session.subscriptions = .all
        }
    }

    // MARK: Request dispatch

    private func handleRequest(_ d: [String: Any], session: Session) {
        guard let type = d["requestType"] as? String, let id = d["requestId"] as? String else {
            close(session, reason: .unknownOpCode)
            return
        }
        let requestData = d["requestData"] as? [String: Any] ?? [:]
        // Snapshot everything the response needs off the queue-confined session.
        let backend = _backend
        let sessionIn = session.incomingMessages
        let sessionOut = session.outgoingMessages

        // Chain this request behind the session's previous one so ordered requests
        // apply and respond in requestId order (M1). An independent Task per request
        // could interleave — a StopStream then StartStream could leave the stream
        // STARTED when the user meant stopped, and responses could arrive out of
        // order. Because the previous task enqueues its `sendRaw` before it
        // completes, awaiting it also preserves response ordering on `queue`.
        let previous = session.requestTail
        session.requestTail = Task { [weak self, weak session] in
            await previous?.value
            guard let self else { return }
            let envelope = await Self.responseEnvelope(type: type, id: id, requestData: requestData,
                                                       backend: backend,
                                                       sessionMessages: (sessionIn, sessionOut))
            // Serialize off-queue (pure), deliver the Sendable bytes on-queue.
            let payload = OBSWS.encodeEnvelope(envelope)
            self.queue.async { [weak session] in
                guard let session else { return }
                self.sendRaw(payload, to: session)
            }
        }
    }

    /// Computes the op-7 response for one request. Pure with respect to the server
    /// (no session/connection mutation) so the serial chain in `handleRequest` can
    /// run it off-queue. Preserves the original dispatch order:
    /// unsupported → no-backend → GetVersion (inline) → backend `execute`.
    static func responseEnvelope(type: String, id: String, requestData: [String: Any],
                                 backend: ControlBackend?,
                                 sessionMessages: (incoming: UInt64, outgoing: UInt64)) async -> OBSWS.Envelope {
        guard Self.supportedRequests.contains(type) else {
            return OBSWS.requestResponse(requestType: type, requestId: id, code: .unknownRequestType)
        }
        guard let backend else {
            return OBSWS.requestResponse(requestType: type, requestId: id, code: .notReady,
                                         comment: "No engine attached.")
        }
        // GetVersion needs no backend hop and answers inline.
        if type == "GetVersion" {
            return OBSWS.requestResponse(requestType: type, requestId: id, code: .success,
                                         responseData: Self.versionPayload())
        }
        do {
            let responseData = try await Self.execute(type, requestData: requestData,
                                                      backend: backend,
                                                      sessionMessages: sessionMessages)
            return OBSWS.requestResponse(requestType: type, requestId: id,
                                         code: .success, responseData: responseData)
        } catch {
            let mapped = OBSWS.statusIncludingFieldErrors(for: error)
            return OBSWS.requestResponse(requestType: type, requestId: id,
                                         code: mapped.code, comment: mapped.comment)
        }
    }

    static func versionPayload() -> [String: Any] {
        [
            "obsVersion": "30.0.0-prism", // ecosystem tools parse this; advertise OBS 30 compatibility
            "obsWebSocketVersion": OBSWS.serverVersion,
            "rpcVersion": OBSWS.rpcVersion,
            "availableRequests": supportedRequests,
            "supportedImageFormats": [String](),
            "platform": "macos",
            "platformDescription": "PrismStudio on macOS",
        ]
    }

    /// Executes one request against the backend. Pure with respect to the
    /// server (no session/connection state) so the mapping is testable.
    static func execute(_ type: String, requestData: [String: Any], backend: ControlBackend,
                        sessionMessages: (incoming: UInt64, outgoing: UInt64)) async throws -> [String: Any]? {
        switch type {
        case "GetStats":
            let s = await backend.stats()
            return [
                "cpuUsage": s.cpuUsage,
                "memoryUsage": s.memoryUsageMB,
                "availableDiskSpace": s.availableDiskSpaceMB,
                "activeFps": s.activeFps,
                "averageFrameRenderTime": s.averageFrameRenderTimeMs,
                "renderSkippedFrames": s.renderSkippedFrames,
                "renderTotalFrames": s.renderTotalFrames,
                "outputSkippedFrames": s.outputSkippedFrames,
                "outputTotalFrames": s.outputTotalFrames,
                "webSocketSessionIncomingMessages": sessionMessages.incoming,
                "webSocketSessionOutgoingMessages": sessionMessages.outgoing,
            ]
        case "GetSceneList":
            let scenes = await backend.sceneList()
            let current = await backend.currentProgramScene()
            let list: [[String: Any]] = scenes.enumerated().map { index, name in
                ["sceneName": name,
                 "sceneUuid": ControlServer.sceneUuid(name),
                 // obs-websocket indexes from the bottom of the UI list.
                 "sceneIndex": scenes.count - 1 - index]
            }
            return [
                "currentProgramSceneName": current,
                "currentProgramSceneUuid": ControlServer.sceneUuid(current),
                "currentPreviewSceneName": NSNull(),
                "currentPreviewSceneUuid": NSNull(),
                "scenes": list,
            ]
        case "GetCurrentProgramScene":
            let current = await backend.currentProgramScene()
            return [
                "currentProgramSceneName": current,
                "currentProgramSceneUuid": ControlServer.sceneUuid(current),
                // Deprecated-but-still-shipped aliases (protocol.md keeps them in 5.x):
                "sceneName": current,
                "sceneUuid": ControlServer.sceneUuid(current),
            ]
        case "SetCurrentProgramScene":
            guard let name = requestData["sceneName"] as? String else {
                throw RequestFieldError.missing("sceneName")
            }
            try await backend.setCurrentProgramScene(name)
            return nil
        case "StartRecord":
            try await backend.startRecord()
            return nil
        case "StopRecord":
            let path = try await backend.stopRecord()
            return ["outputPath": path ?? NSNull()]
        case "StartStream":
            try await backend.startStream()
            return nil
        case "StopStream":
            try await backend.stopStream()
            return nil
        case "GetRecordStatus":
            let s = await backend.recordStatus()
            return [
                "outputActive": s.active,
                "outputPaused": s.paused,
                "outputTimecode": OBSWS.timecode(seconds: s.durationSeconds),
                "outputDuration": Int((s.durationSeconds * 1000).rounded()),
                "outputBytes": s.bytes,
            ]
        case "GetStreamStatus":
            let s = await backend.streamStatus()
            return [
                "outputActive": s.active,
                "outputReconnecting": s.reconnecting,
                "outputTimecode": OBSWS.timecode(seconds: s.durationSeconds),
                "outputDuration": Int((s.durationSeconds * 1000).rounded()),
                "outputCongestion": s.congestion,
                "outputBytes": s.bytes,
                "outputSkippedFrames": s.skippedFrames,
                "outputTotalFrames": s.totalFrames,
            ]
        default:
            // Caller already filtered by supportedRequests; keep the compiler total.
            throw ControlBackendError.failed("unhandled request type \(type)")
        }
    }

    enum RequestFieldError: Error {
        case missing(String)
    }
}

extension OBSWS {
    /// RequestFieldError → 300 MissingRequestField mapping (kept out of the
    /// generic `status(for:)` so that function stays dependency-free).
    static func statusIncludingFieldErrors(for error: Error) -> (code: RequestStatusCode, comment: String?) {
        if case ControlServer.RequestFieldError.missing(let field) = error {
            return (.missingRequestField, "Your request is missing the field '\(field)'.")
        }
        return status(for: error)
    }
}
