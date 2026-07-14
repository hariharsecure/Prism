import CoreGraphics
import Foundation
import PrismCore

/// One composited layer: a source placed on the program canvas.
///
/// Geometry is resolution-independent: `frame` and `crop` are normalized
/// (0…1) rects with a **top-left origin, y-down** convention (matches how
/// video buffers are addressed; the compositor converts to NDC internally).
public struct Layer: Codable, Equatable, Sendable {
    /// Which source feeds this layer.
    public var sourceID: SourceID
    /// Placement on the canvas, normalized 0…1 (top-left origin). (0,0,1,1) = full canvas.
    public var frame: CGRect
    /// Region of the *source* to show, normalized 0…1 within the source frame. (0,0,1,1) = uncropped.
    public var crop: CGRect
    /// 0 (invisible) … 1 (opaque). Applied as premultiplied alpha over layers below.
    public var opacity: Float
    /// Rotation of the layer about its own centre, in **radians** (default 0).
    ///
    /// Applied by the compositor's vertex stage as a rigid rotation of the
    /// layer quad about the centre of its `frame`, composed with `frame`
    /// placement and `crop`. It is **aspect-corrected** (rotation happens in an
    /// isotropic pixel space, not raw NDC) so a square region stays square — no
    /// shear or squeeze — regardless of the canvas aspect ratio. `0` is the
    /// exact historical behaviour: cos 1 / sin 0 make the vertex transform an
    /// identity, so an un-rotated layer renders byte-identically. This is the
    /// live home of `LayerMotion`/`LayerTransform.rotation` (the app sets it per
    /// tick); it was previously evaluated but silently dropped (F20).
    public var rotation: Double
    /// Draw order: lower zIndex is further back. Ties break by array order.
    public var zIndex: Int
    /// Hidden layers are skipped entirely (the "visibility eye").
    public var isHidden: Bool
    /// Alpha semantics of the source feeding this layer.
    ///
    /// - `false` (default): the layer is **opaque** — its sampled alpha is
    ///   ignored and forced to 1. This is the correct and safe choice for
    ///   cameras, screen capture, and any BGRA source whose alpha byte is
    ///   undefined/garbage (often 0). Such sources must NEVER go transparent.
    /// - `true`: the source carries a **premultiplied-alpha matte** (rgb·α, α)
    ///   — e.g. the chroma keyer (`ChromaKeyProcessor`) or person-segmentation
    ///   background removal (`PrismVision.BackgroundEffect.remove`). The sampled
    ///   alpha is honored (× `opacity`), so keyed/segmented pixels are
    ///   transparent and lower layers show through instead of compositing as
    ///   opaque black.
    ///
    /// Only affects the BGRA path; bi-planar YUV sources have no alpha channel
    /// and always composite opaque.
    public var premultipliedAlpha: Bool

    public init(sourceID: SourceID,
                frame: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                opacity: Float = 1.0,
                rotation: Double = 0,
                zIndex: Int = 0,
                isHidden: Bool = false,
                premultipliedAlpha: Bool = false) {
        self.sourceID = sourceID
        self.frame = frame
        self.crop = crop
        self.opacity = opacity
        self.rotation = rotation
        self.zIndex = zIndex
        self.isHidden = isHidden
        self.premultipliedAlpha = premultipliedAlpha
    }

    /// Factory for a layer feeding a `PrismSources.CharacterSource` (the VTuber
    /// rig). Its frames carry a premultiplied-alpha matte — the figure sits in a
    /// centred sub-rect and the surround is transparent — so the layer MUST
    /// honor sampled alpha. Without `premultipliedAlpha: true` the transparent
    /// surround composites as OPAQUE BLACK and the character becomes a
    /// full-canvas black rectangle over the program (B1). This factory sets it,
    /// so call sites can't forget. (It lives on `Layer` rather than on
    /// `CharacterSource` because PrismSources can't depend on PrismCompositor.)
    public static func character(sourceID: SourceID,
                                 frame: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                                 crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                                 opacity: Float = 1.0,
                                 rotation: Double = 0,
                                 zIndex: Int = 0,
                                 isHidden: Bool = false) -> Layer {
        Layer(sourceID: sourceID, frame: frame, crop: crop, opacity: opacity,
              rotation: rotation, zIndex: zIndex, isHidden: isHidden, premultipliedAlpha: true)
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID, frame, crop, opacity, rotation, zIndex, isHidden, premultipliedAlpha
    }

    /// Custom decode for backward compatibility: scenes/JSON written before
    /// `premultipliedAlpha` existed omit the key, which must decode to `false`
    /// (opaque — the historical behavior). All other keys remain required, so
    /// pre-existing scenes still decode unchanged. Encoding is synthesized.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try c.decode(SourceID.self, forKey: .sourceID)
        frame = try c.decode(CGRect.self, forKey: .frame)
        crop = try c.decode(CGRect.self, forKey: .crop)
        opacity = try c.decode(Float.self, forKey: .opacity)
        // `rotation` postdates the original schema — scenes written before it
        // omit the key and must decode to 0 (the historical no-rotation
        // behaviour), exactly like `premultipliedAlpha`.
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        zIndex = try c.decode(Int.self, forKey: .zIndex)
        isHidden = try c.decode(Bool.self, forKey: .isHidden)
        premultipliedAlpha = try c.decodeIfPresent(Bool.self, forKey: .premultipliedAlpha) ?? false
    }
}

/// An ordered stack of layers — what the user switches between.
public struct Scene: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Layers in model order; rendering sorts by `zIndex` (stable for ties).
    public var layers: [Layer]

    public init(id: UUID = UUID(), name: String, layers: [Layer] = []) {
        self.id = id
        self.name = name
        self.layers = layers
    }
}
