import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import PrismCore

/// Pixel dimensions of a generated source's canvas.
public struct CanvasSize: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
    /// 1080p default.
    public static let hd = CanvasSize(width: 1920, height: 1080)
}

/// An RGBA color in the sRGB space (0…1 components), independent of AppKit.
public struct RGBAColor: Sendable, Equatable {
    public var r, g, b, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    public static let white = RGBAColor(r: 1, g: 1, b: 1)
    public static let black = RGBAColor(r: 0, g: 0, b: 0)
    public static let clear = RGBAColor(r: 0, g: 0, b: 0, a: 0)

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

/// A `Sendable` wrapper around a cached `CVPixelBuffer` reference.
///
/// `CVPixelBuffer` (aka `CVBuffer`) is not `Sendable`, so caching it inside an
/// `OSAllocatedUnfairLock`'s protected state — and mutating that state from the
/// lock's `@Sendable` `withLock` closure — trips the concurrency checker. The
/// buffers we cache are IOSurface-backed and treated as immutable once emitted
/// (a `render` never hands back an already-emitted buffer), so passing the bare
/// reference across the isolation boundary is safe; `@unchecked Sendable`
/// asserts exactly that. This wraps only the reference — no pixels are copied,
/// so the zero-copy/IOSurface invariant is unchanged.
struct PixelBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

/// Shared CoreGraphics → IOSurface drawing surface for generated sources
/// (text, image, browser). Owns a `PixelBufferPool` of BGRA8, IOSurface-backed
/// buffers and hands each `render` a bottom-left-origin `CGContext` over a
/// *fresh* buffer.
///
/// Zero-copy note (DESIGN.md §3.5): generated content is inherently CPU-drawn,
/// so we lock the buffer to draw into it — but the buffer itself is always
/// IOSurface-backed, so it enters the compositor zero-copy (wrapped by
/// `CVMetalTextureCache` as a Metal texture). We never hand out a buffer that
/// has already been emitted, so an emitted still is never mutated underfoot.
final class SourceRenderCanvas {
    let width: Int
    let height: Int
    private let pool: PixelBufferPool
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    // BGRA in memory == premultiplied-first + little-endian 32-bit.
    private let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue

    init(size: CanvasSize, minimumBufferCount: Int = 4) throws {
        guard size.width > 0, size.height > 0 else {
            throw SourceError.invalidConfiguration(reason: "canvas \(size.width)x\(size.height)")
        }
        self.width = size.width
        self.height = size.height
        do {
            self.pool = try PixelBufferPool(width: size.width, height: size.height,
                                            pixelFormat: kCVPixelFormatType_32BGRA,
                                            minimumBufferCount: minimumBufferCount)
        } catch {
            throw SourceError.canvasCreationFailed(reason: "\(error)")
        }
    }

    var canvasRect: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    /// Draw into a fresh IOSurface-backed buffer and return it. The context is
    /// bottom-left origin (native CoreGraphics); memory row 0 is the visual top,
    /// so CoreText baselines near the top of the rect and upright `CGImage`
    /// draws both land right-side-up for a top-row-first consumer.
    func render(_ draw: (CGContext) throws -> Void) throws -> CVPixelBuffer {
        let buffer: CVPixelBuffer
        do { buffer = try pool.makeBuffer() }
        catch { throw SourceError.canvasCreationFailed(reason: "\(error)") }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw SourceError.contextCreationFailed
        }
        guard let ctx = CGContext(
            data: base,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw SourceError.contextCreationFailed
        }
        // Pool buffers are recycled; start from a known transparent state.
        ctx.clear(canvasRect)
        try draw(ctx)
        ctx.flush()
        // sol #4 finding 3: generated content is drawn in the sRGB colorspace
        // (`colorSpace` above), so tag the buffer sRGB / Rec.709 — it must carry its
        // OWN colorspace, not reach the HDR compositor untagged (which would decode
        // it with the Rec.709 EOTF instead of the sRGB EOTF: a generated gray 128 →
        // ≈765 instead of ≈726). The SDR compositor ignores the tags (no regression).
        YCbCrTags.stampSRGB(buffer)
        return buffer
    }
}
