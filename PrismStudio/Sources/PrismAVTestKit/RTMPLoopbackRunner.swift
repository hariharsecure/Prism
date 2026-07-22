import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import os
import PrismCompositor
import PrismCore
import PrismOutput
import VideoToolbox

/// Live RTMP loopback verification (Roadmap Phase-1a, feasibility path **a**).
///
/// Where `AVRoundTripRunner` muxes the deterministic oracle sequence to a local
/// MOV and reads it straight back, this runner drives the **real network path**:
/// the production `RTMPStreamOutput` (HaishinKit FLV mux) publishes the synthetic
/// oracle sequence over a TCP RTMP socket to a headless local **MediaMTX**
/// receiver on a random loopback port. MediaMTX FLV-demuxes the live stream and
/// records it; we lossless-remux that recording to MOV (`ffmpeg -c copy`, no
/// re-encode), decode it, and apply the shared `AVRoundTripOracle`.
///
/// This proves — end to end, across a live socket — that the compositor →
/// VideoToolbox encode → FLV mux → RTMP transport → FLV demux path yields a
/// **valid, decodable stream** whose frame identity, ordering, per-patch pixel
/// fidelity, PTS monotonicity, range tag, and A/V co-presence survive the trip.
/// It is strictly more than a "bytes sent" count.
///
/// ## What is verified here vs. what still needs the operator
/// A live receiver rebaselines PTS to the moment recording begins and carries
/// only millisecond-quantized FLV timestamps, and a live capture legitimately
/// trims frames outside the recorded window. So this runner verifies the
/// **captured contiguous run** of oracle frames as a complete unit and applies
/// every gate *except* absolute A/V skew (`.avSkew`) — which the deterministic
/// `AVRoundTripRunner` verifies precisely. Reconnect-mid-stream, slow-consumer
/// backpressure, and ingest into a *real* platform (YouTube/Twitch) require a
/// provisioned server and are left to the operator harness
/// (`prism-dev stream rtmp <url>`).
public enum RTMPLoopbackRunner {
    public struct Diagnostics: Sendable {
        public let mediaMTXPath: String
        public let ffmpegPath: String
        public let rtmpURL: String
        public let publishedFrameCount: Int
        public let capturedFrameCount: Int
        public let verifiedRunLength: Int
        public let fullSequenceCaptured: Bool
        public let publishStates: [String]
    }

    public struct Result: Sendable {
        public let evidence: AVRoundTripEvidence
        public let verification: AVVerificationReport
        public let diagnostics: Diagnostics
        /// Lossless MOV remux of the MediaMTX recording (what the oracle read).
        public let movieURL: URL
        /// The raw fragmented-MP4 MediaMTX wrote from the live socket.
        public let recordingURL: URL

        public init(evidence: AVRoundTripEvidence,
                    verification: AVVerificationReport,
                    diagnostics: Diagnostics,
                    movieURL: URL,
                    recordingURL: URL) {
            self.evidence = evidence
            self.verification = verification
            self.diagnostics = diagnostics
            self.movieURL = movieURL
            self.recordingURL = recordingURL
        }
    }

    public enum LoopbackError: Error, CustomStringConvertible {
        /// A missing binary / port / capture — an XCTest capability skip, never a
        /// regression. If we could not stand up the receiver or capture enough of
        /// the stream, we decline rather than fail.
        case infrastructureUnavailable(String)
        /// The fixture encode failed for a genuine capability reason (no Metal /
        /// no hardware encoder) — also a skip.
        case runnerCapability(AVRoundTripRunner.RunError)
        case publish(String)
        /// We captured a full/partial stream but the oracle rejected it — a real
        /// regression that must fail the suite.
        case verificationFailed(evidenceURL: URL?, failure: AVOracleFailure)

        public var isInfrastructureUnavailable: Bool {
            switch self {
            case .infrastructureUnavailable, .runnerCapability: return true
            default: return false
            }
        }

        public var description: String {
            switch self {
            case .infrastructureUnavailable(let r): return "live RTMP loopback unavailable: \(r)"
            case .runnerCapability(let e): return "fixture capability unavailable: \(e)"
            case .publish(let r): return "RTMP publish failed: \(r)"
            case .verificationFailed(let url, let failure):
                return "live oracle rejected the captured stream (evidence: \(url?.path ?? "n/a")): \(failure)"
            }
        }
    }

    /// Gates verified over the live socket. `.avSkew` is intentionally excluded
    /// (see the type comment): millisecond-quantized, window-rebaselined live
    /// timestamps make absolute A/V skew a deterministic-path / operator concern.
    public static let liveGates: Set<AVOracleAssertionCode> = [
        .cleanFinalization, .frameCount, .frameIdentity, .frameOrdering,
        .patchMedians, .videoPTSMonotonicity, .audioPTSMonotonicity, .rangeTag,
    ]

    // MARK: Binary discovery

    public static func locateMediaMTX() -> URL? { locate("mediamtx", env: "PRISM_MEDIAMTX") }
    public static func locateFFmpeg() -> URL? { locate("ffmpeg", env: "PRISM_FFMPEG") }

    private static func locate(_ name: String, env: String) -> URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment[env],
           fm.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    // MARK: Run

    /// Publish the seeded oracle sequence to a headless MediaMTX over RTMP, pull
    /// the recording back, and verify it. Pre/post-roll padding (distinct
    /// sentinel frame IDs outside the oracle range) absorbs the receiver's
    /// inherent head/tail trim so the oracle's own frames survive intact.
    public static func run(
        configuration: AVRoundTripConfiguration = AVRoundTripConfiguration(),
        prerollFrames: Int = 14,
        postrollFrames: Int = 10,
        minVerifiedRun: Int? = nil,
        artifactRoot: URL? = nil
    ) async throws -> Result {
        guard let mediaMTX = locateMediaMTX() else {
            throw LoopbackError.infrastructureUnavailable("no `mediamtx` binary (set PRISM_MEDIAMTX)")
        }
        guard let ffmpeg = locateFFmpeg() else {
            throw LoopbackError.infrastructureUnavailable("no `ffmpeg` binary (set PRISM_FFMPEG)")
        }
        do { try configuration.validate() }
        catch { throw LoopbackError.runnerCapability(.invalidConfiguration(String(describing: error))) }

        // 1. Capability preflight: no Metal / no hardware encoder is a skip, not
        // a failure. (The real encode runs live during publish, below.)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw LoopbackError.runnerCapability(.metalUnavailable)
        }

        // 2. Working dir + MediaMTX config on a random loopback RTMP port.
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-rtmp-loopback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let recordRoot = workDir.appendingPathComponent("rec", isDirectory: true)
        let port = Int.random(in: 20000...39000)
        let streamPath = "prism/loop\(UInt32.random(in: 0..<UInt32.max))"
        let rtmpURL = "rtmp://127.0.0.1:\(port)/\(streamPath)"
        let logURL = workDir.appendingPathComponent("mediamtx.log")
        try writeMediaMTXConfig(to: workDir.appendingPathComponent("mediamtx.yml"),
                                port: port, recordRoot: recordRoot)

        // 3. Launch the receiver and wait for its RTMP listener.
        let server = Process()
        server.executableURL = mediaMTX
        server.arguments = [workDir.appendingPathComponent("mediamtx.yml").path]
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        server.standardOutput = logHandle
        server.standardError = logHandle
        var serverStopped = false
        func stopServer() {
            guard !serverStopped else { return }
            serverStopped = true
            if server.isRunning { server.interrupt() }        // SIGINT → flush recordings
            let deadline = Date().addingTimeInterval(6)
            while server.isRunning, Date() < deadline { usleep(50_000) }
            if server.isRunning { server.terminate() }
            try? logHandle.close()
        }
        defer { stopServer() }

        do { try server.run() }
        catch { throw LoopbackError.infrastructureUnavailable("mediamtx launch: \(error)") }
        guard waitForPort(port, timeout: 6) else {
            throw LoopbackError.infrastructureUnavailable(
                "mediamtx RTMP listener never came up on :\(port)")
        }
        // The listener accepts a beat before its accept/handshake path is fully
        // ready; connecting too early can stall the RTMP connect command.
        try? await Task.sleep(nanoseconds: 800_000_000)

        // 4. Publish through the production RTMP output actor.
        let states = OSAllocatedUnfairLock<[String]>(initialState: [])
        let output = RTMPStreamOutput(settings: .init(
            codec: .h264, width: configuration.width, height: configuration.height,
            videoBitrate: configuration.videoBitrate,
            keyframeInterval: 2, expectedFrameRate: Double(configuration.fps),
            lowLatencyRateControl: true))
        let stateTask = Task { for await s in await output.stateUpdates { states.withLock { $0.append("\(s)") } } }

        let (app, key) = splitRTMPURL(rtmpURL)
        do { try await output.connect(url: app, streamKey: key) }
        catch {
            stateTask.cancel()
            throw LoopbackError.infrastructureUnavailable("connect to local mediamtx: \(error)")
        }
        // Let the publish handshake settle before the first media lands.
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Drive the production encode → RTMP path LIVE, in real time, exactly as
        // a running broadcast does: continuous media from the moment of publish
        // is what makes the receiver register and record the stream.
        let live: LiveDrive
        do {
            live = try await driveLivePublish(
                output: output, configuration: configuration,
                prerollFrames: max(0, prerollFrames), postrollFrames: max(0, postrollFrames))
        } catch let e as AVRoundTripRunner.RunError where e.isCapabilityUnavailable {
            stateTask.cancel(); throw LoopbackError.runnerCapability(e)
        } catch {
            stateTask.cancel(); throw LoopbackError.publish("live encode: \(error)")
        }
        let encoded = live

        // Drain, then close cleanly so HK finalizes the FLV stream.
        try? await Task.sleep(nanoseconds: 600_000_000)
        let preCloseStats = await output.stats()
        states.withLock { $0.append("appended v=\(preCloseStats.videoFramesAppended) a=\(preCloseStats.audioBuffersAppended) drop=\(preCloseStats.appendsDropped) bytesOut=\(preCloseStats.bytesOut)") }
        await output.close()
        stateTask.cancel()
        try? await Task.sleep(nanoseconds: 400_000_000)
        stopServer() // finalize the recording on disk

        // 5. Locate the recording and lossless-remux to MOV for AVFoundation.
        guard let recording = try newestRecording(under: recordRoot, timeout: 4) else {
            let serverLog = (try? String(contentsOf: logURL, encoding: .utf8))?
                .split(separator: "\n").suffix(12).joined(separator: " | ") ?? "no log"
            throw LoopbackError.infrastructureUnavailable(
                "mediamtx produced no recording (states: \(states.withLock { $0 })); server: \(serverLog)")
        }
        let movieURL = workDir.appendingPathComponent("loopback.mov")
        try remux(ffmpeg: ffmpeg, input: recording, output: movieURL)

        // 6. Decode + build evidence for the captured contiguous oracle run.
        let asset = AVURLAsset(url: movieURL)
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard let videoTrack = videoTracks.first else {
            throw LoopbackError.infrastructureUnavailable("captured stream had no video track")
        }
        let video = try await AVRoundTripRunner.decodeVideo(
            asset: asset, track: videoTrack, expectedPatches: encoded.expectedPatches)
        let audio: AVRoundTripRunner.AudioDecodeResult?
        if let audioTrack = audioTracks.first {
            audio = try await AVRoundTripRunner.decodeAudio(
                asset: asset, track: audioTrack,
                sampleRate: Double(configuration.audioSampleRate))
        } else {
            audio = nil
        }

        // Trim to the maximal contiguous ascending run of in-range oracle IDs.
        let floor = minVerifiedRun ?? max(6, configuration.frameCount / 2)
        let run = longestContiguousRun(video.frames, maxID: configuration.frameCount - 1)
        guard run.count >= floor else {
            throw LoopbackError.infrastructureUnavailable(
                "captured only \(run.count) contiguous oracle frames (need \(floor); "
                + "decoded \(video.frames.count) total)")
        }
        let fullCapture = run.count == configuration.frameCount

        let trimmedFrames = run.enumerated().map { index, frame in
            DecodedVideoFrameEvidence(sequenceIndex: index,
                                      embeddedFrameID: frame.embeddedFrameID,
                                      ptsSeconds: frame.ptsSeconds,
                                      patchMedians: frame.patchMedians)
        }
        let expectedIDs = run.compactMap(\.embeddedFrameID)
        let audioPTS = audio?.samplePTS ?? []

        let evidence = AVRoundTripEvidence(
            configuration: configuration,
            expectedFrameIDs: expectedIDs,
            expectedPatches: encoded.expectedPatches,
            expectedAudioEvents: encoded.expectedAudioEvents,
            decodedFrames: trimmedFrames,
            observedRangeTag: video.rangeTag,
            audioSamplePTSSeconds: audioPTS,
            detectedAudioEvents: [], // .avSkew is not a live gate; see type comment
            finalization: FinalizationEvidence(
                writerCompleted: true,
                videoReaderCompleted: video.readerCompleted,
                audioReaderCompleted: audio?.readerCompleted ?? false,
                fileExists: FileManager.default.fileExists(atPath: movieURL.path),
                bytesWritten: fileSize(movieURL),
                videoTrackCount: videoTracks.count,
                audioTrackCount: audioTracks.count,
                muxedVideoFrameCount: trimmedFrames.count,
                muxedAudioSampleCount: audioPTS.count))

        let diagnostics = Diagnostics(
            mediaMTXPath: mediaMTX.path, ffmpegPath: ffmpeg.path, rtmpURL: rtmpURL,
            publishedFrameCount: encoded.publishedFrameCount,
            capturedFrameCount: video.frames.count,
            verifiedRunLength: run.count, fullSequenceCaptured: fullCapture,
            publishStates: states.withLock { $0 })

        // Copy the artifacts out of the auto-deleted work dir.
        let outDir = (artifactRoot ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("prism-rtmp-loopback-evidence-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let keptMovie = outDir.appendingPathComponent("loopback.mov")
        let keptRec = outDir.appendingPathComponent(recording.lastPathComponent)
        try? FileManager.default.copyItem(at: movieURL, to: keptMovie)
        try? FileManager.default.copyItem(at: recording, to: keptRec)

        do {
            let verification = try AVRoundTripOracle.verify(evidence, gates: liveGates)
            return Result(evidence: evidence, verification: verification,
                          diagnostics: diagnostics, movieURL: keptMovie, recordingURL: keptRec)
        } catch let failure as AVOracleFailure {
            throw LoopbackError.verificationFailed(evidenceURL: keptMovie, failure: failure)
        }
    }

    // MARK: Live encode → publish

    struct LiveDrive {
        let expectedPatches: [ExpectedVideoPatch]
        let expectedAudioEvents: [ExpectedAudioEvent]
        let publishedFrameCount: Int
    }

    /// Drive the compositor → VideoToolbox encode → `RTMPStreamOutput` path in
    /// real time on a **dedicated thread** (as the production `StreamVideoRig` /
    /// `RenderLoop` does), timestamped in **house time**. Running the synchronous
    /// Metal composite + VideoToolbox encode off the Swift-concurrency
    /// cooperative pool is what lets HaishinKit's actor/network keep draining —
    /// driving it inline stalls the RTMP publish so the receiver never registers
    /// the stream. Sentinel-ID pre/post-roll frames absorb the receiver's
    /// head/tail trim so the oracle's own frames survive intact.
    private static func driveLivePublish(
        output: RTMPStreamOutput,
        configuration: AVRoundTripConfiguration,
        prerollFrames: Int,
        postrollFrames: Int
    ) async throws -> LiveDrive {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LiveDrive, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try runLiveDrive(
                    output: output, configuration: configuration,
                    prerollFrames: prerollFrames, postrollFrames: postrollFrames)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func runLiveDrive(
        output: RTMPStreamOutput,
        configuration: AVRoundTripConfiguration,
        prerollFrames: Int,
        postrollFrames: Int
    ) throws -> LiveDrive {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw AVRoundTripRunner.RunError.metalUnavailable
        }
        let fixtureGenerator = try VideoFixtureGenerator(configuration: configuration)
        let compositor = try MetalCompositor(device: device,
                                             width: configuration.width,
                                             height: configuration.height)
        let scene = Scene(name: "rtmp-loopback-fixture", layers: [
            Layer(sourceID: fixtureGenerator.sourceID, premultipliedAlpha: true),
        ])
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(configuration.fps))

        let encoder = ProgramEncoder(settings: .init(
            codec: .h264, width: configuration.width, height: configuration.height,
            averageBitrate: configuration.videoBitrate,
            // Sub-second keyframes: a receiver only brings a track "online" after
            // a full GOP, so a short loopback needs several IDRs to register.
            keyframeInterval: 0.4, expectedFrameRate: Double(configuration.fps),
            lowLatencyRateControl: true, dynamicRange: .sdr))
        // Live: hand each encoded frame straight to the RTMP socket.
        encoder.onEncodedFrame = { buf in output.append(encodedVideo: buf) }
        do { try encoder.start() }
        catch ProgramEncoder.EncoderError.sessionCreationFailed(let status)
            where AVRoundTripRunner.isEncoderCapabilityStatus(status) {
            throw AVRoundTripRunner.RunError.hardwareEncoderUnavailable(status)
        }

        // Sentinel IDs live outside the oracle range [0, frameCount-1] so the
        // decoder-side run finder ignores them.
        let prerollIDs = (0..<prerollFrames).map { 60_000 + $0 }
        let mainIDs = Array(0..<configuration.frameCount)
        let postrollIDs = (0..<postrollFrames).map { 61_000 + $0 }

        // House-time PTS, exactly as the production stream path: real host clock,
        // advanced by wall-clock elapsed between frames.
        var audioPackets: [CMSampleBuffer] = []
        var audioIdx = 0
        var expectedAudioEvents: [ExpectedAudioEvent] = []
        var expectedPatches: [ExpectedVideoPatch] = []
        let framePeriodMicros: UInt32 = UInt32(1_000_000 / max(1, configuration.fps))
        encoder.forceKeyframe()
        for (phase, ids) in [prerollIDs, mainIDs, postrollIDs].enumerated() {
            for id in ids {
                let pts = HouseClock.now()
                if phase == 1 && audioPackets.isEmpty {
                    // Generate the deterministic fixture audio anchored to the
                    // first oracle frame's house-time PTS.
                    let mainDuration = CMTimeMultiply(frameDuration, multiplier: Int32(configuration.frameCount))
                    let fixture = try AudioFixtureGenerator(configuration: configuration)
                        .makePackets(startPTS: pts, duration: mainDuration)
                    audioPackets = fixture.packets
                    expectedAudioEvents = fixture.expectedEvents
                }
                let fixture = try fixtureGenerator.makeFrame(id: id, pts: pts)
                if phase == 1 && expectedPatches.isEmpty { expectedPatches = fixture.expectedPatches }
                let program = try compositor.composite(
                    frames: [fixtureGenerator.sourceID: fixture.frame],
                    scene: scene, pts: pts, duration: frameDuration)
                try encoder.encode(program) // callback → output.append(encodedVideo:)
                while audioIdx < audioPackets.count,
                      CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(audioPackets[audioIdx]))
                        <= pts.seconds {
                    output.append(audio: audioPackets[audioIdx]); audioIdx += 1
                }
                usleep(framePeriodMicros) // real-time pacing on this dedicated thread
            }
        }
        while audioIdx < audioPackets.count { output.append(audio: audioPackets[audioIdx]); audioIdx += 1 }
        encoder.flush()
        encoder.stop() // delivery barrier — every encoded frame has been appended

        return LiveDrive(expectedPatches: expectedPatches,
                         expectedAudioEvents: expectedAudioEvents,
                         publishedFrameCount: prerollIDs.count + mainIDs.count + postrollIDs.count)
    }

    // MARK: Capture helpers

    private static func longestContiguousRun(
        _ frames: [DecodedVideoFrameEvidence], maxID: Int
    ) -> [DecodedVideoFrameEvidence] {
        let inRange = frames.filter { ($0.embeddedFrameID).map { (0...maxID).contains($0) } ?? false }
        var best: [DecodedVideoFrameEvidence] = []
        var current: [DecodedVideoFrameEvidence] = []
        for frame in inRange {
            if let prev = current.last?.embeddedFrameID, let id = frame.embeddedFrameID, id == prev + 1 {
                current.append(frame)
            } else {
                current = [frame]
            }
            if current.count > best.count { best = current }
        }
        return best
    }

    private static func writeMediaMTXConfig(to url: URL, port: Int, recordRoot: URL) throws {
        // Only the random RTMP port is bound; every other listener (RTSP, HLS,
        // WebRTC, SRT, MoQ, API, metrics, pprof, playback) is disabled so
        // concurrent runs never collide on a fixed port.
        let yaml = """
        logLevel: error
        api: no
        metrics: no
        pprof: no
        playback: no
        rtsp: no
        rtmp: yes
        rtmpAddress: 127.0.0.1:\(port)
        rtmpEncryption: "no"
        hls: no
        webrtc: no
        srt: no
        moq: no
        pathDefaults:
          record: yes
          recordPath: \(recordRoot.path)/%path/seg_%Y-%m-%d_%H-%M-%S-%f
          recordFormat: fmp4
          recordSegmentDuration: 1h
        paths:
          all_others:
        """
        try yaml.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Poll a loopback TCP port until something is accepting (log-level agnostic).
    private static func waitForPort(_ port: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if canConnect(port: port) { return true }
            usleep(50_000)
        }
        return false
    }

    private static func canConnect(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private static func newestRecording(under root: URL, timeout: TimeInterval) throws -> URL? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let hit = recordings(under: root).first { return hit }
            usleep(100_000)
        }
        return recordings(under: root).first
    }

    private static func recordings(under root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return e.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "mp4" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }
    }

    private static func remux(ffmpeg: URL, input: URL, output: URL) throws {
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = ["-y", "-loglevel", "error", "-i", input.path,
                       "-c", "copy", "-movflags", "+faststart", output.path]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw LoopbackError.infrastructureUnavailable("ffmpeg remux failed (\(p.terminationStatus)): \(msg)")
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func splitRTMPURL(_ url: String) -> (app: String, key: String) {
        // rtmp://host:port/a/b/key  →  app = everything up to the last path
        // component, key = the last component.
        guard let slash = url.lastIndex(of: "/") else { return (url, "") }
        return (String(url[url.startIndex..<slash]), String(url[url.index(after: slash)...]))
    }
}
