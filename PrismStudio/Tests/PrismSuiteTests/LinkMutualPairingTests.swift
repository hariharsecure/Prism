import CryptoKit
import Foundation
import XCTest
@testable import PrismLink

/// THE BUG: Link pairing was ONE-WAY. The phone (client) proved it knew the
/// pairing code to the Mac (server), but the server never proved it knew the
/// code back. A spoofed first-contact Mac on the LAN could therefore accept a
/// phone and silently receive its camera video without knowing the code.
///
/// THE FIX: a reverse proof — `LinkPairing.serverProof(code:serverCertificateDER:
/// clientNonce:)` — bound to the server's own certificate and a nonce the CLIENT
/// mints. The client withholds all media until it recomputes and matches this
/// proof, so a server that does not know the code can never produce it.
///
/// What this test proves (pure crypto, no socket): the reverse proof verifies
/// only under the correct code, is bound to cert + client nonce, is
/// domain-separated from the client proof, and rejects degenerate nonces. The
/// socket-level withholding of media is wired in `LinkClient` and covered by the
/// build + the opt-in gate; here we lock down the primitive it depends on.
final class LinkMutualPairingTests: XCTestCase {

    private let code = "prism-1234"
    private let certDER = Data("server-leaf-certificate-DER".utf8)

    private func nonce(_ n: Int = 32) -> Data {
        Data((0..<n).map { UInt8($0 & 0xFF) })
    }

    /// Correct code + cert + nonce → the server and client compute the SAME proof.
    func testServerProofMatchesUnderCorrectInputs() throws {
        let n = nonce()
        let byServer = try LinkPairing.serverProof(code: code, serverCertificateDER: certDER, clientNonce: n)
        let byClient = try LinkPairing.serverProof(code: code, serverCertificateDER: certDER, clientNonce: n)
        XCTAssertEqual(byServer, byClient)
        XCTAssertEqual(byServer.count, 32, "HMAC-SHA256 is 32 bytes")
    }

    /// A server that does NOT know the code cannot produce the proof the client
    /// expects — this is the whole defense against a spoof Mac.
    func testWrongCodeFailsVerification() throws {
        let n = nonce()
        let expected = try LinkPairing.serverProof(code: code, serverCertificateDER: certDER, clientNonce: n)
        let spoof = try LinkPairing.serverProof(code: "prism-9999", serverCertificateDER: certDER, clientNonce: n)
        XCTAssertNotEqual(spoof, expected)
    }

    /// Channel binding: the proof is tied to the exact server certificate, so a
    /// spoof presenting a different cert cannot reuse a harvested proof.
    func testProofIsBoundToCertificate() throws {
        let n = nonce()
        let a = try LinkPairing.serverProof(code: code, serverCertificateDER: certDER, clientNonce: n)
        let b = try LinkPairing.serverProof(code: code, serverCertificateDER: Data("other-cert".utf8), clientNonce: n)
        XCTAssertNotEqual(a, b)
    }

    /// The client's fresh nonce makes each proof single-use: a proof captured on
    /// one connection fails on the next (different nonce).
    func testProofIsBoundToClientNonce() throws {
        let a = try LinkPairing.serverProof(code: code, serverCertificateDER: certDER, clientNonce: nonce())
        let b = try LinkPairing.serverProof(code: code, serverCertificateDER: certDER,
                                            clientNonce: Data((0..<32).map { UInt8((255 - $0) & 0xFF) }))
        XCTAssertNotEqual(a, b)
    }

    /// Domain separation: the server proof and the client (pairing) proof over
    /// the SAME code/cert/nonce differ, so a client proof can never be replayed
    /// as a server proof or vice versa.
    func testServerAndClientProofsAreDomainSeparated() throws {
        let n = nonce()
        let serverSide = try LinkPairing.serverProof(code: code, serverCertificateDER: certDER, clientNonce: n)
        let clientSide = try LinkPairing.pairingProof(code: code, serverCertificateDER: certDER, nonce: n)
        XCTAssertNotEqual(serverSide, clientSide,
                          "distinct HMAC contexts must yield distinct proofs for identical inputs")
    }

    /// A hostile server must not be able to downgrade security with a tiny nonce;
    /// the client mints 32 bytes and the primitive rejects short ones.
    func testShortNonceRejected() {
        XCTAssertThrowsError(try LinkPairing.serverProof(code: code,
                                                         serverCertificateDER: certDER,
                                                         clientNonce: Data([1, 2, 3])))
    }
}
