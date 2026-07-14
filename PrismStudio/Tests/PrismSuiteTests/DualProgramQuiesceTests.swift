import CoreMedia
import CoreVideo
import Metal
import os
import XCTest

import PrismCompose
import PrismCompositor
import PrismCore

/// sol #5 #9 — an HDR/color-mode rebuild joins only the PRIMARY render loop, so the
/// OLD `DualProgram` can still drain enqueued vertical work asynchronously and deliver
/// a STALE old-color-mode (e.g. SDR) vertical frame AFTER the new program's first frame
/// — reverting the preview / seeding a new recorder's first frame. `quiesce()` fences
/// the discarded program so no further frame reaches the shared vertical sink.
final class DualProgramQuiesceTests: XCTestCase {

    /// A `quiesce`d program delivers NO frame; the un-fenced (negative control) program
    /// delivers the same submission. The delta is exactly the stale-frame reorder the
    /// fence prevents — proven on the REAL delivery path, not a flag read.
    func testQuiescedProgramSuppressesDeliveryNegativeControlDelivers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }

        func deliveriesAfterSubmit(fence: Bool) throws -> Int {
            let secondary = try SecondaryComposition(device: device, width: 64, height: 64)
            let dual = DualProgram(secondary: secondary)
            let id = SourceID("v.quiesce.\(fence)")
            let pool = try PixelBufferPool(width: 64, height: 64,
                                           pixelFormat: kCVPixelFormatType_32BGRA)
            let frame = VideoFrame(pixelBuffer: try pool.makeBuffer(),
                                   pts: HouseClock.now(), source: id)
            dual.scene = Scene(name: "s", layers: [Layer(sourceID: id)])

            let count = OSAllocatedUnfairLock<Int>(initialState: 0)
            let signalled = DispatchSemaphore(value: 0)
            dual.onSecondaryFrame = { _ in count.withLock { $0 += 1 }; signalled.signal() }

            if fence {
                dual.quiesce()                          // FIX: fence the discarded program
                XCTAssertTrue(dual.isQuiesced)
            }
            dual.submit(frames: [id: frame], pts: frame.pts)

            if fence {
                // Give the (suppressed) drain ample time to run; assert it delivered nothing.
                Thread.sleep(forTimeInterval: 0.3)
            } else {
                // Un-fenced: the frame must actually be delivered (bounded wait).
                XCTAssertEqual(signalled.wait(timeout: .now() + 2), .success,
                               "un-fenced program never delivered — negative control vacuous")
            }
            return count.withLock { $0 }
        }

        // NEGATIVE CONTROL: no fence → the submission reaches the vertical sink (this is
        // the stale old-mode frame that would reorder past the new program).
        XCTAssertEqual(try deliveriesAfterSubmit(fence: false), 1,
                       "negative control vacuous: the un-fenced program did not deliver")
        // FIX: the fence suppresses delivery → no stale frame can reach the sink post-swap.
        XCTAssertEqual(try deliveriesAfterSubmit(fence: true), 0,
                       "sol #5 #9: a quiesced (discarded) DualProgram still delivered a vertical frame")
    }

    /// `resume` re-arms a quiesced program (the HDR-swap failure path revives the old
    /// vertical program) — so the fence is reversible, not a one-way kill.
    func testResumeReArmsAfterQuiesce() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let secondary = try SecondaryComposition(device: device, width: 64, height: 64)
        let dual = DualProgram(secondary: secondary)
        let id = SourceID("v.resume")
        let pool = try PixelBufferPool(width: 64, height: 64,
                                       pixelFormat: kCVPixelFormatType_32BGRA)
        let frame = VideoFrame(pixelBuffer: try pool.makeBuffer(), pts: HouseClock.now(), source: id)
        dual.scene = Scene(name: "s", layers: [Layer(sourceID: id)])

        let delivered = DispatchSemaphore(value: 0)
        dual.onSecondaryFrame = { _ in delivered.signal() }

        dual.quiesce()
        dual.resume()
        XCTAssertFalse(dual.isQuiesced)
        dual.submit(frames: [id: frame], pts: frame.pts)
        XCTAssertEqual(delivered.wait(timeout: .now() + 2), .success,
                       "sol #5 #9: a resumed program did not deliver (fence not reversible)")
    }
}
