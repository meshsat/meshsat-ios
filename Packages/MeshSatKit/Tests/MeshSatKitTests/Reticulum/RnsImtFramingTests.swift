// Mirrors ImtFramingTest.kt: CrossTalk's IMT framing, a packet is "RNSI" 0x01 + raw, a text is
// anything else; and the frame of the r34 review (R34-R1). [MESHSAT-1624]
import Foundation
import MeshSatReticulum
import MeshSatWire
import XCTest

final class RnsImtFramingTests: XCTestCase {
    /// A HEADER_1 data packet to 0x07 x 16, context none, data "payload": the bytes Android's
    /// ImtFramingTest packs with Header(destHash = 0x07 x 16, data = "payload").
    private let packet: [UInt8] = [0x00, 0x00] + [UInt8](repeating: 0x07, count: 16) + [0x00] + Array("payload".utf8)

    func testAFramedPacketRoundTripsAndTheHeaderIsCrossTalks() {
        let wire = RnsImtFraming.encode(packet)
        XCTAssertEqual(Array(wire.prefix(5)), [0x52, 0x4E, 0x53, 0x49, 0x01])
        XCTAssertEqual(RnsImtFraming.decode(wire), packet)
        XCTAssertTrue(RnsImtFraming.isFramed(wire))
    }

    /// The r34 review's input, byte for byte: 52 4e 53 49 01 | 00 00 | 07 x 16 | 00 | "payload".
    func testTheReviewsFrameIsAPacket() {
        let review = Hex.decode("524e534901" + "0000" + String(repeating: "07", count: 16) + "00" + "7061796c6f6164") ?? []
        XCTAssertEqual(review.count, 5 + 2 + 16 + 1 + 7)
        XCTAssertTrue(RnsImtFraming.isFramed(review))
    }

    func testTextsStayTextsEvenOnesThatStartWithTheMagic() {
        XCTAssertNil(RnsImtFraming.decode(Array("hello from the park, 30 bytes of text".utf8)))
        XCTAssertNil(RnsImtFraming.decode(Array("RNSI\u{01}".utf8)), "nothing after the header")
        XCTAssertNil(RnsImtFraming.decode(Array("RNSI\u{02}".utf8) + packet), "another version")
        XCTAssertNil(RnsImtFraming.decode(Array("RNSI is the name of our club tonight".utf8)), "no packet behind the magic")
        XCTAssertFalse(RnsImtFraming.isFramed([]))
    }

    /// Header.unpack's limits: no data after the context byte, a hop count at PATHFINDER_M, and a
    /// HEADER_2 packet shorter than its two hashes are not packets.
    func testWhatAndroidsHeaderUnpackRefusesIsNotAFrame() {
        XCTAssertFalse(RnsImtFraming.isFramed(RnsImtFraming.encode(Array(packet.prefix(19)))), "empty data")
        var hops = packet
        hops[1] = 128
        XCTAssertFalse(RnsImtFraming.isFramed(RnsImtFraming.encode(hops)), "hops at PATHFINDER_M")
        hops[1] = 127
        XCTAssertTrue(RnsImtFraming.isFramed(RnsImtFraming.encode(hops)))
        var header2 = packet
        header2[0] = 0x40
        XCTAssertFalse(RnsImtFraming.isFramed(RnsImtFraming.encode(header2)), "HEADER_2 without room for both hashes")
        let full2: [UInt8] = [0x40, 0x00] + [UInt8](repeating: 0x01, count: 32) + [0x00, 0x2A]
        XCTAssertTrue(RnsImtFraming.isFramed(RnsImtFraming.encode(full2)))
    }
}
