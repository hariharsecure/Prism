import XCTest
import PrismSources

/// XCTest gate for `MovieSource` (video-file source). The heavy logic lives in
/// `MovieSourceSelfTest.run()` (synthetic-clip loop/motion proof + a guarded
/// real-asset decode); this wires it into `swift test` / CI. The real asset is
/// skipped gracefully inside `run()` when absent, so this never hard-fails CI on
/// a missing file.
final class MovieSourceTests: XCTestCase {
    /// Happy-path proof: synthetic-clip loop/motion/shape + guarded real-asset
    /// decode (with the M11 raised motion threshold).
    func testMovieSource() throws {
        try MovieSourceSelfTest.run()
    }

    /// Lifecycle / timing / edge-case gates for MOVIESOURCE_FIX_LEDGER M1–M10:
    /// audio house-time PTS, single-source A/V sync, stop-from-callback (no
    /// deadlock), corrupt-file (no busy-spin), EOF terminal state + restart,
    /// concurrent start/stop atomicity, audio-only typed error, late-decode drop
    /// (no catch-up burst), and rotated nativeSize.
    func testMovieSourceLifecycle() throws {
        try MovieSourceLifecycleTests.run()
    }
}
