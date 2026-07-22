import Metal
import XCTest

import PrismCompositor
import PrismCore
@testable import Prism

/// Phase 3a — STUDIO MODE, STAGE 1: the App-side edit-routing seam.
///
/// Proves the write-indirection (`editScene`): when `studioMode` is ON a layer
/// edit targets `previewScene` and leaves the live `scene` untouched (off-air);
/// when OFF the exact same call mutates `scene` exactly as before (no regression);
/// and `take()` hard-cuts the preview onto the program.
///
/// Pixel-level isolation + deterministic hard-cut are proven at the mechanism
/// level in `PreviewProgramTests` (engine `swift test`); here we prove the state
/// routing that decides WHICH scene an edit lands on.
@MainActor
final class StudioModePreviewTests: XCTestCase {

    /// Build an engine with one text layer, or skip if Metal is unavailable.
    private func engineWithOneLayer() throws -> (AppEngine, SourceID) {
        let engine = AppEngine()
        guard engine.previewProgramColorMode != nil else {
            throw XCTSkip("no preview program (Metal unavailable)")
        }
        engine.addTextSource(text: "A")
        guard let id = engine.lastAddedVideoSourceID else {
            throw XCTSkip("text source could not be added headlessly")
        }
        XCTAssertTrue(engine.scene.layers.contains { $0.sourceID == id }, "seed layer must exist on the program scene")
        return (engine, id)
    }

    private func isHidden(_ scene: ProgramScene, _ id: SourceID) -> Bool? {
        scene.layers.first { $0.sourceID == id }?.isHidden
    }

    // MARK: - Default OFF → no regression

    func testStudioModeDefaultsOff() throws {
        let (engine, _) = try engineWithOneLayer()
        XCTAssertFalse(engine.studioMode, "studio mode must default OFF")
    }

    /// REGRESSION: with studio mode OFF a layer edit applies to the PROGRAM scene
    /// exactly as before — the non-studio path is unchanged.
    func testEditWithStudioOffAppliesToProgram() throws {
        let (engine, id) = try engineWithOneLayer()
        XCTAssertEqual(isHidden(engine.scene, id), false, "layer starts visible")

        engine.setLayerHidden(true, for: id)

        XCTAssertEqual(isHidden(engine.scene, id), true,
                       "studio OFF: a layer edit must apply to the live program scene (regression)")
    }

    // MARK: - Entering studio seeds the preview from the live program

    func testEnteringStudioSeedsPreviewFromProgram() throws {
        let (engine, id) = try engineWithOneLayer()
        engine.studioMode = true
        XCTAssertEqual(engine.previewScene.layers.map(\.sourceID),
                       engine.scene.layers.map(\.sourceID),
                       "entering studio mode must seed previewScene from the current program scene")
        XCTAssertEqual(isHidden(engine.previewScene, id), false, "seeded preview mirrors the live layer state")
    }

    // MARK: - THE off-air routing proof

    /// With studio mode ON, editing a layer targets `previewScene` (the edit
    /// shows there) while the live `scene` is UNCHANGED — proven at the state
    /// level (the pixel-level program byte-invariance is in PreviewProgramTests).
    func testEditWithStudioOnTargetsPreviewNotProgram() throws {
        let (engine, id) = try engineWithOneLayer()
        engine.studioMode = true
        XCTAssertEqual(isHidden(engine.scene, id), false)
        XCTAssertEqual(isHidden(engine.previewScene, id), false)

        engine.setLayerHidden(true, for: id)

        XCTAssertEqual(isHidden(engine.previewScene, id), true,
                       "studio ON: the edit must land on the off-air preview scene")
        XCTAssertEqual(isHidden(engine.scene, id), false,
                       "OFF-AIR: the live program scene must be UNCHANGED by an off-air edit")
    }

    /// `moveLayer` routes through the same seam.
    func testMoveLayerRoutesToPreviewInStudioMode() throws {
        let engine = AppEngine()
        guard engine.previewProgramColorMode != nil else { throw XCTSkip("no preview program (Metal unavailable)") }
        engine.addTextSource(text: "A")
        engine.addTextSource(text: "B")
        guard engine.scene.layers.count >= 2 else { throw XCTSkip("need two layers") }
        engine.studioMode = true
        let programOrdered = engine.scene.layers.sorted { $0.zIndex < $1.zIndex }.map(\.sourceID)
        let bottom = programOrdered.first!

        engine.moveLayer(bottom, up: true)

        XCTAssertEqual(engine.scene.layers.sorted { $0.zIndex < $1.zIndex }.map(\.sourceID), programOrdered,
                       "studio ON: moveLayer must not reorder the live program scene")
        let previewOrdered = engine.previewScene.layers.sorted { $0.zIndex < $1.zIndex }.map(\.sourceID)
        XCTAssertNotEqual(previewOrdered.first, bottom,
                          "studio ON: moveLayer must reorder the preview scene (bottom moved up)")
    }

    // MARK: - Hard-cut TAKE

    /// TAKE hard-cuts the off-air preview onto the program: after `take()`, the
    /// program scene equals the (edited) preview scene.
    func testTakeCommitsPreviewToProgram() throws {
        let (engine, id) = try engineWithOneLayer()
        engine.studioMode = true
        engine.setLayerHidden(true, for: id) // off-air edit
        XCTAssertEqual(isHidden(engine.scene, id), false, "pre-TAKE: program still unedited")

        engine.take()

        XCTAssertEqual(isHidden(engine.scene, id), true,
                       "TAKE must hard-cut the preview edit onto the program")
        XCTAssertEqual(engine.previewScene.layers.map(\.sourceID),
                       engine.scene.layers.map(\.sourceID),
                       "after TAKE, preview and program stay in sync")
    }

    /// `take()` is a no-op when studio mode is off (nothing to cut).
    func testTakeIsNoOpWhenStudioOff() throws {
        let (engine, id) = try engineWithOneLayer()
        let before = isHidden(engine.scene, id)
        engine.take()
        XCTAssertEqual(isHidden(engine.scene, id), before, "take() with studio OFF must not change the program")
    }

    // MARK: - STAGE 2: TAKE runs the currently-selected transition

    /// Phase 3a Stage 2: with `transitionEnabled` ON, TAKE runs the operator's
    /// selected transition (a dissolve) instead of a hard cut. Reproduce-first —
    /// against the Stage-1 hard-cut `take()` the "transition completes" assertion
    /// is RED (a hard cut never starts an animated transition, so
    /// `transitionsCompleted` never advances); after Stage 2 it is GREEN.
    ///
    /// Proves all three Stage-2 claims: (a) NOT instant — the transition is
    /// in-flight right after TAKE, so it has not completed yet; (b) it runs to
    /// completion over `transitionDuration` (`RenderLoop.Stats.transitionsCompleted`
    /// increments); (c) the off-air preview is UNCHANGED across the transition.
    func testTakeWithDissolveRunsTheTransitionNotAnInstantCut() async throws {
        let (engine, id) = try engineWithOneLayer()
        guard let loop = engine.renderLoop else {
            await engine.shutdown(); throw XCTSkip("no render loop (Metal unavailable)")
        }
        engine.setStingerMedia(nil)          // ensure a COMPOSITOR transition, not a stinger
        engine.setTransitionEnabled(true)
        engine.setTransitionKind(.dissolve)
        engine.setTransitionDuration(0.5)
        engine.studioMode = true
        engine.setLayerHidden(true, for: id) // off-air edit → a real preview≠program switch
        XCTAssertEqual(isHidden(engine.scene, id), false, "pre-TAKE: the program is still unedited")

        let previewIDsBefore = engine.previewScene.layers.map(\.sourceID)
        let completedBefore = loop.stats.transitionsCompleted

        engine.take()

        // (a) NOT an instant cut: the dissolve is in-flight, so it has not finished.
        XCTAssertEqual(loop.stats.transitionsCompleted, completedBefore,
                       "TAKE with a dissolve must NOT complete instantly — the transition should be in-flight")
        // The preview edit is committed as the new program base scene; the render
        // loop animates the program pixels toward it over `transitionDuration`.
        XCTAssertEqual(isHidden(engine.scene, id), true,
                       "TAKE commits the preview edit as the program's new base scene")
        // (c) Preview is UNCHANGED across the on-air transition.
        XCTAssertEqual(engine.previewScene.layers.map(\.sourceID), previewIDsBefore,
                       "the off-air preview scene must be UNCHANGED across the on-air transition")
        XCTAssertEqual(isHidden(engine.previewScene, id), true,
                       "the preview keeps showing the taken (incoming) scene during the transition")

        // (b) After `transitionDuration` elapses the transition COMPLETES.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, loop.stats.transitionsCompleted == completedBefore {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThan(loop.stats.transitionsCompleted, completedBefore,
                             "the dissolve TAKE must run to completion (transitionsCompleted increments)")
        // Preview STILL unchanged once the transition has landed.
        XCTAssertEqual(engine.previewScene.layers.map(\.sourceID), previewIDsBefore,
                       "the preview must remain unchanged after the transition completes")
        await engine.shutdown()
    }

    /// Stage-2 preserves Stage-1: with `transitionEnabled` OFF, TAKE is an instant
    /// hard cut — the program base scene is the preview edit IMMEDIATELY and no
    /// animated transition is ever started (a hard cut never increments
    /// `transitionsCompleted`). This is the negative control for the dissolve test.
    func testTakeWithTransitionsOffIsAnInstantHardCut() async throws {
        let (engine, id) = try engineWithOneLayer()
        guard let loop = engine.renderLoop else {
            await engine.shutdown(); throw XCTSkip("no render loop (Metal unavailable)")
        }
        engine.setTransitionEnabled(false)   // transitions OFF → Stage-1 hard cut
        engine.setTransitionDuration(0.5)
        engine.studioMode = true
        engine.setLayerHidden(true, for: id)

        let completedBefore = loop.stats.transitionsCompleted
        engine.take()

        // Instant: the edit is on the program base scene synchronously…
        XCTAssertEqual(isHidden(engine.scene, id), true,
                       "TAKE-off must hard-cut the preview edit onto the program immediately")
        XCTAssertEqual(engine.previewScene.layers.map(\.sourceID), engine.scene.layers.map(\.sourceID),
                       "after a hard-cut TAKE, preview and program stay in sync (Stage-1 behavior)")

        // …and no transition ran. Give the running loop time to (not) complete one.
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(loop.stats.transitionsCompleted, completedBefore,
                       "a hard-cut TAKE must NOT run a transition (transitionsCompleted unchanged)")
        await engine.shutdown()
    }
}
