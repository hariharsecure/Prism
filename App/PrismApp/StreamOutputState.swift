import Foundation

/// Requested-vs-confirmed lifecycle for the STREAMING output (Phase 2f).
///
/// The `isOnAir` bug (`OnAirStatusTests`) was one instance of a wider class:
/// the streaming surface was tracked by loose booleans (`isStreaming`) plus a
/// free-form `streamStateDescription` string that were each written at several
/// call sites and could drift from what the encoder + socket were actually
/// doing. This enum is the SINGLE SOURCE OF TRUTH for the streaming output:
/// `AppEngine.isStreaming`, `AppEngine.isOnAir` (via `computeOnAir`), and
/// `AppEngine.streamStateDescription` all derive from it.
///
/// It separates what was REQUESTED from what is CONFIRMED:
///  - `.preparing` — go-live was requested and the encoder/socket are starting,
///    but the single-RTMP publish is NOT yet confirmed.
///  - `.live` — publishing is CONFIRMED (the RTMP socket reported `.publishing`,
///    or a destinations-only broadcast whose encoder is running).
///
/// SCOPE (bounded, per the 2f spec): this models the STREAMING output only.
/// Recording and the virtual camera keep their existing state (`isRecording`,
/// `vcamOutputEnabled` gated on the feeder's confirmed `.feeding`); folding them
/// into an analogous model is a follow-up, not this pass.
enum StreamOutputState: Equatable, Sendable {
    /// No stream requested — the resting state.
    case idle
    /// REQUESTED: go-live issued; encoder + single-RTMP socket are connecting,
    /// publish not yet confirmed.
    case preparing
    /// CONFIRMED: the socket is publishing (or a destinations-only broadcast is
    /// running). This is the only state that means "actually reaching a viewer".
    case live
    /// Was live; the socket dropped and is retrying. Still an active output.
    case reconnecting(attempt: Int)
    /// Live but impaired (e.g. a subset of destinations degraded). Reserved for a
    /// follow-up that surfaces per-destination health; the reducer supports it so
    /// the model is complete.
    case degraded(reason: String)
    /// Stop requested; external outputs are closing (the 2c teardown barrier).
    case stopping
    /// Terminal failure (connect failed, socket failed). Not an active output.
    case failed(reason: String)

    /// Whether this state counts as a live output — feeds `isStreaming` and, via
    /// `computeOnAir`, `isOnAir`. True for every requested/confirmed/tearing-down
    /// state (so a stream that is connecting or reconnecting still reads on-air,
    /// preserving the pre-2f `isStreaming` semantics); false only at rest
    /// (`.idle`) or after a terminal `.failed`.
    var isActiveOutput: Bool {
        switch self {
        case .idle, .failed:
            return false
        case .preparing, .live, .reconnecting, .degraded, .stopping:
            return true
        }
    }

    /// Human-facing status string. `streamStateDescription` (UI + obs-websocket
    /// StreamStatus + link-debug state file) derives from this, so the display can
    /// never diverge from the state. The `reconnecting` prefix is load-bearing:
    /// `EngineControlBackend.streamStatus()` reads it.
    var description: String {
        switch self {
        case .idle: return "idle"
        case .preparing: return "connecting"
        case .live: return "live"
        case .reconnecting(let attempt): return "reconnecting (attempt \(attempt))"
        case .degraded(let reason): return "degraded: \(reason)"
        case .stopping: return "stopping"
        case .failed(let reason): return "failed: \(reason)"
        }
    }
}

/// The events that drive `StreamOutputState`. Kept separate from
/// `RTMPStreamOutput.ConnectionState` so the transition table is a PURE,
/// unit-testable seam (`StreamOutputStateTests`) that needs no live socket.
enum StreamOutputEvent: Equatable, Sendable {
    /// Go-live requested. Always enters `.preparing` (REQUESTED): a single-RTMP
    /// primary must confirm publishing, and — after #9 — a destinations-only
    /// broadcast likewise stays `.preparing` until at least one destination
    /// actually reports publishing (it is NOT live the instant its encoder runs).
    case requestStart
    /// The single-RTMP socket is connecting (not yet publishing).
    case socketConnecting
    /// The single-RTMP socket confirmed publishing.
    case socketPublishing
    /// The socket dropped and is retrying.
    case socketReconnecting(attempt: Int)
    /// Live but impaired.
    case degraded(reason: String)
    /// Stop requested (operator stop, or an internal teardown).
    case requestStop
    /// The output closed cleanly (terminal).
    case closed
    /// The output failed (terminal).
    case failed(reason: String)
}

extension StreamOutputState {
    /// PURE requested→confirmed transition. The engine funnels every real event
    /// (go-live, RTMP `ConnectionState` updates, stop, failure) through this so
    /// the lifecycle lives in one place and is testable without a socket.
    static func reduce(_ state: StreamOutputState, on event: StreamOutputEvent) -> StreamOutputState {
        switch event {
        case .requestStart:
            // REQUESTED: a primary is only confirmed when its socket publishes,
            // and (#9) a destinations-only broadcast is only confirmed when ≥1
            // destination reports publishing. Both start `.preparing`.
            return .preparing
        case .socketConnecting:
            return .preparing
        case .socketPublishing:
            return .live
        case .socketReconnecting(let attempt):
            return .reconnecting(attempt: attempt)
        case .degraded(let reason):
            return .degraded(reason: reason)
        case .requestStop:
            return .stopping
        case .closed:
            return .idle
        case .failed(let reason):
            return .failed(reason: reason)
        }
    }
}
