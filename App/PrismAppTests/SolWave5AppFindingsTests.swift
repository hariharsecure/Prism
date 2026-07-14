import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import Metal
import os
import UniformTypeIdentifiers
import XCTest

import PrismAudio
import PrismColor
import PrismCompositor
import PrismCore
import PrismOutput
import PrismScreen
import PrismSources
@testable import Prism

/// sol #5 (gpt-5.6-sol) — App-level HDR-wiring gaps + lifecycle races. Each test
/// reproduces the defect on real state with an independent oracle + a negative control
/// (red when the fix is neutralized), per PRODUCTION_BIBLE classes A / B / E / J.
@MainActor
final class SolWave5AppFindingsTests: XCTestCase {

    // MARK: #3 — the App must REQUEST HDR screen capture

    /// Pre-fix `addScreen` always built a default (`preferHDR=false`) config, so a
    /// screen source stayed 8-bit SDR even in an HDR show. The config builder must map
    /// the show's HDR state straight onto `preferHDR`.
    func testScreenCaptureConfigRequestsHDRWhenEnabled() {
        XCTAssertFalse(AppEngine.screenCaptureConfiguration(captureAudio: true, hdr: false).preferHDR,
                       "SDR show must not request HDR screen capture")
        XCTAssertTrue(AppEngine.screenCaptureConfiguration(captureAudio: true, hdr: true).preferHDR,
                      "#3: an HDR show must request the 10-bit HDR screen-capture path")
    }

    /// Toggling HDR must reconfigure a LIVE screen source to request the HDR path — not
    /// leave it stuck on the range it was built with. Uses a pre-built (NOT started)
    /// ScreenSource so no capture / TCC is involved; the reconfigure is skipped-start.
    func testHDRToggleReconfiguresLiveScreenSource() throws {
        let engine = AppEngine()
        guard engine.verticalProgramColorMode != nil || engine.renderLoop != nil else {
            throw XCTSkip("no Metal device")
        }
        let desc = SourceDescriptor(kind: .display, id: "display:1", name: "Display")
        let src = try ScreenSource(descriptor: desc,
                                   configuration: AppEngine.screenCaptureConfiguration(captureAudio: false, hdr: false))
        engine.integrationDebugRegisterScreenSource(src, descriptor: desc)
        let id = SourceID(desc.id)
        XCTAssertEqual(engine.integrationDebugScreenSourcePreferHDR(id), false)

        AppEngine._test_skipScreenSourceStart = true
        // sol #6 #7: the swap now commits only when the replacement's async start
        // CONFIRMS — simulate that success so the reconfigure takes effect.
        AppEngine._test_simulatedScreenStartOutcome = .success
        defer {
            AppEngine._test_skipScreenSourceStart = false
            AppEngine._test_simulatedScreenStartOutcome = .none
        }
        engine.setHDREnabled(true)
        guard engine.hdrEnabled else { throw XCTSkip("HDR toggle did not take (Metal/off-air)") }
        XCTAssertEqual(engine.integrationDebugScreenSourcePreferHDR(id), true,
                       "#3: HDR toggle did not reconfigure the live screen source to request HDR capture")
        // Toggling back returns it to the SDR path (no state left stuck HDR).
        engine.setHDREnabled(false)
        XCTAssertEqual(engine.integrationDebugScreenSourcePreferHDR(id), false,
                       "#3: disabling HDR did not return the screen source to the SDR path")
    }

    /// sol #6 #7: an HDR reconfigure's replacement `ScreenSource.start()` is async; if
    /// the async start FAILS, the old (working) source must be RESTORED, not left with no
    /// screen source. Simulated via the async-outcome seam. `.success` commits the swap
    /// (proves the mechanism can change the source), `.failure` preserves the old source;
    /// the negative control reproduces the pre-fix loss.
    func testFailedAsyncScreenStartRestoresOldSource() throws {
        func preferHDRAfterToggle(outcome: AppEngine.ScreenStartOutcome, loseOnFailure: Bool) throws -> Bool? {
            let engine = AppEngine()
            guard engine.renderLoop != nil else { throw XCTSkip("no Metal device") }
            let desc = SourceDescriptor(kind: .display, id: "display:1", name: "Display")
            let src = try ScreenSource(descriptor: desc,
                                       configuration: AppEngine.screenCaptureConfiguration(captureAudio: false, hdr: false))
            engine.integrationDebugRegisterScreenSource(src, descriptor: desc)
            let id = SourceID(desc.id)
            XCTAssertEqual(engine.integrationDebugScreenSourcePreferHDR(id), false)

            AppEngine._test_skipScreenSourceStart = true
            AppEngine._test_simulatedScreenStartOutcome = outcome
            AppEngine._test_screenRollbackRemovesOnFailure = loseOnFailure
            defer {
                AppEngine._test_skipScreenSourceStart = false
                AppEngine._test_simulatedScreenStartOutcome = .none
                AppEngine._test_screenRollbackRemovesOnFailure = false
            }
            engine.setHDREnabled(true)
            guard engine.hdrEnabled else { throw XCTSkip("HDR toggle did not take (Metal/off-air)") }
            return engine.integrationDebugScreenSourcePreferHDR(id)  // nil ⇒ source gone
        }

        // SUCCESS: the async start confirms → the swap commits (source now HDR).
        XCTAssertEqual(try preferHDRAfterToggle(outcome: .success, loseOnFailure: false), true,
                       "async-start success must commit the HDR replacement")
        // NEGATIVE CONTROL: pre-fix, an async-start failure loses the screen source.
        XCTAssertNil(try preferHDRAfterToggle(outcome: .failure, loseOnFailure: true),
                     "negative control vacuous: the source survived even with the pre-fix loss behaviour")
        // FIX: an async-start failure keeps the OLD (SDR) source — never left with none.
        XCTAssertEqual(try preferHDRAfterToggle(outcome: .failure, loseOnFailure: false), false,
                       "#7: a failed async screen-start left the old source torn down (no screen source)")
    }

    // MARK: sol #7 #2 — screen replacement protocol is lifecycle-safe

    /// The pending replacement must be STRONGLY OWNED until its async start resolves —
    /// `ScreenSource.start()` runs on a `[weak self]` Task, so with no external owner the
    /// source deallocs before `startCapture` acquires it and the reconfigure silently
    /// never starts. `_test_lastScreenReplacement` is a WEAK probe (never retains).
    func testPendingScreenReplacementIsStronglyOwnedUntilResolved() throws {
        func replacementSurvives(ownershipEnabled: Bool) throws -> Bool {
            let engine = AppEngine()
            guard engine.renderLoop != nil else { throw XCTSkip("no Metal device") }
            let desc = SourceDescriptor(kind: .display, id: "display:1", name: "Display")
            let src = try ScreenSource(descriptor: desc,
                                       configuration: AppEngine.screenCaptureConfiguration(captureAudio: false, hdr: false))
            engine.integrationDebugRegisterScreenSource(src, descriptor: desc)

            AppEngine._test_skipScreenSourceStart = true
            AppEngine._test_simulatedScreenStartOutcome = .none   // stays PENDING (no commit)
            AppEngine._test_skipPendingScreenOwnership = !ownershipEnabled
            defer {
                AppEngine._test_skipScreenSourceStart = false
                AppEngine._test_simulatedScreenStartOutcome = .none
                AppEngine._test_skipPendingScreenOwnership = false
            }
            autoreleasepool { engine.setHDREnabled(true) }
            guard engine.hdrEnabled else { throw XCTSkip("HDR toggle did not take") }
            return engine._test_lastScreenReplacementAlive()
        }
        // NEGATIVE CONTROL: without the strong owner the pending replacement deallocs.
        XCTAssertFalse(try replacementSurvives(ownershipEnabled: false),
                       "negative control vacuous: the pending replacement survived even without the strong owner")
        // FIX: the pending replacement is retained until its start resolves.
        XCTAssertTrue(try replacementSurvives(ownershipEnabled: true),
                      "#2: the pending screen replacement was not strongly owned (would dealloc before startCapture)")
    }

    /// An HDR on→off toggle followed by the FIRST (HDR) replacement's LATE async success
    /// must NOT commit the stale HDR source — the mode already flipped back to SDR. The
    /// commit mode-gate rejects a replacement whose `preferHDR` no longer matches the
    /// current show.
    func testStaleScreenReplacementNotCommittedAfterToggleBack() throws {
        let engine = AppEngine()
        guard engine.renderLoop != nil else { throw XCTSkip("no Metal device") }
        let desc = SourceDescriptor(kind: .display, id: "display:1", name: "Display")
        let src = try ScreenSource(descriptor: desc,
                                   configuration: AppEngine.screenCaptureConfiguration(captureAudio: false, hdr: false))
        engine.integrationDebugRegisterScreenSource(src, descriptor: desc)
        let id = SourceID(desc.id)

        AppEngine._test_skipScreenSourceStart = true
        AppEngine._test_simulatedScreenStartOutcome = .none   // HDR replacement stays PENDING
        defer {
            AppEngine._test_skipScreenSourceStart = false
            AppEngine._test_simulatedScreenStartOutcome = .none
        }
        engine.setHDREnabled(true)                            // builds an HDR replacement (pending)
        guard engine.hdrEnabled else { throw XCTSkip("HDR toggle did not take") }
        engine.setHDREnabled(false)                           // desired mode flips back to SDR
        XCTAssertFalse(engine.hdrEnabled)

        // The stale HDR replacement's start now confirms LATE.
        engine._test_fireLatePendingScreenCommit(id)
        XCTAssertEqual(engine.integrationDebugScreenSourcePreferHDR(id), false,
                       "#2: a superseded HDR replacement's late success committed the stale HDR source")
    }

    /// A POST-commit window/display failure of the live screen source must surface an
    /// error, deregister the failed source, and restore the prior source — not leave a
    /// dead source registered silently (the pre-fix `current !== failed` early-return).
    func testPostCommitScreenFailureSurfacesErrorAndRestoresPrior() throws {
        func run(skipRestore: Bool) throws -> (error: Bool, preferHDR: Bool?) {
            let engine = AppEngine()
            guard engine.renderLoop != nil else { throw XCTSkip("no Metal device") }
            let desc = SourceDescriptor(kind: .display, id: "display:1", name: "Display")
            let src = try ScreenSource(descriptor: desc,
                                       configuration: AppEngine.screenCaptureConfiguration(captureAudio: false, hdr: false))
            engine.integrationDebugRegisterScreenSource(src, descriptor: desc)
            let id = SourceID(desc.id)

            AppEngine._test_skipScreenSourceStart = true
            AppEngine._test_simulatedScreenStartOutcome = .success   // commit the HDR source
            AppEngine._test_skipPostCommitScreenRestore = skipRestore
            defer {
                AppEngine._test_skipScreenSourceStart = false
                AppEngine._test_simulatedScreenStartOutcome = .none
                AppEngine._test_skipPostCommitScreenRestore = false
            }
            engine.setHDREnabled(true)
            guard engine.hdrEnabled else { throw XCTSkip("HDR toggle did not take") }
            XCTAssertEqual(engine.integrationDebugScreenSourcePreferHDR(id), true)

            engine.lastError = nil
            engine._test_failLiveScreenSource(id)               // mid-capture failure, post-commit
            return (engine.lastError != nil, engine.integrationDebugScreenSourcePreferHDR(id))
        }

        // NEGATIVE CONTROL: pre-fix — no error surfaced, the dead HDR source stays registered.
        let neg = try run(skipRestore: true)
        XCTAssertFalse(neg.error, "negative control vacuous: an error surfaced even with the pre-fix silent no-op")
        XCTAssertEqual(neg.preferHDR, true, "negative control vacuous: the failed source was already removed pre-fix")

        // FIX: error surfaced + the prior (SDR) source restored (the failed HDR deregistered).
        let fixed = try run(skipRestore: false)
        XCTAssertTrue(fixed.error, "#2: a post-commit screen failure surfaced no error")
        XCTAssertEqual(fixed.preferHDR, false, "#2: post-commit failure did not restore the prior (SDR) screen source")
    }

    // MARK: #7 — a superseded post-provider resume must NOT resurrect removed media

    /// `resumeMemeSourceAfterFrameZeroPresented` waits (bounded) for frame 0, then
    /// starts the source. Pre-fix it STRONG-captured the source and called `start()`
    /// unconditionally — so a removal / expiry / shutdown during the wait resurrected an
    /// orphan looping decoder. The resume must re-check supersession and STOP instead of
    /// starting. Deterministic: drive the guard directly (superseded vs current).
    func testSupersededResumeDoesNotResurrectSource() async throws {
        let gifURL = try makeAnimatedGIF(colors: [(1,0,0),(0,1,0),(0,0,1)], delay: 0.05, side: 16)

        func endedRunning(superseded: Bool) async throws -> Bool {
            let source = try AnimatedGIFSource(fileURL: gifURL, canvasSize: .hd,
                                               contentMode: .aspectFit, loop: true)
            AppEngine.resumeMemeSourceAfterFrameZeroPresented(
                source, loop: nil, ticksBefore: 0, gated: false,
                isSuperseded: { superseded },
                finalizeOnMain: { _ in },
                onError: { _ in })
            // Let the cue queue process the resume.
            try await Task.sleep(nanoseconds: 300_000_000)
            let running = source.state == .running
            source.stop()
            return running
        }

        // NEGATIVE CONTROL: not superseded → the resume legitimately starts the source.
        let control = try await endedRunning(superseded: false)
        XCTAssertTrue(control, "negative control vacuous: a current resume never started the source")
        // FIX: superseded (removed / expired / shut down during the wait) → NO resurrection.
        let fixed = try await endedRunning(superseded: true)
        XCTAssertFalse(fixed, "#7: a superseded post-provider resume resurrected removed media (orphan decoder)")
    }

    /// Integration: removing a meme while its post-provider resume is in flight leaves
    /// no orphan — the source ends stopped and no provider is installed.
    func testRemoveDuringResumeLeavesNoOrphan() async throws {
        let gifURL = try makeAnimatedGIF(colors: [(1,0,0),(0,1,0)], delay: 0.05, side: 16)
        let engine = AppEngine()
        guard engine.renderLoop != nil else { await engine.shutdown(); throw XCTSkip("no render loop") }
        engine.addMeme(url: gifURL, mode: .insert, placement: .lowerThird, holdSec: 1, isBuiltIn: true)
        let item = try XCTUnwrap(engine.memeItems.first { $0.mediaURL == gifURL })

        engine.triggerMeme(id: item.id)
        // Remove it mid-cue/resume; the source id is retained by the meme item.
        let sourceID = item.sourceID
        engine.removeMeme(id: item.id)
        try await Task.sleep(nanoseconds: 500_000_000)   // let any resume drain
        XCTAssertFalse(engine.integrationDebugAuxiliaryIsRunning(sourceID),
                       "#7: a meme removed during its resume was left running (orphan)")
        XCTAssertFalse(engine.integrationDebugMemeProviderInstalled)
        await engine.shutdown()
    }

    // MARK: #10 — failed-admission rollback restores the victim's FULL state

    /// A failed replacement admit re-admits the evicted victim, and must restore its
    /// scene layer + transform + per-source effects — not re-add bare by URL with
    /// defaults. Negative control: the bare re-add loses the transform/effects.
    func testFailedAdmissionRollbackRestoresVictimState() throws {
        let framesEach = 120
        let g1 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: framesEach)
        let g2 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: framesEach)
        let g3 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: framesEach)
        let each = AppEngine.estimatedAnimatedByteCost(url: g1, mode: .insert)

        struct Restored { var frame: CGRect?; var exposure: Double?; var present: Bool }
        func rollbackVictimState(bare: Bool) throws -> Restored {
            let engine = AppEngine()
            let ceiling = engine.integrationDebugAnimatedMemeBytes.ceiling
            XCTAssertLessThanOrEqual(each * 2, ceiling, "two fixtures must fit together")
            XCTAssertGreaterThan(each * 3, ceiling, "three fixtures must exceed the ceiling")

            // g1 is the victim (oldest). Add both survivors first (each add re-applies
            // the scene preset, which would reset a layer transform), THEN give the
            // victim its DISTINCTIVE transform + effect right before the failing admit —
            // so the pre-eviction snapshot captures exactly this state.
            engine.addGIFSource(fileURL: g1)
            let victim = try XCTUnwrap(engine.integrationDebugActiveSourceIDs.last)
            engine.addGIFSource(fileURL: g2)
            engine.setLayerFrame(.corner, for: victim)                 // non-default transform
            engine.setGrade(ColorGrade(exposure: 0.42, contrast: 1, saturation: 1), for: victim)

            AppEngine._test_rollbackBareReadmit = bare
            AppEngine._test_forceAnimatedConstructionFailure = true
            defer {
                AppEngine._test_rollbackBareReadmit = false
                AppEngine._test_forceAnimatedConstructionFailure = false
            }
            engine.addGIFSource(fileURL: g3)   // evicts g1 (before decode), decode FAILS → rollback

            // Find the re-admitted victim by URL (fresh id).
            guard let readmitID = engine.integrationDebugAnimatedGIFSourceID(for: g1) else {
                return Restored(frame: nil, exposure: nil, present: false)
            }
            return Restored(frame: engine.integrationDebugLayer(readmitID)?.frame,
                            exposure: engine.integrationDebugSourceEffects(readmitID)?.grade.exposure,
                            present: true)
        }

        // NEGATIVE CONTROL (bare re-add): victim's bytes come back but its layer is the
        // DEFAULT full-canvas and its effects are IDENTITY — state lost.
        let control = try rollbackVictimState(bare: true)
        XCTAssertTrue(control.present, "bare re-add did not re-admit the victim at all")
        XCTAssertEqual(control.frame, CGRect(x: 0, y: 0, width: 1, height: 1),
                       "negative control vacuous: bare re-add somehow kept the transform")
        XCTAssertEqual(control.exposure ?? 0, 0, accuracy: 1e-9,
                       "negative control vacuous: bare re-add somehow kept the effect")
        // FIX: the victim's exact transform + effect are restored.
        let fixed = try rollbackVictimState(bare: false)
        XCTAssertTrue(fixed.present, "#10: rollback did not re-admit the victim")
        XCTAssertEqual(fixed.frame, LayerFramePreset.corner.rect,
                       "#10: rollback lost the victim's scene-layer transform (re-added bare with defaults)")
        XCTAssertEqual(try XCTUnwrap(fixed.exposure), 0.42, accuracy: 1e-6,
                       "#10: rollback lost the victim's per-source effects (re-added bare with defaults)")
    }

    /// sol #7 #8: a failed-then-rolled-back admission must PRESERVE the LRU eviction order.
    /// The re-admit APPENDS the victim at the newest end, so pre-fix the rolled-back OLDEST
    /// victim (`g1`) became "newest" and the NEXT admission wrongly evicted the newer `g2`.
    /// Restoring the captured LRU position keeps `g1` at the FRONT (next to be evicted).
    func testFailedAdmissionRollbackPreservesLRUEvictionOrder() throws {
        let g1 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: 120)
        let g2 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: 120)
        let g3 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: 120)
        let each = AppEngine.estimatedAnimatedByteCost(url: g1, mode: .insert)

        // After a failed g3 admit that evicted+rolled-back g1: is the FRONT (next-evicted)
        // LRU entry the re-admitted g1 (fixed) or the newer g2 (pre-fix append)?
        func frontIsReadmittedG1(skipLRURestore: Bool) throws -> (frontIsG1: Bool, count: Int) {
            let engine = AppEngine()
            let ceiling = engine.integrationDebugAnimatedMemeBytes.ceiling
            XCTAssertLessThanOrEqual(each * 2, ceiling, "two fixtures must fit together")
            XCTAssertGreaterThan(each * 3, ceiling, "three fixtures must exceed the ceiling")

            engine.addGIFSource(fileURL: g1)   // oldest
            engine.addGIFSource(fileURL: g2)   // newer
            AppEngine._test_rollbackSkipLRURestore = skipLRURestore
            AppEngine._test_forceAnimatedConstructionFailure = true
            defer {
                AppEngine._test_rollbackSkipLRURestore = false
                AppEngine._test_forceAnimatedConstructionFailure = false
            }
            engine.addGIFSource(fileURL: g3)   // evicts g1 (oldest) before decode; decode FAILS → rollback

            let lru = engine._test_animatedMediaLRU()
            let g1id = engine.integrationDebugAnimatedGIFSourceID(for: g1)   // fresh id after rollback
            return (lru.first == g1id && g1id != nil, lru.count)
        }

        // NEGATIVE CONTROL: without the position restore, g1 is appended last → g2 is now
        // the front, so the next eviction would wrongly evict the newer g2.
        let neg = try frontIsReadmittedG1(skipLRURestore: true)
        XCTAssertEqual(neg.count, 2, "both survivors must remain after the rollback")
        XCTAssertFalse(neg.frontIsG1, "negative control vacuous: g1 stayed at the front even without the position restore")
        // FIX: g1 is restored to the FRONT — the next eviction correctly picks the oldest (g1).
        let fixed = try frontIsReadmittedG1(skipLRURestore: false)
        XCTAssertEqual(fixed.count, 2, "both survivors must remain after the rollback")
        XCTAssertTrue(fixed.frontIsG1, "#8: rollback reordered the LRU — the next eviction would pick the newer g2, not the oldest g1")
    }

    /// sol #6 #10: when the victim's OWN re-decode ALSO fails (double-failure), the
    /// rollback must touch NOTHING — the pre-fix code bound the restored state to the
    /// stale `lastAddedVideoSourceID`, applying the victim's transform to an UNRELATED
    /// live source. Negative control: bind to `lastAdded` → the survivor is clobbered.
    func testDoubleFailureRollbackDoesNotMutateUnrelatedSource() throws {
        let g1 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: 120)
        let g2 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: 120)
        let g3 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: 120)

        // Use per-source grade EXPOSURE as the distinctive marker (a layer transform is
        // reset by the scene-preset re-application that each add triggers; a grade is not).
        func survivorExposure(bindToLastAdded: Bool) throws -> Double? {
            let engine = AppEngine()
            engine.addGIFSource(fileURL: g1)                    // victim (oldest)
            let victim = try XCTUnwrap(engine.integrationDebugActiveSourceIDs.last)
            engine.addGIFSource(fileURL: g2)                    // survivor; lastAdded now = g2
            let survivor = try XCTUnwrap(engine.integrationDebugActiveSourceIDs.last)
            engine.setGrade(ColorGrade(exposure: 0.11, contrast: 1, saturation: 1), for: survivor) // survivor's OWN
            engine.setGrade(ColorGrade(exposure: 0.42, contrast: 1, saturation: 1), for: victim)   // victim distinctive

            AppEngine._test_forcedAnimatedConstructionFailuresRemaining = 2 // g3 AND g1 re-decode fail
            AppEngine._test_rollbackBindToLastAdded = bindToLastAdded
            defer {
                AppEngine._test_forcedAnimatedConstructionFailuresRemaining = 0
                AppEngine._test_rollbackBindToLastAdded = false
            }
            engine.addGIFSource(fileURL: g3)   // evict g1 → g3 fails → rollback g1 ALSO fails
            return engine.integrationDebugSourceEffects(survivor)?.grade.exposure
        }

        // NEGATIVE CONTROL: lastAdded-binding applies the victim's grade to the survivor.
        XCTAssertEqual(try survivorExposure(bindToLastAdded: true) ?? 0, 0.42, accuracy: 1e-6,
                       "negative control vacuous: lastAdded-binding did not clobber the survivor")
        // FIX: the unrelated survivor keeps its OWN grade (rollback touched nothing).
        XCTAssertEqual(try survivorExposure(bindToLastAdded: false) ?? 0, 0.11, accuracy: 1e-6,
                       "#10: a double-failure rollback mutated an unrelated source via stale lastAdded")
    }

    /// sol #6 #10: a SUCCESSFUL rollback restores the victim's vertical-hero + stinger-
    /// media routing (both were lost pre-fix — the GIF snapshot never captured them, and
    /// eviction clears them). Negative control: skip the restore → both stay cleared.
    func testRollbackRestoresVerticalHeroAndStingerRouting() throws {
        let g1 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: 120)
        let g2 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: 120)
        let g3 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: 120)

        func routing(skipRestore: Bool) throws -> (hero: Bool, stinger: Bool) {
            let engine = AppEngine()
            engine.addGIFSource(fileURL: g1)                    // victim (oldest)
            let victim = try XCTUnwrap(engine.integrationDebugActiveSourceIDs.last)
            engine.setVerticalHero(victim)
            engine.setStingerMedia(victim)
            engine.addGIFSource(fileURL: g2)

            AppEngine._test_forceAnimatedConstructionFailure = true   // one-shot: g3 fails, g1 re-admit succeeds
            AppEngine._test_rollbackSkipHeroStinger = skipRestore
            defer {
                AppEngine._test_forceAnimatedConstructionFailure = false
                AppEngine._test_rollbackSkipHeroStinger = false
            }
            engine.addGIFSource(fileURL: g3)   // evict g1 → g3 fails → rollback re-admits g1
            guard let readmit = engine.integrationDebugAnimatedGIFSourceID(for: g1) else {
                return (false, false)
            }
            return (engine.verticalHeroSourceID == readmit, engine.stingerMediaID == readmit)
        }

        // NEGATIVE CONTROL: skipping the restore loses both (eviction cleared them).
        let control = try routing(skipRestore: true)
        XCTAssertFalse(control.hero, "negative control vacuous: hero restored even when skipped")
        XCTAssertFalse(control.stinger, "negative control vacuous: stinger restored even when skipped")
        // FIX: both routings are re-bound to the re-admitted source.
        let fixed = try routing(skipRestore: false)
        XCTAssertTrue(fixed.hero, "#10: rollback lost the victim's vertical-hero routing")
        XCTAssertTrue(fixed.stinger, "#10: rollback lost the victim's stinger-media routing")
    }

    // MARK: #13 — vcam attach must not race the HDR gate

    /// The feeder starts feeding (SDR) frames during the async attach window while
    /// `vcamOutputEnabled` is still false. An HDR toggle in that window must be REFUSED
    /// (gated on `vcamOutputRequested`), or it switches the live vcam stream to l10r
    /// mid-flight. Negative control: gate only on the confirmed flag → the toggle slips.
    func testHDRToggleGatedDuringVCamAttach() throws {
        func hdrTookDuringAttach(ignoreRequested: Bool) throws -> Bool {
            let engine = AppEngine()
            guard engine.renderLoop != nil else { throw XCTSkip("no render loop") }
            engine.setVirtualCameraOutput(true)     // requested synchronously; not yet .feeding
            XCTAssertTrue(engine.vcamOutputRequested, "vcam not requested")
            XCTAssertFalse(engine.vcamOutputEnabled, "vcam confirmed feeding without a device (unexpected)")
            AppEngine._test_ignoreVcamRequestedInHDRGate = ignoreRequested
            defer { AppEngine._test_ignoreVcamRequestedInHDRGate = false }
            engine.setHDREnabled(true)
            let took = engine.hdrEnabled
            engine.setVirtualCameraOutput(false)
            return took
        }
        // NEGATIVE CONTROL: ignoring `vcamOutputRequested` lets the HDR toggle slip
        // through mid-attach (would switch the live stream to l10r).
        let control = try hdrTookDuringAttach(ignoreRequested: true)
        XCTAssertTrue(control, "negative control vacuous: HDR was blocked even ignoring the requested flag")
        // FIX: the requested-gate refuses the toggle until the vcam is fully stopped.
        let fixed = try hdrTookDuringAttach(ignoreRequested: false)
        XCTAssertFalse(fixed, "#13: HDR toggle passed during a vcam attach — SDR frames then l10r on the same live stream")
    }

    // MARK: #14 — classic RTMP must not be given HEVC-HDR

    /// The encode-once program feeds ONE elementary stream to every target. HDR (HEVC
    /// Main10) is allowed ONLY when every target is SRT; any classic-RTMP target (the
    /// single-RTMP primary is always classic; a `.rtmp` destination is treated classic)
    /// forces H.264 SDR so HEVC is never silently sent to RTMP ingest.
    func testClassicRTMPNotGivenHEVCHDR() {
        let srt = Destination(name: "SRT", proto: .srt, url: "srt://host:9000")
        let rtmp = Destination(name: "YT", proto: .rtmp, url: "rtmp://a.rtmp.youtube.com/live2", key: "k")

        // HDR off → never HDR regardless of targets.
        XCTAssertFalse(AppEngine.streamUsesHDR(hdrEnabled: false, hasPrimaryRTMP: false, destinations: [srt]))
        // A plain-RTMP primary + HDR → H.264 SDR (gated), NOT silent HEVC.
        XCTAssertFalse(AppEngine.streamUsesHDR(hdrEnabled: true, hasPrimaryRTMP: true, destinations: []),
                       "#14: HEVC-HDR was allowed to a classic-RTMP primary")
        // An RTMP destination + HDR → gated too.
        XCTAssertFalse(AppEngine.streamUsesHDR(hdrEnabled: true, hasPrimaryRTMP: false, destinations: [rtmp]),
                       "#14: HEVC-HDR was allowed to a classic-RTMP destination")
        XCTAssertFalse(AppEngine.streamUsesHDR(hdrEnabled: true, hasPrimaryRTMP: false, destinations: [srt, rtmp]),
                       "#14: HEVC-HDR allowed when a classic-RTMP target is mixed in")
        // SRT-only (no classic RTMP anywhere) + HDR → HEVC-HDR is fine.
        XCTAssertTrue(AppEngine.streamUsesHDR(hdrEnabled: true, hasPrimaryRTMP: false, destinations: [srt]),
                      "#14: an SRT-only HDR broadcast was wrongly downgraded")
    }

    // MARK: #15 — disabling the video wall releases the CPU fallback pool synchronously

    /// A stalled Metal-fallback source gets no further `process(_:)` callback, so the
    /// CPU `TileRepeatRenderer` + `FXCanvas` pool must be released SYNCHRONOUSLY at the
    /// disable site (`update`), not only from a later callback. Negative control: skip
    /// the disable-site release → the stalled source pins the pool.
    func testVideoWallDisableReleasesCPUPoolSynchronously() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let side = 48
        let wall = VideoWall(rows: 2, cols: 2, mirror: false)

        func poolAfterDisable(skipRelease: Bool) throws -> Bool {
            let pipeline = SourceEffectPipeline(device: device, sourceID: SourceID("fx.cpu.pool"),
                                                canvasWidth: side, canvasHeight: side)
            SourceEffectPipeline._test_forceCaptureGPUUnavailable = true
            defer { SourceEffectPipeline._test_forceCaptureGPUUnavailable = false }
            pipeline.update(SourceEffects(videoWall: wall))                 // wall ON
            _ = pipeline.process(try makeBGRAFrame(side: side, source: SourceID("fx.cpu.pool")))
            XCTAssertTrue(pipeline.debugHasCaptureCPURenderer, "CPU pool was never allocated (fixture)")

            // The source STALLS (no further process()). Disable the wall.
            SourceEffectPipeline._test_skipCPUReleaseAtDisableSite = skipRelease
            defer { SourceEffectPipeline._test_skipCPUReleaseAtDisableSite = false }
            pipeline.update(SourceEffects())
            return pipeline.debugHasCaptureCPURenderer
        }

        // NEGATIVE CONTROL: skip the synchronous release → a stalled source pins the pool.
        XCTAssertTrue(try poolAfterDisable(skipRelease: true),
                      "negative control vacuous: the CPU pool released even without the disable-site release")
        // FIX: the disable site releases the CPU pool with no further callback.
        XCTAssertFalse(try poolAfterDisable(skipRelease: false),
                       "#15: a disabled video wall retained its CPU FXCanvas pool (stalled source pins it)")
    }

    // MARK: sol #6 #15 — a disable mid-callback must not recreate the CPU renderer / emit a stale frame

    /// The residual race: the top-of-`applyVideoWall` gate observes the wall ON, then a
    /// disable lands, then (GPU unavailable) the CPU fallback RECREATES the renderer and
    /// emits one stale tiled frame. The render-site re-check (inside `captureCPULock`,
    /// the SAME lock the release takes) closes it. Modelled single-threaded: the wall is
    /// already disabled (`effects.videoWall == nil`) while a STALE snapshot drives the
    /// render with the top gate bypassed (as if it had passed pre-disable).
    func testVideoWallDisableMidCallbackDoesNotRecreateCPURenderer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let side = 48
        let staleWall = VideoWall(rows: 2, cols: 2, mirror: false)

        func renderWithRenderGateSkipped(_ skip: Bool) throws -> (emitted: Bool, hasRenderer: Bool) {
            let pipeline = SourceEffectPipeline(device: device, sourceID: SourceID("fx.wall.race"),
                                                canvasWidth: side, canvasHeight: side)
            // Wall is DISABLED (fresh pipeline) but the callback carries a STALE non-nil wall.
            SourceEffectPipeline._test_forceCaptureGPUUnavailable = true   // force the CPU path
            SourceEffectPipeline._test_skipVideoWallDisableGate = true     // top gate already "passed"
            SourceEffectPipeline._test_skipVideoWallRenderSiteGate = skip  // the acquisition gate under test
            SourceEffectPipeline._test_skipVideoWallEmitSiteGate = skip    // sol #7: also the emit-site gate
            defer {
                SourceEffectPipeline._test_forceCaptureGPUUnavailable = false
                SourceEffectPipeline._test_skipVideoWallDisableGate = false
                SourceEffectPipeline._test_skipVideoWallRenderSiteGate = false
                SourceEffectPipeline._test_skipVideoWallEmitSiteGate = false
            }
            let frame = try makeBGRAFrame(side: side, source: SourceID("fx.wall.race"))
            let out = pipeline._test_applyVideoWallWithStaleSnapshot(frame, staleWall: staleWall)
            return (out != nil, pipeline.debugHasCaptureCPURenderer)
        }

        // NEGATIVE CONTROL: without the render-site gate, a disabled wall recreates the
        // CPU renderer and emits a stale tiled frame.
        let neg = try renderWithRenderGateSkipped(true)
        XCTAssertTrue(neg.emitted, "negative control vacuous: no stale frame even without the render-site gate")
        XCTAssertTrue(neg.hasRenderer, "negative control vacuous: renderer not recreated without the gate")

        // FIX: the render-site re-check suppresses the stale frame and does NOT recreate.
        let fixed = try renderWithRenderGateSkipped(false)
        XCTAssertFalse(fixed.emitted, "#15: a disable mid-callback still emitted a stale wall frame")
        XCTAssertFalse(fixed.hasRenderer, "#15: a disable mid-callback still recreated the CPU renderer/pool")
    }

    /// sol #7 #4/#15 — the RESIDUAL final race: the wall is ON at ACQUISITION (GPU
    /// obtained / CPU renderer created), then a disable lands BEFORE the actual render +
    /// emit (the post-acquisition GPU window; the post-`captureCPULock` CPU window). The
    /// acquisition gate already passed, so the pre-fix code rendered + emitted ONE stale
    /// tiled frame on BOTH paths. The emit-site re-check (`videoWallDisabledAtRenderSite`)
    /// at the actual render + emit sites closes it. Modelled single-threaded: the disable
    /// is injected right after acquisition via `_test_disableWallInPostAcquireWindow`.
    func testVideoWallDisableAfterAcquisitionEmitsNoStaleFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let side = 48
        let wall = VideoWall(rows: 2, cols: 2, mirror: false)

        func emittedFrame(forceCPU: Bool, skipEmitGate: Bool) throws -> Bool {
            let pipeline = SourceEffectPipeline(device: device, sourceID: SourceID("fx.wall.emit"),
                                                canvasWidth: side, canvasHeight: side)
            pipeline.update(SourceEffects(videoWall: wall))                 // wall ON at acquisition
            SourceEffectPipeline._test_forceCaptureGPUUnavailable = forceCPU
            SourceEffectPipeline._test_disableWallInPostAcquireWindow = true  // disable lands post-acquire
            SourceEffectPipeline._test_skipVideoWallEmitSiteGate = skipEmitGate
            defer {
                SourceEffectPipeline._test_forceCaptureGPUUnavailable = false
                SourceEffectPipeline._test_disableWallInPostAcquireWindow = false
                SourceEffectPipeline._test_skipVideoWallEmitSiteGate = false
            }
            let frame = try makeBGRAFrame(side: side, source: SourceID("fx.wall.emit"))
            return pipeline._test_applyVideoWallWithStaleSnapshot(frame, staleWall: wall) != nil
        }

        // GPU path: neg control emits the stale frame; the emit-site gate suppresses it.
        XCTAssertTrue(try emittedFrame(forceCPU: false, skipEmitGate: true),
                      "negative control vacuous (GPU): no stale frame even without the emit-site gate")
        XCTAssertFalse(try emittedFrame(forceCPU: false, skipEmitGate: false),
                       "#4/#15 (GPU): a disable in the post-acquisition window still emitted a stale tiled frame")
        // CPU path: neg control emits the stale frame; the emit-site gate suppresses it.
        XCTAssertTrue(try emittedFrame(forceCPU: true, skipEmitGate: true),
                      "negative control vacuous (CPU): no stale frame even without the emit-site gate")
        XCTAssertFalse(try emittedFrame(forceCPU: true, skipEmitGate: false),
                       "#4/#15 (CPU): a disable in the post-lock window still emitted a stale tiled frame")
    }

    // MARK: sol #8 #1 — a pending screen replacement is torn down on every exit path

    /// A pending HDR/SDR screen replacement (its async start not yet resolved) lives in a
    /// SIDE dictionary, NOT in `activeSources`. Pre-fix, neither `removeSource` nor
    /// `shutdown` touched it, so its capture kept resolving and its frame callback kept
    /// posting after the source was removed / the app shut down. The fix drains it (retire
    /// the gate + stop + clear) on both paths. Oracle: after the drain, no pending remains
    /// AND driving the (retired) callback posts nothing to the render mailbox.
    func testPendingScreenReplacementDrainedOnRemove() throws {
        try assertPendingReplacementDrained(viaShutdown: false)
    }
    func testPendingScreenReplacementDrainedOnShutdown() async throws {
        try await assertPendingReplacementDrainedShutdown()
    }

    private func assertPendingReplacementDrained(viaShutdown: Bool) throws {
        func postsAfterTeardown(skipDrain: Bool) throws -> (posted: Bool, pendingAfter: Int) {
            let engine = AppEngine()
            guard engine.renderLoop != nil else { throw XCTSkip("no Metal device") }
            let desc = SourceDescriptor(kind: .display, id: "display:1", name: "Display")
            let src = try ScreenSource(descriptor: desc,
                                       configuration: AppEngine.screenCaptureConfiguration(captureAudio: false, hdr: false))
            engine.integrationDebugRegisterScreenSource(src, descriptor: desc)
            let id = SourceID(desc.id)

            AppEngine._test_skipScreenSourceStart = true
            AppEngine._test_simulatedScreenStartOutcome = .none   // replacement stays PENDING
            AppEngine._test_skipPendingScreenDrain = skipDrain
            // sol #10 SERIALIZE: a pending replacement's gate is now deferred-armed (not live
            // until commit), so eagerly ARM it to exercise the sol #8 #1 drain/retire contract
            // on a LIVE gate (the drain must retire it; without the drain it leaks).
            AppEngine._test_armReplacementGateEagerly = true
            defer {
                AppEngine._test_skipScreenSourceStart = false
                AppEngine._test_simulatedScreenStartOutcome = .none
                AppEngine._test_skipPendingScreenDrain = false
                AppEngine._test_armReplacementGateEagerly = false
            }
            engine.setHDREnabled(true)
            guard engine.hdrEnabled else { throw XCTSkip("HDR toggle did not take") }
            let handles = try XCTUnwrap(engine._test_pendingScreenReplacementHandles(for: id),
                                        "expected a pending screen replacement after the HDR toggle")
            let before = handles.mailbox.stats.delivered

            engine.removeSource(id)   // remove path (shutdown variant tested separately)

            // Drive a frame through the (now-drained) replacement's capture callback.
            let frame = try makeBGRAFrame(side: 16, source: id)
            handles.source.onFrame?(frame)
            return (handles.mailbox.stats.delivered > before, engine._test_pendingScreenReplacementCount())
        }

        // NEGATIVE CONTROL: without the drain the pending survives and posts after removal.
        let neg = try postsAfterTeardown(skipDrain: true)
        XCTAssertEqual(neg.pendingAfter, 1, "negative control vacuous: the pending replacement was already cleared")
        XCTAssertTrue(neg.posted, "negative control vacuous: a post-removal frame did not leak even without the drain")
        // FIX: removeSource drains the pending replacement — cleared, and no post-removal frame.
        let fixed = try postsAfterTeardown(skipDrain: false)
        XCTAssertEqual(fixed.pendingAfter, 0, "#1: removeSource did not clear the pending screen replacement")
        XCTAssertFalse(fixed.posted, "#1: a pending screen replacement posted a frame after removeSource")
    }

    private func assertPendingReplacementDrainedShutdown() async throws {
        func postsAfterShutdown(skipDrain: Bool) async throws -> (posted: Bool, pendingAfter: Int) {
            let engine = AppEngine()
            guard engine.renderLoop != nil else { throw XCTSkip("no Metal device") }
            let desc = SourceDescriptor(kind: .display, id: "display:1", name: "Display")
            let src = try ScreenSource(descriptor: desc,
                                       configuration: AppEngine.screenCaptureConfiguration(captureAudio: false, hdr: false))
            engine.integrationDebugRegisterScreenSource(src, descriptor: desc)
            let id = SourceID(desc.id)

            AppEngine._test_skipScreenSourceStart = true
            AppEngine._test_simulatedScreenStartOutcome = .none
            AppEngine._test_skipPendingScreenDrain = skipDrain
            // sol #10 SERIALIZE: a pending replacement's gate is now deferred-armed (not live
            // until commit), so eagerly ARM it to exercise the sol #8 #1 drain/retire contract
            // on a LIVE gate (the drain must retire it; without the drain it leaks).
            AppEngine._test_armReplacementGateEagerly = true
            defer {
                AppEngine._test_skipScreenSourceStart = false
                AppEngine._test_simulatedScreenStartOutcome = .none
                AppEngine._test_skipPendingScreenDrain = false
                AppEngine._test_armReplacementGateEagerly = false
            }
            engine.setHDREnabled(true)
            guard engine.hdrEnabled else { throw XCTSkip("HDR toggle did not take") }
            let handles = try XCTUnwrap(engine._test_pendingScreenReplacementHandles(for: id))
            let before = handles.mailbox.stats.delivered

            await engine.shutdown()

            let frame = try makeBGRAFrame(side: 16, source: id)
            handles.source.onFrame?(frame)
            return (handles.mailbox.stats.delivered > before, engine._test_pendingScreenReplacementCount())
        }

        let neg = try await postsAfterShutdown(skipDrain: true)
        XCTAssertEqual(neg.pendingAfter, 1, "negative control vacuous: the pending replacement was already cleared")
        XCTAssertTrue(neg.posted, "negative control vacuous: a post-shutdown frame did not leak even without the drain")
        let fixed = try await postsAfterShutdown(skipDrain: false)
        XCTAssertEqual(fixed.pendingAfter, 0, "#1: shutdown did not clear the pending screen replacement")
        XCTAssertFalse(fixed.posted, "#1: a pending screen replacement posted a frame after shutdown")
    }

    // MARK: sol #8 #2 — a late RESTORE must honor the CURRENT HDR mode at commit

    /// Commit HDR → the live HDR source fails post-commit → an SDR restore (prior mode) is
    /// queued and kept PENDING → toggle HDR off then on. The restore's late success then
    /// committed regardless (restore was EXEMPT from the mode gate), leaving the live source
    /// `preferHDR == false` while `hdrEnabled == true` — a stale mode. The fix keys on
    /// `hdrModeEpoch`: because the mode was TOGGLED while the restore was in flight the
    /// restore is stale → re-derived to the CURRENT (HDR) mode at commit. Oracle: the final
    /// live screen source's `preferHDR` equals `hdrEnabled`. (An UNtoggled post-failure
    /// fallback is still committed as-is — see `testPostCommitScreenFailureSurfacesErrorAndRestoresPrior`.)
    func testLateScreenRestoreHonorsCurrentHDRMode() throws {
        func finalPreferHDR(exemptRestore: Bool) throws -> Bool? {
            let engine = AppEngine()
            guard engine.renderLoop != nil else { throw XCTSkip("no Metal device") }
            let desc = SourceDescriptor(kind: .display, id: "display:1", name: "Display")
            let src = try ScreenSource(descriptor: desc,
                                       configuration: AppEngine.screenCaptureConfiguration(captureAudio: false, hdr: false))
            engine.integrationDebugRegisterScreenSource(src, descriptor: desc)
            let id = SourceID(desc.id)

            AppEngine._test_skipScreenSourceStart = true
            AppEngine._test_exemptRestoreFromModeGate = exemptRestore
            defer {
                AppEngine._test_skipScreenSourceStart = false
                AppEngine._test_simulatedScreenStartOutcome = .none
                AppEngine._test_exemptRestoreFromModeGate = false
            }
            // Commit HDR (live = HDR, hdrEnabled = true).
            AppEngine._test_simulatedScreenStartOutcome = .success
            engine.setHDREnabled(true)
            guard engine.hdrEnabled, engine.integrationDebugScreenSourcePreferHDR(id) == true else {
                throw XCTSkip("HDR toggle/commit did not take")
            }
            // Post-commit failure of the live HDR source → queues an SDR restore, kept pending.
            AppEngine._test_simulatedScreenStartOutcome = .none
            engine._test_failLiveScreenSource(id)
            // Toggle HDR off then on WHILE the restore is pending — the finding's exact window.
            engine.setHDREnabled(false)
            engine.setHDREnabled(true)
            guard engine.hdrEnabled else { throw XCTSkip("HDR toggle-back did not take") }

            // Fire the pending late successes to convergence (a stale restore orphans +
            // re-issues a correct-mode replacement, which the next round commits).
            for _ in 0..<8 where engine._test_fireAllPendingScreenCommits(id) != 0 {}
            return engine.integrationDebugScreenSourcePreferHDR(id)
        }

        // NEGATIVE CONTROL: the exempt restore commits the stale SDR source while HDR is on.
        XCTAssertEqual(try finalPreferHDR(exemptRestore: true), false,
                       "negative control vacuous: the stale SDR restore did not commit even when exempt")
        // FIX: the live source ends matching the current show (HDR), not the stale restore mode.
        XCTAssertEqual(try finalPreferHDR(exemptRestore: false), true,
                       "#2: a late SDR restore committed a stale-mode source (preferHDR != hdrEnabled)")
    }

    // MARK: sol #8 #3 — the video-wall disabled-check is ATOMIC with the emit

    /// The residual window: after `applyVideoWall` returns the tiled buffer, the caller
    /// (`onFrame`) does the taps + `mailbox.post` LATER — a disable landing THERE leaked one
    /// stale tiled frame on both paths. The fix performs the final disabled-check AND the
    /// emit under a SINGLE `stateLock` hold (`processAndEmit`). The hook fires exactly in
    /// that window (post-tile, pre-post) and disables the wall; the gate must then emit the
    /// UNTILED pre-wall frame. Oracle: the untiled pre-wall frame IS the input pixel buffer
    /// (identity chain); the tiled frame is a fresh buffer — pointer identity distinguishes them.
    func testVideoWallDisableAtEmitSiteEmitsNoStaleFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let side = 48
        let wall = VideoWall(rows: 2, cols: 2, mirror: false)

        func emittedStaleTiled(forceCPU: Bool, skipAtomicGate: Bool) throws -> Bool {
            let pipeline = SourceEffectPipeline(device: device, sourceID: SourceID("fx.wall.atomic"),
                                                canvasWidth: side, canvasHeight: side)
            pipeline.update(SourceEffects(videoWall: wall))   // wall ON
            SourceEffectPipeline._test_forceCaptureGPUUnavailable = forceCPU
            SourceEffectPipeline._test_skipAtomicEmitGate = skipAtomicGate
            // Disable the wall in the EXACT residual window: after tiling, before the post.
            SourceEffectPipeline._test_emitSiteHook = { [weak pipeline] in pipeline?._test_disableWallNow() }
            defer {
                SourceEffectPipeline._test_forceCaptureGPUUnavailable = false
                SourceEffectPipeline._test_skipAtomicEmitGate = false
                SourceEffectPipeline._test_emitSiteHook = nil
            }
            let input = try makeBGRAFrame(side: side, source: SourceID("fx.wall.atomic"))
            var emitted: VideoFrame?
            // The program `post` frame is the wave-9 emit-site oracle (tiled vs untiled); taps
            // are irrelevant to this gate, so a no-op taps closure keeps the control valid.
            pipeline.processAndEmit(input, post: { emitted = $0 }, taps: { _ in })
            let out = try XCTUnwrap(emitted, "processAndEmit delivered no frame")
            let tiled = Unmanaged.passUnretained(out.pixelBuffer).toOpaque()
                      != Unmanaged.passUnretained(input.pixelBuffer).toOpaque()
            return tiled
        }

        // GPU path: neg control leaks the stale tiled frame; the atomic gate emits the untiled one.
        XCTAssertTrue(try emittedStaleTiled(forceCPU: false, skipAtomicGate: true),
                      "negative control vacuous (GPU): no stale tiled frame even without the atomic gate")
        XCTAssertFalse(try emittedStaleTiled(forceCPU: false, skipAtomicGate: false),
                       "#3 (GPU): a disable at the emit site still emitted a stale tiled frame")
        // CPU path: same.
        XCTAssertTrue(try emittedStaleTiled(forceCPU: true, skipAtomicGate: true),
                      "negative control vacuous (CPU): no stale tiled frame even without the atomic gate")
        XCTAssertFalse(try emittedStaleTiled(forceCPU: true, skipAtomicGate: false),
                       "#3 (CPU): a disable at the emit site still emitted a stale tiled frame")
    }

    // MARK: sol #8 #4 — a partial MULTI-victim rollback preserves LRU order

    /// TWO victims (g1 oldest, g2) are evicted for a big g4; g3 survives. g4 construction
    /// fails AND g1's re-decode ALSO fails (double failure) while g2 is re-admitted. The
    /// prior fix reinserted g2 at its stale raw index 1 → `[g3,g2]`, so the next eviction
    /// wrongly picked the newer g3. The structural rebuild reproduces the true pre-eviction
    /// order → `[g2,g3]`. Oracle: the FRONT (next-evicted) LRU entry is the re-admitted g2.
    func testPartialMultiVictimRollbackPreservesLRUOrder() throws {
        let g1 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: 90)
        let g2 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: 90)
        let g3 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: 90)
        let g4 = try makeAnimatedGIFRect(w: 1280, h: 720, frames: 180)   // ~2× the others' cost
        let each = AppEngine.estimatedAnimatedByteCost(url: g1, mode: .insert)
        let big = AppEngine.estimatedAnimatedByteCost(url: g4, mode: .insert)

        func frontAfterRollback(skipLRURestore: Bool) throws -> (front: SourceID?, count: Int, g2id: SourceID?, g3id: SourceID?) {
            let engine = AppEngine()
            let ceiling = engine.integrationDebugAnimatedMemeBytes.ceiling
            XCTAssertLessThanOrEqual(each * 3, ceiling, "three small fixtures must fit together")
            XCTAssertGreaterThan(each * 4, ceiling, "a fourth small fixture must exceed the ceiling")
            XCTAssertGreaterThan(each * 2 + big, ceiling, "g4 must force evicting the two oldest")
            XCTAssertLessThanOrEqual(each + big, ceiling, "g4 must fit once the two oldest are evicted")

            engine.addGIFSource(fileURL: g1)   // oldest
            engine.addGIFSource(fileURL: g2)
            engine.addGIFSource(fileURL: g3)   // newest survivor
            AppEngine._test_rollbackSkipLRURestore = skipLRURestore
            AppEngine._test_forcedAnimatedConstructionFailuresRemaining = 2  // g4 admit + g1 re-decode
            defer {
                AppEngine._test_rollbackSkipLRURestore = false
                AppEngine._test_forcedAnimatedConstructionFailuresRemaining = 0
            }
            engine.addGIFSource(fileURL: g4)   // evicts g1,g2 → g4 fails → rollback (g1 re-decode fails)

            let lru = engine._test_animatedMediaLRU()
            return (lru.first, lru.count,
                    engine.integrationDebugAnimatedGIFSourceID(for: g2),
                    engine.integrationDebugAnimatedGIFSourceID(for: g3))
        }

        // NEGATIVE CONTROL: without the rebuild, g2 is appended last → the newer g3 is at the front.
        let neg = try frontAfterRollback(skipLRURestore: true)
        XCTAssertEqual(neg.count, 2, "g1 permanently lost (re-decode failed); g2 + g3 remain")
        XCTAssertEqual(neg.front, neg.g3id, "negative control vacuous: g3 was not wrongly at the front")
        // FIX: the true pre-eviction order is rebuilt → g2 (older) is the front, evicted before g3.
        let fixed = try frontAfterRollback(skipLRURestore: false)
        XCTAssertEqual(fixed.count, 2, "g1 permanently lost (re-decode failed); g2 + g3 remain")
        XCTAssertEqual(fixed.front, fixed.g2id,
                       "#4: partial multi-victim rollback reordered the LRU — the next eviction would pick the newer g3")
    }

    // MARK: sol #9 #1 — the frame callback's liveness check is ATOMIC with the post (TOCTOU)

    /// The wave-9 gate checked `gate.isLive` (lock released) and posted LATER — a teardown
    /// landing in that gap posted a frame to a detached mailbox after the replacement was
    /// retired. The fix performs the check AND the post under a SINGLE hold of the gate lock
    /// `retire()` takes. Reproduce the EXACT window: fire a hook between the check and the post
    /// that retires the gate; the atomic path must deliver NOTHING, the separate-boolean
    /// negative control leaks. Oracle: the render mailbox's delivered count does not advance.
    func testScreenFrameCallbackCheckAndPostAreAtomic() throws {
        func posted(separateBooleanGate: Bool) throws -> Bool {
            let engine = AppEngine()
            guard engine.renderLoop != nil else { throw XCTSkip("no Metal device") }
            let desc = SourceDescriptor(kind: .display, id: "display:1", name: "Display")
            let src = try ScreenSource(descriptor: desc,
                                       configuration: AppEngine.screenCaptureConfiguration(captureAudio: false, hdr: false))
            engine.integrationDebugRegisterScreenSource(src, descriptor: desc)
            let id = SourceID(desc.id)

            AppEngine._test_skipScreenSourceStart = true
            AppEngine._test_simulatedScreenStartOutcome = .none   // stays PENDING
            ScreenReplacementGate._test_useSeparateBooleanGate = separateBooleanGate
            // sol #10 SERIALIZE: the pending replacement gate is deferred-armed — arm it eagerly
            // so this exercises the sol #9 #1 atomic check+post contract on a LIVE gate.
            AppEngine._test_armReplacementGateEagerly = true
            defer {
                AppEngine._test_skipScreenSourceStart = false
                AppEngine._test_simulatedScreenStartOutcome = .none
                ScreenReplacementGate._test_useSeparateBooleanGate = false
                ScreenReplacementGate._test_gateWindowHook = nil
                AppEngine._test_armReplacementGateEagerly = false
            }
            engine.setHDREnabled(true)
            guard engine.hdrEnabled else { throw XCTSkip("HDR toggle did not take") }
            let handles = try XCTUnwrap(engine._test_pendingScreenReplacementHandles(for: id))
            let gate = try XCTUnwrap(engine._test_pendingScreenGate(for: id))
            let before = handles.mailbox.stats.delivered
            // The teardown lands in the exact check→post window: retire the gate right there.
            ScreenReplacementGate._test_gateWindowHook = { gate.retire() }

            let frame = try makeBGRAFrame(side: 16, source: id)
            handles.source.onFrame?(frame)
            return handles.mailbox.stats.delivered > before
        }

        // NEGATIVE CONTROL: the pre-fix separate boolean gate posts after the mid-window retire.
        XCTAssertTrue(try posted(separateBooleanGate: true),
                      "negative control vacuous: no leak even with the separate check-then-post gate")
        // FIX: the atomic check+post drops the frame when the gate retires in the window.
        XCTAssertFalse(try posted(separateBooleanGate: false),
                       "#1: a frame posted after the gate retired between the check and the post")
    }

    /// The pending AUDIO callback was WHOLLY ungated — a valid packet advanced the mixer
    /// channel even after remove/shutdown. It is now gated by the SAME atomic gate as the
    /// frame callback. Reproduce: drain the replacement, then drive its audio callback; the
    /// channel's buffered-frame count must NOT advance. Negative control: the ungated
    /// (separate-boolean) path advances it.
    func testScreenAudioCallbackIsGatedAtomically() throws {
        func advanced(separateBooleanGate: Bool) throws -> Bool {
            let engine = AppEngine()
            guard engine.renderLoop != nil else { throw XCTSkip("no Metal device") }
            let desc = SourceDescriptor(kind: .display, id: "display:1", name: "Display")
            let src = try ScreenSource(descriptor: desc,
                                       configuration: AppEngine.screenCaptureConfiguration(captureAudio: true, hdr: false))
            engine.integrationDebugRegisterScreenSource(src, descriptor: desc)
            let id = SourceID(desc.id)
            engine._test_addAudioChannel(id: id)   // so the replacement wires its audio callback

            AppEngine._test_skipScreenSourceStart = true
            AppEngine._test_simulatedScreenStartOutcome = .none
            ScreenReplacementGate._test_useSeparateBooleanGate = separateBooleanGate
            // sol #10 SERIALIZE: the pending replacement gate is deferred-armed — arm it eagerly
            // so this exercises the sol #9 #1 atomic check+post contract on a LIVE gate.
            AppEngine._test_armReplacementGateEagerly = true
            defer {
                AppEngine._test_skipScreenSourceStart = false
                AppEngine._test_simulatedScreenStartOutcome = .none
                ScreenReplacementGate._test_useSeparateBooleanGate = false
                ScreenReplacementGate._test_gateWindowHook = nil
                AppEngine._test_armReplacementGateEagerly = false
            }
            engine.setHDREnabled(true)
            guard engine.hdrEnabled else { throw XCTSkip("HDR toggle did not take") }
            let handles = try XCTUnwrap(engine._test_pendingScreenReplacementHandles(for: id))
            guard handles.source.onAudio != nil else { throw XCTSkip("replacement has no audio callback") }
            let gate = try XCTUnwrap(engine._test_pendingScreenGate(for: id))
            let before = try XCTUnwrap(engine._test_audioChannelBufferedFrames(id: id))
            // Teardown retires the gate in the callback window (models remove/shutdown landing there).
            ScreenReplacementGate._test_gateWindowHook = { gate.retire() }

            let signal = TransientSelfTest.sine(count: 256, amplitude: 0.4, frequency: 440, sampleRate: 48_000)
            let packet = try TransientSelfTest.makeProgramPacket(signal: signal, channelCount: 2,
                                                                 sampleRate: 48_000, startSample: 0)
            handles.source.onAudio?(packet)
            let after = try XCTUnwrap(engine._test_audioChannelBufferedFrames(id: id))
            return after > before
        }

        // NEGATIVE CONTROL: the ungated (separate-boolean) audio callback advances the channel.
        XCTAssertTrue(try advanced(separateBooleanGate: true),
                      "negative control vacuous: audio did not advance even without the atomic gate")
        // FIX: the atomically-gated audio callback advances nothing once the gate retires.
        XCTAssertFalse(try advanced(separateBooleanGate: false),
                       "#1: an audio packet advanced the channel after the gate retired in the callback window")
    }

    // MARK: sol #9 #2 — a drained stale success must not replace a same-id re-add

    /// Sequence: an HDR replacement P is PENDING → `removeSource` drains P and the source →
    /// a fresh SDR source X is re-added under the SAME id → P's late `onStarted` (commit) fires.
    /// Pre-fix, commit removed a (now-absent) pending record without checking it, then stopped
    /// X and installed the retired, gate-dead P → a dark active screen. The fix requires the
    /// pending record to still be registered; a drained/superseded late commit is a NO-OP.
    /// Oracle: the active source for the id stays X (SDR: `preferHDR == false`), not P (HDR).
    func testDrainedStaleCommitDoesNotReplaceReAdd() throws {
        func activePreferHDRAfterStaleCommit(skipIdentityCheck: Bool) throws -> Bool? {
            let engine = AppEngine()
            guard engine.renderLoop != nil else { throw XCTSkip("no Metal device") }
            let desc = SourceDescriptor(kind: .display, id: "display:1", name: "Display")
            let original = try ScreenSource(descriptor: desc,
                                            configuration: AppEngine.screenCaptureConfiguration(captureAudio: false, hdr: false))
            engine.integrationDebugRegisterScreenSource(original, descriptor: desc)
            let id = SourceID(desc.id)

            AppEngine._test_skipScreenSourceStart = true
            AppEngine._test_simulatedScreenStartOutcome = .none    // P stays PENDING (HDR)
            AppEngine._test_skipCommitPendingIdentityCheck = skipIdentityCheck
            defer {
                AppEngine._test_skipScreenSourceStart = false
                AppEngine._test_simulatedScreenStartOutcome = .none
                AppEngine._test_skipCommitPendingIdentityCheck = false
            }
            engine.setHDREnabled(true)
            guard engine.hdrEnabled else { throw XCTSkip("HDR toggle did not take") }
            let p = try XCTUnwrap(engine._test_pendingScreenReplacementHandles(for: id))  // P (HDR)

            // Drain P (and the source), then re-add a fresh SDR source X under the same id.
            engine.removeSource(id)
            let x = try ScreenSource(descriptor: desc,
                                     configuration: AppEngine.screenCaptureConfiguration(captureAudio: false, hdr: false))
            engine.integrationDebugRegisterScreenSource(x, descriptor: desc)
            XCTAssertEqual(engine.integrationDebugScreenSourcePreferHDR(id), false, "X is SDR before the stale commit")

            // P's late onStarted arrives — hdrEnabled is still true so P's HDR mode matches
            // (the mode gate would NOT catch it; only the pending-identity check does).
            engine._test_commitScreenReplacementDirect(id: id, source: p.source,
                                                        mailbox: p.mailbox, descriptor: desc)
            return engine.integrationDebugScreenSourcePreferHDR(id)
        }

        // NEGATIVE CONTROL: without the identity check the stale HDR P replaces X (dark HDR source).
        XCTAssertEqual(try activePreferHDRAfterStaleCommit(skipIdentityCheck: true), true,
                       "negative control vacuous: the stale P did not replace X even without the check")
        // FIX: the drained late commit is a NO-OP — X (SDR) stays the active source.
        XCTAssertEqual(try activePreferHDRAfterStaleCommit(skipIdentityCheck: false), false,
                       "#2: a drained stale commit stopped the same-id re-add and installed a retired source")
    }

    // MARK: sol #9 #5 — the emit lock must not hold observer taps (reentrancy deadlock)

    /// The wave-9 single-lock emit ran the FULL emit (mailbox post AND observer taps) under
    /// `stateLock`; a tap that synchronously reads pipeline state (which takes `stateLock`)
    /// deadlocks the non-recursive lock. The fix keeps only the program `post` under the lock
    /// and runs `taps` outside it. Oracle: a reentrant tap COMPLETES within a timeout; the
    /// pre-fix taps-under-lock negative control does NOT (deadlock). Runs on a background queue
    /// with a timeout so the deadlocking control fails the assertion instead of hanging the suite.
    func testReentrantObserverTapDoesNotDeadlock() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let side = 32

        func completes(tapsInsideLock: Bool) throws -> Bool {
            let pipeline = SourceEffectPipeline(device: device, sourceID: SourceID("fx.reentrant"),
                                                canvasWidth: side, canvasHeight: side)
            pipeline.update(SourceEffects(videoWall: VideoWall(rows: 2, cols: 2, mirror: false)))  // wall ON → gate taken
            SourceEffectPipeline._test_runTapsInsideLock = tapsInsideLock
            let input = try makeBGRAFrame(side: side, source: SourceID("fx.reentrant"))
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                pipeline.processAndEmit(input, post: { _ in }, taps: { _ in
                    _ = pipeline.currentEffects()   // reentrant read → takes stateLock
                })
                done.signal()
            }
            let finished = done.wait(timeout: .now() + 3) == .success
            // Leave the seam reset only on the path that actually completed (a deadlocked
            // background thread still holds it; a fresh pipeline per call keeps tests isolated).
            if finished { SourceEffectPipeline._test_runTapsInsideLock = false }
            return finished
        }

        // NEGATIVE CONTROL: taps under the lock → the reentrant read self-deadlocks (never completes).
        XCTAssertFalse(try completes(tapsInsideLock: true),
                       "negative control vacuous: no deadlock even with the taps run under the emit lock")
        // FIX: taps outside the lock → the reentrant read is safe and delivery completes.
        XCTAssertTrue(try completes(tapsInsideLock: false),
                      "#5: a reentrant observer tap deadlocked under the emit lock")
    }

    // MARK: - Fixtures

    private func makeBGRAFrame(side: Int, source: SourceID) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: side, height: side,
                                       pixelFormat: kCVPixelFormatType_32BGRA)
        let buffer = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let p = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<side {
                for x in 0..<side {
                    let o = y * bytesPerRow + x * 4
                    p[o] = UInt8((x * 255) / max(1, side - 1))       // B gradient
                    p[o + 1] = UInt8((y * 255) / max(1, side - 1))   // G gradient
                    p[o + 2] = 128
                    p[o + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return VideoFrame(pixelBuffer: buffer, pts: HouseClock.now(), source: source)
    }

    private func makeAnimatedGIF(colors: [(CGFloat, CGFloat, CGFloat)], delay: Double, side: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-w5-\(UUID().uuidString).gif")
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                        colors.count, nil) else {
            throw NSError(domain: "test", code: 1)
        }
        let gifProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(dst, gifProps as CFDictionary)
        let cs = CGColorSpaceCreateDeviceRGB()
        for (r, g, b) in colors {
            let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
            CGImageDestinationAddImage(dst, ctx.makeImage()!, frameProps as CFDictionary)
        }
        guard CGImageDestinationFinalize(dst) else { throw NSError(domain: "test", code: 2) }
        return url
    }

    private func makeAnimatedGIFRect(w: Int, h: Int, frames: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-w5r-\(UUID().uuidString).gif")
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                        frames, nil) else {
            throw NSError(domain: "test", code: 1)
        }
        CGImageDestinationSetProperties(dst, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let cs = CGColorSpaceCreateDeviceRGB()
        for i in 0..<frames {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let f = CGFloat(i) / CGFloat(max(1, frames))
            ctx.setFillColor(red: f, green: 1 - f, blue: 0.5, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            CGImageDestinationAddImage(dst, ctx.makeImage()!,
                                       [kCGImagePropertyGIFDictionary:
                                        [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dst) else { throw NSError(domain: "test", code: 2) }
        return url
    }
}
