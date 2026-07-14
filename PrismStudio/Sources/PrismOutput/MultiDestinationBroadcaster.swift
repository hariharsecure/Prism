import CoreMedia
import Foundation
import PrismCore
import os

/// Fans one already-encoded program stream to N live destinations (RTMP and/or
/// SRT) simultaneously — DESIGN §2.5 "Multi-destination simultaneous streaming:
/// restream without a cloud service".
///
/// **Encode once, distribute many.** The broadcaster never re-encodes. It takes
/// the single `ProgramEncoder`'s output (`CMSampleBuffer`s) exactly once and
/// forwards the *same* buffer to every destination's nonisolated
/// `append(encodedVideo:)`. `CMSampleBuffer` is reference-counted, so fan-out is
/// a pointer copy per destination, not a frame copy.
///
/// **Fault isolation.** Forwarding is a plain loop over `append(...)`, which is
/// `nonisolated`, non-throwing, and fire-and-forget (each output enqueues onto
/// its own bounded `AsyncStream`). A destination that is down, stalled, or
/// mid-reconnect drops on *its own* queue and updates *its own* `appendsDropped`
/// — it can neither block the loop nor stop the other destinations from
/// receiving the frame. Reconnect is entirely internal to each output.
///
/// Wiring:
/// ```
/// let bcast = MultiDestinationBroadcaster()
/// try await bcast.add(Destination(name: "YouTube", proto: .rtmp, url: …, key: …))
/// try await bcast.add(Destination(name: "Backup",  proto: .srt,  url: …))
/// await bcast.attach(to: programEncoder)   // encoder.onEncodedFrame → fan-out
/// ```
public actor MultiDestinationBroadcaster {
    private let log = EngineLog.logger("output.multi")

    /// Codec parameters handed to each concrete output. The video bitrate here
    /// is *not* an encode instruction (we forward pre-encoded frames); it only
    /// seeds the outputs' own settings for their audio path / raw fallback.
    private let videoSettings: SRTStreamOutput.StreamSettings

    /// One managed entry per destination.
    private struct Entry {
        let destination: Destination
        let output: any StreamDestination
    }

    // Actor-isolated source of truth for lifecycle & stats.
    private var entries: [UUID: Entry] = [:]

    // Nonisolated hot-path snapshot: the broadcaster forwards frames without
    // hopping onto the actor. Rebuilt on every add/remove/enable change.
    private let live = OSAllocatedUnfairLock<[any StreamDestination]>(initialState: [])

    private let frameCounter = OSAllocatedUnfairLock<(video: UInt64, audio: UInt64)>(initialState: (0, 0))

    public init(videoSettings: SRTStreamOutput.StreamSettings = SRTStreamOutput.StreamSettings()) {
        self.videoSettings = videoSettings
    }

    // MARK: Destination management

    /// Builds the concrete output for `destination`, and (if enabled) connects
    /// and starts publishing. Throws only if the *connect* fails.
    ///
    /// C5: connect happens **before** the destination enters the live fan-out
    /// snapshot, so a destination whose connect fails never lands in the hot
    /// path (where every frame would call its `append` → drop, and audio would
    /// pay a full PCM convert). On failure it is reverted to `enabled = false`
    /// but kept registered — stats-inspectable and retriable via
    /// `setEnabled(true, id:)`, consistent with C4 — and the error is rethrown.
    @discardableResult
    public func add(_ destination: Destination) async throws -> UUID {
        let output = makeOutput(for: destination)
        // Store the entry but do NOT rebuild the live snapshot yet.
        entries[destination.id] = Entry(destination: destination, output: output)
        if destination.enabled {
            do {
                try await connect(output, destination: destination)
            } catch {
                setDestinationEnabled(destination.id, to: false)
                rebuildLiveSnapshot() // ensure it is not in the hot path
                throw error
            }
        }
        rebuildLiveSnapshot() // now live, only after a successful connect
        return destination.id
    }

    /// Injects a pre-built destination (used for RTMP/SRT built elsewhere, and
    /// by in-process test doubles). Does not connect — caller owns that.
    func addDestination(_ output: any StreamDestination, as destination: Destination) {
        register(output, destination: destination)
    }

    private func makeOutput(for destination: Destination) -> any StreamDestination {
        switch destination.proto {
        case .rtmp:
            return RTMPStreamOutput(settings: .init(
                codec: videoSettings.codec == .hevc ? .hevc : .h264,
                width: videoSettings.width, height: videoSettings.height,
                videoBitrate: videoSettings.videoBitrate,
                keyframeInterval: videoSettings.keyframeInterval,
                expectedFrameRate: videoSettings.expectedFrameRate,
                lowLatencyRateControl: videoSettings.lowLatencyRateControl,
                audioBitrate: videoSettings.audioBitrate))
        case .srt:
            return SRTStreamOutput(settings: videoSettings)
        }
    }

    private func connect(_ output: any StreamDestination, destination: Destination) async throws {
        switch output {
        case let rtmp as RTMPStreamOutput:
            try await rtmp.connect(url: destination.url, streamKey: destination.key)
        case let srt as SRTStreamOutput:
            try await srt.connect(url: destination.url, streamID: destination.key)
        default:
            break // test doubles / already-live outputs
        }
        log.info("destination up: \(destination.name, privacy: .public)")
    }

    private func register(_ output: any StreamDestination, destination: Destination) {
        entries[destination.id] = Entry(destination: destination, output: output)
        rebuildLiveSnapshot()
    }

    /// Enable/disable an existing destination (connect / teardown).
    ///
    /// On a *connect* failure the destination is reverted to `enabled = false`
    /// (kept registered, kept out of the live fan-out) and the error is
    /// rethrown — so a later `setEnabled(true, id:)` is a real retry, not a
    /// short-circuited no-op (C4). The live snapshot is rebuilt on every exit
    /// path so a half-enabled entry never lingers in the hot path.
    public func setEnabled(_ enabled: Bool, id: UUID) async throws {
        guard let entry = entries[id] else { return }
        guard entry.destination.enabled != enabled else { return }
        setDestinationEnabled(id, to: enabled)

        if enabled {
            do {
                try await connect(entry.output, destination: currentDestination(id) ?? entry.destination)
            } catch {
                // Revert so recovery is possible; keep it registered for stats.
                setDestinationEnabled(id, to: false)
                rebuildLiveSnapshot()
                throw error
            }
        } else {
            await entry.output.teardown()
        }
        rebuildLiveSnapshot()
    }

    /// Mutates the stored `enabled` flag for `id` in place (Entry holds an
    /// immutable `Destination`, so we rebuild the value).
    private func setDestinationEnabled(_ id: UUID, to enabled: Bool) {
        guard let entry = entries[id] else { return }
        var updated = entry.destination
        updated.enabled = enabled
        entries[id] = Entry(destination: updated, output: entry.output)
    }

    private func currentDestination(_ id: UUID) -> Destination? {
        entries[id]?.destination
    }

    /// Removes a destination, tearing down its connection first.
    public func remove(id: UUID) async {
        guard let entry = entries.removeValue(forKey: id) else { return }
        rebuildLiveSnapshot()
        await entry.output.teardown()
    }

    /// The set of destinations that should receive frames right now.
    private func rebuildLiveSnapshot() {
        let outputs = entries.values
            .filter { $0.destination.enabled }
            .map { $0.output }
        live.withLock { $0 = outputs }
    }

    public var destinations: [Destination] {
        entries.values.map { $0.destination }.sorted { $0.name < $1.name }
    }

    /// Test/inspection hook: number of destinations currently in the hot-path
    /// fan-out snapshot (the set that actually receives frames). Distinct from
    /// `entries.count` — used by the self-test to prove a failed-connect
    /// destination never lingers in the live set (C5).
    func liveDestinationCount() -> Int {
        live.withLock { $0.count }
    }

    // MARK: Fan-out (hot path — nonisolated)

    /// Forward one already-encoded program video buffer to every enabled
    /// destination. Encode-once → distribute-many.
    public nonisolated func broadcast(encodedVideo sampleBuffer: CMSampleBuffer) {
        let outputs = live.withLock { $0 }
        for output in outputs {
            output.append(encodedVideo: sampleBuffer)
        }
        frameCounter.withLock { $0.video &+= 1 }
    }

    /// Forward one program-mix audio buffer to every enabled destination.
    ///
    /// TODO(C2 — streaming audio not yet wired): this method currently has **no
    /// caller.** `ProgramEncoder` is video-only, so no program audio surface
    /// exists to feed it, and the app never calls `broadcast(audio:)`. Until a
    /// program-audio path is built, live streaming is **video-only** — which is
    /// correct end-to-end: SRT outputs default to `StreamSettings.includeAudio
    /// = false` (declaring `[.video]` to the TSWriter, C1) and RTMP muxes video
    /// with no audio gate, so both stream video cleanly with no audio stall.
    ///
    /// To enable streaming audio, three pieces are needed (out of scope here):
    ///   1. a program-audio mix + encode surface on `ProgramEncoder` (an
    ///      `onEncodedAudio` / PCM callback analogous to `onEncodedFrame`);
    ///   2. app wiring that calls `broadcast(audio:)` from that surface;
    ///   3. constructing SRT destinations with `includeAudio: true`.
    ///
    /// P3 (deferred with C2): each destination's `append(audio:)` re-converts
    /// the *same* PCM `CMSampleBuffer` independently (SRT does a full
    /// CMSampleBuffer→AVAudioPCMBuffer copy). When the audio path is built,
    /// convert once here and share — but that requires widening the
    /// `StreamDestination` audio contract, so it is left until there is a caller.
    public nonisolated func broadcast(audio sampleBuffer: CMSampleBuffer) {
        let outputs = live.withLock { $0 }
        for output in outputs {
            output.append(audio: sampleBuffer)
        }
        frameCounter.withLock { $0.audio &+= 1 }
    }

    /// Wires a single `ProgramEncoder`'s output into the fan-out. The encoder
    /// encodes once; every emitted frame is distributed to all destinations.
    public func attach(to encoder: ProgramEncoder) {
        encoder.onEncodedFrame = { [weak self] sampleBuffer in
            self?.broadcast(encodedVideo: sampleBuffer)
        }
    }

    // MARK: Stats

    public struct FanOutStats: Sendable {
        public let videoFramesFanned: UInt64
        public let audioBuffersFanned: UInt64
        public let destinationCount: Int
        public let enabledCount: Int
    }

    public func fanOutStats() -> FanOutStats {
        let (v, a) = frameCounter.withLock { $0 }
        return FanOutStats(
            videoFramesFanned: v,
            audioBuffersFanned: a,
            destinationCount: entries.count,
            enabledCount: entries.values.filter { $0.destination.enabled }.count
        )
    }

    /// Per-destination transport-agnostic stats (independent counters).
    public func statsByDestination() async -> [UUID: StreamDestinationStats] {
        var out: [UUID: StreamDestinationStats] = [:]
        for (id, entry) in entries {
            out[id] = await entry.output.destinationStats()
        }
        return out
    }

    /// Tears down every destination and clears the set.
    public func shutdown() async {
        let all = entries.values.map { $0.output }
        entries.removeAll()
        rebuildLiveSnapshot()
        for output in all {
            await output.teardown()
        }
    }
}
