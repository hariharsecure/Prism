import CoreGraphics
import Foundation
import XCTest
@testable import Prism

/// FLAGSHIP "Director's Cut" — slice 3b (SUBJECT-TRACKING 9:16 reframe).
///
/// Upgrades the slice-3a centred crop to a Center-Stage-style speaker-follow.
/// These tests lock the PURE, deterministic core — the smoothing / crop-plan
/// math (`SubjectReframePlanner`) and the centred-equivalence geometry — against
/// an INDEPENDENT oracle (analytic properties + hand-computed values), plus the
/// fallback-to-centred guarantee. The Vision detection accuracy and the final
/// visual crop framing are real ML + AVFoundation and are UNVERIFIED-until-eyeball
/// (see the summary for the review recipe); nothing here claims the visual result.
final class DirectorsCutSlice3bTests: XCTestCase {

    // Small halfWindow (wide source) unless a test needs the clamp to bite.
    private func cfg(halfWindow: Double = 0.1,
                     tau: Double = 0.35,
                     maxVelocity: Double = 1.2,
                     reacquire: Double = 0.5,
                     lossHold: Double = 0.6) -> SubjectReframePlanConfig {
        SubjectReframePlanConfig(halfWindow: halfWindow, smoothingTau: tau,
                                 maxVelocity: maxVelocity, reacquireCenter: reacquire,
                                 lossHoldSeconds: lossHold)
    }

    /// A uniform-dt track with a constant / stepping / ramping / nil centre.
    private func track(dt: Double, values: [Double?]) -> [SubjectSample] {
        values.enumerated().map { SubjectSample(seconds: Double($0.offset) * dt, centerX: $0.element) }
    }

    // MARK: - Fallback: no detections → EXACT centred plan (== slice-3a)

    func testNoDetectionsProducesCenteredPlan() {
        let plan = SubjectReframePlanner.plan(track: track(dt: 0.33, values: Array(repeating: nil, count: 30)),
                                              config: cfg())
        XCTAssertTrue(plan.isCentered, "no subject anywhere → the centred (3a) plan")
        XCTAssertEqual(plan.keyframes.count, 1)
        XCTAssertEqual(plan.keyframes.first?.center ?? -1, 0.5, accuracy: 1e-9,
                       "centred plan sits at reacquireCenter (0.5)")
        // Sampling anywhere returns dead centre — byte-identical framing to 3a.
        XCTAssertEqual(plan.center(at: 5), 0.5, accuracy: 1e-9)
    }

    func testEmptyTrackIsCentered() {
        let plan = SubjectReframePlanner.plan(track: [], config: cfg())
        XCTAssertTrue(plan.isCentered)
        XCTAssertEqual(plan.center(at: 0), 0.5, accuracy: 1e-9)
    }

    // MARK: - Step input: smooth, monotone, no overshoot, settles (oracle)

    func testStepInputFollowsSmoothlyNoOvershootAndSettles() {
        // Subject sits at 0.3, then jumps to 0.7 at t=1s; sampled at 3 Hz for 6 s.
        var vals: [Double?] = []
        for i in 0..<18 { vals.append(Double(i) / 3.0 < 1.0 ? 0.3 : 0.7) }
        let plan = SubjectReframePlanner.plan(track: track(dt: 1.0 / 3.0, values: vals),
                                              config: cfg(maxVelocity: 100)) // vel not binding
        let centers = plan.keyframes.map { $0.center }

        // Oracle 1: opens framed on the subject (first detected centre), not 0.5.
        XCTAssertEqual(centers.first ?? -1, 0.3, accuracy: 1e-9)
        // Oracle 2: every value stays within the input envelope [0.3, 0.7] — NO overshoot.
        for c in centers { XCTAssertGreaterThanOrEqual(c, 0.3 - 1e-9); XCTAssertLessThanOrEqual(c, 0.7 + 1e-9) }
        // Oracle 3: after the step the follow is monotonically non-decreasing.
        for i in 1..<centers.count { XCTAssertGreaterThanOrEqual(centers[i], centers[i - 1] - 1e-9) }
        // Oracle 4: it SETTLES — the last value is within 1% of the new target.
        XCTAssertEqual(centers.last ?? -1, 0.7, accuracy: 0.01)
    }

    /// Hand-computed independent oracle for the low-pass step (velocity slack).
    /// dt=1, tau=0.35 ⇒ alpha = 1 − e^(−1/0.35) = 0.942625; from 0.3 toward 0.7:
    /// 0.3 + 0.942625·(0.4) = 0.677050. The planner must reproduce this exactly.
    func testLowPassAlphaMatchesClosedForm() {
        let plan = SubjectReframePlanner.plan(
            track: [SubjectSample(seconds: 0, centerX: 0.3),
                    SubjectSample(seconds: 1.0, centerX: 0.7)],
            config: cfg(tau: 0.35, maxVelocity: 100))
        XCTAssertEqual(plan.keyframes.count, 2)
        XCTAssertEqual(plan.keyframes[0].center, 0.3, accuracy: 1e-9, "seeds on first detection")
        let expected = 0.3 + (1 - exp(-1.0 / 0.35)) * (0.7 - 0.3)
        XCTAssertEqual(plan.keyframes[1].center, expected, accuracy: 1e-9,
                       "low-pass step matches the closed-form alpha")
    }

    // MARK: - Ramp input: tracks with bounded lag, monotone, velocity-limited

    func testRampTracksWithBoundedLag() {
        // Subject ramps 0.3 → 0.7 over 6 s at 3 Hz.
        let n = 18
        let vals: [Double?] = (0..<n).map { 0.3 + 0.4 * Double($0) / Double(n - 1) }
        let plan = SubjectReframePlanner.plan(track: track(dt: 1.0 / 3.0, values: vals),
                                              config: cfg(maxVelocity: 100))
        let centers = plan.keyframes.map { $0.center }
        // Monotone non-decreasing, in-envelope, and the lag to the LAST input is small.
        for i in 1..<centers.count { XCTAssertGreaterThanOrEqual(centers[i], centers[i - 1] - 1e-9) }
        for c in centers { XCTAssertGreaterThanOrEqual(c, 0.3 - 1e-9); XCTAssertLessThanOrEqual(c, 0.7 + 1e-9) }
        XCTAssertEqual(centers.last ?? -1, 0.7, accuracy: 0.05, "tracks the ramp with bounded lag")
    }

    // MARK: - Gap: HOLD last-known within lossHold, then RECENTER

    func testGapHoldsThenRecenters() {
        // Detections at 0.7 for 1 s, then a long nil gap; 3 Hz. lossHold=0.6 s.
        var vals: [Double?] = Array(repeating: 0.7, count: 3)     // t=0.00,0.33,0.66
        vals += Array(repeating: nil, count: 15)                  // gap to t≈5.66 s
        let plan = SubjectReframePlanner.plan(track: track(dt: 1.0 / 3.0, values: vals),
                                              config: cfg(lossHold: 0.6))
        let kfs = plan.keyframes
        // Within the hold window (≤0.6 s after last detection @0.66 → up to ~1.26 s)
        // the centre stays pinned at the last-known 0.7.
        let holdIdx = kfs.firstIndex { $0.seconds > 0.66 && $0.seconds <= 0.66 + 0.6 }!
        XCTAssertEqual(kfs[holdIdx].center, 0.7, accuracy: 1e-6, "holds last-known through a short gap")
        // Well after the hold expires it has eased back toward centre (0.5).
        XCTAssertLessThan(kfs.last!.center, 0.7, "recenters after a sustained loss")
        XCTAssertGreaterThanOrEqual(kfs.last!.center, 0.5 - 1e-6)
        XCTAssertEqual(kfs.last!.center, 0.5, accuracy: 0.05, "settles at reacquireCenter")
    }

    // MARK: - Out-of-frame excursion → clamped fully in-bounds

    func testOutOfFrameExcursionClampedInBounds() {
        let hw = 0.25
        // Subject veers off both edges (0.98, −0.05) and to true edges.
        let vals: [Double?] = [0.5, 0.98, 0.98, 1.2, -0.05, 0.02, 0.5]
        let plan = SubjectReframePlanner.plan(track: track(dt: 1.0 / 3.0, values: vals),
                                              config: cfg(halfWindow: hw, maxVelocity: 100))
        for k in plan.keyframes {
            XCTAssertGreaterThanOrEqual(k.center, hw - 1e-9, "crop never runs off the LEFT edge")
            XCTAssertLessThanOrEqual(k.center, 1 - hw + 1e-9, "crop never runs off the RIGHT edge")
        }
    }

    // MARK: - Velocity clamp: no whip-pan (per-step move bounded)

    func testVelocityClampBoundsPerStepMove() {
        let dt = 1.0 / 3.0
        let maxV = 0.3
        // A hard jump 0.1 → 0.9 with a tiny tau (low-pass would race) — the velocity
        // clamp must be the binding constraint.
        // From 0.1 to 0.9 (0.8 range) at ≤0.1/step needs ≥8 steps → give plenty.
        let vals: [Double?] = [0.1] + Array(repeating: 0.9, count: 13)
        let plan = SubjectReframePlanner.plan(track: track(dt: dt, values: vals),
                                              config: cfg(halfWindow: 0.05, tau: 0.01, maxVelocity: maxV))
        let kfs = plan.keyframes
        for i in 1..<kfs.count {
            let move = abs(kfs[i].center - kfs[i - 1].center)
            XCTAssertLessThanOrEqual(move, maxV * dt + 1e-9, "no step exceeds maxVelocity·dt (no whip-pan)")
        }
        // And it still converges to the target eventually.
        XCTAssertEqual(kfs.last!.center, 0.9, accuracy: 0.02)
    }

    // MARK: - Invariant: plan is ALWAYS in bounds for an arbitrary track

    func testAlwaysInBoundsForArbitraryTrack() {
        let hw = 0.3
        var rng = SystemRandomNumberGeneratorSeeded(seed: 42)
        let vals: [Double?] = (0..<60).map { _ in
            Double.random(in: -0.3...1.3, using: &rng) // includes out-of-range & we drop some
        }.enumerated().map { $0.offset % 7 == 0 ? nil : $0.element }
        let plan = SubjectReframePlanner.plan(track: track(dt: 0.2, values: vals), config: cfg(halfWindow: hw))
        for k in plan.keyframes {
            XCTAssertGreaterThanOrEqual(k.center, hw - 1e-9)
            XCTAssertLessThanOrEqual(k.center, 1 - hw + 1e-9)
        }
    }

    // MARK: - Centred-equivalence: geometry c=0.5 reproduces slice-3a exactly

    func testGeometryCenterReproducesSlice3aCrop() {
        // Synthetic 1920×1080 source (identity transform) → 1080×1920 canvas.
        let orientedW: CGFloat = 1920, orientedH: CGFloat = 1080
        let renderW: CGFloat = 1080, renderH: CGFloat = 1920
        let scale = renderH / orientedH
        let croppedW = orientedW * scale
        let geo = SubjectTrackingVerticalReframer.Geometry(
            preferred: .identity, renderW: renderW, renderH: renderH,
            scale: scale, croppedW: croppedW, fps: 30)

        // The slice-3a centred translate is (renderW − croppedW)/2.
        let slice3aTx = (renderW - croppedW) / 2
        XCTAssertEqual(geo.tx(for: 0.5), slice3aTx, accuracy: 1e-6,
                       "centre crop tx == slice-3a's centred translate")

        // The full centred transform matches slice-3a's compose (scale then translate).
        let expected = CGAffineTransform.identity
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: slice3aTx, y: 0))
        let got = geo.transform(for: 0.5)
        XCTAssertEqual(got.a, expected.a, accuracy: 1e-6)
        XCTAssertEqual(got.d, expected.d, accuracy: 1e-6)
        XCTAssertEqual(got.tx, expected.tx, accuracy: 1e-6)
        XCTAssertEqual(got.ty, expected.ty, accuracy: 1e-6)
    }

    func testGeometryTxClampsKeepCropInBounds() {
        let renderW: CGFloat = 1080, croppedW: CGFloat = 1920
        let geo = SubjectTrackingVerticalReframer.Geometry(
            preferred: .identity, renderW: renderW, renderH: 1920,
            scale: 1, croppedW: croppedW, fps: 30)
        // Far-left subject → tx clamped so the LEFT edge covers the canvas (tx ≤ 0).
        XCTAssertLessThanOrEqual(geo.tx(for: 0.0), 0 + 1e-9)
        XCTAssertEqual(geo.tx(for: 0.0), 0, accuracy: 1e-6, "left-most crop pins the source left edge")
        // Far-right subject → tx clamped to renderW − croppedW (right edge covers).
        XCTAssertEqual(geo.tx(for: 1.0), renderW - croppedW, accuracy: 1e-6,
                       "right-most crop pins the source right edge")
    }

    // MARK: - Plan sampling is continuous (matches the ramp interpolation)

    func testPlanCenterInterpolatesLinearlyBetweenKeyframes() {
        let plan = SubjectReframePlan(keyframes: [
            .init(seconds: 0, center: 0.3),
            .init(seconds: 2, center: 0.7),
        ], isCentered: false)
        XCTAssertEqual(plan.center(at: -1), 0.3, accuracy: 1e-9, "clamped before first keyframe")
        XCTAssertEqual(plan.center(at: 0), 0.3, accuracy: 1e-9)
        XCTAssertEqual(plan.center(at: 1), 0.5, accuracy: 1e-9, "midpoint = linear interp (ramp match)")
        XCTAssertEqual(plan.center(at: 2), 0.7, accuracy: 1e-9)
        XCTAssertEqual(plan.center(at: 9), 0.7, accuracy: 1e-9, "clamped after last keyframe")
    }
}

/// Tiny deterministic RNG so the "arbitrary track" invariant test is reproducible
/// (seeds-before-claims: a fixed seed makes the property check repeatable).
private struct SystemRandomNumberGeneratorSeeded: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
