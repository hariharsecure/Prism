import CoreMedia
import Foundation
import PrismCore

/// Headless self-verification of the FCPXML multicam exporter (no TCC, no
/// capture hardware, no real media files). Builds a synthetic `MulticamSession`,
/// generates the FCPXML, and asserts structurally against a parsed `XMLDocument`.
///
/// Wire `ExportSelfTest.run()` into prism-dev or an XCTest target; it throws with
/// a precise message on the first failed assertion and prints actual results.
///
/// **UNVERIFIED:** a real Final Cut Pro *import* is not exercised here (requires
/// the app + a GUI). This verifies well-formed XML, the FCPXML version, resource
/// structure, multicam angle offsets, active-angle wiring, rational-time math, and
/// — when the interchange DTD is present on disk — DTD validity.
public enum ExportSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case assertionFailed(String)
        public var description: String {
            switch self {
            case .assertionFailed(let s): return "ExportSelfTest failed: \(s)"
            }
        }
    }

    private static func require(_ cond: Bool, _ msg: @autoclosure () -> String) throws {
        if !cond { throw SelfTestError.assertionFailed(msg()) }
    }

    public static func run() throws {
        print("ExportSelfTest: starting")
        try testRationalTime()
        try testMulticamStructure()
        try testDirectorsCutEnrichment()
        print("ExportSelfTest: all checks passed")
    }

    // MARK: - 1. Rational-time converter round-trips

    private static func testRationalTime() throws {
        // 0.5s at a 30000 timebase → 1/2s
        let half = RationalTime(seconds: 0.5, timescale: 30000)
        try require(half.fcpString == "1/2s", "0.5s@30000 → \(half.fcpString), want 1/2s")

        // 2.5s at a 30000 timebase → 5/2s
        let twoHalf = RationalTime(seconds: 2.5, timescale: 30000)
        try require(twoHalf.fcpString == "5/2s", "2.5s@30000 → \(twoHalf.fcpString), want 5/2s")

        // one NTSC (29.97) frame: 1001/30000s — exact, must not reduce
        let ntsc = RationalTime(numerator: 1001, denominator: 30000)
        try require(ntsc.fcpString == "1001/30000s", "NTSC frame → \(ntsc.fcpString), want 1001/30000s")
        try require(abs(ntsc.seconds - 0.033366) < 1e-6, "NTSC frame seconds \(ntsc.seconds)")

        // integer seconds collapse to "Ns"
        try require(RationalTime(seconds: 0, timescale: 60000).fcpString == "0s", "zero not 0s")
        try require(RationalTime(seconds: 5, timescale: 60000).fcpString == "5s", "5s not collapsed")

        // parse round-trips the emitted strings
        for s in ["1/2s", "5/2s", "1001/30000s", "0s", "5s"] {
            let p = RationalTime.parse(s)
            try require(p?.fcpString == s, "parse round-trip failed for \(s) → \(String(describing: p?.fcpString))")
        }

        // FrameRate frame durations
        try require(FrameRate.fps60.frameDuration.fcpString == "1/60s", "60fps frameDuration \(FrameRate.fps60.frameDuration.fcpString)")
        try require(FrameRate.fps5994.frameDuration.fcpString == "1001/60000s", "59.94 frameDuration \(FrameRate.fps5994.frameDuration.fcpString)")
        print("  [1] rational-time: 0.5→1/2s, 2.5→5/2s, NTSC 1001/30000s, 60fps 1/60s, 59.94 1001/60000s — OK")
    }

    // MARK: - 2. Multicam FCPXML structure

    private static func testMulticamStructure() throws {
        // Shared session start at an arbitrary house time.
        let start = CMTime(value: 1_000_000, timescale: 1000) // 1000.0s
        func t(_ sec: Double) -> CMTime { CMTimeAdd(start, CMTime(seconds: sec, preferredTimescale: 60000)) }
        let dur = { (sec: Double) in CMTime(seconds: sec, preferredTimescale: 60000) }

        // NOTE: the file URLs need not exist — XML generation only reads their
        // string form. A real FCP import would require the media on disk.
        func url(_ n: String) -> URL { URL(fileURLWithPath: "/Volumes/Show/\(n).mov") }

        let program = RecordedAngle(
            sourceID: SourceID("program"), name: "Program", url: url("program"),
            start: start, duration: dur(60), width: 1920, height: 1080, fps: 60, hasAudio: true)
        let camA = RecordedAngle(
            sourceID: SourceID("cam-a"), name: "Cam A", url: url("iso-cam-a"),
            start: start, duration: dur(60), width: 1920, height: 1080, fps: 60, hasAudio: false)
        // Cam B joined 5 seconds late → must carry a 5s offset.
        let camB = RecordedAngle(
            sourceID: SourceID("cam-b"), name: "Cam B (late)", url: url("iso-cam-b"),
            start: t(5), duration: dur(55), width: 1920, height: 1080, fps: 60, hasAudio: false)

        let session = MulticamSession(
            projectName: "Prism Test Show", sessionStart: start,
            program: program, isoAngles: [camA, camB],
            frameRate: .fps60, width: 1920, height: 1080)

        let xmlString = FCPXMLExporter.generate(session: session)
        guard let data = xmlString.data(using: .utf8) else {
            throw SelfTestError.assertionFailed("document not UTF-8 encodable")
        }

        // (a) well-formed XML
        let doc: XMLDocument
        do {
            doc = try XMLDocument(data: data, options: [.nodePreserveWhitespace])
        } catch {
            throw SelfTestError.assertionFailed("not well-formed XML: \(error)")
        }

        // (b) fcpxml version attr
        let version = try firstString(doc, "/fcpxml/@version")
        try require(version == "1.11", "version attr = \(version ?? "nil"), want 1.11")

        // (c) exactly one format resource (all angles share 1080p60)
        let formats = try doc.nodes(forXPath: "//resources/format")
        try require(formats.count == 1, "format count = \(formats.count), want 1")

        // (d) one asset per angle (3)
        let assets = try doc.nodes(forXPath: "//resources/asset")
        try require(assets.count == 3, "asset count = \(assets.count), want 3")
        // each asset has exactly one media-rep with a file:// src
        for a in assets {
            let reps = try (a as! XMLElement).nodes(forXPath: "media-rep/@src")
            try require(reps.count == 1, "asset has \(reps.count) media-rep src, want 1")
            let s = reps.first?.stringValue ?? ""
            try require(s.hasPrefix("file://"), "media-rep src not a file URL: \(s)")
        }

        // (e) exactly one mc-clip with 3 mc-angles
        let mcClips = try doc.nodes(forXPath: "//spine/mc-clip")
        try require(mcClips.count == 1, "mc-clip count = \(mcClips.count), want 1")
        let mcAngles = try doc.nodes(forXPath: "//media/multicam/mc-angle")
        try require(mcAngles.count == 3, "mc-angle count = \(mcAngles.count), want 3")

        // (f) offsets: program & Cam A at 0s; late Cam B at exactly 5s.
        let progOffset = try firstString(doc, "//mc-angle[@name='Program']/asset-clip/@offset")
        try require(progOffset == "0s", "program offset = \(progOffset ?? "nil"), want 0s")
        let camBOffset = try firstString(doc, "//mc-angle[@name='Cam B (late)']/asset-clip/@offset")
        // 5s at timebase 60000 → 300000/60000 → reduces to "5s"
        try require(camBOffset == "5s", "late-angle offset = \(camBOffset ?? "nil"), want 5s")
        // rational-time cross-check: the delta 5.0s must equal that emitted string
        let expected = FrameRate.fps60.fcpTime(CMTimeSubtract(camB.start, start).seconds)
        try require(camBOffset == expected, "offset \(camBOffset ?? "nil") ≠ rational-math \(expected)")

        // (g) active angle: mc-source angleID == the program mc-angle's angleID
        let programAngleID = try firstString(doc, "//mc-angle[@name='Program']/@angleID")
        let mcSourceAngleID = try firstString(doc, "//mc-clip/mc-source/@angleID")
        try require(programAngleID != nil && programAngleID == mcSourceAngleID,
                    "active angle mismatch: program=\(programAngleID ?? "nil") mc-source=\(mcSourceAngleID ?? "nil")")

        // (h) sequence duration = farthest offset+duration = 60s (Cam B ends at 5+55=60)
        let seqDur = try firstString(doc, "//sequence/@duration")
        try require(seqDur == "60s", "sequence duration = \(seqDur ?? "nil"), want 60s")

        print("  [2] structure: version 1.11, 1 format, 3 assets, 1 mc-clip / 3 mc-angles,")
        print("       Cam B offset \(camBOffset ?? "?") (rational-math \(expected)), active angle=\(programAngleID ?? "?"), seq \(seqDur ?? "?") — OK")

        // (i) BONUS: validate against the interchange DTD if present on disk.
        try validateAgainstDTD(data: data)
    }

    // MARK: - 3. Director's-Cut enrichment structure

    /// Asserts the metadata-rich first cut: segmented editable multicam (cut points),
    /// chapter markers at the switches, score/reason markers + keyword ranges at the
    /// highlights, the caption transcript, and role-tagged audio stems.
    ///
    /// Oracles are **independent** of the exporter's own logic: expected segment
    /// boundaries, times, and role strings are recomputed here (via the rational-time
    /// library and the angle table read back from the emitted doc), never by trusting
    /// the exporter's emitted attribute strings against themselves.
    private static func testDirectorsCutEnrichment() throws {
        let start = CMTime(value: 0, timescale: 1000)
        let dur = { (sec: Double) in CMTime(seconds: sec, preferredTimescale: 60000) }
        func url(_ n: String) -> URL { URL(fileURLWithPath: "/Volumes/Show/\(n).mov") }
        func stemURL(_ n: String) -> URL { URL(fileURLWithPath: "/Volumes/Show/stem-\(n).caf") }

        let program = RecordedAngle(sourceID: SourceID("program"), name: "Program", url: url("program"),
                                    start: start, duration: dur(60), width: 1920, height: 1080, fps: 60, hasAudio: true)
        let camA = RecordedAngle(sourceID: SourceID("cam-a"), name: "Cam A", url: url("iso-cam-a"),
                                 start: start, duration: dur(60), width: 1920, height: 1080, fps: 60, hasAudio: false)
        let camB = RecordedAngle(sourceID: SourceID("cam-b"), name: "Cam B", url: url("iso-cam-b"),
                                 start: start, duration: dur(60), width: 1920, height: 1080, fps: 60, hasAudio: false)
        let session = MulticamSession(projectName: "Enriched Show", sessionStart: start,
                                      program: program, isoAngles: [camA, camB],
                                      frameRate: .fps60, width: 1920, height: 1080)

        // Independent expectation: 3 switches → 3 segments [0,20)/[20,40)/[40,60).
        let dc = DirectorsCut(
            programSwitches: [
                ProgramSwitch(atSeconds: 0,  sourceName: "Program", source: SourceID("program")),
                ProgramSwitch(atSeconds: 20, sourceName: "Cam A",   source: SourceID("cam-a")),
                ProgramSwitch(atSeconds: 40, sourceName: "Cam B",   source: SourceID("cam-b")),
            ],
            highlights: [
                Highlight(atSeconds: 10, durationSeconds: 6, score: 0.90, reason: "crowd cheer"),
                Highlight(atSeconds: 45, durationSeconds: 4, score: 0.75, reason: "big play"),
            ],
            captions: [
                Caption(atSeconds: 1,  durationSeconds: 3, text: "hello world"),
                Caption(atSeconds: 22, durationSeconds: 2, text: "second line"),
            ],
            audioStems: [
                AudioStem(kind: .mic,        name: "Mic",        url: stemURL("mic")),
                AudioStem(kind: .soundboard, name: "Soundboard", url: stemURL("board")),
                AudioStem(kind: .music,      name: "Music",      url: stemURL("music")),
                AudioStem(kind: .master,     name: "Master",     url: stemURL("master")),
            ])

        let xmlString = FCPXMLExporter.generate(session: session, directorsCut: dc)
        guard let data = xmlString.data(using: .utf8) else {
            throw SelfTestError.assertionFailed("enriched doc not UTF-8 encodable")
        }
        let doc: XMLDocument
        do { doc = try XMLDocument(data: data, options: [.nodePreserveWhitespace]) }
        catch { throw SelfTestError.assertionFailed("enriched doc not well-formed: \(error)") }

        let fr = FrameRate.fps60
        func fcp(_ s: Double) -> String { fr.fcpTime(s) }

        // (a) CUT POINTS: one mc-clip per segment, contiguous, right angle each.
        let clips = try doc.nodes(forXPath: "//spine/mc-clip")
        try require(clips.count == 3, "enriched mc-clip count = \(clips.count), want 3 (one per segment)")
        // Independent oracle: boundaries [0,20,40], ends [20,40,60].
        let expected: [(off: Double, len: Double, angleName: String)] = [
            (0, 20, "Program"), (20, 20, "Cam A"), (40, 20, "Cam B"),
        ]
        for e in expected {
            let base = "//mc-clip[@offset='\(fcp(e.off))']"
            let off = try firstString(doc, "\(base)/@offset")
            try require(off == fcp(e.off), "segment offset = \(off ?? "nil"), want \(fcp(e.off))")
            let len = try firstString(doc, "\(base)/@duration")
            try require(len == fcp(e.len), "segment duration = \(len ?? "nil"), want \(fcp(e.len))")
            let st = try firstString(doc, "\(base)/@start")
            try require(st == fcp(e.off), "segment start = \(st ?? "nil"), want \(fcp(e.off)) (start==offset invariant)")
            // Angle re-pick oracle: read the angle table back from the doc, then assert
            // this segment's mc-source selects the angle whose mc-angle name matches.
            let wantAngleID = try firstString(doc, "//mc-angle[@name='\(e.angleName)']/@angleID")
            let gotAngleID = try firstString(doc, "\(base)/mc-source/@angleID")
            try require(wantAngleID != nil && wantAngleID == gotAngleID,
                        "segment @\(e.off)s angle = \(gotAngleID ?? "nil"), want \(e.angleName)'s id \(wantAngleID ?? "nil")")
            // Stems present → audio must come from the stems, not the multicam mix.
            let srcEnable = try firstString(doc, "\(base)/mc-source/@srcEnable")
            try require(srcEnable == "video", "segment srcEnable = \(srcEnable ?? "nil"), want video (stems carry audio)")
        }

        // (b) CHAPTER MARKERS: one per switch, on the segment it opens, labeled + timed.
        let chapters = try doc.nodes(forXPath: "//chapter-marker")
        try require(chapters.count == 3, "chapter-marker count = \(chapters.count), want 3")
        for (t, name) in [(0.0, "Program"), (20.0, "Cam A"), (40.0, "Cam B")] {
            let seg = "//mc-clip[@offset='\(fcp(t))']"
            let cv = try firstString(doc, "\(seg)/chapter-marker[@start='\(fcp(t))']/@value")
            try require(cv == name, "chapter-marker @\(t)s value = \(cv ?? "nil"), want \(name) on its own segment")
        }

        // (c) HIGHLIGHTS: a marker per candidate at the peak, labeled score+reason,
        //     on the containing segment; independent oracle = (time, segment, text).
        let markers = try doc.nodes(forXPath: "//marker")
        try require(markers.count == 2, "highlight marker count = \(markers.count), want 2")
        // Highlight at 10s → segment [0,20) (offset 0s); 45s → segment [40,60) (offset 40s).
        for (t, segOff, len, reason, score) in [
            (10.0, 0.0, 6.0, "crowd cheer", "0.90"), (45.0, 40.0, 4.0, "big play", "0.75"),
        ] {
            let mk = try doc.nodes(forXPath: "//mc-clip[@offset='\(fcp(segOff))']/marker[@start='\(fcp(t))']")
            try require(mk.count == 1, "highlight marker @\(t)s not on segment @\(segOff)s (found \(mk.count))")
            let val = (mk.first as? XMLElement)?.attribute(forName: "value")?.stringValue ?? ""
            try require(val.contains(reason) && val.contains(score),
                        "highlight marker @\(t)s value = \"\(val)\", want reason \"\(reason)\" + score \(score)")
            let mdur = (mk.first as? XMLElement)?.attribute(forName: "duration")?.stringValue
            try require(mdur == fcp(len), "highlight marker @\(t)s duration = \(mdur ?? "nil"), want \(fcp(len))")
        }

        // (d) KEYWORDS: a keyword range per candidate, same time/segment, tagged Highlight.
        let keywords = try doc.nodes(forXPath: "//keyword")
        try require(keywords.count == 2, "keyword count = \(keywords.count), want 2")
        for (t, segOff) in [(10.0, 0.0), (45.0, 40.0)] {
            let kw = try doc.nodes(forXPath: "//mc-clip[@offset='\(fcp(segOff))']/keyword[@start='\(fcp(t))']")
            try require(kw.count == 1, "keyword @\(t)s not on segment @\(segOff)s")
            let val = (kw.first as? XMLElement)?.attribute(forName: "value")?.stringValue ?? ""
            try require(val.contains("Highlight"), "keyword @\(t)s value = \"\(val)\", want Highlight tag")
        }

        // (e) CAPTIONS: transcript as <caption>, aligned to timecode, on lane 1.
        let captions = try doc.nodes(forXPath: "//mc-clip[@offset='0s']/caption")
        try require(captions.count == 2, "caption count = \(captions.count), want 2 (anchored to segment 0)")
        for (t, txt, len) in [(1.0, "hello world", 3.0), (22.0, "second line", 2.0)] {
            let cap = try doc.nodes(forXPath: "//caption[@offset='\(fcp(t))']")
            try require(cap.count == 1, "no caption at offset \(fcp(t))")
            let el = cap.first as! XMLElement
            let lane = el.attribute(forName: "lane")?.stringValue
            try require(lane == "1", "caption @\(t)s lane = \(lane ?? "nil"), want 1")
            let role = el.attribute(forName: "role")?.stringValue ?? ""
            try require(role.hasPrefix("iTT"), "caption @\(t)s role = \"\(role)\", want an iTT caption role")
            let d = el.attribute(forName: "duration")?.stringValue
            try require(d == fcp(len), "caption @\(t)s duration = \(d ?? "nil"), want \(fcp(len))")
            let text = try firstString(doc, "//caption[@offset='\(fcp(t))']/text")
            try require(text == txt, "caption @\(t)s text = \(text ?? "nil"), want \"\(txt)\"")
        }

        // (f) AUDIO STEMS: role-tagged, distinct negative lanes, each ref → its file.
        let audios = try doc.nodes(forXPath: "//mc-clip[@offset='0s']/audio")
        try require(audios.count == 4, "audio-stem count = \(audios.count), want 4 (anchored to segment 0)")
        var lanes: Set<String> = []
        for a in audios {
            let el = a as! XMLElement
            let lane = el.attribute(forName: "lane")?.stringValue ?? "0"
            try require((Int(lane) ?? 0) < 0, "audio-stem lane \(lane) not negative")
            try require(!lanes.contains(lane), "audio-stem lane \(lane) reused")
            lanes.insert(lane)
        }
        // Independent role oracle: expected role string per kind, and ref → correct file.
        for (role, file) in [
            ("dialogue.mic", "mic"), ("effects.soundboard", "board"),
            ("music.music", "music"), ("mix.master", "master"),
        ] {
            let ref = try firstString(doc, "//audio[@role='\(role)']/@ref")
            try require(ref != nil, "no audio stem with role \(role)")
            let src = try firstString(doc, "//asset[@id='\(ref!)']/media-rep/@src")
            try require(src == stemURL(file).absoluteString,
                        "stem role \(role) src = \(src ?? "nil"), want \(stemURL(file).absoluteString)")
        }

        // (g) BACKWARD-COMPAT: no director's-cut → exactly the old single-clip multicam.
        let plainString = FCPXMLExporter.generate(session: session)
        let plain = try XMLDocument(data: Data(plainString.utf8), options: [.nodePreserveWhitespace])
        try require(try plain.nodes(forXPath: "//spine/mc-clip").count == 1, "plain export must have 1 mc-clip")
        try require(try plain.nodes(forXPath: "//marker").isEmpty, "plain export must have no markers")
        try require(try plain.nodes(forXPath: "//caption").isEmpty, "plain export must have no captions")
        try require(try plain.nodes(forXPath: "//spine//audio").isEmpty, "plain export must have no anchored audio")

        print("  [4] enriched: 3 segments (re-pickable angles), 3 chapter cuts, 2 highlight")
        print("       markers+keywords, 2 captions (lane 1, iTT), 4 role-tagged stems — OK")

        // (h) DTD validity of the whole enriched document.
        try validateAgainstDTD(data: data)
    }

    // MARK: - DTD validation (best-effort bonus)

    private static func validateAgainstDTD(data: Data) throws {
        let candidates = [
            "/Applications/iMovie.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources/FCPXMLv1_11.dtd",
        ]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            print("  [3] DTD validation: SKIPPED (no FCPXMLv1_11.dtd on disk) — well-formedness + structure only")
            return
        }
        do {
            let doc = try XMLDocument(data: data, options: [])
            let dtd = try XMLDTD(contentsOf: URL(fileURLWithPath: path), options: [])
            dtd.name = "fcpxml"
            doc.dtd = dtd
            try doc.validate()
            print("  [3] DTD validation: PASSED against \((path as NSString).lastPathComponent)")
        } catch {
            // Report but do not fail the whole self-test on a DTD-loader hiccup;
            // structural asserts above are the hard bar.
            print("  [3] DTD validation: REPORTED INVALID/UNAVAILABLE — \(error)")
            throw SelfTestError.assertionFailed("DTD validation failed: \(error)")
        }
    }

    // MARK: - XPath helper

    private static func firstString(_ doc: XMLDocument, _ xpath: String) throws -> String? {
        try doc.nodes(forXPath: xpath).first?.stringValue
    }
}
