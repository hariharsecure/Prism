import CoreMedia
import CoreVideo
import Foundation
import os
import PrismCore

/// Factory for an internal repeating tick on a serial queue at a target fps.
/// The mutable timer handle is owned by `TimedVideoSource.Lifecycle`, under the
/// same lock as the public lifecycle state and run generation.
final class SourceTimer {
    let queue: DispatchQueue
    private let interval: DispatchTimeInterval

    init(fps: Double, queue: DispatchQueue) {
        self.queue = queue
        let clamped = max(fps, 0.001)
        self.interval = .nanoseconds(Int(1_000_000_000.0 / clamped))
    }

    func makeTimer(_ handler: @escaping () -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        t.setEventHandler(handler: handler)
        return t
    }
}

/// Base for generated `VideoSource`s driven by an internal timer thread.
///
/// Subclasses override `willStart()` (load resources; may throw), `didStart()`
/// (optional eager work after `.running` commits), `tick()` (produce & emit a
/// frame — runs on `queue`) and optionally `willStop()`.
/// Frames are always stamped in house time (`HouseClock`) and emitted through
/// `emit(_:pts:)` on the source `queue`.
public class TimedVideoSource: VideoSource {
    public let id: SourceID
    public private(set) var state: SourceState {
        get { lifecycleLock.withLock { $0.state } }
        set { lifecycleLock.withLock { $0.state = newValue } }
    }
    /// Set before `start()`. Called on the source's serial queue.
    public var onFrame: ((VideoFrame) -> Void)?

    /// Target emit rate. Read-only after init.
    public let fps: Double

    let queue: DispatchQueue
    let frameDuration: CMTime
    private let timerFactory: SourceTimer

    /// State, generation, and timer ownership move together under this lock.
    /// A generation is invalidated as soon as `stop()` begins, before an
    /// external caller drains `queue`, so an in-flight render cannot emit a
    /// stale frame while the drain is in progress.
    private struct Lifecycle {
        var state: SourceState = .idle
        var generation: UInt64 = 0
        var timer: DispatchSourceTimer?
        var stopCompletion: DispatchGroup?
    }
    private let lifecycleLock = OSAllocatedUnfairLock(initialState: Lifecycle())

    /// Identifies callback-originated lifecycle calls without relying on thread
    /// identity (a serial dispatch queue may execute on different threads).
    private let queueKey = DispatchSpecificKey<UInt8>()

    /// Source-queue-only provenance for the currently executing `didStart()` or
    /// timer tick. `emit` validates this exact token, which prevents the tail of
    /// an old tick from emitting into a stop-then-started run.
    private var deliveryGeneration: UInt64?

    init(id: SourceID, fps: Double, label: String) {
        self.id = id
        self.fps = fps
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.timerFactory = SourceTimer(fps: fps, queue: queue)
        self.frameDuration = CMTime(seconds: 1.0 / max(fps, 0.001), preferredTimescale: 600)
        self.queue.setSpecific(key: queueKey, value: 1)
    }

    // MARK: Overridable

    /// Load resources before the timer starts. Throwing marks the source failed.
    func willStart() throws {}
    /// Perform work that requires a committed `.running` state. Runs on
    /// `queue`; an eager frame belongs here rather than in `willStart()`.
    func didStart() throws {}
    /// Produce and emit one frame. Runs on `queue`.
    func tick() {}
    /// Release resources after the timer stops.
    func willStop() {}

    // MARK: Lifecycle (final)

    public final func start() throws {
        let generation: UInt64? = lifecycleLock.withLock { lifecycle in
            guard lifecycle.state == .idle || lifecycle.state == .failed else { return nil }
            lifecycle.generation &+= 1
            lifecycle.state = .starting
            return lifecycle.generation
        }
        guard let generation else { return }

        do {
            try willStart()
        } catch {
            lifecycleLock.withLock { lifecycle in
                if lifecycle.state == .starting, lifecycle.generation == generation {
                    lifecycle.state = .failed
                }
            }
            throw error
        }

        // `stop()` may have invalidated this run while `willStart()` was doing
        // synchronous setup. Never resurrect that stopped generation.
        let committed = lifecycleLock.withLock { lifecycle in
            guard lifecycle.state == .starting, lifecycle.generation == generation else {
                return false
            }
            lifecycle.state = .running
            return true
        }
        guard committed else { return }

        // Eager work is serialized with timer ticks and tagged with this run's
        // exact generation. In particular, CharacterSource's first callback can
        // call stop() here; the timer is launched only if the run survives it.
        let didStartResult: Result<Void, Error> = onSourceQueue {
            guard self.isRunning(generation) else { return .success(()) }
            return Result {
                try self.withDeliveryGeneration(generation) {
                    try self.didStart()
                }
            }
        }
        if case .failure(let error) = didStartResult {
            let timer = lifecycleLock.withLock { lifecycle -> DispatchSourceTimer? in
                guard lifecycle.state == .running, lifecycle.generation == generation else {
                    return nil
                }
                lifecycle.state = .failed
                let timer = lifecycle.timer
                lifecycle.timer = nil
                return timer
            }
            timer?.cancel()
            throw error
        }

        lifecycleLock.withLock { lifecycle in
            guard lifecycle.state == .running, lifecycle.generation == generation else { return }
            let timer = timerFactory.makeTimer { [weak self] in
                self?.runTick(generation: generation)
            }
            lifecycle.timer = timer
            timer.resume()
        }
    }

    public final func stop() {
        let onQueue = isOnSourceQueue

        enum Action {
            case none
            case wait(DispatchGroup)
            case perform(generation: UInt64, timer: DispatchSourceTimer?, completion: DispatchGroup)
        }

        let action: Action = lifecycleLock.withLock { lifecycle in
            if lifecycle.state == .stopping {
                if let completion = lifecycle.stopCompletion { return .wait(completion) }
                return .none
            }
            guard lifecycle.state == .running || lifecycle.state == .starting || lifecycle.state == .failed else {
                return .none
            }

            lifecycle.generation &+= 1
            lifecycle.state = .stopping
            let timer = lifecycle.timer
            lifecycle.timer = nil
            let completion = DispatchGroup()
            completion.enter()
            lifecycle.stopCompletion = completion
            return .perform(generation: lifecycle.generation, timer: timer, completion: completion)
        }

        switch action {
        case .none:
            return
        case .wait(let completion):
            // A callback-originated repeat stop must let the callback unwind so
            // the external stop that owns the drain can make progress.
            if !onQueue { completion.wait() }
        case .perform(let generation, let timer, let completion):
            timer?.cancel()

            // An external stop waits for the source queue to finish any render
            // or callback already in flight. A nested stop is itself on that
            // queue, so attempting the same synchronous drain would deadlock.
            if !onQueue { queue.sync {} }
            willStop()

            lifecycleLock.withLock { lifecycle in
                if lifecycle.state == .stopping, lifecycle.generation == generation {
                    lifecycle.state = .idle
                    lifecycle.stopCompletion = nil
                }
            }
            completion.leave()
        }
    }

    /// Emit an IOSurface-backed frame with a fresh house-time PTS.
    func emit(_ pixelBuffer: CVPixelBuffer, pts: CMTime? = nil) {
        // Every emit must carry the run token of the tick / `didStart()` that
        // produced it (set by `withDeliveryGeneration`), or, for deferred async
        // work, the token captured at request time via `emitDeferred`. There is
        // NO fallback to the current generation: a tokenless emit is a stale
        // deferred completion from a run that has since ended (a WebKit snapshot
        // landing after a stop/restart) — drop it rather than let old-run pixels
        // adopt the new run's generation and surface in it.
        guard let generation = deliveryGeneration else { return }
        guard isRunning(generation) else { return }
        let frame = VideoFrame(pixelBuffer: pixelBuffer,
                               pts: pts ?? HouseClock.now(),
                               duration: frameDuration,
                               source: id)
        guard isRunning(generation) else { return }
        onFrame?(frame)
    }

    /// The run generation of the tick / `didStart()` currently executing on the
    /// source queue. Deferred async work (e.g. a `WKWebView` snapshot) captures
    /// this at the moment it is REQUESTED and hands it back to
    /// `emitDeferred(_:capturedToken:)` on completion, so a frame produced for an
    /// old run is dropped after a stop/restart instead of adopting the new run.
    /// Read on the source queue.
    var currentRunToken: UInt64 {
        deliveryGeneration ?? lifecycleLock.withLock { $0.generation }
    }

    /// Emit a frame produced by deferred async work, gated on the EXACT run token
    /// captured when that work was requested. Unlike `emit`, there is no fallback
    /// to the current generation: if the run has since advanced (stop → restart),
    /// the frame is dropped rather than surfaced in the new run. Call on the
    /// source queue.
    func emitDeferred(_ pixelBuffer: CVPixelBuffer, capturedToken: UInt64, pts: CMTime? = nil) {
        withDeliveryGeneration(capturedToken) { emit(pixelBuffer, pts: pts) }
    }

    private var isOnSourceQueue: Bool {
        DispatchQueue.getSpecific(key: queueKey) != nil
    }

    private func isRunning(_ generation: UInt64) -> Bool {
        lifecycleLock.withLock {
            $0.state == .running && $0.generation == generation
        }
    }

    private func onSourceQueue<T>(_ body: () throws -> T) rethrows -> T {
        if isOnSourceQueue { return try body() }
        return try queue.sync(execute: body)
    }

    private func withDeliveryGeneration<T>(_ generation: UInt64,
                                           _ body: () throws -> T) rethrows -> T {
        let previous = deliveryGeneration
        deliveryGeneration = generation
        defer { deliveryGeneration = previous }
        return try body()
    }

    private func runTick(generation: UInt64) {
        guard isRunning(generation) else { return }
        withDeliveryGeneration(generation) { tick() }
    }

    #if DEBUG
    /// Force lifecycle state for tests (does not touch the timer/resources).
    public func _test_forceState(_ newState: SourceState) {
        state = newState
    }
    #endif
}
