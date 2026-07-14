import CoreMedia
import CoreVideo
import Foundation
import Metal
import PrismCore
import simd

/// Headless self-verification of the luma keyer + matte view (no TCC, no
/// capture hardware) — real GPU passes on synthetic buffers.
///
/// TEST CODE ONLY: locks pixel-buffer base addresses to fill inputs and read
/// back outputs. Allowed here, forbidden on the engine hot path.
///
/// Wire `LumaKeySelfTest.run()` into prism-dev alongside `ChromaKeySelfTest`.
public enum LumaKeySelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case setupFailed(String)
        case mismatch(String)
        public var description: String {
            switch self {
            case .setupFailed(let s): return "luma-key self-test setup failed: \(s)"
            case .mismatch(let s): return "luma-key self-test mismatch: \(s)"
            }
        }
    }

    private static let testW = 320, testH = 180

    public static func run() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SelfTestError.setupFailed("no Metal device")
        }
        let luma = try LumaKeyProcessor(device: device)
        let chroma = try ChromaKeyProcessor(device: device)

        try testKeyBrightBackground(luma)
        try testInvertFlips(luma)
        try testFeatherEdge(luma)
        try testYUVLumaKey(luma)
        try testLumaMatteView(luma)
        try testChromaMatteView(chroma)
        try testAlphaBearingInput(luma)

        print("LumaKeySelfTest: all checks passed")
    }

    // MARK: - Synthetic buffer helpers (test-only CPU access)

    /// Grayscale BGRA fill: value `v` (0…255) at each pixel from `fill`.
    private static func makeBGRAFrame(_ fill: (Int, Int) -> UInt8, id: String) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: testW, height: testH,
                                       pixelFormat: kCVPixelFormatType_32BGRA, minimumBufferCount: 1)
        let buffer = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<testH {
            for col in 0..<testW {
                let v = fill(col, row)
                let p = base + row * bpr + col * 4
                p[0] = v; p[1] = v; p[2] = v; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return VideoFrame(pixelBuffer: buffer, pts: HouseClock.now(), source: SourceID(id))
    }

    /// Colored BGRA fill (for the chroma matte-view check).
    private static func makeColorFrame(_ fill: (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8),
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

    /// Full-range (420f) neutral-gray fill: luma Y from `fill`, Cb=Cr=128.
    /// Neutral gray means luma == Y/255 through the kernel's BT.709 decode.
    private static func makeYUVGrayFrame(_ fill: (Int, Int) -> UInt8, id: String) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: testW, height: testH,
                                       pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                       minimumBufferCount: 1)
        let buffer = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buffer, [])
        let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let lw = CVPixelBufferGetWidthOfPlane(buffer, 0)
        for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 0) {
            let rowBase = lumaBase + row * lumaRow
            for col in 0..<lw { rowBase[col] = fill(col, row) }
        }
        let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
            let rowBase = chromaBase + row * chromaRow
            for col in 0..<CVPixelBufferGetWidthOfPlane(buffer, 1) {
                rowBase[col * 2] = 128; rowBase[col * 2 + 1] = 128
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return VideoFrame(pixelBuffer: buffer, pts: HouseClock.now(), source: SourceID(id))
    }

    /// Builds a BGRA frame from explicit (v, a) BYTES per pixel — grayscale
    /// value `v` with per-pixel alpha `a`. The caller supplies already-
    /// premultiplied rgb (v is the premult grayscale) so the input is a valid
    /// premultiplied-alpha buffer, unlike `makeBGRAFrame` (α hard-coded 255).
    private static func makeBGRAFrameWithAlpha(_ fill: (Int, Int) -> (v: UInt8, a: UInt8),
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
                p[0] = c.v; p[1] = c.v; p[2] = c.v; p[3] = c.a
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

    private static func assertShape(_ out: VideoFrame, _ src: VideoFrame) throws {
        guard out.width == testW, out.height == testH,
              out.pixelFormat == kCVPixelFormatType_32BGRA,
              CMTimeCompare(out.pts, src.pts) == 0 else {
            throw SelfTestError.mismatch("output shape/pts wrong")
        }
    }

    // MARK: - 1. Bright background keys out, mid-gray foreground kept

    private static func testKeyBrightBackground(_ keyer: LumaKeyProcessor) throws {
        // Mid-gray block (v=90 ≈ luma 0.353) on a near-white backdrop (v=245 ≈ 0.96).
        let blockX = testW / 3 ..< (2 * testW / 3)
        let blockY = testH / 3 ..< (2 * testH / 3)
        let frame = try makeBGRAFrame({ col, row in
            (blockX.contains(col) && blockY.contains(row)) ? 90 : 245
        }, id: "lumakey.bright")

        let out = try keyer.apply(frame: frame, key: .brightBackground)
        try assertShape(out, frame)

        // Background (bright) → α ≈ 0, premultiplied rgb ≈ 0.
        let bg = readBGRA(out, x: 10, y: 10)
        guard bg.a <= 2, bg.r <= 2, bg.g <= 2, bg.b <= 2 else {
            throw SelfTestError.mismatch("bright background not keyed out: got \(bg), expected ≈(0,0,0,0)")
        }
        // Foreground (mid-gray) → α ≈ 255, gray preserved (premult == color at α=1).
        let fg = readBGRA(out, x: testW / 2, y: testH / 2)
        guard fg.a >= 253, abs(fg.r - 90) <= 3, abs(fg.g - 90) <= 3, abs(fg.b - 90) <= 3 else {
            throw SelfTestError.mismatch("mid-gray foreground not kept: got \(fg), expected ≈(90,90,90,255)")
        }
        print("  ✓ luma key: bright bg → \(bg) (transparent), gray fg → \(fg) (kept)")
    }

    // MARK: - 2. Invert flips which side is keyed

    private static func testInvertFlips(_ keyer: LumaKeyProcessor) throws {
        let frame = try makeBGRAFrame({ col, _ in col < testW / 2 ? 245 : 90 }, id: "lumakey.invert")
        var inv = LumaKey.brightBackground; inv.invert = true

        let out = try keyer.apply(frame: frame, key: inv)
        try assertShape(out, frame)
        // Inverted: the bright band is KEPT, everything darker is keyed OUT.
        let bright = readBGRA(out, x: testW / 4, y: testH / 2)     // v=245 → kept
        let dark = readBGRA(out, x: 3 * testW / 4, y: testH / 2)   // v=90  → keyed out
        guard bright.a >= 253, dark.a <= 2 else {
            throw SelfTestError.mismatch("invert did not flip: bright α=\(bright.a) (want ~255), dark α=\(dark.a) (want ~0)")
        }
        print("  ✓ luma key invert: bright kept α=\(bright.a), dark keyed α=\(dark.a)")
    }

    // MARK: - 3. Feather produces intermediate alpha at the band edge

    private static func testFeatherEdge(_ keyer: LumaKeyProcessor) throws {
        // Fill at luma ≈ 0.71, half a feather below the low bound 0.75
        // (smoothness 0.08) → smoothstep ≈ 0.5 → α ≈ 0.5.
        let frame = try makeBGRAFrame({ _, _ in 181 }, id: "lumakey.feather")
        let out = try keyer.apply(frame: frame, key: .brightBackground)
        try assertShape(out, frame)
        let p = readBGRA(out, x: testW / 2, y: testH / 2)
        guard p.a > 90, p.a < 165 else {
            throw SelfTestError.mismatch("feather edge not intermediate: α=\(p.a), expected ~128 (90…165)")
        }
        print("  ✓ luma key feather: edge luma → intermediate α=\(p.a)")
    }

    // MARK: - 4. YUV (420f) luma-key path

    private static func testYUVLumaKey(_ keyer: LumaKeyProcessor) throws {
        // Bright band Y=230 (luma ≈ 0.902) on left, dark Y=90 (≈ 0.353) on right.
        let frame = try makeYUVGrayFrame({ col, _ in col < testW / 2 ? 230 : 90 }, id: "lumakey.420f")
        let out = try keyer.apply(frame: frame, key: .brightBackground)
        try assertShape(out, frame)
        let bg = readBGRA(out, x: testW / 4, y: testH / 2)     // bright → keyed
        let fg = readBGRA(out, x: 3 * testW / 4, y: testH / 2) // dark → kept
        guard bg.a <= 2 else {
            throw SelfTestError.mismatch("420f bright not keyed: α=\(bg.a), expected ~0")
        }
        guard fg.a >= 253, abs(fg.r - 90) <= 4 else {
            throw SelfTestError.mismatch("420f dark not kept: got \(fg), expected ≈(90,90,90,255)")
        }
        print("  ✓ luma key 420f: bright bg → \(bg), dark fg → \(fg)")
    }

    // MARK: - 5. Matte view (luma keyer) = grayscale alpha

    private static func testLumaMatteView(_ keyer: LumaKeyProcessor) throws {
        let frame = try makeBGRAFrame({ col, _ in col < testW / 2 ? 245 : 90 }, id: "lumakey.matte")
        let out = try keyer.apply(frame: frame, key: .brightBackground, matteView: true)
        try assertShape(out, frame)
        // Bright half → α≈0 → grayscale black; dark half → α≈1 → grayscale white.
        // Everywhere: r==g==b (grayscale) and a==255 (opaque matte).
        let bg = readBGRA(out, x: testW / 4, y: testH / 2)
        let fg = readBGRA(out, x: 3 * testW / 4, y: testH / 2)
        for (name, px, expect) in [("bright", bg, 0), ("dark", fg, 255)] {
            guard px.r == px.g, px.g == px.b, px.a == 255 else {
                throw SelfTestError.mismatch("luma matte not opaque grayscale at \(name): got \(px)")
            }
            guard abs(px.r - expect) <= 2 else {
                throw SelfTestError.mismatch("luma matte \(name) value \(px.r), expected ≈\(expect)")
            }
        }
        print("  ✓ luma matte view: bright→\(bg) (r=g=b=α), dark→\(fg)")
    }

    // MARK: - 6. Matte view (chroma keyer) = grayscale alpha

    private static func testChromaMatteView(_ keyer: ChromaKeyProcessor) throws {
        // Red block on green screen; matte view of the chroma key.
        let blockX = testW / 3 ..< (2 * testW / 3)
        let blockY = testH / 3 ..< (2 * testH / 3)
        let frame = try makeColorFrame({ col, row in
            (blockX.contains(col) && blockY.contains(row)) ? (r: 255, g: 0, b: 0) : (r: 0, g: 255, b: 0)
        }, id: "chromakey.matte")
        let out = try keyer.apply(frame: frame, key: .greenScreen, matteView: true)
        try assertShape(out, frame)
        // Green bg → α≈0 → black matte; red fg → α≈1 → white matte.
        let bg = readBGRA(out, x: 10, y: 10)
        let fg = readBGRA(out, x: testW / 2, y: testH / 2)
        for (name, px, expect) in [("green-bg", bg, 0), ("red-fg", fg, 255)] {
            guard px.r == px.g, px.g == px.b, px.a == 255 else {
                throw SelfTestError.mismatch("chroma matte not opaque grayscale at \(name): got \(px)")
            }
            guard abs(px.r - expect) <= 2 else {
                throw SelfTestError.mismatch("chroma matte \(name) value \(px.r), expected ≈\(expect)")
            }
        }
        print("  ✓ chroma matte view: green bg→\(bg) (r=g=b=α), red fg→\(fg)")
    }

    // MARK: - 7. Alpha-bearing (premultiplied) input keeps its own transparency

    /// Regression for the discarded-input-alpha bug: the keyed BGRA path used to
    /// drop `src.a`, so an already-transparent input region (premultiplied →
    /// rgb 0, which a luma key otherwise KEEPS as dark foreground) came out
    /// OPAQUE black (α=255). The fix folds `src.a` into the keyed output alpha
    /// while leaving the matte-view branch untouched.
    ///
    /// Three vertical bands over a premultiplied source, keyed with
    /// `.brightBackground` (keeps luma < ~0.67):
    ///   left   = bright gray v=245 at α=255 (background, keyed OUT)
    ///   middle = mid   gray v=90  at α=255 (foreground, kept — unchanged today)
    ///   right  = fully transparent (v=0, α=0 — kept-tone, but must STAY clear)
    private static func testAlphaBearingInput(_ keyer: LumaKeyProcessor) throws {
        let third = testW / 3
        let frame = try makeBGRAFrameWithAlpha({ col, _ in
            if col < third { return (v: 245, a: 255) }        // bright bg → keyed out
            else if col < 2 * third { return (v: 90, a: 255) } // mid fg → kept
            else { return (v: 0, a: 0) }                       // transparent
        }, id: "lumakey.alpha")

        let out = try keyer.apply(frame: frame, key: .brightBackground)
        try assertShape(out, frame)

        let bright = readBGRA(out, x: third / 2, y: testH / 2)
        let mid = readBGRA(out, x: third + third / 2, y: testH / 2)
        let clear = readBGRA(out, x: 2 * third + third / 2, y: testH / 2)

        // (a) The transparent region stays transparent — NOT opaque black. Note
        // a luma key keeps dark tones (v=0 is "foreground"), so ONLY the folded
        // input alpha makes this region transparent — the exact bug's target.
        guard clear.a <= 2, clear.r <= 2, clear.g <= 2, clear.b <= 2 else {
            throw SelfTestError.mismatch(
                "transparent input turned opaque: got \(clear), expected ≈(0,0,0,0)")
        }
        // (b) The kept mid-gray foreground is unchanged vs today (α=255 input).
        guard mid.a >= 253, abs(mid.r - 90) <= 3, abs(mid.g - 90) <= 3, abs(mid.b - 90) <= 3 else {
            throw SelfTestError.mismatch(
                "mid-gray fg not kept unchanged: got \(mid), expected ≈(90,90,90,255)")
        }
        // (c) The keyed-out bright background is transparent.
        guard bright.a <= 2, bright.r <= 2, bright.g <= 2, bright.b <= 2 else {
            throw SelfTestError.mismatch(
                "bright bg not keyed out: got \(bright), expected ≈(0,0,0,0)")
        }
        // Premult invariant across all three: no channel exceeds alpha.
        for (name, px) in [("bright", bright), ("mid", mid), ("clear", clear)] {
            guard px.r <= px.a + 1, px.g <= px.a + 1, px.b <= px.a + 1 else {
                throw SelfTestError.mismatch(
                    "premult invariant broken at \(name): rgb>\(px.a) in \(px)")
            }
        }
        print("  ✓ alpha input: transparent→\(clear) (stays clear), mid fg→\(mid) (kept), bright bg→\(bright)")
    }
}
