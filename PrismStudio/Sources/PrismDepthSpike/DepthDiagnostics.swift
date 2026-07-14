import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Software diagnostics for the depth spike (`docs/UNREAL_AR_3D_CHARACTER_DESIGN.md`,
/// "output raw depth, calibrated depth, delta/visibility, edge disagreement").
/// Computed on the CPU in Double so a verifier/human can inspect the exact
/// numbers and dump grayscale PNGs. This is inspection, not the render path.
public struct DepthDiagnostics {
    public let width: Int
    public let height: Int
    /// Raw relative monocular value `r` (nil = scene invalid).
    public let raw: [Double?]
    /// Calibrated metric scene Z from the affine fit (nil = invalid / inv≤0).
    public let calibrated: [Double?]
    /// `sceneZ − charZ` (nil where either side invalid or char uncovered).
    public let delta: [Double?]
    /// Occlusion visibility in [0,1] under the declared params.
    public let visibility: [Double]
    /// Edge disagreement magnitude in [0,1]: how much the character SILHOUETTE
    /// (alpha coverage boundary) is suppressed by the depth decision — i.e. the
    /// contour where alpha says "character" but depth hides it. Zero when the
    /// character is entirely in front; nonzero where a scene object cuts it.
    public let edgeDisagreement: [Double]

    public struct Summary: Sendable {
        public var coveredPixels: Int
        public var visibleFraction: Double        // mean visibility over covered
        public var invalidSceneFraction: Double   // over covered pixels
        public var meanCalibrationErrorZ: Double?  // vs a supplied ground truth
        public var maxEdgeDisagreement: Double
    }
    public let summary: Summary

    /// Build all diagnostic maps.
    /// - `rawRelative`: monocular relative map (nil = invalid).
    /// - `charZ`/`charAlpha`: character axial depth & coverage (nil charZ = invalid).
    /// - `groundTruthSceneZ`: optional true metric Z for calibration error.
    public static func compute(width: Int, height: Int,
                               rawRelative: [Double?],
                               charZ: [Double?], charAlpha: [Double],
                               fitA a: Double, fitB b: Double,
                               params: DepthCompositeParams,
                               groundTruthSceneZ: [Double?]? = nil) -> DepthDiagnostics {
        let n = width * height
        var calibrated = [Double?](repeating: nil, count: n)
        var delta = [Double?](repeating: nil, count: n)
        var visibility = [Double](repeating: 0, count: n)

        for i in 0..<n {
            let sceneZ = rawRelative[i].flatMap { InverseDepthFit.metricZ(relative: $0, a: a, b: b) }
            calibrated[i] = sceneZ
            let cz = charZ[i]
            if let cz, let sceneZ { delta[i] = sceneZ - cz }
            visibility[i] = params.visibility(charAlpha: charAlpha[i], charZ: cz, sceneZ: sceneZ)
        }

        // Edge disagreement: silhouette contour (alpha coverage boundary) times
        // how much that covered pixel is suppressed (1 − visibility).
        var edge = [Double](repeating: 0, count: n)
        var maxEdge = 0.0
        func covered(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && x < width && y >= 0 && y < height && charAlpha[y * width + x] > 0
        }
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                guard charAlpha[i] > 0 else { continue }
                let onBoundary = !covered(x - 1, y) || !covered(x + 1, y)
                                 || !covered(x, y - 1) || !covered(x, y + 1)
                if onBoundary {
                    let e = 1.0 - visibility[i]
                    edge[i] = e
                    maxEdge = max(maxEdge, e)
                }
            }
        }

        // Summary.
        var covCount = 0, visSum = 0.0, invScene = 0.0
        var errSum = 0.0, errCount = 0
        for i in 0..<n where charAlpha[i] > 0 {
            covCount += 1
            visSum += visibility[i]
            if calibrated[i] == nil { invScene += 1 }
            if let gt = groundTruthSceneZ?[i], let cal = calibrated[i] {
                errSum += abs(cal - gt); errCount += 1
            }
        }
        let summary = Summary(
            coveredPixels: covCount,
            visibleFraction: covCount > 0 ? visSum / Double(covCount) : 0,
            invalidSceneFraction: covCount > 0 ? invScene / Double(covCount) : 0,
            meanCalibrationErrorZ: errCount > 0 ? errSum / Double(errCount) : nil,
            maxEdgeDisagreement: maxEdge)

        return DepthDiagnostics(width: width, height: height, raw: rawRelative,
                                calibrated: calibrated, delta: delta,
                                visibility: visibility, edgeDisagreement: edge,
                                summary: summary)
    }

    /// Dump a `[Double]` field as an 8-bit grayscale PNG, normalizing `[lo,hi]`
    /// to `[0,255]`. NaN/nil sentinels render as 0. For human inspection only.
    @discardableResult
    public static func dumpGray(_ values: [Double?], width: Int, height: Int,
                                lo: Double, hi: Double, to path: String) -> Bool {
        guard values.count == width * height, hi > lo else { return false }
        var bytes = [UInt8](repeating: 0, count: width * height)
        for i in 0..<values.count {
            guard let v = values[i], v.isFinite else { continue }
            let t = (v - lo) / (hi - lo)
            bytes[i] = UInt8(max(0, min(255, (t * 255).rounded())))
        }
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &bytes, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }
}
