import Foundation

// MemoryGovernor — Prism's graceful-degrade memory governor (G1 v1a).
//
// STATUS: INERT. This type is fully implemented + tested but NOT yet wired into
// AppEngine. It ships tested-but-unused so its numbers can be trusted before any
// automation acts on them. v1b wires the 4 admission sites + the OS-pressure
// listener + a gauge; v2 automates the scarier degrade rungs.
//
// Core principle (DESIGN): CACHES degrade silently; COMMITMENTS (things a
// producer relies on still existing after the show — a replay clip, an ISO
// angle, the live effect quality, the source capture resolution) are never
// reduced without telling the user, and NEVER reduced just because the user
// added something new. So:
//   • user-caused overage        => REFUSE the new thing up-front, with a remedy
//   • environment-caused pressure => AUTO-DEGRADE the ladder (caches first)
//
// PURITY: the decision logic is pure + deterministic. `physicalRAM` and the
// clock (`now`) are injected — this file never calls ProcessInfo, Date(), or an
// RNG. `import Foundation` is only for NSLock (ledger thread-safety) and
// String(format:) (remedy text). All budget/admission/degrade math is integer.

// MARK: - Byte units

private enum Size {
    static let KiB: Int64 = 1024
    static let MiB: Int64 = 1024 * 1024
    static let GiB: Int64 = 1024 * 1024 * 1024
}

// MARK: - LoadClass — the priority ladder (shed-first → sacrosanct)

/// Every consumer of resident memory is tagged with a `LoadClass`. The ladder is
/// ordered by `shedOrder` (ascending = shed first). Three bands:
///   • CACHE       — degradable silently, rebuilt on demand (rungs 1–3)
///   • COMMITMENT  — a producer relies on it; reduce only with consent (rungs 4–7)
///   • SACROSANCT  — the live show itself; NEVER reduced by any governor path.
public enum LoadClass: String, CaseIterable, Sendable, Hashable {
    // --- caches (shed silently) ---
    case memeCache          // rung 1: decoded meme/sticker LRU
    case previewQuality     // rung 2: multiview/preview render scale
    case idleSourcePool     // rung 3: buffers held by not-on-air sources
    // --- commitments (consent required to reduce) ---
    case replayBuffer       // rung 4: instant-replay ring (ephemeral commitment)
    case isoAngle           // rung 5: an isolated-angle recording
    case liveEffectQuality  // rung 6: on-air effect chain fidelity
    case sourceCaptureRes   // rung 7: a capture's native resolution
    // --- sacrosanct (the live show — untouchable) ---
    case streamEncode       // outbound stream encoder
    case programRecord      // the program recording being written to disk
    case audioEngine        // the audio graph
    case compositor         // the program compositor

    /// The ladder, low priority (shed first) → high priority (sacrosanct).
    /// `shedOrder` and all rung logic are driven off this single array.
    public static let ladder: [LoadClass] = [
        .memeCache, .previewQuality, .idleSourcePool,
        .replayBuffer, .isoAngle, .liveEffectQuality, .sourceCaptureRes,
        .streamEncode, .programRecord, .audioEngine, .compositor,
    ]

    /// Ascending priority index (0 = shed first). Data-driven off `ladder`.
    public var shedOrder: Int {
        // `ladder` is asserted complete by a test; force-unwrap is safe.
        Self.ladder.firstIndex(of: self)!
    }

    /// The live show. No admission or degrade path may EVER propose reducing one.
    public var isSacrosanct: Bool {
        switch self {
        case .streamEncode, .programRecord, .audioEngine, .compositor: return true
        default: return false
        }
    }

    /// A producer-visible promise. Reducible only with explicit consent, and
    /// never merely because the user asked to add something new.
    public var isCommitment: Bool {
        switch self {
        case .replayBuffer, .isoAngle, .liveEffectQuality, .sourceCaptureRes: return true
        default: return false
        }
    }

    /// The classes a v1b-enforce admission gate may REFUSE up-front at the hard
    /// limit — exactly the user-add commitments that have an add-site and can be
    /// safely declined without harming the running show: an extra source, an ISO
    /// angle, or arming the replay ring. The primary program record and the live
    /// stream are NEVER in this set (protect the show over a new commitment, but
    /// never block the show itself). `liveEffectQuality` has no user add-site, so
    /// it is degraded (with consent), never refused, and is excluded here.
    public var isRefusable: Bool {
        switch self {
        case .isoAngle, .sourceCaptureRes, .replayBuffer: return true
        default: return false
        }
    }

    /// Silently degradable. The only bytes admission is allowed to auto-reclaim.
    public var isCache: Bool { !isSacrosanct && !isCommitment }

    /// The cache classes, in shed order — the reclaimable set.
    public static var cacheClasses: [LoadClass] {
        ladder.filter { $0.isCache }
    }
}

// MARK: - Resolution + cost model

/// A capture/encode resolution. `pixelCount` drives every per-frame byte figure.
public enum Resolution: Sendable, Equatable, Hashable {
    case hd720, hd1080, uhd4k
    case custom(width: Int, height: Int)

    public var pixelCount: Int64 {
        switch self {
        case .hd720:  return 1280 * 720
        case .hd1080: return 1920 * 1080
        case .uhd4k:  return 3840 * 2160
        case let .custom(w, h): return Int64(max(0, w)) * Int64(max(0, h))
        }
    }
}

/// A user-initiated add whose worst-case resident cost we estimate before
/// admitting it. One case per wired add-site.
public enum AdmissionKind: Sendable, Equatable {
    case startISOAngle(resolution: Resolution)
    /// `effectsEnabled` — the source's effect pipeline exists; `effectsActive` —
    /// a NON-TRIVIAL effect chain is actually running. The ~47.5 MiB (4K) effect
    /// pool is charged only when BOTH hold: a freshly-added source has an identity
    /// chain (effectsActive == false) and costs ~base-pool only (closes the
    /// observed 0.727 over-estimate); a source carrying live effects stays
    /// worst-case-high.
    case addSource(resolution: Resolution, effectsEnabled: Bool, effectsActive: Bool)
    case enableReplay(durationSec: Double, bitrate: Int64)
    case startProgramRecord(resolution: Resolution)
    /// Outbound stream encoder — same encoder+queue shape as a record, at the
    /// stream bitrate (6 Mbps default). Sacrosanct: warned, never refused.
    case streamEncode(resolution: Resolution, bitrate: Int64)
    /// The animated-meme decoded-frame LRU, reported against its REAL aggregate
    /// byte total (not a proxy). A cache: shed silently, never refused.
    case memeCache(aggregateBytes: Int64)

    /// The ledger class this add books into.
    public var loadClass: LoadClass {
        switch self {
        case .startISOAngle:     return .isoAngle
        case .addSource:         return .sourceCaptureRes
        case .enableReplay:      return .replayBuffer
        case .startProgramRecord: return .programRecord
        case .streamEncode:      return .streamEncode
        case .memeCache:         return .memeCache
        }
    }
}

/// The single, documented worst-case cost table. Every constant cites its basis;
/// where the audit under-specified a figure it is FLAGGED and a conservative
/// assumption is made (worst-case-high, so admission errs toward protecting the
/// show, never toward over-committing memory).
public enum MemoryCostModel {

    // --- per-frame ---
    /// BGRA (kCVPixelFormatType_32BGRA — PixelBufferPool's default) = 4 B/px.
    static let bytesPerPixelBGRA: Int64 = 4

    static func frameBytes(_ res: Resolution) -> Int64 {
        res.pixelCount * bytesPerPixelBGRA
    }

    // --- source capture / effect pool ---
    /// A source render canvas keeps this many buffers resident.
    /// Basis: `SourceRenderCanvas.init(minimumBufferCount: 4)` and
    /// `MetalCompositor` pool (both minimumBufferCount = 4).
    static let sourcePoolBuffers: Int64 = 4

    /// Effect-chain overhead attributed to a 4K source WITH effects on.
    /// Basis: the audit figure "4K source-effect pool ~47.5 MiB".
    /// FLAG: the audit gave only this single number for the *effects* pool and
    /// did not separately break out the base capture pool, so here 47.5 MiB is
    /// modeled as the effects OVERHEAD added on top of the buffer-count base pool
    /// above (worst-case-high). Scaled to other resolutions by pixel ratio.
    static let effectPool4KBytes: Int64 = Int64(47.5 * Double(Size.MiB)) // 49,807,360
    static let uhd4kPixels: Int64 = 3840 * 2160

    static func effectOverheadBytes(_ res: Resolution) -> Int64 {
        // Integer pixel-ratio scale of the 4K anchor.
        effectPool4KBytes * res.pixelCount / uhd4kPixels
    }

    // --- encoder writers (ISO angle, program record) ---
    /// Input surfaces a VideoToolbox encoder can hold in flight.
    /// FLAG: the audit specified only an "ISO writer buffer bound" qualitatively;
    /// 6 input surfaces is a conservative documented assumption for a VT encoder
    /// pipeline depth (matches typical B-frame + in-flight reference budgets).
    static let encoderPoolBuffers: Int64 = 6

    /// Compressed writer queue we bound each encoded writer to, in seconds.
    /// Assumption (documented): a 2 s bounded muxer/writer backlog.
    static let writerQueueSeconds: Double = 2

    /// Default program/stream encode bitrate (bits/s).
    /// Basis: `ProgramEncoder averageBitrate = 6_000_000`, RTMP/SRT defaults 6 Mbps.
    static let defaultStreamBitrate: Int64 = 6_000_000

    /// Default disk-record bitrate (bits/s).
    /// Basis: `MovieRecorder videoBitrate = 12_000_000`.
    static let defaultRecordBitrate: Int64 = 12_000_000

    /// Default replay ring bitrate when a caller does not specify one.
    /// Basis: replay is encoded at the program bitrate (6 Mbps).
    static let defaultReplayBitrate: Int64 = 6_000_000

    /// Keyframe/index overhead added on top of the raw ring size, percent.
    static let replayHeadroomPercent: Int64 = 5

    static func writerQueueBytes(bitrate: Int64) -> Int64 {
        Int64((writerQueueSeconds * Double(max(0, bitrate)) / 8.0).rounded(.up))
    }

    /// Worst-case resident bytes for a user-initiated add.
    public static func estimateWorstCase(for kind: AdmissionKind) -> Int64 {
        switch kind {
        case let .addSource(res, effectsEnabled, effectsActive):
            // Base capture pool always resident; the effect pool is charged only
            // when a non-trivial chain is actually running (effectsEnabled AND
            // effectsActive). A plain source estimates ~base-pool → ratio ≈ 1.0.
            let base = sourcePoolBuffers * frameBytes(res)
            let fx = (effectsEnabled && effectsActive) ? effectOverheadBytes(res) : 0
            return base + fx

        case let .startISOAngle(res):
            // Encoder input surface pool + bounded compressed writer queue.
            return encoderPoolBuffers * frameBytes(res)
                + writerQueueBytes(bitrate: defaultRecordBitrate)

        case let .startProgramRecord(res):
            return encoderPoolBuffers * frameBytes(res)
                + writerQueueBytes(bitrate: defaultRecordBitrate)

        case let .streamEncode(res, bitrate):
            // Same encoder+queue shape as a record, at the stream bitrate.
            let br = bitrate > 0 ? bitrate : defaultStreamBitrate
            return encoderPoolBuffers * frameBytes(res)
                + writerQueueBytes(bitrate: br)

        case let .memeCache(aggregateBytes):
            // Report against the cache's REAL aggregate decoded-byte total.
            return max(0, aggregateBytes)

        case let .enableReplay(durationSec, bitrate):
            guard durationSec > 0, bitrate > 0 else { return 0 }
            let raw = Int64((durationSec * Double(bitrate) / 8.0).rounded(.up))
            return raw + raw * replayHeadroomPercent / 100
        }
    }
}

// MARK: - Budget

public struct Budget: Equatable, Sendable {
    public let total: Int64      // memory Prism will use for itself
    public let softLimit: Int64  // 80% — admission gate / degrade trigger band
    public let hardLimit: Int64  // 95% — critical: degrade regardless of pressure

    public init(total: Int64, softLimit: Int64, hardLimit: Int64) {
        self.total = total
        self.softLimit = softLimit
        self.hardLimit = hardLimit
    }
}

// MARK: - Admission

public struct AdmissionRequest: Sendable, Equatable {
    public let loadClass: LoadClass
    public let worstCaseBytes: Int64

    public init(loadClass: LoadClass, worstCaseBytes: Int64) {
        self.loadClass = loadClass
        self.worstCaseBytes = worstCaseBytes
    }

    /// Build a request straight from a user-add kind using the cost model.
    public init(kind: AdmissionKind) {
        self.loadClass = kind.loadClass
        self.worstCaseBytes = MemoryCostModel.estimateWorstCase(for: kind)
    }
}

/// A concrete, ledger-derived way for the user to make room. Never a demand to
/// touch a sacrosanct class.
public struct RemedySuggestion: Sendable, Equatable {
    public let message: String
    public let targetClass: LoadClass
    public let estimatedFreedBytes: Int64

    public init(message: String, targetClass: LoadClass, estimatedFreedBytes: Int64) {
        self.message = message
        self.targetClass = targetClass
        self.estimatedFreedBytes = estimatedFreedBytes
    }
}

public enum AdmissionDecision: Sendable, Equatable {
    /// Fits under the soft limit as-is.
    case admit
    /// Fits only after shedding rung 1–3 caches; `reclaimBytes` = the cache bytes freed.
    case admitAfterReclaimingCaches(reclaimBytes: Int64)
    /// Won't fit even after dropping every cache. Reports the residual gap, which
    /// commitment/sacrosanct classes are being protected, and a real remedy.
    case refuse(gapBytes: Int64, protecting: [LoadClass], remedy: RemedySuggestion)
}

/// The v1b-ENFORCE admission outcome, with SAFE DEFAULTS. Distinct from the
/// stricter `AdmissionDecision` (which refuses at the SOFT limit): enforcement
/// refuses ONLY at the HARD limit (near-OOM) and ONLY for `isRefusable` classes,
/// so an imprecise cost estimate can never spuriously block a normal add. Soft
/// pressure only WARNS.
public enum EnforceDecision: Sendable, Equatable {
    /// Plenty of headroom (or enforcement disabled) — perform the add.
    case allow
    /// Projected use is in the soft band — allow the add, but raise a passive
    /// warning so the UI can surface an 80% banner. Never blocks.
    case warn
    /// At/over the hard limit AND a refusable class — decline the add up-front
    /// with a concrete remedy. Never returned for a non-refusable class.
    case refuse(gapBytes: Int64, remedy: RemedySuggestion)
}

// MARK: - Degrade

public enum PressureLevel: Int, Sendable, Comparable {
    case normal = 0, warning = 1, critical = 2
    public static func < (lhs: PressureLevel, rhs: PressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A degrade step. v1a emits ONLY the two pure-safe rungs (meme cache, replay).
public enum DegradeAction: Sendable, Equatable {
    case shrinkMemeCache(toBytes: Int64)  // rung 1
    case shrinkReplay(toSeconds: Double)  // rung 4 (soft)
    case suspendReplay                    // rung 4 (hard)
    // TODO(v2): the commitment rungs — NOT implemented in v1a because they touch
    // producer-visible state and need consent/automation policy:
    //   rung 2 previewQuality  -> .shrinkPreviewQuality(scale:)
    //   rung 3 idleSourcePool  -> .drainIdleSourcePool
    //   rung 5 isoAngle        -> .dropISOAngle(id:)
    //   rung 6 liveEffectQuality -> .reduceLiveEffectQuality(tier:)
    //   rung 7 sourceCaptureRes  -> .reduceSourceCaptureRes(to:)

    /// The class this action reduces. Used to guard the sacrosanct invariant.
    public var loadClass: LoadClass {
        switch self {
        case .shrinkMemeCache:            return .memeCache
        case .shrinkReplay, .suspendReplay: return .replayBuffer
        }
    }
}

public struct DegradeConfig: Sendable, Equatable {
    /// Meme-cache LRU tiers: 1 GiB → 256 MiB → 64 MiB.
    public var memeWarningBytes: Int64
    public var memeCriticalBytes: Int64
    /// Replay is shrunk to this many seconds on warning, suspended on critical.
    public var replayWarningSeconds: Double
    /// Hysteresis: only restore a shed rung once total < softLimit * this.
    public var restoreFraction: Double

    public init(memeWarningBytes: Int64 = 256 * 1024 * 1024, // 256 MiB
                memeCriticalBytes: Int64 = 64 * 1024 * 1024, //  64 MiB
                replayWarningSeconds: Double = 30,
                restoreFraction: Double = 0.85) {
        self.memeWarningBytes = memeWarningBytes
        self.memeCriticalBytes = memeCriticalBytes
        self.replayWarningSeconds = replayWarningSeconds
        self.restoreFraction = restoreFraction
    }

    public static let `default` = DegradeConfig()
}

/// A timestamped degrade event for the session log. `timestamp` is an injected
/// monotonic-seconds clock value — the core never reads a wall clock.
public struct DegradeEvent: Sendable, Equatable {
    public let timestamp: Double
    public let action: DegradeAction
    public let reason: String
    public let freedBytes: Int64

    public init(timestamp: Double, action: DegradeAction, reason: String, freedBytes: Int64) {
        self.timestamp = timestamp
        self.action = action
        self.reason = reason
        self.freedBytes = freedBytes
    }
}

// MARK: - ResourceAccount + Ledger

public struct ResourceAccount: Sendable, Equatable {
    public let id: String
    public let loadClass: LoadClass
    public var residentBytes: Int64

    public init(id: String, loadClass: LoadClass, residentBytes: Int64) {
        self.id = id
        self.loadClass = loadClass
        self.residentBytes = residentBytes
    }
}

/// Thread-safe resident-bytes ledger. Lock-guarded final class (Sendable-safe)
/// so the pure decision logic stays synchronous + deterministic in tests.
public final class MemoryLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var accounts: [String: ResourceAccount] = [:]

    public init() {}

    public func register(_ account: ResourceAccount) {
        lock.lock(); defer { lock.unlock() }
        accounts[account.id] = account
    }

    public func update(id: String, residentBytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        if var a = accounts[id] { a.residentBytes = residentBytes; accounts[id] = a }
    }

    public func release(id: String) {
        lock.lock(); defer { lock.unlock() }
        accounts[id] = nil
    }

    public var totalBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return accounts.values.reduce(0) { $0 + $1.residentBytes }
    }

    public func bytes(by loadClass: LoadClass) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return accounts.values.filter { $0.loadClass == loadClass }.reduce(0) { $0 + $1.residentBytes }
    }

    /// A per-class byte snapshot — the input to the pure decision functions.
    public func snapshot() -> [LoadClass: Int64] {
        lock.lock(); defer { lock.unlock() }
        var out: [LoadClass: Int64] = [:]
        for a in accounts.values { out[a.loadClass, default: 0] += a.residentBytes }
        return out
    }
}

// MARK: - MemoryGovernor

/// The coordinator: owns a ledger + degrade state + event log, and exposes the
/// pure decisions as `static` functions (the primary tested surface) plus thin
/// instance wrappers that snapshot the live ledger.
public final class MemoryGovernor: @unchecked Sendable {

    public let ledger: MemoryLedger
    public let physicalRAM: Int64
    public let fraction: Double
    public let config: DegradeConfig

    private let lock = NSLock()
    private var shedRungs: Set<LoadClass> = []
    private var events: [DegradeEvent] = []

    public init(physicalRAM: Int64,
                fraction: Double = 0.5,
                config: DegradeConfig = .default,
                ledger: MemoryLedger = MemoryLedger()) {
        self.physicalRAM = physicalRAM
        self.fraction = fraction
        self.config = config
        self.ledger = ledger
    }

    public var budget: Budget {
        Self.computeBudget(physicalRAM: physicalRAM, fraction: fraction)
    }

    // MARK: Pure decisions (deterministic; the tested surface)

    /// total = max(4 GiB, physicalRAM * fraction); soft = 80%; hard = 95%.
    /// `fraction` is clamped to [0.25, 0.9]. All integer math.
    public static func computeBudget(physicalRAM: Int64, fraction: Double = 0.5) -> Budget {
        let f = min(max(fraction, 0.25), 0.9)
        let scaled = Int64(Double(physicalRAM) * f)
        let total = max(4 * Size.GiB, scaled)
        return Budget(total: total,
                      softLimit: total * 80 / 100,
                      hardLimit: total * 95 / 100)
    }

    /// Admission decision. See `AdmissionDecision`.
    public static func admit(request: AdmissionRequest,
                             snapshot: [LoadClass: Int64],
                             physicalRAM: Int64,
                             fraction: Double = 0.5) -> AdmissionDecision {
        let budget = computeBudget(physicalRAM: physicalRAM, fraction: fraction)
        let currentTotal = snapshot.values.reduce(0, +)
        let projected = currentTotal + max(0, request.worstCaseBytes)

        // Fits as-is.
        if projected <= budget.softLimit { return .admit }

        // Fits only by shedding rung 1–3 caches.
        let reclaimable = LoadClass.cacheClasses.reduce(Int64(0)) { $0 + (snapshot[$1] ?? 0) }
        if projected - reclaimable <= budget.softLimit {
            return .admitAfterReclaimingCaches(reclaimBytes: reclaimable)
        }

        // Won't fit even with every cache gone → REFUSE the user's new thing.
        let gap = projected - reclaimable - budget.softLimit
        let protecting = LoadClass.ladder
            .filter { ($0.isCommitment || $0.isSacrosanct) && (snapshot[$0] ?? 0) > 0 }
        let remedy = remedy(snapshot: snapshot)
        return .refuse(gapBytes: gap, protecting: protecting, remedy: remedy)
    }

    /// v1b-ENFORCE admission with SAFE DEFAULTS (the wired app path). Pure +
    /// deterministic like `admit`, but with the enforcement policy baked in:
    ///   • enforcement disabled           → `.allow` (kill-switch honored here too)
    ///   • refusable class, projected ≥ hard → `.refuse` (near-OOM, up-front, with remedy)
    ///   • otherwise projected ≥ soft      → `.warn` (passive banner, never blocks)
    ///   • else                            → `.allow`
    /// Never refuses a non-refusable class (`.programRecord`/`.streamEncode` and
    /// every cache) — the primary show is protected over a new commitment, but the
    /// show itself is never blocked.
    public static func enforceAdmission(request: AdmissionRequest,
                                        snapshot: [LoadClass: Int64],
                                        physicalRAM: Int64,
                                        fraction: Double = 0.5,
                                        enforcementEnabled: Bool = true) -> EnforceDecision {
        guard enforcementEnabled else { return .allow }
        let budget = computeBudget(physicalRAM: physicalRAM, fraction: fraction)
        let currentTotal = snapshot.values.reduce(0, +)
        let projected = currentTotal + max(0, request.worstCaseBytes)

        if request.loadClass.isRefusable, projected >= budget.hardLimit {
            let gap = projected - budget.hardLimit
            return .refuse(gapBytes: gap, remedy: remedy(snapshot: snapshot))
        }
        if projected >= budget.softLimit { return .warn }
        return .allow
    }

    /// A real, ledger-derived reclaim the user can choose. Prefers the cheapest
    /// commitment to the user (shorten the ephemeral replay), then stopping an
    /// ISO angle, then closing a source. Never proposes a sacrosanct class.
    static func remedy(snapshot: [LoadClass: Int64]) -> RemedySuggestion {
        let replay = snapshot[.replayBuffer] ?? 0
        if replay > 0 {
            let floor = MemoryCostModel.estimateWorstCase(
                for: .enableReplay(durationSec: 30, bitrate: MemoryCostModel.defaultReplayBitrate))
            if replay > floor {
                let freed = replay - floor
                return RemedySuggestion(
                    message: "Shorten replay to 30 s to free ~\(mib(freed)) MiB.",
                    targetClass: .replayBuffer, estimatedFreedBytes: freed)
            }
        }
        let iso = snapshot[.isoAngle] ?? 0
        if iso > 0 {
            return RemedySuggestion(
                message: "Stop an ISO angle to free ~\(mib(iso)) MiB.",
                targetClass: .isoAngle, estimatedFreedBytes: iso)
        }
        let source = snapshot[.sourceCaptureRes] ?? 0
        if source > 0 {
            return RemedySuggestion(
                message: "Close a source to free ~\(mib(source)) MiB.",
                targetClass: .sourceCaptureRes, estimatedFreedBytes: source)
        }
        let fx = snapshot[.liveEffectQuality] ?? 0
        return RemedySuggestion(
            message: "Lower live effect quality to free ~\(mib(fx)) MiB.",
            targetClass: .liveEffectQuality, estimatedFreedBytes: fx)
    }

    /// Degrade actions for the current pressure. v1a returns ONLY rung 1 (meme
    /// cache) and rung 4 (replay), in shed order, and NEVER a sacrosanct action.
    public static func degrade(pressure: PressureLevel,
                               snapshot: [LoadClass: Int64],
                               physicalRAM: Int64,
                               fraction: Double = 0.5,
                               config: DegradeConfig = .default) -> [DegradeAction] {
        let budget = computeBudget(physicalRAM: physicalRAM, fraction: fraction)
        let total = snapshot.values.reduce(0, +)
        let overHard = total >= budget.hardLimit
        guard pressure != .normal || overHard else { return [] }

        // At/over the hard limit we treat pressure as critical no matter what.
        let critical = pressure == .critical || overHard

        var actions: [DegradeAction] = []

        // rung 1 — meme cache LRU (shed first).
        let meme = snapshot[.memeCache] ?? 0
        let memeTarget = critical ? config.memeCriticalBytes : config.memeWarningBytes
        if meme > memeTarget { actions.append(.shrinkMemeCache(toBytes: memeTarget)) }

        // rung 4 — replay (after rung 1). Shrink on warning, suspend on critical.
        let replay = snapshot[.replayBuffer] ?? 0
        if replay > 0 {
            actions.append(critical ? .suspendReplay : .shrinkReplay(toSeconds: config.replayWarningSeconds))
        }

        // INVARIANT: no path may reduce a sacrosanct class.
        for a in actions {
            precondition(!a.loadClass.isSacrosanct,
                         "degrade produced a sacrosanct action — invariant violated")
        }
        return actions
    }

    /// Hysteresis gate: a shed rung may be restored only once total memory has
    /// dropped below softLimit * restoreFraction (default 0.85) — no flapping.
    public static func canRestore(currentTotal: Int64,
                                  physicalRAM: Int64,
                                  fraction: Double = 0.5,
                                  restoreFraction: Double = 0.85) -> Bool {
        let budget = computeBudget(physicalRAM: physicalRAM, fraction: fraction)
        let threshold = Int64(Double(budget.softLimit) * restoreFraction)
        return currentTotal < threshold
    }

    /// Freed-bytes estimate for a degrade action, for the event log.
    static func estimatedFreed(action: DegradeAction, snapshot: [LoadClass: Int64]) -> Int64 {
        switch action {
        case let .shrinkMemeCache(toBytes):
            return max(0, (snapshot[.memeCache] ?? 0) - toBytes)
        case let .shrinkReplay(toSeconds):
            let floor = MemoryCostModel.estimateWorstCase(
                for: .enableReplay(durationSec: toSeconds, bitrate: MemoryCostModel.defaultReplayBitrate))
            return max(0, (snapshot[.replayBuffer] ?? 0) - floor)
        case .suspendReplay:
            return snapshot[.replayBuffer] ?? 0
        }
    }

    // MARK: Instance wrappers (snapshot the live ledger + record state)

    public func admit(_ request: AdmissionRequest) -> AdmissionDecision {
        Self.admit(request: request, snapshot: ledger.snapshot(),
                   physicalRAM: physicalRAM, fraction: fraction)
    }

    public func admit(kind: AdmissionKind) -> AdmissionDecision {
        admit(AdmissionRequest(kind: kind))
    }

    /// Instance `enforceAdmission` — snapshots the live ledger. `enforcementEnabled`
    /// is passed by the caller (the app gates it on the kill-switch env var).
    public func enforceAdmission(kind: AdmissionKind, enforcementEnabled: Bool) -> EnforceDecision {
        Self.enforceAdmission(request: AdmissionRequest(kind: kind),
                              snapshot: ledger.snapshot(),
                              physicalRAM: physicalRAM, fraction: fraction,
                              enforcementEnabled: enforcementEnabled)
    }

    /// Run degrade, record shed rungs, and append `DegradeEvent`s stamped with
    /// the injected `now` (monotonic seconds — no wall clock in the core).
    @discardableResult
    public func degrade(pressure: PressureLevel, now: Double) -> [DegradeAction] {
        let snap = ledger.snapshot()
        let actions = Self.degrade(pressure: pressure, snapshot: snap,
                                   physicalRAM: physicalRAM, fraction: fraction, config: config)
        lock.lock(); defer { lock.unlock() }
        for a in actions {
            shedRungs.insert(a.loadClass)
            events.append(DegradeEvent(
                timestamp: now, action: a,
                reason: "pressure=\(pressure)",
                freedBytes: Self.estimatedFreed(action: a, snapshot: snap)))
        }
        return actions
    }

    /// Whether shed rungs may be restored now (hysteresis on the live total).
    public func canRestore() -> Bool {
        Self.canRestore(currentTotal: ledger.totalBytes,
                        physicalRAM: physicalRAM, fraction: fraction,
                        restoreFraction: config.restoreFraction)
    }

    public var degradeLog: [DegradeEvent] {
        lock.lock(); defer { lock.unlock() }; return events
    }

    public var shedClasses: Set<LoadClass> {
        lock.lock(); defer { lock.unlock() }; return shedRungs
    }
}

// MARK: - Helpers

private func mib(_ bytes: Int64) -> String {
    String(format: "%.0f", Double(bytes) / Double(Size.MiB))
}
