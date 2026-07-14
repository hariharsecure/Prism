import CoreVideo
import Foundation
import Metal
import simd

/// Isolated Metal wrapper for the Phase-0 z-aware composite kernel. Owns its own
/// device/queue/library/texture-caches so it shares NOTHING with the production
/// `MetalCompositor`. Zero-copy: pixel buffers are wrapped as textures, never
/// copied.
///
/// Inputs (all in a common camera space):
///  - `plate`  rgba32Float premultiplied real-scene color plate;
///  - `charColor` rgba32Float premultiplied character color+alpha plate;
///  - `charDepth` r32Float character axial-Z (NaN = invalid/no coverage);
///  - `sceneDepth` r32Float scene axial-Z (NaN = invalid).
///
/// Output: a fresh rgba32Float buffer = character-over-plate with rgb AND alpha
/// scaled by per-pixel visibility.
public final class DepthCompositeKernel {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let readCache: CVMetalTextureCache
    private let writeCache: CVMetalTextureCache

    private struct Uniforms {
        var feather: Float
        var epsilon: Float
        var sceneInvalidFallback: Int32
        var charInvalidVisibility: Int32
    }

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw DepthSpikeError.metalUnavailable("no system default Metal device") }
        self.device = device
        guard let q = device.makeCommandQueue() else { throw DepthSpikeError.commandCreationFailed }
        q.label = "studio.prism.depthspike.composite"
        self.queue = q

        let library: MTLLibrary
        let compileOptions = MTLCompileOptions()
        // Fast-math OFF: the kernel relies on IEEE NaN/ordered-compare semantics
        // to detect invalid depth (`!(z > 0)`). Default fast-math assumes no
        // NaNs and would silently mis-handle invalid samples.
        compileOptions.fastMathEnabled = false
        do { library = try device.makeLibrary(source: DepthShaders.source, options: compileOptions) }
        catch { throw DepthSpikeError.libraryCompilationFailed(underlying: error) }
        guard let fn = library.makeFunction(name: "prism_depth_composite") else {
            throw DepthSpikeError.functionNotFound("prism_depth_composite")
        }
        do { self.pipeline = try device.makeComputePipelineState(function: fn) }
        catch { throw DepthSpikeError.pipelineCreationFailed("prism_depth_composite", underlying: error) }

        let readAttrs: [CFString: Any] = [
            kCVMetalTextureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
        ]
        var rc: CVMetalTextureCache?
        var status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, readAttrs as CFDictionary, &rc)
        guard status == kCVReturnSuccess, let rc else { throw DepthSpikeError.textureCacheCreationFailed(status) }
        self.readCache = rc

        let writeAttrs: [CFString: Any] = [
            kCVMetalTextureUsage: NSNumber(value: MTLTextureUsage([.shaderWrite, .shaderRead]).rawValue),
        ]
        var wc: CVMetalTextureCache?
        status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, writeAttrs as CFDictionary, &wc)
        guard status == kCVReturnSuccess, let wc else { throw DepthSpikeError.textureCacheCreationFailed(status) }
        self.writeCache = wc
    }

    private func wrap(_ buffer: CVPixelBuffer, format: MTLPixelFormat, write: Bool,
                      retained: inout [CVMetalTexture]) throws -> MTLTexture {
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        var cv: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, write ? writeCache : readCache, buffer, nil, format, w, h, 0, &cv)
        guard status == kCVReturnSuccess, let cv, let tex = CVMetalTextureGetTexture(cv) else {
            throw DepthSpikeError.textureWrapFailed("status=\(status) fmt=\(format.rawValue) \(w)x\(h)")
        }
        retained.append(cv)
        return tex
    }

    /// Run the composite. All four inputs must share one width/height. Returns a
    /// freshly minted rgba32Float buffer with the composited result.
    public func composite(plate: CVPixelBuffer,
                          charColor: CVPixelBuffer,
                          charDepth: CVPixelBuffer,
                          sceneDepth: CVPixelBuffer,
                          params: DepthCompositeParams) throws -> CVPixelBuffer {
        let w = CVPixelBufferGetWidth(plate), h = CVPixelBufferGetHeight(plate)
        for (name, b) in [("charColor", charColor), ("charDepth", charDepth), ("sceneDepth", sceneDepth)]
        where CVPixelBufferGetWidth(b) != w || CVPixelBufferGetHeight(b) != h {
            throw DepthSpikeError.dimensionMismatch("\(name) is \(CVPixelBufferGetWidth(b))x\(CVPixelBufferGetHeight(b)), expected \(w)x\(h)")
        }

        let output = try DepthPixelIO.makeColor(width: w, height: h) { _, _ in .zero }

        var retained: [CVMetalTexture] = []
        let plateTex = try wrap(plate, format: .rgba32Float, write: false, retained: &retained)
        let charTex  = try wrap(charColor, format: .rgba32Float, write: false, retained: &retained)
        let cDepthTex = try wrap(charDepth, format: .r32Float, write: false, retained: &retained)
        let sDepthTex = try wrap(sceneDepth, format: .r32Float, write: false, retained: &retained)
        let outTex   = try wrap(output, format: .rgba32Float, write: true, retained: &retained)

        var uniforms = Uniforms(feather: params.featherMeters,
                                epsilon: params.epsilonMeters,
                                sceneInvalidFallback: params.sceneInvalidFallback.rawValue,
                                charInvalidVisibility: params.charInvalidVisibility.rawValue)

        guard let cb = queue.makeCommandBuffer() else { throw DepthSpikeError.commandCreationFailed }
        cb.label = "prism.depthspike.composite"
        guard let enc = cb.makeComputeCommandEncoder() else { throw DepthSpikeError.commandCreationFailed }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(plateTex, index: 0)
        enc.setTexture(charTex, index: 1)
        enc.setTexture(cDepthTex, index: 2)
        enc.setTexture(sDepthTex, index: 3)
        enc.setTexture(outTex, index: 4)
        enc.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        let tew = pipeline.threadExecutionWidth
        let teh = max(pipeline.maxTotalThreadsPerThreadgroup / tew, 1)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: tew, height: teh, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        withExtendedLifetime(retained) {}
        guard cb.status == .completed else {
            throw DepthSpikeError.gpuExecutionFailed(underlying: cb.error)
        }
        return output
    }
}
