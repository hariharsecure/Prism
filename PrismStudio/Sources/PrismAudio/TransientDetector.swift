import CoreMedia
import Foundation
import PrismCore
import os

/// A detected audio onset ("hit"): a sharp energy rise in the program mix.
public struct TransientInfo: Sendable, CustomStringConvertible {
    /// House-time seconds at the onset (the analysis block's start), from packet PTS.
    public let hostSeconds: Double
    /// Onset loudness, normalised 0…1 (peak amplitude of the onset block, 1.0 = full-scale).
    public let strength: Double
    /// The onset's presentation timestamp in house time.
    public let pts: CMTime

    public init(hostSeconds: Double, strength: Double, pts: CMTime) {
        self.hostSeconds = hostSeconds
        self.strength = strength
        self.pts = pts
    }

    public var description: String {
        String(format: "transient @ %.4fs · strength %.2f", hostSeconds, strength)
    }
}

/// Reactive audio transient / onset detector for the program master mix.
///
/// Consumes the mixer's `onMasterMix` `AudioPacket`s (interleaved Float32,
/// house-time PTS) and fires `onTransient` when a loud hit/onset lands, so the
/// app can auto-trigger a stinger/effect on the beat of the action.
///
/// ## How it decides (onset, not level)
/// The signal is downmixed to mono and cut into fixed **analysis blocks** (hop
/// `config.blockSize`, ≈10.7 ms at 48 kHz). Per block we compute short-time RMS
/// and peak. Detection is a **scale-invariant energy jump**: an *adaptive
/// baseline* `envSlow` (an EMA of RMS, `config.baselineTimeConstant`) tracks the
/// recent bed level, and a block fires only when its RMS rises sharply above that
/// baseline — `rms > envSlow · (1 + jump)` where `jump` comes from `sensitivity`.
/// Because the test is a *ratio* to the running bed, a steady tone, steady noise
/// or a slow swell (baseline follows the level) never fire, while a click over a
/// quiet bed (ratio ≫ 1) does. An absolute floor `attackThreshold` gates out
/// numerical noise in silence, and the block must be *rising* (`rms > prevRMS`).
///
/// ## Impulsiveness gate (crest factor)
/// A genuine transient concentrates its energy in a short spike, so its *crest
/// factor* (block peak / block RMS) is high, whereas a sustained tone, steady
/// noise or a *slow swell* has a low, roughly constant crest (~1.414 for a sine).
/// A block therefore fires only when `peak > rms * minCrestFactor`. This makes a
/// smooth amplitude swell impossible to fire even while the adaptive baseline is
/// still warming up (it would otherwise trip the ratio test during the ramp), and
/// it lets the **first** block be evaluated against a near-silence pre-roll
/// baseline (RMS/peak both start at 0) so a genuine *opening* hit fires once
/// instead of being silently swallowed by seeding.
///
/// ## One hit = one fire
/// After a fire, a **debounce/hold** of `minIntervalSeconds` suppresses further
/// fires. This collapses two hits closer than the interval into one and stops a
/// single transient's decay/ring from re-triggering (the decay is falling, so the
/// rising-edge test already rejects it; the hold is belt-and-suspenders and the
/// user-facing min-interval).
///
/// ## Threading
/// The mixer tap calls `process(_:)` on its delivery thread. All mutable analysis
/// state lives behind one lock; `onTransient` is invoked *after* the lock is
/// released, so callbacks never re-enter the lock. `reset()` clears running stats.
public final class TransientDetector: @unchecked Sendable {

    // MARK: Analysis-hop bounds (config-clamp safety)

    /// Analysis-hop floor in frames. `process` never uses a hop below this, so
    /// its block loop always advances the cursor. A 0/negative hop reached
    /// through the mutable `Configuration.blockSize` would otherwise make
    /// `while cursor + block <= pending.count` spin forever on the audio-callback
    /// thread (the reported hang) — the floor makes the loop terminate.
    public static let minimumBlockSize = 32
    /// Analysis-hop ceiling in frames. Caps an absurd hop (e.g. `Int.max`) so
    /// `pending` can always fill a block and never grows without bound (a block
    /// that never completes would append every packet to `pending` until OOM).
    public static let maximumBlockSize = 96_000
    /// Clamp a configured hop into `[minimumBlockSize, maximumBlockSize]`.
    /// Idempotent for any value produced by `Configuration.init`.
    static func effectiveBlockSize(_ configured: Int) -> Int {
        min(max(configured, minimumBlockSize), maximumBlockSize)
    }

    // MARK: Configuration

    public struct Configuration: Sendable {
        /// 0…1. Higher → lower energy-jump threshold → fires on smaller onsets.
        public var sensitivity: Double
        /// Debounce: minimum seconds between fires (also the re-trigger hold).
        public var minIntervalSeconds: Double
        /// Absolute amplitude floor (0…1) a block's RMS must exceed to fire at
        /// all — rejects onsets in near-silence. ≈ −40 dBFS by default.
        public var attackThreshold: Float
        /// Analysis hop in frames (also the timing resolution of a fire).
        public var blockSize: Int
        /// Adaptive-baseline time constant in seconds (how fast `envSlow`
        /// follows the level; larger = slower = more onset-selective).
        public var baselineTimeConstant: Double

        public init(sensitivity: Double = 0.5,
                    minIntervalSeconds: Double = 0.10,
                    attackThreshold: Float = 0.01,
                    blockSize: Int = 512,
                    baselineTimeConstant: Double = 0.15) {
            // Reject non-finite (NaN/±inf) values that would poison the ratio
            // test / baseline EMA, then clamp into a safe range. The hop is
            // clamped into [min, max]: the floor stops a zero/negative hop from
            // spinning `process`; the ceiling stops an absurd hop from growing
            // the pending buffer without bound.
            self.sensitivity = sensitivity.isFinite ? min(max(sensitivity, 0), 1) : 0.5
            self.minIntervalSeconds = minIntervalSeconds.isFinite ? max(minIntervalSeconds, 0) : 0.10
            self.attackThreshold = attackThreshold.isFinite ? max(attackThreshold, 0) : 0.01
            self.blockSize = TransientDetector.effectiveBlockSize(blockSize)
            self.baselineTimeConstant = baselineTimeConstant.isFinite ? max(baselineTimeConstant, 1e-3) : 0.15
        }

        /// Re-run the clamps on this value, returning a guaranteed in-range copy.
        /// Idempotent for anything produced by `init`; a safety net so a
        /// replacement `configuration` (whose fields are mutable `var`s and can
        /// be set to e.g. `blockSize = 0`, bypassing `init`) can never install an
        /// out-of-range field that would hang or destabilise `process`.
        public func normalized() -> Configuration {
            Configuration(sensitivity: sensitivity,
                          minIntervalSeconds: minIntervalSeconds,
                          attackThreshold: attackThreshold,
                          blockSize: blockSize,
                          baselineTimeConstant: baselineTimeConstant)
        }

        /// Maps `sensitivity` (0…1) to the required RMS-over-baseline ratio.
        /// sensitivity 0 → 3.0× (very selective); 1 → 1.5× (twitchy).
        var jumpRatio: Float { Float(3.0 - 1.5 * sensitivity) }
    }

    /// Fired once per detected transient, on the caller's thread (the mixer tap
    /// thread in production). Set before feeding packets.
    public var onTransient: (@Sendable (TransientInfo) -> Void)? {
        get { lock.withLock { $0.onTransient } }
        set { lock.withLock { $0.onTransient = newValue } }
    }

    /// The active configuration. Re-reading/replacing is thread-safe; changes
    /// take effect on the next block.
    /// A replacement is **normalized** (clamps re-run) before it is stored, so a
    /// caller cannot install an out-of-range field such as `blockSize = 0`
    /// (legal Swift on the mutable struct) that would hang `process`.
    public var configuration: Configuration {
        get { lock.withLock { $0.config } }
        set {
            let normalized = newValue.normalized()
            lock.withLock { $0.config = normalized }
        }
    }

    // MARK: State (all guarded by `lock`)

    private struct State {
        var config: Configuration
        var onTransient: (@Sendable (TransientInfo) -> Void)?

        /// Leftover mono samples not yet forming a full block.
        var pending: [Float] = []
        /// PTS of `pending[0]`; advanced by one block as blocks are consumed.
        var headPTS: CMTime = .zero
        var havePTS: Bool = false

        /// Adaptive baseline (EMA of block RMS). Starts at 0 = near-silence
        /// pre-roll, so the very first block can be evaluated as an onset.
        var envSlow: Float = 0
        /// Previous block RMS (rising-edge test).
        var prevRMS: Float = 0
        /// House-seconds of the last fire (−inf = none); debounce reference.
        var lastFireSeconds: Double = -.infinity

        init(config: Configuration) { self.config = config }
    }

    private let lock: OSAllocatedUnfairLock<State>
    private let log = EngineLog.logger("audio.transient")
    /// Minimum crest factor (peak / RMS) a block must exhibit to count as an
    /// onset. A sine is ~1.414 and uniform noise ~1.73; a percussive click is far
    /// higher, so this cleanly rejects sustained/steady/swelling content.
    private static let minCrestFactor: Float = 2.0
    /// One-shot warning latch for unsupported packet formats (not perf-critical).
    private let warnedFormat = OSAllocatedUnfairLock<Bool>(initialState: false)

    public let sampleRate: Double

    public init(sampleRate: Double = 48_000, configuration: Configuration = Configuration()) {
        // Reject a non-finite or non-positive sample rate: it feeds the block
        // duration / EMA coefficient and the `CMTimeScale(sampleRate.rounded())`
        // used to stamp fires — 0 or NaN would yield invalid timing. Fall back
        // to the standard 48 kHz. Normalize the config so a directly-mutated
        // struct (e.g. `blockSize = 0`) can't reach `process`.
        self.sampleRate = (sampleRate.isFinite && sampleRate > 0) ? sampleRate : 48_000
        self.lock = OSAllocatedUnfairLock(initialState: State(config: configuration.normalized()))
    }

    #if DEBUG
    /// TEST HOOK: count of buffered mono samples not yet consumed into a block.
    /// Used to assert the pending buffer stays bounded under a hostile blockSize.
    var _test_pendingSampleCount: Int { lock.withLock { $0.pending.count } }
    #endif

    /// Clear all running statistics and buffered audio. Config and `onTransient`
    /// are kept.
    public func reset() {
        lock.withLock { s in
            s.pending.removeAll(keepingCapacity: true)
            s.headPTS = .zero
            s.havePTS = false
            s.envSlow = 0
            s.prevRMS = 0
            s.lastFireSeconds = -.infinity
        }
    }

    // MARK: Ingest

    /// Feed one program-mix packet. Detected transients are delivered to
    /// `onTransient` (after internal locking is released).
    public func process(_ packet: AudioPacket) {
        // Decode outside the lock (read-only on the packet), then analyse under it.
        guard let mono = Self.downmixMono(packet, warnLatch: warnedFormat, log: log) else { return }
        guard !mono.samples.isEmpty else { return }

        let fires: [TransientInfo] = lock.withLock { s in
            var fired: [TransientInfo] = []
            // Clamp the hop wherever the loop consumes it — even if a future
            // change reintroduces a way to store an out-of-range blockSize, the
            // block loop still advances (never spins) and stays bounded.
            let block = Self.effectiveBlockSize(s.config.blockSize)

            // Re-sync the timeline when the pending buffer is empty (contiguous
            // streams stay exact). C7: also detect a PTS discontinuity that lands
            // with leftover buffered samples — track the expected next PTS and, if
            // the incoming packet deviates beyond a small tolerance, drop the stale
            // partial block and begin a fresh timeline at the incoming PTS so
            // post-gap fires report correct house time (not the old timeline).
            if !s.havePTS || s.pending.isEmpty {
                s.headPTS = mono.startPTS
                s.havePTS = true
            } else {
                let bufferedFrames = CMTimeValue(s.pending.count)
                let expectedPTS = CMTimeAdd(
                    s.headPTS,
                    CMTime(value: bufferedFrames, timescale: CMTimeScale(sampleRate.rounded())))
                let deviation = abs(CMTimeGetSeconds(CMTimeSubtract(mono.startPTS, expectedPTS)))
                let tolerance = 0.5 * Double(block) / sampleRate
                if deviation > tolerance {
                    s.pending.removeAll(keepingCapacity: true)
                    s.headPTS = mono.startPTS
                }
            }
            s.pending.append(contentsOf: mono.samples)

            let blockDuration = CMTime(value: CMTimeValue(block),
                                       timescale: CMTimeScale(sampleRate.rounded()))

            var cursor = 0
            let tau = s.config.baselineTimeConstant
            // Per-block EMA coefficient for the baseline (frame-rate independent).
            let alpha = Float(min(1.0, (Double(block) / sampleRate) / tau))

            while cursor + block <= s.pending.count {
                var sumSq: Float = 0
                var peak: Float = 0
                var i = cursor
                let end = cursor + block
                while i < end {
                    let v = s.pending[i]
                    sumSq += v * v
                    let a = abs(v)
                    if a > peak { peak = a }
                    i += 1
                }
                let rms = (sumSq / Float(block)).squareRoot()

                let blockPTS = s.headPTS
                // C6: evaluate EVERY block, including the first (baseline/prevRMS
                // start at 0 = near-silence pre-roll), so a genuine opening hit is
                // detected instead of merely seeding the baseline.
                let baseline = s.envSlow
                let jump = s.config.jumpRatio
                let rising = rms > s.prevRMS
                let aboveFloor = rms > s.config.attackThreshold
                let sharpJump = rms > baseline * (1 + jump)
                // C5: impulsiveness gate — a smooth swell / steady tone / noise has
                // a low crest factor and can never fire, even during warm-up.
                let impulsive = peak > rms * Self.minCrestFactor

                let seconds = blockPTS.seconds
                let debounced = (seconds - s.lastFireSeconds) >= s.config.minIntervalSeconds

                if aboveFloor && sharpJump && rising && impulsive && debounced {
                    let strength = Double(min(peak, 1))
                    fired.append(TransientInfo(hostSeconds: seconds,
                                               strength: strength,
                                               pts: blockPTS))
                    s.lastFireSeconds = seconds
                }

                // Update the adaptive baseline. It creeps toward the current level,
                // so a click barely moves it (ratio stays large) while a slow swell
                // is tracked (ratio stays ~1 → no fire).
                s.envSlow = baseline + alpha * (rms - baseline)
                s.prevRMS = rms

                cursor += block
                s.headPTS = CMTimeAdd(s.headPTS, blockDuration)
            }

            if cursor > 0 { s.pending.removeFirst(cursor) }
            return fired
        }

        guard !fires.isEmpty else { return }
        let callback = lock.withLock { $0.onTransient }
        guard let callback else { return }
        for f in fires { callback(f) }
    }

    // MARK: Decode

    private struct MonoBlockData {
        var samples: [Float]
        var startPTS: CMTime
    }

    /// Downmix a program packet to mono Float32. Supports interleaved Float32
    /// LPCM (the master-mix contract). Other formats are skipped with a one-time
    /// warning.
    private static func downmixMono(_ packet: AudioPacket,
                                    warnLatch: OSAllocatedUnfairLock<Bool>,
                                    log: Logger) -> MonoBlockData? {
        let sb = packet.sampleBuffer
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else {
            return nil
        }
        let asbd = asbdPtr.pointee
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0 else { return MonoBlockData(samples: [], startPTS: packet.pts) }

        let channels = Int(asbd.mChannelsPerFrame)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let is32 = asbd.mBitsPerChannel == 32
        // C8: require PACKED, exact stride so the `floats[base + c]` indexing below
        // can't mis-read a padded interleaved ASBD (mBytesPerFrame > channels*4).
        let bytesPerFrame = channels * MemoryLayout<Float>.size
        let isPacked = (asbd.mFormatFlags & kAudioFormatFlagIsPacked) != 0
        let exactStride = Int(asbd.mBytesPerFrame) == bytesPerFrame
            && asbd.mFramesPerPacket == 1
            && Int(asbd.mBytesPerPacket) == bytesPerFrame
        guard asbd.mFormatID == kAudioFormatLinearPCM, isFloat, is32, isInterleaved,
              channels >= 1, isPacked, exactStride else {
            warnLatch.withLock { warned in
                if !warned {
                    warned = true
                    log.error("transient: unsupported packet format (need packed interleaved Float32 LPCM, exact stride); skipping")
                }
            }
            return nil
        }

        guard let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        var lengthAtOffset = 0
        var totalLength = 0
        var rawPtr: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(block, atOffset: 0,
                                                 lengthAtOffsetOut: &lengthAtOffset,
                                                 totalLengthOut: &totalLength,
                                                 dataPointerOut: &rawPtr)
        let needed = frames * channels * MemoryLayout<Float>.size
        guard status == kCMBlockBufferNoErr, let rawPtr, lengthAtOffset >= needed else {
            return nil
        }

        var mono = [Float](repeating: 0, count: frames)
        let floats = UnsafeRawPointer(rawPtr).assumingMemoryBound(to: Float.self)
        if channels == 1 {
            for f in 0..<frames { mono[f] = floats[f] }
        } else {
            let inv = 1.0 / Float(channels)
            for f in 0..<frames {
                var acc: Float = 0
                let base = f * channels
                for c in 0..<channels { acc += floats[base + c] }
                mono[f] = acc * inv
            }
        }
        return MonoBlockData(samples: mono, startPTS: packet.pts)
    }
}
