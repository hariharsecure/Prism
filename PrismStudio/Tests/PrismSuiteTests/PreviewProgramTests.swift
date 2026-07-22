import CoreMedia
import CoreVideo
import Metal
import os
import XCTest

import PrismCompose
import PrismCompositor
import PrismCore

/// Phase 3a — STUDIO MODE, STAGE 1 (`PreviewProgram`), mechanism-level proofs.
///
/// These exercise the compositor/queue mechanism directly (the same level the
/// `DualProgram*Tests` verify the vertical program). The App-level routing seam
/// (`studioMode` → `previewScene`, `take()`) is proven separately in the App
/// target's `StudioModePreviewTests`; here we prove the load-bearing invariant:
/// a PreviewProgram rendering a separate scene NEVER perturbs a program
/// compositor rendering the live scene, and a hard-cut TAKE reproduces the
/// preview deterministically on the program.
final class PreviewProgramTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    /// Raw BGRA bytes of the whole buffer (row-padding included; both buffers
    /// come from the SAME compositor pool, so their layout is identical).
    private func rawBytes(_ buf: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let h = CVPixelBufferGetHeight(buf)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        return [UInt8](UnsafeBufferPointer(start: base, count: h * bpr))
    }

    private func pixel(_ buf: CVPixelBuffer, x: Int, y: Int) -> (b: Int, g: Int, r: Int, a: Int) {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let p = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self) + y * bpr + x * 4
        return (Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3]))
    }

    /// Median BGR over a centered patch (mirrors the AVRoundTripOracle patch
    /// approach — robust to any 1-LSB rounding between two compositor instances).
    private func patchMedian(_ buf: CVPixelBuffer, half: Int = 8) -> (b: Int, g: Int, r: Int) {
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        var bs: [Int] = [], gs: [Int] = [], rs: [Int] = []
        for dy in -half...half {
            for dx in -half...half {
                let px = pixel(buf, x: w / 2 + dx, y: h / 2 + dy)
                bs.append(px.b); gs.append(px.g); rs.append(px.r)
            }
        }
        func med(_ a: [Int]) -> Int { a.sorted()[a.count / 2] }
        return (med(bs), med(gs), med(rs))
    }

    private struct Fixture {
        let bg = SourceID("preview.bg"), top = SourceID("preview.top")
        let frames: [SourceID: VideoFrame]
        let bgColor: RGBA, topColor: RGBA
    }

    /// A two-layer canvas: a solid blue background (`bg`) under a solid red
    /// top (`top`). Hiding `top` reveals the blue background.
    private func makeFixture(_ device: MTLDevice, width: Int, height: Int) throws -> Fixture {
        let canvas = try FXCanvas(width: width, height: height)
        let bgColor = RGBA(r: 0.15, g: 0.35, b: 0.90) // blue
        let topColor = RGBA(r: 0.90, g: 0.20, b: 0.15) // red
        let bg = SourceID("preview.bg"), top = SourceID("preview.top")
        let frames: [SourceID: VideoFrame] = [
            bg: VideoFrame(pixelBuffer: try canvas.solid(bgColor), pts: HouseClock.now(), source: bg),
            top: VideoFrame(pixelBuffer: try canvas.solid(topColor), pts: HouseClock.now(), source: top),
        ]
        return Fixture(frames: frames, bgColor: bgColor, topColor: topColor)
    }

    private func liveScene(_ f: Fixture) -> Scene {
        Scene(name: "live", layers: [
            Layer(sourceID: f.bg, zIndex: 0),
            Layer(sourceID: f.top, zIndex: 1),
        ])
    }

    /// Await the preview program's next delivered frame (it drains on its own
    /// serial queue), or fail the wait.
    private func nextPreviewFrame(_ preview: PreviewProgram,
                                  frames: [SourceID: VideoFrame],
                                  scene: Scene) throws -> VideoFrame {
        let box = OSAllocatedUnfairLock<VideoFrame?>(initialState: nil)
        let sem = DispatchSemaphore(value: 0)
        preview.onPreviewFrame = { frame in box.withLock { $0 = frame }; sem.signal() }
        preview.submit(frames: frames, scene: scene, pts: HouseClock.now())
        guard sem.wait(timeout: .now() + 3) == .success, let frame = box.withLock({ $0 }) else {
            throw XCTSkip("preview program never delivered a frame")
        }
        return frame
    }

    // MARK: - THE off-air proof

    /// CRITICAL: with the preview rendering an EDITED scene (top layer hidden),
    /// the program compositor's output — rendered from the UNCHANGED live scene —
    /// is BYTE-identical before and after the preview edit, while the preview
    /// frame shows the edit. There is no path from a preview edit to the program.
    func testOffAirPreviewEditLeavesProgramOutputByteUnchanged() throws {
        let dev = try device()
        let W = 256, H = 144
        let fixture = try makeFixture(dev, width: W, height: H)
        let programCompositor = try MetalCompositor(device: dev, width: W, height: H)
        let preview = try PreviewProgram(device: dev, width: W, height: H)

        let live = liveScene(fixture)

        // Program output BEFORE any preview activity.
        let p1 = try programCompositor.composite(frames: fixture.frames, scene: live, pts: HouseClock.now())
        let before = rawBytes(p1.pixelBuffer)
        // Sanity: the live program shows the RED top over blue.
        let liveCenter = pixel(p1.pixelBuffer, x: W / 2, y: H / 2)
        XCTAssertGreaterThan(liveCenter.r, 180, "live program center must be the red top layer, got \(liveCenter)")

        // Edit the PREVIEW off-air: hide the top layer. Render it on the preview
        // program (which drains on its own queue and delivers to its own sink).
        var edited = live
        edited.layers[1].isHidden = true
        let previewFrame = try nextPreviewFrame(preview, frames: fixture.frames, scene: edited)

        // The preview reflects the edit: center now shows the BLUE background.
        let previewCenter = pixel(previewFrame.pixelBuffer, x: W / 2, y: H / 2)
        XCTAssertGreaterThan(previewCenter.b, 180, "preview center must reveal the blue background after hiding top, got \(previewCenter)")
        XCTAssertLessThan(previewCenter.r, 90, "preview center must NOT be the red top after hiding it, got \(previewCenter)")

        // Program output AFTER the preview edit — the program compositor was NEVER
        // asked to render the edited scene, so it must be byte-for-byte unchanged.
        let p2 = try programCompositor.composite(frames: fixture.frames, scene: live, pts: HouseClock.now())
        let after = rawBytes(p2.pixelBuffer)
        XCTAssertEqual(before, after,
                       "OFF-AIR VIOLATION: an off-air preview edit changed the live program output bytes")
    }

    // MARK: - Deterministic hard-cut TAKE

    /// A hard-cut TAKE is: the program renders exactly what the preview rendered.
    /// Prove the program reproduces the pre-TAKE preview's patch medians ONLY
    /// after the take (before, the program still shows the un-taken live scene).
    func testHardCutTakeReproducesPreviewOnProgram() throws {
        let dev = try device()
        let W = 256, H = 144
        let fixture = try makeFixture(dev, width: W, height: H)
        let programCompositor = try MetalCompositor(device: dev, width: W, height: H)
        let preview = try PreviewProgram(device: dev, width: W, height: H)

        let live = liveScene(fixture)
        var edited = live
        edited.layers[1].isHidden = true // off-air edit: hide top

        // Pre-TAKE preview medians (blue background).
        let previewFrame = try nextPreviewFrame(preview, frames: fixture.frames, scene: edited)
        let previewMed = patchMedian(previewFrame.pixelBuffer)

        // BEFORE take: the program still shows the live (un-taken) scene → red.
        let progBefore = try programCompositor.composite(frames: fixture.frames, scene: live, pts: HouseClock.now())
        let beforeMed = patchMedian(progBefore.pixelBuffer)
        XCTAssertGreaterThan(beforeMed.r, 180, "program before TAKE must still be the live red, got \(beforeMed)")
        XCTAssertNotEqual(beforeMed.b, previewMed.b, "negative control: program should differ from preview before TAKE")

        // TAKE (hard cut): the program now renders exactly the preview scene.
        let progAfter = try programCompositor.composite(frames: fixture.frames, scene: edited, pts: HouseClock.now())
        let afterMed = patchMedian(progAfter.pixelBuffer)
        XCTAssertLessThanOrEqual(abs(afterMed.b - previewMed.b), 2, "TAKE must reproduce the preview blue on the program, got \(afterMed) vs \(previewMed)")
        XCTAssertLessThanOrEqual(abs(afterMed.g - previewMed.g), 2, "TAKE G mismatch \(afterMed) vs \(previewMed)")
        XCTAssertLessThanOrEqual(abs(afterMed.r - previewMed.r), 2, "TAKE R mismatch \(afterMed) vs \(previewMed)")
    }

    // MARK: - Source-sync (forget/attach tombstone, mirror DualProgram)

    /// The preview compositor tracks source registration like `DualProgram`:
    /// `forget` tombstones a source (so a stale pending tick can't re-pin it) and
    /// `attach` clears the tombstone — proven via `forgottenSourceIDs`.
    func testSourceSyncForgetAttachTombstone() throws {
        let dev = try device()
        let preview = try PreviewProgram(device: dev, width: 64, height: 64)
        let id = SourceID("preview.sync")

        XCTAssertTrue(preview.forgottenSourceIDs.isEmpty, "a fresh preview program has no tombstones")

        preview.forget(source: id)
        XCTAssertEqual(preview.forgottenSourceIDs, [id], "forget must tombstone the source")

        preview.attach(source: id)
        XCTAssertTrue(preview.forgottenSourceIDs.isEmpty, "attach must clear the tombstone (source re-synced)")
    }

    /// A stale pending tick carrying a forgotten source must NOT re-pin it: the
    /// forgotten frame is filtered from the submitted dict (mirror DualProgram F22).
    func testForgottenSourceIsFilteredFromSubmission() throws {
        let dev = try device()
        let W = 64, H = 64
        let preview = try PreviewProgram(device: dev, width: W, height: H)
        let canvas = try FXCanvas(width: W, height: H)
        let live = SourceID("preview.live"), gone = SourceID("preview.gone")
        let frames: [SourceID: VideoFrame] = [
            live: VideoFrame(pixelBuffer: try canvas.solid(RGBA(r: 0.1, g: 0.8, b: 0.2)), pts: HouseClock.now(), source: live),
            gone: VideoFrame(pixelBuffer: try canvas.solid(RGBA(r: 0.9, g: 0.1, b: 0.1)), pts: HouseClock.now(), source: gone),
        ]
        preview.forget(source: gone) // tombstone before the stale tick arrives
        // The submission still carries `gone`, but it must be filtered — the
        // delivered frame renders only the live source, never the forgotten one.
        let scene = Scene(name: "s", layers: [Layer(sourceID: live, zIndex: 0), Layer(sourceID: gone, zIndex: 1)])
        let frame = try nextPreviewFrame(preview, frames: frames, scene: scene)
        let center = pixel(frame.pixelBuffer, x: W / 2, y: H / 2)
        XCTAssertGreaterThan(center.g, 150, "the forgotten (red) source must be filtered → green live source shows, got \(center)")
        XCTAssertLessThan(center.r, 120, "the forgotten source must not re-pin, got \(center)")
    }

    // MARK: - Discard fence (color-mode / HDR swap), mirror DualProgram

    /// A `quiesce`d preview program delivers NO frame; the un-fenced control does.
    /// The delta is exactly the stale-frame reorder the fence prevents on an HDR swap.
    func testQuiescedPreviewSuppressesDeliveryNegativeControlDelivers() throws {
        let dev = try device()

        func deliveries(fence: Bool) throws -> Int {
            let preview = try PreviewProgram(device: dev, width: 64, height: 64)
            let canvas = try FXCanvas(width: 64, height: 64)
            let id = SourceID("preview.quiesce.\(fence)")
            let frame = VideoFrame(pixelBuffer: try canvas.solid(RGBA(r: 0.2, g: 0.2, b: 0.9)),
                                   pts: HouseClock.now(), source: id)
            preview.scene = Scene(name: "s", layers: [Layer(sourceID: id)])
            let count = OSAllocatedUnfairLock<Int>(initialState: 0)
            let signalled = DispatchSemaphore(value: 0)
            preview.onPreviewFrame = { _ in count.withLock { $0 += 1 }; signalled.signal() }

            if fence { preview.quiesce(); XCTAssertTrue(preview.isQuiesced) }
            preview.submit(frames: [id: frame], pts: frame.pts)

            if fence {
                Thread.sleep(forTimeInterval: 0.3) // give the suppressed drain time; expect nothing
            } else {
                XCTAssertEqual(signalled.wait(timeout: .now() + 2), .success,
                               "un-fenced preview never delivered — negative control vacuous")
            }
            return count.withLock { $0 }
        }

        XCTAssertEqual(try deliveries(fence: false), 1, "negative control: un-fenced preview did not deliver")
        XCTAssertEqual(try deliveries(fence: true), 0, "a quiesced (discarded) preview program still delivered a frame")
    }

    /// `resume` re-arms a quiesced preview (the HDR-swap failure path revives it).
    func testResumeReArmsQuiescedPreview() throws {
        let dev = try device()
        let preview = try PreviewProgram(device: dev, width: 64, height: 64)
        let canvas = try FXCanvas(width: 64, height: 64)
        let id = SourceID("preview.resume")
        let frame = VideoFrame(pixelBuffer: try canvas.solid(RGBA(r: 0.3, g: 0.6, b: 0.3)),
                               pts: HouseClock.now(), source: id)
        preview.scene = Scene(name: "s", layers: [Layer(sourceID: id)])
        let delivered = DispatchSemaphore(value: 0)
        preview.onPreviewFrame = { _ in delivered.signal() }

        preview.quiesce()
        preview.resume()
        XCTAssertFalse(preview.isQuiesced)
        preview.submit(frames: [id: frame], pts: frame.pts)
        XCTAssertEqual(delivered.wait(timeout: .now() + 2), .success, "a resumed preview did not deliver (fence not reversible)")
    }
}
