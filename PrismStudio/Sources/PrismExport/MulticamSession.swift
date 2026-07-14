import CoreMedia
import Foundation
import PrismCore
import PrismOutput

/// One recorded camera angle of a finished multicam session: a clean ISO clip
/// (or the program clip) with the metadata the FCPXML exporter needs to place it
/// on the shared timeline.
///
/// `start` is the house time (`HouseClock`) at which *this* clip's recording
/// began. Under `ISORecorderBank` every ISO recorder shares one fixed start, so
/// their `start`s are identical (offset 0); but a companion device that joins
/// late records a later `start`, and the exporter delays that angle accordingly.
public struct RecordedAngle: Sendable, Identifiable {
    /// The pipeline source this angle was recorded from.
    public let sourceID: SourceID
    /// Human-readable angle name shown in Final Cut ("Cam 1", "iPhone — wide"…).
    public let name: String
    /// Location of the recorded `.mov` on disk.
    public let url: URL
    /// House time this clip's recording began (its shared-timeline placement).
    public let start: CMTime
    /// Recorded media duration.
    public let duration: CMTime
    /// Pixel dimensions of the recording.
    public let width: Int
    public let height: Int
    /// Nominal frame rate of the recording.
    public let fps: Double
    /// Whether the clip carries an audio track.
    public let hasAudio: Bool

    public var id: SourceID { sourceID }

    public init(sourceID: SourceID, name: String, url: URL, start: CMTime,
                duration: CMTime, width: Int, height: Int, fps: Double, hasAudio: Bool) {
        self.sourceID = sourceID
        self.name = name
        self.url = url
        self.start = start
        self.duration = duration
        self.width = width
        self.height = height
        self.fps = fps
        self.hasAudio = hasAudio
    }

    /// Builds an angle from a finished `MovieRecorder.Report` (url + duration come
    /// from the report; the rest is caller-supplied recording metadata). `start`
    /// defaults to the session's shared start — the correct value for `ISORecorderBank`
    /// clips, which all share one fixed timeline zero.
    public static func from(report: MovieRecorder.Report, sourceID: SourceID, name: String,
                            width: Int, height: Int, fps: Double, hasAudio: Bool,
                            start: CMTime) -> RecordedAngle {
        RecordedAngle(sourceID: sourceID, name: name, url: report.url, start: start,
                      duration: report.duration, width: width, height: height,
                      fps: fps, hasAudio: hasAudio)
    }
}

/// A completed multi-angle recording session ready to become a Final Cut
/// multicam project (DESIGN §2.5 "FCPXML multicam export").
///
/// `sessionStart` is the shared timeline zero in house time; each angle's offset
/// on the multicam timeline is `angle.start − sessionStart`. The `program` angle
/// is the switched output and becomes the multicam clip's active angle; `isoAngles`
/// are the clean per-source feeds.
public struct MulticamSession: Sendable {
    /// Final Cut event / project / multicam-clip name.
    public let projectName: String
    /// Shared timeline zero (house time). Angles offset from here.
    public let sessionStart: CMTime
    /// The switched program feed — the active angle of the multicam clip.
    public let program: RecordedAngle
    /// The clean per-source ISO angles.
    public let isoAngles: [RecordedAngle]
    /// Sequence frame rate / timebase.
    public let frameRate: FrameRate
    /// Sequence raster width/height (the program raster).
    public let width: Int
    public let height: Int
    /// FCPXML `colorSpace` string for the format(s), e.g. `"1-1-1 (Rec. 709)"`.
    public let colorSpace: String

    public init(projectName: String, sessionStart: CMTime, program: RecordedAngle,
                isoAngles: [RecordedAngle], frameRate: FrameRate,
                width: Int, height: Int, colorSpace: String = "1-1-1 (Rec. 709)") {
        self.projectName = projectName
        self.sessionStart = sessionStart
        self.program = program
        self.isoAngles = isoAngles
        self.frameRate = frameRate
        self.width = width
        self.height = height
        self.colorSpace = colorSpace
    }

    /// Program first, then the ISO angles — the order they appear as `<mc-angle>`s.
    public var allAngles: [RecordedAngle] { [program] + isoAngles }

    /// This angle's placement on the multicam timeline in seconds, clamped to ≥ 0
    /// (`angle.start − sessionStart`). Angles that began before the shared start
    /// (their leading media trimmed by AVAssetWriter) place at 0.
    public func offsetSeconds(of angle: RecordedAngle) -> Double {
        max(0, CMTimeSubtract(angle.start, sessionStart).seconds)
    }

    /// Total timeline length in seconds: the farthest `offset + duration`.
    public var timelineSeconds: Double {
        allAngles.reduce(0) { max($0, offsetSeconds(of: $1) + $1.duration.seconds) }
    }
}
