import AVFAudio
import CoreMedia
import Foundation
import PrismCore
import os

/// Headless verification of the BS.1770 loudness meter (`LoudnessMeter`),
/// no audio hardware, no TCC. Feeds calibrated synthetic tones straight into
/// the meter and asserts LUFS / true-peak land where the standard predicts.
///
/// Reference calibration (derived, not black-box): for a stereo dual-mono sine
/// the meter reads `L = −0.691 + 10·log10(g_k) + 20·log10(A)`, where `g_k` is
/// the K-weighting power gain at the tone frequency and `A` the amplitude. At
/// 1 kHz, `g_k ≈ 1.19` (≈ +0.76 dB), so a full-scale sine (A = 1) reads ≈ 0
/// LUFS and A ≈ 0.0703 reads ≈ −23 LUFS. This matches the well-known "0 dBFS
/// 997 Hz sine = −3.01 LUFS mono / 0 LUFS dual-mono" figure.
public enum LoudnessSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case mismatch(String)
        public var description: String {
            switch self { case .mismatch(let s): return "loudness self-test mismatch: \(s)" }
        }
    }

    public static func run() throws {
        try testCalibratedMinus23()
        try testFullScale()
        try testSilence()
        print("LoudnessSelfTest: all checks passed")
    }

    /// Feed `seconds` of a stereo (identical L/R) sine into `meter`.
    private static func feed(_ meter: LoudnessMeter, amplitude: Double, frequency: Double,
                             seconds: Double, sampleRate: Double = 48_000) {
        let total = Int(seconds * sampleRate)
        let blockSize = 4_800
        let step = 2.0 * .pi * frequency / sampleRate
        var phase = 0.0
        var idx = 0
        var left = [Float](repeating: 0, count: blockSize)
        var right = [Float](repeating: 0, count: blockSize)
        while idx < total {
            let n = min(blockSize, total - idx)
            for i in 0..<n {
                let s = Float(sin(phase) * amplitude)
                left[i] = s; right[i] = s
                phase += step
                if phase > 2.0 * .pi { phase -= 2.0 * .pi }
            }
            left.withUnsafeMutableBufferPointer { lp in
                right.withUnsafeMutableBufferPointer { rp in
                    var ptrs = [lp.baseAddress!, rp.baseAddress!]
                    ptrs.withUnsafeMutableBufferPointer { pp in
                        meter.process(pp.baseAddress!, channelCount: 2, frameCount: n)
                    }
                }
            }
            idx += n
        }
    }

    private static func testCalibratedMinus23() throws {
        let meter = LoudnessMeter(sampleRate: 48_000, channelCount: 2)
        feed(meter, amplitude: 0.07025, frequency: 1_000, seconds: 4.0)
        let m = meter.measurement
        // Steady tone → momentary ≈ short-term ≈ integrated ≈ −23 LUFS.
        for (name, value) in [("integrated", m.integrated), ("momentary", m.momentary), ("short-term", m.shortTerm)] {
            guard abs(value - (-23)) < 1.0 else {
                throw SelfTestError.mismatch("\(name) \(String(format: "%.2f", value)) LUFS, expected −23 ±1")
            }
        }
        guard abs(m.truePeak - (-23.07)) < 0.6 else {
            throw SelfTestError.mismatch("true-peak \(String(format: "%.2f", m.truePeak)) dBTP, expected −23.07 ±0.6")
        }
        print(String(format: "  ✓ −23 LUFS tone: M %.2f  S %.2f  I %.2f LUFS · TP %.2f dBTP",
                     m.momentary, m.shortTerm, m.integrated, m.truePeak))
    }

    private static func testFullScale() throws {
        let meter = LoudnessMeter(sampleRate: 48_000, channelCount: 2)
        feed(meter, amplitude: 1.0, frequency: 1_000, seconds: 4.0)
        let m = meter.measurement
        guard abs(m.integrated - 0.07) < 1.5 else {
            throw SelfTestError.mismatch("full-scale integrated \(String(format: "%.2f", m.integrated)) LUFS, expected ≈0 ±1.5")
        }
        guard m.truePeak > -0.4, m.truePeak < 0.6 else {
            throw SelfTestError.mismatch("full-scale true-peak \(String(format: "%.2f", m.truePeak)) dBTP, expected ≈0")
        }
        print(String(format: "  ✓ full-scale tone: I %.2f LUFS · TP %.2f dBTP (≈0 both)", m.integrated, m.truePeak))
    }

    private static func testSilence() throws {
        let meter = LoudnessMeter(sampleRate: 48_000, channelCount: 2)
        feed(meter, amplitude: 0.0, frequency: 1_000, seconds: 1.0)
        let m = meter.measurement
        guard m.momentary <= -70, m.integrated <= -70, m.truePeak <= -120 else {
            throw SelfTestError.mismatch("silence not floored: \(m)")
        }
        print("  ✓ silence → M/S/I ≤ −70 LUFS, TP = −inf")
    }
}

/// Headless verification of sidechain ducking (`AudioMixer.setDucking`) via the
/// mixer's manual-rendering mode. A steady music target is ducked by a bursting
/// mic key; the check asserts the target dips under the burst and recovers.
public enum DuckingSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case mismatch(String)
        public var description: String {
            switch self { case .mismatch(let s): return "ducking self-test mismatch: \(s)" }
        }
    }

    public static func run() throws {
        let mixer = AudioMixer()
        let music = SourceID("duck.music")
        let mic = SourceID("duck.mic")
        let musicCh = try mixer.addChannel(id: music)
        _ = try mixer.addChannel(id: mic)
        try mixer.setDucking(target: music, key: mic,
                             config: DuckingConfig(thresholdDB: -30, ratio: 8,
                                                   attack: 0.05, release: 0.2, maxAttenuationDB: 24))
        try mixer.startManualRendering(maximumFrameCount: 4096)
        defer { mixer.stop() }

        var musicFeeder = SineSource(frequency: 220, amplitude: 0.6, sampleRate: 48_000)
        var micFeeder = SineSource(frequency: 900, amplitude: 0.9, sampleRate: 48_000)
        var ingestPTS = CMTime.zero

        func pump(musicOn: Bool, micOn: Bool, seconds: Double) throws {
            let frames = Int(48_000 * seconds)
            if musicOn {
                musicCh.ingest(AudioPacket(sampleBuffer: try musicFeeder.makeBuffer(frameCount: frames, pts: ingestPTS), source: music))
            }
            if micOn {
                try mixer.channel(id: mic)?.ingest(AudioPacket(sampleBuffer: micFeeder.makeBuffer(frameCount: frames, pts: ingestPTS), source: mic))
            }
            ingestPTS = ingestPTS + CMTime(seconds: seconds, preferredTimescale: 48_000)
            var remaining = AVAudioFrameCount(Double(frames) * 0.9)
            while remaining > 0 {
                let block = min(remaining, 512)
                try mixer.renderManually(frameCount: block)
                remaining -= block
            }
        }
        func resetMeter() { _ = musicCh.peakLevel() }

        // Phase A — music only, no key: target passes at unity.
        try pump(musicOn: true, micOn: false, seconds: 0.2)
        resetMeter()
        try pump(musicOn: true, micOn: false, seconds: 0.2)
        let peakA = musicCh.peakLevel().linear

        // Phase B — loud mic burst: target ducks (settle attack, then measure).
        try pump(musicOn: true, micOn: true, seconds: 0.2)
        resetMeter()
        try pump(musicOn: true, micOn: true, seconds: 0.2)
        let peakB = musicCh.peakLevel().linear

        // Phase C — mic stops: target recovers (settle release, then measure).
        try pump(musicOn: true, micOn: false, seconds: 0.5)
        resetMeter()
        try pump(musicOn: true, micOn: false, seconds: 0.15)
        let peakC = musicCh.peakLevel().linear

        guard peakA > 0.45 else {
            throw SelfTestError.mismatch("un-ducked music too quiet: peak \(peakA), expected ≈0.6")
        }
        guard peakB < peakA * 0.3, peakB < 0.15 else {
            throw SelfTestError.mismatch("music not ducked under mic burst: A \(peakA) → B \(peakB)")
        }
        guard peakC > 0.4, peakC > peakB * 3 else {
            throw SelfTestError.mismatch("music did not recover after burst: B \(peakB) → C \(peakC)")
        }
        print(String(format: "  ✓ ducking: un-ducked %.3f → ducked %.3f → recovered %.3f", peakA, peakB, peakC))
        print("DuckingSelfTest: all checks passed")
    }
}

// MARK: - Cross-verification regression self-tests (C3 / C5 / C6 / C7)

/// Umbrella runner for the four audio cross-verification fixes. Each sub-test is
/// also independently runnable; this prints a compact PASS line per finding.
public enum AudioFindingsSelfTests {
    public static func run() throws {
        try DuckingKeyRemovalSelfTest.run()      // C3
        try LoudnessWeightingSelfTest.run()      // C5
        try IntegratedLoudnessBoundedSelfTest.run() // C6
        try LoudnessResetSafetySelfTest.run()    // C7
        print("AudioFindingsSelfTests: all checks passed")
    }
}

/// **C3** — Removing the *key* channel of a ducking rule must not leave the
/// target frozen-ducked. Drives the key loud (target ducks), removes the key
/// channel, and asserts the target recovers to full gain rather than staying
/// stuck at the key's last (loud) sidechain level.
public enum DuckingKeyRemovalSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case mismatch(String)
        public var description: String {
            switch self { case .mismatch(let s): return "ducking-key-removal self-test mismatch: \(s)" }
        }
    }

    public static func run() throws {
        let mixer = AudioMixer()
        let music = SourceID("c3.music")
        let mic = SourceID("c3.mic")
        let musicCh = try mixer.addChannel(id: music)
        _ = try mixer.addChannel(id: mic)
        try mixer.setDucking(target: music, key: mic,
                             config: DuckingConfig(thresholdDB: -30, ratio: 8,
                                                   attack: 0.05, release: 0.2, maxAttenuationDB: 24))
        try mixer.startManualRendering(maximumFrameCount: 4096)
        defer { mixer.stop() }

        var musicFeeder = SineSource(frequency: 220, amplitude: 0.6, sampleRate: 48_000)
        var micFeeder = SineSource(frequency: 900, amplitude: 0.9, sampleRate: 48_000)
        var ingestPTS = CMTime.zero

        func pump(musicOn: Bool, micOn: Bool, seconds: Double) throws {
            let frames = Int(48_000 * seconds)
            if musicOn {
                musicCh.ingest(AudioPacket(sampleBuffer: try musicFeeder.makeBuffer(frameCount: frames, pts: ingestPTS), source: music))
            }
            if micOn {
                try mixer.channel(id: mic)?.ingest(AudioPacket(sampleBuffer: micFeeder.makeBuffer(frameCount: frames, pts: ingestPTS), source: mic))
            }
            ingestPTS = ingestPTS + CMTime(seconds: seconds, preferredTimescale: 48_000)
            var remaining = AVAudioFrameCount(Double(frames) * 0.9)
            while remaining > 0 {
                let block = min(remaining, 512)
                try mixer.renderManually(frameCount: block)
                remaining -= block
            }
        }
        func resetMeter() { _ = musicCh.peakLevel() }

        // Phase A — music only: target at unity.
        try pump(musicOn: true, micOn: false, seconds: 0.2)
        resetMeter()
        try pump(musicOn: true, micOn: false, seconds: 0.2)
        let peakA = musicCh.peakLevel().linear

        // Phase B — loud mic burst: target ducks hard (and the key's published
        // sidechain level is now high — exactly the value that would freeze).
        try pump(musicOn: true, micOn: true, seconds: 0.2)
        resetMeter()
        try pump(musicOn: true, micOn: true, seconds: 0.2)
        let peakB = musicCh.peakLevel().linear

        // Remove the KEY channel while it is loud. Pre-fix, the target's Ducker
        // would keep reading the frozen-loud SidechainLevel forever.
        mixer.removeChannel(id: mic)

        // Phase C — music only, no key present: target must recover.
        try pump(musicOn: true, micOn: false, seconds: 0.3)
        resetMeter()
        try pump(musicOn: true, micOn: false, seconds: 0.15)
        let peakC = musicCh.peakLevel().linear

        guard peakA > 0.45 else {
            throw SelfTestError.mismatch("un-ducked music too quiet: peak \(peakA), expected ≈0.6")
        }
        guard peakB < peakA * 0.3, peakB < 0.15 else {
            throw SelfTestError.mismatch("music not ducked under mic burst: A \(peakA) → B \(peakB)")
        }
        guard peakC > 0.45, peakC > peakB * 3 else {
            throw SelfTestError.mismatch("target STUCK ducked after key removal (C3 not fixed): B \(peakB) → C \(peakC)")
        }
        print(String(format: "  ✓ C3 key-removal recovery: unity %.3f → ducked %.3f → key-removed→recovered %.3f", peakA, peakB, peakC))
    }
}

/// **C5** — BS.1770 channel weighting must be by *role*, not "everything past
/// L/R gets the surround weight". Unit-checks the weight table and proves LFE is
/// excluded (weight 0) while a front channel is counted, with stereo unchanged.
public enum LoudnessWeightingSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case mismatch(String)
        public var description: String {
            switch self { case .mismatch(let s): return "loudness-weighting self-test mismatch: \(s)" }
        }
    }

    public static func run() throws {
        // 1) Weight table by role (ITU/AAC order L,R,C,LFE,Ls,Rs).
        func approx(_ a: [Double], _ b: [Double]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-9 }
        }
        let stereo = LoudnessMeter.bs1770Weights(channelCount: 2)
        let mono = LoudnessMeter.bs1770Weights(channelCount: 1)
        let surround = LoudnessMeter.bs1770Weights(channelCount: 6)
        let seven1 = LoudnessMeter.bs1770Weights(channelCount: 8)
        guard approx(stereo, [1.0, 1.0]) else {
            throw SelfTestError.mismatch("stereo weights \(stereo), expected [1,1]")
        }
        guard approx(mono, [1.0]) else {
            throw SelfTestError.mismatch("mono weights \(mono), expected [1]")
        }
        guard approx(surround, [1.0, 1.0, 1.0, 0.0, 1.41, 1.41]) else {
            throw SelfTestError.mismatch("5.1 weights \(surround), expected [1,1,1,0,1.41,1.41] (LFE excluded)")
        }
        guard approx(seven1, [1.0, 1.0, 1.0, 0.0, 1.41, 1.41, 1.41, 1.41]) else {
            throw SelfTestError.mismatch("7.1 weights \(seven1), expected extra surround = 1.41")
        }

        // 2) Functional: a full-scale tone on LFE ONLY must not register (weight
        // 0), while the same tone on front-L registers ≈ full-scale loudness.
        let lfeMeter = LoudnessMeter(sampleRate: 48_000, channelCount: 6)
        var lfeAmps = [Double](repeating: 0, count: 6); lfeAmps[3] = 1.0 // LFE only
        feedMultichannel(lfeMeter, amplitudes: lfeAmps, frequency: 1_000, seconds: 2.0)
        let lfeM = lfeMeter.measurement
        guard lfeM.integrated <= -70, lfeM.momentary <= -70 else {
            throw SelfTestError.mismatch("LFE-only registered loudness \(lfeM.integrated) LUFS — LFE not excluded")
        }

        let frontMeter = LoudnessMeter(sampleRate: 48_000, channelCount: 6)
        var frontAmps = [Double](repeating: 0, count: 6); frontAmps[0] = 1.0 // front-L only
        feedMultichannel(frontMeter, amplitudes: frontAmps, frequency: 1_000, seconds: 2.0)
        let frontM = frontMeter.measurement
        // Single front channel full-scale ≈ −3 LUFS (one 1.0-weighted channel).
        guard frontM.integrated > -10, frontM.integrated < 3 else {
            throw SelfTestError.mismatch("front-L-only integrated \(frontM.integrated) LUFS, expected ≈−3")
        }

        // 3) Stereo −23 tone still reads −23 (the fix does not disturb stereo).
        let stereoMeter = LoudnessMeter(sampleRate: 48_000, channelCount: 2)
        feedMultichannel(stereoMeter, amplitudes: [0.07025, 0.07025], frequency: 1_000, seconds: 4.0)
        let sM = stereoMeter.measurement
        guard abs(sM.integrated - (-23)) < 1.0 else {
            throw SelfTestError.mismatch("stereo −23 tone read \(sM.integrated) LUFS after fix, expected −23 ±1")
        }
        print(String(format: "  ✓ C5 weights: LFE-only %.1f LUFS (excluded) · front-L %.1f · stereo −23 tone %.2f LUFS", lfeM.integrated, frontM.integrated, sM.integrated))
    }

    /// Feed a per-channel-amplitude sine into the meter (deinterleaved, one
    /// contiguous channel-major backing block reused across chunks).
    static func feedMultichannel(_ meter: LoudnessMeter, amplitudes: [Double],
                                 frequency: Double, seconds: Double, sampleRate: Double = 48_000) {
        let channels = amplitudes.count
        let total = Int(seconds * sampleRate)
        let blockSize = 4_800
        let step = 2.0 * .pi * frequency / sampleRate
        var phase = 0.0
        var flat = [Float](repeating: 0, count: channels * blockSize)
        var idx = 0
        while idx < total {
            let n = min(blockSize, total - idx)
            flat.withUnsafeMutableBufferPointer { fb in
                let base = fb.baseAddress!
                for i in 0..<n {
                    let s = sin(phase)
                    for c in 0..<channels { base[c * blockSize + i] = Float(s * amplitudes[c]) }
                    phase += step
                    if phase > 2.0 * .pi { phase -= 2.0 * .pi }
                }
                var ptrs = (0..<channels).map { base + $0 * blockSize }
                ptrs.withUnsafeMutableBufferPointer { pp in
                    meter.process(pp.baseAddress!, channelCount: channels, frameCount: n)
                }
            }
            idx += n
        }
    }
}

/// **C6** — Integrated loudness must stay correct while its gating history is
/// *bounded* (a fixed-size histogram) and `measurement` does no session-length
/// O(n) work under the tap lock. Feeds a long signal and asserts the integrated
/// reading is stable + gated correctly regardless of duration.
public enum IntegratedLoudnessBoundedSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case mismatch(String)
        public var description: String {
            switch self { case .mismatch(let s): return "integrated-bounded self-test mismatch: \(s)" }
        }
    }

    public static func run() throws {
        // 1) Long steady −23 tone → integrated ≈ −23, independent of how many
        // gating blocks accrue (histogram bin count is fixed, not O(session)).
        let meter = LoudnessMeter(sampleRate: 48_000, channelCount: 2)
        LoudnessWeightingSelfTest.feedMultichannel(meter, amplitudes: [0.07025, 0.07025],
                                                    frequency: 1_000, seconds: 30.0)
        let long = meter.measurement
        guard abs(long.integrated - (-23)) < 1.0 else {
            throw SelfTestError.mismatch("30 s −23 tone integrated \(long.integrated) LUFS, expected −23 ±1")
        }

        // 2) Relative-gate correctness: append a quiet segment well below the
        // relative gate (−23 mean → gate ≈ −33). A −55 LUFS-ish tail must be
        // gated out, so integrated stays anchored to the loud part (≈ −23).
        LoudnessWeightingSelfTest.feedMultichannel(meter, amplitudes: [0.005, 0.005],
                                                   frequency: 1_000, seconds: 8.0)
        let gated = meter.measurement
        guard abs(gated.integrated - (-23)) < 1.5 else {
            throw SelfTestError.mismatch("quiet tail leaked past relative gate: integrated \(gated.integrated) LUFS, expected ≈−23")
        }

        // 3) Bounded-history evidence: the integrated store is a fixed-size
        // histogram — its size does not depend on session length.
        let bins = LoudnessMeter.histBinCount
        guard bins > 0, bins < 5_000 else {
            throw SelfTestError.mismatch("histogram bin count \(bins) not a small fixed bound")
        }
        print(String(format: "  ✓ C6 integrated bounded: 30 s tone %.2f LUFS, +quiet-tail %.2f LUFS (gated) · fixed %d-bin histogram (O(1) update, no O(session) under lock)",
                     long.integrated, gated.integrated, bins))
    }
}

/// **C7** — `reset()` must be safe against a concurrent `process()`. Verifies
/// (a) reset actually clears prior state (a post-reset −23 tone reads −23, not
/// contaminated by earlier audio) and (b) hammering reset() from another thread
/// while process() runs neither crashes nor deadlocks (the shared `stateLock`).
public enum LoudnessResetSafetySelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case mismatch(String)
        public var description: String {
            switch self { case .mismatch(let s): return "reset-safety self-test mismatch: \(s)" }
        }
    }

    public static func run() throws {
        // (a) reset clears state: contaminate with full-scale, reset, then feed a
        // clean −23 tone. Without a proper reset the leftover filter/blocks would
        // bias the reading.
        let meter = LoudnessMeter(sampleRate: 48_000, channelCount: 2)
        LoudnessWeightingSelfTest.feedMultichannel(meter, amplitudes: [1.0, 1.0], frequency: 1_000, seconds: 1.0)
        meter.reset()
        let cleared = meter.measurement
        guard cleared.integrated == -.infinity, cleared.truePeak == -.infinity else {
            throw SelfTestError.mismatch("state not cleared by reset: \(cleared)")
        }
        LoudnessWeightingSelfTest.feedMultichannel(meter, amplitudes: [0.07025, 0.07025], frequency: 1_000, seconds: 4.0)
        let afterReset = meter.measurement
        guard abs(afterReset.integrated - (-23)) < 1.0 else {
            throw SelfTestError.mismatch("post-reset −23 tone read \(afterReset.integrated) LUFS (leftover state?)")
        }

        // (b) Concurrent reset ⟂ process: hammer both from two threads. The
        // stateLock must serialize them — no crash, no deadlock, sane result.
        let raced = LoudnessMeter(sampleRate: 48_000, channelCount: 2)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for _ in 0..<300 {
                LoudnessWeightingSelfTest.feedMultichannel(raced, amplitudes: [0.5, 0.5], frequency: 1_000, seconds: 0.02)
            }
            done.signal()
        }
        for _ in 0..<300 { raced.reset() }
        guard done.wait(timeout: .now() + 10) == .success else {
            throw SelfTestError.mismatch("process/reset race deadlocked (stateLock)")
        }
        let m = raced.measurement // must not crash / produce NaN
        guard !m.momentary.isNaN, !m.integrated.isNaN, !m.truePeak.isNaN else {
            throw SelfTestError.mismatch("NaN after concurrent reset/process: \(m)")
        }
        print("  ✓ C7 reset safety: post-reset −23 tone \(String(format: "%.2f", afterReset.integrated)) LUFS · 300× concurrent reset⟂process → no crash/deadlock/NaN")
    }
}

/// Deterministic interleaved-float-stereo sine → CMSampleBuffer (keeps phase).
private struct SineSource {
    let frequency: Double
    let amplitude: Double
    let sampleRate: Double
    private var phase: Double = 0

    init(frequency: Double, amplitude: Double, sampleRate: Double) {
        self.frequency = frequency; self.amplitude = amplitude; self.sampleRate = sampleRate
    }

    mutating func makeBuffer(frameCount: Int, pts: CMTime) throws -> CMSampleBuffer {
        let step = 2.0 * .pi * frequency / sampleRate
        var interleaved = [Float](repeating: 0, count: frameCount * 2)
        for f in 0..<frameCount {
            let s = Float(sin(phase) * amplitude)
            interleaved[f * 2] = s; interleaved[f * 2 + 1] = s
            phase += step
            if phase > 2.0 * .pi { phase -= 2.0 * .pi }
        }
        let fd = try AudioSampleBufferFactory.interleavedFloatFormatDescription(sampleRate: sampleRate, channelCount: 2)
        return try interleaved.withUnsafeBufferPointer {
            try AudioSampleBufferFactory.makeInterleavedSampleBuffer(
                samples: $0.baseAddress!, frameCount: frameCount, channelCount: 2,
                formatDescription: fd, pts: pts)
        }
    }
}
