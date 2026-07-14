import CoreMedia
import CoreVideo
import Foundation
import PrismCore
import VideoToolbox

/// Converts a program frame to the client-negotiated CMIO **active format**
/// before it is sent on the source stream.
///
/// sol #5 #6: the source stream advertises three formats (BGRA / 420v / l10r)
/// and a client picks one by index (`streamActiveFormatIndex`). The compositor's
/// program frame, however, is BGRA for an SDR show and 10-bit `l10r` for an HDR
/// show — independent of what the client negotiated. Sending the program buffer
/// untouched therefore violates CMIO's contract whenever the two disagree (e.g.
/// an HDR `l10r` program under a BGRA/420v negotiation, or an SDR BGRA program
/// under an `l10r` negotiation): the client is handed a buffer whose real pixel
/// format is not the one it selected. This converts (bit-depth + chroma) to the
/// negotiated format rather than mislabel; when the program already matches, it
/// passes the buffer through untouched (the common, zero-copy case).
///
/// Threading: the vcam consume loop is serial (self-rescheduling), so a single
/// `VTPixelTransferSession` + per-format pool cache is accessed one frame at a
/// time; a lock guards it defensively.
///
/// sol #6 #4: `VTPixelTransferSession` does bit-depth + chroma but NOT a transfer/
/// gamut conversion, so a cross-DYNAMIC-RANGE transfer (SDR BGRA/420v ↔ HDR
/// `l10r`) only RELABELS: sRGB 128 became 10-bit 514 still sRGB-tagged (truthful
/// HLG ≈726), HLG 726 became 8-bit 182 still HLG-tagged (truthful SDR ≈128). When
/// the program's dynamic range and the negotiated format's differ, we now do a
/// REAL colour conversion via the shared `HDRSDRConverter` so pixels AND tags are
/// truthful for the negotiated format; same-range conversions stay on the (correct)
/// `VTPixelTransferSession` path.
final class VCamFormatConverter {

    private let width: Int
    private let height: Int
    private let lock = NSLock()
    private var session: VTPixelTransferSession?
    private var pools: [OSType: PixelBufferPool] = [:]
    private var formatDescriptions: [OSType: CMVideoFormatDescription] = [:]

    init(width: Int = PrismVCamConstants.width, height: Int = PrismVCamConstants.height) {
        self.width = width
        self.height = height
    }

    /// Whether an advertised vcam format is the HDR (10-bit HLG/Rec.2020) one.
    private static func isHDR(_ format: OSType) -> Bool { format == PrismVCamConstants.pixelFormat10bit }

    /// Convert `src` to `targetFormat`. Returns `src` itself when it already is
    /// that format (passthrough); `nil` only on an unrecoverable transfer error.
    func convertPixelBuffer(_ src: CVPixelBuffer, to targetFormat: OSType) -> CVPixelBuffer? {
        let srcFormat = CVPixelBufferGetPixelFormatType(src)
        if srcFormat == targetFormat { return src }
        lock.lock()
        defer { lock.unlock() }

        let srcHDR = Self.isHDR(srcFormat)
        let dstHDR = Self.isHDR(targetFormat)
        // Same dynamic range (SDR↔SDR, i.e. BGRA↔420v): bit-depth/chroma only — the
        // VTPixelTransferSession path is correct.
        if srcHDR == dstHDR {
            return transferLocked(src, to: targetFormat)
        }
        // Cross dynamic range: REAL colour conversion via the shared converter.
        if srcHDR {
            // HDR l10r → SDR. Convert to BGRA (true SDR pixels + sRGB tags); if the
            // client negotiated 420v, transfer the SDR BGRA into 420v (same range).
            guard let bgraPool = poolLocked(for: PrismVCamConstants.pixelFormatBGRA),
                  let sdr = try? HDRSDRConverter.convertHDRToSDR_BGRA(from: src, pool: bgraPool)
            else { return nil }
            if targetFormat == PrismVCamConstants.pixelFormatBGRA { return sdr }
            return transferLocked(sdr, to: targetFormat)
        } else {
            // SDR → HDR l10r. Get the source as BGRA (transfer 420v→BGRA first if
            // needed), then colour-convert to true HLG/Rec.2020 10-bit + tags.
            let bgra: CVPixelBuffer
            if srcFormat == PrismVCamConstants.pixelFormatBGRA {
                bgra = src
            } else {
                guard let transferred = transferLocked(src, to: PrismVCamConstants.pixelFormatBGRA) else { return nil }
                bgra = transferred
            }
            guard let tenBitPool = poolLocked(for: PrismVCamConstants.pixelFormat10bit),
                  let hdr = try? HDRSDRConverter.convertSDRToHDR_10bit(from: bgra, pool: tenBitPool)
            else { return nil }
            return hdr
        }
    }

    /// Same-dynamic-range bit-depth/chroma transfer (caller holds `lock`).
    private func transferLocked(_ src: CVPixelBuffer, to targetFormat: OSType) -> CVPixelBuffer? {
        if CVPixelBufferGetPixelFormatType(src) == targetFormat { return src }
        guard let session = sessionLocked(), let pool = poolLocked(for: targetFormat) else { return nil }
        guard let dst = try? pool.makeBuffer() else { return nil }
        guard VTPixelTransferSessionTransferImage(session, from: src, to: dst) == noErr else { return nil }
        return dst
    }

    /// Produce a sample buffer whose format IS `targetFormat`, preserving the
    /// source timing. Passthrough (returns `src`) when the program buffer is
    /// already in the negotiated format; otherwise a freshly wrapped, converted
    /// buffer. `nil` only on failure (caller falls back to the original).
    func makeSampleBuffer(from src: CMSampleBuffer, targetFormat: OSType) -> CMSampleBuffer? {
        guard let image = CMSampleBufferGetImageBuffer(src) else { return nil }
        if CVPixelBufferGetPixelFormatType(image) == targetFormat { return src }
        guard let converted = convertPixelBuffer(image, to: targetFormat) else { return nil }

        let description: CMVideoFormatDescription
        lock.lock()
        if let cached = formatDescriptions[targetFormat],
           CMVideoFormatDescriptionMatchesImageBuffer(cached, imageBuffer: converted) {
            description = cached
            lock.unlock()
        } else {
            lock.unlock()
            var fresh: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: converted, formatDescriptionOut: &fresh
            ) == noErr, let fresh else { return nil }
            lock.lock(); formatDescriptions[targetFormat] = fresh; lock.unlock()
            description = fresh
        }

        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(src),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(src),
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(src)
        )
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: converted,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &out
        ) == noErr else { return nil }
        return out
    }

    // MARK: - Lazy resources (caller holds `lock`)

    private func sessionLocked() -> VTPixelTransferSession? {
        if let session { return session }
        var created: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault,
                                           pixelTransferSessionOut: &created) == noErr,
              let created else { return nil }
        VTSessionSetProperty(created, key: kVTPixelTransferPropertyKey_ScalingMode,
                             value: kVTScalingMode_Normal)
        session = created
        return created
    }

    private func poolLocked(for format: OSType) -> PixelBufferPool? {
        if let pool = pools[format] { return pool }
        guard let pool = try? PixelBufferPool(width: width, height: height,
                                              pixelFormat: format, minimumBufferCount: 3) else { return nil }
        pools[format] = pool
        return pool
    }
}
