import Foundation

/// Embedded MSL, compiled at runtime via `device.makeLibrary(source:options:)`
/// — the same pattern as PrismCompositor (SPM cannot compile `.metal` files
/// into a library target; the compile cost is paid once per processor init).
///
/// Three kernel families, each with a BGRA and a bi-planar-YUV (420v/420f)
/// input variant so sources are sampled zero-copy in their native format:
///
/// - `prism_grade_*` — the **one fused grade+LUT kernel**: sample →
///   linearize (2.2 power) → exposure × white-balance (linear) → re-encode →
///   lift/gamma/gain → contrast (pivot 0.5) → saturation → optional 1D/3D
///   LUT (trilinear) → BGRA8 write.
/// - `prism_stats_*` — downsampled frame statistics into an atomic
///   fixed-point accumulator buffer (see `FrameAnalyzer` for the layout).
/// - `prism_relight_*` — depth → screen-space normals (central differences)
///   → Lambert + Blinn-Phong accumulation over ≤8 virtual lights, applied in
///   linear light.
///
/// Transfer function (v0, stated honestly): gamma-encoded BT.709 in/out; the
/// "linear-ish working space" is a pure 2.2 power, an approximation of the
/// BT.709/sRGB display chain. Wheels/contrast/saturation/LUT operate on
/// gamma-encoded values (grading-tool convention).
///
/// **Alpha handling:** the BGRA grade/relight kernels PRESERVE the input's
/// alpha channel (write it back unchanged) so a key→grade order keeps the
/// matte intact (the `ChromaKeyProcessor`-documented pipeline). The sampled
/// BGRA rgb is PREMULTIPLIED by α; the grade kernel un-premultiplies to the
/// STRAIGHT color (`straight = α>0 ? rgb/α : rgb`) before the grade math and
/// re-premultiplies the output by α (sol #11 #3), so an alpha-bearing source is
/// graded on its TRUE color — not the α-darkened premultiplied color. Opaque
/// (α==1) and the YUV variants (α always 1) divide by one → byte-identical.
/// (Phase 2e: the `relight_bgra` kernel NOW un-premultiplies the sampled rgb
/// the same way — shades the STRAIGHT color and re-premultiplies by α — because
/// the Blinn specular is an ADDITIVE linear-light term, so shading the α-darkened
/// premultiplied rgb is NOT equivalent to shading·α for a partial-α source.
/// Opaque (α==1) and the YUV variant (α always 1) divide by one → byte-identical.)
enum ColorShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    constant float3 kLuma709 = float3(0.2126, 0.7152, 0.0722);

    // ---------------------------------------------------------------- shared

    // sol #5 finding 2: transfer-aware linearize / re-encode for the grade + relight
    // LINEAR-LIGHT leg. The pre-fix path HARDCODED a 2.2 power to linearize (and
    // 1/2.2 to re-encode) REGARDLESS of the source transfer — so exposure / white-
    // balance / relight of an HLG, PQ or Linear source computed on the wrong domain
    // (e.g. an HLG signal +1 stop over-brightened / clipped; a Linear source treated
    // as 2.2-coded). These decode to TRUE linear per the source's transfer code and
    // re-encode with the SAME transfer:
    //   0 Rec.709 / 3 sRGB (SDR)  → the v0 2.2-power approximation, BYTE-IDENTICAL to
    //                               the pre-fix path (a 709/sRGB source is unchanged).
    //   1 HLG  → BT.2100 inverse-OETF (decode) / OETF (encode).
    //   2 PQ   → SMPTE ST 2084 EOTF (decode) / its exact inverse (encode); the pair
    //            round-trips exactly, so an identity grade is a no-op.
    //   4 Linear → identity (already scene-linear).
    static inline float cs_hlg_inv_oetf1(float v) {
        const float a = 0.17883277, b = 0.28466892, c = 0.55991073;
        return v <= 0.5 ? (v * v) / 3.0 : (exp((v - c) / a) + b) / 12.0;
    }
    static inline float cs_hlg_oetf1(float e) {
        const float a = 0.17883277, b = 0.28466892, c = 0.55991073;
        e = max(e, 0.0);
        return e <= 1.0 / 12.0 ? sqrt(3.0 * e) : a * log(max(12.0 * e - b, 1e-6)) + c;
    }
    static inline float cs_pq_eotf1(float v) {
        const float m1 = 0.1593017578125, m2 = 78.84375;
        const float c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
        float vp = pow(max(v, 0.0), 1.0 / m2);
        float num = max(vp - c1, 0.0);
        float den = c2 - c3 * vp;
        return pow(num / max(den, 1e-8), 1.0 / m1);   // 1.0 == 10000 nits
    }
    static inline float cs_pq_oetf1(float l) {
        const float m1 = 0.1593017578125, m2 = 78.84375;
        const float c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
        float lp = pow(max(l, 0.0), m1);
        return pow((c1 + c2 * lp) / (1.0 + c3 * lp), m2);
    }
    // sol wave-11 #5: ODD-SYMMETRIC (signed) power for the extended sRGB/709 v0 curve —
    // sign(x)·|x|^e — so a legal NEGATIVE extended-range component (wide-gamut color
    // OUTSIDE the 709 triangle) decodes/re-encodes with the correct magnitude AND sign
    // (an IDENTITY grade round-trips it exactly) instead of the one-sided `max(·,0)` that
    // crushed it to 0. For a BOUNDED (pre-saturated ≥0) input this equals |x|^e, so every
    // SDR/HLG/PQ/plain source stays BYTE-IDENTICAL.
    static inline float3 cs_signed_pow(float3 v, float e) {
        return float3(sign(v.r) * pow(fabs(v.r), e),
                      sign(v.g) * pow(fabs(v.g), e),
                      sign(v.b) * pow(fabs(v.b), e));
    }
    static inline float3 cs_to_linear(float3 rgb, float transferF) {
        uint t = uint(transferF + 0.5);
        if (t == 1u) return float3(cs_hlg_inv_oetf1(rgb.r), cs_hlg_inv_oetf1(rgb.g), cs_hlg_inv_oetf1(rgb.b));
        if (t == 2u) return float3(cs_pq_eotf1(rgb.r), cs_pq_eotf1(rgb.g), cs_pq_eotf1(rgb.b));
        if (t == 4u) return rgb;                           // already linear (signed EDR passes through)
        return cs_signed_pow(rgb, 2.2);                    // 709 / sRGB (v0 approx, odd-symmetric)
    }
    static inline float3 cs_to_encoded(float3 lin, float transferF) {
        uint t = uint(transferF + 0.5);
        if (t == 1u) return float3(cs_hlg_oetf1(lin.r), cs_hlg_oetf1(lin.g), cs_hlg_oetf1(lin.b));
        if (t == 2u) return float3(cs_pq_oetf1(lin.r), cs_pq_oetf1(lin.g), cs_pq_oetf1(lin.b));
        if (t == 4u) return lin;                           // stay linear (signed EDR passes through)
        return cs_signed_pow(lin, 1.0 / 2.2);              // 709 / sRGB (v0 approx, odd-symmetric)
    }

    // sol #3 finding 1: YCbCr→RGB for the source's TAGGED matrix (0 BT.709 ·
    // 1 BT.601 · 2 BT.2020, `matrixF` 0/1/2) and range — instead of hardcoding
    // centered BT.709. Coefficients are the standard ITU luma-weight-derived
    // values, IDENTICAL to the compositor's `prism_yuv_to_rgb` and Vision's
    // `sample_yuv`, so a graded/analyzed/keyed effect source matches the primary
    // layer path. The 709 branch is byte-identical to the pre-fix path (untagged
    // → 709, no regression).
    static inline float3 yuv_to_rgb(float y, float2 cbcr, float fullRange, float matrixF) {
        float2 c = cbcr - float2(128.0 / 255.0);
        uint matrix = uint(matrixF + 0.5);
        float3 rgb;
        if (fullRange > 0.5) {
            if (matrix == 1u) {          // BT.601 full range
                rgb = float3(y + 1.402 * c.y,
                             y - 0.344136 * c.x - 0.714136 * c.y,
                             y + 1.772 * c.x);
            } else if (matrix == 2u) {   // BT.2020 full range
                rgb = float3(y + 1.4746 * c.y,
                             y - 0.16455 * c.x - 0.57135 * c.y,
                             y + 1.8814 * c.x);
            } else {                     // BT.709 full range
                rgb = float3(y + 1.5748 * c.y,
                             y - 0.1873 * c.x - 0.4681 * c.y,
                             y + 1.8556 * c.x);
            }
        } else {
            float yv = 1.1644 * (y - 16.0 / 255.0);
            if (matrix == 1u) {          // BT.601 video range
                rgb = float3(yv + 1.596 * c.y,
                             yv - 0.391 * c.x - 0.813 * c.y,
                             yv + 2.017 * c.x);
            } else if (matrix == 2u) {   // BT.2020 video range
                rgb = float3(yv + 1.6787 * c.y,
                             yv - 0.1873 * c.x - 0.6504 * c.y,
                             yv + 2.1418 * c.x);
            } else {                     // BT.709 video range
                rgb = float3(yv + 1.7927 * c.y,
                             yv - 0.2132 * c.x - 0.5329 * c.y,
                             yv + 2.1124 * c.x);
            }
        }
        return saturate(rgb);
    }

    // `chromaOffsetX` shifts the chroma sample half a luma pixel right for a
    // left/co-sited source (siting; 0 = centered — MPEG-1/JPEG default position).
    //
    // wave-5b: `tenBit` (>0.5) selects 10-bit P010-style sampling — the code is in
    // the HIGH 10 bits of each 16-bit sample, so an r16Unorm read is code·64/65535;
    // scale by 65535/65472 → code/1023. Video anchors are 4× the 8-bit ones so
    // code/1020 == code8/255 feeds `yuv_to_rgb`'s internal 128/255 centre exactly;
    // full-range recenters chroma so the internal −128/255 lands on 512/1023.
    // `tenBit <= 0.5` is byte-identical to the original 8-bit sampling.
    static inline float3 sample_yuv(texture2d<float, access::sample> luma,
                                    texture2d<float, access::sample> chroma,
                                    float2 uv, float fullRange, float matrixF, float chromaOffsetX,
                                    float tenBit) {
        constexpr sampler s(address::clamp_to_edge, filter::linear, coord::normalized);
        float2 chromaUV = uv + float2(chromaOffsetX, 0.0);
        if (tenBit > 0.5) {
            const float k = 65535.0 / 65472.0;               // r16Unorm sample → code/1023
            float  y10 = luma.sample(s, uv).r * k;
            float2 c10 = chroma.sample(s, chromaUV).rg * k;
            float y; float2 craw;
            if (fullRange > 0.5) {
                y = y10;
                craw = c10 + float2(128.0 / 255.0 - 512.0 / 1023.0); // internal −128/255 → −512/1023
            } else {
                y = y10 * (1023.0 / 1020.0);                 // video anchors ×4 → code/255
                craw = c10 * (1023.0 / 1020.0);              // neutral 512 → 128/255
            }
            return yuv_to_rgb(y, craw, fullRange, matrixF);
        }
        return yuv_to_rgb(luma.sample(s, uv).r, chroma.sample(s, chromaUV).rg, fullRange, matrixF);
    }

    // ----------------------------------------------------------------- grade

    struct GradeUniforms {
        float4 linearGains;    // xyz = exp2(exposure) × WB gains (linear); w = contrast
        float4 lift;           // xyz = lift wheel; w = saturation
        float4 invGamma;       // xyz = 1/gamma wheel; w = fullRange (YUV only)
        float4 gain;           // xyz = gain wheel; w = lutMode (0 none, 1 = 3D, 2 = 1D)
        float4 lutDomainMin;   // xyz; w = LUT size N
        float4 lutDomainScale; // xyz = 1/(domainMax − domainMin); w = source transfer (0 709·1 HLG·2 PQ·3 sRGB·4 Linear, sol#5 f2)
        float4 yuvTags;        // YUV only: x = matrix (0/1/2), y = chromaOffsetX (siting), z = tenBit
        float4 extended;       // sol wave-10 #3: x = nonlinear extended-range flag (1 = extendedSRGB/709/P3 — do NOT pre-clamp >1 highlights, mirror the wave-9 compositor); yzw pad
    };

    static inline float3 apply_grade(float3 rgb, constant GradeUniforms& u,
                                     texture3d<float> lut3, texture1d<float> lut1) {
        constexpr sampler lutSampler(address::clamp_to_edge, filter::linear, coord::normalized);

        // Linear-light leg: exposure (stops) and white balance. sol #5 finding 2:
        // linearize / re-encode per the SOURCE transfer (u.lutDomainScale.w), not a
        // hardcoded 2.2 — so exposure/WB on an HLG/PQ/Linear source acts in TRUE
        // linear light. 709/sRGB keep the 2.2 approximation (byte-identical).
        float transferF = u.lutDomainScale.w;
        // sol #6 finding 6: a **Linear** source is an EXTENDED-RANGE float working
        // space — a legal EDR value > 1 must flow THROUGH grade unclamped (a `saturate`
        // before the math clamped Linear 1.5 to 1.0, so −1 stop emitted 0.5 not 0.75).
        // sol wave-10 #3: a NONLINEAR extended-range source (extendedSRGB / extended-709
        // / extendedP3, flagged by `u.extended.x`) is ALSO extended — the compositor was
        // already fixed (wave-9) to carry its >1 highlights, but grade still pre-clamped
        // them here (extendedSRGB 1.5 → clamped 1.0). Mirror the compositor: for either
        // extended case, DO NOT pre-clamp; every bounded transfer stays [0,1]
        // (byte-identical). `ext` = pass-through-≥0 for extended, saturate otherwise.
        // sol wave-11 #5: a SIGNED extended-range source (extendedSRGB/709/P3 and the
        // extendedLinear* siblings — flagged by `u.extended.x`) also carries legal NEGATIVE
        // wide-gamut components. Mirror the wave-11 compositor: pass the SIGNED value through
        // decode → linear math → re-encode WITHOUT the one-sided `max(·,0)` (which crushed
        // extendedSRGB(-0.2,…) to 0 → composited 500 vs the spec 430). The gamma wheel is
        // applied odd-symmetrically too (sign·|g|^γ) so an IDENTITY grade round-trips the
        // negative exactly. Every bounded transfer stays [0,1] (byte-identical).
        bool signedExt = (u.extended.x > 0.5);
        bool ext = (uint(transferF + 0.5) == 4u) || signedExt;
        float3 in0 = signedExt ? rgb : (ext ? max(rgb, 0.0) : saturate(rgb));
        float3 lin = cs_to_linear(in0, transferF);
        lin *= u.linearGains.xyz;
        float3 g = cs_to_encoded(lin, transferF);

        // Wheels (gamma space): out = gain·(in + lift·(1−in)), then 1/gamma.
        g = u.gain.xyz * (g + u.lift.xyz * (1.0 - g));
        g = signedExt ? (sign(g) * pow(fabs(g), u.invGamma.xyz))   // odd-symmetric γ (signed EDR)
                      : pow(max(g, 0.0), u.invGamma.xyz);
        // Contrast about pivot 0.5, then saturation against BT.709 luma.
        g = (g - 0.5) * u.linearGains.w + 0.5;
        float luma = dot(g, kLuma709);
        float3 sat = mix(float3(luma), g, u.lift.w);
        g = signedExt ? sat : (ext ? max(sat, 0.0) : saturate(sat));

        // Optional LUT on gamma-encoded values, domain-scaled, texel-center mapped.
        float lutMode = u.gain.w;
        if (lutMode > 0.5) {
            float n = u.lutDomainMin.w;
            float3 c = saturate((g - u.lutDomainMin.xyz) * u.lutDomainScale.xyz);
            float3 tc = (c * (n - 1.0) + 0.5) / n;
            if (lutMode > 1.5) {
                g = float3(lut1.sample(lutSampler, tc.r).r,
                           lut1.sample(lutSampler, tc.g).g,
                           lut1.sample(lutSampler, tc.b).b);
            } else {
                g = lut3.sample(lutSampler, tc).rgb;
            }
            return saturate(g);   // a LUT maps into [0,1] by construction
        }
        // Linear/extended-range keeps values > 1 AND (signed wide-gamut) values < 0
        // (final clamp is deferred to the compositor's single output encode); every other
        // transfer stays [0,1] (unchanged).
        return signedExt ? g : (ext ? max(g, 0.0) : saturate(g));
    }

    kernel void prism_grade_bgra(texture2d<float, access::sample> src [[texture(0)]],
                                 texture2d<float, access::write> dst [[texture(1)]],
                                 texture3d<float> lut3 [[texture(2)]],
                                 texture1d<float> lut1 [[texture(3)]],
                                 constant GradeUniforms& u [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler s(address::clamp_to_edge, filter::linear, coord::normalized);
        float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
        float4 src4 = src.sample(s, uv);
        // sol #11 #3 (MED, pre-existing): the sampled BGRA rgb is PREMULTIPLIED by α
        // (a premultiplied-alpha frame — e.g. the ChromaKey/decoder output). Grading
        // the premultiplied rgb graded the DARKENED color of an alpha-bearing source
        // (HLG straight 0.75 @ α0.25 is stored premult 0.1875 → +1 stop gave 0.2651,
        // downstream 756, not the correct 0.2206 / 622). Un-premultiply to the STRAIGHT
        // color (guard α==0) BEFORE the grade math, then RE-premultiply the graded rgb
        // by α — the same un-premultiply pattern wave-12 applied to the KEY stages.
        // rgb is graded RAW inside apply_grade (it clamps per transfer, honoring the
        // wave-10/11 extended-range + signed handling). OPAQUE (α==1) and the YUV path
        // (α always 1) divide by one → BYTE-IDENTICAL, so the wave-11 EDR carry
        // (extendedSRGB 1.5 @ α==1 → 937) is untouched. α carries through unchanged.
        float a = src4.a;
        float3 straight = (a > 0.0) ? src4.rgb / a : src4.rgb;
        dst.write(float4(apply_grade(straight, u, lut3, lut1) * a, a), gid);
    }

    kernel void prism_grade_yuv(texture2d<float, access::sample> lumaTex [[texture(0)]],
                                texture2d<float, access::sample> chromaTex [[texture(1)]],
                                texture2d<float, access::write> dst [[texture(2)]],
                                texture3d<float> lut3 [[texture(3)]],
                                texture1d<float> lut1 [[texture(4)]],
                                constant GradeUniforms& u [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
        float3 rgb = sample_yuv(lumaTex, chromaTex, uv, u.invGamma.w, u.yuvTags.x, u.yuvTags.y, u.yuvTags.z);
        dst.write(float4(apply_grade(rgb, u, lut3, lut1), 1.0), gid);
    }

    // ----------------------------------------------------------------- stats

    // Accumulator layout (uint32 words) — must match FrameAnalyzer.Layout:
    //  0 sumR ·4096   1 sumG   2 sumB
    //  3 sumR²·4096   4 sumG²  5 sumB²
    //  6 sum (log2(luma)+16)·256
    //  7 nearBlack count (max channel < 0.02)
    //  8 nearWhite count (max channel > 0.98)
    //  9 sample count
    // 10…73 luma histogram, 64 bins
    struct StatsUniforms {
        float4 grid;    // x,y = sample-grid size; z = fullRange (YUV); w unused
        float4 yuvTags; // YUV only: x = matrix (0/1/2), y = chromaOffsetX (siting)
    };

    static inline void accumulate_stats(float3 rgb, device atomic_uint* out) {
        rgb = saturate(rgb);
        uint3 q = uint3(round(rgb * 4096.0));
        uint3 q2 = uint3(round(rgb * rgb * 4096.0));
        atomic_fetch_add_explicit(&out[0], q.x, memory_order_relaxed);
        atomic_fetch_add_explicit(&out[1], q.y, memory_order_relaxed);
        atomic_fetch_add_explicit(&out[2], q.z, memory_order_relaxed);
        atomic_fetch_add_explicit(&out[3], q2.x, memory_order_relaxed);
        atomic_fetch_add_explicit(&out[4], q2.y, memory_order_relaxed);
        atomic_fetch_add_explicit(&out[5], q2.z, memory_order_relaxed);
        float luma = dot(rgb, kLuma709);
        float l2 = log2(max(luma, 1.0 / 8192.0));
        atomic_fetch_add_explicit(&out[6], uint(round((l2 + 16.0) * 256.0)), memory_order_relaxed);
        float mx = max(max(rgb.r, rgb.g), rgb.b);
        if (mx < 0.02) atomic_fetch_add_explicit(&out[7], 1u, memory_order_relaxed);
        if (mx > 0.98) atomic_fetch_add_explicit(&out[8], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&out[9], 1u, memory_order_relaxed);
        uint bin = min(uint(luma * 64.0), 63u);
        atomic_fetch_add_explicit(&out[10 + bin], 1u, memory_order_relaxed);
    }

    kernel void prism_stats_bgra(texture2d<float, access::sample> src [[texture(0)]],
                                 device atomic_uint* out [[buffer(0)]],
                                 constant StatsUniforms& u [[buffer(1)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= uint(u.grid.x) || gid.y >= uint(u.grid.y)) return;
        constexpr sampler s(address::clamp_to_edge, filter::linear, coord::normalized);
        float2 uv = (float2(gid) + 0.5) / u.grid.xy;
        accumulate_stats(src.sample(s, uv).rgb, out);
    }

    kernel void prism_stats_yuv(texture2d<float, access::sample> lumaTex [[texture(0)]],
                                texture2d<float, access::sample> chromaTex [[texture(1)]],
                                device atomic_uint* out [[buffer(0)]],
                                constant StatsUniforms& u [[buffer(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= uint(u.grid.x) || gid.y >= uint(u.grid.y)) return;
        float2 uv = (float2(gid) + 0.5) / u.grid.xy;
        accumulate_stats(sample_yuv(lumaTex, chromaTex, uv, u.grid.z, u.yuvTags.x, u.yuvTags.y, u.yuvTags.z), out);
    }

    // --------------------------------------------------------------- relight

    // Scene model (documented in Relight.swift): x,y = normalized screen
    // coords (top-left origin, y down), z = depth·depthScale increasing AWAY
    // from camera; the camera looks along +z, so lights with z < 0 sit in
    // front of the scene. View vector is a constant (0,0,−1) (orthographic
    // approximation — fine for screen-space relight).
    struct RelightUniforms {
        float4 params;  // x = ambient, y = depthScale, z = light count, w = fullRange
        float4 yuvTags; // x = matrix (0/1/2), y = chromaOffsetX (siting), z = tenBit, w = source transfer (sol#5 f2)
        float4 extended; // sol wave-10 #3: x = nonlinear extended-range flag (see GradeUniforms.extended); yzw pad
    };
    struct GPULight {
        float4 posIntensity;  // xyz = position, w = intensity
        float4 colorSpecular; // xyz = linear color, w = specular strength
        float4 attenShiny;    // x = attenuation k (1/(1+k·d²)), y = shininess, zw pad
    };

    static inline float3 relight_rgb(float3 rgb, float2 uv, float2 texel,
                                     texture2d<float, access::sample> depthTex,
                                     constant RelightUniforms& u,
                                     constant GPULight* lights) {
        // Nearest sampling: r32Float filtering support is not needed here.
        constexpr sampler ds(address::clamp_to_edge, filter::nearest, coord::normalized);
        float zs = u.params.y;
        float d   = depthTex.sample(ds, uv).r;
        float dxp = depthTex.sample(ds, uv + float2(texel.x, 0.0)).r;
        float dxm = depthTex.sample(ds, uv - float2(texel.x, 0.0)).r;
        float dyp = depthTex.sample(ds, uv + float2(0.0, texel.y)).r;
        float dym = depthTex.sample(ds, uv - float2(0.0, texel.y)).r;
        // Surface z = f(x,y); normal toward the camera (−z side).
        float fx = (dxp - dxm) * zs / (2.0 * texel.x);
        float fy = (dyp - dym) * zs / (2.0 * texel.y);
        float3 n = normalize(float3(fx, fy, -1.0));
        float3 P = float3(uv, d * zs);
        float3 V = float3(0.0, 0.0, -1.0);

        // sol #5 finding 2: decode to TRUE linear per the source transfer
        // (u.yuvTags.w), not a hardcoded 2.2 — relighting an HLG/PQ/Linear source
        // shades in real linear light. 709/sRGB keep the 2.2 approximation.
        // sol #6 finding 6: a Linear source is extended-range — do NOT saturate a legal
        // EDR value > 1 before shading (that clamped Linear 1.5 → 1.0, so a −1-stop / ½
        // relight emitted 0.5 not 0.75). 709/sRGB/HLG/PQ inputs stay [0,1] (unchanged).
        // sol wave-10 #3: a NONLINEAR extended-range source (extendedSRGB/709/P3, flagged
        // by `u.extended.x`) is likewise extended — mirror the wave-9 compositor and
        // carry its >1 highlights through the shade instead of pre-clamping to 1.0.
        // sol wave-11 #5: a SIGNED extended-range source carries legal NEGATIVE wide-gamut
        // components — pass the signed value through the linear shade (mirror grade / the
        // wave-11 compositor) instead of the one-sided `max(·,0)` that crushed it to 0.
        float transferF = u.yuvTags.w;
        bool signedExt = (u.extended.x > 0.5);
        bool ext = (uint(transferF + 0.5) == 4u) || signedExt;
        float3 lin = cs_to_linear(signedExt ? rgb : (ext ? max(rgb, 0.0) : saturate(rgb)), transferF);
        float3 diffuse = float3(u.params.x); // ambient floor
        float3 specular = float3(0.0);
        uint count = uint(u.params.z);
        for (uint i = 0; i < count; ++i) {
            float3 Lv = lights[i].posIntensity.xyz - P;
            float dist = max(length(Lv), 1e-4);
            float3 L = Lv / dist;
            float atten = lights[i].posIntensity.w / (1.0 + lights[i].attenShiny.x * dist * dist);
            float ndl = max(dot(n, L), 0.0);
            diffuse += atten * ndl * lights[i].colorSpecular.xyz;
            if (ndl > 0.0 && lights[i].colorSpecular.w > 0.0) {
                float3 H = normalize(L + V);
                float ndh = max(dot(n, H), 0.0);
                specular += lights[i].colorSpecular.w * atten
                          * pow(ndh, max(lights[i].attenShiny.y, 1.0))
                          * lights[i].colorSpecular.xyz;
            }
        }
        float3 litLin = lin * diffuse + specular;
        float3 shaded = cs_to_encoded(signedExt ? litLin : max(litLin, 0.0), transferF);
        return signedExt ? shaded : (ext ? max(shaded, 0.0) : saturate(shaded));
    }

    kernel void prism_relight_bgra(texture2d<float, access::sample> src [[texture(0)]],
                                   texture2d<float, access::sample> depthTex [[texture(1)]],
                                   texture2d<float, access::write> dst [[texture(2)]],
                                   constant RelightUniforms& u [[buffer(0)]],
                                   constant GPULight* lights [[buffer(1)]],
                                   uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler s(address::clamp_to_edge, filter::linear, coord::normalized);
        float2 size = float2(dst.get_width(), dst.get_height());
        float2 uv = (float2(gid) + 0.5) / size;
        float4 src4 = src.sample(s, uv);
        // Phase 2e: the sampled BGRA rgb is PREMULTIPLIED by α. Un-premultiply to
        // the STRAIGHT color (guard α==0) BEFORE shading, then RE-premultiply by α —
        // exactly the prism_grade_bgra pattern. The Blinn specular adds a constant in
        // linear light (litLin = lin·diffuse + specular), so shading the α-darkened
        // premultiplied rgb ≠ shading straight then ·α for a partial-α source. OPAQUE
        // (α==1) and the YUV relight below (α always 1) divide by one → BYTE-IDENTICAL.
        // The input matte (α) carries through unchanged (see prism_grade_bgra).
        float a = src4.a;
        float3 straight = (a > 0.0) ? src4.rgb / a : src4.rgb;
        dst.write(float4(relight_rgb(straight, uv, 1.0 / size, depthTex, u, lights) * a, a), gid);
    }

    kernel void prism_relight_yuv(texture2d<float, access::sample> lumaTex [[texture(0)]],
                                  texture2d<float, access::sample> chromaTex [[texture(1)]],
                                  texture2d<float, access::sample> depthTex [[texture(2)]],
                                  texture2d<float, access::write> dst [[texture(3)]],
                                  constant RelightUniforms& u [[buffer(0)]],
                                  constant GPULight* lights [[buffer(1)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 size = float2(dst.get_width(), dst.get_height());
        float2 uv = (float2(gid) + 0.5) / size;
        float3 rgb = sample_yuv(lumaTex, chromaTex, uv, u.params.w, u.yuvTags.x, u.yuvTags.y, u.yuvTags.z);
        dst.write(float4(relight_rgb(rgb, uv, 1.0 / size, depthTex, u, lights), 1.0), gid);
    }

    // ------------------------------------------------------------- chroma key

    // Standalone green/blue-screen keyer (DESIGN.md §2.3), parallel to the
    // Vision person-segmentation path. Matte = distance in the BT.709 chroma
    // (Cb,Cr) plane between the pixel and the key color, feathered by a
    // smoothstep; hue-aware despill pulls edge spill of the key color back out.
    // Output is **premultiplied alpha** (rgb·α, α) so keyed pixels are
    // transparent black and the frame composites straight over lower layers.
    // The keyed BGRA path folds the input's OWN coverage alpha into the output
    // (output α = keyAlpha·src.a) so an alpha-bearing source keeps its existing
    // transparency; the matte-view kernels visualize the key α alone (unchanged).
    struct ChromaUniforms {
        float4 keyColor; // xyz = key RGB (0..1); w = similarity (chroma dist at/below which fully keyed)
        float4 params;   // x = smoothness (feather width); y = spill strength; z = fullRange (YUV); w unused
        float4 yuvTags;  // YUV only: x = matrix (0/1/2), y = chromaOffsetX (siting)
        float4 extended; // sol wave-11 #4: x = nonlinear extended-range flag (1 = extendedSRGB/709/P3 — the KEPT foreground carries >1 highlights through, clamped only at output; the key MATTE/threshold math is UNCHANGED, computed on the clamped value); yzw pad
    };

    // BT.709 chroma coordinates (luma-independent), the plane greenscreen keys live in.
    static inline float2 rgb_to_cbcr(float3 c) {
        float y = dot(c, kLuma709);
        return float2((c.b - y) / 1.8556, (c.r - y) / 1.5748);
    }

    // Despill: remove tint toward the key's dominant hue. Classic
    // "green − max(red,blue)" despill, generalized to whichever channel the
    // key color leads on (green screen → green, blue screen → blue).
    static inline float3 despill_key(float3 rgb, float3 key, float strength) {
        if (key.g >= key.r && key.g >= key.b) {
            rgb.g -= max(rgb.g - max(rgb.r, rgb.b), 0.0) * strength;
        } else if (key.r >= key.g && key.r >= key.b) {
            rgb.r -= max(rgb.r - max(rgb.g, rgb.b), 0.0) * strength;
        } else {
            rgb.b -= max(rgb.b - max(rgb.r, rgb.g), 0.0) * strength;
        }
        return rgb;
    }

    // The chroma matte α for one pixel, computed on the STRAIGHT (un-premultiplied)
    // color: distance in the BT.709 (Cb,Cr) plane from the key color, feathered by a
    // smoothstep. α = 0 where chroma matches the key (background), 1 far from it
    // (foreground). Shared by the keyer and the matte-view kernels. The distance is
    // computed on the CLAMPED straight value so an extended-range highlight (> 1) does
    // not move the DECISION — the matte is byte-identical for a bounded source.
    static inline float chroma_key_alpha(float3 straight, constant ChromaUniforms& u) {
        float3 mrgb = saturate(straight);
        float dist = distance(rgb_to_cbcr(mrgb), rgb_to_cbcr(u.keyColor.xyz));
        return smoothstep(u.keyColor.w, u.keyColor.w + max(u.params.x, 1e-4), dist);
    }

    static inline float4 key_pixel(float3 rgb, float srcA, constant ChromaUniforms& u) {
        // sol #11 #2 (pre-existing): the matte/threshold + despill are computed on the
        // STRAIGHT (un-premultiplied) color so an ALPHA-BEARING source keys on its TRUE
        // color, not its premultiplied rgb (a premult green at α=0.1 IS green → keyed out,
        // not kept). Divide out coverage (guard α==0); opaque (srcA==1) and YUV (srcA
        // passed as 1) divide by one → byte-identical no-op. The output stays correctly
        // premultiplied by keyAlpha·srcA.
        // sol wave-11 #4: the KEPT foreground COLOR carries the > 1 highlight for an
        // extended-range source (extended → `max(·,0)`), clamped elsewhere only at the
        // final output encode; a bounded/SDR source saturates (byte-identical). The matte
        // DECISION (chroma-distance) is on the clamped straight value → unchanged.
        bool ext = (u.extended.x > 0.5);
        float3 straight = (srcA > 0.0) ? rgb / srcA : rgb;
        float alpha = chroma_key_alpha(straight, u);
        float3 base = ext ? max(straight, 0.0) : saturate(straight);
        float3 despilled = despill_key(base, u.keyColor.xyz, u.params.y);
        float3 fg = ext ? max(despilled, 0.0) : saturate(despilled);
        float outA = alpha * srcA;
        return float4(fg * outA, outA); // premultiplied by keyAlpha·srcA
    }

    kernel void prism_chromakey_bgra(texture2d<float, access::sample> src [[texture(0)]],
                                     texture2d<float, access::write> dst [[texture(1)]],
                                     constant ChromaUniforms& u [[buffer(0)]],
                                     uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler s(address::clamp_to_edge, filter::linear, coord::normalized);
        float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
        // Fold the input's own coverage alpha into the keyed output so an
        // alpha-bearing (premultiplied) source keeps its transparency instead
        // of compositing as opaque black. key_pixel returns premultiplied
        // (fg·keyAlpha, keyAlpha) computed from the already-premultiplied
        // src.rgb; the consistent result is (fg·keyAlpha, keyAlpha·src.a):
        // the rgb (premultiplied by keyAlpha over src.rgb, which already
        // carries src.a) stays as-is and only the OUTPUT alpha gains src.a, so
        // rgb is premultiplied by the SAME keyAlpha·src.a factor as the alpha
        // (invariant rgb ≤ alpha holds). For an opaque input (src.a==1) this is
        // byte-identical to before.
        float4 src4 = src.sample(s, uv);
        // sol #11 #2: hand key_pixel the RAW premultiplied rgb AND its coverage α — it
        // un-premultiplies internally to key on the straight color and folds src.a back into
        // the output. sol wave-11 #4: raw (un-saturated) rgb lets an extended-range > 1
        // highlight survive; the matte saturates internally so a bounded source is identical.
        dst.write(key_pixel(src4.rgb, src4.a, u), gid);
    }

    kernel void prism_chromakey_yuv(texture2d<float, access::sample> lumaTex [[texture(0)]],
                                    texture2d<float, access::sample> chromaTex [[texture(1)]],
                                    texture2d<float, access::write> dst [[texture(2)]],
                                    constant ChromaUniforms& u [[buffer(0)]],
                                    uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
        float3 rgb = sample_yuv(lumaTex, chromaTex, uv, u.params.z, u.yuvTags.x, u.yuvTags.y, u.yuvTags.z);
        // YUV is opaque (no coverage α) → srcA = 1: the un-premultiply is a divide-by-one
        // no-op, so the YUV key is byte-identical.
        dst.write(key_pixel(rgb, 1.0, u), gid);
    }

    // -------------------------------------------------- chroma key: matte view
    // Debug/tuning "matte view" (DESIGN.md §2.3): the same chroma matte the
    // keyer computes, written as opaque grayscale (r=g=b=α, a=1) so an operator
    // can see exactly what is being keyed. Reuses the shared `key_pixel` (no
    // change to the keyed-output kernels above) and just visualizes its α.
    kernel void prism_chromakey_matte_bgra(texture2d<float, access::sample> src [[texture(0)]],
                                           texture2d<float, access::write> dst [[texture(1)]],
                                           constant ChromaUniforms& u [[buffer(0)]],
                                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler s(address::clamp_to_edge, filter::linear, coord::normalized);
        float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
        // sol #11 #2: visualize the matte the keyer actually computes — on the STRAIGHT
        // (un-premultiplied) color. Opaque input (src.a==1) → straight == rgb (identical).
        float4 src4 = src.sample(s, uv);
        float3 straight = (src4.a > 0.0) ? src4.rgb / src4.a : src4.rgb;
        float a = chroma_key_alpha(straight, u);
        dst.write(float4(a, a, a, 1.0), gid);
    }

    kernel void prism_chromakey_matte_yuv(texture2d<float, access::sample> lumaTex [[texture(0)]],
                                          texture2d<float, access::sample> chromaTex [[texture(1)]],
                                          texture2d<float, access::write> dst [[texture(2)]],
                                          constant ChromaUniforms& u [[buffer(0)]],
                                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
        // YUV is opaque (straight color already) → matte identical.
        float a = chroma_key_alpha(sample_yuv(lumaTex, chromaTex, uv, u.params.z, u.yuvTags.x, u.yuvTags.y, u.yuvTags.z), u);
        dst.write(float4(a, a, a, 1.0), gid);
    }

    // -------------------------------------------------------------- luma key
    // Key by LUMINANCE, not chroma distance (DESIGN.md §2.3, the sibling of the
    // chroma keyer): pixels whose BT.709 luma falls inside the band
    // [lowLuma, highLuma] are treated as background (α → 0); pixels outside the
    // band are kept (α → 1). `smoothness` feathers both band edges with a
    // smoothstep. `invert` swaps which side is keyed (key the band instead of
    // its complement) — e.g. key a bright backdrop vs. a dark one.
    //
    // Luma is measured on gamma-encoded BT.709 values (same convention as the
    // grade/stats kernels), so the bounds line up with an 8-bit histogram.
    // Output is **premultiplied alpha** exactly like the chroma keyer, so the
    // frame composites over lower layers; `matteView` instead writes the α as
    // opaque grayscale for tuning. No despill (luma key has no spill hue).
    // The keyed BGRA path also folds the input's own coverage alpha (output
    // α = keyAlpha·src.a) so an alpha-bearing source keeps its transparency;
    // the matte-view branch is left untouched (it shows the key matte itself).
    struct LumaUniforms {
        float4 bounds;  // x = lowLuma, y = highLuma, z = smoothness, w = fullRange (YUV)
        float4 flags;   // x = invert (0/1), y = matteView (0/1), zw unused
        float4 yuvTags; // YUV only: x = matrix (0/1/2), y = chromaOffsetX (siting)
        float4 extended; // sol wave-11 #4: x = nonlinear extended-range flag (1 = extendedSRGB/709/P3 — the KEPT foreground carries >1 highlights through; the luma-band DECISION is UNCHANGED, measured on the clamped luma); yzw pad
    };

    // Foreground α for one pixel: 0 inside the keyed band, 1 outside it,
    // smoothstep-feathered across both edges (or inverted).
    static inline float luma_key_alpha(float3 rgb, constant LumaUniforms& u) {
        float y = dot(saturate(rgb), kLuma709);
        float s = max(u.bounds.z, 1e-4);
        float lowEdge  = smoothstep(u.bounds.x - s, u.bounds.x, y);       // 0 below band → 1 at low
        float highEdge = 1.0 - smoothstep(u.bounds.y, u.bounds.y + s, y); // 1 below high → 0 above band
        float inside = lowEdge * highEdge;                               // 1 = background (in band)
        return (u.flags.x > 0.5) ? inside : (1.0 - inside);
    }

    static inline float4 luma_key_pixel(float3 rgb, float srcA, constant LumaUniforms& u) {
        // sol #11 #2 (pre-existing): measure the luma band on the STRAIGHT
        // (un-premultiplied) color so an ALPHA-BEARING source keys on its TRUE luminance
        // (a premult white at α=0.1 is white, not dark → KEPT under `darkerThan`, not keyed
        // out). Divide out coverage (guard α==0); opaque (srcA==1) and YUV (srcA passed as
        // 1) divide by one → byte-identical. Output stays premultiplied by keyAlpha·srcA.
        // sol wave-11 #4: `luma_key_alpha` measures on the CLAMPED luma so the keyed-vs-kept
        // DECISION is unchanged; the KEPT foreground COLOR carries the > 1 highlight for an
        // extended-range source (extended → `max(·,0)`), clamped only at the final encode.
        float3 straight = (srcA > 0.0) ? rgb / srcA : rgb;
        float alpha = luma_key_alpha(straight, u);
        if (u.flags.y > 0.5) return float4(alpha, alpha, alpha, 1.0); // matte view (coverage-independent)
        float3 fg = (u.extended.x > 0.5) ? max(straight, 0.0) : saturate(straight);
        float outA = alpha * srcA;
        return float4(fg * outA, outA);                              // premultiplied by keyAlpha·srcA
    }

    kernel void prism_lumakey_bgra(texture2d<float, access::sample> src [[texture(0)]],
                                   texture2d<float, access::write> dst [[texture(1)]],
                                   constant LumaUniforms& u [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler s(address::clamp_to_edge, filter::linear, coord::normalized);
        float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
        // Fold the input's coverage alpha into the KEYED output only (same
        // premult reasoning as prism_chromakey_bgra): luma_key_pixel returns
        // premultiplied (src.rgb·keyAlpha, keyAlpha) over the already-
        // premultiplied src.rgb, so scaling only the output alpha by src.a
        // yields (src.rgb·keyAlpha, keyAlpha·src.a) — rgb premultiplied by the
        // same factor as alpha, source transparency preserved, opaque input
        // byte-identical. The matte-view branch (u.flags.y) is left untouched:
        // it visualizes the key matte itself, not a composited result.
        float4 src4 = src.sample(s, uv);
        // sol #11 #2: hand luma_key_pixel the RAW premultiplied rgb AND its coverage α — it
        // un-premultiplies to key on the straight luma and folds src.a into the keyed output
        // (the matte-view branch stays coverage-independent). sol wave-11 #4: raw rgb lets a
        // > 1 highlight survive; the band decision saturates internally (bounded identical).
        dst.write(luma_key_pixel(src4.rgb, src4.a, u), gid);
    }

    kernel void prism_lumakey_yuv(texture2d<float, access::sample> lumaTex [[texture(0)]],
                                  texture2d<float, access::sample> chromaTex [[texture(1)]],
                                  texture2d<float, access::write> dst [[texture(2)]],
                                  constant LumaUniforms& u [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
        float3 rgb = sample_yuv(lumaTex, chromaTex, uv, u.bounds.w, u.yuvTags.x, u.yuvTags.y, u.yuvTags.z);
        // YUV is opaque (no coverage α) → srcA = 1: divide-by-one no-op, byte-identical.
        dst.write(luma_key_pixel(rgb, 1.0, u), gid);
    }
    """
}
