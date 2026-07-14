import Accelerate
import CoreMedia
import CoreVideo
import Foundation
import Metal
import PrismCore
import PrismVision
import Vision

/// "Green-screen without a green screen": turns a camera/video frame into a
/// premultiplied-alpha **presenter cutout** — the person stays opaque, the
/// background becomes transparent — so it composites over the layers beneath
/// like any other alpha layer (DESIGN.md §2.3 no-green-screen background
/// removal, applied at the *source* level; see `PresenterCutoutSource`).
///
/// This is the reusable engine; `PresenterCutoutSource` wraps an upstream
/// `VideoSource` around it. It is exercised directly (synchronously) by the
/// self-test and unit tests with real photos and injected mattes.
///
/// ## Pipeline
/// 1. `segmentMatte(_:)` runs `VNGeneratePersonSegmentationRequest` (the same
///    request the engine's `PersonSegmenter` uses) and returns a single
///    `OneComponent8` matte (255 = person) or `nil` on a clean no-detection.
/// 2. `composite(frame:matte:)` delegates the matte-apply to the engine's GPU
///    background stage — `PrismVision.BackgroundEffect` — which upscales the
///    (usually lower-res) matte with a Metal linear sampler and writes a
///    **premultiplied** BGRA frame entirely on the GPU:
///    `out.rgb = in.rgb · a`, `out.a = a`. Where `a = 0` the pixel is
///    transparent black `(0,0,0,0)` — *not* opaque black — which is the
///    correct premultiplied-alpha representation of "nothing here", so the
///    layer beneath shows through. `.solidColor` fills the background opaque.
///
/// ## Why the GPU now (was a documented CPU gap)
/// The previous implementation upscaled the matte, feathered, and composited
/// **per pixel on the CPU**, allocating an 8–33 MB `[Float]` alpha array every
/// frame (≈62 ms @4K, 141 ms with feather) — a 4K cutout could not hold 15 fps.
/// The engine already ships a GPU background effect
/// (`PrismVision.BackgroundEffect`, `.remove` / `.replace`) that does exactly
/// this composite zero-copy in Metal, sampling BGRA **and** biplanar YUV
/// natively. This engine now delegates to it: the per-frame `[Float]` heap
/// allocation and the per-pixel CPU composite are gone, and — because
/// `BackgroundEffect` samples YUV natively — YUV camera formats now work (the
/// old "cutout needs BGRA / YUV fail-softs" gap is closed).
///
/// The full CPU path is retained as `cpuReferenceComposite(frame:matte:)`: it
/// is the automatic fallback when Metal is unavailable, and it is the
/// per-pixel correctness oracle the GPU path is validated against.
///
/// ## Feather
/// `feather` softens the alpha edge. Because `BackgroundEffect` has no spatial
/// matte blur, feathering is applied as a small box blur **at matte resolution**
/// (the Vision matte is far smaller than the frame — no 4K `[Float]` array, and
/// scratch buffers are reused across frames) before the matte is handed to the
/// GPU. `feather == 0` (the default live case) does **zero** CPU pixel work.
///
/// Thread model: NOT thread-safe — one instance per pipeline (holds a single
/// `BackgroundEffect`, like every PrismVision stage). `segmentMatte` and
/// `composite` may be called from any single thread; `PresenterCutoutSource`
/// serialises them on its worker queue.
public final class PresenterCutout {
    /// Segmentation quality (maps 1:1 onto `VNGeneratePersonSegmentationRequest.QualityLevel`).
    public enum Quality: Sendable {
        case fast, balanced, accurate
        var vnLevel: VNGeneratePersonSegmentationRequest.QualityLevel {
            switch self {
            case .fast: return .fast
            case .balanced: return .balanced
            case .accurate: return .accurate
            }
        }
    }

    /// What fills the background (matte ≈ 0) of the emitted frame.
    public enum Background: Sendable, Equatable {
        /// Alpha-out the background → premultiplied transparent (the cutout).
        case transparent
        /// Composite the person over a solid opaque colour (output alpha = 255).
        case solidColor(RGBAColor)
    }

    /// What to emit when Vision finds no person in the frame.
    public enum NoPersonBehavior: Sendable, Equatable {
        /// Emit a fully transparent frame (default — a cutout with nobody in it
        /// shows nothing, so the layers beneath are unobstructed).
        case transparent
        /// Pass the input frame through opaque (show the raw feed).
        case passThrough
    }

    /// Tunables. `feather` is the alpha-edge softening radius in output pixels
    /// (0 = the matte's own edge; larger = softer, applied as a separable box
    /// blur on the matte). Clamped to 0…64.
    public struct Options: Sendable {
        public var quality: Quality
        public var background: Background
        public var feather: Float
        public var noPerson: NoPersonBehavior
        public init(quality: Quality = .balanced,
                    background: Background = .transparent,
                    feather: Float = 0,
                    noPerson: NoPersonBehavior = .transparent) {
            self.quality = quality
            self.background = background
            self.feather = feather
            self.noPerson = noPerson
        }
    }

    public var options: Options
    private let log = EngineLog.logger("sources.cutout")
    private var outputPool: PixelBufferPool?

    #if DEBUG
    /// Test-only seam (F13 / Class H): when true, the GPU composite is driven to
    /// fail (the real `BackgroundEffect` status-check throws), so the catch → CPU
    /// recovery path (`cpuFallbackComposite` → `cpuReferenceComposite`) is
    /// exercised end-to-end and its output can be checked against the independent
    /// CPU oracle. No effect in release.
    public var _test_forceGPUExecutionFailure = false
    #endif

    /// Lazily-resolved GPU compositor. `nil` after a failed probe → CPU fallback.
    private enum GPUState { case unprobed, ready(GPUCutout), unavailable }
    private var gpuState: GPUState = .unprobed

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: - Segmentation

    /// Run Vision person segmentation on `frame`. Returns an `OneComponent8`
    /// matte (255 = person) or `nil` on a clean no-detection.
    /// Throws `SourceError.segmentationFailed` if the request itself fails.
    ///
    /// Vision accepts any pixel format here (BGRA or YUV).
    public func segmentMatte(_ frame: VideoFrame) throws -> CVPixelBuffer? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = options.quality.vnLevel
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw SourceError.segmentationFailed(underlying: error)
        }
        guard let observation = request.results?.first else { return nil }
        let raw = observation.pixelBuffer
        guard CVPixelBufferGetPixelFormatType(raw) == kCVPixelFormatType_OneComponent8 else {
            // Requested OneComponent8; a mismatch means an OS surprise.
            throw SourceError.segmentationSetupFailed(reason: "matte not OneComponent8")
        }
        return raw
    }

    // MARK: - Public compositing

    /// Full cutout: segment then composite. On a clean no-detection, applies
    /// `options.noPerson`.
    public func cutout(from frame: VideoFrame) throws -> VideoFrame {
        let matte = try segmentMatte(frame)
        return try composite(frame: frame, matte: matte)
    }

    /// Apply `matte` (any resolution, `OneComponent8`, 255 = person; `nil` = no
    /// person) to `frame`, producing a premultiplied BGRA cutout **on the GPU**
    /// (`PrismVision.BackgroundEffect`). This is the injectable path the tests
    /// drive with a known matte.
    ///
    /// Accepts BGRA and biplanar YUV frames on **both** paths: the GPU samples
    /// both natively, and when Metal is unavailable the CPU fallback
    /// (`cpuFallbackComposite`) converts biplanar YUV → BGRA first, so the
    /// documented BGRA-and-YUV contract holds with or without a GPU.
    public func composite(frame: VideoFrame, matte: CVPixelBuffer?) throws -> VideoFrame {
        guard let matte else {
            switch options.noPerson {
            case .passThrough:
                return frame // raw feed, unchanged (still IOSurface, opaque)
            case .transparent:
                return try makeUniformFrame(like: frame, alpha: 0)
            }
        }

        if let gpu = gpuCutout() {
            do {
                var forceFailure = false
                #if DEBUG
                forceFailure = _test_forceGPUExecutionFailure
                #endif
                return try gpu.composite(frame: frame, matte: matte, options: options,
                                         forceExecutionFailure: forceFailure)
            } catch {
                // GPU render error on a live frame: rather than dropping it,
                // recover on the CPU (converting biplanar YUV → BGRA first if
                // needed). Only if the CPU path *also* fails do we surface the
                // original GPU error as `.gpuCompositeFailed`.
                if let recovered = try? cpuFallbackComposite(frame: frame, matte: matte) {
                    log.error("GPU composite failed (\(String(describing: error), privacy: .public)) — recovered on CPU")
                    return recovered
                }
                throw SourceError.gpuCompositeFailed(underlying: error)
            }
        }
        // Metal unavailable → CPU fallback (converts YUV → BGRA first if needed).
        return try cpuFallbackComposite(frame: frame, matte: matte)
    }

    /// Resolve (once) the GPU compositor, caching a failed probe so we do not
    /// retry `MTLCreateSystemDefaultDevice` / pipeline build every frame.
    private func gpuCutout() -> GPUCutout? {
        switch gpuState {
        case .ready(let g): return g
        case .unavailable: return nil
        case .unprobed:
            guard let device = MTLCreateSystemDefaultDevice() else {
                log.error("no Metal device — presenter cutout falls back to CPU compositing")
                gpuState = .unavailable
                return nil
            }
            do {
                let g = try GPUCutout(device: device)
                gpuState = .ready(g)
                return g
            } catch {
                log.error("GPU cutout init failed (\(String(describing: error), privacy: .public)) — CPU fallback")
                gpuState = .unavailable
                return nil
            }
        }
    }

    // MARK: - CPU reference / fallback compositor

    /// The Metal-unavailable fallback composite (also the recovery path for a GPU
    /// render error). Converts a biplanar YUV frame (420f / 420v) to BGRA on the
    /// CPU using the **same chroma-siting/upsampling contract as the GPU**
    /// (`convertedToBGRA`) when needed — a no-op for BGRA input — so the no-GPU
    /// path honours the **same BGRA-and-YUV input contract** the GPU path
    /// advertises AND decodes spatial frames to the same pixels, then runs
    /// `cpuReferenceComposite`. Throws `.unsupportedInputFormat` only for a
    /// genuinely unknown pixel format.
    ///
    /// `public` so the no-Metal path is directly exercisable on a Metal-capable
    /// machine (the tests drive it to prove the YUV fallback), and so callers
    /// that already know Metal is absent can invoke it without the GPU probe.
    public func cpuFallbackComposite(frame: VideoFrame, matte: CVPixelBuffer?) throws -> VideoFrame {
        let bgra = try convertedToBGRA(frame)
        return try cpuReferenceComposite(frame: bgra, matte: matte)
    }

    /// Return `frame` unchanged if it is already `kCVPixelFormatType_32BGRA`;
    /// otherwise convert a biplanar 4:2:0 YUV frame (420f full-range / 420v
    /// video-range) to an IOSurface-backed BGRA `VideoFrame` on the CPU.
    ///
    /// ## Shared chroma-siting + upsampling contract (F11)
    /// This decodes with the **same** contract as the GPU path
    /// (`PrismVision.VisionShaders.sample_yuv`, driven by `BackgroundEffect`):
    ///  - **Siting:** Metal texel-centre — the half-resolution chroma sample `c`
    ///    is located at normalized `(c + 0.5) / cW` (interstitial: it sits at the
    ///    centre of its 2×2 luma block).
    ///  - **Upsampling:** clamp-to-edge **bilinear** — each output pixel samples
    ///    the chroma plane at its own centre `((x+0.5)/w, (y+0.5)/h)`, exactly as
    ///    the GPU's `filter::linear` sampler does. Luma is full-resolution, so at
    ///    a pixel centre its bilinear reduces to the exact texel.
    ///  - **Matrix:** the identical hand-coded BT.709 full/video-range transform
    ///    the shader uses (NOT vImage's `ITU_R_709_2` path, which sites and
    ///    upsamples chroma differently — the source of the prior ~160-code GPU/CPU
    ///    divergence on spatially-varying frames).
    ///
    /// So a spatially-varying 420f/420v frame now decodes to the same BGRA on the
    /// GPU and CPU within a code or two. Throws `.unsupportedInputFormat` for any
    /// other format.
    private func convertedToBGRA(_ frame: VideoFrame) throws -> VideoFrame {
        let fmt = frame.pixelFormat
        if fmt == kCVPixelFormatType_32BGRA { return frame }

        let fullRange: Bool
        switch fmt {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:  fullRange = true
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: fullRange = false
        default: throw SourceError.unsupportedInputFormat(fmt)
        }

        let src = frame.pixelBuffer
        guard CVPixelBufferGetPlaneCount(src) == 2 else {
            throw SourceError.unsupportedInputFormat(fmt)
        }
        let w = frame.width, h = frame.height
        let output = try makeOutputBuffer(width: w, height: h) // BGRA, IOSurface-backed

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(output, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(src, 0)?.assumingMemoryBound(to: UInt8.self),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(src, 1)?.assumingMemoryBound(to: UInt8.self),
              let outBase = CVPixelBufferGetBaseAddress(output)?.assumingMemoryBound(to: UInt8.self) else {
            throw SourceError.contextCreationFailed
        }
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(src, 0)
        let cRow = CVPixelBufferGetBytesPerRowOfPlane(src, 1)
        let cW = CVPixelBufferGetWidthOfPlane(src, 1)
        let cH = CVPixelBufferGetHeightOfPlane(src, 1)
        let outRow = CVPixelBufferGetBytesPerRow(output)
        guard cW > 0, cH > 0 else { throw SourceError.unsupportedInputFormat(fmt) }

        // sol #3 finding 2: honor the source's tagged YCbCr matrix + horizontal
        // chroma siting (same shared `YCbCrTags` the GPU path uses) so a GPU-fault
        // recovery of a 601/2020/left-sited source produces the SAME color as the
        // GPU, not a hardcoded-709 hue + half-pixel shift.
        Self.decodeBiplanarYUVToBGRA(
            yBase: yBase, yRow: yRow,
            cBase: cBase, cRow: cRow, cW: cW, cH: cH,
            outBase: outBase, outRow: outRow,
            width: w, height: h, fullRange: fullRange,
            matrix: YCbCrTags.matrixCode(for: src),
            leftSited: YCbCrTags.isLeftSited(for: src))

        // sol #4 finding 1: the decode lands in the source's primaries, so carry the
        // colorimetry tags onto the derived BGRA (the composite pass propagates them
        // onward) — else the CPU-recovered frame reads untagged and the HDR
        // compositor double-rotates a Rec.2020 source 709→2020.
        YCbCrTags.propagateColorTags(from: src, to: output)
        return VideoFrame(pixelBuffer: output, pts: frame.pts,
                          duration: frame.duration, source: frame.source)
    }

    /// Decode a locked biplanar 420 frame into a locked BGRA buffer using the
    /// shared chroma-siting/upsampling contract documented on `convertedToBGRA`
    /// (clamp-to-edge bilinear chroma at pixel centres + the shader's BT.709
    /// matrix). Byte-for-byte mirror of `PrismVision.VisionShaders.sample_yuv`
    /// → premultiplied write, so the GPU and CPU cutouts agree on spatial frames.
    private static func decodeBiplanarYUVToBGRA(
        yBase: UnsafePointer<UInt8>, yRow: Int,
        cBase: UnsafePointer<UInt8>, cRow: Int, cW: Int, cH: Int,
        outBase: UnsafeMutablePointer<UInt8>, outRow: Int,
        width w: Int, height h: Int, fullRange: Bool,
        matrix: UInt32 = 0, leftSited: Bool = false) {

        @inline(__always) func clampIdx(_ v: Int, _ hi: Int) -> Int { Swift.min(Swift.max(v, 0), hi) }

        // sol #3 finding 2: YCbCr→RGB coefficients for the tagged matrix
        // (0 BT.709 · 1 BT.601 · 2 BT.2020), IDENTICAL to the shared
        // `ColorShaders`/compositor `prism_yuv_to_rgb` values (709 default =
        // byte-identical to the pre-fix path).
        //  full range: r = y + a·Cr, g = y − b·Cb − c·Cr, b = y + d·Cb
        //  video range: yv = 1.1644·(y−16/255), same shape with the video coeffs
        let (fa, fb, fc, fd): (Double, Double, Double, Double)
        let (va, vb, vc, vd): (Double, Double, Double, Double)
        switch matrix {
        case 1: // BT.601
            (fa, fb, fc, fd) = (1.402, 0.344136, 0.714136, 1.772)
            (va, vb, vc, vd) = (1.596, 0.391, 0.813, 2.017)
        case 2: // BT.2020
            (fa, fb, fc, fd) = (1.4746, 0.16455, 0.57135, 1.8814)
            (va, vb, vc, vd) = (1.6787, 0.1873, 0.6504, 2.1418)
        default: // BT.709
            (fa, fb, fc, fd) = (1.5748, 0.1873, 0.4681, 1.8556)
            (va, vb, vc, vd) = (1.7927, 0.2132, 0.5329, 2.1124)
        }
        // Horizontal chroma siting: a left/co-sited source samples half a luma
        // pixel to the right (normalized +0.5/w), matching the GPU `chromaOffsetX`.
        // Vertical stays centered/interstitial (documented limitation).
        let offX = leftSited && w > 0 ? 0.5 / Double(w) : 0.0

        for y in 0..<h {
            // Chroma row siting: uv.y = (y+0.5)/h → chroma texel coord uv.y*cH-0.5.
            let fy = (Double(y) + 0.5) / Double(h) * Double(cH) - 0.5
            let yf = floor(fy)
            let ty = fy - yf
            let cy0 = clampIdx(Int(yf), cH - 1)
            let cy1 = clampIdx(Int(yf) + 1, cH - 1)
            let cRow0 = cBase + cy0 * cRow
            let cRow1 = cBase + cy1 * cRow
            let yRowPtr = yBase + y * yRow
            let outRowPtr = outBase + y * outRow

            for x in 0..<w {
                // Luma is full-res: at the pixel centre its bilinear == exact texel.
                let yn = Double(yRowPtr[x]) / 255.0

                let fx = ((Double(x) + 0.5) / Double(w) + offX) * Double(cW) - 0.5
                let xf = floor(fx)
                let tx = fx - xf
                let cx0 = clampIdx(Int(xf), cW - 1)
                let cx1 = clampIdx(Int(xf) + 1, cW - 1)

                // Bilinear over the four CbCr samples (Cb = byte0, Cr = byte1).
                @inline(__always) func bilerp(_ off: Int) -> Double {
                    let s00 = Double(cRow0[cx0 * 2 + off])
                    let s10 = Double(cRow0[cx1 * 2 + off])
                    let s01 = Double(cRow1[cx0 * 2 + off])
                    let s11 = Double(cRow1[cx1 * 2 + off])
                    let top = s00 * (1 - tx) + s10 * tx
                    let bot = s01 * (1 - tx) + s11 * tx
                    return top * (1 - ty) + bot * ty
                }
                let cbcrX = bilerp(0) / 255.0 - 128.0 / 255.0   // Cb - 128/255
                let cbcrY = bilerp(1) / 255.0 - 128.0 / 255.0   // Cr - 128/255

                let r: Double, g: Double, b: Double
                if fullRange {
                    r = yn + fa * cbcrY
                    g = yn - fb * cbcrX - fc * cbcrY
                    b = yn + fd * cbcrX
                } else {
                    let yv = 1.1644 * (yn - 16.0 / 255.0)
                    r = yv + va * cbcrY
                    g = yv - vb * cbcrX - vc * cbcrY
                    b = yv + vd * cbcrX
                }
                @inline(__always) func b8(_ v: Double) -> UInt8 {
                    UInt8((Swift.min(Swift.max(v, 0), 1) * 255).rounded())
                }
                let op = outRowPtr + x * 4   // BGRA byte order, opaque (tags carried below)
                op[0] = b8(b); op[1] = b8(g); op[2] = b8(r); op[3] = 255
            }
        }
    }

    /// The original per-pixel premultiplied CPU compositor. Retained as the
    /// per-pixel correctness oracle the GPU path is validated against and as the
    /// engine underneath `cpuFallbackComposite`. Requires
    /// `kCVPixelFormatType_32BGRA` input (throws `.unsupportedInputFormat`
    /// otherwise) — YUV frames are converted to BGRA by `cpuFallbackComposite`
    /// before they reach here, so this stays a pure BGRA compositor/oracle.
    public func cpuReferenceComposite(frame: VideoFrame, matte: CVPixelBuffer?) throws -> VideoFrame {
        guard frame.pixelFormat == kCVPixelFormatType_32BGRA else {
            throw SourceError.unsupportedInputFormat(frame.pixelFormat)
        }
        guard let matte else {
            switch options.noPerson {
            case .passThrough: return frame
            case .transparent: return try makeUniformFrame(like: frame, alpha: 0)
            }
        }
        let w = frame.width, h = frame.height
        // 1. Upscale matte → per-pixel alpha in [0,1].
        var alpha = upscaledAlpha(matte: matte, width: w, height: h)
        // 2. Feather the alpha edge (separable box blur), if requested.
        let radius = Int(min(max(options.feather, 0), 64).rounded())
        if radius > 0 { boxBlur(&alpha, width: w, height: h, radius: radius) }
        // 3. Composite premultiplied.
        return try compositeCPU(frame: frame, alpha: alpha)
    }

    private func compositeCPU(frame: VideoFrame, alpha: [Float]) throws -> VideoFrame {
        let w = frame.width, h = frame.height
        let output = try makeOutputBuffer(width: w, height: h)

        let inBuf = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(inBuf, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(output, [])
            CVPixelBufferUnlockBaseAddress(inBuf, .readOnly)
        }
        guard let inBase = CVPixelBufferGetBaseAddress(inBuf)?.assumingMemoryBound(to: UInt8.self),
              let outBase = CVPixelBufferGetBaseAddress(output)?.assumingMemoryBound(to: UInt8.self) else {
            throw SourceError.contextCreationFailed
        }
        let inRow = CVPixelBufferGetBytesPerRow(inBuf)
        let outRow = CVPixelBufferGetBytesPerRow(output)

        // Solid-colour fill (BGRA byte order), premultiplied by (1-a) per pixel.
        var fill: (b: Float, g: Float, r: Float)? = nil
        if case .solidColor(let c) = options.background {
            fill = (b: Float(c.b) * 255, g: Float(c.g) * 255, r: Float(c.r) * 255)
        }

        for y in 0..<h {
            let inRowPtr = inBase + y * inRow
            let outRowPtr = outBase + y * outRow
            let alphaRow = y * w
            for x in 0..<w {
                let a = alpha[alphaRow + x] // already clamped 0…1
                let ip = inRowPtr + x * 4
                let op = outRowPtr + x * 4
                let ib = Float(ip[0]), ig = Float(ip[1]), ir = Float(ip[2])
                if let fill {
                    // Opaque composite over solid colour: out = in·a + bg·(1-a).
                    let inv = 1 - a
                    op[0] = UInt8((ib * a + fill.b * inv).rounded().clampedByte)
                    op[1] = UInt8((ig * a + fill.g * inv).rounded().clampedByte)
                    op[2] = UInt8((ir * a + fill.r * inv).rounded().clampedByte)
                    op[3] = 255
                } else {
                    // Premultiplied transparent: out.rgb = in.rgb·a, out.a = a.
                    op[0] = UInt8((ib * a).rounded().clampedByte)
                    op[1] = UInt8((ig * a).rounded().clampedByte)
                    op[2] = UInt8((ir * a).rounded().clampedByte)
                    op[3] = UInt8((a * 255).rounded().clampedByte)
                }
            }
        }
        // sol #4 finding 1: the composite keeps the source's own primaries rgb, so
        // carry its colorimetry tags forward (input already tagged by convertedToBGRA
        // for YUV, or the original BGRA source) — no HDR double-rotation downstream.
        YCbCrTags.propagateColorTags(from: inBuf, to: output)
        return VideoFrame(pixelBuffer: output, pts: frame.pts,
                          duration: frame.duration, source: frame.source)
    }

    /// A frame of the same size/pts as `frame`, filled with a uniform alpha
    /// (0 → transparent black). Used for the no-person transparent path.
    private func makeUniformFrame(like frame: VideoFrame, alpha: UInt8) throws -> VideoFrame {
        let w = frame.width, h = frame.height
        let output = try makeOutputBuffer(width: w, height: h)
        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let base = CVPixelBufferGetBaseAddress(output)?.assumingMemoryBound(to: UInt8.self) else {
            throw SourceError.contextCreationFailed
        }
        let row = CVPixelBufferGetBytesPerRow(output)
        // Premultiplied: rgb must be 0 when transparent. For any uniform alpha
        // with no colour, rgb = 0 is correct (nothing to show).
        for y in 0..<h {
            let p = base + y * row
            if alpha == 0 {
                memset(p, 0, w * 4)
            } else {
                for x in 0..<w { let q = p + x * 4; q[0] = 0; q[1] = 0; q[2] = 0; q[3] = alpha }
            }
        }
        // sol #4 finding 1: keep the colorimetry tags consistent with the source on
        // the derived frame (the pixels are neutral transparent/black, so this is
        // colorspace-safe and avoids an untagged frame reaching the compositor).
        YCbCrTags.propagateColorTags(from: frame.pixelBuffer, to: output)
        return VideoFrame(pixelBuffer: output, pts: frame.pts,
                          duration: frame.duration, source: frame.source)
    }

    // MARK: - Matte upscale + feather (CPU reference only)

    /// Bilinearly upscale an `OneComponent8` matte to `width`×`height`, returning
    /// normalised alpha in [0,1]. At identity scale this reproduces the matte
    /// exactly at pixel centres (so tests can isolate feather).
    private func upscaledAlpha(matte: CVPixelBuffer, width: Int, height: Int) -> [Float] {
        CVPixelBufferLockBaseAddress(matte, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(matte, .readOnly) }
        let mW = CVPixelBufferGetWidth(matte)
        let mH = CVPixelBufferGetHeight(matte)
        var out = [Float](repeating: 0, count: width * height)
        guard mW > 0, mH > 0,
              let base = CVPixelBufferGetBaseAddress(matte)?.assumingMemoryBound(to: UInt8.self) else {
            return out
        }
        let mRow = CVPixelBufferGetBytesPerRow(matte)
        let sx = Double(mW) / Double(width)
        let sy = Double(mH) / Double(height)
        @inline(__always) func sample(_ ix: Int, _ iy: Int) -> Double {
            let cx = min(max(ix, 0), mW - 1)
            let cy = min(max(iy, 0), mH - 1)
            return Double(base[cy * mRow + cx])
        }
        for oy in 0..<height {
            let fy = (Double(oy) + 0.5) * sy - 0.5
            let y0 = Int(floor(fy)); let ty = fy - Double(y0)
            let rowOff = oy * width
            for ox in 0..<width {
                let fx = (Double(ox) + 0.5) * sx - 0.5
                let x0 = Int(floor(fx)); let tx = fx - Double(x0)
                let top = sample(x0, y0) * (1 - tx) + sample(x0 + 1, y0) * tx
                let bot = sample(x0, y0 + 1) * (1 - tx) + sample(x0 + 1, y0 + 1) * tx
                out[rowOff + ox] = Float((top * (1 - ty) + bot * ty) / 255.0)
            }
        }
        return out
    }

    /// Separable box blur (horizontal then vertical) with a running-sum window
    /// of ±`radius`, edges clamped. A single box pass turns a hard alpha step
    /// into a linear ramp of width ≈ 2·radius — the feather.
    private func boxBlur(_ a: inout [Float], width: Int, height: Int, radius: Int) {
        let window = Float(2 * radius + 1)
        var tmp = [Float](repeating: 0, count: width * height)
        // Horizontal.
        for y in 0..<height {
            let row = y * width
            var sum: Float = 0
            for i in 0...radius { sum += a[row + min(i, width - 1)] }
            // Prime with the left-clamped window [-radius … +radius] at x = 0.
            sum += a[row] * Float(radius) // taps -radius…-1 all clamp to column 0
            for x in 0..<width {
                tmp[row + x] = sum / window
                let addIdx = min(x + radius + 1, width - 1)
                let subIdx = max(x - radius, 0)
                sum += a[row + addIdx] - a[row + subIdx]
            }
        }
        // Vertical.
        for x in 0..<width {
            var sum: Float = 0
            for i in 0...radius { sum += tmp[min(i, height - 1) * width + x] }
            sum += tmp[x] * Float(radius)
            for y in 0..<height {
                a[y * width + x] = sum / window
                let addIdx = min(y + radius + 1, height - 1)
                let subIdx = max(y - radius, 0)
                sum += tmp[addIdx * width + x] - tmp[subIdx * width + x]
            }
        }
    }

    // MARK: - Pools

    private func makeOutputBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        if outputPool == nil || outputPool!.width != width || outputPool!.height != height {
            do {
                outputPool = try PixelBufferPool(width: width, height: height,
                                                 pixelFormat: kCVPixelFormatType_32BGRA,
                                                 minimumBufferCount: 4)
            } catch { throw SourceError.canvasCreationFailed(reason: "\(error)") }
        }
        do { return try outputPool!.makeBuffer() }
        catch { throw SourceError.canvasCreationFailed(reason: "\(error)") }
    }
}

// MARK: - GPU cutout (delegates to PrismVision.BackgroundEffect)

/// Wraps the engine's GPU background stage for the presenter cutout: prepares
/// the matte (optionally feathered at matte resolution, always IOSurface-backed
/// `OneComponent8`) and calls `BackgroundEffect.apply` — `.remove` for a
/// transparent cutout, `.replace` for a solid-colour fill. All per-pixel work
/// (matte upscale + premultiplied composite) runs zero-copy in Metal; the CPU
/// never touches frame pixels here. NOT thread-safe (one per `PresenterCutout`).
private final class GPUCutout {
    private let effect: BackgroundEffect
    /// Pool for prepared (feathered / normalised) mattes, keyed by matte size.
    private var mattePool: PixelBufferPool?
    private var matteW = 0, matteH = 0
    /// Reused blur scratch (matte-resolution, NOT frame-resolution — reallocated
    /// only when the matte size changes, so no per-frame heap allocation).
    private var scratchIn: [Float] = []
    private var scratchTmp: [Float] = []

    init(device: MTLDevice) throws {
        self.effect = try BackgroundEffect(device: device)
    }

    func composite(frame: VideoFrame, matte rawMatte: CVPixelBuffer,
                   options: PresenterCutout.Options,
                   forceExecutionFailure: Bool = false) throws -> VideoFrame {
        #if DEBUG
        effect._test_forceExecutionFailure = forceExecutionFailure
        #endif
        let seg = try prepareMatte(rawMatte, frame: frame, feather: options.feather)
        let mode: BackgroundMode
        switch options.background {
        case .transparent:
            mode = .remove
        case .solidColor(let c):
            mode = .replace(color: SIMD3<Float>(Float(c.r), Float(c.g), Float(c.b)))
        }
        return try effect.apply(frame: frame, matte: seg, mode: mode)
    }

    /// Produce an IOSurface-backed `OneComponent8` `SegmentationMatte` for the
    /// GPU. Fast path (feather 0 + already IOSurface): wrap the raw matte with
    /// zero copies. Otherwise copy into a pooled buffer, box-blurring at matte
    /// resolution when feathering.
    private func prepareMatte(_ raw: CVPixelBuffer, frame: VideoFrame,
                              feather: Float) throws -> SegmentationMatte {
        let mW = CVPixelBufferGetWidth(raw)
        let mH = CVPixelBufferGetHeight(raw)
        // Feather radius is specified in OUTPUT pixels; scale to matte resolution
        // so an identity-scale (full-res) matte matches the CPU reference exactly.
        let outRadius = min(max(feather, 0), 64)
        let matteRadius = mW > 0 && frame.width > 0
            ? Int((outRadius * Float(mW) / Float(frame.width)).rounded())
            : 0

        if matteRadius == 0, CVPixelBufferGetIOSurface(raw) != nil {
            return SegmentationMatte(pixelBuffer: raw, pts: frame.pts, source: frame.source)
        }

        let dst = try pooledMatte(width: mW, height: mH)
        CVPixelBufferLockBaseAddress(raw, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(raw, .readOnly)
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(raw)?.assumingMemoryBound(to: UInt8.self),
              let dstBase = CVPixelBufferGetBaseAddress(dst)?.assumingMemoryBound(to: UInt8.self) else {
            throw SourceError.contextCreationFailed
        }
        let srcRow = CVPixelBufferGetBytesPerRow(raw)
        let dstRow = CVPixelBufferGetBytesPerRow(dst)

        if matteRadius == 0 {
            // Normalise-only copy (raw matte lacked an IOSurface).
            for y in 0..<mH { memcpy(dstBase + y * dstRow, srcBase + y * srcRow, min(srcRow, dstRow)) }
        } else {
            boxBlurMatte(srcBase: srcBase, srcRow: srcRow,
                         dstBase: dstBase, dstRow: dstRow,
                         width: mW, height: mH, radius: matteRadius)
        }
        return SegmentationMatte(pixelBuffer: dst, pts: frame.pts, source: frame.source)
    }

    private func pooledMatte(width: Int, height: Int) throws -> CVPixelBuffer {
        if mattePool == nil || matteW != width || matteH != height {
            do {
                mattePool = try PixelBufferPool(width: width, height: height,
                                                pixelFormat: kCVPixelFormatType_OneComponent8,
                                                minimumBufferCount: 4)
                matteW = width; matteH = height
            } catch { throw SourceError.canvasCreationFailed(reason: "\(error)") }
        }
        do { return try mattePool!.makeBuffer() }
        catch { throw SourceError.canvasCreationFailed(reason: "\(error)") }
    }

    /// Separable box blur of a `OneComponent8` matte (running-sum, ±`radius`,
    /// edges clamped) into `dst` — the matte-resolution analogue of the CPU
    /// reference's alpha feather. Scratch is reused across frames.
    private func boxBlurMatte(srcBase: UnsafePointer<UInt8>, srcRow: Int,
                              dstBase: UnsafeMutablePointer<UInt8>, dstRow: Int,
                              width: Int, height: Int, radius: Int) {
        let n = width * height
        if scratchIn.count != n { scratchIn = [Float](repeating: 0, count: n) }
        if scratchTmp.count != n { scratchTmp = [Float](repeating: 0, count: n) }
        let window = Float(2 * radius + 1)

        scratchIn.withUnsafeMutableBufferPointer { inp in
            scratchTmp.withUnsafeMutableBufferPointer { tmp in
                let a = inp.baseAddress!
                let t = tmp.baseAddress!
                // Load matte → float [0,1].
                for y in 0..<height {
                    let r = srcBase + y * srcRow
                    let o = y * width
                    for x in 0..<width { a[o + x] = Float(r[x]) / 255.0 }
                }
                // Horizontal.
                for y in 0..<height {
                    let row = y * width
                    var sum: Float = 0
                    for i in 0...radius { sum += a[row + min(i, width - 1)] }
                    sum += a[row] * Float(radius)
                    for x in 0..<width {
                        t[row + x] = sum / window
                        let addIdx = min(x + radius + 1, width - 1)
                        let subIdx = max(x - radius, 0)
                        sum += a[row + addIdx] - a[row + subIdx]
                    }
                }
                // Vertical → write straight to the matte buffer (bytes).
                for x in 0..<width {
                    var sum: Float = 0
                    for i in 0...radius { sum += t[min(i, height - 1) * width + x] }
                    sum += t[x] * Float(radius)
                    for y in 0..<height {
                        let v = sum / window
                        (dstBase + y * dstRow)[x] = UInt8((v * 255).rounded().clampedByte)
                        let addIdx = min(y + radius + 1, height - 1)
                        let subIdx = max(y - radius, 0)
                        sum += t[addIdx * width + x] - t[subIdx * width + x]
                    }
                }
            }
        }
    }
}

private extension Float {
    /// Clamp to a valid 0…255 byte value.
    var clampedByte: Float { Swift.min(Swift.max(self, 0), 255) }
}
