import Foundation

/// One media frame (or audio packet) reassembled from its datagram parts.
public struct ReassembledFrame: Sendable {
    public let frameID: UInt32
    public let ptsHouseNanos: Int64
    public let isKeyframe: Bool
    public let isAudio: Bool
    /// Video: whole-frame HEVC Annex-B data. Audio: one AAC-ELD packet.
    public let payload: Data
}

/// Receive-side counters (monotonic since connect).
public struct ReassemblyStats: Sendable {
    public var partsReceived: UInt64 = 0
    public var duplicateParts: UInt64 = 0
    public var bytesReceived: UInt64 = 0
    public var framesCompleted: UInt64 = 0
    /// Frames abandoned: timed out incomplete, evicted by newer frames, or
    /// arrived with inconsistent part fields.
    public var framesDropped: UInt64 = 0
    /// Highest sequence number seen minus datagrams received — a cheap
    /// (reordering-insensitive over time) loss signal for bitrate feedback.
    public var estimatedDatagramsLost: UInt64 = 0
    /// Parts rejected for inconsistent metadata (payload length ≠ header's
    /// declared length, or a part index outside the frame's declared shape).
    public var partsInvalid: UInt64 = 0
    public init() {}
}

/// Reassembles media datagrams (frameID + partIndex/partCount) into frames.
///
/// Pure with respect to time — the caller injects `now` (any monotonic
/// seconds source) so the logic is deterministic and unit-exercisable.
/// Incomplete frames are dropped after `timeout` seconds or when more than
/// `maxPending` frames are in flight (oldest first — a lost part must never
/// stall newer frames; DESIGN §3.4's loss policy handles the gap upstream
/// via keyframe requests, surfaced here through `onKeyframeNeeded`).
///
/// ## Emission order
/// Frames are emitted in **frameID order** (the sender's single monotonically
/// increasing sequence across video + audio), not completion order: a frame
/// whose last part is reordered on the wire must not be decoded after its
/// successors. Completed-but-early frames wait in a bounded reorder buffer;
/// a head-of-line gap is skipped once the oldest waiting frame has waited out
/// `reorderTimeout` (the missing frame is unrecoverable at that point — a
/// keyframe request is signaled). `ingest` returns at most one frame per
/// call, so a burst released together drains across the next few datagrams
/// (wire rate ≫ frame rate, sub-frame extra latency).
public final class FrameReassembler {
    private struct Pending {
        var parts: [Data?]
        var received: Int = 0
        var bytes: Int = 0
        var ptsHouseNanos: Int64
        var flags: MediaDatagramHeader.Flags
        var firstSeen: TimeInterval
    }

    private struct Ready {
        let frame: ReassembledFrame
        let readyAt: TimeInterval
    }

    private var pending: [UInt32: Pending] = [:]
    /// Completed frames waiting for their predecessors (reorder buffer).
    private var ready: [UInt32: Ready] = [:]
    /// In-order frames awaiting return to the caller (one per `ingest`).
    private var emitQueue: [ReassembledFrame] = []
    /// The next frameID to emit. Frames wrap-aware "behind" this are already
    /// emitted or skipped — their late/duplicate parts are ignored, which is
    /// also what stops a completed frame from being rebuilt and re-emitted.
    private var nextExpected: UInt32?
    private var seenSeqMax: UInt32?
    private var datagramCount: UInt64 = 0
    public private(set) var stats = ReassemblyStats()

    /// Fired when a frame is abandoned (timeout, eviction, corruption) or a
    /// head-of-line gap is skipped — the decoder can't proceed past the gap
    /// without an IDR, so the link layer should forward this as a keyframe
    /// request (LinkPeer.requestKeyframe(), which rate-limits). Called
    /// synchronously from `ingest`/`expire` on their caller's queue.
    public var onKeyframeNeeded: (() -> Void)?

    public let timeout: TimeInterval
    public let maxPending: Int
    /// How long a completed frame may wait for a missing predecessor before
    /// the gap is skipped.
    public let reorderTimeout: TimeInterval
    /// Reorder-buffer bound; overflowing forces the oldest gap to be skipped.
    private let maxReady = 16

    public init(timeout: TimeInterval = 0.25, maxPending: Int = 8,
                reorderTimeout: TimeInterval = 0.1) {
        self.timeout = timeout
        self.maxPending = maxPending
        self.reorderTimeout = reorderTimeout
    }

    /// Ingest one datagram. Returns the next frame in frameID order when one
    /// is deliverable, else nil. Also expires stale frames as a side sweep.
    public func ingest(header: MediaDatagramHeader, payload: Data,
                       at now: TimeInterval) -> ReassembledFrame? {
        stats.partsReceived += 1
        stats.bytesReceived += UInt64(payload.count)
        trackLoss(seq: header.seq)
        expire(at: now)
        processPart(header: header, payload: payload, at: now)
        releaseStaleReady(at: now)
        return emitQueue.isEmpty ? nil : emitQueue.removeFirst()
    }

    private func processPart(header: MediaDatagramHeader, payload: Data, at now: TimeInterval) {
        // Part metadata must be self-consistent before it touches state.
        guard Int(header.payloadLength) == payload.count else {
            stats.partsInvalid += 1
            return
        }
        let frameID = header.frameID
        // Anchor the emission sequence at the first frame seen on the wire.
        if nextExpected == nil { nextExpected = frameID }

        if isBehindNextExpected(frameID) || ready[frameID] != nil {
            // Already emitted, skipped, or completed-and-waiting: a re-sent
            // datagram must not rebuild the frame and emit it twice.
            stats.duplicateParts += 1
            return
        }

        var entry = pending[frameID] ?? Pending(parts: Array(repeating: nil, count: Int(header.partCount)),
                                                ptsHouseNanos: header.ptsHouseNanos,
                                                flags: header.flags,
                                                firstSeen: now)
        // A part disagreeing about the frame's shape or timing means
        // corruption or a frameID collision after wrap — abandon the frame,
        // wait for the next (and ask for a recovery point).
        guard entry.parts.count == Int(header.partCount),
              entry.ptsHouseNanos == header.ptsHouseNanos,
              entry.flags == header.flags else {
            pending.removeValue(forKey: frameID)
            stats.framesDropped += 1
            onKeyframeNeeded?()
            return
        }
        let index = Int(header.partIndex)
        guard index < entry.parts.count else { // headers built without parse()'s guard
            stats.partsInvalid += 1
            return
        }
        guard entry.parts[index] == nil else {
            stats.duplicateParts += 1
            pending[frameID] = entry
            return
        }
        entry.parts[index] = payload
        entry.received += 1
        entry.bytes += payload.count

        if entry.received == entry.parts.count {
            pending.removeValue(forKey: frameID)
            stats.framesCompleted += 1
            var whole = Data(capacity: entry.bytes)
            for part in entry.parts { whole.append(part!) }
            ready[frameID] = Ready(frame: ReassembledFrame(frameID: frameID,
                                                           ptsHouseNanos: entry.ptsHouseNanos,
                                                           isKeyframe: entry.flags.contains(.keyframe),
                                                           isAudio: entry.flags.contains(.audio),
                                                           payload: whole),
                                   readyAt: now)
            promoteReady()
            boundReady()
        } else {
            pending[frameID] = entry
            evictIfOverfull(keeping: frameID)
        }
    }

    /// Wrap-aware (RFC 1982 style): is `frameID` before `nextExpected`?
    private func isBehindNextExpected(_ frameID: UInt32) -> Bool {
        guard let next = nextExpected else { return false }
        let ahead = frameID &- next
        return ahead >= 0x8000_0000
    }

    /// Move every consecutively-ready frame into the emit queue.
    private func promoteReady() {
        while let next = nextExpected, let released = ready.removeValue(forKey: next) {
            emitQueue.append(released.frame)
            nextExpected = next &+ 1
        }
    }

    /// The completed frame closest to `nextExpected` (wrap-aware distance).
    private func oldestReadyID() -> UInt32? {
        guard let next = nextExpected else { return ready.keys.min() }
        return ready.keys.min { ($0 &- next) < ($1 &- next) }
    }

    /// Skip a head-of-line gap once the frame(s) waiting behind it have
    /// out-waited the reorder window — the missing frame is not coming.
    private func releaseStaleReady(at now: TimeInterval) {
        guard let next = nextExpected, ready[next] == nil,
              let oldest = oldestReadyID(), let waiting = ready[oldest],
              now - waiting.readyAt > reorderTimeout else { return }
        nextExpected = oldest
        promoteReady()
        onKeyframeNeeded?()
    }

    /// Reorder-buffer bound: on overflow, force the oldest gap skip so the
    /// buffer can drain (never drop the completed frames themselves).
    private func boundReady() {
        while ready.count > maxReady, let oldest = oldestReadyID() {
            nextExpected = oldest
            promoteReady()
            onKeyframeNeeded?()
        }
    }

    /// Drops incomplete frames older than `timeout`. Called from `ingest`, and
    /// callable from a periodic sweep so a silent line still expires state.
    /// Returns the number of frames dropped by this call.
    @discardableResult
    public func expire(at now: TimeInterval) -> Int {
        let stale = pending.filter { now - $0.value.firstSeen > timeout }.map(\.key)
        for key in stale { pending.removeValue(forKey: key) }
        stats.framesDropped += UInt64(stale.count)
        if !stale.isEmpty { onKeyframeNeeded?() }
        return stale.count
    }

    /// Number of frames currently awaiting parts.
    public var pendingFrameCount: Int { pending.count }

    private func evictIfOverfull(keeping newest: UInt32) {
        var evicted = false
        while pending.count > maxPending {
            // Oldest by arrival time; never evict the frame we just touched.
            guard let victim = pending.filter({ $0.key != newest })
                .min(by: { $0.value.firstSeen < $1.value.firstSeen })?.key else { break }
            pending.removeValue(forKey: victim)
            stats.framesDropped += 1
            evicted = true
        }
        if evicted { onKeyframeNeeded?() }
    }

    private func trackLoss(seq: UInt32) {
        datagramCount += 1
        if let previousMax = seenSeqMax {
            // Wrap-aware "is newer" comparison (RFC 1982 style).
            let ahead = seq &- previousMax
            if ahead != 0 && ahead < 0x8000_0000 {
                seenSeqMax = seq
            }
        } else {
            seenSeqMax = seq
        }
        if let maxSeq = seenSeqMax {
            // Expected = highest seq + 1 (assuming the stream started near 0 on
            // connect); clamp at 0 so reordering never yields negative loss.
            let expected = UInt64(maxSeq) + 1
            stats.estimatedDatagramsLost = expected > datagramCount ? expected - datagramCount : 0
        }
    }
}
