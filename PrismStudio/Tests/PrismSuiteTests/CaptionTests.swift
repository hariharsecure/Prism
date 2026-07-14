import CoreMedia
import CoreVideo
import Speech
import XCTest

@testable import PrismAudio
import PrismCompositor
import PrismCore

/// Verification for the live-captions feature:
///
///  - `CaptionRenderer` (PrismCompositor/VisualFX) — fully headless-testable: the
///    rolling subtitle overlay is asserted on the pixels (IOSurface BGRA at canvas
///    size, TRANSPARENT outside the bar, text present + bottom-positioned, long
///    text WRAPS without clipping, two strings differ). PNGs are dumped for the
///    lead to eyeball.
///  - `LiveCaptioner` (PrismAudio) — only the deterministic PLUMBING is tested:
///    construction, availability/authorization mapping, the AudioPacket →
///    AVAudioPCMBuffer conversion, and no-op-when-not-running. The actual Speech
///    TRANSCRIPTION is **UNVERIFIED** here — it needs TCC authorization + real
///    speech on a device, which the headless harness cannot provide.
///
/// PNG dumps →
///   /tmp/prism_captions/
final class CaptionTests: XCTestCase {

    private static let outputDir = URL(fileURLWithPath:
        "/tmp/prism_captions")

    private let W = 1280, H = 720

    // MARK: - Readback helpers (single lock per call)

    private struct Span { var minY: Int; var maxY: Int; var minX: Int; var maxX: Int; var count: Int
        var cyMem: Double; var height: Int }

    /// Bounding box + centroid of pixels whose alpha exceeds `alphaThresh`
    /// (memory / top-origin coords: row 0 = visual top).
    private func opaqueSpan(_ buffer: CVPixelBuffer, alphaThresh: Double = 0.10, step: Int = 1) -> Span {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var minY = h, maxY = -1, minX = w, maxX = -1, count = 0
        var sy = 0.0
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let a = Double((base + y * bpr + x * 4)[3]) / 255
                if a > alphaThresh {
                    count += 1; sy += Double(y)
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                }
                x += step
            }
            y += step
        }
        return Span(minY: minY, maxY: maxY, minX: minX, maxX: maxX, count: count,
                    cyMem: count > 0 ? sy / Double(count) : 0, height: h)
    }

    /// Max alpha over a memory-coord rect (0 → fully transparent there).
    private func maxAlpha(in buffer: CVPixelBuffer, x0: Int, y0: Int, x1: Int, y1: Int, step: Int = 2) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var m = 0.0
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                m = max(m, Double((base + y * bpr + x * 4)[3]) / 255)
                x += step
            }
            y += step
        }
        return m
    }

    /// Count bright (text) pixels: high un-premultiplied luma AND opaque.
    private func brightPixelCount(_ buffer: CVPixelBuffer, step: Int = 1) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var n = 0
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let p = base + y * bpr + x * 4
                // Memory order BGRA, premultiplied-first. White text over a dark
                // bar → high stored B/G/R bytes; the bar itself is near-black.
                if p[3] > 120, p[0] > 170, p[1] > 170, p[2] > 170 { n += 1 }
                x += step
            }
            y += step
        }
        return n
    }

    // MARK: - CaptionRenderer: format + transparency

    func testRendererFormatAndTransparentBackground() throws {
        let renderer = try CaptionRenderer(width: W, height: H)
        let buf = try renderer.render(lines: ["Live captions are on."])

        // IOSurface-backed BGRA at canvas size.
        XCTAssertNotNil(CVPixelBufferGetIOSurface(buf), "caption frame must be IOSurface-backed")
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buf), kCVPixelFormatType_32BGRA)
        XCTAssertEqual(CVPixelBufferGetWidth(buf), W)
        XCTAssertEqual(CVPixelBufferGetHeight(buf), H)

        // Top ~40% of the frame must be FULLY TRANSPARENT (alpha 0) — not an
        // opaque black box.
        let topMaxA = maxAlpha(in: buf, x0: 0, y0: 0, x1: W, y1: Int(Double(H) * 0.40))
        XCTAssertEqual(topMaxA, 0, accuracy: 0.001, "caption background must be transparent, not opaque")
    }

    // MARK: - CaptionRenderer: text present + bottom-positioned

    func testRendererTextPresentAndBottomPositioned() throws {
        let renderer = try CaptionRenderer(width: W, height: H)
        let buf = try renderer.render(lines: ["Welcome back to the stream."])

        let span = opaqueSpan(buf)
        XCTAssertGreaterThan(span.count, 500, "the caption bar + text should paint many pixels")
        // Centroid of painted pixels sits in the lower portion (bottom third).
        XCTAssertGreaterThan(span.cyMem, Double(H) * 0.60,
                             "caption must be anchored to the bottom third (high memory-y)")
        // Bar does not touch the very top or spill past the bottom edge.
        XCTAssertGreaterThan(span.minY, Int(Double(H) * 0.5), "no caption ink in the top half")
        XCTAssertLessThan(span.maxY, H, "caption ink stays within the frame")

        // Legible white text is actually present over the bar.
        XCTAssertGreaterThan(brightPixelCount(buf), 200, "white caption text pixels must be present")
    }

    // MARK: - CaptionRenderer: long text WRAPS (multi-line, not clipped)

    func testRendererLongTextWraps() throws {
        let renderer = try CaptionRenderer(width: W, height: H)
        let style = CaptionRenderer.Style(maxLines: 4)

        let long = "This is a very long single caption line that cannot possibly fit within the safe caption width and therefore must wrap onto several stacked lines instead of clipping off the edge of the screen."
        let wrapped = renderer.wrappedLines([long], style: style)
        XCTAssertGreaterThanOrEqual(wrapped.count, 2, "a long line must wrap to multiple display lines")

        let shortBuf = try renderer.render(lines: ["Short line."], style: style)
        let longBuf = try renderer.render(lines: [long], style: style)

        let shortSpan = opaqueSpan(shortBuf)
        let longSpan = opaqueSpan(longBuf)

        // Multi-line wrap → a taller painted region than a single line.
        let shortH = shortSpan.maxY - shortSpan.minY
        let longH = longSpan.maxY - longSpan.minY
        XCTAssertGreaterThan(longH, Int(Double(shortH) * 1.5),
                             "wrapped caption occupies more vertical space than a single line")

        // Nothing clips off-screen: all painted pixels are inside the frame with a
        // margin on every side.
        XCTAssertGreaterThan(longSpan.minX, 0)
        XCTAssertLessThan(longSpan.maxX, W - 1)
        XCTAssertGreaterThan(longSpan.minY, 0)
        XCTAssertLessThan(longSpan.maxY, H - 1)
    }

    // MARK: - CaptionRenderer: distinct strings render differently

    func testRendererDistinctStringsDiffer() throws {
        let renderer = try CaptionRenderer(width: W, height: H)
        let a = try renderer.render(lines: ["The quick brown fox."])
        let b = try renderer.render(lines: ["Entirely different words here."])
        let diff = FXCanvas.meanDiff(a, b)
        XCTAssertGreaterThan(diff, 0.002, "two different captions must produce different pixels")
    }

    // MARK: - CaptionRenderer: empty input → transparent, no crash

    func testRendererEmptyInputIsTransparent() throws {
        let renderer = try CaptionRenderer(width: W, height: H)
        let buf = try renderer.render(lines: [])
        XCTAssertEqual(opaqueSpan(buf).count, 0, "empty caption input yields a fully transparent frame")
        let blankBuf = try renderer.render(lines: ["   "])
        XCTAssertEqual(opaqueSpan(blankBuf).count, 0, "all-whitespace caption input yields a transparent frame")
    }

    // MARK: - CaptionRenderer: PNG dumps for the lead to eyeball

    func testDumpCaptionPNGs() throws {
        try FileManager.default.createDirectory(at: Self.outputDir, withIntermediateDirectories: true)
        let renderer = try CaptionRenderer(width: W, height: H)

        let short = try renderer.render(lines: ["Live captions are now on."])
        try FXCanvas.writePNG(short, to: Self.outputDir.appendingPathComponent("caption_short.png"))

        let long = try renderer.render(
            lines: ["This is a very long caption line that must wrap onto multiple stacked lines to stay legible and on-screen without ever clipping off the right edge."],
            style: CaptionRenderer.Style(maxLines: 4))
        try FXCanvas.writePNG(long, to: Self.outputDir.appendingPathComponent("caption_long_wrapping.png"))

        let rolling = try renderer.render(
            lines: ["so that's how the pipeline stays zero-copy", "and now the live partial hypothesis updates in place"],
            style: CaptionRenderer.Style(maxLines: 2))
        try FXCanvas.writePNG(rolling, to: Self.outputDir.appendingPathComponent("caption_two_line_rolling.png"))

        print("CaptionTests: wrote PNGs to \(Self.outputDir.path)")
    }

    // MARK: - LiveCaptioner PLUMBING (transcription itself is UNVERIFIED)

    /// The availability/authorization truth table is a pure function — assert the
    /// full mapping without ever triggering a TCC prompt.
    func testCaptionerReadinessMapping() {
        typealias LC = LiveCaptioner
        // No recognizer → unavailable regardless of anything else.
        XCTAssertEqual(LC.resolveReadiness(recognizerExists: false, supportsOnDevice: true,
                                           requireOnDevice: true, authorization: .authorized),
                       .unavailable(.recognizerUnavailable))
        // Require on-device but unsupported.
        XCTAssertEqual(LC.resolveReadiness(recognizerExists: true, supportsOnDevice: false,
                                           requireOnDevice: true, authorization: .authorized),
                       .unavailable(.onDeviceUnsupported))
        // Authorization outcomes (capable recognizer).
        XCTAssertEqual(LC.resolveReadiness(recognizerExists: true, supportsOnDevice: true,
                                           requireOnDevice: true, authorization: .authorized),
                       .ready)
        XCTAssertEqual(LC.resolveReadiness(recognizerExists: true, supportsOnDevice: true,
                                           requireOnDevice: true, authorization: .denied),
                       .unavailable(.authorizationDenied))
        XCTAssertEqual(LC.resolveReadiness(recognizerExists: true, supportsOnDevice: true,
                                           requireOnDevice: true, authorization: .restricted),
                       .unavailable(.authorizationRestricted))
        XCTAssertEqual(LC.resolveReadiness(recognizerExists: true, supportsOnDevice: true,
                                           requireOnDevice: true, authorization: .notDetermined),
                       .needsAuthorization)
        // Cloud allowed (requireOnDevice false) ignores on-device support.
        XCTAssertEqual(LC.resolveReadiness(recognizerExists: true, supportsOnDevice: false,
                                           requireOnDevice: false, authorization: .authorized),
                       .ready)
    }

    /// AudioPacket (interleaved Float32 LPCM, the master-mix contract) →
    /// AVAudioPCMBuffer conversion: valid buffer, right format & frame count.
    func testCaptionerPCMConversion() throws {
        let sr = 48_000.0
        let frames = 1024
        let signal = TransientSelfTest.sine(count: frames, amplitude: 0.5, frequency: 440, sampleRate: sr)

        // Stereo.
        let stereo = try TransientSelfTest.makeProgramPacket(signal: signal, channelCount: 2,
                                                             sampleRate: sr, startSample: 0)
        let sBuf = try XCTUnwrap(LiveCaptioner.makePCMBuffer(from: stereo),
                                 "conversion must succeed for interleaved Float32 LPCM")
        XCTAssertEqual(sBuf.frameLength, AVAudioFrameCount(frames))
        XCTAssertEqual(sBuf.format.channelCount, 2)
        XCTAssertEqual(sBuf.format.sampleRate, sr, accuracy: 0.5)
        XCTAssertEqual(sBuf.format.commonFormat, .pcmFormatFloat32)
        XCTAssertNotNil(sBuf.audioBufferList.pointee.mBuffers.mData)

        // Mono.
        let mono = try TransientSelfTest.makeProgramPacket(signal: signal, channelCount: 1,
                                                           sampleRate: sr, startSample: 0)
        let mBuf = try XCTUnwrap(LiveCaptioner.makePCMBuffer(from: mono))
        XCTAssertEqual(mBuf.frameLength, AVAudioFrameCount(frames))
        XCTAssertEqual(mBuf.format.channelCount, 1)
    }

    /// Feeding audio before `start()` (or when unavailable) must be a safe no-op —
    /// never crashes, never emits captions.
    func testCaptionerAppendBeforeStartIsNoOp() throws {
        let cap = LiveCaptioner()
        let emitted = EmitBox()
        cap.onCaption = { _ in emitted.bump() }

        let signal = TransientSelfTest.sine(count: 1024, amplitude: 0.4, frequency: 300)
        for i in 0..<8 {
            let pkt = try TransientSelfTest.makeProgramPacket(signal: signal, channelCount: 2,
                                                             sampleRate: 48_000, startSample: i * 1024)
            cap.append(pkt) // no crash, no-op (not running)
        }
        // State is idle (or a permanent unavailable if Speech has no locale here);
        // never .running, and nothing was emitted.
        switch cap.state {
        case .running, .starting:
            XCTFail("captioner must not be running before start()")
        default:
            break
        }
        XCTAssertEqual(emitted.value, 0, "no captions before a running session")

        // reset() is safe at any time.
        cap.reset()
        cap.stop()
    }

    /// A captioner constructed for a locale with no recognizer degrades cleanly to
    /// `.unavailable(.recognizerUnavailable)` and stays a no-op.
    func testCaptionerUnavailableLocaleDegradesCleanly() throws {
        // A nonsense locale yields no SFSpeechRecognizer.
        let cap = LiveCaptioner(locale: Locale(identifier: "zz-ZZ"))
        if case .unavailable(.recognizerUnavailable) = cap.state {
            cap.start() // must remain unavailable, no crash
            if case .unavailable = cap.state { /* ok */ } else {
                XCTFail("start() must not move an unavailable captioner out of unavailable")
            }
            let signal = TransientSelfTest.sine(count: 512, amplitude: 0.3, frequency: 200)
            let pkt = try TransientSelfTest.makeProgramPacket(signal: signal, startSample: 0)
            cap.append(pkt) // no-op, no crash
        } else {
            // If this machine unexpectedly HAS a recognizer for "zz-ZZ", we can't
            // assert the unavailable path — record it rather than fail spuriously.
            print("CaptionTests: locale zz-ZZ unexpectedly produced a recognizer; skipping unavailable assertion")
        }
    }

    // MARK: - C1: PCM memory-safety (non-interleaved reject, discontiguous copy)

    /// A NON-interleaved (planar) stereo ASBD must be rejected — the old fast path
    /// memcpy'd `frames*channels*4` into the first channel's plane (which only holds
    /// `frames*4`), overrunning it. Post-fix: `makePCMBuffer` returns nil.
    func testCaptionerNonInterleavedStereoRejected() throws {
        let pkt = try TransientSelfTest.makeNonInterleavedFloatPacket(
            frames: 1024, channelCount: 2, sampleRate: 48_000, startSample: 0)
        XCTAssertNil(LiveCaptioner.makePCMBuffer(from: pkt),
                     "non-interleaved stereo must be rejected (no per-channel overrun)")
    }

    /// A DISCONTIGUOUS CMBlockBuffer (first contiguous run < payload) must be copied
    /// segment-safely, not memcpy'd past the first segment. A per-sample ramp lets
    /// us detect an overread: the old code would corrupt the second half; post-fix
    /// every frame (including the last, across the segment boundary) is exact.
    func testCaptionerDiscontiguousBlockBufferCopiedCorrectly() throws {
        let frames = 1024
        let signal = (0..<frames).map { Float($0) / Float(frames) }
        let pkt = try TransientSelfTest.makeDiscontiguousInterleavedPacket(
            signal: signal, channelCount: 2, sampleRate: 48_000, startSample: 0)
        let buf = try XCTUnwrap(LiveCaptioner.makePCMBuffer(from: pkt),
                                "a discontiguous CMBlockBuffer must be safely copied, not rejected")
        XCTAssertEqual(buf.frameLength, AVAudioFrameCount(frames))
        let data = try XCTUnwrap(buf.audioBufferList.pointee.mBuffers.mData)
        let f = data.assumingMemoryBound(to: Float.self)
        XCTAssertEqual(f[0], signal[0], accuracy: 1e-6)
        XCTAssertEqual(f[1], signal[0], accuracy: 1e-6)                 // frame 0, channel 1
        let lastBase = (frames - 1) * 2
        XCTAssertEqual(f[lastBase], signal[frames - 1], accuracy: 1e-6,
                       "last frame must be copied correctly across the segment boundary")
        XCTAssertEqual(f[lastBase + 1], signal[frames - 1], accuracy: 1e-6)
    }

    // MARK: - C2: concurrent start() claims exactly once

    /// N concurrent `start()` attempts must yield exactly ONE session (the pre-fix
    /// non-atomic read-then-proceed let two idle callers both start). We exercise
    /// the atomic claim directly so no TCC prompt is triggered.
    func testConcurrentStartClaimsExactlyOnce() {
        let cap = LiveCaptioner()
        guard case .idle = cap.state else {
            print("CaptionTests: captioner not .idle on this host (no recognizer?); skipping concurrent-claim assertion")
            return
        }
        let winners = EmitBox()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if cap.claimStart() != nil { winners.bump() }
        }
        XCTAssertEqual(winners.value, 1, "exactly one concurrent claim may transition idle→starting")
        XCTAssertNil(cap.claimStart(), "a claimed captioner rejects further claims")
        if case .starting = cap.state {} else { XCTFail("the winning claim must leave state = .starting") }
    }

    // MARK: - C4: init / readiness-check never prompt

    /// Constructing a captioner and inspecting readiness must NOT begin
    /// authorization (which would move state to `.starting`). A prompt is only
    /// acceptable from an explicit user-initiated `start()`.
    func testInitAndReadinessCheckDoNotPrompt() {
        let cap = LiveCaptioner()
        _ = cap.supportsOnDeviceRecognition
        _ = LiveCaptioner.resolveReadiness(recognizerExists: true, supportsOnDevice: true,
                                           requireOnDevice: true, authorization: .notDetermined)
        switch cap.state {
        case .starting:
            XCTFail("init/readiness-check must never begin authorization (no prompt)")
        default:
            break
        }
    }

    /// Thread-safe counter for emitted captions.
    private final class EmitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
}
