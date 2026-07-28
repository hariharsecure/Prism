import CoreMedia
import CoreVideo
import Foundation
import XCTest

import PrismCore
import PrismOutput
@testable import Prism

/// G1 v1b-ENFORCE — the APP-side wiring of the MemoryGovernor: the hard-limit
/// admission refusal (refusable classes only), the sacrosanct never-refuse rule,
/// and the OS-pressure auto-degrade acting on the ACTUAL replay ring. The pure
/// decision math is covered by `MemoryGovernorTests`; these prove the App applies
/// it to real state. Enforcement is ON by default in the test process (the
/// PRISM_DISABLE_MEM_GOVERNOR kill-switch is not set).
@MainActor
final class MemoryGovernorEnforceAppTests: XCTestCase {

    /// Fill the live ledger to the hard limit with a synthetic sacrosanct account so
    /// any further add's projected total crosses it.
    private func fillToHardLimit(_ engine: AppEngine) {
        let hard = engine.memoryGovernor.budget.hardLimit
        engine.memoryGovernor.ledger.register(
            ResourceAccount(id: "test.fill", loadClass: .compositor, residentBytes: hard))
    }

    func testEnforcementOnByDefault() {
        XCTAssertTrue(AppEngine().memoryGovernorEnforcement,
                      "enforcement must default ON (kill-switch env not set)")
    }

    /// A refusable class (replay) is refused up-front at the hard limit: the ring is
    /// NOT armed and a Fable-framed lastError is surfaced.
    func testReplayArmRefusedAtHardLimit() {
        let engine = AppEngine()
        fillToHardLimit(engine)
        engine.setReplayArmed(true)
        XCTAssertFalse(engine.replayArmed, "replay must be refused at the hard limit")
        XCTAssertNotNil(engine.lastError)
        XCTAssertTrue(engine.lastError?.lowercased().contains("headroom") ?? false)
        XCTAssertEqual(engine.memoryHeadroomState, .critical)
    }

    /// The SAME hard-limit pressure must NOT refuse the sacrosanct program record or
    /// the live stream — they warn, never refuse.
    func testSacrosanctAddsNeverRefusedAtHardLimit() {
        let engine = AppEngine()
        fillToHardLimit(engine)
        let gov = engine.memoryGovernor
        XCTAssertEqual(gov.enforceAdmission(kind: .startProgramRecord(resolution: .hd1080),
                                            enforcementEnabled: true), .warn)
        XCTAssertEqual(gov.enforceAdmission(kind: .streamEncode(resolution: .hd1080, bitrate: 6_000_000),
                                            enforcementEnabled: true), .warn)
    }

    /// Below the hard limit but in the soft band, a refusable class is ALLOWED (warns,
    /// never refuses) — no false refusal from cost imprecision.
    func testSoftBandDoesNotRefuseReplay() {
        let engine = AppEngine()
        let soft = engine.memoryGovernor.budget.softLimit
        engine.memoryGovernor.ledger.register(
            ResourceAccount(id: "test.soft", loadClass: .compositor, residentBytes: soft))
        engine.lastError = nil
        engine.setReplayArmed(true)
        XCTAssertTrue(engine.replayArmed, "soft-band pressure must not refuse arming replay")
        XCTAssertTrue(engine.memoryWarning, "soft band must raise the passive warning")
    }

    /// OS-critical pressure suspends the ACTUAL replay ring (degrade acts on real bytes).
    func testCriticalPressureSuspendsActualReplay() {
        let engine = AppEngine()
        engine.setReplayArmed(true)
        XCTAssertTrue(engine.replayArmed)
        engine._test_handleMemoryPressure(.critical)
        XCTAssertFalse(engine.replayArmed, "critical pressure must suspend the actual replay ring")
        // The governor recorded a suspend event on the actual replay class.
        XCTAssertTrue(engine.recentDegradeEvents.contains { $0.action == .suspendReplay })
    }

    /// Hysteresis: a governor-suspended replay is NOT restored while the ledger is
    /// still above the restore band, and IS restored once it drops below.
    func testHysteresisGuardsReplayRestore() {
        let engine = AppEngine()
        engine.setReplayArmed(true)
        // Pin the total well above the restore band, then suspend under critical.
        let soft = engine.memoryGovernor.budget.softLimit
        engine.memoryGovernor.ledger.register(
            ResourceAccount(id: "test.pin", loadClass: .compositor, residentBytes: soft))
        engine._test_handleMemoryPressure(.critical)
        XCTAssertFalse(engine.replayArmed)
        // Still pinned high → a tick must NOT restore (no flapping).
        engine._test_governorTick()
        XCTAssertFalse(engine.replayArmed, "must not restore while above the hysteresis band")
        // Relieve the pressure → the tick restores the governor-suspended ring.
        engine.memoryGovernor.ledger.release(id: "test.pin")
        engine._test_governorTick()
        XCTAssertTrue(engine.replayArmed, "must restore once below the hysteresis band")
    }

    /// A normal single-source session on this machine has huge headroom → no refusal.
    func testNormalSessionNeverRefusesReplay() {
        let engine = AppEngine()
        engine.lastError = nil
        engine.setReplayArmed(true)
        XCTAssertTrue(engine.replayArmed)
        XCTAssertNil(engine.lastError)
        XCTAssertEqual(engine.memoryHeadroomState, .ok)
    }
}
