import AVFAudio
import CoreMedia
import Foundation
import PrismAudio
import PrismCore

/// Shared self-test report shape (mirrors `AudioMixerSelfCheck.Report`).
public struct SoundTestReport: Sendable, CustomStringConvertible {
    public struct Check: Sendable { public let name: String; public let passed: Bool; public let detail: String }
    public let checks: [Check]
    public var allPassed: Bool { checks.allSatisfy(\.passed) }
    public var description: String {
        checks.map { "\($0.passed ? "PASS" : "FAIL")  \($0.name) — \($0.detail)" }.joined(separator: "\n")
    }
}

/// Headless verification of SoundFoundry generation, SoundLibrary loading, and
/// Soundboard playback routed through an `AudioMixer` — AVAudioEngine manual
/// rendering, zero audio hardware, zero TCC.
public enum SoundSelfTest {
    public static func run() throws -> SoundTestReport {
        var checks: [SoundTestReport.Check] = []
        func check(_ name: String, _ passed: Bool, _ detail: String) {
            checks.append(.init(name: name, passed: passed, detail: detail))
        }

        // ---- 1. Generate a small, category-diverse library to a temp dir ----
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-sound-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let report = try SoundFoundry.generate(to: tmp, perPlanLimit: 2)
        check("generation produced sounds", report.total >= 40, "\(report.total) sounds, \(report.perCategory.count) categories")

        // ---- 2. Load the manifest + resolve files ----
        let lib = try SoundLibrary(root: tmp)
        check("library.json loads", lib.entries.count == report.total,
              "manifest \(lib.entries.count) vs generated \(report.total)")
        let categories = lib.categories
        check("categories present", categories.count >= 6, categories.joined(separator: ","))
        let allFilesExist = lib.entries.allSatisfy { FileManager.default.fileExists(atPath: lib.url(for: $0).path) }
        check("every manifest file exists on disk", allFilesExist, "\(lib.entries.count) files")
        check("loopable sounds tagged", !lib.loopable.isEmpty, "\(lib.loopable.count) loopable")
        check("search by tag works", !lib.entries(withTag: "kick").isEmpty && !lib.search("kick").isEmpty,
              "kick tag \(lib.entries(withTag: "kick").count)")

        // ---- 3. Spot-check a WAV is valid + non-silent + right duration ----
        guard let kickEntry = lib.entries(inCategory: "drums").first(where: { $0.tags.contains("kick") }) ?? lib.entries.first else {
            throw PrismAudioError.invalidState("no entries to spot-check")
        }
        let file = try AVAudioFile(forReading: lib.url(for: kickEntry))
        let fileSeconds = Double(file.length) / file.processingFormat.sampleRate
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        var peak: Float = 0
        if let d = buf.floatChannelData {
            for c in 0..<Int(buf.format.channelCount) { for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(d[c][i])) } }
        }
        check("spot-checked WAV opens + non-silent", peak > 0.1, "peak \(String(format: "%.3f", peak)) (\(kickEntry.file))")
        check("WAV duration matches manifest", abs(fileSeconds - kickEntry.durationSec) < 0.02,
              "file \(String(format: "%.3f", fileSeconds))s vs manifest \(kickEntry.durationSec)s")

        // ---- 4. Soundboard trigger → mixer master output ----
        // Match the mixer's master-tap granularity to our render block so
        // masterPeakLevel() reflects every block (default 1024 would alias).
        var cfg = AudioMixer.Configuration(); cfg.tapBufferFrames = 512
        let mixer = AudioMixer(configuration: cfg)
        let board = try Soundboard(mixer: mixer, library: lib, voiceCount: 8)
        _ = try board.preload(id: kickEntry.id)
        try mixer.startManualRendering(maximumFrameCount: 4096)
        try board.startManual(maximumFrameCount: 4096)
        defer { board.stop(); mixer.stop() }

        let blockFrames: AVAudioFrameCount = 512
        func step() throws -> Float {
            try board.engine.render(frameCount: blockFrames)
            _ = try mixer.renderManually(frameCount: blockFrames)
            return mixer.masterPeakLevel().linear
        }

        // Pre-trigger: the mix is silent.
        var preEnergy: Float = 0
        for _ in 0..<4 { preEnergy = max(preEnergy, try step()) }
        check("mix silent before trigger", preEnergy < 0.01, "pre-trigger peak \(String(format: "%.4f", preEnergy))")

        // Trigger, then render — energy must appear in the program mix.
        try board.trigger(id: kickEntry.id, volume: 1.0)
        var postEnergy: Float = 0
        for _ in 0..<24 { postEnergy = max(postEnergy, try step()) }
        check("triggered sound audible in program mix", postEnergy > 0.05,
              "post-trigger peak \(String(format: "%.3f", postEnergy))")

        // Polyphony: two overlapping triggers don't stall (still audible).
        try board.trigger(id: kickEntry.id, volume: 0.8)
        try board.trigger(id: kickEntry.id, volume: 0.8)
        var polyEnergy: Float = 0
        for _ in 0..<12 { polyEnergy = max(polyEnergy, try step()) }
        check("polyphonic triggers audible", polyEnergy > 0.05, "peak \(String(format: "%.3f", polyEnergy))")

        // ---- 5. LRU cache: byte budget bound + LRU eviction + reload-on-miss ----
        // Load a batch of distinct sounds with no bound, measure the resident set,
        // then clamp the budget to a quarter and confirm the cache evicts the
        // least-recently-used entries down under budget while the newest survive.
        let batch = Array(lib.entries.prefix(24).map(\.id))
        board.cacheBudgetBytes = .max
        for id in batch { _ = try? board.preload(id: id) }
        let fullBytes = board.cachedBytes
        let fullCount = board.cachedCount
        let budget = max(1, fullBytes / 4)
        board.cacheBudgetBytes = budget      // evicts immediately down to budget
        check("cache respects byte budget", board.cachedBytes <= budget,
              "resident \(board.cachedBytes)B <= budget \(budget)B (unbounded was \(fullBytes)B / \(fullCount) buf)")
        check("cache evicted under budget", board.cachedCount < fullCount,
              "resident \(board.cachedCount) of \(fullCount) buf after clamp")

        guard let evictedID = batch.first, let recentID = batch.last else {
            throw PrismAudioError.invalidState("empty batch for cache test")
        }
        check("LRU (oldest) entry evicted", !board.isCached(id: evictedID), "\(evictedID) gone")
        check("recent entry survived eviction", board.isCached(id: recentID), "\(recentID) resident")

        // Re-trigger the evicted sound: it must reload-on-miss and be audible.
        try board.trigger(id: evictedID, volume: 1.0)
        check("evicted sound reloaded on trigger", board.isCached(id: evictedID), "\(evictedID) re-resident")
        var reloadEnergy: Float = 0
        for _ in 0..<24 { reloadEnergy = max(reloadEnergy, try step()) }
        check("re-triggered evicted sound audible", reloadEnergy > 0.05,
              "peak \(String(format: "%.3f", reloadEnergy)) after reload-on-miss")

        return SoundTestReport(checks: checks)
    }
}
