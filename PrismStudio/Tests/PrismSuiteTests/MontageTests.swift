import XCTest
import PrismSources

/// XCTest gate for `MontageSource` (Build B — the montage engine). The heavy
/// logic lives in `MontageSelfTest.run()` (image-montage advance/order/crossfade/
/// Ken-Burns proof + an embedded-MovieSource video-item lifecycle proof + a
/// seeded-shuffle determinism check, all synthetic — no external asset); this
/// wires it into `swift test` / CI. Also dumps an eyeball PNG sequence.
final class MontageTests: XCTestCase {
    func testMontageSource() throws {
        try MontageSelfTest.run()
    }
}
