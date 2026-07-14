import CoreMedia
import CoreVideo
import os
import XCTest

import PrismCore
import PrismScreen
@testable import Prism

/// sol #12 #1 (gpt-5.6-sol, HIGH) — the wave-12 buffer/replay screen hot-swap fix introduced a
/// SAME-MODE ABA defect: an older superseded pending replacement replays its STALE buffered frame
/// over the NEWER live successor.
///
/// Exact interleaving:
///   • HDR on  → queues replacement H1 (pending; async start unconfirmed).
///   • HDR off → leaves H1 pending (the live source is still the original SDR, so no new work).
///   • HDR on  → queues H2. Now H1 and H2 BOTH target the final HDR mode.
///   • H1 buffers a frame at PTS10; H2 buffers a frame at PTS20.
///   • H2's async start confirms FIRST → commits, arms, presents its buffered frame, and emits a
///     live PTS30. H2 is now the live source.
///   • H1's async start confirms LAST. Because H1 and H2 target the SAME final HDR mode, the
///     mode-only (`hdrModeEpoch`) stale check can't distinguish them → pre-fix H1 COMMITS: it
///     retires+stops the live successor H2 and replays H1's stale PTS10 over H2's newer content.
///     Expected PTS30, got PTS10 — an idle screen then stays stale indefinitely.
///
/// FIX (two guarantees): (1) at registration a newer replacement SUPERSEDES an older NON-restore
/// pending for the same source — retires its gate (dropping its buffered frame) and drops its
/// record — so H1's late resolution finds `removed == nil` and NO-OPs; (2) each pending carries a
/// monotonic per-source generation the commit re-checks (defense-in-depth: a superseded generation
/// never arms/replays nor retires the live successor). The wave-10 serialize, single-lock gating,
/// mode-epoch, drained-stale-commit, and wave-11/12 buffer/replay are all preserved.
///
/// Each test reproduces the pre-fix stale replay via the `_test_skipReplacementSupersession`
/// negative control (H1's PTS10 replays over H2), then proves the fix presents H2's live PTS30 and
/// keeps H2 the live source. The serialize invariant (max concurrency 1) is asserted directly.
@MainActor
final class SolWave12ScreenABATests: XCTestCase {

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

    private struct ABAResult {
        let newestPTS: Int64?          // what a render tick would present after H1's late commit
        let liveIsH2: Bool             // the live source is still H2 (not retired/replaced by H1)
        let maxVideoConcurrency: Int   // shared-pipeline serialize probe
        let videoDeliveries: Int
    }

    /// Drive the EXACT ABA interleaving. `skipSupersession` selects the pre-fix bug (H1's stale
    /// PTS10 replays over H2's live PTS30).
    private func driveABA(skipSupersession: Bool, id: String) throws -> ABAResult {
        let engine = AppEngine()
        guard engine.renderLoop != nil else { throw XCTSkip("no Metal device") }
        AppEngine._test_skipScreenSourceStart = true
        AppEngine._test_simulatedScreenStartOutcome = .none          // replacements stay PENDING (manual commit)
        AppEngine._test_skipReplacementSupersession = skipSupersession
        defer {
            AppEngine._test_skipScreenSourceStart = false
            AppEngine._test_simulatedScreenStartOutcome = .none
            AppEngine._test_skipReplacementSupersession = false
            AppEngine._test_clearScreenSwapProbes()
        }
        let (sid, _, desc) = try registerScreen(engine, id: id)
        let probe = AppEngine._test_installScreenSwapProbe(for: sid)
        let mailbox = try XCTUnwrap(engine._test_screenMailbox(for: sid))

        // HDR on → H1 pending (the only pending → deterministic handle). Hold a STRONG ref so H1
        // survives even after supersession drops its record, letting us fire its LATE commit.
        engine.setHDREnabled(true)
        guard engine.hdrEnabled else { throw XCTSkip("HDR toggle did not take") }
        let h1 = try XCTUnwrap(engine._test_pendingScreenReplacementHandles(for: sid)).source

        // HDR off → leaves H1 pending (live source is still the original SDR → no new replacement).
        engine.setHDREnabled(false)
        // HDR on → queues H2 (supersedes H1 when the fix is active). Both target the final HDR mode.
        engine.setHDREnabled(true)
        guard engine.hdrEnabled else { throw XCTSkip("HDR toggle-back did not take") }
        let h2 = try XCTUnwrap(engine._test_lastScreenReplacement)
        XCTAssertFalse(h1 === h2, "test setup invalid: H1 and H2 must be distinct replacement sources")

        // H1 buffers PTS10, H2 buffers PTS20 (each into its own deferred gate; DATA only).
        h1.onFrame?(try Self.makeBGRAFrame(source: sid, pts: CMTime(value: 10, timescale: 600)))
        h2.onFrame?(try Self.makeBGRAFrame(source: sid, pts: CMTime(value: 20, timescale: 600)))

        // H2 commits FIRST (arms, flushes its buffered PTS20) and then emits a LIVE PTS30.
        engine._test_commitScreenReplacementDirect(id: sid, source: h2, mailbox: mailbox, descriptor: desc)
        h2.onFrame?(try Self.makeBGRAFrame(source: sid, pts: CMTime(value: 30, timescale: 600)))

        // H1 resolves LAST. FIX → superseded, NO-OP. Pre-fix → retires H2 + replays stale PTS10.
        engine._test_commitScreenReplacementDirect(id: sid, source: h1, mailbox: mailbox, descriptor: desc)

        return ABAResult(newestPTS: mailbox.takeNewest()?.pts.value,
                         liveIsH2: engine._test_activeScreenSource(for: sid) === h2,
                         maxVideoConcurrency: probe.maxVideoConcurrency,
                         videoDeliveries: probe.videoDeliveries)
    }

    /// The headline: a same-mode ABA must present H2's LIVE PTS30 and keep H2 live — never replay
    /// H1's stale buffered PTS10. Negative control (supersession off) reproduces the stale replay.
    func testSameModeABADoesNotReplayStaleFrameOverLiveSuccessor() throws {
        // FIX: H1's late commit is a no-op → H2's live PTS30 stands, H2 is still the live source.
        let fixed = try driveABA(skipSupersession: false, id: "display:301")
        XCTAssertEqual(fixed.newestPTS, 30,
                       "#12.1: the superseded older replacement H1 replayed its stale frame over the newer live successor H2")
        XCTAssertTrue(fixed.liveIsH2, "#12.1: H1's late commit retired/replaced the live successor H2")
        XCTAssertLessThanOrEqual(fixed.maxVideoConcurrency, 1,
                                 "SERIALIZE regressed: two generations touched the shared pipeline concurrently")
        XCTAssertGreaterThanOrEqual(fixed.videoDeliveries, 1,
                                    "vacuous: H2 never delivered its buffered/live frame through the shared pipeline")

        // NEGATIVE CONTROL: without supersession H1 commits LAST → stale PTS10 replays, H2 retired.
        let neg = try driveABA(skipSupersession: true, id: "display:301")
        XCTAssertEqual(neg.newestPTS, 10,
                       "negative control vacuous: the pre-fix path did NOT replay H1's stale PTS10 over H2")
        XCTAssertFalse(neg.liveIsH2, "negative control vacuous: the pre-fix path did NOT retire/replace the live successor H2")
    }

    /// Registration-time supersession: after H2 is queued for a source that already had a pending
    /// H1, only ONE pending remains (H1's gate retired, record dropped) — the primary fix. With the
    /// negative control both coexist (the pre-fix window the mode-only stale check couldn't resolve).
    func testNewerReplacementSupersedesOlderPendingAtRegistration() throws {
        func pendingCountAfterSecondQueue(skipSupersession: Bool, id: String) throws -> Int {
            let engine = AppEngine()
            guard engine.renderLoop != nil else { throw XCTSkip("no Metal device") }
            AppEngine._test_skipScreenSourceStart = true
            AppEngine._test_simulatedScreenStartOutcome = .none
            AppEngine._test_skipReplacementSupersession = skipSupersession
            defer {
                AppEngine._test_skipScreenSourceStart = false
                AppEngine._test_simulatedScreenStartOutcome = .none
                AppEngine._test_skipReplacementSupersession = false
            }
            let (sid, _, _) = try registerScreen(engine, id: id)
            engine.setHDREnabled(true)
            guard engine.hdrEnabled else { throw XCTSkip("HDR toggle did not take") }
            _ = try XCTUnwrap(engine._test_pendingScreenReplacementHandles(for: sid)).source // hold H1
            engine.setHDREnabled(false)
            engine.setHDREnabled(true)
            guard engine.hdrEnabled else { throw XCTSkip("HDR toggle-back did not take") }
            return engine._test_pendingScreenReplacementCount()
        }

        XCTAssertEqual(try pendingCountAfterSecondQueue(skipSupersession: false, id: "display:302"), 1,
                       "#12.1: registering H2 must supersede the older pending H1 (retire+drop) → one pending")
        XCTAssertEqual(try pendingCountAfterSecondQueue(skipSupersession: true, id: "display:302"), 2,
                       "negative control vacuous: the pre-fix path did NOT leave two coexisting pendings")
    }

    /// sol #12 #2 (RESTORE ABA — wave-13 scoped supersession to `!isRestore`, leaving the restore
    /// path open): the SAME stale-replay defect on the RESTORE lineage.
    ///
    /// Exact interleaving:
    ///   • HDR on  → HDR1 commits (live HDR).
    ///   • HDR1 FAILS post-commit → a SDR restore R is queued (pending, `isRestore`).
    ///   • HDR off → queues a newer SDR replacement N (non-restore). Both R and N are pending.
    ///   • N's async start confirms FIRST → commits, arms, presents its buffered frame, emits a live
    ///     PTS30. N is the live source.
    ///   • R's async start confirms LAST. Pre-fix (supersession scoped to `!isRestore`) R COMMITS:
    ///     it retires+stops the live successor N and replays R's stale PTS10 over N's newer content.
    ///
    /// FIX: a late-resolving pending (restore OR not) whose birth generation is OLDER than the
    /// currently-live committed generation NO-OPs — so R (queued before N which already went live)
    /// is rejected, N stays live, R's stale PTS10 never replays. A LONE restore (nothing newer
    /// committed after it) still commits/recovers (see `testLoneRestoreStillRecoversPostCommit`).
    private struct RestoreABAResult {
        let newestPTS: Int64?
        let liveIsN: Bool
        let liveIsRestore: Bool
        let maxVideoConcurrency: Int
        let pendingAfterNewer: Int
    }

    private func driveRestoreABA(skipSupersession: Bool, id: String) throws -> RestoreABAResult {
        let engine = AppEngine()
        guard engine.renderLoop != nil else { throw XCTSkip("no Metal device") }
        AppEngine._test_skipScreenSourceStart = true
        AppEngine._test_skipReplacementSupersession = skipSupersession
        defer {
            AppEngine._test_skipScreenSourceStart = false
            AppEngine._test_simulatedScreenStartOutcome = .none
            AppEngine._test_skipReplacementSupersession = false
            AppEngine._test_clearScreenSwapProbes()
        }
        let (sid, _, desc) = try registerScreen(engine, id: id)
        let probe = AppEngine._test_installScreenSwapProbe(for: sid)
        let mailbox = try XCTUnwrap(engine._test_screenMailbox(for: sid))

        // HDR on → HDR1 auto-commits (live HDR).
        AppEngine._test_simulatedScreenStartOutcome = .success
        engine.setHDREnabled(true)
        guard engine.hdrEnabled, engine.integrationDebugScreenSourcePreferHDR(sid) == true else {
            throw XCTSkip("HDR toggle/commit did not take")
        }
        // Switch to MANUAL commits; fail the live HDR source → SDR restore R queued (pending).
        AppEngine._test_simulatedScreenStartOutcome = .none
        engine._test_failLiveScreenSource(sid)
        let r = try XCTUnwrap(engine._test_pendingScreenReplacementHandles(for: sid)).source

        // HDR off → queues a NEWER SDR non-restore replacement N. Both R and N are now pending.
        engine.setHDREnabled(false)
        guard !engine.hdrEnabled else { throw XCTSkip("HDR toggle-off did not take") }
        let n = try XCTUnwrap(engine._test_lastScreenReplacement)
        XCTAssertFalse(r === n, "test setup invalid: R and N must be distinct replacement sources")
        let pendingAfterNewer = engine._test_pendingScreenReplacementCount()

        // R buffers PTS10, N buffers PTS20 (DATA only, into their own deferred gates).
        r.onFrame?(try Self.makeBGRAFrame(source: sid, pts: CMTime(value: 10, timescale: 600)))
        n.onFrame?(try Self.makeBGRAFrame(source: sid, pts: CMTime(value: 20, timescale: 600)))

        // N commits FIRST (arms, flushes PTS20) then emits a LIVE PTS30 → N is the live source.
        engine._test_commitScreenReplacementDirect(id: sid, source: n, mailbox: mailbox, descriptor: desc)
        n.onFrame?(try Self.makeBGRAFrame(source: sid, pts: CMTime(value: 30, timescale: 600)))

        // R resolves LAST. FIX → superseded (older committed generation), NO-OP. Pre-fix → retires N
        // + replays stale PTS10.
        engine._test_commitScreenReplacementDirect(id: sid, source: r, mailbox: mailbox, descriptor: desc)

        return RestoreABAResult(newestPTS: mailbox.takeNewest()?.pts.value,
                                liveIsN: engine._test_activeScreenSource(for: sid) === n,
                                liveIsRestore: engine._test_activeScreenSource(for: sid) === r,
                                maxVideoConcurrency: probe.maxVideoConcurrency,
                                pendingAfterNewer: pendingAfterNewer)
    }

    func testRestoreABADoesNotReplayStaleFrameOverLiveSuccessor() throws {
        // FIX: R's late commit is a no-op → N's live PTS30 stands, N is still the live source.
        let fixed = try driveRestoreABA(skipSupersession: false, id: "display:311")
        XCTAssertEqual(fixed.pendingAfterNewer, 2,
                       "test setup: the older restore R must still coexist with the newer N at registration")
        XCTAssertEqual(fixed.newestPTS, 30,
                       "#12.2: the superseded older restore R replayed its stale frame over the newer live successor N")
        XCTAssertTrue(fixed.liveIsN, "#12.2: R's late commit retired/replaced the live successor N")
        XCTAssertFalse(fixed.liveIsRestore, "#12.2: the stale restore became the live source")
        XCTAssertLessThanOrEqual(fixed.maxVideoConcurrency, 1,
                                 "SERIALIZE regressed: two generations touched the shared pipeline concurrently")

        // NEGATIVE CONTROL: without the restore-aware guard R commits LAST → stale PTS10 replays, N retired.
        let neg = try driveRestoreABA(skipSupersession: true, id: "display:311")
        XCTAssertEqual(neg.newestPTS, 10,
                       "negative control vacuous: the pre-fix path did NOT replay R's stale PTS10 over N")
        XCTAssertTrue(neg.liveIsRestore, "negative control vacuous: the pre-fix path did NOT make the stale restore live")
    }

    /// The recovery half of the guarantee: a restore with NO newer replacement committed after it
    /// still commits and becomes the live source (the sol #8 #2 post-commit-failure immediate
    /// fallback). Proves the restore-aware supersession did NOT break lone-restore recovery.
    func testLoneRestoreStillRecoversPostCommit() throws {
        let engine = AppEngine()
        guard engine.renderLoop != nil else { throw XCTSkip("no Metal device") }
        AppEngine._test_skipScreenSourceStart = true
        defer {
            AppEngine._test_skipScreenSourceStart = false
            AppEngine._test_simulatedScreenStartOutcome = .none
        }
        let (sid, _, desc) = try registerScreen(engine, id: "display:312")
        let mailbox = try XCTUnwrap(engine._test_screenMailbox(for: sid))
        AppEngine._test_simulatedScreenStartOutcome = .success
        engine.setHDREnabled(true)
        guard engine.hdrEnabled, engine.integrationDebugScreenSourcePreferHDR(sid) == true else {
            throw XCTSkip("HDR toggle/commit did not take")
        }
        // Fail live HDR → a SOLE SDR restore R is queued (nothing newer registered after it).
        AppEngine._test_simulatedScreenStartOutcome = .none
        engine._test_failLiveScreenSource(sid)
        let r = try XCTUnwrap(engine._test_pendingScreenReplacementHandles(for: sid)).source
        XCTAssertEqual(engine._test_pendingScreenReplacementCount(), 1, "test setup: exactly one pending restore")
        // R commits — the immediate SDR fallback while the show still wants HDR (unchanged epoch) is
        // legitimate; the committed-generation guard must NOT reject it (it is the latest committed).
        engine._test_commitScreenReplacementDirect(id: sid, source: r, mailbox: mailbox, descriptor: desc)
        XCTAssertTrue(engine._test_activeScreenSource(for: sid) === r,
                      "#12.2 regressed lone-restore recovery: the restore was rejected and never went live")
    }

    /// The NON-ABA single-replacement buffer/replay (wave-12) is intact: with just ONE replacement,
    /// the successor's buffered frame is still presented at commit (serialize probe: exactly one
    /// flush, max concurrency 1). Guards that the ABA fix didn't regress the legitimate replay.
    func testNonABASingleReplacementStillReplaysSuccessorFrame() throws {
        let engine = AppEngine()
        guard engine.renderLoop != nil else { throw XCTSkip("no Metal device") }
        AppEngine._test_skipScreenSourceStart = true
        AppEngine._test_simulatedScreenStartOutcome = .none
        defer {
            AppEngine._test_skipScreenSourceStart = false
            AppEngine._test_simulatedScreenStartOutcome = .none
            AppEngine._test_clearScreenSwapProbes()
        }
        let (sid, _, desc) = try registerScreen(engine, id: "display:303")
        let probe = AppEngine._test_installScreenSwapProbe(for: sid)
        let mailbox = try XCTUnwrap(engine._test_screenMailbox(for: sid))
        engine.setHDREnabled(true)
        guard engine.hdrEnabled else { throw XCTSkip("HDR toggle did not take") }
        let pending = try XCTUnwrap(engine._test_pendingScreenReplacementHandles(for: sid)).source

        pending.onFrame?(try Self.makeBGRAFrame(source: sid, pts: CMTime(value: 20, timescale: 600)))
        XCTAssertEqual(probe.videoDeliveries, 0, "buffering must not reach the shared pipeline before arm")
        engine._test_commitScreenReplacementDirect(id: sid, source: pending, mailbox: mailbox, descriptor: desc)

        XCTAssertEqual(mailbox.takeNewest()?.pts.value, 20,
                       "wave-12 regressed: the single-replacement buffered successor frame is no longer presented")
        XCTAssertEqual(probe.videoDeliveries, 1, "the buffered successor frame must be flushed exactly once at arm")
        XCTAssertEqual(probe.maxVideoConcurrency, 1, "SERIALIZE regressed on the single-replacement path")
        XCTAssertTrue(engine._test_activeScreenSource(for: sid) === pending, "the committed replacement must be the live source")
    }
}
