import CoreMedia
import CoreVideo
import Foundation
import os

/// Latest-wins frame mailbox between a capture source and the compositor
/// (DESIGN.md §3.3). Depth is intentionally tiny: live compositing never
/// queues deep. ISO-recording taps sit *before* the mailbox with a real FIFO.
///
/// Thread model: one producer (the source's capture queue), one consumer
/// (the render thread). The lock guards a few pointer swaps — nanoseconds —
/// which is fine at capture rates; a lock-free ring is a later optimization,
/// not a correctness need.
public final class FrameMailbox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    private struct State {
        var slots: [VideoFrame] = []
        var dropped: UInt64 = 0
        var delivered: UInt64 = 0
    }

    public let depth: Int

    /// Optional perf sink. Set by `RenderLoop.setMailbox` (its single choke
    /// point for render inputs) so drops/deliveries/depths are attributed
    /// without touching any other call site. Recording is a brief unfair-lock
    /// write — cheap enough for the capture thread's `post`.
    public var metrics: RenderMetrics?

    public init(depth: Int = 3) {
        precondition(depth >= 1)
        self.depth = depth
    }

    /// Producer side: newest frame in, oldest dropped beyond `depth`.
    public func post(_ frame: VideoFrame) {
        var droppedNow: UInt64 = 0
        lock.withLock { state in
            state.delivered += 1
            state.slots.append(frame)
            if state.slots.count > depth {
                let n = UInt64(state.slots.count - depth)
                state.slots.removeFirst(state.slots.count - depth)
                state.dropped += n
                droppedNow = n
            }
        }
        metrics?.recordDelivered(.video)
        if droppedNow > 0 { metrics?.recordDrop(.queueOverflow, media: .video, count: droppedNow) }
    }

    /// Cheap occupancy sample for depth instrumentation: current item count,
    /// total resident bytes, and the age (ms) of the oldest queued frame
    /// relative to house time `nowSeconds`. Computed under the mailbox lock over
    /// the ≤`depth` resident slots.
    public func depthSample(nowSeconds: Double) -> (items: Int, bytes: Int, oldestAgeMs: Double) {
        lock.withLock { state in
            var bytes = 0
            for f in state.slots { bytes += CVPixelBufferGetDataSize(f.pixelBuffer) }
            let oldestAgeMs: Double
            if let oldest = state.slots.first {
                oldestAgeMs = max(0, (nowSeconds - oldest.pts.seconds) * 1000.0)
            } else {
                oldestAgeMs = 0
            }
            return (state.slots.count, bytes, oldestAgeMs)
        }
    }

    /// Consumer side: newest frame with `pts <= deadline`, or the oldest
    /// available if none qualify yet and `allowFuture` is set (cold start).
    /// Frames older than the one returned are discarded.
    public func take(deadline: CMTime, allowFuture: Bool = false) -> VideoFrame? {
        lock.withLock { state in
            guard !state.slots.isEmpty else { return nil }
            var pick: Int? = nil
            for (i, f) in state.slots.enumerated() where CMTimeCompare(f.pts, deadline) <= 0 {
                pick = i
            }
            if pick == nil && allowFuture { pick = 0 }
            guard let i = pick else { return nil }
            let frame = state.slots[i]
            state.slots.removeFirst(i) // keep frames newer than the pick
            return frame
        }
    }

    /// Newest frame regardless of deadline ("Fastest" sync mode).
    public func takeNewest() -> VideoFrame? {
        lock.withLock { state in
            guard let last = state.slots.last else { return nil }
            state.slots.removeAll()
            return last
        }
    }

    public var stats: (delivered: UInt64, dropped: UInt64) {
        lock.withLock { ($0.delivered, $0.dropped) }
    }
}
