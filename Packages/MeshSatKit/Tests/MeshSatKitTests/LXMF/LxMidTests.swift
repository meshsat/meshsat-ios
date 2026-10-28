// Mirrors the Bridge's internal/lxmf/mid_test.go and the mid rows of LxmfRouterTest.kt: the
// fields map is the HeMB-NG fixture's bytes both ways (contract C2). [MESHSAT-1641]
import Foundation
import MeshSatWire
import XCTest

@testable import MeshSatHub
@testable import MeshSatLXMF
@testable import MeshSatRns

final class LxMidTests: XCTestCase {
    private func fixture() throws -> (fieldsHex: String, mid: String) {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "lxmf_mid_field", withExtension: "json", subdirectory: "Fixtures/hemb-ng/v1"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return (try XCTUnwrap(obj["fields_msgpack_hex"] as? String), try XCTUnwrap(obj["mid"] as? String))
    }

    func testMidFieldsAreTheFixtureBytes() throws {
        let (fieldsHex, midText) = try fixture()
        let mid = try XCTUnwrap(LxMid.parse(midText))
        XCTAssertEqual(Hex.encode(Msgpack.pack(.map(LxMid.fields(mid)))), fieldsHex)
        let raw = try XCTUnwrap(Hex.decode(fieldsHex))
        let (v, n) = try Msgpack.unpack(raw)
        XCTAssertEqual(n, raw.count)
        let got = try XCTUnwrap(LxMid.midOf(try XCTUnwrap(v.asMap)))
        XCTAssertEqual(LxMid.format(got), midText)
        XCTAssertEqual(HubMsgIds.parseCanonical(midText), mid, "the Hub's parser reads the same bytes")
    }

    func testWithMidNeverOverwritesAnotherCustomType() throws {
        var mid = [UInt8](repeating: 0, count: 16)
        mid[0] = 1
        let other: [MpEntry] = [
            MpEntry(.int(LxMid.fieldCustomType), .str("someone.else/2")), MpEntry(.int(LxMid.fieldCustomData), .bin(Array("theirs".utf8))),
        ]
        XCTAssertEqual(LxMid.withMid(other, mid), other, "another custom type was overwritten")
        XCTAssertNil(LxMid.midOf(other), "another custom type read as a mid")
        let dataOnly = [MpEntry(.int(LxMid.fieldCustomData), .bin([0]))]
        XCTAssertEqual(LxMid.withMid(dataOnly, mid).count, 1, "custom data without a type was overwritten")
        // Other fields stay, in order, and the mid follows them.
        let plain = [MpEntry(.int(0x01), .str("e"))]
        let got = LxMid.withMid(plain, mid)
        XCTAssertEqual(got.count, 3)
        XCTAssertEqual(got[0], plain[0])
        XCTAssertEqual(LxMid.midOf(got), mid)
        XCTAssertEqual(LxMid.withMid([], mid), LxMid.fields(mid))
        let short: [MpEntry] = [
            MpEntry(.int(LxMid.fieldCustomType), .str(LxMid.type)),
            MpEntry(.int(LxMid.fieldCustomData), .bin([UInt8](repeating: 0, count: 15))),
        ]
        XCTAssertNil(LxMid.midOf(short), "a 15-byte mid was taken")
        let typeAsBytes: [MpEntry] = [
            MpEntry(.int(LxMid.fieldCustomType), .bin(Array(LxMid.type.utf8))), MpEntry(.int(LxMid.fieldCustomData), .bin(mid)),
        ]
        XCTAssertNil(LxMid.midOf(typeAsBytes), "the type is a str, as the Bridge and the fixture write it")
        XCTAssertNil(LxMid.midOf([]))
    }

    func testParseAndFormat() {
        for bad in ["", "01a14f3166807a0b8c0d0e0f10111213", "01a14f31-6680-7a0b-8c0d-0e0f1011121z", "01a14f31-6680-7a0b-8c0d0-e0f10111213"]
        {
            XCTAssertNil(LxMid.parse(bad), bad)
        }
        let m = LxMid.parse("01A14F31-6680-7A0B-8C0D-0E0F10111213")
        XCTAssertEqual(m.map(LxMid.format), "01a14f31-6680-7a0b-8c0d-0e0f10111213")
        XCTAssertEqual(LxMid.format([1, 2]), "0102", "not a mid, plain hex")
    }

    func testANewMidIsAUUIDv7TheHubAccepts() {
        let a = LxMid.newMid(nowMs: 1_761_685_200_500)
        let b = LxMid.newMid(nowMs: 1_761_685_200_500)
        XCTAssertEqual(a.count, 16)
        XCTAssertNotEqual(a, b, "random tail")
        XCTAssertEqual(Array(a.prefix(6)), Array(b.prefix(6)), "the millisecond prefix")
        XCTAssertEqual(a[6] >> 4, 7)
        XCTAssertEqual(a[8] >> 6, 2)
        XCTAssertTrue(HubMsgIds.validV7(LxMid.format(a)))
        XCTAssertEqual(LxMid.parse(LxMid.format(a)), a)
        XCTAssertEqual(LxMid.midOf(LxMid.fields(a)), a)
    }
}
