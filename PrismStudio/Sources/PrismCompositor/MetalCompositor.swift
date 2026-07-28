import CoreMedia
import CoreVideo
import Foundation
import Metal
import os
import PrismCore

/// Errors from compositor setup and per-frame rendering.
public enum CompositorError: Error {
    /// Runtime MSL compilation failed (embedded shader source).
    case libraryCompilationFailed(underlying: Error)
    /// A named shader function is missing from the compiled library.
    case functionNotFound(String)
    case pipelineCreationFailed(underlying: Error)
    case textureCacheCreationFailed(CVReturn)
    /// The program output buffer could not be wrapped as a render target.
    case outputTextureWrapFailed(CVReturn)
    /// Minting the output CVPixelBuffer from the pool failed.
    case outputBufferFailed(underlying: Error)
    /// Metal command queue / command buffer / encoder creation failed.
    case commandCreationFailed
    /// Allocating an intermediate scene texture for the transition mix failed.
    case intermediateTextureCreationFailed
    /// An effect pass received a pixel format it cannot decode (not BGRA, not
    /// bi-planar 8-/10-bit YUV `420v`/`420f`/`x420`/`xf20`, not `l10r` packed, not
    /// `64RGBAHalf`). The caller should fall back rather than corrupt.
    case unsupportedInputFormat(OSType)
    /// A committed command buffer finished in a non-`.completed` state (GPU
    /// OOM / device fault / timeout). The output buffer holds undefined or stale
    /// pooled pixels and MUST NOT be published — the caller should fall back or
    /// drop rather than emit a corrupt frame. Carries `commandBuffer.error`.
    case gpuExecutionFailed(underlying: Error?)
}

extension CompositorError {
    /// Map a finished command buffer's terminal state to the typed error the
    /// caller must throw (`nil` == completed OK, publish the frame). Extracted so
    /// the completion check is unit-testable without provoking a real GPU fault.
    static func executionError(status: MTLCommandBufferStatus,
                               error: Error?) -> CompositorError? {
        status == .completed ? nil : .gpuExecutionFailed(underlying: error)
    }
}

/// The zero-copy Metal compositor (DESIGN.md §3.5 — "zero-copy or die").
///
/// - Inputs: `VideoFrame`s whose IOSurface-backed CVPixelBuffers are wrapped
///   as Metal textures through a `CVMetalTextureCache` — a pointer exchange on
///   unified memory, never a blit or CPU conversion.
/// - Output: BGRA8 program frames rendered straight into CVPixelBuffers minted
///   from `PrismCore.PixelBufferPool` (IOSurface-backed, Metal-compatible),
///   again wrapped via a `CVMetalTextureCache`.
/// - One fused render pass: layers are textured quads drawn back-to-front with
///   premultiplied-alpha blending. BGRA8 and bi-planar YUV (420v/420f) sources
///   each have a specialized pipeline; YUV→RGB happens in the fragment shader.
///
/// **GPU budget: < 4 ms at 1080p60, < 8 ms at 4K60** (DESIGN.md §3.5).
///
/// Thread model: NOT thread-safe — owned and driven by exactly one render
/// thread (`RenderLoop`). The CPU never touches pixels here; any
/// `CVPixelBufferLockBaseAddress` on this path is a bug.
public final class MetalCompositor {
    /// SourceID stamped on emitted program frames.
    public static let programSourceID = SourceID("program")

    /// Program output color mode (DESIGN.md §2.5 "HDR (P3/HLG) pipeline",
    /// §3.5 "P010/HDR is the v2+ fork").
    ///
    /// - `.sdr`: the default and only pre-HDR behavior — an 8-bit `BGRA8`
    ///   (`kCVPixelFormatType_32BGRA`) program, byte-for-byte identical to the
    ///   original compositor.
    /// - `.hdr`: a 10-bit wide-gamut program — layers are HLG-OETF-encoded into
    ///   a `bgr10a2Unorm` render target and emitted as a
    ///   `kCVPixelFormatType_ARGB2101010LEPacked` CVPixelBuffer tagged with
    ///   Rec.2020 primaries / ITU-R BT.2100 HLG transfer / Rec.2020 matrix so
    ///   HDR displays and the HEVC-Main10 recorder honor it.
    public enum ColorMode: String, Sendable { case sdr, hdr }

    public let device: MTLDevice
    public let width: Int
    public let height: Int

    /// Perf instrumentation sink (Phase 1d). When set, each composite records its
    /// command buffer's true GPU time (`gpuEndTime − gpuStartTime`) against a
    /// subsystem. Set by `RenderLoop` (shares the loop's aggregator). Nil = no
    /// overhead. Reading `gpuStartTime/gpuEndTime` after `waitUntilCompleted`
    /// costs nothing extra — the buffer already completed.
    public var metrics: RenderMetrics?

    /// Record a completed command buffer's GPU span for `subsystem`. Safe to call
    /// only after the buffer has finished (its gpu timestamps are then valid).
    @inline(__always)
    func recordGPU(_ subsystem: RenderMetrics.Subsystem, _ buffer: MTLCommandBuffer) {
        guard let metrics else { return }
        let seconds = buffer.gpuEndTime - buffer.gpuStartTime
        guard seconds > 0 else { return } // driver may report 0 if timestamps unavailable
        metrics.recordGPU(subsystem, nanos: Int64(seconds * 1_000_000_000))
    }
    /// The program output color mode fixed at construction.
    public let colorMode: ColorMode

    /// Metal render-target format for the PROGRAM OUTPUT buffer. SDR → 8-bit
    /// BGRA; HDR → 10-bit `bgr10a2Unorm` (the HLG-encoded, Rec.2020/BT.2100-tagged
    /// signal the recorder/display consume).
    private var attachmentFormat: MTLPixelFormat { colorMode == .hdr ? .bgr10a2Unorm : .bgra8Unorm }

    /// Metal format for the compositor's WORKING space — where every layer/mix/fx
    /// pass renders and blends. SDR composites directly in the 8-bit output format
    /// (byte-identical to the pre-HDR path). **HDR composites in `rgba16Float`
    /// Rec.2020 LINEAR light** (sol #3): layers decode to linear per their transfer
    /// tag, the premultiplied-alpha blend runs in light, and the BT.2100 HLG OETF
    /// is applied ONCE by the final encode pass into `attachmentFormat`.
    private var workingFormat: MTLPixelFormat { colorMode == .hdr ? .rgba16Float : .bgra8Unorm }

    #if DEBUG
    /// Test-only seam (HIGH-4 / Class H): when true, every composite path observes
    /// a **failed** command-buffer terminal status regardless of the real one, so
    /// the real status-check → throw fires deterministically. A genuine device
    /// fault cannot be provoked reliably in a unit test without risking a
    /// process-killing GPU hang, so the failure is injected at the real throw
    /// site. No effect in release.
    public var _test_forceExecutionFailure = false

    /// Test-only seam (wave-5b negative control): when true, the 10-bit input
    /// formats (`x420` / `xf20` biplanar, `l10r` packed, `64RGBAHalf`) fall through
    /// to the unsupported/default case — reproducing the PRE-fix behavior where a
    /// real 10-bit HDR source was dropped (layer skipped → opaque black). A test
    /// asserts the source is ACCEPTED (decoded) with the seam off and DROPPED with
    /// it on, so "10-bit accepted where it was silently dropped" is genuinely
    /// verified rather than assumed. No effect in release.
    public var _test_drop10BitFormats = false
    #endif

    /// The single terminal-status gate every composite/color pass runs after its
    /// `waitUntilCompleted` (HIGH-4 / F13, Class H). On a GPU OOM / device fault /
    /// timeout the pooled output holds undefined or stale pixels, so THROW the
    /// typed error (carrying `commandBuffer.error`) instead of returning a
    /// silently-corrupt frame published as if it succeeded — letting the caller
    /// fall back or drop the frame.
    private func throwIfExecutionFailed(_ commandBuffer: MTLCommandBuffer) throws {
        var status = commandBuffer.status
        #if DEBUG
        if _test_forceExecutionFailure { status = .error }
        #endif
        if let err = CompositorError.executionError(status: status, error: commandBuffer.error) {
            throw err
        }
    }

    private let commandQueue: MTLCommandQueue
    private let bgraPipeline: MTLRenderPipelineState
    private let yuvPipeline: MTLRenderPipelineState
    private let mixPipeline: MTLRenderPipelineState
    /// Fullscreen pixel/tile FX pass (`prism_fx_fragment`) — the live-GPU home of
    /// the pixel-effect and tile transition kinds.
    private let fxPipeline: MTLRenderPipelineState
    /// HDR ONLY (nil in SDR): the final `prism_hlg_encode_fragment` pass that
    /// applies the BT.2100 HLG OETF once, converting the linear Rec.2020 working
    /// texture into the 10-bit HLG/Rec.2020 output (sol #3 linear rebuild).
    private let hlgEncodePipeline: MTLRenderPipelineState?
    /// HDR ONLY: the single `rgba16Float` linear Rec.2020 working texture the
    /// program is composited into before the final HLG encode. Lazily allocated,
    /// then reused every tick (composite is single-threaded + synchronous).
    private var linearWorkTexture: MTLTexture?
    /// Intermediate scene textures for the transition mix stage — allocated
    /// lazily on the first mix composite (idle pipelines pay nothing), then
    /// reused every frame. Two suffice: composite is single-threaded and
    /// synchronous (`waitUntilCompleted`), so there is no in-flight overlap.
    private var mixTextures: (a: MTLTexture, b: MTLTexture)?
    private let inputTextureCache: CVMetalTextureCache
    private let outputTextureCache: CVMetalTextureCache
    private let outputPool: PixelBufferPool
    private let logger = EngineLog.logger("compositor")

    /// Last-known frames + forget-tombstones, guarded by one lock.
    ///
    /// - `held`: last-known frame per source — a 30 fps source keeps showing in
    ///   a 60 fps program; a stalled source holds its final frame rather than
    ///   flickering out. Cleared via `forget(source:)`.
    /// - `tombstoned`: sources that have been `forget`-ten but not re-`attach`-ed.
    ///   This closes the re-pin race (F1/F22): `removeMailbox`/`forget` runs on a
    ///   control thread while a render tick that already *snapshotted the mailbox*
    ///   is still in flight. That stale tick can carry a frame for the removed
    ///   source into `foldAndSnapshot` AFTER `forget` cleared `held` — with the
    ///   mailbox gone, nothing would ever `forget` it again and the IOSurface
    ///   would stay pinned forever. The tombstone makes `foldAndSnapshot` reject
    ///   that frame, so a stale in-flight tick can no longer re-pin a removed
    ///   source. A later `attach(source:)` (a genuine re-registration) clears the
    ///   tombstone so the source composites again.
    ///
    /// Lock rationale: the render thread folds/reads `held` every tick, while
    /// `forget`/`attach` may arrive from a control thread. Composite takes one
    /// snapshot per frame under the lock and renders from the snapshot, so the
    /// hot path holds the lock for a dictionary copy only.
    private struct FrameStore {
        var held: [SourceID: VideoFrame] = [:]
        var tombstoned: Set<SourceID> = []
        /// Monotonic tick counter, bumped once per `foldAndSnapshot`. Gives
        /// tombstones a bounded lifetime (N1) without reopening the F1/F22 race.
        var tickGeneration: UInt64 = 0
        /// Tick generation at which each tombstone was installed. Pruned once
        /// `tombstoneTTLTicks` ticks have elapsed — the render thread is serial per
        /// compositor, so only the immediately-following fold can carry a
        /// pre-forget frame; a small TTL keeps that guard while bounding the set so
        /// meme-churn UUIDs (forgotten, never re-attached) don't leak forever.
        var tombstoneGeneration: [SourceID: UInt64] = [:]
        /// Monotonic registration epoch, bumped by BOTH `attach` and `forget`.
        /// The per-source epoch (`sourceEpoch`) lets `foldAndSnapshot` reject a
        /// frame that was *pulled before a forget* even after a same-ID reattach
        /// cleared the tombstone (HIGH-3, the reopened F1). Tombstone membership
        /// alone cannot: a rapid `forget`→`attach` clears the tombstone, so the
        /// one still-in-flight tick would re-pin its stale pre-forget frame.
        var epochCounter: UInt64 = 0
        /// Registration epoch in force for each source. A stale in-flight frame
        /// carries the epoch captured at pull time; if it no longer matches, a
        /// forget (±reattach) intervened and the frame must be dropped.
        var sourceEpoch: [SourceID: UInt64] = [:]
        /// Epoch snapshot the owning `RenderLoop` captured when it pulled this
        /// tick's frames (set via `setPendingCapturedEpochs` immediately before
        /// `composite`). Empty for standalone/secondary compositors, which then
        /// rely on tombstones only (their original behavior, unchanged).
        var pendingCapturedEpochs: [SourceID: UInt64] = [:]
        /// Complete last-known set used by the most recent composite call.
        /// `RenderLoop` consumes this immediately after a successful primary
        /// render so secondary programs receive held frames too, not only the
        /// mailbox deltas that happened to arrive on that tick.
        var lastCompositeSnapshot: [SourceID: VideoFrame]?
        /// Opt-in: standalone/secondary compositors do not need the export and
        /// should not keep a second COW dictionary alive between composites.
        var exportsCompositeSnapshots = false
    }
    private let store = OSAllocatedUnfairLock<FrameStore>(initialState: FrameStore())

    /// Ticks a forget-tombstone survives before it is pruned (N1). `2` guarantees
    /// the single in-flight tick that could have snapshotted before the forget
    /// still sees the tombstone (with one tick of margin), while keeping the set
    /// bounded under meme churn (forget-then-never-re-attach).
    private static let tombstoneTTLTicks: UInt64 = 2

    /// Fold fresh frames into the last-known set and snapshot it for this tick.
    /// Frames for a tombstoned (forgotten) source are rejected — a stale
    /// in-flight tick must not re-pin a removed source's IOSurface.
    private func foldAndSnapshot(_ frames: [SourceID: VideoFrame]) -> [SourceID: VideoFrame] {
        store.withLock { s in
            s.tickGeneration &+= 1
            let gen = s.tickGeneration
            for (id, frame) in frames {
                // A forgotten (not-yet-reattached) source is rejected outright.
                if s.tombstoned.contains(id) { continue }
                // HIGH-3: reject a frame pulled under an OLDER registration epoch
                // than the source now holds. A rapid forget→attach bumps the epoch
                // twice and clears the tombstone, so this epoch mismatch — not the
                // (now-cleared) tombstone — is what rejects the one stale in-flight
                // tick's pre-forget frame. A genuinely fresh frame pulled AFTER the
                // reattach carries the new epoch and matches, so it still folds.
                if let captured = s.pendingCapturedEpochs[id],
                   let current = s.sourceEpoch[id],
                   captured != current { continue }
                s.held[id] = frame
            }
            // Prune tombstones that have outlived the re-pin window (N1). Done
            // AFTER the reject above, so a tombstone still guards this very fold;
            // TTL ≥ 2 keeps it through the one fold that could predate the forget.
            if !s.tombstoned.isEmpty {
                let expired = s.tombstoned.filter {
                    gen &- (s.tombstoneGeneration[$0] ?? gen) >= Self.tombstoneTTLTicks
                }
                // Drop the pruned id's epoch too — a never-re-attached (meme-churn)
                // source must not leak a `sourceEpoch` entry forever (bounds it
                // exactly like the tombstone set; N1).
                for id in expired {
                    s.tombstoned.remove(id); s.tombstoneGeneration[id] = nil
                    s.sourceEpoch[id] = nil
                }
            }
            let snapshot = s.held
            if s.exportsCompositeSnapshots { s.lastCompositeSnapshot = snapshot }
            return snapshot
        }
    }

    /// Enable exact frame-set export for the owning `RenderLoop`. Kept internal
    /// so standalone/secondary compositors retain their original hot-path cost.
    func enableCompositeSnapshotExport() {
        store.withLock { $0.exportsCompositeSnapshots = true }
    }

    /// Consume the complete source-frame set used by the preceding composite.
    /// Internal to PrismCompositor: the render loop calls this on its single
    /// render thread before publishing an exact tick snapshot.
    func consumeLastCompositeSnapshot() -> [SourceID: VideoFrame] {
        store.withLock { s in
            let snapshot = s.lastCompositeSnapshot ?? [:]
            s.lastCompositeSnapshot = nil
            return snapshot
        }
    }

    /// Layout mirror of the MSL `LayerUniforms` struct (80 bytes, 16-aligned).
    private struct LayerUniforms {
        var ndcRect: SIMD4<Float>
        var cropRect: SIMD4<Float>
        var opacity: Float
        var fullRange: UInt32
        /// BGRA only: 1 = honor sampled premultiplied alpha, 0 = force opaque.
        var premultiplied: UInt32 = 0
        /// Rotation about the layer centre, radians. 0 = identity (no-op).
        var rotation: Float = 0
        /// Canvas aspect ratio (width/height) — makes the rotation isotropic in
        /// pixels so a square layer stays square (no shear/squeeze).
        var aspect: Float = 1
        /// YUV only: which YCbCr→RGB matrix to apply — 0 = BT.709 (default),
        /// 1 = BT.601, 2 = BT.2020 — read from the source's `CVImageBufferYCbCrMatrix`
        /// attachment (MED-9). Wrong matrix = hue/saturation shift.
        var yuvMatrix: UInt32 = 0
        /// YUV only: horizontal chroma-sample offset in normalized texture units
        /// (MED-9). 0 = centered siting (MPEG-1/JPEG); +0.5/width = left/co-sited
        /// horizontal (MPEG-2/H.264/HEVC), read from `CVImageBufferChromaLocation`.
        var chromaOffsetX: Float = 0
        /// HDR only: the primary rotation into the Rec.2020 working gamut —
        /// 0 = already Rec.2020 (pass through, N4), 1 = rotate 709→2020,
        /// 2 = rotate P3→2020 (sol #4 finding 3). Read from the source's
        /// `CVImageBufferColorPrimaries` / `CVImageBufferYCbCrMatrix`; untagged /
        /// 709 → 1 (unchanged). Consumed only by the HDR linear fragments.
        var rotateTo2020: UInt32 = 1
        /// HDR (linear rebuild) only: the source's transfer for the per-layer
        /// linear decode — 0 = Rec.709 (default), 1 = HLG (BT.2100 inverse-OETF),
        /// 2 = PQ (ST 2084 EOTF), 3 = sRGB (IEC 61966-2-1 EOTF), 4 = Linear (skip
        /// the EOTF). Read from `CVImageBufferTransferFunction` (sol #3 + sol #4
        /// finding 3): a true-HLG source must NOT be decoded with the 709 EOTF, a
        /// Linear source must skip it, sRGB uses its own curve. Ignored by SDR.
        var transferFn: UInt32 = 0
        /// YUV only (wave-5b): 1 = the source is 10-bit biplanar (P010-style
        /// `x420`/`xf20`, r16/rg16 planes; the 10-bit code is in the high bits of
        /// each 16-bit sample), 0 = 8-bit (`420v`/`420f`). Selects the shader's
        /// 10-bit sample-scale + range anchors. 0 keeps the 8-bit path byte-identical.
        var tenBit: UInt32 = 0
        /// HDR (linear rebuild) only (sol #8 finding #6): 1 = the source's transfer is a
        /// NONLINEAR extended-range colorspace (`extendedSRGB` / `extendedITUR_2020` /
        /// `extendedDisplayP3`) that can legally carry values > 1 — the linear fragments
        /// must NOT saturate the coded value to [0,1] before the transfer decode (a
        /// half-float 1.5 extended-sRGB highlight was pre-clamped → 756 vs the correct
        /// 937). 0 = a bounded [0,1] transfer (true SDR / HLG / PQ / plain sRGB), whose
        /// pre-decode clamp stays byte-identical. Read from `YCbCrTags.extendedRangeCode`.
        var extendedRange: UInt32 = 0
    }

    /// Layout mirror of the MSL `FXUniforms` struct (48 bytes, all 4-byte
    /// scalars). Drives the pixel/tile FX pass; `seed` is split lo/hi for the
    /// shader's SplitMix64.
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

    /// - Parameters:
    ///   - device: the shared engine Metal device.
    ///   - width/height: program canvas size in pixels.
    ///   - colorMode: `.sdr` (default) keeps the exact BGRA8 behavior; `.hdr`
    ///     renders a 10-bit HLG/Rec.2020 program (opt-in, additive).
    public init(device: MTLDevice, width: Int, height: Int, colorMode: ColorMode = .sdr) throws {
        precondition(width > 0 && height > 0)
        self.device = device
        self.width = width
        self.height = height
        self.colorMode = colorMode
        // Local copies of the formats for use before all stored properties are
        // initialized (the computed properties can't be read on `self` yet).
        // `attach` = program OUTPUT; `working` = the compositing space (HDR blends
        // in rgba16Float Rec.2020 LINEAR, then encodes to `attach` once).
        let attach: MTLPixelFormat = colorMode == .hdr ? .bgr10a2Unorm : .bgra8Unorm
        let working: MTLPixelFormat = colorMode == .hdr ? .rgba16Float : .bgra8Unorm

        guard let queue = device.makeCommandQueue() else { throw CompositorError.commandCreationFailed }
        queue.label = "studio.prism.compositor"
        self.commandQueue = queue

        // SPM can't build .metal files into a library target → compile the embedded
        // MSL source at init. OPT#10: compile ONCE PER DEVICE via the shared cache —
        // identical source (this + SourceEffectGPU, and every HDR-toggle rebuild)
        // reuses one immutable library instead of recompiling. The derived PSOs below
        // stay per-instance.
        let library: MTLLibrary
        do {
            library = try MetalLibraryCache.library(device: device, source: CompositorShaders.source)
        } catch {
            throw CompositorError.libraryCompilationFailed(underlying: error)
        }
        func function(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else { throw CompositorError.functionNotFound(name) }
            return f
        }
        let vertexFn = try function("prism_layer_vertex")

        func makePipeline(fragment: String, label: String) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = label
            desc.vertexFunction = vertexFn
            desc.fragmentFunction = try function(fragment)
            let color = desc.colorAttachments[0]!
            // Layers render + blend in the WORKING space (HDR: linear rgba16Float).
            color.pixelFormat = working
            // Fragment shaders emit premultiplied alpha → (one, 1-srcAlpha).
            color.isBlendingEnabled = true
            color.rgbBlendOperation = .add
            color.alphaBlendOperation = .add
            color.sourceRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .one
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            do { return try device.makeRenderPipelineState(descriptor: desc) }
            catch { throw CompositorError.pipelineCreationFailed(underlying: error) }
        }
        // HDR swaps in the LINEAR-decode fragment variants (decode to Rec.2020
        // linear per transfer tag; NO output encode). The SDR fragment path is
        // byte-for-byte unchanged. The final HLG OETF is a separate encode pass.
        let bgraFragment = colorMode == .hdr ? "prism_layer_fragment_bgra_linear2020" : "prism_layer_fragment_bgra"
        let yuvFragment = colorMode == .hdr ? "prism_layer_fragment_yuv_linear2020" : "prism_layer_fragment_yuv"
        self.bgraPipeline = try makePipeline(fragment: bgraFragment, label: "prism.layer.bgra")
        self.yuvPipeline = try makePipeline(fragment: yuvFragment, label: "prism.layer.yuv")

        // Transition mix: fullscreen lerp of two fully-composited scene
        // textures. Blending disabled — the fragment writes the final program
        // pixel directly.
        do {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "prism.transition.mix"
            desc.vertexFunction = try function("prism_blit_vertex")
            desc.fragmentFunction = try function("prism_mix_fragment")
            // Crossfade lerps in the WORKING space (HDR: linear — a correct
            // light-space crossfade; the encode pass follows).
            desc.colorAttachments[0]!.pixelFormat = working
            do { self.mixPipeline = try device.makeRenderPipelineState(descriptor: desc) }
            catch { throw CompositorError.pipelineCreationFailed(underlying: error) }
        }

        // Pixel/tile FX pass: fullscreen per-pixel blend of two composited
        // scenes for the pixel-effect/tile kinds. Blending disabled — the
        // fragment writes the final opaque program pixel directly.
        do {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "prism.transition.fx"
            desc.vertexFunction = try function("prism_blit_vertex")
            desc.fragmentFunction = try function("prism_fx_fragment")
            desc.colorAttachments[0]!.pixelFormat = working
            do { self.fxPipeline = try device.makeRenderPipelineState(descriptor: desc) }
            catch { throw CompositorError.pipelineCreationFailed(underlying: error) }
        }

        // HDR ONLY: the final HLG-encode pass (`prism_hlg_encode_fragment`) reads
        // the linear Rec.2020 working texture and applies the BT.2100 HLG OETF once
        // into the 10-bit output. Blending disabled — it fully overwrites. Nil in
        // SDR (the composite writes the 8-bit output directly, no encode step).
        if colorMode == .hdr {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "prism.hlg.encode"
            desc.vertexFunction = try function("prism_blit_vertex")
            desc.fragmentFunction = try function("prism_hlg_encode_fragment")
            desc.colorAttachments[0]!.pixelFormat = attach
            do { self.hlgEncodePipeline = try device.makeRenderPipelineState(descriptor: desc) }
            catch { throw CompositorError.pipelineCreationFailed(underlying: error) }
        } else {
            self.hlgEncodePipeline = nil
        }

        // Input cache: default usage (shader read) is what sampling needs.
        var inCache: CVMetalTextureCache?
        var status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &inCache)
        guard status == kCVReturnSuccess, let inCache else { throw CompositorError.textureCacheCreationFailed(status) }
        self.inputTextureCache = inCache

        // Output cache: textures must be render targets.
        let outAttrs: [CFString: Any] = [
            kCVMetalTextureUsage: NSNumber(value: MTLTextureUsage([.renderTarget, .shaderRead]).rawValue),
        ]
        var outCache: CVMetalTextureCache?
        status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, outAttrs as CFDictionary, &outCache)
        guard status == kCVReturnSuccess, let outCache else { throw CompositorError.textureCacheCreationFailed(status) }
        self.outputTextureCache = outCache

        // Program buffers: IOSurface-backed + Metal-compatible by construction.
        // SDR → BGRA8; HDR → 10-bit packed RGB (`ARGB2101010LEPacked`).
        //
        // Depth is a warm-recycle FLOOR, not a cap: `PixelBufferPool` sets only
        // `kCVPixelBufferPoolMinimumBufferCount` (no allocation threshold), so a
        // transient burst above the floor allocates a fresh buffer rather than
        // stalling — the depth can never starve the render thread.
        //
        // Why 4 covers the in-flight program frames: `composite` mints exactly
        // ONE program buffer per tick and renders it synchronously
        // (`waitUntilCompleted` — GPU is done before the frame returns), then
        // hands it to the single `RenderLoop` consumer. The only concurrent
        // liveness is the current tick's frame (1) plus the handful the
        // downstream sink (HEVC recorder / encoder queue) still holds while it
        // drains — steady state is ~2–3 alive at once. 4 gives one warm spare
        // over that; anything beyond it auto-grows. (Was 6 = 199 MB @4K, a
        // profiled over-provision against a pipeline with 25–40× headroom.)
        let poolFormat: OSType = colorMode == .hdr
            ? kCVPixelFormatType_ARGB2101010LEPacked : kCVPixelFormatType_32BGRA
        self.outputPool = try PixelBufferPool(width: width, height: height,
                                              pixelFormat: poolFormat,
                                              minimumBufferCount: 4)
    }

    /// Attach the Rec.2020 / ITU-R BT.2100 HLG color tags to an HDR program
    /// buffer so downstream (HEVC-Main10 recorder, CAMetalLayer/HDR display,
    /// P010 conversion) reads it as HDR. No-op in `.sdr` mode.
    private func attachHDRColorTags(to buffer: CVPixelBuffer) {
        guard colorMode == .hdr else { return }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    }

    /// Composite one program frame.
    ///
    /// - Parameters:
    ///   - frames: frames that arrived since the last tick (missing sources
    ///     fall back to their last-known frame; never-seen sources are skipped).
    ///   - scene: the layer stack; layers render sorted by `zIndex` (back-to-front).
    ///   - pts: house-time PTS stamped on the program frame (pass the tick
    ///     deadline through — never re-stamp with wall clock).
    ///   - duration: optional frame duration (1/fps from the render loop).
    /// - Returns: the program `VideoFrame` (BGRA8, IOSurface-backed), fully
    ///   rendered — safe to hand to encoders / preview / the CMIO extension.
    public func composite(frames: [SourceID: VideoFrame],
                          scene: Scene,
                          pts: CMTime,
                          duration: CMTime = .invalid) throws -> VideoFrame {
        let held = foldAndSnapshot(frames)
        return try renderProgram(scenes: [scene], lastFrames: held, pts: pts, duration: duration)
    }

    /// Composite one program frame of a scene *transition*: a true crossfade
    /// between two fully-rendered scenes.
    ///
    /// Correctness note (why this is not "draw A then B with global opacity
    /// factors"): scaling every layer's opacity in a single shared pass blends
    /// each layer against whatever is *already under it* — for overlapping
    /// content that computes `B over (A over black)`, which darkens through
    /// the clear color and never equals a crossfade. The correct definition is
    /// `program = lerp(render(A), render(B), mix)`, so each scene is rendered
    /// to its own pooled intermediate texture and a fullscreen mix kernel
    /// lerps them into the program buffer. Three passes, one command buffer,
    /// one `waitUntilCompleted` — same synchronous contract as `composite`.
    ///
    /// - Parameters:
    ///   - frames: fresh frames since the last tick (both scenes pull from the
    ///     same last-known set).
    ///   - sceneA: the outgoing scene (`mix == 0` shows exactly this).
    ///   - sceneB: the incoming scene (`mix == 1` shows exactly this).
    ///   - mix: blend factor, clamped to 0…1. The endpoints short-circuit to a
    ///     plain single-scene render (no intermediate passes).
    ///   - pts/duration: as in `composite(frames:scene:pts:duration:)`.
    public func composite(frames: [SourceID: VideoFrame],
                          sceneA: Scene,
                          sceneB: Scene,
                          mix: Float,
                          pts: CMTime,
                          duration: CMTime = .invalid) throws -> VideoFrame {
        let held = foldAndSnapshot(frames)

        let mix = min(max(mix, 0), 1)
        if mix == 0 { return try renderProgram(scenes: [sceneA], lastFrames: held, pts: pts, duration: duration) }
        if mix == 1 { return try renderProgram(scenes: [sceneB], lastFrames: held, pts: pts, duration: duration) }

        let target = try makeProgramTarget()
        let (texA, texB) = try intermediateTextures()
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw CompositorError.commandCreationFailed
        }
        commandBuffer.label = "prism.composite.mix"
        var retained: [CVMetalTexture] = [target.cvTexture]

        let composited = try compositeDestination(finalOutput: target.texture)
        try encodeScenePass(scenes: [sceneA], lastFrames: held, into: texA, commandBuffer: commandBuffer, retained: &retained)
        try encodeScenePass(scenes: [sceneB], lastFrames: held, into: texB, commandBuffer: commandBuffer, retained: &retained)
        try encodeMixPass(a: texA, b: texB, mix: mix, into: composited, commandBuffer: commandBuffer)
        try encodeFinalTransferIfHDR(from: composited, into: target.texture, commandBuffer: commandBuffer)

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        recordGPU(.transition, commandBuffer)
        withExtendedLifetime(retained) {}
        try throwIfExecutionFailed(commandBuffer) // HIGH-4: never publish a fault frame
        return VideoFrame(pixelBuffer: target.buffer, pts: pts, duration: duration,
                          source: Self.programSourceID)
    }

    /// Composite one program frame of a scene transition using a per-pixel/tile
    /// GPU **effect** (`iris`, `zoomBlur`, `glitch`, `animeFlash`, `speedline`,
    /// and the tile family). Both scenes are rendered to their own intermediate
    /// textures, then the `prism_fx_fragment` shader blends them for
    /// `effect.kind` at `progress` — the SAME math as the CPU `TransitionRenderer`
    /// (the ground-truth reference). This is how the pixel/tile kinds run
    /// natively in the live compositor (`RenderLoop.switchScene`) instead of
    /// degrading to a crossfade.
    ///
    /// - Parameters:
    ///   - sceneA/sceneB: outgoing (`progress 0`) / incoming (`progress 1`).
    ///   - effect: which effect + its params (grid/seed/softness/direction).
    ///   - progress: eased blend phase, clamped 0…1. For a one-shot kind the
    ///     endpoints short-circuit to a plain single-scene render (exact A/B);
    ///     `continuous` kinds (`tileFlicker`) never short-circuit.
    ///   - rawProgress: raw (pre-easing) phase — the `glitch` split amount and
    ///     the `tileFlicker` loop phase ride this (matching the CPU renderer).
    public func composite(frames: [SourceID: VideoFrame],
                          sceneA: Scene,
                          sceneB: Scene,
                          effect: CompositorEffect,
                          progress: Float,
                          rawProgress: Float,
                          pts: CMTime,
                          duration: CMTime = .invalid) throws -> VideoFrame {
        let held = foldAndSnapshot(frames)
        let p = min(max(progress, 0), 1)
        // One-shot endpoints are exact A/B (matches the CPU renderer's t≤0/t≥1
        // short-circuit). Continuous kinds (flicker) keep running the shader.
        if !effect.continuous {
            if p <= 0 { return try renderProgram(scenes: [sceneA], lastFrames: held, pts: pts, duration: duration) }
            if p >= 1 { return try renderProgram(scenes: [sceneB], lastFrames: held, pts: pts, duration: duration) }
        }

        let target = try makeProgramTarget()
        let (texA, texB) = try intermediateTextures()
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw CompositorError.commandCreationFailed
        }
        commandBuffer.label = "prism.composite.fx"
        var retained: [CVMetalTexture] = [target.cvTexture]

        let composited = try compositeDestination(finalOutput: target.texture)
        try encodeScenePass(scenes: [sceneA], lastFrames: held, into: texA, commandBuffer: commandBuffer, retained: &retained)
        try encodeScenePass(scenes: [sceneB], lastFrames: held, into: texB, commandBuffer: commandBuffer, retained: &retained)
        try encodeEffectPass(a: texA, b: texB, effect: effect, progress: p, rawProgress: rawProgress,
                             into: composited, commandBuffer: commandBuffer)
        try encodeFinalTransferIfHDR(from: composited, into: target.texture, commandBuffer: commandBuffer)

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        recordGPU(.transition, commandBuffer)
        withExtendedLifetime(retained) {}
        try throwIfExecutionFailed(commandBuffer) // HIGH-4: never publish a fault frame
        return VideoFrame(pixelBuffer: target.buffer, pts: pts, duration: duration,
                          source: Self.programSourceID)
    }

    /// Composite a *stack* of scenes back-to-front in one pass (later scenes
    /// draw over earlier ones, each internally z-sorted). Used by `RenderLoop`
    /// for `.overlay` transitions (slide/push): incoming under, outgoing over,
    /// no extra blend — the layer motion itself reveals the incoming scene
    /// (see `SceneTransition`'s documented compositor seam).
    func composite(frames: [SourceID: VideoFrame],
                   stack: [Scene],
                   pts: CMTime,
                   duration: CMTime = .invalid) throws -> VideoFrame {
        let held = foldAndSnapshot(frames)
        return try renderProgram(scenes: stack, lastFrames: held, pts: pts, duration: duration)
    }

    // MARK: - Render plumbing (shared by all composite entry points)

    /// Mint a program buffer from the pool and wrap it as a render target.
    private func makeProgramTarget() throws -> (buffer: CVPixelBuffer, texture: MTLTexture, cvTexture: CVMetalTexture) {
        let outputBuffer: CVPixelBuffer
        do { outputBuffer = try outputPool.makeBuffer() }
        catch { throw CompositorError.outputBufferFailed(underlying: error) }
        attachHDRColorTags(to: outputBuffer)

        var outCVTexture: CVMetalTexture?
        let wrapStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, outputTextureCache, outputBuffer, nil,
            attachmentFormat, width, height, 0, &outCVTexture)
        guard wrapStatus == kCVReturnSuccess, let outCVTexture,
              let outTexture = CVMetalTextureGetTexture(outCVTexture) else {
            throw CompositorError.outputTextureWrapFailed(wrapStatus)
        }
        return (outputBuffer, outTexture, outCVTexture)
    }

    /// The texture the scene/mix/fx passes should render into. HDR composites in
    /// the linear Rec.2020 working texture (then `encodeFinalTransferIfHDR` applies
    /// the HLG OETF into the 10-bit output); SDR renders straight into the output.
    private func compositeDestination(finalOutput: MTLTexture) throws -> MTLTexture {
        colorMode == .hdr ? try programWorkTexture() : finalOutput
    }

    /// HDR: the single final output transfer — apply the BT.2100 HLG OETF ONCE,
    /// encoding the linear Rec.2020 working texture into the 10-bit HLG output
    /// (sol #3 — the composite happened in LINEAR light; encode is the last step).
    /// SDR: a no-op (the composite already wrote the output directly).
    private func encodeFinalTransferIfHDR(from working: MTLTexture, into output: MTLTexture,
                                          commandBuffer: MTLCommandBuffer) throws {
        guard colorMode == .hdr, let pipeline = hlgEncodePipeline else { return }
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = output
        passDesc.colorAttachments[0].loadAction = .dontCare // fully overwritten
        passDesc.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            throw CompositorError.commandCreationFailed
        }
        encoder.label = "prism.hlg.encode.pass"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(working, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    /// Lazily allocate (then reuse) the HDR linear Rec.2020 working texture the
    /// program composites into before the final HLG encode.
    private func programWorkTexture() throws -> MTLTexture {
        if let linearWorkTexture { return linearWorkTexture }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: workingFormat, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private // never CPU-touched
        guard let t = device.makeTexture(descriptor: desc) else {
            throw CompositorError.intermediateTextureCreationFailed
        }
        t.label = "prism.hdr.linearWork"
        linearWorkTexture = t
        return t
    }

    /// The classic single-pass render: scenes drawn back-to-front into the
    /// program buffer.
    private func renderProgram(scenes: [Scene], lastFrames: [SourceID: VideoFrame],
                               pts: CMTime, duration: CMTime) throws -> VideoFrame {
        let target = try makeProgramTarget()
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw CompositorError.commandCreationFailed
        }
        commandBuffer.label = "prism.composite"

        // CVMetalTextures must outlive GPU execution; retain until completion.
        var retained: [CVMetalTexture] = [target.cvTexture]
        // HDR composites into the linear Rec.2020 working texture, then the final
        // HLG-encode pass writes the 10-bit output; SDR renders straight into it.
        let composited = try compositeDestination(finalOutput: target.texture)
        try encodeScenePass(scenes: scenes, lastFrames: lastFrames, into: composited,
                            commandBuffer: commandBuffer, retained: &retained)
        try encodeFinalTransferIfHDR(from: composited, into: target.texture, commandBuffer: commandBuffer)
        commandBuffer.commit()

        // Synchronous completion: the returned buffer must be fully rendered
        // before any consumer (VT encode, IOSurface push to the CMIO
        // extension) reads it, and the render loop's next tick is >16 ms away
        // while the pass costs <4 ms — blocking here is the simple, correct
        // v0 choice. Async triple-buffered handoff is a later optimization.
        commandBuffer.waitUntilCompleted()
        recordGPU(.compositor, commandBuffer)
        withExtendedLifetime(retained) {}
        try throwIfExecutionFailed(commandBuffer) // HIGH-4: never publish a fault frame

        return VideoFrame(pixelBuffer: target.buffer, pts: pts, duration: duration,
                          source: Self.programSourceID)
    }

    /// Encode one render pass drawing `scenes` back-to-front into `target`
    /// (cleared to opaque black; each scene internally z-sorted).
    /// `lastFrames` is the per-tick snapshot taken under the frames lock.
    private func encodeScenePass(scenes: [Scene], lastFrames: [SourceID: VideoFrame],
                                 into target: MTLTexture,
                                 commandBuffer: MTLCommandBuffer,
                                 retained: inout [CVMetalTexture]) throws {
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = target
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1) // opaque black

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            throw CompositorError.commandCreationFailed
        }
        encoder.label = "prism.scene.pass"

        for scene in scenes {
            // Back-to-front. Swift's sort is not stable → stabilize ties by index.
            let ordered = scene.layers.enumerated()
                .sorted { ($0.element.zIndex, $0.offset) < ($1.element.zIndex, $1.offset) }
                .map(\.element)

            for layer in ordered {
                guard !layer.isHidden, layer.opacity > 0,
                      let frame = lastFrames[layer.sourceID] else { continue } // missing source = skipped
                encodeLayer(layer, frame: frame, encoder: encoder, retained: &retained)
            }
        }
        encoder.endEncoding()
    }

    /// Encode the fullscreen mix pass: `target = lerp(a, b, mix)`.
    private func encodeMixPass(a: MTLTexture, b: MTLTexture, mix: Float,
                               into target: MTLTexture,
                               commandBuffer: MTLCommandBuffer) throws {
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = target
        passDesc.colorAttachments[0].loadAction = .dontCare // fully overwritten
        passDesc.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            throw CompositorError.commandCreationFailed
        }
        encoder.label = "prism.mix.pass"
        encoder.setRenderPipelineState(mixPipeline)
        encoder.setFragmentTexture(a, index: 0)
        encoder.setFragmentTexture(b, index: 1)
        var mix = mix
        encoder.setFragmentBytes(&mix, length: MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    /// Encode the fullscreen pixel/tile FX pass: `target = fx(a, b, effect, p)`.
    private func encodeEffectPass(a: MTLTexture, b: MTLTexture,
                                  effect: CompositorEffect, progress: Float, rawProgress: Float,
                                  into target: MTLTexture,
                                  commandBuffer: MTLCommandBuffer) throws {
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = target
        passDesc.colorAttachments[0].loadAction = .dontCare // fully overwritten
        passDesc.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            throw CompositorError.commandCreationFailed
        }
        encoder.label = "prism.fx.pass"
        encoder.setRenderPipelineState(fxPipeline)
        encoder.setFragmentTexture(a, index: 0)
        encoder.setFragmentTexture(b, index: 1)
        var u = FXUniforms(
            kind: effect.kind.rawValue,
            progress: min(max(progress, 0), 1),
            rawProgress: rawProgress,
            softness: effect.softness,
            rows: max(effect.rows, 1),
            cols: max(effect.cols, 1),
            direction: effect.direction,
            seedLo: UInt32(truncatingIfNeeded: effect.seed),
            seedHi: UInt32(truncatingIfNeeded: effect.seed >> 32),
            width: UInt32(width),
            height: UInt32(height))
        encoder.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    /// Lazily allocate (then reuse) the two GPU-private scene textures for the
    /// mix stage.
    private func intermediateTextures() throws -> (MTLTexture, MTLTexture) {
        if let mixTextures { return mixTextures }
        // Scene textures feed the mix/fx pass, so they are in the WORKING space
        // (HDR: linear rgba16Float — the crossfade/FX blend runs in light).
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: workingFormat, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private // never CPU-touched
        guard let a = device.makeTexture(descriptor: desc),
              let b = device.makeTexture(descriptor: desc) else {
            throw CompositorError.intermediateTextureCreationFailed
        }
        a.label = "prism.mix.sceneA"
        b.label = "prism.mix.sceneB"
        mixTextures = (a, b)
        return (a, b)
    }

    /// Drop the retained last-known frame for a removed source, releasing its
    /// buffer, and tombstone it so a stale in-flight tick (mailbox snapshotted
    /// before removal) cannot re-fold it and re-pin the IOSurface forever
    /// (F1/F22). Thread-safe: callable from any thread while the render loop runs.
    /// Shed the output pool's *unused* buffers so a past spike's IOSurfaces don't
    /// stay resident for process lifetime. Idle-seam only (see `RenderLoop.stop`);
    /// buffers still in flight are untouched, so live recycling is unaffected.
    /// Never call this per-frame — the hot path must stay allocation-free.
    public func flushExcessBuffers() {
        outputPool.flushExcess()
    }

    public func forget(source: SourceID) {
        store.withLock { s in
            s.held.removeValue(forKey: source)
            s.lastCompositeSnapshot?.removeValue(forKey: source)
            s.tombstoned.insert(source)
            s.tombstoneGeneration[source] = s.tickGeneration
            // Advance the registration epoch (HIGH-3): any frame the render thread
            // already pulled under the pre-forget epoch is now stale and will be
            // rejected by `foldAndSnapshot`, even if an immediate reattach follows.
            s.epochCounter &+= 1
            s.sourceEpoch[source] = s.epochCounter
        }
    }

    /// (Re)attach a source: clear any forget-tombstone so its frames fold into
    /// the last-known set again. Call on genuine (re)registration — the primary
    /// path is `RenderLoop.setMailbox`, while `DualProgram.attach(source:)`
    /// provides the secondary's explicit registration fence. Idempotent and
    /// thread-safe.
    public func attach(source: SourceID) {
        store.withLock { s in
            s.tombstoned.remove(source)
            s.tombstoneGeneration[source] = nil
            // A genuine (re)registration is a NEW epoch: frames pulled after this
            // point match and fold; any still-in-flight pre-forget frame keeps the
            // older captured epoch and is rejected (HIGH-3).
            s.epochCounter &+= 1
            s.sourceEpoch[source] = s.epochCounter
        }
    }

    /// Snapshot the current per-source registration epochs. The owning
    /// `RenderLoop` calls this when it pulls a tick's frames, then hands the
    /// snapshot back via `setPendingCapturedEpochs` before `composite`, so
    /// `foldAndSnapshot` can reject any frame whose source was forgotten (and
    /// maybe reattached) between pull and fold (HIGH-3). Internal to the module.
    func captureSourceEpochs() -> [SourceID: UInt64] {
        store.withLock { $0.sourceEpoch }
    }

    /// Install the epoch snapshot captured at pull time for the *next*
    /// `composite`. Replaces any prior snapshot (one per tick). Internal — only
    /// the render loop drives this; standalone compositors never call it and so
    /// keep tombstone-only behavior.
    func setPendingCapturedEpochs(_ epochs: [SourceID: UInt64]) {
        store.withLock { $0.pendingCapturedEpochs = epochs }
    }

    /// Sources whose last-known frame is currently retained (diagnostics /
    /// headless verification of the forget path). Thread-safe.
    public var heldSourceIDs: [SourceID] {
        store.withLock { Array($0.held.keys) }
    }

    /// The retained last-known frame for a source (nil if none). Headless
    /// verification of WHICH frame is pinned — a stale pre-forget frame must
    /// never be, even after a same-ID reattach (HIGH-3). Thread-safe.
    public func retainedFrame(for source: SourceID) -> VideoFrame? {
        store.withLock { $0.held[source] }
    }

    /// Sources currently tombstoned (forgotten, not yet re-attached or pruned).
    /// Diagnostics / headless verification that the tombstone set stays bounded
    /// (N1) — it must not retain a never-re-attached id indefinitely. Thread-safe.
    public var tombstonedSourceIDs: [SourceID] {
        store.withLock { Array($0.tombstoned) }
    }

    // MARK: - Per-layer encoding

    private func encodeLayer(_ layer: Layer, frame: VideoFrame,
                             encoder: MTLRenderCommandEncoder,
                             retained: inout [CVMetalTexture]) {
        var uniforms = LayerUniforms(
            ndcRect: Self.ndcRect(for: layer.frame),
            cropRect: SIMD4(Float(layer.crop.origin.x), Float(layer.crop.origin.y),
                            Float(layer.crop.size.width), Float(layer.crop.size.height)),
            opacity: min(max(layer.opacity, 0), 1),
            fullRange: 0,
            // Honored only by the BGRA fragment; the YUV path has no alpha and
            // always composites opaque regardless of this flag.
            premultiplied: layer.premultipliedAlpha ? 1 : 0,
            // Rotation about the layer centre (radians); 0 → identity vertex
            // transform → byte-identical to the un-rotated path. `aspect` keeps
            // the rotation distortion-free on non-square canvases.
            rotation: Float(layer.rotation),
            aspect: Float(width) / Float(height),
            // N4 + sol #4 finding 3: the primary rotation into the Rec.2020 working
            // gamut — 0 already-2020 (no re-rotate), 1 rotate 709→2020, 2 rotate
            // P3→2020. Supersedes the binary isRec2020 gate (which folded P3 into
            // the 709 case). Consumed only by the HDR linear fragments.
            rotateTo2020: Self.sourcePrimariesRotation(for: frame.pixelBuffer),
            // sol #3: decode each layer to linear per its OWN transfer tag — a true-
            // HLG source must be HLG-inverse-OETF-decoded, not 709-EOTF-decoded.
            // Consumed only by the HDR linear fragments (ignored in SDR).
            transferFn: Self.sourceTransfer(for: frame.pixelBuffer))
        // sol #8 finding #6: mark a nonlinear extended-range source so the HDR linear
        // fragments do NOT pre-clamp its legal > 1 highlights before the transfer
        // decode. 0 for every bounded transfer (true SDR / HLG / PQ) — byte-identical.
        uniforms.extendedRange = Self.sourceExtendedRange(for: frame.pixelBuffer)

        switch frame.pixelFormat {
        case kCVPixelFormatType_32BGRA:
            guard let (tex, cv) = wrapInput(frame.pixelBuffer, format: .bgra8Unorm, plane: 0) else {
                logger.error("BGRA texture wrap failed for \(frame.source, privacy: .public) — layer skipped")
                return
            }
            retained.append(cv)
            encoder.setRenderPipelineState(bgraPipeline)
            encoder.setFragmentTexture(tex, index: 0)

        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, // '420v'
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:  // '420f'
            uniforms.fullRange = frame.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 1 : 0
            // MED-9: honor the source's tagged YCbCr matrix + chroma siting instead
            // of hardcoding centered BT.709 (wrong matrix = hue/sat shift; wrong
            // siting = half-pixel chroma shift / colored fringing on edges).
            uniforms.yuvMatrix = Self.yuvMatrixCode(for: frame.pixelBuffer)
            uniforms.chromaOffsetX = Self.chromaLeftSited(for: frame.pixelBuffer)
                ? 0.5 / Float(frame.width) : 0
            guard let (luma, cvL) = wrapInput(frame.pixelBuffer, format: .r8Unorm, plane: 0),
                  let (chroma, cvC) = wrapInput(frame.pixelBuffer, format: .rg8Unorm, plane: 1) else {
                logger.error("YUV texture wrap failed for \(frame.source, privacy: .public) — layer skipped")
                return
            }
            retained.append(contentsOf: [cvL, cvC])
            encoder.setRenderPipelineState(yuvPipeline)
            encoder.setFragmentTexture(luma, index: 0)
            encoder.setFragmentTexture(chroma, index: 1)

        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, // 'x420' — 10-bit HDR (P010-style)
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:  // 'xf20'
            #if DEBUG
            if _test_drop10BitFormats { // negative control: reproduce the pre-fix drop
                logger.error("10-bit format dropped (test seam) — layer skipped")
                return
            }
            #endif
            // wave-5b: real 10-bit HLG/PQ ingest. The 10-bit code sits in the high
            // bits of each 16-bit sample, so the planes wrap as r16Unorm / rg16Unorm
            // and the shader scales value/1023 (accounting for the 6-bit left shift)
            // — NO downconvert to 8-bit. The tagged matrix/transfer/primaries flow
            // through the EXISTING color model, so a 10-bit Rec.2020/HLG source
            // composites correctly through the linear-light HDR path (wave-4b/5[L]).
            uniforms.fullRange = frame.pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ? 1 : 0
            uniforms.yuvMatrix = Self.yuvMatrixCode(for: frame.pixelBuffer)
            uniforms.chromaOffsetX = Self.chromaLeftSited(for: frame.pixelBuffer)
                ? 0.5 / Float(frame.width) : 0
            uniforms.tenBit = 1
            guard let (luma, cvL) = wrapInput(frame.pixelBuffer, format: .r16Unorm, plane: 0),
                  let (chroma, cvC) = wrapInput(frame.pixelBuffer, format: .rg16Unorm, plane: 1) else {
                logger.error("10-bit YUV texture wrap failed for \(frame.source, privacy: .public) — layer skipped")
                return
            }
            retained.append(contentsOf: [cvL, cvC])
            encoder.setRenderPipelineState(yuvPipeline)
            encoder.setFragmentTexture(luma, index: 0)
            encoder.setFragmentTexture(chroma, index: 1)

        case kCVPixelFormatType_ARGB2101010LEPacked: // 'l10r' — 10-bit packed RGB (ScreenCaptureKit HDR)
            #if DEBUG
            if _test_drop10BitFormats {
                logger.error("10-bit format dropped (test seam) — layer skipped")
                return
            }
            #endif
            // wave-5b: 10-bit unorm — Metal normalizes value/1023 in hardware, so the
            // BGRA fragment samples it byte-precise (no 8-bit collapse). The bgr10a2
            // wrap matches the compositor's own 10-bit OUTPUT buffer (symmetric). In
            // HDR mode the linear BGRA fragment decodes it per its HLG/PQ transfer tag.
            guard let (tex, cv) = wrapInput(frame.pixelBuffer, format: .bgr10a2Unorm, plane: 0) else {
                logger.error("10-bit packed RGB wrap failed for \(frame.source, privacy: .public) — layer skipped")
                return
            }
            retained.append(cv)
            encoder.setRenderPipelineState(bgraPipeline)
            encoder.setFragmentTexture(tex, index: 0)

        case kCVPixelFormatType_64RGBAHalf: // rgba16Float — higher-precision (FX/Vision/Color 10-bit output)
            #if DEBUG
            if _test_drop10BitFormats {
                logger.error("10-bit format dropped (test seam) — layer skipped")
                return
            }
            #endif
            // wave-5b: the per-source FX / Vision / Color stages decode a 10-bit input
            // into an rgba16Float buffer (no 8-bit collapse); the compositor folds
            // that half-float layer straight in (RGBA order; `.rgb` reads correct).
            guard let (tex, cv) = wrapInput(frame.pixelBuffer, format: .rgba16Float, plane: 0) else {
                logger.error("rgba16Float wrap failed for \(frame.source, privacy: .public) — layer skipped")
                return
            }
            retained.append(cv)
            encoder.setRenderPipelineState(bgraPipeline)
            encoder.setFragmentTexture(tex, index: 0)

        default:
            logger.error("Unsupported pixel format \(frame.pixelFormat) from \(frame.source, privacy: .public) — layer skipped")
            return
        }

        encoder.setVertexBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Zero-copy wrap of one plane of an IOSurface-backed buffer as a Metal texture.
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

    /// MED-9: the YCbCr matrix a source declares, mapped to the shader code
    /// (0 = BT.709 default, 1 = BT.601, 2 = BT.2020). An untagged buffer (many
    /// screen/graphics sources) defaults to 709 — preserving the pre-MED-9
    /// behavior exactly. SMPTE-240M and any unrecognized matrix fall back to 709.
    static func yuvMatrixCode(for buffer: CVPixelBuffer) -> UInt32 {
        YCbCrTags.matrixCode(for: buffer)
    }

    /// MED-9: whether a source declares LEFT / co-sited-horizontal chroma siting
    /// (MPEG-2/H.264/HEVC). Absent or `Center` → centered (MPEG-1/JPEG), the
    /// GPU's default normalized-sampling position. Only the horizontal component
    /// is corrected; vertical siting stays centered (documented limitation).
    static func chromaLeftSited(for buffer: CVPixelBuffer) -> Bool {
        YCbCrTags.isLeftSited(for: buffer)
    }

    /// N4: does this source already declare Rec.2020 primaries? (So the HDR path
    /// must NOT re-rotate its gamut.) Delegates to the shared `YCbCrTags`.
    static func sourceIsRec2020(for buffer: CVPixelBuffer) -> Bool {
        YCbCrTags.isRec2020(for: buffer)
    }

    /// sol #4 finding 3: the primary rotation into the Rec.2020 working gamut for
    /// the HDR per-layer linear decode (0 already-2020, 1 709→2020, 2 P3→2020).
    /// Delegates to the shared `YCbCrTags` — one source of truth.
    static func sourcePrimariesRotation(for buffer: CVPixelBuffer) -> UInt32 {
        YCbCrTags.primariesRotationCode(for: buffer)
    }

    /// sol #3 + sol #4 finding 3: the source's transfer for the HDR per-layer linear
    /// decode (0 = Rec.709, 1 = HLG, 2 = PQ, 3 = sRGB, 4 = Linear). Delegates to the
    /// shared `YCbCrTags` — one source of truth. Untagged → 0 (709), unchanged.
    static func sourceTransfer(for buffer: CVPixelBuffer) -> UInt32 {
        YCbCrTags.transferCode(for: buffer)
    }

    /// sol #8 finding #6: 1 when the source's colorspace is a NONLINEAR extended-range
    /// name (`extendedSRGB` / `extendedITUR_2020` / `extendedDisplayP3`) whose > 1
    /// highlights must survive the pre-decode clamp. Delegates to the shared `YCbCrTags`
    /// — one source of truth. Bounded transfers → 0 (pre-clamp unchanged, byte-identical).
    static func sourceExtendedRange(for buffer: CVPixelBuffer) -> UInt32 {
        YCbCrTags.extendedRangeCode(for: buffer)
    }

    /// Normalized canvas rect (top-left origin, y down) → NDC rect
    /// (bottom-left corner + size), for the vertex shader.
    private static func ndcRect(for frame: CGRect) -> SIMD4<Float> {
        SIMD4(Float(frame.minX * 2 - 1),
              Float(1 - 2 * (frame.minY + frame.height)),
              Float(frame.width * 2),
              Float(frame.height * 2))
    }
}
