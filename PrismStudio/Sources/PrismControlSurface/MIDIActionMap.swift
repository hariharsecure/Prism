import Foundation

/// An abstract, hardware-independent action a control surface can request of
/// the engine. `ControlSurface` translates matched MIDI into these; the app
/// wires them to `AppEngine` intents (the same seam as obs-websocket's
/// `ControlBackend`).
///
/// Continuous controls (faders) drive ``setGain`` with the fader's normalized
/// 0–1 value; everything else is edge-triggered.
public enum SurfaceAction: Hashable, Codable, Sendable {
    /// Make scene `index` the program scene.
    case switchScene(index: Int)
    /// Set the gain of a mixer channel. `value` is 0–1 (filled from the fader
    /// at dispatch; the stored binding template ignores it).
    case setGain(channel: Int, value: Double)
    /// Toggle mute on a mixer channel.
    case toggleMute(channel: Int)
    case startStream
    case stopStream
    case startRecord
    /// Save the replay-buffer clip.
    case saveReplay
    /// An app-defined action addressed by string id.
    case custom(id: String)

    /// Whether this action consumes a continuous fader value at dispatch time.
    var isContinuous: Bool {
        if case .setGain = self { return true }
        return false
    }
}

/// The persisted, versioned form of a mapping (Codable). Bindings are stored
/// as an ordered array of pairs so it survives as stable, diffable JSON.
public struct SurfaceMapping: Codable, Sendable {
    public struct Binding: Codable, Sendable {
        public var trigger: MIDITrigger
        public var action: SurfaceAction
        public init(trigger: MIDITrigger, action: SurfaceAction) {
            self.trigger = trigger
            self.action = action
        }
    }
    public var version: Int
    public var bindings: [Binding]
    public init(version: Int = 1, bindings: [Binding] = []) {
        self.version = version
        self.bindings = bindings
    }
}

/// Maps incoming MIDI to ``SurfaceAction``s, with MIDI-learn and Codable
/// persistence. A pure value type — no CoreMIDI, no threads — so it is trivially
/// testable and cheap to snapshot behind a lock in ``ControlSurface``.
///
/// Learn flow: ``beginLearn(for:)`` arms a capture; the next message routed
/// through ``process(_:)`` is bound to that action (and swallowed — it does not
/// also fire). Subsequent matching messages then dispatch.
public struct MIDIActionMap: Sendable {
    /// Value-independent trigger → action template.
    public private(set) var bindings: [MIDITrigger: SurfaceAction]
    private var pendingLearn: SurfaceAction?

    public init() {
        bindings = [:]
    }

    public init(_ mapping: SurfaceMapping) {
        bindings = [:]
        for b in mapping.bindings { bindings[b.trigger] = b.action }
    }

    // MARK: Editing

    /// Directly bind an action to a trigger (used by import / manual mapping).
    public mutating func bind(_ action: SurfaceAction, to trigger: MIDITrigger) {
        bindings[trigger] = action
    }

    public mutating func unbind(_ trigger: MIDITrigger) {
        bindings[trigger] = nil
    }

    public mutating func removeAll() {
        bindings.removeAll()
    }

    // MARK: MIDI learn

    /// Arm learn: the next message routed through ``process(_:)`` is bound here.
    public mutating func beginLearn(for action: SurfaceAction) {
        pendingLearn = action
    }

    public mutating func cancelLearn() {
        pendingLearn = nil
    }

    public var isLearning: Bool { pendingLearn != nil }

    // MARK: Dispatch

    /// Look up the action for a message without side effects and without
    /// consulting learn state. Continuous actions come back value-filled;
    /// button actions only on a `down` edge.
    public func action(for message: MIDIMessage) -> SurfaceAction? {
        let d = message.decomposed
        guard let action = bindings[d.trigger] else { return nil }
        if case let .setGain(channel, _) = action {
            return .setGain(channel: channel, value: d.value)
        }
        return d.edge == .down ? action : nil
    }

    /// Route a live message: if learning, capture the binding and return nil;
    /// otherwise return the action to dispatch (or nil if unmapped / an "up"
    /// edge on a button).
    public mutating func process(_ message: MIDIMessage) -> SurfaceAction? {
        if let learn = pendingLearn {
            bindings[message.decomposed.trigger] = learn
            pendingLearn = nil
            return nil
        }
        return action(for: message)
    }

    // MARK: Persistence

    /// Snapshot to the Codable form (bindings sorted for stable output).
    public func makePersistable() -> SurfaceMapping {
        let sorted = bindings
            .map { SurfaceMapping.Binding(trigger: $0.key, action: $0.value) }
            .sorted { $0.trigger.sortKey < $1.trigger.sortKey }
        return SurfaceMapping(version: 1, bindings: sorted)
    }

    public func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(makePersistable())
    }

    public init(jsonData: Data) throws {
        let mapping = try JSONDecoder().decode(SurfaceMapping.self, from: jsonData)
        self.init(mapping)
    }
}

private extension MIDITrigger {
    /// Deterministic ordering key for stable persisted output.
    var sortKey: String {
        switch self {
        case let .note(n, c):           return String(format: "0-%02x-%02x", c, n)
        case let .cc(cc, c):            return String(format: "1-%02x-%02x", c, cc)
        case let .programChange(p, c):  return String(format: "2-%02x-%02x", c, p)
        case let .pitchBend(c):         return String(format: "3-%02x", c)
        }
    }
}
