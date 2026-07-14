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
}
