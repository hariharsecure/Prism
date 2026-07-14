import CoreMedia
import CoreVideo
import Foundation
import Metal
import PrismCore

/// Headless self-verification of the whole vision stage (no TCC, no camera)
/// — real Vision requests + real GPU passes on synthetic buffers.
///
/// TEST CODE ONLY: this file locks pixel-buffer base addresses to fill
/// synthetic inputs and read back outputs. That is explicitly allowed here
/// and **forbidden on the engine hot path** — the processors themselves
/// never touch pixels on the CPU.
///
/// Note on (a): Vision may or may not classify the synthetic blob as a
/// person — detection is NOT the pass criterion. The segmentation checks
/// assert error-free end-to-end plumbing and accept either a well-formed
/// matte or a clean no-detection; all pixel-exact verification of the GPU
/// stages uses synthetic mattes.
///
/// Wire `VisionSelfTest.run()` into prism-dev; it throws with a precise
/// message on the first mismatch.
public enum VisionSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case setupFailed(String)
        case mismatch(String)
        public var description: String {
            switch self {
            case .setupFailed(let s): return "vision self-test setup failed: \(s)"
            case .mismatch(let s): return "vision self-test mismatch: \(s)"
            }
        }
    }

    public static func run() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SelfTestError.setupFailed("no Metal device")
        }
        try testMatteSmoother(device)
        let effect = try BackgroundEffect(device: device)
        try testBackgroundRemove(effect)
        try testBackgroundBlur(effect)
        try testBackgroundReplace(effect)
        try testBackgroundRemoveYUV(effect)
        try testSegmentationEndToEnd()
        try testSubmitPipeline()
        print("VisionSelfTest: all checks passed")
    }

    // MARK: - Synthetic inputs

    private static let frameW = 640, frameH = 480

    private static func makeBGRAFrame(width: Int = frameW, height: Int = frameH,
                                      id: String,
                                      pts: CMTime? = nil,
                                      fill: (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8)) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: width, height: height,
                                       pixelFormat: kCVPixelFormatType_32BGRA, minimumBufferCount: 1)
        let buffer = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<height {
            for col in 0..<width {
                let c = fill(col, row)
                let p = base + row * bytesPerRow + col * 4
                p[0] = c.b; p[1] = c.g; p[2] = c.r; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return VideoFrame(pixelBuffer: buffer, pts: pts ?? HouseClock.now(), source: SourceID(id))
    }

    private static func makeMatte(width: Int, height: Int, pts: CMTime, id: String,
                                  fill: (Int, Int) -> UInt8) throws -> SegmentationMatte {
        let pool = try PixelBufferPool(width: width, height: height,
                                       pixelFormat: kCVPixelFormatType_OneComponent8,
                                       minimumBufferCount: 1)
        let buffer = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<height {
            for col in 0..<width {
                base[row * bytesPerRow + col] = fill(col, row)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return SegmentationMatte(pixelBuffer: buffer, pts: pts, source: SourceID(id))
    }

    /// 640×480 "person-ish" figure: head circle + body ellipse on a plain
    /// gray background.
    private static func makePersonishFrame(pts: CMTime? = nil, id: String = "selftest.person") throws -> VideoFrame {
        try makeBGRAFrame(id: id, pts: pts) { x, y in
            let hx = Double(x - 320), hy = Double(y - 140)
            if hx * hx + hy * hy < 55 * 55 { return (r: 210, g: 160, b: 130) } // head
            let bx = Double(x - 320) / 110, by = Double(y - 330) / 150
            if bx * bx + by * by < 1 { return (r: 60, g: 90, b: 160) } // torso
            return (r: 180, g: 180, b: 180)
        }
    }

    private static func readPixel(_ frame: VideoFrame, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let buffer = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (Int(p[2]), Int(p[1]), Int(p[0]), Int(p[3]))
    }

    private static func readMatte(_ matte: SegmentationMatte, x: Int, y: Int) -> Int {
        let buffer = matte.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        return Int(base[y * CVPixelBufferGetBytesPerRow(buffer) + x])
    }

    // MARK: - 1. MatteSmoother: exponential blend + convergence

    private static func testMatteSmoother(_ device: MTLDevice) throws {
        let smoother = try MatteSmoother(device: device, alpha: 0.5)
        let pts = HouseClock.now()
        let white = try makeMatte(width: 64, height: 64, pts: pts, id: "selftest.smooth") { _, _ in 255 }
        let black = try makeMatte(width: 64, height: 64, pts: pts, id: "selftest.smooth") { _, _ in 0 }

        // First matte passes through unblended.
        let s1 = try smoother.smooth(white)
        guard readMatte(s1, x: 32, y: 32) == 255 else {
            throw SelfTestError.mismatch("smoother: first matte should pass through, got \(readMatte(s1, x: 32, y: 32))")
        }
        // 0.5·0 + 0.5·255 ≈ 128.
        let s2 = try smoother.smooth(black)
        let v2 = readMatte(s2, x: 32, y: 32)
        guard abs(v2 - 128) <= 2 else {
            throw SelfTestError.mismatch("smoother: 255→0 blend expected ≈128, got \(v2)")
        }
        // 0.5·255 + 0.5·128 ≈ 191.
        let s3 = try smoother.smooth(white)
        let v3 = readMatte(s3, x: 32, y: 32)
        guard abs(v3 - 191) <= 2 else {
            throw SelfTestError.mismatch("smoother: blend expected ≈191, got \(v3)")
        }
        // Constant input converges.
        var converged = 0
        for _ in 0..<12 { converged = readMatte(try smoother.smooth(black), x: 32, y: 32) }
        guard converged <= 2 else {
            throw SelfTestError.mismatch("smoother: expected convergence to ≈0 after 12 steps, got \(converged)")
        }
        // Size change resets state (pass-through again).
        let small = try makeMatte(width: 32, height: 32, pts: pts, id: "selftest.smooth") { _, _ in 200 }
        let s4 = try smoother.smooth(small)
        guard readMatte(s4, x: 16, y: 16) == 200, s4.width == 32 else {
            throw SelfTestError.mismatch("smoother: size change should reset, got \(readMatte(s4, x: 16, y: 16)) @ \(s4.width)px")
        }
        print("  ✓ MatteSmoother: 255 → 128 → 191 (α=0.5), converges to \(converged), size-change reset")
    }

    // MARK: - Shared synthetic matte (half frame resolution — exercises sampler upscale)

    /// Left half person (255), right half background (0), at 320×240.
    private static func makeHalfMatte(pts: CMTime) throws -> SegmentationMatte {
        try makeMatte(width: frameW / 2, height: frameH / 2, pts: pts, id: "selftest.matte") { x, _ in
            x < frameW / 4 ? 255 : 0
        }
    }

    // MARK: - 2. Remove: background alpha (and premultiplied rgb) zeroed, foreground kept

    private static func testBackgroundRemove(_ effect: BackgroundEffect) throws {
        let frame = try makeBGRAFrame(id: "selftest.remove") { x, _ in
            x < frameW / 2 ? (r: 255, g: 40, b: 20) : (r: 10, g: 20, b: 250)
        }
        let matte = try makeHalfMatte(pts: frame.pts)
        let out = try effect.apply(frame: frame, matte: matte, mode: .remove)
        guard out.pixelFormat == kCVPixelFormatType_32BGRA, out.width == frameW, out.height == frameH,
              CMTimeCompare(out.pts, frame.pts) == 0 else {
            throw SelfTestError.mismatch("remove: output shape/format/pts wrong")
        }
        let fg = readPixel(out, x: 100, y: 240)
        guard fg.a == 255, abs(fg.r - 255) <= 2, abs(fg.g - 40) <= 2, abs(fg.b - 20) <= 2 else {
            throw SelfTestError.mismatch("remove: foreground should be kept at alpha 255, got \(fg)")
        }
        let bg = readPixel(out, x: 540, y: 240)
        guard bg.a == 0, bg.r == 0, bg.g == 0, bg.b == 0 else {
            throw SelfTestError.mismatch("remove: background should be transparent black (premultiplied), got \(bg)")
        }
        print("  ✓ BackgroundEffect.remove: fg kept \(fg), bg → transparent black (matte 320×240 upscaled)")
    }

    // MARK: - 3. Blur: foreground within tolerance, background smoothed

    private static func testBackgroundBlur(_ effect: BackgroundEffect) throws {
        // Background = 8px checkerboard (high frequency), foreground = solid green.
        let frame = try makeBGRAFrame(id: "selftest.blur") { x, y in
            if x < frameW / 2 { return (r: 30, g: 200, b: 60) }
            let checker = ((x / 8) + (y / 8)) % 2 == 0
            return checker ? (r: 255, g: 255, b: 255) : (r: 0, g: 0, b: 0)
        }
        let matte = try makeHalfMatte(pts: frame.pts)
        let out = try effect.apply(frame: frame, matte: matte, mode: .blur(radius: 8))

        let fg = readPixel(out, x: 100, y: 240)
        guard fg.a == 255, abs(fg.r - 30) <= 2, abs(fg.g - 200) <= 2, abs(fg.b - 60) <= 2 else {
            throw SelfTestError.mismatch("blur: foreground should be untouched, got \(fg)")
        }
        // Two background pixels that were black-vs-white converge toward the local mean.
        let b1 = readPixel(out, x: 500, y: 240)
        let b2 = readPixel(out, x: 500, y: 248)
        let orig1 = readPixel(frame, x: 500, y: 240)
        guard abs(b1.g - b2.g) < 40, abs(b1.g - orig1.g) > 40 else {
            throw SelfTestError.mismatch("blur: background not smoothed — out \(b1.g) vs \(b2.g), original \(orig1.g)")
        }
        guard abs(b1.g - 128) < 48 else {
            throw SelfTestError.mismatch("blur: background should approach checker mean ≈128, got \(b1.g)")
        }
        print("  ✓ BackgroundEffect.blur(8): fg untouched \(fg), bg checker \(orig1.g)/\(255 - orig1.g) → \(b1.g)/\(b2.g)")
    }

    // MARK: - 4. Replace: background = color, foreground kept

    private static func testBackgroundReplace(_ effect: BackgroundEffect) throws {
        let frame = try makeBGRAFrame(id: "selftest.replace") { _, _ in (r: 200, g: 120, b: 80) }
        let matte = try makeHalfMatte(pts: frame.pts)
        let out = try effect.apply(frame: frame, matte: matte, mode: .replace(color: SIMD3(0, 1, 0)))
        let fg = readPixel(out, x: 100, y: 240)
        guard fg.a == 255, abs(fg.r - 200) <= 2, abs(fg.g - 120) <= 2, abs(fg.b - 80) <= 2 else {
            throw SelfTestError.mismatch("replace: foreground should be kept, got \(fg)")
        }
        let bg = readPixel(out, x: 540, y: 240)
        guard bg.a == 255, bg.r <= 2, bg.g >= 253, bg.b <= 2 else {
            throw SelfTestError.mismatch("replace: background should be (0,255,0), got \(bg)")
        }
        print("  ✓ BackgroundEffect.replace: fg kept \(fg), bg → (\(bg.r),\(bg.g),\(bg.b))")
    }

    // MARK: - 5. Remove on a 420f YUV input (native-format sampling path)

    private static func testBackgroundRemoveYUV(_ effect: BackgroundEffect) throws {
        let pool = try PixelBufferPool(width: frameW, height: frameH,
                                       pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                       minimumBufferCount: 1)
        let buffer = try pool.makeBuffer()
        // Solid green, full-range BT.709: Y=182 Cb=30 Cr=12 (compositor's vector).
        CVPixelBufferLockBaseAddress(buffer, [])
        let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 0) {
            memset(lumaBase + row * lumaRow, 182, CVPixelBufferGetWidthOfPlane(buffer, 0))
        }
        let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
            let rowBase = chromaBase + row * chromaRow
            for col in 0..<CVPixelBufferGetWidthOfPlane(buffer, 1) {
                rowBase[col * 2] = 30; rowBase[col * 2 + 1] = 12
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let frame = VideoFrame(pixelBuffer: buffer, pts: HouseClock.now(), source: SourceID("selftest.420f"))
        let matte = try makeHalfMatte(pts: frame.pts)
        let out = try effect.apply(frame: frame, matte: matte, mode: .remove)
        let fg = readPixel(out, x: 100, y: 240)
        guard fg.a == 255, fg.r <= 4, abs(fg.g - 255) <= 4, fg.b <= 4 else {
            throw SelfTestError.mismatch("remove/420f: foreground should be green at alpha 255, got \(fg)")
        }
        let bg = readPixel(out, x: 540, y: 240)
        guard bg.a == 0, bg.g == 0 else {
            throw SelfTestError.mismatch("remove/420f: background should be transparent, got \(bg)")
        }
        print("  ✓ BackgroundEffect.remove on 420f input: fg green \(fg), bg transparent")
    }

    // MARK: - 6. Vision request end-to-end (synchronous)

    private static func testSegmentationEndToEnd() throws {
        let frame = try makePersonishFrame()
        let segmenter = PersonSegmenter(quality: .balanced)
        // Pass criterion: the request runs error-free and the plumbing is
        // correct — NOT that Vision sees a person in the synthetic blob.
        if let matte = try segmenter.segmentNow(frame) {
            guard CVPixelBufferGetPixelFormatType(matte.pixelBuffer) == kCVPixelFormatType_OneComponent8 else {
                throw SelfTestError.mismatch("segmentation: matte not OneComponent8")
            }
            guard CVPixelBufferGetIOSurface(matte.pixelBuffer) != nil else {
                throw SelfTestError.mismatch("segmentation: matte not IOSurface-backed after normalization")
            }
            guard matte.width > 0, matte.height > 0,
                  CMTimeCompare(matte.pts, frame.pts) == 0, matte.source == frame.source else {
                throw SelfTestError.mismatch("segmentation: matte metadata wrong (\(matte.width)x\(matte.height))")
            }
            let center = readMatte(matte, x: matte.width / 2, y: matte.height / 2)
            print("  ✓ Vision segmentation end-to-end: matte \(matte.width)×\(matte.height), center=\(center) (synthetic blob detected)")
        } else {
            print("  ✓ Vision segmentation end-to-end: clean no-detection on synthetic blob (request ran error-free)")
        }
        // Fast quality must also run error-free.
        _ = try PersonSegmenter(quality: .fast).segmentNow(frame)
        print("  ✓ Vision segmentation: fast quality level runs error-free")
    }

    // MARK: - 7. Async submit pipeline: rate limiting + latest-wins + accounting

    private static func testSubmitPipeline() throws {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var mattes: [SegmentationMatte] = []
            var errors: [Error] = []
        }
        let box = Box()
        let segmenter = PersonSegmenter(quality: .balanced, targetRate: 15)
        segmenter.onMatte = { m in box.lock.lock(); box.mattes.append(m); box.lock.unlock() }
        segmenter.onError = { e in box.lock.lock(); box.errors.append(e); box.lock.unlock() }

        // 30 frames at a simulated 120 fps (PTS-spaced) → the 15 Hz limiter
        // must drop most; Vision busy-drops (latest wins) may drop more.
        let submitted = 30
        var allPTS: Set<CMTime> = []
        for i in 0..<submitted {
            let pts = CMTime(value: CMTimeValue(i), timescale: 120)
            allPTS.insert(pts)
            let frame = try makePersonishFrame(pts: pts, id: "selftest.submit")
            segmenter.submit(frame)
        }

        // Wait (bounded) for the queue to drain — first Vision run loads the model.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let s = segmenter.stats
            if segmenter.isIdle, s.rateLimited + s.superseded + s.processed == submitted { break }
            usleep(20_000)
        }
        let stats = segmenter.stats
        guard segmenter.isIdle, stats.rateLimited + stats.superseded + stats.processed == submitted else {
            throw SelfTestError.mismatch("submit: pipeline did not drain — \(stats)")
        }
        guard stats.submitted == submitted, stats.processed >= 1, stats.errors == 0,
              stats.rateLimited >= 20 else {
            throw SelfTestError.mismatch("submit: accounting wrong — \(stats)")
        }
        box.lock.lock()
        let mattes = box.mattes
        let errors = box.errors
        box.lock.unlock()
        guard errors.isEmpty else {
            throw SelfTestError.mismatch("submit: onError fired: \(errors)")
        }
        guard mattes.count == stats.mattes else {
            throw SelfTestError.mismatch("submit: \(mattes.count) callbacks but stats.mattes=\(stats.mattes)")
        }
        for matte in mattes {
            guard allPTS.contains(matte.pts), matte.source == SourceID("selftest.submit") else {
                throw SelfTestError.mismatch("submit: callback carries unknown pts/source (\(matte.pts))")
            }
        }
        print("  ✓ submit pipeline: 30 @ 120fps → rateLimited \(stats.rateLimited), superseded \(stats.superseded), "
              + "processed \(stats.processed), mattes \(stats.mattes), errors 0 (non-blocking, latest-wins)")
    }
}
