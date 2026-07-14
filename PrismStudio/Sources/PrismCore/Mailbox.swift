import CoreMedia
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

    public init(depth: Int = 3) {
        precondition(depth >= 1)
        self.depth = depth
    }

    /// Producer side: newest frame in, oldest dropped beyond `depth`.
    public func post(_ frame: VideoFrame) {
        lock.withLock { state in
            state.delivered += 1
            state.slots.append(frame)
            if state.slots.count > depth {
                state.slots.removeFirst(state.slots.count - depth)
                state.dropped += 1
            }
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
