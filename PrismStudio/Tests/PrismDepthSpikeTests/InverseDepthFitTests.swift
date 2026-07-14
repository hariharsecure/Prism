import XCTest
@testable import PrismDepthSpike

/// Robust inverse-depth affine fit recovers KNOWN synthetic `a,b`
/// (design: "robust relative-inverse-depth fit recovers known synthetic a,b" —
/// THE central-risk math). The oracle is the `a,b` this test itself planted;
/// correspondences are generated so `1/Z = a·r + b` holds exactly, then the fit
/// must recover them, including under gross outliers.
final class InverseDepthFitTests: XCTestCase {

    /// Generate clean correspondences with a planted a,b over a range of relative
    /// values. relative r spans [0.1, 1.0]; metricZ = 1/(a·r + b).
    private func cleanCorrespondences(a: Double, b: Double, count: Int) -> [DepthCorrespondence] {
        (0..<count).map { i in
            let r = 0.1 + 0.9 * Double(i) / Double(count - 1)
            let invZ = a * r + b
            return DepthCorrespondence(relative: r, metricZ: 1.0 / invZ)
        }
    }

    func testRecoversKnownABClean() throws {
        let a = 3.2, b = 0.15
        let corr = cleanCorrespondences(a: a, b: b, count: 12)
        let fit = try InverseDepthFit.fit(corr)
        XCTAssertEqual(fit.a, a, accuracy: 1e-6, "scale a not recovered")
        XCTAssertEqual(fit.b, b, accuracy: 1e-6, "shift b not recovered")
        XCTAssertEqual(fit.inlierCount, 12)
        XCTAssertLessThan(fit.rmsResidualInliers, 1e-6)
    }

    func testScaleAloneIsInsufficient() throws {
        // With b != 0, a pure-scale model cannot match; the affine fit must find
        // both. Verify predicted 1/Z matches at a check point only with full a,b.
        let a = 2.0, b = 0.5
        let corr = cleanCorrespondences(a: a, b: b, count: 8)
        let fit = try InverseDepthFit.fit(corr)
        let rCheck = 0.62
        let predictedInvZ = fit.a * rCheck + fit.b
        XCTAssertEqual(predictedInvZ, a * rCheck + b, accuracy: 1e-6)
        // A scale-only model (b forced 0) would be off by ~b here.
        XCTAssertGreaterThan(abs((a * rCheck) - (a * rCheck + b)), 0.4)
    }

    func testRecoversABWithOutliers() throws {
        let a = 4.0, b = 0.1
        var corr = cleanCorrespondences(a: a, b: b, count: 20)
        // Corrupt 6 of 20 with gross outliers (wrong metricZ). RANSAC must reject.
        for idx in [2, 5, 8, 11, 14, 17] {
            corr[idx] = DepthCorrespondence(relative: corr[idx].relative, metricZ: 0.05) // absurd near depth
        }
        let fit = try InverseDepthFit.fit(corr, options: .init(inlierThreshold: 0.02,
                                                               ransacIterations: 300))
        XCTAssertEqual(fit.a, a, accuracy: 1e-4, "a not recovered under outliers")
        XCTAssertEqual(fit.b, b, accuracy: 1e-4, "b not recovered under outliers")
        XCTAssertEqual(fit.inlierCount, 14, "should keep exactly the 14 clean points")
        // Diagnostics expose the rejected outliers via maxResidualAll >> inliers.
        XCTAssertGreaterThan(fit.maxResidualAll, fit.maxResidualInliers * 10)
        for badIdx in [2, 5, 8, 11, 14, 17] {
            XCTAssertFalse(fit.inlierIndices.contains(badIdx), "outlier \(badIdx) wrongly kept")
        }
    }

    func testDeterministicAcrossRuns() throws {
        // Reproducibility is a Phase-0 requirement: same seed → identical result.
        let a = 1.7, b = 0.3
        var corr = cleanCorrespondences(a: a, b: b, count: 16)
        corr[3] = DepthCorrespondence(relative: corr[3].relative, metricZ: 99)
        let f1 = try InverseDepthFit.fit(corr)
        let f2 = try InverseDepthFit.fit(corr)
        XCTAssertEqual(f1.a, f2.a)
        XCTAssertEqual(f1.b, f2.b)
        XCTAssertEqual(f1.inlierIndices, f2.inlierIndices)
    }

    func testDegenerateInputsThrow() {
        XCTAssertThrowsError(try InverseDepthFit.fit([DepthCorrespondence(relative: 0.5, metricZ: 2)]))
        // Non-positive metricZ is invalid (can't invert).
        XCTAssertThrowsError(try InverseDepthFit.fit([
            DepthCorrespondence(relative: 0.1, metricZ: 1),
            DepthCorrespondence(relative: 0.2, metricZ: -3),
        ]))
    }

    func testMetricZApplication() {
        // Applying the map is the exact inverse of the generation formula.
        let a = 2.5, b = 0.2, r = 0.4
        let z = InverseDepthFit.metricZ(relative: r, a: a, b: b)
        XCTAssertEqual(z!, 1.0 / (a * r + b), accuracy: 1e-12)
        // Negative implied inverse depth → invalid.
        XCTAssertNil(InverseDepthFit.metricZ(relative: 1.0, a: -1.0, b: 0.5))
    }
}
