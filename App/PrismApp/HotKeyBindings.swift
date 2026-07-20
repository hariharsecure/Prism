import Carbon.HIToolbox
import Foundation

// MARK: - Global hotkeys: pure, hardware-free model + persistence
//
// OBS's single most-used feature: system-wide hotkeys that fire while another
// app (a game, Zoom) is frontmost, so a producer can toggle record / switch
// scenes without alt-tabbing back to Prism. The actual OS registration lives in
// `HotKeyManager` (Carbon RegisterEventHotKey); THIS file is everything that can
// be reasoned about — and unit-tested — without touching hardware or the event
// system: the action set, the Codable binding, UserDefaults persistence, the
// conflict rule, the combo-string formatter, and the stream-start-safety policy.
//
// Modifier storage: we store Carbon modifier masks (`cmdKey`, `shiftKey`,
// `optionKey`, `controlKey`) directly — the exact bits RegisterEventHotKey
// wants — so the manager never re-derives them. The key-capture UI hands us
// NSEvent flags and converts once (see `HotKeyBinding.carbonModifiers(from:)`).

/// What a global hotkey does. Toggles are self-contained; `switchToScene` picks
/// a saved scene collection by its position in `AppEngine.sceneCollections`.
///
/// Codable (synthesized) so the whole binding set round-trips through JSON;
/// Hashable so it can key the manager's id→action map and the conflict set.
enum HotKeyAction: Codable, Hashable {
    case toggleRecord
    case toggleStream
    case toggleVirtualCamera
    case toggleControlServer
    case switchToScene(index: Int)

    /// Stable slug used for the accessibilityIdentifier stem (`hotkeys.<id>.…`)
    /// and as a dictionary key. Never localized, never persisted (the enum's own
    /// Codable is the persisted form) — safe to change display text without
    /// breaking saved bindings.
    var id: String {
        switch self {
        case .toggleRecord:        return "record"
        case .toggleStream:        return "stream"
        case .toggleVirtualCamera: return "virtualCamera"
        case .toggleControlServer: return "controlServer"
        case .switchToScene(let i): return "scene.\(i)"
        }
    }

    /// Human label for the settings row.
    var displayName: String {
        switch self {
        case .toggleRecord:        return "Start / Stop Recording"
        case .toggleStream:        return "Start / Stop Streaming"
        case .toggleVirtualCamera: return "Toggle Virtual Camera"
        case .toggleControlServer: return "Toggle Control Server"
        case .switchToScene(let i): return "Switch to Scene \(i + 1)"
        }
    }

    /// The four fixed toggle actions (scene actions are appended per saved
    /// collection by the UI/manager, since they depend on runtime state).
    static let toggles: [HotKeyAction] =
        [.toggleRecord, .toggleStream, .toggleVirtualCamera, .toggleControlServer]
}

/// A single assignment: an action bound to a physical key + Carbon modifier mask.
/// `Identifiable` by action id so SwiftUI `ForEach` is stable and there is at
/// most one binding per action.
struct HotKeyBinding: Codable, Equatable, Identifiable {
    var action: HotKeyAction
    /// Virtual key code — identical between NSEvent and Carbon (kVK_*).
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey | shiftKey | optionKey | controlKey).
    var carbonModifiers: UInt32

    var id: String { action.id }

    init(action: HotKeyAction, keyCode: UInt32, carbonModifiers: UInt32) {
        self.action = action
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// Convert NSEvent-style modifier flags (from the key-capture control) into
    /// the Carbon mask we persist and register with. Kept as raw UInt to stay
    /// free of an AppKit import so this whole file is unit-testable headless.
    /// `nsFlagsRawValue` is `NSEvent.ModifierFlags.rawValue`.
    static func carbonModifiers(fromNSFlagsRawValue nsFlagsRawValue: UInt) -> UInt32 {
        // NSEvent.ModifierFlags device-independent bits.
        let cmd: UInt   = 1 << 20   // .command
        let shift: UInt = 1 << 17   // .shift
        let opt: UInt   = 1 << 19   // .option
        let ctrl: UInt  = 1 << 18   // .control
        var mask: UInt32 = 0
        if nsFlagsRawValue & cmd   != 0 { mask |= UInt32(cmdKey) }
        if nsFlagsRawValue & shift != 0 { mask |= UInt32(shiftKey) }
        if nsFlagsRawValue & opt   != 0 { mask |= UInt32(optionKey) }
        if nsFlagsRawValue & ctrl  != 0 { mask |= UInt32(controlKey) }
        return mask
    }

    /// Two bindings COLLIDE when they fire on the same physical chord.
    func collides(with other: HotKeyBinding) -> Bool {
        keyCode == other.keyCode && carbonModifiers == other.carbonModifiers
    }
}

// MARK: - Conflict resolution (documented rule: LAST-WINS / steal)

enum HotKeyConflict {
    /// Assign `newBinding` into `existing` and return the resolved set.
    ///
    /// Documented rule — LAST-WINS (the newest assignment steals the chord):
    ///   1. Any prior binding for the SAME action is replaced (an action holds at
    ///      most one chord).
    ///   2. Any OTHER action already on the same keyCode+modifiers is cleared, so
    ///      a physical chord is never ambiguously bound to two actions.
    /// The manager then re-registers from this clean set, so Carbon never sees a
    /// duplicate RegisterEventHotKey for one chord.
    static func apply(_ newBinding: HotKeyBinding, to existing: [HotKeyBinding]) -> [HotKeyBinding] {
        var result = existing.filter { candidate in
            candidate.action != newBinding.action && !candidate.collides(with: newBinding)
        }
        result.append(newBinding)
        return result
    }

    /// Remove any binding for `action` (the row's Clear button).
    static func clear(_ action: HotKeyAction, from existing: [HotKeyBinding]) -> [HotKeyBinding] {
        existing.filter { $0.action != action }
    }
}

// MARK: - Persistence (mirrors SceneCollectionStore / SettingsPersistence)

/// Codable+UserDefaults store for the binding set, keyed like the other
/// `studio.prism.*` defaults. DEFAULT is EMPTY (spec §2): nothing is bound until
/// the user assigns a chord, so Prism never hijacks a key out of the box.
/// `defaults` is injectable so tests run against a throwaway suite and never
/// touch the real user domain.
enum HotKeyBindingStore {
    static let key = "studio.prism.hotkeys.bindings"

    static func load(from defaults: UserDefaults = .standard) -> [HotKeyBinding] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([HotKeyBinding].self, from: data)) ?? []
    }

    static func save(_ bindings: [HotKeyBinding], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: key)
    }
}

// MARK: - Combo-string formatting (pure)

enum HotKeyFormatter {
    /// Render a keyCode+Carbon-modifier chord as a human-readable combo, e.g.
    /// `⌘⇧1`. Modifier order is COMMAND, OPTION, CONTROL, SHIFT (⌘⌥⌃⇧) — chosen
    /// to match Prism's documented convention where ⌘ leads. The key glyph comes
    /// from `keyName`.
    static func string(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        var out = ""
        if carbonModifiers & UInt32(cmdKey)     != 0 { out += "⌘" }
        if carbonModifiers & UInt32(optionKey)  != 0 { out += "⌥" }
        if carbonModifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { out += "⇧" }
        out += keyName(for: keyCode)
        return out
    }

    /// Display glyph/name for a virtual key code (kVK_*). Unknown codes fall back
    /// to `key(N)` so the UI still shows something deterministic.
    static func keyName(for keyCode: UInt32) -> String {
        if let name = keyNames[Int(keyCode)] { return name }
        return "key(\(keyCode))"
    }

    private static let keyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_Delete: "⌫",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
    ]
}

// MARK: - Stream-start-safety policy (pure)

/// What the toggle-stream hotkey should do given current state. Keeping this a
/// pure decision (no engine, no MainActor) lets the test pin the "never invent a
/// URL" contract (spec §1): with nothing configured the action is a logged
/// no-op, NOT a guessed broadcast.
enum StreamHotKeyDecision: Equatable {
    case stop
    case startConfigured        // the user's saved single-RTMP quick target
    case startDestinationsOnly  // no quick target, but ≥1 enabled restream dest
    case noOp(reason: String)
}

enum StreamStartPolicy {
    static func decide(isStreaming: Bool,
                       hasConfiguredTarget: Bool,
                       enabledDestinationCount: Int) -> StreamHotKeyDecision {
        if isStreaming { return .stop }
        if hasConfiguredTarget { return .startConfigured }
        if enabledDestinationCount > 0 { return .startDestinationsOnly }
        return .noOp(reason: "No stream target configured — set an RTMP URL/key or enable a destination first.")
    }
}
