import Foundation

/// An exact rational number of seconds, `N/Ds` — the *only* time representation
/// FCPXML accepts. Apple's FCPXML reference: "All time values … are expressed as
/// a rational number of seconds", e.g. `1001/30000s` for one NTSC (29.97) frame.
///
/// Values are always stored reduced (via GCD) with a positive denominator, so
/// `0.5s → 1/2s`, `2.5s → 5/2s`, and `0s → 0s`.
public struct RationalTime: Equatable, Sendable, CustomStringConvertible {
    public let numerator: Int64
    public let denominator: Int64

    /// Constructs directly from a fraction; normalizes sign and reduces.
    public init(numerator: Int64, denominator: Int64) {
        precondition(denominator != 0, "RationalTime denominator must be non-zero")
        var n = numerator
        var d = denominator
        if d < 0 { n = -n; d = -d }            // keep denominator positive
        let g = RationalTime.gcd(n < 0 ? -n : n, d)
        self.numerator = n / g
        self.denominator = d / g
    }

    /// Quantizes `seconds` to the nearest tick at `timescale` ticks/second, then
    /// reduces. This is the Double-seconds → `"N/Ds"` converter the exporter uses:
    /// choosing the timescale to equal the format's frame-duration denominator
    /// makes every emitted time land on an exact frame boundary.
    public init(seconds: Double, timescale: Int64) {
        precondition(timescale > 0, "timescale must be positive")
        let ticks = (seconds * Double(timescale)).rounded()
        self.init(numerator: Int64(ticks), denominator: timescale)
    }

    /// The value as a Double (for logs/tests — never for chaining media math).
    public var seconds: Double { Double(numerator) / Double(denominator) }

    /// FCPXML form: `"N/Ds"`, collapsing to `"Ns"` when the denominator reduces
    /// to 1 (so `0/1 → "0s"`, `5/1 → "5s"`).
    public var fcpString: String {
        denominator == 1 ? "\(numerator)s" : "\(numerator)/\(denominator)s"
    }

    public var description: String { fcpString }

    /// Parses an FCPXML time string (`"N/Ds"` or `"Ns"`). Returns nil on malformed
    /// input. Used by the self-test to round-trip emitted times.
    public static func parse(_ string: String) -> RationalTime? {
        guard string.hasSuffix("s") else { return nil }
        let body = string.dropLast()
        if let slash = body.firstIndex(of: "/") {
            guard let n = Int64(body[body.startIndex..<slash]),
                  let d = Int64(body[body.index(after: slash)...]) else { return nil }
            return RationalTime(numerator: n, denominator: d)
        }
        guard let n = Int64(body) else { return nil }
        return RationalTime(numerator: n, denominator: 1)
    }

    static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a == 0 ? 1 : a          // avoid divide-by-zero for 0/D
    }
}

/// A video frame rate expressed as an exact frame duration, `frameDurationTicks /
/// timescale` seconds. The `timescale` doubles as the sequence timebase, so
/// integer rates (60 → 1000/60000) and NTSC rates (59.94 → 1001/60000) both land
/// on exact frame boundaries when emitting sequence times.
public struct FrameRate: Equatable, Sendable {
    /// Frame duration numerator, in `timescale` ticks.
    public let frameDurationTicks: Int64
    /// Ticks per second; also the sequence time timebase.
    public let timescale: Int64

    public init(frameDurationTicks: Int64, timescale: Int64) {
        precondition(frameDurationTicks > 0 && timescale > 0, "frame rate ticks/timescale must be positive")
        self.frameDurationTicks = frameDurationTicks
        self.timescale = timescale
    }

    /// Nominal frames per second.
    public var fps: Double { Double(timescale) / Double(frameDurationTicks) }

    /// Frame duration as a reduced rational (what `<format frameDuration>` emits).
    public var frameDuration: RationalTime {
        RationalTime(numerator: frameDurationTicks, denominator: timescale)
    }

    /// Emits `seconds` as an FCPXML time string quantized to this rate's timebase.
    public func fcpTime(_ seconds: Double) -> String {
        RationalTime(seconds: seconds, timescale: timescale).fcpString
    }

    public static let fps2398 = FrameRate(frameDurationTicks: 1001, timescale: 24000) // 23.976
    public static let fps24   = FrameRate(frameDurationTicks: 1000, timescale: 24000)
    public static let fps25   = FrameRate(frameDurationTicks: 1000, timescale: 25000)
    public static let fps2997 = FrameRate(frameDurationTicks: 1001, timescale: 30000) // 29.97
    public static let fps30   = FrameRate(frameDurationTicks: 1000, timescale: 30000)
    public static let fps50   = FrameRate(frameDurationTicks: 1000, timescale: 50000)
    public static let fps5994 = FrameRate(frameDurationTicks: 1001, timescale: 60000) // 59.94
    public static let fps60   = FrameRate(frameDurationTicks: 1000, timescale: 60000)

    static let presets: [FrameRate] = [.fps2398, .fps24, .fps25, .fps2997, .fps30, .fps50, .fps5994, .fps60]

    /// Best-effort mapping from a plain fps number: snaps to a known broadcast rate
    /// within tolerance, else builds a generic 1/1000-tick timebase.
    public init(fps: Double) {
        if let match = FrameRate.presets.first(where: { abs($0.fps - fps) < 0.01 }) {
            self = match
            return
        }
        let ts: Int64 = 60000
        self.init(frameDurationTicks: max(1, Int64((Double(ts) / fps).rounded())), timescale: ts)
    }
}
