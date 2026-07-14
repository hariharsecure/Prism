import XCTest
import CoreVideo
import Metal
import simd
@testable import PrismDepthSpike

/// The isolated z-aware Metal composite kernel vs an INDEPENDENT Double oracle
/// computed inline in each test (never by calling the kernel / shared helper).
/// Covers the design's "Verifiable in software" list:
///  - z-aware shader pixel-exact away from the declared feather;
///  - premultiplied rgb AND alpha both scaled by visibility;
///  - invalid/low-confidence depth takes a declared fallback.
final class DepthCompositeKernelTests: XCTestCase {
    private var kernel: DepthCompositeKernel!

    override func setUpWithError() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("no Metal device — z-aware kernel is GPU-only")
        }
        kernel = try DepthCompositeKernel()
    }

    /// Inline Double oracle for the hard/feather visibility decision.
    private func oracleVis(charAlpha: Double, charZ: Double?, sceneZ: Double?,
                           feather: Double, eps: Double,
                           sceneFallback: Double, charInvalid: Double) -> Double {
        if charAlpha <= 0 { return 0 }
        guard let cz = charZ else { return charInvalid }
        guard let sz = sceneZ else { return sceneFallback }
        let delta = sz - cz
        if feather <= 0 { return (delta - eps > 0) ? 1 : 0 }
        return min(max((delta - eps) / (2 * feather) + 0.5, 0), 1)
    }

    // MARK: - Pixel-exact away from the feather (hard step)

    func testHardStepPixelExact() throws {
        let w = 64, h = 48
        let charZ = 2.0, charAlpha = 1.0
        let charRGB = SIMD3(0.6, 0.4, 0.2)
        // Scene: left half behind (5m → char visible), right half in front (1m → occluded).
        let (charPlate, charDepth) = try SyntheticFixtures.rectangleCharacter(
            width: w, height: h, rect: (0, 0, w, h), rgb: charRGB, alpha: charAlpha, charZMeters: charZ)
        let sceneField = try SyntheticFixtures.field(width: w, height: h) { x, _ in x < w / 2 ? 5.0 : 1.0 }
        let plate = try SyntheticFixtures.solidPlate(width: w, height: h, rgb: SIMD3(0.1, 0.1, 0.1))

        let params = DepthCompositeParams(featherMeters: 0)
        let out = try kernel.composite(plate: plate.buffer, charColor: charPlate.buffer,
                                       charDepth: charDepth.buffer, sceneDepth: sceneField.buffer,
                                       params: params)
        let (px, _, _) = DepthPixelIO.readColor(out)

        for y in 0..<h {
            for x in 0..<w {
                let sceneZ = x < w / 2 ? 5.0 : 1.0
                let vis = oracleVis(charAlpha: charAlpha, charZ: charZ, sceneZ: sceneZ,
                                    feather: 0, eps: 0, sceneFallback: 1, charInvalid: 0)
                // scaledChar over plate.
                let sc = SIMD4(charRGB.x * charAlpha, charRGB.y * charAlpha,
                               charRGB.z * charAlpha, charAlpha) * vis
                let pl = SIMD4(0.1, 0.1, 0.1, 1.0)
                let exp = sc + pl * (1 - sc.w)
                let got = px[y * w + x]
                XCTAssertEqual(Double(got.x), exp.x, accuracy: 1e-5)
                XCTAssertEqual(Double(got.y), exp.y, accuracy: 1e-5)
                XCTAssertEqual(Double(got.z), exp.z, accuracy: 1e-5)
                XCTAssertEqual(Double(got.w), exp.w, accuracy: 1e-5)
            }
        }
    }

    // MARK: - Premultiplied rgb AND alpha both scaled by visibility

    func testPremultRGBAndAlphaBothScaled() throws {
        let w = 16, h = 16
        let charZ = 2.0, charAlpha = 0.8
        let charRGB = SIMD3(0.9, 0.5, 0.3)
        // sceneZ = 2.5 → delta 0.5, feather 1.0 → vis = 0.5/2 + 0.5 = 0.75 (mid-band).
        let (charPlate, charDepth) = try SyntheticFixtures.rectangleCharacter(
            width: w, height: h, rect: (0, 0, w, h), rgb: charRGB, alpha: charAlpha, charZMeters: charZ)
        let sceneField = try SyntheticFixtures.constantPlane(width: w, height: h, zMeters: 2.5)
        // Transparent plate isolates the scaled character exactly.
        let plate = try SyntheticFixtures.transparentPlate(width: w, height: h)

        let out = try kernel.composite(plate: plate.buffer, charColor: charPlate.buffer,
                                       charDepth: charDepth.buffer, sceneDepth: sceneField.buffer,
                                       params: DepthCompositeParams(featherMeters: 1.0))
        let (px, _, _) = DepthPixelIO.readColor(out)
        let vis = 0.75
        for p in px {
            // premultiplied rgb scaled by vis:
            XCTAssertEqual(Double(p.x), charRGB.x * charAlpha * vis, accuracy: 1e-5)
            XCTAssertEqual(Double(p.y), charRGB.y * charAlpha * vis, accuracy: 1e-5)
            XCTAssertEqual(Double(p.z), charRGB.z * charAlpha * vis, accuracy: 1e-5)
            // alpha ALSO scaled by vis:
            XCTAssertEqual(Double(p.w), charAlpha * vis, accuracy: 1e-5)
        }
    }

    // MARK: - Over-plate blend correctness (non-transparent background)

    func testOverPlateBlend() throws {
        let w = 8, h = 8
        let charRGB = SIMD3(1.0, 0.0, 0.0), charAlpha = 0.5, charZ = 2.0
        let plateRGB = SIMD3(0.2, 0.3, 0.4)
        let (charPlate, charDepth) = try SyntheticFixtures.rectangleCharacter(
            width: w, height: h, rect: (0, 0, w, h), rgb: charRGB, alpha: charAlpha, charZMeters: charZ)
        let scene = try SyntheticFixtures.constantPlane(width: w, height: h, zMeters: 2.5) // char fully in front, feather 0
        let plate = try SyntheticFixtures.solidPlate(width: w, height: h, rgb: plateRGB)
        let out = try kernel.composite(plate: plate.buffer, charColor: charPlate.buffer,
                                       charDepth: charDepth.buffer, sceneDepth: scene.buffer,
                                       params: DepthCompositeParams(featherMeters: 0))
        let (px, _, _) = DepthPixelIO.readColor(out)
        let vis = 1.0
        let sc = SIMD4(charRGB.x * charAlpha, charRGB.y * charAlpha, charRGB.z * charAlpha, charAlpha) * vis
        let pl = SIMD4(plateRGB.x, plateRGB.y, plateRGB.z, 1.0)
        let exp = sc + pl * (1 - sc.w)
        for p in px {
            XCTAssertEqual(Double(p.x), exp.x, accuracy: 1e-5)
            XCTAssertEqual(Double(p.y), exp.y, accuracy: 1e-5)
            XCTAssertEqual(Double(p.z), exp.z, accuracy: 1e-5)
            XCTAssertEqual(Double(p.w), exp.w, accuracy: 1e-5)
        }
    }

    // MARK: - Feather ramp is exact 0/1 outside the band, linear inside

    func testFeatherBandExactOutsideRampInside() throws {
        let w = 128, h = 4
        let charZ = 3.0, charAlpha = 1.0, feather = 0.5
        // sceneZ ramps 2.0 → 4.0 across x → delta ramps -1.0 → +1.0.
        let (charPlate, charDepth) = try SyntheticFixtures.rectangleCharacter(
            width: w, height: h, rect: (0, 0, w, h), rgb: SIMD3(1, 1, 1), alpha: charAlpha, charZMeters: charZ)
        let scene = try SyntheticFixtures.field(width: w, height: h) { x, _ in
            2.0 + 2.0 * Double(x) / Double(w - 1)
        }
        let plate = try SyntheticFixtures.transparentPlate(width: w, height: h)
        let out = try kernel.composite(plate: plate.buffer, charColor: charPlate.buffer,
                                       charDepth: charDepth.buffer, sceneDepth: scene.buffer,
                                       params: DepthCompositeParams(featherMeters: Float(feather)))
        let (px, _, _) = DepthPixelIO.readColor(out)
        for y in 0..<h {
            for x in 0..<w {
                let sceneZ = 2.0 + 2.0 * Double(x) / Double(w - 1)
                let delta = sceneZ - charZ
                let expVis: Double
                if delta <= -feather { expVis = 0 }        // exact
                else if delta >= feather { expVis = 1 }    // exact
                else { expVis = delta / (2 * feather) + 0.5 }
                let got = Double(px[y * w + x].w) // alpha == charAlpha*vis == vis
                XCTAssertEqual(got, expVis, accuracy: 1e-5, "x=\(x) delta=\(delta)")
            }
        }
    }

    // MARK: - Declared fallbacks for invalid / low-confidence depth

    func testInvalidDepthFallbacks() throws {
        let w = 4, h = 1
        // Column layout: x0 covered+valid(char in front), x1 scene invalid,
        // x2 char-depth invalid, x3 uncovered (alpha 0).
        let charRGB = SIMD3(1.0, 1.0, 1.0)
        let charPlate = try DepthPixelIO.makeColor(width: w, height: h) { x, _ in
            let a: Float = x == 3 ? 0 : 1
            return SIMD4(charRGB.x.f * a, charRGB.y.f * a, charRGB.z.f * a, a)
        }
        let charDepth = try DepthPixelIO.makeDepth(width: w, height: h) { x, _ in
            x == 2 ? DepthPixelIO.invalidDepth : 2.0
        }
        let scene = try DepthPixelIO.makeDepth(width: w, height: h) { x, _ in
            x == 1 ? DepthPixelIO.invalidDepth : 5.0 // valid scene is far → char visible
        }
        let plate = try SyntheticFixtures.solidPlate(width: w, height: h, rgb: SIMD3(0, 0, 0))

        // sceneInvalid → SHOW (flat char), charInvalid → HIDE (conservative).
        let params = DepthCompositeParams(featherMeters: 0,
                                          sceneInvalidFallback: .show,
                                          charInvalidVisibility: .hide)
        let out = try kernel.composite(plate: plate.buffer, charColor: charPlate,
                                       charDepth: charDepth, sceneDepth: scene, params: params)
        let (px, _, _) = DepthPixelIO.readColor(out)
        // Plate is OPAQUE black (alpha 1), so alpha is 1 everywhere; the occlusion
        // signal is the red channel: character shown → 1, hidden → 0.
        // x0: valid, char in front → vis 1 → white character.
        XCTAssertEqual(Double(px[0].x), 1, accuracy: 1e-5, "x0 char should be visible")
        XCTAssertEqual(Double(px[0].w), 1, accuracy: 1e-5)
        // x1: scene invalid, fallback SHOW → vis 1 → white character.
        XCTAssertEqual(Double(px[1].x), 1, accuracy: 1e-5, "x1 scene-invalid SHOW → char drawn")
        // x2: char depth invalid, HIDE → vis 0 → plate (black rgb), plate alpha 1.
        XCTAssertEqual(Double(px[2].x), 0, accuracy: 1e-5, "x2 char-depth-invalid HIDE → char suppressed")
        XCTAssertEqual(Double(px[2].w), 1, accuracy: 1e-5)
        // x3: uncovered (alpha 0) → no character, plate shows through (black).
        XCTAssertEqual(Double(px[3].x), 0, accuracy: 1e-5, "x3 uncovered → no character")

        // Flip scene fallback to HIDE → x1 character now suppressed (red → 0).
        let hideParams = DepthCompositeParams(featherMeters: 0,
                                              sceneInvalidFallback: .hide,
                                              charInvalidVisibility: .hide)
        let out2 = try kernel.composite(plate: plate.buffer, charColor: charPlate,
                                        charDepth: charDepth, sceneDepth: scene, params: hideParams)
        let (px2, _, _) = DepthPixelIO.readColor(out2)
        XCTAssertEqual(Double(px2[1].x), 0, accuracy: 1e-5, "x1 scene-invalid HIDE → char suppressed")
    }
}

private extension Double { var f: Float { Float(self) } }
