import CoreGraphics
import CoreVideo
import XCTest

import PrismCompositor
import PrismCore

/// Verification for the beat-pulse "boom" effect (BEAT_SYNC_DESIGN.md — "The
/// pulse effect"). Asserts the scale/shake envelope shape (peak on the downbeat,
/// monotonic decay to rest), determinism, and that a rendered frame is visibly
/// bigger on the beat (phase 0) than between beats (phase 0.9).
///
/// PNG dumps across one beat (phase 0, 0.15, 0.3, 0.6, 0.9) go to:
///   /tmp/prism_beatpulse/
final class BeatPulseTests: XCTestCase {

    private static let outputDir = URL(fileURLWithPath:
        "/tmp/prism_beatpulse")

    private let W = 480, H = 270
    private let pulse = BeatPulse.default

    // MARK: - Envelope: scale peaks on the beat and decays monotonically

    func testScalePeaksAtDownbeatAndDecaysMonotonically() {
        let intensity = 0.5
        let t0 = pulse.pulse(phase: 0, intensity: intensity, style: .bump)
        // Peak scale ≈ 1 + intensity at the downbeat.
        XCTAssertEqual(t0.scale, 1 + intensity, accuracy: 1e-9)

        // Strictly decreasing across the beat.
        let phases = stride(from: 0.0, through: 0.99, by: 0.11).map { $0 }
        var last = Double.infinity
        for p in phases {
            let s = pulse.pulse(phase: p, intensity: intensity, style: .bump).scale
            XCTAssertGreaterThanOrEqual(s, 1.0, "scale never drops below rest")
            XCTAssertLessThan(s, last, "scale must strictly decrease over the beat (phase \(p))")
            last = s
        }
        // Nearly back to rest by the end of the beat.
        let sEnd = pulse.pulse(phase: 0.99, intensity: intensity, style: .bump).scale
        XCTAssertEqual(sEnd, 1.0, accuracy: 0.02, "scale decays to ~1 by the next beat")

        // Bump style adds no offset.
        XCTAssertEqual(t0.dx, 0); XCTAssertEqual(t0.dy, 0)
    }

    // MARK: - Shake peaks near the downbeat and decays

    func testShakePeaksNearDownbeatAndDecays() {
        let intensity = 0.8
        let mags = [0.0, 0.2, 0.5, 0.9].map {
            pulse.pulse(phase: $0, intensity: intensity, style: .shake).shakeMagnitude
        }
        // Peak at the downbeat, strictly decaying afterward.
        XCTAssertGreaterThan(mags[0], 0, "shake is non-zero on the beat")
        for i in 1..<mags.count {
            XCTAssertLessThan(mags[i], mags[i - 1], "shake magnitude decays (idx \(i))")
        }
        // Shake style leaves scale at rest.
        XCTAssertEqual(pulse.pulse(phase: 0, intensity: intensity, style: .shake).scale, 1.0)
    }

    // MARK: - Style selects components; intensity is clamped

    func testStylesAndIntensityClamp() {
        let both = pulse.pulse(phase: 0.05, intensity: 1.0, style: .bumpShake)
        XCTAssertGreaterThan(both.scale, 1.0)
        XCTAssertGreaterThan(both.shakeMagnitude, 0)

        // Intensity clamps to maxIntensity (default 2): huge input can't blow up scale.
        let clamped = pulse.pulse(phase: 0, intensity: 999, style: .bump)
        XCTAssertEqual(clamped.scale, 1 + pulse.maxIntensity, accuracy: 1e-9)
        // Negative intensity clamps to 0 (no pulse).
        XCTAssertEqual(pulse.pulse(phase: 0, intensity: -5, style: .bumpShake), .identity)
    }

    // MARK: - Determinism

    func testDeterministic() {
        for p in stride(from: 0.0, through: 1.0, by: 0.07) {
            let a = pulse.pulse(phase: p, intensity: 0.6, style: .bumpShake)
            let b = pulse.pulse(phase: p, intensity: 0.6, style: .bumpShake)
            XCTAssertEqual(a, b, "same phase+intensity → identical transform (phase \(p))")
        }
    }

    // MARK: - Rendering: bigger on the beat than between beats

    /// A black frame with a centered white square (~40% of the canvas). Scaling
    /// up about the center enlarges the square → higher mean luma, which is a
    /// clean, orientation-free proxy for "bigger".
    private func makeLumaSource(_ canvas: FXCanvas) throws -> CVPixelBuffer {
        let w = CGFloat(W), h = CGFloat(H)
        let sw = w * 0.4, sh = h * 0.4
        return try canvas.render { ctx in
            ctx.setFillColor(RGBA.black.cg); ctx.fill(canvas.rect)
            ctx.setFillColor(RGBA.white.cg)
            ctx.fill(CGRect(x: (w - sw) / 2, y: (h - sh) / 2, width: sw, height: sh))
        }
    }

    func testRenderBiggerOnBeat() throws {
        let canvas = try FXCanvas(width: W, height: H)
        let renderer = try BeatPulseRenderer(width: W, height: H)
        let source = try makeLumaSource(canvas)
        let intensity = 0.6

        let onBeat = try renderer.render(source: source,
                                         transform: pulse.pulse(phase: 0, intensity: intensity, style: .bump))
        let between = try renderer.render(source: source,
                                          transform: pulse.pulse(phase: 0.9, intensity: intensity, style: .bump))

        // The two frames differ (the effect does something).
        XCTAssertGreaterThan(FXCanvas.meanDiff(onBeat, between), 0.01, "on-beat vs between frames differ")
        // On the beat the centered white square is scaled up → more white → higher luma.
        let lumaOn = FXCanvas.meanLuma(onBeat)
        let lumaBetween = FXCanvas.meanLuma(between)
        XCTAssertGreaterThan(lumaOn, lumaBetween, "frame is bigger (brighter) on the beat than between beats")
    }

    // MARK: - PNG dump across one beat (eyeball the boom + decay)

    /// A gradient background with a centered magenta box and corner markers so
    /// both the scale boom and the shake jitter are visible.
    private func makeVisualSource(_ canvas: FXCanvas) throws -> CVPixelBuffer {
        let w = CGFloat(W), h = CGFloat(H)
        return try canvas.render { ctx in
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            if let grad = CGGradient(colorsSpace: cs,
                                     colors: [RGBA(r: 0.05, g: 0.05, b: 0.2).cg,
                                              RGBA(r: 0.1, g: 0.3, b: 0.5).cg] as CFArray,
                                     locations: [0, 1]) {
                ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0),
                                       end: CGPoint(x: 0, y: h), options: [])
            }
            // Centered magenta box (the pulsing subject).
            ctx.setFillColor(RGBA(r: 0.95, g: 0.1, b: 0.6).cg)
            ctx.fill(CGRect(x: w * 0.35, y: h * 0.35, width: w * 0.30, height: h * 0.30))
            // Corner markers so the shake offset is visible.
            ctx.setFillColor(RGBA(r: 1, g: 0.85, b: 0).cg)
            let m: CGFloat = 22
            for p in [CGPoint(x: 8, y: 8), CGPoint(x: w - m - 8, y: 8),
                      CGPoint(x: 8, y: h - m - 8), CGPoint(x: w - m - 8, y: h - m - 8)] {
                ctx.fill(CGRect(x: p.x, y: p.y, width: m, height: m))
            }
        }
    }

    func testDumpBeatSequencePNGs() throws {
        let canvas = try FXCanvas(width: W, height: H)
        let renderer = try BeatPulseRenderer(width: W, height: H)
        let source = try makeVisualSource(canvas)
        let intensity = 0.6
        let phases = [0.0, 0.15, 0.3, 0.6, 0.9]

        try? FileManager.default.createDirectory(at: Self.outputDir, withIntermediateDirectories: true)
        for p in phases {
            let t = pulse.pulse(phase: p, intensity: intensity, style: .bumpShake)
            let frame = try renderer.render(source: source, transform: t)
            let name = String(format: "beatpulse_phase_%.2f_scale_%.3f.png", p, t.scale)
            try FXCanvas.writePNG(frame, to: Self.outputDir.appendingPathComponent(name))
        }
        // Confirm the sequence landed.
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.outputDir.path)
            .filter { $0.hasPrefix("beatpulse_phase_") }
        XCTAssertEqual(files.count, phases.count, "one PNG per phase")
    }
}
