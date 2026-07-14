import CoreGraphics
import CoreVideo
import XCTest

import PrismCore

/// sol #5 watch-item — `YCbCrTags.transferCode` / `primariesCode` / `isRec2020`
/// read the DISCRETE colorimetry attachments (`CVImageBufferTransferFunction` etc.)
/// and defaulted to Rec.709 when they were absent. But a buffer can advertise its
/// colorspace by NAME alone — an attached CGColorSpace (`kCVImageBufferCGColorSpaceKey`,
/// e.g. a ScreenCaptureKit `l10r` HDR buffer whose `colorSpaceName = itur_2100_HLG`)
/// with NO discrete transfer attachment. That true HLG buffer then mis-classified as
/// Rec.709 → decoded with the wrong (709) EOTF.
///
/// FIX: when the discrete attachment is absent, derive the transfer / primaries from
/// the attached CGColorSpace NAME before defaulting to 709.
final class ColorTagsNameFallbackTests: XCTestCase {

    /// A buffer carrying ONLY a named CGColorSpace attachment (no discrete
    /// transfer / primaries / matrix attachments).
    private func makeNameOnly(_ csName: CFString) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pb else { throw XCTSkip("no buffer") }
        guard let cs = CGColorSpace(name: csName) else { throw XCTSkip("colorspace \(csName) unavailable") }
        CVBufferSetAttachment(pb, kCVImageBufferCGColorSpaceKey, cs, .shouldPropagate)
        // Deliberately do NOT set kCVImageBufferTransferFunctionKey / ColorPrimaries /
        // YCbCrMatrix — the name is the only signal.
        return pb
    }

    func testHLGNameOnlyClassifiesAsHLGNot709() throws {
        let buf = try makeNameOnly(CGColorSpace.itur_2100_HLG)
        // Precondition: there really is no discrete transfer attachment.
        XCTAssertNil(CVBufferCopyAttachment(buf, kCVImageBufferTransferFunctionKey, nil),
                     "test buffer unexpectedly carries a discrete transfer attachment")
        XCTAssertEqual(YCbCrTags.transferCode(for: buf), 1, "name-only itur_2100_HLG did not classify as HLG (fell back to 709)")
        XCTAssertTrue(YCbCrTags.isRec2020(for: buf), "name-only HLG buffer not seen as Rec.2020")
        XCTAssertEqual(YCbCrTags.primariesRotationCode(for: buf), 0, "name-only 2020 buffer would be re-rotated 709→2020")
    }

    func testPQNameOnlyClassifiesAsPQ() throws {
        let buf = try makeNameOnly(CGColorSpace.itur_2100_PQ)
        XCTAssertEqual(YCbCrTags.transferCode(for: buf), 2, "name-only itur_2100_PQ did not classify as PQ")
        XCTAssertTrue(YCbCrTags.isRec2020(for: buf), "name-only PQ/2020 buffer not seen as Rec.2020")
    }

    func testDiscreteAttachmentStillWinsAndUntaggedStays709() throws {
        // A discrete HLG attachment (no CGColorSpace name) still classifies HLG.
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &pb)
        let buf = pb!
        CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        XCTAssertEqual(YCbCrTags.transferCode(for: buf), 1)

        // A fully untagged buffer (no attachment, no name) still defaults to 709/0.
        var pb2: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &pb2)
        XCTAssertEqual(YCbCrTags.transferCode(for: pb2!), 0, "untagged buffer must stay Rec.709 (0)")
        XCTAssertFalse(YCbCrTags.isRec2020(for: pb2!), "untagged buffer must not read Rec.2020")
    }
}
