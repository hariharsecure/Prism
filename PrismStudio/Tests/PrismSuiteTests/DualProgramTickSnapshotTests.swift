import CoreMedia
import CoreVideo
import Metal
import os
import XCTest

import PrismCompose
import PrismCompositor
import PrismCore

/// F8 regression: a coalesced vertical job must carry the exact dynamic
/// scene/reframe evaluated for its primary tick, not read mutable global values
/// later when the secondary queue eventually drains.
final class DualProgramTickSnapshotTests: XCTestCase {
    func testRenderLoopTickSnapshotReportsExactDeadlineQualifiedFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device on this host")
        }
        let compositor = try MetalCompositor(device: device, width: 64, height: 64)
        let loop = RenderLoop(compositor: compositor, fps: 60)
        defer { loop.stop() }
        let id = SourceID("primary.exact.tick")
        let pool = try PixelBufferPool(width: 64, height: 64,
                                       pixelFormat: kCVPixelFormatType_32BGRA)
        let now = HouseClock.now()
        let olderPTS = CMTimeSubtract(now, CMTime(seconds: 0.2, preferredTimescale: 600))
        let newestPTS = CMTimeSubtract(now, CMTime(seconds: 0.1, preferredTimescale: 600))
        let older = VideoFrame(pixelBuffer: try pool.makeBuffer(), pts: olderPTS, source: id)
        let newest = VideoFrame(pixelBuffer: try pool.makeBuffer(), pts: newestPTS, source: id)
        let mailbox = FrameMailbox()
        mailbox.post(older)
        mailbox.post(newest)
        loop.setMailbox(mailbox, for: id)
        loop.scene = Scene(name: "exact", layers: [Layer(sourceID: id)])

        let delivered = DispatchSemaphore(value: 0)
        let snapshots = OSAllocatedUnfairLock<[RenderLoop.TickSnapshot]>(initialState: [])
        loop.onTickSnapshot = { tick in
            let (ordinal, hasTwo) = snapshots.withLock { current -> (Int, Bool) in
                guard current.count < 2 else { return (current.count, false) }
                current.append(tick)
                return (current.count, current.count == 2)
            }
            // FrameMailbox.take keeps the selected slot for normal low-fps
            // holding. Empty it explicitly after tick one so tick two proves
            // TickSnapshot comes from the compositor's held set, not from a
            // repeated mailbox delivery.
            if ordinal == 1 { _ = mailbox.takeNewest() }
            if hasTwo { delivered.signal() }
        }
        loop.start()
        XCTAssertEqual(delivered.wait(timeout: .now() + 2), .success)
        let ticks = snapshots.withLock { $0 }
        XCTAssertEqual(ticks.first?.frames[id]?.pts, newestPTS,
                       "tick hook did not report the frame actually selected by the primary deadline")
        XCTAssertEqual(ticks.dropFirst().first?.frames[id]?.pts, newestPTS,
                       "tick hook dropped the held frame when the mailbox had no new value")
        XCTAssertEqual(ticks.first?.evaluatedScene?.layers.map(\.sourceID), [id])
        XCTAssertEqual(ticks.first?.restingScene.layers.map(\.sourceID), [id])
    }

    func testStaleSubmitAfterForgetCannotImplicitlyReattachSource() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device on this host")
        }
        let secondary = try SecondaryComposition(device: device, width: 64, height: 64)
        let dual = DualProgram(secondary: secondary)
        let id = SourceID("vertical.stale.after-forget")
        let pool = try PixelBufferPool(width: 64, height: 64,
                                       pixelFormat: kCVPixelFormatType_32BGRA)
        let frame = VideoFrame(pixelBuffer: try pool.makeBuffer(),
                               pts: HouseClock.now(), source: id)
        dual.scene = Scene(name: "stale", layers: [Layer(sourceID: id)])
        _ = try dual.compositeInline(frames: [id: frame], pts: frame.pts)
        XCTAssertTrue(secondary.compositor.heldSourceIDs.contains(id))

        dual.forget(source: id)
        XCTAssertFalse(secondary.compositor.heldSourceIDs.contains(id))
        let delivered = DispatchSemaphore(value: 0)
        dual.onSecondaryFrame = { _ in delivered.signal() }
        // Models an App snapshot taken before removal but submitted afterward.
        dual.submit(frames: [id: frame], pts: frame.pts)
        XCTAssertEqual(delivered.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(secondary.compositor.heldSourceIDs.contains(id),
                       "stale submit implicitly reattached/re-pinned a forgotten source")
    }

    /// F8 late-enable path: the primary has already consumed/prepared a still,
    /// then the vertical program starts on a later tick with no mailbox delta.
    /// The complete held TickSnapshot must make that first 9:16 frame non-black.
    func testLateVerticalSubmitRendersPrimaryHeldPreparedFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device on this host")
        }
        let primary = try MetalCompositor(device: device, width: 64, height: 64)
        let loop = RenderLoop(compositor: primary, fps: 60)
        defer { loop.stop() }
        let dual = try DualProgram(device: device, width: 64, height: 64)

        let id = SourceID("vertical.late.prepared")
        let pool = try PixelBufferPool(width: 64, height: 64,
                                       pixelFormat: kCVPixelFormatType_32BGRA)
        let buffer = try pool.makeBuffer()
        fill(buffer, b: 0, g: 0, r: 255)
        let frame = VideoFrame(pixelBuffer: buffer, pts: HouseClock.now(), source: id)
        let mailbox = FrameMailbox()
        mailbox.post(frame)
        loop.setMailbox(mailbox, for: id)
        loop.scene = Scene(name: "prepared-red", layers: [Layer(sourceID: id)])

        let output = OSAllocatedUnfairLock<VideoFrame?>(initialState: nil)
        let delivered = DispatchSemaphore(value: 0)
        dual.onSecondaryFrame = { frame in
            output.withLock { $0 = frame }
            delivered.signal()
        }
        let ordinal = OSAllocatedUnfairLock<Int>(initialState: 0)
        loop.onTickSnapshot = { tick in
            let n = ordinal.withLock { value -> Int in value += 1; return value }
            if n == 1 {
                // Make the second primary tick rely solely on compositor hold.
                _ = mailbox.takeNewest()
            } else if n == 2, let scene = tick.evaluatedScene {
                dual.submit(frames: tick.frames, scene: scene, reframe: .fillAll(),
                            pts: tick.pts, duration: tick.duration)
            }
        }

        loop.start()
        XCTAssertEqual(delivered.wait(timeout: .now() + 3), .success)
        guard let vertical = output.withLock({ $0 }) else {
            return XCTFail("vertical program did not produce its late-enable frame")
        }
        let rgb = centerRGB(vertical.pixelBuffer)
        XCTAssertGreaterThan(rgb.r, 245)
        XCTAssertLessThan(rgb.g, 10)
        XCTAssertLessThan(rgb.b, 10)
    }

    func testSubmittedSceneAndReframeRemainPairedWithFrames() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device on this host")
        }
        let secondary = try SecondaryComposition(device: device, width: 64, height: 64)
        let dual = DualProgram(secondary: secondary)

        let redID = SourceID("vertical.tick.red")
        let blueID = SourceID("vertical.tick.blue")
        let pool = try PixelBufferPool(width: 64, height: 64,
                                       pixelFormat: kCVPixelFormatType_32BGRA)
        let redBuffer = try pool.makeBuffer()
        let blueBuffer = try pool.makeBuffer()
        fill(redBuffer, b: 0, g: 0, r: 255)
        fill(blueBuffer, b: 255, g: 0, r: 0)
        let pts = HouseClock.now()
        let frames = [
            redID: VideoFrame(pixelBuffer: redBuffer, pts: pts, source: redID),
            blueID: VideoFrame(pixelBuffer: blueBuffer, pts: pts, source: blueID),
        ]

        // Park the secondary queue inside the first consumer so the second job
        // is definitely pending while its global scene/reframe are changed.
        let firstConsumerEntered = DispatchSemaphore(value: 0)
        let releaseFirstConsumer = DispatchSemaphore(value: 0)
        let delivered = DispatchSemaphore(value: 0)
        let count = OSAllocatedUnfairLock<Int>(initialState: 0)
        let secondFrame = OSAllocatedUnfairLock<VideoFrame?>(initialState: nil)
        dual.onSecondaryFrame = { frame in
            let ordinal = count.withLock { value -> Int in
                value += 1
                return value
            }
            if ordinal == 1 {
                firstConsumerEntered.signal()
                _ = releaseFirstConsumer.wait(timeout: .now() + 3)
            } else {
                secondFrame.withLock { $0 = frame }
                delivered.signal()
            }
        }

        let redScene = Scene(name: "red", layers: [Layer(sourceID: redID)])
        let blueScene = Scene(name: "blue", layers: [Layer(sourceID: blueID)])
        dual.submit(frames: frames, scene: redScene, reframe: .fillAll(), pts: pts)
        XCTAssertEqual(firstConsumerEntered.wait(timeout: .now() + 3), .success)

        dual.submit(frames: frames, scene: redScene, reframe: .fillAll(), pts: pts)
        // These mutations occur before the queued job can drain. The submitted
        // job must still render red/full rather than blue or hidden/black.
        dual.scene = blueScene
        dual.reframe = ReframeMap(hero: .none, others: .hidden)
        releaseFirstConsumer.signal()

        XCTAssertEqual(delivered.wait(timeout: .now() + 3), .success)
        guard let output = secondFrame.withLock({ $0 }) else {
            return XCTFail("secondary did not deliver the submitted tick")
        }
        let rgb = centerRGB(output.pixelBuffer)
        XCTAssertGreaterThan(rgb.r, 245)
        XCTAssertLessThan(rgb.g, 10)
        XCTAssertLessThan(rgb.b, 10)
    }

    private func fill(_ buffer: CVPixelBuffer, b: UInt8, g: UInt8, r: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base + y * bytesPerRow
            for x in 0..<width {
                let pixel = row + x * 4
                pixel[0] = b; pixel[1] = g; pixel[2] = r; pixel[3] = 255
            }
        }
    }

    private func centerRGB(_ buffer: CVPixelBuffer) -> (r: Int, g: Int, b: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let x = CVPixelBufferGetWidth(buffer) / 2
        let y = CVPixelBufferGetHeight(buffer) / 2
        let p = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (Int(p[2]), Int(p[1]), Int(p[0]))
    }
}
