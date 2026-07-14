import CoreMedia
import Foundation
import XCTest

import PrismAudio
import PrismDirector
import PrismOutput
@testable import Prism

/// FLAGSHIP "Director's Cut" — slice-3c: the Review & Finish PURE view-model.
///
/// Turns auto-generated highlight candidates (slice-3a store) into approved,
/// exportable clips. Human-in-the-loop: NOTHING auto-posts — approval gates a
/// local export target only. These tests exercise the deterministic logic against
/// the REAL slice-3a `HighlightCandidateStore` persisting to a temp dir (via
/// `StoreReviewBackend`) plus one end-to-end pass over the live `AppEngine` backend.
///
/// The SwiftUI view + AVPlayer preview + Share Sheet are UNVERIFIED-until-eyeball
/// (see `ReviewFinishView.swift`) and are intentionally not tested here.
@MainActor
final class DirectorsCutReviewFinishTests: XCTestCase {

    // MARK: Helpers

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismReviewFinish-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func candidate(score: Double,
                           state: HighlightCandidate.State = .saved,
                           h: URL? = URL(filePath: "/tmp/h-16x9.mov"),
                           v: URL? = URL(filePath: "/tmp/v-9x16.mov")) -> HighlightCandidate {
        HighlightCandidate(id: UUID(), peakSeconds: 100, windowStart: 92, windowEnd: 108,
                           score: score, reason: "audioTransient",
                           horizontalURL: h, verticalURL: v, state: state, note: nil)
    }

    /// A model wired to a real store + temp-dir sidecar backend.
    private func makeModel(_ candidates: [HighlightCandidate],
                           dir: URL,
                           existing: Set<URL> = [],
                           store: HighlightCandidateStore = HighlightCandidateStore())
    -> (ReviewFinishModel, HighlightCandidateStore, StoreReviewBackend) {
        candidates.forEach { store.append($0) }
        let backend = StoreReviewBackend(store: store, directory: dir)
        let model = ReviewFinishModel(backend: backend,
                                      fileExists: { existing.contains($0) })
        model.sync(store.all())
        return (model, store, backend)
    }

    // MARK: - Queue ordering by score

    func testQueueOrderedByScoreDescending() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let low = candidate(score: 0.5), mid = candidate(score: 1.2), high = candidate(score: 2.0)
        let (model, _, _) = makeModel([low, mid, high], dir: dir)
        XCTAssertEqual(model.queue.map(\.id), [high.id, mid.id, low.id],
                       "queue ranks candidates by score, highest first")
        // Default selection is the top finishable candidate.
        XCTAssertEqual(model.selectedID, high.id)
    }

    func testScoreOrderedStableForTies() {
        let a = candidate(score: 1.0), b = candidate(score: 1.0)
        let ordered = ReviewFinishModel.scoreOrdered([a, b])
        XCTAssertEqual(ordered.map(\.id), [a.id, b.id], "ties preserve insertion order (stable)")
    }

    // MARK: - Approve / reject transitions persist

    func testApproveUpdatesStateAndPersistsSidecar() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = candidate(score: 1.0)
        let (model, store, _) = makeModel([c], dir: dir)

        XCTAssertTrue(model.approve(id: c.id))
        XCTAssertEqual(model.queue.first?.state, .approved, "queue reflects approval")
        XCTAssertEqual(store.all().first?.state, .approved, "store mutated")

        // Persisted to the sidecar in the temp dir (survives relaunch).
        let loaded = try HighlightCandidateStore.load(from: dir.appendingPathComponent(store.sidecarName))
        XCTAssertEqual(loaded.candidates.first?.state, .approved, "approval persisted to sidecar")
    }

    func testRejectUpdatesStateAndPersists() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = candidate(score: 1.0)
        let (model, store, _) = makeModel([c], dir: dir)

        XCTAssertTrue(model.reject(id: c.id))
        XCTAssertEqual(model.queue.first?.state, .rejected)
        let loaded = try HighlightCandidateStore.load(from: dir.appendingPathComponent(store.sidecarName))
        XCTAssertEqual(loaded.candidates.first?.state, .rejected)
    }

    func testApproveWithoutAssetIsNoOpWithError() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = candidate(score: 1.0, state: .failed, h: nil, v: nil)
        let (model, store, _) = makeModel([c], dir: dir)

        XCTAssertFalse(model.approve(id: c.id), "cannot approve an asset-less candidate")
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(store.all().first?.state, .failed, "state unchanged — no false approval")
    }

    // MARK: - Reorder

    func testManualReorderChangesQueueOrderAndSurvivesSync() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = candidate(score: 2.0), b = candidate(score: 1.5), c = candidate(score: 1.0)
        let (model, store, _) = makeModel([a, b, c], dir: dir)
        XCTAssertEqual(model.queue.map(\.id), [a.id, b.id, c.id])

        // Move the last (c) to the front.
        model.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(model.queue.map(\.id), [c.id, a.id, b.id], "reorder applied")

        // A later sync (e.g. a re-publish) keeps the human's order.
        model.sync(store.all())
        XCTAssertEqual(model.queue.map(\.id), [c.id, a.id, b.id], "manual order survives sync")
    }

    // MARK: - Trim (clamped in-bounds, in ≤ out)

    func testClampTrimStaysInBoundsAndOrdered() {
        // Out-of-bounds request → clamped to [lower, upper].
        let r1 = ReviewFinishModel.clampTrim(start: -5, end: 999, lower: 10, upper: 20)
        XCTAssertEqual(r1.start, 10); XCTAssertEqual(r1.end, 20)
        // in > out → out pulled up to in (never before it).
        let r2 = ReviewFinishModel.clampTrim(start: 18, end: 12, lower: 10, upper: 20)
        XCTAssertEqual(r2.start, 18); XCTAssertEqual(r2.end, 18)
    }

    func testSetTrimUpdatesWindowClampedInBounds() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = candidate(score: 1.0)   // window [92, 108]
        let (model, store, _) = makeModel([c], dir: dir)

        // Request beyond the captured window → clamped to the window.
        XCTAssertTrue(model.setTrim(id: c.id, start: 80, end: 200))
        let saved = store.all().first!
        XCTAssertEqual(saved.effectiveStart, 92, accuracy: 0.001, "in clamped to windowStart")
        XCTAssertEqual(saved.effectiveEnd, 108, accuracy: 0.001, "out clamped to windowEnd")

        // A normal in-bounds trim narrows the clip.
        XCTAssertTrue(model.setTrim(id: c.id, start: 95, end: 101))
        let trimmed = store.all().first!
        XCTAssertEqual(trimmed.effectiveStart, 95, accuracy: 0.001)
        XCTAssertEqual(trimmed.effectiveEnd, 101, accuracy: 0.001)
        XCTAssertEqual(trimmed.effectiveDuration, 6, accuracy: 0.001)
    }

    // MARK: - Caption + style

    func testCaptionAndStyleEditsUpdateAndPersist() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = candidate(score: 1.0)
        let (model, store, _) = makeModel([c], dir: dir)

        XCTAssertTrue(model.setCaption(id: c.id, text: "That was insane!"))
        XCTAssertTrue(model.setCaptionStyle(id: c.id, style: .karaoke))

        let loaded = try HighlightCandidateStore.load(from: dir.appendingPathComponent(store.sidecarName))
        XCTAssertEqual(loaded.candidates.first?.captionText, "That was insane!")
        XCTAssertEqual(loaded.candidates.first?.captionStyle, .karaoke)
    }

    // MARK: - Aspect selection

    func testAspectSelectionUpdatesChosenVariant() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = candidate(score: 1.0)   // both H + V exist → default vertical
        let (model, store, _) = makeModel([c], dir: dir)
        XCTAssertEqual(store.all().first?.effectiveAspect, .vertical, "default aspect = vertical when 9:16 exists")

        XCTAssertTrue(model.setAspect(id: c.id, aspect: .horizontal))
        XCTAssertEqual(store.all().first?.effectiveAspect, .horizontal)
        XCTAssertEqual(store.all().first?.finishURL, c.horizontalURL, "finish URL follows the chosen aspect")
    }

    // MARK: - Export: correct variant, no-op on missing file, approve-gated

    func testExportTargetsChosenVariantWhenApprovedAndPresent() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = URL(filePath: "/tmp/present-16x9.mov")
        let v = URL(filePath: "/tmp/present-9x16.mov")
        let c = candidate(score: 1.0, h: h, v: v)
        let (model, _, _) = makeModel([c], dir: dir, existing: [h, v])

        // Approve-before-export gate: nothing exportable until approved.
        XCTAssertNil(model.exportTarget(id: c.id), "export blocked before approval")
        XCTAssertNotNil(model.lastError)

        XCTAssertTrue(model.approve(id: c.id))
        XCTAssertTrue(model.setAspect(id: c.id, aspect: .vertical))
        XCTAssertEqual(model.exportTarget(id: c.id), v, "targets the chosen (vertical) variant")
        XCTAssertTrue(model.setAspect(id: c.id, aspect: .horizontal))
        XCTAssertEqual(model.exportTarget(id: c.id), h, "targets the chosen (horizontal) variant")
    }

    func testExportIsNoOpWithErrorWhenFileMissing() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = URL(filePath: "/tmp/present-16x9.mov")
        let v = URL(filePath: "/tmp/missing-9x16.mov")   // NOT in `existing`
        let c = candidate(score: 1.0, h: h, v: v)
        let (model, _, _) = makeModel([c], dir: dir, existing: [h])   // only H exists

        XCTAssertTrue(model.approve(id: c.id))
        XCTAssertTrue(model.setAspect(id: c.id, aspect: .vertical))
        XCTAssertNil(model.exportTarget(id: c.id), "missing file → no export target (no crash)")
        XCTAssertNotNil(model.lastError, "the missing file surfaces an error")

        // Switching to the present variant recovers cleanly.
        XCTAssertTrue(model.setAspect(id: c.id, aspect: .horizontal))
        XCTAssertEqual(model.exportTarget(id: c.id), h)
    }

    func testExportMissingVariantVariantNotProduced() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Partial capture: horizontal only (vertical reframe failed).
        let h = URL(filePath: "/tmp/partial-16x9.mov")
        let c = candidate(score: 1.0, state: .partial, h: h, v: nil)
        let (model, _, _) = makeModel([c], dir: dir, existing: [h])

        XCTAssertTrue(model.approve(id: c.id), "a partial (H-only) clip is still approvable")
        XCTAssertTrue(model.setAspect(id: c.id, aspect: .vertical))
        XCTAssertNil(model.exportTarget(id: c.id), "no 9:16 variant → no target")
        XCTAssertNotNil(model.lastError)
    }

    // MARK: - Toggle-off empties the panel

    func testClearEmptiesQueue() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let (model, _, _) = makeModel([candidate(score: 1.0), candidate(score: 2.0)], dir: dir)
        XCTAssertFalse(model.queue.isEmpty)
        model.clear()
        XCTAssertTrue(model.queue.isEmpty, "toggle-off empties the review queue")
        XCTAssertNil(model.selectedID)
    }

    // MARK: - Model with no backend never crashes (defensive)

    func testEditsWithoutBackendDoNotCrash() {
        let c = candidate(score: 1.0)
        let model = ReviewFinishModel(backend: nil, fileExists: { _ in true })
        model.sync([c])
        XCTAssertTrue(model.approve(id: c.id), "local edit still updates the queue")
        XCTAssertEqual(model.queue.first?.state, .approved)
    }

    // MARK: - End-to-end over the LIVE AppEngine backend

    /// The real capture path produces a candidate; the review model, backed by the
    /// live engine, approves it — the engine's `@Published highlightCandidates`
    /// reflects the approval and the sidecar persists it (single source of truth).
    func testEngineBackendApprovalReflectsInPublishedAndSidecar() async throws {
        typealias SpySaver = DirectorsCutSlice2Tests.SpySaver
        typealias SpyReframer = DirectorsCutSlice2Tests.SpyReframer

        let engine = AppEngine()
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let spy = SpySaver()
        engine._test_highlightSaverOverride = spy
        engine._test_verticalReframerOverride = SpyReframer()
        engine._test_directorsCutDirectoryOverride = dir
        engine.setDirectorsCutEnabled(true)
        engine.setDirectorsCutRoll(preRoll: 5, postRoll: 0.2)

        let saved = expectation(description: "candidate saved")
        spy.onCall = { saved.fulfill() }
        engine.feedTransientToDirector(TransientInfo(hostSeconds: 300, strength: 1.0,
                                                     pts: CMTime(seconds: 300, preferredTimescale: 600)))
        await fulfillment(of: [saved], timeout: 5)
        for _ in 0..<5 { await Task.yield() }

        let model = ReviewFinishModel(backend: engine, fileExists: { _ in true })
        model.sync(engine.highlightCandidates)
        let id = try XCTUnwrap(model.queue.first?.id)
        XCTAssertEqual(model.queue.first?.state, .saved, "candidate is ready to review")

        XCTAssertTrue(model.approve(id: id))
        XCTAssertEqual(engine.highlightCandidates.first?.state, .approved,
                       "approval re-publishes through the engine (single source of truth)")

        // The engine persisted the approval to its per-session sidecar.
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".prism-highlights-") && $0.hasSuffix(".json") }
        let loaded = try HighlightCandidateStore.load(from: dir.appendingPathComponent(files[0]))
        XCTAssertEqual(loaded.candidates.first?.state, .approved, "approval persisted via engine backend")
        await engine.shutdown()
    }
}
