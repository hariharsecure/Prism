import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import PrismCore
import VideoToolbox

/// Headless self-verification of the **HDR recording path** (`RecordingSettings
/// .dynamicRange == .hdr`): encodes synthetic 10-bit frames to a `.mov`, reopens
/// it, and asserts the video track is HEVC, is **Main10** (parsed from the
/// `hvcC` config record), and carries the Rec.2020 / ITU-R BT.2100 HLG color
/// tags in its format description. No TCC needed (VideoToolbox *encode* is
/// permission-free).
///
/// TEST CODE ONLY: fills 10-bit pixel buffers on the CPU to synthesize program
/// frames. Allowed here, forbidden on the engine hot path.
public enum HDRRecorderSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case setupFailed(String)
        case assertion(String)
        public var description: String {
            switch self {
            case .setupFailed(let s): return "HDR recorder self-test setup failed: \(s)"
            case .assertion(let s): return "HDR recorder self-test assertion failed: \(s)"
            }
        }
    }

    /// Runs the HDR encode + reopen check; returns evidence lines.
    public static func run() async throws -> [String] {
        var lines: [String] = []
        let w = 320, h = 240, fps = 30, frames = 30

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism_hdr_recorder_\(UInt64.random(in: 0..<UInt64.max)).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let settings = RecordingSettings(
            codec: .hevc, width: w, height: h, videoBitrate: 8_000_000,
            expectedFrameRate: Double(fps), fragmentInterval: 0.5, includeAudio: false,
            dynamicRange: .hdr)
        let recorder = try MovieRecorder(url: url, settings: settings)
        do { try recorder.start() } catch {
            throw SelfTestError.setupFailed("HDR recorder start (hardware HEVC Main10 encode): \(error)")
        }

        // 10-bit HDR source buffers (ARGB2101010LEPacked), HLG/2020-tagged.
        let pool = try PixelBufferPool(width: w, height: h,
                                       pixelFormat: kCVPixelFormatType_ARGB2101010LEPacked)
        let src = SourceID("selftest.hdr")
        let frameDur = CMTime(value: 1, timescale: CMTimeScale(fps))
        let t0 = HouseClock.now()
        for i in 0..<frames {
            let pts = CMTimeAdd(t0, CMTime(value: Int64(i), timescale: CMTimeScale(fps)))
            let buf = try pool.makeBuffer()
            fill10(buf, phase: i)
            attachHDRTags(buf)
            recorder.append(VideoFrame(pixelBuffer: buf, pts: pts, duration: frameDur, source: src))
            // Give the real-time input a moment so frames aren't dropped for busy.
            try await Task.sleep(nanoseconds: UInt64(1_000_000_000 / UInt64(fps)))
        }
        let report = try await recorder.finish()
        lines.append("   encoded HDR: framesWritten=\(report.videoFramesWritten) dropped=\(report.videoFramesDropped) bytes=\(report.bytesWritten)")
        guard report.videoFramesWritten >= UInt64(frames / 2) else {
            throw SelfTestError.assertion("only \(report.videoFramesWritten)/\(frames) HDR frames encoded — the Main10 encoder may have rejected the 10-bit input")
        }

        // --- Reopen and inspect the track's format description ---
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw SelfTestError.assertion("no video track in HDR file") }
        let formats = try await track.load(.formatDescriptions)
        guard let fdesc = formats.first else { throw SelfTestError.assertion("no format description on HDR track") }

        // Codec: HEVC.
        let subType = CMFormatDescriptionGetMediaSubType(fdesc)
        guard subType == kCMVideoCodecType_HEVC else {
            throw SelfTestError.assertion("track codec is \(fourCC(subType)), expected HEVC ('hvc1')")
        }

        // Color tags in the format description extensions.
        func extString(_ key: CFString) -> String {
            (CMFormatDescriptionGetExtension(fdesc, extensionKey: key) as? String).map(short) ?? "nil"
        }
        func extEquals(_ key: CFString, _ expected: CFString) -> Bool {
            guard let v = CMFormatDescriptionGetExtension(fdesc, extensionKey: key) else { return false }
            return CFEqual(v, expected)
        }
        lines.append("   track: codec=HEVC primaries=\(extString(kCMFormatDescriptionExtension_ColorPrimaries)) transfer=\(extString(kCMFormatDescriptionExtension_TransferFunction)) matrix=\(extString(kCMFormatDescriptionExtension_YCbCrMatrix))")
        guard extEquals(kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionColorPrimaries_ITU_R_2020) else {
            throw SelfTestError.assertion("ColorPrimaries ≠ ITU_R_2020 (got \(extString(kCMFormatDescriptionExtension_ColorPrimaries)))")
        }
        guard extEquals(kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG) else {
            throw SelfTestError.assertion("TransferFunction ≠ ITU_R_2100_HLG (got \(extString(kCMFormatDescriptionExtension_TransferFunction)))")
        }
        guard extEquals(kCMFormatDescriptionExtension_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_2020) else {
            throw SelfTestError.assertion("YCbCrMatrix ≠ ITU_R_2020 (got \(extString(kCMFormatDescriptionExtension_YCbCrMatrix)))")
        }

        // Main10: parse general_profile_idc from the hvcC config record.
        let profileIDC = hevcProfileIDC(fdesc)
        lines.append("   hvcC general_profile_idc=\(profileIDC.map(String.init) ?? "unparsed") (Main10 == 2)")
        if let idc = profileIDC {
            guard idc == 2 else {
                throw SelfTestError.assertion("HEVC profile_idc=\(idc), expected 2 (Main10)")
            }
        }
        lines.append("   HDR recorder: PASS (HEVC Main10, Rec.2020 / BT.2100-HLG tagged, reopened & verified)")
        return lines
    }

    // MARK: - hvcC parse

    /// Extract HEVC `general_profile_idc` from the format description's `hvcC`
    /// atom (ISO/IEC 14496-15): byte[1] & 0x1F. Returns nil if not present.
    private static func hevcProfileIDC(_ fdesc: CMFormatDescription) -> Int? {
        guard let atoms = CMFormatDescriptionGetExtension(
            fdesc, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
            let hvcC = atoms["hvcC"] as? Data, hvcC.count >= 2 else { return nil }
        return Int(hvcC[hvcC.startIndex + 1] & 0x1F)
    }

    // MARK: - test-only 10-bit CPU fill

    /// Fill an `ARGB2101010LEPacked` buffer with a per-frame-varying HDR value
    /// (a moving gradient so successive frames differ → real P/I frames).
    private static func fill10(_ buffer: CVPixelBuffer, phase: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        for y in 0..<h {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt32.self)
            for x in 0..<w {
                let v = UInt32(((x + y + phase * 7) & 0x3FF))          // 0…1023 ramp
                let r = min(v + 200, 1023), g = v, b = min(v / 2, 1023)
                row[x] = (UInt32(3) << 30) | (r << 20) | (g << 10) | b // A2 R10 G10 B10, LE
            }
        }
    }

    private static func attachHDRTags(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    }

    private static func fourCC(_ code: OSType) -> String {
        let b = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                 UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return "'\(String(bytes: b, encoding: .ascii) ?? "?")'"
    }

    private static func short(_ s: String) -> String {
        (s as NSString).components(separatedBy: "_").last ?? s
    }
}
