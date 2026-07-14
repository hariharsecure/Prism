import CoreMedia
import CoreVideo
import os
import XCTest

import PrismCore
import PrismScreen
@testable import Prism

/// sol #11 #1 (gpt-5.6-sol, HIGH) — the wave-11 SERIALIZE screen hot-swap fix (the deferred
/// replacement gate) introduced a VIDEO frame-DROP: the successor `ScreenSource`'s frames that
/// arrive during its async-start window (after it is `.running` + `onStarted` has QUEUED the
/// main-actor commit, but BEFORE the gate is armed at commit) were discarded. If the successor's
/// SOLE complete frame lands in that window, commit armed the gate WITHOUT replaying it, so the
/// screen held the OLD frame (or was BLACK with no prior frame) until the source next emitted —
/// which an IDLE SCK source may never do. That exceeds the accepted one-frame reconfigure hitch.
///
/// FIX: during the deferred-gate window BUFFER the successor's LATEST frame (latest-wins, DATA
/// only — no touch of the shared `SourceEffectGPU`/`MixerChannel`, so the SERIALIZE guarantee is
/// intact). At commit/arm — strictly AFTER the old generation is retired+drained and stopped — the
/// buffered frame is flushed into the mailbox UNDER the gate lock, so the swapped-in content
/// presents immediately and the flush is serialized against any live capture-queue frame.
///
/// Each test reproduces the pre-fix DROP via the `_test_skipDeferredScreenBuffer` negative control
/// (screen stays stale/black), then proves the buffered frame is presented after commit. The
/// serialize-not-regressed invariant is asserted directly on the concurrency probe (max 1).
@MainActor
final class SolWave11ScreenBufferTests: XCTestCase {

    private static func makeBGRAFrame(source: SourceID, pts: CMTime) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: 16, height: 16, pixelFormat: kCVPixelFormatType_32BGRA)
        return VideoFrame(pixelBuffer: try pool.makeBuffer(), pts: pts, source: source)
    }

    private func registerScreen(_ engine: AppEngine, id: String) throws -> (SourceID, ScreenSource, SourceDescriptor) {
        let desc = SourceDescriptor(kind: .display, id: id, name: "Display")
        let src = try ScreenSource(descriptor: desc,
                                   configuration: AppEngine.screenCaptureConfiguration(captureAudio: false, hdr: false))
        engine.integrationDebugRegisterScreenSource(src, descriptor: desc)
        return (SourceID(id), src, desc)
    }

    /// Drive the reconfigure to the point where the HDR replacement is PENDING (its async start
    /// has NOT confirmed → no commit yet), deliver a successor frame into the deferred window,
    /// then commit. Returns the newest frame in the render mailbox after commit and how many
    /// deliveries reached the shared pipeline. `skipBuffer` selects the pre-fix drop.
    private func reconfigureAndCommit(skipBuffer: Bool,
                                      priorFramePTS: CMTime?,
                                      successorPTS: CMTime,
                                      id: String) throws -> (newest: VideoFrame?, probe: ScreenSwapConcurrencyProbe) {
        let engine = AppEngine()
        guard engine.renderLoop != nil else { throw XCTSkip("no Metal device") }
        AppEngine._test_skipScreenSourceStart = true
        AppEngine._test_simulatedScreenStartOutcome = .none       // replacement stays PENDING (no commit)
        AppEngine._test_skipDeferredScreenBuffer = skipBuffer
        defer {
            AppEngine._test_skipScreenSourceStart = false
            AppEngine._test_simulatedScreenStartOutcome = .none
            AppEngine._test_skipDeferredScreenBuffer = false
            AppEngine._test_clearScreenSwapProbes()
        }
        let (sid, original, desc) = try registerScreen(engine, id: id)
        let probe = AppEngine._test_installScreenSwapProbe(for: sid)
        let mailbox = try XCTUnwrap(engine._test_screenMailbox(for: sid))

        // Optional prior frame A from the LIVE original (so the "stale" case has an old frame to hold).
        if let priorFramePTS {
            original.onFrame?(try Self.makeBGRAFrame(source: sid, pts: priorFramePTS))
        }

        // Trigger the HDR reconfigure → a deferred-gate replacement is now PENDING.
        engine.setHDREnabled(true)
        guard engine.hdrEnabled else { throw XCTSkip("HDR toggle did not take") }
        let pending = try XCTUnwrap(engine._test_pendingScreenReplacementHandles(for: sid)).source

        // The successor's SOLE complete frame B arrives in the async-start window (pre-commit).
        pending.onFrame?(try Self.makeBGRAFrame(source: sid, pts: successorPTS))

        // Commit the replacement (models the queued main-actor commit running).
        engine._test_commitScreenReplacementDirect(id: sid, source: pending, mailbox: mailbox, descriptor: desc)

        // What a render tick would present now (latest-wins mailbox).
        return (mailbox.takeNewest(), probe)
    }

    /// With a prior frame A/PTS10, the successor B/PTS20 arriving pre-commit must be PRESENTED
    /// after commit (not the stale A). Negative control (drop) holds the stale A.
    func testDeferredSuccessorFrameReplacesStalePriorFrameAtCommit() throws {
        let a = CMTime(value: 10, timescale: 600)
        let b = CMTime(value: 20, timescale: 600)

        // FIX: the buffered successor frame B is flushed at commit → render presents B.
        let fixed = try reconfigureAndCommit(skipBuffer: false, priorFramePTS: a, successorPTS: b, id: "display:111")
        XCTAssertEqual(fixed.newest?.pts.value, b.value,
                       "#11.1: after commit the render mailbox must present the successor frame B, not the stale A")

        // NEGATIVE CONTROL: the pre-fix drop discards B → the mailbox still holds the stale A.
        let neg = try reconfigureAndCommit(skipBuffer: true, priorFramePTS: a, successorPTS: b, id: "display:111")
        XCTAssertEqual(neg.newest?.pts.value, a.value,
                       "negative control vacuous: the dropped-successor path did NOT leave the stale prior frame A")
    }

    /// With NO prior frame, the successor B/PTS20 arriving pre-commit must be PRESENT after commit
    /// (the screen is not black/missing). Negative control (drop) leaves the mailbox empty.
    func testDeferredSuccessorFramePresentWithNoPriorFrame() throws {
        let b = CMTime(value: 20, timescale: 600)

        let fixed = try reconfigureAndCommit(skipBuffer: false, priorFramePTS: nil, successorPTS: b, id: "display:112")
        XCTAssertEqual(fixed.newest?.pts.value, b.value,
                       "#11.1: with no prior frame, after commit the render mailbox must present the successor frame B")

        let neg = try reconfigureAndCommit(skipBuffer: true, priorFramePTS: nil, successorPTS: b, id: "display:112")
        XCTAssertNil(neg.newest,
                     "negative control vacuous: the dropped-successor path did NOT leave the screen black/missing")
    }

    /// SERIALIZE not regressed: buffering the successor frame during the deferred window must NOT
    /// touch the shared `SourceEffectGPU` (0 deliveries while buffered), and the flush at arm is a
    /// SINGLE serialized delivery — the concurrency probe never exceeds 1 on the shared pipeline.
    func testDeferredBufferDoesNotUseSharedPipelineUntilArm() throws {
        let engine = AppEngine()
        guard engine.renderLoop != nil else { throw XCTSkip("no Metal device") }
        AppEngine._test_skipScreenSourceStart = true
        AppEngine._test_simulatedScreenStartOutcome = .none
        defer {
            AppEngine._test_skipScreenSourceStart = false
            AppEngine._test_simulatedScreenStartOutcome = .none
            AppEngine._test_clearScreenSwapProbes()
        }
        let (sid, _, desc) = try registerScreen(engine, id: "display:113")
        let probe = AppEngine._test_installScreenSwapProbe(for: sid)
        let mailbox = try XCTUnwrap(engine._test_screenMailbox(for: sid))
        engine.setHDREnabled(true)
        guard engine.hdrEnabled else { throw XCTSkip("HDR toggle did not take") }
        let pending = try XCTUnwrap(engine._test_pendingScreenReplacementHandles(for: sid)).source

        // Buffer a successor frame during the deferred window: it must NOT reach the shared pipeline.
        pending.onFrame?(try Self.makeBGRAFrame(source: sid, pts: CMTime(value: 20, timescale: 600)))
        XCTAssertEqual(probe.videoDeliveries, 0,
                       "#11.1: buffering a deferred frame must NOT deliver into the shared SourceEffectGPU")
        XCTAssertEqual(probe.maxVideoConcurrency, 0, "buffering must not enter the shared pipeline")

        // Commit → the buffered frame is flushed exactly once, serialized (max concurrency 1).
        engine._test_commitScreenReplacementDirect(id: sid, source: pending, mailbox: mailbox, descriptor: desc)
        XCTAssertEqual(probe.videoDeliveries, 1, "the buffered successor frame must be flushed exactly once at arm")
        XCTAssertEqual(probe.maxVideoConcurrency, 1,
                       "SERIALIZE regressed: the buffered-frame flush must never overlap a live delivery on the shared pipeline")
    }

    /// Latest-wins: only the LAST deferred frame is replayed at commit (a stale earlier frame is
    /// never presented, and exactly one flush reaches the mailbox).
    func testDeferredBufferIsLatestWins() throws {
        let engine = AppEngine()
        guard engine.renderLoop != nil else { throw XCTSkip("no Metal device") }
        AppEngine._test_skipScreenSourceStart = true
        AppEngine._test_simulatedScreenStartOutcome = .none
        defer {
            AppEngine._test_skipScreenSourceStart = false
            AppEngine._test_simulatedScreenStartOutcome = .none
            AppEngine._test_clearScreenSwapProbes()
        }
        let (sid, _, desc) = try registerScreen(engine, id: "display:114")
        let probe = AppEngine._test_installScreenSwapProbe(for: sid)
        let mailbox = try XCTUnwrap(engine._test_screenMailbox(for: sid))
        engine.setHDREnabled(true)
        guard engine.hdrEnabled else { throw XCTSkip("HDR toggle did not take") }
        let pending = try XCTUnwrap(engine._test_pendingScreenReplacementHandles(for: sid)).source

        pending.onFrame?(try Self.makeBGRAFrame(source: sid, pts: CMTime(value: 20, timescale: 600)))
        pending.onFrame?(try Self.makeBGRAFrame(source: sid, pts: CMTime(value: 40, timescale: 600))) // newer wins
        engine._test_commitScreenReplacementDirect(id: sid, source: pending, mailbox: mailbox, descriptor: desc)

        XCTAssertEqual(probe.videoDeliveries, 1, "latest-wins: exactly one buffered frame is flushed at commit")
        XCTAssertEqual(mailbox.takeNewest()?.pts.value, 40, "latest-wins: the NEWEST deferred frame must be the one presented")
    }
}
