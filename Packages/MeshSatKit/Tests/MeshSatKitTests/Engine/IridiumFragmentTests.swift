// Mirrors IridiumFragmentTest.kt, plus the SatelliteLimitsTest case the frame rule exists for:
// the first part of a two-part message starts with the protocol version byte.
import MeshSatEngine
import MeshSatWire
import XCTest

final class IridiumFragmentTests: XCTestCase {
    func testHeaderRoundtrip() {
        for (idx, total, id) in [(0, 1, 0), (0, 2, 5), (1, 2, 5), (3, 4, 15), (15, 16, 255), (0, 1, 128)] {
            let hdr = IridiumFragment.encodeHeader(fragIndex: idx, fragTotal: total, msgId: id)
            XCTAssertEqual(IridiumFragment.decodeHeader(hdr[0], hdr[1]), .init(fragIndex: idx, fragTotal: total, msgId: id))
        }
    }

    func testNoFragmentationForSmallOrExactMtu() {
        XCTAssertNil(IridiumFragment.fragment([UInt8](repeating: 0, count: 100), msgId: 0))
        XCTAssertNil(IridiumFragment.fragment([UInt8](repeating: 0, count: 340), msgId: 0))
    }

    func testTwoFragmentsFor500Bytes() throws {
        let data = (0..<500).map { UInt8($0 % 256) }
        let frags = try XCTUnwrap(IridiumFragment.fragment(data, msgId: 42))
        XCTAssertEqual(frags.count, 2)
        XCTAssertEqual(IridiumFragment.decodeHeader(frags[0][0], frags[0][1]), .init(fragIndex: 0, fragTotal: 2, msgId: 42))
        XCTAssertEqual(IridiumFragment.decodeHeader(frags[1][0], frags[1][1]), .init(fragIndex: 1, fragTotal: 2, msgId: 42))
        for f in frags { XCTAssertLessThanOrEqual(f.count, 340) }
    }

    func testReassemblyInOrderOutOfOrderDuplicatesAndIds() throws {
        let data = (0..<900).map { UInt8($0 % 256) }
        let frags = try XCTUnwrap(IridiumFragment.fragment(data, msgId: 10))
        XCTAssertEqual(frags.count, 3)
        let buf = IridiumFragment.ReassemblyBuffer()
        XCTAssertNil(try buf.addFragment(frags[0]))
        XCTAssertNil(try buf.addFragment(frags[1]))
        XCTAssertEqual(try buf.addFragment(frags[2]), data)

        let small = (0..<500).map { UInt8($0 % 256) }
        let two = try XCTUnwrap(IridiumFragment.fragment(small, msgId: 7))
        XCTAssertNil(try buf.addFragment(two[1]))
        XCTAssertEqual(try buf.addFragment(two[0]), small)

        let dup = try XCTUnwrap(IridiumFragment.fragment(small, msgId: 3))
        _ = try buf.addFragment(dup[0])
        _ = try buf.addFragment(dup[0])
        XCTAssertEqual(buf.pendingCount, 1)
        XCTAssertEqual(try buf.addFragment(dup[1]), small)

        let a = try XCTUnwrap(IridiumFragment.fragment([UInt8](repeating: 0xAA, count: 500), msgId: 10))
        let b = try XCTUnwrap(IridiumFragment.fragment([UInt8](repeating: 0xBB, count: 500), msgId: 11))
        _ = try buf.addFragment(a[0])
        _ = try buf.addFragment(b[0])
        XCTAssertEqual(buf.pendingCount, 2)
        XCTAssertEqual(try buf.addFragment(a[1]), [UInt8](repeating: 0xAA, count: 500))
        XCTAssertEqual(try buf.addFragment(b[1]), [UInt8](repeating: 0xBB, count: 500))
        XCTAssertThrowsError(try buf.addFragment([0x01]))
    }

    func testMaxFragmentTruncationAndExpiry() throws {
        let mtu = 100
        let payload = mtu - IridiumFragment.headerSize
        let maxData = IridiumFragment.maxFragments * payload
        let frags = try XCTUnwrap(IridiumFragment.fragment([UInt8](repeating: 0, count: maxData + 500), mtu: mtu, msgId: 0))
        XCTAssertEqual(frags.count, IridiumFragment.maxFragments)
        XCTAssertEqual(frags.reduce(0) { $0 + $1.count - IridiumFragment.headerSize }, maxData)

        let clock = TickClock()
        let buf = IridiumFragment.ReassemblyBuffer(maxAgeMs: 1000, now: { clock.now })
        _ = try buf.addFragment(frags[0])
        clock.now = 2000
        XCTAssertEqual(buf.expire(), 1)
        XCTAssertEqual(buf.pendingCount, 0)
    }

    func testTheFirstPartOfATwoPartMessageStartsWithTheVersionByte() throws {
        let parts = try XCTUnwrap(IridiumFragment.fragment([UInt8](repeating: 0x41, count: 400), msgId: 7))
        XCTAssertEqual(parts.count, 2)
        let versioned = ProtocolVersion.prependVersionByte([0x41])
        XCTAssertEqual(parts[0][0], versioned[0], "the collision the one-frame rule exists for")
        XCTAssertEqual(IridiumFragment.moMtu, SatelliteLimits.maxMoBytes)
    }
}
