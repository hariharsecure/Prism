import CoreMedia
import CoreVideo
import Foundation
import Metal
import os
import PrismCore

/// Headless self-verification of the compositor (no TCC, no hardware capture).
///
/// TEST CODE ONLY: this file locks pixel-buffer base addresses to fill
/// synthetic inputs and read back the program output. That is explicitly
/// allowed here and **forbidden on the engine hot path** — the compositor
/// itself never touches pixels on the CPU.
///
/// The integrator can wire `CompositorSelfTest.run()` into prism-dev or an
/// XCTest target; it throws with a precise message on the first mismatch.
public enum CompositorSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case setupFailed(String)
        case mismatch(String)
        public var description: String {
            switch self {
            case .setupFailed(let s): return "self-test setup failed: \(s)"
            case .mismatch(let s): return "self-test mismatch: \(s)"
            }
        }
    }

    /// Composites synthetic BGRA + biplanar-YUV frames into a 1280x720
    /// program and asserts output pixels at known coordinates, covering:
    /// BGRA path, 420f full-range and 420v video-range matrices, opacity
    /// blending, hidden layers, last-known-frame retention, crop mapping,
    /// a short live `RenderLoop` run through `FrameMailbox`es, the transition
    /// mix stage (crossfade endpoints/midpoint, overlapping content, overlay
    /// stack), and a live `RenderLoop.switchScene` crossfade that must blend,
    /// complete, and swap scenes.
    public static func run() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SelfTestError.setupFailed("no Metal device")
        }
        let compositor = try MetalCompositor(device: device, width: 1280, height: 720)

        // --- Synthetic inputs (CPU fill BEFORE wrapping — test-only) ---
        let srcW = 640, srcH = 360
        let bgraPool = try PixelBufferPool(width: srcW, height: srcH, pixelFormat: kCVPixelFormatType_32BGRA)
        let yuvFullPool = try PixelBufferPool(width: srcW, height: srcH,
                                              pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        let yuvVideoPool = try PixelBufferPool(width: srcW, height: srcH,
                                               pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        // Solid red BGRA.
        let redBuffer = try bgraPool.makeBuffer()
        fillBGRA(redBuffer, left: (b: 0, g: 0, r: 255), right: nil)
        // Solid green, 420f: full-range BT.709 → Y=182 Cb=30 Cr=12.
        let greenBuffer = try yuvFullPool.makeBuffer()
        fillBiplanarYUV(greenBuffer, y: 182, cb: 30, cr: 12)
        // Solid blue, 420v: video-range BT.709 → Y=32 Cb=240 Cr=118.
        let blueBuffer = try yuvVideoPool.makeBuffer()
        fillBiplanarYUV(blueBuffer, y: 32, cb: 240, cr: 118)

        let camID = SourceID("selftest.bgra")
        let yuvID = SourceID("selftest.420f")
        let vidID = SourceID("selftest.420v")
        let t0 = HouseClock.now()
        let frames: [SourceID: VideoFrame] = [
            camID: VideoFrame(pixelBuffer: redBuffer, pts: t0, source: camID),
            yuvID: VideoFrame(pixelBuffer: greenBuffer, pts: t0, source: yuvID),
            vidID: VideoFrame(pixelBuffer: blueBuffer, pts: t0, source: vidID),
        ]

        // --- Scene: red base + quadrant overlays exercising each path ---
        let scene = Scene(name: "selftest", layers: [
            Layer(sourceID: camID, zIndex: 0),                                                      // full-canvas red
            Layer(sourceID: yuvID, frame: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), zIndex: 1), // 420f green, bottom-right
            Layer(sourceID: vidID, frame: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), zIndex: 2),   // 420v blue, top-right
            Layer(sourceID: yuvID, frame: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
                  opacity: 0.5, zIndex: 3),                                                         // 50% green over red, bottom-left
            Layer(sourceID: vidID, frame: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                  zIndex: 4, isHidden: true),                                                       // hidden — must not draw
            Layer(sourceID: SourceID("selftest.missing"), zIndex: 5),                               // missing — must be skipped
        ])

        func checkQuadrants(_ program: VideoFrame, pass: String) throws {
            try expect(program, x: 100, y: 100, r: 255, g: 0, b: 0, tol: 3, what: "\(pass): top-left red (hidden layer skipped)")
            try expect(program, x: 960, y: 540, r: 0, g: 255, b: 0, tol: 4, what: "\(pass): bottom-right 420f green")
            try expect(program, x: 960, y: 180, r: 0, g: 0, b: 255, tol: 4, what: "\(pass): top-right 420v blue")
            try expect(program, x: 320, y: 540, r: 128, g: 128, b: 0, tol: 6, what: "\(pass): bottom-left 50% green over red")
        }

        // Pass 1: fresh frames.
        let program1 = try compositor.composite(frames: frames, scene: scene, pts: t0)
        guard program1.width == 1280, program1.height == 720,
              program1.pixelFormat == kCVPixelFormatType_32BGRA else {
            throw SelfTestError.mismatch("program frame is \(program1.width)x\(program1.height) fmt \(program1.pixelFormat), expected 1280x720 BGRA")
        }
        try checkQuadrants(program1, pass: "pass1")

        // Pass 2: NO new frames — last-known frames must keep the program identical
        // (a 30 fps source in a 60 fps program).
        let program2 = try compositor.composite(frames: [:], scene: scene, pts: CMTimeAdd(t0, CMTime(value: 1, timescale: 60)))
        try checkQuadrants(program2, pass: "pass2 (last-known frames)")

        // Pass 3: crop. Source is left-half red / right-half white; a full-canvas
        // layer cropped to the source's right half must render all white.
        let splitBuffer = try bgraPool.makeBuffer()
        fillBGRA(splitBuffer, left: (b: 0, g: 0, r: 255), right: (b: 255, g: 255, r: 255))
        let splitID = SourceID("selftest.split")
        let cropScene = Scene(name: "selftest.crop", layers: [
            Layer(sourceID: splitID, crop: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)),
        ])
        let program3 = try compositor.composite(
            frames: [splitID: VideoFrame(pixelBuffer: splitBuffer, pts: t0, source: splitID)],
            scene: cropScene, pts: CMTimeAdd(t0, CMTime(value: 2, timescale: 60)))
        try expect(program3, x: 100, y: 360, r: 255, g: 255, b: 255, tol: 3, what: "pass3: crop right-half → white at left")
        try expect(program3, x: 1180, y: 360, r: 255, g: 255, b: 255, tol: 3, what: "pass3: crop right-half → white at right")

        // --- RenderLoop: tick through mailboxes for ~0.3 s at 60 fps ---
        let loop = RenderLoop(compositor: compositor, fps: 60)
        loop.scene = scene
        let camBox = FrameMailbox(), yuvBox = FrameMailbox(), vidBox = FrameMailbox()
        loop.setMailbox(camBox, for: camID)
        loop.setMailbox(yuvBox, for: yuvID)
        loop.setMailbox(vidBox, for: vidID)
        let collected = OSAllocatedUnfairLock<[VideoFrame]>(initialState: [])
        loop.onProgramFrame = { frame in collected.withLock { $0.append(frame) } }
        let tPost = HouseClock.now()
        camBox.post(VideoFrame(pixelBuffer: redBuffer, pts: tPost, source: camID))
        yuvBox.post(VideoFrame(pixelBuffer: greenBuffer, pts: tPost, source: yuvID))
        vidBox.post(VideoFrame(pixelBuffer: blueBuffer, pts: tPost, source: vidID))
        loop.start()
        Thread.sleep(forTimeInterval: 0.3)
        loop.stop()
        let programFrames = collected.withLock { $0 }
        let stats = loop.stats
        guard programFrames.count >= 10 else {
            throw SelfTestError.mismatch("render loop delivered \(programFrames.count) frames in 0.3 s @60fps (expected ≥10); stats=\(stats)")
        }
        guard stats.compositeErrors == 0 else {
            throw SelfTestError.mismatch("render loop hit \(stats.compositeErrors) composite errors")
        }
        // Frames were posted once; later ticks ran on last-known frames.
        try checkQuadrants(programFrames[programFrames.count - 1], pass: "renderloop last frame")
        // PTS must be monotonically increasing at ~1/60 s.
        for i in 1..<programFrames.count where CMTimeCompare(programFrames[i].pts, programFrames[i - 1].pts) <= 0 {
            throw SelfTestError.mismatch("render loop PTS not monotonic at frame \(i)")
        }

        // --- Mix stage: crossfade correctness (scene-A/scene-B composite) ---
        let blueBGRABuffer = try bgraPool.makeBuffer()
        fillBGRA(blueBGRABuffer, left: (b: 255, g: 0, r: 0), right: nil)
        let blueID = SourceID("selftest.blue")
        let sceneRed = Scene(name: "mix.red", layers: [Layer(sourceID: camID)])   // full-canvas red
        let sceneBlue = Scene(name: "mix.blue", layers: [Layer(sourceID: blueID)]) // full-canvas blue
        let mixFrames: [SourceID: VideoFrame] = [
            camID: VideoFrame(pixelBuffer: redBuffer, pts: t0, source: camID),
            blueID: VideoFrame(pixelBuffer: blueBGRABuffer, pts: t0, source: blueID),
        ]
        let tMix = CMTimeAdd(t0, CMTime(value: 3, timescale: 60))

        let mix0 = try compositor.composite(frames: mixFrames, sceneA: sceneRed, sceneB: sceneBlue,
                                            mix: 0, pts: tMix)
        try expect(mix0, x: 640, y: 360, r: 255, g: 0, b: 0, tol: 1, what: "mix=0: pure scene A (red)")
        let mix1 = try compositor.composite(frames: [:], sceneA: sceneRed, sceneB: sceneBlue,
                                            mix: 1, pts: tMix)
        try expect(mix1, x: 640, y: 360, r: 0, g: 0, b: 255, tol: 1, what: "mix=1: pure scene B (blue)")
        let mixHalf = try compositor.composite(frames: [:], sceneA: sceneRed, sceneB: sceneBlue,
                                               mix: 0.5, pts: tMix)
        try expect(mixHalf, x: 640, y: 360, r: 127, g: 0, b: 127, tol: 3, what: "mix=0.5: crossfade midpoint")
        try expect(mixHalf, x: 20, y: 20, r: 127, g: 0, b: 127, tol: 3, what: "mix=0.5: crossfade midpoint corner")
        // Non-midpoint blend exercises the full three-pass path off the 0.5 sweet spot.
        let mixQuarter = try compositor.composite(frames: [:], sceneA: sceneRed, sceneB: sceneBlue,
                                                  mix: 0.25, pts: tMix)
        try expect(mixQuarter, x: 640, y: 360, r: 191, g: 0, b: 64, tol: 3, what: "mix=0.25: quarter blend")
        // Overlapping content: scene A's own internal blend (50% green over
        // red) must be fully resolved BEFORE the crossfade — the reason for
        // the two-intermediate-texture design.
        let mixOverlap = try compositor.composite(frames: [:], sceneA: scene, sceneB: sceneBlue,
                                                  mix: 0.5, pts: tMix)
        try expect(mixOverlap, x: 320, y: 540, r: 64, g: 64, b: 127, tol: 6,
                   what: "mix=0.5 of overlapping content: lerp(render(A), render(B))")

        // --- Overlay stack (the slide/push seam): outgoing over incoming ---
        let halfRed = Scene(name: "overlay.out", layers: [
            Layer(sourceID: camID, frame: CGRect(x: 0, y: 0, width: 0.5, height: 1)),
        ])
        let over = try compositor.composite(frames: [:], stack: [sceneBlue, halfRed], pts: tMix)
        try expect(over, x: 320, y: 360, r: 255, g: 0, b: 0, tol: 1, what: "overlay: outgoing red covers left half")
        try expect(over, x: 960, y: 360, r: 0, g: 0, b: 255, tol: 1, what: "overlay: incoming blue revealed right half")

        // --- RenderLoop.switchScene: live crossfade must blend, complete, swap ---
        let loop2 = RenderLoop(compositor: compositor, fps: 60)
        loop2.scene = sceneRed
        let redBox = FrameMailbox(), blueBox = FrameMailbox()
        loop2.setMailbox(redBox, for: camID)
        loop2.setMailbox(blueBox, for: blueID)
        // Sample the center pixel per frame (no buffer retention → pool stays small).
        let samples = OSAllocatedUnfairLock<[(r: Int, g: Int, b: Int)]>(initialState: [])
        loop2.onProgramFrame = { frame in
            if let rgb = centerRGB(frame) { samples.withLock { $0.append(rgb) } }
        }
        let completedScene = OSAllocatedUnfairLock<Scene?>(initialState: nil)
        let tPost2 = HouseClock.now()
        redBox.post(VideoFrame(pixelBuffer: redBuffer, pts: tPost2, source: camID))
        blueBox.post(VideoFrame(pixelBuffer: blueBGRABuffer, pts: tPost2, source: blueID))
        loop2.start()
        Thread.sleep(forTimeInterval: 0.1) // settle on pure red
        loop2.switchScene(to: sceneBlue, transition: .crossfade(duration: 0.15)) { swapped in
            completedScene.withLock { $0 = swapped }
        }
        Thread.sleep(forTimeInterval: 0.4) // transition (0.15 s) + settle on pure blue
        loop2.stop()

        let stats2 = loop2.stats
        guard loop2.scene.id == sceneBlue.id else {
            throw SelfTestError.mismatch("switchScene did not swap: scene is \(loop2.scene.name); stats=\(stats2)")
        }
        guard stats2.transitionsCompleted == 1 else {
            throw SelfTestError.mismatch("expected 1 completed transition, got \(stats2.transitionsCompleted); stats=\(stats2)")
        }
        guard stats2.transitionTicks >= 2 else {
            throw SelfTestError.mismatch("expected ≥2 transition ticks (0.15 s @60fps), got \(stats2.transitionTicks)")
        }
        guard stats2.compositeErrors == 0 else {
            throw SelfTestError.mismatch("transition run hit \(stats2.compositeErrors) composite errors")
        }
        guard let doneScene = completedScene.withLock({ $0 }), doneScene.id == sceneBlue.id else {
            throw SelfTestError.mismatch("transition completion callback missing or wrong scene")
        }
        let centerSamples = samples.withLock { $0 }
        guard let first = centerSamples.first, first.r >= 252, first.b <= 3 else {
            throw SelfTestError.mismatch("pre-transition frame not pure red: \(String(describing: centerSamples.first))")
        }
        guard let last = centerSamples.last, last.b >= 252, last.r <= 3 else {
            throw SelfTestError.mismatch("post-transition frame not pure blue: \(String(describing: centerSamples.last))")
        }
        guard centerSamples.contains(where: { $0.r > 20 && $0.r < 235 && $0.b > 20 && $0.b < 235 }) else {
            throw SelfTestError.mismatch("no genuinely blended frame observed during the crossfade")
        }

        // --- Premultiplied-alpha compositing (the C1/C2 fix proof) ------------
        // Upper layer = a PREMULTIPLIED-alpha source: left half opaque red
        // (rgb·α = (255,0,0), α=255), right half fully transparent (0,0,0,0).
        // Lower layer = solid opaque BLUE (a standard opaque BGRA source).
        // Correct alpha compositing must show RED where the matte is opaque and
        // let the BLUE lower layer show through where the matte is transparent.
        let premulBuffer = try bgraPool.makeBuffer()
        // left = premultiplied opaque red, right = transparent (all-zero incl. α).
        fillBGRAAlpha(premulBuffer,
                      left: (b: 0, g: 0, r: 255, a: 255),
                      right: (b: 0, g: 0, r: 0, a: 0))
        let premulID = SourceID("selftest.premul")
        let blueLowerBuffer = try bgraPool.makeBuffer()
        fillBGRA(blueLowerBuffer, left: (b: 255, g: 0, r: 0), right: nil) // opaque blue
        let blueLowerID = SourceID("selftest.blueLower")
        let alphaScene = Scene(name: "selftest.alpha", layers: [
            Layer(sourceID: blueLowerID, zIndex: 0),                              // opaque blue base
            Layer(sourceID: premulID, zIndex: 1, premultipliedAlpha: true),       // keyed matte over it
        ])
        let alphaProgram = try compositor.composite(
            frames: [premulID: VideoFrame(pixelBuffer: premulBuffer, pts: t0, source: premulID),
                     blueLowerID: VideoFrame(pixelBuffer: blueLowerBuffer, pts: t0, source: blueLowerID)],
            scene: alphaScene, pts: CMTimeAdd(t0, CMTime(value: 4, timescale: 60)))
        // Opaque-matte half → RED (upper layer wins).
        try expect(alphaProgram, x: 100, y: 360, r: 255, g: 0, b: 0, tol: 2,
                   what: "premul alpha: opaque-matte region shows upper RED")
        // Transparent-matte half → BLUE (lower layer shows through — the bug fix).
        try expect(alphaProgram, x: 1180, y: 360, r: 0, g: 0, b: 255, tol: 2,
                   what: "premul alpha: transparent-matte region shows lower BLUE (not opaque black)")

        // Safety case: an OPAQUE layer (premultipliedAlpha=false) whose buffer
        // has α=0 everywhere must STILL render fully opaque — cameras/screens
        // with a garbage alpha byte must not vanish. Green rgb, α=0, over blue.
        let zeroAlphaGreen = try bgraPool.makeBuffer()
        fillBGRAAlpha(zeroAlphaGreen,
                      left: (b: 0, g: 255, r: 0, a: 0), right: nil) // green, α=0
        let zeroAlphaID = SourceID("selftest.zeroAlpha")
        let safetyScene = Scene(name: "selftest.alphaSafety", layers: [
            Layer(sourceID: blueLowerID, zIndex: 0),                              // opaque blue base
            Layer(sourceID: zeroAlphaID, zIndex: 1, premultipliedAlpha: false),  // opaque (default)
        ])
        let safetyProgram = try compositor.composite(
            frames: [zeroAlphaID: VideoFrame(pixelBuffer: zeroAlphaGreen, pts: t0, source: zeroAlphaID),
                     blueLowerID: VideoFrame(pixelBuffer: blueLowerBuffer, pts: t0, source: blueLowerID)],
            scene: safetyScene, pts: CMTimeAdd(t0, CMTime(value: 5, timescale: 60)))
        try expect(safetyProgram, x: 640, y: 360, r: 0, g: 255, b: 0, tol: 2,
                   what: "opaque-layer safety: α=0 buffer still renders opaque GREEN (does not go transparent)")

        print("CompositorSelfTest: all checks passed — \(programFrames.count) loop frames, "
              + "\(stats.ticks) ticks, \(stats.lateTicks) late; transition: "
              + "\(stats2.transitionTicks) mix ticks, \(stats2.transitionsCompleted) completed, "
              + "\(centerSamples.count) sampled frames")
    }

    // MARK: - Test-only CPU pixel access (never on the engine hot path)

    /// Fill a BGRA buffer with `left`; if `right` is given, the right half gets it.
    private static func fillBGRA(_ buffer: CVPixelBuffer,
                                 left: (b: UInt8, g: UInt8, r: UInt8),
                                 right: (b: UInt8, g: UInt8, r: UInt8)?) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        for row in 0..<height {
            let rowBase = base + row * bytesPerRow
            for col in 0..<width {
                let c = (right != nil && col >= width / 2) ? right! : left
                let p = rowBase + col * 4
                p[0] = c.b; p[1] = c.g; p[2] = c.r; p[3] = 255
            }
        }
    }

    /// Fill a BGRA buffer with `left` including an explicit alpha byte; if
    /// `right` is given, the right half gets it. Used to synthesize
    /// premultiplied-alpha mattes and α=0 safety cases (test-only).
    private static func fillBGRAAlpha(_ buffer: CVPixelBuffer,
                                      left: (b: UInt8, g: UInt8, r: UInt8, a: UInt8),
                                      right: (b: UInt8, g: UInt8, r: UInt8, a: UInt8)?) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        for row in 0..<height {
            let rowBase = base + row * bytesPerRow
            for col in 0..<width {
                let c = (right != nil && col >= width / 2) ? right! : left
                let p = rowBase + col * 4
                p[0] = c.b; p[1] = c.g; p[2] = c.r; p[3] = c.a
            }
        }
    }

    /// Fill a bi-planar YUV buffer (420v/420f) with one solid Y/Cb/Cr triple.
    private static func fillBiplanarYUV(_ buffer: CVPixelBuffer, y: UInt8, cb: UInt8, cr: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 0) {
            memset(lumaBase + row * lumaRow, Int32(y), CVPixelBufferGetWidthOfPlane(buffer, 0))
        }
        let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
            let rowBase = chromaBase + row * chromaRow
            for col in 0..<CVPixelBufferGetWidthOfPlane(buffer, 1) {
                rowBase[col * 2] = cb
                rowBase[col * 2 + 1] = cr
            }
        }
    }

    /// Read back the center pixel (640,360) of a 1280x720 program frame as
    /// (r,g,b) — used by the transition test's per-frame sampler (test-only).
    private static func centerRGB(_ frame: VideoFrame) -> (r: Int, g: Int, b: Int)? {
        let buffer = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let p = base.assumingMemoryBound(to: UInt8.self)
            + 360 * CVPixelBufferGetBytesPerRow(buffer) + 640 * 4
        return (Int(p[2]), Int(p[1]), Int(p[0]))
    }

    /// Read back one BGRA pixel of the program frame and compare (test-only).
    private static func expect(_ frame: VideoFrame, x: Int, y: Int,
                               r: Int, g: Int, b: Int, tol: Int, what: String) throws {
        let buffer = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw SelfTestError.setupFailed("no base address on program buffer")
        }
        let p = base.assumingMemoryBound(to: UInt8.self)
            + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        let (gotB, gotG, gotR) = (Int(p[0]), Int(p[1]), Int(p[2]))
        guard abs(gotR - r) <= tol, abs(gotG - g) <= tol, abs(gotB - b) <= tol else {
            throw SelfTestError.mismatch(
                "\(what) at (\(x),\(y)): got RGB(\(gotR),\(gotG),\(gotB)), expected RGB(\(r),\(g),\(b)) ±\(tol)")
        }
    }
}
