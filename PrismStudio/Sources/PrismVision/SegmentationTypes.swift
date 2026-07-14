import CoreMedia
import CoreVideo
import Foundation
import Metal
import PrismCore

/// Errors shared by all PrismVision components.
public enum VisionError: Error {
    /// No Metal device / required capability missing.
    case metalUnavailable(String)
    /// Runtime MSL compilation failed (embedded shader source).
    case libraryCompilationFailed(underlying: Error)
    /// A named kernel is missing from the compiled library.
    case functionNotFound(String)
    case pipelineCreationFailed(String, underlying: Error)
    case textureCacheCreationFailed(CVReturn)
    /// Wrapping an input pixel buffer plane as a Metal texture failed.
    case inputTextureWrapFailed(SourceID)
    /// Wrapping a matte buffer as a Metal texture failed.
    case matteTextureWrapFailed
    /// Wrapping the output buffer as a writable Metal texture failed.
    case outputTextureWrapFailed(CVReturn)
    /// Minting an output CVPixelBuffer from the pool failed.
    case outputBufferFailed(underlying: Error)
    /// Metal command buffer / encoder creation failed.
    case commandCreationFailed
    /// A frame arrived in a pixel format the kernel set doesn't handle.
    case unsupportedPixelFormat(OSType)
    /// A matte arrived in a pixel format other than OneComponent8.
    case unsupportedMatteFormat(OSType)
    /// Allocating a private intermediate texture (blur passes) failed.
    case intermediateTextureFailed
    /// The Vision request itself failed.
    case segmentationFailed(underlying: Error)
    /// Copying a non-IOSurface Vision matte into a pooled buffer failed.
    case matteCopyFailed
    /// A committed command buffer finished in a non-`.completed` state (GPU
    /// OOM / device fault / timeout). The output frame holds undefined or stale
    /// pooled pixels and MUST NOT be published — throwing lets an upstream
    /// recovery (e.g. `PresenterCutout`'s CPU fallback) actually engage instead
    /// of emitting a corrupt frame as if the GPU succeeded. Carries
    /// `commandBuffer.error`.
    case gpuExecutionFailed(underlying: Error?)
}

extension VisionError {
    /// Map a finished command buffer's terminal state to the typed error the
    /// caller must throw (`nil` == completed OK). Extracted so the completion
    /// check is unit-testable without provoking a real GPU fault.
    static func executionError(status: MTLCommandBufferStatus,
                               error: Error?) -> VisionError? {
        status == .completed ? nil : .gpuExecutionFailed(underlying: error)
    }
}

/// One person-segmentation matte: a single-channel (`OneComponent8`)
/// alpha mask where 255 = person, 0 = background, tied to the frame it was
/// computed from by `pts` + `source`.
///
/// The matte is typically LOWER resolution than the video frame (Vision
/// returns model-native sizes); consumers upscale by GPU sampler
/// (`BackgroundEffect` does this — never resample on the CPU).
public struct SegmentationMatte: @unchecked Sendable {
    /// Single-channel `kCVPixelFormatType_OneComponent8`, IOSurface-backed.
    public let pixelBuffer: CVPixelBuffer
    /// House-time PTS of the video frame this matte was computed from.
    public let pts: CMTime
    /// The source the frame came from.
    public let source: SourceID

    public init(pixelBuffer: CVPixelBuffer, pts: CMTime, source: SourceID) {
        self.pixelBuffer = pixelBuffer
        self.pts = pts
        self.source = source
    }

    public var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
    public var height: Int { CVPixelBufferGetHeight(pixelBuffer) }
}

/// What `BackgroundEffect` does with the background (matte < 0.5-ish).
public enum BackgroundMode: Equatable, Sendable {
    /// Alpha-out the background: output is BGRA with **premultiplied** alpha
    /// (foreground keeps its color at alpha≈1; background → transparent black).
    case remove
    /// Gaussian-blur the background (separable, two passes), keep the person
    /// sharp. `radius` in pixels at frame resolution (clamped to 1…63 taps/side).
    case blur(radius: Float)
    /// Replace the background with a solid color (v0 of image replace).
    /// `color` = linear-ish gamma-encoded RGB, 0…1 (same space as the frame).
    case replace(color: SIMD3<Float>)
}
