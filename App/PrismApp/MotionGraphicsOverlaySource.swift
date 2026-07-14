import CoreMedia
import CoreVideo
import Foundation
import PrismCompositor
import PrismCore
import os

// MARK: - Overlay kind + config

/// Which broadcast motion-graphic an overlay source renders. Each maps to a
/// `PrismCompositor.MotionGraphics` render call, driven every frame by a single
/// entrance `progress` (or, for the countdown, a live seconds/tick pair).
enum MGOverlayKind: String, CaseIterable, Identifiable, Sendable {
    case lowerThird, nameTag, countdown, subscribeBug
    var id: String { rawValue }
    var label: String {
        switch self {
        case .lowerThird:   return "Lower Third"
        case .nameTag:      return "Name Tag"
        case .countdown:    return "Countdown"
        case .subscribeBug: return "Subscribe Bug"
        }
    }
    var systemImage: String {
        switch self {
        case .lowerThird:   return "textformat.size.larger"
        case .nameTag:      return "person.text.rectangle"
        case .countdown:    return "timer"
        case .subscribeBug: return "bell.badge"
        }
    }
}

/// Live-editable config for a motion-graphics overlay. Value type so the app can
/// mirror it into `@State` and hand a snapshot to the render thread.
struct MGOverlayConfig: Sendable, Equatable {
    var kind: MGOverlayKind = .lowerThird
    var name: String = "Name"
    var subtitle: String = "Title"
    /// The CTA-bug label (e.g. "SUBSCRIBE").
    var ctaText: String = "SUBSCRIBE"
    var corner: MGCorner = .bottomLeft
    /// Accent color, sRGB 0…1.
    var accentR: Double = 0.15
    var accentG: Double = 0.55
    var accentB: Double = 0.95
    var inSec: Double = 0.5
    var holdSec: Double = 3.0
    var outSec: Double = 0.5
    /// Countdown start value (seconds).
    var countdownSeconds: Int = 10

    var accent: RGBA { RGBA(r: accentR, g: accentG, b: accentB, a: 1) }
    var timing: MGTiming { MGTiming(inSec: inSec, holdSec: holdSec, outSec: outSec) }
}

// MARK: - Overlay video source

/// A generated `VideoSource` that renders an animated broadcast overlay
/// (`MotionGraphics`) into a transparent, premultiplied-alpha BGRA frame every
/// tick. The entrance animation is driven live off the house clock: the elapsed
/// time since the overlay was cued feeds `MGTiming.entranceProgress(at:)`, so the
/// slide-in / hold / slide-out plays in real time. `recue()` restarts it.
///
/// The overlay is registered exactly like any other generated source
/// (`registerGenerated`), so its scene Layer is premultiplied-alpha and it drops
/// over the layers beneath without an opaque box (MotionGraphics leaves the
/// background fully transparent by construction).
///
/// Thread model: create / `start()` / `stop()` from one control thread; live
/// setters (`setConfig`, `recue`) are safe from any thread. `onFrame` fires on
/// the source's serial queue.
final class MotionGraphicsOverlaySource: VideoSource, @unchecked Sendable {
    let id: SourceID
    /// Set before `start()`. Called on the source's serial queue.
    var onFrame: ((VideoFrame) -> Void)?
    private(set) var state: SourceState = .idle

    private let log = EngineLog.logger("app.overlay")
    private let mg: MotionGraphics
    private let queue: DispatchQueue
    private let frameDuration: CMTime
    private let interval: DispatchTimeInterval
    private var timer: DispatchSourceTimer?

    private let lock = NSLock()
    private var config: MGOverlayConfig
    /// House-time seconds the entrance was last cued from.
    private var cuedAt: Double

    init(id: SourceID = SourceID("overlay.\(UUID().uuidString)"),
         width: Int, height: Int, config: MGOverlayConfig, fps: Double = 30) throws {
        self.id = id
        self.mg = try MotionGraphics(width: width, height: height)
        self.config = config
        self.queue = DispatchQueue(label: "studio.prism.source.overlay", qos: .userInitiated)
        let clamped = max(fps, 0.001)
        self.frameDuration = CMTime(seconds: 1.0 / clamped, preferredTimescale: 600)
        self.interval = .nanoseconds(Int(1_000_000_000.0 / clamped))
        self.cuedAt = HouseClock.nowSeconds()
    }

    // MARK: Live control

    func setConfig(_ new: MGOverlayConfig) {
        lock.lock(); config = new; lock.unlock()
    }
    func currentConfig() -> MGOverlayConfig {
        lock.lock(); defer { lock.unlock() }; return config
    }
    /// Restart the entrance animation from now (replay the slide-in / hold / out).
    func recue() {
        lock.lock(); cuedAt = HouseClock.nowSeconds(); lock.unlock()
    }

    // MARK: Lifecycle

    func start() throws {
        guard state == .idle || state == .failed else { return }
        state = .starting
        // Cue the entrance from start so the animation plays when the overlay lands.
        lock.lock(); cuedAt = HouseClock.nowSeconds(); lock.unlock()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        state = .running
        t.resume()
    }

    func stop() {
        guard state == .running || state == .starting || state == .failed else { return }
        state = .stopping
        timer?.cancel()
        timer = nil
        state = .idle
    }

    // MARK: Render

    private func tick() {
        lock.lock()
        let c = config
        let cued = cuedAt
        lock.unlock()
        let elapsed = HouseClock.nowSeconds() - cued
        do {
            let buffer: CVPixelBuffer
            switch c.kind {
            case .lowerThird:
                buffer = try mg.lowerThird(name: c.name, subtitle: c.subtitle,
                                           corner: c.corner, accent: c.accent,
                                           progress: c.timing.entranceProgress(at: elapsed))
            case .nameTag:
                buffer = try mg.nameTag(name: c.name, corner: c.corner, accent: c.accent,
                                        progress: c.timing.entranceProgress(at: elapsed))
            case .subscribeBug:
                buffer = try mg.ctaBug(text: c.ctaText, corner: c.corner, accent: c.accent,
                                       progress: c.timing.entranceProgress(at: elapsed))
            case .countdown:
                // Count down from the start value in real time: seconds remaining
                // ticks down each whole second; tickProgress runs 0→1 through the
                // current second (the number pops and the ring depletes).
                let remaining = Double(c.countdownSeconds) - elapsed
                let secs = max(0, Int(ceil(remaining)))
                let tick = min(max(elapsed - floor(elapsed), 0), 1)
                buffer = try mg.countdown(secondsRemaining: secs, tickProgress: tick,
                                          accent: c.accent)
            }
            onFrame?(VideoFrame(pixelBuffer: buffer, pts: HouseClock.now(),
                                duration: frameDuration, source: id))
        } catch {
            log.error("overlay render failed for \(self.id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
