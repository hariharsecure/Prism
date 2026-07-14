import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import Metal
import os
import UniformTypeIdentifiers
import XCTest

import PrismCompositor
import PrismCore
import PrismSources
@testable import Prism

/// Final cluster of MEDIUM sol-verify findings on the App meme / layer path
/// (PRODUCTION_BIBLE classes A / D / F / J). Each test reproduces the defect the
/// synthetic suite missed: an arbitrary trigger phase (F14), a wall-clock lifetime
/// (F21), an aspect squeeze (F24), dropped live rotation (F20), and unbounded
/// aggregate media / warm GPU floors (F15).
@MainActor
final class MemeLayerPathTests: XCTestCase {

    // MARK: F14 — animated memes CUE to frame zero on trigger (Class D)

    /// A GIF meme cued from two DIFFERENT free-run phases both open on frame ZERO
    /// (byte-identical), and that frame is independently the source's first frame.
    /// Pre-fix, `triggerMeme` never restarted the media, so the first composited
    /// frame was whatever loop phase happened to sit in the mailbox — different on
    /// every trigger.
    func testAnimatedMemeCuesToFrameZeroDeterministically() throws {
        let url = try makeAnimatedGIF(colors: [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0)],
                                      delay: 0.30, side: 32)
        let canvas = CanvasSize(width: 32, height: 32)

        // Independent oracle: a fresh source's first delivered frame = frame 0.
        let oracleHash = try firstFrameHash(gifURL: url, canvas: canvas)

        let source = try AnimatedGIFSource(fileURL: url, canvasSize: canvas,
                                           contentMode: .aspectFill, loop: true)
        let mailbox = FrameMailbox()
        source.onFrame = { [mailbox] in mailbox.post($0) }
        try source.start()

        // Advance well past frame 0 (deterministic: 0.30 s/frame ≫ test ops).
        let freeRunHash = try advanceAndHash(mailbox, untilDelivered: 3)
        XCTAssertNotEqual(freeRunHash, oracleHash,
                          "free-run source never left frame 0 — cannot demonstrate the phase defect")

        // Cue #1 (from this arbitrary phase) → frame 0.
        XCTAssertTrue(AppEngine.cueAnimatedSourceToFrameZero(source, mailbox: mailbox))
        let cuedA = try XCTUnwrap(mailbox.takeNewest())
        XCTAssertEqual(pixelHash(cuedA), oracleHash, "first cued frame was not frame 0")

        // Free-run to a DIFFERENT phase, then cue #2 → frame 0 again. (The cue now
        // pauses the source at frame 0 — sol #7 — so restart it to advance the phase.)
        try source.start()
        _ = try advanceAndHash(mailbox, untilDelivered: mailbox.stats.delivered + 2)
        XCTAssertTrue(AppEngine.cueAnimatedSourceToFrameZero(source, mailbox: mailbox))
        let cuedB = try XCTUnwrap(mailbox.takeNewest())
        XCTAssertEqual(pixelHash(cuedB), oracleHash, "second cued frame was not frame 0")

        XCTAssertEqual(pixelHash(cuedA), pixelHash(cuedB),
                       "two triggers from different phases opened on different frames (F14)")
        source.stop()
    }

    /// sol #7 (F14 residual): the FIRST PRESENTED meme frame must be frame ZERO.
    /// Even though the cue pauses the source at frame 0, the live render loop drains
    /// the source's mailbox into the compositor's FrameStore WHILE the cue runs, so a
    /// post-zero frame could be presented the moment the provider goes live. Independent
    /// LIVE oracle: capture the meme's composited frame from the per-tick snapshot
    /// (`TickSnapshot.frames`) on the FIRST tick the meme is in the evaluated program,
    /// and check its colour — frame 0 is the ONLY RED frame (an 8-colour loop, so no
    /// wrap-around aliases frame 0). Not a delivered-counter; drives the live composite.
    /// Negative control: skip the gate → the first presented frame is a non-red (post-zero) frame.
    func testTriggeredMemeFirstPresentedFrameIsFrameZero() async throws {
        // 8 distinct colours; only frame 0 is red-dominant, so a post-zero frame (up to
        // several frames in) can never be mistaken for frame 0 via loop wrap.
        let colors: [(CGFloat, CGFloat, CGFloat)] = [
            (1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0),
            (0, 1, 1), (1, 0, 1), (0.5, 0.5, 0.5), (0.2, 0.7, 0.3)
        ]
        func firstPresentedIsRed(gateOn: Bool) async throws -> Bool {
            let url = try makeAnimatedGIF(colors: colors, delay: 0.04, side: 64)
            let engine = AppEngine()
            guard let loop = engine.renderLoop else { await engine.shutdown(); throw XCTSkip("no render loop") }
            engine.addMeme(url: url, mode: .cutTo, placement: .fullscreen, holdSec: 2.0, isBuiltIn: true)
            let item = try XCTUnwrap(engine.memeItems.first { $0.mediaURL == url })
            let memeID = item.sourceID

            AppEngine._test_skipFrameZeroGate = !gateOn
            defer { AppEngine._test_skipFrameZeroGate = false }

            let captured = OSAllocatedUnfairLock<VideoFrame?>(initialState: nil)
            loop.onTickSnapshot = { tick in
                guard tick.evaluatedScene?.layers.contains(where: { $0.sourceID == memeID }) == true,
                      let f = tick.frames[memeID] else { return }
                captured.withLock { if $0 == nil { $0 = f } }
            }
            engine.triggerMeme(id: item.id)
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while captured.withLock({ $0 == nil }), ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let frame = try XCTUnwrap(captured.withLock { $0 }, "meme never appeared in a composited tick")
            let red = redDominant(frame)
            await engine.shutdown()
            return red
        }

        // NEGATIVE CONTROL: gate off → the first presented meme frame is a non-red post-zero frame.
        let control = try await firstPresentedIsRed(gateOn: false)
        XCTAssertFalse(control, "negative control vacuous: the first presented frame was frame 0 (red) even without the gate")
        // FIX: gate on → the first presented meme frame is the red frame 0.
        let fixed = try await firstPresentedIsRed(gateOn: true)
        XCTAssertTrue(fixed, "sol #7: the first presented meme frame was not frame 0 (red)")
    }

    /// Center-pixel red-dominance of a composited BGRA meme frame (frame 0's colour).
    private func redDominant(_ frame: VideoFrame) -> Bool {
        let pb = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return false }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        let o = (h / 2) * bpr + (w / 2) * 4    // BGRA center pixel
        let b = Int(p[o]), g = Int(p[o + 1]), r = Int(p[o + 2])
        return r > 150 && g < 90 && b < 90
    }

    /// A still image meme is NOT restarted by the cue (a restart would only re-post
    /// the same frame); the helper reports no animated cue happened.
    func testStillMemeIsNotCued() throws {
        let stillURL = try makeStillPNG(side: 16)
        let source = try ImageSource(fileURL: stillURL, canvasSize: CanvasSize(width: 16, height: 16),
                                     contentMode: .aspectFit, background: .clear)
        let mailbox = FrameMailbox()
        source.onFrame = { [mailbox] in mailbox.post($0) }
        try source.start()
        XCTAssertFalse(AppEngine.cueAnimatedSourceToFrameZero(source, mailbox: mailbox),
                       "a still meme should not be cued as animated media")
        source.stop()
    }

    // MARK: F21 — meme lifetime uses HOUSE time, not wall-clock Date (Class D)

    /// The teardown deadline is derived purely from HOUSE time and the expiry
    /// decision is house-time-only, so a wall-clock `Date` step cannot strand or
    /// early-expire a meme. Pre-fix the deadline was a `Date` compared with
    /// `Date()`, which an NTP backstep could push minutes/hours out.
    func testMemeLifetimeIsHouseTimeNotWallClock() {
        let deadline = AppEngine.memeProviderDeadlineHouse(triggerHouse: 100, holdSec: 1.5)
        XCTAssertEqual(deadline, 100 + 1.5 + 0.25, accuracy: 1e-9)

        // Before the house deadline → still holding.
        XCTAssertFalse(AppEngine.memeProviderExpired(nowHouse: 101.0, deadlineHouse: deadline))
        // Exactly at / past the house deadline → expired.
        XCTAssertTrue(AppEngine.memeProviderExpired(nowHouse: deadline, deadlineHouse: deadline))

        // Immunity to a backward wall clock: the decision takes ONLY house seconds,
        // so with house time well past the deadline the meme expires regardless of
        // any Date step. (Pre-fix `Date() < deadlineDate` would report NOT expired.)
        XCTAssertTrue(AppEngine.memeProviderExpired(nowHouse: 1_000.0, deadlineHouse: deadline),
                      "meme did not expire on house time (F21 wall-clock dependency)")
    }

    /// The live engine stores the meme teardown deadline in HOUSE seconds (near
    /// `now + hold + margin`), not a wall-clock epoch (~1.7e9 s since 1970).
    func testTriggerMemeStoresHouseDeadline() async {
        let engine = AppEngine()
        engine.prepareMemes()
        guard let insert = engine.memeItems.first(where: { $0.mode == .insert }) else {
            await engine.shutdown(); return XCTFail("no insert meme template")
        }
        let now = HouseClock.nowSeconds()
        engine.triggerMeme(id: insert.id)
        let deadline = engine.integrationDebugMemeProviderDeadlineHouse
        XCTAssertNotNil(deadline)
        // Within a couple seconds of the house clock, NOT a 1970-epoch Date value.
        XCTAssertEqual(deadline ?? .infinity, now + max(0.3, insert.holdSec) + 0.25, accuracy: 1.0)
        XCTAssertLessThan(deadline ?? .infinity, 1_000_000_000,
                          "deadline looks like a wall-clock Date epoch, not house time (F21)")
        await engine.shutdown()
    }

    // MARK: F24 — meme placement PRESERVES aspect, not squeezes (Class A)

    /// A 16:9 source fit into a 1:1 (square-in-pixels) target keeps its 16:9 aspect
    /// (letterboxed), never squeezed to fill the square. Pre-fix the 16:9 source
    /// texture was stretched to the placement rect.
    func testAspectFitPreserves16x9IntoSquareTarget() {
        let sixteenNine = 16.0 / 9.0
        // Square canvas + full-canvas placement = a 1:1 pixel target.
        let fit = MemeDirector.aspectFitFrame(CGRect(x: 0, y: 0, width: 1, height: 1),
                                              canvasAspect: 1.0, sourceAspect: sixteenNine)
        let pixelAspect = Double(fit.width) * 1.0 / (Double(fit.height) * 1.0)
        XCTAssertEqual(pixelAspect, sixteenNine, accuracy: 1e-6,
                       "16:9 source was squeezed into the 1:1 target (F24)")
        XCTAssertLessThan(fit.height, fit.width, "expected letterbox bars, not a squeeze")
        // Centered within the target.
        XCTAssertEqual(fit.midX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(fit.midY, 0.5, accuracy: 1e-9)
    }

    /// Through the live director AND a REAL composite: a lower-third insert (a very
    /// wide slot) no longer stretches the 16:9 meme texture. Composite the program
    /// through `MetalCompositor` and measure the meme colour's on-screen bounding
    /// box — its pixel aspect must be 16:9, not the slot's ~7.3:1. Pre-fix the raw
    /// 0.90×0.22 slot was used verbatim, squeezing the source. (Was a geometry-only
    /// self-check that never inspected pixels — rewritten to a real-pixel oracle.)
    func testDirectorAspectCorrectsWideLowerThirdRealPixels() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let W = 640, H = 360
        let compositor = try MetalCompositor(device: device, width: W, height: H)
        let director = MemeDirector()
        director.canvasAspect = 16.0 / 9.0
        let baseID = SourceID("base"), memeID = SourceID("meme.lt")
        let base = Scene(name: "base", layers: [Layer(sourceID: baseID, zIndex: 0)])
        let item = MemeItem(name: "lt", mediaURL: URL(fileURLWithPath: "/dev/null"),
                            sourceID: memeID, mode: .insert, holdSec: 5, placement: .lowerThird)
        director.trigger(item, at: 0)
        let scene = director.program(at: 0.1, base: base)

        let baseCanvas = try FXCanvas(width: W, height: H)
        let memeCanvas = try FXCanvas(width: 160, height: 90)          // 16:9 green fill
        let out = try compositor.composite(frames: [
            baseID: VideoFrame(pixelBuffer: try baseCanvas.solid(RGBA(r: 0.1, g: 0.1, b: 0.9)),
                               pts: HouseClock.now(), source: baseID),
            memeID: VideoFrame(pixelBuffer: try memeCanvas.solid(RGBA(r: 0.0, g: 0.95, b: 0.0)),
                               pts: HouseClock.now(), source: memeID),
        ], scene: scene, pts: HouseClock.now())

        let box = try XCTUnwrap(greenBoundingBox(out.pixelBuffer), "meme not composited")
        let aspect = Double(box.w) / Double(box.h)
        XCTAssertEqual(aspect, 16.0 / 9.0, accuracy: 0.20,
                       "lower-third meme composited at aspect \(aspect) — the 16:9 source was squeezed into the wide slot (F24)")
    }

    /// Bounding box (px) of the strongly-green region of a BGRA buffer.
    private func greenBoundingBox(_ pb: CVPixelBuffer) -> (w: Int, h: Int)? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let o = y * bpr + x * 4
                if Int(p[o + 1]) > 140 && Int(p[o + 2]) < 110 && Int(p[o]) < 110 {
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return (w: maxX - minX + 1, h: maxY - minY + 1)
    }

    // MARK: F20 — live LayerMotion rotation is APPLIED (Class J)

    /// A `.float` motion carries a nonzero, time-varying rotation onto the live
    /// layer. Pre-fix `applyLayerMotions` dropped rotation (Layer had no field),
    /// so it was silently 0 for every tick.
    func testLayerMotionRotationReachesLiveLayer() {
        let motion = LayerMotion(path: .float(amplitude: 0.06))
        let active = ActiveLayerMotion(kind: .float, motion: motion, speed: 1, startHouse: 0)
        let id = SourceID("rot")
        let scene = ProgramScene(name: "s", layers: [Layer(sourceID: id)])

        let atQuarter = AppEngine.applyLayerMotions([id: active], to: scene, atHouseSeconds: 0.25)
        let atThreeQuarter = AppEngine.applyLayerMotions([id: active], to: scene, atHouseSeconds: 0.75)
        let r1 = atQuarter.layers[0].rotation
        let r2 = atThreeQuarter.layers[0].rotation

        XCTAssertNotEqual(r1, 0, "rotation was dropped from the live layer (F20)")
        XCTAssertNotEqual(r1, r2, "layer rotation did not change across house time (F20)")
    }

    // MARK: F15 — aggregate media budget + idle GPU release (Class F)

    /// N animated memes each near the per-instance budget stay under a FIXED
    /// aggregate ceiling — evicting the oldest — never reaching N × per-instance.
    func testAnimatedMemeAggregateBudgetEvictsToCeiling() {
        let ceiling = 1024 * 1024 * 1024                    // 1 GiB
        let each = 400 * 1024 * 1024                        // 400 MiB per meme
        var current: [(id: SourceID, cost: Int)] = []
        for i in 0..<6 {
            let plan = AppEngine.planAnimatedMemeAdmission(newCost: each, current: current, ceiling: ceiling)
            XCTAssertTrue(plan.admitNew)
            current.removeAll { id in plan.evict.contains(id.id) }
            current.append((id: SourceID("meme.\(i)"), cost: each))
            let total = current.reduce(0) { $0 + $1.cost }
            XCTAssertLessThanOrEqual(total, ceiling,
                                     "aggregate animated-meme bytes exceeded the ceiling after meme \(i) (F15)")
        }
        // 2×400 MiB fits (800 < 1024); a 3rd would overflow → at most 2 resident.
        XCTAssertLessThanOrEqual(current.count, 2)
    }

    /// A single meme larger than the whole ceiling is rejected, not admitted.
    func testOversizedAnimatedMemeIsRejected() {
        let ceiling = 512 * 1024 * 1024
        let plan = AppEngine.planAnimatedMemeAdmission(newCost: ceiling + 1, current: [], ceiling: ceiling)
        XCTAssertFalse(plan.admitNew, "a meme larger than the aggregate budget must be rejected (F15)")
    }

    /// A source whose time-varying effects are all disabled RELEASES its render-
    /// thread animated `SourceEffectGPU` warm floor. Pre-fix the ~6-buffer floor
    /// stayed resident forever once the source had ever animated.
    func testAnimatedGPUReleasedWhenNoTimeVaryingFX() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let side = 64
        let pipeline = SourceEffectPipeline(device: device, sourceID: SourceID("fx.release"),
                                            canvasWidth: side, canvasHeight: side)
        pipeline.update(SourceEffects(tile: TileEffect(mode: .flicker, speed: 4)))
        let raw = try makeBGRAFrame(side: side, source: SourceID("fx.release"))
        _ = pipeline.animate(raw: raw, at: CMTime(seconds: 0.1, preferredTimescale: 1_000_000_000))
        XCTAssertTrue(pipeline.debugHasAnimatedGPU, "animated GPU was never allocated")

        pipeline.update(SourceEffects())                    // all FX off
        pipeline.releaseAnimatedGPUIfIdle()
        XCTAssertFalse(pipeline.debugHasAnimatedGPU,
                       "idle source kept its warm animated GPU floor (F15)")
    }

    // MARK: - Helpers

    private func firstFrameHash(gifURL: URL, canvas: CanvasSize) throws -> Int {
        let s = try AnimatedGIFSource(fileURL: gifURL, canvasSize: canvas,
                                      contentMode: .aspectFill, loop: true)
        let mb = FrameMailbox()
        s.onFrame = { [mb] in mb.post($0) }
        try s.start()
        let h = try advanceAndHash(mb, untilDelivered: 1)
        s.stop()
        return h
    }

    /// Spin until the mailbox has delivered at least `untilDelivered` frames, then
    /// hash the newest. Bounded wait so a stall fails rather than hangs.
    private func advanceAndHash(_ mailbox: FrameMailbox, untilDelivered: UInt64) throws -> Int {
        let deadline = ProcessInfo.processInfo.systemUptime + 3.0
        while mailbox.stats.delivered < untilDelivered,
              ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        return pixelHash(try XCTUnwrap(mailbox.takeNewest(), "no frame delivered within timeout"))
    }

    private func pixelHash(_ frame: VideoFrame) -> Int {
        let pb = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return 0 }
        let count = CVPixelBufferGetBytesPerRow(pb) * CVPixelBufferGetHeight(pb)
        var hasher = Hasher()
        hasher.combine(bytes: UnsafeRawBufferPointer(start: base, count: count))
        return hasher.finalize()
    }

    private func makeBGRAFrame(side: Int, source: SourceID) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: side, height: side, pixelFormat: kCVPixelFormatType_32BGRA)
        let pb = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<CVPixelBufferGetHeight(pb) {
                for x in 0..<bpr { ptr[y * bpr + x] = UInt8((x &+ y) & 0xFF) }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return VideoFrame(pixelBuffer: pb, pts: HouseClock.now(), source: source)
    }

    private func makeStillPNG(side: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("still.\(UUID().uuidString).png")
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("could not write PNG fixture") }
        return url
    }

    /// Write a multi-frame animated GIF with distinct solid-color frames.
    private func makeAnimatedGIF(colors: [(CGFloat, CGFloat, CGFloat)], delay: Double,
                                 side: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meme.\(UUID().uuidString).gif")
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, colors.count, nil) else {
            throw XCTSkip("could not create GIF destination")
        }
        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        for (r, g, b) in colors {
            let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let img = ctx.makeImage()!
            let frameProps: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                kCGImagePropertyGIFUnclampedDelayTime: delay]
            ]
            CGImageDestinationAddImage(dest, img, frameProps as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("could not finalize GIF fixture") }
        return url
    }
}
