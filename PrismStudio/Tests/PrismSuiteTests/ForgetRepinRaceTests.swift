import CoreMedia
import CoreVideo
import Metal
import os
import XCTest

import PrismCompose
@testable import PrismCompositor
import PrismCore

/// Regression tests for the IOSurface re-pin race (gpt-5.6-sol F1 + F22).
///
/// The defect: a render tick snapshots its source frames, then a control thread
/// removes the source (`removeMailbox`/`forget`), yet the already-in-flight tick
/// still folds the removed source's frame back into the compositor's last-known
/// set AFTER `forget`. With the mailbox gone, nothing ever forgets it again, so
/// the IOSurface stays pinned forever. sol's barrier probe observed the held set
/// go from `[]` immediately after removal to `["probe.removed"]` after the
/// in-flight tick completed.
///
/// The fix tombstones a forgotten source so `foldAndSnapshot` rejects any stale
/// snapshotted frame for it until a genuine re-`attach`. These tests reproduce
/// the exact interleaving and assert the surface is NOT re-pinned.
final class ForgetRepinRaceTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    /// A valid IOSurface-backed BGRA frame for `id` (pixels irrelevant — the
    /// test is about retention/pinning, not color).
    private func frame(_ id: SourceID, w: Int = 64, h: Int = 64) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_32BGRA)
        return VideoFrame(pixelBuffer: try pool.makeBuffer(), pts: HouseClock.now(), source: id)
    }

    // MARK: - F1: primary RenderLoop / MetalCompositor

    /// Faithful reproduction of sol's render-thread barrier: a `sceneProvider`
    /// parks the in-flight tick AFTER it has taken the source's frame but BEFORE
    /// it composites; the control thread then `removeMailbox`es the source; the
    /// tick is released and must NOT re-pin it.
    func testInFlightTickDoesNotRepinRemovedSource() throws {
        let compositor = try MetalCompositor(device: try device(), width: 320, height: 180)
        let loop = RenderLoop(compositor: compositor, fps: 120)

        let id = SourceID("probe.removed")
        let box = FrameMailbox()
        box.post(try frame(id))
        loop.setMailbox(box, for: id)
        let sceneX = Scene(name: "probe", layers: [Layer(sourceID: id)])
        loop.scene = sceneX

        let atBarrier = DispatchSemaphore(value: 0)
        let releaseBarrier = DispatchSemaphore(value: 0)
        let barrierOnce = OSAllocatedUnfairLock(initialState: false)
        // Ensure a wedged render thread can never outlive the test.
        defer { releaseBarrier.signal(); loop.stop() }

        loop.sceneProvider = { _ in
            let first = barrierOnce.withLock { hit -> Bool in
                if hit { return false }; hit = true; return true
            }
            if first {
                atBarrier.signal()      // frame already taken; announce we're parked
                releaseBarrier.wait()   // hold here until the source has been removed
            }
            return sceneX
        }

        loop.start()
        // The in-flight tick has taken the frame and is parked in the provider.
        XCTAssertEqual(atBarrier.wait(timeout: .now() + 3.0), .success,
                       "render thread never reached the barrier")

        // Control thread removes the source. Matches sol: held == [] right after.
        loop.removeMailbox(for: id)
        XCTAssertFalse(compositor.heldSourceIDs.contains(id),
                       "forget did not drop the last-known frame")

        // Release the in-flight tick: it now folds its already-taken frame.
        releaseBarrier.signal()

        // Let the released tick (and a few more) complete.
        XCTAssertTrue(pollUntil(1.0) { loop.stats.framesDelivered >= 1 }, "no frame delivered after release")
        Thread.sleep(forTimeInterval: 0.1)
        loop.stop()

        // The forgotten source must NOT have been re-pinned by the stale tick.
        XCTAssertFalse(compositor.heldSourceIDs.contains(id),
                       "in-flight tick re-pinned the forgotten source's IOSurface")
    }

    /// Minimal, provider-free reproduction at the compositor boundary: a frame
    /// dict snapshotted before `forget`, folded after it, must be rejected.
    func testForgetRejectsLaterStaleFold() throws {
        let compositor = try MetalCompositor(device: try device(), width: 128, height: 128)
        let id = SourceID("stale.fold")
        let scene = Scene(name: "s", layers: [Layer(sourceID: id)])

        // Establish the source as held.
        _ = try compositor.composite(frames: [id: try frame(id)], scene: scene, pts: HouseClock.now())
        XCTAssertTrue(compositor.heldSourceIDs.contains(id))

        // Forget it, then replay a stale dict (as an in-flight tick would).
        compositor.forget(source: id)
        XCTAssertFalse(compositor.heldSourceIDs.contains(id))
        _ = try compositor.composite(frames: [id: try frame(id)], scene: scene, pts: HouseClock.now())
        XCTAssertFalse(compositor.heldSourceIDs.contains(id),
                       "stale fold re-pinned a forgotten source")

        // A genuine re-attach lets it compose again (re-registration is not broken).
        compositor.attach(source: id)
        _ = try compositor.composite(frames: [id: try frame(id)], scene: scene, pts: HouseClock.now())
        XCTAssertTrue(compositor.heldSourceIDs.contains(id), "re-attach did not restore folding")
    }

    /// N1: a forget-tombstone must NOT live forever. Meme churn forgets sources
    /// under fresh UUIDs that are never re-attached, so `attach` never prunes them.
    /// After a bounded number of clean ticks the tombstone is pruned — while a
    /// stale fold WITHIN the window is still rejected (F1 protection intact).
    func testForgetTombstoneIsBoundedButStillRejectsStaleFold() throws {
        let compositor = try MetalCompositor(device: try device(), width: 128, height: 128)
        let gone = SourceID("meme.churn"), keep = SourceID("keep")
        let scene = Scene(name: "s", layers: [Layer(sourceID: keep), Layer(sourceID: gone)])

        // Establish both as held.
        _ = try compositor.composite(frames: [keep: try frame(keep), gone: try frame(gone)],
                                     scene: scene, pts: HouseClock.now())

        // Forget the churned source → tombstoned.
        compositor.forget(source: gone)
        XCTAssertTrue(compositor.tombstonedSourceIDs.contains(gone), "forget must tombstone the source")

        // F1 protection intact: the immediately-following (stale) fold carrying a
        // pre-forget frame for `gone` is STILL rejected inside the window.
        _ = try compositor.composite(frames: [keep: try frame(keep), gone: try frame(gone)],
                                     scene: scene, pts: HouseClock.now())
        XCTAssertFalse(compositor.heldSourceIDs.contains(gone),
                       "stale fold re-pinned a forgotten source within the re-pin window")

        // After a few more clean ticks (no in-flight tick can predate the forget
        // any longer) the tombstone is pruned — it does not leak forever.
        for _ in 0..<4 {
            _ = try compositor.composite(frames: [keep: try frame(keep)], scene: scene, pts: HouseClock.now())
        }
        XCTAssertFalse(compositor.tombstonedSourceIDs.contains(gone),
                       "tombstone for a never-re-attached (meme-churn) source leaked forever (N1)")
        XCTAssertFalse(compositor.heldSourceIDs.contains(gone),
                       "pruning must not resurrect the forgotten source")
    }

    /// N1 for the secondary program: `DualProgram.forgotten` must also be bounded.
    func testDualProgramForgottenSetIsBounded() throws {
        let secondary = try SecondaryComposition(device: try device(), width: 270, height: 480)
        let dual = DualProgram(secondary: secondary)
        let gone = SourceID("dual.churn"), keep = SourceID("keep")
        dual.scene = Scene(name: "v", layers: [Layer(sourceID: keep)])

        dual.forget(source: gone)
        XCTAssertTrue(dual.forgottenSourceIDs.contains(gone), "forget must add to the filter set")

        // A stale pre-forget frame submitted right after forget is still filtered
        // (it never re-pins in the secondary compositor).
        dual.submit(frames: [gone: try frame(gone), keep: try frame(keep)], pts: HouseClock.now())

        // Under churn (fresh submits), the never-re-attached id is pruned.
        for _ in 0..<4 { dual.submit(frames: [keep: try frame(keep)], pts: HouseClock.now()) }
        XCTAssertFalse(dual.forgottenSourceIDs.contains(gone),
                       "DualProgram.forgotten leaked a never-re-attached source (N1)")
        XCTAssertFalse(secondary.compositor.heldSourceIDs.contains(gone),
                       "the forgotten source must never have been re-pinned")
    }

    // MARK: - HIGH-3: rapid reattach must not resurrect stale content

    /// The reopened F1 (sol re-verify #2): a tick pulls source A's frame, control
    /// `forget`s A and IMMEDIATELY reattaches a NEW mailbox under the same id
    /// (clearing the tombstone), then the old in-flight tick folds — and used to
    /// re-pin A's OLD pre-forget frame. If the new source stalls, those stale
    /// pixels persist. The epoch guard must reject the stale fold even though the
    /// tombstone was cleared by the reattach, while a genuinely fresh post-attach
    /// frame still shows.
    ///
    /// Reproduction (pre-fix this FAILS: the reattach cleared the tombstone and
    /// nothing else rejected the stale frame, so `retainedFrame(for: A)` was the
    /// OLD buffer):
    func testRapidReattachDoesNotResurrectStalePreForgetFrame() throws {
        let compositor = try MetalCompositor(device: try device(), width: 320, height: 180)
        let loop = RenderLoop(compositor: compositor, fps: 120)

        let id = SourceID("rapid.reattach")
        let oldFrame = try frame(id)
        let oldBox = FrameMailbox()
        oldBox.post(oldFrame)
        loop.setMailbox(oldBox, for: id)          // attach → epoch E1
        let sceneX = Scene(name: "probe", layers: [Layer(sourceID: id)])
        loop.scene = sceneX

        let atBarrier = DispatchSemaphore(value: 0)
        let releaseBarrier = DispatchSemaphore(value: 0)
        let barrierOnce = OSAllocatedUnfairLock(initialState: false)
        defer { releaseBarrier.signal(); loop.stop() }

        loop.sceneProvider = { _ in
            let first = barrierOnce.withLock { hit -> Bool in
                if hit { return false }; hit = true; return true
            }
            if first { atBarrier.signal(); releaseBarrier.wait() }
            return sceneX
        }

        loop.start()
        XCTAssertEqual(atBarrier.wait(timeout: .now() + 3.0), .success,
                       "render thread never reached the barrier (already pulled A's OLD frame)")

        // Control: forget A, then IMMEDIATELY reattach a NEW (stalled/empty)
        // mailbox under the SAME id — the reattach clears the tombstone.
        loop.removeMailbox(for: id)               // forget → epoch E2
        let newBox = FrameMailbox()               // new source has not emitted yet
        loop.setMailbox(newBox, for: id)          // attach → epoch E3 (tombstone cleared)

        // Release the parked tick: it folds its already-pulled OLD frame.
        releaseBarrier.signal()
        XCTAssertTrue(pollUntil(1.0) { loop.stats.framesDelivered >= 1 }, "no frame delivered after release")
        Thread.sleep(forTimeInterval: 0.05)

        // The stale pre-forget frame must NOT be pinned: A is either unheld or,
        // if held at all, it is NOT the old buffer.
        if let held = compositor.retainedFrame(for: id) {
            XCTAssertFalse(held.pixelBuffer === oldFrame.pixelBuffer,
                           "rapid reattach resurrected A's OLD pre-forget frame (stale pixels pinned)")
        }

        // A genuinely fresh post-attach frame from the new mailbox IS shown.
        let freshFrame = try frame(id)
        newBox.post(freshFrame)
        XCTAssertTrue(pollUntil(1.0) {
            compositor.retainedFrame(for: id)?.pixelBuffer === freshFrame.pixelBuffer
        }, "the fresh post-reattach frame was not composited")

        // Tombstone set stays bounded (never grows without bound; N1 preserved).
        XCTAssertLessThanOrEqual(compositor.tombstonedSourceIDs.count, 4,
                                 "tombstone set is not bounded after reattach churn")
    }

    /// Compositor-boundary form driving the epoch API directly (independent of the
    /// render thread's timing): a frame pulled under epoch Eold, folded after a
    /// forget→reattach bumped the epoch, is rejected; a frame pulled under the new
    /// epoch folds; the tombstone/epoch bookkeeping stays bounded.
    func testEpochGuardRejectsPreForgetFoldAfterReattach() throws {
        let compositor = try MetalCompositor(device: try device(), width: 128, height: 128)
        let id = SourceID("epoch.reattach")
        let scene = Scene(name: "s", layers: [Layer(sourceID: id)])

        compositor.attach(source: id)             // epoch E1
        let staleEpochs = compositor.captureSourceEpochs()   // what an in-flight tick pulled under
        let oldFrame = try frame(id)

        // Rapid forget→reattach: bumps the epoch twice, clears the tombstone.
        compositor.forget(source: id)             // E2, tombstone
        compositor.attach(source: id)             // E3, tombstone cleared

        // The stale in-flight tick folds its pre-forget frame under E1.
        compositor.setPendingCapturedEpochs(staleEpochs)
        _ = try compositor.composite(frames: [id: oldFrame], scene: scene, pts: HouseClock.now())
        XCTAssertNil(compositor.retainedFrame(for: id),
                     "a pre-forget frame (older epoch) re-pinned A after reattach")

        // A fresh frame pulled under the CURRENT epoch folds normally.
        let freshEpochs = compositor.captureSourceEpochs()   // {id: E3}
        let freshFrame = try frame(id)
        compositor.setPendingCapturedEpochs(freshEpochs)
        _ = try compositor.composite(frames: [id: freshFrame], scene: scene, pts: HouseClock.now())
        XCTAssertTrue(compositor.retainedFrame(for: id)?.pixelBuffer === freshFrame.pixelBuffer,
                      "fresh post-attach frame did not fold")

        // Never-re-attached churn is pruned (sourceEpoch + tombstone both bounded).
        for _ in 0..<64 {
            let g = SourceID(UUID().uuidString)
            compositor.attach(source: g)
            compositor.forget(source: g)
        }
        compositor.setPendingCapturedEpochs([:])
        for _ in 0..<4 { _ = try compositor.composite(frames: [:], scene: scene, pts: HouseClock.now()) }
        XCTAssertLessThanOrEqual(compositor.tombstonedSourceIDs.count, 4,
                                 "tombstone set leaked under forget churn (N1)")
    }

    // MARK: - F22: DualProgram / SecondaryComposition

    /// The secondary program's pending/draining dict can outlive
    /// `dualProgram.forget`; the resulting composite must not re-insert the
    /// removed source into the secondary compositor's last-known set.
    func testDualProgramForgetRejectsStaleDrain() throws {
        let secondary = try SecondaryComposition(device: try device(), width: 270, height: 480)
        let dual = DualProgram(secondary: secondary)
        let id = SourceID("dual.removed")
        dual.scene = Scene(name: "v", layers: [Layer(sourceID: id)])

        // Establish the source as held in the secondary compositor.
        _ = try dual.compositeInline(frames: [id: try frame(id)], pts: HouseClock.now())
        XCTAssertTrue(secondary.compositor.heldSourceIDs.contains(id))

        // Forget it, then replay a pre-forget dict (models the drain compositing
        // `work.job.frames` after forget).
        dual.forget(source: id)
        XCTAssertFalse(secondary.compositor.heldSourceIDs.contains(id),
                       "forget did not drop the secondary's last-known frame")
        _ = try dual.compositeInline(frames: [id: try frame(id)], pts: HouseClock.now())
        XCTAssertFalse(secondary.compositor.heldSourceIDs.contains(id),
                       "stale secondary composite re-pinned the forgotten source")
    }

    /// A genuinely re-registered source explicitly attached by its owner must
    /// compose again in the vertical program — the tombstone must not strand it.
    func testDualProgramReaddAfterForgetComposesAgain() throws {
        let secondary = try SecondaryComposition(device: try device(), width: 270, height: 480)
        let dual = DualProgram(secondary: secondary)
        let id = SourceID("dual.readd")
        dual.scene = Scene(name: "v", layers: [Layer(sourceID: id)])

        let delivered = OSAllocatedUnfairLock<Int>(initialState: 0)
        dual.onSecondaryFrame = { _ in delivered.withLock { $0 += 1 } }

        dual.forget(source: id)
        XCTAssertFalse(secondary.compositor.heldSourceIDs.contains(id))

        // Re-registration is explicit: mere frame presence can be a stale
        // pre-forget App snapshot and must never resurrect the source.
        dual.attach(source: id)
        dual.submit(frames: [id: try frame(id)], pts: HouseClock.now())
        XCTAssertTrue(pollUntil(1.0) { delivered.withLock { $0 >= 1 } }, "secondary never drained the re-add")
        XCTAssertTrue(pollUntil(1.0) { secondary.compositor.heldSourceIDs.contains(id) },
                      "re-added source was not restored to the vertical program")
    }

    /// Forget must retire already-enqueued drain work before returning, and a
    /// following attach may clear the tombstone only after that barrier.
    /// Otherwise a rapid remove/re-add can resurrect the removed IOSurface.
    func testDualProgramForgetAndAttachFenceAlreadyEnqueuedDrain() throws {
        let secondary = try SecondaryComposition(device: try device(), width: 270, height: 480)
        let dual = DualProgram(secondary: secondary)
        let id = SourceID("dual.reattach-fence")
        dual.scene = Scene(name: "v", layers: [Layer(sourceID: id)])

        let consumerEntered = DispatchSemaphore(value: 0)
        let releaseConsumer = DispatchSemaphore(value: 0)
        dual.onSecondaryFrame = { _ in
            consumerEntered.signal()
            _ = releaseConsumer.wait(timeout: .now() + 3)
        }
        dual.submit(frames: [id: try frame(id)], pts: HouseClock.now())
        XCTAssertEqual(consumerEntered.wait(timeout: .now() + 3), .success)

        let forgetReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            dual.forget(source: id)
            forgetReturned.signal()
        }
        XCTAssertEqual(forgetReturned.wait(timeout: .now() + 0.05), .timedOut,
                       "forget returned before the queued drain retired")

        releaseConsumer.signal()
        XCTAssertEqual(forgetReturned.wait(timeout: .now() + 3), .success)
        XCTAssertFalse(secondary.compositor.heldSourceIDs.contains(id))
        dual.attach(source: id)
        dual.onSecondaryFrame = nil
        dual.submit(frames: [id: try frame(id)], pts: HouseClock.now())
        XCTAssertTrue(pollUntil(1.0) { secondary.compositor.heldSourceIDs.contains(id) },
                      "source did not compose after the fenced re-attach")
    }

    // MARK: - helper

    private func pollUntil(_ timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return predicate()
    }
}
