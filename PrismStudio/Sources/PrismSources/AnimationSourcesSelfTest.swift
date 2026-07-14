import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import os
import PrismCompositor
import PrismCore
import UniformTypeIdentifiers

/// Headless self-verification for the three animation-overlay sources
/// (`AnimatedLogoSource`, `TickerSource`, `CreditsSource`).
///
/// Everything runs without hardware or TCC permissions: a small logo PNG is
/// generated on the fly, sources are driven both deterministically (via the
/// shared `render(...)` helpers — repeatable, re-runnable) and live (through the
/// house-clock timer, to exercise the real emit + terminal-state path). For each
/// source it asserts: emitted frames are IOSurface-backed BGRA at canvas size;
/// frames change over time (real motion); the background outside content is
/// transparent (alpha 0, not black); the ticker wraps seamlessly; no `onFrame`
/// fires after `stop()`; and bad input throws a typed `SourceError`. A couple of
/// PNGs per source are dumped to the scratchpad for the lead to eyeball.
///
/// TEST CODE: locks pixel-buffer base addresses to read back output (via
/// `FXCanvas` verification helpers).
public enum AnimationSourcesSelfTest {

    public enum SelfTestError: Error, CustomStringConvertible {
        case setupFailed(String)
        case mismatch(String)
        public var description: String {
            switch self {
            case .setupFailed(let s): return "animation-source self-test setup failed: \(s)"
            case .mismatch(let s): return "animation-source self-test mismatch: \(s)"
            }
        }
    }

    /// Where eyeball PNGs land.
    public static let dumpDir = URL(fileURLWithPath:
        "/tmp/prism_anim_sources")

    /// Small test canvas — keeps overlays a meaningful fraction of the frame so
    /// motion/transparency asserts are sensitive, and renders fast.
    static let canvas = CanvasSize(width: 640, height: 360)

    public static func run() throws {
        try? FileManager.default.createDirectory(at: dumpDir, withIntermediateDirectories: true)
        let logoURL = try makeTestLogoPNG()
        try testLogoSource(logoURL: logoURL)
        try testTickerSource()
        try testCreditsSource()
        try testBadInputThrows(logoURL: logoURL)
        print("AnimationSourcesSelfTest: all checks passed (PNGs → \(dumpDir.path))")
    }

    // MARK: - Logo

    static func testLogoSource(logoURL: URL) throws {
        let style = LogoStyle(anchor: .topRight, sizeFraction: 0.28, margin: 0.05,
                              entrance: .slide(.right), idle: .float)
        let timing = LogoTiming(inSec: 0.6, holdSec: 3, outSec: 0.6, idlePeriod: 2)
        let source = try AnimatedLogoSource(id: SourceID("selftest.logo"), logoURL: logoURL,
                                            canvasSize: canvas, style: style, timing: timing, fps: 30)

        // Deterministic frames across the entrance (repeatable).
        let early = try source.render(progress: 0.1, idlePhase: 0)   // sliding in, faint
        let mid = try source.render(progress: 0.55, idlePhase: 0)
        let rest = try source.render(progress: 1.0, idlePhase: 0.0)  // at rest

        try assertCanvasBGRA(early, "logo.early")
        try assertCanvasBGRA(rest, "logo.rest")

        // Motion: the entrance visibly changes the frame (slide + opacity ramp).
        let move = FXCanvas.meanDiff(early, mid)
        guard move > 0.002 else {
            throw SelfTestError.mismatch("logo entrance did not move (meanDiff \(move))")
        }

        // Transparency: a region the logo never covers (bottom-left) is clear,
        // not black. Anchor is top-right, so bottom-left stays untouched.
        let corner = FXCanvas.pixel(rest, x: 6, y: canvas.height - 6)
        guard corner.a < 0.02 else {
            throw SelfTestError.mismatch("logo background not transparent (alpha \(corner.a))")
        }

        // Live path: house-clock timer emits IOSurface BGRA frames, and stop()
        // is terminal (no callback after it returns).
        try exerciseLive(source, tag: "logo")

        try dump(rest, "logo_rest.png")
        try dump(mid, "logo_entrance_mid.png")
    }

    // MARK: - Ticker

    static func testTickerSource() throws {
        let style = TickerStyle(position: .bottom)
        let source = try TickerSource(id: SourceID("selftest.ticker"),
                                      text: "BREAKING · Prism goes live · overlays are sources now",
                                      canvasSize: canvas, style: style, speed: 160, fps: 30)
        let loop = source.loopLength
        guard loop > 0 else { throw SelfTestError.setupFailed("ticker loopLength \(loop)") }

        let f0 = try source.render(offset: 0)
        let fHalf = try source.render(offset: loop / 2)
        let fLoop = try source.render(offset: loop)

        try assertCanvasBGRA(f0, "ticker.f0")

        // Scroll: half a loop away is a visibly different frame.
        let scroll = FXCanvas.meanDiff(f0, fHalf)
        guard scroll > 0.002 else {
            throw SelfTestError.mismatch("ticker did not scroll (meanDiff \(scroll))")
        }
        // Seamless wrap: exactly one loop later is pixel-identical.
        let wrap = FXCanvas.meanDiff(f0, fLoop)
        guard wrap < 0.004 else {
            throw SelfTestError.mismatch("ticker wrap not seamless (meanDiff \(wrap) at offset=loopLength)")
        }

        // Transparency: above the bottom bar (top of frame) is clear, not black.
        let top = FXCanvas.pixel(f0, x: canvas.width / 2, y: 5)
        guard top.a < 0.02 else {
            throw SelfTestError.mismatch("ticker background not transparent (alpha \(top.a))")
        }

        try exerciseLive(source, tag: "ticker")
        try dump(f0, "ticker_0.png")
        try dump(fHalf, "ticker_half.png")
    }

    // MARK: - Credits

    static func testCreditsSource() throws {
        let lines = ["PRISM STUDIO", "", "Director  ·  June",
                     "Compositor  ·  VisualFX", "Sources  ·  PrismSources", "", "fin"]
        let source = try CreditsSource(id: SourceID("selftest.credits"), lines: lines,
                                       canvasSize: canvas, style: CreditsStyle(),
                                       speed: 90, loop: false)
        let roll = source.rollLength
        guard roll > 0 else { throw SelfTestError.setupFailed("credits rollLength \(roll)") }

        let a = try source.render(offset: roll * 0.25)
        let b = try source.render(offset: roll * 0.55)
        try assertCanvasBGRA(a, "credits.a")

        // Roll: the block moves up between the two offsets.
        let move = FXCanvas.meanDiff(a, b)
        guard move > 0.002 else {
            throw SelfTestError.mismatch("credits did not roll (meanDiff \(move))")
        }
        // Transparency: the far-left column (centered text never reaches it) is clear.
        let edge = FXCanvas.pixel(a, x: 3, y: canvas.height / 2)
        guard edge.a < 0.02 else {
            throw SelfTestError.mismatch("credits background not transparent (alpha \(edge.a))")
        }

        // Loop mode wraps the offset modulo rollLength (seamless repeat).
        let looping = try CreditsSource(lines: lines, canvasSize: canvas, speed: 90, loop: true)
        let l0 = try looping.render(offset: looping.scrollOffset(for: 0))
        let lWrap = try looping.render(offset: looping.scrollOffset(for: roll))
        let wrap = FXCanvas.meanDiff(l0, lWrap)
        guard wrap < 0.004 else {
            throw SelfTestError.mismatch("credits loop wrap not seamless (meanDiff \(wrap))")
        }

        try exerciseLive(source, tag: "credits")
        // `a`/`b` are the real (white, transparent) overlay frames; also dump a
        // dark-text render so the lines are eyeball-able against a white viewer.
        let darkStyle = CreditsStyle(textColor: RGBA(r: 0.1, g: 0.1, b: 0.12))
        let darkSource = try CreditsSource(lines: lines, canvasSize: canvas, style: darkStyle)
        try dump(try darkSource.render(offset: roll * 0.45), "credits_dark_mid.png")
        try dump(a, "credits_early.png")
        try dump(b, "credits_late.png")
    }

    // MARK: - Bad input

    static func testBadInputThrows(logoURL: URL) throws {
        // Missing logo file → imageLoadFailed.
        try expectThrows("logo missing file") {
            _ = try AnimatedLogoSource(logoURL: URL(fileURLWithPath: "/no/such/logo.png"),
                                       canvasSize: canvas)
        } check: { if case SourceError.imageLoadFailed = $0 { return true }; return false }

        // Undecodable logo (a text file with .png extension) → decode/load failure.
        let junk = dumpDir.appendingPathComponent("not_an_image.png")
        try Data("not a png".utf8).write(to: junk)
        try expectThrows("logo undecodable") {
            _ = try AnimatedLogoSource(logoURL: junk, canvasSize: canvas)
        } check: {
            if case SourceError.imageDecodeFailed = $0 { return true }
            if case SourceError.imageLoadFailed = $0 { return true }
            return false
        }

        // Empty ticker text → invalidConfiguration.
        try expectThrows("ticker empty text") {
            _ = try TickerSource(text: "   ", canvasSize: canvas)
        } check: { if case SourceError.invalidConfiguration = $0 { return true }; return false }

        // No non-empty credit lines → invalidConfiguration.
        try expectThrows("credits empty lines") {
            _ = try CreditsSource(lines: ["", "  "], canvasSize: canvas)
        } check: { if case SourceError.invalidConfiguration = $0 { return true }; return false }
    }

    // MARK: - Live drive + terminal-state

    /// Run the source through its real house-clock timer: collect a few live
    /// frames (assert IOSurface BGRA + real motion between them), then assert
    /// `stop()` is terminal — no `onFrame` after it returns.
    static func exerciseLive(_ source: AnimationSource, tag: String) throws {
        let collector = FrameCollector()
        source.onFrame = { collector.add($0) }
        try source.start()
        // Collect enough frames that a slow-start entrance (e.g. a 0.6 s slide)
        // has visibly progressed by the last frame.
        guard waitUntil(timeout: 3, { collector.count >= 12 }) else {
            throw SelfTestError.mismatch("\(tag): live source emitted \(collector.count) frames in 3s")
        }
        let frames = collector.snapshot()
        for f in frames.prefix(4) {
            guard CVPixelBufferGetIOSurface(f.pixelBuffer) != nil else {
                throw SelfTestError.mismatch("\(tag): live frame is not IOSurface-backed")
            }
            guard f.pixelFormat == kCVPixelFormatType_32BGRA else {
                throw SelfTestError.mismatch("\(tag): live frame not 32BGRA")
            }
            guard f.width == canvas.width, f.height == canvas.height else {
                throw SelfTestError.mismatch("\(tag): live frame \(f.width)x\(f.height) != canvas")
            }
        }
        // Motion across the live stream (first vs a later frame).
        if let first = frames.first, let last = frames.last, frames.count >= 2 {
            let d = FXCanvas.meanDiff(first.pixelBuffer, last.pixelBuffer)
            guard d > 0.0005 else {
                throw SelfTestError.mismatch("\(tag): live frames did not change over time (meanDiff \(d))")
            }
        }

        // Terminal: after stop() returns, no further callbacks arrive.
        source.stop()
        let afterStop = collector.count
        _ = waitUntil(timeout: 0.2, { false })   // let any stray tick try to fire
        guard collector.count == afterStop else {
            throw SelfTestError.mismatch("\(tag): \(collector.count - afterStop) frame(s) emitted after stop()")
        }
        source.onFrame = nil
    }

    // MARK: - Helpers

    static func assertCanvasBGRA(_ buffer: CVPixelBuffer, _ label: String) throws {
        guard CVPixelBufferGetIOSurface(buffer) != nil else {
            throw SelfTestError.mismatch("\(label): not IOSurface-backed")
        }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            throw SelfTestError.mismatch("\(label): not 32BGRA")
        }
        guard CVPixelBufferGetWidth(buffer) == canvas.width,
              CVPixelBufferGetHeight(buffer) == canvas.height else {
            throw SelfTestError.mismatch("\(label): wrong size")
        }
    }

    static func dump(_ buffer: CVPixelBuffer, _ name: String) throws {
        _ = try FXCanvas.writePNG(buffer, to: dumpDir.appendingPathComponent(name))
    }

    static func expectThrows(_ what: String, _ body: () throws -> Void,
                             check: (Error) -> Bool) throws {
        do {
            try body()
            throw SelfTestError.mismatch("\(what): expected a throw, got none")
        } catch let e as SelfTestError {
            throw e
        } catch {
            guard check(error) else {
                throw SelfTestError.mismatch("\(what): threw unexpected \(error)")
            }
        }
    }

    @discardableResult
    static func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline { return predicate() }
            usleep(10_000)
        }
        return true
    }

    /// Generate a small transparent PNG with a filled colored disc — a stand-in
    /// user logo with real alpha (clear corners), written to the scratchpad.
    static func makeTestLogoPNG() throws -> URL {
        let w = 256, h = 256
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs, bitmapInfo: info) else {
            throw SelfTestError.setupFailed("could not create logo bitmap context")
        }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))          // transparent bg
        ctx.setFillColor(CGColor(srgbRed: 0.16, green: 0.55, blue: 0.95, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 24, y: 24, width: w - 48, height: h - 48))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.2, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 92, y: 92, width: 72, height: 72))
        guard let image = ctx.makeImage() else {
            throw SelfTestError.setupFailed("could not snapshot logo image")
        }
        let url = dumpDir.appendingPathComponent("test_logo.png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else {
            throw SelfTestError.setupFailed("could not create PNG destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw SelfTestError.setupFailed("could not write logo PNG")
        }
        return url
    }

    /// Thread-safe collector for live `onFrame` callbacks.
    final class FrameCollector: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: [VideoFrame]())
        func add(_ f: VideoFrame) { lock.withLock { $0.append(f) } }
        var count: Int { lock.withLock { $0.count } }
        func snapshot() -> [VideoFrame] { lock.withLock { $0 } }
    }
}
