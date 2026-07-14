import CoreMedia
import Foundation
import XCTest
import os

import PrismAudio
import PrismDirector
import PrismOutput
@testable import Prism

/// FLAGSHIP "Director's Cut" — slice 3a (correct clip semantics + paired 16:9/9:16).
///
/// Fixes the three cross-lineage review gaps in slice-2 auto-save:
///  1. **Moment + POST-ROLL**: a peak at `t` saves the window `[t − preRoll,
///     t + postRoll]`, SCHEDULED after `postRoll` (not a trailing window ending at
///     the peak); a shutdown before the post-roll flushes the available window.
///  2. **EVERY candidate persisted** (not just the last URL): an ordered store +
///     an on-disk JSON sidecar that round-trips.
///  3. **PAIRED H+V**: each candidate carries a distinct, non-clobbering 16:9 AND
///     9:16 asset path.
///
/// Deterministic: injected PTS (no wall clock in the window math), mock
/// ring/reframer seams, a fast post-roll, and non-destructive path assertions
/// (paths are asserted UNIQUE + not-asked-to-overwrite — never a real overwrite).
@MainActor
final class DirectorsCutSlice3Tests: XCTestCase {

    // Reuse the slice-2 spies (same module).
    private typealias SpySaver = DirectorsCutSlice2Tests.SpySaver
    private typealias SpyReframer = DirectorsCutSlice2Tests.SpyReframer

    private func transient(_ strength: Double, at t: Double) -> TransientInfo {
        TransientInfo(hostSeconds: t, strength: strength,
                      pts: CMTime(seconds: t, preferredTimescale: 600))
    }
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismDCut3-\(UUID().uuidString)")
    }
    /// Small-gap scoring config so two nearby peaks are DISTINCT clusters (for the
    /// overlap test) and a single strong transient crosses threshold on its own.
    private func smallGapConfig() -> HighlightDirector.Config {
        HighlightDirector.Config(windowSeconds: 6, halfLifeSeconds: 2, topN: 8,
                                 minGapSeconds: 2, highlightDurationSeconds: 1.5, threshold: 0.5)
    }

    // MARK: - Gap 1a: peak → window [peak−pre, peak+post], scheduled (not immediate)

    func testPostRollWindowIsScheduledNotImmediate() async throws {
        let engine = AppEngine()
        let spy = SpySaver()
        engine._test_highlightSaverOverride = spy
        engine._test_verticalReframerOverride = SpyReframer()
        engine._test_directorsCutDirectoryOverride = tempDir()
        engine.setDirectorsCutEnabled(true)
        engine.setDirectorsCutRoll(preRoll: 6, postRoll: 0.3)

        let saved = expectation(description: "post-roll save fires")
        spy.onCall = { saved.fulfill() }

        engine.feedTransientToDirector(transient(1.0, at: 200))
        // Let the onHighlight main-hop run (candidate scheduled) but not the timer.
        await Task.yield()
        XCTAssertEqual(spy.calls.count, 0, "save must NOT be immediate — it is deferred by post-roll")
        // The candidate exists immediately, in the scheduled state (nothing lost).
        XCTAssertEqual(engine.highlightCandidates.count, 1)
        XCTAssertEqual(engine.highlightCandidates.first?.state, .scheduled)

        await fulfillment(of: [saved], timeout: 5)
        let call = try XCTUnwrap(spy.calls.first)
        XCTAssertEqual(call.start.seconds, 200 - 6, accuracy: 0.01, "window start = peak − preRoll")
        XCTAssertEqual(call.end.seconds, 200 + 0.3, accuracy: 0.01, "window end = peak + postRoll")
        await engine.shutdown()
    }

    // MARK: - Gap 1b: shutdown before post-roll flushes the AVAILABLE window

    func testShutdownBeforePostRollFlushesAvailableWindow() async throws {
        let engine = AppEngine()
        let spy = SpySaver()
        // Ring coverage ends AT the peak (post-roll frames have not arrived yet).
        spy.window = (CMTime(seconds: 100, preferredTimescale: 600),
                      CMTime(seconds: 200, preferredTimescale: 600))
        engine._test_highlightSaverOverride = spy
        engine._test_verticalReframerOverride = SpyReframer()
        engine._test_directorsCutDirectoryOverride = tempDir()
        engine.setDirectorsCutEnabled(true)
        engine.setDirectorsCutRoll(preRoll: 6, postRoll: 100)   // long post-roll → timer won't fire

        let saved = expectation(description: "flushed save")
        spy.onCall = { saved.fulfill() }
        engine.feedTransientToDirector(transient(1.0, at: 200))
        await Task.yield()
        XCTAssertEqual(engine.highlightCandidates.first?.state, .scheduled)
        XCTAssertEqual(spy.calls.count, 0, "nothing saved yet (post-roll pending)")

        // Shutdown before the 100 s post-roll elapses → flush the available window.
        await engine.shutdown()
        await fulfillment(of: [saved], timeout: 5)

        let call = try XCTUnwrap(spy.calls.first)
        XCTAssertEqual(call.start.seconds, 200 - 6, accuracy: 0.01, "start still = peak − preRoll")
        XCTAssertEqual(call.end.seconds, 200, accuracy: 0.01,
                       "end CLAMPED to the available ring coverage (post-roll truncated)")
        let candidate = try XCTUnwrap(engine.highlightCandidates.first)
        XCTAssertNotNil(candidate.note)
        XCTAssertTrue(candidate.note?.contains("flushed at shutdown") ?? false,
                      "flush is noted on the candidate: \(candidate.note ?? "nil")")
    }

    // MARK: - Gap 1c: two overlapping peaks → two distinct candidates, both paired

    func testTwoOverlappingPeaksProduceTwoDistinctPairedCandidates() async throws {
        let engine = AppEngine()
        let spy = SpySaver()
        let reframer = SpyReframer()
        engine._test_highlightSaverOverride = spy
        engine._test_verticalReframerOverride = reframer
        engine._test_directorConfigOverride = smallGapConfig()
        engine._test_directorsCutDirectoryOverride = tempDir()
        engine.setDirectorsCutEnabled(true)
        engine.setDirectorsCutRoll(preRoll: 4, postRoll: 0.3)

        let saved = expectation(description: "two paired saves")
        saved.expectedFulfillmentCount = 2
        spy.onCall = { saved.fulfill() }

        // Two strong peaks 2.5 s apart (> minGap 2) → two DISTINCT clusters. Both
        // are scheduled synchronously before either post-roll timer fires → their
        // post-roll windows overlap in time.
        engine.feedTransientToDirector(transient(1.0, at: 100.0))
        engine.feedTransientToDirector(transient(1.0, at: 102.5))
        await Task.yield()
        XCTAssertEqual(engine.highlightCandidates.count, 2, "two distinct candidates scheduled")

        await fulfillment(of: [saved], timeout: 5)
        // Let both onResult main-hops land the URLs.
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(spy.calls.count, 2, "two horizontal saves — none lost or duplicated")
        XCTAssertEqual(Set(spy.calls.map { $0.url }).count, 2, "two DISTINCT horizontal paths")
        XCTAssertEqual(reframer.pairs.count, 2, "two vertical reframes")
        XCTAssertEqual(Set(reframer.pairs.map { $0.vertical }).count, 2, "two DISTINCT vertical paths")

        // Every candidate ends up with BOTH a horizontal AND a vertical asset.
        let cands = engine.highlightCandidates
        XCTAssertEqual(cands.count, 2)
        for c in cands {
            XCTAssertEqual(c.state, .saved)
            XCTAssertNotNil(c.horizontalURL)
            XCTAssertNotNil(c.verticalURL)
            XCTAssertNotEqual(c.horizontalURL, c.verticalURL, "H and V are distinct paths")
            XCTAssertEqual(c.horizontalURL?.lastPathComponent.contains("16x9"), true)
            XCTAssertEqual(c.verticalURL?.lastPathComponent.contains("9x16"), true)
            // Non-clobbering: neither path was an overwrite request.
            XCTAssertEqual(RecorderFilePath.nonClobbering(c.horizontalURL!), c.horizontalURL!)
            XCTAssertEqual(RecorderFilePath.nonClobbering(c.verticalURL!), c.verticalURL!)
        }
        await engine.shutdown()
    }

    // MARK: - Gap 2: the store holds ALL candidates + round-trips to/from sidecar

    func testCandidateStoreHoldsAllAndRoundTripsSidecar() throws {
        let store = HighlightCandidateStore()
        let a = HighlightCandidate(id: UUID(), peakSeconds: 10, windowStart: 4, windowEnd: 13,
                                   score: 1.4, reason: "audioTransient",
                                   horizontalURL: URL(filePath: "/tmp/a-16x9.mov"),
                                   verticalURL: URL(filePath: "/tmp/a-9x16.mov"),
                                   state: .saved, note: nil)
        let b = HighlightCandidate(id: UUID(), peakSeconds: 40, windowStart: 34, windowEnd: 43,
                                   score: 0.9, reason: "captionLaughter",
                                   horizontalURL: nil, verticalURL: nil, state: .scheduled, note: "clamped end")
        store.append(a)
        store.append(b)
        XCTAssertEqual(store.all().count, 2, "store holds ALL candidates, not just the last")
        XCTAssertEqual(store.all().map { $0.id }, [a.id, b.id], "insertion order preserved")

        // Encode → decode round-trip is identity.
        let sidecar = store.snapshotSidecar()
        let data = try JSONEncoder().encode(sidecar)
        let decoded = try HighlightCandidateStore.decodeSidecar(data)
        XCTAssertEqual(decoded, sidecar, "sidecar round-trips 1:1")
        XCTAssertEqual(decoded.candidates, [a, b])

        // Persist to disk → load from disk is identity (survives relaunch).
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.persist(in: dir)
        let fileURL = dir.appendingPathComponent(store.sidecarName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "sidecar written next to clips")
        let loaded = try HighlightCandidateStore.load(from: fileURL)
        XCTAssertEqual(loaded.sessionID, store.sessionID)
        XCTAssertEqual(loaded.candidates, [a, b], "candidates survive a relaunch load")
    }

    /// The engine persists a per-session sidecar containing every candidate.
    func testEnginePersistsSidecarWithAllCandidates() async throws {
        let engine = AppEngine()
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        engine._test_highlightSaverOverride = SpySaver()
        engine._test_verticalReframerOverride = SpyReframer()
        engine._test_directorConfigOverride = smallGapConfig()
        engine._test_directorsCutDirectoryOverride = dir
        engine.setDirectorsCutEnabled(true)
        engine.setDirectorsCutRoll(preRoll: 4, postRoll: 0.2)

        let saved = expectation(description: "both saved")
        saved.expectedFulfillmentCount = 2
        (engine._test_highlightSaverOverride as? SpySaver)?.onCall = { saved.fulfill() }
        engine.feedTransientToDirector(transient(1.0, at: 100))
        engine.feedTransientToDirector(transient(1.0, at: 104))
        await fulfillment(of: [saved], timeout: 5)
        for _ in 0..<5 { await Task.yield() }

        // A single sidecar file exists in the folder, holding BOTH candidates.
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".prism-highlights-") && $0.hasSuffix(".json") }
        XCTAssertEqual(files.count, 1, "exactly one per-session sidecar")
        let loaded = try HighlightCandidateStore.load(from: dir.appendingPathComponent(files[0]))
        XCTAssertEqual(loaded.candidates.count, 2, "sidecar persists ALL candidates")
        await engine.shutdown()
    }

    // MARK: - Gap 3 seam: single peak → one candidate with distinct H + V paths

    func testSinglePeakProducesPairedHorizontalAndVertical() async throws {
        let engine = AppEngine()
        let spy = SpySaver()
        let reframer = SpyReframer()
        engine._test_highlightSaverOverride = spy
        engine._test_verticalReframerOverride = reframer
        engine._test_directorsCutDirectoryOverride = tempDir()
        engine.setDirectorsCutEnabled(true)
        engine.setDirectorsCutRoll(preRoll: 5, postRoll: 0.2)

        let saved = expectation(description: "paired save")
        spy.onCall = { saved.fulfill() }
        engine.feedTransientToDirector(transient(1.0, at: 300))
        await fulfillment(of: [saved], timeout: 5)
        for _ in 0..<5 { await Task.yield() }

        // The reframer was handed the horizontal the ring produced, and returned a
        // distinct vertical (the paired asset).
        let pair = try XCTUnwrap(reframer.pairs.first)
        XCTAssertEqual(pair.horizontal, spy.calls.first?.url, "vertical is reframed FROM the horizontal clip")
        XCTAssertNotEqual(pair.horizontal, pair.vertical)

        let c = try XCTUnwrap(engine.highlightCandidates.first)
        XCTAssertEqual(c.state, .saved)
        XCTAssertEqual(c.horizontalURL, pair.horizontal)
        XCTAssertEqual(c.verticalURL, pair.vertical)
        XCTAssertEqual(engine.lastHighlightURL, pair.horizontal)
        await engine.shutdown()
    }

    // MARK: - Toggle off → nothing (zero overhead)

    func testToggleOffCancelsPendingAndSchedulesNothing() async throws {
        let engine = AppEngine()
        let spy = SpySaver()
        engine._test_highlightSaverOverride = spy
        engine._test_verticalReframerOverride = SpyReframer()
        engine._test_directorsCutDirectoryOverride = tempDir()
        engine.setDirectorsCutEnabled(true)
        engine.setDirectorsCutRoll(preRoll: 5, postRoll: 100)   // long → pending when we disable

        engine.feedTransientToDirector(transient(1.0, at: 100))
        await Task.yield()
        XCTAssertEqual(engine.highlightCandidates.count, 1, "candidate scheduled while on")

        // Turn OFF before the post-roll fires → the pending capture is cancelled and
        // never saves; further feeds ingest nothing.
        engine.setDirectorsCutEnabled(false)
        engine.feedTransientToDirector(transient(1.0, at: 130))
        await Task.yield()
        // Give any (cancelled) timer a chance to (not) fire.
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(spy.calls.count, 0, "no save after toggle-off — pending capture cancelled")
        XCTAssertTrue(engine.highlightCandidates.isEmpty, "candidates cleared on disable")
        XCTAssertTrue(engine.topDirectorHighlights.isEmpty, "no scoring while off")
        await engine.shutdown()
    }
}
