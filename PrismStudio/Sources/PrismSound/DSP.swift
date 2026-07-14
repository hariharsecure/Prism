import Foundation

// Pure-Swift DSP primitives for SoundFoundry's procedural synthesis.
// Deterministic: all randomness comes from `SplitMix64` seeded by a sound's
// index, so the generated library is fully reproducible (no Date/arc4random).

/// Deterministic PRNG (SplitMix64). Same seed ⇒ same stream ⇒ reproducible WAVs.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform Float in [0, 1).
    mutating func unit() -> Float { Float(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    /// Uniform Float in [-1, 1).
    mutating func bipolar() -> Float { unit() * 2 - 1 }
    /// Uniform Float in [lo, hi).
    mutating func range(_ lo: Float, _ hi: Float) -> Float { lo + unit() * (hi - lo) }
    /// Uniform Int in [lo, hi].
    mutating func int(_ lo: Int, _ hi: Int) -> Int { lo + Int(next() % UInt64(hi - lo + 1)) }
}

/// FNV-1a hash of a string → stable per-category seed component.
func fnv1a(_ s: String) -> UInt64 {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
    return h
}

enum DSP {
    /// Equal-temperament MIDI note → frequency (A4 = 69 = 440 Hz).
    static func midiToHz(_ note: Double) -> Double { 440.0 * pow(2.0, (note - 69.0) / 12.0) }

    /// Exponential decay envelope value at time `t` with time-constant `tau`.
    @inline(__always) static func expDecay(_ t: Float, _ tau: Float) -> Float {
        tau <= 0 ? 0 : expf(-t / tau)
    }

    /// Linear ADSR value at time `t` (seconds). `dur` is total note length.
    static func adsr(_ t: Float, dur: Float, a: Float, d: Float, s: Float, r: Float) -> Float {
        let relStart = max(dur - r, a + d)
        if t < a { return a > 0 ? t / a : 1 }
        if t < a + d { return d > 0 ? 1 - (1 - s) * ((t - a) / d) : s }
        if t < relStart { return s }
        if t < dur { return r > 0 ? s * (1 - (t - relStart) / r) : 0 }
        return 0
    }

    /// Naive band-limited-ish sawtooth from a phase in [0, 1).
    @inline(__always) static func saw(_ phase: Float) -> Float { 2 * (phase - floorf(phase + 0.5)) }
    @inline(__always) static func square(_ phase: Float) -> Float { phase - floorf(phase) < 0.5 ? 1 : -1 }
    @inline(__always) static func triangle(_ phase: Float) -> Float {
        let p = phase - floorf(phase)
        return p < 0.5 ? (4 * p - 1) : (3 - 4 * p)
    }
}

/// One-pole low-pass. `cutoff` in Hz, recomputed per call so it can sweep.
struct OnePoleLP {
    private var z: Float = 0
    mutating func process(_ x: Float, cutoff: Float, sampleRate: Float) -> Float {
        let c = max(1, min(cutoff, sampleRate * 0.49))
        let a = 1 - expf(-2 * .pi * c / sampleRate)
        z += a * (x - z)
        return z
    }
}

/// One-pole high-pass (input minus low-passed).
struct OnePoleHP {
    private var lp = OnePoleLP()
    mutating func process(_ x: Float, cutoff: Float, sampleRate: Float) -> Float {
        x - lp.process(x, cutoff: cutoff, sampleRate: sampleRate)
    }
}

/// Chamberlin state-variable filter (low/high/band outputs), stable for
/// moving cutoff — used for riser/whoosh sweeps and bandpass shaping.
struct StateVariableFilter {
    private var low: Float = 0
    private var band: Float = 0

    mutating func process(_ x: Float, cutoff: Float, q: Float, sampleRate: Float)
        -> (low: Float, high: Float, band: Float) {
        let f = 2 * sinf(.pi * max(1, min(cutoff, sampleRate * 0.45)) / sampleRate)
        let damp = min(1, 1 / max(0.5, q))
        let high = x - low - damp * band
        band += f * high
        low += f * band
        return (low, high, band)
    }
}

/// Deterministic pink-ish noise (Paul Kellet's economy filter) over white noise.
struct PinkNoise {
    private var b0: Float = 0, b1: Float = 0, b2: Float = 0
    mutating func process(_ white: Float) -> Float {
        b0 = 0.99765 * b0 + white * 0.0990460
        b1 = 0.96300 * b1 + white * 0.2965164
        b2 = 0.57000 * b2 + white * 1.0526913
        return (b0 + b1 + b2 + white * 0.1848) * 0.20
    }
}

/// Subtract each channel's mean (DC offset) in place. A DC bias steals headroom
/// from the subsequent peak-normalize and leaves the WAV with a non-zero mean
/// (finding A6: `keys.0000` mean was −0.169). Called both before the edge fades
/// (so the fade brings the *true* signal to zero at the edges — no onset click)
/// and again inside `normalize` for generators that don't fade; the second pass
/// only removes the tiny residual the fade re-introduces, so it's idempotent for
/// practical purposes. Linear + uniform ⇒ safe for loopable material (a constant
/// subtracted from every sample preserves loop-seam continuity).
func removeDC(_ channels: inout [[Float]]) {
    for c in channels.indices {
        let count = channels[c].count
        guard count > 0 else { continue }
        var sum: Double = 0
        for s in channels[c] { sum += Double(s) }
        let mean = Float(sum / Double(count))
        guard abs(mean) > 1e-7 else { continue }
        for i in channels[c].indices { channels[c][i] -= mean }
    }
}

/// Normalize a planar buffer to a target peak (in-place-ish, returns new peak scale).
func normalize(_ channels: inout [[Float]], to peak: Float) {
    removeDC(&channels) // A6: strip any DC bias so it can't survive into the WAV
    var maxAbs: Float = 0
    for ch in channels { for s in ch { maxAbs = max(maxAbs, abs(s)) } }
    guard maxAbs > 1e-9 else { return }
    let g = peak / maxAbs
    for c in channels.indices { for i in channels[c].indices { channels[c][i] *= g } }
}

/// Apply a short raised-cosine fade in/out to remove clicks at edges.
func applyEdgeFades(_ channels: inout [[Float]], sampleRate: Int, fadeMs: Float = 4) {
    removeDC(&channels) // A6: remove DC *before* fading so the edges taper to true zero
    let n = channels.first?.count ?? 0
    let f = min(n / 2, Int(Float(sampleRate) * fadeMs / 1000))
    guard f > 1 else { return }
    for c in channels.indices {
        for i in 0..<f {
            let g = 0.5 - 0.5 * cosf(.pi * Float(i) / Float(f))
            channels[c][i] *= g
            channels[c][n - 1 - i] *= g
        }
    }
}

/// Make a buffer seamlessly loopable by cross-fading its tail into its head
/// (equal-power) and then welding the cyclic boundary so it is truly continuous.
/// The returned buffer is `crossMs` shorter than the input.
func loopify(_ channels: [[Float]], sampleRate: Int, crossMs: Float = 120,
             weldMs: Float = 6) -> [[Float]] {
    let n = channels.first?.count ?? 0
    let x = min(n / 3, Int(Float(sampleRate) * crossMs / 1000))
    guard x > 8, n > 2 * x else { return channels }
    let outN = n - x
    var out = channels.map { Array($0[0..<outN]) }
    // A1: make the CYCLIC boundary (out[outN-1] → out[0]) continuous. The loop
    // is `outN` samples long; when it wraps, the sample that naturally follows
    // out[outN-1] (== channels[outN-1]) is channels[outN]. So at i=0 the head
    // must weigh the *tail* fully (out[0] = channels[outN]) and fade toward the
    // real head by i=x (where out[x] = channels[x], the untouched region).
    // The previous coefficients were inverted (head=cos/tail=sin), so out[0]
    // stayed at channels[0] and the raw last→first discontinuity survived.
    for c in channels.indices {
        for i in 0..<x {
            let t = Float(i) / Float(x)
            let head = sinf(0.5 * .pi * t)   // 0 → 1 across the crossfade
            let tail = cosf(0.5 * .pi * t)   // 1 → 0 across the crossfade
            out[c][i] = channels[c][i] * head + channels[c][outN + i] * tail
        }
    }
    weldLoopSeam(&out, sampleRate: sampleRate, weldMs: weldMs)
    return out
}

/// A11: weld the last→first wrap of a loop to genuine continuity.
///
/// The equal-power crossfade above makes the wrap a *natural* adjacent-sample
/// step of the source. For smooth/tonal beds (drone, texture) that step is tiny,
/// but for broadband noise beds (rain, wind, roomtone — high-passed / band-limited
/// noise) two adjacent samples are near-uncorrelated, so the wrap is a full
/// noise-sized step (measured |first−last| up to ~0.37). That periodic step is an
/// audible loop-seam *click* even though its RATIO to the interior steps is < 1
/// (rain's own interior steps are just as large), which is why the ratio-only
/// validation missed it. No crossfade length can fix this: the metric is a single
/// adjacent pair, and two full-amplitude broadband samples cannot be near-equal.
///
/// Fix: cancel the residual step `δ = out[0] − out[outN-1]` by adding a small
/// linear-ish correction ramp straddling the boundary — easing +δ/2 in over the
/// last `h` samples and −δ/2 out over the first `h` — so the wrap becomes
/// continuous (|first−last| → 0). This only *adds a slow ramp*; it removes no
/// high-frequency energy, so there is no loop-point amplitude dip, and it is
/// signal-agnostic (for tonal beds δ is already ~0 so it is a no-op). Linear and
/// DC-safe: `removeDC`/`normalize` run afterward and preserve the zero step.
func weldLoopSeam(_ channels: inout [[Float]], sampleRate: Int, weldMs: Float = 6) {
    let outN = channels.first?.count ?? 0
    let h = min(outN / 4, max(2, Int(Float(sampleRate) * weldMs / 1000) / 2))
    guard h >= 2, outN > 4 * h else { return }
    for c in channels.indices {
        let delta = channels[c][0] - channels[c][outN - 1]  // the wrap step to cancel
        // Last h samples: ease the correction 0 → +δ/2 as we approach the seam.
        for j in 1...h {
            let frac = 0.5 - 0.5 * cosf(.pi * Float(h - j + 1) / Float(h))
            channels[c][outN - j] += (delta / 2) * frac
        }
        // First h samples: ease the correction −δ/2 → 0 as we leave the seam.
        for j in 0..<h {
            let frac = 0.5 - 0.5 * cosf(.pi * Float(h - j) / Float(h))
            channels[c][j] += (-delta / 2) * frac
        }
    }
}
