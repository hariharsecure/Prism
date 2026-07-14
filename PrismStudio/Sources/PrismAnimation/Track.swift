import Foundation

/// One point on a track: a value at a time, plus the easing used to travel
/// from this keyframe to the *next* one (ignored on the last keyframe).
public struct Keyframe<V: Animatable>: Sendable {
    /// Track-local time in seconds (relative to the animation's start).
    public var time: Double
    public var value: V
    /// Timing curve applied on the segment from this keyframe to the next.
    public var easing: Easing

    public init(time: Double, value: V, easing: Easing = .linear) {
        self.time = time
        self.value = value
        self.easing = easing
    }
}

/// A sampled-anywhere sequence of keyframes for one animatable property.
///
/// Keyframes are kept sorted by time (stable — construction order breaks
/// ties). Sampling clamps: before the first keyframe the first value holds,
/// after the last the last value holds; between a pair the segment's easing
/// shapes the interpolation.
public struct Track<V: Animatable>: Sendable {
    /// Sorted ascending by `time`.
    public private(set) var keyframes: [Keyframe<V>]

    public init(_ keyframes: [Keyframe<V>] = []) {
        self.keyframes = keyframes.sorted { $0.time < $1.time }
    }

    /// Convenience: a two-keyframe track from `from` at t=0 to `to` at
    /// t=`duration`, eased by `easing`.
    public init(from: V, to: V, duration: Double, easing: Easing = .linear) {
        self.init([Keyframe(time: 0, value: from, easing: easing),
                   Keyframe(time: duration, value: to)])
    }

    public var isEmpty: Bool { keyframes.isEmpty }

    /// Time of the last keyframe (0 if empty).
    public var duration: Double { keyframes.last?.time ?? 0 }

    /// Insert a keyframe, keeping sort order.
    public mutating func insert(_ keyframe: Keyframe<V>) {
        let index = keyframes.firstIndex { $0.time > keyframe.time } ?? keyframes.endIndex
        keyframes.insert(keyframe, at: index)
    }

    /// Sample the track at `time` (seconds, track-local).
    /// Returns `nil` only for an empty track.
    public func sample(at time: Double) -> V? {
        guard let first = keyframes.first, let last = keyframes.last else { return nil }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        // Binary search for the segment: greatest i with kf[i].time <= time.
        var lo = 0, hi = keyframes.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if keyframes[mid].time <= time { lo = mid } else { hi = mid }
        }
        let a = keyframes[lo], b = keyframes[hi]
        let span = b.time - a.time
        guard span > 0 else { return b.value }   // coincident keyframes: step
        let u = (time - a.time) / span
        return V.lerp(a.value, b.value, a.easing.apply(u))
    }
}

extension Keyframe: Equatable where V: Equatable {}
extension Keyframe: Codable where V: Codable {}
extension Track: Equatable where V: Equatable {}
extension Track: Codable where V: Codable {}
