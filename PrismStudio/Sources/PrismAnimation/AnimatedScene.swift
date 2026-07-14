import Foundation
import PrismCompositor
import PrismCore

/// What happens to animation-local time outside the animation's duration.
public enum PlaybackPolicy: String, Codable, Equatable, Sendable {
    /// Clamp: hold the first values before start, the last values after the
    /// end (the layer "parks" at its final keyframes).
    case hold
    /// Wrap modulo the duration — the animation repeats forever.
    /// (Before the start time it still holds the first values.)
    case loop
    /// Alternate forward/backward each period.
    case pingPong

    /// Map elapsed seconds (may be negative or past `duration`) to
    /// animation-local time in [0, duration].
    public func localTime(forElapsed elapsed: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        if elapsed <= 0 { return 0 }
        switch self {
        case .hold:
            return min(elapsed, duration)
        case .loop:
            return elapsed.truncatingRemainder(dividingBy: duration)
        case .pingPong:
            let phase = elapsed.truncatingRemainder(dividingBy: 2 * duration)
            return phase <= duration ? phase : 2 * duration - phase
        }
    }
}

/// A `Scene` plus keyframe animations for some of its layers, anchored at a
/// house-time instant.
///
/// `evaluate(at:)` is the module's entire contract with the renderer: it
/// returns a plain compositor `Scene` with layer overrides applied. The
/// compositor never learns about keyframes, easing, or time-mapping — it
/// just draws whatever scene the render loop hands it (DESIGN.md §3.7).
public struct AnimatedScene: Codable, Equatable, Sendable {
    /// The resting scene: every layer's un-animated state.
    public var base: Scene
    /// Per-layer animations keyed by the layer's `sourceID`. Layers without
    /// an entry pass through untouched. (If a scene has several layers with
    /// the same source, they share the animation.)
    public var animations: [SourceID: LayerAnimation]
    /// House-time seconds (`HouseClock.nowSeconds()` domain) at which
    /// animation-local time 0 occurs.
    public var startTime: Double
    /// Behavior outside [startTime, startTime + duration].
    public var policy: PlaybackPolicy

    public init(base: Scene,
                animations: [SourceID: LayerAnimation] = [:],
                startTime: Double = 0,
                policy: PlaybackPolicy = .hold) {
        self.base = base
        self.animations = animations
        self.startTime = startTime
        self.policy = policy
    }

    /// Longest animation duration across all layers (seconds).
    public var duration: Double {
        animations.values.map(\.duration).max() ?? 0
    }

    /// True once every animation has reached its final keyframes
    /// (only meaningful for `.hold`; looping policies never finish).
    public func isFinished(at houseSeconds: Double) -> Bool {
        policy == .hold && houseSeconds - startTime >= duration
    }

    /// Sample all animations at a house-time instant and return the plain
    /// `Scene` to composite. Time-mapping (start offset + repeat policy) is
    /// applied uniformly, so multi-layer moves stay in lockstep.
    public func evaluate(at houseSeconds: Double) -> Scene {
        guard !animations.isEmpty else { return base }
        let local = policy.localTime(forElapsed: houseSeconds - startTime, duration: duration)
        var scene = base
        scene.layers = base.layers.map { layer in
            guard let animation = animations[layer.sourceID] else { return layer }
            return animation.apply(to: layer, at: local)
        }
        return scene
    }
}
