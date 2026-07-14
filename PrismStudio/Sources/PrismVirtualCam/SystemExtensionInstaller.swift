import Foundation
import os
import PrismCore
import SystemExtensions

/// Thin async wrapper around OSSystemExtensionRequest for activating /
/// deactivating the Prism camera extension.
///
/// This compiles and is logic-complete in the library, but activation only
/// *works* from inside a signed .app bundle that embeds the extension at
/// Contents/Library/SystemExtensions/ (OSSystemExtensionRequest hard-requires
/// it) — see README.md. Runtime behavior is therefore UNVERIFIED until the
/// integrator has a signed bundle.
public final class SystemExtensionInstaller: NSObject, @unchecked Sendable {

    // MARK: Public surface

    public enum Phase: Sendable, Equatable {
        /// Request submitted to sysextd.
        case submitted
        /// macOS wants the user to approve the extension in
        /// System Settings → General → Login Items & Extensions.
        /// The request stays pending; a terminal phase follows approval.
        case requiresApproval
        /// Extension activated and running.
        case activated
        /// Activation accepted but takes effect after reboot
        /// (OSSystemExtensionRequest.Result.willCompleteAfterReboot).
        case activatedAfterReboot
        /// Deactivation finished.
        case deactivated
    }

    public enum InstallerError: Error {
        /// Another request from this installer is still in flight.
        case requestAlreadyInFlight
        /// sysextd reported failure (payload is the framework error,
        /// typically an OSSystemExtensionError).
        case requestFailed(any Error)
    }

    /// Interim-phase callback (`.submitted`, `.requiresApproval`), so a UI
    /// can walk the user through the System Settings approval. Called on
    /// `callbackQueue`.
    public var onPhaseChange: ((Phase) -> Void)?

    private let callbackQueue: DispatchQueue

    public init(callbackQueue: DispatchQueue = .main) {
        self.callbackQueue = callbackQueue
        super.init()
    }

    /// Activate (install or upgrade) the extension. Resolves with the
    /// terminal phase — `.activated` or `.activatedAfterReboot` — or throws
    /// `InstallerError`. `.requiresApproval` is reported via `onPhaseChange`
    /// while this call stays suspended (user approval can take minutes).
    public func activate(extensionBundleID: String = PrismVCamConstants.extensionBundleID) async throws -> Phase {
        try await submit(kind: .activate, bundleID: extensionBundleID)
    }

    /// Deactivate (uninstall) the extension. Resolves with `.deactivated`.
    public func deactivate(extensionBundleID: String = PrismVCamConstants.extensionBundleID) async throws -> Phase {
        try await submit(kind: .deactivate, bundleID: extensionBundleID)
    }

    // MARK: - Internals

    private enum Kind { case activate, deactivate }

    private let logger = EngineLog.logger("vcam.installer")
    private let lock = OSAllocatedUnfairLock()
    // Guarded by `lock`. One request in flight at a time keeps delegate
    // dispatch trivial; parallel sysext requests are never needed here.
    private var pendingKind: Kind?
    private var pendingContinuation: CheckedContinuation<Phase, any Error>?

    private func submit(kind: Kind, bundleID: String) async throws -> Phase {
        try await withCheckedThrowingContinuation { continuation in
            let alreadyBusy: Bool = lock.withLock {
                if pendingContinuation != nil { return true }
                pendingKind = kind
                pendingContinuation = continuation
                return false
            }
            if alreadyBusy {
                continuation.resume(throwing: InstallerError.requestAlreadyInFlight)
                return
            }
            let request: OSSystemExtensionRequest
            switch kind {
            case .activate:
                request = .activationRequest(forExtensionWithIdentifier: bundleID, queue: callbackQueue)
            case .deactivate:
                request = .deactivationRequest(forExtensionWithIdentifier: bundleID, queue: callbackQueue)
            }
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
            logger.info("submitted \(String(describing: kind), privacy: .public) request for \(bundleID, privacy: .public)")
            reportPhase(.submitted)
        }
    }

    private func reportPhase(_ phase: Phase) {
        let callback = onPhaseChange
        callbackQueue.async { callback?(phase) }
    }

    private func finish(_ result: Result<Phase, any Error>) {
        let continuation: CheckedContinuation<Phase, any Error>? = lock.withLock {
            let c = pendingContinuation
            pendingContinuation = nil
            pendingKind = nil
            return c
        }
        switch result {
        case .success(let phase):
            logger.info("request finished: \(String(describing: phase), privacy: .public)")
            continuation?.resume(returning: phase)
        case .failure(let error):
            logger.error("request failed: \(String(describing: error), privacy: .public)")
            continuation?.resume(throwing: error)
        }
    }
}

// MARK: - OSSystemExtensionRequestDelegate

extension SystemExtensionInstaller: OSSystemExtensionRequestDelegate {

    public func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        // Upgrade policy: always replace. The extension itself is stateless
        // (dumb relay), so replacement is safe; version handshake with the
        // feeder happens at the DAL layer by device UID, which is stable.
        logger.info("replacing extension \(existing.bundleShortVersion, privacy: .public) → \(ext.bundleShortVersion, privacy: .public)")
        return .replace
    }

    public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        reportPhase(.requiresApproval)
    }

    public func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        let kind = lock.withLock { pendingKind }
        let phase: Phase
        switch result {
        case .willCompleteAfterReboot:
            phase = (kind == .deactivate) ? .deactivated : .activatedAfterReboot
        case .completed:
            phase = (kind == .deactivate) ? .deactivated : .activated
        @unknown default:
            phase = (kind == .deactivate) ? .deactivated : .activated
        }
        finish(.success(phase))
    }

    public func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        finish(.failure(InstallerError.requestFailed(error)))
    }
}
