import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import os
import PrismCompositor
import PrismCore
import PrismOutput

// 4K60 multi-source stress benchmark, judged over N independent runs.
//
// Per run: 8 synthetic 4K sources (4 × BGRA + 4 × 420f biplanar YUV — the two
// real capture pixel-paths) posting at 60 fps from their own threads →
// mailboxes → MetalCompositor (4K program, 2×4 grid = full-frame fragment
// load) → RenderLoop 60 fps → HEVC MovieRecorder. Source buffers are
// pre-filled once and cycled (CPU can't memset 8×4K×60fps; capture hardware
// doesn't either — DMA delivers, so cycling matches the real cost model).
//
// Judge criteria (every run must pass ALL):
//   delivered ≥ 98% of expected ticks · late ticks ≤ 2% · composite errors = 0
//   recorder drops ≤ 1% · file duration within ±15% · file has 1 video track

struct BenchRun {
    var index: Int
    var delivered: UInt64 = 0
    var expected: Double = 0
    var late: UInt64 = 0
    var errors: UInt64 = 0
    var recorded: UInt64 = 0
    var dropped: UInt64 = 0
    var fileDuration: Double = 0
    var observedFPS: Double = 0
    var pass = false
    var reasons: [String] = []
}

private final class BenchSource {
    let id: SourceID
    let mailbox = FrameMailbox()
    private var buffers: [CVPixelBuffer] = []
    private var thread: Thread?
    private let running = OSAllocatedUnfairLock(initialState: false)

    init(index: Int, yuv: Bool, width: Int, height: Int) throws {
        id = SourceID("bench.\(yuv ? "420f" : "bgra").\(index)")
        let format = yuv ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_32BGRA
        let pool = try PixelBufferPool(width: width, height: height, pixelFormat: format, minimumBufferCount: 4)
        for v in 0..<4 {
            let buf = try pool.makeBuffer()
            Self.fill(buf, yuv: yuv, variant: v, sourceIndex: index)
            buffers.append(buf)
        }
    }

    private static func fill(_ buf: CVPixelBuffer, yuv: Bool, variant: Int, sourceIndex: Int) {
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        if yuv {
            let yBase = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!
            let yRows = CVPixelBufferGetHeightOfPlane(buf, 0)
            let yBPR = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
            memset(yBase, Int32(60 + variant * 40), yRows * yBPR)
            let cBase = CVPixelBufferGetBaseAddressOfPlane(buf, 1)!
            let cRows = CVPixelBufferGetHeightOfPlane(buf, 1)
            let cBPR = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
            memset(cBase, Int32(96 + sourceIndex * 24), cRows * cBPR)
        } else {
            let base = CVPixelBufferGetBaseAddress(buf)!
            let size = CVPixelBufferGetHeight(buf) * CVPixelBufferGetBytesPerRow(buf)
            memset(base, Int32((sourceIndex * 48 + variant * 16) & 0xFF), size)
        }
    }

    func start(fps: Double) {
        running.withLock { $0 = true }
        let interval = UInt32(1_000_000.0 / fps)
        let t = Thread { [self] in
            var i = 0
            while running.withLock({ $0 }) {
                let frame = VideoFrame(pixelBuffer: buffers[i % buffers.count], pts: HouseClock.now(), source: id)
                mailbox.post(frame)
                i += 1
                usleep(interval)
            }
        }
        t.name = "bench.\(id.raw)"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    func stop() { running.withLock { $0 = false } }
}

func cmdBench(runs: Int, seconds: Double) async throws {
    let width = 3840, height = 2160
    let fps = 60.0
    let perKind = 4

    guard let device = MTLCreateSystemDefaultDevice() else { throw NSError(domain: "prism-dev", code: 2) }
    print("BENCH: \(runs) judged runs × \(seconds)s — \(perKind)×BGRA + \(perKind)×420f sources at \(width)×\(height), program \(width)×\(height)@\(Int(fps)) + HEVC record")
    print("Metal device: \(device.name)")

    // Sources + grid scene are shared across runs (capture rig doesn't restart between takes)
    var sources: [BenchSource] = []
    for i in 0..<perKind { sources.append(try BenchSource(index: i, yuv: false, width: width, height: height)) }
    for i in 0..<perKind { sources.append(try BenchSource(index: i, yuv: true, width: width, height: height)) }

    // 2 rows × 4 cols — full program area covered, all 8 4K textures sampled per frame
    var layers: [Layer] = []
    for (i, s) in sources.enumerated() {
        let col = i % 4, row = i / 4
        layers.append(Layer(sourceID: s.id,
                            frame: CGRect(x: Double(col) * 0.25, y: Double(row) * 0.5, width: 0.25, height: 0.5),
                            zIndex: i))
    }
    let scene = Scene(name: "bench-grid", layers: layers)

    let compositor = try MetalCompositor(device: device, width: width, height: height)
    for s in sources { s.start(fps: fps) }
    defer { for s in sources { s.stop() } }

    var results: [BenchRun] = []
    for runIdx in 1...runs {
        let outPath = "/tmp/prism_bench_run.mov"
        try? FileManager.default.removeItem(atPath: outPath)

        let loop = RenderLoop(compositor: compositor, fps: fps)
        loop.scene = scene
        for s in sources { loop.setMailbox(s.mailbox, for: s.id) }

        let recorder = try MovieRecorder(
            url: URL(fileURLWithPath: outPath),
            settings: RecordingSettings(codec: .hevc, width: width, height: height,
                                        videoBitrate: 30_000_000, expectedFrameRate: fps, includeAudio: false)
        )
        try recorder.start()
        loop.onProgramFrame = { recorder.append($0) }

        loop.start()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        loop.stop()

        var run = BenchRun(index: runIdx)
        let stats = loop.stats
        run.delivered = stats.framesDelivered
        run.expected = seconds * fps
        run.late = stats.lateTicks
        run.errors = stats.compositeErrors

        let report = try await recorder.finish()
        run.recorded = report.videoFramesWritten
        run.dropped = report.videoFramesDropped

        let asset = AVURLAsset(url: URL(fileURLWithPath: outPath))
        run.fileDuration = try await asset.load(.duration).seconds
        let trackCount = try await asset.loadTracks(withMediaType: .video).count
        run.observedFPS = run.fileDuration > 0 ? Double(run.recorded) / run.fileDuration : 0

        // Judge — delivered is bounded BOTH ways against the file's actual
        // duration (cold-audit finding: nominal-only lower bound let overshoot pass unexamined)
        let durExpected = run.fileDuration > 0 ? run.fileDuration * fps : run.expected
        if Double(run.delivered) < 0.98 * durExpected || Double(run.delivered) > 1.04 * durExpected {
            run.reasons.append("delivered \(run.delivered) vs duration-expected \(Int(durExpected))")
        }
        if Double(run.late) > 0.02 * run.expected { run.reasons.append("late \(run.late)") }
        if run.errors > 0 { run.reasons.append("errors \(run.errors)") }
        if run.recorded > 0, Double(run.dropped) > 0.01 * Double(run.recorded + run.dropped) { run.reasons.append("drops \(run.dropped)") }
        if abs(run.fileDuration - seconds) > 0.15 * seconds { run.reasons.append("duration \(String(format: "%.2f", run.fileDuration))s") }
        if trackCount != 1 { run.reasons.append("tracks \(trackCount)") }
        run.pass = run.reasons.isEmpty
        results.append(run)

        let mark = run.pass ? "PASS" : "FAIL"
        print(String(format: "run %2d/%d  %@  delivered %3d/%3d  late %2d  err %d  rec %3d  drop %d  file %.2fs (%.1f fps)%@",
                     runIdx, runs, mark, run.delivered, Int(run.expected), run.late, run.errors,
                     run.recorded, run.dropped, run.fileDuration, run.observedFPS,
                     run.reasons.isEmpty ? "" : "  ← " + run.reasons.joined(separator: ", ")))
    }
    try? FileManager.default.removeItem(atPath: "/tmp/prism_bench_run.mov")

    // Aggregate judgement
    let passes = results.filter(\.pass).count
    let deliveredPcts = results.map { Double($0.delivered) / $0.expected * 100 }.sorted()
    let totalLate = results.reduce(0) { $0 + $1.late }
    let totalErr = results.reduce(0) { $0 + $1.errors }
    let totalDrop = results.reduce(0) { $0 + $1.dropped }
    print("""

    ── AGGREGATE (\(runs) runs × \(Int(seconds))s, 8×4K sources → 4K\(Int(fps)) program + HEVC record)
    passes:      \(passes)/\(runs)
    delivered:   min \(String(format: "%.1f", deliveredPcts.first ?? 0))% · median \(String(format: "%.1f", deliveredPcts[deliveredPcts.count / 2]))% · max \(String(format: "%.1f", deliveredPcts.last ?? 0))%
    late ticks:  \(totalLate) total across all runs
    composite errors: \(totalErr) · recorder drops: \(totalDrop)
    VERDICT: \(passes == runs ? "PASS — all \(runs) judged runs met all criteria" : "FAIL — \(runs - passes) run(s) missed criteria")
    """)
    if passes != runs { exit(1) }
}
