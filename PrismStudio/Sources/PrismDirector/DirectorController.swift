import CoreGraphics
import CoreMedia
import Foundation
import PrismCore

/// Whole-module configuration.
public struct DirectorConfig: Sendable, Equatable {
    /// Switching policy config.
    public var policy: AutoDirectorConfig
    /// Framing config.
    public var framing: AutoFramerConfig
    /// Whether the framer runs at all (switching can be wanted without
    /// auto-crop, and vice-versa).
    public var autoFrameEnabled: Bool
    /// Analyzer target rate (Hz) and face-confidence floor.
    public var analyzerRate: Double
    public var minFaceConfidence: Float

    public init(policy: AutoDirectorConfig = AutoDirectorConfig(),
                framing: AutoFramerConfig = AutoFramerConfig(),
                autoFrameEnabled: Bool = true,
                analyzerRate: Double = 8,
                minFaceConfidence: Float = 0.3) {
        self.policy = policy
        self.framing = framing
        self.autoFrameEnabled = autoFrameEnabled
        self.analyzerRate = analyzerRate
        self.minFaceConfidence = minFaceConfidence
    }
}

/// Orchestrates the auto-director end to end: it owns the `DirectorAnalyzer`,
/// the `AutoDirector` policy engine, and a per-source `AutoFramer`, and turns a
/// stream of submitted frames into two kinds of output the app applies:
///
///  - `onDecision(DirectorDecision)` — cut the program to a new source (the app
///    switches the scene / sets the hero layer).
///  - `onFraming(SourceID, CGRect)` — a fresh smoothed crop for the active
///    source (the app writes it into that source's `Layer.crop`).
///
/// It **produces decisions, it does not render** (DESIGN §2.2). The app owns the
/// compositor and applies what the director asks for.
///
/// Concurrency: `submit` is non-blocking. Analyzer callbacks (and therefore the
/// `onDecision`/`onFraming` callbacks) arrive on the analyzer's serial queue;
/// internal state is guarded by a lock so `setEnabled`/`config` are safe from
/// any thread. Set the callbacks before submitting frames.
public final class DirectorController: @unchecked Sendable {
    public var onDecision: ((DirectorDecision) -> Void)?
    public var onFraming: ((SourceID, CGRect) -> Void)?
    /// Surfaced for observability (e.g. a debug HUD): every per-source signal.
    public var onSignal: ((SourceSignal) -> Void)?

    private let analyzer: DirectorAnalyzer
    private let director: AutoDirector
    private var framers: [SourceID: AutoFramer] = [:]
    private var latestSignals: [SourceID: SourceSignal] = [:]
    private let lock = NSLock()
    private var config: DirectorConfig
    private var enabled: Bool

    public init(config: DirectorConfig = DirectorConfig(), enabled: Bool = true) {
        self.config = config
        self.enabled = enabled
        self.analyzer = DirectorAnalyzer(targetRate: config.analyzerRate,
                                         minFaceConfidence: config.minFaceConfidence)
        self.director = AutoDirector(config: config.policy)
        analyzer.onSignal = { [weak self] signal in self?.handle(signal) }
        analyzer.onError = { [weak self] error in
            EngineLog.logger("director").error("analyzer error: \(error)")
            _ = self
        }
    }

    /// Submit a live source frame for analysis (non-blocking, rate-limited).
    public func submit(_ frame: VideoFrame) {
        analyzer.submit(frame)
    }

    /// Master enable/disable. Disabling resets the policy so re-enabling starts
    /// clean (no stale challenger/shot timers).
    public func setEnabled(_ on: Bool) {
        lock.lock()
        enabled = on
        if !on { director.reset() }
        lock.unlock()
    }

    public var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }

    /// The source currently on program per the policy (nil before first acquire).
    /// Read under `lock`: the analyzer queue writes `director.currentActiveSource`
    /// (a heap `String`) from `handle(_:)`, so an unlocked read here is a torn
    /// read (crash). Mirrors every sibling accessor (`isEnabled`).
    public var activeSource: SourceID? { lock.lock(); defer { lock.unlock() }; return director.currentActiveSource }

    /// Update configuration live.
    public func updateConfig(_ newConfig: DirectorConfig) {
        lock.lock()
        config = newConfig
        director.config = newConfig.policy
        for framer in framers.values { framer.config = newConfig.framing }
        lock.unlock()
    }

    // MARK: - Signal handling

    /// Injects a caller-supplied audio level for a source before its next
    /// signal is scored (the analyzer never reads audio). Merges into the
    /// stored latest signal so the policy sees it on the following update.
    public func setAudioLevel(_ level: Float, for source: SourceID) {
        lock.lock()
        if var s = latestSignals[source] {
            s.audioLevel = level
            latestSignals[source] = s
        }
        lock.unlock()
    }

    private func handle(_ signal: SourceSignal) {
        onSignal?(signal)
        lock.lock()
        guard enabled else { lock.unlock(); return }
        // Preserve any app-supplied audio level already parked for this source.
        var merged = signal
        if let prior = latestSignals[signal.source], signal.audioLevel == nil {
            merged.audioLevel = prior.audioLevel
        }
        latestSignals[signal.source] = merged

        // Prune stale signals (a source that stopped emitting) so `latestSignals`
        // can't grow without bound and a dead source's last signal never lingers
        // as a cut target. Mirrors `AutoDirector`'s staleness exclusion and
        // `CandidateStore`'s TTL prune. House time is monotonic and shared across
        // sources, so age off the newest PTS seen.
        let staleness = config.policy.stalenessSeconds
        let clock = latestSignals.values
            .compactMap({ $0.pts.seconds.isFinite ? $0.pts.seconds : nil }).max()
        for (id, sig) in latestSignals {
            let secs = sig.pts.seconds
            // L1: a non-finite-PTS signal can't be aged against the house clock, so
            // it would linger forever as a cut target for a source that emitted one
            // NaN/inf PTS then vanished. Treat it as stale (prune it). Finite-PTS
            // staleness (unplugged/frozen camera) is handled unchanged below.
            if !secs.isFinite {
                latestSignals.removeValue(forKey: id)
            } else if let clock, clock - secs > staleness {
                latestSignals.removeValue(forKey: id)
            }
        }

        let signals = Array(latestSignals.values)
        let framingEnabled = config.autoFrameEnabled
        let framingConfig = config.framing
        // Ingest UNDER the lock: `AutoDirector` is not thread-safe and shares
        // this lock with `setEnabled`/`updateConfig` (which reset/mutate it), so
        // an unlocked `ingest` would race a concurrent `reset()`. The director
        // never calls back into us, so there's no reentrancy holding it here.
        let decision = director.ingest(signals)
        let active = director.currentActiveSource
        lock.unlock()

        // Emit the decision OUTSIDE the lock (the user callback may reenter our
        // public API). Re-check `enabled` first so a decision computed just
        // before a `setEnabled(false)` isn't delivered after disable.
        if let decision {
            lock.lock(); let stillEnabled = enabled; lock.unlock()
            if stillEnabled { onDecision?(decision) }
        }

        guard framingEnabled else { return }
        // Only reframe the active source, off the active source's own signal
        // (avoids reframing a hero on a background source's update).
        if let active, active == signal.source {
            lock.lock()
            guard enabled else { lock.unlock(); return }
            let framer: AutoFramer
            if let existing = framers[active] { framer = existing }
            else { framer = AutoFramer(config: framingConfig); framers[active] = framer }
            lock.unlock()
            let crop = framer.update(faceBounds: merged.faceBounds)
            onFraming?(active, crop)
        }
    }
}
