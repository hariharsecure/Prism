import XCTest
import simd
@testable import PrismDepthSpike

/// Diagnostics (raw / calibrated / delta-visibility / edge-disagreement) are
/// computable and inspectable, and behave as the design expects: no edge
/// disagreement when the character is entirely in front, disagreement where a
/// nearer scene object cuts through it. PNG dumps land in the scratchpad for a
/// human/verifier to eyeball.
final class DiagnosticsTests: XCTestCase {
    private static let dumpDir = "/tmp/prism_depth_spike"

    override class func setUp() {
        try? FileManager.default.createDirectory(atPath: dumpDir, withIntermediateDirectories: true)
    }

    /// Scene: character rectangle at charZ; a KNOWN a,b relative map for the
    /// background; a nearer scene bar cutting the character on the right half.
    private func scene(width w: Int, height h: Int)
        -> (raw: [Double?], charZ: [Double?], charAlpha: [Double], gt: [Double?], a: Double, b: Double) {
        let a = 3.0, b = 0.1
        let charZ0 = 2.0
        var raw = [Double?](repeating: nil, count: w * h)
        var cz = [Double?](repeating: nil, count: w * h)
        var ca = [Double](repeating: 0, count: w * h)
        var gt = [Double?](repeating: nil, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                // Character covers the central rectangle.
                let inChar = x >= w / 4 && x < 3 * w / 4 && y >= h / 4 && y < 3 * h / 4
                if inChar { ca[i] = 1; cz[i] = charZ0 }
                // Scene depth: background far (5m), but a nearer bar (1m) on right third.
                let sceneZ = x >= 2 * w / 3 ? 1.0 : 5.0
                gt[i] = sceneZ
                raw[i] = (1.0 / sceneZ - b) / a // relative map with planted a,b
            }
        }
        return (raw, cz, ca, gt, a, b)
    }

    func testDiagnosticsComputeAndDump() throws {
        let w = 96, h = 72
        let s = scene(width: w, height: h)
        // Recover a,b from a handful of correspondences (as the pipeline would).
        var corr: [DepthCorrespondence] = []
        for i in stride(from: 0, to: w * h, by: 211) {
            if let r = s.raw[i], let z = s.gt[i] { corr.append(DepthCorrespondence(relative: r, metricZ: z)) }
        }
        let fit = try InverseDepthFit.fit(corr)
        XCTAssertEqual(fit.a, s.a, accuracy: 1e-5)
        XCTAssertEqual(fit.b, s.b, accuracy: 1e-5)

        let params = DepthCompositeParams(featherMeters: 0)
        let diag = DepthDiagnostics.compute(width: w, height: h, rawRelative: s.raw,
                                            charZ: s.charZ, charAlpha: s.charAlpha,
                                            fitA: fit.a, fitB: fit.b, params: params,
                                            groundTruthSceneZ: s.gt)

        // Calibrated scene depth must match ground truth within fit tolerance.
        if let err = diag.summary.meanCalibrationErrorZ {
            XCTAssertLessThan(err, 1e-3, "calibrated depth should recover metric Z")
        } else { XCTFail("no calibration error computed") }

        // Character overlaps the near bar on its right → some covered pixels are
        // occluded (visibility 0) and the silhouette shows disagreement there.
        XCTAssertLessThan(diag.summary.visibleFraction, 1.0)
        XCTAssertGreaterThan(diag.summary.visibleFraction, 0.0)
        XCTAssertGreaterThan(diag.summary.maxEdgeDisagreement, 0.0)

        // Dump for inspection.
        DepthDiagnostics.dumpGray(diag.raw, width: w, height: h, lo: -0.05, hi: 0.35,
                                  to: "\(Self.dumpDir)/raw_relative.png")
        DepthDiagnostics.dumpGray(diag.calibrated, width: w, height: h, lo: 0, hi: 6,
                                  to: "\(Self.dumpDir)/calibrated_metric.png")
        DepthDiagnostics.dumpGray(diag.visibility.map { Optional($0) }, width: w, height: h,
                                  lo: 0, hi: 1, to: "\(Self.dumpDir)/visibility.png")
        DepthDiagnostics.dumpGray(diag.edgeDisagreement.map { Optional($0) }, width: w, height: h,
                                  lo: 0, hi: 1, to: "\(Self.dumpDir)/edge_disagreement.png")
    }

    func testNoDisagreementWhenFullyInFront() throws {
        let w = 48, h = 48
        let a = 2.0, b = 0.2, charZ0 = 2.0
        var raw = [Double?](repeating: nil, count: w * h)
        var cz = [Double?](repeating: nil, count: w * h)
        var ca = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if x >= w / 4 && x < 3 * w / 4 && y >= h / 4 && y < 3 * h / 4 { ca[i] = 1; cz[i] = charZ0 }
                let sceneZ = 6.0 // everything far → char always in front
                raw[i] = (1.0 / sceneZ - b) / a
            }
        }
        let diag = DepthDiagnostics.compute(width: w, height: h, rawRelative: raw,
                                            charZ: cz, charAlpha: ca, fitA: a, fitB: b,
                                            params: DepthCompositeParams(featherMeters: 0))
        XCTAssertEqual(diag.summary.visibleFraction, 1.0, accuracy: 1e-9)
        XCTAssertEqual(diag.summary.maxEdgeDisagreement, 0.0, accuracy: 1e-9)
    }
}
