import XCTest
@testable import PrismLink
@testable import PrismLinkSender

/// THE BUGS: two remote-DoS clock-arithmetic traps a spoof LAN server / paired
/// peer could fire to CRASH the phone or the Mac.
///
///  1. HIGH — `DeviceClockSync.ingest` did trapping Int64 math
///     (`(t4 - t1) - (t3 - t2)`, `((t2 - t1) + (t3 - t4)) / 2`) on fully
///     attacker-controlled pong fields, reached PRE-AUTH via the clock-sync
///     burst a first-contact (TOFU) server can drive. One crafted `clockPong`
///     (t1 = Int64.min, or t2 = t3 = Int64.max) overflowed → trap → the phone
///     crashed while merely trying to pair.
///
///  2. MEDIUM — `ClockSkewEstimator` trapped on unbounded LinkStats clock
///     fields: `Double($0.deviceNanos - x0)` overflowed Int64 and
///     `Int64(predicted.rounded())` trapped on out-of-range/NaN. A paired peer
///     sending deviceClockNanos = +5e18 then −5e18 crashed the Mac.
///
/// THE FIX: overflow-checked arithmetic that REJECTS (never traps), magnitude
/// validation, and — for the pong path — seq/t1 correlation so an
/// unsolicited/spoofed pong is dropped before any math runs. These tests feed
/// the exact malicious inputs the hunt reproduced and assert no crash + the
/// sample is rejected, and that legitimate input is unchanged.
final class ClockSyncDoSTests: XCTestCase {

    // MARK: Finding 1 — crafted clockPong must be rejected, never trap

    /// The headline crash: t1 = Int64.min makes `t4 - t1` overflow.
    func testCraftedPong_t1IntMin_isRejectedNotTrapped() {
        var sync = DeviceClockSync()
        // Correlate so we isolate the ARITHMETIC defense (not just correlation).
        sync.registerPing(seq: 1, t1: .min)
        let accepted = sync.ingest(
            pong: LinkClockPong(seq: 1, t1: .min, t2: .max, t3: .max),
            receivedAtDeviceNanos: 0)
        XCTAssertFalse(accepted, "crafted t1=Int64.min pong must be rejected")
        XCTAssertEqual(sync.acceptedSamples, 0)
        XCTAssertEqual(sync.rejectedSamples, 1)
    }

    /// The other reported variant: t2 = t3 = Int64.max overflows the offset sum.
    func testCraftedPong_t2t3IntMax_isRejectedNotTrapped() {
        var sync = DeviceClockSync()
        sync.registerPing(seq: 7, t1: 0)
        let accepted = sync.ingest(
            pong: LinkClockPong(seq: 7, t1: 0, t2: .max, t3: .max),
            receivedAtDeviceNanos: 0)
        XCTAssertFalse(accepted, "crafted t2=t3=Int64.max pong must be rejected")
        XCTAssertEqual(sync.acceptedSamples, 0)
    }

    /// A sweep of boundary values that would overflow one intermediate or
    /// another — none may trap, all must be rejected.
    func testCraftedPong_overflowSweep_neverTraps() {
        let extremes: [Int64] = [.min, .max, .min + 1, .max - 1, 0]
        for t1 in extremes {
            for t2 in extremes {
                for t3 in extremes {
                    for t4 in extremes {
                        var sync = DeviceClockSync()
                        sync.registerPing(seq: 3, t1: t1)
                        // Must return (not crash) for every combination.
                        _ = sync.ingest(pong: LinkClockPong(seq: 3, t1: t1, t2: t2, t3: t3),
                                        receivedAtDeviceNanos: t4)
                    }
                }
            }
        }
    }

    // MARK: Finding 1 — seq/t1 correlation drops unsolicited pongs

    func testUnsolicitedPong_droppedWhenNoPingSent() {
        var sync = DeviceClockSync()
        // No registerPing — a well-formed pong with no matching outstanding
        // ping is an injection and must be dropped.
        let accepted = sync.ingest(
            pong: LinkClockPong(seq: 1, t1: 1_000, t2: 1_100, t3: 1_200),
            receivedAtDeviceNanos: 1_400)
        XCTAssertFalse(accepted, "unsolicited pong must be dropped")
        XCTAssertEqual(sync.acceptedSamples, 0)
        XCTAssertEqual(sync.rejectedSamples, 1)
    }

    func testSeqMismatchedPong_dropped() {
        var sync = DeviceClockSync()
        sync.registerPing(seq: 5, t1: 1_000)
        // Same-shape pong but WRONG seq → dropped.
        let wrongSeq = sync.ingest(
            pong: LinkClockPong(seq: 6, t1: 1_000, t2: 1_100, t3: 1_200),
            receivedAtDeviceNanos: 1_400)
        XCTAssertFalse(wrongSeq, "seq-mismatched pong must be dropped")
        // Right seq but WRONG echoed t1 → also dropped.
        let wrongT1 = sync.ingest(
            pong: LinkClockPong(seq: 5, t1: 999, t2: 1_100, t3: 1_200),
            receivedAtDeviceNanos: 1_400)
        XCTAssertFalse(wrongT1, "t1-mismatched pong must be dropped")
        XCTAssertEqual(sync.acceptedSamples, 0)
    }

    func testReplayedPong_droppedAfterFirstAccept() {
        var sync = DeviceClockSync()
        sync.registerPing(seq: 5, t1: 1_000)
        let pong = LinkClockPong(seq: 5, t1: 1_000, t2: 1_100, t3: 1_200)
        XCTAssertTrue(sync.ingest(pong: pong, receivedAtDeviceNanos: 1_400),
                      "first correlated pong should be accepted")
        // The outstanding record was consumed → a replay of the same pong drops.
        XCTAssertFalse(sync.ingest(pong: pong, receivedAtDeviceNanos: 1_400),
                       "replayed pong must be dropped")
        XCTAssertEqual(sync.acceptedSamples, 1)
    }

    // MARK: Finding 1 — legitimate input unchanged (accuracy preserved)

    /// Reproduces the self-test's legitimate scenario and asserts the offset
    /// estimate matches the true offset to sub-millisecond — the fix must not
    /// change accuracy for honest input.
    func testLegitimatePongs_accuracyPreserved() {
        var sync = DeviceClockSync()
        let o0: Int64 = 5_000_000_000_000
        let skewPPM = 20.0
        func trueOffset(atDevice m: Int64) -> Int64 { o0 + Int64(Double(m) * skewPPM / 1e6) }
        func houseAt(device m: Int64) -> Int64 { m + trueOffset(atDevice: m) }

        var device: Int64 = 1_000_000_000_000
        var lastT4 = device
        for i in 0..<32 {
            let t1 = device
            let uplink = Int64(1_500_000 + (i % 5) * 100_000)
            let downlink = Int64(1_500_000 + ((i + 2) % 5) * 100_000)
            let processing: Int64 = 200_000
            let arriveDevice = t1 + uplink
            let t2 = houseAt(device: arriveDevice)
            let t3 = t2 + processing
            let t4 = arriveDevice + processing + downlink
            sync.registerPing(seq: UInt32(i), t1: t1)
            XCTAssertTrue(sync.ingest(pong: LinkClockPong(seq: UInt32(i), t1: t1, t2: t2, t3: t3),
                                      receivedAtDeviceNanos: t4),
                          "legitimate pong \(i) should be accepted")
            lastT4 = t4
            device += 2_000_000_000
        }
        guard let est = sync.estimate() else { return XCTFail("no estimate after 32 samples") }
        XCTAssertLessThan(abs(est.offsetNanos - trueOffset(atDevice: lastT4)), 1_000_000,
                          "offset error ≥ 1 ms — accuracy regressed")
        XCTAssertLessThan(abs(est.skewPPM - skewPPM), 10, "skew estimate off by > 10 ppm")
    }

    // MARK: Finding 2 — poisoned LinkStats clock fields must not trap

    /// The reported Mac crash: deviceClockNanos = +5e18 then −5e18 overflowed
    /// the regression's Int64 subtraction. The estimator must clamp/reject and
    /// never trap when the estimate is read.
    func testPoisonedStats_isRejected_estimateDoesNotTrap() {
        var est = ClockSkewEstimator(window: 64)
        est.add(deviceNanos: 5_000_000_000_000_000_000, offsetNanos: 0)   // +5e18
        est.add(deviceNanos: -5_000_000_000_000_000_000, offsetNanos: 0)  // −5e18
        // Both poisoned samples are out of the plausibility fence → dropped.
        XCTAssertEqual(est.sampleCount, 0, "poisoned samples must not enter the window")
        // Reading the estimate must not trap (nil is fine — no samples).
        XCTAssertNil(est.estimate())
    }

    /// Even if extreme values somehow reached `estimate()`, the Double→Int64
    /// conversion must be guarded. Drive a fit whose prediction is huge and
    /// assert no trap.
    func testEstimate_extremeExtrapolation_doesNotTrap() {
        var est = ClockSkewEstimator(window: 64)
        // Two in-range samples with a steep slope.
        est.add(deviceNanos: 0, offsetNanos: 0)
        est.add(deviceNanos: 1_000_000, offsetNanos: 1_000_000_000_000_000)
        // Extrapolate absurdly far in device time → predicted offset explodes.
        let e = est.estimate(atDeviceNanos: 4_000_000_000_000_000_000)
        XCTAssertNotNil(e, "estimate must return (clamped), not trap")
    }

    /// Legitimate stats produce the same fit as before the fix.
    func testLegitimateStats_fitUnchanged() {
        var est = ClockSkewEstimator(window: 64)
        let x0: Int64 = 1_700_000_000_000_000_000 // ~2023 wall-clock nanos, in range
        for i in 0..<10 {
            let dev = x0 + Int64(i) * 1_000_000_000
            est.add(deviceNanos: dev, offsetNanos: 5_000_000_000 + Int64(i) * 2_000) // +2 ns/s drift
        }
        guard let e = est.estimate() else { return XCTFail("no estimate for legit stats") }
        XCTAssertEqual(e.sampleCount, 10)
        // Offset at the newest sample ≈ 5e9 + 9*2000.
        XCTAssertEqual(e.offsetNanos, 5_000_000_000 + 9 * 2_000, accuracy: 100)
    }
}
