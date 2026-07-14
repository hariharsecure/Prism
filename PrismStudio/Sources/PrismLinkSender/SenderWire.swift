import Foundation
import PrismCore
import PrismLink

// ============================================================================
// Pure sender-side wire logic: fragmentation, device clock sync, bitrate
// ladder. No I/O, no clocks — everything here is deterministic and covered by
// SenderSelfTest (fragmentation round-trips against PrismLink's
// FrameReassembler, the exact code the Mac runs).
// ============================================================================

// MARK: - MediaFragmenter

/// Splits whole encoded frames (or audio packets) into `MediaDatagramHeader`-
/// framed datagrams per the PrismLink wire protocol (LinkProtocol.swift).
///
/// Stateful only in its `seq`/`frameID` counters; no I/O. One instance per
/// connection — counters restart at 0 on reconnect, which is what the
/// receiver's loss estimator assumes ("stream started near 0 on connect").
public struct MediaFragmenter: Sendable {
    public private(set) var nextSeq: UInt32
    public private(set) var nextFrameID: UInt32

    public init(firstSeq: UInt32 = 0, firstFrameID: UInt32 = 0) {
        self.nextSeq = firstSeq
        self.nextFrameID = firstFrameID
    }

    /// Payload bytes per datagram for a total-datagram-size budget.
    public static func chunkSize(maxDatagramSize: Int) -> Int {
        maxDatagramSize - LinkProtocol.mediaHeaderSize
    }

    /// Fragments one frame. Every returned datagram is `header.encoded() +
    /// payload-slice` and is at most `maxDatagramSize` bytes.
    ///
    /// Returns `[]` (and consumes no IDs) when the payload is empty, the
    /// budget cannot fit the 25-byte header plus at least one payload byte,
    /// or the frame would need more than 65 535 parts.
    public mutating func fragment(payload: Data, ptsHouseNanos: Int64,
                                  flags: MediaDatagramHeader.Flags,
                                  maxDatagramSize: Int) -> [Data] {
        let chunk = Self.chunkSize(maxDatagramSize: maxDatagramSize)
        guard chunk > 0, !payload.isEmpty else { return [] }
        let partCount = (payload.count + chunk - 1) / chunk
        guard partCount <= Int(UInt16.max) else { return [] }

        let frameID = nextFrameID
        nextFrameID &+= 1

        var datagrams: [Data] = []
        datagrams.reserveCapacity(partCount)
        var offset = 0
        for part in 0..<partCount {
            let length = min(chunk, payload.count - offset)
            let start = payload.startIndex + offset
            let header = MediaDatagramHeader(seq: nextSeq, frameID: frameID,
                                             partIndex: UInt16(part), partCount: UInt16(partCount),
                                             payloadLength: UInt16(length),
                                             ptsHouseNanos: ptsHouseNanos, flags: flags)
            nextSeq &+= 1
            var datagram = header.encoded()
            datagram.append(payload.subdata(in: start..<(start + length)))
            datagrams.append(datagram)
            offset += length
        }
        return datagrams
    }
}

// MARK: - DeviceClockSync

/// Device-side clock synchronization (DESIGN.md §3.4): ingests clockPong
/// replies, rejects RTT outliers (asymmetric queuing poisons the offset), and
/// feeds PrismLink's `ClockSkewEstimator` — the same regression the receiver
/// runs — so capture PTS can be translated device→house with skew tracked.
///
/// Pure state machine: the caller stamps `t4` (device receive time), no
/// clocks are read here.
public struct DeviceClockSync: Sendable {
    private var estimator: ClockSkewEstimator
    private var bestRTTNanos: Int64?
    public private(set) var acceptedSamples = 0
    public private(set) var rejectedSamples = 0

    /// Below this many accepted samples every non-negative-RTT sample is
    /// accepted (bootstrap); after that, outlier rejection applies.
    public let minSamplesBeforeFiltering: Int

    public init(window: Int = 64, minSamplesBeforeFiltering: Int = 4) {
        self.estimator = ClockSkewEstimator(window: window)
        self.minSamplesBeforeFiltering = minSamplesBeforeFiltering
    }

    /// Ingest one pong. `t4` = device clock at pong receipt (same clock that
    /// produced the ping's `t1`). Returns whether the sample was accepted.
    ///
    /// offset = ((t2 − t1) + (t3 − t4)) / 2  (house − device)
    /// rtt    = (t4 − t1) − (t3 − t2)
    @discardableResult
    public mutating func ingest(pong: LinkClockPong, receivedAtDeviceNanos t4: Int64) -> Bool {
        let rtt = (t4 - pong.t1) - (pong.t3 - pong.t2)
        guard rtt >= 0 else {
            rejectedSamples += 1
            return false
        }
        let offset = ((pong.t2 - pong.t1) + (pong.t3 - t4)) / 2
        let best = bestRTTNanos.map { min($0, rtt) } ?? rtt
        bestRTTNanos = best
        // A sample whose RTT is far above the best seen went through a queue
        // somewhere; its one-way asymmetry bound is too loose to trust.
        if acceptedSamples >= minSamplesBeforeFiltering, rtt > best * 2 + 1_000_000 {
            rejectedSamples += 1
            return false
        }
        estimator.add(deviceNanos: t4, offsetNanos: offset)
        acceptedSamples += 1
        return true
    }

    /// Regression estimate (offset + skew) at `atDeviceNanos` (default: the
    /// newest sample). nil until the first pong is ingested.
    public func estimate(atDeviceNanos: Int64? = nil) -> ClockSkewEstimator.Estimate? {
        estimator.estimate(atDeviceNanos: atDeviceNanos)
    }

    /// Translates a device-clock timestamp to house time. nil until synced.
    public func houseNanos(forDeviceNanos deviceNanos: Int64) -> Int64? {
        guard let est = estimator.estimate(atDeviceNanos: deviceNanos) else { return nil }
        return deviceNanos + est.offsetNanos
    }
}

// MARK: - BitrateLadder

/// The encoder bitrate ladder (DESIGN.md §3.4: 20/12/8/5/3 Mbps).
/// Receiver feedback (`LinkStats.lossPercent`, Mac → device) steps it:
/// loss ≥ `lossStepDownPercent` steps down (rate-limited by a cooldown);
/// a sustained clean window steps back up. Pure w.r.t. the injected `now`.
public struct BitrateLadder: Sendable {
    public static let defaultRungsBps = [20_000_000, 12_000_000, 8_000_000, 5_000_000, 3_000_000]

    /// Rungs, descending. `index` 0 = highest bitrate.
    public private(set) var rungsBps: [Int]
    public private(set) var index: Int

    public var lossStepDownPercent: Double = 2.0
    public var lossCleanPercent: Double = 0.5
    public var stepDownCooldown: TimeInterval = 3
    public var stepUpAfterCleanFor: TimeInterval = 10

    private var lastChangeAt: TimeInterval?
    private var cleanSince: TimeInterval?

    public init(rungsBps: [Int] = BitrateLadder.defaultRungsBps, startIndex: Int = 1) {
        precondition(!rungsBps.isEmpty, "ladder needs at least one rung")
        self.rungsBps = rungsBps.sorted(by: >)
        self.index = min(max(0, startIndex), rungsBps.count - 1)
    }

    public var currentBps: Int { rungsBps[index] }

    /// Snap to the rung closest to `bps` (e.g. when a sessionConfig arrives).
    @discardableResult
    public mutating func select(closestTo bps: Int) -> Int {
        index = rungsBps.enumerated()
            .min { abs($0.element - bps) < abs($1.element - bps) }!.offset
        cleanSince = nil
        return currentBps
    }

    /// Feed one Mac→device feedback message. Returns the new bitrate iff the
    /// rung changed. Feedback without `lossPercent` is ignored.
    public mutating func apply(feedback: LinkStats, at now: TimeInterval) -> Int? {
        guard let loss = feedback.lossPercent else { return nil }
        if loss >= lossStepDownPercent {
            cleanSince = nil
            if let last = lastChangeAt, now - last < stepDownCooldown { return nil }
            return stepDown(at: now)
        }
        if loss <= lossCleanPercent {
            if cleanSince == nil { cleanSince = now }
            if let since = cleanSince, now - since >= stepUpAfterCleanFor {
                cleanSince = now
                return stepUp(at: now)
            }
        } else {
            cleanSince = nil
        }
        return nil
    }

    @discardableResult
    public mutating func stepDown(at now: TimeInterval) -> Int? {
        guard index < rungsBps.count - 1 else { return nil }
        index += 1
        lastChangeAt = now
        return currentBps
    }

    @discardableResult
    public mutating func stepUp(at now: TimeInterval) -> Int? {
        guard index > 0 else { return nil }
        index -= 1
        lastChangeAt = now
        return currentBps
    }
}
