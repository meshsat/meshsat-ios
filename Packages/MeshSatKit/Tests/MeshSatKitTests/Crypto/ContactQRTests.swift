// Mirrors ContactQRTest.kt: everything here is someone else's input arriving through a camera,
// so the tests care as much about what is refused as about what round-trips.
import MeshSatCrypto
import XCTest

final class ContactQRTests: XCTestCase {
    private let identity = Identity.generate()

    private func card(name: String = "Kyriakos") -> ContactQR.Card {
        ContactQR.Card(
            name: name, signingPubRaw: identity.signingPubRaw, meshNodeId: "!bf6ee7bc", bridgeId: "msa-flaneur", issuedAtSec: 1_789_900_000)
    }

    func testACardSurvivesTheRoundTrip() throws {
        let text = try ContactQR.encode(card(), identity: identity)
        XCTAssertTrue(text.hasPrefix(ContactQR.prefix))
        XCTAssertEqual(ContactQR.decode(text), .ok(card()))
    }

    func testACardAlteredInTransitIsRefused() throws {
        let text = try ContactQR.encode(card(), identity: identity)
        let body = String(text.dropFirst(ContactQR.prefix.count))
        let dot = body.firstIndex(of: ".")!
        let payload = ContactQR.unB64(String(body[..<dot]))!
        let tampered = Array(String(bytes: payload, encoding: .utf8)!.replacingOccurrences(of: "Kyriakos", with: "Mallory").utf8)
        let forged = ContactQR.prefix + ContactQR.b64(tampered) + "." + String(body[body.index(after: dot)...])
        XCTAssertEqual(ContactQR.decode(forged), .badSignature)
    }

    func testACardSignedByAnotherKeyIsRefused() throws {
        let other = Identity.generate()
        XCTAssertEqual(ContactQR.decode(try ContactQR.encode(card(), identity: other)), .badSignature)
    }

    func testAnythingThatIsNotACardIsToldApartFromABrokenOne() {
        XCTAssertEqual(ContactQR.decode("https://meshsat.net"), .notACard)
        XCTAssertEqual(ContactQR.decode(""), .notACard)
        XCTAssertEqual(ContactQR.decode("meshsat:contact:2:abc.def"), .notACard)
        XCTAssertEqual(ContactQR.decode(ContactQR.prefix + "no-dot"), .malformed)
        XCTAssertEqual(ContactQR.decode(ContactQR.prefix + "!!!.???"), .malformed)
    }

    func testAKeyOfTheWrongLengthIsRefusedBeforeItReachesTheVerifier() {
        let payload = Array("Someone\u{1F}AAAA\u{1F}\u{1F}\u{1F}0".utf8)
        XCTAssertEqual(ContactQR.decode(ContactQR.prefix + ContactQR.b64(payload) + ".AAAA"), .malformed)
    }

    func testANameCarryingTheSeparatorIsRefusedRatherThanReshapingTheRecord() {
        XCTAssertThrowsError(try ContactQR.encode(card(name: "Kyriakos\u{1F}fake-key"), identity: identity)) { e in
            XCTAssertTrue("\(e)".contains("separator"))
        }
    }

    func testTheFingerprintIsStableReadableAndDifferentPerIdentity() {
        let fp = card().fingerprint
        XCTAssertEqual(fp, ContactQR.fingerprintOf(identity.signingPubRaw))
        XCTAssertEqual(fp.count, 19, "four groups of four")
        XCTAssertEqual(fp.filter { $0 == " " }.count, 3)
        XCTAssertNotEqual(fp, ContactQR.fingerprintOf(Identity.generate().signingPubRaw))
    }
}
