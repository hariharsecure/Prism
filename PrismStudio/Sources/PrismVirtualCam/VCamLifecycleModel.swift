import Foundation

/// THE BUG (VirtualCameraFeeder):
///  1. `start()` unconditionally drove the state to `.searching`. When the sink
///     was already attached, `attemptAttach()` short-circuits (queue present) and
///     never restores `.feeding` — so a repeat "vcam on" kept frames flowing but
///     left Prism reporting off-air forever (lifecycle non-idempotency).
///  2. `stop()` never actually removed the DAL device-list listener (it only
///     flipped a flag), while `start()` added a fresh one each cycle — so every
///     off/on accumulated one permanent listener (a leak).
///
/// THE FIX: model the *decisions* — the start/stop state transition and the
/// DAL-listener accounting — as a pure, total value type, exactly like
/// `PrismVCamConstants.isAuthorizedSinkClient`. A live `VirtualCameraFeeder`
/// can't run headless (no CMIO extension, no DAL device), so the feeder now
/// delegates these decisions here and this type is what the unit tests exercise:
///   - repeat `start()` while attached KEEPS `.feeding` (idempotent),
///   - a full off→on→off cycle nets ZERO DAL listeners (no leak),
///   - a first `start()` still transitions `.searching` → (attach) → `.feeding`.
public struct VCamLifecycleModel: Equatable, Sendable {

    /// The lifecycle-relevant phases. This is a deliberately smaller alphabet
    /// than `VirtualCameraFeeder.State` (no error/not-installed variants): the
    /// model owns only the transitions the two bugs turned on.
    public enum Phase: Equatable, Sendable {
        case idle
        case searching
        case feeding
        case stopped
    }

    /// Current lifecycle phase.
    public private(set) var phase: Phase = .idle
    /// Whether the sink queue is currently attached (frames can flow).
    public private(set) var attached: Bool = false
    /// Net DAL device-list listeners the feeder should have registered. Must
    /// return to 0 after a `stop()`; must never exceed 1 across repeat starts.
    public private(set) var listenerCount: Int = 0

    public init() {}

    /// `start()`. Returns whether the caller must register a *fresh* DAL
    /// device-list listener now — true only when none is currently registered,
    /// so a repeat start can never add a duplicate (the leak fix).
    ///
    /// Idempotency: when already attached the phase STAYS `.feeding`; only a
    /// not-yet-attached start moves to `.searching`.
    @discardableResult
    public mutating func start() -> Bool {
        let needsListener = (listenerCount == 0)
        if needsListener { listenerCount += 1 }
        if !attached {
            phase = .searching
        }
        // attached ⇒ keep `.feeding` — this is the idempotency fix.
        return needsListener
    }

    /// The DAL listener the last `start()` asked us to register failed to
    /// install. Undo the accounting so a later `start()` retries and a `stop()`
    /// won't try to remove a listener that was never registered.
    public mutating func listenerInstallFailed() {
        if listenerCount > 0 { listenerCount -= 1 }
    }

    /// The sink queue was opened and the stream started: frames now flow.
    public mutating func attach() {
        attached = true
        phase = .feeding
    }

    /// The sink was torn down while the feeder keeps searching (e.g. the
    /// extension's device vanished on unload/upgrade). Listener accounting is
    /// unchanged — the feeder is still watching for the device to reappear.
    public mutating func detach() {
        attached = false
    }

    /// `stop()`. Returns whether the caller must remove a currently-registered
    /// DAL listener (i.e. one is accounted for). Drops attachment and settles in
    /// `.stopped`. Combined with `start()`, an off→on→off cycle nets 0 listeners.
    @discardableResult
    public mutating func stop() -> Bool {
        let hadListener = (listenerCount > 0)
        if hadListener { listenerCount = 0 }
        attached = false
        phase = .stopped
        return hadListener
    }
}
