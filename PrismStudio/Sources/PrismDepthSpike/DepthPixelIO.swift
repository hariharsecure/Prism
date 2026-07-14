import CoreVideo
import Foundation
import PrismCore
import simd

/// IOSurface-backed float pixel-buffer helpers for the spike fixtures. Uses the
/// sanctioned `PixelBufferPool` so the zero-copy / Metal-compatible invariant is
/// automatic. Two formats only:
///  - `r32Float`  (`OneComponent32Float`) for axial depth maps (NaN = invalid);
///  - `rgba32Float` (`128RGBAFloat`) for premultiplied color plates.
public enum DepthPixelIO {
    static let depthFormat = kCVPixelFormatType_OneComponent32Float
    static let colorFormat = kCVPixelFormatType_128RGBAFloat

    /// Sentinel written for an invalid/no-coverage depth sample. A valid axial Z
    /// is strictly positive, so any non-positive value is unambiguously invalid
    /// (the design's "separate validity, never a plausible zero"). A negative
    /// sentinel is used rather than NaN because Metal's math mode makes NaN
    /// comparisons unreliable; `!(z > 0)` on the GPU catches this sentinel AND
    /// any stray NaN.
    public static let invalidDepth: Float = -1.0

    /// Mint an r32Float depth buffer from a `(x, y) -> Z` closure. Return
    /// `Float.nan` for invalid pixels (the design's separate-validity contract).
    public static func makeDepth(width: Int, height: Int,
                                 _ fn: (Int, Int) -> Float) throws -> CVPixelBuffer {
        let pool: PixelBufferPool
        do { pool = try PixelBufferPool(width: width, height: height,
                                        pixelFormat: depthFormat, minimumBufferCount: 1) }
        catch { throw DepthSpikeError.bufferAllocationFailed(underlying: error) }
        let buf: CVPixelBuffer
        do { buf = try pool.makeBuffer() }
        catch { throw DepthSpikeError.bufferAllocationFailed(underlying: error) }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: Float.self)
        let stride = CVPixelBufferGetBytesPerRow(buf) / MemoryLayout<Float>.size
        for y in 0..<height { for x in 0..<width { base[y * stride + x] = fn(x, y) } }
        return buf
    }

    /// Mint an rgba32Float color buffer from a `(x, y) -> RGBA` closure.
    public static func makeColor(width: Int, height: Int,
                                 _ fn: (Int, Int) -> SIMD4<Float>) throws -> CVPixelBuffer {
        let pool: PixelBufferPool
        do { pool = try PixelBufferPool(width: width, height: height,
                                        pixelFormat: colorFormat, minimumBufferCount: 1) }
        catch { throw DepthSpikeError.bufferAllocationFailed(underlying: error) }
        let buf: CVPixelBuffer
        do { buf = try pool.makeBuffer() }
        catch { throw DepthSpikeError.bufferAllocationFailed(underlying: error) }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: SIMD4<Float>.self)
        let stride = CVPixelBufferGetBytesPerRow(buf) / MemoryLayout<SIMD4<Float>>.size
        for y in 0..<height { for x in 0..<width { base[y * stride + x] = fn(x, y) } }
        return buf
    }

    /// Read an rgba32Float buffer back into a row-major array (for the oracle).
    public static func readColor(_ buf: CVPixelBuffer) -> (pixels: [SIMD4<Float>], width: Int, height: Int) {
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: SIMD4<Float>.self)
        let stride = CVPixelBufferGetBytesPerRow(buf) / MemoryLayout<SIMD4<Float>>.size
        var out = [SIMD4<Float>](repeating: .zero, count: w * h)
        for y in 0..<h { for x in 0..<w { out[y * w + x] = base[y * stride + x] } }
        return (out, w, h)
    }

    /// Read an r32Float buffer back into a row-major array.
    public static func readDepth(_ buf: CVPixelBuffer) -> (pixels: [Float], width: Int, height: Int) {
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: Float.self)
        let stride = CVPixelBufferGetBytesPerRow(buf) / MemoryLayout<Float>.size
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { out[y * w + x] = base[y * stride + x] } }
        return (out, w, h)
    }
}
