import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import XCTest

import PrismCore
import PrismOutput
@testable import Prism

/// sol HIGH #1 (DATA LOSS) + HIGH #2 (Stop/Start bank ownership) — the App
/// session layer.
///
/// #1 Two rapid Records must produce DISTINCT program (and ISO) paths so a later
///    take never overwrites an earlier take's files. The pre-fix second-resolution
///    program name + fixed per-source ISO name let Take B land on Take A.
///
/// #2 A rapid Stop-A → Start-B must not strand A's ISO/multitrack banks nor
///    cross-finalize B's. The fix snapshots A's banks synchronously at Stop,
///    before the vertical-finalization await where a Start B interleaves.
///
/// Each finding is paired with a firing negative control.
@MainActor
final class SolRecordTakeUniquenessTests: XCTestCase {

    private func makeHLG10(_ w: Int, _ h: Int, source: SourceID) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_ARGB2101010LEPacked)
        let buf = try pool.makeBuffer()
        CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return VideoFrame(pixelBuffer: buf, pts: HouseClock.now(), source: source)
    }

    private func inode(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? UInt64
    }

    private func makeCanvasBGRA(source: SourceID) throws -> CVPixelBuffer {
        // Match the program recorder's canvas (1920×1080) so the encoder accepts it.
        let pool = try PixelBufferPool(width: 1920, height: 1080, pixelFormat: kCVPixelFormatType_32BGRA)
        return try pool.makeBuffer()
    }

    /// Feed a few real program frames so the take's `.mov` finalizes on disk.
    private func feedProgramFrames(_ engine: AppEngine, count: Int = 6) throws {
        let base = HouseClock.now()
        for i in 0..<count {
            let buf = try makeCanvasBGRA(source: SourceID("program"))
            let f = VideoFrame(pixelBuffer: buf,
                               pts: CMTimeAdd(base, CMTime(value: Int64(i), timescale: 30)),
                               duration: CMTime(value: 1, timescale: 30), source: SourceID("program"))
            engine._test_deliverProgramFrame(f)
        }
    }

    // MARK: - #1 two rapid program recordings get distinct paths

    func testTwoRapidProgramRecordingsGetDistinctPaths() async throws {
        let engine = AppEngine()

        try engine.startRecording()
        try feedProgramFrames(engine)
        let stoppedA = await engine.stopRecording()
        let urlA = try XCTUnwrap(stoppedA, "Take A program path")
        let inodeA = inode(URL(filePath: urlA))

        try engine.startRecording()
        try feedProgramFrames(engine)
        let stoppedB = await engine.stopRecording()
        let urlB = try XCTUnwrap(stoppedB, "Take B program path")

        XCTAssertNotEqual(urlA, urlB, "two rapid Records must produce DISTINCT program paths (no same-second collision)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlA), "Take A's program file must survive Take B")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlB), "Take B's program file must exist")
        XCTAssertEqual(inode(URL(filePath: urlA)), inodeA, "Take A's program file must be untouched (same inode)")

        // cleanup
        try? FileManager.default.removeItem(at: URL(filePath: urlA))
        try? FileManager.default.removeItem(at: URL(filePath: urlB))
        await engine.shutdown()
    }

    // MARK: - #1 two takes' ISO files both survive (armed ISO source)

    func testTwoTakesISOFilesBothSurvive() async throws {
        let engine = AppEngine()
        let id = SourceID("iso.take.hlg")
        engine._test_addSyntheticISOSourceNoFrame(id: id) // arm ONCE; arming persists across takes

        func runTake() async throws -> URL {
            try engine.startRecording()
            let base = HouseClock.now()
            for i in 0..<12 {
                var f = try makeHLG10(1280, 720, source: id)
                f = VideoFrame(pixelBuffer: f.pixelBuffer,
                               pts: CMTimeAdd(base, CMTime(value: Int64(i), timescale: 30)),
                               duration: CMTime(value: 1, timescale: 30), source: id)
                engine._test_feedISOFrame(f)
            }
            _ = await engine.stopRecording()
            return try XCTUnwrap(engine._test_lastISOFile(for: id), "finalized ISO file")
        }

        let urlA = try await runTake()
        let inodeA = inode(urlA)
        XCTAssertNotNil(inodeA)

        let urlB = try await runTake()
        XCTAssertNotEqual(urlA, urlB, "Take B's ISO angle must land at a DISTINCT path (per-take subfolder)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlA.path), "Take A's ISO file must survive Take B")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlB.path))
        XCTAssertEqual(inode(urlA), inodeA, "Take A's ISO file untouched (same inode)")

        try? FileManager.default.removeItem(at: urlA.deletingLastPathComponent().deletingLastPathComponent())
        await engine.shutdown()
    }

    // MARK: - #2 Stop-A → Start-B bank ownership (deterministic seam)

    /// The fix: Stop A snapshots + detaches its OWN ISO bank synchronously, before
    /// the vertical await. A Start B interleaved at that window installs a fresh
    /// bank into a clean slot; Stop A finalizes only bank A.
    func testStopAFinalizesOwnBankWhileStartBInstallsFresh() async throws {
        let engine = AppEngine()
        let id = SourceID("iso.aba")
        engine._test_addSyntheticISOSourceNoFrame(id: id)

        try engine.startRecording()
        let bankA = try XCTUnwrap(engine._test_isoBankInstance(), "Take A ISO bank")
        XCTAssertEqual(bankA.state, .recording)

        // Interleave Start B at the exact vulnerable window inside Stop A.
        AppEngine._test_stopMidVerticalHook = { [weak engine] in
            MainActor.assumeIsolated { try? engine?.startRecording() }
        }
        defer { AppEngine._test_stopMidVerticalHook = nil }

        _ = await engine.stopRecording() // Stop A (fires the hook mid-stop)

        let bankB = try XCTUnwrap(engine._test_isoBankInstance(), "Take B ISO bank must be installed into a clean slot")
        XCTAssertFalse(bankB === bankA, "Start B must install a DISTINCT bank, not reuse A's")
        XCTAssertEqual(bankA.state, .finished, "Stop A must finalize its OWN bank (A), not B's")
        XCTAssertEqual(bankB.state, .recording, "Take B's bank must be untouched by Stop A (no premature detach)")

        AppEngine._test_stopMidVerticalHook = nil
        _ = await engine.stopRecording() // Stop B (clean up)
        await engine.shutdown()
    }

    /// NEGATIVE CONTROL: reinstate the pre-fix ordering (capture the banks AFTER
    /// the vertical await). Now Stop A cross-finalizes B's bank and strands A's.
    func testNegativeControlStopACrossFinalizesBAndStrandsA() async throws {
        AppEngine._test_captureBanksAfterVerticalAwait = true
        defer { AppEngine._test_captureBanksAfterVerticalAwait = false }

        let engine = AppEngine()
        let id = SourceID("iso.aba.neg")
        engine._test_addSyntheticISOSourceNoFrame(id: id)

        try engine.startRecording()
        let bankA = try XCTUnwrap(engine._test_isoBankInstance())

        AppEngine._test_stopMidVerticalHook = { [weak engine] in
            MainActor.assumeIsolated { try? engine?.startRecording() }
        }
        defer { AppEngine._test_stopMidVerticalHook = nil }

        _ = await engine.stopRecording() // Stop A, pre-fix ordering

        // Pre-fix damage: Stop A grabbed whatever `isoBank` was AFTER the await —
        // that is B's bank — and finalized it, while A's bank was never finalized.
        XCTAssertEqual(bankA.state, .recording, "negative control: Take A's bank is STRANDED (never finalized)")
        XCTAssertNil(engine._test_isoBankInstance(), "negative control: Stop A prematurely detached B's bank")

        AppEngine._test_stopMidVerticalHook = nil
        await engine.shutdown()
    }
}
