import Foundation
import simd

/// Configuration for the Metal chroma keyer (`ChromaKeyProcessor`) — the
/// green-screen path of DESIGN.md §2.3, run as a standalone GPU pass parallel
/// to Vision person segmentation.
///
/// The matte is computed as the distance, in the BT.709 (Cb,Cr) chroma plane,
/// between each pixel and `keyColor`. Distance is luma-independent, so shadows
/// and highlights on the backdrop key out the same as the mid-tone. The raw
/// distance is feathered into an alpha with a `smoothstep(similarity,
/// similarity + smoothness, dist)`.
public struct ChromaKey: Equatable, Sendable {
    /// The backdrop color to remove, linear-ish gamma-encoded RGB in 0…1.
    public var keyColor: SIMD3<Float>
    /// Chroma-plane distance at (and below) which a pixel is fully keyed
    /// (α = 0). Larger = more aggressive (removes colors further from the key).
    /// Typical 0.25…0.5. BT.709 chroma distances span ~0…1.
    public var similarity: Double
    /// Feather width above `similarity` over which α ramps 0 → 1. Larger =
    /// softer matte edge. Typical 0.03…0.15.
    public var smoothness: Double
    /// Despill strength, 0 = off, 1 = full. Removes the key color's tint that
    /// bleeds onto foreground edges (green/blue fringing).
    public var spillStrength: Double

    public init(keyColor: SIMD3<Float> = SIMD3(0, 1, 0),
                similarity: Double = 0.4,
                smoothness: Double = 0.1,
                spillStrength: Double = 1.0) {
        self.keyColor = keyColor
        self.similarity = similarity
        self.smoothness = smoothness
        self.spillStrength = spillStrength
    }

    /// Standard green-screen preset (key color pure green).
    public static let greenScreen = ChromaKey(keyColor: SIMD3(0, 1, 0))
    /// Standard blue-screen preset (key color pure blue).
    public static let blueScreen = ChromaKey(keyColor: SIMD3(0, 0, 1))
}
