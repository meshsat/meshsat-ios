// Mirrors lxmf/LxmfGoldenTest.kt: Python LXMF 1.2.0 wrote every vector (Android's
// scripts/rns-golden.py); the Swift side must read them. [MESHSAT-1735]
import MeshSatWire
import XCTest

@testable import MeshSatLXMF
@testable import MeshSatRns

final class LxmfGoldenTests: XCTestCase {
    func testAPythonMessageUnpacksVerifiesAndReHashesIdentically() throws {
        let g = try Vectors.golden()
        let src = try RnsIdentity.fromPrivateBytes(try g.hex("lxmf.src_prv"))
        let dst = try RnsIdentity.fromPrivateBytes(try g.hex("lxmf.dst_prv"))
        XCTAssertEqual(src.destHash(LxMessage.deliveryName), try g.hex("lxmf.src_dest"))
        XCTAssertEqual(dst.destHash(LxMessage.deliveryName), try g.hex("lxmf.dst_dest"))
        // The message went from dst to src.
        let dstDest = dst.destHash(LxMessage.deliveryName)
        let m = try LxMessage.unpack(try g.hex("lxmf.packed")) { source in source == dstDest ? dst.sigPubRaw : nil }
        XCTAssertEqual(m.hash, try g.hex("lxmf.hash"))
        XCTAssertTrue(m.sourceKnown)
        XCTAssertTrue(m.signatureValid)
        XCTAssertEqual(m.content, try g.hex("lxmf.content"))
        XCTAssertEqual(m.title, try g.hex("lxmf.title"))
        XCTAssertEqual(m.contentString, "reply from python")
        XCTAssertEqual(m.titleString, "re")
        XCTAssertEqual(m.timestamp, try g.double("lxmf.timestamp"))
        XCTAssertNil(m.stamp)
        XCTAssertEqual(m.fields, [])
        XCTAssertEqual(m.dest, try g.hex("lxmf.src_dest"))
        XCTAssertEqual(m.source, try g.hex("lxmf.dst_dest"))
        XCTAssertEqual(m.packedSize, try g.hex("lxmf.packed").count)
        // An unknown source leaves the signature unverified but the message intact.
        let u = try LxMessage.unpack(try g.hex("lxmf.packed")) { _ in nil }
        XCTAssertFalse(u.sourceKnown)
        XCTAssertFalse(u.signatureValid)
        XCTAssertEqual(u.hash, m.hash)
        let noLookup = try LxMessage.unpack(try g.hex("lxmf.packed"))
        XCTAssertFalse(noLookup.sourceKnown)
        // The wrong key is known but does not verify.
        let wrong = try LxMessage.unpack(try g.hex("lxmf.packed")) { _ in src.sigPubRaw }
        XCTAssertTrue(wrong.sourceKnown)
        XCTAssertFalse(wrong.signatureValid)
    }

    func testFieldsWithUnknownKeysAndAStampAtCost8Survive() throws {
        let g = try Vectors.golden()
        let dst = try RnsIdentity.fromPrivateBytes(try g.hex("lxmf.dst_prv"))
        let m = try LxMessage.unpack(try g.hex("lxmf2.packed")) { _ in dst.sigPubRaw }
        XCTAssertTrue(m.signatureValid)
        XCTAssertEqual(m.hash, try g.hex("lxmf2.hash"))
        XCTAssertEqual(m.stamp, try g.hex("lxmf2.stamp"))
        XCTAssertEqual(Msgpack.pack(.map(m.fields)), try g.hex("lxmf2.fields_packed"))
        XCTAssertEqual(m.fields.count, 3)
        XCTAssertNotNil(MpValue.map(m.fields)[0xAB], "unknown to us, kept")
        XCTAssertEqual(MpValue.map(m.fields)[0xAB], .str("unknown field"))
        XCTAssertEqual(MpValue.map(m.fields)[1], .bin([1, 2]))
        XCTAssertEqual(MpValue.map(m.fields)[LxMessage.fieldGroup]?["ty"], .int(1))
        XCTAssertEqual(m.contentString, "stamped")
        let wb = LxStamper.workblock(m.hash)
        XCTAssertEqual(wb.count, LxStamper.workblockExpandRounds * 256)
        XCTAssertEqual(Rns.sha256(wb), try g.hex("lxmf2.workblock_sha256"))
        let stamp = try XCTUnwrap(m.stamp)
        XCTAssertTrue(LxStamper.stampValid(workblock: wb, stamp: stamp, cost: try g.int("lxmf2.stamp_cost")))
        XCTAssertEqual(LxStamper.stampValue(workblock: wb, stamp: stamp), try g.int("lxmf2.stamp_value"))
        XCTAssertFalse(LxStamper.stampValid(workblock: wb, stamp: stamp, cost: 40))
        XCTAssertFalse(LxStamper.stampValid(workblock: wb, stamp: stamp, cost: 0))
        XCTAssertFalse(LxStamper.stampValid(workblock: wb, stamp: [], cost: 8))
    }

    func testAnnounceAppDataReadsAndWritesLikeLXMF() throws {
        let g = try Vectors.golden()
        let info = LxmfAppData.parse(try g.hex("lxmf.app_data"))
        XCTAssertEqual(info, LxmfAppData.Info(displayName: "MeshSat kit", stampCost: 8, compression: true, legacy: false))
        let none = LxmfAppData.parse(try g.hex("lxmf.app_data_noname"))
        XCTAssertNil(none.displayName)
        XCTAssertEqual(none.stampCost, 0)
        let legacy = LxmfAppData.parse(try g.hex("lxmf.app_data_legacy"))
        XCTAssertEqual(legacy.displayName, try g.str("lxmf.display_name_legacy"))
        XCTAssertTrue(legacy.legacy)
        XCTAssertEqual(LxmfAppData.encode(displayName: "MeshSat kit", stampCost: 8, compression: true), try g.hex("lxmf.app_data"))
        let ours = LxmfAppData.parse(LxmfAppData.encode(displayName: "Phone", stampCost: 0))
        XCTAssertEqual(ours.displayName, "Phone")
        XCTAssertEqual(ours.stampCost, 0)
        XCTAssertFalse(ours.compression)
        let peer = LxmfAppData.parse(try g.hex("announce.app_data"))
        XCTAssertEqual(peer.displayName, try g.str("announce.display_name"))
        XCTAssertEqual(peer.stampCost, try g.int("announce.stamp_cost"))
        XCTAssertEqual(LxmfAppData.parse(nil), LxmfAppData.Info())
        XCTAssertEqual(LxmfAppData.parse([]), LxmfAppData.Info())
        XCTAssertEqual(LxmfAppData.parse([0x93, 0xC0]), LxmfAppData.Info(), "truncated msgpack reads as nothing")
        XCTAssertNil(LxmfAppData.parse(LxmfAppData.encode(displayName: " \u{0}", stampCost: 300)).displayName)
        XCTAssertEqual(LxmfAppData.parse(LxmfAppData.encode(displayName: "x", stampCost: 255)).stampCost, 0, "255 is no cost")
    }

    func testOurOwnPackingRoundTripsAndSizesFollowLXMessage() throws {
        let src = RnsIdentity.generate()
        let dst = RnsIdentity.generate()
        var m = LxMessage(
            dest: dst.destHash(LxMessage.deliveryName), source: src.destHash(LxMessage.deliveryName), title: Array("hi".utf8),
            content: Array("hello from the phone".utf8))
        try m.pack(source: src)
        XCTAssertGreaterThan(m.timestamp, 1_700_000_000, "a zero timestamp becomes now")
        let back = try LxMessage.unpack(m.packed) { _ in src.sigPubRaw }
        XCTAssertTrue(back.signatureValid)
        XCTAssertEqual(back.hash, m.hash)
        XCTAssertEqual(back.contentString, "hello from the phone")
        XCTAssertEqual(LxMessage.encryptedPacketMaxContent, 287)
        XCTAssertEqual(LxMessage.linkPacketMaxContent, 319)
        XCTAssertEqual(LxMessage.overhead, 112)
        XCTAssertEqual(LxMessage.representation(forContentSize: 319), .packet)
        XCTAssertEqual(LxMessage.representation(forContentSize: 320), .resource)
        var stamped = LxMessage(
            dest: dst.destHash(LxMessage.deliveryName), source: src.destHash(LxMessage.deliveryName), content: Array("stamped".utf8))
        try stamped.pack(source: src, stampCost: 5) { h, c in LxStamper.generateStamp(messageId: h, cost: c)?.stamp }
        let sb = try LxMessage.unpack(stamped.packed) { _ in src.sigPubRaw }
        XCTAssertTrue(sb.signatureValid)
        XCTAssertEqual(sb.stamp?.count, LxStamper.stampSize)
        XCTAssertTrue(LxStamper.stampValid(workblock: LxStamper.workblock(sb.hash), stamp: try XCTUnwrap(sb.stamp), cost: 5))
        XCTAssertEqual(sb.hash, stamped.hash, "the stamp is outside the hash")
        // A stamper that gives up fails the pack.
        var failed = stamped
        XCTAssertThrowsError(try failed.pack(source: src, stampCost: 5) { _, _ in nil })
        XCTAssertThrowsError(try LxMessage.unpack([UInt8](repeating: 0, count: 96)), "too short")
        XCTAssertThrowsError(try LxMessage.unpack([UInt8](repeating: 0, count: 96) + [0xC1]), "bad msgpack")
        XCTAssertThrowsError(try LxMessage.unpack([UInt8](repeating: 0, count: 96) + [0x93, 1, 2, 3]), "3 elements")
        XCTAssertThrowsError(try LxMessage.unpack([UInt8](repeating: 0, count: 96) + [0xC0]), "not an array")
        XCTAssertThrowsError(try LxMessage.unpack(m.packed + [0]), "trailing byte")
    }

    func testContentSizeCountsThePayloadLikePython() throws {
        // Python's content_size is the packed payload minus timestamp and structure overhead
        // (which assumes a bin16 content): with an empty title and empty fields it is the
        // content's length from 256 bytes up, and one less below (bin8 is a byte shorter).
        var m = LxMessage(dest: [UInt8](repeating: 0, count: 16), source: [UInt8](repeating: 0, count: 16), timestamp: 1)
        for n in [0, 10, 255, 256, 287, 288, 319, 320] {
            m.content = [UInt8](repeating: 0x41, count: n)
            XCTAssertEqual(m.contentSize(), n < 256 ? n - 1 : n, "\(n)")
        }
        m.title = Array("re".utf8)
        m.content = Array("reply from python".utf8)
        XCTAssertEqual(m.contentSize(), 18, "the title's 2 bytes count too (Go's a_content_size)")
    }
}
