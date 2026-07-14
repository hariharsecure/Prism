import CoreMedia
import Foundation
import XCTest
import os

import PrismAudio
import PrismDirector
import PrismOutput
@testable import Prism

/// FLAGSHIP "Director's Cut" — slice 2 (signals → score → auto-save).
///
/// Verifies the App-side wiring built on slice 1's pure `HighlightDirector`:
///  • the `directorsCutEnabled` toggle is zero-overhead / no-behaviour-change when off;
///  • a high-scoring live sequence fed through the WIRED path auto-saves exactly
///    one horizontal highlight, at a unique non-clobbering path, with the right duration;
///  • callback chaining preserves a pre-existing source handler (both fire);
///  • the in-flight guard bounds concurrent saves under a burst;
///  • `topDirectorHighlights` reflects the ingested moments.
///
/// Deterministic: every event carries an injected PTS (no wall clock in the
/// scoring), and the auto-save target is a temp dir with a mock saver seam.
@MainActor
final class DirectorsCutSlice2Tests: XCTestCase {

    // MARK: - Test doubles

    /// A very wide "ring coverage" so a mock never clamps the requested window.
    static let wideWindow: (start: CMTime, end: CMTime) =
        (CMTime(seconds: -1_000_000, preferredTimescale: 600),
         CMTime(seconds:  1_000_000, preferredTimescale: 600))

    /// Non-blocking windowed clip-saver spy: records each `saveHighlightWindow` call.
    final class SpySaver: HighlightClipSaving, @unchecked Sendable {
        struct Call: Sendable { let start: CMTime; let end: CMTime; let url: URL }
        private let lock = OSAllocatedUnfairLock(initialState: [Call]())
        var onCall: (@Sendable () -> Void)?
        var window: (start: CMTime, end: CMTime)? = DirectorsCutSlice2Tests.wideWindow
        var availableWindow: (start: CMTime, end: CMTime)? { window }
        var calls: [Call] { lock.withLock { $0 } }
        func saveHighlightWindow(from start: CMTime, to end: CMTime, to url: URL) async throws -> URL {
            lock.withLock { $0.append(Call(start: start, end: end, url: url)) }
            onCall?()
            return url
        }
    }

    /// Vertical reframer spy: returns the requested vertical URL (distinct from
    /// the horizontal), recording the (horizontal, vertical) pairing.
    final class SpyReframer: VerticalHighlightProducing, @unchecked Sendable {
        struct Pair: Sendable { let horizontal: URL; let vertical: URL }
        private let lock = OSAllocatedUnfairLock(initialState: [Pair]())
        var pairs: [Pair] { lock.withLock { $0 } }
        func reframeToVertical(horizontal: URL, to url: URL) async throws -> URL {
            lock.withLock { $0.append(Pair(horizontal: horizontal, vertical: url)) }
            return url
        }
    }

    /// Blocking clip-saver: holds every admitted save in-flight (on a checked
    /// continuation) so the test can observe peak concurrency, then release.
    final class BlockingSaver: HighlightClipSaving, @unchecked Sendable {
        private struct S { var active = 0; var maxActive = 0; var entered = 0 }
        private let lock = OSAllocatedUnfairLock(initialState: S())
        private let gate = OSAllocatedUnfairLock(initialState: [CheckedContinuation<Void, Never>]())
        let onEntered: XCTestExpectation
        init(onEntered: XCTestExpectation) { self.onEntered = onEntered }
        var availableWindow: (start: CMTime, end: CMTime)? { DirectorsCutSlice2Tests.wideWindow }
        var maxActive: Int { lock.withLock { $0.maxActive } }
        var entered: Int { lock.withLock { $0.entered } }
        func saveHighlightWindow(from start: CMTime, to end: CMTime, to url: URL) async throws -> URL {
            lock.withLock { s in s.active += 1; s.entered += 1; s.maxActive = max(s.maxActive, s.active) }
            onEntered.fulfill()
            await withCheckedContinuation { c in gate.withLock { $0.append(c) } }
            lock.withLock { s in s.active -= 1 }
            return url
        }
        func releaseAll() {
            let conts = gate.withLock { let c = $0; $0.removeAll(); return c }
            for c in conts { c.resume() }
        }
    }

    private func transient(_ strength: Double, at t: Double) -> TransientInfo {
        TransientInfo(hostSeconds: t, strength: strength,
                      pts: CMTime(seconds: t, preferredTimescale: 600))
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismDirectorsCutTests-\(UUID().uuidString)")
        return dir
    }

    // MARK: - 1. Off = zero overhead / no behaviour change

    func testDisabledIngestsNothingAndSavesNothing() async throws {
        let engine = AppEngine()
        let spy = SpySaver()
        // A saver + directory are present, but the toggle is OFF (default) → the
        // wired feeds must short-circuit: no ingest, no highlights, no save.
        engine._test_highlightSaverOverride = spy
        engine._test_directorsCutDirectoryOverride = tempDir()

        XCTAssertFalse(engine.directorsCutEnabled)
        engine.feedTransientToDirector(transient(1.0, at: 10))
        engine.feedCaptionToDirector(CaptionUpdate(text: "hahaha that was hilarious", isFinal: true, hostSeconds: 10.1))
        engine.feedLoudnessToDirector(momentaryLUFS: -6, at: CMTime(seconds: 10, preferredTimescale: 600))

        XCTAssertTrue(engine.topDirectorHighlights.isEmpty, "no scoring while disabled")
        XCTAssertEqual(spy.calls.count, 0, "no auto-save while disabled")
        XCTAssertNil(engine.lastHighlightURL)
        await engine.shutdown()
    }

    // MARK: - 2. Enabled: high-scoring sequence → exactly one unique save

    func testCoOccurrenceTriggersExactlyOneUniqueSave() async throws {
        let engine = AppEngine()
        let spy = SpySaver()
        let dir = tempDir()
        engine._test_highlightSaverOverride = spy
        engine._test_verticalReframerOverride = SpyReframer()
        engine._test_directorsCutDirectoryOverride = dir
        engine.setDirectorsCutEnabled(true)
        engine.setDirectorsCutRoll(preRoll: 8, postRoll: 0.05)   // fast post-roll for the test

        let saved = expectation(description: "one auto-save")
        spy.onCall = { saved.fulfill() }

        // Neither cue alone crosses threshold (default weights 1.0, threshold 1.0):
        // transient 0.6 and laughter ~0.8. Co-occurring within the window they SUM
        // past 1.0 → exactly one highlight fires → exactly one save (after post-roll).
        engine.feedTransientToDirector(transient(0.6, at: 100.0))
        engine.feedCaptionToDirector(CaptionUpdate(text: "hahaha", isFinal: true, hostSeconds: 100.1))

        await fulfillment(of: [saved], timeout: 5)
        XCTAssertEqual(spy.calls.count, 1, "exactly one save for the single fired highlight")

        let call = try XCTUnwrap(spy.calls.first)
        // The saved window spans [peak − preRoll, peak + postRoll] pinned to house
        // PTS — the run-up AND the payoff, not a trailing window ending at the peak.
        // The peak is whichever co-occurring event scored highest (the laughter at
        // 100.1 here), so assert against the candidate's recorded peak, not 100.0.
        let peak = try XCTUnwrap(engine.highlightCandidates.first).peakSeconds
        XCTAssertEqual(call.start.seconds, peak - 8, accuracy: 0.01, "window start = peak − preRoll")
        XCTAssertEqual(call.end.seconds, peak + 0.05, accuracy: 0.01, "window end = peak + postRoll")
        XCTAssertTrue(call.url.path.hasPrefix(dir.path), "saved into the Director's Cut folder")
        XCTAssertEqual(call.url.pathExtension, "mov")
        // The saver is handed a fresh, non-clobbering path (no overwrite request).
        XCTAssertEqual(RecorderFilePath.nonClobbering(call.url), call.url,
                       "requested path is unique — the saver is not asked to overwrite")
        await engine.shutdown()
    }

    /// Two distinct fired highlights must land at DISTINCT paths (non-clobbering).
    func testTwoHighlightsGetDistinctPaths() async throws {
        let engine = AppEngine()
        let spy = SpySaver()
        engine._test_highlightSaverOverride = spy
        engine._test_verticalReframerOverride = SpyReframer()
        engine._test_directorsCutDirectoryOverride = tempDir()
        engine.setDirectorsCutEnabled(true)
        engine.setDirectorsCutRoll(preRoll: 8, postRoll: 0.05)

        let saved = expectation(description: "two saves")
        saved.expectedFulfillmentCount = 2
        spy.onCall = { saved.fulfill() }

        // Two strong transients > minGap (15s) apart → two distinct clusters fire.
        engine.feedTransientToDirector(transient(1.0, at: 10))
        engine.feedTransientToDirector(transient(1.0, at: 40))

        await fulfillment(of: [saved], timeout: 5)
        XCTAssertEqual(spy.calls.count, 2)
        XCTAssertNotEqual(spy.calls[0].url, spy.calls[1].url, "two highlights → two distinct paths")
        await engine.shutdown()
    }

    // MARK: - 3. Chaining preserves a pre-existing handler (both fire)

    func testChainUtilityRunsExistingThenAdded() {
        let rec = OSAllocatedUnfairLock(initialState: [String]())
        let existing: @Sendable (Int) -> Void = { v in rec.withLock { $0.append("existing:\(v)") } }
        let added: @Sendable (Int) -> Void = { v in rec.withLock { $0.append("added:\(v)") } }

        HighlightFeeds.chain(existing, added)(7)
        XCTAssertEqual(rec.withLock { $0 }, ["existing:7", "added:7"], "existing runs first, then added")

        let rec2 = OSAllocatedUnfairLock(initialState: [String]())
        let added2: @Sendable (Int) -> Void = { v in rec2.withLock { $0.append("added:\(v)") } }
        HighlightFeeds.chain(nil, added2)(3)
        XCTAssertEqual(rec2.withLock { $0 }, ["added:3"], "nil existing handler is skipped, added still fires")
    }

    /// End-to-end: a pre-existing `onTransient` handler chained with the engine's
    /// highlight feed — invoking the chained callback fires BOTH the existing
    /// handler AND scores the moment in the director.
    func testChainedTransientFiresExistingHandlerAndFeedsDirector() {
        let engine = AppEngine()
        engine._test_highlightSaverOverride = SpySaver()
        engine._test_directorsCutDirectoryOverride = tempDir()
        engine.setDirectorsCutEnabled(true)

        let existingFired = OSAllocatedUnfairLock(initialState: false)
        let detector = TransientDetector(sampleRate: 48_000)
        detector.onTransient = { _ in existingFired.withLock { $0 = true } }
        // Mirror AppEngine's wiring: chain the feed onto the existing handler.
        let feed: @Sendable (TransientInfo) -> Void = { [weak engine] info in
            MainActor.assumeIsolated { engine?.feedTransientToDirector(info) }
        }
        detector.onTransient = HighlightFeeds.chain(detector.onTransient, feed)

        detector.onTransient?(transient(1.0, at: 50))

        XCTAssertTrue(existingFired.withLock { $0 }, "pre-existing onTransient handler still fires")
        XCTAssertEqual(engine.topDirectorHighlights.count, 1, "the chained feed scored the moment")
        XCTAssertEqual(engine.topDirectorHighlights.first?.peakSeconds ?? -1, 50, accuracy: 0.001)
    }

    // MARK: - 4. In-flight throttle bounds concurrent saves under a burst

    func testInFlightThrottleBoundsConcurrentSaves() async throws {
        let engine = AppEngine()
        let entered = expectation(description: "two saves reach the saver")
        entered.expectedFulfillmentCount = 2   // engine's HighlightAutoSaver.maxInFlight == 2
        let saver = BlockingSaver(onEntered: entered)
        engine._test_highlightSaverOverride = saver
        engine._test_verticalReframerOverride = SpyReframer()   // don't hit real AVFoundation
        engine._test_directorsCutDirectoryOverride = tempDir()
        engine.setDirectorsCutEnabled(true)
        engine.setDirectorsCutRoll(preRoll: 8, postRoll: 0.05)

        // A burst of 5 strong, well-separated transients → 5 highlights fire → 5
        // save requests. The in-flight guard admits at most 2; the other 3 drop.
        for t in stride(from: 10.0, through: 90.0, by: 20.0) {
            engine.feedTransientToDirector(transient(1.0, at: t))
        }

        await fulfillment(of: [entered], timeout: 5)
        // Each highlight's capture is DEFERRED by its own post-roll timer, so the
        // five requests arrive across timer firings. Wait until all five have been
        // requested (two are held in-flight by the blocking saver, three dropped)
        // before asserting the guard's tallies — avoids racing the timer schedule.
        let deadline = Date().addingTimeInterval(5)
        while engine._test_highlightAutoSaverMetrics.requested < 5, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        // The two admitted saves are held in-flight together — peak concurrency is
        // exactly the bound, never more.
        XCTAssertEqual(saver.maxActive, 2, "at most maxInFlight (2) concurrent saves")
        XCTAssertEqual(saver.entered, 2, "only the admitted saves ever reach the saver")

        let m = engine._test_highlightAutoSaverMetrics
        XCTAssertEqual(m.requested, 5)
        XCTAssertEqual(m.started, 2)
        XCTAssertEqual(m.dropped, 3, "3 of 5 dropped by the in-flight guard")
        XCTAssertEqual(m.maxConcurrent, 2)

        saver.releaseAll()
        await engine.shutdown()
    }

    // MARK: - 5. topHighlights reflects the ingested moments

    func testTopHighlightsReflectsIngestedMoments() async throws {
        let engine = AppEngine()
        engine._test_highlightSaverOverride = SpySaver()
        engine._test_directorsCutDirectoryOverride = tempDir()
        engine.setDirectorsCutEnabled(true)

        engine.feedTransientToDirector(transient(1.0, at: 10))
        engine.feedTransientToDirector(transient(1.0, at: 40))

        // topDirectorHighlights updates synchronously on ingest (main actor).
        let peaks = engine.topDirectorHighlights.map { $0.peakSeconds }.sorted()
        XCTAssertEqual(peaks.count, 2)
        XCTAssertEqual(peaks[0], 10, accuracy: 0.001)
        XCTAssertEqual(peaks[1], 40, accuracy: 0.001)
        await engine.shutdown()
    }

    // MARK: - Caption parser (pure)

    func testCaptionParserClassification() {
        let laugh = HighlightCaptionParser.classify("hahaha that was great")
        XCTAssertEqual(laugh?.kind, .captionLaughter)
        XCTAssertGreaterThanOrEqual(laugh?.intensity ?? 0, 0.8)

        let hype = HighlightCaptionParser.classify("wow that was insane!!!")
        XCTAssertEqual(hype?.kind, .captionKeyword)
        XCTAssertGreaterThan(hype?.intensity ?? 0, 0)

        XCTAssertNil(HighlightCaptionParser.classify("the weather is nice today"),
                     "a neutral line produces no highlight signal")
    }
}
