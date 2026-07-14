import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import Foundation
import XCTest
import PrismCore
import PrismSources

/// XCTest gate for the presenter-cutout ("green screen without a green screen")
/// source. Three layers:
///  1. `PresenterCutoutSelfTest.run()` — deterministic compositing asserts
///     (transparent/feather/solid/no-person + a real Vision smoke run).
///  2. Injected-matte compositing MATH verified at pixel level here, with PNG
///     dumps for eyeballing.
///  3. Real Vision segmentation on an actual person photo (an illustrated
///     portrait from the Two Horizons character refs) — reported honestly and
///     dumped; skipped gracefully if the file is absent (never hard-fails CI).
///
/// PNG dumps land in the scratchpad dir for the lead to inspect.
final class PresenterCutoutTests: XCTestCase {
    private static let dumpDir = "/tmp/prism_cutout"
    private static let gpuDumpDir = "/tmp/prism_cutout_gpu"
    private static let realPhoto = (ProcessInfo.processInfo.environment["PRISM_SELFTEST_PHOTO"] ?? "")

    override class func setUp() {
        try? FileManager.default.createDirectory(atPath: dumpDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: gpuDumpDir, withIntermediateDirectories: true)
    }

    // MARK: - 1. Headless self-test (the full deterministic suite)

    func testSelfTest() throws {
        try PresenterCutoutSelfTest.run()
    }

    // MARK: - 1b. No onFrame after stop() (post-stop-frame robustness fix)

    /// LOW robustness fix: a frame already dequeued by the worker before `stop()`
    /// must NOT fire `onFrame` after `stop()` returns. Drives the push path
    /// directly through a controllable upstream and asserts the callback count is
    /// stable across `stop()`.
    func testNoFrameAfterStop() throws {
        let upstream = ManualUpstream()
        let source = PresenterCutoutSource(wrapping: upstream, options: .init(quality: .fast))

        let counter = CutoutCounter()
        source.onFrame = { _ in counter.bump() }
        try source.start()

        // One reusable BGRA frame is enough — the worker reads it per push.
        let frame = try PresenterCutoutSelfTest.makeBGRAFrame(width: 160, height: 120, id: "push") { _, _ in
            (r: 120, g: 130, b: 140)
        }

        // Hammer the push path (upstream.onFrame == source.submit) from a
        // background queue so a cutout is in flight when stop() lands.
        let feeding = FeedFlag()
        DispatchQueue.global(qos: .userInitiated).async {
            while feeding.get() { upstream.onFrame?(frame); usleep(400) }
        }

        // Let the pipeline process for a bit, then stop mid-stream.
        Thread.sleep(forTimeInterval: 0.15)
        source.stop()
        let atStop = counter.value          // count captured the instant stop() returns
        feeding.set(false)

        // Give any (buggy) in-flight callback ample time to fire after stop().
        Thread.sleep(forTimeInterval: 0.4)
        // Post-stop pushes must be ignored, and no in-flight callback may land.
        upstream.onFrame?(frame)
        Thread.sleep(forTimeInterval: 0.1)
        let later = counter.value

        XCTAssertGreaterThan(atStop, 0, "sanity: frames must process before stop()")
        XCTAssertEqual(later, atStop, "no onFrame may fire after stop(): \(later - atStop) fired post-stop")
        XCTAssertEqual(source.state, .idle)
    }

    // MARK: - 2. Injected-matte compositing math + PNG dumps

    func testInjectedMatteCompositing() throws {
        let W = 256, H = 256
        // Input: left half warm, right half cool, plus a bright band so the
        // premultiply is visible in the dump.
        let frame = try PresenterCutoutSelfTest.makeBGRAFrame(width: W, height: H, id: "test.injected") { x, y in
            let base: (r: UInt8, g: UInt8, b: UInt8) = x < W / 2 ? (230, 90, 40) : (40, 90, 230)
            return y % 32 < 4 ? (255, 255, 255) : base
        }
        // Matte: a centred disc (person) on black (background), full-res.
        let cx = W / 2, cy = H / 2, r = 90
        let matte = try PresenterCutoutSelfTest.makeMatte(width: W, height: H) { x, y in
            let dx = x - cx, dy = y - cy
            return (dx * dx + dy * dy) <= r * r ? 255 : 0
        }

        let cutout = PresenterCutout(options: .init(background: .transparent, feather: 6))
        let out = try cutout.composite(frame: frame, matte: matte)

        // --- Assertions ---
        XCTAssertEqual(out.pixelFormat, kCVPixelFormatType_32BGRA, "output must be BGRA")
        XCTAssertNotNil(CVPixelBufferGetIOSurface(out.pixelBuffer), "output must be IOSurface-backed")
        XCTAssertEqual(out.width, W); XCTAssertEqual(out.height, H)

        // Person interior (disc centre, on a non-band row): opaque passthrough.
        let center = PresenterCutoutSelfTest.readBGRA(out, x: cx, y: cy + 5)
        let src = PresenterCutoutSelfTest.readBGRA(frame, x: cx, y: cy + 5)
        XCTAssertEqual(center.a, 255, "matte=1 → opaque")
        XCTAssertEqual(center.r, src.r, accuracy: 1); XCTAssertEqual(center.g, src.g, accuracy: 1)
        XCTAssertEqual(center.b, src.b, accuracy: 1)

        // Background corner (matte=0): transparent black — NOT opaque black.
        let corner = PresenterCutoutSelfTest.readBGRA(out, x: 4, y: 4)
        XCTAssertEqual(corner.a, 0, "matte=0 → alpha 0")
        XCTAssertEqual(corner.r, 0); XCTAssertEqual(corner.g, 0); XCTAssertEqual(corner.b, 0)

        // Feather band: some pixel on the disc edge is partially transparent and
        // premultiplied (rgb ≈ src·a/255).
        var foundSoft = false
        for t in 0..<r * 2 {
            let x = cx - r - 4 + t
            let px = PresenterCutoutSelfTest.readBGRA(out, x: x, y: cy)
            if px.a > 8 && px.a < 247 {
                let s = PresenterCutoutSelfTest.readBGRA(frame, x: x, y: cy)
                let expected = Int((Double(s.r) * Double(px.a) / 255.0).rounded())
                XCTAssertLessThanOrEqual(abs(px.r - expected), 2, "feather edge must stay premultiplied")
                foundSoft = true
            }
        }
        XCTAssertTrue(foundSoft, "feather must create a soft (partial-alpha) edge band")

        // --- Dumps ---
        try dumpBGRA(frame.pixelBuffer, to: "\(Self.dumpDir)/injected_input.png")
        try dumpMatte(matte, to: "\(Self.dumpDir)/injected_matte.png")
        try dumpBGRA(out.pixelBuffer, to: "\(Self.dumpDir)/injected_cutout_transparent.png")
        // Composite over magenta so the transparency is unambiguous when eyeballed.
        let overMagenta = try PresenterCutout(options: .init(background: .solidColor(RGBAColor(r: 1, g: 0, b: 1)), feather: 6))
            .composite(frame: frame, matte: matte)
        try dumpBGRA(overMagenta.pixelBuffer, to: "\(Self.dumpDir)/injected_cutout_over_magenta.png")
    }

    // MARK: - 3. Real Vision segmentation on an actual person photo

    func testRealPhotoVisionSmoke() throws {
        guard FileManager.default.fileExists(atPath: Self.realPhoto) else {
            throw XCTSkip("real person photo not present at \(Self.realPhoto)")
        }
        let frame = try loadPhotoFrame(path: Self.realPhoto, id: "test.realphoto")
        let cutout = PresenterCutout(options: .init(quality: .accurate, background: .transparent, feather: 3))

        try dumpBGRA(frame.pixelBuffer, to: "\(Self.dumpDir)/real_input.png")

        let matte = try cutout.segmentMatte(frame)
        if let matte {
            // Vision DID segment the (illustrated) person.
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(matte), kCVPixelFormatType_OneComponent8)
            let mW = CVPixelBufferGetWidth(matte), mH = CVPixelBufferGetHeight(matte)
            let out = try cutout.composite(frame: frame, matte: matte)
            XCTAssertEqual(out.pixelFormat, kCVPixelFormatType_32BGRA)
            XCTAssertNotNil(CVPixelBufferGetIOSurface(out.pixelBuffer))

            // Coverage stat: fraction of matte pixels that are "person".
            let coverage = matteCoverage(matte)
            try dumpMatte(matte, to: "\(Self.dumpDir)/real_matte.png")
            try dumpBGRA(out.pixelBuffer, to: "\(Self.dumpDir)/real_cutout_transparent.png")
            let overMagenta = try PresenterCutout(options: .init(background: .solidColor(RGBAColor(r: 1, g: 0, b: 1)), feather: 3))
                .composite(frame: frame, matte: matte)
            try dumpBGRA(overMagenta.pixelBuffer, to: "\(Self.dumpDir)/real_cutout_over_magenta.png")
            print("  [real photo] Vision segmented a person: matte \(mW)×\(mH), coverage \(String(format: "%.1f%%", coverage * 100))")
        } else {
            // No detection — the request still ran error-free. Dump a fully
            // transparent frame (the documented no-person default).
            let out = try cutout.composite(frame: frame, matte: nil)
            XCTAssertEqual(out.pixelFormat, kCVPixelFormatType_32BGRA)
            try dumpBGRA(out.pixelBuffer, to: "\(Self.dumpDir)/real_cutout_transparent.png")
            print("  [real photo] Vision found NO person (illustration) — no-person transparent frame emitted")
        }
    }

    // MARK: - 4. GPU cutout matches the CPU reference (the correctness oracle)

    /// The GPU path (`composite`, delegating to `PrismVision.BackgroundEffect`)
    /// must reproduce the CPU reference (`cpuReferenceComposite`) within a tight
    /// tolerance on injected full-res mattes — transparent, solid-colour fill,
    /// and a feathered edge band. Also dumps the GPU cutout over a colour so the
    /// background is revealed with no black halo.
    func testGPUMatchesCPUReference() throws {
        let W = 256, H = 256
        let frame = try PresenterCutoutSelfTest.makeBGRAFrame(width: W, height: H, id: "gpu.vs.cpu") { x, y in
            let base: (r: UInt8, g: UInt8, b: UInt8) = x < W / 2 ? (230, 90, 40) : (40, 90, 230)
            return y % 32 < 4 ? (255, 255, 255) : base
        }
        let cx = W / 2, cy = H / 2, r = 90
        let matte = try PresenterCutoutSelfTest.makeMatte(width: W, height: H) { x, y in
            let dx = x - cx, dy = y - cy
            return (dx * dx + dy * dy) <= r * r ? 255 : 0
        }

        struct Case { let name: String; let opts: PresenterCutout.Options; let rgbTol: Int; let aTol: Int }
        let cases = [
            Case(name: "transparent/feather0",
                 opts: .init(background: .transparent, feather: 0), rgbTol: 2, aTol: 1),
            Case(name: "transparent/feather6",
                 opts: .init(background: .transparent, feather: 6), rgbTol: 4, aTol: 4),
            Case(name: "solid-magenta/feather6",
                 opts: .init(background: .solidColor(RGBAColor(r: 1, g: 0, b: 1)), feather: 6), rgbTol: 4, aTol: 1),
        ]

        for c in cases {
            let cutout = PresenterCutout(options: c.opts)
            let gpu = try cutout.composite(frame: frame, matte: matte)
            let cpu = try cutout.cpuReferenceComposite(frame: frame, matte: matte)
            XCTAssertNotNil(CVPixelBufferGetIOSurface(gpu.pixelBuffer), "\(c.name): GPU output must be IOSurface")
            let d = Self.maxChannelDiff(gpu, cpu)
            print("  [gpu-vs-cpu] \(c.name): max |Δ| r=\(d.r) g=\(d.g) b=\(d.b) a=\(d.a) (tol rgb=\(c.rgbTol) a=\(c.aTol))")
            XCTAssertLessThanOrEqual(max(d.r, max(d.g, d.b)), c.rgbTol, "\(c.name): GPU rgb diverges from CPU reference")
            XCTAssertLessThanOrEqual(d.a, c.aTol, "\(c.name): GPU alpha diverges from CPU reference")
        }

        // PNG proof: GPU cutout composited over an opaque colour reveals the
        // background with no black halo at the matte edge.
        let overCyan = try PresenterCutout(options: .init(background: .solidColor(RGBAColor(r: 0, g: 0.7, b: 0.9)), feather: 6))
            .composite(frame: frame, matte: matte)
        let transparentGPU = try PresenterCutout(options: .init(background: .transparent, feather: 6))
            .composite(frame: frame, matte: matte)
        try dumpBGRA(transparentGPU.pixelBuffer, to: "\(Self.gpuDumpDir)/gpu_cutout_transparent.png")
        try dumpBGRA(overCyan.pixelBuffer, to: "\(Self.gpuDumpDir)/gpu_cutout_over_cyan.png")
    }

    // MARK: - 5. Timing: CPU composite vs GPU composite at 1080p and 4K

    /// Measures the median per-frame cost of the old CPU composite vs the new
    /// GPU path at 1080p and 4K, and prints them. Not asserted hard (timing is
    /// machine-dependent) beyond a sanity check that the GPU path is faster.
    func testTimingCPUvsGPU() throws {
        for (label, W, H) in [("1080p", 1920, 1080), ("4K", 3840, 2160)] {
            let frame = try PresenterCutoutSelfTest.makeBGRAFrame(width: W, height: H, id: "timing.\(label)") { x, _ in
                x < W / 2 ? (r: 210, g: 120, b: 60) : (r: 30, g: 80, b: 200)
            }
            // A LOW-res matte (like Vision emits) so both paths do a real upscale.
            let mW = W / 4, mH = H / 4
            let matte = try PresenterCutoutSelfTest.makeMatte(width: mW, height: mH) { x, _ in
                x < mW / 2 ? 255 : 0
            }
            let iters = label == "4K" ? 5 : 12
            // Pure-GPU path (feather 0 = the default live case: NO CPU pixel work).
            let cpu0 = PresenterCutout(options: .init(background: .transparent, feather: 0))
            let gpu0 = PresenterCutout(options: .init(background: .transparent, feather: 0))
            _ = try cpu0.cpuReferenceComposite(frame: frame, matte: matte)
            _ = try gpu0.composite(frame: frame, matte: matte)
            let cpu0Ms = Self.medianMs(iters) { _ = try? cpu0.cpuReferenceComposite(frame: frame, matte: matte) as VideoFrame? }
            let gpu0Ms = Self.medianMs(iters) { _ = try? gpu0.composite(frame: frame, matte: matte) as VideoFrame? }
            print(String(format: "  [timing %@ feather=0] CPU %.2f ms  →  GPU %.2f ms  (%.1f× faster)",
                         label, cpu0Ms, gpu0Ms, cpu0Ms / max(gpu0Ms, 0.0001)))

            // With feather (GPU composite + a small matte-resolution CPU blur).
            let cpu3 = PresenterCutout(options: .init(background: .transparent, feather: 3))
            let gpu3 = PresenterCutout(options: .init(background: .transparent, feather: 3))
            _ = try cpu3.cpuReferenceComposite(frame: frame, matte: matte)
            _ = try gpu3.composite(frame: frame, matte: matte)
            let cpu3Ms = Self.medianMs(iters) { _ = try? cpu3.cpuReferenceComposite(frame: frame, matte: matte) as VideoFrame? }
            let gpu3Ms = Self.medianMs(iters) { _ = try? gpu3.composite(frame: frame, matte: matte) as VideoFrame? }
            print(String(format: "  [timing %@ feather=3] CPU %.2f ms  →  GPU %.2f ms  (%.1f× faster)",
                         label, cpu3Ms, gpu3Ms, cpu3Ms / max(gpu3Ms, 0.0001)))
            XCTAssertLessThan(gpu0Ms, cpu0Ms, "\(label): GPU composite should beat the CPU composite")
        }
    }

    // MARK: - 6. YUV camera input now works (was a documented BGRA-only gap)

    /// The old CPU path threw `.unsupportedInputFormat` on YUV; the GPU
    /// `BackgroundEffect` samples biplanar YUV natively, so a 420f frame now
    /// composites to a correct premultiplied BGRA cutout.
    func testYUVInputNowWorks() throws {
        let W = 320, H = 240
        // 420f (full-range) frame: constant mid-gray (luma 0.6, neutral chroma).
        let frame = try Self.makeYUVFrame(width: W, height: H, id: "yuv.cutout", luma: 153, cb: 128, cr: 128)
        // Left = person, right = background.
        let matte = try PresenterCutoutSelfTest.makeMatte(width: W, height: H) { x, _ in x < W / 2 ? 255 : 0 }

        let cutout = PresenterCutout(options: .init(background: .transparent, feather: 0))
        // CPU reference must still reject YUV (documents the old gap).
        XCTAssertThrowsError(try cutout.cpuReferenceComposite(frame: frame, matte: matte))

        // GPU path succeeds.
        let out = try cutout.composite(frame: frame, matte: matte)
        XCTAssertEqual(out.pixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(out.pixelBuffer))
        let fg = PresenterCutoutSelfTest.readBGRA(out, x: 60, y: 120)
        let bg = PresenterCutoutSelfTest.readBGRA(out, x: 260, y: 120)
        XCTAssertEqual(fg.a, 255, "YUV person region must be opaque")
        XCTAssertTrue(fg.r > 100 && fg.g > 100 && fg.b > 100, "YUV person region decodes to ~mid-gray, got \(fg)")
        XCTAssertEqual(bg.a, 0, "YUV background must be transparent")
        XCTAssertEqual(bg.r, 0); XCTAssertEqual(bg.g, 0); XCTAssertEqual(bg.b, 0)
        try dumpBGRA(out.pixelBuffer, to: "\(Self.gpuDumpDir)/gpu_cutout_from_yuv.png")
        print("  [yuv] 420f frame → GPU cutout: fg \(fg) opaque, bg \(bg) transparent")
    }

    // MARK: - 7. No-Metal CPU fallback now handles YUV (the fixed contract gap)

    /// Regression for the fallback-contract gap: on a no-Metal machine `composite`
    /// routes to `cpuFallbackComposite`, which used to throw on non-BGRA input, so
    /// a YUV camera cutout failed despite the advertised YUV support. The fallback
    /// now converts biplanar YUV→BGRA on the CPU (vImage). This drives that path
    /// DIRECTLY (no GPU needed) with a 420f frame and asserts a correct
    /// premultiplied cutout — person opaque + ~mid-gray, background (0,0,0,0)
    /// transparent — matching the GPU/BGRA reference within tolerance.
    func testCPUFallbackYUVPath() throws {
        let W = 320, H = 240
        // 420f (full-range) frame: constant mid-gray (luma 153, neutral chroma) →
        // decodes to BGRA ≈ (153,153,153).
        let yuv = try Self.makeYUVFrame(width: W, height: H, id: "cpu.yuv", luma: 153, cb: 128, cr: 128)
        // BGRA reference of the SAME visual content for a cross-check.
        let bgraRef = try PresenterCutoutSelfTest.makeBGRAFrame(width: W, height: H, id: "cpu.bgra") { _, _ in
            (r: 153, g: 153, b: 153)
        }
        // Left = person (255), right = background (0), full-res.
        let matte = try PresenterCutoutSelfTest.makeMatte(width: W, height: H) { x, _ in x < W / 2 ? 255 : 0 }

        let cutout = PresenterCutout(options: .init(background: .transparent, feather: 0))
        // The FIXED no-Metal fallback: converts YUV→BGRA then composites on the CPU.
        let out = try cutout.cpuFallbackComposite(frame: yuv, matte: matte)

        XCTAssertEqual(out.pixelFormat, kCVPixelFormatType_32BGRA, "CPU fallback output must be BGRA")
        XCTAssertNotNil(CVPixelBufferGetIOSurface(out.pixelBuffer), "CPU fallback output must be IOSurface-backed")
        XCTAssertEqual(out.width, W); XCTAssertEqual(out.height, H)

        // Person region: opaque, ~mid-gray (YUV round-trip within a few codes).
        let fg = PresenterCutoutSelfTest.readBGRA(out, x: 60, y: 120)
        XCTAssertEqual(fg.a, 255, "YUV person region must be opaque on the CPU fallback")
        XCTAssertEqual(fg.r, 153, accuracy: 3); XCTAssertEqual(fg.g, 153, accuracy: 3)
        XCTAssertEqual(fg.b, 153, accuracy: 3)
        // Background region: premultiplied transparent black — NOT opaque black.
        let bg = PresenterCutoutSelfTest.readBGRA(out, x: 260, y: 120)
        XCTAssertEqual(bg.a, 0, "YUV background must be transparent on the CPU fallback")
        XCTAssertEqual(bg.r, 0); XCTAssertEqual(bg.g, 0); XCTAssertEqual(bg.b, 0)

        // Cross-check: CPU-YUV-fallback cutout matches the GPU/BGRA reference
        // (same matte, same content) within a tight tolerance — the two paths now
        // honour the same contract for YUV input.
        let gpuRef = try cutout.composite(frame: bgraRef, matte: matte)
        let d = Self.maxChannelDiff(out, gpuRef)
        print("  [cpu-yuv-fallback] max |Δ| vs GPU/BGRA ref: r=\(d.r) g=\(d.g) b=\(d.b) a=\(d.a)")
        XCTAssertLessThanOrEqual(max(d.r, max(d.g, d.b)), 4, "CPU-YUV fallback diverges from GPU/BGRA reference")
        XCTAssertEqual(d.a, 0, "alpha must match the reference exactly")

        try dumpBGRA(out.pixelBuffer, to: "\(Self.gpuDumpDir)/cpu_fallback_from_yuv.png")
        print("  [cpu-yuv-fallback] 420f → CPU cutout: fg \(fg) opaque, bg \(bg) transparent")
    }

    // MARK: - 8. F13 / Class H — an injected GPU failure recovers on the CPU path

    /// The Class-H gap: the GPU status-check throw exists, but no test drove an
    /// injected GPU failure THROUGH the real catch → CPU-fallback recovery. This
    /// forces `BackgroundEffect`'s status-check to throw on a live frame and
    /// asserts `composite()` (a) does NOT rethrow — it recovers — and (b) returns
    /// the frame the **independent CPU oracle** (`cpuReferenceComposite`, a
    /// different code path) produces, with the background alpha-preserved (Class C).
    ///
    /// Independent oracle, not a tautology: if the `catch { cpuFallbackComposite }`
    /// wiring in `composite` were removed, the injected `gpuExecutionFailed` would
    /// propagate and this test would fail (no frame). The expected pixels come
    /// from the CPU reference compositor and from hand-derived spot values (person
    /// = opaque passthrough, background = transparent), never from the GPU path
    /// under test. A genuine device fault can't be provoked in a unit test without
    /// risking a process-killing GPU hang, so the failure is injected at the real
    /// throw site (`BackgroundEffect._test_forceExecutionFailure`).
    func testInjectedGPUFailureRecoversOnCPUReferencePath() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("no Metal device — cannot exercise the GPU→CPU recovery path")
        }
        let W = 256, H = 256
        // Hostile fixture (Class A/I): spatially-varying BGRA, warm/cool halves + bands.
        let frame = try PresenterCutoutSelfTest.makeBGRAFrame(width: W, height: H, id: "f13") { x, y in
            let base: (r: UInt8, g: UInt8, b: UInt8) = x < W / 2 ? (230, 90, 40) : (40, 90, 230)
            return y % 32 < 4 ? (255, 255, 255) : base
        }
        // Matte: left half person (255), right half background (0), full-res hard edge.
        let matte = try PresenterCutoutSelfTest.makeMatte(width: W, height: H) { x, _ in x < W / 2 ? 255 : 0 }

        let cutout = PresenterCutout(options: .init(background: .transparent, feather: 0))

        // Independent oracle (a DIFFERENT code path from the GPU composite).
        let oracle = try cutout.cpuReferenceComposite(frame: frame, matte: matte)

        // Sanity: with the GPU healthy, composite() uses the GPU path and matches the oracle.
        let healthy = try cutout.composite(frame: frame, matte: matte)
        let dHealthy = Self.maxChannelDiff(healthy, oracle)
        XCTAssertLessThanOrEqual(max(dHealthy.r, max(dHealthy.g, dHealthy.b)), 2,
                                 "sanity: GPU cutout should match the CPU oracle")

        // Inject the GPU execution failure. The real BackgroundEffect status-check
        // now throws; composite() MUST route through catch → cpuFallbackComposite.
        cutout._test_forceGPUExecutionFailure = true
        let recovered = try cutout.composite(frame: frame, matte: matte)   // must NOT throw
        cutout._test_forceGPUExecutionFailure = false

        // (a) Recovery ran and produced the CPU oracle's frame exactly (BGRA input →
        //     convertedToBGRA is identity → cpuReferenceComposite).
        let dRec = Self.maxChannelDiff(recovered, oracle)
        XCTAssertEqual(max(dRec.r, max(dRec.g, dRec.b)), 0,
                       "recovered frame must equal the CPU oracle exactly (RGB)")
        XCTAssertEqual(dRec.a, 0, "recovered frame must equal the CPU oracle exactly (alpha)")

        // (b) Hand-derived spot checks, independent of BOTH composite paths.
        let fg = PresenterCutoutSelfTest.readBGRA(recovered, x: 40, y: 140)
        let src = PresenterCutoutSelfTest.readBGRA(frame, x: 40, y: 140)
        XCTAssertEqual(fg.a, 255, "person region must be opaque after CPU recovery")
        XCTAssertEqual(fg.r, src.r, accuracy: 1); XCTAssertEqual(fg.g, src.g, accuracy: 1)
        XCTAssertEqual(fg.b, src.b, accuracy: 1)
        let bg = PresenterCutoutSelfTest.readBGRA(recovered, x: 220, y: 140)
        XCTAssertEqual(bg.a, 0, "background must be transparent (Class C), not opaque black")
        XCTAssertEqual(bg.r, 0); XCTAssertEqual(bg.g, 0); XCTAssertEqual(bg.b, 0)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(recovered.pixelBuffer),
                        "recovered frame must be IOSurface-backed")
    }

    // MARK: - Helpers: measurement + YUV

    /// Max per-channel absolute difference between two same-size BGRA frames.
    private static func maxChannelDiff(_ a: VideoFrame, _ b: VideoFrame) -> (r: Int, g: Int, b: Int, a: Int) {
        var dr = 0, dg = 0, db = 0, da = 0
        for y in stride(from: 0, to: a.height, by: 1) {
            for x in stride(from: 0, to: a.width, by: 1) {
                let pa = readBGRA(a, x: x, y: y), pb = readBGRA(b, x: x, y: y)
                dr = max(dr, abs(pa.r - pb.r)); dg = max(dg, abs(pa.g - pb.g))
                db = max(db, abs(pa.b - pb.b)); da = max(da, abs(pa.a - pb.a))
            }
        }
        return (dr, dg, db, da)
    }

    private static func readBGRA(_ f: VideoFrame, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        PresenterCutoutSelfTest.readBGRA(f, x: x, y: y)
    }

    /// Median wall-clock milliseconds of `body` over `iters` runs.
    private static func medianMs(_ iters: Int, _ body: () -> Void) -> Double {
        var samples: [Double] = []
        for _ in 0..<iters {
            let t0 = DispatchTime.now().uptimeNanoseconds
            body()
            let t1 = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(t1 - t0) / 1_000_000.0)
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    /// Build a biplanar 420f (full-range) YUV `VideoFrame` filled with constant
    /// luma/chroma. IOSurface-backed via `PixelBufferPool`.
    static func makeYUVFrame(width: Int, height: Int, id: String,
                             luma: UInt8, cb: UInt8, cr: UInt8) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: width, height: height,
                                       pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                       minimumBufferCount: 1)
        let buffer = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        // Plane 0: luma (full-res).
        let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<height { memset(yBase + y * yRow, Int32(luma), width) }
        // Plane 1: interleaved CbCr (half-res each axis).
        let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let cRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let cW = (width + 1) / 2, cH = (height + 1) / 2
        for y in 0..<cH {
            let row = cBase + y * cRow
            for x in 0..<cW { row[x * 2] = cb; row[x * 2 + 1] = cr }
        }
        return VideoFrame(pixelBuffer: buffer, pts: HouseClock.now(), source: SourceID(id))
    }

    // MARK: - Helpers: load / stats

    private func loadPhotoFrame(path: String, id: String) throws -> VideoFrame {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw XCTSkip("could not decode \(path)")
        }
        let W = image.width, H = image.height
        let pool = try PixelBufferPool(width: W, height: H, pixelFormat: kCVPixelFormatType_32BGRA, minimumBufferCount: 1)
        let buffer = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let ctx = CGContext(data: base, width: W, height: H, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        return VideoFrame(pixelBuffer: buffer, pts: HouseClock.now(), source: SourceID(id))
    }

    private func matteCoverage(_ matte: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(matte, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(matte, .readOnly) }
        let w = CVPixelBufferGetWidth(matte), h = CVPixelBufferGetHeight(matte)
        let base = CVPixelBufferGetBaseAddress(matte)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(matte)
        var on = 0
        for y in 0..<h { for x in 0..<w where base[y * row + x] > 127 { on += 1 } }
        return Double(on) / Double(w * h)
    }

    // MARK: - Helpers: PNG dumps

    private func dumpBGRA(_ buffer: CVPixelBuffer, to path: String) throws {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let image = ctx.makeImage() else {
            throw NSError(domain: "cutout.test", code: 1, userInfo: [NSLocalizedDescriptionKey: "BGRA→CGImage failed"])
        }
        try writePNG(image, to: path)
    }

    private func dumpMatte(_ matte: CVPixelBuffer, to path: String) throws {
        CVPixelBufferLockBaseAddress(matte, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(matte, .readOnly) }
        let w = CVPixelBufferGetWidth(matte), h = CVPixelBufferGetHeight(matte)
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(matte), width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(matte),
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let image = ctx.makeImage() else {
            throw NSError(domain: "cutout.test", code: 2, userInfo: [NSLocalizedDescriptionKey: "matte→CGImage failed"])
        }
        try writePNG(image, to: path)
    }

    private func writePNG(_ image: CGImage, to path: String) throws {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "cutout.test", code: 3, userInfo: [NSLocalizedDescriptionKey: "PNG dest failed"])
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "cutout.test", code: 4, userInfo: [NSLocalizedDescriptionKey: "PNG finalize failed"])
        }
    }
}

// MARK: - Test doubles for the post-stop-frame test

/// A `VideoSource` whose `onFrame` is taken over by `PresenterCutoutSource`;
/// the test pushes frames by invoking `onFrame` directly (drives `submit`).
private final class ManualUpstream: VideoSource, @unchecked Sendable {
    let id = SourceID("test.manual.upstream")
    var onFrame: ((VideoFrame) -> Void)?
    private let lock = NSLock()
    private var _state: SourceState = .idle
    var state: SourceState { lock.lock(); defer { lock.unlock() }; return _state }
    func start() throws { lock.lock(); _state = .running; lock.unlock() }
    func stop() { lock.lock(); _state = .idle; lock.unlock() }
}

/// Thread-safe onFrame counter (callbacks fire on the worker queue).
private final class CutoutCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Thread-safe boolean flag for the feeder loop.
private final class FeedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = true
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return on }
    func set(_ v: Bool) { lock.lock(); on = v; lock.unlock() }
}
