import CoreMedia
import Foundation
import PrismCore
import PrismOutput
import os

/// Generates a Final Cut Pro **multicam** FCPXML from a finished `MulticamSession`
/// (DESIGN §2.5 — "one click → Final Cut project, all ISOs aligned"; §1 VISION —
/// "the live show and the post workflow are the same asset").
///
/// ## FCPXML version
/// Emits **version 1.11** (`<fcpxml version="1.11">`). Rationale: 1.11 is the DTD
/// version shipped with Final Cut Pro 10.6.6+ (2023) and the interchange framework
/// on this machine (`.../Interchange.framework/…/FCPXMLv1_11.dtd`), so it validates
/// locally and imports into current FCP. 1.10 (FCP 10.6) is the compatible fallback;
/// nothing we emit for a plain multicam differs between them. The DTD pins the
/// attribute `#FIXED "1.11"`, so the version string is not configurable.
///
/// ## Structure emitted
/// ```
/// fcpxml
///  └─ resources
///      ├─ format(s)         one per distinct (w,h,frameDuration); deduped
///      ├─ asset × N         one per angle, each with a <media-rep src=file://…>
///      └─ media  (multicam) angles as <mc-angle>, each holding an <asset-clip>
///                           positioned by offset = angle.start − sessionStart
///  └─ library
///      └─ event
///          └─ project
///              └─ sequence
///                  └─ spine
///                      └─ mc-clip → the multicam media, with an <mc-source>
///                         selecting the program angle as active
/// ```
/// All times are rational `N/Ds` strings at the sequence timebase.
///
/// ## Output format
/// Writes a single **`.fcpxml`** file (plain XML), not a `.fcpxmld` bundle. A plain
/// file is sufficient because we reference media by external `file://` URL rather
/// than embedding it; `.fcpxmld` only earns its keep when bundling a `Resources/`
/// folder of media, which we don't.
public enum FCPXMLExporter {
    /// The FCPXML version string this exporter emits.
    public static let version = "1.11"

    private static let log = EngineLog.logger("export.fcpxml")

    public enum ExportError: Error, CustomStringConvertible {
        case emptySession(String)
        case writeFailed(URL, underlying: Error)
        public var description: String {
            switch self {
            case .emptySession(let s): return "FCPXML export: \(s)"
            case .writeFailed(let url, let e): return "FCPXML write to \(url.path) failed: \(e)"
            }
        }
    }

    // MARK: - Generation

    /// Generates the FCPXML document as a UTF-8 `String`.
    ///
    /// Passing a non-empty `directorsCut` produces the **metadata-rich** first cut:
    /// the program-selected multicam is split into an editable segment per live
    /// program switch (each re-selectable), with chapter markers at the cuts,
    /// score/reason markers + keyword ranges at the highlight candidates, the
    /// live-caption transcript as `<caption>` elements, and the separated audio
    /// stems as role-tagged anchored `<audio>` clips. `nil`/empty reproduces the
    /// original single-clip multicam byte-for-byte (backward compatible).
    public static func generate(session: MulticamSession, directorsCut: DirectorsCut? = nil) -> String {
        let angles = session.allAngles
        let dc = directorsCut ?? DirectorsCut()
        let enriched = !dc.isEmpty

        // 1. Deduplicate formats across angles + the sequence raster.
        //    A format key is (width, height, frameDurationTicks, timescale).
        struct FormatKey: Hashable { let w: Int; let h: Int; let ticks: Int64; let ts: Int64 }
        var formatIDs: [FormatKey: String] = [:]
        var formatOrder: [(id: String, key: FormatKey)] = []
        var nextID = 1
        func formatID(w: Int, h: Int, rate: FrameRate) -> String {
            let key = FormatKey(w: w, h: h, ticks: rate.frameDurationTicks, ts: rate.timescale)
            if let existing = formatIDs[key] { return existing }
            let id = "r\(nextID)"; nextID += 1
            formatIDs[key] = id
            formatOrder.append((id, key))
            return id
        }

        // Sequence format first, so it is r1.
        let sequenceFormatID = formatID(w: session.width, h: session.height, rate: session.frameRate)

        // 2. Assign an asset id + angleID to every angle (allocated after formats).
        struct AnglePlan {
            let angle: RecordedAngle
            let assetID: String
            let angleID: String
            let formatID: String
            let offsetSec: Double
        }
        var plans: [AnglePlan] = []
        // Resolve every angle's format id first (may create new formats → higher r#).
        var angleFormat: [String] = []
        for angle in angles {
            angleFormat.append(formatID(w: angle.width, h: angle.height, rate: FrameRate(fps: angle.fps)))
        }
        for (i, angle) in angles.enumerated() {
            let assetID = "r\(nextID)"; nextID += 1
            plans.append(AnglePlan(angle: angle, assetID: assetID,
                                   angleID: Self.angleID(for: angle.sourceID),
                                   formatID: angleFormat[i],
                                   offsetSec: session.offsetSeconds(of: angle)))
        }
        // Stem audio assets (one per stem), allocated before the media id so the
        // <resources> block keeps its assets grouped.
        var stemPlans: [StemPlan] = []
        if enriched {
            var lane = -1
            for stem in dc.audioStems {
                let id = "r\(nextID)"; nextID += 1
                let durSec = stem.durationSeconds ?? session.timelineSeconds
                stemPlans.append(StemPlan(stem: stem, assetID: id, lane: lane, durationSec: durSec))
                lane -= 1
            }
        }

        let mediaID = "r\(nextID)"; nextID += 1

        let totalTime = session.frameRate.fcpTime(session.timelineSeconds)
        let programAngleID = plans[0].angleID   // program is allAngles[0]

        var xml = ""
        xml += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<!DOCTYPE fcpxml>\n"
        xml += "<fcpxml version=\"\(version)\">\n"
        xml += "  <resources>\n"

        // Formats
        for (id, key) in formatOrder {
            let fd = RationalTime(numerator: key.ticks, denominator: key.ts).fcpString
            let name = "PrismVideoFormat\(key.w)x\(key.h)"
            xml += "    <format id=\"\(id)\" name=\"\(esc(name))\" frameDuration=\"\(fd)\""
            xml += " width=\"\(key.w)\" height=\"\(key.h)\" colorSpace=\"\(esc(session.colorSpace))\"/>\n"
        }

        // Assets (one per angle)
        for plan in plans {
            let dur = session.frameRate.fcpTime(plan.angle.duration.seconds)
            let src = plan.angle.url.absoluteString
            xml += "    <asset id=\"\(plan.assetID)\" name=\"\(esc(plan.angle.name))\""
            xml += " start=\"0s\" duration=\"\(dur)\" format=\"\(plan.formatID)\""
            xml += " hasVideo=\"1\" videoSources=\"1\""
            if plan.angle.hasAudio {
                xml += " hasAudio=\"1\" audioSources=\"1\" audioChannels=\"2\" audioRate=\"48000\""
            }
            xml += ">\n"
            xml += "      <media-rep kind=\"original-media\" src=\"\(esc(src))\"/>\n"
            xml += "    </asset>\n"
        }

        // Stem audio assets (audio-only; separated mic/soundboard/music/master).
        for sp in stemPlans {
            let dur = session.frameRate.fcpTime(sp.durationSec)
            let name = sp.stem.name.isEmpty ? sp.stem.kind.rawValue : sp.stem.name
            xml += "    <asset id=\"\(sp.assetID)\" name=\"\(esc(name))\""
            xml += " start=\"0s\" duration=\"\(dur)\" hasVideo=\"0\""
            xml += " hasAudio=\"1\" audioSources=\"1\" audioChannels=\"\(sp.stem.channels)\" audioRate=\"48000\">\n"
            xml += "      <media-rep kind=\"original-media\" src=\"\(esc(sp.stem.url.absoluteString))\"/>\n"
            xml += "    </asset>\n"
        }

        // Multicam media
        xml += "    <media id=\"\(mediaID)\" name=\"\(esc(session.projectName))\">\n"
        xml += "      <multicam format=\"\(sequenceFormatID)\" tcStart=\"0s\" tcFormat=\"NDF\" duration=\"\(totalTime)\">\n"
        for plan in plans {
            let dur = session.frameRate.fcpTime(plan.angle.duration.seconds)
            let offset = session.frameRate.fcpTime(plan.offsetSec)
            xml += "        <mc-angle name=\"\(esc(plan.angle.name))\" angleID=\"\(esc(plan.angleID))\">\n"
            xml += "          <asset-clip ref=\"\(plan.assetID)\" name=\"\(esc(plan.angle.name))\""
            xml += " offset=\"\(offset)\" duration=\"\(dur)\" start=\"0s\"/>\n"
            xml += "        </mc-angle>\n"
        }
        xml += "      </multicam>\n"
        xml += "    </media>\n"
        xml += "  </resources>\n"

        // Library → event → project → sequence → spine → mc-clip
        xml += "  <library>\n"
        xml += "    <event name=\"\(esc(session.projectName))\">\n"
        xml += "      <project name=\"\(esc(session.projectName))\">\n"
        xml += "        <sequence format=\"\(sequenceFormatID)\" duration=\"\(totalTime)\""
        xml += " tcStart=\"0s\" tcFormat=\"NDF\" audioLayout=\"stereo\" audioRate=\"48k\">\n"
        xml += "          <spine>\n"
        if enriched {
            xml += emitEnrichedSpine(session: session, dc: dc, mediaID: mediaID,
                                     validAngleIDs: Set(plans.map { $0.angleID }),
                                     stemPlans: stemPlans, programAngleID: programAngleID)
        } else {
            xml += "            <mc-clip ref=\"\(mediaID)\" name=\"\(esc(session.projectName))\""
            xml += " offset=\"0s\" duration=\"\(totalTime)\" start=\"0s\">\n"
            xml += "              <mc-source angleID=\"\(esc(programAngleID))\" srcEnable=\"all\"/>\n"
            xml += "            </mc-clip>\n"
        }
        xml += "          </spine>\n"
        xml += "        </sequence>\n"
        xml += "      </project>\n"
        xml += "    </event>\n"
        xml += "  </library>\n"
        xml += "</fcpxml>\n"
        return xml
    }

    /// Generates the FCPXML document as UTF-8 `Data`.
    public static func generateData(session: MulticamSession, directorsCut: DirectorsCut? = nil) throws -> Data {
        guard let data = generate(session: session, directorsCut: directorsCut).data(using: .utf8) else {
            throw ExportError.emptySession("could not UTF-8 encode document")
        }
        return data
    }

    // MARK: - Writing

    /// Writes the session as a `.fcpxml` file at `url` (a `.fcpxml` extension is
    /// appended if absent). Overwrites any existing file atomically.
    public static func write(session: MulticamSession, to url: URL, directorsCut: DirectorsCut? = nil) throws {
        let target = url.pathExtension.lowercased() == "fcpxml"
            ? url : url.appendingPathExtension("fcpxml")
        let data = try generateData(session: session, directorsCut: directorsCut)
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            throw ExportError.writeFailed(target, underlying: error)
        }
        log.info("wrote FCPXML multicam (\(session.allAngles.count) angles) → \(target.lastPathComponent, privacy: .public)")
    }

    // MARK: - Convenience: build a session from PrismOutput recording results

    /// Per-angle metadata the exporter can't recover from a `MovieRecorder.Report`
    /// alone (the report carries only url + duration).
    public struct AngleMetadata: Sendable {
        public let name: String
        public let width: Int
        public let height: Int
        public let fps: Double
        public let hasAudio: Bool
        public init(name: String, width: Int, height: Int, fps: Double, hasAudio: Bool) {
            self.name = name; self.width = width; self.height = height
            self.fps = fps; self.hasAudio = hasAudio
        }
    }

    /// Builds a `MulticamSession` from PrismOutput recording outputs — the program
    /// `MovieRecorder.Report` plus an `ISORecorderBank.finishAll()` result map.
    ///
    /// Because an ISO bank shares one fixed timeline zero, every angle's `start` is
    /// `sessionStart` (offset 0). Failed ISO results are skipped and logged. The
    /// `metadata` closure supplies the per-source recording geometry (typically from
    /// the `RecordingSettings` used to arm each source).
    public static func makeSession(
        projectName: String,
        sessionStart: CMTime,
        frameRate: FrameRate,
        width: Int,
        height: Int,
        program: (report: MovieRecorder.Report, source: SourceID),
        isoResults: [SourceID: Result<MovieRecorder.Report, Error>],
        metadata: (SourceID) -> AngleMetadata,
        colorSpace: String = "1-1-1 (Rec. 709)"
    ) -> MulticamSession {
        let pMeta = metadata(program.source)
        let programAngle = RecordedAngle.from(
            report: program.report, sourceID: program.source, name: pMeta.name,
            width: pMeta.width, height: pMeta.height, fps: pMeta.fps,
            hasAudio: pMeta.hasAudio, start: sessionStart)

        var isoAngles: [RecordedAngle] = []
        for (sourceID, result) in isoResults.sorted(by: { $0.key.raw < $1.key.raw }) {
            switch result {
            case .success(let report):
                let m = metadata(sourceID)
                isoAngles.append(RecordedAngle.from(
                    report: report, sourceID: sourceID, name: m.name,
                    width: m.width, height: m.height, fps: m.fps,
                    hasAudio: m.hasAudio, start: sessionStart))
            case .failure(let error):
                log.error("ISO angle \(sourceID.raw, privacy: .public) failed, skipped from multicam: \(String(describing: error), privacy: .public)")
            }
        }

        return MulticamSession(projectName: projectName, sessionStart: sessionStart,
                               program: programAngle, isoAngles: isoAngles,
                               frameRate: frameRate, width: width, height: height,
                               colorSpace: colorSpace)
    }

    // MARK: - Enriched spine (Director's-Cut metadata)

    /// Resolved placement of one audio stem on the timeline.
    struct StemPlan { let stem: AudioStem; let assetID: String; let lane: Int; let durationSec: Double }

    /// One editable multicam segment: the timeline span between two program
    /// switches, with the angle that was live and the switch (if any) that opened it.
    private struct Segment { let start: Double; let end: Double; let angleID: String; let opener: ProgramSwitch? }

    /// Builds the segmented, pre-annotated spine: an editable `<mc-clip>` per program
    /// switch (each re-selectable via its `<mc-source angleID>`), chapter markers at
    /// the cuts, score/reason `<marker>` + `<keyword>` at highlight candidates, the
    /// transcript as `<caption>`, and role-tagged `<audio>` stems anchored below.
    private static func emitEnrichedSpine(
        session: MulticamSession, dc: DirectorsCut, mediaID: String,
        validAngleIDs: Set<String>, stemPlans: [StemPlan], programAngleID: String
    ) -> String {
        let fr = session.frameRate
        let total = session.timelineSeconds
        let frameSec = fr.frameDuration.seconds
        func clampTime(_ t: Double) -> Double { min(max(0, t), total) }

        func angleID(for sw: ProgramSwitch) -> String {
            if let s = sw.source {
                let a = Self.angleID(for: s)
                if validAngleIDs.contains(a) { return a }
            }
            return programAngleID
        }

        // 1. Program switches → segment boundaries (0 plus each in-range switch time).
        let switches = dc.programSwitches
            .map { ProgramSwitch(atSeconds: clampTime($0.atSeconds), sourceName: $0.sourceName, source: $0.source) }
            .sorted { $0.atSeconds < $1.atSeconds }
        var boundaries: [Double] = [0]
        for sw in switches where sw.atSeconds > frameSec / 2 && sw.atSeconds < total {
            if let last = boundaries.last, abs(last - sw.atSeconds) <= frameSec / 2 { continue }
            boundaries.append(sw.atSeconds)
        }

        // 2. Resolve each segment's live angle + opening switch.
        var segments: [Segment] = []
        for (i, b) in boundaries.enumerated() {
            let end = (i + 1 < boundaries.count) ? boundaries[i + 1] : total
            let opener = switches.last { abs($0.atSeconds - b) <= frameSec / 2 }
            let angle: String
            if let sw = opener {
                angle = angleID(for: sw)
            } else if let prev = switches.last(where: { $0.atSeconds < b - frameSec / 2 }) {
                angle = angleID(for: prev)
            } else {
                angle = programAngleID   // segment 0 before any switch
            }
            segments.append(Segment(start: b, end: end, angleID: angle, opener: opener))
        }

        let srcEnable = stemPlans.isEmpty ? "all" : "video"   // stems carry audio when present
        var xml = ""

        for (idx, seg) in segments.enumerated() {
            let isLast = idx == segments.count - 1
            let offset = fr.fcpTime(seg.start)
            let dur = fr.fcpTime(seg.end - seg.start)
            xml += "            <mc-clip ref=\"\(mediaID)\" name=\"\(esc(session.projectName))\""
            xml += " offset=\"\(offset)\" duration=\"\(dur)\" start=\"\(offset)\" srcEnable=\"\(srcEnable)\">\n"
            xml += "              <mc-source angleID=\"\(esc(seg.angleID))\" srcEnable=\"\(srcEnable)\"/>\n"

            // --- anchor items (must precede marker items per the DTD) ---
            // Captions + stems anchor to segment 0; every segment clip's start == its
            // timeline position, so an anchored offset equals the absolute timeline time.
            if idx == 0 {
                for (ci, capRaw) in dc.captions.enumerated() {
                    let at = clampTime(capRaw.atSeconds)
                    let d = fr.fcpTime(max(frameSec, capRaw.durationSeconds))
                    let tsID = "ts-cap-\(ci)"
                    xml += "              <caption name=\"Caption \(ci + 1)\" lane=\"1\""
                    xml += " offset=\"\(fr.fcpTime(at))\" duration=\"\(d)\" start=\"0s\""
                    xml += " role=\"iTT?captionFormat=ITT.en\">\n"
                    xml += "                <text><text-style ref=\"\(tsID)\">\(esc(capRaw.text))</text-style></text>\n"
                    xml += "                <text-style-def id=\"\(tsID)\">"
                    xml += "<text-style font=\"Helvetica\" fontSize=\"48\" fontColor=\"1 1 1 1\"/></text-style-def>\n"
                    xml += "              </caption>\n"
                }
                for sp in stemPlans {
                    let d = fr.fcpTime(sp.durationSec)
                    let name = sp.stem.name.isEmpty ? sp.stem.kind.rawValue : sp.stem.name
                    xml += "              <audio ref=\"\(sp.assetID)\" name=\"\(esc(name))\""
                    xml += " role=\"\(esc(sp.stem.kind.role))\" lane=\"\(sp.lane)\""
                    xml += " offset=\"0s\" duration=\"\(d)\" start=\"0s\"/>\n"
                }
            }

            // --- marker items ---
            // Chapter marker at the cut that opened this segment.
            if let sw = seg.opener {
                xml += "              <chapter-marker start=\"\(fr.fcpTime(sw.atSeconds))\""
                xml += " value=\"\(esc(sw.sourceName))\"/>\n"
            }
            // Highlight candidates whose peak falls inside this segment.
            for hl in dc.highlights {
                let at = clampTime(hl.atSeconds)
                let inSeg = at >= seg.start - frameSec / 2 && (at < seg.end - frameSec / 2 || (isLast && at <= seg.end + frameSec / 2))
                guard inSeg else { continue }
                let win = min(hl.durationSeconds, seg.end - at)
                let hasWin = win > frameSec / 2
                let start = fr.fcpTime(at)
                let label = "\(hl.reason) · \(String(format: "%.2f", hl.score))"
                xml += "              <marker start=\"\(start)\""
                if hasWin { xml += " duration=\"\(fr.fcpTime(win))\"" }
                xml += " value=\"\(esc(label))\"/>\n"
                xml += "              <keyword start=\"\(start)\""
                if hasWin { xml += " duration=\"\(fr.fcpTime(win))\"" }
                xml += " value=\"\(esc("Highlight, \(hl.reason)"))\"/>\n"
            }

            xml += "            </mc-clip>\n"
        }
        return xml
    }

    // MARK: - Helpers

    /// Stable, unique angle identifier derived from the source id.
    static func angleID(for source: SourceID) -> String {
        "PrismAngle-" + String(source.raw.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    /// XML-escapes text/attribute content (`& < > " '`).
    static func esc(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(c)
            }
        }
        return out
    }
}
