import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import os
import PrismCore

/// A still-image source (DESIGN.md §2.1 — "Media sources: … images") for
/// BRB screens, bumpers, logos.
///
/// Loads a file via `CGImageSource`, draws it once into a canvas-sized,
/// IOSurface-backed BGRA buffer with the chosen content mode, and re-emits
/// that cached frame at a low fps (a still needs no 60 Hz). Load failures are
/// typed (`SourceError.imageLoadFailed` / `.imageDecodeFailed`).
///
/// Thread model: `start()` (which loads and throws on failure), `stop()` and
/// `setImage`/`setContentMode` from one control thread; `onFrame` fires on the
/// source's serial queue.
public final class ImageSource: TimedVideoSource {
    /// How the image is fitted into the canvas.
    public enum ContentMode: Sendable {
        /// Scale to fit entirely inside the canvas, letterboxed (aspect kept).
        case aspectFit
        /// Scale to fill the canvas, cropping overflow (aspect kept).
        case aspectFill
        /// Stretch to exactly the canvas (aspect broken).
        case stretch
    }

    private let log = EngineLog.logger("sources.image")
    private let canvas: SourceRenderCanvas
    private let background: RGBAColor

    private struct State {
        var url: URL
        var contentMode: ContentMode
        var cached: PixelBox?
        var dirty: Bool = true
        /// Bumped on every mutation (`setImage`/`setContentMode`). `tick()`
        /// captures it before rendering and only clears `dirty`/publishes its
        /// cache if it is unchanged, so a mutation landing *during* a render is
        /// not lost (F5 lost-update fix).
        var generation: UInt64 = 0
    }
    private let lock: OSAllocatedUnfairLock<State>

    /// - Parameters:
    ///   - fileURL: image file (PNG/JPEG/HEIC/GIF first frame/…).
    ///   - canvasSize: output dimensions.
    ///   - contentMode: fit/fill/stretch.
    ///   - background: fill behind a letterboxed image (default `.clear`).
    ///   - fps: emit rate for the still (default 2).
    public init(id: SourceID = SourceID("image.\(UUID().uuidString)"),
                fileURL: URL,
                canvasSize: CanvasSize = .hd,
                contentMode: ContentMode = .aspectFit,
                // Transparent by default so a logo/PNG keeps its transparency and
                // aspect-fit letterbox bars show the layers beneath (an image is
                // usually an OVERLAY). An opaque background can still be passed
                // explicitly for a full-frame backdrop.
                background: RGBAColor = .clear,
                fps: Double = 2) throws {
        self.canvas = try SourceRenderCanvas(size: canvasSize)
        self.background = background
        self.lock = OSAllocatedUnfairLock(initialState: State(url: fileURL, contentMode: contentMode))
        super.init(id: id, fps: fps, label: "studio.prism.source.image")
    }

    /// Convenience for a filesystem path.
    public convenience init(id: SourceID = SourceID("image.\(UUID().uuidString)"),
                            path: String,
                            canvasSize: CanvasSize = .hd,
                            contentMode: ContentMode = .aspectFit,
                            // F23: MATCH the `fileURL:` init default (`.clear`) so a
                            // transparent PNG stays an overlay whichever overload is
                            // chosen (was `.black` — a silent opaque black rectangle).
                            background: RGBAColor = .clear,
                            fps: Double = 2) throws {
        try self.init(id: id, fileURL: URL(fileURLWithPath: path),
                      canvasSize: canvasSize, contentMode: contentMode,
                      background: background, fps: fps)
    }

    /// Swap the image (re-rendered on the next tick). Throws if it can't load.
    public func setImage(fileURL: URL) throws {
        let buffer = try renderImage(url: fileURL, mode: lock.withLock { $0.contentMode })
        let box = PixelBox(buffer: buffer)
        // Bump generation so an in-flight tick render can't clobber this fresh
        // image with its stale (older-URL) result (F5).
        lock.withLock { $0.url = fileURL; $0.cached = box; $0.dirty = false; $0.generation &+= 1 }
    }

    public func setContentMode(_ mode: ContentMode) {
        lock.withLock { $0.contentMode = mode; $0.dirty = true; $0.generation &+= 1 }
    }

    override func willStart() throws {
        // Load eagerly so start() surfaces a bad path as a thrown error.
        let (url, mode) = lock.withLock { ($0.url, $0.contentMode) }
        let buffer = try renderImage(url: url, mode: mode)
        let box = PixelBox(buffer: buffer)
        lock.withLock { $0.cached = box; $0.dirty = false }
    }

    override func tick() {
        let (dirty, url, mode, cached, gen) = lock.withLock { ($0.dirty, $0.url, $0.contentMode, $0.cached, $0.generation) }
        if dirty || cached == nil {
            do {
                let buffer = try renderImage(url: url, mode: mode)
                let box = PixelBox(buffer: buffer)
                // Compare-and-clear: only publish this render + mark clean if no
                // mutation landed while rendering; otherwise leave `dirty` set so
                // the next tick re-renders the newer url/mode (F5 lost-update fix).
                lock.withLock {
                    if $0.generation == gen { $0.cached = box; $0.dirty = false }
                }
                emit(buffer)
            } catch {
                log.error("image re-render failed: \(String(describing: error), privacy: .public)")
                if let cached { emit(cached.buffer) }
            }
        } else if let cached {
            emit(cached.buffer)
        }
    }

    // MARK: - Load + draw

    private func loadCGImage(url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw SourceError.imageLoadFailed(path: url.path, underlying: nil)
        }
        guard CGImageSourceGetCount(src) > 0,
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw SourceError.imageDecodeFailed(path: url.path)
        }
        return image
    }

    private func renderImage(url: URL, mode: ContentMode) throws -> CVPixelBuffer {
        let image = try loadCGImage(url: url)
        let dest = Self.fittedRect(imageW: image.width, imageH: image.height,
                                   canvasW: canvas.width, canvasH: canvas.height, mode: mode)
        return try canvas.render { ctx in
            ctx.setFillColor(background.cgColor)
            ctx.fill(canvas.canvasRect)
            ctx.interpolationQuality = .high
            // Upright: CGImage row 0 (its top) → high y → memory row 0 (visual top).
            ctx.draw(image, in: dest)
        }
    }

    /// Destination rect (bottom-left origin, canvas pixels) for the content mode.
    static func fittedRect(imageW: Int, imageH: Int, canvasW: Int, canvasH: Int, mode: ContentMode) -> CGRect {
        let iw = CGFloat(imageW), ih = CGFloat(imageH)
        let cw = CGFloat(canvasW), ch = CGFloat(canvasH)
        guard iw > 0, ih > 0 else { return CGRect(x: 0, y: 0, width: cw, height: ch) }
        switch mode {
        case .stretch:
            return CGRect(x: 0, y: 0, width: cw, height: ch)
        case .aspectFit, .aspectFill:
            let scale = mode == .aspectFit ? min(cw / iw, ch / ih) : max(cw / iw, ch / ih)
            let dw = iw * scale, dh = ih * scale
            return CGRect(x: (cw - dw) / 2, y: (ch - dh) / 2, width: dw, height: dh)
        }
    }
}
