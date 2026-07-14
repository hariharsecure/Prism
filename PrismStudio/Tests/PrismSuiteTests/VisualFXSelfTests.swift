import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import XCTest

import PrismCompositor
import PrismCore
import PrismSources

/// Verification for the visual-FX engine (transitions / anime animation /
/// character source / meme insert). Renders REAL sequences over IMAGE sources,
/// asserts correctness on the pixels, and DUMPS every frame as a PNG the lead
/// can eyeball.
///
/// PNG output directory (session scratchpad):
///   /tmp/prism_visualfx/
final class VisualFXSelfTests: XCTestCase {

    private static let outputDir = URL(fileURLWithPath:
        "/tmp/prism_visualfx")

    // MARK: - 1. The full engine self-test (asserts + PNG dump)

    func testVisualFXEngineSelfTestAndPNGDump() throws {
        let written = try VisualFXSelfTest.run(outputDir: Self.outputDir, width: 480, height: 270)
        // The suite dumps the source pair + every transition/anime/meme/template frame.
        XCTAssertGreaterThan(written.count, 80, "expected a rich PNG dump for eyeballing")
        for url in written {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing PNG \(url.lastPathComponent)")
        }
        print("VisualFX PNGs written to: \(Self.outputDir.path)")
    }

    // MARK: - 2. Transitions & stinger over REAL ImageSource frames

    func testTransitionsOverRealImageSources() throws {
        let w = 480, h = 270
        let dir = Self.outputDir.appendingPathComponent("real_image_sources")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Two real image files → two real ImageSources.
        let urlA = dir.appendingPathComponent("_imgA.png")
        let urlB = dir.appendingPathComponent("_imgB.png")
        try writeSolidishPNG(to: urlA, top: (230, 90, 30), bottom: (200, 30, 40))   // warm
        try writeSolidishPNG(to: urlB, top: (30, 200, 230), bottom: (30, 60, 210))  // cool

        let a = try firstFrame(ImageSource(id: SourceID("fx.A"), fileURL: urlA,
                                           canvasSize: CanvasSize(width: w, height: h), contentMode: .stretch, fps: 8))
        let b = try firstFrame(ImageSource(id: SourceID("fx.B"), fileURL: urlB,
                                           canvasSize: CanvasSize(width: w, height: h), contentMode: .stretch, fps: 8))

        // Sanity: the two real sources are distinct and IOSurface-backed.
        XCTAssertNotNil(CVPixelBufferGetIOSurface(a.pixelBuffer))
        XCTAssertNotNil(CVPixelBufferGetIOSurface(b.pixelBuffer))
        XCTAssertGreaterThan(FXCanvas.meanDiff(a.pixelBuffer, b.pixelBuffer), 0.2, "image sources should differ")

        // Run a couple of transition kinds over the real source frames.
        let renderer = try TransitionRenderer(width: w, height: h)
        for kind in [TransitionKind.dissolve, .wipe(.left), .iris] {
            let spec = TransitionSpec(kind: kind, duration: 0.5, easing: .easeInOut)
            let f0 = try renderer.render(a: a.pixelBuffer, b: b.pixelBuffer, spec: spec, progress: 0)
            let fMid = try renderer.render(a: a.pixelBuffer, b: b.pixelBuffer, spec: spec, progress: 0.5)
            let f1 = try renderer.render(a: a.pixelBuffer, b: b.pixelBuffer, spec: spec, progress: 1)
            XCTAssertLessThan(FXCanvas.meanDiff(f0, a.pixelBuffer), 0.02, "\(kind.label): p0 == A")
            XCTAssertLessThan(FXCanvas.meanDiff(f1, b.pixelBuffer), 0.02, "\(kind.label): p1 == B")
            XCTAssertGreaterThan(FXCanvas.meanDiff(fMid, a.pixelBuffer), 0.03, "\(kind.label): mid ≠ A")
            XCTAssertGreaterThan(FXCanvas.meanDiff(fMid, b.pixelBuffer), 0.03, "\(kind.label): mid ≠ B")
            try FXCanvas.writePNG(f0, to: dir.appendingPathComponent("real_\(kind.label)_0.png"))
            try FXCanvas.writePNG(fMid, to: dir.appendingPathComponent("real_\(kind.label)_mid.png"))
            try FXCanvas.writePNG(f1, to: dir.appendingPathComponent("real_\(kind.label)_1.png"))
        }

        // Stinger over the real sources.
        let sr = try StingerRenderer(width: w, height: h)
        let sting = StingerTransition.panel(color: RGBA(r: 0.95, g: 0.2, b: 0.3), direction: .down)
        let sMid = try sr.render(a: a.pixelBuffer, b: b.pixelBuffer, stinger: sting, progress: 0.5)
        try FXCanvas.writePNG(sMid, to: dir.appendingPathComponent("real_stinger_cue.png"))
        XCTAssertGreaterThan(FXCanvas.meanDiff(sMid, a.pixelBuffer), 0.1)
    }

    // MARK: - 3. CharacterSource: idle sway + reaction (over real image layers)

    func testCharacterSourceIdleAndReaction() throws {
        let dir = Self.outputDir.appendingPathComponent("character")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let character = try CharacterSource(id: SourceID("fx.character"),
                                            canvasSize: CanvasSize(width: 480, height: 270), fps: 60)
        let collector = FrameCollector()
        character.onFrame = { collector.add($0) }
        try character.start()
        defer { character.stop() }

        // Collect idle frames.
        XCTAssertTrue(pollUntil(2.0) { collector.count >= 12 }, "character emitted no idle frames")
        let idle = collector.snapshot()
        XCTAssertGreaterThanOrEqual(idle.count, 12)

        // Idle actually animates: some later frame differs from the first.
        let idleMotion = (1..<idle.count).map { FXCanvas.meanDiff(idle[0].pixelBuffer, idle[$0].pixelBuffer) }.max() ?? 0
        XCTAssertGreaterThan(idleMotion, 0.0005, "idle sway did not change pixels frame-to-frame")
        let idleBaselineLuma = FXCanvas.meanLuma(idle.last!.pixelBuffer)
        try FXCanvas.writePNG(idle.first!.pixelBuffer, to: dir.appendingPathComponent("char_idle_0.png"))
        try FXCanvas.writePNG(idle.last!.pixelBuffer, to: dir.appendingPathComponent("char_idle_1.png"))

        // Expression swap is reflected.
        XCTAssertEqual(character.currentExpression(), "neutral")
        character.setExpression("happy")
        XCTAssertEqual(character.currentExpression(), "happy")

        // Reaction: impact-pop must produce a white flash frame.
        collector.reset()
        character.react(expression: "surprised", accent: .impactPop, duration: 0.5)
        XCTAssertTrue(pollUntil(1.0) { collector.count >= 8 }, "no reaction frames")
        let reactionFrames = collector.snapshot()
        let peakLuma = reactionFrames.map { FXCanvas.meanLuma($0.pixelBuffer) }.max() ?? 0
        XCTAssertGreaterThan(peakLuma, idleBaselineLuma + 0.15, "impact-pop produced no flash frame (peak \(peakLuma) vs idle \(idleBaselineLuma))")
        XCTAssertEqual(character.currentExpression(), "surprised")

        // Dump the brightest reaction frame (the accent) + a later settled frame.
        if let flashFrame = reactionFrames.max(by: { FXCanvas.meanLuma($0.pixelBuffer) < FXCanvas.meanLuma($1.pixelBuffer) }) {
            try FXCanvas.writePNG(flashFrame.pixelBuffer, to: dir.appendingPathComponent("char_reaction_flash.png"))
        }
        try FXCanvas.writePNG(reactionFrames.last!.pixelBuffer, to: dir.appendingPathComponent("char_reaction_settled.png"))
    }

    // MARK: - Helpers

    private final class FrameCollector {
        private let lock = NSLock()
        private var frames: [VideoFrame] = []
        func add(_ f: VideoFrame) { lock.lock(); frames.append(f); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
        func snapshot() -> [VideoFrame] { lock.lock(); defer { lock.unlock() }; return frames }
        func reset() { lock.lock(); frames.removeAll(); lock.unlock() }
    }

    /// Start a source, wait for its first frame, stop it, return that frame.
    private func firstFrame(_ source: TimedVideoSource) throws -> VideoFrame {
        let collector = FrameCollector()
        source.onFrame = { collector.add($0) }
        try source.start()
        defer { source.stop() }
        XCTAssertTrue(pollUntil(2.0) { collector.count > 0 }, "source emitted no frame")
        return collector.snapshot().first!
    }

    /// Poll (blocking main) until `predicate` or `timeout`. Sources emit on their
    /// own queues, so a sleep-poll is sufficient (no main run loop needed).
    private func pollUntil(_ timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline { return predicate() }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    /// Write a PNG with a distinct top and bottom color (top-left origin content).
    private func writeSolidishPNG(to url: URL, top: (Int, Int, Int), bottom: (Int, Int, Int)) throws {
        let w = 64, h = 64
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "fx.test", code: 1)
        }
        // Bottom-left origin: fill low-y with `bottom`, high-y with `top`.
        ctx.setFillColor(CGColor(srgbRed: CGFloat(bottom.0) / 255, green: CGFloat(bottom.1) / 255, blue: CGFloat(bottom.2) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 2))
        ctx.setFillColor(CGColor(srgbRed: CGFloat(top.0) / 255, green: CGFloat(top.1) / 255, blue: CGFloat(top.2) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h / 2, width: w, height: h / 2))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "fx.test", code: 2)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "fx.test", code: 3) }
    }
}
