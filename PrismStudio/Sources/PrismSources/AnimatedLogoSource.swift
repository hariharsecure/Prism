import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import os
import PrismCompositor
import PrismCore

/// An **animated-logo** overlay source (DESIGN.md §1). Wraps the VisualFX
/// `AnimatedLogo` renderer as a live, addable `VideoSource`: a user-supplied PNG
/// (with its own transparency) is animated through an entrance → hold → exit
/// (`LogoTiming`) with a looping idle (float / pulse / shimmer / sway), all
/// driven off the house clock, and emitted as transparent premultiplied
/// IOSurface BGRA frames the compositor can layer over program.
///
/// Drive model: `start()` cues the entrance (unless `autoCue == false`, in which
/// case the logo stays off until `cue()`). `cue()` re-triggers the entrance from
/// now; `animateOut()` runs the exit (reverse) from the current position. After
/// the natural `LogoTiming` cycle (or an `animateOut`) completes, the logo rests
/// at `progress 0` — fully transparent — and the source keeps emitting (a live
/// overlay stays alive) until `stop()`; `cue()` restarts it. A `LogoStyle.bug`
/// watermark ignores entrance/exit (always at rest) per the renderer.
///
/// Thread model: create / `start()` / `stop()` / `cue()` / `animateOut()` from
/// any thread (drive state is lock-guarded); `onFrame` fires on the source
/// queue. No callback fires after `stop()` returns (see `AnimationSource`).
public final class AnimatedLogoSource: AnimationSource, @unchecked Sendable {

    private let logo: CGImage
    private let renderer: AnimatedLogo
    private let style: LogoStyle
    private let timing: LogoTiming
    private let autoCue: Bool

    /// Entrance/exit drive, in house time (`.invalid` = not (yet) triggered).
    private struct Drive { var cue: CMTime; var out: CMTime }
    private let drive = OSAllocatedUnfairLock<Drive>(initialState: Drive(cue: .invalid, out: .invalid))

    /// - Parameters:
    ///   - logoURL: the logo image file (PNG with alpha, upright).
    ///   - canvasSize: overlay output dimensions.
    ///   - style: anchor / size / entrance / idle (see `LogoStyle`).
    ///   - timing: entrance→hold→exit + idle-loop period (see `LogoTiming`).
    ///   - fps: emit rate (default 30 — overlays don't need 60).
    ///   - autoCue: cue the entrance automatically on `start()` (default true).
    /// - Throws: `SourceError.imageLoadFailed` (missing/unreadable),
    ///   `.imageDecodeFailed` (undecodable), `.canvasCreationFailed`.
    public init(id: SourceID = SourceID("logo.\(UUID().uuidString)"),
                logoURL: URL,
                canvasSize: CanvasSize = .hd,
                style: LogoStyle = LogoStyle(),
                timing: LogoTiming = LogoTiming(),
                fps: Double = 30,
                autoCue: Bool = true) throws {
        self.logo = try Self.loadUprightLogo(logoURL)
        do {
            self.renderer = try AnimatedLogo(width: canvasSize.width, height: canvasSize.height)
        } catch {
            throw SourceError.canvasCreationFailed(reason: "\(error)")
        }
        self.style = style
        self.timing = timing
        self.autoCue = autoCue
        super.init(id: id, fps: fps, label: "studio.prism.source.logo")
    }

    /// Convenience for a filesystem path.
    public convenience init(id: SourceID = SourceID("logo.\(UUID().uuidString)"),
                            path: String,
                            canvasSize: CanvasSize = .hd,
                            style: LogoStyle = LogoStyle(),
                            timing: LogoTiming = LogoTiming(),
                            fps: Double = 30,
                            autoCue: Bool = true) throws {
        try self.init(id: id, logoURL: URL(fileURLWithPath: path), canvasSize: canvasSize,
                      style: style, timing: timing, fps: fps, autoCue: autoCue)
    }

    // MARK: Drive control

    /// (Re)start the entrance from now.
    public func cue() { drive.withLock { $0.cue = HouseClock.now(); $0.out = .invalid } }

    /// Begin the exit (reverse of the entrance) from the current position.
    public func animateOut() {
        drive.withLock {
            guard $0.cue != .invalid, $0.out == .invalid else { return }
            $0.out = HouseClock.now()
        }
    }

    // MARK: AnimationSource

    override func prepare() throws {
        if autoCue { drive.withLock { $0.cue = HouseClock.now(); $0.out = .invalid } }
    }

    override func renderFrame(elapsed: Double) throws -> CVPixelBuffer? {
        let now = HouseClock.now()
        let p = resolvedProgress(now: now)
        // Idle loops continuously off the house clock (its amplitude follows the
        // entrance progress inside the renderer, so it eases in with the logo).
        let phase = timing.idlePhase(at: elapsed)
        return try render(progress: p, idlePhase: phase)
    }

    /// Entrance/exit progress ∈ 0…1 at house time `now` (0 = off, 1 = at rest).
    private func resolvedProgress(now: CMTime) -> Double {
        let d = drive.withLock { $0 }
        guard d.cue != .invalid else { return 0 }
        if d.out != .invalid {
            // Exit: ramp from whatever progress we had when animateOut() fired
            // down to 0 over `outSec` (the reverse of the entrance).
            let base = timing.progress(at: CMTimeSubtract(d.out, d.cue).seconds)
            let o = CMTimeSubtract(now, d.out).seconds
            let frac = o.isFinite ? max(0, 1 - o / timing.outSec) : 0
            return max(0, base * frac)
        }
        let e = CMTimeSubtract(now, d.cue).seconds
        return timing.progress(at: e.isFinite ? e : 0)
    }

    /// Render one frame from explicit drivers (shared by `tick` and the
    /// self-test's deterministic renders).
    func render(progress: Double, idlePhase: Double) throws -> CVPixelBuffer {
        do {
            return try renderer.render(logo: logo, progress: progress,
                                       idlePhase: idlePhase, style: style)
        } catch {
            throw SourceError.canvasCreationFailed(reason: "\(error)")
        }
    }

    // MARK: Load

    /// Load the first frame of the image file as an upright `CGImage`.
    static func loadUprightLogo(_ url: URL) throws -> CGImage {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SourceError.imageLoadFailed(path: url.path, underlying: nil)
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw SourceError.imageLoadFailed(path: url.path, underlying: nil)
        }
        guard CGImageSourceGetCount(src) > 0,
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw SourceError.imageDecodeFailed(path: url.path)
        }
        return image
    }
}
