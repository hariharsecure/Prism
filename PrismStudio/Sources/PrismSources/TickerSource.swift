import CoreMedia
import CoreVideo
import Foundation
import os
import PrismCompositor
import PrismCore

/// A **news-crawl ticker** overlay source (DESIGN.md §2). Wraps the VisualFX
/// `Ticker` renderer as a live, addable `VideoSource`: a bar carrying text that
/// scrolls right→left. The scroll `offset` is advanced by `speed·dt` off the
/// house clock (`offset = speed · elapsed`), and the renderer wraps it modulo the
/// loop length, so the crawl is **seamless** — the frame at `offset` and at
/// `offset + loopLength` are pixel-identical (no gap or jump at the wrap).
///
/// Only the bar + text carry pixels; everything outside the bar is left
/// transparent (premultiplied BGRA), so the crawl composits over program.
///
/// Thread model: create / `start()` / `stop()` / `setText()` from any thread
/// (text is lock-guarded); `onFrame` fires on the source queue. No callback
/// after `stop()` returns (see `AnimationSource`).
public final class TickerSource: AnimationSource, @unchecked Sendable {

    private let renderer: Ticker
    private let style: TickerStyle
    /// Scroll speed in pixels per second.
    public let speed: Double
    private let text: OSAllocatedUnfairLock<String>

    /// - Parameters:
    ///   - text: the crawl string (non-empty).
    ///   - canvasSize: overlay output dimensions.
    ///   - style: bar / accent / font styling (see `TickerStyle`).
    ///   - speed: scroll speed, pixels/second (default 160).
    ///   - fps: emit rate (default 30 — overlays don't need 60).
    /// - Throws: `SourceError.invalidConfiguration` (empty text),
    ///   `.canvasCreationFailed`.
    public init(id: SourceID = SourceID("ticker.\(UUID().uuidString)"),
                text: String,
                canvasSize: CanvasSize = .hd,
                style: TickerStyle = TickerStyle(),
                speed: Double = 160,
                fps: Double = 30) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceError.invalidConfiguration(reason: "ticker text is empty")
        }
        do {
            self.renderer = try Ticker(width: canvasSize.width, height: canvasSize.height)
        } catch {
            throw SourceError.canvasCreationFailed(reason: "\(error)")
        }
        self.style = style
        self.speed = max(0, speed)
        self.text = OSAllocatedUnfairLock(initialState: text)
        super.init(id: id, fps: fps, label: "studio.prism.source.ticker")
    }

    /// The current crawl string.
    public var currentText: String { text.withLock { $0 } }

    /// Swap the crawl string (takes effect on the next tick). Ignored if empty.
    public func setText(_ newText: String) {
        guard !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        text.withLock { $0 = newText }
    }

    /// One loop length (pixels) for the current text — advancing `offset` by
    /// exactly this returns to an identical frame.
    public var loopLength: Double { renderer.loopLength(text: currentText, style: style) }

    // MARK: AnimationSource

    override func renderFrame(elapsed: Double) throws -> CVPixelBuffer? {
        try render(offset: speed * elapsed)
    }

    /// Render one frame at an explicit scroll `offset` (shared by `tick` and the
    /// self-test's deterministic renders). The renderer wraps `offset` modulo the
    /// loop length internally, so any offset is valid.
    func render(offset: Double) throws -> CVPixelBuffer {
        do {
            return try renderer.render(text: currentText, offset: offset, style: style)
        } catch {
            throw SourceError.canvasCreationFailed(reason: "\(error)")
        }
    }
}
