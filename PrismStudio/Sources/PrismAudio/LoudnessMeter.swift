import Foundation
import PrismCore
import os

/// ITU-R BS.1770-4 / EBU R128 loudness meter (DESIGN.md §2.4 — "peak + **LUFS**
/// meters", v1). Ingests the master program PCM (deinterleaved Float32) and
/// exposes momentary (400 ms), short-term (3 s) and gated integrated loudness
/// in LUFS, plus oversampled true-peak in dBTP.
///
/// DSP:
/// - **K-weighting** (BS.1770): two cascaded biquads per channel — a high-shelf
///   "head" pre-filter (~+4 dB above ~1.5 kHz) followed by an RLB high-pass
///   (~38 Hz). Coefficients are the standard 48 kHz set; other rates reuse them
///   (a stated approximation — the mixer master is 48 kHz).
/// - **Blocks & gating**: mean-square of the K-weighted signal is accumulated
///   in 100 ms blocks. Momentary = last 4 blocks (400 ms); short-term = last 30
///   blocks (3 s). Integrated aggregates 400 ms gating blocks hopping every
///   100 ms (75 % overlap) under the two-stage gate: absolute −70 LUFS, then a
///   relative gate 10 LU below the ungated mean.
/// - **Channel summing**: loudness = −0.691 + 10·log10(Σ Gᵢ·zᵢ), where zᵢ is
///   the per-channel K-weighted mean-square over the window and Gᵢ is the
///   BS.1770 channel weight *by role*: front L/R/C = 1.0, LFE **excluded**
///   (weight 0), surround Ls/Rs = 1.41 (≈ +1.5 dB). Channels are mapped to
///   roles by index under the ITU/AAC order assumption L, R, C, LFE, Ls, Rs
///   (see `bs1770Weights`); the mixer master is stereo today, so only L/R are
///   exercised live and stereo is exactly (1.0, 1.0).
/// - **True-peak**: 4× polyphase-FIR oversampling per channel; the running max
///   |sample| across the whole session is reported as dBTP.
///
/// Threading: `process(...)` runs on the mixer's single tap-delivery thread.
/// The K-weighting filter / block-accumulation state it mutates is guarded by
/// `stateLock` (uncontended in steady state) purely so `reset()` can safely
/// clear it from another thread without racing an in-flight `process`. The tiny
/// shared block-history / integrated histogram / published peak live under
/// `shared` so `measurement` can be read from any thread without ever doing
/// session-length O(n) work under that lock.
public final class LoudnessMeter: @unchecked Sendable {
    /// A loudness snapshot. LUFS fields are `-.infinity` when there is no
    /// qualifying audio (silence / below the absolute gate).
    public struct Measurement: Sendable, CustomStringConvertible {
        public let momentary: Double  // LUFS, 400 ms
        public let shortTerm: Double  // LUFS, 3 s
        public let integrated: Double // LUFS, gated
        public let truePeak: Double   // dBTP (session max)
        public var description: String {
            String(format: "M %.1f  S %.1f  I %.1f LUFS · TP %.1f dBTP",
                   momentary, shortTerm, integrated, truePeak)
        }
    }

    private let sampleRate: Double
    private let channelCount: Int
    private let log = EngineLog.logger("audio.loudness")

    // K-weighting: two biquads per channel + per-100ms block accumulation.
    // Mutated only by `process` (single tap thread), but guarded by `stateLock`
    // so `reset()` can clear it concurrently without a data race (C7).
    private var stage1: [Biquad]
    private var stage2: [Biquad]
    private var peakers: [TruePeakOversampler]
    private let blockFrames: Int
    private var blockSumSq: [Double]  // per channel
    private var blockFill: Int = 0
    private let stateLock = OSAllocatedUnfairLock(initialState: ())

    // BS.1770 channel weights by role (see `bs1770Weights`). Sized to channelCount.
    private let channelGains: [Double]

    // Shared history (guarded). The integrated measure uses a *bounded*
    // histogram of 400 ms gating-block loudness rather than an unbounded list
    // (C6): O(1) to update on the tap thread, O(bins) — never O(session) — to
    // read, so `measurement` never holds the lock for session-length work.
    private struct Shared {
        var recentBlockPower: [Double] = []   // ring of last ≤30 block powers (Σ Gᵢ·meanSqᵢ)
        var integratedHist = [Int](repeating: 0, count: LoudnessMeter.histBinCount)
        var truePeakLinear: Float = 0
    }
    private let shared = OSAllocatedUnfairLock<Shared>(initialState: Shared())
    private static let shortTermBlocks = 30 // 3 s / 100 ms
    private static let momentaryBlocks = 4  // 400 ms / 100 ms

    // Integrated-loudness histogram bounds. Gating blocks are binned by their
    // loudness in [gateFloorLUFS, gateCeilLUFS] at `binsPerLU` resolution; the
    // absolute −70 LUFS gate is the floor so anything below it is simply never
    // binned. Fixed size ⇒ bounded memory + bounded lock-hold for any session.
    private static let gateFloorLUFS = -70.0
    private static let gateCeilLUFS = 30.0   // loud blocks clamp into the top bin
    private static let binsPerLU = 10.0      // 0.1 LU resolution (≈ libebur128)
    static let histBinCount = Int((gateCeilLUFS - gateFloorLUFS) * binsPerLU) + 1

    public init(sampleRate: Double = 48_000, channelCount: Int = 2) {
        self.sampleRate = sampleRate
        self.channelCount = max(channelCount, 1)
        self.blockFrames = max(Int((sampleRate * 0.1).rounded()), 1)
        self.stage1 = (0..<self.channelCount).map { _ in Biquad(Biquad.kWeightStage1) }
        self.stage2 = (0..<self.channelCount).map { _ in Biquad(Biquad.kWeightStage2) }
        self.peakers = (0..<self.channelCount).map { _ in TruePeakOversampler() }
        self.blockSumSq = [Double](repeating: 0, count: self.channelCount)
        self.channelGains = Self.bs1770Weights(channelCount: self.channelCount)
    }

    /// BS.1770 channel weights by role, under the ITU/AAC channel-order
    /// assumption `L, R, C, LFE, Ls, Rs, …`: front L/R/C = 1.0, LFE **excluded**
    /// (weight 0, never contributes to loudness), surround Ls/Rs (and any
    /// further surround channels) = 1.41 (≈ +1.5 dB). Mono is a single 1.0
    /// channel; stereo is exactly (1.0, 1.0).
    static func bs1770Weights(channelCount: Int) -> [Double] {
        // index → weight in ITU/AAC order; indices past the table are treated
        // as additional surround channels (1.41).
        let byRole: [Double] = [1.0, 1.0, 1.0, 0.0, 1.41, 1.41]
        return (0..<max(channelCount, 1)).map { $0 < byRole.count ? byRole[$0] : 1.41 }
    }

    /// Reset all metering state (filters, blocks, integrated histogram, peak).
    /// Safe to call concurrently with `process` — the DSP state is cleared under
    /// `stateLock` (the same lock `process` holds while mutating it), the shared
    /// history under `shared` (C7).
    public func reset() {
        stateLock.withLock {
            for i in 0..<channelCount { stage1[i].reset(); stage2[i].reset(); peakers[i].reset() }
            for i in 0..<channelCount { blockSumSq[i] = 0 }
            blockFill = 0
        }
        shared.withLock { $0 = Shared() }
    }

    /// Ingest one buffer of deinterleaved Float32 (as delivered by the mixer's
    /// master tap `AVAudioPCMBuffer.floatChannelData`). Extra channels beyond
    /// the meter's configured count are ignored.
    public func process(_ data: UnsafePointer<UnsafeMutablePointer<Float>>,
                        channelCount incoming: Int, frameCount: Int) {
        let ch = min(incoming, channelCount)
        guard ch > 0, frameCount > 0 else { return }

        // DSP + block accumulation under stateLock so a concurrent reset() can't
        // race the filter/accumulator state (C7). Single tap thread ⇒ the lock
        // is uncontended except during reset. No allocation on this path.
        let (completed, localPeak): ([Double], Float) = stateLock.withLockUnchecked {
            var completed: [Double] = []
            var localPeak: Float = 0
            for f in 0..<frameCount {
                for c in 0..<ch {
                    let x = Double(data[c][f])
                    localPeak = max(localPeak, peakers[c].maxAbs(pushing: x))
                    let k = stage2[c].process(stage1[c].process(x))
                    blockSumSq[c] += k * k
                }
                blockFill += 1
                if blockFill == blockFrames {
                    var power = 0.0
                    for c in 0..<ch {
                        power += channelGains[c] * (blockSumSq[c] / Double(blockFrames))
                        blockSumSq[c] = 0
                    }
                    completed.append(power)
                    blockFill = 0
                }
            }
            return (completed, localPeak)
        }

        guard !completed.isEmpty || localPeak > 0 else { return }
        let completedBlocks = completed
        let peakToMerge = localPeak
        shared.withLock { s in
            for p in completedBlocks {
                s.recentBlockPower.append(p)
                if s.recentBlockPower.count > Self.shortTermBlocks {
                    s.recentBlockPower.removeFirst(s.recentBlockPower.count - Self.shortTermBlocks)
                }
                // Form a 400 ms gating block from the last 4 100 ms blocks
                // (hops 100 ms → 75 % overlap) and fold it into the integrated
                // histogram — O(1), bounded, so history never grows unbounded
                // and `measurement` never re-scans a session-length list (C6).
                let n = s.recentBlockPower.count
                if n >= Self.momentaryBlocks {
                    let gate = s.recentBlockPower[(n - Self.momentaryBlocks)...].reduce(0, +)
                        / Double(Self.momentaryBlocks)
                    Self.addGateBlock(power: gate, to: &s.integratedHist)
                }
            }
            if peakToMerge > s.truePeakLinear { s.truePeakLinear = peakToMerge }
        }
    }

    /// Current loudness + true-peak snapshot. Copies the small bounded state out
    /// under the lock, then does the loudness math *outside* it, so the tap
    /// thread never contends on session-length work (C6).
    public var measurement: Measurement {
        let (recent, hist, peakLinear) = shared.withLock { s in
            (s.recentBlockPower, s.integratedHist, s.truePeakLinear)
        }
        let momentary = Self.loudness(ofLast: Self.momentaryBlocks, in: recent)
        let shortTerm = Self.loudness(ofLast: Self.shortTermBlocks, in: recent)
        let integrated = Self.integratedLoudness(hist: hist)
        let tp = peakLinear > 0 ? 20 * log10(Double(peakLinear)) : -.infinity
        return Measurement(momentary: momentary, shortTerm: shortTerm,
                           integrated: integrated, truePeak: tp)
    }

    // MARK: - Loudness math

    private static let absoluteOffset = -0.691 // BS.1770 loudness normalization

    private static func loudness(power: Double) -> Double {
        power > 0 ? absoluteOffset + 10 * log10(power) : -.infinity
    }

    /// Inverse of `loudness(power:)`: the block power for a loudness value.
    private static func power(forLoudness l: Double) -> Double {
        pow(10, (l - absoluteOffset) / 10)
    }

    /// Bin one 400 ms gating block into the integrated histogram by its loudness.
    /// Blocks below the absolute −70 LUFS gate (the histogram floor) are dropped;
    /// louder-than-ceiling blocks clamp into the top bin. O(1).
    private static func addGateBlock(power p: Double, to hist: inout [Int]) {
        let l = loudness(power: p)
        guard l.isFinite, l >= gateFloorLUFS else { return }
        var bin = Int((l - gateFloorLUFS) * binsPerLU)
        if bin < 0 { bin = 0 }
        if bin >= histBinCount { bin = histBinCount - 1 }
        hist[bin] += 1
    }

    /// Representative power at the centre of histogram bin `bin`.
    private static func binCenterPower(_ bin: Int) -> Double {
        power(forLoudness: gateFloorLUFS + (Double(bin) + 0.5) / binsPerLU)
    }

    private static func loudness(ofLast n: Int, in blocks: [Double]) -> Double {
        guard !blocks.isEmpty else { return -.infinity }
        let slice = blocks.suffix(n)
        let mean = slice.reduce(0, +) / Double(slice.count)
        return loudness(power: mean)
    }

    /// Two-stage gated integration (BS.1770 §5), computed from the bounded
    /// gating-block histogram. The absolute −70 LUFS gate is the histogram floor
    /// (sub-gate blocks were never binned), so stage 1 is the mean power of all
    /// binned blocks; the relative gate keeps bins ≥ 10 LU below that mean.
    /// O(bins), never O(session). Bin quantisation is 0.1 LU (≪ the ±1 LU test
    /// tolerance and imperceptible in practice).
    private static func integratedLoudness(hist: [Int]) -> Double {
        // Stage 1: mean power over every binned (already ≥ −70 LUFS) block.
        var sumPower = 0.0, count = 0
        for bin in 0..<hist.count where hist[bin] > 0 {
            sumPower += Double(hist[bin]) * binCenterPower(bin)
            count += hist[bin]
        }
        guard count > 0 else { return -.infinity }
        let mean1 = sumPower / Double(count)

        // Stage 2: relative gate 10 LU below the stage-1 mean loudness.
        let relLoudness = loudness(power: mean1) - 10
        let relFloorBin = max(0, Int(((relLoudness - gateFloorLUFS) * binsPerLU).rounded(.up)))
        var sumPower2 = 0.0, count2 = 0
        for bin in relFloorBin..<hist.count where hist[bin] > 0 {
            sumPower2 += Double(hist[bin]) * binCenterPower(bin)
            count2 += hist[bin]
        }
        guard count2 > 0 else { return -.infinity }
        return loudness(power: sumPower2 / Double(count2))
    }
}

// MARK: - Biquad (Direct Form I)

/// A single biquad section, Direct Form I, `a0` normalized to 1.
/// `y = b0·x + b1·x1 + b2·x2 − a1·y1 − a2·y2`.
struct Biquad {
    struct Coefficients { let b0, b1, b2, a1, a2: Double }

    // Standard BS.1770 K-weighting coefficients @ 48 kHz.
    static let kWeightStage1 = Coefficients(
        b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
        a1: -1.69065929318241, a2: 0.73248077421585) // "head" high-shelf
    static let kWeightStage2 = Coefficients(
        b0: 1.0, b1: -2.0, b2: 1.0,
        a1: -1.99004745483398, a2: 0.99007225036621) // RLB high-pass

    private let c: Coefficients
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    init(_ c: Coefficients) { self.c = c }

    mutating func reset() { x1 = 0; x2 = 0; y1 = 0; y2 = 0 }

    mutating func process(_ x: Double) -> Double {
        let y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

// MARK: - True-peak oversampler

/// 4× polyphase-FIR interpolator used only to find the true (inter-sample)
/// peak magnitude, per BS.1770 Annex 2. Windowed-sinc kernel, 12 taps/phase.
/// Not allocation-bearing after init; `maxAbs(pushing:)` runs per input sample.
struct TruePeakOversampler {
    private static let phases = 4
    private static let taps = 12
    // Polyphase coefficients [phase][tap], generated once at type load.
    private static let poly: [[Double]] = makePolyphase()

    private var delay = [Double](repeating: 0, count: TruePeakOversampler.taps)
    private var head = 0 // index of the newest sample in the circular delay line

    mutating func reset() {
        for i in 0..<delay.count { delay[i] = 0 }
        head = 0
    }

    /// Push one input sample, return the max |value| among the 4 reconstructed
    /// sub-samples (and the input itself).
    mutating func maxAbs(pushing x: Double) -> Float {
        head = (head + 1) % TruePeakOversampler.taps
        delay[head] = x
        var m = abs(x)
        for p in 0..<TruePeakOversampler.phases {
            var acc = 0.0
            let coeffs = TruePeakOversampler.poly[p]
            for t in 0..<TruePeakOversampler.taps {
                let idx = (head - t + TruePeakOversampler.taps) % TruePeakOversampler.taps
                acc += delay[idx] * coeffs[t]
            }
            m = max(m, abs(acc))
        }
        return Float(m)
    }

    private static func makePolyphase() -> [[Double]] {
        let n = phases * taps
        let center = Double(n - 1) / 2
        var full = [Double](repeating: 0, count: n)
        for k in 0..<n {
            let t = (Double(k) - center) / Double(phases)
            let sinc = t == 0 ? 1.0 : sin(.pi * t) / (.pi * t)
            let hann = 0.5 - 0.5 * cos(2 * .pi * Double(k) / Double(n - 1))
            full[k] = sinc * hann
        }
        var out = [[Double]](repeating: [Double](repeating: 0, count: taps), count: phases)
        for p in 0..<phases {
            var sum = 0.0
            for m in 0..<taps { let v = full[p + phases * m]; out[p][m] = v; sum += v }
            if abs(sum) > 1e-12 { for m in 0..<taps { out[p][m] /= sum } } // unity DC gain per phase
        }
        return out
    }
}
