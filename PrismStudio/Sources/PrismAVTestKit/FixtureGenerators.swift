import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import os
import PrismCore

// MARK: - Shared configuration and value types

/// Expected video quantization range carried by the encoded track.
public enum VideoRangeTag: String, Codable, Sendable {
    case video
    case full
}

/// One deterministic A/V verification run's fixture configuration.
public struct AVRoundTripConfiguration: Codable, Equatable, Sendable {
    public var seed: UInt64
    public var width: Int
    public var height: Int
    public var fps: Int
    public var frameCount: Int
    public var videoBitrate: Int
    public var patchTolerance: Int
    public var avSkewBudgetMilliseconds: Double
    public var audioSampleRate: Double
    public var audioChunkFrames: Int
    public var expectedRangeTag: VideoRangeTag

    public init(
        seed: UInt64 = 0x505249534D415631,
        width: Int = 320,
        height: Int = 192,
        fps: Int = 30,
        frameCount: Int = 18,
        videoBitrate: Int = 8_000_000,
        patchTolerance: Int = 28,
        avSkewBudgetMilliseconds: Double = 8.0,
        audioSampleRate: Double = 48_000,
        audioChunkFrames: Int = 960,
        expectedRangeTag: VideoRangeTag = .video
    ) {
        self.seed = seed
        self.width = width
        self.height = height
        self.fps = fps
        self.frameCount = frameCount
        self.videoBitrate = videoBitrate
        self.patchTolerance = patchTolerance
        self.avSkewBudgetMilliseconds = avSkewBudgetMilliseconds
        self.audioSampleRate = audioSampleRate
        self.audioChunkFrames = audioChunkFrames
        self.expectedRangeTag = expectedRangeTag
    }

    /// Validate the common constraints required by both generators and by the
    /// H.264/HEVC round-trip that consumes their output.
    public func validate() throws {
        guard width >= 160, height >= 120 else {
            throw FixtureGenerationError.invalidConfiguration(
                "video dimensions must be at least 160x120 (got \(width)x\(height))"
            )
        }
        guard width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw FixtureGenerationError.invalidConfiguration(
                "video dimensions must be even for 4:2:0 encode (got \(width)x\(height))"
            )
        }
        guard fps > 0 else {
            throw FixtureGenerationError.invalidConfiguration("fps must be positive (got \(fps))")
        }
        guard frameCount > 0, frameCount <= 65_536 else {
            throw FixtureGenerationError.invalidConfiguration(
                "frameCount must be in 1...65536 (got \(frameCount))"
            )
        }
        guard videoBitrate > 0 else {
            throw FixtureGenerationError.invalidConfiguration(
                "videoBitrate must be positive (got \(videoBitrate))"
            )
        }
        guard patchTolerance >= 0 else {
            throw FixtureGenerationError.invalidConfiguration(
                "patchTolerance must be non-negative (got \(patchTolerance))"
            )
        }
        guard avSkewBudgetMilliseconds.isFinite, avSkewBudgetMilliseconds >= 0 else {
            throw FixtureGenerationError.invalidConfiguration(
                "A/V skew budget must be finite and non-negative"
            )
        }
        guard audioSampleRate.isFinite,
              audioSampleRate >= 8_000,
              audioSampleRate <= 192_000,
              audioSampleRate.rounded() == audioSampleRate else {
            throw FixtureGenerationError.invalidConfiguration(
                "audioSampleRate must be an integral rate in 8000...192000 (got \(audioSampleRate))"
            )
        }
        guard audioChunkFrames > 0 else {
            throw FixtureGenerationError.invalidConfiguration(
                "audioChunkFrames must be positive (got \(audioChunkFrames))"
            )
        }
    }
}

/// A clock seam used by deterministic media producers.
public protocol FixtureClock: Sendable {
    func now() -> CMTime
}

/// Lock-backed media clock advanced explicitly by a test run.
public final class VirtualMediaClock: FixtureClock, @unchecked Sendable {
    private let time: OSAllocatedUnfairLock<CMTime>

    public init(start: CMTime = .zero) {
        time = OSAllocatedUnfairLock(initialState: start)
    }

    public func now() -> CMTime {
        time.withLock { $0 }
    }

    /// Advance by `delta` and return the new time.
    @discardableResult
    public func advance(by delta: CMTime) -> CMTime {
        time.withLock { current in
            current = CMTimeAdd(current, delta)
            return current
        }
    }

    public func set(_ newTime: CMTime) {
        time.withLock { $0 = newTime }
    }
}

public struct FixtureRect: Codable, Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct RGBValue: Codable, Equatable, Sendable {
    public var r: Int
    public var g: Int
    public var b: Int

    public init(r: Int, g: Int, b: Int) {
        self.r = r
        self.g = g
        self.b = b
    }
}

public struct ExpectedVideoPatch: Codable, Equatable, Sendable {
    public var name: String
    public var rect: FixtureRect
    public var rgb: RGBValue
    public var tolerance: Int

    public init(name: String, rect: FixtureRect, rgb: RGBValue, tolerance: Int) {
        self.name = name
        self.rect = rect
        self.rgb = rgb
        self.tolerance = tolerance
    }
}

public struct GeneratedVideoFixture {
    public let frame: VideoFrame
    public let frameID: Int
    public let expectedPatches: [ExpectedVideoPatch]

    public init(frame: VideoFrame, frameID: Int, expectedPatches: [ExpectedVideoPatch]) {
        self.frame = frame
        self.frameID = frameID
        self.expectedPatches = expectedPatches
    }
}

/// SplitMix64: tiny, stable, and intentionally independent of Swift's randomized
/// standard-library hashing/random facilities.
public struct SeededGenerator: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    public mutating func nextByte() -> UInt8 {
        UInt8(truncatingIfNeeded: next() >> 56)
    }
}

/// Typed failures from fixture creation/readback. Descriptions are deliberately
/// evidence-ready so the harness can write them directly to JSON or stderr.
public enum FixtureGenerationError: Error, CustomStringConvertible {
    case invalidConfiguration(String)
    case invalidFrameID(Int)
    case invalidDuration(String)
    case unsupportedPixelFormat(OSType)
    case invalidRect(FixtureRect, imageWidth: Int, imageHeight: Int)
    case missingPixelBaseAddress
    case weakFrameIDSignal(String)
    case coreVideo(operation: String, status: CVReturn)
    case coreMedia(operation: String, status: OSStatus)

    public var description: String {
        switch self {
        case .invalidConfiguration(let reason):
            return "invalid A/V fixture configuration: \(reason)"
        case .invalidFrameID(let id):
            return "frame ID must fit the embedded 16-bit code (got \(id))"
        case .invalidDuration(let reason):
            return "invalid audio fixture duration: \(reason)"
        case .unsupportedPixelFormat(let format):
            return "fixture readback requires 32BGRA, got \(Self.fourCC(format))"
        case .invalidRect(let rect, let width, let height):
            return "fixture readback rect (\(rect.x),\(rect.y),\(rect.width),\(rect.height)) " +
                "is outside \(width)x\(height)"
        case .missingPixelBaseAddress:
            return "pixel buffer has no readable base address"
        case .weakFrameIDSignal(let reason):
            return "embedded frame ID rejected: \(reason)"
        case .coreVideo(let operation, let status):
            return "\(operation) failed with CVReturn \(status)"
        case .coreMedia(let operation, let status):
            return "\(operation) failed with OSStatus \(status)"
        }
    }

    private static func fourCC(_ value: OSType) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ]
        let text = String(bytes: bytes, encoding: .ascii) ?? "?"
        return "'\(text)' (0x\(String(value, radix: 16)))"
    }
}

// MARK: - Video fixture

/// Geometry shared by fixture generation and decoded-frame readback.
private struct VideoFixtureLayout {
    static let idBitCount = 16
    static let idCellCount = idBitCount * 2

    let width: Int
    let height: Int
    let idCells: [FixtureRect]
    let colorPatches: [FixtureRect]
    let rampPatches: [FixtureRect]
    let alphaPatches: [FixtureRect]

    init(width: Int, height: Int) throws {
        guard width >= 160, height >= 120 else {
            throw FixtureGenerationError.invalidConfiguration(
                "decoded fixture is too small for its diagnostic layout (\(width)x\(height))"
            )
        }

        self.width = width
        self.height = height

        let marginX = max(4, width / 40)
        let marginY = max(4, height / 32)
        let verticalGap = max(3, height / 48)
        let usableHeight = height - marginY * 2 - verticalGap * 3
        let idHeight = max(16, usableHeight * 20 / 100)
        let colorHeight = max(18, usableHeight * 25 / 100)
        let rampHeight = max(16, usableHeight * 20 / 100)
        let alphaHeight = usableHeight - idHeight - colorHeight - rampHeight
        guard alphaHeight >= 18 else {
            throw FixtureGenerationError.invalidConfiguration(
                "decoded fixture height leaves no safe alpha diagnostic band"
            )
        }

        let diagnosticWidth = width - marginX * 2
        let idCellWidth = diagnosticWidth / Self.idCellCount
        guard idCellWidth >= 4 else {
            throw FixtureGenerationError.invalidConfiguration(
                "decoded fixture width leaves ID cells narrower than four pixels"
            )
        }
        let idUsedWidth = idCellWidth * Self.idCellCount
        let idStartX = (width - idUsedWidth) / 2
        idCells = (0..<Self.idCellCount).map {
            FixtureRect(x: idStartX + $0 * idCellWidth, y: marginY,
                        width: idCellWidth, height: idHeight)
        }

        let colorY = marginY + idHeight + verticalGap
        let colorGap = max(2, width / 160)
        let colorWidth = (diagnosticWidth - colorGap * 6) / 7
        let colorUsedWidth = colorWidth * 7 + colorGap * 6
        let colorStartX = (width - colorUsedWidth) / 2
        colorPatches = (0..<7).map {
            FixtureRect(x: colorStartX + $0 * (colorWidth + colorGap), y: colorY,
                        width: colorWidth, height: colorHeight)
        }

        let rampY = colorY + colorHeight + verticalGap
        let rampWidth = diagnosticWidth / 16
        let rampUsedWidth = rampWidth * 16
        let rampStartX = (width - rampUsedWidth) / 2
        rampPatches = (0..<16).map {
            FixtureRect(x: rampStartX + $0 * rampWidth, y: rampY,
                        width: rampWidth, height: rampHeight)
        }

        let alphaY = rampY + rampHeight + verticalGap
        let alphaWidth = diagnosticWidth / 8
        let alphaUsedWidth = alphaWidth * 8
        let alphaStartX = (width - alphaUsedWidth) / 2
        alphaPatches = (0..<8).map {
            FixtureRect(x: alphaStartX + $0 * alphaWidth, y: alphaY,
                        width: alphaWidth, height: alphaHeight)
        }
    }

    func safelyInset(_ rect: FixtureRect) -> FixtureRect {
        let inset = max(1, min(3, min(rect.width, rect.height) / 4))
        return FixtureRect(x: rect.x + inset, y: rect.y + inset,
                           width: max(1, rect.width - inset * 2),
                           height: max(1, rect.height - inset * 2))
    }
}

/// Generates codec-tolerant video cards carrying a 16-bit Manchester frame ID,
/// range/color patches, a 16-step signal ramp, and premultiplied-alpha steps.
public final class VideoFixtureGenerator {
    public let configuration: AVRoundTripConfiguration
    public let sourceID = SourceID("fixture.av.video")

    private let pool: PixelBufferPool
    private let layout: VideoFixtureLayout

    public init(configuration: AVRoundTripConfiguration) throws {
        try configuration.validate()
        self.configuration = configuration
        layout = try VideoFixtureLayout(width: configuration.width, height: configuration.height)
        pool = try PixelBufferPool(width: configuration.width, height: configuration.height,
                                   pixelFormat: kCVPixelFormatType_32BGRA,
                                   minimumBufferCount: 3)
    }

    public func makeFrame(id: Int, pts: CMTime) throws -> GeneratedVideoFixture {
        guard (0...65_535).contains(id) else {
            throw FixtureGenerationError.invalidFrameID(id)
        }

        let buffer = try pool.makeBuffer()
        let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw FixtureGenerationError.coreVideo(operation: "CVPixelBufferLockBaseAddress",
                                                   status: lockStatus)
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            throw FixtureGenerationError.missingPixelBaseAddress
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        // Seed every frame independently so generation order cannot alter pixels.
        var random = SeededGenerator(
            seed: configuration.seed ^ (UInt64(id) &* 0xD1B54A32D192ED03)
        )
        for y in 0..<configuration.height {
            let row = base + y * bytesPerRow
            for x in 0..<configuration.width {
                let pixel = row + x * 4
                // Low-amplitude seeded texture prevents an encoder from reducing
                // the entire non-diagnostic background to a degenerate flat block.
                pixel[0] = 10 + random.nextByte() % 9
                pixel[1] = 10 + random.nextByte() % 9
                pixel[2] = 10 + random.nextByte() % 9
                pixel[3] = 255
            }
        }

        func paint(_ rect: FixtureRect, rgb: RGBValue, alpha: Int = 255) {
            let r = UInt8(clamping: rgb.r)
            let g = UInt8(clamping: rgb.g)
            let b = UInt8(clamping: rgb.b)
            let a = UInt8(clamping: alpha)
            for y in rect.y..<(rect.y + rect.height) {
                let row = base + y * bytesPerRow
                for x in rect.x..<(rect.x + rect.width) {
                    let pixel = row + x * 4
                    pixel[0] = b
                    pixel[1] = g
                    pixel[2] = r
                    pixel[3] = a
                }
            }
        }

        // MSB first; each bit is immediately followed by its complement. A
        // decoder therefore rejects a locally smeared/flat pair instead of
        // confidently inventing an ID from a single threshold sample.
        for bitIndex in 0..<VideoFixtureLayout.idBitCount {
            let bit = (id >> (15 - bitIndex)) & 1
            let first = bit == 1 ? 236 : 20
            let second = bit == 1 ? 20 : 236
            paint(layout.idCells[bitIndex * 2], rgb: RGBValue(r: first, g: first, b: first))
            paint(layout.idCells[bitIndex * 2 + 1], rgb: RGBValue(r: second, g: second, b: second))
        }

        var expected: [ExpectedVideoPatch] = []
        let colors: [(String, RGBValue)] = [
            ("color.black", RGBValue(r: 0, g: 0, b: 0)),
            ("color.near-black", RGBValue(r: 16, g: 16, b: 16)),
            ("color.gray", RGBValue(r: 128, g: 128, b: 128)),
            ("color.white", RGBValue(r: 255, g: 255, b: 255)),
            ("color.red", RGBValue(r: 255, g: 0, b: 0)),
            ("color.green", RGBValue(r: 0, g: 255, b: 0)),
            ("color.blue", RGBValue(r: 0, g: 0, b: 255)),
        ]
        for (index, entry) in colors.enumerated() {
            let rect = layout.colorPatches[index]
            paint(rect, rgb: entry.1)
            let chromaSlack = index >= 4 ? 12 : 0
            expected.append(ExpectedVideoPatch(
                name: entry.0, rect: layout.safelyInset(rect), rgb: entry.1,
                tolerance: configuration.patchTolerance + chromaSlack
            ))
        }

        // An evenly-spaced code-value ramp is useful in both SDR and HDR runs:
        // it catches clipping, an unexpected range expansion/compression, and a
        // non-monotonic transfer without relying on one extreme patch.
        for index in 0..<16 {
            let value = Int((Double(index) * 255.0 / 15.0).rounded())
            let rgb = RGBValue(r: value, g: value, b: value)
            let rect = layout.rampPatches[index]
            paint(rect, rgb: rgb)
            expected.append(ExpectedVideoPatch(
                name: String(format: "signal-ramp.%02d", index),
                rect: layout.safelyInset(rect), rgb: rgb,
                tolerance: configuration.patchTolerance
            ))
        }

        // Eight hard alpha steps form several sharp alpha edges. RGB is stored
        // premultiplied, as required by the compositor's `(one, 1-srcAlpha)` path.
        let straight = RGBValue(r: 240, g: 144, b: 48)
        let inspectedAlphaSteps: Set<Int> = [0, 2, 4, 6, 7]
        for index in 0..<8 {
            let alpha = Int((Double(index) * 255.0 / 7.0).rounded())
            let premultiplied = RGBValue(
                r: (straight.r * alpha + 127) / 255,
                g: (straight.g * alpha + 127) / 255,
                b: (straight.b * alpha + 127) / 255
            )
            let rect = layout.alphaPatches[index]
            paint(rect, rgb: premultiplied, alpha: alpha)
            if inspectedAlphaSteps.contains(index) {
                expected.append(ExpectedVideoPatch(
                    name: String(format: "alpha-step.%02d", index),
                    rect: layout.safelyInset(rect), rgb: premultiplied,
                    tolerance: configuration.patchTolerance + 8
                ))
            }
        }

        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(configuration.fps))
        let frame = VideoFrame(pixelBuffer: buffer, pts: pts, duration: frameDuration,
                               source: sourceID)
        return GeneratedVideoFixture(frame: frame, frameID: id, expectedPatches: expected)
    }

    /// Recover the 16-bit MSB-first Manchester ID from a decoded BGRA frame.
    /// Every pair must straddle the global dark/bright threshold and retain
    /// substantial local contrast; weak or non-complement pairs are rejected.
    public static func decodeFrameID(from pixelBuffer: CVPixelBuffer) throws -> Int {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            throw FixtureGenerationError.unsupportedPixelFormat(
                CVPixelBufferGetPixelFormatType(pixelBuffer)
            )
        }
        let layout = try VideoFixtureLayout(width: CVPixelBufferGetWidth(pixelBuffer),
                                            height: CVPixelBufferGetHeight(pixelBuffer))
        let levels = try layout.idCells.map { cell -> Int in
            let rgb = try medianRGB(in: pixelBuffer, rect: layout.safelyInset(cell))
            return (rgb.r + rgb.g + rgb.b) / 3
        }
        guard let darkest = levels.min(), let brightest = levels.max() else {
            throw FixtureGenerationError.weakFrameIDSignal("no ID cells")
        }
        let contrast = brightest - darkest
        guard contrast >= 80 else {
            throw FixtureGenerationError.weakFrameIDSignal(
                "global cell contrast \(contrast) is below 80"
            )
        }
        let threshold = (darkest + brightest) / 2
        let minimumPairContrast = max(40, contrast / 3)

        var decoded = 0
        for bitIndex in 0..<VideoFixtureLayout.idBitCount {
            let first = levels[bitIndex * 2]
            let complement = levels[bitIndex * 2 + 1]
            guard abs(first - complement) >= minimumPairContrast else {
                throw FixtureGenerationError.weakFrameIDSignal(
                    "bit \(bitIndex) pair contrast \(abs(first - complement)) " +
                    "is below \(minimumPairContrast)"
                )
            }
            let firstHigh = first > threshold
            let complementHigh = complement > threshold
            guard firstHigh != complementHigh else {
                throw FixtureGenerationError.weakFrameIDSignal(
                    "bit \(bitIndex) cells are not complements " +
                    "(\(first), \(complement), threshold \(threshold))"
                )
            }
            decoded = (decoded << 1) | (firstHigh ? 1 : 0)
        }
        return decoded
    }

    /// Per-channel median over a safely bounded rectangle in a decoded BGRA frame.
    public static func medianRGB(in pixelBuffer: CVPixelBuffer,
                                 rect: FixtureRect) throws -> RGBValue {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard pixelFormat == kCVPixelFormatType_32BGRA else {
            throw FixtureGenerationError.unsupportedPixelFormat(pixelFormat)
        }
        let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0,
              rect.x <= imageWidth - rect.width,
              rect.y <= imageHeight - rect.height else {
            throw FixtureGenerationError.invalidRect(rect, imageWidth: imageWidth,
                                                     imageHeight: imageHeight)
        }

        let status = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw FixtureGenerationError.coreVideo(operation: "CVPixelBufferLockBaseAddress(readOnly)",
                                                   status: status)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else {
            throw FixtureGenerationError.missingPixelBaseAddress
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard bytesPerRow >= imageWidth * 4 else {
            throw FixtureGenerationError.missingPixelBaseAddress
        }

        let count = rect.width * rect.height
        var reds: [UInt8] = []
        var greens: [UInt8] = []
        var blues: [UInt8] = []
        reds.reserveCapacity(count)
        greens.reserveCapacity(count)
        blues.reserveCapacity(count)
        for y in rect.y..<(rect.y + rect.height) {
            let row = base + y * bytesPerRow
            for x in rect.x..<(rect.x + rect.width) {
                let pixel = row + x * 4
                blues.append(pixel[0])
                greens.append(pixel[1])
                reds.append(pixel[2])
            }
        }

        func median(_ values: inout [UInt8]) -> Int {
            values.sort()
            let middle = values.count / 2
            if values.count.isMultiple(of: 2) {
                return (Int(values[middle - 1]) + Int(values[middle])) / 2
            }
            return Int(values[middle])
        }
        return RGBValue(r: median(&reds), g: median(&greens), b: median(&blues))
    }
}

// MARK: - Audio fixture

public enum AudioSignalKind: String, Codable, Sendable {
    case impulse
    case chirp
}

public struct ExpectedAudioEvent: Codable, Equatable, Sendable {
    public var kind: AudioSignalKind
    public var offsetSeconds: Double
    public var durationSeconds: Double

    public init(kind: AudioSignalKind, offsetSeconds: Double, durationSeconds: Double) {
        self.kind = kind
        self.offsetSeconds = offsetSeconds
        self.durationSeconds = durationSeconds
    }
}

public struct GeneratedAudioFixture {
    public let packets: [CMSampleBuffer]
    public let expectedEvents: [ExpectedAudioEvent]

    public init(packets: [CMSampleBuffer], expectedEvents: [ExpectedAudioEvent]) {
        self.packets = packets
        self.expectedEvents = expectedEvents
    }
}

/// Generates mono interleaved Float32 LPCM with two sample-accurate impulses and
/// one windowed linear chirp, chunked at known monotonically-increasing PTS.
public final class AudioFixtureGenerator {
    public let configuration: AVRoundTripConfiguration

    public init(configuration: AVRoundTripConfiguration) {
        self.configuration = configuration
    }

    public func makePackets(startPTS: CMTime, duration: CMTime) throws -> GeneratedAudioFixture {
        try configuration.validate()
        guard startPTS.isValid, startPTS.isNumeric else {
            throw FixtureGenerationError.invalidDuration("start PTS is not numeric")
        }
        guard duration.isValid, duration.isNumeric,
              duration.seconds.isFinite, duration.seconds > 0 else {
            throw FixtureGenerationError.invalidDuration(
                "duration must be finite and positive (got \(duration.seconds))"
            )
        }

        let sampleRate = configuration.audioSampleRate
        let scale = CMTimeScale(sampleRate)
        let frameCountDouble = floor(duration.seconds * sampleRate + 1e-9)
        guard frameCountDouble > 0, frameCountDouble <= Double(Int.max) else {
            throw FixtureGenerationError.invalidDuration("duration does not fit a sample count")
        }
        let frameCount = Int(frameCountDouble)
        var samples = [Float](repeating: 0, count: frameCount)
        var events: [ExpectedAudioEvent] = []

        func sampleIndex(at seconds: Double) -> Int {
            Int((seconds * sampleRate).rounded())
        }

        func addImpulse(at requestedOffset: Double) {
            let index = sampleIndex(at: requestedOffset)
            guard index >= 0, index < samples.count else { return }
            samples[index] = 0.95
            events.append(ExpectedAudioEvent(
                kind: .impulse,
                offsetSeconds: Double(index) / sampleRate,
                durationSeconds: 1.0 / sampleRate
            ))
        }

        func addChirp(at requestedOffset: Double, requestedDuration: Double) {
            let start = sampleIndex(at: requestedOffset)
            guard start >= 0, start < samples.count else { return }
            let requestedFrames = max(1, sampleIndex(at: requestedDuration))
            let actualFrames = min(requestedFrames, samples.count - start)
            let actualDuration = Double(actualFrames) / sampleRate
            let startHz = 600.0
            let endHz = 6_000.0
            for localIndex in 0..<actualFrames {
                let t = Double(localIndex) / sampleRate
                let progress = actualFrames > 1
                    ? Double(localIndex) / Double(actualFrames - 1) : 0
                let phase = 2.0 * Double.pi * (
                    startHz * t + 0.5 * (endHz - startHz) * t * t / actualDuration
                )
                let envelope = pow(sin(Double.pi * progress), 2)
                samples[start + localIndex] += Float(0.25 * envelope * sin(phase))
            }
            events.append(ExpectedAudioEvent(
                kind: .chirp,
                offsetSeconds: Double(start) / sampleRate,
                durationSeconds: actualDuration
            ))
        }

        addImpulse(at: 0.100)
        addChirp(at: 0.260, requestedDuration: 0.080)
        addImpulse(at: 0.460)
        events.sort { $0.offsetSeconds < $1.offsetSeconds }

        let format = try Self.makeFormatDescription(sampleRate: sampleRate)
        var packets: [CMSampleBuffer] = []
        packets.reserveCapacity((frameCount + configuration.audioChunkFrames - 1) /
                                configuration.audioChunkFrames)
        var firstFrame = 0
        while firstFrame < samples.count {
            let end = min(samples.count, firstFrame + configuration.audioChunkFrames)
            let chunk = Array(samples[firstFrame..<end])
            let pts = CMTimeAdd(
                startPTS,
                CMTime(value: Int64(firstFrame), timescale: scale)
            )
            packets.append(try Self.makeSampleBuffer(samples: chunk,
                                                     formatDescription: format,
                                                     sampleRateScale: scale,
                                                     pts: pts))
            firstFrame = end
        }

        return GeneratedAudioFixture(packets: packets, expectedEvents: events)
    }

    private static func makeFormatDescription(sampleRate: Double) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else {
            throw FixtureGenerationError.coreMedia(
                operation: "CMAudioFormatDescriptionCreate", status: status
            )
        }
        return format
    }

    private static func makeSampleBuffer(
        samples: [Float],
        formatDescription: CMAudioFormatDescription,
        sampleRateScale: CMTimeScale,
        pts: CMTime
    ) throws -> CMSampleBuffer {
        let byteCount = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw FixtureGenerationError.coreMedia(
                operation: "CMBlockBufferCreateWithMemoryBlock", status: status
            )
        }
        status = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: byteCount
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw FixtureGenerationError.coreMedia(
                operation: "CMBlockBufferReplaceDataBytes", status: status
            )
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRateScale),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleSize = MemoryLayout<Float>.size
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: samples.count,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw FixtureGenerationError.coreMedia(
                operation: "CMSampleBufferCreateReady", status: status
            )
        }
        return sampleBuffer
    }
}
