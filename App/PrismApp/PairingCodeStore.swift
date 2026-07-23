import Foundation

/// Phase 5b: Keychain-backed persistence for the Mac's Link pairing code (the
/// v1 PSK bootstrap). Previously the code sat in `UserDefaults` as plaintext —
/// wrong for a shared secret. It now lives in the Keychain (REUSING
/// `KeychainStore`, the same helper the stream keys use). Any legacy value
/// still in `UserDefaults` is migrated into the Keychain on load, then the
/// `UserDefaults` entry is removed so the secret no longer lingers in prefs.
///
/// The Keychain read/write are injectable seams so the migration logic can be
/// exercised headlessly (the live Keychain isn't writable under ad-hoc signing).
enum PairingCodeStore {
    /// Keychain account for the Mac-side pairing code.
    static let account = "studio.prism.link.pairingCode"
    /// Legacy `UserDefaults` key — migrated into the Keychain, then removed.
    static let legacyDefaultsKey = "studio.prism.link.pairingCode"

    // Test seams (default = the real Keychain).
    static var keychainGet: (_ account: String) -> String? = { KeychainStore.get($0) }
    static var keychainSet: (_ value: String, _ account: String) -> Bool = {
        KeychainStore.set($0, for: $1)
    }

    /// Return the persisted pairing code: a valid Keychain value if present;
    /// otherwise a valid legacy `UserDefaults` value MIGRATED into the Keychain
    /// (and cleared from defaults); otherwise a freshly `generate()`d code
    /// stored in the Keychain. `isValid` gates a stored value (a malformed one
    /// is replaced); `normalize` canonicalizes what is returned.
    static func loadOrCreate(defaults: UserDefaults = .standard,
                             generate: () -> String,
                             normalize: (String) -> String,
                             isValid: (String) -> Bool) -> String {
        if let stored = keychainGet(account), isValid(stored) {
            return normalize(stored)
        }
        // Legacy plaintext code in UserDefaults → migrate into the Keychain once.
        if let legacy = defaults.string(forKey: legacyDefaultsKey), isValid(legacy) {
            let normalized = normalize(legacy)
            _ = keychainSet(normalized, account)
            defaults.removeObject(forKey: legacyDefaultsKey)
            return normalized
        }
        let code = generate()
        _ = keychainSet(code, account)
        // Belt-and-suspenders: ensure no stale plaintext remains in defaults.
        defaults.removeObject(forKey: legacyDefaultsKey)
        return code
    }
}
