import CoreMedia
import Foundation

/// The single timing authority for the whole pipeline (DESIGN.md §3.3).
///
/// All media — Mac capture, screen capture, network feeds — is timestamped in
/// *house time*: the Mac's host clock. Mac capture APIs already deliver
/// host-clock PTS; remote devices translate into house time before sending
/// (see PrismLink clock sync).
public enum HouseClock {
    /// The host time clock shared with AVFoundation / ScreenCaptureKit capture PTS.
    public static let clock: CMClock = CMClockGetHostTimeClock()

    /// Current house time.
    public static func now() -> CMTime {
        CMClockGetTime(clock)
    }

    /// Current house time in seconds (for logs/metrics, not media math).
    public static func nowSeconds() -> Double {
        now().seconds
    }
}

public extension CMTime {
    /// Millisecond delta (self − other), for latency metrics.
    func millisecondsSince(_ other: CMTime) -> Double {
        (CMTimeSubtract(self, other)).seconds * 1000.0
    }
}
