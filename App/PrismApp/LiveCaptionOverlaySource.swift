import CoreMedia
import CoreVideo
import Foundation
import PrismAudio
import PrismCompositor
import PrismCore
import os

// MARK: - Live-caption overlay source (feature 1)

/// A generated `VideoSource` that renders the rolling live-caption overlay
/// (`PrismCompositor.CaptionRenderer` — a transparent, premultiplied-alpha
/// bottom-third subtitle bar) into a BGRA frame every tick. The caption text is
/// pushed in live from a `LiveCaptioner` via `apply(_:)`; the render thread only
/// reads the latest wrapped lines, so the recognizer's callback never blocks the
/// tick.
///
/// Registered exactly like any other generated source (`registerGenerated`), so
/// its scene Layer is premultiplied-alpha and the subtitle bar drops over the
/// program without an opaque box (the renderer leaves everything above the bar
/// fully transparent, and an empty transcript yields a fully transparent frame —
/// nothing shows until there is text).
///
/// Thread model: create / `start()` / `stop()` from one control thread;
/// `apply(_:)` is safe from any thread (it's the recognizer callback). `onFrame`
/// fires on the source's serial queue.
final class LiveCaptionOverlaySource: VideoSource, @unchecked Sendable {
    let id: SourceID
    /// Set before `start()`. Called on the source's serial queue.
    var onFrame: ((VideoFrame) -> Void)?
    private(set) var state: SourceState = .idle

    private let log = EngineLog.logger("app.captions")
    private let renderer: CaptionRenderer
    private let style: CaptionRenderer.Style
    private let queue: DispatchQueue
    private let frameDuration: CMTime
    private let interval: DispatchTimeInterval
    private var timer: DispatchSourceTimer?

    private let lock = NSLock()
    /// Committed (final) caption lines, newest last — kept short so the bar stays
    /// a rolling two/three-line window.
    private var committed: [String] = []
    /// The live (not-yet-final) partial line.
    private var partial: String = ""

    init(id: SourceID = SourceID("captions.\(UUID().uuidString)"),
         width: Int, height: Int,
         style: CaptionRenderer.Style = CaptionRenderer.Style(),
         fps: Double = 30) throws {
        self.id = id
        self.renderer = try CaptionRenderer(width: width, height: height)
        self.style = style
        self.queue = DispatchQueue(label: "studio.prism.source.captions", qos: .userInitiated)
        let clamped = max(fps, 0.001)
        self.frameDuration = CMTime(seconds: 1.0 / clamped, preferredTimescale: 600)
        self.interval = .nanoseconds(Int(1_000_000_000.0 / clamped))
    }

    // MARK: Live control

    /// Feed one caption update from the `LiveCaptioner`. A final result commits
    /// the line (and clears the partial); a partial replaces the live line. Safe
    /// from the recognizer's callback thread.
    func apply(_ update: CaptionUpdate) {
        lock.lock()
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if update.isFinal {
            if !text.isEmpty { committed.append(text) }
            // Keep only the last two committed lines; the renderer's own maxLines
            // further trims the wrapped display, but bounding history keeps memory
            // and wrap work tiny.
            if committed.count > 2 { committed.removeFirst(committed.count - 2) }
            partial = ""
        } else {
            partial = text
        }
        lock.unlock()
    }

    /// Clear all caption text (fully transparent overlay).
    func clear() {
        lock.lock(); committed.removeAll(); partial = ""; lock.unlock()
    }

    // MARK: Lifecycle

    func start() throws {
        guard state == .idle || state == .failed else { return }
        state = .starting
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
        var lines = committed
        if !partial.isEmpty { lines.append(partial) }
        lock.unlock()
        do {
            let buffer = try renderer.render(lines: lines, style: style)
            onFrame?(VideoFrame(pixelBuffer: buffer, pts: HouseClock.now(),
                                duration: frameDuration, source: id))
        } catch {
            log.error("caption render failed for \(self.id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
