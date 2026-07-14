import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import PrismCore

/// Renders the "app not running" placeholder card the extension serves when
/// no sink client is feeding program frames (DESIGN.md §3.6).
///
/// COLD PATH ONLY: each variant is rendered exactly once and cached by the
/// device source; the 30 fps placeholder timer re-sends the same pixel buffer
/// with fresh timestamps. That is why locking the buffer's base address here
/// does not violate the zero-copy rule (AGENTS.md §6 — no locks on the *hot*
/// path); buffers still come from `PixelBufferPool`, so they stay
/// IOSurface-backed.
enum PlaceholderRenderer {

    enum RenderError: Error {
        case contextCreationFailed
        case lockFailed(CVReturn)
    }

    /// Branded SMPTE-ish card: 75%-amplitude color bars over a gradient strip
    /// and a caption band. BGRA output.
    static func renderBGRA(width: Int, height: Int, pool: PixelBufferPool) throws -> CVPixelBuffer {
        let buffer = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw RenderError.contextCreationFailed
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        // BGRA little-endian == 32-bit little-endian ARGB in CG terms.
        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw RenderError.contextCreationFailed
        }

        let w = CGFloat(width)
        let h = CGFloat(height)

        // Background.
        ctx.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // 7 SMPTE bars (75% amplitude), top ~58% of the frame.
        let bars: [(CGFloat, CGFloat, CGFloat)] = [
            (0.75, 0.75, 0.75), // gray
            (0.75, 0.75, 0.00), // yellow
            (0.00, 0.75, 0.75), // cyan
            (0.00, 0.75, 0.00), // green
            (0.75, 0.00, 0.75), // magenta
            (0.75, 0.00, 0.00), // red
            (0.00, 0.00, 0.75), // blue
        ]
        let barsTop = h * 0.42 // CG origin is bottom-left; bars occupy the top.
        let barWidth = w / CGFloat(bars.count)
        for (i, c) in bars.enumerated() {
            ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: CGFloat(i) * barWidth, y: barsTop, width: barWidth.rounded(.up), height: h - barsTop))
        }

        // Thin luminance ramp under the bars (SMPTE-ish PLUGE stand-in).
        let rampRect = CGRect(x: 0, y: h * 0.34, width: w, height: h * 0.08)
        if let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 1, alpha: 1)] as CFArray,
            locations: [0, 1]
        ) {
            ctx.saveGState()
            ctx.clip(to: rampRect)
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: rampRect.midY),
                end: CGPoint(x: w, y: rampRect.midY),
                options: []
            )
            ctx.restoreGState()
        }

        // Caption band.
        drawCenteredText("Prism", size: h * 0.085, weightBold: true,
                         color: CGColor(gray: 0.96, alpha: 1),
                         atY: h * 0.20, width: w, in: ctx)
        drawCenteredText("app not running", size: h * 0.042, weightBold: false,
                         color: CGColor(gray: 0.62, alpha: 1),
                         atY: h * 0.12, width: w, in: ctx)
        return buffer
    }

    /// One-time BGRA → 420v (video-range BT.709, 2×2 chroma subsampling)
    /// conversion so a client that negotiated the 420v format still gets a
    /// correct placeholder. CPU per-pixel loop is acceptable: it runs once.
    static func convert420v(from bgra: CVPixelBuffer, pool: PixelBufferPool) throws -> CVPixelBuffer {
        let dst = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(bgra, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(bgra, .readOnly)
        }
        guard
            let srcBase = CVPixelBufferGetBaseAddress(bgra),
            let yBase = CVPixelBufferGetBaseAddressOfPlane(dst, 0),
            let cBase = CVPixelBufferGetBaseAddressOfPlane(dst, 1)
        else { throw RenderError.contextCreationFailed }

        let width = CVPixelBufferGetWidth(bgra)
        let height = CVPixelBufferGetHeight(bgra)
        let srcStride = CVPixelBufferGetBytesPerRow(bgra)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(dst, 0)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(dst, 1)
        let src = srcBase.assumingMemoryBound(to: UInt8.self)
        let yPlane = yBase.assumingMemoryBound(to: UInt8.self)
        let cPlane = cBase.assumingMemoryBound(to: UInt8.self)

        @inline(__always) func clamp8(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }

        for row in 0..<height {
            for col in 0..<width {
                let p = row * srcStride + col * 4 // B G R A
                let b = Double(src[p]) / 255.0
                let g = Double(src[p + 1]) / 255.0
                let r = Double(src[p + 2]) / 255.0
                // BT.709 luma, scaled to video range [16, 235].
                let yLin = 0.2126 * r + 0.7152 * g + 0.0722 * b
                yPlane[row * yStride + col] = clamp8(16.0 + 219.0 * yLin)
                // Chroma from the top-left pixel of each 2×2 block (adequate
                // for a static card; not a general-purpose converter).
                if row % 2 == 0 && col % 2 == 0 {
                    let cb = 128.0 + 224.0 * (b - yLin) / 1.8556
                    let cr = 128.0 + 224.0 * (r - yLin) / 1.5748
                    let cp = (row / 2) * cStride + (col / 2) * 2
                    cPlane[cp] = clamp8(cb)
                    cPlane[cp + 1] = clamp8(cr)
                }
            }
        }
        return dst
    }

    /// One-time BGRA8 (sRGB) → `ARGB2101010LEPacked` (10-bit Rec.2020/HLG)
    /// conversion so a client that negotiated the HDR 10-bit format still gets a
    /// placeholder card whose pixel buffer MATCHES the advertised format (an
    /// 8-bit card under a 10-bit format description would be a format mismatch)
    /// AND whose codes are TRUTHFUL for the Rec.2020/BT.2100-HLG tags it carries.
    ///
    /// sol #5 #11: the old path just left-shifted the sRGB code (`code << 2`),
    /// so neutral sRGB 128 landed on HLG code 512 while stamped HLG — a lie (the
    /// correct HLG code for that luminance is ≈726). The card is now colour-
    /// converted per channel: sRGB EOTF → display-linear → 709/sRGB→2020 primary
    /// matrix → HLG OETF → 10-bit full-range code, so the tag is honest.
    /// CPU per-pixel loop is acceptable: it runs once.
    static func convert10bit(from bgra: CVPixelBuffer, pool: PixelBufferPool) throws -> CVPixelBuffer {
        let dst = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(bgra, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(bgra, .readOnly)
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(bgra),
              let dstBase = CVPixelBufferGetBaseAddress(dst)
        else { throw RenderError.contextCreationFailed }
        let width = CVPixelBufferGetWidth(bgra)
        let height = CVPixelBufferGetHeight(bgra)
        let srcStride = CVPixelBufferGetBytesPerRow(bgra)
        let dstStride = CVPixelBufferGetBytesPerRow(dst)
        let src = srcBase.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let dstRow = dstBase.advanced(by: row * dstStride).assumingMemoryBound(to: UInt32.self)
            for col in 0..<width {
                let p = row * srcStride + col * 4 // B G R A
                let (r10, g10, b10) = srgb8ToHLG2020Code(
                    r8: src[p + 2], g8: src[p + 1], b8: src[p]
                )
                dstRow[col] = (UInt32(3) << 30) | (r10 << 20) | (g10 << 10) | b10
            }
        }
        CVBufferSetAttachment(dst, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(dst, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(dst, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return dst
    }

    // MARK: - sRGB → Rec.2020/HLG (truthful 10-bit HDR conversion, #11)

    /// sRGB EOTF (IEC 61966-2-1): 8-bit non-linear code → display-linear light.
    @inline(__always) static func srgbEOTF(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// BT.2100 HLG OETF (ARIB STD-B67): scene-linear [0,1] → non-linear signal.
    @inline(__always) static func hlgOETF(_ e: Double) -> Double {
        let a = 0.17883277, b = 0.28466892, c = 0.55991073
        let x = max(0.0, min(1.0, e))
        return x <= 1.0 / 12.0 ? (3.0 * x).squareRoot() : a * Foundation.log(12.0 * x - b) + c
    }

    /// Convert one sRGB pixel (8-bit) to a Rec.2020 / BT.2100-HLG 10-bit
    /// full-range code triple. Pure — the #11 oracle: neutral 128 → ≈726.
    static func srgb8ToHLG2020Code(r8: UInt8, g8: UInt8, b8: UInt8) -> (UInt32, UInt32, UInt32) {
        // sRGB code → display-linear Rec.709/sRGB.
        let r = srgbEOTF(Double(r8) / 255.0)
        let g = srgbEOTF(Double(g8) / 255.0)
        let b = srgbEOTF(Double(b8) / 255.0)
        // Linear 709/sRGB → linear Rec.2020 primaries (rows sum to 1 → gray is
        // preserved). Coefficients: BT.709 → BT.2020 RGB (Bradford-adapted D65).
        let r2 = 0.627404 * r + 0.329283 * g + 0.043313 * b
        let g2 = 0.069097 * r + 0.919540 * g + 0.011362 * b
        let b2 = 0.016391 * r + 0.088013 * g + 0.895595 * b
        // HLG OETF → non-linear signal → 10-bit full-range code.
        @inline(__always) func code(_ e: Double) -> UInt32 {
            UInt32(max(0.0, min(1023.0, (hlgOETF(e) * 1023.0).rounded())))
        }
        return (code(r2), code(g2), code(b2))
    }

    // MARK: - Text

    private static func drawCenteredText(
        _ text: String, size: CGFloat, weightBold: Bool,
        color: CGColor, atY y: CGFloat, width: CGFloat, in ctx: CGContext
    ) {
        let font = CTFontCreateWithName((weightBold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ]
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.textPosition = CGPoint(x: (width - bounds.width) / 2, y: y)
        CTLineDraw(line, ctx)
    }
}
