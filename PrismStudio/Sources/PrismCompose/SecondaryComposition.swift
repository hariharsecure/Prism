import CoreMedia
import Foundation
import Metal
import PrismCompositor
import PrismCore

/// A second, independent program at a different aspect ratio, rendered from the
/// *same* source frames as the primary (DESIGN.md §2.5 — "simultaneous
/// horizontal + vertical programs, one show").
///
/// It wraps its own `MetalCompositor` sized to the vertical canvas (default
/// 1080×1920). Given the same `[SourceID: VideoFrame]` the primary composited
/// and the same `Scene`, it applies a `ReframeMap` (via `VerticalScene`) and
/// renders a vertical program frame.
///
/// ## Zero-copy preserved
/// The vertical render re-wraps the *same* IOSurface-backed source buffers in
/// its own `CVMetalTextureCache` — a pointer exchange, never a pixel copy
/// (DESIGN.md §3.5). Only the program output buffer is new (minted from this
/// compositor's pool).
///
/// ## Thread model
/// `MetalCompositor` is single-threaded, but this owns a **distinct**
/// compositor instance (separate command queue, caches, output pool) from the
/// primary's — so the secondary composite can run on its own thread
/// concurrently with the primary without contention. `DualProgram` uses that.
public final class SecondaryComposition {
    /// The vertical-canvas compositor (own instance, not shared with primary).
    public let compositor: MetalCompositor
    public var width: Int { compositor.width }
    public var height: Int { compositor.height }

    /// Build a secondary at `width`×`height` (default 1080×1920 vertical).
    ///
    /// This is the **public** path: it mints its *own* `MetalCompositor` so the
    /// secondary can never accidentally share single-threaded Metal state
    /// (command queue, texture caches, output pool) with the primary. Sharing a
    /// compositor across two programs is a data race (F7); the owning init makes
    /// that impossible by construction.
    public init(device: MTLDevice, width: Int = 1080, height: Int = 1920,
                colorMode: MetalCompositor.ColorMode = .sdr) throws {
        self.compositor = try MetalCompositor(device: device, width: width, height: height, colorMode: colorMode)
    }

    /// The dynamic range this secondary composites in (mirrors the primary's).
    public var colorMode: MetalCompositor.ColorMode { compositor.colorMode }

    /// Adopt a pre-built compositor.
    ///
    /// - Warning: The compositor MUST be a *distinct* instance from the primary's
    ///   (own command queue/caches/pool) and sized to the vertical canvas —
    ///   `MetalCompositor` is single-threaded, so a shared instance races the
    ///   primary's render. This footgun is why the init is not public; prefer
    ///   `init(device:width:height:)`, which owns its compositor and cannot
    ///   share state. Kept `internal` only for in-module construction/tests.
    init(compositor: MetalCompositor) {
        self.compositor = compositor
    }

    /// Render one vertical program frame from horizontal source frames + scene.
    ///
    /// - Parameters:
    ///   - frames: the same per-tick frames fed to the primary (missing sources
    ///     fall back to this compositor's own last-known set).
    ///   - scene: the horizontal `Scene`; reframed internally via `VerticalScene`.
    ///   - reframe: how the scene maps into the vertical canvas.
    ///   - pts: house-time PTS (pass the primary tick's PTS through — never
    ///     re-stamp with wall clock, per AGENTS.md §5).
    /// - Returns: the vertical program `VideoFrame` (BGRA8, IOSurface-backed).
    public func composite(frames: [SourceID: VideoFrame],
                          scene: Scene,
                          reframe: ReframeMap,
                          pts: CMTime,
                          duration: CMTime = .invalid) throws -> VideoFrame {
        let vertical = VerticalScene(from: scene, using: reframe)
        return try compositor.composite(frames: frames, scene: vertical, pts: pts, duration: duration)
    }

    /// Render from a pre-computed vertical scene (skip the reframe transform —
    /// e.g. when the caller already cached `VerticalScene(...)` for this tick).
    public func composite(frames: [SourceID: VideoFrame],
                          verticalScene: Scene,
                          pts: CMTime,
                          duration: CMTime = .invalid) throws -> VideoFrame {
        try compositor.composite(frames: frames, scene: verticalScene, pts: pts, duration: duration)
    }

    /// Drop a removed source's retained last-known frame from the secondary
    /// compositor and tombstone it, so a pending/draining tick snapshotted
    /// before removal cannot re-pin it (mirror the primary's
    /// `RenderLoop.removeMailbox`).
    public func forget(source: SourceID) { compositor.forget(source: source) }

    /// (Re)attach a source: clear its forget-tombstone so its frames fold again
    /// (mirror the primary's `RenderLoop.setMailbox`).
    public func attach(source: SourceID) { compositor.attach(source: source) }
}
