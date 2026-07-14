import CoreVideo
import Foundation
import Metal
import PrismCore

/// An input frame wrapped as Metal textures in its native format.
enum SourceTextures {
    /// Straight-RGB input sampled directly: 8-bit BGRA, 10-bit packed RGB (`l10r`,
    /// bgr10a2), or `64RGBAHalf` (rgba16Float). The kernels sample `.rgb` the same
    /// way for all three (Metal normalizes 10-bit unorm in hardware).
    case bgra(MTLTexture)
    /// Bi-planar YUV: 8-bit (`420v`/`420f`, r8/rg8) or 10-bit (`x420`/`xf20`,
    /// r16/rg16 — `tenBit`), decoded in-shader.
    case yuv(luma: MTLTexture, chroma: MTLTexture, fullRange: Bool, tenBit: Bool)
}

/// Shared zero-copy GPU plumbing for `MatteSmoother` / `BackgroundEffect` —
/// the same pattern as PrismColor's `MetalColorEngine`: one device + queue +
/// runtime-compiled library, `CVMetalTextureCache`s for inputs (shader read)
/// and outputs (shader write), and lazily-(re)built `PixelBufferPool`s for
/// BGRA8 frame outputs and OneComponent8 matte outputs.
///
/// Zero-copy contract (DESIGN.md §3.5): pixel buffers are wrapped, never
/// copied; base addresses are never locked here.
final class MetalVisionEngine {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary

    private let inputCache: CVMetalTextureCache
    private let outputCache: CVMetalTextureCache
    private var framePool: PixelBufferPool?
    private var mattePool: PixelBufferPool?

    init(device: MTLDevice, label: String) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw VisionError.commandCreationFailed }
        queue.label = "studio.prism.vision.\(label)"
        self.commandQueue = queue

        do {
            self.library = try device.makeLibrary(source: VisionShaders.source, options: MTLCompileOptions())
        } catch {
            throw VisionError.libraryCompilationFailed(underlying: error)
        }

        var inCache: CVMetalTextureCache?
        var status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &inCache)
        guard status == kCVReturnSuccess, let inCache else { throw VisionError.textureCacheCreationFailed(status) }
        self.inputCache = inCache

        let outAttrs: [CFString: Any] = [
            kCVMetalTextureUsage: NSNumber(value: MTLTextureUsage([.shaderWrite, .shaderRead]).rawValue),
        ]
        var outCache: CVMetalTextureCache?
        status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, outAttrs as CFDictionary, &outCache)
        guard status == kCVReturnSuccess, let outCache else { throw VisionError.textureCacheCreationFailed(status) }
        self.outputCache = outCache
    }

    func pipeline(_ functionName: String) throws -> MTLComputePipelineState {
        guard let fn = library.makeFunction(name: functionName) else {
            throw VisionError.functionNotFound(functionName)
        }
        do { return try device.makeComputePipelineState(function: fn) }
        catch { throw VisionError.pipelineCreationFailed(functionName, underlying: error) }
    }

    /// Mint an output frame buffer, rebuilding the pool if dimensions/format
    /// changed. `float` (wave-5b) selects the `64RGBAHalf` pool for a 10-bit input
    /// so the decoded frame is emitted at full precision (no 8-bit collapse);
    /// otherwise the original BGRA8 pool (8-bit path, unchanged).
    private var framePoolFloat = false
    func makeFrameBuffer(width: Int, height: Int, float: Bool = false) throws -> CVPixelBuffer {
        if framePool == nil || framePool!.width != width || framePool!.height != height || framePoolFloat != float {
            do {
                framePool = try PixelBufferPool(width: width, height: height,
                                                pixelFormat: float ? kCVPixelFormatType_64RGBAHalf
                                                                   : kCVPixelFormatType_32BGRA,
                                                minimumBufferCount: 4)
                framePoolFloat = float
            } catch { throw VisionError.outputBufferFailed(underlying: error) }
        }
        do { return try framePool!.makeBuffer() }
        catch { throw VisionError.outputBufferFailed(underlying: error) }
    }

    /// Mint a OneComponent8 matte buffer, rebuilding the pool if dimensions changed.
    func makeMatteBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        if mattePool == nil || mattePool!.width != width || mattePool!.height != height {
            do {
                mattePool = try PixelBufferPool(width: width, height: height,
                                                pixelFormat: kCVPixelFormatType_OneComponent8,
                                                minimumBufferCount: 4)
            } catch { throw VisionError.outputBufferFailed(underlying: error) }
        }
        do { return try mattePool!.makeBuffer() }
        catch { throw VisionError.outputBufferFailed(underlying: error) }
    }

    /// Wrap an output buffer as a writable texture in the given format.
    func wrapOutput(_ buffer: CVPixelBuffer, format: MTLPixelFormat,
                    retained: inout [CVMetalTexture]) throws -> MTLTexture {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, outputCache, buffer, nil, format,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw VisionError.outputTextureWrapFailed(status)
        }
        retained.append(cvTexture)
        return texture
    }

    /// Wrap an input frame in its native format. `float` is true (wave-5b) for a
    /// 10-bit input (`x420`/`xf20` biplanar, `l10r` packed, `64RGBAHalf`) — the
    /// caller then emits a `64RGBAHalf` frame so no precision is lost. 8-bit inputs
    /// (BGRA8 / `420v` / `420f`) are unchanged (`float == false`).
    func inputTextures(for frame: VideoFrame, retained: inout [CVMetalTexture]) throws
        -> (textures: SourceTextures, float: Bool) {
        switch frame.pixelFormat {
        case kCVPixelFormatType_32BGRA:
            guard let tex = wrapPlane(frame.pixelBuffer, format: .bgra8Unorm, plane: 0, retained: &retained) else {
                throw VisionError.inputTextureWrapFailed(frame.source)
            }
            return (.bgra(tex), false)
        case kCVPixelFormatType_ARGB2101010LEPacked: // 'l10r' — 10-bit packed RGB
            guard let tex = wrapPlane(frame.pixelBuffer, format: .bgr10a2Unorm, plane: 0, retained: &retained) else {
                throw VisionError.inputTextureWrapFailed(frame.source)
            }
            return (.bgra(tex), true)
        case kCVPixelFormatType_64RGBAHalf: // rgba16Float — a prior stage's high-precision output
            guard let tex = wrapPlane(frame.pixelBuffer, format: .rgba16Float, plane: 0, retained: &retained) else {
                throw VisionError.inputTextureWrapFailed(frame.source)
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
                throw VisionError.inputTextureWrapFailed(frame.source)
            }
            return (.yuv(luma: luma, chroma: chroma, fullRange: full, tenBit: tenBit), tenBit)
        default:
            throw VisionError.unsupportedPixelFormat(frame.pixelFormat)
        }
    }

    /// Wrap a OneComponent8 matte buffer as an `r8Unorm` sample texture.
    func matteTexture(for matte: SegmentationMatte, retained: inout [CVMetalTexture]) throws -> MTLTexture {
        let format = CVPixelBufferGetPixelFormatType(matte.pixelBuffer)
        guard format == kCVPixelFormatType_OneComponent8 else {
            throw VisionError.unsupportedMatteFormat(format)
        }
        guard let tex = wrapPlane(matte.pixelBuffer, format: .r8Unorm, plane: 0, retained: &retained) else {
            throw VisionError.matteTextureWrapFailed
        }
        return tex
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
        guard let cb = commandQueue.makeCommandBuffer() else { throw VisionError.commandCreationFailed }
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
