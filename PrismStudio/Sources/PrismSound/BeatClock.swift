import Foundation

// MARK: - BeatClock

/// A pure, deterministic tempo-clock snapshot the app can feed to visual effects
/// each frame WITHOUT importing the whole `BeatSequencer`.
///
/// A **beat** is a quarter note (`60 / bpm` seconds); a **bar** is `beatsPerBar`
/// of them (a 16-step 4/4 pattern ⇒ 4). Every reading is derived from a single
/// continuous quantity — `hostSeconds − anchorHostSeconds` — so phase is
/// continuous across beat *and* bar boundaries: there is no per-bar reset to
/// drift against, and `beatIndex`/`barIndex` are monotonic.
///
/// Swing (which delays only the odd *sixteenth* notes that fall *between* beats)
/// never moves a quarter-note beat, so it is intentionally absent from the clock
/// — the downbeat grid this clock describes is swing-independent. See
/// `BeatSequencer.beatClock` for how the sequencer populates the anchor.
///
/// Deterministic: no `Date`, no randomness. The app passes
/// `HouseClock.nowSeconds()`; tests pass fixed host times.
public struct BeatClock: Sendable, Equatable {
    /// Quarter-note tempo. `bpm <= 0` (or non-finite) ⇒ a *stopped* clock: all
    /// phases read 0 and no beats occur.
    public var bpm: Double
    /// Quarter-note beats per bar (clamped ≥ 1).
    public var beatsPerBar: Int
    /// House-time (seconds) of beat 0 / bar 0. Stable while playing so phase stays
    /// continuous frame-to-frame.
    public var anchorHostSeconds: Double

    public init(bpm: Double, beatsPerBar: Int, anchorHostSeconds: Double) {
        self.bpm = bpm
        self.beatsPerBar = max(1, beatsPerBar)
        self.anchorHostSeconds = anchorHostSeconds
    }

    /// A stopped clock (phase 0, no beats) — the graceful default when nothing plays.
    public static let stopped = BeatClock(bpm: 0, beatsPerBar: 4, anchorHostSeconds: 0)

    /// Seconds per quarter-note beat; 0 when stopped.
    public var beatSeconds: Double { (bpm > 0 && bpm.isFinite) ? 60.0 / bpm : 0 }
    /// Seconds per bar; 0 when stopped.
    public var barSeconds: Double { beatSeconds * Double(beatsPerBar) }

    /// Fractional beats elapsed since the anchor (0 when stopped or before the anchor).
    private func beatPosition(atHostSeconds host: Double) -> Double {
        let bs = beatSeconds
        guard bs > 0 else { return 0 }
        let elapsed = host - anchorHostSeconds
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        return elapsed / bs
    }

    /// Fractional bars elapsed since the anchor (0 when stopped or before the anchor).
    private func barPosition(atHostSeconds host: Double) -> Double {
        let bs = barSeconds
        guard bs > 0 else { return 0 }
        let elapsed = host - anchorHostSeconds
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        return elapsed / bs
    }

    /// Position within the current beat, `0 → 1`, wrapping to 0 on every downbeat.
    public func beatPhase(atHostSeconds host: Double) -> Double {
        let p = beatPosition(atHostSeconds: host)
        return p - p.rounded(.down)
    }

    /// Position within the current bar, `0 → 1`, wrapping to 0 on every bar line.
    public func barPhase(atHostSeconds host: Double) -> Double {
        let p = barPosition(atHostSeconds: host)
        return p - p.rounded(.down)
    }

    /// Index of the current beat since the anchor (0-based, monotonic); 0 when stopped.
    public func beatIndex(atHostSeconds host: Double) -> Int {
        Int(beatPosition(atHostSeconds: host).rounded(.down))
    }

    /// Index of the current bar since the anchor (0-based, monotonic); 0 when stopped.
    public func barIndex(atHostSeconds host: Double) -> Int {
        Int(barPosition(atHostSeconds: host).rounded(.down))
    }
}
