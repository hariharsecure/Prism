import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import PrismCore
import UniformTypeIdentifiers

/// Errors from the visual-FX CoreGraphics raster path.
public enum VisualFXError: Error, CustomStringConvertible {
    case canvasCreationFailed(String)
    case contextCreationFailed
    case imageCreationFailed
    case pngWriteFailed(String)
    case invalidConfiguration(String)

    public var description: String {
        switch self {
        case .canvasCreationFailed(let s): return "FX canvas creation failed: \(s)"
        case .contextCreationFailed: return "FX draw context creation failed"
        case .imageCreationFailed: return "FX CGImage creation failed"
        case .pngWriteFailed(let s): return "FX PNG write failed: \(s)"
        case .invalidConfiguration(let s): return "FX invalid configuration: \(s)"
        }
    }
}

/// A CoreGraphics → IOSurface BGRA drawing surface for the visual-FX engine —
/// the CPU raster backend that computes transition / animation / meme frames
/// exactly (the ground truth used for headless verification and PNG dumps).
///
/// Mirrors `PrismSources.SourceRenderCanvas`'s contract (bottom-left-origin
/// context over an IOSurface-backed pooled buffer, memory row 0 = visual top)
/// so frames it produces enter the zero-copy compositor identically. It lives
/// in PrismCompositor because the transition/meme model lives here and this
/// module may not import PrismSources.
///
/// Not for the 60 Hz hot path per se: transitions are brief, and the GPU-native
/// kinds (`TransitionSpec.isCompositorNative`) run through `MetalCompositor`
/// instead. This canvas renders the pixel-effect kinds, previews, and all
/// verification frames.
public final class FXCanvas {
    public let width: Int
    public let height: Int
    private let pool: PixelBufferPool
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    // BGRA in memory == premultiplied-first + little-endian 32-bit (same as
    // SourceRenderCanvas / the compositor's BGRA path).
    private let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue

    public init(width: Int, height: Int, minimumBufferCount: Int = 4) throws {
        guard width > 0, height > 0 else {
            throw VisualFXError.invalidConfiguration("canvas \(width)x\(height)")
        }
        self.width = width
        self.height = height
        do {
            self.pool = try PixelBufferPool(width: width, height: height,
                                            pixelFormat: kCVPixelFormatType_32BGRA,
                                            minimumBufferCount: minimumBufferCount)
        } catch {
            throw VisualFXError.canvasCreationFailed("\(error)")
        }
    }

    public var rect: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    /// Draw into a fresh IOSurface-backed BGRA buffer (bottom-left origin).
    public func render(_ draw: (CGContext) throws -> Void) throws -> CVPixelBuffer {
        let buffer: CVPixelBuffer
        do { buffer = try pool.makeBuffer() }
        catch { throw VisualFXError.canvasCreationFailed("\(error)") }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw VisualFXError.contextCreationFailed
        }
        guard let ctx = CGContext(data: base, width: width, height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: colorSpace, bitmapInfo: bitmapInfo) else {
            throw VisualFXError.contextCreationFailed
        }
        ctx.clear(rect)
        try draw(ctx)
        ctx.flush()
        // Phase 2e: this canvas draws sRGB content (`colorSpace` above) — the shared
        // ground-truth surface for every FXCanvas-backed GENERATED overlay
        // (MotionGraphics / Caption / Ticker / AnimatedLogo / CreditsRoll). It must
        // carry its OWN colorimetry, not reach the HDR compositor UNTAGGED: an untagged
        // buffer is decoded with the Rec.709 EOTF instead of the sRGB EOTF (correct
        // primaries, wrong transfer → ~3.8% mid-tone error, a generated gray 128 → ≈765
        // instead of ≈726). Stamp sRGB/709 exactly as `SourceRenderCanvas` and
        // `BackgroundEffect.replace` already do. The SDR compositor ignores the tags.
        YCbCrTags.stampSRGB(buffer)
        return buffer
    }

    /// Mint a fresh IOSurface-backed BGRA buffer and hand its locked base
    /// address to `fill` for direct per-pixel writes (used by the glitch /
    /// RGB-split effect, which is a genuine per-pixel operation). Effect path
    /// only — the GPU hot path never locks a base address.
    public func renderRaw(_ fill: (_ base: UnsafeMutablePointer<UInt8>, _ bytesPerRow: Int) -> Void) throws -> CVPixelBuffer {
        let buffer: CVPixelBuffer
        do { buffer = try pool.makeBuffer() }
        catch { throw VisualFXError.canvasCreationFailed("\(error)") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw VisualFXError.contextCreationFailed
        }
        fill(base.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRow(buffer))
        // Phase 2e: same sRGB content as `render` (the glitch / RGB-split effect writes
        // sRGB bytes directly) — tag it sRGB/709 so it is not decoded as Rec.709 EOTF in
        // the HDR compositor (see `render`).
        YCbCrTags.stampSRGB(buffer)
        return buffer
    }

    // MARK: - Test-image factories (the A/B "image sources")

    /// A solid opaque color fill.
    public func solid(_ c: RGBA) throws -> CVPixelBuffer {
        try render { ctx in
            ctx.setFillColor(c.cg)
            ctx.fill(rect)
        }
    }

    /// A vertical gradient (top → bottom), opaque. Distinct, eyeball-able.
    public func verticalGradient(top: RGBA, bottom: RGBA) throws -> CVPixelBuffer {
        try render { ctx in
            let cs = colorSpace
            let stops: [CGFloat] = [0, 1]
            // CG gradient in a bottom-left context: location 0 = bottom.
            guard let grad = CGGradient(colorsSpace: cs,
                                        colors: [bottom.cg, top.cg] as CFArray,
                                        locations: stops) else {
                ctx.setFillColor(top.cg); ctx.fill(rect); return
            }
            ctx.drawLinearGradient(grad,
                                   start: CGPoint(x: 0, y: 0),
                                   end: CGPoint(x: 0, y: height),
                                   options: [])
        }
    }

    /// A CPU reference rasterization of a `Scene`: layers drawn back-to-front
    /// (z-sorted) into their normalized `frame` rects with opacity. Used to
    /// eyeball MemeBoard cut/insert results headlessly; the live program renders
    /// the same scene through `MetalCompositor`. `crop` is ignored (frame-only).
    public func renderScene(_ scene: Scene, frames: [SourceID: CVPixelBuffer], background: RGBA = .black) throws -> CVPixelBuffer {
        let w = CGFloat(width), h = CGFloat(height)
        let ordered = scene.layers.enumerated()
            .sorted { ($0.element.zIndex, $0.offset) < ($1.element.zIndex, $1.offset) }
            .map(\.element)
        // Snapshot layer images outside the draw closure.
        let drawn: [(CGImage, CGRect, Float)] = try ordered.compactMap { layer in
            guard !layer.isHidden, layer.opacity > 0, let buf = frames[layer.sourceID] else { return nil }
            let img = try FXCanvas.cgImage(from: buf)
            // Normalized top-left-origin frame → bottom-left CG rect.
            let r = CGRect(x: layer.frame.minX * w,
                           y: (1 - layer.frame.minY - layer.frame.height) * h,
                           width: layer.frame.width * w, height: layer.frame.height * h)
            return (img, r, layer.opacity)
        }
        return try render { ctx in
            ctx.setFillColor(background.cg)
            ctx.fill(rect)
            for (img, r, op) in drawn {
                ctx.setAlpha(CGFloat(op))
                ctx.draw(img, in: r)
            }
            ctx.setAlpha(1)
        }
    }

    // MARK: - CGImage bridge

    /// Snapshot a BGRA IOSurface buffer as an upright `CGImage` (copies pixels;
    /// verification/effect path only). Drawing the result with `ctx.draw(_,in:)`
    /// into another bottom-left-origin FX context reproduces it upright.
    public static func cgImage(from buffer: CVPixelBuffer) throws -> CGImage {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw VisualFXError.imageCreationFailed
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bpr, space: cs, bitmapInfo: info),
              let image = ctx.makeImage() else {
            throw VisualFXError.imageCreationFailed
        }
        return image
    }

    // MARK: - Readback (verification helpers)

    /// Read one BGRA pixel (test/verification only — locks the base address).
    public static func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> RGBA {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let p = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self) + y * bpr + x * 4
        // Memory order BGRA (premultiplied-first little-endian).
        let a = Double(p[3]) / 255
        // Un-premultiply for a stable comparison against source colors.
        let inv = a > 0 ? 1 / a : 0
        return RGBA(r: min(Double(p[2]) / 255 * inv, 1),
                    g: min(Double(p[1]) / 255 * inv, 1),
                    b: min(Double(p[0]) / 255 * inv, 1),
                    a: a)
    }

    /// Mean absolute per-channel difference (0…1) between two same-size buffers,
    /// grid-sampled. 0 == pixel-identical; used to prove "genuine blend".
    public static func meanDiff(_ a: CVPixelBuffer, _ b: CVPixelBuffer, step: Int = 16) -> Double {
        meanDiff(a, b, step: step, includeAlpha: false)
    }

    /// Alpha-aware sibling of `meanDiff` — averages all FOUR premultiplied BGRA
    /// channels (0..<4). The BGR-only `meanDiff` is BLIND to an alpha regression
    /// (e.g. a tile hole clobbered from true alpha-0 to opaque black keeps the
    /// same near-black BGR), so any test guarding the premultiplied transparent-
    /// hole invariant must compare with alpha included.
    public static func meanDiffWithAlpha(_ a: CVPixelBuffer, _ b: CVPixelBuffer, step: Int = 16) -> Double {
        meanDiff(a, b, step: step, includeAlpha: true)
    }

    private static func meanDiff(_ a: CVPixelBuffer, _ b: CVPixelBuffer, step: Int, includeAlpha: Bool) -> Double {
        let w = min(CVPixelBufferGetWidth(a), CVPixelBufferGetWidth(b))
        let h = min(CVPixelBufferGetHeight(a), CVPixelBufferGetHeight(b))
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let ba = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
        let bb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        let bpa = CVPixelBufferGetBytesPerRow(a), bpb = CVPixelBufferGetBytesPerRow(b)
        let channels = includeAlpha ? 4 : 3
        var sum = 0.0, n = 0
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let pa = ba + y * bpa + x * 4, pb = bb + y * bpb + x * 4
                for c in 0..<channels { sum += abs(Double(pa[c]) - Double(pb[c])) / 255 }
                n += channels
                x += step
            }
            y += step
        }
        return n > 0 ? sum / Double(n) : 0
    }

    /// Mean luminance (0…1), grid-sampled — used to detect a white flash frame.
    public static func meanLuma(_ buffer: CVPixelBuffer, step: Int = 16) -> Double {
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        var sum = 0.0, n = 0
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let p = base + y * bpr + x * 4
                sum += (Double(p[2]) * 0.30 + Double(p[1]) * 0.59 + Double(p[0]) * 0.11) / 255
                n += 1
                x += step
            }
            y += step
        }
        return n > 0 ? sum / Double(n) : 0
    }

    // MARK: - PNG dump (eyeball-able output)

    /// Write a BGRA buffer to a PNG on disk (for the lead to eyeball).
    @discardableResult
    public static func writePNG(_ buffer: CVPixelBuffer, to url: URL) throws -> URL {
        let image = try cgImage(from: buffer)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw VisualFXError.pngWriteFailed(url.path)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw VisualFXError.pngWriteFailed(url.path) }
        return url
    }
}

/// A plain sRGB color for the FX raster path (independent of AppKit and of
/// `PrismSources.RGBAColor`, which this module can't import).
public struct RGBA: Sendable, Equatable {
    public var r, g, b, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    public static let white = RGBA(r: 1, g: 1, b: 1)
    public static let black = RGBA(r: 0, g: 0, b: 0)
    public static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
}
