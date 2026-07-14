import AudioToolbox
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Vision
import XCTest
@testable import Prism

/// Director's Cut slice-3b — SUBJECT-TRACKING 9:16 reframe: INDEPENDENT validation
/// methods #2 and #3 (the pure smoothing/geometry math is method #1, locked by
/// `DirectorsCutSlice3bTests`). Together they validate the framing THREE ways with
/// NO human eyeball:
///
///   #1  pure planner/geometry math vs an analytic oracle (other file).
///   #2  synthetic-ground-truth END-TO-END: a horizontal test clip whose subject
///       moves along a KNOWN path is run through the REAL reframer (sampling →
///       plan → AVFoundation ramp composition → export), and the emitted crop
///       track is asserted against ground truth (this file).
///   #3  output-geometry cross-check: an INDEPENDENT read of the emitted 9:16
///       file's pixels/metadata (dims, fps, duration, audio-through, and where
///       the subject actually LANDS in the output frame) — separate from the
///       planner's own numbers (this file).
///
/// HONEST SCOPE NOTE. Apple Vision's `VNDetectFaceRectanglesRequest` /
/// `VNDetectHumanRectanglesRequest` do NOT fire on synthetic renders (proven by
/// `testVisionDoesNotDetectSyntheticSubject` below — 0 detections on cartoon and
/// photographic-style faces and a person silhouette). A synthetic clip therefore
/// CANNOT exercise the real ML classifier; only real footage (needing a human)
/// can. So method #2 INJECTS a deterministic subject locator at the analyzer's
/// ML seam (`SubjectTrackAnalyzer.frameDetector`, default `nil` in production).
/// The injected locator reads the REAL decoded frame's pixels (skin-tone
/// centroid) — so the analyzer's frame-sampling/timing, the planner smoothing,
/// the crop geometry, the per-time transform-ramp composition, and the export
/// ALL run for real and are validated against ground truth. What is NOT
/// validated here: Vision's face/human detection ACCURACY (that remains
/// eyeball-on-real-footage). Everything downstream of the detector IS.
@MainActor
final class DirectorsCutReframeSyntheticTests: XCTestCase {

    // Synthetic source geometry.
    private static let W = 1280, H = 720, FPS: Int32 = 30, DUR = 8.0
    private static let AUDIO_SR = 44100.0

    // MARK: - Known ground-truth subject path (normalized source-x, 0…1)
    //
    // left→right ramp (0…3 s: 0.2→0.8), HOLD (3…5 s: 0.8), right→left ramp
    // (5…8 s: 0.8→0.2). Stays inside the ~[0.16, 0.84] in-bounds crop window for
    // a 16:9→9:16 hero-fill, so the target is reachable without edge clamping.
    static func groundTruth(_ t: Double) -> Double {
        if t < 3 { return 0.2 + 0.6 * (t / 3) }
        if t < 5 { return 0.8 }
        return max(0.2, 0.8 - 0.6 * ((t - 5) / 3))
    }

    // MARK: - Synthetic frame drawing (a skin-tone face-like target at cx)

    /// Draw a high-contrast face-like target centred at normalized x `cx` into an
    /// existing context. Dominant skin-tone oval ⇒ a robust colour centroid.
    static func drawFace(in ctx: CGContext, w: Int, h: Int, cx: Double) {
        ctx.setFillColor(CGColor(red: 0.5, green: 0.52, blue: 0.55, alpha: 1)) // grey bg
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let cxPx = CGFloat(cx) * CGFloat(w), cyPx = CGFloat(h) * 0.5
        let headW = CGFloat(h) * 0.42, headH = CGFloat(h) * 0.55
        ctx.setFillColor(CGColor(red: 0.90, green: 0.72, blue: 0.60, alpha: 1)) // skin
        ctx.fillEllipse(in: CGRect(x: cxPx - headW/2, y: cyPx - headH/2, width: headW, height: headH))
        ctx.setFillColor(CGColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)) // eyes
        let eyeR = headW * 0.09, eyeDX = headW * 0.20, eyeDY = headH * 0.14
        ctx.fillEllipse(in: CGRect(x: cxPx - eyeDX - eyeR, y: cyPx + eyeDY - eyeR, width: eyeR*2, height: eyeR*2))
        ctx.fillEllipse(in: CGRect(x: cxPx + eyeDX - eyeR, y: cyPx + eyeDY - eyeR, width: eyeR*2, height: eyeR*2))
        ctx.setStrokeColor(CGColor(red: 0.55, green: 0.25, blue: 0.25, alpha: 1)) // mouth
        ctx.setLineWidth(headW * 0.05)
        ctx.move(to: CGPoint(x: cxPx - headW*0.16, y: cyPx - headH*0.20))
        ctx.addLine(to: CGPoint(x: cxPx + headW*0.16, y: cyPx - headH*0.20))
        ctx.strokePath()
    }

    /// A face-like target as a standalone CGImage (for the Vision-negative probe).
    static func faceImage(w: Int, h: Int, cx: Double) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        drawFace(in: ctx, w: w, h: h, cx: cx)
        return ctx.makeImage()!
    }

    // MARK: - Deterministic pixel subject locator (the injected ML-seam stand-in)

    /// Horizontal centroid (normalized 0…1) of skin-tone pixels in `image`, or
    /// `nil` if too few — reads the ACTUAL decoded frame, so it recovers the true
    /// on-screen subject position. Used both as the injected detector (method #2)
    /// and as the INDEPENDENT output reader (method #3).
    @Sendable static func skinCentroidX(_ image: CGImage) -> Double? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var sumX = 0.0, count = 0.0
        let step = max(1, w / 640)   // subsample for speed
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let p = (y * w + x) * 4
                let r = Double(buf[p]) / 255, g = Double(buf[p+1]) / 255, b = Double(buf[p+2]) / 255
                if r > 0.6 && (r - b) > 0.10 && (r - g) > 0.02 { sumX += Double(x); count += 1 }
                x += step
            }
            y += step
        }
        guard count > 20 else { return nil }
        return (sumX / count) / Double(w)
    }

    // MARK: - Synthetic 16:9 clip writer (video + carried-through audio)

    /// Write a 1280×720 @30fps, `DUR`-second .mov whose subject follows
    /// `groundTruth(t)`, PLUS a silent mono AAC audio track so method #3 can prove
    /// audio is carried through. Returns the source URL. Skips (not fails) if the
    /// host can't encode — the pipeline itself is what we validate.
    private func writeSyntheticSource() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dcut-synth.\(UUID().uuidString).mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { throw XCTSkip("no AVAssetWriter") }
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.W, AVVideoHeightKey: Self.H,
        ])
        vInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.W, kCVPixelBufferHeightKey as String: Self.H,
        ])
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.AUDIO_SR,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000,
        ])
        aInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(vInput), writer.canAdd(aInput) else { throw XCTSkip("h264/aac unavailable") }
        writer.add(vInput); writer.add(aInput)
        guard writer.startWriting() else { throw XCTSkip("writer refused to start") }
        writer.startSession(atSourceTime: .zero)

        // Video frames.
        let frames = Int(Self.DUR * Double(Self.FPS))
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        for i in 0..<frames {
            let t = Double(i) / Double(Self.FPS)
            var pbOut: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess,
                  let pb = pbOut else { throw XCTSkip("no pixel pool") }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb),
               let ctx = CGContext(data: base, width: Self.W, height: Self.H, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                       | CGBitmapInfo.byteOrder32Little.rawValue) {
                Self.drawFace(in: ctx, w: Self.W, h: Self.H, cx: Self.groundTruth(t))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            while !vInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.004) }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: Self.FPS))
        }
        vInput.markAsFinished()

        // Silent audio spanning the clip, in ~0.25 s chunks.
        let chunk = Int(Self.AUDIO_SR * 0.25)
        let totalAudio = Int(Self.AUDIO_SR * Self.DUR)
        var written = 0
        while written < totalAudio {
            let n = min(chunk, totalAudio - written)
            let pts = CMTime(value: CMTimeValue(written), timescale: CMTimeScale(Self.AUDIO_SR))
            guard let sb = Self.silentAudioBuffer(frames: n, sampleRate: Self.AUDIO_SR, pts: pts) else {
                throw XCTSkip("could not build audio buffer")
            }
            while !aInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.004) }
            aInput.append(sb)
            written += n
        }
        aInput.markAsFinished()

        let done = XCTestExpectation(description: "write")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 30)
        guard writer.status == .completed else { throw XCTSkip("synthetic write failed: \(String(describing: writer.error))") }
        return url
    }

    /// A silent LPCM mono CMSampleBuffer of `frames` samples at `sampleRate`.
    static func silentAudioBuffer(frames: Int, sampleRate: Double, pts: CMTime) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &fmt) == noErr, let fmt else { return nil }
        let bytes = frames * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: bytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        _ = CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        var sb: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sizeArr = 2
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt, sampleCount: frames,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                sampleSizeArray: &sizeArr, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }

    // MARK: - Sidecar decode (the PRISM_DCUT_REFRAME_DUMP record)

    private struct SidecarDump: Decodable {
        struct S: Decodable { let t: Double; let detectedCenterX: Double?; let plannedCenter: Double }
        let renderWidth: Int, renderHeight: Int, halfWindow: Double, samples: [S]
    }

    /// Run the REAL subject-tracking reframer on a synthetic clip with the ML seam
    /// injected + the dump sidecar enabled. Returns (source, output, sidecar rows).
    private func runRealPipeline() async throws -> (src: URL, out: URL, dump: SidecarDump) {
        let src = try writeSyntheticSource()
        var analyzer = SubjectTrackAnalyzer(sampleRate: 3)
        analyzer.frameDetector = Self.skinCentroidX   // ML seam ← deterministic pixel locator
        let reframer = SubjectTrackingVerticalReframer(width: 1080, height: 1920,
                                                       analyzer: analyzer, dumpPlan: true)
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dcut-synth-9x16.\(UUID().uuidString).mov")
        let out = try await reframer.reframeToVertical(horizontal: src, to: outURL)
        let sidecar = out.deletingPathExtension().appendingPathExtension("reframe.json")
        let data = try Data(contentsOf: sidecar)
        let dump = try JSONDecoder().decode(SidecarDump.self, from: data)

        // "For the record": merge ground truth into a combined artifact next to the output.
        struct Row: Encodable { let t: Double; let groundTruth: Double; let detected: Double?; let planned: Double }
        let rows = dump.samples.map { Row(t: $0.t, groundTruth: Self.groundTruth($0.t),
                                          detected: $0.detectedCenterX, planned: $0.plannedCenter) }
        let record = out.deletingPathExtension().appendingPathExtension("groundtruth.json")
        if let d = try? JSONEncoder().encode(rows) { try? d.write(to: record) }
        return (src, out, dump)
    }

    // MARK: - Vision-negative probe (records WHY we inject; repeatable)

    /// Documents the limitation that forces injection: Apple Vision detects NO
    /// subject in the synthetic. If a future OS DID detect it, this would fail and
    /// tell us the synthetic can drive real Vision after all — a good failure.
    func testVisionDoesNotDetectSyntheticSubject() {
        for cx in [0.25, 0.5, 0.75] {
            let img = Self.faceImage(w: Self.W, h: Self.H, cx: cx)
            let handler = VNImageRequestHandler(cgImage: img, options: [:])
            let faces = VNDetectFaceRectanglesRequest(), people = VNDetectHumanRectanglesRequest()
            try? handler.perform([faces]); try? handler.perform([people])
            let fN = faces.results?.count ?? 0, pN = people.results?.count ?? 0
            print("PROBE face@\(cx): VNFace=\(fN) VNHuman=\(pN) combined=\(String(describing: SubjectTrackAnalyzer.detectSubjectCenterX(in: img)))")
            XCTAssertEqual(fN, 0, "Vision face detection unexpectedly fired on a synthetic — synthetic may now drive real Vision")
            XCTAssertEqual(pN, 0, "Vision human detection unexpectedly fired on a synthetic")
        }
        // Sanity: the injected pixel locator DOES recover the target (so the seam is valid).
        for cx in [0.25, 0.5, 0.75] {
            let got = Self.skinCentroidX(Self.faceImage(w: Self.W, h: Self.H, cx: cx))
            XCTAssertNotNil(got, "pixel locator must find the synthetic subject")
            XCTAssertEqual(got ?? -1, cx, accuracy: 0.03, "pixel locator recovers ground-truth cx")
        }
    }

    // MARK: - METHOD #2: synthetic-ground-truth END-TO-END (the real pipeline)

    func testMethod2_TracksGroundTruthEndToEnd() async throws {
        let (_, _, dump) = try await runRealPipeline()

        XCTAssertFalse(dump.samples.isEmpty, "pipeline produced a subject track")
        // The injected locator read REAL decoded frames — it must match ground truth
        // (proves the analyzer sampled the right frame at the right time).
        var maxDetErr = 0.0, maxPlanLag = 0.0
        let hw = dump.halfWindow
        for s in dump.samples {
            let gt = Self.groundTruth(s.t)
            if let d = s.detectedCenterX {
                maxDetErr = max(maxDetErr, abs(d - gt))
            } else {
                XCTFail("detector returned nil at t=\(s.t) — synthetic frame extraction gap")
            }
            // Plan always in the in-bounds crop window.
            XCTAssertGreaterThanOrEqual(s.plannedCenter, hw - 1e-6, "plan in-bounds (left) at t=\(s.t)")
            XCTAssertLessThanOrEqual(s.plannedCenter, 1 - hw + 1e-6, "plan in-bounds (right) at t=\(s.t)")
            maxPlanLag = max(maxPlanLag, abs(s.plannedCenter - gt))
        }
        print("METHOD2 samples=\(dump.samples.count) halfWindow=\(String(format: "%.4f", hw)) maxDetectErr=\(String(format: "%.4f", maxDetErr)) maxPlanLag=\(String(format: "%.4f", maxPlanLag))")

        // (a) Detector fidelity vs ground truth (frame timing + locator).
        XCTAssertLessThan(maxDetErr, 0.05, "detected track matches ground truth (frame extraction is correct)")
        // (b) Planned crop tracks ground truth within the documented smoothing lag.
        //     tau=0.35 s, ramp slope 0.2/s ⇒ steady-state lag ~0.07; give 0.13 for
        //     the direction-change transients + 3 Hz sampling.
        XCTAssertLessThan(maxPlanLag, 0.13, "planned crop follows the subject within smoothing lag")

        // (c) Direction & convergence: opens on the subject, tracks the ramp up,
        //     settles on the hold, tracks the ramp back down.
        func plan(at t: Double) -> Double {
            let near = dump.samples.min { abs($0.t - t) < abs($1.t - t) }
            return near!.plannedCenter
        }
        XCTAssertEqual(dump.samples.first!.plannedCenter, Self.groundTruth(0), accuracy: 0.05,
                       "opens framed on the subject, not dead-centre")
        XCTAssertGreaterThan(plan(at: 2.5), plan(at: 0.5) + 0.20, "follows the left→right ramp")
        XCTAssertEqual(plan(at: 4.8), 0.8, accuracy: 0.04, "settles on the hold at 0.8")
        XCTAssertLessThan(plan(at: 7.5), plan(at: 5.2) - 0.20, "follows the right→left ramp")
    }

    // MARK: - METHOD #3: output-geometry cross-check (independent read of RESULT)

    func testMethod3_OutputGeometryCrossCheck() async throws {
        let (src, out, dump) = try await runRealPipeline()
        let asset = AVURLAsset(url: out)

        // Dimensions: emitted video is exactly 1080×1920 (display-oriented).
        let vTracks = try await asset.loadTracks(withMediaType: .video)
        let vTrack = try XCTUnwrap(vTracks.first, "output has a video track")
        let natural = try await vTrack.load(.naturalSize)
        let pref = try await vTrack.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: natural).applying(pref)
        XCTAssertEqual(abs(oriented.width), 1080, accuracy: 1, "output width 1080")
        XCTAssertEqual(abs(oriented.height), 1920, accuracy: 1, "output height 1920")

        // Duration + fps preserved (within a frame).
        let srcDur = try await AVURLAsset(url: src).load(.duration).seconds
        let outDur = try await asset.load(.duration).seconds
        XCTAssertEqual(outDur, srcDur, accuracy: 0.2, "duration preserved")
        let fps = try await vTrack.load(.nominalFrameRate)
        XCTAssertEqual(Double(fps), Double(Self.FPS), accuracy: 1.0, "fps preserved")

        // Audio track carried through.
        let aTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(aTracks.isEmpty, "audio (master mix) carried through to the 9:16 output")

        // INDEPENDENT read of the RESULT: where does the subject actually land in
        // the output frame? Sample output frames, locate the subject by pixel
        // centroid, and check the 9:16 horizontal-center safe zone.
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        var landedAtHold: Double = .nan
        var worstEdge = 0.5
        for t in [0.5, 1.5, 2.5, 4.5, 6.0, 7.0] {
            let cg = try gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
            XCTAssertEqual(cg.width, 1080, "output frame is 1080 wide")
            XCTAssertEqual(cg.height, 1920, "output frame is 1920 tall")
            guard let x = Self.skinCentroidX(cg) else {
                XCTFail("subject not visible in output frame at t=\(t)"); continue
            }
            // Subject must stay inside the horizontal safe zone (never cut off /
            // shoved to an edge) — the whole point of tracking.
            XCTAssertGreaterThan(x, 0.15, "subject not off the LEFT edge at t=\(t) (x=\(x))")
            XCTAssertLessThan(x, 0.85, "subject not off the RIGHT edge at t=\(t) (x=\(x))")
            worstEdge = min(worstEdge, min(x, 1 - x))
            if abs(t - 4.5) < 0.01 { landedAtHold = x }
        }
        print("METHOD3 dims=\(Int(abs(oriented.width)))x\(Int(abs(oriented.height))) dur=\(String(format: "%.2f", outDur))s fps=\(fps) audio=\(!aTracks.isEmpty) subjectAtHold=\(String(format: "%.3f", landedAtHold)) worstEdgeMargin=\(String(format: "%.3f", worstEdge))")

        // On the HOLD the crop has fully settled ⇒ subject sits at output centre.
        XCTAssertEqual(landedAtHold, 0.5, accuracy: 0.10, "on the hold the subject lands at the 9:16 centre")

        // CROSS-CHECK the emitted pixels against the PLAN's own numbers (independent
        // instruments must agree): output subject x ≈ 0.5 + (gt − planned)·(croppedW/renderW).
        let croppedOverRender = Double(Self.W) * (1920.0 / Double(Self.H)) / 1080.0  // = croppedW/renderW
        let gtHold = Self.groundTruth(4.5)
        let planHold = dump.samples.min { abs($0.t - 4.5) < abs($1.t - 4.5) }!.plannedCenter
        let predicted = 0.5 + (gtHold - planHold) * croppedOverRender
        XCTAssertEqual(landedAtHold, predicted, accuracy: 0.06,
                       "emitted-pixel subject position agrees with the planner's crop math")
    }
}
