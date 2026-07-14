import CoreGraphics
import Foundation
import PrismCore

/// Typed configuration for face-aware auto-framing (Center-Stage-like crop).
public struct AutoFramerConfig: Sendable, Equatable {
    /// Target fraction of the crop's height the face should occupy. Smaller =
    /// wider shot (more room around the subject). 0.45 ≈ a comfortable
    /// head-and-shoulders.
    public var subjectHeightFraction: CGFloat
    /// Empty space to keep *above* the face, as a fraction of crop height.
    public var headroom: CGFloat
    /// Crop aspect ratio (width/height) in **normalized source space**
    /// (= outputAspect / sourceAspect). 1.0 keeps the crop square in normalized
    /// units; the app passes the real ratio so the crop matches the program.
    public var aspect: CGFloat
    /// EMA factor per update, 0…1. Lower = smoother/slower glide (less jitter),
    /// higher = snappier. 0.2 is a calm Center-Stage feel.
    public var smoothing: CGFloat
    /// Smallest allowed crop height (don't zoom in past this — avoids a
    /// pixelated punch-in on a tiny/distant face).
    public var minCropHeight: CGFloat
    /// Largest allowed crop height (1.0 = the whole source).
    public var maxCropHeight: CGFloat

    public init(subjectHeightFraction: CGFloat = 0.45,
                headroom: CGFloat = 0.12,
                aspect: CGFloat = 16.0 / 9.0,
                smoothing: CGFloat = 0.2,
                minCropHeight: CGFloat = 0.25,
                maxCropHeight: CGFloat = 1.0) {
        self.subjectHeightFraction = max(0.05, min(1, subjectHeightFraction))
        self.headroom = max(0, min(0.9, headroom))
        self.aspect = max(0.01, aspect)
        self.smoothing = max(0.001, min(1, smoothing))
        self.minCropHeight = max(0.01, min(1, minCropHeight))
        self.maxCropHeight = max(self.minCropHeight, min(1, maxCropHeight))
    }
}

/// Turns a face bounding box into a **smoothed, in-bounds crop rect** that keeps
/// the subject composed with headroom — the geometry behind DESIGN §2.3's
/// "Face-aware auto-framing (Center Stage-like crop)".
///
/// Pure and testable: no pixels. `update` takes a normalized top-left-origin
/// face rect (as produced by `DirectorAnalyzer`/`SourceSignal.faceBounds`) and
/// returns a normalized top-left-origin crop rect suitable for
/// `PrismCompositor.Layer.crop`. Temporal smoothing is a per-component
/// exponential moving average toward the target, so the crop **glides** instead
/// of snapping; both the target and the smoothed result are clamped fully
/// inside 0…1, so the EMA (a convex blend of two in-bounds rects) can never
/// leave the frame.
public final class AutoFramer {
    public var config: AutoFramerConfig
    private var current: CGRect?

    public init(config: AutoFramerConfig = AutoFramerConfig()) {
        self.config = config
    }

    /// The last emitted crop (nil before the first `update`).
    public var currentCrop: CGRect? { current }

    /// Reset smoothing state (next `update` snaps straight to its target).
    public func reset() { current = nil }

    /// Advance the framer.
    /// - Parameter faceBounds: normalized top-left-origin face rect, or nil.
    ///   When nil, the framer eases toward the **full frame** (0,0,1,1) — a
    ///   graceful "lost the subject, pull back to safe wide" behavior.
    /// - Returns: the smoothed, clamped crop rect (normalized, top-left origin).
    @discardableResult
    public func update(faceBounds: CGRect?) -> CGRect {
        let target = clampInBounds(targetCrop(for: faceBounds))
        guard let prev = current else {
            current = target        // first frame snaps (no history to ease from)
            return target
        }
        let a = config.smoothing
        let eased = CGRect(
            x: prev.origin.x + a * (target.origin.x - prev.origin.x),
            y: prev.origin.y + a * (target.origin.y - prev.origin.y),
            width: prev.size.width + a * (target.size.width - prev.size.width),
            height: prev.size.height + a * (target.size.height - prev.size.height)
        )
        current = eased
        return eased
    }

    /// The un-smoothed crop the framer is easing toward, for the given face.
    func targetCrop(for faceBounds: CGRect?) -> CGRect {
        guard let face = faceBounds, face.height > 0, face.width > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        // Height from the desired subject coverage, clamped to zoom limits.
        var h = face.height / config.subjectHeightFraction
        h = max(config.minCropHeight, min(config.maxCropHeight, h))
        var w = h * config.aspect
        if w > 1 { w = 1; h = min(h, w / config.aspect) }
        h = min(h, 1)

        let faceCenterX = face.midX
        let faceTopY = face.minY
        // Center horizontally on the face; place the face top `headroom` below
        // the crop top.
        let originX = faceCenterX - w / 2
        let originY = faceTopY - config.headroom * h
        return CGRect(x: originX, y: originY, width: w, height: h)
    }

    /// Clamp a crop so it lies fully within the 0…1 source, preserving size
    /// where possible (shifting origin), shrinking only if the size itself
    /// exceeds the frame.
    private func clampInBounds(_ rect: CGRect) -> CGRect {
        var w = min(max(rect.width, 0), 1)
        var h = min(max(rect.height, 0), 1)
        if w <= 0 { w = 1 }
        if h <= 0 { h = 1 }
        var x = rect.origin.x
        var y = rect.origin.y
        if x < 0 { x = 0 }
        if y < 0 { y = 0 }
        if x + w > 1 { x = 1 - w }
        if y + h > 1 { y = 1 - h }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
