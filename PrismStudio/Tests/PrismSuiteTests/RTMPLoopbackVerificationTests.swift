import Foundation
import XCTest

@testable import PrismAVTestKit

/// Live RTMP loopback verification (feasibility path **a**): publish the
/// deterministic oracle sequence through the production `RTMPStreamOutput` over a
/// real TCP RTMP socket to a headless MediaMTX receiver on a random loopback
/// port, pull the recording back, and apply the shared oracle. Skips (never
/// fails) when the receiver toolchain is absent or the capture is too short;
/// fails only when a captured stream is genuinely malformed.
final class RTMPLoopbackVerificationTests: XCTestCase {
    private static let configuration = AVRoundTripConfiguration(
        seed: 0x5052_4953_4D52_544D,
        width: 320, height: 192, fps: 30, frameCount: 18,
        videoBitrate: 8_000_000, patchTolerance: 28,
        avSkewBudgetMilliseconds: 8, audioSampleRate: 48_000,
        audioChunkFrames: 960, expectedRangeTag: .video)

    private var minRun: Int { max(6, Self.configuration.frameCount / 2) }

    func testLiveRTMPLoopbackRoundTripThroughMediaMTX() async throws {
        let result = try await runLoopbackOrSkip()
        defer { cleanup(result) }

        // Positive: the captured live stream satisfies every live gate.
        XCTAssertTrue(result.verification.passed,
                      "live oracle should pass on the captured stream: \(result.verification)")
        XCTAssertGreaterThanOrEqual(result.diagnostics.verifiedRunLength, minRun)
        XCTAssertEqual(result.evidence.decodedFrames.count,
                       result.evidence.expectedFrameIDs.count,
                       "trimmed evidence must be internally consistent")
        XCTAssertEqual(result.evidence.finalization.videoTrackCount, 1)
        XCTAssertEqual(result.evidence.finalization.audioTrackCount, 1,
                       "audio must survive the RTMP round trip")
        XCTAssertGreaterThan(result.evidence.finalization.muxedAudioSampleCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.movieURL.path),
                      "the pulled-back MOV must exist for inspection")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.recordingURL.path),
                      "the raw MediaMTX recording must exist for inspection")

        // Embedded IDs recovered from the live-decoded pixels form the exact
        // contiguous run the oracle verified.
        let ids = result.evidence.decodedFrames.compactMap(\.embeddedFrameID)
        XCTAssertEqual(ids, result.evidence.expectedFrameIDs)

        // Negative controls on the REAL captured evidence — prove the live oracle
        // REJECTS a corrupted stream (dropped frame ≈ dropped-IDR consequence,
        // truncated tail, swapped range tag).
        assertLiveOracleRejects(result.evidence.injecting(.frameDrop),
                                fault: .frameDrop,
                                expectedAnyOf: [.frameCount, .frameIdentity])
        assertLiveOracleRejects(result.evidence.injecting(.truncateTail),
                                fault: .truncateTail,
                                expectedAnyOf: [.frameCount, .frameIdentity])
        assertLiveOracleRejects(result.evidence.injecting(.rangeTagSwap),
                                fault: .rangeTagSwap,
                                expectedAnyOf: [.rangeTag])
    }

    // MARK: Helpers

    private func runLoopbackOrSkip() async throws -> RTMPLoopbackRunner.Result {
        do {
            return try await RTMPLoopbackRunner.run(configuration: Self.configuration)
        } catch let error as RTMPLoopbackRunner.LoopbackError where error.isInfrastructureUnavailable {
            throw XCTSkip("live RTMP loopback unavailable on this host: \(error)")
        }
    }

    private func assertLiveOracleRejects(
        _ corrupted: AVRoundTripEvidence,
        fault: AVRoundTripFault,
        expectedAnyOf expectedCodes: Set<AVOracleAssertionCode>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let accepted = try AVRoundTripOracle.verify(corrupted, gates: RTMPLoopbackRunner.liveGates)
            XCTFail("live oracle accepted injected fault \(fault.rawValue): \(accepted)",
                    file: file, line: line)
        } catch let failure as AVOracleFailure {
            let observed = Set(failure.violations.map(\.code))
            XCTAssertFalse(observed.isDisjoint(with: expectedCodes),
                           "fault \(fault.rawValue) produced \(observed), expected one of \(expectedCodes)",
                           file: file, line: line)
        } catch {
            XCTFail("fault \(fault.rawValue) threw unexpected error: \(error)", file: file, line: line)
        }
    }

    private func cleanup(_ result: RTMPLoopbackRunner.Result) {
        try? FileManager.default.removeItem(at: result.movieURL.deletingLastPathComponent())
    }
}
