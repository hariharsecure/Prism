import CoreGraphics
import CoreVideo
import Foundation
import simd

/// Reads the standard YCbCr / gamut color tags off a source pixel buffer.
///
/// One source of truth for every YUV decode path in the engine — the primary
/// compositor layer path (`prism_layer_fragment_yuv`), the per-source effect
/// pre-pass (`prism_srcfx_yuv_to_bgra`), and the Vision background/cutout decode
/// — so a BT.601 / BT.2020-tagged or left-sited source converts with the SAME
/// matrix + siting no matter which path touches it (Class A: wrong matrix = hue/
/// saturation shift; wrong siting = half-pixel chroma shift / colored fringing).
public enum YCbCrTags {
    /// Shader matrix code for the source's `CVImageBufferYCbCrMatrix`:
    /// 0 = BT.709 (default / untagged / unrecognized), 1 = BT.601, 2 = BT.2020.
    public static func matrixCode(for buffer: CVPixelBuffer) -> UInt32 {
        guard let raw = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) else { return 0 }
        let matrix = raw as AnyObject
        if CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4) { return 1 }
        if CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020) { return 2 }
        return 0
    }

    /// sol #8 finding #7: the source's EXPLICITLY-present, recognized YCbCr matrix as a
    /// CFString, or `nil` when the matrix attachment is absent. Unlike `matrixCode`
    /// (which folds an explicit Rec.709 matrix and an absent one into the same code 0),
    /// this distinguishes a discretely-tagged Rec.709 matrix from "no tag", so
    /// materialization can PRESERVE an explicit matrix instead of overwriting it from
    /// the classified primaries. A present-but-unrecognized value reads as absent.
    private static func explicitMatrix(for buffer: CVPixelBuffer) -> CFString? {
        guard let raw = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) else { return nil }
        let m = raw as AnyObject
        if CFEqual(m, kCVImageBufferYCbCrMatrix_ITU_R_601_4) { return kCVImageBufferYCbCrMatrix_ITU_R_601_4 }
        if CFEqual(m, kCVImageBufferYCbCrMatrix_ITU_R_2020) { return kCVImageBufferYCbCrMatrix_ITU_R_2020 }
        if CFEqual(m, kCVImageBufferYCbCrMatrix_ITU_R_709_2) { return kCVImageBufferYCbCrMatrix_ITU_R_709_2 }
        return nil
    }

    /// Whether the source declares horizontally-LEFT / co-sited-horizontal chroma
    /// siting (MPEG-2/H.264/HEVC). Absent or `Center`/`Top`/`Bottom` → centered
    /// (MPEG-1/JPEG), the GPU's default normalized-sampling position. Horizontal
    /// component only.
    ///
    /// sol #3 finding 3: `Left`, `TopLeft`, `BottomLeft` and `DV420` are ALL
    /// horizontally left-sited — they differ only in the VERTICAL component
    /// (which stays centered/documented on every path). Recognizing only `Left`
    /// left the other three legal tags decoded as centered → a half-pixel chroma
    /// shift / colored fringing on high-contrast edges.
    public static func isLeftSited(for buffer: CVPixelBuffer) -> Bool {
        guard let raw = CVBufferCopyAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, nil) else { return false }
        let siting = raw as AnyObject
        for left in [kCVImageBufferChromaLocation_Left,
                     kCVImageBufferChromaLocation_TopLeft,
                     kCVImageBufferChromaLocation_BottomLeft,
                     kCVImageBufferChromaLocation_DV420] where CFEqual(siting, left) {
            return true
        }
        return false
    }

    /// The horizontal chroma-sample offset (normalized texture units) a decode
    /// should add so a left-sited source samples half a luma pixel to the right.
    /// `lumaWidth` is the full-resolution frame width. Centered → 0.
    public static func chromaOffsetX(for buffer: CVPixelBuffer, lumaWidth: Int) -> Float {
        isLeftSited(for: buffer) && lumaWidth > 0 ? 0.5 / Float(lumaWidth) : 0
    }

    /// Whether the source already declares Rec.2020 primaries (via
    /// `CVImageBufferColorPrimaries` OR a Rec.2020 YCbCr matrix, which decides the
    /// primaries the decoded R'G'B' land in). Used to avoid double-rotating an
    /// already-2020 source's gamut in the HLG path (N4).
    public static func isRec2020(for buffer: CVPixelBuffer) -> Bool {
        if let prim = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil),
           CFEqual(prim as AnyObject, kCVImageBufferColorPrimaries_ITU_R_2020) {
            return true
        }
        if let mtx = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil),
           CFEqual(mtx as AnyObject, kCVImageBufferYCbCrMatrix_ITU_R_2020) {
            return true
        }
        // Watch-item (sol #5): fall back to the CGColorSpace NAME when neither the
        // primaries nor the matrix attachment is present (a name-only HDR buffer).
        // sol #8 finding #5: any Rec.2020-primaries NAME (the full enumerated set).
        if let name = namedColorSpaceName(for: buffer),
           namedSpaceClassification(name)?.primaries == 1 { return true }
        return false
    }

    /// The source's transfer function, mapped to a shader code:
    /// **0 = Rec.709** (default / untagged / unrecognized), **1 = HLG**
    /// (ITU-R BT.2100 / ARIB STD-B67), **2 = PQ** (SMPTE ST 2084 / BT.2100),
    /// **3 = sRGB** (IEC 61966-2-1), **4 = Linear** (scene-linear — no EOTF).
    ///
    /// sol #3 finding-2 + sol #4 finding 3 — the transfer is no longer binary
    /// ("HLG/PQ or assume 709"). The HDR path decodes EACH layer to linear per its
    /// OWN transfer:
    ///  - **true HLG** is an HLG *signal* → HLG inverse-OETF (709 EOTF corrupts it:
    ///    a true-HLG gray 192/255 emitted ≈916 instead of ≈771).
    ///  - **PQ** → ST 2084 EOTF.
    ///  - **sRGB** uses the sRGB EOTF, a DIFFERENT curve from Rec.709 (a generated
    ///    sRGB gray 128 → ≈726, not the 709-EOTF's ≈765).
    ///  - **Linear** is already scene-linear → SKIP the EOTF (a Rec.2020+Linear
    ///    gray 128 → ≈892, not the mis-classified-709 ≈765).
    ///  - everything else (SDR camera/broadcast, untagged) → Rec.709 EOTF, unchanged.
    ///
    /// The shader's `prism_to_scene_linear_2020` consumes these exact codes.
    public static func transferCode(for buffer: CVPixelBuffer) -> UInt32 {
        if let raw = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) {
            let tf = raw as AnyObject
            if CFEqual(tf, kCVImageBufferTransferFunction_ITU_R_2100_HLG) { return 1 }
            if CFEqual(tf, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) { return 2 }
            if CFEqual(tf, kCVImageBufferTransferFunction_sRGB) { return 3 }
            if CFEqual(tf, kCVImageBufferTransferFunction_Linear) { return 4 }
            return 0
        }
        // Watch-item (sol #5): NO explicit transfer attachment — derive it from the
        // buffer's attached CGColorSpace NAME (e.g. a ScreenCaptureKit `l10r` HDR
        // buffer carrying only `colorSpaceName = itur_2100_HLG`). Without this a true
        // HLG buffer mis-classified as Rec.709 and was decoded with the wrong EOTF.
        // sol #8 finding #5: EVERY legal name is enumerated in the one classification
        // table below (a partial list previously fell through to Rec.709).
        guard let name = namedColorSpaceName(for: buffer) else { return 0 }
        return Self.namedSpaceClassification(name)?.transfer ?? 0
    }

    /// sol #8 finding #6: whether the buffer's coded pixels can carry a LEGAL
    /// extended-range (>1) value in a NONLINEAR transfer — the `extended*` colorspace
    /// family (`extendedSRGB` / `extendedITUR_2020` / `extendedDisplayP3` and their
    /// linear siblings). The HDR compositor must NOT saturate such a highlight to 1.0
    /// BEFORE the transfer decode: a name-only `extendedSRGB` half-float 1.5 was
    /// pre-clamped and emitted 756 instead of the correct 937 (CI-linear 2.537 →
    /// blend → HLG). A plain/bounded name (sRGB / 709 / HLG / PQ / 2020) returns 0, so
    /// true-SDR and in-range values keep their existing saturating decode byte-for-byte.
    /// Derived from the CGColorSpace NAME only (discrete attachments carry no
    /// extended-range signal); absent name → 0.
    public static func extendedRangeCode(for buffer: CVPixelBuffer) -> UInt32 {
        guard let name = namedColorSpaceName(for: buffer) else { return 0 }
        return (Self.namedSpaceClassification(name)?.extended ?? false) ? 1 : 0
    }

    /// sol #8 finding #5: the EXHAUSTIVE legal-CGColorSpace-NAME → (transfer,
    /// primaries, extendedRange) classification table — one source of truth for the
    /// name-only fallback used by `transferCode` / `primariesCode` / `isRec2020` /
    /// `extendedRangeCode`. A buffer that advertises its colorspace by NAME alone (the
    /// real ScreenCaptureKit / AVFoundation case: no discrete transfer/primaries/matrix
    /// attachments) is classified here instead of silently defaulting to Rec.709.
    ///
    /// Every legal CoreGraphics RGB name is enumerated and mapped to the engine's
    /// transfer {0 = Rec.709 · 1 = HLG · 2 = PQ · 3 = sRGB · 4 = Linear} and primaries
    /// {0 = Rec.709 · 1 = Rec.2020 · 2 = Display-P3 · 3 = Generic-RGB (sol wave-10 #4:
    /// the classic Apple "Generic RGB" gamut — R(0.63,0.34) G(0.295,0.605)
    /// B(0.155,0.077) D65 — distinct from Rec.709; used ONLY by `genericRGBLinear`)}.
    /// `extended == true` marks a
    /// NONLINEAR transfer that can carry legal extended-range (>1) values (the
    /// `extended*` family) so the compositor skips its pre-decode clamp (finding #6).
    /// The three range flavours are distinguished: `extended…` = the nonlinear transfer
    /// extended past 1 (transfer unchanged, extended = true), `linear…` = the Linear
    /// transfer in [0,1] (transfer = 4), `extendedLinear…` = the Linear transfer
    /// extended past 1 (transfer = 4, extended = true).
    ///
    /// Note the two deprecated aliases `itur_2020_HLG` / `itur_2020_PQ` now resolve to
    /// the SAME CFString as `itur_2100_HLG` / `itur_2100_PQ` (verified via `.name`), so
    /// the 2100 entries already cover them — no separate (deprecated-symbol) rows.
    private static func namedSpaceClassification(_ name: CFString)
        -> (transfer: UInt32, primaries: UInt32, extended: Bool)? {
        func eq(_ n: CFString) -> Bool { CFEqual(name, n) }
        // ── Rec.709 primaries (code 0) ──────────────────────────────────────────
        if eq(CGColorSpace.itur_709)             { return (0, 0, false) }
        if eq(CGColorSpace.sRGB)                 { return (3, 0, false) }
        if eq(CGColorSpace.extendedSRGB)         { return (3, 0, true)  }
        if eq(CGColorSpace.linearSRGB)           { return (4, 0, false) }
        if eq(CGColorSpace.extendedLinearSRGB)   { return (4, 0, true)  }
        // sol wave-10 #4: `genericRGBLinear` is the LINEAR-transfer classic Apple
        // "Generic RGB" gamut — NOT Rec.709 primaries. Pre-fix it mapped to primaries
        // 0 (Rec.709), so a saturated red composited (935,466,227) [709→2020] instead
        // of the Core-Image-color-managed (942,530,230). Primaries code 3 selects the
        // dedicated Generic-RGB→Rec.2020 rotation. (`linearSRGB` stays code 0 — its
        // gamut IS Rec.709; only genericRGBLinear differs.)
        if eq(CGColorSpace.genericRGBLinear)     { return (4, 3, false) }
        if eq(CGColorSpace.itur_709_HLG)         { return (1, 0, false) }
        if eq(CGColorSpace.itur_709_PQ)          { return (2, 0, false) }
        // ── Rec.2020 primaries (code 1) ─────────────────────────────────────────
        if eq(CGColorSpace.itur_2020)                { return (0, 1, false) }
        if eq(CGColorSpace.extendedITUR_2020)        { return (0, 1, true)  }
        if eq(CGColorSpace.linearITUR_2020)          { return (4, 1, false) }
        if eq(CGColorSpace.extendedLinearITUR_2020)  { return (4, 1, true)  }
        if eq(CGColorSpace.itur_2020_sRGBGamma)      { return (3, 1, false) }
        if eq(CGColorSpace.itur_2100_HLG)            { return (1, 1, false) }
        if eq(CGColorSpace.itur_2100_PQ)             { return (2, 1, false) }
        // ── Display-P3 primaries (code 2) ───────────────────────────────────────
        if eq(CGColorSpace.displayP3)                { return (3, 2, false) }
        if eq(CGColorSpace.extendedDisplayP3)        { return (3, 2, true)  }
        if eq(CGColorSpace.linearDisplayP3)          { return (4, 2, false) }
        if eq(CGColorSpace.extendedLinearDisplayP3)  { return (4, 2, true)  }
        if eq(CGColorSpace.displayP3_HLG)            { return (1, 2, false) }
        if eq(CGColorSpace.displayP3_PQ)             { return (2, 2, false) }
        return nil
    }

    /// The CoreGraphics NAME of a buffer's attached CGColorSpace
    /// (`kCVImageBufferCGColorSpaceKey`), or `nil` if there is no CGColorSpace
    /// attachment. Used ONLY as a fallback when the discrete transfer / primaries
    /// attachments are absent (sol #5 watch-item), so a buffer that advertises its
    /// colorspace by NAME alone is still classified correctly instead of defaulting
    /// to Rec.709.
    private static func namedColorSpaceName(for buffer: CVPixelBuffer) -> CFString? {
        guard let raw = CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, nil) else { return nil }
        let cf = raw as AnyObject
        guard CFGetTypeID(cf) == CGColorSpace.typeID else { return nil }
        return (cf as! CGColorSpace).name   // safe: the type id matched CGColorSpace
    }

    /// The source's colour PRIMARIES, mapped to a code:
    /// **0 = Rec.709 / sRGB / unknown** (all share the BT.709 primary
    /// chromaticities), **1 = Rec.2020**, **2 = Display P3** (SMPTE-RP-431 P3
    /// primaries; `P3_D65` or `DCI_P3`), **3 = Generic-RGB** (sol wave-10 #4: the
    /// classic Apple "Generic RGB" gamut, name-only via `genericRGBLinear`; a
    /// discrete `CVImageBufferColorPrimaries` attachment never carries it).
    ///
    /// sol #4 finding 3 — the gamut is no longer binary ("Rec.2020 or assume 709").
    /// Display P3 is explicitly advertised (ScreenCaptureKit / AVFoundation deliver
    /// P3 buffers), and a P3 source rotated with the 709→2020 matrix mis-maps: a P3
    /// red came out (935,466,227) instead of the P3→2020 (970,379,0).
    public static func primariesCode(for buffer: CVPixelBuffer) -> UInt32 {
        if let raw = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) {
            let p = raw as AnyObject
            if CFEqual(p, kCVImageBufferColorPrimaries_ITU_R_2020) { return 1 }
            if CFEqual(p, kCVImageBufferColorPrimaries_P3_D65) { return 2 }
            if CFEqual(p, kCVImageBufferColorPrimaries_DCI_P3) { return 2 }
            return 0
        }
        // Watch-item (sol #5) + sol #8 finding #5: NO explicit primaries attachment —
        // derive from the CGColorSpace NAME (the full enumerated table: Rec.2020 → 1,
        // Display-P3 → 2, Rec.709 → 0) before defaulting to Rec.709.
        guard let name = namedColorSpaceName(for: buffer) else { return 0 }
        return namedSpaceClassification(name)?.primaries ?? 0
    }

    /// The primary rotation the HDR compositor must apply to reach the Rec.2020
    /// working gamut, as a shader code: **0 = already Rec.2020** (no rotation —
    /// tagged by primaries OR by a Rec.2020 matrix, N4), **1 = rotate 709→2020**
    /// (Rec.709 / sRGB / untagged), **2 = rotate P3→2020** (Display P3), **3 = rotate
    /// Generic-RGB→2020** (sol wave-10 #4: `genericRGBLinear`).
    ///
    /// sol #4 finding 3 — supersedes the binary `isRec2020 ? 0 : 1`, which folded
    /// P3 into the 709 case. Existing behaviour is preserved for 709/untagged (→ 1)
    /// and Rec.2020 (→ 0); P3 → 2; Generic-RGB → 3. The shader's
    /// `prism_to_scene_linear_2020` selects the matching primary matrix.
    public static func primariesRotationCode(for buffer: CVPixelBuffer) -> UInt32 {
        if isRec2020(for: buffer) { return 0 }          // primaries OR matrix == 2020
        let p = primariesCode(for: buffer)
        if p == 2 { return 2 }                           // Display P3
        if p == 3 { return 3 }                           // Generic-RGB (sol wave-10 #4)
        return 1                                         // 709 / sRGB / untagged
    }

    /// sol #3 finding 4: copy the source's colorimetry attachments — color
    /// primaries, YCbCr matrix and transfer function — onto a derived OUTPUT
    /// buffer, so a downstream stage (the compositor's `isRec2020` gamut gate, an
    /// encoder, a recorder) sees the true colorspace of the pixels instead of an
    /// untagged buffer. Without this, an effect/Vision output of a Rec.2020 source
    /// reads as non-2020 and gets rotated 709→2020 a SECOND time (double-rotation).
    ///
    /// The derived buffer is BGRA (the pre-pass already decoded YUV→RGB in the
    /// source's primaries), so `YCbCrMatrix` is carried only as the `isRec2020`
    /// fallback for sources tagged by matrix alone; the RGB is never re-decoded as
    /// YUV. Only present attachments are copied (an untagged source stays untagged).
    public static func propagateColorTags(from source: CVPixelBuffer, to dest: CVPixelBuffer) {
        var missingDiscrete = false
        for key in [kCVImageBufferColorPrimariesKey,
                    kCVImageBufferYCbCrMatrixKey,
                    kCVImageBufferTransferFunctionKey] {
            if let value = CVBufferCopyAttachment(source, key, nil) {
                CVBufferSetAttachment(dest, key, value, .shouldPropagate)
            } else {
                missingDiscrete = true
            }
        }
        // sol #6 finding 3 + sol #7 finding 10: a NAME-carrying source (a
        // `kCVImageBufferCGColorSpaceKey` attachment — the real camera/screen case where
        // the OS delivers a colorspace NAME, not discrete attachments) whose colorimetry
        // is even PARTIALLY name-derived would otherwise emit an incompletely-tagged
        // derived buffer. Two sub-cases the loop above misses:
        //   • fully name-only (no discrete at all): copies nothing → an identity grade
        //     of a name-only HLG source exits transferCode 0 (Rec.709), mis-decoded.
        //   • name + an explicit discrete TRANSFER but NO discrete primaries/matrix
        //     (sol #7 #10): the loop copies only the transfer, so downstream stages that
        //     read discrete PRIMARIES still see none → 709→2020 double-rotation.
        // Whenever ANY of the three discrete fields is absent while a name is present,
        // materialize the FULL discrete set (transfer + primaries + matrix) from the
        // source's CLASSIFIED codes (which fall back to the name), so classification
        // survives even stages that read only discrete attachments. The classified codes
        // prefer a present discrete attachment, so any already-copied field is unchanged.
        // A truly untagged source (no name, no discrete) still stays untagged.
        guard let colorSpace = CVBufferCopyAttachment(source, kCVImageBufferCGColorSpaceKey, nil) else { return }
        CVBufferSetAttachment(dest, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
        if missingDiscrete { materializeDiscreteTags(from: source, to: dest) }
    }

    /// Stamp discrete transfer / primaries / matrix attachments onto `dest`, derived
    /// from `source`'s classified codes (`transferCode`/`primariesCode`/`matrixCode`,
    /// which fall back to the CGColorSpace NAME). Used by `propagateColorTags` to keep
    /// a name-only source's colorimetry alive across a derived stage (sol #6 finding 3).
    private static func materializeDiscreteTags(from source: CVPixelBuffer, to dest: CVPixelBuffer) {
        let transfer: CFString
        switch transferCode(for: source) {
        case 1:  transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG
        case 2:  transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case 3:  transfer = kCVImageBufferTransferFunction_sRGB
        case 4:  transfer = kCVImageBufferTransferFunction_Linear
        default: transfer = kCVImageBufferTransferFunction_ITU_R_709_2
        }
        // sol wave-10 #4: Generic-RGB (primaries code 3, `genericRGBLinear`) has NO
        // discrete `CVImageBufferColorPrimaries` constant — stamping a 709/2020/P3
        // discrete value would SHADOW the (already-copied) CGColorSpace name and
        // re-break the gamut downstream (discrete wins over name in `primariesCode`).
        // So for Generic-RGB, materialize only the transfer and leave the primaries +
        // matrix name-derived. Every other gamut has a faithful discrete primaries.
        let primariesCodeValue = primariesCode(for: source)
        let primaries: CFString?
        switch primariesCodeValue {
        case 1:  primaries = kCVImageBufferColorPrimaries_ITU_R_2020
        case 2:  primaries = kCVImageBufferColorPrimaries_P3_D65
        case 3:  primaries = nil   // Generic-RGB — no discrete constant; name carries it
        default: primaries = kCVImageBufferColorPrimaries_ITU_R_709_2
        }
        // sol #8 finding #7: an EXPLICITLY-present matrix wins — "present discrete
        // fields win". The public `matrixCode` conflates an explicit Rec.709 matrix
        // with absent/default (both code 0), so an HLG-name source that ALSO carries an
        // explicit Rec.709 matrix would be re-materialized to Rec.2020 (from the name's
        // primaries), overwriting the caller's explicit choice. Distinguish present
        // (any recognized matrix incl. explicit 709) from genuinely absent: preserve a
        // present one, and only materialize from the primaries when the source has NO
        // matrix attachment (a Rec.2020-primaries name then implies the Rec.2020 matrix).
        let matrix: CFString?
        if let explicit = explicitMatrix(for: source) {
            matrix = explicit                                    // present discrete matrix wins
        } else if let primaries {
            matrix = CFEqual(primaries, kCVImageBufferColorPrimaries_ITU_R_2020)
                ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2
        } else {
            matrix = nil   // Generic-RGB, no explicit matrix — leave name-derived
        }
        CVBufferSetAttachment(dest, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        if let primaries {
            CVBufferSetAttachment(dest, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        }
        if let matrix {
            CVBufferSetAttachment(dest, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        }
    }

    /// Stage N (10-bit ingest): stamp **scene-linear Rec.2020** colorimetry
    /// (Rec.2020 primaries, Linear transfer, Rec.2020 matrix) onto a buffer whose
    /// pixels are genuinely linear-light Rec.2020 half-float — a decoded 10-bit HDR
    /// source (MovieSource) rendered into a `64RGBAHalf` canvas via a colour-managed
    /// pass whose OUTPUT colour space is `extendedLinearITUR_2020`.
    ///
    /// Linear transfer (`transferCode` == 4) tells the HDR compositor to SKIP the
    /// EOTF (the values are already scene-linear), and Rec.2020 primaries mean
    /// `primariesRotationCode` == 0 (no re-rotation) — so the half-float layer folds
    /// straight into the compositor's Rec.2020 LINEAR working target and is HLG-OETF
    /// encoded ONCE at output. Tagging it (vs leaving it untagged, which the
    /// compositor would decode with the Rec.709 EOTF as if gamma-coded) is what makes
    /// a true 10-bit HDR movie composite correctly instead of being crushed.
    public static func stampLinearRec2020(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_Linear, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    }

    /// sol #5 finding 1: stamp **HLG Rec.2020** colorimetry (Rec.2020 primaries,
    /// ITU-R BT.2100 HLG transfer, Rec.2020 matrix) onto a buffer whose pixels are
    /// a genuine **HLG signal** in Rec.2020 primaries — a decoded HDR movie
    /// (`MovieSource`) fitted into a `64RGBAHalf` canvas by a colour-managed pass
    /// whose OUTPUT colour space is `itur_2100_HLG`.
    ///
    /// Why HLG-signal-tagged, NOT the earlier scene-linear tag: Core Image's
    /// `extendedLinearITUR_2020` normalization is DISPLAY-linear (it folds in the
    /// HLG OOTF / reference-white scaling), so an HLG signal 0.5 landed at ≈0.25
    /// where the compositor's scene-linear contract needs the pure HLG inverse-OETF
    /// value ≈0.0833 — the compositor then over-brightened / clipped it (HLG 0.5
    /// composited to ≈766 and a bright HLG crushed to 1023, vs the native-x420
    /// values ≈523 / ≈822). Keeping the pixels in the HLG SIGNAL domain and letting
    /// the compositor apply its OWN validated BT.2100 HLG inverse-OETF (transferCode
    /// == 1, no OOTF) makes a fitted HDR movie composite to the SAME value as the
    /// direct native x420 path. Rec.2020 primaries mean `primariesRotationCode` == 0
    /// (no re-rotation) — the CI pass already delivered Rec.2020 primaries.
    public static func stampHLGRec2020(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    }

    /// sol #6 finding 1: stamp **PQ Rec.2020** colorimetry (Rec.2020 primaries,
    /// SMPTE ST 2084 / BT.2100 PQ transfer, Rec.2020 matrix) onto a buffer whose
    /// pixels are a genuine **PQ signal** in Rec.2020 primaries — a decoded PQ movie
    /// (`MovieSource`) fitted into a `64RGBAHalf` canvas by a colour-managed pass
    /// whose OUTPUT colour space is `itur_2100_PQ`.
    ///
    /// A PQ movie must NOT be forced through the HLG-tagged canvas (`stampHLGRec2020`):
    /// Core Image would then PQ→HLG tone-map it (a PQ Y10 512 emitted ≈650 vs the
    /// native-PQ compositor's ≈565). Keeping the pixels a PQ SIGNAL and tagging them PQ
    /// lets the compositor apply its OWN validated ST 2084 EOTF (transferCode 2, ×10
    /// nominal-nit normalization) so a fitted PQ movie composites to the SAME value as
    /// a native PQ x420 source. Rec.2020 primaries → `primariesRotationCode` == 0 (no
    /// re-rotate). HLG movies stay on `stampHLGRec2020` (unchanged).
    public static func stampPQRec2020(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    }

    /// sol #5 finding 4: re-express a **generated / UI colour that is authored in
    /// sRGB** (a strobe flash colour, a beat-pulse background, a background-replace
    /// colour) into the CODED colorspace of `buffer` (its primaries + transfer), so
    /// it can be mixed with the source's own coded pixels HOMOGENEOUSLY and the
    /// resulting buffer honestly carries the SOURCE's tags.
    ///
    /// The pre-fix effects mixed the raw sRGB colour straight into an HLG/PQ + wide-
    /// gamut source frame and then propagated the SOURCE's tags — so e.g. a full-red
    /// strobe on an HLG/Rec.2020 source emitted an sRGB red (1,0,0) FALSELY tagged
    /// Rec.2020/HLG, which the compositor read as a pure Rec.2020-HLG red (1023,0,0)
    /// instead of the correctly-converted sRGB red ≈(935,466,227) in the 2020/HLG
    /// container. Converting the colour here first makes the whole mixed buffer one
    /// colorspace and the propagated tag truthful.
    ///
    /// Steps: sRGB EOTF → linear; rotate sRGB(709) primaries → the source's primaries
    /// (709→2020 or 709→P3, identity for a 709 source); encode with the source's
    /// transfer (HLG / PQ / sRGB / 709 OETF, or identity for Linear). A **plain SDR
    /// source** (Rec.709/sRGB transfer + Rec.709 primaries) returns the colour
    /// UNCHANGED — the UI colour is already in that space, so SDR is byte-identical.
    public static func srgbColor(_ rgb: SIMD3<Float>, inSpaceOf buffer: CVPixelBuffer) -> SIMD3<Float> {
        let transfer = transferCode(for: buffer)
        let rotate = primariesRotationCode(for: buffer)
        // Only a genuine **sRGB** source (sRGB transfer + Rec.709 primaries) is a true
        // identity — the UI colour is already in that exact coded space, so it stays
        // byte-identical. sol #6 finding 2: a **Rec.709** source is NOT identity — sRGB
        // and Rec.709 are DIFFERENT transfer curves, so the colour must be sRGB→709
        // re-encoded (sRGB EOTF → 709 OETF), e.g. gray 0.5 → 0.45019, not 0.5. (Pre-fix
        // the `transfer == 0` short-circuit returned it unchanged, mixing an sRGB value
        // into a 709-coded frame.)
        if transfer == 3 && rotate == 1 { return rgb }

        func srgbEOTF(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        var lin = SIMD3<Double>(srgbEOTF(Double(rgb.x)), srgbEOTF(Double(rgb.y)), srgbEOTF(Double(rgb.z)))

        // Rotate sRGB/Rec.709 primaries → the SOURCE's primaries (rows sum to 1, so
        // the neutral axis is preserved). rotate: 0 source-is-2020 (709→2020),
        // 2 source-is-P3 (709→P3), 1 source-is-709 (identity).
        if rotate == 0 {           // → Rec.2020 (matches the compositor's 709→2020)
            lin = SIMD3(0.627404 * lin.x + 0.329283 * lin.y + 0.043313 * lin.z,
                        0.069097 * lin.x + 0.919540 * lin.y + 0.011362 * lin.z,
                        0.016391 * lin.x + 0.088013 * lin.y + 0.895595 * lin.z)
        } else if rotate == 2 {    // → Display P3 (D65, sRGB→P3)
            lin = SIMD3(0.822462 * lin.x + 0.177538 * lin.y,
                        0.033194 * lin.x + 0.966806 * lin.y,
                        0.017083 * lin.x + 0.072397 * lin.y + 0.910520 * lin.z)
        }

        func encode(_ v: Double) -> Double {
            switch transfer {
            case 1:  // HLG OETF (BT.2100 / ARIB STD-B67)
                let a = 0.17883277, b = 0.28466892, c = 0.55991073, e = max(v, 0)
                return e <= 1.0 / 12.0 ? (3 * e).squareRoot() : a * log(max(12 * e - b, 1e-6)) + c
            case 2:  // PQ OETF (SMPTE ST 2084 inverse EOTF).
                // sol #6 finding 2: the compositor's PQ decode NORMALIZES ST 2084 to a
                // nominal 1000-nit HLG peak (`prism_pq_eotf_norm` = PQ EOTF × 10). So a
                // scene-linear working value `v` (1.0 == the ~1000-nit peak) is a
                // fraction `v/10` of PQ's 10000-nit range: encode `v/10`, and the
                // compositor's ×10 restores `v`. Pre-fix this encoded the raw `v` (as if
                // 1.0 == 10000 nits) → the ×10 pushed a mid sRGB gray to ≈2140 nits →
                // HLG-clipped to 1023. With /10 the round-trip lands at the correct ~726.
                let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
                let lp = pow(max(v / 10.0, 0), m1)
                return pow((c1 + c2 * lp) / (1.0 + c3 * lp), m2)
            case 3:  // sRGB OETF
                return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(max(v, 0), 1.0 / 2.4) - 0.055
            case 4:  // Linear (scene-linear source) — stay linear
                return v
            default: // Rec.709 OETF
                return v < 0.018 ? 4.5 * v : 1.099 * pow(max(v, 0), 0.45) - 0.099
            }
        }
        func clamp(_ v: Double) -> Float { Float(min(max(v, 0), 1)) }
        return SIMD3(clamp(encode(lin.x)), clamp(encode(lin.y)), clamp(encode(lin.z)))
    }

    /// sol #4 finding 2/3: stamp the standard **sRGB / Rec.709** colorimetry
    /// (Rec.709 primaries, sRGB transfer, Rec.709 matrix) onto a buffer whose
    /// pixels are genuinely sRGB — *generated / UI / replacement* content
    /// (`BackgroundEffect.replace`, `SourceRenderCanvas` text/image/browser draws).
    ///
    /// Such content must carry its OWN colorspace, NOT inherit a video source's
    /// Rec.2020/HLG tags (finding 2, the reverse error — that makes the HDR
    /// compositor read an sRGB red as ALREADY Rec.2020 → pure Rec.2020 red instead
    /// of the converted red), and NOT be left untagged (finding 3 — the compositor
    /// would then decode it with the Rec.709 EOTF instead of the correct sRGB EOTF,
    /// e.g. a generated gray 128 → ≈765 instead of ≈726). Rec.709 primaries mean
    /// the compositor correctly rotates 709→2020 in the HDR path.
    public static func stampSRGB(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }
}
