import CoreMedia
import Foundation
import Metal
import os
import PrismCompositor
import PrismCore

/// A second **preview** program (studio mode, Stage 1). It composites the SAME
/// 16:9 program canvas as the primary `RenderLoop`, but from a *separate*
/// `previewScene` the operator edits **off-air** — so a hidden/moved/re-styled
/// layer shows in the preview monitor while the live program is byte-unchanged.
/// `take()` (in the app) hard-cuts `previewScene → scene`; this type only ever
/// renders the preview and hands it to a preview-only sink.
///
/// ## Relationship to `DualProgram`
/// This is deliberately modeled on `DualProgram` (the vertical 9:16 precedent):
/// same off-the-primary's-critical-path threading, same latest-wins coalescing,
/// the same forget/attach source-tombstone barrier, and the same color-mode
/// discard fence (`quiesce`/`resume`). The ONE structural difference is that the
/// preview program renders the FULL scene onto the **same** canvas size as the
/// primary — there is no `ReframeMap` / `VerticalScene` reframe. So it owns a
/// plain `MetalCompositor` at `canvasSize` (not a `SecondaryComposition`), and
/// `submit` carries a `Scene` but no `reframe`.
///
/// ## Off the primary's critical path (identical contract to `DualProgram`)
/// `submit` never blocks the caller and never composites inline: it stores the
/// latest `(frames, scene, pts)` in a single-slot, latest-wins buffer and kicks
/// a dedicated serial queue that drains it. If the preview falls behind,
/// intermediate submissions are **coalesced** (dropped, counted in
/// `Stats.coalesced`). Because it owns a distinct `MetalCompositor`, its GPU
/// pass runs concurrently with the primary; the shared `MetalLibraryCache`
/// makes its MSL a zero-compile cache hit (no extra shader compile).
///
/// ## Why it can never touch the program output
/// This type has NO reference to `ProgramFanOut`, the primary `RenderLoop`, or
/// any program sink. Its only output is `onPreviewFrame`, wired (in the app) to
/// a preview-only `ProgramPreviewStore`. There is structurally no path from a
/// preview edit to the live program buffer — that is the off-air guarantee.
public final class PreviewProgram: @unchecked Sendable {
    /// Receives every preview program frame, on the preview's serial queue.
    public typealias PreviewConsumer = (VideoFrame) -> Void

    public struct Stats: Sendable {
        /// Calls to `submit`.
        public var submitted: UInt64 = 0
        /// Preview frames actually composited and delivered.
        public var rendered: UInt64 = 0
        /// Submissions superseded before they could render (preview behind).
        public var coalesced: UInt64 = 0
        /// Composite failures (logged; the loop continues).
        public var errors: UInt64 = 0
    }

    /// The preview-canvas compositor (own instance, never shared with the primary
    /// or the vertical program — `MetalCompositor` is single-threaded, so sharing
    /// would race the primary render). Sized to the SAME program canvas.
    private let compositor: MetalCompositor
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let logger = EngineLog.logger("compose.preview")

    private struct Shared {
        var scene = Scene(name: "preview")
        var consumer: PreviewConsumer?
        /// A complete preview tick. Scene lives in the pending job (not a mutable
        /// side property), so coalescing can never pair tick A's frames with tick
        /// B's scene.
        var pending: (frames: [SourceID: VideoFrame], scene: Scene,
                      pts: CMTime, duration: CMTime)?
        var draining = false
        var stats = Stats()
        /// Sources explicitly forgotten by the owner (mirror `DualProgram`). A
        /// stale tick carrying one is filtered until an explicit `attach`.
        var forgotten: Set<SourceID> = []
        var tickGeneration: UInt64 = 0
        var forgottenGeneration: [SourceID: UInt64] = [:]
        /// Fenced for discard on a color-mode/HDR swap (mirror `DualProgram`).
        var quiesced = false
    }

    /// Ticks a forgotten id survives before pruning (mirror `DualProgram.N1`).
    private static let forgottenTTLTicks: UInt64 = 2
    private let shared = OSAllocatedUnfairLock<Shared>(initialState: Shared())

    /// Adopt a pre-built compositor.
    ///
    /// - Warning: the compositor MUST be a *distinct* instance from the primary's
    ///   (own command queue / caches / pool) and sized to the program canvas —
    ///   `MetalCompositor` is single-threaded. Prefer `init(device:width:height:)`.
    ///   Kept internal-visible-as-public for in-module construction / tests.
    public init(compositor: MetalCompositor) {
        self.compositor = compositor
        self.queue = DispatchQueue(label: "studio.prism.compose.preview", qos: .userInitiated)
        self.queue.setSpecific(key: queueKey, value: 1)
    }

    /// Build a preview program at the program canvas size on `device`.
    ///
    /// `colorMode: .hdr` builds the preview in the SAME Rec.2020/HLG 10-bit HDR
    /// working space as the primary, so an HDR toggle keeps the preview at parity
    /// (mirrors the `DualProgram` HDR convenience init).
    public convenience init(device: MTLDevice, width: Int, height: Int,
                            colorMode: MetalCompositor.ColorMode = .sdr) throws {
        self.init(compositor: try MetalCompositor(device: device, width: width, height: height, colorMode: colorMode))
    }

    /// The dynamic range the preview program composites in (mirrors the primary's).
    public var colorMode: MetalCompositor.ColorMode { compositor.colorMode }

    /// Preview canvas size.
    public var size: (width: Int, height: Int) { (compositor.width, compositor.height) }

    // MARK: - Configuration (thread-safe, effective next drained frame)

    /// The scene the preview program renders (the operator's off-air edit target).
    public var scene: Scene {
        get { shared.withLock { $0.scene } }
        set { shared.withLock { $0.scene = newValue } }
    }

    /// Preview program frame consumer (the preview monitor store). Set before use.
    public var onPreviewFrame: PreviewConsumer? {
        get { shared.withLock { $0.consumer } }
        set { shared.withLock { $0.consumer = newValue } }
    }

    public var stats: Stats { shared.withLock { $0.stats } }

    // MARK: - The tick hook

    /// Feed the preview this tick's source frames + PTS (the SAME dict/PTS the
    /// primary composited — fed off `RenderLoop.TickSnapshot.frames`, never the
    /// destructive single-consumer mailboxes). A caller may supply the exact
    /// scene to render; omitting it atomically snapshots the current `scene`.
    /// Non-blocking, latest-wins, off-thread.
    public func submit(frames: [SourceID: VideoFrame],
                       scene: Scene? = nil,
                       pts: CMTime,
                       duration: CMTime = .invalid) {
        let kick = shared.withLock { s -> Bool in
            s.stats.submitted += 1
            s.tickGeneration &+= 1
            let liveFrames = s.forgotten.isEmpty
                ? frames
                : frames.filter { !s.forgotten.contains($0.key) }
            if !s.forgotten.isEmpty {
                let gen = s.tickGeneration
                let expired = s.forgotten.filter {
                    gen &- (s.forgottenGeneration[$0] ?? gen) >= Self.forgottenTTLTicks
                }
                for id in expired { s.forgotten.remove(id); s.forgottenGeneration[id] = nil }
            }
            if s.pending != nil { s.stats.coalesced += 1 } // supersede an un-drained submission
            s.pending = (liveFrames, scene ?? s.scene, pts, duration)
            if s.draining { return false }
            s.draining = true
            return true
        }
        guard kick else { return }
        queue.async { [weak self] in self?.drain() }
    }

    /// Drain one latest pending submission (mirror `DualProgram.drain`).
    private func drain() {
        let work: (job: (frames: [SourceID: VideoFrame], scene: Scene,
                         pts: CMTime, duration: CMTime),
                   consumer: PreviewConsumer?)? =
            shared.withLock { s in
                guard let p = s.pending else { s.draining = false; return nil }
                s.pending = nil
                return (p, s.consumer)
            }
        guard let work else { return }
        do {
            let frame = try compositor.composite(frames: work.job.frames,
                                                 scene: work.job.scene,
                                                 pts: work.job.pts,
                                                 duration: work.job.duration)
            // Deliver only if not fenced for discard (a color-mode swap may have
            // quiesced this program while the composite was in flight).
            let deliver = shared.withLock { s -> Bool in s.stats.rendered += 1; return !s.quiesced }
            if deliver { work.consumer?(frame) }
        } catch {
            shared.withLock { $0.stats.errors += 1 }
            logger.error("preview composite failed: \(String(describing: error), privacy: .public)")
        }
        let continueDraining = shared.withLock { s -> Bool in
            if s.pending != nil { return true }
            s.draining = false
            return false
        }
        if continueDraining { queue.async { [weak self] in self?.drain() } }
    }

    // MARK: - Source registration (mirror `DualProgram` forget/attach barrier)

    /// Drop a removed source from the preview compositor's last-known set and
    /// tombstone it, so a pending/draining tick captured before this call cannot
    /// re-pin the removed source. Only an explicit `attach` clears the tombstone.
    public func forget(source: SourceID) {
        shared.withLock { state in
            _ = state.forgotten.insert(source)
            state.forgottenGeneration[source] = state.tickGeneration
            if var pending = state.pending {
                pending.frames[source] = nil
                state.pending = pending
            }
        }
        let unregister = { self.compositor.forget(source: source) }
        if DispatchQueue.getSpecific(key: queueKey) != nil { unregister() }
        else { queue.sync(execute: unregister) }
    }

    /// Explicitly re-register a source after `forget`. Fenced behind already-
    /// enqueued preview work before the compositor tombstone is cleared.
    public func attach(source: SourceID) {
        let register = { self.compositor.attach(source: source) }
        if DispatchQueue.getSpecific(key: queueKey) != nil { register() }
        else { queue.sync(execute: register) }
        shared.withLock { s in
            s.forgotten.remove(source)
            s.forgottenGeneration[source] = nil
        }
    }

    /// Sources currently in the `forgotten` filter set (diagnostics / headless
    /// verification, mirror `DualProgram.forgottenSourceIDs`). Thread-safe.
    public var forgottenSourceIDs: [SourceID] {
        shared.withLock { Array($0.forgotten) }
    }

    // MARK: - Discard fence (color-mode / HDR swap)

    /// Fence this program before it is discarded on an HDR / color-mode swap
    /// (mirror `DualProgram.quiesce`): drop any pending submission and suppress
    /// any in-flight composite's delivery, so no stale old-mode preview frame can
    /// reach the preview sink after the new program's first frame. Reversible via
    /// `resume`. Safe from any thread except the preview `queue` itself.
    public func quiesce() {
        shared.withLock { s in
            s.quiesced = true
            s.pending = nil
        }
        if DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
    }

    /// Re-arm a quiesced program (the HDR-swap failure path revives it).
    public func resume() {
        shared.withLock { $0.quiesced = false }
    }

    /// Whether this program is fenced for discard (headless verification).
    public var isQuiesced: Bool { shared.withLock { $0.quiesced } }
}
