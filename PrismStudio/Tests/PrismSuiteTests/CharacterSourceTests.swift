import XCTest
import PrismSources

/// XCTest gate for `CharacterSource`'s animation depth (DESIGN §3 — lip-sync,
/// auto-blink, richer reactions with overshoot/settle, entrance/exit). The heavy
/// logic lives in `CharacterSelfTest.run()` (deterministic composite renders +
/// pixel/envelope asserts); this wires it into `swift test` / CI and dumps
/// eyeball PNGs to …/scratchpad/prism_character_anim/.
final class CharacterSourceTests: XCTestCase {
    func testCharacterSource() throws {
        try CharacterSelfTest.run()
    }
}
