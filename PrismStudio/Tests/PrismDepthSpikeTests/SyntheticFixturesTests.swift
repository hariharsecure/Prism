import XCTest
import simd
@testable import PrismDepthSpike

/// Synthetic fixtures carry KNOWN Z, and the known-`a,b` relative map feeds the
/// fit end-to-end. Oracles are recomputed here independently.
final class SyntheticFixturesTests: XCTestCase {
    private let K = PinholeIntrinsics(fx: 500, fy: 500, cx: 128, cy: 96,
                                      referenceWidth: 256, referenceHeight: 192)

    func testRectangleAndThinBarKnownZ() throws {
        let f = try SyntheticFixtures.rectangle(width: 32, height: 24,
                                                rect: (8, 6, 20, 18), zMeters: 1.5)
        XCTAssertEqual(f.z[10 * 32 + 12], 1.5)      // inside
        XCTAssertNil(f.z[0])                         // outside → invalid
        let bar = try SyntheticFixtures.thinBar(width: 40, height: 10,
                                                xCenter: 20, barWidthPx: 3, zMeters: 2.0)
        XCTAssertEqual(bar.z[5 * 40 + 20], 2.0)
        XCTAssertNil(bar.z[5 * 40 + 30])
    }

    func testSlantedPlaneAnalytic() throws {
        // Fronto-parallel special case: normal (0,0,1), distance d → Z == d everywhere.
        let flat = try SyntheticFixtures.slantedPlane(width: 16, height: 16, intrinsics: K,
                                                      normal: SIMD3(0, 0, 1), planeDistance: 2.0)
        for z in flat.z { XCTAssertEqual(z!, 2.0, accuracy: 1e-9) }

        // Genuinely slanted: check one pixel against the independent formula.
        let n = SIMD3(0.3, 0.0, 1.0), d = 2.5
        let slant = try SyntheticFixtures.slantedPlane(width: 16, height: 16, intrinsics: K,
                                                       normal: n, planeDistance: d)
        let x = 200.0 - Double(0) // pick pixel (200 is outside 16-wide; use in-range)
        _ = x
        let px = 12, py = 8
        let dx = (Double(px) - K.cx) / K.fx
        let dy = (Double(py) - K.cy) / K.fy
        let expected = d / (n.x * dx + n.y * dy + n.z)
        XCTAssertEqual(slant.z[py * 16 + px]!, expected, accuracy: 1e-9)
    }

    func testSphereFrontSurface() throws {
        // Sphere straight ahead; centre pixel Z must be centerDist − radius.
        let center = SIMD3(0.0, 0.0, 3.0), radius = 0.5
        let s = try SyntheticFixtures.sphere(width: 257, height: 193, intrinsics:
            PinholeIntrinsics(fx: 500, fy: 500, cx: 128, cy: 96, referenceWidth: 257, referenceHeight: 193),
            center: center, radius: radius)
        // Pixel at principal point (128,96): ray = (0,0,1) → nearest hit = 3 - 0.5.
        XCTAssertEqual(s.z[96 * 257 + 128]!, 3.0 - radius, accuracy: 1e-6)
        // A far corner should miss the small sphere → invalid.
        XCTAssertNil(s.z[0])
    }

    func testKnownABRelativeMapRecoversThroughFit() throws {
        // Build a metric scene (slanted plane), derive a relative map with planted
        // a,b, sample correspondences, and confirm the fit recovers a,b — closing
        // the loop fixtures → fit.
        let a = 2.7, b = 0.2
        let metric = try SyntheticFixtures.slantedPlane(width: 64, height: 64, intrinsics: K,
                                                        normal: SIMD3(0.2, 0.1, 1.0), planeDistance: 3.0)
        let relative = SyntheticFixtures.relativeFromMetric(metric, a: a, b: b)
        var corr: [DepthCorrespondence] = []
        for i in stride(from: 0, to: 64 * 64, by: 373) {
            if let r = relative[i], let z = metric.z[i] {
                corr.append(DepthCorrespondence(relative: r, metricZ: z))
            }
        }
        XCTAssertGreaterThanOrEqual(corr.count, 3)
        let fit = try InverseDepthFit.fit(corr)
        XCTAssertEqual(fit.a, a, accuracy: 1e-5)
        XCTAssertEqual(fit.b, b, accuracy: 1e-5)
    }
}
