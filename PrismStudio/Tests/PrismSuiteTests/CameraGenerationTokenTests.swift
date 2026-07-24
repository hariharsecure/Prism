import XCTest
@testable import PrismCapture
import PrismCore

/// sol #16 — camera generation gating must stamp a frame with the generation it was
/// CAPTURED under, not the SUCCESSOR's token.
///
/// BUG: `start()` stored the run token in the SHARED `sessionGeneration`, and the
/// delegate READ that shared value when its callback executed. An old-run frame
/// queued behind a slow callback ran AFTER a stop→restart, read the freshly
/// re-stamped (successor) generation, and passed the gate → an old-frame flash.
///
/// FIX: each run installs a fresh delegate proxy carrying an IMMUTABLE
/// `CameraRunToken` captured at install time, so a straggler frame is validated
/// against its OWN (retired) run's generation and dropped.
///
/// Headless seam: `CameraSource` needs a real capture device, but the gating
/// DECISION is the pure `CameraRunToken` + `GenerationGate` interaction, exercised
/// here without any hardware.
final class CameraGenerationTokenTests: XCTestCase {

    /// Reproduce the exact "queued behind a slow callback, then stop→restart"
    /// sequence and prove the immutable token drops the old frame while the shared
    /// (pre-fix) read would have accepted it.
    func testOldRunFrameDroppedAfterRestart() {
        let gate = GenerationGate()

        // Run A armed at start(); its proxy captures A's immutable token.
        let genA = gate.bump()
        let tokenA = CameraRunToken(generation: genA, gate: gate)
        XCTAssertTrue(tokenA.isCurrent, "run A's own frames pass while A is live")

        // A frame from run A is captured and sits queued behind a slow callback…
        // …then stop() bumps the generation…
        gate.bump()
        // …and start() (run B) bumps again, re-arming the SHARED sessionGeneration
        // to B and installing a fresh proxy with B's immutable token.
        let genB = gate.bump()
        let sharedSessionGeneration = genB      // what the pre-fix delegate would re-read
        let tokenB = CameraRunToken(generation: genB, gate: gate)

        // FIX: the straggler frame validates against tokenA (the run it was captured
        // under) → dropped; run B's frames validate against tokenB → pass.
        XCTAssertFalse(tokenA.isCurrent,
                       "sol #16: an old-run frame must be dropped after stop→restart, not flashed")
        XCTAssertTrue(tokenB.isCurrent, "the live run B's frames must still pass")

        // NEGATIVE CONTROL: the pre-fix path read the SHARED, re-stamped generation
        // for the SAME straggler frame → it wrongly passed (the old-frame flash).
        XCTAssertTrue(gate.isCurrent(sharedSessionGeneration),
                      "negative control vacuous: the shared-token read did not accept the stale frame")
    }

    /// The token is genuinely IMMUTABLE: further lifecycle churn (more stop/starts)
    /// never revives a token captured for an earlier run.
    func testTokenNeverRevives() {
        let gate = GenerationGate()
        let gen = gate.bump()
        let token = CameraRunToken(generation: gen, gate: gate)
        XCTAssertTrue(token.isCurrent)
        for _ in 0..<8 { gate.bump() }
        XCTAssertFalse(token.isCurrent, "a captured token must never re-match a later generation")
    }
}
