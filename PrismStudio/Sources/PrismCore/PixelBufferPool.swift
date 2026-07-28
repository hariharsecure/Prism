import CoreVideo
import Foundation

/// IOSurface-backed CVPixelBuffer pool — the only sanctioned way to mint
/// buffers in this codebase (keeps the zero-copy invariant automatic).
public final class PixelBufferPool: @unchecked Sendable {
    public enum PoolError: Error { case creationFailed(CVReturn), allocationFailed(CVReturn) }

    private let pool: CVPixelBufferPool
    public let width: Int
    public let height: Int
    public let pixelFormat: OSType

    public init(width: Int, height: Int, pixelFormat: OSType = kCVPixelFormatType_32BGRA, minimumBufferCount: Int = 6) throws {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: minimumBufferCount,
        ]
        let bufferAttrs: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, bufferAttrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { throw PoolError.creationFailed(status) }
        self.pool = pool
    }

    public func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw PoolError.allocationFailed(status) }
        return buffer
    }

    /// Release the pool's *unused* (returned, not in-flight) buffers so a past
    /// spike's IOSurfaces don't stay resident for process lifetime.
    ///
    /// The pool is created with only `kCVPixelBufferPoolMinimumBufferCountKey`
    /// (no age-out), so after a transient spike pushes the outstanding count to
    /// K it permanently retains K IOSurfaces. `kCVPixelBufferPoolFlushExcessBuffers`
    /// (verified in the MacOSX SDK `<CoreVideo/CVPixelBufferPool.h>`: the flush
    /// flag "will cause CVPixelBufferPoolFlush to flush all unused buffers
    /// regardless of age") frees every buffer *currently sitting in the pool's
    /// free list* — buffers still held by consumers are untouched, so steady-state
    /// recycling is unaffected.
    ///
    /// This is a latent-hardening seam, NOT a live-bug fix: call it only at idle
    /// seams (stream disarm / source teardown / canvas reconfig), never per-frame
    /// — the hot path must stay allocation-free.
    public func flushExcess() {
        CVPixelBufferPoolFlush(pool, .excessBuffers)
    }
}
