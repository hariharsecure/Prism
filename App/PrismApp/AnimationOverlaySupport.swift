import CoreGraphics
import Foundation
import PrismCompositor
import PrismCore
import SwiftUI

// MARK: - Color bridge (SwiftUI Color → compositor RGBA)

extension Color {
    /// This SwiftUI color as a compositor-space `RGBA` (sRGB, 0…1). Mirrors the
    /// `Color.rgbaColor` bridge in `GeneratedSources.swift`, but yields the
    /// `PrismCompositor.RGBA` the VisualFX renderers (`TickerStyle`, `LogoStyle`)
    /// consume rather than `PrismCore.RGBAColor`.
    var compositorRGBA: RGBA {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return RGBA(r: Double(ns.redComponent), g: Double(ns.greenComponent),
                    b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }
}

// MARK: - Animated logo (DESIGN §1: AnimatedLogoSource)

/// Flat, `Picker`-bindable companion for `LogoEntrance` (whose `.slide` case
/// carries an edge). The Inspector binds this; `entrance` maps back.
enum LogoEntranceChoice: String, CaseIterable, Identifiable {
    case fade, slideLeft, slideRight, slideTop, slideBottom, scalePop, spinIn, blurIn
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fade:        return "Fade"
        case .slideLeft:   return "Slide ←"
        case .slideRight:  return "Slide →"
        case .slideTop:    return "Slide ↓ (from top)"
        case .slideBottom: return "Slide ↑ (from bottom)"
        case .scalePop:    return "Scale pop"
        case .spinIn:      return "Spin in"
        case .blurIn:      return "Blur in"
        }
    }
    var entrance: LogoEntrance {
        switch self {
        case .fade:        return .fade
        case .slideLeft:   return .slide(.left)
        case .slideRight:  return .slide(.right)
        case .slideTop:    return .slide(.top)
        case .slideBottom: return .slide(.bottom)
        case .scalePop:    return .scalePop
        case .spinIn:      return .spinIn
        case .blurIn:      return .blurIn
        }
    }
    static func from(_ e: LogoEntrance) -> LogoEntranceChoice {
        switch e {
        case .fade:        return .fade
        case .slide(.left):   return .slideLeft
        case .slide(.right):  return .slideRight
        case .slide(.top):    return .slideTop
        case .slide(.bottom): return .slideBottom
        case .scalePop:    return .scalePop
        case .spinIn:      return .spinIn
        case .blurIn:      return .blurIn
        }
    }
}

/// Live-editable config for an animated-logo overlay (`AnimatedLogoSource`). Its
/// style/timing are `let` on the source, so a live edit REBUILDS the source in
/// place (mirrors the montage rebuild). Value type so the inspector can mirror it.
struct LogoConfig: Equatable {
    var entrance: LogoEntranceChoice = .fade
    var idle: LogoIdle = .float
    var anchor: LogoAnchor = .topRight
    var sizeFraction: Double = 0.18
    var inSec: Double = 0.6
    var holdSec: Double = 4.0
    var outSec: Double = 0.6

    var style: LogoStyle {
        LogoStyle(anchor: anchor, sizeFraction: sizeFraction, entrance: entrance.entrance, idle: idle)
    }
    var timing: LogoTiming {
        LogoTiming(inSec: inSec, holdSec: holdSec, outSec: outSec)
    }
}

// MARK: - Ticker (DESIGN §2: TickerSource)

/// Live-editable config for a news-crawl ticker. `text` is live (`setText`);
/// `speed`/`position`/`accent` are `let` on the source, so a change REBUILDS it.
struct TickerConfig: Equatable {
    var text: String = "Breaking news"
    var speed: Double = 160
    var position: TickerPosition = .bottom
    var accentR: Double = 0.90
    var accentG: Double = 0.16
    var accentB: Double = 0.20

    var accent: RGBA { RGBA(r: accentR, g: accentG, b: accentB, a: 1) }
    var style: TickerStyle { TickerStyle(position: position, accentColor: accent) }
}

// MARK: - Credits (DESIGN §2: CreditsSource)

/// Live-editable config for a credits roll. `lines` are fixed at add-time; a
/// `speed`/`loop` change REBUILDS the source in place.
struct CreditsConfig: Equatable {
    var lines: [String] = []
    var speed: Double = 90
    var loop: Bool = false
}

// MARK: - Per-layer motion (DESIGN §4: LayerMotion)

/// The motion a layer follows. `.none` clears it. Maps to a `MotionPath`; the
/// looped paths (orbit/bounce/float) loop seamlessly, `glide` ping-pongs a
/// horizontal line so it never freezes.
enum LayerMotionKind: String, CaseIterable, Identifiable, Sendable {
    case none, glide, orbit, bounce, float
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none:   return "None"
        case .glide:  return "Glide"
        case .orbit:  return "Orbit"
        case .bounce: return "Bounce"
        case .float:  return "Float"
        }
    }
    /// The parametric path (normalized canvas-fraction offsets from rest). `.none`
    /// has no path.
    var path: MotionPath? {
        switch self {
        case .none:   return nil
        case .glide:  return .line(from: CGPoint(x: -0.25, y: 0), to: CGPoint(x: 0.25, y: 0))
        case .orbit:  return .orbit(center: CGPoint(x: 0, y: 0), radius: 0.12)
        case .bounce: return .bounce(height: 0.12)
        case .float:  return .float(amplitude: 0.06)
        }
    }
    /// Looped paths advance `u` freely; the one-shot `glide` ping-pongs.
    var isLooping: Bool { self == .orbit || self == .bounce || self == .float }
}

/// One layer's active motion: the evaluator plus the drive params. Value type,
/// Sendable, so the main actor can snapshot it into the render loop's
/// `sceneProvider` closure without a data race.
struct ActiveLayerMotion: Sendable {
    var kind: LayerMotionKind
    var motion: LayerMotion
    /// Cycles per second (loops/sec for looped paths; ping-pong rate for glide).
    var speed: Double
    /// House-time seconds the motion was (re)started, for the phase.
    var startHouse: Double

    /// The normalized parameter `u` for this motion at house time `now`.
    func parameter(atHouseSeconds now: Double) -> Double {
        let elapsed = max(0, now - startHouse) * max(speed, 0)
        if kind.isLooping { return elapsed }          // transform() wraps mod 1
        // One-shot line: ping-pong 0→1→0 so the glide never parks off-center.
        let phase = elapsed.truncatingRemainder(dividingBy: 2)
        return phase <= 1 ? phase : 2 - phase
    }
}
