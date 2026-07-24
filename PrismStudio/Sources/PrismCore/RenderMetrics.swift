import Darwin
import Foundation
import os

/// Real, low-overhead performance instrumentation for the render pipeline
/// (Roadmap Phase 1d). The design goals, in priority order:
///
///  1. **Non-perturbing.** The hot path (render thread, capture threads) only
///     ever writes a handful of integers into pre-allocated storage under a
///     brief `OSAllocatedUnfairLock` — the same nanosecond-scale primitive the
///     `RenderLoop`/`FrameMailbox` already take once per tick. No allocation,
///     no syscalls, no sorting on the hot path. The expensive work (copying a
///     window, sorting for percentiles, reading `task_info`) happens only when
///     a *reader* (`EngineControlBackend.stats()`, a GetStats request) asks —
///     at human/websocket cadence, off the render thread.
///  2. **Trustworthy distribution, not last-value.** Frame work and every span
///     are kept in a bounded ring so we report p50/p95/p99/max over a real
///     window instead of a single eyeballed number that hides serialization.
///  3. **Correct on real hardware.** Timings come from a monotonic uptime clock
///     and from `MTLCommandBuffer.gpuStartTime/gpuEndTime`; memory from
///     `phys_footprint`. Nothing is faked — on a base-M Mac these fields carry
///     real thermal/capacity signal; headless they carry the injected/GPU-less
///     values, and the *math* is what the unit tests pin down.
public final class RenderMetrics: @unchecked Sendable {

    // MARK: Fixed vocabularies (allocation-free indexing)

    /// Pipeline stages we time independently. Fixed set → array-indexed storage,
    /// so recording never touches a dictionary on the hot path.
    public enum Subsystem: Int, CaseIterable, Sendable {
        case compositor      // primary scene render pass (single command buffer)
        case sourceFX        // per-source time-varying effects (render-thread CPU)
        case transition      // mix / overlay / effect transition composite
        case hdrTransfer     // HLG encode / HDR→SDR final transfer
    }

    /// Queue media classes, for depth attribution.
    public enum MediaType: Int, CaseIterable, Sendable {
        case video, audio, data
    }

    /// Why a queued item was dropped rather than delivered.
    public enum DropReason: Int, CaseIterable, Sendable {
        case queueOverflow   // mailbox past depth (newest-wins eviction)
        case lateDeadline    // arrived after its render deadline
        case decodeError     // could not be decoded
        case backpressure    // downstream (encoder/transport) could not keep up
    }

    // MARK: Storage (guarded by the lock)

    private struct Storage {
        // The one number that matters most: total CPU frame work + how much of
        // the frame budget was left (deadline slack; negative = overran).
        var frameWork = PercentileRing(capacity: 1024)      // nanoseconds
        var deadlineSlack = PercentileRing(capacity: 1024)  // nanoseconds, signed

        // Per-subsystem CPU + GPU spans (nanoseconds).
        var cpu: [PercentileRing]
        var gpu: [PercentileRing]

        // Queue depth distributions.
        var queueItems = PercentileRing(capacity: 512)      // count
        var queueBytes = PercentileRing(capacity: 512)      // bytes
        var queueAgeUs = PercentileRing(capacity: 512)      // microseconds (oldest item)

        // Running counters, by media type / drop reason.
        var deliveredByMedia = [UInt64](repeating: 0, count: MediaType.allCases.count)
        var droppedByMedia = [UInt64](repeating: 0, count: MediaType.allCases.count)
        var droppedByReason = [UInt64](repeating: 0, count: DropReason.allCases.count)

        // Periodically-sampled memory + CPU (a light timer, not per-frame).
        var physFootprintBytes: UInt64 = 0
        var metalAllocatedBytes: UInt64 = 0
        var cpuPercent: Double = 0

        init() {
            cpu = (0..<Subsystem.allCases.count).map { _ in PercentileRing(capacity: 512) }
            gpu = (0..<Subsystem.allCases.count).map { _ in PercentileRing(capacity: 512) }
        }
    }

    private let lock = OSAllocatedUnfairLock<Storage>(initialState: Storage())

    // MARK: Reader-side scratch (sol #19)

    /// Preallocated per-ring copy buffers, sized to each ring's capacity so
    /// `snapshot()` copies windows out under the hot-path lock WITHOUT allocating,
    /// then sorts them here — off that lock. Guarded by its OWN lock so concurrent
    /// readers serialize among themselves and NEVER on the hot-path `lock`. The
    /// bank order is fixed: [frameWork, deadlineSlack, cpu×N, gpu×N, queueItems,
    /// queueBytes, queueAgeUs] (N = Subsystem.allCases.count).
    private struct ReaderScratch {
        var banks: [[Int64]]
        init() {
            let n = Subsystem.allCases.count
            var b: [[Int64]] = [
                [Int64](repeating: 0, count: 1024),   // frameWork
                [Int64](repeating: 0, count: 1024),   // deadlineSlack
            ]
            b.append(contentsOf: (0..<n).map { _ in [Int64](repeating: 0, count: 512) }) // cpu
            b.append(contentsOf: (0..<n).map { _ in [Int64](repeating: 0, count: 512) }) // gpu
            b.append([Int64](repeating: 0, count: 512))   // queueItems
            b.append([Int64](repeating: 0, count: 512))   // queueBytes
            b.append([Int64](repeating: 0, count: 512))   // queueAgeUs
            banks = b
        }
    }
    private let readerScratch = OSAllocatedUnfairLock<ReaderScratch>(initialState: ReaderScratch())

    #if DEBUG
    /// Repro seam (sol #19): reproduce the PRE-FIX behaviour — allocate + sort every
    /// window UNDER the hot-path lock (the original inline `snapshot()`), so a test
    /// can prove a concurrent `record*` is blocked for the whole sort. Default off.
    public var _test_sortUnderHotLock = false
    /// Repro seam (sol #19): invoked once during `snapshot()`'s percentile (sort)
    /// phase — with the hot-path lock RELEASED in the fixed path, HELD in the
    /// `_test_sortUnderHotLock` pre-fix path. A test uses it to prove a concurrent
    /// `record*` proceeds (fixed) / blocks (pre-fix) while percentiles are computed.
    public var _test_duringSortHook: (() -> Void)?
    #endif

    public init() {}

    // MARK: Hot-path recording (called on render / capture threads)

    /// One rendered frame: total CPU work (ns) and the budget that remained
    /// before the next scheduled tick (ns; negative means the frame overran).
    @inline(__always)
    public func recordFrame(workNanos: Int64, deadlineSlackNanos: Int64) {
        lock.withLock {
            $0.frameWork.record(workNanos)
            $0.deadlineSlack.record(deadlineSlackNanos)
        }
    }

    /// A CPU span for one subsystem (ns).
    @inline(__always)
    public func recordCPU(_ subsystem: Subsystem, nanos: Int64) {
        lock.withLock { $0.cpu[subsystem.rawValue].record(nanos) }
    }

    /// A GPU span for one subsystem, from `gpuEndTime − gpuStartTime` (ns).
    @inline(__always)
    public func recordGPU(_ subsystem: Subsystem, nanos: Int64) {
        lock.withLock { $0.gpu[subsystem.rawValue].record(nanos) }
    }

    /// A snapshot of one queue's occupancy at a tick, attributed to a media
    /// type. `oldestAgeMs` is the age of the oldest queued item (its head-of-line
    /// latency). A depth sample is an observation, not a delivery/drop.
    @inline(__always)
    public func recordQueueDepth(items: Int, bytes: Int, oldestAgeMs: Double, media: MediaType) {
        lock.withLock {
            $0.queueItems.record(Int64(items))
            $0.queueBytes.record(Int64(bytes))
            $0.queueAgeUs.record(Int64((oldestAgeMs * 1000).rounded()))
        }
    }

    /// Delivered items (producer accepted into a queue).
    @inline(__always)
    public func recordDelivered(_ media: MediaType, count: UInt64 = 1) {
        lock.withLock { $0.deliveredByMedia[media.rawValue] += count }
    }

    /// Dropped items, attributed to a reason and media type.
    @inline(__always)
    public func recordDrop(_ reason: DropReason, media: MediaType, count: UInt64 = 1) {
        lock.withLock {
            $0.droppedByReason[reason.rawValue] += count
            $0.droppedByMedia[media.rawValue] += count
        }
    }

    // MARK: Periodic sampling (called off the hot path, e.g. a 1 Hz timer)

    /// Record the latest memory footprint. `metalAllocatedBytes` is
    /// `MTLDevice.currentAllocatedSize` (0 if unknown / no device).
    public func recordMemory(physFootprintBytes: UInt64, metalAllocatedBytes: UInt64) {
        lock.withLock {
            $0.physFootprintBytes = physFootprintBytes
            $0.metalAllocatedBytes = metalAllocatedBytes
        }
    }

    /// Record the latest whole-process CPU utilization (percent; can exceed 100
    /// across cores).
    public func recordCPUPercent(_ percent: Double) {
        lock.withLock { $0.cpuPercent = percent }
    }

    // MARK: Reader-side snapshot (off the hot path)

    /// Distribution over a window of samples, in the sample's native unit.
    public struct Percentiles: Sendable, Equatable {
        public var count: Int = 0
        public var min: Int64 = 0
        public var p50: Int64 = 0
        public var p95: Int64 = 0
        public var p99: Int64 = 0
        public var max: Int64 = 0
        public var mean: Double = 0

        public static let zero = Percentiles()

        /// Interpret the stored nanosecond values as milliseconds.
        public var p50Ms: Double { Double(p50) / 1_000_000 }
        public var p95Ms: Double { Double(p95) / 1_000_000 }
        public var p99Ms: Double { Double(p99) / 1_000_000 }
        public var maxMs: Double { Double(max) / 1_000_000 }
        public var minMs: Double { Double(min) / 1_000_000 }
        public var meanMs: Double { mean / 1_000_000 }
    }

    /// Immutable, `Sendable` copy of every metric — what readers consume.
    public struct Snapshot: Sendable {
        public var frameWork: Percentiles          // ns
        public var deadlineSlack: Percentiles       // ns (signed)
        public var cpu: [Percentiles]               // ns, indexed by Subsystem.rawValue
        public var gpu: [Percentiles]               // ns, indexed by Subsystem.rawValue
        public var queueItems: Percentiles          // count
        public var queueBytes: Percentiles          // bytes
        public var queueAgeUs: Percentiles          // microseconds (oldest queued item)
        public var deliveredByMedia: [UInt64]
        public var droppedByMedia: [UInt64]
        public var droppedByReason: [UInt64]
        public var physFootprintMB: Double
        public var metalAllocatedMB: Double
        public var cpuPercent: Double

        public func cpu(_ s: Subsystem) -> Percentiles { cpu[s.rawValue] }
        public func gpu(_ s: Subsystem) -> Percentiles { gpu[s.rawValue] }
        public func dropped(_ r: DropReason) -> UInt64 { droppedByReason[r.rawValue] }
        public func delivered(_ m: MediaType) -> UInt64 { deliveredByMedia[m.rawValue] }

        /// Total drops across all reasons.
        public var totalDropped: UInt64 { droppedByReason.reduce(0, +) }
    }

    /// Compute a consistent snapshot. sol #19: the render/capture hot path only ever
    /// blocks for PHASE 1 — an O(n) copy of each window's samples out under a SHORT
    /// hold of the hot-path lock. The O(n log n) percentile sorts (PHASE 2) run OFF
    /// that lock, so a `record*` on the render thread is never serialized behind up
    /// to 13 windows' worth of sorting during a GetStats request. The numbers are
    /// byte-for-byte identical to the old sort-under-the-lock path.
    public func snapshot() -> Snapshot {
        #if DEBUG
        if _test_sortUnderHotLock {
            // NEGATIVE CONTROL: the exact pre-fix path — allocate + sort every window
            // while holding the hot-path lock (`percentiles()` does both), with the
            // sort-phase hook fired UNDER the lock so a concurrent record* blocks.
            return lock.withLock { s in
                _test_duringSortHook?()
                return Snapshot(
                    frameWork: s.frameWork.percentiles(),
                    deadlineSlack: s.deadlineSlack.percentiles(),
                    cpu: s.cpu.map { $0.percentiles() },
                    gpu: s.gpu.map { $0.percentiles() },
                    queueItems: s.queueItems.percentiles(),
                    queueBytes: s.queueBytes.percentiles(),
                    queueAgeUs: s.queueAgeUs.percentiles(),
                    deliveredByMedia: s.deliveredByMedia,
                    droppedByMedia: s.droppedByMedia,
                    droppedByReason: s.droppedByReason,
                    physFootprintMB: Double(s.physFootprintBytes) / 1_048_576,
                    metalAllocatedMB: Double(s.metalAllocatedBytes) / 1_048_576,
                    cpuPercent: s.cpuPercent)
            }
        }
        #endif
        return readerScratch.withLock { scratch -> Snapshot in
            let n = Subsystem.allCases.count
            var meta = [(count: Int, sum: Int64)](repeating: (0, 0), count: scratch.banks.count)

            // PHASE 1 — SHORT hot-path lock: copy windows + snapshot counters. No sort.
            let flat: FlatCounters = lock.withLock { s in
                meta[0] = s.frameWork.copyWindow(into: &scratch.banks[0])
                meta[1] = s.deadlineSlack.copyWindow(into: &scratch.banks[1])
                var idx = 2
                for i in 0..<n { meta[idx] = s.cpu[i].copyWindow(into: &scratch.banks[idx]); idx += 1 }
                for i in 0..<n { meta[idx] = s.gpu[i].copyWindow(into: &scratch.banks[idx]); idx += 1 }
                let itemsIdx = idx, bytesIdx = idx + 1, ageIdx = idx + 2
                meta[itemsIdx] = s.queueItems.copyWindow(into: &scratch.banks[itemsIdx])
                meta[bytesIdx] = s.queueBytes.copyWindow(into: &scratch.banks[bytesIdx])
                meta[ageIdx] = s.queueAgeUs.copyWindow(into: &scratch.banks[ageIdx])
                return FlatCounters(
                    deliveredByMedia: s.deliveredByMedia,
                    droppedByMedia: s.droppedByMedia,
                    droppedByReason: s.droppedByReason,
                    physFootprintBytes: s.physFootprintBytes,
                    metalAllocatedBytes: s.metalAllocatedBytes,
                    cpuPercent: s.cpuPercent)
            }

            #if DEBUG
            _test_duringSortHook?()   // hot-path lock released → a concurrent record* proceeds
            #endif

            // PHASE 2 — OFF the hot-path lock: sort each copied window + reduce. Plain
            // loops (no nested closures over the inout `scratch`) so bank order stays
            // aligned with PHASE 1.
            var out = [Percentiles](repeating: .zero, count: scratch.banks.count)
            for i in 0..<scratch.banks.count {
                out[i] = PercentileRing.percentiles(sorting: &scratch.banks[i],
                                                    count: meta[i].count, sum: meta[i].sum)
            }
            let itemsIdx = 2 + 2 * n, bytesIdx = 2 + 2 * n + 1, ageIdx = 2 + 2 * n + 2
            return Snapshot(
                frameWork: out[0],
                deadlineSlack: out[1],
                cpu: Array(out[2 ..< (2 + n)]),
                gpu: Array(out[(2 + n) ..< (2 + 2 * n)]),
                queueItems: out[itemsIdx],
                queueBytes: out[bytesIdx],
                queueAgeUs: out[ageIdx],   // unit = microseconds; caller uses raw/1000
                deliveredByMedia: flat.deliveredByMedia,
                droppedByMedia: flat.droppedByMedia,
                droppedByReason: flat.droppedByReason,
                physFootprintMB: Double(flat.physFootprintBytes) / 1_048_576,
                metalAllocatedMB: Double(flat.metalAllocatedBytes) / 1_048_576,
                cpuPercent: flat.cpuPercent)
        }
    }

    /// The non-distribution counters copied out under the hot-path lock alongside
    /// the sample windows (sol #19 PHASE 1).
    private struct FlatCounters {
        var deliveredByMedia: [UInt64]
        var droppedByMedia: [UInt64]
        var droppedByReason: [UInt64]
        var physFootprintBytes: UInt64
        var metalAllocatedBytes: UInt64
        var cpuPercent: Double
    }
}

// MARK: - PercentileRing

/// Fixed-capacity ring of recent samples supporting *exact* windowed
/// percentiles. Recording is O(1) and allocation-free (writes into a
/// pre-allocated `[Int64]`). Percentiles are computed on demand by copying the
/// resident window into a scratch array and sorting — deliberately off the hot
/// path. Samples are `Int64` so signed values (deadline slack) work too.
public struct PercentileRing: Sendable {
    private var storage: [Int64]
    private var head = 0            // next write index
    private var count = 0           // number of valid samples (≤ capacity)
    private var residentSum: Int64 = 0
    /// Worst value ever seen (all-time), independent of the resident window —
    /// the "worst frame we have ever produced" capacity signal.
    public private(set) var allTimeMax: Int64 = .min
    /// Lifetime number of samples recorded (may exceed the window).
    public private(set) var lifetimeCount: UInt64 = 0

    public init(capacity: Int) {
        precondition(capacity > 0)
        storage = [Int64](repeating: 0, count: capacity)
    }

    @inline(__always)
    public mutating func record(_ value: Int64) {
        if count == storage.count {
            residentSum -= storage[head]      // evict the sample being overwritten
        } else {
            count += 1
        }
        storage[head] = value
        residentSum += value
        head += 1
        if head == storage.count { head = 0 }
        if value > allTimeMax { allTimeMax = value }
        lifetimeCount &+= 1
    }

    /// Nearest-rank percentile of the resident window. `p` in [0, 100].
    /// Exact for the window (no bucket approximation). Allocates + sorts a private
    /// scratch — used by unit tests and any caller that isn't on the hot-path lock.
    /// The reader-side `RenderMetrics.snapshot()` instead uses the two-phase
    /// `copyWindow` / `percentiles(sorting:)` split so the sort never runs under the
    /// hot-path lock (sol #19).
    public func percentiles() -> RenderMetrics.Percentiles {
        guard count > 0 else { return .zero }
        // Valid samples always occupy indices 0..<count: the head only wraps
        // after the window has filled, at which point count == capacity.
        var scratch = Array(storage[0..<count])
        return Self.percentiles(sorting: &scratch, count: count, sum: residentSum)
    }

    /// sol #19 — PHASE 1 (runs under the hot-path lock): copy the resident window's
    /// samples into `scratch` and hand back the counters needed to finish the
    /// percentiles LATER, off the lock. Only an O(n) memcpy — no sort, no
    /// allocation once `scratch` is preallocated to the ring's capacity (the reader
    /// preallocates it), so a concurrent hot-path `record` waits at most for the
    /// copy, never for the O(n log n) sort.
    @inline(__always)
    func copyWindow(into scratch: inout [Int64]) -> (count: Int, sum: Int64) {
        if scratch.count < count {
            scratch = [Int64](repeating: 0, count: Swift.max(count, storage.count))
        }
        if count > 0 {
            storage.withUnsafeBufferPointer { src in
                scratch.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.update(from: src.baseAddress!, count: count)
                }
            }
        }
        return (count, residentSum)
    }

    /// sol #19 — PHASE 2 (runs OFF the hot-path lock): sort the copied window IN
    /// PLACE and reduce it to percentiles. Identical math to `percentiles()`, just
    /// separated so the sort is paid outside any lock the render/capture threads
    /// contend on.
    static func percentiles(sorting scratch: inout [Int64], count: Int, sum: Int64)
        -> RenderMetrics.Percentiles {
        guard count > 0 else { return .zero }
        scratch[0..<count].sort()
        func rank(_ p: Int) -> Int {
            let r = Int((Double(p) / 100.0 * Double(count)).rounded(.up)) - 1
            return Swift.min(count - 1, Swift.max(0, r))
        }
        return RenderMetrics.Percentiles(
            count: count,
            min: scratch[0],
            p50: scratch[rank(50)],
            p95: scratch[rank(95)],
            p99: scratch[rank(99)],
            max: scratch[count - 1],
            mean: Double(sum) / Double(count))
    }
}

// MARK: - ProcessMetrics (memory + CPU, syscall-backed; off the hot path)

/// Whole-process resource readings via Mach `task_info` / `thread_info`. These
/// call into the kernel, so they are only ever invoked by the periodic sampler
/// / a stats() reader — never per frame.
public enum ProcessMetrics {

    /// `phys_footprint` (the number Activity Monitor's "Memory" column shows),
    /// in bytes. 0 if the query fails.
    public static func physFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    /// Instantaneous whole-process CPU utilization in percent (sum of live
    /// threads' `cpu_usage`; can exceed 100 across cores). 0 if the query fails.
    public static func cpuUsagePercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threadList else { return 0 }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: threadList)),
                          vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
        }
        let usageScale = 1000.0 // TH_USAGE_SCALE / 1000 → percent (TH_USAGE_SCALE = 1_000_000)
        let idleFlag: integer_t = 0x2 // TH_FLAGS_IDLE
        var total = 0.0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(
                MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threadList[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            if kr == KERN_SUCCESS, (info.flags & idleFlag) == 0 {
                total += Double(info.cpu_usage) / usageScale
            }
        }
        return total
    }
}

// MARK: - Monotonic clock

/// Monotonic nanosecond clock (`CLOCK_UPTIME_RAW`) for measuring spans without
/// wall-clock jumps or sleep drift. Reading is a couple of instructions and
/// allocation-free.
public enum MonotonicClock {
    @inline(__always)
    public static func nowNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }
}
