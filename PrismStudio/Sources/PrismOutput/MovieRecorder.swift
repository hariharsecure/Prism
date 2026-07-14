import AVFoundation
import CoreMedia
import Foundation
import PrismCore
import VideoToolbox
import os

/// Codec + rate settings for a program/ISO recording.
public struct RecordingSettings: Sendable {
    /// Video codec for the recording. H.264/HEVC use the media-engine hardware
    /// encoders via AVAssetWriter; ProRes 422 is hardware on Pro/Max/Ultra parts.
    public enum Codec: String, Sendable {
        case h264
        case hevc
        case proRes422
    }

    /// Program dynamic range (DESIGN.md §2.5 "HDR (P3/HLG) pipeline end-to-end").
    ///
    /// - `.sdr` (default): the codec/profile chosen by `codec` at 8-bit, no
    ///   color tags — byte-for-byte the original behavior.
    /// - `.hdr`: forces **HEVC Main10** (`kVTProfileLevel_HEVC_Main10_AutoLevel`,
    ///   10-bit) regardless of `codec`, and writes Rec.2020 / ITU-R BT.2100 HLG
    ///   color properties into the track so the file is tagged HDR. Feed it the
    ///   compositor's `.hdr` (10-bit `ARGB2101010LEPacked`) program frames.
    public enum DynamicRange: String, Sendable { case sdr, hdr }

    public var codec: Codec
    /// Program dynamic range; `.hdr` overrides `codec` to HEVC Main10.
    public var dynamicRange: DynamicRange
    /// Program width in pixels (AVAssetWriter needs dimensions up front).
    public var width: Int
    /// Program height in pixels.
    public var height: Int
    /// Average video bitrate in bits/sec. Ignored for ProRes (fixed-quality codec).
    public var videoBitrate: Int
    /// Maximum keyframe interval in seconds. Ignored for ProRes (all-intra).
    public var keyframeInterval: Double
    /// Expected source frame rate (encoder hint).
    public var expectedFrameRate: Double
    /// How often the QuickTime movie header is re-written (crash safety), seconds.
    public var fragmentInterval: Double
    /// Whether an audio track is written.
    public var includeAudio: Bool
    /// AAC bitrate in bits/sec for the audio track.
    public var audioBitrate: Int
    /// Audio track sample rate.
    public var audioSampleRate: Double
    /// Audio track channel count.
    public var audioChannels: Int

    public init(
        codec: Codec = .h264,
        width: Int = 1920,
        height: Int = 1080,
        videoBitrate: Int = 12_000_000,
        keyframeInterval: Double = 2.0,
        expectedFrameRate: Double = 60,
        fragmentInterval: Double = 4.0,
        includeAudio: Bool = true,
        audioBitrate: Int = 160_000,
        audioSampleRate: Double = 48_000,
        audioChannels: Int = 2,
        dynamicRange: DynamicRange = .sdr
    ) {
        self.codec = codec
        self.dynamicRange = dynamicRange
        self.width = width
        self.height = height
        self.videoBitrate = videoBitrate
        self.keyframeInterval = keyframeInterval
        self.expectedFrameRate = expectedFrameRate
        self.fragmentInterval = fragmentInterval
        self.includeAudio = includeAudio
        self.audioBitrate = audioBitrate
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
    }
}

/// AVAssetWriter-based program recorder (DESIGN §2.5 "record program", §3.2).
///
/// Input: `VideoFrame` (BGRA8, house-clock PTS) + audio `CMSampleBuffer`s.
/// Frames go straight into an `AVAssetWriterInputPixelBufferAdaptor` — the
/// IOSurface-backed pixel buffer is handed to the media engine untouched
/// (no CPU pixel access, per the zero-copy invariant).
///
/// **Container choice: QuickTime `.mov`, not `.mp4`.** Rationale:
///  - Crash safety is the requirement ("never lose a show to a crash").
///    `AVAssetWriter.movieFragmentInterval` periodically appends movie
///    fragments so at most the last interval is lost on a crash/power-cut;
///    per Apple's docs that property applies to QuickTime movie files —
///    a plain `.mp4` writes its `moov` atom only at finalize, so a crash
///    loses the *entire* file.
///  - `.mov` carries the exact same H.264/HEVC/AAC bitstreams as `.mp4`,
///    so a finished recording can be remuxed losslessly if a client needs
///    the `.mp4` extension, and ProRes (the §2.5 v1 option) is only legal
///    in QuickTime containers anyway.
///  - Timecode tracks for the §2.5 ISO/FCPXML story are first-class in
///    QuickTime files.
///
/// Threading: `append` calls may come from different queues (video from the
/// render thread, audio from the audio graph). All mutable state is guarded
/// by one unfair lock; the writer inputs run in real-time mode
/// (`expectsMediaDataInRealTime = true`) and frames are dropped (and counted)
/// instead of blocking when an input can't keep up.
public final class MovieRecorder: @unchecked Sendable {
    public enum RecorderError: Error {
        /// Operation not legal in the current state.
        case invalidState(String)
        /// AVAssetWriter refused to start.
        case startFailed(underlying: Error?)
        /// AVAssetWriter ended in a failed state.
        case writerFailed(underlying: Error?)
        /// Finish called before any video frame started the session.
        case nothingRecorded
    }

    public enum State: String, Sendable {
        case idle, recording, finishing, finished, failed
    }

    /// When the writer session's time zero is established.
    public enum SessionStart: Sendable {
        /// Session starts at the first appended video frame's PTS (program recording).
        case firstVideoFrame
        /// Session starts at a fixed house time (shared by an ISO bank so all
        /// per-source files have an identical timeline zero).
        case fixed(CMTime)
    }

    /// Result of a finished recording.
    public struct Report: Sendable {
        public let url: URL
        /// Wall duration of recorded media (last video end − session start).
        public let duration: CMTime
        /// Size of the finished file on disk.
        public let bytesWritten: Int64
        public let videoFramesWritten: UInt64
        public let videoFramesDropped: UInt64
        /// Frames rejected for a non-monotonic PTS (would corrupt the track /
        /// raise an AVFoundation exception if appended).
        public let videoFramesRejectedForPTS: UInt64
        public let audioBuffersWritten: UInt64
        public let audioBuffersDropped: UInt64
    }

    public let url: URL
    public let settings: RecordingSettings

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private let sessionStart: SessionStart
    private let log = EngineLog.logger("output.recorder")

    private struct MutableState {
        var state: State = .idle
        var sessionStartTime: CMTime?
        var lastVideoPTS: CMTime?
        var lastAudioPTS: CMTime?
        var lastVideoEnd: CMTime?
        var videoFramesWritten: UInt64 = 0
        var videoFramesDropped: UInt64 = 0
        var videoFramesRejectedForPTS: UInt64 = 0
        var audioBuffersWritten: UInt64 = 0
        var audioBuffersDropped: UInt64 = 0
    }

    private let stateLock = OSAllocatedUnfairLock<MutableState>(initialState: MutableState())

    public var state: State { stateLock.withLock { $0.state } }

    /// Live counters + on-disk size, sampled without waiting for `finish()`.
    /// (Additive read-only view for a UI HUD / ISO bank status; does not touch
    /// the recording path.) `bytesWritten` reflects the fragments flushed so far.
    public struct LiveStats: Sendable {
        public let state: State
        public let bytesWritten: Int64
        public let videoFramesWritten: UInt64
        public let videoFramesDropped: UInt64
        public let videoFramesRejectedForPTS: UInt64
        public let audioBuffersWritten: UInt64
        public let audioBuffersDropped: UInt64
    }

    /// A live snapshot of this recorder's progress.
    public var liveStats: LiveStats {
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
        return stateLock.withLock { s in
            LiveStats(
                state: s.state,
                bytesWritten: bytes,
                videoFramesWritten: s.videoFramesWritten,
                videoFramesDropped: s.videoFramesDropped,
                videoFramesRejectedForPTS: s.videoFramesRejectedForPTS,
                audioBuffersWritten: s.audioBuffersWritten,
                audioBuffersDropped: s.audioBuffersDropped
            )
        }
    }

    /// Creates the writer. If a file already exists at `requestedURL` this recorder
    /// writes to a uniquified sibling (`name-2.mov`, `name-3.mov`, …) instead of
    /// deleting it — a new take NEVER destroys a prior take's file (sol HIGH #1
    /// data-loss guard). The session layer still assigns unique, timestamped names;
    /// this is the belt-and-suspenders that makes any name collision non-destructive
    /// rather than an unconditional overwrite. The resolved path is exposed as `url`.
    public init(url requestedURL: URL, settings: RecordingSettings, sessionStart: SessionStart = .firstVideoFrame) throws {
        let url = RecorderFilePath.nonClobbering(requestedURL)
        self.url = url
        self.settings = settings
        self.sessionStart = sessionStart

        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Crash safety: re-write the movie header every few seconds so a hard
        // crash loses at most `fragmentInterval` seconds (QuickTime-only feature).
        writer.movieFragmentInterval = CMTime(seconds: settings.fragmentInterval, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = false

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoOutputSettings(settings))
        videoInput.expectsMediaDataInRealTime = true
        videoInput.mediaTimeScale = 60_000
        // No adaptor-side pool: buffers arrive already IOSurface-backed from PixelBufferPool.
        pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: nil
        )
        writer.add(videoInput)

        if settings.includeAudio {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: settings.audioSampleRate,
                AVNumberOfChannelsKey: settings.audioChannels,
                AVEncoderBitRateKey: settings.audioBitrate,
            ])
            audio.expectsMediaDataInRealTime = true
            writer.add(audio)
            audioInput = audio
        } else {
            audioInput = nil
        }
    }

    private static func videoOutputSettings(_ settings: RecordingSettings) -> [String: Any] {
        var out: [String: Any] = [
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
        ]

        // HDR path (additive): force HEVC Main10 + write Rec.2020/HLG color tags.
        // Overrides `codec` because 8-bit H.264/HEVC-Main can't carry a 10-bit
        // HDR master. The default `.sdr` branch below is unchanged.
        if settings.dynamicRange == .hdr {
            out[AVVideoCodecKey] = AVVideoCodecType.hevc
            out[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
            out[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: settings.videoBitrate,
                AVVideoMaxKeyFrameIntervalDurationKey: settings.keyframeInterval,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: settings.expectedFrameRate,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
            ]
            return out
        }

        switch settings.codec {
        case .h264:
            out[AVVideoCodecKey] = AVVideoCodecType.h264
            out[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: settings.videoBitrate,
                AVVideoMaxKeyFrameIntervalDurationKey: settings.keyframeInterval,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: settings.expectedFrameRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ]
        case .hevc:
            out[AVVideoCodecKey] = AVVideoCodecType.hevc
            out[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: settings.videoBitrate,
                AVVideoMaxKeyFrameIntervalDurationKey: settings.keyframeInterval,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: settings.expectedFrameRate,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
            ]
        case .proRes422:
            // ProRes is a fixed-quality intra codec: bitrate/keyframe knobs don't apply.
            out[AVVideoCodecKey] = AVVideoCodecType.proRes422
        }
        return out
    }

    /// Starts the writer. With `.fixed` session start the timeline zero is
    /// established immediately; with `.firstVideoFrame` it is deferred until
    /// the first appended frame.
    public func start() throws {
        try stateLock.withLock { s in
            guard s.state == .idle else { throw RecorderError.invalidState("start() in \(s.state)") }
            guard writer.startWriting() else {
                s.state = .failed
                throw RecorderError.startFailed(underlying: writer.error)
            }
            if case .fixed(let t) = sessionStart {
                writer.startSession(atSourceTime: t)
                s.sessionStartTime = t
            }
            s.state = .recording
        }
        log.info("recording started → \(self.url.lastPathComponent, privacy: .public)")
    }

    /// Appends one program frame. Non-blocking: if the writer input is busy
    /// (real-time mode), the frame is dropped and counted. A frame whose PTS
    /// is not strictly after the previously appended frame's PTS is rejected
    /// and counted (`Report.videoFramesRejectedForPTS`) — appending it would
    /// put the AVAssetWriter into `.failed` and lose the whole recording.
    public func append(_ frame: VideoFrame) {
        stateLock.withLock { s in
            guard s.state == .recording else { return }
            if let last = s.lastVideoPTS, CMTimeCompare(frame.pts, last) <= 0 {
                s.videoFramesRejectedForPTS &+= 1
                if s.videoFramesRejectedForPTS == 1 {
                    log.error("non-monotonic video PTS \(frame.pts.seconds, format: .fixed(precision: 6)) ≤ \(last.seconds, format: .fixed(precision: 6)) — frame rejected (counted)")
                }
                return
            }
            if s.sessionStartTime == nil {
                writer.startSession(atSourceTime: frame.pts)
                s.sessionStartTime = frame.pts
            }
            guard videoInput.isReadyForMoreMediaData else {
                s.videoFramesDropped &+= 1
                return
            }
            if pixelAdaptor.append(frame.pixelBuffer, withPresentationTime: frame.pts) {
                s.videoFramesWritten &+= 1
                s.lastVideoPTS = frame.pts
                let end = frame.duration.isValid && frame.duration.value > 0
                    ? CMTimeAdd(frame.pts, frame.duration)
                    : frame.pts
                s.lastVideoEnd = end
            } else {
                s.videoFramesDropped &+= 1
                if writer.status == .failed {
                    s.state = .failed
                    log.error("writer failed: \(String(describing: self.writer.error), privacy: .public)")
                }
            }
        }
    }

    /// Appends program audio (PTS in house time, same timeline as video).
    /// Audio arriving before the session started (i.e. before the first video
    /// frame under `.firstVideoFrame`) is dropped and counted — the writer
    /// session can only ever start on a video frame so the file leads with video.
    public func append(audio sampleBuffer: CMSampleBuffer) {
        stateLock.withLock { s in
            guard s.state == .recording, let audioInput else {
                s.audioBuffersDropped &+= 1
                return
            }
            guard s.sessionStartTime != nil else {
                s.audioBuffersDropped &+= 1
                return
            }
            // Same monotonicity protection as video: a backward audio PTS
            // would fail the writer and lose the recording.
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if let last = s.lastAudioPTS, CMTimeCompare(pts, last) <= 0 {
                s.audioBuffersDropped &+= 1
                return
            }
            guard audioInput.isReadyForMoreMediaData else {
                s.audioBuffersDropped &+= 1
                return
            }
            if audioInput.append(sampleBuffer) {
                s.audioBuffersWritten &+= 1
                s.lastAudioPTS = pts
            } else {
                s.audioBuffersDropped &+= 1
                if writer.status == .failed {
                    s.state = .failed
                    log.error("writer failed (audio): \(String(describing: self.writer.error), privacy: .public)")
                }
            }
        }
    }

    /// Finishes the recording cleanly and reports duration/bytes.
    public func finish() async throws -> Report {
        let (startTime, lastEnd): (CMTime?, CMTime?) = try stateLock.withLock { s in
            guard s.state == .recording else { throw RecorderError.invalidState("finish() in \(s.state)") }
            s.state = .finishing
            return (s.sessionStartTime, s.lastVideoEnd)
        }

        guard let startTime else {
            // Never got a frame: nothing valid to finalize.
            writer.cancelWriting()
            stateLock.withLock { $0.state = .failed }
            throw RecorderError.nothingRecorded
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        if let lastEnd {
            writer.endSession(atSourceTime: lastEnd)
        }
        await writer.finishWriting()

        guard writer.status == .completed else {
            stateLock.withLock { $0.state = .failed }
            throw RecorderError.writerFailed(underlying: writer.error)
        }

        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
        let report: Report = stateLock.withLock { s in
            s.state = .finished
            return Report(
                url: url,
                duration: CMTimeSubtract(lastEnd ?? startTime, startTime),
                bytesWritten: bytes,
                videoFramesWritten: s.videoFramesWritten,
                videoFramesDropped: s.videoFramesDropped,
                videoFramesRejectedForPTS: s.videoFramesRejectedForPTS,
                audioBuffersWritten: s.audioBuffersWritten,
                audioBuffersDropped: s.audioBuffersDropped
            )
        }
        log.info("recording finished: \(report.duration.seconds, format: .fixed(precision: 2))s, \(report.bytesWritten) bytes")
        return report
    }

    /// Abandons the recording (file is left as-is; fragments up to the last
    /// header rewrite remain playable).
    public func cancel() {
        stateLock.withLock { s in
            guard s.state == .recording else { return }
            s.state = .failed
            writer.cancelWriting()
        }
    }
}
