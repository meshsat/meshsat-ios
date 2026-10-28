// Mirrors rns/GoldenVectorTest.kt ("msgpack re-encodes umsgpack output byte for byte") and the
// Bridge's TestGolden_MsgpackMatchesUmsgpack: the codec writes what RNS.vendor.umsgpack writes.
import MeshSatWire
import XCTest

@testable import MeshSatRns

final class MsgpackTests: XCTestCase {
    /// The value of the Bridge's TestGolden_MsgpackMatchesUmsgpack, built here by hand.
    private var goValue: MpValue {
        .array([
            .float(1_758_814_000.123), .bin(Array("title".utf8)), .bin([UInt8](repeating: UInt8(ascii: "x"), count: 300)),
            .map([
                MpEntry(.int(1), .str("hello")),
                MpEntry(.int(0x10), .array([.int(-5), .int(200), .int(70000), .int(-200), .bool(true), .null])),
            ]),
            .int(5_000_000_000), .int(-5_000_000_000), .str(String(repeating: "s", count: 40)),
        ])
    }

    func testGoVectorPacksAndRoundTrips() throws {
        let go = try Vectors.go()
        let packed = try go.hex("msgpack_go")
        XCTAssertEqual(Msgpack.pack(goValue), packed, "the Go encoder's bytes")
        let (back, n) = try Msgpack.unpack(packed)
        XCTAssertEqual(n, packed.count)
        XCTAssertEqual(back, goValue)
        XCTAssertEqual(Msgpack.pack(back), packed)
    }

    func testPythonComplexValueReEncodesByteForByte() throws {
        let g = try Vectors.golden()
        let packed = try g.hex("msgpack.complex")
        let (v, n) = try Msgpack.unpack(packed)
        XCTAssertEqual(n, packed.count)
        XCTAssertEqual(Msgpack.pack(v), packed)
        let items = try XCTUnwrap(v.asArray)
        XCTAssertEqual(items.count, 16)
        XCTAssertEqual(items[7], .uint64(UInt64.max))
        XCTAssertEqual(items[8], .int(-(1 << 40)))
        XCTAssertNil(items[7].asInt, "a uint64 above Int64.max is not an int")
        // float32 decodes to a double and re-encodes as float64, as umsgpack does.
        let f32 = try g.hex("msgpack.float32")
        XCTAssertEqual(Msgpack.pack(try Msgpack.unpack(f32).value), try g.hex("msgpack.float32_reencoded"))
        XCTAssertEqual(try Msgpack.unpack(f32).value, .float(1.5))
    }

    func testIntegerEncodingsAtTheBoundaries() throws {
        let cases: [(Int64, [UInt8])] = [
            (0, [0x00]), (127, [0x7F]), (128, [0xCC, 0x80]), (255, [0xCC, 0xFF]), (256, [0xCD, 0x01, 0x00]),
            (65535, [0xCD, 0xFF, 0xFF]), (65536, [0xCE, 0x00, 0x01, 0x00, 0x00]),
            (4_294_967_295, [0xCE, 0xFF, 0xFF, 0xFF, 0xFF]), (4_294_967_296, [0xCF, 0, 0, 0, 1, 0, 0, 0, 0]),
            (-1, [0xFF]), (-32, [0xE0]), (-33, [0xD0, 0xDF]), (-128, [0xD0, 0x80]), (-129, [0xD1, 0xFF, 0x7F]),
            (-32768, [0xD1, 0x80, 0x00]), (-32769, [0xD2, 0xFF, 0xFF, 0x7F, 0xFF]),
            (-2_147_483_648, [0xD2, 0x80, 0, 0, 0]), (-2_147_483_649, [0xD3, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F, 0xFF, 0xFF, 0xFF]),
            (Int64.max, [0xCF, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
            (Int64.min, [0xD3, 0x80, 0, 0, 0, 0, 0, 0, 0]),
        ]
        for (i, want) in cases {
            XCTAssertEqual(Msgpack.pack(.int(i)), want, "\(i)")
            let (back, n) = try Msgpack.unpack(want)
            XCTAssertEqual(back, .int(i), "\(i) back")
            XCTAssertEqual(n, want.count)
        }
        XCTAssertEqual(Msgpack.pack(.uint64(UInt64.max)), [0xCF] + [UInt8](repeating: 0xFF, count: 8))
        XCTAssertEqual(try Msgpack.unpack([0xCF, 0x80, 0, 0, 0, 0, 0, 0, 0]).value, .uint64(1 << 63))
    }

    func testStringBinArrayAndMapLengthPrefixes() throws {
        let s31 = String(repeating: "a", count: 31)
        XCTAssertEqual(Msgpack.pack(.str(s31)).prefix(1), [0xBF])
        XCTAssertEqual(Msgpack.pack(.str(s31 + "a")).prefix(2), [0xD9, 32])
        XCTAssertEqual(Msgpack.pack(.str(String(repeating: "a", count: 256))).prefix(3), [0xDA, 0x01, 0x00])
        XCTAssertEqual(Msgpack.pack(.str(String(repeating: "a", count: 65536))).prefix(5), [0xDB, 0, 1, 0, 0])
        XCTAssertEqual(Msgpack.pack(.str("")), [0xA0])
        XCTAssertEqual(Msgpack.pack(.str("é")), [0xA2, 0xC3, 0xA9], "str length counts UTF-8 bytes")
        XCTAssertEqual(Msgpack.pack(.bin([])), [0xC4, 0])
        XCTAssertEqual(Msgpack.pack(.bin([UInt8](repeating: 1, count: 256))).prefix(3), [0xC5, 0x01, 0x00])
        XCTAssertEqual(Msgpack.pack(.bin([UInt8](repeating: 1, count: 65536))).prefix(5), [0xC6, 0, 1, 0, 0])
        XCTAssertEqual(Msgpack.pack(.array([UInt8](repeating: 0, count: 15).map { .int(Int64($0)) })).prefix(1), [0x9F])
        XCTAssertEqual(Msgpack.pack(.array([UInt8](repeating: 0, count: 16).map { .int(Int64($0)) })).prefix(3), [0xDC, 0, 16])
        let map15 = (0..<15).map { MpEntry(.int(Int64($0)), .null) }
        XCTAssertEqual(Msgpack.pack(.map(map15)).prefix(1), [0x8F])
        XCTAssertEqual(Msgpack.pack(.map(map15 + [MpEntry(.int(15), .null)])).prefix(3), [0xDE, 0, 16])
        XCTAssertEqual(Msgpack.pack(.null), [0xC0])
        XCTAssertEqual(Msgpack.pack(.bool(false)), [0xC2])
        XCTAssertEqual(Msgpack.pack(.float(0.734)), [0xCB, 0x3F, 0xE7, 0x7C, 0xED, 0x91, 0x68, 0x72, 0xB0], "rtt.packed_0_734")
        for v: MpValue in [.str(s31 + "a"), .bin([UInt8](repeating: 1, count: 300)), .map(map15 + [MpEntry(.str("k"), .float(1))])] {
            let packed = Msgpack.pack(v)
            XCTAssertEqual(try Msgpack.unpack(packed).value, v)
        }
    }

    func testExtValuesSurviveVerbatim() throws {
        let fixext1: [UInt8] = [0xD4, 0x01, 0xAA]
        let ext8: [UInt8] = [0xC7, 0x02, 0x05, 0x01, 0x02]
        let packed = Msgpack.pack(.array([.ext(fixext1), .ext(ext8)]))
        XCTAssertEqual(packed, [0x92] + fixext1 + ext8)
        XCTAssertEqual(try Msgpack.unpack(packed).value, .array([.ext(fixext1), .ext(ext8)]))
    }

    func testMalformedInputIsRefused() {
        XCTAssertThrowsError(try Msgpack.unpack([]))
        XCTAssertThrowsError(try Msgpack.unpack([0xC4, 5, 1, 2]), "truncated bin")
        XCTAssertThrowsError(try Msgpack.unpack([0x92, 0x01]), "truncated array")
        XCTAssertThrowsError(try Msgpack.unpack([0xC1]), "0xC1 is never used")
        XCTAssertThrowsError(try Msgpack.unpack([0xCB, 0, 0]), "truncated float")
        XCTAssertThrowsError(try Msgpack.unpack([0xC6, 0xFF, 0xFF, 0xFF, 0xFF]), "length above 2^31")
    }

    func testMapLookupsAndHelpers() {
        let m = MpValue.map([MpEntry(.int(1), .str("one")), MpEntry(.str("k"), .bin([7])), MpEntry(.int(0xFB), .int(3))])
        XCTAssertEqual(m[1], .str("one"))
        XCTAssertEqual(m["k"], .bin([7]))
        XCTAssertNil(m[2])
        XCTAssertNil(m["one"])
        XCTAssertEqual(m[0xFB]?.asInt, 3)
        XCTAssertEqual(MpValue.str("ab").asBytes, [0x61, 0x62])
        XCTAssertEqual(MpValue.bin([1]).asBytes, [1])
        XCTAssertNil(MpValue.int(1).asBytes)
        XCTAssertEqual(MpValue.fields([(5, .null)]), [MpEntry(.int(5), .null)])
    }
}
