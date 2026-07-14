import CoreGraphics
import CoreVideo
import XCTest

import PrismCompositor
import PrismCore

/// Verification for the tile / grid "square boxes" effect family (DESIGN.md
/// Build A + C): `blockDissolve`, `gridWipe`, `checkerboard`, `tileReveal`,
/// `tileFlicker`, and the standalone `TileRepeatRenderer`.
///
/// Two VISUALLY DISTINCT sources are used so a revealed tile is unmistakable:
///   - top A = a SOLID ORANGE fill,
///   - bottom B = a 4-QUADRANT pattern (cyan / green / magenta / blue).
/// A tile that reveals the bottom reads far from orange and matches B there —
/// proving the hole is genuinely transparent (premultipliedAlpha), NOT black.
///
/// PNG dumps (5 frames per kind across progress/phase) go to:
///   /tmp/prism_tilefx/
final class TileEffectsTests: XCTestCase {

    private static let outputDir = URL(fileURLWithPath:
        "/tmp/prism_tilefx")

    private let W = 480, H = 270
    private let rows = 6, cols = 8

    // A distinct orange top and a 4-quadrant bottom.
    private let orange = RGBA(r: 0.95, g: 0.55, b: 0.10)

    private func makeA(_ canvas: FXCanvas) throws -> CVPixelBuffer { try canvas.solid(orange) }

    /// 4-quadrant bottom (memory/top-left origin labels):
    /// TL cyan, TR green, BL magenta, BR blue. All far from orange.
    private func makeB(_ canvas: FXCanvas) throws -> CVPixelBuffer {
        let w = CGFloat(W), h = CGFloat(H)
        return try canvas.render { ctx in
            // Context is bottom-left origin; memory-top == high y.
            ctx.setFillColor(RGBA(r: 0, g: 1, b: 1).cg); ctx.fill(CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))       // TL cyan
            ctx.setFillColor(RGBA(r: 0, g: 1, b: 0).cg); ctx.fill(CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2))   // TR green
            ctx.setFillColor(RGBA(r: 1, g: 0, b: 1).cg); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h / 2))           // BL magenta
            ctx.setFillColor(RGBA(r: 0, g: 0, b: 1).cg); ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2))       // BR blue
        }
    }

    // MARK: - helpers

    private func dist(_ p: RGBA, _ q: RGBA) -> Double {
        (abs(p.r - q.r) + abs(p.g - q.g) + abs(p.b - q.b)) / 3
    }

    /// Sample the center pixel of tile (r,c).
    private func tileCenter(_ frame: CVPixelBuffer, _ r: Int, _ c: Int) -> RGBA {
        let x = Int((Double(c) + 0.5) * Double(W) / Double(cols))
        let y = Int((Double(r) + 0.5) * Double(H) / Double(rows))
        return FXCanvas.pixel(frame, x: min(x, W - 1), y: min(y, H - 1))
    }

    /// A tile is "revealed" (shows B) when its center is far from orange A.
    private func revealedGrid(_ frame: CVPixelBuffer) -> [Bool] {
        var out = [Bool](repeating: false, count: rows * cols)
        for r in 0..<rows { for c in 0..<cols {
            out[r * cols + c] = dist(tileCenter(frame, r, c), orange) > 0.25
        } }
        return out
    }

    private func revealedCount(_ frame: CVPixelBuffer) -> Int { revealedGrid(frame).filter { $0 }.count }

    /// Sample near each tile's top-left corner (10% in) and count how many are
    /// revealed — used for `tileReveal`, whose reveal grows from the tile CENTER,
    /// so at mid the centers show B while the corners still show A.
    private func cornerRevealedCount(_ frame: CVPixelBuffer) -> Int {
        var n = 0
        let tw = Double(W) / Double(cols), th = Double(H) / Double(rows)
        for r in 0..<rows { for c in 0..<cols {
            let x = Int((Double(c) + 0.1) * tw), y = Int((Double(r) + 0.1) * th)
            if dist(FXCanvas.pixel(frame, x: min(x, W - 1), y: min(y, H - 1)), orange) > 0.25 { n += 1 }
        } }
        return n
    }

    private func dump(_ frame: CVPixelBuffer, _ name: String) throws {
        try FXCanvas.writePNG(frame, to: Self.outputDir.appendingPathComponent(name))
    }

    // MARK: - 1. Reveal transitions (blockDissolve / gridWipe / checkerboard / tileReveal)

    /// Endpoints exact, midpoint a genuine mix, PNG dumps. Linear easing so
    /// `progress == schedule phase`.
    func testRevealTransitionsEndpointsMidMixAndDump() throws {
        let canvas = try FXCanvas(width: W, height: H)
        let a = try makeA(canvas), b = try makeB(canvas)
        let renderer = try TransitionRenderer(width: W, height: H)
        let stops = [0.0, 0.25, 0.5, 0.75, 1.0]

        let kinds: [(String, TransitionKind)] = [
            ("blockdissolve", .blockDissolve(rows: rows, cols: cols, seed: 7, softness: 0.15)),
            ("gridwipe", .gridWipe(rows: rows, cols: cols, direction: .right, softness: 0.15)),
            ("checkerboard", .checkerboard(rows: rows, cols: cols, softness: 0.12)),
            ("tilereveal", .tileReveal(rows: rows, cols: cols, softness: 0.20)),
        ]
        let total = rows * cols
        for (name, kind) in kinds {
            let spec = TransitionSpec(kind: kind, duration: 0.5, easing: .linear)
            var frames: [CVPixelBuffer] = []
            for (i, p) in stops.enumerated() {
                let f = try renderer.render(a: a, b: b, spec: spec, progress: p)
                frames.append(f)
                try dump(f, "t_\(name)_\(i)_p\(Int(p * 100)).png")
            }
            // Endpoints: p0 ≈ A (all top), p1 ≈ B (all revealed).
            XCTAssertLessThan(FXCanvas.meanDiff(frames[0], a), 0.02, "\(name): p0 ≠ A")
            XCTAssertLessThan(FXCanvas.meanDiff(frames[4], b), 0.02, "\(name): p1 ≠ B")
            XCTAssertEqual(revealedCount(frames[0]), 0, "\(name): p0 should reveal 0 tiles")
            XCTAssertEqual(revealedCount(frames[4]), total, "\(name): p1 should reveal all tiles")
            // Midpoint: a GENUINE mix (differs from both endpoints).
            XCTAssertGreaterThan(FXCanvas.meanDiff(frames[2], a), 0.03, "\(name): mid ≈ A")
            XCTAssertGreaterThan(FXCanvas.meanDiff(frames[2], b), 0.03, "\(name): mid ≈ B")
            if name == "tilereveal" {
                // Grows from each tile's CENTER: at mid centers show B, corners A.
                XCTAssertEqual(revealedCount(frames[2]), total, "\(name): mid tile centers should show B")
                XCTAssertLessThan(cornerRevealedCount(frames[2]), total, "\(name): mid tile corners should still show A")
            } else {
                // Per-tile reveal: at mid some tiles show A, some B (count between).
                let mid = revealedCount(frames[2])
                XCTAssertGreaterThan(mid, 0, "\(name): mid revealed nothing")
                XCTAssertLessThan(mid, total, "\(name): mid revealed everything")
            }
        }
    }

    // MARK: - 2. Holes are genuinely transparent — revealed tiles show B, not black

    func testRevealedTilesShowBottomNotBlack() throws {
        let canvas = try FXCanvas(width: W, height: H)
        let a = try makeA(canvas), b = try makeB(canvas)
        let renderer = try TransitionRenderer(width: W, height: H)
        // gridWipe.right at p=0.9 → the left/most columns are fully revealed.
        let spec = TransitionSpec(kind: .gridWipe(rows: rows, cols: cols, direction: .right, softness: 0),
                                  duration: 0.5, easing: .linear)
        let f = try renderer.render(a: a, b: b, spec: spec, progress: 0.9)
        try dump(f, "t_transparency_gridwipe_p90.png")

        var checkedRevealed = 0
        for r in 0..<rows { for c in 0..<cols {
            let px = tileCenter(f, r, c)
            if dist(px, orange) > 0.25 {           // this tile revealed the bottom
                checkedRevealed += 1
                let bpx = tileCenter(b, r, c)      // B's color at the same tile
                XCTAssertLessThan(dist(px, bpx), 0.12,
                    "revealed tile (\(r),\(c)) does not match bottom B (got \(px))")
                XCTAssertGreaterThan(max(px.r, max(px.g, px.b)), 0.3,
                    "revealed tile (\(r),\(c)) is opaque BLACK — premultiplied hole bug (got \(px))")
            }
        } }
        XCTAssertGreaterThan(checkedRevealed, 4, "expected several revealed tiles to check")
    }

    // MARK: - 3. Checkerboard parity is exact at the midpoint

    func testCheckerboardParityAtMidpoint() throws {
        let canvas = try FXCanvas(width: W, height: H)
        let a = try makeA(canvas), b = try makeB(canvas)
        let renderer = try TransitionRenderer(width: W, height: H)
        let spec = TransitionSpec(kind: .checkerboard(rows: rows, cols: cols, softness: 0),
                                  duration: 0.5, easing: .linear)
        let f = try renderer.render(a: a, b: b, spec: spec, progress: 0.5)
        try dump(f, "t_checkerboard_parity_mid.png")
        let grid = revealedGrid(f)
        for r in 0..<rows { for c in 0..<cols {
            let evenParity = (r + c) % 2 == 0
            XCTAssertEqual(grid[r * cols + c], evenParity,
                "checkerboard parity wrong at (\(r),\(c)): revealed=\(grid[r * cols + c]) expected even=\(evenParity)")
        } }
    }

    // MARK: - 4. blockDissolve is deterministic per seed and differs across seeds

    func testBlockDissolveDeterminismAndSeedVariation() throws {
        let canvas = try FXCanvas(width: W, height: H)
        let a = try makeA(canvas), b = try makeB(canvas)
        let renderer = try TransitionRenderer(width: W, height: H)

        func mid(_ seed: UInt64) throws -> CVPixelBuffer {
            let spec = TransitionSpec(kind: .blockDissolve(rows: rows, cols: cols, seed: seed, softness: 0.1),
                                      duration: 0.5, easing: .linear)
            return try renderer.render(a: a, b: b, spec: spec, progress: 0.5)
        }
        let s7a = try mid(7), s7b = try mid(7), s42 = try mid(42)
        // Same seed → byte-identical frame.
        XCTAssertLessThan(FXCanvas.meanDiff(s7a, s7b), 0.001, "same seed produced different frames")
        // Different seed → a different reveal pattern.
        XCTAssertGreaterThan(FXCanvas.meanDiff(s7a, s42), 0.03, "different seeds produced ~identical frames")
        XCTAssertNotEqual(revealedGrid(s7a), revealedGrid(s42), "different seeds revealed the same tile set")
        try dump(s7a, "t_blockdissolve_seed7_mid.png")
        try dump(s42, "t_blockdissolve_seed42_mid.png")
    }

    // MARK: - 5. tileFlicker toggles ON and OFF across its phase (non-monotonic)

    func testTileFlickerTogglesAndDump() throws {
        let canvas = try FXCanvas(width: W, height: H)
        let a = try makeA(canvas), b = try makeB(canvas)
        let renderer = try TransitionRenderer(width: W, height: H)
        let spec = TransitionSpec(kind: .tileFlicker(rows: rows, cols: cols, seed: 3, softness: 0.1),
                                  duration: 1.0, easing: .linear)

        // (a) Direct schedule check on one tile across a full loop: it must go
        // both fully ON and fully OFF, and NOT be monotonic.
        var seq: [Double] = []
        let steps = 24
        for i in 0...steps {
            let phase = Double(i) / Double(steps)
            let g = TileSchedule.flicker(rows: rows, cols: cols, seed: 3, phase: phase)
            seq.append(g[0])   // tile (0,0)
        }
        XCTAssertGreaterThan(seq.max() ?? 0, 0.9, "flicker tile never turned fully ON")
        XCTAssertLessThan(seq.min() ?? 1, 0.1, "flicker tile never turned fully OFF")
        // Non-monotonic: contains both an increase and a later decrease.
        let hasUp = zip(seq, seq.dropFirst()).contains { $1 > $0 + 1e-6 }
        let hasDown = zip(seq, seq.dropFirst()).contains { $1 < $0 - 1e-6 }
        XCTAssertTrue(hasUp && hasDown, "flicker is monotonic (should blink on AND off): \(seq)")

        // (b) On rendered frames: at some phase the frame is a mix (some tiles B,
        // some A), proving the blink is spatial; dump 5 frames.
        var sawMix = false
        let phases = [0.0, 0.2, 0.4, 0.6, 0.8]
        for (i, p) in phases.enumerated() {
            let f = try renderer.render(a: a, b: b, spec: spec, progress: p)
            try dump(f, "t_tileflicker_\(i)_ph\(Int(p * 100)).png")
            let rc = revealedCount(f)
            if rc > 0 && rc < rows * cols { sawMix = true }
        }
        XCTAssertTrue(sawMix, "flicker never showed a spatial mix of on/off tiles")
    }

    // MARK: - 6. TileRepeat (Build C) — grid repeat + kaleidoscope mirror

    func testTileRepeatGridAndMirrorDump() throws {
        let canvas = try FXCanvas(width: W, height: H)
        // An asymmetric 4-corner source so H/V flips are detectable.
        let w = CGFloat(W), h = CGFloat(H)
        let src = try canvas.render { ctx in
            ctx.setFillColor(RGBA(r: 1, g: 0, b: 0).cg); ctx.fill(CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))     // TL red
            ctx.setFillColor(RGBA(r: 0, g: 1, b: 0).cg); ctx.fill(CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2)) // TR green
            ctx.setFillColor(RGBA(r: 0, g: 0, b: 1).cg); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h / 2))         // BL blue
            ctx.setFillColor(RGBA(r: 1, g: 1, b: 0).cg); ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2))     // BR yellow
        }
        let tr = try TileRepeatRenderer(width: W, height: H)
        let gr = 3, gc = 3

        // No mirror: every cell shows the source unflipped → the same relative
        // position in each cell has the same color.
        let plain = try tr.render(source: src, rows: gr, cols: gc, mirror: false)
        try dump(plain, "tilerepeat_3x3_plain.png")
        func cellTopLeft(_ f: CVPixelBuffer, _ r: Int, _ c: Int) -> RGBA {
            let cellW = W / gc, cellH = H / gr
            return FXCanvas.pixel(f, x: c * cellW + cellW / 4, y: r * cellH + cellH / 4)
        }
        let ref = cellTopLeft(plain, 0, 0)   // source TL region = red
        XCTAssertLessThan(dist(ref, RGBA(r: 1, g: 0, b: 0)), 0.15, "plain cell(0,0) top-left not red source")
        for r in 0..<gr { for c in 0..<gc {
            XCTAssertLessThan(dist(cellTopLeft(plain, r, c), ref), 0.15,
                "plain tileRepeat cell (\(r),\(c)) does not match the source (no flip expected)")
        } }

        // Mirror: odd columns flip horizontally → cell(0,1) top-left samples the
        // source's TOP-RIGHT (green), differing from cell(0,0) (red).
        let mir = try tr.render(source: src, rows: gr, cols: gc, mirror: true)
        try dump(mir, "tilerepeat_3x3_mirror.png")
        let c00 = cellTopLeft(mir, 0, 0)   // even col, no H flip → red
        let c01 = cellTopLeft(mir, 0, 1)   // odd col, H flip → source top-right green
        XCTAssertLessThan(dist(c00, RGBA(r: 1, g: 0, b: 0)), 0.15, "mirror cell(0,0) not red")
        XCTAssertLessThan(dist(c01, RGBA(r: 0, g: 1, b: 0)), 0.15, "mirror cell(0,1) not H-flipped (green expected)")
        XCTAssertGreaterThan(dist(c00, c01), 0.3, "mirror did not flip odd columns")

        // T6: assert the VERTICAL flip on odd ROWS too — cell(1,0) is odd row, even
        // col → V flip → its top-left samples the source's BOTTOM-left (blue).
        let c10 = cellTopLeft(mir, 1, 0)
        XCTAssertLessThan(dist(c10, RGBA(r: 0, g: 0, b: 1)), 0.15, "mirror cell(1,0) not V-flipped (blue expected)")
        XCTAssertGreaterThan(dist(c00, c10), 0.3, "mirror did not flip odd rows")
    }

    // MARK: - 7. T2: bad grid sizes never crash (clamped/bounded)

    /// rows/cols of 0, negative, or huge must NOT trap or crash — every tile kind
    /// and the schedule engine clamp to a safe bounded grid. Pre-fix: rows:0 → an
    /// out-of-bounds `reveal[]` read; negative → `[Double](repeating:count:)` trap;
    /// huge → an unbounded alloc.
    func testTileGridInvalidSizesNoCrash() throws {
        let canvas = try FXCanvas(width: W, height: H)
        let a = try makeA(canvas), b = try makeB(canvas)
        let renderer = try TransitionRenderer(width: W, height: H)
        let bad: [(Int, Int)] = [(0, 0), (0, 8), (6, 0), (-1, -1), (-5, 3), (100_000, 100_000), (1, 200_000), (6, 8)]
        for (r, c) in bad {
            let kinds: [TransitionKind] = [
                .blockDissolve(rows: r, cols: c, seed: 1, softness: 0.2),
                .gridWipe(rows: r, cols: c, direction: .right, softness: 0.2),
                .checkerboard(rows: r, cols: c, softness: 0.2),
                .tileReveal(rows: r, cols: c, softness: 0.2),
                .tileFlicker(rows: r, cols: c, seed: 1, softness: 0.2),
            ]
            for kind in kinds {
                let spec = TransitionSpec(kind: kind, duration: 0.5, easing: .linear)
                for p in [0.0, 0.5, 1.0] {
                    _ = try renderer.render(a: a, b: b, spec: spec, progress: p)  // must not crash
                }
            }
        }
        // The schedule engine directly (the array-alloc / OOB path).
        _ = TileSchedule.blockDissolve(rows: 0, cols: 0, seed: 1, phase: 0.5)
        _ = TileSchedule.gridWipe(rows: -3, cols: 4, direction: .up, phase: 0.5)
        _ = TileSchedule.checkerboard(rows: 0, cols: -2, phase: 0.5)
        _ = TileSchedule.flicker(rows: -1, cols: 0, seed: 2, phase: 0.3)
        // clampGrid contract: always ≥1×1 and bounded.
        for (r, c) in bad {
            let (cr, cc) = TileSchedule.clampGrid(rows: r, cols: c)
            XCTAssertGreaterThanOrEqual(cr, 1); XCTAssertGreaterThanOrEqual(cc, 1)
            XCTAssertLessThanOrEqual(cr * cc, TileSchedule.maxCells)
        }
    }

    // MARK: - 8. T4: softness clamped; no seam between adjacent revealed tiles

    func testSoftnessExtremesAndNoSeam() throws {
        let canvas = try FXCanvas(width: W, height: H)
        let a = try makeA(canvas), b = try makeB(canvas)
        let renderer = try TransitionRenderer(width: W, height: H)

        // softness is CLAMPED 0…1: an out-of-range 4 must not crash and still
        // reveals (behaves like 1); softness 0 = hard edges. Endpoints stay exact.
        for soft in [0.0, 4.0] {
            let spec = TransitionSpec(kind: .gridWipe(rows: rows, cols: cols, direction: .right, softness: soft),
                                      duration: 0.5, easing: .linear)
            let f0 = try renderer.render(a: a, b: b, spec: spec, progress: 0.0)
            let f1 = try renderer.render(a: a, b: b, spec: spec, progress: 1.0)
            XCTAssertLessThan(FXCanvas.meanDiff(f0, a), 0.02, "softness \(soft): p0 ≠ A")
            XCTAssertLessThan(FXCanvas.meanDiff(f1, b), 0.02, "softness \(soft): p1 ≠ B")
            let mid = try renderer.render(a: a, b: b, spec: spec, progress: 0.5)
            XCTAssertGreaterThan(revealedCount(mid), 0, "softness \(soft): mid revealed nothing")
            XCTAssertLessThan(revealedCount(mid), rows * cols, "softness \(soft): mid revealed all")
        }

        // NO SEAM: at phase 0.95 the left columns are fully revealed; the vertical
        // border between two fully-revealed tiles must show the BOTTOM (B), NOT a
        // top-coloured seam — for softness 0 AND a LARGE softness. The old per-tile
        // feather tapered removal to 0 at every tile border, leaving an orange seam
        // at high softness; the neighbour-aware feather does not feather a shared
        // edge between equally-revealed tiles.
        for soft in [0.0, 1.0] {
            let spec = TransitionSpec(kind: .gridWipe(rows: rows, cols: cols, direction: .right, softness: soft),
                                      duration: 0.5, easing: .linear)
            let f = try renderer.render(a: a, b: b, spec: spec, progress: 0.95)
            try dump(f, "t_softness_noseam_s\(Int(soft * 100))_gridwipe_p95.png")
            let tw = W / cols
            for c in 1..<3 {                 // shared borders col0|col1, col1|col2 (both revealed)
                let bx = min(c * tw, W - 1)
                for r in [1, 3] {
                    let y = min(Int((Double(r) + 0.5) * Double(H) / Double(rows)), H - 1)
                    let p = FXCanvas.pixel(f, x: bx, y: y)
                    XCTAssertGreaterThan(dist(p, orange), 0.25,
                        "softness \(soft): seam at border x=\(bx),y=\(y) shows top orange (got \(p)) — feather bled a seam")
                }
            }
        }
    }
}
