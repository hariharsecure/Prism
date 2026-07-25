import CoreMedia
import Foundation
import PrismCore
import os

/// The **"Director's Cut"** highlight-scoring engine (flagship slice 1; see
/// `WORLD_CLASS_VISION.md`). It turns the stream's already-built live signals
/// — audio transients/hype, program loudness, scene cuts, caption
/// keyword/laughter/excitement (and, later, chat velocity) — into a rolling
/// per-moment **score** and a rolling **top-N highlights** list, and fires a
/// callback when a genuinely new high-scoring moment crosses a threshold (the
/// hook a later slice uses to trigger `ReplayBuffer.saveHighlight`).
///
/// ## Pure, decoupled, deterministic
/// The engine holds **no** audio/Vision/pixels and reads time **only** from the
/// injected event PTS (never wall-clock), exactly like `AutoDirector`. Live
/// sources *push* `HighlightSignal`s in via `ingest(_:)`; the engine never
/// reaches back into them. A scripted event stream therefore yields identical
/// scores, highlights and callbacks every run — fully unit-testable.
///
/// ## Scoring model
/// Each event contributes `weight(kind) · magnitude · 2^(−Δt / halfLife)` to the
/// momentary score `S(t)`, summed over events within the last `windowSeconds`
/// (older events fall out of the window entirely). Because the contribution of a
/// past event only *decays* between events, `S(t)` jumps at each event and decays
/// in between — so every local maximum sits exactly at an event instant, and
/// sampling `S` at each ingested event captures every peak. Co-occurring strong
/// cues (a transient landing with laughter) sum, so they outscore a lone steady
/// signal — the intended "that was a moment" behaviour.
///
/// ## Top-N via greedy non-max suppression + min-gap
/// A highlight is the **peak instant** of a cluster of nearby high scores. Two
/// highlights are never closer than `minGapSeconds` (so their clip windows don't
/// overlap): a new sample within the gap of an existing highlight either raises
/// that highlight's peak (if stronger) or is suppressed by it (if weaker); a
/// sample outside every gap starts a new highlight. This is streaming greedy NMS
/// and matches the offline "highest-scoring non-overlapping windows" result.
///
/// ## Threading
/// All mutable state is behind one lock; `onHighlight` is invoked *after* the
/// lock is released (same pattern as `TransientDetector`/`LiveCaptioner`).
public final class HighlightDirector: @unchecked Sendable {

    // MARK: - Configuration

    public struct Config: Sendable, Equatable {
        /// Per-kind weight. A missing kind (or `chatVelocity` by default) weighs 0.
        public var weights: [HighlightSignal.Kind: Double]
        /// Rolling scoring window (s): an event older than this contributes nothing.
        public var windowSeconds: Double
        /// Decay half-life (s): a contribution halves every `halfLifeSeconds`.
        public var halfLifeSeconds: Double
        /// How many highlights to retain/report.
        public var topN: Int
        /// Minimum spacing (s) between two highlight peaks — the non-overlap guard.
        public var minGapSeconds: Double
        /// Nominal clip length (s) a highlight represents; the reported window is
        /// `[peak − half, peak + half]`. Kept ≤ `minGapSeconds` so windows of two
        /// distinct highlights never overlap.
        public var highlightDurationSeconds: Double
        /// A cluster fires `onHighlight` the first time its peak score reaches
        /// this value — the "clip that moment" trigger.
        public var threshold: Double

        /// Default per-kind weights: a sharp onset and laughter are the strongest
        /// "highlight" evidence; steady loudness and a bare cut are weaker; chat
        /// is off until wired.
        public static let defaultWeights: [HighlightSignal.Kind: Double] = [
            .audioTransient: 1.0,
            .captionLaughter: 1.0,
            .captionKeyword: 0.7,
            .loudness: 0.5,
            .sceneCut: 0.4,
            .chatVelocity: 0.0,
        ]

        public init(weights: [HighlightSignal.Kind: Double] = Config.defaultWeights,
                    windowSeconds: Double = 6,
                    halfLifeSeconds: Double = 2,
                    topN: Int = 5,
                    minGapSeconds: Double = 15,
                    highlightDurationSeconds: Double = 12,
                    threshold: Double = 1.0) {
            self.weights = weights
            self.windowSeconds = max(windowSeconds, 1e-3)
            self.halfLifeSeconds = max(halfLifeSeconds, 1e-3)
            self.topN = max(topN, 0)
            self.minGapSeconds = max(minGapSeconds, 0)
            self.highlightDurationSeconds = max(highlightDurationSeconds, 0)
            self.threshold = threshold
        }

        func weight(_ kind: HighlightSignal.Kind) -> Double { weights[kind] ?? 0 }
    }

    // MARK: - Output

    /// One highlight moment: the peak instant of a cluster, plus the clip window
    /// a later slice hands to `ReplayBuffer.saveHighlight`.
    public struct Highlight: Sendable, Equatable {
        /// Clip window start (`peak − highlightDuration/2`) in house time.
        public let startPTS: CMTime
        /// Clip window end (`peak + highlightDuration/2`) in house time.
        public let endPTS: CMTime
        /// The peak instant (house time) that anchors this highlight.
        public let peakPTS: CMTime
        /// Peak momentary score at `peakPTS`.
        public let score: Double
        /// The single signal kind contributing most at the peak — the "reason".
        public let dominantSignal: HighlightSignal.Kind
        /// Peak instant in seconds (convenience).
        public var peakSeconds: Double { peakPTS.seconds }
    }

    // MARK: - Public callback

    /// Invoked once, off the lock, the first time a highlight cluster's peak
    /// score reaches `config.threshold`. This is the trigger a later slice wires
    /// to `ReplayBuffer.saveHighlight`. Set before ingesting.
    public var onHighlight: (@Sendable (Highlight) -> Void)? {
        get { lock.withLock { $0.onHighlight } }
        set { lock.withLock { $0.onHighlight = newValue } }
    }

    // MARK: - State

    private struct Event { let kind: HighlightSignal.Kind; let seconds: Double; var magnitude: Double }

    /// Hard cap on retained in-window events. A burst (a source flooding thousands
    /// of signals inside one scoring window) is first COALESCED per-kind into
    /// sub-millisecond buckets — score-exact, since co-located same-kind
    /// contributions sum — which crushes the common same-instant flood; this count
    /// cap is the final backstop against an adversarial flood of DISTINCT
    /// timestamps, keeping the sorted insert / re-score O(cap) and memory O(cap)
    /// by dropping the OLDEST (most-decayed, least-weighted) events. Without it a
    /// 100k-signal burst was O(N²) ingest + O(N) memory (a DoS).
    private static let maxEvents = 4096
    /// Same-kind events closer than this (s) are indistinguishable to any in-window
    /// score at millisecond resolution, so they are merged (magnitude summed) —
    /// exact, and it bounds a same-instant burst to one event per kind.
    private static let coalesceEpsilon = 1e-3

    /// A tracked highlight cluster (mutable peak).
    private struct Cluster {
        var peakPTS: CMTime
        var peakSeconds: Double
        var score: Double
        var dominant: HighlightSignal.Kind
        var fired: Bool
    }

    private struct State {
        var config: Config
        var onHighlight: (@Sendable (Highlight) -> Void)?
        /// Events within the current window, kept sorted by time (small buffer).
        var events: [Event] = []
        /// Newest event time seen (the trim/decay reference "now").
        var maxSeconds: Double = -.infinity
        /// Tracked highlight clusters (unbounded ≤ `maxTracked`).
        var clusters: [Cluster] = []
        /// Latest momentary score (score at `maxSeconds`).
        var currentScore: Double = 0

        init(config: Config) { self.config = config }
    }

    private let lock: OSAllocatedUnfairLock<State>
    private let log = EngineLog.logger("director.highlight")

    /// Cluster-list cap for a given config. We only ever need the top-N, but
    /// retain a generous multiple so a strong-but-not-top cluster can still
    /// absorb updates; when over cap we drop the **lowest-scoring** cluster
    /// (never one in the top-N), which keeps memory bounded under a
    /// long/flooded stream. Pure of `self` so it is safe to call while the
    /// state lock is already held (no re-entrant lock acquisition).
    private static func maxTracked(_ config: Config) -> Int {
        max(config.topN * 4, config.topN + 8)
    }

    public var config: Config {
        get { lock.withLock { $0.config } }
        set { lock.withLock { $0.config = newValue } }
    }

    public init(config: Config = Config()) {
        self.lock = OSAllocatedUnfairLock(initialState: State(config: config))
    }

    /// Clears all events, highlights and score. Keeps `config`/`onHighlight`.
    public func reset() {
        lock.withLock { s in
            s.events.removeAll(keepingCapacity: true)
            s.clusters.removeAll(keepingCapacity: true)
            s.maxSeconds = -.infinity
            s.currentScore = 0
        }
    }

    // MARK: - Ingest

    /// Feed one time-stamped signal event. Updates the rolling score and top-N,
    /// and fires `onHighlight` if this event pushes a cluster across the
    /// threshold. Out-of-order (slightly late) events are handled: the event is
    /// inserted at its own PTS and scored there.
    public func ingest(_ signal: HighlightSignal) {
        let fired: [Highlight] = lock.withLock { s in
            let t = signal.seconds
            guard t.isFinite else { return [] }

            // Insert sorted by time (buffer is bounded to the window → cheap).
            // Coalesce a same-kind event landing in the same sub-ms bucket into the
            // adjacent one (magnitude summed) so a same-instant burst can't explode
            // the buffer into an O(N²) ingest — this merge is score-exact.
            let idx = s.events.firstIndex { $0.seconds > t } ?? s.events.count
            if idx > 0, s.events[idx - 1].kind == signal.kind,
               t - s.events[idx - 1].seconds < Self.coalesceEpsilon {
                s.events[idx - 1].magnitude += signal.magnitude
            } else if idx < s.events.count, s.events[idx].kind == signal.kind,
                      s.events[idx].seconds - t < Self.coalesceEpsilon {
                s.events[idx].magnitude += signal.magnitude
            } else {
                s.events.insert(Event(kind: signal.kind, seconds: t, magnitude: signal.magnitude), at: idx)
            }

            if t > s.maxSeconds { s.maxSeconds = t }
            trimEvents(&s)

            // Momentary score + dominant kind at this event's instant.
            let (score, dominant) = Self.score(in: s.events, at: t, config: s.config)
            if t >= s.maxSeconds { s.currentScore = score }

            return absorb(&s, peakPTS: signal.pts, peakSeconds: t,
                          score: score, dominant: dominant)
        }

        guard !fired.isEmpty else { return }
        let cb = lock.withLock { $0.onHighlight }
        guard let cb else { return }
        for h in fired { cb(h) }
    }

    /// Convenience batch ingest (events applied in array order).
    public func ingest(_ signals: [HighlightSignal]) { for sig in signals { ingest(sig) } }

    // MARK: - Queries

    /// Current top-N highlights, highest score first (ties broken by earlier
    /// peak). Never more than `config.topN`.
    public var topHighlights: [Highlight] {
        lock.withLock { s in Self.rankedHighlights(s.clusters, config: s.config) }
    }

    /// Latest momentary score (score at the newest ingested instant).
    public var currentScore: Double { lock.withLock { $0.currentScore } }

    #if DEBUG
    /// Test-only: number of retained in-window events. Proves the M4 burst bound
    /// (coalescing + count cap) keeps the buffer from growing without limit.
    var _test_eventCount: Int { lock.withLock { $0.events.count } }
    #endif

    /// Momentary score at an arbitrary house-time (seconds), reconstructed from
    /// the events still inside the window. Accurate for times within the current
    /// window; events that have aged out contribute nothing (by design).
    public func score(at seconds: Double) -> Double {
        lock.withLock { s in Self.score(in: s.events, at: seconds, config: s.config).score }
    }

    // MARK: - Core math (pure statics — the deterministic heart)

    /// `S(t) = Σ weight(kind)·magnitude·2^(−Δt/halfLife)` over events with
    /// `time ≤ t` and `Δt ≤ window`. Also returns the kind with the single
    /// largest contribution (the "dominant"/reason).
    private static func score(in events: [Event], at t: Double,
                              config: Config) -> (score: Double, dominant: HighlightSignal.Kind) {
        var total = 0.0
        var bestContribution = -1.0
        var dominant: HighlightSignal.Kind = .audioTransient
        for e in events {
            let dt = t - e.seconds
            if dt < 0 { break }               // events are sorted; rest are in the future
            if dt > config.windowSeconds { continue }
            let contribution = config.weight(e.kind) * e.magnitude
                * pow(2, -dt / config.halfLifeSeconds)
            total += contribution
            if contribution > bestContribution {
                bestContribution = contribution
                dominant = e.kind
            }
        }
        return (total, dominant)
    }

    /// Drops events older than the window behind the newest time seen, then caps
    /// the retained count so a burst of DISTINCT-timestamp events inside one window
    /// can't grow the buffer without bound (M4). Over cap, the oldest (most-decayed)
    /// events are dropped first.
    private func trimEvents(_ s: inout State) {
        let cutoff = s.maxSeconds - s.config.windowSeconds
        while let first = s.events.first, first.seconds < cutoff {
            s.events.removeFirst()
        }
        if s.events.count > Self.maxEvents {
            s.events.removeFirst(s.events.count - Self.maxEvents)
        }
    }

    /// Fold one score sample into the cluster set (streaming greedy NMS +
    /// min-gap). Returns the highlights that newly crossed the threshold.
    private func absorb(_ s: inout State, peakPTS: CMTime, peakSeconds: Double,
                        score: Double, dominant: HighlightSignal.Kind) -> [Highlight] {
        // A zero-weight/zero-magnitude instant isn't a highlight (e.g. an
        // unweighted `chatVelocity` event) — never track it.
        guard score > 0 else { return [] }
        let gap = s.config.minGapSeconds

        // Find the nearest existing cluster within the gap (strongest on a tie of
        // distance) — the cluster this sample belongs to under NMS.
        var nearest: Int? = nil
        var nearestDist = Double.infinity
        for (i, c) in s.clusters.enumerated() {
            let d = abs(c.peakSeconds - peakSeconds)
            if d < gap {
                if d < nearestDist || (d == nearestDist && (nearest.map { c.score > s.clusters[$0].score } ?? false)) {
                    nearest = i
                    nearestDist = d
                }
            }
        }

        var fired: [Highlight] = []

        if let i = nearest {
            // Same cluster: raise its peak if this sample is stronger; else the
            // existing (stronger, nearby) peak suppresses this one.
            if score > s.clusters[i].score {
                s.clusters[i].peakPTS = peakPTS
                s.clusters[i].peakSeconds = peakSeconds
                s.clusters[i].score = score
                s.clusters[i].dominant = dominant
                if !s.clusters[i].fired, score >= s.config.threshold {
                    s.clusters[i].fired = true
                    fired.append(highlight(from: s.clusters[i], config: s.config))
                }
            }
        } else {
            // New cluster.
            var c = Cluster(peakPTS: peakPTS, peakSeconds: peakSeconds,
                            score: score, dominant: dominant, fired: false)
            if score >= s.config.threshold {
                c.fired = true
                fired.append(highlight(from: c, config: s.config))
            }
            s.clusters.append(c)
        }
        compact(&s)
        capClusters(&s)
        return fired
    }

    /// Enforces the min-gap invariant: while any two clusters are closer than
    /// `minGapSeconds`, merge them into the stronger peak (preserving `fired` so a
    /// past threshold-crossing is never lost). O(n²) over a small (≤ maxTracked)
    /// list; a moved peak can only newly conflict with a neighbour, so this
    /// converges immediately in practice.
    private func compact(_ s: inout State) {
        let gap = s.config.minGapSeconds
        guard gap > 0 else { return }
        var merged = true
        while merged {
            merged = false
            outer: for a in 0..<s.clusters.count {
                for b in (a + 1)..<s.clusters.count where abs(s.clusters[a].peakSeconds - s.clusters[b].peakSeconds) < gap {
                    let keep = s.clusters[a].score >= s.clusters[b].score ? a : b
                    let drop = keep == a ? b : a
                    s.clusters[keep].fired = s.clusters[a].fired || s.clusters[b].fired
                    s.clusters.remove(at: drop)
                    merged = true
                    break outer
                }
            }
        }
    }

    /// Bounds the cluster list by evicting the lowest-scoring cluster (never one
    /// in the top-N) when over `maxTracked`.
    private func capClusters(_ s: inout State) {
        let cap = Self.maxTracked(s.config)
        while s.clusters.count > cap {
            if let minIdx = s.clusters.indices.min(by: { s.clusters[$0].score < s.clusters[$1].score }) {
                s.clusters.remove(at: minIdx)
            } else { break }
        }
    }

    private func highlight(from c: Cluster, config: Config) -> Highlight {
        let half = CMTime(seconds: config.highlightDurationSeconds / 2, preferredTimescale: 600)
        return Highlight(startPTS: CMTimeSubtract(c.peakPTS, half),
                         endPTS: CMTimeAdd(c.peakPTS, half),
                         peakPTS: c.peakPTS,
                         score: c.score,
                         dominantSignal: c.dominant)
    }

    private static func rankedHighlights(_ clusters: [Cluster], config: Config) -> [Highlight] {
        let half = CMTime(seconds: config.highlightDurationSeconds / 2, preferredTimescale: 600)
        let sorted = clusters.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.peakSeconds < $1.peakSeconds
        }
        return sorted.prefix(config.topN).map { c in
            Highlight(startPTS: CMTimeSubtract(c.peakPTS, half),
                      endPTS: CMTimeAdd(c.peakPTS, half),
                      peakPTS: c.peakPTS,
                      score: c.score,
                      dominantSignal: c.dominant)
        }
    }
}
