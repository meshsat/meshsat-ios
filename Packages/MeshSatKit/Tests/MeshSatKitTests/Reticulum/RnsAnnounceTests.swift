// The announce data format and its signature, as RnsAnnounceHandler and stock RNS check it.
import XCTest

@testable import MeshSatCrypto
@testable import MeshSatReticulum

final class RnsAnnounceTests: XCTestCase {
    func testCreateMarshalUnmarshalVerify() throws {
        let id = Identity.generate()
        let appData = MeshSatAppData.encode(
            deviceType: MeshSatAppData.deviceIos, capabilities: MeshSatAppData.capMesh | MeshSatAppData.capSatellite)
        let (announce, destHash) = RnsAnnounce.create(
            encryptionPub: id.encryptionPubRaw, signingPub: id.signingPubRaw, appData: appData, now: 1_758_700_000, sign: { id.sign($0) })
        XCTAssertEqual(destHash, RnsDestination.computeDestHash(encryptionPub: id.encryptionPubRaw, signingPub: id.signingPubRaw))
        XCTAssertEqual(announce.randomHash.count, 10)
        // Bytes 5..8 are the timestamp big-endian, byte 9 its top nibble (Android's layout).
        XCTAssertEqual(Array(announce.randomHash[5..<9]), [0x68, 0xD3, 0xA1, 0xE0])
        XCTAssertEqual(announce.randomHash[9], 0x06)
        let wire = announce.marshal()
        XCTAssertEqual(wire.count, RnsAnnounce.minSize + 2)
        let parsed = try RnsAnnounce.unmarshal(wire)
        XCTAssertEqual(parsed, announce)
        XCTAssertTrue(parsed.verify(destHash: destHash))
        XCTAssertFalse(parsed.verify(destHash: [UInt8](repeating: 0, count: 16)))
        var tampered = parsed
        tampered.appData = [0x03, 0x00]
        XCTAssertFalse(tampered.verify(destHash: destHash), "app data is under the signature")
        XCTAssertEqual(parsed.announceHash(destHash: destHash).count, 16)
        XCTAssertEqual(MeshSatAppData.decode(parsed.appData ?? []), MeshSatAppData.Decoded(deviceType: 0x02, capabilities: 0x03))
        XCTAssertNil(MeshSatAppData.decode([1]))
        XCTAssertEqual(MeshSatAppData.capTransportNode, 0x20)
    }

    func testAnnounceInAPacketIsUnderTheMtu() {
        let id = Identity.generate()
        let (announce, destHash) = RnsAnnounce.create(
            encryptionPub: id.encryptionPubRaw, signingPub: id.signingPubRaw, appData: [0x02, 0x3F], sign: { id.sign($0) })
        let packet = RnsPacket.announce(destHash: destHash, announceData: announce.marshal())
        XCTAssertEqual(packet.wireSize(), 18 + 150)
        XCTAssertTrue(RnsPacket.validateSize(packet))
    }

    func testTooShortIsRefused() {
        XCTAssertThrowsError(try RnsAnnounce.unmarshal([UInt8](repeating: 0, count: 147)))
        XCTAssertThrowsError(try RnsAnnounce.unmarshal([UInt8](repeating: 0, count: 150), hasRatchet: true))
        XCTAssertNoThrow(try RnsAnnounce.unmarshal([UInt8](repeating: 0, count: 158), hasRatchet: true))
    }
}
