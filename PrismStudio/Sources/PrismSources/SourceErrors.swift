import Foundation

/// Typed errors for the generated (non-hardware) source family.
///
/// These sources *draw* rather than *capture*, so failures are about
/// resources (missing files, unloadable fonts, offscreen web rendering)
/// rather than TCC permissions or device I/O.
public enum SourceError: Error, CustomStringConvertible {
    /// The IOSurface-backed pixel-buffer pool could not be created.
    case canvasCreationFailed(reason: String)
    /// A CoreGraphics bitmap context could not be created over the buffer.
    case contextCreationFailed
    /// The image file could not be opened / read.
    case imageLoadFailed(path: String, underlying: Error?)
    /// The image file opened but no decodable frame could be produced.
    case imageDecodeFailed(path: String)
    /// A requested font could not be resolved (CoreText normally substitutes,
    /// so this is reserved for hard-configuration failures).
    case fontUnavailable(name: String)
    /// A `BrowserSource` could not create/host its `WKWebView`.
    case browserUnavailable(reason: String)
    /// An offscreen web snapshot failed at runtime.
    case snapshotFailed(reason: String)
    /// A configuration value was out of range (e.g. zero canvas size).
    case invalidConfiguration(reason: String)
    /// A media FILE (video) could not be opened / its tracks could not load.
    case mediaLoadFailed(path: String, underlying: Error?)
    /// A media file opened but carries no video track to play.
    case mediaHasNoVideoTrack(path: String)
    /// An `AVAssetReader` could not be created/started for the file.
    case mediaReaderFailed(reason: String)
    /// The Vision person-segmentation request could not be set up (missing
    /// capability / OS support) for `PresenterCutoutSource`.
    case segmentationSetupFailed(reason: String)
    /// A Vision person-segmentation request threw while running.
    case segmentationFailed(underlying: Error)
    /// The cutout compositor was handed a frame in a pixel format neither path
    /// handles; the `OSType` is the format. Both paths accept 32BGRA and
    /// biplanar 4:2:0 YUV (420f/420v) — the GPU samples them natively, the CPU
    /// fallback converts YUV→BGRA via vImage — so this now surfaces only for a
    /// genuinely unknown format (e.g. a 4:2:2 or planar layout), never for the
    /// documented camera formats. `cpuReferenceComposite` (the BGRA-only oracle)
    /// still throws this directly on non-BGRA input.
    case unsupportedInputFormat(OSType)
    /// The GPU cutout stage (`PrismVision.BackgroundEffect`) failed to composite.
    case gpuCompositeFailed(underlying: Error)

    public var description: String {
        switch self {
        case .canvasCreationFailed(let r): return "source canvas creation failed: \(r)"
        case .contextCreationFailed: return "source draw context creation failed"
        case .imageLoadFailed(let p, let e):
            return "image load failed for \(p)\(e.map { ": \($0)" } ?? "")"
        case .imageDecodeFailed(let p): return "image decode failed for \(p)"
        case .fontUnavailable(let n): return "font unavailable: \(n)"
        case .browserUnavailable(let r): return "browser source unavailable: \(r)"
        case .snapshotFailed(let r): return "web snapshot failed: \(r)"
        case .invalidConfiguration(let r): return "invalid source configuration: \(r)"
        case .mediaLoadFailed(let p, let e):
            return "media load failed for \(p)\(e.map { ": \($0)" } ?? "")"
        case .mediaHasNoVideoTrack(let p): return "media has no video track: \(p)"
        case .mediaReaderFailed(let r): return "media reader failed: \(r)"
        case .segmentationSetupFailed(let r): return "person segmentation setup failed: \(r)"
        case .segmentationFailed(let e): return "person segmentation failed: \(e)"
        case .unsupportedInputFormat(let f):
            let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((f >> $0) & 0xFF))) }
            return "cutout: unsupported input pixel format '\(String(chars))' (CPU fallback needs 32BGRA)"
        case .gpuCompositeFailed(let e): return "cutout GPU composite failed: \(e)"
        }
    }
}
