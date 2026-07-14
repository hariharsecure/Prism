import CoreVideo
import Foundation
import Metal
import PrismCore
import simd

/// The per-source GPU color stage (DESIGN.md §3.7): a zero-copy
/// `VideoFrame → VideoFrame` filter that runs *before* compositing.
///
/// **One fused kernel** does the whole grade+LUT path per pixel:
/// sample native input (BGRA8 or 420v/420f biplanar YUV, wrapped through a
/// `CVMetalTextureCache`) → linearize (pure 2.2 power — a stated v0
/// approximation of the BT.709/sRGB display chain) → exposure × white
/// balance in linear light → re-encode → lift/gamma/gain → contrast
/// (pivot 0.5) → saturation → optional 1D/3D LUT (trilinear, domain-scaled)
/// → BGRA8 output minted from `PixelBufferPool`.
///
/// Transfer-function honesty: contrast/saturation/wheels/LUT run on
/// gamma-encoded BT.709 values (grading-tool convention); only exposure and
/// temp/tint act in (approximately) linear light. No scene-linear or
/// color-managed working space in v0 — that is a later, explicit upgrade.
///
/// Thread model: NOT thread-safe — one processor per source pipeline, driven
/// from that source's processing queue. The CPU never touches pixels here.
public final class ColorProcessor {
    public let device: MTLDevice

    #if DEBUG
    /// Test-only seam (F13 / Class H): force the real command-buffer status-check
    /// in `process` to see a failed terminal state, so the throw fires
    /// deterministically without provoking a real (hang-risking) device fault.
    /// No effect in release.
    public var _test_forceExecutionFailure = false
    #endif

    private let engine: MetalColorEngine
    private let gradeBGRA: MTLComputePipelineState
    private let gradeYUV: MTLComputePipelineState
    /// Bound when no LUT (or the other LUT kind) is active — Metal requires
    /// declared texture args to be valid even on untaken branches.
    private let dummyLUT3D: MTLTexture
    private let dummyLUT1D: MTLTexture
    private var cachedLUTID: UUID?
    private var cachedLUTTexture: MTLTexture?
    private let logger = EngineLog.logger("color")

    /// Mirrors the MSL `GradeUniforms` struct (128 bytes, 8 × float4).
    private struct GradeUniforms {
        var linearGains: SIMD4<Float>    // xyz gains, w contrast
        var lift: SIMD4<Float>           // xyz lift, w saturation
        var invGamma: SIMD4<Float>       // xyz 1/gamma, w fullRange
        var gain: SIMD4<Float>           // xyz gain, w lutMode
        var lutDomainMin: SIMD4<Float>   // xyz, w LUT size
        var lutDomainScale: SIMD4<Float> // xyz, w = source transfer
        var yuvTags: SIMD4<Float>        // YUV only: x matrix (0/1/2), y chromaOffsetX, z tenBit
        var extended: SIMD4<Float>       // sol wave-10 #3: x = nonlinear extended-range flag; yzw pad
    }

    public init(device: MTLDevice) throws {
        self.device = device
        // 3D LUTs are rgba32Float + trilinear: require 32-bit float filtering
        // (true on every Apple-silicon Mac GPU — DESIGN.md A1).
        guard device.supports32BitFloatFiltering else {
            throw ColorError.metalUnavailable("32-bit float filtering unsupported on \(device.name)")
        }
        self.engine = try MetalColorEngine(device: device, label: "grade")
        self.gradeBGRA = try engine.pipeline("prism_grade_bgra")
        self.gradeYUV = try engine.pipeline("prism_grade_yuv")

        func makeDummy(_ type: MTLTextureType) throws -> MTLTexture {
            let desc = MTLTextureDescriptor()
            desc.textureType = type
            desc.pixelFormat = .rgba32Float
            desc.width = 1
            if type == .type3D { desc.height = 1; desc.depth = 1 }
            desc.usage = .shaderRead
            desc.storageMode = .shared
            guard let tex = device.makeTexture(descriptor: desc) else {
                throw ColorError.lutTextureCreationFailed
            }
            return tex
        }
        self.dummyLUT3D = try makeDummy(.type3D)
        self.dummyLUT1D = try makeDummy(.type1D)
    }

    /// Apply `grade` (and optionally `lut`) to one frame.
    ///
    /// - Returns: a new BGRA8 `VideoFrame` with the input's PTS/duration/source
    ///   passed through untouched (house-time discipline — never re-stamp).
    /// - Note: identity grade + `nil` LUT still runs the kernel; callers that
    ///   want a true no-op should check `grade.isIdentity && lut == nil` and
    ///   skip the stage.
    public func process(_ frame: VideoFrame, grade: ColorGrade, lut: CubeLUT?) throws -> VideoFrame {
        var retained: [CVMetalTexture] = []
        let (input, isFloat) = try engine.inputTextures(for: frame, retained: &retained)
        let outputBuffer = try engine.makeOutputBuffer(width: frame.width, height: frame.height, float: isFloat)
        let outTexture = try engine.wrapOutput(outputBuffer,
                                               format: isFloat ? .rgba16Float : .bgra8Unorm,
                                               retained: &retained)

        let (lut3, lut1, lutMode) = try lutTextures(for: lut)
        var uniforms = Self.uniforms(for: grade, lut: lut, lutMode: lutMode)
        // sol #5 finding 2: pass the SOURCE transfer so the grade's linear-light leg
        // (exposure / white-balance) linearizes + re-encodes with the CORRECT curve
        // instead of a hardcoded 2.2 — an HLG/PQ/Linear source grades in true linear;
        // 709/sRGB stay the 2.2 approximation (unchanged). `lutDomainScale.w` (unused)
        // carries it for BOTH the BGRA and YUV kernels.
        uniforms.lutDomainScale.w = Float(YCbCrTags.transferCode(for: frame.pixelBuffer))
        // sol wave-10 #3: a nonlinear extended-range source (extendedSRGB/709/P3) must
        // NOT have its >1 highlights pre-clamped in grade (the wave-9 compositor already
        // carries them). Set on a DEDICATED field so it survives the YUV branch's
        // `yuvTags` reassignment; the BGRA branch reads the same field. 0 for every
        // bounded/SDR source → byte-identical. (Linear EDR is already handled by the
        // transfer==4 branch in-shader.)
        uniforms.extended.x = Float(YCbCrTags.extendedRangeCode(for: frame.pixelBuffer))

        let commandBuffer = try engine.makeCommandBuffer(label: "prism.color.grade")
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw ColorError.commandCreationFailed
        }
        encoder.label = "prism.color.grade.pass"
        switch input {
        case .bgra(let tex):
            encoder.setTexture(tex, index: 0)
            encoder.setTexture(outTexture, index: 1)
            encoder.setTexture(lut3, index: 2)
            encoder.setTexture(lut1, index: 3)
            encoder.setBytes(&uniforms, length: MemoryLayout<GradeUniforms>.stride, index: 0)
            engine.dispatch(encoder, pipeline: gradeBGRA, width: frame.width, height: frame.height)
        case .yuv(let luma, let chroma, let fullRange, let tenBit):
            uniforms.invGamma.w = fullRange ? 1 : 0
            // sol #3 finding 1: honor the source's tagged YCbCr matrix + horizontal
            // chroma siting (same as the compositor layer path) so a 601/2020/left-
            // sited source grades with the correct hue instead of centered 709.
            // wave-5b: yuvTags.z = tenBit (10-bit P010-style sampling).
            uniforms.yuvTags = SIMD4(Float(YCbCrTags.matrixCode(for: frame.pixelBuffer)),
                                     YCbCrTags.chromaOffsetX(for: frame.pixelBuffer, lumaWidth: frame.width),
                                     tenBit ? 1 : 0, 0)
            encoder.setTexture(luma, index: 0)
            encoder.setTexture(chroma, index: 1)
            encoder.setTexture(outTexture, index: 2)
            encoder.setTexture(lut3, index: 3)
            encoder.setTexture(lut1, index: 4)
            encoder.setBytes(&uniforms, length: MemoryLayout<GradeUniforms>.stride, index: 0)
            engine.dispatch(encoder, pipeline: gradeYUV, width: frame.width, height: frame.height)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        // Synchronous completion, same rationale as the compositor: the
        // returned frame must be fully written before downstream consumers
        // read it; the pass is far cheaper than a frame interval.
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(retained) {}
        // HIGH-4 / F13: a failed pass leaves undefined pixels — throw, never publish.
        var status = commandBuffer.status
        #if DEBUG
        if _test_forceExecutionFailure { status = .error }
        #endif
        if let err = ColorError.executionError(status: status, error: commandBuffer.error) { throw err }

        // sol #4 finding 1: carry the source's colorimetry tags onto the derived
        // BGRA output — the grade decodes in the source's primaries, so the output
        // pixels ARE genuinely in that colorspace. Without this a Rec.2020/HLG
        // source reads untagged downstream and the HDR compositor rotates 709→2020
        // a SECOND time (double-rotation).
        YCbCrTags.propagateColorTags(from: frame.pixelBuffer, to: outputBuffer)
        return VideoFrame(pixelBuffer: outputBuffer, pts: frame.pts,
                          duration: frame.duration, source: frame.source)
    }

    // MARK: - Uniforms

    private static func uniforms(for grade: ColorGrade, lut: CubeLUT?, lutMode: Float) -> GradeUniforms {
        let wb = WhiteBalanceModel.linearGains(temperature: grade.temperature, tint: grade.tint)
        let exposureGain = exp2(grade.exposure)
        let gains = SIMD3<Float>(Float(wb.x * exposureGain),
                                 Float(wb.y * exposureGain),
                                 Float(wb.z * exposureGain))
        let invGamma = SIMD3<Float>(Float(1 / max(grade.gamma.red, 0.01)),
                                    Float(1 / max(grade.gamma.green, 0.01)),
                                    Float(1 / max(grade.gamma.blue, 0.01)))
        var domainMin = SIMD3<Float>(repeating: 0)
        var domainScale = SIMD3<Float>(repeating: 1)
        var lutSize: Float = 0
        if let lut {
            domainMin = lut.domainMin
            let span = lut.domainMax - lut.domainMin
            domainScale = SIMD3(1 / span.x, 1 / span.y, 1 / span.z)
            lutSize = Float(lut.size)
        }
        return GradeUniforms(
            linearGains: SIMD4(gains, Float(grade.contrast)),
            lift: SIMD4(Float(grade.lift.red), Float(grade.lift.green), Float(grade.lift.blue),
                        Float(grade.saturation)),
            invGamma: SIMD4(invGamma, 0),
            gain: SIMD4(Float(grade.gain.red), Float(grade.gain.green), Float(grade.gain.blue), lutMode),
            lutDomainMin: SIMD4(domainMin, lutSize),
            lutDomainScale: SIMD4(domainScale, 0),
            yuvTags: .zero, // set per-frame in the YUV branch (BGRA ignores it)
            extended: .zero) // sol wave-10 #3: set per-frame in `process`
    }

    // MARK: - LUT textures

    /// Returns (3D texture, 1D texture, lutMode) with dummies in unused slots.
    /// The GPU texture is cached by the LUT's identity token (`CubeLUT.id`),
    /// so switching LUTs uploads once, not per frame.
    private func lutTextures(for lut: CubeLUT?) throws -> (MTLTexture, MTLTexture, Float) {
        guard let lut else { return (dummyLUT3D, dummyLUT1D, 0) }
        let texture: MTLTexture
        if lut.id == cachedLUTID, let cached = cachedLUTTexture {
            texture = cached
        } else {
            texture = try buildLUTTexture(lut)
            cachedLUTID = lut.id
            cachedLUTTexture = texture
            logger.debug("uploaded \(lut.dimension == .threeD ? "3D" : "1D") LUT size \(lut.size)")
        }
        switch lut.dimension {
        case .threeD: return (texture, dummyLUT1D, 1)
        case .oneD: return (dummyLUT3D, texture, 2)
        }
    }

    private func buildLUTTexture(_ lut: CubeLUT) throws -> MTLTexture {
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba32Float
        desc.usage = .shaderRead
        desc.storageMode = .shared
        desc.width = lut.size
        switch lut.dimension {
        case .threeD:
            desc.textureType = .type3D
            desc.height = lut.size
            desc.depth = lut.size
        case .oneD:
            desc.textureType = .type1D
        }
        guard let texture = device.makeTexture(descriptor: desc) else {
            throw ColorError.lutTextureCreationFailed
        }
        // Expand RGB → RGBA once at upload (CPU-side, load-time only — this
        // is not the per-frame hot path).
        let entryCount = lut.data.count / 3
        var rgba = [Float](repeating: 1, count: entryCount * 4)
        for i in 0..<entryCount {
            rgba[i * 4 + 0] = lut.data[i * 3 + 0]
            rgba[i * 4 + 1] = lut.data[i * 3 + 1]
            rgba[i * 4 + 2] = lut.data[i * 3 + 2]
        }
        rgba.withUnsafeBytes { bytes in
            switch lut.dimension {
            case .threeD:
                texture.replace(region: MTLRegionMake3D(0, 0, 0, lut.size, lut.size, lut.size),
                                mipmapLevel: 0, slice: 0,
                                withBytes: bytes.baseAddress!,
                                bytesPerRow: lut.size * 16,
                                bytesPerImage: lut.size * lut.size * 16)
            case .oneD:
                texture.replace(region: MTLRegionMake1D(0, lut.size),
                                mipmapLevel: 0,
                                withBytes: bytes.baseAddress!,
                                bytesPerRow: 0)
            }
        }
        return texture
    }
}
