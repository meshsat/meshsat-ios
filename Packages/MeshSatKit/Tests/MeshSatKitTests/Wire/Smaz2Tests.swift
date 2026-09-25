// Smaz2 has no Android unit test; the vectors here come from a line-by-line port of
// codec/Smaz2.kt run over the same inputs (25 Sep 2026), so the two apps stay byte-equal.
// CannedCodebookTests mirrors CannedCodebookTest.kt.
import XCTest

@testable import MeshSatWire

final class Smaz2Tests: XCTestCase {
    private let golden: [(String, String)] = [
        ("the", "810165"),
        ("that ", "0700"),
        ("this is a test of the message", "07019603206120898c0120a5012081026520064a"),
        ("Hello World!", "0148b0cb02205788036c6421"),
        ("SOS need help at the river crossing", "04534f53200762071c8a0120810265209ea8037220639fc3800167"),
        ("12345678901234", "0531323334350536373839300431323334"),
        ("ABCDEFGHIJ", "05414243444505464748494a"),
        ("Copy.", "0143e802792e"),
        ("\u{e9}", "02c3a9"),
        ("", ""),
    ]

    func testCompressMatchesAndroid() {
        for (text, hex) in golden {
            XCTAssertEqual(Hex.encode(Smaz2.compress(text)), hex, text)
        }
    }

    func testDecompressRoundTrip() {
        for (text, _) in golden where !text.isEmpty && text.utf8.allSatisfy({ $0 < 0x80 }) {
            XCTAssertEqual(Smaz2.decompress(Smaz2.compress(text)), text, text)
        }
        // Bytes above 0x7F come back as Latin-1 characters, as Kotlin's toChar makes them.
        XCTAssertEqual(Smaz2.decompress(Smaz2.compress("\u{e9}")), "\u{c3}\u{a9}")
    }

    func testDecompressRejectsMalformed() {
        XCTAssertNil(Smaz2.decompress([]))
        XCTAssertNil(Smaz2.decompress([0x03, 0x41]))
        XCTAssertNil(Smaz2.decompress([0x06]))
        // Every word index and every bigram index is in range: 256 of each.
        XCTAssertEqual(Smaz2.decompress([0x06, 0xFF]), "still")
        XCTAssertEqual(Smaz2.decompress([0xFF]), "ty")
        XCTAssertEqual(Smaz2.decompress([0x08, 0x00]), " that")
        XCTAssertEqual(Smaz2.decompress([0x07, 0x01]), "this ")
    }

    func testTablesAreComplete() {
        XCTAssertEqual(Smaz2.bigrams.count, 256)
        XCTAssertEqual(Smaz2.words.count, 256)
    }
}

final class CannedCodebookTests: XCTestCase {
    func testDefaultCodebookHas30Entries() {
        XCTAssertEqual(CannedCodebook.defaultEntries.count, 30)
    }

    func testEncodeProducesTwoByteFrame() {
        XCTAssertEqual(CannedCodebook.encode(1), [0xCA, 1])
    }

    func testDecodeAll30() throws {
        XCTAssertEqual(try CannedCodebook.default.decode([0xCA, 1]), "Copy.")
        for id in 1...30 {
            let text = try CannedCodebook.default.decode(CannedCodebook.encode(id))
            XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty, "id \(id)")
        }
        XCTAssertEqual(try CannedCodebook.decodeDefault([0xCA, 25]), "SOS \u{2014} need immediate help.")
    }

    func testReverseLookup() {
        XCTAssertEqual(CannedCodebook.default.lookupByText("SOS \u{2014} need immediate help."), 25)
        XCTAssertNil(CannedCodebook.default.lookupByText("this is not a canned message"))
        XCTAssertEqual(CannedCodebook.lookupByTextDefault("Roger."), 2)
    }

    func testIsCannedAndErrors() {
        XCTAssertTrue(CannedCodebook.isCanned([0xCA, 5]))
        XCTAssertFalse(CannedCodebook.isCanned([0x50, 0x01]))
        XCTAssertThrowsError(try CannedCodebook.decodeDefault([0xCA]))
        XCTAssertThrowsError(try CannedCodebook.decodeDefault([0x50, 1]))
        XCTAssertThrowsError(try CannedCodebook.decodeDefault([0xCA, 99]))
    }

    func testKnownMessages() {
        XCTAssertEqual(CannedCodebook.defaultEntries[1], "Copy.")
        XCTAssertEqual(CannedCodebook.defaultEntries[2], "Roger.")
        XCTAssertEqual(CannedCodebook.defaultEntries[3], "Negative.")
    }
}
