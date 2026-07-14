import CoreVideo
import Foundation
import Metal
import PrismCore

/// The GPU background stage: applies a person matte to a frame as
/// remove / blur / color-replace (DESIGN.md §2.3 — no-green-screen
/// background removal).
///
/// Zero-copy in/out: the source frame is sampled in its native format
/// (BGRA8 or 420v/420f biplanar YUV) through a `CVMetalTextureCache`, the
/// matte (lower-res than the frame) is upscaled by the linear sampler in the
/// kernel, and the output is a BGRA8 `VideoFrame` minted from
/// `PixelBufferPool`. `.remove` emits **premultiplied** alpha so downstream
/// `one, oneMinusSourceAlpha` compositing is correct by default.
///
/// `.blur` runs a separable gaussian (horizontal → vertical, rgba16Float
/// private intermediates cached by frame size) over the whole frame, then
/// composites the sharp foreground back over it with the matte. Slight
/// foreground color bleed into the blurred background near edges is the
/// standard v0 trade; matte-weighted blur is a later refinement.
///
/// Thread model: NOT thread-safe — one instance per source pipeline, like
/// `ColorProcessor`. The CPU never touches pixels here.
public final class BackgroundEffect {
    public let device: MTLDevice

    private let engine: MetalVisionEngine
    private let compositeBGRA: MTLComputePipelineState
    private let compositeYUV: MTLComputePipelineState
    private let blurHBGRA: MTLComputePipelineState
    private let blurHYUV: MTLComputePipelineState
    private let blurV: MTLComputePipelineState
    /// Bound in non-blur modes — Metal requires declared texture args to be
    /// valid even on untaken branches.
    private let dummyBlurred: MTLTexture
    private var intermediateA: MTLTexture?
    private var intermediateB: MTLTexture?
    private var cachedWeightsRadius: Float = -1
    private var cachedWeights: [Float] = []

    #if DEBUG
    /// Test-only seam (F13 / Class H): when true, `apply` observes a **failed**
    /// command-buffer terminal status regardless of the real one, so the real
    /// `VisionError.executionError` status-check → throw fires and an upstream
    /// recovery (e.g. `PresenterCutout`'s catch → CPU fallback) is exercised
    /// deterministically. A genuine Metal device fault cannot be provoked
    /// reliably in a unit test without risking a process-killing GPU hang, so the
    /// failure is injected at the real throw site instead. No effect in release.
    public var _test_forceExecutionFailure = false
    #endif

    /// Mirrors the MSL `EffectUniforms` struct (48 bytes).
    private struct EffectUniforms {
        var replaceColor: SIMD4<Float> // rgb = replace color, w = tenBit (wave-5b)
        var params: SIMD4<Float> // x = mode, y = fullRange, z = matrix, w = siting
        var extended: SIMD4<Float> // sol wave-10 #3: x = nonlinear extended-range flag; yzw pad
    }

    /// Mirrors the MSL `BlurUniforms` struct (32 bytes).
    private struct BlurUniforms {
        var params: SIMD4<Float> // x = half tap count, y = fullRange, z = matrix, w = siting
        var params2: SIMD4<Float> // x = tenBit (wave-5b)
    }

    public init(device: MTLDevice) throws {
        self.device = device
        self.engine = try MetalVisionEngine(device: device, label: "background")
        self.compositeBGRA = try engine.pipeline("prism_bg_bgra")
        self.compositeYUV = try engine.pipeline("prism_bg_yuv")
        self.blurHBGRA = try engine.pipeline("prism_bgblur_h_bgra")
        self.blurHYUV = try engine.pipeline("prism_bgblur_h_yuv")
        self.blurV = try engine.pipeline("prism_bgblur_v")

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                            width: 1, height: 1, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw VisionError.intermediateTextureFailed
        }
        self.dummyBlurred = tex
    }

    /// Apply `mode` to `frame` using `matte` (person = white). Returns a new
    /// BGRA8 `VideoFrame` with PTS/duration/source passed through untouched
    /// (house-time discipline — never re-stamp).
    public func apply(frame: VideoFrame, matte: SegmentationMatte, mode: BackgroundMode) throws -> VideoFrame {
        var retained: [CVMetalTexture] = []
        let (input, isFloat) = try engine.inputTextures(for: frame, retained: &retained)
        let matteTex = try engine.matteTexture(for: matte, retained: &retained)
        // wave-5b: a 10-bit input is decoded + composited into a 64RGBAHalf output
        // (no 8-bit collapse); the compositor folds that half-float frame in.
        let outputBuffer = try engine.makeFrameBuffer(width: frame.width, height: frame.height, float: isFloat)
        let outTexture = try engine.wrapOutput(outputBuffer,
                                               format: isFloat ? .rgba16Float : .bgra8Unorm,
                                               retained: &retained)

        let fullRange: Float
        var tenBit: Float = 0
        switch input {
        case .bgra: fullRange = 0
        case .yuv(_, _, let full, let ten): fullRange = full ? 1 : 0; tenBit = ten ? 1 : 0
        }
        // N5: honor the source's tagged YCbCr matrix + horizontal chroma siting so
        // a 601/2020/left-sited source's background region decodes with the same
        // color as the primary compositor layer path (ignored on the BGRA path).
        let yuvMatrix = Float(YCbCrTags.matrixCode(for: frame.pixelBuffer))
        let chromaOffsetX = YCbCrTags.chromaOffsetX(for: frame.pixelBuffer, lumaWidth: frame.width)

        let commandBuffer = try engine.makeCommandBuffer(label: "prism.vision.background")

        var blurredTex = dummyBlurred
        var modeIndex: Float = 0
        var replaceColor = SIMD4<Float>(repeating: 0)
        switch mode {
        case .remove:
            modeIndex = 0
        case .blur(let radius):
            modeIndex = 1
            blurredTex = try encodeBlurPasses(commandBuffer, input: input,
                                              width: frame.width, height: frame.height,
                                              radius: radius, fullRange: fullRange,
                                              yuvMatrix: yuvMatrix, chromaOffsetX: chromaOffsetX,
                                              tenBit: tenBit)
        case .replace(let color):
            modeIndex = 2
            // sol #5 finding 4: convert the sRGB replacement colour INTO the source's
            // coded colorspace (primaries + transfer) BEFORE mixing, so the replaced
            // background AND the kept foreground are one homogeneous colorspace and the
            // propagated SOURCE tags are truthful — a Rec.2020/HLG source's sRGB-red
            // replacement becomes the correctly-converted 2020/HLG red, and the kept
            // foreground is no longer mis-tagged sRGB (the prior residual). SDR sources
            // return the colour unchanged (byte-identical).
            let converted = YCbCrTags.srgbColor(color, inSpaceOf: frame.pixelBuffer)
            replaceColor = SIMD4(converted, 1)
        }

        // wave-5b: `replaceColor.w` carries `tenBit` (the YUV kernel reads it; the
        // replace-mode composite ignores it, so the replacement rgb is unaffected).
        replaceColor.w = tenBit
        // sol wave-10 #3: a nonlinear extended-range BGRA half-float source
        // (extendedSRGB/709/P3) carries legal >1 highlights; the pre-fix unconditional
        // `saturate` in `prism_bg_bgra` crushed them before the composite (remove
        // identity of extendedSRGB 1.5 → 1.0 / downstream 756 instead of 1.5 / 937).
        // 0 for every bounded/SDR source and all YUV (integer [0,1]) → byte-identical.
        let extendedRange = Float(YCbCrTags.extendedRangeCode(for: frame.pixelBuffer))
        var uniforms = EffectUniforms(replaceColor: replaceColor,
                                      params: SIMD4(modeIndex, fullRange, yuvMatrix, chromaOffsetX),
                                      extended: SIMD4(extendedRange, 0, 0, 0))
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw VisionError.commandCreationFailed
        }
        encoder.label = "prism.vision.background.composite"
        switch input {
        case .bgra(let tex):
            encoder.setTexture(tex, index: 0)
            encoder.setTexture(blurredTex, index: 1)
            encoder.setTexture(matteTex, index: 2)
            encoder.setTexture(outTexture, index: 3)
            encoder.setBytes(&uniforms, length: MemoryLayout<EffectUniforms>.stride, index: 0)
            engine.dispatch(encoder, pipeline: compositeBGRA, width: frame.width, height: frame.height)
        case .yuv(let luma, let chroma, _, _):
            encoder.setTexture(luma, index: 0)
            encoder.setTexture(chroma, index: 1)
            encoder.setTexture(blurredTex, index: 2)
            encoder.setTexture(matteTex, index: 3)
            encoder.setTexture(outTexture, index: 4)
            encoder.setBytes(&uniforms, length: MemoryLayout<EffectUniforms>.stride, index: 0)
            engine.dispatch(encoder, pipeline: compositeYUV, width: frame.width, height: frame.height)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        // Synchronous completion, same rationale as ColorProcessor: the
        // returned frame must be fully written before downstream consumers
        // read it; the pass is far cheaper than a frame interval.
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(retained) {}

        // The pass is now final: on a GPU OOM / device fault / timeout the pooled
        // output holds undefined or stale pixels. THROW the typed error (carrying
        // commandBuffer.error) so an upstream recovery — e.g. PresenterCutout's
        // CPU fallback — engages, instead of publishing a corrupt frame as a
        // successful one.
        var terminalStatus = commandBuffer.status
        #if DEBUG
        if _test_forceExecutionFailure { terminalStatus = .error }
        #endif
        if let err = VisionError.executionError(status: terminalStatus,
                                                error: commandBuffer.error) {
            throw err
        }

        // sol #3 finding 4 / sol #4 finding 2 / sol #5 finding 4: propagate the
        // source's colorimetry tags for EVERY mode, because the output is now genuinely
        // in the source's colorspace in all three:
        //  - `.remove` / `.blur`: the visible pixels ARE the source (kept foreground,
        //    blurred source background).
        //  - `.replace`: the sRGB replacement colour was converted INTO the source's
        //    coded space above, so the replaced background AND the kept foreground are
        //    one homogeneous colorspace — the source tags are truthful. (This SUPERSEDES
        //    the earlier stampSRGB workaround, which fixed the background but left the
        //    kept foreground mis-tagged sRGB → double-rotated in the HDR compositor.)
        // Carrying the source tags keeps a Rec.2020 source from being rotated 709→2020
        // a SECOND time (double-rotation).
        YCbCrTags.propagateColorTags(from: frame.pixelBuffer, to: outputBuffer)
        return VideoFrame(pixelBuffer: outputBuffer, pts: frame.pts,
                          duration: frame.duration, source: frame.source)
    }

    // MARK: - Blur

    /// Encode horizontal + vertical gaussian passes; returns the texture
    /// holding the fully blurred frame. Separate encoders guarantee pass
    /// ordering on the tracked resources.
    private func encodeBlurPasses(_ commandBuffer: MTLCommandBuffer, input: SourceTextures,
                                  width: Int, height: Int,
                                  radius: Float, fullRange: Float,
                                  yuvMatrix: Float, chromaOffsetX: Float, tenBit: Float) throws -> MTLTexture {
        let (texA, texB) = try intermediates(width: width, height: height)
        let weights = gaussianWeights(radius: radius)
        // N5: the horizontal YUV blur pass decodes with the tagged matrix + siting;
        // the vertical pass runs on the already-decoded rgba16Float intermediate.
        var uniforms = BlurUniforms(params: SIMD4(Float(weights.count - 1), fullRange, yuvMatrix, chromaOffsetX),
                                    params2: SIMD4(tenBit, 0, 0, 0))

        guard let hEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw VisionError.commandCreationFailed
        }
        hEncoder.label = "prism.vision.background.blurH"
        switch input {
        case .bgra(let tex):
            hEncoder.setTexture(tex, index: 0)
            hEncoder.setTexture(texA, index: 1)
            hEncoder.setBytes(&uniforms, length: MemoryLayout<BlurUniforms>.stride, index: 0)
            hEncoder.setBytes(weights, length: weights.count * MemoryLayout<Float>.stride, index: 1)
            engine.dispatch(hEncoder, pipeline: blurHBGRA, width: width, height: height)
        case .yuv(let luma, let chroma, _, _):
            hEncoder.setTexture(luma, index: 0)
            hEncoder.setTexture(chroma, index: 1)
            hEncoder.setTexture(texA, index: 2)
            hEncoder.setBytes(&uniforms, length: MemoryLayout<BlurUniforms>.stride, index: 0)
            hEncoder.setBytes(weights, length: weights.count * MemoryLayout<Float>.stride, index: 1)
            engine.dispatch(hEncoder, pipeline: blurHYUV, width: width, height: height)
        }
        hEncoder.endEncoding()

        guard let vEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw VisionError.commandCreationFailed
        }
        vEncoder.label = "prism.vision.background.blurV"
        vEncoder.setTexture(texA, index: 0)
        vEncoder.setTexture(texB, index: 1)
        vEncoder.setBytes(&uniforms, length: MemoryLayout<BlurUniforms>.stride, index: 0)
        vEncoder.setBytes(weights, length: weights.count * MemoryLayout<Float>.stride, index: 1)
        engine.dispatch(vEncoder, pipeline: blurV, width: width, height: height)
        vEncoder.endEncoding()
        return texB
    }

    private func intermediates(width: Int, height: Int) throws -> (MTLTexture, MTLTexture) {
        if let a = intermediateA, let b = intermediateB, a.width == width, a.height == height {
            return (a, b)
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                            width: width, height: height,
                                                            mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let a = device.makeTexture(descriptor: desc),
              let b = device.makeTexture(descriptor: desc) else {
            throw VisionError.intermediateTextureFailed
        }
        a.label = "prism.vision.blur.intermediateA"
        b.label = "prism.vision.blur.intermediateB"
        intermediateA = a
        intermediateB = b
        return (a, b)
    }

    /// Normalized half-kernel gaussian weights: `weights[i]` is the weight of
    /// tap ±i, `weights.count - 1` taps each side. `sigma = radius/2`; reach
    /// clamped to 1…63 so `setBytes` stays tiny and the loop bounded.
    private func gaussianWeights(radius: Float) -> [Float] {
        if radius == cachedWeightsRadius { return cachedWeights }
        let reach = min(max(Int(radius.rounded(.up)), 1), 63)
        let sigma = max(radius, 1) / 2
        var weights = (0...reach).map { i -> Float in
            let x = Float(i)
            return exp(-x * x / (2 * sigma * sigma))
        }
        let sum = weights[0] + 2 * weights.dropFirst().reduce(0, +)
        weights = weights.map { $0 / sum }
        cachedWeightsRadius = radius
        cachedWeights = weights
        return weights
    }
}
