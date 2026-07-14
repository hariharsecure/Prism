import Foundation
import simd

/// Targets/limits for AutoColor. Defaults are conservative broadcast-ish
/// choices; all fields are tunable.
public struct AutoColorTargets: Sendable, Codable, Equatable {
    /// Desired scene log-average in **linear** light (photographic mid-gray).
    public var midGrayLinear: Double
    /// Gamma-encoded luma ceiling the 99th percentile may be pushed to when
    /// raising exposure (highlight protection).
    public var highlightCeiling: Double
    /// Clamp on suggested |exposure| in stops.
    public var maxExposureStops: Double
    /// Clamp on suggested |temperature| and |tint|.
    public var maxWhiteBalance: Double

    public init(midGrayLinear: Double = 0.18,
                highlightCeiling: Double = 0.97,
                maxExposureStops: Double = 3,
                maxWhiteBalance: Double = 0.75) {
        self.midGrayLinear = midGrayLinear
        self.highlightCeiling = highlightCeiling
        self.maxExposureStops = maxExposureStops
        self.maxWhiteBalance = maxWhiteBalance
    }
}

/// Suggested *deltas* to fold into a source's grade. Pure data.
public struct AutoColorSuggestion: Sendable, Codable, Equatable {
    public var exposure: Double
    public var temperature: Double
    public var tint: Double

    public init(exposure: Double = 0, temperature: Double = 0, tint: Double = 0) {
        self.exposure = exposure
        self.temperature = temperature
        self.tint = tint
    }

    public static let none = AutoColorSuggestion()

    /// `grade` with this suggestion's deltas added.
    public func applied(to grade: ColorGrade) -> ColorGrade {
        var g = grade
        g.exposure += exposure
        g.temperature += temperature
        g.tint += tint
        return g
    }
}

/// Pure `FrameStats → grade-delta` math (unit-verifiable, no GPU).
///
/// - **White balance — gray world:** assume the scene averages to neutral;
///   the per-channel gains that equalize the (approximately linearized)
///   channel means are inverted through `WhiteBalanceModel` — the *same*
///   model the GPU kernel applies — so a suggestion, once applied,
///   reproduces the computed gains exactly (uniform-scene case).
/// - **Exposure:** stops that move the linear log-average luma to
///   `midGrayLinear`, capped so the predicted 99th-percentile luma stays
///   under `highlightCeiling` (never fix midtones by clipping highlights).
///
/// Space bookkeeping: `FrameStats` measures gamma-encoded values; means are
/// linearized with the same 2.2 power the processor uses. `mean(x)^2.2` vs
/// `mean(x^2.2)` is a stated approximation (exact for uniform regions);
/// `logAverageLuma` is a geometric mean, so its 2.2-power *is* exact.
public enum AutoColor {
    public static func suggest(from stats: FrameStats,
                               targets: AutoColorTargets = AutoColorTargets()) -> AutoColorSuggestion {
        guard stats.sampleCount > 0 else { return .none }

        // --- Gray-world white balance ---
        let eps = 1e-5
        let lin = SIMD3<Double>(pow(max(stats.meanR, eps), 2.2),
                                pow(max(stats.meanG, eps), 2.2),
                                pow(max(stats.meanB, eps), 2.2))
        let average = (lin.x + lin.y + lin.z) / 3
        let gains = SIMD3<Double>(average / lin.x, average / lin.y, average / lin.z)
        var (temperature, tint) = WhiteBalanceModel.temperatureTint(forGains: gains)
        temperature = temperature.clamped(to: -targets.maxWhiteBalance...targets.maxWhiteBalance)
        tint = tint.clamped(to: -targets.maxWhiteBalance...targets.maxWhiteBalance)

        // --- Exposure from log-average luma, highlight-capped ---
        let currentLinear = pow(max(stats.logAverageLuma, eps), 2.2)
        var exposure = log2(targets.midGrayLinear / currentLinear)
        if exposure > 0 {
            // Predicted gamma-luma scales by 2^(stops/2.2) under our transfer.
            let p99 = max(stats.lumaPercentile(0.99), eps)
            let headroom = 2.2 * log2(targets.highlightCeiling / p99)
            exposure = min(exposure, max(headroom, 0))
        }
        exposure = exposure.clamped(to: -targets.maxExposureStops...targets.maxExposureStops)

        return AutoColorSuggestion(exposure: exposure, temperature: temperature, tint: tint)
    }
}

/// Exponential smoothing with a configurable time constant, in seconds:
/// after `timeConstant` seconds of a steady target the output has covered
/// ~63% of the step; it approaches asymptotically and **never overshoots** —
/// this is what keeps auto corrections from visibly pumping.
public struct TemporalSmoother: Sendable, Codable, Equatable {
    public var timeConstant: Double
    private var value: Double?
    private var lastTime: Double?

    /// - Parameter timeConstant: seconds; larger = slower, calmer corrections.
    public init(timeConstant: Double = 2.0) {
        precondition(timeConstant > 0)
        self.timeConstant = timeConstant
    }

    /// Current smoothed value (nil until the first `update`).
    public var current: Double? { value }

    /// Feed a new target observed at `time` (seconds, monotonic — house-time
    /// seconds in the engine). Returns the smoothed value.
    @discardableResult
    public mutating func update(target: Double, at time: Double) -> Double {
        guard let previous = value, let t0 = lastTime, time > t0 else {
            value = value ?? target
            lastTime = time
            return value!
        }
        let alpha = 1 - exp(-(time - t0) / timeConstant)
        let next = previous + (target - previous) * alpha
        value = next
        lastTime = time
        return next
    }

    /// Forget history (e.g. on scene cut — corrections may jump once, then settle).
    public mutating func reset() {
        value = nil
        lastTime = nil
    }
}

/// Stateful AutoColor: raw per-analysis suggestions smoothed per parameter,
/// so a light flicker or a passing object never pumps the correction.
public struct SmoothedAutoColor: Sendable {
    public var targets: AutoColorTargets
    private var exposureSmoother: TemporalSmoother
    private var temperatureSmoother: TemporalSmoother
    private var tintSmoother: TemporalSmoother

    public init(targets: AutoColorTargets = AutoColorTargets(), timeConstant: Double = 2.0) {
        self.targets = targets
        self.exposureSmoother = TemporalSmoother(timeConstant: timeConstant)
        self.temperatureSmoother = TemporalSmoother(timeConstant: timeConstant)
        self.tintSmoother = TemporalSmoother(timeConstant: timeConstant)
    }

    /// Fold one analysis into the smoothed suggestion.
    public mutating func update(stats: FrameStats, at time: Double) -> AutoColorSuggestion {
        let raw = AutoColor.suggest(from: stats, targets: targets)
        return AutoColorSuggestion(
            exposure: exposureSmoother.update(target: raw.exposure, at: time),
            temperature: temperatureSmoother.update(target: raw.temperature, at: time),
            tint: tintSmoother.update(target: raw.tint, at: time))
    }

    public mutating func reset() {
        exposureSmoother.reset()
        temperatureSmoother.reset()
        tintSmoother.reset()
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
