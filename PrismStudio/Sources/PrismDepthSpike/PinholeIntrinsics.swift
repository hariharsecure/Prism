import Foundation

/// Rectified pinhole intrinsics `K = {fx, fy, cx, cy}` in pixels at a stated
/// reference resolution (`docs/UNREAL_AR_3D_CHARACTER_DESIGN.md`,
/// "Intrinsics: obtain, estimate, and freeze"). Canonical camera axes:
/// +X image-right, +Y image-down, +Z optical-axis forward. Pixel centers at
/// integer (u, v); origin top-left.
///
/// Prism's comparison contract is **positive optical-axis camera Z in meters**
/// (the design's "canonical axial-Z semantic"). A source that reports Euclidean
/// range *along the ray* must be converted with `axialZ(fromRayRange:)`.
public struct PinholeIntrinsics: Equatable, Sendable {
    public var fx: Double
    public var fy: Double
    public var cx: Double
    public var cy: Double
    /// Reference width/height these intrinsics are expressed at (documentation
    /// + invalidation key; not used by the axial/ray math which is per-pixel).
    public var referenceWidth: Int
    public var referenceHeight: Int

    public init(fx: Double, fy: Double, cx: Double, cy: Double,
                referenceWidth: Int, referenceHeight: Int) {
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
        self.referenceWidth = referenceWidth; self.referenceHeight = referenceHeight
    }

    /// Normalized ray direction *before* normalization at pixel (u, v):
    /// `((u-cx)/fx, (v-cy)/fy, 1)`. Its length is the axial→ray scale factor.
    @inline(__always)
    public func rayScale(u: Double, v: Double) -> Double {
        let dx = (u - cx) / fx
        let dy = (v - cy) / fy
        return (dx * dx + dy * dy + 1.0).squareRoot()
    }

    /// Along-ray Euclidean distance for a point at optical-axis depth `axialZ`
    /// imaged at pixel (u, v). At the principal point this equals `axialZ`.
    @inline(__always)
    public func rayRange(fromAxialZ axialZ: Double, u: Double, v: Double) -> Double {
        axialZ * rayScale(u: u, v: v)
    }

    /// Optical-axis depth Z for a point at along-ray distance `rayRange` imaged
    /// at pixel (u, v). Inverse of `rayRange(fromAxialZ:)`.
    @inline(__always)
    public func axialZ(fromRayRange rayRange: Double, u: Double, v: Double) -> Double {
        rayRange / rayScale(u: u, v: v)
    }

    /// Back-project a pixel + axial depth to a camera-space 3D point
    /// `X = (u-cx)Z/fx, Y = (v-cy)Z/fy, Z` (design: Prism can reconstruct X,Y
    /// from rectified K and axial Z without a transported world-position pass).
    @inline(__always)
    public func unproject(u: Double, v: Double, axialZ: Double) -> SIMD3<Double> {
        SIMD3((u - cx) * axialZ / fx, (v - cy) * axialZ / fy, axialZ)
    }
}
