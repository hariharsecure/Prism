import CoreMedia
import Foundation
import PrismCore
import os

/// Manages one `MovieRecorder` per source so per-source ISO recordings land
/// time-aligned (DESIGN §2.5 "ISO recording", §3.2 ISO taps).
///
/// All recorders share **one fixed session start time** (house clock), so every
/// file's timeline zero is the same instant — the FCPXML multicam exporter can
/// lay the clips on a shared timeline with zero per-clip offsets. Media that
/// arrives with PTS before the shared start is trimmed by AVAssetWriter.
///
/// Feeding: ISO taps sit *before* the compositor mailboxes (DESIGN §3.3), so
/// route each source's raw `VideoFrame`s / `AudioPacket`s here from the capture
/// callbacks; the bank fans out by `SourceID`.
public final class ISORecorderBank: @unchecked Sendable {
    public enum BankError: Error {
        case invalidState(String)
        case duplicateSource(SourceID)
        case unknownSource(SourceID)
    }

    public enum State: String, Sendable {
        case configuring, recording, finished
    }

    private struct PendingSource {
        let id: SourceID
        let settings: RecordingSettings
        let includeAudio: Bool
    }

    /// A source whose native format is not yet known at `start(at:)` (it has not
    /// delivered its first frame — sources start async). Instead of freezing a
    /// canvas-sized SDR fallback, its recorder is created LAZILY from the format of
    /// its FIRST real frame (via `settingsFrom`), so the first take is recorded at
    /// the source's native resolution + dynamic range (sol wave-16 #1).
    private struct DeferredSource {
        let includeAudio: Bool
        let settingsFrom: @Sendable (VideoFrame) -> RecordingSettings
    }

    private struct MutableState {
        var state: State = .configuring
        var pending: [PendingSource] = []
        /// Sources awaiting their first frame to materialize a native-format recorder.
        var deferred: [SourceID: DeferredSource] = [:]
        var recorders: [SourceID: MovieRecorder] = [:]
        var startTime: CMTime?
    }

    /// Seam for constructing recorders (failure injection in headless
    /// verification; production uses `MovieRecorder.init`).
    public typealias RecorderFactory = (URL, RecordingSettings, MovieRecorder.SessionStart) throws -> MovieRecorder

    public let directory: URL
    public let defaultSettings: RecordingSettings

    private let lock = OSAllocatedUnfairLock<MutableState>(initialState: MutableState())
    private let recorderFactory: RecorderFactory
    private let log = EngineLog.logger("output.isobank")

    /// - Parameters:
    ///   - directory: destination folder; files are named `iso-<sourceID>.mov`.
    ///   - defaultSettings: settings applied to sources added without overrides.
    ///   - recorderFactory: recorder construction seam; defaults to `MovieRecorder.init`.
    public init(directory: URL, defaultSettings: RecordingSettings,
                recorderFactory: RecorderFactory? = nil) {
        self.directory = directory
        self.defaultSettings = defaultSettings
        self.recorderFactory = recorderFactory ?? { url, settings, sessionStart in
            try MovieRecorder(url: url, settings: settings, sessionStart: sessionStart)
        }
    }

    /// The shared session start (valid once recording).
    public var startTime: CMTime? { lock.withLock { $0.startTime } }
    public var state: State { lock.withLock { $0.state } }

    /// Registers a source before `start(at:)`. Per-source dimension/codec
    /// overrides let e.g. a 4K iPhone ISO coexist with 1080p UVC ISOs.
    public func addSource(_ id: SourceID, settings: RecordingSettings? = nil, includeAudio: Bool = false) throws {
        try lock.withLock { s in
            guard s.state == .configuring else { throw BankError.invalidState("addSource after start") }
            guard !s.pending.contains(where: { $0.id == id }) else { throw BankError.duplicateSource(id) }
            var effective = settings ?? defaultSettings
            effective.includeAudio = includeAudio
            s.pending.append(PendingSource(id: id, settings: effective, includeAudio: includeAudio))
        }
    }

    /// Registers a source whose native format is NOT yet known (it has not yet
    /// delivered a frame — sources start asynchronously). No recorder is created at
    /// `start(at:)`; instead the source's FIRST frame that reaches `append` builds
    /// its recorder from `settingsFrom(firstFrame)` — deriving native resolution +
    /// dynamic range from that frame — sharing the bank's one fixed session start.
    /// So the FIRST take is native + HDR-correct rather than a frozen canvas-sized
    /// SDR fallback (sol wave-16 #1). `settingsFrom` runs on the append (capture)
    /// thread; `includeAudio` overrides the derived settings' audio flag.
    public func addDeferredSource(_ id: SourceID, includeAudio: Bool = false,
                                  settingsFrom: @escaping @Sendable (VideoFrame) -> RecordingSettings) throws {
        try lock.withLock { s in
            guard s.state == .configuring else { throw BankError.invalidState("addDeferredSource after start") }
            guard !s.pending.contains(where: { $0.id == id }), s.deferred[id] == nil else {
                throw BankError.duplicateSource(id)
            }
            s.deferred[id] = DeferredSource(includeAudio: includeAudio, settingsFrom: settingsFrom)
        }
    }

    /// Removes a source armed with `addSource`/`addDeferredSource` before recording
    /// starts (per-source disable in the arm-up UI). Illegal once recording.
    public func removeSource(_ id: SourceID) throws {
        try lock.withLock { s in
            guard s.state == .configuring else { throw BankError.invalidState("removeSource after start") }
            if let idx = s.pending.firstIndex(where: { $0.id == id }) {
                s.pending.remove(at: idx)
            } else if s.deferred[id] != nil {
                s.deferred[id] = nil
            } else {
                throw BankError.unknownSource(id)
            }
        }
    }

    /// Sources armed but not yet started (the UI's ISO arm list while configuring) —
    /// both immediate (native-format-known) and deferred (awaiting first frame).
    public var pendingSourceIDs: [SourceID] {
        lock.withLock { $0.pending.map { $0.id } + Array($0.deferred.keys) }
    }

    /// Sources with a live recorder (valid once `.recording`).
    public var activeSourceIDs: [SourceID] {
        lock.withLock { s in s.state == .recording ? Array(s.recorders.keys) : [] }
    }

    /// True once a source is armed with an audio track.
    public func isArmedWithAudio(_ id: SourceID) -> Bool {
        lock.withLock { s in
            s.pending.first(where: { $0.id == id })?.includeAudio ?? s.deferred[id]?.includeAudio ?? false
        }
    }

    /// Live per-source status for a UI (recording state, bytes on disk, frame
    /// counters). Nil for a source the bank doesn't know.
    public struct SourceStatus: Sendable {
        public let id: SourceID
        public let state: MovieRecorder.State
        public let bytesWritten: Int64
        public let videoFramesWritten: UInt64
        public let videoFramesDropped: UInt64
        public let audioBuffersWritten: UInt64
        public let audioBuffersDropped: UInt64
    }

    /// The effective recording settings of a source's live recorder (valid once
    /// `.recording`) — the per-source native dimensions / codec / dynamic range
    /// actually configured, so a caller can confirm each ISO angle is recorded at
    /// its own native format rather than a shared hardcoded default.
    public func settings(for id: SourceID) -> RecordingSettings? {
        lock.withLock { $0.recorders[id]?.settings }
    }

    /// Live status of one recording source (valid once `.recording`).
    public func status(for id: SourceID) -> SourceStatus? {
        guard let recorder = lock.withLock({ $0.recorders[id] }) else { return nil }
        let live = recorder.liveStats
        return SourceStatus(id: id, state: live.state, bytesWritten: live.bytesWritten,
                            videoFramesWritten: live.videoFramesWritten,
                            videoFramesDropped: live.videoFramesDropped,
                            audioBuffersWritten: live.audioBuffersWritten,
                            audioBuffersDropped: live.audioBuffersDropped)
    }

    /// Live status of every active source (UI HUD refresh).
    public var statuses: [SourceID: SourceStatus] {
        let recorders = lock.withLock { $0.recorders }
        var out: [SourceID: SourceStatus] = [:]
        for (id, recorder) in recorders {
            let live = recorder.liveStats
            out[id] = SourceStatus(id: id, state: live.state, bytesWritten: live.bytesWritten,
                                   videoFramesWritten: live.videoFramesWritten,
                                   videoFramesDropped: live.videoFramesDropped,
                                   audioBuffersWritten: live.audioBuffersWritten,
                                   audioBuffersDropped: live.audioBuffersDropped)
        }
        return out
    }

    /// Instantiates and starts all recorders with one shared timeline zero.
    /// Defaults to "now" in house time.
    ///
    /// All-or-nothing: recorders are created first (a create failure starts
    /// nothing), then started; if any start throws, every recorder this call
    /// already started is cancelled before rethrowing — a failed bank start
    /// never leaks recorders holding open writers. The bank stays
    /// `.configuring`, so a corrected `start(at:)` can be retried.
    public func start(at time: CMTime = HouseClock.now()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try lock.withLock { s in
            guard s.state == .configuring else { throw BankError.invalidState("start in \(s.state)") }
            guard !(s.pending.isEmpty && s.deferred.isEmpty) else { throw BankError.invalidState("no sources added") }

            // Phase 1: create every recorder. Nothing has started yet, so a
            // throw here leaks nothing.
            var created: [(id: SourceID, recorder: MovieRecorder)] = []
            created.reserveCapacity(s.pending.count)
            for source in s.pending {
                let url = directory.appendingPathComponent("iso-\(Self.sanitize(source.id.raw)).mov")
                created.append((source.id, try recorderFactory(url, source.settings, .fixed(time))))
            }

            // Phase 2: start them all; on failure, cancel the ones we started.
            var started: [MovieRecorder] = []
            started.reserveCapacity(created.count)
            do {
                for (_, recorder) in created {
                    try recorder.start()
                    started.append(recorder)
                }
            } catch {
                for recorder in started { recorder.cancel() }
                log.error("ISO bank start failed after \(started.count) recorder(s) started — cancelled them: \(String(describing: error), privacy: .public)")
                throw error
            }

            for (id, recorder) in created { s.recorders[id] = recorder }
            s.startTime = time
            s.state = .recording
        }
        log.info("ISO bank started (\(self.lock.withLock { $0.recorders.count }) sources) at house time \(time.seconds, format: .fixed(precision: 3))")
    }

    /// Routes a raw source frame to its recorder. Frames for unknown sources
    /// are ignored (source may be live in the mix but not ISO-armed). A DEFERRED
    /// source's FIRST frame materializes its native-format recorder here (sol
    /// wave-16 #1).
    public func append(_ frame: VideoFrame) {
        materializedRecorder(for: frame)?.append(frame)
    }

    /// Routes source audio to its recorder (only sources armed with audio). Audio
    /// alone never materializes a deferred source — the video format defines the
    /// file, so the deferred recorder is created by the first VIDEO frame.
    public func append(_ audio: AudioPacket) {
        recorder(for: audio.source)?.append(audio: audio.sampleBuffer)
    }

    private func recorder(for id: SourceID) -> MovieRecorder? {
        lock.withLock { s in
            guard s.state == .recording else { return nil }
            return s.recorders[id]
        }
    }

    /// The live recorder for `frame.source`, creating it now if the source is
    /// DEFERRED and this is its first frame (native-format derivation). Only the
    /// FIRST frame per deferred source materializes it (claimed under the lock);
    /// the recorder is created OUTSIDE the lock (AVAssetWriter setup does I/O).
    private func materializedRecorder(for frame: VideoFrame) -> MovieRecorder? {
        let id = frame.source
        enum Action { case existing(MovieRecorder); case materialize(DeferredSource, CMTime); case none }
        let action: Action = lock.withLock { s in
            guard s.state == .recording else { return .none }
            if let r = s.recorders[id] { return .existing(r) }
            if let d = s.deferred[id], let start = s.startTime {
                s.deferred[id] = nil                      // claim: only the first frame builds it
                return .materialize(d, start)
            }
            return .none
        }
        switch action {
        case .existing(let r): return r
        case .none: return nil
        case .materialize(let d, let start):
            var settings = d.settingsFrom(frame)
            settings.includeAudio = d.includeAudio
            let url = directory.appendingPathComponent("iso-\(Self.sanitize(id.raw)).mov")
            do {
                let recorder = try recorderFactory(url, settings, .fixed(start))
                try recorder.start()
                // Install only if the bank is still recording (a concurrent finishAll
                // may have flipped to .finished while we were opening the writer).
                let kept: Bool = lock.withLock { s in
                    guard s.state == .recording else { return false }
                    s.recorders[id] = recorder
                    return true
                }
                if kept { return recorder }
                recorder.cancel()
                return nil
            } catch {
                log.error("deferred ISO recorder for \(id.raw, privacy: .public) failed to start (first frame \(frame.width)×\(frame.height)): \(String(describing: error), privacy: .public)")
                return nil
            }
        }
    }

    /// Finishes every recorder; returns per-source results (a failed source
    /// never blocks the others' clean finish).
    public func finishAll() async -> [SourceID: Result<MovieRecorder.Report, Error>] {
        let recorders: [SourceID: MovieRecorder] = lock.withLock { s in
            guard s.state == .recording else { return [:] }
            s.state = .finished
            return s.recorders
        }
        var results: [SourceID: Result<MovieRecorder.Report, Error>] = [:]
        for (id, recorder) in recorders {
            do {
                results[id] = .success(try await recorder.finish())
            } catch {
                results[id] = .failure(error)
            }
        }
        return results
    }

    private static func sanitize(_ raw: String) -> String {
        String(raw.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }
}
