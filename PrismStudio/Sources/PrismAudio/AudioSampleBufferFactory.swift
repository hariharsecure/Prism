import AVFAudio
import CoreMedia
import Foundation

/// Errors shared by PrismAudio's CoreMedia plumbing.
public enum PrismAudioError: Error, CustomStringConvertible {
    /// The running OS is older than the API this feature needs.
    case unsupportedOS(required: String)
    /// A CoreAudio / CoreMedia call failed.
    case osStatus(operation: String, status: OSStatus)
    /// A format could not be built or converted.
    case badFormat(String)
    /// Engine/graph misuse (wrong mode, duplicate channel, …).
    case invalidState(String)

    public var description: String {
        switch self {
        case .unsupportedOS(let required): return "requires \(required) or newer"
        case .osStatus(let op, let status): return "\(op) failed (OSStatus \(status))"
        case .badFormat(let why): return "bad audio format: \(why)"
        case .invalidState(let why): return "invalid state: \(why)"
        }
    }
}

/// Internal helpers to mint CMSampleBuffers from PCM. Used by the mixer's
/// master tap (interleaved output for recorder/stream) and by the self-check.
enum AudioSampleBufferFactory {
    /// Format description for packed interleaved Float32 LPCM.
    static func interleavedFloatFormatDescription(sampleRate: Double, channelCount: Int) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channelCount),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channelCount),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw PrismAudioError.osStatus(operation: "CMAudioFormatDescriptionCreate", status: status)
        }
        return formatDescription
    }

    /// Copy `frameCount` interleaved Float32 frames into a ready CMSampleBuffer.
    static func makeInterleavedSampleBuffer(samples: UnsafePointer<Float>,
                                            frameCount: Int,
                                            channelCount: Int,
                                            formatDescription: CMAudioFormatDescription,
                                            pts: CMTime) throws -> CMSampleBuffer {
        let byteCount = frameCount * channelCount * MemoryLayout<Float>.size

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
            throw PrismAudioError.osStatus(operation: "CMBlockBufferCreateWithMemoryBlock", status: status)
        }
        status = CMBlockBufferReplaceDataBytes(
            with: UnsafeRawPointer(samples),
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )
        guard status == kCMBlockBufferNoErr else {
            throw PrismAudioError.osStatus(operation: "CMBlockBufferReplaceDataBytes", status: status)
        }

        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw PrismAudioError.osStatus(operation: "CMAudioSampleBufferCreateReady", status: status)
        }
        return sampleBuffer
    }
}

/// Linear + dBFS reading of a peak meter.
public struct AudioLevel: Sendable, CustomStringConvertible {
    /// Peak amplitude, 0.0…(may exceed 1.0 when clipping).
    public let linear: Float
    /// Peak in dBFS; `-.infinity` for digital silence.
    public let dBFS: Float

    public init(linear: Float) {
        self.linear = linear
        self.dBFS = linear > 0 ? 20 * log10f(linear) : -.infinity
    }

    public static let silence = AudioLevel(linear: 0)
    public var description: String { String(format: "%.1f dBFS", dBFS) }
}
