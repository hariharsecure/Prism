import CoreMedia
import Foundation
import Metal
import PrismColor
import PrismCompositor
import PrismCore
import PrismSound
import PrismVision
import os

// MARK: - Tile / grid effect model (Build A + C)

/// UI-facing tile/grid mode — flattens `TileMaskMode`'s associated values so the
/// Inspector can bind a plain `Picker`. `maskMode(seed:direction:)` maps back to
/// the engine's `TileMaskMode`.
enum TileGridMode: String, CaseIterable, Identifiable, Sendable {
    case flicker          // continuous blink (looping phase)
    case blockDissolve    // one-shot: seeded random reveal
    case gridWipe         // one-shot: directional sweep
    case checkerboard     // one-shot: parity reveal
    case tileReveal       // one-shot: centred grow box

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flicker:       return "Flicker (blink)"
        case .blockDissolve: return "Block Dissolve"
        case .gridWipe:      return "Grid Wipe"
        case .checkerboard:  return "Checkerboard"
        case .tileReveal:    return "Tile Reveal"
        }
    }

    /// Flicker loops forever; every other mode ramps its phase 0→1 once.
    var isOneShot: Bool { self != .flicker }
    /// Only these two modes read a random `seed`.
    var usesSeed: Bool { self == .flicker || self == .blockDissolve }
}

/// One layer's tile-mask config (Build A): punches an animated grid of
/// transparent holes into this source's frame so the compositor reveals the
/// layers BENEATH it. Requires the scene Layer's `premultipliedAlpha == true`
/// (the engine flips it via `producesPremultipliedAlpha`).
struct TileEffect: Sendable, Equatable {
    var mode: TileGridMode = .flicker
    var rows: Int = 6
    var cols: Int = 8
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    var softness: Double = 0.15
    /// Multiplies the time-driven phase. Flicker → blink rate; one-shot → reveal speed.
    var speed: Double = 1.0
    var direction: FXDirection = .left   // gridWipe only
    /// House-time seconds when the effect (re)started, for one-shot progress.
    var startHostSeconds: Double = 0

    /// Beat-sync (BEAT_SYNC_DESIGN "App wiring"): when true the mask `phase` is
    /// driven by the live `BeatClock`'s beat-phase (× `flipsPerBeat`) instead of
    /// the free-running house clock, so tiles flip ON the beat. When the sequencer
    /// is stopped the pipeline falls back to the free-run phase (no frozen effect).
    var syncToBeat: Bool = false
    /// How many full mask cycles happen per quarter-note beat when `syncToBeat`.
    var flipsPerBeat: Double = 1.0

    /// The concrete engine mode this maps to.
    func maskMode() -> TileMaskMode {
        switch mode {
        case .flicker:       return .tileFlicker(seed: seed)
        case .blockDissolve: return .blockDissolve(seed: seed)
        case .gridWipe:      return .gridWipe(direction: direction)
        case .checkerboard:  return .checkerboard
        case .tileReveal:    return .tileReveal
        }
    }
}

/// One layer's beat-pulse config (BEAT_SYNC_DESIGN "App wiring"): scales/shakes
/// this source's frame on every beat via `BeatPulse`, driven by the live
/// `BeatClock`'s beat-phase. The pass preserves source alpha (F4/Class C — the
/// default `.clear` background keeps transparent/uncovered texels transparent),
/// and the common opaque source stays opaque where covered, so it needs no
/// premultiplied-alpha change. When the sequencer is stopped the pulse is
/// identity (the frame passes through untouched — no dead visual).
struct BeatPulseEffect: Sendable, Equatable {
    /// Peak scale bump = `1 + intensity` on the downbeat (clamped by `BeatPulse`).
    var intensity: Double = 0.6
    /// Bump / shake / both.
    var style: BeatPulseStyle = .bump
}

/// One layer's video-wall config (Build C): tiles this source into an N×M grid;
/// `mirror` flips odd-parity cells for a kaleidoscope. Output is a normal opaque
/// frame (no premultiplied-alpha requirement).
struct VideoWall: Sendable, Equatable {
    var rows: Int = 2
    var cols: Int = 2
    var mirror: Bool = false
}

/// One layer's strobe/flash config: a full-frame color flash driven by
/// `StrobeEffect`, peaking on each beat (`syncToBeat`) or on a free-running
/// timer. The flash preserves source alpha (N3/Class C — colour is modulated,
/// scaled by source alpha), and the common opaque source is unchanged where it
/// flashes, so it needs no premultiplied-alpha change. When `syncToBeat` and the
/// sequencer is stopped, the phase falls back to the free-run clock so the flash
/// never freezes (mirrors the tile-mask beat fallback).
struct StrobeEffect: Sendable, Equatable {
    /// Peak flash strength (clamped 0…1 by `StrobeEffect.apply`).
    var intensity: Double = 0.8
    /// Flash color as sRGB 0…1 (built into a `RGBA` in the pipeline).
    var red: Double = 1
    var green: Double = 1
    var blue: Double = 1
    /// Drive the flash phase from the live `BeatClock` when true (flash on the
    /// downbeat); free-run at `freeRunHz` when false or the sequencer is stopped.
    var syncToBeat: Bool = true
    /// Free-run flashes per second (only used when not beat-driven).
    var freeRunHz: Double = 3.0
    /// House-time seconds when the effect (re)started, for the free-run phase.
    var startHostSeconds: Double = 0
}

// MARK: - Per-source effect chain (wave 2, deliverable 1)

/// The effect state for one source: a color grade, an optional 3D LUT, and an
/// optional background mode. The identity default (`SourceEffects()`) is the
/// cost-free case — `isActive` is false, so the pipeline short-circuits and
/// posts the untouched frame.
///
/// Value type, Sendable (ColorGrade/CubeLUT/BackgroundMode are all Sendable),
/// so the main actor can mirror it into `@Published` and hand snapshots to the
/// capture-thread pipeline without data races.
struct SourceEffects: @unchecked Sendable {
    var grade: ColorGrade = .identity
    var lut: CubeLUT?
    var background: BackgroundMode?
    /// Optional green/blue-screen key. Its output is premultiplied-alpha BGRA
    /// (backdrop → transparent), so a source with a chroma key set — like
    /// `background == .remove` — needs its scene Layer's `premultipliedAlpha`
    /// flag flipped true (see `producesPremultipliedAlpha`). Chroma key and
    /// segmentation-`remove` are alternative keying paths; either may be set.
    var chromaKey: ChromaKey?

    /// Optional luminance key (bright/dark backdrop). Like `chromaKey`, its
    /// output is premultiplied-alpha BGRA — mutually exclusive with `chromaKey`
    /// and background-`remove` (a single keying path per source; the engine
    /// setters enforce this). Flips the scene Layer's `premultipliedAlpha` true.
    var lumaKey: LumaKey?

    /// When true, whichever keyer is active (chroma OR luma) renders its MATTE
    /// (white = kept, black = keyed) instead of the keyed image, so an operator
    /// can tune the key precisely. No effect when no keyer is set.
    var matteView: Bool = false

    /// Optional tile/grid mask (Build A). Punches an animated grid of transparent
    /// holes into the frame so the compositor reveals the layers beneath — so it
    /// makes the frame carry premultiplied alpha (see `producesPremultipliedAlpha`).
    var tile: TileEffect?

    /// Optional video wall (Build C): tile this source into an N×M grid. Opaque
    /// output — no premultiplied-alpha requirement.
    var videoWall: VideoWall?

    /// Optional beat pulse (BEAT_SYNC_DESIGN): scale/shake on the beat. Alpha-
    /// preserving output (F4/Class C: `.clear` background — transparent/uncovered
    /// texels stay transparent); the common opaque source stays opaque, so no
    /// premultiplied-alpha change. Identity when the sequencer is stopped.
    var pulse: BeatPulseEffect?

    /// Optional strobe/flash: a full-frame color flash peaking on the beat (or a
    /// free-run timer). Alpha-preserving output (N3/Class C: colour modulated,
    /// scaled by source alpha); the common opaque source is unchanged, so no
    /// premultiplied-alpha change.
    var strobe: StrobeEffect?

    /// True when the chain would change any pixel — the whole pipeline is
    /// skipped when this is false (identity = zero added cost).
    var isActive: Bool {
        !grade.isIdentity || lut != nil || background != nil
            || chromaKey != nil || lumaKey != nil
            || tile != nil || videoWall != nil || pulse != nil || strobe != nil
    }

    /// True when the processed frame carries meaningful (premultiplied) alpha —
    /// i.e. a chroma key, a luma key, or a background-`remove` is active. The
    /// scene Layer for this source MUST set `premultipliedAlpha` to this value,
    /// else the keyed/segmented transparency composites as opaque black (Codex
    /// C1). `blur` and `replace` re-fill the background opaque, so they stay
    /// `false`. (A matte-view render is opaque grayscale — α = 1 everywhere — so
    /// the flag is harmless there; keeping it true keeps the setter path simple.)
    var producesPremultipliedAlpha: Bool {
        chromaKey != nil || lumaKey != nil || background == .remove || tile != nil
    }
}

/// One color+background processing pipeline per video source. Lives for the
/// life of the source; created in `AppEngine.makeEffectPipeline`, torn down in
/// `removeSource`.
///
/// Threading (the whole point of this class): the Metal-backed processors
/// (`ColorProcessor`, `BackgroundEffect`, `FrameAnalyzer`) are NOT thread-safe
/// and are documented as one-instance-per-source-pipeline. They are touched
/// ONLY inside `process(_:)`, which runs on the owning source's single capture
/// thread — so they need no lock. The three cross-thread channels are:
///   • `effects` / `autoColorRequested` — written by the main actor (setters),
///     read by the capture thread → guarded by `stateLock`.
///   • the `PersonSegmenter` (itself `Sendable`) is fed from the capture thread
///     and delivers mattes on its own serial queue; `smoother` + `latestMatte`
///     live behind `matteLock`, and `MatteSmoother` is only ever driven on that
///     serial matte queue (single-threaded).
final class SourceEffectPipeline: @unchecked Sendable {
    let sourceID: SourceID
    private let device: MTLDevice
    /// Canvas size the tile/grid renderers rasterize to (reused, never realloc'd
    /// per frame). The compositor's program raster — a holed/tiled frame lands 1:1.
    private let canvasWidth: Int
    private let canvasHeight: Int
    private let log = EngineLog.logger("app.effects")

    // Cross-thread state (main writes, capture reads).
    private let stateLock = NSLock()
    private var effects = SourceEffects()
    private var autoColorRequested = false
    /// True once `teardown()` ran — gates the grade callback so an auto-color
    /// result resolved on the capture thread can't escape after teardown (W8).
    private var torndown = false

    // Capture-thread-only Metal processors (lazy; created on first active frame).
    private var colorProcessor: ColorProcessor?
    private var colorProcessorFailed = false
    private var backgroundEffect: BackgroundEffect?
    private var backgroundEffectFailed = false
    private var chromaKeyProcessor: ChromaKeyProcessor?
    private var chromaKeyProcessorFailed = false
    private var lumaKeyProcessor: LumaKeyProcessor?
    private var lumaKeyProcessorFailed = false
    private var analyzer: FrameAnalyzer?
    private var analyzerFailed = false
    /// Tile/grid mask (Build A) + video wall (Build C). CPU/CoreGraphics-backed
    /// (`FXCanvas`), sized to the canvas once and reused — created on first use,
    /// touched only on the capture thread. `*Failed` latches an init failure so a
    /// broken renderer degrades to a pass-through instead of retrying every frame.
    private var tileMask: TileMask?
    private var tileMaskFailed = false
    private var tileRepeat: TileRepeatRenderer?
    private var tileRepeatFailed = false
    /// Guards the `tileRepeat` POINTER only (sol #5 #15). The CPU video-wall renderer
    /// + its `FXCanvas` pool is normally released lazily inside `applyVideoWall` on the
    /// capture thread, but a STALLED source gets no further callback and would pin the
    /// pool forever — so `update(_:)` releases it SYNCHRONOUSLY on the main actor at the
    /// disable site (mirroring the capture-GPU floor). That cross-thread pointer write
    /// needs this lock; the `TileRepeatRenderer` itself is still only ever *used* on the
    /// capture thread (via a locally-captured reference).
    private let captureCPULock = NSLock()
    /// Beat-pulse renderer (BEAT_SYNC_DESIGN) — CPU/CoreGraphics-backed, canvas-
    /// sized, created on first use and touched only on the capture thread.
    private var beatPulseRenderer: BeatPulseRenderer?
    private var beatPulseRendererFailed = false
    /// The pulse envelope shape (fixed; per-source intensity/style ride in `effects`).
    private let beatPulse = BeatPulse.default
    /// Strobe/flash renderer (full-frame color flash) — CoreGraphics-backed,
    /// canvas-sized, created on first use and touched only on the capture thread.
    private var strobeEffect: PrismCompositor.StrobeEffect?
    private var strobeEffectFailed = false

    /// GPU offload of the per-source VisualFX passes — the same effect math as
    /// fullscreen Metal fragment passes, <1 ms/frame with no per-frame allocation
    /// (vs. the CPU path's 17–1329 ms), VALIDATED to match the CPU output
    /// (meanDiff < 0.003).
    ///
    /// Thread-safety: `SourceEffectGPU` is NOT thread-safe (own pool + command
    /// queue + texture caches). It is used single-threaded per instance. F5 split
    /// the effect chain across TWO threads — TIME-INVARIANT effects (video wall)
    /// run at capture time in `process(_:)`, TIME-VARYING effects (tile / strobe /
    /// pulse) run on the render thread in `animate(raw:at:)` — so we give each
    /// thread its OWN GPU instance rather than share one and race:
    ///   • `captureFXGPU` — touched only inside `process(_:)` on the source's
    ///     capture thread (video wall).
    ///   • `animatedFXGPU` — touched only inside `animate(raw:at:)` on the render
    ///     thread (tile / strobe / pulse).
    /// Neither is ever touched off its owning thread, so both stay lock-free.
    ///
    /// Both are sized to the canvas and built on the app's shared compositor
    /// `device`. Created lazily; `*Failed` latches an init failure (e.g. no
    /// Metal) so the source degrades to the CPU renderers below without a retry
    /// storm.
    private var captureFXGPU: SourceEffectGPU?
    private var captureFXGPUFailed = false
    /// Guards the `captureFXGPU` POINTER only (not GPU work, which stays on the
    /// capture thread). The video-wall GPU floor is normally released lazily inside
    /// `process(_:)` on the capture thread, but a STALLED source gets no further
    /// callback and would pin ~47.5 MiB forever — so `update(_:)` releases it
    /// SYNCHRONOUSLY on the main actor at the disable site (F15 residual). That
    /// cross-thread pointer write needs this lock; the `SourceEffectGPU` object
    /// itself is still only ever *used* on the capture thread.
    private let captureGPULock = NSLock()
    private var animatedFXGPU: SourceEffectGPU?
    private var animatedFXGPUFailed = false

    /// Live tempo-clock snapshot for beat-synced effects (tile sync + pulse).
    /// Written by the main actor (`setBeatClock`, on play/stop/BPM change), read
    /// on the capture thread each frame. `.stopped` ⇒ effects free-run / go idle.
    private let beatClockLock = NSLock()
    private var beatClock: BeatClock = .stopped

    // Segmentation. `segmenter` is Sendable; `smoother`/`latestMatte` behind matteLock.
    private let matteLock = NSLock()
    private var segmenter: PersonSegmenter?
    private var smoother: MatteSmoother?
    private var latestMatte: SegmentationMatte?
    /// Bumped (under matteLock) on every stop / background change. A matte
    /// callback captures the generation live at spin-up; when it fires it drops
    /// itself if the generation has moved on, so a Vision run still in flight at
    /// teardown cannot resurrect a stale matte after the segmenter was released (W1).
    private var matteGeneration: UInt64 = 0

    /// Fired (on the capture thread) when a `loadAutoColor` request resolves to
    /// a computed grade; AppEngine hops it to the main actor to mirror state.
    /// Backed by `_onGradeComputed` behind `stateLock` so the main-actor set and
    /// the capture-thread read/clear are synchronized (W8).
    var onGradeComputed: ((SourceID, ColorGrade) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _onGradeComputed }
        set { stateLock.lock(); _onGradeComputed = newValue; stateLock.unlock() }
    }
    private var _onGradeComputed: ((SourceID, ColorGrade) -> Void)?

    init(device: MTLDevice, sourceID: SourceID,
         canvasWidth: Int = AppEngine.canvasSize.width,
         canvasHeight: Int = AppEngine.canvasSize.height) {
        self.device = device
        self.sourceID = sourceID
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
    }

    // MARK: Main-actor control surface

    /// Adopt a new effect set. Spins the segmenter up/down on background changes.
    func update(_ new: SourceEffects) {
        stateLock.lock()
        let hadBackground = effects.background != nil
        let hadWall = effects.videoWall != nil
        effects = new
        stateLock.unlock()

        let wantsBackground = new.background != nil
        if wantsBackground && !hadBackground {
            startSegmenter()
        } else if !wantsBackground && hadBackground {
            stopSegmenter()
        }

        // F15 residual: drop the capture-thread video-wall GPU floor SYNCHRONOUSLY
        // the moment the wall is disabled — do NOT wait for the next `process(_:)`
        // callback (which never comes for a STALLED source, pinning ~47.5 MiB
        // indefinitely). Thread-safe via `captureGPULock`.
        //   sol #5 #15: release the CPU fallback renderer + its `FXCanvas` pool at the
        //   SAME disable site. Pre-fix only the GPU was dropped here; the CPU pool was
        //   released only from a later `applyVideoWall` callback (~:722) — which never
        //   arrives for a stalled Metal-fallback source, so it pinned the pool forever.
        if hadWall && new.videoWall == nil {
            releaseCaptureGPUIfIdle()
            #if DEBUG
            if !Self._test_skipCPUReleaseAtDisableSite { releaseCaptureCPUIfIdle() }
            #else
            releaseCaptureCPUIfIdle()
            #endif
        }
    }

    /// Push the live tempo clock (BEAT_SYNC_DESIGN). Called by the main actor
    /// whenever the beat state changes (play / stop / BPM). `.stopped` makes the
    /// beat-synced tile fall back to free-run and the pulse go identity.
    func setBeatClock(_ clock: BeatClock) {
        beatClockLock.lock(); beatClock = clock; beatClockLock.unlock()
    }

    private func currentBeatClock() -> BeatClock {
        beatClockLock.lock(); defer { beatClockLock.unlock() }; return beatClock
    }

    /// Snapshot for read-only callers (debug/state mirror).
    func currentEffects() -> SourceEffects {
        stateLock.lock(); defer { stateLock.unlock() }
        return effects
    }

    /// Request an auto-color pass: the NEXT frame runs FrameAnalyzer + AutoColor
    /// and adopts the suggested grade (published back via `onGradeComputed`).
    func requestAutoColor() {
        stateLock.lock(); autoColorRequested = true; stateLock.unlock()
    }

    /// Release the segmenter (called on removeSource).
    func teardown() {
        stopSegmenter()
        // Clear the grade callback under the same lock the capture thread reads
        // it through, and latch `torndown` so an in-flight auto-color result
        // resolving concurrently can't fire the (now dangling) callback (W8).
        stateLock.lock()
        torndown = true
        _onGradeComputed = nil
        stateLock.unlock()
    }

    // MARK: Capture thread

    /// Runs on the owning source's capture thread, BEFORE the frame is posted to
    /// the render mailbox. Returns the processed frame, or the original when the
    /// chain is identity or a processor is unavailable (never worse than a
    /// pass-through — mirrors LinkFrameNormalizer's fail-soft contract).
    func process(_ frame: VideoFrame) -> VideoFrame {
        let (pre, wall) = runChainToPreWall(frame)
        guard let wall else { return pre }
        return applyVideoWall(pre, wall: wall) ?? pre
    }

    /// sol #8 #3: run the effect chain AND deliver the result through `emit`, closing the
    /// video-wall disable/emit race STRUCTURALLY. Prior fixes moved the disabled-check
    /// progressively closer to the emit (acquisition → render site), but the check still
    /// PRECEDED the actual `mailbox.post` (done by the caller after `process` returned), so
    /// a disable landing in that gap leaked one stale tiled frame. Here the final
    /// disabled-check and the delivery happen under a SINGLE `stateLock` hold — the same
    /// lock `update(_:)` takes to write `videoWall = nil` — so the disable and the emit are
    /// mutually serialized: there is NO window between the check and the post. When no wall
    /// was applied there is nothing to gate, so the frame is delivered directly (no lock).
    /// sol #9 #5: `post` (the PROGRAM output — `mailbox.post`) is performed UNDER `stateLock`,
    /// atomic with the video-wall disabled-check (the gate sol validated — do NOT reopen it).
    /// `taps` (the observer sinks — monitor / ISO / vertical / director) run OUTSIDE the lock on
    /// the SAME frame decided under it, so a tap that synchronously reads pipeline state (which
    /// takes `stateLock`) cannot deadlock on the non-recursive lock. Splitting them keeps the
    /// disable race closed (the decision + primary post are still atomic) while removing the
    /// reentrancy landmine of running arbitrary observer closures under the lock.
    func processAndEmit(_ frame: VideoFrame, post: (VideoFrame) -> Void, taps: (VideoFrame) -> Void) {
        let (pre, wall) = runChainToPreWall(frame)
        guard let wall else {
            // No wall applied → nothing to gate; no lock is held, so taps are free to reenter.
            post(pre); taps(pre); return
        }
        let tiled = applyVideoWall(pre, wall: wall) ?? pre
        #if DEBUG
        Self._test_emitSiteHook?()   // model a disable landing at the emit site (post-tile, pre-post)
        #endif
        // ATOMIC gate: a concurrent `update(nil)` either lands BEFORE this lock (→ we observe the
        // wall disabled and post the untiled `pre`) or is serialized AFTER the post (→ this tiled
        // frame was still correct when posted). No stale frame either way.
        stateLock.lock()
        #if DEBUG
        let disabled = Self._test_skipAtomicEmitGate ? false : (effects.videoWall == nil)
        #else
        let disabled = (effects.videoWall == nil)
        #endif
        let outFrame = disabled ? pre : tiled
        post(outFrame)              // program output — atomic with the disabled-check
        #if DEBUG
        let tapsInsideLock = Self._test_runTapsInsideLock   // NEG CONTROL: pre-fix taps-under-lock
        if tapsInsideLock { taps(outFrame) }
        #else
        let tapsInsideLock = false
        #endif
        stateLock.unlock()
        // sol #9 #5: observer taps OUTSIDE the lock — a reentrant `stateLock` read is now safe.
        if !tapsInsideLock { taps(outFrame) }
    }

    /// Runs the source effect chain up to (but EXCLUDING) the video wall, returning the
    /// pre-wall frame and the wall config to tile with (nil ⇒ no wall / identity chain).
    /// Shared by `process` and `processAndEmit` so the wall is the ONLY step that differs
    /// between the plain and gated-emit paths. Called once per frame (exactly one of the
    /// two entry points runs), so its auto-color + GPU-floor side effects fire once.
    private func runChainToPreWall(_ frame: VideoFrame) -> (frame: VideoFrame, wall: VideoWall?) {
        stateLock.lock()
        var fx = effects
        let doAutoColor = autoColorRequested
        if doAutoColor { autoColorRequested = false }
        stateLock.unlock()

        if doAutoColor, let grade = computeAutoColor(frame, base: fx.grade) {
            fx.grade = grade
            // Read the callback and the teardown latch under the same lock, so a
            // teardown() racing on the main actor either wins (callback dropped)
            // or loses (callback captured) atomically — never a torn read (W8).
            stateLock.lock()
            effects.grade = grade
            let callback = torndown ? nil : _onGradeComputed
            stateLock.unlock()
            callback?(sourceID, grade)
        }

        // F15: drop the capture-thread video-wall GPU warm floor as soon as the
        // effect is off (even when the whole chain then short-circuits to identity).
        if fx.videoWall == nil { releaseCaptureGPUIfIdle() }

        guard fx.isActive else { return (frame, nil) }

        var out = frame

        if !fx.grade.isIdentity || fx.lut != nil {
            out = applyColor(out, grade: fx.grade, lut: fx.lut) ?? out
        }

        // Chroma / luma key: standalone GPU pass AFTER grade (grade sees the
        // opaque source; the key then removes the graded backdrop). Emits
        // premultiplied-alpha BGRA — the app flips this source's Layer.
        // premultipliedAlpha=true. Alternatives to segmentation-`remove` and to
        // each other; the engine setters keep exactly one set. `matteView`
        // renders the matte (for tuning) instead of the keyed image.
        if let key = fx.chromaKey {
            out = applyChromaKey(out, key: key, matteView: fx.matteView) ?? out
        } else if let luma = fx.lumaKey {
            out = applyLumaKey(out, key: luma, matteView: fx.matteView) ?? out
        }

        if let mode = fx.background {
            matteLock.lock(); let seg = segmenter; matteLock.unlock()
            seg?.submit(frame) // feed the ORIGINAL frame; matte res follows source
            matteLock.lock(); let matte = latestMatte; matteLock.unlock()
            if let matte {
                out = applyBackground(out, matte: matte, mode: mode) ?? out
            }
        }

        // Video wall (Build C): tiling the graded/keyed frame into an N×M grid is
        // TIME-INVARIANT geometry, so it stays at CAPTURE time (F5). It is applied by the
        // caller (`process` / `processAndEmit`) so the gated-emit path can re-check the
        // wall's disabled state atomically with the post (sol #8 #3).
        //
        // TIME-VARYING effects (beat pulse / strobe / tile mask) are deliberately NOT
        // applied here (F5). Evaluating them at source-callback arrival made a still/2 fps
        // source flicker/pulse only ~2×/s and aliased a strobe, and it baked the phase at
        // HouseClock-at-arrival rather than the frame PTS. They now evaluate on the
        // RenderLoop TICK against this (held) raw frame via `animate(raw:at:)`, using ONE
        // tick PTS for every source. `out` here is that held raw (pre-animated) frame.
        return (out, fx.videoWall)
    }

    // MARK: Render thread — time-varying (animated) effect pass (F5)

    /// True when a TIME-VARYING effect (beat pulse, strobe, or tile mask) is set,
    /// so the render-tick driver knows to retain this source's held raw frame and
    /// call `animate(raw:at:)` each tick. Cheap cross-thread read of the config.
    var hasAnimatedEffect: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return effects.pulse != nil || effects.strobe != nil || effects.tile != nil
    }

    /// Evaluate this source's TIME-VARYING effects against the held raw frame
    /// `raw` at the tick's house-time PTS. Called ONLY on the render thread (from
    /// the `RenderLoop.frameProcessor`), so its `animatedEffectGPU()` / CPU
    /// renderers are single-threaded and lock-free; the effect config is read
    /// under `stateLock`/`beatClockLock`. Returns nil when no animated effect is
    /// set (the caller keeps `raw`). The phase of every effect derives from `pts`
    /// — never wall-clock callback arrival — so two sources at the SAME tick get
    /// the SAME phase (shared clock) and a low-fps source advances every tick.
    func animate(raw: VideoFrame, at pts: CMTime) -> VideoFrame? {
        stateLock.lock(); let fx = effects; stateLock.unlock()
        guard fx.pulse != nil || fx.strobe != nil || fx.tile != nil else { return nil }
        let seconds = pts.seconds

        // sol OPTIMIZATION_PLAN #5: batch pulse → strobe → tile into ONE command
        // buffer on the render-thread GPU instance (one normalize, private ping-pong
        // intermediates, one fence) instead of 3 command buffers + 3 waits + 3
        // externally-pooled IOSurfaces. Behaviour-preserving: the ORDER, the phase
        // math, the premultiplied-alpha/tag handling, and the per-stage rounding all
        // match the per-effect chain (proven by SourceFXChainParityTests). Falls back
        // to the per-effect (CPU-capable) path when Metal is unavailable or the batch
        // pass throws.
        #if DEBUG
        let forceSequential = Self._test_forceSequentialChain
        #else
        let forceSequential = false
        #endif
        if !forceSequential, let gpu = animatedEffectGPU() {
            let steps = buildChainSteps(fx, atSeconds: seconds)
            if !steps.isEmpty {
                do {
                    let out = try gpu.processChain(source: raw.pixelBuffer, steps: steps)
                    return VideoFrame(pixelBuffer: out, pts: raw.pts,
                                      duration: raw.duration, source: raw.source)
                } catch {
                    log.error("batched source-FX chain failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public) — falling back to per-effect passes")
                }
            }
        }

        // Per-effect fallback (Metal unavailable, empty batch, or batch threw). Same
        // relative order as the batched chain: pulse → strobe → tile.
        var out = raw
        if let pulse = fx.pulse {
            out = applyBeatPulse(out, effect: pulse, atSeconds: seconds) ?? out
        }
        if let strobe = fx.strobe {
            out = applyStrobe(out, effect: strobe, atSeconds: seconds) ?? out
        }
        if let tile = fx.tile {
            out = applyTileMask(out, tile: tile, atSeconds: seconds) ?? out
        }
        return out
    }

    /// Build the ORDERED batched-chain steps for the currently-enabled animated
    /// effects at tick time `seconds` (house seconds). Order is pulse → strobe →
    /// tile — the same as the per-effect fallback. The phase/transform math is
    /// IDENTICAL to `applyBeatPulse`/`applyStrobe`/`applyTileMask`:
    /// - a beat pulse is IDENTITY (omitted) when the sequencer is stopped, so the
    ///   step is only appended when the clock runs — matching `applyBeatPulse`
    ///   returning nil (frame passes through) on a stopped clock;
    /// - strobe/tile always animate (they free-run when the sequencer is stopped),
    ///   so they are always appended.
    private func buildChainSteps(_ fx: SourceEffects, atSeconds seconds: Double) -> [SourceEffectGPU.ChainStep] {
        var steps: [SourceEffectGPU.ChainStep] = []
        let clock = currentBeatClock()
        if let pulse = fx.pulse, clock != .stopped {
            let phase = clock.beatPhase(atHostSeconds: seconds)
            let transform = beatPulse.pulse(phase: phase, intensity: pulse.intensity, style: pulse.style)
            steps.append(.beatPulse(transform: transform, background: .clear))
        }
        if let strobe = fx.strobe {
            let phase = Self.strobePhase(strobe, clock: clock, atSeconds: seconds)
            let color = RGBA(r: strobe.red, g: strobe.green, b: strobe.blue, a: 1)
            steps.append(.strobe(phase: phase, intensity: strobe.intensity, color: color))
        }
        if let tile = fx.tile {
            let phase = Self.tilePhase(tile, clock: clock, atSeconds: seconds)
            steps.append(.tileMask(rows: tile.rows, cols: tile.cols,
                                   mode: tile.maskMode(), phase: phase, softness: tile.softness))
        }
        return steps
    }

    // MARK: Phase (pure functions of the tick time — deterministic, testable)

    /// Tile-mask phase for the tick time `now` (house seconds). Pure function of
    /// `now` (+ the effect/beat config), so it is deterministic per tick PTS and
    /// independent of wall-clock callback arrival (F5). Beat-synced when the
    /// sequencer runs; free-run otherwise (one-shot modes clamp 0…1).
    static func tilePhase(_ tile: TileEffect, clock: BeatClock, atSeconds now: Double) -> Double {
        if tile.syncToBeat, clock != .stopped {
            return clock.beatPhase(atHostSeconds: now) * tile.flipsPerBeat
        }
        let elapsed = now - tile.startHostSeconds
        return tile.mode.isOneShot
            ? min(1.0, max(0.0, elapsed * tile.speed))
            : elapsed * tile.speed
    }

    /// Strobe phase for the tick time `now` (house seconds). Pure function of
    /// `now` (+ config): beat-phase when synced and running, else a monotonically
    /// rising free-run phase at `freeRunHz`. Deterministic per tick PTS (F5).
    static func strobePhase(_ effect: StrobeEffect, clock: BeatClock, atSeconds now: Double) -> Double {
        if effect.syncToBeat, clock != .stopped {
            return clock.beatPhase(atHostSeconds: now)
        }
        return (now - effect.startHostSeconds) * max(effect.freeRunHz, 0.0001)
    }

    /// Lazily build (once) the CAPTURE-thread GPU effect processor (video wall),
    /// sharing the app's compositor `device` and sized to the canvas. Returns nil
    /// — so callers fall back to the CPU renderer — if Metal init fails (latched,
    /// no retry storm). Capture-thread only (single-threaded), so no lock.
    private func captureEffectGPU() -> SourceEffectGPU? {
        captureGPULock.lock(); defer { captureGPULock.unlock() }
        #if DEBUG
        if Self._test_forceCaptureGPUUnavailable { return nil }   // sol #5 #15: force CPU fallback
        #endif
        // TOCTOU (sol #3): `process(_:)` snapshotted `effects` at the top of this
        // callback; the main actor may have DISABLED the wall + released the GPU
        // since (`update` → `releaseCaptureGPUIfIdle`, which takes THIS same
        // `captureGPULock`). Re-read the CURRENT enabled state under `stateLock`
        // while holding `captureGPULock`, so a disable that lands mid-callback WINS:
        // never resurrect the ~47.5 MiB warm floor for a wall that is now off (making
        // the synchronous release terminal, even for the last in-flight callback).
        #if DEBUG
        if !Self._test_bypassCaptureWallReRead {
            stateLock.lock(); let wallOn = effects.videoWall != nil; stateLock.unlock()
            guard wallOn else { return nil }
        }
        #else
        stateLock.lock(); let wallOn = effects.videoWall != nil; stateLock.unlock()
        guard wallOn else { return nil }
        #endif
        guard !captureFXGPUFailed else { return nil }
        if captureFXGPU == nil {
            do {
                captureFXGPU = try SourceEffectGPU(device: device,
                                                   width: canvasWidth, height: canvasHeight)
            } catch {
                captureFXGPUFailed = true
                log.error("capture effect GPU init failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public) — falling back to CPU renderers")
                return nil
            }
        }
        return captureFXGPU
    }

    /// Lazily build (once) the RENDER-thread GPU effect processor (tile / strobe /
    /// beat pulse), a SEPARATE instance from `captureEffectGPU` so the two threads
    /// never share the non-thread-safe `SourceEffectGPU` (F5). Render-thread only
    /// (single-threaded), so no lock. Returns nil (⇒ CPU fallback) on Metal init
    /// failure (latched, no retry storm).
    private func animatedEffectGPU() -> SourceEffectGPU? {
        guard !animatedFXGPUFailed else { return nil }
        if animatedFXGPU == nil {
            do {
                animatedFXGPU = try SourceEffectGPU(device: device,
                                                    width: canvasWidth, height: canvasHeight)
            } catch {
                animatedFXGPUFailed = true
                log.error("animated effect GPU init failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public) — falling back to CPU renderers")
                return nil
            }
        }
        return animatedFXGPU
    }

    /// Release the RENDER-thread animated GPU instance when this source has no
    /// time-varying effect enabled, so a source that once used tile/strobe/pulse
    /// does not keep a ~47.5 MiB (1080p) 6-buffer warm floor forever (F15 / Class
    /// F). Render-thread only (same single-threaded owner as `animatedEffectGPU`),
    /// so no lock. Idempotent — a no-op once released or when a live effect is set.
    /// Clears the init-failure latch too, so re-enabling an effect can retry.
    func releaseAnimatedGPUIfIdle() {
        guard !hasAnimatedEffect else { return }
        animatedFXGPU = nil
        animatedFXGPUFailed = false
    }

    /// Release the CAPTURE-thread GPU instance when this source has no capture-time
    /// GPU effect (the video wall) enabled, mirroring `releaseAnimatedGPUIfIdle`
    /// for the render-thread GPU (F15 / Class F — a source that once used a video
    /// wall must not keep its ~47.5 MiB warm capture-GPU floor forever). Capture-
    /// thread only (same single-threaded owner as `captureEffectGPU`), so no lock.
    /// Idempotent; clears the init-failure latch so re-enabling can retry.
    func releaseCaptureGPUIfIdle() {
        stateLock.lock(); let hasWall = effects.videoWall != nil; stateLock.unlock()
        guard !hasWall else { return }
        captureGPULock.lock()
        captureFXGPU = nil
        captureFXGPUFailed = false
        captureGPULock.unlock()
    }

    /// Release the capture-thread CPU video-wall renderer (`TileRepeatRenderer` + its
    /// `FXCanvas` buffer pool) when the wall is DISABLED (sol #4 / sol #5 #15). Called
    /// both from `applyVideoWall` on the capture thread (a stale in-flight callback
    /// finds the wall now off) AND SYNCHRONOUSLY from `update(_:)` on the main actor at
    /// the disable site — so a STALLED source (no further callback) still releases the
    /// pool. The `captureCPULock` makes the pointer write safe across those two threads;
    /// the renderer object is only ever USED on the capture thread. Re-reads the CURRENT
    /// wall state under `stateLock` so a re-enable that lands mid-callback wins.
    /// Idempotent; clears the init-failure latch so re-enabling can retry.
    func releaseCaptureCPUIfIdle() {
        stateLock.lock(); let hasWall = effects.videoWall != nil; stateLock.unlock()
        guard !hasWall else { return }
        captureCPULock.lock()
        tileRepeat = nil
        tileRepeatFailed = false
        captureCPULock.unlock()
    }

    #if DEBUG
    /// sol OPTIMIZATION_PLAN #5 parity seam: when true, `animate` skips the batched
    /// `processChain` and runs the per-effect (single-command-buffer-per-effect)
    /// path — the ORACLE the batched output must byte-match. Off in release.
    static var _test_forceSequentialChain = false
    /// Whether the render-thread animated GPU instance is currently allocated
    /// (test seam for the F15 warm-floor release).
    var debugHasAnimatedGPU: Bool { animatedFXGPU != nil }
    /// Whether the capture-thread (video-wall) GPU instance is currently allocated
    /// (test seam for the F15 capture-GPU warm-floor release).
    var debugHasCaptureGPU: Bool { captureFXGPU != nil }
    /// Whether the capture-thread CPU video-wall renderer (`TileRepeatRenderer` + its
    /// `FXCanvas` pool) is currently allocated (test seam for sol #4: a disabled wall
    /// must not fall into CPU rendering and retain a pool).
    var debugHasCaptureCPURenderer: Bool { tileRepeat != nil }
    /// NEGATIVE CONTROL for the video-wall disable gate (sol #4): when true,
    /// `applyVideoWall` skips its "wall disabled → render nothing + release the CPU pool"
    /// early-return, so a stale callback on a disabled wall falls through to the CPU
    /// `TileRepeatRenderer` (renders the stale wall, retains the `FXCanvas` pool). The
    /// GPU re-read stays active (so the CPU fallback is genuinely reached), proving the
    /// disable gate — not the GPU re-read — is what suppresses the stale CPU render.
    static var _test_skipVideoWallDisableGate = false
    /// NEGATIVE CONTROL toggle for the capture-GPU TOCTOU fix (sol #3): when true,
    /// `captureEffectGPU()` skips the current-wall re-read, so an in-flight callback
    /// following a STALE `videoWall` snapshot resurrects the GPU floor after a disable
    /// (proves the re-read is load-bearing).
    static var _test_bypassCaptureWallReRead = false
    /// Test seam (sol #5 #15): force `captureEffectGPU()` to return nil (simulating
    /// no-Metal) so `applyVideoWall` takes the CPU `TileRepeatRenderer` fallback even
    /// with the wall ON — letting a test allocate the CPU `FXCanvas` pool.
    static var _test_forceCaptureGPUUnavailable = false
    /// NEGATIVE CONTROL for the synchronous CPU-pool release (sol #5 #15): when true,
    /// `update(_:)` skips `releaseCaptureCPUIfIdle()` at the disable site (pre-fix), so
    /// a STALLED source (no further `process(_:)`) pins the CPU pool forever.
    static var _test_skipCPUReleaseAtDisableSite = false
    /// NEGATIVE CONTROL for the video-wall RENDER-SITE disable gate (sol #6 #15): when
    /// true, `applyVideoWall`'s CPU-fallback closure skips its re-check of the current
    /// disabled state (inside `captureCPULock`), so a disable that lands AFTER the
    /// top-of-function gate recreates the `TileRepeatRenderer` and emits ONE stale
    /// tiled frame — reproducing the residual race the render-site re-check closes.
    static var _test_skipVideoWallRenderSiteGate = false
    /// NEGATIVE CONTROL for the video-wall EMIT-SITE disable gate (sol #7 #4/#15): when
    /// true, `applyVideoWall` skips the re-check of the current disabled state at the
    /// ACTUAL render + emit sites (independent of the ACQUISITION gate). A disable landing
    /// AFTER acquisition (the post-acquisition GPU window / the post-lock CPU window) then
    /// renders + emits ONE stale tiled frame — the residual the emit-site re-check closes.
    static var _test_skipVideoWallEmitSiteGate = false
    /// Test hook (sol #8 #3): fired inside `processAndEmit` AFTER the frame is tiled but
    /// BEFORE the atomic emit gate — models a wall-disable landing in the exact residual
    /// window between the final wall check and the mailbox post. The test uses it to write
    /// `videoWall = nil` (under `stateLock`) right there and assert no stale tiled frame emits.
    static var _test_emitSiteHook: (() -> Void)?
    /// NEGATIVE CONTROL for the sol #8 #3 atomic emit gate: when true, `processAndEmit`
    /// skips the under-lock disabled-recheck and emits the tiled frame regardless — so a
    /// disable landing at the emit site (via `_test_emitSiteHook`) leaks one stale tiled
    /// frame, proving the atomic gate is load-bearing.
    static var _test_skipAtomicEmitGate = false
    /// NEGATIVE CONTROL (sol #9 #5): when true, `processAndEmit` runs the observer `taps`
    /// INSIDE the `stateLock` hold (the pre-fix behaviour) — so a tap that synchronously reads
    /// pipeline state (which takes `stateLock`) deadlocks on the non-recursive lock, proving
    /// the taps-outside-lock split is load-bearing.
    static var _test_runTapsInsideLock = false
    /// Test hook (sol #7 #4/#15): when set, `applyVideoWall` performs the wall-disable
    /// (the same `effects.videoWall = nil` write `update` does first, under `stateLock`)
    /// ONCE right after acquisition — modelling a disable that lands after the acquisition
    /// gate passed but before the render/emit. Auto-clears after firing.
    static var _test_disableWallInPostAcquireWindow = false
    /// Test seam: run the video-wall GPU acquisition exactly as an in-flight
    /// `process(_:)` callback would with a STALE `fx.videoWall` snapshot (the wall may
    /// already be disabled). Reproduces the TOCTOU without threading.
    @discardableResult
    func _test_applyVideoWallWithStaleSnapshot(_ frame: VideoFrame, staleWall: VideoWall) -> VideoFrame? {
        applyVideoWall(frame, wall: staleWall)
    }
    /// sol #8 #3 test hook: disable the video wall the way `update(_:)` does — write
    /// `videoWall = nil` under `stateLock` — so an emit-site hook can model a disable
    /// landing in the exact residual window between the tile and the post.
    func _test_disableWallNow() {
        stateLock.lock(); effects.videoWall = nil; stateLock.unlock()
    }
    #endif

    /// Punch the animated grid of holes for this frame. Phase = f(tick time `now`,
    /// house seconds) — driven by the RENDER-TICK PTS, not callback arrival (F5) —
    /// × speed: flicker uses a monotonically-rising phase (its schedule wraps it
    /// to a 0→1→0 blink internally); one-shot modes clamp progress to 0…1.
    ///
    /// GPU (`SourceEffectGPU`) primary; CPU (`TileMask`) fallback when Metal init
    /// fails. Phase/param math is IDENTICAL on both paths — only the render call
    /// differs. Output is premultiplied-alpha BGRA either way (holes = true α-0).
    /// Render-thread only.
    private func applyTileMask(_ frame: VideoFrame, tile: TileEffect, atSeconds now: Double) -> VideoFrame? {
        let clock = currentBeatClock()
        let phase = Self.tilePhase(tile, clock: clock, atSeconds: now)

        // GPU path (primary).
        if let gpu = animatedEffectGPU() {
            do {
                let holed = try gpu.tileMask(source: frame.pixelBuffer,
                                             rows: tile.rows, cols: tile.cols,
                                             mode: tile.maskMode(), phase: phase,
                                             softness: tile.softness)
                return VideoFrame(pixelBuffer: holed, pts: frame.pts,
                                  duration: frame.duration, source: frame.source)
            } catch {
                log.error("tile mask GPU apply failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        // CPU fallback (Metal unavailable).
        guard !tileMaskFailed else { return nil }
        if tileMask == nil {
            do { tileMask = try TileMask(width: canvasWidth, height: canvasHeight) }
            catch {
                tileMaskFailed = true
                log.error("tile mask init failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        guard let tileMask else { return nil }
        do {
            let holed = try tileMask.apply(to: frame.pixelBuffer,
                                           rows: tile.rows, cols: tile.cols,
                                           mode: tile.maskMode(), phase: phase,
                                           softness: tile.softness)
            return VideoFrame(pixelBuffer: holed, pts: frame.pts,
                              duration: frame.duration, source: frame.source)
        } catch {
            log.error("tile mask apply failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// sol #7 #4/#15: is the video wall disabled RIGHT NOW? Read under `stateLock`, which
    /// guards `effects` — `update(_:)` sets `videoWall = nil` under it BEFORE releasing any
    /// GPU/CPU pool, so a render/emit that observes it nil here MUST drop the frame. The
    /// ACQUISITION gate only checks at the top / while obtaining the renderer; this is
    /// re-checked at the ACTUAL render + emit sites so a disable landing after acquisition
    /// (post-acquisition GPU window / post-lock CPU window) can't publish one stale tiled
    /// frame. Honors the emit-site negative-control seam.
    private func videoWallDisabledAtRenderSite() -> Bool {
        #if DEBUG
        if Self._test_skipVideoWallEmitSiteGate { return false }
        #endif
        stateLock.lock(); let on = effects.videoWall != nil; stateLock.unlock()
        return !on
    }

    #if DEBUG
    /// sol #7 #4/#15 test hook: model a disable landing in the post-acquisition window by
    /// performing the wall-disable (the `stateLock` write `update` does first) exactly once.
    private func testDisableWallInPostAcquireWindowIfArmed() {
        guard Self._test_disableWallInPostAcquireWindow else { return }
        Self._test_disableWallInPostAcquireWindow = false
        stateLock.lock(); effects.videoWall = nil; stateLock.unlock()
    }
    #endif

    /// Tile the frame into an N×M grid (kaleidoscope with `mirror`).
    /// GPU (`SourceEffectGPU.videoWall`) primary; CPU (`TileRepeatRenderer`)
    /// fallback when Metal init fails. Opaque output on both paths.
    private func applyVideoWall(_ frame: VideoFrame, wall: VideoWall) -> VideoFrame? {
        // sol #4: `process(_:)` snapshotted `fx.videoWall` at the top of this callback;
        // the main actor may have DISABLED the wall since. `captureEffectGPU()` correctly
        // refuses to (re)create the GPU when disabled and returns nil — but a nil GPU is
        // AMBIGUOUS: it also means "Metal init failed → CPU fallback". Falling through to
        // the CPU `TileRepeatRenderer` on a DISABLE would render the STALE wall (emitting a
        // disabled-effect frame) AND retain an `FXCanvas` buffer pool. Distinguish the two:
        // when the wall is DISABLED, render NOTHING and release the CPU renderer's pool too
        // (mirrors the GPU floor release), rather than treating it as a GPU failure.
        #if DEBUG
        let enforceDisableGate = !Self._test_skipVideoWallDisableGate
        #else
        let enforceDisableGate = true
        #endif
        if enforceDisableGate {
            stateLock.lock(); let wallOn = effects.videoWall != nil; stateLock.unlock()
            if !wallOn {
                releaseCaptureCPUIfIdle()
                return nil
            }
        }

        // GPU path (primary). Capture-thread instance (time-invariant, F5).
        if let gpu = captureEffectGPU() {
            #if DEBUG
            testDisableWallInPostAcquireWindowIfArmed()
            #endif
            // sol #7 #4/#15: `captureEffectGPU()` re-reads the wall at ACQUISITION, but a
            // disable landing after it returns and before/around the render would still
            // publish one stale tiled frame. Re-check right BEFORE the render (skip wasted
            // GPU work) and right BEFORE EMITTING the frame.
            if videoWallDisabledAtRenderSite() { return nil }
            do {
                let tiled = try gpu.videoWall(source: frame.pixelBuffer,
                                              rows: wall.rows, cols: wall.cols, mirror: wall.mirror)
                if videoWallDisabledAtRenderSite() { return nil }
                return VideoFrame(pixelBuffer: tiled, pts: frame.pts,
                                  duration: frame.duration, source: frame.source)
            } catch {
                log.error("video wall GPU apply failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        // CPU fallback (Metal unavailable). Capture the renderer under `captureCPULock`
        // (sol #5 #15) and use the LOCAL reference: a concurrent synchronous disable
        // (`update` → `releaseCaptureCPUIfIdle`) may nil the ivar while this render is in
        // flight, but the local keeps the in-flight pass valid — mirroring the capture-
        // GPU pattern.
        let renderer: TileRepeatRenderer? = {
            captureCPULock.lock(); defer { captureCPULock.unlock() }
            // sol #6 #15: re-check the CURRENT disabled state INSIDE the CPU-pool lock
            // (the SAME lock `releaseCaptureCPUIfIdle` takes). The top-of-function gate
            // is a TOCTOU: a disable landing after it, with the GPU unavailable, would
            // fall here and RECREATE the renderer — emitting one stale tiled frame and
            // re-pinning the FXCanvas pool. `update(_:)` sets `effects.videoWall = nil`
            // BEFORE releasing the pool, so observing it nil here means bail (no recreate).
            #if DEBUG
            let enforceRenderGate = !Self._test_skipVideoWallRenderSiteGate
            #else
            let enforceRenderGate = true
            #endif
            if enforceRenderGate {
                stateLock.lock(); let wallStillOn = effects.videoWall != nil; stateLock.unlock()
                guard wallStillOn else { return nil }
            }
            if tileRepeatFailed { return nil }
            if tileRepeat == nil {
                do { tileRepeat = try TileRepeatRenderer(width: canvasWidth, height: canvasHeight) }
                catch {
                    tileRepeatFailed = true
                    log.error("tile repeat init failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            return tileRepeat
        }()
        guard let renderer else { return nil }
        #if DEBUG
        testDisableWallInPostAcquireWindowIfArmed()
        #endif
        // sol #7 #4/#15: the acquisition re-check above runs INSIDE `captureCPULock`, but
        // the lock is released before this render/emit — a disable landing in that window
        // would emit one stale tiled frame. Re-check the CURRENT disabled state right
        // BEFORE the render (skip wasted work) and BEFORE EMITTING the frame.
        if videoWallDisabledAtRenderSite() { return nil }
        do {
            let tiled = try renderer.render(source: frame.pixelBuffer,
                                            rows: wall.rows, cols: wall.cols, mirror: wall.mirror)
            if videoWallDisabledAtRenderSite() { return nil }
            return VideoFrame(pixelBuffer: tiled, pts: frame.pts,
                              duration: frame.duration, source: frame.source)
        } catch {
            log.error("tile repeat apply failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Scale/shake the frame on the beat (BEAT_SYNC_DESIGN). Driven by the live
    /// `BeatClock`'s beat-phase; returns nil (⇒ frame passes through unchanged)
    /// when the sequencer is stopped, so a stopped clock means NO pulse — never a
    /// frozen or dead layer. The pass PRESERVES source alpha (F4/Class C): it uses
    /// the default `.clear` background, so a transparent/keyed texel and any strip
    /// the scaled/shaken source does not cover stay premultiplied-transparent
    /// `(0,0,0,0)` — NOT opaque black — and reveal the layers beneath. Do NOT
    /// "repair" this to an opaque background: that reintroduces F4. The common
    /// opaque source stays opaque where covered, so its Layer.premultipliedAlpha
    /// needs no change.
    private func applyBeatPulse(_ frame: VideoFrame, effect: BeatPulseEffect, atSeconds now: Double) -> VideoFrame? {
        let clock = currentBeatClock()
        guard clock != .stopped else { return nil }          // stopped ⇒ identity
        // Phase from the tick PTS (F5), not callback arrival — so two sources at
        // the same tick pulse in the same phase.
        let phase = clock.beatPhase(atHostSeconds: now)
        let transform = beatPulse.pulse(phase: phase, intensity: effect.intensity, style: effect.style)

        // GPU path (primary). Render-thread instance (time-varying, F5).
        if let gpu = animatedEffectGPU() {
            do {
                let pulsed = try gpu.beatPulse(source: frame.pixelBuffer, transform: transform)
                return VideoFrame(pixelBuffer: pulsed, pts: frame.pts,
                                  duration: frame.duration, source: frame.source)
            } catch {
                log.error("beat pulse GPU apply failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        // CPU fallback (Metal unavailable).
        guard !beatPulseRendererFailed else { return nil }
        if beatPulseRenderer == nil {
            do { beatPulseRenderer = try BeatPulseRenderer(width: canvasWidth, height: canvasHeight) }
            catch {
                beatPulseRendererFailed = true
                log.error("beat pulse init failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        guard let beatPulseRenderer else { return nil }
        do {
            let pulsed = try beatPulseRenderer.render(source: frame.pixelBuffer, transform: transform)
            return VideoFrame(pixelBuffer: pulsed, pts: frame.pts,
                              duration: frame.duration, source: frame.source)
        } catch {
            log.error("beat pulse apply failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Flash the frame toward the strobe color (BEAT_SYNC style). When
    /// `syncToBeat` and the sequencer runs, the phase is the live beat-phase so
    /// the flash peaks on the downbeat; otherwise it free-runs at `freeRunHz` off
    /// the house clock (so a stopped sequencer still strobes — never a dead
    /// layer). The flash PRESERVES source alpha (N3/Class C): it modulates colour
    /// only, scaled by the source's own alpha, so a transparent/keyed texel stays
    /// transparent and never flashes an opaque region over the layers beneath. Do
    /// NOT "repair" this to flatten alpha onto an opaque flash. The common opaque
    /// source is unchanged where it flashes, so this source's
    /// Layer.premultipliedAlpha needs no change.
    private func applyStrobe(_ frame: VideoFrame, effect: StrobeEffect, atSeconds now: Double) -> VideoFrame? {
        let clock = currentBeatClock()
        // Phase from the tick PTS (F5), not callback arrival — deterministic per
        // tick and shared across sources; StrobeEffect.envelope wraps free-run
        // phase into 0…1 (a flash every 1/freeRunHz seconds).
        let phase = Self.strobePhase(effect, clock: clock, atSeconds: now)
        let color = RGBA(r: effect.red, g: effect.green, b: effect.blue, a: 1)

        // GPU path (primary). Render-thread instance (time-varying, F5).
        if let gpu = animatedEffectGPU() {
            do {
                let flashed = try gpu.strobe(source: frame.pixelBuffer, phase: phase,
                                             intensity: effect.intensity, color: color)
                return VideoFrame(pixelBuffer: flashed, pts: frame.pts,
                                  duration: frame.duration, source: frame.source)
            } catch {
                log.error("strobe GPU apply failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        // CPU fallback (Metal unavailable).
        guard !strobeEffectFailed else { return nil }
        if strobeEffect == nil {
            do { strobeEffect = try PrismCompositor.StrobeEffect(width: canvasWidth, height: canvasHeight) }
            catch {
                strobeEffectFailed = true
                log.error("strobe init failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        guard let strobeEffect else { return nil }
        do {
            let flashed = try strobeEffect.apply(to: frame.pixelBuffer, phase: phase,
                                                 intensity: effect.intensity, color: color)
            return VideoFrame(pixelBuffer: flashed, pts: frame.pts,
                              duration: frame.duration, source: frame.source)
        } catch {
            log.error("strobe apply failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Capture-thread processors (lazy, single-threaded — no lock)

    private func applyColor(_ frame: VideoFrame, grade: ColorGrade, lut: CubeLUT?) -> VideoFrame? {
        guard !colorProcessorFailed else { return nil }
        if colorProcessor == nil {
            do { colorProcessor = try ColorProcessor(device: device) }
            catch {
                colorProcessorFailed = true
                log.error("color processor init failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        do { return try colorProcessor?.process(frame, grade: grade, lut: lut) }
        catch {
            log.error("color process failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func applyBackground(_ frame: VideoFrame, matte: SegmentationMatte,
                                 mode: BackgroundMode) -> VideoFrame? {
        guard !backgroundEffectFailed else { return nil }
        if backgroundEffect == nil {
            do { backgroundEffect = try BackgroundEffect(device: device) }
            catch {
                backgroundEffectFailed = true
                log.error("background effect init failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        do { return try backgroundEffect?.apply(frame: frame, matte: matte, mode: mode) }
        catch {
            log.error("background apply failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func applyChromaKey(_ frame: VideoFrame, key: ChromaKey, matteView: Bool) -> VideoFrame? {
        guard !chromaKeyProcessorFailed else { return nil }
        if chromaKeyProcessor == nil {
            do { chromaKeyProcessor = try ChromaKeyProcessor(device: device) }
            catch {
                chromaKeyProcessorFailed = true
                log.error("chroma key init failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        do { return try chromaKeyProcessor?.apply(frame: frame, key: key, matteView: matteView) }
        catch {
            log.error("chroma key apply failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func applyLumaKey(_ frame: VideoFrame, key: LumaKey, matteView: Bool) -> VideoFrame? {
        guard !lumaKeyProcessorFailed else { return nil }
        if lumaKeyProcessor == nil {
            do { lumaKeyProcessor = try LumaKeyProcessor(device: device) }
            catch {
                lumaKeyProcessorFailed = true
                log.error("luma key init failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        do { return try lumaKeyProcessor?.apply(frame: frame, key: key, matteView: matteView) }
        catch {
            log.error("luma key apply failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func computeAutoColor(_ frame: VideoFrame, base: ColorGrade) -> ColorGrade? {
        guard !analyzerFailed else { return nil }
        if analyzer == nil {
            do { analyzer = try FrameAnalyzer(device: device) }
            catch {
                analyzerFailed = true
                log.error("frame analyzer init failed for \(self.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        guard let analyzer, let stats = try? analyzer.analyze(frame) else { return nil }
        return AutoColor.suggest(from: stats).applied(to: base)
    }

    // MARK: Segmenter lifecycle (main actor spins up/down)

    private func startSegmenter() {
        matteLock.lock()
        guard segmenter == nil else { matteLock.unlock(); return }
        let seg = PersonSegmenter(quality: .balanced, targetRate: 15)
        // Capture the generation this segmenter belongs to; the callback drops
        // itself once the generation advances (stop / background change), so a
        // late matte can never resurrect after teardown (W1).
        let generation = matteGeneration

        // onMatte fires on the segmenter's private serial queue — the ONLY place
        // the (non-thread-safe) MatteSmoother is driven, so it stays single-threaded.
        // Assigned INSIDE matteLock (atomic with the `segmenter` install) so the
        // callback slot is never mutated outside the lock.
        seg.onMatte = { [weak self] raw in
            guard let self else { return }
            self.matteLock.lock()
            // Superseded (stopSegmenter bumped the generation, or a newer
            // segmenter took over) → drop; never write a stale matte back.
            guard generation == self.matteGeneration, self.segmenter === seg else {
                self.matteLock.unlock(); return
            }
            if self.smoother == nil {
                self.smoother = try? MatteSmoother(device: self.device, alpha: 0.5)
            }
            let smoothed = (try? self.smoother?.smooth(raw)) ?? nil
            self.latestMatte = smoothed ?? raw
            self.matteLock.unlock()
        }
        seg.onError = { [weak self] error in
            self?.log.error("segmentation error: \(error.localizedDescription, privacy: .public)")
        }
        segmenter = seg
        matteLock.unlock()
    }

    private func stopSegmenter() {
        matteLock.lock()
        // Advance the generation first: any matte callback already dispatched on
        // the segmenter's queue will now see the mismatch and drop itself.
        matteGeneration &+= 1
        let seg = segmenter
        segmenter = nil
        // Clear the callback slot INSIDE the lock (was previously cleared after
        // unlock, racing drain()); latestMatte/smoother are cleared atomically
        // with it so no stale matte survives the teardown (W1).
        seg?.onMatte = nil
        seg?.onError = nil
        smoother?.reset()
        smoother = nil
        latestMatte = nil
        matteLock.unlock()
    }
}
