import CoreMedia
import CoreVideo
import Foundation
import Metal
import PrismCore
import simd

/// Headless self-verification of the chroma keyer (no TCC, no capture
/// hardware) — a real GPU pass on synthetic buffers.
///
/// TEST CODE ONLY: locks pixel-buffer base addresses to fill inputs and read
/// back outputs. Allowed here, forbidden on the engine hot path.
///
/// Wire `ChromaKeySelfTest.run()` into prism-dev alongside `ColorSelfTest`.
public enum ChromaKeySelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case setupFailed(String)
        case mismatch(String)
        public var description: String {
            switch self {
            case .setupFailed(let s): return "chroma-key self-test setup failed: \(s)"
            case .mismatch(let s): return "chroma-key self-test mismatch: \(s)"
            }
        }
    }

    private static let testW = 320, testH = 180

    public static func run() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SelfTestError.setupFailed("no Metal device")
        }
        let keyer = try ChromaKeyProcessor(device: device)

        try testKeyGreenBackground(keyer)
        try testSpillSuppression(keyer)
        try testAlphaBearingInput(keyer)

        print("ChromaKeySelfTest: all checks passed")
    }

    // MARK: - Synthetic buffer helpers (test-only CPU access)

    private static func makeBGRAFrame(_ fill: (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8),
                                      id: String) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: testW, height: testH,
                                       pixelFormat: kCVPixelFormatType_32BGRA, minimumBufferCount: 1)
        let buffer = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<testH {
            for col in 0..<testW {
                let c = fill(col, row)
                let p = base + row * bpr + col * 4
                p[0] = c.b; p[1] = c.g; p[2] = c.r; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return VideoFrame(pixelBuffer: buffer, pts: HouseClock.now(), source: SourceID(id))
    }

    /// Builds a BGRA frame from explicit (r,g,b,a) BYTES per pixel — the caller
    /// supplies already-premultiplied rgb so the input is a valid premultiplied-
    /// alpha buffer (unlike `makeBGRAFrame`, which hard-codes α=255).
    private static func makeBGRAFrameWithAlpha(
        _ fill: (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8), id: String) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: testW, height: testH,
                                       pixelFormat: kCVPixelFormatType_32BGRA, minimumBufferCount: 1)
        let buffer = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<testH {
            for col in 0..<testW {
                let c = fill(col, row)
                let p = base + row * bpr + col * 4
                p[0] = c.b; p[1] = c.g; p[2] = c.r; p[3] = c.a
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return VideoFrame(pixelBuffer: buffer, pts: HouseClock.now(), source: SourceID(id))
    }

    /// Reads a BGRA pixel as (r,g,b,a), each 0…255.
    private static func readBGRA(_ frame: VideoFrame, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let buffer = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (Int(p[2]), Int(p[1]), Int(p[0]), Int(p[3]))
    }

    // MARK: - 1. Green background keys to transparent, red foreground kept

    private static func testKeyGreenBackground(_ keyer: ChromaKeyProcessor) throws {
        // A red block on a pure-green screen.
        let blockX = testW / 3 ..< (2 * testW / 3)
        let blockY = testH / 3 ..< (2 * testH / 3)
        let frame = try makeBGRAFrame({ col, row in
            (blockX.contains(col) && blockY.contains(row)) ? (r: 255, g: 0, b: 0) : (r: 0, g: 255, b: 0)
        }, id: "chromakey.green")

        let out = try keyer.apply(frame: frame, key: .greenScreen)
        guard out.width == testW, out.height == testH,
              out.pixelFormat == kCVPixelFormatType_32BGRA,
              CMTimeCompare(out.pts, frame.pts) == 0 else {
            throw SelfTestError.mismatch("output shape/pts wrong")
        }

        // Background (green) → α ≈ 0, premultiplied rgb ≈ 0.
        let bg = readBGRA(out, x: 10, y: 10)
        guard bg.a <= 2, bg.r <= 2, bg.g <= 2, bg.b <= 2 else {
            throw SelfTestError.mismatch("green background not keyed out: got \(bg), expected ≈(0,0,0,0)")
        }

        // Foreground (red) → α ≈ 255, red preserved (despill of a green key
        // leaves red untouched since its green channel is 0).
        let fg = readBGRA(out, x: testW / 2, y: testH / 2)
        guard fg.a >= 253, fg.r >= 250, fg.g <= 3, fg.b <= 3 else {
            throw SelfTestError.mismatch("red foreground not kept: got \(fg), expected ≈(255,0,0,255)")
        }

        print("  ✓ chroma key: green bg → \(bg) (transparent), red fg → \(fg) (kept)")
    }

    // MARK: - 2. Spill suppression reduces green tint on a kept edge pixel

    private static func testSpillSuppression(_ keyer: ChromaKeyProcessor) throws {
        // A desaturated green-tinted foreground (like a subject edge lit by
        // green bounce). Chroma-far enough from pure green to be *kept*
        // (α ≈ 1) yet green-dominant so despill has something to remove.
        let tint: (r: UInt8, g: UInt8, b: UInt8) = (r: 153, g: 191, b: 140) // ≈ (0.60,0.75,0.55)
        let frame = try makeBGRAFrame({ _, _ in tint }, id: "chromakey.spill")

        var noDespill = ChromaKey.greenScreen; noDespill.spillStrength = 0
        var fullDespill = ChromaKey.greenScreen; fullDespill.spillStrength = 1

        let a = try keyer.apply(frame: frame, key: noDespill)
        let b = try keyer.apply(frame: frame, key: fullDespill)
        let pa = readBGRA(a, x: testW / 2, y: testH / 2)
        let pb = readBGRA(b, x: testW / 2, y: testH / 2)

        // The pixel must be kept in both runs (despill doesn't touch alpha)…
        guard pa.a > 200, pb.a > 200, abs(pa.a - pb.a) <= 2 else {
            throw SelfTestError.mismatch("spill test pixel not consistently kept: α \(pa.a) vs \(pb.a)")
        }
        // …and full despill must visibly lower the (premultiplied) green.
        guard pb.g < pa.g - 15 else {
            throw SelfTestError.mismatch("despill did not reduce green: \(pa.g) → \(pb.g) (expected drop > 15)")
        }
        print("  ✓ spill suppression: green \(pa.g) → \(pb.g) at α=\(pb.a) (despill off vs on)")
    }

    // MARK: - 3. Alpha-bearing (premultiplied) input keeps its own transparency

    /// Regression for the discarded-input-alpha bug: the keyed BGRA path used to
    /// drop `src.a`, so an already-transparent input region (premultiplied →
    /// rgb 0) came out OPAQUE black (α=255) once the layer's premultipliedAlpha
    /// flipped true. The fix folds `src.a` into the keyed output alpha.
    ///
    /// Three vertical bands over a premultiplied source:
    ///   left   = pure green at α=255  (background, keyed OUT)
    ///   middle = pure red   at α=255  (foreground, kept — unchanged vs today)
    ///   right  = fully transparent    (α=0, premult rgb 0 — must STAY transparent)
    private static func testAlphaBearingInput(_ keyer: ChromaKeyProcessor) throws {
        let third = testW / 3
        let frame = try makeBGRAFrameWithAlpha({ col, _ in
            if col < third { return (r: 0, g: 255, b: 0, a: 255) }        // green bg
            else if col < 2 * third { return (r: 255, g: 0, b: 0, a: 255) } // red fg
            else { return (r: 0, g: 0, b: 0, a: 0) }                       // transparent
        }, id: "chromakey.alpha")

        let out = try keyer.apply(frame: frame, key: .greenScreen)
        guard out.width == testW, out.height == testH,
              out.pixelFormat == kCVPixelFormatType_32BGRA else {
            throw SelfTestError.mismatch("alpha-input output shape wrong")
        }

        let green = readBGRA(out, x: third / 2, y: testH / 2)
        let red = readBGRA(out, x: third + third / 2, y: testH / 2)
        let clear = readBGRA(out, x: 2 * third + third / 2, y: testH / 2)

        // (a) The already-transparent region stays transparent — NOT opaque black.
        guard clear.a <= 2, clear.r <= 2, clear.g <= 2, clear.b <= 2 else {
            throw SelfTestError.mismatch(
                "transparent input turned opaque: got \(clear), expected ≈(0,0,0,0)")
        }
        // (b) The kept red foreground is unchanged vs the opaque-input test today.
        guard red.a >= 253, red.r >= 250, red.g <= 3, red.b <= 3 else {
            throw SelfTestError.mismatch(
                "red fg not kept unchanged: got \(red), expected ≈(255,0,0,255)")
        }
        // (c) The keyed-out green background is transparent.
        guard green.a <= 2, green.r <= 2, green.g <= 2, green.b <= 2 else {
            throw SelfTestError.mismatch(
                "green bg not keyed out: got \(green), expected ≈(0,0,0,0)")
        }
        // Premult invariant across all three: no channel exceeds alpha.
        for (name, px) in [("green", green), ("red", red), ("clear", clear)] {
            guard px.r <= px.a + 1, px.g <= px.a + 1, px.b <= px.a + 1 else {
                throw SelfTestError.mismatch(
                    "premult invariant broken at \(name): rgb>\(px.a) in \(px)")
            }
        }
        print("  ✓ alpha input: transparent→\(clear) (stays clear), red fg→\(red) (kept), green bg→\(green)")
    }
}
