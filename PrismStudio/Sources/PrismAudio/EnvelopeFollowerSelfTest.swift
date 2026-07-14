import CoreMedia
import Foundation
import PrismCore

/// Headless, deterministic verification of `AudioEnvelopeFollower` — no audio
/// hardware, no TCC, no real time. Synthesises silence / loud tone / burst-then-
/// silence signals and asserts the mouth-openness signal behaves: silence ≈ 0,
/// loud → high, a quiet bed under the floor stays ≈ 0, attack is faster than
/// release, and the output is continuous (slew-limited, no per-block jump to full).
///
/// The synthesis + trace helpers are `public` so `AudioEnvelopeFollowerTests`
/// (XCTest) can build identical signals and measure the same rise/fall times.
public enum EnvelopeFollowerSelfTest {

    public enum SelfTestError: Error, CustomStringConvertible {
        case mismatch(String)
        public var description: String {
            switch self { case .mismatch(let s): return "envelope self-test mismatch: \(s)" }
        }
    }

    // MARK: Signal builders

    /// A steady sine of the given amplitude.
    public static func sine(count: Int, amplitude: Float, frequency: Double = 220,
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

    /// `silence` samples of 0, then a loud sustained tone of `burstAmplitude`.
    /// (Used to measure attack: how fast openness rises once the tone starts.)
    public static func onset(silence: Int, burst: Int, burstAmplitude: Float,
                             frequency: Double = 220, sampleRate: Double = 48_000) -> [Float] {
        var x = [Float](repeating: 0, count: silence)
        x.append(contentsOf: sine(count: burst, amplitude: burstAmplitude,
                                  frequency: frequency, sampleRate: sampleRate))
        return x
    }

    // MARK: Runner

    /// Feed one contiguous signal to a follower in `packetFrames`-sized packets
    /// (mimicking the mixer tap), returning the per-block openness trace.
    public static func trace(follower: AudioEnvelopeFollower,
                             signal: [Float],
                             channelCount: Int = 2,
                             sampleRate: Double = 48_000,
                             packetFrames: Int = 1024) throws -> [Double] {
        let box = TraceBox()
        follower.onEnvelope = { box.append($0) }
        var idx = 0
        while idx < signal.count {
            let n = min(packetFrames, signal.count - idx)
            let slice = Array(signal[idx..<(idx + n)])
            let packet = try makeProgramPacket(signal: slice, channelCount: channelCount,
                                               sampleRate: sampleRate, startSample: idx)
            follower.process(packet)
            idx += n
        }
        follower.onEnvelope = nil
        return box.drain()
    }

    /// Wrap an interleaved mono signal into a program-mix `AudioPacket` (mono
    /// duplicated across `channelCount` identical channels), house-time PTS.
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

    /// Thread-safe collector for the openness trace.
    private final class TraceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        func append(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
        func drain() -> [Double] { lock.lock(); defer { lock.unlock() }; return values }
    }

    // MARK: Measurement helpers

    /// Blocks-until index reaches `fraction` of `steady` on a rising trace, ×
    /// `blockSeconds` → rise time in seconds. Returns nil if never reached.
    public static func riseTime(_ trace: [Double], steady: Double, fraction: Double,
                                blockSeconds: Double) -> Double? {
        let threshold = steady * fraction
        for (i, v) in trace.enumerated() where v >= threshold { return Double(i) * blockSeconds }
        return nil
    }

    /// From the peak, blocks-until the trace falls to `fraction` of `peak`, ×
    /// `blockSeconds` → fall time in seconds. Returns nil if never reached.
    public static func fallTime(_ trace: [Double], from peakIndex: Int, peak: Double,
                                fraction: Double, blockSeconds: Double) -> Double? {
        let threshold = peak * fraction
        var i = peakIndex
        while i < trace.count {
            if trace[i] <= threshold { return Double(i - peakIndex) * blockSeconds }
            i += 1
        }
        return nil
    }

    // MARK: Runnable checks

    public static func run() throws {
        let sr = 48_000.0
        let blockSec = 512.0 / sr

        // 1. Silence → openness ≈ 0.
        do {
            let f = AudioEnvelopeFollower(sampleRate: sr)
            let tr = try trace(follower: f, signal: [Float](repeating: 0, count: Int(sr)), sampleRate: sr)
            let maxV = tr.max() ?? 0
            guard maxV < 1e-4 else { throw SelfTestError.mismatch("silence openness \(maxV) not ≈ 0") }
            guard f.openness < 1e-4 else { throw SelfTestError.mismatch("silence polled openness not ≈ 0") }
            print(String(format: "  ✓ silence → openness ≈ %.5f (closed)", maxV))
        }

        // 2. Quiet bed under the floor → openness ≈ 0 (gate works).
        do {
            let f = AudioEnvelopeFollower(sampleRate: sr)  // noiseFloor 0.010
            let bed = sine(count: Int(sr), amplitude: 0.008, sampleRate: sr) // rms ≈ 0.0057 < floor
            let tr = try trace(follower: f, signal: bed, sampleRate: sr)
            let maxV = tr.max() ?? 0
            guard maxV < 1e-3 else { throw SelfTestError.mismatch("quiet bed openness \(maxV) not gated") }
            print(String(format: "  ✓ quiet bed under floor → openness ≈ %.5f (gated)", maxV))
        }

        // 3. Loud sustained tone → openness rises toward ~1 and stays high.
        do {
            let f = AudioEnvelopeFollower(sampleRate: sr)
            let tone = sine(count: Int(sr), amplitude: 0.7, sampleRate: sr) // rms ≈ 0.495
            let tr = try trace(follower: f, signal: tone, sampleRate: sr)
            let steady = tr.suffix(20).reduce(0, +) / 20.0
            guard steady > 0.9 else { throw SelfTestError.mismatch("loud tone steady \(steady) not high") }
            print(String(format: "  ✓ loud tone → openness steady ≈ %.3f (open)", steady))
        }

        // 4. Attack faster than release + continuity.
        do {
            let f = AudioEnvelopeFollower(sampleRate: sr)
            // 100 ms silence, 300 ms loud burst, 400 ms silence.
            let sig = onset(silence: Int(0.10 * sr), burst: Int(0.30 * sr),
                            burstAmplitude: 0.7, sampleRate: sr)
                + [Float](repeating: 0, count: Int(0.40 * sr))
            let tr = try trace(follower: f, signal: sig, sampleRate: sr)

            // Peak + steady during the burst.
            let peak = tr.max() ?? 0
            let peakIdx = tr.firstIndex(of: peak) ?? 0
            // Rise time: from block 0 of the trace, but onset starts ~100ms in;
            // measure rise relative to the onset block.
            let onsetBlock = Int((0.10 * sr) / 512.0)
            let burstTrace = Array(tr[onsetBlock...])
            let rise = riseTime(burstTrace, steady: peak, fraction: 0.9, blockSeconds: blockSec) ?? .infinity
            let fall = fallTime(tr, from: peakIdx, peak: peak, fraction: 0.1, blockSeconds: blockSec) ?? .infinity
            guard rise < fall else {
                throw SelfTestError.mismatch("attack \(rise)s not faster than release \(fall)s")
            }
            // Continuity: no single block leaps more than ~half the full range.
            var maxStep = 0.0
            for i in 1..<tr.count { maxStep = max(maxStep, abs(tr[i] - tr[i-1])) }
            guard maxStep < 0.5 else {
                throw SelfTestError.mismatch("openness jumped \(maxStep) in one block (not slewed)")
            }
            print(String(format: "  ✓ attack %.3fs < release %.3fs · max per-block step %.3f (continuous)",
                         rise, fall, maxStep))
        }

        print("EnvelopeFollowerSelfTest: all checks passed")
    }
}
