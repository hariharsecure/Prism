import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import os
import PrismCore
import UniformTypeIdentifiers

/// Headless self-verification of `MontageSource` (design Build B).
///
/// Parts (all synthetic — no external asset needed):
///  1. **Image montage** of 4 visually-distinct gradient images. Asserts frames
///     are IOSurface BGRA at canvas size; the montage ADVANCES through the items
///     IN ORDER (each dwell's frame matches that item's hue; a big meanDiff
///     between an early and a later frame); a `.crossfade` midpoint is a GENUINE
///     blend of two items (distinct from either); Ken Burns actually MOVES a
///     still (frame-to-frame diff within one dwell > 0, and ~0 with KB off).
///  2. **Video item** montage (image → synthetic moving clip → image): the
///     embedded `MovieSource` decodes (motion during its dwell), the montage
///     advances past it, and every started video source is stopped
///     (`movieStartCount == movieStopCount` — no leak).
///  3. **Shuffle determinism** — a pure check that the seeded order is stable per
///     seed and varies across seeds.
///  4. Dumps a PNG sequence (≥2 item switches + a crossfade) for the lead to
///     eyeball the cycling.
///
/// TEST CODE ONLY: locks pixel-buffer base addresses to read back output.
public enum MontageSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case setupFailed(String)
        case mismatch(String)
        public var description: String {
            switch self {
            case .setupFailed(let s): return "montage self-test setup failed: \(s)"
            case .mismatch(let s): return "montage self-test mismatch: \(s)"
            }
        }
    }

    /// Where the eyeball PNG sequence is dumped.
    public static let pngDumpDir =
        "/tmp/prism_montage"

    /// A real clip WITH an AAC audio track — used (guarded; skipped if absent) to
    /// exercise the per-item audio path against a genuine encoded soundtrack.
    public static let realAudioAssetPath =
        (ProcessInfo.processInfo.environment["PRISM_SELFTEST_MOVIE"] ?? "")

    public static func run() throws {
        try testShuffleDeterminism()
        try testImageMontageAdvanceCrossfadeKenBurns()
        try testVideoItemLifecycle()
        try testCrossfadeIntoVideoNoBlackFlash()   // T3
        try testAllVideoMontageNoBlackFlash()      // T3
        try testSingleItemMontage()                // T6
        try testLaterItemDecodeFailureKeepsRunning() // T6
        try testStopFromCallback()                 // T6
        try testAudioFromVideoItemAndImageSilence() // A1: per-item audio + silence
        try testAudioStopsOnAdvanceAndSwitches()    // A2: one-emitter, stop-on-advance
        print("MontageSelfTest: all checks passed")
    }

    /// Mean luminance (0…255) over a grid — a background/black flash reads near 0.
    private static func meanLuma(_ f: VideoFrame, step: Int = 12) -> Double {
        let c = meanColor(f, step: step)
        return 0.30 * c.r + 0.59 * c.g + 0.11 * c.b
    }

    // MARK: - Frame collection

    private struct Captured { let t: Double; let frame: VideoFrame }

    private final class FrameCollector: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: [VideoFrame]())
        func add(_ f: VideoFrame) { lock.withLock { $0.append(f) } }
        var count: Int { lock.withLock { $0.count } }
        func snapshot() -> [VideoFrame] { lock.withLock { $0 } }
    }

    /// One captured audio packet: its house-time PTS, the emitting source id (the
    /// embedded clip's `MovieSource`, unique per montage visit) and the house-time
    /// second it ARRIVED (for the no-overlap / stop-on-advance proofs).
    private struct AudioCap { let pts: Double; let source: String; let arrival: Double }

    private final class AudioCollector: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: [AudioCap]())
        func add(_ p: AudioPacket) {
            let arrival = HouseClock.nowSeconds()
            let cap = AudioCap(pts: p.pts.seconds, source: p.source.raw, arrival: arrival)
            lock.withLock { $0.append(cap) }
        }
        var count: Int { lock.withLock { $0.count } }
        func snapshot() -> [AudioCap] { lock.withLock { $0 } }
    }

    @discardableResult
    private static func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline { return predicate() }
            usleep(5_000)
        }
        return true
    }

    /// Rebase collected frames onto seconds-from-first (house-time relative).
    private static func timeline(_ frames: [VideoFrame]) -> [Captured] {
        guard let first = frames.first else { return [] }
        let base = first.pts
        return frames.map { Captured(t: CMTimeSubtract($0.pts, base).seconds, frame: $0) }
    }

    /// The captured frame whose relative time is closest to `t`.
    private static func nearest(_ caps: [Captured], to t: Double) -> Captured? {
        caps.min { abs($0.t - t) < abs($1.t - t) }
    }

    // MARK: - Pixel read-back

    private static func readBGRA(_ b: CVPixelBuffer, x: Int, y: Int) -> (b: Int, g: Int, r: Int) {
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
            + y * CVPixelBufferGetBytesPerRow(b) + x * 4
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }

    /// Mean B/G/R over a grid.
    private static func meanColor(_ f: VideoFrame, step: Int = 12) -> (b: Double, g: Double, r: Double) {
        let w = f.width, h = f.height
        var sb = 0, sg = 0, sr = 0, n = 0
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let px = readBGRA(f.pixelBuffer, x: x, y: y)
                sb += px.b; sg += px.g; sr += px.r; n += 1
                x += step
            }
            y += step
        }
        guard n > 0 else { return (0, 0, 0) }
        return (Double(sb) / Double(n), Double(sg) / Double(n), Double(sr) / Double(n))
    }

    /// Mean absolute per-channel difference (0…255) over a grid.
    private static func meanDiff(_ a: VideoFrame, _ b: VideoFrame, step: Int = 12) -> Double {
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

    private enum Hue: String { case red, green, blue, yellow }

    /// Which hue a mean color reads as (mutually-exclusive gates); nil if ambiguous.
    private static func classify(_ c: (b: Double, g: Double, r: Double)) -> Hue? {
        let rHi = c.r > 90, gHi = c.g > 90, bHi = c.b > 90
        let rLo = c.r < 60, gLo = c.g < 60, bLo = c.b < 60
        if rHi && gLo && bLo { return .red }
        if gHi && rLo && bLo { return .green }
        if bHi && rLo && gLo { return .blue }
        if rHi && gHi && bLo { return .yellow }
        return nil
    }

    // MARK: - 1. Image montage: advance + order + crossfade + Ken Burns

    private static func testImageMontageAdvanceCrossfadeKenBurns() throws {
        let cw = 480, ch = 270
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_montage_imgs_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 4 visually-distinct diagonal-gradient images (800x400, non-canvas aspect
        // so Ken-Burns overscan has room to pan). Gradient structure = KB has
        // something to move; dominant hue = per-item identity.
        let hues: [(Hue, (Double, Double, Double))] = [
            (.red, (1, 0, 0)), (.green, (0, 1, 0)), (.blue, (0, 0, 1)), (.yellow, (1, 1, 0)),
        ]
        var urls: [URL] = []
        for (i, (hue, base)) in hues.enumerated() {
            let u = dir.appendingPathComponent("item_\(i)_\(hue.rawValue).png")
            try writeGradientPNG(to: u, w: 800, h: 400, base: base)
            urls.append(u)
        }

        let interval = 0.40
        let cfDur = 0.15
        // --- Ken-Burns ON montage with crossfade ---
        let montage = try MontageSource(id: SourceID("selftest.montage.img"),
                                        items: urls.map { MontageSource.MontageItem(url: $0, kind: .image) },
                                        canvasSize: CanvasSize(width: cw, height: ch),
                                        interval: interval, transition: .crossfade(duration: cfDur),
                                        kenBurns: true, shuffle: false, loop: true, fps: 30)
        let collector = FrameCollector()
        montage.onFrame = { collector.add($0) }
        try montage.start()
        // Collect ~2.05 s → items 0,1,2,3 (+wrap) with two crossfades inside.
        _ = waitUntil(timeout: 5.0) {
            guard let f = collector.snapshot().first else { return false }
            return CMTimeSubtract(HouseClock.now(), f.pts).seconds > 2.05
        }
        montage.stop()

        let caps = timeline(collector.snapshot())
        guard caps.count > 30 else {
            throw SelfTestError.mismatch("image montage: only \(caps.count) frames collected")
        }
        // Shape on first / mid / last.
        for c in [caps.first!, caps[caps.count / 2], caps.last!] {
            try assertShape(c.frame, w: cw, h: ch, what: "image montage")
        }

        // (a) ADVANCE + ORDER: each dwell's early frame (before the crossfade
        // window) reads as that item's hue, in list order red→green→blue→yellow.
        let expected: [Hue] = [.red, .green, .blue, .yellow]
        var itemFrames: [Hue: VideoFrame] = [:]
        for (k, hue) in expected.enumerated() {
            let target = Double(k) * interval + 0.06        // early in dwell k
            guard let cap = nearest(caps, to: target) else {
                throw SelfTestError.mismatch("image montage: no frame near t=\(target)")
            }
            let mc = meanColor(cap.frame)
            guard classify(mc) == hue else {
                throw SelfTestError.mismatch("image montage: dwell \(k) at t≈\(String(format: "%.2f", cap.t)) reads \(classify(mc).map { $0.rawValue } ?? "ambiguous") (\(fmt(mc))), expected \(hue.rawValue) — montage did not advance in order")
            }
            itemFrames[hue] = cap.frame
        }
        // Advance magnitude: red dwell vs blue dwell frames differ a LOT.
        let advDiff = meanDiff(itemFrames[.red]!, itemFrames[.blue]!)
        guard advDiff > 30 else {
            throw SelfTestError.mismatch("image montage: red↔blue meanDiff \(advDiff) too small — not really switching items")
        }

        // (b) CROSSFADE midpoint: at t ≈ interval - cfDur/2 we blend red→green.
        // The blended frame must be DISTINCT from both pure items (a real mix).
        guard let cf = nearest(caps, to: interval - cfDur / 2) else {
            throw SelfTestError.mismatch("image montage: no crossfade frame")
        }
        let cfDiffRed = meanDiff(cf.frame, itemFrames[.red]!)
        let cfDiffGreen = meanDiff(cf.frame, itemFrames[.green]!)
        let cfColor = meanColor(cf.frame)
        guard cfDiffRed > 10, cfDiffGreen > 10 else {
            throw SelfTestError.mismatch("image montage: crossfade frame at t≈\(String(format: "%.2f", cf.t)) (\(fmt(cfColor))) not a blend — diffToRed \(cfDiffRed), diffToGreen \(cfDiffGreen)")
        }
        // A red→green blend lifts G above pure-red and R above pure-green.
        let redColor = meanColor(itemFrames[.red]!)
        let greenColor = meanColor(itemFrames[.green]!)
        guard cfColor.g > redColor.g + 15, cfColor.r > greenColor.r + 15 else {
            throw SelfTestError.mismatch("image montage: crossfade not mixing channels — cf \(fmt(cfColor)) vs red \(fmt(redColor)) green \(fmt(greenColor))")
        }

        // (c) KEN BURNS: two frames within item0's dwell (both before the
        // crossfade window) differ — the still is moving.
        guard let kb0 = nearest(caps, to: 0.04), let kb1 = nearest(caps, to: 0.22),
              kb0.t < 0.24, kb1.t < 0.24 else {
            throw SelfTestError.mismatch("image montage: could not sample two in-dwell frames for KB")
        }
        let kbMotion = meanDiff(kb0.frame, kb1.frame)
        guard kbMotion > 0.5 else {
            throw SelfTestError.mismatch("image montage: Ken Burns produced no motion within a dwell (meanDiff \(kbMotion))")
        }

        // (c-control) Same two instants with KB OFF ⇒ a static still ⇒ ~0 motion.
        let still = try MontageSource(id: SourceID("selftest.montage.static"),
                                      items: urls.map { MontageSource.MontageItem(url: $0, kind: .image) },
                                      canvasSize: CanvasSize(width: cw, height: ch),
                                      interval: interval, transition: .cut,
                                      kenBurns: false, shuffle: false, loop: true, fps: 30)
        let stillC = FrameCollector()
        still.onFrame = { stillC.add($0) }
        try still.start()
        _ = waitUntil(timeout: 3.0) {
            guard let f = stillC.snapshot().first else { return false }
            return CMTimeSubtract(HouseClock.now(), f.pts).seconds > 0.30
        }
        still.stop()
        let stillCaps = timeline(stillC.snapshot())
        var stillMotion = 0.0
        if let s0 = nearest(stillCaps, to: 0.04), let s1 = nearest(stillCaps, to: 0.22),
           s0.t < 0.30, s1.t < 0.30 {
            stillMotion = meanDiff(s0.frame, s1.frame)
        }
        guard stillMotion < kbMotion else {
            throw SelfTestError.mismatch("image montage: KB motion \(kbMotion) not greater than static motion \(stillMotion)")
        }

        // (d) Dump a PNG sequence for the lead to eyeball (≥2 switches + crossfade).
        let dumped = try dumpPNGSequence(caps, interval: interval, cfDur: cfDur)

        print(String(format: "  ✓ MontageSource[image]: %dx%d IOSurface BGRA, advanced red→green→blue→yellow (red↔blue meanDiff %.0f), crossfade midpoint blends (Δred %.0f Δgreen %.0f), KenBurns moves still (%.2f vs static %.2f), dumped %d PNGs",
                     cw, ch, advDiff, cfDiffRed, cfDiffGreen, kbMotion, stillMotion, dumped))
    }

    private static func fmt(_ c: (b: Double, g: Double, r: Double)) -> String {
        String(format: "r%.0f g%.0f b%.0f", c.r, c.g, c.b)
    }

    // MARK: - 2. Video item lifecycle (embedded MovieSource)

    private static func testVideoItemLifecycle() throws {
        let cw = 320, ch = 180
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_montage_vid_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let redURL = dir.appendingPathComponent("a_red.png")
        let blueURL = dir.appendingPathComponent("c_blue.png")
        let clipURL = dir.appendingPathComponent("b_clip.mov")
        try writeGradientPNG(to: redURL, w: 400, h: 300, base: (1, 0, 0))
        try writeGradientPNG(to: blueURL, w: 400, h: 300, base: (0, 0, 1))
        try writeMovingClip(to: clipURL, frames: 24, size: CGSize(width: 240, height: 180), fps: 24)

        let interval = 0.5
        let montage = try MontageSource(id: SourceID("selftest.montage.video"),
                                        items: [
                                            MontageSource.MontageItem(url: redURL, kind: .image),
                                            MontageSource.MontageItem(url: clipURL, kind: .video),
                                            MontageSource.MontageItem(url: blueURL, kind: .image),
                                        ],
                                        canvasSize: CanvasSize(width: cw, height: ch),
                                        interval: interval, transition: .cut,
                                        kenBurns: false, shuffle: false, loop: true, fps: 30)
        let collector = FrameCollector()
        montage.onFrame = { collector.add($0) }
        try montage.start()
        // ~1.6 s → red(0), clip(1), blue(2), red(0 again) — the clip enters & leaves.
        _ = waitUntil(timeout: 5.0) {
            guard let f = collector.snapshot().first else { return false }
            return CMTimeSubtract(HouseClock.now(), f.pts).seconds > 1.6
        }
        let startsBeforeStop = montage.movieStartCount.withLock { $0 }
        montage.stop()

        let caps = timeline(collector.snapshot())
        guard caps.count > 20 else {
            throw SelfTestError.mismatch("video montage: only \(caps.count) frames")
        }
        for c in [caps.first!, caps.last!] { try assertShape(c.frame, w: cw, h: ch, what: "video montage") }

        // Video dwell is item ordinal 1: t ∈ [0.5, 1.0). Two frames apart there
        // must differ — the embedded MovieSource is decoding real motion.
        guard let v0 = nearest(caps, to: 0.60), let v1 = nearest(caps, to: 0.90),
              v0.t >= 0.5, v1.t < 1.0 else {
            throw SelfTestError.mismatch("video montage: could not sample the video dwell")
        }
        let videoMotion = meanDiff(v0.frame, v1.frame)
        guard videoMotion > 2.0 else {
            throw SelfTestError.mismatch("video montage: no motion during the clip's dwell (meanDiff \(videoMotion)) — MovieSource not decoding")
        }

        // Advanced past the clip: t ≈ 1.1 is the blue image.
        guard let after = nearest(caps, to: 1.10) else {
            throw SelfTestError.mismatch("video montage: no post-clip frame")
        }
        guard classify(meanColor(after.frame)) == .blue else {
            throw SelfTestError.mismatch("video montage: after the clip reads \(fmt(meanColor(after.frame))), expected blue — did not advance past video")
        }

        // Lifecycle / no-leak: at least one video source started, and after stop()
        // every started MovieSource was stopped.
        let starts = montage.movieStartCount.withLock { $0 }
        let stops = montage.movieStopCount.withLock { $0 }
        guard startsBeforeStop >= 1 else {
            throw SelfTestError.mismatch("video montage: the clip's MovieSource never started (starts \(startsBeforeStop))")
        }
        guard starts == stops else {
            throw SelfTestError.mismatch("video montage: MovieSource leak — started \(starts), stopped \(stops)")
        }

        print(String(format: "  ✓ MontageSource[video]: embedded MovieSource decoded (dwell motion %.1f), advanced past clip to blue, lifecycle balanced (started=%d stopped=%d, no leak)",
                     videoMotion, starts, stops))
    }

    // MARK: - T3: no background/black flash at the transition INTO a video

    /// image → video `.crossfade`: pre-fix, the incoming video's async first frame
    /// wasn't ready at the commit boundary, so `drawSlot` painted nothing and the
    /// program showed the background (black) for a frame. Sample the frames around
    /// the boundary INTO the clip and assert none are near-black.
    private static func testCrossfadeIntoVideoNoBlackFlash() throws {
        let cw = 320, ch = 180
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_montage_cf_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let redURL = dir.appendingPathComponent("a_red.png")
        let clipURL = dir.appendingPathComponent("b_clip.mov")
        try writeGradientPNG(to: redURL, w: 400, h: 300, base: (1, 0, 0))
        try writeMovingClip(to: clipURL, frames: 24, size: CGSize(width: 240, height: 180), fps: 24)

        let interval = 0.4, cfDur = 0.15
        let montage = try MontageSource(id: SourceID("selftest.montage.cf.video"),
                                        items: [
                                            MontageSource.MontageItem(url: redURL, kind: .image),
                                            MontageSource.MontageItem(url: clipURL, kind: .video),
                                        ],
                                        canvasSize: CanvasSize(width: cw, height: ch),
                                        interval: interval, transition: .crossfade(duration: cfDur),
                                        kenBurns: false, shuffle: false, loop: true, fps: 30)
        let collector = FrameCollector()
        montage.onFrame = { collector.add($0) }
        try montage.start()
        _ = waitUntil(timeout: 5.0) {
            guard let f = collector.snapshot().first else { return false }
            return CMTimeSubtract(HouseClock.now(), f.pts).seconds > 1.1
        }
        montage.stop()

        let caps = timeline(collector.snapshot())
        guard caps.count > 20 else { throw SelfTestError.mismatch("cf-into-video: only \(caps.count) frames") }
        // The transition INTO the video is around t≈interval (0.4). Every frame in
        // [0.30, 0.70] must be bright — no background flash.
        var checked = 0, minLuma = Double.greatestFiniteMagnitude
        for c in caps where c.t >= 0.30 && c.t <= 0.70 {
            let l = meanLuma(c.frame)
            minLuma = min(minLuma, l)
            checked += 1
            guard l > 12 else {
                throw SelfTestError.mismatch(String(format: "cf-into-video: BLACK FLASH at t=%.2f (luma %.1f) — committed to a not-ready video", c.t, l))
            }
        }
        guard checked > 3 else { throw SelfTestError.mismatch("cf-into-video: too few boundary frames (\(checked))") }
        print(String(format: "  ✓ MontageSource[T3 crossfade→video]: no black flash across the boundary (min luma %.1f over %d frames)", minLuma, checked))
    }

    /// All-video montage with a SHORT interval — the incoming clip must be
    /// pre-rolled ready before each cut and the FIRST frame must not be background
    /// either. No captured frame (past a one-frame startup slack) is near-black.
    private static func testAllVideoMontageNoBlackFlash() throws {
        let cw = 240, ch = 160
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_montage_av_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let clipA = dir.appendingPathComponent("a.mov")
        let clipB = dir.appendingPathComponent("b.mov")
        try writeMovingClip(to: clipA, frames: 20, size: CGSize(width: 200, height: 140), fps: 24)
        try writeMovingClip(to: clipB, frames: 20, size: CGSize(width: 200, height: 140), fps: 24)

        let interval = 0.3
        let montage = try MontageSource(id: SourceID("selftest.montage.allvideo"),
                                        items: [
                                            MontageSource.MontageItem(url: clipA, kind: .video),
                                            MontageSource.MontageItem(url: clipB, kind: .video),
                                        ],
                                        canvasSize: CanvasSize(width: cw, height: ch),
                                        interval: interval, transition: .cut,
                                        kenBurns: false, shuffle: false, loop: true, fps: 30)
        let collector = FrameCollector()
        montage.onFrame = { collector.add($0) }
        try montage.start()
        _ = waitUntil(timeout: 5.0) {
            guard let f = collector.snapshot().first else { return false }
            return CMTimeSubtract(HouseClock.now(), f.pts).seconds > 1.2
        }
        let starts = montage.movieStartCount.withLock { $0 }
        montage.stop()

        let caps = timeline(collector.snapshot())
        guard caps.count > 20 else { throw SelfTestError.mismatch("all-video: only \(caps.count) frames") }
        // Skip the first frame (startup slack); no later frame may be near-black.
        var minLuma = Double.greatestFiniteMagnitude
        for c in caps.dropFirst() {
            let l = meanLuma(c.frame)
            minLuma = min(minLuma, l)
            guard l > 12 else {
                throw SelfTestError.mismatch(String(format: "all-video: BLACK FLASH at t=%.2f (luma %.1f)", c.t, l))
            }
        }
        guard starts >= 2 else { throw SelfTestError.mismatch("all-video: expected ≥2 clip starts, got \(starts)") }
        let stops = montage.movieStopCount.withLock { $0 }
        // start/stop may be off by the still-current slot at stop(); teardown balances it.
        guard stops >= starts - 2 else { throw SelfTestError.mismatch("all-video: leak (started \(starts), stopped \(stops))") }
        print(String(format: "  ✓ MontageSource[T3 all-video]: no black flash incl. startup (min luma %.1f, %d clip starts)", minLuma, starts))
    }

    // MARK: - T6: hardening coverage (single item / bad later item / stop-in-callback)

    /// A single-item montage loops that one item without crashing and keeps emitting.
    private static func testSingleItemMontage() throws {
        let cw = 200, ch = 120
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_montage_single_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let only = dir.appendingPathComponent("only.png")
        try writeGradientPNG(to: only, w: 300, h: 200, base: (0, 1, 0))

        let montage = try MontageSource(id: SourceID("selftest.montage.single"),
                                        items: [MontageSource.MontageItem(url: only, kind: .image)],
                                        canvasSize: CanvasSize(width: cw, height: ch),
                                        interval: 0.2, transition: .crossfade(duration: 0.1),
                                        kenBurns: true, shuffle: false, loop: true, fps: 30)
        let collector = FrameCollector()
        montage.onFrame = { collector.add($0) }
        try montage.start()
        _ = waitUntil(timeout: 3.0) {
            guard let f = collector.snapshot().first else { return false }
            return CMTimeSubtract(HouseClock.now(), f.pts).seconds > 0.9
        }
        let ordinal = montage.currentOrdinal
        montage.stop()
        let caps = timeline(collector.snapshot())
        guard caps.count > 15 else { throw SelfTestError.mismatch("single-item: only \(caps.count) frames") }
        for c in [caps.first!, caps.last!] { try assertShape(c.frame, w: cw, h: ch, what: "single-item") }
        guard classify(meanColor(caps.last!.frame)) == .green else {
            throw SelfTestError.mismatch("single-item: not green (\(fmt(meanColor(caps.last!.frame))))")
        }
        guard ordinal >= 1 else { throw SelfTestError.mismatch("single-item: montage never advanced (ordinal \(ordinal))") }
        print("  ✓ MontageSource[T6 single-item]: loops one item, kept emitting (ordinal \(ordinal))")
    }

    /// A LATER item that fails to decode (a bogus .mov) must not crash — the
    /// montage draws it as background briefly then keeps running and reaches the
    /// following good item.
    private static func testLaterItemDecodeFailureKeepsRunning() throws {
        let cw = 220, ch = 140
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_montage_bad_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let blueURL = dir.appendingPathComponent("a_blue.png")
        let greenURL = dir.appendingPathComponent("c_green.png")
        let badURL = dir.appendingPathComponent("b_bad.mov")
        try writeGradientPNG(to: blueURL, w: 300, h: 200, base: (0, 0, 1))
        try writeGradientPNG(to: greenURL, w: 300, h: 200, base: (0, 1, 0))
        try Data("not a real movie".utf8).write(to: badURL)   // exists but undecodable

        let interval = 0.3
        let montage = try MontageSource(id: SourceID("selftest.montage.bad"),
                                        items: [
                                            MontageSource.MontageItem(url: blueURL, kind: .image),
                                            MontageSource.MontageItem(url: badURL, kind: .video),
                                            MontageSource.MontageItem(url: greenURL, kind: .image),
                                        ],
                                        canvasSize: CanvasSize(width: cw, height: ch),
                                        interval: interval, transition: .cut,
                                        kenBurns: false, shuffle: false, loop: true, fps: 30)
        let collector = FrameCollector()
        montage.onFrame = { collector.add($0) }
        try montage.start()   // first item (blue image) is fine — start() must not throw
        // Run long enough to pass the bad item (hold cap ~0.5s) and reach green.
        _ = waitUntil(timeout: 6.0) {
            guard let f = collector.snapshot().first else { return false }
            return CMTimeSubtract(HouseClock.now(), f.pts).seconds > 2.0
        }
        let running = montage.state == .running
        montage.stop()

        let caps = timeline(collector.snapshot())
        guard caps.count > 20 else { throw SelfTestError.mismatch("bad-item: only \(caps.count) frames") }
        guard running else { throw SelfTestError.mismatch("bad-item: montage stopped running (crashed/wedged?)") }
        // It reached the good GREEN item after the bad one at least once.
        let sawGreen = caps.contains { classify(meanColor($0.frame)) == .green }
        guard sawGreen else { throw SelfTestError.mismatch("bad-item: never reached the good green item after the bad clip") }
        print("  ✓ MontageSource[T6 bad-later-item]: undecodable clip drawn as background, montage kept running and reached green")
    }

    /// `stop()` called from inside the `onFrame` callback must not deadlock/crash.
    private static func testStopFromCallback() throws {
        let cw = 160, ch = 90
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_montage_stopcb_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let u0 = dir.appendingPathComponent("0.png"), u1 = dir.appendingPathComponent("1.png")
        try writeGradientPNG(to: u0, w: 200, h: 120, base: (1, 0, 0))
        try writeGradientPNG(to: u1, w: 200, h: 120, base: (0, 0, 1))

        let montage = try MontageSource(id: SourceID("selftest.montage.stopcb"),
                                        items: [MontageSource.MontageItem(url: u0, kind: .image),
                                                MontageSource.MontageItem(url: u1, kind: .image)],
                                        canvasSize: CanvasSize(width: cw, height: ch),
                                        interval: 0.2, transition: .cut,
                                        kenBurns: false, shuffle: false, loop: true, fps: 30)
        let count = OSAllocatedUnfairLock(initialState: 0)
        montage.onFrame = { [weak montage] _ in
            let n = count.withLock { v -> Int in v += 1; return v }
            if n == 5 { montage?.stop() }   // nested stop from the director queue
        }
        try montage.start()
        _ = waitUntil(timeout: 3.0) { montage.state == .idle && count.withLock { $0 } >= 5 }
        // A moment for anything in flight to settle, then assert it really stopped.
        usleep(100_000)
        guard montage.state == .idle else {
            throw SelfTestError.mismatch("stop-from-callback: state \(montage.state) (expected idle)")
        }
        let n = count.withLock { $0 }
        guard n >= 5 else { throw SelfTestError.mismatch("stop-from-callback: only \(n) frames before stop") }
        print("  ✓ MontageSource[T6 stop-in-callback]: nested stop from onFrame is deadlock-free (stopped at \(n) frames)")
    }

    // MARK: - A1: per-item audio while current + all-image silence

    /// A montage whose middle item is a real clip WITH audio must emit
    /// `AudioPacket`s (house-time PTS, increasing) WHILE that clip is current, and
    /// `hasAudioContent` must be true. A montage of only images must emit ZERO
    /// audio and report `hasAudioContent == false`. (Guarded on the real asset.)
    private static func testAudioFromVideoItemAndImageSilence() throws {
        guard FileManager.default.fileExists(atPath: realAudioAssetPath) else {
            print("  – MontageSource[audio A1]: SKIPPED — \(realAudioAssetPath) not present")
            return
        }
        let cw = 320, ch = 180
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_montage_aud1_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let redURL = dir.appendingPathComponent("a_red.png")
        let blueURL = dir.appendingPathComponent("c_blue.png")
        try writeGradientPNG(to: redURL, w: 400, h: 300, base: (1, 0, 0))
        try writeGradientPNG(to: blueURL, w: 400, h: 300, base: (0, 0, 1))
        let clipURL = URL(fileURLWithPath: realAudioAssetPath)

        let interval = 0.8
        let montage = try MontageSource(id: SourceID("selftest.montage.aud1"),
                                        items: [
                                            MontageSource.MontageItem(url: redURL, kind: .image),
                                            MontageSource.MontageItem(url: clipURL, kind: .video),
                                            MontageSource.MontageItem(url: blueURL, kind: .image),
                                        ],
                                        canvasSize: CanvasSize(width: cw, height: ch),
                                        interval: interval, transition: .cut,
                                        kenBurns: false, shuffle: false, loop: true, fps: 30)
        guard montage.hasAudioContent else {
            throw SelfTestError.mismatch("audio A1: hasAudioContent false for a montage with an audio clip")
        }
        let audio = AudioCollector()
        montage.onAudio = { audio.add($0) }
        let frames = FrameCollector()
        montage.onFrame = { frames.add($0) }
        try montage.start()
        // ~2.6 s → red(0), CLIP(1), blue(2), red(0 wrap): the clip is current once.
        _ = waitUntil(timeout: 6.0) {
            guard let f = frames.snapshot().first else { return false }
            return CMTimeSubtract(HouseClock.now(), f.pts).seconds > 2.6
        }
        montage.stop()

        let caps = audio.snapshot()
        guard caps.count > 0 else {
            throw SelfTestError.mismatch("audio A1: video item emitted ZERO audio packets (expected > 0)")
        }
        // House-time PTS must be finite and non-decreasing (retimed by MovieSource).
        var lastPTS = -Double.greatestFiniteMagnitude
        for c in caps {
            guard c.pts.isFinite else { throw SelfTestError.mismatch("audio A1: non-finite PTS") }
            guard c.pts >= lastPTS - 1e-6 else {
                throw SelfTestError.mismatch(String(format: "audio A1: PTS went backwards (%.4f after %.4f)", c.pts, lastPTS))
            }
            lastPTS = c.pts
        }
        let ptsSpan = caps.last!.pts - caps.first!.pts
        guard ptsSpan > 0 else {
            throw SelfTestError.mismatch("audio A1: PTS did not advance across packets (span \(ptsSpan))")
        }
        // All packets come from the single clip visit (one embedded source id).
        let ids = Set(caps.map { $0.source })
        guard ids.count == 1 else {
            throw SelfTestError.mismatch("audio A1: expected one emitter in this window, saw \(ids.count): \(ids)")
        }
        // Balanced embedded-MovieSource lifecycle (audio rides it): started==stopped.
        let starts = montage.movieStartCount.withLock { $0 }
        let stops = montage.movieStopCount.withLock { $0 }
        guard starts >= 1, starts == stops else {
            throw SelfTestError.mismatch("audio A1: MovieSource lifecycle unbalanced (started \(starts), stopped \(stops))")
        }

        // --- All-image control: ZERO audio, hasAudioContent false. ---
        let stillM = try MontageSource(id: SourceID("selftest.montage.aud1.silent"),
                                       items: [
                                           MontageSource.MontageItem(url: redURL, kind: .image),
                                           MontageSource.MontageItem(url: blueURL, kind: .image),
                                       ],
                                       canvasSize: CanvasSize(width: cw, height: ch),
                                       interval: 0.4, transition: .cut,
                                       kenBurns: false, shuffle: false, loop: true, fps: 30)
        guard !stillM.hasAudioContent else {
            throw SelfTestError.mismatch("audio A1: all-image montage reports hasAudioContent true")
        }
        let silentAudio = AudioCollector()
        stillM.onAudio = { silentAudio.add($0) }
        let silentFrames = FrameCollector()
        stillM.onFrame = { silentFrames.add($0) }
        try stillM.start()
        _ = waitUntil(timeout: 3.0) {
            guard let f = silentFrames.snapshot().first else { return false }
            return CMTimeSubtract(HouseClock.now(), f.pts).seconds > 1.2
        }
        stillM.stop()
        guard silentAudio.count == 0 else {
            throw SelfTestError.mismatch("audio A1: all-image montage emitted \(silentAudio.count) audio packets (expected 0)")
        }

        print(String(format: "  ✓ MontageSource[audio A1]: video item emitted %d packets (PTS span %.2fs, increasing, 1 emitter), all-image montage silent (0 packets), hasAudioContent true/false correct, lifecycle balanced (%d/%d)",
                     caps.count, ptsSpan, starts, stops))
    }

    // MARK: - A2: exactly one emitter — audio stops on advance, next clip starts

    /// A montage of two audio clips (`.cut`): as it advances, the outgoing clip's
    /// audio must STOP before the incoming clip's audio starts — never two
    /// soundtracks at once. Proof: group packets by their (per-visit-unique)
    /// emitter id; the arrival-time intervals of distinct emitters must NOT
    /// overlap, and there must be ≥2 distinct emitters (old stopped → new started).
    /// Also: no packets after `stop()`. (Guarded on the real asset.)
    private static func testAudioStopsOnAdvanceAndSwitches() throws {
        guard FileManager.default.fileExists(atPath: realAudioAssetPath) else {
            print("  – MontageSource[audio A2]: SKIPPED — \(realAudioAssetPath) not present")
            return
        }
        let cw = 320, ch = 180
        let clipURL = URL(fileURLWithPath: realAudioAssetPath)
        let interval = 0.7
        let montage = try MontageSource(id: SourceID("selftest.montage.aud2"),
                                        items: [
                                            MontageSource.MontageItem(url: clipURL, kind: .video),
                                            MontageSource.MontageItem(url: clipURL, kind: .video),
                                        ],
                                        canvasSize: CanvasSize(width: cw, height: ch),
                                        interval: interval, transition: .cut,
                                        kenBurns: false, shuffle: false, loop: true, fps: 30)
        guard montage.hasAudioContent else {
            throw SelfTestError.mismatch("audio A2: hasAudioContent false for an all-video-with-audio montage")
        }
        let audio = AudioCollector()
        montage.onAudio = { audio.add($0) }
        let frames = FrameCollector()
        montage.onFrame = { frames.add($0) }
        try montage.start()
        // ~2.4 s → visit0(0-0.7), visit1(0.7-1.4), visit0'(1.4-2.1), … ≥3 visits,
        // i.e. ≥2 advances between distinct emitters.
        _ = waitUntil(timeout: 6.0) {
            guard let f = frames.snapshot().first else { return false }
            return CMTimeSubtract(HouseClock.now(), f.pts).seconds > 2.4
        }
        let countBeforeStop = audio.count
        montage.stop()
        // Give any (incorrectly) in-flight emitter a chance to leak a packet.
        usleep(250_000)
        let countAfterStop = audio.count
        guard countAfterStop == countBeforeStop else {
            throw SelfTestError.mismatch("audio A2: \(countAfterStop - countBeforeStop) audio packets fired AFTER stop()")
        }

        let caps = audio.snapshot()
        guard caps.count > 0 else { throw SelfTestError.mismatch("audio A2: no audio at all") }

        // Group arrival-time ranges per emitter id.
        var ranges: [String: (min: Double, max: Double)] = [:]
        for c in caps {
            if let r = ranges[c.source] {
                ranges[c.source] = (min(r.min, c.arrival), max(r.max, c.arrival))
            } else {
                ranges[c.source] = (c.arrival, c.arrival)
            }
        }
        guard ranges.count >= 2 else {
            throw SelfTestError.mismatch("audio A2: only \(ranges.count) emitter(s) — the montage never switched clips' audio")
        }
        // No two emitters' active windows overlap (exactly one emitter at a time).
        // A 20 ms slack absorbs arrival-timestamp jitter at the boundary.
        let sorted = ranges.values.sorted { $0.min < $1.min }
        let slack = 0.020
        for i in 1..<sorted.count {
            let prev = sorted[i - 1], cur = sorted[i]
            guard cur.min >= prev.max - slack else {
                throw SelfTestError.mismatch(String(format: "audio A2: emitter windows OVERLAP — [%.3f,%.3f] and [%.3f,%.3f] (two soundtracks at once)",
                                                    prev.min, prev.max, cur.min, cur.max))
            }
        }
        // Balanced embedded lifecycle across the run (allow the still-current slot
        // at stop(): teardown balances it, so |starts - stops| ≤ 1 here).
        let starts = montage.movieStartCount.withLock { $0 }
        let stops = montage.movieStopCount.withLock { $0 }
        guard starts >= 2, abs(starts - stops) <= 1 else {
            throw SelfTestError.mismatch("audio A2: MovieSource lifecycle off (started \(starts), stopped \(stops))")
        }

        print(String(format: "  ✓ MontageSource[audio A2]: %d packets across %d distinct emitters, NO overlap (single emitter per instant), 0 packets after stop(), lifecycle %d/%d",
                     caps.count, ranges.count, starts, stops))
    }

    // MARK: - 3. Shuffle determinism (pure)

    private static func testShuffleDeterminism() throws {
        let n = 12
        let a = MontageSource.makeOrder(count: n, shuffle: true, seed: 42)
        let b = MontageSource.makeOrder(count: n, shuffle: true, seed: 42)
        let c = MontageSource.makeOrder(count: n, shuffle: true, seed: 43)
        let ident = MontageSource.makeOrder(count: n, shuffle: false, seed: 42)
        guard a == b else { throw SelfTestError.mismatch("shuffle: same seed gave different orders \(a) vs \(b)") }
        guard a != c else { throw SelfTestError.mismatch("shuffle: different seeds gave identical order \(a)") }
        guard a.sorted() == Array(0..<n) else { throw SelfTestError.mismatch("shuffle: order is not a permutation \(a)") }
        guard ident == Array(0..<n) else { throw SelfTestError.mismatch("shuffle=false must be identity, got \(ident)") }
        guard a != ident else { throw SelfTestError.mismatch("shuffle: seed 42 order equals identity (no shuffle happened)") }
        print("  ✓ MontageSource[shuffle]: deterministic per seed (42⇒\(a)), differs across seeds, identity when off")
    }

    // MARK: - PNG dump

    private static func dumpPNGSequence(_ caps: [Captured], interval: Double, cfDur: Double) throws -> Int {
        let outDir = URL(fileURLWithPath: pngDumpDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        // Clear any stale frames from a prior run.
        if let old = try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil) {
            for f in old where f.pathExtension == "png" { try? FileManager.default.removeItem(at: f) }
        }
        // Spread across [0 … 2.0 s]: covers item0→1 and item1→2 switches, each with
        // its crossfade window sampled.
        var targets: [Double] = []
        var t = 0.05
        while t <= 2.0 { targets.append(t); t += 0.10 }
        var written = 0
        for (i, tt) in targets.enumerated() {
            guard let cap = nearest(caps, to: tt), abs(cap.t - tt) < 0.06 else { continue }
            let hue = classify(meanColor(cap.frame)).map { $0.rawValue } ?? "blend"
            let name = String(format: "frame_%02d_t%.2f_%@.png", i, cap.t, hue)
            try writeBGRAtoPNG(cap.frame, to: outDir.appendingPathComponent(name))
            written += 1
        }
        print("    montage PNG sequence → \(outDir.path) (\(written) frames)")
        return written
    }

    private static func writeBGRAtoPNG(_ frame: VideoFrame, to url: URL) throws {
        let buffer = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw SelfTestError.setupFailed("PNG base address")
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base, width: frame.width, height: frame.height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: cs, bitmapInfo: info),
              let image = ctx.makeImage() else {
            throw SelfTestError.setupFailed("PNG context/makeImage")
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SelfTestError.setupFailed("PNG destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw SelfTestError.setupFailed("PNG finalize") }
    }

    // MARK: - Test asset writers

    /// A diagonal gradient tinted by `base` (dark corner → bright corner). The
    /// structure gives Ken Burns something to move; the tint gives the item a
    /// dominant hue for identity checks.
    private static func writeGradientPNG(to url: URL, w: Int, h: Int, base: (Double, Double, Double)) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SelfTestError.setupFailed("gradient context")
        }
        let colors = [
            CGColor(srgbRed: base.0 * 0.18, green: base.1 * 0.18, blue: base.2 * 0.18, alpha: 1),
            CGColor(srgbRed: base.0, green: base.1, blue: base.2, alpha: 1),
        ] as CFArray
        guard let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) else {
            throw SelfTestError.setupFailed("gradient")
        }
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0),
                               end: CGPoint(x: w, y: h), options: [])
        // A bright diagonal band so KB pan is unmistakable in the pixels.
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9))
        ctx.setLineWidth(CGFloat(h) * 0.06)
        ctx.move(to: CGPoint(x: 0, y: Double(h) * 0.35))
        ctx.addLine(to: CGPoint(x: Double(w), y: Double(h) * 0.8))
        ctx.strokePath()
        guard let image = ctx.makeImage() else { throw SelfTestError.setupFailed("gradient makeImage") }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SelfTestError.setupFailed("gradient PNG destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw SelfTestError.setupFailed("gradient PNG finalize") }
    }

    /// A ~1 s moving clip (sweeping hue + a moving white bar) — real motion for
    /// the embedded-MovieSource decode proof. Mirrors MovieSourceSelfTest's writer.
    private static func writeMovingClip(to url: URL, frames: Int, size: CGSize, fps: Double) throws {
        try? FileManager.default.removeItem(at: url)
        let w = Int(size.width), h = Int(size.height)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mov) }
        catch { throw SelfTestError.setupFailed("AVAssetWriter: \(error)") }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
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
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let scale = CMTimeScale(600)
        for i in 0..<frames {
            let buffer = try pool.makeBuffer()
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer),
               let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                   space: cs, bitmapInfo: bitmapInfo) {
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
