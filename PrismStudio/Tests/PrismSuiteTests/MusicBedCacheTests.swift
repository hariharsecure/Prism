import AVFAudio
import XCTest

import PrismAudio
import PrismCore
import PrismSound

/// Deterministic verification of the `MusicBed` bounded decoded-bed cache
/// (F15 memory-safety fix). Previously `MusicBed.beds` was an unbounded dict, so
/// auditioning many beds pinned every decoded buffer forever (~219 MiB for the 95
/// installed loopable beds). The cache is now bounded to the active/crossfade
/// pair; a re-selected bed re-decodes on demand. These tests prove the resident
/// set stays bounded and that gapless looping + crossfade survive eviction.
final class MusicBedCacheTests: XCTestCase {

    private func makeBed(budgetBytes: Int = MusicBed.defaultCacheBudgetBytes,
                         countCap: Int = MusicBed.defaultCacheCountCap,
                         library: SoundLibrary? = nil) throws -> MusicBed {
        var cfg = AudioMixer.Configuration(); cfg.tapBufferFrames = 512
        let mixer = AudioMixer(configuration: cfg)
        return try MusicBed(mixer: mixer, library: library,
                            cacheBudgetBytes: budgetBytes, cacheCountCap: countCap)
    }

    /// Allocated footprint of a decoded bed (frameCapacity·channels·4) — the same
    /// accounting the cache uses.
    private func footprint(_ buf: AVAudioPCMBuffer) -> Int {
        Int(buf.frameCapacity) * Int(buf.format.channelCount) * MemoryLayout<Float>.size
    }

    // MARK: Auditioning N beds keeps only the active/crossfade pair resident

    /// Register N distinct synthesized beds (an "audition") and assert the
    /// resident decoded bytes stay bounded to the pair the bed actually needs —
    /// NOT the sum of all N. On the pre-fix unbounded dict this would retain all
    /// N buffers (the ~219 MiB leak); here it stays at the count cap.
    func testAuditioningManyBedsStaysBounded() throws {
        let bed = try makeBed()
        let N = 24
        var wouldPinBytes = 0            // what the OLD unbounded dict would retain
        for i in 0..<N {
            let buf = MusicBed.synthesizeChordBed(rootMidi: 36 + i, minor: i % 2 == 0,
                                                  approxSeconds: 1.0)
            wouldPinBytes += footprint(buf)
            bed.register(id: "bed\(i)", buffer: buf)
        }

        let residentBytes = bed.residentBedBytes
        let residentCount = bed.residentBedCount
        XCTAssertLessThanOrEqual(residentCount, MusicBed.defaultCacheCountCap,
            "resident beds bounded to the active/crossfade pair, not N")
        XCTAssertGreaterThan(residentCount, 0, "still holds the most-recent bed(s)")
        // The pair is a tiny fraction of the N auditioned beds.
        XCTAssertLessThan(residentBytes, wouldPinBytes / 4,
            "resident bytes are ≈ the pair, not the sum of all \(N) beds")
        XCTAssertLessThanOrEqual(residentBytes, bed.residentBedBytes) // stable read
        print("  [musicbed-audition] N=\(N) beds — OLD would pin \(wouldPinBytes) B "
              + "(\(wouldPinBytes / (1024 * 1024)) MiB); NEW resident \(residentBytes) B "
              + "(\(residentBytes / 1024) KiB) / \(residentCount) buf")
    }

    // MARK: An evicted bed re-decodes and still loops gaplessly (real library)

    /// Audition several library beds (evicting the earliest under the pair bound),
    /// then `play` an evicted one: it must re-decode (preload-on-miss) and loop
    /// with no silent block across the loop point — proving the bound did not
    /// break gapless playback.
    func testEvictedBedRedecodesAndLoopsGaplessly() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-musicbed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try SoundFoundry.generate(to: tmp, perPlanLimit: 2)
        let lib = try SoundLibrary(root: tmp)

        let loopIDs = Array(lib.loopable.prefix(5).map(\.id))
        try XCTSkipIf(loopIDs.count < 3, "need ≥3 loopable beds to force eviction")

        var cfg = AudioMixer.Configuration(); cfg.tapBufferFrames = 512
        let mixer = AudioMixer(configuration: cfg)
        let bed = try MusicBed(mixer: mixer, library: lib) // default cap = pair (2)
        try mixer.startManualRendering(maximumFrameCount: 4096)
        try bed.startManual(maximumFrameCount: 4096)
        defer { bed.stop(); mixer.stop() }
        bed.volume = 0.9

        // Audition every loop bed → cache stays bounded to the pair.
        for id in loopIDs { _ = try bed.preload(id: id) }
        XCTAssertLessThanOrEqual(bed.residentBedCount, MusicBed.defaultCacheCountCap,
            "auditioning \(loopIDs.count) beds stays bounded to the pair")

        // The earliest-auditioned bed was evicted (a miss returns nil, no re-decode).
        let evictedID = loopIDs.first!
        XCTAssertNil(bed.buffer(id: evictedID), "earliest bed evicted under the bound")

        // Play it: play(id:) must re-decode on miss and NOT throw.
        try bed.play(id: evictedID)
        let redecoded = try XCTUnwrap(bed.buffer(id: evictedID),
                                      "evicted bed re-decoded into the cache on play")
        let loopFrames = Int(redecoded.frameLength)

        let block: AVAudioFrameCount = 512
        func step() throws -> Float {
            try bed.engine.render(frameCount: block)
            _ = try mixer.renderManually(frameCount: block)
            return bed.engine.sinkChannel?.peakLevel().linear ?? mixer.masterPeakLevel().linear
        }
        let blocksPerLoop = max(1, loopFrames / Int(block))
        var peaks: [Float] = []
        for _ in 0..<(blocksPerLoop * 2 + 8) { peaks.append(try step()) }
        // Skip startup latency, then require EVERY steady block to carry energy —
        // a gap at the loop point would zero one.
        let steady = Array(peaks.dropFirst(4))
        let minSteady = steady.min() ?? 0
        XCTAssertGreaterThan(minSteady, 0.02,
            "re-decoded bed loops gaplessly (no silent block across the loop point)")
        XCTAssertGreaterThan(steady.count, blocksPerLoop, "rendered past ≥1 loop point")

        print("  [musicbed-redecode] evicted \(evictedID) → re-decoded on play; "
              + "min steady peak \(String(format: "%.3f", minSteady)) over \(steady.count) blocks "
              + "(loop=\(blocksPerLoop)); resident \(bed.residentBedBytes) B / \(bed.residentBedCount) buf")

        // Crossfade to another evicted bed must also re-decode (not throw) and
        // stay audible throughout — the crossfade path survives the bound.
        let crossID = loopIDs[1]
        try bed.crossfade(toID: crossID, duration: 0.3)
        var crossMin: Float = 1
        for i in 0..<16 { let e = try step(); if i > 2 { crossMin = min(crossMin, e) } }
        XCTAssertGreaterThan(crossMin, 0.02, "crossfade to a re-decoded bed stays audible")
        XCTAssertLessThanOrEqual(bed.residentBedCount, MusicBed.defaultCacheCountCap,
            "still bounded after crossfade")
    }
}
