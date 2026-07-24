import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import os
import PrismCore
import UniformTypeIdentifiers

/// A **montage** source (design MONTAGE_TILE_EFFECTS_DESIGN.md, Build B):
/// auto-cycles a LIST of media (images and/or video clips) as ONE live source,
/// so a fast image/video montage — a hype reel — is a single toggle instead of
/// hours of manual editing.
///
/// What it does:
///  - **Auto-advance.** Each item gets a `interval`-second dwell, paced against
///    `HouseClock` (the house clock, not wall time). At the end of the dwell it
///    cuts / crossfades to the next item, looping the list. An external driver
///    can instead call `advance()` to force the next cut on demand (the future
///    beat-sync hook — cut on the beat).
///  - **Deterministic shuffle.** `shuffle` uses a SEEDED Fisher–Yates order
///    (SplitMix64 from `seed`) — no `Date`/`Math.random`, so a given seed always
///    produces the same order (reproducible montage; the design's "deterministic
///    seeds" invariant).
///  - **Image items** load once (like `ImageSource`) and, with `kenBurns`, get a
///    slow deterministic pan/zoom over the dwell so a still montage is not static
///    (the Ken Burns staple). The pan/zoom vector is derived deterministically
///    from the item's ordinal, so it too is reproducible.
///  - **Video items** embed a `MovieSource` — the proven video-file decode /
///    real-time pacing / seamless-loop / house-time path is REUSED, not
///    reimplemented. The clip's `MovieSource` is started when the item enters and
///    stopped when it leaves (no leaks; `movieStartCount == movieStopCount` after
///    a full cycle, exercised by the self-test).
///  - **Transitions between items** are done INTERNALLY in this source's own
///    canvas (this module cannot see `PrismCompositor`'s transition library):
///    `.cut` is a hard swap; `.crossfade(dur)` alpha-blends the outgoing and
///    incoming frames over the last `dur` seconds of the dwell (CoreGraphics
///    `setAlpha` source-over — premultipliedAlpha correct). Fancy per-tile
///    transitions between items are a FUTURE bridge (they need a module link to
///    `PrismCompositor`'s `VisualFX`); noted, not blocked.
///
/// Every emitted `VideoFrame` is an IOSurface-backed BGRA buffer at canvas size
/// (the pipeline's zero-copy invariant), stamped in house time.
///
/// Thread model: `init(…)` validates the item list (throws on empty / a missing
/// file). `start()` eagerly loads the first item (throwing a typed `SourceError`
/// on an undecodable first item), then a serial "director" queue drives the
/// timeline. `stop()` is safe from any thread, including from inside `onFrame`
/// (nested-stop guard, mirroring `MovieSource`). `onFrame` fires on the director
/// queue. Runtime decode failures on LATER items are logged and drawn as the
/// background (the montage keeps running) rather than crashing.
public final class MontageSource: VideoSource, @unchecked Sendable {

    /// Reuse the shared fit modes (fit / fill / stretch).
    public typealias ContentMode = ImageSource.ContentMode

    // MARK: One montage item

    /// One media item in the montage — an image OR a video file.
    public struct MontageItem: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case image, video }
        public let url: URL
        public let kind: Kind
        public init(url: URL, kind: Kind) { self.url = url; self.kind = kind }

        /// Build an item, detecting image vs video from the file's UTType (falling
        /// back to a small extension allow-list for video).
        public static func detect(url: URL) -> MontageItem {
            MontageItem(url: url, kind: detectKind(url: url))
        }

        static func detectKind(url: URL) -> Kind {
            if let type = UTType(filenameExtension: url.pathExtension) {
                if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
                if type.conforms(to: .image) { return .image }
            }
            let videoExts: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg"]
            return videoExts.contains(url.pathExtension.lowercased()) ? .video : .image
        }
    }

    /// Item-to-item transition performed internally in this source's canvas.
    public enum Transition: Sendable, Equatable {
        /// Hard swap at the dwell boundary.
        case cut
        /// Alpha-blend outgoing→incoming over the last `duration` seconds of the
        /// dwell. Clamped to the dwell length at use.
        case crossfade(duration: Double)
    }

    // MARK: Public surface

    public let id: SourceID
    /// Set before `start()`. Fires on the director queue.
    public var onFrame: ((VideoFrame) -> Void)?
    /// Set before `start()`. When the CURRENT item is a video with an audio track,
    /// that clip's embedded `MovieSource` audio packets are forwarded here
    /// (already re-stamped to house time by `MovieSource`). Image items emit
    /// nothing (silence). Exactly ONE item's audio is emitted at a time — the
    /// committed/current item — so soundtracks never overlap across a transition
    /// (the incoming clip's audio is gated OFF until it becomes current; the
    /// outgoing clip's audio is stopped when it leaves). No packets fire after
    /// `stop()`. Fires on the embedded `MovieSource`'s audio decode queue.
    public var onAudio: (@Sendable (AudioPacket) -> Void)?

    public var state: SourceState { stateLock.withLock { $0 } }
    /// Number of items in the montage.
    public var itemCount: Int { items.count }
    /// Whether ANY item is a video carrying a decodable audio track — i.e. whether
    /// this montage can ever emit audio through `onAudio`. Lets the app decide up
    /// front whether to create a mixer channel for the montage. Probed lazily on
    /// first access (per unique video file) and cached.
    public var hasAudioContent: Bool {
        if let cached = audioContentCache.withLock({ $0 }) { return cached }
        var seen = Set<String>()
        var result = false
        for item in items where item.kind == .video {
            let key = item.url.path
            if seen.contains(key) { continue }
            seen.insert(key)
            if Self.fileHasAudioTrack(url: item.url) { result = true; break }
        }
        let found = result
        audioContentCache.withLock { $0 = found }
        return found
    }
    /// The deterministic play order (indices into `items`). Same `seed` ⇒ same order.
    public let order: [Int]
    /// 0-based count of item-dwells begun so far (monotonic; wraps the list when
    /// `loop`). Readable for a driver / test to see the montage advanced.
    public var currentOrdinal: Int { directorLock.withLock { $0.ordinal } }

    // MARK: Config

    private let log = EngineLog.logger("sources.montage")
    private let items: [MontageItem]
    private let canvasSize: CanvasSize
    private let canvas: SourceRenderCanvas
    private let interval: Double
    private let transition: Transition
    private let kenBurns: Bool
    private let loop: Bool
    private let seed: UInt64
    private let contentMode: ContentMode
    private let background: RGBAColor
    private let fps: Double
    private let frameDuration: CMTime
    private let ciContext: CIContext

    // MARK: Readiness (T3 — never commit to a not-yet-decoded video)

    /// Lead time BEFORE a dwell boundary at which the incoming item is pre-rolled
    /// so a video's async first frame is ready before we cut to it (a crossfade
    /// window, if longer, wins). Prevents the "background flashes before the video
    /// paints" bug at the transition INTO a video.
    private let videoPrerollLead: Double = 0.30
    /// Max time to HOLD the outgoing item at a boundary waiting for the incoming
    /// item to become ready before giving up and committing anyway. Bounds the
    /// hold so a permanently-failing later item can't wedge the montage (it then
    /// draws as background and the montage keeps running — T6).
    private let readinessHoldCap: Double

    // MARK: Diagnostics / test hooks (internal — exercised by the self-test)

    /// Total embedded `MovieSource`s started / stopped. Equal after a clean cycle
    /// ⇒ no video-item leaks (start-on-enter / stop-on-leave lifecycle proof).
    let movieStartCount = OSAllocatedUnfairLock(initialState: 0)
    let movieStopCount = OSAllocatedUnfairLock(initialState: 0)

    /// Cached result of the `hasAudioContent` probe (nil until first evaluated).
    private let audioContentCache = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    // MARK: Timer + lifecycle

    private let directorQueue = DispatchQueue(label: "studio.prism.source.montage.director", qos: .userInitiated)
    private let directorQueueKey = DispatchSpecificKey<UInt8>()
    private let lifecycleQueue = DispatchQueue(label: "studio.prism.source.montage.lifecycle")
    private let stateLock = OSAllocatedUnfairLock<SourceState>(initialState: .idle)
    private var timer: DispatchSourceTimer?

    // MARK: Director state (mutated ONLY on directorQueue; the lock exists so
    // `advance()` / `currentOrdinal` can poke it from a control thread safely).

    private struct DirectorState {
        var anchor: CMTime = .invalid      // house time the current item's dwell began
        var ordinal: Int = 0               // which dwell we are in (0-based)
        var forceAdvance: Bool = false     // advance() requested an early cut
        var finished: Bool = false         // non-loop montage ran past the last item
        var holdingSince: CMTime = .invalid // house time we began HOLDING at a boundary
    }
    private let directorLock = OSAllocatedUnfairLock(initialState: DirectorState())

    /// The active display slots. `current` always exists while running; `incoming`
    /// exists only during a crossfade window (prepared ahead of the boundary).
    private var current: Slot?
    private var incoming: Slot?

    // MARK: Init

    /// - Parameters:
    ///   - items: the montage list (images and/or video files). Must be non-empty.
    ///   - canvasSize: output dimensions (every emitted frame is this size).
    ///   - interval: per-item dwell in seconds (clamped to ≥ 0.05).
    ///   - transition: `.cut` or `.crossfade(duration:)` between items.
    ///   - kenBurns: slow deterministic pan/zoom on image items.
    ///   - shuffle: play in a seeded deterministic shuffled order.
    ///   - loop: cycle forever (else stop after the last item).
    ///   - seed: shuffle / Ken-Burns seed (deterministic).
    ///   - contentMode: how a non-Ken-Burns item fits the canvas.
    ///   - background: fill behind a letterboxed item.
    ///   - fps: montage output frame rate.
    /// - Throws: `SourceError.invalidConfiguration` (empty list),
    ///   `.mediaLoadFailed` / `.imageLoadFailed` (a listed file is missing),
    ///   `.canvasCreationFailed`.
    public init(id: SourceID = SourceID("montage.\(UUID().uuidString)"),
                items: [MontageItem],
                canvasSize: CanvasSize = .hd,
                interval: Double,
                transition: Transition = .cut,
                kenBurns: Bool = false,
                shuffle: Bool = false,
                loop: Bool = true,
                seed: UInt64 = 0x5052_49534D_0001,
                contentMode: ContentMode = .aspectFill,
                background: RGBAColor = .black,
                fps: Double = 30) throws {
        guard !items.isEmpty else {
            throw SourceError.invalidConfiguration(reason: "montage item list is empty")
        }
        // Fail fast on a missing file — a typed error at construction, per item kind.
        for item in items where !FileManager.default.fileExists(atPath: item.url.path) {
            switch item.kind {
            case .video: throw SourceError.mediaLoadFailed(path: item.url.path, underlying: nil)
            case .image: throw SourceError.imageLoadFailed(path: item.url.path, underlying: nil)
            }
        }
        self.id = id
        self.items = items
        self.canvasSize = canvasSize
        self.interval = max(interval, 0.05)
        self.readinessHoldCap = max(0.5, max(interval, 0.05))
        self.transition = transition
        self.kenBurns = kenBurns
        self.loop = loop
        self.seed = seed
        self.contentMode = contentMode
        self.background = background
        self.fps = max(fps, 1)
        self.frameDuration = CMTime(seconds: 1.0 / max(fps, 1), preferredTimescale: 600)
        self.order = Self.makeOrder(count: items.count, shuffle: shuffle, seed: seed)
        self.canvas = try SourceRenderCanvas(size: canvasSize)
        self.ciContext = CIContext(options: [.cacheIntermediates: false])
        directorQueue.setSpecific(key: directorQueueKey, value: 1)
    }

    /// Convenience: build from a list of file URLs, auto-detecting each item kind.
    public convenience init(id: SourceID = SourceID("montage.\(UUID().uuidString)"),
                            urls: [URL],
                            canvasSize: CanvasSize = .hd,
                            interval: Double,
                            transition: Transition = .cut,
                            kenBurns: Bool = false,
                            shuffle: Bool = false,
                            loop: Bool = true,
                            seed: UInt64 = 0x5052_49534D_0001,
                            contentMode: ContentMode = .aspectFill,
                            background: RGBAColor = .black,
                            fps: Double = 30) throws {
        try self.init(id: id, items: urls.map { MontageItem.detect(url: $0) },
                      canvasSize: canvasSize, interval: interval, transition: transition,
                      kenBurns: kenBurns, shuffle: shuffle, loop: loop, seed: seed,
                      contentMode: contentMode, background: background, fps: fps)
    }

    // MARK: Lifecycle

    /// sol #8: validate that the reel can BEGIN (its first item loads) WITHOUT
    /// launching the director timer or wiring callbacks — so a transactional
    /// reconfigure can confirm the replacement is good BEFORE retiring the
    /// predecessor, yet not feed the shared effect pipeline / mixer channel until the
    /// predecessor has drained. Mirrors the fail-fast `startLocked()` performs on the
    /// FIRST slot; the probe slot is torn down immediately (nothing keeps running).
    public func validateStartable() throws {
        let firstSlot = makeSlot(ordinal: 0)
        do { try firstSlot.load() }
        catch { firstSlot.stop(); throw error }
        firstSlot.stop()
    }

    public func start() throws {
        try lifecycleQueue.sync { try startLocked() }
    }

    private func startLocked() throws {
        let proceed: Bool = stateLock.withLock { s in
            guard s == .idle || s == .failed else { return false }
            s = .starting
            return true
        }
        guard proceed else { return }

        // Eagerly build + load the first slot so start() surfaces a bad FIRST item
        // as a thrown typed error (later items degrade gracefully at runtime).
        let firstSlot = makeSlot(ordinal: 0)
        do {
            try firstSlot.load()
        } catch {
            firstSlot.stop()
            stateLock.withLock { if $0 == .starting { $0 = .failed } }
            throw error
        }
        firstSlot.startVideoIfNeeded()
        // T3: for a video FIRST item, briefly wait (bounded) for its first frame
        // so the montage's opening frame isn't the background before the decode
        // lands. Bounded by `readinessHoldCap` so a bad clip can't block start().
        if firstSlot.item.kind == .video {
            let deadline = Date().addingTimeInterval(readinessHoldCap)
            while !firstSlot.isReady(), Date() < deadline { usleep(3_000) }
        }

        directorLock.withLock {
            $0 = DirectorState(anchor: HouseClock.now(), ordinal: 0, forceAdvance: false, finished: false)
        }
        current = firstSlot
        incoming = nil
        // The opening item is current from frame zero — let its audio (if any) flow.
        firstSlot.setAudioActive(true)

        stateLock.withLock { if $0 == .starting { $0 = .running } }

        let t = DispatchSource.makeTimerSource(queue: directorQueue)
        let step = 1.0 / fps
        t.schedule(deadline: .now(), repeating: step, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    public func stop() {
        // If called from inside `onFrame` we are ON the director queue; capture that
        // BEFORE hopping to the lifecycle queue so the drain skips it (no deadlock).
        let onDirector = DispatchQueue.getSpecific(key: directorQueueKey) != nil
        lifecycleQueue.sync { stopLocked(skipDirectorDrain: onDirector) }
    }

    private func stopLocked(skipDirectorDrain: Bool) {
        let proceed: Bool = stateLock.withLock { s in
            guard s == .running || s == .starting || s == .failed else { return false }
            s = .stopping
            return true
        }
        guard proceed else { return }
        timer?.cancel()
        timer = nil
        // Let the in-flight tick finish (unless we ARE that tick).
        if !skipDirectorDrain { directorQueue.sync {} }
        teardownSlots()
        stateLock.withLock { if $0 == .stopping { $0 = .idle } }
    }

    private func teardownSlots() {
        current?.stop(); current = nil
        incoming?.stop(); incoming = nil
    }

    private func isRunning() -> Bool { stateLock.withLock { $0 == .running } }

    /// Force an immediate cut to the next item on the next tick (the beat-sync
    /// hook — a driver calls this on the beat instead of waiting out the dwell).
    public func advance() {
        directorLock.withLock { $0.forceAdvance = true }
    }

    // MARK: Director tick (runs on directorQueue)

    private enum TickAction { case none, finish, commit, hold }

    private func tick() {
        guard isRunning() else { return }
        let now = HouseClock.now()

        // Decide (advance? finish? hold?) under the lock. A boundary only COMMITS
        // when the incoming slot is READY (T3): committing to a not-yet-decoded
        // video would draw the background for a frame (the flash). If it isn't
        // ready we HOLD on the outgoing item — capped by `readinessHoldCap` so a
        // permanently-failing item can't wedge the montage (T6).
        let (timeInItem, action): (Double, TickAction) = directorLock.withLock { st in
            if st.anchor == .invalid { st.anchor = now }
            var t = CMTimeSubtract(now, st.anchor).seconds
            if !t.isFinite || t < 0 { t = 0 }
            let due = st.forceAdvance || t >= interval
            guard due else { return (t, .none) }

            let nextOrd = st.ordinal + 1
            guard itemIndex(forOrdinal: nextOrd) != nil else {
                st.finished = true
                return (t, .finish)
            }
            let ready = (incoming?.ordinal == nextOrd) && (incoming?.isReady() ?? false)
            let held = st.holdingSince == .invalid ? 0 : CMTimeSubtract(now, st.holdingSince).seconds
            let gaveUp = held.isFinite && held >= readinessHoldCap
            if ready || gaveUp {
                st.forceAdvance = false
                st.ordinal = nextOrd
                st.anchor = now
                st.holdingSince = .invalid
                return (0, .commit)
            }
            if st.holdingSince == .invalid { st.holdingSince = now }
            return (t, .hold)
        }

        switch action {
        case .finish:
            // Non-loop montage: render the last frame once and move to a
            // restartable terminal state.
            renderAndEmit(timeInItem: interval, alphaIn: 0, houseTime: now)
            timer?.cancel(); timer = nil
            teardownSlots()
            stateLock.withLock { if $0 == .running { $0 = .idle } }
            return
        case .commit:
            commitAdvance(now: now)
        case .hold:
            // HOLD: keep pre-rolling the incoming item and keep showing the
            // outgoing one at end-of-dwell (never the background) until ready.
            let nextOrd = directorLock.withLock { $0.ordinal } + 1
            ensureIncoming(nextOrdinal: nextOrd)
            renderAndEmit(timeInItem: interval, alphaIn: 0, houseTime: now)
            return
        case .none:
            break
        }

        let t = action == .commit ? 0.0 : timeInItem
        let ord = directorLock.withLock { $0.ordinal }
        let nextOrd = ord + 1
        var alphaIn = 0.0
        if itemIndex(forOrdinal: nextOrd) != nil {
            // Pre-roll the incoming item ahead of the boundary so a video's async
            // first frame is ready before we cut (T3). Lead ≥ the crossfade
            // window so the incoming frame exists when the blend begins.
            var cfDur = 0.0
            if case .crossfade(let dur) = transition { cfDur = min(max(dur, 0), interval) }
            let lead = max(cfDur, videoPrerollLead)
            if t >= interval - lead { ensureIncoming(nextOrdinal: nextOrd) }
            // Crossfade alpha only inside the window AND once the incoming is
            // ready — never fade toward an empty (background) slot.
            if cfDur > 0 {
                let cfStart = interval - cfDur
                if t >= cfStart, incoming?.isReady() == true {
                    alphaIn = min(1.0, max(0.0, (t - cfStart) / cfDur))
                }
            }
        }

        renderAndEmit(timeInItem: t, alphaIn: alphaIn, houseTime: now)
    }

    private func commitAdvance(now: CMTime) {
        let ord = directorLock.withLock { $0.ordinal }
        if let inc = incoming, inc.ordinal == ord {
            current?.stop()           // silences + tears down the outgoing clip's audio
            current = inc
            incoming = nil
        } else {
            current?.stop()
            incoming?.stop()          // T6: drop any stale (wrong-ordinal) incoming
            let slot = makeSlot(ordinal: ord)
            try? slot.load()          // best-effort; a bad later item draws as background
            slot.startVideoIfNeeded()
            current = slot
            incoming = nil
        }
        // Exactly one emitter: the freshly-committed item is now the sole slot
        // allowed to forward audio (the outgoing one was silenced by stop() above,
        // and the incoming's audio was gated OFF during preroll until this point).
        current?.setAudioActive(true)
    }

    private func ensureIncoming(nextOrdinal: Int) {
        if incoming?.ordinal == nextOrdinal { return }
        incoming?.stop()
        let slot = makeSlot(ordinal: nextOrdinal)
        try? slot.load()
        slot.startVideoIfNeeded()
        incoming = slot
    }

    // MARK: Rendering

    private func renderAndEmit(timeInItem: Double, alphaIn: Double, houseTime: CMTime) {
        let frac = max(0.0, min(1.0, timeInItem / interval))
        let out: CVPixelBuffer
        do {
            out = try canvas.render { [self] ctx in
                ctx.setFillColor(background.cgColor)
                ctx.fill(canvas.canvasRect)
                if let current { drawSlot(current, into: ctx, frac: frac, alpha: 1.0) }
                if alphaIn > 0, let incoming {
                    // Incoming just entered; start its own Ken-Burns from the top.
                    drawSlot(incoming, into: ctx, frac: 0.0, alpha: alphaIn)
                }
            }
        } catch {
            log.error("montage render failed: \(String(describing: error), privacy: .public)")
            return
        }
        let frame = VideoFrame(pixelBuffer: out, pts: houseTime, duration: frameDuration, source: id)
        onFrame?(frame)
    }

    private func drawSlot(_ slot: Slot, into ctx: CGContext, frac: Double, alpha: Double) {
        guard let cg = slot.currentCGImage(ciContext: ciContext) else { return }
        ctx.saveGState()
        ctx.setAlpha(CGFloat(alpha))
        ctx.interpolationQuality = .high
        let dest: CGRect
        if slot.item.kind == .image && kenBurns {
            dest = kenBurnsRect(imageW: cg.width, imageH: cg.height, frac: frac, ordinal: slot.ordinal)
        } else if slot.item.kind == .video {
            // The embedded MovieSource already fitted the frame to canvas size.
            dest = canvas.canvasRect
        } else {
            dest = ImageSource.fittedRect(imageW: cg.width, imageH: cg.height,
                                          canvasW: canvas.width, canvasH: canvas.height,
                                          mode: contentMode)
        }
        ctx.draw(cg, in: dest)
        ctx.restoreGState()
    }

    /// Ken Burns: a slow zoom-in (1.0 → ~1.16) with a deterministic pan derived
    /// from `ordinal`, over an aspect-FILL base so the frame is always covered.
    private func kenBurnsRect(imageW: Int, imageH: Int, frac: Double, ordinal: Int) -> CGRect {
        let base = ImageSource.fittedRect(imageW: imageW, imageH: imageH,
                                          canvasW: canvas.width, canvasH: canvas.height,
                                          mode: .aspectFill)
        let zoom = 1.0 + 0.16 * frac
        let w = base.width * CGFloat(zoom)
        let h = base.height * CGFloat(zoom)
        let extraW = w - CGFloat(canvas.width)
        let extraH = h - CGFloat(canvas.height)
        // Deterministic pan direction in [-0.4, 0.4] from the ordinal.
        var rng = SplitMix64(state: seed ^ (UInt64(bitPattern: Int64(ordinal)) &* 0x9E37_79B9_7F4A_7C15 &+ 1))
        let panX = (Double(rng.next() % 1000) / 1000.0 - 0.5) * 0.8
        let panY = (Double(rng.next() % 1000) / 1000.0 - 0.5) * 0.8
        // Slide the focal point across the overscan as the dwell progresses.
        let originX = -extraW * CGFloat(0.5 + panX * frac)
        let originY = -extraH * CGFloat(0.5 + panY * frac)
        return CGRect(x: originX, y: originY, width: w, height: h)
    }

    // MARK: Order

    /// Deterministic play order. `shuffle` ⇒ seeded Fisher–Yates (SplitMix64), so
    /// the SAME seed always yields the SAME order (no `Date`/`Math.random`).
    static func makeOrder(count: Int, shuffle: Bool, seed: UInt64) -> [Int] {
        var order = Array(0..<count)
        guard shuffle, count > 1 else { return order }
        var rng = SplitMix64(state: seed ^ 0xA5A5_5A5A_1234_9876)
        var i = count - 1
        while i >= 1 {
            // T5: unbiased bounded index in 0...i via rejection sampling — a plain
            // `next() % (i+1)` is skewed toward the low indices unless (i+1)
            // divides 2^64. Still fully deterministic per seed.
            let j = Int(Self.boundedRandom(&rng, upperBound: UInt64(i + 1)))
            order.swapAt(i, j)
            i -= 1
        }
        return order
    }

    /// Uniform integer in `0..<upperBound` (rejection sampling — no modulo bias),
    /// deterministic for a given RNG state. `upperBound` must be > 0.
    static func boundedRandom(_ rng: inout SplitMix64, upperBound: UInt64) -> UInt64 {
        precondition(upperBound > 0)
        // Discard the top zone that would make `% upperBound` non-uniform.
        let limit = UInt64.max - (UInt64.max % upperBound)
        var r = rng.next()
        while r >= limit { r = rng.next() }
        return r % upperBound
    }

    /// The `items` index for a given dwell ordinal, honoring `loop`. `nil` when a
    /// non-looping montage has run past its last item.
    private func itemIndex(forOrdinal ordinal: Int) -> Int? {
        guard !order.isEmpty else { return nil }
        if loop { return order[((ordinal % order.count) + order.count) % order.count] }
        return ordinal < order.count ? order[ordinal] : nil
    }

    /// Lightweight probe: does the file at `url` carry at least one audio track?
    /// Uses the modern async `loadTracks` API (bridged to sync on a semaphore —
    /// this is a setup-time call, not the hot path — avoiding the deprecated
    /// synchronous accessors so the module stays warning-free). Never throws:
    /// an unreadable file simply reports "no audio".
    private static func fileHasAudioTrack(url: URL) -> Bool {
        let asset = AVURLAsset(url: url)
        let sem = DispatchSemaphore(value: 0)
        let box = OSAllocatedUnfairLock(initialState: false)
        Task {
            if let tracks = try? await asset.loadTracks(withMediaType: .audio) {
                box.withLock { $0 = !tracks.isEmpty }
            }
            sem.signal()
        }
        sem.wait()
        return box.withLock { $0 }
    }

    private func makeSlot(ordinal: Int) -> Slot {
        let idx = itemIndex(forOrdinal: ordinal) ?? order[0]
        let item = items[idx]
        // Only wire the embedded clip's audio decode when this montage actually has
        // an `onAudio` consumer (mirrors MovieSource: no audio loop with no sink).
        // The forward closure gates on the montage still running so no packet fires
        // after stop()/terminal; the Slot additionally gates on being the CURRENT
        // (committed) item so exactly one clip's audio is emitted at a time.
        let audioForward: (@Sendable (AudioPacket) -> Void)?
        if onAudio != nil {
            audioForward = { [weak self] packet in
                guard let self, self.isRunning() else { return }
                self.onAudio?(packet)
            }
        } else {
            audioForward = nil
        }
        return Slot(ordinal: ordinal, item: item, canvasSize: canvasSize,
                    contentMode: contentMode, background: background,
                    onMovieStart: { [movieStartCount] in movieStartCount.withLock { $0 += 1 } },
                    onMovieStop: { [movieStopCount] in movieStopCount.withLock { $0 += 1 } },
                    onAudioForward: audioForward,
                    log: log)
    }

    // MARK: - Slot: one active montage item (image still or running video)

    private final class Slot: @unchecked Sendable {
        let ordinal: Int
        let item: MontageItem
        private let canvasSize: CanvasSize
        private let contentMode: ContentMode
        private let background: RGBAColor
        private let onMovieStart: () -> Void
        private let onMovieStop: () -> Void
        /// Where this slot's video-clip audio packets go — nil if the montage has
        /// no `onAudio` consumer (then the embedded audio decode is never wired).
        private let onAudioForward: (@Sendable (AudioPacket) -> Void)?
        private let log: Logger

        // Image: the decoded source image, loaded once.
        private var imageCG: CGImage?
        // Video: the embedded MovieSource + its latest fitted frame.
        private var movie: MovieSource?
        private let latest = OSAllocatedUnfairLock<(box: PixelBox, gen: UInt64)?>(initialState: nil)
        private var lastConvertedGen: UInt64 = .max
        private var lastCG: CGImage?
        private var started = false
        /// Emit gate: the embedded clip's audio packets are forwarded ONLY while
        /// this is `true` — set when the slot becomes the current (committed) item,
        /// cleared on `stop()`. A prerolled/incoming slot decodes video (and audio,
        /// to keep A/V aligned) but drops its audio here until it is committed, so
        /// exactly one clip's soundtrack reaches the mixer at a time.
        private let audioActive = OSAllocatedUnfairLock(initialState: false)

        init(ordinal: Int, item: MontageItem, canvasSize: CanvasSize,
             contentMode: ContentMode, background: RGBAColor,
             onMovieStart: @escaping () -> Void, onMovieStop: @escaping () -> Void,
             onAudioForward: (@Sendable (AudioPacket) -> Void)?,
             log: Logger) {
            self.ordinal = ordinal
            self.item = item
            self.canvasSize = canvasSize
            self.contentMode = contentMode
            self.background = background
            self.onMovieStart = onMovieStart
            self.onMovieStop = onMovieStop
            self.onAudioForward = onAudioForward
            self.log = log
        }

        /// Enable/disable audio emission for this slot. The director enables the
        /// current (committed) slot and no other, guaranteeing a single active
        /// audio emitter across a transition.
        func setAudioActive(_ on: Bool) { audioActive.withLock { $0 = on } }

        /// Load the item's resource (image decode / MovieSource construction).
        /// Throws a typed `SourceError` (used to fail-fast the FIRST item).
        func load() throws {
            switch item.kind {
            case .image:
                imageCG = try Self.loadCGImage(url: item.url)
            case .video:
                let src = try MovieSource(id: SourceID("montage.movie.\(ordinal).\(item.url.lastPathComponent)"),
                                          fileURL: item.url, canvasSize: canvasSize,
                                          contentMode: contentMode, background: background, loop: true)
                let latest = self.latest
                let genBox = OSAllocatedUnfairLock(initialState: UInt64(0))
                src.onFrame = { frame in
                    let g = genBox.withLock { v -> UInt64 in v += 1; return v }
                    latest.withLock { $0 = (PixelBox(buffer: frame.pixelBuffer), g) }
                }
                // Forward the clip's audio ONLY when the montage wants audio AND
                // this slot is the current (committed) item. `MovieSource` already
                // house-time-stamps each packet; we pass it straight through. This
                // must be set BEFORE `movie.start()` so the embedded audio loop
                // actually runs (it only decodes audio when `onAudio != nil`).
                if let forward = onAudioForward {
                    let active = self.audioActive
                    src.onAudio = { packet in
                        guard active.withLock({ $0 }) else { return }
                        forward(packet)
                    }
                }
                movie = src
            }
        }

        /// Whether this slot can paint a frame RIGHT NOW: an image is ready once
        /// loaded; a video is ready once its embedded `MovieSource` has delivered
        /// a first decoded frame. Used to gate committing to a video slot (T3).
        func isReady() -> Bool {
            switch item.kind {
            case .image: return imageCG != nil
            case .video: return latest.withLock { $0 != nil }
            }
        }

        /// Start the embedded video decode (no-op for an image).
        func startVideoIfNeeded() {
            guard item.kind == .video, let movie, !started else { return }
            started = true
            do { try movie.start(); onMovieStart() }
            catch { log.error("montage: video item failed to start: \(String(describing: error), privacy: .public)") }
        }

        func stop() {
            // Silence this slot BEFORE tearing the movie down so no in-flight audio
            // packet slips through as it leaves (movie.stop() also drains its audio
            // queue, so nothing fires after this returns).
            audioActive.withLock { $0 = false }
            if let movie, started {
                movie.stop()
                onMovieStop()
            }
            started = false
        }

        /// The current visual as a `CGImage` (image: the loaded source; video: the
        /// latest decoded frame, converted + cached until a newer frame arrives).
        func currentCGImage(ciContext: CIContext) -> CGImage? {
            switch item.kind {
            case .image:
                return imageCG
            case .video:
                guard let (box, gen) = latest.withLock({ $0 }) else { return lastCG }
                if gen != lastConvertedGen {
                    let ci = CIImage(cvPixelBuffer: box.buffer)
                    if let cg = ciContext.createCGImage(ci, from: ci.extent) {
                        lastCG = cg
                        lastConvertedGen = gen
                    }
                }
                return lastCG
            }
        }

        private static func loadCGImage(url: URL) throws -> CGImage {
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
}

/// SplitMix64 — a tiny deterministic PRNG for seeded shuffle + Ken-Burns pan
/// (no `Date`/`Math.random`; reproducible per seed, the design's invariant).
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
