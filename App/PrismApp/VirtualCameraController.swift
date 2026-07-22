import Foundation
import PrismVirtualCam

/// Owns the virtual-camera output subsystem — the CoreMediaIO system-extension
/// installer plus the DAL feeder that pushes the program frame to the "Prism
/// Camera" device — extracted out of `AppEngine` (Phase 4a decomposition).
///
/// `AppEngine` OWNS one of these and DELEGATES to it (composition, not
/// inheritance): the engine's public `activateVirtualCameraExtension()` /
/// `setVirtualCameraOutput(_:)` methods are byte-identical thin forwarders, and
/// the UI-bound `@Published` status properties (`vcamInstallStatus`,
/// `vcamActivationInFlight`, `vcamFeederStatus`, `vcamOutputRequested`,
/// `vcamOutputEnabled`) STAY on `AppEngine` — this controller pushes their
/// values back through the `on…` callbacks so the SwiftUI bindings are
/// untouched. Behavior is preserved exactly: same side-effect ordering, same
/// `@MainActor` threading, same async attach semantics (C30 — on-air flips only
/// once the feeder CONFIRMS `.feeding`).
@MainActor
final class VirtualCameraController {
    private let feeder = VirtualCameraFeeder()
    private let installer = SystemExtensionInstaller()
    /// The program fan-out the feeder attaches to. Shared with the rest of the
    /// engine and injected so the attach/forget ordering is identical.
    private let fanOut: ProgramFanOut

    // Status mirrors → AppEngine's UI-bound @Published properties. Set by the
    // owner right after construction; called synchronously on the main actor so
    // the published mirrors update with the exact same ordering as before.
    var onInstallStatus: (String) -> Void = { _ in }
    var onActivationInFlight: (Bool) -> Void = { _ in }
    var onFeederStatus: (String) -> Void = { _ in }
    var onOutputRequested: (Bool) -> Void = { _ in }
    var onOutputEnabled: (Bool) -> Void = { _ in }

    /// The user's toggle position, held here so the feeder's async `.feeding`
    /// confirmation can compute on-air (`requested && feeding`) exactly as the
    /// engine did when it read `vcamOutputRequested` inline.
    private var outputRequested = false
    /// Re-entrancy guard for `activate()` (was `vcamActivationInFlight`).
    private var activationInFlight = false

    init(fanOut: ProgramFanOut) {
        self.fanOut = fanOut
        feeder.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                self.onFeederStatus(Self.describe(state))
                // C30: on-air only once the feeder confirms .feeding; any
                // other state (searching/failed/stopped) is not on-air.
                self.onOutputEnabled(self.outputRequested && state == .feeding)
            }
        }
    }

    func activate() {
        guard !activationInFlight else { return }
        activationInFlight = true
        onActivationInFlight(true)
        onInstallStatus("Requesting activation…")
        installer.onPhaseChange = { [weak self] phase in
            DispatchQueue.main.async { self?.onInstallStatus(Self.describe(phase)) }
        }
        Task { @MainActor in
            do {
                let phase = try await installer.activate()
                onInstallStatus(Self.describe(phase))
            } catch {
                onInstallStatus("""
                Activation failed: \(error.localizedDescription) — note: unsigned/ad-hoc \
                builds can't install system extensions. Sign with a team, run from \
                /Applications (or enable `systemextensionsctl developer on`), then retry.
                """)
            }
            activationInFlight = false
            onActivationInFlight(false)
        }
    }

    func setOutput(_ enabled: Bool) {
        outputRequested = enabled
        onOutputRequested(enabled)
        if enabled {
            // C30: do NOT flip vcamOutputEnabled/isOnAir here — the feeder
            // starts asynchronously (search → attach). onStateChange sets
            // vcamOutputEnabled once the feeder confirms `.feeding`.
            feeder.start()
            fanOut.setFeeder(feeder)
        } else {
            onOutputEnabled(false)
            fanOut.setFeeder(nil)
            feeder.stop()
        }
    }

    /// Shutdown hook: stop the feeder now (releases the DAL stream on its serial
    /// work queue, returns immediately) and hand back the drain to await under
    /// the engine's external-output barrier so the vcam actually detaches.
    func stopFeederForShutdown() -> @Sendable () async -> Void {
        feeder.stop()
        let feeder = self.feeder
        return { await feeder.drainTeardown() }
    }

    private static func describe(_ phase: SystemExtensionInstaller.Phase) -> String {
        switch phase {
        case .submitted: return "Activation requested — waiting for macOS…"
        case .requiresApproval:
            return "Approval needed: System Settings → General → Login Items & Extensions"
        case .activated: return "Extension activated"
        case .activatedAfterReboot: return "Activated — takes effect after restart"
        case .deactivated: return "Extension deactivated"
        }
    }

    private static func describe(_ state: VirtualCameraFeeder.State) -> String {
        switch state {
        case .idle: return "Off"
        case .searching: return "Searching for Prism Camera device…"
        case .extensionNotInstalled: return "Extension not installed — activate it first"
        case .feeding: return "Feeding program to Prism Camera"
        case .stopped: return "Off"
        case .failed(let error): return "Failed: \(error)"
        }
    }
}
