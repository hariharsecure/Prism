import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox
import XCTest

import PrismCompositor
import PrismCore
import PrismSources

/// sol #6 finding 1 — `MovieSource` rendered EVERY HDR transfer into an `itur_2100_HLG`
/// canvas. Correct for an HLG clip, but a PQ clip was PQ→HLG tone-mapped by Core Image
/// (a PQ Y10 512 emitted ≈650 vs the native-PQ compositor's ≈565). The fix delivers a
/// PQ clip into a PQ-tagged canvas so the compositor decodes it as PQ and it composites
/// to the SAME value as a native PQ `x420` source. HLG clips are unchanged.
///
/// The INDEPENDENT ORACLE is a real native 10-bit `x420` buffer at the same luma code,
/// PQ-tagged, composited directly through the validated HDR compositor — NOT re-derived
/// from the movie path. A DEBUG seam (`_test_forceHLGCanvasForPQ`) reproduces the pre-fix
/// HLG-canvas path on the SAME clip as a live negative control.
///
/// SOFTWARE-VERIFIED ONLY (synthetic 10-bit asset); real HDR camera/display end-to-end
/// stays UNVERIFIED-until-hardware.
final class MovieSourcePQIngestTests: XCTestCase {

    private func transferTag(_ buf: CVPixelBuffer) -> CFString? {
        CVBufferCopyAttachment(buf, kCVImageBufferTransferFunctionKey, nil).map { $0 as! CFString }
    }

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

    // MARK: - (1) a PQ movie composites to the native PQ value (≈565), NOT the HLG ≈650

    func testPQMovieCompositesAsPQNotHLG() throws {
        let y10 = 512
        let url = try writeHEVCMain10(y10: y10, transfer: AVVideoTransferFunction_SMPTE_ST_2084_PQ)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try MovieSource(fileURL: url, canvasSize: .hd, contentMode: .aspectFit, loop: false)
        XCTAssertTrue(source.isHDR, "Rec.2020/PQ HEVC Main10 clip not detected as HDR")
        let frame = try firstFrame(of: source)

        // Delivered PQ-tagged (NOT re-tagged HLG, which would signal the wrong decode).
        XCTAssertEqual(frame.pixelFormat, kCVPixelFormatType_64RGBAHalf,
                       "PQ movie not delivered as 64RGBAHalf (got '\(fourCC(frame.pixelFormat))')")
        XCTAssertEqual(transferTag(frame.pixelBuffer), kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                       "PQ movie was not tagged PQ (forced through the HLG canvas)")

        // Independent oracle: a native PQ x420 buffer at the SAME luma, composited direct.
        let w = 32, h = 32
        let native = try makeNativeX420PQ(w: w, h: h, y10: y10)
        let nativeG = try compositeSingleG(native, w: w, h: h)
        let movieG = try compositeSingleG(frame.pixelBuffer, w: w, h: h)

        // (i) The fixed PQ movie agrees with the native PQ path.
        XCTAssertLessThanOrEqual(abs(movieG - nativeG), 24,
            "PQ movie composite G=\(movieG) ≠ native PQ G=\(nativeG)")

        #if DEBUG
        // (ii) Reproduce the pre-fix HLG-canvas path on the SAME clip: it DIVERGES from
        // the native PQ value (Core Image PQ→HLG tone-map ≈650 vs native ≈565).
        let preFix = try MovieSource(fileURL: url, canvasSize: .hd, contentMode: .aspectFit, loop: false)
        preFix._test_forceHLGCanvasForPQ = true
        let old = try firstFrame(of: preFix)
        XCTAssertEqual(transferTag(old.pixelBuffer), kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                       "seam did not reproduce the HLG-canvas path")
        let oldG = try compositeSingleG(old.pixelBuffer, w: w, h: h)
        XCTAssertGreaterThan(abs(oldG - nativeG), 40,
            "pre-fix HLG-canvas G=\(oldG) did NOT diverge from native PQ G=\(nativeG) — probe vacuous")
        XCTAssertGreaterThan(abs(oldG - movieG), 40,
            "fixed PQ movie G=\(movieG) indistinguishable from the HLG-canvas control G=\(oldG)")
        #endif
    }

    // MARK: - (2) an HLG movie is UNCHANGED (still HLG-tagged, matches native HLG) ---

    func testHLGMovieUnchanged() throws {
        let y10 = 768
        let url = try writeHEVCMain10(y10: y10, transfer: AVVideoTransferFunction_ITU_R_2100_HLG)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try MovieSource(fileURL: url, canvasSize: .hd, contentMode: .aspectFit, loop: false)
        XCTAssertTrue(source.isHDR)
        let frame = try firstFrame(of: source)
        XCTAssertEqual(transferTag(frame.pixelBuffer), kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                       "HLG movie no longer tagged HLG (regression)")

        let w = 32, h = 32
        let native = try makeNativeX420(w: w, h: h, y10: y10, transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG)
        let nativeG = try compositeSingleG(native, w: w, h: h)
        let movieG = try compositeSingleG(frame.pixelBuffer, w: w, h: h)
        XCTAssertLessThanOrEqual(abs(movieG - nativeG), 24, "HLG movie \(movieG) drifted from native HLG \(nativeG)")
    }

    // MARK: - helpers --------------------------------------------------------------

    private func compositeSingleG(_ buf: CVPixelBuffer, w: Int, h: Int) throws -> Int {
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
            .advanced(by: (h / 2) * CVPixelBufferGetBytesPerRow(out) + (w / 2) * 4)
            .loadUnaligned(as: UInt32.self)
        return Int((word >> 10) & 0x3FF)
    }

    private func makeNativeX420(w: Int, h: Int, y10: Int, transfer: CFString) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                  kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else {
            throw XCTSkip("could not allocate native x420")
        }
        fillYUV10(pb, y: y10, c: 512)
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return pb
    }

    private func makeNativeX420PQ(w: Int, h: Int, y10: Int) throws -> CVPixelBuffer {
        try makeNativeX420(w: w, h: h, y10: y10, transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
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
        let cw = CVPixelBufferGetWidthOfPlane(buf, 1), ch = CVPixelBufferGetHeightOfPlane(buf, 1)
        let cVal = UInt16(truncatingIfNeeded: c << 6)
        for row in 0..<ch {
            let p = (cBase + row * cBpr).assumingMemoryBound(to: UInt16.self)
            for col in 0..<cw { p[col * 2] = cVal; p[col * 2 + 1] = cVal }
        }
    }

    private func fourCC(_ code: OSType) -> String {
        let b: [UInt8] = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return b.allSatisfy { $0 >= 0x20 && $0 < 0x7F } ? String(bytes: b, encoding: .ascii)!
                                                        : String(format: "0x%08X", code)
    }

    /// Write a tiny HEVC Main10 clip tagged Rec.2020 + the given transfer, fed neutral
    /// 10-bit `x420` frames at luma `y10` (chroma neutral 512).
    private func writeHEVCMain10(y10: Int, transfer: String) throws -> URL {
        let w = 64, h = 64
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pqhdr.\(UUID().uuidString).mov")
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
