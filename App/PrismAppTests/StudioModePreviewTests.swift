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

    // MARK: - EXTENDED OFF-AIR PROOF (off-air leaks #1 add/remove, #3 motion/
    // entrance, #14 eye-toggle). Each mirrors the byte-invariance pattern of
    // PreviewProgramTests.testOffAirPreviewEditLeavesProgramOutputByteUnchanged at
    // the App state-routing level: with studio ON the edit must leave the PROGRAM
    // scene UNCHANGED while `previewScene` reflects it, and TAKE promotes it.

    private func twoLayerEngine() throws -> AppEngine {
        let engine = AppEngine()
        guard engine.previewProgramColorMode != nil else { throw XCTSkip("no preview program (Metal unavailable)") }
        engine.addTextSource(text: "A")
        engine.addTextSource(text: "B")
        guard engine.scene.layers.count >= 2 else { throw XCTSkip("need two layers") }
        return engine
    }

    /// LEAK #1 (add): with studio ON, adding a source lands the compositing layer
    /// on `previewScene` ONLY — the live program scene is unchanged until TAKE, so
    /// a just-added camera can't reach the recorder/stream/vcam before it is taken.
    func testAddSourceInStudioLeavesProgramUnchangedUntilTake() throws {
        let (engine, seedID) = try engineWithOneLayer()
        engine.studioMode = true
        let programBefore = engine.scene.layers.map(\.sourceID)
        XCTAssertEqual(programBefore, [seedID])

        engine.addTextSource(text: "B")
        guard let newID = engine.lastAddedVideoSourceID, newID != seedID else {
            throw XCTSkip("second text source could not be added headlessly")
        }

        XCTAssertEqual(engine.scene.layers.map(\.sourceID), programBefore,
                       "OFF-AIR: an added source must NOT reach the live program scene before TAKE")
        XCTAssertFalse(engine.scene.layers.contains { $0.sourceID == newID },
                       "the added layer must be off the program pre-TAKE")
        XCTAssertTrue(engine.previewScene.layers.contains { $0.sourceID == newID },
                      "the added source must appear on the off-air preview scene")

        engine.take()
        XCTAssertTrue(engine.scene.layers.contains { $0.sourceID == newID },
                      "TAKE must promote the added source onto the program")
    }

    /// LEAK #1 (remove): with studio ON, removing a source drops it from
    /// `previewScene` ONLY — the layer stays live AND the underlying source keeps
    /// running (deferred teardown) so the program is unchanged; TAKE commits the
    /// removal and runs the teardown.
    func testRemoveSourceInStudioLeavesProgramUnchangedUntilTake() throws {
        let engine = try twoLayerEngine()
        let victim = engine.scene.layers.sorted { $0.zIndex < $1.zIndex }.first!.sourceID
        engine.studioMode = true
        let programBefore = engine.scene.layers.map(\.sourceID)

        engine.removeSource(victim)

        XCTAssertEqual(engine.scene.layers.map(\.sourceID), programBefore,
                       "OFF-AIR: removing a source must NOT change the live program scene before TAKE")
        XCTAssertTrue(engine.activeSources.contains { $0.id == victim },
                      "OFF-AIR: the underlying source must keep running (deferred teardown) until TAKE")
        XCTAssertTrue(engine._test_pendingStudioRemovals.contains(victim), "the removal must be staged")
        XCTAssertFalse(engine.previewScene.layers.contains { $0.sourceID == victim },
                       "the off-air preview must drop the removed layer")

        engine.take()
        XCTAssertFalse(engine.scene.layers.contains { $0.sourceID == victim },
                       "TAKE must promote the removal onto the program")
        XCTAssertFalse(engine.activeSources.contains { $0.id == victim },
                       "TAKE must run the deferred source teardown")
        XCTAssertTrue(engine._test_pendingStudioRemovals.isEmpty, "staged removals cleared after TAKE")
    }

    /// LEAK #3 (motion): with studio ON, layer motion is STAGED — it does not
    /// install on the live render-loop scene provider (the program does not move)
    /// until TAKE.
    func testLayerMotionInStudioLeavesProgramProviderUnchangedUntilTake() throws {
        let (engine, id) = try engineWithOneLayer()
        guard engine.renderLoop != nil else { throw XCTSkip("no render loop (Metal unavailable)") }
        engine.studioMode = true
        XCTAssertFalse(engine._test_programHasSceneProvider, "no provider before any motion")

        engine.setLayerMotion(.orbit, speed: 1, for: id)

        XCTAssertEqual(engine._test_programLayerMotionCount, 0,
                       "OFF-AIR: layer motion must NOT install on the live program before TAKE")
        XCTAssertFalse(engine._test_programHasSceneProvider,
                       "OFF-AIR: an off-air motion edit must not install a live render-loop provider")
        XCTAssertEqual(engine._test_previewLayerMotionCount, 1, "the motion must be staged off-air")

        engine.take()
        XCTAssertEqual(engine._test_programLayerMotionCount, 1, "TAKE must promote the motion to the program")
        XCTAssertTrue(engine._test_programHasSceneProvider, "TAKE installs the live scene provider")
    }

    /// LEAK #3 (entrance): with studio ON, an entrance is STAGED — it does not start
    /// on the live program (`animatingSourceID` stays nil, no live provider) until
    /// TAKE plays it.
    func testEntranceInStudioLeavesProgramUnchangedUntilTake() throws {
        let (engine, id) = try engineWithOneLayer()
        guard engine.renderLoop != nil else { throw XCTSkip("no render loop (Metal unavailable)") }
        engine.studioMode = true

        engine.animateLayerIn(sourceID: id, preset: .slideIn, duration: 0.5)

        XCTAssertNil(engine.animatingSourceID,
                     "OFF-AIR: an off-air entrance must NOT start on the live program")
        XCTAssertFalse(engine._test_programHasSceneProvider,
                       "OFF-AIR: a staged entrance must not install a live provider")
        XCTAssertEqual(engine._test_pendingStudioEntranceCount, 1, "the entrance must be staged off-air")

        engine.take()
        XCTAssertEqual(engine.animatingSourceID, id, "TAKE must play the staged entrance on the program")
        engine.cancelLayerAnimation() // stop the entrance clear-timer before teardown
    }

    /// LEAK #14 (UI eye-toggle): the layer UI must READ `editableLayers` — the
    /// off-air preview in studio — so a toggle reflects (and is reversible on) the
    /// scene it WRITES, not the on-air program snapshot. Pre-fix the row read
    /// `engine.scene` while writing preview, so a second click could never un-hide.
    func testEyeToggleInStudioReadsEditableSceneAndIsReversible() throws {
        let (engine, id) = try engineWithOneLayer()
        engine.studioMode = true
        func editableHidden() -> Bool? { engine.editableLayers.first { $0.sourceID == id }?.isHidden }
        func programHidden() -> Bool? { engine.scene.layers.first { $0.sourceID == id }?.isHidden }

        XCTAssertEqual(editableHidden(), false, "UI reads the editable (preview) scene, starts visible")

        // Exactly what LayerControlsView's eye button does: toggle from what it READS.
        func toggleFromUI() {
            let layer = engine.editableLayers.first { $0.sourceID == id }!
            engine.setLayerHidden(!layer.isHidden, for: id)
        }

        toggleFromUI()
        XCTAssertEqual(editableHidden(), true, "first toggle hides on the edited (preview) scene")
        XCTAssertEqual(programHidden(), false, "OFF-AIR: the program is unchanged by the off-air eye toggle")

        toggleFromUI()
        XCTAssertEqual(editableHidden(), false,
                       "second toggle must UN-hide — the row reads what it writes (the #14 bug was a stuck toggle)")
        XCTAssertEqual(programHidden(), false, "OFF-AIR: still no program change after two off-air toggles")

        toggleFromUI() // hide again, then prove TAKE promotes the preview state
        XCTAssertEqual(editableHidden(), true)
        engine.take()
        XCTAssertEqual(programHidden(), true, "TAKE promotes the off-air eye-toggle state onto the program")
    }

    /// KNOWN RESIDUAL — off-air leak #2 (FX keying). Per-source FX (chroma / luma /
    /// background key) run through ONE shared `SourceEffectPipeline` whose processed
    /// frame is posted to a single mailbox consumed by BOTH buses
    /// (`deliverSourceFrame`), so a studio FX edit reaches the live program BEFORE
    /// TAKE. A correct fix needs a per-bus FX stage (stage preview FX + premult,
    /// promote on TAKE) — deferred this pass to avoid shipping a half-broken FX
    /// change. This xfail LOCKS the residual in and flips GREEN when it is fixed.
    func testFXKeyingInStudioIsAKnownProgramLeakResidual() throws {
        let (engine, id) = try engineWithOneLayer()
        engine.studioMode = true
        XCTAssertFalse(engine._test_sourceBackgroundIsRemove(id), "no key before the edit")

        XCTExpectFailure("off-air leak #2: FX keying is a shared-pipeline residual — stage preview FX + promote on TAKE") {
            engine.setBackground(.remove, for: id)
            // DESIRED post-fix invariant: a studio FX key must not change the shared,
            // program-facing FX state until TAKE. Today it changes immediately.
            XCTAssertFalse(engine._test_sourceBackgroundIsRemove(id),
                           "off-air: a studio FX key must not change the program-facing FX state pre-TAKE")
        }
    }

    // MARK: - #12 TAKE-in-flight guard

    /// A second TAKE while the first take's transition is still running must be
    /// COALESCED (ignored) — pre-fix it hard-jumped the program (RenderLoop
    /// interrupts a running transition with a cut to its old target).
    func testTakeInFlightGuardCoalescesASecondTake() throws {
        let engine = try twoLayerEngine()
        guard engine.renderLoop != nil else { throw XCTSkip("no render loop (Metal unavailable)") }
        let ids = engine.scene.layers.sorted { $0.zIndex < $1.zIndex }.map(\.sourceID)
        let a = ids[0], b = ids[1]
        engine.setStingerMedia(nil)
        engine.setTransitionEnabled(true)
        engine.setTransitionKind(.dissolve)
        engine.setTransitionDuration(0.5)
        engine.studioMode = true

        engine.setLayerHidden(true, for: a)
        engine.take() // starts a transition
        XCTAssertTrue(engine._test_takeTransitionInFlight, "the first TAKE's transition is in flight")
        XCTAssertEqual(engine.scene.layers.first { $0.sourceID == a }?.isHidden, true,
                       "first TAKE committed edit A as the program base scene")

        engine.setLayerHidden(true, for: b) // a second off-air edit
        engine.take() // must be coalesced — no hard-jump to edit B
        XCTAssertEqual(engine.scene.layers.first { $0.sourceID == b }?.isHidden, false,
                       "#12: a TAKE while a transition is in flight must be IGNORED (no hard-jump to edit B)")

        // Negative control: once the transition completes (guard clears), TAKE lands B.
        engine._test_clearTakeGuard()
        engine.take()
        XCTAssertEqual(engine.scene.layers.first { $0.sourceID == b }?.isHidden, true,
                       "after the guard clears, a subsequent TAKE promotes the pending edit B")
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
