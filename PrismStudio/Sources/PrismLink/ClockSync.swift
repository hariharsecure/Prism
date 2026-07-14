import CoreMedia
import Foundation
import PrismCore

/// Receiver-side clock sync (DESIGN.md §3.4).
///
/// The Mac is the timing authority: it never adjusts anything. It (a) answers
/// clockPings by stamping house time, and (b) passively tracks each peer's
/// reported offset measurements with a linear regression so the engine can
/// display per-device offset/skew and flag drifting devices.
public enum LinkClock {
    /// Current house time in nanoseconds (house clock = host time clock, §3.3).
    public static func houseNanos() -> Int64 {
        let t = CMTimeConvertScale(HouseClock.now(), timescale: 1_000_000_000,
                                   method: .default)
        return t.value
    }

    /// Pure: builds the pong for a ping given the receive/send house stamps.
    public static func pong(for ping: LinkClockPing, receivedAtHouseNanos t2: Int64,
                            sendingAtHouseNanos t3: Int64) -> LinkClockPong {
        LinkClockPong(seq: ping.seq, t1: ping.t1, t2: t2, t3: t3)
    }
}

/// Ordinary least-squares fit of y = slope·x + intercept. Pure.
/// Returns nil for < 2 points or a degenerate (all-same-x) input.
public func linearFit(_ points: [(x: Double, y: Double)]) -> (slope: Double, intercept: Double)? {
    let n = Double(points.count)
    guard points.count >= 2 else { return nil }
    var sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumXY = 0.0
    for p in points {
        sumX += p.x
        sumY += p.y
        sumXX += p.x * p.x
        sumXY += p.x * p.y
    }
    let denominator = n * sumXX - sumX * sumX
    guard abs(denominator) > .ulpOfOne * max(1, abs(sumXX)) * n else { return nil }
    let slope = (n * sumXY - sumX * sumY) / denominator
    let intercept = (sumY - slope * sumX) / n
    return (slope, intercept)
}

/// Tracks one peer's clock offset and skew from its reported measurements:
/// samples of (device clock time, house−device offset). A straight-line fit
/// over the last `window` samples gives offset-now and skew (drift rate).
///
/// Pure state machine — no clocks, no I/O; fully unit-exercisable.
public struct ClockSkewEstimator: Sendable {
    public struct Estimate: Sendable {
        /// Best-estimate (house − device) offset at device time `atDeviceNanos`.
        public let offsetNanos: Int64
        public let atDeviceNanos: Int64
        /// Drift rate in parts-per-million (ns of offset change per ms of device time × 1000).
        public let skewPPM: Double
        public let sampleCount: Int
    }

    private var samples: [(deviceNanos: Int64, offsetNanos: Int64)] = []
    private let window: Int

    public init(window: Int = 64) {
        self.window = max(2, window)
    }

    public mutating func add(deviceNanos: Int64, offsetNanos: Int64) {
        samples.append((deviceNanos, offsetNanos))
        if samples.count > window {
            samples.removeFirst(samples.count - window)
        }
    }

    public var sampleCount: Int { samples.count }

    /// Regression-based estimate at `deviceNanos` (defaults to the newest sample's time).
    /// With one sample, returns it directly with skew 0; nil with no samples.
    public func estimate(atDeviceNanos: Int64? = nil) -> Estimate? {
        guard let last = samples.last else { return nil }
        let at = atDeviceNanos ?? last.deviceNanos
        guard samples.count >= 2 else {
            return Estimate(offsetNanos: last.offsetNanos, atDeviceNanos: at, skewPPM: 0,
                            sampleCount: 1)
        }
        // Center on the first sample to keep the math well-conditioned
        // (nanosecond epochs are ~1e18; squaring them loses precision).
        let x0 = samples[0].deviceNanos
        let y0 = samples[0].offsetNanos
        let points = samples.map { (x: Double($0.deviceNanos - x0), y: Double($0.offsetNanos - y0)) }
        guard let fit = linearFit(points) else {
            return Estimate(offsetNanos: last.offsetNanos, atDeviceNanos: at, skewPPM: 0,
                            sampleCount: samples.count)
        }
        let predicted = fit.slope * Double(at - x0) + fit.intercept + Double(y0)
        return Estimate(offsetNanos: Int64(predicted.rounded()), atDeviceNanos: at,
                        skewPPM: fit.slope * 1_000_000, sampleCount: samples.count)
    }
}
