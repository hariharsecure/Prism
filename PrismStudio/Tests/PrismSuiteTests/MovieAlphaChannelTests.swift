import AVFoundation
import CoreVideo
import Foundation
import Metal
import XCTest

import PrismCompositor
import PrismCore
import PrismSources

/// Class C (Transparency): an ordinary (non-meme) movie whose codec carries alpha
/// (ProRes 4444) must be recognised as alpha-bearing so the App marks its scene
/// layer premultiplied — otherwise the compositor forces its sampled alpha to 1
/// and a transparent pixel composites as opaque black over the layers beneath.
///
/// Independent oracle: the fixtures are ENCODED with a known codec (ProRes 4444
/// vs H.264), and `hasAlphaChannel` is derived from the decoded track's format
/// description — a different code path from the encoder that wrote it.
final class MovieAlphaChannelTests: XCTestCase {

    func testProRes4444ClipReportsAlpha() throws {
        let url = try writeClip(codec: .proRes4444, pixelFormat: kCVPixelFormatType_32BGRA)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try MovieSource(fileURL: url, canvasSize: .hd, contentMode: .aspectFit, loop: false)
        XCTAssertTrue(source.hasAlphaChannel,
                      "ProRes 4444 clip was NOT recognised as alpha-bearing → its layer would flatten to opaque black")
    }

    func testH264ClipReportsNoAlpha() throws {
        let url = try writeClip(codec: .h264, pixelFormat: kCVPixelFormatType_32BGRA)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try MovieSource(fileURL: url, canvasSize: .hd, contentMode: .aspectFit, loop: false)
        XCTAssertFalse(source.hasAlphaChannel,
                       "an opaque H.264 clip must NOT be flagged alpha-bearing (would waste a premultiplied composite)")
    }

    // MARK: - F17: REAL alpha-video-over-color composite (not flags-only)

    /// Raw (premultiplied) BGRA bytes at a pixel.
    private func rawBGRA(_ buf: CVPixelBuffer, x: Int, y: Int) -> (b: Int, g: Int, r: Int, a: Int) {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let p = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self) + y * bpr + x * 4
        return (Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3]))
    }

    /// Decode the FIRST frame of a clip to a real BGRA `CVPixelBuffer` via
    /// `AVAssetReader` (the exact settings `MovieSource` uses — alpha preserved).
    /// This is a genuine ProRes 4444 *decode*, not a synthesized frame.
    private func decodeFirstFrame(_ url: URL) throws -> CVPixelBuffer {
        let asset = AVURLAsset(url: url)
        let sem = DispatchSemaphore(value: 0)
        var loadedTrack: AVAssetTrack?
        asset.loadTracks(withMediaType: .video) { tracks, _ in loadedTrack = tracks?.first; sem.signal() }
        _ = sem.wait(timeout: .now() + 10)
        guard let track = loadedTrack else { throw XCTSkip("no video track") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ])
        guard reader.canAdd(output) else { throw XCTSkip("reader cannot add BGRA output") }
        reader.add(output)
        guard reader.startReading() else { throw XCTSkip("reader refused to start (\(String(describing: reader.error)))") }
        guard let sample = output.copyNextSampleBuffer(),
              let pb = CMSampleBufferGetImageBuffer(sample) else {
            throw XCTSkip("no decoded frame (\(String(describing: reader.error)))")
        }
        return pb
    }

    /// F17 (REAL composite, Class C) — a transparent-region ProRes 4444 clip
    /// composited over a SOLID LOWER COLOR layer through the real `MetalCompositor`
    /// must let the lower color show through the transparent surround, and show the
    /// opaque box over it — not paint an opaque-black rectangle.
    ///
    /// This is NOT a flags-only check (`hasAlphaChannel` above): it decodes real
    /// ProRes 4444 pixels and drives the live two-layer GPU composite. The fixture
    /// has only fully-opaque (box) and fully-transparent (surround) regions, so
    /// premultiplied vs straight alpha is identical there — sidestepping the
    /// premult ambiguity while still exercising a real decoded alpha frame. Samples
    /// are taken deep inside the corners / box center (away from DCT-ringing edges).
    /// Independent oracle: the LOWER layer's known solid color (hand-derived), and
    /// the fixture's known opaque-box RGB — neither comes from the composite path.
    func testProRes4444CompositesLowerColorThroughTransparentRegion() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let url = try writeClip(codec: .proRes4444, pixelFormat: kCVPixelFormatType_32BGRA)
        defer { try? FileManager.default.removeItem(at: url) }

        let alphaFrameBuf = try decodeFirstFrame(url)   // real ProRes 4444 → BGRA (alpha preserved)
        let W = CVPixelBufferGetWidth(alphaFrameBuf), H = CVPixelBufferGetHeight(alphaFrameBuf)

        // Sanity: the decoded frame really carries alpha — a corner is transparent
        // and the center is opaque. (If the decode dropped alpha this fails loudly.)
        let cornerA = rawBGRA(alphaFrameBuf, x: 2, y: 2).a
        let centerPx = rawBGRA(alphaFrameBuf, x: W / 2, y: H / 2)
        XCTAssertLessThan(cornerA, 40, "decoded ProRes 4444 surround must be transparent (got a=\(cornerA))")
        XCTAssertGreaterThan(centerPx.a, 210, "decoded ProRes 4444 box must be opaque (got a=\(centerPx.a))")

        // Lower layer: a distinct solid blue-green the alpha layer must reveal.
        let compositor = try MetalCompositor(device: device, width: W, height: H)
        let canvas = try FXCanvas(width: W, height: H)
        let lower = RGBA(r: 0.10, g: 0.70, b: 0.35)
        let expB = Int((0.35 * 255).rounded()), expG = Int((0.70 * 255).rounded()), expR = Int((0.10 * 255).rounded())

        let bgID = SourceID("f17.lower"), topID = SourceID("f17.prores")
        let scene = Scene(name: "f17", layers: [
            Layer(sourceID: bgID, zIndex: 0),
            Layer(sourceID: topID, zIndex: 1, premultipliedAlpha: true),
        ])
        let program = try compositor.composite(
            frames: [
                bgID: VideoFrame(pixelBuffer: try canvas.solid(lower), pts: HouseClock.now(), source: bgID),
                topID: VideoFrame(pixelBuffer: alphaFrameBuf, pts: HouseClock.now(), source: topID),
            ],
            scene: scene, pts: HouseClock.now())

        // Transparent corners → the LOWER color shows through (never opaque black).
        for (name, x, y) in [("TL", 3, 3), ("TR", W - 4, 3), ("BL", 3, H - 4), ("BR", W - 4, H - 4)] {
            let px = rawBGRA(program.pixelBuffer, x: x, y: y)
            XCTAssertFalse(px.b < 12 && px.g < 12 && px.r < 12,
                "F17 \(name) (\(px.b),\(px.g),\(px.r)) is black — alpha video blacked out the transparent surround")
            XCTAssertLessThanOrEqual(abs(px.b - expB), 24, "F17 \(name) B should reveal the lower layer, got \(px)")
            XCTAssertLessThanOrEqual(abs(px.g - expG), 24, "F17 \(name) G should reveal the lower layer, got \(px)")
            XCTAssertLessThanOrEqual(abs(px.r - expR), 24, "F17 \(name) R should reveal the lower layer, got \(px)")
        }

        // Opaque box center → the ProRes source's red-ish box over the lower layer
        // (fixture wrote B=40 G=40 R=220; ProRes 4444 is near-lossless).
        let mid = rawBGRA(program.pixelBuffer, x: W / 2, y: H / 2)
        XCTAssertGreaterThan(mid.r, 170, "F17 center must show the opaque ProRes box (red), got \(mid)")
        XCTAssertLessThan(mid.b, 80, "F17 center must be the box (low blue), got \(mid)")
    }

    // MARK: fixture writer

    /// Write a tiny 2-frame clip with the given codec, returning its URL.
    private func writeClip(codec: AVVideoCodecType, pixelFormat: OSType) throws -> URL {
        let w = 64, h = 64
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alpha.\(UUID().uuidString).mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            throw XCTSkip("could not create AVAssetWriter")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ])
        guard writer.canAdd(input) else { throw XCTSkip("codec \(codec.rawValue) unavailable on this host") }
        writer.add(input)
        guard writer.startWriting() else { throw XCTSkip("writer refused to start (\(String(describing: writer.error)))") }
        writer.startSession(atSourceTime: .zero)

        for i in 0..<2 {
            var pbOut: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess,
                  let pb = pbOut else { throw XCTSkip("no pixel buffer pool") }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let bpr = CVPixelBufferGetBytesPerRow(pb)
                let ptr = base.assumingMemoryBound(to: UInt8.self)
                // A centered opaque box on a (premultiplied) transparent surround —
                // real spatially-varying content with an alpha edge.
                for y in 0..<h {
                    for x in 0..<w {
                        let inside = x >= 16 && x < 48 && y >= 16 && y < 48
                        let p = ptr + y * bpr + x * 4
                        if inside { p[0] = 40; p[1] = 40; p[2] = 220; p[3] = 255 }   // opaque red-ish
                        else { p[0] = 0; p[1] = 0; p[2] = 0; p[3] = 0 }              // clear
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        let done = XCTestExpectation(description: "write")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 10)
        guard writer.status == .completed else {
            throw XCTSkip("clip write failed: \(String(describing: writer.error))")
        }
        return url
    }
}
