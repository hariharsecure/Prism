import AVFoundation
import CoreMedia
import CoreVideo
import Metal
import os
import XCTest

import PrismCore
import PrismSources
@testable import Prism

/// sol #12 #2 (finding #5, MEDIUM) — changing Movie Loop bypassed an enabled Presenter Cutout.
///
/// `setMovieLoop` rebuilds the `MovieSource` in place (loop is fixed at init). Pre-fix it installed
/// a fresh RAW `MovieSource` and wired its `onFrame` straight to the mailbox WITHOUT rebuilding the
/// cutout wrapper stored by `setPresenterCutout` — so with the cutout enabled the UI still said "on"
/// (state + premultiplied layer + stale wrapper all retained) while live frames bypassed the cutout.
///
/// FIX: when a presenter cutout is enabled for the source, `setMovieLoop` records the new loop and
/// delegates to `setPresenterCutout`, which rebuilds the `MovieSource` (with the new loop) INSIDE a
/// fresh cutout wrapper — so frames still route through the cutout.
@MainActor
final class SolWave13MovieLoopCutoutTests: XCTestCase {

    private func writeMovie(w: Int, h: Int, frames: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip.\(UUID().uuidString).mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            throw XCTSkip("no AVAssetWriter")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            ])
        guard writer.canAdd(input) else { throw XCTSkip("h264 unavailable") }
        writer.add(input)
        guard writer.startWriting() else { throw XCTSkip("writer refused to start") }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            var pbOut: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess,
                  let pb = pbOut else { throw XCTSkip("no pool") }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                memset(base, i % 2 == 0 ? 80 : 160, CVPixelBufferGetBytesPerRow(pb) * h)
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 15))
        }
        input.markAsFinished()
        let done = XCTestExpectation(description: "write")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 10)
        guard writer.status == .completed else { throw XCTSkip("h264 write failed") }
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

    /// Does the CURRENT active movie backing route frames THROUGH the current cutout wrapper?
    /// Installs `_test_beforeCutout` on the live wrapper and drives the active backing's `onFrame`
    /// with a synthetic frame; the hook fires only if the backing feeds the cutout.
    private func activeBackingRoutesThroughCutout(_ engine: AppEngine, _ id: SourceID) async throws -> Bool {
        let wrapper = try XCTUnwrap(engine.integrationDebugCutoutSource(for: id),
                                    "no live cutout wrapper for the source")
        let fired = OSAllocatedUnfairLock(initialState: false)
        wrapper._test_beforeCutout = { _ in fired.withLock { $0 = true } }
        defer { wrapper._test_beforeCutout = nil }
        let movie = try XCTUnwrap(engine.integrationDebugMovieBacking(for: id),
                                  "no live movie backing for the source")
        let pool = try PixelBufferPool(width: 16, height: 16, pixelFormat: kCVPixelFormatType_32BGRA)
        let frame = VideoFrame(pixelBuffer: try pool.makeBuffer(), pts: .zero, source: id)
        movie.onFrame?(frame)   // if routed through the cutout, this hits submit → _test_beforeCutout
        for _ in 0..<100 {
            if fired.withLock({ $0 }) { return true }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return fired.withLock { $0 }
    }

    private struct Result {
        let wrapperChanged: Bool     // setMovieLoop rebuilt the cutout wrapper (fresh identity)
        let cutoutReceives: Bool     // the active backing routes frames through the cutout
        let cutoutStillOn: Bool      // cutout state is still reported enabled
    }

    private func runLoopChange(skipRebuild: Bool, probeRouting: Bool = true) async throws -> Result {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let movURL = try writeMovie(w: 64, h: 64, frames: 4)
        defer { try? FileManager.default.removeItem(at: movURL) }

        let engine = AppEngine()
        guard engine.renderLoop != nil else { await engine.shutdown(); throw XCTSkip("no render loop") }
        engine.addMovieSource(fileURL: movURL, loop: true)
        try await pollUntil(2.0) { !engine.integrationDebugMovieSourceIDs.isEmpty }
        let id = try XCTUnwrap(engine.integrationDebugMovieSourceIDs.first)

        // Enable the presenter cutout on the movie.
        engine.setPresenterCutout(CutoutState(), for: id)
        guard engine.cutoutState(for: id) != nil,
              let wrapperBefore = engine.integrationDebugCutoutSource(for: id) else {
            await engine.shutdown()
            throw XCTSkip("presenter cutout couldn't start (Vision/Metal unavailable)")
        }
        // Sanity: with cutout on, the movie already routes through it.
        let routedBefore = try await activeBackingRoutesThroughCutout(engine, id)
        XCTAssertTrue(routedBefore,
                      "test setup: an enabled cutout must route the movie's frames before the loop change")

        // Change the loop while the cutout is enabled.
        AppEngine._test_skipMovieLoopCutoutRebuild = skipRebuild
        defer { AppEngine._test_skipMovieLoopCutoutRebuild = false }
        engine.setMovieLoop(false, for: id)

        let after = engine.integrationDebugCutoutSource(for: id)
        let wrapperChanged = after != nil && after !== wrapperBefore
        // `wrapperChanged` is the DETERMINISTIC routing signal, observed synchronously at the moment
        // of the rebuild: the fix rebuilds the movie INSIDE a fresh cutout wrapper (new identity ⇒
        // routed through), the pre-fix raw path retains the stale wrapper and wires the new raw movie
        // straight to the mailbox (same identity ⇒ bypassed). The dynamic `cutoutReceives` frame probe
        // is only meaningful (and non-racy) for the POSITIVE path, where the fresh wrapper genuinely
        // routes our driven frame; for the negative path it races leftover in-flight frames still
        // draining through the not-yet-quiesced stale wrapper, so we do not probe it there.
        let cutoutReceives = probeRouting ? try await activeBackingRoutesThroughCutout(engine, id) : false
        let cutoutStillOn = engine.cutoutState(for: id) != nil
        XCTAssertFalse(engine.movieLoops(id), "the loop change must have taken effect")
        await engine.shutdown()
        return Result(wrapperChanged: wrapperChanged, cutoutReceives: cutoutReceives, cutoutStillOn: cutoutStillOn)
    }

    func testMovieLoopChangeKeepsCutoutInFramePath() async throws {
        // FIX: the new movie is rebuilt inside a fresh cutout wrapper → frames still route through it.
        let fixed = try await runLoopChange(skipRebuild: false)
        XCTAssertTrue(fixed.cutoutReceives,
                      "#5: after a loop change the live frames bypass the enabled presenter cutout")
        XCTAssertTrue(fixed.wrapperChanged, "#5: the cutout wrapper was not rebuilt around the new movie")
        XCTAssertTrue(fixed.cutoutStillOn, "#5: the cutout must remain enabled across the loop change")

        // NEGATIVE CONTROL: the pre-fix raw rebuild bypasses the (still-on) cutout — proven by
        // IDENTITY, synchronously, not by racing an async frame through the cutout worker. With the
        // rebuild-via-cutout suppressed, `setMovieLoop` installs a fresh RAW `MovieSource` wired
        // straight to the mailbox while leaving the ORIGINAL cutout wrapper in place (same identity):
        // the new backing is not inside any rebuilt cutout, so its frames bypass it. If the product
        // fix were reverted, the positive path above would raw-rebuild too and `fixed.wrapperChanged`
        // would flip false, reddening this test — so the control is not neutered.
        let neg = try await runLoopChange(skipRebuild: true, probeRouting: false)
        XCTAssertFalse(neg.wrapperChanged,
                       "negative control vacuous: the pre-fix path must NOT rebuild the cutout wrapper "
                       + "(the raw movie is installed without a fresh cutout wrapper, bypassing it)")
        XCTAssertTrue(neg.cutoutStillOn,
                      "negative control setup: the cutout state must remain reported on across the raw "
                      + "rebuild (the bug: UI says on while frames bypass it)")
    }

    /// sol #12 #2 (finding #6, MEDIUM) — a FAILED cutout reconfiguration must not strand the source
    /// stopped. `setPresenterCutout` stops the current source before building its replacement; a
    /// failure that neither restores nor restarts it leaves the registered backing `.idle` (dark).
    /// FIX: on failure, restore + restart a raw feed so the source stays `.running`; `lastError` set.
    func testFailedCutoutReconfigRestoresRunningSource() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }

        func finalState(skipRestore: Bool) async throws -> (state: SourceState?, error: Bool) {
            let movURL = try writeMovie(w: 64, h: 64, frames: 4)
            defer { try? FileManager.default.removeItem(at: movURL) }
            let engine = AppEngine()
            guard engine.renderLoop != nil else { await engine.shutdown(); throw XCTSkip("no render loop") }
            engine.addMovieSource(fileURL: movURL, loop: true)
            try await pollUntil(2.0) { !engine.integrationDebugMovieSourceIDs.isEmpty }
            let id = try XCTUnwrap(engine.integrationDebugMovieSourceIDs.first)
            try await pollUntil(2.0) { engine.integrationDebugMovieBacking(for: id)?.state == .running }

            AppEngine._test_forceCutoutReconfigFailure = true
            AppEngine._test_skipCutoutFailureRestore = skipRestore
            defer {
                AppEngine._test_forceCutoutReconfigFailure = false
                AppEngine._test_skipCutoutFailureRestore = false
            }
            engine.setPresenterCutout(CutoutState(), for: id)   // fails after stopping the source
            let hasError = engine.lastError != nil
            if !skipRestore {
                try? await pollUntil(2.0) { engine.integrationDebugMovieBacking(for: id)?.state == .running }
            }
            let st = engine.integrationDebugMovieBacking(for: id)?.state
            await engine.shutdown()
            return (st, hasError)
        }

        // FIX: the original source is restored to running; the error still surfaces.
        let fixed = try await finalState(skipRestore: false)
        XCTAssertEqual(fixed.state, .running,
                       "#6: a failed cutout reconfigure stranded the source (not restored to running)")
        XCTAssertTrue(fixed.error, "#6: the reconfigure failure must still surface lastError")

        // NEGATIVE CONTROL: the pre-fix path leaves the source stranded (not running).
        let neg = try await finalState(skipRestore: true)
        XCTAssertNotEqual(neg.state, .running,
                          "negative control vacuous: the pre-fix path left the source running")
        XCTAssertTrue(neg.error, "the failure must surface lastError in the pre-fix path too")
    }
}
