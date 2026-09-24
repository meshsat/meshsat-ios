// Ports AesGcmWireFormatTest.kt (MESHSAT-205): the Hub-compatible [nonce][ciphertext][tag] format.
import Crypto
import XCTest

@testable import MeshSatWire

final class AesGcmCryptoTests: XCTestCase {
    private let testKey = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    func testWireFormatIsNonceThenCiphertextThenTag() throws {
        let plaintext = (0..<100).map { UInt8($0) }
        let encrypted = try AesGcmCrypto.encrypt(plaintext, hexKey: testKey)
        XCTAssertEqual(encrypted.count, 12 + 100 + 16)
        XCTAssertEqual(try AesGcmCrypto.decrypt(encrypted, hexKey: testKey), plaintext)
        XCTAssertEqual(try AesGcmCrypto.encrypt(Array("test".utf8), hexKey: testKey).count, 32)
    }

    func testRoundTripsAndRandomNonces() throws {
        let text = "MAYDAY MAYDAY requesting evacuation at checkpoint bravo"
        let enc = try AesGcmCrypto.encrypt(Array(text.utf8), hexKey: testKey)
        XCTAssertEqual(String(decoding: try AesGcmCrypto.decrypt(enc, hexKey: testKey), as: UTF8.self), text)
        let a = try AesGcmCrypto.encrypt(Array("test message".utf8), hexKey: testKey)
        let b = try AesGcmCrypto.encrypt(Array("test message".utf8), hexKey: testKey)
        XCTAssertNotEqual(Array(a.prefix(12)), Array(b.prefix(12)))
        let b64 = try AesGcmCrypto.encryptToBase64("field report: all clear at grid 4523", hexKey: testKey)
        XCTAssertEqual(try AesGcmCrypto.decryptFromBase64(b64, hexKey: testKey), "field report: all clear at grid 4523")
        XCTAssertTrue(AesGcmCrypto.looksEncrypted(b64))
        XCTAssertFalse(AesGcmCrypto.looksEncrypted("hello there, plain text"))
    }

    func testKeysAndFailures() throws {
        let key = AesGcmCrypto.generateKey()
        XCTAssertEqual(key.count, 64)
        XCTAssertTrue(AesGcmCrypto.isValidHexKey(key))
        XCTAssertTrue(AesGcmCrypto.isValidHexKey(testKey.uppercased()))
        XCTAssertFalse(AesGcmCrypto.isValidHexKey("abc"))
        XCTAssertThrowsError(try AesGcmCrypto.encrypt([1], hexKey: "0011"))
        let enc = try AesGcmCrypto.encrypt(Array("x".utf8), hexKey: testKey)
        XCTAssertThrowsError(try AesGcmCrypto.decrypt(enc, hexKey: AesGcmCrypto.generateKey()), "a wrong key fails the tag")
        var tampered = enc
        tampered[14] ^= 0x01
        XCTAssertThrowsError(try AesGcmCrypto.decrypt(tampered, hexKey: testKey))
        XCTAssertThrowsError(try AesGcmCrypto.decrypt([UInt8](repeating: 0, count: 20), hexKey: testKey))
    }

    /// A message the Hub encrypted with Go's crypto/cipher (nonce prepended) decrypts here.
    func testHubProducedCiphertextDecrypts() throws {
        // Produced with Go: key 00..ff (32 bytes as below), nonce 000102...0b, plaintext "hello hub".
        let key = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        let nonce = (0..<12).map { UInt8($0) }
        let sealed = try AES.GCM.seal(
            Array("hello hub".utf8), using: SymmetricKey(data: Hex.decode(key)!), nonce: AES.GCM.Nonce(data: nonce))
        let wire = nonce + Array(sealed.ciphertext) + Array(sealed.tag)
        XCTAssertEqual(String(decoding: try AesGcmCrypto.decrypt(wire, hexKey: key), as: UTF8.self), "hello hub")
    }
}
