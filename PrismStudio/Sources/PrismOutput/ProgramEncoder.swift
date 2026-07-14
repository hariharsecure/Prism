import CoreMedia
import CoreVideo
import Foundation
import PrismCore
import VideoToolbox
import os

/// Hardware VTCompressionSession wrapper — the explicit encode stage for
/// streaming (DESIGN §3.2: "VT encode #1 → RTMP/SRT"; encode policy lives
/// here, not inside a writer).
///
/// Output: encoded `CMSampleBuffer`s delivered on a private serial queue, in
/// presentation order. Ordering is guaranteed because (a) frame reordering /
/// B-frames are disabled (live profile), so the encoder emits in submission
/// order, and (b) delivery hops through one serial queue.
public final class ProgramEncoder: @unchecked Sendable {
    public struct Settings: Sendable {
        public enum Codec: String, Sendable {
            case h264
            case hevc

            var vtCodecType: CMVideoCodecType {
                switch self {
                case .h264: return kCMVideoCodecType_H264
                case .hevc: return kCMVideoCodecType_HEVC
                }
            }
        }

        /// Program dynamic range for the streamed/buffered elementary stream.
        ///
        /// - `.sdr` (default): the codec/profile chosen by `codec` at 8-bit, no
        ///   color tags — byte-for-byte the original streaming behavior.
        /// - `.hdr`: forces **HEVC Main10** (`kVTProfileLevel_HEVC_Main10_AutoLevel`,
        ///   10-bit) regardless of `codec`, and stamps Rec.2020 / ITU-R BT.2100
        ///   HLG color attachments onto the compression session so the emitted
        ///   elementary stream (and every `CMSampleBuffer` format description) is
        ///   tagged HDR. Feed it the compositor's `.hdr` 10-bit
        ///   (`ARGB2101010LEPacked`, Rec.2020/HLG-tagged) program frames.
        ///   Mirrors `RecordingSettings.DynamicRange` so streaming/replay reach
        ///   HDR parity with the recording (Stage O sink-parity).
        public enum DynamicRange: String, Sendable { case sdr, hdr }

        public var codec: Codec
        /// Program dynamic range; `.hdr` overrides `codec` to HEVC Main10.
        public var dynamicRange: DynamicRange
        public var width: Int
        public var height: Int
        /// Average bitrate, bits/sec. Adjustable live via `updateBitrate(_:)`.
        public var averageBitrate: Int
        /// Maximum keyframe interval in seconds.
        public var keyframeInterval: Double
        /// Encoder frame-rate hint (also sizes the keyframe interval in frames).
        public var expectedFrameRate: Double
        /// Opt into VideoToolbox's low-latency rate control
        /// (`kVTVideoEncoderSpecification_EnableLowLatencyRateControl`):
        /// hardware-only pipeline, no frame delay, tighter rate adaptation —
        /// the right mode for RTMP/SRT contribution.
        public var lowLatencyRateControl: Bool

        public init(
            codec: Codec = .h264,
            width: Int = 1920,
            height: Int = 1080,
            averageBitrate: Int = 6_000_000,
            keyframeInterval: Double = 2.0,
            expectedFrameRate: Double = 60,
            lowLatencyRateControl: Bool = true,
            dynamicRange: DynamicRange = .sdr
        ) {
            self.codec = codec
            self.dynamicRange = dynamicRange
            self.width = width
            self.height = height
            self.averageBitrate = averageBitrate
            self.keyframeInterval = keyframeInterval
            self.expectedFrameRate = expectedFrameRate
            self.lowLatencyRateControl = lowLatencyRateControl
        }

        /// The VideoToolbox codec actually used: `.hdr` forces HEVC (Main10)
        /// regardless of the requested `codec` (8-bit H.264 can't carry a 10-bit
        /// HDR master), mirroring `RecordingSettings`.
        var effectiveCodec: Codec { dynamicRange == .hdr ? .hevc : codec }
    }

    public enum EncoderError: Error {
        case sessionCreationFailed(OSStatus)
        case configurationFailed(property: String, status: OSStatus)
        case notRunning
        case encodeFailed(OSStatus)
    }

    public struct Stats: Sendable {
        public let framesSubmitted: UInt64
        public let framesEncoded: UInt64
        public let framesDropped: UInt64
    }

    public let settings: Settings

    /// Encoded-frame sink. Set before `start()`. Called on a private serial
    /// queue, strictly in encode order.
    public var onEncodedFrame: ((CMSampleBuffer) -> Void)? {
        get { callbackLock.withLock { $0 } }
        set { callbackLock.withLock { $0 = newValue } }
    }

    /// VTCompressionSession is thread-safe per VideoToolbox's contract but
    /// carries no Sendable annotation; the box confines the unchecked claim.
    private final class SessionBox: @unchecked Sendable {
        let session: VTCompressionSession
        init(_ session: VTCompressionSession) { self.session = session }
    }

    private struct MutableState {
        var session: SessionBox?
        var forceNextKeyframe = false
        var framesSubmitted: UInt64 = 0
        /// Bumped by `stop()` after the delivery drain: a delivery block
        /// carrying an older generation is suppressed, so no consumer
        /// callback can fire after `stop()` returns (B12).
        var generation: UInt64 = 0
    }

    private let stateLock = OSAllocatedUnfairLock<MutableState>(initialState: MutableState())
    private let callbackLock = OSAllocatedUnfairLock<((CMSampleBuffer) -> Void)?>(initialState: nil)
    private let deliveredLock = OSAllocatedUnfairLock<(encoded: UInt64, dropped: UInt64)>(initialState: (0, 0))
    private let deliveryQueue = DispatchQueue(label: "studio.prism.output.encoder.delivery")
    /// Marks this instance's delivery queue so `flush()`/`stop()` can detect
    /// being called from inside `onEncodedFrame` (same queue → a sync barrier
    /// would deadlock; B13).
    private static let deliveryQueueKey = DispatchSpecificKey<UUID>()
    private let deliveryQueueID = UUID()
    private let log = EngineLog.logger("output.encoder")

    public init(settings: Settings) {
        self.settings = settings
        deliveryQueue.setSpecific(key: Self.deliveryQueueKey, value: deliveryQueueID)
    }

    deinit {
        stop()
    }

    /// Creates and configures the compression session (hardware required).
    /// Idempotent-safe: a live session is invalidated before creating a new one
    /// so a double-start never leaks a VTCompressionSession (Codex W14).
    public func start() throws {
        stop()
        var spec: [CFString: Any] = [
            // Hardware or nothing — falling back to a software encoder would
            // silently blow the CPU budget (§3.5).
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        if settings.lowLatencyRateControl {
            // Low-latency rate control is requested via the encoder
            // *specification* (it selects a different encoder mode), not a
            // session property.
            spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true
        }

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(settings.width),
            height: Int32(settings.height),
            codecType: settings.effectiveCodec.vtCodecType,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil, // per-frame output handlers are used instead
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw EncoderError.sessionCreationFailed(status)
        }

        // A property-set failure here must not leak the freshly-created session
        // (it isn't stored yet, so stop() can't reclaim it) — Codex #8.
        do {
            try setProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
            try setProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
            try setProperty(session, kVTCompressionPropertyKey_AverageBitRate, settings.averageBitrate as CFNumber)
            try setProperty(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, settings.keyframeInterval as CFNumber)
            let keyframeFrames = max(1, Int(settings.keyframeInterval * settings.expectedFrameRate))
            try setProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, keyframeFrames as CFNumber)
            try setProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, settings.expectedFrameRate as CFNumber)
            if settings.dynamicRange == .hdr {
                // HDR streaming/replay parity (Stage O): HEVC Main10 + Rec.2020 /
                // ITU-R BT.2100 HLG color attachments, mirroring the HDR recorder.
                // 8-bit H.264/HEVC-Main can't carry a 10-bit HDR master, so the
                // requested `codec` is overridden (see `effectiveCodec`).
                try setProperty(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main10_AutoLevel)
                try setProperty(session, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_2020)
                try setProperty(session, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_2100_HLG)
                try setProperty(session, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_2020)
            } else {
                switch settings.codec {
                case .h264:
                    try setProperty(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
                case .hevc:
                    try setProperty(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
                }
            }
        } catch {
            VTCompressionSessionInvalidate(session)
            throw error
        }

        VTCompressionSessionPrepareToEncodeFrames(session)
        let box = SessionBox(session)
        stateLock.withLock { $0.session = box }
        log.info("encoder started: \(self.settings.effectiveCodec.rawValue, privacy: .public) \(self.settings.width)x\(self.settings.height) @ \(self.settings.averageBitrate) bps, range=\(self.settings.dynamicRange.rawValue, privacy: .public), lowLatency=\(self.settings.lowLatencyRateControl)")
    }

    /// Sets a session property; `kVTPropertyNotSupportedErr` is tolerated
    /// (low-latency encoders reject some tuning keys) and logged, anything
    /// else is a hard configuration error.
    private func setProperty(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        switch status {
        case noErr:
            break
        case kVTPropertyNotSupportedErr:
            log.info("encoder property \(key as String, privacy: .public) not supported in this mode; skipped")
        default:
            throw EncoderError.configurationFailed(property: key as String, status: status)
        }
    }

    /// Submits one frame (IOSurface-backed, house PTS — handed to the media
    /// engine with zero copies). Output arrives asynchronously on the
    /// delivery queue via `onEncodedFrame`.
    public func encode(_ frame: VideoFrame) throws {
        let (box, forceKeyframe, generation): (SessionBox?, Bool, UInt64) = stateLock.withLock { s in
            let force = s.forceNextKeyframe
            s.forceNextKeyframe = false
            if s.session != nil { s.framesSubmitted &+= 1 }
            return (s.session, force, s.generation)
        }
        guard let session = box?.session else { throw EncoderError.notRunning }

        var frameProperties: CFDictionary?
        if forceKeyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any] as CFDictionary
        }

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: frame.pixelBuffer,
            presentationTimeStamp: frame.pts,
            duration: frame.duration.isValid ? frame.duration : .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, infoFlags, sampleBuffer in
            guard let self else { return }
            guard status == noErr, let sampleBuffer, !infoFlags.contains(.frameDropped) else {
                self.deliveredLock.withLock { $0.dropped &+= 1 }
                return
            }
            // VT emits handlers serially in encode order (reordering is off);
            // one serial queue preserves that order to the consumer.
            self.deliveryQueue.async {
                // A stop() that already drained must not leak this straggler
                // to the consumer (post-stop callback guard).
                guard self.stateLock.withLock({ $0.generation }) == generation else {
                    self.deliveredLock.withLock { $0.dropped &+= 1 }
                    return
                }
                self.deliveredLock.withLock { $0.encoded &+= 1 }
                self.callbackLock.withLock { $0 }?(sampleBuffer)
            }
        }
        guard status == noErr else { throw EncoderError.encodeFailed(status) }
    }

    /// The next encoded frame will be a keyframe (stream start, scene cut,
    /// or a decoder's recovery request).
    public func forceKeyframe() {
        stateLock.withLock { $0.forceNextKeyframe = true }
    }

    /// Live bitrate change (rate adaptation while streaming).
    public func updateBitrate(_ bitsPerSecond: Int) {
        guard let session = stateLock.withLock({ $0.session })?.session else { return }
        let status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitsPerSecond as CFNumber)
        if status != noErr {
            log.error("bitrate update to \(bitsPerSecond) failed: \(status)")
        }
    }

    /// Drains all pending frames through the output callback.
    ///
    /// Safe to call from within `onEncodedFrame`: the encoder detects it is
    /// already on the delivery queue and skips the sync barrier (which would
    /// deadlock); in that case the trailing deliveries complete asynchronously
    /// right after the current callback returns.
    public func flush() {
        guard let session = stateLock.withLock({ $0.session })?.session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        drainDeliveries()
    }

    /// Flushes, drains the delivery queue (no `onEncodedFrame` runs after this
    /// returns — a delivery barrier), and tears the session down. The encoder
    /// can be `start()`ed again. Like `flush()`, safe from within
    /// `onEncodedFrame` (the barrier is skipped; the generation guard still
    /// blocks post-stop callbacks).
    public func stop() {
        let box = stateLock.withLock { s -> SessionBox? in
            let out = s.session
            s.session = nil
            return out
        }
        guard let session = box?.session else { return }
        // 1. Force out everything VT still holds (handlers enqueue deliveries).
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        // 2. Delivery barrier: everything already queued reaches the consumer.
        drainDeliveries()
        // 3. Suppress stragglers (e.g. an encode racing this stop): any
        //    delivery enqueued after the drain carries the old generation.
        stateLock.withLock { $0.generation &+= 1 }
        VTCompressionSessionInvalidate(session)
    }

    /// Waits until every queued delivery has run — unless already on the
    /// delivery queue (called from inside `onEncodedFrame`), where waiting
    /// would deadlock; the queued deliveries then run right after the current
    /// callback.
    private func drainDeliveries() {
        guard DispatchQueue.getSpecific(key: Self.deliveryQueueKey) != deliveryQueueID else { return }
        deliveryQueue.sync {}
    }

    public var stats: Stats {
        let submitted = stateLock.withLock { $0.framesSubmitted }
        let (encoded, dropped) = deliveredLock.withLock { $0 }
        return Stats(framesSubmitted: submitted, framesEncoded: encoded, framesDropped: dropped)
    }
}
