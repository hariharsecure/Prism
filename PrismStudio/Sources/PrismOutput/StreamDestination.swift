import CoreMedia
import Foundation

/// Common connection-state vocabulary shared by every live streaming output
/// (`RTMPStreamOutput`, `SRTStreamOutput`) and the fan-out broadcaster.
///
/// `SRTStreamOutput` uses this type as its own `ConnectionState`;
/// `RTMPStreamOutput` (unchanged) keeps its private nested enum and is mapped
/// onto this in the additive conformance below.
public enum StreamConnectionState: Sendable, Equatable {
    case idle
    case connecting
    case publishing
    case reconnecting(attempt: Int)
    case closed
    case failed(reason: String)

    /// True only while frames are actually going out.
    public var isLive: Bool { self == .publishing }
}

/// Protocol-level, wire-agnostic per-destination statistics. Every concrete
/// output maps its transport-specific counters (RTMP `RTMPStreamInfo.byteCount`,
/// SRT `SRTPerformanceData.byteSentTotal`) onto this common shape so the
/// broadcaster and health HUD can report N destinations uniformly.
public struct StreamDestinationStats: Sendable {
    public let state: StreamConnectionState
    /// Bytes written to the wire since publish.
    public let bytesOut: Int
    /// Instantaneous outgoing rate (bytes/sec) when the transport reports it.
    public let bytesOutPerSecond: Int
    public let videoFramesAppended: UInt64
    public let audioBuffersAppended: UInt64
    /// Appends dropped before the network (backpressure / bad input / down).
    public let appendsDropped: UInt64
    public let reconnects: Int

    public init(
        state: StreamConnectionState,
        bytesOut: Int,
        bytesOutPerSecond: Int,
        videoFramesAppended: UInt64,
        audioBuffersAppended: UInt64,
        appendsDropped: UInt64,
        reconnects: Int
    ) {
        self.state = state
        self.bytesOut = bytesOut
        self.bytesOutPerSecond = bytesOutPerSecond
        self.videoFramesAppended = videoFramesAppended
        self.audioBuffersAppended = audioBuffersAppended
        self.appendsDropped = appendsDropped
        self.reconnects = reconnects
    }
}

/// The substitutable seam that lets `MultiDestinationBroadcaster` fan one
/// encoded program stream to *any* live output — RTMP, SRT, or an in-process
/// test double — without knowing the transport.
///
/// The two `append` entries are `nonisolated` and non-throwing by contract:
/// each concrete output enqueues into its own bounded `AsyncStream` and returns
/// immediately (fire-and-forget). That is what guarantees fan-out independence
/// — a stalled or failed destination absorbs/drops on *its own* queue and can
/// neither block nor throw into the broadcaster's per-frame loop.
public protocol StreamDestination: Actor {
    /// Already-encoded program video (H.264/HEVC `CMSampleBuffer`, house PTS).
    nonisolated func append(encodedVideo sampleBuffer: CMSampleBuffer)
    /// Program-mix audio (PCM `CMSampleBuffer`, house PTS).
    nonisolated func append(audio sampleBuffer: CMSampleBuffer)
    /// Transport-agnostic stats snapshot.
    func destinationStats() async -> StreamDestinationStats
    /// Unpublishes and closes the underlying connection.
    func teardown() async
}

/// A restream target. The broadcaster builds the matching concrete output from
/// this description (DESIGN §2.5 "Multi-destination simultaneous streaming").
public struct Destination: Sendable, Identifiable, Equatable {
    public enum Proto: String, Sendable, Equatable {
        case rtmp
        case srt
    }

    public let id: UUID
    public var name: String
    public var proto: Proto
    /// Ingest endpoint. RTMP(S): `rtmp(s)://host/app`. SRT: `srt://host:port?…`.
    public var url: String
    /// RTMP stream key, or SRT `streamid`. Empty when carried in the URL query.
    public var key: String
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        proto: Proto,
        url: String,
        key: String = "",
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.proto = proto
        self.url = url
        self.key = key
        self.enabled = enabled
    }

    /// #9: whether this destination can actually publish — it must be ENABLED and
    /// carry a non-empty ingest URL. The "Add" button creates an enabled BLANK
    /// destination (empty URL/key); such a target must NOT count toward
    /// `canGoLive` nor be attempted at start, or a destinations-only broadcast
    /// would report "live" with nothing publishing.
    public var isPublishable: Bool {
        enabled && !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Additive conformance for the (unchanged) RTMP output

extension RTMPStreamOutput: StreamDestination {
    /// Maps RTMP's private nested state onto the shared vocabulary.
    private static func shared(_ s: RTMPStreamOutput.ConnectionState) -> StreamConnectionState {
        switch s {
        case .idle: return .idle
        case .connecting: return .connecting
        case .publishing: return .publishing
        case .reconnecting(let a): return .reconnecting(attempt: a)
        case .closed: return .closed
        case .failed(let r): return .failed(reason: r)
        }
    }

    public func destinationStats() async -> StreamDestinationStats {
        let s = await stats()
        return StreamDestinationStats(
            state: Self.shared(s.state),
            bytesOut: s.bytesOut,
            bytesOutPerSecond: s.bytesOutPerSecond,
            videoFramesAppended: s.videoFramesAppended,
            audioBuffersAppended: s.audioBuffersAppended,
            appendsDropped: s.appendsDropped,
            reconnects: s.reconnects
        )
    }

    public func teardown() async {
        await close()
    }
}
