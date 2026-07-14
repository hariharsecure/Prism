import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os
import PrismCore

/// Headless self-verification of `MovieSource`.
///
/// Two parts:
///  1. **Synthetic short clip (always runs, no external asset).** Writes a ~1 s
///     moving clip to a temp file, plays it with `loop: true`, and asserts the
///     emitted frames are IOSurface-backed BGRA at canvas size, non-black,
///     change frame-to-frame (real motion), that a bad path throws, and — since
///     more frames come out than the clip contains — that it **looped**.
///  2. **Real asset (skipped gracefully if absent).** Decodes
///     `$PRISM_SELFTEST_MOVIE` and reports
///     frame count, IOSurface/BGRA/size, non-black, and frame-to-frame meanDiff.
///
/// TEST CODE ONLY: locks pixel-buffer base addresses to read back output.
/// `MovieSource` emits on its own background queue, so this pumps no run loop —
/// it just polls with a deadline.
public enum MovieSourceSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case setupFailed(String)
        case mismatch(String)
        public var description: String {
            switch self {
            case .setupFailed(let s): return "movie self-test setup failed: \(s)"
            case .mismatch(let s): return "movie self-test mismatch: \(s)"
            }
        }
    }

    /// The canonical real test asset (guarded — missing is a skip, not a failure).
    public static let realAssetPath = (ProcessInfo.processInfo.environment["PRISM_SELFTEST_MOVIE"] ?? "")

    public static func run() throws {
        try testSyntheticLoopAndMotion()
        try testRealAssetIfPresent()
        print("MovieSourceSelfTest: all checks passed")
    }

    // MARK: - Frame collection

    private final class FrameCollector: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: [VideoFrame]())
        func add(_ f: VideoFrame) { lock.withLock { $0.append(f) } }
        var count: Int { lock.withLock { $0.count } }
        func snapshot() -> [VideoFrame] { lock.withLock { $0 } }
    }

    private final class AudioCounter: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: 0)
        func bump() { lock.withLock { $0 += 1 } }
        var count: Int { lock.withLock { $0 } }
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

    /// Luminance min/max spread over a grid — a blank/black frame has ~0 spread.
    private static func spread(_ f: VideoFrame, step: Int = 16) -> Int {
        let w = f.width, h = f.height
        var lo = 255, hi = 0
        var y = 0
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

    /// Mean absolute per-channel difference between two frames (0…255 scale) on a
    /// grid — quantifies motion. A frozen/blank decode gives ~0.
    private static func meanDiff(_ a: VideoFrame, _ b: VideoFrame, step: Int = 16) -> Double {
        guard a.width == b.width, a.height == b.height else { return .infinity }
        let w = a.width, h = a.height
        var total = 0, n = 0
        var y = 0
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

    // Pick a frame with the widest luma spread — the most "real" content frame.
    private static func widestSpread(_ frames: [VideoFrame]) -> (VideoFrame, Int)? {
        var best: (VideoFrame, Int)?
        for f in frames {
            let s = spread(f)
            if best == nil || s > best!.1 { best = (f, s) }
        }
        return best
    }

    // Largest frame-to-frame meanDiff across the collected frames.
    private static func maxMotion(_ frames: [VideoFrame]) -> Double {
        guard frames.count > 1 else { return 0 }
        var best = 0.0
        var i = 1
        while i < frames.count {
            best = max(best, meanDiff(frames[i - 1], frames[i]))
            i += 1
        }
        return best
    }

    // Largest meanDiff between frames spaced `stride` apart — captures real
    // motion on slowly-changing content (a frozen decode is still 0 everywhere).
    private static func maxSpacedMotion(_ frames: [VideoFrame], stride: Int) -> Double {
        guard frames.count > stride, stride > 0 else { return maxMotion(frames) }
        var best = 0.0
        var i = stride
        while i < frames.count {
            best = max(best, meanDiff(frames[i - stride], frames[i]))
            i += stride
        }
        return best
    }

    // MARK: - 1. Synthetic clip: loop + motion + shape + bad path

    private static func testSyntheticLoopAndMotion() throws {
        let clipFrames = 24
        let fps = 24.0
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_movie_selftest_\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeMovingClip(to: tmp, frames: clipFrames, size: CGSize(width: 240, height: 180), fps: fps)

        let cw = 320, ch = 180
        let source = try MovieSource(id: SourceID("selftest.movie.synth"),
                                     fileURL: tmp,
                                     canvasSize: CanvasSize(width: cw, height: ch),
                                     contentMode: .aspectFit, loop: true)
        let collector = FrameCollector()
        source.onFrame = { collector.add($0) }
        try source.start()
        defer { source.stop() }

        // Collect long enough (~2.4 s) to overrun the 1 s clip → must loop.
        _ = waitUntil(timeout: 4.0) { collector.count > clipFrames + clipFrames / 2 }
        let frames = collector.snapshot()
        guard let first = frames.first else {
            throw SelfTestError.mismatch("synthetic: no frame emitted")
        }
        try assertShape(first, w: cw, h: ch, what: "synthetic")

        guard let (_, sp) = widestSpread(frames), sp > 30 else {
            throw SelfTestError.mismatch("synthetic: frames look blank/black (spread \(widestSpread(frames)?.1 ?? -1))")
        }
        let motion = maxMotion(frames)
        guard motion > 2.0 else {
            throw SelfTestError.mismatch("synthetic: no frame-to-frame motion (maxMeanDiff \(motion))")
        }
        // Looped: more frames than the clip contains, produced continuously.
        guard frames.count > clipFrames else {
            throw SelfTestError.mismatch("synthetic: only \(frames.count) frames (clip has \(clipFrames)) — did not loop")
        }

        // Bad path throws a typed error at init (missing file).
        var threw = false
        do {
            _ = try MovieSource(path: "/definitely/missing_\(UUID().uuidString).mov")
        } catch let e as SourceError {
            threw = true
            if case .mediaLoadFailed = e {} else {
                throw SelfTestError.mismatch("synthetic bad path: wrong error \(e)")
            }
        }
        guard threw else { throw SelfTestError.mismatch("synthetic bad path: init did not throw") }

        print(String(format: "  ✓ MovieSource[synthetic]: %dx%d IOSurface BGRA, spread %d, maxMeanDiff %.1f, looped (%d frames > %d-frame clip), bad-path throws",
                     cw, ch, sp, motion, frames.count, clipFrames))
    }

    // MARK: - 2. Real asset (guarded)

    private static func testRealAssetIfPresent() throws {
        guard FileManager.default.fileExists(atPath: realAssetPath) else {
            print("  – MovieSource[real asset]: SKIPPED — \(realAssetPath) not present")
            return
        }
        let cw = 640, ch = 360
        let source = try MovieSource(id: SourceID("selftest.movie.real"),
                                     path: realAssetPath,
                                     canvasSize: CanvasSize(width: cw, height: ch),
                                     contentMode: .aspectFit, loop: true)
        let audio = AudioCounter()
        source.onAudio = { _ in audio.bump() }
        let collector = FrameCollector()
        source.onFrame = { collector.add($0) }
        try source.start()
        defer { source.stop() }

        // Collect ~2.5 s of frames — enough to move past the clip's slow opening
        // fade so the motion check has a comfortable margin.
        let want = 60
        _ = waitUntil(timeout: 8.0) { collector.count >= want }
        let frames = collector.snapshot()
        guard frames.count >= 24 else {
            throw SelfTestError.mismatch("real: only \(frames.count) frames in 8 s (wanted ≥24)")
        }
        for f in [frames.first!, frames[frames.count / 2], frames.last!] {
            try assertShape(f, w: cw, h: ch, what: "real")
        }
        guard let (_, sp) = widestSpread(frames), sp > 20 else {
            throw SelfTestError.mismatch("real: frames look blank/black (spread \(widestSpread(frames)?.1 ?? -1))")
        }
        // Spaced comparison (~0.5 s apart) — robust to the slow opening fade.
        // M11: threshold raised 1.0 → 1.5. Real motion here is typically ~2–3, so
        // 1.5 keeps clear margin above a near-frozen decode (which sits near 0)
        // while staying well below live content — a stuck decode now fails.
        let motion = maxSpacedMotion(frames, stride: max(1, frames.count / 6))
        guard motion > 1.5 else {
            throw SelfTestError.mismatch("real: no/near-frozen motion across the clip (maxSpacedMeanDiff \(motion), need > 1.5)")
        }
        print(String(format: "  ✓ MovieSource[real asset]: %d frames %dx%d IOSurface BGRA, native %.0fx%.0f @%.0ffps, spread %d, maxSpacedMeanDiff %.1f, audioPackets %d, hasAudio %@",
                     frames.count, cw, ch, source.nativeSize.width, source.nativeSize.height,
                     source.nominalFrameRate, sp, motion, audio.count, source.hasAudioTrack ? "true" : "false"))
    }

    // MARK: - Synthetic clip writer (moving content → real motion)

    private static func writeMovingClip(to url: URL, frames: Int, size: CGSize, fps: Double) throws {
        try? FileManager.default.removeItem(at: url)
        let w = Int(size.width), h = Int(size.height)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mov) }
        catch { throw SelfTestError.setupFailed("AVAssetWriter: \(error)") }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ])
        guard writer.canAdd(input) else { throw SelfTestError.setupFailed("cannot add writer input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw SelfTestError.setupFailed("startWriting: \(String(describing: writer.error))")
        }
        writer.startSession(atSourceTime: .zero)

        let pool = try PixelBufferPool(width: w, height: h)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let scale = CMTimeScale(600)

        for i in 0..<frames {
            let buffer = try pool.makeBuffer()
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer),
               let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                   space: colorSpace, bitmapInfo: bitmapInfo) {
                // Sweeping background hue + a moving white bar → strong motion.
                let t = Double(i) / Double(max(frames - 1, 1))
                ctx.setFillColor(CGColor(srgbRed: CGFloat(t), green: CGFloat(1 - t), blue: 0.4, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                let barX = CGFloat(t) * CGFloat(w - 30)
                ctx.fill(CGRect(x: barX, y: 0, width: 30, height: CGFloat(h)))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            while !input.isReadyForMoreMediaData { usleep(2_000) }
            let pts = CMTime(value: CMTimeValue(Double(i) / fps * Double(scale)), timescale: scale)
            guard adaptor.append(buffer, withPresentationTime: pts) else {
                throw SelfTestError.setupFailed("adaptor.append failed at frame \(i): \(String(describing: writer.error))")
            }
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed else {
            throw SelfTestError.setupFailed("finishWriting status \(writer.status.rawValue): \(String(describing: writer.error))")
        }
    }
}
