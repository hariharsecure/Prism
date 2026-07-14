import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox
import XCTest

import PrismCompositor
import PrismCore
import PrismSources

/// sol #7 #6 — `MovieSource.renderFittedHDR` filled the letterbox / background bars
/// with an UNQUALIFIED `CIColor(red:green:blue:alpha:)`. When Core Image interprets
/// those raw components in the linear-Rec.2020 canvas working space instead of sRGB,
/// a public sRGB-gray letterbox bar composites to the WRONG code (sol's host: 369 vs
/// the correct sRGB value). The fix qualifies the letterbox `CIColor` with the sRGB
/// colorspace so CI always converts it correctly into the HLG/PQ canvas, independent
/// of the platform's `CIColor` default. (The default CLEAR background is unaffected —
/// α = 0.)
///
/// ── INDEPENDENT ORACLE + REPRODUCTION ───────────────────────────────────────
/// The oracle is the SAME sRGB gray rendered through an INDEPENDENT `CIContext`
/// (working = extendedLinear Rec.2020 → output = itur_2100_HLG) built in the test —
/// NOT via the MovieSource path — matching how a correctly-sRGB-qualified letterbox
/// must land. A DEBUG seam (`_test_unqualifiedLetterboxColor`) reproduces the DEFECT
/// MECHANISM on the SAME clip: the letterbox colour interpreted in the linear-Rec.2020
/// working space (what an unqualified `CIColor` did on sol's host) → a value that
/// DIVERGES from the sRGB oracle. (A plain unqualified `CIColor` defaults to sRGB on
/// this macOS, so the literal 369 is platform-specific; the seam pins the wrong-space
/// interpretation so the reproduction is deterministic here.)
///
/// SOFTWARE-VERIFIED ONLY (synthetic HDR asset); a real HDR display end-to-end
/// stays UNVERIFIED-until-hardware.
final class MovieSourceLetterboxColorTests: XCTestCase {

    private final class FrameBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var frame: VideoFrame?
        func store(_ f: VideoFrame) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard frame == nil else { return false }
            frame = f; return true
        }
    }

    private func firstFrame(of source: MovieSource) throws -> VideoFrame {
        let got = XCTestExpectation(description: "first frame")
        let box = FrameBox()
        source.onFrame = { frame in if box.store(frame) { got.fulfill() } }
        try source.start()
        wait(for: [got], timeout: 15)
        source.stop()
        guard let frame = box.frame else { throw XCTSkip("source produced no frame on this host") }
        return frame
    }

    // MARK: - the letterbox bar composites to the sRGB value, NOT the unqualified 369

    func testHLGMovieLetterboxIsSRGBQualified() throws {
        // A tall-narrow (9:16-ish) HDR clip fitted into a 16:9 canvas → wide side
        // letterbox bars filled with the background color.
        let url = try writeHEVCMain10(y10: 700, w: 64, h: 128,
                                      transfer: AVVideoTransferFunction_ITU_R_2100_HLG)
        defer { try? FileManager.default.removeItem(at: url) }

        // Opaque sRGB gray 0.5 background → visible letterbox bars.
        let gray = RGBAColor(r: 0.5, g: 0.5, b: 0.5, a: 1)
        let source = try MovieSource(fileURL: url, canvasSize: .hd, contentMode: .aspectFit,
                                     background: gray, loop: false)
        XCTAssertTrue(source.isHDR, "HLG HEVC Main10 clip not detected as HDR")
        let frame = try firstFrame(of: source)
        XCTAssertEqual(frame.pixelFormat, kCVPixelFormatType_64RGBAHalf,
                       "HDR movie not delivered as 64RGBAHalf")

        // Read a LEFT-bar pixel (well outside the centered fitted clip).
        let cw = frame.width, ch = frame.height
        let barX = cw / 20, barY = ch / 2

        let barCode = try compositeReadG(frame.pixelBuffer, w: cw, h: ch, x: barX, y: barY)

        // Independent oracle: the SAME sRGB gray 0.5, rendered through a matching
        // CIContext (working extendedLinear2020 → itur_2100_HLG) built HERE — the value
        // a correctly-sRGB-qualified letterbox must land at.
        let oracle = srgbGrayHLGCode(0.5)

        XCTAssertLessThanOrEqual(abs(barCode - oracle), 12,
            "letterbox bar G=\(barCode) ≠ sRGB-qualified oracle G=\(oracle) — background not sRGB-qualified")

        #if DEBUG
        // Reproduce the DEFECT MECHANISM on the SAME clip: the letterbox colour read in
        // the linear-Rec.2020 working space (what an unqualified CIColor did on sol's
        // host) — it DIVERGES from the sRGB oracle.
        let wrongSpaceOracle = linearGrayHLGCode(0.5)
        XCTAssertGreaterThan(abs(wrongSpaceOracle - oracle), 40,
            "oracle discriminator too weak (sRGB \(oracle) vs linear-space \(wrongSpaceOracle))")

        let preFix = try MovieSource(fileURL: url, canvasSize: .hd, contentMode: .aspectFit,
                                     background: gray, loop: false)
        preFix._test_unqualifiedLetterboxColor = true
        let old = try firstFrame(of: preFix)
        let oldBar = try compositeReadG(old.pixelBuffer, w: old.width, h: old.height,
                                        x: old.width / 20, y: old.height / 2)
        XCTAssertLessThanOrEqual(abs(oldBar - wrongSpaceOracle), 12,
            "seam letterbox G=\(oldBar) ≠ linear-space oracle \(wrongSpaceOracle) — seam not reproducing the mechanism")
        XCTAssertGreaterThan(abs(oldBar - oracle), 40,
            "wrong-space letterbox G=\(oldBar) did NOT diverge from the sRGB oracle \(oracle) — probe vacuous")
        XCTAssertGreaterThan(abs(oldBar - barCode), 40,
            "fixed letterbox G=\(barCode) indistinguishable from the wrong-space control G=\(oldBar)")
        #endif
    }

    /// Render a solid sRGB gray `v` through a CIContext (working extendedLinear2020 →
    /// output itur_2100_HLG) and return the 10-bit HLG G code. Independent of MovieSource.
    private func srgbGrayHLGCode(_ v: Double) -> Int {
        renderGrayHLGCode(v, space: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
    /// Same, but interpreting the components in the linear-Rec.2020 working space — the
    /// wrong-space interpretation the defect produced.
    private func linearGrayHLGCode(_ v: Double) -> Int {
        renderGrayHLGCode(v, space: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!)
    }
    private func renderGrayHLGCode(_ v: Double, space: CGColorSpace) -> Int {
        let working = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        let hlg = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
        let ctx = CIContext(options: [.workingColorSpace: working, .workingFormat: CIFormat.RGBAh])
        let rect = CGRect(x: 0, y: 0, width: 8, height: 8)
        let color = CIColor(red: CGFloat(v), green: CGFloat(v), blue: CGFloat(v), alpha: 1, colorSpace: space)!
        let ci = CIImage(color: color).cropped(to: rect)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 8, 8, kCVPixelFormatType_ARGB2101010LEPacked,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &pb)
        let out = pb!
        ctx.render(ci, to: out, bounds: rect, colorSpace: hlg)
        CVPixelBufferLockBaseAddress(out, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
        let word = CVPixelBufferGetBaseAddress(out)!.loadUnaligned(as: UInt32.self)
        return Int((word >> 10) & 0x3FF)
    }

    // MARK: - helpers --------------------------------------------------------------

    private func compositeReadG(_ buf: CVPixelBuffer, w: Int, h: Int, x: Int, y: Int) throws -> Int {
        guard let dev = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let compositor = try MetalCompositor(device: dev, width: w, height: h, colorMode: .hdr)
        let sid = SourceID("s")
        let scene = Scene(name: "s", layers: [Layer(sourceID: sid)])
        let prog = try compositor.composite(frames: [sid: VideoFrame(pixelBuffer: buf, pts: HouseClock.now(), source: sid)],
                                            scene: scene, pts: HouseClock.now())
        let out = prog.pixelBuffer
        CVPixelBufferLockBaseAddress(out, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
        let word = CVPixelBufferGetBaseAddress(out)!
            .advanced(by: y * CVPixelBufferGetBytesPerRow(out) + x * 4)
            .loadUnaligned(as: UInt32.self)
        return Int((word >> 10) & 0x3FF)
    }

    private func fillYUV10(_ buf: CVPixelBuffer, y: Int, c: Int) {
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let yBase = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!
        let yBpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
        let yw = CVPixelBufferGetWidthOfPlane(buf, 0), yh = CVPixelBufferGetHeightOfPlane(buf, 0)
        let yVal = UInt16(truncatingIfNeeded: y << 6)
        for row in 0..<yh {
            let p = (yBase + row * yBpr).assumingMemoryBound(to: UInt16.self)
            for col in 0..<yw { p[col] = yVal }
        }
        let cBase = CVPixelBufferGetBaseAddressOfPlane(buf, 1)!
        let cBpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
        let cw = CVPixelBufferGetWidthOfPlane(buf, 1), chh = CVPixelBufferGetHeightOfPlane(buf, 1)
        let cVal = UInt16(truncatingIfNeeded: c << 6)
        for row in 0..<chh {
            let p = (cBase + row * cBpr).assumingMemoryBound(to: UInt16.self)
            for col in 0..<cw { p[col * 2] = cVal; p[col * 2 + 1] = cVal }
        }
    }

    /// Write a tiny HEVC Main10 clip tagged Rec.2020 + the given transfer, fed neutral
    /// 10-bit `x420` frames at luma `y10`.
    private func writeHEVCMain10(y10: Int, w: Int, h: Int, transfer: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lbhdr.\(UUID().uuidString).mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            throw XCTSkip("could not create AVAssetWriter")
        }
        let colorProps: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: transfer,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: colorProps,
            AVVideoCompressionPropertiesKey: [
                kVTCompressionPropertyKey_ProfileLevel as String: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ])
        guard writer.canAdd(input) else { throw XCTSkip("HEVC Main10 encode unavailable on this host") }
        writer.add(input)
        guard writer.startWriting() else { throw XCTSkip("writer refused to start (\(String(describing: writer.error)))") }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<4 {
            guard let pool = adaptor.pixelBufferPool else { throw XCTSkip("no 10-bit pixel buffer pool") }
            var pbOut: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else {
                throw XCTSkip("could not allocate 10-bit buffer")
            }
            fillYUV10(pb, y: y10, c: 512)
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, AVVideoColorPrimaries_ITU_R_2020 as CFString, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, transfer as CFString, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, AVVideoYCbCrMatrix_ITU_R_2020 as CFString, .shouldPropagate)
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        let done = XCTestExpectation(description: "write hdr")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 15)
        guard writer.status == .completed else { throw XCTSkip("HDR clip write failed: \(String(describing: writer.error))") }
        return url
    }
}
