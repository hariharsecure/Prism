import AVFAudio
import AVFoundation
import CoreMedia
import Foundation
import HaishinKit
import PrismCore
import SRTHaishinKit
import VideoToolbox
import os

/// SRT(S) publishing on HaishinKit 2.x (DESIGN §2.5 "SRT output — modern
/// contribution protocol, better on bad networks"). Structural sibling of
/// `RTMPStreamOutput`: same actor shape, same hot-path AsyncStream ingest,
/// same reconnect-with-backoff, same `append(encodedVideo:)` /
/// `append(frame:)` / `append(audio:)` surface.
///
/// ## How this maps onto HaishinKit 2.2.5's SRTHaishinKit (verified against the checkout)
/// SRT is its own product (`SRTHaishinKit`), independent of RTMP. The pair is
/// `SRTConnection` + `SRTStream`, exactly analogous to `RTMPConnection` +
/// `RTMPStream`. Unlike RTMP, the wire is **MPEG-TS**: `SRTStream` owns a
/// `TSWriter` (`SRTHaishinKit/Sources/SRT/SRTStream.swift:22`) whose packetized
/// output is pumped to `SRTConnection.send(_:)` inside `publish`
/// (`SRTStream.swift:86-90`).
///
/// **Ingest path — compressed (our primary path).**
/// `SRTStream.append(_ sampleBuffer:)` (`SRTStream.swift:159`) branches on
/// `formatDescription.isCompressed`:
///  - **compressed** (`== true`): `writer.videoFormat = …; writer.append(…)`
///    (`SRTStream.swift:162-164`) — muxed straight into MPEG-TS with **no
///    re-encode**. This is what `ProgramEncoder` (one explicit VTCompressionSession,
///    DESIGN §3.2 "one encode policy serves stream/record/ISO alike") feeds via
///    `append(encodedVideo:)`. Chosen because the whole point of multi-destination
///    is *encode once, distribute many* — re-encoding per destination is exactly
///    what we avoid.
///  - **raw** (pixel-buffer-backed): `outgoing.append(…)` (`SRTStream.swift:165-166`)
///    → HK's internal `OutgoingStream`/`VideoCodec` hardware encode. Exposed as
///    `append(_ frame:)` for setups that want HK to own the encode.
///
/// **`setExpectedMedias` is mandatory for the compressed path.** `publish()`
/// only inserts `.video`/`.audio` into `TSWriter.expectedMedias` when
/// `outgoing.videoInputFormat`/`audioInputFormat` is already set
/// (`SRTStream.swift:62-70`) — which is *not* the case when we mux compressed
/// buffers straight into the writer (they never touch `outgoing`). So we call
/// `setExpectedMedias([.video, .audio])` (`SRTStream.swift:135`) before
/// `publish`, exactly as the method's own doc comment instructs, or the writer
/// emits nothing.
///
/// **Audio** — `SRTStream.append(_ audioBuffer:when:)` (`SRTStream.swift:174`)
/// takes an `AVAudioPCMBuffer` → `outgoing.append(buffer, when:)`
/// (`SRTStream.swift:176-177`, HK AAC-encodes internally) or an
/// `AVAudioCompressedBuffer` → writer directly. We convert our program-mix PCM
/// `CMSampleBuffer` → `AVAudioPCMBuffer` + `AVAudioTime`. As with RTMP the
/// `AVAudioTime` carries a **hostTime**; our house clock *is* the host clock
/// (`HouseClock`), so PTS→hostTime is exact.
///
/// **URL / streamid / latency** — `SRTConnection.connect(_ uri:)`
/// (`SRTConnection.swift:78`) parses everything from the URL via
/// `SRTSocketURL` (`SRTSocketURL.swift`): the query string becomes
/// `SRTSocketOption`s, so `srt://host:port?streamid=…&latency=…&mode=caller`
/// is honored (`streamid` → `SRTO_STREAMID`, `latency` → recv latency;
/// `SRTSocketOption.Name.swift:98,44`). Default mode with a non-empty host is
/// `caller` (`SRTSocketURL.swift:73-76`).
///
/// **Stats** — SRT exposes libsrt's `CBytePerfMon` via
/// `SRTConnection.performanceData` (`SRTConnection.swift:27`,
/// `SRTPerformanceData.swift`). `byteSentTotal` is the wire byte count and
/// `mbpsSendRate` the instantaneous send rate; we also surface `msRTT`,
/// `pktSndLossTotal`, and `pktRetransTotal` — the numbers that matter on a
/// congested link (the reason SRT exists).
///
/// **Reconnect** — SRT has no RTMP-style status event stream; disconnects
/// surface as `SRTConnection.connected` flipping to `false`
/// (`SRTConnection.swift:25`; `send()` closes the socket on failure,
/// `SRTConnection.swift:151-157`). A watcher task polls `connected` (1 Hz) and,
/// on an unexpected drop, rebuilds a fresh connection+stream pair with
/// exponential backoff — the same shape as RTMP's watcher.
///
/// Appends are `nonisolated` and order-preserving: they land in one
/// `AsyncStream` consumed by a single task, so the hot path never blocks on the
/// actor or the network.
public actor SRTStreamOutput: StreamDestination {
    /// Shared vocabulary (see `StreamConnectionState`).
    public typealias ConnectionState = StreamConnectionState

    public enum OutputError: Error {
        case invalidURL(String)
        case alreadyConnected
        case notConnected
        case connectFailed(underlying: Error)
        case notConnectedAfterHandshake
    }

    /// Encoder parameters for the HK-internal encode path (raw `VideoFrame`
    /// ingest). Harmless when streaming pre-encoded video: only the audio
    /// (AAC bitrate) settings then apply.
    public struct StreamSettings: Sendable {
        public enum Codec: String, Sendable { case h264, hevc }

        public var codec: Codec
        public var width: Int
        public var height: Int
        public var videoBitrate: Int
        public var keyframeInterval: Double
        public var expectedFrameRate: Double
        public var lowLatencyRateControl: Bool
        public var audioBitrate: Int

        /// Advisory hint that the caller *intends* to feed audio. **No longer
        /// gates the mux** — retained for source/ABI compatibility only.
        ///
        /// ## Why it can no longer stall the stream (finding #1 / #5)
        /// SRT muxes to MPEG-TS through HK's `TSWriter`. Its `canWriteFor`
        /// (vendored `SRTHaishinKit/Sources/TS/TSWriter.swift:56-70`) gates
        /// *every* packet write (`TSWriter.append(_:)`, `TSWriter.swift:112-115`).
        /// When `expectedMedias == [.video, .audio]` it demands BOTH
        /// `audioFormat != nil && videoFormat != nil` (`:60-61`) — but on our
        /// compressed path `SRTStream.append` only ever sets `writer.videoFormat`
        /// (`SRTStream.swift:162-164`), so if audio was declared but never flows,
        /// the writer emits **zero TS packets forever — video included** (the
        /// black-stream stall). The old design tied this to a caller flag, so a
        /// stale flag (or audio added only after Go Live, #5) reopened the stall.
        ///
        /// The engine now **never declares `.audio`.** Every publish declares
        /// `[.video]` (`expectedMediasForPublish()`), which makes `canWriteFor`
        /// return `videoFormat != nil` (`:63-64`): the first encoded video buffer
        /// satisfies the gate and **video always transmits, independent of the
        /// audio flag or whether audio ever arrives** — the load-bearing
        /// invariant. Audio, when it genuinely arrives, upgrades the mux
        /// *dynamically and safely*: HK sets `writer.audioFormat` in
        /// `SRTStream.append(_:when:)` (`SRTStream.swift:180`), whose `didSet`
        /// appends the audio ES to the PMT and re-emits the program
        /// (`TSWriter.swift:21-33`, `writeProgramIfNeeded` `:207-215`) — it never
        /// re-gates video. So audio-after-Go-Live (#5) works with no pre-declare.
        public var includeAudio: Bool

        public init(
            codec: Codec = .h264,
            width: Int = 1920,
            height: Int = 1080,
            videoBitrate: Int = 6_000_000,
            keyframeInterval: Double = 2.0,
            expectedFrameRate: Double = 60,
            lowLatencyRateControl: Bool = true,
            audioBitrate: Int = 160_000,
            includeAudio: Bool = false
        ) {
            self.codec = codec
            self.width = width
            self.height = height
            self.videoBitrate = videoBitrate
            self.keyframeInterval = keyframeInterval
            self.expectedFrameRate = expectedFrameRate
            self.lowLatencyRateControl = lowLatencyRateControl
            self.audioBitrate = audioBitrate
            self.includeAudio = includeAudio
        }
    }

    public struct Stats: Sendable {
        public let state: ConnectionState
        /// Outgoing SRT payload bytes since publish (`byteSentTotal`).
        public let bytesOut: Int
        /// Outgoing bytes/sec, derived from `mbpsSendRate`.
        public let bytesOutPerSecond: Int
        public let videoFramesAppended: UInt64
        public let audioBuffersAppended: UInt64
        /// Appends dropped before the network (backpressure or bad input).
        public let appendsDropped: UInt64
        public let reconnects: Int
        /// SRT link RTT (ms), `SRTPerformanceData.msRTT`.
        public let rttMs: Double
        /// Sender-side lost packets total, `pktSndLossTotal`.
        public let packetsSndLoss: Int
        /// Retransmitted packets total, `pktRetransTotal`.
        public let packetsRetransmitted: Int
    }

    private enum IngestItem {
        case video(CMSampleBuffer)
        case audio(AVAudioPCMBuffer, AVAudioTime)
    }

    // MARK: State

    public private(set) var state: ConnectionState = .idle {
        didSet {
            if state != oldValue { stateContinuation?.yield(state) }
        }
    }

    private let settings: StreamSettings
    private let log = EngineLog.logger("output.srt")

    private var connection: SRTConnection?
    private var stream: SRTStream?
    private var srtURL: URL?
    private var generation = 0
    private var intentionalClose = false
    private var reconnectCount = 0
    private var maxReconnectAttempts = 5
    private var consumerTask: Task<Void, Never>?
    private var watcherTask: Task<Void, Never>?
    private var stateContinuation: AsyncStream<ConnectionState>.Continuation?

    // Hot-path (nonisolated) state.
    private let ingest = OSAllocatedUnfairLock<AsyncStream<IngestItem>.Continuation?>(initialState: nil)
    private let counters = OSAllocatedUnfairLock<(video: UInt64, audio: UInt64, dropped: UInt64)>(initialState: (0, 0, 0))
    private let rawFormatCache = OSAllocatedUnfairLock<CMVideoFormatDescription?>(initialState: nil)

    public init(settings: StreamSettings = StreamSettings()) {
        self.settings = settings
    }

    /// Single-consumer stream of connection-state changes (for the stream
    /// health HUD).
    public var stateUpdates: AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            continuation.yield(state)
            stateContinuation = continuation
        }
    }

    public func setMaxReconnectAttempts(_ count: Int) {
        maxReconnectAttempts = max(0, count)
    }

    /// #20: the reconnect-attempt sequence for a disconnect given the configured
    /// maximum. ZERO configured attempts means DO NOT reconnect — the pre-fix
    /// loop `1...max(1, maxReconnectAttempts)` clamped 0 up to 1 and always
    /// retried once, contradicting the "0 = no reconnect" setting. Pure +
    /// `internal` so the contract is unit-testable without a live socket.
    static func reconnectAttempts(max maxAttempts: Int) -> Range<Int> {
        maxAttempts <= 0 ? (0..<0) : (1..<(maxAttempts + 1))
    }

    // MARK: Lifecycle

    /// Connects and publishes. `url` is the SRT endpoint
    /// (`srt://host:port?streamid=…&latency=…&mode=caller`). If `streamID` is
    /// non-empty and the URL has no `streamid` query item, it is appended.
    public func connect(url: String, streamID: String = "") async throws {
        guard state == .idle || state == .closed, connection == nil else {
            throw OutputError.alreadyConnected
        }
        guard let parsed = Self.buildURL(url, streamID: streamID) else {
            throw OutputError.invalidURL(url)
        }
        self.srtURL = parsed
        self.intentionalClose = false
        state = .connecting
        do {
            try await establish()
        } catch {
            state = .failed(reason: String(describing: error))
            if error is OutputError { throw error }
            throw OutputError.connectFailed(underlying: error)
        }
        startConsumerIfNeeded()
    }

    /// The `TSWriter.expectedMedias` set declared for **every** SRT publish:
    /// always `[.video]`, never `[.audio]`. Pure (no I/O) so it is unit-checkable.
    ///
    /// This is the *structural* guarantee that video can never stall on absent
    /// audio (finding #1/#5). `TSWriter.canWriteFor` (vendored TSWriter.swift:56-70)
    /// returns `videoFormat != nil` for a `[.video]` declaration (`:63-64`), so
    /// the first encoded video buffer — which sets `writer.videoFormat`
    /// (SRTStream.swift:163) — makes the gate pass with **no** dependence on
    /// audio. Declaring `.audio` here would instead require `audioFormat != nil`
    /// (`:60-61`) and block ALL packets (video too) until audio a video-only
    /// source never produces. Audio still works when it arrives: it upgrades the
    /// PMT dynamically via `writer.audioFormat`'s didSet (TSWriter.swift:21-33),
    /// no `.audio` declaration required.
    static func expectedMediasForPublish() -> Set<AVMediaType> {
        [.video]
    }

    /// Normalizes/validates the SRT URL and folds in an explicit `streamID`.
    static func buildURL(_ url: String, streamID: String) -> URL? {
        guard var comps = URLComponents(string: url),
              comps.scheme?.lowercased() == "srt",
              comps.host != nil else {
            return nil
        }
        if !streamID.isEmpty {
            var items = comps.queryItems ?? []
            if !items.contains(where: { $0.name == "streamid" }) {
                items.append(URLQueryItem(name: "streamid", value: streamID))
                comps.queryItems = items
            }
        }
        return comps.url
    }

    /// Builds a fresh connection+stream pair and publishes. SRT keeps per-publish
    /// socket/TS state, so a clean pair per attempt is the safe reconnect shape
    /// (mirrors RTMP).
    private func establish() async throws {
        guard let srtURL else { throw OutputError.notConnected }

        let connection = SRTConnection()
        let stream = SRTStream(connection: connection)

        var videoSettings = VideoCodecSettings(
            videoSize: CGSize(width: settings.width, height: settings.height),
            bitRate: settings.videoBitrate,
            profileLevel: settings.codec == .hevc
                ? kVTProfileLevel_HEVC_Main_AutoLevel as String
                : kVTProfileLevel_H264_High_AutoLevel as String,
            maxKeyFrameIntervalDuration: Int32(settings.keyframeInterval.rounded()),
            allowFrameReordering: false,
            isLowLatencyRateControlEnabled: settings.lowLatencyRateControl
        )
        videoSettings.expectedFrameRate = settings.expectedFrameRate
        try await stream.setVideoSettings(videoSettings)
        try await stream.setAudioSettings(AudioCodecSettings(bitRate: settings.audioBitrate))

        try await connection.connect(srtURL)
        guard await connection.connected else {
            await connection.close()
            throw OutputError.notConnectedAfterHandshake
        }
        // Compressed buffers are muxed straight into the TSWriter, bypassing
        // `outgoing`, so publish() cannot infer the media set — declare it. We
        // ALWAYS declare `[.video]` (never `.audio`): `TSWriter.canWriteFor`
        // (TSWriter.swift:56-70) then admits every packet as soon as
        // `videoFormat` is set on the first encoded frame (SRTStream.swift:163,
        // TSWriter.swift:63-64) — so video is structurally never gated on audio
        // (finding #1/#5). Audio, if it later arrives via `append(audio:)`,
        // upgrades the mux dynamically (HK sets `writer.audioFormat`,
        // SRTStream.swift:180 → PMT re-emit, TSWriter.swift:21-33).
        await stream.setExpectedMedias(Self.expectedMediasForPublish())
        await stream.publish("")

        self.connection = connection
        self.stream = stream
        generation += 1
        state = .publishing
        log.info("publishing to \(srtURL.host ?? "?", privacy: .public)")
        watchConnection(connection, generation: generation)
    }

    /// SRT has no status event stream; poll `connected` (1 Hz) and reconnect on
    /// an unexpected drop.
    private func watchConnection(_ connection: SRTConnection, generation: Int) {
        watcherTask?.cancel()
        watcherTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if Task.isCancelled { return }
                let up = await connection.connected
                if !up {
                    await self.handleDisconnect(generation: generation)
                    return
                }
            }
        }
    }

    private func handleDisconnect(generation: Int) async {
        guard generation == self.generation, !intentionalClose, state == .publishing else { return }
        log.warning("connection lost; reconnecting")
        if let stream { await stream.close() }
        if let connection { await connection.close() }
        // C3: `close()` may have interleaved during the awaits above (it sets
        // `intentionalClose` and `state = .closed`). Re-check before touching
        // state — otherwise we'd overwrite `.closed` with `.reconnecting` and the
        // watcher, already cancelled by close(), would leave us stuck reconnecting
        // forever (a later `connect()` then throws `.alreadyConnected`). RTMP
        // sidesteps this by nil-ing synchronously with no await between the guard
        // and the loop (RTMPStreamOutput.swift:256-257).
        guard !intentionalClose, state == .publishing else { return }
        connection = nil
        stream = nil
        let attempts = Self.reconnectAttempts(max: maxReconnectAttempts)
        for attempt in attempts {
            state = .reconnecting(attempt: attempt)
            // Exponential backoff, capped at 30 s.
            let delay = min(30.0, pow(2.0, Double(attempt - 1)))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if intentionalClose { return }
            do {
                try await establish()
                reconnectCount += 1
                log.info("reconnected after \(attempt) attempt(s)")
                return
            } catch {
                log.warning("reconnect attempt \(attempt) failed: \(String(describing: error), privacy: .public)")
            }
        }
        // #20: with 0 configured attempts `attempts` is empty — the loop never
        // runs and we drop straight to a terminal state with NO reconnect.
        state = .failed(reason: attempts.isEmpty
                        ? "connection lost (reconnect disabled)"
                        : "reconnect attempts exhausted")
    }

    /// Unpublishes and closes. The instance can `connect` again afterwards.
    public func close() async {
        intentionalClose = true
        watcherTask?.cancel()
        watcherTask = nil
        consumerTask?.cancel()
        consumerTask = nil
        ingest.withLock { continuation in
            continuation?.finish()
            continuation = nil
        }
        if let stream { await stream.close() }
        if let connection { await connection.close() }
        stream = nil
        connection = nil
        state = .closed
    }

    /// `StreamDestination` teardown.
    public func teardown() async {
        await close()
    }

    // MARK: Ingest (hot path — nonisolated, order-preserving)

    private func startConsumerIfNeeded() {
        guard consumerTask == nil else { return }
        let (itemStream, continuation) = AsyncStream.makeStream(
            of: IngestItem.self,
            bufferingPolicy: .bufferingNewest(240) // ~2 s of 60 fps video + audio; drop-oldest under stall
        )
        ingest.withLock { $0 = continuation }
        consumerTask = Task { [weak self] in
            for await item in itemStream {
                guard let self else { return }
                await self.deliver(item)
            }
        }
    }

    private func deliver(_ item: IngestItem) async {
        guard state == .publishing, let stream else {
            counters.withLock { $0.dropped &+= 1 }
            return
        }
        switch item {
        case .video(let sampleBuffer):
            await stream.append(sampleBuffer)
        case .audio(let buffer, let when):
            await stream.append(buffer, when: when)
        }
    }

    private nonisolated func enqueue(_ item: IngestItem) {
        let result = ingest.withLock { $0?.yield(item) }
        switch result {
        case .enqueued?:
            switch item {
            case .video: counters.withLock { $0.video &+= 1 }
            case .audio: counters.withLock { $0.audio &+= 1 }
            }
        default:
            counters.withLock { $0.dropped &+= 1 }
        }
    }

    /// Preferred path: already-encoded program video from `ProgramEncoder`
    /// (H.264/HEVC `CMSampleBuffer`s). HK muxes these into MPEG-TS without
    /// re-encoding (`SRTStream.swift:162`).
    public nonisolated func append(encodedVideo sampleBuffer: CMSampleBuffer) {
        enqueue(.video(sampleBuffer))
    }

    /// Alternative path: raw composited frames; HK's internal hardware encoder
    /// (configured from `StreamSettings`) does the encode. Don't mix with
    /// `append(encodedVideo:)` on one session.
    public nonisolated func append(_ frame: VideoFrame) {
        guard let sampleBuffer = makeSampleBuffer(frame) else {
            counters.withLock { $0.dropped &+= 1 }
            return
        }
        enqueue(.video(sampleBuffer))
    }

    /// Program-mix audio (PCM `CMSampleBuffer`, house PTS). Converted to
    /// `AVAudioPCMBuffer` + hostTime because `SRTStream` AAC-encodes PCM
    /// internally via `outgoing` (`SRTStream.swift:176`).
    public nonisolated func append(audio sampleBuffer: CMSampleBuffer) {
        // Forwarded unconditionally (independent of `settings.includeAudio`).
        // Safe by construction: the publish declared `[.video]` only
        // (`expectedMediasForPublish`), so video already transmits and this audio
        // can only *add* a stream — HK sets `writer.audioFormat`
        // (SRTStream.swift:180), whose didSet appends the audio ES to the PMT and
        // re-emits the program (TSWriter.swift:21-33). It can never stall video.
        // If no audio surface is wired this method simply is never called (no
        // cost); if audio is added only after Go Live (#5) it now flows.
        guard let (buffer, when) = Self.makePCMBuffer(audio: sampleBuffer) else {
            counters.withLock { $0.dropped &+= 1 }
            return
        }
        enqueue(.audio(buffer, when))
    }

    // MARK: Stats

    public func stats() async -> Stats {
        let perf: SRTPerformanceData? = await connection?.performanceData
        let (video, audio, dropped) = counters.withLock { $0 }
        // mbpsSendRate is megabits/sec → bytes/sec = *1e6/8 = *125_000.
        let bps = Int((perf?.mbpsSendRate ?? 0) * 125_000)
        return Stats(
            state: state,
            bytesOut: Int(perf?.byteSentTotal ?? 0),
            bytesOutPerSecond: bps,
            videoFramesAppended: video,
            audioBuffersAppended: audio,
            appendsDropped: dropped,
            reconnects: reconnectCount,
            rttMs: perf?.msRTT ?? 0,
            packetsSndLoss: Int(perf?.pktSndLossTotal ?? 0),
            packetsRetransmitted: Int(perf?.pktRetransTotal ?? 0)
        )
    }

    /// `StreamDestination` transport-agnostic stats.
    public func destinationStats() async -> StreamDestinationStats {
        let s = await stats()
        return StreamDestinationStats(
            state: s.state,
            bytesOut: s.bytesOut,
            bytesOutPerSecond: s.bytesOutPerSecond,
            videoFramesAppended: s.videoFramesAppended,
            audioBuffersAppended: s.audioBuffersAppended,
            appendsDropped: s.appendsDropped,
            reconnects: s.reconnects
        )
    }

    // MARK: Buffer plumbing

    /// Wraps a `VideoFrame` in a CMSampleBuffer (no pixel copies; the format
    /// description is cached across frames of identical dimensions).
    private nonisolated func makeSampleBuffer(_ frame: VideoFrame) -> CMSampleBuffer? {
        let formatDescription: CMVideoFormatDescription? = rawFormatCache.withLock { cached in
            if let cached, CMVideoFormatDescriptionMatchesImageBuffer(cached, imageBuffer: frame.pixelBuffer) {
                return cached
            }
            var created: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: nil,
                imageBuffer: frame.pixelBuffer,
                formatDescriptionOut: &created
            )
            guard status == noErr else { return nil }
            cached = created
            return created
        }
        guard let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: frame.duration,
            presentationTimeStamp: frame.pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil,
            imageBuffer: frame.pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        return sampleBuffer
    }

    /// PCM CMSampleBuffer → (AVAudioPCMBuffer, AVAudioTime-with-hostTime).
    /// House PTS *is* host-clock time, and HK's SRT audio path timestamps from
    /// `AVAudioTime` — so the conversion is lossless for sync.
    private static func makePCMBuffer(audio sampleBuffer: CMSampleBuffer) -> (AVAudioPCMBuffer, AVAudioTime)? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM else {
            return nil
        }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let when = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: pts.seconds))
        return (pcm, when)
    }
}
