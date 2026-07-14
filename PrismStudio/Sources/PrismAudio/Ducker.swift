import Foundation
import os

/// Thread-safe holder for a channel's most recent post-fader block level,
/// published by the owning channel's render block and read by any `Ducker`
/// that keys off it. A tiny leaf object (no reference to the channel) so it
/// can be shared with a ducker without a retain cycle.
final class SidechainLevel: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Float>(initialState: 0)
    func set(_ v: Float) { lock.withLock { $0 = v } }
    var value: Float { lock.withLock { $0 } }
}

/// Sidechain ducking parameters (DESIGN.md §2.4 — "Sidechain ducking (music
/// under voice)"). A soft-knee-free downward compressor driven by a *key*
/// channel's level rather than the target's own.
public struct DuckingConfig: Sendable, Equatable {
    /// Key level (dBFS) above which ducking engages.
    public var thresholdDB: Double
    /// Compression ratio (> 1). Gain reduction = overshoot·(1 − 1/ratio).
    public var ratio: Double
    /// Attack time constant (seconds) — how fast the target dips when the key
    /// gets loud.
    public var attack: Double
    /// Release time constant (seconds) — how fast the target recovers.
    public var release: Double
    /// Maximum attenuation floor (dB, positive magnitude), e.g. 24 = −24 dB.
    public var maxAttenuationDB: Double

    public init(thresholdDB: Double = -30,
                ratio: Double = 8,
                attack: Double = 0.05,
                release: Double = 0.3,
                maxAttenuationDB: Double = 24) {
        self.thresholdDB = thresholdDB
        self.ratio = max(ratio, 1.0001)
        self.attack = max(attack, 0)
        self.release = max(release, 0)
        self.maxAttenuationDB = max(maxAttenuationDB, 0)
    }
}

/// Per-target ducking controller. `process(frameCount:)` runs once per target
/// render block on the audio thread and returns the extra linear gain to apply
/// to that block. No allocation on the render path — it reads the key's
/// published level and advances a one-pole gain-reduction envelope.
final class Ducker: @unchecked Sendable {
    private let keyLevel: SidechainLevel
    private let sampleRate: Double
    private let cfg: OSAllocatedUnfairLock<DuckingConfig>
    // Render-thread-only: current gain reduction in dB (≤ 0).
    private var envelopeDB: Double = 0

    init(config: DuckingConfig, keyLevel: SidechainLevel, sampleRate: Double) {
        self.cfg = OSAllocatedUnfairLock(initialState: config)
        self.keyLevel = keyLevel
        self.sampleRate = sampleRate
    }

    func setConfig(_ c: DuckingConfig) { cfg.withLock { $0 = c } }
    var config: DuckingConfig { cfg.withLock { $0 } }

    /// Advance the envelope by one block; return the linear gain (0…1) to apply
    /// to the target channel this block.
    func process(frameCount: Int) -> Float {
        let c = cfg.withLock { $0 }
        let keyLinear = keyLevel.value
        let keyDB = keyLinear > 1e-7 ? 20 * log10(Double(keyLinear)) : -140

        let targetReductionDB: Double
        if keyDB > c.thresholdDB {
            let overshoot = keyDB - c.thresholdDB
            let reduction = overshoot * (1 - 1 / c.ratio)
            targetReductionDB = -min(reduction, c.maxAttenuationDB)
        } else {
            targetReductionDB = 0
        }

        // One-pole smoothing: attack when driving toward more reduction,
        // release when recovering.
        let dt = Double(frameCount) / sampleRate
        let tc = targetReductionDB < envelopeDB ? c.attack : c.release
        let coeff = tc > 0 ? exp(-dt / tc) : 0
        envelopeDB = targetReductionDB + (envelopeDB - targetReductionDB) * coeff
        return Float(pow(10, envelopeDB / 20))
    }
}
