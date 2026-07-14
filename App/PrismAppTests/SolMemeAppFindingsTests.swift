import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import Metal
import os
import UniformTypeIdentifiers
import XCTest

import PrismCompose
import PrismCompositor
import PrismCore
import PrismSources
@testable import Prism

/// Second sol-verify sweep on the App meme / layer path: the findings the FIRST
/// meme cluster left incomplete or regressed. Each test reproduces the defect on
/// real state / real composited pixels (never a tautology), per PRODUCTION_BIBLE
/// classes A / B / D / F.
@MainActor
final class SolMemeAppFindingsTests: XCTestCase {

    // MARK: F24 (vertical) — a 16:9 meme must NOT be horizontally crushed in 9:16

    /// Composite a lower-third 16:9 meme through the REAL vertical (9:16) program
    /// and measure the meme's composited extent: its pixel aspect must stay 16:9,
    /// not the crushed ~0.56:1 that reusing the 16:9-normalized rect on the 9:16
    /// canvas produces. Independent oracle: scan the actual output pixels for the
    /// meme colour and compute its bounding-box aspect — no geometry self-check.
    func testVerticalMemePreservesAspectRealPixels() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let secondary = try SecondaryComposition(device: device, width: 1080, height: 1920)

        let baseID = SourceID("cam"), memeID = SourceID("meme.lt")
        let resting = Scene(name: "base", layers: [Layer(sourceID: baseID, zIndex: 0)])

        // Build the evaluated program exactly as the app does: MemeDirector places
        // a lower-third insert, aspect-corrected for the 16:9 canvas.
        let director = MemeDirector()
        director.canvasAspect = 16.0 / 9.0
        let item = MemeItem(name: "lt", mediaURL: URL(fileURLWithPath: "/dev/null"),
                            sourceID: memeID, mode: .insert, holdSec: 5, placement: .lowerThird)
        director.trigger(item, at: 0)
        let evaluated = director.program(at: 0.1, base: resting)
        let memeFrame = try XCTUnwrap(evaluated.layers.first { $0.sourceID == memeID }?.frame)

        let reframe = AppEngine.verticalReframeMap(
            evaluatedScene: evaluated, restingScene: resting,
            mode: .heroFill, pinnedHero: nil,
            auxiliaryFrames: [memeID: memeFrame])

        // Source frames: opaque blue camera (fills the source canvas 16:9) + a
        // solid-GREEN meme filling its 16:9 source texture. The green layer's whole
        // texture maps to the placement rect, so the green region in the OUTPUT is
        // exactly that rect — its aspect is what we measure.
        let baseCanvas = try FXCanvas(width: 320, height: 180)
        let memeCanvas = try FXCanvas(width: 160, height: 90)
        let frames: [SourceID: VideoFrame] = [
            baseID: VideoFrame(pixelBuffer: try baseCanvas.solid(RGBA(r: 0.1, g: 0.1, b: 0.9)),
                               pts: HouseClock.now(), source: baseID),
            memeID: VideoFrame(pixelBuffer: try memeCanvas.solid(RGBA(r: 0.0, g: 0.95, b: 0.0)),
                               pts: HouseClock.now(), source: memeID),
        ]
        let out = try secondary.composite(frames: frames, scene: evaluated, reframe: reframe,
                                          pts: HouseClock.now())

        let box = greenBoundingBox(out.pixelBuffer)
        let bw = try XCTUnwrap(box).w, bh = try XCTUnwrap(box).h
        XCTAssertGreaterThan(bw, 0); XCTAssertGreaterThan(bh, 0)
        let aspect = Double(bw) / Double(bh)
        // 16:9 ≈ 1.778. Pre-fix (16:9 rect reused verbatim on 9:16) ≈ 0.5625 (crush).
        XCTAssertEqual(aspect, 16.0 / 9.0, accuracy: 0.20,
                       "vertical meme composited at aspect \(aspect) — a 16:9 meme was crushed in 9:16 (F24)")
        XCTAssertGreaterThan(aspect, 1.0,
                             "vertical meme is TALLER than wide — horizontally crushed (F24 vertical)")
    }

    // MARK: F14 — animated memes stay paused until triggered, stop at hold end

    func testAnimatedMemeNoFreeRunAndStopsAtHoldEnd() async throws {
        let gifURL = try makeAnimatedGIF(colors: [(1,0,0),(0,1,0),(0,0,1),(1,1,0)], delay: 0.25, side: 24)
        let engine = AppEngine()
        engine.addMeme(url: gifURL, mode: .insert, placement: .lowerThird, holdSec: 0.4, isBuiltIn: true)
        let item = try XCTUnwrap(engine.memeItems.first { $0.mediaURL == gifURL })

        // (1) Registered but NOT free-running (pre-fix `addMeme` started it).
        XCTAssertFalse(engine.integrationDebugAuxiliaryIsRunning(item.sourceID),
                       "animated meme free-ran at registration (F14)")

        // (2) Trigger → the async frame-zero cue starts the media, then (once frame
        // zero has landed) installs the provider. Poll on the provider (bounded).
        engine.triggerMeme(id: item.id)
        try await pollUntil(2.0) { engine.integrationDebugMemeProviderInstalled }
        // sol #4: the restart is GATED on the render loop presenting frame 0 (deferred off
        // the main actor after install), so poll until the cued media is running.
        try await pollUntil(2.0) { engine.integrationDebugAuxiliaryIsRunning(item.sourceID) }
        XCTAssertTrue(engine.integrationDebugAuxiliaryIsRunning(item.sourceID),
                      "provider installed but the cued media never started (F14)")

        // (3) Hold end → media STOPPED/reset (not left free-running).
        engine.integrationDebugExpireMemeProviderNow()
        XCTAssertFalse(engine.integrationDebugAuxiliaryIsRunning(item.sourceID),
                       "animated meme kept free-running after hold end (F14)")
        XCTAssertFalse(engine.integrationDebugMemeProviderInstalled)

        // (4) Re-trigger → the media is cued back up again (deterministic re-open).
        engine.triggerMeme(id: item.id)
        try await pollUntil(2.0) { engine.integrationDebugMemeProviderInstalled }
        try await pollUntil(2.0) { engine.integrationDebugAuxiliaryIsRunning(item.sourceID) }

        await engine.shutdown()
    }

    // MARK: async cue — remove / shutdown / newer-trigger invalidate the cue

    /// Every trigger, removeMeme, and shutdown BUMP the cue generation, superseding
    /// an in-flight frame-zero cue (which checks the generation before restarting).
    func testCueGenerationInvalidatedByTriggerRemoveShutdown() async throws {
        let gifURL = try makeAnimatedGIF(colors: [(1,0,0),(0,1,0)], delay: 0.2, side: 16)
        let engine = AppEngine()
        engine.addMeme(url: gifURL, mode: .insert, placement: .corner(.topRight), holdSec: 0.5, isBuiltIn: true)
        let item = try XCTUnwrap(engine.memeItems.first { $0.mediaURL == gifURL })

        let g0 = engine.integrationDebugCueGeneration
        engine.triggerMeme(id: item.id)
        let g1 = engine.integrationDebugCueGeneration
        XCTAssertGreaterThan(g1, g0, "trigger did not bump the cue generation")
        // removeMeme bumps this source's generation (superseding any in-flight cue) AND
        // reclaims the key (sol #4 leak fix): a cue that captured the pre-remove value now
        // sees an absent/different generation and is rejected.
        engine.removeMeme(id: item.id)
        XCTAssertEqual(engine.integrationDebugCueGenerationKeyCount, 0,
                       "removeMeme did not invalidate/reclaim the source's cue generation")
        await engine.shutdown()
        XCTAssertEqual(engine.integrationDebugCueGenerationKeyCount, 0,
                       "shutdown did not clear the cue-generation dict")
    }

    /// Removing a meme mid-cue must leave NO provider installed (the stale cue can't
    /// resurrect the removed source or install its dead provider after teardown).
    func testRemoveMidCueInstallsNoProvider() async throws {
        let gifURL = try makeAnimatedGIF(colors: [(1,0,0),(0,1,0)], delay: 0.2, side: 16)
        let engine = AppEngine()
        engine.addMeme(url: gifURL, mode: .insert, placement: .corner(.topRight), holdSec: 0.5, isBuiltIn: true)
        let item = try XCTUnwrap(engine.memeItems.first { $0.mediaURL == gifURL })
        engine.triggerMeme(id: item.id)
        engine.removeMeme(id: item.id)                 // synchronously, mid-cue
        try await Task.sleep(nanoseconds: 200_000_000) // let any pending cue drain
        XCTAssertFalse(engine.integrationDebugMemeProviderInstalled,
                       "a removed meme's stale cue installed a provider after teardown (async-cue regression)")
        XCTAssertNil(engine.memeItems.first { $0.mediaURL == gifURL }, "meme not removed")
        await engine.shutdown()
    }

    /// A newer STILL trigger during an animated cue wins; the stale animated cue is
    /// dropped and cannot overwrite it.
    func testNewerStillTriggerWinsOverAnimatedCue() async throws {
        let gifURL = try makeAnimatedGIF(colors: [(1,0,0),(0,1,0)], delay: 0.2, side: 16)
        let stillURL = try makeStillPNG(side: 16)
        let engine = AppEngine()
        engine.addMeme(url: gifURL, mode: .insert, placement: .corner(.topRight), holdSec: 2, isBuiltIn: true)
        engine.addMeme(url: stillURL, mode: .cutTo, placement: .fullscreen, holdSec: 2, isBuiltIn: true)
        let gif = try XCTUnwrap(engine.memeItems.first { $0.mediaURL == gifURL })
        let still = try XCTUnwrap(engine.memeItems.first { $0.mediaURL == stillURL })

        engine.triggerMeme(id: gif.id)      // animated cue in flight
        engine.triggerMeme(id: still.id)    // newer still trigger — installs synchronously, bumps gen
        XCTAssertTrue(engine.integrationDebugMemeProviderInstalled, "newer still trigger did not install")
        try await Task.sleep(nanoseconds: 200_000_000)   // let the stale animated cue land
        // The provider is still installed (the stale cue did not tear it down or
        // replace it); the still meme is the live one.
        XCTAssertTrue(engine.integrationDebugMemeProviderInstalled,
                      "the stale animated cue overwrote/dropped the newer still trigger (async-cue regression)")
        await engine.shutdown()
    }

    // MARK: F15 — aggregate budget covers ORDINARY GIFs; reject-before-decode; capture GPU release

    /// Adding many ordinary (non-meme) GIF sources keeps the aggregate decoded-byte
    /// total under the hard ceiling — pre-fix only memes counted, so ordinary GIFs
    /// were unbounded.
    func testOrdinaryGIFsStayUnderAggregateCeiling() throws {
        let engine = AppEngine()
        let ceiling = engine.integrationDebugAnimatedMemeBytes.ceiling
        // ~0.6 GiB each → three of them would exceed 1 GiB unless bounded.
        let big = try makeAnimatedGIF(colors: Array(repeating: (0.5,0.5,0.5), count: 8),
                                      delay: 0.1, side: 1500)
        for _ in 0..<4 { engine.addGIFSource(fileURL: big) }
        let total = engine.integrationDebugAnimatedMemeBytes.total
        XCTAssertLessThanOrEqual(total, ceiling,
                                 "ordinary GIFs blew past the aggregate ceiling (\(total) > \(ceiling)) — F15")
        XCTAssertGreaterThan(total, 0, "no ordinary GIF was tracked in the aggregate budget (F15)")
    }

    /// A GIF that cannot fit even alone is rejected WITHOUT decoding — the estimate
    /// comes from metadata only. Proven by admitting nothing and surfacing an error
    /// with the source never registered.
    func testOverBudgetGIFRejectedWithoutDecode() throws {
        let engine = AppEngine()
        // A GIF whose METADATA estimate exceeds the whole 1 GiB ceiling on its own:
        // ~300 frames at the 1280×720 capped decode size ≈ 1.1 GiB. The estimate is
        // read from ImageIO metadata (frame count + first-frame pixel size), so the
        // reject decision needs NO decode of the 300 frames.
        let huge = try makeAnimatedGIF(colors: Array(repeating: (0.2, 0.4, 0.6), count: 300),
                                       delay: 0.05, side: 1280)
        let est = AppEngine.estimatedAnimatedByteCost(url: huge, mode: .insert)
        XCTAssertGreaterThan(est, engine.integrationDebugAnimatedMemeBytes.ceiling,
                             "fixture not large enough to exceed the ceiling (\(est))")
        let activeBefore = engine.integrationDebugActiveSourceCount
        engine.addGIFSource(fileURL: huge)
        XCTAssertEqual(engine.integrationDebugAnimatedMemeBytes.total, 0,
                       "an over-budget GIF was admitted/tracked (F15)")
        XCTAssertEqual(engine.integrationDebugActiveSourceCount, activeBefore,
                       "the rejected GIF was still registered as a source")
        XCTAssertNotNil(engine.lastError, "rejection did not surface an error")
    }

    /// F15 residual: disabling the video wall must release the capture-thread
    /// `SourceEffectGPU` warm floor SYNCHRONOUSLY at the disable site — NOT deferred
    /// to the next `process(_:)` callback, which never arrives for a STALLED source
    /// (it then pins ~47.5 MiB indefinitely). Crucially this asserts release WITHOUT
    /// a further `process()` call — the exact stalled-source condition. Pre-fix
    /// (release only inside `process`) this is red.
    func testCaptureGPUReleasedSynchronouslyWhenVideoWallDisabled() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let side = 64
        let pipeline = SourceEffectPipeline(device: device, sourceID: SourceID("fx.wall"),
                                            canvasWidth: side, canvasHeight: side)
        pipeline.update(SourceEffects(videoWall: VideoWall(rows: 2, cols: 2, mirror: false)))
        let raw = try makeBGRAFrame(side: side, source: SourceID("fx.wall"))
        _ = pipeline.process(raw)                         // allocates the capture GPU
        XCTAssertTrue(pipeline.debugHasCaptureGPU, "capture GPU was never allocated")

        // Disable the wall. The source then STALLS (no further process() callback).
        pipeline.update(SourceEffects())
        XCTAssertFalse(pipeline.debugHasCaptureGPU,
                       "capture GPU floor not released at the disable site — a stalled source with no further process() would pin it (F15 residual)")
    }

    // MARK: AnimatedFXDriver — prune by KEYSET, drop stale raw on re-register

    func testAnimatedFXDriverKeysetPruneAndStaleGuard() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let side = 32
        let a = SourceID("fx.A"), b = SourceID("fx.B")
        let pipA = SourceEffectPipeline(device: device, sourceID: a, canvasWidth: side, canvasHeight: side)
        pipA.update(SourceEffects(tile: TileEffect(mode: .flicker, speed: 2)))   // animated
        let pipB = SourceEffectPipeline(device: device, sourceID: b, canvasWidth: side, canvasHeight: side)
        pipB.update(SourceEffects())                                              // inactive

        let driver = AnimatedFXDriver()
        driver.register(a, pipA)
        driver.register(b, pipB)
        let pts = CMTime(seconds: 0.1, preferredTimescale: 1_000_000_000)
        let frameA = try makeBGRAFrame(side: side, source: a)
        let frameB = try makeBGRAFrame(side: side, source: b)
        _ = driver.process([a: frameA, b: frameB], pts: pts)
        XCTAssertTrue(driver.debugHasHeldRaw(a), "animated A never held its raw frame")

        // Unregister A while inactive B remains — counts are equal, so a count-based
        // prune would NOT fire and A's IOSurface would leak forever.
        driver.unregister(a)
        _ = driver.process([b: frameB], pts: pts)
        XCTAssertFalse(driver.debugHasHeldRaw(a),
                       "unregistered A's held raw/IOSurface leaked (count-prune bug) — MEDIUM")

        // Re-register A: it must NOT animate a STALE frame — no held raw until a
        // FRESH frame lands.
        driver.register(a, pipA)
        _ = driver.process([b: frameB], pts: pts)          // no fresh frame for A
        XCTAssertFalse(driver.debugHasHeldRaw(a),
                       "re-registered A animated a stale frame from its previous generation (MEDIUM)")
        _ = driver.process([a: frameA, b: frameB], pts: pts)
        XCTAssertTrue(driver.debugHasHeldRaw(a), "A never picked up its fresh frame after re-register")
    }

    // MARK: alpha MovieSource — transparent ProRes 4444 reveals the lower layer

    func testTransparentProRes4444RevealsLowerLayer() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let movURL = try writeTransparentProRes4444(w: 64, h: 64)
        defer { try? FileManager.default.removeItem(at: movURL) }

        let engine = AppEngine()
        // Lower layer: opaque red camera-like source is hard without hardware; use a
        // still image source (opaque) beneath, then the alpha movie on top.
        // Instead, verify the LAYER FLAG the App sets (the composited reveal is the
        // engine shader's job, owned elsewhere): an alpha movie's scene layer must
        // be premultiplied so the compositor honors its alpha.
        engine.addMovieSource(fileURL: movURL, loop: false)
        try await pollUntil(1.5) { engine.integrationDebugMovieSourceIDs.isEmpty == false }
        let movieID = try XCTUnwrap(engine.integrationDebugMovieSourceIDs.first)
        XCTAssertTrue(engine.layerNeedsPremultipliedAlpha(movieID),
                      "an alpha (ProRes 4444) movie's layer is NOT premultiplied → it flattens to opaque black (Class C)")
        let layerPremult = engine.integrationDebugLayerPremultiplied(movieID)
        XCTAssertEqual(layerPremult, true,
                       "the alpha movie's live scene layer did not get premultipliedAlpha=true")
        await engine.shutdown()
    }

    // MARK: N2 — an animated stinger stops after its transition completes

    /// The stinger cue restarts a GIF/movie source at frame 0 when the transition
    /// begins; a NORMAL completion only cleared IDs/tokens and never stopped it, so
    /// the media free-ran forever. Drive an armed animated stinger through a real
    /// scene switch to completion and assert its source is STOPPED afterwards.
    func testAnimatedStingerStopsAfterCompletion() async throws {
        let gifURL = try makeAnimatedGIF(colors: [(1,0,0),(0,1,0),(0,0,1),(1,1,0)], delay: 0.05, side: 24)
        let engine = AppEngine()
        guard engine.renderLoop != nil else { await engine.shutdown(); throw XCTSkip("no render loop") }
        engine.prepareMemes()                                   // gives applyPreset real sources
        engine.addMeme(url: gifURL, mode: .stinger, placement: .fullscreen, holdSec: 0.4, isBuiltIn: true)
        let sting = try XCTUnwrap(engine.memeItems.first { $0.mediaURL == gifURL })

        engine.triggerMeme(id: sting.id)                        // arms the stinger tile
        XCTAssertEqual(engine.armedStingerMemeID, sting.id)

        engine.applyPreset(.pipCorner)                          // scene switch consumes the arm → runs it
        XCTAssertNil(engine.armedStingerMemeID, "scene switch did not consume the armed stinger")
        // The cue (async, off-main) restarts the GIF; once frame zero lands the
        // transition ACTIVATES (activeStinger set) and the GIF plays during it.
        try await pollUntil(2.0) { engine.integrationDebugActiveStingerSourceID == sting.sourceID }
        XCTAssertTrue(engine.integrationDebugAuxiliaryIsRunning(sting.sourceID),
                      "stinger media not playing during its own transition")

        // After the transition completes, the completion must stop the free-running
        // stinger media (N2). Pre-fix it kept running with no one to stop it.
        try await pollUntil(3.0) { !engine.integrationDebugAuxiliaryIsRunning(sting.sourceID) }
        XCTAssertFalse(engine.integrationDebugAuxiliaryIsRunning(sting.sourceID),
                       "animated stinger kept free-running after its transition completed (N2)")
        XCTAssertNil(engine.integrationDebugActiveStingerSourceID)
        await engine.shutdown()
    }

    // MARK: N3 — removing one held meme must not strand the others

    /// Two animated memes hold simultaneously; removing meme A must leave meme B
    /// still holding and tearing down on ITS OWN schedule (its source stopped at its
    /// hold end), not stranded free-running. Pre-fix, `removeMeme(A)` reset the whole
    /// director and cancelled the teardown timer, leaking B forever.
    func testRemovingOneMemeDoesNotStrandTheOther() async throws {
        let gifA = try makeAnimatedGIF(colors: [(1,0,0),(0,1,0)], delay: 0.05, side: 20)
        let gifB = try makeAnimatedGIF(colors: [(0,0,1),(1,1,0)], delay: 0.05, side: 20)
        let engine = AppEngine()
        guard engine.renderLoop != nil else { await engine.shutdown(); throw XCTSkip("no render loop") }
        engine.addMeme(url: gifA, mode: .insert, placement: .corner(.topLeft), holdSec: 0.6, isBuiltIn: true)
        engine.addMeme(url: gifB, mode: .insert, placement: .corner(.topRight), holdSec: 0.6, isBuiltIn: true)
        let a = try XCTUnwrap(engine.memeItems.first { $0.mediaURL == gifA })
        let b = try XCTUnwrap(engine.memeItems.first { $0.mediaURL == gifB })

        // Trigger A, wait for its frame-zero cue to LAND (running) before triggering
        // B — every trigger bumps the single latest-wins cue generation, so a second
        // trigger while A's cue is still in flight would supersede it. Once A is live
        // its cue is done, so B's trigger doesn't disturb it; both then hold.
        engine.triggerMeme(id: a.id)
        try await pollUntil(2.0) { engine.integrationDebugAuxiliaryIsRunning(a.sourceID) }
        engine.triggerMeme(id: b.id)
        try await pollUntil(2.0) { engine.integrationDebugAuxiliaryIsRunning(b.sourceID) }
        XCTAssertTrue(engine.integrationDebugAuxiliaryIsRunning(a.sourceID),
                      "meme A stopped when B was triggered")

        // Remove A mid-hold. A stops; B must remain holding + running (its hold has
        // not ended) with the provider + teardown still alive.
        engine.removeMeme(id: a.id)
        XCTAssertFalse(engine.integrationDebugAuxiliaryIsRunning(a.sourceID), "removed meme A not stopped")
        XCTAssertTrue(engine.integrationDebugAuxiliaryIsRunning(b.sourceID),
                      "meme B was stopped when A was removed (should hold on its own schedule)")
        XCTAssertTrue(engine.integrationDebugMemeProviderInstalled,
                      "removing A tore down the provider while B still holds (N3)")

        // B tears down on its OWN schedule: at its hold end the teardown fires and
        // stops B's source. Pre-fix the timer was cancelled → B leaked forever.
        engine.integrationDebugExpireMemeProviderNow()
        XCTAssertFalse(engine.integrationDebugAuxiliaryIsRunning(b.sourceID),
                       "meme B leaked free-running after A was removed — its teardown was stranded (N3)")
        XCTAssertFalse(engine.integrationDebugMemeProviderInstalled)
        await engine.shutdown()
    }

    // MARK: F14 — a cue TIMEOUT must stop the source (not leave it free-running)

    /// `cueAnimatedSourceToFrameZero` starts the source, then waits for frame zero.
    /// On TIMEOUT it returned false but left the source RUNNING (decoding); the
    /// failed-cue cleanup never stopped it. Force a timeout by handing the cue a
    /// mailbox the source never posts into, and assert the source ends STOPPED.
    func testCueTimeoutStopsSource() throws {
        let gifURL = try makeAnimatedGIF(colors: [(1,0,0),(0,1,0),(0,0,1)], delay: 0.05, side: 16)
        let source = try AnimatedGIFSource(fileURL: gifURL, canvasSize: .hd,
                                           contentMode: .aspectFit, loop: true)
        // The source posts to its OWN onFrame (unset) — the mailbox handed to the cue
        // is a DIFFERENT one, so it never sees frame zero → the cue times out.
        let orphanMailbox = FrameMailbox()
        let landed = AppEngine.cueAnimatedSourceToFrameZero(source, mailbox: orphanMailbox, timeout: 0.08)
        XCTAssertFalse(landed, "cue should report failure when frame zero never lands")
        XCTAssertNotEqual(source.state, .running,
                          "F14: a timed-out cue left the source RUNNING (free-run leak)")
    }

    // MARK: async-cue race — supersession in the check→start window stops the source

    /// A removeMeme/shutdown/newer-trigger can land AFTER the pre-start generation
    /// check but BEFORE the source restart, resurrecting a now-unwanted source. The
    /// generation rejection prevents the provider install but must ALSO stop the
    /// source it just started. Negative control: the pre-start hook forces exactly
    /// that interleave (the cue restarts the source, which then delivers frame zero
    /// = `landed`), so the ONLY thing that stops the resurrected source is the
    /// post-start recheck; neutralizing it leaves the source decoding.
    func testAsyncCueSupersededInWindowStopsSource() async throws {
        let gifURL = try makeAnimatedGIF(colors: [(1,0,0),(0,1,0)], delay: 0.05, side: 16)
        let engine = AppEngine()
        engine.addMeme(url: gifURL, mode: .insert, placement: .lowerThird, holdSec: 1, isBuiltIn: true)
        let item = try XCTUnwrap(engine.memeItems.first { $0.mediaURL == gifURL })
        XCTAssertFalse(engine.integrationDebugAuxiliaryIsRunning(item.sourceID),
                       "meme was running before it was triggered")

        // Fire in the exact check→start window (on the cue queue): bump the cue
        // generation, i.e. simulate a removeMeme/newer-trigger/shutdown landing there.
        // Only ONCE — a fresh re-trigger later must be able to run normally.
        let fired = OSAllocatedUnfairLock(initialState: false)
        AppEngine._test_cuePreStartHook = { [weak engine] in
            let go = fired.withLock { done -> Bool in if done { return false }; done = true; return true }
            if go { engine?._test_bumpCueGeneration() }
        }
        defer { AppEngine._test_cuePreStartHook = nil }

        engine.triggerMeme(id: item.id)
        // Let the FULL cue run: it restarts the source (which delivers frame zero →
        // landed), then the post-start recheck sees the bumped generation. With the
        // fix the source ends STOPPED and no provider is installed; without it the
        // resurrected source keeps decoding. Settle, then read the terminal state.
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertFalse(engine.integrationDebugAuxiliaryIsRunning(item.sourceID),
                       "async-cue race: a superseded cue left the resurrected source decoding (leak)")
        XCTAssertFalse(engine.integrationDebugMemeProviderInstalled,
                       "a superseded cue still installed a provider")
        await engine.shutdown()
    }

    // MARK: F15 — the LIVE addGIFSource path genuinely evicts near the ceiling

    /// Add several real GIFs whose aggregate estimate genuinely EXCEEDS the 1 GiB
    /// ceiling, driving the live `addGIFSource → admit → evict` path. Assert the
    /// oldest is evicted, the newest two are resident, and the total stays under the
    /// ceiling while genuinely APPROACHING it (the prior fixture summed ~112 MiB and
    /// never evicted at all — a vacuous ceiling test).
    func testLiveAnimatedSourcesEvictOldestNearCeiling() throws {
        let engine = AppEngine()
        let ceiling = engine.integrationDebugAnimatedMemeBytes.ceiling
        // 1280×720 native → decodes at 1280×720 (the 720p cap, no downscale); ~120
        // frames ≈ 442 MiB each (< the 512 MiB per-source cap), so three sum to
        // ~1.3 GiB and force one eviction.
        let framesEach = 120
        let g1 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: framesEach)
        let g2 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: framesEach)
        let g3 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: framesEach)
        let each = AppEngine.estimatedAnimatedByteCost(url: g1, mode: .insert)
        XCTAssertGreaterThan(each * 3, ceiling,
                             "fixtures too small to exceed the ceiling (3 × \(each) ≤ \(ceiling))")
        XCTAssertLessThanOrEqual(each, ceiling, "a single fixture must fit alone")

        engine.addGIFSource(fileURL: g1)
        let id1 = try XCTUnwrap(engine.integrationDebugActiveSourceIDs.last)
        engine.addGIFSource(fileURL: g2)
        engine.addGIFSource(fileURL: g3)   // pushes over the ceiling → evicts the oldest (g1)

        let (total, _) = engine.integrationDebugAnimatedMemeBytes
        XCTAssertLessThanOrEqual(total, ceiling,
                                 "aggregate blew past the ceiling on the live path (\(total) > \(ceiling)) — F15")
        XCTAssertGreaterThan(total, ceiling / 2,
                             "aggregate never approached the ceiling — vacuous eviction test (\(total))")
        XCTAssertFalse(engine.integrationDebugActiveSourceIDs.contains(id1),
                       "the oldest animated source was not evicted when the ceiling was exceeded (F15)")
    }

    // MARK: sol #2 — removeSource must stop FX-driver injection BEFORE forgetting the mailbox

    /// A source with an ACTIVE animated-FX driver has its held `lastRaw` injected on
    /// every render tick (even ticks it does not emit). If teardown forgets the
    /// compositor mailbox BEFORE unregistering the driver, the driver keeps injecting
    /// the removed source across the window; once the forget-tombstone is pruned
    /// (2 ticks) an injected stale frame is ACCEPTED and pins the IOSurface forever
    /// (reopened F1). `removeSource` must unregister the driver FIRST. Real driver +
    /// real compositor, driven exactly as `RenderLoop.run` does (capture epoch →
    /// FX-driver process → composite); oracle = `retainedFrame(for:)` (the ACTUAL
    /// pinned buffer). Negative control: the pre-fix order genuinely re-pins.
    func testRemoveSourceUnregistersFXDriverBeforeForget() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let side = 32
        let a = SourceID("fx.remove")

        func stalePinAfterRemoval(unregisterBeforeForget: Bool) throws -> Bool {
            // Drive the REAL RenderLoop (its own render thread, real pull-time epoch
            // capture) with the FX driver as its frame processor — exactly the live
            // pipeline. `removeMailbox` only sets a forget-tombstone (pruned after 2
            // ticks); while the driver stays registered it re-injects A's held raw
            // every tick, so after the tombstone prunes an injected stale frame is
            // accepted and pins the IOSurface (reopened F1).
            let compositor = try MetalCompositor(device: device, width: side, height: side)
            let loop = RenderLoop(compositor: compositor, fps: 240)
            let driver = AnimatedFXDriver()
            let pipeline = SourceEffectPipeline(device: device, sourceID: a,
                                                canvasWidth: side, canvasHeight: side)
            pipeline.update(SourceEffects(tile: TileEffect(mode: .flicker, speed: 2)))  // animated → injects every tick
            driver.register(a, pipeline)
            loop.frameProcessor = { frames, pts in driver.process(frames, pts: pts) }
            loop.scene = Scene(name: "s", layers: [Layer(sourceID: a)])
            let box = FrameMailbox()
            box.post(try makeBGRAFrame(side: side, source: a))
            loop.setMailbox(box, for: a)
            defer { _ = loop.stop() }
            loop.start()

            // Prime: wait until A is pinned (the state a live removed source is in).
            let primeDeadline = ProcessInfo.processInfo.systemUptime + 2
            while compositor.retainedFrame(for: a) == nil,
                  ProcessInfo.processInfo.systemUptime < primeDeadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            XCTAssertNotNil(compositor.retainedFrame(for: a), "A never pinned during priming")

            if unregisterBeforeForget {
                driver.unregister(a)          // FIX (removeSource order): stop injection FIRST…
                loop.removeMailbox(for: a)    // …then forget the compositor frame.
            } else {
                loop.removeMailbox(for: a)    // BUG: forget first; the driver keeps injecting across the window.
            }
            // Let the render thread run WELL past the 2-tick tombstone TTL.
            Thread.sleep(forTimeInterval: 0.4)
            if !unregisterBeforeForget { driver.unregister(a) }   // pre-fix: unregister ran LATE
            Thread.sleep(forTimeInterval: 0.1)
            _ = loop.stop()
            return compositor.retainedFrame(for: a) != nil
        }

        // NEGATIVE CONTROL (pre-fix order): the FX driver re-pins the removed source.
        XCTAssertTrue(try stalePinAfterRemoval(unregisterBeforeForget: false),
                      "negative control vacuous: forget-then-unregister did NOT re-pin — the re-pin mechanism never fired")
        // FIX (removeSource order): unregister first → no stale injection survives the forget.
        XCTAssertFalse(try stalePinAfterRemoval(unregisterBeforeForget: true),
                       "sol #2: FX driver re-pinned a removed source's IOSurface (unregister must run BEFORE forget)")
    }

    // MARK: sol #3 — capture-GPU TOCTOU: a stale in-flight callback must not resurrect the floor

    /// `process(_:)` snapshots `fx.videoWall`; the main actor then DISABLES the wall
    /// and releases the ~47.5 MiB capture GPU synchronously. An in-flight callback
    /// following its STALE snapshot must re-read the CURRENT enabled state before
    /// recreating the GPU — otherwise it resurrects the floor (pinned forever if it is
    /// the last callback). Negative control: bypass the re-read and the stale callback
    /// re-allocates the GPU.
    func testCaptureGPUNotResurrectedByStaleInFlightCallback() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let side = 64
        let wall = VideoWall(rows: 2, cols: 2, mirror: false)

        func recreatedAfterDisable(bypassReRead: Bool) throws -> Bool {
            let pipeline = SourceEffectPipeline(device: device, sourceID: SourceID("fx.toctou"),
                                                canvasWidth: side, canvasHeight: side)
            pipeline.update(SourceEffects(videoWall: wall))
            let frame = try makeBGRAFrame(side: side, source: SourceID("fx.toctou"))
            _ = pipeline.process(frame)                    // allocates the capture GPU
            XCTAssertTrue(pipeline.debugHasCaptureGPU, "capture GPU was never allocated")

            pipeline.update(SourceEffects())               // main actor disables + releases the GPU
            XCTAssertFalse(pipeline.debugHasCaptureGPU, "release did not clear the GPU")

            SourceEffectPipeline._test_bypassCaptureWallReRead = bypassReRead
            // This test targets the capture-GPU re-read (the ~47.5 MiB floor). Bypass the
            // sol #4 applyVideoWall disable gate so the callback still reaches
            // `captureEffectGPU` (otherwise the disable gate short-circuits before it).
            SourceEffectPipeline._test_skipVideoWallDisableGate = true
            defer {
                SourceEffectPipeline._test_bypassCaptureWallReRead = false
                SourceEffectPipeline._test_skipVideoWallDisableGate = false
            }
            pipeline._test_applyVideoWallWithStaleSnapshot(frame, staleWall: wall)   // stale in-flight callback
            return pipeline.debugHasCaptureGPU
        }

        // NEGATIVE CONTROL: without the re-read the stale callback resurrects the GPU.
        XCTAssertTrue(try recreatedAfterDisable(bypassReRead: true),
                      "negative control vacuous: the stale callback did not recreate the GPU even without the re-read")
        // FIX: the re-read makes the disable win — no resurrection, floor stays released.
        XCTAssertFalse(try recreatedAfterDisable(bypassReRead: false),
                       "sol #3: a stale in-flight callback resurrected the capture-GPU floor after disable")
    }

    // MARK: sol #4 — evict BEFORE decode (peak ceiling) with rollback (no destructive loss)

    /// A fitting replacement evicts the oldest BEFORE decoding so PEAK resident bytes
    /// never exceed the ceiling; but if the decode FAILS the evicted victims are RE-ADMITTED
    /// (no destructive loss). Force a construction failure after admission and assert the
    /// evicted media is re-admitted (its bytes restored). Negative control: skip the
    /// rollback and the victim is lost.
    func testAnimatedAdmissionFailureReadmitsEvictedVictims() throws {
        let framesEach = 120
        let g1 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: framesEach)
        let g2 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: framesEach)
        let g3 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: framesEach)
        let each = AppEngine.estimatedAnimatedByteCost(url: g1, mode: .insert)

        func totalAfterFailedAdd(skipRollback: Bool) throws -> (total: Int, each: Int) {
            let engine = AppEngine()
            let ceiling = engine.integrationDebugAnimatedMemeBytes.ceiling
            XCTAssertLessThanOrEqual(each * 2, ceiling, "two fixtures must fit together")
            XCTAssertGreaterThan(each * 3, ceiling, "three fixtures must exceed the ceiling (force one eviction)")
            engine.addGIFSource(fileURL: g1)
            engine.addGIFSource(fileURL: g2)

            AppEngine._test_skipAdmissionRollback = skipRollback
            AppEngine._test_forceAnimatedConstructionFailure = true
            defer {
                AppEngine._test_skipAdmissionRollback = false
                AppEngine._test_forceAnimatedConstructionFailure = false
            }
            engine.addGIFSource(fileURL: g3)   // evicts g1 (before decode), decode FAILS
            return (engine.integrationDebugAnimatedMemeBytes.total, each)
        }

        // NEGATIVE CONTROL: no rollback → the evicted victim (g1) is lost; only g2 remains.
        let control = try totalAfterFailedAdd(skipRollback: true)
        XCTAssertEqual(control.total, control.each,
                       "negative control vacuous: the evicted victim was NOT lost without rollback")
        // FIX: rollback re-admits g1 → both fixtures' media resident again (no destructive loss).
        let fixed = try totalAfterFailedAdd(skipRollback: false)
        XCTAssertEqual(fixed.total, fixed.each * 2,
                       "sol #4: a failed replacement admit did not re-admit the evicted victim (destructive loss)")
    }

    /// PEAK resident bytes during a replacement admit must never exceed the ceiling — not
    /// just the POST-op accounting. With evict-before-decode the victim is already gone at
    /// the decode moment, so peak = survivors + replacement ≤ ceiling. Negative control:
    /// evict-AFTER-construct (wave-4 order) leaves the victim resident during decode, so
    /// peak = victim + survivor + replacement overshoots the ceiling (~1.33 GiB in sol's case).
    func testAnimatedAdmissionPeakStaysUnderCeiling() throws {
        let framesEach = 120
        let g1 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: framesEach)
        let g2 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: framesEach)
        let g3 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: framesEach)
        let each = AppEngine.estimatedAnimatedByteCost(url: g1, mode: .insert)

        func peakDuringThirdAdmit(evictAfter: Bool) throws -> (peakPlusNew: Int, ceiling: Int) {
            let engine = AppEngine()
            let ceiling = engine.integrationDebugAnimatedMemeBytes.ceiling
            XCTAssertLessThanOrEqual(each * 2, ceiling, "two fixtures must fit together")
            XCTAssertGreaterThan(each * 3, ceiling, "three fixtures must exceed the ceiling")
            engine.addGIFSource(fileURL: g1)
            engine.addGIFSource(fileURL: g2)

            let residentAtDecode = OSAllocatedUnfairLock<Int>(initialState: 0)
            AppEngine._test_evictAfterConstruct = evictAfter
            AppEngine._test_beforeAnimatedDecodeHook = {
                residentAtDecode.withLock {
                    $0 = MainActor.assumeIsolated { engine.integrationDebugAnimatedMemeBytes.total }
                }
            }
            defer {
                AppEngine._test_evictAfterConstruct = false
                AppEngine._test_beforeAnimatedDecodeHook = nil
            }
            engine.addGIFSource(fileURL: g3)   // plans to evict g1
            // Peak = the animated bytes RESIDENT at the pre-decode moment + the replacement
            // that is about to be decoded (both live simultaneously during the decode).
            return (residentAtDecode.withLock { $0 } + each, ceiling)
        }

        // NEGATIVE CONTROL (evict-after / wave-4 order): victim still resident at decode →
        // peak overshoots the ceiling.
        let control = try peakDuringThirdAdmit(evictAfter: true)
        XCTAssertGreaterThan(control.peakPlusNew, control.ceiling,
                             "negative control vacuous: evict-after did not overshoot peak")
        // FIX (evict-before-decode): victim already evicted at decode → peak under the ceiling.
        let fixed = try peakDuringThirdAdmit(evictAfter: false)
        XCTAssertLessThanOrEqual(fixed.peakPlusNew, fixed.ceiling,
                                 "sol #4: replacement decoded while the victim was still resident — peak exceeded the ceiling")
    }

    // MARK: sol #4 — independent meme lifetimes (per-meme deadlines)

    /// Two memes with DIFFERENT holds: a short one must tear its source down on ITS
    /// OWN hold end while a long one keeps running. Pre-fix a single global `max`
    /// deadline kept the short meme's source decoding until the LONGEST held meme's
    /// hold end. Negative control: couple the lifetimes (global-max) and the short
    /// meme is still running long past its own hold.
    func testMemesTearDownOnIndependentSchedules() async throws {
        func state(coupled: Bool) async throws -> (short: Bool, long: Bool) {
            let gifLong = try makeAnimatedGIF(colors: [(1,0,0),(0,1,0)], delay: 0.05, side: 16)
            let gifShort = try makeAnimatedGIF(colors: [(0,0,1),(1,1,0)], delay: 0.05, side: 16)
            let engine = AppEngine()
            guard engine.renderLoop != nil else { await engine.shutdown(); throw XCTSkip("no render loop") }
            engine.addMeme(url: gifLong, mode: .insert, placement: .corner(.topLeft), holdSec: 3.0, isBuiltIn: true)
            engine.addMeme(url: gifShort, mode: .insert, placement: .corner(.topRight), holdSec: 0.3, isBuiltIn: true)
            let long = try XCTUnwrap(engine.memeItems.first { $0.mediaURL == gifLong })
            let short = try XCTUnwrap(engine.memeItems.first { $0.mediaURL == gifShort })

            AppEngine._test_coupleMemeLifetimes = coupled
            defer { AppEngine._test_coupleMemeLifetimes = false }

            engine.triggerMeme(id: long.id)
            try await pollUntil(2.0) { engine.integrationDebugAuxiliaryIsRunning(long.sourceID) }
            engine.triggerMeme(id: short.id)
            try await pollUntil(2.0) { engine.integrationDebugAuxiliaryIsRunning(short.sourceID) }

            // Past the SHORT hold (0.3 + margin ≈ 0.55 s) but well before the long's (≈3.25 s).
            try await Task.sleep(nanoseconds: 1_200_000_000)
            let s = engine.integrationDebugAuxiliaryIsRunning(short.sourceID)
            let l = engine.integrationDebugAuxiliaryIsRunning(long.sourceID)
            await engine.shutdown()
            return (s, l)
        }

        // NEGATIVE CONTROL: coupled → the short meme runs until the long meme's deadline.
        let control = try await state(coupled: true)
        XCTAssertTrue(control.short, "negative control vacuous: coupled short meme was not kept running past its own hold")
        // FIX: independent → the short meme is torn down on its own hold; the long one still runs.
        let fixed = try await state(coupled: false)
        XCTAssertFalse(fixed.short, "sol #4: short meme kept decoding past its own hold (lifetime coupled to the longer meme)")
        XCTAssertTrue(fixed.long, "sol #4: the longer meme was cut short (should still be holding)")
    }

    /// Two DISTINCT animated inserts triggered back-to-back (A's frame-zero cue still
    /// in flight when B fires) must BOTH cue and run. Pre-fix a single global cue
    /// generation made B's trigger supersede A's in-flight cue, so A never installed.
    /// Negative control: one global generation → the first insert is cancelled.
    func testDistinctRapidInsertsDoNotCancelEachOther() async throws {
        func bothRan(globalGen: Bool) async throws -> (a: Bool, b: Bool) {
            let gifA = try makeAnimatedGIF(colors: [(1,0,0),(0,1,0)], delay: 0.05, side: 16)
            let gifB = try makeAnimatedGIF(colors: [(0,0,1),(1,1,0)], delay: 0.05, side: 16)
            let engine = AppEngine()
            guard engine.renderLoop != nil else { await engine.shutdown(); throw XCTSkip("no render loop") }
            engine.addMeme(url: gifA, mode: .insert, placement: .corner(.topLeft), holdSec: 3.0, isBuiltIn: true)
            engine.addMeme(url: gifB, mode: .insert, placement: .corner(.topRight), holdSec: 3.0, isBuiltIn: true)
            let a = try XCTUnwrap(engine.memeItems.first { $0.mediaURL == gifA })
            let b = try XCTUnwrap(engine.memeItems.first { $0.mediaURL == gifB })

            AppEngine._test_globalCueGeneration = globalGen
            defer { AppEngine._test_globalCueGeneration = false }

            engine.triggerMeme(id: a.id)   // A's cue dispatched…
            engine.triggerMeme(id: b.id)   // …B fires while A's cue is still in flight
            try await Task.sleep(nanoseconds: 900_000_000)   // both cues settle
            let ra = engine.integrationDebugAuxiliaryIsRunning(a.sourceID)
            let rb = engine.integrationDebugAuxiliaryIsRunning(b.sourceID)
            await engine.shutdown()
            return (ra, rb)
        }

        // NEGATIVE CONTROL: one global generation → the two distinct inserts cancel each other.
        let control = try await bothRan(globalGen: true)
        XCTAssertFalse(control.a && control.b,
                       "negative control vacuous: with one global generation both distinct inserts still ran")
        // FIX: per-source generations → both distinct inserts cue and run.
        let fixed = try await bothRan(globalGen: false)
        XCTAssertTrue(fixed.a, "sol #4: distinct insert A was cancelled by B's trigger (shared cue generation)")
        XCTAssertTrue(fixed.b, "insert B did not run")
    }

    // MARK: sol #3 — stinger stops on failed cue; unrelated meme expiry never freezes it

    /// A stinger whose cue FAILS (timeout/error) restarted its media to restore
    /// resting playback, then fell back to a plain cut with NO completion to stop it —
    /// leaving the media free-running. The failed-cue completion must stop it.
    /// Negative control: skip the terminal stop and the media keeps running.
    func testStingerMediaStoppedOnFailedCue() async throws {
        func stingerRunning(skipStop: Bool) async throws -> Bool {
            let gifURL = try makeAnimatedGIF(colors: [(1,0,0),(0,1,0),(0,0,1),(1,1,0)], delay: 0.05, side: 24)
            let engine = AppEngine()
            guard engine.renderLoop != nil else { await engine.shutdown(); throw XCTSkip("no render loop") }
            engine.prepareMemes()
            engine.addMeme(url: gifURL, mode: .stinger, placement: .fullscreen, holdSec: 0.6, isBuiltIn: true)
            let sting = try XCTUnwrap(engine.memeItems.first { $0.mediaURL == gifURL })

            AppEngine._test_forceStingerCueFailure = true
            AppEngine._test_skipStingerTerminalStop = skipStop
            defer {
                AppEngine._test_forceStingerCueFailure = false
                AppEngine._test_skipStingerTerminalStop = false
            }

            engine.triggerMeme(id: sting.id)   // arm
            engine.applyPreset(.pipCorner)     // scene switch → cue runs, FORCED to fail
            try await Task.sleep(nanoseconds: 900_000_000)
            let running = engine.integrationDebugAuxiliaryIsRunning(sting.sourceID)
            await engine.shutdown()
            return running
        }

        // NEGATIVE CONTROL: without the terminal stop the failed-cue stinger free-runs.
        let control = try await stingerRunning(skipStop: true)
        XCTAssertTrue(control,
                      "negative control vacuous: the failed-cue stinger did not stay running even without the terminal stop")
        // FIX: the failed-cue completion stops the media.
        let fixed = try await stingerRunning(skipStop: false)
        XCTAssertFalse(fixed,
                       "sol #3: stinger media free-ran after a failed (timeout/error) cue")
    }

    /// Expiring an UNRELATED animated meme mid-stinger must not touch the in-flight
    /// stinger. Pre-fix, meme teardown stopped EVERY animated meme, freezing the
    /// stinger. Negative control: stop-all-on-expiry freezes it.
    func testUnrelatedMemeExpiryDoesNotFreezeStinger() async throws {
        func stingerRunning(stopAll: Bool) async throws -> Bool {
            let stingerGIF = try makeAnimatedGIF(colors: [(1,0,0),(0,1,0),(0,0,1),(1,1,0)], delay: 0.05, side: 24)
            let insertGIF = try makeAnimatedGIF(colors: [(0,1,1),(1,0,1)], delay: 0.05, side: 20)
            let engine = AppEngine()
            guard engine.renderLoop != nil else { await engine.shutdown(); throw XCTSkip("no render loop") }
            engine.prepareMemes()
            engine.addMeme(url: stingerGIF, mode: .stinger, placement: .fullscreen, holdSec: 3.0, isBuiltIn: true)
            engine.addMeme(url: insertGIF, mode: .insert, placement: .corner(.topLeft), holdSec: 0.4, isBuiltIn: true)
            let sting = try XCTUnwrap(engine.memeItems.first { $0.mediaURL == stingerGIF })
            let insert = try XCTUnwrap(engine.memeItems.first { $0.mediaURL == insertGIF })

            AppEngine._test_stopAllMemesOnExpiry = stopAll
            defer { AppEngine._test_stopAllMemesOnExpiry = false }

            engine.triggerMeme(id: sting.id)
            engine.applyPreset(.pipCorner)
            try await pollUntil(2.0) { engine.integrationDebugActiveStingerSourceID == sting.sourceID }
            XCTAssertTrue(engine.integrationDebugAuxiliaryIsRunning(sting.sourceID), "stinger not playing during its transition")

            engine.triggerMeme(id: insert.id)
            try await pollUntil(2.0) { engine.integrationDebugAuxiliaryIsRunning(insert.sourceID) }
            engine.integrationDebugExpireMemeProviderNow()   // expire the unrelated insert

            let running = engine.integrationDebugAuxiliaryIsRunning(sting.sourceID)
            await engine.shutdown()
            return running
        }

        // NEGATIVE CONTROL (stop-all): expiring the unrelated meme froze the stinger.
        let control = try await stingerRunning(stopAll: true)
        XCTAssertFalse(control,
                       "negative control vacuous: stop-all-on-expiry did not stop the stinger")
        // FIX: scoped teardown leaves the in-flight stinger untouched.
        let fixed = try await stingerRunning(stopAll: false)
        XCTAssertTrue(fixed,
                      "sol #3: an unrelated meme expiry froze the in-flight stinger")
    }

    // MARK: sol #4 — a rapid second switch / HDR rebuild must stop the abandoned stinger

    /// A stinger cue restarts its media at frame 0 when the switch begins. A rapid SECOND
    /// scene switch (or HDR rebuild) clears the pending token WITHOUT stopping the media;
    /// the first cue's completion then fails its token guard and returns BEFORE any stop
    /// path, so the media FREE-RUNS forever. The abandoned/superseded completion must stop
    /// it. Negative control: skip the terminal stop and the media keeps running.
    func testStingerMediaStoppedOnRapidSecondSwitch() async throws {
        func stingerRunning(skipStop: Bool) async throws -> Bool {
            let gifURL = try makeAnimatedGIF(colors: [(1,0,0),(0,1,0),(0,0,1),(1,1,0)], delay: 0.05, side: 24)
            let engine = AppEngine()
            guard engine.renderLoop != nil else { await engine.shutdown(); throw XCTSkip("no render loop") }
            engine.prepareMemes()
            engine.addMeme(url: gifURL, mode: .stinger, placement: .fullscreen, holdSec: 1.0, isBuiltIn: true)
            let sting = try XCTUnwrap(engine.memeItems.first { $0.mediaURL == gifURL })

            AppEngine._test_skipStingerTerminalStop = skipStop
            defer { AppEngine._test_skipStingerTerminalStop = false }

            engine.triggerMeme(id: sting.id)      // arm
            engine.applyPreset(.pipCorner)        // switch #1 → begins the cue (media restarted, in flight)
            engine.applyPreset(.fullscreen)       // switch #2 → abandons the pending cue's token
            try await Task.sleep(nanoseconds: 900_000_000)   // let the abandoned cue completion fire
            let running = engine.integrationDebugAuxiliaryIsRunning(sting.sourceID)
            await engine.shutdown()
            return running
        }
        // NEGATIVE CONTROL: without the terminal stop the abandoned stinger media free-runs.
        let control = try await stingerRunning(skipStop: true)
        XCTAssertTrue(control,
                      "negative control vacuous: the abandoned stinger media did not stay running")
        // FIX: the abandoned/superseded cue completion stops the media.
        let fixed = try await stingerRunning(skipStop: false)
        XCTAssertFalse(fixed,
                       "sol #4: stinger media free-ran after a rapid second switch abandoned its cue")
    }

    // MARK: sol #4 — an expired STILL-QUEUED cue must not resurrect untracked playback

    /// A meme's teardown deadline is installed BEFORE its frame-zero cue enters the serial
    /// cue queue. An existing timer can expire a still-QUEUED source and delete its deadline
    /// WITHOUT invalidating its cue generation; the queued cue then succeeds, restarts the
    /// source, installs a provider, and — with no deadline left — teardown is never
    /// scheduled (a permanently-running untracked meme). Fire the teardown inside the cue's
    /// check→start window; the fix's generation bump must make the queued cue reject itself.
    /// Negative control: skip the bump and the source/provider is resurrected.
    func testExpiredQueuedCueDoesNotResurrectUntrackedPlayback() async throws {
        func resurrected(skipBump: Bool) async throws -> (running: Bool, provider: Bool) {
            let gifURL = try makeAnimatedGIF(colors: [(1,0,0),(0,1,0)], delay: 0.05, side: 16)
            let engine = AppEngine()
            engine.addMeme(url: gifURL, mode: .insert, placement: .lowerThird, holdSec: 0.3, isBuiltIn: true)
            let item = try XCTUnwrap(engine.memeItems.first { $0.mediaURL == gifURL })

            AppEngine._test_skipTeardownGenerationBump = skipBump
            // In the cue's check→start window (off-main), expire this source's deadline via
            // the real teardown — deleting the deadline of a STILL-QUEUED cue. Fire once.
            let fired = OSAllocatedUnfairLock(initialState: false)
            AppEngine._test_cuePreStartHook = { [weak engine] in
                let go = fired.withLock { done -> Bool in if done { return false }; done = true; return true }
                guard go else { return }
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { engine?.integrationDebugExpireMemeProviderNow() }
                }
            }
            defer {
                AppEngine._test_cuePreStartHook = nil
                AppEngine._test_skipTeardownGenerationBump = false
            }
            engine.triggerMeme(id: item.id)
            try await Task.sleep(nanoseconds: 700_000_000)
            let r = (engine.integrationDebugAuxiliaryIsRunning(item.sourceID),
                     engine.integrationDebugMemeProviderInstalled)
            await engine.shutdown()
            return r
        }
        // NEGATIVE CONTROL: teardown deletes the deadline WITHOUT bumping the generation →
        // the queued cue resurrects the source and installs an untracked provider.
        let control = try await resurrected(skipBump: true)
        XCTAssertTrue(control.running || control.provider,
                      "negative control vacuous: the expired-queued cue did not resurrect the source/provider")
        // FIX: teardown bumps the generation → the queued cue rejects itself (no resurrection).
        let fixed = try await resurrected(skipBump: false)
        XCTAssertFalse(fixed.running,
                       "sol #4: an expired-queued cue left the source decoding (untracked resurrection)")
        XCTAssertFalse(fixed.provider,
                       "sol #4: an expired-queued cue installed a provider with no teardown")
    }

    // MARK: sol #4 — a DISABLED video wall must render nothing + release its CPU pool

    /// The capture-GPU re-read refuses GPU creation when the wall is disabled, but
    /// `applyVideoWall` treated the resulting nil GPU as a GPU FAILURE and fell into the CPU
    /// `TileRepeatRenderer`, rendering the STALE wall + retaining an `FXCanvas` pool. When
    /// the wall is DISABLED the effect must render nothing AND release the CPU pool.
    /// Negative control: skip the disable gate → the CPU fallback renders + retains the pool.
    func testDisabledVideoWallRendersNothingAndReleasesCPUPool() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let side = 48
        let wall = VideoWall(rows: 2, cols: 2, mirror: false)

        func result(skipGate: Bool) throws -> (produced: Bool, hasCPUPool: Bool) {
            // Default effects → the wall is DISABLED. The in-flight callback carries a STALE
            // non-nil wall snapshot; `captureEffectGPU` re-reads and refuses the GPU (nil).
            let pipeline = SourceEffectPipeline(device: device, sourceID: SourceID("fx.walldisable"),
                                                canvasWidth: side, canvasHeight: side)
            // sol #6 #15 added a SECOND (render-site) disable gate and sol #7 #4/#15 a
            // THIRD (emit-site) gate; reproducing the original CPU-render defect now
            // requires bypassing ALL THREE.
            SourceEffectPipeline._test_skipVideoWallDisableGate = skipGate
            SourceEffectPipeline._test_skipVideoWallRenderSiteGate = skipGate
            SourceEffectPipeline._test_skipVideoWallEmitSiteGate = skipGate
            defer {
                SourceEffectPipeline._test_skipVideoWallDisableGate = false
                SourceEffectPipeline._test_skipVideoWallRenderSiteGate = false
                SourceEffectPipeline._test_skipVideoWallEmitSiteGate = false
            }
            let frame = try makeBGRAFrame(side: side, source: SourceID("fx.walldisable"))
            let out = pipeline._test_applyVideoWallWithStaleSnapshot(frame, staleWall: wall)
            return (out != nil, pipeline.debugHasCaptureCPURenderer)
        }

        // NEGATIVE CONTROL: without the gate the disabled wall falls into CPU rendering.
        let control = try result(skipGate: true)
        XCTAssertTrue(control.produced && control.hasCPUPool,
                      "negative control vacuous: a disabled wall did not render on the CPU / retain a pool")
        // FIX: a disabled wall produces no frame and retains no CPU pool.
        let fixed = try result(skipGate: false)
        XCTAssertFalse(fixed.produced, "sol #4: a disabled video wall still produced a frame")
        XCTAssertFalse(fixed.hasCPUPool, "sol #4: a disabled video wall retained its CPU FXCanvas pool")
    }

    // MARK: sol #4 — setHDREnabled after shutdown must start no loop

    /// The `didShutdown` guard was added to the fail-safe RESUME, but the public
    /// `setHDREnabled` ENTRY could still build+start a fresh render loop after shutdown.
    /// A toggle after shutdown must be a no-op. Negative control: bypass the entry guard
    /// and the toggle resurrects a render loop.
    func testSetHDREnabledAfterShutdownStartsNoLoop() async throws {
        func loopReplaced(bypass: Bool) async throws -> Bool {
            let engine = AppEngine()
            guard let old = engine.renderLoop else { await engine.shutdown(); throw XCTSkip("no render loop") }
            await engine.shutdown()
            AppEngine._test_bypassHDRShutdownGuard = bypass
            defer { AppEngine._test_bypassHDRShutdownGuard = false }
            engine.setHDREnabled(true)
            try await Task.sleep(nanoseconds: 200_000_000)
            let replaced = engine.renderLoop !== old
            if replaced { _ = engine.renderLoop?.stop() }   // join any resurrected render thread
            return replaced
        }
        // NEGATIVE CONTROL: bypass the guard → the post-shutdown toggle builds a new loop.
        let control = try await loopReplaced(bypass: true)
        XCTAssertTrue(control, "negative control vacuous: bypassing the shutdown guard built no new loop")
        // FIX: the entry guard makes a post-shutdown toggle a no-op.
        let fixed = try await loopReplaced(bypass: false)
        XCTAssertFalse(fixed, "sol #4: setHDREnabled after shutdown built/started a new render loop (resurrection)")
    }

    // MARK: sol #4 — cueGenerations keys must not leak monotonically

    /// Every removed meme created/incremented a per-source cue-generation key that was
    /// never reclaimed (shutdown only bumped), so the dict grew for the app's lifetime.
    /// `removeMeme` must reclaim the key and shutdown must clear the dict.
    func testCueGenerationKeysDoNotLeak() async throws {
        let engine = AppEngine()
        let gif = try makeAnimatedGIF(colors: [(1,0,0),(0,1,0)], delay: 0.1, side: 16)
        XCTAssertEqual(engine.integrationDebugCueGenerationKeyCount, 0)
        let n = 6
        for _ in 0..<n {
            engine.addMeme(url: gif, mode: .insert, placement: .lowerThird, holdSec: 0.3, isBuiltIn: true)
            let item = try XCTUnwrap(engine.memeItems.last)
            engine.triggerMeme(id: item.id)      // creates/bumps this source's key
            engine.removeMeme(id: item.id)        // must reclaim it
        }
        // Pre-fix this would retain N keys; the fix reclaims each on remove (allow ≤1 for a
        // single possibly-in-flight cycle).
        XCTAssertLessThanOrEqual(engine.integrationDebugCueGenerationKeyCount, 1,
            "sol #4: cueGenerations retained \(engine.integrationDebugCueGenerationKeyCount) keys after \(n) add/remove cycles (leak)")
        await engine.shutdown()
        XCTAssertEqual(engine.integrationDebugCueGenerationKeyCount, 0,
                       "sol #4: shutdown did not clear the cue-generation dict")
    }

    // MARK: sol #4 — high-fps meme: the first PRESENTED frame is frame 0

    /// A 120/240-fps source's free-run floods the mailbox with frames 1…N before the next
    /// render pull; the latest-wins mailbox then presents frame 1+. The fix presents EXACTLY
    /// frame 0 (posted alone) and holds the restart until the loop has pulled it. Driven
    /// through the REAL cue + gate helpers on a REAL RenderLoop + compositor, with an
    /// independent colour oracle (frame 0 is the only red frame in a 16-colour loop) — a
    /// 50 fps source against a 30 fps loop genuinely opens the race (not a 40 ms GIF).
    /// Negative control: pre-flood the source and restart immediately (no gate) → frame 1+.
    func testHighFpsMemeFirstPresentedFrameIsFrameZero() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        // 16 distinct frames at the 50 fps floor (0.02 s): only frame 0 is red; the loop
        // (320 ms) is longer than the tick window, so a free-run frame never wraps to red.
        var colors: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0)]
        for i in 1..<16 {
            let t = CGFloat(i) / 16.0
            colors.append((0.05, 0.3 + 0.6 * t, 0.9 - 0.5 * t))   // r < 0.1 → never red-dominant
        }
        let url = try makeAnimatedGIF(colors: colors, delay: 0.02, side: 64)
        let sid = SourceID("hifps.meme")

        func firstPresentedIsRed(gated: Bool) throws -> Bool {
            let compositor = try MetalCompositor(device: device, width: 64, height: 64)
            let loop = RenderLoop(compositor: compositor, fps: 30)
            let source = try AnimatedGIFSource(fileURL: url, canvasSize: CanvasSize(width: 64, height: 64),
                                               contentMode: .aspectFill, loop: true)
            let mailbox = FrameMailbox()
            source.onFrame = { [mailbox] in mailbox.post($0) }
            loop.scene = Scene(name: "s", layers: [Layer(sourceID: sid)])
            loop.setMailbox(mailbox, for: sid)
            defer { _ = loop.stop(); source.stop() }

            // Cue to frame zero (loop not yet running, so the cue's posts aren't pulled).
            let (landed, frameZero) = AppEngine.cueAnimatedSourceCapturingFrameZero(source, mailbox: mailbox)
            XCTAssertTrue(landed, "cue never landed frame zero")
            let frame0 = try XCTUnwrap(frameZero)

            let captured = OSAllocatedUnfairLock<VideoFrame?>(initialState: nil)
            loop.onTickSnapshot = { tick in
                guard let f = tick.frames[sid] else { return }
                captured.withLock { if $0 == nil { $0 = f } }
            }

            if gated {
                // FIX: leave EXACTLY frame 0 resident and GATE the restart on the loop
                // presenting it.
                loop.removeMailbox(for: sid)
                _ = mailbox.takeNewest()
                mailbox.post(frame0)
                loop.setMailbox(mailbox, for: sid)
                let ticksBefore = loop.stats.ticks
                loop.start()
                AppEngine.resumeMemeSourceAfterFrameZeroPresented(
                    source, loop: loop, ticksBefore: ticksBefore, gated: true,
                    isSuperseded: { false }, finalizeOnMain: { _ in }, onError: { _ in })
            } else {
                // NEGATIVE CONTROL: restart immediately (no gate) and let the source free-run
                // BEFORE the first pull, flooding the mailbox — the latest-wins take then
                // presents a post-zero frame.
                try source.start()
                Thread.sleep(forTimeInterval: 0.15)   // ~7 frames free-run into the mailbox
                loop.start()
            }

            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while captured.withLock({ $0 == nil }), ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            let frame = try XCTUnwrap(captured.withLock { $0 }, "meme never appeared in a composited tick")
            return centerIsRed(frame)
        }

        // NEGATIVE CONTROL: a high-fps free-run presents a post-zero (non-red) frame first.
        XCTAssertFalse(try firstPresentedIsRed(gated: false),
                       "negative control vacuous: the free-run source still presented frame 0 (red) first")
        // FIX: the gate presents frame 0 (red) first even for the high-fps source.
        XCTAssertTrue(try firstPresentedIsRed(gated: true),
                      "sol #4: the first presented frame was not frame 0 (red) for a high-fps source")
    }

    // MARK: - Helpers

    /// Center-pixel red-dominance of a BGRA frame (frame 0's colour in the hi-fps test).
    private func centerIsRed(_ frame: VideoFrame) -> Bool {
        let pb = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return false }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        let o = (h / 2) * bpr + (w / 2) * 4    // BGRA
        let b = Int(p[o]), g = Int(p[o + 1]), r = Int(p[o + 2])
        return r > 140 && g < 110 && b < 110
    }

    private func pollUntil(_ timeout: TimeInterval, _ cond: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !cond(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(cond(), "condition not met within \(timeout)s")
    }

    /// Bounding box (in pixels) of the strongly-green region of a BGRA buffer.
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
                let b = Int(p[o]), g = Int(p[o + 1]), r = Int(p[o + 2])
                if g > 140 && r < 110 && b < 110 {     // green-dominant
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return (w: maxX - minX + 1, h: maxY - minY + 1)
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

    private func makeAnimatedGIF(colors: [(CGFloat, CGFloat, CGFloat)], delay: Double, side: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meme.\(UUID().uuidString).gif")
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, colors.count, nil) else {
            throw XCTSkip("could not create GIF destination")
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        for (r, g, b) in colors {
            let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let img = ctx.makeImage()!
            CGImageDestinationAddImage(dest, img, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                kCGImagePropertyGIFUnclampedDelayTime: delay]
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("could not finalize GIF fixture") }
        return url
    }

    /// A rectangular animated GIF with `frames` solid frames at `w`×`h` — lets the
    /// F15 eviction fixture reach a large per-source decode footprint (1280×720 ×
    /// N frames) with the fewest frames.
    private func makeAnimatedGIFRect(w: Int, h: Int, frames: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wide.\(UUID().uuidString).gif")
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
            throw XCTSkip("could not create GIF destination")
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        for i in 0..<frames {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let f = CGFloat(i % 8) / 8.0
            ctx.setFillColor(CGColor(red: f, green: 1 - f, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let img = ctx.makeImage()!
            CGImageDestinationAddImage(dest, img, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("could not finalize GIF fixture") }
        return url
    }

    private func writeTransparentProRes4444(w: Int, h: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alpha.\(UUID().uuidString).mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            throw XCTSkip("no AVAssetWriter")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            ])
        guard writer.canAdd(input) else { throw XCTSkip("ProRes 4444 unavailable") }
        writer.add(input)
        guard writer.startWriting() else { throw XCTSkip("writer refused to start") }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<2 {
            var pbOut: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess,
                  let pb = pbOut else { throw XCTSkip("no pool") }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let bpr = CVPixelBufferGetBytesPerRow(pb)
                let ptr = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<h {
                    for x in 0..<w {
                        let inside = x >= 16 && x < 48 && y >= 16 && y < 48
                        let p = ptr + y * bpr + x * 4
                        if inside { p[0]=40; p[1]=40; p[2]=220; p[3]=255 } else { p[0]=0; p[1]=0; p[2]=0; p[3]=0 }
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        let done = XCTestExpectation(description: "write")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 10)
        guard writer.status == .completed else { throw XCTSkip("prores write failed") }
        return url
    }
}
