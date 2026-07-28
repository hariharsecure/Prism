import PrismCore
import XCTest

/// Deterministic verification of the G1 v1a MemoryGovernor engine core.
///
/// The governor is a PURE decision machine — `physicalRAM` and the clock are
/// injected — so every case below is exact and reproducible: same inputs → same
/// decision, no wall-clock/RNG anywhere. These tests are the bulk of v1a's value
/// (the numbers must be trustworthy before v1b wires anything to them).
final class MemoryGovernorTests: XCTestCase {

    private let KiB: Int64 = 1024
    private let MiB: Int64 = 1024 * 1024
    private let GiB: Int64 = 1024 * 1024 * 1024

    // MARK: - Ladder shape (data-driven correctness)

    func testLadderIsCompleteAndOrdered() {
        // Every case appears exactly once in the ladder.
        XCTAssertEqual(Set(LoadClass.ladder), Set(LoadClass.allCases))
        XCTAssertEqual(LoadClass.ladder.count, LoadClass.allCases.count)

        // shedOrder is the ladder index, strictly ascending.
        for (i, c) in LoadClass.ladder.enumerated() {
            XCTAssertEqual(c.shedOrder, i)
        }

        // Bands: first 3 are caches, last 4 are sacrosanct, middle 4 commitments.
        XCTAssertEqual(LoadClass.cacheClasses, [.memeCache, .previewQuality, .idleSourcePool])
        XCTAssertTrue([LoadClass.streamEncode, .programRecord, .audioEngine, .compositor].allSatisfy { $0.isSacrosanct })
        XCTAssertTrue([LoadClass.replayBuffer, .isoAngle, .liveEffectQuality, .sourceCaptureRes].allSatisfy { $0.isCommitment })
        // A class is exactly one band.
        for c in LoadClass.allCases {
            let bands = [c.isCache, c.isCommitment, c.isSacrosanct].filter { $0 }
            XCTAssertEqual(bands.count, 1, "\(c) must be exactly one band")
        }
        // Sacrosanct classes sit above every non-sacrosanct one.
        let maxNonSacro = LoadClass.allCases.filter { !$0.isSacrosanct }.map(\.shedOrder).max()!
        let minSacro = LoadClass.allCases.filter { $0.isSacrosanct }.map(\.shedOrder).min()!
        XCTAssertGreaterThan(minSacro, maxNonSacro)
    }

    // MARK: - Budget math

    func testBudget8GiBGivesFourGiBTotal() {
        let b = MemoryGovernor.computeBudget(physicalRAM: 8 * GiB)
        XCTAssertEqual(b.total, 4 * GiB)                  // 8 GiB * 0.5
        XCTAssertEqual(b.softLimit, (4 * GiB) * 80 / 100) // 80%
        XCTAssertEqual(b.hardLimit, (4 * GiB) * 95 / 100) // 95%
        XCTAssertLessThan(b.softLimit, b.hardLimit)
    }

    func testBudget128GiBGivesSixtyFourGiBTotal() {
        let b = MemoryGovernor.computeBudget(physicalRAM: 128 * GiB)
        XCTAssertEqual(b.total, 64 * GiB)
    }

    func testBudgetFloorHoldsAtFourGiBForSmallRAM() {
        // 6 GiB * 0.5 = 3 GiB < 4 GiB floor → clamps up to 4 GiB.
        XCTAssertEqual(MemoryGovernor.computeBudget(physicalRAM: 6 * GiB).total, 4 * GiB)
        // Degenerate/zero RAM still floors at 4 GiB.
        XCTAssertEqual(MemoryGovernor.computeBudget(physicalRAM: 0).total, 4 * GiB)
    }

    func testBudgetOverrideFractionClamps() {
        // Below-range fraction clamps to 0.25.
        let low = MemoryGovernor.computeBudget(physicalRAM: 128 * GiB, fraction: 0.01)
        XCTAssertEqual(low.total, Int64(Double(128 * GiB) * 0.25))
        // Above-range fraction clamps to 0.9.
        let high = MemoryGovernor.computeBudget(physicalRAM: 128 * GiB, fraction: 5.0)
        XCTAssertEqual(high.total, Int64(Double(128 * GiB) * 0.9))
        // In-range fraction is honored.
        let mid = MemoryGovernor.computeBudget(physicalRAM: 128 * GiB, fraction: 0.5)
        XCTAssertEqual(mid.total, 64 * GiB)
    }

    // MARK: - Cost model

    func testReplayCostFollowsDurationTimesBitrate() {
        // 60 s * 8 Mbps / 8 = 60,000,000 B, + 5% keyframe/index headroom.
        let raw: Int64 = 60 * 8_000_000 / 8
        let expected = raw + raw * 5 / 100
        XCTAssertEqual(MemoryCostModel.estimateWorstCase(for: .enableReplay(durationSec: 60, bitrate: 8_000_000)), expected)
        // Degenerate inputs cost nothing (guarded).
        XCTAssertEqual(MemoryCostModel.estimateWorstCase(for: .enableReplay(durationSec: 0, bitrate: 8_000_000)), 0)
        XCTAssertEqual(MemoryCostModel.estimateWorstCase(for: .enableReplay(durationSec: 60, bitrate: 0)), 0)
    }

    func testSourceCostRisesWithEffectsAndResolution() {
        let noFX = MemoryCostModel.estimateWorstCase(for: .addSource(resolution: .uhd4k, effectsEnabled: false))
        let withFX = MemoryCostModel.estimateWorstCase(for: .addSource(resolution: .uhd4k, effectsEnabled: true))
        XCTAssertGreaterThan(withFX, noFX)                 // effects add the effect pool
        // Base pool = 4 buffers * 4K BGRA frame.
        XCTAssertEqual(noFX, 4 * (3840 * 2160 * 4))
        // A 4K source costs strictly more than a 1080p one.
        let hd = MemoryCostModel.estimateWorstCase(for: .addSource(resolution: .hd1080, effectsEnabled: true))
        XCTAssertGreaterThan(withFX, hd)
    }

    // MARK: - Admission: the three outcomes

    func testAdmitUnderSoftLimit() {
        // 128 GiB → 64 GiB total, soft ≈ 51 GiB. A 1 GiB base + 1 GiB add fits.
        let snap: [LoadClass: Int64] = [.compositor: 1 * GiB]
        let req = AdmissionRequest(loadClass: .isoAngle, worstCaseBytes: 1 * GiB)
        XCTAssertEqual(MemoryGovernor.admit(request: req, snapshot: snap, physicalRAM: 128 * GiB), .admit)
    }

    func testAdmitOnlyAfterReclaimingCaches() {
        // 8 GiB → 4 GiB total, soft = 4 GiB*0.8. 2 GiB cache + 1 GiB commitment,
        // add 512 MiB: over soft, but dropping the 2 GiB cache brings it under.
        let snap: [LoadClass: Int64] = [.memeCache: 2 * GiB, .replayBuffer: 1 * GiB]
        let req = AdmissionRequest(loadClass: .isoAngle, worstCaseBytes: 512 * MiB)
        let decision = MemoryGovernor.admit(request: req, snapshot: snap, physicalRAM: 8 * GiB)
        XCTAssertEqual(decision, .admitAfterReclaimingCaches(reclaimBytes: 2 * GiB))
    }

    func testRefuseReportsGapProtectingAndRemedy() {
        let ram = 8 * GiB
        let budget = MemoryGovernor.computeBudget(physicalRAM: ram)
        let snap: [LoadClass: Int64] = [
            .memeCache: 100 * MiB,        // the only reclaimable bytes
            .replayBuffer: 1536 * MiB,    // 1.5 GiB commitment
            .isoAngle: 1 * GiB,
            .sourceCaptureRes: 512 * MiB,
            .streamEncode: 200 * MiB,     // sacrosanct, present
        ]
        let addBytes: Int64 = 512 * MiB
        let req = AdmissionRequest(loadClass: .programRecord, worstCaseBytes: addBytes)
        let decision = MemoryGovernor.admit(request: req, snapshot: snap, physicalRAM: ram)

        guard case let .refuse(gapBytes, protecting, remedy) = decision else {
            return XCTFail("expected .refuse, got \(decision)")
        }

        // gap = projected - reclaimableCaches - softLimit.
        let currentTotal = snap.values.reduce(0, +)
        let projected = currentTotal + addBytes
        let reclaimable = snap[.memeCache]!
        XCTAssertEqual(gapBytes, projected - reclaimable - budget.softLimit)
        XCTAssertGreaterThan(gapBytes, 0)

        // protecting lists exactly the resident commitment/sacrosanct classes, in
        // shed order, and never a cache.
        XCTAssertEqual(protecting, [.replayBuffer, .isoAngle, .sourceCaptureRes, .streamEncode])
        XCTAssertTrue(protecting.contains(.streamEncode))       // a sacrosanct class is protected
        XCTAssertFalse(protecting.contains { $0.isCache })

        // remedy names a real, non-sacrosanct reclaim with a plausible estimate.
        XCTAssertEqual(remedy.targetClass, .replayBuffer)
        XCTAssertFalse(remedy.targetClass.isSacrosanct)
        XCTAssertGreaterThan(remedy.estimatedFreedBytes, 0)
        XCTAssertLessThanOrEqual(remedy.estimatedFreedBytes, snap[.replayBuffer]!)
        XCTAssertTrue(remedy.message.lowercased().contains("replay"))
    }

    func testRefuseRemedyFallsBackToISOWhenNoReplay() {
        let ram = 8 * GiB
        let snap: [LoadClass: Int64] = [
            .isoAngle: 3 * GiB,
            .sourceCaptureRes: 1 * GiB,
        ]
        let req = AdmissionRequest(loadClass: .programRecord, worstCaseBytes: 1 * GiB)
        guard case let .refuse(_, _, remedy) = MemoryGovernor.admit(request: req, snapshot: snap, physicalRAM: ram) else {
            return XCTFail("expected .refuse")
        }
        XCTAssertEqual(remedy.targetClass, .isoAngle)
        XCTAssertEqual(remedy.estimatedFreedBytes, 3 * GiB)
    }

    // MARK: - Degrade: rung order + never-sacrosanct

    func testDegradeWarningSheddsMemeThenReplayInOrder() {
        let ram = 8 * GiB
        let snap: [LoadClass: Int64] = [
            .memeCache: 1 * GiB,        // fat meme cache
            .replayBuffer: 1 * GiB,     // long replay
            .streamEncode: 200 * MiB,   // sacrosanct — must be untouched
        ]
        let actions = MemoryGovernor.degrade(pressure: .warning, snapshot: snap, physicalRAM: ram)
        XCTAssertEqual(actions, [.shrinkMemeCache(toBytes: 256 * MiB), .shrinkReplay(toSeconds: 30)])
        // rung 1 (memeCache) strictly before rung 4 (replayBuffer).
        XCTAssertLessThan(actions[0].loadClass.shedOrder, actions[1].loadClass.shedOrder)
        // Never a sacrosanct action.
        XCTAssertFalse(actions.contains { $0.loadClass.isSacrosanct })
    }

    func testDegradeCriticalSuspendsReplayAndDropsMemeToFloor() {
        let ram = 8 * GiB
        let snap: [LoadClass: Int64] = [.memeCache: 1 * GiB, .replayBuffer: 1 * GiB]
        let actions = MemoryGovernor.degrade(pressure: .critical, snapshot: snap, physicalRAM: ram)
        XCTAssertEqual(actions, [.shrinkMemeCache(toBytes: 64 * MiB), .suspendReplay])
    }

    func testDegradeNormalPressureBelowHardLimitDoesNothing() {
        let ram = 8 * GiB
        let snap: [LoadClass: Int64] = [.memeCache: 1 * GiB, .replayBuffer: 1 * GiB]
        XCTAssertEqual(MemoryGovernor.degrade(pressure: .normal, snapshot: snap, physicalRAM: ram), [])
    }

    func testDegradeTriggersAtHardLimitEvenUnderNormalPressure() {
        let ram = 8 * GiB
        let hard = MemoryGovernor.computeBudget(physicalRAM: ram).hardLimit
        // Push total over the hard limit mostly via a sacrosanct class.
        let snap: [LoadClass: Int64] = [
            .memeCache: 1 * GiB,
            .replayBuffer: 512 * MiB,
            .streamEncode: hard,      // dominates → total ≥ hardLimit
        ]
        let actions = MemoryGovernor.degrade(pressure: .normal, snapshot: snap, physicalRAM: ram)
        // Over hard limit is treated as critical.
        XCTAssertEqual(actions, [.shrinkMemeCache(toBytes: 64 * MiB), .suspendReplay])
        XCTAssertFalse(actions.contains { $0.loadClass.isSacrosanct })
    }

    func testDegradeSkipsRungsAlreadyBelowFloor() {
        let ram = 8 * GiB
        // meme already under warning floor, no replay → nothing to shed.
        let snap: [LoadClass: Int64] = [.memeCache: 10 * MiB]
        XCTAssertEqual(MemoryGovernor.degrade(pressure: .warning, snapshot: snap, physicalRAM: ram), [])
    }

    // MARK: - Hysteresis

    func testCanRestoreOnlyBelowEightyFivePercentOfSoft() {
        let ram = 8 * GiB
        let soft = MemoryGovernor.computeBudget(physicalRAM: ram).softLimit
        let threshold = Int64(Double(soft) * 0.85)
        // At/above threshold → no restore (prevents flapping).
        XCTAssertFalse(MemoryGovernor.canRestore(currentTotal: threshold, physicalRAM: ram))
        XCTAssertFalse(MemoryGovernor.canRestore(currentTotal: soft, physicalRAM: ram))
        // Below threshold → restore allowed.
        XCTAssertTrue(MemoryGovernor.canRestore(currentTotal: threshold - 1, physicalRAM: ram))
    }

    func testInstanceHysteresisAcrossLedgerChanges() {
        let ram = 8 * GiB
        let soft = MemoryGovernor.computeBudget(physicalRAM: ram).softLimit
        let gov = MemoryGovernor(physicalRAM: ram)
        // Under pressure (total near soft) → cannot restore yet.
        gov.ledger.register(ResourceAccount(id: "meme", loadClass: .memeCache, residentBytes: soft))
        XCTAssertFalse(gov.canRestore())
        // Pressure relieved (total well below the 85% band) → restore allowed.
        gov.ledger.update(id: "meme", residentBytes: soft / 2)
        XCTAssertTrue(gov.canRestore())
    }

    // MARK: - Invariant: no path ever reduces a sacrosanct class

    func testNoDegradePathEverProposesSacrosanctReduction() {
        let ram = 8 * GiB
        // Sweep a deterministic grid of snapshots × pressures.
        let byteLevels: [Int64] = [0, 32 * MiB, 512 * MiB, 2 * GiB, 8 * GiB]
        for pressure in [PressureLevel.normal, .warning, .critical] {
            for meme in byteLevels {
                for replay in byteLevels {
                    for sacro in byteLevels {
                        let snap: [LoadClass: Int64] = [
                            .memeCache: meme,
                            .replayBuffer: replay,
                            .streamEncode: sacro,
                            .programRecord: sacro,
                            .audioEngine: sacro,
                            .compositor: sacro,
                        ]
                        let actions = MemoryGovernor.degrade(pressure: pressure, snapshot: snap, physicalRAM: ram)
                        for a in actions {
                            XCTAssertFalse(a.loadClass.isSacrosanct, "degrade proposed sacrosanct \(a)")
                            XCTAssertTrue(a.loadClass == .memeCache || a.loadClass == .replayBuffer,
                                          "v1a must only touch rung 1 / rung 4, got \(a)")
                        }
                    }
                }
            }
        }
    }

    func testNoAdmissionRemedyEverTargetsSacrosanct() {
        let ram = 8 * GiB
        let byteLevels: [Int64] = [0, 256 * MiB, 2 * GiB]
        for replay in byteLevels {
            for iso in byteLevels {
                for source in byteLevels {
                    for sacro in byteLevels {
                        let snap: [LoadClass: Int64] = [
                            .replayBuffer: replay, .isoAngle: iso,
                            .sourceCaptureRes: source, .streamEncode: sacro,
                        ]
                        let req = AdmissionRequest(loadClass: .programRecord, worstCaseBytes: 8 * GiB)
                        if case let .refuse(_, protecting, remedy) = MemoryGovernor.admit(request: req, snapshot: snap, physicalRAM: ram) {
                            XCTAssertFalse(remedy.targetClass.isSacrosanct)
                            // protecting may include sacrosanct (they ARE protected) but never a cache.
                            XCTAssertFalse(protecting.contains { $0.isCache })
                        }
                    }
                }
            }
        }
    }

    // MARK: - Determinism

    func testSameInputsYieldSameDecisions() {
        let ram = 8 * GiB
        let snap: [LoadClass: Int64] = [.memeCache: 2 * GiB, .replayBuffer: 1 * GiB]
        let req = AdmissionRequest(kind: .startProgramRecord(resolution: .uhd4k))

        let a1 = MemoryGovernor.admit(request: req, snapshot: snap, physicalRAM: ram)
        let a2 = MemoryGovernor.admit(request: req, snapshot: snap, physicalRAM: ram)
        XCTAssertEqual(a1, a2)

        let d1 = MemoryGovernor.degrade(pressure: .warning, snapshot: snap, physicalRAM: ram)
        let d2 = MemoryGovernor.degrade(pressure: .warning, snapshot: snap, physicalRAM: ram)
        XCTAssertEqual(d1, d2)
    }

    // MARK: - Ledger + event log (stateful glue)

    func testLedgerAccountsRollUpByClass() {
        let ledger = MemoryLedger()
        ledger.register(ResourceAccount(id: "a", loadClass: .memeCache, residentBytes: 100 * MiB))
        ledger.register(ResourceAccount(id: "b", loadClass: .memeCache, residentBytes: 50 * MiB))
        ledger.register(ResourceAccount(id: "c", loadClass: .replayBuffer, residentBytes: 1 * GiB))
        XCTAssertEqual(ledger.bytes(by: .memeCache), 150 * MiB)
        XCTAssertEqual(ledger.totalBytes, 150 * MiB + 1 * GiB)

        ledger.update(id: "a", residentBytes: 200 * MiB)
        XCTAssertEqual(ledger.bytes(by: .memeCache), 250 * MiB)

        ledger.release(id: "c")
        XCTAssertEqual(ledger.totalBytes, 250 * MiB)
        XCTAssertEqual(ledger.snapshot()[.replayBuffer], nil)
    }

    func testDegradeAppendsTimestampedEventsWithInjectedClock() {
        let gov = MemoryGovernor(physicalRAM: 8 * GiB)
        gov.ledger.register(ResourceAccount(id: "meme", loadClass: .memeCache, residentBytes: 1 * GiB))
        gov.ledger.register(ResourceAccount(id: "replay", loadClass: .replayBuffer, residentBytes: 1 * GiB))

        let actions = gov.degrade(pressure: .warning, now: 42.0)
        XCTAssertEqual(actions.count, 2)

        let log = gov.degradeLog
        XCTAssertEqual(log.count, 2)
        XCTAssertTrue(log.allSatisfy { $0.timestamp == 42.0 })          // injected clock, no Date()
        XCTAssertTrue(log.allSatisfy { $0.freedBytes >= 0 })
        // meme shrink 1 GiB → 256 MiB frees 768 MiB.
        XCTAssertEqual(log[0].freedBytes, 1 * GiB - 256 * MiB)
        XCTAssertEqual(gov.shedClasses, [.memeCache, .replayBuffer])
    }

    func testInstanceAdmitUsesCostModelForKind() {
        let gov = MemoryGovernor(physicalRAM: 128 * GiB)
        // Empty ledger, generous budget → a 4K record admits.
        XCTAssertEqual(gov.admit(kind: .startProgramRecord(resolution: .uhd4k)), .admit)
    }
}
