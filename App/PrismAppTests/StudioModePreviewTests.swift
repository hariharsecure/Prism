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
}
