import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Vision
import os

import PrismOutput

// MARK: - Director's Cut slice 3b — SUBJECT-TRACKING vertical reframe
//
// Slice-3a reframes the saved 16:9 highlight to 9:16 with a fixed CENTER crop
// (`AVFoundationVerticalReframer`). Slice-3b (this file) upgrades that to a
// Center-Stage-style SUBJECT FOLLOW: it analyses the clip for the speaker's
// horizontal position over time (Apple Vision), plans a smoothed, in-bounds,
// time-varying 9:16 crop that keeps the subject centred, and applies it via a
// per-time `AVMutableVideoComposition` transform ramp (the crop pans across the
// timeline). Audio (master mix) is carried through untouched; output is 1080×1920.
//
// Three cleanly separable pieces, hardest-logic-first:
//   1. `SubjectReframePlanner` — the PURE, deterministic smoothing / crop-plan
//      math (a subject-centre track → an eased, velocity-clamped, in-bounds crop
//      plan). This is the core; it is unit-tested against an independent oracle.
//   2. `SubjectTrackAnalyzer` — the Vision detection pass (sampled frames →
//      subject-centre track). Real ML — its accuracy is UNVERIFIED-until-eyeball.
//   3. `SubjectTrackingVerticalReframer` — the `VerticalHighlightProducing`
//      seam: analyse → plan → apply. Falls back to the EXACT slice-3a centered
//      crop when no subject is found or analysis fails (never worse than 3a).
//
// Everything is toggle-gated (`tracking`) and reversible: with tracking off, or
// on any analysis miss, the output is byte-for-byte the slice-3a centered crop.

// MARK: - Pure model types

/// One subject observation sampled from the clip. `centerX` is the subject's
/// horizontal centre in **display-normalized** coordinates (0 = left edge, 1 =
/// right edge, after the track's preferred transform); `nil` marks a sampled
/// instant where no subject was detected (a gap the planner must ride through).
struct SubjectSample: Equatable, Sendable {
    /// Sample time in clip seconds (0 = clip start), monotonically increasing.
    let seconds: Double
    /// Subject centre-x, normalized 0…1, or `nil` for a no-detection gap.
    let centerX: Double?
}

/// Tunables for the crop-plan smoothing. Defaults chosen for a talking-head:
/// a ~0.35 s follow constant (responsive but calm), a velocity ceiling that
/// forbids whip-pans, and a 0.6 s hold before a lost subject recenters.
struct SubjectReframePlanConfig: Sendable {
    /// Half the visible (crop) width in normalized source units — the in-bounds
    /// clamp bound. A crop centre must stay within `[halfWindow, 1 − halfWindow]`
    /// so the 9:16 window never runs off either edge of the source.
    var halfWindow: Double
    /// Low-pass follow time constant (seconds). Larger = calmer / laggier.
    var smoothingTau: Double
    /// Max crop-centre speed (normalized units / second) — the anti-whip clamp.
    var maxVelocity: Double
    /// Where the crop eases to when the subject is lost past `lossHoldSeconds`.
    var reacquireCenter: Double
    /// How long to HOLD the last-known centre on a detection gap before easing
    /// back toward `reacquireCenter`.
    var lossHoldSeconds: Double

    init(halfWindow: Double,
         smoothingTau: Double = 0.35,
         maxVelocity: Double = 1.2,
         reacquireCenter: Double = 0.5,
         lossHoldSeconds: Double = 0.6) {
        self.halfWindow = halfWindow
        self.smoothingTau = smoothingTau
        self.maxVelocity = maxVelocity
        self.reacquireCenter = reacquireCenter
        self.lossHoldSeconds = lossHoldSeconds
    }
}

/// The planned, smoothed crop: an ordered list of `(seconds, center)` keyframes
/// in normalized source units. `center(at:)` samples it piecewise-linearly (the
/// AVFoundation layer turns consecutive keyframes into transform ramps, so the
/// crop pans continuously — the linear read here matches the ramp exactly).
struct SubjectReframePlan: Equatable, Sendable {
    struct Keyframe: Equatable, Sendable { let seconds: Double; let center: Double }
    let keyframes: [Keyframe]
    /// True when the plan is a single constant-centre keyframe at `reacquireCenter`
    /// (no usable detections) — i.e. the plan is exactly the slice-3a centred crop.
    let isCentered: Bool

    /// Piecewise-linear centre at `t` (clamped to the keyframe span at the ends).
    func center(at t: Double) -> Double {
        guard let first = keyframes.first else { return 0.5 }
        if t <= first.seconds { return first.center }
        guard let last = keyframes.last else { return first.center }
        if t >= last.seconds { return last.center }
        for i in 1..<keyframes.count {
            let a = keyframes[i - 1], b = keyframes[i]
            if t <= b.seconds {
                let span = b.seconds - a.seconds
                guard span > 0 else { return b.center }
                let f = (t - a.seconds) / span
                return a.center + f * (b.center - a.center)
            }
        }
        return last.center
    }
}

// MARK: - Pure crop planner (the core testable logic)

/// Turns a raw subject-centre track into a smoothed, in-bounds, velocity-limited
/// crop plan. PURE + deterministic (no clock, no I/O): identical input → identical
/// plan, so it is fully unit-testable against an independent oracle.
///
/// Per sample, in time order, it:
///   • resolves a TARGET centre — the detected centre (clamped in-bounds) when
///     present; else the last target while within `lossHoldSeconds` of the last
///     detection (HOLD), else `reacquireCenter` (RECENTER on a sustained loss);
///   • low-passes the current centre toward the target with `alpha = 1 −
///     exp(−dt/tau)` (a critically-damped-style ease, frame-rate independent);
///   • clamps the per-step move to `maxVelocity · dt` (no whip-pan);
///   • clamps the result to `[halfWindow, 1 − halfWindow]` (always in bounds).
enum SubjectReframePlanner {

    /// Build the plan. When the track has NO detections at all, returns the
    /// single-keyframe centred plan (`isCentered == true`) — the slice-3a crop.
    static func plan(track: [SubjectSample], config: SubjectReframePlanConfig) -> SubjectReframePlan {
        let lo = min(config.halfWindow, 0.5)
        let hi = max(1 - config.halfWindow, 0.5)
        let center0 = clamp(config.reacquireCenter, lo, hi)

        // No usable detection anywhere → exact centred (slice-3a) plan.
        let hasAnyDetection = track.contains { $0.centerX != nil }
        guard hasAnyDetection, let first = track.first else {
            return SubjectReframePlan(keyframes: [.init(seconds: 0, center: center0)],
                                      isCentered: true)
        }

        var keyframes: [SubjectReframePlan.Keyframe] = []
        // Seed the current centre at the FIRST detected centre (clamped) so the
        // plan opens already framed on the subject rather than easing in from
        // centre — matches how a live Center-Stage acquires on first sight.
        var current = clamp(first.centerX ?? config.reacquireCenter, lo, hi)
        var lastTarget = current
        var lastSeen = first.centerX != nil ? first.seconds : -Double.infinity
        var prevT = first.seconds

        for sample in track {
            let dt = max(0, sample.seconds - prevT)
            prevT = sample.seconds

            let target: Double
            if let cx = sample.centerX {
                target = clamp(cx, lo, hi)
                lastTarget = target
                lastSeen = sample.seconds
            } else if sample.seconds - lastSeen <= config.lossHoldSeconds {
                target = lastTarget            // HOLD last-known through a short gap
            } else {
                target = center0               // RECENTER on a sustained loss
            }

            if dt > 0 {
                let alpha = 1 - exp(-dt / max(config.smoothingTau, 1e-6))
                var desired = current + alpha * (target - current)
                let maxStep = config.maxVelocity * dt
                let move = desired - current
                if move > maxStep { desired = current + maxStep }
                else if move < -maxStep { desired = current - maxStep }
                current = clamp(desired, lo, hi)
            } else {
                current = clamp(current, lo, hi)
            }
            keyframes.append(.init(seconds: sample.seconds, center: current))
        }
        return SubjectReframePlan(keyframes: keyframes, isCentered: false)
    }

    @inline(__always)
    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        v < lo ? lo : (v > hi ? hi : v)
    }
}

// MARK: - Vision subject-track analyzer

/// Analyses a saved horizontal clip for the subject's horizontal position over
/// time, using Apple Vision on COST-BOUNDED sampled frames (not every frame).
///
/// Detection strategy (per sampled frame, cheapest-strongest-first):
///   • `VNDetectFaceRectanglesRequest` — the talking-head signal. When faces are
///     found, the crop follows the LARGEST face's centre (the presenter).
///   • `VNDetectHumanRectanglesRequest` — fallback when no face is visible
///     (turned away, occluded): follow the largest person box centre. This reuses
///     the same Vision person-detection family Prism already relies on
///     (`PersonSegmenter`/`PresenterCutout` use `VNGeneratePersonSegmentation`);
///     a rectangle request is the cheaper "where is the subject" analogue.
///   • Neither → emit a `nil`-centre sample (a gap the planner rides through).
///
/// Cost: frames are pulled with `AVAssetImageGenerator` at `sampleRate` Hz
/// (default 3 Hz — ~a few per second) with a small tolerance so the generator
/// can reuse decoded frames; each frame runs one image request handler. A
/// 30 s clip ⇒ ~90 Vision passes off the render path, seconds of wall time.
struct SubjectTrackAnalyzer {
    /// Frames analysed per second of clip (bounded; not per-frame).
    var sampleRate: Double = 3
    /// TEST SEAM (default `nil` ⇒ zero behaviour change): a per-frame subject
    /// locator that REPLACES the real Vision pass. Production always leaves this
    /// `nil`, so detection runs the real `detectSubjectCenterX` Vision request.
    /// A synthetic-ground-truth test injects a deterministic pixel-based locator
    /// here because Apple's face/human detectors do NOT fire on synthetic renders
    /// — this lets the REAL sampling→plan→compose→export pipeline be validated
    /// end-to-end against a known subject path (only the ML classifier is mocked).
    var frameDetector: (@Sendable (CGImage) -> Double?)? = nil
    private let logger = Logger(subsystem: "studio.prism", category: "dcut.reframe")

    /// Vision-detected subject centre track (display-normalized), or an empty
    /// array when the clip yields no frames. Never throws for a clean
    /// no-detection — that surfaces as `nil`-centre samples the planner handles.
    func analyze(asset: AVAsset, track: AVAssetTrack) async throws -> [SubjectSample] {
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { return [] }

        let step = 1.0 / max(sampleRate, 0.1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true   // display-oriented centreX
        generator.requestedTimeToleranceBefore = CMTime(seconds: step / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: step / 2, preferredTimescale: 600)

        var samples: [SubjectSample] = []
        var t = 0.0
        while t < duration {
            let time = CMTime(seconds: t, preferredTimescale: 600)
            let centerX: Double?
            do {
                let cg = try generator.copyCGImage(at: time, actualTime: nil)
                if let inject = frameDetector { centerX = inject(cg) }
                else { centerX = Self.detectSubjectCenterX(in: cg) }
            } catch {
                // A single un-decodable frame is a gap, not a failure of the pass.
                logger.debug("reframe analyze: frame at \(t, format: .fixed(precision: 2))s failed: \(String(describing: error))")
                centerX = nil
            }
            samples.append(SubjectSample(seconds: t, centerX: centerX))
            t += step
        }
        return samples
    }

    /// Run face → person detection on one frame; return the dominant subject's
    /// normalized centre-x (Vision's origin is bottom-left; x is unaffected), or
    /// `nil` if nothing is found. Synchronous, off the render path.
    static func detectSubjectCenterX(in image: CGImage) -> Double? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        let faces = VNDetectFaceRectanglesRequest()
        try? handler.perform([faces])
        if let boxes = faces.results, !boxes.isEmpty {
            // Largest face = the presenter closest to camera.
            let biggest = boxes.max { a, b in
                (a.boundingBox.width * a.boundingBox.height) < (b.boundingBox.width * b.boundingBox.height)
            }
            if let b = biggest { return Double(b.boundingBox.midX) }
        }

        let people = VNDetectHumanRectanglesRequest()
        try? handler.perform([people])
        if let boxes = people.results, !boxes.isEmpty {
            let biggest = boxes.max { a, b in
                (a.boundingBox.width * a.boundingBox.height) < (b.boundingBox.width * b.boundingBox.height)
            }
            if let b = biggest { return Double(b.boundingBox.midX) }
        }
        return nil
    }
}

// MARK: - Subject-tracking reframer (the VerticalHighlightProducing seam)

/// Slice-3b production reframer: crops a 16:9 clip to 9:16 (default 1080×1920)
/// with a SUBJECT-FOLLOWING, per-time transform. Drop-in for the slice-3a
/// `AVFoundationVerticalReframer` (same `VerticalHighlightProducing` protocol,
/// same non-clobbering `… 9x16.mov` output, same audio-through behaviour).
///
/// Fallback guarantee: `tracking == false`, OR no subject detected, OR any
/// analysis error ⇒ it delegates to a real `AVFoundationVerticalReframer`, so
/// the result is byte-for-byte the slice-3a centred crop — NEVER worse than 3a.
final class SubjectTrackingVerticalReframer: VerticalHighlightProducing, @unchecked Sendable {
    enum ReframeError: Error, CustomStringConvertible {
        case noVideoTrack, exportSetupFailed, exportFailed(Error?)
        var description: String {
            switch self {
            case .noVideoTrack: return "horizontal clip has no video track to reframe"
            case .exportSetupFailed: return "vertical export session could not be created"
            case .exportFailed(let e): return "vertical subject-tracking export failed: \(String(describing: e))"
            }
        }
    }

    let width: Int
    let height: Int
    let analyzer: SubjectTrackAnalyzer
    /// Slice-3a centred reframer — the fallback and the ultimate degrade path.
    private let centered: AVFoundationVerticalReframer
    /// Toggle: when false, every reframe delegates to the centred (3a) path.
    /// Atomic so the App can flip it live without tearing a reframe.
    private let trackingFlag = OSAllocatedUnfairLock(initialState: true)
    /// When set, a JSON dump of the detected track + planned crop is written next
    /// to each output for offline eyeball review (see `PRISM_DCUT_REFRAME_DUMP`).
    private let dumpPlan: Bool
    private let logger = Logger(subsystem: "studio.prism", category: "dcut.reframe")

    init(width: Int = 1080, height: Int = 1920,
         analyzer: SubjectTrackAnalyzer = SubjectTrackAnalyzer(),
         dumpPlan: Bool = ProcessInfo.processInfo.environment["PRISM_DCUT_REFRAME_DUMP"] != nil) {
        self.width = width
        self.height = height
        self.analyzer = analyzer
        self.centered = AVFoundationVerticalReframer(width: width, height: height)
        self.dumpPlan = dumpPlan
    }

    var tracking: Bool {
        get { trackingFlag.withLock { $0 } }
        set { trackingFlag.withLock { $0 = newValue } }
    }

    func reframeToVertical(horizontal src: URL, to url: URL) async throws -> URL {
        // Toggle off → exact slice-3a behaviour.
        guard tracking else { return try await centered.reframeToVertical(horizontal: src, to: url) }

        let asset = AVURLAsset(url: src)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ReframeError.noVideoTrack
        }

        // Analyse for the subject track. Any failure → centred fallback (3a).
        let samples: [SubjectSample]
        do {
            samples = try await analyzer.analyze(asset: asset, track: track)
        } catch {
            logger.error("reframe analysis failed — falling back to centred (3a): \(String(describing: error))")
            return try await centered.reframeToVertical(horizontal: src, to: url)
        }

        let geo = try await Geometry(asset: asset, track: track, renderW: width, renderH: height)
        let plan = SubjectReframePlanner.plan(track: samples, config: geo.planConfig())

        // No usable detection → centred (3a). Guarantees never-worse-than-3a AND
        // reuses the identical export path so the bytes match slice-3a.
        if plan.isCentered {
            return try await centered.reframeToVertical(horizontal: src, to: url)
        }

        let target = try await applyTrackingCrop(asset: asset, track: track, geo: geo, plan: plan, to: url)
        if dumpPlan { writePlanDump(samples: samples, plan: plan, geo: geo, beside: target) }
        return target
    }

    // MARK: Geometry (shared with slice-3a's centred math)

    /// Display-oriented source geometry + the derived 9:16 crop metrics. Centre
    /// c ∈ [0,1] maps to a horizontal translate `tx(c)` such that c=0.5 reproduces
    /// slice-3a's centred crop exactly (verified below), clamped so the scaled
    /// content always covers the canvas (no black edges).
    struct Geometry: Sendable {
        let preferred: CGAffineTransform
        let renderW: CGFloat, renderH: CGFloat
        let scale: CGFloat
        let croppedW: CGFloat
        let fps: Float

        init(asset: AVAsset, track: AVAssetTrack, renderW: Int, renderH: Int) async throws {
            let naturalSize = try await track.load(.naturalSize)
            self.preferred = try await track.load(.preferredTransform)
            let nominalFPS = try await track.load(.nominalFrameRate)
            self.fps = nominalFPS > 0 ? nominalFPS : 60
            self.renderW = CGFloat(renderW)
            self.renderH = CGFloat(renderH)
            let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferred)
            let orientedW = abs(oriented.width), orientedH = abs(oriented.height)
            guard orientedW > 0, orientedH > 0 else {
                throw SubjectTrackingVerticalReframer.ReframeError.noVideoTrack
            }
            self.scale = self.renderH / orientedH          // hero-fill: fill height
            self.croppedW = orientedW * scale
        }

        /// Memberwise init — lets the crop math be unit-tested without a real asset.
        init(preferred: CGAffineTransform, renderW: CGFloat, renderH: CGFloat,
             scale: CGFloat, croppedW: CGFloat, fps: Float) {
            self.preferred = preferred; self.renderW = renderW; self.renderH = renderH
            self.scale = scale; self.croppedW = croppedW; self.fps = fps
        }

        /// Half the visible crop width in normalized source units — the planner's
        /// in-bounds clamp bound.
        func planConfig() -> SubjectReframePlanConfig {
            let half = croppedW > 0 ? Double(renderW / (2 * croppedW)) : 0.5
            return SubjectReframePlanConfig(halfWindow: min(max(half, 0), 0.5))
        }

        /// Horizontal translate for a crop centred on normalized source-x `c`,
        /// clamped so the scaled content covers `[0, renderW]`. c=0.5 ⇒
        /// `(renderW − croppedW)/2` — identical to slice-3a.
        func tx(for c: Double) -> CGFloat {
            let raw = renderW / 2 - CGFloat(c) * croppedW
            let lo = renderW - croppedW   // ≤ 0 (croppedW ≥ renderW): right edge
            let hi: CGFloat = 0           // left edge
            return min(max(raw, lo), hi)
        }

        /// Full affine for a crop centred on `c` (preferred · scale · translate).
        func transform(for c: Double) -> CGAffineTransform {
            preferred
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: tx(for: c), y: 0))
        }
    }

    // MARK: Per-time transform application

    /// Build an `AVMutableVideoComposition` whose single layer instruction pans
    /// the crop across the timeline via transform RAMPS between plan keyframes
    /// (each keyframe interval → one linear `setTransformRamp`; scale is constant
    /// so the matrix interp reduces to a linear tx pan). Audio carried through.
    private func applyTrackingCrop(asset: AVAsset, track: AVAssetTrack, geo: Geometry,
                                   plan: SubjectReframePlan, to url: URL) async throws -> URL {
        let duration = try await asset.load(.duration)
        let renderSize = CGSize(width: width, height: height)

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let kfs = plan.keyframes
        // Open framed on the first keyframe.
        layer.setTransform(geo.transform(for: kfs[0].center), at: .zero)
        // Ramp between consecutive keyframes (clamped to the clip duration).
        for i in 1..<kfs.count {
            let a = kfs[i - 1], b = kfs[i]
            let start = CMTime(seconds: a.seconds, preferredTimescale: 600)
            var end = CMTime(seconds: b.seconds, preferredTimescale: 600)
            if CMTimeCompare(end, duration) > 0 { end = duration }
            let range = CMTimeRange(start: start, end: end)
            guard range.duration.seconds > 0 else { continue }
            layer.setTransformRamp(fromStart: geo.transform(for: a.center),
                                   toEnd: geo.transform(for: b.center),
                                   timeRange: range)
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]

        let comp = AVMutableVideoComposition()
        comp.renderSize = renderSize
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(geo.fps.rounded()))
        comp.instructions = [instruction]

        let out = RecorderFilePath.nonClobbering(url)
        guard let export = AVAssetExportSession(asset: asset,
                                                presetName: AVAssetExportPresetHighestQuality) else {
            throw ReframeError.exportSetupFailed
        }
        export.outputURL = out
        export.outputFileType = .mov
        export.videoComposition = comp   // audio (master mix) carried through untouched

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            export.exportAsynchronously {
                switch export.status {
                case .completed: cont.resume()
                default: cont.resume(throwing: ReframeError.exportFailed(export.error))
                }
            }
        }
        return out
    }

    // MARK: Offline-review dump (eyeball aid)

    /// Write a `<output>.reframe.json` sidecar: the sampled subject track + the
    /// planned crop centres, so a reviewer can plot the follow and eyeball the
    /// rendered clip against it. Best-effort; never disrupts the reframe.
    private func writePlanDump(samples: [SubjectSample], plan: SubjectReframePlan,
                               geo: Geometry, beside output: URL) {
        struct Dump: Encodable {
            struct S: Encodable { let t: Double; let detectedCenterX: Double?; let plannedCenter: Double }
            let renderWidth: Int, renderHeight: Int
            let halfWindow: Double
            let samples: [S]
        }
        let cfg = geo.planConfig()
        let rows = samples.map {
            Dump.S(t: $0.seconds, detectedCenterX: $0.centerX, plannedCenter: plan.center(at: $0.seconds))
        }
        let dump = Dump(renderWidth: width, renderHeight: height,
                        halfWindow: cfg.halfWindow, samples: rows)
        let sidecar = output.deletingPathExtension().appendingPathExtension("reframe.json")
        if let data = try? JSONEncoder().encode(dump) { try? data.write(to: sidecar) }
    }
}
