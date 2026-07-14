import CoreGraphics
import CoreVideo
import Foundation

/// Tile / grid effect math (DESIGN.md Build A + C — the "square boxes" family
/// Rishi saw: a top layer whose squares blink / disappear to reveal the layer
/// beneath). This file is the deterministic *schedule* engine (which tiles are
/// revealed at a given progress/phase) plus the standalone `TileRepeatRenderer`
/// (Build C — one source drawn into an N×M grid / kaleidoscope).
///
/// The pixel raster for the transition kinds (`blockDissolve`, `gridWipe`,
/// `checkerboard`, `tileReveal`, `tileFlicker`) lives in `TransitionRenderer`,
/// which asks `TileSchedule` for a per-tile reveal grid and punches genuinely
/// transparent holes into the top layer (premultiplied-correct) so the bottom
/// shows through — never opaque black (this codebase's recurring bug).

/// Smoothstep (Hermite) — 0 below `edge0`, 1 above `edge1`, S-curve between.
/// Used for per-tile temporal ramps and per-pixel edge softness.
@inline(__always)
func fxSmoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    if edge1 <= edge0 { return x < edge0 ? 0 : 1 }
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}

/// Deterministic per-tile reveal schedules. Every schedule is a pure function of
/// `(rows, cols, params, phase)` — NO `Date`, NO `Math.random`; block-dissolve /
/// flicker randomness is derived by hashing `seed` with the tile index, so a
/// fixed seed reproduces byte-identical frames and different seeds differ.
///
/// A returned grid is row-major, length `rows*cols`, each entry the tile's
/// **reveal amount** `∈ 0…1` — `0` = top opaque (shows A), `1` = fully revealed
/// (top alpha 0, shows B). Row 0 is the visual TOP (memory row 0).
public enum TileSchedule {

    /// Max cells (rows·cols) any tile schedule / composite will allocate or
    /// iterate. A defensible cap so a pathological `rows`/`cols` (a fat-fingered
    /// value, a corrupt scene, an overflow attempt) can't request an unbounded
    /// allocation (T2). Chosen well above any sane on-screen grid.
    public static let maxCells = 500_000
    /// Per-dimension clamp (a single dimension never exceeds this).
    public static let maxDim = 4096

    /// Clamp a requested grid to a SAFE, non-degenerate size (T2): at least 1×1
    /// (0 / negative would divide-by-zero or trap `[Double](repeating:count:)`),
    /// each dimension ≤ `maxDim`, and the total cell count ≤ `maxCells` (scaled
    /// down preserving aspect if a huge grid is requested). Idempotent: clamping
    /// an already-clamped grid is a no-op, so callers can clamp once and pass the
    /// result to every downstream tile function safely.
    @inline(__always)
    public static func clampGrid(rows: Int, cols: Int) -> (rows: Int, cols: Int) {
        var r = min(max(rows, 1), maxDim)
        var c = min(max(cols, 1), maxDim)
        if r * c > maxCells {
            let scale = (Double(maxCells) / Double(r * c)).squareRoot()
            r = min(max(Int(Double(r) * scale), 1), maxDim)
            c = min(max(Int(Double(c) * scale), 1), maxDim)
        }
        return (r, c)
    }

    /// SplitMix64 — a good, cheap, fully deterministic integer hash (no RNG state).
    @inline(__always)
    static func mix64(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Deterministic tile value in `[0,1)` from `seed` + tile index.
    @inline(__always)
    static func tileUnit(seed: UInt64, row: Int, col: Int) -> Double {
        let idx = (UInt64(bitPattern: Int64(row)) &* 0x0000_0100_0000_01B3)
            ^ (UInt64(bitPattern: Int64(col)) &* 0x0000_0000_9E37_79B1)
        let h = mix64(seed &+ mix64(idx))
        // Top 53 bits → uniform double in [0,1).
        return Double(h >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// **Block Dissolve** — tiles turn transparent in a seeded RANDOM order as
    /// `phase 0→1`. Each tile gets a threshold in `[0, 1-window]` from its hash;
    /// it ramps A→B over `window`. At phase 0 all A, at phase 1 all B.
    public static func blockDissolve(rows: Int, cols: Int, seed: UInt64,
                                     phase: Double, window: Double = 0.22) -> [Double] {
        let (rows, cols) = clampGrid(rows: rows, cols: cols)   // T2: no 0/neg/huge
        var g = [Double](repeating: 0, count: rows * cols)
        for r in 0..<rows {
            for c in 0..<cols {
                let thr = tileUnit(seed: seed, row: r, col: c) * (1 - window)
                g[r * cols + c] = fxSmoothstep(thr, thr + window, phase)
            }
        }
        return g
    }

    /// **Grid Wipe** — tiles reveal in a sequential / directional sweep along
    /// `direction`; a soft front of width `window` moves across the grid.
    public static func gridWipe(rows: Int, cols: Int, direction: FXDirection,
                                phase: Double, window: Double = 0.22) -> [Double] {
        let (rows, cols) = clampGrid(rows: rows, cols: cols)   // T2: no 0/neg/huge
        var g = [Double](repeating: 0, count: rows * cols)
        for r in 0..<rows {
            for c in 0..<cols {
                let fx = (Double(c) + 0.5) / Double(cols)
                let fy = (Double(r) + 0.5) / Double(rows)   // fy 0 = top
                let pos: Double
                switch direction {
                case .right: pos = fx
                case .left:  pos = 1 - fx
                case .down:  pos = fy
                case .up:    pos = 1 - fy
                }
                let thr = pos * (1 - window)
                g[r * cols + c] = fxSmoothstep(thr, thr + window, phase)
            }
        }
        return g
    }

    /// **Checkerboard / Checker Wipe** — even-parity tiles reveal in the first
    /// half of `phase`, odd-parity in the second. At phase 0.5 the grid is a
    /// clean checkerboard (even = B, odd = A).
    public static func checkerboard(rows: Int, cols: Int, phase: Double) -> [Double] {
        let (rows, cols) = clampGrid(rows: rows, cols: cols)   // T2: no 0/neg/huge
        var g = [Double](repeating: 0, count: rows * cols)
        for r in 0..<rows {
            for c in 0..<cols {
                let even = (r + c) % 2 == 0
                g[r * cols + c] = even ? fxSmoothstep(0, 0.5, phase)
                                       : fxSmoothstep(0.5, 1, phase)
            }
        }
        return g
    }

    /// **Tile Flicker** — CONTINUOUS blink: each tile follows a looping cosine
    /// wave with a seeded phase offset, so tiles toggle ON *and* OFF over the
    /// loop (not a one-way transition). `phase` loops `0→1`. Returns per-tile
    /// reveal `0.5 - 0.5·cos(2π·frac(phase+offset))` → 0 (A) then 1 (B) then 0.
    public static func flicker(rows: Int, cols: Int, seed: UInt64, phase: Double) -> [Double] {
        let (rows, cols) = clampGrid(rows: rows, cols: cols)   // T2: no 0/neg/huge
        var g = [Double](repeating: 0, count: rows * cols)
        let p = phase - floor(phase)
        for r in 0..<rows {
            for c in 0..<cols {
                let off = tileUnit(seed: seed, row: r, col: c)
                let x = (p + off).truncatingRemainder(dividingBy: 1)
                g[r * cols + c] = 0.5 - 0.5 * cos(2 * Double.pi * x)
            }
        }
        return g
    }

    /// Build the per-pixel **removal** closure for a `reveal` grid with
    /// NEIGHBOUR-AWARE edge feathering (T4). A tile removes `reveal[idx]` of the
    /// top's alpha; when `softness > 0` the removal feathers toward a tile edge
    /// **only if the neighbour across that edge is LESS revealed** — so two
    /// adjacent fully-revealed tiles share an un-feathered border and there is no
    /// top-coloured seam between them (the old per-tile feather left one). Edges
    /// on the canvas border are treated as equal (never feathered → no rim).
    /// `softness` is clamped 0…1. `reveal`/`rows`/`cols` MUST already be a matched
    /// clamped grid (call `clampGrid` first).
    static func gridRemoval(reveal: [Double], rows: Int, cols: Int, softness: Double)
        -> (_ row: Int, _ col: Int, _ localX: Double, _ localY: Double, _ tileW: Double, _ tileH: Double) -> Double {
        let s = min(max(softness, 0), 1)
        return { r, c, localX, localY, tileW, tileH in
            let idx = r * cols + c
            guard idx >= 0, idx < reveal.count else { return 0 }
            let rev = reveal[idx]
            if rev <= 0 { return 0 }
            guard s > 0 else { return rev }
            let margin = s * 0.5 * min(tileW, tileH)
            guard margin > 0 else { return rev }
            // Out-of-grid neighbours = `rev` (equal) so the canvas edge never feathers.
            let left  = c > 0        ? reveal[r * cols + (c - 1)] : rev
            let right = c < cols - 1 ? reveal[r * cols + (c + 1)] : rev
            let up    = r > 0        ? reveal[(r - 1) * cols + c] : rev
            let down  = r < rows - 1 ? reveal[(r + 1) * cols + c] : rev
            var feather = 1.0
            if left  < rev { feather = min(feather, fxSmoothstep(0, margin, localX)) }
            if right < rev { feather = min(feather, fxSmoothstep(0, margin, tileW - localX)) }
            if up    < rev { feather = min(feather, fxSmoothstep(0, margin, localY)) }
            if down  < rev { feather = min(feather, fxSmoothstep(0, margin, tileH - localY)) }
            return rev * feather
        }
    }
}

/// Punch genuinely-transparent per-tile holes into `source` and return a
/// premultiplied-first BGRA `CGImage` with REAL transparency (never opaque
/// black — this codebase's recurring bug). Shared by `TransitionRenderer`
/// (composite-over-B) and `TileMask` (single-layer holes the compositor reveals
/// through).
///
/// `source` is drawn opaque into a premultiplied-first scratch bitmap, then every
/// pixel's four premultiplied bytes are scaled by `1 - removal(...)` (removal ∈
/// 0…1). Scaling all four bytes by the same factor preserves the premultiplied
/// invariant, so a removal of 1 yields a true alpha-0 hole. Pixel-local
/// coordinates are taken at PIXEL CENTRES (`x+0.5`, `y+0.5`) so feathering is
/// symmetric and seam-free (T4). `rows`/`cols` are clamped (T2).
func punchTileHoles(source: CGImage, width: Int, height: Int, rows: Int, cols: Int,
                    removal: (_ row: Int, _ col: Int, _ localX: Double, _ localY: Double,
                              _ tileW: Double, _ tileH: Double) -> Double) throws -> CGImage {
    let (rows, cols) = TileSchedule.clampGrid(rows: rows, cols: cols)
    let w = width, h = height
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs, bitmapInfo: info) else {
        throw VisualFXError.contextCreationFailed
    }
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))   // opaque source
    guard let base = ctx.data else { throw VisualFXError.contextCreationFailed }
    let ptr = base.assumingMemoryBound(to: UInt8.self)
    let bpr = ctx.bytesPerRow
    let tileW = Double(w) / Double(cols), tileH = Double(h) / Double(rows)
    for y in 0..<h {                       // memory row 0 = visual top
        let cy = Double(y) + 0.5           // pixel CENTRE (T4)
        let row = min(Int(cy / tileH), rows - 1)
        let localY = cy - Double(row) * tileH
        let rowPtr = ptr + y * bpr
        for x in 0..<w {
            let cx = Double(x) + 0.5
            let col = min(Int(cx / tileW), cols - 1)
            let localX = cx - Double(col) * tileW
            let rem = removal(row, col, localX, localY, tileW, tileH)
            if rem <= 0 { continue }
            let f = 1 - min(max(rem, 0), 1)
            let p = rowPtr + x * 4
            p[0] = UInt8(Double(p[0]) * f)   // B (premultiplied)
            p[1] = UInt8(Double(p[1]) * f)   // G
            p[2] = UInt8(Double(p[2]) * f)   // R
            p[3] = UInt8(Double(p[3]) * f)   // A
        }
    }
    guard let image = ctx.makeImage() else { throw VisualFXError.imageCreationFailed }
    return image
}

/// **Build C — Tile-repeat / video wall / kaleidoscope.** Draws ONE source into
/// an `rows × cols` grid of cells; with `mirror` the odd-parity cells are
/// flipped (H on odd columns, V on odd rows) for a kaleidoscope. A standalone
/// CPU raster (same `FXCanvas` backend as `TransitionRenderer`); the result is a
/// normal opaque frame that enters the zero-copy compositor identically.
public final class TileRepeatRenderer {
    private let canvas: FXCanvas
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) throws {
        self.canvas = try FXCanvas(width: width, height: height)
        self.width = width
        self.height = height
    }

    /// Render `source` repeated into a `rows × cols` grid. `mirror` mirrors
    /// odd-parity cells for a kaleidoscope look.
    public func render(source: CVPixelBuffer, rows: Int, cols: Int, mirror: Bool) throws -> CVPixelBuffer {
        let rows = max(1, rows), cols = max(1, cols)
        let img = try FXCanvas.cgImage(from: source)
        let cellW = CGFloat(width) / CGFloat(cols)
        let cellH = CGFloat(height) / CGFloat(rows)
        return try canvas.render { ctx in
            for r in 0..<rows {
                for c in 0..<cols {
                    // Context is bottom-left origin; row 0 is the visual TOP.
                    let x = CGFloat(c) * cellW
                    let yBL = CGFloat(height) - CGFloat(r + 1) * cellH
                    let rect = CGRect(x: x, y: yBL, width: cellW, height: cellH)
                    ctx.saveGState()
                    if mirror {
                        let sx: CGFloat = (c % 2 == 1) ? -1 : 1
                        let sy: CGFloat = (r % 2 == 1) ? -1 : 1
                        ctx.translateBy(x: rect.midX, y: rect.midY)
                        ctx.scaleBy(x: sx, y: sy)
                        ctx.translateBy(x: -rect.midX, y: -rect.midY)
                    }
                    ctx.draw(img, in: rect)
                    ctx.restoreGState()
                }
            }
        }
    }
}
