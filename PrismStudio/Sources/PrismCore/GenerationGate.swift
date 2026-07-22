import Foundation
import os

/// A monotonically-incrementing **generation (epoch) token** that guards a
/// source's lifecycle boundaries.
///
/// Capture sources (camera / screen) deliver their frames and lifecycle
/// callbacks ASYNCHRONOUSLY, on private queues or from `Task`s that outlive the
/// `stop()` that retired them. When a source is stopped and (re)started, a
/// callback armed under the OLD run can still fire — a queued capture frame, a
/// ScreenCaptureKit sample, or an async `startCapture()` completion — and, unless
/// it is dropped, it posts into the SUCCESSOR run (a frame/asset from a retired
/// generation crossing the stop/restart boundary).
///
/// `GenerationGate` makes that boundary observable: every `start()`/`stop()`
/// advances the generation via `bump()`. An async callback captures the live
/// generation at arm time and, when it later runs, NO-OPs unless it still matches
/// — so a stale callback is dropped instead of mutating the live run.
///
/// Thread-safe: the counter is read on capture queues and advanced on the control
/// thread. The accept/reject decision is the pure, side-effect-free
/// `accepts(live:captured:)`, unit-testable in isolation from any real source.
public final class GenerationGate: @unchecked Sendable {
    private let value = OSAllocatedUnfairLock(initialState: UInt64(0))

    public init() {}

    /// The live generation.
    public var current: UInt64 { value.withLock { $0 } }

    /// Advance to a fresh generation (retiring the previous one) and return it.
    /// Called on BOTH `start()` and `stop()`, so *any* lifecycle boundary
    /// invalidates every in-flight callback that captured the prior value.
    @discardableResult
    public func bump() -> UInt64 { value.withLock { $0 &+= 1; return $0 } }

    /// Whether a callback that captured `captured` may still act — i.e. the live
    /// generation has not moved on since it was armed.
    public func isCurrent(_ captured: UInt64) -> Bool {
        value.withLock { Self.accepts(live: $0, captured: captured) }
    }

    /// Pure gate (unit-testable in isolation): a captured generation is accepted
    /// ONLY when it equals the live one; any other value is stale ⇒ reject.
    public static func accepts(live: UInt64, captured: UInt64) -> Bool { live == captured }
}
