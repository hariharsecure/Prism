import CoreGraphics
import CoreVideo
import Foundation

/// The tile / grid "square boxes" family as a LIVE per-LAYER effect (T1) — the
/// real home of the ongoing "blinking squares reveal what's underneath" look
/// Rishi saw. Where `TransitionRenderer` composites a holed A *over* a painted B
/// (a self-contained A→B transition), `TileMask` punches the animated grid of
/// transparent holes into ONE layer's frame and returns it, leaving the reveal
/// to the real compositor: the app feeds the holed frame to a layer with
/// `premultipliedAlpha: true`, so `MetalCompositor` shows the LAYERS BENEATH
/// through the holes — live, every render, over whatever is currently below
/// (not a baked A/B pair).
///
/// This is why the tile kinds "did nothing live": their `TransitionSchedule`
/// path returns no GPU schedule, so a scene-switch hard-cut them (now guarded —
/// see `TransitionSpec.schedule`), and the only pixels were produced by the
/// offline `TransitionRenderer`. `TileMask` is the missing live path.
///
/// Output contract: an IOSurface-backed BGRA buffer at the mask's canvas size
/// (the pipeline's zero-copy invariant), premultiplied-correct (a fully-revealed
/// cell is a TRUE alpha-0 hole, never opaque black). Reuses the verified
/// `punchTileHoles` alpha math and the neighbour-aware feather (`gridRemoval`).
///
/// Modes:
///  - `blockDissolve` / `gridWipe` / `checkerboard` / `tileReveal` are ONE-SHOT:
///    `phase` is progress 0→1 (0 = fully opaque top, 1 = fully revealed).
///  - `tileFlicker` is a CONTINUOUS blink: pass a LOOPING `phase` (0→1→0…); each
///    tile toggles on AND off on a seeded offset (it never settles to all-on).
public enum TileMaskMode: Sendable, Equatable {
    /// Tiles turn transparent in a seeded RANDOM order as `phase` 0→1.
    case blockDissolve(seed: UInt64)
    /// Tiles reveal in a directional sweep as `phase` 0→1.
    case gridWipe(direction: FXDirection)
    /// Alternating-parity tiles reveal first, then the rest, as `phase` 0→1.
    case checkerboard
    /// Every tile reveals via a centred box growing from nothing over `phase`.
    case tileReveal
    /// CONTINUOUS blink on a looping `phase` (tiles toggle on and off).
    case tileFlicker(seed: UInt64)

    /// Stable label for logs / filenames.
    public var label: String {
        switch self {
        case .blockDissolve(let s): return "blockdissolve_s\(s)"
        case .gridWipe(let d):      return "gridwipe_\(d.rawValue)"
        case .checkerboard:         return "checkerboard"
        case .tileReveal:           return "tilereveal"
        case .tileFlicker(let s):   return "tileflicker_s\(s)"
        }
    }
}

/// Applies a `TileMaskMode` to a single layer's frame (see `TileMaskMode`).
public final class TileMask {
    private let canvas: FXCanvas
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) throws {
        self.canvas = try FXCanvas(width: width, height: height)
        self.width = width
        self.height = height
    }

    /// Punch the animated grid of holes into `frame` and return the holed
    /// IOSurface BGRA frame. Feed the result to a `Layer` with
    /// `premultipliedAlpha: true` so the compositor reveals the layers beneath.
    ///
    /// - Parameters:
    ///   - frame: the layer's current BGRA IOSurface frame (opaque or with its
    ///     own alpha — holes are punched on top of whatever alpha it has).
    ///   - rows/cols: grid size (clamped safe — T2).
    ///   - mode: which reveal pattern.
    ///   - phase: one-shot progress 0→1, or a looping phase for `tileFlicker`.
    ///   - softness: hole-edge feather, clamped 0…1 (T4).
    public func apply(to frame: CVPixelBuffer, rows: Int, cols: Int,
                      mode: TileMaskMode, phase: Double, softness: Double) throws -> CVPixelBuffer {
        let (rows, cols) = TileSchedule.clampGrid(rows: rows, cols: cols)
        let src = try FXCanvas.cgImage(from: frame)
        let holed: CGImage
        switch mode {
        case .tileReveal:
            // Centred grow box (same math as TransitionRenderer.tileGrowComposite).
            let f = min(max(phase, 0), 1)
            let s = min(max(softness, 0), 1)
            holed = try punchTileHoles(source: src, width: width, height: height,
                                       rows: rows, cols: cols) { _, _, localX, localY, tileW, tileH in
                let halfW = 0.5 * tileW * f, halfH = 0.5 * tileH * f
                let dx = abs(localX - tileW / 2), dy = abs(localY - tileH / 2)
                let m = max(0.75, s * 0.5 * min(tileW, tileH))
                let insideX = 1 - fxSmoothstep(halfW - m, halfW + m, dx)
                let insideY = 1 - fxSmoothstep(halfH - m, halfH + m, dy)
                return insideX * insideY
            }
        default:
            let reveal = Self.revealGrid(mode: mode, rows: rows, cols: cols, phase: phase)
            let removal = TileSchedule.gridRemoval(reveal: reveal, rows: rows, cols: cols, softness: softness)
            holed = try punchTileHoles(source: src, width: width, height: height,
                                       rows: rows, cols: cols, removal: removal)
        }
        // Draw the holed premultiplied image into a cleared IOSurface BGRA buffer
        // (transparency preserved) → a zero-copy frame the compositor can reveal
        // beneath.
        return try canvas.render { ctx in ctx.draw(holed, in: canvas.rect) }
    }

    /// The per-tile reveal grid for the non-grow modes. One-shot phases are
    /// clamped 0…1; `tileFlicker` keeps its raw looping phase.
    private static func revealGrid(mode: TileMaskMode, rows: Int, cols: Int, phase: Double) -> [Double] {
        let p = min(max(phase, 0), 1)
        switch mode {
        case .blockDissolve(let seed): return TileSchedule.blockDissolve(rows: rows, cols: cols, seed: seed, phase: p)
        case .gridWipe(let dir):       return TileSchedule.gridWipe(rows: rows, cols: cols, direction: dir, phase: p)
        case .checkerboard:            return TileSchedule.checkerboard(rows: rows, cols: cols, phase: p)
        case .tileFlicker(let seed):   return TileSchedule.flicker(rows: rows, cols: cols, seed: seed, phase: phase)
        case .tileReveal:              return []   // handled by the grow path above
        }
    }
}
