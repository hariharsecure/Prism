import CoreMedia
import CoreMediaIO
import Foundation
import PrismCore

/// Stream source for the SOURCE-direction stream — the "Prism Camera" video
/// feed that Zoom/Meet/FaceTime/QuickTime consume. It holds no pixels of its
/// own: the device source pushes into `stream.send(...)`, either mirrored
/// sink frames (app running) or the cached placeholder card.
final class PrismExtensionStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    let formats: [CMIOExtensionStreamFormat]
    private weak var deviceSource: PrismExtensionDeviceSource?
    private let logger = EngineLog.logger("vcam.ext.source")

    init(formats: [CMIOExtensionStreamFormat], deviceSource: PrismExtensionDeviceSource) {
        self.formats = formats
        self.deviceSource = deviceSource
        super.init()
        stream = CMIOExtensionStream(
            localizedName: "\(PrismVCamConstants.deviceName) Video",
            streamID: PrismVCamConstants.sourceStreamID,
            direction: .source,
            clockType: .hostTime, // house time == host clock (PrismCore.HouseClock)
            source: self
        )
    }

    // MARK: CMIOExtensionStreamSource

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = deviceSource?.activeFormatIndex ?? 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = deviceSource?.frameDuration
                ?? CMTime(value: 1, timescale: PrismVCamConstants.frameRate)
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex {
            guard formats.indices.contains(index) else {
                throw NSError(domain: CMIOExtensionErrorDomain(),
                              code: Int(kCMIOHardwareIllegalOperationError),
                              userInfo: [NSLocalizedDescriptionKey: "Invalid format index \(index)"])
            }
            deviceSource?.activeFormatIndex = index
        }
        if let duration = streamProperties.frameDuration {
            deviceSource?.frameDuration = duration
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        // Any camera-authorized app may consume the source stream.
        logger.info("source stream client authorized: \(client.signingID ?? "unknown", privacy: .public) pid=\(client.pid)")
        return true
    }

    func startStream() throws {
        deviceSource?.sourceStreamStarted()
    }

    func stopStream() throws {
        deviceSource?.sourceStreamStopped()
    }
}

/// Stream source for the SINK-direction stream — the back door the Prism app
/// (via `VirtualCameraFeeder`) pushes program frames into. Consumed buffers
/// are mirrored 1:1 onto the source stream by the device source.
final class PrismExtensionStreamSink: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    let formats: [CMIOExtensionStreamFormat]
    private weak var deviceSource: PrismExtensionDeviceSource?
    private let logger = EngineLog.logger("vcam.ext.sink")

    /// The most recent client authorized on this stream; `startStream()` has
    /// no client parameter, so we capture it here (the CMIOExtension idiom —
    /// authorize is always called before start for the same client).
    private(set) var connectedClient: CMIOExtensionClient?

    init(formats: [CMIOExtensionStreamFormat], deviceSource: PrismExtensionDeviceSource) {
        self.formats = formats
        self.deviceSource = deviceSource
        super.init()
        stream = CMIOExtensionStream(
            localizedName: "\(PrismVCamConstants.deviceName) Sink",
            streamID: PrismVCamConstants.sinkStreamID,
            direction: .sink,
            clockType: .hostTime,
            source: self
        )
    }

    // MARK: CMIOExtensionStreamSource

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration,
         .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup,
         .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = deviceSource?.activeFormatIndex ?? 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = deviceSource?.frameDuration
                ?? CMTime(value: 1, timescale: PrismVCamConstants.frameRate)
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = PrismVCamConstants.sinkQueueSize
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = PrismVCamConstants.sinkBuffersRequiredForStartup
        }
        if properties.contains(.streamSinkBufferUnderrunCount) {
            streamProperties.sinkBufferUnderrunCount = 0
        }
        if properties.contains(.streamSinkEndOfData) {
            streamProperties.sinkEndOfData = 0
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex, formats.indices.contains(index) {
            deviceSource?.activeFormatIndex = index
        }
        if let duration = streamProperties.frameDuration {
            deviceSource?.frameDuration = duration
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        // Only the Prism app may FEED the sink; reject any other local process,
        // which would otherwise inject arbitrary frames onto the camera that
        // Zoom/Meet/FaceTime consume. (Consuming the camera is unaffected — that
        // gate lives on the SOURCE stream, not here.)
        guard PrismVCamConstants.isAuthorizedSinkClient(signingID: client.signingID) else {
            logger.error("sink stream client REJECTED: \(client.signingID ?? "unknown", privacy: .public) pid=\(client.pid)")
            return false
        }
        logger.info("sink stream client authorized: \(client.signingID ?? "unknown", privacy: .public) pid=\(client.pid)")
        connectedClient = client
        return true
    }

    func startStream() throws {
        guard let client = connectedClient else {
            throw NSError(domain: CMIOExtensionErrorDomain(),
                          code: Int(kCMIOHardwareNotRunningError),
                          userInfo: [NSLocalizedDescriptionKey: "Sink started with no authorized client"])
        }
        deviceSource?.sinkStreamStarted(client: client)
    }

    func stopStream() throws {
        connectedClient = nil
        deviceSource?.sinkStreamStopped()
    }
}

/// CMIOExtension has no public error domain constant; use a stable string so
/// client-visible NSErrors are at least identifiable.
func CMIOExtensionErrorDomain() -> String { "studio.prism.vcam.extension" }
