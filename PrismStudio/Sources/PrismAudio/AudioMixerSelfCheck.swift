import AVFAudio
import CoreMedia
import Foundation
import PrismCore
import os

/// Headless verification of the mixer graph — AVAudioEngine manual rendering,
/// zero audio hardware, zero TCC. Exercises: ingest (CMSampleBuffer →
/// converter → ring), the source-node render path, gain/mute/solo, per-channel
/// + master metering, the master tap (interleaved CMSampleBuffers, monotonic
/// PTS), and the ring buffer's drop-oldest/underrun policy.
public enum AudioMixerSelfCheck {
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

    public static func run() throws -> Report {
        var checks: [Check] = []
        func check(_ name: String, _ passed: Bool, _ detail: String) {
            checks.append(Check(name: name, passed: passed, detail: detail))
        }

        // ---- Ring buffer policy (pure logic) ----
        do {
            let ring = PCMRingBuffer(channelCount: 2, capacityFrames: 100)
            let frames = [Float](repeating: 0.25, count: 150 * 2) // interleaved, > capacity
            frames.withUnsafeBufferPointer {
                ring.write(interleaved: $0.baseAddress!, sourceChannelCount: 2, frameCount: 150)
            }
            check("ring drop-oldest", ring.bufferedFrames == 100 && ring.stats.dropped == 50,
                  "buffered \(ring.bufferedFrames)/100, dropped \(ring.stats.dropped)")

            var ablBacking = [Float](repeating: -1, count: 120 * 2)
            let got: Int = ablBacking.withUnsafeMutableBufferPointer { buf in
                var abl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 2,
                                          mDataByteSize: UInt32(120 * 2 * 4),
                                          mData: UnsafeMutableRawPointer(buf.baseAddress!))
                )
                return ring.read(into: &abl, frameCount: 120)
            }
            let tailIsSilent = ablBacking[(100 * 2)...].allSatisfy { $0 == 0 }
            let headIsData = ablBacking[..<(100 * 2)].allSatisfy { $0 == 0.25 }
            check("ring underrun-fills-silence",
                  got == 100 && tailIsSilent && headIsData && ring.stats.underruns == 20,
                  "read \(got)/120 real frames, tail silent: \(tailIsSilent), underruns \(ring.stats.underruns)")
        }

        // ---- Mixer graph, manual rendering ----
        let mixer = AudioMixer()
        let idA = SourceID("selfcheck.sineA") // 440 Hz, float32 interleaved 48 kHz stereo
        let idB = SourceID("selfcheck.sineB") // 1 kHz, int16 mono 44.1 kHz (converter + resample + upmix)
        let channelA = try mixer.addChannel(id: idA)
        let channelB = try mixer.addChannel(id: idB)

        let collected = OSAllocatedUnfairLock<[CMTime]>(initialState: [])
        let interleavedOK = OSAllocatedUnfairLock<Bool>(initialState: true)
        mixer.onMasterMix = { packet in
            collected.withLock { $0.append(packet.pts) }
            if let fd = CMSampleBufferGetFormatDescription(packet.sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
                let interleaved = asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
                if !interleaved || asbd.pointee.mChannelsPerFrame != 2 {
                    interleavedOK.withLock { $0 = false }
                }
            }
        }

        try mixer.startManualRendering(maximumFrameCount: 4096)
        defer { mixer.stop() }

        var phaseA = SineFeeder(frequency: 440, amplitude: 0.8, sampleRate: 48_000)
        var phaseB = SineFeeder(frequency: 1_000, amplitude: 0.5, sampleRate: 44_100)
        var ingestPTS = CMTime.zero

        // Feed ~`seconds` of audio to both channels, then render it through the graph.
        func pump(seconds: Double) throws {
            let framesA = Int(48_000 * seconds)
            let framesB = Int(44_100 * seconds)
            channelA.ingest(AudioPacket(
                sampleBuffer: try phaseA.makeFloatStereoBuffer(frameCount: framesA, pts: ingestPTS),
                source: idA))
            channelB.ingest(AudioPacket(
                sampleBuffer: try phaseB.makeInt16MonoBuffer(frameCount: framesB, pts: ingestPTS),
                source: idB))
            ingestPTS = ingestPTS + CMTime(seconds: seconds, preferredTimescale: 48_000)
            var remaining = AVAudioFrameCount(48_000 * seconds * 0.9) // leave headroom in the rings
            while remaining > 0 {
                let block = min(remaining, 512)
                try mixer.renderManually(frameCount: block)
                remaining -= block
            }
        }

        func resetMeters() {
            _ = channelA.peakLevel(); _ = channelB.peakLevel(); _ = mixer.masterPeakLevel()
        }

        // Phase 1: both channels live at unity.
        try pump(seconds: 0.2)
        let peakA1 = channelA.peakLevel(), peakB1 = channelB.peakLevel()
        let master1 = mixer.masterPeakLevel()
        check("both channels audible",
              peakA1.linear > 0.5 && peakB1.linear > 0.2 && master1.linear > 0.5,
              "A \(peakA1), B \(peakB1), master \(master1)")
        check("channel A near source amplitude", abs(peakA1.linear - 0.8) < 0.1,
              "peak \(peakA1.linear) vs 0.8")
        check("converter path (44.1k int16 mono → 48k float stereo) produced audio",
              abs(peakB1.linear - 0.5) < 0.1, "peak \(peakB1.linear) vs 0.5")

        // Phase 2: mute A — A meters silent, master still carries B.
        channelA.isMuted = true
        resetMeters()
        try pump(seconds: 0.1)
        let peakA2 = channelA.peakLevel(), master2 = mixer.masterPeakLevel()
        check("mute silences channel", peakA2.linear == 0 && master2.linear > 0.2,
              "A \(peakA2), master \(master2)")

        // Phase 3: solo B — A (unmuted) is silenced by B's solo.
        channelA.isMuted = false
        channelB.isSolo = true
        resetMeters()
        try pump(seconds: 0.1)
        let peakA3 = channelA.peakLevel(), peakB3 = channelB.peakLevel()
        check("solo silences non-soloed channels", peakA3.linear == 0 && peakB3.linear > 0.2,
              "A \(peakA3), B \(peakB3)")

        // Phase 4: clear solo, gain 0.5 on A, mute B — post-fader meter halves.
        channelB.isSolo = false
        channelB.isMuted = true
        channelA.gain = 0.5
        resetMeters()
        try pump(seconds: 0.1)
        let peakA4 = channelA.peakLevel()
        check("gain applied post-fader", abs(peakA4.linear - 0.4) < 0.06,
              "peak \(peakA4.linear) vs 0.8 × 0.5")

        // Master tap delivery + PTS monotonicity.
        let ptsList = collected.withLock { $0 }
        let monotonic = zip(ptsList, ptsList.dropFirst()).allSatisfy { CMTimeCompare($0, $1) < 0 }
        check("master tap delivered packets", !ptsList.isEmpty, "\(ptsList.count) packets")
        check("master tap PTS strictly monotonic", monotonic && !ptsList.isEmpty,
              "first \(ptsList.first?.seconds ?? -1)s … last \(ptsList.last?.seconds ?? -1)s")
        check("master tap format interleaved stereo", interleavedOK.withLock { $0 }, "asbd flags verified")

        return Report(checks: checks)
    }
}

/// Deterministic sine generator that mints CMSampleBuffers (keeps phase across calls).
private struct SineFeeder {
    let frequency: Double
    let amplitude: Double
    let sampleRate: Double
    private var phase: Double = 0

    init(frequency: Double, amplitude: Double, sampleRate: Double) {
        self.frequency = frequency
        self.amplitude = amplitude
        self.sampleRate = sampleRate
    }

    private mutating func nextSamples(_ count: Int) -> [Float] {
        let step = 2.0 * .pi * frequency / sampleRate
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            out[i] = Float(sin(phase) * amplitude)
            phase += step
            if phase > 2.0 * .pi { phase -= 2.0 * .pi }
        }
        return out
    }

    /// Interleaved Float32 stereo (same signal both channels).
    mutating func makeFloatStereoBuffer(frameCount: Int, pts: CMTime) throws -> CMSampleBuffer {
        let mono = nextSamples(frameCount)
        var interleaved = [Float](repeating: 0, count: frameCount * 2)
        for f in 0..<frameCount {
            interleaved[f * 2] = mono[f]
            interleaved[f * 2 + 1] = mono[f]
        }
        let fd = try AudioSampleBufferFactory.interleavedFloatFormatDescription(
            sampleRate: sampleRate, channelCount: 2)
        return try interleaved.withUnsafeBufferPointer {
            try AudioSampleBufferFactory.makeInterleavedSampleBuffer(
                samples: $0.baseAddress!, frameCount: frameCount, channelCount: 2,
                formatDescription: fd, pts: pts)
        }
    }

    /// Packed Int16 mono — exercises the AVAudioConverter path.
    mutating func makeInt16MonoBuffer(frameCount: Int, pts: CMTime) throws -> CMSampleBuffer {
        let mono = nextSamples(frameCount)
        var int16 = [Int16](repeating: 0, count: frameCount)
        for f in 0..<frameCount { int16[f] = Int16(max(-1, min(1, mono[f])) * 32767) }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var fd: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        guard status == noErr, let fd else {
            throw PrismAudioError.osStatus(operation: "CMAudioFormatDescriptionCreate(int16)", status: status)
        }

        let byteCount = frameCount * 2
        var blockBuffer: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw PrismAudioError.osStatus(operation: "CMBlockBufferCreateWithMemoryBlock", status: status)
        }
        status = int16.withUnsafeBufferPointer {
            CMBlockBufferReplaceDataBytes(with: UnsafeRawPointer($0.baseAddress!),
                                          blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == kCMBlockBufferNoErr else {
            throw PrismAudioError.osStatus(operation: "CMBlockBufferReplaceDataBytes", status: status)
        }

        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: fd,
            sampleCount: frameCount, presentationTimeStamp: pts, packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else {
            throw PrismAudioError.osStatus(operation: "CMAudioSampleBufferCreateReady(int16)", status: status)
        }
        return sampleBuffer
    }
}
