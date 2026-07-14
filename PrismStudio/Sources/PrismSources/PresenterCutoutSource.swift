import CoreMedia
import CoreVideo
import Foundation
import PrismCore

/// A `VideoSource` that wraps an upstream feed (camera / `MovieSource` / any
/// `VideoSource`) and emits a **premultiplied-alpha presenter cutout**: the
/// person opaque, the background transparent, so it layers over the scene
/// beneath without a physical green screen.
///
/// Push-driven: it hooks the upstream's `onFrame`, runs Vision segmentation +
/// premultiplied compositing (`PresenterCutout`) on a private serial worker
/// queue, and re-emits the cutout frame on that queue with the upstream frame's
/// PTS/source preserved (house-time discipline — never re-stamp).
///
/// Back-pressure: segmentation is expensive, so frames arriving while a run is
/// in flight replace a single pending slot (**latest wins**) rather than
/// queueing — the capture thread is never blocked and never backs up. This
/// mirrors `PrismVision.PersonSegmenter`'s off-path model without the extra rate
/// limiter (segmentation is self-limiting at camera rates).
///
/// No-person handling and background fill are `PresenterCutout.Options`
/// (transparent cutout by default; solid-colour fill and pass-through
/// available).
///
/// Thread model: `start()`/`stop()`/option setters from one control thread;
/// `onFrame` fires on the worker queue. `onError` (optional) reports
/// segmentation failures on the worker queue; a failing frame is dropped, the
/// source keeps running.
public final class PresenterCutoutSource: VideoSource {
    public let id: SourceID
    /// Set before `start()`. Called on the worker queue.
    public var onFrame: ((VideoFrame) -> Void)?
    /// Optional clean-ISO tap (sol wave-16 #2): fired with the UPSTREAM RAW frame —
    /// the original camera/movie frame BEFORE segmentation — on the upstream's
    /// capture queue, as each frame arrives. `onFrame` still emits the processed
    /// cutout for the program; this lets an ISO recording capture the true clean
    /// post-production source (native, no baked-in segmentation FX) rather than the
    /// wrapper's processed output. Set before `start()`.
    public var onRawFrame: ((VideoFrame) -> Void)?
    /// Optional: fired on the worker queue when a frame fails to process.
    public var onError: ((Error) -> Void)?

    public var state: SourceState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    /// Live-tunable cutout options (quality/background/feather/no-person).
    ///
    /// F12: these are **wrapper-owned** under `lock` — the control thread only
    /// ever touches `_options`. The worker never reads this live mutable struct;
    /// it snapshots it once per dequeued frame (under the lock) and applies that
    /// immutable snapshot to `engine.options` on the serial worker before running
    /// the cutout, so a concurrent quality/background/feather/no-person edit can
    /// never tear a multi-field read across segmentation + compositing.
    public var options: PresenterCutout.Options {
        get { lock.lock(); defer { lock.unlock() }; return _options }
        set { lock.lock(); _options = newValue; lock.unlock() }
    }

    private let upstream: VideoSource
    private let engine: PresenterCutout
    private let queue = DispatchQueue(label: "studio.prism.source.cutout", qos: .userInitiated)
    /// Identifies the worker queue so `stop()` can detect a nested stop (called
    /// from within `onFrame`) and skip a sync-on-self drain (deadlock guard).
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let lock = NSLock()
    private let log = EngineLog.logger("sources.cutout")

    private var _state: SourceState = .idle
    private var pending: VideoFrame?
    private var busy = false
    /// Wrapper-owned cutout options (F12). Guarded by `lock`; the ONLY field the
    /// control-thread setter mutates. Snapshotted per-frame onto `engine.options`
    /// by the worker so the engine never sees a torn multi-field edit.
    private var _options: PresenterCutout.Options

    #if DEBUG
    /// TEST HOOK (F12): invoked on the worker AFTER the per-frame options snapshot
    /// has been applied to the engine and BEFORE `cutout` runs. Lets a test mutate
    /// `options` from another thread mid-flight to prove the in-flight frame uses
    /// the SNAPSHOT, not the live mutable struct.
    public var _test_beforeCutout: ((VideoFrame) -> Void)?
    /// TEST HOOK (F12): the engine options actually in effect for the frame the
    /// worker just processed (recorded right after `cutout`).
    public var _test_optionsUsed: ((PresenterCutout.Options) -> Void)?
    #endif

    /// - Parameters:
    ///   - id: this source's identity (defaults to a fresh id).
    ///   - upstream: the feed to cut out. Its `onFrame` is taken over by this
    ///     source; do not also consume it elsewhere.
    ///   - options: cutout tunables.
    public init(id: SourceID = SourceID("cutout.\(UUID().uuidString)"),
                wrapping upstream: VideoSource,
                options: PresenterCutout.Options = PresenterCutout.Options()) {
        self.id = id
        self.upstream = upstream
        self.engine = PresenterCutout(options: options)
        self._options = options
        queue.setSpecific(key: queueKey, value: 1)
    }

    public func start() throws {
        lock.lock()
        guard _state == .idle || _state == .failed else { lock.unlock(); return }
        _state = .starting
        lock.unlock()

        upstream.onFrame = { [weak self] frame in
            guard let self else { return }
            // sol wave-16 #2: hand the RAW upstream frame to the clean-ISO tap BEFORE
            // segmentation — the ISO angle must be the true clean source, not the
            // cutout output. The program still gets the processed cutout via `submit`.
            self.onRawFrame?(frame)
            self.submit(frame)
        }
        do {
            try upstream.start()
        } catch {
            lock.lock(); _state = .failed; lock.unlock()
            throw error
        }
        lock.lock(); _state = .running; lock.unlock()
    }

    public func stop() {
        // If called from within `onFrame` we are executing ON the worker queue;
        // capture that here so the drain below skips sync-on-self (deadlock).
        let onWorkerQueue = DispatchQueue.getSpecific(key: queueKey) != nil

        lock.lock()
        guard _state == .running || _state == .starting || _state == .failed else { lock.unlock(); return }
        _state = .stopping
        pending = nil
        lock.unlock()

        upstream.stop()
        upstream.onFrame = nil

        // Drain the worker queue (mirrors MovieSource): block until any in-flight
        // drain() iteration finishes so NO onFrame fires after stop() returns.
        // The state is already .stopping, so drain() drops its emit (below); this
        // also guarantees the worker is fully quiesced before we go idle. Skip
        // when we're ON the worker (nested stop from onFrame) to avoid deadlock.
        if !onWorkerQueue { queue.sync {} }

        lock.lock(); _state = .idle; lock.unlock()
    }

    // MARK: - Worker

    /// Non-blocking: park the frame in the single pending slot (latest wins) and
    /// kick the worker if idle. Safe to call from the upstream's capture queue.
    private func submit(_ frame: VideoFrame) {
        lock.lock()
        guard _state == .running || _state == .starting else { lock.unlock(); return }
        pending = frame
        let shouldStart = !busy
        if shouldStart { busy = true }
        lock.unlock()
        if shouldStart { queue.async { [weak self] in self?.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            // Stop draining the instant we leave the running set — a stop() that
            // landed while we were mid-cutout must not let this loop emit again.
            // Stop draining the instant we leave the running set — a stop() that
            // landed while we were mid-cutout must not let this loop emit again.
            guard _state == .running || _state == .starting, let frame = pending else {
                busy = false
                lock.unlock()
                return
            }
            pending = nil
            // F12: snapshot the wrapper-owned options WITH the dequeued frame,
            // under the lock. This immutable value is the ONLY options the engine
            // sees for this frame — a control-thread edit that lands after this
            // point cannot tear the segmentation+composite multi-field read.
            let snapshot = _options
            lock.unlock()

            do {
                engine.options = snapshot   // worker-only write; never from control thread
                #if DEBUG
                _test_beforeCutout?(frame)
                #endif
                let cut = try engine.cutout(from: frame)
                #if DEBUG
                _test_optionsUsed?(engine.options)
                #endif
                // Re-check under the lock right before delivering: stop() may have
                // landed during the (expensive) cutout, and no onFrame/onError may
                // fire after stop() — terminal-state discipline (mirrors MovieSource).
                lock.lock()
                let live = _state == .running || _state == .starting
                lock.unlock()
                if live { onFrame?(cut) }
            } catch {
                log.error("cutout failed for \(frame.source, privacy: .public): \(String(describing: error), privacy: .public)")
                lock.lock()
                let live = _state == .running || _state == .starting
                lock.unlock()
                if live { onError?(error) }
            }
        }
    }
}
