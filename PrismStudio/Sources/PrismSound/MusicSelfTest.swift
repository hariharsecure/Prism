import AVFAudio
import CoreMedia
import Foundation
import PrismAudio
import PrismCore

/// Headless verification of the BeatSequencer (pattern renders with hits at the
/// on-steps) and MusicBed (gapless loop + crossfade), routed through an
/// `AudioMixer` in manual-rendering mode.
public enum MusicSelfTest {
    public static func run() throws -> SoundTestReport {
        var checks: [SoundTestReport.Check] = []
        func check(_ name: String, _ passed: Bool, _ detail: String) {
            checks.append(.init(name: name, passed: passed, detail: detail))
        }

        // A small library for the sequencer's drum samples.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-music-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try SoundFoundry.generate(to: tmp, perPlanLimit: 2)
        let lib = try SoundLibrary(root: tmp)

        // ---- 1. BeatSequencer: render 1 bar, assert energy at on-steps ----
        guard let kick = lib.entries(withTag: "kick").first?.id,
              let snare = lib.entries(withTag: "snare").first?.id,
              let hat = lib.entries(withTag: "closed").first?.id ?? lib.entries(withTag: "hihat").first?.id else {
            throw PrismAudioError.invalidState("missing drum samples for sequencer test")
        }
        // Kick on steps 0,4,8,12; snare 4,12; hats every other — leave step 15 empty.
        var pattern = BeatSequencer.basicPattern(kick: kick, snare: snare, hat: hat, bpm: 120)
        var cfgB = AudioMixer.Configuration(); cfgB.tapBufferFrames = 256
        let mixerB = AudioMixer(configuration: cfgB)
        let seq = try BeatSequencer(mixer: mixerB, library: lib)
        try seq.load(pattern: pattern)
        try mixerB.startManualRendering(maximumFrameCount: 4096)
        try seq.engine.startManual(maximumFrameCount: 4096)
        defer { seq.stop(); mixerB.stop() }

        let result = try seq.renderOffline(bars: 1, mixer: mixerB, blockFrames: 256)
        let peaks = result.blockPeaks
        check("sequencer produced audio", peaks.contains { $0 > 0.05 }, "\(peaks.count) blocks, max \(String(format: "%.3f", peaks.max() ?? 0))")

        // Energy near each on-step onset block (within a small window after it).
        var hitsFound = 0
        for ob in result.onsetBlocks {
            let window = peaks[ob..<min(peaks.count, ob + 6)]
            if window.contains(where: { $0 > 0.05 }) { hitsFound += 1 }
        }
        check("energy at on-step onsets", hitsFound == result.onsetBlocks.count,
              "\(hitsFound)/\(result.onsetBlocks.count) onsets had energy")

        // The last sixteenth (step 15) has no hit — its block window should be quieter
        // than the loudest hit (proves placement, not a constant drone).
        let stepFrames = Int(pattern.stepSeconds * result.sampleRate)
        let step15Block = (15 * stepFrames) / result.blockFrames
        let tail = peaks[min(step15Block, peaks.count - 1)...]
        let maxPeak = peaks.max() ?? 1
        check("silent step is quieter than a hit", (tail.max() ?? 0) < maxPeak * 0.9,
              "step15 tail max \(String(format: "%.3f", tail.max() ?? 0)) vs overall \(String(format: "%.3f", maxPeak))")

        // Pattern is Codable (save/load round-trip).
        let data = try pattern.makeCodableData()
        let restored = try BeatPattern.fromData(data)
        pattern.swing = 0.2
        check("pattern Codable round-trips", restored.tracks.count == 3 && restored.bpm == 120,
              "\(restored.tracks.count) tracks @ \(restored.bpm) bpm")

        // ---- 2. MusicBed: gapless loop (no silent block across the loop point) ----
        var cfgM = AudioMixer.Configuration(); cfgM.tapBufferFrames = 512
        let mixerM = AudioMixer(configuration: cfgM)
        let micID = SourceID("selftest.mic")
        _ = try mixerM.addChannel(id: micID) // a key channel to prove duckability
        let bed = try MusicBed(mixer: mixerM, library: lib)
        let bedBuf = MusicBed.synthesizeChordBed(rootMidi: 48, minor: false, approxSeconds: 1.0)
        let bedFrames = Int(bedBuf.frameLength)
        try mixerM.startManualRendering(maximumFrameCount: 4096)
        try bed.startManual(maximumFrameCount: 4096)
        defer { bed.stop(); mixerM.stop() }
        bed.volume = 0.9
        bed.playBuffer(bedBuf)

        let block: AVAudioFrameCount = 512
        func bedStep() throws -> Float {
            try bed.engine.render(frameCount: block)
            _ = try mixerM.renderManually(frameCount: block)
            // Per-block-accurate channel peak (master tap flushes on its own grain).
            return bed.engine.sinkChannel?.peakLevel().linear ?? mixerM.masterPeakLevel().linear
        }
        // Render well past one loop length so we cross the loop point at least once.
        let blocksForLoop = bedFrames / Int(block)
        let totalBlocks = blocksForLoop * 2 + 8
        var bedPeaks: [Float] = []
        for _ in 0..<totalBlocks { bedPeaks.append(try bedStep()) }
        // Ignore the first few startup blocks (buffering latency), then require
        // EVERY block to carry energy — a gap at the loop point would zero one.
        let steady = Array(bedPeaks.dropFirst(4))
        let minSteady = steady.min() ?? 0
        check("music bed loops gaplessly (no silent block)", minSteady > 0.05 && steady.count > blocksForLoop,
              "min steady block peak \(String(format: "%.3f", minSteady)) over \(steady.count) blocks (loop=\(blocksForLoop))")

        // Duckable: the bed is on its own channel, so setDucking must succeed.
        var duckingOK = true
        do { try mixerM.setDucking(target: bed.channelID, key: micID, config: DuckingConfig()) }
        catch { duckingOK = false }
        check("music bed channel is duckable", duckingOK, "setDucking(target: \(bed.channelID.raw), key: mic)")

        // ---- 3. Crossfade mechanism (deterministic manual ramp across 2 voices) ----
        let bedB = MusicBed.synthesizeChordBed(rootMidi: 55, minor: true, approxSeconds: 1.0)
        bed.engine.play(bedB, onVoice: 1, loop: true, volume: 0)
        var crossMin: Float = 1
        let ramp = 20
        for i in 0...ramp {
            let p = Float(i) / Float(ramp)
            bed.engine.setVoiceVolume(0.9 * (1 - p), onVoice: 0)
            bed.engine.setVoiceVolume(0.9 * p, onVoice: 1)
            let e = try bedStep()
            if i > 2 { crossMin = min(crossMin, e) }
        }
        check("crossfade stays audible throughout (no dropout)", crossMin > 0.05,
              "min peak during crossfade \(String(format: "%.3f", crossMin))")

        // ---- 4. A2: loop-seam continuity on a REAL loopable library entry ----
        // Loads an actual generated `loopable` WAV off disk and asserts the
        // last→first wrap is no worse than the file's own roughest interior step
        // (crossfade added no discontinuity). The synthetic bed can't catch this;
        // only a real loopify'd file can.
        func seamRatio(_ chans: [[Float]]) -> (jump: Float, maxRatio: Float) {
            var worstJump: Float = 0, worstMaxRatio: Float = 0
            for ch in chans where ch.count > 2 {
                let jump = abs(ch[0] - ch[ch.count - 1])
                var maxStep: Float = 0
                for i in 1..<ch.count { maxStep = max(maxStep, abs(ch[i] - ch[i - 1])) }
                worstJump = max(worstJump, jump)
                worstMaxRatio = max(worstMaxRatio, maxStep > 1e-9 ? jump / maxStep : 0)
            }
            return (worstJump, worstMaxRatio)
        }
        func readChannels(_ url: URL) throws -> [[Float]] {
            let file = try AVAudioFile(forReading: url)
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
            try file.read(into: buf)
            guard let d = buf.floatChannelData else { return [] }
            let n = Int(buf.frameLength)
            return (0..<Int(buf.format.channelCount)).map { Array(UnsafeBufferPointer(start: d[$0], count: n)) }
        }
        if let loop = lib.loopable.first {
            let chans = try readChannels(lib.url(for: loop))
            let (jump, ratio) = seamRatio(chans)
            check("A2: real loopable WAV seam ≤ interior step", !chans.isEmpty && ratio <= 1.05,
                  "\(loop.file): seam |first−last| \(String(format: "%.4f", jump)), seam/max-interior \(String(format: "%.2f", ratio))×")
        } else {
            check("A2: real loopable WAV seam ≤ interior step", false, "no loopable entry in library")
        }

        // Discrimination: the check must FAIL on the OLD inverted crossfade and
        // PASS on the corrected one — proving it actually catches the A1 bug.
        let sr = 48_000
        // Low frequency ⇒ tiny adjacent steps but endpoints far out of phase, so
        // a truncated/inverted-crossfade loop leaves a huge last→first jump (many ×
        // the max interior step) while the correct crossfade makes it ~1 step.
        var tone = [Float](repeating: 0, count: sr)
        for k in 0..<sr { tone[k] = 0.7 * sinf(2 * .pi * 7.3 * Float(k) / Float(sr)) }
        // Fixed loopify (module DSP): seam must be continuous.
        let fixed = loopify([tone], sampleRate: sr)
        // Old inverted crossfade (head=cos/tail=sin) reconstructed inline.
        func invertedLoopify(_ ch: [Float]) -> [Float] {
            let n = ch.count
            let x = min(n / 3, Int(Float(sr) * 120 / 1000))
            let outN = n - x
            var out = Array(ch[0..<outN])
            for i in 0..<x {
                let t = Float(i) / Float(x)
                out[i] = ch[i] * cosf(0.5 * .pi * t) + ch[outN + i] * sinf(0.5 * .pi * t)
            }
            return out
        }
        let inverted = invertedLoopify(tone)
        // Largest discontinuity anywhere in the CYCLE (interior steps + the wrap).
        // The correct crossfade keeps every step near the source signal's own max
        // step; the inverted one injects a glitch — at the wrap AND at the
        // crossfade→body boundary — many × larger.
        func maxCyclicStep(_ ch: [Float]) -> Float {
            guard ch.count > 1 else { return 0 }
            var m: Float = 0
            for i in 1..<ch.count { m = max(m, abs(ch[i] - ch[i - 1])) }
            return max(m, abs(ch[0] - ch[ch.count - 1]))     // include the loop wrap
        }
        var origMax: Float = 0
        for i in 1..<tone.count { origMax = max(origMax, abs(tone[i] - tone[i - 1])) }
        let fixedMax = maxCyclicStep(fixed[0])
        let invertedMax = maxCyclicStep(inverted)
        check("A2: seam check discriminates fixed vs inverted crossfade",
              fixedMax <= origMax * 5 && invertedMax > origMax * 20,
              String(format: "source max step %.5f → fixed cyclic max %.5f (≈source), inverted %.4f (glitch %.0f×)",
                     origMax, fixedMax, invertedMax, invertedMax / max(origMax, 1e-9)))

        // ---- 4b. A11: ABSOLUTE loop-seam continuity on a REAL loopable ambience ----
        // The ratio metric (A2) passes broadband rain even with an audible periodic
        // click, because rain's own interior noise steps are as large as the seam.
        // A genuine loop must have |first−last| tiny in ABSOLUTE terms regardless of
        // how rough its interior is. Prefer a rain file — the worst pre-fix offender
        // (|first−last| was 0.08–0.37; the loopify seam-weld drives it to ~0).
        let rainEntry = lib.entries(withTag: "rain").first ?? lib.loopable.first
        if let loop = rainEntry {
            let chans = try readChannels(lib.url(for: loop))
            var worstAbs: Float = 0
            for ch in chans where ch.count > 2 { worstAbs = max(worstAbs, abs(ch[0] - ch[ch.count - 1])) }
            check("A11: real loopable WAV absolute seam |first−last| < 0.03",
                  !chans.isEmpty && worstAbs < 0.03,
                  "\(loop.file): |first−last| = \(String(format: "%.5f", worstAbs))")
        } else {
            check("A11: real loopable WAV absolute seam |first−last| < 0.03", false,
                  "no rain/loopable entry in library")
        }

        // Discrimination: on the SAME broadband bed, the OLD crossfade-only loopify
        // (no weld) leaves a large absolute seam (an audible click) while the fixed
        // loopify (crossfade + weld) drives it to ~0. Bed = high-passed white noise,
        // exactly like the rain generator, so adjacent samples are near-uncorrelated
        // and the raw wrap is a full noise-sized step.
        var bedRng = SplitMix64(seed: 0x9E37_79B9_7F4A_7C15)
        var hp = OnePoleHP()
        var noiseBed = [Float](repeating: 0, count: sr)
        for k in 0..<sr { noiseBed[k] = hp.process(bedRng.bipolar(), cutoff: 1500, sampleRate: Float(sr)) * 0.5 }
        func crossfadeOnlySeam(_ ch: [Float]) -> Float {
            let n = ch.count
            let xx = min(n / 3, Int(Float(sr) * 120 / 1000))
            let outN = n - xx
            var out = Array(ch[0..<outN])
            for i in 0..<xx {
                let t = Float(i) / Float(xx)
                out[i] = ch[i] * sinf(0.5 * .pi * t) + ch[outN + i] * cosf(0.5 * .pi * t)
            }
            return abs(out[0] - out[outN - 1])
        }
        let oldSeam = crossfadeOnlySeam(noiseBed)
        let welded = loopify([noiseBed], sampleRate: sr)     // crossfade + A11 weld
        let fixedSeam = abs(welded[0][0] - welded[0][welded[0].count - 1])
        check("A11: weld drives broadband seam ~0 where crossfade-only leaves a click",
              oldSeam > 0.1 && fixedSeam < 0.02,
              String(format: "crossfade-only seam %.4f (click) → welded %.5f (continuous)", oldSeam, fixedSeam))

        // ---- 4c. FOOTPRINT: transparent format optimization is actually written ----
        // The disk-footprint pass must land in the real WAV headers, not just the
        // manifest: (a) every previously-24-bit category is now 16-bit (96 dB SNR,
        // transparent), (b) negligible-HF sustained beds are 32 kHz while HF-bearing
        // beds stay 48 kHz, (c) dual-mono stingers collapsed to 1 channel — AND the
        // 32 kHz loopable seam still welds to ~0 (the format change didn't break it).
        func diskFormat(_ tag: String) throws -> (bits: UInt32, sr: Double, ch: UInt32, seam: Float)? {
            guard let e = lib.entries(withTag: tag).first else { return nil }
            let f = try AVAudioFile(forReading: lib.url(for: e))
            let asbd = f.fileFormat.streamDescription.pointee
            let chans = try readChannels(lib.url(for: e))
            var worstAbs: Float = 0
            for ch in chans where ch.count > 2 { worstAbs = max(worstAbs, abs(ch[0] - ch[ch.count - 1])) }
            return (asbd.mBitsPerChannel, f.fileFormat.sampleRate, asbd.mChannelsPerFrame, worstAbs)
        }
        // 16-bit everywhere it used to be 24-bit.
        let bitTargets = ["drone", "texture", "riser", "downlifter", "boom", "cinematic"]
        var all16 = true, bitDetail = ""
        for t in bitTargets {
            let bits = (try diskFormat(t))?.bits ?? 0
            if bits != 16 { all16 = false }
            bitDetail += "\(t)=\(bits) "
        }
        check("FOOTPRINT: former 24-bit categories are now 16-bit", all16, bitDetail)

        // 32 kHz on negligible-HF beds; 48 kHz kept on HF-bearing beds/impacts.
        let dTex = try diskFormat("texture"); let dDrone = try diskFormat("drone")
        let dWind = try diskFormat("wind"); let dRain = try diskFormat("rain")
        let dRoom = try diskFormat("roomtone")
        let ratesOK = dTex?.sr == 32_000 && dDrone?.sr == 32_000 && dWind?.sr == 32_000
            && dRain?.sr == 48_000 && dRoom?.sr == 48_000
        check("FOOTPRINT: negligible-HF beds→32k, HF beds stay 48k", ratesOK,
              "drone=\(dDrone?.sr ?? 0) texture=\(dTex?.sr ?? 0) wind=\(dWind?.sr ?? 0) "
              + "rain=\(dRain?.sr ?? 0) roomtone=\(dRoom?.sr ?? 0)")

        // Dual-mono stingers collapsed to 1 channel; genuinely-stereo beds stay 2.
        let arpCh = (try diskFormat("arp"))?.ch ?? 0
        let alertCh = (try diskFormat("alert"))?.ch ?? 0
        let droneCh = dDrone?.ch ?? 0
        check("FOOTPRINT: dual-mono stingers are 1ch, stereo beds stay 2ch",
              arpCh == 1 && alertCh == 1 && droneCh == 2,
              "arp=\(arpCh)ch alert=\(alertCh)ch drone=\(droneCh)ch")

        // The 32 kHz loopable seam survived the rate change (weld still ~0).
        let droneSeam = dDrone?.seam ?? 1
        let texSeam = dTex?.seam ?? 1
        check("FOOTPRINT: 32k loopable seam still |first−last| < 0.03",
              droneSeam < 0.03 && texSeam < 0.03,
              "drone seam \(String(format: "%.5f", droneSeam)), texture seam \(String(format: "%.5f", texSeam))")

        // ---- 5. A5: live BeatSequencer scheduling math (exact swung onsets) ----
        // The live path was untested (all tests used renderOffline). Drive the
        // exact cursor the live clock uses and assert each step fires once, at its
        // exact swung time, strictly increasing (no collisions/late-by-a-tick).
        let swung = BeatPattern(bpm: 120, swing: 0.6, stepCount: 16)
        let step = swung.stepSeconds                    // 0.125 s @120
        // Known-good swung onsets: even steps on-grid, odd steps + swing·step.
        let onset0 = swung.absoluteOnsetSeconds(globalStep: 0)
        let onset1 = swung.absoluteOnsetSeconds(globalStep: 1)
        let onset2 = swung.absoluteOnsetSeconds(globalStep: 2)
        check("A5: swing delays the odd 16th to the exact time",
              abs(onset0 - 0) < 1e-9 && abs(onset1 - (step + 0.6 * step)) < 1e-9 && abs(onset2 - 2 * step) < 1e-9,
              String(format: "onsets 0/1/2 = %.4f/%.4f/%.4f s (step %.4f)", onset0, onset1, onset2, step))

        // Drive the lookahead cursor across the whole bar in coarse horizon steps;
        // it must emit steps 0…N-1 once each, monotonic, matching absoluteOnset.
        var cursor = BeatScheduleCursor()
        var emitted: [BeatScheduleCursor.Onset] = []
        var horizon = 0.0
        while horizon < swung.barSeconds + 0.2 {
            horizon += 0.05
            emitted += cursor.drain(pattern: swung, upTo: horizon)
        }
        let firstBar = emitted.filter { $0.globalStep < 16 }
        var monotonic = true, exact = true
        for (i, o) in firstBar.enumerated() {
            if o.globalStep != i { exact = false }
            if abs(o.onsetSeconds - swung.absoluteOnsetSeconds(globalStep: o.globalStep)) > 1e-9 { exact = false }
            if i > 0 && o.onsetSeconds <= firstBar[i - 1].onsetSeconds { monotonic = false }
        }
        check("A5: cursor emits each step once, exact + strictly increasing",
              firstBar.count == 16 && exact && monotonic,
              "\(firstBar.count)/16 steps, exact=\(exact), monotonic=\(monotonic)")

        // Clamp validation: garbage bpm/swing/stepCount can't poison the math.
        let bad = BeatPattern(bpm: 0, swing: 5, stepCount: -3)
        check("A5: BeatPattern clamps bad bpm/swing/stepCount",
              bad.stepSeconds.isFinite && bad.stepSeconds > 0 && bad.safeSwing <= 0.75 && bad.safeStepCount >= 1,
              "stepSeconds \(String(format: "%.4f", bad.stepSeconds)), safeSwing \(bad.safeSwing), safeStepCount \(bad.safeStepCount)")

        // ---- 6. A4: live-drain silence skip keeps PTS contiguous ----
        // Feed the drain clock: silent, silent, LOUD, silent, LOUD. Silent idle
        // blocks are skipped; the two loud blocks get contiguous offsets (0, 512)
        // — no gap despite intervening silence, so the first hit isn't delayed by
        // queued silence.
        var drainClock = LiveDrainClock(silenceFloor: SamplePlaybackEngine.liveSilenceFloor)
        let n = 512
        let s0 = drainClock.admit(peak: 0.0, frames: n)       // silent → skip
        let s1 = drainClock.admit(peak: 1e-6, frames: n)      // silent → skip
        let l0 = drainClock.admit(peak: 0.5, frames: n)       // loud → offset 0
        let s2 = drainClock.admit(peak: 0.0, frames: n)       // silent → skip
        let l1 = drainClock.admit(peak: 0.4, frames: n)       // loud → offset 512
        check("A4: silent idle blocks skipped, real blocks stay PTS-contiguous",
              s0 == nil && s1 == nil && s2 == nil && l0 == 0 && l1 == Int64(n),
              "skips=[\(s0 == nil),\(s1 == nil),\(s2 == nil)] offsets=[\(l0.map(String.init) ?? "nil"),\(l1.map(String.init) ?? "nil")]")

        // ---- 7. A3: RT-safe tap handoff — engine-format frames roundtrip a ring ----
        // The tap callback only writes engine-format Float32 into a preallocated
        // PCMRingBuffer (no minting/ingest on the audio thread). Prove the handoff
        // ring roundtrips deinterleaved stereo without allocation on read.
        let handoff = PCMRingBuffer(channelCount: 2, capacityFrames: 24_000)
        let srcBuf = AVAudioPCMBuffer(pcmFormat: SamplePlaybackEngine.internalFormat, frameCapacity: 256)!
        srcBuf.frameLength = 256
        for f in 0..<256 { srcBuf.floatChannelData![0][f] = 0.3; srcBuf.floatChannelData![1][f] = -0.4 }
        handoff.write(deinterleaved: srcBuf.floatChannelData!, sourceChannelCount: 2, frameCount: 256)
        let dstBuf = AVAudioPCMBuffer(pcmFormat: SamplePlaybackEngine.internalFormat, frameCapacity: 256)!
        dstBuf.frameLength = 256
        let got = handoff.read(into: dstBuf.mutableAudioBufferList, frameCount: 256)
        let roundtrips = got == 256 && abs(dstBuf.floatChannelData![0][0] - 0.3) < 1e-6
            && abs(dstBuf.floatChannelData![1][255] - (-0.4)) < 1e-6
        check("A3: tap→worker ring roundtrips engine-format stereo", roundtrips,
              "read \(got)/256 frames, L=\(dstBuf.floatChannelData![0][0]) R=\(dstBuf.floatChannelData![1][255])")

        // ---- 8. A9: minted packet hits the ingest fast path (== internalFormat) ----
        let minter = try AudioPacketMinter(sourceID: SourceID("selftest.mint"), sampleRate: 48_000, channelCount: 2)
        let mintSrc = AVAudioPCMBuffer(pcmFormat: SamplePlaybackEngine.internalFormat, frameCapacity: 128)!
        mintSrc.frameLength = 128
        for f in 0..<128 { mintSrc.floatChannelData![0][f] = 0.2; mintSrc.floatChannelData![1][f] = 0.2 }
        var fastPath = false, mintPeak: Float = 0
        if let pkt = minter.packet(from: mintSrc, pts: .zero),
           let fd = CMSampleBufferGetFormatDescription(pkt.sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd),
           let pf = AVAudioFormat(streamDescription: asbd) {
            fastPath = (pf == SamplePlaybackEngine.internalFormat)
            let list = AVAudioPCMBuffer(pcmFormat: pf, frameCapacity: 128)
            list?.frameLength = 128
            if let list, CMSampleBufferCopyPCMDataIntoAudioBufferList(pkt.sampleBuffer, at: 0, frameCount: 128, into: list.mutableAudioBufferList) == noErr, let d = list.floatChannelData {
                for f in 0..<128 { mintPeak = max(mintPeak, abs(d[0][f])) }
            }
        }
        check("A9: minted packet format == mixer internalFormat (converter-free)",
              fastPath && abs(mintPeak - 0.2) < 1e-4,
              "fastPath=\(fastPath), roundtrip peak \(String(format: "%.3f", mintPeak))")

        // ---- 9. A10: submix soft limiter tames >1.0 polyphonic sums (1.53/1.80) ----
        // The limiter must (a) never let a sum exceed 1.0, (b) strictly reduce any
        // overshoot, and (c) pass sub-knee levels through untouched.
        let overshoots: [Float] = [1.53, 1.80, 3.0]
        let tamed = overshoots.allSatisfy { softLimit($0) <= 1.0 && softLimit($0) < $0 }
        let passthrough = softLimit(0.5) == 0.5 && softLimit(-0.5) == -0.5 && softLimit(0.85) == 0.85
        check("A10: soft limiter caps >1.0 sums at ≤1.0, passes sub-knee through",
              tamed && passthrough,
              "softLimit(1.53/1.80/3.0)=\(overshoots.map { String(format: "%.3f", softLimit($0)) }.joined(separator: "/")), 0.5→\(softLimit(0.5))")

        return SoundTestReport(checks: checks)
    }
}
