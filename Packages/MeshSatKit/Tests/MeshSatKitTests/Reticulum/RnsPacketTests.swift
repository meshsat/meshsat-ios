// Ports RnsPacketTest.kt and RnsHdlcTest.kt: the Reticulum wire format and HDLC framing.
import XCTest

@testable import MeshSatReticulum

final class RnsPacketTests: XCTestCase {
    private let zero16 = [UInt8](repeating: 0, count: 16)

    func testFlagsEncodeAndDecodeRoundTrip() {
        let packet = RnsPacket.data(destHash: zero16, payload: [], destType: RnsConstants.destSingle)
        let flags = packet.encodeFlags()
        XCTAssertEqual(flags, 0x00)
        let decoded = RnsPacket.decodeFlags(flags)
        XCTAssertEqual(decoded.headerType, RnsConstants.header1)
        XCTAssertFalse(decoded.contextFlag)
        XCTAssertEqual(decoded.propagationType, RnsConstants.propagationBroadcast)
        XCTAssertEqual(decoded.destType, RnsConstants.destSingle)
        XCTAssertEqual(decoded.packetType, RnsConstants.packetData)
    }

    func testFlagsPerPacketKind() {
        XCTAssertEqual(RnsPacket.announce(destHash: zero16, announceData: []).encodeFlags(), 0x01)
        XCTAssertEqual(RnsPacket.linkRequest(destHash: zero16, requestData: []).encodeFlags(), 0x02)
        XCTAssertEqual(RnsPacket.proof(destHash: zero16, proofData: []).encodeFlags(), 0x03)
        XCTAssertEqual(RnsPacket.data(destHash: zero16, payload: [], destType: RnsConstants.destLink).encodeFlags(), 0x0C)
        XCTAssertEqual(RnsPacket.data(destHash: zero16, payload: [], context: RnsConstants.ctxChannel).encodeFlags(), 0x20)
        let transport = RnsPacket.wrapForTransport(RnsPacket.data(destHash: zero16, payload: []), transportId: zero16)
        XCTAssertEqual(transport.encodeFlags(), 0x50)
        let all = RnsPacket.decodeFlags(0xFF)
        XCTAssertEqual(all.headerType, 0x03)
        XCTAssertTrue(all.contextFlag)
        XCTAssertEqual(all.propagationType, 1)
        XCTAssertEqual(all.destType, 0x03)
        XCTAssertEqual(all.packetType, 0x03)
    }

    func testHeader1DataPacketRoundTrip() throws {
        let destHash = (1...16).map { UInt8($0) }
        let payload = Array("hello reticulum".utf8)
        let wire = RnsPacket.data(destHash: destHash, payload: payload).marshal()
        XCTAssertEqual(wire.count, 33)
        XCTAssertEqual(wire[0], 0x00)
        XCTAssertEqual(wire[1], 0x00)
        let parsed = try RnsPacket.unmarshal(wire)
        XCTAssertEqual(parsed.headerType, RnsConstants.header1)
        XCTAssertEqual(parsed.packetType, RnsConstants.packetData)
        XCTAssertEqual(parsed.destType, RnsConstants.destSingle)
        XCTAssertEqual(parsed.hops, 0)
        XCTAssertNil(parsed.transportId)
        XCTAssertEqual(parsed.destHash, destHash)
        XCTAssertEqual(parsed.data, payload)
    }

    func testHeader1WithContextByteRoundTrip() throws {
        let destHash = [UInt8](repeating: 0xAA, count: 16)
        let wire = RnsPacket.data(destHash: destHash, payload: [1, 2, 3], context: RnsConstants.ctxKeepalive).marshal()
        XCTAssertEqual(wire.count, 22)
        let parsed = try RnsPacket.unmarshal(wire)
        XCTAssertTrue(parsed.contextFlag)
        XCTAssertEqual(parsed.context, RnsConstants.ctxKeepalive)
        XCTAssertEqual(parsed.data, [1, 2, 3])
    }

    func testHeader2TransportPacketRoundTrip() throws {
        let destHash = (0..<16).map { UInt8($0) }
        let transportId = (0..<16).map { UInt8(0xFF - $0) }
        let payload = Array("routed data".utf8)
        let transport = RnsPacket.wrapForTransport(RnsPacket.data(destHash: destHash, payload: payload), transportId: transportId)
        let wire = transport.marshal()
        XCTAssertEqual(wire.count, 45)
        let parsed = try RnsPacket.unmarshal(wire)
        XCTAssertEqual(parsed.headerType, RnsConstants.header2)
        XCTAssertEqual(parsed.propagationType, RnsConstants.propagationTransport)
        XCTAssertEqual(parsed.transportId, transportId)
        XCTAssertEqual(parsed.destHash, destHash)
        XCTAssertEqual(parsed.data, payload)
    }

    func testAnnouncePacketRoundTripAndHops() throws {
        let destHash = (0..<16).map { UInt8(($0 * 3) & 0xFF) }
        let announceData = (0..<148).map { UInt8($0 & 0xFF) }
        let packet = RnsPacket.announce(destHash: destHash, announceData: announceData)
        XCTAssertEqual(packet.hops, 0)
        let parsed = try RnsPacket.unmarshal(packet.marshal())
        XCTAssertEqual(parsed.packetType, RnsConstants.packetAnnounce)
        XCTAssertEqual(parsed.data, announceData)
        for hops in [7, 255] {
            var p = RnsPacket.data(destHash: zero16, payload: [0x42])
            p.hops = hops
            XCTAssertEqual(try RnsPacket.unmarshal(p.marshal()).hops, hops)
        }
        XCTAssertEqual(try RnsPacket.unmarshal(RnsPacket.data(destHash: zero16, payload: []).marshal()).data.count, 0)
    }

    func testSizes() {
        XCTAssertTrue(RnsPacket.validateSize(RnsPacket.data(destHash: zero16, payload: [UInt8](repeating: 0, count: RnsConstants.mdu))))
        XCTAssertFalse(RnsPacket.validateSize(RnsPacket.data(destHash: zero16, payload: [UInt8](repeating: 0, count: RnsConstants.mtu))))
        XCTAssertThrowsError(try RnsPacket.unmarshal([UInt8](repeating: 0, count: 5)))
        XCTAssertEqual(RnsPacket.data(destHash: zero16, payload: [UInt8](repeating: 0, count: 10)).wireSize(), 28)
        XCTAssertEqual(
            RnsPacket.data(destHash: zero16, payload: [UInt8](repeating: 0, count: 10), context: RnsConstants.ctxResource).wireSize(), 29)
        XCTAssertEqual(
            RnsPacket.wrapForTransport(RnsPacket.data(destHash: zero16, payload: [UInt8](repeating: 0, count: 10)), transportId: zero16)
                .wireSize(),
            44)
        XCTAssertEqual(RnsConstants.mtu, 500)
        XCTAssertEqual(RnsConstants.mdu, 464)
        XCTAssertEqual(RnsConstants.encryptedMdu, 383)
        XCTAssertEqual(RnsConstants.destHashLen, 16)
        XCTAssertEqual(RnsConstants.headerMinSize, 19)
        XCTAssertEqual(RnsConstants.headerMaxSize, 35)
    }

    func testDestinationHashes() {
        let encPub = [UInt8](repeating: 0x01, count: 32)
        let sigPub = [UInt8](repeating: 0x02, count: 32)
        let hash = RnsDestination.computeDestHash(encryptionPub: encPub, signingPub: sigPub)
        XCTAssertEqual(hash.count, 16)
        XCTAssertEqual(hash, RnsDestination.computeDestHash(encryptionPub: encPub, signingPub: sigPub))
        XCTAssertNotEqual(
            hash,
            RnsDestination.computeDestHash(encryptionPub: [UInt8](repeating: 3, count: 32), signingPub: [UInt8](repeating: 4, count: 32)))
        XCTAssertNotEqual(
            RnsDestination.computeDestHash(encryptionPub: encPub, signingPub: sigPub, appName: "meshsat", aspects: ["node"]),
            RnsDestination.computeDestHash(encryptionPub: encPub, signingPub: sigPub, appName: "meshsat", aspects: ["message"]))
        XCTAssertEqual(RnsDestination.nameHash("meshsat", "node").count, 10)
        XCTAssertEqual(RnsDestination.nameHash("meshsat", "node"), RnsDestination.nameHash("meshsat", "node"))
        let idHash = RnsDestination.identityHash(
            encryptionPub: [UInt8](repeating: 0xAA, count: 32), signingPub: [UInt8](repeating: 0xBB, count: 32))
        XCTAssertEqual(idHash.count, 16)
        XCTAssertNotEqual(
            idHash,
            RnsDestination.identityHash(encryptionPub: [UInt8](repeating: 0xBB, count: 32), signingPub: [UInt8](repeating: 0xAA, count: 32))
        )
        XCTAssertEqual(RnsDestination.expandName("meshsat"), "meshsat")
        XCTAssertEqual(RnsDestination.expandName("meshsat", "node"), "meshsat.node")
        XCTAssertEqual(RnsDestination.expandName("meshsat", "node", "status"), "meshsat.node.status")
        XCTAssertEqual(RnsDestination.computePlainDestHash("meshsat", "broadcast").count, 16)
        XCTAssertEqual(
            RnsDestination.computePlainDestHash("meshsat", "broadcast"), RnsDestination.computePlainDestHash("meshsat", "broadcast"))
        XCTAssertEqual(RnsDestination.truncatedHash([1, 2, 3]).count, 16)
        XCTAssertEqual(RnsDestination.fullHash([1, 2, 3]).count, 32)
        XCTAssertEqual(RnsDestination.randomHash().count, 16)
        XCTAssertEqual(RnsDestination.ratchetId((0..<32).map { UInt8($0) }).count, 10)
    }

    /// The name hash and destination hash of a known identity, from Python RNS semantics:
    /// SHA-256("meshsat.node")[:10] is fixed, so the value pins the expansion and truncation.
    func testNameHashIsSha256OfTheDottedName() {
        let expected = Array(RnsDestination.fullHash(Array("meshsat.node".utf8)).prefix(10))
        XCTAssertEqual(RnsDestination.nameHash("meshsat", "node"), expected)
    }
}

final class RnsHdlcTests: XCTestCase {
    func testEscape() {
        XCTAssertEqual(RnsHdlc.escape([0x01, 0x02, 0x03]), [0x01, 0x02, 0x03])
        XCTAssertEqual(RnsHdlc.escape([0x7E]), [0x7D, 0x5E])
        XCTAssertEqual(RnsHdlc.escape([0x7D]), [0x7D, 0x5D])
        XCTAssertEqual(RnsHdlc.escape([0x7E, 0x7D]), [0x7D, 0x5E, 0x7D, 0x5D])
        XCTAssertEqual(RnsHdlc.escape([0x01, 0x7E, 0x02, 0x7D, 0x03]), [0x01, 0x7D, 0x5E, 0x02, 0x7D, 0x5D, 0x03])
        XCTAssertEqual(RnsHdlc.escape([]), [])
        XCTAssertEqual(RnsHdlc.escape([0x7E, 0x7D, 0x7E, 0x7D]).count, 8)
    }

    func testUnescape() {
        XCTAssertEqual(RnsHdlc.unescape([0x01, 0x02, 0x03]), [0x01, 0x02, 0x03])
        XCTAssertEqual(RnsHdlc.unescape([0x7D, 0x5E]), [0x7E])
        XCTAssertEqual(RnsHdlc.unescape([0x7D, 0x5D]), [0x7D])
        XCTAssertEqual(RnsHdlc.unescape([]), [])
    }

    func testRoundTrips() {
        let cases: [[UInt8]] = [
            Array("Hello Reticulum".utf8), (0..<256).map { UInt8($0) }, [UInt8](repeating: 0x7E, count: 10),
            [UInt8](repeating: 0x7D, count: 10),
            (0..<500).map { UInt8($0 % 256) },
        ]
        for original in cases {
            XCTAssertEqual(RnsHdlc.unescape(RnsHdlc.escape(original)), original)
        }
    }

    func testConstants() {
        XCTAssertEqual(RnsHdlc.flag, 0x7E)
        XCTAssertEqual(RnsHdlc.esc, 0x7D)
        XCTAssertEqual(RnsHdlc.escMask, 0x20)
        XCTAssertEqual(RnsHdlc.headerMinSize, 19)
    }

    func testDeframerFindsFramesAcrossReads() {
        let packet = (0..<40).map { UInt8($0 == 5 ? 0x7E : $0) }
        let wire = RnsHdlc.frame(packet) + RnsHdlc.frame(packet)
        var d = RnsHdlc.Deframer()
        var frames: [[UInt8]] = []
        for chunk in stride(from: 0, to: wire.count, by: 7) {
            frames += d.feed(Array(wire[chunk..<min(chunk + 7, wire.count)]))
        }
        XCTAssertEqual(frames, [packet, packet])
        // A short frame (fewer than 19 bytes) is dropped, as Android's read loop drops it.
        XCTAssertEqual(d.feed(RnsHdlc.frame([1, 2, 3])), [])
    }
}
