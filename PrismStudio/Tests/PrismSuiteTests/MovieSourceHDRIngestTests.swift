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

/// Stage N (Class A / HDR ingest) — `MovieSource` must stop forcing a 10-bit HDR
/// movie down to 8-bit BGRA. Before this stage `makeVideoReader` pinned
/// `kCVPixelFormatType_32BGRA` and fitted every frame through an 8-bit sRGB canvas,
/// so a real Rec.2020/HLG clip arrived 8-bit and untagged — the compositor's
/// wave-5b 10-bit ingest (M) could never actually receive 10-bit from this source.
///
/// The fixture is a REAL HEVC **Main10** clip written by `AVAssetWriter`, tagged
/// Rec.2020 / HLG, fed 10-bit `x420` pixel buffers. The source is then run and its
/// first emitted `VideoFrame` inspected.
///
/// Reproduce-first (live negative control): a DEBUG seam
/// `_test_forceEightBitDownconvert` reproduces the pre-fix path on the SAME clip —
/// with it ON the frame arrives 8-bit BGRA (sRGB-tagged), with it OFF the frame
/// arrives 10-bit `64RGBAHalf` tagged scene-linear Rec.2020.
///
/// SOFTWARE-VERIFIED ONLY: this verifies the software decode → 10-bit delivery →
/// colorimetry path with a 10-bit asset. A real HDR camera / HDR display end-to-end
/// remains UNVERIFIED-until-hardware.
final class MovieSourceHDRIngestTests: XCTestCase {

    // MARK: - Attachment readers

    private func transferTag(_ buf: CVPixelBuffer) -> CFString? {
        CVBufferCopyAttachment(buf, kCVImageBufferTransferFunctionKey, nil).map { $0 as! CFString }
    }
    private func primariesTag(_ buf: CVPixelBuffer) -> CFString? {
        CVBufferCopyAttachment(buf, kCVImageBufferColorPrimariesKey, nil).map { $0 as! CFString }
    }

    // MARK: - Drive the source, capture the first frame

    private func firstFrame(of source: MovieSource) throws -> VideoFrame {
        let got = XCTestExpectation(description: "first frame")
        let box = FrameBox()
        source.onFrame = { frame in
            if box.store(frame) { got.fulfill() }
        }
        try source.start()
        wait(for: [got], timeout: 15)
        source.stop()
        guard let frame = box.frame else { throw XCTSkip("source produced no frame on this host") }
        return frame
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

    // MARK: - (a) 10-bit HDR movie delivered at 10-bit WITH tags (+ negative control)

    func testHDRMovieDeliveredTenBitTaggedNotDownconverted() throws {
        let url = try writeHEVCMain10HLG(y10: 768)   // 8-bit 192·4, a bright mid gray
        defer { try? FileManager.default.removeItem(at: url) }

        // Detection: the clip is recognised HDR.
        let source = try MovieSource(fileURL: url, canvasSize: .hd, contentMode: .aspectFit, loop: false)
        XCTAssertTrue(source.isHDR, "Rec.2020/HLG HEVC Main10 clip not detected as HDR")

        let frame = try firstFrame(of: source)

        // Delivered at 10-bit precision (64RGBAHalf), NOT the pre-fix 8-bit BGRA.
        XCTAssertEqual(frame.pixelFormat, kCVPixelFormatType_64RGBAHalf,
                       "HDR movie was not delivered as 64RGBAHalf (got '\(FourCC(frame.pixelFormat))')")
        XCTAssertNotEqual(frame.pixelFormat, kCVPixelFormatType_32BGRA,
                          "HDR movie still down-converted to 8-bit BGRA (pre-fix regression)")

        // sol #5 finding 1: the fitted canvas holds an HLG SIGNAL in Rec.2020
        // primaries and is tagged HLG/Rec.2020 — so the compositor decodes it with
        // its OWN validated BT.2100 HLG inverse-OETF, matching the native x420 path.
        // (The pre-#5 stage-N tag was Linear + a Core Image `extendedLinear` DISPLAY-
        // linear output that over-brightened HLG.)
        XCTAssertEqual(primariesTag(frame.pixelBuffer), kCVImageBufferColorPrimaries_ITU_R_2020,
                       "delivered HDR frame lost its Rec.2020 primaries tag")
        XCTAssertEqual(transferTag(frame.pixelBuffer), kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                       "delivered HDR frame not tagged HLG (compositor would mis-decode it)")

        // ── The load-bearing claim of finding #1: a fitted HDR movie COMPOSITES to
        // the SAME value as the direct native x420 path. The INDEPENDENT ORACLE is a
        // real native 10-bit `x420` buffer at the SAME luma code (2020/HLG-tagged),
        // composited directly through the HDR compositor — the validated ground-truth
        // path (NOT re-derived from the movie path). ────────────────────────────────
        let w = 32, h = 32
        let native = try makeNativeX420(w: w, h: h, y10: 768)   // HLG signal ≈0.80 (video-range)
        let nativeComposited = try compositeSingle(native, w: w, h: h)

        let movieComposited = try compositeSingle(frame.pixelBuffer, w: w, h: h)

        // (i) The movie path now agrees with the native path (per channel, ≤ a few codes).
        for (m, n) in [(movieComposited.b, nativeComposited.b),
                       (movieComposited.g, nativeComposited.g),
                       (movieComposited.r, nativeComposited.r)] {
            XCTAssertLessThanOrEqual(abs(m - n), 8,
                "movie-fitted composite \(movieComposited) ≠ native x420 composite \(nativeComposited)")
        }
        // (ii) It is a genuine bright MID-TONE (≈822/1023), NOT the pre-fix clip: the
        // Core-Image `extendedLinear`/Linear-tag path over-brightened this same code
        // to a fully-clamped 1023 (crushing all highlight detail). Rule that out.
        XCTAssertGreaterThan(movieComposited.g, 700, "HDR gray composited too dark (\(movieComposited))")
        XCTAssertLessThan(movieComposited.g, 960,
            "HDR gray composited near-clipped (\(movieComposited)) — reproduces the pre-fix over-bright/clip")
        XCTAssertLessThanOrEqual(abs(movieComposited.r - movieComposited.g)
                                 + abs(movieComposited.g - movieComposited.b), 6,
                                 "not neutral: \(movieComposited)")

        #if DEBUG
        // Negative control: the SAME clip through the pre-stage-N 8-bit path.
        let preFix = try MovieSource(fileURL: url, canvasSize: .hd, contentMode: .aspectFit, loop: false)
        preFix._test_forceEightBitDownconvert = true
        let old = try firstFrame(of: preFix)
        XCTAssertEqual(old.pixelFormat, kCVPixelFormatType_32BGRA,
                       "negative control did not reproduce the 8-bit BGRA down-convert")
        XCTAssertNotEqual(old.pixelFormat, frame.pixelFormat,
                          "fixed 10-bit output indistinguishable from the 8-bit control")
        // The old path stamps sRGB (a DIFFERENT, non-HDR colorspace), never HLG.
        XCTAssertNotEqual(transferTag(old.pixelBuffer), kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                          "8-bit control unexpectedly tagged HLG")
        #endif
    }

    // MARK: - (a2) HDR movie WITH alpha keeps transparency AND HDR colour (sol #5 finding 5)

    /// A transparent-surround HLG ProRes 4444 overlay, composited over a solid lower
    /// colour through the HDR compositor, must let the lower colour show through the
    /// transparent region (alpha preserved) — the pre-fix `x420` (no-alpha) HDR path
    /// flattened it to opaque. And the opaque HDR box must show real bright colour.
    func testHDRMovieWithAlphaKeepsTransparencyAndColor() throws {
        let url = try writeProRes4444HLG()
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try MovieSource(fileURL: url, canvasSize: .init(width: 64, height: 64),
                                     contentMode: .stretch, loop: false)
        XCTAssertTrue(source.isHDR, "HLG ProRes 4444 clip not detected as HDR")
        XCTAssertTrue(source.hasAlphaChannel, "ProRes 4444 clip not detected as alpha-bearing")

        let frame = try firstFrame(of: source)
        // Delivered as the wide-gamut half-float canvas (NOT 8-bit, NOT alpha-less x420).
        XCTAssertEqual(frame.pixelFormat, kCVPixelFormatType_64RGBAHalf,
                       "HDR+alpha movie not delivered as 64RGBAHalf (got '\(FourCC(frame.pixelFormat))')")
        XCTAssertEqual(transferTag(frame.pixelBuffer), kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                       "HDR+alpha frame not tagged HLG")

        // Sanity: the delivered half-float frame actually carries a transparent region
        // (surround α≈0) and an opaque region (box α≈1) — proving alpha survived decode.
        let cornerA = readHalfA(frame.pixelBuffer, x: 2, y: 2)
        let centerA = readHalfA(frame.pixelBuffer, x: frame.width / 2, y: frame.height / 2)
        XCTAssertLessThan(cornerA, 0.2, "surround alpha not preserved (α=\(cornerA)) — HDR overlay went opaque")
        XCTAssertGreaterThan(centerA, 0.8, "box alpha lost (α=\(centerA))")

        // Composite the overlay (premultiplied) over a distinct solid lower colour.
        let w = 64, h = 64
        guard let dev = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let compositor = try MetalCompositor(device: dev, width: w, height: h, colorMode: .hdr)
        let lower = try makeBGRASolid(w: w, h: h, r: 20, g: 200, b: 90)  // vivid green, 709/untagged
        let bID = SourceID("lower"), tID = SourceID("overlay")
        let scene = Scene(name: "over", layers: [
            Layer(sourceID: bID, zIndex: 0),
            Layer(sourceID: tID, zIndex: 1, premultipliedAlpha: true),
        ])
        let now = HouseClock.now()
        let prog = try compositor.composite(
            frames: [bID: VideoFrame(pixelBuffer: lower, pts: now, source: bID),
                     tID: VideoFrame(pixelBuffer: frame.pixelBuffer, pts: now, source: tID)],
            scene: scene, pts: now)

        // Independent oracle for the surround: the lower green composited ALONE in the
        // HDR program (no overlay) — what must show through a truly-transparent surround.
        let lowerOnly = try compositeSingle(lower, w: w, h: h)

        // Transparent surround → lower green shows through (NOT opaque black, NOT the box).
        for (name, x, y) in [("TL", 4, 4), ("TR", w - 5, 4), ("BL", 4, h - 5), ("BR", w - 5, h - 5)] {
            let px = read10c(prog.pixelBuffer, x: x, y: y)
            XCTAssertFalse(px.b < 24 && px.g < 24 && px.r < 24,
                "\(name) (\(px)) is black — the HDR overlay blacked out the transparent surround")
            XCTAssertLessThanOrEqual(abs(px.g - lowerOnly.g), 40, "\(name) G should reveal the lower green \(lowerOnly), got \(px)")
            XCTAssertGreaterThan(px.g, px.r + 40, "\(name) should be green-dominant (lower layer), got \(px)")
        }
        // Opaque box centre → a real bright HDR colour, not black/transparent.
        let mid = read10c(prog.pixelBuffer, x: w / 2, y: h / 2)
        XCTAssertGreaterThan(mid.r + mid.g + mid.b, 900, "box centre too dark (\(mid)) — HDR colour lost")
    }

    /// Read the alpha channel of a `64RGBAHalf` texel.
    private func readHalfA(_ buf: CVPixelBuffer, x: Int, y: Int) -> Double {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(buf)!
            .advanced(by: y * CVPixelBufferGetBytesPerRow(buf) + x * 8)
            .assumingMemoryBound(to: Float16.self)
        return Double(p[3])
    }

    private func read10c(_ buf: CVPixelBuffer, x: Int, y: Int) -> (b: Int, g: Int, r: Int) {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let word = CVPixelBufferGetBaseAddress(buf)!
            .advanced(by: y * CVPixelBufferGetBytesPerRow(buf) + x * 4)
            .loadUnaligned(as: UInt32.self)
        return (Int(word & 0x3FF), Int((word >> 10) & 0x3FF), Int((word >> 20) & 0x3FF))
    }

    private func makeBGRASolid(w: Int, h: Int, r: UInt8, g: UInt8, b: UInt8) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pb else { throw XCTSkip("no bgra buffer") }
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        for row in 0..<h { for col in 0..<w {
            let p = base + row * bpr + col * 4
            p[0] = b; p[1] = g; p[2] = r; p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    /// Write a tiny ProRes 4444 clip tagged Rec.2020 / HLG with a REAL alpha channel:
    /// an opaque bright box on a transparent surround (source frames are `64RGBAHalf`
    /// half-float, so the clip is genuinely HDR + alpha). Skips if the host can't
    /// encode it.
    private func writeProRes4444HLG() throws -> URL {
        let w = 64, h = 64
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdralpha.\(UUID().uuidString).mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            throw XCTSkip("could not create AVAssetWriter")
        }
        let colorProps: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: colorProps,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ])
        guard writer.canAdd(input) else { throw XCTSkip("ProRes 4444 unavailable on this host") }
        writer.add(input)
        guard writer.startWriting() else { throw XCTSkip("writer refused to start (\(String(describing: writer.error)))") }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<3 {
            guard let pool = adaptor.pixelBufferPool else { throw XCTSkip("no pool") }
            var pbOut: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else {
                throw XCTSkip("no buffer")
            }
            CVPixelBufferLockBaseAddress(pb, [])
            let base = CVPixelBufferGetBaseAddress(pb)!
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            for y in 0..<h { for x in 0..<w {
                let inside = x >= 16 && x < 48 && y >= 16 && y < 48
                let p = (base + y * bpr + x * 8).assumingMemoryBound(to: Float16.self)
                if inside { p[0] = 0.75; p[1] = 0.55; p[2] = 0.30; p[3] = 1.0 }   // opaque bright (premult == straight at α=1)
                else { p[0] = 0; p[1] = 0; p[2] = 0; p[3] = 0 }                    // clear
            } }
            CVPixelBufferUnlockBaseAddress(pb, [])
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, AVVideoColorPrimaries_ITU_R_2020 as CFString, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, AVVideoTransferFunction_ITU_R_2100_HLG as CFString, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, AVVideoYCbCrMatrix_ITU_R_2020 as CFString, .shouldPropagate)
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        let done = XCTestExpectation(description: "write hdralpha")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 15)
        guard writer.status == .completed else { throw XCTSkip("HDR+alpha clip write failed: \(String(describing: writer.error))") }
        return url
    }

    /// A real native 10-bit `x420` (video-range) buffer, neutral gray at luma `y10`
    /// (chroma 512), tagged Rec.2020 / BT.2100-HLG — the ground-truth native ingest
    /// path the fitted movie canvas must match.
    private func makeNativeX420(w: Int, h: Int, y10: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let st = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                     kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                     attrs as CFDictionary, &pb)
        guard st == kCVReturnSuccess, let pb else { throw XCTSkip("could not allocate native x420") }
        fillYUV10(pb, y: y10, c: 512)
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return pb
    }

    /// Composite `buf` as a single full-canvas layer through the HDR compositor and
    /// read the centre 10-bit pixel (b,g,r).
    private func compositeSingle(_ buf: CVPixelBuffer, w: Int, h: Int) throws -> (b: Int, g: Int, r: Int) {
        guard let dev = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let compositor = try MetalCompositor(device: dev, width: w, height: h, colorMode: .hdr)
        let sid = SourceID("s")
        let scene = Scene(name: "s", layers: [Layer(sourceID: sid)])
        let prog = try compositor.composite(frames: [sid: VideoFrame(pixelBuffer: buf, pts: HouseClock.now(), source: sid)],
                                            scene: scene, pts: HouseClock.now())
        let out = prog.pixelBuffer
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(out), kCVPixelFormatType_ARGB2101010LEPacked)
        CVPixelBufferLockBaseAddress(out, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
        let word = CVPixelBufferGetBaseAddress(out)!
            .advanced(by: (h / 2) * CVPixelBufferGetBytesPerRow(out) + (w / 2) * 4)
            .loadUnaligned(as: UInt32.self)
        return (Int(word & 0x3FF), Int((word >> 10) & 0x3FF), Int((word >> 20) & 0x3FF))
    }

    // MARK: - (b) SDR movie still arrives 8-bit BGRA (no regression)

    func testSDRMovieStaysEightBitBGRA() throws {
        let url = try writeH264SDR()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try MovieSource(fileURL: url, canvasSize: .hd, contentMode: .aspectFit, loop: false)
        XCTAssertFalse(source.isHDR, "an SDR H.264 clip must not be flagged HDR")

        let frame = try firstFrame(of: source)
        XCTAssertEqual(frame.pixelFormat, kCVPixelFormatType_32BGRA,
                       "SDR movie no longer delivered as 8-bit BGRA (regression) — got '\(FourCC(frame.pixelFormat))'")
        // SDR frames carry the generated-content sRGB tag, never linear Rec.2020.
        XCTAssertNotEqual(transferTag(frame.pixelBuffer), kCVImageBufferTransferFunction_Linear,
                          "SDR frame wrongly tagged scene-linear")
    }

    // MARK: - helpers

    private func FourCC(_ code: OSType) -> String {
        let b: [UInt8] = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return b.allSatisfy { $0 >= 0x20 && $0 < 0x7F } ? String(bytes: b, encoding: .ascii)!
                                                        : String(format: "0x%08X", code)
    }

    /// Write a tiny HEVC **Main10** clip tagged Rec.2020 / HLG, fed neutral 10-bit
    /// `x420` frames at luma code `y10` (chroma neutral 512). Skips if the host
    /// can't encode HEVC Main10.
    private func writeHEVCMain10HLG(y10: Int) throws -> URL {
        let w = 64, h = 64
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdr10.\(UUID().uuidString).mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            throw XCTSkip("could not create AVAssetWriter")
        }
        let colorProps: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
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
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
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
            // Tag the source buffer too so the encoder keeps the colorimetry.
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, AVVideoColorPrimaries_ITU_R_2020 as CFString, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, AVVideoTransferFunction_ITU_R_2100_HLG as CFString, .shouldPropagate)
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

    /// Fill a 10-bit bi-planar buffer with a neutral gray (code in the high 10 bits).
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

    /// Write a tiny opaque H.264 SDR clip (8-bit BGRA source frames).
    private func writeH264SDR() throws -> URL {
        let w = 64, h = 64
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sdr.\(UUID().uuidString).mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            throw XCTSkip("could not create AVAssetWriter")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            ])
        guard writer.canAdd(input) else { throw XCTSkip("H.264 unavailable") }
        writer.add(input)
        guard writer.startWriting() else { throw XCTSkip("writer refused to start") }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<4 {
            guard let pool = adaptor.pixelBufferPool else { throw XCTSkip("no pool") }
            var pbOut: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else {
                throw XCTSkip("no buffer")
            }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let bpr = CVPixelBufferGetBytesPerRow(pb)
                let ptr = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<h { for x in 0..<w {
                    let p = ptr + y * bpr + x * 4
                    p[0] = 120; p[1] = 130; p[2] = 140; p[3] = 255
                } }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        let done = XCTestExpectation(description: "write sdr")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 10)
        guard writer.status == .completed else { throw XCTSkip("SDR clip write failed") }
        return url
    }
}
