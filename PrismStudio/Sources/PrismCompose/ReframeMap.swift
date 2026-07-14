import CoreGraphics
import Foundation
import PrismCompositor
import PrismCore

/// How a single source maps from the primary (horizontal) program into the
/// secondary (vertical) canvas. Geometry is resolution-independent — every
/// rect is normalized 0…1 in the *vertical* canvas (top-left origin, y-down),
/// exactly matching `PrismCompositor.Layer.frame`.
///
/// The four modes match DESIGN.md §2.5's "one show, two aspect ratios":
///  - `.fill`   — center-crop the source so it fills the vertical canvas
///                full-bleed with no distortion (the "hero" look).
///  - `.fit`    — letterbox the *whole* source into the vertical canvas
///                (black bars above/below a 16:9 source).
///  - `.custom` — place the source at an explicit normalized rect in the
///                vertical canvas (e.g. a picture-in-picture band).
///  - `.hidden` — drop the source from the vertical program entirely.
public enum ReframeMode: Equatable, Sendable {
    case fill
    case fit
    case custom(CGRect)
    case hidden
}

/// Aspect-ratio inputs the `.fit`/`.fill` math needs. All are `width/height`.
///
/// `sourceAspect` is the *content* aspect of a source (a 16:9 camera = 16/9).
/// It defaults to `horizontalAspect` — the common case where a source fills
/// the horizontal program edge-to-edge, so its content shape is the primary
/// canvas shape. Override per source for portrait phones, square art, etc.
public struct ReframeGeometry: Sendable, Equatable {
    /// Primary (horizontal) program aspect, e.g. 16/9.
    public var horizontalAspect: CGFloat
    /// Secondary (vertical) program aspect, e.g. 9/16.
    public var verticalAspect: CGFloat
    /// Per-source content-aspect overrides; absent sources use `horizontalAspect`.
    public var sourceAspect: [SourceID: CGFloat]

    public init(horizontalAspect: CGFloat = 16.0 / 9.0,
                verticalAspect: CGFloat = 9.0 / 16.0,
                sourceAspect: [SourceID: CGFloat] = [:]) {
        precondition(horizontalAspect > 0 && verticalAspect > 0)
        self.horizontalAspect = horizontalAspect
        self.verticalAspect = verticalAspect
        self.sourceAspect = sourceAspect
    }

    /// Content aspect (`width/height`) assumed for a source.
    ///
    /// A per-source override is only honored if it is a sane positive, finite
    /// ratio; a `0`/negative/NaN/±inf entry (which would produce NaN/zero
    /// reframe uniforms → an invisible layer) is ignored and falls back to the
    /// geometry default `horizontalAspect` (itself precondition-checked > 0).
    public func aspect(for id: SourceID) -> CGFloat {
        guard let a = sourceAspect[id], a.isFinite, a > 0 else { return horizontalAspect }
        return a
    }

    /// Standard 16:9 → 9:16 geometry.
    public static let standard = ReframeGeometry()
}

/// A full description of how a `Scene` reframes into the vertical program.
///
/// Resolution order, evaluated per layer's source:
///  1. an explicit `overrides[sourceID]` (always wins),
///  2. else, if the source is the resolved **hero**, `heroMode`,
///  3. else, `others`.
///
/// The "hero" is the source the vertical frame is built around and shown
/// full-bleed. `.topZIndex` picks the frontmost layer's source automatically
/// (the sane live default — whatever is on top of the horizontal program is
/// the subject); `.source(id)` pins a chosen hero (the `.follow` mode);
/// `.none` disables auto-hero and uses only `overrides`/`others`.
public struct ReframeMap: Sendable {
    /// Which source is treated as the full-bleed hero.
    public enum Hero: Sendable, Equatable {
        case topZIndex
        case source(SourceID)
        case none
    }

    public var hero: Hero
    /// How the hero source maps (default `.fill` — full-bleed center-crop).
    public var heroMode: ReframeMode
    /// How every non-hero, non-overridden source maps (default `.hidden`).
    public var others: ReframeMode
    /// Per-source explicit overrides (win over hero/others).
    public var overrides: [SourceID: ReframeMode]
    public var geometry: ReframeGeometry

    public init(hero: Hero = .topZIndex,
                heroMode: ReframeMode = .fill,
                others: ReframeMode = .hidden,
                overrides: [SourceID: ReframeMode] = [:],
                geometry: ReframeGeometry = .standard) {
        self.hero = hero
        self.heroMode = heroMode
        self.others = others
        self.overrides = overrides
        self.geometry = geometry
    }

    // MARK: Presets

    /// The sane vertical default: hero-fill on the top-zIndex source, all
    /// others hidden (DESIGN.md §2.5 "a sane vertical default").
    public static let heroFill = ReframeMap()

    /// Center the vertical program full-bleed on a chosen hero source; hide
    /// the rest. This is the spec's `.follow(sourceID)` mode.
    public static func follow(_ hero: SourceID, geometry: ReframeGeometry = .standard) -> ReframeMap {
        ReframeMap(hero: .source(hero), heroMode: .fill, others: .hidden, geometry: geometry)
    }

    /// Letterbox every source into the vertical canvas (no hero, no crop).
    public static func fitAll(geometry: ReframeGeometry = .standard) -> ReframeMap {
        ReframeMap(hero: .none, others: .fit, geometry: geometry)
    }

    /// Center-crop every source full-bleed (last-drawn wins visually).
    public static func fillAll(geometry: ReframeGeometry = .standard) -> ReframeMap {
        ReframeMap(hero: .none, others: .fill, geometry: geometry)
    }

    // MARK: Resolution

    /// Resolve the hero source for a given scene (frontmost = highest zIndex,
    /// ties broken by later array order — matching the compositor's draw order).
    public func resolveHero(in scene: Scene) -> SourceID? {
        switch hero {
        case .none: return nil
        case .source(let id): return id
        case .topZIndex:
            return scene.layers.enumerated()
                .filter { !$0.element.isHidden }
                .max { ($0.element.zIndex, $0.offset) < ($1.element.zIndex, $1.offset) }?
                .element.sourceID
        }
    }

    /// The mode a source resolves to, given the scene's hero.
    public func mode(for source: SourceID, hero: SourceID?) -> ReframeMode {
        if let m = overrides[source] { return m }
        if let hero, source == hero { return heroMode }
        return others
    }
}

/// Pure transform: produce the **vertical-canvas** `Scene` for a horizontal
/// `Scene` under a `ReframeMap` (DESIGN.md §2.5 deliverable 3).
///
/// This is the clean architecture seam: it rewrites each layer's `frame`/`crop`
/// into the vertical canvas so the *unmodified* `MetalCompositor` — built at
/// the vertical resolution — renders the second program. No compositor changes,
/// no shader changes; the reframe is geometry only.
///
/// Modes (source content aspect `As`, vertical canvas aspect `Av`):
///  - `.fill`: `frame = (0,0,1,1)`; the reframe crop is *composed with the
///    layer's existing crop* (never replaces it) so the already-visible content
///    is center-cropped full-bleed and undistorted.
///  - `.fit`: `crop` unchanged; `frame` is the centered band of the layer's
///    *effective visible aspect* inside the vertical canvas — letterbox bars
///    fall in the cleared black.
///  - `.custom(rect)`: `frame = rect`, `crop` unchanged.
///  - `.hidden`: layer dropped.
///
/// A pre-existing `crop` matters: a layer already cropped to (say) half its
/// width shows content whose *visible* aspect is `As · crop.width/crop.height`,
/// not `As`. Both `.fill` and `.fit` frame from that effective visible aspect,
/// so a pre-cropped layer reframes correctly instead of being stretched (`.fit`)
/// or mis-cropped (`.fill`).
///
/// Everything else on the layer (opacity, zIndex) is preserved.
public func VerticalScene(from scene: Scene, using map: ReframeMap) -> Scene {
    let hero = map.resolveHero(in: scene)
    let Av = map.geometry.verticalAspect
    var out: [Layer] = []
    out.reserveCapacity(scene.layers.count)

    for layer in scene.layers {
        let mode = map.mode(for: layer.sourceID, hero: hero)
        let As = map.geometry.aspect(for: layer.sourceID)
        switch mode {
        case .hidden:
            continue
        case .custom(let rect):
            var l = layer
            l.frame = rect
            out.append(l)
        case .fill:
            var l = layer
            l.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            l.crop = Reframe.fillCrop(existing: layer.crop, sourceAspect: As, verticalAspect: Av)
            out.append(l)
        case .fit:
            var l = layer
            // crop unchanged; frame the layer's *effective visible aspect*
            // (source aspect scaled by its existing crop) into the canvas.
            l.frame = Reframe.fitFrame(sourceAspect: As, verticalAspect: Av, existingCrop: layer.crop)
            out.append(l)
        }
    }
    return Scene(id: scene.id, name: scene.name + " ↕", layers: out)
}

/// Geometry helpers for the reframe modes (pure functions, unit-testable).
public enum Reframe {
    /// Full-crop rect (samples the whole source): the identity crop.
    static let fullCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// The visible content aspect of a layer *after* its own crop: the source
    /// aspect scaled by the crop's `width/height` (a narrow crop makes the
    /// visible content taller, a short crop makes it wider). Guards a degenerate
    /// (zero-height or non-finite) crop by falling back to the source aspect.
    static func effectiveAspect(sourceAspect As: CGFloat, crop: CGRect) -> CGFloat {
        guard crop.height > 0, crop.width > 0, crop.width.isFinite, crop.height.isFinite else { return As }
        return As * (crop.width / crop.height)
    }

    /// Center-crop *within* `existing` so the already-visible content fills a
    /// full vertical layer at aspect `Av` without distortion — the reframe crop
    /// composes with, and never replaces, the layer's existing crop. Framing is
    /// derived from the layer's *effective visible aspect* (source aspect scaled
    /// by `existing`'s w/h), so a pre-cropped layer center-crops correctly.
    /// Content wider than the target keeps full height and crops width; taller
    /// content keeps width and crops height. A non-finite/≤0 aspect is treated
    /// as "no reframe" (returns `existing` unchanged) rather than emitting NaN.
    public static func fillCrop(existing: CGRect, sourceAspect As: CGFloat, verticalAspect Av: CGFloat) -> CGRect {
        let ae = effectiveAspect(sourceAspect: As, crop: existing)
        guard ae.isFinite, ae > 0, Av.isFinite, Av > 0 else { return existing }
        var wFrac: CGFloat = 1, hFrac: CGFloat = 1
        if ae >= Av { wFrac = Av / ae } else { hFrac = ae / Av }
        let w = existing.width * wFrac
        let h = existing.height * hFrac
        let x = existing.origin.x + (existing.width - w) / 2
        let y = existing.origin.y + (existing.height - h) / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The centered band (top-left origin) inside the vertical canvas that shows
    /// the layer's whole visible content without cropping — the letterbox frame.
    /// Framing uses the *effective visible aspect* (source aspect scaled by
    /// `existingCrop`'s w/h) so a pre-cropped layer letterboxes to its real shape
    /// instead of being stretched. A non-finite/≤0 aspect falls back to a full
    /// frame (no letterbox) rather than emitting NaN uniforms.
    public static func fitFrame(sourceAspect As: CGFloat, verticalAspect Av: CGFloat,
                                existingCrop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> CGRect {
        let ae = effectiveAspect(sourceAspect: As, crop: existingCrop)
        guard ae.isFinite, ae > 0, Av.isFinite, Av > 0 else { return fullCrop }
        var fw: CGFloat = 1, fh: CGFloat = 1
        if ae >= Av { fh = Av / ae } else { fw = ae / Av }
        return CGRect(x: (1 - fw) / 2, y: (1 - fh) / 2, width: fw, height: fh)
    }
}
