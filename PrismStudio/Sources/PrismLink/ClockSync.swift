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

    /// Plausibility fence for a peer-reported clock field. Both device epoch
    /// nanos (wall-clock in 2026 ≈ 1.75e18) and house−device offset live far
    /// below this; values above it are garbage/hostile (a paired peer sending
    /// ±5e18 would overflow the regression's Int64 math), so they never enter
    /// the window. Comfortably under Int64.max so any later difference of two
    /// admitted samples also cannot overflow.
    static let maxPlausibleNanos: Int64 = 4_000_000_000_000_000_000 // ~126 years of ns

    public init(window: Int = 64) {
        self.window = max(2, window)
    }

    /// Ingest one (device time, offset) measurement. Fields are attacker-
    /// controlled (LinkStats JSON), so implausible magnitudes are dropped
    /// rather than admitted; valid samples are stored unchanged.
    public mutating func add(deviceNanos: Int64, offsetNanos: Int64) {
        // `.magnitude` (not `abs`) so Int64.min does not itself trap.
        let bound = UInt64(Self.maxPlausibleNanos)
        guard deviceNanos.magnitude <= bound, offsetNanos.magnitude <= bound else { return }
        samples.append((deviceNanos, offsetNanos))
        if samples.count > window {
            samples.removeFirst(samples.count - window)
        }
    }

    /// Rounds a Double to Int64, never trapping on NaN/±inf/out-of-range
    /// (clamps to the representable range; 0 for NaN).
    private static func safeInt64(_ d: Double) -> Int64 {
        let r = d.rounded()
        if let v = Int64(exactly: r) { return v }
        if r.isNaN { return 0 }
        return r > 0 ? Int64.max : Int64.min
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
        // Difference in Int64 first (exact, small — byte-identical to the old
        // path for valid input) but fall back to a Double subtraction on the
        // rare overflow instead of trapping.
        let x0 = samples[0].deviceNanos
        let y0 = samples[0].offsetNanos
        let points = samples.map { s in
            (x: Self.centered(s.deviceNanos, x0), y: Self.centered(s.offsetNanos, y0))
        }
        guard let fit = linearFit(points) else {
            return Estimate(offsetNanos: last.offsetNanos, atDeviceNanos: at, skewPPM: 0,
                            sampleCount: samples.count)
        }
        let predicted = fit.slope * Self.centered(at, x0) + fit.intercept + Double(y0)
        return Estimate(offsetNanos: Self.safeInt64(predicted), atDeviceNanos: at,
                        skewPPM: fit.slope * 1_000_000, sampleCount: samples.count)
    }

    /// `Double(v − origin)`, overflow-safe: exact for admitted samples (whose
    /// difference cannot overflow Int64), Double-subtracts rather than trapping
    /// otherwise.
    private static func centered(_ v: Int64, _ origin: Int64) -> Double {
        let (diff, overflow) = v.subtractingReportingOverflow(origin)
        return overflow ? (Double(v) - Double(origin)) : Double(diff)
    }
}
