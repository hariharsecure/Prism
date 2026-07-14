import CoreGraphics
import CoreMedia
import CoreVideo
import Metal
import XCTest

import PrismColor
import PrismCompositor
import PrismCore
import PrismVision

/// sol wave-11 — the two remaining extended-range (EDR) color defects sol found:
///
///  - **#4** ChromaKey and LumaKey still `saturate` a KEPT foreground, so a name-only
///    `extendedSRGB` 1.5 kept-foreground was crushed to 1.0 → composited @25% opacity
///    to **756** instead of the correct **937** (extended-sRGB EOTF(1.5)=2.537 · 0.25 →
///    HLG). Grade / relight / bg-remove were fixed in wave-10; the two KEY stages were
///    missed. The FIX carries > 1 through the kept foreground while leaving the key
///    MATTE/threshold decision (computed on the clamped value) unchanged.
///
///  - **#5** legal SIGNED extended components were decoded with a ONE-SIDED lower clamp
///    (values < 0 → 0). An extended-range colorspace carries legal NEGATIVE components
///    (wide-gamut colors outside the 709 triangle). Measured:
///    `extendedSRGB(-0.2,0.5,0.5)` → oracle (430,707,720) but compositor (469,708,720) /
///    staged (500,709,720); `extendedLinearSRGB(-0.05,0.5,0.5)` → oracle (656,876,888)
///    but compositor (695,878,888). The FIX decodes with the ODD-SYMMETRIC transfer —
///    `sign(x)·EOTF(|x|)` for extended sRGB/709, signed pass-through for extendedLinear —
///    in the compositor AND the mirrored grade/relight/Vision stages, so the negative
///    survives into the linear blend (the final encode still clamps the DISPLAY output).
///
/// ── INDEPENDENCE OF THE ORACLE ──────────────────────────────────────────────
/// Every expected value is computed HERE, in Double, from the PUBLISHED formulas
/// (sRGB EOTF, BT.2100 HLG OETF, the 709→Rec.2020 primary matrix) — never by calling
/// the shader — and each target also asserts the measured pixel is FAR from the specific
/// pre-fix wrong value (the pre-clamp 756, or the one-sided lower-clamp 469/500/695).
final class SolWave11ColorEDRTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    // MARK: - Independent from-spec references (Double) --------------------------

    private func srgbEOTF(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    /// sol wave-11 #5: the ODD-SYMMETRIC extended-sRGB EOTF — sign(x)·EOTF(|x|).
    private func srgbEOTFSigned(_ v: Double) -> Double { v >= 0 ? srgbEOTF(v) : -srgbEOTF(-v) }
    private func hlgOETF(_ e: Double) -> Double {
        let e = max(e, 0)
        return e <= 1.0 / 12.0 ? (3 * e).squareRoot()
                               : 0.17883277 * log(12 * e - 0.28466892) + 0.55991073
    }
    private func sat(_ v: Double) -> Double { min(max(v, 0), 1) }
    private func code(_ v: Double) -> Int { Int((sat(v) * 1023).rounded()) }

    /// sRGB(709) linear → Rec.2020 linear (rows sum to 1; handles negatives — the
    /// compositor's exact rotate==1 matrix).
    private func rot709to2020(_ c: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(0.627404 * c.x + 0.329283 * c.y + 0.043313 * c.z,
              0.069097 * c.x + 0.919540 * c.y + 0.011362 * c.z,
              0.016391 * c.x + 0.088013 * c.y + 0.895595 * c.z)
    }

    /// Compositor oracle for a name-only single opaque layer at full opacity: decode
    /// (odd-symmetric sRGB, or signed pass-through for linear) → rotate → HLG → code.
    private func oracleComposite(_ c: SIMD3<Double>, linear: Bool) -> (b: Int, g: Int, r: Int) {
        let lin = linear ? c : SIMD3(srgbEOTFSigned(c.x), srgbEOTFSigned(c.y), srgbEOTFSigned(c.z))
        let rot = rot709to2020(lin)
        return (code(hlgOETF(rot.z)), code(hlgOETF(rot.y)), code(hlgOETF(rot.x)))
    }

    // MARK: - Fixtures ----------------------------------------------------------

    /// A `64RGBAHalf` buffer with per-channel (r,g,b) float values, α=1, carrying ONLY a
    /// named CGColorSpace attachment (a name-only extended-range HDR frame).
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

    private func makeForegroundMatte(_ w: Int, _ h: Int) throws -> SegmentationMatte {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_OneComponent8,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &pb)
        guard let pb else { throw XCTSkip("no matte buffer") }
        CVPixelBufferLockBaseAddress(pb, [])
        let db = CVPixelBufferGetBaseAddress(pb)!
        for y in 0..<h { memset(db + y * CVPixelBufferGetBytesPerRow(pb), 255, w) }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return SegmentationMatte(pixelBuffer: pb, pts: HouseClock.now(), source: SourceID("m"))
    }

    private func makeFlatDepth(_ w: Int, _ h: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_OneComponent8,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &pb)
        guard let pb else { throw XCTSkip("no depth buffer") }
        CVPixelBufferLockBaseAddress(pb, [])
        let db = CVPixelBufferGetBaseAddress(pb)!
        for y in 0..<h { memset(db + y * CVPixelBufferGetBytesPerRow(pb), 128, w) }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
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

    private func read10(_ frame: VideoFrame, x: Int, y: Int) -> (b: Int, g: Int, r: Int) {
        let buf = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let word = CVPixelBufferGetBaseAddress(buf)!
            .advanced(by: y * CVPixelBufferGetBytesPerRow(buf) + x * 4)
            .loadUnaligned(as: UInt32.self)
        return (Int(word & 0x3FF), Int((word >> 10) & 0x3FF), Int((word >> 20) & 0x3FF))
    }

    // MARK: - Compositor probes --------------------------------------------------

    private func compositeSingle(_ buf: CVPixelBuffer, w: Int, h: Int) throws -> (b: Int, g: Int, r: Int) {
        let compositor = try MetalCompositor(device: try device(), width: w, height: h, colorMode: .hdr)
        let sid = SourceID("s")
        let scene = Scene(name: "s", layers: [Layer(sourceID: sid, premultipliedAlpha: false)])
        let prog = try compositor.composite(frames: [sid: VideoFrame(pixelBuffer: buf, pts: HouseClock.now(), source: sid)],
                                            scene: scene, pts: HouseClock.now())
        XCTAssertEqual(prog.pixelFormat, kCVPixelFormatType_ARGB2101010LEPacked)
        return read10(prog, x: w / 2, y: h / 2)
    }

    /// Composite a PREMULTIPLIED-alpha frame (a keyer output) over black at `opacity`.
    private func compositePremultOver(top: CVPixelBuffer, opacity: Float, bottom: CVPixelBuffer,
                                      w: Int, h: Int) throws -> (b: Int, g: Int, r: Int) {
        let compositor = try MetalCompositor(device: try device(), width: w, height: h, colorMode: .hdr)
        let bID = SourceID("bottom"), tID = SourceID("top")
        let scene = Scene(name: "over", layers: [
            Layer(sourceID: bID, zIndex: 0),
            Layer(sourceID: tID, opacity: opacity, zIndex: 1, premultipliedAlpha: true),
        ])
        let now = HouseClock.now()
        let prog = try compositor.composite(
            frames: [bID: VideoFrame(pixelBuffer: bottom, pts: now, source: bID),
                     tID: VideoFrame(pixelBuffer: top, pts: now, source: tID)],
            scene: scene, pts: now)
        return read10(prog, x: w / 2, y: h / 2)
    }

    // MARK: - #4 ChromaKey / LumaKey: EDR kept-foreground not pre-clamped ---------

    /// A name-only `extendedSRGB` 1.5 NEUTRAL gray is a KEPT foreground of a green key
    /// (chroma far from green → α=1); the pre-fix `saturate` crushed the kept color to
    /// 1.0. The kept foreground must carry 1.5 (downstream @25% → 937, not 756).
    func testChromaKeyExtendedSRGBKeptForegroundCarriesEDR() throws {
        let w = 32, h = 32
        let proc = try ChromaKeyProcessor(device: try device())
        let src = try makeHalfRGB(w, h, r: 1.5, g: 1.5, b: 1.5, csName: CGColorSpace.extendedSRGB)
        let keyed = try proc.apply(frame: VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("c")),
                                   key: .greenScreen)
        XCTAssertEqual(keyed.pixelFormat, kCVPixelFormatType_64RGBAHalf)
        // Direct: kept foreground (α=1) carries 1.5, not the pre-clamp 1.0.
        XCTAssertLessThanOrEqual(abs(readHalf(keyed, x: w / 2, y: h / 2, ch: 1) - 1.5), 0.03,
                                 "chroma key kept extendedSRGB 1.5 crushed (pre-clamp bug)")
        XCTAssertGreaterThan(abs(readHalf(keyed, x: w / 2, y: h / 2, ch: 1) - 1.0), 0.3, "matches pre-clamp 1.0")
        // Downstream: composited @25% reaches the EDR oracle 937, not the pre-clamp 756.
        let correct = code(hlgOETF(srgbEOTF(1.5) * 0.25))   // ≈937
        let bug = code(hlgOETF(srgbEOTF(1.0) * 0.25))       // ≈756
        XCTAssertGreaterThan(abs(correct - bug), 120, "oracle discriminator weak")
        let got = try compositePremultOver(top: keyed.pixelBuffer, opacity: 0.25,
                                           bottom: try makeBGRA(w, h, r: 0, g: 0, b: 0), w: w, h: h)
        for ch in [got.b, got.g, got.r] {
            XCTAssertLessThanOrEqual(abs(ch - correct), 14, "chroma key downstream \(ch) ≠ EDR oracle \(correct)")
            XCTAssertGreaterThan(abs(ch - bug), 60, "chroma key downstream \(ch) matches pre-clamp bug \(bug)")
        }
    }

    /// LumaKey with a `darkerThan(0.2)` band keeps a bright (luma 1.0) foreground; the
    /// pre-fix `saturate` crushed its extendedSRGB 1.5 to 1.0. Must carry 1.5 → 937.
    func testLumaKeyExtendedSRGBKeptForegroundCarriesEDR() throws {
        let w = 32, h = 32
        let proc = try LumaKeyProcessor(device: try device())
        let src = try makeHalfRGB(w, h, r: 1.5, g: 1.5, b: 1.5, csName: CGColorSpace.extendedSRGB)
        let keyed = try proc.apply(frame: VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("l")),
                                   key: .darkerThan(0.2))
        XCTAssertLessThanOrEqual(abs(readHalf(keyed, x: w / 2, y: h / 2, ch: 1) - 1.5), 0.03,
                                 "luma key kept extendedSRGB 1.5 crushed (pre-clamp bug)")
        let correct = code(hlgOETF(srgbEOTF(1.5) * 0.25))   // ≈937
        let bug = code(hlgOETF(srgbEOTF(1.0) * 0.25))       // ≈756
        let got = try compositePremultOver(top: keyed.pixelBuffer, opacity: 0.25,
                                           bottom: try makeBGRA(w, h, r: 0, g: 0, b: 0), w: w, h: h)
        for ch in [got.b, got.g, got.r] {
            XCTAssertLessThanOrEqual(abs(ch - correct), 14, "luma key downstream \(ch) ≠ EDR oracle \(correct)")
            XCTAssertGreaterThan(abs(ch - bug), 60, "luma key downstream \(ch) matches pre-clamp bug \(bug)")
        }
    }

    /// The key DECISION (what's keyed vs kept) is UNCHANGED by the EDR carry: a green
    /// pixel still keys to transparent (α≈0) on the chroma key, and a dark pixel still
    /// keys to transparent on the `darkerThan` luma key.
    func testKeyDecisionUnchanged() throws {
        let w = 16, h = 16
        // Chroma: an extendedSRGB green (matches the key) → keyed transparent.
        let ck = try ChromaKeyProcessor(device: try device())
        let green = try makeHalfRGB(w, h, r: 0, g: 1, b: 0, csName: CGColorSpace.extendedSRGB)
        let ckOut = try ck.apply(frame: VideoFrame(pixelBuffer: green, pts: HouseClock.now(), source: SourceID("cg")),
                                 key: .greenScreen)
        XCTAssertLessThan(readHalf(ckOut, x: w / 2, y: h / 2, ch: 3), 0.1, "green not keyed (decision changed)")
        // Luma: an extendedSRGB dark (luma 0.1, inside the darkerThan band) → keyed.
        let lk = try LumaKeyProcessor(device: try device())
        let dark = try makeHalfRGB(w, h, r: 0.1, g: 0.1, b: 0.1, csName: CGColorSpace.extendedSRGB)
        let lkOut = try lk.apply(frame: VideoFrame(pixelBuffer: dark, pts: HouseClock.now(), source: SourceID("ld")),
                                 key: .darkerThan(0.2))
        XCTAssertLessThan(readHalf(lkOut, x: w / 2, y: h / 2, ch: 3), 0.1, "dark not keyed (decision changed)")
    }

    /// CONTROL: an in-range (bounded) source is byte-identical — a plain `sRGB` 0.5
    /// neutral kept foreground carries exactly 0.5 through both keys (no EDR carry).
    func testKeysInRangeByteIdentical() throws {
        let w = 16, h = 16
        let src = { try self.makeHalfRGB(w, h, r: 0.5, g: 0.5, b: 0.5, csName: CGColorSpace.extendedSRGB) }
        let ck = try ChromaKeyProcessor(device: try device()).apply(
            frame: VideoFrame(pixelBuffer: try src(), pts: HouseClock.now(), source: SourceID("c")), key: .greenScreen)
        XCTAssertLessThanOrEqual(abs(readHalf(ck, x: w / 2, y: h / 2, ch: 1) - 0.5), 0.02, "chroma in-range 0.5 changed")
        let lk = try LumaKeyProcessor(device: try device()).apply(
            frame: VideoFrame(pixelBuffer: try src(), pts: HouseClock.now(), source: SourceID("l")), key: .darkerThan(0.2))
        XCTAssertLessThanOrEqual(abs(readHalf(lk, x: w / 2, y: h / 2, ch: 1) - 0.5), 0.02, "luma in-range 0.5 changed")
    }

    // MARK: - #5 compositor: signed extended components odd-symmetric decode ------

    /// `extendedSRGB(-0.2,0.5,0.5)` composites to the spec (430,707,720) — the negative
    /// red survives the odd-symmetric decode into the linear blend — NOT the one-sided
    /// lower-clamp (469,…) the toe-linear sRGB EOTF produced.
    func testCompositorSignedExtendedSRGB() throws {
        let w = 32, h = 32
        let got = try compositeSingle(try makeHalfRGB(w, h, r: -0.2, g: 0.5, b: 0.5, csName: CGColorSpace.extendedSRGB), w: w, h: h)
        let want = oracleComposite(SIMD3(-0.2, 0.5, 0.5), linear: false)   // ≈(430,707,720)
        XCTAssertLessThanOrEqual(abs(got.r - want.r), 6, "signed extendedSRGB R \(got.r) ≠ \(want.r)")
        XCTAssertLessThanOrEqual(abs(got.g - want.g), 6, "G \(got.g) ≠ \(want.g)")
        XCTAssertLessThanOrEqual(abs(got.b - want.b), 6, "B \(got.b) ≠ \(want.b)")
        XCTAssertGreaterThan(abs(got.r - 469), 20, "R matches the one-sided lower-clamp bug 469")
    }

    /// `extendedLinearSRGB(-0.05,0.5,0.5)` → spec (656,876,888): the negative linear
    /// component passes SIGNED through (was `max→0`, clamping to 695).
    func testCompositorSignedExtendedLinearSRGB() throws {
        let w = 32, h = 32
        let got = try compositeSingle(try makeHalfRGB(w, h, r: -0.05, g: 0.5, b: 0.5, csName: CGColorSpace.extendedLinearSRGB), w: w, h: h)
        let want = oracleComposite(SIMD3(-0.05, 0.5, 0.5), linear: true)   // ≈(656,876,888)
        XCTAssertLessThanOrEqual(abs(got.r - want.r), 6, "signed extendedLinearSRGB R \(got.r) ≠ \(want.r)")
        XCTAssertLessThanOrEqual(abs(got.g - want.g), 6, "G \(got.g) ≠ \(want.g)")
        XCTAssertLessThanOrEqual(abs(got.b - want.b), 6, "B \(got.b) ≠ \(want.b)")
        XCTAssertGreaterThan(abs(got.r - 695), 20, "R matches the one-sided lower-clamp bug 695")
    }

    /// CONTROL: a BOUNDED `sRGB` (non-extended) name with a negative component STILL
    /// lower-clamps (byte-identical) — the signed carry is gated on the extended name.
    /// `sRGB(-0.2,…)` saturates the red to 0 → composites ≈500, distinct from 430.
    func testCompositorBoundedSRGBNegativeStillClamps() throws {
        let w = 32, h = 32
        let got = try compositeSingle(try makeHalfRGB(w, h, r: -0.2, g: 0.5, b: 0.5, csName: CGColorSpace.sRGB), w: w, h: h)
        let clampedR = code(hlgOETF(rot709to2020(SIMD3(0, srgbEOTF(0.5), srgbEOTF(0.5))).x))   // ≈500
        XCTAssertLessThanOrEqual(abs(got.r - clampedR), 8, "bounded sRGB negative must clamp to 0 (R \(got.r) ≠ \(clampedR))")
        XCTAssertGreaterThan(abs(got.r - 430), 40, "bounded sRGB negative leaked the signed carry (matches extended 430)")
    }

    // MARK: - #5 grade / relight / bg-remove mirror the odd-symmetric decode ------

    /// An IDENTITY grade of `extendedSRGB(-0.2,0.5,0.5)` round-trips the SIGNED value
    /// (the v0 curve + odd-symmetric wheels are exact inverses), so the graded output
    /// composites to the SAME (430,…) — the pre-fix `max→0` crushed it to the staged 500.
    func testGradeSignedExtendedSRGBMirrors() throws {
        let w = 32, h = 32
        let g = try ColorProcessor(device: try device()).process(
            VideoFrame(pixelBuffer: try makeHalfRGB(w, h, r: -0.2, g: 0.5, b: 0.5, csName: CGColorSpace.extendedSRGB),
                       pts: HouseClock.now(), source: SourceID("g")), grade: ColorGrade(), lut: nil)
        // Direct: the graded coded red carries the negative (round-trip ≈ -0.2), not 0.
        XCTAssertLessThanOrEqual(abs(readHalf(g, x: w / 2, y: h / 2, ch: 0) - (-0.2)), 0.03, "grade did not round-trip signed red")
        XCTAssertGreaterThan(abs(readHalf(g, x: w / 2, y: h / 2, ch: 0) - 0.0), 0.1, "grade crushed signed red to 0")
        let got = try compositeSingle(g.pixelBuffer, w: w, h: h)
        let want = oracleComposite(SIMD3(-0.2, 0.5, 0.5), linear: false)   // ≈(430,707,720)
        XCTAssertLessThanOrEqual(abs(got.r - want.r), 8, "grade→composite signed R \(got.r) ≠ \(want.r)")
        XCTAssertGreaterThan(abs(got.r - 500), 40, "grade→composite R matches the staged lower-clamp bug 500")
    }

    /// An IDENTITY relight (ambient 1, no lights, flat depth) of the same source mirrors
    /// the compositor — the signed red survives the shade → composites to (430,…).
    func testRelightSignedExtendedSRGBMirrors() throws {
        let w = 32, h = 32
        let relight = try RelightProcessor(device: try device())
        relight.ambient = 1; relight.depthScale = 0
        let r = try relight.process(
            frame: VideoFrame(pixelBuffer: try makeHalfRGB(w, h, r: -0.2, g: 0.5, b: 0.5, csName: CGColorSpace.extendedSRGB),
                              pts: HouseClock.now(), source: SourceID("r")),
            depth: try makeFlatDepth(w, h), lights: [])
        let got = try compositeSingle(r.pixelBuffer, w: w, h: h)
        let want = oracleComposite(SIMD3(-0.2, 0.5, 0.5), linear: false)
        XCTAssertLessThanOrEqual(abs(got.r - want.r), 8, "relight→composite signed R \(got.r) ≠ \(want.r)")
        XCTAssertGreaterThan(abs(got.r - 500), 40, "relight→composite R matches the staged lower-clamp bug 500")
    }

    /// A background-REMOVE (all-foreground matte, identity) of the same source mirrors
    /// the compositor — the coded signed red passes through the matte blend → (430,…).
    func testBackgroundRemoveSignedExtendedSRGBMirrors() throws {
        let w = 32, h = 32
        let v = try BackgroundEffect(device: try device()).apply(
            frame: VideoFrame(pixelBuffer: try makeHalfRGB(w, h, r: -0.2, g: 0.5, b: 0.5, csName: CGColorSpace.extendedSRGB),
                              pts: HouseClock.now(), source: SourceID("v")),
            matte: try makeForegroundMatte(w, h), mode: .remove)
        let got = try compositeSingle(v.pixelBuffer, w: w, h: h)
        let want = oracleComposite(SIMD3(-0.2, 0.5, 0.5), linear: false)
        XCTAssertLessThanOrEqual(abs(got.r - want.r), 8, "bg-remove→composite signed R \(got.r) ≠ \(want.r)")
        XCTAssertGreaterThan(abs(got.r - 500), 40, "bg-remove→composite R matches the staged lower-clamp bug 500")
    }
}
