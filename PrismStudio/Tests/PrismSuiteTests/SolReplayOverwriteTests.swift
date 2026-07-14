import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import XCTest

import PrismCore
@testable import PrismOutput

/// sol #17 (DATA LOSS) — the replay / highlight / clip save paths must NEVER
/// destructively overwrite an earlier clip. Before the fix, the replay/clip
/// filenames used a *second*-resolution timestamp with no disambiguation and the
/// muxer (`EncodedClipWriter`) unconditionally deleted whatever sat at the
/// destination path, so two clips saved in the same second collided on ONE path
/// and the second destroyed the first (same data-loss class as the recorder, in a
/// path wave-17[OO] didn't cover).
///
/// The oracle is inode identity + byte size read straight off the filesystem (an
/// INDEPENDENT check — `attributesOfItem`, not the saver's own bookkeeping). Each
/// fix test is paired with a firing negative control that reproduces the
/// destructive overwrite so the oracle is proven to detect it.
final class SolReplayOverwriteTests: XCTestCase {

    private let width = 160, height = 120, fps = 30

    // MARK: fixtures

    private func inode(_ url: URL) throws -> UInt64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64) ?? 0
    }
    private func size(_ url: URL) throws -> Int64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
    }

    /// A warmed `ReplayBuffer` holding ~2 s of distinct encoded program frames.
    private func warmBuffer(seconds: Double = 3.0, window: Double = 5.0) throws -> ReplayBuffer {
        let encoder = ProgramEncoder(settings: .init(
            codec: .h264, width: width, height: height, averageBitrate: 4_000_000,
            keyframeInterval: 100.0, expectedFrameRate: Double(fps), lowLatencyRateControl: false))
        let replay = ReplayBuffer(seconds: window, fragmentInterval: 0.5)
        encoder.onEncodedFrame = { replay.append($0) }
        try encoder.start()
        let pool = try PixelBufferPool(width: width, height: height)
        let src = SourceID("test.replayoverwrite")
        let frameDur = CMTime(value: 1, timescale: CMTimeScale(fps))
        let total = Int(seconds * Double(fps))
        for i in 0..<total {
            if i % 15 == 0 { encoder.forceKeyframe() }
            let pts = CMTime(value: Int64(i), timescale: CMTimeScale(fps))
            try encoder.encode(makeSolidFrame(pool: pool, gray: UInt8(20 + (i % 100)), pts: pts,
                                              duration: frameDur, source: src))
        }
        encoder.flush()
        encoder.stop()
        return replay
    }

    private func makeSolidFrame(pool: PixelBufferPool, gray: UInt8, pts: CMTime,
                                duration: CMTime, source: SourceID) throws -> VideoFrame {
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let addr = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let hh = CVPixelBufferGetHeight(buf), ww = CVPixelBufferGetWidth(buf)
        for y in 0..<hh {
            let row = addr.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
            for x in 0..<ww { row[x*4+0] = gray; row[x*4+1] = gray; row[x*4+2] = gray; row[x*4+3] = 255 }
        }
        return VideoFrame(pixelBuffer: buf, pts: pts, duration: duration, source: source)
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism_replay_ov_\(UInt64.random(in: 0..<UInt64.max))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - saveHighlight (the "clip that moment" path) — same-second Take A/B

    func testSaveHighlightSameSecondDoesNotClobberFirstClip() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The EXACT collision from sol's probe: both takes request the same
        // second-resolution "Clip same-second.mov" path.
        let path = dir.appendingPathComponent("Clip same-second.mov")

        let replay = try warmBuffer()
        let a = try await replay.saveHighlight(lastSeconds: 1.0, to: path)
        XCTAssertEqual(a.url, path, "first clip uses the requested path")
        let inodeA = try inode(a.url), sizeA = try size(a.url)
        XCTAssertGreaterThan(sizeA, 0)

        // Take B requests the SAME path in the same second → must go to a
        // non-clobbering sibling, NOT destroy Take A.
        let b = try await replay.saveHighlight(lastSeconds: 1.0, to: path)
        XCTAssertNotEqual(b.url, a.url, "second clip must NOT reuse the first clip's path")

        XCTAssertTrue(FileManager.default.fileExists(atPath: a.url.path), "Take A must survive Take B")
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.url.path), "Take B must exist at its own path")
        XCTAssertEqual(try inode(a.url), inodeA, "Take A file untouched (same inode)")
        XCTAssertEqual(try size(a.url), sizeA, "Take A content unchanged (same size)")
        // And Take A is still a valid, decodable clip.
        let atracks = try await AVURLAsset(url: a.url).loadTracks(withMediaType: .video)
        XCTAssertFalse(atracks.isEmpty, "Take A no longer has a video track — corrupted")
    }

    // MARK: - saveClip (the instant-replay flush path) — same-second Take A/B

    func testSaveClipSameSecondDoesNotClobberFirstReplay() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Replay same-second.mov")

        let replay = try warmBuffer()
        let a = try await replay.saveClip(to: path)
        XCTAssertEqual(a.url, path)
        let inodeA = try inode(a.url), sizeA = try size(a.url)

        let b = try await replay.saveClip(to: path)
        XCTAssertNotEqual(b.url, a.url, "second replay must not reuse the first's path")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.url.path), "Take A replay must survive Take B")
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.url.path))
        XCTAssertEqual(try inode(a.url), inodeA, "Take A replay untouched (same inode)")
        XCTAssertEqual(try size(a.url), sizeA, "Take A replay unchanged (same size)")
    }

    // MARK: - Negative control: the oracle FIRES on the pre-fix overwrite

    func testNegativeControlOverwriteDestroysFirstClip() async throws {
        // Reproduce the pre-fix step: the muxer deleted whatever sat at the fixed
        // path before writing. Show the inode oracle detects Take A was destroyed.
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Clip same-second.mov")

        let replay = try warmBuffer()
        let a = try await replay.saveHighlight(lastSeconds: 1.0, to: path)
        let inodeA = try inode(a.url)

        // The pre-fix destructive step the fix removed: delete the existing file,
        // then a fresh save reuses the now-free path.
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path) // <-- the destructive line
        }
        let b = try await replay.saveHighlight(lastSeconds: 1.0, to: path)
        XCTAssertEqual(b.url, path, "negative control: path is free again, save reuses it")
        XCTAssertNotEqual(try inode(path), inodeA,
                          "negative control: overwrite replaced Take A's file (inode changed) — oracle fires")
    }
}
