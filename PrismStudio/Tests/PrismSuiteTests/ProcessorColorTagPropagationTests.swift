import CoreMedia
import CoreVideo
import Metal
import XCTest

import PrismColor
import PrismCompositor
import PrismCore
import PrismSources

/// sol #4 finding 1 — the PrismColor processors (`ColorProcessor`,
/// `ChromaKeyProcessor`, `LumaKeyProcessor`, `RelightProcessor`) and the
/// `PresenterCutout` CPU recovery path minted FRESH BGRA output buffers WITHOUT
/// propagating the source's colorimetry tags (`CVImageBufferColorPrimaries` /
/// `YCbCrMatrix` / `TransferFunction`). A tagged Rec.2020 / HLG source run
/// through any of them therefore emerged UNTAGGED, so the downstream HDR
/// compositor's `sourceIsRec2020` read FALSE and rotated 709→2020 a SECOND time
/// — a tagged 2020/HLG red came out desaturated (sol's real GPU probe: a
/// 2020/HLG → ChromaKey → HDR pixel measured RGB10 (946,675,525) untagged vs the
/// correct (1023,313,237)-class value when tags propagate).
///
/// FIX (mirrors wave-4 SourceEffectGPU / BackgroundEffect): each processor calls
/// `YCbCrTags.propagateColorTags(from:to:)` onto its output buffer.
///
/// ── INDEPENDENCE OF THE ORACLE ──────────────────────────────────────────────
/// Expected HDR values are re-derived HERE in Double from the published BT.709
/// EOTF, the Rec.709→2020 primary matrix and the BT.2100 HLG OETF — never by
/// calling the shader. A saturated red (1,0,0) is chosen so the transfer choice
/// (HLG-inverse vs 709-EOTF) is a no-op on {0,1} and the test isolates the
/// PRIMARY-ROTATION defect: the correct 2020 red keeps a maxed R with near-zero
/// G/B; the double-rotated (untagged) bug lifts G/B substantially.
final class ProcessorColorTagPropagationTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    // MARK: - independent from-spec oracle

    private func eotf709(_ v: Double) -> Double { v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1.0 / 0.45) }
    private func hlgOETF(_ e: Double) -> Double {
        let e = max(e, 0)
        return e <= 1.0 / 12.0 ? (3 * e).squareRoot()
                               : 0.17883277 * log(12 * e - 0.28466892) + 0.55991073
    }
    private func sat(_ v: Double) -> Double { min(max(v, 0), 1) }
    private func code(_ v: Double) -> Int { Int((sat(v) * 1023).rounded()) }
    private func encodeRed(rotate: Bool) -> (b: Int, g: Int, r: Int) {
        var (r, g, b) = (eotf709(1), eotf709(0), eotf709(0))
        if rotate {
            (r, g, b) = (0.627404 * r + 0.329283 * g + 0.043313 * b,
                         0.069097 * r + 0.919540 * g + 0.011362 * b,
                         0.016391 * r + 0.088013 * g + 0.895595 * b)
        }
        func ch(_ v: Double) -> Int { code(hlgOETF(v)) }
        return (ch(b), ch(g), ch(r))
    }

    // MARK: - fixtures / probes

    /// A solid BGRA buffer tagged Rec.2020 / BT.2100-HLG / Rec.2020-matrix.
    private func makeTagged2020HLG(_ w: Int, _ h: Int, r: UInt8, g: UInt8, b: UInt8) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_32BGRA)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<h { for col in 0..<w {
            let p = base + row * bpr + col * 4
            p[0] = b; p[1] = g; p[2] = r; p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return buf
    }

    private func read10(_ buf: CVPixelBuffer, x: Int, y: Int) -> (b: Int, g: Int, r: Int) {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let word = CVPixelBufferGetBaseAddress(buf)!
            .advanced(by: y * CVPixelBufferGetBytesPerRow(buf) + x * 4)
            .loadUnaligned(as: UInt32.self)
        return (Int(word & 0x3FF), Int((word >> 10) & 0x3FF), Int((word >> 20) & 0x3FF))
    }

    private func fullMatte(_ w: Int, _ h: Int) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: w, height: h,
                                       pixelFormat: kCVPixelFormatType_OneComponent8, minimumBufferCount: 1)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<h { memset(base + y * row, 255, w) }
        return buf
    }

    private func hasPrimaries2020(_ buf: CVPixelBuffer) -> Bool {
        guard let raw = CVBufferCopyAttachment(buf, kCVImageBufferColorPrimariesKey, nil) else { return false }
        return CFEqual(raw as AnyObject, kCVImageBufferColorPrimaries_ITU_R_2020)
    }

    /// The processor output, fed through the HDR compositor, must keep 2020 tags
    /// and NOT be double-rotated (2020 red stays a maxed-R with near-zero G/B).
    private func assertPropagatedAndNotDoubleRotated(_ out: VideoFrame, w: Int, h: Int, _ label: String) throws {
        XCTAssertTrue(hasPrimaries2020(out.pixelBuffer), "\(label): output dropped ColorPrimaries==2020")
        XCTAssertTrue(YCbCrTags.isRec2020(for: out.pixelBuffer),
                      "\(label): output not seen as Rec.2020 downstream → would double-rotate")

        let compositor = try MetalCompositor(device: try device(), width: w, height: h, colorMode: .hdr)
        let sid = out.source
        let scene = Scene(name: "s", layers: [Layer(sourceID: sid, premultipliedAlpha: false)])
        let prog = try compositor.composite(frames: [sid: out], scene: scene, pts: HouseClock.now())
        XCTAssertEqual(prog.pixelFormat, kCVPixelFormatType_ARGB2101010LEPacked)
        let got = read10(prog.pixelBuffer, x: w / 2, y: h / 2)

        let correct = encodeRed(rotate: false)  // already 2020 → no rotation
        let buggy = encodeRed(rotate: true)      // the double-rotation bug
        XCTAssertGreaterThan(abs(correct.g - buggy.g), 200, "oracle discriminator weak (\(correct) vs \(buggy))")
        XCTAssertGreaterThanOrEqual(got.r, 1000, "\(label) red R \(got) not maxed (oracle \(correct))")
        XCTAssertLessThan(got.g, 300, "\(label) 2020 red green lifted — double-rotated (\(got), buggy oracle \(buggy))")
        XCTAssertLessThan(got.b, 300, "\(label) 2020 red blue lifted — double-rotated (\(got))")
    }

    // MARK: - the five processors

    func testColorProcessorPropagatesTags() throws {
        let w = 32, h = 32
        let proc = try ColorProcessor(device: try device())
        let src = try makeTagged2020HLG(w, h, r: 255, g: 0, b: 0)
        let out = try proc.process(VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("c")),
                                   grade: .identity, lut: nil)
        try assertPropagatedAndNotDoubleRotated(out, w: w, h: h, "ColorProcessor")
    }

    func testChromaKeyProcessorPropagatesTags() throws {
        let w = 32, h = 32
        let keyer = try ChromaKeyProcessor(device: try device())
        // Key on blue (far from red), tiny similarity, no spill → red kept opaque.
        let key = ChromaKey(keyColor: SIMD3(0, 0, 1), similarity: 0.02, smoothness: 0.02, spillStrength: 0)
        let src = try makeTagged2020HLG(w, h, r: 255, g: 0, b: 0)
        let out = try keyer.apply(frame: VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("ck")),
                                  key: key)
        try assertPropagatedAndNotDoubleRotated(out, w: w, h: h, "ChromaKeyProcessor")
    }

    func testLumaKeyProcessorPropagatesTags() throws {
        let w = 32, h = 32
        let keyer = try LumaKeyProcessor(device: try device())
        // Bright band [0.9,1.0]; red's luma (~0.21) is well below → kept (α=1).
        let key = LumaKey(lowLuma: 0.9, highLuma: 1.0, smoothness: 0.01, invert: false)
        let src = try makeTagged2020HLG(w, h, r: 255, g: 0, b: 0)
        let out = try keyer.apply(frame: VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("lk")),
                                  key: key)
        try assertPropagatedAndNotDoubleRotated(out, w: w, h: h, "LumaKeyProcessor")
    }

    func testRelightProcessorPropagatesTags() throws {
        let w = 32, h = 32
        let relight = try RelightProcessor(device: try device())
        relight.ambient = 1  // ambient 1 + no lights + flat depth → identity decode
        let depthPool = try PixelBufferPool(width: w, height: h,
                                            pixelFormat: kCVPixelFormatType_OneComponent8, minimumBufferCount: 1)
        let depth = try depthPool.makeBuffer()
        CVPixelBufferLockBaseAddress(depth, [])
        let db = CVPixelBufferGetBaseAddress(depth)!.assumingMemoryBound(to: UInt8.self)
        let dr = CVPixelBufferGetBytesPerRow(depth)
        for y in 0..<h { memset(db + y * dr, 128, w) }
        CVPixelBufferUnlockBaseAddress(depth, [])
        let src = try makeTagged2020HLG(w, h, r: 255, g: 0, b: 0)
        let out = try relight.process(frame: VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("rl")),
                                      depth: depth, lights: [])
        try assertPropagatedAndNotDoubleRotated(out, w: w, h: h, "RelightProcessor")
    }

    func testPresenterCutoutCPURecoveryPropagatesTags() throws {
        let w = 32, h = 32
        let cutout = PresenterCutout()
        let src = try makeTagged2020HLG(w, h, r: 255, g: 0, b: 0)
        let matte = try fullMatte(w, h)
        // Directly exercise the CPU recovery path (finding 1 site).
        let out = try cutout.cpuFallbackComposite(
            frame: VideoFrame(pixelBuffer: src, pts: HouseClock.now(), source: SourceID("pc")),
            matte: matte)
        try assertPropagatedAndNotDoubleRotated(out, w: w, h: h, "PresenterCutout CPU recovery")
    }
}
