import CoreBluetooth
import Foundation
import Security

/// PrismProximity — Bluetooth LE proximity discovery + pairing assist (DESIGN.md
/// §3.8). BLE does exactly three jobs here: let the Mac notice a nearby iOS
/// companion, show "Alex's iPhone is nearby — pair?" *before* any Wi-Fi
/// association, and (later) nudge a sleeping companion awake. It mirrors
/// Continuity Camera's model: **discovery/wake over BT, media over Wi-Fi**.
///
/// ## What NEVER crosses Bluetooth
/// - **Video / audio / any media.** Physics forbids it (BLE ≈ 0.1–1 Mbps;
///   1080p60 HEVC needs 8–12 Mbps/device). All media rides QUIC/Wi-Fi (§3.4,
///   `PrismLink`).
/// - **The pairing code / PSK.** The BLE advertisement carries only *presence*
///   (a stable service UUID) + a device *name* + a short **rotating token**.
///   It never carries — and there is no API path to attach — the pairing code
///   from `LinkPairing.generateCode()` or the HKDF-derived `PSK`. BLE presence
///   only tells the Mac "a device is here and willing to pair"; the actual
///   secret exchange is the existing short-code / QR flow over Wi-Fi
///   (`LinkPairing`, challenge–response with per-session nonce). Compromising
///   the BLE channel yields at most "a device named X was nearby", never the
///   ability to pair.
///
/// ## The rotating presence token
/// A `ProximityToken` is 4 random bytes from `SecRandomCopyBytes` (a CSPRNG).
/// It is **not security-bearing**: its only jobs are (a) let the Mac
/// distinguish two sightings of the same advertiser within a scan window, and
/// (b) rotate periodically so a passive BLE sniffer cannot trivially correlate
/// a device's presence across long time spans (a privacy nicety, not a defense —
/// the local name is still visible). Because the token is pure random bytes
/// generated from no code input, it is structurally incapable of leaking the
/// pairing code.
public enum ProximityProtocol {

    // MARK: - Service / characteristic identity (STABLE — do not change)

    /// The Prism BLE service UUID. Fixed 128-bit constant: the Mac central
    /// scans for exactly this, and the iOS peripheral advertises exactly this.
    /// Changing it breaks discovery between shipped builds, so it is versioned
    /// only by minting a new constant, never by editing this one.
    public static let serviceUUIDString = "9F4B7C10-3E1A-4B2D-8F6A-1C2D3E4F5A6B"

    /// The characteristic a connected central may read to obtain the advertiser's
    /// `name + rotating token` (same payload as the advertisement service-data
    /// blob) when the advertising overflow area was unavailable.
    public static let characteristicUUIDString = "9F4B7C11-3E1A-4B2D-8F6A-1C2D3E4F5A6B"

    /// `CBUUID` form of ``serviceUUIDString``. Constructing a `CBUUID` is pure
    /// (no radio, no permission prompt).
    public static let serviceUUID = CBUUID(string: serviceUUIDString)

    /// `CBUUID` form of ``characteristicUUIDString``.
    public static let characteristicUUID = CBUUID(string: characteristicUUIDString)

    // MARK: - Advertisement payload format

    /// Payload version byte. Bump when the wire layout below changes.
    public static let payloadVersion: UInt8 = 1

    /// Length of the rotating presence token, in bytes.
    public static let tokenLength = 4

    /// Maximum device-name length carried in the payload, in UTF-8 bytes. Kept
    /// small because a legacy BLE advertisement PDU is only ~31 bytes and the
    /// name shares it with the service UUID and service-data header. Names are
    /// truncated on a UTF-8 scalar boundary, never mid-scalar.
    public static let maxNameBytes = 22

    /// Wire layout of the presence payload (used as both the advertisement
    /// service-data blob and the characteristic value):
    ///
    ///     byte 0        : payloadVersion (1)
    ///     bytes 1..<5   : token          (tokenLength = 4 bytes)
    ///     bytes 5...    : device name     (UTF-8, ≤ maxNameBytes)
    ///
    /// No field can hold the pairing code: the encoder's only inputs are a
    /// name and a random token.
    public struct Advertisement: Equatable {
        /// Human-facing device name, e.g. "Alex's iPhone". Truncated to
        /// ``maxNameBytes`` UTF-8 bytes at encode time.
        public let name: String
        /// The current rotating presence token.
        public let token: ProximityToken

        public init(name: String, token: ProximityToken) {
            self.name = name
            self.token = token
        }

        /// Encode to the wire blob. Never fails: an over-long name is truncated
        /// on a scalar boundary so the result always fits `maxNameBytes`.
        public func encode() -> Data {
            var data = Data()
            data.append(ProximityProtocol.payloadVersion)
            data.append(token.bytes)
            data.append(ProximityProtocol.truncatedNameBytes(name))
            return data
        }

        /// Decode a wire blob. Returns `nil` on any malformation (too short,
        /// unknown version, invalid UTF-8 name, or a name longer than
        /// ``maxNameBytes``) rather than a partial value. The name bound is
        /// symmetric with ``encode()`` (which truncates to ``maxNameBytes``): a
        /// blob whose name region exceeds the budget could never have been
        /// produced by our encoder, so it is treated as malformed (#9).
        public static func decode(_ data: Data) -> Advertisement? {
            let header = 1 + ProximityProtocol.tokenLength
            guard data.count >= header else { return nil }
            // Index off the actual startIndex — a `Data` slice need not be 0-based.
            let base = data.startIndex
            guard data[base] == ProximityProtocol.payloadVersion else { return nil }
            let tokenBytes = data.subdata(in: (base + 1)..<(base + header))
            guard let token = ProximityToken(bytes: tokenBytes) else { return nil }
            let nameBytes = data.subdata(in: (base + header)..<data.endIndex)
            // Enforce the same byte bound the encoder does — reject over-long
            // names instead of accepting an arbitrarily long region.
            guard nameBytes.count <= ProximityProtocol.maxNameBytes else { return nil }
            guard let name = String(data: nameBytes, encoding: .utf8) else { return nil }
            return Advertisement(name: name, token: token)
        }
    }

    /// Truncate a name to ``maxNameBytes`` UTF-8 bytes without splitting a
    /// scalar. Drops trailing scalars until the encoding fits.
    static func truncatedNameBytes(_ name: String) -> Data {
        var scalars = Array(name.unicodeScalars)
        while true {
            let candidate = String(String.UnicodeScalarView(scalars))
            let bytes = Data(candidate.utf8)
            if bytes.count <= maxNameBytes || scalars.isEmpty { return bytes }
            scalars.removeLast()
        }
    }

    // MARK: - RSSI → proximity bucket

    /// RSSI (dBm) at/above which a candidate is `.immediate` (device basically
    /// touching the Mac).
    public static let immediateRSSIThreshold = -45
    /// RSSI (dBm) at/above which a candidate is `.near` (same table / arm's
    /// reach); below it is `.far`.
    public static let nearRSSIThreshold = -75

    /// Bucket a raw RSSI reading. CoreBluetooth reports `127` (and any value
    /// ≥ 0) for "reading unavailable", which maps to `.unknown`.
    public static func bucket(forRSSI rssi: Int) -> ProximityBucket {
        if rssi >= 0 { return .unknown }             // 127 / invalid sentinel
        if rssi >= immediateRSSIThreshold { return .immediate }
        if rssi >= nearRSSIThreshold { return .near } // e.g. -50 → near
        return .far                                   // e.g. -90 → far
    }
}

/// Coarse distance bucket derived from RSSI. UI shows this, not raw dBm.
public enum ProximityBucket: String, Equatable, Sendable {
    case immediate
    case near
    case far
    case unknown
}

/// A short, rotating, non-secret presence token (see ``ProximityProtocol``).
public struct ProximityToken: Equatable, Sendable {
    /// Raw token bytes (`ProximityProtocol.tokenLength` long).
    public let bytes: Data

    /// Wrap exactly `tokenLength` bytes. Returns `nil` for any other length so
    /// a malformed advertisement can't fabricate a token.
    public init?(bytes: Data) {
        guard bytes.count == ProximityProtocol.tokenLength else { return nil }
        self.bytes = bytes
    }

    /// A fresh CSPRNG token. Throws `ProximityError.tokenGenerationFailed` if
    /// `SecRandomCopyBytes` reports an error. Takes NO code/PSK input — the
    /// token cannot, by construction, contain the pairing code.
    public static func random() throws -> ProximityToken {
        var raw = [UInt8](repeating: 0, count: ProximityProtocol.tokenLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw)
        guard status == errSecSuccess else {
            throw ProximityError.tokenGenerationFailed(status)
        }
        // Length is a compile-time constant, so this init never fails.
        return ProximityToken(bytes: Data(raw))!
    }

    /// Hex form, for logs (a rotating non-secret, safe to log).
    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
}

/// Holds the current presence token and rotates it on demand. Not thread-safe;
/// drive it from the advertiser's own queue.
public struct TokenRotator {
    public private(set) var current: ProximityToken

    public init() throws {
        current = try ProximityToken.random()
    }

    /// Replace `current` with a fresh token and return it.
    @discardableResult
    public mutating func rotate() throws -> ProximityToken {
        current = try ProximityToken.random()
        return current
    }
}
