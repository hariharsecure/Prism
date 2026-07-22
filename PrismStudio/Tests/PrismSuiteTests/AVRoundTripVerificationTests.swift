import Foundation
import XCTest

@testable import PrismAVTestKit

final class AVRoundTripVerificationTests: XCTestCase {
    /// Pin every default so this integration fixture cannot drift when unrelated
    /// product defaults change.
    private static let fixedConfiguration = AVRoundTripConfiguration(
        seed: 0x5052_4953_4D41_5631,
        width: 320,
        height: 192,
        fps: 30,
        frameCount: 18,
        videoBitrate: 8_000_000,
        patchTolerance: 28,
        avSkewBudgetMilliseconds: 8,
        audioSampleRate: 48_000,
        audioChunkFrames: 960,
        expectedRangeTag: .video
    )

    func testDeterministicAVRoundTripPassesAndWritesEvidence() async throws {
        let result = try await runBaseline()
        defer { removeArtifacts(for: result) }

        XCTAssertTrue(result.verification.passed)
        XCTAssertEqual(result.evidence.expectedFrameIDs.count,
                       result.evidence.decodedFrames.count)
        XCTAssertEqual(result.evidence.expectedFrameIDs.count,
                       Self.fixedConfiguration.frameCount)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.artifact.evidenceURL.path),
                      "round-trip must leave its JSON evidence artifact on disk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.movieURL.path),
                      "round-trip must leave its muxed movie on disk")
    }

    func testOracleRejectsShiftedAudioPTS() async throws {
        let result = try await runBaseline()
        defer { removeArtifacts(for: result) }

        XCTAssertTrue(result.verification.passed, "negative control requires a passing baseline")
        assertOracleRejects(result.evidence.injecting(.audioPTSShift),
                            fault: .audioPTSShift,
                            expectedAnyOf: [.avSkew])
    }

    func testOracleRejectsSwappedRangeTag() async throws {
        let result = try await runBaseline()
        defer { removeArtifacts(for: result) }

        XCTAssertTrue(result.verification.passed, "negative control requires a passing baseline")
        assertOracleRejects(result.evidence.injecting(.rangeTagSwap),
                            fault: .rangeTagSwap,
                            expectedAnyOf: [.rangeTag])
    }

    func testOracleRejectsDroppedFrame() async throws {
        let result = try await runBaseline()
        defer { removeArtifacts(for: result) }

        XCTAssertTrue(result.verification.passed, "negative control requires a passing baseline")
        assertOracleRejects(result.evidence.injecting(.frameDrop),
                            fault: .frameDrop,
                            expectedAnyOf: [.frameCount, .frameIdentity])
    }

    func testOracleRejectsTruncatedStream() async throws {
        let result = try await runBaseline()
        defer { removeArtifacts(for: result) }

        XCTAssertTrue(result.verification.passed, "negative control requires a passing baseline")
        assertOracleRejects(result.evidence.injecting(.truncateTail),
                            fault: .truncateTail,
                            expectedAnyOf: [.frameCount, .frameIdentity, .cleanFinalization])
    }

    /// Capability skips are intentionally narrow. Every other runner error is
    /// rethrown so an encode, mux, decode, evidence, or oracle regression fails.
    private func runBaseline() async throws -> AVRoundTripRunner.Result {
        do {
            return try await AVRoundTripRunner.run(configuration: Self.fixedConfiguration)
        } catch let error as AVRoundTripRunner.RunError where error.isCapabilityUnavailable {
            throw XCTSkip("deterministic A/V round trip unavailable on this host: \(error)")
        }
    }

    private func assertOracleRejects(
        _ corruptedEvidence: AVRoundTripEvidence,
        fault: AVRoundTripFault,
        expectedAnyOf expectedCodes: Set<AVOracleAssertionCode>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let accepted = try AVRoundTripOracle.verify(corruptedEvidence)
            XCTFail("oracle accepted injected fault \(fault.rawValue): \(accepted)",
                    file: file, line: line)
        } catch let failure as AVOracleFailure {
            let observedCodes = Set(failure.violations.map(\.code))
            XCTAssertFalse(observedCodes.isDisjoint(with: expectedCodes),
                           "fault \(fault.rawValue) produced \(observedCodes), expected one of \(expectedCodes)",
                           file: file, line: line)
        } catch {
            XCTFail("fault \(fault.rawValue) threw unexpected error type: \(error)",
                    file: file, line: line)
        }
    }

    private func removeArtifacts(for result: AVRoundTripRunner.Result) {
        try? FileManager.default.removeItem(at: result.movieURL)
        try? FileManager.default.removeItem(at: result.artifact.directoryURL)
    }
}
