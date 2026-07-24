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
///
/// DEV-BUILD BYPASS (#if DEBUG): an ad-hoc/unsigned build gets a NEW code
/// signature on every rebuild, so a Keychain ACL never sticks — macOS re-prompts
/// for the login password (and can hang launch on the ACL dialog) every time the
/// app reads an item a previous build wrote. That is pure friction with zero
/// benefit during development. So Debug builds store these values in a plain file
/// inside the app-support container and never touch the Keychain at all. A real
/// Developer-ID (Release) build uses the Keychain, where the grant is stable.
enum KeychainStore {
    private static let service = "studio.prism.app.streamkeys"

    /// Fixed account for the single-RTMP "quick path" primary stream key.
    static let primaryStreamKeyAccount = "primary.rtmp.streamkey"

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        guard !value.isEmpty else { remove(account); return true }
        #if DEBUG
        var d = devLoad(); d[account] = value; devSave(d); return true
        #else
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
        #endif
    }

    /// Whether the credential store is actually writable in this run.
    static var isAvailable: Bool {
        #if DEBUG
        return devFileURL != nil
        #else
        let probe = "studio.prism.app.kc-probe"
        let ok = set("1", for: probe)
        if ok { remove(probe) }
        return ok
        #endif
    }

    /// Read a secret, or nil if none is stored (or the store is unavailable).
    static func get(_ account: String) -> String? {
        #if DEBUG
        return devLoad()[account]
        #else
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
        #endif
    }

    /// Delete a stored secret (no-op if absent).
    static func remove(_ account: String) {
        #if DEBUG
        var d = devLoad(); d[account] = nil; devSave(d)
        #else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        #endif
    }

    // MARK: Debug file-backed store (never touches the Keychain)
    #if DEBUG
    /// `~/Library/Application Support/Prism/dev-credentials.json` — dev only.
    private static let devFileURL: URL? = {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("Prism", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dev-credentials.json")
    }()

    private static func devLoad() -> [String: String] {
        guard let url = devFileURL, let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    private static func devSave(_ dict: [String: String]) {
        guard let url = devFileURL, let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: url, options: [.atomic])
    }
    #endif
}
