import CoreMedia
import CoreVideo
import Foundation

/// Stable identity for a source instance (a specific camera, window capture, network feed…).
public struct SourceID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
}

/// One video frame flowing through the pipeline.
///
/// Invariants (DESIGN.md §3.5 — "zero-copy or die"):
///  - `pixelBuffer` MUST be IOSurface-backed from capture to encode. Debug builds assert.
///  - `pts` is house time (HouseClock), never a device-local clock.
public struct VideoFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    /// Presentation timestamp in house time.
    public let pts: CMTime
    public let duration: CMTime
    public let source: SourceID

    public init(pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime = .invalid, source: SourceID) {
        assert(CVPixelBufferGetIOSurface(pixelBuffer) != nil,
               "Non-IOSurface-backed pixel buffer entered the graph from \(source) — this breaks zero-copy")
        self.pixelBuffer = pixelBuffer
        self.pts = pts
        self.duration = duration
        self.source = source
    }

    public var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
    public var height: Int { CVPixelBufferGetHeight(pixelBuffer) }
    public var pixelFormat: OSType { CVPixelBufferGetPixelFormatType(pixelBuffer) }
}

/// One chunk of audio flowing through the pipeline. PTS in house time.
public struct AudioPacket: @unchecked Sendable {
    public let sampleBuffer: CMSampleBuffer
    public let source: SourceID

    public init(sampleBuffer: CMSampleBuffer, source: SourceID) {
        self.sampleBuffer = sampleBuffer
        self.source = source
    }

    public var pts: CMTime { CMSampleBufferGetPresentationTimeStamp(sampleBuffer) }
}
