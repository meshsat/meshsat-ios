import MeshSatWire
import XCTest

final class BytesTests: XCTestCase {
    func testHexRoundTrip() {
        let bytes: [UInt8] = [0x00, 0x7F, 0x80, 0xFF, 0x0A]
        XCTAssertEqual(Hex.encode(bytes), "007f80ff0a")
        XCTAssertEqual(Hex.decode("007F80FF0a"), bytes)
        XCTAssertNil(Hex.decode("abc"))
        XCTAssertNil(Hex.decode("zz"))
    }

    func testBase64Variants() {
        let bytes: [UInt8] = [0xFB, 0xFF, 0xBF, 0x3E]
        XCTAssertEqual(Base64Std.encode(bytes), "+/+/Pg==")
        XCTAssertEqual(Base64Url.encode(bytes), "-_-_Pg")
        XCTAssertEqual(Base64Url.decode("-_-_Pg"), bytes)
        XCTAssertEqual(Base64Url.decode("+/+/Pg=="), bytes)
        // android.util.Base64.DEFAULT tolerates line breaks
        XCTAssertEqual(Base64Std.decode("+/+/\nPg=="), bytes)
    }

    func testIntegerViews() {
        let bytes: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        XCTAssertEqual(bytes.uint16BE(at: 0), 0x0102)
        XCTAssertEqual(bytes.uint16LE(at: 0), 0x0201)
        XCTAssertEqual(bytes.uint32BE(at: 0), 0x0102_0304)
        XCTAssertNil(bytes.uint32BE(at: 1))
        XCTAssertEqual(UInt16(0x0102).bytesBE, [0x01, 0x02])
        XCTAssertEqual(UInt32(0x0102_0304).bytesBE, bytes)
    }
}
