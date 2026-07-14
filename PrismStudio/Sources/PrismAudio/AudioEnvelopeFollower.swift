import CoreMedia
import Foundation
import PrismCore
import os

/// Audio-driven **mouth-openness** follower for character lip-sync.
///
/// Consumes the program master mix (`AudioMixer.onMasterMix` `AudioPacket`s —
/// interleaved Float32, house-time PTS) and turns the program loudness into a
/// smoothed **openness value in 0…1** that a character rig polls each frame to
/// drive a mouth. It is the audio half of lip-sync: it produces the *signal*, not
/// the rig (the `CharacterSource` that maps openness → mouth blendshape is a
/// separate follow-up).
///
/// ## How the value is computed (per analysis block)
/// The signal is downmixed to mono and cut into fixed **analysis blocks**
/// (`config.blockSize`, ≈10.7 ms at 48 kHz). For each block:
/// 1. **Short-time RMS** of the mono block (loudness proxy).
/// 2. **Noise-floor gate:** RMS at or below `config.noiseFloor` yields a target of
///    0, so a silent or quiet-room bed reads as a closed mouth. Above the floor the
///    excess (`rms − noiseFloor`) is what drives the mouth, so the gate is a soft
///    knee rather than a hard on/off.
/// 3. **Gain / sensitivity:** the gated excess is scaled by `config.gain`.
/// 4. **Perceptual curve:** a `sqrt` soft-curve so the value reads like speech
///    loudness (moderate speech already opens the mouth well) rather than raw RMS,
///    then clamped to 0…1. This is the block *target*.
/// 5. **Asymmetric attack/release smoothing:** a one-pole envelope tracks the
///    target with a **fast attack** (`attackSeconds`, mouth opens promptly on
///    speech) and a **slower release** (`releaseSeconds`, mouth closes naturally).
///    Because the per-block coefficient is `1 − exp(−blockDuration / τ)` with
///    `τ_attack < τ_release`, the rise coefficient is larger than the fall
///    coefficient, so the mouth opens faster than it closes, and every step is a
///    *bounded* fraction of the remaining distance — the output is continuous /
///    slew-limited, never a per-block jump straight to full.
///
/// ## Threading
/// The mixer tap calls `process(_:)` on its delivery thread. All mutable state
/// lives behind one `OSAllocatedUnfairLock`; `openness` reads it atomically and
/// the rig may poll it from any thread. `onEnvelope` is invoked *after* the lock
/// is released, so callbacks never re-enter the lock. `reset()` closes the mouth
/// and clears buffered audio.
public final class AudioEnvelopeFollower: @unchecked Sendable {

    // MARK: Configuration

    /// Smallest analysis hop the follower will ever use, in frames. `process`
    /// clamps to this even if a `Configuration` somehow carries a smaller value,
    /// so the block loop always advances the cursor and can never spin forever /
    /// append envelope updates without bound.
    public static let minimumBlockSize = 32

    /// Largest analysis hop the follower will ever use, in frames — **2 s at
    /// 48 kHz**. The follower drives real-time mouth-openness for lip-sync; the
    /// hop is the openness-update granularity (default 512 frames ≈ 10.7 ms), so
    /// any hop beyond a fraction of a second is already useless for the feature.
    /// This ceiling is not an operating value but the safety bound that makes the
    /// **pending buffer bounded under every legal config**: `process` only drains
    /// `pending` once it holds a full block, so an unclamped `blockSize` (e.g.
    /// `Int.max`) is a threshold that is never reached — every packet is appended
    /// forever (~192 KB/s at 48 kHz mono) until OOM (Class G). With the clamp,
    /// `pending` never exceeds ~one block + one packet (≤ ~768 KB). Chosen a few
    /// seconds (not tighter) so it never intrudes on any real lip-sync hop.
    public static let maximumBlockSize = 96_000

    /// The hop `process` actually uses for a configured block size: clamped to
    /// `[minimumBlockSize, maximumBlockSize]`. The floor keeps the block loop
    /// advancing (no infinite spin); the ceiling keeps the pending buffer bounded
    /// (no unbounded append). This is the last-line-of-defense clamp behind
    /// `Configuration`'s own; exposed `internal` so both invariants can be
    /// unit-tested directly.
    internal static func effectiveBlockSize(_ configured: Int) -> Int {
        min(max(configured, minimumBlockSize), maximumBlockSize)
    }

    public struct Configuration: Sendable {
        /// Attack time constant in seconds — how fast the mouth *opens*. Small so
        /// it reacts promptly to speech onsets (~10–30 ms).
        ///
        /// Immutable by design: every field is clamped once in `init` and cannot be
        /// mutated afterwards, so a stored `Configuration` is always in range (a
        /// `blockSize = 0` could otherwise hang `process`). Build a variant by
        /// constructing a fresh `Configuration` — the clamps re-run.
        public let attackSeconds: Double
        /// Release time constant in seconds — how fast the mouth *closes*. Larger
        /// than `attackSeconds` so it decays naturally after speech (~80–150 ms).
        public let releaseSeconds: Double
        /// Linear RMS noise floor (0…1). Blocks at or below this read as a closed
        /// mouth; a quiet-room bed sits under it. ≈ −40 dBFS by default.
        public let noiseFloor: Double
        /// Sensitivity: multiplies the above-floor excess before the soft curve.
        /// Higher → the mouth opens wider for the same loudness.
        public let gain: Double
        /// Analysis hop in frames (the openness update granularity). Always in
        /// `[AudioEnvelopeFollower.minimumBlockSize, .maximumBlockSize]`.
        public let blockSize: Int

        public init(attackSeconds: Double = 0.020,
                    releaseSeconds: Double = 0.120,
                    noiseFloor: Double = 0.010,
                    gain: Double = 4.0,
                    blockSize: Int = 512) {
            // Reject non-finite (NaN/±inf) values that would poison the one-pole
            // coefficients or the gate, then clamp into a safe range.
            self.attackSeconds = attackSeconds.isFinite ? max(attackSeconds, 1e-4) : 0.020
            self.releaseSeconds = releaseSeconds.isFinite ? max(releaseSeconds, 1e-4) : 0.120
            self.noiseFloor = noiseFloor.isFinite ? min(max(noiseFloor, 0), 1) : 0.010
            self.gain = gain.isFinite ? max(gain, 0) : 4.0
            // Clamp into [min, max]: the floor stops a zero/negative hop from
            // spinning `process`; the ceiling stops an extreme hop (e.g. Int.max)
            // from making the pending buffer grow without bound (Class G).
            self.blockSize = AudioEnvelopeFollower.effectiveBlockSize(blockSize)
        }

        /// Re-run the clamps on this value, returning a guaranteed in-range copy.
        /// Idempotent for anything produced by `init`; a safety net so a
        /// replacement `configuration` can never install out-of-range fields even
        /// if a future change reintroduces a way to build an unclamped struct.
        public func normalized() -> Configuration {
            Configuration(attackSeconds: attackSeconds, releaseSeconds: releaseSeconds,
                          noiseFloor: noiseFloor, gain: gain, blockSize: blockSize)
        }
    }

    /// Current mouth openness, 0 (closed) … 1 (wide). Thread-safe; poll it from the
    /// rig's render loop each frame.
    public var openness: Double { lock.withLock { Double($0.envelope) } }

    /// Optional per-block sink for the smoothed openness (fired on the caller's
    /// thread, *after* the internal lock is released). Set before feeding packets.
    public var onEnvelope: (@Sendable (Double) -> Void)? {
        get { lock.withLock { $0.onEnvelope } }
        set { lock.withLock { $0.onEnvelope = newValue } }
    }

    /// The active configuration. Reading/replacing is thread-safe; changes take
    /// effect on the next block. A replacement is **normalized** (clamps re-run)
    /// before it is stored, so it can never install an out-of-range field such as
    /// `blockSize = 0` that would hang `process`.
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
        var onEnvelope: (@Sendable (Double) -> Void)?
        /// Leftover mono samples not yet forming a full block.
        var pending: [Float] = []
        /// Smoothed openness (the polled value), 0…1.
        var envelope: Float = 0

        init(config: Configuration) { self.config = config }
    }

    private let lock: OSAllocatedUnfairLock<State>
    private let log = EngineLog.logger("audio.envelope")
    /// One-shot warning latch for unsupported packet formats (not perf-critical).
    private let warnedFormat = OSAllocatedUnfairLock<Bool>(initialState: false)

    public let sampleRate: Double

    public init(sampleRate: Double = 48_000, configuration: Configuration = Configuration()) {
        // Reject a non-finite or non-positive sample rate: it feeds `blockDuration`
        // (→ NaN/inf one-pole coefficients) and would make the whole envelope
        // meaningless. Fall back to the standard 48 kHz.
        self.sampleRate = (sampleRate.isFinite && sampleRate > 0) ? sampleRate : 48_000
        self.lock = OSAllocatedUnfairLock(initialState: State(config: configuration.normalized()))
    }

    #if DEBUG
    /// TEST HOOK: count of buffered mono samples not yet consumed into a block.
    /// Used to assert the pending buffer stays bounded under a hostile blockSize.
    var _test_pendingSampleCount: Int { lock.withLock { $0.pending.count } }
    #endif

    /// Close the mouth and drop buffered audio. Config and `onEnvelope` are kept.
    public func reset() {
        lock.withLock { s in
            s.pending.removeAll(keepingCapacity: true)
            s.envelope = 0
        }
    }

    // MARK: Ingest

    /// Feed one program-mix packet. Advances the openness envelope one step per
    /// full analysis block and delivers each step to `onEnvelope` (after the
    /// internal lock is released).
    public func process(_ packet: AudioPacket) {
        guard let mono = Self.downmixMono(packet, warnLatch: warnedFormat, log: log) else { return }
        guard !mono.isEmpty else { return }

        let updates: [Double] = lock.withLock { s in
            s.pending.append(contentsOf: mono)
            // Hard floor the hop even though `Configuration` already clamps it:
            // a zero/negative block would make the loop below never advance the
            // cursor (`cursor + 0 <= count`), spinning forever and appending
            // envelope updates without bound on the audio callback.
            let block = Self.effectiveBlockSize(s.config.blockSize)
            guard s.pending.count >= block else { return [] }

            // Frame-rate-independent one-pole coefficients: coeff = 1 − exp(−T/τ).
            // τ_attack < τ_release ⇒ attackCoeff > releaseCoeff ⇒ opens faster
            // than it closes. Each step moves a bounded fraction of the remaining
            // distance, so the output is slew-limited (no instant jump to full).
            let blockDuration = Double(block) / sampleRate
            let attackCoeff = Float(1.0 - exp(-blockDuration / s.config.attackSeconds))
            let releaseCoeff = Float(1.0 - exp(-blockDuration / s.config.releaseSeconds))
            let floor = Float(s.config.noiseFloor)
            let gain = Float(s.config.gain)

            var emitted: [Double] = []
            var cursor = 0
            while cursor + block <= s.pending.count {
                var sumSq: Float = 0
                var i = cursor
                let end = cursor + block
                while i < end {
                    let v = s.pending[i]
                    sumSq += v * v
                    i += 1
                }
                let rms = (sumSq / Float(block)).squareRoot()

                // Gate → gain → perceptual soft-curve → clamp = block target.
                let excess = rms - floor
                var target: Float = 0
                if excess > 0 {
                    let driven = excess * gain
                    target = min(driven.squareRoot(), 1)   // sqrt soft-curve
                }

                // Asymmetric attack/release toward the target.
                let coeff = target > s.envelope ? attackCoeff : releaseCoeff
                s.envelope += coeff * (target - s.envelope)
                if s.envelope < 0 { s.envelope = 0 } else if s.envelope > 1 { s.envelope = 1 }

                emitted.append(Double(s.envelope))
                cursor += block
            }
            if cursor > 0 { s.pending.removeFirst(cursor) }
            return emitted
        }

        guard !updates.isEmpty else { return }
        let callback = lock.withLock { $0.onEnvelope }
        guard let callback else { return }
        for v in updates { callback(v) }
    }

    // MARK: Decode

    /// Downmix a program packet to mono Float32. Supports **packed interleaved
    /// Float32 LPCM** (the master-mix contract) and copies segment-safely from a
    /// discontiguous `CMBlockBuffer`. Other formats are skipped with a one-time
    /// warning. (Mirrors `TransientDetector`'s hardened reader — packed/exact-stride
    /// guard prevents mis-indexing a padded ASBD, and the `lengthAtOffset >= needed`
    /// check prevents reading past the first contiguous segment.)
    private static func downmixMono(_ packet: AudioPacket,
                                    warnLatch: OSAllocatedUnfairLock<Bool>,
                                    log: Logger) -> [Float]? {
        let sb = packet.sampleBuffer
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else {
            return nil
        }
        let asbd = asbdPtr.pointee
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0 else { return [] }

        let channels = Int(asbd.mChannelsPerFrame)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let is32 = asbd.mBitsPerChannel == 32
        // Require PACKED, exact stride so the `floats[base + c]` indexing below can't
        // mis-read a padded interleaved ASBD (mBytesPerFrame > channels*4).
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
                    log.error("envelope: unsupported packet format (need packed interleaved Float32 LPCM, exact stride); skipping")
                }
            }
            return nil
        }

        guard let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let needed = frames * channels * MemoryLayout<Float>.size

        // Segment-safe read: try the fast contiguous path, else copy the whole
        // (possibly discontiguous) buffer into a local staging array.
        var lengthAtOffset = 0
        var totalLength = 0
        var rawPtr: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(block, atOffset: 0,
                                                 lengthAtOffsetOut: &lengthAtOffset,
                                                 totalLengthOut: &totalLength,
                                                 dataPointerOut: &rawPtr)
        guard status == kCMBlockBufferNoErr, totalLength >= needed else { return nil }

        var mono = [Float](repeating: 0, count: frames)
        let inv = 1.0 / Float(channels)

        if let rawPtr, lengthAtOffset >= needed {
            // Contiguous: index directly.
            let floats = UnsafeRawPointer(rawPtr).assumingMemoryBound(to: Float.self)
            if channels == 1 {
                for f in 0..<frames { mono[f] = floats[f] }
            } else {
                for f in 0..<frames {
                    var acc: Float = 0
                    let base = f * channels
                    for c in 0..<channels { acc += floats[base + c] }
                    mono[f] = acc * inv
                }
            }
        } else {
            // Discontiguous: copy out segment-safely before touching samples.
            var staging = [Float](repeating: 0, count: frames * channels)
            let copyStatus = staging.withUnsafeMutableBytes { dst -> OSStatus in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: needed,
                                           destination: dst.baseAddress!)
            }
            guard copyStatus == kCMBlockBufferNoErr else { return nil }
            if channels == 1 {
                for f in 0..<frames { mono[f] = staging[f] }
            } else {
                for f in 0..<frames {
                    var acc: Float = 0
                    let base = f * channels
                    for c in 0..<channels { acc += staging[base + c] }
                    mono[f] = acc * inv
                }
            }
        }
        return mono
    }
}
