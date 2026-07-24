import CoreBluetooth
import Foundation
import PrismCore
import PrismLink

/// Headless self-verification of PrismProximity's pure/logic surface. It
/// creates **no** `CBCentralManager`/`CBPeripheralManager` (that would trip the
/// Bluetooth TCC prompt); it exercises only value types and pure functions:
/// advertisement encode/decode, RSSI→bucket mapping, token generation/rotation,
/// the BLE-presence-only security stance, candidate dedup/lastSeen/prune, and
/// the stability of the service/characteristic UUIDs.
///
/// Wire into prism-dev or an XCTest target; `run()` throws with a precise
/// message on the first mismatch.
public enum ProximitySelfTest {
    public enum SelfTestError: Error, CustomStringConvertible {
        case mismatch(String)
        public var description: String {
            switch self {
            case .mismatch(let s): return "proximity self-test mismatch: \(s)"
            }
        }
    }

    private static func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw SelfTestError.mismatch(message()) }
    }

    public static func run() throws {
        try testServiceIdentityStable()
        try testAdvertisementRoundTrip()
        try testAdvertisementMalformed()
        try testNameTruncation()
        try testTokenGeneration()
        try testTokenNeverContainsPairingCode()
        try testProximityBuckets()
        try testCandidateStore()
        try testStateAndAuthMapping()
        #if os(macOS)
        try testCharacteristicReadDelivery()
        #endif
        print("ProximitySelfTest: all pure-logic checks passed")
    }

    // MARK: - 1. Service identity is a stable constant

    private static func testServiceIdentityStable() throws {
        try require(ProximityProtocol.serviceUUID == CBUUID(string: "9F4B7C10-3E1A-4B2D-8F6A-1C2D3E4F5A6B"),
                    "service UUID drifted from its fixed constant")
        try require(ProximityProtocol.characteristicUUID == CBUUID(string: "9F4B7C11-3E1A-4B2D-8F6A-1C2D3E4F5A6B"),
                    "characteristic UUID drifted from its fixed constant")
        try require(ProximityProtocol.serviceUUID != ProximityProtocol.characteristicUUID,
                    "service and characteristic UUIDs must differ")
    }

    // MARK: - 2. Advertisement encode/decode round-trip

    private static func testAdvertisementRoundTrip() throws {
        let token = try ProximityToken.random()
        for name in ["Alex's iPhone", "iPad", "", "Café 📷 Cam"] {
            let adv = ProximityProtocol.Advertisement(name: name, token: token)
            guard let decoded = ProximityProtocol.Advertisement.decode(adv.encode()) else {
                throw SelfTestError.mismatch("decode returned nil for name \"\(name)\"")
            }
            try require(decoded.token == token, "token corrupted in round-trip for \"\(name)\"")
            // Names within the byte budget survive verbatim.
            if Data(name.utf8).count <= ProximityProtocol.maxNameBytes {
                try require(decoded.name == name, "name corrupted: \"\(decoded.name)\" != \"\(name)\"")
            }
            try require(decoded == ProximityProtocol.Advertisement(name: decoded.name, token: token),
                        "Advertisement Equatable broken")
        }

        // Decode must survive a non-zero-based Data slice (real CB service data).
        let padded = Data([0xFF, 0xFF]) + ProximityProtocol.Advertisement(name: "Slice", token: token).encode()
        let slice = padded.subdata(in: (padded.startIndex + 2)..<padded.endIndex)
        try require(ProximityProtocol.Advertisement.decode(slice)?.name == "Slice",
                    "decode failed on a non-zero-based Data slice")
    }

    // MARK: - 3. Malformed payloads decode to nil, not garbage

    private static func testAdvertisementMalformed() throws {
        // Too short (no room for version + token).
        try require(ProximityProtocol.Advertisement.decode(Data([0x01, 0x00])) == nil,
                    "short payload should not decode")
        // Wrong version byte.
        var badVersion = Data([0x02])
        badVersion.append(Data(repeating: 0, count: ProximityProtocol.tokenLength))
        try require(ProximityProtocol.Advertisement.decode(badVersion) == nil,
                    "wrong version should not decode")
        // Invalid UTF-8 in the name region.
        var badName = Data([ProximityProtocol.payloadVersion])
        badName.append(Data(repeating: 0, count: ProximityProtocol.tokenLength))
        badName.append(Data([0xFF, 0xFE, 0xFD]))  // not valid UTF-8
        try require(ProximityProtocol.Advertisement.decode(badName) == nil,
                    "invalid UTF-8 name should not decode")
        // Empty data.
        try require(ProximityProtocol.Advertisement.decode(Data()) == nil,
                    "empty payload should not decode")

        // #9: decode enforces the SAME name bound as encode (symmetry). A name
        // region longer than maxNameBytes could never come from our encoder.
        func payload(nameLen: Int) -> Data {
            var d = Data([ProximityProtocol.payloadVersion])
            d.append(Data(repeating: 0, count: ProximityProtocol.tokenLength))
            d.append(Data(repeating: 0x41, count: nameLen)) // 'A' * nameLen (valid UTF-8)
            return d
        }
        try require(ProximityProtocol.Advertisement.decode(payload(nameLen: ProximityProtocol.maxNameBytes + 1)) == nil,
                    "decode must reject a name longer than maxNameBytes (encode/decode asymmetry)")
        let atLimit = ProximityProtocol.Advertisement.decode(payload(nameLen: ProximityProtocol.maxNameBytes))
        try require(atLimit?.name.utf8.count == ProximityProtocol.maxNameBytes,
                    "decode must accept a name of exactly maxNameBytes")
    }

    // MARK: - 4. Name truncation on a scalar boundary

    private static func testNameTruncation() throws {
        let token = try ProximityToken.random()
        let long = String(repeating: "A", count: 100)
        let encoded = ProximityProtocol.Advertisement(name: long, token: token).encode()
        let nameBytes = encoded.count - 1 - ProximityProtocol.tokenLength
        try require(nameBytes <= ProximityProtocol.maxNameBytes,
                    "encoded name \(nameBytes) bytes exceeds max \(ProximityProtocol.maxNameBytes)")
        // Multi-byte scalars are never split mid-encoding.
        let emoji = String(repeating: "📷", count: 20) // 4 UTF-8 bytes each
        let emojiEncoded = ProximityProtocol.Advertisement(name: emoji, token: token).encode()
        let decoded = ProximityProtocol.Advertisement.decode(emojiEncoded)
        try require(decoded != nil, "truncated emoji name must remain valid UTF-8")
        try require(Data(decoded!.name.utf8).count <= ProximityProtocol.maxNameBytes,
                    "truncated emoji name exceeds max byte budget")
    }

    // MARK: - 5. Token generation + rotation

    private static func testTokenGeneration() throws {
        var seen = Set<Data>()
        for _ in 0..<64 {
            let token = try ProximityToken.random()
            try require(token.bytes.count == ProximityProtocol.tokenLength,
                        "token length \(token.bytes.count) != \(ProximityProtocol.tokenLength)")
            seen.insert(token.bytes)
        }
        // 64 draws of 32-bit tokens colliding down to a handful is astronomically
        // unlikely; a broken CSPRNG (constant output) would give exactly 1.
        try require(seen.count > 60, "token RNG produced only \(seen.count)/64 distinct values")

        var rotator = try TokenRotator()
        let first = rotator.current
        let rotated = try rotator.rotate()
        try require(rotated == rotator.current, "rotate() did not update current")
        try require(rotated != first, "rotate() returned the same token (RNG stuck?)")

        // Token init rejects wrong lengths.
        try require(ProximityToken(bytes: Data([0x01])) == nil, "token accepted a 1-byte payload")
        try require(ProximityToken(bytes: Data(repeating: 0, count: ProximityProtocol.tokenLength + 1)) == nil,
                    "token accepted an over-long payload")
    }

    // MARK: - 6. BLE-presence-only: the pairing code never reaches the payload

    private static func testTokenNeverContainsPairingCode() throws {
        // A real pairing code from the Wi-Fi flow.
        let code = LinkPairing.generateCode()
        let codeBytes = Data(LinkPairing.normalize(code).utf8)
        let psk = try LinkPairing.derivePSK(code: code).withUnsafeBytes { Data($0) }

        // The advertiser's ONLY inputs are a name and a random token — there is
        // no API to attach the code. Verify the emitted bytes over many tokens
        // contain neither the code nor the derived PSK.
        for _ in 0..<200 {
            let token = try ProximityToken.random()
            let payload = ProximityProtocol.Advertisement(name: "Alex's iPhone", token: token).encode()
            try require(!contains(payload, codeBytes),
                        "advertisement payload leaked the pairing code")
            try require(!contains(token.bytes, codeBytes),
                        "presence token contained the pairing code")
            try require(!contains(payload, psk),
                        "advertisement payload leaked the derived PSK")
        }
    }

    // MARK: - 10. Connected characteristic-read token delivery (#7, macOS)

    /// The token is not reachable in the iOS advertisement PDU, so the scanner
    /// connects and reads the presence characteristic. We can't run real BLE
    /// headlessly, but the delivery plumbing exposes ``applyReadPayload`` — the
    /// exact function the `didUpdateValueFor` delegate calls — so the
    /// encode→read→decode round-trip and the store fold are logic-tested. Dedup
    /// then honestly uses the token when present, falling back to peripheralID.
    #if os(macOS)
    private static func testCharacteristicReadDelivery() throws {
        let scanner = ProximityScanner(staleAfter: 10)
        let token = try ProximityToken.random()
        let id = UUID()
        let now = Date(timeIntervalSince1970: 2_000)

        var delivered: ProximityCandidate?
        scanner.onCandidate = { candidate, _ in delivered = candidate }

        // A valid characteristic value (what a connected read returns) delivers
        // the token + name.
        let blob = ProximityProtocol.Advertisement(name: "Alex's iPhone", token: token).encode()
        let applied = scanner.applyReadPayload(blob, peripheralID: id, at: now)
        try require(applied != nil, "characteristic read of a valid payload must yield a candidate")
        try require(applied?.token == token, "token from the characteristic read was not delivered")
        try require(applied?.name == "Alex's iPhone", "name from the characteristic read was not delivered")
        try require(delivered?.token == token, "onCandidate must surface the read-delivered token")

        // A malformed characteristic value delivers no token (no fabrication).
        try require(scanner.applyReadPayload(Data([0x00, 0x01]), peripheralID: id) == nil,
                    "a malformed characteristic value must not fabricate a token")
    }
    #endif

    private static func contains(_ haystack: Data, _ needle: Data) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let h = Array(haystack), n = Array(needle)
        for start in 0...(h.count - n.count) where Array(h[start..<start + n.count]) == n {
            return true
        }
        return false
    }

    // MARK: - 7. RSSI → proximity bucket

    private static func testProximityBuckets() throws {
        let cases: [(Int, ProximityBucket)] = [
            (-20, .immediate),
            (-45, .immediate),   // boundary
            (-46, .near),
            (-50, .near),        // spec example: -50 → near
            (-75, .near),        // boundary
            (-76, .far),
            (-90, .far),         // spec example: -90 → far
            (-120, .far),
            (0, .unknown),       // invalid sentinel
            (127, .unknown),     // CoreBluetooth "unavailable"
        ]
        for (rssi, expected) in cases {
            let got = ProximityProtocol.bucket(forRSSI: rssi)
            try require(got == expected, "RSSI \(rssi) → \(got), expected \(expected)")
        }
    }

    // MARK: - 8. Candidate dedup / lastSeen / prune

    private static func testCandidateStore() throws {
        var store = CandidateStore(staleAfter: 10)
        let a = UUID(), b = UUID()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let token = try ProximityToken.random()

        let first = store.observe(peripheralID: a, name: "iPhone", token: token, rssi: -50, at: t0)
        try require(first.isNew, "first sighting should be new")
        try require(store.count == 1, "store should hold 1 candidate")
        try require(first.candidate.proximity == .near, "candidate proximity should reflect -50 → near")

        // Same peripheral again: update in place, keep firstSeen, refresh lastSeen.
        let t1 = t0.addingTimeInterval(3)
        let second = store.observe(peripheralID: a, name: nil, token: nil, rssi: -80, at: t1)
        try require(!second.isNew, "second sighting of same ID should not be new")
        try require(store.count == 1, "dedup failed — store grew on repeat sighting")
        try require(second.candidate.firstSeen == t0, "firstSeen must be preserved across sightings")
        try require(second.candidate.lastSeen == t1, "lastSeen must advance to the newest sighting")
        try require(second.candidate.name == "iPhone", "name should persist when a PDU omits it")
        try require(second.candidate.proximity == .far, "updated proximity should reflect -80 → far")

        // A distinct peripheral is a separate candidate.
        _ = store.observe(peripheralID: b, name: "iPad", token: token, rssi: -60, at: t1)
        try require(store.count == 2, "distinct peripheral should be a separate candidate")

        // Prune: `a` last seen at t1, `b` at t1. At t1+11, both are stale.
        let expired = store.prune(at: t1.addingTimeInterval(11))
        try require(Set(expired) == Set([a, b]), "prune should retract both stale candidates")
        try require(store.count == 0, "store should be empty after pruning all")

        // Fresh candidate survives a prune inside its TTL.
        _ = store.observe(peripheralID: a, name: "iPhone", token: token, rssi: -50, at: t1)
        try require(store.prune(at: t1.addingTimeInterval(5)).isEmpty, "in-TTL candidate wrongly pruned")
        try require(store.count == 1, "in-TTL candidate should remain")
    }

    // MARK: - 9. Radio-state + authorization mapping (pure; no manager created)

    private static func testStateAndAuthMapping() throws {
        let stateCases: [(CBManagerState, ProximityRadioState)] = [
            (.unknown, .unknown), (.resetting, .resetting), (.unsupported, .unsupported),
            (.unauthorized, .unauthorized), (.poweredOff, .poweredOff), (.poweredOn, .poweredOn),
        ]
        for (cb, expected) in stateCases {
            try require(ProximityRadioState(cb) == expected, "state \(cb.rawValue) mapped wrong")
        }
        try require(ProximityRadioState(.poweredOn).isUsable, "poweredOn must be usable")
        try require(!ProximityRadioState(.poweredOff).isUsable, "poweredOff must not be usable")

        let authCases: [(CBManagerAuthorization, ProximityAuthorization)] = [
            (.notDetermined, .notDetermined), (.restricted, .restricted),
            (.denied, .denied), (.allowedAlways, .allowed),
        ]
        for (cb, expected) in authCases {
            try require(ProximityAuthorization(cb) == expected, "auth \(cb.rawValue) mapped wrong")
        }
    }
}
