import CryptoKit
import Foundation
import Security

/// Server TLS identity for the pairing flow (Mac side).
///
/// QUIC mandates TLS 1.3, and Network.framework does not support TLS-1.3
/// external PSKs (verified empirically 2026-07-07: `sec_protocol_options_add_
/// pre_shared_key` handshakes fine when pinned to TLS 1.2 + suite 0x00A8 over
/// TCP, fails with -9858 when pinned to TLS 1.3, and hangs over QUIC in every
/// variant — with/without ciphersuite append, version pins, and the PSK
/// selection block). So the listener authenticates with a **self-signed
/// ECDSA-P256 certificate generated on device**, and the pairing code
/// authenticates the session one layer up (`LinkPairing.pairingProof` inside
/// the device's hello, channel-bound to this certificate).
///
/// The identity is **ephemeral by design**: regenerated on every
/// `createEphemeral()` call (i.e. every server start). Rationale: macOS
/// keychain ACLs bind a private key to the exact code signature that created
/// it, and Debug builds are ad-hoc signed — a persisted key would trigger
/// keychain prompts (or silent failures) after every rebuild.
///
/// WHERE THE KEY LIVES — an app-private keychain, NEVER login (2026-07-13).
/// `SecIdentityCreateWithCertificate` needs a keychain-resident private key,
/// but storing it in the DEFAULT (login) keychain via `kSecAttrIsPermanent`
/// made every run of an ad-hoc-signed Debug build pop the macOS
/// "Prism wants to sign using key … enter the login keychain password"
/// prompt (the login keychain is locked / signature-mismatched). Since the
/// identity is ephemeral it must never touch login. So `createEphemeral()`
/// mints the key + cert inside a **temporary keychain this process fully
/// owns** — created UNLOCKED with an app-generated random password (never the
/// user's), set to never auto-lock, kept OUT of the user's search list, and
/// searched explicitly. `SecIdentityCreateWithCertificate` still gets a
/// keychain-resident key, but from a keychain that requires no user prompt.
/// The whole keychain (key + cert + file) is deleted on regeneration/stop.
/// The cert/key material and TLS handshake are unchanged — only the STORAGE
/// LOCATION moved (login → app-private keychain).
///
/// INTERACTION WITH TOFU PINNING (`TrustedServerStore`): because this
/// identity is regenerated per server start, a device that pinned the SPKI
/// will see a pin MISMATCH after the Mac restarts its server — that is a
/// true statement ("not the same key as last time"), and the app resolves it
/// by an explicit user re-pair, never silently. Persisting the identity
/// would be what makes the pin survive restarts.
/// TODO(pairing-v2): persist the identity once real signing exists.
public enum LinkIdentity {

    public enum IdentityError: Error {
        case keyGeneration(String)
        case certificateEncoding
        case keychain(OSStatus)
        /// Programmatic identity creation is implemented for macOS only
        /// (devices are always the TLS client and need no identity).
        case unsupportedPlatform
    }

    /// Keychain label owning every item this type creates.
    static let keychainLabel = "Prism Link (ephemeral)"

    #if os(macOS)
    /// Serializes teardown/creation of the process-wide app-private keychain.
    private static let lock = NSLock()
    /// The temporary, app-private keychain currently holding the ephemeral
    /// key + cert (nil when no server owns an identity). Deleted wholesale on
    /// regeneration/stop.
    nonisolated(unsafe) private static var activeKeychain: SecKeychain?
    nonisolated(unsafe) private static var activeKeychainPath: String?

    /// Tears down any prior ephemeral keychain, generates a fresh P-256 key +
    /// self-signed certificate inside a **temporary, app-private keychain**
    /// (created UNLOCKED with an app-generated random password, never the
    /// user's login keychain), and returns the identity.
    ///
    /// `SecIdentityCreateWithCertificate` still needs a keychain-resident
    /// private key, but this keychain requires NO user prompt: it is created
    /// unlocked, set never to auto-lock, kept out of the default search list,
    /// and searched explicitly — so signing never routes through the login
    /// keychain (which is what popped the password prompt on ad-hoc-signed
    /// Debug builds). See the type doc comment for the full rationale.
    public static func createEphemeral() throws -> SecIdentity {
        lock.lock()
        defer { lock.unlock() }
        teardownLocked()

        // 1. A temporary keychain this process fully owns, unlocked with a
        //    random app-generated password (never the user's).
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismLink-\(UUID().uuidString).keychain-db").path
        var password = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, password.count, &password) == errSecSuccess else {
            throw IdentityError.keyGeneration("SecRandomCopyBytes failed for keychain password")
        }
        var keychainRef: SecKeychain?
        let createStatus = path.withCString { cPath in
            SecKeychainCreate(cPath, UInt32(password.count), password, false, nil, &keychainRef)
        }
        guard createStatus == errSecSuccess, let keychain = keychainRef else {
            throw IdentityError.keychain(createStatus)
        }
        activeKeychain = keychain
        activeKeychainPath = path
        // Never auto-lock: a locked keychain is exactly what would re-introduce
        // an unlock prompt mid-session (SecKeychainCreate leaves it unlocked).
        var settings = SecKeychainSettings()
        settings.version = 1
        settings.lockOnSleep = false
        settings.useLockInterval = false
        settings.lockInterval = .max
        SecKeychainSetSettings(keychain, &settings)
        // Keep it OUT of the user's default search list — this keychain is only
        // ever searched explicitly (below); it must not surface in the user's
        // Keychain Access UI or other apps' lookups.
        removeFromDefaultSearchList(keychain)

        // 2. Fresh P-256 key. Generated non-permanent (touches NO keychain),
        //    then added to the app-private keychain only.
        var error: Unmanaged<CFError>?
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: false,
        ]
        guard let privateKey = SecKeyCreateRandomKey(keyAttrs as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw IdentityError.keyGeneration(String(describing: error?.takeRetainedValue()))
        }

        let der = try selfSignedCertificate(publicKeyX963: publicData, signWith: privateKey)
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw IdentityError.certificateEncoding
        }

        // Persist the key into the app-private keychain (kSecUseKeychain
        // directs the add; without kSecAttrIsPermanent the key was in-memory).
        let addKey: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: privateKey,
            kSecUseKeychain as String: keychain,
            kSecAttrLabel as String: keychainLabel,
        ]
        let keyStatus = SecItemAdd(addKey as CFDictionary, nil)
        guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem else {
            throw IdentityError.keychain(keyStatus)
        }
        let addCert: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecUseKeychain as String: keychain,
            kSecAttrLabel as String: keychainLabel,
        ]
        let addStatus = SecItemAdd(addCert as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw IdentityError.keychain(addStatus)
        }

        // 3. Build the identity, searching ONLY the app-private keychain.
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(keychain, certificate, &identity)
        guard status == errSecSuccess, let identity else {
            throw IdentityError.keychain(status)
        }
        return identity
    }

    /// Removes the app-private ephemeral keychain (key + cert + its file) and
    /// sweeps any legacy items a prior Prism version left in the login/default
    /// keychain. Call when the identity is no longer in use (`LinkServer.stop()`
    /// does). Idempotent.
    public static func removeEphemeral() {
        lock.lock()
        defer { lock.unlock() }
        teardownLocked()
    }

    /// Caller holds `lock`. Deletes the current app-private keychain outright
    /// and sweeps any legacy login-keychain residue.
    private static func teardownLocked() {
        if let keychain = activeKeychain {
            SecKeychainDelete(keychain) // removes from search list + deletes the file
        }
        if let path = activeKeychainPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        activeKeychain = nil
        activeKeychainPath = nil
        deleteLegacyLoginKeychainItems()
    }

    /// Best-effort removal of ephemeral key/cert items a PRIOR Prism version
    /// stored in the login/default keychain (the old `kSecAttrIsPermanent`
    /// path). Upgrading users get that login-keychain residue cleaned up.
    ///
    /// Two verified macOS gotchas (2026-07-07, this machine):
    ///  - the file-based keychain's `SecItemDelete` removes ONE matching item
    ///    per call, so a single call leaks under accumulation — loop until
    ///    `errSecItemNotFound`;
    ///  - `SecItemAdd` for a CERTIFICATE ignores `kSecAttrLabel` and stores
    ///    it under a label derived from the subject CN ("Prism"), so the
    ///    label query never matched a cert. Match instead by "self-signed
    ///    with subject summary Prism" — exactly the shape this type mints.
    private static func deleteLegacyLoginKeychainItems() {
        let keyQuery: [String: Any] = [kSecClass as String: kSecClassKey,
                                       kSecAttrLabel as String: keychainLabel]
        var iterations = 0
        while SecItemDelete(keyQuery as CFDictionary) == errSecSuccess, iterations < 1024 {
            iterations += 1
        }

        let certQuery: [String: Any] = [kSecClass as String: kSecClassCertificate,
                                        kSecMatchLimit as String: kSecMatchLimitAll,
                                        kSecReturnRef as String: true]
        var found: CFTypeRef?
        guard SecItemCopyMatching(certQuery as CFDictionary, &found) == errSecSuccess,
              let certs = found as? [SecCertificate] else { return }
        for cert in certs where isEphemeralPrismCertificate(cert) {
            SecItemDelete([kSecClass as String: kSecClassCertificate,
                           kSecValueRef as String: cert] as CFDictionary)
        }
    }

    /// Removes `keychain` from the user's default keychain search list if
    /// `SecKeychainCreate` added it, leaving the rest of the list untouched.
    private static func removeFromDefaultSearchList(_ keychain: SecKeychain) {
        var listRef: CFArray?
        guard SecKeychainCopySearchList(&listRef) == errSecSuccess,
              let list = listRef as? [SecKeychain] else { return }
        let filtered = list.filter { $0 !== keychain }
        if filtered.count != list.count {
            SecKeychainSetSearchList(filtered as CFArray)
        }
    }

    /// True for the exact shape `selfSignedCertificate` mints: subject
    /// summary "Prism" AND issuer == subject (self-signed). A user's real
    /// certificate that merely mentions Prism is CA-issued and won't match.
    private static func isEphemeralPrismCertificate(_ cert: SecCertificate) -> Bool {
        guard SecCertificateCopySubjectSummary(cert) as String? == "Prism",
              let subject = SecCertificateCopyNormalizedSubjectSequence(cert),
              let issuer = SecCertificateCopyNormalizedIssuerSequence(cert) else { return false }
        return (subject as Data) == (issuer as Data)
    }

    #if DEBUG
    /// Test seam: the app-private keychain currently backing the identity
    /// (nil when none), so tests can assert it is unlocked + app-owned. Not
    /// part of the shipping API.
    static var _activeEphemeralKeychainForTesting: SecKeychain? {
        lock.lock(); defer { lock.unlock() }
        return activeKeychain
    }
    #endif
    #else
    public static func createEphemeral() throws -> SecIdentity {
        throw IdentityError.unsupportedPlatform
    }

    /// No keychain identity is ever created off-macOS; nothing to remove.
    public static func removeEphemeral() {}
    #endif

    /// The identity's leaf certificate in DER form — the byte string the
    /// pairing proof is bound to on both sides.
    public static func certificateDER(of identity: SecIdentity) -> Data? {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else { return nil }
        return SecCertificateCopyData(certificate) as Data
    }

    // MARK: Minimal X.509 (exactly one shape: self-signed ECDSA-P256-SHA256)

    static func selfSignedCertificate(publicKeyX963: Data, signWith key: SecKey) throws -> Data {
        let ecdsaWithSHA256 = derSequence([derOID([1, 2, 840, 10045, 4, 3, 2])])
        let name = derSequence([derTag(0x31, derSequence([derOID([2, 5, 4, 3]),
                                                          derTag(0x0C, Data("Prism".utf8))]))])
        let spki = derSequence([
            derSequence([derOID([1, 2, 840, 10045, 2, 1]),      // id-ecPublicKey
                         derOID([1, 2, 840, 10045, 3, 1, 7])]), // prime256v1
            derBitString(publicKeyX963),
        ])
        // Serial: random, positive, non-zero; `derInteger` canonicalizes to
        // minimal DER (strips redundant leading 0x00 bytes — A7).
        var serial = (0..<8).map { _ in UInt8.random(in: 0...255) }
        serial[0] &= 0x7F // keep the INTEGER positive
        if serial.allSatisfy({ $0 == 0 }) { serial[7] = 1 } // RFC 5280: serial > 0
        let now = Date()
        let tbs = derSequence([
            derTag(0xA0, derInteger([2])), // version v3
            derInteger(serial),
            ecdsaWithSHA256,
            name,                          // issuer == subject (self-signed)
            derSequence([derTime(now.addingTimeInterval(-86_400)),
                         derTime(now.addingTimeInterval(86_400 * 365 * 10))]),
            name,
            spki,
        ])
        var error: Unmanaged<CFError>?
        // .ecdsaSignatureMessageX962SHA256 emits the DER-encoded ECDSA-Sig-Value
        // X.509 expects inside the signature BIT STRING.
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256,
                                                    tbs as CFData, &error) as Data? else {
            throw IdentityError.keyGeneration(String(describing: error?.takeRetainedValue()))
        }
        return derSequence([tbs, ecdsaWithSHA256, derBitString(signature)])
    }

    // MARK: DER primitives (pure)

    static func derLength(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func derTag(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        out.append(derLength(content.count))
        out.append(content)
        return out
    }

    static func derSequence(_ parts: [Data]) -> Data {
        derTag(0x30, parts.reduce(Data(), +))
    }

    /// Canonical (minimal) DER INTEGER for a non-negative value: redundant
    /// leading 0x00 bytes are stripped (keeping one only when needed to mark
    /// the value positive), and a set high bit gets a 0x00 prefix (A7).
    static func derInteger(_ bytes: [UInt8]) -> Data {
        var content = bytes
        while content.count > 1, content[0] == 0, content[1] & 0x80 == 0 {
            content.removeFirst()
        }
        if content.isEmpty { content = [0] }
        if content[0] & 0x80 != 0 {
            content.insert(0, at: 0) // avoid negative interpretation
        }
        return derTag(0x02, Data(content))
    }

    static func derOID(_ oid: [UInt64]) -> Data {
        var content = Data([UInt8(oid[0] * 40 + oid[1])])
        for value in oid.dropFirst(2) {
            var chunk: [UInt8] = []
            var v = value
            repeat {
                chunk.insert(UInt8(v & 0x7F), at: 0)
                v >>= 7
            } while v > 0
            for i in 0..<(chunk.count - 1) { chunk[i] |= 0x80 }
            content.append(contentsOf: chunk)
        }
        return derTag(0x06, content)
    }

    /// RFC 5280 §4.1.2.5: dates through 2049 MUST be UTCTime (2-digit year);
    /// dates in 2050 or later MUST be GeneralizedTime (4-digit year) — the
    /// old UTCTime-always encoding silently wrapped ≥2050 into 19xx (A9).
    static func derTime(_ date: Date) -> Data {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let formatter = DateFormatter()
        formatter.timeZone = utc.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if utc.component(.year, from: date) >= 2050 {
            formatter.dateFormat = "yyyyMMddHHmmss'Z'"
            return derTag(0x18, Data(formatter.string(from: date).utf8)) // GeneralizedTime
        }
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return derTag(0x17, Data(formatter.string(from: date).utf8)) // UTCTime
    }

    static func derBitString(_ data: Data) -> Data {
        derTag(0x03, Data([0]) + data) // zero unused bits
    }
}
