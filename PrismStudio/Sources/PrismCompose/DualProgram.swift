import CoreMedia
import Foundation
import Metal
import os
import PrismCompositor
import PrismCore

/// Coordinates the primary (horizontal) program from the existing `RenderLoop`
/// with a `SecondaryComposition` (vertical), so one show emits both aspect
/// ratios (DESIGN.md §2.5).
///
/// ## Feeding the secondary (the design decision)
/// The secondary needs the *same per-tick source frames* the primary
/// composited — not the primary's finished program frame. Two consumers must
/// never pull the same `FrameMailbox` (it is one-producer/one-consumer, and
/// `take` is destructive), so `RenderLoop.onTickSnapshot` exposes the complete
/// frame set its compositor sampled. The app forwards that set through this
/// **push hook**, handing the same source buffers to both programs.
///
/// ## Off the primary's critical path
/// `submit` never blocks the caller and never runs the vertical composite
/// inline: it stores the latest `(frames, pts)` in a single-slot, latest-wins
/// buffer and kicks a dedicated serial queue that drains it. If the secondary
/// falls behind, intermediate submissions are **coalesced** (dropped, counted
/// in `Stats.coalesced`) — the vertical program degrades to a lower effective
/// fps rather than back-pressuring the show. Because the secondary owns a
/// distinct `MetalCompositor`, its GPU pass runs concurrently with the primary.
///
/// ## Perf budget (DESIGN.md §3.5)
/// The vertical program is a *second full composite*. At 1080×1920 (≈2.07 MP,
/// ~same pixel count as 1080p horizontal) budget ~another <4 ms GPU per frame on
/// the media/GPU engines; it runs on its own queue/compositor so it does not
/// add to the primary's <4 ms budget, but it does consume GPU + a second output
/// encode downstream. Coalescing bounds the cost when the GPU is contended.
public final class DualProgram: @unchecked Sendable {
    /// Receives every vertical program frame, on the secondary's serial queue.
    public typealias SecondaryConsumer = (VideoFrame) -> Void

    public struct Stats: Sendable {
        /// Calls to `submit`.
        public var submitted: UInt64 = 0
        /// Vertical frames actually composited and delivered.
        public var rendered: UInt64 = 0
        /// Submissions superseded before they could render (secondary behind).
        public var coalesced: UInt64 = 0
        /// Composite failures (logged; the loop continues).
        public var errors: UInt64 = 0
    }

    private let secondary: SecondaryComposition
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let logger = EngineLog.logger("compose.dual")

    private struct Shared {
        var scene = Scene(name: "empty")
        var reframe = ReframeMap.heroFill
        var consumer: SecondaryConsumer?
        /// A complete secondary tick. Scene + reframe live in the pending job,
        /// rather than in mutable side properties, so coalescing can never pair
        /// tick A's frames with tick B's transient meme/animation scene.
        var pending: (frames: [SourceID: VideoFrame], scene: Scene, reframe: ReframeMap,
                      pts: CMTime, duration: CMTime)?
        var draining = false
        var stats = Stats()
        /// Sources explicitly forgotten by the owner. A stale tick carrying one
        /// is filtered until the owner explicitly calls `attach(source:)`; mere
        /// frame presence cannot prove a genuine re-registration.
        var forgotten: Set<SourceID> = []
        /// Monotonic submit counter — bounds the `forgotten` set's lifetime (N1).
        var tickGeneration: UInt64 = 0
        /// Submit generation at which each id was forgotten. Pruned after a small
        /// TTL so a never-re-attached meme-churn UUID does not leak forever, while
        /// still filtering any stale pre-forget submission within the window (F22).
        var forgottenGeneration: [SourceID: UInt64] = [:]
        /// Fenced for discard on a color-mode/HDR swap (sol #5 #9). While set, a
        /// drained composite is NOT delivered to `consumer` and no new submission is
        /// queued — so an OLD (e.g. SDR) vertical frame can never reach the shared
        /// vertical sink AFTER the NEW program's first frame and revert it.
        var quiesced = false
    }

    /// Submits a forgotten id survives in `forgotten` before pruning (N1). `2`
    /// keeps the filter for any stale pre-forget submission (latest-wins
    /// coalescing means at most the next submit can still carry one) while
    /// bounding the set under meme churn.
    private static let forgottenTTLTicks: UInt64 = 2
    private let shared = OSAllocatedUnfairLock<Shared>(initialState: Shared())

    /// Wrap an existing secondary composition.
    public init(secondary: SecondaryComposition) {
        self.secondary = secondary
        self.queue = DispatchQueue(label: "studio.prism.compose.secondary", qos: .userInitiated)
        self.queue.setSpecific(key: queueKey, value: 1)
    }

    /// Build a vertical secondary (default 1080×1920) on `device`.
    ///
    /// `colorMode: .hdr` builds the vertical program in the SAME Rec.2020/HLG
    /// 10-bit HDR working space as the primary, so the 9:16 program (and its
    /// recording) reach HDR parity with the main program (Stage O sink-parity).
    public convenience init(device: MTLDevice, width: Int = 1080, height: Int = 1920,
                            colorMode: MetalCompositor.ColorMode = .sdr) throws {
        self.init(secondary: try SecondaryComposition(device: device, width: width, height: height, colorMode: colorMode))
    }

    /// The dynamic range the vertical program composites in.
    public var colorMode: MetalCompositor.ColorMode { secondary.colorMode }

    // MARK: - Configuration (thread-safe, effective next drained frame)

    /// The horizontal scene to reframe for the vertical program (keep this in
    /// sync with the primary's scene; on a switch, set both).
    public var scene: Scene {
        get { shared.withLock { $0.scene } }
        set { shared.withLock { $0.scene = newValue } }
    }

    /// How the scene maps into the vertical canvas.
    public var reframe: ReframeMap {
        get { shared.withLock { $0.reframe } }
        set { shared.withLock { $0.reframe = newValue } }
    }

    /// Vertical program frame consumer (encoders/preview/record). Set before use.
    public var onSecondaryFrame: SecondaryConsumer? {
        get { shared.withLock { $0.consumer } }
        set { shared.withLock { $0.consumer = newValue } }
    }

    public var stats: Stats { shared.withLock { $0.stats } }

    /// Vertical canvas size.
    public var size: (width: Int, height: Int) { (secondary.width, secondary.height) }

    // MARK: - The tick hook

    /// Feed the secondary this tick's source frames + PTS (the same dict/PTS the
    /// primary composited). A caller may also supply the exact dynamic scene and
    /// reframe evaluated for that primary tick; omitted values atomically snapshot
    /// the current `scene` / `reframe`. Non-blocking, latest-wins, off-thread.
    ///
    /// Call this once per program tick from the app's frame-assembly path (the
    /// same place it drives the primary `RenderLoop`).
    public func submit(frames: [SourceID: VideoFrame],
                       scene: Scene? = nil,
                       reframe: ReframeMap? = nil,
                       pts: CMTime,
                       duration: CMTime = .invalid) {
        let kick = shared.withLock { s -> Bool in
            s.stats.submitted += 1
            s.tickGeneration &+= 1
            // A pre-forget app snapshot may be submitted after `forget` returns.
            // Filter tombstoned ids; only explicit `attach` can make them live.
            let liveFrames = s.forgotten.isEmpty
                ? frames
                : frames.filter { !s.forgotten.contains($0.key) }
            // Prune ids that have outlived the filter window (N1) — AFTER filtering
            // this submit, so the guard still applies here. Explicit `attach` still
            // clears immediately; this only bounds never-re-attached churn UUIDs.
            if !s.forgotten.isEmpty {
                let gen = s.tickGeneration
                let expired = s.forgotten.filter {
                    gen &- (s.forgottenGeneration[$0] ?? gen) >= Self.forgottenTTLTicks
                }
                for id in expired { s.forgotten.remove(id); s.forgottenGeneration[id] = nil }
            }
            if s.pending != nil { s.stats.coalesced += 1 } // supersede an un-drained submission
            s.pending = (liveFrames, scene ?? s.scene, reframe ?? s.reframe, pts, duration)
            if s.draining { return false }
            s.draining = true
            return true
        }
        guard kick else { return }
        queue.async { [weak self] in self?.drain() }
    }

    /// Drain one latest pending submission. If another arrived while rendering,
    /// enqueue one more drain turn. Yielding the serial queue between turns lets
    /// rare forget/attach barriers retire even when the secondary is slower than
    /// the primary's continuous submit rate.
    private func drain() {
        let work: (job: (frames: [SourceID: VideoFrame], scene: Scene, reframe: ReframeMap,
                         pts: CMTime, duration: CMTime),
                   consumer: SecondaryConsumer?)? =
            shared.withLock { s in
                guard let p = s.pending else { s.draining = false; return nil }
                s.pending = nil
                return (p, s.consumer)
            }
        guard let work else { return }
        do {
            let frame = try secondary.composite(frames: work.job.frames,
                                                scene: work.job.scene,
                                                reframe: work.job.reframe,
                                                pts: work.job.pts,
                                                duration: work.job.duration)
            // Deliver only if not fenced for discard (sol #5 #9): a swap may have
            // quiesced this program while the composite was in flight; suppressing the
            // late frame keeps the OLD color mode from reaching the vertical sink after
            // the NEW program's first frame.
            let deliver = shared.withLock { s -> Bool in s.stats.rendered += 1; return !s.quiesced }
            if deliver { work.consumer?(frame) }
        } catch {
            shared.withLock { $0.stats.errors += 1 }
            logger.error("secondary composite failed: \(String(describing: error), privacy: .public)")
        }
        let continueDraining = shared.withLock { s -> Bool in
            if s.pending != nil { return true }
            s.draining = false
            return false
        }
        if continueDraining { queue.async { [weak self] in self?.drain() } }
    }

    /// Synchronous alternative: composite the vertical program with the current
    /// `scene`/`reframe`, returning the frame to the *calling* thread. For apps
    /// that want the second program inline on their own tick (accepting it on
    /// that thread's budget) rather than the coalescing background queue.
    ///
    /// ## Thread-safety contract
    /// `MetalCompositor` is single-threaded, so the inline path and the
    /// background `drain()` must never touch it concurrently. This routes the
    /// composite through the **same serial `queue`** as `drain` (via `sync`), so
    /// the two paths are mutually exclusive: the call blocks the caller only for
    /// as long as an in-flight drain (one coalesced composite) takes.
    ///
    /// Do NOT call this from `onSecondaryFrame` (the consumer runs on `queue`);
    /// re-entering `queue.sync` from the queue would deadlock. It is safe from
    /// the app's own tick thread, which is not `queue`.
    public func compositeInline(frames: [SourceID: VideoFrame],
                                pts: CMTime,
                                duration: CMTime = .invalid) throws -> VideoFrame {
        let (scene, reframe) = shared.withLock { ($0.scene, $0.reframe) }
        return try queue.sync {
            try secondary.composite(frames: frames, scene: scene, reframe: reframe,
                                    pts: pts, duration: duration)
        }
    }

    /// Drop a removed source from the secondary compositor's last-known set and
    /// tombstone it, so a pending/draining tick dict captured before this call
    /// cannot re-insert (re-pin) the removed source (F22). A later frame alone
    /// does not clear the tombstone; the source owner must explicitly `attach`.
    public func forget(source: SourceID) {
        shared.withLock { state in
            _ = state.forgotten.insert(source)
            state.forgottenGeneration[source] = state.tickGeneration
            // Also scrub a job that is pending but not yet copied by `drain`.
            if var pending = state.pending {
                pending.frames[source] = nil
                state.pending = pending
            }
        }
        // Retire work already copied by `drain` before installing the compositor
        // tombstone. The shared forgotten bit remains set throughout, so new
        // submissions cannot carry this source across the barrier.
        let unregister = { self.secondary.forget(source: source) }
        if DispatchQueue.getSpecific(key: queueKey) != nil { unregister() }
        else { queue.sync(execute: unregister) }
    }

    /// Explicitly re-register a source after `forget`. Kept separate from
    /// `submit` so a stale pre-removal snapshot can never resurrect a source.
    /// The registration is fenced behind already-enqueued secondary work before
    /// the compositor tombstone is cleared; otherwise a stale job copied before
    /// `forget` could fold after a rapid `attach` and re-pin the dead frame.
    public func attach(source: SourceID) {
        let register = { self.secondary.attach(source: source) }
        if DispatchQueue.getSpecific(key: queueKey) != nil { register() }
        else { queue.sync(execute: register) }
        // Only make submitted frames live after every stale drain has retired
        // and the compositor tombstone is cleared.
        shared.withLock { s in
            s.forgotten.remove(source)
            s.forgottenGeneration[source] = nil
        }
    }

    /// Sources currently in the `forgotten` filter set (diagnostics / headless
    /// verification that the set stays bounded — N1). Thread-safe.
    public var forgottenSourceIDs: [SourceID] {
        shared.withLock { Array($0.forgotten) }
    }

    // MARK: - Discard fence (color-mode / HDR swap)

    /// Fence this program before it is discarded on an HDR / color-mode swap
    /// (sol #5 #9). `setHDREnabled` joins only the PRIMARY render loop, but the OLD
    /// `DualProgram` can still hold enqueued work that drains asynchronously — so a
    /// stale OLD-mode vertical frame could arrive AFTER the NEW program's first
    /// frame (reverting the preview / seeding a new recorder's first frame). After
    /// this returns:
    ///   • any pending (un-drained) submission is dropped, and
    ///   • any in-flight `drain` composite is barrier-joined and its delivery
    ///     suppressed (gated on `quiesced` before it reaches `consumer`),
    /// so NO further frame reaches the shared vertical sink. Reversible via
    /// `resume` (the HDR-swap failure path revives the old program). Safe from any
    /// thread except the secondary `queue` itself (it barrier-joins that queue).
    public func quiesce() {
        shared.withLock { s in
            s.quiesced = true
            s.pending = nil
        }
        if DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
    }

    /// Re-arm a quiesced program: the HDR/color-mode swap aborted and revived this
    /// (old) vertical program, so its submissions must deliver again (sol #5 #9).
    public func resume() {
        shared.withLock { $0.quiesced = false }
    }

    /// Whether this program is fenced for discard (headless verification — sol #5 #9).
    public var isQuiesced: Bool { shared.withLock { $0.quiesced } }
}
