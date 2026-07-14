#if os(iOS)
import CoreMedia
import CoreVideo
import Foundation
import PrismLinkSender
import VideoToolbox

/// Simulator-only fallback video encoder for `SyntheticStreamer`.
///
/// The shipping `LowLatencyEncoder` requests VideoToolbox's
/// `EnableLowLatencyRateControl` spec, which requires the **hardware**
/// low-latency HEVC encoder — absent in the iOS Simulator (init fails with
/// -12908 / `kVTCouldNotFindVideoEncoderErr`). Since the engine is read-only,
/// this App-local encoder builds a plain `VTCompressionSession` (no
/// low-latency spec, software encode permitted) so the transport can still be
/// exercised from the Simulator.
///
/// It emits the exact same wire format as `LowLatencyEncoder` — whole-frame
/// Annex-B with parameter sets in-band on every keyframe — reusing the
/// engine's public `LowLatencyEncoder.annexB(fromLengthPrefixed:…)`. HEVC is
/// tried first (so the Mac's HEVC decoder decodes real frames end-to-end);
/// H.264 is a last resort that still proves the QUIC media lane (the Mac
/// decoder is HEVC-only, so those records reassemble — `parts` advance — but
/// won't complete a decoded frame).
final class SyntheticEncoder: @unchecked Sendable {

    struct Frame {
        let annexB: Data
        let pts: CMTime
        let isKeyframe: Bool
    }

    /// Wire codec actually in use ("hevc" or "h264") once init succeeds.
    let codecName: String
    var onEncodedFrame: ((Frame) -> Void)?

    private let session: VTCompressionSession
    private let codecType: CMVideoCodecType

    init?(width: Int, height: Int, fps: Int, bitrateBps: Int) {
        if let s = Self.makeSession(codec: kCMVideoCodecType_HEVC, width: width,
                                    height: height, fps: fps, bitrateBps: bitrateBps) {
            session = s; codecType = kCMVideoCodecType_HEVC; codecName = "hevc"
        } else if let s = Self.makeSession(codec: kCMVideoCodecType_H264, width: width,
                                           height: height, fps: fps, bitrateBps: bitrateBps) {
            session = s; codecType = kCMVideoCodecType_H264; codecName = "h264"
        } else {
            return nil
        }
    }

    deinit {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    func encode(pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
            duration: duration, frameProperties: nil, infoFlagsOut: nil
        ) { [weak self] status, flags, sampleBuffer in
            guard let self, status == noErr, !flags.contains(.frameDropped),
                  let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer),
                  let frame = self.annexBFrame(from: sampleBuffer) else { return }
            self.onEncodedFrame?(frame)
        }
    }

    func invalidate() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    // MARK: Sample buffer → Annex-B (reuses the engine's public converter)

    private func annexBFrame(from sampleBuffer: CMSampleBuffer) -> Frame? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let (sets, nalLen) = parameterSets(of: format) else { return nil }
        let isKeyframe = Self.isKeyframe(sampleBuffer)

        let length = CMBlockBufferGetDataLength(dataBuffer)
        guard length > 0 else { return nil }
        var raw = Data(count: length)
        let copyStatus = raw.withUnsafeMutableBytes { buffer -> OSStatus in
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length,
                                       destination: buffer.baseAddress!)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        guard let annexB = LowLatencyEncoder.annexB(
            fromLengthPrefixed: raw, nalUnitHeaderLength: nalLen,
            prepending: isKeyframe ? sets : []) else { return nil }
        return Frame(annexB: annexB,
                     pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                     isKeyframe: isKeyframe)
    }

    private func parameterSets(of format: CMFormatDescription) -> (sets: [Data], nalLen: Int)? {
        var count = 0
        var nalLen: Int32 = 0
        let get: (Int, UnsafeMutablePointer<UnsafePointer<UInt8>?>?, UnsafeMutablePointer<Int>?,
                  UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int32>?) -> OSStatus
        if codecType == kCMVideoCodecType_HEVC {
            get = { i, p, s, c, n in
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: p,
                    parameterSetSizeOut: s, parameterSetCountOut: c, nalUnitHeaderLengthOut: n) }
        } else {
            get = { i, p, s, c, n in
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: p,
                    parameterSetSizeOut: s, parameterSetCountOut: c, nalUnitHeaderLengthOut: n) }
        }
        guard get(0, nil, nil, &count, &nalLen) == noErr, count > 0 else { return nil }
        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard get(index, &pointer, &size, nil, nil) == noErr,
                  let pointer, size > 0 else { return nil }
            sets.append(Data(bytes: pointer, count: size))
        }
        return (sets, Int(nalLen))
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[String: Any]],
              let first = attachments.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync as String] as? Bool) != true
    }

    // MARK: Session construction (no low-latency spec ⇒ software encode allowed)

    private static func makeSession(codec: CMVideoCodecType, width: Int, height: Int,
                                    fps: Int, bitrateBps: Int) -> VTCompressionSession? {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: codec,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { return nil }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: NSNumber(value: max(1, fps)))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitrateBps))
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }
}
#endif
