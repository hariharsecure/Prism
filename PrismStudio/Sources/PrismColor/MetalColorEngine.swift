import CoreVideo
import Foundation
import Metal
import PrismCore

/// Errors shared by all PrismColor GPU components.
public enum ColorError: Error {
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
    /// Wrapping the output buffer as a writable Metal texture failed.
    case outputTextureWrapFailed(CVReturn)
    /// Minting the output CVPixelBuffer from the pool failed.
    case outputBufferFailed(underlying: Error)
    /// Metal command buffer / encoder creation failed.
    case commandCreationFailed
    /// A frame arrived in a pixel format the kernel set doesn't handle.
    case unsupportedPixelFormat(OSType)
    /// The depth buffer's pixel format has no single-channel Metal mapping.
    case unsupportedDepthFormat(OSType)
    /// LUT texture allocation failed.
    case lutTextureCreationFailed
    /// A committed command buffer finished in a non-`.completed` state (GPU OOM /
    /// device fault / timeout). The output holds undefined or stale pooled pixels
    /// and MUST NOT be published — the caller should fall back or drop the frame.
    /// Carries `commandBuffer.error` (HIGH-4 / F13, Class H).
    case gpuExecutionFailed(underlying: Error?)
}

extension ColorError {
    /// Map a finished command buffer's terminal state to the typed error the
    /// caller must throw (`nil` == completed OK, publish the frame). Extracted so
    /// every PrismColor GPU pass shares one status check (mirrors
    /// `CompositorError.executionError` / `VisionError.executionError`).
    static func executionError(status: MTLCommandBufferStatus,
                               error: Error?) -> ColorError? {
        status == .completed ? nil : .gpuExecutionFailed(underlying: error)
    }
}

/// An input frame wrapped as Metal textures in its native format.
enum SourceTextures {
    /// Straight-RGB input sampled directly: 8-bit BGRA, 10-bit packed RGB (`l10r`,
    /// bgr10a2), or `64RGBAHalf` (rgba16Float). Kernels sample `.rgb` identically.
    case bgra(MTLTexture)
    /// Bi-planar YUV: 8-bit (`420v`/`420f`) or 10-bit (`x420`/`xf20` — `tenBit`).
    case yuv(luma: MTLTexture, chroma: MTLTexture, fullRange: Bool, tenBit: Bool)
}

/// Shared zero-copy GPU plumbing for `ColorProcessor` / `FrameAnalyzer` /
/// `RelightProcessor`: one device + queue + runtime-compiled library, plus
/// `CVMetalTextureCache`s for inputs (shader read) and outputs (shader write)
/// and a lazily-(re)built `PixelBufferPool` for BGRA8 output frames.
///
/// Zero-copy contract (DESIGN.md §3.5): pixel buffers are wrapped, never
/// copied; base addresses are never locked here.
final class MetalColorEngine {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary

    private let inputCache: CVMetalTextureCache
    private let outputCache: CVMetalTextureCache
    private var outputPool: PixelBufferPool?

    init(device: MTLDevice, label: String) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw ColorError.commandCreationFailed }
        queue.label = "studio.prism.color.\(label)"
        self.commandQueue = queue

        // OPT#10: compile ColorShaders ONCE PER DEVICE via the shared cache — each
        // per-source colour engine reuses one immutable library instead of
        // recompiling identical source. Per-instance queue/caches/pool/PSOs unchanged.
        do {
            self.library = try MetalLibraryCache.library(device: device, source: ColorShaders.source)
        } catch {
            throw ColorError.libraryCompilationFailed(underlying: error)
        }

        var inCache: CVMetalTextureCache?
        var status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &inCache)
        guard status == kCVReturnSuccess, let inCache else { throw ColorError.textureCacheCreationFailed(status) }
        self.inputCache = inCache

        let outAttrs: [CFString: Any] = [
            kCVMetalTextureUsage: NSNumber(value: MTLTextureUsage([.shaderWrite, .shaderRead]).rawValue),
        ]
        var outCache: CVMetalTextureCache?
        status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, outAttrs as CFDictionary, &outCache)
        guard status == kCVReturnSuccess, let outCache else { throw ColorError.textureCacheCreationFailed(status) }
        self.outputCache = outCache
    }

    func pipeline(_ functionName: String) throws -> MTLComputePipelineState {
        guard let fn = library.makeFunction(name: functionName) else {
            throw ColorError.functionNotFound(functionName)
        }
        do { return try device.makeComputePipelineState(function: fn) }
        catch { throw ColorError.pipelineCreationFailed(functionName, underlying: error) }
    }

    private var outputPoolFloat = false
    /// Mint an output buffer, rebuilding the pool if dimensions/format changed
    /// (per-source filters follow their source's size). `float` (wave-5b) selects
    /// the `64RGBAHalf` pool for a 10-bit input so the graded/keyed frame keeps
    /// full precision (no 8-bit collapse); otherwise the original BGRA8 pool.
    func makeOutputBuffer(width: Int, height: Int, float: Bool = false) throws -> CVPixelBuffer {
        if outputPool == nil || outputPool!.width != width || outputPool!.height != height || outputPoolFloat != float {
            do {
                outputPool = try PixelBufferPool(width: width, height: height,
                                                 pixelFormat: float ? kCVPixelFormatType_64RGBAHalf
                                                                    : kCVPixelFormatType_32BGRA,
                                                 minimumBufferCount: 4)
                outputPoolFloat = float
            } catch { throw ColorError.outputBufferFailed(underlying: error) }
        }
        do { return try outputPool!.makeBuffer() }
        catch { throw ColorError.outputBufferFailed(underlying: error) }
    }

    /// Wrap the output buffer as a writable texture (`bgra8Unorm` by default;
    /// `rgba16Float` for the 10-bit path).
    func wrapOutput(_ buffer: CVPixelBuffer, format: MTLPixelFormat = .bgra8Unorm,
                    retained: inout [CVMetalTexture]) throws -> MTLTexture {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, outputCache, buffer, nil, format,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw ColorError.outputTextureWrapFailed(status)
        }
        retained.append(cvTexture)
        return texture
    }

    /// Wrap an input frame in its native format. `float` is true (wave-5b) for a
    /// 10-bit input (`x420`/`xf20` biplanar, `l10r` packed, `64RGBAHalf`) — the
    /// caller then writes a `64RGBAHalf` output. 8-bit inputs are unchanged.
    func inputTextures(for frame: VideoFrame, retained: inout [CVMetalTexture]) throws
        -> (textures: SourceTextures, float: Bool) {
        switch frame.pixelFormat {
        case kCVPixelFormatType_32BGRA:
            guard let tex = wrapPlane(frame.pixelBuffer, format: .bgra8Unorm, plane: 0, retained: &retained) else {
                throw ColorError.inputTextureWrapFailed(frame.source)
            }
            return (.bgra(tex), false)
        case kCVPixelFormatType_ARGB2101010LEPacked: // 'l10r' — 10-bit packed RGB
            guard let tex = wrapPlane(frame.pixelBuffer, format: .bgr10a2Unorm, plane: 0, retained: &retained) else {
                throw ColorError.inputTextureWrapFailed(frame.source)
            }
            return (.bgra(tex), true)
        case kCVPixelFormatType_64RGBAHalf: // rgba16Float — a prior stage's high-precision output
            guard let tex = wrapPlane(frame.pixelBuffer, format: .rgba16Float, plane: 0, retained: &retained) else {
                throw ColorError.inputTextureWrapFailed(frame.source)
            }
            return (.bgra(tex), true)
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, // '420v'
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,  // '420f'
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, // 'x420' (10-bit)
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:  // 'xf20' (10-bit)
            let tenBit = frame.pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                      || frame.pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            let full = frame.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    || frame.pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            let lumaFmt: MTLPixelFormat = tenBit ? .r16Unorm : .r8Unorm
            let chromaFmt: MTLPixelFormat = tenBit ? .rg16Unorm : .rg8Unorm
            guard let luma = wrapPlane(frame.pixelBuffer, format: lumaFmt, plane: 0, retained: &retained),
                  let chroma = wrapPlane(frame.pixelBuffer, format: chromaFmt, plane: 1, retained: &retained) else {
                throw ColorError.inputTextureWrapFailed(frame.source)
            }
            return (.yuv(luma: luma, chroma: chroma, fullRange: full, tenBit: tenBit), tenBit)
        default:
            throw ColorError.unsupportedPixelFormat(frame.pixelFormat)
        }
    }

    /// Zero-copy wrap of one plane of an IOSurface-backed buffer.
    func wrapPlane(_ buffer: CVPixelBuffer, format: MTLPixelFormat, plane: Int,
                   retained: inout [CVMetalTexture]) -> MTLTexture? {
        let planar = CVPixelBufferIsPlanar(buffer)
        let w = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
        let h = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, inputCache, buffer, nil, format, w, h, plane, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        retained.append(cvTexture)
        return texture
    }

    func makeCommandBuffer(label: String) throws -> MTLCommandBuffer {
        guard let cb = commandQueue.makeCommandBuffer() else { throw ColorError.commandCreationFailed }
        cb.label = label
        return cb
    }

    /// Dispatch a compute pass over a `width × height` grid.
    /// Apple-GPU-only codebase (DESIGN.md A1) → non-uniform threadgroups are available.
    func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState,
                  width: Int, height: Int) {
        encoder.setComputePipelineState(pipeline)
        let w = pipeline.threadExecutionWidth
        let h = max(pipeline.maxTotalThreadsPerThreadgroup / w, 1)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }
}
