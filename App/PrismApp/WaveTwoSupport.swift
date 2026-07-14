import AppKit
import PrismCore
import PrismScreen
import PrismSources
import SwiftUI
import simd

// MARK: - Selection (view-layer only)

/// Which source the Inspector (right rail) is editing. Lives entirely in the
/// view layer — AppEngine has no notion of a "selected" source, so selection
/// is app-UI state shared between the layer stack (sets it) and the Inspector
/// (reads it) via the environment.
@MainActor
final class SelectionModel: ObservableObject {
    @Published var selectedSourceID: SourceID?
}

// MARK: - Debouncer

/// Coalesces a burst of rapid calls (e.g. a slider dragged continuously) into a
/// single trailing call after `delay` seconds of quiet. Keeps effect setters
/// off the every-pixel path from turning into every-tick spam.
final class Debouncer {
    private var workItem: DispatchWorkItem?
    private let delay: TimeInterval

    init(delay: TimeInterval = 0.06) { self.delay = delay }

    func call(_ action: @escaping () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem(block: action)
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Cancel any pending trailing call. Used when a caller commits immediately
    /// and must ensure a stale debounced value can't land afterwards (W6).
    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}

// MARK: - Active source classification

extension ActiveSource {
    /// A source that feeds an audio mixer channel: a microphone, system audio,
    /// a screen/window/app source captured WITH its audio, or a video file whose
    /// soundtrack is routed into a mixer channel (its `onAudio` packets are
    /// ingested by a `MixerChannel` just like a mic — deliverable A). This is the
    /// predicate the Mixer tab filters on, so a movie with a soundtrack MUST
    /// return true here or its (already-wired) channel never surfaces.
    var isAudio: Bool {
        switch backing {
        case .microphone, .systemAudio: return true
        case .screen(let screen): return screen.configuration.capturesAudio
        case .movie(let movie): return movie.hasAudioTrack
        // A montage reel is a `.generated` backing; when any item carries a
        // decodable audio track it owns a mixer channel (per-item audio, Build B),
        // so it must surface in the Mixer tab just like a movie clip.
        case .generated(let video):
            if let montage = video as? MontageSource { return montage.hasAudioContent }
            return false
        default: return false
        }
    }
}

// MARK: - Color <-> SIMD bridge (for the background-replace color well)

extension Color {
    /// sRGB components as the linear-ish gamma-encoded triple `BackgroundMode`
    /// expects (same space as the frame — see BackgroundMode.replace docs).
    var backgroundReplaceRGB: SIMD3<Float> {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return SIMD3(Float(ns.redComponent), Float(ns.greenComponent), Float(ns.blueComponent))
    }

    init(backgroundReplaceRGB c: SIMD3<Float>) {
        self = Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }
}

// MARK: - Level meter

/// A vertical peak meter. `level` is linear amplitude (0…~1); displayed with a
/// mild perceptual curve and a green→amber→red gradient.
struct LevelMeter: View {
    /// Linear amplitude, 0…1+.
    var level: Float

    private var fraction: CGFloat {
        // sqrt gives a gentler, more readable low-end response than raw linear.
        CGFloat(min(1, max(0, sqrt(max(0, level)))))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(
                        colors: [.green, .green, .yellow, .red],
                        startPoint: .bottom, endPoint: .top))
                    .frame(height: max(2, geo.size.height * fraction))
                    .animation(.linear(duration: 0.08), value: fraction)
            }
        }
        .frame(width: 6)
    }
}

// MARK: - Vertical fader

/// A vertical gain fader built from a rotated `Slider` (SwiftUI has no native
/// vertical slider on macOS).
struct VerticalFader: View {
    @Binding var value: Double
    var range: ClosedRange<Double>

    var body: some View {
        Slider(value: $value, in: range)
            .rotationEffect(.degrees(-90))
            .frame(width: 110)
            .fixedSize()
            .frame(width: 24, height: 110)
    }
}
