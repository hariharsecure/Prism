import Foundation

/// Headless, deterministic verification of the `BeatClock` phase math and the
/// `BeatSequencer` downbeat classification the live `onBeat`/`onBar` callbacks
/// fire from. Fixed host-time inputs — no real-time playback, no audio hardware,
/// so it is reproducible and CI-safe.
public enum BeatClockSelfTest {
    public static func run() throws -> SoundTestReport {
        var checks: [SoundTestReport.Check] = []
        func check(_ name: String, _ passed: Bool, _ detail: String) {
            checks.append(.init(name: name, passed: passed, detail: detail))
        }

        // 120 BPM ⇒ 0.5 s / beat, 4 beats / bar ⇒ 2.0 s / bar. Anchor at t=1000.
        let anchor = 1000.0
        let clk = BeatClock(bpm: 120, beatsPerBar: 4, anchorHostSeconds: anchor)
        check("120 BPM ⇒ 0.5 s beat / 2.0 s bar",
              abs(clk.beatSeconds - 0.5) < 1e-12 && abs(clk.barSeconds - 2.0) < 1e-12,
              "beatSeconds \(clk.beatSeconds), barSeconds \(clk.barSeconds)")

        // beatPhase advances 0→1 across the beat and WRAPS. Sample within one beat.
        let within: [(t: Double, want: Double)] = [
            (0.0, 0.0), (0.125, 0.25), (0.25, 0.5), (0.375, 0.75), (0.499, 0.998),
        ]
        var phaseOK = true, mono = true, prev = -1.0
        for s in within {
            let ph = clk.beatPhase(atHostSeconds: anchor + s.t)
            if abs(ph - s.want) > 1e-6 { phaseOK = false }
            if ph <= prev { mono = false }
            prev = ph
        }
        // At exactly one beat later phase wraps back to 0 and beatIndex ticks to 1.
        let wrapPh = clk.beatPhase(atHostSeconds: anchor + 0.5)
        let idxAt0 = clk.beatIndex(atHostSeconds: anchor + 0.25)
        let idxAt1 = clk.beatIndex(atHostSeconds: anchor + 0.5)
        check("beatPhase 0→1 monotonic within a beat, then wraps to 0",
              phaseOK && mono && abs(wrapPh) < 1e-9 && idxAt0 == 0 && idxAt1 == 1,
              "wrap phase \(String(format: "%.6f", wrapPh)), idx@0.25=\(idxAt0) idx@0.5=\(idxAt1)")

        // barPhase spans the whole bar (0 → 1 across 2.0 s) and wraps at the bar line.
        let barMid = clk.barPhase(atHostSeconds: anchor + 1.0)     // half a bar
        let barEnd = clk.barPhase(atHostSeconds: anchor + 2.0)     // bar line ⇒ 0
        let barIdx0 = clk.barIndex(atHostSeconds: anchor + 1.0)
        let barIdx1 = clk.barIndex(atHostSeconds: anchor + 2.0)
        check("barPhase spans the bar and wraps; barIndex increments",
              abs(barMid - 0.5) < 1e-9 && abs(barEnd) < 1e-9 && barIdx0 == 0 && barIdx1 == 1,
              "barPhase@1.0=\(String(format: "%.4f", barMid)) @2.0=\(String(format: "%.4f", barEnd)), barIdx 0→\(barIdx1)")

        // beatIndex increments exactly once per beat over 8 beats.
        var lastIdx = -1, increments = 0, idxMono = true
        for k in 0..<80 {                     // 80 samples across 4 s = 8 beats @ 0.05 s
            let idx = clk.beatIndex(atHostSeconds: anchor + Double(k) * 0.05)
            if idx != lastIdx { increments += 1; if idx != lastIdx + 1 && lastIdx >= 0 { idxMono = false }; lastIdx = idx }
        }
        check("beatIndex increments once per beat (8 beats over 4 s)",
              increments == 8 && idxMono && lastIdx == 7,
              "\(increments) distinct beat indices, last=\(lastIdx), strictlyStepped=\(idxMono)")

        // Stopped clock (bpm 0) ⇒ phase 0, index 0 — graceful, no beats.
        let stopped = BeatClock.stopped
        let sPhase = stopped.beatPhase(atHostSeconds: anchor + 12.3)
        let sBar = stopped.barPhase(atHostSeconds: anchor + 12.3)
        let sIdx = stopped.beatIndex(atHostSeconds: anchor + 12.3)
        check("stopped / bpm=0 ⇒ phase 0, index 0, no beats",
              sPhase == 0 && sBar == 0 && sIdx == 0,
              "phase \(sPhase), barPhase \(sBar), idx \(sIdx)")

        // Continuity across the bar boundary: sampling just before and just after a
        // bar line, beatPhase must not jump (same continuous clock, no per-bar reset).
        let before = clk.beatPhase(atHostSeconds: anchor + 2.0 - 1e-4)
        let after = clk.beatPhase(atHostSeconds: anchor + 2.0 + 1e-4)
        check("phase continuous across the bar line (no reset seam)",
              before > 0.999 && after < 0.001,
              "phase@(bar⁻) \(String(format: "%.5f", before)) → @(bar⁺) \(String(format: "%.5f", after))")

        // Swing shifts the odd 16ths (BeatPattern is swing's carrier): even steps
        // stay on-grid, odd steps are delayed by swing·stepSeconds — and the beat
        // downbeats (steps 0,4,8,12, all even) are therefore unmoved.
        let sw = BeatPattern(bpm: 120, swing: 0.6, stepCount: 16)
        let step = sw.stepSeconds
        let odd1 = sw.onsetSeconds(step: 1, bar: 0)
        let even2 = sw.onsetSeconds(step: 2, bar: 0)
        let beat4 = sw.onsetSeconds(step: 4, bar: 0)     // a downbeat — must be unswung
        check("swing delays odd 16ths, leaves downbeats on-grid",
              abs(odd1 - (step + 0.6 * step)) < 1e-9 && abs(even2 - 2 * step) < 1e-9 && abs(beat4 - 4 * step) < 1e-9,
              String(format: "odd1 %.4f (=1.6·step), even2 %.4f, beat4 %.4f (step %.4f)", odd1, even2, beat4, step))

        // onBeat/onBar single-source-of-truth: drive the SAME lookahead cursor the
        // live clock uses over 2 bars, apply `beatInfo`, and assert each beat fires
        // exactly once, in order 0,1,2,…, with bar-firsts at 0,4.
        let pat = BeatPattern(bpm: 140, swing: 0.3, stepCount: 16)
        let target = pat.barSeconds * 2       // exactly 2 bars (exclusive of bar-2's downbeat)
        var cursor = BeatScheduleCursor()
        var beatsFired: [Int] = []
        var barsFired: [Int] = []
        var horizon = 0.0
        while horizon < target {
            horizon = min(horizon + 0.05, target)
            for onset in cursor.drain(pattern: pat, upTo: horizon) {
                if let bi = BeatSequencer.beatInfo(forGlobalStep: onset.globalStep, stepCount: pat.safeStepCount) {
                    beatsFired.append(bi.beatIndex)
                    if bi.firstBeatOfBar { barsFired.append(bi.barIndex) }
                }
            }
        }
        let expectBeats = Array(0..<8)               // 4 beats/bar × 2 bars
        check("onBeat fires once per beat, in order, across 2 bars",
              beatsFired == expectBeats && barsFired == [0, 1],
              "beats \(beatsFired), bars \(barsFired)")

        return SoundTestReport(checks: checks)
    }
}
