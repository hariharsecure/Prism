import CoreBluetooth
import Foundation

/// A nearby iOS device the Mac has heard advertising the Prism service. This is
/// what the app's "nearby devices" UI renders; selecting one kicks off the
/// existing Wi-Fi short-code / QR pairing (`PrismLink`) — the BLE sighting only
/// says "this device is here and willing to pair".
public struct ProximityCandidate: Equatable, Sendable {
    /// CoreBluetooth's per-scan peripheral identifier (a rotating UUID on iOS
    /// privacy addresses — stable enough to dedupe within a scan session).
    public let peripheralID: UUID
    /// Device name from the advertisement, if present.
    public let name: String?
    /// Latest rotating presence token, if the advertiser included one.
    public let token: ProximityToken?
    /// Most recent RSSI reading (dBm).
    public let rssi: Int
    /// When this peripheral was first heard in the current session.
    public let firstSeen: Date
    /// When this peripheral was most recently heard.
    public let lastSeen: Date

    /// Coarse distance bucket for the latest RSSI.
    public var proximity: ProximityBucket { ProximityProtocol.bucket(forRSSI: rssi) }

    public init(peripheralID: UUID, name: String?, token: ProximityToken?,
                rssi: Int, firstSeen: Date, lastSeen: Date) {
        self.peripheralID = peripheralID
        self.name = name
        self.token = token
        self.rssi = rssi
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// Dedup + freshness bookkeeping for sightings. A sighting of an already-known
/// peripheral updates its `rssi`/`name`/`token`/`lastSeen` in place, preserving
/// `firstSeen`; a new peripheral is inserted. Stale entries are pruned by TTL.
///
/// Pure logic — no CoreBluetooth object is created here, so it is exercised
/// fully by the headless self-test. Not thread-safe; the scanner drives it from
/// its delegate queue.
public struct CandidateStore {
    private var candidates: [UUID: ProximityCandidate] = [:]

    /// How long a candidate survives without a fresh sighting.
    public let staleAfter: TimeInterval

    public init(staleAfter: TimeInterval = 10) {
        self.staleAfter = staleAfter
    }

    /// Current candidates, most-recently-seen first.
    public var all: [ProximityCandidate] {
        candidates.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    public var count: Int { candidates.count }

    public func candidate(for id: UUID) -> ProximityCandidate? { candidates[id] }

    /// Record a sighting. Returns the resulting candidate and whether it was
    /// newly discovered (so the UI can distinguish "appeared" from "updated").
    @discardableResult
    public mutating func observe(peripheralID: UUID, name: String?, token: ProximityToken?,
                                 rssi: Int, at now: Date) -> (candidate: ProximityCandidate, isNew: Bool) {
        if let existing = candidates[peripheralID] {
            let updated = ProximityCandidate(
                peripheralID: peripheralID,
                name: name ?? existing.name,        // keep last known name if this PDU omitted it
                token: token ?? existing.token,
                rssi: rssi,
                firstSeen: existing.firstSeen,
                lastSeen: now)
            candidates[peripheralID] = updated
            return (updated, false)
        }
        let fresh = ProximityCandidate(
            peripheralID: peripheralID, name: name, token: token,
            rssi: rssi, firstSeen: now, lastSeen: now)
        candidates[peripheralID] = fresh
        return (fresh, true)
    }

    /// Drop candidates not seen within `staleAfter` of `now`. Returns the IDs
    /// removed so the UI can retract them.
    @discardableResult
    public mutating func prune(at now: Date) -> [UUID] {
        let expired = candidates.filter { now.timeIntervalSince($0.value.lastSeen) > staleAfter }
        for id in expired.keys { candidates.removeValue(forKey: id) }
        return Array(expired.keys)
    }

    /// Forget everything (e.g. when scanning stops or Bluetooth powers off).
    public mutating func removeAll() { candidates.removeAll() }
}
