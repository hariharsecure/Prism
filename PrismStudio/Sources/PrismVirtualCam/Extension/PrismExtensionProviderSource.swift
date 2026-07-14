import CoreMediaIO
import Foundation
import PrismCore

/// Provider source for the Prism CMIO camera extension. One provider, one
/// device ("Prism Camera"), created eagerly at startup so clients can bind
/// the moment the extension process is launched by the CMIO registry.
///
/// This class compiles into the PrismVirtualCam library; the actual
/// .systemextension target is a thin `main.swift` that calls
/// `PrismVirtualCamExtension.main()` (see README.md for the embedding steps).
public final class PrismExtensionProviderSource: NSObject, CMIOExtensionProviderSource {

    public private(set) var provider: CMIOExtensionProvider!
    private let deviceSource: PrismExtensionDeviceSource
    private let logger = EngineLog.logger("vcam.ext.provider")

    /// - Parameter clientQueue: queue for CMIOExtension callbacks; nil = default.
    public init(clientQueue: DispatchQueue?) {
        deviceSource = PrismExtensionDeviceSource()
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add Prism Camera device to provider: \(error)")
        }
        logger.info("provider up; device \(PrismVCamConstants.deviceUID, privacy: .public) registered")
    }

    // MARK: CMIOExtensionProviderSource

    public func connect(to client: CMIOExtensionClient) throws {
        logger.info("client connected: \(client.signingID ?? "unknown", privacy: .public) pid=\(client.pid)")
    }

    public func disconnect(from client: CMIOExtensionClient) {
        logger.info("client disconnected: \(client.signingID ?? "unknown", privacy: .public) pid=\(client.pid)")
    }

    public var availableProperties: Set<CMIOExtensionProperty> {
        [.providerName, .providerManufacturer]
    }

    public func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerName) {
            providerProperties.name = PrismVCamConstants.providerName
        }
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = PrismVCamConstants.manufacturer
        }
        return providerProperties
    }

    public func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
        // Nothing settable.
    }
}

/// Entry point for the .systemextension executable. Its whole `main.swift` is:
///
///     import PrismVirtualCam
///     PrismVirtualCamExtension.main()
public enum PrismVirtualCamExtension {
    public static func main() -> Never {
        let providerSource = PrismExtensionProviderSource(clientQueue: nil)
        CMIOExtensionProvider.startService(provider: providerSource.provider)
        dispatchMain() // never returns; CMIOExtension callbacks drive everything
    }
}
