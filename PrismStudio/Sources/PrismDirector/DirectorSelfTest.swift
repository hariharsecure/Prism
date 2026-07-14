import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import PrismCore

/// Headless self-verification of the auto-director (no TCC, no camera).
///
/// The load-bearing logic — the switching **policy** and the framing
/// **geometry** — is pure and is verified exactly (scripted signal timelines,
/// asserted cut decisions and crop trajectories). The Vision analyzer is
/// exercised end-to-end on synthetic buffers for plumbing only: whether Vision
/// classifies a synthetic blob as a face is NOT the pass criterion (mirrors
/// `VisionSelfTest`).
///
/// TEST CODE ONLY: this file locks pixel-buffer base addresses to fill
/// synthetic inputs — allowed here, forbidden on the engine hot path.
///
/// `DirectorSelfTest.run()` throws with a precise message on the first mismatch.
public enum DirectorSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case setupFailed(String)
        case mismatch(String)
        public var description: String {
            switch self {
            case .setupFailed(let s): return "director self-test setup failed: \(s)"
            case .mismatch(let s): return "director self-test mismatch: \(s)"
            }
        }
    }

    public static func run() throws {
        try testPolicyHysteresisAndMinShot()
        try testStaleSourceNotCuttable()
        try testPTSDiscontinuityRebaseline()
        try testAnalyzerRateLimiterAfterReset()
        try testMotionOnlyActivity()
        try testFramerSmoothingAndBounds()
        try testAnalyzerEndToEnd()
        try testAnalyzerSubmitPipeline()
        print("DirectorSelfTest: all checks passed")
    }

    // MARK: - (a) AutoDirector: hysteresis + min-shot + cooldown

    /// Drives a scripted per-source timeline at 5 Hz (Δt=0.2 s, PTS-exact via
    /// timescale 5 so the timeline is fp-robust) and asserts the anti-flicker
    /// policy: hold on the initial acquire, IGNORE a one-frame B spike, IGNORE
    /// an equal-signal tie, CUT only when B's lead is *sustained* past the lead
    /// window AND the shot has met min-duration, then refuse to flip back until
    /// cooldown + min-shot both clear.
    private static func testPolicyHysteresisAndMinShot() throws {
        let a = SourceID("cam.a"), b = SourceID("cam.b")
        // Thresholds deliberately off the 0.2 s grid so no gate lands on a
        // floating-point knife-edge.
        let config = AutoDirectorConfig(enabled: true, sensitivity: 0.5,
                                        minShotSeconds: 1.9,
                                        leadWindowSeconds: 0.75,
                                        cutCooldownSeconds: 1.4)
        // Sanity: derived gates are where we expect.
        guard abs(config.hysteresisMargin - 0.225) < 1e-6, abs(config.activationFloor - 0.12) < 1e-6 else {
            throw SelfTestError.mismatch("policy: derived margin/floor off — \(config.hysteresisMargin)/\(config.activationFloor)")
        }
        let director = AutoDirector(config: config)

        func activity(_ i: Int) -> (Float, Float) {
            switch i {
            case 0...11: return (0.90, 0.44)   // A speaking → acquire + hold
            case 12:     return (0.44, 0.95)   // one-frame B spike (must NOT cut)
            case 13...14: return (0.50, 0.50)  // equal tie (must hold A)
            case 15...19: return (0.44, 0.95)  // B sustained → cut to B at i=19 (t=3.8)
            default:     return (0.95, 0.44)   // A re-spike → blocked by cooldown/min-shot until i=29 (t=5.8)
            }
        }
        func signal(_ src: SourceID, _ level: Float, _ i: Int) -> SourceSignal {
            // facePresent + conf 0 gives a 0.20 presence floor; audio drives the
            // rest, so activity == max(0.20, level) — exactly `level` here.
            SourceSignal(source: src, pts: CMTime(value: CMTimeValue(i), timescale: 5),
                         facePresent: true, faceConfidence: 0, faceBounds: nil,
                         motionEnergy: 0, audioLevel: level)
        }

        var decisions: [DirectorDecision] = []
        var ticks = 0
        for i in 0...32 {
            let (av, bv) = activity(i)
            let sigs = [signal(a, av, i), signal(b, bv, i)]
            ticks += 1
            if let d = director.ingest(sigs) { decisions.append(d) }
        }

        guard decisions.count == 3 else {
            throw SelfTestError.mismatch("policy: expected 3 decisions over \(ticks) ticks, got \(decisions.count): "
                + decisions.map { "\($0.activeSource)@\(String(format: "%.1f", $0.atSeconds))(\($0.reason.rawValue))" }.joined(separator: ", "))
        }
        let d0 = decisions[0], d1 = decisions[1], d2 = decisions[2]
        guard d0.activeSource == a, d0.reason == .initialAcquire, abs(d0.atSeconds - 0.0) < 0.05 else {
            throw SelfTestError.mismatch("policy: decision 0 should be acquire A@0.0, got \(d0.activeSource)@\(d0.atSeconds) \(d0.reason)")
        }
        guard d1.activeSource == b, d1.previousSource == a, d1.reason == .sustainedLead, abs(d1.atSeconds - 3.8) < 0.05 else {
            throw SelfTestError.mismatch("policy: decision 1 should be cut A→B@3.8, got \(d1.activeSource)@\(d1.atSeconds)")
        }
        guard d2.activeSource == a, d2.previousSource == b, d2.reason == .sustainedLead, abs(d2.atSeconds - 5.8) < 0.05 else {
            throw SelfTestError.mismatch("policy: decision 2 should be cut B→A@5.8, got \(d2.activeSource)@\(d2.atSeconds)")
        }

        // Second run of the SAME script must reproduce identically (determinism).
        let d2b = AutoDirector(config: config)
        var replay: [DirectorDecision] = []
        for i in 0...32 { if let d = d2b.ingest([signal(a, activity(i).0, i), signal(b, activity(i).1, i)]) { replay.append(d) } }
        guard replay == decisions else {
            throw SelfTestError.mismatch("policy: replay diverged from first run")
        }

        // Disabled engine emits nothing.
        let off = AutoDirector(config: AutoDirectorConfig(enabled: false))
        guard off.ingest([signal(a, 0.9, 0), signal(b, 0.1, 0)]) == nil else {
            throw SelfTestError.mismatch("policy: disabled engine must not decide")
        }

        print("  ✓ AutoDirector: 33 ticks @5Hz → 3 cuts "
            + "[acquire A@0.0, A→B@\(String(format: "%.1f", d1.atSeconds)) (B sustained past 0.75s lead), "
            + "B→A@\(String(format: "%.1f", d2.atSeconds)) (after 1.9s min-shot + 1.4s cooldown)]; "
            + "ignored 1-frame B spike @2.4 and equal-tie @2.6–2.8; deterministic on replay")
    }

    // MARK: - (a.1) #1 Stale source must not be a cut target

    /// A source emits one decisive high signal then goes silent (unplugged /
    /// frozen). The controller keeps its last signal in `latestSignals`, so the
    /// policy keeps seeing it. Proves: once that signal ages past the staleness
    /// window it is EXCLUDED from ranking, so the director never cuts to the dead
    /// source (holds the live program) — whereas an identical but *fresh* B does
    /// get cut to, isolating staleness as the only difference.
    private static func testStaleSourceNotCuttable() throws {
        let a = SourceID("cam.a"), b = SourceID("cam.b")
        // Small gates so a fresh challenger WOULD cut quickly; leadWindow (1.5s)
        // deliberately exceeds the staleness window (1.0s) so a source that goes
        // silent can never sustain a lead long enough to cut.
        let config = AutoDirectorConfig(enabled: true, sensitivity: 0.5,
                                        minShotSeconds: 0.5, leadWindowSeconds: 1.5,
                                        cutCooldownSeconds: 0.5, stalenessSeconds: 1.0)
        // Deterministic 0.1 s grid via timescale 10.
        func sig(_ src: SourceID, _ level: Float, ptsTick i: Int) -> SourceSignal {
            SourceSignal(source: src, pts: CMTime(value: CMTimeValue(i), timescale: 10),
                         facePresent: true, faceConfidence: 0, faceBounds: nil,
                         motionEnergy: 0, audioLevel: level)
        }
        // A activity 0.40 (presence floor 0.20 dominated by audio 0.40); B starts
        // low, spikes 0.99 on ticks 3–5, then goes silent (its last signal stays
        // frozen at tick 5 / activity 0.99).
        func aLevel(_ i: Int) -> Float { 0.40 }
        func bLevel(_ i: Int) -> Float { (3...5).contains(i) ? 0.99 : 0.10 }

        // --- Scenario 1: B goes silent after tick 5 (frozen signal). ---
        let dirStale = AutoDirector(config: config)
        var staleDecisions: [DirectorDecision] = []
        var frozenB: SourceSignal? = nil
        for i in 0...40 {
            var sigs = [sig(a, aLevel(i), ptsTick: i)]
            if i <= 5 { let s = sig(b, bLevel(i), ptsTick: i); frozenB = s; sigs.append(s) }
            else if let fb = frozenB { sigs.append(fb) }   // B's last signal lingers (frozen PTS/activity)
            if let d = dirStale.ingest(sigs) { staleDecisions.append(d) }
        }
        guard staleDecisions.count == 1, staleDecisions[0].activeSource == a,
              staleDecisions[0].reason == .initialAcquire else {
            throw SelfTestError.mismatch("stale: expected only [acquire A], got "
                + staleDecisions.map { "\($0.activeSource)@\(String(format: "%.1f", $0.atSeconds))(\($0.reason.rawValue))" }.joined(separator: ", "))
        }
        guard dirStale.currentActiveSource == a else {
            throw SelfTestError.mismatch("stale: program should still be A, got \(String(describing: dirStale.currentActiveSource))")
        }

        // --- Scenario 2 (control): B keeps emitting FRESH 0.99 → must cut A→B. ---
        let dirFresh = AutoDirector(config: config)
        var freshDecisions: [DirectorDecision] = []
        for i in 0...40 {
            let bl: Float = i >= 3 ? 0.99 : 0.10
            if let d = dirFresh.ingest([sig(a, aLevel(i), ptsTick: i), sig(b, bl, ptsTick: i)]) {
                freshDecisions.append(d)
            }
        }
        guard freshDecisions.count == 2, freshDecisions[0].activeSource == a,
              freshDecisions[1].activeSource == b, freshDecisions[1].previousSource == a,
              freshDecisions[1].reason == .sustainedLead else {
            throw SelfTestError.mismatch("stale-control: fresh B should cut A→B, got "
                + freshDecisions.map { "\($0.activeSource)@\(String(format: "%.1f", $0.atSeconds))" }.joined(separator: ", "))
        }

        print("  ✓ Stale-source guard: B spikes 0.99 then goes silent @0.5s → director HOLDS A "
            + "(no cut over 4.1s; B excluded once >1.0s stale); identical FRESH B cuts A→B@"
            + "\(String(format: "%.1f", freshDecisions[1].atSeconds)) — staleness is the only difference")
    }

    // MARK: - (a.2) #2 PTS discontinuity re-baselines timers (never stuck)

    /// The program sits on A with a large PTS. A source reconnects with its PTS
    /// reset to ~0, so the house clock jumps BACKWARD. Without a guard,
    /// `onShot`/`sinceCut` go negative and the gates wedge forever. Proves the
    /// director re-baselines its timers to the new clock and still cuts correctly
    /// after the discontinuity.
    private static func testPTSDiscontinuityRebaseline() throws {
        let a = SourceID("cam.a"), b = SourceID("cam.b")
        let config = AutoDirectorConfig(enabled: true, sensitivity: 0.5,
                                        minShotSeconds: 0.5, leadWindowSeconds: 0.3,
                                        cutCooldownSeconds: 0.5, stalenessSeconds: 100)
        let director = AutoDirector(config: config)
        func sig(_ src: SourceID, _ level: Float, pts: CMTime) -> SourceSignal {
            SourceSignal(source: src, pts: pts, facePresent: true, faceConfidence: 0,
                         faceBounds: nil, motionEnergy: 0, audioLevel: level)
        }
        var decisions: [DirectorDecision] = []

        // Phase 1: A on program at PTS ~100 s (timescale 10 → 0.1 s steps).
        for i in 1000...1004 {   // 100.0 … 100.4
            let pts = CMTime(value: CMTimeValue(i), timescale: 10)
            if let d = director.ingest([sig(a, 0.90, pts: pts), sig(b, 0.10, pts: pts)]) { decisions.append(d) }
        }
        guard decisions.count == 1, decisions[0].activeSource == a,
              decisions[0].reason == .initialAcquire, abs(decisions[0].atSeconds - 100.0) < 0.05 else {
            throw SelfTestError.mismatch("discontinuity: phase-1 should acquire A@100.0, got "
                + decisions.map { "\($0.activeSource)@\(String(format: "%.1f", $0.atSeconds))" }.joined(separator: ", "))
        }

        // Phase 2: PTS resets to ~0; B now wants program. onShot would be −100 s
        // (activeSince=100.0) — the guard must re-baseline so cutting resumes.
        for i in 0...10 {        // 0.0 … 1.0
            let pts = CMTime(value: CMTimeValue(i), timescale: 10)
            if let d = director.ingest([sig(a, 0.10, pts: pts), sig(b, 0.90, pts: pts)]) { decisions.append(d) }
        }
        guard decisions.count == 2 else {
            throw SelfTestError.mismatch("discontinuity: expected 2 decisions (acquire + post-reset cut), got \(decisions.count): "
                + decisions.map { "\($0.activeSource)@\(String(format: "%.1f", $0.atSeconds))" }.joined(separator: ", "))
        }
        let cut = decisions[1]
        guard cut.activeSource == b, cut.previousSource == a, cut.reason == .sustainedLead,
              abs(cut.atSeconds - 0.5) < 0.05 else {
            throw SelfTestError.mismatch("discontinuity: post-reset cut should be A→B@0.5, got \(cut.activeSource)@\(cut.atSeconds) \(cut.reason)")
        }
        print("  ✓ PTS-discontinuity re-baseline: A acquired @100.0s, PTS jumps back to 0 → "
            + "timers re-baseline (onShot would be −100s) → still cuts A→B@\(String(format: "%.1f", cut.atSeconds))s "
            + "(not wedged)")
    }

    // MARK: - (a.3) #3 Analyzer rate-limiter survives a PTS reset

    /// After a same-source PTS reset, `seconds - lastAccepted` goes negative and
    /// the naive `< 1/rate` test would rate-limit EVERY subsequent frame, killing
    /// the source. Proves backward time is treated as a discontinuity: the frame
    /// is accepted and the baseline resets. Submits one frame at a time and waits
    /// for idle so accounting is deterministic (no supersede races).
    private static func testAnalyzerRateLimiterAfterReset() throws {
        let analyzer = DirectorAnalyzer(targetRate: 8)   // interval 0.125 s
        let src = "ratelimit.reset"
        func submitAndDrain(_ ptsSeconds: Double) throws {
            let pts = CMTime(seconds: ptsSeconds, preferredTimescale: 1000)
            analyzer.submit(try makePersonishFrame(pts: pts, id: src))
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline { if analyzer.isIdle { break }; usleep(10_000) }
            guard analyzer.isIdle else { throw SelfTestError.mismatch("ratelimit: analyzer did not drain at pts \(ptsSeconds)") }
        }
        try submitAndDrain(10.00)   // accept (first)
        try submitAndDrain(10.05)   // rate-limited (0.05 < 0.125, forward)
        try submitAndDrain(0.00)    // PTS RESET (backward) → accept + re-baseline
        try submitAndDrain(0.05)    // rate-limited (0.05 < 0.125, forward)
        try submitAndDrain(0.20)    // accept (0.20 ≥ 0.125)
        let s = analyzer.stats
        guard s.submitted == 5, s.processed == 3, s.rateLimited == 2, s.superseded == 0, s.errors == 0 else {
            throw SelfTestError.mismatch("ratelimit: expected submitted 5 / processed 3 / rateLimited 2 / superseded 0 / errors 0, got \(s)")
        }
        print("  ✓ Analyzer rate-limiter post-reset: pts 10.00→10.05→(reset)0.00→0.05→0.20 → "
            + "processed \(s.processed), rateLimited \(s.rateLimited) "
            + "(reset frame accepted, source stays alive — not permanently dark)")
    }

    // MARK: - (a.4) #5 Pure-motion source clears the activation floor

    /// A source with no face and no audio but strong motion must score via the
    /// motion term (> activation floor) and be selectable — the documented
    /// behavior the old early-out contradicted. A truly-idle source stays 0.
    private static func testMotionOnlyActivity() throws {
        let motionOnly = SourceSignal(source: SourceID("motion"),
                                      pts: CMTime(value: 0, timescale: 1),
                                      facePresent: false, faceConfidence: 0, faceBounds: nil,
                                      motionEnergy: 0.9, audioLevel: nil)
        // 0.7 · 0.9 = 0.63.
        guard abs(motionOnly.activity - 0.63) < 1e-5 else {
            throw SelfTestError.mismatch("motion-only: activity should be 0.63, got \(motionOnly.activity)")
        }
        let cfg = AutoDirectorConfig()   // sensitivity 0.5 → activationFloor 0.12
        guard motionOnly.activity > cfg.activationFloor else {
            throw SelfTestError.mismatch("motion-only: \(motionOnly.activity) must exceed floor \(cfg.activationFloor)")
        }
        // Truly idle (no face, no audio, no motion) stays exactly 0.
        let idle = SourceSignal(source: SourceID("idle"), pts: CMTime(value: 0, timescale: 1),
                                facePresent: false, faceConfidence: 0, faceBounds: nil,
                                motionEnergy: 0, audioLevel: nil)
        guard idle.activity == 0 else {
            throw SelfTestError.mismatch("motion-only: idle source should score 0, got \(idle.activity)")
        }
        // The policy can acquire a pure-motion source.
        let director = AutoDirector(config: cfg)
        guard let d = director.ingest([motionOnly]), d.activeSource == SourceID("motion"),
              d.reason == .initialAcquire else {
            throw SelfTestError.mismatch("motion-only: director should acquire the motion source")
        }
        print("  ✓ Motion-only activity: no face/audio, motion 0.9 → activity 0.63 > floor "
            + "\(String(format: "%.2f", cfg.activationFloor)) → acquired; idle source scores 0")
    }

    // MARK: - (b) AutoFramer: smoothing + headroom + clamp

    private static func testFramerSmoothingAndBounds() throws {
        let cfg = AutoFramerConfig(subjectHeightFraction: 0.45, headroom: 0.12,
                                   aspect: 1.0, smoothing: 0.3,
                                   minCropHeight: 0.25, maxCropHeight: 1.0)
        let framer = AutoFramer(config: cfg)

        func face(cx: CGFloat, top: CGFloat, w: CGFloat = 0.15, h: CGFloat = 0.20) -> CGRect {
            CGRect(x: cx - w / 2, y: top, width: w, height: h)
        }
        let expectedH = min(1.0, 0.20 / 0.45)          // 0.4444
        let leftFace = face(cx: 0.30, top: 0.30)
        let rightFace = face(cx: 0.75, top: 0.30)
        let rightTarget = framer.targetCrop(for: rightFace)

        // First update snaps to target (no history).
        let first = framer.update(faceBounds: leftFace)
        let leftTarget = framer.targetCrop(for: leftFace)
        guard rectClose(first, leftTarget) else {
            throw SelfTestError.mismatch("framer: first update should snap to target, got \(fmt(first)) vs \(fmt(leftTarget))")
        }
        guard inBounds(first) else { throw SelfTestError.mismatch("framer: first crop out of bounds \(fmt(first))") }

        // Now jump the face right and hold it; the crop must GLIDE, not snap.
        var trajectory: [CGFloat] = [first.origin.x]
        var prevGap = abs(first.origin.x - rightTarget.origin.x)
        let firstStepPrev = first.origin.x
        for step in 0..<24 {
            let out = framer.update(faceBounds: rightFace)
            trajectory.append(out.origin.x)
            guard inBounds(out) else { throw SelfTestError.mismatch("framer: crop left bounds at step \(step): \(fmt(out))") }
            let gap = abs(out.origin.x - rightTarget.origin.x)
            guard gap <= prevGap + 1e-9 else {
                throw SelfTestError.mismatch("framer: not approaching target at step \(step): gap \(gap) > \(prevGap)")
            }
            if step == 0 {
                // Fractional move: exactly the EMA step, strictly between prev and target.
                let expectedStep = 0.3 * (rightTarget.origin.x - firstStepPrev)
                guard abs((out.origin.x - firstStepPrev) - expectedStep) < 1e-6,
                      out.origin.x > firstStepPrev, out.origin.x < rightTarget.origin.x else {
                    throw SelfTestError.mismatch("framer: first move not a fractional EMA step (got \(out.origin.x), expected +\(expectedStep))")
                }
            }
            prevGap = gap
        }
        let converged = framer.currentCrop!
        guard abs(converged.origin.x - rightTarget.origin.x) < 0.01,
              abs(converged.size.height - expectedH) < 0.01 else {
            throw SelfTestError.mismatch("framer: did not converge to target — \(fmt(converged)) vs \(fmt(rightTarget))")
        }
        // Headroom check at convergence: gap above the face top ≈ headroom·cropH.
        let headroomGap = rightFace.minY - converged.origin.y
        let headroomFrac = headroomGap / converged.size.height
        guard abs(headroomFrac - 0.12) < 0.02 else {
            throw SelfTestError.mismatch("framer: headroom \(headroomFrac) not ≈0.12")
        }

        // Clamp: a face near the right edge must not push the crop off-frame.
        framer.reset()
        let edge = framer.update(faceBounds: face(cx: 0.95, top: 0.30))
        guard inBounds(edge), edge.origin.x + edge.size.width <= 1.0 + 1e-9 else {
            throw SelfTestError.mismatch("framer: edge face not clamped in-bounds: \(fmt(edge))")
        }

        // Lost subject: eases back toward the full frame (width grows toward 1).
        framer.reset()
        _ = framer.update(faceBounds: rightFace)           // start zoomed-in
        let zoomedW = framer.currentCrop!.size.width
        var wideW = zoomedW
        for _ in 0..<10 { wideW = framer.update(faceBounds: nil).size.width }
        guard wideW > zoomedW + 0.1 else {
            throw SelfTestError.mismatch("framer: lost-subject should pull wider — \(zoomedW) → \(wideW)")
        }

        let traj = trajectory.prefix(6).map { String(format: "%.3f", $0) }.joined(separator: "→")
        print("  ✓ AutoFramer: crop.x glides \(traj)…→\(String(format: "%.3f", converged.origin.x)) "
            + "(target \(String(format: "%.3f", rightTarget.origin.x)), α=0.3), headroom "
            + "\(String(format: "%.3f", headroomFrac)), edge-face clamped, lost-subject widens \(String(format: "%.2f", zoomedW))→\(String(format: "%.2f", wideW))")
    }

    // MARK: - (c) DirectorAnalyzer: Vision end-to-end on a synthetic frame

    private static func testAnalyzerEndToEnd() throws {
        let analyzer = DirectorAnalyzer(targetRate: 8, minFaceConfidence: 0.3)
        let src = SourceID("selftest.analyze")

        // Frame 1: plain gray (establishes motion baseline).
        let f1 = try makeBGRAFrame(id: src.raw, pts: CMTime(value: 1, timescale: 30)) { _, _ in (128, 128, 128) }
        let s1 = try analyzer.analyzeNow(f1)
        guard s1.source == src, CMTimeCompare(s1.pts, f1.pts) == 0,
              s1.motionEnergy >= 0, s1.motionEnergy <= 1,
              s1.faceConfidence >= 0, s1.faceConfidence <= 1 else {
            throw SelfTestError.mismatch("analyzer: frame-1 signal malformed \(s1)")
        }
        guard s1.motionEnergy == 0 else {
            throw SelfTestError.mismatch("analyzer: first frame should have no motion history, got \(s1.motionEnergy)")
        }

        // Frame 2: half the frame flipped bright → measurable motion vs frame 1.
        let f2 = try makeBGRAFrame(id: src.raw, pts: CMTime(value: 2, timescale: 30)) { x, _ in
            x < 320 ? (255, 255, 255) : (128, 128, 128)
        }
        let s2 = try analyzer.analyzeNow(f2)
        guard s2.motionEnergy > 0.05 else {
            throw SelfTestError.mismatch("analyzer: frame-2 should register motion, got \(s2.motionEnergy)")
        }

        // A "person-ish" frame — plumbing only; face detection may or may not fire.
        let fp = try makePersonishFrame(id: "selftest.person")
        let sp = try analyzer.analyzeNow(fp)
        if sp.facePresent {
            guard let bb = sp.faceBounds, bb.width > 0, bb.height > 0,
                  bb.minX >= -0.01, bb.maxX <= 1.01, bb.minY >= -0.01, bb.maxY <= 1.01 else {
                throw SelfTestError.mismatch("analyzer: face present but bounds invalid \(String(describing: sp.faceBounds))")
            }
            print("  ✓ DirectorAnalyzer end-to-end: motion 0→\(String(format: "%.3f", s2.motionEnergy)), "
                + "face detected conf=\(String(format: "%.2f", sp.faceConfidence)) bounds=\(fmt(sp.faceBounds!)) (top-left origin)")
        } else {
            print("  ✓ DirectorAnalyzer end-to-end: motion 0→\(String(format: "%.3f", s2.motionEnergy)), "
                + "clean no-face on synthetic blob (Vision ran error-free — plumbing verified)")
        }
    }

    // MARK: - Async submit pipeline: non-blocking + rate limiting + accounting

    private static func testAnalyzerSubmitPipeline() throws {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var signals: [SourceSignal] = []
            var errors: [Error] = []
        }
        let box = Box()
        let analyzer = DirectorAnalyzer(targetRate: 8)
        analyzer.onSignal = { s in box.lock.lock(); box.signals.append(s); box.lock.unlock() }
        analyzer.onError = { e in box.lock.lock(); box.errors.append(e); box.lock.unlock() }

        // Two sources, 20 frames each at a simulated 60 fps → the 8 Hz limiter
        // drops most.
        let a = SourceID("submit.a"), b = SourceID("submit.b")
        let per = 20
        for i in 0..<per {
            let pts = CMTime(value: CMTimeValue(i), timescale: 60)
            analyzer.submit(try makePersonishFrame(pts: pts, id: a.raw))
            analyzer.submit(try makePersonishFrame(pts: pts, id: b.raw))
        }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let s = analyzer.stats
            if analyzer.isIdle, s.rateLimited + s.superseded + s.processed == per * 2 { break }
            usleep(20_000)
        }
        let stats = analyzer.stats
        guard analyzer.isIdle, stats.rateLimited + stats.superseded + stats.processed == per * 2 else {
            throw SelfTestError.mismatch("analyzer submit: pipeline did not drain — \(stats)")
        }
        guard stats.submitted == per * 2, stats.processed >= 2, stats.errors == 0, stats.rateLimited >= 10 else {
            throw SelfTestError.mismatch("analyzer submit: accounting wrong — \(stats)")
        }
        box.lock.lock(); let errors = box.errors; let signalCount = box.signals.count; box.lock.unlock()
        guard errors.isEmpty else { throw SelfTestError.mismatch("analyzer submit: onError fired \(errors)") }
        guard signalCount == stats.processed else {
            throw SelfTestError.mismatch("analyzer submit: \(signalCount) callbacks vs \(stats.processed) processed")
        }
        print("  ✓ DirectorAnalyzer submit: \(per * 2) @60fps/2 sources → rateLimited \(stats.rateLimited), "
            + "superseded \(stats.superseded), processed \(stats.processed), errors 0 (non-blocking, latest-wins per source)")
    }

    // MARK: - Synthetic-frame helpers (test code: CPU pixel fill is allowed)

    private static let frameW = 640, frameH = 480

    private static func makeBGRAFrame(width: Int = frameW, height: Int = frameH,
                                      id: String, pts: CMTime,
                                      fill: (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8)) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: width, height: height,
                                       pixelFormat: kCVPixelFormatType_32BGRA, minimumBufferCount: 1)
        let buffer = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<height {
            for col in 0..<width {
                let c = fill(col, row)
                let p = base + row * bpr + col * 4
                p[0] = c.b; p[1] = c.g; p[2] = c.r; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return VideoFrame(pixelBuffer: buffer, pts: pts, source: SourceID(id))
    }

    private static func makePersonishFrame(pts: CMTime? = nil, id: String) throws -> VideoFrame {
        try makeBGRAFrame(id: id, pts: pts ?? HouseClock.now()) { x, y in
            let hx = Double(x - 320), hy = Double(y - 140)
            if hx * hx + hy * hy < 55 * 55 { return (210, 160, 130) }   // head
            let bx = Double(x - 320) / 110, by = Double(y - 330) / 150
            if bx * bx + by * by < 1 { return (60, 90, 160) }           // torso
            return (180, 180, 180)
        }
    }

    // MARK: - Assertions helpers

    private static func inBounds(_ r: CGRect) -> Bool {
        r.origin.x >= -1e-9 && r.origin.y >= -1e-9
            && r.origin.x + r.size.width <= 1 + 1e-9
            && r.origin.y + r.size.height <= 1 + 1e-9
            && r.size.width > 0 && r.size.height > 0
    }
    private static func rectClose(_ a: CGRect, _ b: CGRect, eps: CGFloat = 1e-6) -> Bool {
        abs(a.origin.x - b.origin.x) < eps && abs(a.origin.y - b.origin.y) < eps
            && abs(a.size.width - b.size.width) < eps && abs(a.size.height - b.size.height) < eps
    }
    private static func fmt(_ r: CGRect) -> String {
        String(format: "(%.3f,%.3f,%.3f,%.3f)", r.origin.x, r.origin.y, r.size.width, r.size.height)
    }
}
