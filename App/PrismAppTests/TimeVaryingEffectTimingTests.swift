import CoreMedia
import CoreVideo
import Foundation
import Metal
import XCTest

import PrismCompositor
import PrismCore
import PrismSound
@testable import Prism

/// F5 (PRODUCTION_BIBLE Class D — Timing & Cadence): time-varying per-source
/// effects (tile flicker / strobe / beat pulse) must advance on the RENDER-TICK
/// house clock, using ONE tick PTS for every source — NOT at source-callback
/// arrival, and never against wall-clock `Date`.
///
/// Pre-fix, the whole effect chain ran inside `SourceEffectPipeline.process`,
/// which fires only when a source's `onFrame` fires (a still ImageSource emits
/// ~2 fps) and read `HouseClock.nowSeconds()` at callback ARRIVAL. So a 2 fps
/// source flickered ~2×/s, a strobe aliased, and a beat pulse looked frozen; and
/// equal-PTS local vs delayed-network frames baked different phases. These tests
/// pin the corrected architecture: phase derives from the tick PTS handed to
/// `animate(raw:at:)`, evaluated against the held raw frame every render tick.
@MainActor
final class TimeVaryingEffectTimingTests: XCTestCase {

    // MARK: Pure phase math (deterministic; no GPU)

    /// Phase is a pure function of the tick PTS, NOT wall-clock callback arrival:
    /// two evaluations at the SAME tick time are identical even with real wall
    /// time passing between them; a later tick time advances the phase. Pre-fix
    /// the phase was `f(HouseClock.nowSeconds())` at call time, so two calls 50 ms
    /// apart would differ — exactly the aliasing/"different phase for equal PTS"
    /// defect this refutes.
    func testStrobePhaseIsDeterministicPerTickPTSNotWallClock() {
        let effect = StrobeEffect(syncToBeat: false, freeRunHz: 3, startHostSeconds: 0)

        let atTick = SourceEffectPipeline.strobePhase(effect, clock: .stopped, atSeconds: 1.0)
        Thread.sleep(forTimeInterval: 0.05)                 // real wall time elapses
        let sameTick = SourceEffectPipeline.strobePhase(effect, clock: .stopped, atSeconds: 1.0)
        XCTAssertEqual(atTick, sameTick, accuracy: 1e-12,
                       "strobe phase changed with wall-clock arrival at a fixed tick PTS")

        let laterTick = SourceEffectPipeline.strobePhase(effect, clock: .stopped, atSeconds: 1.5)
        XCTAssertNotEqual(atTick, laterTick,
                          "strobe phase did not advance with the tick PTS")
    }

    /// Tile-flicker phase is shared across sources at the same tick (a pure
    /// function of the tick time + identical config) and advances between ticks —
    /// so a still source, sampled only at render ticks, still animates.
    func testTilePhaseSharedAcrossSourcesAtSameTickAndAdvances() {
        let tile = TileEffect(mode: .flicker, speed: 4, startHostSeconds: 0)

        // Two independent sources, same tick PTS → same phase (shared clock).
        let sourceA = SourceEffectPipeline.tilePhase(tile, clock: .stopped, atSeconds: 2.0)
        let sourceB = SourceEffectPipeline.tilePhase(tile, clock: .stopped, atSeconds: 2.0)
        XCTAssertEqual(sourceA, sourceB, accuracy: 1e-12,
                       "two sources at the same tick got different tile phase")

        // Successive render ticks advance the phase even with no new source frame.
        let nextTick = SourceEffectPipeline.tilePhase(tile, clock: .stopped, atSeconds: 2.25)
        XCTAssertNotEqual(sourceA, nextTick,
                          "tile phase did not advance across render ticks")
    }

    /// Beat-synced phase from a shared running `BeatClock`: two sources at one
    /// tick read the same beat phase (shared clock), and a still source advances
    /// between ticks because the phase is sampled at the tick PTS.
    func testBeatSyncedPhaseSharedAndAdvancesOnStillSource() {
        // 120 BPM → 0.5 s/beat, anchored at t=0.
        let clock = BeatClock(bpm: 120, beatsPerBar: 4, anchorHostSeconds: 0)
        let strobe = StrobeEffect(syncToBeat: true, freeRunHz: 3, startHostSeconds: 0)

        let a = SourceEffectPipeline.strobePhase(strobe, clock: clock, atSeconds: 1.0)
        let b = SourceEffectPipeline.strobePhase(strobe, clock: clock, atSeconds: 1.0)
        XCTAssertEqual(a, b, accuracy: 1e-12, "shared beat clock gave two phases at one tick")

        // A quarter-beat later (0.125 s) the phase must have advanced by ~0.25.
        let quarterBeatLater = SourceEffectPipeline.strobePhase(strobe, clock: clock, atSeconds: 1.125)
        XCTAssertEqual(quarterBeatLater - a, 0.25, accuracy: 1e-9,
                       "beat phase did not advance by a quarter beat across ticks")
    }

    // MARK: End-to-end frame evaluation (GPU)

    /// A still source (ONE raw frame, no new callbacks) with tile-FLICKER enabled
    /// produces DISTINCT frames across successive render ticks: `animate` is
    /// driven purely by the tick PTS against the held raw frame, so the flicker
    /// advances at render cadence rather than the source's callback rate. Pre-fix
    /// the flicker only changed when `onFrame` fired.
    func testTileFlickerProducesDistinctFramesAcrossRenderTicks() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let side = 128
        let pipeline = SourceEffectPipeline(device: device, sourceID: SourceID("fx.flicker"),
                                            canvasWidth: side, canvasHeight: side)
        pipeline.update(SourceEffects(tile: TileEffect(mode: .flicker, rows: 6, cols: 8,
                                                       speed: 4, startHostSeconds: 0)))
        XCTAssertTrue(pipeline.hasAnimatedEffect)

        // ONE held raw frame — the source never emits again.
        let raw = try makeFrame(side: side, source: SourceID("fx.flicker"))

        // Sample the SAME raw frame at a sweep of render-tick PTS values.
        var hashes = Set<Int>()
        for i in 0..<12 {
            let pts = CMTime(seconds: Double(i) * 0.05, preferredTimescale: 1_000_000_000)
            let out = try XCTUnwrap(pipeline.animate(raw: raw, at: pts),
                                    "animate returned nil for a live tile effect")
            hashes.insert(pixelHash(out))
        }
        XCTAssertGreaterThan(hashes.count, 1,
                             "tile flicker was frozen across render ticks — a still source did not animate")
    }

    /// Shared clock at the frame level: two sources with identical animated config
    /// sampled at the SAME tick PTS produce byte-identical frames (same phase);
    /// the SAME source at a later tick differs (phase advanced by the tick PTS).
    func testAnimatedFramesShareOnePhaseClockAcrossSources() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let side = 128
        func makePipeline(_ id: String) -> SourceEffectPipeline {
            let p = SourceEffectPipeline(device: device, sourceID: SourceID(id),
                                         canvasWidth: side, canvasHeight: side)
            p.update(SourceEffects(tile: TileEffect(mode: .flicker, rows: 6, cols: 8,
                                                    speed: 4, startHostSeconds: 0)))
            return p
        }
        let a = makePipeline("fx.shared.a")
        let b = makePipeline("fx.shared.b")
        let raw = try makeFrame(side: side, source: SourceID("fx.shared"))

        let tick = CMTime(seconds: 0.30, preferredTimescale: 1_000_000_000)
        let outA = try XCTUnwrap(a.animate(raw: raw, at: tick))
        let outB = try XCTUnwrap(b.animate(raw: raw, at: tick))
        XCTAssertEqual(pixelHash(outA), pixelHash(outB),
                       "two sources at the same tick baked different phases (no shared clock)")

        // Half a flicker period later (Δphase = 0.5 × speed-scaled) so the blink
        // is maximally different, not aliased back to the same pattern.
        let laterTick = CMTime(seconds: 0.425, preferredTimescale: 1_000_000_000)
        let outALater = try XCTUnwrap(a.animate(raw: raw, at: laterTick))
        XCTAssertNotEqual(pixelHash(outA), pixelHash(outALater),
                          "phase did not advance with the tick PTS")
    }

    /// Capture-time `process` no longer bakes the time-varying effect: with only a
    /// tile effect set (no color/key/wall), the frame posted to the mailbox is the
    /// UNANIMATED raw frame — animation is applied later by `animate` at the tick.
    func testCaptureProcessLeavesTimeVaryingEffectUnbaked() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let side = 128
        let pipeline = SourceEffectPipeline(device: device, sourceID: SourceID("fx.raw"),
                                            canvasWidth: side, canvasHeight: side)
        pipeline.update(SourceEffects(tile: TileEffect(mode: .flicker, speed: 4)))
        let raw = try makeFrame(side: side, source: SourceID("fx.raw"))

        let posted = pipeline.process(raw)
        XCTAssertEqual(pixelHash(posted), pixelHash(raw),
                       "capture-time process still bakes the animated tile effect (F5 regression)")
    }

    // MARK: Helpers

    private func makeFrame(side: Int, source: SourceID) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: side, height: side,
                                       pixelFormat: kCVPixelFormatType_32BGRA)
        let pb = try pool.makeBuffer()
        // Paint a nonuniform pattern so a hole-punch/flicker actually changes bytes.
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            let h = CVPixelBufferGetHeight(pb)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h {
                for x in 0..<bpr {
                    ptr[y * bpr + x] = UInt8((x &+ y) & 0xFF)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return VideoFrame(pixelBuffer: pb, pts: HouseClock.now(), source: source)
    }

    private func pixelHash(_ frame: VideoFrame) -> Int {
        let pb = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return 0 }
        let count = CVPixelBufferGetBytesPerRow(pb) * CVPixelBufferGetHeight(pb)
        var hasher = Hasher()
        hasher.combine(bytes: UnsafeRawBufferPointer(start: base, count: count))
        return hasher.finalize()
    }
}
