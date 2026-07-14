import CoreMedia
import Metal
import XCTest

@testable import PrismCompositor
import PrismCore

/// HIGH-5 — the HDR rebuild swaps the render loop while both the OLD and the NEW
/// loop reuse the SAME non-thread-safe animated-FX object (`SourceEffectGPU` /
/// `lastRaw`, wired as the loop's `frameProcessor`). The defect: `stop()` timed
/// out after 2 s and returned silently while `setHDREnabled` unconditionally
/// started the replacement — so if the old tick was wedged in the shared
/// processor, two render threads ran over it at once.
///
/// The fix makes `stop()` REPORT quiescence (a Bool) and the HDR swap GATE on it:
/// the replacement is never started until the old thread has confirmed exit, so
/// the shared processor is only ever entered by one thread.
///
/// These reproduce the race against a real `RenderLoop` pair sharing one
/// processor, with an in-processor concurrency detector.
final class HDRSwapQuiescenceTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    private func loop(_ device: MTLDevice, fps: Double,
                      processor: @escaping RenderLoop.FrameProcessor) throws -> RenderLoop {
        let compositor = try MetalCompositor(device: device, width: 64, height: 64)
        let l = RenderLoop(compositor: compositor, fps: fps)
        l.frameProcessor = processor
        return l
    }

    /// A shared, deliberately NON-thread-safe stand-in for the animated-FX
    /// processor. It flags any moment two threads are inside it at once, and can
    /// wedge its first caller so a second thread would overlap.
    private final class SharedFXProbe: @unchecked Sendable {
        private let obs = NSLock()
        private var inside = false
        private var wedgedOnce = false
        private(set) var concurrentEntryDetected = false
        var wedgeFirstCall = false
        let atWedge = DispatchSemaphore(value: 0)
        let releaseWedge = DispatchSemaphore(value: 0)

        func process(_ frames: [SourceID: VideoFrame], _ pts: CMTime) -> [SourceID: VideoFrame] {
            obs.lock()
            if inside { concurrentEntryDetected = true }
            inside = true
            let doWedge = wedgeFirstCall && !wedgedOnce
            if doWedge { wedgedOnce = true }
            obs.unlock()

            if doWedge { atWedge.signal(); releaseWedge.wait() } // hold `inside == true`

            obs.lock(); inside = false; obs.unlock()
            return frames
        }
    }

    // MARK: - stop() reports quiescence

    func testStopReturnsTrueWhenCleanFalseWhenWedged() throws {
        let device = try device()

        // Clean loop: stop() confirms exit → true.
        let clean = try loop(device, fps: 120) { f, _ in f }
        XCTAssertTrue(clean.start())
        XCTAssertTrue(pollUntil(1.0) { clean.stats.ticks >= 1 }, "clean loop never ticked")
        XCTAssertTrue(clean.stop(), "clean stop() must confirm quiescence")

        // Wedged loop: the tick parks in the processor → stop(timeout:) times out
        // → false; after release it exits and a later stop() returns true.
        let probe = SharedFXProbe()
        probe.wedgeFirstCall = true
        let wedged = try loop(device, fps: 120) { f, p in probe.process(f, p) }
        defer { probe.releaseWedge.signal(); wedged.stop() }
        XCTAssertTrue(wedged.start())
        XCTAssertEqual(probe.atWedge.wait(timeout: .now() + 2.0), .success, "processor never wedged")
        XCTAssertFalse(wedged.stop(timeout: 0.3), "stop() must report FALSE while the tick is wedged")

        probe.releaseWedge.signal()
        XCTAssertTrue(pollUntil(2.0) { wedged.stop(timeout: 0.2) },
                      "after the wedge released, the thread must drain and stop() report true")
    }

    // MARK: - the swap gate prevents two threads over the shared processor

    /// FIXED path: because the wedged old loop's `stop()` returns false, the swap
    /// gate refuses to start the replacement, so the shared processor is never
    /// entered concurrently.
    func testGatedSwapNeverDoubleRunsSharedProcessor() throws {
        let device = try device()
        let probe = SharedFXProbe()
        probe.wedgeFirstCall = true
        let oldLoop = try loop(device, fps: 240) { f, p in probe.process(f, p) }
        let newLoop = try loop(device, fps: 240) { f, p in probe.process(f, p) }
        defer { probe.releaseWedge.signal(); oldLoop.stop(); newLoop.stop() }

        XCTAssertTrue(oldLoop.start())
        XCTAssertEqual(probe.atWedge.wait(timeout: .now() + 2.0), .success)

        // The HDR-swap decision, exactly as setHDREnabled now makes it:
        let quiesced = oldLoop.stop(timeout: 0.3)
        XCTAssertFalse(quiesced, "old loop should not have quiesced while wedged")
        if quiesced { newLoop.start() } // gated OFF — the replacement is NOT started

        // Give any (erroneously started) second thread ample time to run.
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(probe.concurrentEntryDetected,
                       "the gate must prevent a second render thread entering the shared processor")
        XCTAssertEqual(newLoop.stats.ticks, 0, "the replacement loop must not have started")
    }

    /// NEGATIVE CONTROL: the old (ungated) behavior — start the replacement
    /// regardless of quiescence — DOES run two threads over the shared processor.
    /// Proves the detector is real and the gate is load-bearing (not a tautology).
    func testUngatedSwapDoesDoubleRunSharedProcessor() throws {
        let device = try device()
        let probe = SharedFXProbe()
        probe.wedgeFirstCall = true
        let oldLoop = try loop(device, fps: 240) { f, p in probe.process(f, p) }
        let newLoop = try loop(device, fps: 240) { f, p in probe.process(f, p) }
        defer { probe.releaseWedge.signal(); oldLoop.stop(); newLoop.stop() }

        XCTAssertTrue(oldLoop.start())
        XCTAssertEqual(probe.atWedge.wait(timeout: .now() + 2.0), .success)

        // Ungated: ignore stop()'s result and start the replacement anyway.
        _ = oldLoop.stop(timeout: 0.2)
        XCTAssertTrue(newLoop.start())

        // The replacement's tick enters the shared processor while the old tick is
        // still wedged inside it → concurrent entry.
        XCTAssertTrue(pollUntil(2.0) { probe.concurrentEntryDetected },
                      "ungated double-run must be caught entering the shared processor concurrently")
    }

    // MARK: - helper
    private func pollUntil(_ timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return predicate()
    }
}
