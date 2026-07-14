import Foundation

/// Embedded MSL, compiled at runtime via `device.makeLibrary(source:options:)`.
/// SPM cannot compile `.metal` resources into a library target, so the shader
/// ships as source — compile cost is paid once at `MetalCompositor.init`.
///
/// One fused render pass (DESIGN.md §3.5): every layer is a textured quad,
/// drawn back-to-front with premultiplied-alpha blending. The quad geometry is
/// synthesized in the vertex shader from per-layer uniforms (no vertex buffer).
///
/// GPU budget: the whole program composite targets **< 4 ms at 1080p60**
/// (< 8 ms at 4K60). These shaders are ALU-trivial; the budget is bandwidth.
enum CompositorShaders {
    /// Must match `MetalCompositor.LayerUniforms` layout exactly (80 bytes).
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct LayerUniforms {
        float4 ndcRect;      // x,y = bottom-left corner in NDC; z,w = size in NDC
        float4 cropRect;     // x,y = origin, z,w = size — normalized tex coords (top-left origin)
        float  opacity;      // 0…1, premultiplied in the fragment shader
        uint   fullRange;    // YUV only: 1 = full-range (420f), 0 = video-range (420v)
        uint   premultiplied; // BGRA only: 1 = honor sampled premultiplied alpha, 0 = force opaque
        float  rotation;     // radians, about the layer centre; 0 = identity
        float  aspect;       // canvas width/height, for distortion-free rotation
        uint   yuvMatrix;    // YUV only: 0 BT.709 · 1 BT.601 · 2 BT.2020 (MED-9)
        float  chromaOffsetX;// YUV only: horizontal chroma sample offset (siting; MED-9)
        uint   rotateTo2020; // HDR only: primary rotation — 0 already-2020 · 1 709→2020 · 2 P3→2020 (N4 + sol#4 finding 3)
        uint   transferFn;   // HDR only: source transfer for linear decode — 0 709 · 1 HLG · 2 PQ · 3 sRGB · 4 Linear (sol#4 finding 3)
        uint   tenBit;       // YUV only: 1 = 10-bit biplanar (P010-style x420/xf20, r16/rg16 planes) · 0 = 8-bit (wave-5b)
        uint   extendedRange;// HDR only (sol #8 #6): 1 = a NONLINEAR extended-range transfer (extendedSRGB/extendedITUR_2020/extendedDisplayP3) whose >1 highlights must NOT be pre-clamped before decode · 0 = bounded [0,1]
    };

    // MED-9: YCbCr→RGB for the tagged matrix (0 BT.709 · 1 BT.601 · 2 BT.2020) and
    // range. `cbcr` is the raw chroma sample already centered (−128/255). The
    // video-range coefficients fold the 255/224 chroma + 255/219 luma scaling in,
    // matching the pre-existing 709 path's convention (so untagged 709 is
    // byte-identical). Constants are the standard ITU luma-weight-derived values.
    inline float3 prism_yuv_to_rgb(float y, float2 cbcr, uint fullRange, uint matrix) {
        float3 rgb;
        if (fullRange != 0u) {
            if (matrix == 1u) {          // BT.601 full range
                rgb = float3(y + 1.402 * cbcr.y,
                             y - 0.344136 * cbcr.x - 0.714136 * cbcr.y,
                             y + 1.772 * cbcr.x);
            } else if (matrix == 2u) {   // BT.2020 full range
                rgb = float3(y + 1.4746 * cbcr.y,
                             y - 0.16455 * cbcr.x - 0.57135 * cbcr.y,
                             y + 1.8814 * cbcr.x);
            } else {                     // BT.709 full range
                rgb = float3(y + 1.5748 * cbcr.y,
                             y - 0.1873 * cbcr.x - 0.4681 * cbcr.y,
                             y + 1.8556 * cbcr.x);
            }
        } else {
            float yv = 1.1644 * (y - 16.0 / 255.0);
            if (matrix == 1u) {          // BT.601 video range
                rgb = float3(yv + 1.596 * cbcr.y,
                             yv - 0.391 * cbcr.x - 0.813 * cbcr.y,
                             yv + 2.017 * cbcr.x);
            } else if (matrix == 2u) {   // BT.2020 video range
                rgb = float3(yv + 1.6787 * cbcr.y,
                             yv - 0.1873 * cbcr.x - 0.6504 * cbcr.y,
                             yv + 2.1418 * cbcr.x);
            } else {                     // BT.709 video range
                rgb = float3(yv + 1.7927 * cbcr.y,
                             yv - 0.2132 * cbcr.x - 0.5329 * cbcr.y,
                             yv + 2.1124 * cbcr.x);
            }
        }
        return rgb;
    }

    // wave-5b: sample a bi-planar YUV source and decode to R'G'B', handling both
    // 8-bit (r8/rg8 planes) and 10-bit P010-style (r16/rg16 planes, x420/xf20).
    //
    // 10-bit storage: the 10-bit code sits in the HIGH 10 bits of each 16-bit
    // sample (low 6 bits zero), so an `r16Unorm` read returns code·64/65535; scaling
    // by 65535/65472 recovers code/1023. VIDEO-range 10-bit level anchors are exactly
    // 4× the 8-bit ones (black 64 = 16·4, white 940 = 235·4, chroma-neutral 512), so
    // code/1020 == code8/255 feeds `prism_yuv_to_rgb`'s 8-bit-derived constants EXACTLY
    // (no re-hardcoding); FULL-range 10-bit centers chroma at its own neutral 512/1023
    // and maps white 1023 → 1.0. `tenBit == 0u` is byte-identical to the original
    // 8-bit sampling (same sampler, same expressions) — the SDR path never changes.
    inline float3 prism_sample_yuv_layer(texture2d<float> luma, texture2d<float> chroma,
                                         sampler s, float2 uv, float2 chromaUV,
                                         uint fullRange, uint matrix, uint tenBit) {
        float y; float2 cbcr;
        if (tenBit != 0u) {
            const float k = 65535.0 / 65472.0;             // r16Unorm sample → code/1023
            float  y10 = luma.sample(s, uv).r * k;
            float2 c10 = chroma.sample(s, chromaUV).rg * k;
            if (fullRange != 0u) {
                y = y10;                                   // white 1023 → 1.0
                cbcr = c10 - float2(512.0 / 1023.0);       // full-range neutral 512
            } else {
                y = y10 * (1023.0 / 1020.0);               // video anchors ×4 → code/255
                cbcr = c10 * (1023.0 / 1020.0) - float2(128.0 / 255.0);
            }
        } else {
            y = luma.sample(s, uv).r;
            cbcr = chroma.sample(s, chromaUV).rg - float2(128.0 / 255.0);
        }
        return prism_yuv_to_rgb(y, cbcr, fullRange, matrix);
    }

    struct VSOut {
        float4 position [[position]];
        float2 texCoord;
    };

    // vid 0..3 as a triangle strip: (0,0) (1,0) (0,1) (1,1) in quad space.
    vertex VSOut prism_layer_vertex(uint vid [[vertex_id]],
                                    constant LayerUniforms& u [[buffer(0)]]) {
        float2 corner = float2(float(vid & 1u), float(vid >> 1u));
        VSOut out;
        float2 ndc = u.ndcRect.xy + corner * u.ndcRect.zw;
        // Rigid rotation of the layer quad about the centre of its frame.
        // Rotation is affine, so rotating the 4 quad corners and letting the
        // rasterizer interpolate the (unchanged) texcoords reproduces the exact
        // rotation of the sampled source. It is aspect-corrected: NDC is
        // anisotropic (x unit = W/2 px, y unit = H/2 px), so we scale x by
        // `aspect` (W/H) into an isotropic pixel space, rotate there, then undo
        // — a square layer stays square, no shear/squeeze. rotation == 0 →
        // cos 1 / sin 0 → this whole block is an identity, so an un-rotated
        // layer is byte-identical to the original path (no regression).
        if (u.rotation != 0.0) {
            float2 centre = u.ndcRect.xy + 0.5 * u.ndcRect.zw;
            float2 d = ndc - centre;
            float2 a = float2(d.x * u.aspect, d.y);         // → isotropic pixel space
            float cs = cos(u.rotation), sn = sin(u.rotation);
            float2 r = float2(a.x * cs - a.y * sn, a.x * sn + a.y * cs);
            ndc = centre + float2(r.x / u.aspect, r.y);     // → back to NDC
        }
        out.position = float4(ndc, 0.0, 1.0);
        // NDC y is up; texture y is down — flip when mapping into the crop rect.
        float2 tc = float2(corner.x, 1.0 - corner.y);
        out.texCoord = u.cropRect.xy + tc * u.cropRect.zw;
        return out;
    }

    // BGRA8 source: one texture, sampled directly.
    fragment float4 prism_layer_fragment_bgra(VSOut in [[stage_in]],
                                              constant LayerUniforms& u [[buffer(0)]],
                                              texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float4 c = tex.sample(s, in.texCoord);
        // Opaque layers (cameras/screens/BGRA whose alpha byte is undefined)
        // force α=1. Premultiplied-matte layers (chroma key / segmentation)
        // honor the sampled alpha; their rgb is ALREADY premultiplied (rgb·α),
        // so scaling float4(rgb, a) by opacity keeps it premultiplied.
        float a = (u.premultiplied != 0u) ? c.a : 1.0;
        return float4(c.rgb, a) * u.opacity; // premultiplied
    }

    // Bi-planar YUV source (420v/420f): luma R8 + chroma RG8, BT.709 matrix
    // in-shader — no CPU or pre-pass conversion, ever (DESIGN.md §3.5).
    fragment float4 prism_layer_fragment_yuv(VSOut in [[stage_in]],
                                             constant LayerUniforms& u [[buffer(0)]],
                                             texture2d<float> luma   [[texture(0)]],
                                             texture2d<float> chroma [[texture(1)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        // MED-9: left/co-sited-horizontal siting shifts the chroma sample by half
        // a luma pixel (chromaOffsetX); centered siting leaves it (offset 0).
        float2 chromaUV = in.texCoord + float2(u.chromaOffsetX, 0.0);
        // wave-5b: `tenBit` selects 8-bit vs 10-bit sampling; 8-bit is byte-identical.
        float3 rgb = prism_sample_yuv_layer(luma, chroma, s, in.texCoord, chromaUV,
                                            u.fullRange, u.yuvMatrix, u.tenBit); // MED-9
        return float4(saturate(rgb), 1.0) * u.opacity; // premultiplied
    }

    // ── Transition mix stage ────────────────────────────────────────────────
    // Fullscreen pass: program = lerp(sceneA, sceneB, mix). The two scene
    // textures were rendered by the same layer pipelines above (same
    // orientation as the output target), so texcoords map 1:1.

    vertex VSOut prism_blit_vertex(uint vid [[vertex_id]]) {
        float2 corner = float2(float(vid & 1u), float(vid >> 1u));
        VSOut out;
        out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
        // NDC y is up; texture y is down.
        out.texCoord = float2(corner.x, 1.0 - corner.y);
        return out;
    }

    fragment float4 prism_mix_fragment(VSOut in [[stage_in]],
                                       constant float& mixFactor [[buffer(0)]],
                                       texture2d<float> sceneA [[texture(0)]],
                                       texture2d<float> sceneB [[texture(1)]]) {
        // 1:1 texel mapping — nearest keeps the blend a pure per-pixel lerp.
        constexpr sampler s(address::clamp_to_edge, filter::nearest);
        return mix(sceneA.sample(s, in.texCoord), sceneB.sample(s, in.texCoord), mixFactor);
    }

    // ── Pixel/tile FX transition stage ──────────────────────────────────────
    // A single fullscreen pass that blends two fully-composited scene textures
    // (A, B) per-pixel for the pixel-effect and tile transition kinds — the
    // live-GPU home of iris / zoomBlur / glitch / animeFlash / speedline and the
    // tile family (blockDissolve / gridWipe / checkerboard / tileReveal /
    // tileFlicker). The math MATCHES the CPU `TransitionRenderer` /
    // `TileSchedule` (the ground-truth reference) so the live compositor look is
    // the real per-pixel effect, not a crossfade.
    //
    // Coordinate contract: the blit vertex maps output-top → texCoord.y=0, so
    // `py = texCoord.y·H` is the CPU memory row (row 0 = visual top) and
    // `px = texCoord.x·W` the column — 1:1 with the CPU raster's (x,y).
    //
    // Determinism: all randomness is SplitMix64 over (seed, tile index) — no
    // Date / rand, derived from the tile index exactly like `TileSchedule`.
    // Endpoints for the one-shot kinds are short-circuited on the CPU side
    // (progress 0 → A, 1 → B), so this pass runs only for 0 < progress < 1.

    struct FXUniforms {
        uint  kind;         // 0 iris 1 zoomBlur 2 glitch 3 animeFlash 4 speedline
                            // 5 blockDissolve 6 gridWipe 7 checkerboard 8 tileReveal 9 tileFlicker
        float progress;     // eased e (0…1)
        float rawProgress;  // raw phase t (glitch split/jitter, flicker loop)
        float softness;     // tile hole feather 0…1
        uint  rows;
        uint  cols;
        uint  direction;    // gridWipe: 0 left 1 right 2 up 3 down
        uint  seedLo;
        uint  seedHi;
        uint  width;
        uint  height;
        uint  pad0;
    };

    // Matches `TileEffects.fxSmoothstep` (edge1<=edge0 → step at edge0).
    inline float fx_smoothstep(float e0, float e1, float x) {
        if (e1 <= e0) return x < e0 ? 0.0 : 1.0;
        float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }

    // SplitMix64 — byte-identical to `TileSchedule.mix64` (64-bit wraparound).
    inline ulong fx_mix64(ulong x) {
        ulong z = x + ((ulong(0x9E3779B9) << 32) | ulong(0x7F4A7C15));
        z = (z ^ (z >> 30)) * ((ulong(0xBF58476D) << 32) | ulong(0x1CE4E5B9));
        z = (z ^ (z >> 27)) * ((ulong(0x94D049BB) << 32) | ulong(0x133111EB));
        return z ^ (z >> 31);
    }

    // Matches `TileSchedule.tileUnit` — deterministic tile value in [0,1).
    inline float fx_tileUnit(ulong seed, uint row, uint col) {
        ulong ridx = ulong(row) * ((ulong(0x00000100) << 32) | ulong(0x000001B3));
        ulong cidx = ulong(col) * ulong(0x9E3779B1);
        ulong idx = ridx ^ cidx;
        ulong h = fx_mix64(seed + fx_mix64(idx));
        return float(h >> 11) * (1.0 / 9007199254740992.0);
    }

    // Per-tile reveal amount (0=A,1=B) for the non-grow tile kinds — matches the
    // corresponding `TileSchedule` schedule (window 0.22).
    inline float fx_tileReveal(constant FXUniforms& u, ulong seed, uint r, uint c) {
        const float window = 0.22;
        if (u.kind == 5u) {                          // blockDissolve
            float thr = fx_tileUnit(seed, r, c) * (1.0 - window);
            return fx_smoothstep(thr, thr + window, u.progress);
        } else if (u.kind == 6u) {                   // gridWipe
            float fx = (float(c) + 0.5) / float(u.cols);
            float fy = (float(r) + 0.5) / float(u.rows);
            float pos;
            if (u.direction == 1u)      pos = fx;        // right
            else if (u.direction == 0u) pos = 1.0 - fx;  // left
            else if (u.direction == 3u) pos = fy;        // down
            else                        pos = 1.0 - fy;  // up
            float thr = pos * (1.0 - window);
            return fx_smoothstep(thr, thr + window, u.progress);
        } else if (u.kind == 7u) {                   // checkerboard
            bool even = ((r + c) & 1u) == 0u;
            return even ? fx_smoothstep(0.0, 0.5, u.progress)
                        : fx_smoothstep(0.5, 1.0, u.progress);
        } else {                                     // tileFlicker (9)
            float off = fx_tileUnit(seed, r, c);
            float p = u.rawProgress - floor(u.rawProgress);
            float x = fract(p + off);
            return 0.5 - 0.5 * cos(2.0 * M_PI_F * x);
        }
    }

    // Neighbour-aware feathered removal — matches `TileSchedule.gridRemoval`.
    inline float fx_tileRemoval(constant FXUniforms& u, ulong seed,
                                uint r, uint c, float localX, float localY,
                                float tileW, float tileH) {
        float rev = fx_tileReveal(u, seed, r, c);
        if (rev <= 0.0) return 0.0;
        float s = clamp(u.softness, 0.0, 1.0);
        if (s <= 0.0) return rev;
        float margin = s * 0.5 * min(tileW, tileH);
        if (margin <= 0.0) return rev;
        float left  = (c > 0u)          ? fx_tileReveal(u, seed, r, c - 1u) : rev;
        float right = (c < u.cols - 1u) ? fx_tileReveal(u, seed, r, c + 1u) : rev;
        float up    = (r > 0u)          ? fx_tileReveal(u, seed, r - 1u, c) : rev;
        float down  = (r < u.rows - 1u) ? fx_tileReveal(u, seed, r + 1u, c) : rev;
        float feather = 1.0;
        if (left  < rev) feather = min(feather, fx_smoothstep(0.0, margin, localX));
        if (right < rev) feather = min(feather, fx_smoothstep(0.0, margin, tileW - localX));
        if (up    < rev) feather = min(feather, fx_smoothstep(0.0, margin, localY));
        if (down  < rev) feather = min(feather, fx_smoothstep(0.0, margin, tileH - localY));
        return rev * feather;
    }

    fragment float4 prism_fx_fragment(VSOut in [[stage_in]],
                                      constant FXUniforms& u [[buffer(0)]],
                                      texture2d<float> texA [[texture(0)]],
                                      texture2d<float> texB [[texture(1)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::nearest);
        float2 tc = in.texCoord;
        float W = float(u.width), H = float(u.height);
        float px = tc.x * W, py = tc.y * H;
        float e = clamp(u.progress, 0.0, 1.0);
        ulong seed = (ulong(u.seedHi) << 32) | ulong(u.seedLo);

        if (u.kind == 0u) {                          // iris — circular reveal of B
            float maxR = 0.5 * sqrt(W * W + H * H) * e;
            float d = distance(float2(px, py), float2(W * 0.5, H * 0.5));
            float4 c = (d <= maxR) ? texB.sample(s, tc) : texA.sample(s, tc);
            return float4(c.rgb, 1.0);
        } else if (u.kind == 1u) {                   // zoomBlur
            // A zooms out (base), then 5 radial-scaled B samples source-over.
            float sA = 1.0 + 0.6 * e;
            float2 uvA = (tc - 0.5) / sA + 0.5;
            float4 col = texA.sample(s, uvA);
            float strength = sin(M_PI_F * e);
            float baseScaleB = 1.0 + 0.4 * (1.0 - e);
            const int samples = 5;
            for (int i = 0; i < samples; ++i) {
                float k = (float(i) / float(samples - 1) - 0.5) * 2.0;
                float sB = baseScaleB * (1.0 + 0.08 * strength * k);
                float2 uvB = (tc - 0.5) / sB + 0.5;
                if (all(uvB >= 0.0) && all(uvB <= 1.0)) {  // outside = not drawn
                    float aB = e / float(samples);
                    float4 bs = texB.sample(s, uvB);
                    col = bs * aB + col * (1.0 - aB);       // source-over
                }
            }
            return float4(col.rgb, 1.0);
        } else if (u.kind == 2u) {                   // glitch — RGB-split + row jitter
            float t = clamp(u.rawProgress, 0.0, 1.0);
            float split = round(sin(M_PI_F * t) * 0.028 * W);
            int i = int(px), j = int(py);
            int band = j / 24;
            uint jig = (uint(band) * 2654435761u) & 0xFFu;
            int amt = int(float(jig) / 255.0 * 6.0 * sin(M_PI_F * t));
            int jitter = (band % 2 == 0) ? amt : -amt;
            int isplit = int(split);
            int wI = int(W);
            float vy = (float(j) + 0.5) / H;         // band row centre
            // base(x') = mix(A,B,e); R from x+split, G from x, B from x−split (+jitter).
            int sxR = clamp(i + isplit + jitter, 0, wI - 1);
            int sxG = clamp(i          + jitter, 0, wI - 1);
            int sxB = clamp(i - isplit + jitter, 0, wI - 1);
            float2 tR = float2((float(sxR) + 0.5) / W, vy);
            float2 tG = float2((float(sxG) + 0.5) / W, vy);
            float2 tB = float2((float(sxB) + 0.5) / W, vy);
            float R = mix(texA.sample(s, tR), texB.sample(s, tR), e).r;
            float G = mix(texA.sample(s, tG), texB.sample(s, tG), e).g;
            float B = mix(texA.sample(s, tB), texB.sample(s, tB), e).b;
            return float4(R, G, B, 1.0);
        } else if (u.kind == 3u) {                   // animeFlash — blow to white
            float flash = pow(1.0 - fabs(2.0 * e - 1.0), 0.55);
            float4 base = (e < 0.5) ? texA.sample(s, tc) : texB.sample(s, tc);
            float3 rgb = float3(1.0) * flash + base.rgb * (1.0 - flash);
            return float4(rgb, 1.0);
        } else if (u.kind == 4u) {                   // speedline — radial white wedges
            float4 base = mix(texA.sample(s, tc), texB.sample(s, tc), e);
            float coverage = sin(M_PI_F * e);
            float sweep = e * 0.35;
            // CPU renders in a bottom-left (y-up) context → flip y about centre.
            float2 d = float2(px - W * 0.5, H * 0.5 - py);
            float theta = atan2(d.y, d.x);
            float stepA = 2.0 * M_PI_F / 56.0;
            float halfAng = 0.006 + 0.010 * coverage;
            float rel = theta - sweep;
            float nearest = round(rel / stepA) * stepA;
            float adist = fabs(rel - nearest);       // angular dist to nearest wedge
            float3 rgb = base.rgb;
            if (coverage > 0.0 && adist <= halfAng) {
                float aw = 0.85 * coverage;
                rgb = float3(1.0) * aw + base.rgb * (1.0 - aw);
            }
            return float4(rgb, 1.0);
        } else {                                     // tiles 5..9 → hole-punch over B
            float tileW = W / float(u.cols);
            float tileH = H / float(u.rows);
            uint col = min(uint(px / tileW), u.cols - 1u);
            uint row = min(uint(py / tileH), u.rows - 1u);
            float localX = px - float(col) * tileW;
            float localY = py - float(row) * tileH;
            float removal;
            if (u.kind == 8u) {                      // tileReveal centred grow box
                float f = e;
                float sft = clamp(u.softness, 0.0, 1.0);
                float halfW = 0.5 * tileW * f, halfH = 0.5 * tileH * f;
                float dx = fabs(localX - tileW * 0.5), dy = fabs(localY - tileH * 0.5);
                float m = max(0.75, sft * 0.5 * min(tileW, tileH));
                float insideX = 1.0 - fx_smoothstep(halfW - m, halfW + m, dx);
                float insideY = 1.0 - fx_smoothstep(halfH - m, halfH + m, dy);
                removal = insideX * insideY;
            } else {
                removal = fx_tileRemoval(u, seed, row, col, localX, localY, tileW, tileH);
            }
            // Premultiplied hole: A survives by f=(1−removal), B reveals through.
            // out = A·f + B·(1−f) == mix(B, A, f); f=0 → B (never black).
            float f = 1.0 - clamp(removal, 0.0, 1.0);
            float4 A = texA.sample(s, tc);
            float4 B = texB.sample(s, tc);
            float3 rgb = mix(B.rgb, A.rgb, f);
            return float4(rgb, 1.0);
        }
    }

    // ── HDR (HLG/Rec.2020) LINEAR-LIGHT output path (sol #3 rebuild) ─────────
    // ADDITIVE: the SDR fragments above are untouched. These variants run ONLY
    // when the compositor is constructed in `.hdr` mode.
    //
    // ARCHITECTURE — broadcast-correct HDR compositing (BT.2100):
    //   1. WORKING SPACE: an RGBA16Float accumulation target in **Rec.2020 LINEAR
    //      light** (scene-referred HLG linear). Blending in a non-linear (encoded)
    //      space is physically wrong — 50% of white over black must be half the
    //      LIGHT, then encoded, not half the SIGNAL.
    //   2. PER-LAYER DECODE: each layer fragment decodes to Rec.2020 linear
    //      according to its OWN transfer tag — SDR/Rec.709 → BT.709 EOTF; true HLG
    //      → BT.2100 HLG INVERSE-OETF; PQ → ST 2084 EOTF (see the per-transfer note
    //      below). Primaries are rotated 709→2020 IN LINEAR LIGHT unless the source
    //      is already Rec.2020 (N4). The fragment outputs the LINEAR value,
    //      premultiplied by α·opacity — it does NOT encode.
    //   3. LINEAR BLEND: the premultiplied-alpha blend (one, 1−srcAlpha) runs in
    //      the linear working target, so opacity + matte compositing is in light.
    //   4. FINAL ENCODE (ONCE): after the whole program is composited,
    //      `prism_hlg_encode_fragment` applies the BT.2100 HLG OETF a single time,
    //      writing the tagged Rec.2020/HLG 10-bit output.
    //
    // The pre-rebuild path was wrong two ways sol confirmed by pixel probe:
    //   - it HLG-encoded per layer and blended in HLG-ENCODED space → 50% white
    //     over black emitted 511/1023 (correct linear→HLG is ≈892);
    //   - it decoded every source with the BT.709 EOTF, so a TRUE-HLG gray 192/255
    //     emitted ≈916/1023 (correct HLG-inverse-OETF round-trip is ≈771).
    //
    // DOCUMENTED RESIDUAL (honest, not silently wrong): NO scene-referred OOTF /
    // system-gamma tone-map is applied — the reference system gamma is treated as
    // γ = 1, so the working space is HLG SCENE-linear and the final OETF is a plain
    // scene→signal encode. This is the standard display-referred approximation and
    // is what makes the two spec targets exact (HLG_OETF(0.5)·1023 = 892; a true-
    // HLG source round-trips to itself). A true BT.2100 OOTF (γ ≈ 1.2 @ 1000 nits,
    // applied on luminance) plus a defined nominal peak would be the next step; it
    // is deferred, not hidden. SDR sources are treated display-referred (709 EOTF
    // output ≡ scene-linear). PQ (absolute) → HLG (relative) carries no luminance
    // tone-map (see `prism_pq_eotf_norm`).

    // BT.2100 / ARIB STD-B67 HLG OETF: SCENE-LINEAR [0,1] → HLG signal. OETF(0)=0,
    // OETF(1)=1; mid-tones bend onto the HLG curve.
    inline float3 prism_hlg_oetf(float3 e) {
        const float a = 0.17883277;
        const float b = 0.28466892;
        const float c = 0.55991073;
        float3 lo = sqrt(max(e, 0.0) * 3.0);
        float3 hi = a * log(max(12.0 * e - b, 1e-6)) + c;
        return select(hi, lo, e <= (1.0 / 12.0));
    }

    // BT.2100 HLG INVERSE-OETF: HLG signal [0,1] → scene-linear [0,1]. Exact
    // inverse of `prism_hlg_oetf`, so a true-HLG source decoded here then re-encoded
    // by the final pass round-trips to itself (NO 709-EOTF corruption). No OOTF.
    inline float prism_hlg_inverse_oetf(float v) {
        const float a = 0.17883277;
        const float b = 0.28466892;
        const float c = 0.55991073;
        return v <= 0.5 ? (v * v) / 3.0
                        : (exp((v - c) / a) + b) / 12.0;
    }

    inline float prism_eotf709(float v) {   // display 709 (gamma-coded) → linear
        return v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1.0 / 0.45);
    }

    // sol #4 finding 3: sRGB (IEC 61966-2-1) EOTF, gamma-coded → linear. A DIFFERENT
    // curve from Rec.709 (0.055 offset + 2.4 exponent + 1/12.92 toe vs 709's 0.099 +
    // 1/0.45 + 1/4.5) — a generated sRGB gray 128 → ≈726, not the 709-EOTF's ≈765.
    inline float prism_eotf_srgb(float v) {
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
    }

    // sol wave-11 #5: ODD-SYMMETRIC (signed) EOTFs for the extended sRGB/709 transfer.
    // An extended-range colorspace (extendedSRGB / extendedITUR_2020 / extendedDisplayP3)
    // carries legal NEGATIVE coded components (wide-gamut colors OUTSIDE the 709 triangle).
    // The one-sided lower clamp (pre-decode saturate, or the post-rotate `max(lin,0)`)
    // crushed those to 0, so extendedSRGB(-0.2,0.5,0.5) composited (469,708,720) instead of
    // the spec (430,707,720). Decode a signed component as sign(x)·EOTF(|x|) so the negative
    // survives into the linear blend; the SINGLE final output encode clamps the DISPLAY.
    // For a BOUNDED (non-extended) source the input is pre-saturated ≥0, so sign(x)·EOTF(|x|)
    // == EOTF(x) — BYTE-IDENTICAL (never take the negative branch).
    inline float prism_eotf_srgb_signed(float v) { return sign(v) * prism_eotf_srgb(fabs(v)); }
    inline float prism_eotf709_signed(float v)   { return sign(v) * prism_eotf709(fabs(v)); }

    // SMPTE ST 2084 (BT.2100 PQ) EOTF: PQ signal [0,1] → display-linear, where 1.0
    // = 10000 nits. Normalized to a nominal 1000-nit HLG peak (×10, saturated) so a
    // PQ layer shares the HLG linear working range. APPROXIMATION: no PQ↔HLG
    // luminance tone-map (documented residual above); PQ ingest into a live HLG
    // program is rare.
    inline float prism_pq_eotf_norm(float v) {
        const float m1 = 0.1593017578125;
        const float m2 = 78.84375;
        const float c1 = 0.8359375;
        const float c2 = 18.8515625;
        const float c3 = 18.6875;
        float vp = pow(max(v, 0.0), 1.0 / m2);
        float num = max(vp - c1, 0.0);
        float den = c2 - c3 * vp;
        float y = pow(num / max(den, 1e-6), 1.0 / m1);   // 1.0 = 10000 nits
        return saturate(y * 10.0);                        // → ~1000-nit HLG peak
    }

    // Decode the source's coded R'G'B' to Rec.2020 LINEAR light per its transfer
    // tag, then (only if it is not already Rec.2020) rotate the primaries 709→2020
    // IN LINEAR LIGHT. Returns the LINEAR Rec.2020 value the compositor blends —
    // NO output encode here. The 3×3 primary matrix rows sum to 1, so the neutral
    // axis (r==g==b, incl. white/black/gray) is preserved exactly.
    // transferFn: 0 Rec.709 · 1 HLG · 2 PQ · 3 sRGB · 4 Linear (sol #4 finding 3).
    // rotate:     0 already-2020 · 1 709→2020 · 2 P3→2020 (sol #4 finding 3).
    inline float3 prism_to_scene_linear_2020(float3 rgbCoded, uint rotate, uint transferFn, uint extendedRange) {
        float3 lin;
        if (transferFn == 1u) {          // true HLG signal → scene-linear
            lin = float3(prism_hlg_inverse_oetf(rgbCoded.r),
                         prism_hlg_inverse_oetf(rgbCoded.g),
                         prism_hlg_inverse_oetf(rgbCoded.b));
        } else if (transferFn == 2u) {   // PQ signal → normalized linear
            lin = float3(prism_pq_eotf_norm(rgbCoded.r),
                         prism_pq_eotf_norm(rgbCoded.g),
                         prism_pq_eotf_norm(rgbCoded.b));
        } else if (transferFn == 3u) {   // sRGB signal → linear (finding 3)
            // sol wave-11 #5: odd-symmetric so a legal NEGATIVE extended-sRGB component
            // decodes to sign(x)·EOTF(|x|) (bounded/pre-saturated input → byte-identical).
            lin = float3(prism_eotf_srgb_signed(rgbCoded.r),
                         prism_eotf_srgb_signed(rgbCoded.g),
                         prism_eotf_srgb_signed(rgbCoded.b));
        } else if (transferFn == 4u) {   // already scene-linear → SKIP the EOTF (finding 3)
            // sol #7 #5new: Linear is an EXTENDED-RANGE (EDR) float working value —
            // carry highlights > 1 through the linear-light opacity/blend (clamp only
            // at the final output encode).
            // sol wave-11 #5: an EXTENDED-linear source (extendedLinearSRGB/2020/P3) also
            // carries legal NEGATIVE wide-gamut components — pass the SIGNED value straight
            // through so extendedLinearSRGB(-0.05,…) survives (was max→0, clipping it to
            // 695 vs the spec 656). A BOUNDED linear source lower-bounds (no negative light).
            lin = (extendedRange != 0u) ? rgbCoded : max(rgbCoded, 0.0);
        } else {                         // Rec.709 (default / untagged)
            lin = float3(prism_eotf709_signed(rgbCoded.r),
                         prism_eotf709_signed(rgbCoded.g),
                         prism_eotf709_signed(rgbCoded.b));
        }
        // Primary rotation into the Rec.2020 working gamut. Rows sum to 1, so the
        // neutral axis (r==g==b, incl. white/black/gray) is preserved exactly.
        if (rotate == 1u) {              // Rec.709 → Rec.2020
            lin = float3(
                0.627404 * lin.r + 0.329283 * lin.g + 0.043313 * lin.b,
                0.069097 * lin.r + 0.919540 * lin.g + 0.011362 * lin.b,
                0.016391 * lin.r + 0.088013 * lin.g + 0.895595 * lin.b);
        } else if (rotate == 2u) {       // Display P3 → Rec.2020 (finding 3)
            lin = float3(
                0.753833 * lin.r + 0.198597 * lin.g + 0.047570 * lin.b,
                0.045744 * lin.r + 0.941777 * lin.g + 0.012479 * lin.b,
               -0.001210 * lin.r + 0.017602 * lin.g + 0.983609 * lin.b);
        } else if (rotate == 3u) {       // Generic-RGB → Rec.2020 (sol wave-10 #4)
            // Classic Apple "Generic RGB" gamut R(0.63,0.34) G(0.295,0.605)
            // B(0.155,0.077) D65 → Rec.2020 linear. Rows sum to 1 (neutral preserved).
            // A saturated genericRGBLinear red now composites ≈(942,530,230) matching
            // the Core-Image-color-managed oracle, not the 709→2020 (935,466,227).
            lin = float3(
                0.649557 * lin.r + 0.295451 * lin.g + 0.054992 * lin.b,
                0.088655 * lin.r + 0.869899 * lin.g + 0.041446 * lin.b,
                0.016927 * lin.r + 0.081712 * lin.g + 0.901360 * lin.b);
        }
        // sol #7 #5new + sol #8 #6 + sol wave-11 #5: an EXTENDED-RANGE transfer carries
        // BOTH highlights > 1 AND (for a signed wide-gamut source) legal NEGATIVE post-
        // rotation components — return them fully UN-clamped so the linear-light blend sees
        // true light AND true wide-gamut chroma; the single final output encode applies the
        // only clamp (prism_hlg_encode_fragment). Three cases:
        //   • extendedRange 1 (nonlinear extendedSRGB/709/P3 OR extendedLinear*): the coded
        //     value can be > 1 (highlight) or < 0 (wide-gamut) — DO NOT clamp either bound,
        //     so extendedSRGB(-0.2,…)→(430,…) not the lower-clamped (500,…). Any residual
        //     out-of-2020 negative survives to the final encode (which max(e,0)s the display).
        //   • transferFn 4 (bounded Linear): scene-linear, >1 = a highlight, but no negative
        //     light — lower-bound only (unchanged).
        //   • every bounded transfer (true SDR / HLG / PQ / plain sRGB) saturates (unchanged).
        if (extendedRange != 0u) {
            return lin;             // LINEAR, Rec.2020 primaries, EDR highlights + signed wide-gamut preserved
        }
        if (transferFn == 4u) {
            return max(lin, 0.0);   // bounded Linear: EDR highlights, no negative light
        }
        return saturate(lin);   // LINEAR, Rec.2020 primaries
    }

    // BGRA8 source → Rec.2020 LINEAR (premultiplied) into the linear working
    // target. NO HLG OETF here — the single final encode pass does that after the
    // linear blend.
    //
    // Premultiplied-alpha correctness (#6): decode must see the STRAIGHT color, so
    // UN-premultiply → decode-to-linear → RE-premultiply by α. For an opaque pixel
    // (α==1) this is an exact no-op. The re-premultiplied LINEAR value blends
    // correctly in the (one, 1−srcAlpha) linear target.
    fragment float4 prism_layer_fragment_bgra_linear2020(VSOut in [[stage_in]],
                                                         constant LayerUniforms& u [[buffer(0)]],
                                                         texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float4 col = tex.sample(s, in.texCoord);
        float alpha = (u.premultiplied != 0u) ? col.a : 1.0;
        // sol #7 #5new + sol #8 #6: keep an EXTENDED-RANGE source's straight value
        // UN-clamped above 1 so a legal > 1 highlight reaches the transfer decode (a
        // Linear EDR value, OR a nonlinear extendedSRGB/709/P3 coded value); clamp the
        // un-premultiply only for the bounded [0,1] transfers (true SDR / HLG / PQ /
        // plain sRGB), which stay byte-identical.
        float3 straight = (alpha > 0.0) ? (col.rgb / alpha) : float3(0.0);
        if (u.transferFn != 4u && u.extendedRange == 0u) straight = saturate(straight);
        float3 lin2020 = prism_to_scene_linear_2020(straight, u.rotateTo2020, u.transferFn, u.extendedRange);
        return float4(lin2020 * alpha, alpha) * u.opacity; // premultiplied LINEAR
    }

    // Bi-planar YUV source → decode → Rec.2020 LINEAR (premultiplied). Opaque
    // (α≡1). NO HLG OETF here — the final encode pass applies it once.
    fragment float4 prism_layer_fragment_yuv_linear2020(VSOut in [[stage_in]],
                                                        constant LayerUniforms& u [[buffer(0)]],
                                                        texture2d<float> luma   [[texture(0)]],
                                                        texture2d<float> chroma [[texture(1)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float2 chromaUV = in.texCoord + float2(u.chromaOffsetX, 0.0);        // MED-9 siting
        // wave-5b: 10-bit (x420/xf20) decode feeds the SAME linear-light HDR path — a
        // real 10-bit HLG/PQ source is decoded (per `transferFn`) to Rec.2020 linear.
        float3 rgb = prism_sample_yuv_layer(luma, chroma, s, in.texCoord, chromaUV,
                                            u.fullRange, u.yuvMatrix, u.tenBit); // MED-9 matrix
        // A biplanar YUV source is integer-coded in [0,1] (no extended range), so the
        // input clamp + extendedRange 0 keep this path byte-identical.
        float3 lin2020 = prism_to_scene_linear_2020(saturate(rgb), u.rotateTo2020, u.transferFn, u.extendedRange);
        return float4(lin2020, 1.0) * u.opacity; // premultiplied LINEAR (opaque)
    }

    // FINAL HDR OUTPUT TRANSFER — applied ONCE, after the entire program is
    // composited in the Rec.2020 linear working target. Reads the linear texture,
    // applies the BT.2100 HLG OETF, writes the 10-bit Rec.2020/HLG signal. The
    // program base is opaque black (α=1), so the un-premultiply is an exact no-op
    // there; it is done anyway so any residual partial-alpha is transfer-correct
    // (OETF(α·C) ≠ α·OETF(C)). Blending is disabled for this pass.
    fragment float4 prism_hlg_encode_fragment(VSOut in [[stage_in]],
                                              texture2d<float> lin [[texture(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::nearest);
        float4 c = lin.sample(s, in.texCoord);
        float a = c.a;
        float3 straight = (a > 0.0) ? saturate(c.rgb / a) : float3(0.0);
        float3 hlg = prism_hlg_oetf(straight);
        return float4(hlg, 1.0);   // opaque HLG-encoded Rec.2020 program pixel
    }

    // ── Per-source effect stages (GPU offload of the CPU VisualFX renderers) ──
    // SINGLE-source fullscreen passes (frame in → frame out) that MATCH the CPU
    // reference renderers — TileMask / StrobeEffect / BeatPulseRenderer /
    // TileRepeatRenderer — so the app's per-source pipeline runs them on the GPU
    // (sub-ms) instead of paying per-frame CoreGraphics. All use the fullscreen
    // `prism_blit_vertex` quad, so `texCoord` at output pixel (x,y) is
    // ((x+0.5)/W, (y+0.5)/H) — 1:1 with the CPU raster's PIXEL CENTRES (row 0 =
    // visual top), the same coordinate contract as `prism_fx_fragment`.
    //
    // Blending is DISABLED for these passes (the app binds a `.dontCare` /
    // no-blend target): each fragment writes the final premultiplied pixel
    // directly, so a tile hole's alpha-0 pixels are stored verbatim (never
    // clobbered to opaque black — this codebase's recurring premultiplied bug).

    // TileMask — the "square boxes reveal what's underneath" LAYER effect. Punch
    // the animated grid of holes into ONE frame's premultiplied alpha; the app
    // feeds the result to a `premultipliedAlpha: true` layer so the compositor
    // reveals the layers beneath. Reuses `FXUniforms` (kind 5..9) and the exact
    // `fx_tileRemoval` / grow-box math of `prism_fx_fragment`, matching
    // `TileMask.apply` / `punchTileHoles` (out = src·(1−removal), all four
    // premultiplied channels scaled together → a TRUE alpha-0 hole at removal 1).
    fragment float4 prism_srcfx_tilemask(VSOut in [[stage_in]],
                                         constant FXUniforms& u [[buffer(0)]],
                                         texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::nearest);
        float2 tc = in.texCoord;
        float W = float(u.width), H = float(u.height);
        float px = tc.x * W, py = tc.y * H;
        ulong seed = (ulong(u.seedHi) << 32) | ulong(u.seedLo);
        float tileW = W / float(u.cols);
        float tileH = H / float(u.rows);
        uint col = min(uint(px / tileW), u.cols - 1u);
        uint row = min(uint(py / tileH), u.rows - 1u);
        float localX = px - float(col) * tileW;
        float localY = py - float(row) * tileH;
        float removal;
        if (u.kind == 8u) {                          // tileReveal centred grow box
            float f = clamp(u.progress, 0.0, 1.0);
            float sft = clamp(u.softness, 0.0, 1.0);
            float halfW = 0.5 * tileW * f, halfH = 0.5 * tileH * f;
            float dx = fabs(localX - tileW * 0.5), dy = fabs(localY - tileH * 0.5);
            float m = max(0.75, sft * 0.5 * min(tileW, tileH));
            float insideX = 1.0 - fx_smoothstep(halfW - m, halfW + m, dx);
            float insideY = 1.0 - fx_smoothstep(halfH - m, halfH + m, dy);
            removal = insideX * insideY;
        } else {
            removal = fx_tileRemoval(u, seed, row, col, localX, localY, tileW, tileH);
        }
        float f = 1.0 - clamp(removal, 0.0, 1.0);
        return tex.sample(s, tc) * f;                // premultiplied hole
    }

    // Strobe — a full-frame color flash that PRESERVES source alpha (Class C).
    // Premultiplied flash of a straight `color` at alpha `amount`, scaled by the
    // source alpha (out.rgb = src·(1−a) + colorStraight·a·src.a, out.a = src.a),
    // matching `StrobeEffect.apply` (the exponential envelope is evaluated CPU-side
    // and passed as `amount`).
    struct SrcStrobeUniforms {
        float4 color;   // straight (un-premultiplied) flash color; .a ignored (folded into amount)
        float  amount;  // flash alpha 0…1 (envelope · intensity · color.a)
        float  pad0; float pad1; float pad2;
    };
    fragment float4 prism_srcfx_strobe(VSOut in [[stage_in]],
                                       constant SrcStrobeUniforms& u [[buffer(0)]],
                                       texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::nearest);
        float4 c = tex.sample(s, in.texCoord);
        float a = clamp(u.amount, 0.0, 1.0);
        // Class C: PRESERVE the source's alpha. `c` is premultiplied, so scale the
        // flash-colour term by the source alpha `c.a` too. A fully-transparent /
        // keyed texel (c.a == 0) stays transparent — it must NOT flash and cover
        // the layers beneath — while a fully-opaque texel (c.a == 1) is byte-for-
        // byte the pre-fix look. Partial-alpha edges flash proportionally.
        float3 rgb = c.rgb * (1.0 - a) + u.color.rgb * (a * c.a);
        float alpha = c.a;
        return float4(rgb, alpha);
    }

    // BeatPulse — uniform scale-about-centre + shake-offset. Matches
    // `BeatPulseRenderer.render` (the pure `BeatPulse.pulse` transform is computed
    // CPU-side and passed as scale/dx/dy). Inverse-maps each output texel to the
    // source; texels the (offset/scaled) source does not cover show `background`.
    // Coordinate parity: `dx` is a +x fraction of width; `dy` positive = screen-
    // DOWN = +texCoord.y (the CPU's −y in its bottom-left context). Uniform pixel
    // scale about the pixel centre == uniform scale about texCoord (0.5,0.5).
    struct SrcPulseUniforms {
        float  scale; float dx; float dy; float pad0;
        float4 background;   // straight rgba; premultiplied in-shader
    };
    fragment float4 prism_srcfx_beatpulse(VSOut in [[stage_in]],
                                          constant SrcPulseUniforms& u [[buffer(0)]],
                                          texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float2 tc = in.texCoord;
        float sc = max(u.scale, 1e-4);
        float2 src = (tc - float2(u.dx, u.dy) - 0.5) / sc + 0.5;
        float3 bgp = u.background.rgb * u.background.a;      // premultiplied bg
        if (all(src >= float2(0.0)) && all(src <= float2(1.0))) {
            float4 c = tex.sample(s, src);                   // premultiplied source
            float3 rgb = c.rgb + bgp * (1.0 - c.a);          // source-over bg
            float alpha = c.a + u.background.a * (1.0 - c.a);
            return float4(rgb, alpha);
        }
        return float4(bgp, u.background.a);
    }

    // VideoWall — one source drawn into an rows×cols grid (kaleidoscope when
    // `mirror`). Matches `TileRepeatRenderer.render`: each cell samples the FULL
    // source; with `mirror`, odd columns flip horizontally and odd rows flip
    // vertically about the cell centre.
    struct SrcWallUniforms { uint rows; uint cols; uint mirror; uint pad0; };
    fragment float4 prism_srcfx_videowall(VSOut in [[stage_in]],
                                          constant SrcWallUniforms& u [[buffer(0)]],
                                          texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float2 tc = in.texCoord;
        float fx = tc.x * float(u.cols);
        float fy = tc.y * float(u.rows);
        uint c = min(uint(fx), u.cols - 1u);
        uint r = min(uint(fy), u.rows - 1u);
        float uu = fx - float(c);
        float vv = fy - float(r);
        if (u.mirror != 0u) {
            if ((c & 1u) == 1u) uu = 1.0 - uu;
            if ((r & 1u) == 1u) vv = 1.0 - vv;
        }
        return tex.sample(s, float2(uu, vv));
    }

    // YUV→BGRA normalize pre-pass for SourceEffectGPU. Live camera/screen/link
    // sources emit bi-planar 420v/420f; the srcfx effect shaders above all assume
    // a straight BGRA input (the CPU reference renderers operate on BGRA). This
    // decodes luma R8 + chroma RG8 with the EXACT SAME matrix + siting math as the
    // compositor's own `prism_layer_fragment_yuv` layer decode (opacity ≡ 1,
    // alpha ≡ 1 = opaque) into a pooled BGRA texture, which the effect pass then
    // reads — so a camera frame is color-converted identically to the composited
    // layer path before the tile/strobe/pulse/wall effect runs, INCLUDING the
    // source's tagged YCbCr matrix (601/709/2020) and chroma siting (N5/finding-9;
    // previously hardcoded centered BT.709, so a 601/2020/left-sited source with
    // any effect took a hue/half-pixel shift the downstream BGRA path can't repair).
    struct SrcYUVUniforms { uint fullRange; uint yuvMatrix; float chromaOffsetX; uint tenBit; };
    fragment float4 prism_srcfx_yuv_to_bgra(VSOut in [[stage_in]],
                                            constant SrcYUVUniforms& u [[buffer(0)]],
                                            texture2d<float> luma   [[texture(0)]],
                                            texture2d<float> chroma [[texture(1)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        // N5: left/co-sited siting shifts the chroma sample by half a luma pixel.
        float2 chromaUV = in.texCoord + float2(u.chromaOffsetX, 0.0);
        // wave-5b: `tenBit` selects 8-bit vs 10-bit (P010-style) sampling. For a
        // 10-bit source the effect pass runs on an rgba16Float intermediate/output
        // (SourceEffectGPU), so no precision is lost to an 8-bit normalize here.
        float3 rgb = prism_sample_yuv_layer(luma, chroma, s, in.texCoord, chromaUV,
                                            u.fullRange, u.yuvMatrix, u.tenBit); // N5: tagged matrix
        return float4(saturate(rgb), 1.0);   // opaque straight RGB
    }
    """
}
