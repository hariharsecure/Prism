import CoreMedia
import CoreVideo
import Foundation
import PrismCore
import VideoToolbox

// MARK: - Pure HEVC Annex-B helpers

/// Pure Annex-B utilities: start-code scanning, NAL typing, and conversion to
/// the 4-byte length-prefixed layout VideoToolbox sample buffers require.
public enum HEVCAnnexB {
    /// HEVC NAL unit types we care about (nal_unit_type, 6 bits).
    public enum NALType {
        public static let vps = 32
        public static let sps = 33
        public static let pps = 34
        public static let idrWRADL = 19
        public static let idrNLP = 20
        public static let cra = 21

        public static func isParameterSet(_ type: Int) -> Bool {
            type == vps || type == sps || type == pps
        }
        /// IRAP range per the spec (BLA/IDR/CRA: 16…23).
        public static func isKeyframe(_ type: Int) -> Bool {
            (16...23).contains(type)
        }
    }

    /// nal_unit_type from the first NAL header byte: (byte >> 1) & 0x3F.
    public static func nalType(_ nal: Data) -> Int {
        guard let first = nal.first else { return -1 }
        return Int((first >> 1) & 0x3F)
    }

    /// Splits an Annex-B elementary stream into raw NAL units (start codes
    /// removed). Accepts 3-byte (001) and 4-byte (0001) start codes. Pure.
    public static func splitNALUnits(_ annexB: Data) -> [Data] {
        let bytes = [UInt8](annexB) // work on a plain array; Data slices index-trap easily
        var starts: [Int] = []      // index just past each start code
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append(i + 3)
                    i += 3
                    continue
                }
                if i + 3 < bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    starts.append(i + 4)
                    i += 4
                    continue
                }
            }
            i += 1
        }
        var nals: [Data] = []
        for (n, start) in starts.enumerated() {
            var end = n + 1 < starts.count ? starts[n + 1] : bytes.count
            // Trim the next start code (and any zero padding before it) off this NAL.
            if n + 1 < starts.count {
                end -= 3 // the 001
                while end > start, bytes[end - 1] == 0 { end -= 1 }
            }
            if end > start {
                nals.append(Data(bytes[start..<end]))
            }
        }
        return nals
    }

    /// Concatenates NAL units into the AVCC/hvcC sample layout: each NAL
    /// prefixed with its length as a 4-byte BIG-endian integer. Pure.
    public static func lengthPrefixed(_ nals: [Data]) -> Data {
        var out = Data(capacity: nals.reduce(0) { $0 + $1.count + 4 })
        for nal in nals {
            let len = UInt32(nal.count)
            out.append(UInt8(truncatingIfNeeded: len >> 24))
            out.append(UInt8(truncatingIfNeeded: len >> 16))
            out.append(UInt8(truncatingIfNeeded: len >> 8))
            out.append(UInt8(truncatingIfNeeded: len))
            out.append(nal)
        }
        return out
    }

    /// Stage N: parse `bit_depth_luma_minus8` out of an HEVC SPS NAL → luma bit
    /// depth (8, 10, 12…), or nil if the SPS can't be parsed. Pure. Used to pick a
    /// 10-bit decode output (`x420`) instead of forcing 8-bit `420v` and truncating a
    /// real 10-bit HDR stream. Independently unit-testable with synthesized SPS bits.
    ///
    /// `sps` is the raw NAL *including* its 2-byte header. Emulation-prevention bytes
    /// are removed, then the SPS RBSP is bit-parsed through profile_tier_level up to
    /// `bit_depth_luma_minus8` (H.265 §7.3.2.2.1).
    public static func bitDepthLuma(sps: Data) -> Int? {
        guard sps.count > 2 else { return nil }
        let rbsp = removeEmulationPrevention([UInt8](sps.dropFirst(2)))
        var r = BitReader(rbsp)
        guard r.u(4) != nil else { return nil }             // sps_video_parameter_set_id
        guard let maxSub = r.u(3) else { return nil }        // sps_max_sub_layers_minus1
        guard r.u(1) != nil else { return nil }              // sps_temporal_id_nesting_flag
        guard profileTierLevel(&r, maxNumSubLayersMinus1: maxSub) else { return nil }
        guard r.ue() != nil else { return nil }              // sps_seq_parameter_set_id
        guard let chroma = r.ue() else { return nil }        // chroma_format_idc
        if chroma == 3, r.u(1) == nil { return nil }         // separate_colour_plane_flag
        guard r.ue() != nil, r.ue() != nil else { return nil }  // pic_width/height_in_luma_samples
        guard let confWin = r.u(1) else { return nil }       // conformance_window_flag
        if confWin == 1 { for _ in 0..<4 where r.ue() == nil { return nil } }
        guard let bdLumaMinus8 = r.ue() else { return nil }  // bit_depth_luma_minus8
        return 8 + Int(bdLumaMinus8)
    }

    /// Skip an H.265 profile_tier_level( 1, maxNumSubLayersMinus1 ) — the general
    /// profile/tier/level is a fixed 88 bits + an 8-bit level; each present sub-layer
    /// adds another 88 + 8. Returns false on underrun.
    static func profileTierLevel(_ r: inout BitReader, maxNumSubLayersMinus1 m: UInt32) -> Bool {
        guard r.skip(88), r.skip(8) else { return false }    // general profile block + general_level_idc
        var subProfile = [Bool](), subLevel = [Bool]()
        for _ in 0..<m {
            guard let p = r.u(1), let l = r.u(1) else { return false }
            subProfile.append(p == 1); subLevel.append(l == 1)
        }
        if m > 0 { for _ in m..<8 where !r.skip(2) { return false } }  // reserved_zero_2bits[i]
        for i in 0..<Int(m) {
            if subProfile[i], !r.skip(88) { return false }   // sub_layer profile block
            if subLevel[i], !r.skip(8) { return false }      // sub_layer_level_idc
        }
        return true
    }

    /// Strip HEVC emulation-prevention bytes (00 00 03 → 00 00) from a NAL RBSP.
    static func removeEmulationPrevention(_ bytes: [UInt8]) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(bytes.count)
        var zeroRun = 0, i = 0
        while i < bytes.count {
            let b = bytes[i]
            if zeroRun >= 2, b == 0x03, i + 1 < bytes.count, bytes[i + 1] <= 0x03 {
                zeroRun = 0; i += 1; continue    // drop emulation_prevention_three_byte
            }
            out.append(b)
            zeroRun = (b == 0) ? zeroRun + 1 : 0
            i += 1
        }
        return out
    }

    /// Minimal MSB-first bit reader over a byte array (Exp-Golomb aware).
    struct BitReader {
        private let bytes: [UInt8]
        private var bitPos = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        private var bitsLeft: Int { bytes.count * 8 - bitPos }
        private mutating func bit() -> UInt32? {
            guard bitPos < bytes.count * 8 else { return nil }
            let v = (UInt32(bytes[bitPos >> 3]) >> (7 - (bitPos & 7))) & 1
            bitPos += 1
            return v
        }
        mutating func u(_ n: Int) -> UInt32? {
            var v: UInt32 = 0
            for _ in 0..<n { guard let b = bit() else { return nil }; v = (v << 1) | b }
            return v
        }
        mutating func skip(_ n: Int) -> Bool {
            guard bitsLeft >= n else { return false }
            bitPos += n; return true
        }
        mutating func ue() -> UInt32? {
            var zeros = 0
            while true {
                guard let b = bit() else { return nil }
                if b == 1 { break }
                zeros += 1
                if zeros > 31 { return nil }
            }
            if zeros == 0 { return 0 }
            guard let rest = u(zeros) else { return nil }
            return (UInt32(1) << UInt32(zeros)) - 1 + rest
        }
    }

    /// Pulls (vps, sps, pps) out of a NAL list if all three are present.
    public static func parameterSets(in nals: [Data]) -> (vps: Data, sps: Data, pps: Data)? {
        var vps: Data?, sps: Data?, pps: Data?
        for nal in nals {
            switch nalType(nal) {
            case NALType.vps: vps = nal
            case NALType.sps: sps = nal
            case NALType.pps: pps = nal
            default: break
            }
        }
        guard let vps, let sps, let pps else { return nil }
        return (vps, sps, pps)
    }
}

// MARK: - Decoder

/// Per-peer HEVC decode path: reassembled Annex-B frames → VTDecompressionSession
/// → IOSurface-backed CVPixelBuffers → `VideoFrame` (pts already in house time;
/// the sending device translated it — §3.3/§3.4, we trust it).
public final class VideoFrameDecoder: @unchecked Sendable {
    public enum DecoderError: Error {
        case formatDescriptionFailed(OSStatus)
        case sessionCreationFailed(OSStatus)
        case blockBufferFailed(OSStatus)
        case sampleBufferFailed(OSStatus)
    }

    /// Decoded output. Called on VideoToolbox's decode thread.
    public var onFrame: ((VideoFrame) -> Void)?
    /// Fired when the decoder needs an IDR to proceed (no parameter sets yet,
    /// or a decode error) — wire this to LinkPeer.requestKeyframe().
    public var onNeedsKeyframe: (() -> Void)?

    public let source: SourceID

    private let log = EngineLog.logger("link.decode")
    private let queue = DispatchQueue(label: "studio.prism.link.decode")
    private var session: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    private var currentParameterSets: (vps: Data, sps: Data, pps: Data)?
    private var awaitingKeyframe = true

    public init(source: SourceID) {
        self.source = source
    }

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    /// Feed one reassembled *video* frame (whole-frame Annex-B payload).
    public func decode(_ frame: ReassembledFrame) {
        queue.async { [weak self] in
            self?.decodeOnQueue(frame)
        }
    }

    private func decodeOnQueue(_ frame: ReassembledFrame) {
        let nals = HEVCAnnexB.splitNALUnits(frame.payload)
        guard !nals.isEmpty else { return }

        // In-band parameter sets (senders repeat them on every keyframe).
        if let sets = HEVCAnnexB.parameterSets(in: nals) {
            if currentParameterSets == nil || sets != currentParameterSets! {
                do {
                    try rebuildSession(with: sets)
                    currentParameterSets = sets
                } catch {
                    log.error("format/session rebuild failed: \(String(describing: error))")
                    return
                }
            }
        }
        guard let session, let formatDescription else {
            // Can't decode anything before the first keyframe's parameter sets.
            onNeedsKeyframe?()
            return
        }
        if awaitingKeyframe && !frame.isKeyframe {
            onNeedsKeyframe?()
            return
        }

        // Strip parameter sets (they live in the format description) and wrap
        // the VCL/SEI NALs in the length-prefixed sample layout.
        let sampleNALs = nals.filter { !HEVCAnnexB.NALType.isParameterSet(HEVCAnnexB.nalType($0)) }
        guard !sampleNALs.isEmpty else { return }
        let sampleData = HEVCAnnexB.lengthPrefixed(sampleNALs)

        let pts = CMTime(value: frame.ptsHouseNanos, timescale: 1_000_000_000)
        do {
            let sampleBuffer = try Self.makeSampleBuffer(data: sampleData,
                                                         format: formatDescription, pts: pts)
            var infoFlags = VTDecodeInfoFlags()
            let status = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sampleBuffer,
                flags: [._EnableAsynchronousDecompression],
                infoFlagsOut: &infoFlags
            ) { [weak self] status, _, imageBuffer, pts, _ in
                self?.handleDecoded(status: status, imageBuffer: imageBuffer, pts: pts)
            }
            if status != noErr {
                log.error("decode submit failed (\(status)); requesting keyframe")
                awaitingKeyframe = true
                onNeedsKeyframe?()
            } else {
                awaitingKeyframe = false
            }
        } catch {
            log.error("sample buffer build failed: \(String(describing: error))")
        }
    }

    private func handleDecoded(status: OSStatus, imageBuffer: CVImageBuffer?, pts: CMTime) {
        guard status == noErr, let pixelBuffer = imageBuffer else {
            log.warning("decode output error \(status); requesting keyframe")
            queue.async { [weak self] in
                self?.awaitingKeyframe = true
                self?.onNeedsKeyframe?()
            }
            return
        }
        onFrame?(VideoFrame(pixelBuffer: pixelBuffer, pts: pts, source: source))
    }

    private func rebuildSession(with sets: (vps: Data, sps: Data, pps: Data)) throws {
        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        let format = try Self.makeFormatDescription(vps: sets.vps, sps: sets.sps, pps: sets.pps)

        // IOSurface-backed, Metal-compatible outputs — the zero-copy invariant
        // (VideoFrame.init asserts it). The pixel format MUST be pinned: left to
        // its own choice, VT on Apple silicon emits lossless-compressed 4:2:0
        // ('&8v0'), which the compositor can't sample — layers skip silently.
        // (Found by the link-render seam verification, 2026-07-07.)
        //
        // Stage N: pin a 10-bit output ('x420') when the SPS declares ≥10-bit luma,
        // so a real 10-bit HDR peer stream is decoded at 10-bit instead of being
        // truncated to 8-bit '420v'. The colorimetry (HLG/PQ, Rec.2020) rides the
        // format description onto the decoded buffers, so the compositor tags flow.
        let lumaDepth = HEVCAnnexB.bitDepthLuma(sps: sets.sps) ?? 8
        let outputFormat: OSType = lumaDepth >= 10
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if lumaDepth >= 10 {
            log.info("link decode: 10-bit stream (\(lumaDepth)-bit luma) → 'x420' output for \(self.source)")
        }
        let imageBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: outputFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw DecoderError.sessionCreationFailed(status)
        }
        self.formatDescription = format
        self.session = session
        self.awaitingKeyframe = true
        log.info("decoder session (re)built for \(self.source)")
    }

    // MARK: CoreMedia plumbing (static, deterministic)

    static func makeFormatDescription(vps: Data, sps: Data, pps: Data) throws -> CMFormatDescription {
        var format: CMFormatDescription?
        let status: OSStatus = vps.withUnsafeBytes { vpsRaw in
            sps.withUnsafeBytes { spsRaw in
                pps.withUnsafeBytes { ppsRaw in
                    let pointers: [UnsafePointer<UInt8>] = [
                        vpsRaw.bindMemory(to: UInt8.self).baseAddress!,
                        spsRaw.bindMemory(to: UInt8.self).baseAddress!,
                        ppsRaw.bindMemory(to: UInt8.self).baseAddress!,
                    ]
                    let sizes: [Int] = [vps.count, sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: nil,
                        parameterSetCount: pointers.count,
                        parameterSetPointers: pointers,
                        parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &format
                    )
                }
            }
        }
        guard status == noErr, let format else {
            throw DecoderError.formatDescriptionFailed(status)
        }
        return format
    }

    static func makeSampleBuffer(data: Data, format: CMFormatDescription, pts: CMTime) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw DecoderError.blockBufferFailed(status)
        }
        status = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == kCMBlockBufferNoErr else {
            throw DecoderError.blockBufferFailed(status)
        }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw DecoderError.sampleBufferFailed(status)
        }
        return sampleBuffer
    }
}

// MARK: - VideoSource façade

/// Presents one link peer's video as a standard `VideoSource` so the engine's
/// source graph treats a network camera exactly like a local one.
public final class NetworkVideoSource: VideoSource, @unchecked Sendable {
    public let id: SourceID
    public private(set) var state: SourceState = .idle
    /// Called from the decoder's output thread (the "capture queue" of this source).
    public var onFrame: ((VideoFrame) -> Void)?

    private let lock = NSLock()
    /// Serial delivery queue. VideoToolbox's async decompression callback can
    /// fire `deliver` from multiple threads concurrently; local sources
    /// (camera/screen/mic) all deliver on a serial queue, and downstream
    /// consumers (per-source ColorProcessor/BackgroundEffect) are not
    /// thread-safe — so this façade serializes to honor the same contract.
    /// (Codex wave-2 finding W4, 2026-07-07.)
    private let deliveryQueue = DispatchQueue(label: "studio.prism.link.netsource")
    /// Single-slot, latest-wins hand-off (all access under `lock`). Bounds the
    /// delivery backlog to one frame: if the `onFrame` consumer is slower than
    /// the decoder, newer frames supersede an un-delivered one instead of piling
    /// up on `deliveryQueue` and retaining an unbounded chain of pixel buffers
    /// (Codex finding F9). Serial one-at-a-time delivery (W4) is preserved: only
    /// one drain is ever scheduled/running.
    private var pendingFrame: VideoFrame?
    private var isDraining = false

    public init(id: SourceID) {
        self.id = id
    }

    /// The link layer starts delivering when the peer streams; `start`/`stop`
    /// gate emission (they do not tear down the connection — that's LinkPeer's job).
    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        state = .running
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        state = .idle
    }

    /// LinkPeer → engine delivery point. Serializes onto `deliveryQueue` so
    /// consumers see one frame at a time even under concurrent VT decode
    /// callbacks (W4), and bounds the backlog to a single latest-wins slot so a
    /// stalled consumer can't grow memory unboundedly (F9).
    func deliver(_ frame: VideoFrame) {
        lock.lock()
        guard state == .running else { lock.unlock(); return }
        // Latest-wins: replace any un-delivered frame rather than enqueue.
        pendingFrame = frame
        if isDraining {
            // A drain is already scheduled/running; it will pick up `pendingFrame`.
            lock.unlock()
            return
        }
        isDraining = true
        lock.unlock()
        deliveryQueue.async { [weak self] in self?.drainDelivery() }
    }

    /// Serially deliver the newest pending frame until the slot is empty. Only
    /// one `drainDelivery` runs at a time (guarded by `isDraining`), so the W4
    /// one-frame-at-a-time contract holds.
    private func drainDelivery() {
        while true {
            lock.lock()
            guard state == .running, let frame = pendingFrame else {
                isDraining = false
                lock.unlock()
                return
            }
            pendingFrame = nil
            lock.unlock()
            onFrame?(frame)
        }
    }

    func markFailed() {
        lock.lock(); defer { lock.unlock() }
        state = .failed
    }
}
