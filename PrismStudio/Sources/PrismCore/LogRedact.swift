import CryptoKit
import Foundation

/// Pure, non-reversible-looking redaction helpers for privacy-safe OSLog output.
///
/// OSLog interpolations that would otherwise publish a hardware UID, a device
/// name, a full filesystem path, or a rotating presence token get run through
/// these first (or marked `.private`). Hashing keeps a value *correlatable*
/// across log lines — the same input always yields the same short tag — without
/// exposing the raw identifier, so e.g. `capture.devices` can still tell "the
/// same camera reconnected" without ever publishing its real `uniqueID`.
///
/// Everything here is a pure function of its input (no I/O, no global state), so
/// it is trivially unit-testable and safe to call from any thread.
public enum LogRedact {
    /// A stable, short, non-reversible-looking tag for an identifier.
    ///
    /// The same input always maps to the same tag (correlatable across lines);
    /// the raw input is never a substring of the output (SHA-256 → hex prefix).
    /// Intended for hardware UIDs or any stable ID you want to follow across log
    /// lines but must not leak. Prefixed with `#` so a redacted tag is visually
    /// distinct from a raw value in the log.
    ///
    /// - Parameter length: number of hex characters to keep (default 12 → 48
    ///   bits, ample to distinguish the handful of devices on one machine).
    public static func hashID(_ id: some StringProtocol, length: Int = 12) -> String {
        let digest = SHA256.hash(data: Data(String(id).utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "#" + String(hex.prefix(max(1, length)))
    }

    /// The final path component only — every parent directory is dropped — so a
    /// full local path never reaches a public log.
    /// `/Users/alex/Library/Application Support/…/kick_0007.wav` → `kick_0007.wav`.
    public static func basename(_ path: some StringProtocol) -> String {
        (String(path) as NSString).lastPathComponent
    }
}
