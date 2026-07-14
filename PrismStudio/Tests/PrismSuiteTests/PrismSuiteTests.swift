import XCTest

// CI gate wrapping every module's self-test so `swift test` (and CI) actually
// enforces the correctness envelope. These suites already existed and passed,
// but only via the `prism-dev selftest` CLI — a manual ritual, not a gate.
// (Consultation finding, 2026-07-08: unenforced verification was the top risk.)
//
// Each case calls the module's public `*SelfTest.run()` entry point and fails
// the XCTest if it throws or reports a non-passing result.

import PrismAnimation
import PrismAudio
import PrismColor
import PrismCompose
import PrismCompositor
import PrismControlSurface
import PrismDirector
import PrismExport
import PrismOutput
import PrismProximity
import PrismSound
import PrismSources
import PrismVision

final class PrismSuiteTests: XCTestCase {

    func testCompositor() throws { try CompositorSelfTest.run() }

    /// OPT#10: shared per-device Metal library cache — identical MSL compiles once,
    /// two SourceEffectGPU instances share one library, HDR toggle recompiles nothing.
    func testMetalLibraryCache() throws {
        do { try MetalLibraryCacheSelfTest.run() }
        catch MetalLibraryCacheSelfTest.Err.noDevice {
            throw XCTSkip("no Metal device on this host")
        }
    }

    func testAudioMixer() throws {
        let report = try AudioMixerSelfCheck.run()
        XCTAssertTrue(report.allPassed, report.description)
    }

    func testAnimation() throws { try AnimationSelfTest.run() }

    func testColor() throws { try ColorSelfTest.run() }

    func testChromaKey() throws { try ChromaKeySelfTest.run() }

    func testLumaKey() throws { try LumaKeySelfTest.run() }

    func testVision() throws { try VisionSelfTest.run() }

    func testSources() throws { try SourcesSelfTest.run() }

    func testExport() throws { try ExportSelfTest.run() }

    func testCompose() throws { try ComposeSelfTest.run() }

    func testOutput() async throws { _ = try await OutputSelfTest.run() }

    func testMultiDestination() async throws { _ = try await MultiDestinationSelfTest.run() }

    func testMultitrackAudio() async throws { _ = try await MultitrackAudioSelfTest.run() }

    func testLoudness() throws { try LoudnessSelfTest.run() }

    func testDucking() throws { try DuckingSelfTest.run() }

    func testAudioFindings() throws { try AudioFindingsSelfTests.run() }

    func testAudioInserts() async throws {
        let report = try await AudioInsertsSelfTest.run()
        XCTAssertTrue(report.allPassed, report.description)
    }

    func testControlSurface() throws { _ = try ControlSurfaceSelfTest.run() }

    func testProximity() throws { try ProximitySelfTest.run() }

    func testDirector() throws { try DirectorSelfTest.run() }

    func testHDRCompositor() throws { _ = try HDRSelfTest.run() }

    func testHDRRecorder() async throws { _ = try await HDRRecorderSelfTest.run() }

    func testSound() throws {
        let report = try SoundSelfTest.run()
        XCTAssertTrue(report.allPassed, report.description)
    }

    func testMusic() throws {
        let report = try MusicSelfTest.run()
        XCTAssertTrue(report.allPassed, report.description)
    }
}
