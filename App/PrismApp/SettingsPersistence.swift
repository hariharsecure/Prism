import Foundation
import PrismCompositor
import PrismCore
import PrismSound
import PrismSources
import os

// MARK: - Settings persistence (mirrors the sound-pad UserDefaults pattern)
//
// The app already persists a few things to `UserDefaults` (the sound-pad
// assignments in `savePadAssignments`, the Link pairing code, plus the
// on-disk scene-collection / stream-destination stores). This file extends that
// pattern to the settings that were previously in-memory only and lost on
// relaunch:
//
//   • the beat-maker grid  (`beatPattern`)                → JSON blob
//   • the transition kind + enable/duration + stinger pick → small scalar keys
//   • user-added MemeBoard tiles                          → security-scoped bookmarks
//   • per-source tile / pulse / video-wall effects        → keyed by SourceID.raw
//   • the last-used montage settings                      → applied to new montages
//
// SANDBOXING: media files (meme tiles) are stored as security-scoped bookmarks,
// never raw absolute paths, so a sandboxed Release build can re-open them. If a
// referenced file is gone the entry is skipped silently (the user re-adds it) —
// never a crash. In the ad-hoc Debug build (no sandbox) the security-scope
// options are harmless no-ops.
//
// ACCESS: this is an extension in a separate file, so it can only READ the
// engine's `private(set)` published state and must go through the existing
// public setters to restore it. `montageSources` / `MontageEntry` are `private`
// to AppEngine, so the montage-defaults save takes explicit values from the
// setter call sites (which live in AppEngine.swift and can see them).

extension AppEngine {
    private static let persistLog = EngineLog.logger("app.persistence")

    private enum PersistKey {
        static let beatPattern       = "studio.prism.sound.beatPattern"
        static let transitionKind    = "studio.prism.transition.kind"
        static let transitionEnabled = "studio.prism.transition.enabled"
        static let transitionDur     = "studio.prism.transition.duration"
        static let stingerMedia      = "studio.prism.transition.stinger"
        static let userMemes         = "studio.prism.memes.userItems"
        static let sourceFX          = "studio.prism.sourceFX"
        static let montageDefaults   = "studio.prism.montage.defaults"
    }

    // MARK: Restore (called once from init, after the on-disk stores load)

    /// Restore the scalar settings that go through public setters. Beat pattern,
    /// meme tiles, per-source FX, and montage defaults restore lazily at their
    /// own natural entry points (buildSoundStack / prepareMemes / register /
    /// addMontageSource) so they land after the objects they attach to exist.
    func restorePersistedSettings() {
        let d = UserDefaults.standard
        // Transition enable + duration (only if a value was ever written).
        if d.object(forKey: PersistKey.transitionEnabled) != nil {
            setTransitionEnabled(d.bool(forKey: PersistKey.transitionEnabled))
        }
        if d.object(forKey: PersistKey.transitionDur) != nil {
            setTransitionDuration(d.double(forKey: PersistKey.transitionDur))
        }
        // Transition kind via the flat, String-backed UI companion.
        if let raw = d.string(forKey: PersistKey.transitionKind),
           let choice = TransitionKindChoice(rawValue: raw) {
            setTransitionKind(choice.kind)
        }
        // Stinger media id. The referenced source is not itself restored (sources
        // aren't persisted), so this may dangle until a matching source exists —
        // harmless (the picker just shows nothing checked). Restored for parity.
        if let rawID = d.string(forKey: PersistKey.stingerMedia), !rawID.isEmpty {
            setStingerMedia(SourceID(rawID))
        }
    }

    // MARK: Beat pattern

    func saveBeatPattern() {
        guard let data = try? JSONEncoder().encode(beatPattern) else { return }
        UserDefaults.standard.set(data, forKey: PersistKey.beatPattern)
    }

    /// The persisted beat grid, if any. `buildSoundStack` prefers this over the
    /// generated starter groove so an edited pattern survives relaunch.
    static func loadPersistedBeatPattern() -> BeatPattern? {
        guard let data = UserDefaults.standard.data(forKey: PersistKey.beatPattern) else { return nil }
        return try? JSONDecoder().decode(BeatPattern.self, from: data)
    }

    // MARK: Transition + stinger

    func saveTransitionSettings() {
        let d = UserDefaults.standard
        d.set(TransitionKindChoice.from(transitionKind).rawValue, forKey: PersistKey.transitionKind)
        d.set(transitionEnabled, forKey: PersistKey.transitionEnabled)
        d.set(transitionDuration, forKey: PersistKey.transitionDur)
        d.set(stingerMediaID?.raw ?? "", forKey: PersistKey.stingerMedia)
    }

    // MARK: User meme tiles (security-scoped bookmarks)

    private struct PersistedMeme: Codable {
        var bookmark: Data
        var mode: MemeMode
        var placement: MemePlacement
        var holdSec: Double
    }

    /// Persist every USER-added meme tile (built-in templates regenerate on
    /// launch, so they are excluded). Each tile's media is stored as a
    /// security-scoped bookmark; unbookmarkable URLs are skipped, never fatal.
    func saveUserMemes() {
        var out: [PersistedMeme] = []
        for item in memeItems where !item.isBuiltInTemplate {
            guard let bookmark = Self.makeBookmark(item.mediaURL) else { continue }
            out.append(PersistedMeme(bookmark: bookmark, mode: item.mode,
                                     placement: item.placement, holdSec: item.holdSec))
        }
        if let data = try? JSONEncoder().encode(out) {
            UserDefaults.standard.set(data, forKey: PersistKey.userMemes)
        }
    }

    /// Re-add the persisted user meme tiles. Called from `prepareMemes` AFTER the
    /// built-in templates are generated so the board shows templates + user tiles.
    /// A tile whose file is gone (stale bookmark) is skipped silently.
    func restoreUserMemes() {
        guard let data = UserDefaults.standard.data(forKey: PersistKey.userMemes),
              let stored = try? JSONDecoder().decode([PersistedMeme].self, from: data) else { return }
        for meme in stored {
            guard let url = Self.resolveBookmark(meme.bookmark) else { continue }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // Image/GIF memes decode fully at init, so releasing the scope right
            // after is safe; a MovieSource meme re-acquires its OWN scoped grant
            // inside addMeme (held until removeMeme), so this release is balanced.
            addMeme(url: url, mode: meme.mode, placement: meme.placement,
                    holdSec: meme.holdSec, isBuiltIn: false)
        }
    }

    // MARK: Per-source tile / pulse / video-wall effects

    private struct TileDTO: Codable {
        var mode: String; var rows: Int; var cols: Int; var seed: UInt64
        var softness: Double; var speed: Double; var direction: String
        var syncToBeat: Bool; var flipsPerBeat: Double
    }
    private struct PulseDTO: Codable { var intensity: Double; var style: String }
    private struct WallDTO: Codable { var rows: Int; var cols: Int; var mirror: Bool }
    /// Strobe/flash (feature 5): the flash color/intensity/rate; `startHostSeconds`
    /// is a runtime epoch (re-anchored on restore), so it is intentionally not saved.
    private struct StrobeDTO: Codable {
        var intensity: Double; var red: Double; var green: Double; var blue: Double
        var syncToBeat: Bool; var freeRunHz: Double
    }
    /// Presenter cutout (feature 5): the edge feather + background fill. A solid
    /// fill stores its sRGB; `transparent == true` means the alpha-out cutout.
    private struct CutoutDTO: Codable {
        var feather: Double
        var transparent: Bool
        var r: Double; var g: Double; var b: Double; var a: Double
    }
    private struct SourceFXDTO: Codable {
        var tile: TileDTO?; var pulse: PulseDTO?; var wall: WallDTO?
        var strobe: StrobeDTO?; var cutout: CutoutDTO?
        var isEmpty: Bool {
            tile == nil && pulse == nil && wall == nil && strobe == nil && cutout == nil
        }
    }

    private func loadSourceFXStore() -> [String: SourceFXDTO] {
        guard let data = UserDefaults.standard.data(forKey: PersistKey.sourceFX),
              let store = try? JSONDecoder().decode([String: SourceFXDTO].self, from: data)
        else { return [:] }
        return store
    }

    private func writeSourceFXStore(_ store: [String: SourceFXDTO]) {
        if let data = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(data, forKey: PersistKey.sourceFX)
        }
    }

    /// Persist the tile/pulse/video-wall snapshot for one source. Called from the
    /// FX setters. NOTE: movie/montage/generated SourceIDs are fresh UUIDs each
    /// launch and those sources are not auto-restored, so cross-relaunch
    /// reattachment only fires for STABLE-id sources (camera/mic device ids). The
    /// keyed store is still correct and drives within-session source-reselect.
    func saveSourceFX(for id: SourceID) {
        var store = loadSourceFXStore()
        let fx = sourceEffects[id]
        let dto = SourceFXDTO(
            tile: fx?.tile.map { t in
                TileDTO(mode: t.mode.rawValue, rows: t.rows, cols: t.cols, seed: t.seed,
                        softness: t.softness, speed: t.speed, direction: t.direction.rawValue,
                        syncToBeat: t.syncToBeat, flipsPerBeat: t.flipsPerBeat)
            },
            pulse: fx?.pulse.map { PulseDTO(intensity: $0.intensity, style: $0.style.rawValue) },
            wall: fx?.videoWall.map { WallDTO(rows: $0.rows, cols: $0.cols, mirror: $0.mirror) },
            strobe: fx?.strobe.map { s in
                StrobeDTO(intensity: s.intensity, red: s.red, green: s.green, blue: s.blue,
                          syncToBeat: s.syncToBeat, freeRunHz: s.freeRunHz)
            },
            cutout: cutoutState(for: id).map { c in
                switch c.background {
                case .transparent:
                    return CutoutDTO(feather: Double(c.feather), transparent: true,
                                     r: 0, g: 0, b: 0, a: 0)
                case .solidColor(let rgba):
                    return CutoutDTO(feather: Double(c.feather), transparent: false,
                                     r: rgba.r, g: rgba.g, b: rgba.b, a: rgba.a)
                }
            })
        if dto.isEmpty { store[id.raw] = nil } else { store[id.raw] = dto }
        writeSourceFXStore(store)
    }

    /// Reattach a persisted tile/pulse/video-wall snapshot when a source with a
    /// matching id (re)appears. Called from `register`.
    func restoreSourceFX(for id: SourceID) {
        guard let dto = loadSourceFXStore()[id.raw] else { return }
        if let t = dto.tile {
            var tile = TileEffect()
            tile.mode = TileGridMode(rawValue: t.mode) ?? .flicker
            tile.rows = t.rows; tile.cols = t.cols; tile.seed = t.seed
            tile.softness = t.softness; tile.speed = t.speed
            tile.direction = FXDirection(rawValue: t.direction) ?? .left
            tile.syncToBeat = t.syncToBeat; tile.flipsPerBeat = t.flipsPerBeat
            setTileEffect(tile, for: id)
        }
        if let p = dto.pulse {
            setBeatPulse(BeatPulseEffect(intensity: p.intensity,
                                         style: BeatPulseStyle(rawValue: p.style) ?? .bump), for: id)
        }
        if let w = dto.wall {
            setVideoWall(VideoWall(rows: w.rows, cols: w.cols, mirror: w.mirror), for: id)
        }
        if let s = dto.strobe {
            var strobe = StrobeEffect()
            strobe.intensity = s.intensity
            strobe.red = s.red; strobe.green = s.green; strobe.blue = s.blue
            strobe.syncToBeat = s.syncToBeat; strobe.freeRunHz = s.freeRunHz
            setStrobe(strobe, for: id)
        }
        // Presenter cutout only re-attaches for a cutout-capable feed (camera/movie)
        // that is present with the same id; setPresenterCutout rebuilds it in place.
        if let c = dto.cutout, isCutoutCapable(id) {
            let background: PresenterCutout.Background = c.transparent
                ? .transparent
                : .solidColor(RGBAColor(r: c.r, g: c.g, b: c.b, a: c.a))
            setPresenterCutout(CutoutState(feather: Float(c.feather), background: background), for: id)
        }
    }

    // MARK: Montage defaults (applied to newly-added montages)

    private struct MontageDefaultsDTO: Codable {
        var interval: Double
        var crossfade: Bool
        var crossfadeDuration: Double
        var kenBurns: Bool
        var shuffle: Bool
        var cutOnBeat: Bool
        var cutEveryBeats: Int
    }

    /// Remember the last-used montage settings so the next "Add Montage" inherits
    /// them. Values are passed in explicitly because `MontageEntry` is private.
    func saveMontageDefaults(interval: Double, crossfade: Bool, crossfadeDuration: Double,
                             kenBurns: Bool, shuffle: Bool, cutOnBeat: Bool, cutEveryBeats: Int) {
        let dto = MontageDefaultsDTO(interval: interval, crossfade: crossfade,
                                     crossfadeDuration: crossfadeDuration, kenBurns: kenBurns,
                                     shuffle: shuffle, cutOnBeat: cutOnBeat, cutEveryBeats: cutEveryBeats)
        if let data = try? JSONEncoder().encode(dto) {
            UserDefaults.standard.set(data, forKey: PersistKey.montageDefaults)
        }
    }

    /// Persisted montage defaults as `(interval, transition, kenBurns, shuffle,
    /// cutOnBeat, cutEveryBeats)`, or nil if none saved yet.
    func persistedMontageDefaults()
        -> (interval: Double, transition: MontageSource.Transition, kenBurns: Bool,
            shuffle: Bool, cutOnBeat: Bool, cutEveryBeats: Int)? {
        guard let data = UserDefaults.standard.data(forKey: PersistKey.montageDefaults),
              let dto = try? JSONDecoder().decode(MontageDefaultsDTO.self, from: data) else { return nil }
        let transition: MontageSource.Transition = dto.crossfade
            ? .crossfade(duration: dto.crossfadeDuration) : .cut
        return (dto.interval, transition, dto.kenBurns, dto.shuffle, dto.cutOnBeat, dto.cutEveryBeats)
    }

    // MARK: Bookmark helpers

    private static func makeBookmark(_ url: URL) -> Data? {
        if let data = try? url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
            return data
        }
        // Non-sandboxed / non-scoped URL: fall back to a plain bookmark.
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                              relativeTo: nil, bookmarkDataIsStale: &stale), !stale {
            return url
        }
        // Retry without the security-scope option (plain bookmark from Debug).
        var stale2 = false
        return try? URL(resolvingBookmarkData: data, options: [],
                        relativeTo: nil, bookmarkDataIsStale: &stale2)
    }
}
