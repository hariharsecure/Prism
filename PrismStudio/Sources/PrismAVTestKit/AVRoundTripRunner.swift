import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import PrismCompositor
import PrismCore
import PrismOutput
import VideoToolbox

/// Runs the Phase-1 deterministic verification spine through the production
/// compositor, explicit VideoToolbox encoder, replay MOV muxer, and decoder.
public enum AVRoundTripRunner {
    public struct Result: Sendable {
        public let evidence: AVRoundTripEvidence
        public let verification: AVVerificationReport
        public let artifact: EvidenceArtifact
        public let movieURL: URL

        public init(evidence: AVRoundTripEvidence,
                    verification: AVVerificationReport,
                    artifact: EvidenceArtifact,
                    movieURL: URL) {
            self.evidence = evidence
            self.verification = verification
            self.artifact = artifact
            self.movieURL = movieURL
        }
    }

    public enum RunError: Error, CustomStringConvertible {
        case invalidConfiguration(String)
        case metalUnavailable
        case hardwareEncoderUnavailable(OSStatus)
        case encoderSetup(String)
        case encode(String)
        case mux(String)
        case asset(String)
        case videoDecode(String)
        case audioDecode(String)
        case evidenceWrite(String)
        case verificationFailed(evidenceURL: URL, failure: AVOracleFailure)

        /// Only these conditions are capability skips in XCTest. Configuration,
        /// encode, mux, decode, and oracle failures are regressions.
        public var isCapabilityUnavailable: Bool {
            switch self {
            case .metalUnavailable, .hardwareEncoderUnavailable: return true
            default: return false
            }
        }

        public var description: String {
            switch self {
            case .invalidConfiguration(let reason):
                return "invalid A/V fixture configuration: \(reason)"
            case .metalUnavailable:
                return "no Metal device is available"
            case .hardwareEncoderUnavailable(let status):
                return "hardware H.264 encoder unavailable (VideoToolbox \(status))"
            case .encoderSetup(let reason): return "VideoToolbox setup failed: \(reason)"
            case .encode(let reason): return "composite/encode failed: \(reason)"
            case .mux(let reason): return "MOV mux failed: \(reason)"
            case .asset(let reason): return "muxed asset is invalid: \(reason)"
            case .videoDecode(let reason): return "video decode failed: \(reason)"
            case .audioDecode(let reason): return "audio decode failed: \(reason)"
            case .evidenceWrite(let reason): return "JSON evidence write failed: \(reason)"
            case .verificationFailed(let url, let failure):
                return "A/V oracle rejected the run (evidence: \(url.path)): \(failure)"
            }
        }
    }

    struct VideoDecodeResult {
        let frames: [DecodedVideoFrameEvidence]
        let rangeTag: VideoRangeTag
        let readerCompleted: Bool
    }

    struct AudioDecodeResult {
        let samplePTS: [Double]
        let impulsePTS: [Double]
        let readerCompleted: Bool
    }

    /// Execute and verify one seeded run. `artifactRoot` is a parent directory;
    /// a unique run child containing `evidence.json` is created beneath it.
    public static func run(
        configuration: AVRoundTripConfiguration = AVRoundTripConfiguration(),
        artifactRoot: URL? = nil
    ) async throws -> Result {
        guard configuration.width >= 320, configuration.height >= 176 else {
            throw RunError.invalidConfiguration("minimum fixture canvas is 320x176")
        }
        guard configuration.fps > 0, configuration.frameCount > 0 else {
            throw RunError.invalidConfiguration("fps and frameCount must be positive")
        }
        guard configuration.frameCount <= Int(UInt16.max) else {
            throw RunError.invalidConfiguration("frameCount exceeds 16-bit embedded ID capacity")
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw RunError.metalUnavailable }

        let fixtureGenerator: VideoFixtureGenerator
        do { fixtureGenerator = try VideoFixtureGenerator(configuration: configuration) }
        catch { throw RunError.invalidConfiguration(String(describing: error)) }

        let compositor: MetalCompositor
        do {
            compositor = try MetalCompositor(device: device,
                                             width: configuration.width,
                                             height: configuration.height)
        } catch {
            throw RunError.encoderSetup("MetalCompositor: \(error)")
        }

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(configuration.fps))
        let mediaDuration = CMTimeMultiply(frameDuration, multiplier: Int32(configuration.frameCount))
        let clock = VirtualMediaClock(start: .zero)
        let scene = Scene(name: "deterministic-av-fixture", layers: [
            Layer(sourceID: fixtureGenerator.sourceID, premultipliedAlpha: true),
        ])

        let replaySeconds = max(2.0, mediaDuration.seconds + 1.0)
        let replay = ReplayBuffer(seconds: replaySeconds, fragmentInterval: 0.25)
        let encoder = ProgramEncoder(settings: .init(
            codec: .h264,
            width: configuration.width,
            height: configuration.height,
            averageBitrate: configuration.videoBitrate,
            keyframeInterval: replaySeconds,
            expectedFrameRate: Double(configuration.fps),
            lowLatencyRateControl: false,
            dynamicRange: .sdr
        ))
        encoder.onEncodedFrame = { replay.append($0) }

        do {
            try encoder.start()
        } catch ProgramEncoder.EncoderError.sessionCreationFailed(let status)
            where isEncoderCapabilityStatus(status) {
            throw RunError.hardwareEncoderUnavailable(status)
        } catch {
            throw RunError.encoderSetup(String(describing: error))
        }

        var expectedIDs: [Int] = []
        var expectedPatches: [ExpectedVideoPatch] = []
        do {
            // ReplayBuffer discards leading non-sync samples, so make the first
            // submitted fixture an explicit keyframe.
            encoder.forceKeyframe()
            for id in 0..<configuration.frameCount {
                let pts = clock.now()
                let fixture = try fixtureGenerator.makeFrame(id: id, pts: pts)
                if expectedPatches.isEmpty { expectedPatches = fixture.expectedPatches }
                expectedIDs.append(fixture.frameID)
                let program = try compositor.composite(
                    frames: [fixtureGenerator.sourceID: fixture.frame],
                    scene: scene,
                    pts: pts,
                    duration: frameDuration
                )
                try encoder.encode(program)
                _ = clock.advance(by: frameDuration)
            }
            encoder.flush()
            encoder.stop() // completion + delivery barrier; all replay appends landed
        } catch {
            encoder.stop()
            throw RunError.encode(String(describing: error))
        }

        let audioFixture: GeneratedAudioFixture
        do {
            audioFixture = try AudioFixtureGenerator(configuration: configuration)
                .makePackets(startPTS: .zero, duration: mediaDuration)
            for packet in audioFixture.packets { replay.appendAudio(packet) }
        } catch {
            throw RunError.encode("audio fixture: \(error)")
        }

        let movieRequest = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-av-roundtrip-\(String(configuration.seed, radix: 16))-\(UUID().uuidString).mov")
        let clip: ReplayBuffer.ClipReport
        do { clip = try await replay.saveClip(to: movieRequest) }
        catch { throw RunError.mux(String(describing: error)) }

        let asset = AVURLAsset(url: clip.url)
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw RunError.asset("track load: \(error)")
        }
        guard let videoTrack = videoTracks.first else { throw RunError.asset("no video track") }
        guard let audioTrack = audioTracks.first else { throw RunError.asset("no audio track") }

        let video = try await decodeVideo(asset: asset, track: videoTrack,
                                          expectedPatches: expectedPatches)
        let audio = try await decodeAudio(asset: asset, track: audioTrack,
                                          sampleRate: Double(configuration.audioSampleRate))
        let detectedEvents = matchImpulses(audio.impulsePTS,
                                           expected: audioFixture.expectedEvents)

        let fileExists = FileManager.default.fileExists(atPath: clip.url.path)
        let fileBytes = ((try? FileManager.default.attributesOfItem(atPath: clip.url.path))?[.size]
            as? NSNumber)?.int64Value ?? clip.bytesWritten
        let evidence = AVRoundTripEvidence(
            configuration: configuration,
            expectedFrameIDs: expectedIDs,
            expectedPatches: expectedPatches,
            expectedAudioEvents: audioFixture.expectedEvents,
            decodedFrames: video.frames,
            observedRangeTag: video.rangeTag,
            audioSamplePTSSeconds: audio.samplePTS,
            detectedAudioEvents: detectedEvents,
            finalization: FinalizationEvidence(
                writerCompleted: true,
                videoReaderCompleted: video.readerCompleted,
                audioReaderCompleted: audio.readerCompleted,
                fileExists: fileExists,
                bytesWritten: fileBytes,
                videoTrackCount: videoTracks.count,
                audioTrackCount: audioTracks.count,
                muxedVideoFrameCount: clip.frameCount,
                muxedAudioSampleCount: clip.audioSampleCount
            )
        )

        let artifact: EvidenceArtifact
        do { artifact = try JSONEvidenceArtifactWriter(rootDirectory: artifactRoot).write(evidence) }
        catch { throw RunError.evidenceWrite(String(describing: error)) }

        do {
            let verification = try AVRoundTripOracle.verify(evidence)
            return Result(evidence: evidence, verification: verification,
                          artifact: artifact, movieURL: clip.url)
        } catch let failure as AVOracleFailure {
            throw RunError.verificationFailed(evidenceURL: artifact.evidenceURL, failure: failure)
        }
    }

    static func isEncoderCapabilityStatus(_ status: OSStatus) -> Bool {
        status == kVTCouldNotFindVideoEncoderErr
            || status == kVTVideoEncoderNotAvailableNowErr
            || status == kVTVideoEncoderNeedsRosettaErr
    }

    static func decodeVideo(asset: AVAsset,
                                    track: AVAssetTrack,
                                    expectedPatches: [ExpectedVideoPatch]) async throws -> VideoDecodeResult {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw RunError.videoDecode("reader creation: \(error)") }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RunError.videoDecode("cannot add BGRA output") }
        reader.add(output)
        guard reader.startReading() else {
            throw RunError.videoDecode("startReading: \(String(describing: reader.error))")
        }

        var frames: [DecodedVideoFrameEvidence] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                throw RunError.videoDecode("decoded sample has no image buffer")
            }
            let frameID: Int?
            do { frameID = try VideoFixtureGenerator.decodeFrameID(from: pixelBuffer) }
            catch { frameID = nil }
            var medians: [PatchMedianEvidence] = []
            for patch in expectedPatches {
                let rgb: RGBValue
                do { rgb = try VideoFixtureGenerator.medianRGB(in: pixelBuffer, rect: patch.rect) }
                catch { throw RunError.videoDecode("patch \(patch.name): \(error)") }
                medians.append(PatchMedianEvidence(name: patch.name,
                                                   r: Double(rgb.r),
                                                   g: Double(rgb.g),
                                                   b: Double(rgb.b)))
            }
            frames.append(DecodedVideoFrameEvidence(
                sequenceIndex: frames.count,
                embeddedFrameID: frameID,
                ptsSeconds: CMSampleBufferGetPresentationTimeStamp(sample).seconds,
                patchMedians: medians
            ))
        }
        let completed = reader.status == .completed

        let rangeTag: VideoRangeTag
        do {
            let descriptions = try await track.load(.formatDescriptions)
            if let desc = descriptions.first,
               let extensionValue = CMFormatDescriptionGetExtension(
                    desc, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo),
               CFEqual(extensionValue, kCFBooleanTrue) {
                rangeTag = .full
            } else {
                // CoreMedia specifies absent FullRangeVideo as video range for
                // Y'CbCr compressed formats.
                rangeTag = .video
            }
        } catch {
            throw RunError.videoDecode("format-description range tag: \(error)")
        }
        return VideoDecodeResult(frames: frames, rangeTag: rangeTag,
                                 readerCompleted: completed)
    }

    static func decodeAudio(asset: AVAsset,
                                    track: AVAssetTrack,
                                    sampleRate: Double) async throws -> AudioDecodeResult {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw RunError.audioDecode("reader creation: \(error)") }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw RunError.audioDecode("cannot add Float32 PCM output") }
        reader.add(output)
        guard reader.startReading() else {
            throw RunError.audioDecode("startReading: \(String(describing: reader.error))")
        }

        var packetPTS: [Double] = []
        var impulsePTS: [Double] = []
        var wasAboveImpulseThreshold = false
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            packetPTS.append(pts)
            guard let block = CMSampleBufferGetDataBuffer(sample) else {
                throw RunError.audioDecode("decoded PCM sample has no data buffer")
            }
            let byteCount = CMBlockBufferGetDataLength(block)
            guard byteCount >= MemoryLayout<Float>.size else { continue }
            var bytes = [UInt8](repeating: 0, count: byteCount)
            let status = bytes.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount,
                                           destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else {
                throw RunError.audioDecode("CMBlockBufferCopyDataBytes \(status)")
            }
            bytes.withUnsafeBytes { raw in
                let values = raw.bindMemory(to: Float.self)
                for i in values.indices {
                    let above = abs(values[i]) >= 0.75
                    if above && !wasAboveImpulseThreshold {
                        impulsePTS.append(pts + Double(i) / sampleRate)
                    }
                    wasAboveImpulseThreshold = above
                }
            }
        }
        return AudioDecodeResult(samplePTS: packetPTS, impulsePTS: impulsePTS,
                                 readerCompleted: reader.status == .completed)
    }

    static func matchImpulses(_ detected: [Double],
                                      expected: [ExpectedAudioEvent]) -> [DetectedAudioEventEvidence] {
        var available = detected
        var matches: [DetectedAudioEventEvidence] = []
        for event in expected where event.kind == .impulse {
            let index = available.indices.min { a, b in
                abs(available[a] - event.offsetSeconds) < abs(available[b] - event.offsetSeconds)
            }
            let pts: Double
            if let index {
                pts = available.remove(at: index)
            } else {
                // Finite sentinel remains JSON-encodable and is guaranteed to
                // violate the A/V skew budget.
                pts = -1
            }
            matches.append(DetectedAudioEventEvidence(
                kind: event.kind,
                expectedOffsetSeconds: event.offsetSeconds,
                detectedPTSSeconds: pts
            ))
        }
        return matches
    }
}
