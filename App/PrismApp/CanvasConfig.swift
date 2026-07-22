import Foundation

// MARK: - Canvas configuration (resolution + framerate)
//
// The program canvas was hard-locked to 1920×1080 @ 60 fps (a `static let
// canvasSize` + a hardcoded `RenderLoop(fps: 60)` + a hardcoded status string).
// `CanvasConfig` makes that a persisted project setting: one of five 16:9
// resolution presets × three framerate presets. The DEFAULT stays 1080p60 so
// out-of-the-box behavior is byte-for-byte unchanged.
//
// All presets are 16:9, which is why the aspect-only references that remain on
// `AppEngine.canvasSize` (the vertical-reframe math + the MemeDirector canvas
// aspect) stay correct regardless of the chosen preset — a resolution change
// never changes the program aspect.
//
// The live consumers (compositor render target, render-loop cadence, the
// record/stream encoders, and — transitively, via the composited program frame
// — the virtual camera) read the CURRENT value off the engine, so a non-default
// preset propagates everywhere the old constant reached.

struct CanvasConfig: Equatable, Codable {

    /// 16:9 resolution presets (weak-upload → 4K record).
    enum Resolution: String, CaseIterable, Codable, Identifiable {
        case r720  // 1280 × 720
        case r900  // 1600 × 900
        case r1080 // 1920 × 1080  (default)
        case r1440 // 2560 × 1440
        case r2160 // 3840 × 2160

        var id: String { rawValue }

        var width: Int {
            switch self {
            case .r720:  return 1280
            case .r900:  return 1600
            case .r1080: return 1920
            case .r1440: return 2560
            case .r2160: return 3840
            }
        }

        var height: Int {
            switch self {
            case .r720:  return 720
            case .r900:  return 900
            case .r1080: return 1080
            case .r1440: return 1440
            case .r2160: return 2160
            }
        }

        /// Menu label, e.g. "1920 × 1080 (1080p)".
        var label: String {
            let suffix: String
            switch self {
            case .r720:  suffix = "720p"
            case .r900:  suffix = "900p"
            case .r1080: suffix = "1080p"
            case .r1440: suffix = "1440p"
            case .r2160: suffix = "4K"
            }
            return "\(width) × \(height) (\(suffix))"
        }
    }

    /// Program output framerate presets.
    enum FrameRate: Int, CaseIterable, Codable, Identifiable {
        case fps24 = 24
        case fps30 = 30
        case fps60 = 60

        var id: Int { rawValue }
        var label: String { "\(rawValue) fps" }
    }

    var resolution: Resolution
    var frameRate: FrameRate

    var width: Int { resolution.width }
    var height: Int { resolution.height }
    /// Integer program output rate. `RenderLoop` takes a `Double`; use `Double(fps)`.
    var fps: Int { frameRate.rawValue }

    /// Status-line text — the single source of truth that replaces the old
    /// hardcoded `Text("Program 1920×1080 · 60 fps")`.
    var statusLine: String { "Program \(width)×\(height) · \(fps) fps" }

    /// The out-of-the-box canvas (unchanged behavior): 1080p60.
    static let `default` = CanvasConfig(resolution: .r1080, frameRate: .fps60)
}
