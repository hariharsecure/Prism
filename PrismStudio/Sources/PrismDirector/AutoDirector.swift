import CoreMedia
import Foundation
import PrismCore

/// Typed configuration for the switching policy.
///
/// The two anti-flicker time constants are the load-bearing knobs:
/// `leadWindowSeconds` (a challenger must *sustain* its lead this long before
/// we believe it) and `minShotSeconds` + `cutCooldownSeconds` (we don't cut
/// away from a shot that's too fresh, and we don't cut again too soon).
public struct AutoDirectorConfig: Sendable, Equatable {
    /// Master enable. When false the engine emits nothing.
    public var enabled: Bool
    /// 0 = sticky (only switch on a big, clear, sustained lead) … 1 = twitchy
    /// (switch on a small edge). Drives the hysteresis margin and activation
    /// floor (see `hysteresisMargin`/`activationFloor`).
    public var sensitivity: Float
    /// Minimum time (s) a shot must be live before we're allowed to cut away
    /// from it. Stops rapid A→B→A churn.
    public var minShotSeconds: Double
    /// A challenger must lead **continuously** for this long (s) before a cut
    /// fires. This is the core hysteresis: a one-frame spike never cuts.
    public var leadWindowSeconds: Double
    /// Minimum time (s) between two cuts, regardless of anything else. The hard
    /// anti-flip-flop backstop.
    public var cutCooldownSeconds: Double
    /// A signal is **stale** once its PTS lags the house clock by more than this
    /// window (s). Stale signals are excluded from ranking/selection: a source
    /// that stopped emitting (unplugged / frozen) must never be a cut target,
    /// however high its last signal was. Analogous to `CandidateStore`'s TTL.
    public var stalenessSeconds: Double

    public init(enabled: Bool = true,
                sensitivity: Float = 0.5,
                minShotSeconds: Double = 2.0,
                leadWindowSeconds: Double = 0.8,
                cutCooldownSeconds: Double = 1.5,
                stalenessSeconds: Double = 1.0) {
        self.enabled = enabled
        self.sensitivity = min(1, max(0, sensitivity))
        self.minShotSeconds = max(0, minShotSeconds)
        self.leadWindowSeconds = max(0, leadWindowSeconds)
        self.cutCooldownSeconds = max(0, cutCooldownSeconds)
        self.stalenessSeconds = max(0, stalenessSeconds)
    }

    /// How much a challenger's activity must exceed the current program's
    /// before it counts as "leading". High when sticky, low when twitchy.
    /// (0.40 at sensitivity 0 … 0.05 at sensitivity 1.)
    public var hysteresisMargin: Float { 0.05 + 0.35 * (1 - sensitivity) }
    /// Minimum activity for a source to be selectable at all (below this a
    /// source is "empty" and never acquired). (0.22 … 0.02.)
    public var activationFloor: Float { 0.02 + 0.20 * (1 - sensitivity) }
}

/// One switch decision emitted by the policy engine.
public struct DirectorDecision: Sendable, Equatable {
    /// Why the engine chose to (re)assign the program.
    public enum Reason: String, Sendable {
        /// First source to clear the activation floor — no prior program.
        case initialAcquire
        /// A challenger sustained a decisive lead past every gate.
        case sustainedLead
    }
    /// The source now on program.
    public let activeSource: SourceID
    /// The source we cut away from (`nil` on the initial acquire).
    public let previousSource: SourceID?
    public let reason: Reason
    /// House-time seconds at which the decision was made (the driving frame's PTS).
    public let atSeconds: Double
}

/// The switching policy engine: given per-source `SourceSignal`s over time,
/// decide the program source with **hysteresis + minimum-shot + cooldown**.
///
/// This type is **pure and fully testable** — it holds no Vision, no pixels, no
/// wall-clock. It reads time from the signals' PTS, so a scripted sequence
/// yields identical decisions every run. `ingest` returns a decision (or nil);
/// wire `onDecision` for a callback style.
///
/// ### The anti-flicker rules (all must pass to cut)
/// 1. **Decisive lead** — a challenger must beat the current program's activity
///    by at least `hysteresisMargin`. Equal (or barely-ahead) signals never
///    cut → the program holds. This kills tie-flicker.
/// 2. **Sustained** — the challenger must hold that lead *continuously* for
///    `leadWindowSeconds`. Any interruption (it drops, or another source takes
///    the lead) resets the timer. This kills spike-flicker.
/// 3. **Min shot** — the current shot must have been live at least
///    `minShotSeconds`. This kills too-fast cutting.
/// 4. **Cooldown** — at least `cutCooldownSeconds` must have elapsed since the
///    last cut. This is the hard backstop against A→B→A ping-pong.
///
/// Not thread-safe on its own; `DirectorController` serializes access.
public final class AutoDirector {
    public var config: AutoDirectorConfig
    /// Fired on every decision (in addition to `ingest`'s return value).
    public var onDecision: ((DirectorDecision) -> Void)?

    private var activeSource: SourceID?
    private var activeSince: Double = 0
    private var lastCutAt: Double = -Double.infinity
    private var challengerSource: SourceID?
    private var challengerSince: Double?

    public init(config: AutoDirectorConfig = AutoDirectorConfig()) {
        self.config = config
    }

    /// The source currently on program (nil before the first acquire).
    public var currentActiveSource: SourceID? { activeSource }

    /// Reset all state (e.g. on enable/disable or scene reload).
    public func reset() {
        activeSource = nil
        activeSince = 0
        lastCutAt = -Double.infinity
        challengerSource = nil
        challengerSince = nil
    }

    /// Feed the latest signal per source. Returns a `DirectorDecision` when the
    /// program should change, else nil. `now` defaults to the newest PTS among
    /// the signals (house time) so the timeline is signal-driven and
    /// deterministic; pass an explicit value only if you must.
    @discardableResult
    public func ingest(_ signals: [SourceSignal], now: Double? = nil) -> DirectorDecision? {
        guard config.enabled else { return nil }
        let clock = now ?? signals.compactMap { $0.pts.seconds.isFinite ? $0.pts.seconds : nil }.max()
            ?? HouseClock.nowSeconds()

        // Guard against non-monotonic house time. If a source reconnects with a
        // reset PTS the clock can jump BACKWARD relative to our stored timers,
        // making `onShot`/`sinceCut` negative so the gates never pass again (the
        // engine wedges). Detect the discontinuity and re-baseline the timers to
        // the new clock rather than computing negative durations.
        if activeSource != nil,
           clock < activeSince || (lastCutAt.isFinite && clock < lastCutAt) {
            activeSince = clock
            lastCutAt = clock
            challengerSource = nil
            challengerSince = nil
        }

        // Exclude stale signals: a source whose last PTS lags the house clock by
        // more than the staleness window has stopped emitting (unplugged / frozen)
        // and must not be rankable — otherwise its last high signal out-ranks the
        // live active source forever and we cut to a dead source. A signal with a
        // non-finite PTS can't be aged out, so it stays eligible.
        let fresh = signals.filter { sig in
            guard sig.pts.seconds.isFinite else { return true }
            return clock - sig.pts.seconds <= config.stalenessSeconds
        }

        // Rank candidates: activity desc, then source id asc for a stable
        // tie-break (so equal signals resolve deterministically → hold).
        let ranked = fresh
            .map { (source: $0.source, activity: $0.activity) }
            .sorted { $0.activity != $1.activity ? $0.activity > $1.activity : $0.source.raw < $1.source.raw }
        guard let leader = ranked.first else { return nil }

        // No program yet: acquire the leader if it clears the floor.
        guard let active = activeSource else {
            if leader.activity >= config.activationFloor {
                return commit(to: leader.source, previous: nil, reason: .initialAcquire, at: clock)
            }
            return nil
        }

        // Leader is already on program → nothing to challenge; clear tracking.
        if leader.source == active {
            challengerSource = nil
            challengerSince = nil
            return nil
        }

        // A different source leads. Is the lead decisive vs the current program?
        let activeActivity = ranked.first { $0.source == active }?.activity ?? 0
        let decisive = leader.activity >= activeActivity + config.hysteresisMargin
            && leader.activity >= config.activationFloor
        guard decisive else {
            challengerSource = nil
            challengerSince = nil
            return nil
        }

        // Track continuity of this challenger's lead.
        if challengerSource != leader.source {
            challengerSource = leader.source
            challengerSince = clock
        }
        let led = clock - (challengerSince ?? clock)
        let onShot = clock - activeSince
        let sinceCut = clock - lastCutAt

        if led >= config.leadWindowSeconds
            && onShot >= config.minShotSeconds
            && sinceCut >= config.cutCooldownSeconds {
            return commit(to: leader.source, previous: active, reason: .sustainedLead, at: clock)
        }
        return nil
    }

    private func commit(to source: SourceID, previous: SourceID?,
                        reason: DirectorDecision.Reason, at clock: Double) -> DirectorDecision {
        activeSource = source
        activeSince = clock
        lastCutAt = clock
        challengerSource = nil
        challengerSince = nil
        let decision = DirectorDecision(activeSource: source, previousSource: previous,
                                        reason: reason, atSeconds: clock)
        onDecision?(decision)
        return decision
    }
}
