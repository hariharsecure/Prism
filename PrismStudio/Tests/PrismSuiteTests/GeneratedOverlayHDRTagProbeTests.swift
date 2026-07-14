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
/// Motivation: those overlay sources render sRGB content into an **untagged**
/// BGRA `FXCanvas` buffer (`FXCanvas.render` mints a pooled buffer and attaches
/// no colorimetry; `TimedVideoSource.emit` / the app overlay sources emit it as
/// a plain `VideoFrame` with no `stampSRGB`). An untagged buffer in the HDR
/// compositor is decoded as **Rec.709** (`YCbCrTags.transferCode == 0`,
/// `primariesRotationCode == 1`): correct 709/sRGB PRIMARIES (709→2020 rotation),
/// but the **Rec.709 EOTF instead of the sRGB EOTF**.
///
/// This probe renders the real `FXCanvas` raster backend (the ground-truth
/// surface shared by every generated overlay) through the real `MetalCompositor`
/// in `.hdr` mode, reads back the 10-bit program, and compares against three
/// independent from-spec oracles:
///   • CORRECT   = sRGB EOTF → (709→2020 linear) → HLG OETF   (what a stamped
///                 sRGB overlay would give),
///   • MEASURED-EXPECTED (current, untagged) = 709 EOTF → … → HLG,
///   • WORST-CASE (badly wrong) = if the overlay were stamped the program's HLG
///     transfer, the sRGB value would be HLG-inverse-decoded (grossly dark).
///
/// Finding (see KNOWN_LIMITATIONS.md "Generated overlays untagged in HDR"): the
/// measured value tracks the 709-EOTF oracle, NOT the HLG worst case. On the
/// neutral axis the residual sRGB-vs-709 transfer error is small (~39/1023 ≈
/// 3.8% of range at mid-gray) and ZERO at black / white / a saturated primary.
/// Primaries are correct. This is a documented MEDIUM edge, not a HIGH.
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

    /// Prove the untagged FXCanvas overlay buffer really carries NO colorimetry —
    /// so the compositor's untagged→Rec.709 default is what actually runs.
    func testGeneratedOverlayBufferIsUntagged() throws {
        let canvas = try FXCanvas(width: W, height: H)
        let buf = try canvas.solid(RGBA(r: 0.50196, g: 0.50196, b: 0.50196))
        XCTAssertNil(CVBufferCopyAttachment(buf, kCVImageBufferColorPrimariesKey, nil),
                     "FXCanvas overlay buffer unexpectedly carries ColorPrimaries")
        XCTAssertNil(CVBufferCopyAttachment(buf, kCVImageBufferTransferFunctionKey, nil),
                     "FXCanvas overlay buffer unexpectedly carries TransferFunction")
        XCTAssertNil(CVBufferCopyAttachment(buf, kCVImageBufferCGColorSpaceKey, nil),
                     "FXCanvas overlay buffer unexpectedly carries a CGColorSpace name")
    }

    /// Render a generated sRGB overlay (mid-gray + saturated red) through the real
    /// HDR compositor and classify the color error against from-spec oracles.
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
        let correctGray  = Int((hlgOETF(srgbEOTF(v)) * 1023).rounded())          // stamped-sRGB oracle
        let untaggedGray = Int((hlgOETF(eotf709(v)) * 1023).rounded())           // current untagged→709 path
        let hlgMisdecode = Int((hlgOETF(hlgInverseOETF(v)) * 1023).rounded())    // worst case if stamped HLG
        let measuredGray = g.g                                                   // neutral: channels equal

        let errVsCorrect = abs(measuredGray - correctGray)
        let errVsWorst   = abs(measuredGray - hlgMisdecode)
        print("[overlay-HDR probe] gray128 measured=\(measuredGray) | correct-sRGB≈\(correctGray) untagged-709≈\(untaggedGray) HLG-misdecode≈\(hlgMisdecode) | err vs correct=\(errVsCorrect)/1023 (\(String(format: "%.1f", Double(errVsCorrect) / 1023 * 100))%)")

        // 1. The compositor decodes the untagged overlay as Rec.709 (NOT sRGB, NOT HLG).
        XCTAssertEqual(measuredGray, untaggedGray, accuracy: 12,
                       "untagged overlay should decode via the Rec.709 EOTF path")
        // 2. It is NOT the badly-wrong HLG-misdecode (that would be grossly dark ≈513).
        XCTAssertGreaterThan(errVsWorst, 150,
                             "measured gray is near the HLG-misdecode value — that WOULD be a HIGH")
        // 3. The residual sRGB-vs-709 error is a small, bounded transfer diff → MEDIUM.
        XCTAssertLessThan(errVsCorrect, 60,
                          "sRGB-vs-709 gray error unexpectedly large — re-classify")
        XCTAssertGreaterThan(errVsCorrect, 20,
                             "gray error vanished — overlay may now be stamped sRGB; update the ledger")

        // ---- Saturated sRGB RED (255,0,0): sRGB & 709 EOTF agree at 0 and 1 → ZERO transfer error ----
        let redBuf = try canvas.solid(RGBA(r: 1, g: 0, b: 0))
        let redID = SourceID("probe.overlay.red")
        let redProgram = try compositor.composite(
            frames: [redID: VideoFrame(pixelBuffer: redBuf, pts: t0, source: redID)],
            scene: Scene(name: "r", layers: [Layer(sourceID: redID)]),
            pts: CMTimeAdd(t0, CMTime(value: 1, timescale: 60)))
        let r = read10(redProgram, x: cx, y: cy)

        // Oracle: EOTF(1)=1 for BOTH sRGB and 709, so correct == untagged for a pure primary.
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
