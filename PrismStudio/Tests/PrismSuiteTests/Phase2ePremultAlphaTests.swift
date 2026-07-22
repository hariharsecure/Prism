import CoreMedia
import CoreVideo
import Metal
import XCTest

import PrismColor
import PrismCore
import PrismSources
import PrismVision

/// Roadmap Phase 2e — the premultiplied-alpha class fixed across the stages missed
/// when it was fixed elsewhere (grade / background-remove / chroma+luma key already
/// un-premultiply; see `SolGradeBgAlphaTests` / `SolKeyStraightColorMatteTests`).
/// Each fix is proved on a synthetic ALPHA-BEARING source against an INDEPENDENT
/// from-spec Double oracle, with the pre-fix WRONG value pinned so the test proves
/// the fix (not a tautology). Opaque controls stay BYTE-IDENTICAL.
///
///  1. RELIGHT (`prism_relight_bgra`) shaded the PREMULTIPLIED rgb as if straight.
///     Because the Blinn specular ADDS a constant in linear light (litLin = lin·diffuse
///     + specular), shading the α-darkened premult rgb ≠ shading straight then ·α.
///     FIX: un-premultiply → shade → re-premultiply (the grade pattern).
///  2. BACKGROUND BLUR/REPLACE (`prism_bg_bgra`) forced output α = 1.0, so an
///     alpha-bearing source became OPAQUE under blur/replace. FIX: preserve source α
///     (the remove path already intersects m·srcA).
///  3. PRESENTER-CUTOUT CPU FALLBACK (`cpuReferenceComposite`) emitted the matte α
///     alone (all-person matte → α255) instead of intersecting the source's OWN
///     coverage. FIX: out.α = srcA·matteα (the GPU `.remove` path already does m·srcA).
final class Phase2ePremultAlphaTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }
    private func sat(_ v: Double) -> Double { min(max(v, 0), 1) }

    // MARK: - Fixtures ----------------------------------------------------------

    /// A `64RGBAHalf` holding an already-**premultiplied** pixel (stored rgb = straight·α,
    /// stored α = α), untagged → decoded as Rec.709/sRGB (2.2-power v0), non-extended.
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

    /// A flat (constant-zero) single-channel depth map, IOSurface-backed — so the
    /// relight screen-space normal is exactly (0,0,−1) everywhere (central differences
    /// vanish) and every pixel shades identically. Depth 0 → surface point P.z = 0.
    private func makeFlatDepth(_ w: Int, _ h: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_OneComponent32Float,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else {
            throw XCTSkip("could not allocate OneComponent32Float depth")
        }
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        for row in 0..<h {
            let p = (base + row * bpr).assumingMemoryBound(to: Float.self)
            for col in 0..<w { p[col] = 0 }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    /// An OPAQUE (α=255) 32BGRA fill.
    private func makeBGRA(_ w: Int, _ h: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_32BGRA)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<h { for col in 0..<w {
            let p = base + row * bpr + col * 4
            p[0] = b; p[1] = g; p[2] = r; p[3] = a
        } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    /// A OneComponent8 matte filled with `value` (255 = all-person, 0 = all-background).
    private func makeMatte(_ w: Int, _ h: Int, value: UInt8, pts: CMTime) throws -> SegmentationMatte {
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_OneComponent8, minimumBufferCount: 1)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<h { for col in 0..<w { base[row * bpr + col] = value } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return SegmentationMatte(pixelBuffer: buf, pts: pts, source: SourceID("m"))
    }

    /// A OneComponent8 CVPixelBuffer matte (for the PresenterCutout API, which takes a raw buffer).
    private func makeMatteBuffer(_ w: Int, _ h: Int, value: UInt8) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_OneComponent8, minimumBufferCount: 1)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<h { for col in 0..<w { base[row * bpr + col] = value } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    // MARK: - Read helpers ------------------------------------------------------

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

    // MARK: - 1. RELIGHT un-premultiply -----------------------------------------

    /// From-spec relight shade of ONE white light with specular, at the read pixel's
    /// exact uv over a FLAT depth (normal (0,0,−1)). Mirrors `relight_rgb` in Double:
    /// decode 2.2 → litLin = lin·diffuse + specular → encode 1/2.2 → saturate.
    /// Returns the shaded (encoded, pre-premultiply) value.
    private func relightShade(straight: Double, uv: (Double, Double),
                              lightPos: (Double, Double, Double),
                              intensity: Double, attenK: Double,
                              specStrength: Double, shininess: Double, ambient: Double) -> Double {
        let n = (0.0, 0.0, -1.0), V = (0.0, 0.0, -1.0)
        let P = (uv.0, uv.1, 0.0)                                     // depth 0
        let Lv = (lightPos.0 - P.0, lightPos.1 - P.1, lightPos.2 - P.2)
        let dist = max((Lv.0 * Lv.0 + Lv.1 * Lv.1 + Lv.2 * Lv.2).squareRoot(), 1e-4)
        let L = (Lv.0 / dist, Lv.1 / dist, Lv.2 / dist)
        let atten = intensity / (1.0 + attenK * dist * dist)
        let ndl = max(n.0 * L.0 + n.1 * L.1 + n.2 * L.2, 0.0)
        let diffuse = ambient + atten * ndl                          // white light color = 1
        var spec = 0.0
        if ndl > 0, specStrength > 0 {
            let Hr = (L.0 + V.0, L.1 + V.1, L.2 + V.2)
            let hl = (Hr.0 * Hr.0 + Hr.1 * Hr.1 + Hr.2 * Hr.2).squareRoot()
            let Hn = (Hr.0 / hl, Hr.1 / hl, Hr.2 / hl)
            let ndh = max(n.0 * Hn.0 + n.1 * Hn.1 + n.2 * Hn.2, 0.0)
            spec = specStrength * atten * pow(ndh, max(shininess, 1.0))
        }
        let lin = pow(sat(straight), 2.2)
        return sat(pow(max(lin * diffuse + spec, 0.0), 1.0 / 2.2))
    }

    /// A valid alpha-bearing overlay (straight 0.75 / α0.25) relit by one specular
    /// light MUST shade the STRAIGHT color then re-premultiply by α. Pre-fix shaded the
    /// premult 0.1875 as straight and wrote α unchanged → a grossly wrong stored value.
    func testRelightPartialAlphaUnpremultiplied() throws {
        let w = 16, h = 16
        let alpha = 0.25, straight = 0.75
        let rx = w / 2, ry = h / 2
        let uv = ((Double(rx) + 0.5) / Double(w), (Double(ry) + 0.5) / Double(h))  // (0.53125, 0.53125)

        let src = try makePremultHalf(w, h, straightR: straight, straightG: straight, straightB: straight, alpha: alpha)
        let depth = try makeFlatDepth(w, h)
        // One white light directly in front of the read pixel (so ndl = ndh = 1) with a
        // specular term → the shade is AFFINE (not linear) in the input, so premult vs
        // straight actually diverge.
        let light = VirtualLight(position: SIMD3(Float(uv.0), Float(uv.1), -1.0),
                                 color: SIMD3(1, 1, 1), intensity: 1.0,
                                 specular: 0.5, shininess: 32, attenuation: 2.0)
        let proc = try RelightProcessor(device: try device())
        proc.ambient = 0.35
        proc.depthScale = 1.0
        let out = try proc.process(frame: VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("rl")),
                                   depth: depth, lights: [light])
        XCTAssertEqual(out.pixelFormat, kCVPixelFormatType_64RGBAHalf)

        let shadeStraight = relightShade(straight: straight, uv: uv, lightPos: (uv.0, uv.1, -1.0),
                                         intensity: 1.0, attenK: 2.0, specStrength: 0.5, shininess: 32, ambient: 0.35)
        let correct = shadeStraight * alpha                          // ≈ 0.1873
        let bug = relightShade(straight: straight * alpha, uv: uv, lightPos: (uv.0, uv.1, -1.0),
                               intensity: 1.0, attenK: 2.0, specStrength: 0.5, shininess: 32, ambient: 0.35) // ≈ 0.4631
        XCTAssertGreaterThan(abs(correct - bug), 0.05, "relight oracle discriminator weak (\(correct) vs \(bug))")

        let gotG = readHalf(out, x: rx, y: ry, ch: 1)                // premultiplied stored green
        print("[relight] straight=\(straight) α=\(alpha): measured=\(gotG) correct≈\(correct) pre-fix-bug≈\(bug)")
        XCTAssertLessThanOrEqual(abs(gotG - correct), 0.01,
                                 "partial-α relight \(gotG) ≠ straight-shaded·α \(correct)")
        XCTAssertGreaterThan(abs(gotG - bug), 0.05,
                             "partial-α relight \(gotG) matches the pre-fix shade-the-premult bug \(bug)")
        // α carried through unchanged.
        XCTAssertLessThanOrEqual(abs(readHalf(out, x: rx, y: ry, ch: 3) - alpha), 0.005, "relight dropped α")
    }

    /// Opaque control: un-premultiply is a divide-by-one no-op, so an α=1 source shades
    /// identically to before (the straight math the partial-α case recovers ÷ α).
    func testRelightOpaqueControlByteIdentical() throws {
        let w = 16, h = 16
        let straight = 0.75
        let rx = w / 2, ry = h / 2
        let uv = ((Double(rx) + 0.5) / Double(w), (Double(ry) + 0.5) / Double(h))
        let depth = try makeFlatDepth(w, h)
        let light = VirtualLight(position: SIMD3(Float(uv.0), Float(uv.1), -1.0),
                                 color: SIMD3(1, 1, 1), intensity: 1.0,
                                 specular: 0.5, shininess: 32, attenuation: 2.0)
        let proc = try RelightProcessor(device: try device())
        proc.ambient = 0.35; proc.depthScale = 1.0

        let opaque = try makePremultHalf(w, h, straightR: straight, straightG: straight, straightB: straight, alpha: 1.0)
        let opaqueOut = try proc.process(frame: VideoFrame(pixelBuffer: opaque, pts: HouseClock.now(), source: SourceID("op")),
                                         depth: depth, lights: [light])
        let opaqueG = readHalf(opaqueOut, x: rx, y: ry, ch: 1)

        let premult = try makePremultHalf(w, h, straightR: straight, straightG: straight, straightB: straight, alpha: 0.25)
        let premultOut = try proc.process(frame: VideoFrame(pixelBuffer: premult, pts: HouseClock.now(), source: SourceID("pm")),
                                          depth: depth, lights: [light])
        let recoveredStraight = readHalf(premultOut, x: rx, y: ry, ch: 1) / 0.25

        let expected = relightShade(straight: straight, uv: uv, lightPos: (uv.0, uv.1, -1.0),
                                    intensity: 1.0, attenK: 2.0, specStrength: 0.5, shininess: 32, ambient: 0.35)
        XCTAssertLessThanOrEqual(abs(opaqueG - expected), 0.01, "opaque relight \(opaqueG) ≠ oracle \(expected)")
        XCTAssertLessThanOrEqual(abs(recoveredStraight - opaqueG), 0.01,
                                 "un-premult relight \(recoveredStraight) ≠ opaque relight \(opaqueG)")
    }

    // MARK: - 2. BACKGROUND BLUR / REPLACE preserve source α --------------------

    /// BLUR over an alpha-bearing source (α0.25), all-person matte (m=1 → sharp
    /// foreground): output must KEEP α = srcA = 0.25 with the premult rgb intact.
    /// Pre-fix forced α = 1.0 (an alpha-bearing source became opaque under blur).
    func testBlurPreservesSourceAlpha() throws {
        let w = 16, h = 16
        let pts = HouseClock.now()
        let sr = 0.6, sg = 0.4, sb = 0.2, alpha = 0.25
        let src = try makePremultHalf(w, h, straightR: sr, straightG: sg, straightB: sb, alpha: alpha)
        let matte = try makeMatte(w, h, value: 255, pts: pts)             // all-person → m=1
        let out = try BackgroundEffect(device: try device()).apply(
            frame: VideoFrame(pixelBuffer: src, pts: pts, source: SourceID("bl")), matte: matte, mode: .blur(radius: 8))
        XCTAssertEqual(out.pixelFormat, kCVPixelFormatType_64RGBAHalf)

        let gotA = readHalf(out, x: w / 2, y: h / 2, ch: 3)
        print("[blur] α measured=\(gotA) correct=\(alpha) pre-fix-bug=1.0")
        XCTAssertLessThanOrEqual(abs(gotA - alpha), 0.01, "blur did not preserve source α (got \(gotA))")
        XCTAssertGreaterThan(abs(gotA - 1.0), 0.5, "α matches the pre-fix force-opaque bug 1.0")
        // Sharp foreground (m=1) → premult rgb unchanged (straight·α).
        XCTAssertLessThanOrEqual(abs(readHalf(out, x: w / 2, y: h / 2, ch: 0) - sr * alpha), 0.01, "blur premult r wrong")
    }

    /// REPLACE over an alpha-bearing source (α0.25), all-background matte (m=0 → whole
    /// frame is the replacement color): output α must be srcA = 0.25 and the replacement
    /// rgb PREMULTIPLIED by srcA. Pre-fix forced α = 1.0 and left rgb straight (opaque).
    /// The premult rgb is cross-checked against the SAME replace on an OPAQUE control
    /// (α=1) — independent of the sRGB→coded color conversion the shader does.
    func testReplacePreservesSourceAlpha() throws {
        let w = 16, h = 16
        let pts = HouseClock.now()
        let replace = SIMD3<Float>(0.6, 0.6, 0.6)
        let be = try BackgroundEffect(device: try device())

        // Opaque control (α=1): output rgb == converted replace color C, α==1.
        let opaque = try makePremultHalf(w, h, straightR: 0.3, straightG: 0.3, straightB: 0.3, alpha: 1.0)
        let opaqueOut = try be.apply(frame: VideoFrame(pixelBuffer: opaque, pts: pts, source: SourceID("ropq")),
                                     matte: try makeMatte(w, h, value: 0, pts: pts), mode: .replace(color: replace))
        let cR = readHalf(opaqueOut, x: w / 2, y: h / 2, ch: 0)
        XCTAssertLessThanOrEqual(abs(readHalf(opaqueOut, x: w / 2, y: h / 2, ch: 3) - 1.0), 0.01, "opaque replace α not 1")

        // Alpha-bearing (α=0.25): output rgb == C·0.25, α == 0.25.
        let alpha = 0.25
        let src = try makePremultHalf(w, h, straightR: 0.3, straightG: 0.3, straightB: 0.3, alpha: alpha)
        let out = try be.apply(frame: VideoFrame(pixelBuffer: src, pts: pts, source: SourceID("rep")),
                               matte: try makeMatte(w, h, value: 0, pts: pts), mode: .replace(color: replace))
        let gotA = readHalf(out, x: w / 2, y: h / 2, ch: 3)
        let gotR = readHalf(out, x: w / 2, y: h / 2, ch: 0)
        print("[replace] α measured=\(gotA) correct=\(alpha) pre-fix=1.0 | premultR=\(gotR) correct≈\(cR * alpha) pre-fix≈\(cR)")
        XCTAssertLessThanOrEqual(abs(gotA - alpha), 0.01, "replace did not preserve source α (got \(gotA))")
        XCTAssertGreaterThan(abs(gotA - 1.0), 0.5, "α matches the pre-fix force-opaque bug 1.0")
        // rgb is now premultiplied by srcA (≈ C·0.25), NOT the straight color C (pre-fix).
        XCTAssertLessThanOrEqual(abs(gotR - cR * alpha), 0.01, "replace rgb not premultiplied by source α (got \(gotR))")
        XCTAssertGreaterThan(abs(gotR - cR), 0.1, "replace rgb matches the pre-fix straight (un-premultiplied) color")
    }

    /// Opaque BGRA control: blur & replace stay α=255 (byte-identical to before).
    func testBlurReplaceOpaqueControl() throws {
        let w = 16, h = 16
        let pts = HouseClock.now()
        let be = try BackgroundEffect(device: try device())
        let opaque = try makeBGRA(w, h, r: 200, g: 100, b: 50)
        let blurOut = try be.apply(frame: VideoFrame(pixelBuffer: opaque, pts: pts, source: SourceID("obl")),
                                   matte: try makeMatte(w, h, value: 255, pts: pts), mode: .blur(radius: 8))
        XCTAssertGreaterThanOrEqual(readBGRA(blurOut, x: w / 2, y: h / 2).a, 254, "opaque blur α not kept")
        let repOut = try be.apply(frame: VideoFrame(pixelBuffer: try makeBGRA(w, h, r: 200, g: 100, b: 50),
                                                    pts: pts, source: SourceID("orp")),
                                  matte: try makeMatte(w, h, value: 0, pts: pts),
                                  mode: .replace(color: SIMD3(0.6, 0.6, 0.6)))
        XCTAssertGreaterThanOrEqual(readBGRA(repOut, x: w / 2, y: h / 2).a, 254, "opaque replace α not kept")
    }

    // MARK: - 3. PRESENTER-CUTOUT CPU FALLBACK intersects source α --------------

    /// The CPU reference/fallback compositor (Metal-unavailable + GPU-fault recovery)
    /// must INTERSECT the matte with the source's OWN coverage α. An alpha-bearing
    /// premultiplied BGRA (straight color, α byte 64) under an all-person matte must
    /// come back at α ≈ 64 — pre-fix it emitted the matte α alone → α255 (opaque).
    func testCutoutCPUFallbackIntersectsSourceAlpha() throws {
        let w = 32, h = 32
        // Premultiplied BGRA: straight (r0.6,g0.4,b0.2) · srcA0.25 → bytes, α byte 64.
        let srcA = 64                                                     // 0.2510 · 255
        let ir = UInt8((0.6 * Double(srcA)).rounded())                    // premult r
        let ig = UInt8((0.4 * Double(srcA)).rounded())
        let ib = UInt8((0.2 * Double(srcA)).rounded())
        let frame = VideoFrame(pixelBuffer: try makeBGRA(w, h, r: ir, g: ig, b: ib, a: UInt8(srcA)),
                               pts: HouseClock.now(), source: SourceID("cpa"))
        let matte = try makeMatteBuffer(w, h, value: 255)                 // all-person → matte α = 1

        let cutout = PresenterCutout(options: .init(background: .transparent, feather: 0))
        let out = try cutout.cpuReferenceComposite(frame: frame, matte: matte)
        let px = readBGRA(out, x: w / 2, y: h / 2)
        print("[cutout-cpu] measured α=\(px.a) correct=\(srcA) pre-fix-bug=255 | rgb=\(px.r),\(px.g),\(px.b)")

        // Oracle: out.α = srcA · matteα = 64 · 1 = 64 (pre-fix wrote matteα·255 = 255).
        XCTAssertEqual(px.a, srcA, accuracy: 1, "CPU fallback did not intersect source coverage (got α \(px.a))")
        XCTAssertGreaterThan(abs(px.a - 255), 150, "α matches the pre-fix all-opaque bug 255")
        // Premult rgb (in.rgb · matteα, matteα=1) is unchanged — still consistent with α.
        XCTAssertEqual(px.r, Int(ir), accuracy: 1, "premult r changed")
        XCTAssertEqual(px.g, Int(ig), accuracy: 1)
        XCTAssertEqual(px.b, Int(ib), accuracy: 1)
    }

    /// Opaque control: an α=255 source under an all-person matte still comes back α=255
    /// (ia·a == a·255 → byte-identical) and a removed (matte 0) region → α0.
    func testCutoutCPUOpaqueControlByteIdentical() throws {
        let w = 32, h = 32
        let cutout = PresenterCutout(options: .init(background: .transparent, feather: 0))
        let opaque = VideoFrame(pixelBuffer: try makeBGRA(w, h, r: 200, g: 100, b: 50),
                                pts: HouseClock.now(), source: SourceID("copq"))
        let kept = try cutout.cpuReferenceComposite(frame: opaque, matte: try makeMatteBuffer(w, h, value: 255))
        let keptPx = readBGRA(kept, x: w / 2, y: h / 2)
        XCTAssertEqual(keptPx.a, 255, "opaque person region must stay α255")
        XCTAssertEqual(keptPx.r, 200, accuracy: 1, "opaque foreground color lost")

        let removed = try cutout.cpuReferenceComposite(
            frame: VideoFrame(pixelBuffer: try makeBGRA(w, h, r: 200, g: 100, b: 50), pts: HouseClock.now(), source: SourceID("crm")),
            matte: try makeMatteBuffer(w, h, value: 0))
        XCTAssertLessThanOrEqual(readBGRA(removed, x: w / 2, y: h / 2).a, 1, "opaque removed region not transparent")
    }
}
