import CoreMedia
import CoreVideo
import Foundation
import XCTest

import PrismCore
import PrismOutput
@testable import Prism

/// sol #6 #5: the classic-RTMP "SDR fallback" must CONVERT the HDR program to real
/// SDR pixels before the SDR H.264 encoder — not just select an SDR encoder and
/// feed it the unchanged 10-bit HLG program (whose decoded gray is 182 from HLG
/// 726, not SDR ~128). Decoded-pixel + negative-control, then the wiring gate.
@MainActor
final class HDRClassicRTMPSDRTests: XCTestCase {

    private func hdrProgramFrame(code: UInt32 = 726, size: Int = 32) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: size, height: size,
                                       pixelFormat: kCVPixelFormatType_ARGB2101010LEPacked, minimumBufferCount: 1)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<size {
            let r = base.advanced(by: row * bpr).assumingMemoryBound(to: UInt32.self)
            for col in 0..<size { r[col] = (UInt32(3) << 30) | (code << 20) | (code << 10) | code }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return VideoFrame(pixelBuffer: buf, pts: CMTime(value: 0, timescale: 60),
                          duration: CMTime(value: 1, timescale: 60), source: SourceID("test"))
    }

    private func sdrProgramFrame(fill: UInt8 = 128, size: Int = 32) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: size, height: size,
                                       pixelFormat: kCVPixelFormatType_32BGRA, minimumBufferCount: 1)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<size { for col in 0..<size {
            let p = row * bpr + col * 4
            base[p] = fill; base[p + 1] = fill; base[p + 2] = fill; base[p + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return VideoFrame(pixelBuffer: buf, pts: .zero, duration: .invalid, source: SourceID("test"))
    }

    private func green(_ frame: VideoFrame) -> Int {
        CVPixelBufferLockBaseAddress(frame.pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, .readOnly) }
        return Int(CVPixelBufferGetBaseAddress(frame.pixelBuffer)!.assumingMemoryBound(to: UInt8.self)[1])
    }

    /// The frame the SDR stream encoder actually receives is real SDR (~128), not
    /// the HLG program relabelled to 8-bit (~182).
    func testClassicRTMPStreamFrameIsRealSDRNot182() throws {
        let fanOut = ProgramFanOut()
        let hdr = try hdrProgramFrame(code: 726)

        // Negative control: a naive bit-depth relabel of HLG 726 → 8-bit is 181/182 —
        // exactly what an SDR encoder fed the raw program would decode.
        let relabel = Int((726.0 / 1023.0 * 255.0).rounded())
        XCTAssertTrue(relabel == 181 || relabel == 182, "relabel anchor \(relabel)")

        let sdr = try XCTUnwrap(fanOut.convertProgramToSDR(hdr))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(sdr.pixelBuffer), kCVPixelFormatType_32BGRA)
        XCTAssertEqual(green(sdr), 128, accuracy: 2)          // real SDR
        XCTAssertNotEqual(green(sdr), relabel)                // NOT the relabel
        XCTAssertEqual(YCbCrTags.transferCode(for: sdr.pixelBuffer), 3)   // sRGB-tagged
    }

    /// An already-SDR program frame is never "converted" (nil → the caller feeds it
    /// straight through). Only a real 10-bit HDR program is converted.
    func testSDRProgramIsNotConverted() throws {
        let fanOut = ProgramFanOut()
        XCTAssertNil(fanOut.convertProgramToSDR(try sdrProgramFrame()))
    }

    /// sol #7 #3/#5 — STREAM STARTUP ATOMICITY. The pre-fix arm installed the SDR
    /// encoder (`setStreamEncoder`) BEFORE enabling the HDR→SDR conversion
    /// (`setStreamSDRFromHDR`); a render tick landing in that inter-call gap fed the SDR
    /// encoder the RAW 10-bit HDR program frame (decoded ~182). `armStreamEncoder` sets
    /// both under ONE lock hold, so the encoder is never visible without its conversion.
    /// Drives the REAL `handle()` path and inspects the exact frame handed to the encoder.
    func testHDRFrameNeverFedRawToSDREncoderDuringArm() throws {
        let hdr = try hdrProgramFrame(code: 726)
        let encoder = ProgramEncoder(settings: .init(codec: .h264, width: hdr.width, height: hdr.height,
                                                     dynamicRange: .sdr))   // never started; encode is a no-op

        /// The pixel format of the frame the stream encoder is actually handed when a
        /// render tick fires at `armPoint`, armed either atomically (the fix) or via the
        /// pre-fix two-call order (encoder first, conversion second).
        func formatFedToEncoder(atomic: Bool) -> OSType? {
            let fanOut = ProgramFanOut()
            var fed: OSType?
            fanOut._test_onStreamEncode = { fed = CVPixelBufferGetPixelFormatType($0.pixelBuffer) }
            if atomic {
                fanOut.armStreamEncoder(encoder, sdrFromHDR: true)   // encoder + convert together
                fanOut.handle(hdr)
            } else {
                fanOut.setStreamEncoder(encoder)                     // pre-fix: encoder first…
                fanOut.handle(hdr)                                   // …a tick lands in the gap
                fanOut.setStreamSDRFromHDR(true)                     // …conversion armed too late
            }
            return fed
        }

        // NEGATIVE CONTROL: the pre-fix two-call order leaks the RAW 10-bit HDR frame to
        // the SDR encoder during startup.
        XCTAssertEqual(formatFedToEncoder(atomic: false), kCVPixelFormatType_ARGB2101010LEPacked,
                       "negative control vacuous: no raw HDR frame leaked even with the pre-fix arm order")
        // FIX: the atomic arm only ever feeds a converted SDR (BGRA) frame — no leak.
        XCTAssertEqual(formatFedToEncoder(atomic: true), kCVPixelFormatType_32BGRA,
                       "#3/#5: a raw 10-bit HDR frame reached the SDR encoder during stream startup")

        // The armed steady state is unchanged: encoder installed AND conversion on, together.
        let fresh = ProgramFanOut()
        fresh.armStreamEncoder(encoder, sdrFromHDR: true)
        XCTAssertTrue(fresh._test_armState.encoderInstalled && fresh._test_armState.convertEnabled,
                      "#3/#5: atomic arm must expose the encoder and the conversion together")
    }

    /// Wiring gate: an HDR show with ANY classic-RTMP target streams SDR (→ convert),
    /// while an all-SRT HDR show keeps true HDR (→ no convert). `streamUsesHDR`
    /// returns false ⇔ the SDR conversion is engaged.
    func testHDRToSDRConversionEngagedOnlyForClassicRTMP() {
        let srt = Destination(name: "srt", proto: .srt, url: "srt://h:1", key: "")
        let rtmp = Destination(name: "rtmp", proto: .rtmp, url: "rtmp://h/app", key: "k")

        // HDR + a primary RTMP → SDR stream → convert.
        XCTAssertFalse(AppEngine.streamUsesHDR(hdrEnabled: true, hasPrimaryRTMP: true, destinations: []))
        // HDR + an RTMP destination → SDR stream → convert.
        XCTAssertFalse(AppEngine.streamUsesHDR(hdrEnabled: true, hasPrimaryRTMP: false, destinations: [rtmp]))
        // HDR + only SRT → TRUE HDR → no convert.
        XCTAssertTrue(AppEngine.streamUsesHDR(hdrEnabled: true, hasPrimaryRTMP: false, destinations: [srt]))
        // SDR show → never HDR, never converts.
        XCTAssertFalse(AppEngine.streamUsesHDR(hdrEnabled: false, hasPrimaryRTMP: false, destinations: [srt]))
    }
}
