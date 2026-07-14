import CoreMedia
import CoreVideo
import Metal
import XCTest

import PrismCompositor
import PrismCore
import PrismVision

/// sol #3 finding 4 — `SourceEffectGPU.makeTarget` and `BackgroundEffect` minted
/// pooled OUTPUT buffers WITHOUT propagating the source's colorimetry tags
/// (`CVImageBufferColorPrimaries` / `YCbCrMatrix` / transfer). The pre-pass
/// correctly decodes a tagged Rec.2020 source into 2020-primaries RGB (finding-9),
/// but the untagged output made the downstream compositor's `sourceIsRec2020`
/// read FALSE → it rotated 709→2020 a SECOND time. An 8-bit Rec.2020 source with
/// a GPU effect in an HDR show came out desaturated/hue-shifted.
///
/// Oracle is INDEPENDENT from-spec: YCbCr inverse re-derived from Kr/Kb, the
/// 709→2020 primary matrix + BT.709 EOTF + BT.2100 HLG OETF are published
/// constants (not the shader's math). The 2020 output must match the
/// NO-rotation oracle and be far from the double-rotated value.
final class FXVisionColorTagPropagationTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    // MARK: - independent from-spec oracle (copied from HDRDoubleRotationTests intent)

    private func eotf709(_ v: Double) -> Double { v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1.0 / 0.45) }
    private func hlgOETF(_ e: Double) -> Double {
        let e = max(e, 0)
        return e <= 1.0 / 12.0 ? (3 * e).squareRoot()
                               : 0.17883277 * log(12 * e - 0.28466892) + 0.55991073
    }
    private func sat(_ v: Double) -> Double { min(max(v, 0), 1) }
    private func sceneLinear2020(_ rgb: (Double, Double, Double), rotate: Bool) -> (Double, Double, Double) {
        var (r, g, b) = (eotf709(rgb.0), eotf709(rgb.1), eotf709(rgb.2))
        if rotate {
            (r, g, b) = (0.627404 * r + 0.329283 * g + 0.043313 * b,
                         0.069097 * r + 0.919540 * g + 0.011362 * b,
                         0.016391 * r + 0.088013 * g + 0.895595 * b)
        }
        return (sat(r), sat(g), sat(b))
    }
    private func decodeFull(kr: Double, kb: Double, y: Int, cb: Int, cr: Int) -> (Double, Double, Double) {
        let kg = 1 - kr - kb
        let yf = Double(y) / 255.0
        let cbf = Double(cb) / 255.0 - 0.5
        let crf = Double(cr) / 255.0 - 0.5
        let r = yf + 2 * (1 - kr) * crf
        let b = yf + 2 * (1 - kb) * cbf
        let g = (yf - kr * r - kb * b) / kg
        return (sat(r), sat(g), sat(b))
    }
    private func encodeFull(kr: Double, kb: Double, r: Double, g: Double, b: Double) -> (UInt8, UInt8, UInt8) {
        let kg = 1 - kr - kb
        let y = kr * r + kg * g + kb * b
        let cb = (b - y) / (2 * (1 - kb)) + 0.5
        let cr = (r - y) / (2 * (1 - kr)) + 0.5
        func q(_ v: Double) -> UInt8 { UInt8(min(max((v * 255).rounded(), 0), 255)) }
        return (q(y), q(cb), q(cr))
    }
    private func encode(_ disp: (Double, Double, Double), rotate: Bool) -> (b: Int, g: Int, r: Int) {
        let lin = sceneLinear2020(disp, rotate: rotate)
        func ch(_ v: Double) -> Int { Int((hlgOETF(v) * 1023).rounded()) }
        return (ch(lin.2), ch(lin.1), ch(lin.0))
    }

    // MARK: - fixtures / probes

    private func makeYUVRed(w: Int, h: Int, matrix: CFString, primaries: CFString?,
                            yByte: UInt8, cbByte: UInt8, crByte: UInt8) throws -> VideoFrame {
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        var pb: CVPixelBuffer?
        let st = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                     kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                     attrs as CFDictionary, &pb)
        guard st == kCVReturnSuccess, let buffer = pb else { throw XCTSkip("no biplanar buffer (\(st))") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let lb = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lbpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<h { for x in 0..<w { lb[y * lbpr + x] = yByte } }
        let cb = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let cbpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for cy in 0..<(h / 2) { for cx in 0..<(w / 2) {
            cb[cy * cbpr + cx * 2 + 0] = cbByte
            cb[cy * cbpr + cx * 2 + 1] = crByte
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        if let primaries {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        }
        return VideoFrame(pixelBuffer: buffer, pts: HouseClock.now(), source: SourceID("yuv"))
    }

    private func hasPrimaries(_ buf: CVPixelBuffer, _ primaries: CFString) -> Bool {
        guard let raw = CVBufferCopyAttachment(buf, kCVImageBufferColorPrimariesKey, nil) else { return false }
        return CFEqual(raw as AnyObject, primaries)
    }

    private func read10(_ buf: CVPixelBuffer, x: Int, y: Int) -> (b: Int, g: Int, r: Int) {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let word = CVPixelBufferGetBaseAddress(buf)!
            .advanced(by: y * CVPixelBufferGetBytesPerRow(buf) + x * 4)
            .loadUnaligned(as: UInt32.self)
        return (Int(word & 0x3FF), Int((word >> 10) & 0x3FF), Int((word >> 20) & 0x3FF))
    }

    private func compositeHDR(_ frame: VideoFrame, w: Int, h: Int) throws -> (b: Int, g: Int, r: Int) {
        let compositor = try MetalCompositor(device: try device(), width: w, height: h, colorMode: .hdr)
        let sid = frame.source
        let scene = Scene(name: "s", layers: [Layer(sourceID: sid)])
        let prog = try compositor.composite(frames: [sid: frame], scene: scene, pts: HouseClock.now())
        XCTAssertEqual(prog.pixelFormat, kCVPixelFormatType_ARGB2101010LEPacked)
        return read10(prog.pixelBuffer, x: w / 2, y: h / 2)
    }

    private func fullPersonMatte(_ w: Int, _ h: Int) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: w, height: h,
                                       pixelFormat: kCVPixelFormatType_OneComponent8, minimumBufferCount: 1)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<h { memset(base + y * row, 255, w) }
        return buf
    }

    // MARK: - shared assertions

    /// The FX/Vision output frame, fed through the HDR compositor, must NOT be
    /// double-rotated (2020 red stays saturated-red), and must carry 2020 primaries.
    private func assertNotDoubleRotated(_ out: VideoFrame, w: Int, h: Int, disp: (Double, Double, Double),
                                        _ label: String) throws {
        XCTAssertTrue(hasPrimaries(out.pixelBuffer, kCVImageBufferColorPrimaries_ITU_R_2020),
                      "\(label): output dropped ColorPrimaries==2020")
        XCTAssertTrue(YCbCrTags.isRec2020(for: out.pixelBuffer),
                      "\(label): output not seen as Rec.2020 downstream → would double-rotate")
        let got = try compositeHDR(out, w: w, h: h)
        let correct = encode(disp, rotate: false)  // already 2020 → no rotation
        let buggy = encode(disp, rotate: true)      // the double-rotation bug
        XCTAssertLessThanOrEqual(abs(got.r - correct.r), 14, "\(label) R \(got) vs no-rotation oracle \(correct)")
        XCTAssertLessThan(got.g, 260, "\(label) 2020 red green too high — double-rotated (\(got))")
        XCTAssertLessThan(got.b, 260, "\(label) 2020 red blue too high — double-rotated (\(got))")
        XCTAssertGreaterThan(buggy.g, 400, "sanity: double-rotated green should be large (\(buggy))")
    }

    // MARK: - FX (SourceEffectGPU) output tags

    func testFXOutputCarries2020TagsAndIsNotDoubleRotated() throws {
        let w = 64, h = 64
        let (kr, kb) = (0.2627, 0.0593)
        let (yB, cbB, crB) = encodeFull(kr: kr, kb: kb, r: 1, g: 0, b: 0)
        let frame = try makeYUVRed(w: w, h: h,
                                   matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
                                   primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                                   yByte: yB, cbByte: cbB, crByte: crB)
        let fx = try SourceEffectGPU(device: try device(), width: w, height: h)
        let fxOut = try fx.videoWall(source: frame.pixelBuffer, rows: 1, cols: 1, mirror: false)
        let outFrame = VideoFrame(pixelBuffer: fxOut, pts: frame.pts, source: SourceID("fx2020"))
        let disp = decodeFull(kr: kr, kb: kb, y: Int(yB), cb: Int(cbB), cr: Int(crB))
        try assertNotDoubleRotated(outFrame, w: w, h: h, disp: disp, "FX")
    }

    func testFXOutputUntaggedStays709() throws {
        let w = 32, h = 32
        // No primaries, no matrix → 709 default; FX output must NOT gain 2020.
        let (yB, cbB, crB): (UInt8, UInt8, UInt8) = (130, 90, 230)
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        var pb: CVPixelBuffer?
        _ = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs as CFDictionary, &pb)
        let buffer = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let lb = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lbpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<h { for x in 0..<w { lb[y * lbpr + x] = yB } }
        let cb = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let cbpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for cy in 0..<(h / 2) { for cx in 0..<(w / 2) {
            cb[cy * cbpr + cx * 2 + 0] = cbB; cb[cy * cbpr + cx * 2 + 1] = crB
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let fx = try SourceEffectGPU(device: try device(), width: w, height: h)
        let fxOut = try fx.videoWall(source: buffer, rows: 1, cols: 1, mirror: false)
        XCTAssertFalse(hasPrimaries(fxOut, kCVImageBufferColorPrimaries_ITU_R_2020),
                       "untagged FX output must not gain 2020 primaries")
        XCTAssertFalse(YCbCrTags.isRec2020(for: fxOut), "untagged FX output must stay non-2020 (709)")
    }

    // MARK: - Vision (BackgroundEffect) output tags

    func testVisionOutputCarries2020TagsAndIsNotDoubleRotated() throws {
        let w = 64, h = 64
        let (kr, kb) = (0.2627, 0.0593)
        let (yB, cbB, crB) = encodeFull(kr: kr, kb: kb, r: 1, g: 0, b: 0)
        let frame = try makeYUVRed(w: w, h: h,
                                   matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
                                   primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                                   yByte: yB, cbByte: cbB, crByte: crB)
        let effect = try BackgroundEffect(device: try device())
        let matte = try fullPersonMatte(w, h)
        let out = try effect.apply(frame: frame,
                                   matte: SegmentationMatte(pixelBuffer: matte, pts: frame.pts, source: frame.source),
                                   mode: .remove)
        let disp = decodeFull(kr: kr, kb: kb, y: Int(yB), cb: Int(cbB), cr: Int(crB))
        try assertNotDoubleRotated(out, w: w, h: h, disp: disp, "Vision")
    }
}
