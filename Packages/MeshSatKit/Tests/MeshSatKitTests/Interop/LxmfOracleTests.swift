// Mirrors lxmf/LxmfOracleTest.kt: Python LXMF 1.2.0 reads what we pack (messages, stamps and announce app
// data) and we read its reply. Skipped without the venv (scripts/interop-docker.sh). [MESHSAT-1735]
import Foundation
import MeshSatWire
import XCTest

@testable import MeshSatLXMF
@testable import MeshSatRns

final class LxmfOracleTests: XCTestCase {
    func testPythonVerifiesOurMessageAndWeVerifyItsReply() throws {
        _ = try PyEnv.python()
        let src = RnsIdentity.generate()
        let dst = RnsIdentity.generate()
        var m = LxMessage(
            dest: dst.destHash(LxMessage.deliveryName), source: src.destHash(LxMessage.deliveryName), title: Array("hi".utf8),
            content: Array("hello from the phone".utf8))
        try m.pack(source: src)
        let script = """
            import sys, RNS, LXMF
            RNS.loglevel = 0
            src = RNS.Identity.from_bytes(bytes.fromhex(sys.argv[1])); dst = RNS.Identity.from_bytes(bytes.fromhex(sys.argv[2]))
            for i in (src, dst):
                h = RNS.Destination.hash_from_name_and_identity("lxmf.delivery", i)
                RNS.Identity.known_destinations[h] = [0, None, i.get_public_key(), None]
            lxm = LXMF.LXMessage.unpack_from_bytes(bytes.fromhex(sys.argv[3]))
            d_src = RNS.Destination(src, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")
            d_dst = RNS.Destination(dst, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")
            reply = LXMF.LXMessage(d_src, d_dst, b"reply from python", title=b"re", desired_method=LXMF.LXMessage.OPPORTUNISTIC)
            reply.pack()
            print("hash=" + lxm.hash.hex()); print("valid=" + str(bool(lxm.signature_validated)))
            print("content=" + lxm.content.decode()); print("packed=" + reply.packed.hex())
            """
        let r = try PyEnv.pyKv(script, Hex.encode(try src.privateBytes()), Hex.encode(try dst.privateBytes()), Hex.encode(m.packed))
        XCTAssertEqual(r["hash"], m.hashHex)
        XCTAssertEqual(r["valid"], "True")
        XCTAssertEqual(r["content"], "hello from the phone")
        let dstDelivery = dst.destHash(LxMessage.deliveryName)
        let back = try LxMessage.unpack(
            try XCTUnwrap(Hex.decode(try XCTUnwrap(r["packed"]))), sigPubOf: { s in s == dstDelivery ? dst.sigPubRaw : nil })
        XCTAssertTrue(back.sourceKnown && back.signatureValid)
        XCTAssertEqual(back.contentString, "reply from python")
        XCTAssertEqual(back.titleString, "re")
        // Python's content_size equals ours.
        let sizeScript = """
            import sys, RNS, LXMF
            import RNS.vendor.umsgpack as um
            packed = bytes.fromhex(sys.argv[1])
            payload = packed[16+16+64:]
            print("size=" + str(len(payload) - LXMF.LXMessage.TIMESTAMP_SIZE - LXMF.LXMessage.STRUCT_OVERHEAD))
            """
        let cs = try PyEnv.pyKv(sizeScript, Hex.encode(m.packed))
        XCTAssertEqual(cs["size"], String(m.contentSize()))
    }

    func testPythonAcceptsOurStampAtCost8AndOurAnnounceAppData() throws {
        _ = try PyEnv.python()
        let src = RnsIdentity.generate()
        let dst = RnsIdentity.generate()
        var m = LxMessage(
            dest: dst.destHash(LxMessage.deliveryName), source: src.destHash(LxMessage.deliveryName), content: Array("stamped".utf8))
        try m.pack(source: src, stampCost: 8, stamper: { h, c in LxStamper.generateStamp(messageId: h, cost: c)?.stamp })
        let app = LxmfAppData.encode(displayName: "MeshSat phone", stampCost: 8)
        let script = """
            import sys, RNS, LXMF
            RNS.loglevel = 0
            src = RNS.Identity.from_bytes(bytes.fromhex(sys.argv[1])); dst = RNS.Identity.from_bytes(bytes.fromhex(sys.argv[2]))
            for i in (src, dst):
                h = RNS.Destination.hash_from_name_and_identity("lxmf.delivery", i)
                RNS.Identity.known_destinations[h] = [0, None, i.get_public_key(), None]
            lxm = LXMF.LXMessage.unpack_from_bytes(bytes.fromhex(sys.argv[3]))
            app = bytes.fromhex(sys.argv[4])
            print("stamp_ok=" + str(bool(lxm.validate_stamp(8)) and bool(lxm.signature_validated)))
            print("name=" + str(LXMF.display_name_from_app_data(app))); print("cost=" + str(LXMF.stamp_cost_from_app_data(app)))
            print("compression=" + str(LXMF.compression_support_from_app_data(app)))
            """
        let r = try PyEnv.pyKv(
            script, Hex.encode(try src.privateBytes()), Hex.encode(try dst.privateBytes()), Hex.encode(m.packed), Hex.encode(app))
        XCTAssertEqual(r["stamp_ok"], "True")
        XCTAssertEqual(r["name"], "MeshSat phone")
        XCTAssertEqual(r["cost"], "8")
        XCTAssertEqual(r["compression"], "False")
    }
}
