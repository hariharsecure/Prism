import Foundation
import PrismCore

/// A synthesized sound before it becomes a WAV: planar float channels + format.
struct RenderedSound {
    var channels: [[Float]]
    var sampleRate: Int
    var bitDepth: WAVFile.BitDepth
    var tags: [String]
    var name: String
    var durationSec: Double { Double(channels.first?.count ?? 0) / Double(sampleRate) }
}

/// SoundFoundry — procedural DSP synthesis of a large, categorized, royalty-free
/// sound library. No external/copyrighted samples: every sound is generated from
/// oscillators, noise and filters. Parameters are derived deterministically from
/// each sound's index (seeded `SplitMix64`), so the library is fully reproducible.
public enum SoundFoundry {
    /// Result of a generation run.
    public struct GenerationReport: Sendable, CustomStringConvertible {
        public let rootURL: URL
        public let total: Int
        public let perCategory: [(category: String, count: Int)]
        public let totalBytes: Int64
        public var description: String {
            let cats = perCategory.map { "  \($0.category): \($0.count)" }.joined(separator: "\n")
            let mb = Double(totalBytes) / 1_048_576
            return "SoundFoundry generated \(total) sounds → \(rootURL.path)\n\(cats)\n  total: "
                + String(format: "%.1f MB", mb)
        }
    }

    /// A category plan: how many to make and how to synthesize each index.
    struct CategoryPlan {
        let category: String
        let subdir: String
        let count: Int
        let make: (_ index: Int, _ rng: inout SplitMix64) -> RenderedSound
    }

    // MARK: Public API

    /// Generate the full library to `root` (default: the app-support path),
    /// writing every WAV + a `library.json` manifest. `limit` optionally caps the
    /// total number of sounds (for a fast smoke run); nil = the full ≥1000 set.
    /// `progress` is called with (done, total) periodically.
    @discardableResult
    public static func generate(to root: URL? = nil,
                                limit: Int? = nil,
                                perPlanLimit: Int? = nil,
                                progress: ((Int, Int) -> Void)? = nil) throws -> GenerationReport {
        let log = EngineLog.logger("sound.foundry")
        let rootURL = root ?? SoundLibrary.defaultRootURL
        let fm = FileManager.default
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let plans = categoryPlans()
        func planCount(_ p: CategoryPlan) -> Int { min(p.count, perPlanLimit ?? p.count) }
        let plannedTotal = plans.reduce(0) { $0 + planCount($1) }
        let target = min(limit ?? plannedTotal, plannedTotal)

        var entries: [SoundEntry] = []
        entries.reserveCapacity(target)
        var totalBytes: Int64 = 0
        var perCat: [String: Int] = [:]
        var produced = 0

        outer: for plan in plans {
            let subdirURL = rootURL.appendingPathComponent(plan.subdir, isDirectory: true)
            try fm.createDirectory(at: subdirURL, withIntermediateDirectories: true)
            for i in 0..<planCount(plan) {
                if produced >= target { break outer }
                var rng = SplitMix64(seed: fnv1a(plan.category) &+ UInt64(i) &* 0x9E37_79B9)
                let snd = plan.make(i, &rng)
                let fileName = String(format: "%@_%04d.wav", plan.subdir, i)
                let relPath = "\(plan.subdir)/\(fileName)"
                let data = WAVFile.encode(channels: snd.channels,
                                          sampleRate: snd.sampleRate, bitDepth: snd.bitDepth)
                try data.write(to: subdirURL.appendingPathComponent(fileName))
                totalBytes += Int64(data.count)
                entries.append(SoundEntry(
                    id: String(format: "%@.%04d", plan.subdir, i),
                    name: snd.name,
                    category: plan.category,
                    tags: snd.tags,
                    durationSec: (snd.durationSec * 1000).rounded() / 1000,
                    channels: snd.channels.count,
                    sampleRate: snd.sampleRate,
                    file: relPath))
                perCat[plan.category, default: 0] += 1
                produced += 1
                if produced % 100 == 0 { progress?(produced, target) }
            }
        }

        let manifest = try JSONEncoder().encodePretty(entries)
        try manifest.write(to: rootURL.appendingPathComponent("library.json"))
        progress?(produced, target)
        log.info("generated \(produced) sounds to \(rootURL.path, privacy: .public)")

        return GenerationReport(
            rootURL: rootURL,
            total: produced,
            perCategory: perCat.sorted { $0.key < $1.key }.map { ($0.key, $0.value) },
            totalBytes: totalBytes)
    }

    // MARK: Category plans (counts sum to ≥1000)

    static func categoryPlans() -> [CategoryPlan] {
        [
            // Drums — 260
            CategoryPlan(category: "drums", subdir: "kick", count: 64, make: makeKick),
            CategoryPlan(category: "drums", subdir: "snare", count: 48, make: makeSnare),
            CategoryPlan(category: "drums", subdir: "hatclosed", count: 32, make: makeHatClosed),
            CategoryPlan(category: "drums", subdir: "hatopen", count: 20, make: makeHatOpen),
            CategoryPlan(category: "drums", subdir: "clap", count: 20, make: makeClap),
            CategoryPlan(category: "drums", subdir: "tom", count: 32, make: makeTom),
            CategoryPlan(category: "drums", subdir: "perc", count: 44, make: makePerc),
            // Bass & synth tones — 150
            CategoryPlan(category: "bass", subdir: "subbass", count: 30, make: makeSubBass),
            CategoryPlan(category: "bass", subdir: "sawbass", count: 30, make: makeSawBass),
            CategoryPlan(category: "synth", subdir: "pluck", count: 30, make: makePluck),
            CategoryPlan(category: "synth", subdir: "keys", count: 30, make: makeKeys),
            CategoryPlan(category: "synth", subdir: "stab", count: 30, make: makeStab),
            // Risers / downlifters / sweeps — 120
            CategoryPlan(category: "risers", subdir: "riser", count: 40, make: makeNoiseRiser),
            CategoryPlan(category: "risers", subdir: "tonalriser", count: 25, make: makeTonalRiser),
            CategoryPlan(category: "risers", subdir: "downlifter", count: 30, make: makeDownlifter),
            CategoryPlan(category: "risers", subdir: "sweep", count: 25, make: makeSweep),
            // Impacts — 100
            CategoryPlan(category: "impacts", subdir: "boom", count: 40, make: makeBoom),
            CategoryPlan(category: "impacts", subdir: "hit", count: 30, make: makeHit),
            CategoryPlan(category: "impacts", subdir: "cinematic", count: 30, make: makeCinematic),
            // Whooshes — 100
            CategoryPlan(category: "whooshes", subdir: "whoosh", count: 60, make: makeWhoosh),
            CategoryPlan(category: "whooshes", subdir: "transition", count: 40, make: makeTransition),
            // Stingers / alerts — 120
            CategoryPlan(category: "stingers", subdir: "chordstinger", count: 40, make: makeChordStinger),
            CategoryPlan(category: "stingers", subdir: "arp", count: 40, make: makeArpStinger),
            CategoryPlan(category: "stingers", subdir: "alert", count: 40, make: makeAlert),
            // UI / beeps / blips / clicks — 80
            CategoryPlan(category: "ui", subdir: "beep", count: 30, make: makeBeep),
            CategoryPlan(category: "ui", subdir: "blip", count: 25, make: makeBlip),
            CategoryPlan(category: "ui", subdir: "click", count: 25, make: makeClick),
            // Ambiences / textures — 90
            CategoryPlan(category: "ambiences", subdir: "drone", count: 30, make: makeDrone),
            CategoryPlan(category: "ambiences", subdir: "wind", count: 15, make: makeWind),
            CategoryPlan(category: "ambiences", subdir: "rain", count: 15, make: makeRain),
            CategoryPlan(category: "ambiences", subdir: "roomtone", count: 15, make: makeRoomTone),
            CategoryPlan(category: "ambiences", subdir: "texture", count: 20, make: makeTexture),
        ]
    }

    // Shared sample rates.
    static let srDrum = 44_100
    static let srTonal = 44_100
    static let srBed = 48_000
    /// Reduced bed rate (Nyquist 16 kHz) for sustained tonal/filtered beds whose
    /// measured energy above 16 kHz is negligible (< 0.05 %, ≤ −33 dB): drone,
    /// texture, wind, tonalriser. Generating natively at 32 k (rather than
    /// resampling afterward) keeps the loopify/weld seam perfect. Broadband-noise
    /// or transient categories (rain 36.6 %, roomtone 4.35 %, riser 3.12 %,
    /// downlifter 2.19 %, whoosh, boom/cinematic impacts) KEEP 48 k — they carry
    /// real HF "air" or need transient headroom, so downsampling would be audible.
    static let srBed32 = 32_000

    // MARK: - Drums

    static func makeKick(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srDrum
        let dur = rng.range(0.18, 0.9)
        let n = Int(Double(sr) * Double(dur))
        let f0 = Double(rng.range(110, 220))
        let fEnd = Double(rng.range(38, 55))
        let pitchTau = rng.range(0.02, 0.09)
        let ampTau = rng.range(0.08, 0.45)
        let clickAmt = rng.range(0.1, 0.7)
        let drive = rng.range(1.0, 3.5)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        for k in 0..<n {
            let t = Float(k) / Float(sr)
            let f = fEnd + (f0 - fEnd) * Double(DSP.expDecay(t, pitchTau))
            phase += 2 * .pi * f / Double(sr)
            let body = Float(sin(phase)) * DSP.expDecay(t, ampTau)
            let click = (t < 0.006 ? clickAmt * rng.bipolar() * (1 - t / 0.006) : 0)
            out[k] = tanhf(drive * (body + click)) / tanhf(drive)
        }
        var ch = [out]
        applyEdgeFades(&ch, sampleRate: sr)
        normalize(&ch, to: 0.95)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["drums", "kick", "oneshot", "punchy"],
                             name: "Kick \(String(format: "%03d", i)) \(Int(f0))Hz")
    }

    static func makeSnare(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srDrum
        let dur = rng.range(0.14, 0.4)
        let n = Int(Double(sr) * Double(dur))
        let toneHz = Double(rng.range(160, 260))
        let toneTau = rng.range(0.05, 0.12)
        let noiseTau = rng.range(0.06, 0.22)
        let bright = rng.range(1800, 5500)
        var out = [Float](repeating: 0, count: n)
        var hp = OnePoleHP()
        var phase = 0.0
        for k in 0..<n {
            let t = Float(k) / Float(sr)
            phase += 2 * .pi * toneHz / Double(sr)
            let body = Float(sin(phase)) * DSP.expDecay(t, toneTau) * 0.5
            let noise = hp.process(rng.bipolar(), cutoff: Float(bright), sampleRate: Float(sr))
            out[k] = body + noise * DSP.expDecay(t, noiseTau) * 0.8
        }
        var ch = [out]
        applyEdgeFades(&ch, sampleRate: sr)
        normalize(&ch, to: 0.92)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["drums", "snare", "oneshot"],
                             name: "Snare \(String(format: "%03d", i))")
    }

    static func filteredNoiseHit(sr: Int, dur: Float, tau: Float, cutoff: Float,
                                 rng: inout SplitMix64) -> [Float] {
        let n = Int(Double(sr) * Double(dur))
        var out = [Float](repeating: 0, count: n)
        var hp = OnePoleHP()
        for k in 0..<n {
            let t = Float(k) / Float(sr)
            out[k] = hp.process(rng.bipolar(), cutoff: cutoff, sampleRate: Float(sr)) * DSP.expDecay(t, tau)
        }
        return out
    }

    static func makeHatClosed(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srDrum
        let tau = rng.range(0.015, 0.06)
        let cutoff = rng.range(6000, 11000)
        var ch = [filteredNoiseHit(sr: sr, dur: tau * 4 + 0.02, tau: tau, cutoff: cutoff, rng: &rng)]
        applyEdgeFades(&ch, sampleRate: sr, fadeMs: 1)
        normalize(&ch, to: 0.8)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["drums", "hihat", "closed", "oneshot"],
                             name: "Closed Hat \(String(format: "%03d", i))")
    }

    static func makeHatOpen(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srDrum
        let tau = rng.range(0.12, 0.5)
        let cutoff = rng.range(5500, 9500)
        var ch = [filteredNoiseHit(sr: sr, dur: tau * 3 + 0.05, tau: tau, cutoff: cutoff, rng: &rng)]
        applyEdgeFades(&ch, sampleRate: sr, fadeMs: 2)
        normalize(&ch, to: 0.8)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["drums", "hihat", "open", "oneshot"],
                             name: "Open Hat \(String(format: "%03d", i))")
    }

    static func makeClap(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srDrum
        let bursts = rng.int(3, 5)
        let spacing = rng.range(0.007, 0.014)
        let cutoff = rng.range(1200, 3200)
        let tailTau = rng.range(0.08, 0.2)
        let dur = spacing * Float(bursts) + tailTau * 3 + 0.05
        let n = Int(Double(sr) * Double(dur))
        var out = [Float](repeating: 0, count: n)
        var hp = OnePoleHP()
        for k in 0..<n {
            let t = Float(k) / Float(sr)
            var amp: Float = 0
            for b in 0..<bursts {
                let start = Float(b) * spacing
                if t >= start { amp += DSP.expDecay(t - start, 0.012) }
            }
            let tailStart = Float(bursts) * spacing
            if t >= tailStart { amp += DSP.expDecay(t - tailStart, tailTau) * 0.6 }
            out[k] = hp.process(rng.bipolar(), cutoff: cutoff, sampleRate: Float(sr)) * amp
        }
        var ch = [out]
        applyEdgeFades(&ch, sampleRate: sr)
        normalize(&ch, to: 0.9)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["drums", "clap", "oneshot"],
                             name: "Clap \(String(format: "%03d", i))")
    }

    static func makeTom(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srDrum
        let dur = rng.range(0.2, 0.6)
        let n = Int(Double(sr) * Double(dur))
        let f0 = Double(rng.range(90, 260))
        let fEnd = f0 * Double(rng.range(0.5, 0.75))
        let pitchTau = rng.range(0.05, 0.15)
        let ampTau = rng.range(0.12, 0.4)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        for k in 0..<n {
            let t = Float(k) / Float(sr)
            let f = fEnd + (f0 - fEnd) * Double(DSP.expDecay(t, pitchTau))
            phase += 2 * .pi * f / Double(sr)
            out[k] = Float(sin(phase)) * DSP.expDecay(t, ampTau)
        }
        var ch = [out]
        applyEdgeFades(&ch, sampleRate: sr)
        normalize(&ch, to: 0.92)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["drums", "tom", "oneshot"],
                             name: "Tom \(String(format: "%03d", i)) \(Int(f0))Hz")
    }

    static func makePerc(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srDrum
        let dur = rng.range(0.08, 0.35)
        let n = Int(Double(sr) * Double(dur))
        let toneHz = Double(rng.range(400, 2200))
        let toneTau = rng.range(0.02, 0.1)
        let noiseMix = rng.range(0.1, 0.6)
        let cutoff = rng.range(2000, 7000)
        var out = [Float](repeating: 0, count: n)
        var hp = OnePoleHP()
        var phase = 0.0
        for k in 0..<n {
            let t = Float(k) / Float(sr)
            phase += 2 * .pi * toneHz / Double(sr)
            let tone = Float(sin(phase)) * DSP.expDecay(t, toneTau)
            let noise = hp.process(rng.bipolar(), cutoff: Float(cutoff), sampleRate: Float(sr))
                * DSP.expDecay(t, toneTau * 0.8)
            out[k] = tone * (1 - noiseMix) + noise * noiseMix
        }
        var ch = [out]
        applyEdgeFades(&ch, sampleRate: sr, fadeMs: 1)
        normalize(&ch, to: 0.88)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["drums", "percussion", "oneshot"],
                             name: "Perc \(String(format: "%03d", i))")
    }

    // MARK: - Bass & synth

    /// Root note spread across a musical range so tones are genuinely tuned.
    static func noteName(_ midi: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[((midi % 12) + 12) % 12])\(midi / 12 - 1)"
    }

    static func makeSubBass(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srTonal
        let midi = 24 + (i % 24)   // C1 … B2
        let hz = DSP.midiToHz(Double(midi))
        let dur: Float = 1.0
        let n = Int(Double(sr) * Double(dur))
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        let sub = rng.range(0.1, 0.35)  // second-harmonic warmth
        for k in 0..<n {
            let t = Float(k) / Float(sr)
            phase += 2 * .pi * hz / Double(sr)
            let env = DSP.adsr(t, dur: dur, a: 0.005, d: 0.1, s: 0.85, r: 0.25)
            out[k] = (Float(sin(phase)) + sub * Float(sin(2 * phase))) * env
        }
        var ch = [out]
        normalize(&ch, to: 0.9)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["bass", "sub", "tone", "note:\(noteName(midi))"],
                             name: "Sub Bass \(noteName(midi))")
    }

    static func makeSawBass(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srTonal
        let midi = 28 + (i % 24)
        let hz = DSP.midiToHz(Double(midi))
        let dur: Float = 1.0
        let n = Int(Double(sr) * Double(dur))
        let detune = rng.range(0.005, 0.02)
        let cutoff = rng.range(400, 2500)
        var out = [Float](repeating: 0, count: n)
        var p1: Float = 0, p2: Float = 0
        var lp = OnePoleLP()
        for k in 0..<n {
            let t = Float(k) / Float(sr)
            p1 += Float(hz) / Float(sr); p2 += Float(hz) * (1 + detune) / Float(sr)
            let raw = (DSP.saw(p1) + DSP.saw(p2)) * 0.5
            let env = DSP.adsr(t, dur: dur, a: 0.005, d: 0.12, s: 0.8, r: 0.2)
            let fc = cutoff * (0.5 + env)  // envelope opens the filter
            out[k] = lp.process(raw, cutoff: fc, sampleRate: Float(sr)) * env
        }
        var ch = [out]
        normalize(&ch, to: 0.88)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["bass", "saw", "tone", "note:\(noteName(midi))"],
                             name: "Saw Bass \(noteName(midi))")
    }

    static func makePluck(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srTonal
        let midi = 48 + (i % 30)
        let hz = DSP.midiToHz(Double(midi))
        let dur = rng.range(0.4, 0.9)
        let n = Int(Double(sr) * Double(dur))
        let cutoff = rng.range(1200, 6000)
        var out = [Float](repeating: 0, count: n)
        var p: Float = 0
        var lp = OnePoleLP()
        for k in 0..<n {
            let t = Float(k) / Float(sr)
            p += Float(hz) / Float(sr)
            let env = DSP.expDecay(t, Float(dur) * 0.3)
            let raw = (DSP.saw(p) + DSP.square(p) * 0.3)
            out[k] = lp.process(raw, cutoff: cutoff * (0.3 + env), sampleRate: Float(sr)) * env
        }
        var ch = [out]
        applyEdgeFades(&ch, sampleRate: sr, fadeMs: 2)
        normalize(&ch, to: 0.85)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["synth", "pluck", "tone", "note:\(noteName(midi))"],
                             name: "Pluck \(noteName(midi))")
    }

    static func makeKeys(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srTonal
        let midi = 48 + (i % 30)
        let hz = DSP.midiToHz(Double(midi))
        let dur = rng.range(0.8, 1.6)
        let n = Int(Double(sr) * Double(dur))
        let modIndex = rng.range(0.5, 3.0)     // FM brightness
        let ratio = Float([1.0, 2.0, 1.5, 3.0][i % 4])
        var out = [Float](repeating: 0, count: n)
        var pc = 0.0, pm = 0.0
        for k in 0..<n {
            let t = Float(k) / Float(sr)
            pm += 2 * .pi * Double(hz) * Double(ratio) / Double(sr)
            let env = DSP.adsr(t, dur: dur, a: 0.01, d: 0.3, s: 0.6, r: Float(dur) * 0.4)
            pc += 2 * .pi * Double(hz) / Double(sr) + Double(modIndex * env) * sin(pm) * 0.01
            out[k] = Float(sin(pc)) * env
        }
        var ch = [out]
        applyEdgeFades(&ch, sampleRate: sr, fadeMs: 3)
        normalize(&ch, to: 0.82)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["synth", "keys", "fm", "tone", "note:\(noteName(midi))"],
                             name: "FM Keys \(noteName(midi))")
    }

    static func makeStab(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srTonal
        let root = 48 + (i % 12)
        let minor = (i % 2 == 0)
        let intervals = minor ? [0, 3, 7] : [0, 4, 7]
        let dur = rng.range(0.4, 0.8)
        let n = Int(Double(sr) * Double(dur))
        let cutoff = rng.range(1500, 5000)
        var chL = [Float](repeating: 0, count: n)
        var chR = [Float](repeating: 0, count: n)
        var phases = [Float](repeating: 0, count: intervals.count * 2)
        var lpL = OnePoleLP(); var lpR = OnePoleLP()
        for k in 0..<n {
            let t = Float(k) / Float(sr)
            let env = DSP.expDecay(t, Float(dur) * 0.4)
            var l: Float = 0, r: Float = 0
            for (vi, iv) in intervals.enumerated() {
                let hz = Float(DSP.midiToHz(Double(root + iv + 12)))
                phases[vi * 2] += hz / Float(sr)
                phases[vi * 2 + 1] += hz * 1.007 / Float(sr)
                l += DSP.saw(phases[vi * 2])
                r += DSP.saw(phases[vi * 2 + 1])
            }
            let g = env / Float(intervals.count)
            chL[k] = lpL.process(l * g, cutoff: cutoff * (0.4 + env), sampleRate: Float(sr))
            chR[k] = lpR.process(r * g, cutoff: cutoff * (0.4 + env), sampleRate: Float(sr))
        }
        var ch = [chL, chR]
        applyEdgeFades(&ch, sampleRate: sr, fadeMs: 3)
        normalize(&ch, to: 0.85)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["synth", "stab", "chord", minor ? "minor" : "major", "tone"],
                             name: "\(minor ? "Min" : "Maj") Stab \(noteName(root))")
    }

    // MARK: - Risers / downlifters / sweeps

    static func makeNoiseRiser(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srBed
        let dur = rng.range(1.0, 3.0)
        let n = Int(Double(sr) * Double(dur))
        let startHz = rng.range(200, 500)
        let endHz = rng.range(6000, 14000)
        let q = rng.range(2, 6)
        var chL = [Float](repeating: 0, count: n)
        var chR = [Float](repeating: 0, count: n)
        var svfL = StateVariableFilter(); var svfR = StateVariableFilter()
        for k in 0..<n {
            let p = Float(k) / Float(n)
            let cutoff = startHz * powf(endHz / startHz, p)
            let amp = p * p
            chL[k] = svfL.process(rng.bipolar(), cutoff: cutoff, q: q, sampleRate: Float(sr)).band * amp
            chR[k] = svfR.process(rng.bipolar(), cutoff: cutoff, q: q, sampleRate: Float(sr)).band * amp
        }
        var ch = [chL, chR]
        applyEdgeFades(&ch, sampleRate: sr, fadeMs: 8)
        normalize(&ch, to: 0.9)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["riser", "uplifter", "noise", "transition"],
                             name: "Noise Riser \(String(format: "%.1fs", dur))")
    }

    static func makeTonalRiser(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srBed32   // pure tonal sweep (≤3 kHz); 0.0000 % energy >16 kHz
        let dur = rng.range(1.0, 2.5)
        let n = Int(Double(sr) * Double(dur))
        let startHz = Double(rng.range(150, 300))
        let endHz = Double(rng.range(1200, 3000))
        var chL = [Float](repeating: 0, count: n)
        var chR = [Float](repeating: 0, count: n)
        var ph = 0.0
        for k in 0..<n {
            let p = Double(k) / Double(n)
            let hz = startHz * pow(endHz / startHz, p)
            ph += 2 * .pi * hz / Double(sr)
            let vib = 1 + 0.01 * sin(2 * .pi * 6 * Double(k) / Double(sr))
            let amp = Float(p)
            let s = Float(sin(ph * vib)) * amp
            chL[k] = s; chR[k] = Float(sin(ph * vib + 0.05)) * amp
        }
        var ch = [chL, chR]
        applyEdgeFades(&ch, sampleRate: sr, fadeMs: 6)
        normalize(&ch, to: 0.85)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["riser", "tonal", "uplifter", "transition"],
                             name: "Tonal Riser \(String(format: "%.1fs", dur))")
    }

    static func makeDownlifter(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srBed
        let dur = rng.range(1.0, 2.5)
        let n = Int(Double(sr) * Double(dur))
        let startHz = rng.range(6000, 12000)
        let endHz = rng.range(150, 400)
        let q = rng.range(2, 5)
        var chL = [Float](repeating: 0, count: n)
        var chR = [Float](repeating: 0, count: n)
        var svfL = StateVariableFilter(); var svfR = StateVariableFilter()
        for k in 0..<n {
            let p = Float(k) / Float(n)
            let cutoff = startHz * powf(endHz / startHz, p)
            let amp = 1 - p * 0.7
            chL[k] = svfL.process(rng.bipolar(), cutoff: cutoff, q: q, sampleRate: Float(sr)).band * amp
            chR[k] = svfR.process(rng.bipolar(), cutoff: cutoff, q: q, sampleRate: Float(sr)).band * amp
        }
        var ch = [chL, chR]
        applyEdgeFades(&ch, sampleRate: sr, fadeMs: 8)
        normalize(&ch, to: 0.9)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["downlifter", "downer", "noise", "transition"],
                             name: "Downlifter \(String(format: "%.1fs", dur))")
    }

    static func makeSweep(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srBed
        let dur = rng.range(0.8, 2.0)
        let n = Int(Double(sr) * Double(dur))
        let up = (i % 2 == 0)
        let lo = rng.range(300, 800), hi = rng.range(4000, 10000)
        var chL = [Float](repeating: 0, count: n)
        var chR = [Float](repeating: 0, count: n)
        var svfL = StateVariableFilter(); var svfR = StateVariableFilter()
        var pink = PinkNoise()
        for k in 0..<n {
            let p = Float(k) / Float(n)
            let frac = up ? p : (1 - p)
            let cutoff = lo * powf(hi / lo, frac)
            let amp = sinf(.pi * p)  // fade in + out
            let src = pink.process(rng.bipolar())
            chL[k] = svfL.process(src, cutoff: cutoff, q: 3, sampleRate: Float(sr)).band * amp
            chR[k] = svfR.process(src, cutoff: cutoff * 1.03, q: 3, sampleRate: Float(sr)).band * amp
        }
        var ch = [chL, chR]
        normalize(&ch, to: 0.85)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["sweep", up ? "up" : "down", "noise", "transition"],
                             name: "Sweep \(up ? "Up" : "Down") \(String(format: "%03d", i))")
    }

    // MARK: - Impacts

    static func makeImpactCore(sr: Int, boomHz: Double, boomTau: Float, tailTau: Float,
                               bright: Float, dur: Float, rng: inout SplitMix64) -> [[Float]] {
        let n = Int(Double(sr) * Double(dur))
        var chL = [Float](repeating: 0, count: n)
        var chR = [Float](repeating: 0, count: n)
        var phase = 0.0
        var lpL = OnePoleLP(); var lpR = OnePoleLP()
        for k in 0..<n {
            let t = Float(k) / Float(sr)
            phase += 2 * .pi * boomHz / Double(sr)
            let boom = Float(sin(phase)) * DSP.expDecay(t, boomTau)
            let transient = t < 0.004 ? rng.bipolar() * (1 - t / 0.004) : 0
            let tailL = lpL.process(rng.bipolar(), cutoff: bright, sampleRate: Float(sr)) * DSP.expDecay(t, tailTau) * 0.5
            let tailR = lpR.process(rng.bipolar(), cutoff: bright, sampleRate: Float(sr)) * DSP.expDecay(t, tailTau) * 0.5
            chL[k] = boom + transient + tailL
            chR[k] = boom + transient + tailR
        }
        var ch = [chL, chR]
        applyEdgeFades(&ch, sampleRate: sr, fadeMs: 4)
        normalize(&ch, to: 0.95)
        return ch
    }

    static func makeBoom(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srBed
        let dur = rng.range(0.6, 1.8)
        let ch = makeImpactCore(sr: sr, boomHz: Double(rng.range(45, 80)),
                                boomTau: rng.range(0.15, 0.5), tailTau: rng.range(0.15, 0.5),
                                bright: rng.range(600, 2000), dur: dur, rng: &rng)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["impact", "boom", "sub", "oneshot"],
                             name: "Boom \(String(format: "%03d", i))")
    }

    static func makeHit(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srBed
        let dur = rng.range(0.3, 0.9)
        let ch = makeImpactCore(sr: sr, boomHz: Double(rng.range(80, 160)),
                                boomTau: rng.range(0.08, 0.25), tailTau: rng.range(0.1, 0.3),
                                bright: rng.range(2000, 6000), dur: dur, rng: &rng)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["impact", "hit", "oneshot"],
                             name: "Hit \(String(format: "%03d", i))")
    }

    static func makeCinematic(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srBed
        let dur = rng.range(1.5, 3.5)
        let ch = makeImpactCore(sr: sr, boomHz: Double(rng.range(38, 60)),
                                boomTau: rng.range(0.4, 1.0), tailTau: rng.range(0.6, 1.6),
                                bright: rng.range(400, 1200), dur: dur, rng: &rng)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["impact", "cinematic", "boom", "trailer", "oneshot"],
                             name: "Cinematic Impact \(String(format: "%03d", i))")
    }

    // MARK: - Whooshes

    static func makeWhoosh(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srBed
        let dur = rng.range(0.5, 1.6)
        let n = Int(Double(sr) * Double(dur))
        let centreLo = rng.range(500, 1500), centreHi = rng.range(2500, 7000)
        let q = rng.range(1.5, 4)
        let leftToRight = (i % 2 == 0)
        var chL = [Float](repeating: 0, count: n)
        var chR = [Float](repeating: 0, count: n)
        var svf = StateVariableFilter()
        var pink = PinkNoise()
        for k in 0..<n {
            let p = Float(k) / Float(n)
            let cutoff = centreLo + (centreHi - centreLo) * sinf(.pi * p)
            let amp = sinf(.pi * p)
            let mono = svf.process(pink.process(rng.bipolar()), cutoff: cutoff, q: q, sampleRate: Float(sr)).band * amp
            let pan = leftToRight ? p : (1 - p)   // 0 = left, 1 = right
            chL[k] = mono * (1 - pan)
            chR[k] = mono * pan
        }
        var ch = [chL, chR]
        normalize(&ch, to: 0.9)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["whoosh", "transition", leftToRight ? "pan-lr" : "pan-rl"],
                             name: "Whoosh \(leftToRight ? "L→R" : "R→L") \(String(format: "%03d", i))")
    }

    static func makeTransition(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srBed
        let dur = rng.range(0.6, 1.4)
        let n = Int(Double(sr) * Double(dur))
        let cutoff = rng.range(1500, 6000)
        var chL = [Float](repeating: 0, count: n)
        var chR = [Float](repeating: 0, count: n)
        var hpL = OnePoleHP(); var hpR = OnePoleHP()
        for k in 0..<n {
            let p = Float(k) / Float(n)
            // Reverse-swell into a soft tail: amp rises then a quick drop.
            let amp = p < 0.85 ? p / 0.85 : (1 - (p - 0.85) / 0.15)
            chL[k] = hpL.process(rng.bipolar(), cutoff: cutoff, sampleRate: Float(sr)) * amp
            chR[k] = hpR.process(rng.bipolar(), cutoff: cutoff * 1.05, sampleRate: Float(sr)) * amp
        }
        var ch = [chL, chR]
        applyEdgeFades(&ch, sampleRate: sr, fadeMs: 4)
        normalize(&ch, to: 0.85)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["transition", "swell", "noise"],
                             name: "Transition \(String(format: "%03d", i))")
    }

    // MARK: - Stingers / alerts

    static func bell(_ hz: Double, sr: Int, dur: Float, partials: Int, rng: inout SplitMix64) -> [Float] {
        let n = Int(Double(sr) * Double(dur))
        var out = [Float](repeating: 0, count: n)
        let ratios: [Float] = [1, 2.01, 3.0, 4.2, 5.4]
        var phases = [Double](repeating: 0, count: partials)
        for k in 0..<n {
            let t = Float(k) / Float(sr)
            var s: Float = 0
            for pi in 0..<partials {
                phases[pi] += 2 * .pi * hz * Double(ratios[pi % ratios.count]) / Double(sr)
                s += Float(sin(phases[pi])) * DSP.expDecay(t, Float(dur) * (0.5 / Float(pi + 1))) / Float(pi + 1)
            }
            out[k] = s
        }
        return out
    }

    static func makeChordStinger(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srTonal
        let root = 60 + (i % 12)
        let minor = (i % 3 == 0)
        let intervals = minor ? [0, 3, 7, 12] : [0, 4, 7, 12]
        let dur = rng.range(1.0, 2.2)
        let n = Int(Double(sr) * Double(dur))
        var mix = [Float](repeating: 0, count: n)
        for iv in intervals {
            let voice = bell(DSP.midiToHz(Double(root + iv)), sr: sr, dur: Float(dur), partials: 4, rng: &rng)
            for k in 0..<n { mix[k] += voice[k] }
        }
        var chL = mix, chR = mix
        // Tiny stereo widen.
        for k in 1..<n { chR[k] = mix[k - 1] }
        var ch = [chL, chR]
        applyEdgeFades(&ch, sampleRate: sr, fadeMs: 4)
        normalize(&ch, to: 0.85)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["stinger", "chord", "bell", minor ? "minor" : "major", "notification"],
                             name: "\(minor ? "Min" : "Maj") Chord Stinger \(noteName(root))")
    }

    static func makeArpStinger(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srTonal
        let root = 60 + (i % 12)
        let major = (i % 2 == 0)
        let scale = major ? [0, 4, 7, 12] : [0, 3, 7, 12]
        let noteDur = rng.range(0.09, 0.16)
        let ring = rng.range(0.25, 0.5)
        let count = scale.count
        let n = Int(Double(sr) * (Double(noteDur) * Double(count) + Double(ring)))
        var out = [Float](repeating: 0, count: n)
        for (ni, iv) in scale.enumerated() {
            let start = Int(Double(sr) * Double(noteDur) * Double(ni))
            let hz = DSP.midiToHz(Double(root + iv + 12))
            var phase = 0.0
            for k in start..<n {
                let t = Float(k - start) / Float(sr)
                phase += 2 * .pi * hz / Double(sr)
                out[k] += (Float(sin(phase)) + 0.3 * Float(sin(2 * phase))) * DSP.expDecay(t, ring)
            }
        }
        // Dual-mono (L==R exactly): store a single channel (half size, bit-identical
        // playback). Measured L/R correlation 1.0000, arrays equal.
        var ch = [out]
        applyEdgeFades(&ch, sampleRate: sr, fadeMs: 3)
        normalize(&ch, to: 0.85)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["stinger", "arp", "melodic", major ? "major" : "minor", "notification"],
                             name: "\(major ? "Maj" : "Min") Arp \(noteName(root))")
    }

    static func makeAlert(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srTonal
        let root = 66 + (i % 10)
        let up = (i % 2 == 0)
        let interval = [4, 5, 7][i % 3]
        let notes = up ? [root, root + interval] : [root + interval, root]
        let noteDur = rng.range(0.1, 0.16)
        let n = Int(Double(sr) * (Double(noteDur) * Double(notes.count) + 0.12))
        var out = [Float](repeating: 0, count: n)
        for (ni, m) in notes.enumerated() {
            let start = Int(Double(sr) * Double(noteDur) * Double(ni))
            let end = min(n, start + Int(Double(sr) * (Double(noteDur) + 0.1)))
            let hz = DSP.midiToHz(Double(m))
            var phase = 0.0
            for k in start..<end {
                let t = Float(k - start) / Float(sr)
                phase += 2 * .pi * hz / Double(sr)
                let env = DSP.adsr(t, dur: Float(noteDur) + 0.09, a: 0.005, d: 0.03, s: 0.7, r: 0.06)
                out[k] += (Float(sin(phase)) * 0.7 + DSP.square(Float(phase) / (2 * .pi)) * 0.15) * env
            }
        }
        // Dual-mono (L==R exactly): store a single channel. Transparent — mono plays
        // identically on both outputs; the previous stereo file just duplicated bytes.
        var ch = [out]
        applyEdgeFades(&ch, sampleRate: sr, fadeMs: 2)
        normalize(&ch, to: 0.8)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["alert", "notification", up ? "up" : "down", "ui"],
                             name: "Alert \(up ? "Up" : "Down") \(String(format: "%03d", i))")
    }

    // MARK: - UI / beeps / blips / clicks

    static func makeBeep(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srTonal
        let hz = Double(rng.range(500, 2000))
        let dur = rng.range(0.08, 0.25)
        let n = Int(Double(sr) * Double(dur))
        let wave = i % 3
        var out = [Float](repeating: 0, count: n)
        var phase: Float = 0
        for k in 0..<n {
            let t = Float(k) / Float(sr)
            phase += Float(hz) / Float(sr)
            let osc = wave == 0 ? sinf(2 * .pi * phase) : (wave == 1 ? DSP.square(phase) : DSP.triangle(phase))
            out[k] = osc * DSP.adsr(t, dur: Float(dur), a: 0.004, d: 0.02, s: 0.8, r: 0.03)
        }
        var ch = [out]
        applyEdgeFades(&ch, sampleRate: sr, fadeMs: 2)
        normalize(&ch, to: 0.8)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["ui", "beep", "tone"],
                             name: "Beep \(Int(hz))Hz")
    }

    static func makeBlip(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srTonal
        let hz0 = Double(rng.range(400, 1200))
        let hz1 = hz0 * Double(rng.range(1.5, 3.0))
        let dur = rng.range(0.04, 0.12)
        let n = Int(Double(sr) * Double(dur))
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        for k in 0..<n {
            let p = Double(k) / Double(n)
            let hz = hz0 + (hz1 - hz0) * p
            phase += 2 * .pi * hz / Double(sr)
            out[k] = Float(sin(phase)) * DSP.expDecay(Float(k) / Float(sr), Float(dur) * 0.5)
        }
        var ch = [out]
        applyEdgeFades(&ch, sampleRate: sr, fadeMs: 1)
        normalize(&ch, to: 0.8)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["ui", "blip", "tone"],
                             name: "Blip \(String(format: "%03d", i))")
    }

    static func makeClick(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srTonal
        let dur = rng.range(0.01, 0.05)
        let n = Int(Double(sr) * Double(dur))
        let toneHz = Double(rng.range(1000, 4000))
        let noiseMix = rng.range(0.3, 0.9)
        var out = [Float](repeating: 0, count: n)
        var hp = OnePoleHP()
        var phase = 0.0
        for k in 0..<n {
            let t = Float(k) / Float(sr)
            phase += 2 * .pi * toneHz / Double(sr)
            let env = DSP.expDecay(t, Float(dur) * 0.3)
            let tone = Float(sin(phase)) * env
            let noise = hp.process(rng.bipolar(), cutoff: 3000, sampleRate: Float(sr)) * env
            out[k] = tone * (1 - noiseMix) + noise * noiseMix
        }
        var ch = [out]
        applyEdgeFades(&ch, sampleRate: sr, fadeMs: 0.5)
        normalize(&ch, to: 0.8)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["ui", "click", "tick"],
                             name: "Click \(String(format: "%03d", i))")
    }

    // MARK: - Ambiences / textures (loopable)

    static func makeDrone(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srBed32   // tonal partials + 800 Hz-LP noise; 0.0138 % energy >16 kHz
        let dur: Float = rng.range(5, 8)
        let n = Int(Double(sr) * Double(dur))
        let root = DSP.midiToHz(Double(36 + (i % 12)))
        let partials = [1.0, 1.5, 2.0, 3.0]
        let detunes = [1.0, 1.004, 0.996, 1.008]
        var chL = [Float](repeating: 0, count: n)
        var chR = [Float](repeating: 0, count: n)
        var phL = [Double](repeating: 0, count: partials.count)
        var phR = [Double](repeating: 0, count: partials.count)
        let lfoHz = Double(rng.range(0.1, 0.4))
        var lp = OnePoleLP()
        for k in 0..<n {
            let lfo = 0.7 + 0.3 * sin(2 * .pi * lfoHz * Double(k) / Double(sr))
            var l: Float = 0, r: Float = 0
            for (pi, mult) in partials.enumerated() {
                phL[pi] += 2 * .pi * root * mult / Double(sr)
                phR[pi] += 2 * .pi * root * mult * detunes[pi] / Double(sr)
                l += Float(sin(phL[pi])) / Float(pi + 1)
                r += Float(sin(phR[pi])) / Float(pi + 1)
            }
            let noise = lp.process(rng.bipolar(), cutoff: 800, sampleRate: Float(sr)) * 0.15
            chL[k] = (l * 0.3 + noise) * Float(lfo)
            chR[k] = (r * 0.3 + noise) * Float(lfo)
        }
        var ch = loopify([chL, chR], sampleRate: sr)
        normalize(&ch, to: 0.7)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["ambience", "drone", "loop", "loopable", "bed", "pad"],
                             name: "Drone \(noteName(36 + (i % 12)))")
    }

    static func makeWind(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srBed32   // LP-noise bed (cutoff ≤1.8 kHz); 0.0297 % energy >16 kHz
        let dur: Float = rng.range(5, 8)
        let n = Int(Double(sr) * Double(dur))
        var chL = [Float](repeating: 0, count: n)
        var chR = [Float](repeating: 0, count: n)
        var svfL = StateVariableFilter(); var svfR = StateVariableFilter()
        let lfoHz = Double(rng.range(0.15, 0.5))
        for k in 0..<n {
            let mod = 0.5 + 0.5 * sin(2 * .pi * lfoHz * Double(k) / Double(sr))
            let cutoff = Float(400 + 1400 * mod)
            let amp = Float(0.4 + 0.6 * mod)
            chL[k] = svfL.process(rng.bipolar(), cutoff: cutoff, q: 1.5, sampleRate: Float(sr)).low * amp
            chR[k] = svfR.process(rng.bipolar(), cutoff: cutoff * 0.95, q: 1.5, sampleRate: Float(sr)).low * amp
        }
        var ch = loopify([chL, chR], sampleRate: sr)
        normalize(&ch, to: 0.75)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["ambience", "wind", "loop", "loopable", "texture", "nature"],
                             name: "Wind \(String(format: "%03d", i))")
    }

    static func makeRain(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srBed
        let dur: Float = rng.range(5, 8)
        let n = Int(Double(sr) * Double(dur))
        var chL = [Float](repeating: 0, count: n)
        var chR = [Float](repeating: 0, count: n)
        var hpL = OnePoleHP(); var hpR = OnePoleHP()
        let density = rng.range(0.15, 0.4)
        for k in 0..<n {
            // Steady filtered-noise bed + sparse high droplets.
            let bedL = hpL.process(rng.bipolar(), cutoff: 1500, sampleRate: Float(sr)) * 0.25
            let bedR = hpR.process(rng.bipolar(), cutoff: 1600, sampleRate: Float(sr)) * 0.25
            let drop = rng.unit() < density * 0.01 ? rng.bipolar() * 0.6 : 0
            chL[k] = bedL + drop
            chR[k] = bedR + drop * 0.8
        }
        var ch = loopify([chL, chR], sampleRate: sr)
        normalize(&ch, to: 0.75)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["ambience", "rain", "loop", "loopable", "texture", "nature"],
                             name: "Rain \(String(format: "%03d", i))")
    }

    static func makeRoomTone(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srBed
        let dur: Float = rng.range(5, 8)
        let n = Int(Double(sr) * Double(dur))
        var chL = [Float](repeating: 0, count: n)
        var chR = [Float](repeating: 0, count: n)
        var pinkL = PinkNoise(); var pinkR = PinkNoise()
        let humHz = Double([50.0, 60.0][i % 2])
        for k in 0..<n {
            let hum = Float(sin(2 * .pi * humHz * Double(k) / Double(sr))) * 0.02
            chL[k] = pinkL.process(rng.bipolar()) * 0.3 + hum
            chR[k] = pinkR.process(rng.bipolar()) * 0.3 + hum
        }
        var ch = loopify([chL, chR], sampleRate: sr)
        normalize(&ch, to: 0.5)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["ambience", "roomtone", "loop", "loopable", "background", "\(Int(humHz))hz"],
                             name: "Room Tone \(Int(humHz))Hz \(String(format: "%03d", i))")
    }

    static func makeTexture(_ i: Int, _ rng: inout SplitMix64) -> RenderedSound {
        let sr = srBed32   // FM sine bed (carrier ≤0.5 kHz); 0.0000 % energy >16 kHz
        let dur: Float = rng.range(5, 8)
        let n = Int(Double(sr) * Double(dur))
        let carrier = DSP.midiToHz(Double(48 + (i % 12)))
        let ratio = Double([1.41, 2.0, 2.76, 3.5][i % 4])
        var chL = [Float](repeating: 0, count: n)
        var chR = [Float](repeating: 0, count: n)
        var pc = 0.0, pm = 0.0
        let lfoHz = Double(rng.range(0.08, 0.3))
        for k in 0..<n {
            let modDepth = 2.0 * (0.5 + 0.5 * sin(2 * .pi * lfoHz * Double(k) / Double(sr)))
            pm += 2 * .pi * carrier * ratio / Double(sr)
            pc += 2 * .pi * carrier / Double(sr) + modDepth * sin(pm) * 0.008
            let s = Float(sin(pc))
            chL[k] = s * 0.5
            chR[k] = Float(sin(pc + 0.1)) * 0.5
        }
        var ch = loopify([chL, chR], sampleRate: sr)
        normalize(&ch, to: 0.6)
        return RenderedSound(channels: ch, sampleRate: sr, bitDepth: .pcm16,
                             tags: ["ambience", "texture", "loop", "loopable", "fm", "evolving"],
                             name: "Texture \(String(format: "%03d", i))")
    }
}

// Pretty JSON helper (stable key ordering for a reviewable manifest).
extension JSONEncoder {
    func encodePretty<T: Encodable>(_ value: T) throws -> Data {
        outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encode(value)
    }
}
