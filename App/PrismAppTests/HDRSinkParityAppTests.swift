import CoreVideo
import QuartzCore
import Metal
import XCTest

import PrismCompositor
@testable import Prism

/// Stage O — HDR sink parity, App side: the **preview** EDR configuration and the
/// **vertical program** rebuilding into HDR on an HDR toggle.
///
/// CONFIGURATION-verified (the CAMetalLayer's EDR flags / colorspace / metadata,
/// and the vertical compositor's color mode). Whether the preview shows real HDR
/// headroom on an EDR display is UNVERIFIED-until-hardware.
@MainActor
final class HDRSinkParityAppTests: XCTestCase {

    // MARK: - Preview EDR

    func testPreviewLayerEnablesEDRForHDRFrame() {
        let layer = CAMetalLayer()
        let hdr = PreviewEDR.configure(layer, for: kCVPixelFormatType_ARGB2101010LEPacked)
        XCTAssertTrue(hdr)
        XCTAssertTrue(layer.wantsExtendedDynamicRangeContent,
                      "an HDR (10-bit) program frame must enable EDR on the preview layer")
        XCTAssertEqual(layer.pixelFormat, .bgr10a2Unorm, "HDR preview drawable must be 10-bit")
        XCTAssertNotNil(layer.edrMetadata, "HDR preview must carry CAEDRMetadata (HLG)")
        XCTAssertEqual(layer.colorspace?.name, CGColorSpace.itur_2100_HLG,
                       "HDR preview colorspace must be Rec.2020 / BT.2100 HLG")
    }

    func testPreviewLayerClearsEDRForSDRFrame() {
        let layer = CAMetalLayer()
        // First put it in HDR, then feed an SDR frame — the EDR flags must clear.
        PreviewEDR.configure(layer, for: kCVPixelFormatType_ARGB2101010LEPacked)
        let hdr = PreviewEDR.configure(layer, for: kCVPixelFormatType_32BGRA)
        XCTAssertFalse(hdr)
        XCTAssertFalse(layer.wantsExtendedDynamicRangeContent, "SDR frame must NOT request EDR")
        XCTAssertEqual(layer.pixelFormat, .bgra8Unorm, "SDR preview drawable stays 8-bit BGRA")
        XCTAssertNil(layer.edrMetadata, "SDR must carry no EDR metadata")
    }

    func testPreviewHDRDetectionIsOffPixelFormat() {
        XCTAssertTrue(PreviewEDR.isHDR(kCVPixelFormatType_ARGB2101010LEPacked))
        XCTAssertFalse(PreviewEDR.isHDR(kCVPixelFormatType_32BGRA))
        XCTAssertFalse(PreviewEDR.isHDR(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
    }

    // MARK: - Vertical program follows the HDR toggle

    func testVerticalProgramRebuildsIntoHDROnToggle() throws {
        let engine = AppEngine()
        guard engine.verticalProgramColorMode != nil else {
            // No Metal device on this host → no vertical program to rebuild.
            throw XCTSkip("no vertical program (Metal unavailable)")
        }
        XCTAssertEqual(engine.verticalProgramColorMode, .sdr, "vertical program starts SDR")
        engine.setHDREnabled(true)
        // If HDR actually took (Metal available, off-air), the vertical program
        // must have rebuilt into HDR — the previously-SDR-forever bug.
        if engine.hdrEnabled {
            XCTAssertEqual(engine.verticalProgramColorMode, .hdr,
                           "vertical program must reach HDR parity with the primary")
            engine.setHDREnabled(false)
            XCTAssertEqual(engine.verticalProgramColorMode, .sdr,
                           "vertical program returns to SDR when HDR is disabled")
        }
    }
}
