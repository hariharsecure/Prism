import XCTest

@testable import PrismCore

/// Unit tests for the pure OSLog redaction helpers. We can't assert on OSLog's
/// rendered output directly, so we test the pure functions the log sites call:
/// `hashID` (stable + non-reversible-looking) and `basename` (strips directories).
final class LogRedactTests: XCTestCase {

    // MARK: - hashID

    /// Same input → same tag, so a hashed ID still correlates across log lines.
    func testHashIDIsStable() {
        let uid = "0x1a2b3c4d-Camera-BuiltIn"
        XCTAssertEqual(LogRedact.hashID(uid), LogRedact.hashID(uid))
    }

    /// Different inputs → different tags (no trivial collision on realistic IDs).
    func testHashIDDistinguishesInputs() {
        XCTAssertNotEqual(LogRedact.hashID("device-A-uniqueID"),
                          LogRedact.hashID("device-B-uniqueID"))
    }

    /// Non-reversible-looking: the raw identifier is NEVER a substring of the tag.
    func testHashIDDoesNotContainInput() {
        let secrets = ["47C8B2FA-1234-5678-9ABC-DEF012345678",
                       "the operator-iPhone-uniqueID",
                       "AppleUSBAudio:1a2b"]
        for s in secrets {
            let tag = LogRedact.hashID(s)
            XCTAssertFalse(tag.contains(s), "hashID leaked the raw input: \(tag)")
            // Also ensure no long fragment of the input survives.
            XCTAssertFalse(tag.lowercased().contains(s.prefix(6).lowercased()),
                           "hashID leaked an input fragment: \(tag)")
        }
    }

    /// The tag is a short, fixed-shape hex string (`#` + N hex chars).
    func testHashIDShape() {
        let tag = LogRedact.hashID("anything", length: 12)
        XCTAssertEqual(tag.count, 13)                     // "#" + 12 hex
        XCTAssertTrue(tag.hasPrefix("#"))
        let hex = tag.dropFirst()
        XCTAssertTrue(hex.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(hex.count, 12)
    }

    /// A custom length is honored (and clamped to at least 1 char).
    func testHashIDLengthParameter() {
        XCTAssertEqual(LogRedact.hashID("x", length: 8).dropFirst().count, 8)
        XCTAssertEqual(LogRedact.hashID("x", length: 0).dropFirst().count, 1)
    }

    // MARK: - basename

    /// A full local path collapses to its last component only.
    func testBasenameStripsDirectories() {
        XCTAssertEqual(
            LogRedact.basename("/Users/alex/Library/Application Support/Prism/sounds/kick_0007.wav"),
            "kick_0007.wav")
        XCTAssertEqual(LogRedact.basename("/var/folders/xy/z/library.json"), "library.json")
    }

    /// The parent directories never survive redaction (no leak of the user's home).
    func testBasenameDropsHomeDirectory() {
        let out = LogRedact.basename("/Users/alex/secret/place/file.wav")
        XCTAssertFalse(out.contains("june"))
        XCTAssertFalse(out.contains("/"))
    }

    /// A bare filename passes through unchanged.
    func testBasenameOnBareName() {
        XCTAssertEqual(LogRedact.basename("library.json"), "library.json")
    }
}
