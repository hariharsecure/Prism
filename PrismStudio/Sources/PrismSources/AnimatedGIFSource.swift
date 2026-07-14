import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import os
import PrismCore

/// An **animated-GIF** source (DESIGN.md §2.1 — media sources): decodes an
/// animated GIF and re-emits its frames as a live, house-clock-paced video
/// source, so a motion meme / reaction loop / animated overlay can be used
/// exactly like a camera in the compositor / stream / record graph.
///
/// Guarantees (the pipeline contract):
///  - **IOSurface-backed BGRA at a capped decode resolution.** Every GIF frame
///    is decoded once and drawn into a `SourceRenderCanvas` (a `PixelBufferPool`
///    of IOSurface BGRA buffers), so every emitted `VideoFrame` satisfies
///    `VideoFrame`'s IOSurface assertion. All frames are **preloaded** into the
///    pool at `init`, so playback is disk- and decode-free. Frames are decoded
///    at `min(canvasSize, ≤720p, GIF-native)` — NOT full canvas size — because a
///    GIF is a low-res overlay the compositor scales to its on-screen rect;
///    decoding every frame at full canvas resolution costs 4–16× the RAM for no
///    visible gain (`frameWidth`×`frameHeight`×4×`frameCount` resident).
///  - **Per-frame timing.** Each GIF frame carries its own delay
///    (`kCGImagePropertyGIFDictionary` → unclamped delay preferred, clamped
///    fallback). Very small delays are floored to ~0.02 s the way browsers do,
///    and a zero/absent delay defaults to 0.1 s. Frames are presented at their
///    per-frame delay relative to `HouseClock` — not decode-as-fast.
///  - **Seamless loop** (default): at the end of the last frame the playhead
///    wraps to frame 0 and the house-time anchor advances by the GIF's total
///    duration, so the source is a continuous feed for streaming / recording.
///  - **Upright, correct fit.** Each frame's native size is fitted into the
///    canvas with the chosen `ContentMode` via the same bottom-left-origin
///    `ctx.draw` path as `ImageSource` (row 0 → visual top), so frames are
///    right-side up.
///  - **Still fallback.** A single-frame GIF or a static image (any type
///    `CGImageSource` can decode) is treated as a still: one cached frame
///    re-emitted at a low fps, keeping the feed alive without churn.
///
/// Thread model: `init(…)` (throws on a missing/undecodable file), `start()` and
/// `stop()` from any control thread (atomic — safe under concurrent/nested
/// calls, including `stop()` from inside `onFrame`); `onFrame` fires on the
/// source's own serial playback queue. After `stop()` returns, no further
/// `onFrame` callback is delivered (terminal-state discipline, mirrored from
/// `MovieSource`).
public final class AnimatedGIFSource: VideoSource, @unchecked Sendable {

    /// Reuse `ImageSource`'s fitting modes (fit / fill / stretch).
    public typealias ContentMode = ImageSource.ContentMode

    // MARK: Public surface

    public let id: SourceID
    /// Set before `start()`. Frames fire on the playback queue.
    public var onFrame: ((VideoFrame) -> Void)?
    public var state: SourceState { lifecycleState.withLock { $0.state } }

    /// Number of decoded frames (1 for a still / single-frame GIF).
    public let frameCount: Int
    /// Pixel dimensions of each decoded/emitted frame buffer. This is the
    /// **capped decode resolution** — `min(canvasSize, ≤720p, GIF-native)`,
    /// preserving the `canvasSize` aspect ratio — so it may be smaller than the
    /// requested `canvasSize`. Resident decode memory is
    /// `frameWidth·frameHeight·4·frameCount`; capping it here is the memory win
    /// (a GIF overlay is scaled to its on-screen rect by the compositor, so a
    /// smaller source frame simply scales up like any overlay — visually
    /// lossless while cutting RAM 4–16×).
    public let frameWidth: Int
    public let frameHeight: Int
    /// Sum of the per-frame delays — one loop's wall duration in seconds.
    public let nominalDurationSeconds: Double
    /// True when the GIF carries more than one frame (i.e. actually animates).
    public let isAnimated: Bool
    /// The error that moved the source to `.failed` (for callers / tests).
    public var lastError: SourceError? { lastErrorBox.withLock { $0 } }

    // MARK: Config / decoded frames

    private let log = EngineLog.logger("sources.gif")
    private let fileURL: URL
    private let loop: Bool

    /// A preloaded frame: its IOSurface-backed canvas buffer + its delay (s).
    private struct Frame { let box: PixelBox; let delay: Double }
    private let frames: [Frame]

    /// Per-frame delays (test/diagnostic accessor — same-module self-test).
    var perFrameDelays: [Double] { frames.map { $0.delay } }

    // Still cadence: a single-frame GIF / static image re-emits at 2 fps.
    private static let stillFrameDelay: Double = 0.5
    // Browsers floor tiny GIF delays to ~50 fps; a zero/absent delay → 0.1 s.
    private static let minAnimatedDelay: Double = 0.02
    private static let defaultDelay: Double = 0.1

    // MARK: Decode budget (bounds construction-time allocation)

    /// Hard cap on decoded frame count. A real reaction/meme GIF is ~10–200
    /// frames; thousands is pathological/hostile. Guards the pool sizing.
    static let defaultMaxFrameCount = 4096
    /// Hard cap on total decoded bytes preloaded into the pool. Every frame is a
    /// *decode-resolution* IOSurface BGRA buffer held simultaneously, so peak
    /// resident decode memory ≈ `frameCount · frameWidth · frameHeight · 4` —
    /// the CAPPED size (≤720p), not the full canvas. 512 MiB bounds a
    /// hostile/long GIF (e.g. > ~140 frames at the 720p ceiling) while
    /// comfortably fitting legitimate overlays.
    static let defaultMaxDecodedBytes = 512 * 1024 * 1024

    /// GIF-appropriate decode-resolution cap (a 1280×720 box). GIFs are low-res
    /// overlays shown small, so frames are decoded no larger than this box
    /// (aspect-preserving) — and never larger than the GIF's own native pixels.
    /// The compositor scales the layer to its on-screen rect regardless, so a
    /// smaller source frame is visually lossless while cutting RAM 4–16×.
    static let decodeCapLongSide = 1280
    static let decodeCapShortSide = 720

    /// The capped decode canvas: `canvasSize` scaled down (aspect-preserving) to
    /// fit the ≤720p cap box AND to not upscale a `gifW`×`gifH` GIF beyond its
    /// native pixels. Returns at least 1×1. When the native size is unknown
    /// (`gifW`/`gifH` ≤ 0) only the cap box applies.
    static func decodeCanvasSize(canvas: CanvasSize, gifW: Int, gifH: Int,
                                 mode: ContentMode) -> CanvasSize {
        let cw = Double(canvas.width), ch = Double(canvas.height)
        guard cw > 0, ch > 0 else { return CanvasSize(width: 1, height: 1) }
        // 1. Cap box (≤720p), oriented to the canvas, aspect-preserving.
        let capLong = Double(decodeCapLongSide), capShort = Double(decodeCapShortSide)
        let (capW, capH) = cw >= ch ? (capLong, capShort) : (capShort, capLong)
        var s = min(1.0, min(capW / cw, capH / ch))
        // 2. Never upscale the GIF past native: it is drawn into the canvas at
        //    `fitScale`; scaling the decode canvas below `1/fitScale` keeps the
        //    GIF's drawn region at ≤ native resolution (no upsampling of source
        //    detail). Uses the most-upscaled axis so neither axis is upsampled.
        if gifW > 0, gifH > 0 {
            let gw = Double(gifW), gh = Double(gifH)
            let fitScale: Double
            switch mode {
            case .aspectFit:  fitScale = min(cw / gw, ch / gh)
            case .aspectFill: fitScale = max(cw / gw, ch / gh)
            case .stretch:    fitScale = max(cw / gw, ch / gh)
            }
            if fitScale > 1 { s = min(s, 1.0 / fitScale) }
        }
        let dw = max(1, Int((cw * s).rounded()))
        let dh = max(1, Int((ch * s).rounded()))
        return CanvasSize(width: dw, height: dh)
    }

    // MARK: State

    /// Mutations are serialized by `lifecycleQueue`; the lock gives the
    /// playback queue and public `state` accessor cheap, atomic snapshots.
    /// `activeGeneration` is cleared before a stop drains the playback queue,
    /// so an old loop can never mistake a later run's `.running` state for its
    /// own. External drains keep the source in `.stopping`, preventing a new
    /// run from being queued ahead of a drain that must make `stop()` terminal.
    private struct LifecycleState {
        var state: SourceState = .idle
        var nextGeneration: UInt64 = 0
        var activeGeneration: UInt64?
        var externalDrains: Int = 0
    }
    private let lifecycleState = OSAllocatedUnfairLock<LifecycleState>(
        initialState: LifecycleState()
    )
    private let lastErrorBox = OSAllocatedUnfairLock<SourceError?>(initialState: nil)

    private let playbackQueue = DispatchQueue(label: "studio.prism.source.gif", qos: .userInitiated)
    /// Serializes `start()`/`stop()` so lifecycle transitions never interleave.
    private let lifecycleQueue = DispatchQueue(label: "studio.prism.source.gif.lifecycle")
    private let playbackQueueKey = DispatchSpecificKey<UInt8>()

    // MARK: Diagnostics / test injection

    /// Times the anchor was re-seated because playback fell catastrophically
    /// behind wall time (stay-live recovery — mirrors MovieSource M9).
    let anchorReseats = OSAllocatedUnfairLock<Int>(initialState: 0)

    // MARK: Init

    /// - Parameters:
    ///   - fileURL: the animated-GIF (or static image) file to play.
    ///   - canvasSize: output dimensions (frames are fitted into this).
    ///   - contentMode: how each frame's native size fits the canvas.
    ///   - background: fill behind a letterboxed / transparent frame. Default
    ///     `.clear` so a GIF overlay keeps its transparency and letterbox bars
    ///     show the layers beneath (a GIF is usually an OVERLAY).
    ///   - loop: restart at the last frame for a continuous feed (default true).
    /// - Throws: `SourceError.imageLoadFailed` (missing/unreadable),
    ///   `.imageDecodeFailed` (no decodable frame), `.invalidConfiguration`
    ///   (frame-count / decoded-byte budget exceeded), or `.canvasCreationFailed`.
    public convenience init(id: SourceID = SourceID("gif.\(UUID().uuidString)"),
                            fileURL: URL,
                            canvasSize: CanvasSize = .hd,
                            contentMode: ContentMode = .aspectFit,
                            background: RGBAColor = .clear,
                            loop: Bool = true) throws {
        try self.init(id: id, fileURL: fileURL, canvasSize: canvasSize,
                      contentMode: contentMode, background: background, loop: loop,
                      maxFrameCount: Self.defaultMaxFrameCount,
                      maxDecodedBytes: Self.defaultMaxDecodedBytes)
    }

    /// Designated init with an injectable decode budget. Internal so same-module
    /// tests can drive the over-budget path with a small budget without touching
    /// the public API surface.
    init(id: SourceID,
         fileURL: URL,
         canvasSize: CanvasSize,
         contentMode: ContentMode,
         background: RGBAColor,
         loop: Bool,
         maxFrameCount: Int,
         maxDecodedBytes: Int) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SourceError.imageLoadFailed(path: fileURL.path, underlying: nil)
        }
        self.id = id
        self.fileURL = fileURL
        self.loop = loop

        let decoded = try Self.decodeFrames(url: fileURL, canvasSize: canvasSize,
                                            mode: contentMode, background: background,
                                            maxFrameCount: maxFrameCount,
                                            maxDecodedBytes: maxDecodedBytes)
        self.frames = decoded
        self.frameCount = decoded.count
        // All frames share the pool's decode-canvas dimensions.
        self.frameWidth = CVPixelBufferGetWidth(decoded[0].box.buffer)
        self.frameHeight = CVPixelBufferGetHeight(decoded[0].box.buffer)
        self.isAnimated = decoded.count > 1
        self.nominalDurationSeconds = decoded.reduce(0) { $0 + $1.delay }

        playbackQueue.setSpecific(key: playbackQueueKey, value: 1)
    }

    /// Convenience for a filesystem path.
    public convenience init(id: SourceID = SourceID("gif.\(UUID().uuidString)"),
                            path: String,
                            canvasSize: CanvasSize = .hd,
                            contentMode: ContentMode = .aspectFit,
                            // F23: MATCH the `fileURL:` init default (`.clear`) so a
                            // transparent GIF stays an overlay whichever overload is
                            // chosen (was `.black` — a silent opaque black rectangle).
                            background: RGBAColor = .clear,
                            loop: Bool = true) throws {
        try self.init(id: id, fileURL: URL(fileURLWithPath: path),
                      canvasSize: canvasSize, contentMode: contentMode,
                      background: background, loop: loop)
    }

    /// Estimate the resident decoded-byte cost of this GIF WITHOUT decoding it —
    /// `frameCount · decodeW · decodeH · 4`, using the same capped decode size the
    /// real decode would pick. Reads only the container's frame count + first
    /// frame's native pixel size via ImageIO (no pixel decode), so the App can
    /// enforce its app-wide animated-media budget BEFORE paying the decode (F15 /
    /// Class F — reject an over-budget GIF without decoding it). Returns 0 for a
    /// still (single-frame) image or when the file can't be read.
    public static func estimatedResidentBytes(url: URL, canvasSize: CanvasSize = .hd,
                                              contentMode: ContentMode = .aspectFit) -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        let count = CGImageSourceGetCount(src)
        guard count > 1 else { return 0 }                        // still → untracked
        let (nativeW, nativeH) = gifPixelSize(src: src, index: 0) ?? (0, 0)
        let decode = decodeCanvasSize(canvas: canvasSize, gifW: nativeW, gifH: nativeH, mode: contentMode)
        return count * decode.width * decode.height * 4
    }

    // MARK: Decode (preload every frame into the pool once)

    private static func decodeFrames(url: URL, canvasSize: CanvasSize,
                                     mode: ContentMode, background: RGBAColor,
                                     maxFrameCount: Int, maxDecodedBytes: Int) throws -> [Frame] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw SourceError.imageLoadFailed(path: url.path, underlying: nil)
        }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { throw SourceError.imageDecodeFailed(path: url.path) }

        // Decode at a CAPPED resolution, not full canvas: a GIF is a low-res
        // overlay the compositor scales to its on-screen rect, so decoding every
        // frame at full canvas size wastes 4–16× the RAM. The decode canvas is
        // `canvasSize` scaled to fit ≤720p AND to not upscale the GIF past its
        // native pixels (read cheaply from the first frame's properties).
        let (nativeW, nativeH) = gifPixelSize(src: src, index: 0) ?? (0, 0)
        let decodeSize = decodeCanvasSize(canvas: canvasSize, gifW: nativeW,
                                          gifH: nativeH, mode: mode)

        // Enforce the decode budget BEFORE allocating the pool: a large/hostile
        // GIF (thousands of frames, or a very long clip) must not preload
        // unboundedly at construction. Cap both frame count AND total decoded
        // bytes (every frame is a decode-resolution IOSurface BGRA buffer held
        // at once). Int64 math avoids overflow on hostile dimensions.
        guard count <= maxFrameCount else {
            throw SourceError.invalidConfiguration(
                reason: "animated GIF frame count \(count) exceeds limit \(maxFrameCount)")
        }
        let perFrameBytes = Int64(decodeSize.width) * Int64(decodeSize.height) * 4
        let projectedBytes = Int64(count) * perFrameBytes
        guard projectedBytes <= Int64(maxDecodedBytes) else {
            throw SourceError.invalidConfiguration(
                reason: "animated GIF decode budget exceeded: \(count) frames × "
                    + "\(decodeSize.width)×\(decodeSize.height)×4 = \(projectedBytes) bytes "
                    + "> \(maxDecodedBytes) byte limit")
        }
        let multi = count > 1

        // Size the pool to hold every preloaded frame simultaneously.
        let canvas = try SourceRenderCanvas(size: decodeSize, minimumBufferCount: max(4, count + 2))

        var result: [Frame] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else {
                // Partial/corrupt decode: keep whatever prefix decoded, else fail.
                if result.isEmpty { throw SourceError.imageDecodeFailed(path: url.path) }
                break
            }
            let delay = multi ? frameDelay(src: src, index: i) : stillFrameDelay
            let dest = ImageSource.fittedRect(imageW: cg.width, imageH: cg.height,
                                              canvasW: canvas.width, canvasH: canvas.height, mode: mode)
            let buffer = try canvas.render { ctx in
                ctx.setFillColor(background.cgColor)
                ctx.fill(canvas.canvasRect)
                ctx.interpolationQuality = .high
                // Upright: CGImage row 0 (top) → high y → memory row 0 (visual top).
                ctx.draw(cg, in: dest)
            }
            result.append(Frame(box: PixelBox(buffer: buffer), delay: delay))
        }
        guard !result.isEmpty else { throw SourceError.imageDecodeFailed(path: url.path) }
        return result
    }

    /// The GIF frame's native pixel size, read from its properties (no full
    /// decode). `nil` if unavailable — the decode-canvas sizing then falls back
    /// to the cap box alone.
    private static func gifPixelSize(src: CGImageSource, index: Int) -> (Int, Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// One frame's delay (seconds), honoring the UNCLAMPED delay first, then the
    /// clamped delay; a zero/absent delay defaults to 0.1 s and any positive
    /// delay below ~0.02 s is floored the way browsers cap GIF playback.
    private static func frameDelay(src: CGImageSource, index: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let unclamped = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif?[kCGImagePropertyGIFDelayTime] as? Double
        var delay = unclamped ?? clamped ?? defaultDelay
        if !delay.isFinite || delay <= 0 { return defaultDelay }
        if delay < minAnimatedDelay { delay = minAnimatedDelay }
        return delay
    }

    // MARK: Lifecycle (atomic — nested-stop safe, concurrent-safe)

    /// Launches the paced playback loop. Frames are already decoded in `init`,
    /// so this does not throw in practice; the signature satisfies `VideoSource`.
    public func start() throws {
        let run: (generation: UInt64, anchor: CMTime)? = lifecycleQueue.sync {
            lifecycleState.withLock { lifecycle in
                guard lifecycle.state == .idle || lifecycle.state == .failed else {
                    return nil
                }
                lifecycle.state = .starting
                lifecycle.nextGeneration &+= 1
                let generation = lifecycle.nextGeneration
                lifecycle.activeGeneration = generation
                lastErrorBox.withLock { $0 = nil }
                let anchor = HouseClock.now()
                lifecycle.state = .running
                return (generation, anchor)
            }
        }
        guard let run else { return }
        playbackQueue.async { [self] in
            runPlaybackLoop(generation: run.generation, startAnchor: run.anchor)
        }
    }

    public func stop() {
        if DispatchQueue.getSpecific(key: playbackQueueKey) != nil {
            stopFromPlaybackQueue()
            return
        }

        // Phase 1 only invalidates the run. Crucially, lifecycleQueue is
        // released before the synchronous playback drain: a callback that also
        // calls stop() can therefore perform its repeat transition and return.
        lifecycleQueue.sync {
            lifecycleState.withLock { lifecycle in
                lifecycle.externalDrains += 1
                lifecycle.activeGeneration = nil
                lifecycle.state = .stopping
            }
        }

        // Every external caller drains, including repeated concurrent stops.
        // This is what makes each external return a terminal callback boundary.
        playbackQueue.sync {}

        lifecycleQueue.sync {
            lifecycleState.withLock { lifecycle in
                lifecycle.externalDrains -= 1
                if lifecycle.externalDrains == 0, lifecycle.state == .stopping {
                    lifecycle.state = .idle
                }
            }
        }
    }

    /// A callback-originated stop cannot drain its own serial queue. It
    /// invalidates the current generation and completes immediately when no
    /// external drain owns the terminal boundary. If an external stop is
    /// already draining, this is deliberately a nonblocking repeat stop; that
    /// external caller performs the eventual `.idle` transition.
    private func stopFromPlaybackQueue() {
        let isRepeatStop = lifecycleState.withLock {
            $0.activeGeneration == nil &&
                ($0.state == .stopping || $0.externalDrains > 0)
        }
        if isRepeatStop { return }

        lifecycleQueue.sync {
            lifecycleState.withLock { lifecycle in
                lifecycle.activeGeneration = nil
                if lifecycle.externalDrains > 0 || lifecycle.state == .stopping {
                    lifecycle.state = .stopping
                } else if lifecycle.state != .idle {
                    lifecycle.state = .idle
                }
            }
        }
    }

    /// A global running bit is insufficient: an old loop can observe a later
    /// start's `.running` state. Both state and per-run generation must match.
    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        lifecycleState.withLock {
            $0.state == .running && $0.activeGeneration == generation
        }
    }

    // MARK: Playback loop

    private enum LoopExit { case stopped, eof }

    private func runPlaybackLoop(generation: UInt64, startAnchor: CMTime) {
        guard isCurrentGeneration(generation) else { return }
        var loopBase = startAnchor
        let exit = playthroughs(loopBase: &loopBase, generation: generation)
        switch exit {
        case .stopped:
            break                                     // stop() owns the transition
        case .eof:
            lifecycleQueue.sync {
                lifecycleState.withLock { lifecycle in
                    guard lifecycle.state == .running,
                          lifecycle.activeGeneration == generation else { return }
                    lifecycle.activeGeneration = nil
                    lifecycle.state = .idle
                }
            }
        }
    }

    private func playthroughs(loopBase: inout CMTime, generation: UInt64) -> LoopExit {
        let severeLate = 1.0                          // re-anchor if this far behind
        while isCurrentGeneration(generation) {
            var offset = CMTime.zero
            for f in frames {
                if !isCurrentGeneration(generation) { return .stopped }
                var target = CMTimeAdd(loopBase, offset)

                // Stay live: if playback fell catastrophically behind wall time
                // (a stalled consumer), re-seat the anchor to now so we don't
                // replay a huge backlog as a catch-up burst.
                let late = CMTimeSubtract(HouseClock.now(), target).seconds
                if late.isFinite && late > severeLate {
                    let jump = CMTime(seconds: late, preferredTimescale: 600)
                    loopBase = CMTimeAdd(loopBase, jump)
                    target = CMTimeAdd(target, jump)
                    anchorReseats.withLock { $0 += 1 }
                }

                paceUntil(target, generation: generation)
                if !isCurrentGeneration(generation) { return .stopped }
                emit(f.box.buffer, houseTime: target, delaySeconds: f.delay,
                     generation: generation)
                offset = CMTimeAdd(offset, CMTime(seconds: f.delay, preferredTimescale: 600))
            }
            guard loop else { return .eof }
            // Advance the anchor by exactly one loop's duration; never let it fall
            // behind wall time (avoids a catch-up burst after a long GIF).
            loopBase = CMTimeAdd(loopBase, offset)
            let now = HouseClock.now()
            if CMTimeCompare(loopBase, now) < 0 { loopBase = now }
        }
        return .stopped
    }

    /// Emit one preloaded frame. Re-checks the run generation so a retired loop
    /// cannot deliver into a later run.
    private func emit(_ buffer: CVPixelBuffer, houseTime: CMTime, delaySeconds: Double,
                      generation: UInt64) {
        guard isCurrentGeneration(generation) else { return }
        let duration = CMTime(seconds: delaySeconds, preferredTimescale: 600)
        onFrame?(VideoFrame(pixelBuffer: buffer, pts: houseTime, duration: duration, source: id))
    }

    /// Block the playback queue until house time reaches `target` (in small
    /// steps so `stop()` is observed promptly). Returns immediately if due.
    private func paceUntil(_ target: CMTime, generation: UInt64) {
        while isCurrentGeneration(generation) {
            let delta = CMTimeSubtract(target, HouseClock.now()).seconds
            if !delta.isFinite || delta <= 0.0005 { return }
            Thread.sleep(forTimeInterval: min(delta, 0.05))
        }
    }
}
