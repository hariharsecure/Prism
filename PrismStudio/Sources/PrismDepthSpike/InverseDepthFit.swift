import Foundation

/// A single depth correspondence used to fit the inverse-depth affine map.
/// `relative` is the monocular model's raw (relative / inverse-depth-like)
/// output `d`; `metricZ` is the known metric optical-axis depth at that region.
public struct DepthCorrespondence: Sendable, Equatable {
    public var relative: Double
    public var metricZ: Double
    public init(relative: Double, metricZ: Double) {
        self.relative = relative
        self.metricZ = metricZ
    }
}

/// Result of the robust inverse-depth affine fit `1/Z ≈ a·d + b`, plus the
/// diagnostics the design calls "the point" of Phase 0 (residuals, inliers).
public struct InverseDepthFitResult: Sendable, Equatable {
    /// Inverse-depth scale.
    public var a: Double
    /// Inverse-depth shift.
    public var b: Double
    /// Indices (into the input array) classified as inliers by the robust step.
    public var inlierIndices: [Int]
    /// RMS residual (in inverse-depth units, 1/m) over the inliers.
    public var rmsResidualInliers: Double
    /// Max absolute residual over the inliers.
    public var maxResidualInliers: Double
    /// Max absolute residual over ALL correspondences (outliers included).
    public var maxResidualAll: Double
    /// Number of robust re-weighting / RANSAC iterations actually run.
    public var iterations: Int

    public var inlierCount: Int { inlierIndices.count }
}

/// Robust fit of the inverse-depth affine map that carries a RELATIVE monocular
/// depth map into a common metric space
/// (`docs/UNREAL_AR_3D_CHARACTER_DESIGN.md`, "Central risk: aligning monocular
/// and UE depth"):
///
///     inverseZ_metric(u,v) = a · r(u,v) + b
///     sceneZ_m(u,v)        = 1 / inverseZ_metric(u,v)
///
/// Both `a` and `b` are generally needed (a single scale is insufficient for
/// affine-invariant relative depth). This is THE central-risk math; it is fit
/// in the *inverse-depth* domain where the model is linear, exactly as the
/// design prescribes, and reports residuals so drift can be monitored.
public enum InverseDepthFit {

    public struct Options: Sendable {
        /// RANSAC inlier threshold on the inverse-depth residual |a·d + b − 1/Z|,
        /// in 1/m. Points within this band are inliers.
        public var inlierThreshold: Double
        /// RANSAC hypotheses to try. 0 disables RANSAC (plain least squares only).
        public var ransacIterations: Int
        /// Iteratively-reweighted-least-squares (Huber) refinement passes after
        /// the inlier set is chosen. 0 disables IRLS.
        public var irlsIterations: Int
        /// Huber delta (1/m) for the IRLS weight.
        public var huberDelta: Double
        /// Deterministic RANSAC seed (reproducibility — a Phase-0 requirement).
        public var seed: UInt64

        public init(inlierThreshold: Double = 0.02,
                    ransacIterations: Int = 200,
                    irlsIterations: Int = 5,
                    huberDelta: Double = 0.01,
                    seed: UInt64 = 0x9E3779B97F4A7C15) {
            self.inlierThreshold = inlierThreshold
            self.ransacIterations = ransacIterations
            self.irlsIterations = irlsIterations
            self.huberDelta = huberDelta
            self.seed = seed
        }
    }

    /// Ordinary least-squares line fit `y ≈ a·x + b` with optional per-point
    /// weights. Closed-form 2×2 normal equations in Double. Returns nil if the
    /// design matrix is degenerate (all x identical / zero total weight).
    static func weightedLeastSquares(x: [Double], y: [Double],
                                     w: [Double]? = nil) -> (a: Double, b: Double)? {
        let n = x.count
        guard n >= 2, y.count == n else { return nil }
        var sw = 0.0, swx = 0.0, swy = 0.0, swxx = 0.0, swxy = 0.0
        for i in 0..<n {
            let wi = w?[i] ?? 1.0
            let xi = x[i], yi = y[i]
            sw += wi
            swx += wi * xi
            swy += wi * yi
            swxx += wi * xi * xi
            swxy += wi * xi * yi
        }
        let det = sw * swxx - swx * swx
        guard abs(det) > 1e-18, sw > 0 else { return nil }
        let a = (sw * swxy - swx * swy) / det
        let b = (swxx * swy - swx * swxy) / det
        return (a, b)
    }

    /// Robustly recover `a, b` from correspondences, rejecting outliers.
    ///
    /// Pipeline: RANSAC (deterministic, seeded) proposes 2-point lines in the
    /// inverse-depth domain and keeps the largest consensus set → least-squares
    /// refit on inliers → optional Huber IRLS. Falls back to plain least squares
    /// when RANSAC is disabled.
    public static func fit(_ correspondences: [DepthCorrespondence],
                           options: Options = Options()) throws -> InverseDepthFitResult {
        let n = correspondences.count
        guard n >= 2 else {
            throw DepthSpikeError.fitDegenerate("need ≥2 correspondences, got \(n)")
        }
        // Work in the linear inverse-depth domain: x = d (relative), y = 1/Z.
        var xs = [Double](repeating: 0, count: n)
        var ys = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let c = correspondences[i]
            guard c.metricZ > 0 else {
                throw DepthSpikeError.fitDegenerate("non-positive metricZ at index \(i): \(c.metricZ)")
            }
            xs[i] = c.relative
            ys[i] = 1.0 / c.metricZ
        }

        var bestInliers: [Int] = Array(0..<n)
        var iterations = 0

        if options.ransacIterations > 0 && n > 2 {
            var rng = SplitMix64(seed: options.seed)
            var bestCount = -1
            for _ in 0..<options.ransacIterations {
                iterations += 1
                let i = Int(rng.next() % UInt64(n))
                var j = Int(rng.next() % UInt64(n))
                if j == i { j = (j + 1) % n }
                let dx = xs[j] - xs[i]
                if abs(dx) < 1e-12 { continue } // vertical / degenerate sample
                let a = (ys[j] - ys[i]) / dx
                let b = ys[i] - a * xs[i]
                var inliers: [Int] = []
                inliers.reserveCapacity(n)
                for k in 0..<n where abs(a * xs[k] + b - ys[k]) <= options.inlierThreshold {
                    inliers.append(k)
                }
                if inliers.count > bestCount {
                    bestCount = inliers.count
                    bestInliers = inliers
                }
            }
        }

        guard bestInliers.count >= 2,
              var model = weightedLeastSquares(x: bestInliers.map { xs[$0] },
                                               y: bestInliers.map { ys[$0] }) else {
            throw DepthSpikeError.fitDegenerate("no non-degenerate consensus set")
        }

        // Huber IRLS refinement over the inlier set.
        for _ in 0..<options.irlsIterations {
            iterations += 1
            let xi = bestInliers.map { xs[$0] }
            let yi = bestInliers.map { ys[$0] }
            var w = [Double](repeating: 1, count: xi.count)
            for k in 0..<xi.count {
                let r = abs(model.a * xi[k] + model.b - yi[k])
                w[k] = r <= options.huberDelta ? 1.0 : options.huberDelta / max(r, 1e-12)
            }
            guard let refined = weightedLeastSquares(x: xi, y: yi, w: w) else { break }
            model = refined
        }

        // Diagnostics.
        var sumSq = 0.0, maxIn = 0.0
        for idx in bestInliers {
            let r = abs(model.a * xs[idx] + model.b - ys[idx])
            sumSq += r * r
            maxIn = max(maxIn, r)
        }
        let rms = (sumSq / Double(max(bestInliers.count, 1))).squareRoot()
        var maxAll = 0.0
        for k in 0..<n { maxAll = max(maxAll, abs(model.a * xs[k] + model.b - ys[k])) }

        return InverseDepthFitResult(a: model.a, b: model.b,
                                     inlierIndices: bestInliers.sorted(),
                                     rmsResidualInliers: rms,
                                     maxResidualInliers: maxIn,
                                     maxResidualAll: maxAll,
                                     iterations: iterations)
    }

    /// Apply the fitted map to a relative value → metric optical-axis Z.
    /// Returns `nil` (invalid) when the implied inverse depth is ≤ 0.
    public static func metricZ(relative d: Double, a: Double, b: Double) -> Double? {
        let inv = a * d + b
        return inv > 0 ? 1.0 / inv : nil
    }
}

/// Small deterministic PRNG (SplitMix64) — reproducible RANSAC without pulling
/// in a platform RNG whose sequence could drift across OS versions.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
