// SmsSender and SmsReceiver have no pure unit tests on Android (they need a Context); these
// pin the pipeline both ways so a kit and the phone read each other's SMS.
import MeshSatMsvqsc
import MeshSatWire
import XCTest

@testable import MeshSatEngine

final class SmsWireTests: XCTestCase {
    private struct FakeEncoder: MsvqscEncoding {
        func encode(_ text: String, maxStages: Int) -> [UInt8]? { MsvqscWire.pack(Array(repeating: 5, count: maxStages)) }
    }

    func testPlainTextStaysPlain() {
        let e = SmsWire.encode("Hello")
        XCTAssertEqual(e, SmsWire.Encoded(body: "Hello", compressed: false, encrypted: false))
        XCTAssertEqual(SmsWire.decode("Hello"), SmsWire.Decoded(text: "Hello", rawText: "", wasEncrypted: false, wasCompressed: false))
        // Something that happens to be base64 but not ours stays as typed.
        XCTAssertEqual(SmsWire.decode("YWJjZA==").text, "YWJjZA==")
    }

    func testSmaz2RoundTrip() {
        let text = "this is a test of the message that the phone sends"
        let e = SmsWire.encode(text, smaz2: true)
        XCTAssertTrue(e.compressed)
        XCTAssertFalse(e.encrypted)
        let bytes = Base64Std.decode(e.body) ?? []
        XCTAssertEqual(bytes.first, ProtocolVersion.protoVersion1)
        let d = SmsWire.decode(e.body)
        XCTAssertEqual(d, SmsWire.Decoded(text: text, rawText: e.body, wasEncrypted: false, wasCompressed: true))
        // No gain: sent as typed.
        XCTAssertEqual(SmsWire.encode("\u{e9}\u{e9}", smaz2: true).compressed, false)
    }

    func testEncryptedAndCompressedRoundTrip() {
        let key = AesGcmCrypto.generateKey()
        let text = "meet at the north bridge at noon"
        let e = SmsWire.encode(text, encryptionKey: key, smaz2: true)
        XCTAssertTrue(e.compressed)
        XCTAssertTrue(e.encrypted)
        XCTAssertTrue(AesGcmCrypto.looksEncrypted(e.body))
        XCTAssertEqual(
            SmsWire.decode(e.body, keys: ["", "deadbeef", key]),
            SmsWire.Decoded(text: text, rawText: e.body, wasEncrypted: true, wasCompressed: true))
        // The wrong key: neither decrypted nor decoded, shown as received.
        XCTAssertEqual(SmsWire.decode(e.body, keys: [AesGcmCrypto.generateKey()]).text, e.body)
        // Auto-decrypt off: as received.
        XCTAssertEqual(SmsWire.decode(e.body, keys: [key], autoDecrypt: false).wasEncrypted, false)
        // Encrypted only. The receiver still says "compressed": plain ASCII is its own smaz2
        // encoding (bytes 9 to 127 are literals), so SmsReceiver's printable check accepts it.
        // Android reports the same, and the text is right either way.
        let plain = SmsWire.encode("hi", encryptionKey: key)
        XCTAssertFalse(plain.compressed)
        XCTAssertEqual(
            SmsWire.decode(plain.body, keys: [key]),
            SmsWire.Decoded(text: "hi", rawText: plain.body, wasEncrypted: true, wasCompressed: true))
        // Non-ASCII text through smaz2 comes back as Latin-1 characters, as Kotlin's
        // Smaz2.decompress makes them (the same mangling on both apps; MESHSAT-1343 for Android).
        let accented = SmsWire.encode("caf\u{e9}", encryptionKey: key)
        XCTAssertEqual(SmsWire.decode(accented.body, keys: [key]).wasEncrypted, true)
    }

    func testMsvqscTakesTheEncoderAndNeedsTheCodebook() {
        let e = SmsWire.encode("go north", msvqscEncoder: FakeEncoder(), msvqscStages: 2)
        XCTAssertTrue(e.compressed)
        let bytes = ProtocolVersion.stripVersionByte(Base64Std.decode(e.body) ?? []).data
        XCTAssertTrue(MsvqscWire.looksLikeMsvqsc(bytes))
        XCTAssertEqual(bytes, MsvqscWire.pack([5, 5]))
        // smaz2 wins when it gains, as on Android; the encoder is not asked.
        let both = SmsWire.encode("this is a test of the message", smaz2: true, msvqscEncoder: FakeEncoder())
        XCTAssertEqual(SmsWire.decode(both.body).text, "this is a test of the message")
        // Without a codebook the frame is shown as received.
        XCTAssertEqual(SmsWire.decode(e.body).text, e.body)
    }

    func testPrintable() {
        XCTAssertTrue(SmsWire.isPrintable("Hello, world!\n"))
        XCTAssertFalse(SmsWire.isPrintable("\u{01}x"))
        XCTAssertFalse(SmsWire.isPrintable("\u{c3}\u{a9}"))
    }
}
