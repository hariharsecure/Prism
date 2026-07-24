import XCTest
@testable import PrismCore

/// sol #19 — GetStats must NOT sort under the render/capture HOT-PATH lock.
///
/// BUG: `RenderMetrics.snapshot()` held the same `OSAllocatedUnfairLock` the hot
/// path takes (`recordFrame`/`recordCPU`/… once per tick) across ALL 13 windows
/// while each one allocated a scratch array and SORTED it (up to ~7,680 samples).
/// So every render/capture `record*` blocked behind every copy+sort during a
/// GetStats request.
///
/// FIX: under a SHORT hold of the hot-path lock, copy each window's samples into a
/// preallocated reader-side scratch bank; compute the percentiles (the sort)
/// OUTSIDE that lock. The numbers are identical; the hot path only ever waits for
/// the O(n) copy, never the O(n log n) sort.
final class RenderMetricsSnapshotLockTests: XCTestCase {

    // MARK: Numbers unchanged (fixed split == pre-fix inline)

    /// The two-phase (copy-then-sort-off-lock) snapshot yields byte-identical
    /// percentiles to the pre-fix inline (sort-under-lock) path, over a rich,
    /// window-wrapping series across every ring.
    func testPercentilesIdenticalToPreFixPath() {
        func fill(_ m: RenderMetrics) {
            // frameWork/deadlineSlack wrap their 1024-window; subsystems + queues too.
            for i in 0..<3000 {
                m.recordFrame(workNanos: Int64((i * 37) % 911),
                              deadlineSlackNanos: Int64(((i * 13) % 401) - 200))
            }
            for s in RenderMetrics.Subsystem.allCases {
                for i in 0..<1500 {
                    m.recordCPU(s, nanos: Int64((i * 7 + s.rawValue) % 613))
                    m.recordGPU(s, nanos: Int64((i * 11 + s.rawValue) % 509))
                }
            }
            for i in 0..<1500 {
                m.recordQueueDepth(items: (i % 17), bytes: (i * 128) % 9973,
                                   oldestAgeMs: Double(i % 53), media: .video)
            }
            m.recordDelivered(.video, count: 123)
            m.recordDrop(.queueOverflow, media: .audio, count: 7)
            m.recordMemory(physFootprintBytes: 640 * 1_048_576, metalAllocatedBytes: 96 * 1_048_576)
            m.recordCPUPercent(41.25)
        }

        let fixed = RenderMetrics()
        let prefix = RenderMetrics()
        fill(fixed)
        fill(prefix)
        prefix._test_sortUnderHotLock = true   // exact pre-fix inline path

        let a = fixed.snapshot()
        let b = prefix.snapshot()

        XCTAssertEqual(a.frameWork, b.frameWork)
        XCTAssertEqual(a.deadlineSlack, b.deadlineSlack)
        for s in RenderMetrics.Subsystem.allCases {
            XCTAssertEqual(a.cpu(s), b.cpu(s), "cpu[\(s)] diverged")
            XCTAssertEqual(a.gpu(s), b.gpu(s), "gpu[\(s)] diverged")
        }
        XCTAssertEqual(a.queueItems, b.queueItems)
        XCTAssertEqual(a.queueBytes, b.queueBytes)
        XCTAssertEqual(a.queueAgeUs, b.queueAgeUs)
        XCTAssertEqual(a.deliveredByMedia, b.deliveredByMedia)
        XCTAssertEqual(a.droppedByReason, b.droppedByReason)
        XCTAssertEqual(a.physFootprintMB, b.physFootprintMB, accuracy: 1e-9)
        XCTAssertEqual(a.cpuPercent, b.cpuPercent, accuracy: 1e-9)
    }

    /// Repeated snapshots (reusing the preallocated scratch banks) stay identical —
    /// the scratch is sorted in place each call, so a stale prior sort must not leak.
    func testRepeatedSnapshotsStable() {
        let m = RenderMetrics()
        for i in 0..<500 { m.recordFrame(workNanos: Int64((i * 91) % 333), deadlineSlackNanos: 0) }
        let first = m.snapshot().frameWork
        for _ in 0..<5 { XCTAssertEqual(m.snapshot().frameWork, first) }
    }

    // MARK: Lock is not held across the sort

    /// Drive `snapshot()` and, at the sort phase, fire a concurrent `record*` from
    /// another thread. FIXED: the hot-path lock is released before the sort, so the
    /// record proceeds promptly. PRE-FIX: the sort runs under the lock, so the same
    /// record blocks for the whole sort phase.
    private func recordProceedsDuringSort(preFix: Bool) -> Bool {
        let m = RenderMetrics()
        // Fill enough that the sort phase is a real, observable span.
        for i in 0..<4000 { m.recordFrame(workNanos: Int64((i * 17) % 5000), deadlineSlackNanos: 0) }
        for s in RenderMetrics.Subsystem.allCases {
            for i in 0..<512 { m.recordCPU(s, nanos: Int64(i)); m.recordGPU(s, nanos: Int64(i)) }
        }
        m._test_sortUnderHotLock = preFix

        var proceeded = false
        m._test_duringSortHook = {
            let done = DispatchSemaphore(value: 0)
            let started = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                started.signal()
                m.recordFrame(workNanos: 1, deadlineSlackNanos: 1)   // takes the hot-path lock
                done.signal()
            }
            _ = started.wait(timeout: .now() + 1)
            // Give the detached thread time to reach (and, pre-fix, block on) the lock.
            proceeded = (done.wait(timeout: .now() + 1) == .success)
        }
        _ = m.snapshot()
        m._test_duringSortHook = nil
        return proceeded
    }

    func testRecordNotBlockedDuringSort() {
        XCTAssertTrue(recordProceedsDuringSort(preFix: false),
                      "sol #19: a concurrent record* was blocked while snapshot() sorted — lock held across sort")
    }

    /// NEGATIVE CONTROL: the pre-fix inline path DOES block the record for the sort,
    /// proving the test can observe the difference (not vacuously green).
    func testPreFixBlocksRecordDuringSort() {
        XCTAssertFalse(recordProceedsDuringSort(preFix: true),
                       "negative control vacuous: the pre-fix sort-under-lock path did not block a concurrent record*")
    }
}
