import CoreMedia
import CoreVideo
import Metal
import XCTest

import PrismCompositor
import PrismCore
import PrismVision

/// N5 / finding-9 — the primary layer path already honored the source's tagged
/// `YCbCrMatrix` + `ChromaLocation`, but the **SourceEffectGPU YUV pre-pass**
/// (`prism_srcfx_yuv_to_bgra`) and the **Vision background decode**
/// (`VisionShaders.sample_yuv`) hardcoded centered BT.709. So a BT.601 / BT.2020
/// (or left-sited) source that had ANY per-source effect, or a background-remove,
/// took a hue shift + half-pixel chroma misalignment — and because the pre-pass
/// outputs BGRA, the lost metadata could not be repaired downstream.
///
/// The oracle is an INDEPENDENT decode: the YCbCr→RGB inverse is re-derived from
/// the ITU luma weights (Kr/Kb), not copied from the shader coefficients. Fixtures
/// are spatially varying (Class A). Includes a FX-vs-primary-layer PARITY check.
final class FXVisionYUVMatrixSitingTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    // MARK: - fixture (full-range biplanar 420, matrix + optional left siting)

    private func makeYUV(w: Int, h: Int, matrix: CFString, leftSited: Bool,
                         lumaAt: (Int, Int) -> UInt8,
                         chromaAt: (Int, Int) -> (UInt8, UInt8)) throws -> VideoFrame {
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        var pb: CVPixelBuffer?
        let st = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                     kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                     attrs as CFDictionary, &pb)
        guard st == kCVReturnSuccess, let buffer = pb else { throw XCTSkip("no biplanar buffer (\(st))") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let lb = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lbpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<h { for x in 0..<w { lb[y * lbpr + x] = lumaAt(x, y) } }
        let cb = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let cbpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for cy in 0..<(h / 2) { for cx in 0..<(w / 2) {
            let (cbv, crv) = chromaAt(cx, cy)
            cb[cy * cbpr + cx * 2 + 0] = cbv
            cb[cy * cbpr + cx * 2 + 1] = crv
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        if leftSited {
            CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey,
                                  kCVImageBufferChromaLocation_Left, .shouldPropagate)
        }
        return VideoFrame(pixelBuffer: buffer, pts: HouseClock.now(), source: SourceID("yuv"))
    }

    /// Independent full-range YCbCr→RGB, inverse RE-DERIVED from Kr/Kb.
    private func oracleRGB(y: UInt8, cb: UInt8, cr: UInt8, kr: Double, kb: Double) -> (r: Int, g: Int, b: Int) {
        let kg = 1 - kr - kb
        let yf = Double(y) / 255.0
        let cbf = Double(cb) / 255.0 - 0.5
        let crf = Double(cr) / 255.0 - 0.5
        let r = yf + 2 * (1 - kr) * crf
        let b = yf + 2 * (1 - kb) * cbf
        let g = (yf - kr * r - kb * b) / kg
        func q(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return (q(r), q(g), q(b))
    }

    private func readBGRA(_ buf: CVPixelBuffer, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(buf)!
            .advanced(by: y * CVPixelBufferGetBytesPerRow(buf) + x * 4)
            .assumingMemoryBound(to: UInt8.self)
        return (Int(p[2]), Int(p[1]), Int(p[0]))
    }

    // MARK: - FX pre-pass: matrix

    /// A 601-tagged source WITH an effect (VideoWall 1×1 = identity resample, so it
    /// isolates the YUV pre-pass decode) converts via the 601 matrix — matching the
    /// independent 601 oracle and measurably different from the 709 decode.
    func testFXPrePassHonors601Matrix() throws {
        let w = 64, h = 64
        let fx = try SourceEffectGPU(device: try device(), width: w, height: h)
        let cbV: UInt8 = 200, crV: UInt8 = 90
        func luma(_ x: Int, _ y: Int) -> UInt8 { UInt8(40 + (y * 170 / h)) }   // vertical gradient
        func chroma(_ cx: Int, _ cy: Int) -> (UInt8, UInt8) { (cbV, crV) }     // constant

        let f601 = try makeYUV(w: w, h: h, matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                               leftSited: false, lumaAt: luma, chromaAt: chroma)
        let f709 = try makeYUV(w: w, h: h, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                               leftSited: false, lumaAt: luma, chromaAt: chroma)
        let out601 = try fx.videoWall(source: f601.pixelBuffer, rows: 1, cols: 1, mirror: false)
        let out709 = try fx.videoWall(source: f709.pixelBuffer, rows: 1, cols: 1, mirror: false)

        let px = w / 2, py = h / 2
        let got601 = readBGRA(out601, x: px, y: py)
        let got709 = readBGRA(out709, x: px, y: py)
        let want601 = oracleRGB(y: luma(px, py), cb: cbV, cr: crV, kr: 0.299, kb: 0.114)
        let want709 = oracleRGB(y: luma(px, py), cb: cbV, cr: crV, kr: 0.2126, kb: 0.0722)

        XCTAssertLessThanOrEqual(abs(got601.r - want601.r), 3, "FX 601 R \(got601) vs oracle \(want601)")
        XCTAssertLessThanOrEqual(abs(got601.g - want601.g), 3, "FX 601 G \(got601) vs oracle \(want601)")
        XCTAssertLessThanOrEqual(abs(got601.b - want601.b), 3, "FX 601 B \(got601) vs oracle \(want601)")
        // 709 path still matches its own oracle (no regression for untagged/709).
        XCTAssertLessThanOrEqual(abs(got709.r - want709.r), 3, "FX 709 R \(got709) vs oracle \(want709)")
        let diff = abs(got601.r - got709.r) + abs(got601.g - got709.g) + abs(got601.b - got709.b)
        XCTAssertGreaterThan(diff, 6, "FX pre-pass decoded 601 and 709 identically (\(got601) vs \(got709)) — matrix ignored")
    }

    /// PARITY: the same 601-tagged source converts to the SAME color on the FX
    /// pre-pass and the primary compositor layer path (both now use the tagged
    /// matrix), so an effect source and a plain layer of it agree.
    func testFXPrePassMatchesPrimaryLayerForTaggedSource() throws {
        let w = 64, h = 64
        let fx = try SourceEffectGPU(device: try device(), width: w, height: h)
        let compositor = try MetalCompositor(device: try device(), width: w, height: h)
        let cbV: UInt8 = 210, crV: UInt8 = 70
        func luma(_ x: Int, _ y: Int) -> UInt8 { UInt8(30 + (x * 180 / w)) }
        func chroma(_ cx: Int, _ cy: Int) -> (UInt8, UInt8) { (cbV, crV) }

        let frame = try makeYUV(w: w, h: h, matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                                leftSited: false, lumaAt: luma, chromaAt: chroma)
        let fxOut = try fx.videoWall(source: frame.pixelBuffer, rows: 1, cols: 1, mirror: false)
        let sid = SourceID("yuv")
        let layerOut = try compositor.composite(frames: [sid: frame],
                                                scene: Scene(name: "s", layers: [Layer(sourceID: sid)]),
                                                pts: HouseClock.now())
        for (px, py) in [(w / 2, h / 2), (w / 4, h / 3), (3 * w / 4, 2 * h / 3)] {
            let a = readBGRA(fxOut, x: px, y: py)
            let b = readBGRA(layerOut.pixelBuffer, x: px, y: py)
            XCTAssertLessThanOrEqual(abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b), 4,
                                     "FX-vs-layer parity broke at (\(px),\(py)): FX \(a) layer \(b)")
        }
    }

    /// FX pre-pass left-siting: a left/co-sited source samples chroma half a luma
    /// pixel to the right of centered → with a horizontal Cr ramp the reconstructed
    /// red shifts by the independent siting oracle (0.25 chroma-texel · ramp step).
    func testFXPrePassLeftSitingShiftsChroma() throws {
        let w = 16, h = 8
        let fx = try SourceEffectGPU(device: try device(), width: w, height: h)
        let step = 32.0, base = 20.0
        func luma(_ x: Int, _ y: Int) -> UInt8 { 180 }
        func chroma(_ cx: Int, _ cy: Int) -> (UInt8, UInt8) {
            (128, UInt8(min(max(base + Double(cx) * step, 0), 255)))
        }
        let centered = try makeYUV(w: w, h: h, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                                   leftSited: false, lumaAt: luma, chromaAt: chroma)
        let left = try makeYUV(w: w, h: h, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                               leftSited: true, lumaAt: luma, chromaAt: chroma)
        let pc = try fx.videoWall(source: centered.pixelBuffer, rows: 1, cols: 1, mirror: false)
        let pl = try fx.videoWall(source: left.pixelBuffer, rows: 1, cols: 1, mirror: false)

        let px = 8, py = h / 2
        let rc = readBGRA(pc, x: px, y: py).r
        let rl = readBGRA(pl, x: px, y: py).r
        let expectedDelta = 1.5748 * 0.25 * step
        XCTAssertGreaterThan(rl - rc, 6, "FX left siting did not shift chroma right (ΔR=\(rl - rc))")
        XCTAssertLessThanOrEqual(abs(Double(rl - rc) - expectedDelta), 6,
                                 "FX left-vs-centered ΔR=\(rl - rc), oracle ≈\(expectedDelta)")
    }

    // MARK: - Vision decode: matrix

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

    private func rawBGRA(_ buf: CVPixelBuffer, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(buf)!
            .advanced(by: y * CVPixelBufferGetBytesPerRow(buf) + x * 4)
            .assumingMemoryBound(to: UInt8.self)
        return (Int(p[2]), Int(p[1]), Int(p[0]), Int(p[3]))
    }

    /// A 601-tagged source through the Vision background `.remove` (all-person
    /// matte → decoded color at alpha 1) converts via the 601 matrix, matching the
    /// independent 601 oracle and distinct from the 709 decode.
    func testVisionDecodeHonors601Matrix() throws {
        let w = 64, h = 64
        let effect = try BackgroundEffect(device: try device())
        let cbV: UInt8 = 205, crV: UInt8 = 85
        func luma(_ x: Int, _ y: Int) -> UInt8 { UInt8(40 + (y * 170 / h)) }
        func chroma(_ cx: Int, _ cy: Int) -> (UInt8, UInt8) { (cbV, crV) }

        let f601 = try makeYUV(w: w, h: h, matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                               leftSited: false, lumaAt: luma, chromaAt: chroma)
        let f709 = try makeYUV(w: w, h: h, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                               leftSited: false, lumaAt: luma, chromaAt: chroma)
        let matte = try fullPersonMatte(w, h)
        func decode(_ f: VideoFrame) throws -> (r: Int, g: Int, b: Int, a: Int) {
            let out = try effect.apply(frame: f,
                                       matte: SegmentationMatte(pixelBuffer: matte, pts: f.pts, source: f.source),
                                       mode: .remove)
            return rawBGRA(out.pixelBuffer, x: w / 2, y: h / 2)
        }
        let got601 = try decode(f601)
        let got709 = try decode(f709)
        let want601 = oracleRGB(y: luma(w / 2, h / 2), cb: cbV, cr: crV, kr: 0.299, kb: 0.114)

        XCTAssertEqual(got601.a, 255, "person pixel must be opaque")
        XCTAssertLessThanOrEqual(abs(got601.r - want601.r), 3, "Vision 601 R \(got601) vs oracle \(want601)")
        XCTAssertLessThanOrEqual(abs(got601.g - want601.g), 3, "Vision 601 G \(got601) vs oracle \(want601)")
        XCTAssertLessThanOrEqual(abs(got601.b - want601.b), 3, "Vision 601 B \(got601) vs oracle \(want601)")
        let diff = abs(got601.r - got709.r) + abs(got601.g - got709.g) + abs(got601.b - got709.b)
        XCTAssertGreaterThan(diff, 6, "Vision decoded 601 and 709 identically (\(got601) vs \(got709)) — matrix ignored")
    }
}
