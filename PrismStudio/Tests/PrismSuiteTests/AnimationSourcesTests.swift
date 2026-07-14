import XCTest
import CoreVideo
import PrismCompositor
import PrismCore
import PrismSources

/// XCTest gate for the three animation-overlay sources (`AnimatedLogoSource`,
/// `TickerSource`, `CreditsSource`). The heavy, deterministic logic — generated
/// logo PNG, per-source motion / transparency / seamless-wrap / terminal-state /
/// bad-input asserts, and eyeball PNG dumps — lives in
/// `AnimationSourcesSelfTest.run()` (same module as the sources, so it can drive
/// their internal deterministic `render(...)` helpers). This wires it into
/// `swift test` / CI and adds a couple of public-API smoke checks.
final class AnimationSourcesTests: XCTestCase {

    /// Full deterministic + live self-test suite (motion, transparency, wrap,
    /// terminal-state, typed bad-input, PNG dumps).
    func testAnimationSourcesSelfTest() throws {
        try AnimationSourcesSelfTest.run()
    }

    /// Public-API smoke: bad input throws the typed `SourceError`.
    func testTypedBadInput() {
        XCTAssertThrowsError(try TickerSource(text: "")) { error in
            guard case SourceError.invalidConfiguration = error else {
                return XCTFail("expected invalidConfiguration, got \(error)")
            }
        }
        XCTAssertThrowsError(try CreditsSource(lines: [])) { error in
            guard case SourceError.invalidConfiguration = error else {
                return XCTFail("expected invalidConfiguration, got \(error)")
            }
        }
        XCTAssertThrowsError(try AnimatedLogoSource(path: "/no/such/file.png")) { error in
            guard case SourceError.imageLoadFailed = error else {
                return XCTFail("expected imageLoadFailed, got \(error)")
            }
        }
    }

    /// Public-API smoke: a ticker reports a positive loop length and its live
    /// timer emits IOSurface-backed BGRA frames that stop after `stop()`.
    func testTickerLiveEmitAndStop() throws {
        let source = try TickerSource(text: "hello prism",
                                      canvasSize: .init(width: 480, height: 270), speed: 120)
        XCTAssertGreaterThan(source.loopLength, 0)

        let box = FrameBox()
        source.onFrame = { box.add($0) }
        try source.start()
        let got = box.wait(untilCount: 3, timeout: 2)
        XCTAssertTrue(got, "ticker emitted \(box.count) frames")
        if let f = box.first {
            XCTAssertNotNil(CVPixelBufferGetIOSurface(f.pixelBuffer))
            XCTAssertEqual(f.pixelFormat, kCVPixelFormatType_32BGRA)
        }
        source.stop()
        let after = box.count
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(box.count, after, "frames emitted after stop()")
    }

    /// Minimal thread-safe frame box for the smoke test.
    private final class FrameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [VideoFrame] = []
        func add(_ f: VideoFrame) { lock.lock(); frames.append(f); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
        var first: VideoFrame? { lock.lock(); defer { lock.unlock() }; return frames.first }
        func wait(untilCount n: Int, timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while count < n { if Date() >= deadline { return false }; usleep(10_000) }
            return true
        }
    }
}
