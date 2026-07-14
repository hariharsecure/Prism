import CoreBluetooth
import Foundation
import PrismCore

/// Typed failures across the proximity layer.
public enum ProximityError: Error, CustomStringConvertible {
    /// `SecRandomCopyBytes` failed while minting a presence token.
    case tokenGenerationFailed(OSStatus)
    /// The radio isn't usable (off / unsupported / resetting).
    case radioUnavailable(ProximityRadioState)
    /// The user hasn't granted (or has denied) Bluetooth permission.
    case unauthorized(ProximityAuthorization)
    /// A role was started on the wrong platform (e.g. advertising on macOS).
    case roleUnavailable(String)

    public var description: String {
        switch self {
        case .tokenGenerationFailed(let s):
            return "proximity token generation failed (OSStatus \(s))"
        case .radioUnavailable(let state):
            return "Bluetooth radio unavailable: \(state)"
        case .unauthorized(let auth):
            return "Bluetooth not authorized: \(auth) — add NSBluetoothAlwaysUsageDescription and prompt the user"
        case .roleUnavailable(let why):
            return "proximity role unavailable: \(why)"
        }
    }
}

/// Radio state, mapped from `CBManagerState` so callers never import
/// CoreBluetooth just to switch on state. Mapping is pure (no manager needed).
public enum ProximityRadioState: String, Equatable, Sendable {
    case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn

    public init(_ state: CBManagerState) {
        switch state {
        case .unknown: self = .unknown
        case .resetting: self = .resetting
        case .unsupported: self = .unsupported
        case .unauthorized: self = .unauthorized
        case .poweredOff: self = .poweredOff
        case .poweredOn: self = .poweredOn
        @unknown default: self = .unknown
        }
    }

    /// True only when scanning/advertising can actually run.
    public var isUsable: Bool { self == .poweredOn }
}

/// Authorization, mapped from `CBManagerAuthorization`. Pure mapping.
public enum ProximityAuthorization: String, Equatable, Sendable {
    case notDetermined, restricted, denied, allowed, unknown

    public init(_ auth: CBManagerAuthorization) {
        switch auth {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .allowedAlways: self = .allowed
        @unknown default: self = .unknown
        }
    }
}

/// Front door for PrismProximity. Owns the platform-appropriate role: on macOS
/// it scans (central) for nearby iOS companions; on iOS it advertises
/// (peripheral) so a Mac can find it. Media + real pairing always happen
/// elsewhere over Wi-Fi (`PrismLink`).
///
/// ## Runtime requirement
/// CoreBluetooth prompts on first use, so the host app's Info.plist MUST carry
/// `NSBluetoothAlwaysUsageDescription` (both roles) — without it the process is
/// killed the moment a `CBCentralManager`/`CBPeripheralManager` is created. No
/// manager is created until ``startDiscovery()`` / ``startAdvertising(name:)``
/// is called, so merely constructing a controller is prompt-free and safe in
/// tests.
public final class ProximityController {
    private let log = EngineLog.logger("proximity")

    #if os(macOS)
    /// The central-role scanner (macOS).
    public let scanner: ProximityScanner

    public init(staleAfter: TimeInterval = 10) {
        scanner = ProximityScanner(staleAfter: staleAfter)
    }

    /// Begin scanning for nearby Prism companions. Triggers the Bluetooth
    /// permission prompt on first use — do NOT call in headless verification.
    public func startDiscovery() {
        log.info("proximity: starting discovery (central)")
        scanner.start()
    }

    public func stopDiscovery() {
        log.info("proximity: stopping discovery")
        scanner.stop()
    }
    #elseif os(iOS)
    /// The peripheral-role advertiser (iOS).
    public let advertiser: ProximityAdvertiser

    public init() {
        advertiser = ProximityAdvertiser()
    }

    /// Begin advertising presence under `name`. Triggers the Bluetooth
    /// permission prompt on first use — do NOT call in headless verification.
    public func startAdvertising(name: String) throws {
        log.info("proximity: starting advertising (peripheral)")
        try advertiser.start(name: name)
    }

    public func stopAdvertising() {
        log.info("proximity: stopping advertising")
        advertiser.stop()
    }
    #else
    public init() {}
    #endif
}
