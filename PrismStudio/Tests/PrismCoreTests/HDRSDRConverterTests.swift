import CoreVideo
import Foundation
import XCTest

@testable import PrismCore

/// Independent-oracle tests for the shared HDR↔SDR colour converter (sol #6 #4/#5).
///
/// The expected values are re-derived here from the published spec math (a SECOND
/// implementation of the sRGB / HLG transfers + the BT.709↔BT.2020 primary
/// matrices) — NOT by calling `HDRSDRConverter` — so a bug in the converter and
/// its oracle cannot move together (Bible Class I). The load-bearing anchors
/// (neutral sRGB 128 ↔ HLG code 726) are also hard-asserted as spec constants.
final class HDRSDRConverterTests: XCTestCase {

    // MARK: - Independent spec oracle (distinct code path from the converter)

    private func oSrgbEOTF(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    private func oSrgbOETF(_ v: Double) -> Double {
        let x = max(0, v)
        return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1.0 / 2.4) - 0.055
    }
    private func oHlgOETF(_ e: Double) -> Double {
        let a = 0.17883277, b = 0.28466892, c = 0.55991073
        let x = max(0, min(1, e))
        return x <= 1.0 / 12.0 ? sqrt(3 * x) : a * log(12 * x - b) + c
    }
    private func oHlgInvOETF(_ s: Double) -> Double {
        let a = 0.17883277, b = 0.28466892, c = 0.55991073
        let x = max(0, min(1, s))
        return x <= 0.5 ? (x * x) / 3 : (exp((x - c) / a) + b) / 12
    }
    private func oToneMap(_ x: Double) -> Double {
        let v = max(0, x), k = 0.8
        return v <= k ? v : k + (1 - k) * tanh((v - k) / (1 - k))
    }
    // Neutral axis: both primary matrices have rows summing to 1, so an equal
    // (r,g,b) is unchanged — the oracle for the gray tests uses that directly.

    private func oExpectedSDRFromSRGBGray(_ code8: Int) -> Int {
        // sRGB code → linear → (2020 identity on gray) → HLG code → back down.
        let lin = oSrgbEOTF(Double(code8) / 255.0)
        let hlgCode = (oHlgOETF(lin) * 1023.0).rounded()
        let sig = hlgCode / 1023.0
        let scene = oHlgInvOETF(sig)
        let toned = oToneMap(scene)
        return Int((oSrgbOETF(toned) * 255.0).rounded())
    }

    private func oExpectedHLGCodeFromSRGBGray(_ code8: Int) -> Int {
        let lin = oSrgbEOTF(Double(code8) / 255.0)
        return Int((oHlgOETF(lin) * 1023.0).rounded())
    }

    // MARK: - Scalar oracle anchors

    func testNeutralSRGB128MapsToHLG726() {
        let (r, g, b) = HDRSDRConverter.srgb8ToHLG2020Code(r8: 128, g8: 128, b8: 128)
        XCTAssertEqual(r, 726); XCTAssertEqual(g, 726); XCTAssertEqual(b, 726)
        XCTAssertEqual(oExpectedHLGCodeFromSRGBGray(128), 726) // independent oracle agrees
    }

    func testNeutralHLG726MapsToSRGB128() {
        let (r, g, b) = HDRSDRConverter.hlg2020CodeToSRGB8(r10: 726, g10: 726, b10: 726)
        XCTAssertEqual(Int(r), 128); XCTAssertEqual(Int(g), 128); XCTAssertEqual(Int(b), 128)
        XCTAssertEqual(oExpectedSDRFromSRGBGray(128), 128) // 128 → 726 → 128
    }

    /// The pre-fix `VTPixelTransferSession` / relabel behaviour is a NEGATIVE
    /// control: a pure bit-depth scale of 128 → 10-bit is 128/255*1023 ≈ 514, and
    /// a pure scale of HLG 726 → 8-bit is 726/1023*255 ≈ 181. The real converter
    /// must NOT produce those (they are the "only relabelled" bug).
    func testConverterIsNotABitDepthRelabel() {
        let (r10, _, _) = HDRSDRConverter.srgb8ToHLG2020Code(r8: 128, g8: 128, b8: 128)
        XCTAssertNotEqual(Int(r10), 514)
        XCTAssertEqual(Int(r10), 726)
        let (r8, _, _) = HDRSDRConverter.hlg2020CodeToSRGB8(r10: 726, g10: 726, b10: 726)
        XCTAssertNotEqual(Int(r8), 181); XCTAssertNotEqual(Int(r8), 182)
        XCTAssertEqual(Int(r8), 128)
    }

    /// SDR→HDR→SDR round-trips the mid/low range EXACTLY (±1), and always matches
    /// the independent spec oracle across the FULL range. Highlights above the
    /// tone-map knee are covered separately (`testHighlightRollsOff`).
    func testGrayRoundTripThroughHLG() {
        for code in stride(from: 0, through: 255, by: 17) {
            let (r10, g10, b10) = HDRSDRConverter.srgb8ToHLG2020Code(r8: UInt8(code), g8: UInt8(code), b8: UInt8(code))
            XCTAssertEqual(Int(r10), oExpectedHLGCodeFromSRGBGray(code), accuracy: 1, "fwd \(code)")
            let (r8, _, _) = HDRSDRConverter.hlg2020CodeToSRGB8(r10: r10, g10: g10, b10: b10)
            XCTAssertEqual(Int(r8), oExpectedSDRFromSRGBGray(code), accuracy: 1, "oracle \(code)")
            if code <= 204 { // below the tone-map knee → exact round-trip
                XCTAssertEqual(Int(r8), code, accuracy: 1, "round-trip \(code)")
            }
        }
    }

    /// Above the knee, the highlight tone-map compresses toward (but never past)
    /// white — a near-peak gray comes back DARKER than a naive identity would give,
    /// which is the point (highlight roll-off, not hard clip).
    func testHighlightRollsOff() {
        let (r10, g10, b10) = HDRSDRConverter.srgb8ToHLG2020Code(r8: 255, g8: 255, b8: 255)
        let (r8, _, _) = HDRSDRConverter.hlg2020CodeToSRGB8(r10: r10, g10: g10, b10: b10)
        XCTAssertLessThan(Int(r8), 255)                          // rolled off
        XCTAssertGreaterThan(Int(r8), 240)                       // but still near-white
        XCTAssertEqual(Int(r8), oExpectedSDRFromSRGBGray(255))   // matches the spec oracle
    }

    /// A saturated pure-2020 HLG value (out of the Rec.709 gamut) tone-maps into a
    /// valid 8-bit code without overflow/underflow — the highlight/gamut roll-off.
    func testWideGamutHighlightStaysInRange() {
        // Peak red in Rec.2020 (code 1023,0,0): 2020→709 pushes G,B negative and R
        // >1; the converter must clamp/roll to [0,255] with no wraparound.
        let (r8, g8, b8) = HDRSDRConverter.hlg2020CodeToSRGB8(r10: 1023, g10: 0, b10: 0)
        XCTAssertGreaterThan(Int(r8), 200)              // still a bright red
        XCTAssertLessThanOrEqual(Int(r8), 255)
        XCTAssertGreaterThanOrEqual(Int(g8), 0); XCTAssertLessThan(Int(g8), 128)
        XCTAssertGreaterThanOrEqual(Int(b8), 0); XCTAssertLessThan(Int(b8), 128)
    }

    // MARK: - Buffer-level conversions + tags

    private func makeTenBit(fillCode: UInt32, size: Int = 16) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: size, height: size,
                                       pixelFormat: kCVPixelFormatType_ARGB2101010LEPacked, minimumBufferCount: 1)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<size {
            let r = base.advanced(by: row * bpr).assumingMemoryBound(to: UInt32.self)
            for col in 0..<size { r[col] = (UInt32(3) << 30) | (fillCode << 20) | (fillCode << 10) | fillCode }
        }
        return buf
    }

    private func makeBGRA(fill: UInt8, size: Int = 16) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: size, height: size,
                                       pixelFormat: kCVPixelFormatType_32BGRA, minimumBufferCount: 1)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<size { for col in 0..<size {
            let p = row * bpr + col * 4
            base[p] = fill; base[p + 1] = fill; base[p + 2] = fill; base[p + 3] = 255
        } }
        return buf
    }

    func testBufferHDRToSDRDecodesNeutralAndTagsSRGB() throws {
        let hdr = try makeTenBit(fillCode: 726)
        let pool = try PixelBufferPool(width: 16, height: 16,
                                       pixelFormat: kCVPixelFormatType_32BGRA, minimumBufferCount: 1)
        let sdr = try HDRSDRConverter.convertHDRToSDR_BGRA(from: hdr, pool: pool)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(sdr), kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(sdr, .readOnly)
        let base = CVPixelBufferGetBaseAddress(sdr)!.assumingMemoryBound(to: UInt8.self)
        let g = Int(base[1]) // green byte at pixel 0
        CVPixelBufferUnlockBaseAddress(sdr, .readOnly)
        XCTAssertEqual(g, 128, accuracy: 1)          // NOT the relabel value 182
        XCTAssertEqual(YCbCrTags.transferCode(for: sdr), 3)   // sRGB
        XCTAssertEqual(YCbCrTags.primariesRotationCode(for: sdr), 1) // 709
    }

    func testBufferSDRToHDREncodesNeutralAndTagsHLG() throws {
        let sdr = try makeBGRA(fill: 128)
        let pool = try PixelBufferPool(width: 16, height: 16,
                                       pixelFormat: kCVPixelFormatType_ARGB2101010LEPacked, minimumBufferCount: 1)
        let hdr = try HDRSDRConverter.convertSDRToHDR_10bit(from: sdr, pool: pool)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(hdr), kCVPixelFormatType_ARGB2101010LEPacked)
        CVPixelBufferLockBaseAddress(hdr, .readOnly)
        let word = CVPixelBufferGetBaseAddress(hdr)!.assumingMemoryBound(to: UInt32.self)[0]
        CVPixelBufferUnlockBaseAddress(hdr, .readOnly)
        let g10 = Int((word >> 10) & 0x3FF)
        XCTAssertEqual(g10, 726, accuracy: 1)        // NOT the relabel value 514
        XCTAssertEqual(YCbCrTags.transferCode(for: hdr), 1)   // HLG
        XCTAssertTrue(YCbCrTags.isRec2020(for: hdr))
    }

    // MARK: - Spatially-varying fixtures (Bible Class I / F11: a constant plane
    // hides every per-channel + packing/ordering bug — vary every pixel).

    /// A 10-bit `ARGB2101010LEPacked` buffer whose r/g/b codes each vary across the
    /// frame (distinct per channel, spanning low → peak → wide-gamut).
    private func makeTenBitVarying(width: Int, height: Int) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: width, height: height,
                                       pixelFormat: kCVPixelFormatType_ARGB2101010LEPacked, minimumBufferCount: 1)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<height {
            let r = base.advanced(by: row * bpr).assumingMemoryBound(to: UInt32.self)
            for col in 0..<width {
                let r10 = UInt32((col * 1023) / max(width - 1, 1))                 // 0…1023 across x
                let g10 = UInt32((row * 1023) / max(height - 1, 1))               // 0…1023 across y
                let b10 = UInt32(((col + row) * 1023) / max(width + height - 2, 1)) // diagonal
                r[col] = (UInt32(3) << 30) | (r10 << 20) | (g10 << 10) | b10
            }
        }
        return buf
    }

    /// An 8-bit BGRA buffer whose channels each vary across the frame.
    private func makeBGRAVarying(width: Int, height: Int) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: width, height: height,
                                       pixelFormat: kCVPixelFormatType_32BGRA, minimumBufferCount: 1)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<height { for col in 0..<width {
            let p = row * bpr + col * 4
            base[p]     = UInt8((col * 255) / max(width - 1, 1))     // B across x
            base[p + 1] = UInt8((row * 255) / max(height - 1, 1))    // G across y
            base[p + 2] = UInt8(((col + row) * 255) / max(width + height - 2, 1)) // R diagonal
            base[p + 3] = 255
        } }
        return buf
    }

    private func maxByteDiff(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
        let sa = CVPixelBufferGetBytesPerRow(a), sb = CVPixelBufferGetBytesPerRow(b)
        let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
        let pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        var worst = 0
        for row in 0..<h { for col in 0..<(w * 4) {
            worst = max(worst, abs(Int(pa[row * sa + col]) - Int(pb[row * sb + col])))
        } }
        return worst
    }

    /// The GPU HDR→SDR output must match the scalar CPU reference on a
    /// spatially-varying colour fixture (proves the Metal packing/channel-order +
    /// tone-map/gamut math reproduce the CPU intent, not just on the neutral axis).
    func testGPUMatchesCPU_HDRToSDR_varying() throws {
        try XCTSkipUnless(HDRSDRConverter.isGPUAccelerated, "no Metal device — CPU-only host")
        let w = 96, h = 72
        let src = try makeTenBitVarying(width: w, height: h)
        let gpu = try HDRSDRConverter.convertHDRToSDR_BGRA(
            from: src, pool: PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_32BGRA, minimumBufferCount: 1))
        let cpu = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_32BGRA, minimumBufferCount: 1).makeBuffer()
        try HDRSDRConverter.convertHDRToSDR_BGRA_cpu(from: src, into: cpu)
        XCTAssertLessThanOrEqual(maxByteDiff(gpu, cpu), 2, "GPU vs CPU HDR→SDR diverged")
    }

    /// The GPU SDR→HDR output must match the scalar CPU reference on a varying
    /// colour fixture (10-bit code packing, per channel).
    func testGPUMatchesCPU_SDRToHDR_varying() throws {
        try XCTSkipUnless(HDRSDRConverter.isGPUAccelerated, "no Metal device — CPU-only host")
        let w = 96, h = 72
        let src = try makeBGRAVarying(width: w, height: h)
        let gpu = try HDRSDRConverter.convertSDRToHDR_10bit(
            from: src, pool: PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_ARGB2101010LEPacked, minimumBufferCount: 1))
        let cpu = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_ARGB2101010LEPacked, minimumBufferCount: 1).makeBuffer()
        try HDRSDRConverter.convertSDRToHDR_10bit_cpu(from: src, into: cpu)
        // Compare per-channel 10-bit codes (±2) rather than raw bytes.
        CVPixelBufferLockBaseAddress(gpu, .readOnly); CVPixelBufferLockBaseAddress(cpu, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(gpu, .readOnly); CVPixelBufferUnlockBaseAddress(cpu, .readOnly) }
        let sg = CVPixelBufferGetBytesPerRow(gpu), sc = CVPixelBufferGetBytesPerRow(cpu)
        let pg = CVPixelBufferGetBaseAddress(gpu)!, pc = CVPixelBufferGetBaseAddress(cpu)!
        var worst = 0
        for row in 0..<h {
            let rg = pg.advanced(by: row * sg).assumingMemoryBound(to: UInt32.self)
            let rc = pc.advanced(by: row * sc).assumingMemoryBound(to: UInt32.self)
            for col in 0..<w {
                let a = rg[col], b = rc[col]
                for shift in [20, 10, 0] {
                    worst = max(worst, abs(Int((a >> UInt32(shift)) & 0x3FF) - Int((b >> UInt32(shift)) & 0x3FF)))
                }
            }
        }
        XCTAssertLessThanOrEqual(worst, 2, "GPU vs CPU SDR→HDR diverged")
    }

    // MARK: - Performance (sol #7): the GPU path is many-× faster than the scalar
    // CPU loop that collapsed cadence (~90 ms/frame HDR→SDR at 1080p).

    func testGPUConversionIsFastAt1080p() throws {
        try XCTSkipUnless(HDRSDRConverter.isGPUAccelerated, "no Metal device — CPU fallback env")
        let w = 1920, h = 1080
        let src = try makeTenBitVarying(width: w, height: h)
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_32BGRA, minimumBufferCount: 3)

        // Warm the pipeline (first dispatch pays one-time costs).
        _ = try HDRSDRConverter.convertHDRToSDR_BGRA(from: src, pool: pool)

        let iterations = 5
        var gpuStart = Date()
        for _ in 0..<iterations { _ = try HDRSDRConverter.convertHDRToSDR_BGRA(from: src, pool: pool) }
        let gpuMs = Date().timeIntervalSince(gpuStart) / Double(iterations) * 1000.0

        // Scalar CPU reference on the SAME workload (the path sol measured at ~90 ms).
        let cpuDst = try pool.makeBuffer()
        gpuStart = Date()
        try HDRSDRConverter.convertHDRToSDR_BGRA_cpu(from: src, into: cpuDst)
        let cpuMs = Date().timeIntervalSince(gpuStart) * 1000.0
        print("[HDRSDR perf] 1080p HDR→SDR — GPU \(String(format: "%.2f", gpuMs)) ms/frame, CPU \(String(format: "%.1f", cpuMs)) ms/frame, speed-up \(String(format: "%.0f", cpuMs / gpuMs))×")

        // Primary (robust) assertion: order-of-magnitude speed-up. The scalar path
        // FAILS the render cadence; the GPU path clears it by many ×.
        XCTAssertLessThan(gpuMs, cpuMs / 5.0, "GPU (\(gpuMs) ms) not ≫ faster than CPU (\(cpuMs) ms)")
        // Secondary (looser, env-tolerant) ceiling: the ~5 ms/frame target.
        XCTAssertLessThan(gpuMs, 15.0, "GPU 1080p conversion \(gpuMs) ms exceeds budget")
    }
}
