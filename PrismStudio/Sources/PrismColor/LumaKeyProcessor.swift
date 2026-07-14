import CoreVideo
import Foundation
import Metal
import PrismCore
import simd

/// Zero-copy Metal luma keyer (DESIGN.md §2.3) — the luminance-based sibling of
/// `ChromaKeyProcessor`. A standalone `VideoFrame → VideoFrame` pass with the
/// same runtime-MSL / `CVMetalTextureCache` / `PixelBufferPool` plumbing as the
/// chroma keyer, but mattes on BT.709 luma instead of chroma distance.
///
/// Output: BGRA8 from the pool with **premultiplied alpha** — keyed background
/// pixels are transparent black `(0,0,0,0)`, foreground pixels keep their color
/// at α ≈ 1 — so the frame composites straight over lower layers (the
/// compositor honours premultipliedAlpha layers). Handles BGRA and 420v/420f
/// input like the other processors. Not thread-safe — one processor per source
/// pipeline.
///
/// Passing `matteView: true` to `apply` instead renders the computed alpha as
/// opaque grayscale (r = g = b = α, a = 1) — the §2.3 "matte view" for tuning a
/// key. Mirrors `ChromaKeyProcessor.apply(frame:key:matteView:)`.
public final class LumaKeyProcessor {
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
    private let logger = EngineLog.logger("color.lumakey")

    /// Mirrors the MSL `LumaUniforms` struct (64 bytes, 4 × float4).
    private struct LumaUniforms {
        var bounds: SIMD4<Float>  // x = lowLuma; y = highLuma; z = smoothness; w = fullRange (YUV)
        var flags: SIMD4<Float>   // x = invert; y = matteView; zw unused
        var yuvTags: SIMD4<Float> // YUV only: x matrix (0/1/2), y chromaOffsetX
        var extended: SIMD4<Float> // sol wave-11 #4: x = nonlinear extended-range flag; yzw pad
    }

    public init(device: MTLDevice) throws {
        self.device = device
        self.engine = try MetalColorEngine(device: device, label: "lumakey")
        self.keyBGRA = try engine.pipeline("prism_lumakey_bgra")
        self.keyYUV = try engine.pipeline("prism_lumakey_yuv")
    }

    /// Key `frame` against `key`, producing a premultiplied-alpha BGRA8 frame.
    ///
    /// - Parameter matteView: when `true`, output the alpha matte as opaque
    ///   grayscale (r = g = b = α·255, a = 255) instead of the keyed result —
    ///   the DESIGN.md §2.3 matte view for tuning.
    /// - Returns: a new frame with the input's PTS/duration/source passed
    ///   through untouched (house-time discipline — never re-stamp).
    public func apply(frame: VideoFrame, key: LumaKey, matteView: Bool = false) throws -> VideoFrame {
        var retained: [CVMetalTexture] = []
        let (input, isFloat) = try engine.inputTextures(for: frame, retained: &retained)
        let outputBuffer = try engine.makeOutputBuffer(width: frame.width, height: frame.height, float: isFloat)
        let outTexture = try engine.wrapOutput(outputBuffer,
                                               format: isFloat ? .rgba16Float : .bgra8Unorm,
                                               retained: &retained)

        var uniforms = LumaUniforms(
            bounds: SIMD4(Float(key.lowLuma), Float(key.highLuma), Float(key.smoothness), 0),
            flags: SIMD4(key.invert ? 1 : 0, matteView ? 1 : 0, 0, 0),
            yuvTags: .zero,
            extended: .zero)
        // sol wave-11 #4: a nonlinear extended-range source (extendedSRGB/709/P3) — the
        // KEPT foreground carries its > 1 highlights through (clamped only at output); the
        // luma-band decision is on the clamped luma (unchanged). 0 for bounded/SDR →
        // byte-identical. (YUV sources carry no extended name → stays 0 on that branch.)
        uniforms.extended.x = Float(YCbCrTags.extendedRangeCode(for: frame.pixelBuffer))

        let commandBuffer = try engine.makeCommandBuffer(label: "prism.color.lumakey")
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw ColorError.commandCreationFailed
        }
        encoder.label = "prism.color.lumakey.pass"
        switch input {
        case .bgra(let tex):
            encoder.setTexture(tex, index: 0)
            encoder.setTexture(outTexture, index: 1)
            encoder.setBytes(&uniforms, length: MemoryLayout<LumaUniforms>.stride, index: 0)
            engine.dispatch(encoder, pipeline: keyBGRA, width: frame.width, height: frame.height)
        case .yuv(let luma, let chroma, let fullRange, let tenBit):
            uniforms.bounds.w = fullRange ? 1 : 0
            // sol #3 finding 1: decode in the source's tagged matrix + siting so the
            // BT.709-luma band lines up with the correctly-decoded pixel.
            // wave-5b: yuvTags.z = tenBit.
            uniforms.yuvTags = SIMD4(Float(YCbCrTags.matrixCode(for: frame.pixelBuffer)),
                                     YCbCrTags.chromaOffsetX(for: frame.pixelBuffer, lumaWidth: frame.width),
                                     tenBit ? 1 : 0, 0)
            encoder.setTexture(luma, index: 0)
            encoder.setTexture(chroma, index: 1)
            encoder.setTexture(outTexture, index: 2)
            encoder.setBytes(&uniforms, length: MemoryLayout<LumaUniforms>.stride, index: 0)
            engine.dispatch(encoder, pipeline: keyYUV, width: frame.width, height: frame.height)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        // Synchronous completion, same rationale as ChromaKeyProcessor: the pass
        // is far cheaper than a frame interval and downstream must see a fully
        // written frame.
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(retained) {}
        // HIGH-4 / F13: a failed pass leaves undefined pixels — throw, never publish.
        var status = commandBuffer.status
        #if DEBUG
        if _test_forceExecutionFailure { status = .error }
        #endif
        if let err = ColorError.executionError(status: status, error: commandBuffer.error) { throw err }

        // sol #4 finding 1: carry the source's colorimetry tags onto the keyed
        // output (its rgb is the source colorspace, only masked) so the HDR
        // compositor does not double-rotate a Rec.2020 source 709→2020.
        YCbCrTags.propagateColorTags(from: frame.pixelBuffer, to: outputBuffer)
        return VideoFrame(pixelBuffer: outputBuffer, pts: frame.pts,
                          duration: frame.duration, source: frame.source)
    }
}
