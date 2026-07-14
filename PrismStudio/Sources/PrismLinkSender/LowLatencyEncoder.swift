import CoreMedia
import CoreVideo
import Foundation
import os
import PrismCore
import VideoToolbox

/// Device-side HEVC encoder for the PrismLink sender (DESIGN.md §3.4):
/// VideoToolbox with low-latency rate control, real-time, no B-frames, and a
/// live-settable bitrate (fed by `BitrateLadder`).
///
/// Output is whole-frame **Annex-B** (start-code-delimited NAL units,
/// converted from the sample buffer's length-prefixed layout) with
/// vps/sps/pps prepended on every keyframe — exactly what PrismLink's
/// `VideoFrameDecoder` expects on the Mac ("senders repeat them on every
/// keyframe"). PTS is the capture timestamp passed through untouched
/// (device host clock); `LinkClient` translates it to house time at send.
public final class LowLatencyEncoder: @unchecked Sendable {

    public struct Configuration: Sendable {
        public var width: Int
        public var height: Int
        public var fps: Int
        public var averageBitrateBps: Int
        public var keyframeIntervalSeconds: Double

        public init(width: Int = 1920, height: Int = 1080, fps: Int = 30,
                    averageBitrateBps: Int = 12_000_000,
                    keyframeIntervalSeconds: Double = 2) {
            self.width = width
            self.height = height
            self.fps = fps
            self.averageBitrateBps = averageBitrateBps
            self.keyframeIntervalSeconds = keyframeIntervalSeconds
        }
    }

    /// One encoded frame, ready for `LinkClient.send(encoded:pts:isKeyframe:)`.
    public struct EncodedFrame: Sendable {
        /// Whole-frame HEVC Annex-B; parameter sets in-band on keyframes.
        public let annexB: Data
        /// The capture PTS (device host clock) — NOT yet house time.
        public let pts: CMTime
        public let isKeyframe: Bool
    }

    public enum EncoderError: Error {
        case sessionCreationFailed(OSStatus)
        case encodeFailed(OSStatus)
    }

    /// Called on VideoToolbox's output thread, in presentation order
    /// (frame reordering is disabled).
    public var onEncodedFrame: ((EncodedFrame) -> Void)?

    public let configuration: Configuration
    public private(set) var currentBitrateBps: Int
    public private(set) var expectedFPS: Int

    /// Frames rejected by the encoder or dropped by rate control.
    public var framesDropped: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return droppedCount
    }

    private let log = EngineLog.logger("link.sender.encode")
    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var forceNextKeyframe = false
    private var droppedCount: UInt64 = 0

    public init(configuration: Configuration = Configuration()) throws {
        self.configuration = configuration
        self.currentBitrateBps = configuration.averageBitrateBps
        self.expectedFPS = configuration.fps
        self.session = try Self.makeSession(configuration, log: log)
    }

    deinit {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    // MARK: Controls

    /// The next encoded frame will be an IDR (receiver keyframeRequest → here).
    public func forceKeyframe() {
        lock.lock()
        forceNextKeyframe = true
        lock.unlock()
    }

    /// Live bitrate change — takes effect without a session rebuild
    /// (the bitrate-ladder path, and sessionConfig's targetBitrateBps).
    public func setBitrate(_ bps: Int) {
        lock.lock(); defer { lock.unlock() }
        guard bps > 0, let session else { return }
        currentBitrateBps = bps
        let status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                                          value: NSNumber(value: bps))
        if status != noErr {
            log.warning("setBitrate(\(bps)) rejected: \(status)")
        }
    }

    /// Update the encoder's expected frame rate (sessionConfig fps changes).
    public func setExpectedFPS(_ fps: Int) {
        lock.lock(); defer { lock.unlock() }
        guard fps > 0, let session else { return }
        expectedFPS = fps
        Self.trySet(session, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps), log)
        let interval = max(1, Int(Double(fps) * configuration.keyframeIntervalSeconds))
        Self.trySet(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: interval), log)
    }

    /// Emits any frames still in flight, in order.
    public func flush() {
        lock.lock()
        let session = self.session
        lock.unlock()
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        }
    }

    /// Tears the session down; further `encode` calls are no-ops.
    public func invalidate() {
        lock.lock()
        let session = self.session
        self.session = nil
        lock.unlock()
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    // MARK: Encode

    /// Encode one frame. `pts` is the capture timestamp (device host clock),
    /// passed through to the output. Call from the capture queue; output
    /// arrives asynchronously on VideoToolbox's thread.
    public func encode(pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime = .invalid) {
        lock.lock()
        guard let session else {
            lock.unlock()
            return
        }
        var frameProperties: CFDictionary?
        if forceNextKeyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
            forceNextKeyframe = false
        }
        lock.unlock()

        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: duration,
            frameProperties: frameProperties, infoFlagsOut: nil
        ) { [weak self] status, infoFlags, sampleBuffer in
            self?.handleOutput(status: status, infoFlags: infoFlags, sampleBuffer: sampleBuffer)
        }
        if status != noErr {
            lock.lock()
            droppedCount &+= 1
            lock.unlock()
            log.warning("encode submit failed: \(status)")
        }
    }

    private func handleOutput(status: OSStatus, infoFlags: VTEncodeInfoFlags,
                              sampleBuffer: CMSampleBuffer?) {
        guard status == noErr, !infoFlags.contains(.frameDropped),
              let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else {
            lock.lock()
            droppedCount &+= 1
            lock.unlock()
            return
        }
        guard let frame = Self.annexBFrame(from: sampleBuffer) else {
            log.error("Annex-B conversion failed for an encoded frame")
            return
        }
        onEncodedFrame?(frame)
    }

    // MARK: Session construction

    private static func makeSession(_ config: Configuration, log: Logger) throws -> VTCompressionSession {
        var session: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue!] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(config.width), height: Int32(config.height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw EncoderError.sessionCreationFailed(status)
        }
        // Property rejections are logged, not fatal: low-latency mode varies
        // by chip generation in which auxiliary keys it accepts, and a missing
        // nicety must not kill the camera feed.
        trySet(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!, log)
        trySet(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel, log)
        trySet(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!, log)
        trySet(session, kVTCompressionPropertyKey_AllowOpenGOP, kCFBooleanFalse!, log)
        trySet(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
               NSNumber(value: config.keyframeIntervalSeconds), log)
        trySet(session, kVTCompressionPropertyKey_MaxKeyFrameInterval,
               NSNumber(value: max(1, Int(Double(config.fps) * config.keyframeIntervalSeconds))), log)
        trySet(session, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: config.fps), log)
        trySet(session, kVTCompressionPropertyKey_AverageBitRate,
               NSNumber(value: config.averageBitrateBps), log)
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    private static func trySet(_ session: VTCompressionSession, _ key: CFString,
                               _ value: CFTypeRef, _ log: Logger) {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr {
            log.warning("encoder property \(key as String) rejected: \(status)")
        }
    }

    // MARK: Sample buffer → Annex-B (deterministic, no session state)

    /// Converts one encoded sample buffer to a wire-ready `EncodedFrame`.
    static func annexBFrame(from sampleBuffer: CMSampleBuffer) -> EncodedFrame? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let (parameterSets, nalUnitHeaderLength) = hevcParameterSets(of: format) else {
            return nil
        }
        let isKeyframe = isKeyframe(sampleBuffer)

        let length = CMBlockBufferGetDataLength(dataBuffer)
        guard length > 0 else { return nil }
        var raw = Data(count: length)
        let copyStatus = raw.withUnsafeMutableBytes { buffer -> OSStatus in
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length,
                                       destination: buffer.baseAddress!)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        guard let annexB = annexB(fromLengthPrefixed: raw,
                                  nalUnitHeaderLength: nalUnitHeaderLength,
                                  prepending: isKeyframe ? parameterSets : []) else {
            return nil
        }
        return EncodedFrame(annexB: annexB,
                            pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                            isKeyframe: isKeyframe)
    }

    /// Pure: rewrites length-prefixed NAL units (big-endian length of
    /// `nalUnitHeaderLength` bytes each — the VT sample-buffer layout) as
    /// Annex-B with 4-byte start codes, prepending `parameterSets`
    /// (vps/sps/pps) each as its own start-code-delimited NAL.
    /// Returns nil on malformed input (truncated or zero-length NAL).
    public static func annexB(fromLengthPrefixed data: Data, nalUnitHeaderLength: Int,
                              prepending parameterSets: [Data]) -> Data? {
        guard (1...4).contains(nalUnitHeaderLength) else { return nil }
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data(capacity: data.count + parameterSets.reduce(0) { $0 + $1.count + 4 } + 16)
        for set in parameterSets {
            out.append(contentsOf: startCode)
            out.append(set)
        }
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            guard i + nalUnitHeaderLength <= bytes.count else { return nil }
            var length = 0
            for k in 0..<nalUnitHeaderLength {
                length = (length << 8) | Int(bytes[i + k])
            }
            i += nalUnitHeaderLength
            guard length > 0, i + length <= bytes.count else { return nil }
            out.append(contentsOf: startCode)
            out.append(contentsOf: bytes[i..<(i + length)])
            i += length
        }
        return out
    }

    static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                        createIfNecessary: false)
                as? [[String: Any]],
              let first = attachments.first else {
            return true // no attachments = sync sample, per CoreMedia convention
        }
        return (first[kCMSampleAttachmentKey_NotSync as String] as? Bool) != true
    }

    /// Extracts (vps, sps, pps, …) and the NAL length-prefix size from an
    /// HEVC format description.
    static func hevcParameterSets(of format: CMFormatDescription)
        -> (sets: [Data], nalUnitHeaderLength: Int)? {
        var count = 0
        var nalHeaderLength: Int32 = 0
        var status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalHeaderLength)
        guard status == noErr, count > 0 else { return nil }
        var sets: [Data] = []
        sets.reserveCapacity(count)
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer, size > 0 else { return nil }
            sets.append(Data(bytes: pointer, count: size))
        }
        return (sets, Int(nalHeaderLength))
    }
}
