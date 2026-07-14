import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import os
import PrismCore

/// An animated **layered character** source (DESIGN.md §3 — the "characters
/// application" / VTuber rig). A stack of image layers (a base body + swappable
/// expression / eye / mouth overlays) composited into one IOSurface-backed BGRA
/// frame, with:
///  - **Idle animation**: a gentle sinusoidal sway/breath on the whole rig.
///  - **Triggerable reactions**: swap the expression + play a short anime accent
///    (impact-pop scale-punch + white flash, or a decaying shake).
///
/// Loads from a folder + `character.json`; if none is given (or it fails to
/// load), it synthesizes a simple 3-layer placeholder procedurally so the source
/// is always renderable and testable.
///
/// Module note: PrismSources can't depend on PrismCompositor, so the accent math
/// here is a compact self-contained copy of the anime keyframe idea (the
/// canonical multi-keyframe evaluator lives in `PrismCompositor.AnimePreset`).
///
/// **Compositing (B1):** the emitted frames carry a premultiplied-alpha matte —
/// the character occupies a centred sub-rect and everything around it is
/// transparent. A scene `Layer` feeding this source therefore MUST set
/// `premultipliedAlpha: true`, or the compositor forces the transparent
/// surround to opaque and the character renders as a full-canvas black
/// rectangle over the program. Because this module can't name
/// `PrismCompositor.Layer`, the ready-made factory lives there as
/// `Layer.character(sourceID:frame:zIndex:)` (it sets the flag for you).
public final class CharacterSource: TimedVideoSource {

    /// A named anime accent played on a reaction. Each accent is a short
    /// deterministic transform envelope (see `reactionAccent(_:phase:)`) that
    /// **overshoots then settles** — a spring-y "boom" rather than a hard swap.
    public enum Reaction: String, Sendable, CaseIterable {
        case impactPop   // scale-punch (attack→overshoot→settle) + white flash
        case shake       // decaying horizontal shake
        case bounce      // vertical hop that overshoots up then settles
        case wobble      // decaying rotational wobble (a "no"/shiver head shake)
    }

    /// Whole-rig entrance/exit motion for `animateIn` / `animateOut`.
    public enum EntranceStyle: String, Sendable, CaseIterable {
        case slideLeft   // slides in from / out to the left edge
        case slideRight
        case slideUp
        case slideDown
        case pop         // scale-pop with a back-ease overshoot + fade
        case fade        // pure opacity fade
    }

    /// Direction of an in-flight entrance/exit.
    private enum EntranceMode { case none, appearing, disappearing }

    // MARK: Manifest (character.json)

    /// One layer as declared in `character.json`.
    public struct LayerSpec: Codable, Sendable {
        public var name: String
        /// Image filename relative to the character folder (omitted for placeholder).
        public var file: String?
        /// Normalized placement (top-left origin) x,y,w,h.
        public var x: Double; public var y: Double; public var w: Double; public var h: Double
        public var z: Int
        /// `base` (always visible) or an overlay group ("eyes","mouth","brows"…).
        public var group: String
    }

    /// `character.json` shape.
    public struct Manifest: Codable, Sendable {
        public var name: String
        public var defaultExpression: String
        public var layers: [LayerSpec]
        /// expression name → the set of overlay layer names it shows.
        public var expressions: [String: [String]]
    }

    // MARK: Internal render model

    private struct RenderLayer {
        let name: String
        let image: CGImage
        let frame: CGRect          // normalized, top-left origin
        let z: Int
        let group: String          // "base" or an overlay group
    }

    private let log = EngineLog.logger("sources.character")
    private let canvas: SourceRenderCanvas

    private struct State {
        var expression: String
        var reaction: Reaction?
        var reactionStart: Double = 0
        var reactionDuration: Double = 0.5
        /// Bumped when the expression/reaction changes (so a tick can't lose an update).
        var generation: UInt64 = 0

        // --- Lip-sync (the app polls `AudioEnvelopeFollower.openness` and pushes
        //     it via `setMouthOpenness`; this module can't name PrismAudio) ---
        var mouthOpenness: Double = 0        // 0 (closed) … 1 (wide)
        var lipSyncEnabled: Bool = false     // default off → mouth follows expression

        // --- Auto-blink (deterministic seeded schedule off HouseClock) ---
        var autoBlinkEnabled: Bool = true    // default on
        /// Monotonic resume cursor into the blink schedule (advanced past any
        /// blink fully in the past so the per-frame scan stays O(1) amortized).
        var blinkCursorStart: Double = 0
        var blinkCursorIndex: Int = 0

        // --- Entrance / exit ---
        var entranceMode: EntranceMode = .none
        var entranceStyle: EntranceStyle = .pop
        var entranceStart: Double = 0
        var entranceDuration: Double = 0.6
    }
    private let lock: OSAllocatedUnfairLock<State>
    private let layers: [RenderLayer]          // immutable after init
    private let expressions: [String: Set<String>]
    /// Resolved layer roles (by name heuristic, once at init) used by the
    /// transient overrides — blink swaps to `closedEyeLayerName`; lip-sync
    /// cross-fades `closedMouthLayerName` → `openMouthLayerName`. Any `nil`
    /// role simply disables that override (the feature no-ops, staying additive).
    private let closedEyeLayerName: String?
    private let closedMouthLayerName: String?
    private let openMouthLayerName: String?
    /// Idle-animation anchor in HOUSE time seconds (B2): the same clock family as
    /// capture PTS and the reaction window — never `Date()` wall-clock, which is
    /// non-deterministic and jumps under NTP correction.
    private let startHouse = HouseClock.nowSeconds()

    // MARK: Init

    /// Load a character from a folder containing `character.json`.
    public init(id: SourceID = SourceID("character.\(UUID().uuidString)"),
                folder: URL,
                canvasSize: CanvasSize = .hd,
                fps: Double = 60) throws {
        self.canvas = try SourceRenderCanvas(size: canvasSize)
        // B3: a bad manifest/asset must NOT throw — the class contract promises
        // the source is ALWAYS renderable, so fall back to the procedural
        // placeholder on any typed load failure (and log which one).
        let loaded: ([RenderLayer], [String: Set<String>], String)
        do {
            loaded = try Self.load(folder: folder)
        } catch {
            EngineLog.logger("sources.character").error(
                "character load failed for \(folder.path, privacy: .public) — using placeholder: \(String(describing: error), privacy: .public)")
            loaded = Self.placeholder()
        }
        self.layers = loaded.0
        self.expressions = loaded.1
        let roles = Self.resolveRoles(loaded.0)
        self.closedEyeLayerName = roles.closedEye
        self.closedMouthLayerName = roles.closedMouth
        self.openMouthLayerName = roles.openMouth
        self.lock = OSAllocatedUnfairLock(initialState: State(expression: loaded.2))
        super.init(id: id, fps: fps, label: "studio.prism.source.character")
    }

    /// Synthesize a simple procedural placeholder character (no assets needed).
    public init(id: SourceID = SourceID("character.placeholder.\(UUID().uuidString)"),
                canvasSize: CanvasSize = .hd,
                fps: Double = 60) throws {
        self.canvas = try SourceRenderCanvas(size: canvasSize)
        let (rl, exprs, def) = Self.placeholder()
        self.layers = rl
        self.expressions = exprs
        let roles = Self.resolveRoles(rl)
        self.closedEyeLayerName = roles.closedEye
        self.closedMouthLayerName = roles.closedMouth
        self.openMouthLayerName = roles.openMouth
        self.lock = OSAllocatedUnfairLock(initialState: State(expression: def))
        super.init(id: id, fps: fps, label: "studio.prism.source.character")
    }

    #if DEBUG
    /// TEST-ONLY (F19): build a rig from explicit layers so a pixel test can drive
    /// the lip-sync crossfade on a **non-coincident** mouth rig (open mouth ink not
    /// covering every closed mouth pixel) and prove the closed mouth fades fully
    /// OUT at openness 1. Not part of the public API.
    init(id: SourceID,
         canvasSize: CanvasSize,
         fps: Double,
         testLayers: [(name: String, image: CGImage, frame: CGRect, z: Int, group: String)],
         expressions: [String: Set<String>],
         defaultExpression: String) throws {
        self.canvas = try SourceRenderCanvas(size: canvasSize)
        let rl = testLayers.map {
            RenderLayer(name: $0.name, image: $0.image, frame: $0.frame, z: $0.z, group: $0.group)
        }
        self.layers = rl
        self.expressions = expressions
        let roles = Self.resolveRoles(rl)
        self.closedEyeLayerName = roles.closedEye
        self.closedMouthLayerName = roles.closedMouth
        self.openMouthLayerName = roles.openMouth
        self.lock = OSAllocatedUnfairLock(initialState: State(expression: defaultExpression))
        super.init(id: id, fps: fps, label: "studio.prism.source.character.test")
    }
    #endif

    /// Pick the closed-eye / closed-mouth / open-mouth layers by name heuristic
    /// (once at init). Naming is the only signal `character.json` carries, so we
    /// match common substrings and degrade to `nil` (feature off) when absent.
    private static func resolveRoles(_ layers: [RenderLayer])
        -> (closedEye: String?, closedMouth: String?, openMouth: String?) {
        func firstName(group: String, _ needles: [String]) -> String? {
            for l in layers where l.group == group {
                let n = l.name.lowercased()
                if needles.contains(where: { n.contains($0) }) { return l.name }
            }
            return nil
        }
        let mouthLayers = layers.filter { $0.group == "mouth" }
        let closedEye = firstName(group: "eyes", ["closed", "blink", "shut"])
        let closedMouth = firstName(group: "mouth", ["closed", "close"])
            ?? firstName(group: "mouth", ["neutral", "smile", "rest"])
            ?? mouthLayers.first?.name
        var openMouth = firstName(group: "mouth", ["open", "wide", "aah", "talk"])
        if openMouth == nil, mouthLayers.count > 1 { openMouth = mouthLayers.last?.name }
        if openMouth == closedMouth { openMouth = nil }   // need two distinct layers to interpolate
        return (closedEye, closedMouth, openMouth)
    }

    // MARK: Control

    /// Available expression names.
    public var expressionNames: [String] { Array(expressions.keys).sorted() }

    /// Swap the visible expression (no accent).
    public func setExpression(_ name: String) {
        lock.withLock { if expressions[name] != nil { $0.expression = name; $0.generation &+= 1 } }
    }

    /// Trigger a reaction: swap to `expression` (if given) and play `accent`.
    public func react(expression: String? = nil, accent: Reaction = .impactPop, duration: Double = 0.5) {
        lock.withLock {
            if let expression, expressions[expression] != nil { $0.expression = expression }
            $0.reaction = accent
            $0.reactionStart = HouseClock.nowSeconds()
            $0.reactionDuration = max(duration, 0.05)
            $0.generation &+= 1
        }
    }

    /// The current expression (for tests / UI).
    public func currentExpression() -> String { lock.withLock { $0.expression } }

    // MARK: Lip-sync

    /// Feed the current mouth-openness (0 closed … 1 wide). Thread-safe; call it
    /// each frame from the app, which polls `PrismAudio.AudioEnvelopeFollower
    /// .openness` (this module can't depend on PrismAudio). When `lipSyncEnabled`
    /// is true this drives the mouth (cross-fading the closed→open mouth layers);
    /// the expression still controls eyes/brows. The follower already smooths, so
    /// no extra smoothing is applied here (a light map keeps it responsive).
    public func setMouthOpenness(_ value: Double) {
        let v = value.isFinite ? min(max(value, 0), 1) : 0
        lock.withLock { $0.mouthOpenness = v }
    }

    /// When on, `setMouthOpenness` drives the mouth. Default **off** (mouth
    /// follows the expression, exactly as before). Thread-safe.
    public var lipSyncEnabled: Bool {
        get { lock.withLock { $0.lipSyncEnabled } }
        set { lock.withLock { $0.lipSyncEnabled = newValue } }
    }

    /// Periodic auto-blink (deterministic seeded schedule off HouseClock).
    /// Default **on**. Thread-safe.
    public var autoBlinkEnabled: Bool {
        get { lock.withLock { $0.autoBlinkEnabled } }
        set { lock.withLock { $0.autoBlinkEnabled = newValue } }
    }

    // MARK: Entrance / exit

    /// Animate the whole character **in** on cue (slides/pops/fades in). Runs off
    /// house time over `duration`; before it completes the rig is off-screen /
    /// scaled-down / transparent per `style`, then eases to rest.
    public func animateIn(style: EntranceStyle = .pop, duration: Double = 0.6) {
        lock.withLock {
            $0.entranceMode = .appearing
            $0.entranceStyle = style
            $0.entranceStart = HouseClock.nowSeconds()
            $0.entranceDuration = max(duration, 0.05)
            $0.generation &+= 1
        }
    }

    /// Animate the whole character **out** on cue (reverse of `animateIn`); it
    /// stays hidden once the exit completes.
    public func animateOut(style: EntranceStyle = .fade, duration: Double = 0.6) {
        lock.withLock {
            $0.entranceMode = .disappearing
            $0.entranceStyle = style
            $0.entranceStart = HouseClock.nowSeconds()
            $0.entranceDuration = max(duration, 0.05)
            $0.generation &+= 1
        }
    }

    // MARK: Render

    override func didStart() throws {
        // Emit one frame eagerly only after TimedVideoSource has committed this
        // run. A stop from this callback therefore invalidates the generation
        // before start() considers launching the repeating timer.
        let (buffer, pts) = try renderFrame()
        emit(buffer, pts: pts)
    }

    override func tick() {
        do {
            let (buffer, pts) = try renderFrame()
            emit(buffer, pts: pts)
        }
        catch { log.error("character render failed: \(String(describing: error), privacy: .public)") }
    }

    // MARK: Deterministic animation math (self-contained, no Date/rand)

    /// The per-frame transform envelope for a reaction accent (fraction-of-canvas
    /// units; `scaleBoost` adds to the rest scale of 1). Pure + deterministic —
    /// a function of `(reaction, phase)` only. Each accent **overshoots then
    /// settles** (`scaleBoost`/`transY`/`rot` peak past rest, then decay to ~0 by
    /// phase 1) so a reaction reads as a bouncy "boom", not a hard swap.
    struct Accent { var scaleBoost = 0.0; var shakeX = 0.0; var transY = 0.0; var rot = 0.0; var flash = 0.0 }

    static func reactionAccent(_ reaction: Reaction, phase: Double) -> Accent {
        let p = min(max(phase, 0), 1)
        switch reaction {
        case .impactPop:
            // Attack→overshoot→settle: an attack-decay curve peaking (≈+0.34
            // scale) shortly after the hit, decaying back to rest by phase 1.
            let a = 0.16
            let shape = (p / a) * exp(1 - p / a)            // 0 at p=0, peak 1 at p=a, →0
            return Accent(scaleBoost: 0.34 * shape, flash: max(0, 1 - p * 5))
        case .shake:
            let env = 1 - p
            return Accent(shakeX: 0.03 * sin(p * 40) * env, flash: max(0, 0.4 - p * 2))
        case .bounce:
            let env = exp(-3 * p)
            // Hops up then settles (a couple of decaying bounces).
            return Accent(scaleBoost: -0.05 * env * abs(sin(2 * .pi * 1.5 * p)),
                          transY: 0.06 * env * cos(2 * .pi * 1.5 * p))
        case .wobble:
            let env = exp(-4 * p)
            return Accent(rot: 0.10 * env * cos(2 * .pi * 2.5 * p))
        }
    }

    /// Whole-rig entrance transform for an eased `progress` (0…1). Returns the
    /// screen-space offset (fraction of canvas), a scale multiplier and a group
    /// alpha. `appearing == false` (an exit) is the same shape played in reverse.
    /// Pure + deterministic.
    static func entranceTransform(style: EntranceStyle, appearing: Bool, progress: Double)
        -> (dx: Double, dy: Double, scale: Double, alpha: Double) {
        if !appearing {
            return entranceTransform(style: style, appearing: true, progress: 1 - progress)
        }
        let p = min(max(progress, 0), 1)
        let off = 1.4                                        // fully off-canvas at p=0
        func easeOutCubic(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
        func easeOutBack(_ t: Double) -> Double {
            let c1 = 1.70158, c3 = c1 + 1; let x = t - 1
            return 1 + c3 * x * x * x + c1 * x * x           // overshoots slightly past 1
        }
        switch style {
        case .slideLeft:  return (-off * (1 - easeOutCubic(p)), 0, 1, 1)
        case .slideRight: return ( off * (1 - easeOutCubic(p)), 0, 1, 1)
        case .slideUp:    return (0,  off * (1 - easeOutCubic(p)), 1, 1)
        case .slideDown:  return (0, -off * (1 - easeOutCubic(p)), 1, 1)
        case .pop:        return (0, 0, 0.2 + 0.8 * easeOutBack(p), min(1, p * 3))
        case .fade:       return (0, 0, 1, easeOutCubic(p))
        }
    }

    /// Deterministic blink schedule — no `Date`/`rand`. Blink `k` happens at a
    /// seeded interval (`blinkMinGap…blinkMaxGap`) after the previous, and lasts
    /// `blinkCloseDuration`. Returns the closed-amount (0 open … 1 shut) at
    /// house-relative time `tRel`, resuming from a monotonic cursor advanced past
    /// finished blinks (so the per-frame scan is O(1) amortized).
    public static let blinkSeed: UInt64 = 0x9E37_79B9_7F4A_7C15
    static let blinkCloseDuration = 0.12
    static let blinkMinGap = 2.0
    static let blinkMaxGap = 6.0

    /// Seeded gap (seconds) before blink `index`, in `[blinkMinGap, blinkMaxGap]`.
    static func blinkGap(_ index: Int) -> Double {
        // splitmix64 finalizer → a stable unit fraction per index.
        var z = blinkSeed &+ (UInt64(bitPattern: Int64(index)) &* 0x9E37_79B9_7F4A_7C15)
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        let u = Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)   // 2^53
        return blinkMinGap + (blinkMaxGap - blinkMinGap) * u
    }

    static func blinkClosedAmount(tRel: Double, cursorStart: inout Double, cursorIndex: inout Int) -> Double {
        while true {
            let bStart = cursorStart + blinkGap(cursorIndex)
            if tRel < bStart { return 0 }                                   // before this blink
            if tRel < bStart + blinkCloseDuration {                         // during blink `index`
                let half = blinkCloseDuration / 2
                let local = tRel - bStart
                return max(0, 1 - abs(local - half) / half)                 // triangle 0→1→0
            }
            cursorStart = bStart + blinkCloseDuration                       // advance past it
            cursorIndex += 1
        }
    }

    // MARK: Render

    /// The resolved animation state for one frame — built from a single house-time
    /// read under the lock, then rendered by `renderComposite`. Splitting it out
    /// keeps the drawing pure + deterministic (the self-test drives it directly).
    struct AnimParams {
        var idleT: Double            // seconds since startHouse (idle phase)
        var expression: String
        var mouthOpenness: Double    // 0…1
        var lipSync: Bool
        var closedAmount: Double     // blink 0…1
        var accent: Accent?          // active reaction envelope, if any
        var entrance: (style: EntranceStyle, appearing: Bool, progress: Double)?
    }

    /// Compose the character for the current time (idle sway + lip-sync + blink +
    /// any active accent + entrance). Returns the composited buffer and the
    /// house-time PTS sampled for it (B2): idle phase, blink schedule, reaction
    /// window, entrance window and the emitted stamp all use this one `HouseClock`
    /// read.
    private func renderFrame() throws -> (CVPixelBuffer, CMTime) {
        let nowTime = HouseClock.now()
        let now = nowTime.seconds
        let params: AnimParams = lock.withLock { st in
            let tRel = now - startHouse

            var accent: Accent? = nil
            if let r = st.reaction, now >= st.reactionStart, now < st.reactionStart + st.reactionDuration {
                accent = Self.reactionAccent(r, phase: (now - st.reactionStart) / st.reactionDuration)
            }

            var closed = 0.0
            if st.autoBlinkEnabled {
                closed = Self.blinkClosedAmount(tRel: tRel,
                                                cursorStart: &st.blinkCursorStart,
                                                cursorIndex: &st.blinkCursorIndex)
            }

            var entrance: (EntranceStyle, Bool, Double)? = nil
            switch st.entranceMode {
            case .none: break
            case .appearing:
                let p = (now - st.entranceStart) / max(st.entranceDuration, 0.001)
                if p >= 1 { st.entranceMode = .none }        // settled at rest → normal
                else { entrance = (st.entranceStyle, true, max(0, p)) }
            case .disappearing:
                let p = (now - st.entranceStart) / max(st.entranceDuration, 0.001)
                entrance = (st.entranceStyle, false, min(max(p, 0), 1))   // stays hidden at p≥1
            }

            return AnimParams(idleT: tRel, expression: st.expression,
                              mouthOpenness: st.mouthOpenness, lipSync: st.lipSyncEnabled,
                              closedAmount: closed, accent: accent, entrance: entrance)
        }
        let buffer = try renderComposite(params)
        return (buffer, nowTime)
    }

    /// Draw the layered rig for a resolved `AnimParams` into a fresh IOSurface
    /// BGRA buffer. Pure w.r.t. its input (deterministic) — the self-test feeds it
    /// crafted params to prove lip-sync / blink / overshoot / entrance on pixels.
    func renderComposite(_ params: AnimParams) throws -> CVPixelBuffer {
        let t = params.idleT
        let bob = sin(t * 2 * .pi * 0.5) * 0.010          // vertical breath, fraction of height
        let breathe = 1 + sin(t * 2 * .pi * 0.5) * 0.006  // subtle scale
        let idleRot = sin(t * 2 * .pi * 0.22) * 0.010     // slight rotational sway (radians)

        let accent = params.accent ?? Accent()
        let scaleBoost = accent.scaleBoost, shakeX = accent.shakeX
        let accTransY = accent.transY, accRot = accent.rot, flash = accent.flash

        // Entrance transform (identity when no entrance active).
        var entDx = 0.0, entDy = 0.0, entScale = 1.0, entAlpha = 1.0
        if let e = params.entrance {
            let tr = Self.entranceTransform(style: e.style, appearing: e.appearing, progress: e.progress)
            entDx = tr.dx; entDy = tr.dy; entScale = tr.scale; entAlpha = tr.alpha
        }

        let w = CGFloat(canvas.width), h = CGFloat(canvas.height)
        let center = CGPoint(x: w / 2, y: h / 2)
        let scale = (CGFloat(breathe) + CGFloat(scaleBoost)) * CGFloat(entScale)

        // Resolve which layers draw + at what alpha (blink & lip-sync override the
        // eye/mouth groups transiently; everything else follows the expression).
        let visible = expressions[params.expression] ?? []
        let blinking = params.closedAmount > 0.001 && closedEyeLayerName != nil
        let lipSync = params.lipSync && closedMouthLayerName != nil && openMouthLayerName != nil
        let openness = CGFloat(min(max(params.mouthOpenness, 0), 1))
        var draws: [(RenderLayer, CGFloat)] = []
        for layer in layers {
            switch layer.group {
            case "base":
                draws.append((layer, 1))
            case "eyes":
                if blinking {
                    if layer.name == closedEyeLayerName { draws.append((layer, CGFloat(params.closedAmount))) }
                    else if visible.contains(layer.name) { draws.append((layer, CGFloat(1 - params.closedAmount))) }
                } else if visible.contains(layer.name) {
                    draws.append((layer, 1))
                }
            case "mouth":
                if lipSync {
                    // Cross-fade closed→open by openness (mouth "opens" with it);
                    // the expression's own mouth layers are suppressed. F19: this
                    // is a REAL crossfade — closed fades OUT as open fades IN, so at
                    // openness 1 the closed mouth is fully gone (no "two mouths" on a
                    // non-coincident rig where open doesn't cover every closed pixel).
                    if layer.name == closedMouthLayerName { draws.append((layer, 1 - openness)) }
                    else if layer.name == openMouthLayerName { draws.append((layer, openness)) }
                } else if visible.contains(layer.name) {
                    draws.append((layer, 1))
                }
            default:
                if visible.contains(layer.name) { draws.append((layer, 1)) }
            }
        }
        draws.sort { $0.0.z < $1.0.z }

        let groupAlpha = min(max(entAlpha, 0), 1)
        let buffer = try canvas.render { ctx in
            ctx.saveGState()
            // Whole-rig transform: entrance offset + sway/accent offset, breathe/
            // punch/entrance scale, idle+wobble rotation — about center.
            ctx.translateBy(x: CGFloat(entDx) * w, y: CGFloat(entDy) * h)
            ctx.translateBy(x: CGFloat(shakeX) * w, y: -CGFloat(bob + accTransY) * h)
            ctx.translateBy(x: center.x, y: center.y)
            ctx.scaleBy(x: scale, y: scale)
            ctx.rotate(by: CGFloat(idleRot + accRot))
            ctx.translateBy(x: -center.x, y: -center.y)

            // A transparency layer applies the entrance/exit group alpha ONCE over
            // the composited rig (no double-blend where layers overlap).
            let grouped = groupAlpha < 0.999
            if grouped { ctx.setAlpha(CGFloat(groupAlpha)); ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
            for (layer, a) in draws {
                let r = CGRect(x: layer.frame.minX * w,
                               y: (1 - layer.frame.minY - layer.frame.height) * h,
                               width: layer.frame.width * w, height: layer.frame.height * h)
                ctx.setAlpha(a)
                ctx.draw(layer.image, in: r)
            }
            ctx.setAlpha(1)
            if grouped { ctx.endTransparencyLayer() }
            ctx.restoreGState()

            if flash > 0.01 {
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                ctx.setAlpha(CGFloat(min(flash, 1)) * CGFloat(groupAlpha))
                ctx.fill(canvas.canvasRect)
                ctx.setAlpha(1)
            }
        }
        return buffer
    }

    // MARK: Loading

    /// Load + VALIDATE a `character.json` folder (B3). Every failure is a typed
    /// `SourceError` (no raw Cocoa/DecodingError leak); the caller (`init`) turns
    /// any throw into the procedural placeholder so the source stays renderable.
    private static func load(folder: URL) throws -> ([RenderLayer], [String: Set<String>], String) {
        let manifestURL = folder.appendingPathComponent("character.json")
        let data: Data
        do { data = try Data(contentsOf: manifestURL) }
        catch { throw SourceError.imageLoadFailed(path: manifestURL.path, underlying: error) }
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: data) }
        catch { throw SourceError.invalidConfiguration(reason: "character.json decode failed: \(error)") }

        // --- Structural validation BEFORE touching image assets ---
        guard !manifest.layers.isEmpty else {
            throw SourceError.invalidConfiguration(reason: "character.json declares no layers")
        }
        guard manifest.layers.contains(where: { $0.group == "base" }) else {
            throw SourceError.invalidConfiguration(reason: "character.json declares no base layer")
        }
        guard !manifest.expressions.isEmpty,
              manifest.expressions[manifest.defaultExpression] != nil else {
            throw SourceError.invalidConfiguration(
                reason: "defaultExpression '\(manifest.defaultExpression)' is not among the declared expressions")
        }
        let layerNames = Set(manifest.layers.map(\.name))
        for (expr, overlays) in manifest.expressions {
            for name in overlays where !layerNames.contains(name) {
                throw SourceError.invalidConfiguration(
                    reason: "expression '\(expr)' references unknown layer '\(name)'")
            }
        }
        for spec in manifest.layers {
            let finite = [spec.x, spec.y, spec.w, spec.h].allSatisfy { $0.isFinite }
            guard finite, spec.w > 0, spec.h > 0,
                  spec.x >= 0, spec.y >= 0,
                  spec.x + spec.w <= 1.0001, spec.y + spec.h <= 1.0001 else {
                throw SourceError.invalidConfiguration(
                    reason: "layer '\(spec.name)' has an out-of-range rect (\(spec.x),\(spec.y),\(spec.w),\(spec.h))")
            }
        }

        var rl: [RenderLayer] = []
        for spec in manifest.layers {
            guard let file = spec.file else { continue }
            let url = folder.appendingPathComponent(file)
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetCount(src) > 0,
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                throw SourceError.imageLoadFailed(path: url.path, underlying: nil)
            }
            rl.append(RenderLayer(name: spec.name, image: img,
                                  frame: CGRect(x: spec.x, y: spec.y, width: spec.w, height: spec.h),
                                  z: spec.z, group: spec.group))
        }
        guard rl.contains(where: { $0.group == "base" }) else {
            throw SourceError.invalidConfiguration(
                reason: "no renderable base layer (base layer(s) lacked a loadable image file)")
        }
        let exprs = manifest.expressions.mapValues { Set($0) }
        return (rl, exprs, manifest.defaultExpression)
    }

    // MARK: Placeholder synthesis

    /// A simple 3-group placeholder: a body/head (base) + eye variants + mouth
    /// variants, expressive enough to see idle sway and reaction expression swaps.
    private static func placeholder() -> ([RenderLayer], [String: Set<String>], String) {
        func img(_ px: Int = 512, _ draw: (CGContext) -> Void) -> CGImage {
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            draw(ctx)
            return ctx.makeImage()!
        }
        // NOTE: these mini-images are drawn in their own bottom-left-origin space;
        // eye/mouth positions here are relative to each layer's own frame.
        let body = img { ctx in
            // Head (circle) + shoulders (rounded rect).
            ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.85, blue: 0.73, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 96, y: 160, width: 320, height: 320))
            ctx.setFillColor(CGColor(srgbRed: 0.20, green: 0.45, blue: 0.75, alpha: 1))
            ctx.fill(CGRect(x: 60, y: 0, width: 392, height: 190))
        }
        func eyes(happy: Bool, surprised: Bool, closed: Bool = false) -> CGImage {
            img { ctx in
                ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1))
                let y: CGFloat = 300
                if closed {
                    // Two short horizontal lids (the blink frame).
                    ctx.setLineCap(.round); ctx.setLineWidth(14)
                    ctx.setStrokeColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1))
                    for cx in [182.0, 332.0] {
                        ctx.move(to: CGPoint(x: cx - 28, y: y + 20)); ctx.addLine(to: CGPoint(x: cx + 28, y: y + 20))
                    }
                    ctx.strokePath()
                } else if surprised {
                    ctx.fillEllipse(in: CGRect(x: 150, y: y - 20, width: 60, height: 70))
                    ctx.fillEllipse(in: CGRect(x: 300, y: y - 20, width: 60, height: 70))
                } else if happy {
                    // Upward arcs.
                    for cx in [180.0, 330.0] {
                        ctx.setLineWidth(14); ctx.setStrokeColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1))
                        ctx.addArc(center: CGPoint(x: cx, y: y), radius: 34, startAngle: .pi * 0.1, endAngle: .pi * 0.9, clockwise: false)
                        ctx.strokePath()
                    }
                } else {
                    ctx.fillEllipse(in: CGRect(x: 160, y: y, width: 44, height: 44))
                    ctx.fillEllipse(in: CGRect(x: 310, y: y, width: 44, height: 44))
                }
            }
        }
        func mouth(open: Bool, smile: Bool) -> CGImage {
            img { ctx in
                ctx.setStrokeColor(CGColor(srgbRed: 0.5, green: 0.15, blue: 0.15, alpha: 1))
                ctx.setFillColor(CGColor(srgbRed: 0.7, green: 0.2, blue: 0.2, alpha: 1))
                ctx.setLineWidth(12)
                if open {
                    ctx.fillEllipse(in: CGRect(x: 210, y: 200, width: 90, height: 70))
                } else if smile {
                    ctx.addArc(center: CGPoint(x: 256, y: 250), radius: 60, startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false)
                    ctx.strokePath()
                } else {
                    ctx.move(to: CGPoint(x: 210, y: 235)); ctx.addLine(to: CGPoint(x: 300, y: 235)); ctx.strokePath()
                }
            }
        }
        // Whole rig occupies a centered square; overlays share the same frame so
        // their internal positions line up on the face.
        let faceFrame = CGRect(x: 0.30, y: 0.12, width: 0.40, height: 0.72)
        let rl: [RenderLayer] = [
            RenderLayer(name: "body", image: body, frame: faceFrame, z: 0, group: "base"),
            RenderLayer(name: "eyes_neutral", image: eyes(happy: false, surprised: false), frame: faceFrame, z: 2, group: "eyes"),
            RenderLayer(name: "eyes_happy", image: eyes(happy: true, surprised: false), frame: faceFrame, z: 2, group: "eyes"),
            RenderLayer(name: "eyes_surprised", image: eyes(happy: false, surprised: true), frame: faceFrame, z: 2, group: "eyes"),
            // Blink frame — NOT part of any expression; auto-blink swaps to it transiently.
            RenderLayer(name: "eyes_closed", image: eyes(happy: false, surprised: false, closed: true), frame: faceFrame, z: 2, group: "eyes"),
            RenderLayer(name: "mouth_closed", image: mouth(open: false, smile: false), frame: faceFrame, z: 3, group: "mouth"),
            RenderLayer(name: "mouth_smile", image: mouth(open: false, smile: true), frame: faceFrame, z: 3, group: "mouth"),
            RenderLayer(name: "mouth_open", image: mouth(open: true, smile: false), frame: faceFrame, z: 3, group: "mouth"),
        ]
        let expressions: [String: Set<String>] = [
            "neutral": ["eyes_neutral", "mouth_closed"],
            "happy": ["eyes_happy", "mouth_smile"],
            "surprised": ["eyes_surprised", "mouth_open"],
        ]
        return (rl, expressions, "neutral")
    }
}
