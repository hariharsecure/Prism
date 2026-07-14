import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import os
import PrismCore
import UniformTypeIdentifiers

/// Headless self-verification of `CharacterSource`'s animation depth (DESIGN §3):
/// **lip-sync**, **auto-blink**, **richer reactions (overshoot/settle)** and
/// **entrance/exit**. All deterministic — the drawing is driven through
/// `renderComposite(_:)` with crafted `AnimParams`, plus one live-source pass to
/// prove the lifecycle still emits IOSurface BGRA frames.
///
/// Asserts on real pixels / envelope values, and DUMPS eyeball PNGs to:
///   …/scratchpad/prism_character_anim/
///
/// TEST CODE ONLY: locks pixel-buffer base addresses to read back output (the
/// engine hot path never does).
public enum CharacterSelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case setupFailed(String)
        case mismatch(String)
        public var description: String {
            switch self {
            case .setupFailed(let s): return "character self-test setup failed: \(s)"
            case .mismatch(let s):    return "character self-test mismatch: \(s)"
            }
        }
    }

    public static let pngDumpDir =
        "/tmp/prism_character_anim"

    private static let W = 480, H = 270

    public static func run() throws {
        let outDir = URL(fileURLWithPath: pngDumpDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        if let old = try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil) {
            for f in old where f.pathExtension == "png" { try? FileManager.default.removeItem(at: f) }
        }

        try testLiveEmission()
        try testLipSync(outDir)
        try testLipSyncCrossfadeNonCoincident(outDir)
        try testAutoBlink(outDir)
        try testReactionOvershoot(outDir)
        try testEntrance(outDir)
        print("CharacterSelfTest: all checks passed — PNGs at \(pngDumpDir)")
    }

    // MARK: - 1. Lifecycle: live source still emits IOSurface BGRA

    private static func testLiveEmission() throws {
        let source = try CharacterSource(id: SourceID("selftest.character.live"),
                                         canvasSize: CanvasSize(width: W, height: H), fps: 60)
        let collector = Collector()
        source.onFrame = { collector.add($0) }
        try source.start()
        defer { source.stop() }
        guard poll(2.0, { collector.count > 0 }), let f = collector.latest else {
            throw SelfTestError.mismatch("live: no frame emitted within 2s")
        }
        guard f.width == W, f.height == H else {
            throw SelfTestError.mismatch("live: frame \(f.width)x\(f.height), expected \(W)x\(H)")
        }
        guard f.pixelFormat == kCVPixelFormatType_32BGRA else {
            throw SelfTestError.mismatch("live: pixel format \(f.pixelFormat), expected BGRA")
        }
        guard CVPixelBufferGetIOSurface(f.pixelBuffer) != nil else {
            throw SelfTestError.mismatch("live: frame is NOT IOSurface-backed (zero-copy violation)")
        }
        // Lifecycle discipline: no frames after stop.
        source.stop()
        let n = collector.count
        _ = poll(0.2, { false })
        guard collector.count == n else {
            throw SelfTestError.mismatch("live: source emitted \(collector.count - n) frame(s) after stop()")
        }
        print("  ✓ live: \(W)x\(H) IOSurface BGRA, no frames after stop")
    }

    // MARK: - 2. Lip-sync: openness maps to a mouth opening

    private static func testLipSync(_ outDir: URL) throws {
        let c = try CharacterSource(id: SourceID("selftest.character.lipsync"),
                                    canvasSize: CanvasSize(width: W, height: H), fps: 60)
        let closed = try c.renderComposite(params(mouthOpenness: 0, lipSync: true))
        let open   = try c.renderComposite(params(mouthOpenness: 1, lipSync: true))

        // Mouth region changes strongly; a control region (forehead) barely moves.
        let mouthDiff    = boxMeanDiff(closed, open, 0.40, 0.44, 0.60, 0.62)
        let foreheadDiff = boxMeanDiff(closed, open, 0.42, 0.14, 0.58, 0.24)
        guard mouthDiff > 1.5 else {
            throw SelfTestError.mismatch("lipsync: mouth region barely changed 0→1 (diff \(mouthDiff))")
        }
        guard mouthDiff > foreheadDiff * 4 + 0.5 else {
            throw SelfTestError.mismatch("lipsync: change not localized to the mouth (mouth \(mouthDiff) vs forehead \(foreheadDiff))")
        }

        // With lip-sync OFF the mouth ignores openness (unchanged 0→1).
        let offA = try c.renderComposite(params(mouthOpenness: 0, lipSync: false))
        let offB = try c.renderComposite(params(mouthOpenness: 1, lipSync: false))
        let offDiff = boxMeanDiff(offA, offB, 0.40, 0.44, 0.60, 0.62)
        guard offDiff < 0.5 else {
            throw SelfTestError.mismatch("lipsync: openness moved the mouth even with lip-sync OFF (diff \(offDiff))")
        }

        try writePNG(closed, outDir.appendingPathComponent("01_mouth_closed_openness0.png"))
        try writePNG(open,   outDir.appendingPathComponent("02_mouth_open_openness1.png"))
        print(String(format: "  ✓ lip-sync: mouth diff 0→1 = %.2f (forehead ctrl %.2f, off %.2f)", mouthDiff, foreheadDiff, offDiff))
    }

    // MARK: - 2b. Lip-sync crossfade on a NON-COINCIDENT rig (F19)

    /// Regression for F19: on a rig where the open-mouth ink does NOT cover every
    /// closed-mouth pixel, the OLD code drew closed at alpha 1 always and only
    /// overlaid open at `openness`, so at openness 1 the uncovered closed-mouth
    /// pixels stayed visible → TWO mouths. The fix crossfades (closed α = 1−open),
    /// so at openness 1 the closed-only region is fully gone. Built from explicit
    /// layers with DISJOINT closed/open ink so the defect is unambiguous.
    ///
    /// Also dumps the openness-1 frame (one mouth) for the lead.
    private static func testLipSyncCrossfadeNonCoincident(_ outDir: URL) throws {
        // 200×200 layer images, bottom-left origin, transparent except the ink.
        func inkImg(_ rect: CGRect, _ color: CGColor) -> CGImage {
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
                                bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(color)
            ctx.fill(rect)
            return ctx.makeImage()!
        }
        // Region A (closed-only) and region B (open-only) are DISJOINT.
        let closedImg = inkImg(CGRect(x: 20, y: 130, width: 60, height: 50),
                               CGColor(srgbRed: 0.8, green: 0.2, blue: 0.2, alpha: 1))
        let openImg = inkImg(CGRect(x: 120, y: 20, width: 60, height: 50),
                             CGColor(srgbRed: 0.2, green: 0.2, blue: 0.8, alpha: 1))
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let c = try CharacterSource(
            id: SourceID("selftest.character.crossfade"),
            canvasSize: CanvasSize(width: W, height: H), fps: 60,
            testLayers: [
                (name: "mouth_closed", image: closedImg, frame: full, z: 3, group: "mouth"),
                (name: "mouth_open", image: openImg, frame: full, z: 4, group: "mouth"),
            ],
            expressions: ["neutral": []],
            defaultExpression: "neutral")

        let atClosed = try c.renderComposite(params(mouthOpenness: 0, lipSync: true))
        let atOpen   = try c.renderComposite(params(mouthOpenness: 1, lipSync: true))

        // Pixels inked at openness 0 == the closed-mouth (region A). Count how many
        // of THOSE stay inked at openness 1. The fix drives that to ~0; the bug
        // leaves the whole closed mouth painted (a second mouth).
        var inked0 = 0, stillInked = 0
        var y = 0
        while y < H {
            var x = 0
            while x < W {
                let a0 = readBGRA(atClosed, x: x, y: y).a
                if a0 > 40 {
                    inked0 += 1
                    if readBGRA(atOpen, x: x, y: y).a > 40 { stillInked += 1 }
                }
                x += 1
            }
            y += 1
        }
        guard inked0 > 200 else {
            throw SelfTestError.mismatch("crossfade: closed mouth barely painted at openness 0 (inked \(inked0)) — rig setup wrong")
        }
        // Open mouth (region B) must be present at openness 1 (one mouth, not zero).
        let openInk = maxAlpha(atOpen)
        guard openInk > 0.5 else {
            throw SelfTestError.mismatch("crossfade: open mouth not visible at openness 1 (maxAlpha \(openInk))")
        }
        let leakFrac = Double(stillInked) / Double(inked0)
        guard leakFrac < 0.02 else {
            throw SelfTestError.mismatch(String(format:
                "crossfade: closed mouth still visible at openness 1 — TWO mouths (%.1f%% of closed-mouth pixels remain, %d/%d)",
                leakFrac * 100, stillInked, inked0))
        }

        try writePNG(atClosed, outDir.appendingPathComponent("08_crossfade_openness0_closed.png"))
        try writePNG(atOpen,   outDir.appendingPathComponent("09_crossfade_openness1_onemouth.png"))
        // Also drop the openness-1 "one mouth" proof into the lead's src-fix dir.
        let leadDir = URL(fileURLWithPath:
            "/tmp/prism_srcfix",
            isDirectory: true)
        try? FileManager.default.createDirectory(at: leadDir, withIntermediateDirectories: true)
        try? writePNG(atOpen, leadDir.appendingPathComponent("F19_lipsync_openness1_one_mouth.png"))
        try? writePNG(atClosed, leadDir.appendingPathComponent("F19_lipsync_openness0_closed.png"))
        print(String(format: "  ✓ lip-sync crossfade (F19): closed-mouth leak at openness 1 = %.2f%% (was ~100%%)", leakFrac * 100))
    }

    // MARK: - 3. Auto-blink: deterministic seeded schedule + closed-eye frame

    private static func testAutoBlink(_ outDir: URL) throws {
        // Deterministic schedule (pure): gaps in range, varied, reproducible.
        let g0 = CharacterSource.blinkGap(0)
        let g1 = CharacterSource.blinkGap(1)
        guard g0 >= CharacterSource.blinkMinGap, g0 <= CharacterSource.blinkMaxGap,
              g1 >= CharacterSource.blinkMinGap, g1 <= CharacterSource.blinkMaxGap else {
            throw SelfTestError.mismatch("blink: gap out of [\(CharacterSource.blinkMinGap),\(CharacterSource.blinkMaxGap)] (g0 \(g0), g1 \(g1))")
        }
        guard abs(g0 - g1) > 1e-6 else { throw SelfTestError.mismatch("blink: schedule is constant (g0==g1)") }
        guard CharacterSource.blinkGap(0) == g0 else { throw SelfTestError.mismatch("blink: schedule not reproducible per seed") }

        // A blink fires within its scheduled window; open between blinks.
        var cs = 0.0, ci = 0
        let atCenter = CharacterSource.blinkClosedAmount(tRel: g0 + CharacterSource.blinkCloseDuration / 2,
                                                         cursorStart: &cs, cursorIndex: &ci)
        var cs2 = 0.0, ci2 = 0
        let before = CharacterSource.blinkClosedAmount(tRel: g0 - 0.5, cursorStart: &cs2, cursorIndex: &ci2)
        var cs3 = 0.0, ci3 = 0
        let between = CharacterSource.blinkClosedAmount(tRel: g0 + CharacterSource.blinkCloseDuration + 0.2,
                                                        cursorStart: &cs3, cursorIndex: &ci3)
        guard atCenter > 0.9 else { throw SelfTestError.mismatch("blink: not closed at scheduled center (amt \(atCenter))") }
        guard before == 0 else { throw SelfTestError.mismatch("blink: closed BEFORE first blink (amt \(before))") }
        guard between == 0 else { throw SelfTestError.mismatch("blink: still closed between blinks (amt \(between))") }

        // Pixel proof: the closed-eye frame differs (in the eye region) from open.
        let c = try CharacterSource(id: SourceID("selftest.character.blink"),
                                    canvasSize: CanvasSize(width: W, height: H), fps: 60)
        let openEye   = try c.renderComposite(params(closedAmount: 0))
        let closedEye = try c.renderComposite(params(closedAmount: 1))
        let eyeDiff      = boxMeanDiff(openEye, closedEye, 0.38, 0.34, 0.62, 0.46)
        let foreheadDiff = boxMeanDiff(openEye, closedEye, 0.42, 0.14, 0.58, 0.24)
        guard eyeDiff > 1.5, eyeDiff > foreheadDiff * 4 + 0.5 else {
            throw SelfTestError.mismatch("blink: eye region did not close (eye \(eyeDiff) vs forehead \(foreheadDiff))")
        }

        try writePNG(closedEye, outDir.appendingPathComponent("03_blink_closed.png"))
        print(String(format: "  ✓ auto-blink: g0=%.2fs g1=%.2fs, closed@center %.2f, eye diff %.2f (forehead %.2f)", g0, g1, atCenter, eyeDiff, foreheadDiff))
    }

    // MARK: - 4. Reaction: overshoot then settle

    private static func testReactionOvershoot(_ outDir: URL) throws {
        // Sample the impactPop scale envelope across the reaction window.
        var boosts: [Double] = []
        var p = 0.0
        while p <= 1.0001 { boosts.append(CharacterSource.reactionAccent(.impactPop, phase: p).scaleBoost); p += 0.02 }
        let maxBoost = boosts.max() ?? 0
        let peakIdx = boosts.firstIndex(of: maxBoost) ?? 0
        let atStart = boosts.first ?? 0
        let atEnd = boosts.last ?? 0
        guard maxBoost > 0.1 else { throw SelfTestError.mismatch("reaction: no overshoot (max scaleBoost \(maxBoost))") }
        guard peakIdx > 0, peakIdx < boosts.count - 1 else {
            throw SelfTestError.mismatch("reaction: peak not interior (idx \(peakIdx)/\(boosts.count)) — not an attack→settle")
        }
        guard abs(atStart) < 0.03 else { throw SelfTestError.mismatch("reaction: does not start from rest (start \(atStart))") }
        guard abs(atEnd) < 0.05 else { throw SelfTestError.mismatch("reaction: did not settle back to rest (end \(atEnd))") }

        // The other accents also overshoot then settle (translate/rotate → ~0).
        let bounceEnd = CharacterSource.reactionAccent(.bounce, phase: 1).transY
        let wobbleEnd = CharacterSource.reactionAccent(.wobble, phase: 1).rot
        guard abs(bounceEnd) < 0.02, abs(wobbleEnd) < 0.02 else {
            throw SelfTestError.mismatch("reaction: bounce/wobble did not settle (\(bounceEnd), \(wobbleEnd))")
        }

        // Dump the scale-punch peak (flash faded so the enlarged rig is visible).
        let c = try CharacterSource(id: SourceID("selftest.character.react"),
                                    canvasSize: CanvasSize(width: W, height: H), fps: 60)
        let peak = try c.renderComposite(params(expression: "surprised",
                                                accent: CharacterSource.reactionAccent(.impactPop, phase: 0.24)))
        let rest = try c.renderComposite(params(expression: "surprised"))
        try writePNG(peak, outDir.appendingPathComponent("04_reaction_overshoot_peak.png"))
        try writePNG(rest, outDir.appendingPathComponent("05_reaction_settled.png"))
        print(String(format: "  ✓ reaction: impactPop overshoot max scale +%.2f at phase %.2f, settles to %.3f", maxBoost, Double(peakIdx) * 0.02, atEnd))
    }

    // MARK: - 5. Entrance / exit: off → on

    private static func testEntrance(_ outDir: URL) throws {
        // Pure transform: slide-in starts fully off-canvas, ends at rest; a fade
        // starts transparent; an EXIT ends fully off.
        let inStart = CharacterSource.entranceTransform(style: .slideLeft, appearing: true, progress: 0)
        let inEnd   = CharacterSource.entranceTransform(style: .slideLeft, appearing: true, progress: 1)
        let fadeStart = CharacterSource.entranceTransform(style: .fade, appearing: true, progress: 0)
        let outEnd  = CharacterSource.entranceTransform(style: .slideLeft, appearing: false, progress: 1)
        guard inStart.dx < -1.0 else { throw SelfTestError.mismatch("entrance: slide-in not off-canvas at p=0 (dx \(inStart.dx))") }
        guard abs(inEnd.dx) < 0.02 else { throw SelfTestError.mismatch("entrance: slide-in not at rest at p=1 (dx \(inEnd.dx))") }
        guard fadeStart.alpha < 0.02 else { throw SelfTestError.mismatch("entrance: fade not transparent at p=0 (alpha \(fadeStart.alpha))") }
        guard outEnd.dx < -1.0 else { throw SelfTestError.mismatch("entrance: exit not off-canvas at p=1 (dx \(outEnd.dx))") }

        // Pixel proof: off-canvas at p=0 (nothing painted) → on-canvas at p=1.
        let c = try CharacterSource(id: SourceID("selftest.character.entrance"),
                                    canvasSize: CanvasSize(width: W, height: H), fps: 60)
        let off = try c.renderComposite(params(entrance: (.slideLeft, true, 0.0)))
        let on  = try c.renderComposite(params(entrance: (.slideLeft, true, 1.0)))
        let offAlpha = maxAlpha(off)
        let onAlpha  = maxAlpha(on)
        guard offAlpha < 0.02 else { throw SelfTestError.mismatch("entrance: something on-canvas at p=0 (maxAlpha \(offAlpha))") }
        guard onAlpha > 0.5 else { throw SelfTestError.mismatch("entrance: character not visible at p=1 (maxAlpha \(onAlpha))") }
        // At rest the character is centred (off-canvas frame has no centroid).
        if let cOn = opaqueCentroid(on) {
            guard abs(cOn.x - Double(W) / 2) < Double(W) * 0.2 else {
                throw SelfTestError.mismatch("entrance: at-rest centroid not near center (x \(cOn.x))")
            }
        }

        // Dump an entrance sweep (slide) + a pop midpoint for the lead.
        for prog in [0.0, 0.35, 0.7, 1.0] {
            let f = try c.renderComposite(params(entrance: (.slideLeft, true, prog)))
            try writePNG(f, outDir.appendingPathComponent(String(format: "06_entrance_slide_p%02d.png", Int(prog * 100))))
        }
        let pop = try c.renderComposite(params(entrance: (.pop, true, 0.5)))
        try writePNG(pop, outDir.appendingPathComponent("07_entrance_pop_p50.png"))
        print(String(format: "  ✓ entrance: off→on (maxAlpha %.2f→%.2f), slide-in dx %.2f→%.2f", offAlpha, onAlpha, inStart.dx, inEnd.dx))
    }

    // MARK: - Params builder

    private static func params(idleT: Double = 0,
                               expression: String = "neutral",
                               mouthOpenness: Double = 0,
                               lipSync: Bool = false,
                               closedAmount: Double = 0,
                               accent: CharacterSource.Accent? = nil,
                               entrance: (CharacterSource.EntranceStyle, Bool, Double)? = nil)
        -> CharacterSource.AnimParams {
        CharacterSource.AnimParams(idleT: idleT, expression: expression,
                                   mouthOpenness: mouthOpenness, lipSync: lipSync,
                                   closedAmount: closedAmount, accent: accent, entrance: entrance)
    }

    // MARK: - Frame collection

    private final class Collector {
        private let lock = OSAllocatedUnfairLock(initialState: [VideoFrame]())
        func add(_ f: VideoFrame) { lock.withLock { $0.append(f) } }
        var count: Int { lock.withLock { $0.count } }
        var latest: VideoFrame? { lock.withLock { $0.last } }
    }

    /// Sources emit on their own serial queue, so a sleep-poll suffices.
    @discardableResult
    private static func poll(_ timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline { return predicate() }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    // MARK: - Pixel readback

    private static func readBGRA(_ b: CVPixelBuffer, x: Int, y: Int) -> (b: Int, g: Int, r: Int, a: Int) {
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
            + y * CVPixelBufferGetBytesPerRow(b) + x * 4
        return (Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3]))
    }

    /// Mean absolute per-pixel RGB difference over a normalized box (0…255 scale).
    private static func boxMeanDiff(_ a: CVPixelBuffer, _ b: CVPixelBuffer,
                                    _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Double {
        let px0 = Int(x0 * Double(W)), px1 = Int(x1 * Double(W))
        let py0 = Int(y0 * Double(H)), py1 = Int(y1 * Double(H))
        var sum = 0.0, n = 0
        var y = py0
        while y < py1 {
            var x = px0
            while x < px1 {
                let pa = readBGRA(a, x: x, y: y), pb = readBGRA(b, x: x, y: y)
                sum += Double(abs(pa.r - pb.r) + abs(pa.g - pb.g) + abs(pa.b - pb.b)) / 3.0
                n += 1
                x += 2
            }
            y += 2
        }
        return n > 0 ? sum / Double(n) : 0
    }

    private static func maxAlpha(_ b: CVPixelBuffer) -> Double {
        var hi = 0
        var y = 0
        while y < H {
            var x = 0
            while x < W { hi = max(hi, readBGRA(b, x: x, y: y).a); x += 4 }
            y += 4
        }
        return Double(hi) / 255.0
    }

    /// Centroid of opaque (a>32) pixels, or nil if the frame is empty.
    private static func opaqueCentroid(_ b: CVPixelBuffer) -> (x: Double, y: Double)? {
        var sx = 0.0, sy = 0.0, n = 0.0
        var y = 0
        while y < H {
            var x = 0
            while x < W {
                if readBGRA(b, x: x, y: y).a > 32 { sx += Double(x); sy += Double(y); n += 1 }
                x += 2
            }
            y += 2
        }
        return n > 0 ? (sx / n, sy / n) : nil
    }

    // MARK: - PNG dump

    private static func writePNG(_ buffer: CVPixelBuffer, _ url: URL) throws {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw SelfTestError.setupFailed("PNG base address")
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base, width: W, height: H, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: cs, bitmapInfo: info),
              let image = ctx.makeImage() else {
            throw SelfTestError.setupFailed("PNG context/makeImage")
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SelfTestError.setupFailed("PNG destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw SelfTestError.setupFailed("PNG finalize") }
    }
}
