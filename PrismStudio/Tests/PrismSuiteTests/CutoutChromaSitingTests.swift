import CoreVideo
import Foundation
import Metal
import XCTest

import PrismCore
import PrismSources
import PrismVision

/// F11 regression — **GPU and CPU cutout YUV decode must agree on SPATIAL
/// frames**, both matching an INDEPENDENT oracle.
///
/// The defect: the GPU path (`BackgroundEffect` / `VisionShaders.sample_yuv`)
/// bilinearly upsamples the half-resolution chroma plane at each output pixel's
/// centre, while the CPU fallback (`PresenterCutout.convertedToBGRA`) used
/// vImage, which sites/upsamples chroma differently. On non-uniform 420f/420v
/// frames the two diverged by up to ~160 codes. Solid-colour tests hid it, and
/// the old GPU-vs-CPU test used the GPU converter as its own "reference".
///
/// These build **spatially-varying** 420f AND 420v fixtures (chroma gradients so
/// bilinear ≠ nearest) and compare BOTH decoders against a closed-form oracle
/// written HERE (the shared contract: clamp-to-edge bilinear chroma at pixel
/// centres + the shader's BT.709 matrix) — never the GPU converter. With the fix
/// both agree with the oracle within a couple of codes.
final class CutoutChromaSitingTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    private func rawBGRA(_ buf: CVPixelBuffer, x: Int, y: Int) -> (b: Int, g: Int, r: Int, a: Int) {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let p = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self) + y * bpr + x * 4
        return (Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3]))
    }

    /// A spatially-varying biplanar 420 frame: a luma gradient plus INDEPENDENT
    /// Cb/Cr gradients on the half-res chroma plane (so chroma varies texel-to-
    /// texel and bilinear upsampling genuinely differs from nearest).
    private func makeSpatialYUV(_ w: Int, _ h: Int, fullRange: Bool) throws -> CVPixelBuffer {
        let fmt = fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: fmt, minimumBufferCount: 1)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }

        let yBase = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!.assumingMemoryBound(to: UInt8.self)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
        let lW = CVPixelBufferGetWidthOfPlane(buf, 0), lH = CVPixelBufferGetHeightOfPlane(buf, 0)
        for yy in 0..<lH {
            let row = yBase + yy * yRow
            for xx in 0..<lW {
                let v = 40.0 + 170.0 * Double(xx) / Double(max(lW - 1, 1)) + 30.0 * Double(yy) / Double(max(lH - 1, 1))
                row[xx] = UInt8(min(max(v, 0), 255).rounded())
            }
        }
        let cBase = CVPixelBufferGetBaseAddressOfPlane(buf, 1)!.assumingMemoryBound(to: UInt8.self)
        let cRow = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
        let cW = CVPixelBufferGetWidthOfPlane(buf, 1), cH = CVPixelBufferGetHeightOfPlane(buf, 1)
        for cy in 0..<cH {
            let row = cBase + cy * cRow
            for cx in 0..<cW {
                // Cb ramps across x, Cr ramps across y → a real 2-D chroma field.
                let cb = 60.0 + 150.0 * Double(cx) / Double(max(cW - 1, 1))
                let cr = 70.0 + 150.0 * Double(cy) / Double(max(cH - 1, 1))
                row[cx * 2]     = UInt8(min(max(cb, 0), 255).rounded())
                row[cx * 2 + 1] = UInt8(min(max(cr, 0), 255).rounded())
            }
        }
        return buf
    }

    /// A full-resolution `OneComponent8` matte of all-255 (person everywhere), so
    /// `.remove` / the CPU composite emit exactly the decoded colour at alpha 1 —
    /// isolating the YUV decode.
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

    /// The INDEPENDENT oracle (authored here, not the GPU/CPU converters): the
    /// shared contract — clamp-to-edge BILINEAR chroma at the pixel centre +
    /// hand-coded BT.709. Reads the fixture's discrete planes directly.
    private func oracleBGRA(_ yuv: CVPixelBuffer, x: Int, y: Int, w: Int, h: Int, fullRange: Bool) -> (b: Int, g: Int, r: Int) {
        CVPixelBufferLockBaseAddress(yuv, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(yuv, .readOnly) }
        let yBase = CVPixelBufferGetBaseAddressOfPlane(yuv, 0)!.assumingMemoryBound(to: UInt8.self)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(yuv, 0)
        let cBase = CVPixelBufferGetBaseAddressOfPlane(yuv, 1)!.assumingMemoryBound(to: UInt8.self)
        let cRow = CVPixelBufferGetBytesPerRowOfPlane(yuv, 1)
        let cW = CVPixelBufferGetWidthOfPlane(yuv, 1), cH = CVPixelBufferGetHeightOfPlane(yuv, 1)

        let yn = Double(yBase[y * yRow + x]) / 255.0

        func clampIdx(_ v: Int, _ hi: Int) -> Int { min(max(v, 0), hi) }
        let fx = (Double(x) + 0.5) / Double(w) * Double(cW) - 0.5
        let fy = (Double(y) + 0.5) / Double(h) * Double(cH) - 0.5
        let xf = floor(fx), yf = floor(fy)
        let tx = fx - xf, ty = fy - yf
        let cx0 = clampIdx(Int(xf), cW - 1), cx1 = clampIdx(Int(xf) + 1, cW - 1)
        let cy0 = clampIdx(Int(yf), cH - 1), cy1 = clampIdx(Int(yf) + 1, cH - 1)
        func chroma(_ off: Int) -> Double {
            let s00 = Double((cBase + cy0 * cRow)[cx0 * 2 + off])
            let s10 = Double((cBase + cy0 * cRow)[cx1 * 2 + off])
            let s01 = Double((cBase + cy1 * cRow)[cx0 * 2 + off])
            let s11 = Double((cBase + cy1 * cRow)[cx1 * 2 + off])
            let top = s00 * (1 - tx) + s10 * tx
            let bot = s01 * (1 - tx) + s11 * tx
            return top * (1 - ty) + bot * ty
        }
        let cx = chroma(0) / 255.0 - 128.0 / 255.0
        let cyv = chroma(1) / 255.0 - 128.0 / 255.0
        let r: Double, g: Double, b: Double
        if fullRange {
            r = yn + 1.5748 * cyv; g = yn - 0.1873 * cx - 0.4681 * cyv; b = yn + 1.8556 * cx
        } else {
            let yv = 1.1644 * (yn - 16.0 / 255.0)
            r = yv + 1.7927 * cyv; g = yv - 0.2132 * cx - 0.5329 * cyv; b = yv + 2.1124 * cx
        }
        func b8(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return (b8(b), b8(g), b8(r))
    }

    func testGPUAndCPUCutoutMatchOracleOnSpatialFrames() throws {
        let W = 320, H = 240
        let dev = try device()
        let effect = try BackgroundEffect(device: dev)   // GPU YUV decode
        let cutout = PresenterCutout()                    // CPU fallback YUV decode

        for (label, fullRange) in [("420f", true), ("420v", false)] {
            let yuv = try makeSpatialYUV(W, H, fullRange: fullRange)
            let matte = try fullPersonMatte(W, H)
            let frame = VideoFrame(pixelBuffer: yuv, pts: HouseClock.now(), source: SourceID("f11.\(label)"))

            // GPU: .remove over an all-person matte → decoded colour at alpha 1.
            let gpuOut = try effect.apply(
                frame: frame,
                matte: SegmentationMatte(pixelBuffer: matte, pts: frame.pts, source: frame.source),
                mode: .remove)

            // CPU fallback: same all-person matte, transparent bg → decoded colour.
            let cpuOut = try cutout.cpuFallbackComposite(frame: frame, matte: matte)

            var gpuMax = 0, cpuMax = 0
            var gpuSum = 0.0, cpuSum = 0.0, n = 0
            // Sample a grid, deliberately including chroma-transition columns/rows.
            for y in stride(from: 2, to: H - 2, by: 7) {
                for x in stride(from: 2, to: W - 2, by: 7) {
                    let exp = oracleBGRA(yuv, x: x, y: y, w: W, h: H, fullRange: fullRange)
                    let g = rawBGRA(gpuOut.pixelBuffer, x: x, y: y)
                    let c = rawBGRA(cpuOut.pixelBuffer, x: x, y: y)
                    let gd = max(abs(g.b - exp.b), max(abs(g.g - exp.g), abs(g.r - exp.r)))
                    let cd = max(abs(c.b - exp.b), max(abs(c.g - exp.g), abs(c.r - exp.r)))
                    gpuMax = max(gpuMax, gd); cpuMax = max(cpuMax, cd)
                    gpuSum += Double(gd); cpuSum += Double(cd); n += 1
                    XCTAssertEqual(g.a, 255, "F11 \(label) GPU must be opaque")
                    XCTAssertEqual(c.a, 255, "F11 \(label) CPU must be opaque")
                }
            }
            let gpuMean = gpuSum / Double(n), cpuMean = cpuSum / Double(n)
            print("F11 \(label): GPU vs oracle max=\(gpuMax) mean=\(String(format: "%.3f", gpuMean)); " +
                  "CPU vs oracle max=\(cpuMax) mean=\(String(format: "%.3f", cpuMean)) over \(n) pts")

            // Both decoders must track the independent oracle within a few codes
            // (the old vImage CPU path diverged by up to ~160 here).
            XCTAssertLessThanOrEqual(gpuMax, 3, "F11 \(label): GPU decode diverges from the oracle (max \(gpuMax))")
            XCTAssertLessThanOrEqual(cpuMax, 3, "F11 \(label): CPU decode diverges from the oracle (max \(cpuMax))")
            XCTAssertLessThan(gpuMean, 1.5, "F11 \(label): GPU mean delta \(gpuMean) too high")
            XCTAssertLessThan(cpuMean, 1.5, "F11 \(label): CPU mean delta \(cpuMean) too high")
        }
    }
}
