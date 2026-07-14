import CoreGraphics
import Foundation
import PrismCompositor

/// An edge of the normalized canvas (top-left origin, y-down — the
/// compositor's `Layer.frame` convention).
public enum CanvasEdge: String, Codable, Equatable, Sendable {
    case top, bottom, left, right
}

/// Ways a layer can arrive on the canvas. Each case is a factory: give it
/// the layer's *resting* state (where the scene wants the layer to sit) and
/// it builds a `LayerAnimation` that ends exactly there.
public enum LayerEntrance: Codable, Equatable, Sendable {
    /// Slide in from just outside the given edge to the resting frame.
    case slideIn(from: CanvasEdge)
    /// Opacity 0 → the layer's resting opacity.
    case fadeIn
    /// Grow from `fromScale` × resting size (about the resting center) while
    /// fading in.
    case scaleIn(fromScale: Double)
    /// Scale up with a springy overshoot ("pop") while fading in.
    case pop

    /// Build the animation. `easing` defaults per kind (`.ease` for moves,
    /// `.defaultSpring` for `.pop`).
    public func animation(for resting: Layer,
                          duration: Double,
                          easing: Easing? = nil) -> LayerAnimation {
        let restingOpacity = Double(resting.opacity)
        switch self {
        case .slideIn(let edge):
            return LayerAnimation(
                frame: Track(from: resting.frame.offscreen(beyond: edge),
                             to: resting.frame,
                             duration: duration,
                             easing: easing ?? .ease))
        case .fadeIn:
            return LayerAnimation(
                opacity: Track(from: 0, to: restingOpacity,
                               duration: duration, easing: easing ?? .ease))
        case .scaleIn(let fromScale):
            return LayerAnimation(
                frame: Track(from: resting.frame.scaled(by: fromScale),
                             to: resting.frame,
                             duration: duration, easing: easing ?? .ease),
                opacity: Track(from: 0, to: restingOpacity,
                               duration: duration, easing: easing ?? .ease))
        case .pop:
            return LayerAnimation(
                frame: Track(from: resting.frame.scaled(by: 0.6),
                             to: resting.frame,
                             duration: duration, easing: easing ?? .defaultSpring),
                // Fade completes in the first third so the overshoot reads
                // as motion, not as a translucency artifact.
                opacity: Track([
                    Keyframe(time: 0, value: 0, easing: .quadOut),
                    Keyframe(time: duration / 3, value: restingOpacity),
                    Keyframe(time: duration, value: restingOpacity),
                ]))
        }
    }
}

/// Ways a layer can leave the canvas. Each animation *starts* at the
/// resting state and ends offscreen / invisible.
public enum LayerExit: Codable, Equatable, Sendable {
    /// Slide from the resting frame to just outside the given edge.
    case slideOut(to: CanvasEdge)
    /// Resting opacity → 0.
    case fadeOut
    /// Shrink toward the resting center (to `toScale` × size) while fading out.
    case scaleOut(toScale: Double)

    public func animation(for resting: Layer,
                          duration: Double,
                          easing: Easing? = nil) -> LayerAnimation {
        let restingOpacity = Double(resting.opacity)
        switch self {
        case .slideOut(let edge):
            return LayerAnimation(
                frame: Track(from: resting.frame,
                             to: resting.frame.offscreen(beyond: edge),
                             duration: duration,
                             easing: easing ?? .ease))
        case .fadeOut:
            return LayerAnimation(
                opacity: Track(from: restingOpacity, to: 0,
                               duration: duration, easing: easing ?? .ease))
        case .scaleOut(let toScale):
            return LayerAnimation(
                frame: Track(from: resting.frame,
                             to: resting.frame.scaled(by: toScale),
                             duration: duration, easing: easing ?? .ease),
                opacity: Track(from: restingOpacity, to: 0,
                               duration: duration, easing: easing ?? .ease))
        }
    }
}

extension CGRect {
    /// This rect translated to sit entirely outside the unit canvas past
    /// `edge` (flush against it), preserving size and cross-axis position.
    func offscreen(beyond edge: CanvasEdge) -> CGRect {
        var rect = self
        switch edge {
        case .left: rect.origin.x = -rect.width
        case .right: rect.origin.x = 1
        case .top: rect.origin.y = -rect.height   // y-down: top is y = 0
        case .bottom: rect.origin.y = 1
        }
        return rect
    }

    /// This rect scaled about its own center.
    func scaled(by scale: Double) -> CGRect {
        let s = CGFloat(scale)
        return CGRect(x: midX - width * s / 2,
                      y: midY - height * s / 2,
                      width: width * s,
                      height: height * s)
    }
}
