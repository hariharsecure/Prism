import Foundation
import XCTest
@testable import PrismControlSurface

/// Cheap-hardening: a `switchScene(index:)` binding imported from an untrusted
/// persisted MIDI map must be bounds-checked before it can index the scene list.
/// A NEGATIVE index would crash the app the instant it is applied, so such a
/// binding is dropped at import (the upper bound is the consumer's job — only it
/// knows the live scene count).
final class MIDIImportBoundsTests: XCTestCase {

    private func mapping(_ actions: [(MIDITrigger, SurfaceAction)]) -> SurfaceMapping {
        SurfaceMapping(version: 1, bindings: actions.map { SurfaceMapping.Binding(trigger: $0.0, action: $0.1) })
    }

    /// REPRODUCE: a persisted map carrying `switchScene(index: -3)`. Post-fix the
    /// negative binding is discarded; the valid ones survive.
    func testNegativeSwitchSceneIndexDroppedOnImport() throws {
        let m = mapping([
            (.note(note: 60, channel: 0), .switchScene(index: -3)),   // invalid → dropped
            (.note(note: 61, channel: 0), .switchScene(index: 0)),    // valid
            (.note(note: 62, channel: 0), .switchScene(index: 5)),    // valid
            (.cc(cc: 7, channel: 0), .startStream),                   // valid non-scene
        ])
        let map = MIDIActionMap(m)
        XCTAssertNil(map.bindings[.note(note: 60, channel: 0)], "negative-index binding must be dropped")
        XCTAssertEqual(map.bindings[.note(note: 61, channel: 0)], .switchScene(index: 0))
        XCTAssertEqual(map.bindings[.note(note: 62, channel: 0)], .switchScene(index: 5))
        XCTAssertEqual(map.bindings[.cc(cc: 7, channel: 0)], .startStream)
    }

    /// The same guard applies through the JSON decode path (`loadMapping`).
    func testNegativeIndexDroppedThroughJSONDecode() throws {
        let data = try JSONEncoder().encode(mapping([
            (.note(note: 40, channel: 1), .switchScene(index: -1)),
            (.note(note: 41, channel: 1), .switchScene(index: 3)),
        ]))
        let map = try MIDIActionMap(jsonData: data)
        XCTAssertNil(map.bindings[.note(note: 40, channel: 1)])
        XCTAssertEqual(map.bindings[.note(note: 41, channel: 1)], .switchScene(index: 3))
    }

    /// NEGATIVE CONTROL: a valid all-nonnegative map imports unchanged.
    func testValidMapImportsUnchanged() {
        let m = mapping([
            (.note(note: 60, channel: 0), .switchScene(index: 0)),
            (.note(note: 61, channel: 0), .switchScene(index: 12)),
            (.programChange(program: 3, channel: 2), .saveReplay),
        ])
        let map = MIDIActionMap(m)
        XCTAssertEqual(map.bindings.count, 3)
    }
}
