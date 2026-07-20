import AVFAudio
import CoreMedia
import Foundation
import PrismAudio
import PrismCore
import os

/// Soft peak limiter for the per-engine polyphonic submix (A10). Summed voices
/// can overshoot 1.0 (measured 1.53 / 1.80); a hard clip there would buzz. Below
/// the knee the signal is untouched; above it a `tanh` knee asymptotes toward
/// ~1.0, taming sums while barely touching a single normalized hit.
@inline(__always) func softLimit(_ x: Float) -> Float {
    let knee: Float = 0.9
    if x > knee { return knee + (1 - knee) * tanhf((x - knee) / (1 - knee)) }
    if x < -knee { return -knee - (1 - knee) * tanhf((-x - knee) / (1 - knee)) }
    return x
}

/// Mints **deinterleaved** Float32 `CMSampleBuffer`s (house-time PTS) from an
/// `AVAudioPCMBuffer` so playback can be `ingest`ed into an `AudioMixer` channel
/// — mirroring how every other Prism source feeds the mixer.
///
/// A9: the packet's format is non-interleaved 48 kHz stereo float, matching the
/// mixer's `internalFormat`, so `MixerChannel.ingest` takes the no-converter
/// fast path instead of spinning up an `AVAudioConverter` every block.
/// A10: samples pass through `softLimit` on the way out (submix peak limiter).
final class AudioPacketMinter {
    private let sourceID: SourceID
    private let formatDescription: CMAudioFormatDescription
    private let channelCount: Int
    private var scratch: [Float] = []   // planar: [ch0 frames…][ch1 frames…]

    init(sourceID: SourceID, sampleRate: Double, channelCount: Int) throws {
        self.sourceID = sourceID
        self.channelCount = channelCount
        // Non-interleaved (planar) packed float: mBytesPerFrame/Packet describe a
        // single channel (4 bytes); the block holds channels back-to-back.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32, mReserved: 0)
        var fd: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        guard status == noErr, let fd else {
            throw PrismAudioError.osStatus(operation: "CMAudioFormatDescriptionCreate(sound)", status: status)
        }
        self.formatDescription = fd
    }

    /// Build a packet from a deinterleaved float buffer. `pts` in house time.
    func packet(from buffer: AVAudioPCMBuffer, pts: CMTime) -> AudioPacket? {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let src = buffer.floatChannelData else { return nil }
        let ch = min(channelCount, Int(buffer.format.channelCount))
        if scratch.count < frames * channelCount { scratch = [Float](repeating: 0, count: frames * channelCount) }
        // Planar layout (all of ch0, then all of ch1) + submix soft limiter (A10).
        for c in 0..<channelCount {
            let srcC = src[min(c, ch - 1)]
            let dstBase = c * frames
            for f in 0..<frames { scratch[dstBase + f] = softLimit(srcC[f]) }
        }
        return scratch.withUnsafeBufferPointer { buf -> AudioPacket? in
            guard let sb = try? Self.make(samples: buf.baseAddress!, frames: frames,
                                          channels: channelCount, fd: formatDescription, pts: pts)
            else { return nil }
            return AudioPacket(sampleBuffer: sb, source: sourceID)
        }
    }

    private static func make(samples: UnsafePointer<Float>, frames: Int, channels: Int,
                             fd: CMAudioFormatDescription, pts: CMTime) throws -> CMSampleBuffer {
        let byteCount = frames * channels * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else {
            throw PrismAudioError.osStatus(operation: "CMBlockBufferCreate(sound)", status: status)
        }
        status = CMBlockBufferReplaceDataBytes(with: UnsafeRawPointer(samples), blockBuffer: block,
                                               offsetIntoDestination: 0, dataLength: byteCount)
        guard status == kCMBlockBufferNoErr else {
            throw PrismAudioError.osStatus(operation: "CMBlockBufferReplace(sound)", status: status)
        }
        var sb: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fd,
            sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb)
        guard status == noErr, let sb else {
            throw PrismAudioError.osStatus(operation: "CMAudioSampleBufferCreateReady(sound)", status: status)
        }
        return sb
    }
}

/// Testable core of the live tap drain (A3/A4). Given each drained block's peak
/// and frame count it decides whether to ingest the block and, if so, the
/// PTS sample-offset to stamp. Silent idle blocks are skipped but still advance
/// house time, so the next real block aligns with the program mix without
/// queueing the skipped PCM. Pure value type ⇒ unit-testable without hardware.
struct LiveDrainClock {
    private(set) var elapsedFrames: Int64 = 0
    let silenceFloor: Float
    init(silenceFloor: Float) { self.silenceFloor = silenceFloor }

    /// Returns the house-timeline sample offset for a block to ingest, or nil
    /// for silence. Every valid block advances time even when its PCM is skipped.
    mutating func admit(peak: Float, frames: Int) -> Int64? {
        guard frames > 0 else { return nil }
        let offset = elapsedFrames
        elapsedFrames += Int64(frames)
        return peak > silenceFloor ? offset : nil
    }
}

/// A small `AVAudioEngine` hosting a pool of `AVAudioPlayerNode` voices whose
/// mixed output is tapped and forwarded (as `AudioPacket`s) into a single
/// `AudioMixer` channel. This is the shared substrate under `Soundboard`,
/// `BeatSequencer` and `MusicBed`: triggered audio lands in the program mix, so
/// it records / streams / ducks / meters for free.
///
/// Two run modes mirror `AudioMixer`: `startLive()` (real-time, output device)
/// and `startManual()` + `render(frameCount:)` (headless, no hardware/TCC).
public final class SamplePlaybackEngine: @unchecked Sendable {
    /// Internal format: 48 kHz stereo float, matching the `AudioMixer`'s bus.
    public static let internalFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    public let sourceID: SourceID
    private let engine = AVAudioEngine()
    private let submix = AVAudioMixerNode()
    private let voices: [AVAudioPlayerNode]
    private let minter: AudioPacketMinter
    private let log = EngineLog.logger("sound.engine")

    /// The mixer channel that receives this engine's output (set by the owner).
    public var sinkChannel: MixerChannel?

    private let nextVoice = OSAllocatedUnfairLock(initialState: 0)
    private var running = false
    private var manualMode = false
    private var manualBuffer: AVAudioPCMBuffer?
    private var sampleTime: Int64 = 0
    private let base = HouseClock.now()

    // A3: live-tap → worker handoff. The RT tap callback ONLY memcpys the
    // engine-format Float32 block into this preallocated ring (no minting, no
    // ingest, no CMSampleBuffer allocation on the audio thread). A worker timer
    // drains the ring off-thread, mints the packet, and ingests it.
    private var tapRing: PCMRingBuffer?
    private var tapWorker: DispatchSourceTimer?
    private let tapWorkerQueue = DispatchQueue(label: "sound.engine.tapworker", qos: .userInitiated)
    private var drainBuffer: AVAudioPCMBuffer?
    private var liveBase: CMTime = .zero
    private var liveClock = LiveDrainClock(silenceFloor: liveSilenceFloor)
    /// A4: below this block peak a live idle block is dropped instead of ingested,
    /// so 0.5 s of silence never queues ahead of the first real trigger.
    static let liveSilenceFloor: Float = 1e-4

    public init(sourceID: SourceID, voiceCount: Int = 16) throws {
        self.sourceID = sourceID
        self.minter = try AudioPacketMinter(sourceID: sourceID, sampleRate: 48_000, channelCount: 2)
        var v: [AVAudioPlayerNode] = []
        for _ in 0..<max(1, voiceCount) { v.append(AVAudioPlayerNode()) }
        self.voices = v

        engine.attach(submix)
        for node in voices {
            engine.attach(node)
            engine.connect(node, to: submix, format: Self.internalFormat)
        }
        engine.connect(submix, to: engine.mainMixerNode, format: Self.internalFormat)
    }

    /// Convert an arbitrary decoded buffer to this engine's play format so any
    /// voice can play any sound (uniform format = safe polyphony).
    public func normalized(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == Self.internalFormat { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: Self.internalFormat) else { return nil }
        let ratio = Self.internalFormat.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.internalFormat, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true; outStatus.pointee = .haveData; return buffer
        }
        guard status != .error else { log.error("normalize failed: \(String(describing: err))"); return nil }
        return out
    }

    /// Decode a sound file to an engine-format (`internalFormat`) buffer. Off
    /// the RT path — call at load/preload time, never on trigger.
    public func loadFile(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw PrismAudioError.invalidState("empty/unallocatable buffer for \(url.lastPathComponent)")
        }
        try file.read(into: raw)
        guard let norm = normalized(raw) else {
            throw PrismAudioError.badFormat("conversion failed for \(url.lastPathComponent)")
        }
        return norm
    }

    // MARK: Lifecycle

    /// Live-mode delivery (A3): a real-time tap on the submix does the minimum —
    /// copy the engine-format block into a preallocated SPSC ring — then a worker
    /// drains it, mints packets and ingests them off the audio thread. (Manual
    /// mode pushes the rendered block directly in `render(frameCount:)`.)
    private func installTap() {
        let ring = PCMRingBuffer(channelCount: 2, capacityFrames: 24_000) // 0.5 s @ 48 kHz
        tapRing = ring
        // The tap closure captures only `ring` (no `self`) so the audio thread
        // takes no transient retain and never touches engine state — just the
        // ring's bounded lock+memcpy (the same RT trade the mixer already makes).
        submix.installTap(onBus: 0, bufferSize: 1024, format: Self.internalFormat) { buf, _ in
            guard let ch = buf.floatChannelData, buf.frameLength > 0 else { return }
            ring.write(deinterleaved: ch,
                       sourceChannelCount: Int(buf.format.channelCount),
                       frameCount: Int(buf.frameLength))
        }
    }

    /// Off-RT worker: drain whatever the tap has buffered, skip silent idle
    /// blocks (A4), mint a deinterleaved packet (A9) and ingest it.
    private func startTapWorker() {
        guard let ring = tapRing else { return }
        let drain = AVAudioPCMBuffer(pcmFormat: Self.internalFormat, frameCapacity: 4096)!
        drainBuffer = drain
        let t = DispatchSource.makeTimerSource(queue: tapWorkerQueue)
        t.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.drainTap(ring: ring, into: drain) }
        tapWorker = t
        t.resume()
    }

    private func drainTap(ring: PCMRingBuffer, into drain: AVAudioPCMBuffer) {
        let cap = Int(drain.frameCapacity)
        let channels = Int(drain.format.channelCount)
        while true {
            let available = ring.bufferedFrames
            guard available > 0 else { break }
            let n = min(available, cap)
            drain.frameLength = AVAudioFrameCount(n)
            _ = ring.read(into: drain.mutableAudioBufferList, frameCount: n)
            guard let data = drain.floatChannelData else { break }

            // A4: drop fully-silent idle blocks. LiveDrainClock still advances
            // their house-time span, so the first hit aligns without queued PCM.
            var peak: Float = 0
            outer: for c in 0..<channels {
                for f in 0..<n { let a = abs(data[c][f]); if a > peak { peak = a; if peak > Self.liveSilenceFloor { break outer } } }
            }
            guard let offset = liveClock.admit(peak: peak, frames: n) else { continue }
            let pts = CMTimeAdd(liveBase, CMTime(value: offset, timescale: 48_000))
            if let pkt = minter.packet(from: drain, pts: pts) { sinkChannel?.ingest(pkt) }
        }
    }

    public func startLive() throws {
        guard !running else { return }
        manualMode = false
        liveBase = HouseClock.now()
        liveClock = LiveDrainClock(silenceFloor: Self.liveSilenceFloor)
        engine.mainMixerNode.outputVolume = 0 // silent to hardware; audio flows only via the tap → program mixer
        installTap()
        engine.prepare()
        try engine.start()
        for node in voices { node.play() }
        startTapWorker()
        running = true
        log.info("sound engine live (\(self.sourceID.raw, privacy: .public))")
    }

    public func startManual(maximumFrameCount: AVAudioFrameCount = 4096) throws {
        guard !running else { return }
        manualMode = true
        sampleTime = 0
        engine.mainMixerNode.outputVolume = 1 // manual output goes only to the offline buffer (no hardware)
        try engine.enableManualRenderingMode(.offline, format: Self.internalFormat,
                                             maximumFrameCount: maximumFrameCount)
        try engine.start()
        for node in voices { node.play() }
        manualBuffer = AVAudioPCMBuffer(pcmFormat: Self.internalFormat, frameCapacity: maximumFrameCount)
        running = true
    }

    /// Pull one block in manual mode; the rendered audio is minted and ingested
    /// into the sink channel synchronously (zero latency, no underruns).
    @discardableResult
    public func render(frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard running, manualMode, let out = manualBuffer, frameCount <= out.frameCapacity else {
            throw PrismAudioError.invalidState("render outside manual mode / frameCount too large")
        }
        let status = try engine.renderOffline(frameCount, to: out)
        guard status == .success else {
            throw PrismAudioError.invalidState("renderOffline: \(String(describing: status))")
        }
        let pts = CMTimeAdd(base, CMTime(value: sampleTime, timescale: 48_000))
        sampleTime += Int64(out.frameLength)
        if let pkt = minter.packet(from: out, pts: pts) { sinkChannel?.ingest(pkt) }
        return out
    }

    public func stop() {
        guard running else { return }
        for node in voices where node.isPlaying { node.stop() }
        if !manualMode {
            tapWorker?.cancel(); tapWorker = nil
            submix.removeTap(onBus: 0)
            tapWorkerQueue.sync {}   // let any in-flight drain finish before dropping the ring
            tapRing = nil
            drainBuffer = nil
        }
        engine.stop()
        if manualMode { engine.disableManualRenderingMode(); manualMode = false }
        running = false
    }

    // MARK: Playback

    /// Trigger `buffer` on the next voice (round-robin polyphony). Voices are
    /// always running; `.interrupts` makes the scheduled buffer start
    /// immediately (standard sampler-voice pattern). `loop` = gapless looping.
    public func play(_ buffer: AVAudioPCMBuffer, loop: Bool = false, volume: Float = 1.0) {
        guard running else { return }
        let idx = nextVoice.withLock { v -> Int in let cur = v; v = (v + 1) % voices.count; return cur }
        play(buffer, onVoice: idx, loop: loop, volume: volume)
    }

    /// Trigger on the next round-robin voice, scheduled at an exact `when`
    /// (`nil` = as soon as possible). The BeatSequencer's live scheduler passes a
    /// host-time `AVAudioTime` so the hit lands on the exact sample regardless of
    /// timer jitter (A5). For a future `when` we must NOT stop the node first —
    /// stopping resets its render clock and would drop the queued schedule.
    public func play(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime?, loop: Bool = false, volume: Float = 1.0) {
        guard running else { return }
        let idx = nextVoice.withLock { v -> Int in let cur = v; v = (v + 1) % voices.count; return cur }
        guard idx >= 0, idx < voices.count else { return }
        let node = voices[idx]
        node.volume = max(0, min(1, volume))
        if when == nil {
            if node.isPlaying { node.stop() }
            node.scheduleBuffer(buffer, at: nil, options: loop ? .loops : [], completionHandler: nil)
            node.play()
        } else {
            node.scheduleBuffer(buffer, at: when, options: loop ? .loops : [], completionHandler: nil)
            if !node.isPlaying { node.play() }
        }
    }

    /// Schedule on a specific voice index (used by MusicBed crossfades).
    public func play(_ buffer: AVAudioPCMBuffer, onVoice idx: Int, loop: Bool, volume: Float) {
        guard running, idx >= 0, idx < voices.count else { return }
        let node = voices[idx]
        node.volume = max(0, min(1, volume))
        if node.isPlaying { node.stop() }
        node.scheduleBuffer(buffer, at: nil, options: loop ? .loops : [], completionHandler: nil)
        node.play()
    }

    /// Ramp a specific voice's volume (linear) — MusicBed crossfade/volume.
    public func setVoiceVolume(_ v: Float, onVoice idx: Int) {
        guard idx >= 0, idx < voices.count else { return }
        voices[idx].volume = max(0, min(1, v))
    }

    public func stopVoice(_ idx: Int) {
        guard idx >= 0, idx < voices.count, voices[idx].isPlaying else { return }
        voices[idx].stop()
    }

    public func stopAll() {
        for node in voices where node.isPlaying { node.stop() }
    }

    public var voiceCount: Int { voices.count }
}
