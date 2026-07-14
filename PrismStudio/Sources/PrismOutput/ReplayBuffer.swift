import AVFoundation
import CoreMedia
import Foundation
import PrismCore
import os

/// Instant-replay ring buffer (DESIGN §2.5 "Replay buffer + instant-replay
/// source").
///
/// Holds the last *N* seconds of **already-encoded** program frames — feed it
/// the very same `CMSampleBuffer`s that `ProgramEncoder` hands the recorder and
/// the stream (encode once, tap many). On `saveClip(to:)` it muxes the buffered
/// window into a fragmented `.mov` via passthrough `AVAssetWriter` (no re-encode).
///
/// **Keyframe retention — why the saved clip is decodable.** An H.264/HEVC
/// P-frame references earlier frames; if the buffer's leading frame were a
/// P-frame whose reference had already aged out, the clip would not decode from
/// frame 0. So the ring never drops past the *newest keyframe that still sits at
/// or before the window's start*: eviction removes a whole leading GOP only when
/// the following keyframe's PTS is still ≤ `newest − duration` (i.e. dropping it
/// keeps the full window covered by a keyframe-led buffer). Consequence: the
/// saved clip always begins on a sync sample and covers ≥ `duration` seconds
/// (up to one keyframe-interval more, because a clip can only start on a
/// keyframe). Any leading non-sync orphans (before the first keyframe ever seen)
/// are dropped immediately — they can never decode.
///
/// Threading: `append` is lock-guarded and cheap (append + trim), callable from
/// the encoder's delivery queue on the hot path. `saveClip` snapshots the ring
/// under the lock, releases it, then muxes off-thread — the render/encode thread
/// is never blocked by disk I/O.
public final class ReplayBuffer: @unchecked Sendable {
    public enum ReplayError: Error, CustomStringConvertible {
        /// `saveClip` called with nothing buffered yet.
        case empty
        /// A buffered sample carried no format description (cannot mux passthrough).
        case noFormatDescription
        case writerSetupFailed(underlying: Error?)
        case writerFailed(underlying: Error?)
        public var description: String {
            switch self {
            case .empty: return "replay buffer is empty — nothing to save"
            case .noFormatDescription: return "buffered sample has no CMFormatDescription"
            case .writerSetupFailed(let e): return "clip writer setup failed: \(String(describing: e))"
            case .writerFailed(let e): return "clip writer failed: \(String(describing: e))"
            }
        }
    }

    /// Result of a saved clip.
    public struct ClipReport: Sendable, CustomStringConvertible {
        public let url: URL
        /// Media duration of the saved window (last sample end − first sample PTS).
        public let duration: CMTime
        public let bytesWritten: Int64
        public let frameCount: Int
        public let keyframeCount: Int
        /// Audio samples muxed into the clip (0 when video-only).
        public let audioSampleCount: Int
        public var description: String {
            String(format: "ClipReport(%@ dur=%.3fs bytes=%lld frames=%d keyframes=%d audio=%d)",
                   url.lastPathComponent, duration.seconds, bytesWritten, frameCount, keyframeCount, audioSampleCount)
        }
    }

    /// Live snapshot of the ring (for a UI HUD).
    public struct Status: Sendable {
        public let frameCount: Int
        public let keyframeCount: Int
        /// Span currently retained (newest end − oldest PTS); ≥ configured
        /// duration once warmed up, a touch more due to GOP alignment.
        public let bufferedDuration: CMTime
        public let bytesBuffered: Int64
        public let leadsWithKeyframe: Bool
    }

    private struct Entry {
        let sample: CMSampleBuffer
        let pts: CMTime
        let end: CMTime
        let isKeyframe: Bool
        let bytes: Int
    }

    /// A buffered audio sample. Audio needs no keyframe bookkeeping — every LPCM
    /// or AAC frame is independently decodable — so the audio ring simply trims
    /// to the retention window and is interleaved by PTS at save time.
    private struct AudioEntry {
        let sample: CMSampleBuffer
        let pts: CMTime
        let end: CMTime
        let bytes: Int
    }

    private struct MutableState {
        var entries: [Entry] = []
        var bytes: Int64 = 0
        var keyframes: Int = 0
        var totalAppended: UInt64 = 0
        var audio: [AudioEntry] = []
        var audioBytes: Int64 = 0
    }

    /// Configured retention window (seconds of program covered).
    public let duration: CMTime
    /// Timescale used to build the retention window CMTime.
    private static let ts: CMTimeScale = 600
    private let fragmentInterval: Double
    private let state = OSAllocatedUnfairLock<MutableState>(initialState: MutableState())
    private let log = EngineLog.logger("output.replay")

    /// - Parameters:
    ///   - seconds: retention window; default 30 s (DESIGN §2.5).
    ///   - fragmentInterval: movie-fragment cadence for the saved `.mov`
    ///     (crash safety mirrors `MovieRecorder`); default 1 s.
    public init(seconds: Double = 30, fragmentInterval: Double = 1.0) {
        precondition(seconds > 0, "replay window must be positive")
        self.duration = CMTime(seconds: seconds, preferredTimescale: Self.ts)
        self.fragmentInterval = fragmentInterval
    }

    /// Appends one encoded program frame and trims the ring to the window,
    /// preserving a leading keyframe. Cheap + lock-guarded; safe from the
    /// encoder delivery queue.
    public func append(_ sample: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid else { return }
        let dur = CMSampleBufferGetDuration(sample)
        let end = (dur.isValid && dur.value > 0) ? CMTimeAdd(pts, dur) : pts
        let isKey = Self.isSyncSample(sample)
        let bytes = CMSampleBufferGetTotalSampleSize(sample)
        let entry = Entry(sample: sample, pts: pts, end: end, isKeyframe: isKey, bytes: bytes)

        state.withLock { s in
            // Reject a non-monotonic PTS (would corrupt the muxed timeline).
            if let last = s.entries.last, CMTimeCompare(pts, last.pts) <= 0 { return }
            s.entries.append(entry)
            s.bytes += Int64(bytes)
            if isKey { s.keyframes += 1 }
            s.totalAppended &+= 1
            Self.trim(&s, window: duration)
        }
    }

    /// Appends one program **audio** buffer (encoded or PCM, house PTS on the
    /// same timeline as the video) and trims the audio ring to the window.
    /// Additive to `append(_:)`: feed both to retain a clip *with sound*. Cheap
    /// + lock-guarded; safe from the audio delivery queue.
    public func appendAudio(_ sample: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid else { return }
        let dur = CMSampleBufferGetDuration(sample)
        let end = (dur.isValid && dur.value > 0) ? CMTimeAdd(pts, dur) : pts
        let bytes = CMSampleBufferGetTotalSampleSize(sample)
        let entry = AudioEntry(sample: sample, pts: pts, end: end, bytes: bytes)

        state.withLock { s in
            if let last = s.audio.last, CMTimeCompare(pts, last.pts) <= 0 { return }
            s.audio.append(entry)
            s.audioBytes += Int64(bytes)
            Self.trimAudio(&s, window: duration)
        }
    }

    /// Drops audio older than the retention window. Keyed off the newest audio
    /// PTS so audio retention tracks the video window (both share house time).
    private static func trimAudio(_ s: inout MutableState, window: CMTime) {
        guard let newest = s.audio.last else { return }
        let cutoff = CMTimeSubtract(newest.pts, window)
        while let first = s.audio.first, CMTimeCompare(first.end, cutoff) < 0 {
            s.audioBytes -= Int64(first.bytes)
            s.audio.removeFirst()
        }
    }

    /// Evicts aged frames while keeping the saved window keyframe-decodable.
    private static func trim(_ s: inout MutableState, window: CMTime) {
        guard let newest = s.entries.last else { return }
        let cutoff = CMTimeSubtract(newest.pts, window)

        // 1. Drop any leading orphans that precede the first keyframe — a clip
        //    can never start on a P-frame.
        while let first = s.entries.first, !first.isKeyframe {
            removeFront(&s)
        }

        // 2. Drop whole leading GOPs: remove [0 ..< nextKeyframe) as long as the
        //    NEXT keyframe still sits at or before the window start, so the ring
        //    stays led by a keyframe that covers the full [cutoff, newest] span.
        while true {
            guard let nextKey = s.entries.dropFirst().firstIndex(where: { $0.isKeyframe }) else { break }
            // nextKey is an index into s.entries (dropFirst keeps original indices).
            guard CMTimeCompare(s.entries[nextKey].pts, cutoff) <= 0 else { break }
            for _ in 0..<nextKey { removeFront(&s) }
        }
    }

    private static func removeFront(_ s: inout MutableState) {
        let e = s.entries.removeFirst()
        s.bytes -= Int64(e.bytes)
        if e.isKeyframe { s.keyframes -= 1 }
    }

    /// The absolute house-time span the ring currently retains
    /// (`oldest.pts … newest.end`), or `nil` when empty. Used by the Director's
    /// Cut post-roll capture to clamp a requested `[start, end]` window to what is
    /// actually buffered (and to detect a too-short ring / a not-yet-arrived
    /// post-roll at shutdown). Thread-safe.
    public var coveredWindow: (start: CMTime, end: CMTime)? {
        state.withLock { s in
            guard let first = s.entries.first, let last = s.entries.last else { return nil }
            return (first.pts, last.end)
        }
    }

    /// A live snapshot for a HUD.
    public var status: Status {
        state.withLock { s in
            let span: CMTime
            if let first = s.entries.first, let last = s.entries.last {
                span = CMTimeSubtract(last.end, first.pts)
            } else {
                span = .zero
            }
            return Status(
                frameCount: s.entries.count,
                keyframeCount: s.keyframes,
                bufferedDuration: span,
                bytesBuffered: s.bytes,
                leadsWithKeyframe: s.entries.first?.isKeyframe ?? false
            )
        }
    }

    /// Clears the ring (e.g. on scene reset / encoder restart).
    public func reset() {
        state.withLock { $0 = MutableState() }
    }

    /// Snapshots the **entire** buffered window and muxes it to a fragmented
    /// `.mov` at `url`, off the calling thread. The clip starts at time zero on
    /// a keyframe; if audio was fed via `appendAudio`, an audio track covering
    /// the same window is interleaved by PTS. If a file already exists at `url`
    /// the clip is written to a free, non-clobbering sibling (`name-2.mov`, …)
    /// instead of destroying it — the actual path is returned in `ClipReport.url`
    /// (sol #17 data-loss guard). Never deletes a prior clip.
    public func saveClip(to url: URL) async throws -> ClipReport {
        let (entries, audioAll): ([Entry], [AudioEntry]) = state.withLock { ($0.entries, $0.audio) }
        return try await mux(videoEntries: entries, audioAll: audioAll, to: url)
    }

    /// Saves only the **most recent `lastSeconds`** of buffered program — the
    /// "clip that moment" highlight extractor. Snapshots the ring under the
    /// lock (cheap), then selects the tail sub-window and encodes it via the
    /// same passthrough writer as `saveClip`.
    ///
    /// The saved window is keyframe-led and decodable: it begins at the **latest
    /// keyframe at or before `now − lastSeconds`**, so the clip covers the full
    /// requested span (up to one GOP more, since a clip can only open on a sync
    /// sample) and never starts on an undecodable P-frame — exactly the same
    /// retention invariant `trim` maintains for the whole ring.
    ///
    /// Robustness:
    ///  - `lastSeconds` larger than what is buffered is **clamped** to the whole
    ///    buffer (you get everything retained; no error) — the cutoff simply
    ///    falls before the oldest retained keyframe, selecting index 0.
    ///  - An empty buffer throws `ReplayError.empty` (typed, no crash).
    ///
    /// Off the append hot path / thread-safe: the only shared-state touch is the
    /// snapshot under the lock. Tail selection + disk I/O run afterward on the
    /// writer's own queue, so `append`/`appendAudio` are never blocked by a save
    /// and a concurrent append during the mux is safe — the snapshot is an
    /// immutable COW copy that later mutations don't touch.
    public func saveHighlight(lastSeconds: Double, to url: URL) async throws -> ClipReport {
        precondition(lastSeconds > 0, "lastSeconds must be positive")
        let (entries, audioAll): ([Entry], [AudioEntry]) = state.withLock { ($0.entries, $0.audio) }
        guard let last = entries.last else { throw ReplayError.empty }

        // Tail cutoff on the house timeline. Clamp is implicit: a cutoff before
        // the oldest retained keyframe leaves `startIndex` at 0 → whole buffer.
        let cutoff = CMTimeSubtract(last.end, CMTime(seconds: lastSeconds, preferredTimescale: Self.ts))
        var startIndex = 0
        for (i, e) in entries.enumerated() where e.isKeyframe && CMTimeCompare(e.pts, cutoff) <= 0 {
            startIndex = i
        }
        let tail = Array(entries[startIndex...])
        return try await mux(videoEntries: tail, audioAll: audioAll, to: url)
    }

    /// Saves the buffered program spanning an **explicit house-time window**
    /// `[startPTS, endPTS]` — the Director's Cut "moment + post-roll" extractor.
    /// Unlike `saveHighlight(lastSeconds:)` (a trailing window ending at *now*),
    /// this pins both edges to absolute PTS, so a highlight peak captured earlier
    /// yields `[peak − preRoll, peak + postRoll]` regardless of how much the ring
    /// has advanced since — the run-up AND the payoff, not just the run-up.
    ///
    /// Keyframe-led + decodable: the clip begins at the **latest keyframe at or
    /// before `startPTS`** (same invariant as `trim`/`saveHighlight`), so it never
    /// opens on an undecodable P-frame and covers the full requested span (up to
    /// one GOP more on the leading edge).
    ///
    /// Clamping (never throws on a short ring):
    ///  - `startPTS` before the oldest retained frame → starts at index 0.
    ///  - `endPTS` after the newest buffered frame (e.g. the post-roll has not yet
    ///    arrived, or shutdown truncated it) → ends at the newest frame.
    /// The actually-covered span is reported in `ClipReport.duration`; compare it
    /// (or `coveredWindow`) against the request to detect a clamp. An empty buffer
    /// throws `ReplayError.empty`.
    ///
    /// Off the append hot path / thread-safe (only shared touch is the snapshot).
    public func saveHighlight(from startPTS: CMTime, to endPTS: CMTime,
                              to url: URL) async throws -> ClipReport {
        let (entries, audioAll): ([Entry], [AudioEntry]) = state.withLock { ($0.entries, $0.audio) }
        guard !entries.isEmpty else { throw ReplayError.empty }

        // Leading edge: latest keyframe at/before startPTS (clamp to 0 when the
        // request precedes the oldest retained keyframe).
        var startIndex = 0
        for (i, e) in entries.enumerated() where e.isKeyframe && CMTimeCompare(e.pts, startPTS) <= 0 {
            startIndex = i
        }
        // Trailing edge: last entry whose PTS is at/before endPTS (clamp to the
        // newest frame when the request runs past the buffer). Always ≥ startIndex.
        var endIndex = startIndex
        for (i, e) in entries.enumerated() where i >= startIndex {
            if CMTimeCompare(e.pts, endPTS) <= 0 { endIndex = i } else { break }
        }
        let window = Array(entries[startIndex...endIndex])
        return try await mux(videoEntries: window, audioAll: audioAll, to: url)
    }

    /// Muxes a snapshot of video entries (+ any overlapping audio) into a
    /// fragmented `.mov`. Shared by `saveClip` (whole window), `saveHighlight`
    /// (recent tail), and the windowed `saveHighlight(from:to:)`; runs entirely
    /// off the append hot path.
    private func mux(videoEntries entries: [Entry], audioAll: [AudioEntry], to url: URL) async throws -> ClipReport {
        guard let first = entries.first, let last = entries.last else {
            throw ReplayError.empty
        }
        guard let formatHint = CMSampleBufferGetFormatDescription(first.sample) else {
            throw ReplayError.noFormatDescription
        }
        let duration = CMTimeSubtract(last.end, first.pts)
        let keyframeCount = entries.reduce(0) { $0 + ($1.isKeyframe ? 1 : 0) }

        // sol #17 (DATA LOSS): two replay/highlight clips saved in the same second
        // reused ONE filename (second-resolution timestamp, no disambiguation) and
        // the writer unconditionally deleted whatever sat at that path → the second
        // clip destroyed the first. Resolve a free, non-clobbering sibling before
        // writing so a save NEVER overwrites an existing clip; the resolved path is
        // reported back to the caller as `ClipReport.url`. (Belt-and-suspenders with
        // the App's per-save unique naming — same last-line guard the OO recorders
        // use.) Independent of the writer's own stale-file handling.
        let target = RecorderFilePath.nonClobbering(url)

        // Keep audio that overlaps the video clip window [origin, clipEnd).
        // Origin = the clip's first video PTS (its timeline zero). The *first*
        // in-window audio buffer almost always STRADDLES the origin
        // (pts < origin < end): the video window starts on a keyframe, not an
        // audio-packet boundary. Left untrimmed, `EncodedClipWriter.retime`
        // subtracts `origin` → a negative PTS → `AVAssetWriterInput.append`
        // rejects it → the whole `saveClip` throws (finding #3). So trim every
        // straddling buffer at the boundary: drop its pre-origin samples so the
        // surviving audio starts at ≥ origin (retimes to ≥ 0, never negative).
        // Symmetrically, the *last* in-window audio buffer may STRADDLE the
        // trailing edge (pts < clipEnd < end): the video window ends on a frame
        // boundary, not an audio-packet boundary. Written in full, that buffer's
        // tail runs PAST the video clip end and past `ClipReport.duration`, so
        // the saved audio track outlasts the picture. Trim every straddler at
        // `clipEnd` too, so the muxed audio ends at/before the video window.
        let origin = first.pts
        let clipEnd = last.end
        let audioSamples: [CMSampleBuffer] = audioAll
            .filter { CMTimeCompare($0.end, origin) > 0 && CMTimeCompare($0.pts, clipEnd) < 0 }
            .compactMap { Self.trimLeadingToOrigin($0.sample, origin: origin) }
            .compactMap { Self.trimTrailingToClipEnd($0, clipEnd: clipEnd) }
        let audioFormatHint = audioSamples.first.flatMap { CMSampleBufferGetFormatDescription($0) }

        let writer = try EncodedClipWriter(url: target, sourceFormatHint: formatHint,
                                           audioFormatHint: audioFormatHint,
                                           fragmentInterval: fragmentInterval)
        let bytes = try await writer.write(videoSamples: entries.map { $0.sample },
                                           audioSamples: audioSamples,
                                           startingAt: origin)
        log.info("saved replay clip \(target.lastPathComponent, privacy: .public): \(duration.seconds, format: .fixed(precision: 3))s \(entries.count) frames \(audioSamples.count) audio \(bytes) bytes")
        return ClipReport(url: target, duration: duration, bytesWritten: bytes,
                          frameCount: entries.count, keyframeCount: keyframeCount,
                          audioSampleCount: audioSamples.count)
    }

    /// Trims the leading portion of an audio sample buffer that falls before
    /// `origin`, returning a buffer whose first sample starts at ≥ `origin`.
    ///
    /// - Returns the buffer unchanged when it already starts at/after `origin`.
    /// - Returns `nil` when it lies entirely before `origin` (nothing to keep)
    ///   or when it cannot be split (non-uniform/zero duration) — dropping is
    ///   always safe: it degrades to a fractionally later audio start, never a
    ///   failed `saveClip`.
    ///
    /// Works for any *interleaved* audio (LPCM or packetized AAC): the drop
    /// count is derived from the buffer's own per-sample duration, and
    /// `CMSampleBufferCopySampleBufferForRange` recomputes the output PTS from
    /// the retained sample range — so the result's PTS is `≥ origin` and, after
    /// `EncodedClipWriter.retime`, `≥ 0`. (Non-interleaved audio is explicitly
    /// unsupported by that API, and the program mix is interleaved.)
    static func trimLeadingToOrigin(_ sample: CMSampleBuffer, origin: CMTime) -> CMSampleBuffer? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        // Already at/after the clip origin — no negative PTS possible; keep as-is.
        if CMTimeCompare(pts, origin) >= 0 { return sample }

        let numSamples = CMSampleBufferGetNumSamples(sample)
        let dur = CMSampleBufferGetDuration(sample)
        guard numSamples > 0, dur.isValid, dur.value > 0 else { return nil }

        // Uniform per-sample duration (LPCM: 1/rate; AAC: 1024/rate).
        let perSample = dur.seconds / Double(numSamples)
        guard perSample > 0 else { return nil }

        // Ceil so the first surviving sample lands at/after origin (never before).
        let lead = origin.seconds - pts.seconds
        var drop = Int((lead / perSample).rounded(.up))
        drop = max(0, min(drop, numSamples))
        if drop >= numSamples { return nil } // entire buffer precedes origin

        var out: CMSampleBuffer?
        let status = CMSampleBufferCopySampleBufferForRange(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleRange: CFRange(location: drop, length: numSamples - drop),
            sampleBufferOut: &out)
        guard status == noErr, let out else { return nil }
        return out
    }

    /// Trims the trailing portion of an audio sample buffer that extends past
    /// `clipEnd` (the video window's end), returning a buffer whose last sample
    /// ends at ≤ `clipEnd`.
    ///
    /// - Returns the buffer unchanged when it already ends at/before `clipEnd`,
    ///   or when it cannot be split (non-uniform/zero duration) — in the
    ///   unsplittable case a fractional overshoot is preferable to dropping an
    ///   in-window buffer entirely, and it can never corrupt the write.
    /// - Returns `nil` only when nothing survives (the whole buffer sits at/after
    ///   `clipEnd`, which the overlap filter already excludes).
    ///
    /// Mirror of `trimLeadingToOrigin`: the retained sample count is derived from
    /// the buffer's own per-sample duration and `CMSampleBufferCopySampleBufferForRange`
    /// keeps `[0, keep)`, so the result ends at/before `clipEnd` and the saved
    /// audio track never outlasts the video clip.
    static func trimTrailingToClipEnd(_ sample: CMSampleBuffer, clipEnd: CMTime) -> CMSampleBuffer? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let numSamples = CMSampleBufferGetNumSamples(sample)
        let dur = CMSampleBufferGetDuration(sample)
        guard numSamples > 0, dur.isValid, dur.value > 0 else { return sample }

        let end = CMTimeAdd(pts, dur)
        // Already ends at/before the clip window — no negative overshoot; keep.
        if CMTimeCompare(end, clipEnd) <= 0 { return sample }

        // Uniform per-sample duration (LPCM: 1/rate; AAC: 1024/rate).
        let perSample = dur.seconds / Double(numSamples)
        guard perSample > 0 else { return sample }

        // Floor so the last surviving sample ends at/before clipEnd (never after).
        let span = clipEnd.seconds - pts.seconds
        var keep = Int((span / perSample).rounded(.down))
        keep = max(0, min(keep, numSamples))
        if keep <= 0 { return nil }              // whole buffer at/after clipEnd
        if keep >= numSamples { return sample }  // nothing to trim (defensive)

        var out: CMSampleBuffer?
        let status = CMSampleBufferCopySampleBufferForRange(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleRange: CFRange(location: 0, length: keep),
            sampleBufferOut: &out)
        guard status == noErr, let out else { return nil }
        return out
    }

    /// True when the sample is a sync (key) frame. Encoded samples mark
    /// non-keyframes with `kCMSampleAttachmentKey_NotSync == true`; absence of
    /// the attachment means a sync sample.
    static func isSyncSample(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[CFString: Any]], let first = attachments.first else {
            return true
        }
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSync
        }
        return true
    }
}

/// Internal shared helper: writes a batch of already-encoded video
/// `CMSampleBuffer`s into a fragmented QuickTime `.mov` in passthrough mode
/// (no re-encode). Factored out of `ReplayBuffer` so any future
/// "mux-encoded-samples" path (e.g. a segment recorder) reuses the same
/// crash-safe fragmented-writer setup. Deliberately independent of
/// `MovieRecorder` (which owns the *encode*-on-write path) so nothing here
/// alters that type's behavior.
final class EncodedClipWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let url: URL
    private let feedQueue = DispatchQueue(label: "studio.prism.output.replay.mux")

    /// Per-input cursor (mutated only on `feedQueue`).
    private final class FeedCursor { var index = 0 }
    /// Coordinates completion across the video + optional audio inputs. Every
    /// method runs on the single serial `feedQueue`, so no extra locking.
    private final class Coordinator {
        private var remaining: Int
        private var done = false
        init(_ inputs: Int) { remaining = inputs }
        func finishOne(_ cont: CheckedContinuation<Void, Error>) {
            guard !done else { return }
            remaining -= 1
            if remaining == 0 { done = true; cont.resume() }
        }
        func fail(_ cont: CheckedContinuation<Void, Error>, _ error: Error) {
            guard !done else { return }
            done = true
            cont.resume(throwing: error)
        }
    }

    init(url: URL, sourceFormatHint: CMFormatDescription,
         audioFormatHint: CMFormatDescription? = nil, fragmentInterval: Double) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw ReplayBuffer.ReplayError.writerSetupFailed(underlying: error)
        }
        writer.movieFragmentInterval = CMTime(seconds: fragmentInterval, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = false
        // Passthrough: nil outputSettings mux the encoded/PCM bitstream verbatim.
        input = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                   sourceFormatHint: sourceFormatHint)
        input.expectsMediaDataInRealTime = false
        writer.add(input)

        if let audioFormatHint {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                           sourceFormatHint: audioFormatHint)
            audio.expectsMediaDataInRealTime = false
            writer.add(audio)
            audioInput = audio
        } else {
            audioInput = nil
        }
    }

    /// Writes video (+ optional audio) re-timed so `startingAt` maps to zero,
    /// interleaved by the writer, then finalizes.
    func write(videoSamples: [CMSampleBuffer], audioSamples: [CMSampleBuffer],
               startingAt origin: CMTime) async throws -> Int64 {
        guard writer.startWriting() else {
            throw ReplayBuffer.ReplayError.writerSetupFailed(underlying: writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        let coordinator = Coordinator(audioInput != nil ? 2 : 1)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            drive(input, samples: videoSamples, origin: origin, coordinator: coordinator, cont: cont)
            if let audioInput {
                drive(audioInput, samples: audioSamples, origin: origin, coordinator: coordinator, cont: cont)
            }
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ReplayBuffer.ReplayError.writerFailed(underlying: writer.error)
        }
        return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
    }

    /// Feeds one input to exhaustion on `feedQueue`, resuming `cont` via the
    /// shared coordinator when every input is finished (or failed).
    private func drive(_ writerInput: AVAssetWriterInput, samples: [CMSampleBuffer],
                       origin: CMTime, coordinator: Coordinator,
                       cont: CheckedContinuation<Void, Error>) {
        let cursor = FeedCursor()
        writerInput.requestMediaDataWhenReady(on: feedQueue) { [self] in
            while writerInput.isReadyForMoreMediaData {
                guard cursor.index < samples.count else {
                    writerInput.markAsFinished()
                    coordinator.finishOne(cont)
                    return
                }
                let retimed = Self.retime(samples[cursor.index], offsetBy: origin)
                if !writerInput.append(retimed) {
                    coordinator.fail(cont, ReplayBuffer.ReplayError.writerFailed(underlying: writer.error))
                    return
                }
                cursor.index += 1
            }
        }
    }

    /// Returns a copy of `sample` with every timing stamp shifted so `origin`
    /// becomes zero (clean clip timeline). Falls back to the original if the
    /// copy fails.
    private static func retime(_ sample: CMSampleBuffer, offsetBy origin: CMTime) -> CMSampleBuffer {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0,
                                                      arrayToFill: nil,
                                                      entriesNeededOut: &count) == noErr, count > 0 else {
            return sample
        }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count,
                                                     arrayToFill: &timings,
                                                     entriesNeededOut: &count) == noErr else {
            return sample
        }
        for i in 0..<timings.count {
            if timings[i].presentationTimeStamp.isValid {
                timings[i].presentationTimeStamp = CMTimeSubtract(timings[i].presentationTimeStamp, origin)
            }
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeSubtract(timings[i].decodeTimeStamp, origin)
            }
        }
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                    sampleBuffer: sample,
                                                    sampleTimingEntryCount: count,
                                                    sampleTimingArray: &timings,
                                                    sampleBufferOut: &copy) == noErr,
              let copy else {
            return sample
        }
        return copy
    }
}
