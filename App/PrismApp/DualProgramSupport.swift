import CoreVideo
import Foundation
import PrismCompose
import PrismCompositor
import PrismCore
import PrismOutput

// Dual-program (horizontal + vertical) app-side plumbing.
//
// The vertical program is a SECOND full composite of the SAME per-tick source
// frames the primary `RenderLoop` composited, reframed 16:9 → 9:16 at 1080×1920
// (PrismCompose.DualProgram / SecondaryComposition). Perf: it runs on its own
// `MetalCompositor` + serial queue, so its ~<4 ms GPU pass runs concurrently
// with the primary and never adds to the primary's <4 ms tick budget; if the
// GPU is contended, `DualProgram` coalesces (drops) intermediate submissions
// rather than back-pressuring the show.

/// How the vertical program reframes the horizontal scene (UI-facing subset of
/// `ReframeMap`'s presets).
enum VerticalReframeMode: String, CaseIterable, Sendable {
    case heroFill   // full-bleed center-crop on the frontmost (or chosen) source
    case follow     // full-bleed on a pinned hero source; others hidden
    case fitAll     // letterbox every source into the vertical canvas

    var label: String {
        switch self {
        case .heroFill: return "Hero Fill"
        case .follow: return "Follow source"
        case .fitAll: return "Fit all"
        }
    }
}

/// Thread-safe vertical-tick state. Capture callbacks may update diagnostics,
/// but the frames submitted to 9:16 come from `RenderLoop.onTickSnapshot`: the
/// exact deadline-qualified dictionary consumed by the primary tick.
///
/// This is the integration seam: `RenderLoop` pulls each source's frames from
/// its (one-consumer, destructive) mailboxes internally and exposes the chosen
/// per-tick dict through its exact tick hook; this holder pairs that dict with
/// the provider-evaluated scene/reframe without copying pixels. Gated by
/// `enabled` so it costs nothing until the vertical program is turned on.
final class LatestFrameTap: @unchecked Sendable {
    struct Snapshot {
        var frames: [SourceID: VideoFrame]
        /// The exact primary-provider scene evaluated for this tick. `nil` means
        /// the secondary should use its resting/static scene.
        var scene: Scene?
        /// Reframe paired with `scene`. Kept in the same snapshot so a meme
        /// insert can never be submitted with the next tick's hero/placement.
        var reframe: ReframeMap?
    }

    private let lock = NSLock()
    private var exactFrames: [SourceID: VideoFrame] = [:]
    private var exactProgram: (scene: Scene, reframe: ReframeMap)?
    private var routingMode: VerticalReframeMode = .heroFill
    private var pinnedHero: SourceID?
    private var _enabled = false

    var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set {
            lock.lock()
            _enabled = newValue
            if !newValue {
                exactFrames.removeAll(keepingCapacity: true)
                exactProgram = nil
            }
            lock.unlock()
        }
    }

    /// Update main-actor routing controls without exposing them to the render
    /// thread unsafely. The exact evaluated/resting scenes arrive in the tick.
    func updateRouting(mode: VerticalReframeMode, pinnedHero: SourceID?) {
        lock.lock()
        routingMode = mode
        self.pinnedHero = pinnedHero
        lock.unlock()
    }

    func routingSnapshot() -> (mode: VerticalReframeMode, pinnedHero: SourceID?) {
        lock.lock(); defer { lock.unlock() }
        return (routingMode, pinnedHero)
    }

    /// Capture callbacks keep this compatibility hook while source wiring is
    /// shared with other taps. Intentionally stores nothing: retaining a second
    /// latest IOSurface per source would waste memory and could not be tick-exact.
    func update(_ id: SourceID, with frame: VideoFrame) {}

    /// Atomically store one exact delivered primary tick for diagnostics/tests.
    func updateExactTick(frames: [SourceID: VideoFrame], scene: Scene?, reframe: ReframeMap?) {
        lock.lock()
        if _enabled {
            // RenderLoop reports the compositor's complete last-known set for
            // this delivered tick, so replacement also drops anything no
            // longer present. `forget` remains the synchronous removal fence.
            exactFrames = frames
            if let scene, let reframe { exactProgram = (scene, reframe) }
            else { exactProgram = nil }
        }
        lock.unlock()
    }

    /// Drop a removed source.
    func forget(_ id: SourceID) {
        lock.lock()
        exactFrames[id] = nil
        lock.unlock()
    }

    /// Return to the secondary's main-actor-managed resting scene/reframe once
    /// no scene provider (meme hold / LayerMotion / entrance) owns the program.
    func clearProgramOverride() {
        lock.lock(); exactProgram = nil; lock.unlock()
    }

    /// One atomic vertical-tick snapshot: latest frames plus the primary scene
    /// and reframe evaluated for the same program tick.
    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(frames: exactFrames,
                        scene: exactProgram?.scene,
                        reframe: exactProgram?.reframe)
    }
}

/// Consumers of the vertical program frame (`DualProgram.onSecondaryFrame`,
/// invoked on the secondary's serial queue): a 9:16 preview store and an
/// optional vertical `MovieRecorder`. Mirrors `ProgramFanOut`'s recorder
/// pattern — the recorder's own `ProgramEncoder` lives inside its encode-on-
/// write path, so we just append BGRA frames and it drops (counts) instead of
/// blocking if the writer falls behind.
final class VerticalProgramSink: @unchecked Sendable {
    let preview = ProgramPreviewStore()

    /// Fires (once per recorder instance) if the vertical writer enters `.failed`
    /// while appending — mirrors ProgramFanOut's C29 health poll so a broken
    /// vertical recording surfaces immediately, not only at finalize (Codex C4).
    var onRecorderFailure: ((MovieRecorder) -> Void)?

    private let lock = NSLock()
    private var recorder: MovieRecorder?
    private var lastStateCheck: TimeInterval = 0
    private var failureReported = false

    func setRecorder(_ newValue: MovieRecorder?) {
        lock.lock(); recorder = newValue; failureReported = false; lock.unlock()
    }

    /// Secondary serial queue, once per vertical program frame.
    func consume(_ frame: VideoFrame) {
        preview.store(frame)
        lock.lock(); let recorder = recorder; lock.unlock()
        guard let recorder else { return }
        recorder.append(frame) // drops (and counts) instead of blocking
        checkHealth(recorder)
    }

    private func checkHealth(_ recorder: MovieRecorder) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard recorder === self.recorder, !failureReported, now - lastStateCheck >= 1 else {
            lock.unlock(); return
        }
        lastStateCheck = now
        lock.unlock()

        guard recorder.state == .failed else { return }

        lock.lock()
        let shouldReport = recorder === self.recorder && !failureReported
        if shouldReport { failureReported = true }
        lock.unlock()
        if shouldReport { onRecorderFailure?(recorder) }
    }
}

/// Consumer of the **preview** program frame (`PreviewProgram.onPreviewFrame`,
/// invoked on the preview's serial queue) — studio mode, Stage 1.
///
/// Deliberately a preview-ONLY sink: it owns a single `ProgramPreviewStore`
/// (the off-air monitor) and NOTHING else. Unlike `VerticalProgramSink` there
/// is no recorder / vcam / encoder — a preview edit must never reach ANY output.
/// It has no reference to `ProgramFanOut`, so there is structurally no path from
/// an off-air preview frame to the live program buffer, recorder, stream, or
/// virtual camera. That isolation is the off-air guarantee.
final class PreviewProgramSink: @unchecked Sendable {
    let preview = ProgramPreviewStore()

    /// Preview serial queue, once per preview program frame.
    func consume(_ frame: VideoFrame) {
        preview.store(frame)
    }
}
