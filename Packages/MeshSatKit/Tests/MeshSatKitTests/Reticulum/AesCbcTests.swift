// The AES-256-CBC helper against an OpenSSL 3.0 vector, so CommonCrypto (Apple) and
// _CryptoExtras (Linux) produce the same bytes.
import MeshSatWire
import XCTest

@testable import MeshSatReticulum

final class AesCbcTests: XCTestCase {
    private let key = (0..<32).map { UInt8($0) }
    private let iv: [UInt8] = [0x0f, 0x0e, 0x0d, 0x0c, 0x0b, 0x0a, 0x09, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x00]

    func testOpenSslVector() throws {
        // printf '0123456789abcdefXYZ' | openssl enc -aes-256-cbc -K 00..1f -iv 0f..00
        let plaintext = Array("0123456789abcdefXYZ".utf8)
        let expected = Hex.decode("7862a071da19f3286dcd4ca7ca9c6e3e403b5d3ae12c39155dce46f6a975ab7e") ?? []
        XCTAssertEqual(try AesCbc.encrypt(plaintext, key: key, iv: iv), expected)
        XCTAssertEqual(try AesCbc.decrypt(expected, key: key, iv: iv), plaintext)
    }

    func testPaddingAndErrors() throws {
        // A whole block of plaintext gains a full block of padding.
        XCTAssertEqual(try AesCbc.encrypt([UInt8](repeating: 7, count: 16), key: key, iv: iv).count, 32)
        XCTAssertEqual(try AesCbc.encrypt([], key: key, iv: iv).count, 16)
        XCTAssertThrowsError(try AesCbc.encrypt([1], key: [1, 2, 3], iv: iv))
        XCTAssertThrowsError(try AesCbc.encrypt([1], key: key, iv: [1]))
        XCTAssertThrowsError(try AesCbc.decrypt([1, 2, 3], key: key, iv: iv))
        // A wrong key never gives the text back: CommonCrypto reports bad padding unless the
        // garbage happens to end in a valid pad (one case in 256), BoringSSL always reports it.
        let ct = try AesCbc.encrypt(Array("secret".utf8), key: key, iv: iv)
        let wrong = try? AesCbc.decrypt(ct, key: (0..<32).map { UInt8(255 - $0) }, iv: iv)
        XCTAssertNotEqual(wrong, Array("secret".utf8))
    }
}
