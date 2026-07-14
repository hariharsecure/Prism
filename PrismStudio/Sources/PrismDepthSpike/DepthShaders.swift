import Foundation

/// Embedded MSL for the isolated Phase-0 z-aware composite kernel, compiled at
/// runtime via `device.makeLibrary(source:options:)` — the same pattern the
/// production `PrismColor`/`PrismCompositor` shaders use (SPM cannot compile a
/// `.metal` file into a library target). This is a SPIKE kernel: it lives only
/// in `PrismDepthSpike` and never touches the production compositor.
///
/// Full-float32 path (rgba32Float color, r32Float depth) so the compare/blend
/// is pixel-exact against a Double oracle — precision over bandwidth, because
/// this is a math proof, not the shipping bandwidth-tuned path.
enum DepthShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct CompositeUniforms {
        float feather;              // half-width (m); <=0 => hard step
        float epsilon;              // decision bias (m)
        int   sceneInvalidFallback; // 1 = show flat character, 0 = hide
        int   charInvalidVisibility;// 0 = conservative hide
    };

    // Depth-aware character-over-plate composite. All depths are camera
    // optical-axis Z in meters, in a common camera space. Invalid depth is a
    // non-positive sentinel (never a plausible zero — design's validity
    // contract); a valid axial Z is strictly positive.
    kernel void prism_depth_composite(
        texture2d<float, access::read>  plateColor [[texture(0)]],
        texture2d<float, access::read>  charColor  [[texture(1)]], // premultiplied
        texture2d<float, access::read>  charDepth  [[texture(2)]],
        texture2d<float, access::read>  sceneDepth [[texture(3)]],
        texture2d<float, access::write> outColor   [[texture(4)]],
        constant CompositeUniforms&     U          [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= outColor.get_width() || gid.y >= outColor.get_height()) return;

        float4 plate = plateColor.read(gid);
        float4 chr   = charColor.read(gid);   // premultiplied rgb, straight-ish a
        float  cz    = charDepth.read(gid).r;
        float  sz    = sceneDepth.read(gid).r;

        // Validity: a valid axial Z is strictly positive. `!(z > 0)` catches
        // NaN AND any non-positive sentinel — robust under Metal's math modes
        // (the library is compiled with fast-math OFF so NaN compares per IEEE).
        bool czValid = cz > 0.0f;
        bool szValid = sz > 0.0f;

        float visibility;
        if (chr.a <= 0.0f) {
            visibility = 0.0f;                                  // no coverage
        } else if (!czValid) {
            visibility = float(U.charInvalidVisibility);        // char depth invalid
        } else if (!szValid) {
            visibility = float(U.sceneInvalidFallback);         // scene depth invalid
        } else {
            float delta = sz - cz;                              // >0 => char in front
            if (U.feather <= 0.0f) {
                visibility = (delta - U.epsilon > 0.0f) ? 1.0f : 0.0f;
            } else {
                float t = (delta - U.epsilon) / (2.0f * U.feather) + 0.5f;
                visibility = clamp(t, 0.0f, 1.0f);
            }
        }

        // BOTH rgb and alpha scaled by visibility, then premultiplied over the
        // plate. With a transparent plate this returns the scaled character
        // exactly (the "rgb AND alpha both scaled" test).
        float4 scaledChar = chr * visibility;
        float4 outC = scaledChar + plate * (1.0f - scaledChar.a);
        outColor.write(outC, gid);
    }
    """
}
