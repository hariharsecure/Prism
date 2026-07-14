import CoreGraphics
import CoreMedia
import CoreVideo
import Metal
import XCTest

import PrismColor
import PrismCore

/// sol #11 #2 (MEDIUM, pre-existing) — the chroma-key and luma-key matte/threshold
/// were computed from the **premultiplied** `src.rgb` instead of the **straight**
/// (un-premultiplied) color, so an ordinary alpha-bearing movie/image keyed on the
/// wrong color:
///
///  - a premultiplied pure green at α=0.1 (premult rgb (0,0.1,0)) has a chroma FAR
///    from the green key → it was KEPT (output α≈0.0999756) when its true color IS
///    green and it should be keyed OUT (α≈0).
///  - a premultiplied white at α=0.1 (premult rgb (0.1,0.1,0.1)) under
///    `darkerThan(0.2)` has luma 0.1 → it was keyed OUT (output α 0) when its true
///    color is white (luma 1) and it should be KEPT (α 0.1).
///
/// The FIX un-premultiplies (rgb/α, guard α==0) BEFORE the chroma-distance / luma-band
/// math, so the key decides on the source's TRUE color; the output stays correctly
/// premultiplied by keyAlpha·α. Opaque (α==1) and YUV inputs divide by one → no-op
/// (byte-identical).
///
/// ── INDEPENDENT ORACLE ──────────────────────────────────────────────────────
/// The key DECISION is recomputed HERE in Double from the STRAIGHT color (premult/α),
/// using the published BT.709 chroma coords + the ChromaKey/LumaKey preset params —
/// never by calling the shader — and each assertion also pins the measured α FAR from
/// the specific pre-fix wrong value (0.0999756 kept-green / 0 keyed-white).
final class SolKeyStraightColorMatteTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    // MARK: - Fixtures ----------------------------------------------------------

    /// A 64RGBAHalf buffer holding an already-**premultiplied** pixel: the stored rgb is
    /// `straight · alpha`, the stored alpha is `alpha` (a valid premultiplied-alpha frame,
    /// exactly what an ordinary alpha-bearing movie/image decodes to).
    private func makePremultHalf(_ w: Int, _ h: Int,
                                 straightR: Double, straightG: Double, straightB: Double,
                                 alpha: Double) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_64RGBAHalf,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else {
            throw XCTSkip("could not allocate 64RGBAHalf")
        }
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let px: [Float16] = [Float16(straightR * alpha), Float16(straightG * alpha),
                             Float16(straightB * alpha), Float16(alpha)]
        for row in 0..<h {
            let p = (base + row * bpr).assumingMemoryBound(to: Float16.self)
            for col in 0..<w { for k in 0..<4 { p[col * 4 + k] = px[k] } }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    /// A name-only extendedSRGB 64RGBAHalf with per-channel straight values, α=1 (the
    /// wave-11 EDR fixture — opaque, so un-premult is a divide-by-one no-op).
    private func makeHalfRGB(_ w: Int, _ h: Int, r: Double, g: Double, b: Double, csName: CFString) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_64RGBAHalf,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else {
            throw XCTSkip("could not allocate 64RGBAHalf")
        }
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let px: [Float16] = [Float16(r), Float16(g), Float16(b), Float16(1)]
        for row in 0..<h {
            let p = (base + row * bpr).assumingMemoryBound(to: Float16.self)
            for col in 0..<w { for k in 0..<4 { p[col * 4 + k] = px[k] } }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        guard let cs = CGColorSpace(name: csName) else { throw XCTSkip("colorspace \(csName) unavailable") }
        CVBufferSetAttachment(pb, kCVImageBufferCGColorSpaceKey, cs, .shouldPropagate)
        return pb
    }

    /// An OPAQUE 32BGRA buffer (α=255) with a single (r,g,b) fill.
    private func makeBGRA(_ w: Int, _ h: Int, r: UInt8, g: UInt8, b: UInt8) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_32BGRA)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<h { for col in 0..<w {
            let p = base + row * bpr + col * 4
            p[0] = b; p[1] = g; p[2] = r; p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    // MARK: - Read helpers ------------------------------------------------------

    private func readHalfA(_ frame: VideoFrame, x: Int, y: Int) -> Double { readHalf(frame, x: x, y: y, ch: 3) }
    private func readHalf(_ frame: VideoFrame, x: Int, y: Int, ch: Int) -> Double {
        let buf = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(buf)!
            .advanced(by: y * CVPixelBufferGetBytesPerRow(buf) + x * 8)
            .assumingMemoryBound(to: Float16.self)
        return Double(p[ch])
    }

    private func readBGRA(_ frame: VideoFrame, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let buf = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            + y * CVPixelBufferGetBytesPerRow(buf) + x * 4
        return (Int(p[2]), Int(p[1]), Int(p[0]), Int(p[3]))
    }

    // MARK: - Independent Double oracle (STRAIGHT-color key decision) ------------

    /// BT.709 chroma coords (luma-independent) — the plane the greenscreen keys live in.
    private func cbcr(_ r: Double, _ g: Double, _ b: Double) -> (cb: Double, cr: Double) {
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return ((b - y) / 1.8556, (r - y) / 1.5748)
    }
    private func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / (e1 - e0), 0), 1); return t * t * (3 - 2 * t)
    }
    /// keyAlpha for a STRAIGHT color under greenScreen (key (0,1,0), sim 0.4, smooth 0.1).
    private func chromaKeyAlphaStraight(_ r: Double, _ g: Double, _ b: Double) -> Double {
        let sr = min(max(r, 0), 1), sg = min(max(g, 0), 1), sb = min(max(b, 0), 1)
        let p = cbcr(sr, sg, sb), k = cbcr(0, 1, 0)
        let dist = ((p.cb - k.cb) * (p.cb - k.cb) + (p.cr - k.cr) * (p.cr - k.cr)).squareRoot()
        return smoothstep(0.4, 0.5, dist)
    }
    /// keyAlpha for a STRAIGHT color under darkerThan(0.2) (band [-0.01,0.2], smooth 0.08).
    private func lumaKeyAlphaStraight(_ r: Double, _ g: Double, _ b: Double) -> Double {
        let y = 0.2126 * min(max(r, 0), 1) + 0.7152 * min(max(g, 0), 1) + 0.0722 * min(max(b, 0), 1)
        let s = 0.08
        let lowEdge = smoothstep(-0.01 - s, -0.01, y)
        let highEdge = 1.0 - smoothstep(0.2, 0.2 + s, y)
        let inside = lowEdge * highEdge
        return 1.0 - inside // not inverted
    }

    // MARK: - #2 chroma key keys an alpha-bearing source on its STRAIGHT color -----

    /// sol's exact case: a premultiplied pure GREEN at α=0.1 (premult rgb (0,0.1,0)) IS
    /// green → must be keyed OUT (output α≈0). Pre-fix the premult chroma was far from the
    /// key → kept at α≈0.0999756.
    func testChromaKeyPremultGreenKeyedOnStraightColor() throws {
        let w = 16, h = 16
        let src = try makePremultHalf(w, h, straightR: 0, straightG: 1, straightB: 0, alpha: 0.1)
        let out = try ChromaKeyProcessor(device: try device()).apply(
            frame: VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("cg")), key: .greenScreen)
        XCTAssertEqual(out.pixelFormat, kCVPixelFormatType_64RGBAHalf)
        // Oracle: straight color (0,1,0) → keyAlpha 0 → output α = keyAlpha·srcA = 0.
        let oracleKeyAlpha = chromaKeyAlphaStraight(0, 1, 0)
        XCTAssertLessThan(oracleKeyAlpha, 0.01, "oracle: straight green must key out")
        let gotA = readHalfA(out, x: w / 2, y: h / 2)
        XCTAssertLessThanOrEqual(gotA, 0.01, "premult green not keyed out (got α \(gotA), premult-matte bug)")
        XCTAssertGreaterThan(abs(gotA - 0.0999756), 0.05, "α matches the pre-fix premult-matte bug 0.0999756")
    }

    // MARK: - #2 luma key keys an alpha-bearing source on its STRAIGHT color -------

    /// sol's exact case: a premultiplied WHITE at α=0.1 (premult rgb (0.1,0.1,0.1)) under
    /// `darkerThan(0.2)` — its TRUE color is white (luma 1), NOT dark → must be KEPT
    /// (output α 0.1). Pre-fix the premult luma 0.1 fell inside the band → keyed OUT (α 0).
    func testLumaKeyPremultWhiteKeptOnStraightColor() throws {
        let w = 16, h = 16
        let src = try makePremultHalf(w, h, straightR: 1, straightG: 1, straightB: 1, alpha: 0.1)
        let out = try LumaKeyProcessor(device: try device()).apply(
            frame: VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("lw")), key: .darkerThan(0.2))
        // Oracle: straight white (1,1,1) luma 1 outside the dark band → keyAlpha 1 → α = 0.1.
        let oracleKeyAlpha = lumaKeyAlphaStraight(1, 1, 1)
        XCTAssertGreaterThan(oracleKeyAlpha, 0.99, "oracle: straight white must be kept")
        let gotA = readHalfA(out, x: w / 2, y: h / 2)
        XCTAssertLessThanOrEqual(abs(gotA - 0.1), 0.01, "premult white not kept (got α \(gotA), premult-matte bug)")
        XCTAssertGreaterThan(gotA, 0.05, "α matches the pre-fix premult-matte bug 0 (keyed out)")
        // Kept foreground carries its true (straight) color: premult rgb = straight·α = 0.1.
        XCTAssertLessThanOrEqual(abs(readHalf(out, x: w / 2, y: h / 2, ch: 1) - 0.1), 0.01, "kept white premult rgb wrong")
    }

    /// A partially-transparent DARK premult pixel: straight color is dark → still keyed OUT
    /// (the decision now follows the straight color, both pre- and post-fix agree here).
    func testLumaKeyPremultDarkStillKeyed() throws {
        let w = 16, h = 16
        let src = try makePremultHalf(w, h, straightR: 0.1, straightG: 0.1, straightB: 0.1, alpha: 0.5)
        let out = try LumaKeyProcessor(device: try device()).apply(
            frame: VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("ld")), key: .darkerThan(0.2))
        XCTAssertLessThan(lumaKeyAlphaStraight(0.1, 0.1, 0.1), 0.01, "oracle: straight dark keys out")
        XCTAssertLessThanOrEqual(readHalfA(out, x: w / 2, y: h / 2), 0.01, "straight-dark premult pixel not keyed out")
    }

    // MARK: - OPAQUE control: unchanged (divide-by-one no-op) ---------------------

    /// OPAQUE (α=255) BGRA: green keyed OUT, red KEPT — byte-identical to before (the
    /// un-premultiply is a divide-by-one no-op). This is the pre-existing self-test case.
    func testOpaqueControlUnchanged() throws {
        let w = 16, h = 16
        let ck = try ChromaKeyProcessor(device: try device())
        let greenOut = try ck.apply(frame: VideoFrame(pixelBuffer: try makeBGRA(w, h, r: 0, g: 255, b: 0),
                                                      pts: HouseClock.now(), source: SourceID("og")), key: .greenScreen)
        let g = readBGRA(greenOut, x: w / 2, y: h / 2)
        XCTAssertLessThanOrEqual(g.a, 2, "opaque green not keyed out: \(g)")
        let redOut = try ck.apply(frame: VideoFrame(pixelBuffer: try makeBGRA(w, h, r: 255, g: 0, b: 0),
                                                    pts: HouseClock.now(), source: SourceID("or")), key: .greenScreen)
        let r = readBGRA(redOut, x: w / 2, y: h / 2)
        XCTAssertGreaterThanOrEqual(r.a, 253, "opaque red not kept: \(r)")
        XCTAssertGreaterThanOrEqual(r.r, 250, "opaque red color lost: \(r)")
    }

    // MARK: - wave-11 EDR case unchanged (opaque extendedSRGB 1.5 kept-fg) --------

    /// The wave-11 EDR carry is preserved: an OPAQUE (α=1) extendedSRGB 1.5 kept foreground
    /// still carries 1.5 through both keys (un-premult by 1 = no-op, EDR path untouched).
    func testWave11EDRUnchanged() throws {
        let w = 16, h = 16
        let ck = try ChromaKeyProcessor(device: try device()).apply(
            frame: VideoFrame(pixelBuffer: try makeHalfRGB(w, h, r: 1.5, g: 1.5, b: 1.5, csName: CGColorSpace.extendedSRGB),
                              pts: HouseClock.now(), source: SourceID("ce")), key: .greenScreen)
        XCTAssertLessThanOrEqual(abs(readHalf(ck, x: w / 2, y: h / 2, ch: 1) - 1.5), 0.03, "chroma EDR 1.5 carry regressed")
        let lk = try LumaKeyProcessor(device: try device()).apply(
            frame: VideoFrame(pixelBuffer: try makeHalfRGB(w, h, r: 1.5, g: 1.5, b: 1.5, csName: CGColorSpace.extendedSRGB),
                              pts: HouseClock.now(), source: SourceID("le")), key: .darkerThan(0.2))
        XCTAssertLessThanOrEqual(abs(readHalf(lk, x: w / 2, y: h / 2, ch: 1) - 1.5), 0.03, "luma EDR 1.5 carry regressed")
    }
}
