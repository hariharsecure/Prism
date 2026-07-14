import AVFAudio
import CoreMedia
import Foundation
import PrismCore
import Speech
import os

/// One caption emission from `LiveCaptioner`.
///
/// A recognizer produces a stream of *partial* hypotheses that refine the live
/// line, then a single *final* result that commits it. `isFinal == false` should
/// update the on-air live line in place; `isFinal == true` commits it and starts
/// a new live line.
public struct CaptionUpdate: Sendable, Equatable {
    /// The best transcription so far (whole current utterance).
    public let text: String
    /// `true` when the recognizer committed this utterance (stable); `false` for
    /// an in-progress partial hypothesis.
    public let isFinal: Bool
    /// House-time seconds of the most recently ingested program audio — the
    /// approximate on-air time of this caption. (Recognition latency means it
    /// trails the audio slightly.)
    public let hostSeconds: Double

    public init(text: String, isFinal: Bool, hostSeconds: Double) {
        self.text = text
        self.isFinal = isFinal
        self.hostSeconds = hostSeconds
    }
}

/// Live speech-to-text over the program master mix, using Apple's on-device
/// Speech framework.
///
/// Consumes the mixer's `onMasterMix` `AudioPacket`s (interleaved Float32 LPCM,
/// house-time PTS — same contract `TransientDetector` reads), converts each to an
/// `AVAudioPCMBuffer`, and appends it to an `SFSpeechAudioBufferRecognitionRequest`.
/// Partial and final transcriptions are delivered to `onCaption`, which a caption
/// overlay (e.g. `CaptionRenderer`) burns into the output.
///
/// ## Availability & degradation (never crashes)
/// Speech is a TCC-gated, optionally-unsupported capability. The captioner
/// resolves readiness before doing any work and, if it can't run, enters a clear
/// `.unavailable(reason)` state and **no-ops** every `append`:
///   - recognizer can't be constructed for the locale → `.recognizerUnavailable`
///   - `requireOnDevice` but the locale has no on-device model → `.onDeviceUnsupported`
///   - authorization denied / restricted → `.authorizationDenied` / `.authorizationRestricted`
///   - not-yet-authorized → `start()` requests authorization; if the user denies,
///     it transitions to `.unavailable(...)`; if granted, to `.running`.
///
/// ## Threading
/// All mutable state is guarded by one lock; `onCaption` is invoked *after* the
/// lock is released, on the Speech framework's callback queue. `start/stop/reset`
/// and `append` are safe to call from any thread.
public final class LiveCaptioner: @unchecked Sendable {

    /// Why the captioner can't transcribe. Stable, reportable reasons.
    public enum Unavailable: String, Sendable, Equatable, CustomStringConvertible {
        case recognizerUnavailable  // no SFSpeechRecognizer for the locale / offline
        case onDeviceUnsupported    // requireOnDevice but no on-device model
        case authorizationDenied    // user denied Speech access
        case authorizationRestricted // MDM / parental restriction
        case recognitionFailed      // the recognition task errored out

        public var description: String { rawValue }
    }

    /// Lifecycle / availability state.
    public enum State: Sendable, Equatable {
        case idle                 // constructed / reset, not running
        case starting             // authorization in flight
        case running              // actively transcribing appended audio
        case stopped              // stopped after running
        case unavailable(Unavailable)
    }

    /// Result of resolving whether transcription can start — pure, no I/O, so the
    /// mapping is unit-testable without triggering a TCC prompt.
    public enum Readiness: Sendable, Equatable {
        case ready                 // authorized + capable → can begin now
        case needsAuthorization    // not-determined → must request authorization
        case unavailable(Unavailable)
    }

    // MARK: State (guarded by `lock`)

    private let lock = NSLock()
    private var _state: State
    private var _onCaption: (@Sendable (CaptionUpdate) -> Void)?
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    private var _task: SFSpeechRecognitionTask?
    private var _lastHostSeconds: Double = 0
    private var _warnedConvert = false
    /// Monotonic session token. Bumped on every start/stop/rotate so that
    /// recognition callbacks and appends from a superseded session are ignored.
    private var _generation: UInt64 = 0

    private let recognizer: SFSpeechRecognizer?
    private let requireOnDevice: Bool
    private let log = EngineLog.logger("audio.captioner")

    // MARK: Init

    /// - Parameters:
    ///   - locale: recognition locale (default: current, falling back to en-US).
    ///   - requireOnDevice: prefer/require on-device recognition (default `true` —
    ///     keeps program audio off Apple's servers; if the locale lacks an
    ///     on-device model the captioner becomes `.onDeviceUnsupported`).
    public init(locale: Locale = Locale(identifier: "en-US"), requireOnDevice: Bool = true) {
        self.requireOnDevice = requireOnDevice
        self.recognizer = SFSpeechRecognizer(locale: locale)
        if recognizer == nil {
            _state = .unavailable(.recognizerUnavailable)
        } else {
            _state = .idle
        }
    }

    // MARK: Public API

    /// The caption sink. Set before `start()`. Invoked off the recognizer's queue,
    /// after internal locking is released. Thread-safe.
    public var onCaption: (@Sendable (CaptionUpdate) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onCaption }
        set { lock.lock(); defer { lock.unlock() }; _onCaption = newValue }
    }

    /// Current lifecycle / availability state. Thread-safe.
    public var state: State { lock.lock(); defer { lock.unlock() }; return _state }

    /// Whether the recognizer reports on-device recognition support for the locale.
    public var supportsOnDeviceRecognition: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    /// Begin transcribing. Resolves readiness first; requests Speech authorization
    /// if not yet determined. Safe to call when already running (no-op) or when
    /// permanently `.unavailable` (stays unavailable). Non-blocking.
    ///
    /// ## Authorization prompt contract (C4)
    /// The system Speech-authorization prompt is requested **only** here, from an
    /// explicit user-initiated `start()`, and only when the status is
    /// `.notDetermined`. Neither `init`, `state`, `supportsOnDeviceRecognition`,
    /// nor the pure `resolveReadiness(...)` truth table ever triggers a prompt —
    /// enabling captions is the sole user action that may ask for permission.
    public func start() {
        // C2: atomically claim the `.idle`/`.stopped` → `.starting` transition.
        // Exactly one concurrent caller wins the compare-and-set; the rest observe
        // a busy/permanent state and no-op, so two recognition tasks can never be
        // spun up for one captioner. The winner carries a fresh session generation.
        guard let generation = claimStart() else { return }

        let readiness = Self.resolveReadiness(
            recognizerExists: recognizer != nil,
            supportsOnDevice: recognizer?.supportsOnDeviceRecognition ?? false,
            requireOnDevice: requireOnDevice,
            authorization: SFSpeechRecognizer.authorizationStatus())

        switch readiness {
        case .unavailable(let reason):
            setUnavailable(reason, generation: generation)
        case .ready:
            beginSession(generation: generation)
        case .needsAuthorization:
            // State is already `.starting`; request authorization (user-initiated).
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                guard let self else { return }
                let r = Self.resolveReadiness(
                    recognizerExists: self.recognizer != nil,
                    supportsOnDevice: self.recognizer?.supportsOnDeviceRecognition ?? false,
                    requireOnDevice: self.requireOnDevice,
                    authorization: status)
                switch r {
                case .ready: self.beginSession(generation: generation)
                case .unavailable(let reason): self.setUnavailable(reason, generation: generation)
                case .needsAuthorization: self.setUnavailable(.authorizationDenied, generation: generation)
                }
            }
        }
    }

    /// Atomically claim the `.idle`/`.stopped` → `.starting` transition, returning
    /// a fresh session-generation token to the single winning caller (or `nil` when
    /// already running/starting/permanently unavailable). Exposed `internal` so the
    /// concurrency of the claim can be verified without triggering a TCC prompt.
    func claimStart() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        switch _state {
        case .idle, .stopped:
            _generation &+= 1
            _state = .starting
            return _generation
        case .running, .starting, .unavailable:
            return nil
        }
    }

    /// Feed one program-mix packet. When running, converts it to PCM and appends
    /// it to the recognition request; otherwise a no-op. Never throws or crashes
    /// on an unexpected format — it logs once and drops the packet.
    public func append(_ packet: AudioPacket) {
        // C3: snapshot the live session generation under the lock. Only append when
        // running with a live request; a concurrent stop()/rotate changes the
        // generation, so a captured-but-now-dead request is never fed.
        let generation: UInt64? = {
            lock.lock(); defer { lock.unlock() }
            guard case .running = _state, _request != nil else { return nil }
            _lastHostSeconds = packet.pts.seconds
            return _generation
        }()
        guard let generation else { return }

        guard let buffer = Self.makePCMBuffer(from: packet) else {
            lock.lock()
            let warn = !_warnedConvert
            _warnedConvert = true
            lock.unlock()
            if warn { log.error("captioner: could not convert AudioPacket → PCM (need packed interleaved Float32 LPCM); dropping") }
            return
        }
        // Re-check under the lock that this exact session is still the live one
        // before handing the buffer to the recognizer.
        lock.lock()
        guard case .running = _state, generation == _generation, let req = _request else {
            lock.unlock()
            return
        }
        req.append(buffer)
        lock.unlock()
    }

    /// Stop transcribing and tear down the recognition task. Keeps `onCaption`.
    /// A permanently-`.unavailable` captioner stays unavailable.
    public func stop() {
        let request: SFSpeechAudioBufferRecognitionRequest?
        let task: SFSpeechRecognitionTask?
        lock.lock()
        _generation &+= 1   // C2/C3: invalidate any in-flight session + its callbacks
        request = _request; task = _task
        _request = nil; _task = nil
        if case .unavailable = _state {} else { _state = .stopped }
        lock.unlock()
        request?.endAudio()
        task?.finish()
    }

    /// Stop and return to `.idle` so `start()` can run a fresh session. A
    /// permanently-`.unavailable` captioner stays unavailable.
    public func reset() {
        stop()
        lock.lock()
        _lastHostSeconds = 0
        _warnedConvert = false
        if case .unavailable = _state {} else { _state = .idle }
        lock.unlock()
    }

    // MARK: Readiness (pure — unit-testable, no TCC/I-O)

    /// Map the observable capability/authorization inputs to a `Readiness`. Pure
    /// so `start()` and tests share one truth table (no prompt, no hardware).
    public static func resolveReadiness(recognizerExists: Bool,
                                        supportsOnDevice: Bool,
                                        requireOnDevice: Bool,
                                        authorization: SFSpeechRecognizerAuthorizationStatus) -> Readiness {
        guard recognizerExists else { return .unavailable(.recognizerUnavailable) }
        if requireOnDevice && !supportsOnDevice { return .unavailable(.onDeviceUnsupported) }
        switch authorization {
        case .authorized:     return .ready
        case .denied:         return .unavailable(.authorizationDenied)
        case .restricted:     return .unavailable(.authorizationRestricted)
        case .notDetermined:  return .needsAuthorization
        @unknown default:     return .unavailable(.authorizationDenied)
        }
    }

    // MARK: AudioPacket → AVAudioPCMBuffer (pure — unit-testable)

    /// Convert a program `AudioPacket` (interleaved Float32 LPCM, the master-mix
    /// contract) into an `AVAudioPCMBuffer` suitable for
    /// `SFSpeechAudioBufferRecognitionRequest.append`. Returns `nil` for an
    /// unsupported format or malformed buffer (never traps).
    public static func makePCMBuffer(from packet: AudioPacket) -> AVAudioPCMBuffer? {
        let sb = packet.sampleBuffer
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else {
            return nil
        }
        var asbd = asbdPtr.pointee
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0 else { return nil }
        let channels = Int(asbd.mChannelsPerFrame)
        // C1: master-mix contract is PACKED INTERLEAVED Float32 LPCM with an exact
        // stride. Reject anything else — in particular NON-interleaved (planar)
        // audio, whose per-channel buffers we must never treat as one interleaved
        // block, and padded strides that would mis-index. Returning nil here lets
        // `append` log once and drop the packet (never traps, never overruns).
        let bytesPerFrame = channels * MemoryLayout<Float>.size
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              (asbd.mFormatFlags & kAudioFormatFlagIsPacked) != 0,
              (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0,
              asbd.mBitsPerChannel == 32,
              channels >= 1,
              asbd.mFramesPerPacket == 1,
              Int(asbd.mBytesPerFrame) == bytesPerFrame,
              asbd.mBytesPerPacket == asbd.mBytesPerFrame else {
            return nil
        }
        guard let format = AVAudioFormat(streamDescription: &asbd),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)

        guard let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let byteCount = frames * bytesPerFrame
        guard CMBlockBufferGetDataLength(block) >= byteCount else { return nil }

        // Interleaved Float32 → a single AudioBuffer holding all channels.
        let abl = buffer.mutableAudioBufferList
        guard let dst = abl.pointee.mBuffers.mData else { return nil }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0,
                                          lengthAtOffsetOut: &lengthAtOffset,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &dataPtr) == kCMBlockBufferNoErr,
              let dataPtr else {
            return nil
        }
        if lengthAtOffset >= byteCount {
            // Contiguous fast path: the first segment holds the whole payload.
            memcpy(dst, dataPtr, byteCount)
        } else {
            // C1: a DISCONTIGUOUS CMBlockBuffer's first segment is shorter than the
            // payload — copy segment-safely instead of overreading past it.
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0,
                                             dataLength: byteCount,
                                             destination: dst) == kCMBlockBufferNoErr else {
                return nil
            }
        }
        return buffer
    }

    // MARK: Internals

    /// Apply an `.unavailable` state only if this start attempt is still current
    /// (a concurrent stop()/newer start bumps the generation and must win).
    private func setUnavailable(_ reason: Unavailable, generation: UInt64) {
        lock.lock()
        if generation == _generation { _state = .unavailable(reason) }
        lock.unlock()
    }

    private func beginSession(generation: UInt64) {
        guard let recognizer, recognizer.isAvailable else {
            setUnavailable(.recognizerUnavailable, generation: generation)
            return
        }
        // Bail if this attempt was superseded (stop()/newer start) before we begin.
        let current: Bool = { lock.lock(); defer { lock.unlock() }; return generation == _generation }()
        guard current else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if requireOnDevice { request.requiresOnDeviceRecognition = true }

        // Create the task OUTSIDE the lock (its callback may fire on another
        // thread); the callback is generation-stamped, so any result that arrives
        // before we publish `_task` — or after we're superseded — is ignored.
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handleResult(result, error: error, generation: generation)
        }

        lock.lock()
        if generation == _generation, case .starting = _state {
            _request = request
            _task = task
            _state = .running
            lock.unlock()
        } else {
            // Superseded between the pre-check and here — discard the orphan.
            lock.unlock()
            request.endAudio()
            task.cancel()
        }
    }

    private func handleResult(_ result: SFSpeechRecognitionResult?, error: Error?, generation: UInt64) {
        var emit: CaptionUpdate?
        var callback: (@Sendable (CaptionUpdate) -> Void)?
        var rearm = false
        lock.lock()
        // C3: ignore any callback from a superseded/torn-down session.
        guard generation == _generation else { lock.unlock(); return }
        if let result {
            // C3: emit ONLY while actively running this exact session.
            if case .running = _state {
                emit = CaptionUpdate(text: result.bestTranscription.formattedString,
                                     isFinal: result.isFinal,
                                     hostSeconds: _lastHostSeconds)
                callback = _onCaption
                if result.isFinal {
                    // Commit this line, then rotate: tear down the finished task and
                    // re-arm a fresh request/task so the rolling live line keeps
                    // going after a committed utterance (instead of stalling).
                    _request = nil
                    _task = nil
                    rearm = true
                }
            }
        } else if error != nil {
            if case .unavailable = _state {} else { _state = .stopped }
            _request = nil
            _task = nil
        }
        lock.unlock()

        if let error {
            log.error("captioner: recognition task ended: \(error.localizedDescription, privacy: .public)")
        }
        if let emit, let callback { callback(emit) }
        if rearm { rearmSession(previousGeneration: generation) }
    }

    /// After a committed (final) utterance, rotate to a fresh recognition
    /// request/task under a new generation so continuous captioning continues.
    private func rearmSession(previousGeneration: UInt64) {
        guard let recognizer, recognizer.isAvailable else { return }
        // Reserve a fresh generation (invalidates late callbacks from the finished
        // task) only if we're still the current, running session.
        let newGeneration: UInt64? = {
            lock.lock(); defer { lock.unlock() }
            guard previousGeneration == _generation, case .running = _state else { return nil }
            _generation &+= 1
            return _generation
        }()
        guard let newGeneration else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if requireOnDevice { request.requiresOnDeviceRecognition = true }
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handleResult(result, error: error, generation: newGeneration)
        }
        lock.lock()
        if newGeneration == _generation, case .running = _state {
            _request = request
            _task = task
            lock.unlock()
        } else {
            lock.unlock()
            request.endAudio()
            task.cancel()
        }
    }
}
