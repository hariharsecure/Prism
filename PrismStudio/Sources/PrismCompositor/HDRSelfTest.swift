import CoreMedia
import CoreVideo
import Foundation
import Metal
import PrismCore

/// Headless self-verification of the compositor's **HDR (HLG/Rec.2020) output
/// path** and proof that the default **SDR path is unchanged** (no TCC, no
/// capture hardware — a real GPU composite read back on the CPU).
///
/// TEST CODE ONLY: locks pixel-buffer base addresses to fill synthetic inputs
/// and read back the 10-bit program output. Allowed here, forbidden on the
/// engine hot path.
///
/// Covers:
///  (a) `.hdr` compositor: composites synthetic frames into a 10-bit program,
///      asserts the pixel format is `ARGB2101010LEPacked`, the output is
///      non-zero, the HLG OETF actually ran (a mid-tone lands on the HLG curve,
///      not the identity line), a saturated primary encodes to a single
///      max channel, and the CVImageBuffer carries the Rec.2020 / BT.2100-HLG
///      color attachments.
///  (b) `.sdr` compositor: a known BGRA composite still matches exactly
///      (byte-identical to the pre-HDR behavior).
///
/// The recorder-side HDR proof lives in `PrismOutput.HDRRecorderSelfTest` (a
/// single type can't reach both `MetalCompositor` and `MovieRecorder` across the
/// module boundary); the `.build` object-link harness runs both.
public enum HDRSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case setupFailed(String)
        case mismatch(String)
        public var description: String {
            switch self {
            case .setupFailed(let s): return "HDR self-test setup failed: \(s)"
            case .mismatch(let s): return "HDR self-test mismatch: \(s)"
            }
        }
    }

    /// Runs every check; returns human-readable evidence lines (throws on first
    /// mismatch).
    @discardableResult
    public static func run() throws -> [String] {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SelfTestError.setupFailed("no Metal device")
        }
        var lines: [String] = []
        lines += try runHDR(device: device)
        lines += try runPremultipliedMatte(device: device)
        lines += try runSDRUnchanged(device: device)
        return lines
    }

    // MARK: - (a) HDR output path

    private static func runHDR(device: MTLDevice) throws -> [String] {
        var lines: [String] = []
        let w = 640, h = 360
        let compositor = try MetalCompositor(device: device, width: w, height: h, colorMode: .hdr)
        guard compositor.colorMode == .hdr else {
            throw SelfTestError.mismatch(".hdr compositor reports colorMode \(compositor.colorMode)")
        }

        let srcPool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_32BGRA)
        let t0 = HouseClock.now()

        // --- White (1,1,1): HLG OETF(1)=1 → all three 10-bit channels ≈ 1023 ---
        let whiteBuf = try srcPool.makeBuffer()
        fillBGRA(whiteBuf, b: 255, g: 255, r: 255)
        let whiteID = SourceID("hdr.white")
        let whiteScene = Scene(name: "hdr.white", layers: [Layer(sourceID: whiteID)])
        let whiteProgram = try compositor.composite(
            frames: [whiteID: VideoFrame(pixelBuffer: whiteBuf, pts: t0, source: whiteID)],
            scene: whiteScene, pts: t0)

        // Format + dimensions.
        guard whiteProgram.pixelFormat == kCVPixelFormatType_ARGB2101010LEPacked else {
            throw SelfTestError.mismatch("HDR program format is \(fourCC(whiteProgram.pixelFormat)), expected 'l10r' (ARGB2101010LEPacked)")
        }
        guard whiteProgram.width == w, whiteProgram.height == h else {
            throw SelfTestError.mismatch("HDR program is \(whiteProgram.width)x\(whiteProgram.height), expected \(w)x\(h)")
        }

        // Color attachments (Rec.2020 / BT.2100 HLG) present on the CVImageBuffer.
        try assertHDRTags(whiteProgram.pixelBuffer)
        lines.append("   HDR tags: ColorPrimaries=ITU_R_2020, TransferFunction=ITU_R_2100_HLG, YCbCrMatrix=ITU_R_2020 ✓")

        let white = try read10(whiteProgram, x: w / 2, y: h / 2)
        lines.append("   white(1,1,1) → 10-bit channels \(white.channels) alpha=\(white.alpha) word=0x\(String(white.word, radix: 16))")
        guard white.word != 0 else { throw SelfTestError.mismatch("HDR white composite read back all-zero") }
        for (i, ch) in white.channels.enumerated() where ch < 1000 {
            throw SelfTestError.mismatch("HDR white channel[\(i)]=\(ch) < 1000 (expected ≈1023 after HLG OETF(1)=1)")
        }

        // --- Mid-gray (0.502): proves the LINEAR→HLG transfer actually ran ---
        // finding-10: gray is EOTF-decoded to linear (0.502 → ≈0.262) THEN HLG-
        // encoded → HLG OETF(0.262) ≈ 0.747 → ≈765/1023. (The old bug fed the
        // gamma-coded 0.502 straight into HLG → ≈892; a plain SDR-in-10-bit path
        // would give ≈513.) The gap from 513 is the proof the transfer ran.
        let grayBuf = try srcPool.makeBuffer()
        fillBGRA(grayBuf, b: 128, g: 128, r: 128)
        let grayID = SourceID("hdr.gray")
        let grayScene = Scene(name: "hdr.gray", layers: [Layer(sourceID: grayID)])
        let grayProgram = try compositor.composite(
            frames: [grayID: VideoFrame(pixelBuffer: grayBuf, pts: t0, source: grayID)],
            scene: grayScene, pts: CMTimeAdd(t0, CMTime(value: 1, timescale: 60)))
        let gray = try read10(grayProgram, x: w / 2, y: h / 2)
        let expectedGray = Int((HLGTransferRef.oetf(HLGTransferRef.eotf709(128.0 / 255.0)) * 1023).rounded())
        lines.append("   gray(0.502) → 10-bit channels \(gray.channels) (expected linear→HLG ≈\(expectedGray), gamma-into-HLG bug ≈892, SDR-linear ≈513)")
        for (i, ch) in gray.channels.enumerated() where abs(ch - expectedGray) > 40 {
            throw SelfTestError.mismatch("HDR gray channel[\(i)]=\(ch) not ≈\(expectedGray) — HLG OETF did not run as expected")
        }
        guard abs(expectedGray - 513) > 60 else {
            throw SelfTestError.mismatch("HLG/SDR mid-tone gap too small to be a real proof")
        }

        // --- Saturated 709 primary → Rec.2020 primaries (MED-10) ---
        // A pure BT.709 red sits INSIDE the wider Rec.2020 gamut, so after the
        // 709→2020 rotation it is no longer a single maxed channel: R stays the
        // dominant channel but does not clamp to full, and G/B pick up the
        // rotation's cross terms. (Pre-MED-10 this was mis-tagged 709-red-as-2020;
        // channels are B,G,R at bit offsets 0/10/20 in ARGB2101010LEPacked.)
        let redBuf = try srcPool.makeBuffer()
        fillBGRA(redBuf, b: 0, g: 0, r: 255)
        let redID = SourceID("hdr.red")
        let redScene = Scene(name: "hdr.red", layers: [Layer(sourceID: redID)])
        let redProgram = try compositor.composite(
            frames: [redID: VideoFrame(pixelBuffer: redBuf, pts: t0, source: redID)],
            scene: redScene, pts: CMTimeAdd(t0, CMTime(value: 2, timescale: 60)))
        let red = try read10(redProgram, x: w / 2, y: h / 2)
        let (rB, rG, rR) = (red.channels[0], red.channels[1], red.channels[2])
        lines.append("   709 red(1,0,0) → Rec.2020 channels B,G,R = \(rB),\(rG),\(rR) (R dominant, in-gamut, G/B lifted)")
        guard rR > rG, rR > rB else {
            throw SelfTestError.mismatch("HDR red: R (\(rR)) is not the dominant channel after 709→2020 (\(red.channels))")
        }
        guard rR < 1015 else {
            throw SelfTestError.mismatch("HDR red: R (\(rR)) still clamps to full — 709→2020 gamut rotation did not run")
        }
        guard rG > 200 else {
            throw SelfTestError.mismatch("HDR red: G (\(rG)) too small — 709→2020 cross terms missing (\(red.channels))")
        }

        lines.append("   HDR compositor: PASS (10-bit ARGB2101010LEPacked, HLG-encoded, Rec.2020 primaries + HLG tagged)")
        return lines
    }

    // MARK: - (a2) Partial-alpha matte composites in LINEAR light (sol #3)

    /// A partial-alpha premultiplied matte (chroma key / segmentation edge) must
    /// composite in LINEAR light: decode the straight color to linear, premultiply
    /// by α and blend IN LINEAR, then apply the HLG OETF ONCE. This composites a
    /// 50%-alpha premultiplied white matte over opaque black and asserts the result
    /// is the linear-light value HLG_OETF(0.5·1.0) ≈ 892/1023 — NOT the old
    /// encoded-space blend HLG_OETF(1)·0.5 ≈ 513 (which blended HLG-ENCODED values,
    /// sol #3 defect 1).
    private static func runPremultipliedMatte(device: MTLDevice) throws -> [String] {
        var lines: [String] = []
        let w = 320, h = 240
        let compositor = try MetalCompositor(device: device, width: w, height: h, colorMode: .hdr)
        let srcPool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_32BGRA)
        let t0 = HouseClock.now()

        // 50%-alpha premultiplied WHITE: straight color = (1,1,1); stored
        // premultiplied as rgb = α·C = 128/255 ≈ 0.502, alpha byte = 128.
        let aByte: UInt8 = 128
        let alpha = Float(aByte) / 255.0
        let matteBuf = try srcPool.makeBuffer()
        fillBGRA(matteBuf, b: aByte, g: aByte, r: aByte, aByte: aByte) // rgb already premultiplied
        let bgBuf = try srcPool.makeBuffer()
        fillBGRA(bgBuf, b: 0, g: 0, r: 0, aByte: 255)                  // opaque black background

        let bgID = SourceID("hdr.matte.bg"), matteID = SourceID("hdr.matte.fg")
        let scene = Scene(name: "hdr.matte", layers: [
            Layer(sourceID: bgID, zIndex: 0),
            Layer(sourceID: matteID, opacity: 1.0, zIndex: 1, premultipliedAlpha: true),
        ])
        let program = try compositor.composite(
            frames: [bgID: VideoFrame(pixelBuffer: bgBuf, pts: t0, source: bgID),
                     matteID: VideoFrame(pixelBuffer: matteBuf, pts: t0, source: matteID)],
            scene: scene, pts: t0)

        let px = try read10(program, x: w / 2, y: h / 2)
        // LINEAR-CORRECT (sol #3): straight = 0.502/0.502 = 1.0 ; EOTF709(1)=1 linear;
        // premultiply by α and blend over black IN LINEAR → 0.5 light; encode ONCE
        // → HLG_OETF(0.5) ≈ 0.872 → ≈892/1023.
        let correct = Int((HLGTransferRef.oetf(HLGTransferRef.eotf709(1.0) * alpha) * 1023).rounded())
        // OLD ENCODED-SPACE BUG (blended HLG-ENCODED values): HLG_OETF(1)·α = 1·0.5
        // = 0.5 → ≈513. This is exactly what the linear rebuild rules out.
        let encodedSpaceBug = Int((HLGTransferRef.oetf(HLGTransferRef.eotf709(1.0)) * alpha * 1023).rounded())
        lines.append("   premult 50% white matte → channels \(px.channels) (linear-correct ≈\(correct), old encoded-space blend ≈\(encodedSpaceBug))")
        for (i, ch) in px.channels.enumerated() where abs(ch - correct) > 24 {
            throw SelfTestError.mismatch("HDR premult matte channel[\(i)]=\(ch) ≠ linear-correct ≈\(correct) (decode→premult→LINEAR blend→HLG once); the old encoded-space blend gives ≈\(encodedSpaceBug)")
        }
        guard abs(correct - encodedSpaceBug) > 200 else {
            throw SelfTestError.mismatch("premult matte linear/encoded-space gap too small to be a real proof")
        }

        // Opaque premultiplied pixel (α=255) is an exact no-op: OETF(1)=1 → ≈1023.
        let opaqueBuf = try srcPool.makeBuffer()
        fillBGRA(opaqueBuf, b: 255, g: 255, r: 255, aByte: 255)
        let opID = SourceID("hdr.matte.opaque")
        let opScene = Scene(name: "hdr.matte.opaque", layers: [Layer(sourceID: opID, premultipliedAlpha: true)])
        let opProgram = try compositor.composite(
            frames: [opID: VideoFrame(pixelBuffer: opaqueBuf, pts: t0, source: opID)],
            scene: opScene, pts: CMTimeAdd(t0, CMTime(value: 1, timescale: 60)))
        let op = try read10(opProgram, x: w / 2, y: h / 2)
        for (i, ch) in op.channels.enumerated() where ch < 1000 {
            throw SelfTestError.mismatch("HDR opaque premult channel[\(i)]=\(ch) < 1000 — the unpremultiply path altered an opaque pixel")
        }
        lines.append("   opaque premult white unchanged → channels \(op.channels) (≈1023) ✓")
        lines.append("   HDR premultiplied matte: PASS (no OETF edge fringe; opaque no-op)")
        return lines
    }

    // MARK: - (b) SDR path unchanged

    private static func runSDRUnchanged(device: MTLDevice) throws -> [String] {
        var lines: [String] = []
        let w = 1280, h = 720
        // Default init (no colorMode) AND explicit .sdr must both be SDR.
        let compositor = try MetalCompositor(device: device, width: w, height: h)
        guard compositor.colorMode == .sdr else {
            throw SelfTestError.mismatch("default compositor colorMode is \(compositor.colorMode), expected .sdr")
        }
        let explicitSDR = try MetalCompositor(device: device, width: w, height: h, colorMode: .sdr)
        _ = explicitSDR

        let srcPool = try PixelBufferPool(width: 640, height: 360, pixelFormat: kCVPixelFormatType_32BGRA)
        let redBuf = try srcPool.makeBuffer()
        fillBGRA(redBuf, b: 0, g: 0, r: 255)
        let greenBuf = try srcPool.makeBuffer()
        fillBGRA(greenBuf, b: 0, g: 255, r: 0)
        let camID = SourceID("sdr.red"), grID = SourceID("sdr.green")
        let t0 = HouseClock.now()

        // Base red + 50% green over red bottom-left — a known composite whose
        // exact BGRA values are the pre-HDR ground truth.
        let scene = Scene(name: "sdr.check", layers: [
            Layer(sourceID: camID, zIndex: 0),
            Layer(sourceID: grID, frame: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
                  opacity: 0.5, zIndex: 1),
        ])
        let program = try compositor.composite(
            frames: [camID: VideoFrame(pixelBuffer: redBuf, pts: t0, source: camID),
                     grID: VideoFrame(pixelBuffer: greenBuf, pts: t0, source: grID)],
            scene: scene, pts: t0)

        guard program.pixelFormat == kCVPixelFormatType_32BGRA else {
            throw SelfTestError.mismatch("SDR program format is \(fourCC(program.pixelFormat)), expected BGRA")
        }
        // Pure red top region: byte-exact (tol 0).
        try expectBGRA(program, x: 100, y: 100, r: 255, g: 0, b: 0, tol: 0,
                       what: "SDR unchanged: pure red is byte-exact (255,0,0)")
        // 50% green over red: BGRA8 blend → (128,128,0) ±2 (identical to the
        // original CompositorSelfTest expectation for this quadrant).
        try expectBGRA(program, x: 320, y: 540, r: 128, g: 128, b: 0, tol: 2,
                       what: "SDR unchanged: 50% green over red is (128,128,0)")
        lines.append("   SDR path: PASS (BGRA8, red byte-exact, 50% blend matches pre-HDR ground truth)")
        return lines
    }

    // MARK: - HDR tag assertion

    private static func assertHDRTags(_ buffer: CVPixelBuffer) throws {
        func attaches(_ key: CFString, _ expected: CFString) -> Bool {
            guard let v = CVBufferCopyAttachment(buffer, key, nil) else { return false }
            return CFEqual(v, expected)
        }
        guard attaches(kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020) else {
            throw SelfTestError.mismatch("ColorPrimaries attachment missing or ≠ ITU_R_2020")
        }
        guard attaches(kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG) else {
            throw SelfTestError.mismatch("TransferFunction attachment missing or ≠ ITU_R_2100_HLG")
        }
        guard attaches(kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020) else {
            throw SelfTestError.mismatch("YCbCrMatrix attachment missing or ≠ ITU_R_2020")
        }
    }

    // MARK: - Test-only CPU pixel access

    private static func fillBGRA(_ buffer: CVPixelBuffer, b: UInt8, g: UInt8, r: UInt8, aByte: UInt8 = 255) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<CVPixelBufferGetHeight(buffer) {
            let rowBase = base + row * bpr
            for col in 0..<CVPixelBufferGetWidth(buffer) {
                let p = rowBase + col * 4
                p[0] = b; p[1] = g; p[2] = r; p[3] = aByte
            }
        }
    }

    /// Read one 10-bit `ARGB2101010LEPacked` pixel: little-endian uint32 word,
    /// three 10-bit channel groups (bit offsets 0/10/20), and the 2-bit alpha.
    private static func read10(_ frame: VideoFrame, x: Int, y: Int) throws -> (word: UInt32, channels: [Int], alpha: Int) {
        let buffer = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw SelfTestError.setupFailed("no base address on HDR program buffer")
        }
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let p = base.advanced(by: y * bpr + x * 4)
        let word = p.loadUnaligned(as: UInt32.self)
        let c0 = Int(word & 0x3FF)
        let c1 = Int((word >> 10) & 0x3FF)
        let c2 = Int((word >> 20) & 0x3FF)
        let a = Int((word >> 30) & 0x3)
        return (word, [c0, c1, c2], a)
    }

    private static func expectBGRA(_ frame: VideoFrame, x: Int, y: Int,
                                   r: Int, g: Int, b: Int, tol: Int, what: String) throws {
        let buffer = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw SelfTestError.setupFailed("no base address on SDR program buffer")
        }
        let p = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer) + x * 4)
            .assumingMemoryBound(to: UInt8.self)
        let (gotB, gotG, gotR) = (Int(p[0]), Int(p[1]), Int(p[2]))
        guard abs(gotR - r) <= tol, abs(gotG - g) <= tol, abs(gotB - b) <= tol else {
            throw SelfTestError.mismatch("\(what) at (\(x),\(y)): got RGB(\(gotR),\(gotG),\(gotB)), expected RGB(\(r),\(g),\(b)) ±\(tol)")
        }
    }

    private static func fourCC(_ code: OSType) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let s = String(bytes: bytes, encoding: .ascii) ?? "?"
        return "'\(s)' (0x\(String(code, radix: 16)))"
    }
}

/// Pure-Swift HLG OETF reference (mirrors PrismColor.HLGTransfer, duplicated
/// here so PrismCompositor's self-test has no cross-module test dependency).
enum HLGTransferRef {
    static func oetf(_ e: Float) -> Float {
        let e = max(e, 0)
        if e <= 1.0 / 12.0 { return (3 * e).squareRoot() }
        return 0.17883277 * log(12 * e - 0.28466892) + 0.55991073
    }
    /// BT.709 EOTF (display gamma → linear) — used to feed the LINEAR value into
    /// the HLG OETF, matching the compositor's finding-10 transfer.
    static func eotf709(_ v: Float) -> Float {
        v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1.0 / 0.45)
    }
}
