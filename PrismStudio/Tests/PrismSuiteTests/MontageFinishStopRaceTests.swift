import AVFoundation
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import XCTest
import PrismCore
@testable import PrismSources

/// Final-hunt M3: a non-looping `MontageSource`'s natural `.finish` (on the
/// director queue) must NOT race an external `stop()` (on the lifecycle queue).
/// Pre-fix both paths did `timer=nil` + `teardownSlots()` unordered → a
/// DispatchSourceTimer over-release and a DOUBLE teardown, which double-stops the
/// embedded video clip and breaks the `movieStartCount == movieStopCount`
/// invariant (double `onMovieStop`). The fix routes `.finish` through the
/// lifecycle queue (serialized with `stop()`), so exactly one path tears down.
///
/// This test drives the real finish/stop seam: a short non-looping montage that
/// ends on its own while a background thread fires `stop()` at a jittered instant,
/// repeated many times. The clip lifecycle invariant must hold every trial.
final class MontageFinishStopRaceTests: XCTestCase {

    private var tmpDir: URL!
    private var imageURL: URL!
    private var clipURL: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_montage_race_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        imageURL = tmpDir.appendingPathComponent("still.png")
        clipURL = tmpDir.appendingPathComponent("clip.mov")
        try Self.writeSolidPNG(to: imageURL, w: 160, h: 90)
        try Self.writeMovingClip(to: clipURL, frames: 20, w: 160, h: 90, fps: 20)
    }

    override func tearDownWithError() throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
    }

    /// The finish/stop seam under concurrent pressure. Each trial: a 2-item
    /// non-looping montage ([video, image]) with a tiny interval runs to its
    /// natural finish while a background `stop()` fires after a jittered delay.
    func testFinishStopRacePreservesMovieLifecycle() throws {
        let trials = 40
        let items: [MontageSource.MontageItem] = [
            MontageSource.MontageItem(url: clipURL, kind: .video),
            MontageSource.MontageItem(url: imageURL, kind: .image),
        ]
        let canvas = CanvasSize(width: 160, height: 90)
        for trial in 0..<trials {
            let montage = try MontageSource(
                id: SourceID("race.\(trial)"),
                items: items,
                canvasSize: canvas,
                interval: 0.05,
                transition: .cut,
                kenBurns: false,
                shuffle: false,
                loop: false,
                fps: 30)

            let collector = FrameSink()
            montage.onFrame = { _ in collector.bump() }
            try montage.start()

            // Fire stop() from a background thread at a jittered instant that lands
            // near the montage's natural finish, maximizing the race window.
            let delayUs = UInt32.random(in: 20_000...140_000)
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                usleep(delayUs)
                montage.stop()
                done.signal()
            }
            _ = done.wait(timeout: .now() + 5)
            // Give any in-flight natural finish time to settle, then stop() again
            // (must be idempotent and must not double-teardown).
            usleep(20_000)
            montage.stop()

            let starts = montage.movieStartCount.withLock { $0 }
            let stops = montage.movieStopCount.withLock { $0 }
            XCTAssertEqual(starts, stops,
                           "trial \(trial): every embedded clip start must have exactly one stop "
                           + "(no double teardown) — starts=\(starts) stops=\(stops)")
            XCTAssertEqual(montage.state, .idle, "trial \(trial): must land in the restartable terminal state")
        }
    }

    // MARK: - Fixtures

    private final class FrameSink: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
    }

    private static func writeSolidPNG(to url: URL, w: Int, h: Int) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "test", code: 1)
        }
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "test", code: 2)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "test", code: 3) }
    }

    private static func writeMovingClip(to url: URL, frames: Int, w: Int, h: Int, fps: Double) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ])
        guard writer.canAdd(input) else { throw NSError(domain: "test", code: 4) }
        writer.add(input)
        guard writer.startWriting() else { throw NSError(domain: "test", code: 5) }
        writer.startSession(atSourceTime: .zero)

        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let scale = CMTimeScale(600)
        for i in 0..<frames {
            var pxOut: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &pxOut)
            guard let buffer = pxOut else { throw NSError(domain: "test", code: 6) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer),
               let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                   space: cs, bitmapInfo: bitmapInfo) {
                let t = Double(i) / Double(max(frames - 1, 1))
                ctx.setFillColor(CGColor(srgbRed: CGFloat(t), green: CGFloat(1 - t), blue: 0.4, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { usleep(1_000) }
            let pts = CMTime(value: CMTimeValue(Double(i) / fps * Double(scale)), timescale: scale)
            guard adaptor.append(buffer, withPresentationTime: pts) else { throw NSError(domain: "test", code: 7) }
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed else { throw NSError(domain: "test", code: 8) }
    }
}
