import CoreMedia
import CoreVideo
import Foundation
import Metal
import XCTest

@testable import PrismColor
@testable import PrismCompositor
@testable import PrismVision
import PrismCore

/// F13 regression — **a non-completed Metal command buffer must THROW a typed
/// error, not publish a frame**.
///
/// The defect: `SourceEffectGPU.process` and `BackgroundEffect.apply` both
/// `commit()` + `waitUntilCompleted()` and then returned the output buffer
/// without inspecting `commandBuffer.status` / `.error`. On a GPU OOM / device
/// fault / timeout they published undefined or stale pooled pixels as if the pass
/// succeeded — and, because no error was thrown, `PresenterCutout`'s advertised
/// catch→CPU recovery never engaged.
///
/// A real device fault cannot be provoked deterministically in a unit test, so
/// the completion decision was extracted into `executionError(status:error:)` on
/// each module's error type. These exercise that exact decision: a non-completed
/// terminal state maps to the typed GPU-execution error (carrying
/// `commandBuffer.error`), while `.completed` maps to `nil` (publish the frame).
/// A real successful pass returning `.completed` is covered by the other
/// SourceEffectGPU / PresenterCutout tests.
final class GPUExecutionErrorTests: XCTestCase {

    private struct FakeGPUError: Error { let code: Int }

    func testCompositorNonCompletedStatusMapsToTypedError() {
        // .completed → publish (nil).
        XCTAssertNil(CompositorError.executionError(status: .completed, error: nil),
                     "a completed command buffer must NOT map to an error")

        // Every non-completed terminal state → the typed execution error, carrying
        // the underlying command-buffer error so the caller can log/inspect it.
        for status in [MTLCommandBufferStatus.error, .notEnqueued, .enqueued,
                       .committed, .scheduled] {
            let underlying = FakeGPUError(code: Int(status.rawValue))
            guard let mapped = CompositorError.executionError(status: status, error: underlying) else {
                return XCTFail("status \(status.rawValue) must map to a typed error")
            }
            guard case .gpuExecutionFailed(let carried) = mapped else {
                return XCTFail("expected .gpuExecutionFailed, got \(mapped)")
            }
            XCTAssertEqual((carried as? FakeGPUError)?.code, Int(status.rawValue),
                           "the command-buffer error must be carried through")
        }
    }

    func testVisionNonCompletedStatusMapsToTypedError() {
        XCTAssertNil(VisionError.executionError(status: .completed, error: nil),
                     "a completed command buffer must NOT map to an error")

        let underlying = FakeGPUError(code: 7)
        guard let mapped = VisionError.executionError(status: .error, error: underlying) else {
            return XCTFail("an errored command buffer must map to a typed error")
        }
        guard case .gpuExecutionFailed(let carried) = mapped else {
            return XCTFail("expected VisionError.gpuExecutionFailed, got \(mapped)")
        }
        XCTAssertEqual((carried as? FakeGPUError)?.code, 7, "the command-buffer error must be carried through")
    }

    func testColorNonCompletedStatusMapsToTypedError() {
        XCTAssertNil(ColorError.executionError(status: .completed, error: nil),
                     "a completed command buffer must NOT map to an error")
        let underlying = FakeGPUError(code: 9)
        guard let mapped = ColorError.executionError(status: .error, error: underlying),
              case .gpuExecutionFailed(let carried) = mapped else {
            return XCTFail("an errored PrismColor command buffer must map to .gpuExecutionFailed")
        }
        XCTAssertEqual((carried as? FakeGPUError)?.code, 9)
    }

    // MARK: - HIGH-4: the CORE composite paths throw on a GPU fault (F13 gap)

    /// F13 only covered `SourceEffectGPU` + `BackgroundEffect`. The three primary
    /// composite paths (`composite(scene:)` / `composite(stack:)`, the crossfade
    /// `mix`, and the `effect` transition) waited on the command buffer then
    /// returned the pooled output WITHOUT checking `.status`/`.error` — a device
    /// fault published undefined pixels as a successful frame.
    ///
    /// A real device fault can't be provoked deterministically, so the failure is
    /// injected at the REAL throw site via `_test_forceExecutionFailure` (the exact
    /// pattern F13 uses for BackgroundEffect). NON-TAUTOLOGY / NEGATIVE CONTROL:
    /// with the flag OFF the same composite SUCCEEDS (returns a frame). Were the
    /// status check absent, the flag-ON case would also return a frame and each
    /// `XCTAssertThrowsError` below would fail — so the assertions can only pass
    /// because the check is present and reached.
    func testCoreCompositePathsThrowOnInjectedGPUFault() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let compositor = try MetalCompositor(device: device, width: 128, height: 72)
        let pool = try PixelBufferPool(width: 64, height: 64, pixelFormat: kCVPixelFormatType_32BGRA)
        func frame(_ id: String) throws -> VideoFrame {
            VideoFrame(pixelBuffer: try pool.makeBuffer(), pts: HouseClock.now(), source: SourceID(id))
        }
        let a = SourceID("a"), b = SourceID("b")
        let sceneA = Scene(name: "A", layers: [Layer(sourceID: a)])
        let sceneB = Scene(name: "B", layers: [Layer(sourceID: b)])
        let frames = [a: try frame("a"), b: try frame("b")]
        let effect = CompositorEffect(kind: .iris)

        func assertThrowsGPUFault(_ what: String, _ body: () throws -> VideoFrame) {
            XCTAssertThrowsError(try body(), "\(what) did not throw on a forced GPU fault") { err in
                guard case CompositorError.gpuExecutionFailed = err else {
                    return XCTFail("\(what) threw \(err), expected .gpuExecutionFailed")
                }
            }
        }

        // Negative control: with the seam OFF every path SUCCEEDS.
        compositor._test_forceExecutionFailure = false
        XCTAssertNoThrow(try compositor.composite(frames: frames, scene: sceneA, pts: HouseClock.now()))
        XCTAssertNoThrow(try compositor.composite(frames: frames, sceneA: sceneA, sceneB: sceneB,
                                                  mix: 0.5, pts: HouseClock.now()))
        XCTAssertNoThrow(try compositor.composite(frames: frames, sceneA: sceneA, sceneB: sceneB,
                                                  effect: effect, progress: 0.5, rawProgress: 0.5,
                                                  pts: HouseClock.now()))

        // Fault injected at the real throw site → every path must THROW.
        compositor._test_forceExecutionFailure = true
        assertThrowsGPUFault("primary composite") {
            try compositor.composite(frames: frames, scene: sceneA, pts: HouseClock.now())
        }
        assertThrowsGPUFault("crossfade mix composite") {
            try compositor.composite(frames: frames, sceneA: sceneA, sceneB: sceneB,
                                     mix: 0.5, pts: HouseClock.now())
        }
        assertThrowsGPUFault("effect transition composite") {
            try compositor.composite(frames: frames, sceneA: sceneA, sceneB: sceneB,
                                     effect: effect, progress: 0.5, rawProgress: 0.5,
                                     pts: HouseClock.now())
        }
    }

    // MARK: - F13 gap: the INDIVIDUAL SourceEffectGPU + Color/Vision throw sites

    /// F13 originally reasoned about `SourceEffectGPU` + the per-effect Color/Vision
    /// passes through the shared `executionError(status:error:)` MAPPER only (the
    /// three tests at the top of this file), not through their REAL command-buffer
    /// throw path. sol flagged that as a gap: the mapper being right doesn't prove
    /// each `process`/`apply` actually reaches it and throws.
    ///
    /// This injects a forced command-buffer failure at each REAL throw site via a
    /// `#if DEBUG` seam (mirroring the core-compositor `_test_forceExecutionFailure`
    /// pattern above) and asserts the live method THROWS the typed error and
    /// publishes NO frame. NON-TAUTOLOGY / NEGATIVE CONTROL: with the seam OFF the
    /// exact same call SUCCEEDS and returns a real IOSurface-backed frame — so if a
    /// site's status-check were removed, the seam-ON call would also return a frame
    /// and its `XCTAssertThrowsError` would fail. None of these sites has a CPU
    /// recovery at this level (they only throw); the GPU→CPU recovery that DOES
    /// exist lives one layer up in `PresenterCutout` and is proven against a CPU
    /// oracle in `PresenterCutoutTests.testInjectedGPUFailureRecoversOnCPUReferencePath`.
    func testSourceEffectGPUAndColorVisionSitesThrowOnInjectedGPUFault() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let W = 64, H = 64
        let frame = try makeBGRAFrame(width: W, height: H, id: "f13.site")
        let depth = try makeDepth(width: W, height: H)

        // Each site: a name, its seam setter, and the call. `error` is the module's
        // typed error the call must throw (Compositor for FX, Color for the rest).
        func check<E: Error>(_ name: String,
                             setFailure: (Bool) -> Void,
                             expect _: E.Type,
                             isExpected: (Error) -> Bool,
                             _ call: () throws -> CVPixelBuffer) rethrows {
            // Negative control: seam OFF → succeeds, publishes a real frame.
            setFailure(false)
            do {
                let out = try call()
                XCTAssertNotNil(CVPixelBufferGetIOSurface(out),
                                "\(name): healthy pass must publish an IOSurface-backed frame")
            } catch {
                XCTFail("\(name): healthy pass must NOT throw (got \(error))")
            }
            // Seam ON → the real status-check throws; no frame is published.
            setFailure(true)
            XCTAssertThrowsError(try call(), "\(name) did not throw on a forced GPU fault") { err in
                XCTAssertTrue(isExpected(err), "\(name) threw \(err), expected \(E.self)")
            }
            setFailure(false)
        }

        func isCompositor(_ e: Error) -> Bool { if case CompositorError.gpuExecutionFailed = e { return true }; return false }
        func isColor(_ e: Error) -> Bool { if case ColorError.gpuExecutionFailed = e { return true }; return false }

        // 1. SourceEffectGPU.process (via beatPulse — one fullscreen fragment pass).
        let fx = try SourceEffectGPU(device: device, width: W, height: H)
        let pulse = BeatPulse.default.pulse(phase: 0.05, intensity: 1.0, style: .shake)
        try check("SourceEffectGPU.process", setFailure: { fx._test_forceExecutionFailure = $0 },
                  expect: CompositorError.self, isExpected: isCompositor) {
            try fx.beatPulse(source: frame.pixelBuffer, transform: pulse)
        }

        // 2. ColorProcessor.process (grade pass).
        let grader = try ColorProcessor(device: device)
        try check("ColorProcessor.process", setFailure: { grader._test_forceExecutionFailure = $0 },
                  expect: ColorError.self, isExpected: isColor) {
            try grader.process(frame, grade: .identity, lut: nil).pixelBuffer
        }

        // 3. ChromaKeyProcessor.apply.
        let chroma = try ChromaKeyProcessor(device: device)
        try check("ChromaKeyProcessor.apply", setFailure: { chroma._test_forceExecutionFailure = $0 },
                  expect: ColorError.self, isExpected: isColor) {
            try chroma.apply(frame: frame, key: .greenScreen).pixelBuffer
        }

        // 4. LumaKeyProcessor.apply.
        let luma = try LumaKeyProcessor(device: device)
        try check("LumaKeyProcessor.apply", setFailure: { luma._test_forceExecutionFailure = $0 },
                  expect: ColorError.self, isExpected: isColor) {
            try luma.apply(frame: frame, key: .brightBackground).pixelBuffer
        }

        // 5. RelightProcessor.process (needs a depth map + a light).
        let relight = try RelightProcessor(device: device)
        try check("RelightProcessor.process", setFailure: { relight._test_forceExecutionFailure = $0 },
                  expect: ColorError.self, isExpected: isColor) {
            try relight.process(frame: frame, depth: depth, lights: [.key()]).pixelBuffer
        }
    }

    /// A spatially-varying BGRA frame (a diagonal gradient) — real content, not a
    /// solid color, so the keyers/grader have something to operate on.
    private func makeBGRAFrame(width: Int, height: Int, id: String) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: width, height: height, pixelFormat: kCVPixelFormatType_32BGRA)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * bpr + x * 4
                p[0] = UInt8((x * 255) / max(1, width - 1))          // B
                p[1] = UInt8((y * 255) / max(1, height - 1))         // G
                p[2] = UInt8(((x + y) * 255) / max(1, width + height - 2)) // R
                p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return VideoFrame(pixelBuffer: buf, pts: HouseClock.now(), source: SourceID(id))
    }

    /// A OneComponent8 depth map (a horizontal ramp) for the relight pass.
    private func makeDepth(width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let st = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                     kCVPixelFormatType_OneComponent8,
                                     [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard st == kCVReturnSuccess, let buf = pb else { throw XCTSkip("no depth buffer (\(st))") }
        CVPixelBufferLockBaseAddress(buf, [])
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height { for x in 0..<width { base[y * bpr + x] = UInt8((x * 255) / max(1, width - 1)) } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }
}
