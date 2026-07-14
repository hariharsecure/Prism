import CoreGraphics
import Foundation

/// A value that can be linearly interpolated — the substrate every
/// keyframe track operates on.
public protocol Animatable: Sendable {
    /// Linear interpolation: `t = 0` → `from`, `t = 1` → `to`.
    /// `t` outside [0, 1] extrapolates (easing curves may overshoot —
    /// springs and back-style beziers rely on this).
    static func lerp(_ from: Self, _ to: Self, _ t: Double) -> Self
}

extension Double: Animatable {
    public static func lerp(_ from: Double, _ to: Double, _ t: Double) -> Double {
        from + (to - from) * t
    }
}

extension CGFloat: Animatable {
    public static func lerp(_ from: CGFloat, _ to: CGFloat, _ t: Double) -> CGFloat {
        from + (to - from) * CGFloat(t)
    }
}

extension CGPoint: Animatable {
    public static func lerp(_ from: CGPoint, _ to: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: CGFloat.lerp(from.x, to.x, t),
                y: CGFloat.lerp(from.y, to.y, t))
    }
}

extension CGSize: Animatable {
    public static func lerp(_ from: CGSize, _ to: CGSize, _ t: Double) -> CGSize {
        CGSize(width: CGFloat.lerp(from.width, to.width, t),
               height: CGFloat.lerp(from.height, to.height, t))
    }
}

extension CGRect: Animatable {
    public static func lerp(_ from: CGRect, _ to: CGRect, _ t: Double) -> CGRect {
        CGRect(origin: CGPoint.lerp(from.origin, to.origin, t),
               size: CGSize.lerp(from.size, to.size, t))
    }
}
