import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import XCTest

import PrismCore
import PrismOutput
@testable import Prism

/// sol #17 (DATA LOSS) — the App's replay / highlight / clip save paths. Two
/// clips saved in the same second reused ONE second-resolution filename and the
/// muxer deleted the earlier file, so the second clip destroyed the first.
///
/// The fix: `saveReplayAsync` / `clipThatMomentAsync` mint millisecond + monotonic
/// -counter names, and `ReplayBuffer.saveClip/saveHighlight` resolve a
/// non-clobbering sibling. Oracle = filesystem inode (independent of the saver).
/// Each fix test is paired with a firing negative control.
@MainActor
final class SolReplayClipUniquenessTests: XCTestCase {

    private func inode(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? UInt64
    }

    private func makeCanvasBGRA() throws -> CVPixelBuffer {
        // Match the replay program encoder's canvas so it accepts the frames.
        try PixelBufferPool(width: 1920, height: 1080, pixelFormat: kCVPixelFormatType_32BGRA).makeBuffer()
    }

    /// Arms replay, feeds program frames through the real fan-out → replay encoder,
    /// and waits (bounded) for the async encoder delivery to fill the ring.
    private func armAndWarmReplay(_ engine: AppEngine) async throws {
        engine.setReplayArmed(true)
        let base = HouseClock.now()
        for i in 0..<40 {
            let f = VideoFrame(pixelBuffer: try makeCanvasBGRA(),
                               pts: CMTimeAdd(base, CMTime(value: Int64(i), timescale: 30)),
                               duration: CMTime(value: 1, timescale: 30), source: SourceID("program"))
            engine._test_deliverProgramFrame(f)
        }
        // Wait for the async VideoToolbox delivery to land in the ring.
        for _ in 0..<200 where engine._test_replayBufferedFrameCount() < 8 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThan(engine._test_replayBufferedFrameCount(), 0, "replay ring never filled")
    }

    // MARK: - clipThatMoment: two same-second saves don't clobber

    func testTwoClipThatMomentSavesDoNotClobber() async throws {
        let engine = AppEngine()
        try await armAndWarmReplay(engine)

        let urlA = try await engine.clipThatMomentAsync()
        let inodeA = inode(urlA)
        XCTAssertNotNil(inodeA, "Take A clip must exist")

        let urlB = try await engine.clipThatMomentAsync()
        XCTAssertNotEqual(urlA, urlB, "two clips must land at DISTINCT paths (no same-second collision)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlA.path), "Take A clip must survive Take B")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlB.path))
        XCTAssertEqual(inode(urlA), inodeA, "Take A clip untouched (same inode)")

        try? FileManager.default.removeItem(at: urlA)
        try? FileManager.default.removeItem(at: urlB)
        engine.setReplayArmed(false)
        await engine.shutdown()
    }

    // MARK: - saveReplay: two same-second saves don't clobber

    func testTwoSaveReplaySavesDoNotClobber() async throws {
        let engine = AppEngine()
        try await armAndWarmReplay(engine)

        let urlA = try await engine.saveReplayAsync()
        let inodeA = inode(urlA)
        let urlB = try await engine.saveReplayAsync()
        XCTAssertNotEqual(urlA, urlB, "two replays must land at DISTINCT paths")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlA.path), "Take A replay must survive Take B")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlB.path))
        XCTAssertEqual(inode(urlA), inodeA, "Take A replay untouched (same inode)")

        try? FileManager.default.removeItem(at: urlA)
        try? FileManager.default.removeItem(at: urlB)
        engine.setReplayArmed(false)
        await engine.shutdown()
    }

    // MARK: - Negative control: a fixed-path overwrite DOES destroy Take A

    func testNegativeControlFixedPathOverwriteDestroysTakeA() async throws {
        // The fix makes the public API mint unique names, so it can no longer be
        // coerced into a collision — that IS the fix. To prove the inode oracle
        // detects the destruction the pre-fix code caused, reproduce the exact
        // destructive step (delete the file, write a new file at the SAME path)
        // and show Take A's inode changes.
        let engine = AppEngine()
        try await armAndWarmReplay(engine)

        let urlA = try await engine.clipThatMomentAsync()
        let inodeA = inode(urlA)
        XCTAssertNotNil(inodeA)

        // Pre-fix: a same-second second clip reused this exact path; the muxer
        // deleted the existing file first, then wrote fresh bytes there.
        try FileManager.default.removeItem(at: urlA)                       // <-- the destructive line
        FileManager.default.createFile(atPath: urlA.path, contents: Data([1, 2, 3]))
        XCTAssertNotEqual(inode(urlA), inodeA,
                          "negative control: fixed-path overwrite replaced Take A (inode changed) — oracle fires")

        try? FileManager.default.removeItem(at: urlA)
        engine.setReplayArmed(false)
        await engine.shutdown()
    }
}
