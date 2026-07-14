import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import os
import PrismCore
import UniformTypeIdentifiers

/// Headless self-verification of `AnimatedGIFSource`.
///
/// Generates a REAL multi-frame animated GIF with `ffmpeg` (from the canonical
/// mp4 asset when present, else from a handful of distinct-colored frames) and
/// asserts:
///  - ≥2 frames decoded, each with a positive per-frame delay (floored),
///  - emitted buffers are IOSurface-backed BGRA at canvas size,
///  - frames CHANGE over time (frame-to-frame meanDiff above a threshold — real
///    motion, not a frozen first frame),
///  - playback LOOPS (more frames emitted than the GIF contains, and the loop
///    seam realigns to an early frame),
///  - a single-frame image behaves as a STATIC still (identical frames),
///  - a bad file throws a typed `SourceError` at init,
///  - NO frame is emitted after `stop()`.
///
/// A few PNGs sampled across the loop are dumped to `dumpDir` for eyeballing.
/// If `ffmpeg` is absent the animated section is SKIPPED (not failed); the
/// still / bad-path / no-emit-after-stop checks still run on a synthesized GIF
/// written directly with `ImageIO` (no external tool).
///
/// TEST CODE ONLY: locks pixel-buffer base addresses to read back output.
public enum AnimatedGIFSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case setupFailed(String)
        case mismatch(String)
        public var description: String {
            switch self {
            case .setupFailed(let s): return "gif self-test setup failed: \(s)"
            case .mismatch(let s): return "gif self-test mismatch: \(s)"
            }
        }
    }

    /// The canonical real asset used to synthesize a GIF (guarded).
    public static let realAssetPath = (ProcessInfo.processInfo.environment["PRISM_SELFTEST_MOVIE"] ?? "")
    /// Where sampled PNGs are dumped for the lead to eyeball.
    public static let dumpDir = "/tmp/prism_gif"

    public static func run() throws {
        try testAnimatedLoopAndMotion()
        try testStillImage()
        try testBadPathThrows()
        try testNoEmitAfterStop()
        try testDecodeBudget()
        print("AnimatedGIFSelfTest: all checks passed")
    }

    // MARK: - Frame collection

    private final class FrameCollector: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: [VideoFrame]())
        func add(_ f: VideoFrame) { lock.withLock { $0.append(f) } }
        var count: Int { lock.withLock { $0.count } }
        func snapshot() -> [VideoFrame] { lock.withLock { $0 } }
    }

    @discardableResult
    private static func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline { return predicate() }
            usleep(10_000)
        }
        return true
    }

    // MARK: - Pixel read-back

    private static func readBGRA(_ b: CVPixelBuffer, x: Int, y: Int) -> (b: Int, g: Int, r: Int) {
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
            + y * CVPixelBufferGetBytesPerRow(b) + x * 4
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }

    private static func spread(_ f: VideoFrame, step: Int = 16) -> Int {
        let w = f.width, h = f.height
        var lo = 255, hi = 0, y = 0
        while y < h {
            var x = 0
            while x < w {
                let px = readBGRA(f.pixelBuffer, x: x, y: y)
                let lum = (px.r * 30 + px.g * 59 + px.b * 11) / 100
                lo = min(lo, lum); hi = max(hi, lum)
                x += step
            }
            y += step
        }
        return hi - lo
    }

    private static func meanDiff(_ a: VideoFrame, _ b: VideoFrame, step: Int = 16) -> Double {
        guard a.width == b.width, a.height == b.height else { return .infinity }
        let w = a.width, h = a.height
        var total = 0, n = 0, y = 0
        while y < h {
            var x = 0
            while x < w {
                let pa = readBGRA(a.pixelBuffer, x: x, y: y)
                let pb = readBGRA(b.pixelBuffer, x: x, y: y)
                total += abs(pa.b - pb.b) + abs(pa.g - pb.g) + abs(pa.r - pb.r)
                n += 3
                x += step
            }
            y += step
        }
        return n > 0 ? Double(total) / Double(n) : 0
    }

    private static func maxMotion(_ frames: [VideoFrame]) -> Double {
        guard frames.count > 1 else { return 0 }
        var best = 0.0, i = 1
        while i < frames.count { best = max(best, meanDiff(frames[i - 1], frames[i])); i += 1 }
        return best
    }

    private static func assertShape(_ f: VideoFrame, w: Int, h: Int, what: String) throws {
        guard f.width == w, f.height == h else {
            throw SelfTestError.mismatch("\(what): frame \(f.width)x\(f.height), expected \(w)x\(h)")
        }
        guard f.pixelFormat == kCVPixelFormatType_32BGRA else {
            throw SelfTestError.mismatch("\(what): pixel format \(f.pixelFormat), expected BGRA")
        }
        guard CVPixelBufferGetIOSurface(f.pixelBuffer) != nil else {
            throw SelfTestError.mismatch("\(what): NOT IOSurface-backed (zero-copy violation)")
        }
    }

    // MARK: - 1. Animated GIF: decode / delays / motion / loop + PNG dump

    private static func testAnimatedLoopAndMotion() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_gif_selftest_\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: tmp) }

        guard let (origin, _) = try makeAnimatedGIF(to: tmp) else {
            print("  – AnimatedGIFSource[animated]: SKIPPED — ffmpeg absent, cannot synthesize a real GIF")
            return
        }

        let cw = 320, ch = 240
        // Opaque background so the letterbox contributes no alpha ambiguity to
        // the pixel read-back checks.
        let source = try AnimatedGIFSource(id: SourceID("selftest.gif.animated"),
                                           fileURL: tmp,
                                           canvasSize: CanvasSize(width: cw, height: ch),
                                           contentMode: .aspectFit,
                                           background: .black,
                                           loop: true)

        // Decode-side assertions: ≥2 frames, every delay positive & floored.
        guard source.frameCount >= 2 else {
            throw SelfTestError.mismatch("animated: only \(source.frameCount) frame(s) decoded (\(origin))")
        }
        let delays = source.perFrameDelays
        guard let minDelay = delays.min(), minDelay >= 0.02 - 1e-9 else {
            throw SelfTestError.mismatch("animated: a per-frame delay is not floored: \(delays)")
        }
        guard delays.allSatisfy({ $0 > 0 }) else {
            throw SelfTestError.mismatch("animated: a non-positive delay: \(delays)")
        }

        // Resolution cap: frames decode at ≤720p and no larger than the requested
        // canvas — NOT full canvas when the canvas already fits the cap here, but
        // the GIF's native size (160-wide) further shrinks it below the canvas.
        let fw = source.frameWidth, fh = source.frameHeight
        guard fw > 0, fh > 0, fw <= cw, fh <= ch,
              fw <= AnimatedGIFSource.decodeCapLongSide,
              fh <= AnimatedGIFSource.decodeCapLongSide else {
            throw SelfTestError.mismatch("animated: decode res \(fw)x\(fh) not capped ≤ canvas \(cw)x\(ch) / ≤720p")
        }

        let collector = FrameCollector()
        source.onFrame = { collector.add($0) }
        try source.start()
        defer { source.stop() }

        // Collect long enough to overrun one loop (~2× the GIF duration + slack).
        let overrun = source.frameCount + max(2, source.frameCount / 2)
        let budget = max(4.0, source.nominalDurationSeconds * 2.5 + 1.0)
        _ = waitUntil(timeout: budget) { collector.count > overrun }
        let frames = collector.snapshot()
        guard let first = frames.first else {
            throw SelfTestError.mismatch("animated: no frame emitted")
        }
        try assertShape(first, w: fw, h: fh, what: "animated")
        try assertShape(frames[frames.count / 2], w: fw, h: fh, what: "animated.mid")
        try assertShape(frames.last!, w: fw, h: fh, what: "animated.last")

        guard let sp = frames.map({ spread($0) }).max(), sp > 20 else {
            throw SelfTestError.mismatch("animated: frames look blank (max spread \(frames.map { spread($0) }.max() ?? -1))")
        }
        // Real motion: some frame-to-frame pair must differ meaningfully.
        let motion = maxMotion(frames)
        guard motion > 2.0 else {
            throw SelfTestError.mismatch("animated: no frame-to-frame motion (maxMeanDiff \(motion)) — frozen first frame?")
        }
        // Looped: more frames than the GIF contains, produced continuously.
        guard frames.count > source.frameCount else {
            throw SelfTestError.mismatch("animated: only \(frames.count) frames (GIF has \(source.frameCount)) — did not loop")
        }
        // Loop seam realigns: some later emitted frame closely matches frame 0
        // (the playhead wrapped back to the top).
        var seamMin = Double.infinity
        var j = source.frameCount - 1
        while j < frames.count { seamMin = min(seamMin, meanDiff(first, frames[j])); j += 1 }
        guard seamMin < max(2.0, motion * 0.5) else {
            throw SelfTestError.mismatch("animated: loop seam never realigns to frame 0 (minSeamDiff \(seamMin))")
        }

        try dumpPNGs(frames, prefix: "animated")

        print(String(format: "  ✓ AnimatedGIFSource[animated]: %@ — %d frames, delays %@, decode %dx%d (canvas %dx%d) IOSurface BGRA, maxSpread %d, maxMeanDiff %.1f (motion), looped (%d emitted > %d-frame GIF), seamDiff %.1f, dur %.2fs",
                     origin, source.frameCount, shortDelays(delays), fw, fh, cw, ch, sp, motion,
                     frames.count, source.frameCount, seamMin, source.nominalDurationSeconds))
    }

    // MARK: - 2. Single-frame image → static still

    private static func testStillImage() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_gif_still_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeSolidPNG(to: tmp, w: 32, h: 32, r: 0.2, g: 0.8, b: 0.4)

        let cw = 128, ch = 128
        let source = try AnimatedGIFSource(id: SourceID("selftest.gif.still"),
                                           fileURL: tmp,
                                           canvasSize: CanvasSize(width: cw, height: ch),
                                           contentMode: .stretch,
                                           background: .black, loop: true)
        guard source.frameCount == 1, !source.isAnimated else {
            throw SelfTestError.mismatch("still: expected 1 frame, got \(source.frameCount) (isAnimated \(source.isAnimated))")
        }
        let collector = FrameCollector()
        source.onFrame = { collector.add($0) }
        try source.start()
        defer { source.stop() }
        _ = waitUntil(timeout: 3.0) { collector.count >= 3 }
        let frames = collector.snapshot()
        guard frames.count >= 2 else {
            throw SelfTestError.mismatch("still: only \(frames.count) frames in 3 s")
        }
        let fw = source.frameWidth, fh = source.frameHeight
        try assertShape(frames[0], w: fw, h: fh, what: "still")
        // Static: every emitted frame is identical (a re-emitted cached still).
        let motion = maxMotion(frames)
        guard motion < 0.5 else {
            throw SelfTestError.mismatch("still: frames changed over time (maxMeanDiff \(motion)) — not static")
        }
        print(String(format: "  ✓ AnimatedGIFSource[still]: single-frame image → %d identical %dx%d frames (canvas %dx%d, maxMeanDiff %.2f)",
                     frames.count, fw, fh, cw, ch, motion))
    }

    // MARK: - 3. Bad file → typed throw at init

    private static func testBadPathThrows() throws {
        var threw = false
        do {
            _ = try AnimatedGIFSource(path: "/definitely/missing_\(UUID().uuidString).gif")
        } catch let e as SourceError {
            threw = true
            if case .imageLoadFailed = e {} else {
                throw SelfTestError.mismatch("bad path: wrong error \(e)")
            }
        }
        guard threw else { throw SelfTestError.mismatch("bad path: init did not throw") }

        // A file that exists but is not a decodable image → typed decode failure.
        let junk = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_gif_junk_\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: junk) }
        try Data("not an image".utf8).write(to: junk)
        var threw2 = false
        do { _ = try AnimatedGIFSource(fileURL: junk) }
        catch let e as SourceError {
            threw2 = true
            if case .imageLoadFailed = e {} else if case .imageDecodeFailed = e {} else {
                throw SelfTestError.mismatch("junk file: wrong error \(e)")
            }
        }
        guard threw2 else { throw SelfTestError.mismatch("junk file: init did not throw") }
        print("  ✓ AnimatedGIFSource[bad-path]: missing → imageLoadFailed, junk bytes → typed decode throw")
    }

    // MARK: - 4. No emission after stop()

    private static func testNoEmitAfterStop() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_gif_stop_\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeSyntheticGIF(to: tmp, frames: 6, w: 48, h: 48, delay: 0.05)

        let source = try AnimatedGIFSource(id: SourceID("selftest.gif.stop"),
                                           fileURL: tmp,
                                           canvasSize: CanvasSize(width: 96, height: 96),
                                           loop: true)
        let collector = FrameCollector()
        source.onFrame = { collector.add($0) }
        try source.start()
        _ = waitUntil(timeout: 3.0) { collector.count >= 4 }
        source.stop()
        let afterStop = collector.count
        // Any callback in flight completed during stop()'s drain; none may start.
        usleep(400_000)
        let later = collector.count
        guard later == afterStop else {
            throw SelfTestError.mismatch("stop: \(later - afterStop) frame(s) emitted after stop()")
        }
        guard source.state == .idle else {
            throw SelfTestError.mismatch("stop: state \(source.state), expected idle")
        }
        print("  ✓ AnimatedGIFSource[stop]: \(afterStop) frames before stop, 0 after, state idle")
    }

    // MARK: - 5. Decode budget: over-budget preload → typed throw at init

    private static func testDecodeBudget() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_gif_budget_\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeSyntheticGIF(to: tmp, frames: 6, w: 48, h: 48, delay: 0.05)
        let canvas = CanvasSize(width: 96, height: 96)

        // Over budget by BYTES: a 1 KiB decoded-byte budget rejects 6·96·96·4 B.
        try assertThrowsInvalidConfiguration("budget(bytes)") {
            _ = try AnimatedGIFSource(id: SourceID("selftest.gif.budget.bytes"),
                                      fileURL: tmp, canvasSize: canvas, contentMode: .stretch,
                                      background: .black, loop: true,
                                      maxFrameCount: AnimatedGIFSource.defaultMaxFrameCount,
                                      maxDecodedBytes: 1024)
        }

        // Over budget by FRAME COUNT: a max of 2 rejects the 6-frame GIF.
        try assertThrowsInvalidConfiguration("budget(count)") {
            _ = try AnimatedGIFSource(id: SourceID("selftest.gif.budget.count"),
                                      fileURL: tmp, canvasSize: canvas, contentMode: .stretch,
                                      background: .black, loop: true,
                                      maxFrameCount: 2,
                                      maxDecodedBytes: AnimatedGIFSource.defaultMaxDecodedBytes)
        }

        // Control: the SAME GIF under the DEFAULT budget decodes fine and plays.
        let ok = try AnimatedGIFSource(id: SourceID("selftest.gif.budget.ok"),
                                       fileURL: tmp, canvasSize: canvas, contentMode: .stretch,
                                       background: .black, loop: true)
        guard ok.frameCount == 6 else {
            throw SelfTestError.mismatch("budget(ok): expected 6 frames, got \(ok.frameCount)")
        }
        let collector = FrameCollector()
        ok.onFrame = { collector.add($0) }
        try ok.start()
        defer { ok.stop() }
        _ = waitUntil(timeout: 3.0) { collector.count >= 2 }
        guard collector.count >= 2 else {
            throw SelfTestError.mismatch("budget(ok): GIF did not play under default budget")
        }
        print("  ✓ AnimatedGIFSource[budget]: tiny-byte + max-2-frame budgets throw invalidConfiguration; default budget decodes+plays 6 frames")
    }

    private static func assertThrowsInvalidConfiguration(_ what: String, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch let e as SourceError {
            if case .invalidConfiguration = e { return }
            throw SelfTestError.mismatch("\(what): wrong error \(e)")
        }
        throw SelfTestError.mismatch("\(what): init did not throw")
    }

    // MARK: - GIF generation

    /// Make a real multi-frame GIF at `url`. Returns `(origin, frameCount)` or
    /// `nil` if `ffmpeg` is unavailable. Prefers the canonical mp4 (real motion);
    /// falls back to distinct-colored synthesized frames.
    private static func makeAnimatedGIF(to url: URL) throws -> (origin: String, frames: Int)? {
        guard let ffmpeg = ffmpegPath() else { return nil }
        try? FileManager.default.removeItem(at: url)

        if FileManager.default.fileExists(atPath: realAssetPath) {
            // ffmpeg -y -i <mp4> -t 1 -vf fps=8,scale=160:-1 out.gif
            let ok = runProcess(ffmpeg, ["-y", "-loglevel", "error", "-i", realAssetPath,
                                         "-t", "1", "-vf", "fps=8,scale=160:-1", url.path])
            if ok, gifFrameCount(url) >= 2 {
                return ("mp4→gif fps=8", gifFrameCount(url))
            }
        }

        // Fallback: 6 distinct solid-color PNGs → GIF at 4 fps.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_gif_src_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let palette: [(Double, Double, Double)] = [
            (0.9, 0.1, 0.1), (0.1, 0.9, 0.1), (0.1, 0.1, 0.9),
            (0.9, 0.9, 0.1), (0.9, 0.1, 0.9), (0.1, 0.9, 0.9),
        ]
        for (i, c) in palette.enumerated() {
            let f = dir.appendingPathComponent(String(format: "f%02d.png", i))
            try writeSolidPNG(to: f, w: 160, h: 120, r: c.0, g: c.1, b: c.2)
        }
        let ok = runProcess(ffmpeg, ["-y", "-loglevel", "error", "-framerate", "4",
                                     "-i", dir.appendingPathComponent("f%02d.png").path,
                                     url.path])
        guard ok, gifFrameCount(url) >= 2 else { return nil }
        return ("color-frames→gif", gifFrameCount(url))
    }

    private static func gifFrameCount(_ url: URL) -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        return CGImageSourceGetCount(src)
    }

    private static func ffmpegPath() -> String? {
        for p in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    @discardableResult
    private static func runProcess(_ launch: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0
    }

    // MARK: - Synthetic GIF written directly with ImageIO (no ffmpeg)

    /// A tiny animated GIF written with `ImageIO` — used for the no-emit-after-stop
    /// check so it runs even without ffmpeg.
    private static func writeSyntheticGIF(to url: URL, frames: Int, w: Int, h: Int, delay: Double) throws {
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
            throw SelfTestError.setupFailed("GIF destination")
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        for i in 0..<frames {
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw SelfTestError.setupFailed("GIF frame context")
            }
            let t = Double(i) / Double(max(frames - 1, 1))
            ctx.setFillColor(CGColor(srgbRed: CGFloat(t), green: CGFloat(1 - t), blue: 0.4, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: CGFloat(t) * CGFloat(w - 8), y: 0, width: 8, height: CGFloat(h)))
            guard let img = ctx.makeImage() else { throw SelfTestError.setupFailed("GIF makeImage") }
            CGImageDestinationAddImage(dest, img, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay]
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw SelfTestError.setupFailed("GIF finalize") }
    }

    private static func writeSolidPNG(to url: URL, w: Int, h: Int, r: Double, g: Double, b: Double) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SelfTestError.setupFailed("PNG context")
        }
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = ctx.makeImage() else { throw SelfTestError.setupFailed("PNG makeImage") }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SelfTestError.setupFailed("PNG destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw SelfTestError.setupFailed("PNG finalize") }
    }

    // MARK: - PNG dump (eyeball a few frames across the loop)

    private static func dumpPNGs(_ frames: [VideoFrame], prefix: String) throws {
        guard !frames.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dumpDir, withIntermediateDirectories: true)
        // Sample up to 6 frames spread across the collected span (spans the loop).
        let n = min(6, frames.count)
        for k in 0..<n {
            let idx = frames.count == 1 ? 0 : k * (frames.count - 1) / max(n - 1, 1)
            let path = "\(dumpDir)/\(prefix)_\(String(format: "%02d", k))_frame\(idx).png"
            writeFramePNG(frames[idx], to: path)
        }
        print("    ↳ dumped \(n) PNGs across the loop to \(dumpDir)/")
    }

    private static func writeFramePNG(_ f: VideoFrame, to path: String) {
        let buffer = f.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base, width: f.width, height: f.height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: cs, bitmapInfo: info),
              let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func shortDelays(_ d: [Double]) -> String {
        let head = d.prefix(4).map { String(format: "%.3f", $0) }.joined(separator: ",")
        return d.count > 4 ? "[\(head),…]" : "[\(head)]"
    }
}
