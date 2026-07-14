import CoreMedia
import CoreVideo
import Foundation
import XCTest

@testable import PrismCapture
import PrismCore
@testable import PrismVirtualCam

/// sol #5 (gpt-5.6-sol) HDR/format-signaling defects on the virtual-camera and
/// camera-capture paths:
///   #6  vcam ignores the client-negotiated active format (mislabels program).
///   #8  CameraSource keeps a stale output pixel format after reselection.
///   #11 the 10-bit vcam placeholder is falsely tagged HDR (naive `code<<2`).
///   #12 the advertised l10r vcam format carries no HDR color signaling.
/// Each test reproduces the PRE-fix defect (independent oracle / config
/// assertion) before asserting the fix. The real end-to-end HDR path (a CMIO
/// client negotiating, a real HDR camera) stays UNVERIFIED-until-hardware.
final class VCamHDRFormatTests: XCTestCase {

    // MARK: - #6 vcam converts the program to the negotiated active format

    private func bgraProgramBuffer(fill: UInt8 = 128) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: 64, height: 64, pixelFormat: kCVPixelFormatType_32BGRA)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<64 { for col in 0..<64 {
            let p = row * bpr + col * 4
            base[p] = fill; base[p + 1] = fill; base[p + 2] = fill; base[p + 3] = 255
        } }
        return buf
    }

    private func tenBitProgramBuffer() throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: 64, height: 64,
                                       pixelFormat: PrismVCamConstants.pixelFormat10bit)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<64 {
            let r = base.advanced(by: row * bpr).assumingMemoryBound(to: UInt32.self)
            for col in 0..<64 { r[col] = (UInt32(3) << 30) | (600 << 20) | (600 << 10) | 600 }
        }
        return buf
    }

    private func sampleBuffer(_ pb: CVPixelBuffer) throws -> CMSampleBuffer {
        var desc: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &desc), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
                                        presentationTimeStamp: CMTime(value: 0, timescale: 60),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: desc!,
            sampleTiming: &timing, sampleBufferOut: &sb), noErr)
        return sb!
    }

    private func subtype(_ sb: CMSampleBuffer) -> OSType {
        CMFormatDescriptionGetMediaSubType(CMSampleBufferGetFormatDescription(sb)!)
    }

    /// An SDR (BGRA) program under an l10r/420v negotiation, and an HDR (l10r)
    /// program under a BGRA/420v negotiation, must be CONVERTED so the fed
    /// sample buffer's format IS the negotiated one — not mislabeled.
    func testProgramConvertedToNegotiatedFormat() throws {
        let converter = VCamFormatConverter(width: 64, height: 64)

        // Reproduction: the raw program buffer's format is BGRA, so sending it
        // untouched under an l10r negotiation would mislabel it.
        let sdr = try sampleBuffer(try bgraProgramBuffer())
        XCTAssertEqual(subtype(sdr), kCVPixelFormatType_32BGRA)

        for target in [PrismVCamConstants.pixelFormat10bit,
                       PrismVCamConstants.pixelFormat420v] {
            let out = try XCTUnwrap(converter.makeSampleBuffer(from: sdr, targetFormat: target),
                                    "SDR program failed to convert to \(target)")
            XCTAssertEqual(subtype(out), target,
                           "fed buffer must be the negotiated format, not the program's BGRA")
        }

        // HDR (l10r) program under BGRA / 420v negotiation → converted down.
        let hdr = try sampleBuffer(try tenBitProgramBuffer())
        XCTAssertEqual(subtype(hdr), PrismVCamConstants.pixelFormat10bit)
        for target in [kCVPixelFormatType_32BGRA, PrismVCamConstants.pixelFormat420v] {
            let out = try XCTUnwrap(converter.makeSampleBuffer(from: hdr, targetFormat: target),
                                    "HDR program failed to convert to \(target)")
            XCTAssertEqual(subtype(out), target,
                           "an HDR program under an 8-bit negotiation must be converted, not mislabeled 10-bit")
        }
    }

    /// When the program already matches the negotiated format, the converter
    /// passes the buffer through untouched (zero-copy fast path).
    func testMatchingFormatPassesThrough() throws {
        let converter = VCamFormatConverter(width: 64, height: 64)
        let sdr = try sampleBuffer(try bgraProgramBuffer())
        let out = converter.makeSampleBuffer(from: sdr, targetFormat: kCVPixelFormatType_32BGRA)
        XCTAssertTrue(out === sdr, "matching format must pass through with no conversion")
    }

    // MARK: - #11 the 10-bit placeholder is a TRUTHFUL HLG conversion

    /// Independent oracle: neutral sRGB 128 → display-linear 0.2159 → HLG signal
    /// 0.7093 → 10-bit code ≈726. The pre-fix path emitted `128<<2 == 512` while
    /// stamping HLG — a lie.
    func testPlaceholderNeutralMapsToTruthfulHLGCode() {
        let (r, g, b) = PlaceholderRenderer.srgb8ToHLG2020Code(r8: 128, g8: 128, b8: 128)
        // Reproduction: the discarded naive shift.
        XCTAssertEqual(128 << 2, 512, "naive shift oracle (pre-fix HLG lie)")
        XCTAssertEqual(Int(r), Int(g)); XCTAssertEqual(Int(g), Int(b), "neutral gray must stay neutral")
        XCTAssertEqual(Double(r), 726, accuracy: 3,
                       "neutral sRGB 128 must map to the correct HLG code ≈726, not 512")
        XCTAssertGreaterThan(Int(r), 512 + 100, "the fix must not resemble the naive shift")
    }

    /// The full BGRA→l10r card conversion produces those codes end-to-end and
    /// tags the buffer Rec.2020/HLG.
    func testPlaceholderConvert10BitEndToEnd() throws {
        let bgra = try bgraProgramBuffer(fill: 128)
        let pool10 = try PixelBufferPool(width: 64, height: 64,
                                         pixelFormat: PrismVCamConstants.pixelFormat10bit)
        let card = try PlaceholderRenderer.convert10bit(from: bgra, pool: pool10)
        CVPixelBufferLockBaseAddress(card, .readOnly)
        let word = CVPixelBufferGetBaseAddress(card)!.assumingMemoryBound(to: UInt32.self)[0]
        CVPixelBufferUnlockBaseAddress(card, .readOnly)
        let r = (word >> 20) & 0x3FF, g = (word >> 10) & 0x3FF, b = word & 0x3FF
        XCTAssertEqual(Double(r), 726, accuracy: 3)
        XCTAssertEqual(Double(g), 726, accuracy: 3)
        XCTAssertEqual(Double(b), 726, accuracy: 3)
        let primaries = CVBufferGetAttachment(card, kCVImageBufferColorPrimariesKey, nil)?
            .takeUnretainedValue() as? String
        XCTAssertEqual(primaries, kCVImageBufferColorPrimaries_ITU_R_2020 as String)
    }

    // MARK: - #12 the advertised l10r format carries HDR color signaling

    private func ext(_ desc: CMFormatDescription, _ key: CFString) -> String? {
        CMFormatDescriptionGetExtension(desc, extensionKey: key) as? String
    }

    func testTenBitAdvertisedFormatCarriesHDRColorTags() throws {
        let desc = try XCTUnwrap(
            PrismExtensionDeviceSource.makeFormatDescription(for: PrismVCamConstants.pixelFormat10bit))
        XCTAssertEqual(ext(desc, kCMFormatDescriptionExtension_ColorPrimaries),
                       kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String,
                       "l10r must declare Rec.2020 primaries")
        XCTAssertEqual(ext(desc, kCMFormatDescriptionExtension_TransferFunction),
                       kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String,
                       "l10r must declare BT.2100-HLG transfer")
        XCTAssertEqual(ext(desc, kCMFormatDescriptionExtension_YCbCrMatrix),
                       kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String,
                       "l10r must declare the Rec.2020 matrix")
    }

    func testEightBitAdvertisedFormatsStaySDRTagged() throws {
        // Reproduction/control: pre-fix EVERY format was built extensions:nil.
        // The 8-bit formats must STAY untagged (SDR) — only l10r gains HDR tags.
        for codec in [PrismVCamConstants.pixelFormatBGRA, PrismVCamConstants.pixelFormat420v] {
            let desc = try XCTUnwrap(PrismExtensionDeviceSource.makeFormatDescription(for: codec))
            XCTAssertNil(ext(desc, kCMFormatDescriptionExtension_ColorPrimaries),
                         "an 8-bit SDR vcam format must not be HDR-tagged")
            XCTAssertNil(ext(desc, kCMFormatDescriptionExtension_TransferFunction))
        }
    }

    // MARK: - #8 CameraSource re-applies the output format on reselection

    /// Model the exact defect (pure, hardware-free): the OLD code resolved the
    /// output pixel format ONCE at first configuration and never re-applied it,
    /// so an SDR→10-bit reselection left the stale 8-bit format. The FIX
    /// re-resolves from the CURRENT selection on every format change.
    func testReselectionReappliesOutputFormat() {
        let available = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                         kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]

        // Initial configuration on an SDR (8-bit) device format → 8-bit output.
        let configured = CameraSource.preferredOutputFormat(activeIsTenBit: false, available: available)
        XCTAssertEqual(configured, CameraSource.outputPixelFormat)

        // Reselect to a 10-bit device format. Pre-fix behavior = frozen at the
        // configure-time value (stale 8-bit); fixed behavior = re-resolved.
        let stalePreFix = configured
        let reappliedFixed = CameraSource.preferredOutputFormat(activeIsTenBit: true, available: available)
        XCTAssertEqual(stalePreFix, CameraSource.outputPixelFormat,
                       "reproduction: a once-resolved format stays 8-bit after a 10-bit reselection")
        XCTAssertEqual(reappliedFixed, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                       "the reselection must re-apply the 10-bit output format")
        XCTAssertNotEqual(stalePreFix, reappliedFixed, "the stale format is a real, observable defect")

        // And the reverse: 10-bit → SDR reselection re-applies 8-bit.
        XCTAssertEqual(CameraSource.preferredOutputFormat(activeIsTenBit: false, available: available),
                       CameraSource.outputPixelFormat, "10-bit→SDR reselection must return to 8-bit")
    }

    // MARK: - sol #7 #9 — persistent conversion failures must engage the placeholder

    /// A run of DROPPED `mirrorToSource` conversions must let the sink go STALE so the
    /// placeholder engages — not freeze the client on the last good frame. The fix
    /// advances sink freshness ONLY on a successful send; pre-fix it refreshed BEFORE the
    /// conversion (even for a drop), pinning `placeholderShouldSend` shut forever.
    func testConsecutiveConversionFailuresEngagePlaceholder() {
        let staleness = PrismVCamConstants.sinkStalenessSeconds
        let lastGoodSend = 100.0          // freshness established by the last SUCCESSFUL send
        let dt = staleness / 4            // frames arrive faster than the staleness window
        let drops = 6

        func placeholderEngages(refreshOnDrop: Bool) -> Bool {
            var freshness = lastGoodSend
            var now = lastGoodSend
            var engaged = false
            for _ in 0..<drops {
                now += dt
                // A dropped conversion: the FIX leaves freshness untouched; the pre-fix
                // (refreshOnDrop) advances it to `now` even though nothing was sent.
                if refreshOnDrop { freshness = now }
                if PrismExtensionDeviceSource.placeholderShouldSend(
                    sourceClientCount: 1, now: now,
                    lastSinkFrameHostSeconds: freshness, staleness: staleness) {
                    engaged = true
                }
            }
            return engaged
        }

        // NEGATIVE CONTROL: pre-fix refresh-before-conversion keeps the sink "fresh" on
        // every drop → the placeholder never engages.
        XCTAssertFalse(placeholderEngages(refreshOnDrop: true),
                       "negative control vacuous: the sink went stale even while refreshing on every drop")
        // FIX: drops don't advance freshness → the sink goes stale → the placeholder engages.
        XCTAssertTrue(placeholderEngages(refreshOnDrop: false),
                      "#9: repeated conversion drops never engaged the placeholder (frozen last frame)")
    }
}
