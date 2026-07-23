import PrismOutput
import XCTest
@testable import Prism

/// Phase 5 (app security) contracts, reproduce-first:
///
/// 5a — FAIL-CLOSED STREAM KEYS: a stream key is a credential. `StreamDestinationsStore`
///   must NEVER persist it as plaintext in the JSON — not even when the Keychain
///   write fails. THE BUG it guards: the old code fell back to writing the key as
///   plaintext into `StreamDestinations.json` on a Keychain write failure, so a
///   screen-shared setup leaked the key. THE FIX: fail closed — blank the JSON key
///   unconditionally, keep the unsaved key in memory only, surface a warning.
///   The legacy-plaintext → Keychain load-time migration must still run.
///
/// 5b — PAIRING CODE → KEYCHAIN: the Link pairing code (the PSK) moved out of
///   `UserDefaults` into the Keychain (via `PairingCodeStore`, reusing
///   `KeychainStore`); a legacy `UserDefaults` value is migrated in and cleared.
///   The `PRISM_LINK_STATE_FILE` debug export must OMIT the code.
///
/// The live Keychain isn't writable under ad-hoc/headless signing, so the stores
/// expose injectable Keychain seams that these tests drive with in-memory fakes.
@MainActor
final class Phase5AppSecTests: XCTestCase {

    // MARK: Fixture helpers

    private func tempFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-p5-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Decode the persisted JSON to `[[String: Any]]` for field-level assertions.
    private func rows(of url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    override func tearDown() {
        // Restore the real Keychain seams after any test swapped them.
        StreamDestinationsStore.keychainSet = { KeychainStore.set($0, for: $1) }
        StreamDestinationsStore.keychainGet = { KeychainStore.get($0) }
        PairingCodeStore.keychainSet = { KeychainStore.set($0, for: $1) }
        PairingCodeStore.keychainGet = { KeychainStore.get($0) }
        super.tearDown()
    }

    // MARK: 5a — fail-closed stream keys

    /// Reproduce-first: even when the Keychain WRITE FAILS, no plaintext key may
    /// land in the JSON. The `key` field is empty and a warning is surfaced.
    func testFailClosedLeavesNoPlaintextKeyInJSONOnKeychainFailure() throws {
        StreamDestinationsStore.keychainSet = { _, _ in false } // simulate failure
        let secret = "SUPERSECRET-STREAM-KEY-123"
        let dest = Destination(name: "YouTube", proto: .rtmp,
                               url: "rtmp://a.rtmp.youtube.com/live2", key: secret)
        let url = tempFile()

        try StreamDestinationsStore.save([dest], to: url)

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains(secret),
                       "fail-closed: the plaintext key must NOT appear in the JSON")
        let row = try XCTUnwrap(rows(of: url).first)
        XCTAssertEqual(row["key"] as? String, "",
                       "the JSON key field must be empty even on a Keychain write failure")
        XCTAssertNotNil(StreamDestinationsStore.lastError,
                        "a Keychain write failure must surface a warning")
        XCTAssertTrue(StreamDestinationsStore.lastError?.contains("YouTube") ?? false,
                      "the warning names the affected destination")
    }

    /// The success path is unchanged: the key goes to the (fake) Keychain and the
    /// JSON stays empty, with no warning.
    func testSuccessfulSaveKeepsKeyOutOfJSONAndClearsWarning() throws {
        var keychain: [String: String] = [:]
        StreamDestinationsStore.keychainSet = { keychain[$1] = $0; return true }
        let dest = Destination(name: "Twitch", proto: .rtmp,
                               url: "rtmp://live.twitch.tv/app", key: "tw-key-9")
        let url = tempFile()

        try StreamDestinationsStore.save([dest], to: url)

        XCTAssertEqual(keychain[dest.id.uuidString], "tw-key-9", "secret stored in the Keychain")
        let row = try XCTUnwrap(rows(of: url).first)
        XCTAssertEqual(row["key"] as? String, "", "JSON key stays empty on success")
        XCTAssertNil(StreamDestinationsStore.lastError, "a clean save clears the warning")
    }

    /// The load-time legacy-plaintext migration MUST still run: a legacy file with
    /// a plaintext key migrates it INTO the Keychain on load, and the next save
    /// empties the JSON.
    func testLegacyPlaintextKeyMigratesIntoKeychainThenEmptiesJSON() throws {
        var keychain: [String: String] = [:]
        StreamDestinationsStore.keychainGet = { keychain[$0] }
        StreamDestinationsStore.keychainSet = { keychain[$1] = $0; return true }

        let id = UUID()
        let legacyKey = "LEGACY-PLAINTEXT-KEY"
        let legacyJSON = """
        [{"id":"\(id.uuidString)","name":"YT","proto":"rtmp",\
        "url":"rtmp://a/live","key":"\(legacyKey)","enabled":true}]
        """
        let url = tempFile()
        try legacyJSON.write(to: url, atomically: true, encoding: .utf8)

        // Load migrates the plaintext key into the Keychain and returns it.
        let loaded = StreamDestinationsStore.load(from: url)
        XCTAssertEqual(loaded.first?.key, legacyKey, "load surfaces the legacy key")
        XCTAssertEqual(keychain[id.uuidString], legacyKey,
                       "legacy plaintext key migrated INTO the Keychain on load")

        // Next save drops the plaintext from the JSON.
        try StreamDestinationsStore.save(loaded, to: url)
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains(legacyKey), "the legacy plaintext is cleared from JSON on save")
        let row = try XCTUnwrap(rows(of: url).first)
        XCTAssertEqual(row["key"] as? String, "")
    }

    // MARK: 5b — pairing code lives in the Keychain

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "phase5-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// A fresh install with no legacy value: the generated code is stored in the
    /// Keychain (not UserDefaults).
    func testFreshPairingCodeStoredInKeychainNotUserDefaults() {
        var keychain: [String: String] = [:]
        PairingCodeStore.keychainGet = { keychain[$0] }
        PairingCodeStore.keychainSet = { keychain[$1] = $0; return true }
        let defaults = ephemeralDefaults()

        let code = PairingCodeStore.loadOrCreate(
            defaults: defaults,
            generate: { "GENCODE0" },
            normalize: { $0 },
            isValid: { !$0.isEmpty })

        XCTAssertEqual(code, "GENCODE0")
        XCTAssertEqual(keychain[PairingCodeStore.account], "GENCODE0", "stored in the Keychain")
        XCTAssertNil(defaults.string(forKey: PairingCodeStore.legacyDefaultsKey),
                     "nothing left in UserDefaults")
    }

    /// A legacy code sitting in UserDefaults migrates INTO the Keychain and is
    /// removed from UserDefaults; a subsequent load reads from the Keychain and
    /// does NOT regenerate.
    func testLegacyPairingCodeMigratesOutOfUserDefaultsIntoKeychain() {
        var keychain: [String: String] = [:]
        PairingCodeStore.keychainGet = { keychain[$0] }
        PairingCodeStore.keychainSet = { keychain[$1] = $0; return true }
        let defaults = ephemeralDefaults()
        defaults.set("LEGACY12", forKey: PairingCodeStore.legacyDefaultsKey)

        let code = PairingCodeStore.loadOrCreate(
            defaults: defaults,
            generate: { "SHOULD-NOT-GENERATE" },
            normalize: { $0 },
            isValid: { !$0.isEmpty })

        XCTAssertEqual(code, "LEGACY12", "the legacy code is returned, not a fresh one")
        XCTAssertEqual(keychain[PairingCodeStore.account], "LEGACY12",
                       "legacy code migrated INTO the Keychain")
        XCTAssertNil(defaults.string(forKey: PairingCodeStore.legacyDefaultsKey),
                     "legacy code removed from UserDefaults")

        // Second load: served from the Keychain, generator must not run.
        let again = PairingCodeStore.loadOrCreate(
            defaults: defaults,
            generate: { XCTFail("must not regenerate"); return "X" },
            normalize: { $0 },
            isValid: { !$0.isEmpty })
        XCTAssertEqual(again, "LEGACY12")
    }

    // MARK: 5b — state-export hook omits the pairing code

    /// The debug link-state export must NOT include the pairing code (PSK).
    func testLinkStateExportOmitsPairingCode() throws {
        let engine = AppEngine()
        let state = engine.makeLinkDebugState()

        XCTAssertNil(state["pairingCode"], "the export must not carry a pairingCode field")

        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(engine.pairingCode.isEmpty, "precondition: the engine has a real code")
        XCTAssertFalse(json.contains(engine.pairingCode),
                       "the pairing code value must not leak into the serialized export")
    }
}
