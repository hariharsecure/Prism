import CoreMedia
import CoreVideo
import Foundation
import PrismCompositor
import PrismCore

/// A **credits-roll** overlay source (DESIGN.md §2). Wraps the VisualFX
/// `CreditsRoll` renderer as a live, addable `VideoSource`: multi-line text
/// scrolling bottom→top, with both edges fading so lines dissolve in/out. The
/// vertical `offset` is advanced by `speed·dt` off the house clock
/// (`offset = speed · elapsed`).
///
/// Two modes:
///  - **one-shot** (default): the roll plays once; after all lines have scrolled
///    past the top (`offset ≥ rollLength`) the source rests on transparent frames
///    (a live overlay stays alive) until `stop()`. `isFinished` reports this.
///  - **loop**: `offset` wraps modulo `rollLength`, so the roll repeats seamlessly.
///
/// Only the text carries pixels; the background is left transparent
/// (premultiplied BGRA) so the roll composits over program.
///
/// Thread model: create / `start()` / `stop()` from any thread; `onFrame` fires
/// on the source queue. No callback after `stop()` returns (see `AnimationSource`).
public final class CreditsSource: AnimationSource, @unchecked Sendable {

    private let renderer: CreditsRoll
    private let style: CreditsStyle
    private let lines: [String]
    /// Scroll speed in pixels per second.
    public let speed: Double
    /// Whether the roll repeats (`true`) or plays once (`false`).
    public let loops: Bool

    /// - Parameters:
    ///   - lines: the credit lines (at least one non-empty line required).
    ///   - canvasSize: overlay output dimensions.
    ///   - style: line-height / font / edge-fade styling (see `CreditsStyle`).
    ///   - speed: scroll speed, pixels/second (default 90).
    ///   - loop: repeat the roll seamlessly (default false = one-shot).
    ///   - fps: emit rate (default 30 — overlays don't need 60).
    /// - Throws: `SourceError.invalidConfiguration` (no non-empty lines),
    ///   `.canvasCreationFailed`.
    public init(id: SourceID = SourceID("credits.\(UUID().uuidString)"),
                lines: [String],
                canvasSize: CanvasSize = .hd,
                style: CreditsStyle = CreditsStyle(),
                speed: Double = 90,
                loop: Bool = false,
                fps: Double = 30) throws {
        guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw SourceError.invalidConfiguration(reason: "credits has no non-empty lines")
        }
        do {
            self.renderer = try CreditsRoll(width: canvasSize.width, height: canvasSize.height)
        } catch {
            throw SourceError.canvasCreationFailed(reason: "\(error)")
        }
        self.style = style
        self.lines = lines
        self.speed = max(0, speed)
        self.loops = loop
        super.init(id: id, fps: fps, label: "studio.prism.source.credits")
    }

    /// Total scroll distance (pixels) for the whole block to travel from
    /// fully-below to fully-above the canvas — the natural end of a one-shot roll.
    public var rollLength: Double { renderer.rollLength(lineCount: lines.count, style: style) }

    /// True once a one-shot roll has fully scrolled past the top (transparent
    /// from here on). Always false while looping.
    public var isFinished: Bool {
        guard !loops else { return false }
        return speed * elapsedNow() >= rollLength
    }

    // MARK: AnimationSource

    override func renderFrame(elapsed: Double) throws -> CVPixelBuffer? {
        try render(offset: scrollOffset(for: speed * elapsed))
    }

    /// Map a raw travelled distance to the offset fed to the renderer: wrapped
    /// modulo `rollLength` when looping, otherwise passed straight through.
    func scrollOffset(for raw: Double) -> Double {
        guard loops else { return raw }
        let len = rollLength
        guard len > 0 else { return raw }
        let m = raw.truncatingRemainder(dividingBy: len)
        return m < 0 ? m + len : m
    }

    /// Render one frame at an explicit vertical `offset` (shared by `tick` and
    /// the self-test's deterministic renders).
    func render(offset: Double) throws -> CVPixelBuffer {
        do {
            return try renderer.render(lines: lines, offset: offset, style: style)
        } catch {
            throw SourceError.canvasCreationFailed(reason: "\(error)")
        }
    }
}
