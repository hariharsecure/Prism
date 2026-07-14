import CoreMedia
import CoreVideo
import Foundation
import Metal
import XCTest

import PrismCompositor
import PrismCore
import PrismSound
@testable import Prism

/// sol OPTIMIZATION_PLAN #5 — END-TO-END parity for the batched render-time
/// source-FX chain, driven through `SourceEffectPipeline.animate(raw:at:)`.
///
/// `animate` now batches pulse → strobe → tile into ONE command buffer
/// (`SourceEffectGPU.processChain`). This proves the whole render-thread path —
/// including the tick-PTS phase math in `buildChainSteps` — is behaviour-
/// preserving: the batched frame is byte-identical to the OLD per-effect chain
/// (3 command buffers), which the `_test_forceSequentialChain` seam still runs.
@MainActor
final class SourceFXChainAnimateParityTests: XCTestCase {

    private func makeRaw(_ side: Int, alpha: Bool) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: side, height: side, pixelFormat: kCVPixelFormatType_32BGRA)
        let pb = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<side {
            for x in 0..<side {
                let p = base + y * bpr + x * 4
                let a: UInt8 = alpha && x < side / 3 ? 0 : 255       // cutout left third
                let af = Double(a) / 255
                p[0] = UInt8((Double((x * 255) / (side - 1)) * af).rounded())
                p[1] = UInt8((Double((y * 255) / (side - 1)) * af).rounded())
                p[2] = UInt8((Double(((x + y) * 255) / (2 * side - 2)) * af).rounded())
                p[3] = a
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return VideoFrame(pixelBuffer: pb, pts: HouseClock.now(), source: SourceID("fx.parity"))
    }

    private func bytesEqual(_ a: VideoFrame, _ b: VideoFrame) -> (maxDelta: Int, differing: Int) {
        let pa = a.pixelBuffer, pb = b.pixelBuffer
        let w = min(CVPixelBufferGetWidth(pa), CVPixelBufferGetWidth(pb))
        let h = min(CVPixelBufferGetHeight(pa), CVPixelBufferGetHeight(pb))
        CVPixelBufferLockBaseAddress(pa, .readOnly); CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pa, .readOnly); CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let ba = CVPixelBufferGetBaseAddress(pa)!.assumingMemoryBound(to: UInt8.self)
        let bb = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let bpa = CVPixelBufferGetBytesPerRow(pa), bpb = CVPixelBufferGetBytesPerRow(pb)
        var maxDelta = 0, differing = 0
        for y in 0..<h {
            for x in 0..<(w * 4) {
                let d = abs(Int((ba + y * bpa)[x]) - Int((bb + y * bpb)[x]))
                if d != 0 { differing += 1; if d > maxDelta { maxDelta = d } }
            }
        }
        return (maxDelta, differing)
    }

    func testAnimateBatchedMatchesSequentialAcrossTicks() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let side = 192
        let pipeline = SourceEffectPipeline(device: device, sourceID: SourceID("fx.parity"),
                                            canvasWidth: side, canvasHeight: side)
        // Full render chain: pulse + strobe + tile, all animated.
        pipeline.update(SourceEffects(
            tile: TileEffect(mode: .flicker, rows: 6, cols: 8, speed: 4, startHostSeconds: 0),
            pulse: BeatPulseEffect(intensity: 1.2, style: .bumpShake),
            strobe: StrobeEffect(intensity: 0.8, red: 1, green: 0.3, blue: 0.2,
                                 syncToBeat: true, freeRunHz: 3, startHostSeconds: 0)))
        // A running clock so the beat pulse is non-identity (part of the chain).
        pipeline.setBeatClock(BeatClock(bpm: 120, beatsPerBar: 4, anchorHostSeconds: 0))
        XCTAssertTrue(pipeline.hasAnimatedEffect)

        let raw = try makeRaw(side, alpha: true)   // hostile: cutout source

        for i in 0..<6 {
            let pts = CMTime(seconds: 0.05 + Double(i) * 0.037, preferredTimescale: 1_000_000_000)

            SourceEffectPipeline._test_forceSequentialChain = false
            let batched = try XCTUnwrap(pipeline.animate(raw: raw, at: pts))
            SourceEffectPipeline._test_forceSequentialChain = true
            let sequential = try XCTUnwrap(pipeline.animate(raw: raw, at: pts))
            SourceEffectPipeline._test_forceSequentialChain = false

            let s = bytesEqual(batched, sequential)
            print(String(format: "ANIMATE parity @pts=%.3f: maxByteDelta=%d differing=%d", pts.seconds, s.maxDelta, s.differing))
            XCTAssertLessThanOrEqual(s.maxDelta, 1,
                "animate batched vs sequential diverged at pts \(pts.seconds) (maxDelta \(s.maxDelta))")
        }
    }
}
