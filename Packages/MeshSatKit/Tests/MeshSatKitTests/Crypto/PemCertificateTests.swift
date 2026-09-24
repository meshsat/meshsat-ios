import Crypto
import Foundation
import MeshSatCrypto
import X509
import XCTest

final class PemCertificateTests: XCTestCase {
    func testTheFactsOfACertificate() throws {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName { CommonName("bridge-1") }
        let notAfter = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15
        let cert = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: .init(key.publicKey),
            notValidBefore: Date(timeIntervalSince1970: 1_700_000_000), notValidAfter: notAfter, issuer: name, subject: name,
            signatureAlgorithm: .ecdsaWithSHA256, extensions: Certificate.Extensions(), issuerPrivateKey: .init(key))
        let pem = try cert.serializeAsPEM().pemString
        let info = try PemCertificate.parse(pem)
        XCTAssertEqual(info.notAfter, "2027-01-15")
        XCTAssertTrue(info.subject.contains("bridge-1"), info.subject)
        XCTAssertEqual(info.fingerprint.count, 23)
        XCTAssertEqual(info.fingerprint.filter { $0 == ":" }.count, 7)
    }

    func testSomethingElseIsRefused() {
        XCTAssertThrowsError(try PemCertificate.parse("hello"))
    }
}
