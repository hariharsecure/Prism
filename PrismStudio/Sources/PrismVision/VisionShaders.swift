import Foundation

/// Embedded MSL, compiled at runtime via `device.makeLibrary(source:options:)`
/// — the same pattern as PrismCompositor / PrismColor (SPM cannot compile
/// `.metal` files into a library target; the compile cost is paid once per
/// processor init).
///
/// Kernel families:
/// - `prism_matte_blend` — temporal exponential blend of consecutive mattes
///   (`out = α·current + (1−α)·previous`), the flicker killer.
/// - `prism_bgblur_h_{bgra,yuv}` / `prism_bgblur_v` — separable gaussian,
///   horizontal pass samples the source in its native format into an
///   rgba16Float intermediate; vertical pass blurs the intermediate.
/// - `prism_bg_{bgra,yuv}` — the background-effect composite: samples the
///   source natively, upscales the matte by linear sampler (it is lower-res
///   than the frame), and applies remove / blur-composite / color-replace.
///
/// The matte is single-channel r8: 1 = person, 0 = background.
enum VisionShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // ---------------------------------------------------------------- shared

    // N5/finding-9: this Vision background-effect decode now honors the source's
    // tagged YCbCr matrix (601/709/2020, `matrixF` 0/1/2) and horizontal chroma
    // siting (`chromaOffsetX`), matching the compositor's `prism_yuv_to_rgb`
    // coefficients EXACTLY so a 601/2020/left-sited source segments/blurs with the
    // same color as the primary layer path (previously hardcoded centered BT.709).
    // Scope: vertical chroma siting stays centered (documented; horizontal only).
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

    // wave-5b: `tenBit` (>0.5) selects 10-bit P010-style sampling — the code sits in
    // the HIGH 10 bits of each 16-bit sample, so an r16Unorm read is code·64/65535;
    // scale by 65535/65472 → code/1023. Video anchors are 4× the 8-bit ones so
    // code/1020 == code8/255 feeds `yuv_to_rgb`'s internal 128/255 centre exactly;
    // full-range recenters chroma so the internal −128/255 lands on 512/1023.
    // `tenBit <= 0.5` is byte-identical to the original 8-bit sampling.
    static inline float3 sample_yuv(texture2d<float, access::sample> luma,
                                    texture2d<float, access::sample> chroma,
                                    float2 uv, float fullRange,
                                    float matrixF, float chromaOffsetX, float tenBit) {
        constexpr sampler s(address::clamp_to_edge, filter::linear, coord::normalized);
        float2 chromaUV = uv + float2(chromaOffsetX, 0.0);   // N5: horizontal siting
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

    // ----------------------------------------------------------- matte blend

    struct BlendUniforms {
        float4 params; // x = alpha (weight of the NEW matte), y = hasPrevious, zw unused
    };

    kernel void prism_matte_blend(texture2d<float, access::sample> current [[texture(0)]],
                                  texture2d<float, access::sample> previous [[texture(1)]],
                                  texture2d<float, access::write> dst [[texture(2)]],
                                  constant BlendUniforms& u [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler s(address::clamp_to_edge, filter::linear, coord::normalized);
        float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
        float c = current.sample(s, uv).r;
        float out = c;
        if (u.params.y > 0.5) {
            out = u.params.x * c + (1.0 - u.params.x) * previous.sample(s, uv).r;
        }
        dst.write(float4(out, 0.0, 0.0, 1.0), gid);
    }

    // ------------------------------------------------- separable gaussian blur

    struct BlurUniforms {
        float4 params; // x = half tap count, y = fullRange, z = yuvMatrix, w = chromaOffsetX (N5)
        float4 params2; // x = tenBit (wave-5b), yzw unused
    };

    kernel void prism_bgblur_h_bgra(texture2d<float, access::sample> src [[texture(0)]],
                                    texture2d<float, access::write> dst [[texture(1)]],
                                    constant BlurUniforms& u [[buffer(0)]],
                                    constant float* weights [[buffer(1)]],
                                    uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler s(address::clamp_to_edge, filter::linear, coord::normalized);
        float2 size = float2(dst.get_width(), dst.get_height());
        int reach = int(u.params.x);
        float3 acc = float3(0.0);
        for (int i = -reach; i <= reach; ++i) {
            float2 uv = (float2(gid) + 0.5 + float2(i, 0.0)) / size;
            acc += weights[abs(i)] * src.sample(s, uv).rgb;
        }
        dst.write(float4(acc, 1.0), gid);
    }

    kernel void prism_bgblur_h_yuv(texture2d<float, access::sample> lumaTex [[texture(0)]],
                                   texture2d<float, access::sample> chromaTex [[texture(1)]],
                                   texture2d<float, access::write> dst [[texture(2)]],
                                   constant BlurUniforms& u [[buffer(0)]],
                                   constant float* weights [[buffer(1)]],
                                   uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 size = float2(dst.get_width(), dst.get_height());
        int reach = int(u.params.x);
        float3 acc = float3(0.0);
        for (int i = -reach; i <= reach; ++i) {
            float2 uv = (float2(gid) + 0.5 + float2(i, 0.0)) / size;
            acc += weights[abs(i)] * sample_yuv(lumaTex, chromaTex, uv, u.params.y, u.params.z, u.params.w, u.params2.x);
        }
        dst.write(float4(acc, 1.0), gid);
    }

    kernel void prism_bgblur_v(texture2d<float, access::sample> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               constant BlurUniforms& u [[buffer(0)]],
                               constant float* weights [[buffer(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler s(address::clamp_to_edge, filter::linear, coord::normalized);
        float2 size = float2(dst.get_width(), dst.get_height());
        int reach = int(u.params.x);
        float3 acc = float3(0.0);
        for (int i = -reach; i <= reach; ++i) {
            float2 uv = (float2(gid) + 0.5 + float2(0.0, i)) / size;
            acc += weights[abs(i)] * src.sample(s, uv).rgb;
        }
        dst.write(float4(acc, 1.0), gid);
    }

    // ------------------------------------------------ background composite

    struct EffectUniforms {
        float4 replaceColor; // rgb = replacement color, w = tenBit (wave-5b)
        float4 params;       // x = mode (0 remove, 1 blur, 2 replace), y = fullRange, z = yuvMatrix, w = chromaOffsetX (N5)
        float4 extended;     // sol wave-10 #3: x = nonlinear extended-range flag (1 = extendedSRGB/709/P3 BGRA half-float — do NOT pre-clamp >1 highlights before compositing, mirror the wave-9 compositor); yzw pad
    };

    // m = matte (1 person, 0 background), upscaled by linear sampler.
    // srcA = the source's own coverage α (the BGRA sample's α; 1.0 for opaque BGRA
    // and every YUV source, which have no coverage).
    static inline float4 bg_composite(float3 rgb, float3 blurred, float m, float srcA,
                                      constant EffectUniforms& u) {
        int mode = int(u.params.x + 0.5);
        if (mode == 0) {
            // Remove: INTERSECT the matte with the source's EXISTING coverage.
            // sol #11 #4 (MED, pre-existing): emitting (rgb·m, m) REPLACED the source α
            // with the matte, so an alpha-bearing source (input α<1) acquired OPAQUE
            // regions under background removal (all-person matte m=1 + input α0.25 →
            // output α1.0 instead of 0.25). The correct coverage is the intersection
            // m·srcA. The sampled rgb is already premultiplied by srcA, so ·m makes it
            // premultiplied by m·srcA (straight·srcA·m) — consistent with the output α.
            // OPAQUE BGRA and YUV (srcA==1) are BYTE-IDENTICAL (·1); a removed region
            // (m==0) still → α0.
            float outA = m * srcA;
            return float4(rgb * m, outA);
        } else if (mode == 1) {
            // Blur: sharp foreground over blurred background.
            // Phase 2e: PRESERVE the source's own coverage α instead of forcing 1.0.
            // An alpha-bearing source (input α<1) became fully OPAQUE under blur (a PNG
            // overlay's transparent holes filled in). Both `rgb` and `blurred` are already
            // premultiplied by srcA (blurred is the blur of the premultiplied source), so
            // their mix is premultiplied by srcA and the output α = srcA is consistent.
            // OPAQUE BGRA and YUV (srcA==1) are BYTE-IDENTICAL (α=1.0 as before).
            return float4(mix(blurred, rgb, m), srcA);
        }
        // Replace: solid color background.
        // Phase 2e: PRESERVE the source's coverage α (was forced 1.0, making an
        // alpha-bearing source opaque under replace). `rgb` is premultiplied by srcA;
        // premultiply the (straight, coded) replacement color by srcA too so the whole
        // mix is premultiplied by srcA and the output α = srcA is consistent. OPAQUE
        // BGRA and YUV (srcA==1) are BYTE-IDENTICAL (replaceColor·1, α=1.0 as before).
        return float4(mix(u.replaceColor.rgb * srcA, rgb, m), srcA);
    }

    kernel void prism_bg_bgra(texture2d<float, access::sample> src [[texture(0)]],
                              texture2d<float, access::sample> blurred [[texture(1)]],
                              texture2d<float, access::sample> matte [[texture(2)]],
                              texture2d<float, access::write> dst [[texture(3)]],
                              constant EffectUniforms& u [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler s(address::clamp_to_edge, filter::linear, coord::normalized);
        float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
        // sol wave-10 #3: a NONLINEAR extended-range BGRA half-float source
        // (extendedSRGB/709/P3, flagged by `u.extended.x`) carries legal >1 highlights;
        // the pre-fix unconditional `saturate` crushed them to 1.0 BEFORE the composite,
        // so a background-remove identity of extendedSRGB 1.5 emitted 1.0 (downstream
        // 756) instead of carrying 1.5 (downstream 937). Mirror the wave-9 compositor:
        // keep >1 for extended sources; every bounded/SDR source still saturates
        // (byte-identical). YUV sources are integer-coded [0,1] and go through
        // `prism_bg_yuv` (never extended), so this path is BGRA-only.
        // sol wave-11 #5: an extended-range source ALSO carries legal NEGATIVE wide-gamut
        // components — pass the SIGNED value straight through (the composite here is a matte
        // blend in the coded space; the compositor decodes it downstream), instead of the
        // one-sided `max(·,0)` that crushed extendedSRGB(-0.2,…) to 0.
        float4 src4 = src.sample(s, uv);
        float3 sampled = src4.rgb;
        float3 rgb = (u.extended.x > 0.5) ? sampled : saturate(sampled);
        float m = matte.sample(s, uv).r;
        // sol #11 #4: pass the source's own coverage α so REMOVE intersects the matte
        // with it (m·srcA) instead of overwriting it. Opaque BGRA (α==1) unchanged.
        dst.write(bg_composite(rgb, blurred.sample(s, uv).rgb, m, src4.a, u), gid);
    }

    kernel void prism_bg_yuv(texture2d<float, access::sample> lumaTex [[texture(0)]],
                             texture2d<float, access::sample> chromaTex [[texture(1)]],
                             texture2d<float, access::sample> blurred [[texture(2)]],
                             texture2d<float, access::sample> matte [[texture(3)]],
                             texture2d<float, access::write> dst [[texture(4)]],
                             constant EffectUniforms& u [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler s(address::clamp_to_edge, filter::linear, coord::normalized);
        float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
        float3 rgb = sample_yuv(lumaTex, chromaTex, uv, u.params.y, u.params.z, u.params.w, u.replaceColor.w);
        float m = matte.sample(s, uv).r;
        // YUV is opaque (no coverage α) → srcA = 1.0: the intersection is a ·1 no-op.
        dst.write(bg_composite(rgb, blurred.sample(s, uv).rgb, m, 1.0, u), gid);
    }
    """
}
