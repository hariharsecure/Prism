#if os(iOS)
import CoreBluetooth
import Foundation
import PrismCore

/// iOS **peripheral** role: advertises the Prism service UUID + device name +
/// a rotating presence token so a nearby Mac can surface "this iPhone is here
/// and willing to pair" *before* any Wi-Fi association. It NEVER advertises the
/// pairing code / PSK (see ``ProximityProtocol``); the real pairing + all media
/// happen over Wi-Fi (`PrismLink`).
///
/// Advertising is deferred to ``start(name:)`` (which creates the
/// `CBPeripheralManager` and triggers the Bluetooth permission prompt), so
/// constructing an advertiser is prompt-free.
public final class ProximityAdvertiser: NSObject {
    private let log = EngineLog.logger("proximity.advertiser")

    /// Fired when the radio state changes.
    public var onStateChange: ((ProximityRadioState) -> Void)?

    /// Latest known radio state.
    public private(set) var state: ProximityRadioState = .unknown
    /// Whether advertising is currently requested (may await poweredOn).
    public private(set) var isAdvertising = false

    /// How often the presence token rotates (privacy anti-correlation).
    public let tokenRotationInterval: TimeInterval

    private let queue = DispatchQueue(label: "studio.prism.proximity.advertiser")
    private var peripheral: CBPeripheralManager?
    private var characteristic: CBMutableCharacteristic?
    private var rotator: TokenRotator?
    private var deviceName: String = ""
    private var rotationTimer: DispatchSourceTimer?

    public init(tokenRotationInterval: TimeInterval = 900) {
        self.tokenRotationInterval = tokenRotationInterval
        super.init()
    }

    /// Begin advertising presence under `name`. **Triggers the Bluetooth
    /// permission prompt** — never call from headless verification.
    ///
    /// Throws `ProximityError.tokenGenerationFailed` if the first token can't
    /// be minted.
    public func start(name: String) throws {
        let rotator = try TokenRotator()   // fail fast before touching the radio
        queue.async { [weak self] in
            guard let self else { return }
            self.deviceName = name
            self.rotator = rotator
            self.isAdvertising = true
            if self.peripheral == nil {
                self.peripheral = CBPeripheralManager(delegate: self, queue: self.queue,
                                                      options: [CBPeripheralManagerOptionShowPowerAlertKey: true])
            } else {
                self.beginAdvertisingIfReady()
            }
        }
    }

    /// Stop advertising and cancel token rotation. The peripheral manager is
    /// retained so a later `start` doesn't re-prompt.
    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isAdvertising = false
            self.peripheral?.stopAdvertising()
            self.rotationTimer?.cancel()
            self.rotationTimer = nil
        }
    }

    // MARK: - Internals (all on `queue`)

    private func beginAdvertisingIfReady() {
        guard let peripheral, peripheral.state == .poweredOn,
              isAdvertising, rotator?.current != nil else { return }

        // Publish a readable characteristic carrying name+token. This is the
        // ONLY path by which the token reaches a central: iOS strips arbitrary
        // advertisement service-data, so a scanner CONNECTS and reads this
        // characteristic to obtain the token (see `ProximityScanner`).
        //
        // The characteristic is created **value-less** (`value: nil`): a
        // CBMutableCharacteristic given a static `value` is cached read-only by
        // CoreBluetooth and never routes reads to `didReceiveRead`, so a rotated
        // token would never be seen (#8). With `value: nil`, every read is
        // served dynamically from the *current* token below.
        peripheral.removeAllServices()
        let characteristic = CBMutableCharacteristic(
            type: ProximityProtocol.characteristicUUID,
            properties: [.read], value: nil, permissions: [.readable])
        let service = CBMutableService(type: ProximityProtocol.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        peripheral.add(service)
        self.characteristic = characteristic

        // Advertise the service UUID + the human name. (iOS restricts advertised
        // keys to the service UUIDs and local name; the rotating token is NOT in
        // the PDU — it is delivered on a connected characteristic read.)
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [ProximityProtocol.serviceUUID],
            CBAdvertisementDataLocalNameKey: deviceName,
        ])
        startRotationTimer()
        // Device name is .private (identifies a person, e.g. "Rishi's iPhone");
        // the presence token is intentionally NOT logged (secret + anti-correlation).
        log.info("proximity: advertising as \(self.deviceName, privacy: .private)")
    }

    private func startRotationTimer() {
        guard rotationTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + tokenRotationInterval, repeating: tokenRotationInterval)
        timer.setEventHandler { [weak self] in self?.rotateToken() }
        timer.resume()
        rotationTimer = timer
    }

    private func rotateToken() {
        guard (try? rotator?.rotate()) != nil else { return }
        // No cached value to mutate: reads are served live in
        // `peripheralManager(_:didReceiveRead:)` from the current token, so the
        // rotated value is delivered on the next connected read (#8). The token
        // value itself is never logged (secret + anti-correlation).
        log.debug("proximity: rotated presence token")
    }

    /// The encoded presence payload for the current name+token, or `nil` if no
    /// token has been minted yet. Rebuilt on each call so a read always reflects
    /// the freshest rotation.
    private func currentPayload() -> Data? {
        guard let token = rotator?.current else { return nil }
        return ProximityProtocol.Advertisement(name: deviceName, token: token).encode()
    }
}

extension ProximityAdvertiser: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        state = ProximityRadioState(peripheral.state)
        onStateChange?(state)
        switch peripheral.state {
        case .poweredOn:
            beginAdvertisingIfReady()
        case .unauthorized:
            log.error("proximity: Bluetooth unauthorized — needs NSBluetoothAlwaysUsageDescription + user grant")
        case .unsupported:
            log.error("proximity: Bluetooth LE unsupported on this device")
        default:
            break
        }
    }

    /// Serve reads of the presence characteristic from the CURRENT token (#8).
    /// Because the characteristic is value-less, CoreBluetooth routes every read
    /// here, so a token that rotated after `service.add` is still delivered.
    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == ProximityProtocol.characteristicUUID,
              let value = currentPayload() else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        // Honor the ATT read offset (long-read continuation).
        guard request.offset <= value.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = value.subdata(in: value.startIndex.advanced(by: request.offset)..<value.endIndex)
        peripheral.respond(to: request, withResult: .success)
    }
}
#endif
