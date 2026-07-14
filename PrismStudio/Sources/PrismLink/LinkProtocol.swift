import Foundation

// ============================================================================
// PrismLink wire protocol v1 (DESIGN.md §3.4)
// ============================================================================
//
// Transport: QUIC (Network.framework), ALPN "prism/1", TLS 1.3 with pinned
// certificates established during QR/PIN pairing. Discovery via Bonjour
// "_prism._udp" with a TXT record carrying {name, version}.
//
// Two lanes per device:
//
//  1. CONTROL — the first bidirectional QUIC stream the device opens
//     (reliable, ordered). Carries framed JSON messages:
//
//         ┌────────┬──────┬────────────┬──────────────┐
//         │ 0xC0   │ type │ length     │ payload      │
//         │ magic  │ u8   │ u32 LE     │ JSON (UTF-8) │
//         └────────┴──────┴────────────┴──────────────┘
//
//     Types: hello/capabilities, pairingChallenge/pairingResponse,
//     sessionConfig, cameraControl, tally, keyframeRequest, stats,
//     clockPing/clockPong (see ControlMessageType).
//
//  2. MEDIA — QUIC datagrams (unreliable, unordered; RFC 9221 flow created by
//     the sender with isDatagram = true). One or more media records per
//     datagram; every record is self-delimiting so the same parser also works
//     if a sender falls back to shipping media over a reliable QUIC stream or
//     raw UDP:
//
//         ┌──────┬─────┬───────┬───────┬─────────┬───────────┬───────────┬────────────┬───────────────┬─────────┐
//         │ 0xD1 │ ver │ flags │ seq   │ frameID │ partIndex │ partCount │ payloadLen │ ptsHouseNanos │ payload │
//         │ u8   │ u8  │ u8    │ u32LE │ u32LE   │ u16LE     │ u16LE     │ u16LE      │ i64LE         │ bytes   │
//         └──────┴─────┴───────┴───────┴─────────┴───────────┴───────────┴────────────┴───────────────┴─────────┘
//
//     Header is 25 bytes. flags: bit0 = keyframe, bit1 = audio (else video).
//     Video payloads are HEVC Annex-B fragments (a frame's NAL units split
//     across partCount parts); audio payloads are AAC-ELD packets.
//     `ptsHouseNanos` is HOUSE time — the device runs continuous clock sync
//     (clockPing/clockPong + skew regression) and translates capture PTS to
//     house time BEFORE sending (DESIGN.md §3.3); the receiver trusts it.
//
// Loss policy (§3.4): P-frame part loss → frame dropped on timeout, decoder
// freezes on last good frame, receiver sends keyframeRequest; sustained loss →
// receiver stats feedback drops the encoder bitrate rung on the device.
// ============================================================================

/// Protocol constants shared by both sides.
public enum LinkProtocol {
    public static let version: UInt8 = 1
    public static let alpn = "prism/1"
    public static let bonjourServiceType = "_prism._udp"

    public static let controlMagic: UInt8 = 0xC0
    public static let mediaMagic: UInt8 = 0xD1
    /// Fixed media record header size in bytes.
    public static let mediaHeaderSize = 25
    /// Control frame header size: magic + type + u32 length.
    public static let controlHeaderSize = 6
    /// Upper bound we accept for one control payload (JSON), defensive.
    public static let maxControlPayload = 1 << 20
}

// MARK: - Control messages

/// Control-stream message type byte.
public enum ControlMessageType: UInt8, Sendable {
    case hello = 0x01
    case sessionConfig = 0x02
    case cameraControl = 0x03
    case tally = 0x04
    case keyframeRequest = 0x05
    case stats = 0x06
    case clockPing = 0x07
    case clockPong = 0x08
    /// Mac → device: per-connection random nonce; the device must answer
    /// with `pairingResponse` before the server activates it (pairing v2).
    case pairingChallenge = 0x09
    /// Device → Mac: `LinkPairing.pairingProof(code:serverCertificateDER:nonce:)`.
    case pairingResponse = 0x0A
}

/// Device → Mac: identity + capabilities, first message on the control stream.
public struct LinkHello: Codable, Sendable {
    public var protocolVersion: UInt8
    public var name: String
    public var model: String
    public var codecs: [String]        // e.g. ["hevc"]
    public var maxWidth: Int
    public var maxHeight: Int
    public var maxFps: Int
    public var hasTorch: Bool
    public var lenses: [String]        // e.g. ["wide", "ultraWide", "tele"]
    /// LEGACY (pairing v1, removed 2026-07-07): base64 static proof — HMAC
    /// of the server's leaf certificate with the code-derived key, no nonce.
    /// v2 clients leave this nil and answer the server's `pairingChallenge`
    /// instead; a pairing-enabled v2 server REJECTS a hello that carries
    /// this field (a static proof is replayable — see LinkPairing's
    /// honest-scope note). Kept only so the JSON shape stays decodable.
    public var pairingProof: String?
    /// Pairing v2 (mutual auth): base64 client-issued nonce. When the client
    /// requires pairing it mints a fresh 32-byte nonce here; the server must
    /// return `LinkPairingChallenge.serverProof` computed over this nonce, so the
    /// client can verify the server knows the code before streaming media.
    /// Optional so the JSON shape stays backward-compatible (nil = no reverse
    /// proof requested, legacy behavior).
    public var clientNonce: String?

    public init(protocolVersion: UInt8 = LinkProtocol.version, name: String, model: String,
                codecs: [String] = ["hevc"], maxWidth: Int = 1920, maxHeight: Int = 1080,
                maxFps: Int = 60, hasTorch: Bool = false, lenses: [String] = [],
                pairingProof: String? = nil, clientNonce: String? = nil) {
        self.protocolVersion = protocolVersion
        self.name = name
        self.model = model
        self.codecs = codecs
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.maxFps = maxFps
        self.hasTorch = hasTorch
        self.lenses = lenses
        self.pairingProof = pairingProof
        self.clientNonce = clientNonce
    }
}

/// Mac → device: the session the receiver wants (codec/resolution/fps/bitrate).
public struct LinkSessionConfig: Codable, Sendable {
    public var codec: String
    public var width: Int
    public var height: Int
    public var fps: Int
    public var targetBitrateBps: Int
    public var keyframeIntervalSeconds: Double

    public init(codec: String = "hevc", width: Int = 1920, height: Int = 1080, fps: Int = 60,
                targetBitrateBps: Int = 12_000_000, keyframeIntervalSeconds: Double = 2) {
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
        self.targetBitrateBps = targetBitrateBps
        self.keyframeIntervalSeconds = keyframeIntervalSeconds
    }
}

/// Mac → device: camera adjustments. All fields optional = "leave unchanged".
public struct LinkCameraControl: Codable, Sendable {
    public var lens: String?
    public var exposureBiasEV: Double?
    public var torch: Bool?
    public var zoomFactor: Double?

    public init(lens: String? = nil, exposureBiasEV: Double? = nil, torch: Bool? = nil,
                zoomFactor: Double? = nil) {
        self.lens = lens
        self.exposureBiasEV = exposureBiasEV
        self.torch = torch
        self.zoomFactor = zoomFactor
    }
}

/// Mac → device: tally state for the device's UI.
public struct LinkTally: Codable, Sendable {
    public var program: Bool
    public var preview: Bool
    public init(program: Bool, preview: Bool) {
        self.program = program
        self.preview = preview
    }
}

/// Mac → device: "send an IDR now" (after loss or on join).
public struct LinkKeyframeRequest: Codable, Sendable {
    /// Last frameID the receiver completed, for the sender's diagnostics.
    public var lastCompletedFrameID: UInt32?
    public init(lastCompletedFrameID: UInt32? = nil) {
        self.lastCompletedFrameID = lastCompletedFrameID
    }
}

/// Bidirectional telemetry. Device → Mac includes clock-sync measurements the
/// receiver folds into its skew regression; Mac → device includes loss/jitter
/// feedback that drives the encoder bitrate ladder (§3.4).
public struct LinkStats: Codable, Sendable {
    // Device → Mac
    public var thermalState: Int?             // 0 nominal … 3 critical
    public var encoderQueueDepth: Int?
    public var sendBitrateBps: Int?
    /// Device's most recent clock measurement: at device clock `deviceClockNanos`
    /// its estimated (house − device) offset was `clockOffsetNanos`.
    public var deviceClockNanos: Int64?
    public var clockOffsetNanos: Int64?
    // Mac → device
    public var lossPercent: Double?
    public var jitterMs: Double?
    public var framesDropped: UInt64?

    public init(thermalState: Int? = nil, encoderQueueDepth: Int? = nil, sendBitrateBps: Int? = nil,
                deviceClockNanos: Int64? = nil, clockOffsetNanos: Int64? = nil,
                lossPercent: Double? = nil, jitterMs: Double? = nil, framesDropped: UInt64? = nil) {
        self.thermalState = thermalState
        self.encoderQueueDepth = encoderQueueDepth
        self.sendBitrateBps = sendBitrateBps
        self.deviceClockNanos = deviceClockNanos
        self.clockOffsetNanos = clockOffsetNanos
        self.lossPercent = lossPercent
        self.jitterMs = jitterMs
        self.framesDropped = framesDropped
    }
}

/// Mac → device (pairing v2): a fresh per-connection challenge. `nonce` is
/// base64 of ≥16 random bytes (servers send 32, from `SecRandomCopyBytes`).
/// Sent in reply to the hello when the server has a pairing code configured;
/// the device must answer with `LinkPairingResponse` or be dropped.
public struct LinkPairingChallenge: Codable, Sendable {
    public var nonce: String
    /// Pairing v2 (mutual auth): base64 of
    /// `LinkPairing.serverProof(code:serverCertificateDER:clientNonce:)`, present
    /// when the hello carried a `clientNonce`. Lets the device verify the server
    /// knows the code before it streams. Optional for JSON back-compat.
    public var serverProof: String?
    public init(nonce: String, serverProof: String? = nil) {
        self.nonce = nonce
        self.serverProof = serverProof
    }
}

/// Device → Mac (pairing v2): base64 of
/// `LinkPairing.pairingProof(code:serverCertificateDER:nonce:)` computed over
/// the certificate observed in the TLS handshake and the challenge nonce.
public struct LinkPairingResponse: Codable, Sendable {
    public var proof: String
    public init(proof: String) {
        self.proof = proof
    }
}

/// Device → Mac. `t1` = device send time in DEVICE clock nanos (opaque to us).
public struct LinkClockPing: Codable, Sendable {
    public var seq: UInt32
    public var t1: Int64
    public init(seq: UInt32, t1: Int64) {
        self.seq = seq
        self.t1 = t1
    }
}

/// Mac → device reply. `t2` = house time at receive, `t3` = house time at send
/// (both nanos). The device computes offset = ((t2 − t1) + (t3 − t4)) / 2.
public struct LinkClockPong: Codable, Sendable {
    public var seq: UInt32
    public var t1: Int64
    public var t2: Int64
    public var t3: Int64
    public init(seq: UInt32, t1: Int64, t2: Int64, t3: Int64) {
        self.seq = seq
        self.t1 = t1
        self.t2 = t2
        self.t3 = t3
    }
}

// MARK: - Media record header

/// Header of one media record (25 bytes on the wire, little-endian).
public struct MediaDatagramHeader: Equatable, Sendable {
    public struct Flags: OptionSet, Equatable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let keyframe = Flags(rawValue: 1 << 0)
        public static let audio = Flags(rawValue: 1 << 1)
    }

    public var seq: UInt32
    public var frameID: UInt32
    public var partIndex: UInt16
    public var partCount: UInt16
    public var payloadLength: UInt16
    public var ptsHouseNanos: Int64
    public var flags: Flags

    public init(seq: UInt32, frameID: UInt32, partIndex: UInt16, partCount: UInt16,
                payloadLength: UInt16, ptsHouseNanos: Int64, flags: Flags) {
        self.seq = seq
        self.frameID = frameID
        self.partIndex = partIndex
        self.partCount = partCount
        self.payloadLength = payloadLength
        self.ptsHouseNanos = ptsHouseNanos
        self.flags = flags
    }

    /// Pure encode: 25-byte little-endian header.
    public func encoded() -> Data {
        var out = Data(capacity: LinkProtocol.mediaHeaderSize)
        out.append(LinkProtocol.mediaMagic)
        out.append(LinkProtocol.version)
        out.append(flags.rawValue)
        out.appendLE(seq)
        out.appendLE(frameID)
        out.appendLE(partIndex)
        out.appendLE(partCount)
        out.appendLE(payloadLength)
        out.appendLE(UInt64(bitPattern: ptsHouseNanos))
        return out
    }

    public enum ParseError: Error, Equatable {
        case tooShort
        case badMagic(UInt8)
        case unsupportedVersion(UInt8)
        case badPartFields
    }

    /// Pure decode of the fixed header from the start of `data` (payload follows).
    public static func parse(_ data: Data) throws -> MediaDatagramHeader {
        guard data.count >= LinkProtocol.mediaHeaderSize else { throw ParseError.tooShort }
        let magic = data.byte(at: 0)
        guard magic == LinkProtocol.mediaMagic else { throw ParseError.badMagic(magic) }
        let version = data.byte(at: 1)
        guard version == LinkProtocol.version else { throw ParseError.unsupportedVersion(version) }
        let header = MediaDatagramHeader(
            seq: data.readLE(UInt32.self, at: 3),
            frameID: data.readLE(UInt32.self, at: 7),
            partIndex: data.readLE(UInt16.self, at: 11),
            partCount: data.readLE(UInt16.self, at: 13),
            payloadLength: data.readLE(UInt16.self, at: 15),
            ptsHouseNanos: Int64(bitPattern: data.readLE(UInt64.self, at: 17)),
            flags: Flags(rawValue: data.byte(at: 2))
        )
        guard header.partCount > 0, header.partIndex < header.partCount else {
            throw ParseError.badPartFields
        }
        return header
    }
}

// MARK: - Control frame codec + stream parser (pure)

/// One item produced by `LinkFrameParser`.
public enum LinkParsedItem: Sendable {
    case control(type: ControlMessageType, payload: Data)
    /// A control frame with a type byte we don't know (forward compat: skip).
    case unknownControl(type: UInt8, payload: Data)
    case media(header: MediaDatagramHeader, payload: Data)
}

public enum LinkFrameError: Error, Equatable {
    case badMagic(UInt8)
    case oversizedControlPayload(Int)
}

/// Encodes one control frame: [0xC0][type][u32 LE length][JSON payload].
public func encodeControlFrame(type: ControlMessageType, payload: Data) -> Data {
    var out = Data(capacity: LinkProtocol.controlHeaderSize + payload.count)
    out.append(LinkProtocol.controlMagic)
    out.append(type.rawValue)
    out.appendLE(UInt32(payload.count))
    out.append(payload)
    return out
}

/// Convenience: encode a Codable control message body into a full frame.
public func encodeControlMessage<T: Encodable>(_ type: ControlMessageType, _ body: T) throws -> Data {
    encodeControlFrame(type: type, payload: try JSONEncoder().encode(body))
}

/// Incremental, allocation-light parser for the byte stream of a peer.
///
/// Because every record is self-delimiting (control frames carry a length,
/// media records carry payloadLength), the same parser handles: a reliable
/// QUIC stream chunked arbitrarily, one-datagram-per-callback delivery, or
/// several records coalesced into one buffer. Pure: no I/O, no clocks.
public struct LinkFrameParser: Sendable {
    private var buffer = Data()

    public init() {}

    /// Feed received bytes; returns every complete item now available.
    /// Throws on a framing violation (caller should reset/kill the lane).
    public mutating func feed(_ data: Data) throws -> [LinkParsedItem] {
        buffer.append(data)
        var items: [LinkParsedItem] = []
        while !buffer.isEmpty {
            switch buffer.byte(at: 0) {
            case LinkProtocol.controlMagic:
                guard buffer.count >= LinkProtocol.controlHeaderSize else { return items }
                let typeByte = buffer.byte(at: 1)
                let length = Int(buffer.readLE(UInt32.self, at: 2))
                guard length <= LinkProtocol.maxControlPayload else {
                    throw LinkFrameError.oversizedControlPayload(length)
                }
                let total = LinkProtocol.controlHeaderSize + length
                guard buffer.count >= total else { return items }
                let payload = buffer.subdata(in: (buffer.startIndex + LinkProtocol.controlHeaderSize)
                    ..< (buffer.startIndex + total))
                if let type = ControlMessageType(rawValue: typeByte) {
                    items.append(.control(type: type, payload: payload))
                } else {
                    items.append(.unknownControl(type: typeByte, payload: payload))
                }
                buffer.removeFirst(total)
            case LinkProtocol.mediaMagic:
                guard buffer.count >= LinkProtocol.mediaHeaderSize else { return items }
                let header = try MediaDatagramHeader.parse(buffer)
                let total = LinkProtocol.mediaHeaderSize + Int(header.payloadLength)
                guard buffer.count >= total else { return items }
                let payload = buffer.subdata(in: (buffer.startIndex + LinkProtocol.mediaHeaderSize)
                    ..< (buffer.startIndex + total))
                items.append(.media(header: header, payload: payload))
                buffer.removeFirst(total)
            case let other:
                throw LinkFrameError.badMagic(other)
            }
        }
        return items
    }

    /// Bytes currently buffered awaiting completion (for stats/debug).
    public var pendingByteCount: Int { buffer.count }
}

// MARK: - Little-endian Data helpers (internal, pure)

extension Data {
    /// Byte at logical offset `i` regardless of the slice's startIndex.
    func byte(at i: Int) -> UInt8 {
        self[startIndex + i]
    }

    /// Reads a little-endian fixed-width integer at logical offset `offset`.
    /// Precondition: `offset + size <= count` (callers check lengths first).
    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size {
            value |= T(byte(at: offset + i)) << (8 * i)
        }
        return value
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value
        for _ in 0..<MemoryLayout<T>.size {
            append(UInt8(truncatingIfNeeded: v))
            v >>= 8
        }
    }
}
