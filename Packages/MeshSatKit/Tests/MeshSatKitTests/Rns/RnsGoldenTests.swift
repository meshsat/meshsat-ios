// Mirrors rns/GoldenVectorTest.kt for the pieces of this tranche: Python RNS wrote every value
// in Fixtures/lxmf/golden.properties; the Swift side must read them all, and what it writes
// (announces, tokens) must read back. Links, proofs and IFAC are the next tranche.
import MeshSatWire
import XCTest

@testable import MeshSatCrypto
@testable import MeshSatReticulum
@testable import MeshSatRns

final class RnsGoldenTests: XCTestCase {
    func testPinnedToTheVersionsTheClientsShip() throws {
        let g = try Vectors.golden()
        XCTAssertEqual(try g.str("rns.version"), "1.5.5")
        XCTAssertEqual(try g.str("lxmf.version"), "1.2.0")
    }

    func testHkdfAgreesWithRnsCryptographyHkdf() throws {
        let g = try Vectors.golden()
        XCTAssertEqual(RnsHkdf.derive(length: 64, from: try g.hex("hkdf.ikm"), salt: try g.hex("hkdf.salt")), try g.hex("hkdf.a"))
        XCTAssertEqual(RnsHkdf.derive(length: 48, from: try g.hex("hkdf.ikm"), salt: nil), try g.hex("hkdf.b"))
    }

    func testTokenDecryptsWhatPythonEncryptedBothKeySizes() throws {
        let g = try Vectors.golden()
        for n in ["token256", "token128"] {
            let tok = try Token(key: try g.hex("\(n).key"))
            XCTAssertEqual(try tok.decrypt(try g.hex("\(n).ct")), try g.hex("\(n).plain"), n)
            // And ours reads back, with a fresh iv each time.
            let plain = try g.hex("\(n).plain")
            let a = try tok.encrypt(plain)
            let b = try tok.encrypt(plain)
            XCTAssertNotEqual(a, b)
            XCTAssertEqual(try tok.decrypt(a), plain)
            var tampered = a
            tampered[20] ^= 1
            XCTAssertThrowsError(try tok.decrypt(tampered), "HMAC")
            XCTAssertFalse(tok.verifyHmac(tampered))
        }
        XCTAssertThrowsError(try Token(key: [UInt8](repeating: 0, count: 48)))
    }

    func testIdentityLoadsPythonPrivateBytesAndDecryptsItsPackets() throws {
        let g = try Vectors.golden()
        let id = try RnsIdentity.fromPrivateBytes(try g.hex("identity.prv"))
        XCTAssertEqual(id.publicBytes, try g.hex("identity.pub"))
        XCTAssertEqual(id.hash, try g.hex("identity.hash"))
        XCTAssertEqual(id.destHash("lxmf.delivery"), try g.hex("identity.lxmf_dest"))
        XCTAssertEqual(Rns.nameHash("lxmf.delivery"), try g.hex("identity.name_hash"))
        XCTAssertEqual(try id.privateBytes(), try g.hex("identity.prv"))
        XCTAssertTrue(id.hasPrivateKey)
        let (plain, idx) = try XCTUnwrap(try id.decrypt(try g.hex("identity.ct")))
        XCTAssertEqual(plain, try g.hex("identity.plain"))
        XCTAssertEqual(idx, -1)
        XCTAssertTrue(id.verify(try g.hex("identity.sig_data"), signature: try g.hex("identity.sig")))
        XCTAssertFalse(id.verify(try g.hex("identity.sig_data") + [0], signature: try g.hex("identity.sig")))
        XCTAssertEqual(RnsIdentity.ratchetPublic(try g.hex("ratchet.prv")), try g.hex("ratchet.pub"))
        let (rp, ridx) = try XCTUnwrap(try id.decrypt(try g.hex("ratchet.ct"), ratchetPrivs: [try g.hex("ratchet.prv")]))
        XCTAssertEqual(rp, try g.hex("ratchet.plain"))
        XCTAssertEqual(ridx, 0)
        XCTAssertNil(try id.decrypt(try g.hex("ratchet.ct")), "the ratchet is not the identity key")
        // Ed25519 is deterministic: our signature over Python's data is Python's.
        XCTAssertEqual(try id.sign(try g.hex("identity.sig_data")), try g.hex("identity.sig"))
    }

    func testIdentityEncryptsToItselfWithAndWithoutARatchet() throws {
        let id = RnsIdentity.generate()
        let pub = try RnsIdentity.fromPublicBytes(id.publicBytes)
        XCTAssertFalse(pub.hasPrivateKey)
        XCTAssertEqual(pub.hash, id.hash)
        XCTAssertThrowsError(try pub.sign([1]))
        XCTAssertThrowsError(try pub.decrypt([UInt8](repeating: 0, count: 100)))
        let plain = Array("single packet plaintext".utf8)
        let ct = try pub.encrypt(plain)
        XCTAssertEqual(ct.count, Rns.pubLen + 16 + 32 + 32, "eph pub + iv + one padded block + hmac")
        XCTAssertEqual(try XCTUnwrap(try id.decrypt(ct)).plaintext, plain)
        let ratchet = RnsIdentity.generateRatchet()
        let rct = try pub.encrypt(plain, ratchetPub: try XCTUnwrap(RnsIdentity.ratchetPublic(ratchet)))
        XCTAssertNil(try id.decrypt(rct))
        let back = try XCTUnwrap(try id.decrypt(rct, ratchetPrivs: [RnsIdentity.generateRatchet(), ratchet]))
        XCTAssertEqual(back.plaintext, plain)
        XCTAssertEqual(back.ratchet, 1)
        XCTAssertNil(try id.decrypt(Array(ct.prefix(40))), "too short for a token")
        XCTAssertThrowsError(try RnsIdentity.fromPrivateBytes([1, 2, 3]))
        XCTAssertThrowsError(try RnsIdentity.fromPublicBytes([1, 2, 3]))
        XCTAssertNil(RnsIdentity.fromPublicBytesOrNil([]))
    }

    func testTheRoutingIdentityIsTheSameKeys() {
        let routing = Identity.generate()
        let rns = RnsIdentity.fromRouting(routing)
        XCTAssertEqual(rns.encPubRaw, routing.encryptionPubRaw)
        XCTAssertEqual(rns.sigPubRaw, routing.signingPubRaw)
        XCTAssertEqual(try rns.privateBytes(), routing.encryptionPrivateRaw + routing.signingSeedRaw)
        XCTAssertEqual(rns.hash, RnsDestination.identityHash(encryptionPub: routing.encryptionPubRaw, signingPub: routing.signingPubRaw))
        XCTAssertEqual(
            rns.destHash("meshsat.node"),
            RnsDestination.computeDestHash(encryptionPub: routing.encryptionPubRaw, signingPub: routing.signingPubRaw),
            "the hash the phone already announces")
        XCTAssertTrue(routing.verify([1, 2, 3], signature: try rns.sign([1, 2, 3])))
    }

    func testPacketHashesMatchPacketPyInBothHeaderForms() throws {
        let g = try Vectors.golden()
        let raw = try g.hex("packet.raw")
        let raw2 = try g.hex("packet.raw2")
        XCTAssertEqual(Header.packetHash(raw), try g.hex("packet.hash"))
        XCTAssertEqual(Header.truncatedPacketHash(raw), try g.hex("packet.trunc"))
        XCTAssertEqual(Header.packetHash(raw2), try g.hex("packet.hash2"))
        let h = try Header.unpack(raw2)
        XCTAssertEqual(h.headerType, Rns.header2)
        XCTAssertEqual(h.transportType, Rns.transportTransport)
        XCTAssertEqual(h.hops, 3)
        XCTAssertEqual(h.transportId, Array(raw2[2..<18]))
        XCTAssertEqual(h.destHash, try g.hex("identity.lxmf_dest"))
        XCTAssertEqual(h.context, Rns.ctxNone)
        XCTAssertEqual(h.data, Array("payload bytes".utf8))
        XCTAssertEqual(try h.pack(), raw2)
        XCTAssertEqual(Header.stripTransport(raw2), raw)
        XCTAssertEqual(Header.rewriteForTransport(raw, transportId: try XCTUnwrap(h.transportId)), raw2)
        let h1 = try Header.unpack(raw)
        XCTAssertEqual(h1.headerType, Rns.header1)
        XCTAssertNil(h1.transportId)
        XCTAssertEqual(try h1.pack(), raw)
        XCTAssertEqual(
            Array(Header.rewriteForTransport(raw2, transportId: [UInt8](repeating: 9, count: 16))[2..<18]),
            [UInt8](repeating: 9, count: 16))
    }

    func testHeaderRefusesWhatAPeerDrops() throws {
        XCTAssertThrowsError(try Header.unpack([UInt8](repeating: 0, count: 18)), "shorter than HEADER_MINSIZE")
        XCTAssertThrowsError(try Header.unpack([0x00, 0x00] + [UInt8](repeating: 0, count: 17)), "empty data")
        XCTAssertThrowsError(try Header.unpack([0x00, 128] + [UInt8](repeating: 0, count: 18)), "hops at PATHFINDER_M")
        XCTAssertThrowsError(try Header.unpack([0x40, 0] + [UInt8](repeating: 0, count: 18)), "HEADER_2 shorter than 35")
        XCTAssertThrowsError(try Header(headerType: Rns.header2, destHash: [UInt8](repeating: 0, count: 16), data: [1]).pack())
        XCTAssertThrowsError(try Header(destHash: [1], data: [1]).pack())
        XCTAssertNil(Header.unpackOrNil([]))
        XCTAssertEqual(Header(contextFlag: 1, destType: Rns.destLink, packetType: Rns.packetProof, destHash: []).flags(), 0x2F)
    }

    func testAnnouncesFromPythonParseAndVerifyWithAndWithoutARatchet() throws {
        let g = try Vectors.golden()
        let a1 = try Announce.unpackPacket(try g.hex("announce1.raw"))
        XCTAssertNil(a1.verify())
        XCTAssertEqual(a1.contextFlag, 0)
        XCTAssertNil(a1.ratchet)
        XCTAssertEqual(a1.appData, [])
        XCTAssertEqual(a1.emittedAt(), Int64(try g.int("announce.ts")))
        XCTAssertEqual(try a1.packet(), try g.hex("announce1.raw"))

        let a2 = try Announce.unpackPacket(try g.hex("announce2.raw"))
        XCTAssertNil(a2.verify())
        XCTAssertEqual(a2.contextFlag, 1)
        XCTAssertEqual(a2.ratchet, try g.hex("ratchet.pub"))
        XCTAssertEqual(a2.appData, try g.hex("announce.app_data"))
        XCTAssertEqual(a2.destHash, try g.hex("identity.lxmf_dest"))
        XCTAssertEqual(a2.publicKey, try g.hex("identity.pub"))
        XCTAssertEqual(try a2.packet(), try g.hex("announce2.raw"), "re-marshals byte for byte")
        XCTAssertEqual(try XCTUnwrap(a2.identity).hash, try g.hex("identity.hash"))

        let a3 = try Announce.unpackPacket(try g.hex("announce3.raw"))
        XCTAssertNil(a3.verify())
        XCTAssertEqual(a3.hops, 2)
        XCTAssertEqual(a3.context, Rns.ctxPathResponse)
        XCTAssertEqual(try Header.unpack(try g.hex("announce3.raw")).headerType, Rns.header2)
        let tid = try XCTUnwrap(try Header.unpack(try g.hex("announce3.raw")).transportId)
        XCTAssertEqual(try a3.transportPacket(transportId: tid, hops: 2, context: Rns.ctxPathResponse), try g.hex("announce3.raw"))

        XCTAssertNotNil(try Announce.unpackPacket(try g.hex("announce.bad")).verify())
        XCTAssertThrowsError(try Announce.unpackPacket(try g.hex("packet.raw")), "a DATA packet is not an announce")
        XCTAssertThrowsError(try Announce.unpackPayload([UInt8](repeating: 0, count: 147), destHash: [], hops: 0, contextFlag: 0))
        XCTAssertThrowsError(try Announce.unpackPayload([UInt8](repeating: 0, count: 179), destHash: [], hops: 0, contextFlag: 1))
    }

    func testOurAnnounceVerifiesAndReadsBack() throws {
        let g = try Vectors.golden()
        let id = try RnsIdentity.fromPrivateBytes(try g.hex("identity.prv"))
        let a = try Announce.create(identity: id, name: "lxmf.delivery", appData: try g.hex("announce.app_data"), nowSec: 1_791_848_972)
        XCTAssertNil(a.verify())
        XCTAssertEqual(a.destHash, try g.hex("identity.lxmf_dest"))
        XCTAssertEqual(a.emittedAt(), 1_791_848_972)
        XCTAssertEqual(Array(a.random[5...]), Array(try g.hex("announce1.raw")[(2 + 16 + 1 + 64 + 10 + 5)..<(2 + 16 + 1 + 64 + 10 + 10)]))
        let back = try Announce.unpackPacket(try a.packet())
        XCTAssertEqual(back, a)
        XCTAssertNil(back.verify())
        let ratchet = try XCTUnwrap(RnsIdentity.ratchetPublic(try g.hex("ratchet.prv")))
        let r = try Announce.create(identity: id, name: "lxmf.delivery", appData: nil, ratchetPub: ratchet, pathResponse: true)
        XCTAssertEqual(r.contextFlag, 1)
        XCTAssertEqual(r.context, Rns.ctxPathResponse)
        XCTAssertEqual(try r.packet().count, 2 + 16 + 1 + Announce.ratchetPayload)
        let rb = try Announce.unpackPacket(try r.packet())
        XCTAssertEqual(rb.ratchet, ratchet)
        XCTAssertNil(rb.verify())
        var forged = rb
        forged.signature[0] ^= 1
        XCTAssertEqual(forged.verify(), "invalid announce signature")
        let pubOnly = try RnsIdentity.fromPublicBytes(id.publicBytes)
        XCTAssertThrowsError(try Announce.create(identity: pubOnly, name: "lxmf.delivery", appData: nil))
    }

    func testThePathRequestDestinationIsThePlainHash() throws {
        let g = try Vectors.golden()
        XCTAssertEqual(Rns.pathRequestDestHash, try g.hex("plain.path_request_dest"))
        XCTAssertEqual(Rns.encryptedMdu, 383)
        XCTAssertEqual(Rns.linkMdu(), 431)
        XCTAssertEqual(Rns.mdu, 464)
    }
}
