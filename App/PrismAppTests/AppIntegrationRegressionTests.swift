import CoreGraphics
import CoreMedia
import CoreVideo
import os
import XCTest

import PrismCompose
import PrismCompositor
import PrismCore
import PrismSources
@testable import Prism

@MainActor
final class AppIntegrationRegressionTests: XCTestCase {
    /// F6: prepared auxiliary media and the active provider both survive the
    /// destructive-mailbox-safe SDR→HDR render-loop replacement.
    func testHDRRebuildPreservesPreparedMemesAndSceneProvider() async {
        let engine = AppEngine()
        engine.prepareMemes()
        engine.addTextSource(text: "HDR integration probe")

        guard let baseID = engine.activeSources.first(where: \.isVideo)?.id,
              let insert = engine.memeItems.first(where: { $0.mode == .insert }) else {
            await engine.shutdown()
            return XCTFail("camera-free generated sources/meme templates were not prepared")
        }
        engine.setLayerMotion(.float, speed: 1, for: baseID)
        engine.setVerticalEnabled(true)
        engine.triggerMeme(id: insert.id)

        let oldLoop = engine.renderLoop
        let auxiliaryBefore = engine.integrationDebugAuxiliarySourceIDs
        XCTAssertTrue(auxiliaryBefore.contains(insert.sourceID))
        XCTAssertNotNil(oldLoop?.sceneProvider)

        engine.setHDREnabled(true)

        XCTAssertTrue(engine.hdrEnabled, engine.lastError ?? "HDR rebuild did not complete")
        XCTAssertFalse(oldLoop === engine.renderLoop)
        XCTAssertEqual(engine.integrationDebugAuxiliarySourceIDs, auxiliaryBefore)
        XCTAssertTrue(engine.renderLoop?.registeredSourceIDs.isSuperset(of: auxiliaryBefore) == true,
                      "replacement RenderLoop did not receive every auxiliary mailbox")
        XCTAssertNotNil(engine.renderLoop?.sceneProvider,
                        "meme/LayerMotion provider was not reinstalled on the replacement loop")
        if let provider = engine.renderLoop?.sceneProvider {
            let t0 = HouseClock.now()
            let first = provider(t0)
            let second = provider(CMTimeAdd(t0, CMTime(seconds: 0.08,
                                                       preferredTimescale: 600)))
            XCTAssertTrue(first.layers.contains { $0.sourceID == insert.sourceID },
                          "active meme was absent from the reinstalled provider")
            XCTAssertNotEqual(first.layers.first { $0.sourceID == baseID }?.frame,
                              second.layers.first { $0.sourceID == baseID }?.frame,
                              "LayerMotion stopped across the HDR loop replacement")
        }
        let verticalDeadline = Date().addingTimeInterval(1.5)
        while Date() < verticalDeadline {
            let snapshot = engine.integrationDebugVerticalSnapshot
            if snapshot.frames[insert.sourceID] != nil,
               snapshot.scene?.layers.contains(where: { $0.sourceID == insert.sourceID }) == true {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let vertical = engine.integrationDebugVerticalSnapshot
        XCTAssertNotNil(vertical.frames[insert.sourceID],
                        "exact primary tick never routed the prepared meme frame to 9:16")
        XCTAssertTrue(vertical.scene?.layers.contains { $0.sourceID == insert.sourceID } == true,
                      "exact primary tick never routed the evaluated meme scene to 9:16")
        await engine.shutdown()
    }

    /// F7: exercise the exact shutdown helper with a started wrapper, then prove
    /// stop was invoked, both stores emptied, and the wrapper graph deallocated.
    func testCutoutShutdownStopsClearsAndReleasesWrapper() async throws {
        let engine = AppEngine()
        let upstream = ManualVideoSource(id: SourceID("cutout.shutdown.upstream"))
        var wrapper: PresenterCutoutSource? = PresenterCutoutSource(
            id: SourceID("cutout.shutdown.wrapper"), wrapping: upstream)
        let callbacks = OSAllocatedUnfairLock<Int>(initialState: 0)
        wrapper?.onFrame = { _ in callbacks.withLock { $0 += 1 } }
        try wrapper?.start()
        weak var weakWrapper = wrapper

        let key = upstream.id
        engine.integrationDebugInstallCutout(wrapper!, state: CutoutState(), for: key)
        upstream.emit(try makeFrame(source: key)) // may be in Vision when shutdown lands
        wrapper = nil

        await engine.shutdown()
        let callbacksAtReturn = callbacks.withLock { $0 }
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(upstream.stopCount, 1)
        XCTAssertEqual(engine.integrationDebugCutoutCounts.sources, 0)
        XCTAssertEqual(engine.integrationDebugCutoutCounts.states, 0)
        XCTAssertEqual(callbacks.withLock { $0 }, callbacksAtReturn,
                       "cutout delivered a callback after AppEngine.shutdown returned")
        XCTAssertNil(weakWrapper, "cutout wrapper retained its upstream/sink graph after shutdown")
    }

    /// F8: the vertical tick contains the auxiliary frame and the exact scene
    /// produced by MemeDirector; hero-fill preserves the base hero while the
    /// lower-third remains a placed overlay rather than becoming full-screen.
    func testVerticalSnapshotIncludesMemeSceneAndCorrectInsertReframe() throws {
        let baseID = SourceID("vertical.base")
        let memeID = SourceID("vertical.meme")
        let base = Scene(name: "base", layers: [Layer(sourceID: baseID)])
        let item = MemeItem(name: "insert", mediaURL: URL(fileURLWithPath: "/dev/null"),
                            sourceID: memeID, mode: .insert, holdSec: 1,
                            placement: .lowerThird)
        let director = MemeDirector()
        director.trigger(item, at: 10)
        let evaluated = director.program(at: 10.25, base: base)
        let map = AppEngine.verticalReframeMap(
            evaluatedScene: evaluated,
            restingScene: base,
            mode: .heroFill,
            pinnedHero: nil,
            auxiliaryFrames: [memeID: item.placement.frame])

        let tap = LatestFrameTap()
        tap.enabled = true
        let frame = try makeFrame(source: memeID)
        tap.updateExactTick(frames: [memeID: frame], scene: evaluated, reframe: map)
        let tick = tap.snapshot()

        XCTAssertEqual(tick.frames[memeID]?.source, memeID)
        XCTAssertEqual(tick.scene?.layers.map(\.sourceID), [baseID, memeID])
        guard let scene = tick.scene, let reframe = tick.reframe else {
            return XCTFail("dynamic vertical scene/reframe missing from tick")
        }
        let vertical = VerticalScene(from: scene, using: reframe)
        XCTAssertEqual(Set(vertical.layers.map(\.sourceID)), Set([baseID, memeID]))
        XCTAssertEqual(vertical.layers.first(where: { $0.sourceID == baseID })?.frame,
                       CGRect(x: 0, y: 0, width: 1, height: 1))
        // F24 (vertical): the meme's 16:9 content must be aspect-PRESERVED on the
        // 9:16 vertical canvas, NOT stretched to the raw lower-third slot (which
        // distorts it). Assert the placed rect's PIXEL aspect on 1080×1920 is 16:9
        // — this test previously (wrongly) EXPECTED the raw distorting slot.
        let mframe = try XCTUnwrap(vertical.layers.first(where: { $0.sourceID == memeID })?.frame)
        let pixelAspect = Double(mframe.width) * 1080 / (Double(mframe.height) * 1920)
        XCTAssertEqual(pixelAspect, 16.0 / 9.0, accuracy: 0.05,
                       "vertical meme aspect distorted — a 16:9 meme was stretched into the 9:16 slot (F24)")
        XCTAssertNotEqual(mframe, MemePlacement.lowerThird.frame,
                          "vertical meme used the raw slot verbatim → distorted aspect (F24 vertical)")
    }

    /// F9: the live schedule really changes A→B at its cue and leaves only the
    /// stinger overlay in the primary outgoing stack after that point.
    func testLiveStingerCueEvaluatorSwitchesTargetScene() {
        let a = SourceID("stinger.A")
        let b = SourceID("stinger.B")
        let media = SourceID("stinger.media")
        let outgoing = Scene(name: "A", layers: [Layer(sourceID: a)])
        let incoming = Scene(name: "B", layers: [Layer(sourceID: b)])
        let item = MemeItem(name: "sting", mediaURL: URL(fileURLWithPath: "/dev/null"),
                            sourceID: media, mode: .stinger, holdSec: 1,
                            placement: .fullscreen)
        let schedule = AppEngine.liveStingerSchedule(item: item,
                                                     outgoing: outgoing,
                                                     incoming: incoming)
        XCTAssertEqual(schedule.blend, .crossfade)
        XCTAssertEqual(schedule.progress(0.25), 0)
        XCTAssertEqual(schedule.progress(0.75), 1)
        XCTAssertEqual(schedule.outgoingScene?(0.25).layers.map(\.sourceID), [a, media])
        XCTAssertEqual(schedule.incomingScene?(0.75).layers.map(\.sourceID), [b, media])

        let before = AppEngine.evaluateLiveStinger(item: item, outgoing: outgoing,
                                                   incoming: incoming, elapsed: 0.25,
                                                   duration: 1)
        XCTAssertEqual(before.outgoingScene.layers.map(\.sourceID), [a, media])
        XCTAssertEqual(before.incomingScene.layers.map(\.sourceID), [b, media])
        XCTAssertEqual(before.evaluatedProgram.layers.map(\.sourceID), [a, media])

        let cue = AppEngine.evaluateLiveStinger(item: item, outgoing: outgoing,
                                                incoming: incoming, elapsed: 0.5,
                                                duration: 1)
        XCTAssertEqual(cue.outgoingScene.layers.map(\.sourceID), [a, media])
        XCTAssertEqual(cue.incomingScene.layers.map(\.sourceID), [b, media])
        XCTAssertEqual(cue.evaluatedProgram.layers.map(\.sourceID), [b, media])
        XCTAssertEqual(cue.incomingScene.layers.last?.opacity ?? -1, 1, accuracy: 0.0001)

        let after = AppEngine.evaluateLiveStinger(item: item, outgoing: outgoing,
                                                  incoming: incoming, elapsed: 0.75,
                                                  duration: 1)
        XCTAssertEqual(after.outgoingScene.layers.map(\.sourceID), [a, media])
        XCTAssertEqual(after.incomingScene.layers.map(\.sourceID), [b, media])
        XCTAssertEqual(after.evaluatedProgram.layers.map(\.sourceID), [b, media])
        XCTAssertLessThan(after.incomingScene.layers.last?.opacity ?? 1, 1)
    }

    func testStingerTileArmsAndSceneSwitchConsumesLiveTransition() async {
        let engine = AppEngine()
        engine.prepareMemes()
        guard let item = engine.memeItems.first(where: { $0.mode == .stinger }),
              let loop = engine.renderLoop else {
            await engine.shutdown()
            return XCTFail("built-in stinger/render loop unavailable")
        }
        let completedBefore = loop.stats.transitionsCompleted
        engine.triggerMeme(id: item.id)
        XCTAssertEqual(engine.armedStingerMemeID, item.id)

        engine.applyPreset(.pipCorner)
        XCTAssertNil(engine.armedStingerMemeID, "scene switch did not consume one-shot arm")
        XCTAssertEqual(engine.integrationDebugActiveStingerSourceID, item.sourceID)

        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline,
              loop.stats.transitionsCompleted == completedBefore {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThan(loop.stats.transitionsCompleted, completedBefore)
        // Completion hops back to the main actor to release the active token.
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(engine.integrationDebugActiveStingerSourceID)
        await engine.shutdown()
    }

    /// N1: when the old render loop fails to QUIESCE during an HDR toggle, the swap
    /// aborts as the HIGH-5 fail-safe (no double-run) — but preview must KEEP
    /// RUNNING. The regression left the old loop stopped with its provider torn
    /// down, so preview froze forever once the wedged pass exited. This forces a
    /// real stop() timeout (wedged frame processor) and asserts the old loop is
    /// restored to a running state, provider + mailboxes intact, frames flowing.
    /// It is its own negative control: neutralize the recovery (leave the old loop
    /// stopped) and the final "frames flow again" assertion goes red.
    func testFailedHDRQuiesceResumesOldLoopNotFrozen() async throws {
        let engine = AppEngine()
        guard let old = engine.renderLoop else {
            await engine.shutdown(); throw XCTSkip("no render loop (no Metal device)")
        }
        engine.addTextSource(text: "N1 quiesce probe")
        guard let sourceID = engine.activeSources.first?.id else {
            await engine.shutdown(); return XCTFail("no source registered")
        }
        engine.setLayerMotion(.float, speed: 1, for: sourceID)  // installs a scene provider
        XCTAssertNotNil(old.sceneProvider, "layer motion did not install a provider")
        let registeredBefore = old.registeredSourceIDs

        // Wedge the old render thread INSIDE its frame processor, past stop()'s 2 s
        // quiesce budget, so setHDREnabled's `stop()` returns false.
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let blockedOnce = OSAllocatedUnfairLock(initialState: false)
        old.frameProcessor = { frames, _ in
            let first = blockedOnce.withLock { done -> Bool in
                if done { return false }; done = true; return true
            }
            if first { entered.signal(); release.wait() }
            return frames
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success,
                       "render thread never entered the wedge")

        engine.setHDREnabled(true)  // blocks ~2 s on the stop() timeout, then fails safe
        XCTAssertFalse(engine.hdrEnabled, "HDR swap should have aborted on the failed quiesce")
        XCTAssertTrue(engine.renderLoop === old, "old loop pointer not restored on the fail-safe path")
        XCTAssertNotNil(engine.renderLoop?.sceneProvider,
                        "the old loop's scene provider was torn down on a failed quiesce (N1)")
        XCTAssertEqual(engine.renderLoop?.registeredSourceIDs, registeredBefore,
                       "the old loop's mailboxes were torn down on a failed quiesce (N1)")

        // Let the wedged pass exit; the recovery must RESTART the old loop so frames
        // keep FLOWING. Require SUSTAINED delivery: the wedged tick itself delivers
        // exactly one trailing frame as it exits, so a single increment is NOT proof
        // of resumption — only a genuinely running loop reaches a healthy margin.
        release.signal()
        let before = old.stats.framesDelivered
        let target = before + 20
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while old.stats.framesDelivered < target,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThanOrEqual(old.stats.framesDelivered, target,
                                    "preview stayed frozen after the failed HDR quiesce — old loop never resumed with frames flowing (N1)")
        await engine.shutdown()
    }

    /// sol #3 (HIGH): the HDR fail-safe schedules `resumeRenderLoopAfterFailedQuiesce`
    /// retries via `DispatchQueue.main.asyncAfter`. If `shutdown()` runs in that window,
    /// a queued retry must NEVER `start()` the loop — shutdown stopped every source, tore
    /// down the pipelines, and issued `renderLoop.stop()`, so spawning a render thread now
    /// runs over TORN-DOWN state (a resurrection). `shutdown()` leaves the `renderLoop`
    /// pointer intact (=== old), so the resume's `renderLoop === loop` guard passes and
    /// ONLY `didShutdown` protects us. Assert NO render thread starts after shutdown; the
    /// NEGATIVE CONTROL bypasses only the didShutdown guard and the very same retry then
    /// resurrects the loop (frames climb), proving the guard is load-bearing.
    func testResumeRetryAfterShutdownDoesNotResurrectRenderThread() async throws {
        let engine = AppEngine()
        guard let old = engine.renderLoop else {
            await engine.shutdown(); throw XCTSkip("no render loop (no Metal device)")
        }
        engine.addTextSource(text: "resume-after-shutdown probe")
        guard let sourceID = engine.activeSources.first?.id else {
            await engine.shutdown(); return XCTFail("no source registered")
        }
        engine.setLayerMotion(.float, speed: 1, for: sourceID)   // installs a scene provider

        await engine.shutdown()
        XCTAssertTrue(engine.renderLoop === old, "shutdown unexpectedly replaced the render loop")

        // Simulate the queued fail-safe retry firing AFTER shutdown completed.
        AppEngine._test_bypassShutdownResumeGuard = false
        let before = old.stats.framesDelivered
        engine._test_resumeRenderLoopAfterFailedQuiesce(old)
        try await Task.sleep(nanoseconds: 300_000_000)   // ample time for a thread to spin up
        XCTAssertEqual(old.stats.framesDelivered, before,
                       "a render thread was resurrected AFTER shutdown (sol #3) — frames delivered over torn-down state")

        // NEGATIVE CONTROL: neutralize ONLY the didShutdown guard → the identical retry now
        // starts a render thread over the torn-down state (frames climb).
        AppEngine._test_bypassShutdownResumeGuard = true
        defer { AppEngine._test_bypassShutdownResumeGuard = false }
        let ncBefore = old.stats.framesDelivered
        engine._test_resumeRenderLoopAfterFailedQuiesce(old)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while old.stats.framesDelivered <= ncBefore + 5,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThan(old.stats.framesDelivered, ncBefore + 5,
                             "negative control vacuous: bypassing the didShutdown guard did NOT resurrect the loop")
        _ = old.stop()   // join the resurrected thread so it doesn't outlive the test
    }

    /// sol #4 (regression): two overlapping failed-quiesce attempts create two retry chains.
    /// After the thread drains, one chain restarts the loop; the other then sees `start()`
    /// refused BECAUSE the loop is already running and — pre-fix — reads that as "still
    /// draining" and retries every 100 ms FOREVER. Firing a resume on an already-RUNNING
    /// loop simulates "a chain firing after another already recovered it": it must terminate
    /// at once (running = success), not retry unboundedly. Negative control bypasses ONLY
    /// the running check → the identical resume retries without bound.
    func testOverlappingFailedQuiesceDoesNotRetryForever() async throws {
        let engine = AppEngine()
        guard let old = engine.renderLoop else { await engine.shutdown(); throw XCTSkip("no render loop") }

        func attempts(bypassRunningCheck: Bool) async throws -> Int {
            engine._test_resumeRetryAttempts = 0   // per-engine counter: immune to other engines' chains
            AppEngine._test_bypassResumeRunningCheck = bypassRunningCheck
            defer { AppEngine._test_bypassResumeRunningCheck = false }
            // Two overlapping resume requests for the SAME (running) loop.
            engine._test_resumeRenderLoopAfterFailedQuiesce(old)
            engine._test_resumeRenderLoopAfterFailedQuiesce(old)
            try await Task.sleep(nanoseconds: 600_000_000)   // 6 × the 100 ms retry period
            return engine._test_resumeRetryAttempts
        }

        // FIX: a running loop terminates the retry immediately (bounded, both chains coalesced).
        let fixed = try await attempts(bypassRunningCheck: false)
        XCTAssertLessThanOrEqual(fixed, 3,
            "sol #4: the resume retried \(fixed) times on an already-running loop (should terminate at once)")
        // NEGATIVE CONTROL: without the running check the chain retries every 100 ms unbounded.
        let control = try await attempts(bypassRunningCheck: true)
        XCTAssertGreaterThan(control, 4,
            "negative control vacuous: without the running check the resume still terminated")
        await engine.shutdown()
    }

    private func makeFrame(source: SourceID) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: 16, height: 16,
                                       pixelFormat: kCVPixelFormatType_32BGRA)
        return VideoFrame(pixelBuffer: try pool.makeBuffer(), pts: HouseClock.now(), source: source)
    }
}

private final class ManualVideoSource: VideoSource {
    let id: SourceID
    var state: SourceState = .idle
    var onFrame: ((VideoFrame) -> Void)?
    private(set) var stopCount = 0

    init(id: SourceID) { self.id = id }

    func start() throws { state = .running }
    func emit(_ frame: VideoFrame) {
        guard state == .running else { return }
        onFrame?(frame)
    }
    func stop() {
        stopCount += 1
        state = .idle
        onFrame = nil
    }
}
