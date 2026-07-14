import Foundation

/// One affine per-channel transfer: `out = gain·in + offset`.
public struct ChannelTransfer: Sendable, Codable, Equatable {
    public let gain: Double
    public let offset: Double

    public init(gain: Double, offset: Double) {
        self.gain = gain
        self.offset = offset
    }

    public static let identity = ChannelTransfer(gain: 1, offset: 0)

    public func apply(_ x: Double) -> Double { gain * x + offset }
}

/// A shot-match correction: independent affine maps per channel
/// (matrix-expressible — a diagonal 3×3 gain plus an offset vector).
public struct ShotMatchCorrection: Sendable, Codable, Equatable {
    public let red: ChannelTransfer
    public let green: ChannelTransfer
    public let blue: ChannelTransfer

    public init(red: ChannelTransfer, green: ChannelTransfer, blue: ChannelTransfer) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let identity = ShotMatchCorrection(red: .identity, green: .identity, blue: .identity)

    /// Express the correction through `ColorGrade`'s lift/gain wheels.
    ///
    /// With `gamma = 1` the wheel formula `out = gain·(in + lift·(1−in))`
    /// expands to exactly `out = (gainW·(1−lift))·in + gainW·lift` — so an
    /// affine map (gain g, offset o) is representable *exactly* by
    /// `gainW = g + o`, `lift = o / (g + o)` whenever `g + o > 0`.
    /// Degenerate channels (g + o ≤ ~0) fall back to gain-only.
    public func asColorGrade() -> ColorGrade {
        func wheel(_ t: ChannelTransfer) -> (lift: Double, gain: Double) {
            let gainW = t.gain + t.offset
            guard gainW > 0.05 else { return (0, max(t.gain, 0)) }
            return (t.offset / gainW, gainW)
        }
        let r = wheel(red), g = wheel(green), b = wheel(blue)
        return ColorGrade(lift: GradeTriple(red: r.lift, green: g.lift, blue: b.lift),
                          gain: GradeTriple(red: r.gain, green: g.gain, blue: b.gain))
    }
}

/// Statistical color transfer (Reinhard-style mean/σ matching), per channel.
///
/// **Working space (stated):** gamma-encoded BT.709 RGB — the space
/// `FrameStats` measures and the lift/gain wheels operate in. Simple RGB is
/// the accepted v0; a perceptual (lab/YCbCr) space is a later refinement.
///
/// For each channel: `out = (in − μ_target)·(σ_ref/σ_target) + μ_ref`,
/// i.e. `gain = σ_ref/σ_target`, `offset = μ_ref − gain·μ_target`. A target
/// channel with ~zero σ (flat card) degrades to gain 1 + mean shift.
/// Pure math on two `FrameStats` — unit-verifiable, no GPU.
public enum ShotMatch {
    /// - Parameters:
    ///   - reference: stats of the look you want (the "hero" camera).
    ///   - target: stats of the camera being matched.
    ///   - maxGain: σ-ratio clamp so a near-flat target can't explode noise.
    public static func correction(reference: FrameStats, target: FrameStats,
                                  maxGain: Double = 4) -> ShotMatchCorrection {
        func channel(refMean: Double, refStd: Double,
                     targetMean: Double, targetStd: Double) -> ChannelTransfer {
            let sigmaFloor = 1e-4
            let gain: Double
            if targetStd < sigmaFloor {
                gain = 1 // flat target: mean shift only
            } else {
                gain = (refStd / targetStd).clamped(to: 1 / maxGain...maxGain)
            }
            return ChannelTransfer(gain: gain, offset: refMean - gain * targetMean)
        }
        return ShotMatchCorrection(
            red: channel(refMean: reference.meanR, refStd: reference.stdDevR,
                         targetMean: target.meanR, targetStd: target.stdDevR),
            green: channel(refMean: reference.meanG, refStd: reference.stdDevG,
                           targetMean: target.meanG, targetStd: target.stdDevG),
            blue: channel(refMean: reference.meanB, refStd: reference.stdDevB,
                          targetMean: target.meanB, targetStd: target.stdDevB))
    }
}
