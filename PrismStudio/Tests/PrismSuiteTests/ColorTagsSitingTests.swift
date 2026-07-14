import CoreVideo
import XCTest

import PrismCore

/// sol #3 finding 3 — `YCbCrTags.isLeftSited` recognized only
/// `kCVImageBufferChromaLocation_Left`, missing the horizontal-left component of
/// the other legal co-sited-horizontal tags `TopLeft`, `BottomLeft` and `DV420`
/// (all left-sited horizontally). A source tagged with any of those was decoded
/// as centered → a half-pixel chroma shift / colored fringing on edges.
///
/// Vertical siting stays centered/documented on every path; only the horizontal
/// component these tags additionally carry is corrected.
final class ColorTagsSitingTests: XCTestCase {

    private func makeBuffer(w: Int, h: Int, siting: CFString?) throws -> CVPixelBuffer {
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        var pb: CVPixelBuffer?
        let st = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                     kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                     attrs as CFDictionary, &pb)
        guard st == kCVReturnSuccess, let buffer = pb else { throw XCTSkip("no biplanar buffer (\(st))") }
        if let siting {
            CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, siting, .shouldPropagate)
        }
        return buffer
    }

    func testLeftFamilyAllRecognizedAsHorizontallyLeft() throws {
        let w = 64, h = 64
        let leftFamily: [CFString] = [
            kCVImageBufferChromaLocation_Left,
            kCVImageBufferChromaLocation_TopLeft,
            kCVImageBufferChromaLocation_BottomLeft,
            kCVImageBufferChromaLocation_DV420,
        ]
        for siting in leftFamily {
            let buf = try makeBuffer(w: w, h: h, siting: siting)
            XCTAssertTrue(YCbCrTags.isLeftSited(for: buf), "\(siting) not recognized as horizontally-left")
            XCTAssertEqual(YCbCrTags.chromaOffsetX(for: buf, lumaWidth: w), 0.5 / Float(w), accuracy: 1e-7,
                           "\(siting) did not get the left horizontal chroma offset")
        }
    }

    func testCenteredAndAbsentStayCentered() throws {
        let w = 64, h = 64
        let center = try makeBuffer(w: w, h: h, siting: kCVImageBufferChromaLocation_Center)
        XCTAssertFalse(YCbCrTags.isLeftSited(for: center), "Center must stay centered")
        XCTAssertEqual(YCbCrTags.chromaOffsetX(for: center, lumaWidth: w), 0)

        let absent = try makeBuffer(w: w, h: h, siting: nil)
        XCTAssertFalse(YCbCrTags.isLeftSited(for: absent), "absent siting must default to centered")
        XCTAssertEqual(YCbCrTags.chromaOffsetX(for: absent, lumaWidth: w), 0)
    }
}
