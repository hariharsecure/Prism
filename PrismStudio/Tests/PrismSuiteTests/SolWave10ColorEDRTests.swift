import CoreGraphics
import CoreMedia
import CoreVideo
import Metal
import XCTest

import PrismColor
import PrismCompositor
import PrismCore
import PrismVision

/// sol wave-10 — the extended-range no-clamp that reached the wave-9 compositor but
/// NOT the other color stages, plus `genericRGBLinear`'s wrong primaries.
///
///  - **#3** a NONLINEAR extended-range source (`extendedSRGB` / `extendedITUR_2020`
///    / `extendedDisplayP3`) carries legal > 1 highlights. The wave-9 compositor
///    fix carries them, but the PrismColor grade + relight shaders treated ONLY the
///    Linear transfer as extended (`ColorShaders` ~190/~360) and the PrismVision
///    background-removal shader ALWAYS saturated (`VisionShaders` ~209) — so an
///    `extendedSRGB` 1.5 was pre-clamped to 1.0 upstream (stage output 1.0; composited
///    @25% opacity that is **756**) even though the compositor now handles it (the
///    unclamped 1.5 composites to **937** = extended-sRGB EOTF(1.5)=2.537 · 0.25 → HLG).
///  - **#4** `genericRGBLinear` mapped to Rec.709 primaries, so a saturated red
///    composited **(935,466,227)** [709→2020] instead of the Core-Image-color-managed
///    **(942,530,230)** [Generic-RGB→2020] — a ~64-code green error. `linearSRGB` (a
///    genuine Rec.709 gamut) is unchanged.
///
/// ── INDEPENDENCE OF THE ORACLE ──────────────────────────────────────────────
/// Every expected value is computed HERE, in Double, from the PUBLISHED formulas
/// (sRGB EOTF, BT.2100 HLG OETF, and the Generic-RGB / 709 → Rec.2020 primary
/// matrices derived from the published chromaticities) — never by calling the
/// shader — and each target also asserts the measured pixel is FAR from the specific
/// pre-fix wrong value (the pre-clamp 1.0 / 756, or the 709-primaries red).
final class SolWave10ColorEDRTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    // MARK: - Independent from-spec references (Double) --------------------------

    private func srgbEOTF(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    private func hlgOETF(_ e: Double) -> Double {
        let e = max(e, 0)
        return e <= 1.0 / 12.0 ? (3 * e).squareRoot()
                               : 0.17883277 * log(12 * e - 0.28466892) + 0.55991073
    }
    private func sat(_ v: Double) -> Double { min(max(v, 0), 1) }
    private func code(_ v: Double) -> Int { Int((sat(v) * 1023).rounded()) }

    /// sRGB(709) linear → Rec.2020 linear (rows sum to 1 — neutral preserved).
    private func rot709to2020(_ c: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(0.627404 * c.x + 0.329283 * c.y + 0.043313 * c.z,
              0.069097 * c.x + 0.919540 * c.y + 0.011362 * c.z,
              0.016391 * c.x + 0.088013 * c.y + 0.895595 * c.z)
    }
    /// Generic-RGB linear → Rec.2020 linear (the compositor's exact rotate==3 matrix,
    /// derived from the classic Apple Generic-RGB chromaticities). Rows sum to 1.
    private func rotGenericTo2020(_ c: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(0.649557 * c.x + 0.295451 * c.y + 0.054992 * c.z,
              0.088655 * c.x + 0.869899 * c.y + 0.041446 * c.z,
              0.016927 * c.x + 0.081712 * c.y + 0.901360 * c.z)
    }

    // MARK: - Fixtures ----------------------------------------------------------

    /// A neutral `64RGBAHalf` buffer at float value `v` (all channels), α=1, carrying
    /// ONLY a named CGColorSpace attachment (a name-only extended-range HDR frame).
    private func makeHalfNameOnly(_ w: Int, _ h: Int, v: Double, csName: CFString) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_64RGBAHalf,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else {
            throw XCTSkip("could not allocate 64RGBAHalf")
        }
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let px: [Float16] = [Float16(v), Float16(v), Float16(v), Float16(1)]
        for row in 0..<h {
            let p = (base + row * bpr).assumingMemoryBound(to: Float16.self)
            for col in 0..<w { for k in 0..<4 { p[col * 4 + k] = px[k] } }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        guard let cs = CGColorSpace(name: csName) else { throw XCTSkip("colorspace \(csName) unavailable") }
        CVBufferSetAttachment(pb, kCVImageBufferCGColorSpaceKey, cs, .shouldPropagate)
        return pb
    }

    /// A name-only `32BGRA` buffer of one solid color.
    private func makeBGRANameOnly(_ w: Int, _ h: Int, r: UInt8, g: UInt8, b: UInt8, csName: CFString) throws -> CVPixelBuffer {
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
        guard let cs = CGColorSpace(name: csName) else { throw XCTSkip("colorspace \(csName) unavailable") }
        CVBufferSetAttachment(buf, kCVImageBufferCGColorSpaceKey, cs, .shouldPropagate)
        return buf
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

    /// An all-foreground (person = 255) OneComponent8 matte, so a background-remove
    /// is an identity pass (output rgb = source rgb, α = 1).
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

    private func readHalfG(_ frame: VideoFrame, x: Int, y: Int) -> Double {
        let buf = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(buf)!
            .advanced(by: y * CVPixelBufferGetBytesPerRow(buf) + x * 8)
            .assumingMemoryBound(to: Float16.self)
        return Double(p[1])
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

    private func compositeOver(top: CVPixelBuffer, topOpacity: Float, bottom: CVPixelBuffer,
                               w: Int, h: Int) throws -> (b: Int, g: Int, r: Int) {
        let compositor = try MetalCompositor(device: try device(), width: w, height: h, colorMode: .hdr)
        let bID = SourceID("bottom"), tID = SourceID("top")
        let scene = Scene(name: "over", layers: [
            Layer(sourceID: bID, zIndex: 0),
            Layer(sourceID: tID, opacity: topOpacity, zIndex: 1, premultipliedAlpha: false),
        ])
        let now = HouseClock.now()
        let prog = try compositor.composite(
            frames: [bID: VideoFrame(pixelBuffer: bottom, pts: now, source: bID),
                     tID: VideoFrame(pixelBuffer: top, pts: now, source: tID)],
            scene: scene, pts: now)
        return read10(prog, x: w / 2, y: h / 2)
    }

    // MARK: - #3 grade: nonlinear extended-range highlight not pre-clamped -------

    /// A name-only `extendedSRGB` half-float 1.5 through an IDENTITY grade must carry
    /// the > 1 highlight (the 2.2 approx round-trips 1.5 → 1.5), NOT crush it to 1.0.
    /// The pre-fix `saturate` (Linear-only `ext`) clamped 1.5 → 1.0 before the math.
    func testGradeExtendedSRGBHighlightNotPreClamped() throws {
        let w = 16, h = 16
        let proc = try ColorProcessor(device: try device())
        let src = try makeHalfNameOnly(w, h, v: 1.5, csName: CGColorSpace.extendedSRGB)
        let out = try proc.process(VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("g")),
                                   grade: ColorGrade(), lut: nil)
        XCTAssertEqual(out.pixelFormat, kCVPixelFormatType_64RGBAHalf)
        let got = readHalfG(out, x: w / 2, y: h / 2)
        XCTAssertLessThanOrEqual(abs(got - 1.5), 0.03, "grade extendedSRGB 1.5 identity \(got) ≠ 1.5 (carried)")
        XCTAssertGreaterThan(abs(got - 1.0), 0.3, "grade extendedSRGB 1.5 \(got) matches the pre-clamp bug 1.0")
    }

    /// IN-RANGE extendedSRGB (0.5) is unchanged — only > 1 differs from the pre-fix
    /// pre-clamp, so true-SDR/in-range stays byte-identical (identity grade → 0.5).
    func testGradeInRangeExtendedSRGBUnchanged() throws {
        let w = 16, h = 16
        let proc = try ColorProcessor(device: try device())
        let src = try makeHalfNameOnly(w, h, v: 0.5, csName: CGColorSpace.extendedSRGB)
        let out = try proc.process(VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("g")),
                                   grade: ColorGrade(), lut: nil)
        XCTAssertLessThanOrEqual(abs(readHalfG(out, x: w / 2, y: h / 2) - 0.5), 0.02, "in-range extendedSRGB 0.5 changed")
    }

    /// CONTROL: a NON-extended source name (`sRGB`, not `extendedSRGB`) with a > 1
    /// value STILL pre-clamps to 1.0 (the extended-range carry is gated on the
    /// extended-family name only, so bounded transfers are byte-identical).
    func testGradeBoundedSRGBStillClamps() throws {
        let w = 16, h = 16
        let proc = try ColorProcessor(device: try device())
        let src = try makeHalfNameOnly(w, h, v: 1.5, csName: CGColorSpace.sRGB)   // NOT extended
        let out = try proc.process(VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("g")),
                                   grade: ColorGrade(), lut: nil)
        XCTAssertLessThanOrEqual(abs(readHalfG(out, x: w / 2, y: h / 2) - 1.0), 0.02,
                                 "bounded sRGB > 1 must still clamp to 1.0 (extended-carry leaked to a bounded transfer)")
    }

    // MARK: - #3 relight: same defect -------------------------------------------

    /// extendedSRGB 1.5 through an IDENTITY relight (ambient 1, no lights, flat depth)
    /// carries the highlight (1.5), not the pre-clamped 1.0.
    func testRelightExtendedSRGBHighlightNotPreClamped() throws {
        let w = 16, h = 16
        let relight = try RelightProcessor(device: try device())
        relight.ambient = 1      // identity linear scale (no lights)
        relight.depthScale = 0   // flat depth → no normal shading
        let depth = try makeFlatDepth(w, h)
        let src = try makeHalfNameOnly(w, h, v: 1.5, csName: CGColorSpace.extendedSRGB)
        let out = try relight.process(frame: VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("r")),
                                      depth: depth, lights: [])
        let got = readHalfG(out, x: w / 2, y: h / 2)
        XCTAssertLessThanOrEqual(abs(got - 1.5), 0.03, "relight extendedSRGB 1.5 identity \(got) ≠ 1.5 (carried)")
        XCTAssertGreaterThan(abs(got - 1.0), 0.3, "relight extendedSRGB 1.5 \(got) matches the pre-clamp bug 1.0")
    }

    // MARK: - #3 Vision background-remove: always-saturate defect ----------------

    /// extendedSRGB 1.5 through a background-REMOVE with an all-foreground matte is an
    /// identity pass; the pre-fix unconditional `saturate` crushed 1.5 → 1.0. The
    /// output (premultiplied, α=1) must carry 1.5.
    func testBackgroundRemoveExtendedSRGBHighlightNotPreClamped() throws {
        let w = 16, h = 16
        let bg = try BackgroundEffect(device: try device())
        let src = try makeHalfNameOnly(w, h, v: 1.5, csName: CGColorSpace.extendedSRGB)
        let matte = try makeForegroundMatte(w, h)
        let out = try bg.apply(frame: VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("v")),
                               matte: matte, mode: .remove)
        let got = readHalfG(out, x: w / 2, y: h / 2)
        XCTAssertLessThanOrEqual(abs(got - 1.5), 0.03, "bg-remove extendedSRGB 1.5 identity \(got) ≠ 1.5 (carried)")
        XCTAssertGreaterThan(abs(got - 1.0), 0.3, "bg-remove extendedSRGB 1.5 \(got) matches the pre-clamp bug 1.0")
    }

    // MARK: - #3 downstream: each stage's output composites to the EDR oracle -----

    /// The end-to-end proof sol named: extendedSRGB 1.5 through relight / background-
    /// remove (identity) then composited @25% opacity over black must reach the EDR
    /// oracle **937** (unclamped 1.5), NOT the pre-clamp **756** (1.5 → 1.0). Grade
    /// identity likewise reaches 937 (was 756). Independent oracle: extended-sRGB
    /// EOTF(1.5)=2.537, 709→2020 keeps neutral, blend 2.537·0.25 → HLG.
    func testStageOutputsCompositeToEDROracleNotPreClamp() throws {
        let w = 32, h = 32
        let correct = code(hlgOETF(rot709to2020(SIMD3(repeating: srgbEOTF(1.5))).x * 0.25))   // ≈937
        let preClampBug = code(hlgOETF(srgbEOTF(1.0) * 0.25))                                  // ≈756
        XCTAssertGreaterThan(abs(correct - preClampBug), 120, "oracle discriminator weak (\(correct) vs \(preClampBug))")

        let black = try makeBGRA(w, h, r: 0, g: 0, b: 0)

        func assertStage(_ label: String, _ out: VideoFrame) throws {
            let got = try compositeOver(top: out.pixelBuffer, topOpacity: 0.25, bottom: black, w: w, h: h)
            for ch in [got.b, got.g, got.r] {
                XCTAssertLessThanOrEqual(abs(ch - correct), 14, "\(label) downstream \(ch) ≠ EDR oracle \(correct)")
                XCTAssertGreaterThan(abs(ch - preClampBug), 60, "\(label) downstream \(ch) matches the pre-clamp bug \(preClampBug)")
            }
        }

        // grade identity
        let g = try ColorProcessor(device: try device()).process(
            VideoFrame(pixelBuffer: try makeHalfNameOnly(w, h, v: 1.5, csName: CGColorSpace.extendedSRGB),
                       pts: HouseClock.now(), source: SourceID("g")), grade: ColorGrade(), lut: nil)
        try assertStage("grade", g)

        // relight identity
        let relight = try RelightProcessor(device: try device())
        relight.ambient = 1; relight.depthScale = 0
        let r = try relight.process(
            frame: VideoFrame(pixelBuffer: try makeHalfNameOnly(w, h, v: 1.5, csName: CGColorSpace.extendedSRGB),
                              pts: HouseClock.now(), source: SourceID("r")),
            depth: try makeFlatDepth(w, h), lights: [])
        try assertStage("relight", r)

        // background-remove identity (all-foreground matte)
        let v = try BackgroundEffect(device: try device()).apply(
            frame: VideoFrame(pixelBuffer: try makeHalfNameOnly(w, h, v: 1.5, csName: CGColorSpace.extendedSRGB),
                              pts: HouseClock.now(), source: SourceID("v")),
            matte: try makeForegroundMatte(w, h), mode: .remove)
        try assertStage("bg-remove", v)
    }

    // MARK: - #4 genericRGBLinear correct primaries ------------------------------

    /// A saturated `genericRGBLinear` red composites through the Generic-RGB→Rec.2020
    /// rotation to ≈(942,530,230) [the Core-Image-color-managed oracle], NOT the
    /// pre-fix 709-primaries (935,466,227) — a ~64-code green error.
    func testGenericRGBLinearRedUsesGenericPrimaries() throws {
        let w = 32, h = 32
        let got = try compositeSingle(try makeBGRANameOnly(w, h, r: 255, g: 0, b: 0, csName: CGColorSpace.genericRGBLinear), w: w, h: h)
        // Independent from-spec oracle: Generic-RGB red (linear 1,0,0) → Rec.2020 → HLG.
        let lin = rotGenericTo2020(SIMD3(1, 0, 0))
        let cr = code(hlgOETF(lin.x)), cg = code(hlgOETF(lin.y)), cb = code(hlgOETF(lin.z))  // ≈(942,527,231)
        XCTAssertLessThanOrEqual(abs(got.r - cr), 8, "genericRGBLinear red R \(got.r) ≠ \(cr)")
        XCTAssertLessThanOrEqual(abs(got.g - cg), 8, "genericRGBLinear red G \(got.g) ≠ \(cg)")
        XCTAssertLessThanOrEqual(abs(got.b - cb), 6, "genericRGBLinear red B \(got.b) ≠ \(cb)")
        // Matches sol's Core-Image cross-check (942,530,230) within tolerance.
        XCTAssertLessThanOrEqual(abs(got.r - 942), 8, "R ≠ CI oracle 942")
        XCTAssertLessThanOrEqual(abs(got.g - 530), 10, "G ≠ CI oracle 530")
        XCTAssertLessThanOrEqual(abs(got.b - 230), 8, "B ≠ CI oracle 230")
        // FAR from the 709-primaries bug (935,466,227) — the green error is the tell.
        XCTAssertGreaterThan(abs(got.g - 466), 40, "genericRGBLinear green matches the 709-primaries bug 466")
    }

    /// CONTROL: `linearSRGB` is a genuine Rec.709 gamut — its saturated red is
    /// UNCHANGED (709→2020 → ≈(935,466,227)); only genericRGBLinear's gamut moved.
    func testLinearSRGBRedUnchanged() throws {
        let w = 32, h = 32
        let got = try compositeSingle(try makeBGRANameOnly(w, h, r: 255, g: 0, b: 0, csName: CGColorSpace.linearSRGB), w: w, h: h)
        let lin = rot709to2020(SIMD3(1, 0, 0))
        let cr = code(hlgOETF(lin.x)), cg = code(hlgOETF(lin.y)), cb = code(hlgOETF(lin.z))  // ≈(935,466,227)
        XCTAssertLessThanOrEqual(abs(got.r - cr), 8, "linearSRGB red R \(got.r) ≠ \(cr)")
        XCTAssertLessThanOrEqual(abs(got.g - cg), 8, "linearSRGB red G \(got.g) ≠ \(cg) (regressed off Rec.709)")
        XCTAssertLessThanOrEqual(abs(got.b - cb), 6, "linearSRGB red B \(got.b) ≠ \(cb)")
    }
}
