import CoreVideo
import Foundation
import os
import PrismCore
@testable import PrismSources
import XCTest

final class TimedVideoLifecycleRegressionTests: XCTestCase {
    /// Regression for F2: CharacterSource used to emit from `willStart()` while
    /// the base was still `.starting`. Stopping in that first callback set the
    /// source idle, but the outer start then unconditionally resurrected it as
    /// `.running` and produced further frames.
    func testCharacterStopFromFirstCallbackDoesNotResurrectRun() throws {
        let source = try CharacterSource(
            id: SourceID("regression.timed.character-stop-from-first-frame"),
            canvasSize: CanvasSize(width: 96, height: 96),
            fps: 120
        )
        defer { source.stop() }

        let callbackCount = OSAllocatedUnfairLock(initialState: 0)
        source.onFrame = { [weak source] _ in
            let isFirst = callbackCount.withLock { count in
                count += 1
                return count == 1
            }
            if isFirst { source?.stop() }
        }

        try source.start()

        XCTAssertEqual(source.state.rawValue, SourceState.idle.rawValue,
                       "a stop from the eager callback must survive the outer start()")
        XCTAssertEqual(callbackCount.withLock { $0 }, 1)

        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(source.state.rawValue, SourceState.idle.rawValue)
        XCTAssertEqual(callbackCount.withLock { $0 }, 1,
                       "the stopped generation must not launch or emit timer ticks")
    }

    /// An external stop must wait out an in-flight render. Once the render is
    /// released, its old-generation emit is rejected before the drain returns.
    /// The pre-fix implementation returned from stop immediately and delivered
    /// this frame afterward.
    func testExternalStopDrainsInFlightTickAndSuppressesItsEmit() throws {
        let source = try BlockingTimedSource()
        defer {
            source.releaseRender.signal()
            source.stop()
        }

        let callbackCount = OSAllocatedUnfairLock(initialState: 0)
        source.onFrame = { _ in callbackCount.withLock { $0 += 1 } }
        try source.start()

        XCTAssertEqual(source.renderEntered.wait(timeout: .now() + 1), .success,
                       "the timer tick never entered its controlled render")

        let stopReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            source.stop()
            stopReturned.signal()
        }

        // Wait until stop has made its lifecycle transition. In the fixed code
        // it remains `.stopping` while blocked in the queue drain; the old code
        // races straight through to `.idle` and returns.
        let transitionDeadline = Date().addingTimeInterval(1)
        while source.state.rawValue == SourceState.running.rawValue,
              Date() < transitionDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertNotEqual(source.state.rawValue, SourceState.running.rawValue)
        XCTAssertEqual(stopReturned.wait(timeout: .now() + 0.05), .timedOut,
                       "external stop returned without draining the blocked tick")

        source.releaseRender.signal()
        XCTAssertEqual(stopReturned.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(source.state.rawValue, SourceState.idle.rawValue)
        XCTAssertEqual(callbackCount.withLock { $0 }, 0,
                       "the render completed after stop began and must not emit")
    }

    /// Reproduction for the Browser run-1→run-2 leak: a deferred async completion
    /// (BrowserSource's WebKit snapshot hops back onto the source queue AFTER the
    /// requesting `tick()` returned) calls `emit` with NO captured run token. The
    /// pre-fix `emit` substituted the CURRENT generation as a fallback, so a
    /// completion that lands during a later run was accepted and old-page pixels
    /// surfaced in run 2. A tokenless deferred emit must be DROPPED.
    func testDeferredEmitWithoutRunTokenIsDropped() throws {
        let source = try DeferredEmitSource()
        try source.start()          // run 1
        source.stop()               // run 1 ends

        let run2Count = OSAllocatedUnfairLock(initialState: 0)
        source.onFrame = { _ in run2Count.withLock { $0 += 1 } }
        try source.start()          // run 2 (fresh generation)
        defer { source.stop() }

        // Simulate the late snapshot completion landing during run 2, exactly as
        // BrowserSource.finish does: `queue.async { self.emit(buffer) }`.
        source.fireLegacyDeferredEmit()
        source.queue.sync {}        // drain the deferred block

        XCTAssertEqual(run2Count.withLock { $0 }, 0,
            "a deferred emit carrying no run token must be dropped, never adopt the current run")
    }

    /// The fixed BrowserSource captures the run token when the snapshot is
    /// REQUESTED and emits through `emitDeferred(_:capturedToken:)`. A token from
    /// run 1 completing in run 2 is dropped; a token captured in run 2 completing
    /// in run 2 is delivered.
    func testCapturedTokenGatesDeferredEmitAcrossRuns() throws {
        let source = try TokenSnapshotSource()
        try source.start()          // run 1
        source.captureTokenNow()    // as if a snapshot was requested in run 1
        source.stop()

        let count = OSAllocatedUnfairLock(initialState: 0)
        source.onFrame = { _ in count.withLock { $0 += 1 } }
        try source.start()          // run 2
        defer { source.stop() }

        // Run-1 token completing in run 2 → dropped.
        source.fireDeferredWithCapturedToken()
        source.queue.sync {}
        XCTAssertEqual(count.withLock { $0 }, 0,
            "a snapshot requested in run 1 must not surface in run 2")

        // Run-2 token captured and completing in run 2 → delivered.
        source.captureTokenNow()
        source.fireDeferredWithCapturedToken()
        source.queue.sync {}
        XCTAssertEqual(count.withLock { $0 }, 1,
            "a snapshot requested and completed within run 2 must be delivered")
    }
}

/// Mimics BrowserSource's pre-fix deferred completion: a plain `emit` hopped onto
/// the source queue after the requesting tick returned (no run token).
private final class DeferredEmitSource: TimedVideoSource, @unchecked Sendable {
    private let buffer: CVPixelBuffer
    init() throws {
        let pool = try PixelBufferPool(width: 16, height: 16, minimumBufferCount: 1)
        self.buffer = try pool.makeBuffer()
        super.init(id: SourceID("regression.timed.deferred-emit"),
                   fps: 1, label: "studio.prism.test.deferred-emit")
    }
    override func tick() {}   // no auto-emit; the test drives the deferred path
    func fireLegacyDeferredEmit() {
        queue.async { [weak self] in guard let self else { return }; self.emit(self.buffer) }
    }
}

/// Mimics the FIXED BrowserSource: captures the run token at request time and
/// emits through the token-gated `emitDeferred`.
private final class TokenSnapshotSource: TimedVideoSource, @unchecked Sendable {
    private let buffer: CVPixelBuffer
    private let captured = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    init() throws {
        let pool = try PixelBufferPool(width: 16, height: 16, minimumBufferCount: 1)
        self.buffer = try pool.makeBuffer()
        super.init(id: SourceID("regression.timed.token-snapshot"),
                   fps: 1, label: "studio.prism.test.token-snapshot")
    }
    override func tick() {}
    /// Capture the current run token on the source queue (as tick()/request does).
    func captureTokenNow() {
        queue.sync { self.captured.withLock { $0 = self.currentRunToken } }
    }
    func fireDeferredWithCapturedToken() {
        let token = captured.withLock { $0 }
        queue.async { [weak self] in
            guard let self else { return }
            self.emitDeferred(self.buffer, capturedToken: token)
        }
    }
}

private final class BlockingTimedSource: TimedVideoSource, @unchecked Sendable {
    let renderEntered = DispatchSemaphore(value: 0)
    let releaseRender = DispatchSemaphore(value: 0)
    private let buffer: CVPixelBuffer

    init() throws {
        let pool = try PixelBufferPool(width: 16, height: 16, minimumBufferCount: 1)
        self.buffer = try pool.makeBuffer()
        super.init(id: SourceID("regression.timed.blocked-render"),
                   fps: 120,
                   label: "studio.prism.test.timed-blocked-render")
    }

    override func tick() {
        renderEntered.signal()
        releaseRender.wait()
        emit(buffer)
    }
}
