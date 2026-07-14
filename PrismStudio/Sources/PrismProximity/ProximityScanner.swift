#if os(macOS)
import CoreBluetooth
import Foundation
import PrismCore

/// macOS **central** role: scans for iOS devices advertising the Prism service
/// UUID and surfaces each as a ``ProximityCandidate`` (name + RSSI proximity +
/// lastSeen). This feeds the app's "nearby devices" list; picking one starts
/// the existing Wi-Fi short-code / QR pairing (`PrismLink`). BLE here does
/// discovery only — no media, no pairing code (see ``ProximityProtocol``).
///
/// Real scanning is deferred to ``start()`` (which creates the
/// `CBCentralManager` and triggers the Bluetooth permission prompt), so
/// constructing a scanner is prompt-free.
public final class ProximityScanner: NSObject {
    private let log = EngineLog.logger("proximity.scanner")

    /// Fired whenever a candidate appears or updates (dedup already applied).
    public var onCandidate: ((ProximityCandidate, _ isNew: Bool) -> Void)?
    /// Fired with the IDs of candidates that went stale and were dropped.
    public var onCandidatesExpired: (([UUID]) -> Void)?
    /// Fired when the radio state changes (poweredOn/unauthorized/…).
    public var onStateChange: ((ProximityRadioState) -> Void)?

    /// Latest known radio state.
    public private(set) var state: ProximityRadioState = .unknown

    /// Snapshot of current candidates, most-recently-seen first.
    public var candidates: [ProximityCandidate] { store.all }

    private var store: CandidateStore
    private let queue = DispatchQueue(label: "studio.prism.proximity.scanner")
    private var central: CBCentralManager?
    /// Whether the caller currently wants to scan. Without this, a `stop()` that
    /// lands before `.poweredOn` arrives would be undone when the delegate later
    /// fires `didUpdateState(.poweredOn)` and unconditionally began scanning —
    /// scanning with the toggle off, and never torn down (Codex C2).
    private var wantsScan = false
    private var pruneTimer: DispatchSourceTimer?
    /// Peripherals with an in-flight token fetch (connect→read→disconnect).
    /// `CBCentralManager` does not retain peripherals it hands out, so we hold a
    /// strong reference here for the duration of the connection.
    private var connecting: [UUID: CBPeripheral] = [:]

    public init(staleAfter: TimeInterval = 10) {
        store = CandidateStore(staleAfter: staleAfter)
        super.init()
    }

    /// Create the central manager (if needed) and begin scanning once the radio
    /// is powered on. **Triggers the Bluetooth permission prompt** — never call
    /// from headless verification.
    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsScan = true
            if self.central == nil {
                // Delegate callbacks land on `queue`; scanning starts from
                // `centralManagerDidUpdateState` once poweredOn.
                self.central = CBCentralManager(delegate: self, queue: self.queue,
                                                options: [CBCentralManagerOptionShowPowerAlertKey: true])
            } else {
                self.beginScanIfReady()
            }
            self.startPruneTimer()
        }
    }

    /// Stop scanning, forget candidates, and tear down the prune timer. The
    /// central manager is retained so a later `start()` doesn't re-prompt.
    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsScan = false
            self.central?.stopScan()
            // Tear down any in-flight token fetches.
            for peripheral in self.connecting.values {
                self.central?.cancelPeripheralConnection(peripheral)
            }
            self.connecting.removeAll()
            self.store.removeAll()
            self.pruneTimer?.cancel()
            self.pruneTimer = nil
        }
    }

    // MARK: - Internals (all on `queue`)

    private func beginScanIfReady() {
        guard wantsScan, let central, central.state == .poweredOn else { return }
        // Allow duplicate discoveries so RSSI / lastSeen keep refreshing.
        central.scanForPeripherals(
            withServices: [ProximityProtocol.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        log.info("proximity: scanning for \(ProximityProtocol.serviceUUIDString, privacy: .public)")
    }

    private func startPruneTimer() {
        guard pruneTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let expired = self.store.prune(at: Date())
            if !expired.isEmpty { self.onCandidatesExpired?(expired) }
        }
        timer.resume()
        pruneTimer = timer
    }

    /// Reconstruct the presence name from a raw CoreBluetooth advertisement
    /// dict. The device name comes from the local-name / peripheral name.
    ///
    /// The token is **not** in the advertisement in practice: iOS strips
    /// arbitrary advertisement service-data, so `CBAdvertisementDataServiceDataKey`
    /// is (almost) never present for our UUID. We still parse it opportunistically
    /// (a non-iOS advertiser *could* include it), but the reliable delivery path
    /// is a connected characteristic read (see ``maybeFetchToken`` /
    /// ``applyReadPayload``). When neither yields a token, dedup honestly falls
    /// back to `peripheralID` alone.
    private func decodeAdvertisement(_ advertisementData: [String: Any],
                                     peripheral: CBPeripheral) -> (name: String?, token: ProximityToken?) {
        var name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? peripheral.name
        var token: ProximityToken?
        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
           let blob = serviceData[ProximityProtocol.serviceUUID],
           let adv = ProximityProtocol.Advertisement.decode(blob) {
            token = adv.token
            if name == nil || name?.isEmpty == true { name = adv.name }
        }
        return (name, token)
    }

    /// Kick off a connect→read→disconnect to fetch the presence token when we
    /// don't already have one for this peripheral. iOS can't advertise the token
    /// in the PDU, so a connected characteristic read is the delivery path. Only
    /// one fetch per peripheral is in flight at a time, and we skip peripherals
    /// whose token we already hold.
    ///
    /// Must run on `queue`. UNVERIFIED end-to-end (needs a real central + a live
    /// advertiser); the payload decode it drives is logic-tested via
    /// ``applyReadPayload``.
    private func maybeFetchToken(for peripheral: CBPeripheral, haveAdvertisedToken: Bool) {
        guard let central else { return }
        guard !haveAdvertisedToken else { return }
        guard store.candidate(for: peripheral.identifier)?.token == nil else { return }
        guard connecting[peripheral.identifier] == nil else { return } // fetch already in flight
        connecting[peripheral.identifier] = peripheral                 // retain across the connection
        central.connect(peripheral, options: nil)
    }

    /// Fold a characteristic-read payload's token (and any name) into the store,
    /// refreshing the candidate and firing ``onCandidate``. Returns the updated
    /// candidate, or `nil` if the payload was malformed.
    ///
    /// This is the logic-testable seam of the connected-read delivery path: it
    /// takes raw bytes + a peripheral ID (no CoreBluetooth objects), so the
    /// self-test exercises the encode→read→decode round-trip headlessly.
    /// Must run on `queue`.
    @discardableResult
    func applyReadPayload(_ value: Data, peripheralID: UUID, at now: Date = Date()) -> ProximityCandidate? {
        guard let adv = ProximityProtocol.Advertisement.decode(value) else { return nil }
        // Preserve the last-known RSSI; `observe` updates token/name in place for
        // a known peripheral (keeping firstSeen) or inserts a fresh candidate.
        let rssi = store.candidate(for: peripheralID)?.rssi ?? 0
        let result = store.observe(peripheralID: peripheralID, name: adv.name,
                                   token: adv.token, rssi: rssi, at: now)
        onCandidate?(result.candidate, result.isNew)
        return result.candidate
    }
}

extension ProximityScanner: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = ProximityRadioState(central.state)
        onStateChange?(state)
        switch central.state {
        case .poweredOn:
            beginScanIfReady()
        case .unauthorized:
            log.error("proximity: Bluetooth unauthorized — needs NSBluetoothAlwaysUsageDescription + user grant")
        case .unsupported:
            log.error("proximity: Bluetooth LE unsupported on this Mac")
        default:
            store.removeAll()
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let (name, token) = decodeAdvertisement(advertisementData, peripheral: peripheral)
        let result = store.observe(peripheralID: peripheral.identifier, name: name, token: token,
                                   rssi: RSSI.intValue, at: Date())
        onCandidate?(result.candidate, result.isNew)
        // The token isn't in the PDU on iOS — fetch it via a connected read.
        maybeFetchToken(for: peripheral, haveAdvertisedToken: token != nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([ProximityProtocol.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        connecting.removeValue(forKey: peripheral.identifier)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        connecting.removeValue(forKey: peripheral.identifier)
    }
}

extension ProximityScanner: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == ProximityProtocol.serviceUUID }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([ProximityProtocol.characteristicUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        guard error == nil,
              let characteristic = service.characteristics?
                .first(where: { $0.uuid == ProximityProtocol.characteristicUUID }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.readValue(for: characteristic)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        // One-shot read: decode the token, then disconnect regardless of outcome.
        defer { central?.cancelPeripheralConnection(peripheral) }
        guard error == nil, characteristic.uuid == ProximityProtocol.characteristicUUID,
              let value = characteristic.value else { return }
        applyReadPayload(value, peripheralID: peripheral.identifier)
    }
}
#endif
