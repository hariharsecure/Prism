import AVFoundation
import CoreMedia
import Foundation
import PrismCore
import os

/// Codec/format settings for a per-source audio track (§2.4 "Multitrack
/// recording").
public struct AudioTrackSettings: Sendable {
    /// Encoding for the written audio track.
    public enum Format: Sendable {
        /// AAC-LC at the given bitrate (bits/sec). The production default —
        /// small files, universally playable.
        case aac(bitrate: Int)
        /// Uncompressed 32-bit float LPCM (largest, bit-exact — "fix it in post").
        case pcmFloat32
        /// Uncompressed 16-bit integer LPCM.
        case pcmInt16
    }

    public var format: Format
    public var sampleRate: Double
    public var channels: Int
    /// QuickTime movie-fragment cadence (crash safety), seconds.
    public var fragmentInterval: Double

    public init(format: Format = .aac(bitrate: 160_000),
                sampleRate: Double = 48_000,
                channels: Int = 2,
                fragmentInterval: Double = 4.0) {
        self.format = format
        self.sampleRate = sampleRate
        self.channels = channels
        self.fragmentInterval = fragmentInterval
    }
}

/// Audio-only `AVAssetWriter` recorder: writes one PCM/AAC track to a `.mov`
/// with a **fixed** session-start time so several recorders (and the program
/// recorder) share one house-time zero — the audio analogue of a video ISO in
/// `ISORecorderBank`. Feed it program/master audio or a single source's audio.
///
/// Threading mirrors `MovieRecorder`: `append` is non-blocking (drops + counts
/// when the input can't keep up or on a non-monotonic PTS) and all mutable
/// state is guarded by one unfair lock.
public final class AudioTrackRecorder: @unchecked Sendable {
    public enum RecorderError: Error {
        case invalidState(String)
        case startFailed(underlying: Error?)
        case writerFailed(underlying: Error?)
        case nothingRecorded
    }

    public enum State: String, Sendable {
        case idle, recording, finishing, finished, failed
    }

    /// Result of a finished audio track.
    public struct Report: Sendable {
        public let url: URL
        /// Media duration (last sample end − session start).
        public let duration: CMTime
        public let bytesWritten: Int64
        public let buffersWritten: UInt64
        public let buffersDropped: UInt64
    }

    public struct LiveStats: Sendable {
        public let state: State
        public let bytesWritten: Int64
        public let buffersWritten: UInt64
        public let buffersDropped: UInt64
    }

    public let url: URL
    public let settings: AudioTrackSettings

    private let writer: AVAssetWriter
    private let audioInput: AVAssetWriterInput
    /// Fixed timeline zero shared across a multitrack set.
    private let sessionStart: CMTime
    private let log = EngineLog.logger("output.audiotrack")

    private struct MutableState {
        var state: State = .idle
        var lastPTS: CMTime?
        var lastEnd: CMTime?
        var buffersWritten: UInt64 = 0
        var buffersDropped: UInt64 = 0
    }
    private let stateLock = OSAllocatedUnfairLock<MutableState>(initialState: MutableState())

    public var state: State { stateLock.withLock { $0.state } }

    public var liveStats: LiveStats {
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
        return stateLock.withLock { s in
            LiveStats(state: s.state, bytesWritten: bytes,
                      buffersWritten: s.buffersWritten, buffersDropped: s.buffersDropped)
        }
    }

    /// - Parameters:
    ///   - requestedURL: destination `.mov`; if a file already exists there this
    ///     recorder writes to a uniquified sibling (`name-2.mov`, …) rather than
    ///     deleting it — a new take NEVER destroys a prior take's file (sol HIGH #1
    ///     data-loss guard). The resolved path is exposed as `url`.
    ///   - settings: codec/rate/channels.
    ///   - sessionStart: fixed house-time zero (shared by the whole track set).
    public init(url requestedURL: URL, settings: AudioTrackSettings, sessionStart: CMTime) throws {
        let url = RecorderFilePath.nonClobbering(requestedURL)
        self.url = url
        self.settings = settings
        self.sessionStart = sessionStart

        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: settings.fragmentInterval, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = false

        audioInput = AVAssetWriterInput(mediaType: .audio,
                                        outputSettings: Self.outputSettings(settings))
        audioInput.expectsMediaDataInRealTime = true
        writer.add(audioInput)
    }

    private static func outputSettings(_ settings: AudioTrackSettings) -> [String: Any] {
        switch settings.format {
        case .aac(let bitrate):
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: settings.sampleRate,
                AVNumberOfChannelsKey: settings.channels,
                AVEncoderBitRateKey: bitrate,
            ]
        case .pcmFloat32:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: settings.sampleRate,
                AVNumberOfChannelsKey: settings.channels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        case .pcmInt16:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: settings.sampleRate,
                AVNumberOfChannelsKey: settings.channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        }
    }

    /// Starts the writer; establishes the shared timeline zero immediately.
    public func start() throws {
        try stateLock.withLock { s in
            guard s.state == .idle else { throw RecorderError.invalidState("start() in \(s.state)") }
            guard writer.startWriting() else {
                s.state = .failed
                throw RecorderError.startFailed(underlying: writer.error)
            }
            writer.startSession(atSourceTime: sessionStart)
            s.state = .recording
        }
        log.info("audio track started → \(self.url.lastPathComponent, privacy: .public)")
    }

    /// Appends one audio buffer (PTS in house time, same timeline as the shared
    /// zero). Buffers before the session start, out of order, or arriving while
    /// the input is busy are dropped and counted.
    public func append(_ sampleBuffer: CMSampleBuffer) {
        stateLock.withLock { s in
            guard s.state == .recording else { s.buffersDropped &+= 1; return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard pts.isValid, CMTimeCompare(pts, sessionStart) >= 0 else {
                s.buffersDropped &+= 1; return
            }
            if let last = s.lastPTS, CMTimeCompare(pts, last) <= 0 {
                s.buffersDropped &+= 1; return
            }
            guard audioInput.isReadyForMoreMediaData else { s.buffersDropped &+= 1; return }
            if audioInput.append(sampleBuffer) {
                s.buffersWritten &+= 1
                s.lastPTS = pts
                let dur = CMSampleBufferGetDuration(sampleBuffer)
                s.lastEnd = (dur.isValid && dur.value > 0) ? CMTimeAdd(pts, dur) : pts
            } else {
                s.buffersDropped &+= 1
                if writer.status == .failed {
                    s.state = .failed
                    log.error("audio writer failed: \(String(describing: self.writer.error), privacy: .public)")
                }
            }
        }
    }

    /// Finishes cleanly; reports duration/bytes.
    public func finish() async throws -> Report {
        let lastEnd: CMTime? = try stateLock.withLock { s in
            guard s.state == .recording else { throw RecorderError.invalidState("finish() in \(s.state)") }
            s.state = .finishing
            return s.lastEnd
        }
        guard let lastEnd else {
            writer.cancelWriting()
            stateLock.withLock { $0.state = .failed }
            throw RecorderError.nothingRecorded
        }
        audioInput.markAsFinished()
        writer.endSession(atSourceTime: lastEnd)
        await writer.finishWriting()
        guard writer.status == .completed else {
            stateLock.withLock { $0.state = .failed }
            throw RecorderError.writerFailed(underlying: writer.error)
        }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
        let report: Report = stateLock.withLock { s in
            s.state = .finished
            return Report(url: url, duration: CMTimeSubtract(lastEnd, sessionStart),
                          bytesWritten: bytes, buffersWritten: s.buffersWritten,
                          buffersDropped: s.buffersDropped)
        }
        log.info("audio track finished: \(report.duration.seconds, format: .fixed(precision: 2))s, \(report.bytesWritten) bytes")
        return report
    }

    public func cancel() {
        stateLock.withLock { s in
            guard s.state == .recording else { return }
            s.state = .failed
            writer.cancelWriting()
        }
    }
}

/// Manages one `AudioTrackRecorder` per source (plus, optionally, the master
/// mix) so every audio track shares one house-time zero — the audio analogue of
/// `ISORecorderBank`. This is what lets the app record each source on its own
/// track "to fix the mix in post" (§2.4 Multitrack recording).
public final class AudioTrackRecorderBank: @unchecked Sendable {
    public enum BankError: Error {
        case invalidState(String)
        case duplicateSource(SourceID)
        case unknownSource(SourceID)
    }

    public enum State: String, Sendable { case configuring, recording, finished }

    /// Recorder construction seam (failure injection in tests).
    public typealias RecorderFactory = (URL, AudioTrackSettings, CMTime) throws -> AudioTrackRecorder

    public let directory: URL
    public let defaultSettings: AudioTrackSettings

    private struct Pending { let id: SourceID; let settings: AudioTrackSettings }
    private struct MutableState {
        var state: State = .configuring
        var pending: [Pending] = []
        var recorders: [SourceID: AudioTrackRecorder] = [:]
        var startTime: CMTime?
    }
    private let lock = OSAllocatedUnfairLock<MutableState>(initialState: MutableState())
    private let recorderFactory: RecorderFactory
    private let log = EngineLog.logger("output.audiobank")

    public init(directory: URL, defaultSettings: AudioTrackSettings,
                recorderFactory: RecorderFactory? = nil) {
        self.directory = directory
        self.defaultSettings = defaultSettings
        self.recorderFactory = recorderFactory ?? { url, settings, start in
            try AudioTrackRecorder(url: url, settings: settings, sessionStart: start)
        }
    }

    public var startTime: CMTime? { lock.withLock { $0.startTime } }
    public var state: State { lock.withLock { $0.state } }
    public var pendingSourceIDs: [SourceID] { lock.withLock { $0.pending.map { $0.id } } }
    public var activeSourceIDs: [SourceID] {
        lock.withLock { s in s.state == .recording ? Array(s.recorders.keys) : [] }
    }

    /// Arms a source (or the master, keyed by its own `SourceID`) before start.
    public func addSource(_ id: SourceID, settings: AudioTrackSettings? = nil) throws {
        try lock.withLock { s in
            guard s.state == .configuring else { throw BankError.invalidState("addSource after start") }
            guard !s.pending.contains(where: { $0.id == id }) else { throw BankError.duplicateSource(id) }
            s.pending.append(Pending(id: id, settings: settings ?? defaultSettings))
        }
    }

    public func removeSource(_ id: SourceID) throws {
        try lock.withLock { s in
            guard s.state == .configuring else { throw BankError.invalidState("removeSource after start") }
            guard let idx = s.pending.firstIndex(where: { $0.id == id }) else {
                throw BankError.unknownSource(id)
            }
            s.pending.remove(at: idx)
        }
    }

    /// Creates+starts every recorder with one shared timeline zero. All-or-
    /// nothing, mirroring `ISORecorderBank.start`.
    public func start(at time: CMTime = HouseClock.now()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try lock.withLock { s in
            guard s.state == .configuring else { throw BankError.invalidState("start in \(s.state)") }
            guard !s.pending.isEmpty else { throw BankError.invalidState("no sources added") }

            var created: [(id: SourceID, recorder: AudioTrackRecorder)] = []
            created.reserveCapacity(s.pending.count)
            for p in s.pending {
                let url = directory.appendingPathComponent("audio-\(Self.sanitize(p.id.raw)).mov")
                created.append((p.id, try recorderFactory(url, p.settings, time)))
            }
            var started: [AudioTrackRecorder] = []
            do {
                for (_, recorder) in created {
                    try recorder.start()
                    started.append(recorder)
                }
            } catch {
                for recorder in started { recorder.cancel() }
                log.error("audio bank start failed after \(started.count) recorder(s) — cancelled: \(String(describing: error), privacy: .public)")
                throw error
            }
            for (id, recorder) in created { s.recorders[id] = recorder }
            s.startTime = time
            s.state = .recording
        }
        log.info("audio bank started (\(self.lock.withLock { $0.recorders.count }) tracks) at house time \(time.seconds, format: .fixed(precision: 3))")
    }

    /// Routes a source's audio to its track (unknown sources ignored).
    public func append(_ packet: AudioPacket) {
        recorder(for: packet.source)?.append(packet.sampleBuffer)
    }

    /// Routes a raw sample buffer to a specific source's track (e.g. the master
    /// mix under its own SourceID).
    public func append(_ sampleBuffer: CMSampleBuffer, source: SourceID) {
        recorder(for: source)?.append(sampleBuffer)
    }

    private func recorder(for id: SourceID) -> AudioTrackRecorder? {
        lock.withLock { s in s.state == .recording ? s.recorders[id] : nil }
    }

    public func status(for id: SourceID) -> AudioTrackRecorder.LiveStats? {
        lock.withLock { $0.recorders[id] }?.liveStats
    }

    /// Finishes every track; a failed track never blocks the others.
    public func finishAll() async -> [SourceID: Result<AudioTrackRecorder.Report, Error>] {
        let recorders: [SourceID: AudioTrackRecorder] = lock.withLock { s in
            guard s.state == .recording else { return [:] }
            s.state = .finished
            return s.recorders
        }
        var results: [SourceID: Result<AudioTrackRecorder.Report, Error>] = [:]
        for (id, recorder) in recorders {
            do { results[id] = .success(try await recorder.finish()) }
            catch { results[id] = .failure(error) }
        }
        return results
    }

    private static func sanitize(_ raw: String) -> String {
        String(raw.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }
}
