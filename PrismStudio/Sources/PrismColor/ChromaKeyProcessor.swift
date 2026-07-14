import CoreVideo
import Foundation
import Metal
import PrismCore
import simd

/// Zero-copy Metal chroma keyer (DESIGN.md §2.3). A standalone `VideoFrame →
/// VideoFrame` pass — same runtime-MSL / `CVMetalTextureCache` / `PixelBufferPool`
/// plumbing as `ColorProcessor`, but a distinct kernel and its own
/// `MetalColorEngine`.
///
/// Design choice — **standalone pass, not folded into the grade kernel**: the
/// keyer is per-source and optional, its output is a premultiplied-alpha matte
/// meant to composite over lower layers, whereas the grade kernel emits opaque
/// program-space BGRA. Keeping them separate lets the compositor order
/// key → grade (or vice-versa) freely and skip the keyer entirely when a
/// source isn't a green-screen source; the compositor's own per-layer effect
/// kernel can later inline this matte if a fused path is ever measured to win.
///
/// Output: BGRA8 from the pool with **premultiplied alpha** — keyed background
/// pixels are transparent black `(0,0,0,0)`; foreground pixels keep their
/// (despilled) color at α ≈ 1. Handles BGRA and 420v/420f input like the other
/// processors. Not thread-safe — one processor per source pipeline.
public final class ChromaKeyProcessor {
    public let device: MTLDevice

    #if DEBUG
    /// Test-only seam (F13 / Class H): force the real command-buffer status-check
    /// in `apply` to see a failed terminal state, so the throw fires
    /// deterministically without provoking a real (hang-risking) device fault.
    /// No effect in release.
    public var _test_forceExecutionFailure = false
    #endif

    private let engine: MetalColorEngine
    private let keyBGRA: MTLComputePipelineState
    private let keyYUV: MTLComputePipelineState
    private let matteBGRA: MTLComputePipelineState
    private let matteYUV: MTLComputePipelineState
    private let logger = EngineLog.logger("color.chromakey")

    /// Mirrors the MSL `ChromaUniforms` struct (64 bytes, 4 × float4).
    private struct ChromaUniforms {
        var keyColor: SIMD4<Float> // xyz = key RGB; w = similarity
        var params: SIMD4<Float>   // x = smoothness; y = spill; z = fullRange; w unused
        var yuvTags: SIMD4<Float>  // YUV only: x matrix (0/1/2), y chromaOffsetX
        var extended: SIMD4<Float> // sol wave-11 #4: x = nonlinear extended-range flag; yzw pad
    }

    public init(device: MTLDevice) throws {
        self.device = device
        self.engine = try MetalColorEngine(device: device, label: "chromakey")
        self.keyBGRA = try engine.pipeline("prism_chromakey_bgra")
        self.keyYUV = try engine.pipeline("prism_chromakey_yuv")
        self.matteBGRA = try engine.pipeline("prism_chromakey_matte_bgra")
        self.matteYUV = try engine.pipeline("prism_chromakey_matte_yuv")
    }

    /// Key `frame` against `key`, producing a premultiplied-alpha BGRA8 frame.
    ///
    /// - Parameter matteView: when `true`, output the alpha matte as opaque
    ///   grayscale (r = g = b = α·255, a = 255) instead of the keyed result —
    ///   the DESIGN.md §2.3 matte view for tuning a key.
    /// - Returns: a new frame with the input's PTS/duration/source passed
    ///   through untouched (house-time discipline — never re-stamp).
    public func apply(frame: VideoFrame, key: ChromaKey, matteView: Bool = false) throws -> VideoFrame {
        var retained: [CVMetalTexture] = []
        let (input, isFloat) = try engine.inputTextures(for: frame, retained: &retained)
        let outputBuffer = try engine.makeOutputBuffer(width: frame.width, height: frame.height, float: isFloat)
        let outTexture = try engine.wrapOutput(outputBuffer,
                                               format: isFloat ? .rgba16Float : .bgra8Unorm,
                                               retained: &retained)

        var uniforms = ChromaUniforms(
            keyColor: SIMD4(key.keyColor, Float(key.similarity)),
            params: SIMD4(Float(key.smoothness), Float(key.spillStrength), 0, 0),
            yuvTags: .zero,
            extended: .zero)
        // sol wave-11 #4: a nonlinear extended-range source (extendedSRGB/709/P3) — the
        // KEPT foreground must carry its > 1 highlights through the key (clamped only at
        // output); the matte decision is computed on the clamped value (unchanged). 0 for
        // every bounded/SDR source → byte-identical. (YUV sources never carry an extended
        // name, so this stays 0 on the YUV branch below.)
        uniforms.extended.x = Float(YCbCrTags.extendedRangeCode(for: frame.pixelBuffer))

        let commandBuffer = try engine.makeCommandBuffer(label: "prism.color.chromakey")
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw ColorError.commandCreationFailed
        }
        encoder.label = "prism.color.chromakey.pass"
        switch input {
        case .bgra(let tex):
            encoder.setTexture(tex, index: 0)
            encoder.setTexture(outTexture, index: 1)
            encoder.setBytes(&uniforms, length: MemoryLayout<ChromaUniforms>.stride, index: 0)
            engine.dispatch(encoder, pipeline: matteView ? matteBGRA : keyBGRA,
                            width: frame.width, height: frame.height)
        case .yuv(let luma, let chroma, let fullRange, let tenBit):
            uniforms.params.z = fullRange ? 1 : 0
            // sol #3 finding 1: decode in the source's tagged matrix + siting so the
            // key operates on the correctly-hued RGB. wave-5b: yuvTags.z = tenBit.
            uniforms.yuvTags = SIMD4(Float(YCbCrTags.matrixCode(for: frame.pixelBuffer)),
                                     YCbCrTags.chromaOffsetX(for: frame.pixelBuffer, lumaWidth: frame.width),
                                     tenBit ? 1 : 0, 0)
            encoder.setTexture(luma, index: 0)
            encoder.setTexture(chroma, index: 1)
            encoder.setTexture(outTexture, index: 2)
            encoder.setBytes(&uniforms, length: MemoryLayout<ChromaUniforms>.stride, index: 0)
            engine.dispatch(encoder, pipeline: matteView ? matteYUV : keyYUV,
                            width: frame.width, height: frame.height)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        // Synchronous completion, same rationale as ColorProcessor: downstream
        // consumers must see a fully-written frame; the pass is far cheaper
        // than a frame interval.
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(retained) {}
        // HIGH-4 / F13: a failed pass leaves undefined pixels — throw, never publish.
        var status = commandBuffer.status
        #if DEBUG
        if _test_forceExecutionFailure { status = .error }
        #endif
        if let err = ColorError.executionError(status: status, error: commandBuffer.error) { throw err }

        // sol #4 finding 1: the keyer decodes in the source's primaries and only
        // masks/despills — its (premultiplied) rgb is still the source colorspace,
        // so carry the colorimetry tags onto the output (else the HDR compositor
        // double-rotates a Rec.2020 source 709→2020).
        YCbCrTags.propagateColorTags(from: frame.pixelBuffer, to: outputBuffer)
        return VideoFrame(pixelBuffer: outputBuffer, pts: frame.pts,
                          duration: frame.duration, source: frame.source)
    }
}
