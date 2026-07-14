import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import ImageIO
import os
import PrismCore
import UniformTypeIdentifiers

/// How a meme item is played (DESIGN.md §4).
public enum MemeMode: String, Sendable, Codable, CaseIterable {
    /// Momentarily takes PROGRAM full-screen, auto-returns after `holdSec`.
    case cutTo
    /// Overlays the item on current program for `holdSec`, then removes.
    case insert
    /// Uses the item as a §1 stinger transition into a target scene.
    case stinger
}

/// Where an `insert` item sits on the program.
public enum MemePlacement: Sendable, Codable, Equatable {
    case fullscreen
    case lowerThird
    case corner(Corner)
    public enum Corner: String, Sendable, Codable { case topLeft, topRight, bottomLeft, bottomRight }

    /// Normalized (top-left origin) placement rect for this placement.
    public var frame: CGRect {
        switch self {
        case .fullscreen: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .lowerThird: return CGRect(x: 0.05, y: 0.72, width: 0.90, height: 0.22)
        case .corner(let c):
            let s = 0.30, m = 0.04
            switch c {
            case .topLeft:     return CGRect(x: m, y: m, width: s, height: s)
            case .topRight:    return CGRect(x: 1 - m - s, y: m, width: s, height: s)
            case .bottomLeft:  return CGRect(x: m, y: 1 - m - s, width: s, height: s)
            case .bottomRight: return CGRect(x: 1 - m - s, y: 1 - m - s, width: s, height: s)
            }
        }
    }
}

/// One entry on the visual MemeBoard (DESIGN.md §4). The media is a source
/// already registered with the compositor (`sourceID`); `mediaURL` is where the
/// user-added or generated file lives on disk.
public struct MemeItem: Sendable, Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    /// On-disk media (image / GIF / clip). User-added or a generated template.
    public var mediaURL: URL
    /// The compositor source id feeding this item's frames when played.
    public var sourceID: SourceID
    public var mode: MemeMode
    /// How long a `cutTo`/`insert` holds before auto-return, seconds.
    public var holdSec: Double
    public var placement: MemePlacement
    /// True for the bundled originals; false once the user adds their own.
    public var isBuiltInTemplate: Bool

    public init(id: UUID = UUID(), name: String, mediaURL: URL, sourceID: SourceID,
                mode: MemeMode = .insert, holdSec: Double = 1.5,
                placement: MemePlacement = .fullscreen, isBuiltInTemplate: Bool = false) {
        self.id = id; self.name = name; self.mediaURL = mediaURL; self.sourceID = sourceID
        self.mode = mode; self.holdSec = holdSec; self.placement = placement
        self.isBuiltInTemplate = isBuiltInTemplate
    }
}

/// Executes MemeBoard triggers against the live program (DESIGN.md §4). This is
/// the *mechanism*: given triggered `MemeItem`s and a base program scene, it
/// computes the program scene at any house-time — a `cutTo` replaces the program
/// full-screen and auto-returns after `holdSec`; an `insert` overlays a placed
/// layer for `holdSec`. `stinger` items are transitions (run via
/// `StingerRenderer` / `RenderLoop.switchScene`), not overlays, and are surfaced
/// through `stinger(for:image:)` — the app wires the scene swap.
///
/// The app owns the RenderLoop; it sets `renderLoop.sceneProvider = { director.program(at: $0.seconds, base: base) }`.
public final class MemeDirector {
    private struct Active { let item: MemeItem; let start: Double }
    private let state = OSAllocatedUnfairLock<[Active]>(initialState: [])
    private let log = EngineLog.logger("compositor.memeboard")

    /// Canvas aspect ratio (width / height) the program renders at. When set, a
    /// placed meme layer's frame is aspect-corrected so the meme's source texture
    /// (rendered at the canvas aspect) is never stretched into a differently
    /// shaped placement rect (F24 / Class A — e.g. a 16:9 texture squeezed into a
    /// wide lower-third). `nil` (default) keeps the raw placement rect — the
    /// historical behaviour — so existing callers/tests are unchanged.
    public var canvasAspect: Double?

    public init() {}

    /// Aspect-preserving fit of a `sourceAspect` (w/h) texture inside `frame`
    /// (normalized, top-left origin) on a `canvasAspect` (w/h) canvas: returns the
    /// largest `sourceAspect`-shaped rect that fits inside `frame`'s PIXEL
    /// rectangle, centered, back in normalized canvas coords. Prevents the F24
    /// squeeze/stretch. Returns `frame` unchanged when the placement's pixel
    /// aspect already equals the source aspect (e.g. a full-canvas cut, or a PiP
    /// slot that is already the canvas aspect). Pure + deterministic.
    public static func aspectFitFrame(_ frame: CGRect, canvasAspect: Double,
                                      sourceAspect: Double) -> CGRect {
        guard canvasAspect > 0, sourceAspect > 0,
              frame.width > 0, frame.height > 0 else { return frame }
        // Work in a pixel space with unit height and width = canvasAspect.
        let pxW = Double(frame.width) * canvasAspect
        let pxH = Double(frame.height)
        let placeAspect = pxW / pxH
        var fitPxW = pxW, fitPxH = pxH
        if placeAspect > sourceAspect {
            fitPxW = pxH * sourceAspect        // placement too wide → pillarbox
        } else {
            fitPxH = pxW / sourceAspect        // placement too tall → letterbox
        }
        let normW = fitPxW / canvasAspect
        let normH = fitPxH
        return CGRect(x: Double(frame.midX) - normW / 2,
                      y: Double(frame.midY) - normH / 2,
                      width: normW, height: normH)
    }

    /// The placement rect for an item, aspect-corrected when `canvasAspect` is
    /// set. Meme sources are rendered at the canvas aspect (their texture is
    /// letterboxed/filled into the shared source canvas), so `sourceAspect ==
    /// canvasAspect` here.
    private func placedFrame(for placement: MemePlacement) -> CGRect {
        guard let ca = canvasAspect else { return placement.frame }
        return Self.aspectFitFrame(placement.frame, canvasAspect: ca, sourceAspect: ca)
    }

    /// Fire a meme at house-time `startTime` (seconds). `cutTo`/`insert` items
    /// join the active set until `startTime + holdSec`.
    ///
    /// Dedupe by `sourceID`: re-triggering an already-active meme UPDATES the
    /// existing entry (refreshing its start → extends the hold) instead of
    /// appending a duplicate. Two `Active` entries with the same `sourceID` would
    /// emit two program layers sharing that id; a downstream
    /// `Dictionary(uniqueKeysWithValues:)` keyed on `sourceID` (the app's vertical
    /// tap) then traps. One meme = one layer, always.
    public func trigger(_ item: MemeItem, at startTime: Double) {
        guard item.mode != .stinger else {
            log.info("meme '\(item.name, privacy: .public)' is a stinger — use stinger(for:image:) + switchScene")
            return
        }
        state.withLock { active in
            if let idx = active.firstIndex(where: { $0.item.sourceID == item.sourceID }) {
                active[idx] = Active(item: item, start: startTime)   // update in place
            } else {
                active.append(Active(item: item, start: startTime))
            }
        }
    }

    /// True while a full-screen `cutTo` currently holds the program.
    public func isCutActive(at time: Double) -> Bool {
        state.withLock { active in
            active.contains { $0.item.mode == .cutTo && time >= $0.start && time < $0.start + $0.item.holdSec }
        }
    }

    /// The program scene at `time`, given the resting `base` program. A live
    /// `cutTo` replaces the whole program with the meme source full-screen;
    /// `insert`s add placed overlay layers; expired triggers are dropped and the
    /// program returns to `base`.
    public func program(at time: Double, base: Scene) -> Scene {
        let (cut, inserts) = state.withLock { active -> (Active?, [Active]) in
            active.removeAll { time >= $0.start + $0.item.holdSec }   // auto-return
            let live = active.filter { time >= $0.start }
            let cut = live.last { $0.item.mode == .cutTo }
            let inserts = live.filter { $0.item.mode == .insert }
            return (cut, inserts)
        }

        if let cut {
            // Program is TAKEN: a single full-frame layer of the meme source.
            var s = Scene(id: base.id, name: "meme.cut.\(cut.item.name)")
            s.layers = [Layer(sourceID: cut.item.sourceID, frame: MemePlacement.fullscreen.frame, zIndex: 0)]
            return s
        }

        guard !inserts.isEmpty else { return base }
        var s = base
        var z = (base.layers.map(\.zIndex).max() ?? 0) + 1
        // Defensive: emit at most ONE layer per sourceID even if two triggers with
        // the same source slipped in (belt-and-braces with `trigger`'s dedupe), so
        // the program never carries duplicate-keyed layers.
        var emitted = Set<SourceID>()
        for ins in inserts where emitted.insert(ins.item.sourceID).inserted {
            s.layers.append(Layer(sourceID: ins.item.sourceID,
                                  frame: placedFrame(for: ins.item.placement),
                                  opacity: 1, zIndex: z, premultipliedAlpha: true))
            z += 1
        }
        return s
    }

    /// Build the stinger transition for a `stinger`-mode item, using its media
    /// image as the media-cover overlay. The app runs it via `StingerRenderer`
    /// or by driving the program cut at `cueProgress`.
    public func stinger(for item: MemeItem, image: CGImage, duration: Double = 0.7,
                        cueProgress: Double = 0.5) -> StingerTransition {
        StingerTransition.mediaCover(image: image, duration: duration, cueProgress: cueProgress)
    }

    /// Drop all active triggers (a hard "clear the board").
    public func reset() { state.withLock { $0.removeAll() } }

    /// Remove ONE meme's active trigger by `sourceID` (targeted teardown) and
    /// prune any expired trigger, returning whether a still-holding trigger
    /// remains at `time`. Removing a single held meme must not strand the others:
    /// `reset()` drops every simultaneously-held meme, so a caller that only wants
    /// to pull one source uses this and keeps the survivors — and their scheduled
    /// teardown — intact (N3).
    @discardableResult
    public func remove(sourceID: SourceID, at time: Double) -> Bool {
        state.withLock { active in
            active.removeAll { $0.item.sourceID == sourceID }
            active.removeAll { time >= $0.start + $0.item.holdSec }   // auto-return expired
            return active.contains { time >= $0.start }
        }
    }
}

// MARK: - Procedural template generator

/// Generates ORIGINAL, royalty-free meme-FORMAT templates to disk (DESIGN.md §4
/// copyright boundary). These are *formats* — reaction cards, anime impact
/// frames, speech bubbles, caption frames — never actual famous memes, which
/// are copyrighted and must be user-added (their responsibility).
public enum MemeTemplateGenerator {
    /// UI copy stating the copyright boundary (surface this near the "add meme"
    /// affordance).
    public static let copyrightNotice =
        "Bundled memes are original, royalty-free FORMAT templates. Famous memes are copyrighted — add your own; you are responsible for the rights."

    /// A generated template: file on disk + suggested play settings.
    public struct Template: Sendable {
        public let name: String
        public let url: URL
        public let suggestedMode: MemeMode
        public let suggestedPlacement: MemePlacement
    }

    /// Render the default template set (1080p) into `directory`. Returns the
    /// written templates. Idempotent (overwrites).
    @discardableResult
    public static func generateDefaults(into directory: URL, width: Int = 1920, height: Int = 1080) throws -> [Template] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let w = width, h = height
        var out: [Template] = []

        out.append(Template(name: "reaction-card",
                            url: try write(dir: directory, name: "reaction_card.png", w: w, h: h) { reactionCard($0, w, h) },
                            suggestedMode: .cutTo, suggestedPlacement: .fullscreen))
        out.append(Template(name: "anime-impact",
                            url: try write(dir: directory, name: "anime_impact.png", w: w, h: h) { animeImpact($0, w, h) },
                            suggestedMode: .stinger, suggestedPlacement: .fullscreen))
        out.append(Template(name: "speech-bubble",
                            url: try write(dir: directory, name: "speech_bubble.png", w: w, h: h) { speechBubble($0, w, h) },
                            suggestedMode: .insert, suggestedPlacement: .corner(.topRight)))
        out.append(Template(name: "wow-caption",
                            url: try write(dir: directory, name: "wow_caption.png", w: w, h: h) { wowCaption($0, w, h) },
                            suggestedMode: .cutTo, suggestedPlacement: .fullscreen))
        return out
    }

    /// Turn generated templates into ready `MemeItem`s (caller supplies each
    /// item's compositor `sourceID` once the media is loaded as a source).
    public static func items(from templates: [Template], sourceID: (Template) -> SourceID) -> [MemeItem] {
        templates.map { t in
            MemeItem(name: t.name, mediaURL: t.url, sourceID: sourceID(t),
                     mode: t.suggestedMode, holdSec: 1.5,
                     placement: t.suggestedPlacement, isBuiltInTemplate: true)
        }
    }

    // MARK: template painters (bottom-left-origin CG context)

    private static func reactionCard(_ ctx: CGContext, _ w: Int, _ h: Int) {
        // Bold caption over a vertical gradient.
        drawVerticalGradient(ctx, w, h, top: RGBA(r: 0.16, g: 0.18, b: 0.32), bottom: RGBA(r: 0.05, g: 0.06, b: 0.12))
        drawCenteredText(ctx, ["WHEN THE", "BUILD PASSES"], w: w, h: h, centerFrac: 0.5,
                         fontSize: Double(h) * 0.11, weight: 0.62, color: .white, stroke: nil)
    }

    private static func animeImpact(_ ctx: CGContext, _ w: Int, _ h: Int) {
        // Radial speedlines + center white flash + caption slot.
        ctx.setFillColor(RGBA(r: 0.02, g: 0.02, b: 0.04).cg)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let center = CGPoint(x: Double(w) / 2, y: Double(h) / 2)
        let reach = hypot(Double(w), Double(h))
        ctx.setFillColor(RGBA(r: 1, g: 1, b: 1).cg)
        let count = 72
        for i in 0..<count {
            let a0 = Double(i) / Double(count) * 2 * .pi
            let half = 0.010
            let inner = reach * 0.18
            let p0 = CGPoint(x: center.x + cos(a0) * inner, y: center.y + sin(a0) * inner)
            let p1 = CGPoint(x: center.x + cos(a0 - half) * reach, y: center.y + sin(a0 - half) * reach)
            let p2 = CGPoint(x: center.x + cos(a0 + half) * reach, y: center.y + sin(a0 + half) * reach)
            ctx.beginPath(); ctx.move(to: p0); ctx.addLine(to: p1); ctx.addLine(to: p2); ctx.closePath(); ctx.fillPath()
        }
        // Center flash disc.
        let r = reach * 0.16
        ctx.setFillColor(RGBA(r: 1, g: 1, b: 0.9, a: 0.95).cg)
        ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        // Caption slot.
        drawCenteredText(ctx, ["IMPACT"], w: w, h: h, centerFrac: 0.5,
                         fontSize: Double(h) * 0.13, weight: 0.62,
                         color: RGBA(r: 0.05, g: 0.05, b: 0.08), stroke: .white)
    }

    private static func speechBubble(_ ctx: CGContext, _ w: Int, _ h: Int) {
        // Transparent background → alpha overlay. Rounded white bubble + tail.
        let fw = Double(w), fh = Double(h)
        let bubble = CGRect(x: fw * 0.08, y: fh * 0.30, width: fw * 0.84, height: fh * 0.55)
        let path = CGPath(roundedRect: bubble, cornerWidth: fh * 0.10, cornerHeight: fh * 0.10, transform: nil)
        ctx.setFillColor(RGBA(r: 1, g: 1, b: 1).cg)
        ctx.addPath(path); ctx.fillPath()
        // Tail (triangle pointing down-left, in the bottom-left CG space).
        ctx.beginPath()
        ctx.move(to: CGPoint(x: fw * 0.22, y: fh * 0.30))
        ctx.addLine(to: CGPoint(x: fw * 0.14, y: fh * 0.12))
        ctx.addLine(to: CGPoint(x: fw * 0.36, y: fh * 0.30))
        ctx.closePath(); ctx.fillPath()
        // Outline
        ctx.setStrokeColor(RGBA(r: 0.05, g: 0.05, b: 0.08).cg)
        ctx.setLineWidth(fh * 0.012)
        ctx.addPath(path); ctx.strokePath()
        drawCenteredText(ctx, ["...bruh"], w: w, h: h, centerFrac: 0.42,
                         fontSize: fh * 0.16, weight: 0.56, color: RGBA(r: 0.05, g: 0.05, b: 0.08), stroke: nil)
    }

    private static func wowCaption(_ ctx: CGContext, _ w: Int, _ h: Int) {
        drawVerticalGradient(ctx, w, h, top: RGBA(r: 0.9, g: 0.2, b: 0.45), bottom: RGBA(r: 0.35, g: 0.1, b: 0.5))
        drawCenteredText(ctx, ["WOW"], w: w, h: h, centerFrac: 0.5,
                         fontSize: Double(h) * 0.34, weight: 0.62, color: .white,
                         stroke: RGBA(r: 0.05, g: 0.02, b: 0.08))
    }

    // MARK: painter helpers

    private static func drawVerticalGradient(_ ctx: CGContext, _ w: Int, _ h: Int, top: RGBA, bottom: RGBA) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        if let g = CGGradient(colorsSpace: cs, colors: [bottom.cg, top.cg] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h), options: [])
        } else {
            ctx.setFillColor(top.cg); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    /// Draw stacked centered lines (CoreText). `centerFrac` is the vertical
    /// center as a fraction from the TOP (screen-space). Optional `stroke` gives
    /// an outline (drawn via CT stroke attributes).
    private static func drawCenteredText(_ ctx: CGContext, _ lines: [String], w: Int, h: Int,
                                         centerFrac: Double, fontSize: Double,
                                         weight: Double, color: RGBA, stroke: RGBA?) {
        let font = makeFont(size: fontSize, weight: weight)
        let lineH = fontSize * 1.15
        let totalH = lineH * Double(lines.count)
        // Screen-space center → bottom-left-origin y of the top line's baseline block.
        let centerYFromBottom = Double(h) * (1 - centerFrac)
        var y = centerYFromBottom + totalH / 2 - lineH
        for line in lines {
            var attrs: [NSAttributedString.Key: Any] = [
                .init(kCTFontAttributeName as String): font,
                .init(kCTForegroundColorAttributeName as String): color.cg,
            ]
            if let stroke {
                // Negative width = fill + stroke (CoreText convention).
                attrs[.init(kCTStrokeWidthAttributeName as String)] = -6.0
                attrs[.init(kCTStrokeColorAttributeName as String)] = stroke.cg
            }
            let attributed = NSAttributedString(string: line, attributes: attrs)
            let ctLine = CTLineCreateWithAttributedString(attributed)
            // B7: `CTLineGetImageBounds` measures relative to the context's
            // CURRENT text position. After drawing line 1 the position is at the
            // end of that line (far right), so measuring line 2 from there yielded
            // a strongly negative origin.x and pushed line 2 off-screen
            // ("BUILD PASSES" → only "ES" visible). Reset to .zero before
            // measuring so bounds are position-independent and each line centres.
            ctx.textPosition = .zero
            let bounds = CTLineGetImageBounds(ctLine, ctx)
            let x = (Double(w) - Double(bounds.width)) / 2 - Double(bounds.origin.x)
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(ctLine, ctx)
            y -= lineH
        }
    }

    private static func makeFont(size: Double, weight: Double) -> CTFont {
        let traits: [CFString: Any] = [kCTFontWeightTrait: weight]
        let attrs: [CFString: Any] = [
            kCTFontFamilyNameAttribute: ".AppleSystemUIFont",
            kCTFontSizeAttribute: size,
            kCTFontTraitsAttribute: traits,
        ]
        let desc = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
        return CTFontCreateWithFontDescriptor(desc, CGFloat(size), nil)
    }

    static func write(dir: URL, name: String, w: Int, h: Int, _ paint: (CGContext) -> Void) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: info) else {
            throw VisualFXError.contextCreationFailed
        }
        paint(ctx)
        guard let image = ctx.makeImage() else { throw VisualFXError.imageCreationFailed }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw VisualFXError.pngWriteFailed(url.path)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw VisualFXError.pngWriteFailed(url.path) }
        return url
    }
}
