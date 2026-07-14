import CoreMedia
import Foundation
import PrismCore

/// Headless, deterministic verification of `TransientDetector` — no audio
/// hardware, no TCC, no real time. Synthesises a quiet bed with known clicks and
/// asserts the detector fires exactly on them (and never on steady tone / noise /
/// silence / a slow swell).
///
/// The synthesis helpers are `public` so `TransientDetectorTests` (XCTest) can
/// build identical program-mix packets.
public enum TransientSelfTest {

    public enum SelfTestError: Error, CustomStringConvertible {
        case mismatch(String)
        public var description: String {
            switch self { case .mismatch(let s): return "transient self-test mismatch: \(s)" }
        }
    }

    // MARK: Synthesis (shared with XCTest)

    /// Wrap an interleaved Float32 mono/stereo signal into a program-mix
    /// `AudioPacket`, PTS placed at `startSample / sampleRate` (house time).
    /// The mono `signal` is duplicated to `channelCount` identical channels.
    public static func makeProgramPacket(signal: [Float],
                                         channelCount: Int = 2,
                                         sampleRate: Double = 48_000,
                                         startSample: Int) throws -> AudioPacket {
        let frames = signal.count
        var interleaved = [Float](repeating: 0, count: max(frames, 1) * channelCount)
        for f in 0..<frames {
            let v = signal[f]
            for c in 0..<channelCount { interleaved[f * channelCount + c] = v }
        }
        let fmt = try AudioSampleBufferFactory.interleavedFloatFormatDescription(
            sampleRate: sampleRate, channelCount: channelCount)
        let pts = CMTime(value: CMTimeValue(startSample), timescale: CMTimeScale(sampleRate.rounded()))
        let sb = try interleaved.withUnsafeBufferPointer { buf -> CMSampleBuffer in
            try AudioSampleBufferFactory.makeInterleavedSampleBuffer(
                samples: buf.baseAddress!, frameCount: frames, channelCount: channelCount,
                formatDescription: fmt, pts: pts)
        }
        return AudioPacket(sampleBuffer: sb, source: AudioMixer.masterSourceID)
    }

    // MARK: Edge-case packet builders (adversarial format coverage)

    /// A **non-interleaved** (planar) Float32 LPCM packet. The master-mix contract
    /// is interleaved; consumers must reject this rather than treat the first plane
    /// as if it held every channel. (Data is zero-filled — consumers reject on the
    /// ASBD flags before ever touching the samples.)
    public static func makeNonInterleavedFloatPacket(frames: Int,
                                                     channelCount: Int = 2,
                                                     sampleRate: Double = 48_000,
                                                     startSample: Int) throws -> AudioPacket {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,        // per-channel for non-interleaved
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0)
        let fmt = try formatDescription(for: &asbd)
        let bytes = [UInt8](repeating: 0, count: frames * channelCount * 4)
        let bb = try blockBuffer(bytes: bytes)
        let pts = CMTime(value: CMTimeValue(startSample), timescale: CMTimeScale(sampleRate.rounded()))
        let sb = try readySampleBuffer(blockBuffer: bb, format: fmt, frames: frames, pts: pts)
        return AudioPacket(sampleBuffer: sb, source: AudioMixer.masterSourceID)
    }

    /// A packed interleaved Float32 packet whose backing `CMBlockBuffer` is
    /// **discontiguous** (two chained memory segments), so the first contiguous run
    /// is shorter than the total — consumers must copy segment-safely, not memcpy
    /// past the first segment. `signal` is duplicated across channels.
    public static func makeDiscontiguousInterleavedPacket(signal: [Float],
                                                          channelCount: Int = 2,
                                                          sampleRate: Double = 48_000,
                                                          startSample: Int) throws -> AudioPacket {
        let frames = signal.count
        var interleaved = [Float](repeating: 0, count: max(frames, 1) * channelCount)
        for f in 0..<frames {
            let v = signal[f]
            for c in 0..<channelCount { interleaved[f * channelCount + c] = v }
        }
        let totalBytes = frames * channelCount * 4

        var bb: CMBlockBuffer?
        var st = CMBlockBufferCreateEmpty(allocator: kCFAllocatorDefault,
                                          capacity: 2, flags: 0, blockBufferOut: &bb)
        guard st == kCMBlockBufferNoErr, let bb else {
            throw SelfTestError.mismatch("CMBlockBufferCreateEmpty \(st)")
        }
        let firstLen = ((totalBytes / 2) / 4) * 4       // split on a Float boundary
        let secondLen = totalBytes - firstLen
        for len in [firstLen, secondLen] where len > 0 {
            st = CMBlockBufferAppendMemoryBlock(bb, memoryBlock: nil, length: len,
                                                blockAllocator: kCFAllocatorDefault,
                                                customBlockSource: nil, offsetToData: 0,
                                                dataLength: len, flags: kCMBlockBufferAssureMemoryNowFlag)
            guard st == kCMBlockBufferNoErr else {
                throw SelfTestError.mismatch("CMBlockBufferAppendMemoryBlock \(st)")
            }
        }
        st = interleaved.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb,
                                          offsetIntoDestination: 0, dataLength: totalBytes)
        }
        guard st == kCMBlockBufferNoErr else {
            throw SelfTestError.mismatch("CMBlockBufferReplaceDataBytes \(st)")
        }
        let fmt = try AudioSampleBufferFactory.interleavedFloatFormatDescription(
            sampleRate: sampleRate, channelCount: channelCount)
        let pts = CMTime(value: CMTimeValue(startSample), timescale: CMTimeScale(sampleRate.rounded()))
        let sb = try readySampleBuffer(blockBuffer: bb, format: fmt, frames: frames, pts: pts)
        return AudioPacket(sampleBuffer: sb, source: AudioMixer.masterSourceID)
    }

    /// A **padded** interleaved Float32 packet: `mBytesPerFrame` carries one extra
    /// Float of inter-frame padding and the packed flag is *not* set, so naive
    /// `stride == channels*4` indexing would mis-read. Consumers must reject it.
    public static func makePaddedInterleavedPacket(signal: [Float],
                                                   channelCount: Int = 2,
                                                   sampleRate: Double = 48_000,
                                                   startSample: Int) throws -> AudioPacket {
        let frames = signal.count
        let paddedBytesPerFrame = channelCount * 4 + 4   // one Float of padding/frame
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat,       // deliberately NOT packed
            mBytesPerPacket: UInt32(paddedBytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(paddedBytesPerFrame),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0)
        let fmt = try formatDescription(for: &asbd)
        var bytes = [UInt8](repeating: 0, count: frames * paddedBytesPerFrame)
        bytes.withUnsafeMutableBytes { rb in
            let base = rb.baseAddress!
            for f in 0..<frames {
                var v = signal[f]
                let frameBase = f * paddedBytesPerFrame
                for c in 0..<channelCount {
                    memcpy(base + frameBase + c * 4, &v, 4)
                }
            }
        }
        let bb = try blockBuffer(bytes: bytes)
        let pts = CMTime(value: CMTimeValue(startSample), timescale: CMTimeScale(sampleRate.rounded()))
        let sb = try readySampleBuffer(blockBuffer: bb, format: fmt, frames: frames, pts: pts)
        return AudioPacket(sampleBuffer: sb, source: AudioMixer.masterSourceID)
    }

    // MARK: CoreMedia plumbing for the edge-case builders

    private static func formatDescription(for asbd: inout AudioStreamBasicDescription) throws -> CMAudioFormatDescription {
        var fmt: CMAudioFormatDescription?
        let st = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                                layoutSize: 0, layout: nil, magicCookieSize: 0,
                                                magicCookie: nil, extensions: nil,
                                                formatDescriptionOut: &fmt)
        guard st == noErr, let fmt else {
            throw SelfTestError.mismatch("CMAudioFormatDescriptionCreate \(st)")
        }
        return fmt
    }

    private static func blockBuffer(bytes: [UInt8]) throws -> CMBlockBuffer {
        var bb: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bb)
        guard st == kCMBlockBufferNoErr, let bb else {
            throw SelfTestError.mismatch("CMBlockBufferCreateWithMemoryBlock \(st)")
        }
        st = bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb,
                                          offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard st == kCMBlockBufferNoErr else {
            throw SelfTestError.mismatch("CMBlockBufferReplaceDataBytes \(st)")
        }
        return bb
    }

    private static func readySampleBuffer(blockBuffer: CMBlockBuffer,
                                          format: CMAudioFormatDescription,
                                          frames: Int, pts: CMTime) throws -> CMSampleBuffer {
        var sb: CMSampleBuffer?
        let st = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
            sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil,
            sampleBufferOut: &sb)
        guard st == noErr, let sb else {
            throw SelfTestError.mismatch("CMAudioSampleBufferCreateReady \(st)")
        }
        return sb
    }

    /// Feed one contiguous signal to a detector in `packetFrames`-sized packets
    /// (mimicking the mixer tap), returning every transient it fired.
    public static func run(detector: TransientDetector,
                           signal: [Float],
                           channelCount: Int = 2,
                           sampleRate: Double = 48_000,
                           packetFrames: Int = 1024) throws -> [TransientInfo] {
        let box = FireBox()
        detector.onTransient = { info in box.append(info) }
        var idx = 0
        while idx < signal.count {
            let n = min(packetFrames, signal.count - idx)
            let slice = Array(signal[idx..<(idx + n)])
            let packet = try makeProgramPacket(signal: slice, channelCount: channelCount,
                                               sampleRate: sampleRate, startSample: idx)
            detector.process(packet)
            idx += n
        }
        detector.onTransient = nil
        return box.drain()
    }

    /// Thread-safe collector for fired transients.
    private final class FireBox: @unchecked Sendable {
        private let lock = NSLock()
        private var fires: [TransientInfo] = []
        func append(_ i: TransientInfo) { lock.lock(); fires.append(i); lock.unlock() }
        func drain() -> [TransientInfo] { lock.lock(); defer { lock.unlock() }; return fires }
    }

    // MARK: Signal builders

    /// Quiet bed (low-amplitude sine) with sharp Hann-windowed click bursts at
    /// the given sample positions/amplitudes.
    public static func bedWithClicks(totalSamples: Int,
                                     bedAmplitude: Float,
                                     clicks: [(sample: Int, amplitude: Float, width: Int)],
                                     sampleRate: Double = 48_000,
                                     bedFrequency: Double = 220) -> [Float] {
        var x = sine(count: totalSamples, amplitude: bedAmplitude,
                     frequency: bedFrequency, sampleRate: sampleRate)
        for click in clicks {
            let w = max(click.width, 1)
            for i in 0..<w {
                let idx = click.sample + i
                guard idx >= 0 && idx < totalSamples else { continue }
                // Hann-windowed high-frequency burst → a sharp, decaying transient.
                let win = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(w))
                let osc = sin(2.0 * Double.pi * 4_000.0 * Double(i) / sampleRate)
                x[idx] += Float(Double(click.amplitude) * win * osc)
            }
        }
        return x
    }

    public static func sine(count: Int, amplitude: Float, frequency: Double,
                            sampleRate: Double = 48_000) -> [Float] {
        var x = [Float](repeating: 0, count: count)
        let step = 2.0 * Double.pi * frequency / sampleRate
        var phase = 0.0
        for i in 0..<count {
            x[i] = Float(sin(phase) * Double(amplitude))
            phase += step
            if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }
        }
        return x
    }

    /// Deterministic pseudo-random noise (LCG), amplitude-scaled, in [-amp, amp].
    public static func noise(count: Int, amplitude: Float, seed: UInt64 = 0x1234_5678) -> [Float] {
        var x = [Float](repeating: 0, count: count)
        var state = seed
        for i in 0..<count {
            state = 6364136223846793005 &* state &+ 1442695040888963407
            let u = Float(state >> 40) / Float(1 << 24) // 0..1
            x[i] = (u * 2 - 1) * amplitude
        }
        return x
    }

    /// A slow linear amplitude swell of a tone from 0 → `peakAmplitude` over the
    /// whole span (no sharp onset).
    public static func swell(count: Int, peakAmplitude: Float, frequency: Double = 220,
                             sampleRate: Double = 48_000) -> [Float] {
        var x = sine(count: count, amplitude: 1, frequency: frequency, sampleRate: sampleRate)
        for i in 0..<count {
            let env = Float(i) / Float(max(count - 1, 1))
            x[i] *= env * peakAmplitude
        }
        return x
    }

    // MARK: Runnable checks

    public static func run() throws {
        try testClicks()
        try testSteadyToneNoiseSilence()
        try testDebounce()
        try testSwell()
        print("TransientSelfTest: all checks passed")
    }

    private static func testClicks() throws {
        let sr = 48_000.0
        let total = Int(sr) // 1 s
        let positions = [Int(0.15 * sr), Int(0.45 * sr), Int(0.75 * sr)]
        let signal = bedWithClicks(totalSamples: total, bedAmplitude: 0.02,
                                   clicks: [(positions[0], 0.9, 256),
                                            (positions[1], 0.5, 256),
                                            (positions[2], 0.3, 256)],
                                   sampleRate: sr)
        let det = TransientDetector(sampleRate: sr)
        let fires = try run(detector: det, signal: signal, sampleRate: sr)
        guard fires.count == 3 else {
            throw SelfTestError.mismatch("clicks: expected 3 fires, got \(fires.count) at \(fires.map { $0.hostSeconds })")
        }
        // Each fire within one block (~11 ms) of its click.
        let blockSec = 512.0 / sr
        for (f, p) in zip(fires, positions) {
            let expected = Double(p) / sr
            guard abs(f.hostSeconds - expected) <= 2 * blockSec else {
                throw SelfTestError.mismatch("click time \(f.hostSeconds) vs expected \(expected)")
            }
        }
        // Louder → stronger.
        guard fires[0].strength > fires[1].strength, fires[1].strength > fires[2].strength else {
            throw SelfTestError.mismatch("strength not monotonic: \(fires.map { $0.strength })")
        }
        print(String(format: "  ✓ 3 clicks → 3 fires @ %.3f/%.3f/%.3f s · strength %.2f/%.2f/%.2f",
                     fires[0].hostSeconds, fires[1].hostSeconds, fires[2].hostSeconds,
                     fires[0].strength, fires[1].strength, fires[2].strength))
    }

    private static func testSteadyToneNoiseSilence() throws {
        let sr = 48_000.0
        let total = Int(sr)
        for (name, signal) in [
            ("tone", sine(count: total, amplitude: 0.5, frequency: 440, sampleRate: sr)),
            ("noise", noise(count: total, amplitude: 0.3)),
            ("silence", [Float](repeating: 0, count: total)),
        ] {
            let det = TransientDetector(sampleRate: sr)
            let fires = try run(detector: det, signal: signal, sampleRate: sr)
            guard fires.isEmpty else {
                throw SelfTestError.mismatch("\(name): expected 0 fires, got \(fires.count)")
            }
            print("  ✓ steady \(name) → 0 fires")
        }
    }

    private static func testDebounce() throws {
        let sr = 48_000.0
        let total = Int(sr)
        // Two hits 40 ms apart with a 150 ms debounce → collapse to one.
        let signal = bedWithClicks(totalSamples: total, bedAmplitude: 0.02,
                                   clicks: [(Int(0.30 * sr), 0.8, 256),
                                            (Int(0.34 * sr), 0.8, 256)],
                                   sampleRate: sr)
        var cfg = TransientDetector.Configuration()
        cfg.minIntervalSeconds = 0.15
        let det = TransientDetector(sampleRate: sr, configuration: cfg)
        let fires = try run(detector: det, signal: signal, sampleRate: sr)
        guard fires.count == 1 else {
            throw SelfTestError.mismatch("debounce: expected 1 fire, got \(fires.count)")
        }
        print("  ✓ two hits within debounce → 1 fire")
    }

    private static func testSwell() throws {
        let sr = 48_000.0
        let total = Int(sr)
        let signal = swell(count: total, peakAmplitude: 0.8, frequency: 220, sampleRate: sr)
        let det = TransientDetector(sampleRate: sr)
        let fires = try run(detector: det, signal: signal, sampleRate: sr)
        guard fires.isEmpty else {
            throw SelfTestError.mismatch("swell: expected 0 fires, got \(fires.count)")
        }
        print("  ✓ slow swell → 0 fires (no sharp onset)")
    }
}
