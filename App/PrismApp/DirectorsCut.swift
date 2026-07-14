import AVFoundation
import CoreMedia
import Foundation
import os

import PrismAudio
import PrismDirector
import PrismOutput

// MARK: - Director's Cut support types (flagship slice 2)
//
// The flagship "Director's Cut" (see `WORLD_CLASS_VISION.md`) turns the stream's
// already-built live signals into scored highlight moments and auto-saves the
// horizontal clip when a moment crosses threshold. Slice 1 built the pure
// `HighlightDirector` scoring engine; this slice wires the App's live signals
// into it (in `AppEngine`) and adds the auto-save.
//
// These small, App-side, pure/decoupled helpers keep `AppEngine`'s wiring thin
// and independently unit-testable:
//   • `HighlightFeeds.chain`        — the non-clobbering callback chain used to
//                                     add the highlight feed onto a source
//                                     callback that may already be set.
//   • `HighlightCaptionParser`      — pure caption-text → laughter/keyword scoring.
//   • `HighlightClipSaving`         — the auto-save seam (real `ReplayBuffer`, or a
//                                     mock in tests).
//   • `HighlightAutoSaver`          — bounded-concurrency guard so a burst of
//                                     highlights never spawns unbounded saves.

// MARK: - Callback chaining (preserve existing handlers)

/// Composes source callbacks without clobbering. The wired live sources
/// (`TransientDetector.onTransient`, `LiveCaptioner.onCaption`, …) may already
/// carry a handler (the reactive-trigger effect, the caption overlay); the
/// flagship must ADD its feed, not replace them. `chain` returns a closure that
/// runs the existing handler **first**, then the added feed — so both fire, in
/// order, and a `nil` existing handler is simply skipped.
enum HighlightFeeds {
    static func chain<T>(_ existing: (@Sendable (T) -> Void)?,
                         _ added: @escaping @Sendable (T) -> Void) -> @Sendable (T) -> Void {
        { value in
            existing?(value)
            added(value)
        }
    }
}

// MARK: - Caption scoring (pure)

/// Pure classification of a caption line into a highlight signal. Laughter tokens
/// ("haha", "lol", "😂", …) map to `.captionLaughter`; excitement keywords
/// ("wow", "insane", "let's go", …) and exclamation density map to
/// `.captionKeyword`. Returns `nil` for a neutral line (no signal). Deterministic
/// and case-insensitive so the wiring layer and tests share one mapping.
enum HighlightCaptionParser {
    struct Classification: Equatable, Sendable {
        let kind: HighlightSignal.Kind
        /// Normalized 0…1 intensity (clamped).
        let intensity: Double
    }

    /// Laughter evidence — the strongest "that was funny" cue.
    static let laughterTokens: [String] = [
        "haha", "hehe", "lol", "lmao", "lmfao", "rofl", "😂", "🤣", "😆", "😹",
    ]

    /// Excitement / hype keywords — a caption that reads like a big moment.
    static let excitementKeywords: [String] = [
        "wow", "omg", "insane", "let's go", "lets go", "no way", "unbelievable",
        "amazing", "incredible", "clutch", "huge", "goal", "let’s go",
    ]

    static func classify(_ text: String) -> Classification? {
        let lower = text.lowercased()

        // Laughter wins when present (a funnier, sharper highlight cue than hype).
        var laughCount = 0
        for token in laughterTokens { laughCount += occurrences(of: token, in: lower) }
        if laughCount > 0 {
            let intensity = min(1.0, 0.8 + 0.1 * Double(laughCount - 1))
            return Classification(kind: .captionLaughter, intensity: intensity)
        }

        // Otherwise score excitement from keyword hits + exclamation density.
        var keywordHits = 0
        for keyword in excitementKeywords where lower.contains(keyword) { keywordHits += 1 }
        let bangs = min(4, text.reduce(0) { $0 + ($1 == "!" ? 1 : 0) })
        let raw = 0.4 * Double(keywordHits) + 0.15 * Double(bangs)
        if raw > 0 {
            return Classification(kind: .captionKeyword, intensity: min(1.0, max(0.2, raw)))
        }
        return nil
    }

    /// Non-overlapping occurrences of `needle` in `haystack` (both already lowercased).
    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: range) {
            count += 1
            range = found.upperBound..<haystack.endIndex
        }
        return count
    }
}

// MARK: - Clip-saving seam (windowed — moment + post-roll)

/// The horizontal-clip source the flagship extracts a highlight window from. The
/// real `ReplayBuffer` conforms (below); tests inject a mock so the capture path
/// is verified without touching disk or racing the real muxer.
///
/// Slice-3a correction: the window is an **explicit house-PTS span** `[start,
/// end]`, not a trailing `lastSeconds` ending at *now*. A highlight peak fires,
/// the save is scheduled `postRoll` seconds later, and the window
/// `[peak − preRoll, peak + postRoll]` is pinned to absolute PTS — capturing the
/// run-up AND the payoff. `availableWindow` is the ring's current coverage, used
/// to clamp a request to what is buffered (a too-short ring, or a post-roll that
/// has not yet arrived / was truncated by shutdown).
protocol HighlightClipSaving: Sendable {
    /// The absolute house-time span currently retained, or `nil` when empty.
    var availableWindow: (start: CMTime, end: CMTime)? { get }
    /// Save the program window `[start, end]` (house PTS) to `url`, returning the
    /// URL actually written (the muxer resolves a non-clobbering sibling).
    func saveHighlightWindow(from start: CMTime, to end: CMTime, to url: URL) async throws -> URL
}

extension ReplayBuffer: HighlightClipSaving {
    var availableWindow: (start: CMTime, end: CMTime)? { coveredWindow }
    func saveHighlightWindow(from start: CMTime, to end: CMTime, to url: URL) async throws -> URL {
        try await saveHighlight(from: start, to: end, to: url).url
    }
}

// MARK: - Vertical (9:16) production seam

/// Produces the paired **9:16** asset for a highlight. Slice-3a produces it by
/// reframing the already-saved horizontal (16:9) clip via a centered hero-fill
/// crop — the "reframe the horizontal via the existing reframe path" the flagship
/// spec names when a dedicated vertical program ring isn't the source. The 9:16
/// SUBJECT-tracking auto-reframe (Center-Stage-style speaker follow) is the NEXT
/// slice (3b); a centered crop is the accepted 3a behaviour. Tests inject a mock.
protocol VerticalHighlightProducing: Sendable {
    func reframeToVertical(horizontal: URL, to url: URL) async throws -> URL
}

/// Default production reframer: crops a 16:9 clip to 9:16 (default 1080×1920)
/// with a centered hero-fill transform (scale to fill the vertical canvas height,
/// centre-crop the width) and carries the master-mix audio track through
/// untouched (preserve-first). One re-encode via `AVAssetExportSession`; the
/// heavy compositor reframe map governs the LIVE vertical program, while this
/// file-level crop is the cheapest correct clip-time analogue for 3a.
final class AVFoundationVerticalReframer: VerticalHighlightProducing {
    enum ReframeError: Error, CustomStringConvertible {
        case noVideoTrack, exportSetupFailed, exportFailed(Error?)
        var description: String {
            switch self {
            case .noVideoTrack: return "horizontal clip has no video track to reframe"
            case .exportSetupFailed: return "vertical export session could not be created"
            case .exportFailed(let e): return "vertical export failed: \(String(describing: e))"
            }
        }
    }

    let width: Int
    let height: Int
    init(width: Int = 1080, height: Int = 1920) { self.width = width; self.height = height }

    func reframeToVertical(horizontal src: URL, to url: URL) async throws -> URL {
        let asset = AVURLAsset(url: src)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ReframeError.noVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let nominalFPS = try await track.load(.nominalFrameRate)

        let renderSize = CGSize(width: width, height: height)
        // Display-oriented source dimensions (after the track's preferred transform).
        let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(preferred)
        let orientedW = abs(orientedRect.width)
        let orientedH = abs(orientedRect.height)
        guard orientedW > 0, orientedH > 0 else { throw ReframeError.noVideoTrack }

        // Hero-fill: scale so the source HEIGHT fills the 9:16 canvas, then centre
        // the (wider) 16:9 content horizontally — a centre crop. Subject-tracking
        // offset is slice 3b; centre is the 3a default.
        let scale = renderSize.height / orientedH
        let croppedW = orientedW * scale
        let tx = (renderSize.width - croppedW) / 2
        let transform = preferred
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: 0))

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        instruction.layerInstructions = [layer]

        let comp = AVMutableVideoComposition()
        comp.renderSize = renderSize
        let fps = nominalFPS > 0 ? nominalFPS : 60
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        comp.instructions = [instruction]

        // Non-clobbering last-line guard (mirrors the horizontal path / recorders).
        let target = RecorderFilePath.nonClobbering(url)
        guard let export = AVAssetExportSession(asset: asset,
                                                presetName: AVAssetExportPresetHighestQuality) else {
            throw ReframeError.exportSetupFailed
        }
        export.outputURL = target
        export.outputFileType = .mov
        export.videoComposition = comp   // audio (master mix) carried through untouched

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            export.exportAsynchronously {
                switch export.status {
                case .completed: cont.resume()
                default: cont.resume(throwing: ReframeError.exportFailed(export.error))
                }
            }
        }
        return target
    }
}

// MARK: - Paired H+V outcome

/// The result of a paired capture: the horizontal (16:9) clip always, the
/// vertical (9:16) clip when its reframe succeeded (else `nil` + `verticalError`
/// so the candidate records a partial). The horizontal failing throws (the whole
/// unit fails); the vertical failing degrades to a horizontal-only partial.
struct PairedClipOutcome: Sendable {
    let horizontal: URL
    let vertical: URL?
    let verticalError: String?
}

// MARK: - Bounded-concurrency auto-saver

/// Bounds how many paired captures run at once. `HighlightDirector` fires
/// `onHighlight` per crossing moment; a burst could spawn many concurrent
/// muxer + reframe tasks. This admits at most `maxInFlight` units and drops
/// (counts) the rest — an in-flight guard. Each admitted unit runs its own
/// snapshot/mux/export, so admitted units run safely in parallel.
final class HighlightAutoSaver: @unchecked Sendable {
    struct Metrics: Sendable, Equatable {
        var requested = 0
        var started = 0
        var dropped = 0
        var succeeded = 0
        var failed = 0
        /// Peak number of units observed in flight at once (≤ `maxInFlight`).
        var maxConcurrent = 0
    }

    private struct S { var inFlight = 0; var metrics = Metrics() }
    private let lock = OSAllocatedUnfairLock(initialState: S())

    let maxInFlight: Int

    init(maxInFlight: Int) { self.maxInFlight = max(1, maxInFlight) }

    var metrics: Metrics { lock.withLock { $0.metrics } }

    /// Admit one async unit of work when fewer than `maxInFlight` are running,
    /// else drop it. Returns whether it was admitted. `onResult` runs when an
    /// admitted unit finishes (any thread).
    @discardableResult
    func admit<T: Sendable>(_ op: @escaping @Sendable () async throws -> T,
                            onResult: @escaping @Sendable (Result<T, Error>) -> Void) -> Bool {
        let admitted: Bool = lock.withLock { s in
            s.metrics.requested += 1
            guard s.inFlight < maxInFlight else {
                s.metrics.dropped += 1
                return false
            }
            s.inFlight += 1
            s.metrics.started += 1
            if s.inFlight > s.metrics.maxConcurrent { s.metrics.maxConcurrent = s.inFlight }
            return true
        }
        guard admitted else { return false }

        Task.detached { [weak self] in
            let result: Result<T, Error>
            do { result = .success(try await op()) }
            catch { result = .failure(error) }
            self?.lock.withLock { s in
                s.inFlight -= 1
                switch result {
                case .success: s.metrics.succeeded += 1
                case .failure: s.metrics.failed += 1
                }
            }
            onResult(result)
        }
        return true
    }
}

// MARK: - Highlight candidate model + store (the Review & Finish data model)

/// Which aspect variant the human chose to finish/export. The capture path always
/// produces the 16:9 horizontal; the 9:16 vertical is the reframed sibling.
enum HighlightAspect: String, Codable, Sendable, CaseIterable, Identifiable {
    case horizontal   // 16:9
    case vertical     // 9:16
    var id: String { rawValue }
    var label: String { self == .horizontal ? "16:9" : "9:16" }
    var toggled: HighlightAspect { self == .horizontal ? .vertical : .horizontal }
}

/// Burned-caption style for the exported clip. String-raw so it round-trips in the
/// sidecar and drives a simple `.menu` picker in the review UI.
enum HighlightCaptionStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case clean       // minimal, no background
    case boxed       // solid caption bar
    case karaoke     // word-highlight
    case bold        // large bold pop
    var id: String { rawValue }
    var label: String {
        switch self {
        case .clean: return "Clean"
        case .boxed: return "Boxed"
        case .karaoke: return "Karaoke"
        case .bold: return "Bold Pop"
        }
    }
    static let defaultStyle: HighlightCaptionStyle = .boxed
}

/// One persisted Director's Cut highlight candidate — the record the "Review &
/// Finish" UI consumes. Slice-2 kept only `lastHighlightURL` (the most recent
/// clip); slice-3a persists EVERY candidate of a session with its full provenance
/// and both paired asset URLs; slice-3c adds the human-review edits (approve/
/// reject, trim, caption, chosen aspect).
///
/// `Codable` for the on-disk sidecar (round-trips 1:1). Times are house-time
/// seconds (the engine's math clock), never wall-clock. The slice-3c review fields
/// are all OPTIONAL so a slice-3a sidecar decodes unchanged (missing → nil).
struct HighlightCandidate: Codable, Identifiable, Equatable, Sendable {
    /// Lifecycle of a candidate's assets + human review.
    enum State: String, Codable, Sendable {
        case scheduled   // peak fired; save deferred until post-roll elapses
        case saving      // post-roll elapsed; extracting + reframing
        case saved       // both H and V produced (ready to review)
        case partial     // H produced, V (reframe) failed (ready to review, H-only)
        case failed      // H extraction failed (no assets)
        case approved    // human approved — ready to export (slice-3c)
        case rejected    // human rejected — dropped from the finish queue (slice-3c)
    }

    let id: UUID
    /// Peak instant that anchored this highlight (house seconds).
    let peakSeconds: Double
    /// Saved window `[start, end]` (house seconds) = `[peak − preRoll, peak + postRoll]`.
    let windowStart: Double
    let windowEnd: Double
    /// Peak momentary score.
    let score: Double
    /// Dominant signal kind ("audioTransient" / "captionLaughter" / …) — the reason.
    let reason: String
    /// Horizontal (16:9) asset once written.
    var horizontalURL: URL?
    /// Vertical (9:16) asset once reframed.
    var verticalURL: URL?
    var state: State
    /// A human note when the window was clamped (short ring / shutdown flush) or a
    /// partial/failed asset outcome. `nil` on a clean full-window save.
    var note: String?

    // MARK: Review & Finish edits (slice-3c) — all optional so a slice-3a sidecar
    // decodes 1:1 (a missing key → nil → the captured default is used).

    /// Human-adjusted trim IN point (house seconds), clamped to `[windowStart,
    /// windowEnd]`. `nil` → use `windowStart` (no trim).
    var trimStart: Double?
    /// Human-adjusted trim OUT point (house seconds), clamped to `[windowStart,
    /// windowEnd]`, always ≥ `effectiveStart`. `nil` → use `windowEnd`.
    var trimEnd: Double?
    /// Human-corrected caption text to burn on export. `nil` → none set.
    var captionText: String?
    /// Chosen burned-caption style. `nil` → `HighlightCaptionStyle.defaultStyle`.
    var captionStyle: HighlightCaptionStyle?
    /// Which aspect variant the human chose to finish. `nil` → `defaultAspect`
    /// (vertical when a 9:16 asset exists, else horizontal).
    var selectedAspect: HighlightAspect?

    var windowDuration: Double { max(0, windowEnd - windowStart) }

    // MARK: Effective (edited-or-default) values the UI + export read.

    /// Effective trim IN — the human's `trimStart` or the captured window start.
    var effectiveStart: Double { trimStart ?? windowStart }
    /// Effective trim OUT — never before `effectiveStart`.
    var effectiveEnd: Double { max(effectiveStart, trimEnd ?? windowEnd) }
    /// Effective clip duration after trim.
    var effectiveDuration: Double { max(0, effectiveEnd - effectiveStart) }
    /// Effective caption style (falls back to the default).
    var effectiveCaptionStyle: HighlightCaptionStyle { captionStyle ?? .defaultStyle }
    /// True when at least one finished asset exists to review/export.
    var hasFinishableAsset: Bool { horizontalURL != nil || verticalURL != nil }
    /// The default aspect: vertical when a 9:16 asset exists, else horizontal.
    var defaultAspect: HighlightAspect { verticalURL != nil ? .vertical : .horizontal }
    /// The aspect the human is finishing (chosen or default).
    var effectiveAspect: HighlightAspect { selectedAspect ?? defaultAspect }
    /// The asset URL for a given aspect (may be `nil` if that variant wasn't made).
    func variantURL(_ aspect: HighlightAspect) -> URL? {
        aspect == .horizontal ? horizontalURL : verticalURL
    }
    /// The asset URL for the human's chosen aspect.
    var finishURL: URL? { variantURL(effectiveAspect) }
    /// Short human status for the queue row.
    var reviewStatusLabel: String {
        switch state {
        case .scheduled: return "Scheduled"
        case .saving: return "Saving…"
        case .saved: return "Ready"
        case .partial: return "Ready (16:9 only)"
        case .failed: return "Failed"
        case .approved: return "Approved"
        case .rejected: return "Rejected"
        }
    }
}

/// The on-disk sidecar payload — an ordered list of all candidates of one
/// session. Written next to the clips so candidates survive relaunch (a future
/// Review UI reopens a past session by loading this file).
struct HighlightCandidateSidecar: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version: Int = HighlightCandidateSidecar.currentVersion
    var sessionID: UUID
    var candidates: [HighlightCandidate]
}

/// An ordered, observable-friendly store of the session's highlight candidates,
/// with a lightweight JSON sidecar. Thread-safe (all state behind one lock);
/// pure of any engine type so it unit-tests in isolation. The App mirrors
/// `all()` into a `@Published` for the UI on each mutation.
///
/// Sidecar discipline: the file path is fixed *per session*
/// (`.prism-highlights-<sessionID>.json`), so two concurrent sessions never
/// clobber each other; within a session the store rewrites its own file
/// atomically on each change.
final class HighlightCandidateStore: @unchecked Sendable {
    let sessionID: UUID
    private let lock = OSAllocatedUnfairLock(initialState: [HighlightCandidate]())

    init(sessionID: UUID = UUID()) { self.sessionID = sessionID }

    /// All candidates in insertion order.
    func all() -> [HighlightCandidate] { lock.withLock { $0 } }

    /// Append a new candidate (insertion order preserved).
    func append(_ candidate: HighlightCandidate) {
        lock.withLock { $0.append(candidate) }
    }

    /// Mutate a candidate in place by id (no-op if absent). Returns the updated
    /// snapshot for the caller to publish.
    @discardableResult
    func update(id: UUID, _ transform: (inout HighlightCandidate) -> Void) -> [HighlightCandidate] {
        lock.withLock { candidates in
            if let i = candidates.firstIndex(where: { $0.id == id }) { transform(&candidates[i]) }
            return candidates
        }
    }

    /// The sidecar filename for this session (stable across the session).
    var sidecarName: String { ".prism-highlights-\(sessionID.uuidString).json" }

    /// Encode the current candidates as a sidecar payload.
    func snapshotSidecar() -> HighlightCandidateSidecar {
        HighlightCandidateSidecar(sessionID: sessionID, candidates: all())
    }

    /// Atomically write the sidecar into `directory` (creates it if needed).
    /// Best-effort: a write failure never disrupts capture.
    func persist(in directory: URL) {
        let payload = snapshotSidecar()
        guard let data = try? JSONEncoder.pretty.encode(payload) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(sidecarName)
        try? data.write(to: url, options: .atomic)
    }

    /// Decode a sidecar payload from raw JSON (round-trip of `snapshotSidecar`).
    static func decodeSidecar(_ data: Data) throws -> HighlightCandidateSidecar {
        try JSONDecoder().decode(HighlightCandidateSidecar.self, from: data)
    }

    /// Load a sidecar file written by a prior session (Review & Finish reopen).
    static func load(from url: URL) throws -> HighlightCandidateSidecar {
        try decodeSidecar(Data(contentsOf: url))
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
