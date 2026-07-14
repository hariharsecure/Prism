import CoreMedia
import CoreVideo
import Foundation
import PrismCore

/// Headless self-verification of the presenter-cutout compositing (no camera,
/// no TCC). Real Vision request + deterministic CPU compositing on synthetic
/// buffers and injected mattes; throws with a precise message on the first
/// mismatch. Wire `PresenterCutoutSelfTest.run()` into a dev harness.
///
/// TEST CODE: locks pixel-buffer base addresses to build inputs and read
/// outputs — allowed here, forbidden on any engine hot path.
public enum PresenterCutoutSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case setupFailed(String)
        case mismatch(String)
        public var description: String {
            switch self {
            case .setupFailed(let s): return "cutout self-test setup failed: \(s)"
            case .mismatch(let s): return "cutout self-test mismatch: \(s)"
            }
        }
    }

    private static let w = 320, h = 240

    public static func run() throws {
        try testTransparentCutout()
        try testFeather()
        try testSolidColorBackground()
        try testNoPerson()
        try testRealVisionPath()
        print("PresenterCutoutSelfTest: all checks passed")
    }

    // MARK: - Builders

    /// IOSurface BGRA frame; `fill` returns (r,g,b) per pixel, alpha forced 255.
    /// `public` so `PresenterCutoutTests` (a separate module) can reuse it.
    public static func makeBGRAFrame(width: Int = 320, height: Int = 240, id: String,
                                     fill: (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8)) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: width, height: height,
                                       pixelFormat: kCVPixelFormatType_32BGRA, minimumBufferCount: 1)
        let buffer = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let c = fill(x, y); let p = base + y * row + x * 4
                p[0] = c.b; p[1] = c.g; p[2] = c.r; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return VideoFrame(pixelBuffer: buffer, pts: HouseClock.now(), source: SourceID(id))
    }

    /// IOSurface OneComponent8 matte; `fill` returns 0…255 per pixel.
    public static func makeMatte(width: Int, height: Int, fill: (Int, Int) -> UInt8) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: width, height: height,
                                       pixelFormat: kCVPixelFormatType_OneComponent8, minimumBufferCount: 1)
        let buffer = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height { for x in 0..<width { base[y * row + x] = fill(x, y) } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    public static func readBGRA(_ frame: VideoFrame, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let buf = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            + y * CVPixelBufferGetBytesPerRow(buf) + x * 4
        return (Int(p[2]), Int(p[1]), Int(p[0]), Int(p[3]))
    }

    // MARK: - 1. Transparent cutout: fg opaque passthrough, bg transparent black

    private static func testTransparentCutout() throws {
        // Left half red, right half blue.
        let frame = try makeBGRAFrame(id: "cutout.transparent") { x, _ in
            x < w / 2 ? (r: 220, g: 30, b: 20) : (r: 10, g: 20, b: 230)
        }
        // Full-res matte: left = person (255), right = background (0).
        let matte = try makeMatte(width: w, height: h) { x, _ in x < w / 2 ? 255 : 0 }
        let cutout = PresenterCutout(options: .init(background: .transparent, feather: 0))
        let out = try cutout.composite(frame: frame, matte: matte)

        guard out.pixelFormat == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetIOSurface(out.pixelBuffer) != nil,
              out.width == w, out.height == h, CMTimeCompare(out.pts, frame.pts) == 0 else {
            throw SelfTestError.mismatch("transparent: output shape/format/pts/IOSurface wrong")
        }
        let fg = readBGRA(out, x: 60, y: 120)
        guard fg.a == 255, abs(fg.r - 220) <= 1, abs(fg.g - 30) <= 1, abs(fg.b - 20) <= 1 else {
            throw SelfTestError.mismatch("transparent: fg must pass through opaque, got \(fg)")
        }
        let bg = readBGRA(out, x: 260, y: 120)
        guard bg.a == 0, bg.r == 0, bg.g == 0, bg.b == 0 else {
            throw SelfTestError.mismatch("transparent: bg must be transparent black (premultiplied), got \(bg)")
        }
        print("  ✓ transparent cutout: fg \(fg) opaque, bg \(bg) transparent-black (not opaque black)")
    }

    // MARK: - 2. Feather softens the alpha edge

    private static func testFeather() throws {
        let frame = try makeBGRAFrame(id: "cutout.feather") { _, _ in (r: 200, g: 200, b: 200) }
        // Hard vertical step at x = w/2 (full-res → upscale is identity, so
        // feather is the ONLY source of softening).
        let matte = try makeMatte(width: w, height: h) { x, _ in x < w / 2 ? 255 : 0 }

        let sharp = try PresenterCutout(options: .init(feather: 0)).composite(frame: frame, matte: matte)
        // Sharp: the two columns straddling the edge are a clean 255 → 0 step.
        guard readBGRA(sharp, x: w / 2 - 1, y: 120).a == 255, readBGRA(sharp, x: w / 2, y: 120).a == 0 else {
            throw SelfTestError.mismatch("feather=0 should be a hard step at the edge")
        }

        let feathered = try PresenterCutout(options: .init(feather: 8)).composite(frame: frame, matte: matte)
        // Count intermediate (soft) alpha columns across the boundary band.
        var soft = 0
        for x in (w / 2 - 12)..<(w / 2 + 12) {
            let a = readBGRA(feathered, x: x, y: 120).a
            if a > 4 && a < 251 { soft += 1 }
        }
        guard soft >= 8 else {
            throw SelfTestError.mismatch("feather=8 should produce a soft ramp band, got \(soft) intermediate columns")
        }
        // Interiors stay solid / clear.
        guard readBGRA(feathered, x: 40, y: 120).a == 255, readBGRA(feathered, x: w - 40, y: 120).a == 0 else {
            throw SelfTestError.mismatch("feather=8 must keep interiors opaque/transparent")
        }
        // A feathered edge pixel is premultiplied: rgb ≈ 200·(a/255).
        let edge = readBGRA(feathered, x: w / 2, y: 120)
        let expected = Int((200.0 * Double(edge.a) / 255.0).rounded())
        guard abs(edge.r - expected) <= 2 else {
            throw SelfTestError.mismatch("feather edge not premultiplied: a=\(edge.a) r=\(edge.r) expected≈\(expected)")
        }
        print("  ✓ feather: hard step at f=0; f=8 → \(soft) soft columns, edge premultiplied (a=\(edge.a), r=\(edge.r))")
    }

    // MARK: - 3. Solid-colour background fill

    private static func testSolidColorBackground() throws {
        let frame = try makeBGRAFrame(id: "cutout.solid") { _, _ in (r: 200, g: 120, b: 80) }
        let matte = try makeMatte(width: w, height: h) { x, _ in x < w / 2 ? 255 : 0 }
        let green = RGBAColor(r: 0, g: 1, b: 0)
        let out = try PresenterCutout(options: .init(background: .solidColor(green), feather: 0))
            .composite(frame: frame, matte: matte)
        let fg = readBGRA(out, x: 60, y: 120)
        guard fg.a == 255, abs(fg.r - 200) <= 1, abs(fg.g - 120) <= 1, abs(fg.b - 80) <= 1 else {
            throw SelfTestError.mismatch("solid: fg must be kept, got \(fg)")
        }
        let bg = readBGRA(out, x: 260, y: 120)
        guard bg.a == 255, bg.r <= 1, bg.g >= 254, bg.b <= 1 else {
            throw SelfTestError.mismatch("solid: bg must be opaque green (0,255,0), got \(bg)")
        }
        print("  ✓ solid-colour bg: fg kept \(fg), bg → opaque \(bg)")
    }

    // MARK: - 4. No person: transparent vs pass-through

    private static func testNoPerson() throws {
        let frame = try makeBGRAFrame(id: "cutout.noperson") { _, _ in (r: 111, g: 122, b: 133) }
        let transparent = try PresenterCutout(options: .init(noPerson: .transparent))
            .composite(frame: frame, matte: nil)
        let t = readBGRA(transparent, x: 160, y: 120)
        guard t == (0, 0, 0, 0) else {
            throw SelfTestError.mismatch("no-person transparent must be (0,0,0,0), got \(t)")
        }
        let passed = try PresenterCutout(options: .init(noPerson: .passThrough))
            .composite(frame: frame, matte: nil)
        let p = readBGRA(passed, x: 160, y: 120)
        guard p == (111, 122, 133, 255) else {
            throw SelfTestError.mismatch("no-person pass-through must be the input opaque, got \(p)")
        }
        print("  ✓ no-person: transparent → \(t), pass-through → \(p)")
    }

    // MARK: - 5. Real Vision request runs error-free (detection not required)

    private static func testRealVisionPath() throws {
        // A person-ish blob on gray — Vision may or may not call it a person;
        // the criterion is error-free plumbing, matching VisionSelfTest.
        let frame = try makeBGRAFrame(id: "cutout.vision") { x, y in
            let hx = Double(x - w / 2), hy = Double(y - 70)
            if hx * hx + hy * hy < 40 * 40 { return (r: 210, g: 160, b: 130) }
            let bx = Double(x - w / 2) / 55, by = Double(y - 170) / 80
            if bx * bx + by * by < 1 { return (r: 60, g: 90, b: 160) }
            return (r: 180, g: 180, b: 180)
        }
        let cutout = PresenterCutout(options: .init(quality: .fast))
        if let matte = try cutout.segmentMatte(frame) {
            guard CVPixelBufferGetPixelFormatType(matte) == kCVPixelFormatType_OneComponent8 else {
                throw SelfTestError.mismatch("vision: matte not OneComponent8")
            }
            // Compositing an arbitrary real matte must still yield IOSurface BGRA.
            let out = try cutout.composite(frame: frame, matte: matte)
            guard out.pixelFormat == kCVPixelFormatType_32BGRA,
                  CVPixelBufferGetIOSurface(out.pixelBuffer) != nil else {
                throw SelfTestError.mismatch("vision: composited output not IOSurface BGRA")
            }
            print("  ✓ real Vision path: matte \(CVPixelBufferGetWidth(matte))×\(CVPixelBufferGetHeight(matte)) → BGRA cutout (blob segmented)")
        } else {
            print("  ✓ real Vision path: clean no-detection on synthetic blob (request ran error-free)")
        }
    }
}
