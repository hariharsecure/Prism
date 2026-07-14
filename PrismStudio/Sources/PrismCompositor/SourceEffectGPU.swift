import CoreVideo
import Foundation
import Metal
import os
import PrismCore

/// GPU offload of the per-source CPU VisualFX effect stages (DESIGN.md §3.5
/// "zero-copy or die"). The CPU renderers — `TileMask`, `StrobeEffect`,
/// `BeatPulseRenderer`, `TileRepeatRenderer` — run CoreGraphics per frame and
/// cap the owning source's fps (measured: TileMask 66.7 ms @4K / 17.2 ms
/// @1080p; Strobe / BeatPulse / VideoWall ~22 ms @4K each). The Metal
/// compositor has 25–40× headroom, so these single-source passes move the exact
/// same effect math onto the GPU as fullscreen fragment passes.
///
/// Contract (mirrors the CPU renderers): a source **BGRA** IOSurface frame in →
/// a processed **BGRA** IOSurface frame out, minted from a pooled
/// `PixelBufferPool` (no per-frame bitmap/pixel-buffer heap allocation — this
/// also removes the CPU path's per-frame `CGContext`/`CGImage` allocations).
/// Premultiplied-alpha correct: TileMask holes are TRUE alpha-0 (reveal the
/// layers beneath, never opaque black). Deterministic: the tile schedules are
/// SplitMix64 over (seed, tile index), byte-identical to `TileSchedule`.
///
/// Thread model: NOT thread-safe — like `MetalCompositor`, own one instance per
/// render/source thread (each holds its own pool + caches). Every pass is
/// synchronous (`waitUntilCompleted`), so the returned buffer is fully rendered
/// and safe to hand downstream.
///
/// Input format: **BGRA8** (fast path, wrapped zero-copy) OR **bi-planar YUV**
/// (`420v` video-range / `420f` full-range) — live camera/screen/link sources
/// emit YUV, so an effect stage decodes it FIRST. The YUV path wraps the Y plane
/// (`.r8Unorm`) + CbCr plane (`.rg8Unorm`), runs a YUV→BGRA normalize pre-pass
/// (honoring the tagged matrix/range/siting, byte-exact with the compositor's own
/// `prism_layer_fragment_yuv` layer decode), then runs the effect on that BGRA
/// texture. 8-bit output is BGRA8.
///
/// wave-5b — **10-bit** input (`x420`/`xf20` biplanar, `l10r` packed RGB) OR a
/// `64RGBAHalf` input runs the SAME effect fragment on an **`rgba16Float`**
/// intermediate/output (the YUV planes wrap `.r16Unorm`/`.rg16Unorm`; the shader's
/// `tenBit` flag scales for the 10-bit range) — NO 8-bit collapse — and emits a
/// `64RGBAHalf` frame the compositor folds in directly. An unsupported pixel
/// format throws `CompositorError.unsupportedInputFormat` so the caller can fall
/// back rather than corrupt.
public final class SourceEffectGPU {
    public let device: MTLDevice
    public let width: Int
    public let height: Int

    /// Strobe envelope steepness (mirrors `StrobeEffect.decay`).
    public let strobeDecay: Double
    /// Strobe peak-flash clamp (mirrors `StrobeEffect.maxIntensity`).
    public let strobeMaxIntensity: Double

    private let commandQueue: MTLCommandQueue
    private let tileMaskPipeline: MTLRenderPipelineState
    private let strobePipeline: MTLRenderPipelineState
    private let beatPulsePipeline: MTLRenderPipelineState
    private let videoWallPipeline: MTLRenderPipelineState
    /// YUV→BGRA normalize pre-pass (decodes 420v/420f before an effect runs).
    private let yuvNormalizePipeline: MTLRenderPipelineState
    private let inputTextureCache: CVMetalTextureCache
    private let outputTextureCache: CVMetalTextureCache
    private let outputPool: PixelBufferPool
    private let logger = EngineLog.logger("compositor")

    /// wave-5b: kept so the `rgba16Float` pipeline variants (for 10-bit input) can
    /// be built lazily — the common 8-bit path never touches them.
    private let library: MTLLibrary

    #if DEBUG
    /// OPT#10 test seam: the shared, cached library this instance uses — a test
    /// asserts two instances on one device hold the SAME object.
    var _test_library: MTLLibrary { library }
    #endif
    /// wave-5b: lazily-built `rgba16Float` variants of the effect + normalize
    /// fragments, keyed by fragment name. A 10-bit source is decoded + effected in
    /// half-float (no 8-bit collapse) and emitted as a `64RGBAHalf` frame the
    /// compositor folds in directly.
    private var floatPipelineCache: [String: MTLRenderPipelineState] = [:]
    /// wave-5b: lazily-(re)built `64RGBAHalf` output pool for the 10-bit path.
    private var outputFloatPool: PixelBufferPool?

    #if DEBUG
    /// Test-only seam (F13 / Class H): when true, `process` observes a **failed**
    /// command-buffer terminal status regardless of the real one, so the real
    /// status-check → throw fires deterministically. A genuine device fault cannot
    /// be provoked reliably in a unit test without risking a process-killing GPU
    /// hang, so the failure is injected at the real throw site. No effect in release.
    public var _test_forceExecutionFailure = false
    #endif

    // MARK: - Uniform mirrors (byte-exact with the MSL structs)

    /// Mirror of MSL `FXUniforms` (48 bytes) — reused for the TileMask pass.
    private struct FXUniforms {
        var kind: UInt32
        var progress: Float
        var rawProgress: Float
        var softness: Float
        var rows: UInt32
        var cols: UInt32
        var direction: UInt32
        var seedLo: UInt32
        var seedHi: UInt32
        var width: UInt32
        var height: UInt32
        var pad0: UInt32 = 0
    }
    /// Mirror of MSL `SrcStrobeUniforms` (32 bytes).
    private struct StrobeUniforms {
        var color: SIMD4<Float>
        var amount: Float
        var pad0: Float = 0, pad1: Float = 0, pad2: Float = 0
    }
    /// Mirror of MSL `SrcPulseUniforms` (32 bytes).
    private struct PulseUniforms {
        var scale: Float
        var dx: Float
        var dy: Float
        var pad0: Float = 0
        var background: SIMD4<Float>
    }
    /// Mirror of MSL `SrcWallUniforms` (16 bytes).
    private struct WallUniforms {
        var rows: UInt32
        var cols: UInt32
        var mirror: UInt32
        var pad0: UInt32 = 0
    }
    /// Mirror of MSL `SrcYUVUniforms` (16 bytes) — YUV normalize pre-pass.
    private struct YUVUniforms {
        var fullRange: UInt32
        var yuvMatrix: UInt32 = 0        // N5: 0 BT.709 · 1 BT.601 · 2 BT.2020
        var chromaOffsetX: Float = 0     // N5: horizontal chroma siting offset
        var tenBit: UInt32 = 0           // wave-5b: 1 = 10-bit biplanar (x420/xf20)
    }

    // MARK: - Init

    /// - Parameters:
    ///   - device: the shared engine Metal device.
    ///   - width/height: the source/output frame size in pixels.
    ///   - strobeDecay/strobeMaxIntensity: match a `StrobeEffect` you compare
    ///     against (defaults mirror `StrobeEffect`).
    public init(device: MTLDevice, width: Int, height: Int,
                strobeDecay: Double = 6, strobeMaxIntensity: Double = 1) throws {
        precondition(width > 0 && height > 0)
        self.device = device
        self.width = width
        self.height = height
        self.strobeDecay = max(strobeDecay, 0.0001)
        self.strobeMaxIntensity = min(max(strobeMaxIntensity, 0), 1)

        guard let queue = device.makeCommandQueue() else { throw CompositorError.commandCreationFailed }
        queue.label = "studio.prism.srcfx"
        self.commandQueue = queue

        // OPT#10: compile the embedded MSL ONCE PER DEVICE via the shared cache. A
        // per-source FX instance no longer recompiles the identical CompositorShaders
        // source — it reuses the same immutable library the compositor built. The
        // per-instance PSOs / queues / caches / pools below are unchanged.
        let library: MTLLibrary
        do {
            library = try MetalLibraryCache.library(device: device, source: CompositorShaders.source)
        } catch {
            throw CompositorError.libraryCompilationFailed(underlying: error)
        }
        self.library = library
        func function(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else { throw CompositorError.functionNotFound(name) }
            return f
        }
        let blitVertex = try function("prism_blit_vertex")

        // Blending DISABLED — each single-source fragment writes the final
        // premultiplied pixel directly (a tile hole's alpha-0 stays alpha-0).
        func makePipeline(fragment: String, label: String) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = label
            desc.vertexFunction = blitVertex
            desc.fragmentFunction = try function(fragment)
            desc.colorAttachments[0]!.pixelFormat = .bgra8Unorm
            do { return try device.makeRenderPipelineState(descriptor: desc) }
            catch { throw CompositorError.pipelineCreationFailed(underlying: error) }
        }
        self.tileMaskPipeline = try makePipeline(fragment: "prism_srcfx_tilemask", label: "prism.srcfx.tilemask")
        self.strobePipeline = try makePipeline(fragment: "prism_srcfx_strobe", label: "prism.srcfx.strobe")
        self.beatPulsePipeline = try makePipeline(fragment: "prism_srcfx_beatpulse", label: "prism.srcfx.beatpulse")
        self.videoWallPipeline = try makePipeline(fragment: "prism_srcfx_videowall", label: "prism.srcfx.videowall")
        self.yuvNormalizePipeline = try makePipeline(fragment: "prism_srcfx_yuv_to_bgra", label: "prism.srcfx.yuv")

        var inCache: CVMetalTextureCache?
        var status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &inCache)
        guard status == kCVReturnSuccess, let inCache else { throw CompositorError.textureCacheCreationFailed(status) }
        self.inputTextureCache = inCache

        let outAttrs: [CFString: Any] = [
            kCVMetalTextureUsage: NSNumber(value: MTLTextureUsage([.renderTarget, .shaderRead]).rawValue),
        ]
        var outCache: CVMetalTextureCache?
        status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, outAttrs as CFDictionary, &outCache)
        guard status == kCVReturnSuccess, let outCache else { throw CompositorError.textureCacheCreationFailed(status) }
        self.outputTextureCache = outCache

        self.outputPool = try PixelBufferPool(width: width, height: height,
                                              pixelFormat: kCVPixelFormatType_32BGRA,
                                              minimumBufferCount: 6)
    }

    // MARK: - Public effect passes

    /// **TileMask** layer effect — punch the animated grid of holes into `source`
    /// and return the holed premultiplied BGRA frame. Feed the result to a
    /// `premultipliedAlpha: true` layer so the compositor reveals the layers
    /// beneath. Matches `TileMask.apply` / `punchTileHoles` exactly.
    ///
    /// - Parameters:
    ///   - source: the layer's current BGRA IOSurface frame.
    ///   - rows/cols: grid size (clamped safe via `TileSchedule.clampGrid`).
    ///   - mode: which reveal pattern (see `TileMaskMode`).
    ///   - phase: one-shot progress 0→1, or a LOOPING phase for `tileFlicker`.
    ///   - softness: hole-edge feather, clamped 0…1.
    public func tileMask(source: CVPixelBuffer, rows: Int, cols: Int,
                         mode: TileMaskMode, phase: Double, softness: Double) throws -> CVPixelBuffer {
        var u = tileMaskUniforms(rows: rows, cols: cols, mode: mode, phase: phase, softness: softness)
        return try process(source: source, pipeline: tileMaskPipeline, fragment: "prism_srcfx_tilemask") { encoder in
            encoder.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
        }
    }

    /// Build the TileMask `FXUniforms` (shared by `tileMask` and `processChain` so
    /// the batched chain encodes byte-identical uniforms to the single-pass path).
    private func tileMaskUniforms(rows: Int, cols: Int, mode: TileMaskMode,
                                  phase: Double, softness: Double) -> FXUniforms {
        let (rows, cols) = TileSchedule.clampGrid(rows: rows, cols: cols)
        // Map the mode → shader kind + which phase field it rides (one-shot kinds
        // use `progress` clamped 0…1; the continuous flicker rides raw `phase`).
        let kind: UInt32
        var seed: UInt64 = 0
        var direction: UInt32 = 0
        var progress = Float(min(max(phase, 0), 1))
        var rawProgress = Float(phase)
        switch mode {
        case .blockDissolve(let s): kind = 5; seed = s
        case .gridWipe(let dir):    kind = 6; direction = Self.directionCode(dir)
        case .checkerboard:         kind = 7
        case .tileReveal:           kind = 8
        case .tileFlicker(let s):   kind = 9; seed = s
        }
        // For flicker the shader reads rawProgress; for one-shot kinds it reads
        // progress. Keep both populated (harmless for the unused field).
        if kind == 9 { progress = Float(phase) } else { rawProgress = progress }

        return FXUniforms(kind: kind, progress: progress, rawProgress: rawProgress,
                          softness: Float(min(max(softness, 0), 1)),
                          rows: UInt32(rows), cols: UInt32(cols), direction: direction,
                          seedLo: UInt32(truncatingIfNeeded: seed),
                          seedHi: UInt32(truncatingIfNeeded: seed >> 32),
                          width: UInt32(width), height: UInt32(height))
    }

    /// **Strobe** — flash `source` toward `color` by a phase-driven exponential
    /// envelope (`phase 0` = brightest). Matches `StrobeEffect.apply`; the
    /// envelope is evaluated on the CPU (a pure scalar) and applied on the GPU.
    /// PRESERVES source alpha (Class C): a transparent/keyed texel stays
    /// transparent — the flash modulates colour only, scaled by source alpha — so
    /// a keyed source's cutout background never flashes over the layers beneath.
    ///
    /// - Parameters:
    ///   - phase: beat phase 0→1 (0 = downbeat), wrapped into 0…1.
    ///   - intensity: peak flash strength (clamped 0…`strobeMaxIntensity`).
    ///   - color: flash target color (white by default); its `.a` scales the flash.
    public func strobe(source: CVPixelBuffer, phase: Double, intensity: Double,
                       color: RGBA = .white) throws -> CVPixelBuffer {
        var u = strobeUniforms(source: source, phase: phase, intensity: intensity, color: color)
        return try process(source: source, pipeline: strobePipeline, fragment: "prism_srcfx_strobe") { encoder in
            encoder.setFragmentBytes(&u, length: MemoryLayout<StrobeUniforms>.stride, index: 0)
        }
    }

    /// Build the Strobe `StrobeUniforms` (shared by `strobe` and `processChain`).
    /// The sRGB flash colour is converted INTO the ORIGINAL `source`'s coded
    /// colorspace — see the note below. In the batched chain every step converts
    /// against the ORIGINAL source (identical to the single-pass path, where each
    /// stage sees the prior stage's output carrying the SAME propagated tags).
    private func strobeUniforms(source: CVPixelBuffer, phase: Double, intensity: Double,
                                color: RGBA) -> StrobeUniforms {
        let amount = strobeFlashAmount(phase: phase, intensity: intensity) * min(max(color.a, 0), 1)
        // sol #5 finding 4: convert the sRGB flash colour INTO the source's coded
        // colorspace (primaries + transfer) BEFORE it is mixed into the source-coded
        // pixels, so the mixed output is homogeneous and the SOURCE tags this pass
        // propagates are truthful — a full-red strobe on an HLG/Rec.2020 source ends as
        // the correctly-converted 2020/HLG red, not a false pure-2020 red. SDR sources
        // return the colour unchanged (byte-identical).
        let flash = YCbCrTags.srgbColor(SIMD3(Float(color.r), Float(color.g), Float(color.b)),
                                        inSpaceOf: source)
        return StrobeUniforms(
            color: SIMD4(flash.x, flash.y, flash.z, 1),
            amount: Float(amount))
    }

    /// The strobe flash alpha (0…1) at a beat `phase` and `intensity` — the exact
    /// pure envelope of `StrobeEffect.flashAmount` (exposed so a caller can drive
    /// or verify the flash without rendering).
    public func strobeFlashAmount(phase: Double, intensity: Double) -> Double {
        let i = min(max(intensity, 0), strobeMaxIntensity)
        let p = min(max(phase - floor(phase), 0), 1)
        let k = strobeDecay
        let e0 = exp(-k)
        let env = (exp(-k * p) - e0) / (1 - e0)
        return min(max(i * env, 0), 1)
    }

    /// **BeatPulse** — render `source` under a `BeatPulseTransform` (uniform scale
    /// about centre + shake offset) over `background`. Matches
    /// `BeatPulseRenderer.render`. Compute `transform` with `BeatPulse.pulse(...)`
    /// (the pure transform math) and pass it here.
    ///
    /// `background` defaults to **`.clear`** so the pass PRESERVES the source's
    /// alpha: a transparent source texel, and any output texel the scaled/shaken
    /// source does not cover, stays premultiplied-transparent `(0,0,0,0)` — NOT
    /// opaque black. Passing an opaque `background` (e.g. `.black`) is the opt-in
    /// "flatten onto a colour" behaviour; the default no longer turns a
    /// transparent/keyed/cutout source into an opaque black box over lower layers.
    public func beatPulse(source: CVPixelBuffer, transform t: BeatPulseTransform,
                          background: RGBA = .clear) throws -> CVPixelBuffer {
        var u = beatPulseUniforms(source: source, transform: t, background: background)
        return try process(source: source, pipeline: beatPulsePipeline, fragment: "prism_srcfx_beatpulse") { encoder in
            encoder.setFragmentBytes(&u, length: MemoryLayout<PulseUniforms>.stride, index: 0)
        }
    }

    /// Build the BeatPulse `PulseUniforms` (shared by `beatPulse` and `processChain`).
    private func beatPulseUniforms(source: CVPixelBuffer, transform t: BeatPulseTransform,
                                   background: RGBA) -> PulseUniforms {
        // sol #5 finding 4: convert the sRGB pulse background INTO the source's coded
        // colorspace before it is source-over-mixed, so the propagated SOURCE tags are
        // truthful (a coloured pulse background on an HLG/2020 source is correctly
        // converted, not falsely tagged). SDR / `.clear` return unchanged.
        let bg = YCbCrTags.srgbColor(SIMD3(Float(background.r), Float(background.g), Float(background.b)),
                                     inSpaceOf: source)
        return PulseUniforms(
            scale: Float(t.scale), dx: Float(t.dx), dy: Float(t.dy),
            background: SIMD4(bg.x, bg.y, bg.z, Float(background.a)))
    }

    /// **VideoWall** — draw `source` repeated into an `rows × cols` grid; `mirror`
    /// flips odd-parity cells for a kaleidoscope. Matches `TileRepeatRenderer.render`.
    public func videoWall(source: CVPixelBuffer, rows: Int, cols: Int, mirror: Bool) throws -> CVPixelBuffer {
        let rows = max(1, rows), cols = max(1, cols)
        var u = WallUniforms(rows: UInt32(rows), cols: UInt32(cols), mirror: mirror ? 1 : 0)
        return try process(source: source, pipeline: videoWallPipeline, fragment: "prism_srcfx_videowall") { encoder in
            encoder.setFragmentBytes(&u, length: MemoryLayout<WallUniforms>.stride, index: 0)
        }
    }

    // MARK: - Batched render-time chain (sol OPTIMIZATION_PLAN #5)

    /// One ordered step in a batched source-FX chain. The cases mirror the
    /// render-thread animated effects and their order is the SAME as today's
    /// per-effect chain (pulse → strobe → tile). Each carries exactly the params
    /// the single-pass method takes, so the batched encode is byte-identical.
    public enum ChainStep: Sendable {
        case beatPulse(transform: BeatPulseTransform, background: RGBA)
        case strobe(phase: Double, intensity: Double, color: RGBA)
        case tileMask(rows: Int, cols: Int, mode: TileMaskMode, phase: Double, softness: Double)
    }

    /// A resolved step: its 8-bit pipeline, its fragment name (for the lazy
    /// `rgba16Float` variant on the 10-bit path), and a closure that binds its
    /// uniforms onto an encoder.
    private struct ResolvedStep {
        let pipeline: MTLRenderPipelineState
        let fragment: String
        let bind: (MTLRenderCommandEncoder) -> Void
    }

    private func resolve(_ step: ChainStep, source: CVPixelBuffer) -> ResolvedStep {
        switch step {
        case .beatPulse(let t, let bg):
            let u = beatPulseUniforms(source: source, transform: t, background: bg)
            return ResolvedStep(pipeline: beatPulsePipeline, fragment: "prism_srcfx_beatpulse") { enc in
                var uu = u; enc.setFragmentBytes(&uu, length: MemoryLayout<PulseUniforms>.stride, index: 0)
            }
        case .strobe(let phase, let intensity, let color):
            let u = strobeUniforms(source: source, phase: phase, intensity: intensity, color: color)
            return ResolvedStep(pipeline: strobePipeline, fragment: "prism_srcfx_strobe") { enc in
                var uu = u; enc.setFragmentBytes(&uu, length: MemoryLayout<StrobeUniforms>.stride, index: 0)
            }
        case .tileMask(let rows, let cols, let mode, let phase, let softness):
            let u = tileMaskUniforms(rows: rows, cols: cols, mode: mode, phase: phase, softness: softness)
            return ResolvedStep(pipeline: tileMaskPipeline, fragment: "prism_srcfx_tilemask") { enc in
                var uu = u; enc.setFragmentBytes(&uu, length: MemoryLayout<FXUniforms>.stride, index: 0)
            }
        }
    }

    /// Two PRIVATE (non-IOSurface, internal) ping-pong working textures, lazily
    /// built and reused across ticks. Storage is `.private` so the chain's
    /// intermediates never touch an externally-pooled IOSurface — the whole point
    /// of the batch. Rebuilt if the working pixel format changes (8-bit ⇄ 10-bit).
    private var pingPongTextures: [MTLTexture] = []
    private var pingPongFormat: MTLPixelFormat?

    private func pingPong(_ index: Int, format: MTLPixelFormat) throws -> MTLTexture {
        if pingPongFormat != format || pingPongTextures.count < 2 {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            guard let a = device.makeTexture(descriptor: desc),
                  let b = device.makeTexture(descriptor: desc) else {
                throw CompositorError.outputTextureWrapFailed(kCVReturnError)
            }
            a.label = "prism.srcfx.chain.pp0"
            b.label = "prism.srcfx.chain.pp1"
            pingPongTextures = [a, b]
            pingPongFormat = format
        }
        return pingPongTextures[index]
    }

    /// **Batched source-FX chain** — encode the ORDERED `steps` (same order as the
    /// per-effect chain: pulse → strobe → tile) into ONE command buffer with ONE
    /// `waitUntilCompleted`, using two PRIVATE ping-pong textures for the
    /// intermediates and exposing ONLY the final pooled IOSurface (same
    /// format/tags/premultiplied-alpha as the per-effect path).
    ///
    /// Behaviour-preserving vs calling the single-pass methods in sequence:
    /// - the YUV→working normalize runs ONCE (the first step reads the decoded
    ///   texture; subsequent steps read a prior step's straight-RGB output, exactly
    ///   as the per-effect path skips re-normalize on its `64RGBAHalf`/BGRA output);
    /// - each intermediate is the SAME working pixel format (`bgra8Unorm` 8-bit /
    ///   `rgba16Float` 10-bit) as the per-effect path's pooled intermediate, so the
    ///   per-stage store→sample rounding is identical;
    /// - every colour conversion resolves against the ORIGINAL `source` tags, which
    ///   the per-effect path propagates stage-to-stage — so the uniforms match;
    /// - the source colorimetry tags are propagated onto the final output;
    /// - the command-buffer terminal status is checked and a failure throws (H).
    ///
    /// `steps` must be non-empty (the caller short-circuits an empty chain to the
    /// untouched raw frame). Render-thread only (same single-threaded contract as
    /// every other pass on this instance).
    public func processChain(source: CVPixelBuffer, steps: [ChainStep]) throws -> CVPixelBuffer {
        precondition(!steps.isEmpty, "processChain requires at least one step")

        let format = CVPixelBufferGetPixelFormatType(source)
        let isFloat: Bool
        switch format {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_ARGB2101010LEPacked,
             kCVPixelFormatType_64RGBAHalf:
            isFloat = true
        default:
            isFloat = false
        }
        let workingFormat: MTLPixelFormat = isFloat ? .rgba16Float : .bgra8Unorm

        let target = try makeTarget(float: isFloat)   // final pooled IOSurface output
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw CompositorError.commandCreationFailed
        }
        commandBuffer.label = "prism.srcfx.chain"

        // Keep every CV-wrapped input/output texture alive until the GPU finishes.
        // The private ping-pong textures are retained by `self`, so they need no
        // per-call retention.
        var retained: [CVMetalTexture] = [target.cvTexture]

        // Resolve the straight-RGB input to the FIRST step. BGRA / packed-RGB / half
        // wrap zero-copy; YUV (8- or 10-bit) decodes ONCE into a private ping-pong
        // texture via the normalize pre-pass (matching `process`).
        let effectInput: MTLTexture
        switch format {
        case kCVPixelFormatType_32BGRA:
            guard let (tex, cv) = wrapInput(source, format: .bgra8Unorm, plane: 0) else {
                throw CompositorError.outputTextureWrapFailed(kCVReturnError)
            }
            retained.append(cv)
            effectInput = tex

        case kCVPixelFormatType_ARGB2101010LEPacked:
            guard let (tex, cv) = wrapInput(source, format: .bgr10a2Unorm, plane: 0) else {
                throw CompositorError.outputTextureWrapFailed(kCVReturnError)
            }
            retained.append(cv)
            effectInput = tex

        case kCVPixelFormatType_64RGBAHalf:
            guard let (tex, cv) = wrapInput(source, format: .rgba16Float, plane: 0) else {
                throw CompositorError.outputTextureWrapFailed(kCVReturnError)
            }
            retained.append(cv)
            effectInput = tex

        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                      || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                         || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            // Normalize into ping-pong slot 0 (the decoded working input). The first
            // effect reads it; a later effect may reuse it as a ping-pong dest.
            let normTarget = try pingPong(0, format: workingFormat)
            let lumaFmt: MTLPixelFormat = tenBit ? .r16Unorm : .r8Unorm
            let chromaFmt: MTLPixelFormat = tenBit ? .rg16Unorm : .rg8Unorm
            guard let (luma, cvL) = wrapInput(source, format: lumaFmt, plane: 0),
                  let (chroma, cvC) = wrapInput(source, format: chromaFmt, plane: 1) else {
                throw CompositorError.outputTextureWrapFailed(kCVReturnError)
            }
            retained.append(contentsOf: [cvL, cvC])
            var yu = YUVUniforms(
                fullRange: fullRange ? 1 : 0,
                yuvMatrix: YCbCrTags.matrixCode(for: source),
                chromaOffsetX: YCbCrTags.chromaOffsetX(for: source, lumaWidth: CVPixelBufferGetWidth(source)),
                tenBit: tenBit ? 1 : 0)

            let normDesc = MTLRenderPassDescriptor()
            normDesc.colorAttachments[0].texture = normTarget
            normDesc.colorAttachments[0].loadAction = .dontCare
            normDesc.colorAttachments[0].storeAction = .store
            guard let normEnc = commandBuffer.makeRenderCommandEncoder(descriptor: normDesc) else {
                throw CompositorError.commandCreationFailed
            }
            normEnc.label = "prism.srcfx.chain.yuv"
            normEnc.setRenderPipelineState(isFloat ? try floatPipeline("prism_srcfx_yuv_to_bgra")
                                                   : yuvNormalizePipeline)
            normEnc.setFragmentTexture(luma, index: 0)
            normEnc.setFragmentTexture(chroma, index: 1)
            normEnc.setFragmentBytes(&yu, length: MemoryLayout<YUVUniforms>.stride, index: 0)
            normEnc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            normEnc.endEncoding()
            effectInput = normTarget

        default:
            throw CompositorError.unsupportedInputFormat(format)
        }

        // Encode each effect. Intermediate destinations alternate between the two
        // private ping-pong textures (never writing the texture it reads); the LAST
        // step writes the pooled output. So the exposed IOSurface is only ever the
        // final result — never an intermediate.
        let resolved = steps.map { resolve($0, source: source) }
        var currentInput = effectInput
        for (i, step) in resolved.enumerated() {
            let isLast = i == resolved.count - 1
            let dest: MTLTexture
            if isLast {
                dest = target.texture
            } else {
                let ppA = try pingPong(0, format: workingFormat)
                let ppB = try pingPong(1, format: workingFormat)
                dest = (currentInput === ppA) ? ppB : ppA
            }
            let passDesc = MTLRenderPassDescriptor()
            passDesc.colorAttachments[0].texture = dest
            passDesc.colorAttachments[0].loadAction = .dontCare   // fully overwritten
            passDesc.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
                throw CompositorError.commandCreationFailed
            }
            encoder.label = "prism.srcfx.chain.fx"
            encoder.setRenderPipelineState(isFloat ? try floatPipeline(step.fragment) : step.pipeline)
            encoder.setFragmentTexture(currentInput, index: 0)
            step.bind(encoder)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            currentInput = dest
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(retained) {}
        // One terminal-status check for the whole chain (H): on GPU OOM / device
        // fault / timeout the pooled target holds undefined pixels, so THROW and let
        // the caller fall back rather than publish a corrupt frame.
        var status = commandBuffer.status
        #if DEBUG
        if _test_forceExecutionFailure { status = .error }
        #endif
        if let err = CompositorError.executionError(status: status,
                                                    error: commandBuffer.error) {
            throw err
        }
        // Carry the source's colorimetry tags onto the pooled output (identical to
        // the per-effect path's final stage).
        YCbCrTags.propagateColorTags(from: source, to: target.buffer)
        return target.buffer
    }

    // MARK: - Shared plumbing

    /// `gridWipe` sweep direction → the shader's `direction` code (matches
    /// `TransitionKind.directionCode`).
    private static func directionCode(_ d: FXDirection) -> UInt32 {
        switch d {
        case .left:  return 0
        case .right: return 1
        case .up:    return 2
        case .down:  return 3
        }
    }

    /// Mint a pooled output buffer, wrap `source` as an input texture, encode one
    /// fullscreen fragment pass (`setUniforms` binds the effect's constants), run
    /// it synchronously, and return the finished IOSurface frame.
    ///
    /// wave-5b: an 8-bit source (BGRA8 / 420v / 420f) runs the original path
    /// byte-for-byte (BGRA8 output). A 10-bit source (`x420`/`xf20` biplanar,
    /// `l10r` packed) or a `64RGBAHalf` source runs the SAME effect fragment on an
    /// `rgba16Float` intermediate/output — NO 8-bit collapse — and emits a
    /// `64RGBAHalf` frame the compositor folds in directly.
    private func process(source: CVPixelBuffer, pipeline: MTLRenderPipelineState, fragment: String,
                         _ setUniforms: (MTLRenderCommandEncoder) -> Void) throws -> CVPixelBuffer {
        let format = CVPixelBufferGetPixelFormatType(source)
        let isFloat: Bool
        switch format {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_ARGB2101010LEPacked,
             kCVPixelFormatType_64RGBAHalf:
            isFloat = true
        default:
            isFloat = false
        }

        let target = try makeTarget(float: isFloat)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw CompositorError.commandCreationFailed
        }
        commandBuffer.label = "prism.srcfx.pass"

        // Keep every CV-wrapped texture (and any intermediate buffer) alive
        // until the GPU work finishes.
        var retained: [CVMetalTexture] = [target.cvTexture]
        var intermediateBuffer: CVPixelBuffer?

        // Resolve the effect's straight-RGB input texture. BGRA / packed-RGB /
        // half sources wrap zero-copy; YUV (8- or 10-bit) sources are decoded into
        // a pooled intermediate by a normalize pre-pass first (rgba16Float for the
        // 10-bit path — no precision lost), so the effect always sees straight RGB.
        let effectInput: MTLTexture
        switch format {
        case kCVPixelFormatType_32BGRA:
            guard let (tex, cv) = wrapInput(source, format: .bgra8Unorm, plane: 0) else {
                throw CompositorError.outputTextureWrapFailed(kCVReturnError)
            }
            retained.append(cv)
            effectInput = tex

        case kCVPixelFormatType_ARGB2101010LEPacked: // 'l10r' — 10-bit packed RGB, already straight RGB
            guard let (tex, cv) = wrapInput(source, format: .bgr10a2Unorm, plane: 0) else {
                throw CompositorError.outputTextureWrapFailed(kCVReturnError)
            }
            retained.append(cv)
            effectInput = tex

        case kCVPixelFormatType_64RGBAHalf: // rgba16Float — already straight RGB (a prior stage's output)
            guard let (tex, cv) = wrapInput(source, format: .rgba16Float, plane: 0) else {
                throw CompositorError.outputTextureWrapFailed(kCVReturnError)
            }
            retained.append(cv)
            effectInput = tex

        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,    // '420v'
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,     // '420f'
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,   // 'x420' (10-bit)
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:    // 'xf20' (10-bit)
            let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                      || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                         || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            let inter = try makeTarget(float: isFloat)   // float only for the 10-bit path
            intermediateBuffer = inter.buffer
            retained.append(inter.cvTexture)
            // 10-bit planes wrap as r16/rg16 (P010-style: code in the high bits);
            // 8-bit as r8/rg8. The shader's `tenBit` selects the sample scale.
            let lumaFmt: MTLPixelFormat = tenBit ? .r16Unorm : .r8Unorm
            let chromaFmt: MTLPixelFormat = tenBit ? .rg16Unorm : .rg8Unorm
            guard let (luma, cvL) = wrapInput(source, format: lumaFmt, plane: 0),
                  let (chroma, cvC) = wrapInput(source, format: chromaFmt, plane: 1) else {
                throw CompositorError.outputTextureWrapFailed(kCVReturnError)
            }
            retained.append(contentsOf: [cvL, cvC])
            // N5: honor the source's tagged YCbCr matrix + chroma siting (same as
            // the compositor layer path) so an effect source converts identically.
            var yu = YUVUniforms(
                fullRange: fullRange ? 1 : 0,
                yuvMatrix: YCbCrTags.matrixCode(for: source),
                chromaOffsetX: YCbCrTags.chromaOffsetX(for: source, lumaWidth: CVPixelBufferGetWidth(source)),
                tenBit: tenBit ? 1 : 0)

            let normDesc = MTLRenderPassDescriptor()
            normDesc.colorAttachments[0].texture = inter.texture
            normDesc.colorAttachments[0].loadAction = .dontCare   // fully overwritten
            normDesc.colorAttachments[0].storeAction = .store
            guard let normEnc = commandBuffer.makeRenderCommandEncoder(descriptor: normDesc) else {
                throw CompositorError.commandCreationFailed
            }
            normEnc.label = "prism.srcfx.yuv"
            normEnc.setRenderPipelineState(isFloat ? try floatPipeline("prism_srcfx_yuv_to_bgra")
                                                   : yuvNormalizePipeline)
            normEnc.setFragmentTexture(luma, index: 0)
            normEnc.setFragmentTexture(chroma, index: 1)
            normEnc.setFragmentBytes(&yu, length: MemoryLayout<YUVUniforms>.stride, index: 0)
            normEnc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            normEnc.endEncoding()
            effectInput = inter.texture

        default:
            throw CompositorError.unsupportedInputFormat(format)
        }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = target.texture
        passDesc.colorAttachments[0].loadAction = .dontCare   // fully overwritten
        passDesc.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            throw CompositorError.commandCreationFailed
        }
        encoder.label = "prism.srcfx"
        // 8-bit → the prebuilt BGRA8 pipeline (byte-identical); 10-bit → the same
        // fragment compiled for the rgba16Float target (built + cached lazily).
        encoder.setRenderPipelineState(isFloat ? try floatPipeline(fragment) : pipeline)
        encoder.setFragmentTexture(effectInput, index: 0)
        setUniforms(encoder)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(retained) {}
        withExtendedLifetime(intermediateBuffer) {}
        // The pass ran synchronously — its terminal state is now final. On a GPU
        // OOM / device fault / timeout the pooled target holds undefined or stale
        // pixels, so THROW (letting the caller fall back) instead of returning a
        // silently-corrupt frame published as if it succeeded.
        var status = commandBuffer.status
        #if DEBUG
        if _test_forceExecutionFailure { status = .error }
        #endif
        if let err = CompositorError.executionError(status: status,
                                                    error: commandBuffer.error) {
            throw err
        }
        // sol #3 finding 4: carry the source's colorimetry tags (primaries / matrix
        // / transfer) onto the pooled OUTPUT so the downstream compositor reads the
        // true colorspace — otherwise a Rec.2020 source with an effect reads as
        // untagged and gets rotated 709→2020 a second time (double-rotation).
        YCbCrTags.propagateColorTags(from: source, to: target.buffer)
        return target.buffer
    }

    /// Build (and cache) the `rgba16Float` variant of a fragment for the 10-bit
    /// path — the same MSL, a half-float render target instead of BGRA8.
    private func floatPipeline(_ fragment: String) throws -> MTLRenderPipelineState {
        if let p = floatPipelineCache[fragment] { return p }
        guard let vfn = library.makeFunction(name: "prism_blit_vertex") else {
            throw CompositorError.functionNotFound("prism_blit_vertex")
        }
        guard let ffn = library.makeFunction(name: fragment) else {
            throw CompositorError.functionNotFound(fragment)
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "prism.srcfx.\(fragment).f16"
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0]!.pixelFormat = .rgba16Float
        let p: MTLRenderPipelineState
        do { p = try device.makeRenderPipelineState(descriptor: desc) }
        catch { throw CompositorError.pipelineCreationFailed(underlying: error) }
        floatPipelineCache[fragment] = p
        return p
    }

    /// Mint an output buffer + render target. `float` selects the `64RGBAHalf`
    /// (rgba16Float) pool for the precision-preserving 10-bit path; otherwise the
    /// original BGRA8 pool (8-bit path, unchanged).
    private func makeTarget(float: Bool = false) throws
        -> (buffer: CVPixelBuffer, texture: MTLTexture, cvTexture: CVMetalTexture) {
        let outputBuffer: CVPixelBuffer
        let wrapFormat: MTLPixelFormat
        if float {
            if outputFloatPool == nil {
                do {
                    outputFloatPool = try PixelBufferPool(width: width, height: height,
                                                          pixelFormat: kCVPixelFormatType_64RGBAHalf,
                                                          minimumBufferCount: 6)
                } catch { throw CompositorError.outputBufferFailed(underlying: error) }
            }
            do { outputBuffer = try outputFloatPool!.makeBuffer() }
            catch { throw CompositorError.outputBufferFailed(underlying: error) }
            wrapFormat = .rgba16Float
        } else {
            do { outputBuffer = try outputPool.makeBuffer() }
            catch { throw CompositorError.outputBufferFailed(underlying: error) }
            wrapFormat = .bgra8Unorm
        }

        var outCVTexture: CVMetalTexture?
        let wrapStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, outputTextureCache, outputBuffer, nil,
            wrapFormat, width, height, 0, &outCVTexture)
        guard wrapStatus == kCVReturnSuccess, let outCVTexture,
              let outTexture = CVMetalTextureGetTexture(outCVTexture) else {
            throw CompositorError.outputTextureWrapFailed(wrapStatus)
        }
        return (outputBuffer, outTexture, outCVTexture)
    }

    /// Zero-copy wrap of one plane of an IOSurface-backed buffer as a Metal
    /// texture (BGRA uses plane 0 full-res; YUV uses plane 0 luma / plane 1 chroma
    /// at their own half-res dimensions). Mirrors `MetalCompositor.wrapInput`.
    private func wrapInput(_ buffer: CVPixelBuffer, format: MTLPixelFormat, plane: Int) -> (MTLTexture, CVMetalTexture)? {
        let planar = CVPixelBufferIsPlanar(buffer)
        let w = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
        let h = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, inputTextureCache, buffer, nil, format, w, h, plane, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return (texture, cvTexture)
    }
}
