import AppKit
import Carbon.HIToolbox
import Combine
import PrismCore

// MARK: - Global hotkey registration + dispatch
//
// System-wide hotkeys via Carbon **RegisterEventHotKey** (spec CRITICAL): this
// is the ONLY Cocoa/Carbon path that fires while Prism is backgrounded AND needs
// no Accessibility/Input-Monitoring TCC grant. NSEvent.addGlobalMonitorForEvents
// is deliberately NOT used — it requires the Accessibility TCC permission, only
// observes (can't consume) events, and does not fire reliably for this use.
//
// Registration is isolated behind `HotKeyRegistrar` so the testable logic in
// HotKeyBindings.swift stays hardware-free: the unit tests inject a fake
// registrar and never call RegisterEventHotKey. `HotKeyManager` is @MainActor —
// Carbon hotkeys must be registered on the main thread, and every fired action
// mutates the engine on the main actor.

/// Abstraction over the OS hotkey table so `HotKeyManager` (and its tests) can
/// swap the real Carbon implementation for a fake. `onFire(id)` is called with
/// the hotkey signature id when a registered chord fires.
@MainActor
protocol HotKeyRegistrar: AnyObject {
    var onFire: ((UInt32) -> Void)? { get set }
    /// Register one chord under an integer id. Returns false if the OS refused
    /// (e.g. the chord is owned system-wide by something else).
    @discardableResult
    func register(id: UInt32, keyCode: UInt32, carbonModifiers: UInt32) -> Bool
    /// Tear down every registered chord + the shared event handler.
    func unregisterAll()
}

// MARK: - Carbon implementation

/// Real system-wide registration. One `InstallEventHandler` on the application
/// event target dispatches every `kEventHotKeyPressed` back here by signature id;
/// each chord is a `RegisterEventHotKey` handle we release on teardown.
@MainActor
final class CarbonHotKeyRegistrar: HotKeyRegistrar {
    var onFire: ((UInt32) -> Void)?

    private var eventHandler: EventHandlerRef?
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    /// 4-char OSType signature shared by all of Prism's hotkeys ('PRSM').
    private let signature: OSType = 0x5052_534D

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // Pass an unretained pointer to self; the manager outlives the handler
        // (unregisterAll runs before dealloc), so unretained is safe.
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard status == noErr else { return noErr }
            let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers on the main run loop; hop to the main actor to be
            // explicit and satisfy isolation.
            let firedID = hkID.id
            Task { @MainActor in registrar.onFire?(firedID) }
            return noErr
        }, 1, &spec, userData, &eventHandler)
    }

    @discardableResult
    func register(id: UInt32, keyCode: UInt32, carbonModifiers: UInt32) -> Bool {
        installHandlerIfNeeded()
        let hkID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, carbonModifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRefs[id] = ref
        return true
    }

    func unregisterAll() {
        for (_, ref) in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    deinit {
        // deinit is nonisolated; the refs are plain C handles, safe to release.
        for (_, ref) in hotKeyRefs { UnregisterEventHotKey(ref) }
        if let handler = eventHandler { RemoveEventHandler(handler) }
    }
}

// MARK: - Manager

/// Owns the binding set, registers each bound chord via the injected registrar,
/// and routes a fired chord → `HotKeyAction` → the matching `AppEngine` call on
/// the main actor. Rebuilds registration whenever bindings change.
@MainActor
final class HotKeyManager: ObservableObject {
    /// The current bindings; mutating through the API re-registers + persists.
    @Published private(set) var bindings: [HotKeyBinding]

    private unowned let engine: AppEngine
    private let registrar: HotKeyRegistrar
    private let defaults: UserDefaults
    private let log = EngineLog.logger("app.hotkeys")

    /// Registered signature-id → action, rebuilt on every re-register.
    private var idToAction: [UInt32: HotKeyAction] = [:]

    init(engine: AppEngine,
         registrar: HotKeyRegistrar? = nil,
         defaults: UserDefaults = .standard) {
        self.engine = engine
        // Default (production) registrar is the real Carbon one; tests inject a
        // fake. Built here (on the main actor) rather than as a default arg,
        // which would evaluate in a nonisolated context.
        self.registrar = registrar ?? CarbonHotKeyRegistrar()
        self.defaults = defaults
        self.bindings = HotKeyBindingStore.load(from: defaults)
        self.registrar.onFire = { [weak self] id in self?.handleFire(id) }
    }

    /// Register every persisted chord with the OS. Call once at launch.
    func start() {
        reregister()
    }

    /// Assign/replace a chord for an action (last-wins conflict rule), persist,
    /// and re-register.
    func assign(_ binding: HotKeyBinding) {
        bindings = HotKeyConflict.apply(binding, to: bindings)
        persistAndReregister()
    }

    /// Clear an action's chord (the row's Clear button), persist, re-register.
    func clear(_ action: HotKeyAction) {
        bindings = HotKeyConflict.clear(action, from: bindings)
        persistAndReregister()
    }

    /// The chord currently bound to `action`, if any (drives the row's label).
    func binding(for action: HotKeyAction) -> HotKeyBinding? {
        bindings.first { $0.action == action }
    }

    // MARK: Internals

    private func persistAndReregister() {
        HotKeyBindingStore.save(bindings, to: defaults)
        reregister()
    }

    private func reregister() {
        registrar.unregisterAll()
        idToAction.removeAll()
        // Assign sequential, nonzero ids (RegisterEventHotKey treats id purely as
        // a signature tag; it need not be stable across relaunches).
        var nextID: UInt32 = 1
        for binding in bindings {
            let ok = registrar.register(id: nextID, keyCode: binding.keyCode,
                                        carbonModifiers: binding.carbonModifiers)
            if ok {
                idToAction[nextID] = binding.action
                nextID += 1
            } else {
                log.error("hotkey register refused for \(binding.action.id, privacy: .public) — chord likely owned system-wide")
            }
        }
    }

    /// A chord fired: map id → action → engine call. Runs on the main actor.
    private func handleFire(_ id: UInt32) {
        guard let action = idToAction[id] else { return }
        perform(action)
    }

    /// Route an action to the real AppEngine methods. Kept small + explicit so
    /// the wiring is auditable.
    func perform(_ action: HotKeyAction) {
        switch action {
        case .toggleRecord:
            engine.toggleRecording()

        case .toggleStream:
            performStreamToggle()

        case .toggleVirtualCamera:
            engine.setVirtualCameraOutput(!engine.vcamOutputRequested)

        case .toggleControlServer:
            engine.setControlServer(!engine.controlServerRunning)

        case .switchToScene(let index):
            let collections = engine.sceneCollections
            guard index >= 0, index < collections.count else {
                log.notice("scene hotkey index \(index) out of range (\(collections.count) saved) — ignored")
                return
            }
            engine.loadCollection(collections[index])
        }
    }

    /// Stream-start-safety (spec §1): stop if live; otherwise start the
    /// configured quick target, else destinations-only, else a LOGGED no-op —
    /// never a guessed URL.
    private func performStreamToggle() {
        let decision = StreamStartPolicy.decide(
            isStreaming: engine.isStreaming,
            hasConfiguredTarget: engine.hotKeyHasConfiguredStreamTarget,
            enabledDestinationCount: engine.hotKeyEnabledDestinationCount)
        switch decision {
        case .stop:
            engine.stopStream()
        case .startConfigured:
            do { try engine.startConfiguredStream() }
            catch { log.error("toggle-stream: startConfiguredStream failed: \(error.localizedDescription, privacy: .public)") }
        case .startDestinationsOnly:
            engine.goLive(rtmpURL: "", streamKey: "")
        case .noOp(let reason):
            log.notice("toggle-stream no-op: \(reason, privacy: .public)")
        }
    }
}
