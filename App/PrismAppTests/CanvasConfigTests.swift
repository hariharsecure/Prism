import XCTest
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
}
