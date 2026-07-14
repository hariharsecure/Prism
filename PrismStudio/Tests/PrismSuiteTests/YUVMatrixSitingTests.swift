import CoreMedia
import CoreVideo
import Metal
import XCTest

import PrismCompositor
import PrismCore

/// MED-9 — the compositor's YUV→RGB path hardcoded centered BT.709 and honored
/// only full/video RANGE, ignoring the source's tagged `CVImageBufferYCbCrMatrix`
/// (BT.601 / BT.2020) and `CVImageBufferChromaLocation` (left vs centered). A
/// BT.601 source rendered with the 709 matrix shifts hue/saturation; a left-sited
/// source sampled at the centered position shifts chroma half a pixel.
///
/// The oracle is an INDEPENDENT hand-derived ITU decode (a plain Swift loop), not
/// the GPU converter — and the fixtures are spatially varying (luma gradient /
/// chroma ramp), never solid color (Class A / Class I).
final class YUVMatrixSitingTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    // MARK: - biplanar 420 fixture

    /// Make an IOSurface-backed biplanar 420 full-range buffer, filling luma via
    /// `lumaAt(x,y)` (0…255) and chroma via `chromaAt(cx,cy) -> (cb,cr)` on the
    /// W/2×H/2 chroma grid, then tag matrix + (optional) left siting.
    private func makeYUV(w: Int, h: Int,
                         matrix: CFString, leftSited: Bool,
                         lumaAt: (Int, Int) -> UInt8,
                         chromaAt: (Int, Int) -> (UInt8, UInt8)) throws -> VideoFrame {
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        var pb: CVPixelBuffer?
        let st = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                     kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                     attrs as CFDictionary, &pb)
        guard st == kCVReturnSuccess, let buffer = pb else {
            throw XCTSkip("could not create biplanar buffer (\(st))")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaBPR = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<h { for x in 0..<w { lumaBase[y * lumaBPR + x] = lumaAt(x, y) } }
        let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let cBPR = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let cw = w / 2, ch = h / 2
        for cy in 0..<ch { for cx in 0..<cw {
            let (cb, cr) = chromaAt(cx, cy)
            cBase[cy * cBPR + cx * 2 + 0] = cb
            cBase[cy * cBPR + cx * 2 + 1] = cr
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        if leftSited {
            CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey,
                                  kCVImageBufferChromaLocation_Left, .shouldPropagate)
        }
        return VideoFrame(pixelBuffer: buffer, pts: HouseClock.now(), source: SourceID("yuv"))
    }

    // Independent full-range YCbCr→RGB oracle (hand-derived ITU; NOT the shader).
    private func oracleRGB(y: UInt8, cb: UInt8, cr: UInt8, matrix601: Bool) -> (Int, Int, Int) {
        let yf = Double(y) / 255.0
        let cbf = Double(cb) / 255.0 - 128.0 / 255.0
        let crf = Double(cr) / 255.0 - 128.0 / 255.0
        let r: Double, g: Double, b: Double
        if matrix601 {
            r = yf + 1.402 * crf
            g = yf - 0.344136 * cbf - 0.714136 * crf
            b = yf + 1.772 * cbf
        } else { // 709
            r = yf + 1.5748 * crf
            g = yf - 0.1873 * cbf - 0.4681 * crf
            b = yf + 1.8556 * cbf
        }
        func q(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return (q(r), q(g), q(b))
    }

    private func readBGRA(_ frame: VideoFrame, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let buf = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(buf)!
            .advanced(by: y * CVPixelBufferGetBytesPerRow(buf) + x * 4)
            .assumingMemoryBound(to: UInt8.self)
        return (Int(p[2]), Int(p[1]), Int(p[0]))
    }

    // MARK: - matrix

    /// A BT.601-tagged frame decodes with the 601 matrix (distinct from 709) and
    /// matches the independent 601 oracle. Luma is a vertical gradient (spatially
    /// varying); chroma is constant so upsampling is exact and the matrix is
    /// isolated.
    func testMatrix601DistinctFrom709AndMatchesOracle() throws {
        let w = 64, h = 64
        let compositor = try MetalCompositor(device: try device(), width: w, height: h)
        // Constant, clearly-chromatic chroma; varying luma.
        let cbV: UInt8 = 200, crV: UInt8 = 90
        func luma(_ x: Int, _ y: Int) -> UInt8 { UInt8(40 + (y * 170 / h)) }
        func chroma(_ cx: Int, _ cy: Int) -> (UInt8, UInt8) { (cbV, crV) }

        let f601 = try makeYUV(w: w, h: h, matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                               leftSited: false, lumaAt: luma, chromaAt: chroma)
        let f709 = try makeYUV(w: w, h: h, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                               leftSited: false, lumaAt: luma, chromaAt: chroma)
        let sid = SourceID("yuv")
        let scene = Scene(name: "s", layers: [Layer(sourceID: sid)])
        let p601 = try compositor.composite(frames: [sid: f601], scene: scene, pts: HouseClock.now())
        let p709 = try compositor.composite(frames: [sid: f709], scene: scene, pts: HouseClock.now())

        let px = w / 2, py = h / 2
        let got601 = readBGRA(p601, x: px, y: py)
        let got709 = readBGRA(p709, x: px, y: py)
        let yHere = luma(px, py)
        let want601 = oracleRGB(y: yHere, cb: cbV, cr: crV, matrix601: true)
        let want709 = oracleRGB(y: yHere, cb: cbV, cr: crV, matrix601: false)

        // Correct matrix selected: GPU 601 ≈ 601 oracle.
        XCTAssertLessThanOrEqual(abs(got601.r - want601.0), 3, "601 R \(got601) vs oracle \(want601)")
        XCTAssertLessThanOrEqual(abs(got601.g - want601.1), 3, "601 G \(got601) vs oracle \(want601)")
        XCTAssertLessThanOrEqual(abs(got601.b - want601.2), 3, "601 B \(got601) vs oracle \(want601)")
        // 709 path still matches the 709 oracle (no regression).
        XCTAssertLessThanOrEqual(abs(got709.r - want709.0), 3, "709 R \(got709) vs oracle \(want709)")
        // The two matrices are ACTUALLY different (proves the tag is honored, not
        // both silently 709): the green channel diverges most for reds/greens.
        let diff = abs(got601.g - got709.g) + abs(got601.r - got709.r) + abs(got601.b - got709.b)
        XCTAssertGreaterThan(diff, 6, "601 and 709 decoded identically (\(got601) vs \(got709)) — matrix ignored")
    }

    // MARK: - chroma siting

    /// A left/co-sited-horizontal frame samples chroma half a luma pixel to the
    /// right of the centered position. With a horizontal chroma RAMP the two
    /// sitings reconstruct different Cr at the same pixel; the delta matches the
    /// independent ramp+siting oracle (0.25 chroma-texel × ramp step, decoded
    /// through the 709 Cr→R coefficient).
    func testLeftSitingShiftsChromaSamplePosition() throws {
        // Narrow width so a steep-per-texel ramp stays UNCLAMPED across all 8
        // chroma columns (a saturated ramp is flat → no siting signal).
        let w = 16, h = 8
        let compositor = try MetalCompositor(device: try device(), width: w, height: h)
        let step = 32.0                 // Cr bytes per chroma texel (cols 20…244)
        let base = 20.0
        func luma(_ x: Int, _ y: Int) -> UInt8 { 180 }               // constant
        func chroma(_ cx: Int, _ cy: Int) -> (UInt8, UInt8) {
            let cr = min(max(base + Double(cx) * step, 0), 255)      // horizontal ramp
            return (128, UInt8(cr))                                  // Cb neutral
        }
        let centered = try makeYUV(w: w, h: h, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                                   leftSited: false, lumaAt: luma, chromaAt: chroma)
        let left = try makeYUV(w: w, h: h, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                               leftSited: true, lumaAt: luma, chromaAt: chroma)
        let sid = SourceID("yuv")
        let scene = Scene(name: "s", layers: [Layer(sourceID: sid)])
        let pc = try compositor.composite(frames: [sid: centered], scene: scene, pts: HouseClock.now())
        let pl = try compositor.composite(frames: [sid: left], scene: scene, pts: HouseClock.now())

        // Probe an interior pixel (ramp is exactly linear there).
        let px = 8, py = h / 2
        let rc = readBGRA(pc, x: px, y: py).r
        let rl = readBGRA(pl, x: px, y: py).r
        // Oracle: left samples 0.25 chroma-texel further along the ramp → +0.25·step
        // in Cr; R = y + 1.5748·(Cr/255). ΔR(byte) = 1.5748 · 0.25·step.
        let expectedDelta = 1.5748 * 0.25 * step   // ≈ 15.7
        XCTAssertGreaterThan(rl - rc, 6,
                             "left siting did not shift chroma to the right (ΔR=\(rl - rc))")
        XCTAssertLessThanOrEqual(abs(Double(rl - rc) - expectedDelta), 6,
                                 "left-vs-centered ΔR=\(rl - rc), oracle ≈\(expectedDelta)")
    }
}
