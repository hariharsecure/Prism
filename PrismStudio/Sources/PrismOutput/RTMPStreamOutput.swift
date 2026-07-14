import AVFAudio
import AVFoundation
import CoreMedia
import Foundation
import HaishinKit
import PrismCore
import RTMPHaishinKit
import VideoToolbox
import os

/// RTMP(S) publishing on HaishinKit 2.x (DESIGN §2.5 "RTMP(S) streaming").
///
/// ## How this maps onto HaishinKit 2.2.5 (verified against the checkout)
/// HK 2.x split RTMP out of the core product: `RTMPConnection`/`RTMPStream`
/// live in the `RTMPHaishinKit` module (`RTMPHaishinKit/Sources/RTMP/`), while
/// the core `HaishinKit` module holds the codec settings and stream protocols.
///
/// **Ingest path** — `RTMPStream.append(_ sampleBuffer:)`
/// (`RTMPHaishinKit/Sources/RTMP/RTMPStream.swift:726`) accepts *both*:
///  - **compressed video** (`formatDescription.isCompressed == true`): muxed
///    straight into an `RTMPVideoMessage` with no re-encode (`:728–741`).
///    This is our primary path: `ProgramEncoder` (explicit VTCompressionSession,
///    DESIGN §3.2 "one encode policy serves stream/record/ISO alike") feeds its
///    output here via `append(encodedVideo:)`.
///  - **raw video** (pixel-buffer-backed): forwarded to HK's internal
///    `OutgoingStream`/`VideoCodec` hardware encode (`:742`). Exposed as
///    `append(_ frame:)` for setups that want HK to own the encode (its
///    `StreamBitRateStrategy` can then adapt bitrate itself).
///
/// **Audio** — `RTMPStream.append(_ sampleBuffer:)`'s switch only handles
/// `.video`; audio `CMSampleBuffer`s are silently ignored (`:726–764`). Audio
/// must enter through `append(_ audioBuffer:when:)` (`:766`): PCM buffers are
/// AAC-encoded internally. So `append(audio:)` converts our program-mix
/// `CMSampleBuffer` → `AVAudioPCMBuffer` + `AVAudioTime`. The `AVAudioTime`
/// **must carry a hostTime**: HK's `RTMPTimestamp` reads
/// `AVAudioTime.seconds(forHostTime:)` (`RTMPTimestamp.swift:61–65`). Our house
/// clock *is* the host clock (`HouseClock`), so PTS→hostTime is exact.
///
/// **Why not `MediaMixer`** — HK's `MediaMixer` exists to attach capture
/// devices and mix them; our program frames are already composited upstream,
/// so we append directly to the stream (the same entry `MediaMixer` itself
/// uses via `MediaMixerOutput`). HK never touches our capture graph.
///
/// **Stats** — `RTMPStream.info.byteCount` accumulates outgoing RTMP payload
/// bytes (`RTMPStream.swift:551`, incremented with each chunk written by
/// `connection.doOutput`). HK's `NetworkMonitor` is `package`-scoped
/// (`HaishinKit/Sources/Network/NetworkMonitor.swift:4`) and not reachable
/// from clients, so `byteCount`/`currentBytesPerSecond` are the supported
/// wire-level numbers.
///
/// **Reconnect** — disconnects surface on `RTMPConnection.status` as
/// `RTMPConnection.Code.connectClosed` (the same signal HK's own
/// `RTMPSession.swift` watches). On unexpected close, a fresh
/// connection+stream pair is built and re-published with exponential backoff.
///
/// Appends are `nonisolated` and order-preserving: they land in one
/// `AsyncStream` consumed by a single task, so the hot path never blocks on
/// the actor or the network.
public actor RTMPStreamOutput {
    public enum ConnectionState: Sendable, Equatable {
        case idle
        case connecting
        case publishing
        case reconnecting(attempt: Int)
        case closed
        case failed(reason: String)
    }

    public enum OutputError: Error {
        case invalidURL(String)
        case alreadyConnected
        case notConnected
        case connectFailed(underlying: Error)
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

        public init(
            codec: Codec = .h264,
            width: Int = 1920,
            height: Int = 1080,
            videoBitrate: Int = 6_000_000,
            keyframeInterval: Double = 2.0,
            expectedFrameRate: Double = 60,
            lowLatencyRateControl: Bool = true,
            audioBitrate: Int = 160_000
        ) {
            self.codec = codec
            self.width = width
            self.height = height
            self.videoBitrate = videoBitrate
            self.keyframeInterval = keyframeInterval
            self.expectedFrameRate = expectedFrameRate
            self.lowLatencyRateControl = lowLatencyRateControl
            self.audioBitrate = audioBitrate
        }
    }

    public struct Stats: Sendable {
        public let state: ConnectionState
        /// Outgoing RTMP payload bytes since publish (RTMPStreamInfo.byteCount).
        public let bytesOut: Int
        /// Outgoing bytes/sec (updated by HK's monitor dispatch cycle).
        public let bytesOutPerSecond: Int
        public let videoFramesAppended: UInt64
        public let audioBuffersAppended: UInt64
        /// Appends dropped before the network (backpressure or bad input).
        public let appendsDropped: UInt64
        public let reconnects: Int
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
    private let log = EngineLog.logger("output.rtmp")

    private var connection: RTMPConnection?
    private var stream: RTMPStream?
    private var appURL: URL?
    private var streamKey: String?
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

    // MARK: Lifecycle

    /// Connects and publishes. `url` is the ingest endpoint
    /// (e.g. `rtmp://a.rtmp.youtube.com/live2` or `rtmps://…:443/app`),
    /// `streamKey` the platform stream key.
    public func connect(url: String, streamKey: String) async throws {
        guard state == .idle || state == .closed, connection == nil else {
            throw OutputError.alreadyConnected
        }
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "rtmp" || scheme == "rtmps",
              parsed.host != nil else {
            throw OutputError.invalidURL(url)
        }
        self.appURL = parsed
        self.streamKey = streamKey
        self.intentionalClose = false
        state = .connecting
        do {
            try await establish()
        } catch {
            state = .failed(reason: String(describing: error))
            throw OutputError.connectFailed(underlying: error)
        }
        startConsumerIfNeeded()
    }

    /// Builds a fresh connection+stream pair and publishes. HK's RTMPStream
    /// keeps per-publish timestamp state, so reusing instances across
    /// reconnects is fragile — a clean pair per attempt matches what HK's own
    /// RTMPSession does on mode switches.
    private func establish() async throws {
        guard let appURL, let streamKey else { throw OutputError.notConnected }

        let connection = RTMPConnection()
        let stream = RTMPStream(connection: connection)

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

        _ = try await connection.connect(appURL.absoluteString)
        _ = try await stream.publish(streamKey)

        self.connection = connection
        self.stream = stream
        generation += 1
        state = .publishing
        log.info("publishing to \(appURL.host ?? "?", privacy: .public)")
        watchConnection(connection, generation: generation)
    }

    /// Watches for server-side/transport disconnects (the signal HK's own
    /// RTMPSession uses) and kicks off reconnection.
    private func watchConnection(_ connection: RTMPConnection, generation: Int) {
        watcherTask?.cancel()
        watcherTask = Task { [weak self] in
            for await status in await connection.status {
                if Task.isCancelled { return }
                if status.code == RTMPConnection.Code.connectClosed.rawValue {
                    await self?.handleDisconnect(generation: generation)
                    return
                }
            }
        }
    }

    private func handleDisconnect(generation: Int) async {
        guard generation == self.generation, !intentionalClose, state == .publishing else { return }
        log.warning("connection lost; reconnecting")
        connection = nil
        stream = nil
        for attempt in 1...max(1, maxReconnectAttempts) {
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
        state = .failed(reason: "reconnect attempts exhausted")
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
        if let stream { _ = try? await stream.close() }
        if let connection { try? await connection.close() }
        stream = nil
        connection = nil
        state = .closed
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
    /// (H.264/HEVC `CMSampleBuffer`s). HK muxes these into RTMP messages
    /// without re-encoding (RTMPStream.swift:728).
    public nonisolated func append(encodedVideo sampleBuffer: CMSampleBuffer) {
        enqueue(.video(sampleBuffer))
    }

    /// Alternative path: raw composited frames; HK's internal hardware
    /// encoder (configured from `StreamSettings`) does the encode.
    /// Don't mix with `append(encodedVideo:)` on one session.
    public nonisolated func append(_ frame: VideoFrame) {
        guard let sampleBuffer = makeSampleBuffer(frame) else {
            counters.withLock { $0.dropped &+= 1 }
            return
        }
        enqueue(.video(sampleBuffer))
    }

    /// Program-mix audio (PCM `CMSampleBuffer`, house PTS). Converted to
    /// `AVAudioPCMBuffer` because RTMPStream ignores audio CMSampleBuffers
    /// (see type comment); HK AAC-encodes internally.
    public nonisolated func append(audio sampleBuffer: CMSampleBuffer) {
        guard let (buffer, when) = Self.makePCMBuffer(audio: sampleBuffer) else {
            counters.withLock { $0.dropped &+= 1 }
            return
        }
        enqueue(.audio(buffer, when))
    }

    // MARK: Stats

    public func stats() async -> Stats {
        let info: RTMPStreamInfo? = await stream?.info
        let (video, audio, dropped) = counters.withLock { $0 }
        return Stats(
            state: state,
            bytesOut: info?.byteCount ?? 0,
            bytesOutPerSecond: info?.currentBytesPerSecond ?? 0,
            videoFramesAppended: video,
            audioBuffersAppended: audio,
            appendsDropped: dropped,
            reconnects: reconnectCount
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
    /// House PTS *is* host-clock time, and HK's RTMP timestamping reads
    /// `AVAudioTime.hostTime` — so the conversion is lossless for sync.
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
