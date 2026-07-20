import Foundation

// MARK: - Decoded evidence

/// Median decoded RGB value for one named fixture patch.
public struct PatchMedianEvidence: Codable, Equatable, Sendable {
    public let name: String
    public let r: Double
    public let g: Double
    public let b: Double

    public init(name: String, r: Double, g: Double, b: Double) {
        self.name = name
        self.r = r
        self.g = g
        self.b = b
    }
}

/// Evidence recovered from one decoded video sample.
public struct DecodedVideoFrameEvidence: Codable, Equatable, Sendable {
    public let sequenceIndex: Int
    public let embeddedFrameID: Int?
    public let ptsSeconds: Double
    public let patchMedians: [PatchMedianEvidence]

    public init(sequenceIndex: Int,
                embeddedFrameID: Int?,
                ptsSeconds: Double,
                patchMedians: [PatchMedianEvidence]) {
        self.sequenceIndex = sequenceIndex
        self.embeddedFrameID = embeddedFrameID
        self.ptsSeconds = ptsSeconds
        self.patchMedians = patchMedians
    }
}

/// One audio event recovered from decoded PCM.
public struct DetectedAudioEventEvidence: Codable, Equatable, Sendable {
    public let kind: AudioSignalKind
    public let expectedOffsetSeconds: Double
    public let detectedPTSSeconds: Double

    public init(kind: AudioSignalKind,
                expectedOffsetSeconds: Double,
                detectedPTSSeconds: Double) {
        self.kind = kind
        self.expectedOffsetSeconds = expectedOffsetSeconds
        self.detectedPTSSeconds = detectedPTSSeconds
    }
}

/// Lifecycle and container facts gathered independently after the round trip.
public struct FinalizationEvidence: Codable, Equatable, Sendable {
    public let writerCompleted: Bool
    public let videoReaderCompleted: Bool
    public let audioReaderCompleted: Bool
    public let fileExists: Bool
    public let bytesWritten: Int64
    public let videoTrackCount: Int
    public let audioTrackCount: Int
    public let muxedVideoFrameCount: Int
    public let muxedAudioSampleCount: Int

    public init(writerCompleted: Bool,
                videoReaderCompleted: Bool,
                audioReaderCompleted: Bool,
                fileExists: Bool,
                bytesWritten: Int64,
                videoTrackCount: Int,
                audioTrackCount: Int,
                muxedVideoFrameCount: Int,
                muxedAudioSampleCount: Int) {
        self.writerCompleted = writerCompleted
        self.videoReaderCompleted = videoReaderCompleted
        self.audioReaderCompleted = audioReaderCompleted
        self.fileExists = fileExists
        self.bytesWritten = bytesWritten
        self.videoTrackCount = videoTrackCount
        self.audioTrackCount = audioTrackCount
        self.muxedVideoFrameCount = muxedVideoFrameCount
        self.muxedAudioSampleCount = muxedAudioSampleCount
    }
}

/// Stable, JSON-serializable evidence gathered by a deterministic A/V run.
public struct AVRoundTripEvidence: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let configuration: AVRoundTripConfiguration
    public let expectedFrameIDs: [Int]
    public let expectedPatches: [ExpectedVideoPatch]
    public let expectedAudioEvents: [ExpectedAudioEvent]
    public var decodedFrames: [DecodedVideoFrameEvidence]
    public var observedRangeTag: VideoRangeTag
    public var audioSamplePTSSeconds: [Double]
    public var detectedAudioEvents: [DetectedAudioEventEvidence]
    public let finalization: FinalizationEvidence

    public init(schemaVersion: Int = 1,
                configuration: AVRoundTripConfiguration,
                expectedFrameIDs: [Int],
                expectedPatches: [ExpectedVideoPatch],
                expectedAudioEvents: [ExpectedAudioEvent],
                decodedFrames: [DecodedVideoFrameEvidence],
                observedRangeTag: VideoRangeTag,
                audioSamplePTSSeconds: [Double],
                detectedAudioEvents: [DetectedAudioEventEvidence],
                finalization: FinalizationEvidence) {
        self.schemaVersion = schemaVersion
        self.configuration = configuration
        self.expectedFrameIDs = expectedFrameIDs
        self.expectedPatches = expectedPatches
        self.expectedAudioEvents = expectedAudioEvents
        self.decodedFrames = decodedFrames
        self.observedRangeTag = observedRangeTag
        self.audioSamplePTSSeconds = audioSamplePTSSeconds
        self.detectedAudioEvents = detectedAudioEvents
        self.finalization = finalization
    }
}

// MARK: - Verification result

public enum AVOracleAssertionCode: String, Codable, Equatable, CaseIterable, Sendable {
    case cleanFinalization
    case frameCount
    case frameIdentity
    case frameOrdering
    case patchMedians
    case videoPTSMonotonicity
    case audioPTSMonotonicity
    case rangeTag
    case avSkew
}

public struct AVOracleAssertionResult: Codable, Equatable, Sendable {
    public let code: AVOracleAssertionCode
    public let passed: Bool
    public let message: String

    public init(code: AVOracleAssertionCode, passed: Bool, message: String) {
        self.code = code
        self.passed = passed
        self.message = message
    }
}

public struct AVVerificationReport: Codable, Equatable, Sendable, CustomStringConvertible {
    public let assertions: [AVOracleAssertionResult]
    public let evidenceLines: [String]

    public init(assertions: [AVOracleAssertionResult], evidenceLines: [String]) {
        self.assertions = assertions
        self.evidenceLines = evidenceLines
    }

    public var assertionResults: [AVOracleAssertionResult] { assertions }
    public var passed: Bool { assertions.allSatisfy(\.passed) }

    public var description: String {
        let passedCount = assertions.lazy.filter(\.passed).count
        return "A/V verification \(passed ? "PASS" : "FAIL") (\(passedCount)/\(assertions.count) assertions)"
    }
}

public struct AVOracleViolation: Codable, Equatable, Sendable {
    public let code: AVOracleAssertionCode
    public let message: String

    public init(code: AVOracleAssertionCode, message: String) {
        self.code = code
        self.message = message
    }
}

public struct AVOracleFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public let violations: [AVOracleViolation]

    public init(violations: [AVOracleViolation]) {
        self.violations = violations
    }

    public var description: String {
        let details = violations.map { "[\($0.code.rawValue)] \($0.message)" }.joined(separator: "; ")
        return "A/V verification failed with \(violations.count) violation\(violations.count == 1 ? "" : "s"): \(details)"
    }
}

// MARK: - Oracle

public enum AVRoundTripOracle {
    /// Verify all independent evidence, collecting every failure before throwing.
    public static func verify(_ evidence: AVRoundTripEvidence) throws -> AVVerificationReport {
        var violations: [AVOracleViolation] = []

        verifyFinalization(evidence, into: &violations)
        verifyFrameCount(evidence, into: &violations)
        verifyFrameIdentity(evidence, into: &violations)
        verifyFrameOrdering(evidence, into: &violations)
        verifyPatchMedians(evidence, into: &violations)
        verifyVideoPTS(evidence, into: &violations)
        verifyAudioPTS(evidence, into: &violations)
        verifyRangeTag(evidence, into: &violations)
        let maximumSkewMilliseconds = verifyAVSkew(evidence, into: &violations)

        guard violations.isEmpty else { throw AVOracleFailure(violations: violations) }

        let expectedImpulseCount = evidence.expectedAudioEvents.lazy.filter { $0.kind == .impulse }.count
        let assertionMessages: [AVOracleAssertionCode: String] = [
            .cleanFinalization: "writer and both readers completed; one video and one audio track",
            .frameCount: "decoded \(evidence.decodedFrames.count) expected frames",
            .frameIdentity: "every embedded frame ID matched its expected position",
            .frameOrdering: "embedded frame IDs were unique and strictly increasing",
            .patchMedians: "all \(evidence.expectedPatches.count) named patches stayed within RGB tolerance",
            .videoPTSMonotonicity: "\(evidence.decodedFrames.count) video PTS values were strictly increasing",
            .audioPTSMonotonicity: "\(evidence.audioSamplePTSSeconds.count) audio PTS values were strictly increasing",
            .rangeTag: "decoded range tag matched \(evidence.configuration.expectedRangeTag.rawValue)",
            .avSkew: String(format: "%d impulse events stayed within %.3f ms (max %.3f ms)",
                            expectedImpulseCount,
                            evidence.configuration.avSkewBudgetMilliseconds,
                            maximumSkewMilliseconds),
        ]
        let assertions = AVOracleAssertionCode.allCases.map {
            AVOracleAssertionResult(code: $0, passed: true, message: assertionMessages[$0] ?? "passed")
        }
        let finalization = evidence.finalization
        let evidenceLines = [
            "finalization: writer/readers complete, tracks=\(finalization.videoTrackCount)V+\(finalization.audioTrackCount)A, bytes=\(finalization.bytesWritten)",
            "video: decoded=\(evidence.decodedFrames.count)/\(evidence.expectedFrameIDs.count), patches/frame=\(evidence.expectedPatches.count)",
            "range: observed=\(evidence.observedRangeTag.rawValue), expected=\(evidence.configuration.expectedRangeTag.rawValue)",
            "audio: pts=\(evidence.audioSamplePTSSeconds.count), impulses=\(expectedImpulseCount), maxSkewMs=\(formatMilliseconds(maximumSkewMilliseconds))",
        ]
        return AVVerificationReport(assertions: assertions, evidenceLines: evidenceLines)
    }

    private static func violation(_ code: AVOracleAssertionCode,
                                  _ message: String,
                                  into violations: inout [AVOracleViolation]) {
        violations.append(AVOracleViolation(code: code, message: message))
    }

    private static func verifyFinalization(_ evidence: AVRoundTripEvidence,
                                           into violations: inout [AVOracleViolation]) {
        let f = evidence.finalization
        if !f.writerCompleted {
            violation(.cleanFinalization, "mux writer did not complete", into: &violations)
        }
        if !f.videoReaderCompleted {
            violation(.cleanFinalization, "video reader did not complete", into: &violations)
        }
        if !f.audioReaderCompleted {
            violation(.cleanFinalization, "audio reader did not complete", into: &violations)
        }
        if !f.fileExists {
            violation(.cleanFinalization, "muxed evidence file does not exist", into: &violations)
        }
        if f.bytesWritten <= 0 {
            violation(.cleanFinalization, "muxed evidence file is empty (\(f.bytesWritten) bytes)", into: &violations)
        }
        if f.videoTrackCount != 1 {
            violation(.cleanFinalization, "expected exactly one video track, found \(f.videoTrackCount)", into: &violations)
        }
        if f.audioTrackCount != 1 {
            violation(.cleanFinalization, "expected exactly one audio track, found \(f.audioTrackCount)", into: &violations)
        }
        if f.muxedVideoFrameCount != evidence.expectedFrameIDs.count {
            violation(.cleanFinalization,
                      "mux reported \(f.muxedVideoFrameCount) video frames; expected \(evidence.expectedFrameIDs.count)",
                      into: &violations)
        }
        if f.muxedAudioSampleCount <= 0 {
            violation(.cleanFinalization, "mux reported no audio samples", into: &violations)
        }
    }

    private static func verifyFrameCount(_ evidence: AVRoundTripEvidence,
                                         into violations: inout [AVOracleViolation]) {
        guard evidence.decodedFrames.count == evidence.expectedFrameIDs.count else {
            violation(.frameCount,
                      "decoded \(evidence.decodedFrames.count) frames; expected \(evidence.expectedFrameIDs.count)",
                      into: &violations)
            return
        }
    }

    private static func verifyFrameIdentity(_ evidence: AVRoundTripEvidence,
                                            into violations: inout [AVOracleViolation]) {
        let commonCount = min(evidence.decodedFrames.count, evidence.expectedFrameIDs.count)
        for index in 0..<commonCount {
            let frame = evidence.decodedFrames[index]
            let expected = evidence.expectedFrameIDs[index]
            guard frame.embeddedFrameID == expected else {
                let observed = frame.embeddedFrameID.map(String.init) ?? "nil"
                violation(.frameIdentity,
                          "frame position \(index) carried ID \(observed); expected \(expected)",
                          into: &violations)
                continue
            }
        }
        if evidence.decodedFrames.count > commonCount {
            for index in commonCount..<evidence.decodedFrames.count {
                let observed = evidence.decodedFrames[index].embeddedFrameID.map(String.init) ?? "nil"
                violation(.frameIdentity,
                          "unexpected decoded frame at position \(index) carried ID \(observed)",
                          into: &violations)
            }
        }
    }

    private static func verifyFrameOrdering(_ evidence: AVRoundTripEvidence,
                                            into violations: inout [AVOracleViolation]) {
        let frames = evidence.decodedFrames
        let identifiers = frames.compactMap(\.embeddedFrameID)
        if identifiers.count != frames.count {
            violation(.frameOrdering,
                      "cannot establish ordering: \(frames.count - identifiers.count) decoded frame IDs were unreadable",
                      into: &violations)
        }
        if Set(identifiers).count != identifiers.count {
            violation(.frameOrdering, "embedded frame IDs were not unique: \(identifiers)", into: &violations)
        }
        if identifiers.count > 1 {
            for index in 1..<identifiers.count where identifiers[index] <= identifiers[index - 1] {
                violation(.frameOrdering,
                          "frame ID \(identifiers[index]) at decoded position \(index) was not strictly after \(identifiers[index - 1])",
                          into: &violations)
            }
        }
    }

    private static func verifyPatchMedians(_ evidence: AVRoundTripEvidence,
                                           into violations: inout [AVOracleViolation]) {
        for frame in evidence.decodedFrames {
            let grouped = Dictionary(grouping: frame.patchMedians, by: \.name)
            for expected in evidence.expectedPatches {
                guard let matches = grouped[expected.name], matches.count == 1, let observed = matches.first else {
                    let count = grouped[expected.name]?.count ?? 0
                    violation(.patchMedians,
                              "frame \(frame.sequenceIndex) patch '\(expected.name)' had \(count) observations; expected exactly one",
                              into: &violations)
                    continue
                }
                verifyPatchChannel(frame: frame.sequenceIndex, patch: expected.name, channel: "R",
                                   observed: observed.r, expected: Double(expected.rgb.r),
                                   tolerance: Double(expected.tolerance), violations: &violations)
                verifyPatchChannel(frame: frame.sequenceIndex, patch: expected.name, channel: "G",
                                   observed: observed.g, expected: Double(expected.rgb.g),
                                   tolerance: Double(expected.tolerance), violations: &violations)
                verifyPatchChannel(frame: frame.sequenceIndex, patch: expected.name, channel: "B",
                                   observed: observed.b, expected: Double(expected.rgb.b),
                                   tolerance: Double(expected.tolerance), violations: &violations)
            }
            for (name, matches) in grouped where !evidence.expectedPatches.contains(where: { $0.name == name }) {
                violation(.patchMedians,
                          "frame \(frame.sequenceIndex) contained unexpected patch evidence '\(name)' (\(matches.count) observation(s))",
                          into: &violations)
            }
        }
    }

    private static func verifyPatchChannel(frame: Int,
                                           patch: String,
                                           channel: String,
                                           observed: Double,
                                           expected: Double,
                                           tolerance: Double,
                                           violations: inout [AVOracleViolation]) {
        guard observed.isFinite, expected.isFinite, tolerance.isFinite, tolerance >= 0,
              abs(observed - expected) <= tolerance else {
            violation(.patchMedians,
                      "frame \(frame) patch '\(patch)' \(channel)=\(formatNumber(observed)); expected \(formatNumber(expected)) +/- \(formatNumber(tolerance))",
                      into: &violations)
            return
        }
    }

    private static func verifyVideoPTS(_ evidence: AVRoundTripEvidence,
                                       into violations: inout [AVOracleViolation]) {
        let values = evidence.decodedFrames.map(\.ptsSeconds)
        guard !values.isEmpty else {
            violation(.videoPTSMonotonicity, "decoded video PTS evidence was empty", into: &violations)
            return
        }
        for (index, value) in values.enumerated() where !value.isFinite {
            violation(.videoPTSMonotonicity,
                      "video PTS at position \(index) was not finite (\(value))",
                      into: &violations)
        }
        for index in 1..<values.count where !(values[index] > values[index - 1]) {
            violation(.videoPTSMonotonicity,
                      "video PTS was not strictly increasing at position \(index): \(values[index]) <= \(values[index - 1])",
                      into: &violations)
        }
    }

    private static func verifyAudioPTS(_ evidence: AVRoundTripEvidence,
                                       into violations: inout [AVOracleViolation]) {
        let values = evidence.audioSamplePTSSeconds
        guard !values.isEmpty else {
            violation(.audioPTSMonotonicity, "decoded audio PTS evidence was empty", into: &violations)
            return
        }
        for (index, value) in values.enumerated() where !value.isFinite {
            violation(.audioPTSMonotonicity,
                      "audio PTS at position \(index) was not finite (\(value))",
                      into: &violations)
        }
        for index in 1..<values.count where !(values[index] > values[index - 1]) {
            violation(.audioPTSMonotonicity,
                      "audio PTS was not strictly increasing at position \(index): \(values[index]) <= \(values[index - 1])",
                      into: &violations)
        }
    }

    private static func verifyRangeTag(_ evidence: AVRoundTripEvidence,
                                       into violations: inout [AVOracleViolation]) {
        if evidence.observedRangeTag != evidence.configuration.expectedRangeTag {
            violation(.rangeTag,
                      "observed range '\(evidence.observedRangeTag.rawValue)'; expected '\(evidence.configuration.expectedRangeTag.rawValue)'",
                      into: &violations)
        }
    }

    /// Returns maximum verified impulse skew for the passing report.
    @discardableResult
    private static func verifyAVSkew(_ evidence: AVRoundTripEvidence,
                                     into violations: inout [AVOracleViolation]) -> Double {
        let expectedImpulses = evidence.expectedAudioEvents.filter { $0.kind == .impulse }
        let detectedImpulses = evidence.detectedAudioEvents.filter { $0.kind == .impulse }
        guard !expectedImpulses.isEmpty else {
            violation(.avSkew, "fixture declared no expected impulse events", into: &violations)
            return .infinity
        }

        let offsetEpsilon = max(1.0e-9, 1.0 / max(evidence.configuration.audioSampleRate, 1))
        if detectedImpulses.count != expectedImpulses.count {
            violation(.avSkew,
                      "detected \(detectedImpulses.count) impulse events; expected \(expectedImpulses.count)",
                      into: &violations)
        }

        for detected in detectedImpulses {
            let matchingExpected = expectedImpulses.filter {
                abs($0.offsetSeconds - detected.expectedOffsetSeconds) <= offsetEpsilon
            }
            if matchingExpected.isEmpty {
                violation(.avSkew,
                          "detected unexpected impulse labelled with offset \(formatNumber(detected.expectedOffsetSeconds))s",
                          into: &violations)
            } else if matchingExpected.count > 1 {
                violation(.avSkew,
                          "impulse offset \(formatNumber(detected.expectedOffsetSeconds))s ambiguously matched \(matchingExpected.count) expected events",
                          into: &violations)
            }
        }

        guard let firstVideoPTS = evidence.decodedFrames.first?.ptsSeconds, firstVideoPTS.isFinite else {
            violation(.avSkew, "cannot measure A/V skew without a finite first-video PTS", into: &violations)
            return .infinity
        }

        let budgetMilliseconds = evidence.configuration.avSkewBudgetMilliseconds
        if !budgetMilliseconds.isFinite || budgetMilliseconds < 0 {
            violation(.avSkew, "invalid A/V skew budget \(budgetMilliseconds) ms", into: &violations)
            return .infinity
        }

        var maximumSkewMilliseconds = 0.0
        for expected in expectedImpulses {
            let matches = detectedImpulses.filter {
                abs($0.expectedOffsetSeconds - expected.offsetSeconds) <= offsetEpsilon
            }
            guard matches.count == 1, let detected = matches.first else {
                violation(.avSkew,
                          "expected impulse at offset \(formatNumber(expected.offsetSeconds))s had \(matches.count) matching detections; expected exactly one",
                          into: &violations)
                continue
            }
            guard detected.detectedPTSSeconds.isFinite else {
                violation(.avSkew,
                          "impulse at offset \(formatNumber(expected.offsetSeconds))s had non-finite detected PTS",
                          into: &violations)
                continue
            }
            let expectedPTS = firstVideoPTS + expected.offsetSeconds
            let skewMilliseconds = abs(detected.detectedPTSSeconds - expectedPTS) * 1_000
            maximumSkewMilliseconds = max(maximumSkewMilliseconds, skewMilliseconds)
            if skewMilliseconds > budgetMilliseconds {
                violation(.avSkew,
                          "impulse at offset \(formatNumber(expected.offsetSeconds))s skewed \(formatMilliseconds(skewMilliseconds)) ms; budget \(formatMilliseconds(budgetMilliseconds)) ms",
                          into: &violations)
            }
        }
        return maximumSkewMilliseconds
    }

    private static func formatNumber(_ value: Double) -> String {
        value.isFinite ? String(format: "%.6f", value) : String(describing: value)
    }

    private static func formatMilliseconds(_ value: Double) -> String {
        value.isFinite ? String(format: "%.3f", value) : String(describing: value)
    }
}

// MARK: - Firing negative controls

public enum AVRoundTripFault: String, Codable, Equatable, Sendable {
    case audioPTSShift
    case rangeTagSwap
    case frameDrop
}

public extension AVRoundTripEvidence {
    /// Return evidence corrupted after collection while leaving the expected
    /// manifest untouched, proving that each independent oracle gate fires.
    func injecting(_ fault: AVRoundTripFault) -> AVRoundTripEvidence {
        var copy = self
        switch fault {
        case .audioPTSShift:
            let shift = max(0.100, 4 * configuration.avSkewBudgetMilliseconds / 1_000)
            copy.audioSamplePTSSeconds = audioSamplePTSSeconds.map { $0 + shift }
            copy.detectedAudioEvents = detectedAudioEvents.map {
                DetectedAudioEventEvidence(kind: $0.kind,
                                           expectedOffsetSeconds: $0.expectedOffsetSeconds,
                                           detectedPTSSeconds: $0.detectedPTSSeconds + shift)
            }
        case .rangeTagSwap:
            copy.observedRangeTag = observedRangeTag == .video ? .full : .video
        case .frameDrop:
            guard !copy.decodedFrames.isEmpty else { return copy }
            copy.decodedFrames.remove(at: copy.decodedFrames.count / 2)
        }
        return copy
    }
}

// MARK: - JSON evidence artifact

public struct EvidenceArtifact: Codable, Equatable, Sendable {
    public let directoryURL: URL
    public let evidenceURL: URL

    public init(directoryURL: URL, evidenceURL: URL) {
        self.directoryURL = directoryURL
        self.evidenceURL = evidenceURL
    }
}

public struct JSONEvidenceArtifactWriter {
    private let rootDirectory: URL

    public init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? FileManager.default.temporaryDirectory
    }

    /// Write pretty, key-sorted evidence into a fresh child directory. The root
    /// itself is never used as the artifact directory and existing children are
    /// never replaced.
    public func write(_ evidence: AVRoundTripEvidence) throws -> EvidenceArtifact {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let seed = String(evidence.configuration.seed, radix: 16, uppercase: false)
        let directory: URL
        while true {
            let candidate = rootDirectory.appendingPathComponent(
                "prism-av-evidence-seed-\(seed)-\(UUID().uuidString.lowercased())",
                isDirectory: true)
            guard !fileManager.fileExists(atPath: candidate.path) else { continue }
            try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
            directory = candidate
            break
        }

        let evidenceURL = directory.appendingPathComponent("evidence.json", isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(evidence)
        // The parent directory is freshly created above, so the destination
        // cannot exist. Foundation rejects combining `.atomic` with
        // `.withoutOverwriting` at runtime; atomic alone gives the desired
        // crash-safe write without weakening non-clobbering behavior.
        try data.write(to: evidenceURL, options: .atomic)
        return EvidenceArtifact(directoryURL: directory, evidenceURL: evidenceURL)
    }
}
