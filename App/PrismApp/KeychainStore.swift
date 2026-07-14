import Foundation
import Security

/// Codex #8: stream secrets (RTMP stream keys / SRT streamids, and the primary
/// RTMP key) must NOT sit in plaintext in `StreamDestinations.json` or in the
/// `UserDefaults`-backed `@AppStorage`. This is a tiny generic-password Keychain
/// helper: the JSON / defaults hold only a REFERENCE (the destination `id`, or a
/// fixed account for the primary key); the secret itself lives in the Keychain.
///
/// All operations fail soft (a Keychain that is unavailable — e.g. an unsigned
/// headless run — returns nil / silently no-ops) so a missing secret degrades to
/// "no key configured" rather than crashing or blocking the app.
enum KeychainStore {
    private static let service = "studio.prism.app.streamkeys"

    /// Fixed account for the single-RTMP "quick path" primary stream key.
    static let primaryStreamKeyAccount = "primary.rtmp.streamkey"

    /// Store (or update) a secret for `account`. An empty value removes the item
    /// so we never persist a stale/blank entry. Returns whether the write
    /// actually succeeded — callers MUST NOT delete the plaintext fallback on a
    /// failed write (Codex #8 re-verify: under ad-hoc/no-entitlement signing the
    /// write can silently fail; discarding the status lost the key on relaunch).
    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        guard !value.isEmpty else { remove(account); return true }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    /// Whether the Keychain is actually writable in this run (probe once). Under
    /// ad-hoc signing it often isn't, in which case callers keep the plaintext
    /// fallback rather than migrating into a black hole.
    static var isAvailable: Bool {
        let probe = "studio.prism.app.kc-probe"
        let ok = set("1", for: probe)
        if ok { remove(probe) }
        return ok
    }

    /// Read a secret, or nil if none is stored (or the Keychain is unavailable).
    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    /// Delete a stored secret (no-op if absent).
    static func remove(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
