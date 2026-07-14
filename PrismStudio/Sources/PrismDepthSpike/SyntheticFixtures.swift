import CoreVideo
import Foundation
import simd

/// Deterministic synthetic geometry + character plates at KNOWN axial Z, for the
/// Phase-0 spike corpus (`docs/UNREAL_AR_3D_CHARACTER_DESIGN.md`, "Inputs and
/// corpus": rectangles, a sphere, a slanted plane, thin geometry, synthetic
/// character plates, and a known-`a,b` relative-depth map). Public/synthetic
/// only — real target-camera clips are a separate workstream needing Rishi's
/// footage.
///
/// Every generator returns the IOSurface-backed buffer AND a parallel row-major
/// `[Double?]` oracle (`nil` == invalid/NaN) so a test can assert against math
/// it computed itself, never against the buffer it is checking.
public enum SyntheticFixtures {

    /// A generated axial-depth field: the r32Float buffer plus its Double oracle.
    public struct DepthField {
        public let buffer: CVPixelBuffer
        public let z: [Double?] // row-major, nil == invalid (NaN)
        public let width: Int
        public let height: Int
    }

    /// A generated premultiplied color plate: the rgba32Float buffer plus its
    /// straight (un-premultiplied) rgb/alpha oracle.
    public struct ColorPlate {
        public let buffer: CVPixelBuffer
        public let rgbaPremul: [SIMD4<Double>] // row-major premultiplied
        public let width: Int
        public let height: Int
    }

    // MARK: - Depth generators

    static func field(width: Int, height: Int, _ fn: (Int, Int) -> Double?) throws -> DepthField {
        var z = [Double?](repeating: nil, count: width * height)
        let buf = try DepthPixelIO.makeDepth(width: width, height: height) { x, y in
            let v = fn(x, y)
            z[y * width + x] = v
            return v.map { Float($0) } ?? DepthPixelIO.invalidDepth
        }
        return DepthField(buffer: buf, z: z, width: width, height: height)
    }

    /// Fronto-parallel constant-depth plane at `zMeters`.
    public static func constantPlane(width: Int, height: Int, zMeters: Double) throws -> DepthField {
        try field(width: width, height: height) { _, _ in zMeters }
    }

    /// Fronto-parallel rectangle at `zMeters`; invalid (NaN) outside `rect`.
    public static func rectangle(width: Int, height: Int,
                                 rect: (x0: Int, y0: Int, x1: Int, y1: Int),
                                 zMeters: Double) throws -> DepthField {
        try field(width: width, height: height) { x, y in
            (x >= rect.x0 && x < rect.x1 && y >= rect.y0 && y < rect.y1) ? zMeters : nil
        }
    }

    /// Thin vertical bar `barWidthPx` wide centered at `xCenter`, at `zMeters`;
    /// invalid elsewhere (design's "thin geometry at known Z").
    public static func thinBar(width: Int, height: Int,
                               xCenter: Int, barWidthPx: Int, zMeters: Double) throws -> DepthField {
        let half = max(barWidthPx, 1) / 2
        return try field(width: width, height: height) { x, _ in
            abs(x - xCenter) <= half ? zMeters : nil
        }
    }

    /// Slanted plane given a camera-space plane `n·X = planeDistance` (n need not
    /// be unit). Axial Z at pixel (u,v): with ray dir `(dx,dy,1)`,
    /// `Z = planeDistance / (n · dir)`. Invalid where the plane is behind /
    /// parallel or Z ≤ 0.
    public static func slantedPlane(width: Int, height: Int, intrinsics K: PinholeIntrinsics,
                                    normal n: SIMD3<Double>, planeDistance d: Double) throws -> DepthField {
        try field(width: width, height: height) { x, y in
            let dx = (Double(x) - K.cx) / K.fx
            let dy = (Double(y) - K.cy) / K.fy
            let denom = n.x * dx + n.y * dy + n.z * 1.0
            if abs(denom) < 1e-9 { return nil }
            let z = d / denom
            return z > 0 ? z : nil
        }
    }

    /// Front surface of a sphere (camera-space `center`, `radius` meters). Axial
    /// Z is the nearest positive intersection of the ray `(dx,dy,1)` with the
    /// sphere; invalid outside the silhouette.
    public static func sphere(width: Int, height: Int, intrinsics K: PinholeIntrinsics,
                              center c: SIMD3<Double>, radius r: Double) throws -> DepthField {
        try field(width: width, height: height) { x, y in
            let dx = (Double(x) - K.cx) / K.fx
            let dy = (Double(y) - K.cy) / K.fy
            let dir = SIMD3(dx, dy, 1.0)
            let A = simd_dot(dir, dir)
            let B = -2.0 * simd_dot(dir, c)
            let C = simd_dot(c, c) - r * r
            let disc = B * B - 4 * A * C
            if disc < 0 { return nil }
            let s = disc.squareRoot()
            let t0 = (-B - s) / (2 * A)
            let t1 = (-B + s) / (2 * A)
            let t = t0 > 0 ? t0 : (t1 > 0 ? t1 : nil)
            // point = t * dir, and dir.z == 1 → axial Z == t.
            return t
        }
    }

    // MARK: - Character plate

    /// Rectangular premultiplied character plate of constant straight color
    /// `rgb`/`alpha` inside `rect` (alpha 0 outside), plus a constant character
    /// axial-depth plate `charZ` inside the rect (NaN outside). Returns the color
    /// plate and its exactly-paired depth field.
    public static func rectangleCharacter(width: Int, height: Int,
                                          rect: (x0: Int, y0: Int, x1: Int, y1: Int),
                                          rgb: SIMD3<Double>, alpha: Double,
                                          charZMeters: Double) throws -> (ColorPlate, DepthField) {
        var oracle = [SIMD4<Double>](repeating: .zero, count: width * height)
        let color = try DepthPixelIO.makeColor(width: width, height: height) { x, y -> SIMD4<Float> in
            let inside = x >= rect.x0 && x < rect.x1 && y >= rect.y0 && y < rect.y1
            let a = inside ? alpha : 0.0
            let pr = rgb.x * a, pg = rgb.y * a, pb = rgb.z * a // premultiplied
            oracle[y * width + x] = SIMD4(pr, pg, pb, a)
            return SIMD4(Float(pr), Float(pg), Float(pb), Float(a))
        }
        let depth = try rectangle(width: width, height: height, rect: rect, zMeters: charZMeters)
        return (ColorPlate(buffer: color, rgbaPremul: oracle, width: width, height: height), depth)
    }

    /// A constant opaque color plate (e.g. the real-scene background plate).
    public static func solidPlate(width: Int, height: Int,
                                  rgb: SIMD3<Double>, alpha: Double = 1) throws -> ColorPlate {
        var oracle = [SIMD4<Double>](repeating: .zero, count: width * height)
        let buf = try DepthPixelIO.makeColor(width: width, height: height) { x, y -> SIMD4<Float> in
            let pr = rgb.x * alpha, pg = rgb.y * alpha, pb = rgb.z * alpha
            oracle[y * width + x] = SIMD4(pr, pg, pb, alpha)
            return SIMD4(Float(pr), Float(pg), Float(pb), Float(alpha))
        }
        return ColorPlate(buffer: buf, rgbaPremul: oracle, width: width, height: height)
    }

    /// A fully transparent plate — compositing the character over it returns the
    /// visibility-scaled character exactly (used to prove "rgb AND alpha scaled").
    public static func transparentPlate(width: Int, height: Int) throws -> ColorPlate {
        try solidPlate(width: width, height: height, rgb: .zero, alpha: 0)
    }

    // MARK: - Known-a,b relative-depth map

    /// Build a RELATIVE (inverse-depth-like) map `r` from a metric scene such
    /// that `1/Z = a·r + b` holds exactly, i.e. `r = (1/Z − b) / a`. Recovering
    /// `a,b` from correspondences drawn from this map is the central-risk test.
    /// Returns the relative map (row-major, nil where scene invalid).
    public static func relativeFromMetric(_ metric: DepthField, a: Double, b: Double) -> [Double?] {
        precondition(abs(a) > 1e-12, "a must be non-zero")
        return metric.z.map { zOpt in
            guard let z = zOpt, z > 0 else { return nil }
            return (1.0 / z - b) / a
        }
    }
}
