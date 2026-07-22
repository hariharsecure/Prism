import XCTest
import PrismCore
import PrismControl

/// Proves the Phase 1d "real numbers, not zeros" contract at the exact seam
/// `EngineControlBackend.stats()` uses: `EngineStats(perf:…)`. Hardware-free —
/// the aggregator is fed a synthetic "engine has run" series, then the mapped
/// EngineStats is asserted to be non-zero and plausibly shaped (previously these
/// fields were hardcoded to 0).
final class EngineStatsMappingTests: XCTestCase {

    /// Build an aggregator that looks like the engine ran for a while at 60 fps.
    private func ranAggregator() -> RenderMetrics {
        let m = RenderMetrics()
        for w in 1...60 {
            let workNs = Int64(4_000_000 + (w % 5) * 400_000)     // ~4–6 ms
            let slackNs = Int64(16_666_666) - workNs               // budget left at 60 fps
            m.recordFrame(workNanos: workNs, deadlineSlackNanos: slackNs)
        }
        m.recordGPU(.compositor, nanos: 2_500_000)
        m.recordGPU(.transition, nanos: 1_200_000)
        m.recordQueueDepth(items: 2, bytes: 2_000_000, oldestAgeMs: 5, media: .video)
        m.recordDelivered(.video, count: 60)
        m.recordDrop(.queueOverflow, media: .video, count: 2)
        m.recordMemory(physFootprintBytes: 480 * 1_048_576, metalAllocatedBytes: 96 * 1_048_576)
        m.recordCPUPercent(42)
        return m
    }

    func testMappedStatsAreNonZeroAndPlausible() {
        let s = ranAggregator().snapshot()
        let stats = EngineStats(perf: s,
                                availableDiskSpaceMB: 100_000,
                                activeFps: 60,
                                frameIntervalMs: 1000.0 / 60.0,
                                renderSkippedFrames: 0,
                                renderTotalFrames: 60,
                                outputSkippedFrames: 0,
                                outputTotalFrames: 60)

        // The formerly-hardcoded zeros are now real.
        XCTAssertGreaterThan(stats.cpuUsage, 0)                 // process CPU% (42)
        XCTAssertEqual(stats.cpuUsage, 42, accuracy: 1e-6)
        XCTAssertGreaterThan(stats.memoryUsageMB, 0)            // phys_footprint
        XCTAssertEqual(stats.memoryUsageMB, 480, accuracy: 1e-6)
        XCTAssertGreaterThan(stats.averageFrameRenderTimeMs, 0) // frame-work p50
        XCTAssertLessThan(stats.averageFrameRenderTimeMs, 16.7) // within a 60 fps budget

        // Distribution + subsystem + queue fields are populated.
        XCTAssertGreaterThan(stats.frameWorkP95Ms, 0)
        XCTAssertGreaterThanOrEqual(stats.frameWorkMaxMs, stats.frameWorkP95Ms)
        XCTAssertGreaterThan(stats.deadlineSlackP50Ms, 0)      // frames finished under budget
        XCTAssertGreaterThan(stats.gpuCompositorP95Ms, 0)
        XCTAssertGreaterThan(stats.gpuTransitionP95Ms, 0)
        XCTAssertEqual(stats.metalAllocatedMB, 96, accuracy: 1e-6)
        XCTAssertGreaterThan(stats.renderQueueDepthBytes, 0)
        XCTAssertEqual(stats.renderQueueDroppedFrames, 2)

        // Frame counters pass through.
        XCTAssertEqual(stats.renderTotalFrames, 60)
        XCTAssertEqual(stats.outputTotalFrames, 60)
    }

    /// An engine that never ran maps to honest zeros (only disk known) — the
    /// mapping does not fabricate signal.
    func testEmptyAggregatorMapsToZeroPerf() {
        let stats = EngineStats(perf: RenderMetrics().snapshot(),
                                availableDiskSpaceMB: 100_000,
                                activeFps: 60,
                                frameIntervalMs: 1000.0 / 60.0,
                                renderSkippedFrames: 0,
                                renderTotalFrames: 0,
                                outputSkippedFrames: 0,
                                outputTotalFrames: 0)
        XCTAssertEqual(stats.averageFrameRenderTimeMs, 0)
        XCTAssertEqual(stats.memoryUsageMB, 0)
        XCTAssertEqual(stats.cpuUsage, 0)
        XCTAssertEqual(stats.frameWorkMaxMs, 0)
        XCTAssertEqual(stats.availableDiskSpaceMB, 100_000, accuracy: 1e-6)
    }
}
