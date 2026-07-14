import CoreGraphics
import CoreMedia
import Foundation
import PrismCore

/// Direction for the wipe / push / slide family.
public enum FXDirection: String, Sendable, CaseIterable, Codable {
    case left, right, up, down
}

/// The transition library (DESIGN.md §1). Each kind is a blend over
/// `progress 0→1`; parameters (duration/easing/direction) live in
/// `TransitionSpec`.
///
/// ## One math, all compositor-native
/// Every kind runs NATIVELY in the live Metal compositor via
/// `TransitionSpec.schedule(...)` → `TransitionSchedule` → `RenderLoop.switchScene`:
/// - **Layer-quad** kinds: `dissolve` (GPU crossfade-mix), `push`/`slide` and
///   `wipe` (overlay stack + animated layer geometry).
/// - **Pixel-effect** kinds (`iris`, `zoomBlur`, `glitch`, `animeFlash`,
///   `speedline`) and the **tile / grid** kinds (`blockDissolve`, `gridWipe`,
///   `checkerboard`, `tileReveal`, `tileFlicker`) run through the compositor's
///   per-pixel FX pass (the `.effect` blend → `prism_fx_fragment` shader), whose
///   math MATCHES the CPU `TransitionRenderer` / `TileSchedule` exactly. So the
///   real per-pixel look renders live, not a crossfade. `TransitionRenderer`
///   stays the CPU ground-truth / preview reference (and the single source of
///   the effect math); `TileMask` remains the per-LAYER live hole-punch (a
///   different use: reveal arbitrary layers beneath, not a baked A→B pair).
public enum TransitionKind: Sendable, Equatable {
    /// Cross-dissolve (A fades into B). Compositor-native (crossfade mix).
    case dissolve
    /// Hard boundary sweeps; B grows from `edge`. Compositor-native (crop+frame).
    case wipe(FXDirection)
    /// Both scenes translate; A exits toward `edge`, B enters opposite. Compositor-native (overlay).
    case push(FXDirection)
    /// Circular reveal of B growing from center. Pixel-effect (circular mask).
    case iris
    /// Zoom-and-blur cross (A zooms out, B zooms in). Pixel-effect.
    case zoomBlur
    /// RGB-split digital glitch over a dissolve. Pixel-effect.
    case glitch
    /// Blow to white at the cut, then reveal B. Pixel-effect (flash frame).
    case animeFlash
    /// Radial speedline sweep over the cut. Pixel-effect.
    case speedline

    // MARK: Tile / grid family (Build A — the "square boxes" reveal)

    /// **Block Dissolve** — top-layer tiles turn transparent in a SEEDED random
    /// order as progress 0→1, revealing B. `seed` is deterministic (no RNG state);
    /// `softness` (0…1) feathers each tile's hole edge. Pixel-effect.
    case blockDissolve(rows: Int, cols: Int, seed: UInt64, softness: Double)
    /// **Grid Wipe** — tiles reveal in a sequential/directional sweep. Pixel-effect.
    case gridWipe(rows: Int, cols: Int, direction: FXDirection, softness: Double)
    /// **Checkerboard / Checker Wipe** — alternating-parity tiles reveal first,
    /// then the rest. Pixel-effect.
    case checkerboard(rows: Int, cols: Int, softness: Double)
    /// **Tile Reveal** — every tile reveals uniformly via a centered box that
    /// grows from nothing to full over progress. Pixel-effect.
    case tileReveal(rows: Int, cols: Int, softness: Double)
    /// **Tile Flicker** — CONTINUOUS blink: tiles toggle on AND off over a looping
    /// phase (each tile a seeded phase offset). NOT a one-way transition — pass a
    /// looping phase 0→1 (it never short-circuits to A or B). Pixel-effect.
    case tileFlicker(rows: Int, cols: Int, seed: UInt64, softness: Double)

    /// `slide` is an alias many UIs use for `push`.
    public static func slide(_ d: FXDirection) -> TransitionKind { .push(d) }

    /// True when the kind runs through the GPU compositor via a
    /// `TransitionSchedule`. Every kind is now compositor-native: `dissolve`/
    /// `wipe`/`push` via the crossfade/overlay blends, and the pixel-effect and
    /// tile kinds via the `.effect` blend (the `prism_fx_fragment` GPU pass).
    public var isCompositorNative: Bool { true }

    /// True when the kind is a per-pixel/tile GPU **effect** (the `.effect`
    /// blend) rather than the plain layer-quad crossfade/overlay path.
    public var isPixelEffect: Bool {
        switch self {
        case .dissolve, .wipe, .push: return false
        case .iris, .zoomBlur, .glitch, .animeFlash, .speedline,
             .blockDissolve, .gridWipe, .checkerboard, .tileReveal, .tileFlicker:
            return true
        }
    }

    /// Stable label for logs / PNG filenames.
    public var label: String {
        switch self {
        case .dissolve: return "dissolve"
        case .wipe(let d): return "wipe_\(d.rawValue)"
        case .push(let d): return "push_\(d.rawValue)"
        case .iris: return "iris"
        case .zoomBlur: return "zoomblur"
        case .glitch: return "glitch"
        case .animeFlash: return "animeflash"
        case .speedline: return "speedline"
        case .blockDissolve(let r, let c, let s, _): return "blockdissolve_\(r)x\(c)_s\(s)"
        case .gridWipe(let r, let c, let d, _):      return "gridwipe_\(r)x\(c)_\(d.rawValue)"
        case .checkerboard(let r, let c, _):         return "checkerboard_\(r)x\(c)"
        case .tileReveal(let r, let c, _):           return "tilereveal_\(r)x\(c)"
        case .tileFlicker(let r, let c, let s, _):   return "tileflicker_\(r)x\(c)_s\(s)"
        }
    }
}

/// A fully-parameterized transition: what kind, how long, and its easing.
public struct TransitionSpec: Sendable, Equatable {
    public var kind: TransitionKind
    /// Total length in house-time seconds. `<= 0` is treated as a hard cut.
    public var duration: Double
    public var easing: Easing

    public init(kind: TransitionKind, duration: Double = 0.5, easing: Easing = .easeInOut) {
        self.kind = kind
        self.duration = duration
        self.easing = easing
    }

    public var isCompositorNative: Bool { kind.isCompositorNative }

    /// Eased progress (0…1) at `elapsed` seconds since the transition began.
    public func progress(atElapsed elapsed: Double) -> Double {
        guard duration > 0 else { return 1 }
        return min(max(easing.apply(elapsed / duration), 0), 1)
    }

    // MARK: - Compositor-native scheduling

    /// Build a `TransitionSchedule` that plugs into
    /// `RenderLoop.switchScene(to:transition:)` for the compositor-native kinds,
    /// so a scene-preset switch can use this transition on the real zero-copy
    /// path. Returns `nil` for pixel-effect kinds (drive those with
    /// `TransitionRenderer`).
    ///
    /// - `dissolve` → `.crossfade` (the compositor's intermediate-texture mix).
    /// - `push`/`slide` → `.overlay` with both scenes' full-frame layers
    ///   translated by the eased progress (incoming under, outgoing over — the
    ///   motion reveals B, matching `TransitionSchedule`'s documented seam).
    /// - `wipe` → `.overlay` with the outgoing scene's full-frame layers clipped
    ///   to the un-wiped region (matched `frame`+`crop`), incoming full beneath.
    ///
    /// Geometry note: `push`/`wipe` schedules assume the animated layers are
    /// full-frame `(0,0,1,1)`. Sub-frame layers still render, but their motion
    /// is computed against the full canvas (documented limitation); the exact,
    /// general result is what `TransitionRenderer` produces for verification.
    public func schedule(outgoing: Scene, incoming: Scene) -> TransitionSchedule? {
        guard duration > 0 else { return nil }
        let ease = easing
        let dur = duration
        // B4: NO captured clock. The scene closures are pure functions of the
        // `elapsed` seconds the RenderLoop passes (it is the single transition
        // clock), so a prebuilt/deferred schedule can never desync. B9: the
        // eased progress is CLAMPED to 0…1 here — overshoot easings (backOut /
        // bounceOut) would otherwise make negative-width wipe rects / over-travel.
        // @Sendable: this is captured by the @Sendable schedule closures below;
        // unmarked it warns today and is a hard error under Swift 6.
        @Sendable func easedProgress(_ elapsed: Double) -> Double {
            min(max(ease.apply(min(max(elapsed / dur, 0), 1)), 0), 1)
        }
        // Raw (pre-easing) clamped phase — the FX shader's glitch split amount
        // and tileFlicker loop phase ride this, matching `TransitionRenderer`.
        @Sendable func rawProgress(_ elapsed: Double) -> Double {
            min(max(elapsed / dur, 0), 1)
        }
        switch kind {
        case .dissolve:
            return TransitionSchedule(duration: dur, blend: .crossfade,
                                      progress: { easedProgress($0) })

        case .push(let edge):
            let outBase = outgoing, incBase = incoming
            return TransitionSchedule(
                duration: dur, blend: .overlay,
                progress: { easedProgress($0) },
                outgoingScene: { elapsed in Self.translated(outBase, by: Self.exitOffset(edge, easedProgress(elapsed))) },
                incomingScene: { elapsed in Self.translated(incBase, by: Self.enterOffset(edge, easedProgress(elapsed))) })

        case .wipe(let edge):
            let outBase = outgoing, incBase = incoming
            return TransitionSchedule(
                duration: dur, blend: .overlay,
                progress: { easedProgress($0) },
                outgoingScene: { elapsed in Self.clippedToUnwiped(outBase, edge: edge, progress: easedProgress(elapsed)) },
                incomingScene: { _ in incBase })

        case .blockDissolve(let rows0, let cols0, let seed, let soft):
            // NATIVE now: the tile hole-punch runs in the compositor's FX shader
            // (render A, render B, per-tile reveal → premultiplied hole so B
            // shows through). Matches `TransitionRenderer`/`TileSchedule`; no
            // more crossfade fallback. (`TileMask` remains the per-LAYER live
            // home for revealing arbitrary layers beneath — a different use.)
            let (rows, cols) = TileSchedule.clampGrid(rows: rows0, cols: cols0)
            let fx = CompositorEffect(kind: .blockDissolve, rows: UInt32(rows), cols: UInt32(cols),
                                      seed: seed, softness: Float(soft))
            return TransitionSchedule(duration: dur, blend: .effect(fx),
                                      progress: { easedProgress($0) })

        case .gridWipe(let rows0, let cols0, let dir, let soft):
            let (rows, cols) = TileSchedule.clampGrid(rows: rows0, cols: cols0)
            let fx = CompositorEffect(kind: .gridWipe, rows: UInt32(rows), cols: UInt32(cols),
                                      softness: Float(soft), direction: Self.directionCode(dir))
            return TransitionSchedule(duration: dur, blend: .effect(fx),
                                      progress: { easedProgress($0) })

        case .checkerboard(let rows0, let cols0, let soft):
            let (rows, cols) = TileSchedule.clampGrid(rows: rows0, cols: cols0)
            let fx = CompositorEffect(kind: .checkerboard, rows: UInt32(rows), cols: UInt32(cols),
                                      softness: Float(soft))
            return TransitionSchedule(duration: dur, blend: .effect(fx),
                                      progress: { easedProgress($0) })

        case .tileReveal(let rows0, let cols0, let soft):
            let (rows, cols) = TileSchedule.clampGrid(rows: rows0, cols: cols0)
            let fx = CompositorEffect(kind: .tileReveal, rows: UInt32(rows), cols: UInt32(cols),
                                      softness: Float(soft))
            return TransitionSchedule(duration: dur, blend: .effect(fx),
                                      progress: { easedProgress($0) })

        case .tileFlicker(let rows0, let cols0, let seed, let soft):
            // CONTINUOUS blink: rides the RAW looping phase and never
            // short-circuits its endpoints (they are the same loop point).
            let (rows, cols) = TileSchedule.clampGrid(rows: rows0, cols: cols0)
            let fx = CompositorEffect(kind: .tileFlicker, rows: UInt32(rows), cols: UInt32(cols),
                                      seed: seed, softness: Float(soft), continuous: true)
            return TransitionSchedule(duration: dur, blend: .effect(fx),
                                      progress: { rawProgress($0) },
                                      rawProgress: { rawProgress($0) })

        case .iris, .zoomBlur, .glitch, .animeFlash, .speedline:
            // NATIVE now: each pixel-effect runs in the compositor's FX shader,
            // matching the CPU `TransitionRenderer` math. `glitch` needs the raw
            // phase for its channel-split amount (eased base, raw split).
            let fx: CompositorEffect
            switch kind {
            case .iris:       fx = CompositorEffect(kind: .iris)
            case .zoomBlur:   fx = CompositorEffect(kind: .zoomBlur)
            case .glitch:     fx = CompositorEffect(kind: .glitch)
            case .animeFlash: fx = CompositorEffect(kind: .animeFlash)
            default:          fx = CompositorEffect(kind: .speedline)  // .speedline
            }
            return TransitionSchedule(duration: dur, blend: .effect(fx),
                                      progress: { easedProgress($0) },
                                      rawProgress: { rawProgress($0) })
        }
    }

    /// `gridWipe` sweep direction → the shader's `direction` code.
    static func directionCode(_ d: FXDirection) -> UInt32 {
        switch d {
        case .left: return 0
        case .right: return 1
        case .up: return 2
        case .down: return 3
        }
    }

    // MARK: - Geometry (shared with the CPU renderer's math)

    /// Outgoing-scene offset (normalized) for a push at eased progress `p`.
    static func exitOffset(_ edge: FXDirection, _ p: Double) -> CGVector {
        switch edge {
        case .left:  return CGVector(dx: -p, dy: 0)
        case .right: return CGVector(dx: p, dy: 0)
        case .up:    return CGVector(dx: 0, dy: -p)
        case .down:  return CGVector(dx: 0, dy: p)
        }
    }
    /// Incoming-scene offset (normalized): starts fully off the opposite edge.
    static func enterOffset(_ edge: FXDirection, _ p: Double) -> CGVector {
        switch edge {
        case .left:  return CGVector(dx: 1 - p, dy: 0)
        case .right: return CGVector(dx: -(1 - p), dy: 0)
        case .up:    return CGVector(dx: 0, dy: 1 - p)
        case .down:  return CGVector(dx: 0, dy: -(1 - p))
        }
    }

    static func translated(_ scene: Scene, by v: CGVector) -> Scene {
        var s = scene
        s.layers = scene.layers.map { l in
            var nl = l
            nl.frame = l.frame.offsetBy(dx: v.dx, dy: v.dy)
            return nl
        }
        return s
    }

    /// Clip EVERY outgoing layer to the region not yet wiped, matching each
    /// layer's `frame` AND `crop` so content stays put and is cut exactly at the
    /// boundary (B5). B grows from `edge`; the un-wiped region is the complement.
    ///
    /// The old version only handled a full-canvas `(0,0,1,1)` layer and let
    /// every sub-frame layer (PiP / lower-third / cropped) pass through unwiped,
    /// so it showed through the whole transition. Here each layer's frame is
    /// intersected with the un-wiped region, and its crop is remapped to the
    /// same fractional sub-rect of the source (linear frame→crop map). A layer
    /// that falls entirely inside the wiped-away region is dropped.
    static func clippedToUnwiped(_ scene: Scene, edge: FXDirection, progress p: Double) -> Scene {
        let p = min(max(p, 0), 1)
        // Un-wiped region in normalized, top-left-origin canvas coordinates.
        let region: CGRect
        switch edge {
        case .left:  region = CGRect(x: p, y: 0, width: 1 - p, height: 1)
        case .right: region = CGRect(x: 0, y: 0, width: 1 - p, height: 1)
        case .up:    region = CGRect(x: 0, y: p, width: 1, height: 1 - p)
        case .down:  region = CGRect(x: 0, y: 0, width: 1, height: 1 - p)
        }
        var s = scene
        s.layers = scene.layers.compactMap { l -> Layer? in
            let f = l.frame
            let inter = f.intersection(region)
            // Entirely inside the wiped-away region → this layer must NOT show.
            guard !inter.isNull, inter.width > 0, inter.height > 0 else { return nil }
            var nl = l
            nl.frame = inter
            // Remap crop: the visible sub-rect of the frame maps to the same
            // fractional sub-rect of the source's crop (both top-left origin).
            if f.width > 0, f.height > 0 {
                let fx = (inter.minX - f.minX) / f.width
                let fy = (inter.minY - f.minY) / f.height
                let fw = inter.width / f.width
                let fh = inter.height / f.height
                let c = l.crop
                nl.crop = CGRect(x: c.minX + fx * c.width,
                                 y: c.minY + fy * c.height,
                                 width: fw * c.width,
                                 height: fh * c.height)
            }
            return nl
        }
        return s
    }
}
