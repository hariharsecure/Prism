import CryptoKit
import Foundation

// MARK: - TrustedServerStore (A1: TOFU pinning seam)

/// Persistence seam for trust-on-first-use server pinning.
///
/// The pairing TLS layer historically accepted ANY server certificate when a
/// pairing code was set ("accept any cert forever"). This store turns that
/// into TOFU: on the FIRST successful pairing for a code, `LinkClient` stores
/// the SHA-256 of the server leaf certificate's SubjectPublicKeyInfo (SPKI),
/// keyed by the normalized pairing code; every reconnect for that code then
/// requires the presented certificate's SPKI hash to match, and a mismatch is
/// rejected with a distinct error (`LinkClient.TrustError`).
///
/// HONEST SCOPE: first contact remains unauthenticated — the device cannot
/// distinguish the real Mac from an impostor the very first time it pairs
/// with a code. TOFU only guarantees "the same server as last time".
///
/// The default is `InMemoryTrustedServerStore` (pins survive reconnects
/// within one process, not relaunch). The app should supply a persistent
/// implementation — e.g. UserDefaults- or file-backed — via
/// `LinkClient.Configuration.trustedServerStore` so pins survive relaunch.
public protocol TrustedServerStore: AnyObject, Sendable {
    /// The pinned SPKI-SHA256 for a normalized pairing code, or nil if this
    /// code has never completed a pairing.
    func trustedSPKIHash(forCode normalizedCode: String) -> Data?
    /// Pin (or re-pin, e.g. after the user explicitly resets trust) the
    /// SPKI-SHA256 for a normalized pairing code.
    func setTrustedSPKIHash(_ hash: Data, forCode normalizedCode: String)
}

/// Default in-process store: thread-safe, nothing persisted to disk.
public final class InMemoryTrustedServerStore: TrustedServerStore, @unchecked Sendable {
    private let lock = NSLock()
    private var hashesByCode: [String: Data] = [:]

    public init() {}

    public func trustedSPKIHash(forCode normalizedCode: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return hashesByCode[normalizedCode]
    }

    public func setTrustedSPKIHash(_ hash: Data, forCode normalizedCode: String) {
        lock.lock()
        defer { lock.unlock() }
        hashesByCode[normalizedCode] = hash
    }
}

// MARK: - SPKI extraction (pure DER walk)

/// Certificate-trust helpers shared by pinning code on both sides.
public enum ServerTrust {

    /// SHA-256 of the SubjectPublicKeyInfo element (full TLV bytes) of an
    /// X.509 certificate in DER form. Pure structural walk — no Security
    /// framework, so it is deterministic and testable off-keychain:
    ///
    ///     Certificate ::= SEQUENCE { tbsCertificate, sigAlg, sigValue }
    ///     TBSCertificate ::= SEQUENCE { [0] version?, serialNumber,
    ///         signature, issuer, validity, subject, subjectPublicKeyInfo, … }
    ///
    /// Returns nil for anything that doesn't parse as that shape; callers
    /// MUST treat nil as a verification failure (never "skip pinning").
    public static func spkiSHA256(fromCertificateDER der: Data) -> Data? {
        let bytes = [UInt8](der)
        // Outer Certificate SEQUENCE.
        guard let cert = parseTLV(bytes, at: 0), cert.tag == 0x30 else { return nil }
        // TBSCertificate SEQUENCE.
        guard let tbs = parseTLV(bytes, at: cert.contentStart), tbs.tag == 0x30 else { return nil }
        var offset = tbs.contentStart
        let tbsEnd = tbs.contentStart + tbs.contentLength
        // Optional [0] EXPLICIT version.
        if let first = parseTLV(bytes, at: offset), first.tag == 0xA0 {
            offset = first.end
        }
        // serialNumber, signature, issuer, validity, subject — skip 5 elements.
        for _ in 0..<5 {
            guard let element = parseTLV(bytes, at: offset), element.end <= tbsEnd else { return nil }
            offset = element.end
        }
        // subjectPublicKeyInfo — hash its FULL TLV (tag + length + content).
        guard let spki = parseTLV(bytes, at: offset), spki.tag == 0x30, spki.end <= tbsEnd else {
            return nil
        }
        return Data(SHA256.hash(data: Data(bytes[offset..<spki.end])))
    }

    private struct TLV {
        let tag: UInt8
        let contentStart: Int
        let contentLength: Int
        var end: Int { contentStart + contentLength }
    }

    /// Reads one DER TLV (single-byte tag, short or long definite length)
    /// starting at `offset`. Returns nil on truncation/indefinite length.
    private static func parseTLV(_ bytes: [UInt8], at offset: Int) -> TLV? {
        guard offset + 2 <= bytes.count else { return nil }
        let tag = bytes[offset]
        let first = bytes[offset + 1]
        var contentStart = offset + 2
        var length = Int(first)
        if first & 0x80 != 0 {
            let count = Int(first & 0x7F)
            guard count > 0, count <= 8, contentStart + count <= bytes.count else { return nil }
            length = 0
            for i in 0..<count {
                length = (length << 8) | Int(bytes[contentStart + i])
            }
            contentStart += count
        }
        guard length >= 0, contentStart + length <= bytes.count else { return nil }
        return TLV(tag: tag, contentStart: contentStart, contentLength: length)
    }
}
