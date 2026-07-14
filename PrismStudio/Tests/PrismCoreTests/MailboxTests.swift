import CoreMedia
import CoreVideo
import XCTest
@testable import PrismCore

final class MailboxTests: XCTestCase {
    private func frame(ptsMs: Int64, source: String = "test") throws -> VideoFrame {
        let pool = try PixelBufferPool(width: 16, height: 16)
        let buf = try pool.makeBuffer()
        return VideoFrame(
            pixelBuffer: buf,
            pts: CMTime(value: ptsMs, timescale: 1000),
            source: SourceID(source)
        )
    }

    func testLatestWinsWithinDeadline() throws {
        let box = FrameMailbox(depth: 3)
        try box.post(frame(ptsMs: 100))
        try box.post(frame(ptsMs: 116))
        try box.post(frame(ptsMs: 133))
        let picked = box.take(deadline: CMTime(value: 120, timescale: 1000))
        XCTAssertEqual(picked?.pts.value, 116)
        // 100 was discarded with the pick; 133 remains for the next tick
        let next = box.take(deadline: CMTime(value: 140, timescale: 1000))
        XCTAssertEqual(next?.pts.value, 133)
    }

    func testDeadlineBeforeAllFramesReturnsNilUnlessAllowFuture() throws {
        let box = FrameMailbox(depth: 3)
        try box.post(frame(ptsMs: 200))
        XCTAssertNil(box.take(deadline: CMTime(value: 100, timescale: 1000)))
        XCTAssertEqual(box.take(deadline: CMTime(value: 100, timescale: 1000), allowFuture: true)?.pts.value, 200)
    }

    func testDepthBoundDropsOldest() throws {
        let box = FrameMailbox(depth: 2)
        for ms: Int64 in [10, 20, 30, 40] { try box.post(frame(ptsMs: ms)) }
        let stats = box.stats
        XCTAssertEqual(stats.delivered, 4)
        XCTAssertEqual(stats.dropped, 2)
        XCTAssertEqual(box.takeNewest()?.pts.value, 40)
        XCTAssertNil(box.takeNewest())
    }

    func testHouseClockMonotonic() {
        let a = HouseClock.now()
        let b = HouseClock.now()
        XCTAssertGreaterThanOrEqual(CMTimeCompare(b, a), 0)
    }

    func testPoolMintsIOSurfaceBackedBuffers() throws {
        let pool = try PixelBufferPool(width: 64, height: 64)
        let buf = try pool.makeBuffer()
        XCTAssertNotNil(CVPixelBufferGetIOSurface(buf))
    }
}
