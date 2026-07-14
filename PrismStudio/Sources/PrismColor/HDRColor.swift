import Foundation
import simd

/// HDR (P3/HLG, Rec.2020) transfer + working-space handling for the color
/// stage — the v2+ fork of the pipeline (DESIGN.md §2.5 "HDR (P3/HLG) pipeline
/// end-to-end", §3.5 "P010/HDR is the v2+ fork").
///
/// **What this module owns today (honest scope).** `ColorProcessor` /
/// `FrameAnalyzer` / `RelightProcessor` run in a v0 SDR working space:
/// gamma-encoded BT.709 values, a pure-2.2 "linear-ish" leg, and a final
/// `saturate` clamp to [0,1] (see `ColorShaders`). That path is unchanged and
/// remains the default. This file adds the transfer math and the documented
/// decisions the HDR path needs, so the compositor's HLG output (PrismCompositor
/// `.hdr` mode) and the HEVC-Main10 recorder (PrismOutput) are honored.
///
/// **Tone-mapping caveats (be honest — none of these are magic).**
///  - The grade kernel still clamps to SDR range. Running an SDR-clamped grade
///    *before* HLG encoding compresses highlights into the [0,1] display range —
///    correct for a pass-through look, wrong if you want to grade into HDR
///    headroom. Grading in the HDR working range (no SDR clamp, values allowed
///    above the 0.75 HLG "reference white") is a tracked follow-up; today the
///    HDR path composites and HLG-encodes *without* re-clamping in the
///    compositor, but per-source grading (if inserted) is still SDR-scoped.
///  - No gamut rotation: BT.709-decoded primaries are HLG-encoded in place, not
///    rotated into Rec.2020/P3 primaries. Colors are correct in hue but do not
///    yet use the wider gamut volume.
///  - No PQ (ST.2084) path here — HLG only. PQ needs an absolute-nits master
///    and display metadata; deferred.
public enum HDRColor {
    /// HDR transfer functions this pipeline can tag/encode. HLG is implemented;
    /// PQ is declared for API completeness but not yet encoded.
    public enum Transfer: String, Sendable {
        /// ITU-R BT.2100 Hybrid Log-Gamma (ARIB STD-B67). Scene-referred,
        /// display-adaptive, no static metadata — the pragmatic choice for a
        /// live pipeline and iPhone HDR capture.
        case hlg
        /// ITU-R BT.2100 Perceptual Quantizer (ST.2084). Not yet encoded.
        case pq
    }

    /// HLG "reference white" in the signal domain (BT.2100): diffuse white sits
    /// at ~0.75 of the HLG signal, leaving headroom above for speculars.
    public static let hlgReferenceWhiteSignal: Float = 0.75
}

/// Hybrid Log-Gamma transfer (ITU-R BT.2100 / ARIB STD-B67), as pure Swift so
/// color code and tests can reason about the exact curve the compositor's
/// `prism_hlg_oetf` shader applies. Scene value E ∈ [0,1] ↔ HLG signal E' ∈ [0,1].
///
/// Constants: a = 0.17883277, b = 0.28466892, c = 0.55991073. The breakpoint is
/// E = 1/12 (E' = 1/2). `oetf(0)=0` and `oetf(1)=1`, so black and fully
/// saturated primaries pass through unchanged — only mid-tones bend.
public enum HLGTransfer {
    public static let a: Float = 0.17883277
    public static let b: Float = 0.28466892
    public static let c: Float = 0.55991073

    /// Scene-linear (normalized [0,1]) → HLG signal.
    public static func oetf(_ e: Float) -> Float {
        let e = max(e, 0)
        if e <= 1.0 / 12.0 { return (3 * e).squareRoot() }
        return a * log(12 * e - b) + c
    }

    /// HLG signal → scene-linear (normalized [0,1]). Inverse of `oetf`.
    public static func inverseOetf(_ ePrime: Float) -> Float {
        let e = max(ePrime, 0)
        if e <= 0.5 { return (e * e) / 3 }
        return (exp((e - c) / a) + b) / 12
    }

    /// Per-channel `oetf`.
    public static func oetf(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(oetf(rgb.x), oetf(rgb.y), oetf(rgb.z))
    }
}
