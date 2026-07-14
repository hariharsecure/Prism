import AVFAudio
import Foundation
import PrismAudio
import PrismCore
import os

/// Size-bounded LRU over decoded `AVAudioPCMBuffer`s. Memory-safety insurance so
/// a full `preloadAll()` can never pin unbounded Float32 PCM: on insert past the
/// byte budget (or count cap) the least-recently-used entries are evicted until
/// the cache is back under budget. An evicted sound is simply re-decoded from
/// disk on its next trigger (preload-on-miss) — correct playback, no crash.
///
/// The budget is a HARD ceiling: even a lone entry larger than the whole budget
/// is evicted (never pinned), so `totalBytes` never exceeds `budgetBytes`. Such
/// an oversized sound still plays transiently (the engine voice retains it) and
/// re-decodes on its next trigger. Byte accounting uses each buffer's allocated
/// `frameCapacity`, the true footprint, not its (shorter) `frameLength`.
///
/// Not itself thread-safe: the `Soundboard` drives it entirely under its
/// `OSAllocatedUnfairLock`, mirroring the lock discipline of the plain dict it
/// replaced. Recency and byte accounting are `O(n)` in the (soundboard-scale)
/// entry count, which is negligible next to a WAV decode.
struct LRUBufferCache {
    private struct Entry { let buffer: AVAudioPCMBuffer; let bytes: Int }
    private var entries: [String: Entry] = [:]
    /// Recency order of ids: front = least-recently-used, back = most-recent.
    private var order: [String] = []
    private(set) var totalBytes: Int = 0
    private(set) var budgetBytes: Int
    private(set) var countCap: Int

    init(budgetBytes: Int, countCap: Int) {
        self.budgetBytes = max(0, budgetBytes)
        self.countCap = max(1, countCap)
    }

    /// Resident size of a decoded buffer: allocated `frameCapacity` × channels ×
    /// 4 (Float32). We account the ALLOCATED capacity, not the (possibly shorter)
    /// `frameLength`, because that is the real footprint the deinterleaved Float32
    /// PCM occupies — `SamplePlaybackEngine.normalized` over-allocates capacity
    /// (resample slack + padding), so `frameLength` would undercount the budget.
    static func byteSize(of buffer: AVAudioPCMBuffer) -> Int {
        Int(buffer.frameCapacity) * Int(buffer.format.channelCount) * MemoryLayout<Float>.size
    }

    var count: Int { entries.count }
    var keys: [String] { Array(entries.keys) }
    /// Membership probe that does NOT alter recency (introspection/tests).
    func contains(_ id: String) -> Bool { entries[id] != nil }
    /// Peek without touching recency.
    func peek(_ id: String) -> AVAudioPCMBuffer? { entries[id]?.buffer }

    /// Look up and mark most-recently-used. `nil` on miss.
    mutating func get(_ id: String) -> AVAudioPCMBuffer? {
        guard let e = entries[id] else { return nil }
        touch(id)
        return e.buffer
    }

    /// Insert (or replace) a buffer, then evict LRU entries until back under
    /// budget. Returns the evicted buffers (kept alive only until the caller
    /// releases them — a currently-playing voice retains its own copy).
    @discardableResult
    mutating func insert(_ id: String, buffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        if let old = entries.removeValue(forKey: id) {
            totalBytes -= old.bytes
            order.removeAll { $0 == id }
        }
        let bytes = Self.byteSize(of: buffer)
        entries[id] = Entry(buffer: buffer, bytes: bytes)
        order.append(id)               // newest = most-recently-used
        totalBytes += bytes
        return evictToBudget()
    }

    /// Lower/raise the budget; evicts immediately if the new budget is tighter.
    @discardableResult
    mutating func setBudget(_ bytes: Int) -> [AVAudioPCMBuffer] {
        budgetBytes = max(0, bytes)
        return evictToBudget()
    }

    private mutating func touch(_ id: String) {
        guard let idx = order.firstIndex(of: id) else { return }
        order.remove(at: idx)
        order.append(id)
    }

    /// Evict from the LRU end until under both caps — including the sole entry.
    /// A lone buffer larger than the whole budget is NOT pinned: it is evicted
    /// too, so `totalBytes` can never exceed `budgetBytes`. Such an oversized
    /// sound is still played transiently (the engine voice retains its own
    /// reference for the life of the note) and is simply re-decoded on its next
    /// trigger — it never silently blows the cache budget.
    private mutating func evictToBudget() -> [AVAudioPCMBuffer] {
        var evicted: [AVAudioPCMBuffer] = []
        while (totalBytes > budgetBytes || entries.count > countCap) && !order.isEmpty {
            let lru = order.removeFirst()
            if let e = entries.removeValue(forKey: lru) {
                totalBytes -= e.bytes
                evicted.append(e.buffer)
            }
        }
        return evicted
    }
}

/// Real-time-safe soundboard: preloads library samples into
/// `AVAudioPCMBuffer`s (no disk read on trigger) and plays them polyphonically
/// into an `AudioMixer` channel via a `SamplePlaybackEngine`. A triggered sound
/// is therefore in the program mix (records / streams / ducks / meters).
///
/// The decoded-buffer cache is a size-bounded LRU (see `LRUBufferCache`): it
/// never pins more than `cacheBudgetBytes` of PCM, evicting least-recently-used
/// sounds and re-decoding them on demand (preload-on-miss) if re-triggered.
public final class Soundboard: @unchecked Sendable {
    public enum SoundboardError: Error, CustomStringConvertible {
        case notLoaded(String)
        case loadFailed(String)
        public var description: String {
            switch self {
            case .notLoaded(let id): return "sound '\(id)' is not preloaded"
            case .loadFailed(let w): return "sample load failed: \(w)"
            }
        }
    }

    /// Default decoded-buffer cache budget (256 MiB). A full `preloadAll()` of a
    /// ~525 MiB library therefore stays resident only up to this ceiling.
    public static let defaultCacheBudgetBytes = 256 * 1024 * 1024

    public let channelID: SourceID
    /// The playback engine (exposed for headless manual-render verification).
    public let engine: SamplePlaybackEngine

    private let library: SoundLibrary?
    private let cache: OSAllocatedUnfairLock<LRUBufferCache>
    private let log = EngineLog.logger("sound.board")

    /// - Parameters:
    ///   - mixer: the program mixer; a channel `channelID` is added to it.
    ///   - library: catalog to resolve ids → files (nil = only `triggerBuffer`).
    ///   - cacheBudgetBytes: LRU byte budget for decoded buffers (default 256 MiB).
    ///   - cacheCountCap: optional hard cap on the number of cached buffers.
    public init(mixer: AudioMixer, library: SoundLibrary?,
                channelID: SourceID = SourceID("sound.board"), voiceCount: Int = 16,
                cacheBudgetBytes: Int = Soundboard.defaultCacheBudgetBytes,
                cacheCountCap: Int = .max) throws {
        self.channelID = channelID
        self.library = library
        self.cache = OSAllocatedUnfairLock(
            initialState: LRUBufferCache(budgetBytes: cacheBudgetBytes, countCap: cacheCountCap))
        self.engine = try SamplePlaybackEngine(sourceID: channelID, voiceCount: voiceCount)
        // A8: drop the dead `format:` arg (AudioMixer ignores it, converting lazily).
        let channel = try mixer.addChannel(id: channelID)
        engine.sinkChannel = channel
    }

    // MARK: Cache config + introspection

    /// LRU byte budget. Lowering it evicts least-recently-used buffers at once.
    public var cacheBudgetBytes: Int {
        get { cache.withLock { $0.budgetBytes } }
        set { cache.withLock { _ = $0.setBudget(newValue) } }
    }
    /// Approximate resident PCM bytes currently held by the cache.
    public var cachedBytes: Int { cache.withLock { $0.totalBytes } }
    /// Number of decoded buffers currently resident.
    public var cachedCount: Int { cache.withLock { $0.count } }
    /// Whether `id` is resident right now (does NOT affect recency).
    public func isCached(id: String) -> Bool { cache.withLock { $0.contains(id) } }

    // MARK: Loading

    /// Decode a WAV/AIFF/etc. file to an engine-format buffer (off the RT path).
    public func loadBuffer(url: URL) throws -> AVAudioPCMBuffer {
        do { return try engine.loadFile(url) }
        catch { throw SoundboardError.loadFailed(String(describing: error)) }
    }

    /// Preload one library sound by id. Inserted into the LRU cache (may evict
    /// least-recently-used buffers to stay under `cacheBudgetBytes`).
    @discardableResult
    public func preload(id: String) throws -> AVAudioPCMBuffer {
        guard let lib = library, let url = lib.url(forID: id) else { throw SoundboardError.notLoaded(id) }
        let buf = try loadBuffer(url: url)   // decode off-lock (file I/O)
        cache.withLock { _ = $0.insert(id, buffer: buf) }
        return buf
    }

    /// Register an already-decoded buffer under an id (e.g. a synthesized pad).
    /// Also subject to the LRU budget.
    public func register(id: String, buffer: AVAudioPCMBuffer) {
        cache.withLock { _ = $0.insert(id, buffer: buffer) }
    }

    /// Preload up to `limit` sounds (optionally filtered by category), filling
    /// the cache to its budget: entries are decoded in order and the LRU evicts
    /// as needed, so the resident set is the most-recently-loaded window that
    /// fits under `cacheBudgetBytes`. Returns the ids that decoded successfully
    /// (a returned id may have since been evicted — check `isCached(id:)`).
    @discardableResult
    public func preloadAll(category: String? = nil, limit: Int = .max) -> [String] {
        guard let lib = library else { return [] }
        let source = category.map { lib.entries(inCategory: $0) } ?? lib.entries
        var loaded: [String] = []
        for e in source.prefix(limit) {
            if (try? preload(id: e.id)) != nil { loaded.append(e.id) }
        }
        log.info("soundboard preloaded \(loaded.count) sample(s); resident \(self.cachedCount) buf / \(self.cachedBytes) B")
        return loaded
    }

    public var loadedIDs: [String] { cache.withLock { $0.keys } }
    /// Fetch a cached buffer, marking it most-recently-used (an access). Returns
    /// `nil` on a cache miss (never resident / evicted) — use `preload` to reload.
    public func buffer(id: String) -> AVAudioPCMBuffer? { cache.withLock { $0.get(id) } }

    // MARK: Lifecycle

    public func startLive() throws { try engine.startLive() }
    public func startManual(maximumFrameCount: AVAudioFrameCount = 4096) throws {
        try engine.startManual(maximumFrameCount: maximumFrameCount)
    }
    public func stop() { engine.stop() }

    // MARK: Trigger (RT-safe: buffer already in memory)

    /// Trigger a preloaded sound by id. Polyphonic; `loop` for sustained pads.
    /// Marks the sound most-recently-used. On a cache miss (never preloaded, or
    /// evicted under budget pressure) it transparently re-decodes from the
    /// library — preload-on-miss — so an evicted sound still plays correctly.
    /// Throws `.notLoaded` only when no library entry resolves the id at all.
    public func trigger(id: String, loop: Bool = false, volume: Float = 1.0) throws {
        let buf = try cache.withLock { $0.get(id) } ?? preload(id: id)
        engine.play(buf, loop: loop, volume: volume)
    }

    /// Trigger an arbitrary already-loaded buffer.
    public func triggerBuffer(_ buffer: AVAudioPCMBuffer, loop: Bool = false, volume: Float = 1.0) {
        engine.play(buffer, loop: loop, volume: volume)
    }

    public func stopAll() { engine.stopAll() }
}
