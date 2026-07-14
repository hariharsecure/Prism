import CoreMedia
import CoreVideo
import Metal
import XCTest

import PrismCompose
import PrismCompositor
import PrismCore
import PrismVirtualCam

/// Stage O — HDR sink parity for the **virtual camera** and the **vertical (9:16)
/// program**. (The streaming/replay encoder is covered by `StreamHDRParityTests`.)
///
/// Before this stage (sol #4 finding #6) only the main recording was
/// HDR-configured: the virtual camera advertised only 8-bit BGRA/420v, and the
/// vertical program's compositor was always built SDR, so a 9:16 program + its
/// recording stayed SDR H.264 while the primary program was 10-bit HDR.
///
/// CONFIGURATION-verified (advertised format list / compositor color mode).
/// A real HDR client negotiating the 10-bit vcam format and a real HDR display
/// are UNVERIFIED-until-hardware.
final class HDRSinkParityTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        return d
    }

    // MARK: - Virtual camera advertises a 10-bit HDR format

    func testVCamAdvertisesTenBitHDRFormat() {
        let formats = PrismVCamConstants.advertisedPixelFormats
        // Pre-fix the list was only [BGRA, 420v] — no 10-bit format existed.
        XCTAssertTrue(formats.contains(PrismVCamConstants.pixelFormat10bit),
                      "vcam must advertise a 10-bit HDR format for parity")
        XCTAssertEqual(PrismVCamConstants.pixelFormat10bit, kCVPixelFormatType_ARGB2101010LEPacked,
                       "the 10-bit format must match the compositor's HDR program output")
        // The 8-bit formats are still advertised (SDR clients unchanged).
        XCTAssertTrue(formats.contains(PrismVCamConstants.pixelFormatBGRA))
        XCTAssertTrue(formats.contains(PrismVCamConstants.pixelFormat420v))
    }

    /// Every advertised format must yield a valid `CMVideoFormatDescription` at
    /// the vcam canvas — this is exactly the per-format construction the
    /// extension does at init, so a 10-bit entry that can't build would break it.
    func testEveryAdvertisedFormatBuildsAFormatDescription() {
        for codec in PrismVCamConstants.advertisedPixelFormats {
            var desc: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, codecType: codec,
                width: Int32(PrismVCamConstants.width), height: Int32(PrismVCamConstants.height),
                extensions: nil, formatDescriptionOut: &desc)
            XCTAssertEqual(status, noErr, "format \(codec) failed to build")
            XCTAssertNotNil(desc)
        }
    }

    // MARK: - Vertical program composites in HDR

    func testVerticalProgramBuildsInHDRColorMode() throws {
        let device = try device()
        // SDR default (unchanged behavior).
        let sdr = try DualProgram(device: device, width: 1080, height: 1920, colorMode: .sdr)
        XCTAssertEqual(sdr.colorMode, .sdr, "default vertical program must stay SDR")
        // HDR: the vertical compositor now shares the primary's Rec.2020/HLG space.
        let hdr = try DualProgram(device: device, width: 1080, height: 1920, colorMode: .hdr)
        XCTAssertEqual(hdr.colorMode, .hdr, "vertical program must build in HDR when requested")
    }

    func testSecondaryCompositionHDRColorModePropagates() throws {
        let device = try device()
        let secondary = try SecondaryComposition(device: device, width: 1080, height: 1920, colorMode: .hdr)
        XCTAssertEqual(secondary.colorMode, .hdr)
        XCTAssertEqual(secondary.compositor.colorMode, .hdr,
                       "the vertical compositor itself must be HDR (10-bit working space)")
        // Default stays SDR.
        let def = try SecondaryComposition(device: device, width: 1080, height: 1920)
        XCTAssertEqual(def.colorMode, .sdr)
    }

    /// An HDR vertical program emits a 10-bit HDR-tagged program frame (the same
    /// output-format contract as the primary), so a vertical recorder tags it HDR.
    func testHDRVerticalProgramEmitsTenBitTaggedFrame() throws {
        let device = try device()
        let dual = try DualProgram(device: device, width: 360, height: 640, colorMode: .hdr)
        let got = XCTestExpectation(description: "vertical frame")
        let box = FormatBox()
        dual.onSecondaryFrame = { frame in box.set(frame.pixelFormat); got.fulfill() }

        // Feed a single source frame + a trivial scene, submit one tick.
        let pool = try PixelBufferPool(width: 320, height: 240, pixelFormat: kCVPixelFormatType_32BGRA)
        let src = SourceID("test.vert")
        let buf = try pool.makeBuffer()
        let frame = VideoFrame(pixelBuffer: buf, pts: CMTime(value: 0, timescale: 60),
                               duration: CMTime(value: 1, timescale: 60), source: src)
        dual.scene = Scene(name: "t", layers: [Layer(sourceID: src, frame: CGRect(x: 0, y: 0, width: 1, height: 1))])
        dual.submit(frames: [src: frame],
                    scene: dual.scene,
                    reframe: ReframeMap(),
                    pts: CMTime(value: 0, timescale: 60),
                    duration: CMTime(value: 1, timescale: 60))
        _ = XCTWaiter().wait(for: [got], timeout: 3.0)
        guard let fmt = box.getFormat() else { throw XCTSkip("no vertical frame produced on this host") }
        XCTAssertEqual(fmt, kCVPixelFormatType_ARGB2101010LEPacked,
                       "HDR vertical program frame must be 10-bit (was BGRA8 / SDR)")
    }

    private final class FormatBox: @unchecked Sendable {
        private let lock = NSLock()
        private var fmt: OSType?
        func set(_ v: OSType) { lock.lock(); if fmt == nil { fmt = v }; lock.unlock() }
        func getFormat() -> OSType? { lock.lock(); defer { lock.unlock() }; return fmt }
    }
}
