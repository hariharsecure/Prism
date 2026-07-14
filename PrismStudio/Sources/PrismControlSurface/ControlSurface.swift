import Foundation
import PrismCore

/// Ties a ``MIDIEngine`` (live MIDI) to a ``MIDIActionMap`` (bindings + learn)
/// and emits abstract ``SurfaceAction``s. This is the engine seam an app wires
/// to `AppEngine` intents — the control-surface analogue of `ControlBackend`.
///
/// ```
/// let surface = ControlSurface()
/// surface.onAction = { engine.apply($0) }   // wire to intents
/// try surface.start()
/// surface.beginLearn(for: .startStream)      // then wiggle a hardware control
/// ```
///
/// Threading: MIDI arrives on CoreMIDI's receive thread; the mapping is guarded
/// by a lock, and ``onAction`` fires on that receive thread.
public final class ControlSurface: @unchecked Sendable {
    private let log = EngineLog.logger("controlsurface")
    private let engine: MIDIEngine
    private let lock = NSLock()
    private var map: MIDIActionMap

    /// Fires for every mapped, dispatchable action. Called on CoreMIDI's
    /// receive thread — hop to your own executor if needed.
    public var onAction: ((SurfaceAction) -> Void)?

    /// Optional observer of the *raw* parsed stream (for a "MIDI monitor" UI /
    /// learn feedback). Also on the receive thread.
    public var onMessage: ((MIDIMessage) -> Void)?

    public init(clientName: String = "PrismControlSurface", mapping: MIDIActionMap = MIDIActionMap()) {
        self.engine = MIDIEngine(clientName: clientName)
        self.map = mapping
        self.engine.onMessage = { [weak self] message in
            self?.handle(message)
        }
    }

    // MARK: Lifecycle

    public func start() throws {
        try engine.start()
    }

    public func stop() {
        engine.stop()
        // Disarm any pending MIDI-learn so re-enabling later can't silently bind
        // the next message to a stale target (Codex C3).
        lock.lock(); map.cancelLearn(); lock.unlock()
    }

    /// Currently connected input sources (0 in a headless run with no devices).
    public var connectedSourceCount: Int { engine.connectedSourceCount }

    // MARK: Message → action

    private func handle(_ message: MIDIMessage) {
        onMessage?(message)
        lock.lock()
        let action = map.process(message)
        lock.unlock()
        if let action {
            log.debug("action \(String(describing: action))")
            onAction?(action)
        }
    }

    // MARK: MIDI learn

    /// Arm learn: the next incoming message is bound to `action`.
    public func beginLearn(for action: SurfaceAction) {
        lock.lock(); map.beginLearn(for: action); lock.unlock()
    }

    public func cancelLearn() {
        lock.lock(); map.cancelLearn(); lock.unlock()
    }

    public var isLearning: Bool {
        lock.lock(); defer { lock.unlock() }
        return map.isLearning
    }

    /// Manually bind without learn.
    public func bind(_ action: SurfaceAction, to trigger: MIDITrigger) {
        lock.lock(); map.bind(action, to: trigger); lock.unlock()
    }

    public func unbind(_ trigger: MIDITrigger) {
        lock.lock(); map.unbind(trigger); lock.unlock()
    }

    // MARK: Mapping snapshot / persistence

    /// A copy of the current mapping (value type — safe to inspect off-thread).
    public var mapping: MIDIActionMap {
        lock.lock(); defer { lock.unlock() }
        return map
    }

    public func setMapping(_ mapping: MIDIActionMap) {
        lock.lock(); map = mapping; lock.unlock()
    }

    /// Replace the live mapping with one loaded from disk.
    public func loadMapping(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let loaded = try MIDIActionMap(jsonData: data)
        setMapping(loaded)
        log.info("loaded mapping from \(url.lastPathComponent, privacy: .public)")
    }

    /// Persist the current mapping as JSON.
    public func saveMapping(to url: URL) throws {
        let data = try mapping.jsonData()
        try data.write(to: url, options: .atomic)
        log.info("saved mapping to \(url.lastPathComponent, privacy: .public)")
    }
}
