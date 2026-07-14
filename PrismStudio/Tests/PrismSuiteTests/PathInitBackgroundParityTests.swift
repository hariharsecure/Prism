import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import XCTest
import PrismCore
import PrismSources

/// F23 regression: the `path:` (String) convenience initializers of `ImageSource`
/// and `AnimatedGIFSource` used to default to OPAQUE BLACK while the equivalent
/// `fileURL:` initializers defaulted to `.clear`. The same transparent PNG / GIF
/// then rendered as an overlay or a black rectangle based only on which overload
/// was chosen. The fix makes BOTH default to `.clear`, so a content-free region
/// (a transparent pixel or a letterbox bar) is alpha 0 whichever init is used.
final class PathInitBackgroundParityTests: XCTestCase {

    // MARK: - Helpers

    /// Start the source, capture its first emitted frame, stop. (These sources
    /// render eagerly and re-emit a still, so the first tick is representative.)
    private func firstFrame(_ source: VideoSource) throws -> CVPixelBuffer {
        let sink = FirstFrameSink()
        source.onFrame = { sink.set($0.pixelBuffer) }
        try source.start()
        let deadline = Date().addingTimeInterval(3)
        while sink.get() == nil && Date() < deadline { usleep(10_000) }
        source.stop()
        return try XCTUnwrap(sink.get(), "source emitted no frame")
    }

    /// Minimum alpha over the frame (0 ⇒ at least one fully-transparent pixel).
    private func minAlpha(_ b: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let w = CVPixelBufferGetWidth(b), h = CVPixelBufferGetHeight(b)
        let bpr = CVPixelBufferGetBytesPerRow(b)
        let base = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        var lo = 255, y = 0
        while y < h {
            var x = 0
            while x < w { lo = min(lo, Int(base[y * bpr + x * 4 + 3])); if lo == 0 { return 0 }; x += 2 }
            y += 2
        }
        return lo
    }

    private func writeTransparentCornerPNG(to url: URL, side: Int) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Opaque green everywhere...
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.8, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        // ...except a fully-transparent corner block (clear ⇒ alpha 0).
        ctx.clear(CGRect(x: 0, y: 0, width: side / 3, height: side / 3))
        let img = ctx.makeImage()!
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "f23.test", code: 1)
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "f23.test", code: 2) }
    }

    // MARK: - ImageSource

    func testImageSourcePathInitMatchesFileURLDefault() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_f23_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeTransparentCornerPNG(to: tmp, side: 129)   // odd → maps cleanly under stretch

        let canvas = CanvasSize(width: 129, height: 129)
        // fileURL init: default background (already .clear).
        let viaURL = try ImageSource(fileURL: tmp, canvasSize: canvas, contentMode: .stretch)
        // path init: default background (was .black — the bug; now .clear).
        let viaPath = try ImageSource(path: tmp.path, canvasSize: canvas, contentMode: .stretch)

        let aURL = minAlpha(try firstFrame(viaURL))
        let aPath = minAlpha(try firstFrame(viaPath))
        XCTAssertEqual(aURL, 0, "fileURL init must preserve the transparent corner (alpha 0)")
        XCTAssertEqual(aPath, 0,
            "path init must ALSO preserve transparency (alpha 0) — got \(aPath); the old default painted it opaque black (255)")
    }

    // MARK: - AnimatedGIFSource (letterbox bar reveals the background default)

    func testGIFSourcePathInitMatchesFileURLDefault() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_f23_\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Square GIF into a 2:1 canvas ⇒ aspect-fit leaves transparent letterbox
        // BARS filled by the background default (the F23 surface).
        try AnimatedGIFTests.writeSyntheticGIF(to: tmp, frames: 2, w: 96, h: 96)

        let canvas = CanvasSize(width: 256, height: 128)   // 2:1, bars on the sides
        let viaURL = try AnimatedGIFSource(fileURL: tmp, canvasSize: canvas, contentMode: .aspectFit)
        let viaPath = try AnimatedGIFSource(path: tmp.path, canvasSize: canvas, contentMode: .aspectFit)

        let aURL = minAlpha(try firstFrame(viaURL))
        let aPath = minAlpha(try firstFrame(viaPath))
        XCTAssertEqual(aURL, 0, "fileURL init must leave transparent letterbox bars (alpha 0)")
        XCTAssertEqual(aPath, 0,
            "path init must ALSO leave transparent bars (alpha 0) — got \(aPath); the old default filled them opaque black (255)")
    }
}

/// Captures the first emitted frame (callbacks fire on the source's own queue).
private final class FirstFrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private var b: CVPixelBuffer?
    func set(_ v: CVPixelBuffer) { lock.lock(); if b == nil { b = v }; lock.unlock() }
    func get() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return b }
}
