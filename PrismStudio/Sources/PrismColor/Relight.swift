import CoreVideo
import Foundation
import Metal
import PrismCore
import simd

/// Supplies a depth map for a frame. A Core ML Depth-Anything-class adapter
/// plugs in here later (run at reduced rate off the render path, like
/// segmentation — DESIGN.md §3.7); **no model ships with the engine**.
///
/// Contract: the returned buffer must be IOSurface-backed (mint via
/// `PixelBufferPool`) in a single-channel format — DepthFloat32/16,
/// DisparityFloat32/16, OneComponent32Float/16Half/8. Resolution may be
/// (and typically is) lower than the video frame; the kernel samples it
/// normalized. Values are relative depth increasing away from the camera —
/// scaling into scene units is `RelightProcessor.depthScale`'s job.
public protocol DepthProvider {
    func depth(for frame: VideoFrame) async -> CVPixelBuffer?
}

/// One virtual light. Coordinate model (documented; visual tuning comes
/// later with a real depth model):
/// - `position.x/y`: normalized screen coordinates, top-left origin, y down.
/// - `position.z`: along the depth axis — the scene occupies z ≥ 0 (depth ×
///   `depthScale`), the camera looks from −z, so **negative z is in front of
///   the scene**.
public struct VirtualLight: Sendable, Codable, Equatable {
    public var position: SIMD3<Float>
    /// Linear-light RGB color, usually ≤ 1 per channel.
    public var color: SIMD3<Float>
    /// Diffuse intensity multiplier.
    public var intensity: Float
    /// Blinn specular strength (0 = pure Lambertian).
    public var specular: Float
    /// Blinn shininess exponent (≥ 1).
    public var shininess: Float
    /// Distance falloff `1/(1 + k·d²)` in normalized-screen units.
    public var attenuation: Float

    public init(position: SIMD3<Float>,
                color: SIMD3<Float> = SIMD3(1, 1, 1),
                intensity: Float = 1,
                specular: Float = 0.1,
                shininess: Float = 32,
                attenuation: Float = 2) {
        self.position = position
        self.color = color
        self.intensity = intensity
        self.specular = specular
        self.shininess = shininess
        self.attenuation = attenuation
    }

    // MARK: - Presets (classic three-point starting points)

    /// Key: upper-left front, neutral-warm, dominant.
    public static func key(intensity: Float = 1.2) -> VirtualLight {
        VirtualLight(position: SIMD3(0.3, 0.25, -0.6),
                     color: SIMD3(1.0, 0.98, 0.94),
                     intensity: intensity, specular: 0.15, shininess: 32, attenuation: 1.5)
    }

    /// Fill: right front, soft and slightly warm, low specular.
    public static func fill(intensity: Float = 0.5) -> VirtualLight {
        VirtualLight(position: SIMD3(0.75, 0.4, -0.7),
                     color: SIMD3(1.0, 0.96, 0.9),
                     intensity: intensity, specular: 0.03, shininess: 8, attenuation: 1.0)
    }

    /// Rim: high, behind the subject (positive z), cool.
    /// v0 skeleton limitation (stated): Lambert from screen-space normals
    /// can't produce a true silhouette rim — this reads as a cool top/back
    /// accent until a real depth model + edge term lands.
    public static func rim(intensity: Float = 0.8) -> VirtualLight {
        VirtualLight(position: SIMD3(0.5, 0.1, 0.5),
                     color: SIMD3(0.85, 0.92, 1.0),
                     intensity: intensity, specular: 0.4, shininess: 64, attenuation: 2.0)
    }
}

/// Depth-driven virtual relighting (DaVinci "Relight"-class, skeleton).
///
/// Math (documented; correct-by-construction, tuned later):
/// 1. Depth → screen-space normals by central differences on the sampled
///    depth surface `z = depth(u,v)·depthScale`; normal = normalize((∂z/∂u,
///    ∂z/∂v, −1)), pointing toward the camera.
/// 2. Per pixel P = (u, v, z), for each light: Lambert `max(n·L̂, 0)` with
///    `1/(1+k·d²)` falloff, plus Blinn specular `(n·Ĥ)^shininess` with a
///    constant view vector (0,0,−1) (orthographic approximation).
/// 3. Applied in linear light (2.2-power transfer, same contract as
///    `ColorProcessor`): `out = base·(ambient + Σ diffuse) + Σ specular`.
///
/// Zero-copy in/out; ≤ 8 lights per pass.
public final class RelightProcessor {
    public static let maxLights = 8

    public let device: MTLDevice
    /// Ambient floor multiplying the source (1 = lights only ever *add*).
    public var ambient: Float = 0.35
    /// Scene-unit scale applied to raw depth values (normalized screen space
    /// is ~1 unit wide, so ~0.5–2 is a sane range for relative-depth maps).
    public var depthScale: Float = 1.0

    #if DEBUG
    /// Test-only seam (F13 / Class H): force the real command-buffer status-check
    /// in `process` to see a failed terminal state, so the throw fires
    /// deterministically without provoking a real (hang-risking) device fault.
    /// No effect in release.
    public var _test_forceExecutionFailure = false
    #endif

    private let engine: MetalColorEngine
    private let relightBGRA: MTLComputePipelineState
    private let relightYUV: MTLComputePipelineState
    private let logger = EngineLog.logger("relight")

    /// Mirrors MSL `RelightUniforms`.
    /// `yuvTags`: YUV only — x = matrix (0/1/2), y = chromaOffsetX (siting), z = tenBit,
    /// w = source transfer. `extended.x` (sol wave-10 #3) = nonlinear extended-range flag.
    private struct RelightUniforms {
        var params: SIMD4<Float>
        var yuvTags: SIMD4<Float>
        var extended: SIMD4<Float>
    }
    /// Mirrors MSL `GPULight` (48 bytes).
    private struct GPULight {
        var posIntensity: SIMD4<Float>
        var colorSpecular: SIMD4<Float>
        var attenShiny: SIMD4<Float>
    }

    public init(device: MTLDevice) throws {
        self.device = device
        self.engine = try MetalColorEngine(device: device, label: "relight")
        self.relightBGRA = try engine.pipeline("prism_relight_bgra")
        self.relightYUV = try engine.pipeline("prism_relight_yuv")
    }

    /// Relight one frame with `lights` (first `maxLights` used) against a
    /// depth map (any resolution, single-channel float/8-bit, IOSurface-backed).
    ///
    /// Returns a BGRA8 frame with PTS/duration/source passed through.
    public func process(frame: VideoFrame, depth: CVPixelBuffer, lights: [VirtualLight]) throws -> VideoFrame {
        var retained: [CVMetalTexture] = []
        let (input, isFloat) = try engine.inputTextures(for: frame, retained: &retained)

        let depthFormat = try Self.metalFormat(forDepth: CVPixelBufferGetPixelFormatType(depth))
        guard let depthTexture = engine.wrapPlane(depth, format: depthFormat, plane: 0,
                                                  retained: &retained) else {
            throw ColorError.inputTextureWrapFailed(frame.source)
        }

        let outputBuffer = try engine.makeOutputBuffer(width: frame.width, height: frame.height, float: isFloat)
        let outTexture = try engine.wrapOutput(outputBuffer,
                                               format: isFloat ? .rgba16Float : .bgra8Unorm,
                                               retained: &retained)

        if lights.count > Self.maxLights {
            logger.warning("\(lights.count) lights supplied; using first \(Self.maxLights)")
        }
        var gpuLights = lights.prefix(Self.maxLights).map { light in
            GPULight(posIntensity: SIMD4(light.position, light.intensity),
                     colorSpecular: SIMD4(light.color, light.specular),
                     attenShiny: SIMD4(light.attenuation, max(light.shininess, 1), 0, 0))
        }
        let lightCount = gpuLights.count
        if gpuLights.isEmpty { // keep the buffer argument valid; count is 0
            gpuLights.append(GPULight(posIntensity: .zero, colorSpecular: .zero, attenShiny: .zero))
        }
        var uniforms = RelightUniforms(params: SIMD4(ambient, depthScale, Float(lightCount), 0),
                                       yuvTags: .zero, extended: .zero)
        // sol #5 finding 2: the source transfer for the linear-light relight (decode →
        // shade → re-encode). Set AFTER the per-branch yuvTags assignment below so it
        // survives; `yuvTags.w` carries it for BOTH the BGRA and YUV kernels.
        let transferCode = Float(YCbCrTags.transferCode(for: frame.pixelBuffer))
        // sol wave-10 #3: nonlinear extended-range (extendedSRGB/709/P3) — carry >1
        // highlights through the shade instead of pre-clamping to 1.0 (mirror the
        // wave-9 compositor). Dedicated field, unaffected by the YUV yuvTags set.
        uniforms.extended.x = Float(YCbCrTags.extendedRangeCode(for: frame.pixelBuffer))

        let commandBuffer = try engine.makeCommandBuffer(label: "prism.color.relight")
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw ColorError.commandCreationFailed
        }
        encoder.label = "prism.color.relight.pass"
        let pipeline: MTLComputePipelineState
        switch input {
        case .bgra(let tex):
            pipeline = relightBGRA
            encoder.setTexture(tex, index: 0)
            encoder.setTexture(depthTexture, index: 1)
            encoder.setTexture(outTexture, index: 2)
        case .yuv(let luma, let chroma, let fullRange, let tenBit):
            pipeline = relightYUV
            uniforms.params.w = fullRange ? 1 : 0
            // sol #3 finding 1: decode in the source's tagged matrix + siting.
            // wave-5b: yuvTags.z = tenBit.
            uniforms.yuvTags = SIMD4(Float(YCbCrTags.matrixCode(for: frame.pixelBuffer)),
                                     YCbCrTags.chromaOffsetX(for: frame.pixelBuffer, lumaWidth: frame.width),
                                     tenBit ? 1 : 0, 0)
            encoder.setTexture(luma, index: 0)
            encoder.setTexture(chroma, index: 1)
            encoder.setTexture(depthTexture, index: 2)
            encoder.setTexture(outTexture, index: 3)
        }
        uniforms.yuvTags.w = transferCode   // sol #5 finding 2 (survives the YUV branch's yuvTags set)
        encoder.setBytes(&uniforms, length: MemoryLayout<RelightUniforms>.stride, index: 0)
        encoder.setBytes(&gpuLights, length: MemoryLayout<GPULight>.stride * gpuLights.count, index: 1)
        engine.dispatch(encoder, pipeline: pipeline, width: frame.width, height: frame.height)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(retained) {}
        // HIGH-4 / F13: a failed pass leaves undefined pixels — throw, never publish.
        var status = commandBuffer.status
        #if DEBUG
        if _test_forceExecutionFailure { status = .error }
        #endif
        if let err = ColorError.executionError(status: status, error: commandBuffer.error) { throw err }

        // sol #4 finding 1: relight shades the source's own primaries rgb, so the
        // output is still that colorspace — carry the colorimetry tags forward so a
        // Rec.2020 source is not double-rotated 709→2020 in the HDR compositor.
        YCbCrTags.propagateColorTags(from: frame.pixelBuffer, to: outputBuffer)
        return VideoFrame(pixelBuffer: outputBuffer, pts: frame.pts,
                          duration: frame.duration, source: frame.source)
    }

    static func metalFormat(forDepth format: OSType) throws -> MTLPixelFormat {
        switch format {
        case kCVPixelFormatType_DepthFloat32,
             kCVPixelFormatType_DisparityFloat32,
             kCVPixelFormatType_OneComponent32Float:
            return .r32Float
        case kCVPixelFormatType_DepthFloat16,
             kCVPixelFormatType_DisparityFloat16,
             kCVPixelFormatType_OneComponent16Half:
            return .r16Float
        case kCVPixelFormatType_OneComponent8:
            return .r8Unorm
        default:
            throw ColorError.unsupportedDepthFormat(format)
        }
    }
}
