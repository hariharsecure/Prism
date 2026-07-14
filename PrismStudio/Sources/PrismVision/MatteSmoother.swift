import CoreVideo
import Foundation
import Metal
import PrismCore

/// Temporal exponential blend of consecutive segmentation mattes on the GPU
/// (`out = α·current + (1−α)·previousOutput`) — kills matte flicker between
/// Vision runs (DESIGN.md §3.5: "a matte texture the shader samples with
/// temporal smoothing").
///
/// State: the smoother keeps its **own last output** (an exponential moving
/// average), so cost is one tiny compute pass per matte at segmentation rate
/// (~15 Hz), not per rendered frame. If the incoming matte size changes (a
/// source reconfigure or quality switch), state resets and the new matte
/// passes through unblended.
///
/// Thread model: NOT thread-safe — one smoother per source, driven from the
/// segmentation callback (which `PersonSegmenter` serializes). The CPU never
/// touches pixels here.
public final class MatteSmoother {
    public let device: MTLDevice

    /// Weight of the NEW matte (0…1, clamped). 1 = no smoothing;
    /// smaller = smoother but laggier edges. Default 0.5 ≈ two-frame memory.
    public var alpha: Float

    private let engine: MetalVisionEngine
    private let blend: MTLComputePipelineState
    /// Bound when there is no previous matte yet — Metal requires declared
    /// texture args to be valid even on untaken branches.
    private let dummyPrevious: MTLTexture
    private var previous: CVPixelBuffer?

    /// Mirrors the MSL `BlendUniforms` struct (16 bytes).
    private struct BlendUniforms {
        var params: SIMD4<Float> // x = alpha, y = hasPrevious
    }

    public init(device: MTLDevice, alpha: Float = 0.5) throws {
        self.device = device
        self.alpha = alpha
        self.engine = try MetalVisionEngine(device: device, label: "mattesmooth")
        self.blend = try engine.pipeline("prism_matte_blend")

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
                                                            width: 1, height: 1, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw VisionError.intermediateTextureFailed
        }
        self.dummyPrevious = tex
    }

    /// Blend `matte` against the smoother's running state and return the
    /// smoothed matte (same size, PTS and source passed through).
    public func smooth(_ matte: SegmentationMatte) throws -> SegmentationMatte {
        var retained: [CVMetalTexture] = []
        let currentTex = try engine.matteTexture(for: matte, retained: &retained)

        // Size change (or first matte) → reset: pass through unblended.
        var previousTex: MTLTexture? = nil
        if let previous,
           CVPixelBufferGetWidth(previous) == matte.width,
           CVPixelBufferGetHeight(previous) == matte.height {
            let prevMatte = SegmentationMatte(pixelBuffer: previous, pts: matte.pts, source: matte.source)
            previousTex = try engine.matteTexture(for: prevMatte, retained: &retained)
        }

        let outputBuffer = try engine.makeMatteBuffer(width: matte.width, height: matte.height)
        let outTexture = try engine.wrapOutput(outputBuffer, format: .r8Unorm, retained: &retained)

        let clamped = min(max(alpha, 0), 1)
        var uniforms = BlendUniforms(params: SIMD4(clamped, previousTex == nil ? 0 : 1, 0, 0))

        let commandBuffer = try engine.makeCommandBuffer(label: "prism.vision.matteblend")
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw VisionError.commandCreationFailed
        }
        encoder.label = "prism.vision.matteblend.pass"
        encoder.setTexture(currentTex, index: 0)
        encoder.setTexture(previousTex ?? dummyPrevious, index: 1)
        encoder.setTexture(outTexture, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<BlendUniforms>.stride, index: 0)
        engine.dispatch(encoder, pipeline: blend, width: matte.width, height: matte.height)
        encoder.endEncoding()
        commandBuffer.commit()
        // Synchronous completion (same rationale as ColorProcessor): the
        // returned matte must be fully written before consumers sample it;
        // the pass is microseconds at matte resolution.
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(retained) {}
        // HIGH-4 / F13: a failed pass leaves an undefined matte — throw before
        // caching it as `previous` (a bad matte must not poison the next blend).
        if let err = VisionError.executionError(status: commandBuffer.status, error: commandBuffer.error) { throw err }

        previous = outputBuffer
        return SegmentationMatte(pixelBuffer: outputBuffer, pts: matte.pts, source: matte.source)
    }

    /// Drop the temporal state (e.g. on scene cut) — the next matte passes
    /// through unblended.
    public func reset() {
        previous = nil
    }
}
