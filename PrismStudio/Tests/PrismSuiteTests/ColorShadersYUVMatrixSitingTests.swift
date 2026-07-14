import CoreMedia
import CoreVideo
import Metal
import XCTest

import PrismColor
import PrismCore

/// sol #3 finding 1 — the PrismColor kernels (`ColorShaders.yuv_to_rgb`) hardcoded
/// centered BT.709 for the grade, statistics, relight, chroma-key and luma-key
/// YUV pre-passes. So a BT.601 / BT.2020 (or left-sited) tagged source run through
/// ANY of those took a hue shift + half-pixel chroma misalignment the downstream
/// BGRA could not repair (sol: an identity grade turned a tagged full-range 601 red
/// from (254,0,0) into (255,25,0)).
///
/// Oracle is INDEPENDENT: the YCbCr→RGB inverse is re-derived from the ITU luma
/// weights (Kr/Kb), NOT copied from the shader coefficients. Fixtures are
/// spatially varying where siting matters (Class A / Class I).
final class ColorShadersYUVMatrixSitingTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    // MARK: - fixtures / oracle

    private func makeYUV(w: Int, h: Int, matrix: CFString, leftSited: Bool,
                         lumaAt: (Int, Int) -> UInt8,
                         chromaAt: (Int, Int) -> (UInt8, UInt8)) throws -> VideoFrame {
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        var pb: CVPixelBuffer?
        let st = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                     kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                     attrs as CFDictionary, &pb)
        guard st == kCVReturnSuccess, let buffer = pb else { throw XCTSkip("no biplanar buffer (\(st))") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let lb = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lbpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<h { for x in 0..<w { lb[y * lbpr + x] = lumaAt(x, y) } }
        let cb = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let cbpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for cy in 0..<(h / 2) { for cx in 0..<(w / 2) {
            let (cbv, crv) = chromaAt(cx, cy)
            cb[cy * cbpr + cx * 2 + 0] = cbv
            cb[cy * cbpr + cx * 2 + 1] = crv
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        if leftSited {
            CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey,
                                  kCVImageBufferChromaLocation_Left, .shouldPropagate)
        }
        return VideoFrame(pixelBuffer: buffer, pts: HouseClock.now(), source: SourceID("yuv"))
    }

    /// Independent full-range YCbCr→RGB, inverse RE-DERIVED from Kr/Kb.
    private func oracleRGB(y: UInt8, cb: UInt8, cr: UInt8, kr: Double, kb: Double) -> (r: Int, g: Int, b: Int) {
        let kg = 1 - kr - kb
        let yf = Double(y) / 255.0
        let cbf = Double(cb) / 255.0 - 0.5
        let crf = Double(cr) / 255.0 - 0.5
        let r = yf + 2 * (1 - kr) * crf
        let b = yf + 2 * (1 - kb) * cbf
        let g = (yf - kr * r - kb * b) / kg
        func q(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return (q(r), q(g), q(b))
    }

    private func readBGRA(_ buf: CVPixelBuffer, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(buf)!
            .advanced(by: y * CVPixelBufferGetBytesPerRow(buf) + x * 4)
            .assumingMemoryBound(to: UInt8.self)
        return (Int(p[2]), Int(p[1]), Int(p[0]))
    }

    // A solid-color 420f fixture (siting-invariant) for the matrix checks.
    private func solid(w: Int, h: Int, y: UInt8, cb: UInt8, cr: UInt8, matrix: CFString) throws -> VideoFrame {
        try makeYUV(w: w, h: h, matrix: matrix, leftSited: false,
                    lumaAt: { _, _ in y }, chromaAt: { _, _ in (cb, cr) })
    }

    private let kr601 = 0.299, kb601 = 0.114
    private let kr709 = 0.2126, kb709 = 0.0722
    private let kr2020 = 0.2627, kb2020 = 0.0593

    // A saturated-red-ish sample: high Cr, low Cb.
    private let yR: UInt8 = 130, cbR: UInt8 = 90, crR: UInt8 = 230

    // MARK: - grade

    func testGradeIdentityHonorsMatrix() throws {
        let w = 32, h = 32
        let proc = try ColorProcessor(device: try device())
        func gradedCenter(_ matrix: CFString) throws -> (r: Int, g: Int, b: Int) {
            let f = try solid(w: w, h: h, y: yR, cb: cbR, cr: crR, matrix: matrix)
            let out = try proc.process(f, grade: .identity, lut: nil)
            return readBGRA(out.pixelBuffer, x: w / 2, y: h / 2)
        }
        let got601 = try gradedCenter(kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        let got709 = try gradedCenter(kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        let got2020 = try gradedCenter(kCVImageBufferYCbCrMatrix_ITU_R_2020)

        let want601 = oracleRGB(y: yR, cb: cbR, cr: crR, kr: kr601, kb: kb601)
        let want2020 = oracleRGB(y: yR, cb: cbR, cr: crR, kr: kr2020, kb: kb2020)
        let want709 = oracleRGB(y: yR, cb: cbR, cr: crR, kr: kr709, kb: kb709)

        XCTAssertLessThanOrEqual(abs(got601.r - want601.r), 3, "grade 601 R \(got601) vs \(want601)")
        XCTAssertLessThanOrEqual(abs(got601.g - want601.g), 3, "grade 601 G \(got601) vs \(want601)")
        XCTAssertLessThanOrEqual(abs(got601.b - want601.b), 3, "grade 601 B \(got601) vs \(want601)")
        XCTAssertLessThanOrEqual(abs(got2020.g - want2020.g), 3, "grade 2020 G \(got2020) vs \(want2020)")
        // Untagged/709 unchanged.
        XCTAssertLessThanOrEqual(abs(got709.g - want709.g), 3, "grade 709 G \(got709) vs \(want709)")
        // 601 and 709 must differ (matrix honored, not hardcoded).
        let diff = abs(got601.g - got709.g) + abs(got601.b - got709.b)
        XCTAssertGreaterThan(diff, 4, "grade decoded 601 and 709 identically (\(got601) vs \(got709))")
    }

    func testGradeUntaggedStays709() throws {
        let w = 16, h = 16
        let proc = try ColorProcessor(device: try device())
        // No YCbCrMatrix attachment at all → must default to 709.
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        var pb: CVPixelBuffer?
        _ = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                attrs as CFDictionary, &pb)
        let buffer = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let lb = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lbpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<h { for x in 0..<w { lb[y * lbpr + x] = yR } }
        let cbP = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let cbpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for cy in 0..<(h / 2) { for cx in 0..<(w / 2) {
            cbP[cy * cbpr + cx * 2 + 0] = cbR; cbP[cy * cbpr + cx * 2 + 1] = crR
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let f = VideoFrame(pixelBuffer: buffer, pts: HouseClock.now(), source: SourceID("u"))
        let out = try proc.process(f, grade: .identity, lut: nil)
        let got = readBGRA(out.pixelBuffer, x: w / 2, y: h / 2)
        let want = oracleRGB(y: yR, cb: cbR, cr: crR, kr: kr709, kb: kb709)
        XCTAssertLessThanOrEqual(abs(got.r - want.r) + abs(got.g - want.g) + abs(got.b - want.b), 6,
                                 "untagged grade \(got) not 709 \(want)")
    }

    // MARK: - stats (shares sample_yuv)

    func testStatsHonorsMatrix() throws {
        let w = 64, h = 64
        let analyzer = try FrameAnalyzer(device: try device())
        let s601 = try analyzer.analyze(try solid(w: w, h: h, y: yR, cb: cbR, cr: crR,
                                                  matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4))
        let s709 = try analyzer.analyze(try solid(w: w, h: h, y: yR, cb: cbR, cr: crR,
                                                  matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2))
        let want601 = oracleRGB(y: yR, cb: cbR, cr: crR, kr: kr601, kb: kb601)
        XCTAssertLessThanOrEqual(abs(s601.meanR - Double(want601.r) / 255.0), 0.02,
                                 "stats 601 meanR \(s601.meanR) vs \(Double(want601.r) / 255.0)")
        XCTAssertLessThanOrEqual(abs(s601.meanG - Double(want601.g) / 255.0), 0.02,
                                 "stats 601 meanG \(s601.meanG) vs \(Double(want601.g) / 255.0)")
        XCTAssertGreaterThan(abs(s601.meanG - s709.meanG), 0.015,
                             "stats decoded 601 and 709 identically (matrix ignored)")
    }

    // MARK: - relight (ambient 1, no lights → identity decode; shares sample_yuv)

    func testRelightHonorsMatrix() throws {
        let w = 32, h = 32
        let relight = try RelightProcessor(device: try device())
        relight.ambient = 1
        // Flat depth so normals are (0,0,-1) and no lights → out ≈ decoded base.
        let depthPool = try PixelBufferPool(width: w, height: h,
                                            pixelFormat: kCVPixelFormatType_OneComponent8, minimumBufferCount: 1)
        let depth = try depthPool.makeBuffer()
        CVPixelBufferLockBaseAddress(depth, [])
        let db = CVPixelBufferGetBaseAddress(depth)!.assumingMemoryBound(to: UInt8.self)
        let dr = CVPixelBufferGetBytesPerRow(depth)
        for y in 0..<h { memset(db + y * dr, 128, w) }
        CVPixelBufferUnlockBaseAddress(depth, [])

        func lit(_ matrix: CFString) throws -> (r: Int, g: Int, b: Int) {
            let f = try solid(w: w, h: h, y: yR, cb: cbR, cr: crR, matrix: matrix)
            let out = try relight.process(frame: f, depth: depth, lights: [])
            return readBGRA(out.pixelBuffer, x: w / 2, y: h / 2)
        }
        let got601 = try lit(kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        let got709 = try lit(kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        let want601 = oracleRGB(y: yR, cb: cbR, cr: crR, kr: kr601, kb: kb601)
        XCTAssertLessThanOrEqual(abs(got601.g - want601.g), 4, "relight 601 G \(got601) vs \(want601)")
        XCTAssertGreaterThan(abs(got601.g - got709.g) + abs(got601.b - got709.b), 4,
                             "relight decoded 601 and 709 identically")
    }

    // MARK: - chroma key (spill 0, key far → alpha 1 → premultiplied decode)

    func testChromaKeyHonorsMatrix() throws {
        let w = 32, h = 32
        let keyer = try ChromaKeyProcessor(device: try device())
        // Key on blue, far from the red-ish sample, no spill and tiny similarity so
        // the foreground alpha is 1 and the output rgb is the decoded color.
        let key = ChromaKey(keyColor: SIMD3(0, 0, 1), similarity: 0.02, smoothness: 0.02, spillStrength: 0)
        func keyed(_ matrix: CFString) throws -> (r: Int, g: Int, b: Int) {
            let f = try solid(w: w, h: h, y: yR, cb: cbR, cr: crR, matrix: matrix)
            let out = try keyer.apply(frame: f, key: key)
            return readBGRA(out.pixelBuffer, x: w / 2, y: h / 2)
        }
        let got601 = try keyed(kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        let got709 = try keyed(kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        let want601 = oracleRGB(y: yR, cb: cbR, cr: crR, kr: kr601, kb: kb601)
        XCTAssertLessThanOrEqual(abs(got601.r - want601.r), 4, "chromakey 601 R \(got601) vs \(want601)")
        XCTAssertGreaterThan(abs(got601.g - got709.g) + abs(got601.b - got709.b), 3,
                             "chromakey decoded 601 and 709 identically")
    }

    // MARK: - luma key (band excludes pixel → alpha 1 → premultiplied decode)

    func testLumaKeyHonorsMatrix() throws {
        let w = 32, h = 32
        let keyer = try LumaKeyProcessor(device: try device())
        // Key a bright band [0.9,1.0]; the sample's luma is well below it → kept (α=1).
        let key = LumaKey(lowLuma: 0.9, highLuma: 1.0, smoothness: 0.01, invert: false)
        func keyed(_ matrix: CFString) throws -> (r: Int, g: Int, b: Int) {
            let f = try solid(w: w, h: h, y: yR, cb: cbR, cr: crR, matrix: matrix)
            let out = try keyer.apply(frame: f, key: key)
            return readBGRA(out.pixelBuffer, x: w / 2, y: h / 2)
        }
        let got601 = try keyed(kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        let got709 = try keyed(kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        let want601 = oracleRGB(y: yR, cb: cbR, cr: crR, kr: kr601, kb: kb601)
        XCTAssertLessThanOrEqual(abs(got601.r - want601.r), 4, "lumakey 601 R \(got601) vs \(want601)")
        XCTAssertGreaterThan(abs(got601.g - got709.g) + abs(got601.b - got709.b), 3,
                             "lumakey decoded 601 and 709 identically")
    }

    // MARK: - grade left-siting (horizontal Cr ramp → red shifts by siting oracle)

    func testGradeLeftSitingShiftsChroma() throws {
        let w = 16, h = 8
        let proc = try ColorProcessor(device: try device())
        let step = 30.0, base = 20.0
        func luma(_ x: Int, _ y: Int) -> UInt8 { 180 }
        func chroma(_ cx: Int, _ cy: Int) -> (UInt8, UInt8) {
            (128, UInt8(min(max(base + Double(cx) * step, 0), 255)))
        }
        let centered = try makeYUV(w: w, h: h, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                                   leftSited: false, lumaAt: luma, chromaAt: chroma)
        let left = try makeYUV(w: w, h: h, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                               leftSited: true, lumaAt: luma, chromaAt: chroma)
        let pc = try proc.process(centered, grade: .identity, lut: nil)
        let pl = try proc.process(left, grade: .identity, lut: nil)
        let px = 8, py = h / 2
        let rc = readBGRA(pc.pixelBuffer, x: px, y: py).r
        let rl = readBGRA(pl.pixelBuffer, x: px, y: py).r
        XCTAssertGreaterThan(rl - rc, 5, "grade left siting did not shift chroma right (ΔR=\(rl - rc))")
    }
}
