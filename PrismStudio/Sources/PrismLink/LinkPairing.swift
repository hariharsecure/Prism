import CryptoKit
import Foundation
import Network
import Security

/// v1 pairing bootstrap (DESIGN.md §3.4 / §3.7): a short code shown on the
/// Mac (typed or QR-scanned on the device) from which BOTH sides derive the
/// same 32-byte key:
///
///     PSK = HKDF-SHA256(ikm:  normalized pairing code (UTF-8),
///                       salt: "prism/1-psk-v1",
///                       info: "_prism._udp",           // the service name
///                       out:  32 bytes)
///
/// HOW THE KEY IS USED — application-layer proof, not TLS-PSK. The original
/// design ran QUIC as TLS-1.3-PSK with this key; that is **impossible on
/// Network.framework today** (see `apply(pairingCode:to:)`). Instead
/// (pairing sub-handshake v2, challenge–response):
///
///  1. The server (Mac) presents an ephemeral self-signed certificate
///     (`LinkIdentity`); QUIC/TLS 1.3 provides encryption.
///  2. The client accepts that certificate (subject to TOFU pinning — see
///     `TrustedServerStore`) and remembers its DER bytes.
///  3. The client's hello carries NO proof. The server answers it with a
///     `pairingChallenge` control message holding a fresh random nonce
///     (32 bytes from `SecRandomCopyBytes`, one per connection).
///  4. The client replies with a `pairingResponse` carrying
///     `pairingProof(code:serverCertificateDER:nonce:)` — HMAC-SHA256 with
///     the code-derived key over context ‖ server leaf cert ‖ nonce.
///  5. The server verifies the proof against its own certificate + the nonce
///     it issued and drops the peer on mismatch. Cert binding defeats an
///     active MITM relaying to the real server (its cert differs); the nonce
///     makes the proof per-session, so a harvested proof cannot be REPLAYED.
///
/// SECURITY (honest scope): an 8-character code over a 32-symbol alphabet is
/// 40 bits — LAN-MVP security. It gates who on the local network can attach a
/// camera. Known gaps, deliberately accepted for the LAN MVP:
///  - **there IS an offline brute-force surface against an ACTIVE attacker**:
///    a fake Prism server on the LAN can accept a device's connection, issue
///    a nonce, harvest the proof, and grind all 32^8 ≈ 1.1e12 codes offline
///    (every input to the HMAC other than the code is attacker-known). The
///    nonce does NOT fix this — it only kills replay of a harvested proof.
///    TLS encryption prevents *passive* harvesting only. Mitigations in
///    place: TOFU pinning (`TrustedServerStore`) stops a fake server from
///    impersonating a Mac the device has already paired with; the
///    per-session nonce stops proof replay. 40 bits is the real ceiling of
///    this scheme; raising code length is the only way to raise it.
///  - first contact is trust-on-first-use: the device cannot distinguish the
///    real Mac from a fake one the very first time it pairs with a code.
///  - online code guessing is possible (one guess per connection; 32^8 keeps
///    this impractical online, and codes are per-install).
/// The QR code carries the same code (nothing stronger).
///
/// WIRE COMPATIBILITY: v2 (2026-07-07) replaced the v1 static hello proof
/// (`LinkHello.pairingProof`, HMAC over context ‖ cert with no nonce). A
/// pairing-enabled server now REJECTS hellos carrying the legacy static
/// proof and requires the challenge round-trip; pre-v2 senders cannot pair.
/// Both ends live in this repo and version together (ALPN "prism/1").
/// TODO(pairing-v2+): longer-code option, BLE-proximity or SAS-style
/// out-of-band verification.
public enum LinkPairing {

    /// Crockford-style base32: 0-9 + A-Z minus I, L, O, U — no two symbols
    /// look alike, so codes survive being read aloud or hand-typed.
    public static let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    /// Pairing codes are 8 symbols (40 bits of entropy).
    public static let codeLength = 8

    /// Minimum NORMALIZED code length `derivePSK`/`pairingProof` accept.
    /// Generated codes are always `codeLength`; anything shorter is a typo
    /// or an empty string and must not silently derive a weak key.
    public static let minimumCodeLength = 8

    /// Minimum challenge-nonce length (bytes) a client will accept from a
    /// server. Servers send 32; refusing short nonces stops a hostile server
    /// from downgrading the replay defense to a guessable value.
    public static let minimumNonceLength = 16

    /// Typed failures for code validation (A6) and challenge validation.
    public enum PairingError: Error, Equatable {
        /// The normalized code is shorter than `minimumCodeLength`
        /// (includes the empty string).
        case codeTooShort(normalizedLength: Int, minimum: Int)
        /// The server-supplied challenge nonce is shorter than
        /// `minimumNonceLength`.
        case nonceTooShort(length: Int, minimum: Int)
    }

    /// TLS PSK identity for prism/1 code-derived keys. Sent as the server's
    /// identity hint and as the client's offered PSK identity; a future
    /// pairing scheme (v2 per-device keys) will use a different identity so
    /// both can coexist during migration.
    public static let pskIdentity = "prism-pair-v1"

    /// HKDF salt, versioned with the derivation scheme.
    static let hkdfSalt = "prism/1-psk-v1"

    // MARK: Code generation / normalization

    /// A fresh random pairing code (`SystemRandomNumberGenerator` — CSPRNG
    /// on Apple platforms).
    public static func generateCode() -> String {
        var rng = SystemRandomNumberGenerator()
        let symbols = Array(alphabet)
        return String((0..<codeLength).map { _ in
            symbols[Int(rng.next(upperBound: UInt32(symbols.count)))]
        })
    }

    /// Canonical form used for key derivation: uppercased, separators/spaces
    /// stripped, look-alikes folded (O→0, I→1, L→1). Both sides MUST
    /// normalize, so "abcd-2345" and "ABCD2345" derive the same key.
    public static func normalize(_ code: String) -> String {
        String(code.uppercased().compactMap { char -> Character? in
            switch char {
            case "O": return "0"
            case "I", "L": return "1"
            case let c where alphabet.contains(c): return c
            default: return nil // hyphens, spaces, stray punctuation
            }
        })
    }

    /// Human-facing form: "ABCD-2345".
    public static func display(_ code: String) -> String {
        let normalized = normalize(code)
        guard normalized.count > 4 else { return normalized }
        let middle = normalized.index(normalized.startIndex, offsetBy: 4)
        return "\(normalized[..<middle])-\(normalized[middle...])"
    }

    // MARK: Key derivation

    /// The 32-byte PSK both sides derive from the code. Deterministic; the
    /// info string is the Bonjour service name (stable protocol constant on
    /// both sides — the human-readable server name is NOT part of the
    /// derivation, so a client can derive before discovery resolves).
    /// Throws `PairingError.codeTooShort` for empty/degenerate codes (A6) —
    /// deriving a key from "" would turn "no code" into a known key.
    public static func derivePSK(code: String) throws -> SymmetricKey {
        let normalized = normalize(code)
        guard normalized.count >= minimumCodeLength else {
            throw PairingError.codeTooShort(normalizedLength: normalized.count,
                                            minimum: minimumCodeLength)
        }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(normalized.utf8)),
            salt: Data(hkdfSalt.utf8),
            info: Data(LinkProtocol.bonjourServiceType.utf8),
            outputByteCount: 32)
    }

    // MARK: Pairing proof (the mechanism actually in use)

    /// Domain separator for the challenge–response proof HMAC. v2 — the v1
    /// context ("…-proof-v1") signed a static, nonce-less input; a distinct
    /// context guarantees a harvested v1 proof can never verify as v2.
    static let proofContext = "prism/1-pair-proof-v2"

    /// HMAC-SHA256 over context ‖ server leaf certificate (DER) ‖ server
    /// challenge nonce, keyed with the code-derived key. The client computes
    /// it from the certificate observed during the TLS handshake plus the
    /// nonce from the server's `pairingChallenge`; the server computes it
    /// from its own certificate plus the nonce it issued; equality proves
    /// the client knows the code AND is talking to this certificate (channel
    /// binding) IN this session (the nonce makes the proof single-use —
    /// replaying it on a new connection fails because the nonce differs).
    public static func pairingProof(code: String, serverCertificateDER: Data,
                                    nonce: Data) throws -> Data {
        guard nonce.count >= minimumNonceLength else {
            throw PairingError.nonceTooShort(length: nonce.count, minimum: minimumNonceLength)
        }
        var mac = HMAC<SHA256>(key: try derivePSK(code: code))
        mac.update(data: Data(proofContext.utf8))
        mac.update(data: serverCertificateDER)
        mac.update(data: nonce)
        return Data(mac.finalize())
    }

    /// Domain separator for the SERVER's reverse proof (server→client). Distinct
    /// from `proofContext` so a client proof can never be replayed as a server
    /// proof — even with the same code, certificate, and nonce, the two HMACs
    /// differ because the context bytes differ.
    static let serverProofContext = "prism/1-server-proof-v2"

    /// HMAC-SHA256 over serverProofContext ‖ server leaf certificate (DER) ‖
    /// CLIENT-issued nonce, keyed with the code-derived key. The server computes
    /// it from its own certificate plus the nonce the client sent in its hello;
    /// the client recomputes it from the certificate it observed during the TLS
    /// handshake plus the nonce it minted, and requires equality BEFORE it opens
    /// the media lane. This proves the server knows the code AND is this exact
    /// certificate, defeating a first-contact spoof server that would otherwise
    /// silently harvest the client's camera. The client nonce makes it single-use.
    public static func serverProof(code: String, serverCertificateDER: Data,
                                   clientNonce: Data) throws -> Data {
        guard clientNonce.count >= minimumNonceLength else {
            throw PairingError.nonceTooShort(length: clientNonce.count, minimum: minimumNonceLength)
        }
        var mac = HMAC<SHA256>(key: try derivePSK(code: code))
        mac.update(data: Data(serverProofContext.utf8))
        mac.update(data: serverCertificateDER)
        mac.update(data: clientNonce)
        return Data(mac.finalize())
    }

    // MARK: QUIC/TLS-PSK wiring — KEPT FOR REFERENCE, currently unusable

    /// Configures `options.securityProtocolOptions` for TLS-1.3-PSK with the
    /// code-derived key (add_pre_shared_key + identity hint + TLS 1.3 pin +
    /// AES-128-GCM-SHA256, per RFC 8446 §4.2.11 hash binding).
    ///
    /// **DO NOT WIRE THIS INTO QUIC** — verified empirically on macOS 26
    /// (2026-07-07): Network.framework only supports PSK with TLS 1.2 PSK
    /// ciphersuites (0x00A8 handshakes fine over TCP); pinning TLS 1.3 fails
    /// with -9858 and QUIC (which mandates TLS 1.3) hangs in every variant
    /// (with/without suite append, version pins, PSK selection block).
    /// Retained so the intended one-line switch is documented if Apple ships
    /// TLS-1.3 external-PSK support; the shipping mechanism is
    /// `pairingProof(code:serverCertificateDER:nonce:)` + `LinkIdentity`.
    public static func apply(pairingCode: String, to options: NWProtocolQUIC.Options) throws {
        let sec = options.securityProtocolOptions
        let key = try derivePSK(code: pairingCode)
        let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data(pskIdentity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(sec,
                                                psk as __DispatchData,
                                                identity as __DispatchData)
        sec_protocol_options_set_tls_pre_shared_key_identity_hint(sec, identity as __DispatchData)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13) // QUIC is 1.3-only anyway
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv13)
        sec_protocol_options_append_tls_ciphersuite(sec, .AES_128_GCM_SHA256)
    }
}
