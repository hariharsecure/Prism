import CoreGraphics
import CoreMedia
import CoreVideo
import Metal
import XCTest

import PrismCompositor
import PrismCore

/// LIVE-compositor proof for **F20** — the fix that plumbs `Layer.rotation`
/// (radians, about the layer centre) through the real `MetalCompositor` vertex
/// stage so `LayerMotion`/`LayerTransform.rotation` is no longer silently
/// dropped.
///
/// The bug: `LayerMotion.transform(at:)` returns rotation, but the scene `Layer`
/// had no rotation field, so the live program never rotated anything. A pure
/// evaluator test could not catch it — only compositing an ASYMMETRIC pattern
/// through the actual GPU and observing that it *moves as a rotation about the
/// centre* does.
///
/// These assertions FAIL on the pre-fix engine (a rotated layer renders
/// identically to an un-rotated one, so the marker never moves) and hold only
/// when rotation is genuinely applied about the layer centre, aspect-corrected.
final class LayerRotationCompositeTests: XCTestCase {

    private static let dumpDir = URL(fileURLWithPath:
        "/tmp/prism_f20_fix")

    private func makeCompositor(_ w: Int, _ h: Int) throws -> MetalCompositor {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device on this host")
        }
        return try MetalCompositor(device: device, width: w, height: h)
    }

    // MARK: - Raw readback helpers (lock once, scan)

    /// Visit every pixel as (normalized x, normalized y with row 0 = top, luma
    /// 0…1). BGRA premultiplied-first; the fixtures here are opaque so
    /// premultiplied == straight.
    private func forEachPixel(_ buffer: CVPixelBuffer, step: Int = 1,
                              _ body: (_ xN: Double, _ yN: Double, _ luma: Double) -> Void) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var y = 0
        while y < h {
            let row = base + y * bpr
            var x = 0
            while x < w {
                let p = row + x * 4                 // B,G,R,A
                let luma = (Double(p[2]) * 0.30 + Double(p[1]) * 0.59 + Double(p[0]) * 0.11) / 255
                body(Double(x) / Double(w), Double(y) / Double(h), luma)
                x += step
            }
            y += step
        }
    }

    /// Luma-weighted centroid over the whole frame, normalized (row 0 = top).
    private func centroid(_ buffer: CVPixelBuffer) -> CGPoint {
        var sx = 0.0, sy = 0.0, sw = 0.0
        forEachPixel(buffer) { xN, yN, luma in
            sx += xN * luma; sy += yN * luma; sw += luma
        }
        guard sw > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: sx / sw, y: sy / sw)
    }

    /// Pixel bounding box (normalized) of the bright marker (luma > 0.5).
    private func brightBBox(_ buffer: CVPixelBuffer) -> (w: Double, h: Double, cx: Double, cy: Double, count: Int) {
        var minX = 2.0, minY = 2.0, maxX = -1.0, maxY = -1.0, n = 0
        forEachPixel(buffer) { xN, yN, luma in
            if luma > 0.5 {
                minX = min(minX, xN); maxX = max(maxX, xN)
                minY = min(minY, yN); maxY = max(maxY, yN); n += 1
            }
        }
        guard n > 0 else { return (0, 0, 0.5, 0.5, 0) }
        return (maxX - minX, maxY - minY, (minX + maxX) / 2, (minY + maxY) / 2, n)
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }

    // MARK: - A: an off-centre marker actually rotates about the layer centre

    /// A full-canvas layer carrying an ASYMMETRIC (off-centre) white disc on a
    /// black field, composited through the REAL `MetalCompositor`. On a SQUARE
    /// canvas (aspect 1 → isotropic normalized coords) a rotation of the layer
    /// must move the marker's centroid along a circle about the canvas centre:
    ///
    ///  - it MOVES (the bug-reproducing assertion: pre-fix the marker never moves);
    ///  - its distance from centre is preserved (rotation, not translate/shear);
    ///  - at 90° the displacement is perpendicular to the 0° displacement;
    ///  - at 180° it is the point-reflection through the centre.
    ///
    /// And a rotation-0 layer renders byte-identically to the default (no
    /// regression). Dumps 0°/30° PNGs for the lead.
    func testOffCentreMarkerRotatesAboutCentre() throws {
        let S = 300
        let compositor = try makeCompositor(S, S)
        let canvas = try FXCanvas(width: S, height: S)
        let markerID = SourceID("rot.marker")

        // Black field + an off-centre white disc (CG is bottom-left origin; the
        // absolute spot is irrelevant — only that it is off the centre).
        let discCG = CGPoint(x: 0.30 * Double(S), y: 0.70 * Double(S))
        let radius = 0.10 * Double(S)
        let markerBuf = try canvas.render { ctx in
            ctx.setFillColor(RGBA.black.cg); ctx.fill(canvas.rect)
            ctx.setFillColor(RGBA.white.cg)
            ctx.fillEllipse(in: CGRect(x: discCG.x - radius, y: discCG.y - radius,
                                       width: radius * 2, height: radius * 2))
        }
        let frames: [SourceID: VideoFrame] = [
            markerID: VideoFrame(pixelBuffer: markerBuf, pts: HouseClock.now(), source: markerID),
        ]

        func render(_ rotation: Double) throws -> VideoFrame {
            let scene = Scene(name: "rot\(rotation)", layers: [
                Layer(sourceID: markerID, rotation: rotation, zIndex: 0),
            ])
            return try compositor.composite(frames: frames, scene: scene, pts: HouseClock.now())
        }

        let f0 = try render(0)
        let f90 = try render(.pi / 2)
        let f180 = try render(.pi)

        let centre = CGPoint(x: 0.5, y: 0.5)
        let p0 = centroid(f0.pixelBuffer)
        let p90 = centroid(f90.pixelBuffer)
        let p180 = centroid(f180.pixelBuffer)

        // Dumps for the lead (0° and a shallow 30° so the disc's arc is obvious).
        let f30 = try render(.pi / 6)
        _ = try? FXCanvas.writePNG(f0.pixelBuffer, to: Self.dumpDir.appendingPathComponent("marker_rot0.png"))
        _ = try? FXCanvas.writePNG(f30.pixelBuffer, to: Self.dumpDir.appendingPathComponent("marker_rot30.png"))
        _ = try? FXCanvas.writePNG(f90.pixelBuffer, to: Self.dumpDir.appendingPathComponent("marker_rot90.png"))

        let v0 = CGPoint(x: p0.x - centre.x, y: p0.y - centre.y)
        let v90 = CGPoint(x: p90.x - centre.x, y: p90.y - centre.y)
        let v180 = CGPoint(x: p180.x - centre.x, y: p180.y - centre.y)
        let r0 = hypot(v0.x, v0.y), r90 = hypot(v90.x, v90.y), r180 = hypot(v180.x, v180.y)

        // The marker is genuinely off-centre (so a rotation can move it).
        XCTAssertGreaterThan(r0, 0.15, "marker should be well off-centre at rest (got r0=\(r0), p0=\(p0))")

        // BUG-REPRODUCING: at 90° the marker must MOVE. Pre-fix, rotation is
        // dropped → f90 == f0 → p90 == p0 → this fails.
        XCTAssertGreaterThan(dist(p90, p0), 0.15,
                             "90° rotation did not move the marker (dropped rotation?) p0=\(p0) p90=\(p90)")
        XCTAssertGreaterThan(dist(p180, p0), 0.15,
                             "180° rotation did not move the marker p0=\(p0) p180=\(p180)")

        // ROTATION (not translate/shear): distance from centre preserved.
        XCTAssertEqual(r90, r0, accuracy: 0.03, "90°: radius not preserved (r0=\(r0) r90=\(r90))")
        XCTAssertEqual(r180, r0, accuracy: 0.03, "180°: radius not preserved (r0=\(r0) r180=\(r180))")

        // 90° displacement is perpendicular to the 0° displacement (sign-agnostic).
        let cos90 = (v0.x * v90.x + v0.y * v90.y) / (r0 * r90)
        XCTAssertEqual(cos90, 0, accuracy: 0.12, "90° displacement not perpendicular to rest (cos=\(cos90))")

        // 180° is the point-reflection through the centre: v180 ≈ -v0.
        XCTAssertEqual(v180.x, -v0.x, accuracy: 0.03, "180°: not point-reflected in x")
        XCTAssertEqual(v180.y, -v0.y, accuracy: 0.03, "180°: not point-reflected in y")

        // NO REGRESSION: a rotation-0 layer is byte-identical to the default
        // (rotation left unset). meanDiffWithAlpha over all four channels == 0.
        let sceneDefault = Scene(name: "def", layers: [Layer(sourceID: markerID, zIndex: 0)])
        let fDefault = try compositor.composite(frames: frames, scene: sceneDefault, pts: HouseClock.now())
        let diff0 = FXCanvas.meanDiffWithAlpha(f0.pixelBuffer, fDefault.pixelBuffer, step: 1)
        XCTAssertEqual(diff0, 0, accuracy: 0.0001,
                       "rotation:0 must render byte-identically to the default layer (diff=\(diff0))")
    }

    // MARK: - B: rotation is aspect-corrected (no distortion) on a 16:9 canvas

    /// A CENTRED circle on a non-square (16:9) canvas, composited live, must stay
    /// a circle when the layer is rotated 90° — i.e. its bright bounding box stays
    /// ~square. A naive rotation in raw (anisotropic) NDC would squeeze the circle
    /// into an ellipse (w/h ≈ aspect² away from 1); the aspect-corrected transform
    /// keeps w ≈ h. The centred circle also must not translate under rotation.
    func testCentredCircleStaysCircularUnderRotation() throws {
        let W = 480, H = 270                       // 16:9, aspect ≈ 1.778
        let compositor = try makeCompositor(W, H)
        let canvas = try FXCanvas(width: W, height: H)
        let circID = SourceID("rot.circle")

        // A true PIXEL circle at the canvas centre (radius in px, drawn in the
        // canvas-sized source so the layer maps it 1:1).
        let radius = 0.20 * Double(H)              // 54 px, fits within H/2
        let circBuf = try canvas.render { ctx in
            ctx.setFillColor(RGBA.black.cg); ctx.fill(canvas.rect)
            ctx.setFillColor(RGBA.white.cg)
            ctx.fillEllipse(in: CGRect(x: Double(W) / 2 - radius, y: Double(H) / 2 - radius,
                                       width: radius * 2, height: radius * 2))
        }
        let frames: [SourceID: VideoFrame] = [
            circID: VideoFrame(pixelBuffer: circBuf, pts: HouseClock.now(), source: circID),
        ]
        func render(_ rotation: Double) throws -> VideoFrame {
            let scene = Scene(name: "c\(rotation)", layers: [Layer(sourceID: circID, rotation: rotation, zIndex: 0)])
            return try compositor.composite(frames: frames, scene: scene, pts: HouseClock.now())
        }

        let c0 = try render(0)
        let c90 = try render(.pi / 2)
        _ = try? FXCanvas.writePNG(c0.pixelBuffer, to: Self.dumpDir.appendingPathComponent("circle_16x9_rot0.png"))
        _ = try? FXCanvas.writePNG(c90.pixelBuffer, to: Self.dumpDir.appendingPathComponent("circle_16x9_rot90.png"))

        // The bright box is measured in NORMALIZED coords; convert to a pixel
        // aspect ratio (× W/H on width) so a real circle reads ~1.0.
        let b0 = brightBBox(c0.pixelBuffer)
        let b90 = brightBBox(c90.pixelBuffer)
        XCTAssertGreaterThan(b0.count, 100, "circle marker not found at rest")
        XCTAssertGreaterThan(b90.count, 100, "circle marker not found after 90°")

        let pxRatio0 = (b0.w * Double(W)) / (b0.h * Double(H))
        let pxRatio90 = (b90.w * Double(W)) / (b90.h * Double(H))
        XCTAssertEqual(pxRatio0, 1.0, accuracy: 0.15, "rest fixture is not circular (px w/h=\(pxRatio0))")
        // The load-bearing anti-distortion assertion: still ~circular after 90°.
        // A raw-NDC rotation would make this ≈ aspect² (≈3.16) or its reciprocal.
        XCTAssertEqual(pxRatio90, 1.0, accuracy: 0.20, "90° rotation distorted the circle (px w/h=\(pxRatio90))")

        // A centred marker must not translate under rotation about the centre.
        XCTAssertEqual(b90.cx, 0.5, accuracy: 0.03, "centred circle drifted in x under rotation")
        XCTAssertEqual(b90.cy, 0.5, accuracy: 0.03, "centred circle drifted in y under rotation")
    }
}
