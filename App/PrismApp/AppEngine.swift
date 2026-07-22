import AppKit
import Combine
import CoreGraphics
import CoreMedia
import Foundation
import Metal
import Network
import os
import PrismAnimation
import PrismAudio
import PrismCapture
import PrismColor
import PrismCompose
import PrismCompositor
import PrismControl
import PrismControlSurface
import PrismCore
import PrismDirector
import PrismExport
import PrismLink
import PrismOutput
import PrismProximity
import PrismScreen
import PrismSound
import PrismSources
import PrismVision
import PrismVirtualCam
import UniformTypeIdentifiers
import VideoToolbox

/// The compositor's scene type (named to avoid colliding with SwiftUI.Scene in view files).
typealias ProgramScene = PrismCompositor.Scene

// MARK: - Active sources

/// A started source wired into the engine: its object, and (for video) the
/// mailbox feeding the render loop.
final class ActiveSource: Identifiable {
    enum Backing {
        case camera(CameraSource)
        case microphone(MicrophoneSource)
        case screen(ScreenSource)
        case link(NetworkVideoSource, LinkPeer)
        /// System-audio capture (macOS 14.2+); stored as the protocol so the
        /// 14.2-only concrete `SystemAudioSource` type never leaks its
        /// availability annotation into this enum.
        case systemAudio(AudioSource)
        /// A generated PrismSources source (text / image / browser). Stored as
        /// the protocol; the concrete type is recovered by cast for live config.
        case generated(VideoSource)
        /// A video-FILE source (MovieSource): a decoded, looping clip whose
        /// optional soundtrack is routed into its own mixer channel.
        case movie(MovieSource)
    }

    let id: SourceID
    let descriptor: SourceDescriptor
    let backing: Backing
    let mailbox: FrameMailbox?

    var isVideo: Bool { mailbox != nil }

    init(id: SourceID, descriptor: SourceDescriptor, backing: Backing, mailbox: FrameMailbox?) {
        self.id = id
        self.descriptor = descriptor
        self.backing = backing
        self.mailbox = mailbox
    }
}

/// Immutable snapshot of a `LinkPeer`'s mutable state (C24). `LinkPeer.state`
/// and `.hello` are mutated on the link server's queue with no lock, so the
/// main actor must never read them directly. Snapshots are taken ON the link
/// queue (inside onPeerConnected / onStateChange, which the server invokes
/// there) and published to the main actor; SwiftUI and the debug-state writer
/// read only the snapshot.
struct PeerSnapshot: Sendable {
    var stateDescription: String
    var isActive: Bool
    var name: String?
    var model: String?

    /// MUST be called on the link server's queue — the only context where
    /// reading `peer.state` / `peer.hello` is race-free.
    init(readingOnLinkQueue peer: LinkPeer) {
        let state = peer.state
        stateDescription = String(describing: state)
        if case .active = state { isActive = true } else { isActive = false }
        name = peer.hello?.name
        model = peer.hello?.model
    }
}

/// A connected Prism Camera (iOS) peer, addable as a source.
/// `peer` is an opaque handle (for wiring/sends); all display state comes
/// from `snapshot` — never read `peer.state`/`peer.hello` here (C24).
struct PeerEntry: Identifiable {
    let peer: LinkPeer
    var snapshot: PeerSnapshot
    var id: SourceID { peer.id } // `id` is immutable on LinkPeer — safe anywhere
    var name: String { snapshot.name ?? "iOS device" }
    var detail: String? { snapshot.model }
}

// MARK: - Layout presets

/// PiP layout presets (DESIGN §2.2). These double as the obs-websocket
/// "scenes": GetSceneList returns them, SetCurrentProgramScene applies one.
enum ScenePreset: String, CaseIterable, Identifiable {
    case fullscreen = "Fullscreen"
    case pipCorner = "PiP Corner"
    case sideBySide = "Side by Side"

    var id: String { rawValue }
}

/// Per-layer frame presets offered in the layer inspector.
enum LayerFramePreset: String, CaseIterable, Identifiable {
    case full = "Full"
    case corner = "Corner"
    case leftHalf = "Left"
    case rightHalf = "Right"

    var id: String { rawValue }

    /// Normalized (0…1, top-left origin) canvas rect.
    var rect: CGRect {
        switch self {
        case .full: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .corner: return CGRect(x: 0.66, y: 0.64, width: 0.30, height: 0.30)
        case .leftHalf: return CGRect(x: 0, y: 0.25, width: 0.5, height: 0.5)
        case .rightHalf: return CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5)
        }
    }
}

// MARK: - Link debug monitor (env-gated observability, normal builds: nil)

/// Debug-only program/source observability behind PRISM_LINK_STATE_FILE:
/// per-source last frame PTS, program-frame counters, and a cheap content
/// fingerprint of the latest program frame (sampled CPU read, at most once
/// per second, on a dedicated debug queue — never on the render thread).
/// Instantiated only when the env var is set; nil in normal use.
final class LinkDebugMonitor: @unchecked Sendable {
    private struct State {
        var lastFramePTS: [String: Double] = [:]          // source id → seconds
        var fingerprint: String?                          // FNV-1a of 64 sampled bytes
        var fingerprintPTS: Double = 0                    // program PTS it was taken at
        var fingerprintCount: UInt64 = 0                  // how many were computed
        var lastSampleUptime: TimeInterval = 0
        var sampleInFlight = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "studio.prism.link-debug", qos: .utility)

    /// Source capture queue: remember the newest PTS per source.
    func recordSourceFrame(_ frame: VideoFrame) {
        let seconds = frame.pts.seconds
        lock.withLock { $0.lastFramePTS[frame.source.raw] = seconds }
    }

    func forgetSource(_ id: SourceID) {
        lock.withLock { _ = $0.lastFramePTS.removeValue(forKey: id.raw) }
    }

    /// Render thread, every program frame: throttle to ≤1 sample/second and
    /// hop to the debug queue for the CPU read (retaining the frame keeps its
    /// IOSurface-backed buffer from being recycled by the pool).
    func observeProgram(_ frame: VideoFrame) {
        let now = ProcessInfo.processInfo.systemUptime
        let shouldSample = lock.withLock { state -> Bool in
            guard !state.sampleInFlight, now - state.lastSampleUptime >= 1 else { return false }
            state.lastSampleUptime = now
            state.sampleInFlight = true
            return true
        }
        guard shouldSample else { return }
        queue.async { [self] in
            let value = Self.fingerprint(of: frame.pixelBuffer)
            lock.withLock { state in
                state.fingerprint = value
                state.fingerprintPTS = frame.pts.seconds
                state.fingerprintCount += 1
                state.sampleInFlight = false
            }
        }
    }

    /// FNV-1a 64-bit over 64 bytes sampled evenly across the base plane.
    /// Debug-only CPU read — acceptable here, forbidden on the hot path.
    private static func fingerprint(of buffer: CVPixelBuffer) -> String? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(buffer)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
                                : CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let size = planar
            ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * CVPixelBufferGetHeightOfPlane(buffer, 0)
            : CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
        guard size > 0 else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride = max(1, (size / 64) | 1) // odd → samples cycle across channels
        var hash: UInt64 = 0xcbf29ce484222325
        var offset = 0
        for _ in 0..<64 where offset < size {
            hash = (hash ^ UInt64(bytes[offset])) &* 0x100000001b3
            offset += stride
        }
        return String(format: "%016llx", hash)
    }

    /// Snapshot for the JSON state file (main thread).
    func snapshot() -> (sources: [String: Double], fingerprint: String?,
                        fingerprintPTS: Double, fingerprintCount: UInt64) {
        lock.withLock { ($0.lastFramePTS, $0.fingerprint, $0.fingerprintPTS, $0.fingerprintCount) }
    }
}

// MARK: - Link frame normalizer (workaround for an engine bug — see below)

/// Converts incoming link frames the compositor can't render into plain
/// 4:2:0 bi-planar.
///
/// WORKAROUND for an engine bug (reported upstream, PrismLink is not
/// app-owned): `VideoFrameDecoder.rebuildSession` does not pin
/// `kCVPixelBufferPixelFormatTypeKey` in its `imageBufferAttributes`, so on
/// Apple silicon VideoToolbox picks lossless-compressed 4:2:0 ('&8v0',
/// OSType 641234480). `MetalCompositor.encodeLayer` supports only BGRA /
/// '420v' / '420f' and silently skips the layer ("Unsupported pixel format …
/// — layer skipped"), so peer video decoded fine but never rendered. Until
/// the decoder pins its output format, normalize here via
/// VTPixelTransferSession (hardware path, one conversion per received frame).
///
/// Thread model: single caller — the owning source's decoder-output thread.
final class LinkFrameNormalizer {
    private var session: VTPixelTransferSession?
    private var pool: PixelBufferPool?
    private var loggedFailure = false
    private let logger = EngineLog.logger("app.linkcompat")

    /// Formats MetalCompositor.encodeLayer accepts (keep in sync).
    /// sol #12 #2 (Link/peer Main10): the 10-bit formats MUST be here so a peer's Main10 decode
    /// PASSES THROUGH to the compositor at 10-bit instead of being downconverted to 8-bit `420v`
    /// below — the wave-5b[M] compositor decodes x420/xf20/l10r/64RGBAHalf NATIVELY (r16Unorm /
    /// bgr10a2Unorm / rgba16Float, precision-preserving). A stale 8-bit-only allowlist here
    /// irreversibly collapsed 10-bit peer video (distinct codes → one 8-bit bucket) before the
    /// compositor ever saw it. Genuine 8-bit peers (BGRA/420v/420f) are unchanged; a truly
    /// unsupported/compressed format (e.g. lossless '&8v0') still normalizes to `420v`.
    private static let compositorFormats: Set<OSType> = [
        kCVPixelFormatType_32BGRA,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,   // 'x420' — Main10 video range
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,    // 'xf20' — Main10 full range
        kCVPixelFormatType_ARGB2101010LEPacked,             // 'l10r' — 10-bit packed (SCK HDR)
        kCVPixelFormatType_64RGBAHalf,                      // FX/Vision/Color 10-bit float output
    ]

    /// Pass-through for compositor-supported formats; otherwise convert.
    /// On any conversion failure, returns the original frame (the layer is
    /// then skipped exactly as before — never worse than the status quo).
    func normalize(_ frame: VideoFrame) -> VideoFrame {
        guard !Self.compositorFormats.contains(frame.pixelFormat) else { return frame }
        if session == nil {
            var created: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created)
            session = created
        }
        if pool == nil || pool?.width != frame.width || pool?.height != frame.height {
            pool = try? PixelBufferPool(
                width: frame.width, height: frame.height,
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        }
        guard let session, let pool, let output = try? pool.makeBuffer(),
              VTPixelTransferSessionTransferImage(session, from: frame.pixelBuffer,
                                                  to: output) == noErr else {
            if !loggedFailure {
                loggedFailure = true
                logger.error("link frame normalize failed (format \(frame.pixelFormat)) — layers from \(frame.source, privacy: .public) will be skipped by the compositor")
            }
            return frame
        }
        return VideoFrame(pixelBuffer: output, pts: frame.pts,
                          duration: frame.duration, source: frame.source)
    }
}

// MARK: - ISO tap (capture-queue → ISO bank routing)

/// Records the NATIVE format (pixel dimensions + HDR-ness) of each source's raw
/// frames, so an ISO recording can be sized to the source's own resolution and
/// tagged HDR when the source is HDR — instead of the hardcoded 1080p/H.264/SDR
/// that upscaled a 640×480 source and flattened a 10-bit HLG source to 8-bit
/// H.264 (sol: "ISO is neither clean, native, nor HDR").
///
/// Fed on EVERY raw source frame via `ISOTap.append` (even while idle, before a
/// bank is installed), so at Record start the latest native format is already
/// known for every live source. `isHDR` is read from the source buffer's own
/// transfer tag (HLG/PQ) — the same one-source-of-truth `YCbCrTags` the color
/// pipeline uses — not from the program's HDR toggle.
final class SourceFormatProbe: @unchecked Sendable {
    struct Format: Sendable, Equatable {
        let width: Int
        let height: Int
        /// The source declares an HDR transfer (HLG or PQ) → record HEVC Main10 +
        /// Rec.2020/HLG, not 8-bit H.264 SDR.
        let isHDR: Bool
    }
    private let store = OSAllocatedUnfairLock<[SourceID: Format]>(initialState: [:])

    /// Sample one raw frame's native format (keyed by `frame.source`). O(1); no
    /// pixel access — dimensions + the color-tag transfer only.
    func record(_ frame: VideoFrame) {
        let transfer = YCbCrTags.transferCode(for: frame.pixelBuffer)
        let hdr = (transfer == 1 || transfer == 2) // 1 = HLG, 2 = PQ (YCbCrTags codes)
        let format = Format(width: frame.width, height: frame.height, isHDR: hdr)
        store.withLock { $0[frame.source] = format }
    }

    /// The latest recorded native format for a source (nil until it delivers a frame).
    func format(for id: SourceID) -> Format? { store.withLock { $0[id] } }

    /// Drop a removed source's entry.
    func forget(_ id: SourceID) { store.withLock { $0[id] = nil } }
}

/// Thread-safe holder that lets a source's capture-queue `onFrame` closure route
/// its frames into the active `ISORecorderBank` (deliverable 3). The bank is
/// installed on the main actor at Record start and cleared on Stop; source
/// closures — created once when the source is added — capture this holder, so
/// they need no rewiring when a recording session begins or ends. When no bank
/// is installed, `append` only updates the native-format probe (a cheap nil
/// bank-check no-op for the recording route).
///
/// **Contract (sol #1):** `append` must be handed the RAW per-source frame
/// (pre-grade/key/background/FX), never the processed program frame — ISO is the
/// clean per-source angle. The caller passes the unprocessed frame; here the raw
/// frame both updates `formats` and (once recording) routes to the bank.
final class ISOTap: @unchecked Sendable {
    private let bank = OSAllocatedUnfairLock<ISORecorderBank?>(initialState: nil)
    /// Always-updated native-format probe (independent of whether a bank is
    /// installed), so ISO can size/tag each per-source file natively at start.
    let formats = SourceFormatProbe()
    func install(_ newBank: ISORecorderBank?) { bank.withLock { $0 = newBank } }
    func append(_ frame: VideoFrame) {
        formats.record(frame)              // native-format probe (always, even pre-record)
        bank.withLock { $0 }?.append(frame) // clean raw per-source angle (only while recording)
    }
}

#if DEBUG
/// sol #1 test-only inert `VideoSource` backing for a synthetic ISO-armed source
/// (no capture, no TCC, emits nothing on its own). Only its `id` is read by the
/// ISO/record paths under test.
final class _TestStubVideoSource: VideoSource, @unchecked Sendable {
    let id: SourceID
    var state: SourceState = .idle
    var onFrame: ((VideoFrame) -> Void)?
    init(id: SourceID) { self.id = id }
    func start() throws {}
    func stop() {}
}
#endif

/// Thread-safe holder that lets each AUDIO source's capture-queue `onAudio`
/// closure route its packets into the active `AudioTrackRecorderBank` for
/// multitrack recording (deliverable 3). Installed on the main actor at Record
/// start (when audio sources are armed) and cleared on Stop; the per-source
/// `onAudio` closures — created once when the source is added — capture this
/// holder, so no rewiring is needed per session. The bank routes each packet to
/// its own track by `packet.source`; unarmed sources have no track so their
/// packets are dropped. No bank installed → `append` is a cheap nil-check no-op.
final class MultitrackAudioTap: @unchecked Sendable {
    private let bank = OSAllocatedUnfairLock<AudioTrackRecorderBank?>(initialState: nil)
    func install(_ newBank: AudioTrackRecorderBank?) { bank.withLock { $0 = newBank } }
    func append(_ packet: AudioPacket) { bank.withLock { $0 }?.append(packet) }
}

/// Thread-safe seam that routes each video source's capture-queue frames into
/// the active `DirectorController` (auto-director). Installed on the main actor
/// when Auto-Director is enabled and cleared when it is disabled; the per-source
/// `onFrame` closures — created once when the source is added — capture this
/// holder, so they need no rewiring when auto-switching begins or ends. When no
/// director is installed, `submit` is a cheap nil-check no-op. `submit` is
/// non-blocking and safe from any thread (`DirectorController.submit` enqueues).
final class DirectorTap: @unchecked Sendable {
    private let box = OSAllocatedUnfairLock<DirectorController?>(initialState: nil)
    func install(_ director: DirectorController?) { box.withLock { $0 = director } }
    func submit(_ frame: VideoFrame) {
        let director = box.withLock { $0 }
        director?.submit(frame)
    }
}

/// sol #8 #1: a thread-safe live gate for a pending screen-source replacement's frame
/// callback. `ScreenSource.start()` resolves capture asynchronously; its `onFrame`
/// fires on the capture queue. When the replacement is drained (its source removed,
/// the app shut down, or the replacement superseded/orphaned) the gate is `retire()`d
/// on the main actor and every subsequent (or already-in-flight) callback no-ops —
/// so no frame is ever posted after the replacement's lifecycle ended.
final class ScreenReplacementGate: @unchecked Sendable {
    private struct State {
        var live: Bool
        /// sol #11 #1: a DEFERRED replacement gate (`live: false`) is created BUFFERING. While
        /// its successor's async `startCapture()` resolves, its capture-queue VIDEO frames would
        /// otherwise be DROPPED (the serialize window) — leaving the screen stale/black until the
        /// next SCK frame, which an idle screen source may never emit. Instead the LATEST such
        /// delivery is buffered here (latest-wins) and replayed at `arm()`. Cleared on arm/retire.
        /// An ORIGINAL/active gate starts live → `buffering == false` → it never buffers.
        var buffering: Bool
        /// The latest deferred VIDEO delivery body (captures the frame DATA only — running it is
        /// deferred to `arm()`, so buffering does NOT touch the shared `SourceEffectGPU` /
        /// `MixerChannel`; the OLD generation stays the sole writer through the async-start window).
        var pendingDelivery: (() -> Void)?
    }
    private let state: OSAllocatedUnfairLock<State>

    /// A gate for the ORIGINAL/active source starts LIVE (its callbacks deliver
    /// immediately). A gate for a pending REPLACEMENT starts NOT-live and is `arm()`ed
    /// only at commit, AFTER the old source's gate has been retired+drained — so the two
    /// generations never ingest into the shared `SourceEffectGPU` / `MixerChannel`
    /// concurrently (sol #10 #2/#3, the SERIALIZE fix).
    init(live: Bool = true) {
        state = OSAllocatedUnfairLock<State>(initialState: State(live: live, buffering: !live, pendingDelivery: nil))
    }
    var isLive: Bool { state.withLock { $0.live } }
    /// Retire the gate: it delivers nothing more AND drops any buffered deferred frame (a
    /// superseded / failed / drained replacement must NOT replay stale content). Terminal.
    func retire() { state.withLock { $0.live = false; $0.buffering = false; $0.pendingDelivery = nil } }
    /// Make a deferred-arm replacement gate live. Called on the main actor at commit,
    /// strictly AFTER the retired predecessor gate has drained and the old stream stopped, so the
    /// new source begins ingesting into the shared pipeline/channel only once the old one has
    /// fully relinquished them. In the SAME lock hold it FLUSHES the buffered latest deferred
    /// frame (sol #11 #1) as the new generation's first delivery, so the swapped-in content
    /// presents immediately — no stale/black hold waiting for the next SCK frame. Running the
    /// flush under the gate lock serializes it against any live capture-queue callback, so the
    /// shared `SourceEffectGPU` / `MixerChannel` stay single-writer (max concurrency 1 — the
    /// SERIALIZE guarantee is preserved). Idempotent (a re-arm of an already-live gate re-flushes
    /// nothing).
    func arm() {
        state.withLock { st in
            st.live = true
            st.buffering = false
            let pending = st.pendingDelivery
            st.pendingDelivery = nil
            pending?()
        }
    }

    /// sol #9 #1: deliver a frame or audio packet ONLY while the replacement is live, with
    /// the liveness check AND `body` (the `mailbox.post` / audio-channel `ingest`) performed
    /// under a SINGLE hold of the SAME lock `retire()` takes. A concurrent teardown
    /// (`removeSource` / `shutdown` / commit-supersede → `retire()`) is therefore serialized
    /// either FULLY BEFORE this call (→ we observe `false`, `body` is skipped) or FULLY AFTER
    /// it (→ `body` already ran, then the gate dies). There is NO window — unlike the pre-fix
    /// separate `guard gate.isLive` (lock released) then later `post` (lock re-taken), where a
    /// teardown landing between the check and the post let a frame/packet reach a detached
    /// mailbox / audio channel after the replacement's lifecycle had ended.
    /// Deliver a frame/audio packet while the gate is live. `allowBuffer` (video only) makes a
    /// NOT-yet-live DEFERRED replacement gate BUFFER this delivery (latest-wins) instead of
    /// dropping it (sol #11 #1) — audio passes `false` (a brief audio gap at the swap is
    /// acceptable; a stale/black VIDEO hold is not). The buffered body is DATA only and is not
    /// run until `arm()`, so buffering never touches the shared pipeline/channel.
    func deliverIfLive(buffering allowBuffer: Bool = false, _ body: @escaping () -> Void) {
        #if DEBUG
        if Self._test_useSeparateBooleanGate {
            // NEGATIVE CONTROL — the pre-fix separate boolean gate: read liveness and RELEASE
            // the lock, let a teardown land in the window, then post regardless of the retire.
            let wasLive = isLive               // check (lock released here)
            Self._test_gateWindowHook?()       // teardown retires the gate HERE (the TOCTOU gap)
            if wasLive { body() }              // posts even though the gate is now retired → LEAK
            return
        }
        Self._test_gateWindowHook?()           // atomic path: a teardown lands BEFORE the check+post lock
        #endif
        state.withLock { st in
            if st.live {
                body()
            } else if allowBuffer && st.buffering {
                st.pendingDelivery = body      // latest-wins; DATA only — replayed at arm()
            }
        }
    }

    #if DEBUG
    /// NEGATIVE CONTROL (sol #9 #1): reproduce the pre-fix separate `guard gate.isLive`
    /// then later `post` (the check and the post do NOT share one lock hold), so a teardown
    /// landing between them leaks a frame/packet onto a detached mailbox / audio channel.
    static var _test_useSeparateBooleanGate = false
    /// Test hook (sol #9 #1): fired inside `deliverIfLive` in the exact check→post window so a
    /// test can `retire()` the gate there and assert the atomic path delivers NOTHING while
    /// the separate-boolean negative control leaks. Runs BEFORE the atomic lock is taken (so a
    /// `retire()` it triggers does not self-deadlock the non-recursive gate lock).
    static var _test_gateWindowHook: (() -> Void)?
    #endif
}

#if DEBUG
/// sol #10 #2/#3 — DEBUG concurrency probe for the screen hot-swap SERIALIZE proof. ONE
/// per screen `SourceID`, shared by BOTH the original and the replacement source
/// generations' delivery closures (which capture the same `effectPipelines[id]`
/// `SourceEffectGPU` and the same `MixerChannel`). It records the MAX number of delivery
/// bodies simultaneously inside the shared video pipeline (`enter/exitVideo`) and the
/// shared audio-channel ingest (`enter/exitAudio`): a SERIALIZED reconfigure must never
/// exceed 1, while the pre-fix overlap (both gates armed at once) reaches 2. It also counts
/// total deliveries so the ORIGINAL-callback leak (a post-teardown post) is directly
/// observable (a retired gate delivers NOTHING → the count does not advance).
final class ScreenSwapConcurrencyProbe: @unchecked Sendable {
    private struct S {
        var video = 0, audio = 0
        var maxVideo = 0, maxAudio = 0
        var videoDeliveries = 0, audioDeliveries = 0
    }
    private let s = OSAllocatedUnfairLock<S>(initialState: S())
    func enterVideo() { s.withLock { $0.video += 1; $0.maxVideo = max($0.maxVideo, $0.video); $0.videoDeliveries += 1 } }
    func exitVideo()  { s.withLock { $0.video -= 1 } }
    func enterAudio() { s.withLock { $0.audio += 1; $0.maxAudio = max($0.maxAudio, $0.audio); $0.audioDeliveries += 1 } }
    func exitAudio()  { s.withLock { $0.audio -= 1 } }
    var maxVideoConcurrency: Int { s.withLock { $0.maxVideo } }
    var maxAudioConcurrency: Int { s.withLock { $0.maxAudio } }
    var videoDeliveries: Int { s.withLock { $0.videoDeliveries } }
    var audioDeliveries: Int { s.withLock { $0.audioDeliveries } }
}
#endif

/// Render-thread driver for TIME-VARYING per-source effects (F5). Installed as
/// the `RenderLoop.frameProcessor`, so it runs on the render thread once per tick
/// with the tick's house-time PTS. For every registered source that has a live
/// animated effect (tile flicker / strobe / beat pulse) it re-evaluates the
/// source's HELD RAW frame at that one tick PTS and injects the animated result
/// into the frame dict the compositor renders — so a still/low-fps source still
/// animates at render cadence and every source shares one coherent phase clock,
/// instead of the effect being baked at source-callback arrival.
///
/// Threading: `pipelines` is mutated on the main actor (register/unregister) and
/// read on the render thread → guarded by `lock`. `lastRaw` (the per-source held
/// raw frame) is touched ONLY inside `process` on the render thread, so it needs
/// no lock. Each `SourceEffectPipeline.animate` is render-thread-only (its own
/// GPU instance), so the whole per-tick pass is race-free.
final class AnimatedFXDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var pipelines: [SourceID: SourceEffectPipeline] = [:]
    /// Ids (re)registered since the last `process` — their held raw must be
    /// dropped so a re-registered source can never animate a STALE frame from a
    /// previous registration before a fresh frame lands. Read+cleared under `lock`
    /// at the top of `process`. (Bug: A unregistered then re-registered between two
    /// ticks kept its old-generation `lastRaw`, animating a stale frame.)
    private var invalidated: Set<SourceID> = []
    /// Render-thread-only: the last held raw (pre-animated) frame per animated
    /// source, so a tick on which the source did not emit still re-animates.
    private var lastRaw: [SourceID: VideoFrame] = [:]

    func register(_ id: SourceID, _ pipeline: SourceEffectPipeline) {
        lock.lock(); pipelines[id] = pipeline; invalidated.insert(id); lock.unlock()
    }

    func unregister(_ id: SourceID) {
        lock.lock(); pipelines[id] = nil; lock.unlock()
        // `lastRaw[id]` is dropped by the KEYSET prune in `process` (an id no
        // longer in `pipelines` is removed) — not by a count comparison, which
        // failed to fire when an inactive pipeline masked the count (leaking the
        // unregistered source's held IOSurface forever).
    }

    /// Render thread, once per tick. Returns the frames to composite: each
    /// animated source's held raw frame re-evaluated at `pts`, everything else
    /// unchanged. Injects an entry even for a source that did not emit this tick.
    func process(_ frames: [SourceID: VideoFrame], pts: CMTime) -> [SourceID: VideoFrame] {
        lock.lock()
        let ps = pipelines
        let justRegistered = invalidated
        invalidated.removeAll(keepingCapacity: true)
        lock.unlock()
        // Drop stale held raw for any source (re)registered since the last tick, so
        // a re-registered source animates only a FRESH frame — never a leftover
        // frame from its previous registration.
        for id in justRegistered { lastRaw[id] = nil }
        guard !ps.isEmpty else {
            if !lastRaw.isEmpty { lastRaw.removeAll() }
            return frames
        }
        var out = frames
        for (id, pipeline) in ps {
            guard pipeline.hasAnimatedEffect else {
                lastRaw[id] = nil
                pipeline.releaseAnimatedGPUIfIdle()   // F15: drop the warm GPU floor when idle
                continue
            }
            if let fresh = frames[id] { lastRaw[id] = fresh }   // newest held raw
            guard let raw = lastRaw[id] else { continue }        // nothing seen yet
            if let animated = pipeline.animate(raw: raw, at: pts) { out[id] = animated }
        }
        // Prune held-raw frames by KEYSET: drop any whose pipeline is no longer
        // registered. (A count comparison missed the leak when an inactive pipeline
        // kept `pipelines.count == lastRaw.count` after an animated source left.)
        if lastRaw.contains(where: { ps[$0.key] == nil }) {
            lastRaw = lastRaw.filter { ps[$0.key] != nil }
        }
        return out
    }

    #if DEBUG
    /// Render-thread-only test seam: whether a held raw frame is currently retained
    /// for `id` (proves the keyset prune released an unregistered source's frame,
    /// and that a re-registered source has no stale frame until a fresh one lands).
    func debugHasHeldRaw(_ id: SourceID) -> Bool { lastRaw[id] != nil }
    #endif
}

/// Everything the FCPXML multicam export needs from a just-finished multi-angle
/// session (deliverable 4). Retained on `AppEngine` so a later "Export Final Cut
/// Project…" references real on-disk clips, durations, and the shared timeline
/// zero rather than recomputing them.
struct FinishedMulticamSession {
    struct AngleMeta { let name: String; let width: Int; let height: Int; let fps: Double; let hasAudio: Bool }
    let projectName: String
    /// Folder the recordings live in (the `.fcpxml` is written here).
    let directory: URL
    /// Shared timeline zero (house time) — the ISO bank's fixed start.
    let sessionStart: CMTime
    let programSource: SourceID
    let program: MovieRecorder.Report
    let isoResults: [SourceID: Result<MovieRecorder.Report, Error>]
    let meta: [SourceID: AngleMeta]
}

// MARK: - AppEngine

/// The app-side engine shell: owns the compositor + render loop, the active
/// source graph, and the three program consumers (preview / recorder /
/// virtual camera). All @Published state mutates on the main actor; engine
/// callbacks hop here explicitly.
@MainActor
final class AppEngine: ObservableObject {

    /// Weak, main-actor reference to the live engine so App Intents (which run
    /// in this process) can reach it without an environment injection. Set in
    /// `init`; the app creates exactly one AppEngine.
    static weak var current: AppEngine?

    // Core (nil only if Metal init failed — UI degrades to an error banner).
    private(set) var renderLoop: RenderLoop?
    private let fanOut = ProgramFanOut()
    var previewStore: ProgramPreviewStore { fanOut.preview }

    static let canvasSize = (width: 1920, height: 1080)

    // MARK: Dual program (vertical 9:16, deliverable — PrismCompose)

    /// Second full composite of the SAME per-tick source frames at 1080×1920
    /// (nil only if Metal init failed). Fed from the primary program-frame
    /// callback via `verticalTap`; its own compositor/queue run concurrently
    /// with the primary (perf note in DualProgramSupport.swift).
    ///
    /// `var` (not `let`) so `setHDREnabled` can REBUILD it in the matching
    /// `ColorMode` — the vertical program + its recording must reach HDR parity
    /// with the primary (Stage O sink-parity). The render loop's tick-snapshot
    /// closure captures whichever instance is current at `buildRenderLoop` time.
    private var dualProgram: DualProgram?
    /// The dynamic range the vertical (9:16) program currently composites in
    /// (nil if there is no vertical program). Test-visible so Stage O can assert
    /// the vertical program reaches HDR parity after `setHDREnabled`.
    var verticalProgramColorMode: MetalCompositor.ColorMode? { dualProgram?.colorMode }
    /// Vertical program canvas.
    static let verticalCanvasSize = (width: 1080, height: 1920)
    /// Latest processed frame per source, snapshotted at each program tick to
    /// feed `dualProgram.submit`. Enabled only while the vertical program runs.
    private let verticalTap = LatestFrameTap()
    /// Vertical program-frame consumers: 9:16 preview + optional recorder.
    private let verticalSink = VerticalProgramSink()
    /// The 9:16 preview store the vertical monitor pulls from.
    var verticalPreviewStore: ProgramPreviewStore { verticalSink.preview }
    /// Optional vertical `MovieRecorder` (records the 9:16 alongside the 16:9).
    private var verticalRecorder: MovieRecorder?
    /// Base URL of the in-progress primary recording (drives the "-vertical"
    /// companion file name when the vertical recorder starts).
    private var currentRecordingBaseURL: URL?

    // Discovery & transport
    private let deviceManager = CaptureDeviceManager()
    private let linkServer: LinkServer

    // ISO recording tap: source capture-queue frames → active ISO bank
    // (deliverable 3). Captured by every video source's onFrame closure.
    private let isoTap = ISOTap()
    private let multitrackTap = MultitrackAudioTap()

    /// Render-thread driver for time-varying per-source effects (F5). Installed
    /// as the RenderLoop's `frameProcessor`; every effect pipeline registers with
    /// it so its tile/strobe/pulse advance on the render tick against the held raw
    /// frame at the tick PTS. Survives render-loop replacement (HDR toggle) — only
    /// the closure that forwards to it is reinstalled on the new loop.
    private let animatedFXDriver = AnimatedFXDriver()

    // Debug observability (nil unless PRISM_LINK_STATE_FILE is set).
    private let linkDebugMonitor: LinkDebugMonitor?
    /// Debug-only: PRISM_AUTOADD_PEERS=1 auto-adds a connecting peer's video
    /// as a scene layer (what the sidebar "+" does), so a headless loopback
    /// test can prove peer pixels reach the program output.
    private let autoAddPeers =
        ProcessInfo.processInfo.environment["PRISM_AUTOADD_PEERS"] == "1"

    /// UserDefaults key for the persisted pairing code (survives relaunches
    /// so already-paired devices keep working).
    private static let pairingCodeDefaultsKey = "studio.prism.link.pairingCode"

    /// Loads the persisted pairing code, generating + persisting one on
    /// first launch (or if the stored value is malformed).
    private static func loadOrCreatePairingCode() -> String {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: pairingCodeDefaultsKey),
           LinkPairing.normalize(stored).count == LinkPairing.codeLength {
            return LinkPairing.normalize(stored)
        }
        let code = LinkPairing.generateCode()
        defaults.set(code, forKey: pairingCodeDefaultsKey)
        return code
    }

    // Outputs
    private var recorder: MovieRecorder?
    /// Monotonic token identifying the current recording (C26). Bumped by
    /// every successful start; an in-flight stopRecording() only publishes
    /// its "stopped" control event if its generation is still current after
    /// the `await finish()` (a start during the await supersedes it).
    private var recordGeneration: UInt64 = 0
    /// Monotonic per-take counter (sol HIGH #1). Combined with a millisecond
    /// timestamp it guarantees every take's program/ISO/multitrack paths are
    /// unique even for two Records within the same second — so a later take can
    /// never overwrite an earlier take's files.
    private var recordTakeCounter: UInt64 = 0
    /// Monotonic per-save counter for replay/highlight clips (sol #17 data-loss).
    /// The replay/clip filenames used a *second*-resolution timestamp with no
    /// disambiguation, so two clips saved in the same second collided on one path
    /// and the second destroyed the first. Millisecond timestamp + this counter
    /// makes every requested clip path unique (belt-and-suspenders with the
    /// engine's `RecorderFilePath.nonClobbering` last-line guard in `ReplayBuffer`).
    private var clipSaveCounter: UInt64 = 0
    private let feeder = VirtualCameraFeeder()
    private let installer = SystemExtensionInstaller()
    private let controlServer = ControlServer()
    private let controlBackend = EngineControlBackend()

    // MARK: Published state

    @Published private(set) var engineFault: String?

    @Published private(set) var cameras: [SourceDescriptor] = []
    @Published private(set) var microphones: [SourceDescriptor] = []
    @Published private(set) var peers: [PeerEntry] = []
    @Published private(set) var activeSources: [ActiveSource] = [] {
        didSet { persistActiveSources() } // source persistence: save the show whenever the set changes
    }

    /// Add-time file identity (bookmark + loop) for image/movie sources, keyed by
    /// their runtime id. Feeds `persistActiveSources` (the descriptor.id of a media
    /// source is a throwaway `SourceID`, so the file has to be captured on add and
    /// dropped on remove). Source-persistence support state.
    var persistableSourceFiles: [SourceID: PersistableSourceFile] = [:]
    /// Entries whose device/file was absent at restore: skipped for creation but
    /// RETAINED so a later save keeps them (they reappear when the device returns).
    var retainedAbsentSources: [PersistedSource] = []
    /// While a restore is replaying sources, suppress the per-mutation save so the
    /// file is written ONCE at the end (live sources + retained-absent).
    var isSourcePersistenceSuspended = false

    /// The most recently added video source that got its own layer. The view
    /// layer observes this to auto-select the new layer in the Inspector, so a
    /// freshly-added source immediately shows its adjustable effects instead of
    /// the "nothing selected" empty state (discoverability). View-only sugar —
    /// the engine itself has no notion of a "selected" source.
    @Published private(set) var lastAddedVideoSourceID: SourceID?

    // Device link (iPhone pairing)
    /// The pairing code devices type/scan (normalized, no hyphen).
    let pairingCode: String
    /// "ABCD-2345" — what the sidebar shows.
    var pairingCodeDisplay: String { LinkPairing.display(pairingCode) }
    /// UDP port the QUIC listener bound (nil while starting / after failure).
    @Published private(set) var linkPort: UInt16?
    /// Human-readable last listener state ("ready" / "waiting: …" / "failed: …")
    /// for the sidebar + the debug state file. Starts "off": peer-connect is
    /// OPT-IN, so no listener runs until the user enables it (see `linkEnabled`).
    @Published private(set) var linkListenerState = "off"
    /// Peer-connect (PrismLink) opt-in gate. **Default FALSE.** While false the
    /// Link server never starts, so there is NO TLS-identity creation (no
    /// keychain access), NO Bonjour advertisement, and no listener. The user
    /// turns this on explicitly via `setLinkEnabled(_:)`; nothing auto-enables it.
    @Published private(set) var linkEnabled = false
    /// Whether the listener advertises over Bonjour — only when the user has
    /// opted into peer-connect (never advertise while `linkEnabled` is false).
    var linkAdvertising: Bool { linkEnabled }
    var linkStatusText: String {
        guard let port = linkPort else { return "Link listener \(linkListenerState)" }
        let peersPart = peers.isEmpty ? "no devices" :
            "\(peers.count) device\(peers.count == 1 ? "" : "s")"
        return "UDP \(port) · \(linkAdvertising ? "advertising" : "hidden") · \(peersPart)"
    }

    @Published private(set) var scene = ProgramScene(name: "Program") {
        // Instant apply for layer edits. Preset switches route through
        // `commitSceneAnimated`, which sets `scene` under this flag so the
        // render loop gets the animated `switchScene` instead of a hard cut.
        didSet {
            // Keep the vertical program's scene in sync with the primary's so
            // hero resolution (top-zIndex) and reframe track live edits + cuts.
            dualProgram?.scene = scene
            // Keep the meme director's resting base current so an active `insert`
            // overlay sits atop the live layout (edits / preset switches). Copy to
            // a local first — the lock's closure is @Sendable and can't read the
            // main-actor `scene` property directly.
            let current = scene
            memeBaseScene.withLock { $0 = current }
            guard !suppressSceneRenderApply else { return }
            invalidatePendingStingerCue()
            cancelActiveStingerTransition(applyTargetScene: false)
            // A live scene edit must reclaim control immediately: if a layer
            // entrance is animating, its sceneProvider would otherwise mask this
            // edit until the clear timer fires (up to the animation duration —
            // Codex F2). Cancel it so the edit shows now.
            cancelLayerAnimation()
            renderLoop?.scene = scene
        }
    }
    @Published private(set) var selectedPreset: ScenePreset = .fullscreen

    /// Set while `commitSceneAnimated` mutates `scene`, so the didSet above does
    /// not also hard-cut the render loop (the animated transition already did).
    private var suppressSceneRenderApply = false

    // MARK: v2 — Scene collections (save/load named layouts, deliverable 1)

    /// Persisted named layouts (each a scene snapshot + its preset), loaded from
    /// Application Support at launch. Save/load/delete round-trip through disk.
    @Published private(set) var sceneCollections: [SceneCollection] = []
    /// Debug: result of a save→disk→reload round-trip (PRISM_DEBUG_SAVE_COLLECTION).
    @Published private(set) var lastCollectionRoundTripOK: Bool?

    // MARK: v2 — Keyframed layer motion (deliverable 3)

    /// The layer currently playing an entrance animation (nil when idle). Drives
    /// the render loop's per-tick `sceneProvider` hook; cleared when it finishes.
    @Published private(set) var animatingSourceID: SourceID?
    private var animationClearTimer: Timer?

    // MARK: Wave-2 state (effects / audio mixer / streaming / transitions)

    /// The Metal device the compositor uses; shared with per-source effect
    /// processors so their textures interoperate. Nil only if Metal init failed.
    private var metalDevice: MTLDevice?

    // Per-source effect chain (deliverable 1).
    /// Capture-thread pipelines, one per VIDEO source. Created in
    /// `makeEffectPipeline`, torn down in `removeSource`.
    private var effectPipelines: [SourceID: SourceEffectPipeline] = [:]
    /// sol #7 #2: STRONG owners of screen-source replacements whose async `start()` has
    /// not yet confirmed. `ScreenSource.start()` kicks off a `Task { [weak self] … }`,
    /// so a pending replacement with no external strong owner can DEALLOC before
    /// `startCapture` acquires it — the reconfiguration then silently never starts.
    /// Keyed by the replacement's `ObjectIdentifier` so every pending source is retained
    /// until IT commits/fails (a superseded one is not overwritten out of existence). The
    /// record carries the mode it was built for (so a stale/superseded one is rejected at
    /// commit) and whether it is a post-commit-failure RESTORE (exempt from the mode gate).
    /// sol #8 #1: a pending replacement is OWNED LIFECYCLE STATE, torn down on every exit
    /// path. It carries the SourceID it replaces (so `removeSource` can drain the pending
    /// replacement for that source) and its render `mailbox`, plus a `gate` its frame
    /// callback checks — retired the instant the replacement is drained/superseded so no
    /// post-removal / post-shutdown frame is ever posted, even if a frame is already
    /// in flight on the capture queue when the source is stopped.
    private struct PendingScreenReplacement {
        let id: SourceID                     // the source this replacement swaps in for
        let source: ScreenSource
        let mailbox: FrameMailbox            // the render mailbox the replacement posts to
        let mode: Bool                       // the `preferHDR` mode this replacement targets
        let isRestore: Bool                  // a post-commit-failure restore (→ prior mode, exempt)
        let queuedEpoch: Int                 // sol #8 #2: `hdrModeEpoch` when this was queued
        let generation: Int                  // sol #12 #1: monotonic per-source token (latest-wins)
        let gate: ScreenReplacementGate      // frame-callback live gate (retired on teardown)
    }
    private var pendingScreenReplacements: [ObjectIdentifier: PendingScreenReplacement] = [:]
    /// sol #12 #1: monotonic per-source replacement generation. Bumped every time a NEW pending
    /// replacement is registered for a source; the pending record carries the token it was born
    /// with, and `commitScreenReplacement` proceeds only if that token is still the CURRENT-LATEST
    /// for the source. This distinguishes two SAME-MODE pending replacements (an ABA HDR on→off→on
    /// leaves H1 and H2 both targeting the final HDR mode) that the mode-only `hdrModeEpoch` stale
    /// check cannot — so a SUPERSEDED older pending (H1) can never commit over the newer live
    /// successor (H2). Registration also retires+drops the older pending outright (primary fix), so
    /// this check is defense-in-depth: with supersession active a superseded pending's record is
    /// already gone (`removed == nil` no-ops it), and the check only fires if a superseded record
    /// somehow survives.
    /// sol #9 #1: the live gate of a COMMITTED screen replacement, keyed by the SourceID it
    /// backs. On commit a replacement leaves `pendingScreenReplacements`, so pre-fix it lost
    /// all gate ownership — a later `removeSource`/`shutdown` could not retire it and an
    /// in-flight capture callback could post after the source was stopped. Holding the gate
    /// here lets teardown retire it (and a same-id supersede retire the predecessor's).
    private var committedScreenGates: [SourceID: ScreenReplacementGate] = [:]
    /// sol #8 #2: monotonic counter bumped on every committed HDR-mode change. A pending
    /// screen restore records the epoch at queue time; if it differs at commit the mode was
    /// TOGGLED while the restore was in flight (→ the restore's target mode may be stale).
    private var hdrModeEpoch = 0
    /// sol #12 #1: the latest replacement generation issued per source (see `generation` above).
    private var screenReplacementGeneration: [SourceID: Int] = [:]
    /// sol #12 #2 (RESTORE ABA): the `generation` of the replacement CURRENTLY LIVE (committed) for
    /// each source — updated at every successful `commitScreenReplacement`. A late-resolving pending
    /// (RESTORE or non-restore) whose birth `generation` is OLDER than this has been superseded by a
    /// newer replacement that already WON → it must NO-OP (never retire the live successor nor replay
    /// its stale buffered frame). This is the restore-safe distinguisher the non-restore-only
    /// generation check + the mode-only `hdrModeEpoch` gate both missed: it keys on "did a newer
    /// replacement already go live", not on restore-vs-not, so a LONE restore (nothing newer committed
    /// after it) still commits/recovers via the sol #8 #2 post-commit-failure epoch path.
    private var committedScreenGeneration: [SourceID: Int] = [:]
    /// Main-actor mirror of each source's effect state, for the view + debug.
    @Published private(set) var sourceEffects: [SourceID: SourceEffects] = [:]

    // Audio mixer path (deliverable 2).
    private let audioMixer = AudioMixer()
    private var audioMixerStarted = false
    /// BS.1770 / EBU-R128 loudness meter fed from the mixer's master tap.
    /// Attached to the mixer before `start()`; polled by the meter timer.
    private let loudnessMeter = LoudnessMeter()
    /// The active system-audio source, if one was added (kept for `===` identity).
    private var systemAudioSource: AudioSource?
    /// Master-mix peak level (linear amplitude), polled ~10 Hz.
    @Published private(set) var mixerMasterLevel: Float = 0
    /// Broadcast loudness of the master mix (LUFS + true-peak dBTP), polled with
    /// the meter timer. Fields are `-.infinity` before any qualifying audio.
    @Published private(set) var masterLoudness = LoudnessReadout()

    /// Main-actor mirror of `LoudnessMeter.Measurement` (Equatable so SwiftUI
    /// diffs it, and Sendable-free — plain Doubles).
    struct LoudnessReadout: Equatable {
        var momentary = -Double.infinity   // LUFS, 400 ms
        var shortTerm = -Double.infinity   // LUFS, 3 s
        var integrated = -Double.infinity  // LUFS, gated
        var truePeak = -Double.infinity    // dBTP, session max
    }
    /// Authoritative per-channel state (real peak + fader/mute/solo), polled ~10 Hz,
    /// so the mixer UI shows live data instead of view-local stand-ins.
    @Published private(set) var channelStates: [SourceID: ChannelState] = [:]
    private var meterTimer: Timer?

    /// Shared render-perf aggregator (Phase 1d). Created once and reused across
    /// HDR rebuilds so the metric window and counters are continuous. Read by
    /// `EngineControlBackend.stats()` via `renderLoop.metrics`.
    let renderMetrics = RenderMetrics()
    /// Light 1 Hz sampler for phys_footprint + Metal-allocated size + process CPU%.
    /// Deliberately NOT per-frame — memory/CPU reads are syscalls; a periodic
    /// timer keeps them off the render thread (non-perturbing).
    private var perfSampleTimer: Timer?

    /// (Re)start the memory/CPU sampler. Idempotent; called when a render loop
    /// is built. Runs on the main runloop at 1 Hz.
    private func startPerfSampler() {
        guard perfSampleTimer == nil else { return }
        perfSampleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let metalBytes = UInt64(self.metalDevice?.currentAllocatedSize ?? 0)
            self.renderMetrics.recordMemory(physFootprintBytes: ProcessMetrics.physFootprintBytes(),
                                            metalAllocatedBytes: metalBytes)
            self.renderMetrics.recordCPUPercent(ProcessMetrics.cpuUsagePercent())
        }
    }

    struct ChannelState: Equatable {
        var peakLinear: Float
        var gain: Float
        var isMuted: Bool
        var isSolo: Bool
        /// Live count of loaded AUv3 inserts (deliverable 2), polled with the meter.
        var insertCount: Int = 0
        /// Whether per-source voice isolation is engaged (deliverable 2).
        var voiceIsolationEnabled: Bool = false
    }

    /// Installed AU effects, queried once at launch (the AVAudioUnitComponentManager
    /// scan is not free). Data source for the mixer's insert picker; its count is
    /// mirrored to the debug state file.
    let audioEffectCatalog: [MixerChannel.AudioEffectComponent] = MixerChannel.availableEffectComponents()

    /// Per-channel loaded inserts, in signal order (deliverable 2). The app is the
    /// source of truth for WHICH effects are loaded — `MixerChannel` exposes only
    /// `insertCount` — so the editor reads its chain from here.
    @Published private(set) var channelInserts: [SourceID: [MixerChannel.AudioEffectComponent]] = [:]

    /// Per-channel in-flight insert-edit Task (Codex #2). Tracked so `removeSource`
    /// (and a superseding edit) can CANCEL it — a slow out-of-process AUv3 that
    /// finishes instantiating after the source was removed must not reconnect a
    /// detached channel.
    private var channelInsertTasks: [SourceID: Task<Void, Never>] = [:]
    /// Per-channel monotonic edit token (Codex #2/#6). Only the LATEST-issued edit
    /// is allowed to re-wire the live graph AND update the `channelInserts` mirror;
    /// every earlier (superseded) task bails on a token mismatch, so overlapping
    /// edits can't desync the graph from the UI mirror.
    private var channelInsertGeneration: [SourceID: UInt64] = [:]

    // RTMP streaming (deliverable 3).
    private var streamEncoder: ProgramEncoder?
    private var rtmpOutput: RTMPStreamOutput?
    private var streamStateTask: Task<Void, Never>?
    /// The in-flight `connect()` Task (W2). Stored so a stop during connect can
    /// cancel + await it, then `close()` whatever it managed to publish — so a
    /// stop mid-connect never orphans a live publishing connection.
    private var streamConnectTask: Task<Void, Never>?
    /// Monotonic token for the current stream attempt (W2). Bumped on stop/
    /// teardown; the connect Task treats itself as superseded if the token moved
    /// while it was awaiting, and tears its own connection back down.
    private var streamGeneration: UInt64 = 0
    /// True once the stream reached `.publishing` at least once. A later return
    /// to `.publishing` (after a `.reconnecting`) is a fresh publish → force a
    /// keyframe so the new stream is immediately decodable (W5).
    private var streamHasPublished = false
    private var streamStatsTimer: Timer?
    private var configuredStreamURL: String?
    private var configuredStreamKey: String?
    @Published private(set) var isStreaming = false
    @Published private(set) var streamStateDescription = "idle"
    /// When the current stream attempt started (nil while idle). Backs the
    /// obs-websocket GetStreamStatus `outputDuration`/`outputTimecode`.
    @Published private(set) var streamStartDate: Date?
    /// Outgoing bitrate in bits/second (derived from RTMP bytesOutPerSecond).
    @Published private(set) var streamBitrate = 0
    @Published private(set) var streamDroppedAppends: UInt64 = 0
    @Published private(set) var streamBytesOut = 0
    @Published private(set) var streamTotalFrames: UInt64 = 0

    // MARK: - Multi-destination restream + SRT (deliverable B)

    /// Persisted restream targets (RTMP/SRT), edited in the destinations editor
    /// and saved to Application Support. "Go Live" starts every enabled one.
    @Published private(set) var destinations: [Destination] = []
    /// The live fan-out broadcaster (nil unless a broadcast with ≥1 enabled
    /// destination is running). Fed by the SAME `streamEncoder` as the single
    /// RTMP path (video) + the master-mix audio tap (audio, via `ProgramFanOut`).
    private var broadcaster: MultiDestinationBroadcaster?
    /// In-flight per-destination connect Tasks (Codex #4), keyed by a monotonic
    /// token. Each `broadcaster.add(dest)` is tracked here so teardown can CANCEL
    /// and AWAIT every one before `broadcaster.shutdown()` — otherwise actor
    /// reentrancy lets a connect finish (assigning connection/stream) AFTER
    /// shutdown, leaving a destination publishing past stop.
    private var destinationConnectTasks: [UInt64: Task<Void, Never>] = [:]
    private var destinationConnectSeq: UInt64 = 0
    /// Per-destination live stats while broadcasting (keyed by Destination.id),
    /// polled from `broadcaster.statsByDestination()`.
    @Published private(set) var destinationStats: [UUID: StreamDestinationStats] = [:]
    /// Fan-out counters mirrored for the UI + debug state file: how many
    /// destinations went live, and how many program video/audio buffers the
    /// broadcaster has distributed (proves audio AND video reach destinations).
    @Published private(set) var broadcastDestinationsConfigured = 0
    @Published private(set) var broadcastVideoFrames: UInt64 = 0
    @Published private(set) var broadcastAudioFrames: UInt64 = 0
    private var broadcastStatsTimer: Timer?

    /// Live bytes written by the active program recorder (obs GetRecordStatus).
    var recordByteCount: Int64 { recorder?.liveStats.bytesWritten ?? 0 }

    // Transitions (deliverable 4).
    @Published private(set) var transitionEnabled = true
    @Published private(set) var transitionDuration: Double = 0.3
    /// The transition EFFECT (VisualFX). Applied by every animated scene switch.
    /// Compositor-native kinds (dissolve/wipe/push) run on the zero-copy path;
    /// pixel-effect kinds fall back to a live crossfade (TransitionRenderer port
    /// is future work — see `transitionSchedule`).
    @Published private(set) var transitionKind: TransitionKind = .dissolve
    /// Selected stinger media source (a generated/image source) for stinger-style
    /// scene switches. A non-nil live source replaces the normal transition with
    /// the same cue-frame schedule used by an armed MemeBoard stinger.
    @Published private(set) var stingerMediaID: SourceID?

    // MARK: Sound / Music (PrismSound) — soundboard, beat maker, music bed.

    /// The generated sound catalog (nil if none is installed — UI degrades to an
    /// empty state). Loaded lazily (no audio hardware) on first Sound-tab use.
    private var soundLibrary: SoundLibrary?
    private var soundboard: Soundboard?
    private var beatSequencer: BeatSequencer?
    private var musicBed: MusicBed?
    /// Objects built (channels attached) — HW not necessarily started yet.
    private var soundStackBuilt = false

    @Published private(set) var soundLibraryLoaded = false
    /// 16 soundboard pads → assigned library sound id (nil = empty). Persisted in
    /// UserDefaults (cheap; the scene collection is a frozen engine type).
    @Published var padAssignments: [String?] = AppEngine.loadPadAssignments()
    /// The editable beat pattern (16-step × N-track). Bound to the beat grid.
    @Published private(set) var beatPattern = BeatPattern()
    @Published private(set) var beatIsPlaying = false
    /// Loopable music-bed choices (synth beds always present + any library loops).
    @Published private(set) var musicBeds: [MusicBedChoice] = []
    @Published private(set) var bedIsPlaying = false
    @Published var bedVolume: Double = 0.8
    @Published private(set) var bedDuckingEnabled = false
    @Published private(set) var activeBedID: String?

    // MARK: MemeBoard (PrismCompositor.VisualFX)

    /// Executes meme triggers against the live program (folded in via the render
    /// loop's `sceneProvider` while any meme holds).
    let memeDirector: MemeDirector = {
        let d = MemeDirector()
        // Placed meme layers preserve the meme texture's (canvas) aspect inside
        // their placement rect rather than being stretched (F24).
        d.canvasAspect = Double(AppEngine.canvasSize.width) / Double(AppEngine.canvasSize.height)
        return d
    }()
    @Published private(set) var memeItems: [MemeItem] = []
    /// A stinger tile arms its media for the next real scene/preset switch. This
    /// is intentionally explicit: a tile click has no target scene of its own.
    @Published private(set) var armedStingerMemeID: UUID?
    /// In-flight live stinger identity. Used to cancel safely if its media is
    /// removed mid-transition; the token rejects late completion from a replaced
    /// transition (RenderLoop intentionally drops replaced completions).
    private var activeStingerSourceID: SourceID?
    private var activeStingerToken: UUID?
    private let stingerCueQueue = DispatchQueue(label: "studio.prism.stinger-cue",
                                                qos: .userInitiated)
    private var pendingStingerCueToken: UUID?
    private var pendingStingerCueSourceID: SourceID?
    /// Every video source registered outside `activeSources`, retained together
    /// with its mailbox so a compositor/HDR rebuild can migrate the complete
    /// source graph. Memes are the current client; the generic registry also
    /// protects future overlay/auxiliary registrations from being dropped.
    private struct AuxiliaryVideoSource: @unchecked Sendable {
        let source: VideoSource
        let mailbox: FrameMailbox
    }
    private var auxiliarySources: [SourceID: AuxiliaryVideoSource] = [:]
    /// Security-scoped grants HELD for meme sources that stream from disk for
    /// their whole lifetime (`MovieSource`). Image/GIF memes decode fully at
    /// init and are absent here. Released in `removeMeme` / `deactivateAll`.
    private var memeScopedURLs: [SourceID: URL] = [:]
    /// Aggregate decoded-byte bound across ALL active animated (GIF/movie) memes
    /// (F15 / Class F). A GIF's per-instance budget (512 MiB) multiplied across an
    /// unbounded number of memes was worst-case ≈ N × 512 MiB; this caps the SUM.
    /// `animatedMemeByteCost` is the per-source decoded estimate; the ordered
    /// `animatedMemeLRU` (oldest first) drives eviction when a new meme would
    /// exceed the ceiling.
    static let animatedMemeAggregateByteBudget = 1024 * 1024 * 1024   // 1 GiB hard ceiling
    private var animatedMemeByteCost: [SourceID: Int] = [:]
    private var animatedMemeLRU: [SourceID] = []
    private var animatedMemeDecodedBytes: Int { animatedMemeByteCost.values.reduce(0, +) }
    /// Source URL of an ORDINARY (non-meme) animated GIF, kept so a victim evicted to
    /// admit a replacement can be RE-ADMITTED if the replacement's decode fails (sol #4
    /// evict-before-decode rollback). Cleared in `removeSource`.
    private var animatedGIFSourceURLs: [SourceID: URL] = [:]
    private var memeTemplatesReady = false
    private var memeProviderInstalled = false
    private var memeClearTimer: Timer?
    /// PER-SOURCE latest-wins cue generation (N4 / sol #4): a superseded trigger's
    /// deferred provider install is dropped when a newer trigger for the SAME source
    /// lands mid-cue. Keyed by source so DISTINCT animated inserts never cancel one
    /// another (a single global counter made rapid distinct inserts supersede each
    /// other). Thread-safe (read from the off-main cue queue): a trigger and
    /// `removeMeme` bump ONLY that source's value; `shutdown` invalidates ALL; the
    /// in-flight cue checks its source's value BEFORE restarting — so a removed/
    /// superseded/torn-down meme can never be resurrected or install a provider,
    /// while a concurrently-triggered different meme is untouched.
    private let cueGenerations = OSAllocatedUnfairLock<[SourceID: UInt64]>(initialState: [:])
    /// Cue-generation lookup key for a source. Identity in production; the DEBUG
    /// NEGATIVE CONTROL collapses every source onto one sentinel key to reproduce the
    /// pre-fix single-global-generation behavior (distinct rapid inserts cancelling
    /// each other, sol #4).
    nonisolated static func cueGenKey(_ id: SourceID) -> SourceID {
        #if DEBUG
        if _test_globalCueGeneration { return SourceID("__prism_global_cue__") }
        #endif
        return id
    }
    /// Bump one source's cue generation and return the new value; any in-flight cue
    /// for THAT source captured against an older value is thereby superseded.
    @discardableResult
    private func bumpCueGeneration(for id: SourceID) -> UInt64 {
        let key = Self.cueGenKey(id)
        return cueGenerations.withLock { $0[key, default: 0] &+= 1; return $0[key]! }
    }
    /// The current cue generation for a source (0 if never triggered).
    private func cueGeneration(for id: SourceID) -> UInt64 {
        let key = Self.cueGenKey(id)
        return cueGenerations.withLock { $0[key] ?? 0 }
    }
    /// Invalidate EVERY source's in-flight cue (shutdown): bump all known generations
    /// so any queued cue is superseded regardless of source.
    private func invalidateAllCueGenerations() {
        cueGenerations.withLock { state in for k in state.keys { state[k]! &+= 1 } }
    }
    #if DEBUG
    /// Test seam invoked (on the cue queue) between the pre-start generation check
    /// and the source restart, so a test can deterministically interleave a
    /// removeMeme/shutdown-equivalent supersession into the async-cue race window.
    nonisolated(unsafe) static var _test_cuePreStartHook: (@Sendable () -> Void)?
    /// Bump the cue generations from a test to simulate a supersession (removeMeme /
    /// newer trigger / shutdown) landing mid-cue. Thread-safe.
    nonisolated func _test_bumpCueGeneration() {
        cueGenerations.withLock { state in for k in state.keys { state[k]! &+= 1 } }
    }
    /// NEGATIVE CONTROL toggle for the HDR-resume-after-shutdown guard (sol #3):
    /// when true, `resumeRenderLoopAfterFailedQuiesce` skips its `didShutdown` gate,
    /// so a post-shutdown retry resurrects the render thread (proves the guard is
    /// what prevents it). Off in every normal run.
    static var _test_bypassShutdownResumeGuard = false
    /// NEGATIVE CONTROL for the retry-forever regression (sol #4): when true,
    /// `retryResumeRenderLoop` skips the "loop is already running again → stop" check, so
    /// a chain that fires after the loop recovered reads `start()==false` (refused BECAUSE
    /// running) as "still draining" and retries every 100 ms FOREVER (the pre-fix loop).
    static var _test_bypassResumeRunningCheck = false
    /// Count of `retryResumeRenderLoop` entries (sol #4): a test asserts this stays
    /// BOUNDED (terminates) with the fix and CLIMBS unbounded under the negative control.
    /// PER-INSTANCE (not `static`): a process-global counter is inflated under full-suite
    /// load because retry chains belonging to OTHER engines (other tests, and the real HDR
    /// fail-safe at `setHDREnabled`) reschedule on the shared main queue and land inside a
    /// measuring test's window — an over-count that is a test-harness race, not a product
    /// bug. Scoping it to the engine under test makes the bound observe ONLY that engine's
    /// own retries, so it is immune to cross-engine bleed yet still climbs if THIS engine's
    /// retry regresses to unbounded.
    var _test_resumeRetryAttempts = 0
    /// NEGATIVE CONTROL for the `setHDREnabled` post-shutdown guard (sol #4): when true,
    /// the public entry skips its `didShutdown` gate, so a toggle after shutdown builds
    /// and starts a fresh render loop over torn-down state (a resurrection).
    static var _test_bypassHDRShutdownGuard = false
    /// NEGATIVE CONTROL for the vcam-attach HDR gate (sol #5 #13): when true,
    /// `setHDREnabled` ignores `vcamOutputRequested` (checks only the confirmed
    /// `vcamOutputEnabled`), reproducing the pre-fix window where an HDR toggle slips
    /// through mid-attach and switches the already-live vcam stream to l10r.
    static var _test_ignoreVcamRequestedInHDRGate = false
    /// Test seam (sol #5 #3): skip `ScreenSource.start()` inside
    /// `reconfigureScreenSourcesForHDR` so a headless test can verify the live screen
    /// source's capture config flipped to/from HDR WITHOUT tripping the Screen
    /// Recording TCC prompt (start would attempt a real capture).
    static var _test_skipScreenSourceStart = false
    /// Test seam (sol #6 #7): with `_test_skipScreenSourceStart`, drive the SIMULATED
    /// async-start outcome of a screen-source replacement so a headless test can prove
    /// the keep-old-until-confirmed rollback — `.failure` must restore the old source,
    /// `.success` must commit the swap, `.none` leaves it pending.
    enum ScreenStartOutcome { case none, success, failure }
    static var _test_simulatedScreenStartOutcome: ScreenStartOutcome = .none
    /// NEGATIVE CONTROL (sol #6 #7): reproduce the pre-fix behaviour where an async
    /// start failure LOSES the screen source (old torn down + replacement removed) — so
    /// a test can prove the keep-old-until-confirmed restore is load-bearing.
    static var _test_screenRollbackRemovesOnFailure = false
    /// NEGATIVE CONTROL (sol #7 #2): when true, `startScreenReplacement` does NOT retain
    /// the pending replacement in `pendingScreenReplacements` — reproducing the pre-fix
    /// weak-owner window where the source (started via a `[weak self]` Task) deallocs
    /// before `startCapture` acquires it. A test proves the strong owner is load-bearing.
    static var _test_skipPendingScreenOwnership = false
    /// NEGATIVE CONTROL (sol #7 #2): when true, `screenReplacementFailed` skips the
    /// post-commit restore (returns silently after stopping the failed source) —
    /// reproducing the pre-fix behaviour where a mid-capture failure left a dead source
    /// registered with NO surfaced error.
    static var _test_skipPostCommitScreenRestore = false
    /// NEGATIVE CONTROL (sol #8 #1): when true, `removeSource`/`shutdown` do NOT drain a
    /// pending screen replacement (no gate retire, no stop, no clear) — reproducing the
    /// pre-fix leak where the replacement's capture keeps resolving and its frame callback
    /// keeps posting after the source was removed / the app shut down.
    static var _test_skipPendingScreenDrain = false
    /// NEGATIVE CONTROL (sol #8 #2): when true, `commitScreenReplacement` restores the
    /// pre-fix behaviour where a RESTORE is EXEMPT from the current-mode gate — so a restore
    /// whose `preferHDR` no longer matches `hdrEnabled` commits a stale-mode source (live
    /// `preferHDR` ≠ `hdrEnabled`). The fix re-derives the restore to the current mode instead.
    static var _test_exemptRestoreFromModeGate = false
    /// NEGATIVE CONTROL (sol #9 #2): when true, `commitScreenReplacement` SKIPS the
    /// still-registered-pending identity check and installs a late-arriving replacement even
    /// if its pending record was already DRAINED or SUPERSEDED — reproducing the pre-fix bug
    /// where a stale late `onStarted` stops the CURRENT same-id re-add and installs a retired
    /// (dark) source. The fix makes such a late commit a NO-OP.
    static var _test_skipCommitPendingIdentityCheck = false
    /// NEGATIVE CONTROL (sol #10 #1): when true, `addScreen` / the debug register wire the
    /// ORIGINAL screen source's frame + audio callbacks UNGATED (the pre-fix behaviour) and do
    /// NOT register its gate — so `removeSource` / `shutdown` / the first-HDR-commit cannot
    /// retire it and an in-flight callback posts a frame (mailbox +1) / advances the audio
    /// channel (+256) after teardown. The fix gates every screen source (original + replacement).
    static var _test_skipOriginalScreenGate = false
    /// NEGATIVE CONTROL (sol #10 #2/#3): when true, a pending REPLACEMENT's delivery gate is
    /// built ALREADY-ARMED (live) instead of deferred-armed at commit — reproducing the pre-fix
    /// window in which the OLD and the NEW generation BOTH ingest into the shared
    /// `SourceEffectGPU` / `MixerChannel` concurrently (a forced overlap reaches concurrency 2).
    /// The fix arms the replacement gate only AFTER the old gate is retired+drained (≤1).
    static var _test_armReplacementGateEagerly = false
    /// NEGATIVE CONTROL (sol #11 #1): when true, a DEFERRED replacement's frames arriving during
    /// its async-start window are DROPPED (the pre-fix behaviour) instead of buffered latest-wins.
    /// Reproduces the frame-drop the serialize fix introduced: the successor's sole complete frame
    /// is discarded, and commit arms the gate without replaying it → the screen holds the OLD frame
    /// (or is black with no prior frame) until the source next emits — which an idle SCK source may
    /// never do. The fix buffers the latest deferred frame and flushes it at arm.
    static var _test_skipDeferredScreenBuffer = false
    /// NEGATIVE CONTROL (sol #12 #1): when true, `startScreenReplacement` does NOT supersede an
    /// older pending replacement for the same source AND `commitScreenReplacement` skips the
    /// per-source generation staleness check — reproducing the pre-fix ABA bug. A same-mode
    /// ABA (HDR on→off→on) leaves TWO pending replacements (H1, H2) that both target the final
    /// mode; H2 commits + emits a live frame, then H1 resolves LAST. The mode-only stale check
    /// can't distinguish them, so H1 commits: it retires+stops the live successor H2 and replays
    /// H1's stale buffered frame over H2's newer live content (an idle screen then stays stale
    /// indefinitely). The fix retires+drops the older pending at registration (H1's late commit
    /// finds itself superseded → `removed == nil` → no-op) and, as defense-in-depth, tags each
    /// pending with a monotonic per-source generation the commit re-checks.
    static var _test_skipReplacementSupersession = false
    /// NEGATIVE CONTROL (sol #12 #2, finding #5): when true, `setMovieLoop` rebuilds the RAW
    /// `MovieSource` and wires it directly (the pre-fix behaviour) even when a presenter cutout is
    /// enabled — reproducing the bypass where the new movie's frames skip the (still "on") cutout.
    /// The fix rebuilds the movie INSIDE a fresh cutout wrapper when `cutoutStates[id]` is set.
    static var _test_skipMovieLoopCutoutRebuild = false
    /// TEST HOOK (sol #12 #2, finding #6): when true, `setPresenterCutout` throws right after
    /// stopping the current source — simulating a failing backing (source that won't rebuild/start).
    static var _test_forceCutoutReconfigFailure = false
    /// NEGATIVE CONTROL (sol #12 #2, finding #6): when true, a failed cutout reconfigure does NOT
    /// restore/restart the original source (the pre-fix behaviour) — leaving the registered backing
    /// stranded `.idle` (dark) with only `lastError` set. The fix restores + restarts a raw feed.
    static var _test_skipCutoutFailureRestore = false
    /// sol #10 #2/#3 test hook: fired INSIDE every gated screen delivery body, UNDER the gate
    /// lock (between the concurrency `enter` and `exit`). A forced-overlap probe pins one
    /// generation's body here (holding its gate lock) while it drives the other generation, to
    /// measure the max simultaneous use of the shared pipeline/channel.
    static var _test_screenDeliveryInside: (() -> Void)?
    #if DEBUG
    /// sol #1 NEGATIVE CONTROL: route the PROCESSED (`out`) frame to ISO — the
    /// pre-fix behavior. With this false (default) ISO gets the RAW `frame`.
    nonisolated(unsafe) static var _test_isoUsesProcessedFrame = false
    /// sol #1 oracle hook: fires (capture queue) with the EXACT frame handed to
    /// the ISO tap, so a test can prove it is the clean raw frame, not the graded.
    nonisolated(unsafe) static var _test_isoRoutedFrame: ((VideoFrame) -> Void)?
    /// sol #2 NEGATIVE CONTROL: gate the record-audio track on `activeSources`
    /// (the pre-fix behavior that dropped mixer-only master-mix audio). Default
    /// false → the program master mix is always recorded.
    static var _test_gateRecordAudioOnActiveSources = false
    /// sol #1 NEGATIVE CONTROL: force the pre-fix hardcoded 1920×1080 H.264 SDR
    /// ISO settings for every armed source (ignoring its native format). Default
    /// false → each ISO angle is sized/tagged from its own native frame.
    static var _test_forceISOHardcodedSettings = false
    /// sol wave-16 #1 NEGATIVE CONTROL: for a source with NO frame yet at Record
    /// start, freeze the pre-fix canvas-sized SDR fallback (instead of DEFERRING the
    /// recorder to the first frame). Reproduces "ISO armed before the first frame →
    /// permanently 1920×1080 SDR/H.264". Default false → the recorder is deferred and
    /// the first take is native + HDR-correct.
    nonisolated(unsafe) static var _test_forceISOImmediateCanvasFallback = false
    #endif
    #if DEBUG
    /// sol #10 #2/#3: per-`SourceID` concurrency probes shared by the original + replacement
    /// delivery closures (looked up LAZILY at call time so a test can install a probe after the
    /// source is registered but before it drives frames). A static thread-safe registry because
    /// the closures run on the capture queues, not the main actor.
    static let _test_screenSwapProbes = OSAllocatedUnfairLock<[SourceID: ScreenSwapConcurrencyProbe]>(initialState: [:])
    static func _test_screenSwapProbe(for id: SourceID) -> ScreenSwapConcurrencyProbe? {
        _test_screenSwapProbes.withLock { $0[id] }
    }
    /// Install (or fetch) the shared probe for `id`; the test then reads its max-concurrency /
    /// delivery counts after driving the two generations.
    @discardableResult
    static func _test_installScreenSwapProbe(for id: SourceID) -> ScreenSwapConcurrencyProbe {
        _test_screenSwapProbes.withLock {
            if let p = $0[id] { return p }
            let p = ScreenSwapConcurrencyProbe(); $0[id] = p; return p
        }
    }
    static func _test_clearScreenSwapProbes() { _test_screenSwapProbes.withLock { $0.removeAll() } }
    #endif
    /// sol #10 test probe: the ACTIVE screen source backing `id` (so a forced-overlap probe can
    /// drive the original/committed source's frame + audio callbacks directly, no capture/TCC).
    func _test_activeScreenSource(for id: SourceID) -> ScreenSource? {
        guard let active = activeSources.first(where: { $0.id == id }),
              case .screen(let source) = active.backing else { return nil }
        return source
    }
    /// sol #10 test probe: the render mailbox backing `id`, so a leak test can read
    /// `stats.delivered` as an INDEPENDENT engine oracle for "a frame was posted".
    func _test_screenMailbox(for id: SourceID) -> FrameMailbox? {
        activeSources.first(where: { $0.id == id })?.mailbox
    }
    /// sol #9 #1/#2 test probe: the live gate of the pending replacement for `id`, so a test
    /// can `retire()` it in the exact callback check→post window (or observe teardown).
    func _test_pendingScreenGate(for id: SourceID) -> ScreenReplacementGate? {
        pendingScreenReplacements.values.first(where: { $0.id == id })?.gate
    }
    /// sol #9 #1 test hook: add a mixer channel for `id` so a pending screen replacement built
    /// with `capturesAudio` wires its (gated) audio callback to a real channel.
    func _test_addAudioChannel(id: SourceID) { _ = try? audioMixer.addChannel(id: id) }
    /// sol #9 #1 test probe: the mixer channel's buffered-frame count for `id` (nil = no
    /// channel), so a test can assert a drained replacement's audio callback did NOT advance it.
    func _test_audioChannelBufferedFrames(id: SourceID) -> Int? {
        audioMixer.channel(id: id)?.bufferedFrames
    }
    /// sol #9 #2 test hook: fire a late `onStarted` (commit) for a SPECIFIC replacement source
    /// — including one whose pending record was already drained/superseded — so a test can
    /// prove the identity check makes such a stale late commit a NO-OP.
    func _test_commitScreenReplacementDirect(id: SourceID, source: ScreenSource,
                                             mailbox: FrameMailbox, descriptor: SourceDescriptor) {
        commitScreenReplacement(id: id, newSource: source, mailbox: mailbox, descriptor: descriptor)
    }
    /// sol #8 #2 test hook: synchronously commit EVERY pending screen replacement for `id`
    /// (models their late async successes arriving). Returns the number of replacements
    /// still pending afterwards — a mode-mismatched restore orphans + re-issues a
    /// correct-mode replacement, which a subsequent call then commits (bounded convergence).
    func _test_fireAllPendingScreenCommits(_ id: SourceID) -> Int {
        guard let descriptor = activeSources.first(where: { $0.id == id })?.descriptor else {
            return pendingScreenReplacements.count
        }
        for pending in Array(pendingScreenReplacements.values) {
            commitScreenReplacement(id: pending.id, newSource: pending.source,
                                    mailbox: pending.mailbox, descriptor: descriptor)
        }
        return pendingScreenReplacements.count
    }
    /// sol #8 #1 test probe: the number of live pending screen replacements.
    func _test_pendingScreenReplacementCount() -> Int { pendingScreenReplacements.count }
    /// sol #8 #1 test probe: the pending replacement's source + render mailbox for `id`,
    /// so a test can drive its frame callback AFTER a drain and assert nothing posts.
    func _test_pendingScreenReplacementHandles(for id: SourceID) -> (source: ScreenSource, mailbox: FrameMailbox)? {
        guard let p = pendingScreenReplacements.values.first(where: { $0.id == id }) else { return nil }
        return (p.source, p.mailbox)
    }
    /// sol #7 #2 test probe: a WEAK handle to the most recently created screen
    /// replacement, so a test can observe whether it survives (strongly owned) or
    /// deallocs (pre-fix). Weak → never keeps the source alive itself.
    weak var _test_lastScreenReplacement: ScreenSource?
    /// sol #7 #2 test hook: synchronously drive a POST-commit failure of the live screen
    /// source backing `id` (a mid-capture window/display failure), exercising the
    /// error-surface + deregister + restore-prior path without a real capture.
    func _test_failLiveScreenSource(_ id: SourceID) {
        guard let active = activeSources.first(where: { $0.id == id }),
              case .screen(let source) = active.backing else { return }
        screenReplacementFailed(id: id, failedSource: source,
                                mode: source.configuration.preferHDR,
                                error: NSError(domain: "prism.test", code: 9))
    }
    /// sol #7 #2 test probe: whether the last screen replacement is still alive.
    func _test_lastScreenReplacementAlive() -> Bool { _test_lastScreenReplacement != nil }
    /// sol #7 #2 test hook: fire the LATE async success of the still-pending screen
    /// replacement for `id` (models an HDR on→off toggle where the first replacement's
    /// start confirms after the mode already flipped back). The commit mode-gate must
    /// REJECT it (stale) and keep the current entry.
    func _test_fireLatePendingScreenCommit(_ id: SourceID) {
        guard let active = activeSources.first(where: { $0.id == id }),
              let mailbox = active.mailbox,
              let pending = pendingScreenReplacements.values.first else { return }
        commitScreenReplacement(id: id, newSource: pending.source,
                                mailbox: mailbox, descriptor: active.descriptor)
    }
    /// NEGATIVE CONTROL for the peak-ceiling fix (sol #4): when true, `addMeme`/
    /// `addGIFSource` commit the planned eviction AFTER constructing the replacement
    /// (the wave-4 evict-on-success order) — so at `_test_beforeAnimatedDecodeHook` the
    /// victims are STILL resident and peak = victims + replacement overshoots the ceiling.
    static var _test_evictAfterConstruct = false
    /// NEGATIVE CONTROL for the evict-before-decode ROLLBACK (sol #4): when true, a failed
    /// replacement admit does NOT re-admit the evicted victims (destructive loss).
    static var _test_skipAdmissionRollback = false
    /// NEGATIVE CONTROL for the FULL-state rollback (sol #5 #10): when true,
    /// `rollbackAnimatedEviction` re-admits victims BARE by URL (the pre-fix path) —
    /// restoring only the bytes/presence, losing the scene layer / transform / effects /
    /// arm state — so a test can prove the state-preserving rollback is load-bearing.
    static var _test_rollbackBareReadmit = false
    /// Test hook fired AFTER eviction and BEFORE decoding the replacement (sol #4), so a
    /// test can observe that the victims are already evicted at the peak-decode moment
    /// (and read the aggregate byte total to assert peak stays under the ceiling).
    nonisolated(unsafe) static var _test_beforeAnimatedDecodeHook: (() -> Void)?
    /// When true, animated-source construction throws (simulates a decode/alloc
    /// failure AFTER admission) so the evict-then-rollback ordering can be exercised.
    static var _test_forceAnimatedConstructionFailure = false
    /// sol #6 #10: fail the next N consecutive animated-source constructions (NOT
    /// one-shot) so a rollback where the VICTIM's own re-decode ALSO fails (the
    /// double-failure) can be exercised: set to 2 → the triggering admit AND the
    /// victim re-admit both throw.
    static var _test_forcedAnimatedConstructionFailuresRemaining = 0
    /// NEGATIVE CONTROL (sol #6 #10): reproduce the pre-fix rollback that bound the
    /// restored victim state to the stale `lastAddedVideoSourceID` instead of the
    /// re-admit RESULT — so a double-failure mutates whatever source `lastAdded` names.
    static var _test_rollbackBindToLastAdded = false
    /// NEGATIVE CONTROL (sol #6 #10): skip restoring vertical-hero + stinger routing on
    /// rollback (the pre-fix behaviour, which lost both) to prove the restore is real.
    static var _test_rollbackSkipHeroStinger = false
    /// NEGATIVE CONTROL (sol #7 #8): skip restoring the victim's ORIGINAL LRU position on
    /// rollback (the pre-fix behaviour: the re-admit APPENDS at the newest end) — so a
    /// test proves the position restore is what keeps the next eviction picking the true
    /// oldest victim.
    static var _test_rollbackSkipLRURestore = false
    /// sol #7 #8 test probe: the current animated-media LRU order (oldest first).
    func _test_animatedMediaLRU() -> [SourceID] { animatedMemeLRU }
    static func _test_throwIfForcedConstructionFailure() throws {
        if _test_forcedAnimatedConstructionFailuresRemaining > 0 {
            _test_forcedAnimatedConstructionFailuresRemaining -= 1
            throw NSError(domain: "prism.test", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "forced construction failure (n)"])
        }
        if _test_forceAnimatedConstructionFailure {
            // ONE-SHOT: reset so the failure hits only the triggering admit; the rollback
            // re-admit of the evicted victims then decodes normally (sol #4).
            _test_forceAnimatedConstructionFailure = false
            throw NSError(domain: "prism.test", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "forced construction failure"])
        }
    }
    /// NEGATIVE CONTROL for per-source cue generations (sol #4): collapse all sources
    /// onto one shared generation key (the pre-fix single-global counter) so distinct
    /// rapid inserts cancel one another. `nonisolated(unsafe)` — read from the off-main
    /// cue key helper; toggled on the main thread around a single test.
    nonisolated(unsafe) static var _test_globalCueGeneration = false
    /// NEGATIVE CONTROL for per-meme deadlines (sol #4): when true, a trigger couples
    /// every held meme onto the single LONGEST deadline (the pre-fix global `max`), so
    /// a short meme's source keeps decoding until the longest held meme's hold end.
    static var _test_coupleMemeLifetimes = false
    /// NEGATIVE CONTROL for the stinger terminal-path stop (sol #3): when true, the
    /// cancel/replace and failed-cue paths do NOT stop the stinger media (pre-fix),
    /// so it free-runs after the transition is abandoned.
    static var _test_skipStingerTerminalStop = false
    /// Force `beginStingerCue` to report FAILURE (drives the timeout/error terminal
    /// path live) — the media was restarted, so only the failed-cue completion stops it.
    static var _test_forceStingerCueFailure = false
    /// NEGATIVE CONTROL for meme-expiry scoping (sol #3): when true, meme teardown
    /// stops EVERY animated meme source (the pre-fix `stopAnimatedMemeSources`), which
    /// can freeze an unrelated in-flight stinger.
    static var _test_stopAllMemesOnExpiry = false
    /// NEGATIVE CONTROL for the F14-residual frame-zero gate (sol #7): when true, the
    /// cue does NOT pause the source at frame 0 and `showMemeProvider` does NOT clear
    /// the stale FrameStore — reproducing the pre-fix race where the first presented
    /// meme frame is a post-zero frame. `nonisolated(unsafe)` — read from the off-main
    /// cue; toggled on the main thread around a single test.
    nonisolated(unsafe) static var _test_skipFrameZeroGate = false
    /// NEGATIVE CONTROL for the expired-queued-cue fix (sol #4): when true, teardown
    /// deletes an expired source's deadline WITHOUT bumping its cue generation (the
    /// pre-fix behavior), so a still-queued cue for that source resurrects it and
    /// installs an untracked provider with no teardown.
    static var _test_skipTeardownGenerationBump = false
    #endif
    /// PER-MEME teardown deadlines in HOUSE-CLOCK seconds (monotonic host time), NOT
    /// wall-clock `Date` (F21 — a backward NTP/DST wall-clock step must never strand
    /// or early-expire a meme). Keyed by source so INDEPENDENT memes tear down on
    /// their OWN schedule (sol #4): a single global `max` deadline made a short meme
    /// keep decoding until the LONGEST held meme's deadline, and removing the long
    /// one stranded the already-expired short one's source running forever. The
    /// single `memeClearTimer` is (re)scheduled at the NEAREST survivor deadline; the
    /// expiry decision compares house time per source.
    private var memeDeadlinesHouse: [SourceID: Double] = [:]
    /// Thread-safe resting-program snapshot the meme `sceneProvider` folds over
    /// (updated from the `scene` didSet so inserts sit atop live edits/presets).
    private let memeBaseScene = OSAllocatedUnfairLock<ProgramScene>(initialState: ProgramScene(name: "Program"))

    // MARK: Character sources (PrismSources.CharacterSource — VTuber rig)

    /// Active character sources, for the inspector's expression picker.
    private var characterSources: [SourceID: CharacterSource] = [:]

    /// Active motion-graphics overlay sources (lower-third / name-tag / countdown /
    /// subscribe-bug), for the inspector's live text/corner/accent/timing controls.
    private var overlaySources: [SourceID: MotionGraphicsOverlaySource] = [:]

    // MARK: Animation-overlay sources (AnimatedLogo / Ticker / Credits — DESIGN §1–2)

    /// One animated-logo overlay + everything a live edit needs. Its style/timing
    /// are `let` on `AnimatedLogoSource`, so an edit REBUILDS it in place (mirrors
    /// the montage rebuild). The security-scoped URL is held for the logo's whole
    /// lifetime so a Release-build rebuild can re-read the image; released on removal.
    struct LogoEntry { let url: URL; let scoped: Bool; var config: LogoConfig }
    private var logoEntries: [SourceID: LogoEntry] = [:]
    /// Ticker overlays keyed by id. `text` is live (`setText`); a speed/position/
    /// accent change REBUILDS the source in place.
    private var tickerEntries: [SourceID: TickerConfig] = [:]
    /// Credits-roll overlays keyed by id. A speed/loop change REBUILDS in place.
    private var creditsEntries: [SourceID: CreditsConfig] = [:]

    // MARK: Character lip-sync (AudioEnvelopeFollower → CharacterSource.setMouthOpenness)

    /// Character ids with "Lip-sync to program audio" ON. While non-empty a single
    /// shared `AudioEnvelopeFollower` is fed the program master mix and a ~60 Hz
    /// timer pushes its `openness` to every listed character.
    private var lipSyncCharacterIDs: Set<SourceID> = []
    private var lipSyncFollower: AudioEnvelopeFollower?
    private var lipSyncTimer: Timer?

    // MARK: Per-layer motion (LayerMotion → the render loop's sceneProvider)

    /// Active per-layer motions keyed by the layer's source id. While non-empty
    /// (and no entrance is animating) the render loop's `sceneProvider` applies
    /// each motion's transform to its layer every tick, driven off the house clock.
    private var layerMotions: [SourceID: ActiveLayerMotion] = [:]

    /// The lower-third overlay the last "Quick Scene" (`generateQuickScene`)
    /// composed, so a second Generate REPLACES it (updates config + re-cues in
    /// place) rather than stacking a new overlay. Cleared if the operator removes
    /// the overlay manually.
    private var quickSceneOverlayID: SourceID?
    /// The music-bed id the last Quick Scene started, so a re-Generate can stop it
    /// before starting the new one (never leaves the previous bed playing).
    private var quickSceneBedID: String?
    /// Human-readable note about the last Quick Scene (e.g. which vibe matched, or
    /// that no bed matched) — surfaced by the Quick Scene sheet after Generate.
    @Published private(set) var quickSceneStatus: String?

    /// Presenter-cutout wrappers keyed by the source they wrap. When present, the
    /// wrapper (not the underlying camera/movie) drives frames into the mailbox.
    private var cutoutSources: [SourceID: PresenterCutoutSource] = [:]
    /// The last-applied cutout state per source (drives the inspector + the
    /// premultiplied-alpha decision). Absent ⇒ cutout off.
    private var cutoutStates: [SourceID: CutoutState] = [:]

    // MARK: Video-file sources (PrismSources.MovieSource — a decoded clip)

    /// A decoded video-FILE source and the state the inspector + lifecycle need:
    /// the clip's URL (for a loop rebuild), the current loop flag, and whether we
    /// hold a security-scoped grant to release on removal (sandboxed Release build).
    private struct MovieEntry {
        let source: MovieSource
        let fileURL: URL
        var loop: Bool
        let scoped: Bool
    }
    /// Active movie sources, keyed by id. Drives the inspector's Video section
    /// (loop toggle / native size) and the scoped-access release on removal.
    private var movieSources: [SourceID: MovieEntry] = [:]

    // MARK: Montage sources (PrismSources.MontageSource — Build B)

    /// A montage source and everything the inspector + lifecycle need. Its params
    /// are `let` on `MontageSource`, so a live edit REBUILDS the source in place
    /// (same id / mailbox / pipeline / layer) — mirroring `setMovieLoop`. The
    /// security-scoped URLs are held for the montage's whole lifetime (it streams
    /// video items from disk) and released on removal.
    private struct MontageEntry {
        let items: [MontageSource.MontageItem]
        let scopedURLs: [URL]
        var interval: Double
        var transition: MontageSource.Transition
        var kenBurns: Bool
        var shuffle: Bool
        var loop: Bool
        /// Beat-sync (BEAT_SYNC_DESIGN "App wiring"): when true the montage cuts on
        /// the BeatSequencer downbeat (every `cutEveryBeats` beats) instead of
        /// relying only on the fixed `interval`. Stopped ⇒ the interval still runs.
        var cutOnBeat: Bool = false
        var cutEveryBeats: Int = 1
    }
    /// Active montage sources, keyed by id.
    private var montageSources: [SourceID: MontageEntry] = [:]

    // Screen browser ("Add Display/Window" — explicit click only: enumerating
    // shareable content is what triggers the Screen Recording TCC prompt).
    @Published private(set) var screenItems: [SourceDescriptor] = []
    @Published private(set) var screenBrowserBusy = false
    @Published private(set) var screenBrowserError: String?

    // Record
    @Published private(set) var isRecording = false
    @Published private(set) var recordStartDate: Date?
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var lastVerticalRecordingURL: URL?

    // Vertical program (9:16) controls.
    @Published private(set) var verticalProgramEnabled = false
    @Published private(set) var verticalReframeMode: VerticalReframeMode = .heroFill
    /// The pinned hero source for `.follow` mode (nil → frontmost / default).
    @Published private(set) var verticalHeroSourceID: SourceID?

    // ISO recording (deliverable 3). Per-source arm set (edited while idle),
    // the live bank, and per-source status/result surfaces for the UI.
    @Published private(set) var isoArmedSourceIDs: Set<SourceID> = []
    /// Live per-source ISO status text while recording (frames written etc.).
    @Published private(set) var isoStatuses: [SourceID: String] = [:]
    /// Files produced by the last finished ISO session (source → URL).
    @Published private(set) var lastISOFiles: [SourceID: URL] = [:]
    private var isoBank: ISORecorderBank?
    private var isoStatusTimer: Timer?

    // Multitrack audio (deliverable 3): per-source AUDIO tracks recorded beside
    // the program. Armed while idle (mirrors ISO), started as a shared-clock
    // `AudioTrackRecorderBank` at Record start, finalized on Stop.
    @Published private(set) var multitrackArmedSourceIDs: Set<SourceID> = []
    /// Files produced by the last finished multitrack session (source → URL).
    @Published private(set) var lastMultitrackFiles: [SourceID: URL] = [:]
    private var multitrackBank: AudioTrackRecorderBank?

    // Replay buffer (deliverable 2).
    @Published private(set) var replayArmed = false
    @Published private(set) var replayLengthSeconds: Double = 30
    @Published private(set) var lastReplayURL: URL?
    /// Live buffered span in seconds (HUD), refreshed while armed.
    @Published private(set) var replayBufferedSeconds: Double = 0
    private var replayBuffer: ReplayBuffer?
    private var replayEncoder: ProgramEncoder?
    private var replayStatusTimer: Timer?

    // "Clip that moment" (feature 3): save the last N seconds of the replay ring.
    @Published private(set) var clipLengthSeconds: Double = 20
    @Published private(set) var lastClipURL: URL?

    // MARK: - Director's Cut (FLAGSHIP, slice 2 — signals → score → auto-save)

    /// Owns the pure `HighlightDirector` scoring engine (slice 1) when the
    /// flagship is on. Off by default: no director, no wiring, no per-signal work
    /// — the live-signal feed adapters short-circuit on `directorsCutEnabled`, so
    /// turning it off restores exactly the prior behaviour with zero overhead.
    @Published private(set) var directorsCutEnabled = false
    /// Rolling top-N highlight moments (observable, for a future list/UI).
    @Published private(set) var topDirectorHighlights: [HighlightDirector.Highlight] = []
    /// URL of the most recently auto-saved horizontal highlight clip.
    @Published private(set) var lastHighlightURL: URL?
    /// EVERY persisted highlight candidate of the session (slice-3a) — the data
    /// model the future "Review & Finish" UI consumes. Mirrors the store below.
    @Published private(set) var highlightCandidates: [HighlightCandidate] = []
    private var highlightDirector: HighlightDirector?
    /// Ordered, observable candidate store + JSON sidecar (survives relaunch).
    /// Rebuilt per Director's-Cut session so each session owns its own sidecar.
    private var highlightCandidateStore: HighlightCandidateStore?
    /// Pre-roll / post-roll (s) of the captured window `[peak − pre, peak + post]`.
    /// Post-roll defers the save so the PAYOFF after the hype peak is captured, not
    /// just the run-up. Internal-settable (clamped) so tests can drive fast timing.
    private(set) var directorsCutPreRollSeconds: Double = 8
    private(set) var directorsCutPostRollSeconds: Double = 3
    /// Pending post-roll capture timers, keyed by candidate id. A new peak during
    /// another's post-roll simply schedules a second independent timer — both fire,
    /// no candidate is lost or duplicated (overlap determinism).
    private var pendingHighlightTimers: [UUID: Timer] = [:]
    /// Bounds concurrent paired captures so a burst can't flood the muxer/exporter.
    private let highlightAutoSaver = HighlightAutoSaver(maxInFlight: 2)
    /// Produces the 9:16 asset from the saved 16:9 clip. Slice-3b: a SUBJECT-
    /// TRACKING (Center-Stage-style speaker-follow) reframe that falls back to the
    /// slice-3a centred crop when no subject is found / analysis fails. The
    /// `tracking` toggle (see `setDirectorsCutSubjectTracking`) makes it reversible
    /// to the pure centred (3a) behaviour. Overridable for tests.
    private let verticalReframer: VerticalHighlightProducing = SubjectTrackingVerticalReframer()

    /// Toggle the slice-3b subject-tracking reframe on/off (reversible). Off ⇒ the
    /// 9:16 asset is the slice-3a centred crop. No-op if a test override is active.
    func setDirectorsCutSubjectTracking(_ on: Bool) {
        (verticalReframer as? SubjectTrackingVerticalReframer)?.tracking = on
    }
    /// Test seam: inject a mock clip saver (verifies the capture path without disk).
    /// Also satisfies `directorsCutHasClipSource` so a headless test can score.
    var _test_highlightSaverOverride: HighlightClipSaving?
    /// Test seam: inject a mock vertical reframer (verifies pairing without export).
    var _test_verticalReframerOverride: VerticalHighlightProducing?
    /// Test seam: override the director's scoring config on enable (e.g. small minGap).
    var _test_directorConfigOverride: HighlightDirector.Config?
    /// Test seam: redirect the auto-save folder (default ~/Movies/Prism/Director's Cut).
    var _test_directorsCutDirectoryOverride: URL?

    /// Set the pre/post-roll window (clamped ≥ 0; post-roll capped so a scheduled
    /// save can't be deferred absurdly). Internal — used by settings + tests.
    func setDirectorsCutRoll(preRoll: Double, postRoll: Double) {
        directorsCutPreRollSeconds = min(60, max(0, preRoll))
        directorsCutPostRollSeconds = min(30, max(0, postRoll))
    }

    // Live captions (feature 1).
    @Published private(set) var captionsEnabled = false
    /// One-line reason captions can't transcribe (no authorization / no on-device
    /// model). nil when off or transcribing fine. Drives the disabled-state note.
    @Published private(set) var captionsStatusNote: String?
    private var captioner: LiveCaptioner?
    private var captionOverlay: LiveCaptionOverlaySource?
    private var captionStatusTimer: Timer?

    // Reactive trigger (feature 4): auto-fire an effect on a loud program transient.
    @Published private(set) var reactiveTrigger: ReactiveTrigger = .none
    private var transientDetector: TransientDetector?

    // FCPXML export (deliverable 4): the last multi-angle session, retained so
    // the export has real per-angle URLs / durations / offsets.
    @Published private(set) var lastMulticamExportable = false
    @Published private(set) var lastExportedFCPXMLURL: URL?
    private var lastFinishedSession: FinishedMulticamSession?

    // Virtual camera
    @Published private(set) var vcamInstallStatus = "Extension not activated"
    @Published private(set) var vcamActivationInFlight = false
    @Published private(set) var vcamFeederStatus = "Off"
    /// The user's toggle position ("send program to the virtual camera").
    @Published private(set) var vcamOutputRequested = false
    /// True only while the feeder has CONFIRMED it is feeding (C30): set on
    /// the feeder's `.feeding` state, never optimistically at start().
    @Published private(set) var vcamOutputEnabled = false

    // Control server
    @Published private(set) var controlServerRunning = false

    // Preflight "Broadcast Check" (deliverable 2): the most recent report,
    // surfaced in the sheet and mirrored into the debug state file.
    @Published private(set) var lastBroadcastReport: BroadcastReport?
    /// Re-entrancy guard for `runBroadcastCheck` so the debug-timer auto-run and
    /// the view's `.task` can't overlap and race on `lastBroadcastReport` (Codex).
    private var isRunningBroadcastCheck = false

    // MARK: - MIDI control surface (PrismControlSurface)

    /// Live MIDI → abstract-action bridge. Constructed at launch (prompt-free:
    /// no CoreMIDI client until `start()`); `start()`/`stop()` gate the actual
    /// MIDI input behind the enable toggle.
    private var controlSurface: ControlSurface?
    @Published private(set) var controlSurfaceEnabled = false
    /// Mirror of the live mapping for the UI: action bindingKey → human-readable
    /// bound trigger ("Note 60 · ch 1").
    @Published private(set) var surfaceBindings: [String: String] = [:]
    /// The action currently awaiting a MIDI-learn capture (nil = not learning).
    @Published private(set) var surfaceLearningAction: SurfaceAction?
    /// Telemetry/verification: how many surface actions have dispatched to an
    /// AppEngine intent, and the last one's bindingKey.
    @Published private(set) var surfaceActionCount = 0
    @Published private(set) var surfaceLastAction: String?

    // MARK: - Nearby devices (PrismProximity — BLE discovery only)

    /// macOS central-role scanner for nearby iOS Prism companions. Discovery is
    /// behind a toggle (the first `startDiscovery()` triggers the Bluetooth
    /// permission prompt — NSBluetoothAlwaysUsageDescription is in the Info.plist).
    private let proximityController = ProximityController()
    @Published private(set) var proximityDiscovering = false
    @Published private(set) var proximityCandidates: [ProximityCandidate] = []
    @Published private(set) var proximityRadioState = "unknown"
    /// The "pair over Wi-Fi with code NNNN" hint shown when a nearby device is
    /// tapped — BLE is discovery-only; the real pair is the existing QUIC flow.
    @Published private(set) var nearbyHint: String?

    // MARK: - Auto-Director (PrismDirector)

    /// Produces switch/framing decisions from submitted source frames. Created
    /// lazily on first enable; frames reach it through `directorTap`.
    private var director: DirectorController?
    private let directorTap = DirectorTap()
    @Published private(set) var autoDirectorEnabled = false
    @Published private(set) var directorSensitivity: Double = 0.5
    @Published private(set) var directorMinShotSeconds: Double = 2.0
    @Published private(set) var directorDecisionCount = 0
    @Published private(set) var directorActiveSourceID: SourceID?
    /// Debug-only (PRISM_DEBUG_AUTODIRECTOR): injects a synthetic audio level so
    /// a source clears the activation floor headlessly and a decision fires.
    private var directorAudioInjectTimer: Timer?
    @Published private(set) var debugSignalCount = 0
    @Published private(set) var debugLastActivity: Double = 0

    // MARK: - HDR output

    /// When true the program runs in HDR (Rec.2020 HLG, 10-bit): the compositor
    /// + render loop are rebuilt in `.hdr` ColorMode and new recordings are
    /// tagged HDR. Gated off-air (rebuilding under an active recording/stream
    /// would feed 10-bit frames to an 8-bit-configured writer/encoder).
    @Published private(set) var hdrEnabled = false

    @Published var lastError: String?

    /// On-air = ANY live output is running: recording, virtual camera, OR
    /// streaming (RTMP/SRT). Omitting `isStreaming` here reported "not on air"
    /// while actively broadcasting — a false operator status.
    var isOnAir: Bool { Self.computeOnAir(recording: isRecording, vcam: vcamOutputEnabled, streaming: isStreaming) }

    /// Pure on-air predicate (extracted so the contract is unit-testable without
    /// driving a live output). Every live-output surface must be OR'd in here.
    static func computeOnAir(recording: Bool, vcam: Bool, streaming: Bool) -> Bool {
        recording || vcam || streaming
    }

    /// Serial queue for outbound LinkPeer control sends (C25). LinkPeer's
    /// send* methods do NOT hop to the link queue internally, so they must
    /// never run on the main actor; this queue keeps our sends off the main
    /// actor and serialized with each other. (The complete fix — hopping to
    /// the peer's own queue inside LinkPeer — is engine-side, tracked there.)
    private let linkSendQueue = DispatchQueue(label: "studio.prism.app.link-send", qos: .userInitiated)

    private let log = EngineLog.logger("app.engine")

    // MARK: Init

    init() {
        let code = Self.loadOrCreatePairingCode()
        pairingCode = code
        linkServer = LinkServer(configuration: .init(pairingCode: code))
        let env = ProcessInfo.processInfo.environment
        linkDebugMonitor = (env["PRISM_LINK_STATE_FILE"]?.isEmpty == false)
            ? LinkDebugMonitor() : nil

        let device = MTLCreateSystemDefaultDevice()
        metalDevice = device
        // Second (vertical) program on its own compositor/queue — same device.
        dualProgram = device.flatMap {
            try? DualProgram(device: $0,
                             width: Self.verticalCanvasSize.width,
                             height: Self.verticalCanvasSize.height)
        }
        if let loop = buildRenderLoop(colorMode: .sdr) {
            loop.start()
            renderLoop = loop
        } else {
            engineFault = "Metal is unavailable — the compositor could not start."
        }

        // Vertical program frame → 9:16 preview + optional recorder.
        dualProgram?.onSecondaryFrame = { [verticalSink] frame in verticalSink.consume(frame) }
        verticalSink.onRecorderFailure = { [weak self] failed in
            DispatchQueue.main.async { self?.verticalRecorderFailed(failed) }
        }
        dualProgram?.scene = scene

        Self.current = self // reachable by App Intents (all stored props now initialized)
        controlBackend.engine = self
        controlServer.backend = controlBackend
        setupControlSurface() // MIDI control surface (input starts only on the toggle)

        // Audio mixer master tap: the combined program mix feeds the same
        // fan-out the recorder + stream draw audio from. Set before start().
        audioMixer.onMasterMix = { [fanOut] packet in fanOut.handle(audio: packet) }
        // LUFS metering: attach before start() so the master tap feeds it every
        // callback (deliverable 3). Polled into `masterLoudness` by the meter timer.
        audioMixer.setLoudnessMeter(loudnessMeter)

        feeder.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                self.vcamFeederStatus = Self.describe(state)
                // C30: on-air only once the feeder confirms .feeding; any
                // other state (searching/failed/stopped) is not on-air.
                self.vcamOutputEnabled = self.vcamOutputRequested && state == .feeding
            }
        }

        // C29: the fan-out polls MovieRecorder.state after appends (throttled)
        // and reports a mid-recording writer failure exactly once.
        fanOut.onRecorderFailure = { [weak self] failed in
            DispatchQueue.main.async { self?.recorderFailed(failed) }
        }

        deviceManager.onDeviceEvent = { [weak self] _ in
            DispatchQueue.main.async { self?.refreshDevices() }
        }
        refreshDevices()
        // Peer-connect (PrismLink) is OPT-IN, OFF BY DEFAULT: do NOT start the
        // Link server on launch. Starting it eagerly created a TLS identity
        // (LinkIdentity.createEphemeral → macOS keychain prompt) and advertised
        // over Bonjour on every launch even when the user never uses peer
        // connect. The server (and its identity) now start only when the user
        // enables peer-connect via `setLinkEnabled(true)`.
        sceneCollections = SceneCollectionStore.load() // v2 deliverable 1
        destinations = StreamDestinationsStore.load()  // deliverable B: restream targets
        restorePersistedSettings()                     // transition kind/enable/duration + stinger
        restorePersistedSources()                      // source persistence: reopen the saved show's sources

        // Debug-only: auto-start the obs-websocket control server on TCP 4455 so
        // a headless loopback client can exercise the request surface without the
        // UI toggle. No-op in normal use.
        if env["PRISM_DEBUG_CONTROL_SERVER"] == "1" {
            setControlServer(true)
        }

        // Debug-only headless exerciser (no-op in normal use): drives the
        // source-free wave-2 plumbing — scene transitions, the audio-mixer
        // engine start, and an RTMP connect to a dead URL that must fail
        // gracefully — so a CLI run proves the wiring runs without crashing.
        // TCC-gated capture (camera/mic/system-audio start) is NOT exercised.
        if env["PRISM_DEBUG_EXERCISE"] == "1" {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.applyPreset(.pipCorner)   // animated switchScene (crossfade)
                    self.applyPreset(.sideBySide)
                    self.setTransitionEnabled(false)
                    self.applyPreset(.fullscreen)  // instant-cut path
                    self.setTransitionEnabled(true)
                    self.ensureAudioMixerStarted()  // AVAudioEngine start on this Mac
                    // Dead RTMP target: encoder starts, connect fails → teardown.
                    self.startStream(url: "rtmp://127.0.0.1:1/none", streamKey: "x")
                }
            }
        }

        // Debug-only end-to-end proof for the generated-source path (no TCC):
        // add a live-clock TextSource shortly after launch. It renders into the
        // program, so PRISM_LINK_STATE_FILE's programFingerprint changes and the
        // source appears in the "sources" array — camera-free verification.
        if env["PRISM_DEBUG_ADD_TEXT"] == "1" {
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.addTextSource(text: "PRISM {time}", fontSize: 120, color: .white)
                }
            }
        }

        // Debug-only: auto-add the first connected camera at launch (for capturing
        // a walkthrough with real video). No effect in normal use.
        if env["PRISM_DEBUG_USE_CAMERA"] == "1" {
            Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let cam = self?.cameras.first { self?.addCamera(cam) }
                }
            }
        }

        // Debug-only: background blur (person segmentation) on the first camera —
        // confirms the headline no-green-screen path runs on real video.
        if env["PRISM_DEBUG_CAMERA_BG"] == "1" {
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let cam = self.cameras.first else { return }
                    let id = SourceID(cam.id)
                    if self.isActive(id) { self.setBackground(.blur(radius: 30), for: id) }
                }
            }
        }

        // Debug-only: apply a strong, obvious color grade to the first camera so a
        // screenshot can confirm the per-source effect pipeline works on real video.
        if env["PRISM_DEBUG_CAMERA_GRADE"] == "1" {
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let cam = self.cameras.first else { return }
                    let id = SourceID(cam.id)
                    if self.isActive(id) {
                        self.setGrade(ColorGrade(exposure: 0.3, contrast: 1.15, saturation: 2.2,
                                                 temperature: 0.7, tint: -0.1), for: id)
                    }
                }
            }
        }

        // Debug-only end-to-end proof for the DUAL program: enable the vertical
        // (9:16) program at launch. The synthetic text source (PRISM_DEBUG_ADD_TEXT)
        // then flows into the SECOND composite, so the state file's
        // verticalFramesProduced counter advances — real proof the dual composite
        // runs — while programCompositeErrors / verticalCompositeErrors stay 0.
        if env["PRISM_DEBUG_VERTICAL"] == "1" {
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.setVerticalEnabled(true) }
            }
        }

        // Debug-only (deliverable 2): run the preflight Broadcast Check shortly
        // after launch and mirror its pass/warn/fail results into the state file
        // (`broadcastCheckOverall` + `broadcastChecks`). Headless-safe: the disk/
        // thermal/encoder/sources checks run fine, and the RTMP-host probe warns/
        // skips cleanly when no target is configured.
        if env["PRISM_DEBUG_BROADCAST_CHECK"] == "1" {
            Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { @MainActor in _ = await self.runBroadcastCheck() }
                }
            }
        }

        // Debug-only (v2 deliverable 1): save the current scene as a named
        // collection, then reload the file from disk to prove the round-trip.
        // Result lands in the state file as `collectionRoundTripOK`.
        if let name = env["PRISM_DEBUG_SAVE_COLLECTION"], !name.isEmpty {
            Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.debugSaveAndReloadCollection(named: name) }
            }
        }

        // Debug-only (CRITICAL alpha fix): add a solid background + a foreground
        // generated source, then enable background-remove on the TOP source. The
        // top layer's premultipliedAlpha MUST flip to true and the composite must
        // keep running (programCompositeErrors stays 0) — proving the Codex C1
        // alpha-layer flag is wired end-to-end without a camera. Verified via the
        // state file's `layers` array.
        if env["PRISM_DEBUG_ALPHA_LAYERS"] == "1" {
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.debugAddAlphaLayers() }
            }
        }

        // Debug-only (LUMA key): add a background + a bright foreground generated
        // source, then enable a luma key on the TOP source. The top layer's
        // premultipliedAlpha MUST flip to true and the composite must keep running
        // (programCompositeErrors stays 0) — proving the luma keyer is wired
        // end-to-end without a camera. Verified via the state file's `layers`.
        if env["PRISM_DEBUG_LUMA_LAYERS"] == "1" {
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.debugAddLumaLayers() }
            }
        }

        // Debug-only (v2 deliverable 3): animate the newest video layer in,
        // proving frames keep flowing during an animation (programFramesDelivered
        // keeps advancing, compositeErrors stays 0 in the state file).
        if env["PRISM_DEBUG_ANIMATE_IN"] == "1" {
            Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self,
                          let layer = self.scene.layers.max(by: { $0.zIndex < $1.zIndex })
                    else { return }
                    self.animateLayerIn(sourceID: layer.sourceID, preset: .fadeIn, duration: 2.0)
                }
            }
        }

        // Debug-only (Auto-Director): enable the director, add a second generated
        // source alongside PRISM_DEBUG_ADD_TEXT's clock, and inject a synthetic
        // audio level so a source clears the activation floor headlessly. The
        // state file's `directorDecisionCount` then advances while
        // `programCompositeErrors` stays 0. Camera-free.
        if env["PRISM_DEBUG_AUTODIRECTOR"] == "1" {
            Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.debugStartAutoDirector() }
            }
        }

        // Debug-only (MIDI control surface): feed a synthetic MIDIMessage through
        // a MIDIActionMap and dispatch the resulting SurfaceAction to the real
        // AppEngine intent — proving the message→action→intent path without
        // hardware MIDI. `surfaceActionCount` advances + `selectedPreset` changes.
        if env["PRISM_DEBUG_MIDI_LEARN"] == "1" {
            Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.debugMIDIDispatch() }
            }
        }

        // Debug-only (HDR output): rebuild the compositor + render loop in `.hdr`
        // ColorMode and confirm the program keeps delivering frames with 0
        // composite errors in HDR mode (state file `hdrEnabled` + `programCompositeErrors`).
        if env["PRISM_DEBUG_HDR"] == "1" {
            Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.setHDREnabled(true) }
            }
        }

        // Debug-only (deliverable B): configure two DEAD destinations (one RTMP,
        // one SRT) — in-memory, not persisted — start the audio mixer so the
        // master-mix tap feeds program audio, and go live via the broadcaster
        // with NO single-RTMP primary. Proves the broadcaster is fed BOTH video
        // (encoder → broadcast(encodedVideo:)) AND audio (master tap →
        // broadcast(audio:)) via `broadcastVideoFrames`/`broadcastAudioFrames`,
        // and that dead destinations never stall the program (programCompositeErrors
        // stays 0, clean quit). Camera-free; capture stays TCC-gated & untouched.
        if env["PRISM_DEBUG_MULTIDEST"] == "1" {
            Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.debugStartMultiDestination() }
            }
        }
    }

    /// Debug harness for deliverable B (see the PRISM_DEBUG_MULTIDEST hook).
    private func debugStartMultiDestination() {
        // Two unreachable targets: RTMP + SRT (SRT with audio muxed).
        destinations = [
            Destination(name: "Dead RTMP", proto: .rtmp, url: "rtmp://127.0.0.1:1/none", key: "x"),
            Destination(name: "Dead SRT", proto: .srt, url: "srt://127.0.0.1:1?streamid=x"),
        ]
        ensureAudioMixerStarted()                 // master-mix tap → program audio fan-out
        // A bare mixer channel gives the master bus an active input node, so the
        // engine pulls the graph and the master tap fires (silence) — exercising
        // the REAL onMasterMix → fanOut.handle(audio:) → broadcast(audio:) path
        // headlessly, camera/mic-free. (In normal use a mic/app-audio source does
        // this; here nothing is captured.)
        _ = try? audioMixer.addChannel(id: SourceID("debug-audio-probe"))
        startStreamInternal(url: "", streamKey: "") // destinations-only (no single-RTMP primary)
    }

    /// Build a program render loop over a fresh `MetalCompositor` in the given
    /// color mode, wiring the program-frame fan-out (preview / recorder / stream)
    /// and the vertical (9:16) dual-program feed. Returns nil if Metal is
    /// unavailable. Used at launch (`.sdr`) and by `setHDREnabled` (rebuild).
    /// Does NOT start the loop or register mailboxes — the caller does both.
    private func buildRenderLoop(colorMode: MetalCompositor.ColorMode) -> RenderLoop? {
        guard let device = metalDevice,
              let compositor = try? MetalCompositor(device: device,
                                                    width: Self.canvasSize.width,
                                                    height: Self.canvasSize.height,
                                                    colorMode: colorMode) else { return nil }
        let loop = RenderLoop(compositor: compositor, fps: 60)
        // Phase 1d: attach the shared perf aggregator so this loop's ticks, its
        // compositor's GPU spans, and its mailboxes' drop/depth counters all land
        // in one place that `EngineControlBackend.stats()` reads. Persist it on the
        // engine (survives an HDR rebuild that swaps the loop) and (re)start the
        // light memory/CPU sampler.
        loop.metrics = renderMetrics
        startPerfSampler()
        loop.scene = scene
        // Feed 9:16 the exact deadline-qualified frames the primary consumed,
        // paired with the provider scene/reframe evaluated during that same tick.
        // Non-blocking + coalescing on the secondary's own queue/compositor.
        loop.onTickSnapshot = { [dualProgram, verticalTap] tick in
            if let dualProgram, verticalTap.enabled {
                let routing = verticalTap.routingSnapshot()
                let reframe = tick.evaluatedScene.map { evaluated -> ReframeMap in
                    let restingIDs = Set(tick.restingScene.layers.map(\.sourceID))
                    // `uniquingKeysWith` (never `uniqueKeysWithValues`, which TRAPS
                    // on a duplicate key): defensively survive two evaluated layers
                    // sharing a sourceID — keep the frontmost (last) — rather than
                    // crash the render tick (belt with MemeDirector's dedupe).
                    let transientFrames = Dictionary(
                        evaluated.layers
                            .filter { !restingIDs.contains($0.sourceID) }
                            .map { ($0.sourceID, $0.frame) },
                        uniquingKeysWith: { _, latest in latest })
                    return AppEngine.verticalReframeMap(
                        evaluatedScene: evaluated,
                        restingScene: tick.restingScene,
                        mode: routing.mode,
                        pinnedHero: routing.pinnedHero,
                        auxiliaryFrames: transientFrames)
                }
                verticalTap.updateExactTick(frames: tick.frames,
                                            scene: tick.evaluatedScene,
                                            reframe: reframe)
                dualProgram.submit(frames: tick.frames,
                                   scene: tick.evaluatedScene,
                                   reframe: reframe,
                                   pts: tick.pts, duration: tick.duration)
            }
        }
        // F5: advance time-varying per-source effects on the render tick, at the
        // one tick PTS, against each source's held raw frame. Reinstalled on the
        // new loop after an HDR rebuild (the driver + registrations persist).
        loop.frameProcessor = { [animatedFXDriver] frames, pts in
            animatedFXDriver.process(frames, pts: pts)
        }
        loop.onProgramFrame = { [fanOut, monitor = linkDebugMonitor] frame in
            fanOut.handle(frame)
            monitor?.observeProgram(frame)
        }
        return loop
    }

    /// Orderly teardown (C23): awaited by AppDelegate.applicationShouldTerminate
    /// before the process is allowed to exit. Finalizes an in-progress
    /// recording (await finish() → playable file) before stopping the engine.
    private var didShutdown = false

    /// The render loop a fail-safe HDR resume chain is currently retrying (sol #4).
    /// Coalesces duplicate chains: two overlapping failed-quiesce attempts both call
    /// `resumeRenderLoopAfterFailedQuiesce(old)` for the SAME loop, and without this a
    /// second chain would keep retrying forever after the first recovered the loop
    /// (its `start()` then fails BECAUSE the loop is already running). Exactly one
    /// chain runs per loop; cleared on every terminal branch.
    private var resumeRetryLoop: RenderLoop?

    /// Synchronous cutout barrier shared by shutdown and the App integration
    /// test. `PresenterCutoutSource.stop()` drains its Vision worker, so no
    /// captured frame sink can touch taps/mailboxes/pipelines after this returns.
    static func stopAndClearCutouts(
        sources: inout [SourceID: PresenterCutoutSource],
        states: inout [SourceID: CutoutState]
    ) {
        for source in sources.values { source.stop() }
        sources.removeAll()
        states.removeAll()
    }

    func shutdown() async {
        guard !didShutdown else { return }
        didShutdown = true
        log.info("shutdown: begin (recording=\(self.isRecording))")
        // Supersede EVERY in-flight meme frame-zero cue so its background closure can
        // neither restart a source nor install a provider after teardown.
        invalidateAllCueGenerations()
        invalidatePendingStingerCue(drain: true)
        activeStingerSourceID = nil
        activeStingerToken = nil
        verticalTap.clearProgramOverride()
        // F7: stop + synchronously drain every Vision wrapper BEFORE detaching
        // taps or tearing down a captured SourceEffectPipeline. The didShutdown
        // fence prevents actor reentrancy during later awaits from reinstalling
        // a wrapper after this barrier.
        Self.stopAndClearCutouts(sources: &cutoutSources, states: &cutoutStates)
        linkDebugTimer?.invalidate()
        animationClearTimer?.invalidate()
        renderLoop?.sceneProvider = nil
        meterTimer?.invalidate()
        streamStatsTimer?.invalidate()
        broadcastStatsTimer?.invalidate()
        streamStateTask?.cancel()
        streamConnectTask?.cancel()
        isoStatusTimer?.invalidate()
        replayStatusTimer?.invalidate()
        // Integrations: stop MIDI input, auto-director, and BLE discovery.
        directorAudioInjectTimer?.invalidate()
        directorTap.install(nil)
        director?.setEnabled(false)
        controlSurface?.stop()
        // Stop unconditionally: proximityDiscovering may be false while a scan is
        // still pending a delayed .poweredOn (Codex C2).
        proximityController.stopDiscovery()
        await stopRecording() // no-op when idle; finalizes MovieRecorder + ISO bank when recording
        // Flagship: flush any deferred post-roll captures BEFORE the replay ring is
        // torn down — the show ended before their post-roll elapsed, so save the
        // available window rather than losing the candidate.
        flushPendingHighlightCaptures()
        if replayArmed { setReplayArmed(false) }
        if isStreaming { stopStream() }
        // Sound / music engines + meme media sources (each owns hardware/queues).
        memeClearTimer?.invalidate()
        armedStingerMemeID = nil
        soundboard?.stop(); beatSequencer?.stop(); musicBed?.stop()
        for (id, registration) in auxiliarySources {
            registration.source.stop()
            // Symmetric with removeMeme: drop the mailbox + un-pin the retained
            // IOSurface. Redundant with the `renderLoop?.stop()` below (full
            // teardown discards the loop), but kept for consistency.
            renderLoop?.removeMailbox(for: id)
            verticalTap.forget(id)
            dualProgram?.forget(source: id)
        }
        auxiliarySources.removeAll()
        for url in memeScopedURLs.values { url.stopAccessingSecurityScopedResource() }
        memeScopedURLs.removeAll()
        // sol #4: release ALL cue-generation keys (the bump above already superseded any
        // in-flight cue; the didShutdown fence stops the rest on their main hop) so the
        // dict does not survive as a leaked monotonic key set.
        cueGenerations.withLock { $0.removeAll() }
        if audioMixerStarted { audioMixer.stop() }
        // Stop every active source and tear down its effect pipeline (W13):
        // releases capture devices, segmenters, and per-source Metal processors
        // deterministically instead of leaning on process exit to reclaim them.
        for source in activeSources {
            switch source.backing {
            case .camera(let camera): camera.stop()
            case .microphone(let mic): mic.stop()
            case .screen(let screen): screen.stop()
            case .link(let video, _): video.stop()
            case .systemAudio(let audio): audio.stop()
            case .generated(let video): video.stop()
            case .movie(let movie): movie.stop()
            }
        }
        // sol #8 #1: pending screen replacements live in a side dictionary (not in
        // `activeSources`); a still-resolving replacement would keep capturing + posting
        // after shutdown. Retire every gate, stop every pending source, clear the dict.
        drainAllPendingScreenReplacements()
        // sol #9 #1: retire every COMMITTED replacement gate too (a committed screen source
        // owns a gate that the plain `stop()` above can't atomically silence).
        for gate in committedScreenGates.values { gate.retire() }
        committedScreenGates.removeAll()
        committedScreenGeneration.removeAll()   // sol #12 #2
        screenReplacementGeneration.removeAll()
        for id in effectPipelines.keys { animatedFXDriver.unregister(id) }
        for pipeline in effectPipelines.values { pipeline.teardown() }
        effectPipelines.removeAll()
        activeSources.removeAll()
        renderLoop?.stop()
        feeder.stop()
        linkServer.stop()
        if controlServerRunning { controlServer.stop() }
        // Codex #4: fence the control tier. Detach the obs backend and clear the
        // App-Intent handle so any StartRecord/StartStream/App Intent that raced
        // the `await stopRecording()` suspension finds no engine and no-ops
        // cleanly (the automation-reachable mutators also early-return on
        // didShutdown above, so a request that captured the ref before this still
        // can't attach a new output).
        controlBackend.engine = nil
        Self.current = nil
        log.info("shutdown: complete")
    }

    // MARK: Device discovery

    private func refreshDevices() {
        cameras = deviceManager.videoDevices()
        microphones = deviceManager.audioDevices()
        // Drop active sources whose hardware went away.
        let known = Set((cameras + microphones).map(\.id))
        for source in activeSources {
            switch source.backing {
            case .camera, .microphone:
                if !known.contains(source.id.raw) { removeSource(source.id) }
            default:
                break
            }
        }
    }

    // MARK: Link server (OPT-IN; peers appear in the sidebar once enabled)

    /// Enable/disable peer-connect (PrismLink). This is the ONLY path that
    /// starts the Link server — and therefore the only path that creates the
    /// TLS identity (keychain) and advertises over Bonjour.
    ///
    /// Enabling starts the QUIC listener, generates the ephemeral identity, and
    /// advertises over Bonjour. Disabling calls `linkServer.stop()`, which tears
    /// down the listener and (per its docs, A8) removes the ephemeral identity
    /// it created. Idempotent in both directions: enabling while already enabled
    /// (or disabling while already off) is a no-op — it never double-starts.
    func setLinkEnabled(_ enabled: Bool) {
        guard enabled != linkEnabled else { return } // idempotent both ways
        linkEnabled = enabled
        if enabled {
            linkListenerState = "starting"
            startLinkServer()
        } else {
            linkServer.stop()
            linkDebugTimer?.invalidate()
            linkDebugTimer = nil
            linkPort = nil
            linkListenerState = "off"
            peers.removeAll()   // listener torn down; no live peers remain
            writeLinkDebugState()
        }
    }

    private func startLinkServer() {
        // Re-enable safety: a prior enable/disable cycle may have armed the
        // debug timer; never stack timers across restarts.
        linkDebugTimer?.invalidate()
        linkDebugTimer = nil
        // Both callbacks fire on the link server's queue — the only context
        // where LinkPeer.state/hello may be read (C24). Snapshot there, then
        // hop the Sendable snapshot to the main actor.
        linkServer.onPeerConnected = { [weak self] peer in
            // Install onStateChange here (still on the link queue) so the
            // handler itself also snapshots on the link queue.
            peer.onStateChange = { [weak self, weak peer] _ in
                guard let peer else { return }
                let snapshot = PeerSnapshot(readingOnLinkQueue: peer)
                let id = peer.id
                DispatchQueue.main.async { self?.peerStateChanged(id, snapshot) }
            }
            let snapshot = PeerSnapshot(readingOnLinkQueue: peer)
            DispatchQueue.main.async { self?.peerConnected(peer, snapshot) }
        }
        linkServer.onPeerDisconnected = { [weak self] peer in
            let id = peer.id
            DispatchQueue.main.async { self?.peerDisconnected(id) }
        }
        linkServer.onListenerStateChange = { [weak self] state, port in
            let describe: String
            switch state {
            case .ready: describe = "ready"
            case .waiting(let error): describe = "waiting: \(error)"
            case .failed(let error): describe = "failed: \(error)"
            case .cancelled: describe = "cancelled"
            default: describe = String(describing: state)
            }
            DispatchQueue.main.async {
                self?.linkPort = port
                self?.linkListenerState = describe
                self?.writeLinkDebugState()
            }
        }
        do { try linkServer.start() }
        catch { lastError = "Link server failed to start: \(error.localizedDescription)" }

        // Debug-observability only: refresh the state file every second so a
        // CLI test can watch per-peer media counters advance (see
        // writeLinkDebugState). Not armed unless the env var is set.
        if ProcessInfo.processInfo.environment["PRISM_LINK_STATE_FILE"] != nil {
            linkDebugTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                DispatchQueue.main.async { [weak self] in self?.writeLinkDebugState() }
            }
        }
    }

    private var linkDebugTimer: Timer?

    private func peerConnected(_ peer: LinkPeer, _ snapshot: PeerSnapshot) {
        guard !peers.contains(where: { $0.id == peer.id }) else { return }
        let entry = PeerEntry(peer: peer, snapshot: snapshot)
        peers.append(entry)
        if autoAddPeers { addPeer(entry) } // debug loopback path (see property doc)
        writeLinkDebugState()
    }

    /// Main actor: adopt a fresh snapshot taken on the link queue (C24).
    /// Mutating the @Published array publishes the change (hello → name updates).
    private func peerStateChanged(_ id: SourceID, _ snapshot: PeerSnapshot) {
        if let index = peers.firstIndex(where: { $0.id == id }) {
            peers[index].snapshot = snapshot
        }
        writeLinkDebugState()
    }

    private func peerDisconnected(_ id: SourceID) {
        peers.removeAll { $0.id == id }
        if activeSources.contains(where: { $0.id == id }) {
            removeSource(id)
        }
        writeLinkDebugState()
    }

    /// Runtime-verification hook: when the PRISM_LINK_STATE_FILE environment
    /// variable names a path, mirror the link state there as JSON on every
    /// change (listener port, peers, per-peer media counters). Lets a CLI
    /// test observe "the server accepted my hello / my frames arrived"
    /// without UI scraping. No-op in normal use.
    private func writeLinkDebugState() {
        guard let path = ProcessInfo.processInfo.environment["PRISM_LINK_STATE_FILE"],
              !path.isEmpty else { return }
        let peerDicts: [[String: Any]] = peers.map { entry in
            // mediaStats is internally synchronized (queue.sync onto the link
            // queue) — safe here. state/name come from the snapshot (C24);
            // never read entry.peer.state/hello on the main actor.
            let media = entry.peer.mediaStats
            return [
                "id": entry.id.raw,
                "name": entry.name,
                "state": entry.snapshot.stateDescription,
                "framesCompleted": media.framesCompleted,
                "partsReceived": media.partsReceived,
                "bytesReceived": media.bytesReceived,
                "framesDropped": media.framesDropped,
            ]
        }
        var state: [String: Any] = [
            "port": linkPort ?? 0,
            "listenerState": linkListenerState,
            "advertising": linkAdvertising,
            "pairingCode": pairingCode,
            "peerCount": peers.count,
            "peers": peerDicts,
            "updatedAt": Date().timeIntervalSince1970,
            // Wave-2 observability (deliverable 5): stream + mixer + effects.
            "streamState": streamStateDescription,
            "isStreaming": isStreaming,
            "streamBitrate": streamBitrate,
            "streamDroppedAppends": NSNumber(value: streamDroppedAppends),
            // Multi-destination restream (deliverable B): counters prove the
            // broadcaster is fed BOTH program video and program audio, and how
            // many destinations went live.
            "destinationsCount": destinations.count,
            "destinationsConfigured": broadcastDestinationsConfigured,
            "broadcastVideoFrames": NSNumber(value: broadcastVideoFrames),
            "broadcastAudioFrames": NSNumber(value: broadcastAudioFrames),
            "mixerMasterLevel": mixerMasterLevel,
            "loudnessMomentary": masterLoudness.momentary.isFinite ? masterLoudness.momentary : "-inf",
            "loudnessShortTerm": masterLoudness.shortTerm.isFinite ? masterLoudness.shortTerm : "-inf",
            "loudnessIntegrated": masterLoudness.integrated.isFinite ? masterLoudness.integrated : "-inf",
            "loudnessTruePeak": masterLoudness.truePeak.isFinite ? masterLoudness.truePeak : "-inf",
            "activeEffectsCount": activeEffectsCount,
            // Deliverable 2: how many installed AU effects the insert picker sees
            // (proof availableAudioEffects() returns a real list at launch).
            "availableAudioEffectsCount": audioEffectCatalog.count,
            // Scene layers with their compositor alpha flag — proof the Codex C1
            // premultipliedAlpha fix flips when a chroma key / background-remove
            // is enabled (keyed/segmented sources composite transparent, not black).
            "layers": scene.layers
                .sorted { $0.zIndex < $1.zIndex }
                .map { layer -> [String: Any] in
                    [
                        "sourceID": layer.sourceID.raw,
                        "zIndex": layer.zIndex,
                        "premultipliedAlpha": layer.premultipliedAlpha,
                        "hidden": layer.isHidden,
                    ]
                },
            // Wave-3 observability: replay + ISO + export.
            "replayArmed": replayArmed,
            "replayBufferedSeconds": replayBufferedSeconds,
            "isoArmedCount": isoArmedSourceIDs.count,
            "isoRecordingCount": isoBank?.activeSourceIDs.count ?? 0,
            "multicamExportable": lastMulticamExportable,
            // v2 observability: scene collections + layer animation.
            "sceneCollectionsCount": sceneCollections.count,
            "animating": animatingSourceID != nil,
            "animatingSourceID": animatingSourceID?.raw ?? "none",
            "selectedPreset": selectedPreset.rawValue,
            // Integrations observability: MIDI control surface, auto-director, HDR,
            // BLE proximity.
            "controlSurfaceEnabled": controlSurfaceEnabled,
            "surfaceActionCount": surfaceActionCount,
            "surfaceLastAction": surfaceLastAction ?? "none",
            "surfaceConnectedSources": controlSurface?.connectedSourceCount ?? 0,
            "autoDirectorEnabled": autoDirectorEnabled,
            "directorDecisionCount": directorDecisionCount,
            "directorActiveSource": directorActiveSourceID?.raw ?? "none",
            "debugSignalCount": debugSignalCount,
            "debugLastActivity": debugLastActivity,
            "hdrEnabled": hdrEnabled,
            "compositorColorMode": hdrEnabled ? "hdr" : "sdr",
            "proximityDiscovering": proximityDiscovering,
            "proximityCandidateCount": proximityCandidates.count,
        ]
        if let ok = lastCollectionRoundTripOK { state["collectionRoundTripOK"] = ok }
        // Preflight Broadcast Check (deliverable 2) results, when one has run.
        if let report = lastBroadcastReport {
            state["broadcastCheckOverall"] = report.overall.rawValue
            state["broadcastChecks"] = report.results.map {
                ["id": $0.id, "status": $0.status.rawValue, "message": $0.message]
            }
        }
        // Program-output evidence: proves frames RENDER, not just decode.
        if let stats = renderLoop?.stats {
            state["programFramesDelivered"] = NSNumber(value: stats.framesDelivered)
            state["programTicks"] = NSNumber(value: stats.ticks)
            state["programCompositeErrors"] = NSNumber(value: stats.compositeErrors)
        }
        // Dual-program (vertical 9:16) evidence: the SECOND composite's counters.
        state["verticalProgramEnabled"] = verticalProgramEnabled
        state["verticalReframeMode"] = verticalReframeMode.rawValue
        if let dstats = dualProgram?.stats {
            state["verticalFramesProduced"] = NSNumber(value: dstats.rendered)
            state["verticalFramesSubmitted"] = NSNumber(value: dstats.submitted)
            state["verticalFramesCoalesced"] = NSNumber(value: dstats.coalesced)
            state["verticalCompositeErrors"] = NSNumber(value: dstats.errors)
        }
        if let monitor = linkDebugMonitor {
            let snap = monitor.snapshot()
            state["sources"] = activeSources.filter(\.isVideo).map { active -> [String: Any] in
                [
                    "id": active.id.raw,
                    "kind": active.descriptor.kind.rawValue,
                    "name": active.descriptor.name,
                    "lastFramePTS": snap.sources[active.id.raw] ?? 0,
                ]
            }
            state["programFingerprint"] = snap.fingerprint ?? "none"
            state["programFingerprintPTS"] = snap.fingerprintPTS
            state["programFingerprintCount"] = NSNumber(value: snap.fingerprintCount)
        }
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    // MARK: Add / remove sources

    func isActive(_ id: SourceID) -> Bool {
        activeSources.contains { $0.id == id }
    }

    func addCamera(_ descriptor: SourceDescriptor) {
        guard !isActive(SourceID(descriptor.id)) else { return }
        do {
            let source = try CameraSource(deviceID: descriptor.id)
            let mailbox = FrameMailbox()
            let pipeline = makeEffectPipeline(for: source.id)
            source.onFrame = { [mailbox, monitor = linkDebugMonitor, pipeline, isoTap, verticalTap, directorTap, sid = source.id] frame in
                Self.deliverSourceFrame(frame, pipeline: pipeline, monitor: monitor,
                                        isoTap: isoTap, verticalTap: verticalTap,
                                        directorTap: directorTap, sid: sid, mailbox: mailbox)
            }
            do {
                try source.start()
            } catch {
                discardEffectPipeline(source.id) // W12: don't leave a stale entry
                throw error
            }
            register(ActiveSource(id: source.id, descriptor: descriptor,
                                  backing: .camera(source), mailbox: mailbox))
        } catch {
            lastError = "Couldn't add \(descriptor.name): \(error.localizedDescription)"
        }
    }

    /// Roll back the per-source effect state a failed video-source add left
    /// behind (`makeEffectPipeline` registers before the source starts). Keeps
    /// `effectPipelines` / `sourceEffects` free of dead entries so a retry, or
    /// the debug/state mirror, never sees a source that isn't active (W12).
    private func discardEffectPipeline(_ id: SourceID) {
        animatedFXDriver.unregister(id)
        effectPipelines[id]?.teardown()
        effectPipelines[id] = nil
        sourceEffects[id] = nil
    }

    func addMicrophone(_ descriptor: SourceDescriptor) {
        guard !isActive(SourceID(descriptor.id)) else { return }
        do {
            let source = try MicrophoneSource(deviceID: descriptor.id)
            // Route through a mixer channel → master mix → fan-out (recorder +
            // stream), replacing the old direct mic→recorder path.
            ensureAudioMixerStarted()
            let channel = try audioMixer.addChannel(id: source.id)
            source.onAudio = { [multitrackTap] packet in
                channel.ingest(packet)
                multitrackTap.append(packet) // no-op unless a multitrack session is live
            }
            do {
                try source.start()
            } catch {
                // start() threw AFTER the mixer channel was registered — remove
                // it (and any partial state) so a retry doesn't hit "channel
                // already exists" and no MixerChannel/AVAudioNode leaks (W3).
                audioMixer.removeChannel(id: source.id)
                throw error
            }
            register(ActiveSource(id: source.id, descriptor: descriptor,
                                  backing: .microphone(source), mailbox: nil))
        } catch {
            lastError = "Couldn't add \(descriptor.name): \(error.localizedDescription)"
        }
    }

    /// Add a screen / window / application source. When `captureAudio` is true
    /// (the default for app/window capture, where the app's audio is the point)
    /// the source's app audio is routed into its OWN mixer channel — so it shows
    /// in the mixer with gain/mute/solo + meter and is folded into the master mix
    /// that feeds the recorder + stream (deliverable A). TCC: the audio rides the
    /// same Screen-Recording grant as the video; no extra prompt.
    func addScreen(_ descriptor: SourceDescriptor, captureAudio: Bool = true) {
        let sid = SourceID(descriptor.id)
        guard !isActive(sid) else { return }
        do {
            // sol #5 #3: request the 10-bit HDR capture path when the show is HDR —
            // pre-fix the App always built a default (preferHDR=false) config, so a
            // screen source stayed 8-bit SDR even in an HDR show and toggling HDR never
            // reached ScreenCaptureKit's dynamic range.
            let config = Self.screenCaptureConfiguration(captureAudio: captureAudio, hdr: hdrEnabled)
            let source = try ScreenSource(descriptor: descriptor, configuration: config)
            let mailbox = FrameMailbox()
            _ = makeEffectPipeline(for: source.id)
            // sol #10 #1: the ORIGINAL/active screen source is gated exactly like a hot-swap
            // replacement (LIVE from the start), so removeSource / shutdown / the first-HDR
            // commit can retire it and no post-teardown frame/audio ever reaches the shared
            // pipeline / mixer channel. The gate is registered in `committedScreenGates` so
            // every retirement path finds it.
            let gate = ScreenReplacementGate()   // original starts LIVE
            #if DEBUG
            let cbGate: ScreenReplacementGate? = Self._test_skipOriginalScreenGate ? nil : gate
            #else
            let cbGate: ScreenReplacementGate? = gate
            #endif
            source.onFrame = makeGatedScreenFrameCallback(id: source.id, mailbox: mailbox, gate: cbGate)
            // App/system audio → its own mixer channel → master mix → fan-out
            // (recorder + stream), exactly like a microphone. Registered before
            // start() so no packet is dropped; rolled back if start() throws.
            if captureAudio {
                ensureAudioMixerStarted()
                let channel = try audioMixer.addChannel(id: source.id)
                source.onAudio = makeGatedScreenAudioCallback(id: source.id, channel: channel, gate: cbGate)
            }
            #if DEBUG
            if !Self._test_skipOriginalScreenGate { committedScreenGates[source.id] = gate }
            #else
            committedScreenGates[source.id] = gate
            #endif
            source.onError = { [weak self, weak source] error in
                DispatchQueue.main.async {
                    guard let self, let source else { return }
                    // C27: ignore errors from a superseded instance. After
                    // remove + re-add of the same descriptor.id, a late
                    // onError from the OLD instance must not tear down the
                    // NEW one — act only if this exact instance is still the
                    // registered backing for the id.
                    let id = SourceID(descriptor.id)
                    guard let active = self.activeSources.first(where: { $0.id == id }),
                          case .screen(let current) = active.backing,
                          current === source else { return }
                    self.lastError = "Screen capture stopped: \(error.localizedDescription)"
                    self.removeSource(id)
                }
            }
            do {
                try source.start()
            } catch {
                discardEffectPipeline(source.id) // W12: don't leave a stale entry
                if captureAudio { audioMixer.removeChannel(id: source.id) } // W3: no orphan channel
                committedScreenGates[source.id] = nil // no orphan gate for an un-registered source
                throw error
            }
            register(ActiveSource(id: source.id, descriptor: descriptor,
                                  backing: .screen(source), mailbox: mailbox))
        } catch {
            lastError = "Couldn't add \(descriptor.name): \(error.localizedDescription)"
        }
    }

    /// Build a screen-capture configuration for the current show (sol #5 #3). Pure /
    /// unit-testable: `hdr` maps straight to `preferHDR`, so the HDR-request decision
    /// is verifiable without a live capture (which would trip the Screen Recording TCC
    /// prompt).
    static func screenCaptureConfiguration(captureAudio: Bool, hdr: Bool) -> ScreenCaptureConfiguration {
        var config = ScreenCaptureConfiguration()
        config.capturesAudio = captureAudio
        config.preferHDR = hdr
        return config
    }

    // MARK: - Generated sources (deliverable 1: text / image / browser)

    /// Canvas size for generated sources — the program raster, so a full-frame
    /// title/still lands 1:1 in the compositor.
    private static var sourceCanvas: CanvasSize {
        CanvasSize(width: canvasSize.width, height: canvasSize.height)
    }

    /// Wire a freshly-created generated `VideoSource` into the scene exactly like
    /// a camera: per-source effect pipeline → ISO tap → mailbox → new layer.
    private func registerGenerated(_ source: VideoSource, descriptor: SourceDescriptor,
                                   characterLayer: Bool = false) throws {
        let mailbox = FrameMailbox()
        let pipeline = makeEffectPipeline(for: source.id)
        source.onFrame = { [mailbox, monitor = linkDebugMonitor, pipeline, isoTap, verticalTap, directorTap, sid = source.id] frame in
            Self.deliverSourceFrame(frame, pipeline: pipeline, monitor: monitor,
                                    isoTap: isoTap, verticalTap: verticalTap,
                                    directorTap: directorTap, sid: sid, mailbox: mailbox)
        }
        do {
            try source.start()
        } catch {
            discardEffectPipeline(source.id) // makeEffectPipeline registered state; roll back (W12)
            throw error
        }
        register(ActiveSource(id: source.id, descriptor: descriptor,
                              backing: .generated(source), mailbox: mailbox),
                 characterLayer: characterLayer)
    }

    /// Add a styled text/title source (SF font, live `{time}`/`{counter}` tokens).
    func addTextSource(text: String, fontSize: Double = 96, color: RGBAColor = .white) {
        let style = TextSource.Style(fontSize: fontSize, weight: .semibold, color: color,
                                     horizontalAlignment: .center, verticalAlignment: .center)
        do {
            let source = try TextSource(text: text, style: style, canvasSize: Self.sourceCanvas)
            let descriptor = SourceDescriptor(kind: .virtual, id: source.id.raw,
                                              name: text.isEmpty ? "Text" : text)
            try registerGenerated(source, descriptor: descriptor)
        } catch {
            lastError = "Couldn't add text source: \(error.localizedDescription)"
        }
    }

    /// Add a still-image source (BRB screen, logo, bumper).
    func addImageSource(fileURL: URL) {
        do {
            let source = try ImageSource(fileURL: fileURL, canvasSize: Self.sourceCanvas,
                                         contentMode: .aspectFit)
            let descriptor = SourceDescriptor(kind: .media, id: source.id.raw,
                                              name: fileURL.deletingPathExtension().lastPathComponent)
            // Source persistence: capture the file BEFORE register() appends (the
            // append triggers the save, which reads this table).
            registerPersistableSourceFile(id: source.id, url: fileURL, isMovie: false, loop: nil)
            try registerGenerated(source, descriptor: descriptor)
        } catch {
            lastError = "Couldn't add image \(fileURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Add an animated-GIF source (motion meme / reaction loop). Decoded fully at
    /// init (all frames preloaded), so — like an image — the security-scoped grant
    /// can be released as soon as this returns. Registered as a GENERATED source so
    /// its layer is premultiplied-alpha: a transparent GIF composites over the
    /// layers beneath without an opaque box. Missing/undecodable → `lastError`.
    /// Returns the new source's id on success, `nil` on failure (sol #6 #10: the
    /// rollback re-admit binds restored victim state to the ACTUAL re-admitted id
    /// from this result — never a stale `lastAddedVideoSourceID`).
    @discardableResult
    func addGIFSource(fileURL: URL) -> SourceID? {
        // F15 / Class F: an ORDINARY (non-meme) GIF counts against the SAME
        // app-wide animated-media budget as memes — otherwise N scene GIFs are
        // unbounded. Estimate + admit BEFORE decoding (reject over-budget without a
        // decode); a fitting one may evict the oldest animated sources.
        let cost = AnimatedGIFSource.estimatedResidentBytes(url: fileURL,
                                                            canvasSize: Self.sourceCanvas,
                                                            contentMode: .aspectFit)
        // sol #4: reject an over-budget GIF without decoding; a fitting one evicts the
        // oldest animated sources BEFORE decoding (peak ceiling), with a rollback that
        // re-admits them if this GIF's decode fails (no destructive loss).
        let plan = planAnimatedAdmission(cost: cost)
        guard plan.admit else {
            lastError = "GIF \(fileURL.lastPathComponent) exceeds the animated-media budget."
            return nil
        }
        let readmits = captureAnimatedVictimSnapshots(plan.evict)
        #if DEBUG
        if !Self._test_evictAfterConstruct { commitAnimatedEviction(plan.evict) }
        Self._test_beforeAnimatedDecodeHook?()   // observe: victims already evicted, pre-decode
        #else
        commitAnimatedEviction(plan.evict)
        #endif
        do {
            #if DEBUG
            try Self._test_throwIfForcedConstructionFailure()
            #endif
            let source = try AnimatedGIFSource(fileURL: fileURL, canvasSize: Self.sourceCanvas,
                                               contentMode: .aspectFit, loop: true)
            let descriptor = SourceDescriptor(kind: .media, id: source.id.raw,
                                              name: fileURL.deletingPathExtension().lastPathComponent)
            try registerGenerated(source, descriptor: descriptor)
            #if DEBUG
            if Self._test_evictAfterConstruct { commitAnimatedEviction(plan.evict) }  // NEGATIVE CONTROL: peak overshoot
            #endif
            animatedGIFSourceURLs[source.id] = fileURL   // sol #4: enable rollback re-admit
            trackAnimatedSource(source.id, cost: cost)   // aggregate budget accounting
            return source.id
        } catch {
            rollbackAnimatedEviction(readmits)           // sol #4: re-admit the evicted victims
            lastError = "Couldn't add GIF \(fileURL.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    /// Add a browser source (WKWebView → layer capture) for a URL.
    func addBrowserSource(urlString: String) {
        guard let url = URL(string: urlString), url.scheme != nil else {
            lastError = "Enter a full URL (including http:// or https://)."
            return
        }
        do {
            let source = try BrowserSource(content: .url(url), canvasSize: Self.sourceCanvas)
            let descriptor = SourceDescriptor(kind: .virtual, id: source.id.raw,
                                              name: url.host ?? "Browser", detail: url.absoluteString)
            try registerGenerated(source, descriptor: descriptor)
        } catch {
            lastError = "Couldn't add browser source: \(error.localizedDescription)"
        }
    }

    /// Add a video-FILE source (a downloaded clip) — decoded, real-time-paced,
    /// looping by default, and usable exactly like a camera in the scene / record
    /// / stream graph. If the file has a soundtrack it is routed into its OWN mixer
    /// channel (folded into the master mix). A missing/undecodable file surfaces
    /// via `lastError` — never a crash.
    func addMovieSource(fileURL: URL, loop: Bool = true) {
        // Unlike ImageSource (which caches its frame synchronously so the scope can
        // be released immediately), MovieSource streams from disk for its whole
        // lifetime. In a sandboxed build the security-scoped grant must therefore be
        // HELD until the source is removed — balanced in removeSource / addMovieSource
        // error path. Harmless no-op when the app is not sandboxed (Debug).
        let scoped = fileURL.startAccessingSecurityScopedResource()
        do {
            let source = try MovieSource(fileURL: fileURL, canvasSize: Self.sourceCanvas,
                                         contentMode: .aspectFit, loop: loop)
            let descriptor = SourceDescriptor(kind: .media, id: source.id.raw,
                                              name: fileURL.deletingPathExtension().lastPathComponent)
            // Source persistence: capture the file (+loop) BEFORE register() appends.
            registerPersistableSourceFile(id: source.id, url: fileURL, isMovie: true, loop: loop)
            try registerMovie(source, descriptor: descriptor,
                              fileURL: fileURL, loop: loop, scoped: scoped)
        } catch {
            if scoped { fileURL.stopAccessingSecurityScopedResource() }
            lastError = "Couldn't add video \(fileURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Wire a `MovieSource` into the scene like a camera (effect pipeline → taps →
    /// mailbox → new layer) AND route its optional soundtrack into a mixer channel
    /// → master mix → fan-out (recorder + stream). Rolls back cleanly if `start()`
    /// throws.
    private func registerMovie(_ source: MovieSource, descriptor: SourceDescriptor,
                               fileURL: URL, loop: Bool, scoped: Bool) throws {
        let mailbox = FrameMailbox()
        let pipeline = makeEffectPipeline(for: source.id)
        source.onFrame = { [mailbox, monitor = linkDebugMonitor, pipeline, isoTap, verticalTap, directorTap, sid = source.id] frame in
            Self.deliverSourceFrame(frame, pipeline: pipeline, monitor: monitor,
                                    isoTap: isoTap, verticalTap: verticalTap,
                                    directorTap: directorTap, sid: sid, mailbox: mailbox)
        }
        // Clip soundtrack → its own mixer channel (gain/mute/solo + meter), exactly
        // like a mic / app-audio source. Wired before start() so no packet is
        // dropped; rolled back if start() throws.
        var addedChannel = false
        if source.hasAudioTrack {
            ensureAudioMixerStarted()
            let channel = try audioMixer.addChannel(id: source.id)
            addedChannel = true
            source.onAudio = { [multitrackTap] packet in
                channel.ingest(packet)
                multitrackTap.append(packet) // no-op unless a multitrack session is live
            }
        }
        do {
            try source.start()
        } catch {
            discardEffectPipeline(source.id)          // W12: no stale effect entry
            if addedChannel { audioMixer.removeChannel(id: source.id) } // W3: no orphan channel
            throw error
        }
        movieSources[source.id] = MovieEntry(source: source, fileURL: fileURL,
                                             loop: loop, scoped: scoped)
        register(ActiveSource(id: source.id, descriptor: descriptor,
                              backing: .movie(source), mailbox: mailbox))
    }

    // MARK: Movie source inspector + live config

    func isMovieSource(_ id: SourceID) -> Bool { movieSources[id] != nil }
    /// The clip's native (display-oriented) pixel size, for the inspector label.
    func movieNativeSize(for id: SourceID) -> CGSize? { movieSources[id]?.source.nativeSize }
    /// Whether the movie source is currently set to loop (drives the toggle).
    func movieLoops(_ id: SourceID) -> Bool { movieSources[id]?.loop ?? true }
    /// Whether the clip carries a soundtrack routed into the mixer.
    func movieHasAudio(_ id: SourceID) -> Bool { movieSources[id]?.source.hasAudioTrack ?? false }

    /// Change a movie source's loop behavior. `loop` is fixed at `MovieSource`
    /// init, so this rebuilds the decoder IN PLACE — reusing the same SourceID,
    /// mailbox, effect pipeline, scene layer, and (if present) mixer channel —
    /// swapping only the backing decoder, so the layer never leaves the scene.
    func setMovieLoop(_ loop: Bool, for id: SourceID) {
        guard let entry = movieSources[id], entry.loop != loop,
              let index = activeSources.firstIndex(where: { $0.id == id }),
              case .movie = activeSources[index].backing,
              let mailbox = activeSources[index].mailbox else { return }
        // sol #12 #2 (finding #5): if a presenter cutout is enabled for this movie, the fresh
        // `MovieSource` MUST be rebuilt INSIDE the cutout wrapper — otherwise the new raw movie's
        // frames bypass the still-"on" cutout (the UI says on, the premultiplied layer + stale
        // wrapper stay enabled, but live frames route straight to the mailbox). Reuse the
        // cutout-rebuild path: record the new loop in the entry, then delegate to
        // `setPresenterCutout`, which rebuilds the movie (from the entry's loop) wrapped in a
        // fresh cutout and re-wires the frame graph through it.
        #if DEBUG
        let rebuildViaCutout = !Self._test_skipMovieLoopCutoutRebuild
        #else
        let rebuildViaCutout = true
        #endif
        if rebuildViaCutout, let cutout = cutoutStates[id] {
            movieSources[id] = MovieEntry(source: entry.source, fileURL: entry.fileURL,
                                          loop: loop, scoped: entry.scoped)
            setPresenterCutout(cutout, for: id)   // rebuilds the movie (new loop) inside the cutout
            return
        }
        let descriptor = activeSources[index].descriptor
        do {
            let source = try MovieSource(id: id, fileURL: entry.fileURL,
                                         canvasSize: Self.sourceCanvas,
                                         contentMode: .aspectFit, loop: loop)
            let pipeline = effectPipelines[id]
            source.onFrame = { [mailbox, monitor = linkDebugMonitor, pipeline, isoTap, verticalTap, directorTap, sid = id] frame in
                Self.deliverSourceFrame(frame, pipeline: pipeline, monitor: monitor,
                                        isoTap: isoTap, verticalTap: verticalTap,
                                        directorTap: directorTap, sid: sid, mailbox: mailbox)
            }
            // Reuse the existing mixer channel (same id) if the clip has audio.
            if source.hasAudioTrack, let channel = audioMixer.channel(id: id) {
                source.onAudio = { [multitrackTap] packet in
                    channel.ingest(packet)
                    multitrackTap.append(packet)
                }
            }
            entry.source.stop()        // old decoder's closures go quiet
            try source.start()
            movieSources[id] = MovieEntry(source: source, fileURL: entry.fileURL,
                                          loop: loop, scoped: entry.scoped)
            activeSources[index] = ActiveSource(id: id, descriptor: descriptor,
                                                backing: .movie(source), mailbox: mailbox)
        } catch {
            lastError = "Couldn't update loop for \(descriptor.name): \(error.localizedDescription)"
        }
    }

    // MARK: - Montage source (Build B: auto-cycling image/video reel)

    /// UI-facing item-to-item transition (flattens `MontageSource.Transition`).
    enum MontageTransitionKind: String, CaseIterable, Identifiable, Sendable {
        case cut, crossfade
        var id: String { rawValue }
        var label: String { self == .cut ? "Cut" : "Crossfade" }
    }

    /// Build a `MontageSource` from picked files/folders and register it like a
    /// movie (mailbox → render loop → Layer, auto-selected). Folders are expanded
    /// to their media files. The security-scoped grants are HELD for the source's
    /// lifetime (it streams video items from disk) and released on removal. An
    /// empty/undecodable selection surfaces via `lastError` — never a crash.
    ///
    /// Audio: video-only for now — MontageSource emits video frames only; per-item
    /// soundtracks are not routed into the mixer. TODO: route audio for video items.
    func addMontageSource(fileURLs: [URL], interval: Double = 2.5,
                          transition: MontageSource.Transition = .crossfade(duration: 0.4),
                          kenBurns: Bool = true, shuffle: Bool = false, loop: Bool = true) {
        // New montages inherit the operator's last-used settings (persisted across
        // relaunch). The sole UI caller passes only fileURLs, so these override the
        // function defaults cleanly.
        var interval = interval, transition = transition, kenBurns = kenBurns, shuffle = shuffle
        var restoredCutOnBeat = false, restoredCutEvery = 1
        if let d = persistedMontageDefaults() {
            interval = d.interval; transition = d.transition
            kenBurns = d.kenBurns; shuffle = d.shuffle
            restoredCutOnBeat = d.cutOnBeat; restoredCutEvery = d.cutEveryBeats
        }
        var scoped: [URL] = []
        var items: [MontageSource.MontageItem] = []
        for url in fileURLs {
            // Hold the scope for the montage's lifetime (video items stream from disk).
            if url.startAccessingSecurityScopedResource() { scoped.append(url) }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])) ?? []
                for file in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                where Self.isMontageMedia(file) {
                    items.append(MontageSource.MontageItem.detect(url: file))
                }
            } else if Self.isMontageMedia(url) {
                items.append(MontageSource.MontageItem.detect(url: url))
            }
        }
        guard !items.isEmpty else {
            scoped.forEach { $0.stopAccessingSecurityScopedResource() }
            lastError = "Add Montage: no images or videos were found in the selection."
            return
        }
        do {
            let source = try MontageSource(items: items, canvasSize: Self.sourceCanvas,
                                           interval: interval, transition: transition,
                                           kenBurns: kenBurns, shuffle: shuffle, loop: loop)
            let descriptor = SourceDescriptor(kind: .media, id: source.id.raw,
                                              name: "Montage (\(items.count))")
            // Per-item soundtrack → its OWN mixer channel (gain/mute/solo + meter),
            // exactly like a movie clip's audio (registerMovie). The montage emits
            // one item's audio at a time, so a single channel carries the reel.
            // Wired before start() so no packet is dropped; rolled back if start
            // throws. `hasAudioContent` is false for an all-image reel (no channel).
            var addedChannel = false
            if source.hasAudioContent {
                ensureAudioMixerStarted()
                let channel = try audioMixer.addChannel(id: source.id)
                addedChannel = true
                source.onAudio = { [multitrackTap] packet in
                    channel.ingest(packet)
                    multitrackTap.append(packet) // no-op unless a multitrack session is live
                }
            }
            do {
                try registerGenerated(source, descriptor: descriptor)
            } catch {
                if addedChannel { audioMixer.removeChannel(id: source.id) } // W3: no orphan channel
                throw error
            }
            var entry = MontageEntry(items: items, scopedURLs: scoped,
                                     interval: interval, transition: transition,
                                     kenBurns: kenBurns, shuffle: shuffle, loop: loop)
            entry.cutOnBeat = restoredCutOnBeat
            entry.cutEveryBeats = max(1, restoredCutEvery)
            montageSources[source.id] = entry
            persistMontageDefaults(from: source.id)
        } catch {
            scoped.forEach { $0.stopAccessingSecurityScopedResource() }
            lastError = "Couldn't add montage: \(error.localizedDescription)"
        }
    }

    /// Whether a URL is an image or video montage can use (skips junk like .DS_Store).
    private static func isMontageMedia(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension) {
            if type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .video) {
                return true
            }
        }
        let videoExts: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg"]
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "gif", "tiff", "bmp", "webp"]
        let ext = url.pathExtension.lowercased()
        return videoExts.contains(ext) || imageExts.contains(ext)
    }

    // MARK: Montage inspector + live reconfigure

    func isMontageSource(_ id: SourceID) -> Bool { montageSources[id] != nil }
    func montageItemCount(for id: SourceID) -> Int { montageSources[id]?.items.count ?? 0 }
    func montageInterval(for id: SourceID) -> Double { montageSources[id]?.interval ?? 2.5 }
    func montageKenBurns(for id: SourceID) -> Bool { montageSources[id]?.kenBurns ?? false }
    func montageShuffle(for id: SourceID) -> Bool { montageSources[id]?.shuffle ?? false }
    func montageTransitionKind(for id: SourceID) -> MontageTransitionKind {
        if case .crossfade = montageSources[id]?.transition { return .crossfade }
        return .cut
    }
    func montageCrossfadeDuration(for id: SourceID) -> Double {
        if case .crossfade(let d) = montageSources[id]?.transition { return d }
        return 0.4
    }
    func montageCutOnBeat(for id: SourceID) -> Bool { montageSources[id]?.cutOnBeat ?? false }
    func montageCutEveryBeats(for id: SourceID) -> Int { montageSources[id]?.cutEveryBeats ?? 1 }

    /// Enable/disable "cut on beat" for a montage (BEAT_SYNC_DESIGN). When on, the
    /// `onBeat` callback advances the reel; the fixed interval keeps running too,
    /// so a stopped sequencer still cycles (free-run fallback). No source rebuild.
    func setMontageCutOnBeat(_ on: Bool, for id: SourceID) {
        guard montageSources[id] != nil else { return }
        montageSources[id]?.cutOnBeat = on
        persistMontageDefaults(from: id)
    }
    /// Cut every N downbeats (N=4 ⇒ once per bar in 4/4). Clamped ≥ 1.
    func setMontageCutEveryBeats(_ n: Int, for id: SourceID) {
        guard montageSources[id] != nil else { return }
        montageSources[id]?.cutEveryBeats = max(1, n)
        persistMontageDefaults(from: id)
    }

    /// Persist this montage's settings as the last-used defaults for new montages.
    /// Lives here (not in the persistence extension) because `MontageEntry` is private.
    private func persistMontageDefaults(from id: SourceID) {
        guard let e = montageSources[id] else { return }
        let crossfade: Bool, duration: Double
        if case .crossfade(let d) = e.transition { crossfade = true; duration = d }
        else { crossfade = false; duration = 0.4 }
        saveMontageDefaults(interval: e.interval, crossfade: crossfade, crossfadeDuration: duration,
                            kenBurns: e.kenBurns, shuffle: e.shuffle,
                            cutOnBeat: e.cutOnBeat, cutEveryBeats: e.cutEveryBeats)
    }

    /// Recover the live `MontageSource` behind an id (registered as a `.generated`
    /// backing) so the beat callback can force a cut via `advance()`.
    private func montageSource(for id: SourceID) -> MontageSource? {
        guard let active = activeSources.first(where: { $0.id == id }),
              case .generated(let source) = active.backing else { return nil }
        return source as? MontageSource
    }

    /// Main-actor handler for a BeatSequencer downbeat (hopped here off the clock
    /// queue). Advances every montage that opted into "cut on beat" whose beat
    /// counter lands on this index. Reads main-actor state only after the hop.
    private func handleBeatCut(beatIndex: Int) {
        for (id, entry) in montageSources where entry.cutOnBeat {
            let n = max(1, entry.cutEveryBeats)
            guard beatIndex % n == 0 else { continue }
            montageSource(for: id)?.advance()
        }
    }

    /// Push the current tempo clock into every effect pipeline (BEAT_SYNC_DESIGN),
    /// so beat-synced tiles + pulses read a fresh `BeatClock`. Called on play /
    /// stop / BPM change; `.stopped` when nothing is playing (free-run fallback).
    private func broadcastBeatClock() {
        let clock = beatSequencer?.beatClock ?? .stopped
        for pipeline in effectPipelines.values { pipeline.setBeatClock(clock) }
    }

    /// Live-reconfigure a montage. Its params are fixed at init, so this REBUILDS
    /// the `MontageSource` in place — reusing the SourceID, mailbox, effect
    /// pipeline, and scene layer (only the backing decoder is swapped) — so the
    /// layer never leaves the scene. Mirrors `setMovieLoop`.
    func reconfigureMontage(for id: SourceID, interval: Double? = nil,
                            transition: MontageSource.Transition? = nil,
                            kenBurns: Bool? = nil, shuffle: Bool? = nil) {
        guard var entry = montageSources[id],
              let index = activeSources.firstIndex(where: { $0.id == id }),
              case .generated(let old) = activeSources[index].backing,
              let mailbox = activeSources[index].mailbox else { return }
        if let interval { entry.interval = interval }
        if let transition { entry.transition = transition }
        if let kenBurns { entry.kenBurns = kenBurns }
        if let shuffle { entry.shuffle = shuffle }
        let descriptor = activeSources[index].descriptor
        do {
            let source = try MontageSource(id: id, items: entry.items,
                                           canvasSize: Self.sourceCanvas,
                                           interval: entry.interval, transition: entry.transition,
                                           kenBurns: entry.kenBurns, shuffle: entry.shuffle,
                                           loop: entry.loop)
            let pipeline = effectPipelines[id]
            source.onFrame = { [mailbox, monitor = linkDebugMonitor, pipeline, isoTap, verticalTap, directorTap, sid = id] frame in
                Self.deliverSourceFrame(frame, pipeline: pipeline, monitor: monitor,
                                        isoTap: isoTap, verticalTap: verticalTap,
                                        directorTap: directorTap, sid: sid, mailbox: mailbox)
            }
            // Reuse the existing mixer channel (same id) if the reel has audio — the
            // item set is unchanged by a reconfigure, so hasAudioContent is stable
            // (mirrors setMovieLoop's audio re-wire on an in-place rebuild).
            if source.hasAudioContent, let channel = audioMixer.channel(id: id) {
                source.onAudio = { [multitrackTap] packet in
                    channel.ingest(packet)
                    multitrackTap.append(packet)
                }
            }
            old.stop() // old director queue goes quiet
            try source.start()
            montageSources[id] = entry
            activeSources[index] = ActiveSource(id: id, descriptor: descriptor,
                                                backing: .generated(source), mailbox: mailbox)
            persistMontageDefaults(from: id)
        } catch {
            lastError = "Couldn't update montage: \(error.localizedDescription)"
        }
    }

    /// Live-update the text of an added `TextSource` (inline sidebar editing).
    func setSourceText(_ text: String, for id: SourceID) {
        guard let active = activeSources.first(where: { $0.id == id }),
              case .generated(let source) = active.backing,
              let textSource = source as? TextSource else { return }
        textSource.setText(text)
    }

    /// Whether a source is a live-editable `TextSource` (drives the inline editor).
    func isTextSource(_ id: SourceID) -> Bool {
        guard let active = activeSources.first(where: { $0.id == id }),
              case .generated(let source) = active.backing else { return false }
        return source is TextSource
    }

    /// The live `TextSource` backing for an id (for reveal-style / cue), or nil.
    private func textSourceBacking(_ id: SourceID) -> TextSource? {
        guard let active = activeSources.first(where: { $0.id == id }),
              case .generated(let source) = active.backing else { return nil }
        return source as? TextSource
    }

    /// The reveal-animation style of an added `TextSource` (nil = static).
    func textRevealStyle(for id: SourceID) -> TextRevealStyle? {
        textSourceBacking(id)?.revealStyle
    }

    /// Set the reveal-animation style (nil = static). Setting a non-nil value
    /// re-arms the animation so the text sweeps in over `revealDuration`.
    func setTextRevealStyle(_ style: TextRevealStyle?, for id: SourceID) {
        textSourceBacking(id)?.revealStyle = style
    }

    /// The reveal-animation duration (seconds) of an added `TextSource`.
    func textRevealDuration(for id: SourceID) -> Double {
        textSourceBacking(id)?.revealDuration ?? 1.2
    }

    /// Set the reveal-animation duration (seconds); re-arms the animation.
    func setTextRevealDuration(_ seconds: Double, for id: SourceID) {
        textSourceBacking(id)?.revealDuration = seconds
    }

    /// Replay the text reveal from the start (no-op if the style is static/nil).
    func replayTextReveal(for id: SourceID) {
        textSourceBacking(id)?.cue()
    }

    func addPeer(_ entry: PeerEntry) {
        guard !isActive(entry.id) else { return }
        let source = entry.peer.videoSource
        let mailbox = FrameMailbox()
        let normalizer = LinkFrameNormalizer() // decoder output → compositor-renderable
        let pipeline = makeEffectPipeline(for: entry.id)
        source.onFrame = { [mailbox, monitor = linkDebugMonitor, pipeline, isoTap, verticalTap, directorTap, sid = entry.id] frame in
            let renderable = normalizer.normalize(frame)
            Self.deliverSourceFrame(renderable, pipeline: pipeline, monitor: monitor,
                                    isoTap: isoTap, verticalTap: verticalTap,
                                    directorTap: directorTap, sid: sid, mailbox: mailbox)
        }
        do { try source.start() } catch {
            discardEffectPipeline(entry.id) // W12: don't leave a stale entry
            lastError = "Couldn't add \(entry.name): \(error.localizedDescription)"
            return
        }
        sendTally(LinkTally(program: true, preview: false), to: entry.peer)
        let descriptor = SourceDescriptor(kind: .network, id: entry.id.raw,
                                          name: entry.name, detail: entry.detail)
        register(ActiveSource(id: entry.id, descriptor: descriptor,
                              backing: .link(source, entry.peer), mailbox: mailbox))
    }

    private func register(_ source: ActiveSource, characterLayer: Bool = false) {
        activeSources.append(source)
        if let mailbox = source.mailbox {
            renderLoop?.setMailbox(mailbox, for: source.id)
            dualProgram?.attach(source: source.id)
            var layers = scene.layers
            let nextZ = (layers.map(\.zIndex).max() ?? -1) + 1
            // Text/image/browser sources render premultiplied alpha with a
            // transparent background — their layer MUST honor that alpha, else the
            // compositor treats the transparent background as opaque black and the
            // overlay hides the camera/layers beneath it. (Found streaming a text
            // overlay over the live camera.) Camera/screen/network are opaque.
            // A CharacterSource carries a premultiplied-alpha matte (figure in a
            // centred sub-rect, transparent surround) — it MUST use Layer.character
            // (premultipliedAlpha:true) or it composites as a full-canvas black box.
            let newLayer: Layer = characterLayer
                ? Layer.character(sourceID: source.id, zIndex: nextZ)
                : Layer(sourceID: source.id, zIndex: nextZ,
                        premultipliedAlpha: layerNeedsPremultipliedAlpha(source.id))
            layers.append(newLayer)
            scene.layers = layers
            applyPreset(selectedPreset)
            // Announce the new layer so the Inspector can auto-select it.
            lastAddedVideoSourceID = source.id
        }
        // Reattach any persisted tile/pulse/video-wall snapshot for this id (only
        // fires for a source that returns with the SAME id — stable device ids).
        restoreSourceFX(for: source.id)
    }

    /// sol #8 #3 / #9 #5: the SINGLE gated video-frame emission point shared by every source's
    /// `onFrame`. Runs the source's effect chain and delivers the result. When the chain
    /// applied a video wall, `processAndEmit` re-checks the wall's disabled state and performs
    /// the PROGRAM `post` UNDER THE SAME `stateLock` hold as (and atomically with) that check —
    /// so a disable can never land between the final check and the post (no stale tiled frame).
    /// The observer `taps` run OUTSIDE that lock (on the frame decided under it) so a reentrant
    /// tap can't deadlock (#9 #5). `nonisolated` (runs on the capture queue, touches only
    /// Sendable collaborators — never main-actor engine state).
    /// - Parameter feedISO: when `true` (default) the RAW `frame` is routed to the
    ///   ISO tap here. Set `false` for a source whose clean ISO angle is fed from a
    ///   SEPARATE upstream tap — a Presenter Cutout source, where `frame` is the
    ///   PROCESSED cutout (segmentation baked in) and the true clean source is the
    ///   cutout's upstream raw input, tapped directly into `isoTap` (sol wave-16 #2).
    nonisolated static func deliverSourceFrame(_ frame: VideoFrame,
                                               pipeline: SourceEffectPipeline?,
                                               monitor: LinkDebugMonitor?,
                                               isoTap: ISOTap,
                                               verticalTap: LatestFrameTap,
                                               directorTap: DirectorTap,
                                               sid: SourceID,
                                               mailbox: FrameMailbox,
                                               feedISO: Bool = true) {
        // sol #9 #5: split the delivery into the PROGRAM OUTPUT (`mailbox.post`) and the
        // OBSERVER TAPS. `processAndEmit` performs `post` under its `stateLock` (atomic with
        // the video-wall disabled-check — the gate sol validated) but runs `taps` OUTSIDE the
        // lock, so a tap that synchronously reads pipeline state cannot deadlock. Both receive
        // the SAME frame decided under the lock, so the disable race stays closed for every sink.
        let post: (VideoFrame) -> Void = { out in
            mailbox.post(out)
        }
        let taps: (VideoFrame) -> Void = { out in
            monitor?.recordSourceFrame(out)
            // sol #1: ISO records the RAW per-source frame (clean — pre-grade/key/
            // background/FX — and native format/resolution), NOT the processed `out`.
            // The monitor / vertical / director taps keep the processed frame.
            // sol wave-16 #2: `feedISO == false` for a Presenter Cutout source — its
            // clean ISO angle is fed the UPSTREAM raw frame directly (see
            // `setPresenterCutout`), so routing `frame` (the processed cutout) here
            // would bake segmentation FX into the "clean" ISO.
            if feedISO {
                #if DEBUG
                let isoFrame = AppEngine._test_isoUsesProcessedFrame ? out : frame
                AppEngine._test_isoRoutedFrame?(isoFrame)
                isoTap.append(isoFrame)
                #else
                isoTap.append(frame)
                #endif
            }
            verticalTap.update(sid, with: out)
            directorTap.submit(out)
        }
        if let pipeline {
            pipeline.processAndEmit(frame, post: post, taps: taps)
        } else {
            post(frame)
            taps(frame)
        }
    }

    /// sol #10 #1/#2/#3: build the gated frame callback for a screen source. EVERY screen
    /// source — the original (`addScreen`) AND each hot-swap replacement — routes its
    /// capture-queue frames through a `ScreenReplacementGate` so a single `retire()` on the
    /// main actor atomically silences it (no post-teardown post; sol #10 #1) and DRAINS any
    /// in-flight body (the body runs UNDER the gate lock, so `retire()` blocks until it returns
    /// → the shared `SourceEffectGPU` is idle before the successor is armed; sol #10 #2). `gate`
    /// is `nil` only for the `_test_skipOriginalScreenGate` negative control (pre-fix ungated).
    private func makeGatedScreenFrameCallback(id: SourceID, mailbox: FrameMailbox,
                                              gate: ScreenReplacementGate?) -> (VideoFrame) -> Void {
        let pipeline = effectPipelines[id]
        let monitor = linkDebugMonitor
        let isoTap = self.isoTap, verticalTap = self.verticalTap, directorTap = self.directorTap
        return { frame in
            let body: () -> Void = {
                #if DEBUG
                let probe = AppEngine._test_screenSwapProbe(for: id)
                probe?.enterVideo(); defer { probe?.exitVideo() }
                AppEngine._test_screenDeliveryInside?()
                #endif
                AppEngine.deliverSourceFrame(frame, pipeline: pipeline, monitor: monitor,
                                             isoTap: isoTap, verticalTap: verticalTap,
                                             directorTap: directorTap, sid: id, mailbox: mailbox)
            }
            // sol #11 #1: a DEFERRED replacement's frames arriving before its commit are BUFFERED
            // (latest-wins) rather than dropped, so the swapped-in screen presents immediately at
            // arm instead of holding stale/black. `_test_skipDeferredScreenBuffer` reproduces the
            // pre-fix drop.
            #if DEBUG
            let allowBuffer = !AppEngine._test_skipDeferredScreenBuffer
            #else
            let allowBuffer = true
            #endif
            if let gate { gate.deliverIfLive(buffering: allowBuffer, body) } else { body() }
        }
    }

    /// sol #10 #1/#3: build the gated audio callback for a screen source. Gated by the SAME gate
    /// as the source's frame callback, so retiring the source makes it frame-AND-audio-dead
    /// atomically — the pre-fix ORIGINAL audio closure was WHOLLY ungated (a 256-frame packet
    /// advanced the shared/detached `MixerChannel` after remove/shutdown/first-HDR-commit). The
    /// `retire()` drain also relinquishes the channel ingest before the successor is armed.
    private func makeGatedScreenAudioCallback(id: SourceID, channel: MixerChannel,
                                              gate: ScreenReplacementGate?) -> (AudioPacket) -> Void {
        let multitrackTap = self.multitrackTap
        return { packet in
            let body: () -> Void = {
                #if DEBUG
                let probe = AppEngine._test_screenSwapProbe(for: id)
                probe?.enterAudio(); defer { probe?.exitAudio() }
                AppEngine._test_screenDeliveryInside?()
                #endif
                channel.ingest(packet)
                multitrackTap.append(packet)
            }
            if let gate { gate.deliverIfLive(body) } else { body() }
        }
    }

    func removeSource(_ id: SourceID) {
        guard let index = activeSources.firstIndex(where: { $0.id == id }) else { return }
        // Release aggregate animated-media budget accounting for an ordinary GIF
        // source (F15); harmless no-op for non-animated sources.
        animatedMemeByteCost[id] = nil
        animatedMemeLRU.removeAll { $0 == id }
        animatedGIFSourceURLs[id] = nil
        persistableSourceFiles[id] = nil // source persistence: drop the file identity on remove
        invalidatePendingStingerCue(for: id, drain: true)
        if activeStingerSourceID == id { cancelActiveStingerTransition() }
        let source = activeSources.remove(at: index)
        if stingerMediaID == id {
            stingerMediaID = nil
            saveTransitionSettings()
        }
        // Tear down a presenter-cutout wrapper if one drives this source's frames
        // (its stop() also stops the wrapped upstream). State goes with the source.
        cutoutSources.removeValue(forKey: id)?.stop()
        cutoutStates[id] = nil
        switch source.backing {
        case .camera(let camera): camera.stop()
        case .microphone(let mic):
            mic.stop()
            audioMixer.removeChannel(id: id)
        case .screen(let screen):
            screen.stop()
            // sol #9 #1: a COMMITTED replacement source owns a gate (in `committedScreenGates`)
            // that a plain `stop()` can't atomically silence — retire it so an in-flight capture
            // callback can't post after removal (the committed source no longer loses its gate).
            committedScreenGates[id]?.retire()
            committedScreenGates[id] = nil
            committedScreenGeneration[id] = nil   // sol #12 #2: a re-add starts a fresh lineage
            screenReplacementGeneration[id] = nil
            // sol #8 #1: a screen source can have an in-flight HDR/SDR replacement that is
            // NOT yet in `activeSources` (still resolving its async start). Tear it down
            // too — otherwise its capture keeps resolving and posting frames after removal.
            drainPendingScreenReplacements(for: id)
            // Remove the app-audio mixer channel if this source captured audio
            // (deliverable A) — symmetric with the mic/system-audio teardown.
            if screen.configuration.capturesAudio { audioMixer.removeChannel(id: id) }
        case .link(let video, let peer):
            video.stop()
            sendTally(LinkTally(program: false, preview: false), to: peer)
        case .systemAudio(let audio):
            audio.stop()
            audioMixer.removeChannel(id: id)
            if systemAudioSource === audio { systemAudioSource = nil }
        case .generated(let video):
            video.stop()
            characterSources.removeValue(forKey: id)
            overlaySources.removeValue(forKey: id)
            tickerEntries.removeValue(forKey: id)
            creditsEntries.removeValue(forKey: id)
            // Release the security-scoped grant a logo held for its lifetime.
            if let logo = logoEntries.removeValue(forKey: id), logo.scoped {
                logo.url.stopAccessingSecurityScopedResource()
            }
            // Drop this character from the lip-sync set (tears the follower/timer
            // down if it was the last one).
            if lipSyncCharacterIDs.remove(id) != nil { teardownLipSyncIfIdle() }
            // Drop any per-layer motion and refresh the render provider.
            if layerMotions.removeValue(forKey: id) != nil { refreshSceneProvider() }
            // A montage whose reel carries audio owns a mixer channel — remove it
            // symmetrically with the movie/mic teardown (idempotent for silent reels).
            if let montage = video as? MontageSource, montage.hasAudioContent {
                audioMixer.removeChannel(id: id)
            }
            // Release the security-scoped grants a montage held for its lifetime.
            if let entry = montageSources.removeValue(forKey: id) {
                entry.scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            }
        case .movie(let movie):
            movie.stop()
            // Symmetric with the mic/app-audio teardown: a clip with a soundtrack
            // owns a mixer channel that goes away with it.
            if movie.hasAudioTrack { audioMixer.removeChannel(id: id) }
            // Release the security-scoped grant held for the file's lifetime.
            if let entry = movieSources[id], entry.scoped {
                entry.fileURL.stopAccessingSecurityScopedResource()
            }
            movieSources.removeValue(forKey: id)
        }
        // A removed source can no longer be ISO- or multitrack-armed, and its
        // insert chain / voice-iso state goes away with the channel.
        isoArmedSourceIDs.remove(id)
        multitrackArmedSourceIDs.remove(id)
        // Codex #2: cancel + drop any in-flight insert edit and bump the token so
        // a slow AUv3 that finishes instantiating after this can't reconnect the
        // now-detached channel (and can't write back a stale mirror).
        channelInsertTasks[id]?.cancel()
        channelInsertTasks[id] = nil
        channelInsertGeneration[id] = (channelInsertGeneration[id] ?? 0) &+ 1
        channelInserts[id] = nil
        // sol #2 (HIGH): STOP the animated-FX driver injecting this source's held
        // `lastRaw` BEFORE the compositor forgets its mailbox. `removeMailbox` only
        // sets a forget-tombstone (pruned after 2 ticks); if the driver is still
        // registered it keeps injecting the removed source's frame across that
        // window, and once the tombstone is pruned an injected stale frame is
        // accepted and stays pinned forever (reopened F1). Unregistering FIRST means
        // no injection survives the forget: the one possibly-in-flight injection (a
        // `process()` that already snapshotted the pipelines) lands while the
        // tombstone still guards, and every later tick sees the source gone from the
        // driver — so the compositor frame is forgotten AFTER injection has stopped.
        animatedFXDriver.unregister(id)
        if source.isVideo {
            renderLoop?.removeMailbox(for: id)
            scene.layers.removeAll { $0.sourceID == id }
            linkDebugMonitor?.forgetSource(id)
            verticalTap.forget(id)
            isoTap.formats.forget(id) // drop the removed source's native-format probe entry
            dualProgram?.forget(source: id)
            if verticalHeroSourceID == id {
                verticalHeroSourceID = nil
                rebuildVerticalReframe()
            }
        }
        // Per-source effect chain teardown (releases the segmenter, if any).
        effectPipelines[id]?.teardown()
        effectPipelines[id] = nil
        sourceEffects[id] = nil
        // Don't leave a removed source as the last-added auto-select target.
        if lastAddedVideoSourceID == id { lastAddedVideoSourceID = nil }
    }

    /// C25: LinkPeer.send* must not run on the main actor (no internal hop to
    /// the link queue). All app-side control sends go through linkSendQueue.
    private func sendTally(_ tally: LinkTally, to peer: LinkPeer) {
        linkSendQueue.async { peer.send(tally: tally) }
    }

    // MARK: Screen browser

    func refreshScreenItems() {
        screenBrowserBusy = true
        screenBrowserError = nil
        Task { @MainActor in
            do {
                let displays = try await ScreenContentBrowser.displays()
                let windows = try await ScreenContentBrowser.windows()
                screenItems = displays + windows
            } catch {
                screenItems = []
                screenBrowserError = """
                Couldn't list screens/windows. If macOS asked for Screen Recording access, \
                allow Prism in System Settings → Privacy & Security → Screen & System Audio \
                Recording, then try again.
                """
            }
            screenBrowserBusy = false
        }
    }

    // MARK: Layers

    func displayName(for id: SourceID) -> String {
        activeSources.first(where: { $0.id == id })?.descriptor.name ?? id.raw
    }

    func setLayerHidden(_ hidden: Bool, for id: SourceID) {
        mutateLayer(id) { $0.isHidden = hidden }
    }

    func setLayerFrame(_ preset: LayerFramePreset, for id: SourceID) {
        mutateLayer(id) { $0.frame = preset.rect }
    }

    /// Move a layer one step toward the front (`up == true`) or back.
    func moveLayer(_ id: SourceID, up: Bool) {
        var ordered = scene.layers.sorted { $0.zIndex < $1.zIndex }
        guard let index = ordered.firstIndex(where: { $0.sourceID == id }) else { return }
        let target = up ? index + 1 : index - 1
        guard ordered.indices.contains(target) else { return }
        ordered.swapAt(index, target)
        for (i, _) in ordered.enumerated() { ordered[i].zIndex = i }
        scene.layers = ordered
    }

    private func mutateLayer(_ id: SourceID, _ mutate: (inout Layer) -> Void) {
        var layers = scene.layers
        guard let index = layers.firstIndex(where: { $0.sourceID == id }) else { return }
        mutate(&layers[index])
        scene.layers = layers
    }

    func applyPreset(_ preset: ScenePreset) {
        guard !didShutdown else { return } // Codex #4: no control-tier mutation after shutdown
        selectedPreset = preset
        var ordered = scene.layers.sorted { $0.zIndex < $1.zIndex }
        let visible = ordered.indices.filter { !ordered[$0].isHidden }
        switch preset {
        case .fullscreen:
            for i in visible { ordered[i].frame = LayerFramePreset.full.rect }
        case .pipCorner:
            for i in visible { ordered[i].frame = LayerFramePreset.full.rect }
            if visible.count >= 2, let top = visible.last {
                ordered[top].frame = LayerFramePreset.corner.rect
            }
        case .sideBySide:
            if visible.count >= 2 {
                ordered[visible[visible.count - 2]].frame = LayerFramePreset.leftHalf.rect
                ordered[visible[visible.count - 1]].frame = LayerFramePreset.rightHalf.rect
                for i in visible.dropLast(2) { ordered[i].frame = LayerFramePreset.full.rect }
            } else {
                for i in visible { ordered[i].frame = LayerFramePreset.full.rect }
            }
        }
        var next = scene
        next.layers = ordered
        commitSceneAnimated(next) // preset switch = animated transition (deliverable 4)
        controlServer.publish(.currentProgramSceneChanged(sceneName: preset.rawValue))
    }

    // MARK: Record

    func toggleRecording() {
        if isRecording {
            Task { await self.stopRecording() }
        } else {
            do { try startRecording() }
            catch { lastError = "Couldn't start recording: \(error.localizedDescription)" }
        }
    }

    // MARK: - Vertical program (9:16) controls

    /// Turn the vertical program on/off. When on, the primary program-frame
    /// callback starts feeding `dualProgram` this tick's frames; when off, the
    /// tap stops accumulating (zero cost). If a recording is already running,
    /// this also starts the companion vertical file.
    func setVerticalEnabled(_ enabled: Bool) {
        guard verticalProgramEnabled != enabled else { return }
        verticalProgramEnabled = enabled
        verticalTap.enabled = enabled
        if enabled {
            dualProgram?.scene = scene
            rebuildVerticalReframe()
            // A live meme/motion provider will publish its exact evaluated
            // scene on the next primary tick now that the tap is enabled.
            refreshSceneProvider()
            if isRecording { startVerticalRecorderIfNeeded() }
        }
        // A disable mid-recording leaves the in-flight vertical file to finalize
        // at stopRecording() (keeps that clip complete for the whole session).
    }

    /// Choose how the vertical program reframes the horizontal scene.
    func setVerticalReframe(_ mode: VerticalReframeMode) {
        verticalReframeMode = mode
        rebuildVerticalReframe()
        refreshSceneProvider()
    }

    /// Pin the full-bleed hero source used by `.follow` mode.
    func setVerticalHero(_ id: SourceID?) {
        verticalHeroSourceID = id
        rebuildVerticalReframe()
        refreshSceneProvider()
    }

    /// Map the UI mode + hero selection onto a `ReframeMap` for the secondary.
    private func rebuildVerticalReframe() {
        verticalTap.updateRouting(mode: verticalReframeMode,
                                  pinnedHero: verticalHeroSourceID)
        let map: ReframeMap
        switch verticalReframeMode {
        case .heroFill:
            map = .heroFill                                   // frontmost source, full-bleed
        case .follow:
            map = verticalHeroSourceID.map { .follow($0) }    // pinned hero, full-bleed
                ?? .heroFill                                  // none chosen yet → sane default
        case .fitAll:
            map = .fitAll()                                   // letterbox every source
        }
        dualProgram?.reframe = map
    }

    /// Build the vertical mapping for a provider-evaluated scene. Auxiliary
    /// meme layers must not participate in automatic hero selection: an Insert
    /// in the corner stays an overlay over the resting hero, while a Cut-To
    /// (the evaluated scene contains only auxiliary media) becomes full-bleed.
    /// Re-fit an auxiliary (meme) layer's 16:9-canvas placement rect so its true
    /// 16:9 source aspect is preserved on the 9:16 vertical canvas (F24 / Class A).
    /// The meme texture fills the shared source canvas (16:9), so its content
    /// aspect equals the horizontal canvas aspect; letterbox that aspect inside the
    /// incoming region on the vertical canvas. Pure + deterministic.
    nonisolated static func verticalAuxiliaryFrame(_ frame: CGRect) -> CGRect {
        let hAspect = Double(canvasSize.width) / Double(canvasSize.height)               // 16:9
        let vAspect = Double(verticalCanvasSize.width) / Double(verticalCanvasSize.height) // 9:16
        return MemeDirector.aspectFitFrame(frame, canvasAspect: vAspect, sourceAspect: hAspect)
    }

    nonisolated static func verticalReframeMap(
        evaluatedScene: ProgramScene,
        restingScene: ProgramScene,
        mode: VerticalReframeMode,
        pinnedHero: SourceID?,
        auxiliaryFrames: [SourceID: CGRect]
    ) -> ReframeMap {
        let auxiliaryIDs = Set(auxiliaryFrames.keys)
        let visibleLayers = evaluatedScene.layers.filter { !$0.isHidden }
        let auxiliaryOnly = !visibleLayers.isEmpty
            && visibleLayers.allSatisfy { auxiliaryIDs.contains($0.sourceID) }

        var overrides: [SourceID: ReframeMode] = [:]
        for layer in visibleLayers where auxiliaryIDs.contains(layer.sourceID) {
            let frame = auxiliaryFrames[layer.sourceID] ?? layer.frame
            let isFullscreen = abs(frame.minX) < 0.0001 && abs(frame.minY) < 0.0001
                && abs(frame.width - 1) < 0.0001 && abs(frame.height - 1) < 0.0001
            // F24 (vertical): the placement rect was aspect-corrected for the 16:9
            // canvas. Reusing that normalized rect verbatim on the 9:16 vertical
            // canvas (via `.custom`, which sets frame=rect, crop unchanged) squeezes
            // the meme's 16:9 texture into a much narrower pixel box → a horizontal
            // crush. RE-FIT the meme's true (16:9) source aspect inside that region
            // against the 9:16 canvas so the vertical placement preserves aspect too.
            overrides[layer.sourceID] = (auxiliaryOnly || isFullscreen)
                ? .fill
                : .custom(Self.verticalAuxiliaryFrame(frame))
        }

        switch mode {
        case .heroFill:
            // Resolve against the resting program, never the transient top-z
            // meme layer. If there is no resting hero (meme over empty program),
            // top-z remains the sensible fallback and overrides still win.
            let baseHero = ReframeMap.heroFill.resolveHero(in: restingScene)
            return ReframeMap(hero: baseHero.map(ReframeMap.Hero.source) ?? .topZIndex,
                              heroMode: .fill, others: .hidden, overrides: overrides)
        case .follow:
            let fallback = ReframeMap.heroFill.resolveHero(in: restingScene)
            let hero = pinnedHero ?? fallback
            return ReframeMap(hero: hero.map(ReframeMap.Hero.source) ?? .topZIndex,
                              heroMode: .fill, others: .hidden, overrides: overrides)
        case .fitAll:
            return ReframeMap(hero: .none, others: .fit, overrides: overrides)
        }
    }

    /// Start the companion vertical `MovieRecorder` (video-only, 1080×1920) for
    /// the current recording session, writing a "-vertical" sibling file.
    private func startVerticalRecorderIfNeeded() {
        guard verticalProgramEnabled, verticalRecorder == nil,
              dualProgram != nil, let base = currentRecordingBaseURL else { return }
        let dir = base.deletingLastPathComponent()
        let name = base.deletingPathExtension().lastPathComponent + "-vertical"
        let url = dir.appending(path: name + ".mov")
        // HDR sink-parity (Stage O): when the program is HDR the vertical
        // compositor is rebuilt in `.hdr` (see setHDREnabled), so its recording
        // must be tagged HDR too (HEVC Main10 / Rec.2020-HLG). SDR unchanged.
        let settings = RecordingSettings(codec: .h264,
                                         width: Self.verticalCanvasSize.width,
                                         height: Self.verticalCanvasSize.height,
                                         includeAudio: false,
                                         dynamicRange: hdrEnabled ? .hdr : .sdr)
        do {
            let recorder = try MovieRecorder(url: url, settings: settings)
            try recorder.start()
            verticalRecorder = recorder
            verticalSink.setRecorder(recorder)
        } catch {
            lastError = "Couldn't start vertical recording: \(error.localizedDescription)"
        }
    }

    /// The vertical writer entered `.failed` mid-recording (Codex C4): detach it
    /// so a stop can't try to finalize a dead writer, and surface the error —
    /// identity-checked against the current recorder.
    private func verticalRecorderFailed(_ failed: MovieRecorder) {
        guard verticalRecorder === failed else { return }
        verticalRecorder = nil
        verticalSink.setRecorder(nil)
        failed.cancel()
        lastError = "Vertical recording failed while writing — stopped."
    }

    /// Finalize the vertical recorder (awaited from stopRecording). Detaches the
    /// sink first so no more frames route in while it finalizes.
    private func finishVerticalRecorder() async {
        guard let recorder = verticalRecorder else { return }
        verticalRecorder = nil
        verticalSink.setRecorder(nil)
        do {
            let report = try await recorder.finish()
            lastVerticalRecordingURL = report.url
        } catch {
            lastError = "Vertical recording failed to finalize: \(error.localizedDescription)"
        }
    }

    func startRecording() throws {
        guard !didShutdown else { return } // Codex #4: don't attach outputs after shutdown
        guard recorder == nil else { return }
        let directory = URL(filePath: NSHomeDirectory()).appending(path: "Movies/Prism")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // sol HIGH #1 (data loss): a second-resolution name let two rapid Records
        // pick the identical filename → the later take overwrote the earlier one.
        // Disambiguate with milliseconds AND a monotonic per-take counter, and give
        // each take its OWN ISO/Multitrack subfolder (`takeID`), so no take can ever
        // overwrite another take's program, ISO, or multitrack files.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        recordTakeCounter &+= 1
        let takeID = "\(formatter.string(from: Date())) (\(recordTakeCounter))"
        let url = directory.appending(path: "Prism \(takeID).mov")

        // sol #2: record the PROGRAM MASTER MIX. The mixer's master tap
        // (`audioMixer.onMasterMix` → `fanOut.handle(audio:)`) carries soundboard,
        // beat, and music-bed channels — which are MIXER-owned, NOT `activeSources`
        // — plus every mic / app-audio channel, INCLUDING any mic added AFTER Record
        // starts. Gating the audio track on `activeSources` dropped all mixer-only
        // audio (a video-only source with a soundboard playing recorded silence) and
        // could never capture a later-added mic. Always write the audio track and
        // feed it the master mix so all of that is recorded.
        #if DEBUG
        let hasAudio = AppEngine._test_gateRecordAudioOnActiveSources
            ? activeSources.contains(where: \.isAudio) // NEG CONTROL: the pre-fix gate
            : true
        #else
        let hasAudio = true
        #endif
        // HDR program (rebuilt compositor emits 10-bit .hdr frames) → tag the
        // recording HDR so MovieRecorder writes HEVC Main10 + Rec.2020 HLG.
        let settings = RecordingSettings(codec: .h264,
                                         width: Self.canvasSize.width,
                                         height: Self.canvasSize.height,
                                         includeAudio: hasAudio,
                                         dynamicRange: hdrEnabled ? .hdr : .sdr)
        let newRecorder = try MovieRecorder(url: url, settings: settings)
        try newRecorder.start()
        recordGeneration &+= 1 // C26: this start supersedes any in-flight stop
        recorder = newRecorder
        fanOut.setRecorder(newRecorder, wantsAudio: hasAudio)
        isRecording = true
        recordStartDate = Date()
        // Companion vertical (9:16) file alongside the 16:9 program, if enabled.
        currentRecordingBaseURL = url
        startVerticalRecorderIfNeeded()
        controlServer.publish(.recordStateChanged(active: true, state: .started, outputPath: url.path))

        // ISO: if any active video source is armed, start a per-source bank on
        // one shared house-time zero (deliverable 3). The .fcpxml lands beside
        // the program clip in `directory` (deliverable 4). `takeID` namespaces
        // this take's ISO files so a later take can't overwrite them (sol HIGH #1).
        startISOIfArmed(recordingDirectory: directory,
                        projectName: url.deletingPathExtension().lastPathComponent,
                        takeID: takeID)

        // Multitrack: if any active audio source is armed, start a per-source
        // audio bank on its own shared timeline zero (deliverable 3). Per-take
        // subfolder (`takeID`) so a later take can't overwrite it (sol HIGH #1).
        startMultitrackIfArmed(recordingDirectory: directory, takeID: takeID)
    }

    @discardableResult
    func stopRecording() async -> String? {
        await stopRecordingReportingClaim().path
    }

    /// Stop the active recording, reporting whether THIS call actually claimed a
    /// running recording (`stopped`) alongside the finalized file path.
    ///
    /// The claim — nil-ing `recorder` and flipping `isRecording` — is synchronous
    /// (no await before it), so two concurrent StopRecord requests can't both
    /// win: exactly one sees a live `recorder`, the loser gets `stopped == false`
    /// and the obs backend maps that to `outputNotRunning` instead of a phantom
    /// success (Codex #5).
    @discardableResult
    func stopRecordingReportingClaim() async -> (stopped: Bool, path: String?) {
        guard let finishing = recorder else { return (false, nil) }
        let generation = recordGeneration // C26: token for THIS recording
        recorder = nil
        fanOut.setRecorder(nil)
        currentRecordingBaseURL = nil
        // Flip the public flag synchronously with the claim (before the first
        // await) so the claim is fully atomic on the main actor.
        isRecording = false
        recordStartDate = nil

        // sol HIGH #2: capture + detach THIS take's ISO/multitrack banks
        // SYNCHRONOUSLY, before the vertical-finalization await. Otherwise a
        // Start B that interleaves during `await finishVerticalRecorder()` (the
        // claim already published `recorder == nil`, so Start B is admitted)
        // installs NEW banks into the still-live slots; this Stop would then
        // capture+finalize B's banks and strand A's. Snapshotting here means this
        // Stop only ever finalizes its OWN banks and a Start B installs into a
        // clean (nil) slot. Detaching the taps also stops new frames routing in.
        func detachBanks() -> (iso: ISORecorderBank?, audio: AudioTrackRecorderBank?) {
            let iso = isoBank
            isoBank = nil
            isoTap.install(nil)
            stopISOStatusTimer()
            let audio = multitrackBank
            multitrackBank = nil
            multitrackTap.install(nil)
            return (iso, audio)
        }
        #if DEBUG
        // NEGATIVE CONTROL: the pre-fix ordering captured the banks AFTER the
        // vertical await, so a Start B during that await cross-finalized B's banks
        // and stranded A's. Flag reinstates it to prove the race reproduces.
        let captureAfterAwait = AppEngine._test_captureBanksAfterVerticalAwait
        #else
        let captureAfterAwait = false
        #endif
        var bank: ISORecorderBank?
        var audioBank: AudioTrackRecorderBank?
        if !captureAfterAwait { (bank, audioBank) = detachBanks() }

        #if DEBUG
        // Seam: deterministically interleave a Start B at the exact vulnerable
        // window (where the original `await` suspended the main actor).
        AppEngine._test_stopMidVerticalHook?()
        #endif
        await finishVerticalRecorder() // finalize the 9:16 companion, if any
        if captureAfterAwait { (bank, audioBank) = detachBanks() }

        var programReport: MovieRecorder.Report?
        do {
            let report = try await finishing.finish()
            programReport = report
            lastRecordingURL = report.url
            // C26: a startRecording() during the await bumped the generation;
            // publishing "stopped" then would misreport the NEW recording.
            if generation == recordGeneration {
                controlServer.publish(.recordStateChanged(active: false, state: .stopped,
                                                          outputPath: report.url.path))
            }
        } catch {
            lastError = "Recording failed to finalize: \(error.localizedDescription)"
            if generation == recordGeneration {
                controlServer.publish(.recordStateChanged(active: false, state: .stopped, outputPath: nil))
            }
        }

        // Finalize the ISO angles (if any) and retain the session for export.
        if let bank {
            let results = await bank.finishAll()
            finishISOSession(results: results, program: programReport)
        }
        // Finalize the multitrack audio tracks (if any).
        if let audioBank {
            let results = await audioBank.finishAll()
            finishMultitrackSession(results: results)
        }
        return (true, programReport?.url.path)
    }

    /// C29: the fan-out detected the active recorder in `.failed` (writer
    /// errors surface asynchronously inside append). Surface it and clear
    /// recording state; ignore if the failed instance was already superseded.
    private func recorderFailed(_ failed: MovieRecorder) {
        guard recorder === failed else { return }
        recorder = nil
        fanOut.setRecorder(nil)
        currentRecordingBaseURL = nil
        Task { await self.finishVerticalRecorder() } // close the 9:16 companion too
        isRecording = false
        recordStartDate = nil
        lastError = "Recording failed: the writer stopped mid-recording "
            + "(\(failed.url.lastPathComponent)). The file may be incomplete."
        controlServer.publish(.recordStateChanged(active: false, state: .stopped,
                                                  outputPath: failed.url.path))
        // Tear down the ISO bank too — close its files rather than leak writers.
        if let bank = isoBank {
            isoBank = nil
            isoTap.install(nil)
            stopISOStatusTimer()
            Task { let results = await bank.finishAll(); await MainActor.run { self.finishISOSession(results: results, program: nil) } }
        }
        // Tear down the multitrack audio bank too — close its files, don't leak.
        if let audioBank = multitrackBank {
            multitrackBank = nil
            multitrackTap.install(nil)
            Task { let results = await audioBank.finishAll(); await MainActor.run { self.finishMultitrackSession(results: results) } }
        }
    }

    // MARK: - ISO recording (deliverable 3)

    /// Arm / disarm a source for ISO recording. Only legal while idle (the bank
    /// is immutable once `start(at:)` runs).
    func setISOArmed(_ armed: Bool, for id: SourceID) {
        guard !isRecording else { return }
        if armed { isoArmedSourceIDs.insert(id) } else { isoArmedSourceIDs.remove(id) }
    }

    func isISOArmed(_ id: SourceID) -> Bool { isoArmedSourceIDs.contains(id) }

    // MARK: - Multitrack audio (deliverable 3)

    /// Arm / disarm an AUDIO source for multitrack recording (its own clean track
    /// beside the program). Only legal while idle — the bank is immutable once
    /// `start()` runs.
    func setMultitrackArmed(_ armed: Bool, for id: SourceID) {
        guard !isRecording else { return }
        if armed { multitrackArmedSourceIDs.insert(id) } else { multitrackArmedSourceIDs.remove(id) }
    }

    func isMultitrackArmed(_ id: SourceID) -> Bool { multitrackArmedSourceIDs.contains(id) }

    /// Start a per-source audio bank for every armed, still-present audio source,
    /// on one shared house-time zero. Each source's `onAudio` closure already
    /// feeds `multitrackTap`; installing the bank routes those packets to their
    /// own tracks. No-op when nothing is armed.
    private func startMultitrackIfArmed(recordingDirectory: URL, takeID: String) {
        let armed = activeSources.filter { $0.isAudio && multitrackArmedSourceIDs.contains($0.id) }
        guard !armed.isEmpty else { return }
        // Per-take subfolder so a later take's `audio-<source>.mov` never lands on
        // (and overwrites) an earlier take's file (sol HIGH #1).
        let dir = recordingDirectory.appending(path: "Multitrack").appending(path: takeID)
        let bank = AudioTrackRecorderBank(directory: dir, defaultSettings: AudioTrackSettings())
        do {
            for source in armed { try bank.addSource(source.id) }
            try bank.start()
            multitrackBank = bank
            multitrackTap.install(bank)
        } catch {
            lastError = "Couldn't start multitrack audio: \(error.localizedDescription)"
            multitrackBank = nil
        }
    }

    /// Adopt finished multitrack results: publish the per-source file list.
    private func finishMultitrackSession(results: [SourceID: Result<AudioTrackRecorder.Report, Error>]) {
        var files: [SourceID: URL] = [:]
        for (id, result) in results {
            if case .success(let report) = result { files[id] = report.url }
        }
        lastMultitrackFiles = files
    }

    /// Per-source ISO metadata captured at arm time, so the export survives the
    /// source being removed after Stop.
    private var isoSessionStart: CMTime?
    private var isoSessionDir: URL?
    private var isoSessionProjectName: String?
    private var isoSessionMeta: [SourceID: FinishedMulticamSession.AngleMeta] = [:]

    private func startISOIfArmed(recordingDirectory: URL, projectName: String, takeID: String) {
        // Only video sources still present can be ISO-recorded.
        let armed = activeSources.filter { $0.isVideo && isoArmedSourceIDs.contains($0.id) }
        guard !armed.isEmpty else { return }

        // Per-take subfolder so a later take's `iso-<source>.mov` never lands on
        // (and overwrites) an earlier take's file (sol HIGH #1).
        let isoDir = recordingDirectory.appending(path: "ISO").appending(path: takeID)
        // Fallback only (a source that has not yet delivered a frame): canvas-size
        // SDR. Each armed source below overrides this with its OWN native format.
        let defaultSettings = RecordingSettings(codec: .h264,
                                                width: Self.canvasSize.width,
                                                height: Self.canvasSize.height,
                                                includeAudio: false)
        let bank = ISORecorderBank(directory: isoDir, defaultSettings: defaultSettings)
        var meta: [SourceID: FinishedMulticamSession.AngleMeta] = [:]
        do {
            for source in armed {
                // sol #1 / wave-16 #1: size + tag the per-source ISO file from the
                // source's OWN raw frame — native resolution, and HEVC Main10 +
                // Rec.2020/HLG when the source is HDR (H.264/SDR otherwise) —
                // instead of a hardcoded 1920×1080 H.264 SDR that upscaled a
                // 640×480 source and flattened a 10-bit HLG source to 8-bit.
                let native = isoTap.formats.format(for: source.id)
                #if DEBUG
                let hardcode = AppEngine._test_forceISOHardcodedSettings
                let forceImmediateFallback = AppEngine._test_forceISOImmediateCanvasFallback
                #else
                let hardcode = false
                let forceImmediateFallback = false
                #endif
                if let native, !hardcode {
                    // The source's native format is already known → configure natively now.
                    let perSource = RecordingSettings(codec: .h264, width: native.width, height: native.height,
                                                      includeAudio: false,
                                                      dynamicRange: native.isHDR ? .hdr : .sdr)
                    try bank.addSource(source.id, settings: perSource, includeAudio: false)
                    meta[source.id] = FinishedMulticamSession.AngleMeta(
                        name: source.descriptor.name,
                        width: native.width, height: native.height,
                        fps: recordingFPS(for: source.id), hasAudio: false)
                } else if hardcode || forceImmediateFallback {
                    // NEGATIVE CONTROL (pre-fix): freeze a canvas-sized SDR fallback for a
                    // source with no frame yet (or force 1080p for every source), losing
                    // native resolution + HDR on the first take.
                    let w = Self.canvasSize.width, h = Self.canvasSize.height
                    let perSource = RecordingSettings(codec: .h264, width: w, height: h,
                                                      includeAudio: false, dynamicRange: .sdr)
                    try bank.addSource(source.id, settings: perSource, includeAudio: false)
                    meta[source.id] = FinishedMulticamSession.AngleMeta(
                        name: source.descriptor.name, width: w, height: h,
                        fps: recordingFPS(for: source.id), hasAudio: false)
                } else {
                    // sol wave-16 #1: NO frame has arrived yet (sources start async, so an
                    // ISO armed before the first frame would otherwise freeze a canvas-sized
                    // SDR fallback and lose native + HDR on the FIRST take). DEFER the
                    // recorder's creation to the source's FIRST real frame, deriving native
                    // resolution + HDR-ness from it — exactly as the per-source probe does.
                    try bank.addDeferredSource(source.id, includeAudio: false) { frame in
                        let transfer = YCbCrTags.transferCode(for: frame.pixelBuffer)
                        let isHDR = (transfer == 1 || transfer == 2) // 1=HLG, 2=PQ
                        return RecordingSettings(codec: .h264, width: frame.width, height: frame.height,
                                                 includeAudio: false, dynamicRange: isHDR ? .hdr : .sdr)
                    }
                    // Provisional meta (native, canvas-fallback dims) — refreshed from the
                    // materialized recorder's actual settings at finish (finishISOSession).
                    meta[source.id] = FinishedMulticamSession.AngleMeta(
                        name: source.descriptor.name,
                        width: Self.canvasSize.width, height: Self.canvasSize.height,
                        fps: recordingFPS(for: source.id), hasAudio: false)
                }
            }
            let start = HouseClock.now()
            try bank.start(at: start)
            isoBank = bank
            isoTap.install(bank)
            isoSessionStart = start
            isoSessionDir = recordingDirectory
            isoSessionProjectName = projectName
            isoSessionMeta = meta
            isoStatuses = Dictionary(uniqueKeysWithValues: armed.map { ($0.id, "recording…") })
            startISOStatusTimer()
        } catch {
            lastError = "Couldn't start ISO recording: \(error.localizedDescription)"
            isoBank = nil
        }
    }

    /// Nominal fps for a source's recording metadata (exact for generated
    /// sources; cameras/screen default to the program rate).
    private func recordingFPS(for id: SourceID) -> Double {
        guard let active = activeSources.first(where: { $0.id == id }) else { return 60 }
        if case .generated(let video) = active.backing, let timed = video as? TimedVideoSource {
            return timed.fps
        }
        return 60
    }

    /// Adopt finished ISO results: publish the per-source file list and retain
    /// the session for FCPXML export (deliverable 4).
    private func finishISOSession(results: [SourceID: Result<MovieRecorder.Report, Error>],
                                  program: MovieRecorder.Report?) {
        var files: [SourceID: URL] = [:]
        for (id, result) in results {
            if case .success(let report) = result { files[id] = report.url }
        }
        lastISOFiles = files
        isoStatuses = [:]

        // Export needs the program clip + the shared start; without them there
        // is nothing to place ISO angles against.
        guard let program, let start = isoSessionStart, let directory = isoSessionDir else {
            lastMulticamExportable = false
            return
        }
        let programSource = SourceID("program")
        var meta = isoSessionMeta
        // sol wave-16 #1: a DEFERRED angle's meta was recorded with provisional
        // canvas dims at start (its native format was unknown then). By finish the
        // native-format probe has seen the source's frames — refresh each angle's
        // export dims to the native truth so FCPXML places the clip at its real size.
        for (id, m) in meta {
            if let native = isoTap.formats.format(for: id), native.width != m.width || native.height != m.height {
                meta[id] = FinishedMulticamSession.AngleMeta(
                    name: m.name, width: native.width, height: native.height,
                    fps: m.fps, hasAudio: m.hasAudio)
            }
        }
        meta[programSource] = FinishedMulticamSession.AngleMeta(
            name: "Program", width: Self.canvasSize.width, height: Self.canvasSize.height,
            fps: 60, hasAudio: program.audioBuffersWritten > 0)

        lastFinishedSession = FinishedMulticamSession(
            projectName: isoSessionProjectName ?? "Prism Multicam",
            directory: directory,
            sessionStart: start,
            programSource: programSource,
            program: program,
            isoResults: results,
            meta: meta)
        lastMulticamExportable = true
    }

    private func startISOStatusTimer() {
        isoStatusTimer?.invalidate()
        isoStatusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let bank = self.isoBank else { return }
                var statuses: [SourceID: String] = [:]
                for id in bank.activeSourceIDs {
                    if let s = bank.status(for: id) {
                        statuses[id] = "\(s.state.rawValue) · \(s.videoFramesWritten) frames"
                    }
                }
                self.isoStatuses = statuses
            }
        }
    }

    private func stopISOStatusTimer() {
        isoStatusTimer?.invalidate()
        isoStatusTimer = nil
    }

    #if DEBUG
    /// sol #1 test seam: the ACTUAL per-source settings configured on a live ISO
    /// recorder (native width/height + dynamic range), so a test can prove the
    /// angle is recorded natively rather than a hardcoded 1080p/H.264/SDR.
    func _test_isoRecorderSettings(for id: SourceID) -> RecordingSettings? {
        isoBank?.settings(for: id)
    }

    /// sol #2 test seam: the program recorder's settings (`includeAudio` reflects
    /// the record-audio decision) and whether the master-mix tap is armed to feed it.
    var _test_programRecorderSettings: RecordingSettings? { recorder?.settings }
    var _test_fanOutWantsAudio: Bool { fanOut._test_recorderWantsAudio }

    /// sol #1 test seam: register a video source armed for ISO WITHOUT any live
    /// capture (no TCC), and prime its native-format probe with one representative
    /// raw frame — exactly what a live 640×480 / 10-bit-HLG source would deliver.
    func _test_addSyntheticISOSource(id: SourceID, nativeFrame: VideoFrame, name: String = "Synthetic ISO") {
        let descriptor = SourceDescriptor(kind: .camera, id: id.raw, name: name)
        activeSources.append(ActiveSource(id: id, descriptor: descriptor,
                                          backing: .generated(_TestStubVideoSource(id: id)),
                                          mailbox: FrameMailbox()))
        isoArmedSourceIDs.insert(id)
        isoTap.append(nativeFrame) // populate the native-format probe as a real capture would
    }

    /// sol wave-16 #1 test seam: register a video source armed for ISO whose FIRST
    /// frame has NOT arrived yet (the async-start window) — the native-format probe
    /// is left empty, exactly as a source armed before delivering any frame. The
    /// recorder must be DEFERRED until the first frame (fed via `_test_feedISOFrame`).
    func _test_addSyntheticISOSourceNoFrame(id: SourceID, name: String = "Synthetic ISO (no frame)") {
        let descriptor = SourceDescriptor(kind: .camera, id: id.raw, name: name)
        activeSources.append(ActiveSource(id: id, descriptor: descriptor,
                                          backing: .generated(_TestStubVideoSource(id: id)),
                                          mailbox: FrameMailbox()))
        isoArmedSourceIDs.insert(id)
    }

    /// sol wave-16 test seam: route a raw per-source frame through the ISO tap
    /// exactly as a live capture callback would (updates the native-format probe and,
    /// once recording, materializes/feeds the source's recorder).
    func _test_feedISOFrame(_ frame: VideoFrame) { isoTap.append(frame) }

    /// sol wave-16 #1 test seam: the finalized ISO file for a source after Stop.
    func _test_lastISOFile(for id: SourceID) -> URL? { lastISOFiles[id] }

    /// sol HIGH #2 test seams: prove Stop/Start bank ownership.
    /// The current live ISO bank instance (identity), so a test can assert a Stop
    /// finalized its OWN bank and a concurrent Start installed a distinct one.
    func _test_isoBankInstance() -> ISORecorderBank? { isoBank }
    func _test_multitrackBankInstance() -> AudioTrackRecorderBank? { multitrackBank }

    /// sol HIGH #2: fired synchronously inside `stopRecordingReportingClaim` at the
    /// exact window where a Start B could interleave (the original vertical-await
    /// suspension point). A test installs a Start B here to drive the race
    /// deterministically without needing a live vertical recorder / real frames.
    nonisolated(unsafe) static var _test_stopMidVerticalHook: (() -> Void)?

    /// sol HIGH #2 NEGATIVE CONTROL: reinstates the pre-fix ordering (capture the
    /// ISO/multitrack banks AFTER the vertical await) so a test can reproduce the
    /// cross-finalization + stranding the fix prevents.
    nonisolated(unsafe) static var _test_captureBanksAfterVerticalAwait = false

    /// sol HIGH #1 test seam: deliver a program frame straight to the record
    /// fan-out (bypassing the render loop) so a headless test can finalize a REAL
    /// program `.mov` and assert two rapid takes land at distinct, non-clobbering
    /// paths.
    func _test_deliverProgramFrame(_ frame: VideoFrame) { fanOut.handle(frame) }

    /// sol #17 test seam: number of encoded frames currently in the replay ring,
    /// so a headless test can poll for the async encoder delivery to land before
    /// saving a clip/replay.
    func _test_replayBufferedFrameCount() -> Int { replayBuffer?.status.frameCount ?? 0 }
    #endif

    // MARK: - Replay buffer (deliverable 2)

    /// Configure the replay window length (rebuilds the ring if already armed).
    func setReplayLength(_ seconds: Double) {
        let clamped = min(300, max(5, seconds))
        guard clamped != replayLengthSeconds else { return }
        replayLengthSeconds = clamped
        if replayArmed { setReplayArmed(false); setReplayArmed(true) }
    }

    /// Arm/disarm the instant-replay ring. Arming spins up a dedicated program
    /// encoder whose encoded frames feed the ring via the fan-out tap.
    func setReplayArmed(_ armed: Bool) {
        guard armed != replayArmed else { return }
        if armed {
            let buffer = ReplayBuffer(seconds: replayLengthSeconds)
            // HDR sink-parity (Stage O): an HDR show buffers 10-bit HEVC Main10 /
            // Rec.2020-HLG so a saved replay matches the HDR recording (was 8-bit
            // H.264). SDR unchanged.
            let encoder = ProgramEncoder(settings: .init(codec: .h264,
                                                         width: Self.canvasSize.width,
                                                         height: Self.canvasSize.height,
                                                         averageBitrate: 12_000_000,
                                                         expectedFrameRate: 60,
                                                         dynamicRange: hdrEnabled ? .hdr : .sdr))
            encoder.onEncodedFrame = { [buffer] sampleBuffer in buffer.append(sampleBuffer) }
            do {
                try encoder.start()
            } catch {
                lastError = "Replay encoder failed to start: \(error.localizedDescription)"
                return
            }
            replayBuffer = buffer
            replayEncoder = encoder
            fanOut.setReplayEncoder(encoder)
            // Route the master-mix audio into the ring too, so a saved clip has
            // sound (deliverable 3b). ReplayBuffer.appendAudio is engine-wired;
            // this is the app-side connection of program audio → ring.
            fanOut.setReplayBuffer(buffer)
            replayArmed = true
            startReplayStatusTimer()
        } else {
            fanOut.setReplayEncoder(nil)
            fanOut.setReplayBuffer(nil)
            replayEncoder?.stop()
            replayEncoder = nil
            replayBuffer = nil
            replayArmed = false
            replayBufferedSeconds = 0
            replayStatusTimer?.invalidate(); replayStatusTimer = nil
        }
    }

    /// Save the buffered window to ~/Movies/Prism/Replays and reveal it.
    /// Errors surfaced by `saveReplayAsync` (so the Save Replay App Intent can
    /// throw the real outcome to Shortcuts — Codex #6).
    enum ReplayError: LocalizedError {
        case notArmed
        var errorDescription: String? {
            switch self {
            case .notArmed: return "Instant replay isn't armed — nothing buffered to save."
            }
        }
    }

    /// Save the buffered instant-replay window, returning the written clip URL or
    /// throwing on failure. The App Intent awaits this so Shortcuts sees the real
    /// success/failure instead of a fire-and-forget task's deferred `lastError`
    /// (Codex #6). `saveReplay()` wraps it for UI callers (surfaces via lastError).
    @discardableResult
    func saveReplayAsync() async throws -> URL {
        guard let buffer = replayBuffer else { throw ReplayError.notArmed }
        let directory = URL(filePath: NSHomeDirectory()).appending(path: "Movies/Prism/Replays")
        // sol #17 (data loss): a second-resolution name let two rapid replays pick
        // the identical path → the later save destroyed the earlier clip. Millisecond
        // timestamp + a monotonic counter makes each save's path unique; `saveClip`
        // additionally resolves a non-clobbering sibling as a last-line guard.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        clipSaveCounter &+= 1
        let url = directory.appending(path: "Replay \(formatter.string(from: Date())) (\(clipSaveCounter)).mov")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let report = try await buffer.saveClip(to: url)
        lastReplayURL = report.url
        NSWorkspace.shared.activateFileViewerSelecting([report.url])
        return report.url
    }

    func saveReplay() {
        Task { @MainActor in
            do { _ = try await saveReplayAsync() }
            catch { lastError = "Couldn't save replay: \(error.localizedDescription)" }
        }
    }

    func revealLastReplay() {
        guard let url = lastReplayURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func startReplayStatusTimer() {
        replayStatusTimer?.invalidate()
        replayStatusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let buffer = self.replayBuffer else { return }
                self.replayBufferedSeconds = buffer.status.bufferedDuration.seconds
            }
        }
    }

    // MARK: - FCPXML export (deliverable 4)

    /// Build a Final Cut multicam project from the last multi-angle session and
    /// reveal the written `.fcpxml`. No-op (and disabled in the UI) when no such
    /// session exists.
    func exportFinalCutProject() {
        guard let session = lastFinishedSession else { return }
        let multicam = FCPXMLExporter.makeSession(
            projectName: session.projectName,
            sessionStart: session.sessionStart,
            frameRate: .fps60,
            width: Self.canvasSize.width,
            height: Self.canvasSize.height,
            program: (report: session.program, source: session.programSource),
            isoResults: session.isoResults,
            metadata: { id in
                let m = session.meta[id]
                return FCPXMLExporter.AngleMetadata(
                    name: m?.name ?? id.raw,
                    width: m?.width ?? Self.canvasSize.width,
                    height: m?.height ?? Self.canvasSize.height,
                    fps: m?.fps ?? 60,
                    hasAudio: m?.hasAudio ?? false)
            })
        // sol #17 (data-loss class): the exporter overwrites any existing file at
        // the target path, and the name is a fixed `<projectName>.fcpxml`. Two
        // exports of the same session (or two sessions sharing a project name +
        // directory) would destroy the earlier `.fcpxml`. Resolve a non-clobbering
        // sibling so an export never overwrites a prior export.
        let url = RecorderFilePath.nonClobbering(
            session.directory.appending(path: "\(session.projectName).fcpxml"))
        do {
            try FCPXMLExporter.write(session: multicam, to: url)
            lastExportedFCPXMLURL = url
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            lastError = "Final Cut export failed: \(error.localizedDescription)"
        }
    }

    func revealLastRecording() {
        guard let url = lastRecordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Virtual camera

    func activateVirtualCameraExtension() {
        guard !vcamActivationInFlight else { return }
        vcamActivationInFlight = true
        vcamInstallStatus = "Requesting activation…"
        installer.onPhaseChange = { [weak self] phase in
            DispatchQueue.main.async { self?.vcamInstallStatus = Self.describe(phase) }
        }
        Task { @MainActor in
            do {
                let phase = try await installer.activate()
                vcamInstallStatus = Self.describe(phase)
            } catch {
                vcamInstallStatus = """
                Activation failed: \(error.localizedDescription) — note: unsigned/ad-hoc \
                builds can't install system extensions. Sign with a team, run from \
                /Applications (or enable `systemextensionsctl developer on`), then retry.
                """
            }
            vcamActivationInFlight = false
        }
    }

    func setVirtualCameraOutput(_ enabled: Bool) {
        vcamOutputRequested = enabled
        if enabled {
            // C30: do NOT flip vcamOutputEnabled/isOnAir here — the feeder
            // starts asynchronously (search → attach). onStateChange sets
            // vcamOutputEnabled once the feeder confirms `.feeding`.
            feeder.start()
            fanOut.setFeeder(feeder)
        } else {
            vcamOutputEnabled = false
            fanOut.setFeeder(nil)
            feeder.stop()
        }
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

    // MARK: Global-hotkeys support (read-only view for the toggle-stream policy)

    /// Whether a single-RTMP "quick path" target is fully configured. The
    /// global toggle-stream hotkey reads this (via `StreamStartPolicy`) so it can
    /// start the user's saved target instead of inventing a URL. `configured*`
    /// are private, so this thin accessor lives here rather than in an extension.
    var hotKeyHasConfiguredStreamTarget: Bool {
        guard let url = configuredStreamURL, let key = configuredStreamKey else { return false }
        return !url.isEmpty && !key.isEmpty
    }

    /// Count of enabled restream destinations — the fallback broadcast target for
    /// the toggle-stream hotkey when no single-RTMP quick target is configured.
    var hotKeyEnabledDestinationCount: Int { destinations.filter(\.enabled).count }

    // MARK: Control server (obs-websocket, port 4455)

    func setControlServer(_ enabled: Bool) {
        if enabled {
            do {
                try controlServer.start()
                controlServerRunning = true
            } catch {
                controlServerRunning = false
                lastError = "Control server failed to start: \(error.localizedDescription)"
            }
        } else {
            controlServer.stop()
            controlServerRunning = false
        }
    }

    // MARK: - Preflight "Broadcast Check" (deliverable 2)

    /// Run every preflight check and publish the report. Disk, thermal, encoder
    /// trial, and the source/listener checks are fast; the RTMP host probe does
    /// a bounded (≤4 s) TCP connect. Safe to run repeatedly and headless.
    @discardableResult
    func runBroadcastCheck() async -> BroadcastReport {
        // Re-entrancy guard (Codex): the debug-timer auto-run and the sheet's
        // .task must not overlap and race on lastBroadcastReport. The guard+set
        // is atomic here (synchronous until the first await).
        guard !isRunningBroadcastCheck else {
            return lastBroadcastReport ?? BroadcastReport(results: [], generatedAt: Date())
        }
        isRunningBroadcastCheck = true
        defer { isRunningBroadcastCheck = false }

        // Snapshot the main-actor state the off-main probes need.
        let home = URL(filePath: NSHomeDirectory())
        // Codex #3: a HW encoder is already demonstrably working when we're live
        // or recording — skip the trial rather than open a contending 3rd session.
        let encoderInUse = isStreaming || isRecording

        // Codex #2: the synchronous probes (disk stat + a VTCompressionSession
        // trial, tens–hundreds of ms) run OFF the main actor so the sheet and the
        // render loop never hitch. @Published writes stay on main (below).
        let (diskResult, thermalResult, encoderResult) = await Task.detached {
            (BroadcastCheck.diskCheck(directory: home),
             BroadcastCheck.thermalCheck(),
             BroadcastCheck.encoderTrial(encoderInUse: encoderInUse))
        }.value

        var results: [CheckResult] = [diskResult, thermalResult, encoderResult]
        // A video source and an audio source exist.
        results.append(sourcesCheck())
        // RTMP host reachability (bounded TCP probe; warns/skips with no target).
        results.append(await rtmpHostCheck())
        // Pairing / link-listener state.
        results.append(listenerCheck())

        let report = BroadcastReport(results: results, generatedAt: Date())
        lastBroadcastReport = report
        writeLinkDebugState()
        return report
    }

    /// Do a video AND an audio source exist? No video is a blocker; video but
    /// no audio is a warning (silent broadcast).
    private func sourcesCheck() -> CheckResult {
        let hasVideo = activeSources.contains(where: \.isVideo)
        let hasAudio = activeSources.contains(where: \.isAudio)
        if !hasVideo {
            return CheckResult(id: "sources", title: "Sources", status: .fail,
                               message: "No video source added — nothing to broadcast.")
        }
        if !hasAudio {
            return CheckResult(id: "sources", title: "Sources", status: .warn,
                               message: "A video source is present, but no audio source — the broadcast will be silent.")
        }
        return CheckResult(id: "sources", title: "Sources", status: .pass,
                           message: "Video and audio sources are present.")
    }

    /// TCP-connect probe against the configured RTMP host. With no target
    /// configured this warns (skipped) rather than fails; an unreachable host
    /// warns (could be a firewall or a not-yet-open ingest) rather than blocks.
    private func rtmpHostCheck() async -> CheckResult {
        guard let urlString = configuredStreamURL, !urlString.isEmpty,
              let comps = URLComponents(string: urlString), let host = comps.host, !host.isEmpty else {
            return CheckResult(id: "network", title: "Stream host", status: .warn,
                               message: "No RTMP target configured — skipped.")
        }
        let port = UInt16(comps.port ?? 1935)
        let reachable = await BroadcastCheck.tcpProbe(host: host, port: port)
        if reachable {
            return CheckResult(id: "network", title: "Stream host", status: .pass,
                               message: "Reached \(host):\(port).")
        }
        return CheckResult(id: "network", title: "Stream host", status: .warn,
                           message: "Couldn't reach \(host):\(port) — check the URL, network, or ingest availability.")
    }

    /// Link listener / pairing readiness (device sources come in over this).
    private func listenerCheck() -> CheckResult {
        if let port = linkPort, linkListenerState == "ready" {
            let devices = peers.isEmpty ? "no devices yet" : "\(peers.count) device\(peers.count == 1 ? "" : "s")"
            return CheckResult(id: "listener", title: "Device link", status: .pass,
                               message: "Listener ready on UDP \(port) · \(devices).")
        }
        return CheckResult(id: "listener", title: "Device link", status: .warn,
                           message: "Link listener \(linkListenerState).")
    }

    // MARK: - Per-source effects (deliverable 1)

    /// Lazily builds and registers a capture-thread effect pipeline for a video
    /// source. Returns nil if Metal is unavailable (frames pass through untouched).
    private func makeEffectPipeline(for id: SourceID) -> SourceEffectPipeline? {
        guard let device = metalDevice else { return nil }
        let pipeline = SourceEffectPipeline(device: device, sourceID: id)
        pipeline.onGradeComputed = { [weak self] sid, grade in
            DispatchQueue.main.async { self?.gradeComputed(sid, grade) }
        }
        // Seed the tempo clock so a source added mid-beat immediately picks up
        // beat-synced tile/pulse timing (BEAT_SYNC_DESIGN).
        pipeline.setBeatClock(beatSequencer?.beatClock ?? .stopped)
        effectPipelines[id] = pipeline
        sourceEffects[id] = SourceEffects()
        // F5: register so the render tick evaluates this source's time-varying
        // effects at the tick PTS. `hasAnimatedEffect` gates the actual work, so
        // registering unconditionally is cheap (a nil-check per tick until an
        // animated effect is set).
        animatedFXDriver.register(id, pipeline)
        return pipeline
    }

    /// Debug-only exerciser for the CRITICAL alpha fix (PRISM_DEBUG_ALPHA_LAYERS).
    /// Adds two generated sources (background + foreground) and enables
    /// background-remove on the top one, flipping its Layer.premultipliedAlpha to
    /// true. The state file's `layers` array then shows premultipliedAlpha=true on
    /// the top layer while programCompositeErrors stays 0. Camera-free.
    private func debugAddAlphaLayers() {
        addTextSource(text: "ALPHA-BG", fontSize: 200, color: .white)    // bottom layer
        addTextSource(text: "ALPHA-FG", fontSize: 140,
                      color: RGBAColor(r: 0, g: 1, b: 0, a: 1))          // top layer (green)
        guard let top = scene.layers.max(by: { $0.zIndex < $1.zIndex }) else { return }
        setBackground(.remove, for: top.sourceID) // → premultipliedAlpha=true on the top layer
    }

    /// Debug-only exerciser for the LUMA key path (PRISM_DEBUG_LUMA_LAYERS).
    /// Adds two generated sources and enables a luma key on the top one, flipping
    /// its Layer.premultipliedAlpha to true (mirrors debugAddAlphaLayers for the
    /// background-remove path). The state file's `layers` array then shows
    /// premultipliedAlpha=true on the top layer while programCompositeErrors stays
    /// 0 — proving the luma keyer is wired end-to-end without a camera.
    private func debugAddLumaLayers() {
        addTextSource(text: "LUMA-BG", fontSize: 200, color: .white)     // bottom layer
        addTextSource(text: "LUMA-FG", fontSize: 140,
                      color: RGBAColor(r: 1, g: 1, b: 1, a: 1))          // top layer (bright)
        guard let top = scene.layers.max(by: { $0.zIndex < $1.zIndex }) else { return }
        setLumaKey(.brightBackground, for: top.sourceID) // → premultipliedAlpha=true on the top layer
    }

    /// Number of sources whose effect chain would change pixels (debug/telemetry).
    var activeEffectsCount: Int {
        sourceEffects.values.filter(\.isActive).count
    }

    /// Set the color grade for a source. Identity grade is the cost-free default.
    func setGrade(_ grade: ColorGrade, for id: SourceID) {
        guard let pipeline = effectPipelines[id] else { return }
        var fx = sourceEffects[id] ?? SourceEffects()
        fx.grade = grade
        sourceEffects[id] = fx
        pipeline.update(fx)
    }

    /// Load (or clear, when `url == nil`) a .cube LUT for a source. Returns
    /// `true` iff the engine adopted the change, so the UI only reflects a LUT
    /// name after the load actually succeeded (W11); a parse failure returns
    /// `false` and surfaces via `lastError`.
    @discardableResult
    func setLUT(url: URL?, for id: SourceID) -> Bool {
        guard let pipeline = effectPipelines[id] else { return false }
        var fx = sourceEffects[id] ?? SourceEffects()
        if let url {
            do { fx.lut = try CubeLUT(contentsOf: url) }
            catch {
                lastError = "Couldn't load LUT: \(error.localizedDescription)"
                return false
            }
        } else {
            fx.lut = nil
        }
        sourceEffects[id] = fx
        pipeline.update(fx)
        return true
    }

    /// Set (or clear, when `mode == nil`) the background effect for a source.
    /// A non-nil mode spins up a per-source PersonSegmenter inside the pipeline.
    func setBackground(_ mode: BackgroundMode?, for id: SourceID) {
        guard let pipeline = effectPipelines[id] else { return }
        var fx = sourceEffects[id] ?? SourceEffects()
        fx.background = mode
        // Chroma/luma key and background-`remove` are mutually-exclusive keying
        // paths (Codex C2): running two feeds a keyed frame into a second keying
        // stage, whose shader ignores incoming alpha → opaque black. Enabling
        // remove clears any chroma OR luma key.
        if mode == .remove { fx.chromaKey = nil; fx.lumaKey = nil }
        sourceEffects[id] = fx
        pipeline.update(fx)
        updateLayerPremultipliedAlpha(for: id)
    }

    /// Enable/clear a green/blue-screen chroma key for a source. Like
    /// background-`remove`, a non-nil key makes the source output premultiplied
    /// alpha, so this also flips the source's Layer.premultipliedAlpha (below).
    /// Chroma key and segmentation-`remove` are alternative keying paths.
    func setChromaKey(_ key: ChromaKey?, for id: SourceID) {
        guard let pipeline = effectPipelines[id] else { return }
        var fx = sourceEffects[id] ?? SourceEffects()
        fx.chromaKey = key
        // Mutually exclusive with the luma key and background-`remove` (Codex C2).
        if key != nil {
            fx.lumaKey = nil
            if fx.background == .remove { fx.background = nil }
        }
        sourceEffects[id] = fx
        pipeline.update(fx)
        updateLayerPremultipliedAlpha(for: id)
    }

    /// Enable/clear a luminance key (bright/dark backdrop) for a source. Like
    /// the chroma key and background-`remove`, a non-nil key emits premultiplied
    /// alpha, so this flips the source's Layer.premultipliedAlpha. Mutually
    /// exclusive with the chroma key and background-`remove`.
    func setLumaKey(_ key: LumaKey?, for id: SourceID) {
        guard let pipeline = effectPipelines[id] else { return }
        var fx = sourceEffects[id] ?? SourceEffects()
        // Codex #10: normalize so lowLuma ≤ highLuma. Crossed bounds (low > high)
        // describe an empty keep-band that would key the ENTIRE source to
        // transparent (a wiped layer); swap them so the band is always valid.
        var normalized = key
        if var k = normalized, k.lowLuma > k.highLuma {
            swap(&k.lowLuma, &k.highLuma)
            normalized = k
        }
        fx.lumaKey = normalized
        if key != nil {
            fx.chromaKey = nil
            if fx.background == .remove { fx.background = nil }
        }
        sourceEffects[id] = fx
        pipeline.update(fx)
        updateLayerPremultipliedAlpha(for: id)
    }

    /// Toggle matte-view for a source: renders whichever keyer is active (chroma
    /// or luma) as its grayscale matte so an operator can tune the key. No effect
    /// when no keyer is set; never changes the layer's premultipliedAlpha.
    func setMatteView(_ on: Bool, for id: SourceID) {
        guard let pipeline = effectPipelines[id] else { return }
        var fx = sourceEffects[id] ?? SourceEffects()
        guard fx.matteView != on else { return }
        fx.matteView = on
        sourceEffects[id] = fx
        pipeline.update(fx)
    }

    /// Enable/clear the tile/grid mask (Build A) for a source. A non-nil effect
    /// punches an animated grid of transparent holes into the frame, so this
    /// source outputs premultiplied alpha — the compositor then reveals the
    /// LAYERS BENEATH through the holes. The layer's `premultipliedAlpha` flag is
    /// flipped true below (else the holes composite as opaque black). The reveal
    /// only reads when a layer sits under this one.
    func setTileEffect(_ tile: TileEffect?, for id: SourceID) {
        guard let pipeline = effectPipelines[id] else { return }
        var fx = sourceEffects[id] ?? SourceEffects()
        if var t = tile {
            // (Re)start the one-shot progress epoch on first enable or a mode
            // change; otherwise preserve it so tweaking rows/softness/speed does
            // not restart the reveal mid-animation.
            if let prev = fx.tile, prev.mode == t.mode {
                t.startHostSeconds = prev.startHostSeconds
            } else {
                t.startHostSeconds = HouseClock.nowSeconds()
            }
            fx.tile = t
        } else {
            fx.tile = nil
        }
        sourceEffects[id] = fx
        pipeline.update(fx)
        updateLayerPremultipliedAlpha(for: id) // tile → premultipliedAlpha=true
        saveSourceFX(for: id)
    }

    /// Enable/clear the video wall (Build C) for a source: tile it into an N×M
    /// grid (kaleidoscope with `mirror`). Opaque output — no premultiplied-alpha
    /// change (but the sync call is harmless if a keyer is also active).
    func setVideoWall(_ wall: VideoWall?, for id: SourceID) {
        guard let pipeline = effectPipelines[id] else { return }
        var fx = sourceEffects[id] ?? SourceEffects()
        fx.videoWall = wall
        sourceEffects[id] = fx
        pipeline.update(fx)
        updateLayerPremultipliedAlpha(for: id)
        saveSourceFX(for: id)
    }

    /// Enable/clear the beat pulse (BEAT_SYNC_DESIGN) for a source: scale/shake on
    /// the beat, driven by the live `BeatClock`. Opaque output — no premultiplied-
    /// alpha change. Identity (no pulse) while the sequencer is stopped.
    func setBeatPulse(_ pulse: BeatPulseEffect?, for id: SourceID) {
        guard let pipeline = effectPipelines[id] else { return }
        var fx = sourceEffects[id] ?? SourceEffects()
        fx.pulse = pulse
        sourceEffects[id] = fx
        pipeline.update(fx)
        saveSourceFX(for: id)
    }
    func beatPulse(for id: SourceID) -> BeatPulseEffect? { sourceEffects[id]?.pulse }

    /// Enable/clear the strobe/flash for a source: a full-frame color flash on the
    /// beat (or a free-run timer). Opaque output — no premultiplied-alpha change.
    /// The free-run epoch is (re)started on first enable so the flash begins from a
    /// clean phase; tweaking intensity/color/rate preserves it (no restart jump).
    func setStrobe(_ strobe: StrobeEffect?, for id: SourceID) {
        guard let pipeline = effectPipelines[id] else { return }
        var fx = sourceEffects[id] ?? SourceEffects()
        if var s = strobe {
            if let prev = fx.strobe {
                s.startHostSeconds = prev.startHostSeconds
            } else {
                s.startHostSeconds = HouseClock.nowSeconds()
            }
            fx.strobe = s
        } else {
            fx.strobe = nil
        }
        sourceEffects[id] = fx
        pipeline.update(fx)
        saveSourceFX(for: id) // strobe survives relaunch + source-reselect (feature 5)
    }
    func strobe(for id: SourceID) -> StrobeEffect? { sourceEffects[id]?.strobe }

    /// LOAD-BEARING alpha fix (Codex C1): keep the source's scene Layer's
    /// `premultipliedAlpha` in lock-step with whether its effect chain emits
    /// premultiplied-alpha frames (chroma key OR background-`remove`). Without
    /// this the keyed/segmented transparency composites as OPAQUE BLACK. Only
    /// mutates (and republishes the scene) when the flag actually changes.
    /// Whether a source's layer must composite with its alpha honored. True for
    /// generated text/image/browser sources (they render a transparent
    /// background) OR when an effect (chroma/luma key, background-remove)
    /// produces a matte. Single source of truth for every premultipliedAlpha
    /// decision, so overlays survive collection save/load and effect toggles.
    func layerNeedsPremultipliedAlpha(_ id: SourceID) -> Bool {
        let isGenerated = activeSources.first(where: { $0.id == id }).map {
            if case .generated = $0.backing { return true }
            return false
        } ?? false
        // A transparent presenter cutout emits premultiplied alpha (person opaque,
        // background alpha-out) — its layer must honor that alpha. A solid-colour
        // cutout is opaque, so it does NOT flip the flag.
        let cutoutTransparent = cutoutStates[id]?.background == .transparent
        // A movie whose codec carries alpha (ProRes 4444) emits premultiplied
        // transparent pixels — its layer MUST honor that alpha, else the compositor
        // forces sampled alpha to 1 and a transparent pixel composites as opaque
        // black over the layers beneath (Class C). Only the meme movie path set
        // this before; an ordinary alpha movie was flattened.
        let movieAlpha = movieSources[id]?.source.hasAlphaChannel ?? false
        return isGenerated || cutoutTransparent || movieAlpha
            || (sourceEffects[id]?.producesPremultipliedAlpha ?? false)
    }

    private func updateLayerPremultipliedAlpha(for id: SourceID) {
        let premultiplied = layerNeedsPremultipliedAlpha(id)
        guard let index = scene.layers.firstIndex(where: { $0.sourceID == id }),
              scene.layers[index].premultipliedAlpha != premultiplied else { return }
        mutateLayer(id) { $0.premultipliedAlpha = premultiplied }
    }

    /// Analyze the next frame (FrameAnalyzer) and adopt AutoColor's suggested
    /// grade for the source; the resulting grade lands in `sourceEffects`.
    func loadAutoColor(for id: SourceID) {
        effectPipelines[id]?.requestAutoColor()
    }

    /// Main-actor mirror update when the pipeline resolves an auto-color pass.
    private func gradeComputed(_ id: SourceID, _ grade: ColorGrade) {
        guard var fx = sourceEffects[id] else { return }
        fx.grade = grade
        sourceEffects[id] = fx
    }

    // MARK: - Audio mixer (deliverable 2)

    /// Starts the mixer engine on first use (opening the default output device).
    /// Idempotent; failure degrades gracefully (channels still ingest, but the
    /// master tap won't fire without a running engine).
    private func ensureAudioMixerStarted() {
        guard !audioMixerStarted else { return }
        do {
            try audioMixer.start()
            audioMixerStarted = true
            startMeterTimer()
        } catch {
            lastError = "Audio mixer failed to start: \(error.localizedDescription)"
        }
    }

    private func startMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop, so main-actor isolation holds.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mixerMasterLevel = self.audioMixer.masterPeakLevel().linear
                let m = self.loudnessMeter.measurement
                let readout = LoudnessReadout(momentary: m.momentary, shortTerm: m.shortTerm,
                                              integrated: m.integrated, truePeak: m.truePeak)
                if readout != self.masterLoudness { self.masterLoudness = readout } // Codex #5: don't republish unchanged
                // Flagship: sample program loudness on the existing meter cadence and
                // feed it as a `.loudness` highlight signal (one bool when off).
                if self.directorsCutEnabled {
                    self.feedLoudnessToDirector(momentaryLUFS: m.momentary, at: HouseClock.now())
                }
                var states: [SourceID: ChannelState] = [:]
                for id in self.audioMixer.channelIDs {
                    guard let ch = self.audioMixer.channel(id: id) else { continue }
                    states[id] = ChannelState(peakLinear: ch.peakLevel().linear,
                                              gain: ch.gain, isMuted: ch.isMuted, isSolo: ch.isSolo,
                                              insertCount: ch.insertCount,
                                              voiceIsolationEnabled: ch.isVoiceIsolationEnabled)
                }
                self.channelStates = states
            }
        }
    }

    /// Add system audio as a source (macOS 14.2+; throws below that). Appears in
    /// `activeSources` as a `.systemAudio` backing and feeds its own mixer channel.
    func addSystemAudio() {
        let id = SourceID("system-audio") // distinct from AudioMixer.masterSourceID ("mixer.master")
        guard !isActive(id) else { return }
        do {
            let source = try SystemAudioCapture.makeSource(id: id)
            ensureAudioMixerStarted()
            let channel = try audioMixer.addChannel(id: id)
            source.onAudio = { [multitrackTap] packet in
                channel.ingest(packet)
                multitrackTap.append(packet) // no-op unless a multitrack session is live
            }
            do {
                try source.start()
            } catch {
                // start() threw AFTER the mixer channel was registered — remove
                // it so a retry works and no MixerChannel/AVAudioNode leaks (W3).
                audioMixer.removeChannel(id: id)
                throw error
            }
            systemAudioSource = source
            let descriptor = SourceDescriptor(kind: .systemAudio, id: id.raw,
                                              name: "System Audio")
            register(ActiveSource(id: id, descriptor: descriptor,
                                  backing: .systemAudio(source), mailbox: nil))
        } catch {
            lastError = "Couldn't add system audio: \(error.localizedDescription)"
        }
    }

    /// Whether system audio is currently captured (macOS 14.2+ always available
    /// at this deployment target; false until added).
    var isSystemAudioActive: Bool { systemAudioSource != nil }

    func setChannelGain(_ gain: Float, for id: SourceID) {
        audioMixer.channel(id: id)?.gain = gain
    }

    func setChannelMuted(_ muted: Bool, for id: SourceID) {
        audioMixer.channel(id: id)?.isMuted = muted
    }

    func setChannelSolo(_ solo: Bool, for id: SourceID) {
        audioMixer.channel(id: id)?.isSolo = solo
    }

    // MARK: Channel inserts + voice isolation (deliverable 2)

    /// The installed AU effects available to load as inserts (queried once at
    /// launch). Thin pass-through so the UI never touches the private mixer.
    func availableAudioEffects() -> [MixerChannel.AudioEffectComponent] { audioEffectCatalog }

    /// Replace a channel's ordered AUv3 insert chain. AU instantiation is async
    /// (3rd-party AUv3 load out-of-process), so the graph re-wire happens in a
    /// Task; `channelInserts` is mirrored optimistically and rolled back on a
    /// load failure (which surfaces via `lastError`). Pass `[]` to clear.
    func setChannelInserts(_ effects: [MixerChannel.AudioEffectComponent], for id: SourceID) {
        guard let channel = audioMixer.channel(id: id) else { return }
        // Codex #2/#6: supersede any in-flight edit for this channel. Cancel the
        // previous task and bump a per-channel generation token so only THIS
        // (latest-issued) edit is allowed to touch the live graph + the mirror.
        let superseded = channelInsertTasks[id]
        superseded?.cancel()
        let generation = (channelInsertGeneration[id] ?? 0) &+ 1
        channelInsertGeneration[id] = generation
        let previous = channelInserts[id]
        channelInserts[id] = effects                 // optimistic mirror for the editor
        let descriptions = effects.map(\.description)
        let task = Task { @MainActor [weak self] in
            // Let the superseded edit fully settle first, so the graph is re-wired
            // in CALL order — the latest-issued edit wins the live graph, not
            // whichever task happened to acquire the channel lock last (#6).
            await superseded?.value
            guard let self, self.channelInsertGeneration[id] == generation else { return }
            do {
                try await channel.setInserts(descriptions)
            } catch {
                // A newer edit may have superseded us while the AUv3 loaded; only
                // roll back / report if we're still the current edit.
                if self.channelInsertGeneration[id] == generation {
                    self.lastError = "Couldn't load audio insert: \(error.localizedDescription)"
                    self.channelInserts[id] = previous   // roll back — engine left the chain intact
                    self.channelInsertTasks[id] = nil
                }
                return
            }
            // Reconcile the mirror to what was actually applied — but only when we
            // are still the latest edit (else the newer edit owns graph + mirror).
            guard self.channelInsertGeneration[id] == generation else { return }
            self.channelInserts[id] = effects
            self.channelInsertTasks[id] = nil
        }
        channelInsertTasks[id] = task
    }

    /// Toggle per-source voice isolation / noise removal (deliverable 2).
    func setChannelVoiceIsolation(_ enabled: Bool, for id: SourceID) {
        audioMixer.channel(id: id)?.setVoiceIsolation(enabled)
    }

    /// Route the master mix to the default output device (local monitoring).
    func setAudioMonitoring(_ enabled: Bool) {
        audioMixer.isMonitoringEnabled = enabled
    }

    /// Sidechain ducking (deliverable 4): attenuate `target` when `key` gets
    /// loud (music-under-voice). Both channels must exist; failure surfaces via
    /// `lastError`. `clearDucking` removes the rule.
    func setDucking(target: SourceID, key: SourceID, config: DuckingConfig) {
        guard target != key else {
            lastError = "Ducking target and key must be different channels."
            return
        }
        do { try audioMixer.setDucking(target: target, key: key, config: config) }
        catch { lastError = "Couldn't set ducking: \(error.localizedDescription)" }
    }

    func clearDucking(target: SourceID) {
        audioMixer.clearDucking(target: target)
    }

    var isAudioMonitoringEnabled: Bool { audioMixer.isMonitoringEnabled }

    // MARK: - RTMP streaming (deliverable 3)

    enum StreamError: Error, LocalizedError {
        case noTarget
        var errorDescription: String? {
            switch self {
            case .noTarget: return "No stream target configured (call configureStream first)."
            }
        }
    }

    /// Remember a stream target so obs-websocket `StartStream` (no URL argument)
    /// can start streaming later.
    func configureStream(url: String, streamKey: String) {
        configuredStreamURL = url
        configuredStreamKey = streamKey
    }

    /// Start streaming to an explicit RTMP target (also remembered for obs).
    func startStream(url: String, streamKey: String) {
        configuredStreamURL = url
        configuredStreamKey = streamKey
        startStreamInternal(url: url, streamKey: streamKey)
    }

    /// Go Live (deliverable B): start the single-RTMP quick path (when a URL +
    /// key are given) AND every enabled restream destination, all off one encoder.
    /// Empty quick creds → destinations-only broadcast.
    func goLive(rtmpURL: String, streamKey: String) {
        if !rtmpURL.isEmpty {
            configuredStreamURL = rtmpURL
            configuredStreamKey = streamKey
        }
        startStreamInternal(url: rtmpURL, streamKey: streamKey)
    }

    /// obs-websocket path: start with the previously-configured target.
    func startConfiguredStream() throws {
        guard !didShutdown else { return } // Codex #4: no new stream after shutdown
        guard let url = configuredStreamURL, let key = configuredStreamKey else {
            throw StreamError.noTarget
        }
        startStreamInternal(url: url, streamKey: key)
    }

    /// Start a live broadcast. `url`/`streamKey` are the OPTIONAL single-RTMP
    /// "quick path" primary (empty → skip it, e.g. destinations-only Go Live);
    /// every enabled persisted `destinations` entry additionally streams via the
    /// `MultiDestinationBroadcaster`. Both are fed by the SAME `ProgramEncoder`
    /// (video) and the SAME master-mix audio tap (audio), so it is truly
    /// encode-once / distribute-many (deliverable B).
    /// Whether a broadcast may carry HDR (10-bit HEVC Main10) given its targets
    /// (sol #5 #14). Pure / unit-testable. HDR is allowed ONLY when HDR is requested
    /// AND every target is SRT (codec-agnostic): the single-RTMP primary is always
    /// classic RTMP (H.264-only), and a `.rtmp` destination is treated as classic
    /// (enhanced-RTMP HEVC support is not modeled). Any classic-RTMP target forces the
    /// encode-once program to H.264 SDR so HEVC is never silently sent to RTMP ingest.
    static func streamUsesHDR(hdrEnabled: Bool, hasPrimaryRTMP: Bool,
                              destinations: [Destination]) -> Bool {
        guard hdrEnabled else { return false }
        let hasClassicRTMP = hasPrimaryRTMP || destinations.contains { $0.proto == .rtmp }
        return !hasClassicRTMP
    }

    private func startStreamInternal(url: String, streamKey: String) {
        guard !didShutdown else { return } // Codex #4: don't attach outputs after shutdown
        guard streamEncoder == nil, !isStreaming else { return }
        let enabledDestinations = destinations.filter(\.enabled)
        let hasPrimary = !url.isEmpty && !streamKey.isEmpty
        guard hasPrimary || !enabledDestinations.isEmpty else {
            lastError = "No stream target — enter an RTMP URL and key, or enable a destination."
            return
        }
        let w = Self.canvasSize.width, h = Self.canvasSize.height
        // HDR sink-parity (Stage O): an HDR show streams 10-bit HEVC Main10 /
        // Rec.2020-HLG (was 8-bit H.264). The single ProgramEncoder feeds both the
        // RTMP primary and every SRT destination, so all broadcast paths carry the
        // same HDR elementary stream. SDR is byte-for-byte unchanged.
        //   NOTE (UNVERIFIED-until-hardware / protocol): classic RTMP carries
        //   H.264 only; HEVC-HDR over RTMP requires enhanced-RTMP (E-RTMP) ingest
        //   support at the destination. SRT is codec-agnostic and carries HEVC-HDR.
        //   sol #5 #14: classic RTMP carries H.264 ONLY. The encode-once program feeds
        //   ONE elementary stream to every target, so if ANY target is classic RTMP —
        //   the single-RTMP primary is always classic; a `.rtmp` destination is not
        //   modeled as enhanced-RTMP — an HDR show must NOT silently emit HEVC to it.
        //   Gate HEVC-HDR to an all-SRT target set; otherwise fall back to H.264 SDR for
        //   the whole broadcast and SURFACE why (never silently send HEVC to RTMP).
        let hdr = Self.streamUsesHDR(hdrEnabled: hdrEnabled, hasPrimaryRTMP: hasPrimary,
                                     destinations: enabledDestinations)
        if hdrEnabled && !hdr {
            lastError = "HDR streaming needs an SRT (or enhanced-RTMP) destination — classic RTMP is H.264-only. Streaming in SDR."
        }
        let streamRange: ProgramEncoder.Settings.DynamicRange = hdr ? .hdr : .sdr
        let encoder = ProgramEncoder(settings: .init(codec: .h264, width: w, height: h,
                                                     averageBitrate: 6_000_000,
                                                     expectedFrameRate: 60,
                                                     dynamicRange: streamRange))
        // Optional single-RTMP primary (drives the existing hardened published
        // stream state/stats/reconnect surface). Codec follows the program range
        // so the muxed elementary stream is declared HEVC when HDR.
        let rtmp: RTMPStreamOutput? = hasPrimary
            ? RTMPStreamOutput(settings: .init(codec: hdr ? .hevc : .h264, width: w, height: h,
                                               videoBitrate: 6_000_000,
                                               expectedFrameRate: 60))
            : nil
        // Program audio is sent to destinations whenever the mixer is running
        // (the master tap fans master-mix packets to `broadcast(audio:)`), so
        // SRT destinations must declare `includeAudio` to MATCH — otherwise the
        // TS mux stalls waiting for audio it (never) or (always) gets. When the
        // mixer isn't running, no audio flows → includeAudio must be false.
        let sendingAudio = audioMixerStarted
        let broadcaster: MultiDestinationBroadcaster? = enabledDestinations.isEmpty ? nil
            : MultiDestinationBroadcaster(videoSettings: .init(
                codec: hdr ? .hevc : .h264, width: w, height: h, videoBitrate: 6_000_000,
                expectedFrameRate: 60, includeAudio: sendingAudio))
        // Encoded program video → the single RTMP (if any) AND the broadcaster.
        // Both appends are nonisolated + fire-and-forget (safe from the encoder
        // queue); a down destination drops on its own queue, never here.
        encoder.onEncodedFrame = { sampleBuffer in
            rtmp?.append(encodedVideo: sampleBuffer)
            broadcaster?.broadcast(encodedVideo: sampleBuffer)
        }
        do {
            try encoder.start()
        } catch {
            lastError = "Stream encoder failed to start: \(error.localizedDescription)"
            return
        }

        streamEncoder = encoder
        rtmpOutput = rtmp
        self.broadcaster = broadcaster
        isStreaming = true
        streamStartDate = Date()
        streamStateDescription = hasPrimary ? "connecting" : "broadcasting"
        // Reset all live counters on START so GetStreamStatus never reports the
        // previous stream's totals before the first stats tick (Codex #7).
        streamDroppedAppends = 0
        streamBitrate = 0
        streamBytesOut = 0
        streamTotalFrames = 0
        streamHasPublished = false
        broadcastVideoFrames = 0
        broadcastAudioFrames = 0
        broadcastDestinationsConfigured = 0
        destinationStats = [:]
        streamGeneration &+= 1
        let generation = streamGeneration
        // Fan-out feeds the encoder (video), the single RTMP audio, AND the
        // broadcaster audio (the missing `broadcast(audio:)` caller — C2).
        //
        // sol #7 #3/#5: INSTALL THE ENCODER AND ARM THE HDR→SDR CONVERSION ATOMICALLY.
        // `ProgramFanOut.handle` snapshots BOTH `streamEncoder` and `streamSDRFromHDR`
        // under one lock, so the arming is atomic per-frame — but two SEPARATE setter
        // calls are not. Pre-fix `setStreamEncoder` ran BEFORE `setStreamSDRFromHDR`,
        // opening a window where a render tick saw a live SDR encoder with the conversion
        // still OFF and fed it the RAW 10-bit HDR program frame (decoded ~182, not ~128).
        // A single atomic setter closes it — the encoder is never visible without its
        // matching conversion flag. `hdrEnabled && !hdr` is exactly the classic-RTMP
        // SDR-fallback case surfaced above; a true-HDR (all-SRT/enhanced) broadcast keeps
        // `hdr == true` → no convert.
        fanOut.armStreamEncoder(encoder, sdrFromHDR: hdrEnabled && !hdr)
        fanOut.setStreamOutput(rtmp)
        fanOut.setBroadcaster(broadcaster)
        controlServer.publish(.streamStateChanged(active: true, state: .starting))

        // Bring up the persisted destinations (each connect is independent — a
        // dead/failed destination reverts to disabled and never enters the hot
        // path; it can neither stall the loop nor block the others).
        if let broadcaster {
            broadcastDestinationsConfigured = enabledDestinations.count
            for dest in enabledDestinations {
                trackedConnect { [weak self] in
                    do { _ = try await broadcaster.add(dest) }
                    catch {
                        guard !Task.isCancelled else { return }
                        self?.lastError = "Destination \"\(dest.name)\" failed to connect: \(error.localizedDescription)"
                    }
                }
            }
            startBroadcastStatsTimer()
        }

        // Single-RTMP primary: observe its state + connect (unchanged hardened path).
        if let rtmp {
            streamStateTask = Task { [weak self] in
                let updates = await rtmp.stateUpdates
                for await state in updates {
                    await MainActor.run { self?.streamStateChanged(state) }
                }
            }
            // Attempt the connection (a bad URL / no server fails gracefully here).
            // Tracked so stopStream can cancel + await it; and re-checked AFTER the
            // connect await so a stop that landed while connect() was in flight
            // tears the just-published connection back down instead of orphaning it (W2).
            streamConnectTask = Task { [weak self] in
                do {
                    try await rtmp.connect(url: url, streamKey: streamKey)
                    let stillCurrent = await MainActor.run { [weak self] () -> Bool in
                        self?.streamGeneration == generation && self?.rtmpOutput === rtmp
                    }
                    // Superseded by a stop/teardown during connect → undo the publish.
                    if !stillCurrent { await rtmp.close() }
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, self.streamGeneration == generation else { return }
                        self.streamConnectFailed(error)
                    }
                }
            }
            startStreamStatsTimer()
        } else {
            // Destinations-only: no single RTMP to publish; the broadcast is live
            // as soon as the encoder runs (per-destination state is in the HUD).
            streamHasPublished = true
        }
    }

    func stopStream() {
        guard isStreaming else { return }
        controlServer.publish(.streamStateChanged(active: false, state: .stopped))
        finishStreamTeardown(state: "closed")
    }

    private func streamStateChanged(_ state: RTMPStreamOutput.ConnectionState) {
        streamStateDescription = Self.describe(state)
        switch state {
        case .publishing:
            // A return to .publishing after the first publish is a fresh stream
            // (e.g. following a .reconnecting) — force a keyframe so the new
            // connection starts decodable instead of waiting up to a full
            // keyframe interval for the next IDR (W5).
            if streamHasPublished { streamEncoder?.forceKeyframe() }
            streamHasPublished = true
        case .failed, .closed:
            finishStreamTeardown(state: streamStateDescription)
        default:
            break
        }
        writeLinkDebugState()
    }

    private func streamConnectFailed(_ error: Error) {
        lastError = "Stream connect failed: \(error.localizedDescription)"
        streamStateDescription = "failed: \(error.localizedDescription)"
        controlServer.publish(.streamStateChanged(active: false, state: .stopped))
        finishStreamTeardown(state: streamStateDescription)
    }

    /// Single teardown path for stop AND failure/closed (W7). Bumps the stream
    /// generation (superseding any in-flight connect), stops the encoder, and
    /// awaits `RTMPStreamOutput.close()` — which cancels the consumer/watcher
    /// tasks and finishes the ingest continuation — so no path leaves a live
    /// RTMP session or a running connect Task behind.
    private func finishStreamTeardown(state: String) {
        streamStatsTimer?.invalidate(); streamStatsTimer = nil
        broadcastStatsTimer?.invalidate(); broadcastStatsTimer = nil
        streamStateTask?.cancel(); streamStateTask = nil
        streamGeneration &+= 1 // supersede any in-flight connect Task
        let connectTask = streamConnectTask
        streamConnectTask = nil
        let rtmp = rtmpOutput
        let encoder = streamEncoder
        let broadcaster = broadcaster
        fanOut.setStreamEncoder(nil)
        fanOut.setStreamSDRFromHDR(false)   // sol #6 #5: drop the HDR→SDR stream conversion
        fanOut.setStreamOutput(nil)
        fanOut.setBroadcaster(nil)
        encoder?.stop()
        streamEncoder = nil
        rtmpOutput = nil
        self.broadcaster = nil
        isStreaming = false
        streamStartDate = nil
        streamHasPublished = false
        // Reset counters on teardown too (Codex #7): a stopped stream has no live
        // bitrate, and the next stream starts from a clean slate regardless.
        streamBitrate = 0
        streamBytesOut = 0
        streamTotalFrames = 0
        streamDroppedAppends = 0
        broadcastDestinationsConfigured = 0
        streamStateDescription = state
        // Cancel + await the connect Task (so a connect that publishes right as
        // we tear down completes first), THEN close() — close tears down
        // whatever connect established, guaranteeing no orphan connection (W2/W7).
        if rtmp != nil || connectTask != nil {
            Task {
                connectTask?.cancel()
                await connectTask?.value
                await rtmp?.close()
            }
        }
        // Tear down every restream destination (unpublish + close each output).
        // Codex #4: cancel + AWAIT every in-flight per-destination connect Task
        // FIRST, so no `broadcaster.add(dest)` finishes (assigning a live
        // connection/stream) after `shutdown()` — which would leave a destination
        // publishing past stop. The await guarantees connect-then-shutdown order
        // even though actor reentrancy would otherwise interleave them.
        let connectTasks = Array(destinationConnectTasks.values)
        destinationConnectTasks.removeAll()
        if let broadcaster {
            Task {
                for t in connectTasks { t.cancel() }
                for t in connectTasks { await t.value }
                await broadcaster.shutdown()
            }
        } else {
            for t in connectTasks { t.cancel() }
        }
    }

    private func startStreamStatsTimer() {
        streamStatsTimer?.invalidate()
        streamStatsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop, so main-actor isolation holds.
            MainActor.assumeIsolated {
                guard let self, let rtmp = self.rtmpOutput else { return }
                // Capture the stream identity BEFORE the async stats() call so a
                // stop/teardown or a restart that lands while stats() is in flight
                // can't clobber the live (or freshly reset) counters with the old
                // stream's values (Codex #1).
                let generation = self.streamGeneration
                Task {
                    let stats = await rtmp.stats()
                    await MainActor.run {
                        guard self.streamGeneration == generation,
                              self.rtmpOutput === rtmp else { return }
                        self.streamBitrate = stats.bytesOutPerSecond * 8
                        self.streamDroppedAppends = stats.appendsDropped
                        self.streamBytesOut = stats.bytesOut
                        self.streamTotalFrames = stats.videoFramesAppended
                    }
                }
            }
        }
    }

    /// Poll the broadcaster's fan-out + per-destination stats while restreaming
    /// (deliverable B). Runs only when a broadcaster is live; the identity guard
    /// (same generation + same broadcaster instance) prevents a late async result
    /// from clobbering a freshly-reset broadcast's counters.
    private func startBroadcastStatsTimer() {
        broadcastStatsTimer?.invalidate()
        broadcastStatsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let broadcaster = self.broadcaster else { return }
                let generation = self.streamGeneration
                Task {
                    let fan = await broadcaster.fanOutStats()
                    let byDest = await broadcaster.statsByDestination()
                    await MainActor.run {
                        guard self.streamGeneration == generation,
                              self.broadcaster === broadcaster else { return }
                        self.broadcastVideoFrames = fan.videoFramesFanned
                        self.broadcastAudioFrames = fan.audioBuffersFanned
                        self.destinationStats = byDest
                    }
                }
            }
        }
    }

    // MARK: - Destinations editor (deliverable B)

    /// Spawn + TRACK a per-destination connect Task (Codex #4). Every task that
    /// calls into the broadcaster to bring a destination up is registered here so
    /// `finishStreamTeardown` can cancel and AWAIT them before `shutdown()`,
    /// guaranteeing no connect assigns a live connection/stream after teardown.
    /// The task removes itself from the registry when it finishes.
    private func trackedConnect(_ body: @escaping @MainActor () async -> Void) {
        destinationConnectSeq &+= 1
        let token = destinationConnectSeq
        let task = Task { @MainActor [weak self] in
            await body()
            self?.destinationConnectTasks[token] = nil
        }
        destinationConnectTasks[token] = task
    }

    /// Add a restream destination and persist. If a broadcast is already live,
    /// enabled destinations are brought up immediately.
    func addDestination(_ destination: Destination) {
        destinations.append(destination)
        persistDestinations()
        if isStreaming, destination.enabled, let broadcaster {
            trackedConnect { [weak self] in
                do { _ = try await broadcaster.add(destination) }
                catch {
                    guard let self, !Task.isCancelled else { return }
                    // Re-verify #7: same phantom-enabled fix as setDestinationEnabled —
                    // a destination ADDED while live whose connect fails must not stay
                    // persisted/shown as enabled.
                    if let i = self.destinations.firstIndex(where: { $0.id == destination.id }) {
                        self.destinations[i].enabled = false
                        self.persistDestinations()
                    }
                    self.lastError = "Destination \"\(destination.name)\" failed to connect: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Remove a destination and persist. Tears down its live output if streaming.
    func removeDestination(_ id: UUID) {
        guard destinations.contains(where: { $0.id == id }) else { return }
        destinations.removeAll { $0.id == id }
        persistDestinations()
        KeychainStore.remove(id.uuidString) // Codex #8: drop the destination's stored secret
        if let broadcaster { Task { await broadcaster.remove(id: id) } }
    }

    /// Replace a destination's fields (name/proto/url/key) and persist. Edits to
    /// a live destination take effect on the next Go Live (a running SRT/RTMP
    /// connection can't be re-pointed in place) — surfaced in the editor.
    func updateDestination(_ destination: Destination) {
        guard let index = destinations.firstIndex(where: { $0.id == destination.id }) else { return }
        destinations[index] = destination
        persistDestinations()
    }

    /// Enable/disable a destination and persist; brings it up / tears it down
    /// live if a broadcast is running.
    func setDestinationEnabled(_ enabled: Bool, id: UUID) {
        guard let index = destinations.firstIndex(where: { $0.id == id }) else { return }
        destinations[index].enabled = enabled
        persistDestinations()
        guard isStreaming, let broadcaster else { return }
        let dest = destinations[index]
        trackedConnect { [weak self] in
            do {
                // If the destination isn't registered yet (added while live and
                // disabled), add it; otherwise flip its enabled state.
                let registered = await broadcaster.destinations.contains { $0.id == id }
                if enabled, !registered {
                    _ = try await broadcaster.add(dest)
                } else {
                    try await broadcaster.setEnabled(enabled, id: id)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                // Codex #7: the live enable/disable failed and the broadcaster
                // reverted its own copy. Revert the PERSISTED + @Published state to
                // match so the JSON, the UI, and the broadcaster all agree (rather
                // than persisting `enabled=true` for a destination that never came
                // up). Surface the error too.
                if let i = self.destinations.firstIndex(where: { $0.id == id }) {
                    self.destinations[i].enabled = !enabled
                    self.persistDestinations()
                }
                self.lastError = "Destination \"\(dest.name)\" failed to connect: \(error.localizedDescription)"
            }
        }
    }

    private func persistDestinations() {
        do { try StreamDestinationsStore.save(destinations) }
        catch { lastError = "Couldn't save destinations: \(error.localizedDescription)" }
    }

    private static func describe(_ state: RTMPStreamOutput.ConnectionState) -> String {
        switch state {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .publishing: return "publishing"
        case .reconnecting(let attempt): return "reconnecting (attempt \(attempt))"
        case .closed: return "closed"
        case .failed(let reason): return "failed: \(reason)"
        }
    }

    // MARK: - Transitions (deliverable 4)

    func setTransitionEnabled(_ enabled: Bool) { transitionEnabled = enabled; saveTransitionSettings() }

    func setTransitionDuration(_ seconds: Double) {
        transitionDuration = max(0, seconds)
        saveTransitionSettings()
    }

    private func stingerRegistration(for id: SourceID) -> AuxiliaryVideoSource? {
        if let auxiliary = auxiliarySources[id] {
            return auxiliary
        } else if let active = activeSources.first(where: { $0.id == id }),
                  let mailbox = active.mailbox,
                  case .generated(let source) = active.backing {
            return AuxiliaryVideoSource(source: source, mailbox: mailbox)
        }
        return nil
    }

    /// Cue phaseful media off the main actor and wait for frame zero before the
    /// transition clock starts. Stills/procedural sources bypass this entirely.
    private func beginStingerCue(_ registration: AuxiliaryVideoSource,
                                 completion: @escaping @MainActor (Bool, String?) -> Void) {
        stingerCueQueue.async {
            registration.source.stop()
            _ = registration.mailbox.takeNewest()
            let deliveredBefore = registration.mailbox.stats.delivered
            let failure: String?
            do {
                try registration.source.start()
                let deadline = ProcessInfo.processInfo.systemUptime + 0.35
                while registration.mailbox.stats.delivered == deliveredBefore,
                      ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                if registration.mailbox.stats.delivered > deliveredBefore {
                    failure = nil
                } else {
                    registration.source.stop()
                    try? registration.source.start() // restore continuous tile playback
                    failure = "Stinger media did not produce its cue frame in time."
                }
            } catch {
                try? registration.source.start() // best-effort rollback
                failure = "Couldn't cue stinger media: \(error.localizedDescription)"
            }
            #if DEBUG
            // Force the timeout/error terminal path live: the media was (re)started
            // above, so the completion's failed-cue branch is the only thing that stops it.
            let forced = AppEngine._test_forceStingerCueFailure
            let reportReady = forced ? false : (failure == nil)
            let reportFailure = forced ? "forced stinger cue failure" : failure
            #else
            let reportReady = failure == nil
            let reportFailure = failure
            #endif
            DispatchQueue.main.async {
                completion(reportReady, reportFailure)
            }
        }
    }

    private func invalidatePendingStingerCue(for sourceID: SourceID? = nil,
                                             drain: Bool = false) {
        guard sourceID == nil || pendingStingerCueSourceID == sourceID else { return }
        pendingStingerCueToken = nil
        pendingStingerCueSourceID = nil
        if drain { stingerCueQueue.sync {} }
    }

    /// Cancel/replace an in-flight stinger without leaving its vertical override
    /// or a scene that references media the operator is removing.
    private func cancelActiveStingerTransition(applyTargetScene: Bool = true) {
        guard let sourceID = activeStingerSourceID else { return }
        activeStingerSourceID = nil
        activeStingerToken = nil
        verticalTap.clearProgramOverride()
        if applyTargetScene { renderLoop?.scene = scene }
        // sol #3: a cancelled/replaced stinger restarted its media at the cue and had
        // only the (now-cancelled) transition completion to stop it — stop/rewind it
        // here on the cancel/replace terminal path (guarded against a resting layer).
        #if DEBUG
        if Self._test_skipStingerTerminalStop { return }
        #endif
        stopStingerMedia(sourceID)
    }

    /// Stop an animated stinger source once its transition has completed (N2).
    /// The stinger cue restarts a GIF/movie source at frame 0 when the transition
    /// begins; on a normal completion nothing stopped it, so its media kept
    /// free-running. Return it to idle here — but only when it is NOT also a live
    /// resting layer of the program (e.g. a camera the operator picked as stinger
    /// media): stopping a source that is still on-screen would freeze it.
    private func stopStingerMedia(_ sourceID: SourceID) {
        guard !scene.layers.contains(where: { $0.sourceID == sourceID }) else { return }
        guard let registration = stingerRegistration(for: sourceID),
              registration.source is AnimatedGIFSource || registration.source is MovieSource else { return }
        registration.source.stop()
    }

    /// Commit a new program scene with the configured transition (crossfade by
    /// default; a hard cut when disabled / zero-duration). Sets `scene` under
    /// `suppressSceneRenderApply` so the didSet doesn't double-apply.
    private func commitSceneAnimated(_ newScene: ProgramScene) {
        let outgoing = scene
        invalidatePendingStingerCue()
        cancelActiveStingerTransition()
        // A normal/replacement transition must never inherit the previous
        // stinger's vertical scene if RenderLoop dropped that completion.
        verticalTap.clearProgramOverride()
        let armedItem = armedStingerMemeID.flatMap { armedID in
            memeItems.first { $0.id == armedID && $0.mode == .stinger }
        }
        let selectedItem: MemeItem? = {
            guard armedItem == nil, transitionEnabled, transitionDuration > 0,
                  let id = stingerMediaID,
                  let source = activeSources.first(where: { $0.id == id && $0.isVideo }) else {
                return nil
            }
            return MemeItem(name: source.descriptor.name,
                            mediaURL: URL(fileURLWithPath: "/dev/null"),
                            sourceID: id, mode: .stinger,
                            holdSec: transitionDuration,
                            placement: .fullscreen)
        }()
        let stingerItem = armedItem ?? selectedItem
        // A scene switch is the first point at which an armed tile has both A
        // and B. Consume it exactly once; a removed/stale id simply falls back
        // to the operator's normal transition.
        if armedStingerMemeID != nil { armedStingerMemeID = nil }
        guard let candidate = stingerItem else {
            performSceneCommit(newScene, outgoing: outgoing, stingerItem: nil)
            return
        }
        guard let registration = stingerRegistration(for: candidate.sourceID) else {
            lastError = "Stinger media is no longer registered."
            performSceneCommit(newScene, outgoing: outgoing, stingerItem: nil)
            return
        }
        // Stills/procedural sources have no playback phase. Restarting a user
        // ImageSource would also re-read a URL after its security scope ended.
        guard registration.source is AnimatedGIFSource
                || registration.source is MovieSource else {
            performSceneCommit(newScene, outgoing: outgoing, stingerItem: candidate)
            return
        }

        let cueToken = UUID()
        pendingStingerCueToken = cueToken
        pendingStingerCueSourceID = candidate.sourceID
        verticalTap.forget(candidate.sourceID)
        beginStingerCue(registration) { [weak self] ready, failure in
            guard let self else { return }
            guard self.pendingStingerCueToken == cueToken else {
                // sol #4: a rapid SECOND scene switch or an HDR rebuild cleared the pending
                // token (`invalidatePendingStingerCue`) WITHOUT stopping this cue's media.
                // `beginStingerCue` already restarted the media at its cue frame, so this
                // stale early-return would leave it FREE-RUNNING forever. Stop it here —
                // UNLESS a newer cue or the active transition now owns this source (it
                // manages its own stop; a re-armed same-source cue restarts it anyway).
                // `stopStingerMedia` also guards a source that is a live resting layer.
                if self.pendingStingerCueSourceID != candidate.sourceID,
                   self.activeStingerSourceID != candidate.sourceID {
                    #if DEBUG
                    if !Self._test_skipStingerTerminalStop { self.stopStingerMedia(candidate.sourceID) }
                    #else
                    self.stopStingerMedia(candidate.sourceID)
                    #endif
                }
                return
            }
            self.pendingStingerCueToken = nil
            self.pendingStingerCueSourceID = nil
            if let failure { self.lastError = failure }
            if !ready {
                // sol #3: a TIMED-OUT / ERRORED cue restarted the media to restore
                // resting playback, then falls back to a plain cut with NO transition
                // completion to stop it — leaving a non-resting stinger source
                // free-running. Stop it here (guarded so a source that is also a live
                // resting layer isn't frozen).
                #if DEBUG
                if !Self._test_skipStingerTerminalStop { self.stopStingerMedia(candidate.sourceID) }
                #else
                self.stopStingerMedia(candidate.sourceID)
                #endif
            }
            self.performSceneCommit(newScene, outgoing: outgoing,
                                    stingerItem: ready ? candidate : nil)
        }
    }

    private func performSceneCommit(_ newScene: ProgramScene,
                                    outgoing: ProgramScene,
                                    stingerItem: MemeItem?) {
        if let loop = renderLoop {
            if let stingerItem {
                let token = UUID()
                let stingerSourceID = stingerItem.sourceID
                activeStingerSourceID = stingerSourceID
                activeStingerToken = token
                loop.switchScene(
                    to: newScene,
                    transition: AppEngine.liveStingerSchedule(item: stingerItem,
                                                               outgoing: outgoing,
                                                               incoming: newScene),
                    completion: { [weak self, verticalTap] _ in
                        verticalTap.clearProgramOverride()
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.activeStingerToken == token else { return }
                            self.activeStingerSourceID = nil
                            self.activeStingerToken = nil
                            // N2: the cue STARTED this animated stinger source and
                            // only the timeout/error paths ever restart/stop it — a
                            // NORMAL completion left it free-running forever. Stop it
                            // back to its idle/frame-0 state so it isn't decoding a
                            // transition that already finished.
                            self.stopStingerMedia(stingerSourceID)
                        }
                    })
            } else {
                loop.switchScene(to: newScene,
                                 transition: transitionSchedule(outgoing: outgoing, incoming: newScene))
            }
        }
        suppressSceneRenderApply = true
        scene = newScene
        suppressSceneRenderApply = false
    }

    /// Pure cue evaluator used by the live schedule and App regression tests.
    /// Builds independently-cleared A+media and B+media scenes. RenderLoop uses
    /// a hard-step crossfade at the cue, so transparent/uncovered parts of A can
    /// never reveal B early (the `.overlay` stack would leak B underneath).
    nonisolated static func evaluateLiveStinger(
        item: MemeItem,
        outgoing: ProgramScene,
        incoming: ProgramScene,
        elapsed: Double,
        duration: Double,
        cueProgress: Double = 0.5
    ) -> (outgoingScene: ProgramScene,
          incomingScene: ProgramScene,
          evaluatedProgram: ProgramScene) {
        let safeDuration = max(0.0001, duration)
        let cue = min(max(cueProgress, 0.0001), 0.9999)
        let progress = min(max(elapsed / safeDuration, 0), 1)
        let alpha = progress <= cue
            ? progress / cue
            : 1 - (progress - cue) / (1 - cue)
        func addingOverlay(to base: ProgramScene, phase: String) -> ProgramScene {
            let z = (base.layers.map(\.zIndex).max() ?? 0) + 1
            let overlay = Layer(sourceID: item.sourceID,
                                frame: MemePlacement.fullscreen.frame,
                                opacity: Float(min(max(alpha, 0), 1)),
                                zIndex: z,
                                premultipliedAlpha: true)
            var result = base
            result.layers.append(overlay)
            result.name = "stinger.\(item.name).\(phase)"
            return result
        }
        let out = addingOverlay(to: outgoing, phase: "outgoing")
        let incoming = addingOverlay(to: incoming, phase: "incoming")
        return (out, incoming, progress < cue ? out : incoming)
    }

    /// Zero-copy live stinger: the registered meme source is sampled as a
    /// compositor layer every render tick; no StingerRenderer/CoreGraphics
    /// readback enters the hot path. The scene swap happens at the full-cover
    /// cue, and the same evaluated scene/reframe is published to 9:16.
    nonisolated static func liveStingerSchedule(item: MemeItem,
                                                outgoing: ProgramScene,
                                                incoming: ProgramScene) -> TransitionSchedule {
        let duration = min(max(item.holdSec, 0.2), 6)
        let cue = 0.5
        return TransitionSchedule(
            duration: duration,
            blend: .crossfade,
            // An intentional hard scene cut, hidden by the full-cover media at
            // `cue`. Each side is rendered to its own cleared texture first.
            progress: { elapsed in elapsed / duration < cue ? 0 : 1 },
            outgoingScene: { elapsed in
                let evaluation = AppEngine.evaluateLiveStinger(
                    item: item, outgoing: outgoing, incoming: incoming,
                    elapsed: elapsed, duration: duration, cueProgress: cue)
                return evaluation.outgoingScene
            },
            incomingScene: { elapsed in
                let evaluation = AppEngine.evaluateLiveStinger(
                    item: item, outgoing: outgoing, incoming: incoming,
                    elapsed: elapsed, duration: duration, cueProgress: cue)
                return evaluation.incomingScene
            })
    }

    /// Build the `TransitionSchedule` for the chosen `transitionKind` (deliverable
    /// — VisualFX transitions). Compositor-native kinds (dissolve/wipe/push) get an
    /// exact zero-copy schedule via `TransitionSpec.schedule`; pixel-effect kinds
    /// (iris/zoomBlur/glitch/animeFlash/speedline) return nil there, so we fall
    /// back to a live crossfade of the same duration (the exact pixel effect would
    /// need a `TransitionRenderer` GPU pass — future work). nil = an instant cut
    /// (transitions disabled or zero duration).
    private func transitionSchedule(outgoing: ProgramScene, incoming: ProgramScene) -> TransitionSchedule? {
        guard transitionEnabled, transitionDuration > 0 else { return nil }
        let spec = TransitionSpec(kind: transitionKind, duration: transitionDuration)
        if let native = spec.schedule(outgoing: outgoing, incoming: incoming) { return native }
        return .crossfade(duration: transitionDuration)
    }

    // MARK: Transition-kind controls (deliverable 3)

    func setTransitionKind(_ kind: TransitionKind) { transitionKind = kind; saveTransitionSettings() }
    /// Choose media that turns every enabled scene switch into a live stinger.
    /// Set nil to resume the selected `transitionKind`.
    func setStingerMedia(_ id: SourceID?) { stingerMediaID = id; saveTransitionSettings() }
}

// MARK: - v2 deliverable 1: Scene collections (persistent named layouts)

extension AppEngine {
    /// Snapshot the current program scene + selected preset as a named,
    /// persisted collection. Replaces an existing collection of the same name
    /// (so re-saving under a name updates it) and writes the set to disk.
    func saveCurrentAsCollection(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let collection = SceneCollection(name: trimmed, scene: scene,
                                         presetRawValue: selectedPreset.rawValue)
        if let index = sceneCollections.firstIndex(where: { $0.name == trimmed }) {
            sceneCollections[index] = collection
        } else {
            sceneCollections.append(collection)
        }
        persistCollections()
    }

    /// Apply a saved collection's layer arrangement to the program (animated by
    /// the current transition). Layers whose sources aren't active simply don't
    /// render until re-added — the arrangement (frames / z-order / opacity /
    /// hidden) is restored so the operator's layout survives a relaunch.
    func loadCollection(_ collection: SceneCollection) {
        if let preset = ScenePreset(rawValue: collection.presetRawValue) {
            selectedPreset = preset
        }
        var restored = scene
        restored.layers = collection.scene.layers
        // `premultipliedAlpha` is persisted per layer, but the correct value
        // depends on the CURRENT effect state, not what was saved (Codex #1):
        // a collection saved un-keyed then loaded while chroma/remove is active
        // would restore a stale `false` → keyed transparency composites opaque
        // black. Recompute each restored layer's flag from live sourceEffects.
        for i in restored.layers.indices {
            let want = layerNeedsPremultipliedAlpha(restored.layers[i].sourceID)
            restored.layers[i].premultipliedAlpha = want
        }
        commitSceneAnimated(restored)
    }

    func deleteCollection(_ collection: SceneCollection) {
        sceneCollections.removeAll { $0.id == collection.id }
        persistCollections()
    }

    private func persistCollections() {
        do { try SceneCollectionStore.save(sceneCollections) }
        catch { lastError = "Couldn't save scene collections: \(error.localizedDescription)" }
        writeLinkDebugState()
    }

    /// Debug round-trip (PRISM_DEBUG_SAVE_COLLECTION): save the current scene,
    /// reload the file fresh from disk, and publish whether the reloaded copy
    /// matches — proving persistence really goes through the filesystem.
    func debugSaveAndReloadCollection(named name: String) {
        saveCurrentAsCollection(name: name)
        let reloaded = SceneCollectionStore.load()
        lastCollectionRoundTripOK = reloaded.contains {
            $0.name == name && $0.scene.layers.count == scene.layers.count
        }
        writeLinkDebugState()
    }
}

// MARK: - v2 deliverable 3: Keyframed layer motion

extension AppEngine {
    /// Animate a layer's entrance (slide / fade / scale / pop) over `duration`
    /// seconds, driving the render loop's per-tick `sceneProvider` hook with an
    /// `AnimatedScene`. Frames keep flowing throughout (the loop composites
    /// `sceneProvider(pts)` every tick); when the entrance finishes the provider
    /// is cleared and the resting scene resumes.
    func animateLayerIn(sourceID: SourceID, preset: LayerEntrancePreset, duration: Double) {
        guard let loop = renderLoop else { return }
        // Resting layer = where the scene currently wants the layer to sit; the
        // entrance ends exactly there.
        guard let resting = scene.layers.first(where: { $0.sourceID == sourceID }) else { return }
        let clamped = min(10, max(0.1, duration))
        let animation = preset.entrance.animation(for: resting, duration: clamped)
        let animated = AnimatedScene(base: scene,
                                     animations: [sourceID: animation],
                                     startTime: HouseClock.nowSeconds(),
                                     policy: .hold)
        loop.sceneProvider = { pts in animated.evaluate(at: pts.seconds) }
        animatingSourceID = sourceID

        // Clear the provider once the entrance completes so later static scene
        // edits (which set renderLoop.scene directly) are honored again. A live
        // edit arriving sooner cancels this early via `cancelLayerAnimation()`.
        animationClearTimer?.invalidate()
        animationClearTimer = Timer.scheduledTimer(withTimeInterval: clamped, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelLayerAnimation()
            }
        }
        writeLinkDebugState()
    }

    /// Stop any in-flight layer entrance and restore direct scene control.
    /// Idempotent; safe to call from the `scene` didSet (it never mutates `scene`).
    func cancelLayerAnimation() {
        guard animatingSourceID != nil || animationClearTimer != nil else { return }
        animationClearTimer?.invalidate()
        animationClearTimer = nil
        renderLoop?.sceneProvider = nil
        animatingSourceID = nil
        // The entrance just borrowed the sceneProvider. Hand it back to whatever
        // still needs it — a holding meme and/or active per-layer motion — so an
        // active cut/insert or a moving layer doesn't vanish when the entrance ends.
        refreshSceneProvider()
        writeLinkDebugState()
    }
}

// MARK: - Integration 1: MIDI control surface (PrismControlSurface)

/// Value-independent identity for a `SurfaceAction` (a fader's continuous value
/// is ignored), used as the mapping-display key and the UI row identity.
extension SurfaceAction {
    var bindingKey: String {
        switch self {
        case .switchScene(let i):  return "scene.\(i)"
        case .setGain(let c, _):   return "gain.\(c)"
        case .toggleMute(let c):   return "mute.\(c)"
        case .startStream:         return "startStream"
        case .stopStream:          return "stopStream"
        case .startRecord:         return "startRecord"
        case .saveReplay:          return "saveReplay"
        case .custom(let id):      return "custom.\(id)"
        }
    }
}

extension AppEngine {

    /// The actions a control surface can bind, with UI labels. `switchScene`
    /// indices map to `ScenePreset.allCases`; channel 0 is the first audio
    /// channel (sorted by id).
    static var bindableActions: [(action: SurfaceAction, label: String)] {
        [
            (.switchScene(index: 0), "Scene: Fullscreen"),
            (.switchScene(index: 1), "Scene: PiP Corner"),
            (.switchScene(index: 2), "Scene: Side by Side"),
            (.startRecord,           "Record (toggle)"),
            (.startStream,           "Start streaming"),
            (.stopStream,            "Stop streaming"),
            (.saveReplay,            "Save replay"),
            (.toggleMute(channel: 0), "Mute channel 1"),
            (.setGain(channel: 0, value: 0), "Fader → channel 1 gain"),
        ]
    }

    /// `~/Library/Application Support/studio.prism.app/MIDIMapping.json`.
    static var midiMappingURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("studio.prism.app", isDirectory: true)
            .appendingPathComponent("MIDIMapping.json")
    }

    /// Human-readable trigger label for the mapping UI.
    static func describe(_ trigger: MIDITrigger) -> String {
        switch trigger {
        case .note(let n, let c):          return "Note \(n) · ch \(c + 1)"
        case .cc(let cc, let c):           return "CC \(cc) · ch \(c + 1)"
        case .programChange(let p, let c): return "PC \(p) · ch \(c + 1)"
        case .pitchBend(let c):            return "Pitch Bend · ch \(c + 1)"
        }
    }

    /// Construct the surface (prompt-free — no CoreMIDI client until `start()`),
    /// wire its callbacks, and adopt any persisted mapping. Called once at init.
    func setupControlSurface() {
        let surface = ControlSurface()
        // onAction fires on CoreMIDI's receive thread — hop to the main actor.
        surface.onAction = { [weak self] action in
            DispatchQueue.main.async { self?.dispatchSurfaceAction(action) }
        }
        // onMessage fires (also off-thread) for every raw message, including the
        // one that completes a learn — hop to main to refresh + persist.
        surface.onMessage = { [weak self] _ in
            DispatchQueue.main.async { self?.surfaceMessageObserved() }
        }
        controlSurface = surface
        let url = Self.midiMappingURL
        if FileManager.default.fileExists(atPath: url.path) {
            try? surface.loadMapping(from: url)
        }
        refreshSurfaceBindings()
    }

    /// Start/stop live MIDI input (opens/closes the CoreMIDI client).
    func setControlSurfaceEnabled(_ on: Bool) {
        guard controlSurfaceEnabled != on, let surface = controlSurface else { return }
        if on {
            do { try surface.start(); controlSurfaceEnabled = true }
            catch { lastError = "MIDI control surface failed to start: \(error.localizedDescription)" }
        } else {
            surface.stop()
            controlSurfaceEnabled = false
            surfaceLearningAction = nil
        }
        writeLinkDebugState()
    }

    /// Arm MIDI-learn for `action`: the next incoming message binds to it.
    func beginSurfaceLearn(for action: SurfaceAction) {
        guard let surface = controlSurface else { return }
        surface.beginLearn(for: action)
        surfaceLearningAction = action
    }

    func cancelSurfaceLearn() {
        controlSurface?.cancelLearn()
        surfaceLearningAction = nil
    }

    /// Remove every trigger bound to `action` (matched by bindingKey).
    func unbindSurfaceAction(_ action: SurfaceAction) {
        guard let surface = controlSurface else { return }
        var map = surface.mapping
        for (trigger, bound) in map.bindings where bound.bindingKey == action.bindingKey {
            map.unbind(trigger)
        }
        surface.setMapping(map)
        persistSurfaceMapping()
        refreshSurfaceBindings()
    }

    /// Persist the current mapping to Application Support (like scene collections).
    func saveSurfaceMapping() { persistSurfaceMapping() }

    /// Reload the mapping from disk (discarding unsaved live edits).
    func loadSurfaceMapping() {
        guard let surface = controlSurface else { return }
        let url = Self.midiMappingURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = "No saved MIDI mapping found."; return
        }
        do { try surface.loadMapping(from: url); refreshSurfaceBindings() }
        catch { lastError = "Couldn't load MIDI mapping: \(error.localizedDescription)" }
    }

    /// A raw message arrived: if a learn was in flight it just completed —
    /// clear it, refresh the mirror, and persist. Ignored otherwise so live
    /// performance messages don't churn the mirror or the disk.
    private func surfaceMessageObserved() {
        guard surfaceLearningAction != nil else { return }
        surfaceLearningAction = nil
        refreshSurfaceBindings()
        persistSurfaceMapping()
    }

    private func refreshSurfaceBindings() {
        guard let surface = controlSurface else { surfaceBindings = [:]; return }
        var display: [String: String] = [:]
        for (trigger, action) in surface.mapping.bindings {
            display[action.bindingKey] = Self.describe(trigger)
        }
        surfaceBindings = display
    }

    private func persistSurfaceMapping() {
        guard let surface = controlSurface else { return }
        do {
            try FileManager.default.createDirectory(
                at: Self.midiMappingURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try surface.saveMapping(to: Self.midiMappingURL)
        } catch { lastError = "Couldn't save MIDI mapping: \(error.localizedDescription)" }
    }

    /// Dispatch a matched surface action to the corresponding AppEngine intent.
    /// Runs on the main actor.
    func dispatchSurfaceAction(_ action: SurfaceAction) {
        guard !didShutdown else { return }
        surfaceActionCount += 1
        surfaceLastAction = action.bindingKey
        switch action {
        case .switchScene(let index):
            let presets = ScenePreset.allCases
            if presets.indices.contains(index) { applyPreset(presets[index]) }
        case .setGain(let channel, let value):
            if let id = audioChannelID(at: channel) { setChannelGain(Float(value), for: id) }
        case .toggleMute(let channel):
            if let id = audioChannelID(at: channel) {
                let muted = audioMixer.channel(id: id)?.isMuted ?? false
                setChannelMuted(!muted, for: id)
            }
        case .startStream:
            do { try startConfiguredStream() }
            catch { lastError = "MIDI start-stream: \(error.localizedDescription)" }
        case .stopStream:
            stopStream()
        case .startRecord:
            toggleRecording() // a single hardware button both starts and stops
        case .saveReplay:
            saveReplay()
        case .custom:
            break // app-defined; no default binding
        }
        writeLinkDebugState()
    }

    /// Nth audio channel by sorted id (surface "channel" index → SourceID).
    private func audioChannelID(at index: Int) -> SourceID? {
        let ids = audioMixer.channelIDs.sorted { $0.raw < $1.raw }
        return ids.indices.contains(index) ? ids[index] : nil
    }

    /// Debug-only (PRISM_DEBUG_MIDI_LEARN): feed a synthetic MIDIMessage through
    /// a MIDIActionMap and dispatch the resulting action to the real intent.
    func debugMIDIDispatch() {
        var map = MIDIActionMap()
        let trigger = MIDITrigger.note(note: 60, channel: 0)
        map.bind(.switchScene(index: 2), to: trigger) // → applyPreset(.sideBySide)
        let before = surfaceActionCount
        if let action = map.process(.noteOn(note: 60, velocity: 100, channel: 0)) {
            dispatchSurfaceAction(action)
        }
        // Also bind it on the live surface so a subsequent real message dispatches
        // and the UI shows the binding.
        controlSurface?.bind(.switchScene(index: 2), to: trigger)
        refreshSurfaceBindings()
        log.info("debug midi dispatch: surfaceActionCount \(before) → \(self.surfaceActionCount), preset \(self.selectedPreset.rawValue, privacy: .public)")
        writeLinkDebugState()
    }
}

// MARK: - Integration 2: Nearby devices (PrismProximity — BLE discovery only)

extension AppEngine {

    /// Start/stop BLE discovery of nearby iOS Prism companions. The first
    /// `startDiscovery()` triggers the Bluetooth permission prompt.
    func setProximityDiscovery(_ on: Bool) {
        guard proximityDiscovering != on else { return }
        if on {
            let scanner = proximityController.scanner
            scanner.onCandidate = { [weak self] candidate, _ in
                DispatchQueue.main.async { self?.proximityObserved(candidate) }
            }
            scanner.onCandidatesExpired = { [weak self] ids in
                DispatchQueue.main.async { self?.proximityExpired(ids) }
            }
            scanner.onStateChange = { [weak self] state in
                DispatchQueue.main.async { self?.proximityRadioState = state.rawValue }
            }
            proximityController.startDiscovery()
            proximityDiscovering = true
        } else {
            proximityController.stopDiscovery()
            proximityDiscovering = false
            proximityCandidates = []
            nearbyHint = nil
        }
        writeLinkDebugState()
    }

    /// Tapping a nearby device is a hint only — BLE is discovery-only; the real
    /// pair is the existing Wi-Fi/QUIC short-code flow.
    func nearbyTapped(_ candidate: ProximityCandidate) {
        let name = candidate.name ?? "That device"
        nearbyHint = "\(name) is nearby — open Prism Camera on it and pair over Wi-Fi with code \(pairingCodeDisplay)."
    }

    private func proximityObserved(_ candidate: ProximityCandidate) {
        if let i = proximityCandidates.firstIndex(where: { $0.peripheralID == candidate.peripheralID }) {
            proximityCandidates[i] = candidate
        } else {
            proximityCandidates.append(candidate)
        }
    }

    private func proximityExpired(_ ids: [UUID]) {
        let dropped = Set(ids)
        proximityCandidates.removeAll { dropped.contains($0.peripheralID) }
    }
}

// MARK: - Integration 3: Auto-Director (PrismDirector)

extension AppEngine {

    /// Enable/disable automatic switching + framing. When on, every video
    /// source's frames flow to the director (via `directorTap`), its decisions
    /// switch the program hero, and its framing crops the active source's layer.
    /// When off, manual control resumes.
    func setAutoDirectorEnabled(_ on: Bool) {
        guard autoDirectorEnabled != on else { return }
        if on {
            let director = ensureDirector()
            director.setEnabled(true)
            directorTap.install(director) // start routing frames
            autoDirectorEnabled = true
        } else {
            directorTap.install(nil) // stop routing frames first
            director?.setEnabled(false)
            directorAudioInjectTimer?.invalidate(); directorAudioInjectTimer = nil
            autoDirectorEnabled = false
        }
        writeLinkDebugState()
    }

    func setDirectorSensitivity(_ value: Double) {
        directorSensitivity = min(1, max(0, value))
        director?.updateConfig(currentDirectorConfig())
    }

    func setDirectorMinShot(_ seconds: Double) {
        directorMinShotSeconds = max(0, seconds)
        director?.updateConfig(currentDirectorConfig())
    }

    private func currentDirectorConfig() -> DirectorConfig {
        let policy = AutoDirectorConfig(sensitivity: Float(directorSensitivity),
                                        minShotSeconds: directorMinShotSeconds)
        return DirectorConfig(policy: policy)
    }

    private func ensureDirector() -> DirectorController {
        if let director { return director }
        let controller = DirectorController(config: currentDirectorConfig(), enabled: false)
        // onDecision / onFraming fire on the analyzer's serial queue → hop to main.
        controller.onDecision = { [weak self] decision in
            DispatchQueue.main.async { self?.applyDirectorDecision(decision) }
        }
        controller.onFraming = { [weak self] id, crop in
            DispatchQueue.main.async { self?.applyDirectorFraming(id, crop) }
        }
        director = controller
        return controller
    }

    /// Cut the program to the director's chosen source: bring its layer to the
    /// top zIndex (the hero) and commit through the animated transition path.
    private func applyDirectorDecision(_ decision: DirectorDecision) {
        guard autoDirectorEnabled, !didShutdown else { return } // P2: no scene mutation post-shutdown
        directorDecisionCount += 1
        directorActiveSourceID = decision.activeSource
        // Flagship: a program switch is a highlight cue. Feed it before the layer
        // reorder (which may early-return below) so the cut is always scored.
        feedDecisionToDirector(decision)
        guard scene.layers.contains(where: { $0.sourceID == decision.activeSource }) else {
            writeLinkDebugState(); return
        }
        var ordered = scene.layers.sorted { $0.zIndex < $1.zIndex }
        if let index = ordered.firstIndex(where: { $0.sourceID == decision.activeSource }) {
            let hero = ordered.remove(at: index)
            ordered.append(hero) // move to top (hero) — resolves as the program source
            for i in ordered.indices { ordered[i].zIndex = i }
        }
        var next = scene
        next.layers = ordered
        commitSceneAnimated(next) // animated switch via the existing transition path
        writeLinkDebugState()
    }

    /// Apply the director's smoothed crop to the active source's layer.
    private func applyDirectorFraming(_ id: SourceID, _ crop: CGRect) {
        guard autoDirectorEnabled, !didShutdown else { return } // P2
        guard let index = scene.layers.firstIndex(where: { $0.sourceID == id }),
              scene.layers[index].crop != crop else { return }
        mutateLayer(id) { $0.crop = crop }
    }

    /// Debug-only (PRISM_DEBUG_AUTODIRECTOR): enable the director twitchy +
    /// instant, add a second generated source, and inject a synthetic audio
    /// level so a source clears the activation floor and a decision fires.
    func debugStartAutoDirector() {
        addTextSource(text: "DIR-2 {counter}", fontSize: 96, color: .white)
        setDirectorSensitivity(1.0) // activationFloor ≈ 0.02
        setDirectorMinShot(0)
        setAutoDirectorEnabled(true)
        director?.onSignal = { [weak self] signal in
            DispatchQueue.main.async {
                guard let self else { return }
                self.debugSignalCount += 1
                self.debugLastActivity = Double(signal.activity)
            }
        }
        directorAudioInjectTimer?.invalidate()
        directorAudioInjectTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let director = self.director else { return }
                if let first = self.activeSources.first(where: \.isVideo) {
                    director.setAudioLevel(0.9, for: first.id)
                }
            }
        }
    }
}

// MARK: - Integration 4: HDR output (rebuild the compositor/render loop)

extension AppEngine {

    /// Install the complete registered video graph on a fresh render loop.
    /// `activeSources` covers resting layers; `auxiliarySources` covers transient
    /// media such as prepared memes that only appear in provider-evaluated scenes.
    private func installAllMailboxes(on loop: RenderLoop) {
        for source in activeSources {
            if let mailbox = source.mailbox { loop.setMailbox(mailbox, for: source.id) }
        }
        for (id, registration) in auxiliarySources {
            loop.setMailbox(registration.mailbox, for: id)
        }
    }

    /// Toggle HDR program output. `MetalCompositor.colorMode` is an init param,
    /// so switching HDR at runtime rebuilds the compositor + render loop in the
    /// chosen `ColorMode`, migrating source mailboxes and the scene, then swaps
    /// it in atomically (the fan-out / dual-program wiring is reused unchanged).
    /// Gated off-air: a live recorder/encoder is configured for the current bit
    /// depth, so rebuilding under one would feed it mismatched frames.
    func setHDREnabled(_ on: Bool) {
        // sol #4: a toggle AFTER shutdown must be a no-op. Without this the public
        // entry would build a fresh compositor + render loop and `start()` a render
        // thread over torn-down state (a resurrection) — the retry's `didShutdown`
        // guard only covers the fail-safe resume, not this entry point.
        #if DEBUG
        if !Self._test_bypassHDRShutdownGuard { guard !didShutdown else { return } }
        #else
        guard !didShutdown else { return }
        #endif
        guard hdrEnabled != on else { return }
        guard metalDevice != nil else { lastError = "HDR unavailable — Metal isn't running."; return }
        // Gate on every live output, INCLUDING the virtual camera (Codex C1):
        // rebuilding the compositor under a live 8-bit-configured sink would feed
        // it a mid-stream SDR↔HDR bit-depth switch + non-monotonic PTS.
        //   sol #5 #13: also gate on `vcamOutputRequested` (set SYNCHRONOUSLY in
        //   setVirtualCameraOutput), not just `vcamOutputEnabled` (set only later when
        //   the feeder confirms `.feeding`). The feeder begins feeding SDR frames during
        //   that async attach window while `vcamOutputEnabled` is still false — so
        //   gating on the confirmed flag alone let an HDR toggle slip through and switch
        //   that already-live stream to l10r mid-flight.
        let vcamBusy: Bool = {
            #if DEBUG
            if Self._test_ignoreVcamRequestedInHDRGate { return vcamOutputEnabled }
            #endif
            return vcamOutputEnabled || vcamOutputRequested
        }()
        guard !isRecording, !isStreaming, !replayArmed, !vcamBusy else {
            lastError = "Stop recording, streaming, replay, and the virtual camera before changing HDR."
            return
        }
        let mode: MetalCompositor.ColorMode = on ? .hdr : .sdr
        // Rebuild the vertical (9:16) program in the SAME color mode so the vertical
        // program + its recording reach HDR parity with the primary (Stage O). The
        // render loop's tick-snapshot closure captures whichever `dualProgram` is
        // current at `buildRenderLoop` time, so swap the new one in BEFORE building
        // the loop; every failure path below restores `oldDual`.
        let oldDual = dualProgram
        let newDual: DualProgram? = metalDevice.flatMap { dev -> DualProgram? in
            guard let d = try? DualProgram(device: dev,
                                           width: Self.verticalCanvasSize.width,
                                           height: Self.verticalCanvasSize.height,
                                           colorMode: mode) else { return nil }
            d.onSecondaryFrame = { [verticalSink] frame in verticalSink.consume(frame) }
            d.scene = scene
            return d
        }
        // If a vertical program existed but couldn't be rebuilt, abort rather than
        // silently drop the 9:16 program.
        if oldDual != nil && newDual == nil {
            lastError = "Couldn't rebuild the vertical program in \(on ? "HDR" : "SDR") mode."
            return
        }
        dualProgram = newDual ?? oldDual
        guard let newLoop = buildRenderLoop(colorMode: mode) else {
            dualProgram = oldDual
            lastError = "Couldn't rebuild the compositor in \(on ? "HDR" : "SDR") mode."
            return
        }
        let old = renderLoop
        // A FrameMailbox is destructive/single-consumer AND both loops' frame
        // processors reuse the SAME non-thread-safe animated-FX `SourceEffectGPU`
        // / `lastRaw` (F5). Fully QUIESCE the old render thread before tearing down
        // ANY of its state or installing/starting the replacement — otherwise, if
        // the old tick is wedged in animated FX, `stop()` timing out and `start()`
        // proceeding would run two threads over that shared state at once (HIGH-5).
        //
        // Quiesce FIRST, tear down AFTER (N1): nothing about the old loop — its
        // scene provider, meme/motion state, pending stinger cue — is dismantled
        // until `stop()` confirms the old render thread is gone. So a failed
        // quiesce is a near-no-op that leaves the old loop's config intact and we
        // simply resume it, rather than the old bug where the provider was already
        // nil'd + the loop left `running=false`, freezing preview once the wedged
        // pass finally exited.
        if let old, old.stop() == false {
            // FAIL SAFE: the old render pass didn't quiesce in the budget. We must
            // NOT start the replacement (double-run over the shared FX GPU). `stop()`
            // set `running=false`, so bring the old loop back to a RUNNING state with
            // its (still-intact) provider so frames keep flowing once the wedged pass
            // exits — a frozen preview is not an acceptable fail-safe (N1).
            renderLoop = old
            dualProgram = oldDual // old loop's tick closure references oldDual — keep consistent
            resumeRenderLoopAfterFailedQuiesce(old)
            lastError = "HDR change couldn't proceed — the current render pass didn't quiesce. Preview kept running; try again."
            return
        }
        // Old render thread confirmed gone (or there was none): now it is safe to
        // dismantle the old loop's state and stand up the replacement.
        // sol #5 #9: the OLD DualProgram can still be draining enqueued vertical work
        // asynchronously (it is fed off the old render loop's tick snapshot). The
        // primary loop is quiesced above, but the old vertical program is not — fence
        // it so a stale OLD-mode (e.g. SDR) vertical frame cannot arrive at the shared
        // vertical sink AFTER the new program's first frame. Revived on the start-fail
        // path below (which restores `oldDual`).
        if newDual !== oldDual { oldDual?.quiesce() }
        invalidatePendingStingerCue(drain: true)
        cancelActiveStingerTransition()
        cancelLayerAnimation()
        old?.sceneProvider = nil
        installAllMailboxes(on: newLoop)
        newLoop.scene = scene
        renderLoop = newLoop
        // F6: provider state belongs to the loop instance. Rebuild it only after
        // swapping, so a holding meme and every LayerMotion target the new loop.
        refreshSceneProvider()
        guard newLoop.start() else {
            renderLoop = old
            dualProgram = oldDual // restore the old loop's captured vertical program
            oldDual?.resume()     // sol #5 #9: revive the fenced old vertical program
            old?.scene = scene
            refreshSceneProvider()
            _ = old?.start()
            lastError = "Couldn't start the rebuilt \(on ? "HDR" : "SDR") render loop."
            return
        }
        hdrEnabled = on
        hdrModeEpoch &+= 1   // sol #8 #2: every committed HDR-mode change bumps the epoch so a
                             // pending screen restore can tell whether the mode was toggled since
                             // it was queued (→ stale, re-derive) vs. an untouched post-failure fallback.
        // sol #5 #3: switch any LIVE screen capture to (or from) the 10-bit HDR path.
        // A screen source's SCStream range is fixed at build time, so this rebuilds
        // the backing ScreenSource IN PLACE — reusing the SourceID, mailbox, effect
        // pipeline, scene layer, and mixer channel — so the toggle actually reaches
        // ScreenCaptureKit's HDR capture instead of leaving it stuck on 8-bit SDR.
        reconfigureScreenSourcesForHDR(on)
        writeLinkDebugState()
    }

    /// Rebuild every live screen source so its ScreenCaptureKit capture matches the
    /// current HDR state (sol #5 #3). `ScreenCaptureConfiguration` (and thus the
    /// SCStream pixel format / dynamic range) is fixed at construction, so an HDR
    /// toggle must rebuild the backing `ScreenSource` — but IN PLACE, preserving the
    /// SourceID / mailbox / effect pipeline / scene layer / audio channel (mirrors
    /// `setMovieLoop`), so the source never leaves the scene and no transform/effect
    /// state is lost. Software-verified via `configuration.preferHDR`; real 10-bit
    /// delivery is UNVERIFIED-until-hardware (needs an HDR display + macOS 15).
    ///
    /// sol #6 #7: `ScreenSource.start()` returns BEFORE `SCStream.startCapture()`
    /// completes. Pre-fix this stopped the working `old` source and swapped in the
    /// replacement up-front, so an async start FAILURE (`onError`) removed the
    /// replacement and left NO screen source. Now the old source is KEPT running until
    /// the replacement's async start CONFIRMS success (`onStarted` → commit); on async
    /// failure (`onError`) the old source is untouched (still live) and only an error is
    /// surfaced — the source is never lost.
    /// sol #8 #1: tear down every pending screen replacement that targets `id` — retire
    /// its frame-callback gate (no post-teardown frames), STOP its (possibly already
    /// resolving) capture, and drop the strong owner. Called from `removeSource` so a
    /// pending replacement can never outlive the source it was replacing.
    private func drainPendingScreenReplacements(for id: SourceID) {
        #if DEBUG
        if Self._test_skipPendingScreenDrain { return }   // NEGATIVE CONTROL: pending survives
        #endif
        for (key, pending) in pendingScreenReplacements where pending.id == id {
            pending.gate.retire()
            pending.source.stop()
            pendingScreenReplacements[key] = nil
        }
    }

    /// sol #8 #1: tear down ALL pending screen replacements (shutdown). Same contract as
    /// `drainPendingScreenReplacements(for:)` across every entry.
    private func drainAllPendingScreenReplacements() {
        #if DEBUG
        if Self._test_skipPendingScreenDrain { return }   // NEGATIVE CONTROL: pending survives
        #endif
        for pending in pendingScreenReplacements.values {
            pending.gate.retire()
            pending.source.stop()
        }
        pendingScreenReplacements.removeAll()
    }

    private func reconfigureScreenSourcesForHDR(_ on: Bool) {
        // Snapshot the ids first: we mutate `activeSources` on commit, so iterate a
        // stable list rather than live indices.
        let targets: [(id: SourceID, old: ScreenSource, mailbox: FrameMailbox, descriptor: SourceDescriptor)] =
            activeSources.compactMap { active in
                guard case .screen(let old) = active.backing,
                      old.configuration.preferHDR != on,
                      let mailbox = active.mailbox else { return nil }
                return (active.id, old, mailbox, active.descriptor)
            }
        for target in targets {
            startScreenReplacement(id: target.id, mailbox: target.mailbox,
                                   descriptor: target.descriptor, mode: on,
                                   priorConfig: target.old.configuration, isRestore: false)
        }
    }

    /// sol #7 #2: build, wire, STRONGLY OWN, and start ONE screen-source replacement.
    /// The old source is kept live; the swap commits only when the async start confirms
    /// (`onStarted` → `commitScreenReplacement`). A pending strong owner
    /// (`pendingScreenReplacements`) is held until commit/failure so the `[weak self]`
    /// start Task can't let the source dealloc before `startCapture` acquires it.
    /// `isRestore` marks a post-commit-failure restore (built for the PRIOR mode — exempt
    /// from the commit mode gate). Shared by the HDR reconfigure and the failure restore.
    private func startScreenReplacement(id: SourceID, mailbox: FrameMailbox,
                                        descriptor: SourceDescriptor, mode: Bool,
                                        priorConfig: ScreenCaptureConfiguration, isRestore: Bool) {
        var config = priorConfig
        config.preferHDR = mode
        do {
            let source = try ScreenSource(descriptor: descriptor, configuration: config)
            // sol #10 #2/#3 (SERIALIZE): the pending replacement's gate starts NOT-live and is
            // `arm()`ed only in `commitScreenReplacement`, AFTER the OLD source's gate has been
            // retired+drained (its in-flight body has returned → the shared `SourceEffectGPU` is
            // idle and the `MixerChannel` ingest released). So while the replacement's async
            // `startCapture()` is resolving, its capture-queue callbacks fire but no-op (gated
            // off) — the OLD generation is the ONLY writer of the shared pipeline/channel until
            // the atomic handoff at commit. There is therefore NO window in which both
            // generations concurrently use either shared resource. (sol #8 #1 gate contract kept:
            // `retire()` on remove/shutdown/supersede still silences an in-flight callback.)
            // The `_test_armReplacementGateEagerly` negative control builds it LIVE to reproduce
            // the pre-fix concurrent-overlap.
            #if DEBUG
            let gate = ScreenReplacementGate(live: Self._test_armReplacementGateEagerly)
            #else
            let gate = ScreenReplacementGate(live: false)
            #endif
            source.onFrame = makeGatedScreenFrameCallback(id: id, mailbox: mailbox, gate: gate)
            if config.capturesAudio, let channel = audioMixer.channel(id: id) {
                source.onAudio = makeGatedScreenAudioCallback(id: id, channel: channel, gate: gate)
            }
            // Async SUCCESS → commit the replacement (stop old, swap the entry).
            source.onStarted = { [weak self, weak source] in
                DispatchQueue.main.async {
                    guard let self, let source else { return }
                    self.commitScreenReplacement(id: id, newSource: source,
                                                 mailbox: mailbox, descriptor: descriptor)
                }
            }
            // Async FAILURE → keep the still-running old source (pre-commit) OR restore the
            // prior one (post-commit); surface the error either way.
            source.onError = { [weak self, weak source] error in
                DispatchQueue.main.async {
                    guard let self, let source else { return }
                    self.screenReplacementFailed(id: id, failedSource: source, mode: mode, error: error)
                }
            }
            // sol #12 #1 (ABA supersession — the primary fix): a NEW replacement for a source that
            // ALREADY has a pending replacement SUPERSEDES it. Retire the older pending's gate (which
            // also DROPS its buffered deferred frame — a superseded frame must never replay), stop
            // its (possibly still-resolving) capture, and drop its record NOW. So when the older
            // pending's async start resolves LAST, `commitScreenReplacement` finds `removed == nil`
            // (already dropped) and NO-OPs — it can no longer retire+stop the newer live successor or
            // replay its own stale frame. This is what the mode-only `hdrModeEpoch` check missed for a
            // same-mode ABA (H1 and H2 both target the final HDR mode). Only PENDING (not-yet-committed)
            // records are touched — the live committed source is untouched, so sol #6/#7's
            // keep-old-live-until-confirmed guarantee holds (no screen loss). The generation bump below
            // is the defense-in-depth token the commit re-checks.
            #if DEBUG
            let supersedeOlderPending = !Self._test_skipReplacementSupersession
            #else
            let supersedeOlderPending = true
            #endif
            if supersedeOlderPending {
                // Only supersede a prior NON-restore reconfigure replacement (the ABA lineage). A
                // pending RESTORE keeps its existing epoch-based staleness handling (sol #8 #2 —
                // it may legitimately commit stale-as-exempt or re-derive to the current mode via
                // `restoreWentStale`); dropping it here would defeat post-commit-failure recovery.
                for (key, prior) in pendingScreenReplacements where prior.id == id && !prior.isRestore {
                    prior.gate.retire()
                    prior.source.stop()
                    pendingScreenReplacements[key] = nil
                }
            }
            let generation = (screenReplacementGeneration[id] ?? 0) + 1
            screenReplacementGeneration[id] = generation
            // STRONG owner until commit/failure (sol #7 #2). Keyed by the source identity. sol #12 #1:
            // supersession above means at most one pending per source in production; the `generation`
            // token lets commit reject any superseded record that (in a neutralized-supersession
            // negative control) still coexists.
            #if DEBUG
            _test_lastScreenReplacement = source
            if !Self._test_skipPendingScreenOwnership {
                pendingScreenReplacements[ObjectIdentifier(source)] =
                    PendingScreenReplacement(id: id, source: source, mailbox: mailbox,
                                             mode: mode, isRestore: isRestore,
                                             queuedEpoch: hdrModeEpoch, generation: generation, gate: gate)
            }
            #else
            pendingScreenReplacements[ObjectIdentifier(source)] =
                PendingScreenReplacement(id: id, source: source, mailbox: mailbox,
                                         mode: mode, isRestore: isRestore,
                                         queuedEpoch: hdrModeEpoch, generation: generation, gate: gate)
            #endif
            // NB: `old` is NOT stopped and the entry is NOT swapped here — that
            // happens only in `commitScreenReplacement` once the async start confirms.
            #if DEBUG
            if Self._test_skipScreenSourceStart {
                switch Self._test_simulatedScreenStartOutcome {
                case .success: commitScreenReplacement(id: id, newSource: source,
                                                       mailbox: mailbox, descriptor: descriptor)
                case .failure: screenReplacementFailed(id: id, failedSource: source, mode: mode,
                                                       error: NSError(domain: "prism.test", code: 7))
                case .none: break
                }
            } else {
                try source.start()
            }
            #else
            try source.start()
            #endif
        } catch {
            lastError = "Couldn't switch \(descriptor.name) to \(mode ? "HDR" : "SDR") capture: \(error.localizedDescription)"
        }
    }

    /// sol #6 #7: the replacement screen source's async start CONFIRMED — now (and only
    /// now) stop the old source and swap the live entry to the new one. If a later
    /// reconfigure already superseded us (the entry is no longer backed by an old,
    /// SDR/HDR-mismatched source) the freshly-started `newSource` is an orphan → stop it.
    private func commitScreenReplacement(id: SourceID, newSource: ScreenSource,
                                         mailbox: FrameMailbox, descriptor: SourceDescriptor) {
        // sol #7 #2: release the strong pending owner now that the async start resolved,
        // and remember whether this was a post-commit-failure RESTORE (exempt from the
        // superseded-mode orphan below — a restore deliberately targets the PRIOR mode).
        let removed = pendingScreenReplacements.removeValue(forKey: ObjectIdentifier(newSource))
        // sol #9 #2: the pending record for `newSource` MUST still be the registered pending at
        // commit. `removed == nil` means it was already DRAINED (`removeSource`/`shutdown`) or
        // SUPERSEDED by a newer same-id registration before this async start confirmed — i.e. a
        // stale late `onStarted`. Installing it here would `stop()` the CURRENT live source
        // (e.g. a same-id re-add) and register this now-orphaned, gate-retired source → a dark
        // active screen. NO-OP: leave the current entry untouched; just stop the orphan stream.
        #if DEBUG
        let requirePending = !Self._test_skipCommitPendingIdentityCheck
        #else
        let requirePending = true
        #endif
        if requirePending, removed == nil {
            newSource.stop()
            return
        }
        // sol #12 #1 + #12 #2 (ABA — RESTORE-aware): even with a still-registered pending record, a
        // replacement (RESTORE **or** non-restore) must not commit over a NEWER replacement that has
        // ALREADY WON — i.e. already committed and gone live for `id`. `committedScreenGeneration[id]`
        // is the birth generation of the currently-live committed replacement; a pending whose own
        // birth generation is OLDER than it was superseded by a newer winner → stop the orphan and
        // NO-OP (do NOT retire the live successor, do NOT arm/replay its stale buffered frame).
        //   • The wave-12 same-mode ABA (H1 & H2 both target the final HDR mode) is invisible to the
        //     mode-only `hdrModeEpoch` gate below; in production the registration-time supersession
        //     already dropped the superseded NON-restore H1's record (`removed == nil` handled it
        //     above), so this fires only if a superseded record coexists — e.g. the
        //     `_test_skipReplacementSupersession` negative control.
        //   • The RESTORE ABA (sol #12 #2): a stale SDR restore R resolving AFTER a newer SDR
        //     replacement N already committed-and-went-live would otherwise retire N and replay R's
        //     stale frame. Registration-time supersession must NOT drop a pending RESTORE (that would
        //     defeat the sol #8 #2 recovery — the restore may still need to commit/re-derive), so the
        //     commit-time committed-generation check is the primary guard for the restore path. A LONE
        //     restore (nothing newer committed after it) has `generation >=` the committed generation,
        //     so it still commits/recovers via the `restoreWentStale`/epoch path below.
        #if DEBUG
        let checkGeneration = !Self._test_skipReplacementSupersession
        #else
        let checkGeneration = true
        #endif
        if checkGeneration, let removed,
           removed.generation < (committedScreenGeneration[id] ?? 0) {
            newSource.stop()
            return
        }
        let isRestore = removed?.isRestore ?? false
        // The replacement's mode must not be STALE at commit. Two distinct cases:
        //   • a NON-restore (sol #7 #2) whose `preferHDR` no longer matches `hdrEnabled` was
        //     superseded by a later reconfigure (which already spawned the correct-mode
        //     replacement) → orphan it and keep the current entry.
        //   • a RESTORE (sol #8 #2) is a fallback built for a specific mode at a post-commit
        //     failure. It is legitimate to commit EVEN when it mismatches `hdrEnabled` (an
        //     HDR capture failed and we fall back to the prior SDR capture while the show
        //     still wants HDR) — UNLESS the HDR mode was TOGGLED while the restore was in
        //     flight. `hdrModeEpoch` distinguishes the two: an unchanged epoch = an untouched
        //     immediate fallback (commit as-is); a CHANGED epoch + a current-mode mismatch =
        //     the restore went stale across a toggle (the finding's off→on) — a later
        //     reconfigure does NOT rescue it (the dead live entry already "looks" like the
        //     current mode), so re-derive: orphan the stale restore and re-issue to the
        //     CURRENT mode.
        let modeMismatch = (newSource.configuration.preferHDR != hdrEnabled)
        #if DEBUG
        let exemptRestore = isRestore && Self._test_exemptRestoreFromModeGate  // NEGATIVE CONTROL: pre-fix restore exemption
        #else
        let exemptRestore = false
        #endif
        let restoreWentStale = isRestore && modeMismatch
            && (removed?.queuedEpoch ?? hdrModeEpoch) != hdrModeEpoch && !exemptRestore
        let nonRestoreSuperseded = !isRestore && modeMismatch
        if restoreWentStale || nonRestoreSuperseded {
            removed?.gate.retire()
            newSource.stop()   // orphan the stale replacement/restore
            if restoreWentStale,
               let index = activeSources.firstIndex(where: { $0.id == id }),
               case .screen(let current) = activeSources[index].backing,
               let mbx = activeSources[index].mailbox {
                startScreenReplacement(id: id, mailbox: mbx, descriptor: current.descriptor,
                                       mode: hdrEnabled, priorConfig: current.configuration,
                                       isRestore: false)
            }
            return
        }
        guard let index = activeSources.firstIndex(where: { $0.id == id }),
              case .screen(let current) = activeSources[index].backing else {
            removed?.gate.retire()
            newSource.stop()   // source removed while starting → don't leak the new stream
            return
        }
        // Already the new source (double-commit) → nothing to do.
        if current === newSource { return }
        // sol #10 #2/#3 (SERIALIZE — the definitive fix for the shared-resource races): fully
        // quiesce the OLD source's use of the shared `SourceEffectGPU` (`effectPipelines[id]`)
        // and `MixerChannel` BEFORE the NEW source is allowed to ingest into them. The order is
        // load-bearing:
        //   1. retire the OLD/predecessor gate — its delivery body runs UNDER the gate lock, so
        //      `retire()` BLOCKS until any in-flight old frame/audio body returns → the shared
        //      pipeline is idle (no in-flight GPU work) and the channel ingest is released. From
        //      this instant the old generation delivers NOTHING.
        //   2. stop the old SCStream capture (the confirmed-working predecessor is retired only
        //      now — sol #6 #7 kept: it stayed live through the whole async start).
        //   3. arm the NEW source's deferred gate — only now does the new generation begin
        //      ingesting into the (now-relinquished) shared pipeline/channel. `arm()` ALSO FLUSHES
        //      the successor's buffered latest deferred frame (sol #11 #1) as its first delivery,
        //      UNDER the gate lock, so the swapped-in screen presents immediately instead of
        //      holding stale/black; the flush is serialized against any live capture-queue frame,
        //      so the shared pipeline/channel stay single-writer.
        // There is NO instant at which both generations touch either shared resource, so the
        // SourceEffectGPU (forbids concurrent use) and the MixerChannel (one ingest writer) are
        // never raced — buffering (2) captured only the frame DATA, and the buffered body RUNS in
        // (3) after the old generation has fully relinquished the shared resources. The gap
        // between (1) and (3) is a single synchronous main-actor hop; the only visible cost is a
        // brief reconfigure hitch and, for audio, a short gap (the successor's in-window audio is
        // dropped, not buffered). The drain in (1) can briefly (≤ one in-flight frame) block the
        // main actor. This is the documented, accepted tradeoff (June, lead decision); sol #11 #1
        // removed the earlier video frame-DROP (stale/black hold) without reopening the race.
        committedScreenGates[id]?.retire()   // (1) retire + DRAIN the old/predecessor gate
        current.stop()                        // (2) stop the predecessor's capture
        removed?.gate.arm()                   // (3) arm the new gate + flush its buffered frame
        committedScreenGates[id] = removed?.gate
        // sol #12 #2: record the generation that just went LIVE so any OLDER late-resolving pending
        // (restore or not) is rejected by the committed-generation guard above.
        if let g = removed?.generation { committedScreenGeneration[id] = g }
        activeSources[index] = ActiveSource(id: id, descriptor: descriptor,
                                            backing: .screen(newSource), mailbox: mailbox)
    }

    /// sol #6 #7 + #7 #2: a replacement `ScreenSource` reported `.failed`. Two cases:
    ///
    ///  • PRE-commit failure (the source is still PENDING — its async start never
    ///    confirmed): the old source was never stopped or swapped, so it is still live.
    ///    Drop the pending owner and surface the error; the current capture is preserved.
    ///
    ///  • POST-commit failure (the source is the LIVE entry — a mid-capture window/display
    ///    failure): pre-fix this returned silently, leaving a DEAD source registered with
    ///    no error. Now surface the error, DEREGISTER the failed source, and RESTORE the
    ///    prior source (a fresh capture in the prior mode, reusing the SourceID's mailbox/
    ///    pipeline/scene registration). A restore's OWN failure is a pre-commit failure →
    ///    no recursion.
    private func screenReplacementFailed(id: SourceID, failedSource: ScreenSource,
                                         mode: Bool, error: Error) {
        failedSource.stop()   // the .failed source cleans up its own stream; belt-and-suspenders
        // sol #8 #1: a pre-commit failure drains the pending replacement — retire its
        // frame-callback gate so no late in-flight frame posts after the failure.
        let drained = pendingScreenReplacements.removeValue(forKey: ObjectIdentifier(failedSource))
        drained?.gate.retire()
        let wasPending = drained != nil
        #if DEBUG
        if Self._test_screenRollbackRemovesOnFailure {
            removeSource(id)   // pre-fix: the working screen source is lost on async failure
            return
        }
        #endif
        if wasPending {
            // PRE-commit: the old source is still installed and running — the switch just
            // didn't take. Surface why; the live screen source is preserved (not lost).
            if let index = activeSources.firstIndex(where: { $0.id == id }),
               case .screen(let current) = activeSources[index].backing,
               current !== failedSource {
                lastError = "Couldn't switch \(current.descriptor.name) to \(mode ? "HDR" : "SDR") capture: \(error.localizedDescription). Kept the current screen capture."
            }
            return
        }
        // POST-commit: the failed source IS the live entry. Surface the error, deregister
        // it, and restore the prior source (prior mode = the OTHER of the flipped pair).
        guard let index = activeSources.firstIndex(where: { $0.id == id }),
              case .screen(let current) = activeSources[index].backing,
              current === failedSource,
              let mailbox = activeSources[index].mailbox else { return }
        // sol #9 #1: retire the failed committed source's gate — it must post nothing while the
        // restore is in flight; the restore installs a fresh gate on its own commit.
        committedScreenGates[id]?.retire()
        committedScreenGates[id] = nil
        #if DEBUG
        if Self._test_skipPostCommitScreenRestore { return }   // NEGATIVE CONTROL: pre-fix silent no-op
        #endif
        lastError = "Screen capture \(current.descriptor.name) failed: \(error.localizedDescription). Restoring the previous capture."
        startScreenReplacement(id: id, mailbox: mailbox, descriptor: current.descriptor,
                               mode: !mode, priorConfig: current.configuration, isRestore: true)
    }

    /// Resume the old render loop after an HDR swap aborted because it didn't
    /// quiesce (N1). `stop()` set `running=false` and the wedged pass is still
    /// draining, so `start()` is refused (`threadActive`) until the old render
    /// thread actually exits — retry on the main actor until it takes, rather than
    /// leaving preview frozen. Its scene provider / mailboxes were never torn down
    /// (we quiesce before teardown), so a plain restart resumes the exact prior
    /// program.
    ///
    /// TWO gates bound the retry deterministically instead of giving up early:
    ///   1. `didShutdown` — the app tore everything down (sources stopped, pipelines
    ///      destroyed, `renderLoop?.stop()` issued). A queued retry that fires AFTER
    ///      shutdown must NEVER `start()` the loop: that would spawn a render thread
    ///      over torn-down state (a resurrection). `shutdown()` sets this flag
    ///      synchronously, so any already-queued retry no-ops the moment it runs.
    ///   2. `renderLoop === loop` — a later HDR swap superseded us.
    /// Otherwise keep retrying: `start()` is refused ONLY while the previous render
    /// thread is still alive (`stop()` already cleared `running`), so retrying until
    /// it drains RECOVERS a late-draining pass rather than permanently freezing
    /// preview once the bounded budget lapsed (sol #3). The retry self-terminates
    /// the instant the thread drains (`start()` succeeds) or either gate trips.
    private func resumeRenderLoopAfterFailedQuiesce(_ loop: RenderLoop) {
        // Coalesce (sol #4): if a chain is already retrying THIS loop, don't spawn a
        // second — two overlapping failed-quiesce attempts pass the same `old` loop, and
        // duplicate chains are exactly what let one retry forever after the other
        // recovered. A DIFFERENT loop supersedes (a later swap): adopt it.
        if resumeRetryLoop === loop { return }
        resumeRetryLoop = loop
        retryResumeRenderLoop(loop)
    }

    /// One retry step of the fail-safe HDR resume. Self-terminating: stops the instant
    /// the loop is running again (recovered — by us or the other chain), superseded, or
    /// shutdown. Clears `resumeRetryLoop` on every terminal branch so a later genuine
    /// failed-quiesce can start a fresh chain.
    private func retryResumeRenderLoop(_ loop: RenderLoop) {
        func stopRetrying() { if resumeRetryLoop === loop { resumeRetryLoop = nil } }
        #if DEBUG
        _test_resumeRetryAttempts += 1
        // NEGATIVE CONTROL seam: neutralize ONLY the didShutdown guard so a test can
        // prove it is load-bearing (with it bypassed, a post-shutdown retry resurrects
        // the render thread — red).
        if !Self._test_bypassShutdownResumeGuard, didShutdown { stopRetrying(); return }
        #else
        if didShutdown { stopRetrying(); return }   // shutdown in progress/complete — never resurrect
        #endif
        guard renderLoop === loop else { stopRetrying(); return }   // superseded by a later swap
        // Distinguish "the loop is already running again" (someone — the other chain, or
        // a prior step — recovered it: SUCCESS, stop retrying) from "still draining"
        // (`start()` refused because the previous render thread hasn't exited yet).
        // Without this, a duplicate chain reads the post-recovery `start()==false` as
        // "still draining" and retries every 100 ms FOREVER (sol #4 regression).
        #if DEBUG
        let checkRunning = !Self._test_bypassResumeRunningCheck
        #else
        let checkRunning = true
        #endif
        if checkRunning, loop.isRunning { stopRetrying(); return }
        if loop.start() { stopRetrying(); return }  // WE resumed it (the wedged thread had drained)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                self?.retryResumeRenderLoop(loop)
            }
        }
    }
}

#if DEBUG
extension AppEngine {
    /// Drive the HDR fail-safe resume directly (sol #3): simulates the queued
    /// `asyncAfter` retry firing at an arbitrary time (e.g. AFTER shutdown), so a
    /// test can prove the retry no-ops post-shutdown instead of resurrecting a
    /// render thread over torn-down state.
    func _test_resumeRenderLoopAfterFailedQuiesce(_ loop: RenderLoop) {
        resumeRenderLoopAfterFailedQuiesce(loop)
    }

    /// Narrow App-integration test seam: proves prepared auxiliary registrations
    /// survive a loop replacement without exposing mutable production state.
    var integrationDebugAuxiliarySourceIDs: Set<SourceID> {
        Set(auxiliarySources.keys)
    }

    func integrationDebugInstallCutout(_ source: PresenterCutoutSource,
                                       state: CutoutState,
                                       for id: SourceID) {
        cutoutSources[id] = source
        cutoutStates[id] = state
    }

    var integrationDebugCutoutCounts: (sources: Int, states: Int) {
        (cutoutSources.count, cutoutStates.count)
    }

    /// sol #12 #2 (finding #5) test seam: the live cutout wrapper for `id` (nil ⇒ raw feed), so a
    /// test can install `_test_beforeCutout` and prove the active backing routes through it.
    func integrationDebugCutoutSource(for id: SourceID) -> PresenterCutoutSource? { cutoutSources[id] }

    /// sol #12 #2 (finding #5) test seam: the live backing `MovieSource` for `id` (drives its
    /// `onFrame` directly to prove where the frame graph routes).
    func integrationDebugMovieBacking(for id: SourceID) -> MovieSource? {
        guard let s = activeSources.first(where: { $0.id == id }),
              case .movie(let m) = s.backing else { return nil }
        return m
    }

    var integrationDebugVerticalSnapshot: LatestFrameTap.Snapshot {
        verticalTap.snapshot()
    }

    var integrationDebugActiveStingerSourceID: SourceID? {
        activeStingerSourceID
    }

    /// The live meme-provider teardown deadline in HOUSE-clock seconds (F21) —
    /// nil when no provider is scheduled. Proves the deadline is stored as
    /// house-time, not a wall-clock `Date`.
    var integrationDebugMemeProviderDeadlineHouse: Double? {
        memeDeadlinesHouse.values.min()
    }

    /// Peek the newest frame retained for an auxiliary (meme) source's mailbox,
    /// without consuming it — lets a test observe the frame a trigger cued (F14).
    func integrationDebugAuxiliaryNewestFrame(_ id: SourceID) -> VideoFrame? {
        auxiliarySources[id]?.mailbox.takeNewest()
    }

    /// Current aggregate decoded-byte total across all active animated memes and
    /// the hard ceiling it is bounded to (F15 / Class F).
    var integrationDebugAnimatedMemeBytes: (total: Int, ceiling: Int) {
        (animatedMemeDecodedBytes, Self.animatedMemeAggregateByteBudget)
    }

    /// Whether an auxiliary (meme) source is currently RUNNING — proves an animated
    /// meme stays paused at registration and is stopped at hold end (F14).
    func integrationDebugAuxiliaryIsRunning(_ id: SourceID) -> Bool {
        auxiliarySources[id]?.source.state == .running
    }

    /// Whether the meme scene provider is currently installed (a triggered meme is
    /// live) — proves a failed cue installs NO provider (F14) and a superseded/
    /// removed/torn-down async cue installs none (async-cue regression).
    var integrationDebugMemeProviderInstalled: Bool { memeProviderInstalled }

    /// The live cue generation — proves remove/shutdown/trigger bump it, superseding
    /// an in-flight frame-zero cue (async-cue regression).
    var integrationDebugCueGeneration: UInt64 { cueGenerations.withLock { $0.values.reduce(0, &+) } }

    /// Number of retained per-source cue-generation keys (sol #4 leak): must not grow
    /// monotonically with add+remove cycles — `removeMeme` reclaims its key, shutdown
    /// clears the dict.
    var integrationDebugCueGenerationKeyCount: Int { cueGenerations.withLock { $0.count } }

    /// Force ALL house-time meme lifetimes to expire NOW and run the teardown, so a
    /// test can drive hold-end deterministically (F14 stop/reset at hold end).
    func integrationDebugExpireMemeProviderNow() {
        let past = HouseClock.nowSeconds() - 1
        for id in memeDeadlinesHouse.keys { memeDeadlinesHouse[id] = past }
        teardownMemeProviderIfIdle()
    }

    /// Ids of live movie sources (proves an alpha ProRes 4444 movie registered).
    var integrationDebugMovieSourceIDs: [SourceID] { Array(movieSources.keys) }

    /// Count of live active (resting) scene sources (F15 reject-before-register).
    var integrationDebugActiveSourceCount: Int { activeSources.count }

    /// Live active-source IDs in registration order (F15 — prove the OLDEST
    /// animated source is the one evicted when the aggregate ceiling is exceeded).
    var integrationDebugActiveSourceIDs: [SourceID] { activeSources.map(\.id) }

    /// The live scene layer's `premultipliedAlpha` for a source (Class C — proves
    /// an alpha movie's layer honors its alpha end-to-end).
    func integrationDebugLayerPremultiplied(_ id: SourceID) -> Bool? {
        scene.layers.first { $0.sourceID == id }?.premultipliedAlpha
    }

    /// Register a pre-built (NOT started) screen source into the live scene, so a
    /// headless test can exercise the HDR reconfigure without a real capture (sol #5
    /// #3). `ScreenSource.init` performs no capture, so this trips no TCC.
    func integrationDebugRegisterScreenSource(_ source: ScreenSource, descriptor: SourceDescriptor) {
        let mailbox = FrameMailbox()
        _ = makeEffectPipeline(for: source.id)
        // sol #10 #1: mirror `addScreen`'s gated wiring so a headless test exercises the REAL
        // original-source frame + audio gating (no capture / TCC — `start()` is never called).
        let gate = ScreenReplacementGate()
        #if DEBUG
        let cbGate: ScreenReplacementGate? = Self._test_skipOriginalScreenGate ? nil : gate
        #else
        let cbGate: ScreenReplacementGate? = gate
        #endif
        source.onFrame = makeGatedScreenFrameCallback(id: source.id, mailbox: mailbox, gate: cbGate)
        if source.configuration.capturesAudio {
            ensureAudioMixerStarted()
            if let channel = try? audioMixer.addChannel(id: source.id) {
                source.onAudio = makeGatedScreenAudioCallback(id: source.id, channel: channel, gate: cbGate)
            }
        }
        #if DEBUG
        if !Self._test_skipOriginalScreenGate { committedScreenGates[source.id] = gate }
        #else
        committedScreenGates[source.id] = gate
        #endif
        register(ActiveSource(id: source.id, descriptor: descriptor,
                              backing: .screen(source), mailbox: mailbox))
    }

    /// The `preferHDR` flag of the live screen source backing `id` (sol #5 #3 —
    /// proves an HDR toggle reconfigured the capture to request the HDR path).
    func integrationDebugScreenSourcePreferHDR(_ id: SourceID) -> Bool? {
        guard let active = activeSources.first(where: { $0.id == id }),
              case .screen(let source) = active.backing else { return nil }
        return source.configuration.preferHDR
    }

    /// The live scene layer for a source (sol #5 #10 — proves a failed-admission
    /// rollback restores the victim's exact transform, not a default full-canvas layer).
    func integrationDebugLayer(_ id: SourceID) -> Layer? {
        scene.layers.first { $0.sourceID == id }
    }

    /// The live per-source effects snapshot (sol #5 #10 — proves rollback restores
    /// the victim's effects, not defaults).
    func integrationDebugSourceEffects(_ id: SourceID) -> SourceEffects? {
        sourceEffects[id]
    }

    /// The live ordinary-GIF source id currently backing `url` (sol #5 #10 — a
    /// re-admitted victim gets a fresh id, so a test finds it by media URL).
    func integrationDebugAnimatedGIFSourceID(for url: URL) -> SourceID? {
        animatedGIFSourceURLs.first { $0.value == url }?.key
    }
}
#endif

// MARK: - Sound / Music pass-throughs (PrismSound: soundboard + beats + music bed)

/// A loopable music-bed choice for the Sound tab's bed player (synth or library).
struct MusicBedChoice: Identifiable, Hashable {
    let id: String
    let name: String
}

extension AppEngine {

    // MARK: Sound stack lifecycle (build = no hardware; live = opens audio HW)

    /// Load the catalog + build the soundboard/beat/bed objects (attaches their
    /// mixer channels) WITHOUT starting audio hardware. Call from the Sound tab's
    /// `.onAppear` so browsing/assigning works before anything makes a sound.
    func prepareSound() { buildSoundStack() }

    private func buildSoundStack() {
        guard !soundStackBuilt else { return }
        soundStackBuilt = true
        // No library installed → nil is fine; the board/beat/bed still build and
        // the UI degrades to an empty catalog (synth beds still play).
        soundLibrary = SoundLibrary.loadDefault()
        soundLibraryLoaded = (soundLibrary != nil)
        do {
            soundboard = try Soundboard(mixer: audioMixer, library: soundLibrary)
            beatSequencer = try BeatSequencer(mixer: audioMixer, library: soundLibrary)
            // Beat-sync (BEAT_SYNC_DESIGN): `onBeat` fires on the sequencer's clock
            // queue (@Sendable). Hop to the main actor before touching app state —
            // then advance any "cut on beat" montage. Mirrors the feeder callback.
            beatSequencer?.onBeat = { [weak self] index in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.handleBeatCut(beatIndex: index)
                }
            }
            musicBed = try MusicBed(mixer: audioMixer, library: soundLibrary)
            musicBed?.volume = Float(bedVolume)
            setupSoundDefaults()
        } catch {
            lastError = "Sound engine failed to initialize: \(error.localizedDescription)"
        }
    }

    /// Ensure the mixer + each sound engine are live (opens the default output).
    /// Idempotent — `startLive()` no-ops when already running.
    private func ensureSoundLive() {
        buildSoundStack()
        ensureAudioMixerStarted()
        try? soundboard?.startLive()
        try? beatSequencer?.startLive()
        try? musicBed?.startLive()
    }

    private func setupSoundDefaults() {
        // Music beds: two always-available synth beds + any loopable library beds.
        var beds: [MusicBedChoice] = []
        if let bed = musicBed {
            bed.register(id: "bed.warm", buffer: MusicBed.synthesizeChordBed(rootMidi: 48, minor: false))
            bed.register(id: "bed.calm", buffer: MusicBed.synthesizeChordBed(rootMidi: 45, minor: true))
            beds = [MusicBedChoice(id: "bed.warm", name: "Warm Pad (synth)"),
                    MusicBedChoice(id: "bed.calm", name: "Calm Minor (synth)")]
        }
        if let lib = soundLibrary {
            beds += lib.loopable.map { MusicBedChoice(id: $0.id, name: $0.name) }
        }
        musicBeds = beds

        // Beat pattern: prefer the operator's persisted grid (survives relaunch);
        // otherwise a starter groove if drum samples exist, else an empty 3-track
        // grid the operator can still edit (silent without samples).
        if let saved = Self.loadPersistedBeatPattern() {
            try? beatSequencer?.load(pattern: saved)
            beatPattern = saved
        } else if let kick = libSoundID("kick"), let snare = libSoundID("snare"), let hat = libSoundID("hat") {
            let pattern = BeatSequencer.basicPattern(kick: kick, snare: snare, hat: hat)
            try? beatSequencer?.load(pattern: pattern)
            beatPattern = pattern
        } else {
            beatPattern = BeatPattern(bpm: 120, swing: 0, stepCount: 16, tracks: [
                BeatTrack(name: "Kick", soundID: "", steps: Array(repeating: BeatStep(), count: 16)),
                BeatTrack(name: "Snare", soundID: "", steps: Array(repeating: BeatStep(), count: 16)),
                BeatTrack(name: "Hat", soundID: "", steps: Array(repeating: BeatStep(), count: 16)),
            ])
        }

        // Pads: auto-fill from the library on first run if none are assigned.
        if padAssignments.allSatisfy({ $0 == nil }), let lib = soundLibrary {
            for (i, entry) in lib.entries.prefix(16).enumerated() where padAssignments.indices.contains(i) {
                padAssignments[i] = entry.id
            }
            savePadAssignments()
        }
        for id in padAssignments.compactMap({ $0 }) { try? soundboard?.preload(id: id) }
    }

    private func libSoundID(_ term: String) -> String? { soundLibrary?.search(term).first?.id }

    // MARK: Catalog browsing (library-only — no hardware)

    var soundCategories: [String] { soundLibrary?.categories ?? [] }
    func sounds(inCategory category: String) -> [SoundEntry] {
        soundLibrary?.entries(inCategory: category) ?? []
    }
    func searchSounds(_ query: String) -> [SoundEntry] {
        guard let lib = soundLibrary else { return [] }
        return query.isEmpty ? lib.entries : lib.search(query)
    }
    func soundName(forID id: String) -> String { soundLibrary?.entry(id: id)?.name ?? id }
    func soundCategory(forID id: String) -> String? { soundLibrary?.entry(id: id)?.category }

    // MARK: Soundboard

    /// Trigger a sound into the program mix (records / streams / meters / ducks).
    func triggerSound(id: String) {
        ensureSoundLive()
        guard let sb = soundboard else { return }
        if sb.buffer(id: id) == nil { try? sb.preload(id: id) }
        try? sb.trigger(id: id)
    }

    func assignSoundToPad(_ index: Int, id: String) {
        buildSoundStack()
        guard padAssignments.indices.contains(index) else { return }
        try? soundboard?.preload(id: id)
        padAssignments[index] = id
        savePadAssignments()
    }

    func clearPad(_ index: Int) {
        guard padAssignments.indices.contains(index) else { return }
        padAssignments[index] = nil
        savePadAssignments()
    }

    private static let padDefaultsKey = "studio.prism.sound.pads"
    static func loadPadAssignments() -> [String?] {
        if let arr = UserDefaults.standard.array(forKey: padDefaultsKey) as? [String] {
            var out: [String?] = arr.map { $0.isEmpty ? nil : $0 }
            while out.count < 16 { out.append(nil) }
            return Array(out.prefix(16))
        }
        return Array(repeating: nil, count: 16)
    }
    private func savePadAssignments() {
        UserDefaults.standard.set(padAssignments.map { $0 ?? "" }, forKey: Self.padDefaultsKey)
    }

    // MARK: Beat maker

    func toggleBeatStep(track: Int, step: Int) {
        guard beatPattern.tracks.indices.contains(track),
              beatPattern.tracks[track].steps.indices.contains(step) else { return }
        beatPattern.tracks[track].steps[step].on.toggle()
        beatSequencer?.pattern = beatPattern
        saveBeatPattern()
    }
    func setBPM(_ value: Double) {
        beatPattern.bpm = value
        beatSequencer?.pattern = beatPattern
        broadcastBeatClock() // tempo change → refresh beat-synced tiles/pulses
        saveBeatPattern()
    }
    func setSwing(_ value: Double) {
        beatPattern.swing = value; beatSequencer?.pattern = beatPattern
        saveBeatPattern()
    }

    func playBeats() {
        ensureSoundLive()
        guard let seq = beatSequencer else { return }
        seq.pattern = beatPattern
        seq.play()
        beatIsPlaying = true
        broadcastBeatClock() // anchor is now set → beat-synced effects go live
    }
    func stopBeats() {
        beatSequencer?.stop()
        beatIsPlaying = false
        broadcastBeatClock() // → .stopped: tiles free-run, pulse goes identity
    }

    // MARK: Music bed

    func playBed(id: String) {
        ensureSoundLive()
        guard let bed = musicBed else { return }
        if bed.buffer(id: id) == nil { try? bed.preload(id: id) }
        do { try bed.play(id: id); bedIsPlaying = true; activeBedID = id }
        catch { lastError = "Couldn't play music bed: \(error.localizedDescription)" }
    }
    func stopBed() { musicBed?.stop(); bedIsPlaying = false; activeBedID = nil }
    func setBedVolume(_ value: Double) { bedVolume = value; musicBed?.volume = Float(value) }

    /// Duck the music bed under the first live microphone (its own mixer channel
    /// makes this the existing sidechain path). No mic → a note, no crash.
    func setBedDucking(_ enabled: Bool) {
        bedDuckingEnabled = enabled
        ensureSoundLive()
        guard let bed = musicBed else { return }
        if enabled {
            guard let mic = activeSources.first(where: { $0.isAudio })?.id else {
                lastError = "Add a microphone to duck the music under."
                return
            }
            do {
                try audioMixer.setDucking(target: bed.channelID, key: mic,
                                          config: DuckingConfig(thresholdDB: -28, ratio: 8))
            } catch {
                lastError = "Couldn't enable ducking: \(error.localizedDescription)"
            }
        } else {
            audioMixer.clearDucking(target: bed.channelID)
        }
    }
}

// MARK: - MemeBoard pass-throughs (PrismCompositor.VisualFX)

extension AppEngine {

    private func registerAuxiliarySource(_ source: VideoSource, mailbox: FrameMailbox) {
        auxiliarySources[source.id] = AuxiliaryVideoSource(source: source, mailbox: mailbox)
        renderLoop?.setMailbox(mailbox, for: source.id)
        dualProgram?.attach(source: source.id)
    }

    /// Remove an auxiliary registration from both programs and release each
    /// compositor's retained IOSurface/tombstone state. The caller stops the
    /// source first so its callback cannot repopulate either cache afterward.
    @discardableResult
    private func removeAuxiliarySource(_ id: SourceID) -> VideoSource? {
        let source = auxiliarySources.removeValue(forKey: id)?.source
        renderLoop?.removeMailbox(for: id)
        verticalTap.forget(id)
        dualProgram?.forget(source: id)
        return source
    }

    /// Copyright boundary copy shown by the Memes tab.
    var memeCopyrightNotice: String { MemeTemplateGenerator.copyrightNotice }

    /// Generate + register the bundled, royalty-free FORMAT templates (idempotent).
    /// Call from the Memes tab's `.onAppear`.
    func prepareMemes() {
        guard !memeTemplatesReady else { return }
        memeTemplatesReady = true
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("studio.prism.app/MemeTemplates", isDirectory: true)
        do {
            let templates = try MemeTemplateGenerator.generateDefaults(into: dir)
            for t in templates {
                addMeme(url: t.url, mode: t.suggestedMode,
                        placement: t.suggestedPlacement, holdSec: 1.5, isBuiltIn: true)
            }
        } catch {
            lastError = "Couldn't generate meme templates: \(error.localizedDescription)"
        }
        restoreUserMemes() // re-add the operator's own tiles after the built-ins
    }

    /// Register a meme media file as a compositor source (mailbox registered so
    /// its frames are ready) and add a `MemeItem`. The source is retained OUTSIDE
    /// `activeSources` — it is not a resting scene layer; the `MemeDirector` adds
    /// its layer transiently only while triggered.
    func addMeme(url: URL, mode: MemeMode, placement: MemePlacement,
                 holdSec: Double, isBuiltIn: Bool = false) {
        // F15: enforce the app-wide aggregate decoded-media ceiling BEFORE decoding. The
        // cost is estimated from metadata (GIF frame count × capped decode size), so an
        // over-budget GIF is REJECTED without decoding; a fitting one may evict the oldest
        // animated sources (LRU). One that cannot fit even alone is rejected outright.
        let cost = Self.estimatedAnimatedByteCost(url: url, mode: mode)
        let plan = planAnimatedAdmission(cost: cost)
        guard plan.admit else {
            lastError = "Meme \(url.lastPathComponent) exceeds the animated-media budget."
            return
        }
        // sol #4: evict victims BEFORE decoding the replacement so PEAK resident bytes
        // never exceed the ceiling (evict-on-success overshot peak — victims + replacement
        // both resident during decode). Capture rollback re-admitters first so a decode/
        // alloc failure RE-ADMITS the victims (no destructive loss — wave-4's guarantee).
        let readmits = captureAnimatedVictimSnapshots(plan.evict)
        #if DEBUG
        if !Self._test_evictAfterConstruct { commitAnimatedEviction(plan.evict) }
        Self._test_beforeAnimatedDecodeHook?()   // observe: victims already evicted, pre-decode
        #else
        commitAnimatedEviction(plan.evict)
        #endif
        do {
            #if DEBUG
            try Self._test_throwIfForcedConstructionFailure()
            #endif
            // GIF → animated loop; movie file → clip; else → still image. All are
            // `VideoSource`s emitting frames, so the same MemeDirector trigger path
            // (Cut-To / Insert / Stinger) animates whichever kind is fed in.
            let (source, scopedURL) = try makeMemeSource(url: url, mode: mode)
            let isAnimated = source is AnimatedGIFSource || source is MovieSource
            let mailbox = FrameMailbox()
            // The mailbox is registered in the primary RenderLoop; its exact
            // deadline-qualified take is forwarded to 9:16 by onTickSnapshot.
            source.onFrame = { [mailbox] frame in mailbox.post(frame) }
            // F14 / Class D: do NOT start an animated (GIF/movie) meme at
            // registration — that made it FREE-RUN so a trigger opened on whatever
            // loop phase happened to be resident. Keep it paused until `triggerMeme`
            // cues it to frame ZERO. A still image IS started so its single frame is
            // resident for an immediate (uncued) trigger.
            if !isAnimated {
                do {
                    try source.start()
                } catch {
                    if let scopedURL { scopedURL.stopAccessingSecurityScopedResource() }
                    throw error
                }
            }
            registerAuxiliarySource(source, mailbox: mailbox)
            if let scopedURL { memeScopedURLs[source.id] = scopedURL }
            #if DEBUG
            if Self._test_evictAfterConstruct { commitAnimatedEviction(plan.evict) }  // NEGATIVE CONTROL: peak overshoot
            #endif
            trackAnimatedSource(source.id, cost: cost)   // F15: aggregate budget accounting
            memeItems.append(MemeItem(name: url.deletingPathExtension().lastPathComponent,
                                      mediaURL: url, sourceID: source.id, mode: mode,
                                      holdSec: max(0.2, holdSec), placement: placement,
                                      isBuiltInTemplate: isBuiltIn))
            if !isBuiltIn { saveUserMemes() } // user tiles persist across relaunch
        } catch {
            rollbackAnimatedEviction(readmits)   // sol #4: re-admit the evicted victims
            lastError = "Couldn't add meme \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Build the compositor source for a meme file. A `.gif` becomes an
    /// `AnimatedGIFSource` (transparent, looping), a movie file a looping
    /// `MovieSource`, and anything else the existing still `ImageSource`. Returns
    /// the source plus, for a `MovieSource` (which streams from disk for its whole
    /// lifetime), the URL whose security-scoped grant the caller must HOLD until
    /// the meme is removed (nil for image/GIF, which decode fully at init).
    private func makeMemeSource(url: URL, mode: MemeMode) throws -> (source: VideoSource, scopedURL: URL?) {
        // Cut-To and Stinger must cover the program at the cue (fill/crop).
        // Inserts fit + keep transparency so a GIF composites as a placed overlay.
        let fitMode: ImageSource.ContentMode = mode == .insert ? .aspectFit : .aspectFill
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .gif) == true {
            // background defaults to `.clear` → transparent areas show program through.
            let source = try AnimatedGIFSource(fileURL: url, canvasSize: Self.sourceCanvas,
                                               contentMode: fitMode, loop: true)
            return (source, nil)
        }
        if type?.conforms(to: .movie) == true {
            // Hold the security-scoped grant for the source's lifetime (mirrors
            // addMovieSource); balanced in removeMeme / deactivateAll.
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                let source = try MovieSource(fileURL: url, canvasSize: Self.sourceCanvas,
                                             contentMode: fitMode, loop: true)
                return (source, scoped ? url : nil)
            } catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
                throw error
            }
        }
        let source = try ImageSource(fileURL: url, canvasSize: Self.sourceCanvas,
                                     contentMode: fitMode, background: .clear)
        return (source, nil)
    }

    /// Decoded-byte cost estimate for an animated meme source (F15). A GIF holds
    /// every frame resident (`frameCount · w · h · 4`); a `MovieSource` streams
    /// from disk so its resident decode footprint is a small bounded set of canvas
    /// buffers. Stills are untracked (≈ one small buffer). Returns 0 for a still.
    static func animatedMemeByteCost(for source: VideoSource) -> Int {
        if let gif = source as? AnimatedGIFSource {
            return max(0, gif.frameCount) * max(1, gif.frameWidth) * max(1, gif.frameHeight) * 4
        }
        if source is MovieSource {
            // Streamed: a handful of canvas-sized decode buffers, not the whole clip.
            return sourceCanvas.width * sourceCanvas.height * 4 * 3
        }
        return 0
    }

    /// Plan admission of a new animated meme costing `newCost` bytes against a
    /// hard aggregate `ceiling`, given the currently-resident animated memes in
    /// LRU order (`current`, oldest first). Evicts oldest memes until the new one
    /// fits; rejects the new meme if it cannot fit even after evicting everything.
    /// Pure + deterministic (F15 / Class F — testable without a live pipeline).
    static func planAnimatedMemeAdmission(newCost: Int,
                                          current: [(id: SourceID, cost: Int)],
                                          ceiling: Int) -> (evict: [SourceID], admitNew: Bool) {
        guard newCost <= ceiling else { return (current.map(\.id), false) }   // too big alone
        var total = current.reduce(0) { $0 + $1.cost }
        var evict: [SourceID] = []
        var idx = 0
        while total + newCost > ceiling, idx < current.count {
            evict.append(current[idx].id)
            total -= current[idx].cost
            idx += 1
        }
        return (evict, total + newCost <= ceiling)
    }

    /// Pre-decode resident-byte estimate for an animated media file (F15): a GIF's
    /// `frameCount × capped-decode-size × 4` read from metadata (no decode), a
    /// movie's bounded streamed decode footprint, or 0 for a still. Lets admission
    /// run BEFORE the source is constructed/decoded.
    static func estimatedAnimatedByteCost(url: URL, mode: MemeMode) -> Int {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .gif) == true {
            let fit: ImageSource.ContentMode = mode == .insert ? .aspectFit : .aspectFill
            return AnimatedGIFSource.estimatedResidentBytes(url: url, canvasSize: sourceCanvas, contentMode: fit)
        }
        if type?.conforms(to: .movie) == true {
            return sourceCanvas.width * sourceCanvas.height * 4 * 3   // streamed nominal
        }
        return 0
    }

    /// Plan admission of a new animated source costing `cost` bytes against the
    /// app-wide aggregate ceiling — WITHOUT side effects (sol #3). Returns the oldest
    /// animated sources (memes OR ordinary GIFs) that would need to be evicted, plus
    /// whether the new one fits at all (`admit == false` when it can't fit even after
    /// evicting everything — the caller must not construct/decode). The eviction is
    /// committed via `commitAnimatedEviction` ONLY after the replacement is
    /// successfully constructed, so a decode/alloc failure never destroys the
    /// existing live sources with no rollback (evict-on-success).
    private func planAnimatedAdmission(cost: Int) -> (evict: [SourceID], admit: Bool) {
        guard cost > 0 else { return ([], true) }
        let current = animatedMemeLRU.map { (id: $0, cost: animatedMemeByteCost[$0] ?? 0) }
        let plan = Self.planAnimatedMemeAdmission(newCost: cost, current: current,
                                                  ceiling: Self.animatedMemeAggregateByteBudget)
        return (plan.evict, plan.admitNew)
    }

    /// Evict the planned victims. Called BEFORE decoding the replacement (sol #4
    /// evict-before-decode) so peak resident bytes never exceed the ceiling — the
    /// victims' decoded frames are freed before the new source's are allocated.
    /// Idempotent per id (`evictAnimatedSource` no-ops an already-gone source).
    private func commitAnimatedEviction(_ evict: [SourceID]) {
        for victim in evict { evictAnimatedSource(victim) }
    }

    /// The FULL prior state of an animated victim, captured BEFORE eviction so a
    /// failed replacement admit restores it EXACTLY (sol #5 #10) — not the pre-fix
    /// bare re-add-by-URL that produced a fresh SourceID/item with DEFAULTS (losing
    /// the scene layer + transform, per-source effects, arm state, and layer motion).
    /// The decoded FRAMES are still freed (the peak-ceiling fix), but this metadata is
    /// tiny and preserved; on rollback it is re-applied to the re-decoded source.
    /// sol #8 #4: every case carries the victim's ORIGINAL SourceID so a rollback can
    /// rebuild the LRU in its TRUE pre-eviction relative order (see `AnimatedEvictionPlan`).
    private enum AnimatedVictimSnapshot {
        /// A meme (`auxiliarySources`): its stable identity (`item.id` / name / list
        /// position), armed-stinger flag, and placement/hold survive the rollback.
        case meme(item: MemeItem, wasArmedStinger: Bool, listIndex: Int, originalID: SourceID)
        /// An ordinary GIF (`activeSources`): its scene layer (transform/crop/opacity/
        /// rotation/zIndex/visibility/premult), per-source effects, ISO/multitrack arm
        /// state, layer motion, AND its vertical-hero + stinger-media routing (sol #6
        /// #10) survive the rollback.
        case gif(url: URL, layer: Layer?, effects: SourceEffects?,
                 isoArmed: Bool, multitrackArmed: Bool,
                 motion: (kind: LayerMotionKind, speed: Double)?,
                 verticalHero: Bool, stingerMedia: Bool, originalID: SourceID)
    }

    /// sol #8 #4: the victim snapshots PLUS the full `animatedMemeLRU` order (oldest-first)
    /// captured BEFORE eviction. The rollback rebuilds the LRU from this true pre-eviction
    /// order — reinserting each re-admitted victim at its ORIGINAL raw index against the
    /// now-SHRUNK LRU reversed newer survivors on a partial multi-victim rollback.
    private struct AnimatedEvictionPlan {
        let snapshots: [AnimatedVictimSnapshot]
        let preEvictionLRU: [SourceID]
    }

    /// Snapshot the victims' FULL state BEFORE they are evicted (sol #5 #10). If the
    /// replacement's decode/alloc then FAILS, `rollbackAnimatedEviction` re-admits the
    /// media AND re-applies this state — reconciling the peak-ceiling fix (evict before
    /// decode) with wave-4's no-destructive-loss guarantee, without collapsing a
    /// configured source back to defaults.
    private func captureAnimatedVictimSnapshots(_ evict: [SourceID]) -> AnimatedEvictionPlan {
        // sol #8 #4: capture the full pre-eviction LRU order — the rollback rebuilds from it.
        let preEvictionLRU = animatedMemeLRU
        var snapshots: [AnimatedVictimSnapshot] = []
        for id in evict {
            if let index = memeItems.firstIndex(where: { $0.sourceID == id }) {
                let meme = memeItems[index]
                snapshots.append(.meme(item: meme,
                                       wasArmedStinger: armedStingerMemeID == meme.id,
                                       listIndex: index, originalID: id))
            } else if let url = animatedGIFSourceURLs[id] {
                let motion: (LayerMotionKind, Double)? = layerMotions[id].map { ($0.kind, $0.speed) }
                snapshots.append(.gif(url: url,
                                      layer: scene.layers.first { $0.sourceID == id },
                                      effects: sourceEffects[id],
                                      isoArmed: isoArmedSourceIDs.contains(id),
                                      multitrackArmed: multitrackArmedSourceIDs.contains(id),
                                      motion: motion,
                                      verticalHero: verticalHeroSourceID == id,
                                      stingerMedia: stingerMediaID == id, originalID: id))
            }
        }
        return AnimatedEvictionPlan(snapshots: snapshots, preEvictionLRU: preEvictionLRU)
    }

    /// Re-admit each evicted victim AND restore its captured state (a failed
    /// replacement admit — sol #5 #10). The victim is re-decoded (its frames were
    /// freed), then its scene layer / transform / effects / arm state / motion /
    /// identity are re-applied to the fresh source — so a rollback is invisible to the
    /// user, not a reset to defaults.
    private func rollbackAnimatedEviction(_ plan: AnimatedEvictionPlan) {
        let snapshots = plan.snapshots
        #if DEBUG
        if Self._test_skipAdmissionRollback { return }   // NEGATIVE CONTROL: destructive loss
        if Self._test_rollbackBareReadmit {               // NEGATIVE CONTROL: bytes-only (state lost)
            for snap in snapshots {
                switch snap {
                case .meme(let item, _, _, _):
                    addMeme(url: item.mediaURL, mode: item.mode, placement: item.placement,
                            holdSec: item.holdSec, isBuiltIn: item.isBuiltInTemplate)
                case .gif(let url, _, _, _, _, _, _, _, _):
                    addGIFSource(fileURL: url)
                }
            }
            return
        }
        #endif
        // sol #8 #4: map each victim's ORIGINAL id → its re-admitted NEW id (absent = the
        // victim's OWN re-decode failed → permanently dropped). Used to rebuild the LRU in
        // the true pre-eviction order after all re-adds (each re-add appended at the newest end).
        var victimNewID: [SourceID: SourceID] = [:]
        for snap in snapshots {
            switch snap {
            case .meme(let item, let wasArmed, let listIndex, let originalID):
                let before = Set(memeItems.map(\.id))
                addMeme(url: item.mediaURL, mode: item.mode, placement: item.placement,
                        holdSec: item.holdSec, isBuiltIn: item.isBuiltInTemplate)
                // Restore the victim's stable identity / name / list position so armed-
                // stinger references and tile ordering survive (the re-add minted a new
                // UUID + appended at the end).
                guard let newIndex = memeItems.firstIndex(where: { !before.contains($0.id) }) else { continue }
                var restored = memeItems.remove(at: newIndex)
                restored.id = item.id
                restored.name = item.name
                memeItems.insert(restored, at: min(listIndex, memeItems.count))
                if wasArmed { armedStingerMemeID = item.id }
                if !item.isBuiltInTemplate { saveUserMemes() }
                victimNewID[originalID] = restored.sourceID
            case .gif(let url, let layer, let effects, let iso, let mt, let motion, let wasHero, let wasStinger, let originalID):
                // sol #6 #10: bind restored state to the ACTUAL re-admitted id from the
                // re-add RESULT, not `lastAddedVideoSourceID`. On the DOUBLE-failure (the
                // victim's OWN re-decode also fails) `addGIFSource` returns nil — restore
                // NOTHING, never mutate an unrelated source that `lastAdded` happens to name.
                let readmitted = addGIFSource(fileURL: url)
                #if DEBUG
                let resolvedID = Self._test_rollbackBindToLastAdded ? lastAddedVideoSourceID : readmitted
                #else
                let resolvedID = readmitted
                #endif
                guard let newID = resolvedID else { continue }
                // Restore the victim's exact scene layer (remapped to the fresh source
                // id) in place of the default full-canvas layer the re-add created.
                if var layer, let i = scene.layers.firstIndex(where: { $0.sourceID == newID }) {
                    layer.sourceID = newID
                    scene.layers[i] = layer
                }
                if let effects { applySourceEffectsSnapshot(effects, to: newID) }
                if iso { isoArmedSourceIDs.insert(newID) }
                if mt { multitrackArmedSourceIDs.insert(newID) }
                if let motion { setLayerMotion(motion.kind, speed: motion.speed, for: newID) }
                // Restore the victim's vertical-hero + armed-stinger routing (sol #6 #10).
                #if DEBUG
                let restoreHeroStinger = !Self._test_rollbackSkipHeroStinger
                #else
                let restoreHeroStinger = true
                #endif
                if restoreHeroStinger {
                    if wasHero { setVerticalHero(newID) }
                    if wasStinger { setStingerMedia(newID) }
                }
                victimNewID[originalID] = newID
            }
        }
        // sol #8 #4: REBUILD the LRU in the TRUE pre-eviction relative order. The prior fix
        // reinserted each re-admitted victim at its ORIGINAL RAW index against the now-shrunk
        // LRU; with TWO victims where the oldest (`g1`) re-decode fails while a newer one
        // (`g2`) is re-admitted and a still-newer survivor (`g3`) remains, inserting `g2` at
        // its stale raw index produced `[g3,g2]` instead of `[g2,g3]` → the next admission
        // wrongly evicted the newer `g3`. Instead, walk the captured pre-eviction order and
        // rebuild: keep each survivor (still present, same id) in place, swap each re-admitted
        // victim to its new id, and DROP victims whose re-admit failed — reproducing the exact
        // pre-eviction ordering of the survived + re-admitted set (evicted ids never reappear
        // under their old id, so `current.contains` distinguishes a survivor).
        #if DEBUG
        let restoreLRUOrder = !Self._test_rollbackSkipLRURestore
        #else
        let restoreLRUOrder = true
        #endif
        if restoreLRUOrder {
            let current = Set(animatedMemeLRU)
            var rebuilt: [SourceID] = []
            for original in plan.preEvictionLRU {
                if let newID = victimNewID[original] {
                    rebuilt.append(newID)             // re-admitted victim (fresh id)
                } else if current.contains(original) {
                    rebuilt.append(original)          // survivor (never evicted)
                }                                     // else: evicted + re-decode failed → dropped
            }
            // Defensive: preserve any current LRU entry the pre-eviction order didn't cover
            // (e.g. concurrently added) at the newest end rather than silently losing it.
            let rebuiltSet = Set(rebuilt)
            for id in animatedMemeLRU where !rebuiltSet.contains(id) { rebuilt.append(id) }
            animatedMemeLRU = rebuilt
        }
    }

    /// Re-apply a full per-source effects snapshot (sol #5 #10 rollback): mirror it
    /// into `sourceEffects` AND push it to the live effect pipeline so the restored
    /// grade / LUT / keyer / video-wall actually take effect on the re-decoded source.
    private func applySourceEffectsSnapshot(_ fx: SourceEffects, to id: SourceID) {
        sourceEffects[id] = fx
        effectPipelines[id]?.update(fx)
    }

    /// Track a newly-admitted animated source's cost in the aggregate budget.
    private func trackAnimatedSource(_ id: SourceID, cost: Int) {
        guard cost > 0 else { return }
        animatedMemeByteCost[id] = cost
        animatedMemeLRU.append(id)
    }

    /// Evict one animated source to reclaim budget: a meme via `removeMeme`, an
    /// ordinary source via `removeSource` (both drop the cost accounting).
    private func evictAnimatedSource(_ id: SourceID) {
        if let meme = memeItems.first(where: { $0.sourceID == id }) {
            removeMeme(id: meme.id)
        } else {
            removeSource(id)
        }
    }

    func removeMeme(id: UUID) {
        guard let index = memeItems.firstIndex(where: { $0.id == id }) else { return }
        let item = memeItems.remove(at: index)
        // Supersede any in-flight frame-zero cue for THIS source: its background
        // closure checks the generation before restarting, so it can't resurrect this
        // source after we stop it below, nor install a provider for a removed meme.
        // Per-source (sol #4) so a concurrently-cueing DIFFERENT meme is undisturbed.
        bumpCueGeneration(for: item.sourceID)
        // Release the aggregate-budget accounting for this animated meme (F15).
        animatedMemeByteCost[item.sourceID] = nil
        animatedMemeLRU.removeAll { $0 == item.sourceID }
        invalidatePendingStingerCue(for: item.sourceID, drain: true)
        if activeStingerSourceID == item.sourceID { cancelActiveStingerTransition() }
        auxiliarySources[item.sourceID]?.source.stop()
        removeAuxiliarySource(item.sourceID)
        if armedStingerMemeID == item.id { armedStingerMemeID = nil }
        if let scoped = memeScopedURLs.removeValue(forKey: item.sourceID) {
            scoped.stopAccessingSecurityScopedResource()
        }
        // Drop the mailbox AND un-pin the compositor's retained last IOSurface for
        // this source (mirrors `removeSource`). Meme sources live outside
        // `activeSources`, so they never travel the `removeSource` path — without
        // this every add/remove cycle leaks a dead mailbox entry plus one pinned
        // ~8 MB (1080p) / ~33 MB (4K) IOSurface, since each meme gets a fresh
        // sourceID. `removeMailbox` calls `compositor.forget(source:)` internally.
        // Pulled MID-HOLD: the director still holds a live trigger for this now-dead
        // source and the meme provider is still folding it. With the mailbox gone the
        // program would reference a forgotten source (a black/blank take) for the rest
        // of the hold. Remove ONLY this source's trigger (N3) — a blanket
        // `reset()` would also drop any OTHER simultaneously-held animated meme AND
        // cancel the teardown timer that stops it, stranding that source
        // free-running with no schedule. Keep the provider + teardown alive while
        // any other meme still holds so each stops on its own hold end.
        // Drop THIS meme's own teardown deadline (sol #4) so the survivor schedule
        // recomputes to the next-nearest — never leaving an already-expired sibling's
        // source stranded (its timer was previously cancelled with the global one).
        memeDeadlinesHouse[item.sourceID] = nil
        if memeProviderInstalled {
            memeDirector.remove(sourceID: item.sourceID, at: HouseClock.nowSeconds())
            if memeDeadlinesHouse.isEmpty {
                memeProviderInstalled = false
                memeClearTimer?.invalidate()
            } else {
                scheduleMemeTeardown()   // recompute survivor schedule (sol #4)
            }
            if animatingSourceID == nil { refreshSceneProvider() }
        }
        // sol #4: release this source's cue-generation key. Every removed meme created/
        // bumped a fresh per-source key that was NEVER reclaimed (shutdown only bumped),
        // so `cueGenerations` grew monotonically for the app's lifetime. The bump above
        // already superseded any in-flight cue (it re-reads and sees nil → mismatch), so
        // dropping the key now is safe. Remove the RAW source key (production identity),
        // leaving the DEBUG global-cue sentinel — used by a concurrent negative-control
        // test — undisturbed.
        cueGenerations.withLock { $0.removeValue(forKey: item.sourceID) }
        if !item.isBuiltInTemplate { saveUserMemes() }
    }

    /// Fire a meme against the live program. `cutTo`/`insert` fold in via the
    /// render loop's `sceneProvider`. A stinger tile toggles a one-shot arm; the
    /// next real scene/preset switch supplies its target and consumes the live
    /// cue-frame schedule in `commitSceneAnimated`.
    func triggerMeme(id: UUID) {
        guard let item = memeItems.first(where: { $0.id == id }) else { return }
        if item.mode == .stinger {
            armedStingerMemeID = armedStingerMemeID == item.id ? nil : item.id
            return
        }
        let triggerHouse = HouseClock.nowSeconds()
        // Supersede any earlier in-flight cue for THIS source: every trigger (animated
        // OR still) bumps its source's generation, so a stale animated cue for the same
        // source can never overwrite a newer trigger once it lands. Per-source (sol #4)
        // so two DISTINCT rapid inserts do not cancel each other.
        let gen = bumpCueGeneration(for: item.sourceID)
        // Set this meme's OWN house-clock lifetime synchronously (F21, immune to
        // wall-clock steps; sol #4 independent lifetimes) so its teardown is scheduled
        // from the trigger instant regardless of cue latency and independent of any
        // other held meme's (longer/shorter) deadline. A re-trigger extends its own.
        let deadline = Self.memeProviderDeadlineHouse(triggerHouse: triggerHouse, holdSec: item.holdSec)
        memeDeadlinesHouse[item.sourceID] = deadline
        #if DEBUG
        // NEGATIVE CONTROL: pre-fix global-max coupling — every held meme shares the
        // longest deadline, so a short meme keeps decoding until the longest's hold end.
        if Self._test_coupleMemeLifetimes, let maxD = memeDeadlinesHouse.values.max() {
            for k in memeDeadlinesHouse.keys { memeDeadlinesHouse[k] = maxD }
        }
        #endif

        // Cue an animated meme (GIF/movie) to frame ZERO so every trigger opens on
        // a deterministic frame, not whatever free-run phase sat in the mailbox
        // (F14 / Class D). The cue (`source.stop()`'s playbackQueue.sync + the
        // up-to-0.35 s first-frame await) runs OFF the main actor (N4) so a stalled
        // decode never hitches the UI; the meme provider is installed only once
        // frame zero has ACTUALLY landed, preserving the deterministic opening frame.
        let registration = auxiliarySources[item.sourceID]
        let isAnimated = registration.map { $0.source is AnimatedGIFSource || $0.source is MovieSource } ?? false
        if isAnimated, let registration {
            let mailbox = registration.mailbox
            let genLock = cueGenerations
            let sourceID = item.sourceID
            let genKey = Self.cueGenKey(sourceID)
            // WEAK-capture the source so a queued cue can NEVER resurrect a source
            // that `removeMeme`/`shutdown` already dropped; check THIS source's
            // generation BEFORE restarting so a superseded/removed/torn-down trigger
            // does no work (no stop→start on a dead source) and installs no provider.
            Self.cueQueue.async { [weak self, weak source = registration.source] in
                guard genLock.withLock({ $0[genKey] }) == gen else { return }   // superseded (this source)
                guard let source else { return }                                // removed / gone
                #if DEBUG
                // Test seam: fire a caller-supplied action in the check→start window
                // (the exact interval `removeMeme`/`shutdown` can interleave) so the
                // resurrection race is reproducible/negative-controllable off-main.
                Self._test_cuePreStartHook?()
                #endif
                let (landed, frameZero) = AppEngine.cueAnimatedSourceCapturingFrameZero(source, mailbox: mailbox)
                // Async-cue resurrection race: `removeMeme`/`shutdown`/a newer trigger
                // for THIS source can land AFTER the pre-start generation check but
                // BEFORE the cue restarted the source — so we just resurrected a source
                // that is now unwanted. The generation moved, so the provider install
                // below is (correctly) rejected, but that alone leaves the source DECODING
                // untracked. RE-CHECK here and STOP it.
                if genLock.withLock({ $0[genKey] }) != gen {
                    source.stop()
                    return
                }
                Task { @MainActor in
                    guard let self, !self.didShutdown,
                          self.cueGeneration(for: sourceID) == gen else {
                        // Shutdown or a newer generation raced in between the off-main
                        // recheck and this main-actor hop: stop the source we restarted
                        // so no untracked decode survives (async-cue resurrection race).
                        source.stop()
                        return
                    }
                    guard landed else {
                        // Cue FAILED (frame zero never arrived within the bound):
                        // fall back cleanly — do NOT install a provider showing a
                        // mid-phase frame. Clear THIS source's pending deadline (other
                        // held memes keep theirs).
                        self.memeCueFailedCleanup(for: sourceID)
                        return
                    }
                    self.showMemeProvider(item: item, triggerHouse: triggerHouse, frameZero: frameZero)
                }
            }
        } else {
            showMemeProvider(item: item, triggerHouse: triggerHouse)
        }
    }

    /// Clean fallback when a frame-zero cue fails to land for `id`: drop THAT
    /// source's pending house deadline so no phantom teardown is scheduled for it and
    /// the program stays on its resting scene (F14 — never activate on a mid-phase
    /// frame after a failed cue). Any OTHER held meme keeps its own deadline (sol #4).
    private func memeCueFailedCleanup(for id: SourceID) {
        memeDeadlinesHouse[id] = nil
        if memeDeadlinesHouse.isEmpty {
            memeProviderInstalled = false
            memeClearTimer?.invalidate()
        } else {
            scheduleMemeTeardown()
        }
    }

    /// Make the triggered meme live: activate it in the director, install the
    /// scene provider, and (re)schedule its house-time teardown. Split out of
    /// `triggerMeme` so an animated meme can defer this until its frame-zero cue
    /// has landed off the main actor (N4) — keeping the opening frame deterministic
    /// (F14) — while this source's `memeDeadlinesHouse` entry is set synchronously (F21).
    private func showMemeProvider(item: MemeItem, triggerHouse: Double, frameZero: VideoFrame? = nil) {
        // F14 residual (sol #7): the cue paused the animated source at frame zero. The
        // render loop may have already drained a post-zero frame it produced into the
        // compositor's FrameStore during the cue. GATE the first presented frame to
        // zero: clear that stale FrameStore (forget→reattach) BEFORE the provider goes
        // live, then restart the (paused-at-0) source AFTER — so the first frame the
        // render loop folds for this now-in-program source is frame 0.
        let animatedReg: AuxiliaryVideoSource? = {
            guard let reg = auxiliarySources[item.sourceID],
                  reg.source is AnimatedGIFSource || reg.source is MovieSource else { return nil }
            return reg
        }()
        #if DEBUG
        if Self._test_skipFrameZeroGate {
            // NEGATIVE CONTROL: reproduce the pre-fix race deterministically — the cue
            // left the source RUNNING; let it advance past frame 0 (the render loop
            // drains those frames into FrameStore) BEFORE installing the provider, so
            // the first presented frame is a post-zero frame.
            if let reg = animatedReg {
                let target = reg.mailbox.stats.delivered + 3
                let deadline = ProcessInfo.processInfo.systemUptime + 1
                while reg.mailbox.stats.delivered < target,
                      ProcessInfo.processInfo.systemUptime < deadline {}
            }
            memeDirector.trigger(item, at: triggerHouse)
            installMemeProvider()
            scheduleMemeTeardown()
            return
        }
        #endif
        if let reg = animatedReg {
            renderLoop?.removeMailbox(for: item.sourceID)          // clear any stale drained frame
            if let frameZero {
                // sol #4: leave EXACTLY frame 0 resident so a high-fps source's free-run
                // (frames 1…N already in the mailbox) can't be selected first by the
                // latest-wins take. The source stays PAUSED until the gate below.
                _ = reg.mailbox.takeNewest()
                reg.mailbox.post(frameZero)
            }
            renderLoop?.setMailbox(reg.mailbox, for: item.sourceID) // reattach (fresh registration)
        }
        let ticksBefore = renderLoop?.stats.ticks ?? 0
        memeDirector.trigger(item, at: triggerHouse)
        installMemeProvider()
        scheduleMemeTeardown()
        // sol #4: GATE the source RESTART on the render loop having PRESENTED frame 0
        // (waited one tick past install, off the main actor) instead of restarting
        // immediately — otherwise a 120/240 fps source floods the mailbox before the next
        // 60 Hz pull and frame 1+ is presented. Restart errors are SURFACED, not `try?`d.
        if let reg = animatedReg {
            // sol #5 #7: capture this source's cue generation + a thread-safe check so
            // the deferred resume (which waits up to 0.25 s for frame 0) can detect a
            // removal / expiry / shutdown / newer trigger that landed during the wait
            // and NOT resurrect the (possibly torn-down) media.
            let genLock = cueGenerations
            let sourceID = item.sourceID
            let genKey = Self.cueGenKey(sourceID)
            let gen = cueGeneration(for: sourceID)
            Self.resumeMemeSourceAfterFrameZeroPresented(
                reg.source, loop: renderLoop, ticksBefore: ticksBefore, gated: frameZero != nil,
                isSuperseded: { genLock.withLock { $0[genKey] } != gen },
                finalizeOnMain: { [weak self] src in
                    Task { @MainActor in
                        guard let self else { return }
                        // Authoritative main-actor validation: still the registered
                        // backing for this id, not superseded, not shut down.
                        if self.didShutdown
                            || self.cueGeneration(for: sourceID) != gen
                            || self.auxiliarySources[sourceID]?.source !== src {
                            src.stop()
                        }
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor in
                        self?.lastError = "Couldn't resume meme playback: \(error.localizedDescription)"
                    }
                })
        }
    }

    /// The house-clock deadline (seconds) at which a meme provider triggered at
    /// `triggerHouse` may be torn down: the hold plus a small settle margin. Pure
    /// so the timing contract is testable without a live clock (F21).
    static func memeProviderDeadlineHouse(triggerHouse: Double, holdSec: Double) -> Double {
        triggerHouse + max(0.3, holdSec) + 0.25
    }

    /// Whether a meme provider whose house-clock deadline is `deadlineHouse` has
    /// expired at house time `nowHouse`. Pure + house-time-only, so a wall-clock
    /// `Date` step (NTP/DST) can never affect the decision (F21). A nil deadline
    /// counts as expired (nothing scheduled).
    static func memeProviderExpired(nowHouse: Double, deadlineHouse: Double?) -> Bool {
        guard let deadlineHouse else { return true }
        return nowHouse >= deadlineHouse
    }

    /// Serial queue the frame-zero cue runs on, OFF the main actor (N4), so a
    /// stalled decode never hitches the UI on a meme trigger.
    private static let cueQueue = DispatchQueue(label: "studio.prism.app.meme-cue", qos: .userInitiated)

    /// Restart an animated (GIF / movie) source at frame zero and wait (bounded)
    /// for its first cue frame to land in `mailbox`, so a trigger shows a
    /// deterministic opening frame (F14). No-op for a still `ImageSource` (a
    /// restart would just re-post the same frame).
    ///
    /// `nonisolated` and **must be run OFF the main actor** (N4): `source.stop()`
    /// does a `playbackQueue.sync` and the first-frame wait blocks up to `timeout`,
    /// so a stalled decode would hitch the UI if this ran on @MainActor. Callers
    /// dispatch it to `cueQueue` and install the meme provider from the completion.
    @discardableResult
    nonisolated static func cueAnimatedSourceToFrameZero(_ source: VideoSource, mailbox: FrameMailbox,
                                                         timeout: TimeInterval = 0.35) -> Bool {
        cueAnimatedSourceCapturingFrameZero(source, mailbox: mailbox, timeout: timeout).landed
    }

    /// Restart an animated source at frame zero, CAPTURE that frame, and leave the
    /// source paused at it (sol #4 / sol #7). Returns `landed` plus the captured
    /// `frameZero` VideoFrame so the caller can present EXACTLY frame 0 first — even for
    /// a high-fps (120/240 fps) source whose free-run would otherwise flood the mailbox
    /// with frames 1…N before the render loop's next 60 Hz pull (the latest-wins mailbox
    /// would then present frame 1+). The mailbox is left with frame 0 resident (the cue
    /// contract used by `cueAnimatedSourceToFrameZero`'s direct callers).
    @discardableResult
    nonisolated static func cueAnimatedSourceCapturingFrameZero(
        _ source: VideoSource, mailbox: FrameMailbox, timeout: TimeInterval = 0.35
    ) -> (landed: Bool, frameZero: VideoFrame?) {
        guard source is AnimatedGIFSource || source is MovieSource else { return (false, nil) }
        source.stop()
        _ = mailbox.takeNewest()                          // drop the stale free-run phase
        let before = mailbox.stats.delivered
        do {
            try source.start()                            // playback restarts at frame 0
        } catch {
            source.stop()                                 // F14: never leave it half-started
            return (false, nil)
        }
        #if DEBUG
        if _test_skipFrameZeroGate {
            // NEGATIVE CONTROL: leave the source RUNNING (free-run) and capture nothing,
            // reproducing the pre-fix race where the first presented frame is post-zero.
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while mailbox.stats.delivered == before,
                  ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            return (mailbox.stats.delivered > before, nil)
        }
        #endif
        // Capture the FIRST emitted frame = frame 0. TIGHT spin (no sleep) so a high-fps
        // source cannot slip a SECOND frame past the observation window before we grab it —
        // otherwise `takeNewest` would return frame 1+, defeating the deterministic open.
        var frameZero: VideoFrame?
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if mailbox.stats.delivered > before {
                frameZero = mailbox.takeNewest()
                break
            }
        }
        guard let frameZero else {
            // F14: the cue TIMED OUT — frame zero never landed. `start()` above left the
            // source running; the caller installs no provider on a failed cue, so STOP it.
            source.stop()
            return (false, nil)
        }
        source.stop()                                     // PAUSE at frame 0
        mailbox.post(frameZero)                           // leave EXACTLY frame 0 resident (cue contract)
        return (true, frameZero)
    }

    /// Resume continuous playback of a cued meme source ONLY after the render loop has
    /// presented frame 0 (sol #4). While `gated`, wait (bounded, off the main actor) for
    /// the loop to advance past the install tick — i.e. to have PULLED the reattached
    /// mailbox (only frame 0 is resident while the source stays paused), so frame 0 is the
    /// first PRESENTED frame — then restart the source so a high-fps free-run can't flood
    /// frames 1…N ahead of the first pull. Restart errors are SURFACED via `onError`
    /// (never `try?`-swallowed).
    nonisolated static func resumeMemeSourceAfterFrameZeroPresented(
        _ source: VideoSource, loop: RenderLoop?, ticksBefore: UInt64, gated: Bool,
        isSuperseded: @escaping @Sendable () -> Bool,
        finalizeOnMain: @escaping @Sendable (VideoSource) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        cueQueue.async { [weak source] in
            if gated, let loop {
                let deadline = ProcessInfo.processInfo.systemUptime + 0.25
                while loop.stats.ticks <= ticksBefore + 1,
                      ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
            // sol #5 #7: a removal / expiry / shutdown / newer trigger during the wait
            // superseded this resume. The pre-fix STRONG capture unconditionally called
            // start(), resurrecting an orphan looping decoder + self-retained mailbox on
            // media that was already torn down. WEAK-capture (a removed+released source
            // is already nil) + a thread-safe generation re-check (remove / expiry /
            // shutdown all bump it) gate the restart; a superseded resume STOPS the
            // source rather than resurrecting it.
            guard !isSuperseded() else { source?.stop(); return }
            guard let source else { return }
            do { try source.start() }
            catch { onError(error); return }
            // A supersession that raced in AFTER the check but around start() left the
            // source running untracked — re-check and quiet it; then a main-actor
            // finalize confirms still-registered + !didShutdown (authoritative).
            if isSuperseded() { source.stop(); return }
            finalizeOnMain(source)
        }
    }

    private func installMemeProvider() {
        let current = scene
        memeBaseScene.withLock { $0 = current }
        memeProviderInstalled = true
        refreshSceneProvider()
    }

    private func scheduleMemeTeardown() {
        memeClearTimer?.invalidate()
        // Fire at the NEAREST survivor deadline (sol #4): each meme then tears down on
        // its own hold end, not the longest concurrently-held one's.
        guard let nearest = memeDeadlinesHouse.values.min() else { return }
        // Delay derived from house-time remaining; the run-loop Timer fires on the
        // monotonic system clock, so this is unaffected by a wall-clock step (F21).
        let interval = max(0.05, nearest - HouseClock.nowSeconds())
        memeClearTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.teardownMemeProviderIfIdle() }
        }
    }

    /// Retire every meme whose OWN house-time deadline has passed (sol #4 — each
    /// meme tears down on its own schedule), then reschedule for the next survivor or
    /// fully tear down when none remain. The `MemeDirector` already drops each expired
    /// trigger from the PROGRAM at its own hold; here we quiet its SOURCE (stop/reset
    /// to frame 0 so a re-trigger cues deterministically, F14) and release it.
    private func teardownMemeProviderIfIdle() {
        let now = HouseClock.nowSeconds()
        let expired = memeDeadlinesHouse.filter {
            Self.memeProviderExpired(nowHouse: now, deadlineHouse: $0.value)
        }
        #if DEBUG
        if Self._test_stopAllMemesOnExpiry, !expired.isEmpty {
            // NEGATIVE CONTROL: pre-fix `stopAnimatedMemeSources()` — stop EVERY
            // animated meme source unconditionally (can freeze an in-flight stinger).
            for item in memeItems {
                guard let reg = auxiliarySources[item.sourceID],
                      reg.source is AnimatedGIFSource || reg.source is MovieSource else { continue }
                reg.source.stop()
            }
        }
        #endif
        for (id, _) in expired {
            // sol #4: deadlines are installed BEFORE the frame-zero cue enters the global
            // serial cue queue, so a still-QUEUED cue can outlive this expiry. Deleting the
            // deadline WITHOUT invalidating the source's cue generation left that queued cue
            // free to succeed — restart the source, install a provider, and (with no
            // deadline left) NEVER schedule a teardown → an untracked, permanently-running
            // meme. Bump the generation here so the queued cue's own pre-start / post-start
            // generation checks REJECT it (and stop the source it may have restarted), exactly
            // as `removeMeme` already does. (`stopAnimatedMemeSource`/`memeDirector.remove`
            // handle the source already-live at its hold end.)
            #if DEBUG
            if !Self._test_skipTeardownGenerationBump { bumpCueGeneration(for: id) }
            #else
            bumpCueGeneration(for: id)
            #endif
            stopAnimatedMemeSource(id)
            memeDirector.remove(sourceID: id, at: now)
            memeDeadlinesHouse[id] = nil
        }
        if memeDeadlinesHouse.isEmpty {
            memeProviderInstalled = false
            memeClearTimer?.invalidate()
        } else {
            scheduleMemeTeardown()   // next-nearest survivor
        }
        // Never yank the provider out from under a live layer-entrance animation.
        // Otherwise fall back to whatever the provider should be now (per-layer
        // motion may still need it) — or nil if nothing is animating.
        if animatingSourceID == nil { refreshSceneProvider() }
    }

    /// Stop (reset to frame 0) ONE animated GIF/movie meme source at its hold end.
    /// Idle animated memes are already stopped (they never free-run at registration,
    /// F14), so this is a no-op for them; it quiets the one a just-expired hold was
    /// playing. Scoped (sol #3): NEVER stops a source that is a live resting layer OR
    /// the active/pending stinger media — so an unrelated meme's expiry can't freeze
    /// an in-flight stinger. Stills are untouched.
    private func stopAnimatedMemeSource(_ id: SourceID) {
        guard id != activeStingerSourceID, id != pendingStingerCueSourceID else { return }
        guard !scene.layers.contains(where: { $0.sourceID == id }) else { return }
        guard let reg = auxiliarySources[id],
              reg.source is AnimatedGIFSource || reg.source is MovieSource else { return }
        reg.source.stop()
    }
}

// MARK: - Character source pass-throughs (PrismSources.CharacterSource)

extension AppEngine {

    /// Add a placeholder character (VTuber rig). CRITICAL: its layer is created
    /// via `Layer.character(...)` (premultipliedAlpha:true) so the transparent
    /// surround doesn't composite as a full-canvas black box.
    func addCharacterSource() {
        do {
            let source = try CharacterSource()
            let descriptor = SourceDescriptor(kind: .virtual, id: source.id.raw, name: "Character")
            try registerGenerated(source, descriptor: descriptor, characterLayer: true)
            characterSources[source.id] = source
        } catch {
            lastError = "Couldn't add character: \(error.localizedDescription)"
        }
    }

    func isCharacterSource(_ id: SourceID) -> Bool { characterSources[id] != nil }
    func characterExpressions(for id: SourceID) -> [String] {
        characterSources[id]?.expressionNames ?? []
    }
    func currentCharacterExpression(for id: SourceID) -> String? {
        characterSources[id]?.currentExpression()
    }
    func setCharacterExpression(_ name: String, for id: SourceID) {
        characterSources[id]?.setExpression(name)
    }
    /// Play a quick reaction accent (impact-pop) on the character.
    func triggerCharacterReaction(for id: SourceID) {
        characterSources[id]?.react()
    }
}

// MARK: - Motion-graphics overlay sources (PrismCompositor.MotionGraphics)

extension AppEngine {

    /// Add an animated broadcast overlay (lower-third / name-tag / countdown /
    /// subscribe-bug). It renders via `MotionGraphics` each frame, with the
    /// entrance progress driven live off the house clock, and is registered like
    /// any generated source (premultiplied-alpha overlay layer). The slide-in /
    /// hold / slide-out plays immediately; re-trigger it via `recueOverlay`.
    func addOverlaySource(kind: MGOverlayKind) {
        do {
            var config = MGOverlayConfig()
            config.kind = kind
            // A subscribe bug reads best in the bottom-right with a red accent.
            if kind == .subscribeBug {
                config.corner = .bottomRight
                config.accentR = 0.90; config.accentG = 0.16; config.accentB = 0.20
            }
            let source = try MotionGraphicsOverlaySource(
                width: Self.sourceCanvas.width, height: Self.sourceCanvas.height,
                config: config)
            let descriptor = SourceDescriptor(kind: .virtual, id: source.id.raw, name: kind.label)
            try registerGenerated(source, descriptor: descriptor)
            overlaySources[source.id] = source
        } catch {
            lastError = "Couldn't add overlay: \(error.localizedDescription)"
        }
    }

    func isOverlaySource(_ id: SourceID) -> Bool { overlaySources[id] != nil }
    /// The overlay's current config (for the inspector to load). Nil if not one.
    func overlayConfig(for id: SourceID) -> MGOverlayConfig? { overlaySources[id]?.currentConfig() }
    /// Push a new overlay config (live text/corner/accent/timing/countdown edit).
    func setOverlayConfig(_ config: MGOverlayConfig, for id: SourceID) {
        overlaySources[id]?.setConfig(config)
    }
    /// Replay the overlay's entrance (slide-in / hold / slide-out) from now.
    func recueOverlay(for id: SourceID) { overlaySources[id]?.recue() }

    /// Add a lower-third overlay from a fully-formed config and return its id
    /// (unlike `addOverlaySource(kind:)`, which starts from defaults). Used by
    /// `generateQuickScene` so it can track + later re-drive the exact overlay.
    private func addOverlaySource(config: MGOverlayConfig) -> SourceID? {
        do {
            let source = try MotionGraphicsOverlaySource(
                width: Self.sourceCanvas.width, height: Self.sourceCanvas.height,
                config: config)
            let descriptor = SourceDescriptor(kind: .virtual, id: source.id.raw,
                                              name: config.kind.label)
            try registerGenerated(source, descriptor: descriptor)
            overlaySources[source.id] = source
            return source.id
        } catch {
            lastError = "Couldn't add overlay: \(error.localizedDescription)"
            return nil
        }
    }
}

// MARK: - Animation overlays (AnimatedLogo / Ticker / Credits — DESIGN §1–2)

extension AppEngine {

    // --- Shared in-place rebuild (style/timing/speed are `let` on these sources,
    //     so a live edit rebuilds the backing while reusing the id / mailbox /
    //     effect pipeline / scene layer — mirrors `reconfigureMontage`). ---

    /// Swap a generated source's backing decoder for a freshly-built one with the
    /// SAME id, rewiring the frame tap and reusing the mailbox/pipeline/layer.
    private func swapGeneratedBacking(id: SourceID, to source: VideoSource) throws {
        guard let index = activeSources.firstIndex(where: { $0.id == id }),
              case .generated(let old) = activeSources[index].backing,
              let mailbox = activeSources[index].mailbox else { return }
        let descriptor = activeSources[index].descriptor
        let pipeline = effectPipelines[id]
        source.onFrame = { [mailbox, monitor = linkDebugMonitor, pipeline, isoTap, verticalTap, directorTap, sid = id] frame in
            Self.deliverSourceFrame(frame, pipeline: pipeline, monitor: monitor,
                                    isoTap: isoTap, verticalTap: verticalTap,
                                    directorTap: directorTap, sid: sid, mailbox: mailbox)
        }
        old.stop()
        try source.start()
        activeSources[index] = ActiveSource(id: id, descriptor: descriptor,
                                            backing: .generated(source), mailbox: mailbox)
    }

    /// The live generated backing for an id (for `cue()` / `setText()`), or nil.
    private func generatedBacking(_ id: SourceID) -> VideoSource? {
        guard let active = activeSources.first(where: { $0.id == id }),
              case .generated(let source) = active.backing else { return nil }
        return source
    }

    // --- Animated logo ---

    /// Add an animated-logo overlay from a user-picked PNG/image. Registered like
    /// any generated source (premultiplied-alpha overlay layer — the renderer
    /// leaves the surround transparent). The entrance plays immediately (autoCue);
    /// re-trigger it with `replayLogo`. The security-scoped grant is HELD for the
    /// logo's lifetime (so a live-edit rebuild can re-read the file) and released
    /// on removal — mirrors `addMovieSource`.
    func addLogoSource(fileURL: URL) {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        let config = LogoConfig()
        do {
            let source = try AnimatedLogoSource(logoURL: fileURL, canvasSize: Self.sourceCanvas,
                                                style: config.style, timing: config.timing)
            let descriptor = SourceDescriptor(kind: .media, id: source.id.raw,
                                              name: fileURL.deletingPathExtension().lastPathComponent)
            try registerGenerated(source, descriptor: descriptor)
            logoEntries[source.id] = LogoEntry(url: fileURL, scoped: scoped, config: config)
        } catch {
            if scoped { fileURL.stopAccessingSecurityScopedResource() }
            lastError = "Couldn't add logo \(fileURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func isLogoSource(_ id: SourceID) -> Bool { logoEntries[id] != nil }
    func logoConfig(for id: SourceID) -> LogoConfig? { logoEntries[id]?.config }
    /// Replay the logo entrance (slide-in / hold / idle) from now.
    func replayLogo(for id: SourceID) { (generatedBacking(id) as? AnimatedLogoSource)?.cue() }

    /// Apply a new logo style/timing — rebuilds the source in place from the held URL.
    func setLogoConfig(_ config: LogoConfig, for id: SourceID) {
        guard var entry = logoEntries[id], entry.config != config else { return }
        entry.config = config
        do {
            let source = try AnimatedLogoSource(id: id, logoURL: entry.url,
                                                canvasSize: Self.sourceCanvas,
                                                style: config.style, timing: config.timing)
            try swapGeneratedBacking(id: id, to: source)
            logoEntries[id] = entry
        } catch {
            lastError = "Couldn't update logo: \(error.localizedDescription)"
        }
    }

    // --- Ticker ---

    /// Add a news-crawl ticker. Registered like any generated source (premultiplied
    /// overlay: only the bar carries pixels). `text` is live-editable; a speed/
    /// position/accent change rebuilds the source in place.
    func addTickerSource(config: TickerConfig) {
        do {
            let source = try TickerSource(text: config.text, canvasSize: Self.sourceCanvas,
                                          style: config.style, speed: config.speed)
            let descriptor = SourceDescriptor(kind: .virtual, id: source.id.raw, name: "Ticker")
            try registerGenerated(source, descriptor: descriptor)
            tickerEntries[source.id] = config
        } catch {
            lastError = "Couldn't add ticker: \(error.localizedDescription)"
        }
    }

    func isTickerSource(_ id: SourceID) -> Bool { tickerEntries[id] != nil }
    func tickerConfig(for id: SourceID) -> TickerConfig? { tickerEntries[id] }

    /// Live-update the ticker. `text` alone is applied without a rebuild
    /// (`setText`); a speed/position/accent change rebuilds the source in place.
    func setTickerConfig(_ config: TickerConfig, for id: SourceID) {
        guard let old = tickerEntries[id], old != config else { return }
        let onlyTextChanged = old.speed == config.speed && old.position == config.position
            && old.accentR == config.accentR && old.accentG == config.accentG && old.accentB == config.accentB
        if onlyTextChanged {
            (generatedBacking(id) as? TickerSource)?.setText(config.text)
            tickerEntries[id] = config
            return
        }
        do {
            let source = try TickerSource(id: id, text: config.text, canvasSize: Self.sourceCanvas,
                                          style: config.style, speed: config.speed)
            try swapGeneratedBacking(id: id, to: source)
            tickerEntries[id] = config
        } catch {
            lastError = "Couldn't update ticker: \(error.localizedDescription)"
        }
    }

    // --- Credits ---

    /// Add a credits roll from multiple lines. Registered like any generated
    /// source (premultiplied overlay). Speed/loop are live-editable (rebuild).
    func addCreditsSource(config: CreditsConfig) {
        do {
            let source = try CreditsSource(lines: config.lines, canvasSize: Self.sourceCanvas,
                                           speed: config.speed, loop: config.loop)
            let descriptor = SourceDescriptor(kind: .virtual, id: source.id.raw, name: "Credits")
            try registerGenerated(source, descriptor: descriptor)
            creditsEntries[source.id] = config
        } catch {
            lastError = "Couldn't add credits: \(error.localizedDescription)"
        }
    }

    func isCreditsSource(_ id: SourceID) -> Bool { creditsEntries[id] != nil }
    func creditsConfig(for id: SourceID) -> CreditsConfig? { creditsEntries[id] }

    /// Live-update the credits speed/loop — rebuilds the source in place.
    func setCreditsConfig(_ config: CreditsConfig, for id: SourceID) {
        guard let old = creditsEntries[id], old != config else { return }
        do {
            let source = try CreditsSource(id: id, lines: config.lines, canvasSize: Self.sourceCanvas,
                                           speed: config.speed, loop: config.loop)
            try swapGeneratedBacking(id: id, to: source)
            creditsEntries[id] = config
        } catch {
            lastError = "Couldn't update credits: \(error.localizedDescription)"
        }
    }
}

// MARK: - Character lip-sync + auto-blink (AudioEnvelopeFollower → CharacterSource)

extension AppEngine {

    func isCharacterLipSyncEnabled(_ id: SourceID) -> Bool { lipSyncCharacterIDs.contains(id) }
    func isCharacterAutoBlinkEnabled(_ id: SourceID) -> Bool {
        characterSources[id]?.autoBlinkEnabled ?? true
    }

    /// Toggle auto-blink for a character (default on).
    func setCharacterAutoBlink(_ on: Bool, for id: SourceID) {
        characterSources[id]?.autoBlinkEnabled = on
    }

    /// Toggle "Lip-sync to program audio" for a character. ON: enables the rig's
    /// lip-sync, ensures a shared `AudioEnvelopeFollower` is fed the program master
    /// mix (via the fan-out tap), and starts the ~60 Hz push timer. If there's no
    /// program audio the follower simply reports 0 openness — a no-op (mouth stays
    /// per the expression). OFF: closes the mouth and tears the follower down once
    /// the last character disables it.
    func setCharacterLipSync(_ on: Bool, for id: SourceID) {
        guard let character = characterSources[id] else { return }
        character.lipSyncEnabled = on
        if on {
            lipSyncCharacterIDs.insert(id)
            ensureLipSyncRunning()
        } else {
            lipSyncCharacterIDs.remove(id)
            character.setMouthOpenness(0)   // relax the mouth back to the expression
            teardownLipSyncIfIdle()
        }
    }

    private func ensureLipSyncRunning() {
        if lipSyncFollower == nil {
            ensureAudioMixerStarted()       // master-mix tap must be live to feed the follower
            let follower = AudioEnvelopeFollower(sampleRate: 48_000)
            lipSyncFollower = follower
            fanOut.setEnvelopeFollower(follower)   // program audio → openness
        }
        if lipSyncTimer == nil {
            // Poll the smoothed openness and push it to every lip-sync character.
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let follower = self.lipSyncFollower else { return }
                    let openness = follower.openness
                    for cid in self.lipSyncCharacterIDs {
                        self.characterSources[cid]?.setMouthOpenness(openness)
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            lipSyncTimer = timer
        }
    }

    private func teardownLipSyncIfIdle() {
        guard lipSyncCharacterIDs.isEmpty else { return }
        lipSyncTimer?.invalidate(); lipSyncTimer = nil
        fanOut.setEnvelopeFollower(nil)
        lipSyncFollower = nil
    }
}

// MARK: - Per-layer motion (LayerMotion → the render loop's sceneProvider)

extension AppEngine {

    /// The motion currently applied to a layer (`.none` if none).
    func layerMotionKind(for id: SourceID) -> LayerMotionKind {
        layerMotions[id]?.kind ?? .none
    }
    /// The speed (cycles/sec) of a layer's motion (default 1).
    func layerMotionSpeed(for id: SourceID) -> Double {
        layerMotions[id]?.speed ?? 1.0
    }

    /// Set (or clear, with `.none`) a layer's motion. A live motion drives the
    /// layer's transform every render tick off the house clock, looping.
    func setLayerMotion(_ kind: LayerMotionKind, speed: Double, for id: SourceID) {
        if kind == .none {
            guard layerMotions.removeValue(forKey: id) != nil else { return }
        } else if let path = kind.path {
            let motion = LayerMotion(path: path)
            layerMotions[id] = ActiveLayerMotion(kind: kind, motion: motion,
                                                 speed: max(0.01, speed),
                                                 startHouse: HouseClock.nowSeconds())
        }
        refreshSceneProvider()
    }

    /// (Re)install the render loop's `sceneProvider` to reflect the current mix of
    /// per-layer motion and any holding meme. A live layer-entrance owns the
    /// provider exclusively while it plays, so this yields to it. When nothing
    /// needs it, the provider is cleared and the resting scene resumes.
    func refreshSceneProvider() {
        guard let loop = renderLoop else { return }
        if animatingSourceID != nil { return }   // entrance owns it; it re-refreshes on finish
        let motions = layerMotions
        let memeOn = memeProviderInstalled
        guard !motions.isEmpty || memeOn else {
            loop.sceneProvider = nil
            verticalTap.clearProgramOverride()
            return
        }
        let baseLock = memeBaseScene
        let director = memeDirector
        loop.sceneProvider = { pts in
            var scene = baseLock.withLock { $0 }
            if !motions.isEmpty {
                scene = AppEngine.applyLayerMotions(motions, to: scene, atHouseSeconds: pts.seconds)
            }
            if memeOn {
                scene = director.program(at: pts.seconds, base: scene)
            }
            return scene
        }
    }

    /// Apply each active motion's transform to its layer (pure; render-thread
    /// safe — value inputs only). Offsets the layer's normalized frame by the
    /// motion's `(tx, ty)`, scales it about its center, folds in the opacity, and
    /// carries the motion's `rotation` (radians) onto the layer — the compositor's
    /// aspect-corrected vertex stage now honors `Layer.rotation` (F20 engine), so
    /// the live app must no longer drop it. Rotation accumulates onto any static
    /// layer rotation.
    nonisolated static func applyLayerMotions(_ motions: [SourceID: ActiveLayerMotion],
                                              to scene: ProgramScene,
                                              atHouseSeconds now: Double) -> ProgramScene {
        var out = scene
        out.layers = scene.layers.map { layer in
            guard let m = motions[layer.sourceID] else { return layer }
            let t = m.motion.transform(at: m.parameter(atHouseSeconds: now))
            var l = layer
            var frame = l.frame
            frame.origin.x += CGFloat(t.tx)
            frame.origin.y += CGFloat(t.ty)
            if t.scale != 1 {
                let s = CGFloat(t.scale)
                frame = CGRect(x: frame.midX - frame.width * s / 2,
                               y: frame.midY - frame.height * s / 2,
                               width: frame.width * s, height: frame.height * s)
            }
            l.frame = frame
            l.opacity *= Float(min(max(t.opacity, 0), 1))
            l.rotation += t.rotation                      // F20: wire rotation to the live layer
            return l
        }
        return out
    }
}

// MARK: - Quick Scene (rule-based "Text-to-Scene" composer)

/// The recipe a parsed vibe/title resolves to: an accent colour, a lower-third
/// corner, a transition, and which music bed to look for. Everything downstream
/// drives the EXISTING engine calls (overlay add / setTransitionKind / playBed) —
/// no new rendering or audio path. Pure value type so it is trivially testable.
struct QuickSceneRecipe: Equatable {
    /// The vibe label shown back to the operator ("Breaking News", "Lofi", …).
    var vibe: String
    /// Accent colour, sRGB 0…1 (feeds `MGOverlayConfig.accent*`).
    var accent: (r: Double, g: Double, b: Double)
    var corner: MGCorner
    /// Whether program switches animate. `false` ⇒ a hard cut (news/breaking).
    var transitionEnabled: Bool
    var transitionKind: TransitionKind
    var transitionDuration: Double
    /// Ordered keyword tags to match a loopable library bed by name/id. The first
    /// hit wins; if none match we fall back to `defaultBedID` (an always-present
    /// synth bed), or leave the bed silent when `defaultBedID` is nil (news).
    var bedTags: [String]
    /// Synth bed to use when no library bed matches (nil ⇒ intentionally no bed).
    var defaultBedID: String?

    static func == (l: QuickSceneRecipe, r: QuickSceneRecipe) -> Bool {
        l.vibe == r.vibe && l.accent == r.accent && l.corner == r.corner
            && l.transitionEnabled == r.transitionEnabled
            && l.transitionKind == r.transitionKind
            && l.transitionDuration == r.transitionDuration
            && l.bedTags == r.bedTags && l.defaultBedID == r.defaultBedID
    }

    /// Rule-based keyword → recipe map. Case-insensitive substring match on the
    /// title; the FIRST matching family wins; unmatched titles get a sensible
    /// neutral default. No ML — a plain lookup table.
    static func parse(title: String) -> QuickSceneRecipe {
        let t = title.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { t.contains($0) } }

        // News / breaking → red, hard cut, tense-or-no bed.
        if has(["news", "breaking", "headline", "report", "bulletin", "alert", "urgent"]) {
            return QuickSceneRecipe(
                vibe: "Breaking News",
                accent: (0.85, 0.12, 0.15), corner: .bottomLeft,
                transitionEnabled: false, transitionKind: .wipe(.left), transitionDuration: 0.0,
                bedTags: ["tense", "drone", "news", "suspense"], defaultBedID: nil)
        }
        // Lofi / chill / night → purple, slow crossfade, warm pad.
        if has(["lofi", "lo-fi", "chill", "night", "study", "relax", "calm", "sleep", "ambient", "cozy"]) {
            return QuickSceneRecipe(
                vibe: "Late Night / Lofi",
                accent: (0.55, 0.35, 0.85), corner: .bottomLeft,
                transitionEnabled: true, transitionKind: .dissolve, transitionDuration: 0.6,
                bedTags: ["lofi", "warm", "pad", "chill", "ambient"], defaultBedID: "bed.warm")
        }
        // Hype / gaming → bright orange, punchy push, beaty bed.
        if has(["hype", "gaming", "game", "esports", "energy", "pump", "fire", "arena", "versus", "battle"]) {
            return QuickSceneRecipe(
                vibe: "Hype / Gaming",
                accent: (1.0, 0.45, 0.08), corner: .bottomRight,
                transitionEnabled: true, transitionKind: .push(.left), transitionDuration: 0.25,
                bedTags: ["beat", "drum", "bass", "hype", "energy", "electro"], defaultBedID: "bed.calm")
        }
        // Wedding / soft → pastel pink, slow dissolve, gentle bed.
        if has(["wedding", "soft", "love", "romance", "bride", "celebration", "gentle", "elegant", "pastel"]) {
            return QuickSceneRecipe(
                vibe: "Wedding / Soft",
                accent: (0.95, 0.72, 0.82), corner: .bottomLeft,
                transitionEnabled: true, transitionKind: .dissolve, transitionDuration: 0.9,
                bedTags: ["soft", "piano", "gentle", "warm", "calm"], defaultBedID: "bed.calm")
        }
        // Default: neutral broadcast blue, standard crossfade, warm pad.
        return QuickSceneRecipe(
            vibe: "Default",
            accent: (0.15, 0.55, 0.95), corner: .bottomLeft,
            transitionEnabled: true, transitionKind: .dissolve, transitionDuration: 0.3,
            bedTags: ["warm", "pad", "calm", "ambient"], defaultBedID: "bed.warm")
    }
}

extension AppEngine {

    /// Compose a matching scene from EXISTING pieces for a typed vibe/title:
    /// parse keywords → a `QuickSceneRecipe`, then (1) add/refresh a lower-third
    /// overlay with the title/subtitle + chosen accent/corner, (2) set the program
    /// transition kind (or a hard cut), and (3) start a loopable music bed that
    /// best matches — all through the same engine calls the rest of the app uses.
    ///
    /// Idempotent-ish: a second call REPLACES the previous quick-scene overlay
    /// (updates its config + re-cues in place) and swaps its music bed, instead of
    /// stacking. An empty title is a gentle no-op (sets a prompt in
    /// `quickSceneStatus`). Never crashes: a missing bed falls back to a synth bed
    /// or skips the bed with a note; an overlay-build failure surfaces via
    /// `lastError`.
    func generateQuickScene(title: String, subtitle: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            quickSceneStatus = "Type a vibe or title to generate a scene."
            return
        }
        let trimmedSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipe = QuickSceneRecipe.parse(title: trimmedTitle)

        // 1) Lower-third overlay — build the config, then reuse-in-place if the
        //    last quick-scene overlay is still around, else add a fresh one.
        var config = MGOverlayConfig()
        config.kind = .lowerThird
        config.name = trimmedTitle
        config.subtitle = trimmedSubtitle
        config.corner = recipe.corner
        config.accentR = recipe.accent.r
        config.accentG = recipe.accent.g
        config.accentB = recipe.accent.b

        if let id = quickSceneOverlayID, isOverlaySource(id) {
            setOverlayConfig(config, for: id)   // replace, don't stack
            recueOverlay(for: id)               // replay the entrance
        } else {
            quickSceneOverlayID = addOverlaySource(config: config)
        }

        // 2) Transition kind (a hard cut disables transitions entirely).
        setTransitionEnabled(recipe.transitionEnabled)
        if recipe.transitionEnabled {
            setTransitionKind(recipe.transitionKind)
            setTransitionDuration(recipe.transitionDuration)
        }

        // 3) Music bed — ensure the catalog is built so `musicBeds` is populated,
        //    then pick the best loopable match by keyword, else the synth default.
        prepareSound()
        var bedNote: String
        if let bedID = matchBedID(tags: recipe.bedTags, default: recipe.defaultBedID) {
            if quickSceneBedID != bedID {
                if quickSceneBedID != nil { stopBed() } // swap, don't layer
                playBed(id: bedID)
                quickSceneBedID = bedID
            }
            let bedName = musicBeds.first { $0.id == bedID }?.name ?? bedID
            bedNote = "bed \(bedName)"
        } else {
            if quickSceneBedID != nil { stopBed(); quickSceneBedID = nil }
            bedNote = "no music bed (none matched)"
        }

        let transitionNote = recipe.transitionEnabled ? recipe.transitionKind.label : "hard cut"
        quickSceneStatus = "\(recipe.vibe): lower third + \(transitionNote) + \(bedNote)."
    }

    /// Pick a loopable bed id whose name/id contains one of `tags` (first tag,
    /// first hit wins), else `fallback` if that id exists in `musicBeds`, else the
    /// fallback verbatim (the synth beds are always registered), else nil.
    private func matchBedID(tags: [String], default fallback: String?) -> String? {
        for tag in tags {
            if let hit = musicBeds.first(where: {
                $0.name.lowercased().contains(tag) || $0.id.lowercased().contains(tag)
            }) {
                return hit.id
            }
        }
        guard let fallback else { return nil }
        // Synth beds (bed.warm / bed.calm) are registered by buildSoundStack, so
        // `fallback` is playable even when it isn't listed yet.
        if musicBeds.contains(where: { $0.id == fallback }) { return fallback }
        return fallback
    }
}

// MARK: - Presenter cutout (PrismSources.PresenterCutoutSource)

/// The app-side cutout state for a camera/movie source: whether it's on, the
/// alpha-edge feather, and the background fill (transparent cutout or a solid
/// colour). Absent ⇒ off.
struct CutoutState: Equatable {
    var feather: Float = 3
    var background: PresenterCutout.Background = .transparent
}

extension AppEngine {

    /// Whether a source can be background-cut-out: only the physical feeds
    /// (camera / movie clip) — a generated overlay has no person to segment.
    func isCutoutCapable(_ id: SourceID) -> Bool {
        guard let s = activeSources.first(where: { $0.id == id }) else { return false }
        switch s.backing {
        case .camera, .movie: return true
        default: return false
        }
    }

    /// The current cutout state for a source (nil ⇒ off), for the inspector.
    func cutoutState(for id: SourceID) -> CutoutState? { cutoutStates[id] }

    /// Enable/disable (or retune) the presenter cutout for a camera/movie source.
    /// A non-nil `state` wraps the source in a `PresenterCutoutSource` (person
    /// opaque, background per `state.background`) so the presenter composites over
    /// the layers beneath; nil restores the raw feed. Rebuilds the underlying
    /// source fresh IN PLACE — reusing the SourceID, mailbox, effect pipeline, and
    /// scene layer (only the frame graph is re-wired) — mirroring `setMovieLoop`,
    /// so the layer never leaves the scene. A transparent cutout flips the layer's
    /// `premultipliedAlpha` true (else the transparent surround composites black).
    func setPresenterCutout(_ state: CutoutState?, for id: SourceID) {
        guard !didShutdown else { return }
        guard let index = activeSources.firstIndex(where: { $0.id == id }),
              let mailbox = activeSources[index].mailbox else { return }
        let descriptor = activeSources[index].descriptor
        let pipeline = effectPipelines[id]

        // Tear down whatever currently drives frames (a cutout wrapper, or the raw
        // source) so the old closures go quiet before we re-wire.
        cutoutSources.removeValue(forKey: id)?.stop() // also stops its wrapped upstream
        let isMovie: Bool
        switch activeSources[index].backing {
        case .camera(let c): c.stop(); isMovie = false
        case .movie(let m):  m.stop(); isMovie = true
        default: return
        }

        // The shared frame sink: pipeline → taps → mailbox (identical to registration).
        let frameSink: (VideoFrame) -> Void = { [mailbox, monitor = linkDebugMonitor, pipeline, isoTap, verticalTap, directorTap, sid = id] frame in
            Self.deliverSourceFrame(frame, pipeline: pipeline, monitor: monitor,
                                    isoTap: isoTap, verticalTap: verticalTap,
                                    directorTap: directorTap, sid: sid, mailbox: mailbox)
        }
        // sol wave-16 #2: a Presenter Cutout's PROGRAM sink must NOT feed ISO the
        // processed cutout (segmentation baked in). The program still shows the
        // cutout, but ISO is fed the UPSTREAM raw frame directly (see `onRawFrame`
        // below), so the advertised clean ISO is the true native pre-segmentation
        // source. `feedISO: false` suppresses the ISO append on the processed path.
        let cutoutProgramSink: (VideoFrame) -> Void = { [mailbox, monitor = linkDebugMonitor, pipeline, isoTap, verticalTap, directorTap, sid = id] frame in
            Self.deliverSourceFrame(frame, pipeline: pipeline, monitor: monitor,
                                    isoTap: isoTap, verticalTap: verticalTap,
                                    directorTap: directorTap, sid: sid, mailbox: mailbox,
                                    feedISO: false)
        }
        // The clean-ISO tap for a cutout: the RAW upstream frame, straight to the ISO
        // tap (native, no segmentation FX). Keyed by the SOURCE id so the ISO angle
        // matches the source identity.
        let cutoutRawISOSink: (VideoFrame) -> Void = { [isoTap, sid = id] raw in
            #if DEBUG
            AppEngine._test_isoRoutedFrame?(VideoFrame(pixelBuffer: raw.pixelBuffer, pts: raw.pts,
                                                       duration: raw.duration, source: sid))
            #endif
            isoTap.append(VideoFrame(pixelBuffer: raw.pixelBuffer, pts: raw.pts,
                                     duration: raw.duration, source: sid))
        }

        do {
            #if DEBUG
            if Self._test_forceCutoutReconfigFailure { throw NSError(domain: "prism.test", code: 42) }
            #endif
            // Rebuild the underlying source fresh (same id) so its onFrame is clean.
            let underlying: VideoSource
            var rebuiltMovie: MovieSource?
            var movieEntry: MovieEntry?
            if isMovie {
                guard let entry = movieSources[id] else { return }
                let mv = try MovieSource(id: id, fileURL: entry.fileURL,
                                         canvasSize: Self.sourceCanvas,
                                         contentMode: .aspectFit, loop: entry.loop)
                underlying = mv; rebuiltMovie = mv; movieEntry = entry
                // Re-wire the clip's soundtrack into its existing mixer channel.
                if mv.hasAudioTrack, let channel = audioMixer.channel(id: id) {
                    mv.onAudio = { [multitrackTap] packet in
                        channel.ingest(packet)
                        multitrackTap.append(packet)
                    }
                }
            } else {
                underlying = try CameraSource(deviceID: descriptor.id)
            }

            let backing: ActiveSource.Backing
            if let state {
                // Wrap in a cutout; the wrapper's start() also starts the upstream.
                var opts = PresenterCutout.Options()
                opts.background = state.background
                opts.feather = state.feather
                let cutout = PresenterCutoutSource(wrapping: underlying, options: opts)
                // Program shows the cutout; ISO taps the UPSTREAM raw (sol wave-16 #2).
                cutout.onFrame = cutoutProgramSink
                cutout.onRawFrame = cutoutRawISOSink
                cutoutSources[id] = cutout
                cutoutStates[id] = state
                try cutout.start()
            } else {
                underlying.onFrame = frameSink
                cutoutStates[id] = nil
                try underlying.start()
            }
            if let mv = rebuiltMovie {
                backing = .movie(mv)
                if let e = movieEntry {
                    movieSources[id] = MovieEntry(source: mv, fileURL: e.fileURL,
                                                  loop: e.loop, scoped: e.scoped)
                }
            } else if let cam = underlying as? CameraSource {
                backing = .camera(cam)
            } else {
                return
            }
            activeSources[index] = ActiveSource(id: id, descriptor: descriptor,
                                                backing: backing, mailbox: mailbox)
            updateLayerPremultipliedAlpha(for: id) // transparent cutout ⇒ premultiplied
            saveSourceFX(for: id)                   // presenter cutout survives relaunch (feature 5)
        } catch {
            lastError = "Couldn't update background cutout for \(descriptor.name): \(error.localizedDescription)"
            #if DEBUG
            if Self._test_skipCutoutFailureRestore {
                cutoutStates[id] = nil   // pre-fix: leave the source stranded .idle (dark)
                return
            }
            #endif
            // sol #12 #2 (finding #6): the original source was STOPPED at the top of this method,
            // and the reconfigure failed BEFORE `activeSources[index]` was reassigned — so the
            // registered backing is now a stopped (idle/dark) source. Do NOT strand it: restore +
            // restart a fresh RAW feed (same id/mailbox/pipeline/layer) so the source stays live.
            // The cutout is reported OFF (honest — the reconfigure did not take); `lastError` is
            // preserved above. A restore that ITSELF fails is no worse than the stranded state.
            cutoutSources.removeValue(forKey: id)?.stop()  // drop a half-built wrapper if any
            cutoutStates[id] = nil
            do {
                let restored: VideoSource
                var restoredMovie: MovieSource?
                if isMovie {
                    guard let entry = movieSources[id] else { return }
                    let mv = try MovieSource(id: id, fileURL: entry.fileURL,
                                             canvasSize: Self.sourceCanvas,
                                             contentMode: .aspectFit, loop: entry.loop)
                    if mv.hasAudioTrack, let channel = audioMixer.channel(id: id) {
                        mv.onAudio = { [multitrackTap] packet in
                            channel.ingest(packet)
                            multitrackTap.append(packet)
                        }
                    }
                    restored = mv; restoredMovie = mv
                } else {
                    restored = try CameraSource(deviceID: descriptor.id)
                }
                restored.onFrame = frameSink
                try restored.start()
                if let mv = restoredMovie {
                    if let e = movieSources[id] {
                        movieSources[id] = MovieEntry(source: mv, fileURL: e.fileURL,
                                                      loop: e.loop, scoped: e.scoped)
                    }
                    activeSources[index] = ActiveSource(id: id, descriptor: descriptor,
                                                        backing: .movie(mv), mailbox: mailbox)
                } else if let cam = restored as? CameraSource {
                    activeSources[index] = ActiveSource(id: id, descriptor: descriptor,
                                                        backing: .camera(cam), mailbox: mailbox)
                }
                updateLayerPremultipliedAlpha(for: id)
            } catch {
                // Restore itself failed — no worse than the stranded state; keep the first error.
            }
        }
    }
}

// MARK: - Live captions (feature 1: PrismAudio.LiveCaptioner + CaptionRenderer)

extension AppEngine {

    /// Turn live captions on/off. ON: registers a premultiplied caption-overlay
    /// source, spins up an on-device `LiveCaptioner`, and feeds it the program
    /// master mix (via the fan-out audio tap). If the captioner can't run (no
    /// authorization / no on-device model) the toggle stays on but a one-line note
    /// is surfaced in `captionsStatusNote` — never a crash, and the transparent
    /// overlay simply shows nothing.
    func setCaptionsEnabled(_ on: Bool) {
        guard on != captionsEnabled else { return }
        if on { startCaptions() } else { stopCaptions() }
    }

    private func startCaptions() {
        do {
            let overlay = try LiveCaptionOverlaySource(width: Self.sourceCanvas.width,
                                                       height: Self.sourceCanvas.height)
            let cap = LiveCaptioner()
            // onCaption fires off the recognizer's queue; overlay.apply is thread-safe.
            // The flagship's caption feed CHAINS onto the overlay apply (both fire,
            // overlay first) so enabling Director's Cut never clobbers the captions.
            let applyOverlay: @Sendable (CaptionUpdate) -> Void = { [weak overlay] update in
                overlay?.apply(update)
            }
            let feedHighlight: @Sendable (CaptionUpdate) -> Void = { [weak self] update in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.feedCaptionToDirector(update) }
                }
            }
            cap.onCaption = HighlightFeeds.chain(applyOverlay, feedHighlight)
            let descriptor = SourceDescriptor(kind: .virtual, id: overlay.id.raw, name: "Live Captions")
            try registerGenerated(overlay, descriptor: descriptor)
            captionOverlay = overlay
            captioner = cap
            ensureAudioMixerStarted()      // master-mix tap must be live to feed the captioner
            fanOut.setCaptioner(cap)       // program audio → captioner (feature 1)
            cap.start()                    // async authorization; state observed by the poll
            captionsEnabled = true
            captionsStatusNote = nil
            startCaptionStatusTimer()
        } catch {
            lastError = "Couldn't start captions: \(error.localizedDescription)"
        }
    }

    private func stopCaptions() {
        captionStatusTimer?.invalidate(); captionStatusTimer = nil
        fanOut.setCaptioner(nil)
        captioner?.stop(); captioner = nil
        if let overlay = captionOverlay { removeSource(overlay.id) }
        captionOverlay = nil
        captionsEnabled = false
        captionsStatusNote = nil
    }

    private func startCaptionStatusTimer() {
        captionStatusTimer?.invalidate()
        captionStatusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let cap = self.captioner else { return }
                if case .unavailable(let reason) = cap.state {
                    self.captionsStatusNote = Self.captionUnavailableText(reason)
                } else {
                    self.captionsStatusNote = nil
                }
            }
        }
    }

    private static func captionUnavailableText(_ reason: LiveCaptioner.Unavailable) -> String {
        switch reason {
        case .recognizerUnavailable:  return "Captions unavailable — no speech recognizer for this language."
        case .onDeviceUnsupported:    return "Captions unavailable — no on-device speech model installed."
        case .authorizationDenied:    return "Captions need Speech Recognition access — enable it in System Settings › Privacy & Security."
        case .authorizationRestricted: return "Captions are restricted on this Mac (parental / MDM controls)."
        case .recognitionFailed:      return "Captions stopped — speech recognition failed."
        }
    }
}

// MARK: - Clip that moment (feature 3: ReplayBuffer.saveHighlight)

extension AppEngine {

    /// Clamp + store the "clip that moment" window length (5…120 s).
    func setClipLength(_ seconds: Double) {
        clipLengthSeconds = min(120, max(5, seconds))
    }

    /// Save the last `clipLengthSeconds` of buffered program (video + audio) as a
    /// highlight clip under ~/Movies/Prism/Clips and reveal it. Requires instant
    /// replay to be ARMED — the ring only buffers while armed — otherwise throws
    /// `ReplayError.notArmed` (the UI keeps the button disabled until armed).
    @discardableResult
    func clipThatMomentAsync() async throws -> URL {
        guard let buffer = replayBuffer else { throw ReplayError.notArmed }
        let directory = URL(filePath: NSHomeDirectory()).appending(path: "Movies/Prism/Clips")
        // sol #17 (data loss): a second-resolution name let two rapid "clip that
        // moment" saves pick the identical path → the later save destroyed the
        // earlier clip. Millisecond timestamp + a monotonic counter makes each
        // save's path unique; `saveHighlight` additionally resolves a non-clobbering
        // sibling as a last-line guard.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        clipSaveCounter &+= 1
        let url = directory.appending(path: "Clip \(formatter.string(from: Date())) (\(clipSaveCounter)).mov")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let report = try await buffer.saveHighlight(lastSeconds: clipLengthSeconds, to: url)
        lastClipURL = report.url
        NSWorkspace.shared.activateFileViewerSelecting([report.url])
        return report.url
    }

    func clipThatMoment() {
        Task { @MainActor in
            do { _ = try await clipThatMomentAsync() }
            catch { lastError = "Couldn't save clip: \(error.localizedDescription)" }
        }
    }

    func revealLastClip() {
        guard let url = lastClipURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Director's Cut (FLAGSHIP, slice 2 — signals → score → auto-save)

extension AppEngine {

    /// Turn the flagship on/off. ON builds the `HighlightDirector` and wires its
    /// `onHighlight` to the auto-save. OFF tears it down: the feed adapters then
    /// short-circuit, restoring the exact prior behaviour (zero overhead). Idempotent.
    func setDirectorsCutEnabled(_ on: Bool) {
        guard on != directorsCutEnabled else { return }
        if on {
            let director = HighlightDirector(config: _test_directorConfigOverride ?? HighlightDirector.Config())
            director.onHighlight = { [weak self] highlight in
                // `ingest` is only ever called on the main actor here, so this fires
                // on main; hop defensively and orchestrate on the main actor.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.scheduleHighlightCapture(highlight) }
                }
            }
            highlightDirector = director
            highlightCandidateStore = HighlightCandidateStore()
            highlightCandidates = []
            directorsCutEnabled = true
        } else {
            directorsCutEnabled = false
            highlightDirector = nil
            topDirectorHighlights = []
            // Cancel any deferred post-roll captures — off means nothing fires.
            for (_, timer) in pendingHighlightTimers { timer.invalidate() }
            pendingHighlightTimers.removeAll()
            highlightCandidateStore = nil
            highlightCandidates = []
        }
    }

    /// Test seam: the bounded auto-saver's metrics (admitted/dropped/concurrency).
    var _test_highlightAutoSaverMetrics: HighlightAutoSaver.Metrics { highlightAutoSaver.metrics }

    /// There must be somewhere to clip FROM — a live recording/stream or an armed
    /// replay ring (a highlight is pulled from the `ReplayBuffer`). Absent that,
    /// scoring is pointless, so signals aren't ingested. The test seam counts too.
    private var directorsCutHasClipSource: Bool {
        isRecording || isStreaming || replayBuffer != nil || _test_highlightSaverOverride != nil
    }

    /// The single gate every wired signal funnels through. One bool of work when
    /// the flagship is off (nothing is ingested, no behaviour change).
    private func ingestHighlight(_ signal: HighlightSignal) {
        guard directorsCutEnabled, !didShutdown,
              let director = highlightDirector,
              directorsCutHasClipSource else { return }
        director.ingest(signal)
        topDirectorHighlights = director.topHighlights
    }

    // MARK: Live-signal feed adapters
    //
    // Each maps a native live event → `HighlightSignal` exactly as slice-1's
    // factories cite, then funnels through `ingestHighlight`. These are the wired
    // path the source callbacks chain into (and the deterministic test entry points).

    /// `TransientDetector.onTransient` (`TransientInfo`) → `.audioTransient`.
    func feedTransientToDirector(_ info: TransientInfo) {
        ingestHighlight(.audioTransient(strength: info.strength, at: info.pts))
    }

    /// `LiveCaptioner.onCaption` (`CaptionUpdate`) → keyword/laughter parse →
    /// `.captionKeyword` / `.captionLaughter`. Only FINAL lines are scored
    /// (partials update the on-air line in place — scoring them would double-count).
    func feedCaptionToDirector(_ update: CaptionUpdate) {
        guard update.isFinal else { return }
        guard let c = HighlightCaptionParser.classify(update.text) else { return }
        let pts = CMTime(seconds: update.hostSeconds, preferredTimescale: 600)
        switch c.kind {
        case .captionLaughter: ingestHighlight(.captionLaughter(intensity: c.intensity, at: pts))
        case .captionKeyword:  ingestHighlight(.captionKeyword(intensity: c.intensity, at: pts))
        default: break
        }
    }

    /// `AutoDirector`/`DirectorController` program switch (`DirectorDecision`) →
    /// `.sceneCut` (an impulse cue).
    func feedDecisionToDirector(_ decision: DirectorDecision) {
        ingestHighlight(.sceneCut(at: CMTime(seconds: decision.atSeconds, preferredTimescale: 600)))
    }

    /// `LoudnessMeter.measurement.momentary` sampled on the meter cadence →
    /// `.loudness` via `HighlightSignal.normalizeLoudness`. Silence/`-inf` → 0 →
    /// not ingested.
    func feedLoudnessToDirector(momentaryLUFS lufs: Double, at pts: CMTime) {
        let energy = HighlightSignal.normalizeLoudness(momentaryLUFS: lufs)
        guard energy > 0 else { return }
        ingestHighlight(.loudness(energy: energy, at: pts))
    }

    // MARK: Capture (moment + post-roll → paired 16:9 + 9:16)

    /// A highlight crossed threshold. Slice-3a: instead of clipping the trailing
    /// window *now* (which captures the run-up but misses the payoff), record the
    /// candidate immediately and SCHEDULE the extraction for `postRoll` seconds
    /// later, so the saved window spans `[peak − preRoll, peak + postRoll]`. The
    /// candidate is persisted at once (state `.scheduled`) so nothing is lost if
    /// the show ends before the post-roll elapses (shutdown flushes it).
    private func scheduleHighlightCapture(_ highlight: HighlightDirector.Highlight) {
        guard directorsCutEnabled, !didShutdown, let store = highlightCandidateStore else { return }

        let peak = highlight.peakSeconds
        let candidate = HighlightCandidate(
            id: UUID(),
            peakSeconds: peak,
            windowStart: peak - directorsCutPreRollSeconds,
            windowEnd: peak + directorsCutPostRollSeconds,
            score: highlight.score,
            reason: highlight.dominantSignal.rawValue,
            horizontalURL: nil, verticalURL: nil,
            state: .scheduled, note: nil)
        store.append(candidate)
        highlightCandidates = store.all()
        persistHighlightSidecar()

        // Defer by a REAL post-roll delay (we must wait real time for the payoff
        // frames to actually reach the ring). The window itself is pinned to house
        // PTS — no wall-clock in the window math (Bible Class D).
        let id = candidate.id
        let timer = Timer.scheduledTimer(withTimeInterval: max(0, directorsCutPostRollSeconds),
                                         repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.performHighlightCapture(id: id, flushing: false) }
        }
        pendingHighlightTimers[id] = timer
    }

    /// Extract the candidate's window and produce the paired H+V assets. When
    /// `flushing` (shutdown before the post-roll elapsed), the window's end is
    /// clamped to whatever the ring actually holds — flush what's available.
    private func performHighlightCapture(id: UUID, flushing: Bool) {
        pendingHighlightTimers[id]?.invalidate()
        pendingHighlightTimers[id] = nil
        guard let store = highlightCandidateStore,
              let candidate = store.all().first(where: { $0.id == id }) else { return }
        guard let saver = _test_highlightSaverOverride ?? replayBuffer else {
            markCandidate(id, state: .failed, note: "no replay ring to clip from")
            lastError = "Director's Cut: no replay buffer to clip the highlight from."
            return
        }

        // Clamp the requested window to the ring's actual coverage. A short ring or
        // a not-yet-arrived / shutdown-truncated post-roll narrows the window
        // rather than failing (Bible Class G — hostile-but-legal).
        var start = CMTime(seconds: candidate.windowStart, preferredTimescale: 600)
        var end = CMTime(seconds: candidate.windowEnd, preferredTimescale: 600)
        var note: String? = flushing ? "flushed at shutdown (post-roll truncated)" : nil
        if let avail = saver.availableWindow {
            if CMTimeCompare(start, avail.start) < 0 { start = avail.start; note = appendNote(note, "clamped start (ring too short)") }
            if CMTimeCompare(end, avail.end) > 0 { end = avail.end; note = appendNote(note, "clamped end (post-roll unavailable)") }
        }
        guard CMTimeCompare(end, start) > 0 else {
            markCandidate(id, state: .failed, note: appendNote(note, "empty window after clamp"))
            return
        }

        let vertical = _test_verticalReframerOverride ?? verticalReframer
        let (hTarget, vTarget) = highlightClipPaths(reason: candidate.reason)
        markCandidate(id, state: .saving, note: note)

        // One admitted unit produces BOTH clips so the in-flight bound throttles the
        // PAIR. Horizontal failure fails the unit; vertical failure degrades to a
        // horizontal-only partial (the H asset is never lost to a reframe error).
        let admitted = highlightAutoSaver.admit({
            let h = try await saver.saveHighlightWindow(from: start, to: end, to: hTarget)
            do {
                let v = try await vertical.reframeToVertical(horizontal: h, to: vTarget)
                return PairedClipOutcome(horizontal: h, vertical: v, verticalError: nil)
            } catch {
                return PairedClipOutcome(horizontal: h, vertical: nil,
                                         verticalError: String(describing: error))
            }
        }, onResult: { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch result {
                    case .success(let out):
                        self.lastHighlightURL = out.horizontal
                        self.markCandidate(id,
                                           state: out.vertical == nil ? .partial : .saved,
                                           note: appendNote(note, out.verticalError.map { "vertical reframe failed: \($0)" }),
                                           horizontalURL: out.horizontal, verticalURL: out.vertical)
                    case .failure(let err):
                        self.markCandidate(id, state: .failed,
                                           note: appendNote(note, "clip failed: \(err.localizedDescription)"))
                        self.lastError = "Director's Cut save failed: \(err.localizedDescription)"
                    }
                }
            }
        })
        if !admitted {
            // In-flight guard dropped this capture (burst). Record it, don't lose it.
            markCandidate(id, state: .failed, note: appendNote(note, "dropped by in-flight guard (burst)"))
        }
    }

    /// Fire every still-pending post-roll capture immediately with the available
    /// window (shutdown before the post-roll elapsed). Called from `shutdown()`
    /// BEFORE the replay ring is torn down, so the snapshot is still valid.
    func flushPendingHighlightCaptures() {
        for id in Array(pendingHighlightTimers.keys) {
            performHighlightCapture(id: id, flushing: true)
        }
    }

    /// Build the paired non-clobbering `Director's Cut/` paths (16:9 + 9:16). Each
    /// carries the reason + a monotonic counter; `RecorderFilePath.nonClobbering`
    /// is the last-line guard so a save NEVER overwrites a prior clip (sol #17).
    private func highlightClipPaths(reason: String) -> (horizontal: URL, vertical: URL) {
        let directory = _test_directorsCutDirectoryOverride
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Movies/Prism/Director's Cut")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        clipSaveCounter &+= 1
        let stamp = formatter.string(from: Date())
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let h = directory.appending(path: "Highlight \(stamp) \(reason) (\(clipSaveCounter)) 16x9.mov")
        let v = directory.appending(path: "Highlight \(stamp) \(reason) (\(clipSaveCounter)) 9x16.mov")
        return (RecorderFilePath.nonClobbering(h), RecorderFilePath.nonClobbering(v))
    }

    private func markCandidate(_ id: UUID, state: HighlightCandidate.State, note: String?,
                               horizontalURL: URL? = nil, verticalURL: URL? = nil) {
        guard let store = highlightCandidateStore else { return }
        let updated = store.update(id: id) { c in
            c.state = state
            if let note { c.note = note }
            if let horizontalURL { c.horizontalURL = horizontalURL }
            if let verticalURL { c.verticalURL = verticalURL }
        }
        highlightCandidates = updated
        persistHighlightSidecar()
    }

    private func persistHighlightSidecar() {
        guard let store = highlightCandidateStore else { return }
        store.persist(in: highlightReviewDirectory)
    }

    /// The folder the session's clips + sidecar live in (test-overridable).
    var highlightReviewDirectory: URL {
        _test_directorsCutDirectoryOverride
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Movies/Prism/Director's Cut")
    }
}

// MARK: - Review & Finish backend (FLAGSHIP slice-3c)
//
// The engine is the live backend for the Review & Finish UI: its review edits go
// through the SAME per-session `HighlightCandidateStore` the capture path owns, so
// `@Published highlightCandidates` stays the single source of truth (an edit
// re-publishes and rewrites the sidecar). See `ReviewFinish.swift`.
extension AppEngine: ReviewCandidateBackend {
    func reviewCandidates() -> [HighlightCandidate] { highlightCandidates }

    @discardableResult
    func applyReview(id: UUID, _ transform: (inout HighlightCandidate) -> Void) -> [HighlightCandidate] {
        guard let store = highlightCandidateStore else { return highlightCandidates }
        let updated = store.update(id: id, transform)
        highlightCandidates = updated
        persistHighlightSidecar()
        return updated
    }
}

/// Compose two optional notes into one "; "-joined string (either may be nil).
private func appendNote(_ base: String?, _ add: String?) -> String? {
    switch (base, add) {
    case (nil, nil): return nil
    case (let b?, nil): return b
    case (nil, let a?): return a
    case (let b?, let a?): return "\(b); \(a)"
    }
}

// MARK: - Reactive trigger (feature 4: PrismAudio.TransientDetector)

/// What a detected loud program transient auto-fires. `.none` (default) = off.
enum ReactiveTrigger: String, CaseIterable, Identifiable, Sendable {
    case none, strobe, stinger, meme
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none:    return "None"
        case .strobe:  return "Strobe pulse"
        case .stinger: return "Arm next stinger"
        case .meme:    return "Trigger meme"
        }
    }
}

extension AppEngine {

    /// Arm/disarm the reactive trigger. A non-`.none` action spins up a
    /// `TransientDetector` on the program master mix (fed via the fan-out audio
    /// tap); its `onTransient` hops to the main actor and fires the chosen effect.
    /// The detector debounces internally. `.none` tears it down.
    func setReactiveTrigger(_ action: ReactiveTrigger) {
        guard action != reactiveTrigger else { return }
        reactiveTrigger = action
        if action == .none {
            fanOut.setTransientDetector(nil)
            transientDetector = nil
        } else if transientDetector == nil {
            ensureAudioMixerStarted() // master-mix tap must be live to feed the detector
            let detector = TransientDetector(sampleRate: 48_000)
            // Reactive-trigger effect (existing behaviour). The flagship's highlight
            // feed CHAINS onto this — both fire, the effect first — so enabling
            // Director's Cut never clobbers the reactive trigger (and vice versa).
            let fireEffect: @Sendable (TransientInfo) -> Void = { [weak self] _ in
                DispatchQueue.main.async { self?.fireReactiveTrigger() }
            }
            let feedHighlight: @Sendable (TransientInfo) -> Void = { [weak self] info in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.feedTransientToDirector(info) }
                }
            }
            detector.onTransient = HighlightFeeds.chain(fireEffect, feedHighlight)
            transientDetector = detector
            fanOut.setTransientDetector(detector)
        }
    }

    private func fireReactiveTrigger() {
        switch reactiveTrigger {
        case .none:    return
        case .meme:    triggerFirstMeme(stingerOnly: false)
        case .stinger: triggerFirstMeme(stingerOnly: true)
        case .strobe:  pulseProgramStrobe()
        }
    }

    /// Fire the first available meme (or arm the first stinger-mode item),
    /// reusing the existing `triggerMeme` path. No-op when no matching tile exists.
    private func triggerFirstMeme(stingerOnly: Bool) {
        let item = stingerOnly
            ? memeItems.first(where: { $0.mode == .stinger })
            : memeItems.first
        if let item { triggerMeme(id: item.id) }
    }

    /// A one-shot full-frame flash on the top program layer, reusing the strobe
    /// path. Only added to a layer with NO user-configured strobe (so a beat
    /// strobe is never clobbered); restored to none after a brief flash.
    private func pulseProgramStrobe() {
        guard let top = scene.layers.max(by: { $0.zIndex < $1.zIndex }) else { return }
        let id = top.sourceID
        guard effectPipelines[id] != nil, strobe(for: id) == nil else { return }
        var flash = StrobeEffect()
        flash.intensity = 0.9
        flash.syncToBeat = false
        flash.freeRunHz = 6
        setStrobe(flash, for: id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            self?.setStrobe(nil, for: id)
        }
    }
}
