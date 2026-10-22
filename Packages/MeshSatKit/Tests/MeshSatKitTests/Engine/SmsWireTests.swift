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
        XCTAssertEqual(Array(bytes.prefix(3)), [SmsWireV2.version, SmsWireV2.modeClear, SmsWireV2.codecSmaz2])
        let d = SmsWire.decode(e.body)
        XCTAssertEqual(d, SmsWire.Decoded(text: text, rawText: e.body, wasEncrypted: false, wasCompressed: true))
        // No gain: sent as typed.
        XCTAssertEqual(SmsWire.encode("éé", smaz2: true).compressed, false)
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
        // The wrong key: not decrypted, and shown exactly as it came. Under version 1 the ciphertext
        // could read as printable smaz2 and show a misread (the second symptom on MESHSAT-1343);
        // version 2 keeps a frame no key opens. [r40 review R40-R1]
        let wrongKey = SmsWire.decode(e.body, keys: [AesGcmCrypto.generateKey()])
        XCTAssertEqual(wrongKey, SmsWire.Decoded(text: e.body, rawText: "", wasEncrypted: false, wasCompressed: false))
        // Auto-decrypt off: as received.
        XCTAssertEqual(SmsWire.decode(e.body, keys: [key], autoDecrypt: false).wasEncrypted, false)
        // Encrypted only. Plain ASCII is its own smaz2 encoding (bytes 9 to 127 are literals), so the
        // receiver used to call it compressed; compressing "hi" gives one byte, not these two, so it
        // is now read as what it is. The text was right either way. [MESHSAT-1628]
        let plain = SmsWire.encode("hi", encryptionKey: key)
        XCTAssertFalse(plain.compressed)
        XCTAssertEqual(
            SmsWire.decode(plain.body, keys: [key]),
            SmsWire.Decoded(text: "hi", rawText: plain.body, wasEncrypted: true, wasCompressed: false))
        // Encrypted, not compressed (smaz2 gains nothing on these): the text as sent, never read
        // as SMAZ2, whose bigrams turned every byte above 0x7F into two ASCII letters. [MESHSAT-1628]
        // A single Greek word is all bigram codes read as SMAZ2, and its bigrams compress back to the
        // same bytes: only the plain-UTF-8 rule tells it. [MESHSAT-1646]
        for text in [
            "café",
            "Καλημέρα από το σκάφος",
            "ok \u{1F44D}",
            "Καλημέρα",
            "Ναι",
            "Όχι",
        ] {
            let sealed = SmsWire.encode(text, encryptionKey: key, smaz2: true)
            XCTAssertFalse(sealed.compressed, text)
            XCTAssertEqual(
                SmsWire.decode(sealed.body, keys: [key]),
                SmsWire.Decoded(text: text, rawText: sealed.body, wasEncrypted: true, wasCompressed: false), text)
        }
        // Compressed and encrypted, mixed English and Greek: read back as sent.
        let mixed = "this is the message from the station, όλοι καλά"
        let both = SmsWire.encode(mixed, encryptionKey: key, smaz2: true)
        XCTAssertTrue(both.compressed)
        XCTAssertEqual(
            SmsWire.decode(both.body, keys: [key]),
            SmsWire.Decoded(text: mixed, rawText: both.body, wasEncrypted: true, wasCompressed: true))
    }

    func testMsvqscTakesTheEncoderAndNeedsTheCodebook() {
        let e = SmsWire.encode("go north", msvqscEncoder: FakeEncoder(), msvqscStages: 2)
        XCTAssertTrue(e.compressed)
        let bytes = Base64Std.decode(e.body) ?? []
        XCTAssertEqual(bytes, [SmsWireV2.version, SmsWireV2.modeClear, SmsWireV2.codecMsvqsc] + MsvqscWire.pack([5, 5]))
        XCTAssertEqual(SmsWire.decode(e.body, codebook: nil).text, e.body, "no codebook: kept as it came")
        // smaz2 wins when it gains, as on Android; the encoder is not asked.
        let both = SmsWire.encode("this is a test of the message", smaz2: true, msvqscEncoder: FakeEncoder())
        XCTAssertEqual(SmsWire.decode(both.body).text, "this is a test of the message")
        // Without a codebook the frame is shown as received.
        XCTAssertEqual(SmsWire.decode(e.body).text, e.body)
    }

    /// Plain non-ASCII text is valid UTF-8 only, checked without the iOS 18 API (MESHSAT-1646).
    func testPlainNonASCIINeedsValidUTF8() {
        XCTAssertTrue(SmsWire.isPlainNonASCII(Array("Καλημέρα".utf8)))
        XCTAssertFalse(SmsWire.isPlainNonASCII(Array("plain ascii".utf8)), "ASCII only is not this case")
        XCTAssertFalse(SmsWire.isPlainNonASCII([0xCE]), "a lone lead byte")
        XCTAssertFalse(SmsWire.isPlainNonASCII([0x41, 0xC0, 0xAF]), "an overlong form")
        XCTAssertFalse(SmsWire.isPlainNonASCII([0xED, 0xA0, 0x80]), "a surrogate")
        XCTAssertFalse(SmsWire.isPlainNonASCII(Array("\u{FFFD}x".utf8)), "U+FFFD is not readable text")
    }

    func testPrintable() {
        XCTAssertTrue(SmsWire.isPrintable("Hello, world!\n"))
        XCTAssertTrue(SmsWire.isPrintable("café \u{1F44D}\t\r"))
        XCTAssertFalse(SmsWire.isPrintable("\u{01}x"))
        XCTAssertFalse(SmsWire.isPrintable("a\u{7F}"), "DEL")
        XCTAssertFalse(SmsWire.isPrintable("\u{85}x"), "a C1 control")
        XCTAssertFalse(SmsWire.isPrintable("x\u{FFFD}"), "broken UTF-8")
    }

    /// Android's SmsSmaz2TextTest cases, through the iOS receive path for version 1: compressed
    /// Greek, mixed and English text reads back as sent; what decodes to control bytes or broken UTF-8 is not taken
    /// as compressed and is shown as it came. [MESHSAT-1628]
    func testACompressedSmsWithGreekOrEmojiReadsBackAsSent() {
        for s in [
            "Καλημέρα από το σκάφος",
            "Είμαστε στο βόρειο φυλάκιο, όλοι καλά",
            "meet at the gate, ώρα 14:00", "the satellite is in range\nall good",
            "café ñandú \u{1F44D}",
        ] {
            let body = Base64Std.encode(ProtocolVersion.prependVersionByte(Smaz2Bytes.compress(Array(s.utf8), dict: .default)))
            XCTAssertEqual(SmsWire.decode(body), SmsWire.Decoded(text: s, rawText: body, wasEncrypted: false, wasCompressed: true), s)
        }
        for (name, bytes) in [
            ("a control byte", [0x41, 0x1B, 0x42]), ("a NUL", [0x41, 0x00]), ("broken UTF-8 in a verbatim run", [0x02, 0xFF, 0xFE]),
            ("a C1 control", [0x02, 0xC2, 0x85]),
        ] as [(String, [UInt8])] {
            XCTAssertNil(SmsWire.isPrintable(Smaz2.decompress(bytes) ?? "\u{0}") ? "taken" : nil, name)
        }
        XCTAssertNil(Smaz2.decompress([]))
    }
}
