import Carbon.HIToolbox
import XCTest
@testable import Prism

/// THE BUG (missing feature): Prism shipped with NO global hotkeys — OBS's
/// single most-used capability. A producer streaming a game or a Zoom call could
/// not toggle record / switch scenes without alt-tabbing back to Prism, because
/// nothing fired while the app was backgrounded.
///
/// THE FIX: global hotkeys via Carbon RegisterEventHotKey (fires unfocused, no
/// TCC). Carbon registration itself isn't unit-testable headless, so the logic
/// that CAN break silently is extracted pure — the Codable binding, the
/// UserDefaults store, the last-wins conflict rule, the combo-string formatter,
/// and the stream-start-safety policy — and guarded here. A fake registrar
/// proves the manager wiring never touches a real system hotkey.
@MainActor
final class HotKeyBindingsTests: XCTestCase {

    // MARK: - Codable round-trip (action + keyCode + modifiers preserved)

    func testBindingCodableRoundTrip() throws {
        let original = HotKeyBinding(action: .toggleRecord,
                                     keyCode: UInt32(kVK_ANSI_R),
                                     carbonModifiers: UInt32(cmdKey) | UInt32(shiftKey))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HotKeyBinding.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.action, .toggleRecord)
        XCTAssertEqual(decoded.keyCode, UInt32(kVK_ANSI_R))
        XCTAssertEqual(decoded.carbonModifiers, UInt32(cmdKey) | UInt32(shiftKey))
    }

    /// The associated-value case (scene index) must survive the round-trip too.
    func testSceneActionCodableRoundTrip() throws {
        let original = HotKeyBinding(action: .switchToScene(index: 3),
                                     keyCode: UInt32(kVK_ANSI_3),
                                     carbonModifiers: UInt32(cmdKey))
        let decoded = try JSONDecoder().decode(HotKeyBinding.self,
                                               from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.action, .switchToScene(index: 3))
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Store persists + reloads (save then load equals)

    func testBindingSetPersistsThroughStore() {
        let suiteName = "hotkeys.test.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let set = [
            HotKeyBinding(action: .toggleRecord, keyCode: UInt32(kVK_ANSI_R),
                          carbonModifiers: UInt32(cmdKey) | UInt32(shiftKey)),
            HotKeyBinding(action: .switchToScene(index: 0), keyCode: UInt32(kVK_ANSI_1),
                          carbonModifiers: UInt32(cmdKey)),
        ]
        HotKeyBindingStore.save(set, to: suite)
        let reloaded = HotKeyBindingStore.load(from: suite)
        XCTAssertEqual(reloaded, set)
    }

    /// A pristine store yields the documented default: EMPTY (nothing hijacks
    /// keys until the user assigns a chord).
    func testDefaultBindingsAreEmpty() {
        let suite = UserDefaults(suiteName: "hotkeys.test.empty.\(UUID().uuidString)")!
        XCTAssertTrue(HotKeyBindingStore.load(from: suite).isEmpty)
    }

    // MARK: - Conflict logic (documented rule: LAST-WINS / steal)

    func testConflictLastWinsStealsChord() {
        let chordCmdShift1 = (keyCode: UInt32(kVK_ANSI_1),
                              mods: UInt32(cmdKey) | UInt32(shiftKey))
        var set: [HotKeyBinding] = []
        set = HotKeyConflict.apply(
            HotKeyBinding(action: .toggleRecord, keyCode: chordCmdShift1.keyCode,
                          carbonModifiers: chordCmdShift1.mods), to: set)
        // Assign the SAME chord to a different action → the newest steals it.
        set = HotKeyConflict.apply(
            HotKeyBinding(action: .toggleStream, keyCode: chordCmdShift1.keyCode,
                          carbonModifiers: chordCmdShift1.mods), to: set)

        // Exactly one binding owns the chord, and it is the newest action.
        let owners = set.filter { $0.keyCode == chordCmdShift1.keyCode && $0.carbonModifiers == chordCmdShift1.mods }
        XCTAssertEqual(owners.count, 1)
        XCTAssertEqual(owners.first?.action, .toggleStream)
        // The stolen-from action no longer has any binding.
        XCTAssertNil(set.first { $0.action == .toggleRecord })
    }

    /// Re-assigning the SAME action just replaces its chord (one chord per action).
    func testReassignSameActionReplaces() {
        var set: [HotKeyBinding] = []
        set = HotKeyConflict.apply(
            HotKeyBinding(action: .toggleRecord, keyCode: UInt32(kVK_ANSI_R),
                          carbonModifiers: UInt32(cmdKey)), to: set)
        set = HotKeyConflict.apply(
            HotKeyBinding(action: .toggleRecord, keyCode: UInt32(kVK_ANSI_T),
                          carbonModifiers: UInt32(cmdKey)), to: set)
        let recordBindings = set.filter { $0.action == .toggleRecord }
        XCTAssertEqual(recordBindings.count, 1)
        XCTAssertEqual(recordBindings.first?.keyCode, UInt32(kVK_ANSI_T))
    }

    // MARK: - Combo-string formatting (pure)

    func testComboStringRendersCmdShift1() {
        let combo = HotKeyFormatter.string(keyCode: UInt32(kVK_ANSI_1),
                                           carbonModifiers: UInt32(cmdKey) | UInt32(shiftKey))
        XCTAssertEqual(combo, "⌘⇧1")
    }

    func testComboStringAllModifiers() {
        let mods = UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey) | UInt32(shiftKey)
        XCTAssertEqual(HotKeyFormatter.string(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: mods),
                       "⌘⌥⌃⇧A")
    }

    // MARK: - NSEvent → Carbon modifier conversion

    func testNSFlagsToCarbonModifiers() {
        // NSEvent.ModifierFlags.command (1<<20) | .shift (1<<17).
        let nsFlags: UInt = (1 << 20) | (1 << 17)
        let carbon = HotKeyBinding.carbonModifiers(fromNSFlagsRawValue: nsFlags)
        XCTAssertEqual(carbon, UInt32(cmdKey) | UInt32(shiftKey))
    }

    // MARK: - Stream-start-safety policy (never invent a URL)

    func testStreamPolicyNoOpWhenNothingConfigured() {
        let decision = StreamStartPolicy.decide(isStreaming: false,
                                                hasConfiguredTarget: false,
                                                enabledDestinationCount: 0)
        guard case .noOp = decision else {
            return XCTFail("with no target, toggle-stream must be a no-op, not a guessed broadcast")
        }
    }

    func testStreamPolicyStartsConfiguredTarget() {
        XCTAssertEqual(StreamStartPolicy.decide(isStreaming: false, hasConfiguredTarget: true,
                                                enabledDestinationCount: 0),
                       .startConfigured)
    }

    func testStreamPolicyFallsBackToDestinations() {
        XCTAssertEqual(StreamStartPolicy.decide(isStreaming: false, hasConfiguredTarget: false,
                                                enabledDestinationCount: 2),
                       .startDestinationsOnly)
    }

    func testStreamPolicyStopsWhenLive() {
        XCTAssertEqual(StreamStartPolicy.decide(isStreaming: true, hasConfiguredTarget: true,
                                                enabledDestinationCount: 2),
                       .stop)
    }

    // MARK: - Manager wiring never registers a REAL system hotkey

    /// A fake registrar records calls instead of touching Carbon. Proves the
    /// manager registers exactly the bound chords, re-registers on assign/clear,
    /// and can route a fired id → action — all hardware-free.
    func testManagerUsesRegistrarAndNeverTouchesCarbon() {
        let suite = UserDefaults(suiteName: "hotkeys.test.mgr.\(UUID().uuidString)")!
        let registrar = FakeRegistrar()
        let engine = AppEngine()
        let manager = HotKeyManager(engine: engine, registrar: registrar, defaults: suite)

        manager.start()
        XCTAssertEqual(registrar.registered.count, 0, "no bindings yet → no registrations")

        manager.assign(HotKeyBinding(action: .toggleStream, keyCode: UInt32(kVK_ANSI_S),
                                     carbonModifiers: UInt32(cmdKey) | UInt32(shiftKey)))
        XCTAssertEqual(registrar.registered.count, 1)
        XCTAssertEqual(registrar.lastUnregisterAllCount, 2) // start() + assign()

        // Fire the registered id: routes to the toggle-stream SAFE no-op path
        // (nothing configured on a fresh engine → logged no-op, no hardware).
        let firedID = registrar.registered.first!.id
        registrar.onFire?(firedID)
        XCTAssertFalse(engine.isStreaming, "no configured target → toggle-stream stays a no-op")

        manager.clear(.toggleStream)
        XCTAssertTrue(registrar.registered.isEmpty)
    }
}

/// In-memory stand-in for `CarbonHotKeyRegistrar` — records registrations and
/// lets a test synthesize a fire. NEVER calls RegisterEventHotKey.
@MainActor
private final class FakeRegistrar: HotKeyRegistrar {
    var onFire: ((UInt32) -> Void)?
    private(set) var registered: [(id: UInt32, keyCode: UInt32, mods: UInt32)] = []
    private(set) var lastUnregisterAllCount = 0

    func register(id: UInt32, keyCode: UInt32, carbonModifiers: UInt32) -> Bool {
        registered.append((id, keyCode, carbonModifiers))
        return true
    }

    func unregisterAll() {
        lastUnregisterAllCount += 1
        registered.removeAll()
    }
}
