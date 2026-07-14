import CoreVideo
import Foundation
import Metal
import XCTest

import PrismCore
import PrismSources

/// sol #3 finding 2 — `PresenterCutout`'s CPU recovery path (the no-Metal /
/// GPU-fault fallback, `decodeBiplanarYUVToBGRA`) hardcoded centered BT.709
/// regardless of the source's tags. So a GPU-fault recovery of a BT.601 / BT.2020
/// (or left-sited) source took a hue shift + half-pixel chroma misalignment that
/// the GPU path (post finding-9) does NOT — the fallback silently produced a
/// different, wrong color.
///
/// Oracle is INDEPENDENT: the YCbCr→RGB inverse is re-derived from the ITU luma
/// weights (Kr/Kb), NOT copied from the decode's coefficients.
final class CutoutCPUMatrixSitingTests: XCTestCase {

    private func makeYUV(w: Int, h: Int, matrix: CFString, leftSited: Bool,
                         lumaAt: (Int, Int) -> UInt8,
                         chromaAt: (Int, Int) -> (UInt8, UInt8)) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: w, height: h,
                                       pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                       minimumBufferCount: 1)
        let buffer = try pool.makeBuffer()
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

    /// CPU recovery of a 601-tagged source matches the independent 601 oracle and
    /// differs from a 709 decode.
    func testCPUFallbackHonors601Matrix() throws {
        let w = 64, h = 64
        let cutout = PresenterCutout()
        let yV: UInt8 = 130, cbV: UInt8 = 90, crV: UInt8 = 230 // red-ish
        func luma(_ x: Int, _ y: Int) -> UInt8 { yV }
        func chroma(_ cx: Int, _ cy: Int) -> (UInt8, UInt8) { (cbV, crV) }

        let f601 = try makeYUV(w: w, h: h, matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                               leftSited: false, lumaAt: luma, chromaAt: chroma)
        let f709 = try makeYUV(w: w, h: h, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                               leftSited: false, lumaAt: luma, chromaAt: chroma)
        let matte = try fullPersonMatte(w, h)
        let out601 = try cutout.cpuFallbackComposite(frame: f601, matte: matte)
        let out709 = try cutout.cpuFallbackComposite(frame: f709, matte: matte)

        let got601 = readBGRA(out601.pixelBuffer, x: w / 2, y: h / 2)
        let got709 = readBGRA(out709.pixelBuffer, x: w / 2, y: h / 2)
        let want601 = oracleRGB(y: yV, cb: cbV, cr: crV, kr: 0.299, kb: 0.114)

        XCTAssertLessThanOrEqual(abs(got601.r - want601.r), 3, "CPU 601 R \(got601) vs \(want601)")
        XCTAssertLessThanOrEqual(abs(got601.g - want601.g), 3, "CPU 601 G \(got601) vs \(want601)")
        XCTAssertLessThanOrEqual(abs(got601.b - want601.b), 3, "CPU 601 B \(got601) vs \(want601)")
        let diff = abs(got601.g - got709.g) + abs(got601.b - got709.b)
        XCTAssertGreaterThan(diff, 4, "CPU recovery decoded 601 and 709 identically (\(got601) vs \(got709))")
    }

    /// CPU recovery of a 2020-tagged source matches the independent 2020 oracle.
    func testCPUFallbackHonors2020Matrix() throws {
        let w = 32, h = 32
        let cutout = PresenterCutout()
        let yV: UInt8 = 120, cbV: UInt8 = 100, crV: UInt8 = 210
        let f = try makeYUV(w: w, h: h, matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
                            leftSited: false, lumaAt: { _, _ in yV }, chromaAt: { _, _ in (cbV, crV) })
        let out = try cutout.cpuFallbackComposite(frame: f, matte: try fullPersonMatte(w, h))
        let got = readBGRA(out.pixelBuffer, x: w / 2, y: h / 2)
        let want = oracleRGB(y: yV, cb: cbV, cr: crV, kr: 0.2627, kb: 0.0593)
        XCTAssertLessThanOrEqual(abs(got.g - want.g), 3, "CPU 2020 G \(got) vs \(want)")
        XCTAssertLessThanOrEqual(abs(got.b - want.b), 3, "CPU 2020 B \(got) vs \(want)")
    }

    /// CPU recovery honors LEFT horizontal siting — a left-sited source samples
    /// chroma half a luma pixel right of centered → with a horizontal Cr ramp the
    /// reconstructed red shifts right.
    func testCPUFallbackLeftSitingShiftsChroma() throws {
        let w = 16, h = 8
        let cutout = PresenterCutout()
        let step = 30.0, base = 20.0
        func luma(_ x: Int, _ y: Int) -> UInt8 { 180 }
        func chroma(_ cx: Int, _ cy: Int) -> (UInt8, UInt8) {
            (128, UInt8(min(max(base + Double(cx) * step, 0), 255)))
        }
        let centered = try makeYUV(w: w, h: h, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                                   leftSited: false, lumaAt: luma, chromaAt: chroma)
        let left = try makeYUV(w: w, h: h, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                               leftSited: true, lumaAt: luma, chromaAt: chroma)
        let matte = try fullPersonMatte(w, h)
        let pc = try cutout.cpuFallbackComposite(frame: centered, matte: matte)
        let pl = try cutout.cpuFallbackComposite(frame: left, matte: matte)
        let px = 8, py = h / 2
        let rc = readBGRA(pc.pixelBuffer, x: px, y: py).r
        let rl = readBGRA(pl.pixelBuffer, x: px, y: py).r
        XCTAssertGreaterThan(rl - rc, 5, "CPU left siting did not shift chroma right (ΔR=\(rl - rc))")
    }
}
