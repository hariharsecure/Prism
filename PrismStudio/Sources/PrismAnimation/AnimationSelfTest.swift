import CoreGraphics
import Foundation
import PrismCompositor
import PrismCore

/// A self-test failure: which check broke and how.
public enum AnimationSelfTestError: Error, CustomStringConvertible {
    case checkFailed(String)
    public var description: String {
        switch self {
        case .checkFailed(let message): return "AnimationSelfTest: \(message)"
        }
    }
}

/// Runnable verification of the whole module — pure math, no hardware, no
/// permissions (AGENTS.md #8). Kept behind public API because module agents
/// may not register test targets; the integrator can also call this from
/// XCTest with a one-liner.
public enum AnimationSelfTest {
    private static let log = EngineLog.logger("animation")

    /// Run every check; throws `AnimationSelfTestError` on the first failure.
    public static func run() throws {
        try easingEndpointsAndMonotonicity()
        try bezierAgainstCSSReferences()
        try springSettles()
        try trackSampling()
        try layerAnimationApply()
        try animatedSceneEvaluation()
        try playbackPolicies()
        try entranceExitPresets()
        try sceneTransitions()
        log.info("AnimationSelfTest: all checks passed")
    }

    // MARK: - Helpers

    private static func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw AnimationSelfTestError.checkFailed(message()) }
    }

    private static func approx(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
        abs(a - b) <= tolerance
    }

    private static func approx(_ a: CGRect, _ b: CGRect, _ tolerance: Double = 1e-9) -> Bool {
        approx(a.origin.x, b.origin.x, tolerance) && approx(a.origin.y, b.origin.y, tolerance)
            && approx(a.width, b.width, tolerance) && approx(a.height, b.height, tolerance)
    }

    // MARK: - Easing

    private static func easingEndpointsAndMonotonicity() throws {
        let monotonic: [(String, Easing)] = [
            ("linear", .linear),
            ("quadIn", .quadIn), ("quadOut", .quadOut), ("quadInOut", .quadInOut),
            ("cubicIn", .cubicIn), ("cubicOut", .cubicOut), ("cubicInOut", .cubicInOut),
            ("ease", .ease),
            ("bezier(0.42,0,0.58,1)", .cubicBezier(p1x: 0.42, p1y: 0, p2x: 0.58, p2y: 1)),
        ]
        let all = monotonic + [
            ("spring(10,100,0)", .defaultSpring),
            ("spring(30,100,0) critical", .spring(damping: 20, stiffness: 100, initialVelocity: 0)),
            ("spring(40,100,0) overdamped", .spring(damping: 40, stiffness: 100, initialVelocity: 0)),
            ("spring(v0=5)", .spring(damping: 12, stiffness: 180, initialVelocity: 5)),
        ]
        for (name, easing) in all {
            try require(approx(easing.apply(0), 0), "\(name): f(0) = \(easing.apply(0)) ≠ 0")
            try require(approx(easing.apply(1), 1), "\(name): f(1) = \(easing.apply(1)) ≠ 1")
            // Clamping outside [0,1].
            try require(approx(easing.apply(-0.5), 0), "\(name): f(-0.5) not clamped to 0")
            try require(approx(easing.apply(1.5), 1), "\(name): f(1.5) not clamped to 1")
        }
        for (name, easing) in monotonic {
            var previous = 0.0
            for step in 1...200 {
                let value = easing.apply(Double(step) / 200)
                try require(value >= previous - 1e-9,
                            "\(name): not monotonic at t=\(Double(step) / 200) (\(value) < \(previous))")
                previous = value
            }
            // Standard curves stay inside [0,1].
            try require(previous <= 1 + 1e-9, "\(name): exceeds 1")
        }
    }

    private static func bezierAgainstCSSReferences() throws {
        // References computed by an INDEPENDENT method (dense bisection on
        // the parametric polynomial, external script, 2026-07-07) — not by
        // this module's Newton solver. ease(0.5)=0.8024 also matches the
        // widely published CSS value.
        let cases: [(Easing, Double, Double)] = [
            (.ease, 0.25, 0.40851),
            (.ease, 0.50, 0.80240),
            (.ease, 0.75, 0.96046),
            (.cubicBezier(p1x: 0.42, p1y: 0, p2x: 0.58, p2y: 1), 0.25, 0.12916),
            (.cubicBezier(p1x: 0, p1y: 0, p2x: 0.58, p2y: 1), 0.5, 0.68464),
        ]
        for (easing, x, expected) in cases {
            let got = easing.apply(x)
            try require(abs(got - expected) < 0.01,
                        "bezier: f(\(x)) = \(got), expected \(expected) ± 0.01")
        }
        // Analytic anchors: identity bezier is y = x; a symmetric in-out
        // bezier passes through (0.5, 0.5) exactly.
        let identity = Easing.cubicBezier(p1x: 0, p1y: 0, p2x: 1, p2y: 1)
        try require(abs(identity.apply(0.3) - 0.3) < 1e-4, "identity bezier: f(0.3) ≠ 0.3")
        let symmetric = Easing.cubicBezier(p1x: 0.42, p1y: 0, p2x: 0.58, p2y: 1)
        try require(abs(symmetric.apply(0.5) - 0.5) < 1e-4, "symmetric bezier: f(0.5) ≠ 0.5")
    }

    private static func springSettles() throws {
        let springs: [(String, Easing)] = [
            ("underdamped", .spring(damping: 10, stiffness: 100, initialVelocity: 0)),
            ("critically damped", .spring(damping: 20, stiffness: 100, initialVelocity: 0)),
            ("overdamped", .spring(damping: 50, stiffness: 100, initialVelocity: 0)),
            ("with velocity", .spring(damping: 10, stiffness: 100, initialVelocity: 8)),
        ]
        for (name, spring) in springs {
            try require(approx(spring.apply(0), 0), "spring \(name): f(0) ≠ 0")
            try require(approx(spring.apply(1), 1), "spring \(name): f(1) ≠ 1")
            // Settled by construction: residual ≤ envelope ε near t = 1.
            for t in [0.97, 0.99, 0.999] {
                let value = spring.apply(t)
                try require(abs(value - 1) < 0.005,
                            "spring \(name): f(\(t)) = \(value), not settled near 1")
            }
            // Springs actually move: reach at least half-way by mid-flight.
            try require(spring.apply(0.5) > 0.5, "spring \(name): f(0.5) suspiciously low")
        }
        // The underdamped default overshoots (that's the point of a spring).
        let underdamped = Easing.defaultSpring
        let peak = (1...200).map { underdamped.apply(Double($0) / 200) }.max() ?? 0
        try require(peak > 1.0, "underdamped spring never overshoots (peak \(peak))")
    }

    // MARK: - Tracks

    private static func trackSampling() throws {
        // Empty track.
        try require(Track<Double>().sample(at: 0.5) == nil, "empty track should sample nil")

        // Single keyframe: constant everywhere.
        let constant = Track([Keyframe(time: 1, value: 7.0)])
        for t in [-1.0, 0.0, 1.0, 5.0] {
            try require(constant.sample(at: t) == 7.0, "single-keyframe track not constant at \(t)")
        }

        // Two keyframes, linear: clamp + midpoint.
        let linear = Track(from: 10.0, to: 20.0, duration: 2)
        try require(linear.sample(at: -1) == 10, "clamp before first failed")
        try require(linear.sample(at: 3) == 20, "clamp after last failed")
        try require(approx(linear.sample(at: 1)!, 15), "linear midpoint ≠ 15")
        try require(approx(linear.sample(at: 0.5)!, 12.5), "linear quarter ≠ 12.5")

        // Multi-keyframe with per-segment easing + unsorted input.
        var track = Track([
            Keyframe(time: 4, value: 0.0),                      // deliberately out of order
            Keyframe(time: 0, value: 0.0, easing: .linear),
            Keyframe(time: 2, value: 10.0, easing: .quadIn),
        ])
        try require(track.keyframes.map(\.time) == [0, 2, 4], "keyframes not sorted")
        try require(approx(track.sample(at: 1)!, 5), "segment 1 (linear) midpoint")
        // Segment 2 uses quadIn: at u = 0.5 → 0.25 of the way from 10 to 0.
        try require(approx(track.sample(at: 3)!, 10 - 2.5), "segment 2 (quadIn) easing not applied")
        try require(approx(track.sample(at: 2)!, 10), "exact keyframe time should return its value")

        // insert() keeps order.
        track.insert(Keyframe(time: 3, value: 100.0))
        try require(track.keyframes.map(\.time) == [0, 2, 3, 4], "insert broke sort order")
        try require(approx(track.sample(at: 3)!, 100), "inserted keyframe not sampled")

        // Coincident keyframes behave as a step, not a divide-by-zero.
        let step = Track([Keyframe(time: 1, value: 0.0), Keyframe(time: 1, value: 5.0)])
        try require(step.sample(at: 1) != nil, "coincident keyframes crashed/failed")

        // CGRect track interpolates all four components.
        let rects = Track(from: CGRect(x: 0, y: 0, width: 1, height: 1),
                          to: CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5),
                          duration: 1)
        try require(approx(rects.sample(at: 0.5)!,
                           CGRect(x: 0.25, y: 0.125, width: 0.75, height: 0.75)),
                    "CGRect lerp wrong")
    }

    // MARK: - LayerAnimation

    private static func layerAnimationApply() throws {
        let layer = Layer(sourceID: SourceID("cam"),
                          frame: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4),
                          opacity: 0.8, zIndex: 3)
        let animation = LayerAnimation(
            frame: Track(from: CGRect(x: 0, y: 0, width: 0.4, height: 0.4),
                         to: CGRect(x: 0.6, y: 0, width: 0.4, height: 0.4),
                         duration: 2),
            opacity: Track(from: 0, to: 1, duration: 1))
        try require(approx(animation.duration, 2), "LayerAnimation.duration ≠ max track duration")

        let mid = animation.apply(to: layer, at: 1)
        try require(approx(mid.frame, CGRect(x: 0.3, y: 0, width: 0.4, height: 0.4)),
                    "frame track not applied at t=1")
        try require(mid.opacity == 1, "opacity track not applied/clamped at t=1")
        // Untouched properties pass through.
        try require(mid.sourceID == layer.sourceID && mid.zIndex == 3 && mid.crop == layer.crop,
                    "apply(to:) must not disturb unanimated properties")
        // nil tracks leave the layer alone.
        let noop = LayerAnimation().apply(to: layer, at: 0.5)
        try require(noop == layer, "empty LayerAnimation must be identity")
        // Out-of-range opacity values clamp into Layer's 0…1 contract.
        let wild = LayerAnimation(opacity: Track(from: -1, to: 2, duration: 1))
        try require(wild.apply(to: layer, at: 0).opacity == 0
                        && wild.apply(to: layer, at: 1).opacity == 1,
                    "opacity not clamped to 0…1")
    }

    // MARK: - AnimatedScene

    private static func fixtureScene() -> (Scene, Layer, Layer) {
        let animated = Layer(sourceID: SourceID("cam"),
                             frame: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                             opacity: 1)
        let still = Layer(sourceID: SourceID("screen"),
                          frame: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        return (Scene(name: "fixture", layers: [animated, still]), animated, still)
    }

    private static func animatedSceneEvaluation() throws {
        let (scene, animatedLayer, stillLayer) = fixtureScene()
        let move = LayerAnimation(
            frame: Track(from: animatedLayer.frame,
                         to: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                         duration: 2),
            opacity: Track(from: 1, to: 0.5, duration: 2))
        let animated = AnimatedScene(base: scene,
                                     animations: [animatedLayer.sourceID: move],
                                     startTime: 100,
                                     policy: .hold)
        try require(approx(animated.duration, 2), "AnimatedScene.duration wrong")

        // Before start: resting/first-keyframe state.
        let before = animated.evaluate(at: 99)
        try require(approx(before.layers[0].frame, animatedLayer.frame), "pre-start frame wrong")
        try require(before.layers[0].opacity == 1, "pre-start opacity wrong")

        // Mid-flight (t = 1 of 2, linear): x = 0.25, opacity = 0.75.
        let mid = animated.evaluate(at: 101)
        try require(approx(mid.layers[0].frame, CGRect(x: 0.25, y: 0, width: 0.5, height: 0.5)),
                    "mid-flight frame wrong: \(mid.layers[0].frame)")
        try require(approx(Double(mid.layers[0].opacity), 0.75, 1e-6), "mid-flight opacity wrong")
        // The un-animated layer is untouched, and the scene shell survives.
        try require(mid.layers[1] == stillLayer, "un-animated layer disturbed")
        try require(mid.id == scene.id && mid.name == scene.name && mid.layers.count == 2,
                    "scene identity/shape disturbed")

        // After end (.hold): final keyframes, and isFinished flips.
        let after = animated.evaluate(at: 110)
        try require(approx(after.layers[0].frame, CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)),
                    "post-end frame should hold final value")
        try require(!animated.isFinished(at: 101) && animated.isFinished(at: 102.1),
                    "isFinished(at:) wrong")

        // Purity: evaluating must not mutate the AnimatedScene or its base.
        try require(animated.base == scene, "evaluate(at:) mutated base scene")
    }

    private static func playbackPolicies() throws {
        // Direct time-mapping checks.
        try require(PlaybackPolicy.hold.localTime(forElapsed: 5, duration: 2) == 2, "hold clamp")
        try require(PlaybackPolicy.hold.localTime(forElapsed: -1, duration: 2) == 0, "hold pre-start")
        try require(approx(PlaybackPolicy.loop.localTime(forElapsed: 2.5, duration: 2), 0.5), "loop wrap")
        try require(approx(PlaybackPolicy.loop.localTime(forElapsed: 6.5, duration: 2), 0.5), "loop wrap ×3")
        try require(approx(PlaybackPolicy.pingPong.localTime(forElapsed: 2.5, duration: 2), 1.5),
                    "pingPong reflect")
        try require(approx(PlaybackPolicy.pingPong.localTime(forElapsed: 4.5, duration: 2), 0.5),
                    "pingPong second period")
        // Zero-duration guard.
        try require(PlaybackPolicy.loop.localTime(forElapsed: 3, duration: 0) == 0, "zero duration")

        // Through AnimatedScene: loop repeats the flight path.
        let (scene, animatedLayer, _) = fixtureScene()
        let move = LayerAnimation(
            frame: Track(from: animatedLayer.frame,
                         to: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                         duration: 2))
        var animated = AnimatedScene(base: scene,
                                     animations: [animatedLayer.sourceID: move],
                                     startTime: 0, policy: .loop)
        let firstPass = animated.evaluate(at: 0.5).layers[0].frame
        let secondPass = animated.evaluate(at: 2.5).layers[0].frame
        try require(approx(firstPass, secondPass), "loop: pass 2 differs from pass 1")

        animated.policy = .pingPong
        let forward = animated.evaluate(at: 0.5).layers[0].frame
        let reflected = animated.evaluate(at: 3.5).layers[0].frame   // 3.5 → local 0.5 (reflected)
        try require(approx(forward, reflected), "pingPong: reflected sample differs")
    }

    // MARK: - Presets

    private static func entranceExitPresets() throws {
        let resting = Layer(sourceID: SourceID("cam"),
                            frame: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                            opacity: 0.9)
        let duration = 0.6

        // Every entrance ends exactly at the resting values.
        let entrances: [(String, LayerEntrance)] = [
            ("slideIn(left)", .slideIn(from: .left)),
            ("slideIn(top)", .slideIn(from: .top)),
            ("fadeIn", .fadeIn),
            ("scaleIn", .scaleIn(fromScale: 0.5)),
            ("pop", .pop),
        ]
        for (name, entrance) in entrances {
            let animation = entrance.animation(for: resting, duration: duration)
            let end = animation.apply(to: resting, at: duration)
            try require(approx(end.frame, resting.frame, 1e-6),
                        "\(name): end frame ≠ resting (\(end.frame))")
            try require(abs(Double(end.opacity) - 0.9) < 1e-6,
                        "\(name): end opacity ≠ resting (\(end.opacity))")
        }

        // Entrance starts: offscreen / invisible / scaled as advertised.
        let slideStart = LayerEntrance.slideIn(from: .left)
            .animation(for: resting, duration: duration).apply(to: resting, at: 0)
        try require(approx(slideStart.frame.maxX, 0, 1e-9), "slideIn(left) start not flush offscreen")
        try require(approx(slideStart.frame.origin.y, 0.25), "slideIn must not move the cross axis")
        let fadeStart = LayerEntrance.fadeIn
            .animation(for: resting, duration: duration).apply(to: resting, at: 0)
        try require(fadeStart.opacity == 0, "fadeIn start opacity ≠ 0")
        let scaleStart = LayerEntrance.scaleIn(fromScale: 0.5)
            .animation(for: resting, duration: duration).apply(to: resting, at: 0)
        try require(approx(scaleStart.frame.width, 0.25) && approx(scaleStart.frame.midX, 0.5),
                    "scaleIn start not center-scaled")

        // Every exit starts exactly at the resting values.
        let exits: [(String, LayerExit)] = [
            ("slideOut(right)", .slideOut(to: .right)),
            ("slideOut(bottom)", .slideOut(to: .bottom)),
            ("fadeOut", .fadeOut),
            ("scaleOut", .scaleOut(toScale: 0.2)),
        ]
        for (name, exit) in exits {
            let animation = exit.animation(for: resting, duration: duration)
            let start = animation.apply(to: resting, at: 0)
            try require(approx(start.frame, resting.frame, 1e-6),
                        "\(name): start frame ≠ resting")
            try require(abs(Double(start.opacity) - 0.9) < 1e-6,
                        "\(name): start opacity ≠ resting")
        }
        // Exit ends: offscreen / invisible.
        let slideEnd = LayerExit.slideOut(to: .right)
            .animation(for: resting, duration: duration).apply(to: resting, at: duration)
        try require(slideEnd.frame.minX >= 1 - 1e-9, "slideOut(right) end not offscreen")
        let fadeEnd = LayerExit.fadeOut
            .animation(for: resting, duration: duration).apply(to: resting, at: duration)
        try require(fadeEnd.opacity == 0, "fadeOut end opacity ≠ 0")

        // All four edges land fully outside the unit canvas.
        for edge in [CanvasEdge.top, .bottom, .left, .right] {
            let start = LayerEntrance.slideIn(from: edge)
                .animation(for: resting, duration: duration).apply(to: resting, at: 0)
            let f = start.frame
            let outside = f.maxX <= 1e-9 || f.minX >= 1 - 1e-9 || f.maxY <= 1e-9 || f.minY >= 1 - 1e-9
            try require(outside, "slideIn(\(edge)) start frame \(f) not outside canvas")
        }
    }

    // MARK: - Transitions

    private static func sceneTransitions() throws {
        let transition = SceneTransition(kind: .crossfade, duration: 0.5, curve: .quadInOut)
        try require(transition.progress(at: -1) == 0, "progress before start ≠ 0")
        try require(transition.progress(at: 0) == 0, "progress at 0 ≠ 0")
        try require(transition.progress(at: 0.5) == 1, "progress at duration ≠ 1")
        try require(transition.progress(at: 9) == 1, "progress after end ≠ 1")
        try require(approx(transition.progress(at: 0.25), 0.5), "quadInOut midpoint ≠ 0.5")
        // Eased, not raw: quarter-time through quadInOut is 2·0.25² = 0.125.
        try require(approx(transition.progress(at: 0.125), 0.125), "progress not eased")
        // Zero-duration transition = instant cut.
        let cut = SceneTransition(kind: .crossfade, duration: 0)
        try require(cut.progress(at: 0) == 1 && cut.progress(at: -0.001) == 0,
                    "zero-duration transition should cut")

        // Crossfade generates no layer motion (mix stage owns it).
        let (scene, animatedLayer, stillLayer) = fixtureScene()
        try require(transition.outgoingAnimations(for: scene).isEmpty
                        && transition.incomingAnimations(for: scene).isEmpty,
                    "crossfade must not generate layer animations")

        // Slide left: outgoing exits left, incoming enters from the right.
        let slide = SceneTransition(kind: .slide(direction: .left), duration: 0.5, curve: .linear)
        let outgoing = slide.outgoingAnimations(for: scene)
        let incoming = slide.incomingAnimations(for: scene)
        try require(outgoing.count == 2 && incoming.count == 2,
                    "slide should animate every visible layer")

        // Outgoing: starts at resting, ends offscreen left.
        let outAnim = outgoing[animatedLayer.sourceID]!
        try require(approx(outAnim.apply(to: animatedLayer, at: 0).frame, animatedLayer.frame),
                    "slide outgoing must start at resting")
        let outEnd = outAnim.apply(to: animatedLayer, at: 0.5).frame
        try require(outEnd.maxX <= 1e-9, "slide outgoing end not offscreen left: \(outEnd)")

        // Incoming: starts offscreen right, ends at resting.
        let inAnim = incoming[stillLayer.sourceID]!
        let inStart = inAnim.apply(to: stillLayer, at: 0).frame
        try require(inStart.minX >= 1 - 1e-9, "slide incoming start not offscreen right: \(inStart)")
        try require(approx(inAnim.apply(to: stillLayer, at: 0.5).frame, stillLayer.frame),
                    "slide incoming must end at resting")

        // Hidden layers are skipped.
        var withHidden = scene
        withHidden.layers[1].isHidden = true
        try require(slide.outgoingAnimations(for: withHidden).count == 1,
                    "hidden layers should not get transition animations")

        // dipToColor placeholder: progress-only, no layer animations.
        let dip = SceneTransition(kind: .dipToColor(.black), duration: 1)
        try require(dip.outgoingAnimations(for: scene).isEmpty
                        && dip.incomingAnimations(for: scene).isEmpty,
                    "dipToColor must not generate layer animations")
    }
}
