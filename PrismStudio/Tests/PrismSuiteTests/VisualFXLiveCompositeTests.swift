import CoreGraphics
import CoreMedia
import CoreVideo
import Metal
import os
import XCTest

import PrismCompositor
import PrismCore
import PrismSources

/// LIVE-compositor verification for the VisualFX fixes that a PNG dump or a
/// headless CPU raster could NOT catch — they only surface when frames go
/// through the real `MetalCompositor` / `RenderLoop` path:
///
///  - **B1**: a `CharacterSource` composited over an OPAQUE background must show
///    the background OUTSIDE the figure (not opaque black). Proven both ways: the
///    `Layer.character` factory (premultipliedAlpha=true) shows the background;
///    a plain default `Layer` (the bug) shows black.
///  - **B5**: the compositor-native `wipe` must clip EVERY layer — a sub-frame
///    PiP in the wiped region must NOT show through; one in the un-wiped region
///    must remain; a straddling one is cut at the boundary (crop remap). Plus
///    direction, plus exact A/B endpoints through a live `RenderLoop.switchScene`.
///  - **B4**: the live wipe also exercises the RenderLoop-owned transition clock
///    (the schedule closures are pure functions of the loop's `elapsed`).
final class VisualFXLiveCompositeTests: XCTestCase {

    // Program canvas for these tests.
    private let W = 480, H = 270

    private func makeCompositor() throws -> MetalCompositor {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device on this host")
        }
        return try MetalCompositor(device: device, width: W, height: H)
    }

    /// A solid opaque BGRA IOSurface frame for `id`.
    private func solidFrame(_ id: SourceID, _ c: RGBA, canvas: FXCanvas) throws -> VideoFrame {
        VideoFrame(pixelBuffer: try canvas.solid(c), pts: HouseClock.now(), source: id)
    }

    /// Read one program pixel (normalized coords) as un-premultiplied RGBA.
    private func px(_ frame: VideoFrame, _ xN: Double, _ yN: Double) -> RGBA {
        let x = min(max(Int(xN * Double(W)), 0), W - 1)
        let y = min(max(Int(yN * Double(H)), 0), H - 1)
        return FXCanvas.pixel(frame.pixelBuffer, x: x, y: y)
    }

    private func assertColor(_ frame: VideoFrame, _ xN: Double, _ yN: Double,
                             r: Double, g: Double, b: Double, tol: Double = 0.04,
                             _ what: String) {
        let p = px(frame, xN, yN)
        XCTAssertEqual(p.r, r, accuracy: tol, "\(what): R (got \(p.r))")
        XCTAssertEqual(p.g, g, accuracy: tol, "\(what): G (got \(p.g))")
        XCTAssertEqual(p.b, b, accuracy: tol, "\(what): B (got \(p.b))")
    }

    // MARK: - B1: CharacterSource over an opaque background

    func testCharacterSourceCompositesOverBackgroundNotBlack() throws {
        let compositor = try makeCompositor()
        let canvas = try FXCanvas(width: W, height: H)

        // A live CharacterSource frame (transparent around the centred figure).
        let charID = SourceID("live.character")
        let character = try CharacterSource(id: charID,
                                            canvasSize: CanvasSize(width: W, height: H), fps: 60)
        let collector = OSAllocatedUnfairLock<[VideoFrame]>(initialState: [])
        character.onFrame = { f in collector.withLock { $0.append(f) } }
        try character.start()
        XCTAssertTrue(pollUntil(2.0) { collector.withLock { !$0.isEmpty } }, "character emitted no frame")
        character.stop()
        let charFrame = collector.withLock { $0.first! }

        // Opaque BLUE background under the character.
        let bgID = SourceID("live.bg")
        let bg = try solidFrame(bgID, RGBA(r: 0, g: 0, b: 1), canvas: canvas)
        let frames: [SourceID: VideoFrame] = [charID: charFrame, bgID: bg]

        // Correct wiring: Layer.character sets premultipliedAlpha=true (B1 fix).
        let good = Scene(name: "char.good", layers: [
            Layer(sourceID: bgID, zIndex: 0),
            Layer.character(sourceID: charID, zIndex: 1),
        ])
        let program = try compositor.composite(frames: frames, scene: good, pts: HouseClock.now())

        // OUTSIDE the figure (all four corners) → the BLUE background, NOT black.
        for (xN, yN, name) in [(0.02, 0.03, "top-left"), (0.98, 0.03, "top-right"),
                               (0.02, 0.97, "bottom-left"), (0.98, 0.97, "bottom-right")] {
            assertColor(program, xN, yN, r: 0, g: 0, b: 1, "B1 \(name) corner shows background blue")
        }
        // INSIDE the figure the character actually drew (centre ≠ background).
        let centre = px(program, 0.5, 0.5)
        let bgDist = abs(centre.r - 0) + abs(centre.g - 0) + abs(centre.b - 1)
        XCTAssertGreaterThan(bgDist, 0.2, "B1: character not visible at centre (got \(centre))")

        // The BUG, for contrast: a plain default Layer (premultipliedAlpha=false)
        // forces the transparent surround opaque → corners go BLACK.
        let buggy = Scene(name: "char.buggy", layers: [
            Layer(sourceID: bgID, zIndex: 0),
            Layer(sourceID: charID, zIndex: 1),   // default premultipliedAlpha:false
        ])
        let buggyProgram = try compositor.composite(frames: frames, scene: buggy, pts: HouseClock.now())
        assertColor(buggyProgram, 0.02, 0.03, r: 0, g: 0, b: 0,
                    "B1 contrast: default Layer makes the corner opaque black")
    }

    // MARK: - B5: compositor-native wipe clips EVERY layer (deterministic)

    func testWipeClipsSubFrameLayersDeterministic() throws {
        let compositor = try makeCompositor()
        let canvas = try FXCanvas(width: W, height: H)

        let redID = SourceID("w.red"), blueID = SourceID("w.blue")
        let greenID = SourceID("w.green"), magentaID = SourceID("w.magenta"), cyanID = SourceID("w.cyan")
        let frames: [SourceID: VideoFrame] = [
            redID:     try solidFrame(redID, RGBA(r: 1, g: 0, b: 0), canvas: canvas),
            blueID:    try solidFrame(blueID, RGBA(r: 0, g: 0, b: 1), canvas: canvas),
            greenID:   try solidFrame(greenID, RGBA(r: 0, g: 1, b: 0), canvas: canvas),
            magentaID: try solidFrame(magentaID, RGBA(r: 1, g: 0, b: 1), canvas: canvas),
            cyanID:    try solidFrame(cyanID, RGBA(r: 0, g: 1, b: 1), canvas: canvas),
        ]

        // Outgoing A: full red + three PiPs — one in the wiped (left) region, one
        // in the un-wiped (right) region, one straddling the p=0.5 boundary.
        let sceneA = Scene(name: "A", layers: [
            Layer(sourceID: redID, zIndex: 0),
            Layer(sourceID: greenID,   frame: CGRect(x: 0.05, y: 0.40, width: 0.20, height: 0.20), zIndex: 1),
            Layer(sourceID: magentaID, frame: CGRect(x: 0.75, y: 0.40, width: 0.20, height: 0.20), zIndex: 2),
            Layer(sourceID: cyanID,    frame: CGRect(x: 0.40, y: 0.70, width: 0.20, height: 0.20), zIndex: 3),
        ])
        let sceneB = Scene(name: "B", layers: [Layer(sourceID: blueID, zIndex: 0)])

        // Evaluate the compositor-native wipe schedule at p=0.5 (linear, dur 0.5
        // → elapsed 0.25) and composite the overlay stack (incoming under).
        let spec = TransitionSpec(kind: .wipe(.left), duration: 0.5, easing: .linear)
        let sched = try XCTUnwrap(spec.schedule(outgoing: sceneA, incoming: sceneB))
        let outClipped = try XCTUnwrap(sched.outgoingScene)(0.25)
        let inScene = (sched.incomingScene?(0.25)) ?? sceneB
        let program = try compositor.composite(frames: frames,
                                               scene: mergeOverlay(under: inScene, over: outClipped),
                                               pts: HouseClock.now())

        // Un-wiped region for wipe(.left) at p=0.5 is x∈[0.5,1] (A); x∈[0,0.5] is B.
        assertColor(program, 0.25, 0.50, r: 0, g: 0, b: 1, "B5 wipe.left: left half revealed B (blue)")
        assertColor(program, 0.62, 0.20, r: 1, g: 0, b: 0, "B5 wipe.left: right half still A (red)")
        // (a) PiP entirely in the wiped region must NOT show through: its old
        // location now reads the revealed B, not green.
        assertColor(program, 0.15, 0.50, r: 0, g: 0, b: 1, "B5: left PiP (green) is wiped, shows B")
        // A PiP entirely in the un-wiped region still renders (we didn't drop all).
        assertColor(program, 0.85, 0.50, r: 1, g: 0, b: 1, "B5: right PiP (magenta) still shows")
        // A straddling PiP is CUT at the boundary (crop remap): right part shows,
        // left part is wiped to B.
        assertColor(program, 0.55, 0.80, r: 0, g: 1, b: 1, "B5: straddling PiP right of boundary shows cyan")
        assertColor(program, 0.45, 0.80, r: 0, g: 0, b: 1, "B5: straddling PiP left of boundary is wiped to B")
    }

    // MARK: - B5: crop remap PROOF (patterned PiP + non-default crop)

    /// A 4-vertical-band source: green | yellow | magenta | cyan across source-x
    /// quarters. Spatially varying so a WRONG frame→crop remap samples a
    /// different band (unlike a solid-color PiP, which passes any remap).
    private func bands4(_ canvas: FXCanvas) throws -> CVPixelBuffer {
        try canvas.render { ctx in
            let cols: [RGBA] = [RGBA(r: 0, g: 1, b: 0), RGBA(r: 1, g: 1, b: 0),
                                RGBA(r: 1, g: 0, b: 1), RGBA(r: 0, g: 1, b: 1)]
            let bw = Double(self.W) / 4
            for (i, c) in cols.enumerated() {
                ctx.setFillColor(c.cg)
                ctx.fill(CGRect(x: Double(i) * bw, y: 0, width: bw, height: Double(self.H)))
            }
        }
    }

    /// B5 crop-remap: a straddling PiP with a spatially-varying pattern AND a
    /// non-default `crop`. After the wipe clips it at the boundary, the surviving
    /// sub-region must show the CORRECT part of the pattern — the exact content
    /// that was there pre-wipe — which only holds if the frame→crop remap is
    /// right. A wrong/absent remap squeezes the whole crop into the narrower
    /// frame and shows a shifted band. This is the assertion the solid-color
    /// deterministic test could not make.
    func testWipeCropRemapWithPatternedPiP() throws {
        let compositor = try makeCompositor()
        let canvas = try FXCanvas(width: W, height: H)

        let redID = SourceID("cr.red"), blueID = SourceID("cr.blue"), patID = SourceID("cr.pat")
        let frames: [SourceID: VideoFrame] = [
            redID:  try solidFrame(redID, RGBA(r: 1, g: 0, b: 0), canvas: canvas),
            blueID: try solidFrame(blueID, RGBA(r: 0, g: 0, b: 1), canvas: canvas),
            patID:  VideoFrame(pixelBuffer: try bands4(canvas), pts: HouseClock.now(), source: patID),
        ]

        // PiP frame straddles the p=0.5 boundary (x∈[0.30,0.70]). Its non-default
        // crop shows the MIDDLE half of the source (source-x [0.25,0.75]) → the
        // frame maps: left half yellow ([0.25,0.5)), right half magenta ([0.5,0.75)).
        let pipFrame = CGRect(x: 0.30, y: 0.40, width: 0.40, height: 0.20)
        let pipCrop  = CGRect(x: 0.25, y: 0.0,  width: 0.50, height: 1.0)
        let sceneA = Scene(name: "A", layers: [
            Layer(sourceID: redID, zIndex: 0),
            Layer(sourceID: patID, frame: pipFrame, crop: pipCrop, zIndex: 1),
        ])
        let sceneB = Scene(name: "B", layers: [Layer(sourceID: blueID, zIndex: 0)])

        // Compositor-native wipe.left at p=0.5 (dur 0.5 → elapsed 0.25).
        let spec = TransitionSpec(kind: .wipe(.left), duration: 0.5, easing: .linear)
        let sched = try XCTUnwrap(spec.schedule(outgoing: sceneA, incoming: sceneB))
        let outClipped = try XCTUnwrap(sched.outgoingScene)(0.25)
        let inScene = (sched.incomingScene?(0.25)) ?? sceneB
        let program = try compositor.composite(frames: frames,
                                               scene: mergeOverlay(under: inScene, over: outClipped),
                                               pts: HouseClock.now())

        // Left (wiped) half of the PiP is gone → shows incoming B (blue).
        assertColor(program, 0.40, 0.50, r: 0, g: 0, b: 1, "B5 crop: wiped-left PiP shows B")
        // Un-wiped background survives (red) away from the PiP.
        assertColor(program, 0.85, 0.20, r: 1, g: 0, b: 0, "B5 crop: right bg still A red")
        // LOAD-BEARING crop-remap pixel: the surviving right part of the PiP
        // (canvas x∈[0.5,0.7]) must show MAGENTA (source-x [0.5,0.75]) — a correct
        // remap keeps content put. A wrong remap shows YELLOW here (see contrast).
        assertColor(program, 0.55, 0.50, r: 1, g: 0, b: 1, "B5 crop-remap: surviving PiP is magenta (correct remap)")
        assertColor(program, 0.65, 0.50, r: 1, g: 0, b: 1, "B5 crop-remap: surviving PiP magenta throughout")

        // PROOF the x=0.55 pixel discriminates a wrong remap: build the buggy
        // scene inline — clip the frame to the same sub-rect but KEEP the
        // original (un-remapped) crop — and show it reads YELLOW there.
        let inter = pipFrame.intersection(CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        let buggyA = Scene(name: "A.buggy", layers: [
            Layer(sourceID: redID, frame: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), zIndex: 0),
            Layer(sourceID: patID, frame: inter, crop: pipCrop, zIndex: 1),   // crop NOT remapped = the bug
        ])
        let buggyProgram = try compositor.composite(frames: frames,
                                                    scene: mergeOverlay(under: sceneB, over: buggyA),
                                                    pts: HouseClock.now())
        assertColor(buggyProgram, 0.55, 0.50, r: 1, g: 1, b: 0,
                    "B5 crop-remap contrast: un-remapped crop shows YELLOW at the load-bearing pixel")
        let correct = px(program, 0.55, 0.50), buggy = px(buggyProgram, 0.55, 0.50)
        XCTAssertGreaterThan(abs(correct.g - buggy.g), 0.5,
                             "B5 crop-remap: correct (magenta, g≈0) and bug (yellow, g≈1) MUST differ at x=0.55")
    }

    // MARK: - B5: live RenderLoop wipe wipes a sub-frame PiP (no bleed-through)

    /// The outgoing scene carries a sub-frame PiP in the region the wipe sweeps
    /// early. Through the real `RenderLoop.switchScene` path, at a mid-transition
    /// frame the PiP location must read the incoming scene (wiped), NOT the PiP —
    /// proving the fix holds live, not only in the deterministic schedule eval.
    func testLiveRenderLoopWipeWipesSubFramePiP() throws {
        let compositor = try makeCompositor()
        let canvas = try FXCanvas(width: W, height: H)
        let redID = SourceID("lwp.red"), blueID = SourceID("lwp.blue"), greenID = SourceID("lwp.green")
        let redBuf = try canvas.solid(RGBA(r: 1, g: 0, b: 0))
        let blueBuf = try canvas.solid(RGBA(r: 0, g: 0, b: 1))
        let greenBuf = try canvas.solid(RGBA(r: 0, g: 1, b: 0))

        // Outgoing A: full red + a sub-frame GREEN PiP on the LEFT (x∈[0.10,0.30]),
        // which wipe(.left) sweeps early. Incoming B: full blue.
        let sceneA = Scene(name: "A", layers: [
            Layer(sourceID: redID, zIndex: 0),
            Layer(sourceID: greenID, frame: CGRect(x: 0.10, y: 0.40, width: 0.20, height: 0.20), zIndex: 1),
        ])
        let sceneB = Scene(name: "B", layers: [Layer(sourceID: blueID, zIndex: 0)])

        let loop = RenderLoop(compositor: compositor, fps: 60)
        loop.scene = sceneA
        let redBox = FrameMailbox(), blueBox = FrameMailbox(), greenBox = FrameMailbox()
        loop.setMailbox(redBox, for: redID)
        loop.setMailbox(blueBox, for: blueID)
        loop.setMailbox(greenBox, for: greenID)

        struct Sample { let pip: RGBA; let right: RGBA }
        let samples = OSAllocatedUnfairLock<[Sample]>(initialState: [])
        loop.onProgramFrame = { f in
            let pip = FXCanvas.pixel(f.pixelBuffer, x: Int(0.20 * Double(self.W)), y: self.H / 2)
            let right = FXCanvas.pixel(f.pixelBuffer, x: Int(0.80 * Double(self.W)), y: self.H / 2)
            samples.withLock { $0.append(Sample(pip: pip, right: right)) }
        }
        let tPost = HouseClock.now()
        redBox.post(VideoFrame(pixelBuffer: redBuf, pts: tPost, source: redID))
        blueBox.post(VideoFrame(pixelBuffer: blueBuf, pts: tPost, source: blueID))
        greenBox.post(VideoFrame(pixelBuffer: greenBuf, pts: tPost, source: greenID))
        loop.start()
        Thread.sleep(forTimeInterval: 0.1)   // settle on A (red + green PiP)
        let spec = TransitionSpec(kind: .wipe(.left), duration: 0.3, easing: .linear)
        loop.switchScene(to: sceneB, transition: spec.schedule(outgoing: sceneA, incoming: sceneB))
        Thread.sleep(forTimeInterval: 0.5)   // transition (0.3s) + settle on pure B
        loop.stop()

        let all = samples.withLock { $0 }
        XCTAssertGreaterThan(all.count, 10, "loop delivered too few frames")
        XCTAssertEqual(loop.stats.transitionsCompleted, 1, "wipe did not complete/swap")
        XCTAssertEqual(loop.stats.compositeErrors, 0, "composite errors during live wipe")
        XCTAssertEqual(loop.scene.id, sceneB.id, "scene did not swap to B")

        func isBlue(_ p: RGBA) -> Bool { p.b > 0.6 && p.r < 0.4 && p.g < 0.4 }
        func isRed(_ p: RGBA) -> Bool { p.r > 0.6 && p.b < 0.4 && p.g < 0.4 }
        func isGreen(_ p: RGBA) -> Bool { p.g > 0.6 && p.r < 0.4 && p.b < 0.4 }

        // Sanity: the PiP is genuinely present pre-wipe (green over red A).
        XCTAssertTrue(isGreen(try XCTUnwrap(all.first).pip),
                      "sanity: first frame's PiP pixel is not the green PiP over red A")
        // Endpoint: settled on pure B.
        let last = try XCTUnwrap(all.last)
        XCTAssertTrue(isBlue(last.pip) && isBlue(last.right), "last frame not pure B (blue)")
        // KEY (B5 live): a mid-transition frame where the wipe has reached the PiP
        // (its location now reads the incoming B/blue) while the right side is
        // still outgoing A (red). A PiP that bled through unwiped would read GREEN
        // at its location throughout the transition, so no such frame exists and
        // this assertion fires.
        XCTAssertTrue(all.contains { isBlue($0.pip) && isRed($0.right) },
                      "B5 live: sub-frame PiP not wiped mid-transition (it bled through unwiped)")
    }

    // MARK: - T1: live TileMask LAYER effect reveals the background through holes

    /// The headline T1 proof: a `TileMask` applied to ONE opaque top layer, then
    /// composited over an opaque background through the REAL `MetalCompositor`
    /// with `premultipliedAlpha: true`, must show the BACKGROUND through the holed
    /// (revealed) cells — not black (the premultiplied-hole bug), not the top — and
    /// the top through the covered cells. This is the mechanism that makes the
    /// "blinking squares reveal what's underneath" work LIVE, per-layer, over
    /// whatever is beneath (not a baked A/B transition). Dumps a PNG to eyeball.
    func testLiveTileMaskLayerRevealsBackground() throws {
        let compositor = try makeCompositor()
        let canvas = try FXCanvas(width: W, height: H)
        let rows = 6, cols = 8

        let bgID = SourceID("tm.bg"), topID = SourceID("tm.top")
        let blue = RGBA(r: 0, g: 0, b: 1)                    // background
        let orange = RGBA(r: 0.95, g: 0.55, b: 0.10)        // opaque top
        let bg = try solidFrame(bgID, blue, canvas: canvas)
        let topSolid = try canvas.solid(orange)

        // gridWipe.right @ phase 0.5 → LEFT columns revealed (holes), RIGHT covered.
        let mask = try TileMask(width: W, height: H)
        let holed = try mask.apply(to: topSolid, rows: rows, cols: cols,
                                   mode: .gridWipe(direction: .right), phase: 0.5, softness: 0)
        let topFrame = VideoFrame(pixelBuffer: holed, pts: HouseClock.now(), source: topID)

        let scene = Scene(name: "tilemask", layers: [
            Layer(sourceID: bgID, zIndex: 0),
            Layer(sourceID: topID, zIndex: 1, premultipliedAlpha: true),   // honor the holes
        ])
        let program = try compositor.composite(frames: [bgID: bg, topID: topFrame],
                                               scene: scene, pts: HouseClock.now())

        let outDir = URL(fileURLWithPath:
            "/tmp/prism_tilefx_live")
        _ = try? FXCanvas.writePNG(program.pixelBuffer,
                               to: outDir.appendingPathComponent("tilemask_gridwipe_right_p50_over_blue.png"))
        // Also dump a flicker phase so the lead can see the ongoing-blink family.
        let flick = try mask.apply(to: topSolid, rows: rows, cols: cols,
                                   mode: .tileFlicker(seed: 5), phase: 0.35, softness: 0.1)
        let flickScene = Scene(name: "flick", layers: [
            Layer(sourceID: bgID, zIndex: 0),
            Layer(sourceID: topID, zIndex: 1, premultipliedAlpha: true),
        ])
        let flickProgram = try compositor.composite(frames: [bgID: bg,
            topID: VideoFrame(pixelBuffer: flick, pts: HouseClock.now(), source: topID)],
            scene: flickScene, pts: HouseClock.now())
        _ = try? FXCanvas.writePNG(flickProgram.pixelBuffer,
                               to: outDir.appendingPathComponent("tilemask_flicker_seed5_p35_over_blue.png"))

        func tileCenter(_ f: VideoFrame, _ r: Int, _ c: Int) -> RGBA {
            px(f, (Double(c) + 0.5) / Double(cols), (Double(r) + 0.5) / Double(rows))
        }
        func isBlue(_ p: RGBA) -> Bool { p.b > 0.6 && p.r < 0.4 && p.g < 0.4 }
        func isOrange(_ p: RGBA) -> Bool { p.r > 0.6 && p.g > 0.3 && p.b < 0.3 }
        func isBlack(_ p: RGBA) -> Bool { p.r < 0.15 && p.g < 0.15 && p.b < 0.15 }

        var revealed = 0, covered = 0
        for r in 0..<rows {
            // Leftmost column is fully revealed → BACKGROUND blue, never black/top.
            let left = tileCenter(program, r, 0)
            XCTAssertFalse(isBlack(left), "T1 revealed cell (r\(r),c0) is BLACK — premultiplied-hole bug (got \(left))")
            XCTAssertTrue(isBlue(left), "T1 revealed cell (r\(r),c0) not background blue (got \(left))")
            // Rightmost column is covered → the top (orange).
            let right = tileCenter(program, r, cols - 1)
            XCTAssertTrue(isOrange(right), "T1 covered cell (r\(r),c\(cols-1)) not top orange (got \(right))")
        }
        for r in 0..<rows { for c in 0..<cols {
            let p = tileCenter(program, r, c)
            XCTAssertFalse(isBlack(p), "T1 cell (r\(r),c\(c)) is BLACK (got \(p))")
            if isBlue(p) { revealed += 1 } else if isOrange(p) { covered += 1 }
        } }
        XCTAssertGreaterThan(revealed, 0, "T1: no cell revealed the background")
        XCTAssertGreaterThan(covered, 0, "T1: no cell kept the top")
    }

    // MARK: - B5/B4: live RenderLoop.switchScene wipe — endpoints + direction

    func testLiveRenderLoopWipeEndpointsAndDirection() throws {
        let compositor = try makeCompositor()
        let canvas = try FXCanvas(width: W, height: H)
        let redID = SourceID("lw.red"), blueID = SourceID("lw.blue")
        let redBuf = try canvas.solid(RGBA(r: 1, g: 0, b: 0))
        let blueBuf = try canvas.solid(RGBA(r: 0, g: 0, b: 1))

        let sceneA = Scene(name: "A", layers: [Layer(sourceID: redID, zIndex: 0)])
        let sceneB = Scene(name: "B", layers: [Layer(sourceID: blueID, zIndex: 0)])

        let loop = RenderLoop(compositor: compositor, fps: 60)
        loop.scene = sceneA
        let redBox = FrameMailbox(), blueBox = FrameMailbox()
        loop.setMailbox(redBox, for: redID)
        loop.setMailbox(blueBox, for: blueID)

        // Sample a LEFT and a RIGHT pixel each frame (small retention).
        struct Sample { let left: RGBA; let right: RGBA }
        let samples = OSAllocatedUnfairLock<[Sample]>(initialState: [])
        loop.onProgramFrame = { f in
            let l = FXCanvas.pixel(f.pixelBuffer, x: Int(0.15 * Double(self.W)), y: self.H / 2)
            let r = FXCanvas.pixel(f.pixelBuffer, x: Int(0.70 * Double(self.W)), y: self.H / 2)
            samples.withLock { $0.append(Sample(left: l, right: r)) }
        }
        let tPost = HouseClock.now()
        redBox.post(VideoFrame(pixelBuffer: redBuf, pts: tPost, source: redID))
        blueBox.post(VideoFrame(pixelBuffer: blueBuf, pts: tPost, source: blueID))
        loop.start()
        Thread.sleep(forTimeInterval: 0.1)   // settle on pure A (red)
        let spec = TransitionSpec(kind: .wipe(.left), duration: 0.2, easing: .linear)
        let completed = OSAllocatedUnfairLock<Scene?>(initialState: nil)
        loop.switchScene(to: sceneB, transition: spec.schedule(outgoing: sceneA, incoming: sceneB)) { s in
            completed.withLock { $0 = s }
        }
        Thread.sleep(forTimeInterval: 0.4)   // transition (0.2s) + settle on pure B (blue)
        loop.stop()

        let all = samples.withLock { $0 }
        XCTAssertGreaterThan(all.count, 10, "loop delivered too few frames")
        XCTAssertEqual(loop.stats.transitionsCompleted, 1, "wipe transition did not complete/swap")
        XCTAssertEqual(loop.stats.compositeErrors, 0, "composite errors during live wipe")
        XCTAssertEqual(loop.scene.id, sceneB.id, "scene did not swap to B")
        XCTAssertEqual(completed.withLock { $0 }?.id, sceneB.id, "completion missing/wrong scene")

        // (c) Endpoints exact: first frame pure A (red), last frame pure B (blue).
        let first = try XCTUnwrap(all.first)
        XCTAssertGreaterThan(first.left.r, 0.9); XCTAssertLessThan(first.left.b, 0.1)
        XCTAssertGreaterThan(first.right.r, 0.9); XCTAssertLessThan(first.right.b, 0.1)
        let last = try XCTUnwrap(all.last)
        XCTAssertGreaterThan(last.left.b, 0.9); XCTAssertLessThan(last.left.r, 0.1)
        XCTAssertGreaterThan(last.right.b, 0.9); XCTAssertLessThan(last.right.r, 0.1)

        // (b) Direction: wipe(.left) reveals B from the LEFT — some mid frame has
        // the left pixel already B (blue) while the right is still A (red).
        let directional = all.contains { $0.left.b > 0.6 && $0.left.r < 0.4 && $0.right.r > 0.6 && $0.right.b < 0.4 }
        XCTAssertTrue(directional, "no frame showed B on the left while A on the right during wipe(.left)")
    }

    // MARK: - B5/B9: live RenderLoop.switchScene push — endpoints + completion

    func testLiveRenderLoopPushEndpoints() throws {
        let compositor = try makeCompositor()
        let canvas = try FXCanvas(width: W, height: H)
        let redID = SourceID("lp.red"), blueID = SourceID("lp.blue")
        let redBuf = try canvas.solid(RGBA(r: 1, g: 0, b: 0))
        let blueBuf = try canvas.solid(RGBA(r: 0, g: 0, b: 1))
        let sceneA = Scene(name: "A", layers: [Layer(sourceID: redID, zIndex: 0)])
        let sceneB = Scene(name: "B", layers: [Layer(sourceID: blueID, zIndex: 0)])

        let loop = RenderLoop(compositor: compositor, fps: 60)
        loop.scene = sceneA
        let redBox = FrameMailbox(), blueBox = FrameMailbox()
        loop.setMailbox(redBox, for: redID)
        loop.setMailbox(blueBox, for: blueID)
        let centre = OSAllocatedUnfairLock<[RGBA]>(initialState: [])
        loop.onProgramFrame = { f in
            centre.withLock { $0.append(FXCanvas.pixel(f.pixelBuffer, x: self.W / 2, y: self.H / 2)) }
        }
        let tPost = HouseClock.now()
        redBox.post(VideoFrame(pixelBuffer: redBuf, pts: tPost, source: redID))
        blueBox.post(VideoFrame(pixelBuffer: blueBuf, pts: tPost, source: blueID))
        loop.start()
        Thread.sleep(forTimeInterval: 0.1)
        let spec = TransitionSpec(kind: .push(.left), duration: 0.2, easing: .easeInOut)
        loop.switchScene(to: sceneB, transition: spec.schedule(outgoing: sceneA, incoming: sceneB))
        Thread.sleep(forTimeInterval: 0.4)
        loop.stop()

        let all = centre.withLock { $0 }
        XCTAssertEqual(loop.stats.transitionsCompleted, 1, "push did not complete")
        XCTAssertEqual(loop.stats.compositeErrors, 0, "composite errors during live push")
        XCTAssertEqual(loop.scene.id, sceneB.id, "scene did not swap to B")
        let first = try XCTUnwrap(all.first)
        XCTAssertGreaterThan(first.r, 0.9, "push start not pure A (red)")
        let last = try XCTUnwrap(all.last)
        XCTAssertGreaterThan(last.b, 0.9, "push end not pure B (blue)")
    }

    // MARK: - Live-GPU pixel/tile effects (the nil→crossfade fix)

    /// Directory for the eyeball-able live-GPU FX PNG dumps.
    private static let fxDumpDir = URL(fileURLWithPath:
        "/tmp/prism_gpu_fx")

    /// Drive one pixel/tile kind through the REAL `MetalCompositor` FX path at
    /// `progress` (linear easing → eased == raw == progress), returning the live
    /// GPU program frame. This is exactly what `RenderLoop`'s `.effect` blend
    /// runs — the schedule is non-nil (the bug fix) and carries a GPU effect.
    private func gpuEffect(_ compositor: MetalCompositor, _ spec: TransitionSpec,
                           a: VideoFrame, b: VideoFrame, aID: SourceID, bID: SourceID,
                           progress: Double) throws -> VideoFrame {
        let sceneA = Scene(name: "A", layers: [Layer(sourceID: aID, zIndex: 0)])
        let sceneB = Scene(name: "B", layers: [Layer(sourceID: bID, zIndex: 0)])
        let sched = try XCTUnwrap(spec.schedule(outgoing: sceneA, incoming: sceneB),
                                  "\(spec.kind.label): schedule() returned nil (the bug)")
        guard case .effect(let fx) = sched.blend else {
            XCTFail("\(spec.kind.label): expected .effect blend, got \(sched.blend)")
            throw XCTSkip("no effect blend")
        }
        let elapsed = progress * spec.duration
        let e = Float(sched.progress(elapsed))
        let raw = Float(sched.rawProgress?(elapsed) ?? Double(e))
        return try compositor.composite(frames: [aID: a, bID: b],
                                        sceneA: sceneA, sceneB: sceneB,
                                        effect: fx, progress: e, rawProgress: raw,
                                        pts: HouseClock.now())
    }

    /// Assert the live GPU frame matches the CPU `TransitionRenderer` ground
    /// truth for the same kind/progress within `tol` (mean per-channel diff).
    @discardableResult
    private func assertMatchesCPU(_ gpu: VideoFrame, _ renderer: TransitionRenderer,
                                  a: CVPixelBuffer, b: CVPixelBuffer, spec: TransitionSpec,
                                  progress: Double, tol: Double, _ what: String) throws -> Double {
        let cpu = try renderer.render(a: a, b: b, spec: spec, progress: progress)
        let d = FXCanvas.meanDiff(gpu.pixelBuffer, cpu, step: 4)
        XCTAssertLessThan(d, tol, "\(what): GPU vs CPU meanDiff \(d) ≥ tol \(tol)")
        return d
    }

    private func tileCenter(_ f: VideoFrame, _ r: Int, _ c: Int, rows: Int, cols: Int) -> RGBA {
        px(f, (Double(c) + 0.5) / Double(cols), (Double(r) + 0.5) / Double(rows))
    }
    private func isBlue(_ p: RGBA) -> Bool { p.b > 0.55 && p.r < 0.45 && p.g < 0.45 }
    private func isRed(_ p: RGBA) -> Bool { p.r > 0.55 && p.b < 0.45 && p.g < 0.45 }
    private func isBlack(_ p: RGBA) -> Bool { p.r < 0.12 && p.g < 0.12 && p.b < 0.12 }
    private func isWhite(_ p: RGBA) -> Bool { p.r > 0.85 && p.g > 0.85 && p.b > 0.85 }

    private func dump(_ f: VideoFrame, _ name: String) {
        _ = try? FXCanvas.writePNG(f.pixelBuffer, to: Self.fxDumpDir.appendingPathComponent(name))
    }

    /// The five PIXEL-effect kinds, LIVE through `MetalCompositor`: endpoints
    /// (p0==A, p1==B via the compositor's short-circuit), the correct mid-effect,
    /// and a match against the CPU `TransitionRenderer` for the same math.
    func testLiveGPUPixelEffectsMatchCPUAndEndpoints() throws {
        let compositor = try makeCompositor()
        let canvas = try FXCanvas(width: W, height: H)
        let renderer = try TransitionRenderer(width: W, height: H)

        let aID = SourceID("fx.a"), bID = SourceID("fx.b")
        let red = RGBA(r: 1, g: 0, b: 0), blue = RGBA(r: 0, g: 0, b: 1)
        let redBuf = try canvas.solid(red), blueBuf = try canvas.solid(blue)
        let aF = VideoFrame(pixelBuffer: redBuf, pts: HouseClock.now(), source: aID)
        let bF = VideoFrame(pixelBuffer: blueBuf, pts: HouseClock.now(), source: bID)

        // Patterned buffers so glitch's channel-split is actually visible.
        let bandsBuf = try bands4(canvas)                       // green|yellow|magenta|cyan
        let darkBuf = try canvas.solid(RGBA(r: 0, g: 0, b: 0))
        let bandsF = VideoFrame(pixelBuffer: bandsBuf, pts: HouseClock.now(), source: aID)
        let darkF = VideoFrame(pixelBuffer: darkBuf, pts: HouseClock.now(), source: bID)

        func endpoints(_ spec: TransitionSpec, a: VideoFrame, b: VideoFrame,
                       aBuf: CVPixelBuffer, bBuf: CVPixelBuffer, _ label: String) throws {
            let p0 = try gpuEffect(compositor, spec, a: a, b: b, aID: aID, bID: bID, progress: 0)
            let p1 = try gpuEffect(compositor, spec, a: a, b: b, aID: aID, bID: bID, progress: 1)
            let a0 = px(p0, 0.5, 0.5), aRef = FXCanvas.pixel(aBuf, x: W / 2, y: H / 2)
            let b1 = px(p1, 0.5, 0.5), bRef = FXCanvas.pixel(bBuf, x: W / 2, y: H / 2)
            XCTAssertEqual(a0.r, aRef.r, accuracy: 0.03, "\(label) p0==A R")
            XCTAssertEqual(a0.b, aRef.b, accuracy: 0.03, "\(label) p0==A B")
            XCTAssertEqual(b1.r, bRef.r, accuracy: 0.03, "\(label) p1==B R")
            XCTAssertEqual(b1.b, bRef.b, accuracy: 0.03, "\(label) p1==B B")
        }

        // ── iris: mid = B inside a centre circle over A ──────────────────────
        let iris = TransitionSpec(kind: .iris, duration: 0.5, easing: .linear)
        try endpoints(iris, a: aF, b: bF, aBuf: redBuf, bBuf: blueBuf, "iris")
        let irisMid = try gpuEffect(compositor, iris, a: aF, b: bF, aID: aID, bID: bID, progress: 0.5)
        dump(irisMid, "iris_mid.png")
        XCTAssertTrue(isBlue(px(irisMid, 0.5, 0.5)), "iris mid centre not B (got \(px(irisMid,0.5,0.5)))")
        XCTAssertTrue(isRed(px(irisMid, 0.02, 0.02)), "iris mid corner not A (got \(px(irisMid,0.02,0.02)))")
        let dIris = try assertMatchesCPU(irisMid, renderer, a: redBuf, b: blueBuf, spec: iris, progress: 0.5, tol: 0.02, "iris")

        // ── zoomBlur: mid = blend of A and B (neither pure) ──────────────────
        let zoom = TransitionSpec(kind: .zoomBlur, duration: 0.5, easing: .linear)
        try endpoints(zoom, a: aF, b: bF, aBuf: redBuf, bBuf: blueBuf, "zoomBlur")
        let zoomMid = try gpuEffect(compositor, zoom, a: aF, b: bF, aID: aID, bID: bID, progress: 0.5)
        dump(zoomMid, "zoomblur_mid.png")
        let zc = px(zoomMid, 0.5, 0.5)
        XCTAssertTrue(zc.r > 0.2 && zc.b > 0.2, "zoomBlur mid centre not a red↔blue blend (got \(zc))")
        let dZoom = try assertMatchesCPU(zoomMid, renderer, a: redBuf, b: blueBuf, spec: zoom, progress: 0.5, tol: 0.03, "zoomBlur")

        // ── glitch: mid has an RGB channel-split (differs from a plain dissolve) ─
        let glitch = TransitionSpec(kind: .glitch, duration: 0.5, easing: .linear)
        try endpoints(glitch, a: bandsF, b: darkF, aBuf: bandsBuf, bBuf: darkBuf, "glitch")
        let glitchMid = try gpuEffect(compositor, glitch, a: bandsF, b: darkF, aID: aID, bID: bID, progress: 0.5)
        dump(glitchMid, "glitch_mid.png")
        let dissolveMid = try renderer.render(a: bandsBuf, b: darkBuf,
            spec: TransitionSpec(kind: .dissolve, duration: 0.5, easing: .linear), progress: 0.5)
        let splitDiff = FXCanvas.meanDiff(glitchMid.pixelBuffer, dissolveMid, step: 4)
        XCTAssertGreaterThan(splitDiff, 0.01, "glitch mid shows no channel-split vs a plain dissolve (\(splitDiff))")
        let dGlitch = try assertMatchesCPU(glitchMid, renderer, a: bandsBuf, b: darkBuf, spec: glitch, progress: 0.5, tol: 0.05, "glitch")

        // ── animeFlash: mid (p=0.5) blows to white ───────────────────────────
        let flash = TransitionSpec(kind: .animeFlash, duration: 0.5, easing: .linear)
        try endpoints(flash, a: aF, b: bF, aBuf: redBuf, bBuf: blueBuf, "animeFlash")
        let flashMid = try gpuEffect(compositor, flash, a: aF, b: bF, aID: aID, bID: bID, progress: 0.5)
        dump(flashMid, "animeflash_mid.png")
        XCTAssertTrue(isWhite(px(flashMid, 0.5, 0.5)), "animeFlash mid not white (got \(px(flashMid,0.5,0.5)))")
        let dFlash = try assertMatchesCPU(flashMid, renderer, a: redBuf, b: blueBuf, spec: flash, progress: 0.5, tol: 0.02, "animeFlash")

        // ── speedline: mid brighter than a plain dissolve (white wedges) ─────
        let speed = TransitionSpec(kind: .speedline, duration: 0.5, easing: .linear)
        try endpoints(speed, a: aF, b: bF, aBuf: redBuf, bBuf: blueBuf, "speedline")
        let speedMid = try gpuEffect(compositor, speed, a: aF, b: bF, aID: aID, bID: bID, progress: 0.5)
        dump(speedMid, "speedline_mid.png")
        let dissolveRB = try renderer.render(a: redBuf, b: blueBuf,
            spec: TransitionSpec(kind: .dissolve, duration: 0.5, easing: .linear), progress: 0.5)
        XCTAssertGreaterThan(FXCanvas.meanLuma(speedMid.pixelBuffer), FXCanvas.meanLuma(dissolveRB) + 0.02,
                             "speedline mid not brighter than a plain dissolve (no white wedges?)")
        let dSpeed = try assertMatchesCPU(speedMid, renderer, a: redBuf, b: blueBuf, spec: speed, progress: 0.5, tol: 0.04, "speedline")

        print("LIVE-GPU pixel FX vs CPU meanDiff — iris \(dIris), zoomBlur \(dZoom), glitch \(dGlitch) (splitΔ \(splitDiff)), animeFlash \(dFlash), speedline \(dSpeed)")
    }

    /// The five TILE kinds, LIVE through `MetalCompositor`: the premultiplied
    /// hole reveals B (never black), the correct per-kind reveal pattern at mid,
    /// endpoints, and a CPU `TransitionRenderer` match.
    func testLiveGPUTileEffectsMatchCPUAndEndpoints() throws {
        let compositor = try makeCompositor()
        let canvas = try FXCanvas(width: W, height: H)
        let renderer = try TransitionRenderer(width: W, height: H)
        let rows = 6, cols = 8

        let aID = SourceID("tf.a"), bID = SourceID("tf.b")
        let redBuf = try canvas.solid(RGBA(r: 1, g: 0, b: 0))
        let blueBuf = try canvas.solid(RGBA(r: 0, g: 0, b: 1))
        let aF = VideoFrame(pixelBuffer: redBuf, pts: HouseClock.now(), source: aID)
        let bF = VideoFrame(pixelBuffer: blueBuf, pts: HouseClock.now(), source: bID)

        func noBlackAnywhere(_ f: VideoFrame, _ label: String) {
            for r in 0..<rows { for c in 0..<cols {
                let p = tileCenter(f, r, c, rows: rows, cols: cols)
                XCTAssertFalse(isBlack(p), "\(label): tile (r\(r),c\(c)) is BLACK — premultiplied-hole bug (got \(p))")
            } }
        }
        func endpoints(_ spec: TransitionSpec, _ label: String) throws {
            let p0 = try gpuEffect(compositor, spec, a: aF, b: bF, aID: aID, bID: bID, progress: 0)
            let p1 = try gpuEffect(compositor, spec, a: aF, b: bF, aID: aID, bID: bID, progress: 1)
            XCTAssertTrue(isRed(px(p0, 0.5, 0.5)), "\(label) p0==A (red) got \(px(p0,0.5,0.5))")
            XCTAssertTrue(isBlue(px(p1, 0.5, 0.5)), "\(label) p1==B (blue) got \(px(p1,0.5,0.5))")
        }

        // ── blockDissolve: scattered tiles reveal B; some still A; none black ─
        let block = TransitionSpec(kind: .blockDissolve(rows: rows, cols: cols, seed: 42, softness: 0),
                                   duration: 0.5, easing: .linear)
        try endpoints(block, "blockDissolve")
        let blockMid = try gpuEffect(compositor, block, a: aF, b: bF, aID: aID, bID: bID, progress: 0.5)
        dump(blockMid, "blockdissolve_mid.png")
        noBlackAnywhere(blockMid, "blockDissolve")
        var revealed = 0, covered = 0
        for r in 0..<rows { for c in 0..<cols {
            let p = tileCenter(blockMid, r, c, rows: rows, cols: cols)
            if isBlue(p) { revealed += 1 } else if isRed(p) { covered += 1 }
        } }
        XCTAssertGreaterThan(revealed, 0, "blockDissolve mid revealed NO tiles to B")
        XCTAssertGreaterThan(covered, 0, "blockDissolve mid kept NO tiles on A")
        let dBlock = try assertMatchesCPU(blockMid, renderer, a: redBuf, b: blueBuf, spec: block, progress: 0.5, tol: 0.06, "blockDissolve")

        // ── gridWipe.right: at 0.5 LEFT columns revealed (B), RIGHT covered (A) ─
        let grid = TransitionSpec(kind: .gridWipe(rows: rows, cols: cols, direction: .right, softness: 0),
                                  duration: 0.5, easing: .linear)
        try endpoints(grid, "gridWipe")
        let gridMid = try gpuEffect(compositor, grid, a: aF, b: bF, aID: aID, bID: bID, progress: 0.5)
        dump(gridMid, "gridwipe_right_mid.png")
        noBlackAnywhere(gridMid, "gridWipe")
        XCTAssertTrue(isBlue(tileCenter(gridMid, rows / 2, 0, rows: rows, cols: cols)), "gridWipe.right mid: left column not revealed B")
        XCTAssertTrue(isRed(tileCenter(gridMid, rows / 2, cols - 1, rows: rows, cols: cols)), "gridWipe.right mid: right column not covered A")
        let dGrid = try assertMatchesCPU(gridMid, renderer, a: redBuf, b: blueBuf, spec: grid, progress: 0.5, tol: 0.03, "gridWipe")

        // ── checkerboard: at 0.5 even tiles = B, odd tiles = A ────────────────
        let check = TransitionSpec(kind: .checkerboard(rows: rows, cols: cols, softness: 0),
                                   duration: 0.5, easing: .linear)
        try endpoints(check, "checkerboard")
        let checkMid = try gpuEffect(compositor, check, a: aF, b: bF, aID: aID, bID: bID, progress: 0.5)
        dump(checkMid, "checkerboard_mid.png")
        noBlackAnywhere(checkMid, "checkerboard")
        XCTAssertTrue(isBlue(tileCenter(checkMid, 0, 0, rows: rows, cols: cols)), "checkerboard mid: even tile (0,0) not B")
        XCTAssertTrue(isRed(tileCenter(checkMid, 0, 1, rows: rows, cols: cols)), "checkerboard mid: odd tile (0,1) not A")
        let dCheck = try assertMatchesCPU(checkMid, renderer, a: redBuf, b: blueBuf, spec: check, progress: 0.5, tol: 0.03, "checkerboard")

        // ── tileReveal: at 0.5 each tile's CENTRE = B, its corner still A ─────
        let reveal = TransitionSpec(kind: .tileReveal(rows: rows, cols: cols, softness: 0),
                                    duration: 0.5, easing: .linear)
        try endpoints(reveal, "tileReveal")
        let revealMid = try gpuEffect(compositor, reveal, a: aF, b: bF, aID: aID, bID: bID, progress: 0.5)
        dump(revealMid, "tilereveal_mid.png")
        noBlackAnywhere(revealMid, "tileReveal")
        // Tile (2,3) centre = B; a point near its corner = A.
        XCTAssertTrue(isBlue(tileCenter(revealMid, 2, 3, rows: rows, cols: cols)), "tileReveal mid: tile centre not revealed B")
        XCTAssertTrue(isRed(px(revealMid, (3.0 + 0.06) / Double(cols), (2.0 + 0.06) / Double(rows))), "tileReveal mid: tile corner not still A")
        let dReveal = try assertMatchesCPU(revealMid, renderer, a: redBuf, b: blueBuf, spec: reveal, progress: 0.5, tol: 0.03, "tileReveal")

        // ── tileFlicker: CONTINUOUS — some tiles B, some A, none black; matches CPU.
        // (No p0==A/p1==B: the endpoints are the same loop point, by design.)
        let flick = TransitionSpec(kind: .tileFlicker(rows: rows, cols: cols, seed: 5, softness: 0.1),
                                   duration: 1.0, easing: .linear)
        let flickMid = try gpuEffect(compositor, flick, a: aF, b: bF, aID: aID, bID: bID, progress: 0.3)
        dump(flickMid, "tileflicker_p30.png")
        noBlackAnywhere(flickMid, "tileFlicker")
        var fRev = 0, fCov = 0
        for r in 0..<rows { for c in 0..<cols {
            let p = tileCenter(flickMid, r, c, rows: rows, cols: cols)
            if p.b > 0.5 { fRev += 1 } else if p.r > 0.5 { fCov += 1 }
        } }
        XCTAssertGreaterThan(fRev, 0, "tileFlicker: no tile toward B")
        XCTAssertGreaterThan(fCov, 0, "tileFlicker: no tile toward A")
        let dFlick = try assertMatchesCPU(flickMid, renderer, a: redBuf, b: blueBuf, spec: flick, progress: 0.3, tol: 0.06, "tileFlicker")

        print("LIVE-GPU tile FX vs CPU meanDiff — blockDissolve \(dBlock), gridWipe \(dGrid), checkerboard \(dCheck), tileReveal \(dReveal), tileFlicker \(dFlick)")
    }

    /// End-to-end proof the nil→crossfade bug is gone: an `iris` scene-switch
    /// driven by the REAL `RenderLoop.switchScene` produces a genuine iris
    /// mid-frame (B in a centre circle over A) — NOT a uniform crossfade blend.
    func testLiveRenderLoopIrisRunsNativeGPU() throws {
        let compositor = try makeCompositor()
        let canvas = try FXCanvas(width: W, height: H)
        let redID = SourceID("li.red"), blueID = SourceID("li.blue")
        let redBuf = try canvas.solid(RGBA(r: 1, g: 0, b: 0))
        let blueBuf = try canvas.solid(RGBA(r: 0, g: 0, b: 1))
        let sceneA = Scene(name: "A", layers: [Layer(sourceID: redID, zIndex: 0)])
        let sceneB = Scene(name: "B", layers: [Layer(sourceID: blueID, zIndex: 0)])

        let loop = RenderLoop(compositor: compositor, fps: 60)
        loop.scene = sceneA
        let redBox = FrameMailbox(), blueBox = FrameMailbox()
        loop.setMailbox(redBox, for: redID)
        loop.setMailbox(blueBox, for: blueID)

        // Per frame: sample the centre and a corner. An iris shows B at the
        // centre while the corner is still A for a mid-transition frame; a
        // crossfade would blend the WHOLE frame uniformly (corner == centre).
        struct S { let centre: RGBA; let corner: RGBA }
        let samples = OSAllocatedUnfairLock<[S]>(initialState: [])
        loop.onProgramFrame = { f in
            let cN = FXCanvas.pixel(f.pixelBuffer, x: self.W / 2, y: self.H / 2)
            let cr = FXCanvas.pixel(f.pixelBuffer, x: Int(0.02 * Double(self.W)), y: Int(0.02 * Double(self.H)))
            samples.withLock { $0.append(S(centre: cN, corner: cr)) }
        }
        let tPost = HouseClock.now()
        redBox.post(VideoFrame(pixelBuffer: redBuf, pts: tPost, source: redID))
        blueBox.post(VideoFrame(pixelBuffer: blueBuf, pts: tPost, source: blueID))
        loop.start()
        Thread.sleep(forTimeInterval: 0.1)   // settle on A (red)
        let spec = TransitionSpec(kind: .iris, duration: 0.3, easing: .linear)
        loop.switchScene(to: sceneB, transition: spec.schedule(outgoing: sceneA, incoming: sceneB))
        Thread.sleep(forTimeInterval: 0.5)   // transition + settle on B
        loop.stop()

        let all = samples.withLock { $0 }
        XCTAssertGreaterThan(all.count, 10, "loop delivered too few frames")
        XCTAssertEqual(loop.stats.transitionsCompleted, 1, "iris transition did not complete/swap")
        XCTAssertEqual(loop.stats.compositeErrors, 0, "composite errors during live iris")
        XCTAssertEqual(loop.scene.id, sceneB.id, "scene did not swap to B")
        // Endpoints: first pure A (red), last pure B (blue).
        XCTAssertTrue(isRed(try XCTUnwrap(all.first).centre), "iris start not pure A (red)")
        XCTAssertTrue(isBlue(try XCTUnwrap(all.last).centre), "iris end not pure B (blue)")
        // KEY: a real iris frame — centre already B (blue) while the corner is
        // still A (red). A crossfade degrade could NEVER produce this (it blends
        // the whole frame the same), so its absence proves native GPU iris.
        XCTAssertTrue(all.contains { self.isBlue($0.centre) && self.isRed($0.corner) },
                      "no native-iris frame (centre B, corner A) — did it degrade to a crossfade?")
    }

    // MARK: - Helpers

    /// Merge two scenes into one layer stack: `under` first, `over` on top
    /// (mirrors the RenderLoop `.overlay` stack, incoming under / outgoing over).
    private func mergeOverlay(under: Scene, over: Scene) -> Scene {
        let base = (under.layers.map(\.zIndex).max() ?? 0) + 100
        var layers = under.layers
        for l in over.layers {
            var nl = l
            nl.zIndex = l.zIndex + base
            layers.append(nl)
        }
        return Scene(name: "\(under.name)+\(over.name)", layers: layers)
    }

    private func pollUntil(_ timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline { return predicate() }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }
}
