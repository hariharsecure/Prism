import XCTest
@testable import PrismCore

/// Deterministic, hardware-free tests for the Phase 1d perf aggregator. A fixed
/// timing series is fed in and the computed percentiles/counters are pinned to
/// known values — no GPU, no timers, no capture hardware needed.
final class RenderMetricsTests: XCTestCase {

    // MARK: PercentileRing — exact windowed percentiles

    func testExactPercentilesOverFullWindow() {
        var ring = PercentileRing(capacity: 16)
        for v in 1...10 { ring.record(Int64(v)) }
        let p = ring.percentiles()
        // Nearest-rank convention: index = ceil(pct/100 * n) - 1.
        XCTAssertEqual(p.count, 10)
        XCTAssertEqual(p.min, 1)
        XCTAssertEqual(p.p50, 5)
        XCTAssertEqual(p.p95, 10)
        XCTAssertEqual(p.p99, 10)
        XCTAssertEqual(p.max, 10)
        XCTAssertEqual(p.mean, 5.5, accuracy: 1e-9)
    }

    /// 1…100 makes p95 / p99 / max all distinct, proving they are not aliased.
    func testPercentilesAreDistinct() {
        var ring = PercentileRing(capacity: 128)
        for v in 1...100 { ring.record(Int64(v)) }
        let p = ring.percentiles()
        XCTAssertEqual(p.p50, 50)
        XCTAssertEqual(p.p95, 95)
        XCTAssertEqual(p.p99, 99)
        XCTAssertEqual(p.max, 100)
        XCTAssertEqual(p.min, 1)
    }

    /// Order of insertion must not change the result (percentiles sort).
    func testPercentilesOrderInvariant() {
        var a = PercentileRing(capacity: 32)
        var b = PercentileRing(capacity: 32)
        for v in [7, 3, 9, 1, 5, 2, 8, 4, 6, 10] { a.record(Int64(v)) }
        for v in 1...10 { b.record(Int64(v)) }
        XCTAssertEqual(a.percentiles(), b.percentiles())
    }

    func testRingEvictsOldestKeepsWindow() {
        var ring = PercentileRing(capacity: 4)
        for v in 1...6 { ring.record(Int64(v)) }   // resident window = [3,4,5,6]
        let p = ring.percentiles()
        XCTAssertEqual(p.count, 4)
        XCTAssertEqual(p.min, 3)
        XCTAssertEqual(p.max, 6)
        XCTAssertEqual(p.p50, 4)                    // ceil(0.5*4)-1 = idx 1 → 4
        XCTAssertEqual(p.mean, 4.5, accuracy: 1e-9) // (3+4+5+6)/4
        // All-time max survives eviction; lifetime count exceeds the window.
        XCTAssertEqual(ring.allTimeMax, 6)
        XCTAssertEqual(ring.lifetimeCount, 6)
    }

    func testSignedSamplesForDeadlineSlack() {
        var ring = PercentileRing(capacity: 8)
        for v in [-3, -1, 0, 2, 5] { ring.record(Int64(v)) }
        let p = ring.percentiles()
        XCTAssertEqual(p.min, -3)   // worst overrun
        XCTAssertEqual(p.max, 5)
        XCTAssertEqual(p.mean, 0.6, accuracy: 1e-9)
    }

    func testEmptyRingIsZero() {
        let ring = PercentileRing(capacity: 4)
        XCTAssertEqual(ring.percentiles(), .zero)
    }

    func testSingleSampleRing() {
        var ring = PercentileRing(capacity: 8)
        ring.record(42)
        let p = ring.percentiles()
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p.min, 42)
        XCTAssertEqual(p.p50, 42)
        XCTAssertEqual(p.p95, 42)
        XCTAssertEqual(p.p99, 42)
        XCTAssertEqual(p.max, 42)
        XCTAssertEqual(p.mean, 42, accuracy: 1e-9)
    }

    func testCapacityOneRingHoldsNewest() {
        var ring = PercentileRing(capacity: 1)
        ring.record(5)
        ring.record(9)
        let p = ring.percentiles()
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p.p50, 9)          // only the newest is resident
        XCTAssertEqual(ring.allTimeMax, 9)
        XCTAssertEqual(ring.lifetimeCount, 2)
    }

    // MARK: RenderMetrics aggregator + snapshot

    func testAggregatorSnapshotFromSyntheticSeries() {
        let m = RenderMetrics()
        // 10 frames: work 1..10 ms, slack = interval(16ms) - work.
        for w in 1...10 {
            let workNs = Int64(w) * 1_000_000
            let slackNs = Int64(16 - w) * 1_000_000
            m.recordFrame(workNanos: workNs, deadlineSlackNanos: slackNs)
        }
        // Subsystem spans.
        for g in [2, 4, 6] { m.recordGPU(.compositor, nanos: Int64(g) * 1_000_000) }
        m.recordGPU(.transition, nanos: 3_000_000)
        m.recordCPU(.sourceFX, nanos: 500_000)
        // Queue depth samples + drops.
        m.recordQueueDepth(items: 3, bytes: 3_000_000, oldestAgeMs: 12, media: .video)
        m.recordQueueDepth(items: 2, bytes: 2_000_000, oldestAgeMs: 8, media: .video)
        m.recordDelivered(.video, count: 100)
        m.recordDrop(.queueOverflow, media: .video, count: 4)
        m.recordDrop(.lateDeadline, media: .video, count: 1)
        // Periodic memory/CPU.
        m.recordMemory(physFootprintBytes: 512 * 1_048_576, metalAllocatedBytes: 128 * 1_048_576)
        m.recordCPUPercent(37.5)

        let s = m.snapshot()
        // Frame work: p50 = 5 ms, max = 10 ms.
        XCTAssertEqual(s.frameWork.p50Ms, 5, accuracy: 1e-6)
        XCTAssertEqual(s.frameWork.maxMs, 10, accuracy: 1e-6)
        XCTAssertEqual(s.frameWork.count, 10)
        // Deadline slack: worst (min) = 16 - 10 = 6 ms.
        XCTAssertEqual(s.deadlineSlack.minMs, 6, accuracy: 1e-6)
        // GPU compositor p50 over [2,4,6] = 4 ms; transition present.
        XCTAssertEqual(s.gpu(.compositor).p50Ms, 4, accuracy: 1e-6)
        XCTAssertEqual(s.gpu(.transition).maxMs, 3, accuracy: 1e-6)
        XCTAssertEqual(s.cpu(.sourceFX).maxMs, 0.5, accuracy: 1e-6)
        // Queue depth: items window [3,2], p95 = 3; bytes present; age.
        XCTAssertEqual(s.queueItems.max, 3)
        XCTAssertGreaterThan(s.queueBytes.max, 0)
        XCTAssertEqual(Double(s.queueAgeUs.max) / 1000.0, 12, accuracy: 1e-6)
        // Counters by media / reason.
        XCTAssertEqual(s.delivered(.video), 100)
        XCTAssertEqual(s.dropped(.queueOverflow), 4)
        XCTAssertEqual(s.dropped(.lateDeadline), 1)
        XCTAssertEqual(s.totalDropped, 5)
        // Memory + CPU.
        XCTAssertEqual(s.physFootprintMB, 512, accuracy: 1e-6)
        XCTAssertEqual(s.metalAllocatedMB, 128, accuracy: 1e-6)
        XCTAssertEqual(s.cpuPercent, 37.5, accuracy: 1e-9)
    }

    func testDropAndDeliverAttributionByMedia() {
        let m = RenderMetrics()
        m.recordDelivered(.video, count: 10)
        m.recordDelivered(.audio, count: 20)
        m.recordDrop(.queueOverflow, media: .video, count: 3)
        m.recordDrop(.backpressure, media: .audio, count: 5)
        let s = m.snapshot()
        XCTAssertEqual(s.delivered(.video), 10)
        XCTAssertEqual(s.delivered(.audio), 20)
        XCTAssertEqual(s.dropped(.queueOverflow), 3)
        XCTAssertEqual(s.dropped(.backpressure), 5)
        XCTAssertEqual(s.droppedByMedia[RenderMetrics.MediaType.video.rawValue], 3)
        XCTAssertEqual(s.droppedByMedia[RenderMetrics.MediaType.audio.rawValue], 5)
        XCTAssertEqual(s.totalDropped, 8)
    }

    func testSubsystemsAreIndependent() {
        let m = RenderMetrics()
        m.recordGPU(.compositor, nanos: 5_000_000)
        m.recordCPU(.transition, nanos: 1_000_000)
        let s = m.snapshot()
        XCTAssertEqual(s.gpu(.compositor).maxMs, 5, accuracy: 1e-6)
        XCTAssertEqual(s.gpu(.transition), .zero)     // untouched subsystem stays zero
        XCTAssertEqual(s.cpu(.transition).maxMs, 1, accuracy: 1e-6)
        XCTAssertEqual(s.cpu(.compositor), .zero)
    }

    /// An empty aggregator (engine never ran) yields all-zero, plausible values —
    /// the honest "no data yet" state, distinct from a ran engine's non-zeros.
    func testEmptyAggregatorIsAllZero() {
        let s = RenderMetrics().snapshot()
        XCTAssertEqual(s.frameWork, .zero)
        XCTAssertEqual(s.totalDropped, 0)
        XCTAssertEqual(s.physFootprintMB, 0)
        XCTAssertEqual(s.cpuPercent, 0)
    }

    // MARK: ProcessMetrics — real, but hardware-free (reads THIS process)

    func testProcessMemoryIsPlausible() {
        let bytes = ProcessMetrics.physFootprintBytes()
        // Any live test process footprint is comfortably in [1 MB, 100 GB].
        XCTAssertGreaterThan(bytes, 1_048_576)
        XCTAssertLessThan(bytes, 100 * 1024 * 1_048_576)
    }

    func testProcessCPUIsNonNegative() {
        XCTAssertGreaterThanOrEqual(ProcessMetrics.cpuUsagePercent(), 0)
    }

    func testMonotonicClockAdvances() {
        let a = MonotonicClock.nowNanos()
        var acc: UInt64 = 0
        for i in 0..<10_000 { acc &+= UInt64(i) }
        let b = MonotonicClock.nowNanos()
        XCTAssertGreaterThanOrEqual(b, a)
        XCTAssertGreaterThan(acc, 0) // keep the loop from being optimized away
    }
}
