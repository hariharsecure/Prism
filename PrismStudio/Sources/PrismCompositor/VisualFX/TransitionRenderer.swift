import CoreGraphics
import CoreVideo
import Foundation

/// The exact CPU/CoreGraphics raster of the transition library (DESIGN.md §1) —
/// the single source of truth for *every* `TransitionKind`'s pixels over
/// `progress 0→1`. Compositor-native kinds also run on the GPU via
/// `TransitionSpec.schedule`, but this renderer is what previews, drives the
/// pixel-effect kinds, and produces the eyeball-able / assertable verification
/// frames.
///
/// Contract:
///  - `progress 0` returns a frame equal to A; `progress 1` equals B.
///  - `0 < progress < 1` is a genuine blend (differs from both A and B) for
///    every kind.
public final class TransitionRenderer {
    private let canvas: FXCanvas
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) throws {
        self.canvas = try FXCanvas(width: width, height: height)
        self.width = width
        self.height = height
    }

    /// Render one frame of `spec.kind` blending A→B at raw (un-eased) `progress`.
    /// The kind's easing is applied internally, so callers may pass linear phase.
    public func render(a: CVPixelBuffer, b: CVPixelBuffer, spec: TransitionSpec, progress rawT: Double) throws -> CVPixelBuffer {
        // `tileFlicker` is a CONTINUOUS looping blink, not a one-way A→B
        // transition: it must NOT short-circuit to A/B at the 0/1 endpoints (they
        // are the same point in the loop), so it is handled first on the raw phase.
        if case .tileFlicker(let rows0, let cols0, let seed, let soft) = spec.kind {
            let (rows, cols) = TileSchedule.clampGrid(rows: rows0, cols: cols0)   // T2
            let imgA = try FXCanvas.cgImage(from: a)
            let imgB = try FXCanvas.cgImage(from: b)
            let rev = TileSchedule.flicker(rows: rows, cols: cols, seed: seed, phase: rawT)
            return try tileComposite(top: imgA, bottom: imgB, rows: rows, cols: cols,
                                     reveal: rev, softness: soft)
        }
        let t = min(max(rawT, 0), 1)
        // B9: clamp the eased progress ONCE, here, before any geometry/pixel
        // math. Overshoot easings (backOut / bounceOut) return values outside
        // 0…1; unclamped they make negative-width wipe/iris rects and
        // over-travel pushes. (The intended overshoot lives in the anime
        // keyframe evaluator, not in transition geometry.)
        let e = min(max(spec.easing.apply(t), 0), 1)
        // Endpoints short-circuit to an exact copy so `== A` / `== B` holds
        // regardless of the kind's interior math.
        if t <= 0 { return try copy(a) }
        if t >= 1 { return try copy(b) }

        let imgA = try FXCanvas.cgImage(from: a)
        let imgB = try FXCanvas.cgImage(from: b)
        switch spec.kind {
        case .dissolve:     return try dissolve(imgA, imgB, e)
        case .wipe(let d):  return try wipe(imgA, imgB, edge: d, e: e)
        case .push(let d):  return try push(imgA, imgB, edge: d, e: e)
        case .iris:         return try iris(imgA, imgB, e)
        case .zoomBlur:     return try zoomBlur(imgA, imgB, e)
        case .glitch:       return try glitch(a, b, e, t)
        // B8: honor the kind's easing — the flash/cut ride the eased progress,
        // consistent with every other kind (not the raw linear phase).
        case .animeFlash:   return try animeFlash(imgA, imgB, e)
        case .speedline:    return try speedline(imgA, imgB, e)
        case .blockDissolve(let rows0, let cols0, let seed, let soft):
            let (rows, cols) = TileSchedule.clampGrid(rows: rows0, cols: cols0)   // T2
            let rev = TileSchedule.blockDissolve(rows: rows, cols: cols, seed: seed, phase: e)
            return try tileComposite(top: imgA, bottom: imgB, rows: rows, cols: cols, reveal: rev, softness: soft)
        case .gridWipe(let rows0, let cols0, let dir, let soft):
            let (rows, cols) = TileSchedule.clampGrid(rows: rows0, cols: cols0)   // T2
            let rev = TileSchedule.gridWipe(rows: rows, cols: cols, direction: dir, phase: e)
            return try tileComposite(top: imgA, bottom: imgB, rows: rows, cols: cols, reveal: rev, softness: soft)
        case .checkerboard(let rows0, let cols0, let soft):
            let (rows, cols) = TileSchedule.clampGrid(rows: rows0, cols: cols0)   // T2
            let rev = TileSchedule.checkerboard(rows: rows, cols: cols, phase: e)
            return try tileComposite(top: imgA, bottom: imgB, rows: rows, cols: cols, reveal: rev, softness: soft)
        case .tileReveal(let rows0, let cols0, let soft):
            let (rows, cols) = TileSchedule.clampGrid(rows: rows0, cols: cols0)   // T2
            return try tileGrowComposite(top: imgA, bottom: imgB, rows: rows, cols: cols, fraction: e, softness: soft)
        case .tileFlicker:
            // Handled on the raw phase before the endpoint short-circuit above.
            fatalError("tileFlicker handled before endpoint short-circuit")
        }
    }

    // MARK: - Tile / grid family (DESIGN.md Build A)

    /// Build the top layer as A with GENUINELY TRANSPARENT per-tile holes (a real
    /// premultiplied-alpha hole, not opaque black), then composite it over a fully
    /// painted B. Where a hole is punched, B shows through — verified in the PNGs.
    ///
    /// The hole is punched per-pixel into a premultiplied-first BGRA scratch image:
    /// A is drawn opaque, then every channel (incl. alpha) is scaled by the top's
    /// surviving fraction `f = 1 - reveal·edgeFeather`. Scaling all four
    /// premultiplied bytes by the same factor keeps the premultiplied invariant,
    /// so drawing the result over B blends correctly (reveal=1 ⇒ f=0 ⇒ true hole).
    private func tileComposite(top: CGImage, bottom: CGImage, rows: Int, cols: Int,
                               reveal: [Double], softness: Double) throws -> CVPixelBuffer {
        // Neighbour-aware feather (T4): no top-coloured seam between adjacent
        // fully-revealed tiles. Shared premultiplied hole-punch (T2 clamps).
        let removal = TileSchedule.gridRemoval(reveal: reveal, rows: rows, cols: cols, softness: softness)
        let holed = try punchTileHoles(source: top, width: width, height: height,
                                       rows: rows, cols: cols, removal: removal)
        return try canvas.render { ctx in
            ctx.draw(bottom, in: canvas.rect)   // B fully underneath (never black)
            ctx.draw(holed, in: canvas.rect)    // A with transparent holes on top
        }
    }

    /// `tileReveal`: every tile reveals uniformly via a centered box that grows
    /// from 0 to full over `fraction`. Removal is 1 inside the box, feathered at
    /// its edges by `softness` (clamped 0…1, T4).
    private func tileGrowComposite(top: CGImage, bottom: CGImage, rows: Int, cols: Int,
                                   fraction: Double, softness: Double) throws -> CVPixelBuffer {
        let f = min(max(fraction, 0), 1)
        let s = min(max(softness, 0), 1)
        let holed = try punchTileHoles(source: top, width: width, height: height,
                                       rows: rows, cols: cols) { _, _, localX, localY, tileW, tileH in
            let halfW = 0.5 * tileW * f, halfH = 0.5 * tileH * f
            let dx = abs(localX - tileW / 2), dy = abs(localY - tileH / 2)
            // Antialias margin (at least 0.75px; wider with softness).
            let m = max(0.75, s * 0.5 * min(tileW, tileH))
            let insideX = 1 - fxSmoothstep(halfW - m, halfW + m, dx)
            let insideY = 1 - fxSmoothstep(halfH - m, halfH + m, dy)
            return insideX * insideY
        }
        return try canvas.render { ctx in
            ctx.draw(bottom, in: canvas.rect)
            ctx.draw(holed, in: canvas.rect)
        }
    }

    // MARK: - Kinds

    private func dissolve(_ a: CGImage, _ b: CGImage, _ e: Double) throws -> CVPixelBuffer {
        try canvas.render { ctx in
            ctx.draw(a, in: canvas.rect)
            ctx.setAlpha(CGFloat(e))
            ctx.draw(b, in: canvas.rect)
        }
    }

    private func wipe(_ a: CGImage, _ b: CGImage, edge: FXDirection, e: Double) throws -> CVPixelBuffer {
        let w = CGFloat(width), h = CGFloat(height)
        return try canvas.render { ctx in
            ctx.draw(b, in: canvas.rect)                 // incoming underneath
            // Outgoing clipped to the region not yet wiped. Context is
            // bottom-left origin, so "up" (screen) is high y.
            let region: CGRect
            switch edge {
            case .left:  region = CGRect(x: CGFloat(e) * w, y: 0, width: (1 - CGFloat(e)) * w, height: h)
            case .right: region = CGRect(x: 0, y: 0, width: (1 - CGFloat(e)) * w, height: h)
            case .up:    region = CGRect(x: 0, y: 0, width: w, height: (1 - CGFloat(e)) * h) // A recedes upward
            case .down:  region = CGRect(x: 0, y: CGFloat(e) * h, width: w, height: (1 - CGFloat(e)) * h)
            }
            ctx.saveGState()
            ctx.clip(to: region)
            ctx.draw(a, in: canvas.rect)
            ctx.restoreGState()
        }
    }

    private func push(_ a: CGImage, _ b: CGImage, edge: FXDirection, e: Double) throws -> CVPixelBuffer {
        let w = CGFloat(width), h = CGFloat(height)
        let ce = CGFloat(e)
        return try canvas.render { ctx in
            // A exits toward `edge`; B enters from the opposite side.
            let aOrigin: CGPoint, bOrigin: CGPoint
            switch edge {
            case .left:  aOrigin = CGPoint(x: -ce * w, y: 0);       bOrigin = CGPoint(x: (1 - ce) * w, y: 0)
            case .right: aOrigin = CGPoint(x: ce * w, y: 0);        bOrigin = CGPoint(x: -(1 - ce) * w, y: 0)
            case .up:    aOrigin = CGPoint(x: 0, y: ce * h);        bOrigin = CGPoint(x: 0, y: -(1 - ce) * h)
            case .down:  aOrigin = CGPoint(x: 0, y: -ce * h);       bOrigin = CGPoint(x: 0, y: (1 - ce) * h)
            }
            ctx.draw(b, in: CGRect(origin: bOrigin, size: CGSize(width: w, height: h)))
            ctx.draw(a, in: CGRect(origin: aOrigin, size: CGSize(width: w, height: h)))
        }
    }

    private func iris(_ a: CGImage, _ b: CGImage, _ e: Double) throws -> CVPixelBuffer {
        let w = CGFloat(width), h = CGFloat(height)
        let maxR = (hypot(w, h) / 2) * CGFloat(e)
        let center = CGPoint(x: w / 2, y: h / 2)
        return try canvas.render { ctx in
            ctx.draw(a, in: canvas.rect)                 // outgoing background
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: center.x - maxR, y: center.y - maxR, width: maxR * 2, height: maxR * 2))
            ctx.clip()
            ctx.draw(b, in: canvas.rect)                 // incoming through the circle
            ctx.restoreGState()
        }
    }

    private func zoomBlur(_ a: CGImage, _ b: CGImage, _ e: Double) throws -> CVPixelBuffer {
        let w = CGFloat(width), h = CGFloat(height)
        let strength = sin(Double.pi * e)               // peaks mid-transition
        func centeredScaled(_ img: CGImage, _ s: CGFloat, ctx: CGContext, alpha: CGFloat) {
            let dw = w * s, dh = h * s
            let r = CGRect(x: (w - dw) / 2, y: (h - dh) / 2, width: dw, height: dh)
            ctx.setAlpha(alpha)
            ctx.draw(img, in: r)
        }
        return try canvas.render { ctx in
            // A zooms out (grows) and fades; B zooms in (shrinks toward 1) and rises.
            centeredScaled(a, 1 + 0.6 * CGFloat(e), ctx: ctx, alpha: 1)
            // Radial-blur smear: several scaled copies of B around its target scale.
            let samples = 5
            let baseScaleB = 1 + 0.4 * (1 - CGFloat(e))
            for i in 0..<samples {
                let k = (CGFloat(i) / CGFloat(samples - 1) - 0.5) * 2   // -1…1
                let s = baseScaleB * (1 + 0.08 * CGFloat(strength) * k)
                centeredScaled(b, s, ctx: ctx, alpha: CGFloat(e) / CGFloat(samples))
            }
        }
    }

    private func animeFlash(_ a: CGImage, _ b: CGImage, _ e: Double) throws -> CVPixelBuffer {
        // `e` is the EASED progress (B8). Base is a hard cut at the midpoint; a
        // white flash peaks there.
        let flash = pow(1 - abs(2 * e - 1), 0.55)       // 0 at ends, 1 at e=0.5
        let base = e < 0.5 ? a : b
        return try canvas.render { ctx in
            ctx.draw(base, in: canvas.rect)
            ctx.setFillColor(RGBA(r: 1, g: 1, b: 1, a: 1).cg)
            ctx.setAlpha(CGFloat(flash))
            ctx.fill(canvas.rect)
        }
    }

    private func speedline(_ a: CGImage, _ b: CGImage, _ e: Double) throws -> CVPixelBuffer {
        let w = CGFloat(width), h = CGFloat(height)
        let center = CGPoint(x: w / 2, y: h / 2)
        let coverage = sin(Double.pi * e)               // lines peak mid-transition
        let sweep = e * 0.35                            // slight angular rotation
        let reach = hypot(w, h)
        return try canvas.render { ctx in
            ctx.draw(a, in: canvas.rect)
            ctx.setAlpha(CGFloat(e))
            ctx.draw(b, in: canvas.rect)                // also cross-dissolves underneath
            ctx.setAlpha(1)
            // Radial white speed-line wedges from center.
            let count = 56
            ctx.setFillColor(RGBA(r: 1, g: 1, b: 1, a: 1).cg)
            for i in 0..<count {
                let a0 = (Double(i) / Double(count)) * 2 * Double.pi + sweep
                let half = 0.006 + 0.010 * coverage     // wedge half-angle
                let p0 = CGPoint(x: center.x + cos(a0 - half) * reach, y: center.y + sin(a0 - half) * reach)
                let p1 = CGPoint(x: center.x + cos(a0 + half) * reach, y: center.y + sin(a0 + half) * reach)
                ctx.beginPath()
                ctx.move(to: center)
                ctx.addLine(to: p0)
                ctx.addLine(to: p1)
                ctx.closePath()
                ctx.setAlpha(CGFloat(0.85 * coverage))
                ctx.fillPath()
            }
        }
    }

    // MARK: - glitch (genuine per-pixel RGB-split)

    private func glitch(_ a: CVPixelBuffer, _ b: CVPixelBuffer, _ e: Double, _ t: Double) throws -> CVPixelBuffer {
        // Base = a dissolve of A→B, rendered once, then channels are split.
        let base = try dissolve(try FXCanvas.cgImage(from: a), try FXCanvas.cgImage(from: b), e)
        let split = Int((sin(Double.pi * t) * 0.028 * Double(width)).rounded())   // px, peaks mid
        let w = width, h = height
        CVPixelBufferLockBaseAddress(base, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(base, .readOnly) }
        let srcBase = CVPixelBufferGetBaseAddress(base)!.assumingMemoryBound(to: UInt8.self)
        let srcBPR = CVPixelBufferGetBytesPerRow(base)
        // Deterministic per-band horizontal jitter (no RNG → reproducible frames).
        func rowShift(_ y: Int) -> Int {
            let band = y / 24
            let jig = (band * 2654435761) & 0xff          // cheap hash
            let amt = Int(Double(jig) / 255 * 6 * sin(Double.pi * t))   // 0…~6 px
            return (band % 2 == 0) ? amt : -amt
        }
        return try canvas.renderRaw { out, outBPR in
            for y in 0..<h {
                let jitter = rowShift(y)
                let srcRow = srcBase + y * srcBPR
                let outRow = out + y * outBPR
                for x in 0..<w {
                    func sample(_ dx: Int, _ channel: Int) -> UInt8 {
                        var sx = x + dx + jitter
                        if sx < 0 { sx = 0 }; if sx >= w { sx = w - 1 }
                        return (srcRow + sx * 4)[channel]     // BGRA memory order
                    }
                    let o = outRow + x * 4
                    o[0] = sample(-split, 0)  // B channel shifted left
                    o[1] = sample(0, 1)       // G channel centered
                    o[2] = sample(split, 2)   // R channel shifted right
                    o[3] = 255
                }
            }
        }
    }

    // MARK: - Helpers

    /// Exact copy of a source buffer into a fresh FX buffer (for the 0/1 endpoints).
    private func copy(_ src: CVPixelBuffer) throws -> CVPixelBuffer {
        let img = try FXCanvas.cgImage(from: src)
        return try canvas.render { ctx in ctx.draw(img, in: canvas.rect) }
    }
}
