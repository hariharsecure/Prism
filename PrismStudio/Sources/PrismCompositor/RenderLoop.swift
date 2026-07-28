import CoreMedia
import Darwin
import Foundation
import os
import PrismCore

/// Pull-based program render loop (DESIGN.md §3.3).
///
/// One dedicated thread ticks at the output fps. Each tick with target time
/// `T` (house clock) computes `deadline = T − latencyCompensation`, pulls the
/// newest qualifying frame from every source mailbox, composites, and hands
/// the program frame to the consumer callback — all on the render thread.
///
/// ## Why `mach_wait_until` on a raw Thread (not Timer/RunLoop)
/// - `Timer` fires on a RunLoop, whose wakeups are coalesced/deferred by the
///   scheduler — worst-case jitter is milliseconds, which at 60 fps (16.7 ms
///   budget) eats a meaningful slice of the frame and makes deadlines mushy.
/// - `mach_wait_until` sleeps until an absolute host-clock instant — the same
///   clock family as `HouseClock`/capture PTS — giving sub-millisecond wakeup
///   on a `.userInteractive` thread with no runloop machinery on the hot path.
/// - Absolute-time scheduling (`next += interval`) is drift-free: late wakeups
///   don't accumulate. CVDisplayLink is the display-locked alternative, but
///   the *program* clock should follow output fps, not the panel's refresh.
public final class RenderLoop: @unchecked Sendable {
    /// Receives every program frame, called on the render thread — do minimal
    /// work and hand off (encoders/preview have their own queues).
    public typealias ProgramConsumer = (VideoFrame) -> Void

    /// Exact source selection for one successfully-composited primary tick.
    /// This is the complete last-known set actually sampled by the compositor:
    /// newly deadline-qualified mailbox frames plus held frames for sources that
    /// did not emit on this tick. It is not a capture-callback "latest"
    /// approximation. Secondary programs use it to render the same
    /// animation/GIF/video frame at the same house PTS.
    public struct TickSnapshot: Sendable {
        public let frames: [SourceID: VideoFrame]
        /// Exact single scene rendered for this tick when representable. Normal
        /// provider ticks and hard-step transition endpoints provide one; a
        /// blended/effect/stacked transition reports nil.
        public let evaluatedScene: Scene?
        /// Static program beneath `evaluatedScene`, used by secondary reframers
        /// to distinguish transient provider layers from resting layers.
        public let restingScene: Scene
        public let pts: CMTime
        public let duration: CMTime
    }
    public typealias TickConsumer = (TickSnapshot) -> Void

    /// Transforms the deadline-qualified source frames for a tick, on the render
    /// thread, given the tick's house-time PTS. This is the seam that lets
    /// *time-varying* per-source effects (the App's `SourceEffectPipeline`
    /// tile-flicker / strobe / beat-pulse) advance on the **render cadence**
    /// against each source's held raw frame, using ONE tick PTS for every source
    /// — instead of being baked at source-callback arrival (F5). It is applied
    /// after the mailbox frames are pulled and before `composite`, so the
    /// returned dict is exactly what the compositor renders AND what
    /// `onTickSnapshot` publishes (keeping the animated result in parity across
    /// both programs). The processor may inject an entry for a source that did
    /// not emit this tick (its held raw re-animated at the new PTS) so a low-fps
    /// source still animates every tick. Identity (frames unchanged) when nil.
    /// Called on the render thread; must be fast and thread-safe.
    public typealias FrameProcessor = (_ frames: [SourceID: VideoFrame], _ pts: CMTime) -> [SourceID: VideoFrame]

    /// Produces the scene to composite for a tick, given the tick's
    /// house-time PTS — the hook that lets an animation system (e.g.
    /// PrismAnimation's `AnimatedScene.evaluate`) drive per-tick layer state
    /// without this module depending on it. Called on the render thread; must
    /// be fast (pure math, no I/O) and thread-safe.
    public typealias SceneProvider = (CMTime) -> Scene

    public struct Stats: Sendable {
        public var ticks: UInt64 = 0
        /// Ticks that produced and delivered a program frame.
        public var framesDelivered: UInt64 = 0
        /// Ticks where composite threw (logged; loop continues).
        public var compositeErrors: UInt64 = 0
        /// Ticks that overran a full frame interval (deadline pressure signal).
        public var lateTicks: UInt64 = 0
        /// Ticks rendered mid-transition (two scenes composited).
        public var transitionTicks: UInt64 = 0
        /// Transitions that ran to completion and swapped `scene`
        /// (hard cuts and replaced transitions don't count).
        public var transitionsCompleted: UInt64 = 0
    }

    public let fps: Double

    /// Perf instrumentation sink (Phase 1d). When set, each tick records total
    /// frame work + deadline slack and the render-mailbox queue depths; attached
    /// mailboxes and the compositor share this same instance so GPU spans and
    /// drop counters land in one aggregator. Nil = no instrumentation overhead.
    public var metrics: RenderMetrics? {
        didSet { compositor.metrics = metrics }
    }

    private let compositor: MetalCompositor
    private let logger = EngineLog.logger("renderloop")
    private let signposter = EngineLog.signposter("compositor")

    #if DEBUG
    /// Test-only seam (atomic re-pin fix): invoked on the render thread AFTER the
    /// mailbox+epoch snapshot critical section and BEFORE the tick's frames are
    /// pulled. A negative-control test forces a `removeMailbox`+`setMailbox` of the
    /// same id here to land a rapid reattach in the exact window between the
    /// mailbox snapshot and the epoch capture that the fix closes. Nil in release.
    var _test_betweenSnapshotAndEpochCapture: (() -> Void)?
    /// Test-only toggle: when true, the tick's captured epoch map is taken AFTER
    /// the seam above (outside the snapshot lock) instead of atomically inside it
    /// — reproducing the ORIGINAL non-atomic capture (the bug). The negative
    /// control asserts this makes the stale pre-forget frame ACCEPTED (red).
    /// Default false = the atomic fix. No effect in release.
    var _test_captureEpochsAfterSnapshot = false
    #endif

    /// An in-flight scene switch, anchored in house time.
    private struct ActiveTransition {
        /// Identity token: the finishing tick only swaps/clears if *this*
        /// transition is still the active one (a mid-flight `switchScene`
        /// replaces it).
        let token: UUID
        let schedule: TransitionSchedule
        let incoming: Scene
        /// House-time seconds at which the transition clock started.
        let startSeconds: Double
        let completion: ((Scene) -> Void)?
    }

    private struct Shared {
        var scene = Scene(name: "empty")
        var sceneProvider: SceneProvider?
        var transition: ActiveTransition?
        var mailboxes: [SourceID: FrameMailbox] = [:]
        var latencyCompensation: TimeInterval = 0
        var consumer: ProgramConsumer?
        var tickConsumer: TickConsumer?
        var frameProcessor: FrameProcessor?
        var running = false
        /// True from thread spawn until the render thread's exit path has run.
        /// `start()` refuses while set — two threads must never composite.
        var threadActive = false
        /// Per-generation exit signal: created by `start()`, signaled by the
        /// render thread on exit, awaited by `stop()`. A fresh semaphore per
        /// start means a timed-out wait can never leave a stale signal that
        /// unbalances a later stop().
        var exitSignal: DispatchSemaphore?
        var stats = Stats()
    }
    private let shared: OSAllocatedUnfairLock<Shared>

    /// - Parameters:
    ///   - compositor: owned by this loop from `start()` on — no other thread
    ///     may call `composite` while running.
    ///   - fps: program output rate (default 60).
    public init(compositor: MetalCompositor, fps: Double = 60) {
        precondition(fps > 0)
        self.compositor = compositor
        self.fps = fps
        self.shared = OSAllocatedUnfairLock(initialState: Shared())
        compositor.enableCompositeSnapshotExport()
    }

    // MARK: - Configuration (thread-safe, effective next tick)

    /// The scene to render.
    public var scene: Scene {
        get { shared.withLock { $0.scene } }
        // A direct scene assignment (a manual/live edit) supersedes any in-flight
        // transition: without clearing it, the transition would complete a tick
        // later and overwrite this edit with its own `incoming` (Codex C4).
        set { shared.withLock { $0.scene = newValue; $0.transition = nil } }
    }

    /// Optional per-tick scene source. When set, each tick composites
    /// `sceneProvider(pts)` instead of the static `scene` (which stays the
    /// resting/base scene for transitions). This is how animated scenes run:
    /// the integrator wraps an `AnimatedScene` and returns `evaluate(at:)`.
    public var sceneProvider: SceneProvider? {
        get { shared.withLock { $0.sceneProvider } }
        set { shared.withLock { $0.sceneProvider = newValue } }
    }

    // MARK: - Scene transitions

    /// Switch to `incoming`, animated by `transition`. Non-blocking: this
    /// starts a house-time transition clock and returns; the render thread
    /// evaluates `transition.progress` each tick and composites both scenes
    /// (crossfade mix or overlay stack) until `duration` elapses, then swaps
    /// `scene` to `incoming` and calls `completion` (on the render thread).
    ///
    /// - A `nil` transition or `duration <= 0` is a hard cut: `scene` swaps
    ///   immediately and `completion` runs on the calling thread.
    /// - Calling again mid-transition replaces the running transition: its
    ///   target scene is committed as the new outgoing base (a cut to the old
    ///   target, then the new transition), and its completion is dropped.
    /// - Stats: mid-transition ticks count in `Stats.transitionTicks`;
    ///   a finished swap increments `Stats.transitionsCompleted`.
    public func switchScene(to incoming: Scene,
                            transition: TransitionSchedule?,
                            completion: ((Scene) -> Void)? = nil) {
        guard let transition, transition.duration > 0 else {
            shared.withLock { state in
                state.transition = nil
                state.scene = incoming
            }
            completion?(incoming)
            return
        }
        let active = ActiveTransition(token: UUID(),
                                      schedule: transition,
                                      incoming: incoming,
                                      startSeconds: HouseClock.nowSeconds(),
                                      completion: completion)
        shared.withLock { state in
            if let replaced = state.transition {
                // Interrupt: the old target becomes the outgoing base.
                state.scene = replaced.incoming
            }
            state.transition = active
        }
    }

    /// Aligned-mode compensation, seconds: each tick pulls frames with
    /// `pts ≤ now − latencyCompensation`. 0 = "Fastest" behavior (DESIGN.md §3.3).
    public var latencyCompensation: TimeInterval {
        get { shared.withLock { $0.latencyCompensation } }
        set { shared.withLock { $0.latencyCompensation = max(0, newValue) } }
    }

    /// Program frame consumer; set before `start()`.
    public var onProgramFrame: ProgramConsumer? {
        get { shared.withLock { $0.consumer } }
        set { shared.withLock { $0.consumer = newValue } }
    }

    /// Receives the exact source-frame dict for each delivered primary tick,
    /// on the render thread immediately before `onProgramFrame`.
    public var onTickSnapshot: TickConsumer? {
        get { shared.withLock { $0.tickConsumer } }
        set { shared.withLock { $0.tickConsumer = newValue } }
    }

    /// Per-tick, render-thread transform of the pulled source frames (F5). See
    /// `FrameProcessor`. Set before or during running; effective next tick.
    public var frameProcessor: FrameProcessor? {
        get { shared.withLock { $0.frameProcessor } }
        set { shared.withLock { $0.frameProcessor = newValue } }
    }

    /// Attach (or replace) the mailbox feeding a source's layers. Clears any
    /// forget-tombstone in the compositor so a re-registered source composites
    /// again (see `MetalCompositor.forget`/`attach`).
    public func setMailbox(_ mailbox: FrameMailbox, for id: SourceID) {
        mailbox.metrics = metrics // single choke point: attribute this input's drops/deliveries
        shared.withLock { $0.mailboxes[id] = mailbox }
        compositor.attach(source: id)
    }

    /// Detach a source's mailbox and drop the compositor's retained last
    /// frame for it — a removed source must not pin its final IOSurface.
    public func removeMailbox(for id: SourceID) {
        shared.withLock { _ = $0.mailboxes.removeValue(forKey: id) }
        compositor.forget(source: id)
    }

    public var stats: Stats { shared.withLock { $0.stats } }

    /// Whether a render thread is currently accepting ticks (`running`). Distinct
    /// from "a previous thread is still draining after a timed-out `stop()`"
    /// (`start()` also refuses that, but the loop is NOT running). A resume/retry
    /// caller uses this to tell "someone already recovered the loop" (stop retrying)
    /// from "still draining" (keep retrying) — see `start()`'s two refusal cases.
    public var isRunning: Bool { shared.withLock { $0.running } }

    /// Read-only registration snapshot for integration diagnostics/tests.
    public var registeredSourceIDs: Set<SourceID> {
        shared.withLock { Set($0.mailboxes.keys) }
    }

    // MARK: - Lifecycle

    /// Spawn the render thread.
    /// - Returns: `true` if a render thread was spawned. `false` if refused:
    ///   the loop is already running, or a previous render thread has not
    ///   finished exiting yet (a `stop()` timed out) — starting then would put
    ///   two threads inside the non-thread-safe compositor, so the call is
    ///   rejected until the old thread drains; retry after it exits.
    @discardableResult
    public func start() -> Bool {
        let exitSignal = DispatchSemaphore(value: 0)
        let accepted = shared.withLock { state -> Bool in
            guard !state.running, !state.threadActive else { return false }
            state.running = true
            state.threadActive = true
            state.exitSignal = exitSignal
            return true
        }
        guard accepted else {
            logger.error("start() refused: loop already running or previous render thread has not exited")
            return false
        }
        let thread = Thread { [weak self] in self?.run(exitSignal: exitSignal) }
        thread.name = "studio.prism.renderloop"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    /// Signal the render thread to exit and join it deterministically (the
    /// thread confirms its own exit through this generation's semaphore).
    ///
    /// - Returns: `true` when the render thread has CONFIRMED it exited its tick
    ///   (fully quiesced — no code is still inside `composite` / the shared
    ///   frame processor), or when there was no live thread. `false` if the
    ///   thread was still wedged past the bounded wait: the loop stays poisoned
    ///   (`start()` keeps refusing until it drains) AND a caller that is about to
    ///   stand up a *replacement* loop over shared non-thread-safe state (e.g. the
    ///   HDR rebuild's `SourceEffectGPU`/`lastRaw`) MUST NOT proceed — starting
    ///   then would run two threads over that state at once (HIGH-5).
    @discardableResult
    public func stop() -> Bool { stop(timeout: 2.0) }

    /// `stop()` with a caller-chosen quiesce budget. Internal so tests can pass a
    /// short timeout instead of paying the full 2 s; production always uses 2 s.
    @discardableResult
    func stop(timeout: TimeInterval) -> Bool {
        let exitSignal: DispatchSemaphore? = shared.withLock { state in
            state.running = false
            return state.threadActive ? state.exitSignal : nil
        }
        guard let exitSignal else { return true } // no live thread — already quiesced
        if exitSignal.wait(timeout: .now() + timeout) == .timedOut {
            logger.error("render thread did not exit within \(timeout)s — restart refused until it drains")
            return false
        }
        // Re-arm so a concurrent/later stop() of this generation also returns
        // immediately (the thread is confirmed gone).
        exitSignal.signal()
        // Idle seam (stream disarm): the render thread has CONFIRMED it exited its
        // tick — no code is inside `composite`, so the compositor's output pool
        // holds only free (non-in-flight) buffers. Shed any excess IOSurfaces a
        // past spike left resident (G2 hardening). Safe here and only here: this
        // runs once per stop, never on the per-frame hot path.
        compositor.flushExcessBuffers()
        return true
    }

    // MARK: - Render thread

    private func run(exitSignal: DispatchSemaphore) {
        defer {
            shared.withLock { $0.threadActive = false }
            exitSignal.signal()
        }

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let numer = UInt64(timebase.numer)
        let denom = UInt64(timebase.denom)
        let intervalNs = UInt64((1_000_000_000.0 / fps).rounded())
        let intervalTicks = intervalNs * denom / numer
        let frameDuration = CMTime(value: Int64(intervalNs), timescale: 1_000_000_000)

        // Host-tick → nanosecond conversion for the perf spans (numer/denom are
        // the mach timebase). Deltas are sub-frame, so the multiply cannot overflow.
        func toNanos(_ ticks: UInt64) -> Int64 { Int64(ticks &* numer / denom) }

        var nextTick = mach_absolute_time() + intervalTicks

        while shared.withLock({ $0.running }) {
            mach_wait_until(nextTick)
            let tickTime = nextTick
            nextTick += intervalTicks
            let now = mach_absolute_time()
            if now >= nextTick {
                // Fell ≥1 full frame behind: resynchronize instead of
                // spiraling through a burst of catch-up ticks.
                shared.withLock { $0.stats.lateTicks += 1 }
                nextTick = now + intervalTicks
            }

            // Tick target in house time (host clock ticks → nanoseconds).
            let pts = CMTime(value: Int64(tickTime * numer / denom), timescale: 1_000_000_000)

            // HIGH-3 / atomic re-pin fix: snapshot the mailbox set AND the
            // compositor's per-source registration epochs under ONE critical
            // section. `setMailbox`/`removeMailbox` mutate `mailboxes` under this
            // SAME lock BEFORE they call `compositor.attach`/`forget`, so holding
            // it here means no `forget(±reattach)` can interleave between the
            // mailbox snapshot and the epoch capture. A frame pulled from a given
            // mailbox snapshot therefore always carries the epoch that was current
            // for that same snapshot: a forget (and maybe same-ID reattach) that
            // lands AFTER this section moves the live epoch, so the stale
            // pre-forget frame — still carrying the old epoch — is rejected by
            // `foldAndSnapshot` (previously the epoch was captured on a separate
            // line, so a reattach in that gap re-stamped the stale frame with the
            // post-attach epoch and it was wrongly accepted).
            let (scene, provider, transition, mailboxes, compensation, tickConsumer, frameProcessor, consumer, atomicEpochs) = shared.withLock {
                $0.stats.ticks += 1
                let epochs = compositor.captureSourceEpochs()
                return ($0.scene, $0.sceneProvider, $0.transition,
                        $0.mailboxes, $0.latencyCompensation, $0.tickConsumer,
                        $0.frameProcessor, $0.consumer, epochs)
            }

            #if DEBUG
            // Seam + neutralization toggle for the negative-control test only.
            _test_betweenSnapshotAndEpochCapture?()
            let capturedEpochs = _test_captureEpochsAfterSnapshot
                ? compositor.captureSourceEpochs()   // NEGATIVE CONTROL: non-atomic (the bug)
                : atomicEpochs                        // fix: atomic with the mailbox snapshot
            #else
            let capturedEpochs = atomicEpochs
            #endif

            let deadline = CMTimeSubtract(pts, CMTime(seconds: compensation, preferredTimescale: 1_000_000_000))

            // Queue-depth instrumentation: sample the render mailboxes' occupancy
            // BEFORE the take loop drains them — items/bytes/oldest-age the
            // producers built up since the last tick. A brief per-mailbox lock;
            // no effect on the frames actually pulled.
            if let metrics {
                var items = 0, bytes = 0
                var oldestAgeMs = 0.0
                let nowSec = pts.seconds
                for (_, mailbox) in mailboxes {
                    let d = mailbox.depthSample(nowSeconds: nowSec)
                    items += d.items
                    bytes += d.bytes
                    oldestAgeMs = max(oldestAgeMs, d.oldestAgeMs)
                }
                metrics.recordQueueDepth(items: items, bytes: bytes, oldestAgeMs: oldestAgeMs, media: .video)
            }

            var frames: [SourceID: VideoFrame] = [:]
            frames.reserveCapacity(mailboxes.count)
            for (id, mailbox) in mailboxes {
                // allowFuture: on cold start a source's first frame may sit
                // just ahead of the compensated deadline — show it rather
                // than a black program.
                if let frame = mailbox.take(deadline: deadline, allowFuture: true) {
                    frames[id] = frame
                }
            }

            // F5: advance time-varying per-source effects on the render tick,
            // against each source's held raw frame, at this one tick PTS — so a
            // still/low-fps source still flickers/pulses at render cadence and
            // every source shares one coherent phase clock.
            if let frameProcessor {
                let fxStart = mach_absolute_time()
                frames = frameProcessor(frames, pts)
                metrics?.recordCPU(.sourceFX, nanos: toNanos(mach_absolute_time() &- fxStart))
            }

            // Hand the pull-time epoch snapshot to the compositor for this tick's
            // fold (HIGH-3). Set every tick (fully replaced), so a stale carry-over
            // can never mis-gate a later tick.
            compositor.setPendingCapturedEpochs(capturedEpochs)

            let interval = signposter.beginInterval("composite")
            var finished: ActiveTransition?
            do {
                let program: VideoFrame
                var tickScene: Scene?
                var tickRestingScene = scene

                if let t = transition {
                    let elapsed = pts.seconds - t.startSeconds
                    if elapsed >= t.schedule.duration {
                        // Done: swap to the incoming scene (only if this
                        // transition wasn't replaced since the snapshot).
                        let token = t.token
                        let incoming = t.incoming
                        let didFinish = shared.withLock { state -> Bool in
                            guard state.transition?.token == token else { return false }
                            state.transition = nil
                            state.scene = incoming
                            state.stats.transitionsCompleted += 1
                            return true
                        }
                        if didFinish { finished = t }
                        tickScene = t.incoming
                        tickRestingScene = t.incoming
                        program = try compositor.composite(frames: frames, scene: t.incoming,
                                                           pts: pts, duration: frameDuration)
                    } else {
                        // The RenderLoop is the ONE transition clock (B4): the
                        // schedule's scene closures are pure functions of this
                        // `elapsed`, so a prebuilt/deferred schedule can never
                        // desync from a start captured at build time.
                        let outgoing = t.schedule.outgoingScene?(elapsed) ?? provider?(pts) ?? scene
                        let incoming = t.schedule.incomingScene?(elapsed) ?? t.incoming
                        switch t.schedule.blend {
                        case .crossfade:
                            let mix = Float(min(max(t.schedule.progress(elapsed), 0), 1))
                            if mix <= 0 {
                                tickScene = outgoing
                                tickRestingScene = scene
                            } else if mix >= 1 {
                                tickScene = incoming
                                tickRestingScene = t.incoming
                            }
                            program = try compositor.composite(frames: frames,
                                                               sceneA: outgoing, sceneB: incoming,
                                                               mix: mix, pts: pts, duration: frameDuration)
                        case .overlay:
                            // Incoming under, outgoing over — the providers'
                            // layer motion (fed by the same progress curve)
                            // reveals the incoming scene; no extra blend.
                            program = try compositor.composite(frames: frames,
                                                               stack: [incoming, outgoing],
                                                               pts: pts, duration: frameDuration)
                        case .effect(let fx):
                            // Pixel/tile GPU effect: render A + B, then blend
                            // per-pixel via the compositor's FX shader (the real
                            // per-pixel look, live — no more nil→crossfade).
                            let e = Float(min(max(t.schedule.progress(elapsed), 0), 1))
                            let raw = Float(t.schedule.rawProgress?(elapsed) ?? Double(e))
                            program = try compositor.composite(frames: frames,
                                                               sceneA: outgoing, sceneB: incoming,
                                                               effect: fx, progress: e, rawProgress: raw,
                                                               pts: pts, duration: frameDuration)
                        }
                        shared.withLock { $0.stats.transitionTicks += 1 }
                    }
                } else {
                    let evaluated = provider?(pts) ?? scene
                    tickScene = evaluated
                    program = try compositor.composite(frames: frames,
                                                       scene: evaluated,
                                                       pts: pts, duration: frameDuration)
                }
                signposter.endInterval("composite", interval)
                // Completion is a lifecycle fence, not just a success callback:
                // run it before consumers so an integrator can clear per-
                // transition secondary state for this finishing tick.
                if let finished { finished.completion?(finished.incoming) }
                // `frames` contains this tick's mailbox deltas. The compositor
                // also sampled its retained last-known frames; publish that
                // complete exact set so a coalesced/late-enabled secondary does
                // not miss a prepared still or a low-fps meme source.
                let compositedFrames = compositor.consumeLastCompositeSnapshot()
                tickConsumer?(TickSnapshot(frames: compositedFrames,
                                           evaluatedScene: tickScene,
                                           restingScene: tickRestingScene,
                                           pts: pts,
                                           duration: frameDuration))
                consumer?(program)
                shared.withLock { $0.stats.framesDelivered += 1 }
            } catch {
                signposter.endInterval("composite", interval)
                // The transition was already atomically committed above. Its
                // cleanup must still run if rendering the final frame failed.
                if let finished { finished.completion?(finished.incoming) }
                _ = compositor.consumeLastCompositeSnapshot()
                shared.withLock { $0.stats.compositeErrors += 1 }
                logger.error("composite failed: \(String(describing: error), privacy: .public)")
            }

            // THE number that matters most (Phase 1d): total CPU work this tick,
            // and how much of the frame budget was left before the next scheduled
            // tick (negative = the frame overran its deadline). `now` was captured
            // at the very start of tick processing; `nextTick` is the next
            // scheduled wake. Two integer writes under an unfair lock — the
            // measurement cannot perturb the frame it measures.
            if let metrics {
                let workEnd = mach_absolute_time()
                let workNs = toNanos(workEnd &- now)
                let slackNs = (Int64(bitPattern: nextTick) &- Int64(bitPattern: workEnd))
                    * Int64(numer) / Int64(denom)
                metrics.recordFrame(workNanos: workNs, deadlineSlackNanos: slackNs)
            }
        }
    }
}
