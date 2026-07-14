import CoreMedia
import CoreVideo
import Foundation

/// Constants shared between the CMIO extension process and the host-side
/// feeder. Both sides compile this file (the extension target embeds this
/// library), so device/stream identity can never drift between the two.
///
/// DESIGN.md §3.6: the extension is *dumb* — one device, one source stream
/// (what Zoom/Meet/FaceTime consume), one sink stream (what the app feeds).
public enum PrismVCamConstants {

    // MARK: Identity

    /// Marketing name clients show in their camera pickers.
    public static let deviceName = "Prism Camera"
    public static let providerName = "Prism"
    public static let manufacturer = "Prism"
    public static let deviceModel = "Prism Virtual Camera"

    /// Stable device UUID (CMIOExtensionDevice.deviceID). Never change once shipped.
    public static let deviceID = UUID(uuidString: "6D9F1E4A-2C3B-4F5D-8A70-1B2C3D4E5F60")!

    /// The DAL-visible device UID (CMIOExtensionDevice.legacyDeviceID →
    /// kCMIODevicePropertyDeviceUID). The host feeder matches on this exact
    /// string when enumerating devices. Never change once shipped.
    public static let deviceUID = "PrismCamera-8F2C1A9E"

    /// Source stream (extension → conferencing apps).
    public static let sourceStreamID = UUID(uuidString: "9A8B7C6D-5E4F-4321-B0A1-C2D3E4F50617")!
    /// Sink stream (host app → extension).
    public static let sinkStreamID = UUID(uuidString: "1F2E3D4C-5B6A-4798-8091-A2B3C4D5E6F7")!

    /// Base mach service name of the extension (Info.plist `CMIOExtension →
    /// CMIOExtensionMachServiceName`). At runtime it must be prefixed with the
    /// team identifier or an app-group prefix; see README.md.
    public static let machServiceNameBase = "studio.prism.PrismStudio.vcam"

    /// Bundle identifier of the .systemextension (what
    /// `SystemExtensionInstaller` activates). Keep in sync with the Xcode target.
    public static let extensionBundleID = "studio.prism.PrismStudio.vcam"

    // MARK: Sink authorization

    /// Signing-ID prefix a client must carry to be allowed to FEED the virtual
    /// camera's sink (the Prism app is `studio.prism.app`). Anything else — an
    /// arbitrary local process opening the CMIO sink to inject frames onto the
    /// "Prism Camera" other apps consume — is rejected.
    ///
    /// Note (honest scope): CMIO surfaces only `client.signingID` here, not a full
    /// `SecCode`, so this is a bundle-prefix gate, not a team-ID/cdhash designated
    /// requirement. It blocks casual/foreign injection; it is not proof against a
    /// process that forges this exact signing ID. Matching a prefix (not an exact
    /// signature) keeps the legitimate app working across ad-hoc rebuilds.
    public static let authorizedSinkClientSigningIDPrefix = "studio.prism."

    /// Whether a client with the given signing ID may feed the sink stream.
    /// Pure + total so it can be unit-tested without a live CMIO client.
    public static func isAuthorizedSinkClient(signingID: String?) -> Bool {
        guard let signingID, !signingID.isEmpty else { return false }
        return signingID.hasPrefix(authorizedSinkClientSigningIDPrefix)
    }

    // MARK: Formats

    public static let width = 1920
    public static let height = 1080
    /// Default/maximum frame rate of the camera (frame duration 1/60).
    public static let frameRate: Int32 = 60
    /// Placeholder cadence when no sink client is feeding (DESIGN §3.6: 30 fps
    /// so client apps never stall).
    public static let placeholderFrameRate: Int32 = 30

    /// Format index 0: BGRA (matches the compositor's program output — the
    /// zero-copy default path).
    public static let pixelFormatBGRA: OSType = kCVPixelFormatType_32BGRA
    /// Format index 1: 420v (some clients prefer bi-planar YUV).
    public static let pixelFormat420v: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    /// Format index 2: 10-bit packed RGB (`ARGB2101010LEPacked`) — advertises the
    /// HDR program to a client that can negotiate it. This is EXACTLY the
    /// compositor's `.hdr` program-frame format (Rec.2020 / BT.2100-HLG-tagged),
    /// so an HDR show reaches the virtual camera at 10-bit instead of being
    /// silently down-advertised as 8-bit BGRA/420v (Stage O sink-parity).
    public static let pixelFormat10bit: OSType = kCVPixelFormatType_ARGB2101010LEPacked

    /// The advertised pixel formats, IN INDEX ORDER (0 = BGRA default, 1 = 420v,
    /// 2 = 10-bit HDR). The extension builds one `CMVideoFormatDescription` per
    /// entry from this list, so a client sees all three; the last one gives an
    /// HDR show 10-bit parity. Exposed as a constant so the format set is
    /// unit-testable without the CMIOExtension host runtime.
    public static let advertisedPixelFormats: [OSType] = [
        pixelFormatBGRA, pixelFormat420v, pixelFormat10bit,
    ]

    /// Sink stream queue depth (translates to kCMIOStreamPropertyOutputBufferQueueSize).
    public static let sinkQueueSize = 8
    /// Buffers the sink wants before startup (kCMIOStreamPropertyOutputBuffersRequiredForStartup).
    public static let sinkBuffersRequiredForStartup = 1

    /// If the sink has been silent this long while a source client is
    /// streaming, the placeholder generator takes over (and yields again the
    /// moment real frames resume).
    public static let sinkStalenessSeconds: Double = 0.5
}
