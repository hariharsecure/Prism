import PrismCore
import XCTest
@testable import Prism

/// THE BUG (product-contract gap, confirmed 2026-07): the app persisted the
/// SCENE (layers/frames/z-order) but NOT the sources those layers reference —
/// `SettingsPersistence.swift` admitted as much. So a relaunched show pointed at
/// cameras/mics/screens/clips that no longer existed until the operator manually
/// re-added every one. A live-production app must reopen the SAME show.
///
/// THE FIX: `PersistedSource` (a Codable DTO capturing kind + STABLE identity +
/// per-source settings) saved to Application Support like `SceneCollection`, plus
/// a PURE `PersistedSource.plan(from:availableDeviceIDs:)` planner that classifies
/// each entry as "restore" or "unavailable — keep" WITHOUT touching hardware.
/// This test guards the contract hardware-free:
///   1. round-trip fidelity (kind / identity / settings / loop flag),
///   2. a file bookmark resolves back to the same path,
///   3. graceful degradation — an absent camera and a deleted-file bookmark both
///      decode fine and plan as "unavailable, keep" (never throw / crash).
final class SourcePersistenceTests: XCTestCase {

    // Helpers ----------------------------------------------------------------

    /// Create a real temp file and return its URL (registered for cleanup).
    private func makeTempFile(ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-src-\(UUID().uuidString).\(ext)")
        try Data([0x01, 0x02, 0x03]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func roundTrip(_ sources: [PersistedSource]) throws -> [PersistedSource] {
        let data = try JSONEncoder().encode(sources)
        return try JSONDecoder().decode([PersistedSource].self, from: data)
    }

    private func samePath(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }

    // 1. Round-trip fidelity -------------------------------------------------

    func testRoundTripFidelityAcrossKinds() throws {
        let movieURL = try makeTempFile(ext: "mov")
        let imageURL = try makeTempFile(ext: "png")
        let movieBookmark = try XCTUnwrap(AppEngine.makeBookmark(movieURL), "movie file should bookmark")
        let imageBookmark = try XCTUnwrap(AppEngine.makeBookmark(imageURL), "image file should bookmark")

        let original: [PersistedSource] = [
            PersistedSource(kind: .camera, name: "FaceTime HD", deviceID: "cam-uid-42"),
            PersistedSource(kind: .movie, name: "intro", bookmark: movieBookmark, loop: false),
            PersistedSource(kind: .image, name: "logo", bookmark: imageBookmark),
        ]

        let decoded = try roundTrip(original)
        XCTAssertEqual(decoded, original, "the whole set must survive a JSON round-trip")

        // Explicit field-level assertions (kind / identity / settings / loop).
        XCTAssertEqual(decoded[0].kind, .camera)
        XCTAssertEqual(decoded[0].deviceID, "cam-uid-42", "camera identity is the stable uniqueID, not the name")
        XCTAssertEqual(decoded[1].kind, .movie)
        XCTAssertEqual(decoded[1].loop, false, "the movie loop flag must round-trip")
        XCTAssertEqual(decoded[1].bookmark, movieBookmark)
        XCTAssertEqual(decoded[2].kind, .image)
        XCTAssertNil(decoded[2].loop, "an image has no loop flag")
    }

    // 2. File bookmark resolves back to the same path ------------------------

    func testFileBookmarkResolvesToSamePath() throws {
        let movieURL = try makeTempFile(ext: "mov")
        let bookmark = try XCTUnwrap(AppEngine.makeBookmark(movieURL))
        let source = PersistedSource(kind: .movie, name: "clip", bookmark: bookmark, loop: true)

        let decoded = try roundTrip([source])[0]
        let plans = PersistedSource.plan(from: [decoded], availableDeviceIDs: [])
        guard case .restore(.movie(let url, let loop)) = plans[0].outcome else {
            return XCTFail("a movie whose file exists must plan as restorable, got \(plans[0].outcome)")
        }
        XCTAssertTrue(samePath(url, movieURL), "the resolved URL must point back at the same file")
        XCTAssertTrue(loop, "the loop flag must flow through the plan")
    }

    // 3. Graceful degradation — absent device / deleted file -----------------

    func testAbsentCameraIsKeptNotDropped() {
        let present = PersistedSource(kind: .camera, name: "USB Cam", deviceID: "present-uid")
        let absent = PersistedSource(kind: .camera, name: "Unplugged Cam", deviceID: "gone-uid")

        let plans = PersistedSource.plan(from: [present, absent],
                                         availableDeviceIDs: ["present-uid"])

        guard case .restore(.camera(let id)) = plans[0].outcome else {
            return XCTFail("a present camera must be restorable")
        }
        XCTAssertEqual(id, "present-uid")

        guard case .unavailable = plans[1].outcome else {
            return XCTFail("an absent camera must be KEPT (unavailable), never dropped or crashed")
        }
        // The entry itself is retained intact so it can reappear when the device returns.
        XCTAssertEqual(plans[1].source, absent)
    }

    func testDeletedFileBookmarkIsKeptNotCrash() throws {
        let url = try makeTempFile(ext: "mov")
        let bookmark = try XCTUnwrap(AppEngine.makeBookmark(url))
        // Delete the file AFTER bookmarking — the stale-bookmark case.
        try FileManager.default.removeItem(at: url)

        let source = PersistedSource(kind: .movie, name: "gone clip", bookmark: bookmark, loop: true)
        let decoded = try roundTrip([source])[0] // must still DECODE fine
        let plans = PersistedSource.plan(from: [decoded], availableDeviceIDs: [])

        guard case .unavailable = plans[0].outcome else {
            return XCTFail("a deleted-file bookmark must plan as unavailable, not throw/crash")
        }
        XCTAssertEqual(plans[0].source, decoded, "the entry is kept intact for a later reappearance")
    }

    /// A source with no usable identity (a camera with no device id) degrades
    /// rather than force-unwrapping.
    func testMissingIdentityDegrades() {
        let noID = PersistedSource(kind: .camera, name: "mystery", deviceID: nil)
        let plans = PersistedSource.plan(from: [noID], availableDeviceIDs: [])
        guard case .unavailable = plans[0].outcome else {
            return XCTFail("a camera with no device id must degrade, never crash")
        }
    }

    /// A screen (inherently ephemeral) with an id plans for a best-effort restore
    /// with its kind + captureAudio preserved; the addScreen path itself degrades
    /// if the display is gone.
    func testScreenBestEffortRestore() {
        let screen = PersistedSource(kind: .screen, name: "Display 1", deviceID: "disp-1",
                                     screenKind: SourceKind.display.rawValue, captureAudio: true)
        let plans = PersistedSource.plan(from: [screen], availableDeviceIDs: [])
        guard case .restore(.screen(let id, let kind, let captureAudio)) = plans[0].outcome else {
            return XCTFail("a screen with an id should attempt a best-effort restore")
        }
        XCTAssertEqual(id, "disp-1")
        XCTAssertEqual(kind, .display)
        XCTAssertTrue(captureAudio)
    }
}
