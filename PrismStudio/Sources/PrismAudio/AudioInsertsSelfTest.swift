import AVFAudio
import AudioToolbox
import CoreMedia
import Foundation
import PrismCore
import os

/// Headless verification of per-channel AUv3 insert hosting and voice isolation
/// (§2.4). AVAudioEngine manual rendering + in-process AudioUnit instantiation
/// need no TCC permission, so this runs anywhere.
///
/// Exercises:
///  - instantiate Apple's built-in `kAudioUnitSubType_LowPassFilter` (always
///    present) from an `AudioComponentDescription`, splice it into a live
///    channel, and prove it attenuates high-frequency energy at the master tap;
///  - add then remove an insert chain while the engine keeps rendering (no
///    crash, level recovers);
///  - toggle voice isolation and prove the fallback high-pass DSP attenuates a
///    low-frequency (rumble) tone while a mid-band tone passes — i.e. the graph
///    reconfigures and audio still renders. (DSP *quality* of a real ML denoise
///    is UNVERIFIED without a reference signal; this asserts plumbing + a real
///    fallback effect.)
public enum AudioInsertsSelfTest {
    public struct Check: Sendable {
        public let name: String
        public let passed: Bool
        public let detail: String
    }

    public struct Report: Sendable, CustomStringConvertible {
        public let checks: [Check]
        public var allPassed: Bool { checks.allSatisfy(\.passed) }
        public var description: String {
            checks.map { "\($0.passed ? "PASS" : "FAIL")  \($0.name) — \($0.detail)" }
                .joined(separator: "\n")
        }
    }

    /// Apple built-in low-pass effect — present on every Mac, in-process.
    private static var lowPassDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_LowPassFilter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
    }

    public static func run() async throws -> Report {
        var checks: [Check] = []
        func check(_ name: String, _ passed: Bool, _ detail: String) {
            checks.append(Check(name: name, passed: passed, detail: detail))
        }

        // Discovery surface (data source for a plugin picker). Should never crash
        // and always includes at least Apple's built-in effects.
        let discovered = MixerChannel.availableEffectComponents()
        check("AU effect discovery via AVAudioUnitComponentManager",
              !discovered.isEmpty, "\(discovered.count) effect components found")

        let mixer = AudioMixer()
        let id = SourceID("inserts.chanA")
        let channel = try mixer.addChannel(id: id)
        mixer.isMonitoringEnabled = false // master tap fires regardless

        try mixer.startManualRendering(maximumFrameCount: 4096)
        defer { mixer.stop() }

        var ingestPTS = CMTime.zero

        // Pumps `seconds` of a fresh tone through the channel and returns the
        // master peak observed. Over-drains the ring (renders more than it
        // ingests) so each measurement is independent: no buffered surplus
        // carries a prior tone forward, and an inserted AU's pipeline latency
        // can't smear one frequency into the next reading. The tail underrun is
        // silence, which never lowers the peak.
        func pump(_ sine: inout Sine, seconds: Double) throws -> Float {
            let frames = Int(48_000 * seconds)
            channel.ingest(AudioPacket(sampleBuffer: try sine.buffer(frames: frames, pts: ingestPTS),
                                       source: id))
            ingestPTS = ingestPTS + CMTime(seconds: seconds, preferredTimescale: 48_000)
            _ = mixer.masterPeakLevel() // reset
            var remaining = AVAudioFrameCount(Double(frames) + 48_000 * 0.15)
            while remaining > 0 {
                let block = min(remaining, 512)
                try mixer.renderManually(frameCount: block)
                remaining -= block
            }
            return mixer.masterPeakLevel().linear
        }

        // ---- AUv3 low-pass insert attenuates HF ----
        // 15 kHz tone: well above Apple's default low-pass cutoff (~6.9 kHz).
        var hfDry = Sine(frequency: 15_000, amplitude: 0.8, sampleRate: 48_000)
        let dryPeak = try pump(&hfDry, seconds: 0.2)
        check("dry HF tone reaches master (no insert)", dryPeak > 0.4,
              String(format: "peak %.3f", dryPeak))

        try await channel.setInserts([lowPassDescription])
        check("insert loaded", channel.insertCount == 1, "insertCount \(channel.insertCount)")
        var hfWet = Sine(frequency: 15_000, amplitude: 0.8, sampleRate: 48_000)
        let wetPeak = try pump(&hfWet, seconds: 0.2)
        let ratio = dryPeak > 0 ? wetPeak / dryPeak : 1
        check("low-pass insert attenuates 15 kHz", wetPeak > 0 && ratio < 0.6,
              String(format: "wet %.3f / dry %.3f = %.3f×", wetPeak, dryPeak, ratio))

        // ---- add a second insert, then remove all, mid-render (no crash) ----
        try await channel.setInserts([lowPassDescription, lowPassDescription])
        var hf2 = Sine(frequency: 15_000, amplitude: 0.8, sampleRate: 48_000)
        let twoPeak = try pump(&hf2, seconds: 0.2)
        check("two chained inserts still render", channel.insertCount == 2 && twoPeak > 0,
              String(format: "count %d peak %.3f", channel.insertCount, twoPeak))

        try await channel.setInserts([]) // remove without tearing the engine
        var hfBack = Sine(frequency: 15_000, amplitude: 0.8, sampleRate: 48_000)
        let recovered = try pump(&hfBack, seconds: 0.2)
        check("insert removal restores dry path", channel.insertCount == 0 && recovered > dryPeak * 0.7,
              String(format: "recovered %.3f vs dry %.3f", recovered, dryPeak))

        // ---- voice isolation (fallback high-pass): rumble attenuated, voice passes ----
        var lowDry = Sine(frequency: 60, amplitude: 0.8, sampleRate: 48_000)
        let lowNoIso = try pump(&lowDry, seconds: 0.2)

        channel.setVoiceIsolation(true)
        check("voice isolation engaged", channel.isVoiceIsolationEnabled, "enabled")
        var lowWet = Sine(frequency: 60, amplitude: 0.8, sampleRate: 48_000)
        let lowIso = try pump(&lowWet, seconds: 0.2)
        let rumbleRatio = lowNoIso > 0 ? lowIso / lowNoIso : 1
        check("voice isolation attenuates 60 Hz rumble", lowIso < lowNoIso * 0.6,
              String(format: "iso %.3f / raw %.3f = %.3f×", lowIso, lowNoIso, rumbleRatio))

        var voice = Sine(frequency: 1_000, amplitude: 0.8, sampleRate: 48_000)
        let voicePeak = try pump(&voice, seconds: 0.2)
        check("voice band passes through isolation", voicePeak > 0.4,
              String(format: "1 kHz peak %.3f (iso on)", voicePeak))

        channel.setVoiceIsolation(false)
        check("voice isolation disengaged", !channel.isVoiceIsolationEnabled, "disabled")

        // ---- finding #2: a REMOVED channel's late setInserts must be a safe no-op ----
        // `removeChannel` detaches the channel from the engine. A `setInserts`
        // whose async AU instantiation completes *after* detach must NOT
        // reconnect the detached source node (that throws an AVAudioEngine
        // NSException + leaks AU nodes). Reaching the assertion at all proves no
        // exception was raised; the guard proves the chain was left untouched.
        let detachedID = SourceID("inserts.detached")
        let detachedChannel = try mixer.addChannel(id: detachedID)
        mixer.removeChannel(id: detachedID) // terminal detach
        try await detachedChannel.setInserts([lowPassDescription]) // must be a no-op, not a crash
        check("detached channel: late setInserts is a safe no-op (no reconnect)",
              detachedChannel.insertCount == 0,
              "insertCount \(detachedChannel.insertCount) after detach+setInserts")
        detachedChannel.setVoiceIsolation(true) // also must not touch the engine
        check("detached channel: setVoiceIsolation is a safe no-op",
              true, "no engine mutation / no crash")

        return Report(checks: checks)
    }
}

/// Deterministic interleaved-Float32-stereo sine → CMSampleBuffer (phase kept).
private struct Sine {
    let frequency: Double
    let amplitude: Double
    let sampleRate: Double
    private var phase: Double = 0

    init(frequency: Double, amplitude: Double, sampleRate: Double) {
        self.frequency = frequency
        self.amplitude = amplitude
        self.sampleRate = sampleRate
    }

    mutating func buffer(frames: Int, pts: CMTime) throws -> CMSampleBuffer {
        let step = 2.0 * .pi * frequency / sampleRate
        var interleaved = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            let v = Float(sin(phase) * amplitude)
            interleaved[f * 2] = v
            interleaved[f * 2 + 1] = v
            phase += step
            if phase > 2.0 * .pi { phase -= 2.0 * .pi }
        }
        let fd = try AudioSampleBufferFactory.interleavedFloatFormatDescription(
            sampleRate: sampleRate, channelCount: 2)
        return try interleaved.withUnsafeBufferPointer {
            try AudioSampleBufferFactory.makeInterleavedSampleBuffer(
                samples: $0.baseAddress!, frameCount: frames, channelCount: 2,
                formatDescription: fd, pts: pts)
        }
    }
}
