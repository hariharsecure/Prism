import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest

import PrismCore
import PrismSources
@testable import Prism

/// 2a — TRANSACTIONAL RECONFIGURATION (prepare / commit / rollback).
///
/// BUG: `reconfigureMontage` (and the raw movie-loop reconfigure branch) STOPPED
/// the predecessor source BEFORE building its replacement, then `try`-started the
/// replacement. If the replacement's first asset is missing/corrupt its eager
/// first-frame load throws at `start()`, and the `catch` only set `lastError` — so
/// the already-stopped predecessor was left STRANDED (frames stopped, no
/// recovery), while `activeSources` still pointed at it.
///
/// FIX: build + validate (start) the replacement FIRST, via the reusable
/// `reconfigureTransactionally(prepare:commit:rollback:)` primitive. The
/// predecessor is stopped and swapped out ONLY once the replacement is confirmed
/// good; on failure the predecessor keeps running and only `lastError` is set — it
/// is never stranded.
@MainActor
final class TransactionalMontageReconfigTests: XCTestCase {

    /// A solid-color PNG the montage can load as an image item (no video decode,
    /// so the source starts headless without a real capture device).
    private func writePNG(w: Int = 32, h: Int = 32) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("montage.\(UUID().uuidString).png")
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw XCTSkip("no CGContext")
        }
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw XCTSkip("no PNG encoder")
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("PNG write failed") }
        return url
    }

    private func pollUntil(_ seconds: TimeInterval, _ cond: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if cond() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if !cond() { throw XCTSkip("precondition not met in \(seconds)s") }
    }

    private struct Outcome {
        let predecessorSurvived: Bool   // the SAME backing object is still registered
        let predecessorRunning: Bool    // …and still running (not stranded)
        let error: Bool                 // lastError surfaced
    }

    /// Add a montage, then reconfigure it under the given seams; report whether the
    /// predecessor survived (same identity) and is still running.
    private func runReconfigure(forceFailure: Bool, stopPredecessorFirst: Bool) async throws -> Outcome {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let png = try writePNG()
        defer { try? FileManager.default.removeItem(at: png) }

        let engine = AppEngine()
        guard engine.renderLoop != nil else { await engine.shutdown(); throw XCTSkip("no render loop") }

        engine.addMontageSource(fileURLs: [png], interval: 1.0)
        try await pollUntil(2.0) { !engine.integrationDebugMontageSourceIDs.isEmpty }
        let id = try XCTUnwrap(engine.integrationDebugMontageSourceIDs.first)
        try await pollUntil(2.0) { engine.integrationDebugGeneratedBacking(for: id)?.state == .running }

        let predecessor = try XCTUnwrap(engine.integrationDebugGeneratedBacking(for: id))
        engine.lastError = nil

        AppEngine._test_forceReconfigFailure = forceFailure
        AppEngine._test_reconfigStopPredecessorFirst = stopPredecessorFirst
        defer {
            AppEngine._test_forceReconfigFailure = false
            AppEngine._test_reconfigStopPredecessorFirst = false
        }
        engine.reconfigureMontage(for: id, interval: 3.5)   // a new value distinct from the original

        let after = engine.integrationDebugGeneratedBacking(for: id)
        let survived = after != nil && after === predecessor
        let running = after?.state == .running
        let hadError = engine.lastError != nil
        await engine.shutdown()
        return Outcome(predecessorSurvived: survived, predecessorRunning: running, error: hadError)
    }

    /// FIX: a failing reconfigure leaves the predecessor running (never stranded).
    func testFailedReconfigKeepsPredecessorRunning() async throws {
        let fixed = try await runReconfigure(forceFailure: true, stopPredecessorFirst: false)
        XCTAssertTrue(fixed.predecessorSurvived,
                      "2a: a failed reconfigure swapped/dropped the predecessor instead of keeping it")
        XCTAssertTrue(fixed.predecessorRunning,
                      "2a: a failed reconfigure stranded the predecessor (stopped, no recovery)")
        XCTAssertTrue(fixed.error, "2a: the reconfigure failure must still surface lastError")
    }

    /// NEGATIVE CONTROL: the pre-fix ordering (stop predecessor, THEN build) strands
    /// the predecessor when the replacement fails.
    func testPreFixOrderingStrandsPredecessor() async throws {
        let neg = try await runReconfigure(forceFailure: true, stopPredecessorFirst: true)
        XCTAssertFalse(neg.predecessorRunning,
                       "negative control vacuous: the pre-fix stop-first ordering left the predecessor running")
        XCTAssertTrue(neg.error, "the failure must surface lastError in the pre-fix path too")
    }

    /// POSITIVE CONTROL: a valid reconfigure still swaps the source correctly.
    func testValidReconfigSwapsSource() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let png = try writePNG()
        defer { try? FileManager.default.removeItem(at: png) }

        let engine = AppEngine()
        guard engine.renderLoop != nil else { await engine.shutdown(); throw XCTSkip("no render loop") }

        engine.addMontageSource(fileURLs: [png], interval: 1.0)
        try await pollUntil(2.0) { !engine.integrationDebugMontageSourceIDs.isEmpty }
        let id = try XCTUnwrap(engine.integrationDebugMontageSourceIDs.first)
        try await pollUntil(2.0) { engine.integrationDebugGeneratedBacking(for: id)?.state == .running }
        let predecessor = try XCTUnwrap(engine.integrationDebugGeneratedBacking(for: id))

        engine.reconfigureMontage(for: id, interval: 3.5)

        let after = try XCTUnwrap(engine.integrationDebugGeneratedBacking(for: id))
        XCTAssertFalse(after === predecessor, "2a positive control: a valid reconfigure must swap in a fresh source")
        XCTAssertEqual(after.state, .running, "2a positive control: the swapped-in source must be running")
        XCTAssertEqual(engine.montageInterval(for: id), 3.5, accuracy: 0.001,
                       "2a positive control: the new interval must take effect")
        XCTAssertNil(engine.lastError, "2a positive control: a valid reconfigure must not set lastError")
        await engine.shutdown()
    }
}
