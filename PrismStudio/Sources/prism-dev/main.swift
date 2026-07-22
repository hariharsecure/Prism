import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Metal
import Network
import os
import PrismAnimation
import PrismAudio
import PrismAVTestKit
import PrismCapture
import PrismColor
import PrismCompose
import PrismControlSurface
import PrismProximity
import PrismDirector
import PrismCompositor
import PrismControl
import PrismCore
import PrismExport
import PrismSources
import PrismLink
import PrismLinkSender
import PrismOutput
import PrismScreen
import PrismSound
import PrismVirtualCam
import PrismVision
import UniformTypeIdentifiers

// prism-dev — developer harness for the Prism engine modules.
// Commands that touch TCC-gated hardware (camera/screen) are explicit and
// never run as part of `selftest`.

let usage = """
prism-dev <command>

  selftest              run all headless module self-tests (no permissions needed)
  gensounds [count] [dir]
                        generate the procedural sound library (≥1000 WAVs + library.json)
                        to ~/Library/Application Support/studio.prism.app/SoundLibrary
                        (or [dir]); [count] optionally caps the total. Verifies a few WAVs.
  scansounds [dir]      scan the on-disk library and report loop-seam continuity
                        (seam vs interior step) + DC offset — the A1/A6 fix proof
  devices               enumerate cameras + microphones (no capture started)
  content               enumerate displays/windows/apps (TRIGGERS Screen Recording TCC prompt)
  pipeline [secs] [out] synthetic 2-source → mailboxes → RenderLoop → compositor → recorder
                        (default 3 s; verifies the recorded file afterwards)
  av-roundtrip [seed] [evidenceRoot]
                        deterministic fixture → real compositor → VideoToolbox encode
                        → MOV mux → decode + A/V oracle. Seed accepts decimal or 0x hex;
                        JSON evidence defaults to a fresh directory under the temp dir.
  rtmp-loopback [seed]  LIVE socket proof: oracle fixture → RTMPStreamOutput (FLV mux)
                        → real RTMP → headless MediaMTX → recording → decode + live oracle,
                        with negative controls. Auto-skips if mediamtx/ffmpeg absent.
                        Reconnect/slow-consumer/real-ingest → `stream rtmp <url>`.
  playfile <path> [secs] [outDir]
                        network-free proof: MovieSource(video FILE) → compositor → dump ~10
                        spread PNG frames + per-frame timing + frame-to-frame meanDiff
                        (default 6 s; outDir defaults to a temp dir)
  montage <dir_or_files...> [interval] [outDir]
                        build a MontageSource from real image/video files (a folder
                        is expanded to its media) and dump spread PNG frames +
                        per-frame timing/meanDiff, proving items cycle. Ken Burns +
                        crossfade on. [interval] default 1.5s; outDir defaults to a
                        temp dir. e.g. prism-dev montage ~/Movies/clips 1.0
  control [port]        run the obs-websocket v5 server with a demo backend (Ctrl-C to stop)
  capture [id] [secs] [out]
                        LIVE camera capture → compositor → recording (first camera if no id;
                        TRIGGERS the Camera TCC prompt; iPhone via Continuity appears as a camera)
  link-client <code> [host] [port]
                        PrismLink loopback tester: QUIC connect to a running LinkServer
                        (e.g. the Prism app) with the given pairing code, hello (code-bound
                        proof) + clock sync, then 60 synthetic encoded frames.
                        Default host 127.0.0.1; port required.
  link-server <code> [port]
                        Headless LinkServer (no Bonjour) for loopback testing; prints peer
                        events + media stats. (The old "CLI QUIC listeners get EINVAL" lore
                        was a bug — setting newConnectionHandler AND newConnectionGroupHandler
                        on one QUIC listener — fixed in LinkServer.)
  stream <rtmp|srt|multi> <url> [secs] [--audio] [--camera] [--file <path>]
                        --file streams a downloaded VIDEO FILE full-frame (letterboxed, looped);
                        with --audio it uses the clip's own soundtrack. Otherwise:
                        synthetic 2-source → compositor → RenderLoop → ONE ProgramEncoder
                        (H.264, realtime, ~2 s keyframe) → live RTMP / SRT / multi-destination
                        output. --audio adds a synthetic sine-tone → AudioMixer → onMasterMix
                        → the stream's append(audio:). Default 10 s. Point <url> at a LOCAL
                        media server (mediamtx): the command only connects to the URL you give.
                          rtmp  URL rtmp://host:1935/<streamKey>   (key = last path component)
                          srt   URL srt://host:8890?streamid=…     (streamid carried in the URL)
                          multi <url> as one destination (+ a dead one, to prove fault isolation)
  stream audiocheck     network-free proof the synthetic audio generator produces valid
                        CMSampleBuffers: drives the mixer in manual-render mode for 1 s and
                        asserts onMasterMix fired + PTS is monotonic (no server, no audio device).
"""

// MARK: - Synthetic sources (dev-harness only: CPU fill is allowed in test code)

func makeSolidFrame(pool: PixelBufferPool, rgba: (UInt8, UInt8, UInt8, UInt8),
                    pts: CMTime, source: SourceID) throws -> VideoFrame {
    let buf = try pool.makeBuffer()
    CVPixelBufferLockBaseAddress(buf, [])
    defer { CVPixelBufferUnlockBaseAddress(buf, []) }
    let base = CVPixelBufferGetBaseAddress(buf)!
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buf)
    let h = CVPixelBufferGetHeight(buf), w = CVPixelBufferGetWidth(buf)
    for y in 0..<h {
        let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for x in 0..<w {
            // BGRA byte order
            row[x * 4 + 0] = rgba.2; row[x * 4 + 1] = rgba.1
            row[x * 4 + 2] = rgba.0; row[x * 4 + 3] = rgba.3
        }
    }
    return VideoFrame(pixelBuffer: buf, pts: pts, source: source)
}

// MARK: - Commands

func cmdSelftest() async throws {
    var failures = 0

    print("── PrismCompositor.CompositorSelfTest")
    do { try CompositorSelfTest.run(); print("   PASS") } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismCompositor.MetalLibraryCacheSelfTest (OPT#10)")
    do { try MetalLibraryCacheSelfTest.run(); print("   PASS") } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismAudio.AudioMixerSelfCheck")
    do {
        let report = try AudioMixerSelfCheck.run()
        print(report.description.split(separator: "\n").map { "   \($0)" }.joined(separator: "\n"))
        if !report.allPassed { failures += 1 }
    } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismAnimation.AnimationSelfTest")
    do { try AnimationSelfTest.run(); print("   PASS") } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismColor.ColorSelfTest")
    do { try ColorSelfTest.run(); print("   PASS") } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismColor.ChromaKeySelfTest")
    do { try ChromaKeySelfTest.run(); print("   PASS") } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismColor.LumaKeySelfTest")
    do { try LumaKeySelfTest.run(); print("   PASS") } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismAudio.LoudnessSelfTest")
    do { try LoudnessSelfTest.run(); print("   PASS") } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismAudio.DuckingSelfTest")
    do { try DuckingSelfTest.run(); print("   PASS") } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismAudio.AudioFindingsSelfTests")
    do { try AudioFindingsSelfTests.run(); print("   PASS") } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismAudio.AudioInsertsSelfTest")
    do { let r = try await AudioInsertsSelfTest.run(); if !r.allPassed { failures += 1 }; print("   " + (r.allPassed ? "PASS" : "FAIL")) } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismVision.VisionSelfTest")
    do { try VisionSelfTest.run(); print("   PASS") } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismSources.SourcesSelfTest")
    do { try SourcesSelfTest.run(); print("   PASS") } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismSources.MovieSourceSelfTest")
    do { try MovieSourceSelfTest.run(); print("   PASS") } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismSources.MontageSelfTest")
    do { try MontageSelfTest.run(); print("   PASS") } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismExport.ExportSelfTest")
    do { try ExportSelfTest.run(); print("   PASS") } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismCompose.ComposeSelfTest")
    do { try ComposeSelfTest.run(); print("   PASS") } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismOutput.OutputSelfTest")
    do {
        let lines = try await OutputSelfTest.run()
        print(lines.map { "   \($0)" }.joined(separator: "\n"))
    } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismOutput.MultiDestinationSelfTest")
    do {
        let lines = try await MultiDestinationSelfTest.run()
        print(lines.map { "   \($0)" }.joined(separator: "\n"))
    } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismOutput.MultitrackAudioSelfTest")
    do { _ = try await MultitrackAudioSelfTest.run(); print("   PASS") } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismControlSurface.ControlSurfaceSelfTest")
    do { _ = try ControlSurfaceSelfTest.run(); print("   PASS") } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismProximity.ProximitySelfTest")
    do { try ProximitySelfTest.run(); print("   PASS") } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismDirector.DirectorSelfTest")
    do { try DirectorSelfTest.run(); print("   PASS") } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismCompositor.HDRSelfTest")
    do { _ = try HDRSelfTest.run(); print("   PASS") } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismOutput.HDRRecorderSelfTest")
    do { _ = try await HDRRecorderSelfTest.run(); print("   PASS") } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismSound.SoundSelfTest")
    do {
        let r = try SoundSelfTest.run()
        print(r.description.split(separator: "\n").map { "   \($0)" }.joined(separator: "\n"))
        if !r.allPassed { failures += 1 }
    } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismSound.MusicSelfTest")
    do {
        let r = try MusicSelfTest.run()
        print(r.description.split(separator: "\n").map { "   \($0)" }.joined(separator: "\n"))
        if !r.allPassed { failures += 1 }
    } catch { print("   FAIL: \(error)"); failures += 1 }

    print("── PrismSound.BeatClockSelfTest")
    do {
        let r = try BeatClockSelfTest.run()
        print(r.description.split(separator: "\n").map { "   \($0)" }.joined(separator: "\n"))
        if !r.allPassed { failures += 1 }
    } catch { print("   FAIL: \(error)"); failures += 1 }

    if failures > 0 { print("\nSELFTEST: \(failures) suite(s) FAILED"); exit(1) }
    print("\nSELFTEST: all suites passed")
}

func cmdGensounds(count: Int?, dir: String?) async throws {
    let root = dir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    print("Generating procedural sound library\(count.map { " (cap \($0))" } ?? "") …")
    let start = Date()
    let report = try SoundFoundry.generate(to: root, limit: count) { done, total in
        print("  … \(done)/\(total)")
    }
    let elapsed = Date().timeIntervalSince(start)
    print(report.description)
    print(String(format: "  generated in %.1fs", elapsed))

    // Independent verification: reload the manifest + spot-check a few WAVs.
    let lib = try SoundLibrary(root: report.rootURL)
    print("Verify: library.json has \(lib.entries.count) entries across \(lib.categories.count) categories")
    for (cat, n) in lib.countsByCategory { print("   \(cat): \(n)") }

    var opened = 0, nonSilent = 0, durationOK = 0
    let sample = stride(from: 0, to: lib.entries.count, by: max(1, lib.entries.count / 8)).map { lib.entries[$0] }
    for e in sample {
        guard let file = try? AVAudioFile(forReading: lib.url(for: e)),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil else { continue }
        opened += 1
        var peak: Float = 0
        if let d = buf.floatChannelData {
            for c in 0..<Int(buf.format.channelCount) { for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(d[c][i])) } }
        }
        if peak > 0.05 { nonSilent += 1 }
        let secs = Double(file.length) / file.processingFormat.sampleRate
        if abs(secs - e.durationSec) < 0.05 { durationOK += 1 }
    }
    print("Verify: spot-checked \(sample.count) WAVs — opened \(opened), non-silent \(nonSilent), duration-match \(durationOK)")
    let ok = lib.entries.count >= 1000 || (count != nil && lib.entries.count == min(count!, 1020))
    let valid = opened == sample.count && nonSilent == sample.count && durationOK == sample.count
    print((ok && valid) ? "GENSOUNDS: PASS" : "GENSOUNDS: DONE (count=\(lib.entries.count), spot-check valid=\(valid))")
    if !valid { exit(1) }
}

/// Scan the on-disk sound library and report the two metrics the fix ledger
/// targets: loop-seam continuity (|first−last| vs median adjacent step, over
/// loopable entries) and DC offset (max |channel-mean| over ALL files). This is
/// the "re-scan real files" proof for findings A1 + A6 — numbers, not adjectives.
func cmdScanSounds(dir: String?) throws {
    let root = dir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        ?? SoundLibrary.defaultRootURL
    let lib = try SoundLibrary(root: root)
    print("Scanning \(lib.entries.count) entries under \(root.path)")

    func read(_ e: SoundEntry) -> [[Float]]? {
        guard let file = try? AVAudioFile(forReading: lib.url(for: e)),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil, let d = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength), ch = Int(buf.format.channelCount)
        return (0..<ch).map { c in Array(UnsafeBufferPointer(start: d[c], count: n)) }
    }

    func median(_ xs: [Float]) -> Float {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(); return s[s.count / 2]
    }

    // ---- DC over ALL files ----
    var worstDC: Float = 0, worstDCFile = "", dcOver005 = 0
    // ---- seam over LOOPABLE files ----
    // Two ratios: vs MEDIAN adjacent step (ledger metric) and vs MAX interior
    // adjacent step. seam/maxInterior ≤ 1 proves the last→first wrap is no worse
    // than the roughest transition already inside the signal — i.e. the crossfade
    // added no discontinuity (for noise beds the seam is a genuine adjacent pair,
    // so it's naturally a noise-sized step and the median ratio can exceed 1).
    var worstMedRatio: Float = 0, worstMedFile = ""
    var worstMaxRatio: Float = 0, worstMaxFile = ""
    var worstJump: Float = 0, worstJumpFile = ""
    var jumpOver01 = 0, seamOverInterior = 0
    var loopCount = 0, scanned = 0
    var perCatWorstMed: [String: Float] = [:]

    for e in lib.entries {
        guard let chans = read(e) else { continue }
        scanned += 1
        for ch in chans {
            guard !ch.isEmpty else { continue }
            let mean = abs(ch.reduce(0, +) / Float(ch.count))
            if mean > worstDC { worstDC = mean; worstDCFile = e.file }
            if mean > 0.005 { dcOver005 += 1 }
        }
        if e.isLoopable {
            loopCount += 1
            for ch in chans where ch.count > 2 {
                let jump = abs(ch[0] - ch[ch.count - 1])                 // last → first wrap
                var diffs = [Float](); diffs.reserveCapacity(ch.count - 1)
                var maxStep: Float = 0
                for i in 1..<ch.count { let d = abs(ch[i] - ch[i - 1]); diffs.append(d); maxStep = max(maxStep, d) }
                let med = median(diffs)
                let medRatio = med > 1e-9 ? jump / med : 0
                let maxRatio = maxStep > 1e-9 ? jump / maxStep : 0
                if jump > worstJump { worstJump = jump; worstJumpFile = e.file }
                if medRatio > worstMedRatio { worstMedRatio = medRatio; worstMedFile = e.file }
                if maxRatio > worstMaxRatio { worstMaxRatio = maxRatio; worstMaxFile = e.file }
                if jump > 0.1 { jumpOver01 += 1 }
                if maxRatio > 1.0 { seamOverInterior += 1 }
                perCatWorstMed[e.category] = max(perCatWorstMed[e.category] ?? 0, medRatio)
            }
        }
    }

    print("── scanned \(scanned) files (\(loopCount) loopable)")
    print(String(format: "SEAM  worst |first−last|          = %.4f  (%@)", worstJump, worstJumpFile))
    print(String(format: "SEAM  worst seam/median-step      = %.2f× (%@)", worstMedRatio, worstMedFile))
    print(String(format: "SEAM  worst seam/MAX-interior-step = %.2f× (%@)  ← ≤1 ⇒ no added discontinuity", worstMaxRatio, worstMaxFile))
    print("SEAM  loopable chans seam > max-interior-step = \(seamOverInterior)")
    for (cat, r) in perCatWorstMed.sorted(by: { $0.key < $1.key }) {
        print(String(format: "SEAM    %@ worst seam/median = %.2f×", cat, r))
    }
    print(String(format: "DC    max |channel-mean|  = %.4f  (%@)", worstDC, worstDCFile))
    print("DC    files with |mean| > 0.005 = \(dcOver005)")
    // Pass criterion: DC removed, every seam ≤ the signal's own worst interior
    // step (crossfade added no discontinuity), AND — the A11 fix — every ABSOLUTE
    // |first−last| is tiny. The ratio test alone passed broadband rain despite an
    // audible periodic click (its interior noise steps are just as large); the
    // absolute gate is what actually proves the loop-seam weld worked.
    let seamOK = worstMaxRatio <= 1.05
    let absSeamOK = worstJump <= 0.03
    let dcOK = worstDC <= 0.006
    print((seamOK && absSeamOK && dcOK)
          ? "SCANSOUNDS: PASS"
          : "SCANSOUNDS: CHECK (seamOK=\(seamOK) absSeamOK=\(absSeamOK) dcOK=\(dcOK))")
    if !(seamOK && absSeamOK && dcOK) { exit(1) }
}

func cmdDevices() {
    let manager = CaptureDeviceManager()
    let devices = manager.allDevices()
    if devices.isEmpty { print("No cameras or audio-input devices connected.") }
    for d in devices {
        print("[\(d.kind.rawValue)] \(d.name)  id=\(d.id)")
        if let detail = d.detail { print("    \(detail)") }
    }
}

func cmdContent() async {
    print("Enumerating shareable content (this may trigger the Screen Recording permission prompt)…")
    do {
        let items = try await ScreenContentBrowser.descriptors()
        for d in items { print("[\(d.kind.rawValue)] \(d.name)  id=\(d.id)") }
        print("\(items.count) items")
    } catch { print("FAILED: \(error)"); exit(1) }
}

func cmdPipeline(seconds: Double, outPath: String) async throws {
    let camID = SourceID("synthetic.cam"), screenID = SourceID("synthetic.screen")
    let outURL = URL(fileURLWithPath: outPath)
    try? FileManager.default.removeItem(at: outURL)

    guard let device = MTLCreateSystemDefaultDevice() else { throw NSError(domain: "prism-dev", code: 1) }
    let compositor = try MetalCompositor(device: device, width: 1280, height: 720)
    let loop = RenderLoop(compositor: compositor, fps: 60)

    // Scene: full-frame "screen" + corner PiP "camera"
    loop.scene = Scene(name: "dev", layers: [
        Layer(sourceID: screenID, zIndex: 0),
        Layer(sourceID: camID, frame: CGRect(x: 0.7, y: 0.65, width: 0.28, height: 0.3), zIndex: 1),
    ])

    let camBox = FrameMailbox(), screenBox = FrameMailbox()
    loop.setMailbox(camBox, for: camID)
    loop.setMailbox(screenBox, for: screenID)

    let recorder = try MovieRecorder(
        url: outURL,
        settings: RecordingSettings(codec: .hevc, width: 1280, height: 720, includeAudio: false)
    )
    try recorder.start()
    loop.onProgramFrame = { frame in recorder.append(frame) }

    // Producers: cam at 30 fps, screen at 60 fps, animated colors
    let producerQueue = DispatchQueue(label: "prism-dev.producers")
    let camPool = try PixelBufferPool(width: 640, height: 360)
    let screenPool = try PixelBufferPool(width: 1280, height: 720)
    let running = OSAllocatedUnfairLock(initialState: true)
    func isRunning() -> Bool { running.withLock { $0 } }

    producerQueue.async {
        var i = 0
        while isRunning() {
            let pts = HouseClock.now()
            let phase = UInt8((i * 8) % 255)
            if let f = try? makeSolidFrame(pool: screenPool, rgba: (40, 40, phase, 255), pts: pts, source: screenID) {
                screenBox.post(f)
            }
            if i % 2 == 0, let f = try? makeSolidFrame(pool: camPool, rgba: (255 &- phase, 80, 80, 255), pts: pts, source: camID) {
                camBox.post(f)
            }
            i += 1
            usleep(16_667)
        }
    }

    print("Running \(seconds)s synthetic pipeline @60fps …")
    loop.start()
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    loop.stop()
    running.withLock { $0 = false }

    let stats = loop.stats
    let report = try await recorder.finish()
    print("RenderLoop: ticks=\(stats.ticks) delivered=\(stats.framesDelivered) errors=\(stats.compositeErrors) late=\(stats.lateTicks)")
    print("Recorder:   \(report)")

    // Independent verification: reopen the file and check duration + track
    let asset = AVURLAsset(url: outURL)
    let duration = try await asset.load(.duration).seconds
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let size = ((try? FileManager.default.attributesOfItem(atPath: outPath))?[.size] as? Int) ?? 0
    print("Verify:     \(outPath) duration=\(String(format: "%.2f", duration))s videoTracks=\(tracks.count) bytes=\(size)")
    let ok = duration > seconds * 0.8 && tracks.count == 1 && stats.compositeErrors == 0 && stats.framesDelivered > UInt64(seconds * 50)
    print(ok ? "PIPELINE: PASS" : "PIPELINE: FAIL")
    if !ok { exit(1) }
}

// MARK: - playfile command

/// Writes a BGRA IOSurface `VideoFrame`'s pixels to a PNG file.
func writeBGRAtoPNG(_ frame: VideoFrame, to url: URL) throws {
    let buffer = frame.pixelBuffer
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else {
        throw NSError(domain: "prism-dev.playfile", code: 1)
    }
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard let ctx = CGContext(data: base, width: frame.width, height: frame.height,
                              bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                              space: cs, bitmapInfo: info),
          let image = ctx.makeImage() else {
        throw NSError(domain: "prism-dev.playfile", code: 2)
    }
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "prism-dev.playfile", code: 3)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "prism-dev.playfile", code: 4)
    }
}

/// Coarse per-channel grid signature of a frame (for a memory-light meanDiff
/// between the dumped stills — we never retain whole frame buffers).
func gridSignature(_ frame: VideoFrame, cols: Int = 48, rows: Int = 27) -> [UInt8] {
    let buffer = frame.pixelBuffer
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return [] }
    let bpr = CVPixelBufferGetBytesPerRow(buffer)
    let w = frame.width, h = frame.height
    var out = [UInt8](); out.reserveCapacity(cols * rows * 3)
    for r in 0..<rows {
        let y = min(h - 1, r * h / rows)
        for c in 0..<cols {
            let x = min(w - 1, c * w / cols)
            let p = base + y * bpr + x * 4
            out.append(p[0]); out.append(p[1]); out.append(p[2])
        }
    }
    return out
}

func gridMeanDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var total = 0
    for i in 0..<a.count { total += abs(Int(a[i]) - Int(b[i])) }
    return Double(total) / Double(a.count)
}

/// Thread-safe dumper: on a schedule of wall-time points, writes spread PNG
/// stills from the compositor program output + records timing and meanDiff.
final class PlayfileDumper: @unchecked Sendable {
    private struct State {
        var next = 0
        var start: CFAbsoluteTime = 0
        var prevGrid: [UInt8] = []
        var records: [(idx: Int, ms: Double, meanDiff: Double, path: String)] = []
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let schedule: [Double]          // seconds-from-start dump points
    private let outDir: URL

    init(dumpCount: Int, seconds: Double, outDir: URL) {
        // Spread across [0.4 s … seconds], skipping the very first startup frame.
        let lo = min(0.4, seconds * 0.1), hi = seconds
        self.schedule = (0..<dumpCount).map { lo + (hi - lo) * Double($0) / Double(max(dumpCount - 1, 1)) }
        self.outDir = outDir
    }

    func begin() { lock.withLock { $0.start = CFAbsoluteTimeGetCurrent() } }

    func consider(_ frame: VideoFrame) {
        let now = CFAbsoluteTimeGetCurrent()
        let action: (idx: Int, ms: Double)? = lock.withLock { st in
            guard st.next < schedule.count else { return nil }
            let elapsed = now - st.start
            guard elapsed >= schedule[st.next] else { return nil }
            let idx = st.next
            st.next += 1
            return (idx, elapsed * 1000)
        }
        guard let (idx, ms) = action else { return }
        let path = outDir.appendingPathComponent(String(format: "frame_%02d.png", idx))
        let grid = gridSignature(frame)
        let diff = lock.withLock { st -> Double in
            let d = st.prevGrid.isEmpty ? 0 : gridMeanDiff(st.prevGrid, grid)
            st.prevGrid = grid
            return d
        }
        do {
            try writeBGRAtoPNG(frame, to: path)
            lock.withLock { $0.records.append((idx, ms, diff, path.path)) }
        } catch {
            print("  playfile: PNG write failed for frame \(idx): \(error)")
        }
    }

    var records: [(idx: Int, ms: Double, meanDiff: Double, path: String)] { lock.withLock { $0.records } }
}

/// Network-free proof: `MovieSource` → compositor → dump ~10 spread PNG frames
/// + per-frame timing + frame-to-frame meanDiff. Mirrors the `pipeline` dump.
func cmdPlayfile(path: String, seconds: Double, outDir: String) async throws {
    let expanded = (path as NSString).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: expanded) else {
        print("playfile: no such file '\(expanded)'"); exit(1)
    }
    let outURL = URL(fileURLWithPath: (outDir as NSString).expandingTildeInPath, isDirectory: true)
    try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

    guard let device = MTLCreateSystemDefaultDevice() else { throw NSError(domain: "prism-dev", code: 1) }
    let W = 1280, H = 720
    let compositor = try MetalCompositor(device: device, width: W, height: H)
    let loop = RenderLoop(compositor: compositor, fps: 60)
    let srcID = SourceID("playfile.movie")
    loop.scene = Scene(name: "playfile", layers: [Layer(sourceID: srcID, zIndex: 0)])
    let box = FrameMailbox()
    loop.setMailbox(box, for: srcID)

    // M7: a bad/audio-only file surfaces a TYPED SourceError (e.g.
    // `.mediaHasNoVideoTrack`). Catch it → clean one-line + exit 2, never a
    // top-level fatalError on user input.
    let movie: MovieSource
    do {
        movie = try MovieSource(id: srcID, fileURL: URL(fileURLWithPath: expanded),
                                canvasSize: CanvasSize(width: W, height: H),
                                contentMode: .aspectFit, loop: true)
    } catch let e as SourceError {
        print("playfile: \(e)"); exit(2)
    }
    print("playfile: \(expanded)")
    print("  native \(Int(movie.nativeSize.width))x\(Int(movie.nativeSize.height)) @\(String(format: "%.0f", movie.nominalFrameRate))fps, hasAudio=\(movie.hasAudioTrack)")
    let emitted = OSAllocatedUnfairLock(initialState: UInt64(0))
    movie.onFrame = { frame in emitted.withLock { $0 &+= 1 }; box.post(frame) }

    let dumper = PlayfileDumper(dumpCount: 10, seconds: seconds, outDir: outURL)
    loop.onProgramFrame = { frame in dumper.consider(frame) }

    dumper.begin()
    try movie.start()
    _ = loop.start()
    print("  playing \(String(format: "%.1f", seconds))s → \(W)x\(H) compositor, dumping 10 PNGs to \(outURL.path) …")
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    loop.stop()
    movie.stop()

    let stats = loop.stats
    let records = dumper.records.sorted { $0.idx < $1.idx }
    print("  MovieSource emitted=\(emitted.withLock { $0 }) frames; RenderLoop ticks=\(stats.ticks) delivered=\(stats.framesDelivered) errors=\(stats.compositeErrors)")
    for r in records {
        print(String(format: "    frame_%02d  t=%6.0fms  meanDiffVsPrev=%5.1f  %@", r.idx, r.ms, r.meanDiff, r.path))
    }
    let motion = records.dropFirst().map { $0.meanDiff }
    let maxMotion = motion.max() ?? 0
    let ok = records.count >= 8 && emitted.withLock { $0 } > 0 && stats.compositeErrors == 0 && maxMotion > 1.0
    print(String(format: "  PNGs=%d  maxMeanDiff=%.1f (motion proof: frames are NOT identical)", records.count, maxMotion))
    print(ok ? "PLAYFILE: PASS" : "PLAYFILE: FAIL")
    if !ok { exit(1) }
}

// MARK: - montage command

/// Build a `MontageSource` from real files (a folder is expanded to its media,
/// sorted) and dump spread PNG frames + per-frame timing/meanDiff — proving the
/// items actually cycle. Ken Burns + crossfade are on so the dump is lively.
func cmdMontage(inputs: [String], interval: Double, outDir: String) throws {
    // Expand folders → their image/video files (sorted); keep explicit files.
    var urls: [URL] = []
    let mediaExts: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tiff", "bmp",
                                  "mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg"]
    for raw in inputs {
        let path = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            print("montage: no such file/dir '\(path)'"); continue
        }
        if isDir.boolValue {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            for name in entries.sorted() where mediaExts.contains((name as NSString).pathExtension.lowercased()) {
                urls.append(URL(fileURLWithPath: path).appendingPathComponent(name))
            }
        } else {
            urls.append(URL(fileURLWithPath: path))
        }
    }
    guard !urls.isEmpty else { print("montage: no media files found in inputs"); exit(2) }
    // Cap so a huge folder still finishes quickly (dev harness).
    if urls.count > 8 { urls = Array(urls.prefix(8)) }

    let outURL = URL(fileURLWithPath: (outDir as NSString).expandingTildeInPath, isDirectory: true)
    try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
    if let old = try? FileManager.default.contentsOfDirectory(at: outURL, includingPropertiesForKeys: nil) {
        for f in old where f.pathExtension == "png" { try? FileManager.default.removeItem(at: f) }
    }

    let W = 1280, H = 720
    let montage: MontageSource
    do {
        montage = try MontageSource(id: SourceID("dev.montage"), urls: urls,
                                    canvasSize: CanvasSize(width: W, height: H),
                                    interval: interval, transition: .crossfade(duration: min(0.4, interval * 0.4)),
                                    kenBurns: true, shuffle: false, loop: true, fps: 30)
    } catch let e as SourceError {
        print("montage: \(e)"); exit(2)
    }
    print("montage: \(urls.count) items, interval \(String(format: "%.2f", interval))s, crossfade+KenBurns → \(W)x\(H)")
    for (i, u) in urls.enumerated() {
        print(String(format: "  [%d] %@  (%@)", i, u.lastPathComponent,
                     MontageSource.MontageItem.detect(url: u).kind == .video ? "video" : "image"))
    }

    // Thread-safe dumper: on a schedule of relative-time points, write PNGs +
    // record meanDiff-vs-prev (a spike ⇒ an item switch happened).
    final class Dumper: @unchecked Sendable {
        private struct S { var start: CFAbsoluteTime = 0; var next = 0; var prev: [UInt8] = []
                           var recs: [(idx: Int, ms: Double, diff: Double, tag: String)] = [] }
        private let lock = OSAllocatedUnfairLock(initialState: S())
        private let schedule: [Double]; private let outURL: URL
        init(count: Int, span: Double, outURL: URL) {
            self.schedule = (0..<count).map { 0.1 + (span - 0.1) * Double($0) / Double(max(count - 1, 1)) }
            self.outURL = outURL
        }
        func begin() { lock.withLock { $0.start = CFAbsoluteTimeGetCurrent() } }
        func consider(_ frame: VideoFrame) {
            let now = CFAbsoluteTimeGetCurrent()
            let hit: Int? = lock.withLock { st in
                guard st.next < schedule.count, now - st.start >= schedule[st.next] else { return nil }
                let i = st.next; st.next += 1; return i
            }
            guard let idx = hit else { return }
            let grid = gridSignature(frame)
            let diff = lock.withLock { st -> Double in
                let d = st.prev.isEmpty ? 0 : gridMeanDiff(st.prev, grid); st.prev = grid; return d
            }
            let path = outURL.appendingPathComponent(String(format: "montage_%02d.png", idx))
            do { try writeBGRAtoPNG(frame, to: path)
                 lock.withLock { $0.recs.append((idx, (now - $0.start) * 1000, diff, path.lastPathComponent)) }
            } catch { print("  montage: PNG write failed \(idx): \(error)") }
        }
        var records: [(idx: Int, ms: Double, diff: Double, tag: String)] { lock.withLock { $0.recs } }
    }

    let span = interval * Double(min(urls.count, 4)) + interval   // cover several switches
    let dumper = Dumper(count: 12, span: span, outURL: outURL)
    let emitted = OSAllocatedUnfairLock(initialState: UInt64(0))
    montage.onFrame = { frame in emitted.withLock { $0 &+= 1 }; dumper.consider(frame) }

    dumper.begin()
    try montage.start()
    print("  running \(String(format: "%.1f", span))s, dumping 12 PNGs to \(outURL.path) …")
    let deadline = Date().addingTimeInterval(span + 0.3)
    while Date() < deadline { usleep(20_000) }
    montage.stop()

    let recs = dumper.records.sorted { $0.idx < $1.idx }
    for r in recs {
        print(String(format: "    %@  t=%6.0fms  meanDiffVsPrev=%5.1f", r.tag, r.ms, r.diff))
    }
    let switches = recs.dropFirst().filter { $0.diff > 8 }.count
    let ok = recs.count >= 8 && emitted.withLock { $0 } > 0 && switches >= 1
    print(String(format: "  emitted=%d frames, PNGs=%d, item-switch spikes=%d (meanDiff>8 ⇒ montage advanced)",
                 emitted.withLock { $0 }, recs.count, switches))
    print(ok ? "MONTAGE: PASS" : "MONTAGE: FAIL")
    if !ok { exit(1) }
}

func cmdCapture(deviceID: String?, seconds: Double, outPath: String) async throws {
    let manager = CaptureDeviceManager()
    let cams = manager.allDevices().filter { $0.kind == .camera }
    guard !cams.isEmpty else {
        print("""
        No cameras connected. Options:
          • bring an iPhone near (same Apple ID, unlocked) for Continuity Camera
          • plug in a USB/UVC camera or HDMI capture card
        then re-run: prism-dev capture
        """)
        exit(1)
    }
    let chosen = deviceID.flatMap { id in cams.first { $0.id == id } } ?? cams[0]
    print("Using camera: \(chosen.name)  id=\(chosen.id)")

    let camera = try CameraSource(deviceID: chosen.id)
    for (i, f) in camera.formats.enumerated() { print("  format[\(i)] \(f)") }

    guard let device = MTLCreateSystemDefaultDevice() else { throw NSError(domain: "prism-dev", code: 1) }
    let compositor = try MetalCompositor(device: device, width: 1280, height: 720)
    let loop = RenderLoop(compositor: compositor, fps: 30)
    loop.scene = Scene(name: "capture", layers: [Layer(sourceID: camera.id)])

    let box = FrameMailbox()
    loop.setMailbox(box, for: camera.id)
    var received: UInt64 = 0
    let receivedLock = OSAllocatedUnfairLock(initialState: UInt64(0))
    camera.onFrame = { frame in
        receivedLock.withLock { $0 += 1 }
        box.post(frame)
    }

    let outURL = URL(fileURLWithPath: outPath)
    try? FileManager.default.removeItem(at: outURL)
    let recorder = try MovieRecorder(
        url: outURL,
        settings: RecordingSettings(codec: .hevc, width: 1280, height: 720, expectedFrameRate: 30, includeAudio: false)
    )
    try recorder.start()
    loop.onProgramFrame = { recorder.append($0) }

    print("Starting live capture for \(seconds)s (macOS may show the Camera permission prompt)…")
    try camera.start()
    loop.start()
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    loop.stop()
    camera.stop()
    received = receivedLock.withLock { $0 }

    let stats = loop.stats
    let report = try await recorder.finish()
    print("Camera frames received: \(received)")
    print("RenderLoop: ticks=\(stats.ticks) delivered=\(stats.framesDelivered) errors=\(stats.compositeErrors) late=\(stats.lateTicks)")
    print("Recorder:   \(report)")
    let asset = AVURLAsset(url: outURL)
    let duration = try await asset.load(.duration).seconds
    print("Verify:     \(outPath) duration=\(String(format: "%.2f", duration))s")
    let ok = received > 0 && duration > seconds * 0.6 && stats.compositeErrors == 0
    print(ok ? "CAPTURE: PASS" : "CAPTURE: FAIL (0 frames usually means the TCC prompt was denied or the device disappeared)")
    if !ok { exit(1) }
}

// MARK: - link-client (PrismLink loopback tester)

/// Polls `condition` (from THIS task, never from client callbacks — the
/// LinkClient synchronous accessors deadlock if called on its own queue)
/// until true or timeout.
func waitUntil(timeout: TimeInterval, every: TimeInterval = 0.05,
               _ condition: () -> Bool) async -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
    }
    return condition()
}

func cmdLinkClient(code: String, host: String, port: UInt16) async throws {
    print("link-client → \(host):\(port)  code=\(LinkPairing.display(code)) " +
          "(QUIC/TLS-1.3, code-bound hello proof)")

    let hello = LinkHello(name: "prism-dev", model: "cli-loopback",
                          maxWidth: 1280, maxHeight: 720, maxFps: 30)
    let client = LinkClient(configuration: .init(hello: hello, pairingCode: code))

    // Callback tallies (callbacks arrive on the client's queue; locks only,
    // no synchronous client accessors in here).
    let lastState = OSAllocatedUnfairLock<LinkClient.State>(initialState: .idle)
    let sawConnected = OSAllocatedUnfairLock(initialState: false)
    let gotSessionConfig = OSAllocatedUnfairLock<LinkSessionConfig?>(initialState: nil)
    let tallies = OSAllocatedUnfairLock(initialState: 0)
    let feedbacks = OSAllocatedUnfairLock(initialState: 0)
    let keyframeRequests = OSAllocatedUnfairLock(initialState: 0)

    client.onStateChange = { state in
        lastState.withLock { $0 = state }
        if state == .connected { sawConnected.withLock { $0 = true } }
        print("[client] state → \(state)")
    }
    client.onSessionConfig = { config in
        gotSessionConfig.withLock { $0 = config }
        print("[client] sessionConfig ← \(config.codec) \(config.width)x\(config.height)@\(config.fps) " +
              "target=\(config.targetBitrateBps)bps keyint=\(config.keyframeIntervalSeconds)s")
    }
    client.onTally = { tally in
        tallies.withLock { $0 += 1 }
        print("[client] tally ← program=\(tally.program) preview=\(tally.preview)")
    }
    client.onFeedback = { stats in
        feedbacks.withLock { $0 += 1 }
        print("[client] feedback ← loss=\(stats.lossPercent.map { "\($0)%" } ?? "–") " +
              "jitter=\(stats.jitterMs.map { "\($0)ms" } ?? "–")")
    }
    client.onKeyframeRequest = {
        keyframeRequests.withLock { $0 += 1 }
        print("[client] keyframeRequest ←")
    }
    client.onBitrateChange = { bps in print("[client] bitrate ladder → \(bps)bps") }

    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
        print("LINK-CLIENT: FAIL — bad port \(port)"); exit(1)
    }
    client.connect(to: .hostPort(host: NWEndpoint.Host(host), port: nwPort))

    // ── 1. QUIC/TLS handshake + control stream + hello ─────────────────────
    let connected = await waitUntil(timeout: 8) {
        lastState.withLock { $0 } != .idle && lastState.withLock { $0 } != .connecting
    }
    guard connected, lastState.withLock({ $0 }) == .connected else {
        if sawConnected.withLock({ $0 }) {
            print("LINK-CLIENT: FAIL — connected, then the server dropped the peer " +
                  "(wrong pairing code)")
        } else {
            print("LINK-CLIENT: FAIL — no connection (no server at that host:port, or " +
                  "handshake failed). Final state: \(lastState.withLock { $0 })")
        }
        exit(2)
    }
    print("✓ handshake: QUIC/TLS-1.3 tunnel up, control stream open, hello sent (challenge-nonce pairing)")

    // ── 1b. Pairing acceptance: a valid hello is answered with sessionConfig;
    //        a wrong code makes the server DROP the peer instead. ───────────
    _ = await waitUntil(timeout: 5) {
        gotSessionConfig.withLock { $0 } != nil || lastState.withLock { $0 } == .disconnected
    }
    guard gotSessionConfig.withLock({ $0 }) != nil else {
        let dropped = lastState.withLock { $0 } == .disconnected
        print("LINK-CLIENT: FAIL — hello not accepted" +
              (dropped ? " (server dropped the peer — wrong pairing code)" : " (timeout)"))
        exit(2)
    }
    print("✓ pairing: hello accepted, sessionConfig received")

    // ── 2. Clock sync convergence (8-ping burst at connect) ────────────────
    let clockLocked = await waitUntil(timeout: 5) { client.clockEstimate != nil }
    guard clockLocked, let estimate = client.clockEstimate else {
        print("LINK-CLIENT: FAIL — clock sync never produced an estimate")
        exit(3)
    }
    print(String(format: "✓ clock sync: offset=%.3fms skew=%.1fppm samples=%d " +
                 "(loopback ⇒ offset ≈ 0 expected)",
                 Double(estimate.offsetNanos) / 1e6, estimate.skewPPM, estimate.sampleCount))

    // ── 3. 60 synthetic frames → LowLatencyEncoder → media datagrams ───────
    let sessionConfig = gotSessionConfig.withLock { $0 }
    let encoder = try LowLatencyEncoder(configuration: .init(
        width: 1280, height: 720, fps: 30,
        averageBitrateBps: min(sessionConfig?.targetBitrateBps ?? 4_000_000, 8_000_000),
        keyframeIntervalSeconds: 1))
    let encodedCount = OSAllocatedUnfairLock(initialState: 0)
    let keyframeCount = OSAllocatedUnfairLock(initialState: 0)
    encoder.onEncodedFrame = { frame in
        encodedCount.withLock { $0 += 1 }
        if frame.isKeyframe { keyframeCount.withLock { $0 += 1 } }
        client.send(encoded: frame.annexB, pts: frame.pts, isKeyframe: frame.isKeyframe)
    }

    let pool = try PixelBufferPool(width: 1280, height: 720)
    let sourceID = SourceID("link-client.synthetic")
    print("sending 60 synthetic frames (solid colors, 1280x720@30, HEVC low-latency)…")
    for i in 0..<60 {
        let phase = UInt8((i * 17) % 255)
        let frame = try makeSolidFrame(pool: pool, rgba: (phase, 255 &- phase, 128, 255),
                                       pts: HouseClock.now(), source: sourceID)
        encoder.encode(pixelBuffer: frame.pixelBuffer, pts: frame.pts,
                       duration: CMTime(value: 1, timescale: 30))
        try await Task.sleep(nanoseconds: 33_000_000)
    }
    encoder.flush()
    // Let in-flight datagrams + any server feedback/tally land.
    try await Task.sleep(nanoseconds: 1_500_000_000)

    // ── 4. Final report ─────────────────────────────────────────────────────
    let stats = client.sendStats
    let encoded = encodedCount.withLock { $0 }
    let finalEstimate = client.clockEstimate
    print("""
    ── link-client final stats
       encoder:  frames=\(encoded) keyframes=\(keyframeCount.withLock { $0 }) dropped=\(encoder.framesDropped)
       sender:   datagrams=\(stats.datagramsSent) bytes=\(stats.bytesSent) \
    sendErrors=\(stats.datagramSendErrors) droppedAwaitingClock=\(stats.framesDroppedAwaitingClock)
       control:  sessionConfig=\(gotSessionConfig.withLock { $0 } != nil) tallies=\(tallies.withLock { $0 }) \
    feedback=\(feedbacks.withLock { $0 }) keyframeRequests=\(keyframeRequests.withLock { $0 })
       clock:    \(finalEstimate.map { String(format: "offset=%.3fms skew=%.1fppm samples=%d", Double($0.offsetNanos) / 1e6, $0.skewPPM, $0.sampleCount) } ?? "lost")
       ladder:   \(client.currentLadderBps)bps
    """)

    let stillConnected = lastState.withLock { $0 } == .connected
    let ok = stillConnected && encoded >= 50 && stats.datagramsSent >= UInt64(encoded)
        && stats.datagramSendErrors == 0 && gotSessionConfig.withLock { $0 } != nil
        && finalEstimate != nil
    client.disconnect()
    try await Task.sleep(nanoseconds: 200_000_000)
    print(ok ? "LINK-CLIENT: PASS" : "LINK-CLIENT: FAIL")
    if !ok { exit(1) }
}

func cmdLinkServer(code: String, port: UInt16) throws {
    let server = LinkServer(configuration: .init(port: port, pairingCode: code, advertise: false))
    server.onListenerStateChange = { state, port in
        print("[server] listener \(state)\(port.map { " on UDP \($0)" } ?? "")")
    }
    server.onPeerConnected = { peer in
        print("[server] peer connected: \(peer.id)")
        peer.onStateChange = { state in
            print("[server] peer \(peer.id) → \(state) (hello: \(peer.hello?.name ?? "-"))")
        }
        peer.videoSource.onFrame = { frame in
            _ = frame // count via mediaStats below; onFrame proves decode works
        }
        try? peer.videoSource.start()
    }
    server.onPeerDisconnected = { peer in
        // Server callbacks run on the server's queue; peer.mediaStats does
        // queue.sync on that same queue — hop off before touching it or the
        // whole link queue (listener included) deadlocks.
        DispatchQueue.main.async {
            let stats = peer.mediaStats
            print("[server] peer disconnected: \(peer.id) — parts=\(stats.partsReceived) " +
                  "framesCompleted=\(stats.framesCompleted) bytes=\(stats.bytesReceived) " +
                  "dropped=\(stats.framesDropped)")
        }
    }
    try server.start()
    print("link-server pairing code \(LinkPairing.display(code)) — Ctrl-C to stop")
    // Periodic stats so a driver script can watch frames arrive.
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 2, repeating: 2)
    timer.setEventHandler {
        for peer in server.peers {
            let stats = peer.mediaStats
            let clock = peer.clockEstimate
            print("[server] peer \(peer.hello?.name ?? peer.id.raw): " +
                  "parts=\(stats.partsReceived) frames=\(stats.framesCompleted) " +
                  "bytes=\(stats.bytesReceived) lost≈\(stats.estimatedDatagramsLost) " +
                  "clockSamples=\(clock?.sampleCount ?? 0)")
        }
    }
    timer.resume()
    withExtendedLifetime((server, timer)) { dispatchMain() }
}

final class DemoBackend: ControlBackend, @unchecked Sendable {
    var scene = "Main"
    func sceneList() async -> [String] { ["Main", "Interview", "BRB"] }
    func currentProgramScene() async -> String { scene }
    func setCurrentProgramScene(_ name: String) async throws { scene = name; print("[control] scene → \(name)") }
    func startRecord() async throws { print("[control] startRecord") }
    func stopRecord() async throws -> String? { print("[control] stopRecord"); return "/tmp/demo.mov" }
    func startStream() async throws { print("[control] startStream") }
    func stopStream() async throws { print("[control] stopStream") }
    func recordStatus() async -> RecordStatus { RecordStatus() }
    func streamStatus() async -> StreamStatus { StreamStatus() }
    func stats() async -> EngineStats { EngineStats() }
}

func cmdControl(port: UInt16) throws {
    let server = ControlServer(port: port)
    let backend = DemoBackend()
    server.backend = backend
    try server.start()
    print("obs-websocket v5 server on ws://127.0.0.1:\(port) (demo backend, no auth). Ctrl-C to stop.")
    dispatchMain()
}

// MARK: - Synthetic audio (dev-harness only: interleaved Float32, house-clock PTS)

/// Generates a stereo sine-tone `AudioPacket` stream (interleaved Float32,
/// 48 kHz, house-clock PTS). Fed into an `AudioMixer` channel so `onMasterMix`
/// produces a real program-audio feed for the stream's `append(audio:)`.
///
/// PTS is `base + sampleIndex/sampleRate` — monotonic and gap-free, so the
/// mixer's PTS-continuity tracking inserts no silence. (Not thread-safe; call
/// `next()` from one producer at a time, matching `MixerChannel.ingest`'s
/// contract.)
final class SyntheticToneGenerator: @unchecked Sendable {
    let sampleRate: Double
    let channelCount: Int
    let framesPerPacket: Int
    let frequency: Double
    let amplitude: Float

    private let source = SourceID("synthetic.tone")
    private let formatDescription: CMAudioFormatDescription
    private let base: CMTime
    private var sampleIndex: Int64 = 0          // total frames generated so far
    private(set) var lastPTS: CMTime = .invalid
    private(set) var monotonic = true           // strictly-increasing PTS?
    private(set) var produced: UInt64 = 0

    init(sampleRate: Double = 48_000, channelCount: Int = 2,
         framesPerPacket: Int = 1024, frequency: Double = 440,
         amplitude: Float = 0.25) throws {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.framesPerPacket = framesPerPacket
        self.frequency = frequency
        self.amplitude = amplitude
        self.formatDescription = try Self.makeFormatDescription(
            sampleRate: sampleRate, channelCount: channelCount)
        self.base = HouseClock.now()
    }

    /// Next packet (advances the sample clock). `nil` only if buffer minting
    /// fails (never on the happy path).
    func next() -> AudioPacket? {
        let frames = framesPerPacket
        var samples = [Float](repeating: 0, count: frames * channelCount)
        let w = 2.0 * Double.pi * frequency / sampleRate
        for f in 0..<frames {
            let v = Float(sin(w * Double(sampleIndex + Int64(f)))) * amplitude
            for c in 0..<channelCount { samples[f * channelCount + c] = v }
        }
        let pts = CMTimeAdd(base, CMTime(value: sampleIndex,
                                         timescale: CMTimeScale(sampleRate.rounded())))
        if lastPTS.isValid, CMTimeCompare(pts, lastPTS) <= 0 { monotonic = false }
        lastPTS = pts
        sampleIndex += Int64(frames)
        produced += 1
        guard let sb = try? Self.makeSampleBuffer(
            samples: samples, frameCount: frames, channelCount: channelCount,
            formatDescription: formatDescription, pts: pts) else { return nil }
        return AudioPacket(sampleBuffer: sb, source: source)
    }

    /// Packed interleaved Float32 LPCM format description.
    static func makeFormatDescription(sampleRate: Double, channelCount: Int) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channelCount),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channelCount),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0)
        var fd: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        guard status == noErr, let fd else {
            throw NSError(domain: "prism-dev.audio", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "CMAudioFormatDescriptionCreate failed"])
        }
        return fd
    }

    /// Copy interleaved Float32 frames into a ready `CMSampleBuffer`.
    static func makeSampleBuffer(samples: [Float], frameCount: Int, channelCount: Int,
                                 formatDescription: CMAudioFormatDescription,
                                 pts: CMTime) throws -> CMSampleBuffer {
        let byteCount = frameCount * channelCount * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw NSError(domain: "prism-dev.audio", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "CMBlockBufferCreate failed"])
        }
        status = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == kCMBlockBufferNoErr else {
            throw NSError(domain: "prism-dev.audio", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "CMBlockBufferReplaceDataBytes failed"])
        }
        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: formatDescription, sampleCount: frameCount,
            presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else {
            throw NSError(domain: "prism-dev.audio", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "CMAudioSampleBufferCreateReady failed"])
        }
        return sampleBuffer
    }
}

/// Synthetic program-audio rig: tone generator → `AudioMixer` channel →
/// master tap → `onProgramAudio`. Driven in **manual-rendering** mode (no
/// output device needed — works headless/over SSH), pumped at real-time cadence
/// on a private queue. The same queue is the sole caller of `ingest` and
/// `renderManually`, satisfying both single-caller contracts.
final class AudioProgramRig: @unchecked Sendable {
    let mixer: AudioMixer
    let channel: MixerChannel
    let gen: SyntheticToneGenerator

    let packetsTapped = OSAllocatedUnfairLock(initialState: UInt64(0)) // onMasterMix fires
    let tapMonotonic = OSAllocatedUnfairLock(initialState: true)
    private let lastTapPTS = OSAllocatedUnfairLock<CMTime>(initialState: .invalid)
    private let running = OSAllocatedUnfairLock(initialState: true)
    private let queue = DispatchQueue(label: "prism-dev.stream.audio")

    init(onProgramAudio: @escaping (CMSampleBuffer) -> Void) throws {
        gen = try SyntheticToneGenerator()
        mixer = AudioMixer()
        channel = try mixer.addChannel(id: SourceID("synthetic.tone"))
        let tapped = packetsTapped, tapMono = tapMonotonic, lastPTS = lastTapPTS
        mixer.onMasterMix = { packet in
            tapped.withLock { $0 &+= 1 }
            lastPTS.withLock { last in
                if last.isValid, CMTimeCompare(packet.pts, last) <= 0 { tapMono.withLock { $0 = false } }
                last = packet.pts
            }
            onProgramAudio(packet.sampleBuffer)
        }
    }

    func start() throws {
        try mixer.startManualRendering(maximumFrameCount: 4096)
        let running = self.running, gen = self.gen, channel = self.channel, mixer = self.mixer
        queue.async {
            while running.withLock({ $0 }) {
                if let pkt = gen.next() { channel.ingest(pkt) }
                _ = try? mixer.renderManually(frameCount: 1024)
                usleep(21_333) // ≈ 1024 frames @ 48 kHz
            }
        }
    }

    func stop() {
        running.withLock { $0 = false }
        queue.sync {}       // let the in-flight render iteration finish
        mixer.stop()
    }
}

/// Synthetic video rig: 2 animated sources → compositor → RenderLoop program
/// frames → ONE `ProgramEncoder` (H.264, realtime, ~2 s keyframe) →
/// `onEncodedVideo`. Same synthetic-source pattern as `cmdPipeline`.
final class StreamVideoRig: @unchecked Sendable {
    let encoder: ProgramEncoder
    let loop: RenderLoop
    let encodedFrames = OSAllocatedUnfairLock(initialState: UInt64(0))

    private let compositor: MetalCompositor
    private let camBox = FrameMailbox(), screenBox = FrameMailbox()
    private let camPool: PixelBufferPool, screenPool: PixelBufferPool
    private let camID = SourceID("synthetic.cam"), screenID = SourceID("synthetic.screen")
    private let liveCamID = SourceID("live.camera")
    private let producerQueue = DispatchQueue(label: "prism-dev.stream.producers")
    private let running = OSAllocatedUnfairLock(initialState: true)
    private let cameraDeviceID: String?
    private let movieFileURL: URL?
    private var camera: CameraSource?
    private var movie: MovieSource?

    init(width: Int, height: Int, fps: Double, cameraDeviceID: String? = nil,
         movieFileURL: URL? = nil,
         onEncodedVideo: @escaping (CMSampleBuffer) -> Void) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "prism-dev", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no Metal device"])
        }
        self.cameraDeviceID = cameraDeviceID
        self.movieFileURL = movieFileURL
        compositor = try MetalCompositor(device: device, width: width, height: height)
        loop = RenderLoop(compositor: compositor, fps: fps)
        if cameraDeviceID != nil || movieFileURL != nil {
            // Real camera OR a video FILE fills the frame — the true end-to-end
            // path. Both feed the single full-frame layer via `camBox`/`liveCamID`.
            loop.scene = Scene(name: "stream", layers: [Layer(sourceID: liveCamID, zIndex: 0)])
            loop.setMailbox(camBox, for: liveCamID)
        } else {
            loop.scene = Scene(name: "stream", layers: [
                Layer(sourceID: screenID, zIndex: 0),
                Layer(sourceID: camID, frame: CGRect(x: 0.7, y: 0.65, width: 0.28, height: 0.3), zIndex: 1),
            ])
            loop.setMailbox(camBox, for: camID)
            loop.setMailbox(screenBox, for: screenID)
        }
        camPool = try PixelBufferPool(width: 640, height: 360)
        screenPool = try PixelBufferPool(width: width, height: height)
        encoder = ProgramEncoder(settings: .init(
            codec: .h264, width: width, height: height, averageBitrate: 4_000_000,
            keyframeInterval: 2, expectedFrameRate: fps, lowLatencyRateControl: true))
        let counter = encodedFrames
        encoder.onEncodedFrame = { sb in counter.withLock { $0 &+= 1 }; onEncodedVideo(sb) }

        // M2: for a video FILE, build the single MovieSource HERE (not in start())
        // so a caller can attach `onAudio` to the SAME instance before start() —
        // one source, one loop anchor drives both video and audio (A/V sync).
        if let fileURL = movieFileURL {
            let src = try MovieSource(id: liveCamID, fileURL: fileURL,
                                      canvasSize: CanvasSize(width: width, height: height),
                                      contentMode: .aspectFit, loop: true)
            let camBox = self.camBox
            src.onFrame = { frame in camBox.post(frame) }
            movie = src
        }
    }

    /// The single file source (present only in `--file` mode). Attach `onAudio`
    /// to THIS instance before `start()` for A/V-synced audio (M2).
    var movieSource: MovieSource? { movie }

    func start() throws {
        try encoder.start()
        let encoder = self.encoder
        loop.onProgramFrame = { frame in try? encoder.encode(frame) }

        if let movie {
            // Video FILE → camBox (full-frame, letterboxed into the canvas, looped).
            // The single source was built in init(); `onAudio` (if any) is already
            // attached, so this one start() drives BOTH tracks off one anchor (M2).
            try movie.start()
        } else if let deviceID = cameraDeviceID {
            // Live camera → camBox (full-frame). No synthetic producer.
            let cam = try CameraSource(deviceID: deviceID)
            let liveCamID = self.liveCamID
            let camBox = self.camBox
            cam.onFrame = { frame in
                camBox.post(VideoFrame(pixelBuffer: frame.pixelBuffer, pts: frame.pts, source: liveCamID))
            }
            try cam.start()
            camera = cam
        } else {
            let running = self.running
            let screenPool = self.screenPool, camPool = self.camPool
            let screenBox = self.screenBox, camBox = self.camBox
            let screenID = self.screenID, camID = self.camID
            producerQueue.async {
                var i = 0
                while running.withLock({ $0 }) {
                    let pts = HouseClock.now()
                    let phase = UInt8((i * 8) % 255)
                    if let f = try? makeSolidFrame(pool: screenPool, rgba: (40, 40, phase, 255),
                                                   pts: pts, source: screenID) { screenBox.post(f) }
                    if i % 2 == 0, let f = try? makeSolidFrame(pool: camPool, rgba: (255 &- phase, 80, 80, 255),
                                                               pts: pts, source: camID) { camBox.post(f) }
                    i += 1
                    usleep(16_667)
                }
            }
        }
        _ = loop.start()
    }

    func stop() {
        loop.stop()
        camera?.stop()
        movie?.stop()
        running.withLock { $0 = false }
        producerQueue.sync {}
        encoder.flush()
        encoder.stop()
    }
}

/// Movie-file program-audio rig: the file's audio track (decoded by the SHARED
/// `MovieSource` that also drives video) → `AudioMixer` channel → master tap →
/// `onProgramAudio`. Mirrors `AudioProgramRig` but the packets come from the clip
/// instead of the synthetic tone, so `stream --file --audio` carries the movie's
/// real soundtrack. Driven in manual-rendering mode (headless-safe).
///
/// M2: this rig NO LONGER owns a `MovieSource`. It attaches `onAudio` to the
/// single source owned by `StreamVideoRig` (built in its init), so video and
/// audio share ONE loop anchor and start A/V-aligned. The video rig owns the
/// source's start()/stop() lifecycle; this rig only owns the mixer.
final class MovieAudioRig: @unchecked Sendable {
    let mixer: AudioMixer
    let channel: MixerChannel
    let packetsTapped = OSAllocatedUnfairLock(initialState: UInt64(0))
    private let running = OSAllocatedUnfairLock(initialState: true)
    private let queue = DispatchQueue(label: "prism-dev.stream.movieaudio")

    /// - Parameter movie: the shared file source (must have an audio track — the
    ///   caller preflights `hasAudioTrack` for the M8 video-only fallback).
    init(movie: MovieSource, onProgramAudio: @escaping (CMSampleBuffer) -> Void) throws {
        mixer = AudioMixer()
        channel = try mixer.addChannel(id: SourceID("movie.audio"))
        guard movie.hasAudioTrack else {
            throw SourceError.mediaHasNoVideoTrack(path: "audio track") // unreachable — caller preflights
        }
        let tapped = packetsTapped
        mixer.onMasterMix = { packet in
            tapped.withLock { $0 &+= 1 }
            onProgramAudio(packet.sampleBuffer)
        }
        let channel = self.channel
        // Attach onAudio to the SHARED source (set before its start()).
        movie.onAudio = { pkt in channel.ingest(pkt) }
    }

    func start() throws {
        try mixer.startManualRendering(maximumFrameCount: 4096)
        let running = self.running, mixer = self.mixer
        queue.async {
            while running.withLock({ $0 }) {
                _ = try? mixer.renderManually(frameCount: 1024)
                usleep(21_333) // ≈ 1024 frames @ 48 kHz
            }
        }
    }

    func stop() {
        running.withLock { $0 = false }
        queue.sync {}
        mixer.stop()
    }
}

// MARK: - stream command

/// Splits an RTMP ingest URL into HK's (app, streamKey): the stream key is the
/// last path component, the app is everything before it. `rtmp://h:1935/live/key`
/// → ("rtmp://h:1935/live", "key"); `rtmp://h:1935/key` → ("rtmp://h:1935", "key").
func splitRTMP(_ url: String) -> (app: String, key: String)? {
    guard let comps = URLComponents(string: url),
          let scheme = comps.scheme?.lowercased(),
          scheme == "rtmp" || scheme == "rtmps",
          let host = comps.host else { return nil }
    let portPart = comps.port.map { ":\($0)" } ?? ""
    let base = "\(scheme)://\(host)\(portPart)"
    let parts = comps.path.split(separator: "/").map(String.init)
    switch parts.count {
    case 0:  return (base, "prism")
    case 1:  return (base, parts[0])
    default: return (base + "/" + parts.dropLast().joined(separator: "/"), parts.last!)
    }
}

/// Prints the exact mediamtx + ffprobe/ffplay commands the operator runs to
/// receive & verify the wire this command produced.
func printOperatorCommands(mode: String, url: String) {
    print("── operator: receive + verify the wire (run these separately)")
    print("   1. start a LOCAL media server (defaults: RTMP :1935, SRT :8890/udp):")
    print("        mediamtx")
    switch mode {
    case "rtmp":
        print("   2. verify the published stream (RTMP):")
        print("        ffprobe -v error -show_streams -show_format \(url)")
        print("        ffplay \(url)")
    case "srt":
        let read = url.replacingOccurrences(of: "streamid=publish:", with: "streamid=read:")
        print("   2. verify the published stream (SRT — read side flips publish→read):")
        print("        ffprobe -v error -show_streams -show_format \"\(read)\"")
        print("        ffplay \"\(read)\"")
    default: // multi
        print("   2. verify the PRIMARY destination (same reader as its protocol above):")
        if url.lowercased().hasPrefix("srt") {
            let read = url.replacingOccurrences(of: "streamid=publish:", with: "streamid=read:")
            print("        ffprobe -v error -show_streams \"\(read)\"   # SRT read side")
        } else {
            print("        ffprobe -v error -show_streams \(url)")
        }
        print("      (the 'dead-isolation' destination is expected to fail — that IS the isolation proof)")
    }
}

/// Network-free proof the synthetic audio generator produces valid
/// CMSampleBuffers: manual-render the mixer for 1 s and assert the master tap
/// fired + PTS is monotonic. No server, no audio device.
func cmdStreamAudioCheck() async throws {
    print("── synthetic audio generator self-check (manual render — no server, no audio device)")
    let received = OSAllocatedUnfairLock(initialState: UInt64(0))
    let rig = try AudioProgramRig { _ in received.withLock { $0 &+= 1 } }
    try rig.start()
    try await Task.sleep(nanoseconds: 1_000_000_000)
    rig.stop()

    let tapped = rig.packetsTapped.withLock { $0 }
    let tapMono = rig.tapMonotonic.withLock { $0 }
    let got = received.withLock { $0 }
    print("   generator: packets=\(rig.gen.produced) genPTSMonotonic=\(rig.gen.monotonic)")
    print("   masterTap: onMasterMix fired=\(tapped) tapPTSMonotonic=\(tapMono) append(audio:)=\(got)")
    let ok = tapped > 0 && rig.gen.monotonic && tapMono && rig.gen.produced > 0 && got > 0
    print(ok ? "AUDIOCHECK: PASS" : "AUDIOCHECK: FAIL")
    if !ok { exit(1) }
}

func cmdStream(mode: String, url: String, seconds: Double, audio: Bool,
               cameraDeviceID: String? = nil, movieFileURL: URL? = nil) async throws {
    let width = 1280, height = 720, fps = 30.0

    // Shared teardown+report closure fills these in.
    var video: StreamVideoRig?
    var audioRig: AudioProgramRig?
    var movieAudioRig: MovieAudioRig?
    func stopAudio() { audioRig?.stop(); movieAudioRig?.stop() }
    func audioPacketCount() -> UInt64 {
        (audioRig?.packetsTapped.withLock { $0 }) ?? (movieAudioRig?.packetsTapped.withLock { $0 }) ?? 0
    }

    func runPipeline(appendVideo: @escaping (CMSampleBuffer) -> Void,
                     appendAudio: @escaping (CMSampleBuffer) -> Void) throws {
        video = try StreamVideoRig(width: width, height: height, fps: fps,
                                   cameraDeviceID: cameraDeviceID, movieFileURL: movieFileURL,
                                   onEncodedVideo: appendVideo)
        if audio {
            // --file --audio prefers the clip's own soundtrack; else synthetic tone.
            if movieFileURL != nil {
                // M8: preflight the SHARED source's audio track. If --audio was
                // asked for but the clip has none, warn and stream video-only
                // (typed, not a thrown NSError that unwinds the whole pipeline).
                if let src = video?.movieSource, src.hasAudioTrack {
                    let rig = try MovieAudioRig(movie: src) { sb in appendAudio(sb) }
                    try rig.start()
                    movieAudioRig = rig
                } else {
                    print("stream --file --audio: clip has no audio track — streaming video-only")
                }
            } else {
                let rig = try AudioProgramRig { sb in appendAudio(sb) }
                try rig.start()
                audioRig = rig
            }
        }
        try video!.start()
    }

    switch mode {
    case "rtmp":
        guard let (app, key) = splitRTMP(url) else {
            print("stream rtmp: bad URL '\(url)' (expected rtmp://host:1935/streamKey)"); exit(2)
        }
        let out = RTMPStreamOutput(settings: .init(
            codec: .h264, width: width, height: height, videoBitrate: 4_000_000,
            keyframeInterval: 2, expectedFrameRate: fps, lowLatencyRateControl: true))
        let transitions = OSAllocatedUnfairLock<[String]>(initialState: [])
        let stateTask = Task {
            for await s in await out.stateUpdates {
                transitions.withLock { $0.append("\(s)") }
                print("[state] \(s)")
            }
        }
        print("stream rtmp → app=\(app) streamKey=\(key)  audio=\(audio)")
        do {
            try await out.connect(url: app, streamKey: key)
        } catch {
            print("STREAM: connect FAILED — \(error)")
            stateTask.cancel(); exit(1)
        }
        try runPipeline(appendVideo: { out.append(encodedVideo: $0) },
                        appendAudio: { out.append(audio: $0) })
        print("streaming H.264\(audio ? "+AAC" : "") for \(seconds)s …")
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        video?.stop(); stopAudio()
        let stats = await out.stats()
        await out.close()
        stateTask.cancel()
        print("""
        ── stream rtmp final
           encoder:   sent=\(video?.encodedFrames.withLock { $0 } ?? 0) \
        submitted=\(video?.encoder.stats.framesSubmitted ?? 0) dropped=\(video?.encoder.stats.framesDropped ?? 0)
           audio:     packets=\(audioPacketCount()) enabled=\(audio)
           rtmp:      state=\(stats.state) bytesOut=\(stats.bytesOut) \
        videoAppended=\(stats.videoFramesAppended) audioAppended=\(stats.audioBuffersAppended) \
        dropped=\(stats.appendsDropped) reconnects=\(stats.reconnects)
           states:    \(transitions.withLock { $0 }.joined(separator: " → "))
        """)
        printOperatorCommands(mode: mode, url: url)
        let ok = (video?.encodedFrames.withLock { $0 } ?? 0) > 0
        print(ok ? "STREAM DONE" : "STREAM DONE (WARNING: zero frames encoded)")

    case "srt":
        let out = SRTStreamOutput(settings: .init(
            codec: .h264, width: width, height: height, videoBitrate: 4_000_000,
            keyframeInterval: 2, expectedFrameRate: fps, lowLatencyRateControl: true,
            includeAudio: audio))
        let transitions = OSAllocatedUnfairLock<[String]>(initialState: [])
        let stateTask = Task {
            for await s in await out.stateUpdates {
                transitions.withLock { $0.append("\(s)") }
                print("[state] \(s)")
            }
        }
        print("stream srt → \(url)  audio=\(audio)")
        do {
            try await out.connect(url: url, streamID: "")
        } catch {
            print("STREAM: connect FAILED — \(error)")
            stateTask.cancel(); exit(1)
        }
        try runPipeline(appendVideo: { out.append(encodedVideo: $0) },
                        appendAudio: { out.append(audio: $0) })
        print("streaming H.264\(audio ? "+AAC" : "") for \(seconds)s …")
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        video?.stop(); stopAudio()
        let stats = await out.stats()
        await out.close()
        stateTask.cancel()
        print("""
        ── stream srt final
           encoder:   sent=\(video?.encodedFrames.withLock { $0 } ?? 0) \
        submitted=\(video?.encoder.stats.framesSubmitted ?? 0) dropped=\(video?.encoder.stats.framesDropped ?? 0)
           audio:     packets=\(audioPacketCount()) enabled=\(audio)
           srt:       state=\(stats.state) bytesOut=\(stats.bytesOut) rttMs=\(String(format: "%.1f", stats.rttMs)) \
        sndLoss=\(stats.packetsSndLoss) retrans=\(stats.packetsRetransmitted)
           append:    video=\(stats.videoFramesAppended) audio=\(stats.audioBuffersAppended) \
        dropped=\(stats.appendsDropped) reconnects=\(stats.reconnects)
           states:    \(transitions.withLock { $0 }.joined(separator: " → "))
        """)
        printOperatorCommands(mode: mode, url: url)
        let ok = (video?.encodedFrames.withLock { $0 } ?? 0) > 0
        print(ok ? "STREAM DONE" : "STREAM DONE (WARNING: zero frames encoded)")

    case "multi":
        // Primary destination from the URL's scheme.
        let primary: Destination
        if url.lowercased().hasPrefix("srt") {
            primary = Destination(name: "primary", proto: .srt, url: url, key: "")
        } else if let (app, key) = splitRTMP(url) {
            primary = Destination(name: "primary", proto: .rtmp, url: app, key: key)
        } else {
            print("stream multi: bad URL '\(url)' (expected rtmp://… or srt://…)"); exit(2)
        }
        let bcast = MultiDestinationBroadcaster(videoSettings: .init(
            codec: .h264, width: width, height: height, videoBitrate: 4_000_000,
            keyframeInterval: 2, expectedFrameRate: fps, lowLatencyRateControl: true,
            includeAudio: audio))
        print("stream multi → primary=\(primary.proto.rawValue):\(url)  audio=\(audio)")
        let primaryID: UUID
        do {
            primaryID = try await bcast.add(primary)
        } catch {
            print("STREAM: primary connect FAILED — \(error)"); exit(1)
        }
        // A deliberately-dead second destination (localhost, no listener) proves
        // fault isolation: its connect fails fast, the primary keeps streaming.
        let dead = Destination(name: "dead-isolation", proto: .rtmp,
                               url: "rtmp://127.0.0.1:1", key: "dead")
        do {
            _ = try await bcast.add(dead)
            print("[multi] dead destination unexpectedly connected")
        } catch {
            print("[multi] dead destination failed to connect (EXPECTED) — primary is isolated, keeps streaming")
        }
        try runPipeline(appendVideo: { bcast.broadcast(encodedVideo: $0) },
                        appendAudio: { bcast.broadcast(audio: $0) })
        print("streaming H.264\(audio ? "+AAC" : "") for \(seconds)s …")
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        video?.stop(); stopAudio()
        let fan = await bcast.fanOutStats()
        let per = await bcast.statsByDestination()
        await bcast.shutdown()
        print("""
        ── stream multi final
           encoder:   sent=\(video?.encodedFrames.withLock { $0 } ?? 0) \
        submitted=\(video?.encoder.stats.framesSubmitted ?? 0) dropped=\(video?.encoder.stats.framesDropped ?? 0)
           audio:     packets=\(audioPacketCount()) enabled=\(audio)
           fan-out:   videoFanned=\(fan.videoFramesFanned) audioFanned=\(fan.audioBuffersFanned) \
        destinations=\(fan.destinationCount) enabled=\(fan.enabledCount)
        """)
        for (id, s) in per {
            let tag = id == primaryID ? "primary" : "dead-isolation"
            print("   dest[\(tag)]: state=\(s.state) bytesOut=\(s.bytesOut) " +
                  "videoAppended=\(s.videoFramesAppended) audioAppended=\(s.audioBuffersAppended) " +
                  "dropped=\(s.appendsDropped) reconnects=\(s.reconnects)")
        }
        printOperatorCommands(mode: mode, url: url)
        let ok = (video?.encodedFrames.withLock { $0 } ?? 0) > 0
        print(ok ? "STREAM DONE" : "STREAM DONE (WARNING: zero frames encoded)")

    default:
        print("stream: unknown mode '\(mode)' (use rtmp | srt | multi | audiocheck)\n\n\(usage)")
        exit(1)
    }
}

// MARK: - Deterministic A/V verification

/// Parse the harness's published seed syntax without accepting a bare `0x`.
func parseAVRoundTripSeed(_ value: String) -> UInt64? {
    let lower = value.lowercased()
    if lower.hasPrefix("0x") {
        let digits = lower.dropFirst(2)
        guard !digits.isEmpty else { return nil }
        return UInt64(digits, radix: 16)
    }
    return UInt64(value, radix: 10)
}

/// Live RTMP loopback harness (feasibility path a): the deterministic oracle
/// sequence → production RTMPStreamOutput (FLV mux) → real RTMP socket → headless
/// MediaMTX → recording → decode + live oracle. Auto-skips (exit 0) when the
/// mediamtx/ffmpeg toolchain is missing. The reconnect / slow-consumer / real
/// ingest cases need a provisioned server — use `prism-dev stream rtmp <url>`.
func cmdRTMPLoopback(seed: UInt64) async {
    var configuration = AVRoundTripConfiguration()
    configuration.seed = seed
    print("── live RTMP loopback (seed=0x\(String(seed, radix: 16)))")
    print("   mediamtx: \(RTMPLoopbackRunner.locateMediaMTX()?.path ?? "NOT FOUND")")
    print("   ffmpeg:   \(RTMPLoopbackRunner.locateFFmpeg()?.path ?? "NOT FOUND")")
    do {
        let r = try await RTMPLoopbackRunner.run(configuration: configuration)
        let d = r.diagnostics
        print("   rtmp url: \(d.rtmpURL)")
        print("   states:   \(d.publishStates.joined(separator: " → "))")
        print("   published=\(d.publishedFrameCount) captured=\(d.capturedFrameCount) "
              + "verifiedRun=\(d.verifiedRunLength) fullSequence=\(d.fullSequenceCaptured)")
        print("   \(r.verification.description)")
        for line in r.verification.evidenceLines { print("   \(line)") }
        print("   recording: \(r.recordingURL.path)")
        print("   movie:     \(r.movieURL.path)")
        // Prove the live oracle rejects a corrupted capture.
        for fault in [AVRoundTripFault.frameDrop, .truncateTail, .rangeTagSwap] {
            let rejected = (try? AVRoundTripOracle.verify(r.evidence.injecting(fault),
                                                          gates: RTMPLoopbackRunner.liveGates)) == nil
            print("   negative-control \(fault.rawValue): \(rejected ? "REJECTED ✓" : "ACCEPTED ✗")")
        }
        print("RTMP-LOOPBACK: PASS (live socket verified; reconnect/slow-consumer/real-ingest → operator)")
    } catch let e as RTMPLoopbackRunner.LoopbackError where e.isInfrastructureUnavailable {
        print("RTMP-LOOPBACK: SKIP — \(e)")
    } catch {
        print("RTMP-LOOPBACK: FAIL — \(error)")
        exit(1)
    }
}

func cmdAVRoundtrip(seed: UInt64, evidenceRoot: String?) async {
    var configuration = AVRoundTripConfiguration()
    configuration.seed = seed
    let rootURL = evidenceRoot.map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
    }

    print("── deterministic A/V round-trip (seed=\(seed), 0x\(String(seed, radix: 16)))")
    do {
        let result = try await AVRoundTripRunner.run(
            configuration: configuration,
            artifactRoot: rootURL
        )
        print("   \(result.verification.description)")
        for line in result.verification.evidenceLines { print("   \(line)") }
        print("   evidence: \(result.artifact.evidenceURL.path)")
        print("   movie:    \(result.movieURL.path)")
        print("AV-ROUNDTRIP: PASS")
    } catch {
        print("AV-ROUNDTRIP: FAIL — \(error)")
        exit(1)
    }
}

// MARK: - Entry

setbuf(stdout, nil) // dev harness output is often piped/teed — keep it live

let args = CommandLine.arguments.dropFirst()
guard let command = args.first else { print(usage); exit(0) }

switch command {
case "selftest":
    try await cmdSelftest()
case "gensounds":
    let rest = Array(args.dropFirst())
    let count = rest.first.flatMap { Int($0) }
    let dir = rest.first(where: { Int($0) == nil })
    try await cmdGensounds(count: count, dir: dir)
case "scansounds":
    let dir = args.dropFirst().first
    try cmdScanSounds(dir: dir)
case "devices":
    cmdDevices()
case "content":
    await cmdContent()
case "pipeline":
    let secs = args.dropFirst().first.flatMap(Double.init) ?? 3.0
    let out = args.dropFirst(2).first ?? "/tmp/prism_pipeline_test.mov"
    try await cmdPipeline(seconds: secs, outPath: out)
case "av-roundtrip":
    let rest = Array(args.dropFirst())
    guard rest.count <= 2 else {
        print("av-roundtrip accepts at most [seed] [evidenceRoot]\n\n\(usage)")
        exit(2)
    }
    let seed: UInt64
    if let rawSeed = rest.first {
        guard let parsed = parseAVRoundTripSeed(rawSeed) else {
            print("av-roundtrip: malformed seed '\(rawSeed)' (use decimal or 0x-prefixed hex)")
            exit(2)
        }
        seed = parsed
    } else {
        seed = AVRoundTripConfiguration().seed
    }
    let evidenceRoot = rest.count == 2 ? rest[1] : nil
    await cmdAVRoundtrip(seed: seed, evidenceRoot: evidenceRoot)
case "rtmp-loopback":
    let rest = Array(args.dropFirst())
    let seedArg = rest.first(where: { !$0.hasPrefix("--") })
    let seed = seedArg.flatMap(parseAVRoundTripSeed) ?? AVRoundTripConfiguration().seed
    await cmdRTMPLoopback(seed: seed)
case "playfile":
    let rest = Array(args.dropFirst())
    guard let path = rest.first, !path.isEmpty else {
        print("playfile needs a <path> to a video file\n\n\(usage)"); exit(1)
    }
    let secs = rest.count > 1 ? (Double(rest[1]) ?? 6.0) : 6.0
    let out = rest.count > 2 ? rest[2] : NSTemporaryDirectory() + "prism_playfile"
    try await cmdPlayfile(path: path, seconds: secs, outDir: out)
case "montage":
    let rest = Array(args.dropFirst())
    guard !rest.isEmpty else {
        print("montage needs <dir_or_files...> [interval] [outDir]\n\n\(usage)"); exit(1)
    }
    // Partition: existing files/dirs → inputs; a bare number → interval; a
    // remaining non-existent path → outDir.
    var inputs: [String] = [], interval = 1.5, outDir = NSTemporaryDirectory() + "prism_montage"
    var sawInterval = false
    for a in rest {
        let expanded = (a as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            inputs.append(a)
        } else if !sawInterval, let d = Double(a) {
            interval = d; sawInterval = true
        } else {
            outDir = a
        }
    }
    try cmdMontage(inputs: inputs, interval: interval, outDir: outDir)
case "capture":
    let rest = Array(args.dropFirst())
    // Heuristic: a first arg that parses as a number is the duration, not a device id
    let idArg = rest.first.flatMap { Double($0) == nil ? $0 : nil }
    let numeric = rest.filter { Double($0) != nil }
    let secs = numeric.first.flatMap(Double.init) ?? 5.0
    let out = rest.first { $0.hasSuffix(".mov") } ?? "/tmp/prism_capture_test.mov"
    try await cmdCapture(deviceID: idArg == out ? nil : idArg, seconds: secs, outPath: out)
case "control":
    let port = args.dropFirst().first.flatMap(UInt16.init) ?? 4455
    try cmdControl(port: port)
case "link-client":
    let rest = Array(args.dropFirst())
    guard let code = rest.first, !code.isEmpty else {
        print("link-client needs the pairing code shown in Prism's sidebar\n\n\(usage)"); exit(1)
    }
    let host = rest.count > 1 ? rest[1] : "127.0.0.1"
    guard let port = rest.count > 2 ? UInt16(rest[2]) : nil else {
        print("link-client needs the server port (Prism logs it; Bonjour carries it for real devices)")
        exit(1)
    }
    try await cmdLinkClient(code: code, host: host, port: port)
case "link-server":
    let rest = Array(args.dropFirst())
    guard let code = rest.first, !code.isEmpty else {
        print("link-server needs a pairing code\n\n\(usage)"); exit(1)
    }
    let port = rest.count > 1 ? (UInt16(rest[1]) ?? 0) : 0
    try cmdLinkServer(code: code, port: port)
case "stream":
    let rest = Array(args.dropFirst())
    guard let mode = rest.first else {
        print("stream needs a mode: rtmp | srt | multi | audiocheck\n\n\(usage)"); exit(1)
    }
    if mode == "audiocheck" {
        try await cmdStreamAudioCheck()
        break
    }
    guard rest.count > 1, !rest[1].isEmpty else {
        print("stream \(mode) needs a <url> (point it at a LOCAL mediamtx)\n\n\(usage)"); exit(1)
    }
    let streamURL = rest[1]
    let positional = rest.dropFirst(2).filter { !$0.hasPrefix("--") }
    let secs = positional.first.flatMap(Double.init) ?? 10.0
    let wantAudio = rest.contains("--audio")
    // --camera: stream the FIRST real camera (StreamCam) full-frame instead of
    // synthetic sources — the true camera→compositor→encode→RTMP path.
    var camID: String? = nil
    if rest.contains("--camera") {
        let cams = CaptureDeviceManager().allDevices().filter { $0.kind == .camera }
        guard let cam = cams.first else { print("stream --camera: no camera connected"); exit(2) }
        print("stream --camera → \(cam.name) (id=\(cam.id))")
        camID = cam.id
    }
    // --file <path>: stream a downloaded VIDEO FILE full-frame (letterboxed,
    // looped) instead of the camera/synthetic source. Takes precedence over
    // --camera. With --audio the clip's own soundtrack is used.
    var movieURL: URL? = nil
    if let fi = rest.firstIndex(of: "--file") {
        guard fi + 1 < rest.count else { print("stream --file needs a <path>"); exit(2) }
        let path = (rest[fi + 1] as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            print("stream --file: no such file '\(path)'"); exit(2)
        }
        movieURL = URL(fileURLWithPath: path)
        print("stream --file → \(path)")
    }
    try await cmdStream(mode: mode, url: streamURL, seconds: secs, audio: wantAudio,
                        cameraDeviceID: movieURL == nil ? camID : nil, movieFileURL: movieURL)
default:
    print(usage); exit(1)
}
