import CoreMedia
import CoreVideo
import XCTest
import PrismCore
import PrismSources

/// F12 regression: `PresenterCutoutSource` live options must be SNAPSHOTTED per
/// dequeued frame and applied only on the serial worker, so a control-thread
/// quality/background/feather/no-person edit can never tear the multi-field
/// `Options` read the engine performs across segmentation + compositing.
///
/// The pre-fix code let the public setter write `engine.options` directly while
/// the worker read that same live struct (unlocked) mid-cutout — a data race
/// that could apply a MIX of two edits to one frame. The fix keeps options
/// wrapper-owned under the lock, snapshots them with the frame, and applies that
/// immutable snapshot to the engine on the worker before the cutout.
final class PresenterCutoutOptionsRaceTests: XCTestCase {

    private func qcode(_ q: PresenterCutout.Quality) -> Int {
        switch q { case .fast: return 0; case .balanced: return 1; case .accurate: return 2 }
    }
    private func same(_ a: PresenterCutout.Options, _ b: PresenterCutout.Options) -> Bool {
        qcode(a.quality) == qcode(b.quality) && a.feather == b.feather
            && a.background == b.background && a.noPerson == b.noPerson
    }

    // MARK: - Deterministic: a mid-flight edit must NOT reach the in-flight frame

    /// Drives one frame through the worker and, via a test hook, mutates
    /// `options` from a control thread AFTER the frame has been dequeued (the
    /// exact race window). The options the engine actually used for that frame
    /// must equal the value current when the frame was dequeued — the SNAPSHOT —
    /// not the later mutation. On the pre-fix code the live read picked up the
    /// mutation, so this fails.
    func testMidFlightEditDoesNotAffectInFlightFrame() throws {
        let A = PresenterCutout.Options(quality: .fast, background: .transparent,
                                        feather: 0, noPerson: .transparent)
        let B = PresenterCutout.Options(quality: .accurate,
                                        background: .solidColor(RGBAColor(r: 1, g: 0, b: 1)),
                                        feather: 32, noPerson: .passThrough)

        let upstream = RaceUpstream()
        let source = PresenterCutoutSource(wrapping: upstream, options: A)

        let usedBox = OptionsBox()
        let processed = expectation(description: "one frame processed")
        // After the snapshot is taken + applied, slam a wholly different edit in
        // from a background thread — modelling a concurrent control-thread change.
        source._test_beforeCutout = { _ in
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { source.options = B; done.signal() }
            done.wait()   // ensure the edit has fully landed before the cutout runs
        }
        source._test_optionsUsed = { opts in
            usedBox.set(opts)
            processed.fulfill()
        }

        try source.start()
        let frame = try PresenterCutoutSelfTest.makeBGRAFrame(width: 96, height: 72, id: "race") { _, _ in
            (r: 128, g: 128, b: 128)   // flat → Vision finds no person → no-person path
        }
        upstream.onFrame?(frame)

        wait(for: [processed], timeout: 10)
        source.stop()

        let used = try XCTUnwrap(usedBox.get())
        XCTAssertTrue(same(used, A),
            "in-flight frame must use the SNAPSHOT (A), not the concurrent edit (B): "
            + "used quality=\(qcode(used.quality)) feather=\(used.feather) bg=\(used.background) noPerson=\(used.noPerson)")
        // And the live options reflect the edit for the NEXT frame.
        XCTAssertTrue(same(source.options, B), "live options should now be the edited value B")
    }

    // MARK: - Stress: every processed frame sees a COHERENT whole-options value

    /// Hammer whole-options edits from a control thread while the worker processes
    /// a stream of frames. Each edit is internally COHERENT — every field is a
    /// deterministic function of an integer id carried in `feather`. If any frame
    /// ever observed a torn read, its recorded options would combine fields from
    /// two different ids and fail the coherence check. With snapshot-per-frame it
    /// never can.
    func testHammerEditsNeverTear() throws {
        func opts(id: Int) -> PresenterCutout.Options {
            PresenterCutout.Options(
                quality: [PresenterCutout.Quality.fast, .balanced, .accurate][id % 3],
                background: id % 2 == 0 ? .transparent
                    : .solidColor(RGBAColor(r: Double(id % 5) / 4.0, g: 0, b: 1)),
                feather: Float(id),
                noPerson: id % 2 == 0 ? .transparent : .passThrough)
        }
        func isCoherent(_ o: PresenterCutout.Options) -> Bool { same(o, opts(id: Int(o.feather))) }

        let upstream = RaceUpstream()
        let source = PresenterCutoutSource(wrapping: upstream, options: opts(id: 0))

        let torn = TornFlag()
        let count = Counter()
        source._test_optionsUsed = { o in
            if !isCoherent(o) { torn.trip() }
            count.bump()
        }

        try source.start()
        let frame = try PresenterCutoutSelfTest.makeBGRAFrame(width: 64, height: 48, id: "hammer") { _, _ in
            (r: 100, g: 110, b: 120)
        }

        let editing = TornFlag()   // reuse as a "keep going" flag (starts un-tripped)
        let editor = Thread {
            var i = 1
            while !editing.tripped {
                source.options = opts(id: i)
                i += 1
            }
        }
        editor.start()

        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline && count.value < 20 {
            upstream.onFrame?(frame)
            usleep(500)
        }
        editing.trip()   // stop the editor
        Thread.sleep(forTimeInterval: 0.1)
        source.stop()

        XCTAssertGreaterThan(count.value, 0, "sanity: some frames were processed")
        XCTAssertFalse(torn.tripped, "a torn/mixed options read reached the engine")
    }
}

// MARK: - Test doubles

/// Upstream whose `onFrame` is taken over by `PresenterCutoutSource`; the test
/// pushes frames by invoking it directly.
private final class RaceUpstream: VideoSource, @unchecked Sendable {
    let id = SourceID("test.race.upstream")
    var onFrame: ((VideoFrame) -> Void)?
    private let lock = NSLock()
    private var _state: SourceState = .idle
    var state: SourceState { lock.lock(); defer { lock.unlock() }; return _state }
    func start() throws { lock.lock(); _state = .running; lock.unlock() }
    func stop() { lock.lock(); _state = .idle; lock.unlock() }
}

private final class OptionsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: PresenterCutout.Options?
    func set(_ o: PresenterCutout.Options) { lock.lock(); v = o; lock.unlock() }
    func get() -> PresenterCutout.Options? { lock.lock(); defer { lock.unlock() }; return v }
}

private final class TornFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _t = false
    var tripped: Bool { lock.lock(); defer { lock.unlock() }; return _t }
    func trip() { lock.lock(); _t = true; lock.unlock() }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
