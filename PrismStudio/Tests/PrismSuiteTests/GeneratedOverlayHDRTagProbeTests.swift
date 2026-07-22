import CoreMedia
import CoreVideo
import Metal
import XCTest

import PrismCompositor
import PrismCore

/// GPU probe: how a GENERATED sRGB OVERLAY frame (AnimatedLogo / Ticker /
/// CreditsRoll / MotionGraphics / CaptionRenderer — every `FXCanvas`-backed
/// overlay source) composites into an HDR (HLG / Rec.2020) program.
///
/// Phase 2e FIX (was a documented MEDIUM edge): those overlay sources render sRGB
/// content into an `FXCanvas` BGRA buffer that used to be emitted **untagged**.
/// An untagged buffer in the HDR compositor is decoded as **Rec.709**
/// (`YCbCrTags.transferCode == 0`): correct 709/sRGB PRIMARIES (709→2020 rotation),
/// but the **Rec.709 EOTF instead of the sRGB EOTF** — a ~3.8% mid-tone transfer
/// error (a generated gray 128 → ≈765/1023 instead of the correct ≈726).
///
/// `FXCanvas.render` / `renderRaw` now call `YCbCrTags.stampSRGB(buffer)` (matching
/// `SourceRenderCanvas` and `BackgroundEffect.replace`), so the overlay carries its
/// OWN sRGB/709 colorimetry and the compositor decodes it with the **sRGB EOTF**.
///
/// This probe renders the real `FXCanvas` raster backend (the ground-truth surface
/// shared by every generated overlay) through the real `MetalCompositor` in `.hdr`
/// mode, reads back the 10-bit program, and compares against three independent
/// from-spec oracles:
///   • CORRECT (post-fix, stamped sRGB) = sRGB EOTF → (709→2020 linear) → HLG OETF,
///   • PRE-FIX WRONG (untagged → 709 EOTF) = 709 EOTF → … → HLG (≈765 at mid-gray,
///     ~39/1023 above the correct value — the bug this fix removes),
///   • WORST-CASE = if the overlay were stamped the program's HLG transfer, the sRGB
///     value would be HLG-inverse-decoded (grossly dark ≈513).
///
/// Finding: after the fix the measured mid-gray tracks the sRGB-EOTF oracle (≈726),
/// NOT the pre-fix 709 value (≈765) and NOT the HLG worst case. Primaries were always
/// correct; the fix corrects the transfer. Black / white / a saturated primary are
/// ZERO-error on BOTH transfers, so they stay unchanged (a pure primary is a control).
final class GeneratedOverlayHDRTagProbeTests: XCTestCase {

    private let W = 256, H = 144

    // MARK: - From-spec transfer oracles (independent of the shader)

    private func srgbEOTF(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    private func eotf709(_ v: Double) -> Double {
        v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1.0 / 0.45)
    }
    private func hlgOETF(_ e: Double) -> Double {
        let e = max(e, 0)
        if e <= 1.0 / 12.0 { return (3 * e).squareRoot() }
        return 0.17883277 * log(12 * e - 0.28466892) + 0.55991073
    }
    private func hlgInverseOETF(_ v: Double) -> Double {
        let a = 0.17883277, b = 0.28466892, c = 0.55991073
        if v <= 0.5 { return v * v / 3.0 }
        return (exp((v - c) / a) + b) / 12.0
    }
    /// 709→2020 linear primary rotation (matches `prism_to_scene_linear_2020`).
    private func rotate709to2020(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        (0.627404 * r + 0.329283 * g + 0.043313 * b,
         0.069097 * r + 0.919540 * g + 0.011362 * b,
         0.016391 * r + 0.088013 * g + 0.895595 * b)
    }

    // MARK: - Readback (10-bit ARGB2101010LEPacked: B,G,R at bit 0/10/20)

    private func read10(_ frame: VideoFrame, x: Int, y: Int) -> (b: Int, g: Int, r: Int) {
        let buffer = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let word = base.advanced(by: y * bpr + x * 4).loadUnaligned(as: UInt32.self)
        return (Int(word & 0x3FF), Int((word >> 10) & 0x3FF), Int((word >> 20) & 0x3FF))
    }

    private func attachmentEquals(_ buf: CVPixelBuffer, _ key: CFString, _ expected: CFString) -> Bool {
        guard let raw = CVBufferCopyAttachment(buf, key, nil) else { return false }
        return CFEqual(raw as AnyObject, expected)
    }

    /// Phase 2e: prove the generated FXCanvas overlay buffer now carries the sRGB/709
    /// colorimetry `stampSRGB` writes — so the compositor decodes it with the sRGB EOTF
    /// (correct), not the untagged→Rec.709 default (the pre-fix bug).
    func testGeneratedOverlayBufferIsStampedSRGB() throws {
        let canvas = try FXCanvas(width: W, height: H)
        let buf = try canvas.solid(RGBA(r: 0.50196, g: 0.50196, b: 0.50196))
        XCTAssertTrue(attachmentEquals(buf, kCVImageBufferColorPrimariesKey,
                                       kCVImageBufferColorPrimaries_ITU_R_709_2),
                      "FXCanvas overlay buffer must be stamped Rec.709 primaries")
        XCTAssertTrue(attachmentEquals(buf, kCVImageBufferTransferFunctionKey,
                                       kCVImageBufferTransferFunction_sRGB),
                      "FXCanvas overlay buffer must be stamped the sRGB transfer (not left untagged → Rec.709 EOTF)")
        XCTAssertTrue(attachmentEquals(buf, kCVImageBufferYCbCrMatrixKey,
                                       kCVImageBufferYCbCrMatrix_ITU_R_709_2),
                      "FXCanvas overlay buffer must be stamped the Rec.709 matrix")
        // The raw-fill effect path (glitch / RGB-split) is stamped too.
        let raw = try canvas.render { ctx in ctx.setFillColor(RGBA(r: 0.5, g: 0.5, b: 0.5).cg); ctx.fill(canvas.rect) }
        XCTAssertTrue(attachmentEquals(raw, kCVImageBufferTransferFunctionKey,
                                       kCVImageBufferTransferFunction_sRGB),
                      "render() output must be stamped sRGB")
    }

    /// Render a generated sRGB overlay (mid-gray + saturated red) through the real
    /// HDR compositor and classify the color against from-spec oracles: the mid-gray
    /// now decodes via the sRGB EOTF (≈726), NOT the pre-fix Rec.709 EOTF (≈765).
    func testGeneratedOverlayCompositedIntoHDRProgram() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let compositor = try MetalCompositor(device: device, width: W, height: H, colorMode: .hdr)
        let canvas = try FXCanvas(width: W, height: H)   // shared generated-overlay raster backend
        let t0 = HouseClock.now()
        let cx = W / 2, cy = H / 2

        // ---- sRGB MID-GRAY 128 (the neutral-axis worst case for a transfer error) ----
        let grayBuf = try canvas.solid(RGBA(r: 0.50196, g: 0.50196, b: 0.50196))
        let grayID = SourceID("probe.overlay.gray")
        let grayProgram = try compositor.composite(
            frames: [grayID: VideoFrame(pixelBuffer: grayBuf, pts: t0, source: grayID)],
            scene: Scene(name: "g", layers: [Layer(sourceID: grayID)]), pts: t0)
        let g = read10(grayProgram, x: cx, y: cy)

        let v = 128.0 / 255.0
        let correctGray  = Int((hlgOETF(srgbEOTF(v)) * 1023).rounded())          // stamped-sRGB oracle ≈726
        let preFixGray   = Int((hlgOETF(eotf709(v)) * 1023).rounded())           // pre-fix untagged→709 ≈765 (the BUG)
        let hlgMisdecode = Int((hlgOETF(hlgInverseOETF(v)) * 1023).rounded())    // worst case if stamped HLG ≈513
        let measuredGray = g.g                                                   // neutral: channels equal

        let errVsCorrect = abs(measuredGray - correctGray)
        let errVsPreFix  = abs(measuredGray - preFixGray)
        let errVsWorst   = abs(measuredGray - hlgMisdecode)
        print("[overlay-HDR probe] gray128 measured=\(measuredGray) | correct-sRGB≈\(correctGray) pre-fix-709≈\(preFixGray) HLG-misdecode≈\(hlgMisdecode) | err vs correct=\(errVsCorrect)/1023 vs pre-fix=\(errVsPreFix)/1023")

        // Discriminator sanity: the sRGB and 709 oracles differ enough to tell apart.
        XCTAssertGreaterThan(abs(correctGray - preFixGray), 25,
                             "sRGB vs 709 mid-gray oracles too close to discriminate (\(correctGray) vs \(preFixGray))")

        // 1. The stamped overlay now decodes via the sRGB EOTF (the FIX).
        XCTAssertEqual(measuredGray, correctGray, accuracy: 12,
                       "stamped overlay should decode via the sRGB EOTF (≈726)")
        // 2. It is NOT the pre-fix untagged→Rec.709 value (≈765) — the bug is gone.
        XCTAssertGreaterThan(errVsPreFix, 20,
                             "measured gray still matches the pre-fix Rec.709-EOTF value \(preFixGray) — stampSRGB did not take effect")
        // 3. It is NOT the badly-wrong HLG-misdecode (that would be grossly dark ≈513).
        XCTAssertGreaterThan(errVsWorst, 150,
                             "measured gray is near the HLG-misdecode value — that WOULD be a HIGH")

        // ---- Saturated sRGB RED (255,0,0): sRGB & 709 EOTF agree at 0 and 1 → ZERO transfer error,
        //      so red is a CONTROL — unchanged by the fix. ----
        let redBuf = try canvas.solid(RGBA(r: 1, g: 0, b: 0))
        let redID = SourceID("probe.overlay.red")
        let redProgram = try compositor.composite(
            frames: [redID: VideoFrame(pixelBuffer: redBuf, pts: t0, source: redID)],
            scene: Scene(name: "r", layers: [Layer(sourceID: redID)]),
            pts: CMTimeAdd(t0, CMTime(value: 1, timescale: 60)))
        let r = read10(redProgram, x: cx, y: cy)

        // Oracle: EOTF(1)=1 for BOTH sRGB and 709, so correct == pre-fix for a pure primary.
        let (lr, lg, lb) = rotate709to2020(1, 0, 0)
        let oracleR = Int((hlgOETF(lr) * 1023).rounded())
        let oracleG = Int((hlgOETF(lg) * 1023).rounded())
        let oracleB = Int((hlgOETF(lb) * 1023).rounded())
        print("[overlay-HDR probe] red(1,0,0) measured B,G,R=\(r.b),\(r.g),\(r.r) | oracle B,G,R=\(oracleB),\(oracleG),\(oracleR)")

        // Red composites correctly: dominant R, in-gamut (not clamped), G/B lifted by
        // the 709→2020 rotation — and matches the oracle within readback tolerance.
        XCTAssertEqual(r.r, oracleR, accuracy: 16, "709→2020 red R channel off-oracle")
        XCTAssertEqual(r.g, oracleG, accuracy: 16, "709→2020 red G cross-term off-oracle")
        XCTAssertEqual(r.b, oracleB, accuracy: 16, "709→2020 red B cross-term off-oracle")
        XCTAssertGreaterThan(r.r, r.g, "red not dominant after 709→2020")
        XCTAssertLessThan(r.r, 1015, "red clamped to full — gamut rotation did not run")
    }
}
