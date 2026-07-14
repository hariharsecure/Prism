import Foundation
import XCTest

import PrismCompositor
import PrismCore

/// HIGH (sol-verify): the vertical repeated-insert CRASH. Triggering the SAME
/// insert twice within its hold made `MemeDirector.program` emit TWO layers with
/// the same `sourceID`; the app's vertical tap then builds a `Dictionary` keyed on
/// `sourceID` and `Dictionary(uniqueKeysWithValues:)` TRAPS on the duplicate key.
///
/// Independent oracle: inspect the actual emitted program layers — the fix makes a
/// re-trigger UPDATE the one active entry, so exactly one layer carries the meme's
/// sourceID (and a duplicate-keyed dict build over the layers cannot trap).
final class MemeDirectorDedupeTests: XCTestCase {

    func testDoubleTriggerSameInsertEmitsExactlyOneLayer() {
        let director = MemeDirector()
        let memeID = SourceID("meme.dup")
        let base = Scene(name: "base", layers: [Layer(sourceID: SourceID("cam"), zIndex: 0)])
        let item = MemeItem(name: "dup", mediaURL: URL(fileURLWithPath: "/dev/null"),
                            sourceID: memeID, mode: .insert, holdSec: 3,
                            placement: .corner(.topRight))

        director.trigger(item, at: 0.0)
        director.trigger(item, at: 0.5)                 // re-trigger INSIDE the hold

        let scene = director.program(at: 1.0, base: base)
        let memeLayers = scene.layers.filter { $0.sourceID == memeID }
        XCTAssertEqual(memeLayers.count, 1,
                       "re-trigger emitted a DUPLICATE layer for one sourceID (pre-fix = 2) — the app vertical-tap dict traps on this")

        // The exact op the app performs on the evaluated layers must not trap.
        let ids = scene.layers.map(\.sourceID)
        XCTAssertEqual(Set(ids).count, ids.count,
                       "program carried duplicate-keyed layers — Dictionary(uniqueKeysWithValues:) would crash")
    }

    /// The re-trigger EXTENDS the hold (updates the active entry's start) rather
    /// than being ignored: still live well past the first trigger's own expiry.
    func testReTriggerExtendsHold() {
        let director = MemeDirector()
        let memeID = SourceID("meme.extend")
        let base = Scene(name: "base", layers: [Layer(sourceID: SourceID("cam"), zIndex: 0)])
        let item = MemeItem(name: "extend", mediaURL: URL(fileURLWithPath: "/dev/null"),
                            sourceID: memeID, mode: .insert, holdSec: 1.0,
                            placement: .lowerThird)
        director.trigger(item, at: 0.0)
        director.trigger(item, at: 0.9)                 // refresh near end of first hold
        // At t=1.5 the FIRST hold (0…1.0) would have expired, but the refreshed
        // one (0.9…1.9) is still live → the meme layer is present.
        let scene = director.program(at: 1.5, base: base)
        XCTAssertTrue(scene.layers.contains { $0.sourceID == memeID },
                      "re-trigger did not refresh the hold")
    }
}
