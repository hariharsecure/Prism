import XCTest
import simd
@testable import PrismDepthSpike

/// Axial-Z ⇄ along-ray-distance conversion vs INDEPENDENT analytic fixtures
/// (design's "axial versus ray conversion matches analytic fixtures"). The
/// expected values are computed here in Double from first principles, never by
/// calling the conversion under test.
final class AxialRayConversionTests: XCTestCase {
    private let K = PinholeIntrinsics(fx: 1000, fy: 1000, cx: 960, cy: 540,
                                      referenceWidth: 1920, referenceHeight: 1080)

    func testPrincipalPointRayEqualsAxial() {
        // On the optical axis the ray IS the axis → range == axial Z, exactly.
        let z = 2.5
        let range = K.rayRange(fromAxialZ: z, u: 960, v: 540)
        XCTAssertEqual(range, z, accuracy: 1e-12)
        XCTAssertEqual(K.axialZ(fromRayRange: z, u: 960, v: 540), z, accuracy: 1e-12)
    }

    func testOffAxisAnalyticFixture() {
        // Pixel one focal length right of centre: dx=1, dy=0 → scale = sqrt(2).
        let u = 960.0 + 1000.0, v = 540.0
        let z = 3.0
        let expectedScale = (1.0 * 1.0 + 0.0 + 1.0).squareRoot() // independent
        let expectedRange = z * expectedScale
        XCTAssertEqual(K.rayRange(fromAxialZ: z, u: u, v: v), expectedRange, accuracy: 1e-10)
        // Inverse recovers axial.
        XCTAssertEqual(K.axialZ(fromRayRange: expectedRange, u: u, v: v), z, accuracy: 1e-10)
    }

    func testGeneralOffAxisFixture() {
        // dx = (u-cx)/fx, dy = (v-cy)/fy computed independently.
        let u = 1360.0, v = 240.0 // dx = 0.4, dy = -0.3
        let dx = 0.4, dy = -0.3
        let scale = (dx * dx + dy * dy + 1.0).squareRoot()
        let z = 4.2
        XCTAssertEqual(K.rayRange(fromAxialZ: z, u: u, v: v), z * scale, accuracy: 1e-10)
    }

    func testRoundTripManyPixels() {
        for u in stride(from: 0.0, through: 1920.0, by: 137.0) {
            for v in stride(from: 0.0, through: 1080.0, by: 91.0) {
                for z in [0.75, 1.5, 3.0, 5.0] {
                    let r = K.rayRange(fromAxialZ: z, u: u, v: v)
                    XCTAssertEqual(K.axialZ(fromRayRange: r, u: u, v: v), z, accuracy: 1e-9)
                }
            }
        }
    }

    func testUnprojectConsistentWithAxialZ() {
        // Back-projected point's Z component must equal the axial input, and its
        // norm must equal the ray range (cross-check between the two utilities).
        let u = 1200.0, v = 700.0, z = 2.1
        let p = K.unproject(u: u, v: v, axialZ: z)
        XCTAssertEqual(p.z, z, accuracy: 1e-12)
        XCTAssertEqual(simd_length(p), K.rayRange(fromAxialZ: z, u: u, v: v), accuracy: 1e-10)
    }
}
