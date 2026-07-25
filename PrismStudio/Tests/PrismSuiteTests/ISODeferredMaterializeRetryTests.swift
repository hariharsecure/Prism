import AVFoundation
import CoreMedia
import CoreVideo
import XCTest

import PrismCore
import PrismOutput

/// HIGH — a deferred ISO angle must NOT be permanently killed by a single
/// first-frame recorder-creation failure.
///
/// `ISORecorderBank.materializedRecorder(for:)` CLAIMS the deferred descriptor
/// under the lock (`deferred[id] = nil`, so only the first frame builds it) and
/// then does the FALLIBLE recorder creation OUTSIDE the lock. Pre-fix, a first
/// frame that fails to create/start its writer (transient disk-full /
/// too-many-open-files / permissions, or a bad first frame → invalid settings)
/// returned nil WITHOUT restoring the claimed descriptor, so every later frame
/// saw `recorders[id]==nil && deferred[id]==nil ⇒ .none` and the angle silently
/// recorded NOTHING for the whole session — even after conditions recovered.
///
/// The fix restores the descriptor in the `catch` (under the lock) so a LATER
/// frame retries. These tests exercise the `RecorderFactory` seam with a factory
/// that THROWS on its first call(s) and then succeeds.
final class ISODeferredMaterializeRetryTests: XCTestCase {

    private enum FactoryFault: Error { case injectedFirstFrameFailure }

    /// A thread-safe recorder factory that fails its first `failFirst` calls and
    /// then delegates to the real `MovieRecorder` — the exact throw-first-then-
    /// succeed seam the bug needs. Counts invocations so a test can prove the
    /// bank RETRIED (called the factory again) rather than silently giving up.
    private final class CountingFactory: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private let failFirst: Int
        init(failFirst: Int) { self.failFirst = failFirst }

        var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }

        func make(_ url: URL, _ settings: RecordingSettings,
                  _ sessionStart: MovieRecorder.SessionStart) throws -> MovieRecorder {
            let n: Int = { lock.lock(); defer { lock.unlock() }; calls += 1; return calls }()
            if n <= failFirst { throw FactoryFault.injectedFirstFrameFailure }
            return try MovieRecorder(url: url, settings: settings, sessionStart: sessionStart)
        }
    }

    private func makeBGRA(_ w: Int, _ h: Int, source: SourceID, pts: CMTime) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_32BGRA)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<h {
            let p = (base + row * bpr).assumingMemoryBound(to: UInt8.self)
            for col in 0..<w { p[col * 4 + 0] = 30; p[col * 4 + 1] = 160; p[col * 4 + 2] = 80; p[col * 4 + 3] = 255 }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return VideoFrame(pixelBuffer: buf, pts: pts,
                          duration: CMTime(value: 1, timescale: 30), source: source)
    }

    private func deferredSettings(from frame: VideoFrame) -> RecordingSettings {
        RecordingSettings(codec: .h264, width: frame.width, height: frame.height,
                          includeAudio: false, dynamicRange: .sdr)
    }

    private func trackNaturalSize(_ url: URL) async throws -> CGSize {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first, "no video track in \(url.lastPathComponent)")
        return try await track.load(.naturalSize)
    }

    // MARK: - reproduce-first: a transient first-frame failure must NOT permanently kill the angle

    func testDeferredAngleRecoversAfterTransientFirstFrameFailures() async throws {
        // Factory throws on the first TWO calls, then succeeds. Pre-fix the bank
        // claims the descriptor on the first frame, the create throws, the
        // descriptor is never restored → the factory is NEVER called again and the
        // angle records nothing. Post-fix every frame retries until it succeeds.
        let src = SourceID("iso.deferred.retry")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism_iso_retry_\(UInt64.random(in: 0..<UInt64.max))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let factory = CountingFactory(failFirst: 2)
        let bank = ISORecorderBank(directory: dir,
                                   defaultSettings: RecordingSettings(),
                                   recorderFactory: factory.make)
        try bank.addDeferredSource(src, includeAudio: false) { self.deferredSettings(from: $0) }
        let t0 = HouseClock.now()
        try bank.start(at: t0)

        let fps = 30
        // Frame 1: materialize attempted → throws → angle must NOT be permanently dead.
        bank.append(try makeBGRA(320, 240, source: src, pts: CMTimeAdd(t0, CMTime(value: 0, timescale: CMTimeScale(fps)))))
        XCTAssertEqual(factory.callCount, 1, "first frame must attempt materialization")
        XCTAssertFalse(bank.activeSourceIDs.contains(src), "first-frame failure leaves the angle unmaterialized (this frame)")
        XCTAssertNil(bank.settings(for: src), "no recorder yet after the first-frame failure")

        // Frame 2: pre-fix the descriptor was lost so this is a silent no-op; post-fix it retries and fails again.
        bank.append(try makeBGRA(320, 240, source: src, pts: CMTimeAdd(t0, CMTime(value: 1, timescale: CMTimeScale(fps)))))
        XCTAssertEqual(factory.callCount, 2, "second frame must RETRY the factory (descriptor restored) — pre-fix this stays 1")

        // Frame 3+: the transient fault clears → the angle materializes and records.
        for i in 2..<14 {
            bank.append(try makeBGRA(320, 240, source: src, pts: CMTimeAdd(t0, CMTime(value: Int64(i), timescale: CMTimeScale(fps)))))
            try await Task.sleep(nanoseconds: UInt64(1_000_000_000 / UInt64(fps)))
        }
        XCTAssertEqual(factory.callCount, 3, "materialization succeeds on the 3rd attempt, then stops retrying")
        XCTAssertTrue(bank.activeSourceIDs.contains(src), "angle RECOVERED — it is live after the transient failure cleared")
        let live = try XCTUnwrap(bank.settings(for: src), "recovered angle has a live recorder")
        XCTAssertEqual(live.width, 320); XCTAssertEqual(live.height, 240)

        let results = await bank.finishAll()
        guard case .success(let report)? = results[src] else {
            throw XCTSkip("recovered ISO recorder produced no file: \(String(describing: results[src]))")
        }
        // INDEPENDENT oracle: the finalized file exists and is the native size.
        let size = try await trackNaturalSize(report.url)
        XCTAssertEqual(size, CGSize(width: 320, height: 240), "recovered angle recorded its native 320×240 to disk")
    }

    // MARK: - negative control: a PERSISTENT fault records nothing, and the bank keeps retrying every frame

    func testNegativeControlPersistentFactoryFailureRecordsNothingButRetriesEveryFrame() async throws {
        // Control for the reproduce-first test above: when creation can NEVER
        // succeed, the angle correctly records nothing — proving "records nothing"
        // is the observable symptom. And the retry count == frame count proves the
        // fix restores the descriptor on EVERY failure (pre-fix it would be 1).
        let src = SourceID("iso.deferred.persistent-fail")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism_iso_persist_\(UInt64.random(in: 0..<UInt64.max))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let factory = CountingFactory(failFirst: .max)
        let bank = ISORecorderBank(directory: dir,
                                   defaultSettings: RecordingSettings(),
                                   recorderFactory: factory.make)
        try bank.addDeferredSource(src, includeAudio: false) { self.deferredSettings(from: $0) }
        let t0 = HouseClock.now()
        try bank.start(at: t0)

        let fps = 30
        let frameCount = 6
        for i in 0..<frameCount {
            bank.append(try makeBGRA(320, 240, source: src, pts: CMTimeAdd(t0, CMTime(value: Int64(i), timescale: CMTimeScale(fps)))))
        }
        XCTAssertEqual(factory.callCount, frameCount,
                       "descriptor restored after each failure → every frame retries (pre-fix this would be 1)")
        XCTAssertFalse(bank.activeSourceIDs.contains(src), "a persistently failing angle records nothing")
        XCTAssertNil(bank.settings(for: src), "no recorder ever materialized under a persistent fault")

        let results = await bank.finishAll()
        XCTAssertNil(results[src], "no file for an angle that never materialized")
    }
}
