import CoreGraphics
import Foundation
import PrismCompositor

/// Keyframe tracks bound to the animatable properties of a compositor
/// `Layer`. A `nil` track leaves that property untouched, so animations
/// compose with whatever the scene already defines.
///
/// Pure: `apply(to:at:)` returns a *new* `Layer` — nothing here talks to
/// the renderer (DESIGN.md §3.7: the compositor stays dumb).
public struct LayerAnimation: Codable, Equatable, Sendable {
    /// Canvas placement (normalized 0…1, top-left origin — see `Layer.frame`).
    public var frame: Track<CGRect>?
    /// Opacity 0…1. Sampled as Double, clamped, written to `Layer.opacity` (Float).
    public var opacity: Track<Double>?
    /// Source crop (normalized 0…1 — see `Layer.crop`).
    public var crop: Track<CGRect>?

    public init(frame: Track<CGRect>? = nil,
                opacity: Track<Double>? = nil,
                crop: Track<CGRect>? = nil) {
        self.frame = frame
        self.opacity = opacity
        self.crop = crop
    }

    /// Longest track duration — the animation is "done" past this time.
    public var duration: Double {
        max(frame?.duration ?? 0, opacity?.duration ?? 0, crop?.duration ?? 0)
    }

    /// Sample every track at `time` (animation-local seconds) and return
    /// the layer with those properties overridden.
    public func apply(to layer: Layer, at time: Double) -> Layer {
        var result = layer
        if let value = frame?.sample(at: time) { result.frame = value }
        if let value = opacity?.sample(at: time) {
            result.opacity = Float(min(max(value, 0), 1))
        }
        if let value = crop?.sample(at: time) { result.crop = value }
        return result
    }
}
