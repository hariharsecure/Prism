import CoreMedia
import CoreVideo
import Foundation
import Metal
import PrismCore
import simd

/// Headless self-verification of the whole color stage (no TCC, no capture
/// hardware) — real GPU passes on synthetic buffers.
///
/// TEST CODE ONLY: this file locks pixel-buffer base addresses to fill
/// synthetic inputs and read back outputs. That is explicitly allowed here
/// and **forbidden on the engine hot path** — the processors themselves
/// never touch pixels on the CPU.
///
/// Wire `ColorSelfTest.run()` into prism-dev or an XCTest target; it throws
/// with a precise message on the first mismatch.
public enum ColorSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case setupFailed(String)
        case mismatch(String)
        public var description: String {
            switch self {
            case .setupFailed(let s): return "color self-test setup failed: \(s)"
            case .mismatch(let s): return "color self-test mismatch: \(s)"
            }
        }
    }

    public static func run() throws {
        // Pure-math checks first (no GPU).
        try testCubeParser()
        try testTemporalSmoother()

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SelfTestError.setupFailed("no Metal device")
        }
        let processor = try ColorProcessor(device: device)
        let analyzer = try FrameAnalyzer(device: device)

        try testIdentityGrade(processor)
        try testExposureOneStop(processor)
        try testSaturationZero(processor)
        try testYUVIdentity(processor)
        try testIdentityLUT(processor)
        try testOneDLUTInversion(processor)
        try testAutoColorGrayWorld(processor, analyzer)
        try testShotMatch(processor, analyzer)
        try testRelight(device)

        print("ColorSelfTest: all checks passed")
    }

    // MARK: - 1. CubeLUT parser (pure)

    private static func testCubeParser() throws {
        let cube = """
        # a tiny test cube
        TITLE "tiny"
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0

        LUT_3D_SIZE 2
        # data: identity with red/blue swapped (b g r per row)
        0.0 0.0 0.0
        0.0 0.0 1.0
        0.0 1.0 0.0
        0.0 1.0 1.0
        1.0 0.0 0.0
        1.0 0.0 1.0
        1.0 1.0 0.0
        1.0 1.0 1.0
        """
        let lut = try CubeLUT(string: cube)
        guard lut.dimension == .threeD, lut.size == 2, lut.title == "tiny",
              lut.data.count == 24, lut.domainMin == SIMD3(repeating: 0),
              lut.domainMax == SIMD3(repeating: 1) else {
            throw SelfTestError.mismatch("cube parse: size=\(lut.size) title=\(lut.title ?? "nil") count=\(lut.data.count)")
        }
        // Entry for (r=1,g=0,b=0) is index 1 → expect (0,0,1): red→blue swap.
        guard lut.data[3] == 0, lut.data[4] == 0, lut.data[5] == 1 else {
            throw SelfTestError.mismatch("cube parse: entry[1] = \(Array(lut.data[3...5])), expected [0,0,1]")
        }

        func expectError(_ text: String, _ expected: CubeLUTError, _ what: String) throws {
            do {
                _ = try CubeLUT(string: text)
                throw SelfTestError.mismatch("cube parser accepted \(what)")
            } catch let error as CubeLUTError {
                guard error == expected else {
                    throw SelfTestError.mismatch("cube parser: \(what) → \(error), expected \(expected)")
                }
            }
        }
        try expectError("0 0 0\n1 1 1\n", .missingSize, "data without a size")
        try expectError("LUT_3D_SIZE 2\n0 0 0\n", .entryCountMismatch(expected: 8, found: 1), "short data")
        try expectError("LUT_3D_SIZE 2\nLUT_1D_SIZE 4\n", .conflictingSize, "two sizes")
        try expectError("LUT_1D_SIZE 2\n0 0\n1 1 1\n", .malformedLine(line: 2, content: "0 0"), "2-float row")
        try expectError("LUT_3D_SIZE 200\n", .invalidSize(200), "size 200")
        print("  ✓ CubeLUT parser (3D parse, domain, title, 5 error cases)")
    }

    // MARK: - 2. TemporalSmoother (pure)

    private static func testTemporalSmoother() throws {
        var smoother = TemporalSmoother(timeConstant: 0.5)
        guard smoother.update(target: 0, at: 0) == 0 else {
            throw SelfTestError.mismatch("smoother: first sample must pass through")
        }
        var previous = 0.0
        var t = 0.0
        while t < 3.0 { // 6 time constants of a unit step
            t += 0.05
            let v = smoother.update(target: 1, at: t)
            guard v >= previous - 1e-12, v <= 1 + 1e-12 else {
                throw SelfTestError.mismatch("smoother: non-monotonic or overshoot at t=\(t): \(v)")
            }
            previous = v
        }
        guard abs(previous - 1) < 0.01 else {
            throw SelfTestError.mismatch("smoother: after 6τ expected ≈1, got \(previous)")
        }
        // ~63% after exactly one time constant.
        var s2 = TemporalSmoother(timeConstant: 1.0)
        s2.update(target: 0, at: 0)
        let oneTau = s2.update(target: 1, at: 1)
        guard abs(oneTau - 0.632) < 0.01 else {
            throw SelfTestError.mismatch("smoother: after 1τ expected ≈0.632, got \(oneTau)")
        }
        print("  ✓ TemporalSmoother (pass-through, monotone, no overshoot, 63.2% @ 1τ)")
    }

    // MARK: - GPU test helpers

    private static let testW = 320, testH = 180

    private static func makeBGRAFrame(_ fill: (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8),
                                      id: String) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: testW, height: testH,
                                       pixelFormat: kCVPixelFormatType_32BGRA, minimumBufferCount: 1)
        let buffer = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<testH {
            for col in 0..<testW {
                let c = fill(col, row)
                let p = base + row * bytesPerRow + col * 4
                p[0] = c.b; p[1] = c.g; p[2] = c.r; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return VideoFrame(pixelBuffer: buffer, pts: HouseClock.now(), source: SourceID(id))
    }

    private static func readPixel(_ frame: VideoFrame, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let buffer = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (Int(p[2]), Int(p[1]), Int(p[0]))
    }

    private static func meanRGB(_ frame: VideoFrame, xRange: Range<Int>, yRange: Range<Int>) -> (r: Double, g: Double, b: Double) {
        let buffer = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        var sum = (r: 0.0, g: 0.0, b: 0.0)
        var n = 0.0
        for y in yRange {
            for x in xRange {
                let p = base + y * bpr + x * 4
                sum.b += Double(p[0]); sum.g += Double(p[1]); sum.r += Double(p[2])
                n += 1
            }
        }
        return (sum.r / n / 255, sum.g / n / 255, sum.b / n / 255)
    }

    // MARK: - 3. Identity grade = pass-through

    private static func testIdentityGrade(_ processor: ColorProcessor) throws {
        let frame = try makeBGRAFrame({ col, row in
            (r: UInt8(col * 255 / (testW - 1)), g: UInt8(row * 255 / (testH - 1)), b: 128)
        }, id: "selftest.identity")
        let out = try processor.process(frame, grade: .identity, lut: nil)
        guard out.width == testW, out.height == testH,
              out.pixelFormat == kCVPixelFormatType_32BGRA,
              CMTimeCompare(out.pts, frame.pts) == 0 else {
            throw SelfTestError.mismatch("identity: output shape/pts wrong")
        }
        for (x, y) in [(0, 0), (10, 20), (160, 90), (200, 33), (319, 179)] {
            let want = readPixel(frame, x: x, y: y)
            let got = readPixel(out, x: x, y: y)
            guard abs(want.r - got.r) <= 1, abs(want.g - got.g) <= 1, abs(want.b - got.b) <= 1 else {
                throw SelfTestError.mismatch("identity grade at (\(x),\(y)): got \(got), want \(want) ±1")
            }
        }
        print("  ✓ identity grade = pass-through (±1)")
    }

    // MARK: - 4. Exposure +1 stop doubles linear values

    private static func testExposureOneStop(_ processor: ColorProcessor) throws {
        // Under the stated 2.2-power transfer: out_gamma = (2·in^2.2)^(1/2.2).
        let frame = try makeBGRAFrame({ _, _ in (r: 64, g: 64, b: 64) }, id: "selftest.exposure")
        let out = try processor.process(frame, grade: ColorGrade(exposure: 1), lut: nil)
        let got = readPixel(out, x: 160, y: 90)
        let inLinear = pow(64.0 / 255.0, 2.2)
        let outLinear = pow(Double(got.r) / 255.0, 2.2)
        let ratio = outLinear / inLinear
        guard abs(ratio - 2.0) < 0.12 else { // 8-bit quantization allowance
            throw SelfTestError.mismatch("exposure +1: linear ratio \(ratio), expected 2.0 ±0.12 (got \(got))")
        }
        print(String(format: "  ✓ exposure +1 stop: linear ratio %.3f (expected 2.0; gamma 64→%d)", ratio, got.r))
    }

    // MARK: - 5. Saturation 0 → gray

    private static func testSaturationZero(_ processor: ColorProcessor) throws {
        let frame = try makeBGRAFrame({ _, _ in (r: 255, g: 0, b: 0) }, id: "selftest.sat")
        let out = try processor.process(frame, grade: ColorGrade(saturation: 0), lut: nil)
        let got = readPixel(out, x: 160, y: 90)
        // BT.709 luma of pure red in gamma space: 0.2126 → ≈54.
        guard abs(got.r - got.g) <= 2, abs(got.g - got.b) <= 2, abs(got.r - 54) <= 3 else {
            throw SelfTestError.mismatch("saturation 0: got \(got), expected neutral ≈(54,54,54)")
        }
        print("  ✓ saturation 0 → gray (pure red → \(got))")
    }

    // MARK: - 6. YUV input path (420f identity)

    private static func testYUVIdentity(_ processor: ColorProcessor) throws {
        let pool = try PixelBufferPool(width: testW, height: testH,
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
        let out = try processor.process(frame, grade: .identity, lut: nil)
        let got = readPixel(out, x: 160, y: 90)
        guard abs(got.r - 0) <= 4, abs(got.g - 255) <= 4, abs(got.b - 0) <= 4 else {
            throw SelfTestError.mismatch("420f green through identity grade: got \(got), expected (0,255,0) ±4")
        }
        print("  ✓ 420f YUV input path (green → \(got))")
    }

    // MARK: - 7. Identity 3D LUT = pass-through

    private static func testIdentityLUT(_ processor: ColorProcessor) throws {
        // Build the identity .cube TEXT and run it through the parser too.
        var text = "TITLE \"identity8\"\nLUT_3D_SIZE 8\n"
        let n = 8
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    text += String(format: "%.6f %.6f %.6f\n",
                                   Double(r) / Double(n - 1), Double(g) / Double(n - 1), Double(b) / Double(n - 1))
                }
            }
        }
        let lut = try CubeLUT(string: text)
        let frame = try makeBGRAFrame({ col, row in
            (r: UInt8(col * 255 / (testW - 1)), g: UInt8((col + row) * 255 / (testW + testH - 2)), b: UInt8(row * 255 / (testH - 1)))
        }, id: "selftest.lut")
        let out = try processor.process(frame, grade: .identity, lut: lut)
        for (x, y) in [(5, 5), (100, 60), (160, 90), (250, 140), (315, 175)] {
            let want = readPixel(frame, x: x, y: y)
            let got = readPixel(out, x: x, y: y)
            guard abs(want.r - got.r) <= 2, abs(want.g - got.g) <= 2, abs(want.b - got.b) <= 2 else {
                throw SelfTestError.mismatch("identity LUT at (\(x),\(y)): got \(got), want \(want) ±2")
            }
        }
        print("  ✓ identity 3D LUT (8³, parsed from text) = pass-through (±2)")
    }

    // MARK: - 8. 1D LUT (inversion curve) applies

    private static func testOneDLUTInversion(_ processor: ColorProcessor) throws {
        let lut = try CubeLUT(string: "LUT_1D_SIZE 2\n1.0 1.0 1.0\n0.0 0.0 0.0\n")
        let frame = try makeBGRAFrame({ _, _ in (r: 64, g: 128, b: 192) }, id: "selftest.lut1d")
        let out = try processor.process(frame, grade: .identity, lut: lut)
        let got = readPixel(out, x: 160, y: 90)
        guard abs(got.r - 191) <= 2, abs(got.g - 127) <= 2, abs(got.b - 63) <= 2 else {
            throw SelfTestError.mismatch("1D inversion LUT: got \(got), expected ≈(191,127,63)")
        }
        print("  ✓ 1D LUT inversion curve ((64,128,192) → \(got))")
    }

    // MARK: - 9. AutoColor gray-world corrects a blue-tinted frame

    private static func testAutoColorGrayWorld(_ processor: ColorProcessor, _ analyzer: FrameAnalyzer) throws {
        // A realistic blue cast (needs ≈ +0.70 temperature — inside the WB
        // clamp; casts beyond the clamp are corrected partially, by design).
        let frame = try makeBGRAFrame({ _, _ in (r: 90, g: 100, b: 140) }, id: "selftest.autocolor")
        let before = try analyzer.analyze(frame)
        let spreadBefore = max(before.meanR, before.meanG, before.meanB)
                         - min(before.meanR, before.meanG, before.meanB)
        let suggestion = AutoColor.suggest(from: before)
        guard suggestion.temperature > 0 else { // blue cast → warm correction
            throw SelfTestError.mismatch("autocolor: expected warm (positive) temperature, got \(suggestion.temperature)")
        }
        // Apply ONLY the WB part so the check isolates gray-world behavior.
        var grade = ColorGrade()
        grade.temperature = suggestion.temperature
        grade.tint = suggestion.tint
        let corrected = try processor.process(frame, grade: grade, lut: nil)
        let after = try analyzer.analyze(corrected)
        let spreadAfter = max(after.meanR, after.meanG, after.meanB)
                        - min(after.meanR, after.meanG, after.meanB)
        guard spreadAfter < spreadBefore * 0.35 else {
            throw SelfTestError.mismatch(
                "autocolor: channel-mean spread \(spreadBefore) → \(spreadAfter), wanted ≥65% reduction "
                + "(before: \(before.meanR),\(before.meanG),\(before.meanB); after: \(after.meanR),\(after.meanG),\(after.meanB))")
        }
        print(String(format: "  ✓ AutoColor gray-world: spread %.3f → %.3f (temp %+.2f, tint %+.2f)",
                     spreadBefore, spreadAfter, suggestion.temperature, suggestion.tint))
    }

    // MARK: - 10. ShotMatch maps target stats onto reference

    private static func testShotMatch(_ processor: ColorProcessor, _ analyzer: FrameAnalyzer) throws {
        // Reference: split-color pattern (non-zero per-channel σ).
        let reference = try makeBGRAFrame({ col, _ in
            col < testW / 2 ? (r: 200, g: 120, b: 60) : (r: 60, g: 120, b: 200)
        }, id: "selftest.match.ref")
        // Target: same pattern through a per-channel squash + lift → different means AND σ.
        func squash(_ v: Int) -> UInt8 { UInt8(min(255, Int(Double(v) * 0.7 + 20))) }
        let target = try makeBGRAFrame({ col, _ in
            col < testW / 2 ? (r: squash(200), g: squash(120), b: squash(60))
                            : (r: squash(60), g: squash(120), b: squash(200))
        }, id: "selftest.match.target")

        let refStats = try analyzer.analyze(reference)
        let targetStats = try analyzer.analyze(target)
        let correction = ShotMatch.correction(reference: refStats, target: targetStats)

        // Pure math: correcting the target means must land exactly on reference means.
        for (name, got, want) in [
            ("R", correction.red.apply(targetStats.meanR), refStats.meanR),
            ("G", correction.green.apply(targetStats.meanG), refStats.meanG),
            ("B", correction.blue.apply(targetStats.meanB), refStats.meanB),
        ] {
            guard abs(got - want) < 1e-9 else {
                throw SelfTestError.mismatch("shotmatch math \(name): \(got) vs \(want)")
            }
        }

        // GPU round-trip: the ColorGrade expression of the correction must
        // land the processed frame's means on the reference within tolerance.
        let matched = try processor.process(target, grade: correction.asColorGrade(), lut: nil)
        let after = try analyzer.analyze(matched)
        for (name, got, want) in [("R", after.meanR, refStats.meanR),
                                  ("G", after.meanG, refStats.meanG),
                                  ("B", after.meanB, refStats.meanB)] {
            guard abs(got - want) < 0.02 else {
                throw SelfTestError.mismatch("shotmatch GPU \(name): mean \(got) vs reference \(want) (±0.02)")
            }
        }
        print(String(format: "  ✓ ShotMatch: means (%.3f,%.3f,%.3f) → (%.3f,%.3f,%.3f), ref (%.3f,%.3f,%.3f)",
                     targetStats.meanR, targetStats.meanG, targetStats.meanB,
                     after.meanR, after.meanG, after.meanB,
                     refStats.meanR, refStats.meanG, refStats.meanB))
    }

    // MARK: - 11. Relight on a synthetic depth ramp

    private static func testRelight(_ device: MTLDevice) throws {
        let relight = try RelightProcessor(device: device)
        relight.ambient = 0.35
        relight.depthScale = 1.0

        let frame = try makeBGRAFrame({ _, _ in (r: 128, g: 128, b: 128) }, id: "selftest.relight")

        // Depth ramp, half video resolution: near (0) at left → far (1) at right.
        let dw = testW / 2, dh = testH / 2
        let depthPool = try PixelBufferPool(width: dw, height: dh,
                                            pixelFormat: kCVPixelFormatType_DepthFloat32,
                                            minimumBufferCount: 1)
        let depth = try depthPool.makeBuffer()
        CVPixelBufferLockBaseAddress(depth, [])
        let base = CVPixelBufferGetBaseAddress(depth)!.assumingMemoryBound(to: Float32.self)
        let stride = CVPixelBufferGetBytesPerRow(depth) / MemoryLayout<Float32>.size
        for row in 0..<dh {
            for col in 0..<dw {
                base[row * stride + col] = Float(col) / Float(dw - 1)
            }
        }
        CVPixelBufferUnlockBaseAddress(depth, [])

        // Key light at the left front.
        let light = VirtualLight(position: SIMD3(0.15, 0.5, -0.4),
                                 intensity: 1.6, specular: 0.1, shininess: 32, attenuation: 3)
        let out = try relight.process(frame: frame, depth: depth, lights: [light])
        guard out.width == testW, out.height == testH else {
            throw SelfTestError.mismatch("relight: output shape wrong")
        }
        let left = meanRGB(out, xRange: 10..<(testW / 4), yRange: testH / 4..<(3 * testH / 4))
        let right = meanRGB(out, xRange: (3 * testW / 4)..<(testW - 10), yRange: testH / 4..<(3 * testH / 4))
        guard left.r > right.r * 1.15, left.g > right.g * 1.15 else {
            throw SelfTestError.mismatch("relight: lit side not brighter — left \(left), right \(right)")
        }
        // No-lights pass must still run (ambient-only darkening) without error.
        let ambientOnly = try relight.process(frame: frame, depth: depth, lights: [])
        let ambientMean = meanRGB(ambientOnly, xRange: 0..<testW, yRange: 0..<testH)
        guard ambientMean.r < 0.45 else {
            throw SelfTestError.mismatch("relight ambient-only: mean \(ambientMean.r), expected < input 0.5")
        }
        print(String(format: "  ✓ Relight: lit-side mean %.3f vs unlit %.3f (ramp depth, key light); ambient-only %.3f",
                     left.r, right.r, ambientMean.r))
    }
}
