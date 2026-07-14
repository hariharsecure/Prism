import CoreMedia
import CoreVideo
import Foundation
import os
import PrismCore

/// Shared base for the animation-overlay `VideoSource`s (`AnimatedLogoSource`,
/// `TickerSource`, `CreditsSource`) that wrap the PrismCompositor VisualFX
/// renderers (`AnimatedLogo`, `Ticker`, `CreditsRoll`) as live, addable sources.
///
/// It builds on `TimedVideoSource` (serial-queue timer at a modest fps — overlays
/// don't need 60) and adds the two things every overlay needs:
///
///  - **House-clock drive.** `willStart()` records a house-time `epoch`; each
///    `tick()` computes `elapsed = HouseClock.now() − epoch` (seconds) and asks
///    the subclass to render the frame for that elapsed. Motion is therefore
///    real-time and pacing-independent (a dropped tick doesn't rewind the
///    animation), and every emitted frame is stamped in house time.
///  - **Terminal-state discipline (mirrors `MovieSource`/`AnimatedGIFSource`).**
///    `tick()` re-checks `state == .running` both before rendering and again
///    immediately before `emit`, and `willStop()` drains any in-flight tick
///    (`queue.sync {}`) so **no `onFrame` callback fires after `stop()` returns**.
///    The drain is skipped when `stop()` is called from inside `onFrame` (i.e.
///    already on the source queue), detected via a queue-specific key, so a
///    consumer stopping the source from its frame callback can't deadlock.
///
/// Subclasses override `prepare()` (validate/load resources — may throw to fail
/// the source) and `renderFrame(elapsed:)` (produce one IOSurface-backed BGRA
/// frame, or `nil` to skip this tick).
public class AnimationSource: TimedVideoSource, @unchecked Sendable {
    private let epochLock = OSAllocatedUnfairLock<CMTime>(initialState: .invalid)
    private let queueKey = DispatchSpecificKey<UInt8>()
    let animLog: Logger

    override init(id: SourceID, fps: Double, label: String) {
        self.animLog = EngineLog.logger("sources.anim")
        super.init(id: id, fps: fps, label: label)
        // Tag the source queue so a `stop()` arriving from inside `onFrame`
        // (executing on this queue) skips the drain and can't deadlock.
        queue.setSpecific(key: queueKey, value: 1)
    }

    /// House time recorded at `start()`; `.invalid` before the source runs.
    final var epoch: CMTime { epochLock.withLock { $0 } }

    /// Seconds since `start()` on the house clock (never negative / non-finite).
    final func elapsedNow() -> Double {
        let base = epochLock.withLock { $0 }
        guard base != .invalid else { return 0 }
        let d = CMTimeSubtract(HouseClock.now(), base).seconds
        return d.isFinite ? max(0, d) : 0
    }

    // MARK: Subclass hooks

    /// Validate configuration / load resources before the timer starts. Throwing
    /// marks the source `.failed` (surfaced from `start()`).
    func prepare() throws {}

    /// Render one frame for the given house-clock `elapsed` (seconds since start).
    /// Return `nil` to skip emitting this tick. Runs on the source queue.
    func renderFrame(elapsed: Double) throws -> CVPixelBuffer? { nil }

    // MARK: TimedVideoSource overrides

    final override func willStart() throws {
        try prepare()
        epochLock.withLock { $0 = HouseClock.now() }
    }

    final override func tick() {
        guard state == .running else { return }
        let e = elapsedNow()
        do {
            guard let buffer = try renderFrame(elapsed: e) else { return }
            // Re-check after the (millisecond-scale) render so a stop() that
            // landed mid-render suppresses this frame.
            guard state == .running else { return }
            emit(buffer)
        } catch {
            animLog.error("\(self.id) render failed: \(String(describing: error), privacy: .public)")
        }
    }

    final override func willStop() {
        // Drain any in-flight tick so no callback fires after stop() returns —
        // unless we're already on the source queue (stop() from within onFrame),
        // in which case there is no in-flight tick to wait on and sync would
        // deadlock.
        if DispatchQueue.getSpecific(key: queueKey) == nil {
            queue.sync {}
        }
    }
}
