import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import XCTest
import PrismCore
@testable import PrismSources

/// XCTest gate for `AnimatedGIFSource` (animated-GIF live source). The heavy
/// logic lives in `AnimatedGIFSelfTest.run()`: it generates a REAL multi-frame
/// GIF with ffmpeg (from the canonical mp4, else synthesized color frames),
/// then proves per-frame delays, IOSurface BGRA canvas frames, real frame-to-
/// frame motion, looping, a single-frame-image static fallback, a typed throw
/// on a bad file, no emission after stop(), and the decode budget (over-budget
/// preload → typed throw). A few PNGs across the loop are dumped for eyeballing.
/// The animated section skips gracefully if ffmpeg is absent (the still /
/// bad-path / no-emit-after-stop / budget checks still run on an ImageIO GIF).
final class AnimatedGIFTests: XCTestCase {
    func testAnimatedGIFSource() throws {
        try AnimatedGIFSelfTest.run()
    }

    /// The construction-time decode budget is a hard backstop: it must reject an
    /// over-large preload (`frames · frameW · frameH · 4`, computed on the CAPPED
    /// decode resolution) with a typed throw BEFORE allocating the pool, so a
    /// long/hostile GIF cannot allocate unboundedly.
    func testDecodeBudgetBackstop() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_gif_budget_\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Self.writeSyntheticGIF(to: tmp, frames: 4, w: 128, h: 128)
        let canvas = CanvasSize(width: 256, height: 256)

        // Over budget by BYTES: a 1 KiB decoded-byte budget rejects the preload.
        XCTAssertThrowsError(try AnimatedGIFSource(
            id: SourceID("t.budget.bytes"), fileURL: tmp, canvasSize: canvas,
            contentMode: .stretch, background: .black, loop: true,
            maxFrameCount: AnimatedGIFSource.defaultMaxFrameCount, maxDecodedBytes: 1024)) { error in
            guard let e = error as? SourceError, case .invalidConfiguration = e else {
                return XCTFail("expected .invalidConfiguration (bytes), got \(error)")
            }
        }

        // Over budget by FRAME COUNT: a max of 2 rejects the 4-frame GIF.
        XCTAssertThrowsError(try AnimatedGIFSource(
            id: SourceID("t.budget.count"), fileURL: tmp, canvasSize: canvas,
            contentMode: .stretch, background: .black, loop: true,
            maxFrameCount: 2, maxDecodedBytes: AnimatedGIFSource.defaultMaxDecodedBytes)) { error in
            guard let e = error as? SourceError, case .invalidConfiguration = e else {
                return XCTFail("expected .invalidConfiguration (count), got \(error)")
            }
        }

        // Control: the SAME GIF under the DEFAULT budget decodes and plays — and,
        // crucially, a HUGE canvas that would have blown the old canvas-sized
        // budget now SUCCEEDS, because frames decode at a capped (native/≤720p)
        // resolution rather than full canvas. This is the memory win.
        let source = try AnimatedGIFSource(fileURL: tmp,
                                           canvasSize: CanvasSize(width: 8192, height: 8192),
                                           contentMode: .aspectFit, background: .black, loop: true)
        XCTAssertEqual(source.frameCount, 4)
        // 8192² canvas but a 128² GIF → decode at native 128², not full canvas.
        XCTAssertLessThanOrEqual(source.frameWidth, AnimatedGIFSource.decodeCapLongSide)
        XCTAssertLessThan(source.frameWidth, 8192, "decode must not be full canvas")
        let counter = TestCounter()
        source.onFrame = { _ in counter.bump() }
        try source.start()
        let deadline = Date().addingTimeInterval(3)
        while counter.value < 2 && Date() < deadline { usleep(10_000) }
        source.stop()
        XCTAssertGreaterThanOrEqual(counter.value, 2, "huge-canvas GIF must decode + play post-cap")
    }

    /// The optimization: frames are stored at a CAPPED decode resolution
    /// (≤720p, aspect-preserving), not the full canvas — cutting resident RAM
    /// (`frameW·frameH·4·frameCount`) several-fold — while playback still shows
    /// real motion and loops. A large 4K canvas over a 720p-native GIF.
    func testDecodeResolutionCapped() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_gif_cap_\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // 720p-native, multi-frame (per-frame color ramp → frame-to-frame motion).
        try Self.writeSyntheticGIF(to: tmp, frames: 6, w: 1280, h: 720)

        let canvas = CanvasSize(width: 3840, height: 2160)   // 4K canvas (16:9)
        let source = try AnimatedGIFSource(fileURL: tmp, canvasSize: canvas,
                                           contentMode: .aspectFit, background: .black, loop: true)
        XCTAssertEqual(source.frameCount, 6)

        // Decoded frames are at the ≤720p cap, well below the 4K canvas.
        XCTAssertLessThanOrEqual(source.frameWidth, AnimatedGIFSource.decodeCapLongSide)
        XCTAssertLessThanOrEqual(source.frameHeight, AnimatedGIFSource.decodeCapShortSide)
        XCTAssertLessThan(source.frameWidth, canvas.width, "decode width must be < full canvas")
        XCTAssertLessThan(source.frameHeight, canvas.height, "decode height must be < full canvas")
        // Aspect ratio preserved (so the overlay scales up identically).
        let arCanvas = Double(canvas.width) / Double(canvas.height)
        let arFrame = Double(source.frameWidth) / Double(source.frameHeight)
        XCTAssertEqual(arFrame, arCanvas, accuracy: 0.02, "decode canvas must keep the aspect ratio")

        // RAM before (full-canvas) vs after (capped) — the win, in bytes.
        let before = canvas.width * canvas.height * 4 * source.frameCount
        let after = source.frameWidth * source.frameHeight * 4 * source.frameCount
        print(String(format: "  [gif-cap] resident decode RAM: before %.1f MB (%dx%d) → after %.1f MB (%dx%d) = %.1f× smaller",
                     Double(before) / 1e6, canvas.width, canvas.height,
                     Double(after) / 1e6, source.frameWidth, source.frameHeight,
                     Double(before) / Double(after)))

        // Playback: frames emit at the capped size, show motion, and loop.
        let frames = FrameSink()
        source.onFrame = { frames.add($0.pixelBuffer, w: $0.width, h: $0.height) }
        try source.start()
        let deadline = Date().addingTimeInterval(5)
        while frames.count <= source.frameCount + 2 && Date() < deadline { usleep(10_000) }
        source.stop()

        XCTAssertGreaterThan(frames.count, source.frameCount, "must loop past one pass")
        XCTAssertTrue(frames.allMatch(w: source.frameWidth, h: source.frameHeight),
                      "every emitted frame is at the capped decode resolution")
        XCTAssertGreaterThan(frames.maxMeanDiff(), 2.0, "playback must show frame-to-frame motion")
    }

    /// Minimal multi-frame GIF written with ImageIO (no ffmpeg dependency).
    static func writeSyntheticGIF(to url: URL, frames: Int, w: Int, h: Int) throws {
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
            throw NSError(domain: "gif.test", code: 1)
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        for i in 0..<frames {
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw NSError(domain: "gif.test", code: 2)
            }
            let t = Double(i) / Double(max(frames - 1, 1))
            ctx.setFillColor(CGColor(srgbRed: CGFloat(t), green: CGFloat(1 - t), blue: 0.4, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            guard let img = ctx.makeImage() else { throw NSError(domain: "gif.test", code: 3) }
            CGImageDestinationAddImage(dest, img, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 0.05]
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "gif.test", code: 4) }
    }
}

/// Thread-safe counter for onFrame callbacks fired off the source's own queue.
final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Thread-safe sink that captures emitted frames (buffer + dims) so a test can
/// assert on the emitted resolution and frame-to-frame motion. Test code only:
/// locks pixel-buffer base addresses to read pixels back.
final class FrameSink: @unchecked Sendable {
    private struct F { let b: CVPixelBuffer; let w: Int; let h: Int }
    private let lock = NSLock()
    private var frames: [F] = []
    func add(_ b: CVPixelBuffer, w: Int, h: Int) {
        lock.lock(); frames.append(F(b: b, w: w, h: h)); lock.unlock()
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
    func allMatch(w: Int, h: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return frames.allSatisfy { $0.w == w && $0.h == h }
    }
    /// Largest mean absolute per-channel diff between consecutive frames.
    func maxMeanDiff(step: Int = 16) -> Double {
        lock.lock(); let snap = frames; lock.unlock()
        guard snap.count > 1 else { return 0 }
        var best = 0.0
        for i in 1..<snap.count where snap[i].w == snap[i - 1].w && snap[i].h == snap[i - 1].h {
            best = max(best, Self.meanDiff(snap[i - 1], snap[i], step: step))
        }
        return best
    }
    private static func meanDiff(_ a: F, _ b: F, step: Int) -> Double {
        CVPixelBufferLockBaseAddress(a.b, .readOnly)
        CVPixelBufferLockBaseAddress(b.b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a.b, .readOnly)
            CVPixelBufferUnlockBaseAddress(b.b, .readOnly)
        }
        guard let pa = CVPixelBufferGetBaseAddress(a.b)?.assumingMemoryBound(to: UInt8.self),
              let pb = CVPixelBufferGetBaseAddress(b.b)?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        let rowA = CVPixelBufferGetBytesPerRow(a.b), rowB = CVPixelBufferGetBytesPerRow(b.b)
        var total = 0, n = 0, y = 0
        while y < a.h {
            var x = 0
            while x < a.w {
                for c in 0..<3 {
                    total += abs(Int(pa[y * rowA + x * 4 + c]) - Int(pb[y * rowB + x * 4 + c]))
                    n += 1
                }
                x += step
            }
            y += step
        }
        return n > 0 ? Double(total) / Double(n) : 0
    }
}
