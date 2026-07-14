import CoreMedia
import CoreVideo
import Foundation
import PrismAudio
import PrismCore
import PrismOutput
import PrismVirtualCam

/// Latest program frame, handed from the render thread to the UI.
/// The program monitor pulls at ~30 fps; latest-wins, no queue.
final class ProgramPreviewStore: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: VideoFrame?
    private var sequence: UInt64 = 0

    func store(_ newFrame: VideoFrame) {
        lock.lock()
        frame = newFrame
        sequence &+= 1
        lock.unlock()
    }

    /// Newest frame iff it changed since `lastSequence`.
    func latest(after lastSequence: UInt64) -> (frame: VideoFrame, sequence: UInt64)? {
        lock.lock(); defer { lock.unlock() }
        guard sequence != lastSequence, let frame else { return nil }
        return (frame, sequence)
    }
}

/// Program-frame fan-out (DESIGN §3.2): every frame the render loop emits goes
/// to the preview store, the optional recorder, and the optional virtual-camera
/// feeder. Runs on the render thread — nothing here blocks.
final class ProgramFanOut: @unchecked Sendable {
    let preview = ProgramPreviewStore()

    /// C29: fires (render thread, at most once per recorder instance) when
    /// the active recorder is observed in `.failed` — MovieRecorder.append
    /// swallows writer errors, so failures only show up in its state.
    var onRecorderFailure: ((MovieRecorder) -> Void)?

    private let lock = NSLock()
    private var recorder: MovieRecorder?
    private var recorderWantsAudio = false
    private var recorderFailureReported = false
    private var lastRecorderStateCheck: TimeInterval = 0
    private var feeder: VirtualCameraFeeder?
    /// sol #6 #5: when an HDR show is streamed to a classic-RTMP target, the stream
    /// encoder is H.264 SDR but the program frame is 10-bit HLG/Rec.2020 — feeding it
    /// UNCHANGED emits an SDR-declared stream whose decoded gray is 182 (from HLG 726)
    /// not ~128. When this is set, the program frame is CONVERTED to real SDR (via the
    /// shared `HDRSDRConverter`) BEFORE the stream encoder — pixels, not just tags.
    /// Only the classic-RTMP/SDR stream path converts; recorder/replay/SRT keep the
    /// true HDR frame. Guarded by `lock`; the BGRA scratch pool is render-thread-only.
    private var streamSDRFromHDR = false
    private var streamSDRPool: PixelBufferPool?
    /// Stream sinks (wave 2): program video → encoder, master-mix audio → RTMP.
    private var streamEncoder: ProgramEncoder?
    private var streamOutput: RTMPStreamOutput?
    /// Replay sink (wave 3): a dedicated program encoder whose encoded frames
    /// feed the instant-replay ring buffer (nil unless replay is armed).
    private var replayEncoder: ProgramEncoder?
    /// Replay ring buffer (wave 3): receives the master-mix AUDIO directly (PCM),
    /// so a saved replay clip muxes sound. Its VIDEO arrives pre-encoded via
    /// `replayEncoder.onEncodedFrame`. nil unless replay is armed.
    private var replayBuffer: ReplayBuffer?
    /// Multi-destination broadcaster (deliverable B): receives the SAME
    /// master-mix audio the single RTMP output does, so restream destinations
    /// mux program audio. Its VIDEO arrives via the shared ProgramEncoder's
    /// `onEncodedFrame` (wired in AppEngine), not here. nil unless a broadcast
    /// with ≥1 destination is live. `broadcast(audio:)` is nonisolated → safe
    /// to call from the audio callback thread.
    private var broadcaster: MultiDestinationBroadcaster?
    /// Live-captions tap (feature 1): the program master mix is appended to the
    /// on-device speech recognizer, which drives the caption overlay. nil unless
    /// captions are ON. `append` is thread-safe (internal lock) and a no-op when
    /// the captioner isn't `.running`.
    private var captioner: LiveCaptioner?
    /// Reactive-trigger tap (feature 4): the program master mix is fed to a
    /// transient detector whose `onTransient` auto-fires the chosen effect. nil
    /// unless a reactive action is armed. `process` is thread-safe.
    private var transientDetector: TransientDetector?
    /// Character lip-sync tap: the program master mix is fed to an audio-envelope
    /// follower whose smoothed `openness` the app polls each frame and pushes to
    /// every lip-sync-enabled `CharacterSource`. nil unless ≥1 character has
    /// lip-sync on. `process` is thread-safe (its own lock).
    private var envelopeFollower: AudioEnvelopeFollower?

    func setRecorder(_ newValue: MovieRecorder?, wantsAudio: Bool = false) {
        lock.lock()
        recorder = newValue
        recorderWantsAudio = wantsAudio
        recorderFailureReported = false
        lastRecorderStateCheck = 0
        lock.unlock()
    }

    #if DEBUG
    /// sol #2 test probe: whether the master-mix audio tap is armed to feed the
    /// program recorder (set from `startRecording`'s record-audio decision).
    var _test_recorderWantsAudio: Bool { lock.lock(); defer { lock.unlock() }; return recorderWantsAudio }
    #endif

    func setFeeder(_ newValue: VirtualCameraFeeder?) {
        lock.lock()
        feeder = newValue
        lock.unlock()
    }

    /// Program-video encoder for the live stream (nil when not streaming).
    func setStreamEncoder(_ newValue: ProgramEncoder?) {
        lock.lock()
        streamEncoder = newValue
        lock.unlock()
    }

    /// sol #7 #3/#5: install the stream encoder AND set the HDR→SDR conversion flag
    /// ATOMICALLY under a single `lock` hold. `handle` snapshots both fields under the
    /// same lock, so no render tick can ever observe a live SDR encoder with the
    /// conversion still OFF and feed it a raw 10-bit HDR frame (the one-frame startup
    /// leak that fed the SDR encoder an HLG-726 gray → decoded ~182 instead of ~128).
    /// Replaces the pre-fix two-call arm (`setStreamEncoder` then `setStreamSDRFromHDR`)
    /// whose inter-call gap leaked exactly that one frame.
    func armStreamEncoder(_ encoder: ProgramEncoder?, sdrFromHDR: Bool) {
        lock.lock()
        streamEncoder = encoder
        streamSDRFromHDR = sdrFromHDR
        if !sdrFromHDR { streamSDRPool = nil }
        lock.unlock()
    }

    #if DEBUG
    /// sol #7 #3/#5 test seam: fires (under no lock) with the EXACT frame about to be
    /// handed to the stream encoder — so a test can assert a raw 10-bit HDR frame never
    /// reaches the SDR encoder during the arm window. See `HDRClassicRTMPSDRTests`.
    var _test_onStreamEncode: ((VideoFrame) -> Void)?
    /// sol #7 #3/#5 test probe: the current arm state (is the encoder installed, is the
    /// HDR→SDR conversion enabled) — used to prove the two are always armed together.
    var _test_armState: (encoderInstalled: Bool, convertEnabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (streamEncoder != nil, streamSDRFromHDR)
    }
    #endif

    /// sol #6 #5: mark whether the live-stream encoder is SDR while the program is
    /// HDR (a classic-RTMP target under an HDR show) — so the program frame is
    /// colour-converted to real SDR before that encoder. Cleared when streaming
    /// stops or the target set carries HDR (SRT/enhanced).
    func setStreamSDRFromHDR(_ active: Bool) {
        lock.lock()
        streamSDRFromHDR = active
        if !active { streamSDRPool = nil }
        lock.unlock()
    }

    /// RTMP output for the live stream's audio (nil when not streaming). Its
    /// video arrives pre-encoded via the encoder's own callback.
    func setStreamOutput(_ newValue: RTMPStreamOutput?) {
        lock.lock()
        streamOutput = newValue
        lock.unlock()
    }

    /// Program-video encoder feeding the replay ring buffer (nil unless armed).
    /// Encodes independently of the stream encoder ("encode once, tap many" is
    /// the ring's own contract — here each sink owns its encode).
    func setReplayEncoder(_ newValue: ProgramEncoder?) {
        lock.lock()
        replayEncoder = newValue
        lock.unlock()
    }

    /// Replay ring buffer that should receive the master-mix audio (nil unless
    /// armed). `appendAudio` is lock-guarded and safe from the audio thread.
    func setReplayBuffer(_ newValue: ReplayBuffer?) {
        lock.lock()
        replayBuffer = newValue
        lock.unlock()
    }

    /// Multi-destination broadcaster whose destinations should receive the
    /// program-mix audio (deliverable B). nil when not multi-streaming.
    func setBroadcaster(_ newValue: MultiDestinationBroadcaster?) {
        lock.lock()
        broadcaster = newValue
        lock.unlock()
    }

    /// Live captioner that should receive the master-mix audio (feature 1). nil
    /// unless captions are ON. `append` is internally locked / off-thread safe.
    func setCaptioner(_ newValue: LiveCaptioner?) {
        lock.lock()
        captioner = newValue
        lock.unlock()
    }

    /// Transient detector that should receive the master-mix audio (feature 4).
    /// nil unless a reactive action is armed. `process` is internally locked.
    func setTransientDetector(_ newValue: TransientDetector?) {
        lock.lock()
        transientDetector = newValue
        lock.unlock()
    }

    /// Audio-envelope follower that should receive the master-mix audio (character
    /// lip-sync). nil unless ≥1 character has lip-sync on. `process` is internally
    /// locked / off-thread safe.
    func setEnvelopeFollower(_ newValue: AudioEnvelopeFollower?) {
        lock.lock()
        envelopeFollower = newValue
        lock.unlock()
    }

    /// Render thread, once per program frame.
    func handle(_ frame: VideoFrame) {
        preview.store(frame)
        lock.lock()
        let recorder = recorder
        let feeder = feeder
        let streamEncoder = streamEncoder
        let replayEncoder = replayEncoder
        let convertStreamToSDR = streamSDRFromHDR
        lock.unlock()
        recorder?.append(frame)      // drops (and counts) instead of blocking
        feeder?.send(frame)          // no-op unless the feeder is .feeding
        if let streamEncoder {       // encoded output → RTMP via onEncodedFrame
            // sol #6 #5: a classic-RTMP/SDR stream under an HDR show gets REAL SDR
            // pixels here (not the HLG program relabelled) so its decoded gray is
            // ~128, not 182. Recorder/replay/SRT above/below keep the true HDR frame.
            //   sol #7 #3/#5: `convertStreamToSDR` and `streamEncoder` are snapshotted
            //   TOGETHER above, and armed together by `armStreamEncoder`, so a converting
            //   stream NEVER sees the raw HDR frame here. A conversion active-but-failed
            //   → nil → the frame is SKIPPED (never fed HDR to the SDR encoder).
            let toEncode: VideoFrame? = convertStreamToSDR ? convertProgramToSDR(frame) : frame
            if let toEncode {
                #if DEBUG
                _test_onStreamEncode?(toEncode)
                #endif
                try? streamEncoder.encode(toEncode)
            }
        }
        if let replayEncoder {       // encoded output → ReplayBuffer via onEncodedFrame
            try? replayEncoder.encode(frame)
        }
        if let recorder { checkRecorderHealth(recorder) }
    }

    /// sol #6 #5: convert an HDR (10-bit ARGB2101010 HLG/Rec.2020) program frame to a
    /// true SDR BGRA frame for the classic-RTMP SDR encoder. Returns nil (skip the
    /// frame) if the program isn't the expected HDR format or conversion fails — the
    /// SDR encoder is NEVER fed raw HDR pixels. The BGRA scratch pool is created lazily
    /// at the program size; `handle` runs single-threaded on the render thread.
    func convertProgramToSDR(_ frame: VideoFrame) -> VideoFrame? {
        guard CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_ARGB2101010LEPacked else {
            return nil
        }
        let pool: PixelBufferPool
        lock.lock()
        if let existing = streamSDRPool,
           existing.width == frame.width, existing.height == frame.height {
            pool = existing
            lock.unlock()
        } else {
            lock.unlock()
            guard let made = try? PixelBufferPool(width: frame.width, height: frame.height,
                                                  pixelFormat: kCVPixelFormatType_32BGRA) else { return nil }
            lock.lock(); streamSDRPool = made; lock.unlock()
            pool = made
        }
        guard let sdr = try? HDRSDRConverter.convertHDRToSDR_BGRA(from: frame.pixelBuffer, pool: pool) else { return nil }
        return VideoFrame(pixelBuffer: sdr, pts: frame.pts, duration: frame.duration, source: frame.source)
    }

    /// C29: MovieRecorder has no failure callback; poll its (lock-guarded)
    /// state on a debug cadence — at most once per second — after appends,
    /// and report a `.failed` transition exactly once per recorder.
    private func checkRecorderHealth(_ recorder: MovieRecorder) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        // Only police the CURRENT recorder; a stale reference (swapped out
        // between the unlocked read in handle() and here) is not ours to report.
        guard recorder === self.recorder, !recorderFailureReported,
              now - lastRecorderStateCheck >= 1 else {
            lock.unlock()
            return
        }
        lastRecorderStateCheck = now
        lock.unlock()

        guard recorder.state == .failed else { return }

        lock.lock()
        let shouldReport = recorder === self.recorder && !recorderFailureReported
        if shouldReport { recorderFailureReported = true }
        lock.unlock()
        if shouldReport { onRecorderFailure?(recorder) }
    }

    /// Master-mix audio tap (AudioMixer.onMasterMix). Feeds the recorder, the
    /// single RTMP output, AND every multi-destination (deliverable B) — the
    /// caller `broadcast(audio:)` the C2 TODO was waiting for.
    func handle(audio packet: AudioPacket) {
        lock.lock()
        let recorder = recorderWantsAudio ? recorder : nil
        let streamOutput = streamOutput
        let broadcaster = broadcaster
        let replayBuffer = replayBuffer
        let captioner = captioner
        let transientDetector = transientDetector
        let envelopeFollower = envelopeFollower
        lock.unlock()
        recorder?.append(audio: packet.sampleBuffer)
        streamOutput?.append(audio: packet.sampleBuffer) // nonisolated, safe off any thread
        broadcaster?.broadcast(audio: packet.sampleBuffer) // nonisolated fan-out to N destinations
        replayBuffer?.appendAudio(packet.sampleBuffer)     // program audio → replay ring (saved clip has sound)
        captioner?.append(packet)                          // program audio → on-device captions (feature 1)
        transientDetector?.process(packet)                 // program audio → reactive trigger (feature 4)
        envelopeFollower?.process(packet)                  // program audio → character lip-sync openness
    }
}
