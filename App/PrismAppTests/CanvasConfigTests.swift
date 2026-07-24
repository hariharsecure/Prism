import XCTest
import CoreMedia
import PrismCore
import PrismExport
import PrismOutput
@testable import Prism

/// THE FEATURE (Roadmap 3b): the program canvas was hard-locked to 1920×1080 @
/// 60 fps — a `static let canvasSize`, a `RenderLoop(fps: 60)`, and a hardcoded
/// status string. `CanvasConfig` makes it a persisted resolution + framerate
/// choice (default 1080p60, unchanged out of the box) that propagates to every
/// consumer — the compositor render target, the render-loop cadence, the
/// record/stream encoders, and (via the composited program frame) the virtual
/// camera — with the picker guarded off-air so a live recording can't corrupt.
///
/// These tests exercise the PURE config plumbing (values the consumers read),
/// persistence round-trip, the status string, and the on-air guard — NOT a live
/// GPU. One test additionally starts a real program recorder to prove the
/// encoder is configured from the chosen canvas.
@MainActor
final class CanvasConfigTests: XCTestCase {

    // Stable persistence keys (mirror SettingsPersistence.PersistKey, which is
    // private). Cleared around the persistence tests so a developer's saved canvas
    // can't leak in — and restored to the default afterwards.
    private let resKey = "studio.prism.canvas.resolution"
    private let fpsKey = "studio.prism.canvas.fps"

    override func tearDown() {
        // Leave UserDefaults on the shipping default so later tests / the app see 1080p60.
        AppEngine.persistCanvasConfig(.default)
        super.tearDown()
    }

    // MARK: Preset values (what every consumer reads)

    /// Each resolution preset maps to the intended 16:9 pixel dimensions. All
    /// presets are 16:9 — the invariant that keeps the remaining aspect-only
    /// `canvasSize` references correct across a resolution change.
    func testPresetDimensionsAre16by9() {
        let expected: [CanvasConfig.Resolution: (Int, Int)] = [
            .r720:  (1280, 720),
            .r900:  (1600, 900),
            .r1080: (1920, 1080),
            .r1440: (2560, 1440),
            .r2160: (3840, 2160),
        ]
        for res in CanvasConfig.Resolution.allCases {
            let (w, h) = expected[res]!
            XCTAssertEqual(res.width, w, "\(res) width")
            XCTAssertEqual(res.height, h, "\(res) height")
            XCTAssertEqual(Double(res.width) / Double(res.height), 16.0 / 9.0, accuracy: 0.0001,
                           "\(res) must be 16:9 so aspect-only canvasSize refs stay valid")
        }
    }

    /// Framerate presets are exactly 24 / 30 / 60.
    func testFrameRatePresets() {
        XCTAssertEqual(CanvasConfig.FrameRate.allCases.map(\.rawValue), [24, 30, 60])
    }

    /// The DEFAULT is 1080p60 — no behavior change out of the box.
    func testDefaultIs1080p60() {
        XCTAssertEqual(CanvasConfig.default.width, 1920)
        XCTAssertEqual(CanvasConfig.default.height, 1080)
        XCTAssertEqual(CanvasConfig.default.fps, 60)
    }

    // MARK: Status string (kills the hardcoded ContentView string)

    /// The status line is derived from the config — the single source of truth
    /// that replaced `Text("Program 1920×1080 · 60 fps")`.
    func testStatusLineReflectsCanvas() {
        XCTAssertEqual(CanvasConfig.default.statusLine, "Program 1920×1080 · 60 fps",
                       "default must reproduce the old hardcoded string exactly")
        let uhd = CanvasConfig(resolution: .r2160, frameRate: .fps24)
        XCTAssertEqual(uhd.statusLine, "Program 3840×2160 · 24 fps")
        let weak = CanvasConfig(resolution: .r900, frameRate: .fps30)
        XCTAssertEqual(weak.statusLine, "Program 1600×900 · 30 fps")
    }

    // MARK: Persistence round-trip

    /// A non-default canvas round-trips through UserDefaults (survives relaunch).
    func testPersistenceRoundTrip() {
        let chosen = CanvasConfig(resolution: .r1440, frameRate: .fps30)
        AppEngine.persistCanvasConfig(chosen)
        XCTAssertEqual(AppEngine.loadPersistedCanvasConfig(), chosen,
                       "persisted canvas must reload identically")

        let other = CanvasConfig(resolution: .r720, frameRate: .fps60)
        AppEngine.persistCanvasConfig(other)
        XCTAssertEqual(AppEngine.loadPersistedCanvasConfig(), other)
    }

    /// With nothing persisted, the load falls back to the shipping default.
    func testLoadFallsBackToDefaultWhenUnset() {
        UserDefaults.standard.removeObject(forKey: resKey)
        UserDefaults.standard.removeObject(forKey: fpsKey)
        XCTAssertEqual(AppEngine.loadPersistedCanvasConfig(), .default,
                       "no saved canvas → 1080p60 default")
    }

    // MARK: Engine propagation (config plumbing, not a live GPU)

    /// Setting a non-default canvas off-air updates the engine's `canvasConfig`,
    /// which is the single value the compositor / render-loop / encoders read,
    /// and persists it. Asserts the config plumbing, not rendered pixels.
    func testSetCanvasConfigUpdatesEngineAndPersists() {
        AppEngine.persistCanvasConfig(.default)
        let engine = AppEngine()
        XCTAssertTrue(engine.canChangeCanvas, "a fresh engine is off-air")

        let chosen = CanvasConfig(resolution: .r1440, frameRate: .fps30)
        engine.setCanvasConfig(chosen)

        XCTAssertEqual(engine.canvasConfig, chosen)
        XCTAssertEqual(engine.canvasConfig.width, 2560)
        XCTAssertEqual(engine.canvasConfig.height, 1440)
        XCTAssertEqual(engine.canvasConfig.fps, 30)
        XCTAssertEqual(engine.canvasConfig.statusLine, "Program 2560×1440 · 30 fps")
        XCTAssertEqual(AppEngine.loadPersistedCanvasConfig(), chosen,
                       "the applied canvas is persisted for next launch")
    }

    /// A relaunch applies the persisted non-default canvas at construction (the
    /// engine loads it BEFORE building the first render loop).
    func testEngineAdoptsPersistedCanvasOnLaunch() {
        let saved = CanvasConfig(resolution: .r720, frameRate: .fps30)
        AppEngine.persistCanvasConfig(saved)
        let engine = AppEngine()
        XCTAssertEqual(engine.canvasConfig, saved,
                       "engine must adopt the persisted canvas at launch")
    }

    /// The program recorder's encoder is sized from the chosen canvas — proves the
    /// non-default preset reaches the value the encoder actually reads.
    func testRecorderEncoderUsesConfiguredCanvas() async throws {
        AppEngine.persistCanvasConfig(.default)
        let engine = AppEngine()
        try XCTSkipIf(engine.engineFault != nil, "no Metal — can't exercise the recorder")

        engine.setCanvasConfig(CanvasConfig(resolution: .r1440, frameRate: .fps30))
        try engine.startRecording()
        defer { Task { _ = await engine.stopRecording() } }

        let settings = engine._test_programRecorderSettings
        XCTAssertEqual(settings?.width, 2560, "recorder encoder width follows the canvas")
        XCTAssertEqual(settings?.height, 1440, "recorder encoder height follows the canvas")

        _ = await engine.stopRecording()
    }

    /// REPRODUCE-FIRST (Phase 3a Stage 1 follow-up): a canvas resolution change must
    /// rebuild the studio-mode PREVIEW compositor at the NEW size, not just the primary
    /// render loop. Before the fix `setCanvasConfig` rebuilt only the primary, so the
    /// preview program kept compositing at the OLD dimensions after a resolution change.
    func testSetCanvasConfigRebuildsPreviewAtNewSize() throws {
        AppEngine.persistCanvasConfig(.default)
        let engine = AppEngine()
        try XCTSkipIf(engine.previewProgramSize == nil, "no preview program (Metal unavailable)")

        // Starts at the 1080p default.
        XCTAssertEqual(engine.previewProgramSize?.width, 1920)
        XCTAssertEqual(engine.previewProgramSize?.height, 1080)

        engine.setCanvasConfig(CanvasConfig(resolution: .r1440, frameRate: .fps30))

        XCTAssertEqual(engine.previewProgramSize?.width, 2560,
                       "preview compositor width must follow the canvas change")
        XCTAssertEqual(engine.previewProgramSize?.height, 1440,
                       "preview compositor height must follow the canvas change")

        // A second change (down to 720p) also propagates — no stale dimensions.
        engine.setCanvasConfig(CanvasConfig(resolution: .r720, frameRate: .fps60))
        XCTAssertEqual(engine.previewProgramSize?.width, 1280)
        XCTAssertEqual(engine.previewProgramSize?.height, 720)
    }

    /// The preview-program rebuild preserves color mode: a canvas change made while
    /// HDR is on must rebuild the preview in HDR (not silently drop to SDR), mirroring
    /// the primary's `hdrEnabled ? .hdr : .sdr` parity.
    func testSetCanvasConfigPreservesPreviewColorMode() throws {
        AppEngine.persistCanvasConfig(.default)
        let engine = AppEngine()
        try XCTSkipIf(engine.previewProgramColorMode == nil, "no preview program (Metal unavailable)")

        let modeBefore = engine.previewProgramColorMode
        engine.setCanvasConfig(CanvasConfig(resolution: .r1440, frameRate: .fps30))
        XCTAssertEqual(engine.previewProgramColorMode, modeBefore,
                       "canvas change must keep the preview in the current color mode")
    }

    // MARK: On-air guard

    /// Changing the canvas is refused while an output is on-air — the picker is
    /// disabled AND `setCanvasConfig` re-checks the guard so the config can't
    /// change out from under a live, fixed-dimension encoder.
    func testCanvasChangeBlockedWhileOnAir() {
        AppEngine.persistCanvasConfig(.default)
        let engine = AppEngine()
        XCTAssertTrue(engine.canChangeCanvas)

        // vcamOutputRequested flips synchronously (no hardware needed) → on-air.
        engine.setVirtualCameraOutput(true)
        XCTAssertFalse(engine.canChangeCanvas, "requesting the virtual camera makes the app on-air")

        let before = engine.canvasConfig
        engine.setCanvasConfig(CanvasConfig(resolution: .r2160, frameRate: .fps24))
        XCTAssertEqual(engine.canvasConfig, before, "canvas must NOT change while on-air")
        XCTAssertNotNil(engine.lastError, "the refusal surfaces an explanatory error")

        // Turning the output off re-enables the picker.
        engine.setVirtualCameraOutput(false)
        XCTAssertTrue(engine.canChangeCanvas)
    }

    // MARK: - #4 REGRESSION: the preview keeps RECEIVING ticks after a resize

    /// REGRESSION (shipped in 5cddc62): `setCanvasConfig` built the new render loop
    /// BEFORE swapping in the new preview program, so the loop's tick-snapshot closure
    /// captured the OLD preview instance by value; that old preview was then quiesced
    /// → the NEW preview received NO ticks and FROZE on its last pre-resize frame.
    /// Asserting only `previewProgramSize` (raster is correct) sailed right past it.
    ///
    /// This proves the fix at the behavior that actually matters: after the resize the
    /// preview program's frame SEQUENCE keeps ADVANCING (new frames keep arriving),
    /// not merely that the raster size is right. Pre-fix the sequence is frozen and
    /// this test fails; post-fix it advances.
    func testCanvasResizePreviewKeepsReceivingTicksNotJustCorrectSize() async throws {
        AppEngine.persistCanvasConfig(.default)
        let engine = AppEngine()
        guard engine.previewProgramSize != nil, engine.renderLoop != nil else {
            await engine.shutdown(); throw XCTSkip("no preview program / render loop (Metal unavailable)")
        }
        engine.addTextSource(text: "A")   // real content so the loop composites frames
        engine.studioMode = true          // gate the preview-submit path ON

        var lastSeen: UInt64 = 0
        func pump() { if let l = engine.previewProgramStore.latest(after: lastSeen) { lastSeen = l.sequence } }
        func advance(to target: UInt64, within seconds: Double) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                pump()
                if lastSeen >= target { return true }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return false
        }

        // Baseline: the preview delivers frames BEFORE the resize.
        guard await advance(to: 1, within: 3) else {
            await engine.shutdown()
            throw XCTSkip("preview never delivered a frame pre-resize (headless render idle)")
        }

        engine.setCanvasConfig(CanvasConfig(resolution: .r1440, frameRate: .fps30))
        XCTAssertEqual(engine.previewProgramSize?.width, 2560,
                       "raster follows the resize (necessary — but NOT sufficient: it passed even while frozen)")

        // Settle to a post-resize baseline (drain any single stale in-flight frame
        // from the quiesced old preview), then require the sequence to advance
        // BEYOND it — the frozen old preview cannot produce a continuing stream.
        try? await Task.sleep(nanoseconds: 150_000_000)
        pump()
        let base = lastSeen
        let advanced = await advance(to: base + 3, within: 3)
        XCTAssertTrue(advanced,
                      "#4: after the resize the NEW preview received no continuing ticks — it is FROZEN on its last pre-resize frame")
        await engine.shutdown()
    }

    // MARK: - #13: defer a canvas change while a transition is in flight

    /// #13 (minimal-safe): a canvas rebuild unconditionally cancels an in-flight
    /// scene/TAKE transition + any pending stinger cue. Rather than silently
    /// destroying the transition mid-flight, the change is DEFERRED — queued and
    /// re-applied from the transition-completion fence. Here: a TAKE transition is in
    /// flight, `setCanvasConfig` is refused-and-queued (canvas unchanged + surfaced),
    /// and completing the transition (leaving studio clears the guard + drains) then
    /// applies the queued change.
    func testCanvasChangeDeferredWhileTransitionInFlightThenAppliedOnCompletion() throws {
        AppEngine.persistCanvasConfig(.default)
        let engine = AppEngine()
        try XCTSkipIf(engine.renderLoop == nil, "no render loop (Metal unavailable)")
        engine.addTextSource(text: "A")
        guard let id = engine.lastAddedVideoSourceID else { throw XCTSkip("headless text add failed") }
        engine.setStingerMedia(nil)          // a plain compositor dissolve (no stinger cue)
        engine.setTransitionEnabled(true)
        engine.setTransitionKind(.dissolve)
        engine.setTransitionDuration(0.3)
        engine.studioMode = true
        engine.setLayerHidden(true, for: id) // off-air edit → a real preview≠program switch
        engine.take()                        // starts the transition
        XCTAssertTrue(engine._test_takeTransitionInFlight, "precondition: the TAKE transition is in flight")

        let before = engine.canvasConfig
        engine.setCanvasConfig(CanvasConfig(resolution: .r1440, frameRate: .fps30))
        XCTAssertEqual(engine.canvasConfig, before,
                       "#13: the canvas change must be DEFERRED (not applied) while a transition is in flight")
        XCTAssertEqual(engine.canvasConfig.width, 1920, "canvas unchanged during the transition")
        XCTAssertEqual(engine.lastError?.contains("deferred"), true, "#13: the deferral is surfaced to the operator")

        // Complete the transition: leaving studio clears the guard and drains the
        // queued change (the completion fence). The deferred resize now applies.
        engine.studioMode = false
        XCTAssertEqual(engine.canvasConfig.width, 2560,
                       "#13: the deferred canvas change applies once the transition completes")
        XCTAssertEqual(engine.canvasConfig.height, 1440)
    }

    // MARK: - #18: FCPXML export uses the RECORDED canvas, not the live one

    /// #18: the FCPXML export must declare the geometry the session was RECORDED at
    /// (snapshotted at record START), not whatever the live `canvasConfig` happens to
    /// be at export time. Repro: a session recorded at 1080p60, then the canvas is
    /// resized to 4K24, then exported → the FCPXML must still declare 1080p60.
    func testFCPXMLExportDeclaresRecordedCanvasNotLiveCanvas() throws {
        AppEngine.persistCanvasConfig(.default)
        let engine = AppEngine()

        // Simulate a finished multicam session recorded at 1080p60.
        let dir = FileManager.default.temporaryDirectory
        let report = MovieRecorder.Report(
            url: dir.appending(path: "program.mov"),
            duration: CMTime(seconds: 5, preferredTimescale: 600),
            bytesWritten: 4096, videoFramesWritten: 300, videoFramesDropped: 0,
            videoFramesRejectedForPTS: 0, audioBuffersWritten: 0, audioBuffersDropped: 0)
        let programID = SourceID("program")
        let session = FinishedMulticamSession(
            projectName: "RecordedAt1080p60",
            directory: dir,
            sessionStart: .zero,
            canvas: FinishedMulticamSession.CanvasSnapshot(width: 1920, height: 1080, fps: 60),
            programSource: programID,
            program: report,
            isoResults: [:],
            meta: [programID: FinishedMulticamSession.AngleMeta(
                name: "Program", width: 1920, height: 1080, fps: 60, hasAudio: false)])
        engine._test_setLastFinishedSession(session)

        // AFTER the recording, the operator resizes the live canvas to 4K24.
        engine.setCanvasConfig(CanvasConfig(resolution: .r2160, frameRate: .fps24))
        XCTAssertEqual(engine.canvasConfig.width, 3840, "precondition: the LIVE canvas is now 4K24")

        // The export must declare the RECORDED 1080p60, not the live 4K24.
        let multicam = try XCTUnwrap(engine._test_exportMulticamSession())
        XCTAssertEqual(multicam.width, 1920, "#18: FCPXML timeline width must be the RECORDED canvas")
        XCTAssertEqual(multicam.height, 1080, "#18: FCPXML timeline height must be the RECORDED canvas")
        XCTAssertEqual(multicam.frameRate.fps, 60, accuracy: 0.01, "#18: FCPXML cadence must be the RECORDED fps")
        XCTAssertEqual(multicam.program.width, 1920, "#18: program angle width must be the RECORDED canvas")
        XCTAssertEqual(multicam.program.height, 1080, "#18: program angle height must be the RECORDED canvas")
        XCTAssertEqual(multicam.program.fps, 60, accuracy: 0.01, "#18: program angle fps must be the RECORDED cadence")
    }

    // MARK: - #17 RESIDUAL (xfail): canvas-native sources are not rebuilt on resize

    /// #17 KNOWN RESIDUAL (documented in KNOWN_LIMITATIONS.md): canvas-native sources
    /// (text/image/gif/browser/movie/montage) capture their raster dimensions at
    /// CONSTRUCTION. `setCanvasConfig` rebuilds the render loop + preview program but
    /// NOT these sources, so after a resize they keep rendering at the OLD size and the
    /// compositor upscales them. This xfail LOCKS IN the residual — it flips GREEN the
    /// moment `setCanvasConfig` rebuilds canvas-native sources at the new size.
    func testCanvasResizeDoesNotRebuildNativeSourcesKnownResidual() throws {
        AppEngine.persistCanvasConfig(.default)
        let engine = AppEngine()
        engine.addTextSource(text: "A")
        guard let id = engine.lastAddedVideoSourceID else { throw XCTSkip("headless text add failed") }
        // Constructed at the 1080p default.
        XCTAssertEqual(engine._test_canvasNativeRasterSize(for: id)?.width, 1920,
                       "the text source rasters at the canvas size present at construction")

        engine.setCanvasConfig(CanvasConfig(resolution: .r2160, frameRate: .fps24))

        XCTExpectFailure("#17 residual: setCanvasConfig does not re-raster canvas-native sources at the new size (KNOWN_LIMITATIONS.md)") {
            // DESIRED post-fix invariant: the source re-rasters at the new canvas size.
            XCTAssertEqual(engine._test_canvasNativeRasterSize(for: id)?.width, 3840,
                           "#17 desired: a canvas resize should re-raster canvas-native sources at the new size")
        }
    }
}
