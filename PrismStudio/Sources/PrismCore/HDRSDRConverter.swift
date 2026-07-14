import CoreVideo
import Foundation
import Metal

/// The ONE shared HDR↔SDR colour converter (sol #6 #4 + #5).
///
/// Two Prism paths need to turn HDR pixels into real SDR pixels (and back), and
/// both were previously only RELABELLING — changing tags / bit-depth / layout
/// without touching the colour values:
///   * the virtual camera (`VCamFormatConverter`): an HDR `l10r` program under a
///     BGRA/420v negotiation, or an SDR BGRA program under an `l10r` negotiation,
///     was fed through `VTPixelTransferSession`, which does bit-depth + chroma but
///     NOT a transfer/gamut conversion — so HLG code 726 landed at 8-bit 182
///     still tagged HLG, and sRGB 128 landed at 10-bit 514 still tagged sRGB.
///   * the classic-RTMP "SDR fallback": an HDR program frame was handed UNCHANGED
///     to an SDR H.264 encoder, so the decoded gray was 182 (from HLG 726) not
///     SDR ~128.
///
/// This utility performs the REAL conversion so the pixels AND the tags are
/// truthful for the destination dynamic range. It is a naive-but-self-consistent
/// model that maps the SDR luma range onto the full HLG signal range (SDR white
/// ↔ HLG peak); the ONLY colours that leave [0,1] are wide-gamut Rec.2020 ones,
/// which the highlight tone-map rolls back into the Rec.709 gamut. A physically-
/// referred HLG OOTF / nominal-peak grade is a future refinement and is
/// UNVERIFIED-until-hardware (needs a real HDR display pass).
///
/// Spec anchors (independent oracle re-derivation lives in the tests):
///   * sRGB EOTF/OETF — IEC 61966-2-1
///   * HLG OETF / inverse-OETF — ITU-R BT.2100 / ARIB STD-B67
///   * BT.709↔BT.2020 primary matrices — ITU-R BT.709/2020 (Bradford-adapted D65)
///
/// Neutral round-trip is EXACT: sRGB 128 → HLG code 726 → sRGB 128 (the gamut
/// step is identity on the neutral axis and mid-tones sit below the tone-map
/// knee, so only the forward/inverse transfer functions act).
public enum HDRSDRConverter {

    // MARK: - Pure scalar transfer functions

    /// sRGB EOTF (IEC 61966-2-1): non-linear code fraction [0,1] → display-linear.
    @inline(__always) public static func srgbEOTF(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : Foundation.pow((c + 0.055) / 1.055, 2.4)
    }

    /// sRGB OETF (inverse EOTF): display-linear [0,1] → non-linear code fraction.
    @inline(__always) public static func srgbOETF(_ v: Double) -> Double {
        let x = max(0.0, v)
        return x <= 0.0031308 ? 12.92 * x : 1.055 * Foundation.pow(x, 1.0 / 2.4) - 0.055
    }

    /// BT.2100 HLG OETF (ARIB STD-B67): scene-linear [0,1] → non-linear signal.
    @inline(__always) public static func hlgOETF(_ e: Double) -> Double {
        let a = 0.17883277, b = 0.28466892, c = 0.55991073
        let x = max(0.0, min(1.0, e))
        return x <= 1.0 / 12.0 ? (3.0 * x).squareRoot() : a * Foundation.log(12.0 * x - b) + c
    }

    /// BT.2100 HLG inverse-OETF: non-linear signal [0,1] → scene-linear [0,1].
    @inline(__always) public static func hlgInverseOETF(_ x: Double) -> Double {
        let a = 0.17883277, b = 0.28466892, c = 0.55991073
        let s = max(0.0, min(1.0, x))
        return s <= 0.5 ? (s * s) / 3.0 : (Foundation.exp((s - c) / a) + b) / 12.0
    }

    /// Highlight tone-map: identity below the knee, a smooth `tanh` shoulder above
    /// it that asymptotes to 1.0 — so wide-gamut Rec.2020 channels pushed past the
    /// Rec.709 gamut (and near-peak highlights) roll off instead of hard-clipping.
    /// The knee is high enough that all mid-tones (incl. the 726↔128 neutral
    /// oracle) pass through unchanged.
    public static let toneMapKnee = 0.8
    @inline(__always) public static func toneMapHighlight(_ x: Double) -> Double {
        let v = max(0.0, x)
        let k = toneMapKnee
        if v <= k { return v }
        return k + (1.0 - k) * Foundation.tanh((v - k) / (1.0 - k))
    }

    // MARK: - Primary matrices (rows sum to 1 → neutral axis preserved)

    /// Linear Rec.709/sRGB primaries → linear Rec.2020 primaries.
    @inline(__always) static func rec709ToRec2020(_ r: Double, _ g: Double, _ b: Double)
        -> (Double, Double, Double) {
        (0.627404 * r + 0.329283 * g + 0.043313 * b,
         0.069097 * r + 0.919540 * g + 0.011362 * b,
         0.016391 * r + 0.088013 * g + 0.895595 * b)
    }

    /// Linear Rec.2020 primaries → linear Rec.709/sRGB primaries (inverse of the
    /// above; ITU-R BT.2020 → BT.709, Bradford-adapted D65).
    @inline(__always) static func rec2020ToRec709(_ r: Double, _ g: Double, _ b: Double)
        -> (Double, Double, Double) {
        ( 1.660491 * r - 0.587641 * g - 0.072850 * b,
         -0.124550 * r + 1.132900 * g - 0.008349 * b,
         -0.018151 * r - 0.100579 * g + 1.118730 * b)
    }

    // MARK: - Per-pixel code conversions (the oracle targets)

    /// One sRGB 8-bit pixel → a Rec.2020 / BT.2100-HLG 10-bit full-range code
    /// triple. Neutral 128 → ≈726. (SDR→HDR.)
    public static func srgb8ToHLG2020Code(r8: UInt8, g8: UInt8, b8: UInt8) -> (UInt32, UInt32, UInt32) {
        let r = srgbEOTF(Double(r8) / 255.0)
        let g = srgbEOTF(Double(g8) / 255.0)
        let b = srgbEOTF(Double(b8) / 255.0)
        let (r2, g2, b2) = rec709ToRec2020(r, g, b)
        @inline(__always) func code(_ e: Double) -> UInt32 {
            UInt32(max(0.0, min(1023.0, (hlgOETF(e) * 1023.0).rounded())))
        }
        return (code(r2), code(g2), code(b2))
    }

    /// One Rec.2020 / BT.2100-HLG 10-bit full-range code triple → an sRGB 8-bit
    /// pixel, with highlight tone-mapping. Neutral 726 → ≈128. (HDR→SDR.)
    public static func hlg2020CodeToSRGB8(r10: UInt32, g10: UInt32, b10: UInt32) -> (UInt8, UInt8, UInt8) {
        // 10-bit full-range signal → scene-linear (Rec.2020 primaries).
        let er = hlgInverseOETF(Double(r10) / 1023.0)
        let eg = hlgInverseOETF(Double(g10) / 1023.0)
        let eb = hlgInverseOETF(Double(b10) / 1023.0)
        // Rec.2020 → Rec.709 primaries (may push wide-gamut channels <0 or >1).
        var (r, g, b) = rec2020ToRec709(er, eg, eb)
        // Highlight/gamut roll-off, then clamp any residual out-of-gamut negative.
        r = toneMapHighlight(r); g = toneMapHighlight(g); b = toneMapHighlight(b)
        @inline(__always) func code(_ v: Double) -> UInt8 {
            UInt8(max(0.0, min(255.0, (srgbOETF(v) * 255.0).rounded())))
        }
        return (code(r), code(g), code(b))
    }

    // MARK: - Buffer conversions

    public enum ConvertError: Error { case lockFailed, unsupportedFormat }

    /// Convert an HDR 10-bit `ARGB2101010LEPacked` (Rec.2020/BT.2100-HLG) buffer
    /// into an 8-bit BGRA buffer of TRUE SDR pixels, tagged sRGB/Rec.709. `pool`
    /// must vend `kCVPixelFormatType_32BGRA` buffers at the same size.
    ///
    /// GPU-accelerated (sol #7): a cached Metal compute pipeline runs the same
    /// HLG-inverse-OETF → Rec.2020→709 → highlight tone-map → sRGB-OETF math the
    /// scalar `hlg2020CodeToSRGB8` does, per-pixel in parallel (~1-2 ms/1080p vs
    /// ~90 ms on the scalar CPU loop). If no Metal device is available, or the GPU
    /// pass faults (Class H command-buffer status), it transparently falls back to
    /// the byte-identical scalar CPU loop (`convertHDRToSDR_BGRA_cpu`). The public
    /// signature is unchanged and synchronous — the GPU dispatch blocks for the
    /// frame, which at ~1-2 ms is cheaper than the cadence budget it was blowing.
    public static func convertHDRToSDR_BGRA(from src: CVPixelBuffer, pool: PixelBufferPool) throws -> CVPixelBuffer {
        guard CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_ARGB2101010LEPacked else {
            throw ConvertError.unsupportedFormat
        }
        let dst = try pool.makeBuffer()
        if let gpu = sharedGPU, (try? gpu.run(gpu.hdrToSDR, src: src, dst: dst)) != nil {
            YCbCrTags.stampSRGB(dst)
            return dst
        }
        try convertHDRToSDR_BGRA_cpu(from: src, into: dst)   // documented CPU fallback
        YCbCrTags.stampSRGB(dst)
        return dst
    }

    /// Convert an 8-bit BGRA (sRGB/Rec.709) buffer into an HDR 10-bit
    /// `ARGB2101010LEPacked` buffer of TRUE HLG/Rec.2020 pixels, tagged
    /// Rec.2020/BT.2100-HLG. `pool` must vend `ARGB2101010LEPacked` buffers.
    ///
    /// GPU-accelerated with the same cache-and-fallback contract as
    /// `convertHDRToSDR_BGRA` (sol #7): the cached Metal pipeline runs the
    /// scalar `srgb8ToHLG2020Code` math per-pixel; falls back to
    /// `convertSDRToHDR_10bit_cpu` when Metal is unavailable or the pass faults.
    public static func convertSDRToHDR_10bit(from src: CVPixelBuffer, pool: PixelBufferPool) throws -> CVPixelBuffer {
        guard CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_32BGRA else {
            throw ConvertError.unsupportedFormat
        }
        let dst = try pool.makeBuffer()
        if let gpu = sharedGPU, (try? gpu.run(gpu.sdrToHDR, src: src, dst: dst)) != nil {
            YCbCrTags.stampHLGRec2020(dst)
            return dst
        }
        try convertSDRToHDR_10bit_cpu(from: src, into: dst)  // documented CPU fallback
        YCbCrTags.stampHLGRec2020(dst)
        return dst
    }

    // MARK: - Scalar CPU fallback (also the perf-test reference baseline)

    /// The original per-pixel scalar HDR→SDR loop. Kept as the documented fallback
    /// (no Metal device / GPU fault) AND as the independent slow reference the
    /// performance test measures the GPU speed-up against. Does NOT stamp tags —
    /// the public wrapper does, so GPU and CPU paths tag identically.
    static func convertHDRToSDR_BGRA_cpu(from src: CVPixelBuffer, into dst: CVPixelBuffer) throws {
        guard CVPixelBufferLockBaseAddress(src, .readOnly) == kCVReturnSuccess else { throw ConvertError.lockFailed }
        guard CVPixelBufferLockBaseAddress(dst, []) == kCVReturnSuccess else {
            CVPixelBufferUnlockBaseAddress(src, .readOnly); throw ConvertError.lockFailed
        }
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(src),
              let dstBase = CVPixelBufferGetBaseAddress(dst) else { throw ConvertError.lockFailed }
        let width = min(CVPixelBufferGetWidth(src), CVPixelBufferGetWidth(dst))
        let height = min(CVPixelBufferGetHeight(src), CVPixelBufferGetHeight(dst))
        let srcStride = CVPixelBufferGetBytesPerRow(src)
        let dstStride = CVPixelBufferGetBytesPerRow(dst)
        for row in 0..<height {
            let srcRow = srcBase.advanced(by: row * srcStride).assumingMemoryBound(to: UInt32.self)
            let dstRow = dstBase.advanced(by: row * dstStride).assumingMemoryBound(to: UInt8.self)
            for col in 0..<width {
                let word = srcRow[col]
                let r10 = (word >> 20) & 0x3FF
                let g10 = (word >> 10) & 0x3FF
                let b10 = word & 0x3FF
                let (r8, g8, b8) = hlg2020CodeToSRGB8(r10: r10, g10: g10, b10: b10)
                let p = col * 4
                dstRow[p] = b8; dstRow[p + 1] = g8; dstRow[p + 2] = r8; dstRow[p + 3] = 255
            }
        }
    }

    /// The original per-pixel scalar SDR→HDR loop. Documented fallback + perf
    /// reference (see `convertHDRToSDR_BGRA_cpu`). Does NOT stamp tags.
    static func convertSDRToHDR_10bit_cpu(from src: CVPixelBuffer, into dst: CVPixelBuffer) throws {
        guard CVPixelBufferLockBaseAddress(src, .readOnly) == kCVReturnSuccess else { throw ConvertError.lockFailed }
        guard CVPixelBufferLockBaseAddress(dst, []) == kCVReturnSuccess else {
            CVPixelBufferUnlockBaseAddress(src, .readOnly); throw ConvertError.lockFailed
        }
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(src),
              let dstBase = CVPixelBufferGetBaseAddress(dst) else { throw ConvertError.lockFailed }
        let width = min(CVPixelBufferGetWidth(src), CVPixelBufferGetWidth(dst))
        let height = min(CVPixelBufferGetHeight(src), CVPixelBufferGetHeight(dst))
        let srcStride = CVPixelBufferGetBytesPerRow(src)
        let dstStride = CVPixelBufferGetBytesPerRow(dst)
        for row in 0..<height {
            let srcRow = srcBase.advanced(by: row * srcStride).assumingMemoryBound(to: UInt8.self)
            let dstRow = dstBase.advanced(by: row * dstStride).assumingMemoryBound(to: UInt32.self)
            for col in 0..<width {
                let p = col * 4
                let (r10, g10, b10) = srgb8ToHLG2020Code(r8: srcRow[p + 2], g8: srcRow[p + 1], b8: srcRow[p])
                dstRow[col] = (UInt32(3) << 30) | (r10 << 20) | (g10 << 10) | b10
            }
        }
    }

    // MARK: - GPU compute engine (cached device / queue / pipelines)

    /// `true` when a Metal device + both compute pipelines are live, so the buffer
    /// conversions run on the GPU. `false` on a headless / device-less host, where
    /// the scalar CPU fallback runs (still correct, just slow). Exposed for the
    /// performance test to require a device-backed path where one exists.
    public static var isGPUAccelerated: Bool { sharedGPU != nil }

    /// One process-wide engine — MTLDevice / library / pipeline creation is
    /// expensive, so it is built once, lazily, and reused for every conversion
    /// (the `sol #7` fix: a dedicated cached pipeline, not a per-frame rebuild).
    /// `nil` if Metal is unavailable → the public entry points take the CPU path.
    static let sharedGPU: GPUEngine? = GPUEngine()

    /// Cached Metal plumbing for the two buffer conversions. Immutable after init
    /// (device, queue, two pipelines); each `run` mints its own command buffer +
    /// staging buffers, so concurrent calls from the render thread are safe.
    final class GPUEngine: @unchecked Sendable {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let hdrToSDR: MTLComputePipelineState
        let sdrToHDR: MTLComputePipelineState

        enum GPUError: Error { case lockFailed, bufferAllocFailed, encodeFailed, executionFailed(Error?) }

        init?() {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let queue = device.makeCommandQueue() else { return nil }
            queue.label = "studio.prism.hdrsdr.convert"
            do {
                let lib = try device.makeLibrary(source: GPUEngine.source, options: MTLCompileOptions())
                guard let fHtoS = lib.makeFunction(name: "prism_hdr_to_sdr"),
                      let fStoH = lib.makeFunction(name: "prism_sdr_to_hdr") else { return nil }
                self.hdrToSDR = try device.makeComputePipelineState(function: fHtoS)
                self.sdrToHDR = try device.makeComputePipelineState(function: fStoH)
            } catch { return nil }
            self.device = device
            self.queue = queue
        }

        /// Uniforms — matches `struct Params` in the shader (all `uint`, tight).
        private struct Params { var width: UInt32; var height: UInt32; var srcStrideBytes: UInt32; var dstStrideBytes: UInt32 }

        /// Run one conversion `pipeline` over `src`→`dst`. Copies the locked source
        /// region into a shared MTLBuffer, dispatches a 2D grid, blocks for
        /// completion, checks Class-H status, then copies the result back into the
        /// pooled destination. Throws on any failure so the caller falls back to CPU.
        func run(_ pipeline: MTLComputePipelineState, src: CVPixelBuffer, dst: CVPixelBuffer) throws {
            guard CVPixelBufferLockBaseAddress(src, .readOnly) == kCVReturnSuccess else { throw GPUError.lockFailed }
            guard CVPixelBufferLockBaseAddress(dst, []) == kCVReturnSuccess else {
                CVPixelBufferUnlockBaseAddress(src, .readOnly); throw GPUError.lockFailed
            }
            defer {
                CVPixelBufferUnlockBaseAddress(dst, [])
                CVPixelBufferUnlockBaseAddress(src, .readOnly)
            }
            guard let srcBase = CVPixelBufferGetBaseAddress(src),
                  let dstBase = CVPixelBufferGetBaseAddress(dst) else { throw GPUError.lockFailed }
            let width = min(CVPixelBufferGetWidth(src), CVPixelBufferGetWidth(dst))
            let height = min(CVPixelBufferGetHeight(src), CVPixelBufferGetHeight(dst))
            let srcStride = CVPixelBufferGetBytesPerRow(src)
            let dstStride = CVPixelBufferGetBytesPerRow(dst)
            let srcLen = srcStride * CVPixelBufferGetHeight(src)
            let dstLen = dstStride * CVPixelBufferGetHeight(dst)

            // Staging buffers (shared storage, zero-copy CPU read-back). The source
            // is copied in respecting its stride; the output is copied back out.
            guard let inBuf = device.makeBuffer(bytes: srcBase, length: srcLen, options: .storageModeShared),
                  let outBuf = device.makeBuffer(length: dstLen, options: .storageModeShared) else {
                throw GPUError.bufferAllocFailed
            }
            var params = Params(width: UInt32(width), height: UInt32(height),
                                srcStrideBytes: UInt32(srcStride), dstStrideBytes: UInt32(dstStride))

            guard let cb = queue.makeCommandBuffer(),
                  let enc = cb.makeComputeCommandEncoder() else { throw GPUError.encodeFailed }
            enc.setComputePipelineState(pipeline)
            enc.setBuffer(inBuf, offset: 0, index: 0)
            enc.setBuffer(outBuf, offset: 0, index: 1)
            enc.setBytes(&params, length: MemoryLayout<Params>.stride, index: 2)
            let tew = pipeline.threadExecutionWidth
            let th = max(pipeline.maxTotalThreadsPerThreadgroup / tew, 1)
            enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: tew, height: th, depth: 1))
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            // Class H — never publish garbage: a non-`.completed` buffer means the
            // GPU faulted; throw so the public wrapper takes the CPU fallback.
            guard cb.status == .completed else { throw GPUError.executionFailed(cb.error) }
            memcpy(dstBase, outBuf.contents(), dstLen)
        }

        /// Embedded MSL (compiled once at init — SPM can't build `.metal` files into
        /// a library target; same runtime-compile pattern as PrismColor/PrismCompositor).
        /// The transfer functions + primary matrices are a line-for-line port of the
        /// scalar Swift ones above; the bit packing/unpacking is byte-identical to the
        /// CPU loops (`(word>>20)&0x3FF`, `(3<<30)|(r10<<20)|(g10<<10)|b10`), so the
        /// only CPU/GPU divergence is float-vs-double transfer math (±1 code, the
        /// tolerance the oracle tests already allow at the buffer level).
        static let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct Params { uint width; uint height; uint srcStrideBytes; uint dstStrideBytes; };

        inline float srgbEOTF(float c) {
            return c <= 0.04045f ? c / 12.92f : pow((c + 0.055f) / 1.055f, 2.4f);
        }
        inline float srgbOETF(float v) {
            float x = max(0.0f, v);
            return x <= 0.0031308f ? 12.92f * x : 1.055f * pow(x, 1.0f / 2.4f) - 0.055f;
        }
        inline float hlgOETF(float e) {
            const float a = 0.17883277f, b = 0.28466892f, c = 0.55991073f;
            float x = clamp(e, 0.0f, 1.0f);
            return x <= 1.0f / 12.0f ? sqrt(3.0f * x) : a * log(12.0f * x - b) + c;
        }
        inline float hlgInvOETF(float s) {
            const float a = 0.17883277f, b = 0.28466892f, c = 0.55991073f;
            float x = clamp(s, 0.0f, 1.0f);
            return x <= 0.5f ? (x * x) / 3.0f : (exp((x - c) / a) + b) / 12.0f;
        }
        inline float toneMap(float x) {
            float v = max(0.0f, x);
            const float k = 0.8f;
            return v <= k ? v : k + (1.0f - k) * tanh((v - k) / (1.0f - k));
        }
        inline float3 rec709ToRec2020(float3 v) {
            return float3(0.627404f*v.r + 0.329283f*v.g + 0.043313f*v.b,
                          0.069097f*v.r + 0.919540f*v.g + 0.011362f*v.b,
                          0.016391f*v.r + 0.088013f*v.g + 0.895595f*v.b);
        }
        inline float3 rec2020ToRec709(float3 v) {
            return float3( 1.660491f*v.r - 0.587641f*v.g - 0.072850f*v.b,
                          -0.124550f*v.r + 1.132900f*v.g - 0.008349f*v.b,
                          -0.018151f*v.r - 0.100579f*v.g + 1.118730f*v.b);
        }

        // HDR 10-bit ARGB2101010LEPacked (HLG/Rec.2020) -> 8-bit BGRA (sRGB/709).
        kernel void prism_hdr_to_sdr(device const uint *src [[buffer(0)]],
                                     device uchar     *dst [[buffer(1)]],
                                     constant Params  &p   [[buffer(2)]],
                                     uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= p.width || gid.y >= p.height) { return; }
            uint word = src[(gid.y * p.srcStrideBytes) / 4u + gid.x];
            float3 e = float3(hlgInvOETF(float((word >> 20) & 0x3FFu) / 1023.0f),
                              hlgInvOETF(float((word >> 10) & 0x3FFu) / 1023.0f),
                              hlgInvOETF(float( word        & 0x3FFu) / 1023.0f));
            float3 rgb = rec2020ToRec709(e);
            rgb = float3(toneMap(rgb.r), toneMap(rgb.g), toneMap(rgb.b));
            float3 code = clamp(round(float3(srgbOETF(rgb.r), srgbOETF(rgb.g), srgbOETF(rgb.b)) * 255.0f), 0.0f, 255.0f);
            uint o = gid.y * p.dstStrideBytes + gid.x * 4u;
            dst[o]     = uchar(code.b);
            dst[o + 1] = uchar(code.g);
            dst[o + 2] = uchar(code.r);
            dst[o + 3] = 255;
        }

        // 8-bit BGRA (sRGB/709) -> HDR 10-bit ARGB2101010LEPacked (HLG/Rec.2020).
        kernel void prism_sdr_to_hdr(device const uchar *src [[buffer(0)]],
                                     device uint        *dst [[buffer(1)]],
                                     constant Params    &p   [[buffer(2)]],
                                     uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= p.width || gid.y >= p.height) { return; }
            uint s = gid.y * p.srcStrideBytes + gid.x * 4u;
            float3 lin = float3(srgbEOTF(float(src[s + 2]) / 255.0f),
                                srgbEOTF(float(src[s + 1]) / 255.0f),
                                srgbEOTF(float(src[s])     / 255.0f));
            float3 v = rec709ToRec2020(lin);
            float3 code = clamp(round(float3(hlgOETF(v.r), hlgOETF(v.g), hlgOETF(v.b)) * 1023.0f), 0.0f, 1023.0f);
            uint r10 = uint(code.r), g10 = uint(code.g), b10 = uint(code.b);
            dst[(gid.y * p.dstStrideBytes) / 4u + gid.x] = (3u << 30) | (r10 << 20) | (g10 << 10) | b10;
        }
        """
    }
}
