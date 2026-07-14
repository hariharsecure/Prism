import AVFAudio
import XCTest

import PrismAudio
import PrismCore
import PrismSound

/// Deterministic verification of the `Soundboard` bounded-LRU decoded-buffer
/// cache (memory-safety insurance so a full `preloadAll()` can never pin
/// unbounded Float32 PCM).
///
/// The accounting tests use `register(id:buffer:)` with synthetic buffers of a
/// KNOWN byte size (frames × 2 ch × 4 B) so the byte budget, count, and exact
/// eviction order are all deterministic without any file I/O or engine. The
/// reload-on-miss test drives a real generated library through manual rendering
/// to prove an evicted sound re-decodes and plays (non-silent) on re-trigger.
final class SoundCacheTests: XCTestCase {

    private let framesPerBuf: AVAudioFrameCount = 1000
    /// 1000 frames × 2 channels × 4 bytes (Float32) = 8000 B per buffer.
    private var bytesPerBuf: Int { Int(framesPerBuf) * 2 * MemoryLayout<Float>.size }

    private func makeBuffer(fill: Float = 0.5) -> AVAudioPCMBuffer {
        let fmt = SamplePlaybackEngine.internalFormat // 48 kHz stereo float
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: framesPerBuf)!
        buf.frameLength = framesPerBuf
        if let ch = buf.floatChannelData {
            for c in 0..<Int(fmt.channelCount) { for i in 0..<Int(framesPerBuf) { ch[c][i] = fill } }
        }
        return buf
    }

    /// A Soundboard with no library (register-only) for pure accounting tests.
    private func makeBoard(budgetBytes: Int, countCap: Int = .max) throws -> Soundboard {
        let mixer = AudioMixer(configuration: AudioMixer.Configuration())
        return try Soundboard(mixer: mixer, library: nil, voiceCount: 4,
                              cacheBudgetBytes: budgetBytes, cacheCountCap: countCap)
    }

    // MARK: Byte budget bound + LRU eviction order

    func testByteBudgetEvictsOldestFirst() throws {
        let budget = 3 * bytesPerBuf            // holds exactly 3 buffers
        let board = try makeBoard(budgetBytes: budget)
        for i in 0..<6 { board.register(id: "id\(i)", buffer: makeBuffer()) }

        // Only the newest 3 stay resident; the oldest 3 are evicted.
        XCTAssertEqual(board.cachedCount, 3, "budget of 3 buffers → 3 resident")
        XCTAssertEqual(board.cachedBytes, 3 * bytesPerBuf, "resident bytes exactly at budget")
        XCTAssertLessThanOrEqual(board.cachedBytes, budget, "never exceeds budget")
        for i in 0..<3 { XCTAssertFalse(board.isCached(id: "id\(i)"), "id\(i) (LRU) evicted") }
        for i in 3..<6 { XCTAssertTrue(board.isCached(id: "id\(i)"), "id\(i) (recent) resident") }
        print("  [byte-budget] budget=\(budget)B resident=\(board.cachedBytes)B/\(board.cachedCount) evicted id0,id1,id2")
    }

    // MARK: A read (buffer(id:)) marks most-recently-used → survives eviction

    func testReadUpdatesRecency() throws {
        let board = try makeBoard(budgetBytes: 3 * bytesPerBuf) // holds 3
        for i in 0..<3 { board.register(id: "id\(i)", buffer: makeBuffer()) }
        XCTAssertEqual(board.cachedCount, 3)

        // Touch id0 (the current LRU) so it becomes most-recently-used.
        XCTAssertNotNil(board.buffer(id: "id0"), "id0 resident before touch")
        // Insert a 4th → one eviction. id1 is now the LRU (id0 was just touched).
        board.register(id: "id3", buffer: makeBuffer())

        XCTAssertEqual(board.cachedCount, 3, "still 3 under budget")
        XCTAssertFalse(board.isCached(id: "id1"), "id1 is now LRU → evicted")
        XCTAssertTrue(board.isCached(id: "id0"), "id0 survived because a read touched it")
        XCTAssertTrue(board.isCached(id: "id2"))
        XCTAssertTrue(board.isCached(id: "id3"))
        print("  [recency] touched id0 then inserted id3 → evicted id1 (not id0)")
    }

    // MARK: Lowering the budget evicts immediately

    func testLoweringBudgetEvicts() throws {
        let board = try makeBoard(budgetBytes: .max)
        for i in 0..<4 { board.register(id: "id\(i)", buffer: makeBuffer()) }
        XCTAssertEqual(board.cachedCount, 4)
        XCTAssertEqual(board.cachedBytes, 4 * bytesPerBuf)

        board.cacheBudgetBytes = 2 * bytesPerBuf // clamp to hold 2
        XCTAssertEqual(board.cachedCount, 2, "clamping the budget evicts down to fit")
        XCTAssertLessThanOrEqual(board.cachedBytes, 2 * bytesPerBuf)
        XCTAssertFalse(board.isCached(id: "id0"))
        XCTAssertFalse(board.isCached(id: "id1"))
        XCTAssertTrue(board.isCached(id: "id2"))
        XCTAssertTrue(board.isCached(id: "id3"))
    }

    // MARK: Count cap bounds the cache independently of bytes

    func testCountCapEvicts() throws {
        let board = try makeBoard(budgetBytes: .max, countCap: 2)
        for i in 0..<5 { board.register(id: "id\(i)", buffer: makeBuffer()) }
        XCTAssertEqual(board.cachedCount, 2, "count cap holds only the newest 2")
        XCTAssertTrue(board.isCached(id: "id3"))
        XCTAssertTrue(board.isCached(id: "id4"))
    }

    // MARK: A lone buffer larger than the whole budget is NOT pinned (F15)

    /// A single buffer larger than the whole budget must not silently blow the
    /// cache budget: it is evicted (played transiently, re-decoded on demand),
    /// so `cachedBytes` stays bounded rather than growing without limit.
    func testSingleOversizeBufferNotPinned() throws {
        let board = try makeBoard(budgetBytes: bytesPerBuf / 2) // < one buffer
        board.register(id: "big", buffer: makeBuffer())
        XCTAssertFalse(board.isCached(id: "big"), "oversize sole entry is not pinned in the cache")
        XCTAssertEqual(board.cachedCount, 0, "nothing retained over budget")
        XCTAssertLessThanOrEqual(board.cachedBytes, board.cacheBudgetBytes,
                                 "cachedBytes never exceeds the budget, even for a lone oversize entry")
        XCTAssertEqual(board.cachedBytes, 0)

        // Registering several oversize entries never accumulates over budget.
        for i in 0..<10 { board.register(id: "big\(i)", buffer: makeBuffer()) }
        XCTAssertLessThanOrEqual(board.cachedBytes, board.cacheBudgetBytes,
                                 "repeated oversize inserts stay bounded, not N×buffer")
        print("  [oversize] budget=\(board.cacheBudgetBytes)B resident=\(board.cachedBytes)B/\(board.cachedCount) (not pinned)")
    }

    // MARK: Byte accounting uses ALLOCATED capacity, not frameLength (F15)

    /// A buffer allocated with capacity ≫ frameLength must be accounted by its
    /// real footprint (frameCapacity·channels·4), not the shorter frameLength —
    /// otherwise the budget is undercounted and can be silently overrun.
    func testAccountingUsesAllocatedCapacity() throws {
        let fmt = SamplePlaybackEngine.internalFormat // 48 kHz stereo float
        let capacity: AVAudioFrameCount = 1000
        let length: AVAudioFrameCount = 100          // 10× shorter than allocation
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: capacity)!
        buf.frameLength = length

        let capacityBytes = Int(capacity) * 2 * MemoryLayout<Float>.size // 8000 B
        let lengthBytes = Int(length) * 2 * MemoryLayout<Float>.size     //  800 B

        let board = try makeBoard(budgetBytes: .max)
        board.register(id: "sparse", buffer: buf)
        XCTAssertEqual(board.cachedBytes, capacityBytes,
                       "accounted by allocated capacity (real footprint)")
        XCTAssertNotEqual(board.cachedBytes, lengthBytes,
                          "must NOT undercount using frameLength")
        print("  [capacity-accounting] capacity=\(capacityBytes)B length=\(lengthBytes)B resident=\(board.cachedBytes)B")
    }

    // MARK: Reload-on-miss: an evicted sound re-decodes and plays

    func testEvictedSoundReloadsAndPlays() throws {
        // Real generated library (small) for genuine disk reload.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-soundcache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let gen = try SoundFoundry.generate(to: tmp, perPlanLimit: 2)
        XCTAssertGreaterThan(gen.total, 8, "need several sounds to force eviction")
        let lib = try SoundLibrary(root: tmp)

        var cfg = AudioMixer.Configuration(); cfg.tapBufferFrames = 512
        let mixer = AudioMixer(configuration: cfg)
        let board = try Soundboard(mixer: mixer, library: lib, voiceCount: 8,
                                   cacheBudgetBytes: .max)
        try mixer.startManualRendering(maximumFrameCount: 4096)
        try board.startManual(maximumFrameCount: 4096)
        defer { board.stop(); mixer.stop() }

        let blockFrames: AVAudioFrameCount = 512
        func step() throws -> Float {
            try board.engine.render(frameCount: blockFrames)
            _ = try mixer.renderManually(frameCount: blockFrames)
            return mixer.masterPeakLevel().linear
        }

        // Load a batch unbounded, then clamp to a quarter to force eviction.
        let batch = Array(lib.entries.prefix(16).map(\.id))
        for id in batch { _ = try? board.preload(id: id) }
        let fullBytes = board.cachedBytes
        let fullCount = board.cachedCount
        let budget = max(1, fullBytes / 4)
        board.cacheBudgetBytes = budget

        XCTAssertLessThanOrEqual(board.cachedBytes, budget, "cache clamped under budget")
        XCTAssertLessThan(board.cachedCount, fullCount, "eviction happened")

        let evictedID = try XCTUnwrap(batch.first)
        let recentID = try XCTUnwrap(batch.last)
        XCTAssertFalse(board.isCached(id: evictedID), "oldest sound evicted")
        XCTAssertTrue(board.isCached(id: recentID), "newest sound survived")

        // Re-trigger the evicted sound → reload-on-miss, must be audible.
        try board.trigger(id: evictedID, volume: 1.0)
        XCTAssertTrue(board.isCached(id: evictedID), "re-triggered sound re-decoded into the cache")
        var energy: Float = 0
        for _ in 0..<24 { energy = max(energy, try step()) }
        XCTAssertGreaterThan(energy, 0.05, "reloaded sound is audible in the program mix")

        print("  [reload-on-miss] full=\(fullBytes)B/\(fullCount) buf → budget=\(budget)B resident=\(board.cachedBytes)B/\(board.cachedCount) buf; reload peak=\(String(format: "%.3f", energy))")
    }
}
