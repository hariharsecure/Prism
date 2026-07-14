import Foundation
import Network
import PrismOutput
import os

// MARK: - Preflight "Broadcast Check" (deliverable 2)
//
// A before-you-go-live checklist. Each check returns pass / warn / fail with a
// human message. The stateless probes (disk, thermal, encoder trial, TCP host
// reachability) live here; `AppEngine.runBroadcastCheck()` assembles them with
// the engine-state checks (sources present, link listener) it alone can read.

/// A single check's outcome. `.warn` = go-able but worth a look; `.fail` =
/// blocker.
enum CheckStatus: String, Sendable {
    case pass
    case warn
    case fail
}

/// One preflight check result.
struct CheckResult: Identifiable, Sendable {
    let id: String        // stable key ("disk", "thermal", …) — also the SF row id
    let title: String
    let status: CheckStatus
    let message: String
}

/// The aggregate report a Broadcast Check produces.
struct BroadcastReport: Sendable {
    let results: [CheckResult]
    let generatedAt: Date

    /// Worst status across all checks (fail > warn > pass).
    var overall: CheckStatus {
        if results.contains(where: { $0.status == .fail }) { return .fail }
        if results.contains(where: { $0.status == .warn }) { return .warn }
        return .pass
    }
}

/// Namespace for the stateless preflight probes.
enum BroadcastCheck {
    /// Recording budget assumption: ~5 GB per hour for 1080p60 H.264.
    static let gbPerHour = 5.0

    // MARK: Disk

    /// Available recording space on the volume backing `directory`.
    /// fail < 1 hr, warn < 3 hr, pass otherwise.
    static func diskCheck(directory: URL) -> CheckResult {
        let bytes = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0
        let gb = Double(bytes) / 1_073_741_824
        let hours = gb / gbPerHour
        let detail = String(format: "%.1f GB free (~%.1f h at %.0f GB/h)", gb, hours, gbPerHour)
        let status: CheckStatus = hours < 1 ? .fail : (hours < 3 ? .warn : .pass)
        return CheckResult(id: "disk", title: "Disk space", status: status, message: detail)
    }

    // MARK: Thermal / CPU

    static func thermalCheck() -> CheckResult {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            return CheckResult(id: "thermal", title: "Thermal state", status: .pass, message: "Nominal.")
        case .fair:
            return CheckResult(id: "thermal", title: "Thermal state", status: .pass, message: "Fair — plenty of headroom.")
        case .serious:
            return CheckResult(id: "thermal", title: "Thermal state", status: .warn,
                               message: "Serious — the Mac is warm. Consider lowering output settings.")
        case .critical:
            return CheckResult(id: "thermal", title: "Thermal state", status: .fail,
                               message: "Critical — the Mac is overheating. Cool down before going live.")
        @unknown default:
            return CheckResult(id: "thermal", title: "Thermal state", status: .warn, message: "Unknown thermal state.")
        }
    }

    // MARK: Encoder

    /// Trial-start a program encoder (hardware H.264) and stop it, proving the
    /// output path can spin up before going live.
    ///
    /// When the engine is already streaming and/or recording (`encoderInUse`), a
    /// HW encoder is demonstrably working — opening a THIRD 1080p60 session here
    /// would contend for the fixed HW encoder pool and could spuriously fail, so
    /// we skip the trial and report pass instead (Codex #3).
    static func encoderTrial(encoderInUse: Bool = false) -> CheckResult {
        if encoderInUse {
            return CheckResult(id: "encoder", title: "Encoder", status: .pass,
                               message: "Encoder in use by an active output — OK.")
        }
        let encoder = ProgramEncoder(settings: .init(codec: .h264, width: 1920, height: 1080,
                                                     averageBitrate: 6_000_000, expectedFrameRate: 60))
        do {
            try encoder.start()
            encoder.stop()
            return CheckResult(id: "encoder", title: "Encoder", status: .pass,
                               message: "Hardware H.264 encoder started and stopped cleanly.")
        } catch {
            return CheckResult(id: "encoder", title: "Encoder", status: .fail,
                               message: "Program encoder could not start: \(error.localizedDescription)")
        }
    }

    // MARK: Network reachability (TCP connect probe)

    /// One-shot TCP connect to `host:port`. `true` iff the connection reaches
    /// `.ready` within `timeout`. Never throws; a firewall/DNS/timeout → false.
    static func tcpProbe(host: String, port: UInt16, timeout: TimeInterval = 4) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ ok: Bool) {
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                guard first else { return }
                connection.cancel()
                continuation.resume(returning: ok)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}
