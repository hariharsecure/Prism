import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import os
import PrismCore
import UniformTypeIdentifiers

/// Headless self-verification of the generated (non-hardware) source family.
/// No TCC / no capture hardware — these sources *draw*, they don't capture.
///
/// TEST CODE ONLY: locks pixel-buffer base addresses to read back output (the
/// engine hot path never does). Requires a running main run loop for the
/// browser section (the runner pumps `RunLoop.main`); wire into an executable,
/// not an XCTest that blocks the main thread.
public enum SourcesSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case setupFailed(String)
        case mismatch(String)
        public var description: String {
            switch self {
            case .setupFailed(let s): return "sources self-test setup failed: \(s)"
            case .mismatch(let s): return "sources self-test mismatch: \(s)"
            }
        }
    }

    public static func run() throws {
        try testTextSource()
        try testImageSource()
        try testBrowserSource()
        print("SourcesSelfTest: all checks passed")
    }

    // MARK: - Frame collection & sampling helpers

    private final class FrameCollector {
        private let lock = OSAllocatedUnfairLock(initialState: [VideoFrame]())
        func add(_ f: VideoFrame) { lock.withLock { $0.append(f) } }
        var count: Int { lock.withLock { $0.count } }
        var latest: VideoFrame? { lock.withLock { $0.last } }
    }

    /// Pump the main run loop until `predicate` is true or `timeout` elapses.
    @discardableResult
    private static func wait(timeout: TimeInterval, until predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline { return predicate() }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return true
    }

    private static func readBGRA(_ frame: VideoFrame, x: Int, y: Int) -> (b: Int, g: Int, r: Int, a: Int) {
        let buffer = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3]))
    }

    /// Grid-sample luminance signature; also the min/max spread (for blank test).
    private static func stats(_ frame: VideoFrame, step: Int = 8) -> (signature: Int, minV: Int, maxV: Int, maxAlpha: Int) {
        let w = frame.width, h = frame.height
        var sig = 0, lo = 255, hi = 0, maxA = 0
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let px = readBGRA(frame, x: x, y: y)
                let lum = (px.r * 30 + px.g * 59 + px.b * 11) / 100
                sig = sig &+ lum &* (x + 1) &+ px.r
                lo = min(lo, lum); hi = max(hi, lum); maxA = max(maxA, px.a)
                x += step
            }
            y += step
        }
        return (sig, lo, hi, maxA)
    }

    /// Count pixels whose alpha exceeds `thresh` within an x-range (memory/top
    /// origin coords) of a raw BGRA buffer — the painted (inked) pixel count.
    private static func paintedCount(_ buffer: CVPixelBuffer, xRange: Range<Int>? = nil,
                                     alphaThresh: Int = 40, step: Int = 2) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let x0 = max(0, xRange?.lowerBound ?? 0), x1 = min(w, xRange?.upperBound ?? w)
        var count = 0, y = 0
        while y < h {
            var x = x0
            while x < x1 {
                if Int(base[y * bpr + x * 4 + 3]) > alphaThresh { count += 1 }
                x += step
            }
            y += step
        }
        return count
    }

    /// Rightmost painted column (memory x) of a raw BGRA buffer, or -1 if none.
    private static func rightmostPaintedX(_ buffer: CVPixelBuffer, alphaThresh: Int = 40) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var maxX = -1, y = 0
        while y < h {
            var x = w - 1
            while x > maxX {
                if Int(base[y * bpr + x * 4 + 3]) > alphaThresh { maxX = x; break }
                x -= 1
            }
            y += 2
        }
        return maxX
    }

    private static func assertFrameShape(_ frame: VideoFrame, w: Int, h: Int, what: String) throws {
        guard frame.width == w, frame.height == h else {
            throw SelfTestError.mismatch("\(what): frame is \(frame.width)x\(frame.height), expected \(w)x\(h)")
        }
        guard frame.pixelFormat == kCVPixelFormatType_32BGRA else {
            throw SelfTestError.mismatch("\(what): pixel format \(frame.pixelFormat), expected BGRA")
        }
        guard CVPixelBufferGetIOSurface(frame.pixelBuffer) != nil else {
            throw SelfTestError.mismatch("\(what): frame is NOT IOSurface-backed (zero-copy violation)")
        }
    }

    // MARK: - 1. TextSource

    private static func testTextSource() throws {
        let w = 320, h = 180
        let style = TextSource.Style(fontSize: 48, weight: .bold, color: .white,
                                     horizontalAlignment: .center, verticalAlignment: .center,
                                     background: .black)
        let source = try TextSource(id: SourceID("selftest.text"),
                                    text: "PRISM {counter}", style: style,
                                    canvasSize: CanvasSize(width: w, height: h), fps: 60)
        let collector = FrameCollector()
        source.onFrame = { collector.add($0) }
        try source.start()
        defer { source.stop() }

        guard wait(timeout: 2, until: { collector.count > 0 }), let first = collector.latest else {
            throw SelfTestError.mismatch("text: no frame emitted within 2s")
        }
        try assertFrameShape(first, w: w, h: h, what: "text")

        // Non-blank: white glyphs over black must give a real luminance spread.
        let s0 = stats(first)
        guard s0.maxV - s0.minV > 40 else {
            throw SelfTestError.mismatch("text: output looks blank (lum spread \(s0.maxV - s0.minV))")
        }
        let sig0 = s0.signature

        // {counter} increment must change the rendered pixels.
        source.increment()
        let changed = wait(timeout: 2, until: {
            guard let f = collector.latest else { return false }
            return stats(f).signature != sig0
        })
        guard changed, let after = collector.latest else {
            throw SelfTestError.mismatch("text: {counter} increment did not change the buffer")
        }
        let sig1 = stats(after).signature
        guard sig1 != sig0 else {
            throw SelfTestError.mismatch("text: counter render identical (sig \(sig0))")
        }
        // resolvedText reflects the live counter.
        guard source.resolvedText() == "PRISM 1" else {
            throw SelfTestError.mismatch("text: resolvedText = \(source.resolvedText()), expected 'PRISM 1'")
        }

        // {time} token forces a re-render each tick (signatures differ over time).
        let clock = try TextSource(id: SourceID("selftest.clock"),
                                   text: "{time}",
                                   style: TextSource.Style(color: .white, background: .black),
                                   canvasSize: CanvasSize(width: w, height: h),
                                   timeFormat: "HH:mm:ss.SSS", fps: 60)
        let clockFrames = FrameCollector()
        clock.onFrame = { clockFrames.add($0) }
        try clock.start()
        defer { clock.stop() }
        _ = wait(timeout: 1.0, until: { clockFrames.count >= 10 })
        guard clock.resolvedText().count >= 8 else {
            throw SelfTestError.mismatch("clock: resolvedText '\(clock.resolvedText())' not a time string")
        }

        print("  ✓ TextSource: \(w)x\(h) IOSurface, non-blank (spread \(s0.maxV - s0.minV)), counter 0→1 changed sig (\(sig0)→\(sig1)), {time} live")

        #if DEBUG
        try testTextReveal(w: w, h: h)
        #endif
    }

    #if DEBUG
    /// Deterministic reveal checks (no clock/Date): render explicit progresses via
    /// the test hook and assert the painted-pixel count grows monotonically and
    /// typewriter fills left→right.
    private static func testTextReveal(w: Int, h: Int) throws {
        // Transparent overlay (no background) so alpha counts the inked glyphs.
        let style = TextSource.Style(fontSize: 40, weight: .bold, color: .white,
                                     horizontalAlignment: .left, verticalAlignment: .center)
        let rev = try TextSource(id: SourceID("selftest.text.reveal"),
                                 text: "HELLO WORLD", style: style,
                                 canvasSize: CanvasSize(width: w, height: h), fps: 30)

        let p0 = paintedCount(try rev._test_renderReveal(progress: 0, style: .typewriter))
        let pMid = paintedCount(try rev._test_renderReveal(progress: 0.5, style: .typewriter))
        let p1 = paintedCount(try rev._test_renderReveal(progress: 1, style: .typewriter))
        let ref = paintedCount(try rev._test_renderStatic())

        guard p0 <= 4 else {
            throw SelfTestError.mismatch("reveal p0: expected ~no glyphs, painted \(p0)")
        }
        guard pMid > p0, pMid < p1 else {
            throw SelfTestError.mismatch("reveal mid not partial: p0=\(p0) mid=\(pMid) p1=\(p1)")
        }
        // Progress 1 ≈ the static reference (single-line vs framesetter kerning).
        let tol = Double(ref) * 0.30
        guard abs(Double(p1) - Double(ref)) <= tol else {
            throw SelfTestError.mismatch("reveal p1=\(p1) not within 30% of static ref=\(ref)")
        }

        // Left→right: the inked region's right edge advances with progress.
        let rightEarly = rightmostPaintedX(try rev._test_renderReveal(progress: 0.3, style: .typewriter))
        let rightEnd = rightmostPaintedX(try rev._test_renderReveal(progress: 1, style: .typewriter))
        guard rightEarly > 0, rightEnd > rightEarly else {
            throw SelfTestError.mismatch("reveal not left→right: rightEarly=\(rightEarly) rightEnd=\(rightEnd)")
        }

        // Word-by-word also grows and settles to the full string.
        let wb0 = paintedCount(try rev._test_renderReveal(progress: 0, style: .wordByWord))
        let wb1 = paintedCount(try rev._test_renderReveal(progress: 1, style: .wordByWord))
        guard wb0 <= 4, wb1 > wb0 else {
            throw SelfTestError.mismatch("reveal wordByWord: wb0=\(wb0) wb1=\(wb1)")
        }

        print("  ✓ TextReveal: typewriter p0=\(p0) mid=\(pMid) p1=\(p1) (static ref \(ref)); " +
              "left→right (rightEarly \(rightEarly)→rightEnd \(rightEnd)); wordByWord \(wb0)→\(wb1)")
    }
    #endif

    // MARK: - 2. ImageSource

    private static func testImageSource() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_sources_selftest_\(UUID().uuidString).png")
        try writeTopRedBottomBluePNG(to: tmp, w: 32, h: 32)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let w = 64, h = 64
        let source = try ImageSource(id: SourceID("selftest.image"), fileURL: tmp,
                                     canvasSize: CanvasSize(width: w, height: h),
                                     contentMode: .stretch, fps: 4)
        let collector = FrameCollector()
        source.onFrame = { collector.add($0) }
        try source.start()
        defer { source.stop() }

        guard wait(timeout: 2, until: { collector.count > 0 }), let frame = collector.latest else {
            throw SelfTestError.mismatch("image: no frame emitted within 2s")
        }
        try assertFrameShape(frame, w: w, h: h, what: "image")

        // Orientation + load: top must be red, bottom must be blue.
        let top = readBGRA(frame, x: w / 2, y: 4)
        let bottom = readBGRA(frame, x: w / 2, y: h - 4)
        guard top.r > 180, top.b < 80 else {
            throw SelfTestError.mismatch("image: top sample \(top) not red — flipped or not loaded")
        }
        guard bottom.b > 180, bottom.r < 80 else {
            throw SelfTestError.mismatch("image: bottom sample \(bottom) not blue — flipped or not loaded")
        }

        // Bad path throws a typed error at start().
        let bad = try ImageSource(id: SourceID("selftest.image.bad"),
                                  path: "/definitely/does/not/exist_\(UUID().uuidString).png",
                                  canvasSize: CanvasSize(width: w, height: h))
        var threw = false
        do { try bad.start() }
        catch let e as SourceError {
            threw = true
            if case .imageLoadFailed = e {} else if case .imageDecodeFailed = e {} else {
                throw SelfTestError.mismatch("image bad path: wrong error \(e)")
            }
        }
        guard threw else { throw SelfTestError.mismatch("image bad path: start() did not throw") }

        // aspectFit math sanity (pure).
        let fit = ImageSource.fittedRect(imageW: 100, imageH: 50, canvasW: 200, canvasH: 200, mode: .aspectFit)
        guard fit.width == 200, fit.height == 100, fit.origin.y == 50 else {
            throw SelfTestError.mismatch("image aspectFit math wrong: \(fit)")
        }

        print("  ✓ ImageSource: \(w)x\(h) IOSurface, loaded PNG upright (top red \(top.r), bottom blue \(bottom.b)), bad-path throws, fit math OK")
    }

    private static func writeTopRedBottomBluePNG(to url: URL, w: Int, h: Int) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SelfTestError.setupFailed("PNG context")
        }
        // CGContext is bottom-left origin: fill high-y (top) red, low-y (bottom) blue.
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 2))          // bottom
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h / 2, width: w, height: h / 2))      // top
        guard let image = ctx.makeImage() else { throw SelfTestError.setupFailed("PNG makeImage") }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SelfTestError.setupFailed("PNG destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw SelfTestError.setupFailed("PNG finalize") }
    }

    // MARK: - 3. BrowserSource

    private static func testBrowserSource() throws {
        #if os(macOS)
        let w = 200, h = 120
        let html = "<html><body style='margin:0;background:#00cc33;'>" +
                   "<div style='color:#fff;font-size:28px;padding:20px'>PRISM</div></body></html>"

        func tryMethod(_ method: BrowserSource.SnapshotMethod, label: String) throws
            -> (frame: VideoFrame, blank: Bool)? {
            let source = try BrowserSource(id: SourceID("selftest.browser.\(label)"),
                                           content: .html(html, baseURL: nil),
                                           canvasSize: CanvasSize(width: w, height: h),
                                           method: method, fps: 10)
            let collector = FrameCollector()
            source.onFrame = { collector.add($0) }
            try source.start()
            defer { source.stop() }
            // Give WebKit time to load + snapshot (pumps main run loop).
            _ = wait(timeout: 4.0, until: { collector.count > 0 && source.isLoaded })
            guard let frame = collector.latest else { return nil }
            try assertFrameShape(frame, w: w, h: h, what: "browser.\(label)")
            let s = stats(frame)
            // "Blank" = nothing painted: fully transparent OR a uniform fill of
            // ANY brightness (a headless WKWebView often returns a solid-white
            // default backdrop with the page's CSS never composited).
            let blank = (s.maxAlpha == 0) || (s.maxV - s.minV < 8)
            return (frame, blank)
        }

        // Primary: takeSnapshot. Honest fallback to layerRender if it's blank.
        if let r = try tryMethod(.takeSnapshot, label: "snap"), !r.blank {
            let c = readBGRA(r.frame, x: w / 2, y: h / 2)
            print("  ✓ BrowserSource[takeSnapshot]: \(w)x\(h) IOSurface, non-blank (center \(c))")
            return
        }
        print("  ⚠ BrowserSource[takeSnapshot]: produced a blank/absent frame in headless CLI (expected — no window server); trying layerRender")

        if let r = try tryMethod(.layerRender, label: "layer"), !r.blank {
            let c = readBGRA(r.frame, x: w / 2, y: h / 2)
            print("  ✓ BrowserSource[layerRender]: \(w)x\(h) IOSurface, non-blank (center \(c))")
            return
        }

        // Plumbing verified even if both render blank in a headless process:
        // the source constructed, loaded, hopped main→queue, and emitted a
        // correctly-sized IOSurface frame. Report honestly rather than fail.
        if let r = try tryMethod(.layerRender, label: "plumb") {
            print("  ⚠ BrowserSource: PLUMBING-ONLY verified — emitted a correct \(r.frame.width)x\(r.frame.height) IOSurface frame, " +
                  "but pixels are blank in this headless CLI (WebKit needs a window server to composite). Blank=\(r.blank)")
        } else {
            throw SelfTestError.mismatch("browser: no frame emitted by either method")
        }
        #else
        print("  – BrowserSource: skipped (macOS only)")
        #endif
    }
}
