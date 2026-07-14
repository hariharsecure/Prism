import CoreMedia
import CoreVideo
import Metal
import os
import XCTest

@testable import PrismCompositor
import PrismCore

/// Reproduction + negative control for the **non-atomic mailbox/epoch snapshot**
/// re-pin race (sol "reattach re-pin" — STILL-OPEN after HIGH-3).
///
/// The HIGH-3 epoch guard only works if the epoch map a tick carries was captured
/// for the SAME mailbox set the tick pulled frames from. The bug: `RenderLoop.run`
/// snapshotted `mailboxes` under the shared lock, then captured the compositor
/// epochs on a SEPARATE line. A `removeMailbox(A)`+`setMailbox(A, newBox)` landing
/// in that gap made the captured epoch already equal the post-attach value, so a
/// stale frame pulled from the OLD mailbox snapshot folded under a matching epoch
/// and was ACCEPTED → stale pixels pinned.
///
/// The fix captures the mailbox set and the epoch map atomically under one
/// critical section (`setMailbox`/`removeMailbox` mutate `mailboxes` under that
/// same lock before touching the compositor, so no forget/attach can interleave).
///
/// NEGATIVE CONTROL: the DEBUG toggle `_test_captureEpochsAfterSnapshot`
/// reverts to the original non-atomic capture. The test forces the exact
/// interleaving via `_test_betweenSnapshotAndEpochCapture` and asserts the stale
/// pre-forget frame is REJECTED with the fix and ACCEPTED once neutralized (red).
final class AtomicEpochCaptureTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    private func frame(_ id: SourceID, w: Int = 64, h: Int = 64) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_32BGRA)
        return VideoFrame(pixelBuffer: try pool.makeBuffer(), pts: HouseClock.now(), source: id)
    }

    private func pollUntil(_ timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return predicate()
    }

    /// Run the interleaving once. `neutralized == true` reverts to the non-atomic
    /// capture (the bug). Returns whether A's OLD pre-forget frame ended up pinned.
    private func runScenario(neutralized: Bool) throws -> (pinnedStale: Bool, freshShown: Bool) {
        let compositor = try MetalCompositor(device: try device(), width: 320, height: 180)
        let loop = RenderLoop(compositor: compositor, fps: 120)

        let id = SourceID("atomic.reattach")
        let oldFrame = try frame(id)
        let oldBox = FrameMailbox()
        oldBox.post(oldFrame)
        loop.setMailbox(oldBox, for: id)           // attach → epoch E_old
        let sceneX = Scene(name: "probe", layers: [Layer(sourceID: id)])
        loop.scene = sceneX

        let fired = OSAllocatedUnfairLock(initialState: false)
        let seamDone = DispatchSemaphore(value: 0)
        let newBoxHolder = OSAllocatedUnfairLock<FrameMailbox?>(initialState: nil)
        loop._test_captureEpochsAfterSnapshot = neutralized

        // Fires between the mailbox+epoch snapshot and the frame pull. On the first
        // tick (oldBox is in the snapshot) it forgets A and reattaches a fresh
        // EMPTY mailbox under the same id — landing the reattach in the exact
        // window the atomic capture closes.
        loop._test_betweenSnapshotAndEpochCapture = {
            let first = fired.withLock { d -> Bool in if d { return false }; d = true; return true }
            guard first else { return }
            loop.removeMailbox(for: id)             // forget → epoch E_old+1, tombstone
            let nb = FrameMailbox()                 // new source has not emitted yet
            loop.setMailbox(nb, for: id)            // attach → epoch E_old+2, tombstone cleared
            newBoxHolder.withLock { $0 = nb }
            seamDone.signal()
        }

        defer { loop.stop() }
        loop.start()
        XCTAssertEqual(seamDone.wait(timeout: .now() + 3.0), .success,
                       "test seam never fired (render thread never reached the snapshot↔epoch window)")

        // Let the tick that already pulled A's OLD frame complete its fold.
        XCTAssertTrue(pollUntil(1.0) { loop.stats.framesDelivered >= 1 }, "no frame delivered after seam")
        Thread.sleep(forTimeInterval: 0.05)

        let pinnedStale = compositor.retainedFrame(for: id)?.pixelBuffer === oldFrame.pixelBuffer

        // Reattach must still work: a genuinely fresh frame on the NEW mailbox shows.
        let freshFrame = try frame(id)
        newBoxHolder.withLock { $0 }?.post(freshFrame)
        let freshShown = pollUntil(1.0) {
            compositor.retainedFrame(for: id)?.pixelBuffer === freshFrame.pixelBuffer
        }
        loop.stop()
        return (pinnedStale, freshShown)
    }

    /// With the atomic capture (production default), the stale pre-forget frame is
    /// REJECTED; neutralizing the atomic capture ACCEPTS it (the negative control
    /// goes red), proving the test actually exercises the fix.
    func testAtomicCaptureRejectsStaleReattachFold_negativeControlAccepts() throws {
        let fixed = try runScenario(neutralized: false)
        XCTAssertFalse(fixed.pinnedStale,
                       "atomic capture: a stale pre-forget frame was re-pinned across a rapid reattach")
        XCTAssertTrue(fixed.freshShown,
                      "atomic capture broke genuine reattach — the fresh post-attach frame never showed")

        let control = try runScenario(neutralized: true)
        XCTAssertTrue(control.pinnedStale,
                      "NEGATIVE CONTROL FAILED: with the non-atomic capture neutralized the stale frame should be accepted (the test has no teeth)")
    }
}
