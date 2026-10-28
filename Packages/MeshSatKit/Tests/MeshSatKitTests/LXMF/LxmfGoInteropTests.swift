// The Bridge's Go code (internal/lxmf at 8c2f6ede) packed Fixtures/lxmf/go-vectors.properties for
// the golden keys with fixed timestamps, and Python LXMF 1.2.1 validated them. Swift must pack
// the same inputs to the same bytes and read Go's bytes back (MESHSAT-1735, tranche 1).
import MeshSatWire
import XCTest

@testable import MeshSatLXMF
@testable import MeshSatRns

final class LxmfGoInteropTests: XCTestCase {
    private struct Keys {
        let src: RnsIdentity
        let dst: RnsIdentity
        var srcDest: [UInt8] { src.destHash(LxMessage.deliveryName) }
        var dstDest: [UInt8] { dst.destHash(LxMessage.deliveryName) }
    }

    private func keys(_ g: Vectors) throws -> Keys {
        Keys(
            src: try RnsIdentity.fromPrivateBytes(try g.hex("lxmf.src_prv")),
            dst: try RnsIdentity.fromPrivateBytes(try g.hex("lxmf.dst_prv")))
    }

    func testSwiftPacksThePythonMessageToGoAndPythonBytes() throws {
        let g = try Vectors.golden()
        let go = try Vectors.go()
        let k = try keys(g)
        XCTAssertEqual(k.srcDest, try go.hex("src_dest"))
        XCTAssertEqual(k.dstDest, try go.hex("dst_dest"))
        XCTAssertEqual(k.src.hash, try go.hex("src_hash"))
        XCTAssertEqual(k.dst.hash, try go.hex("dst_hash"))
        XCTAssertEqual(try go.hex("a_packed"), try g.hex("lxmf.packed"), "Go's repack is Python's bytes")
        // dst -> src, Python's timestamp, Ed25519 deterministic: the bytes are the same.
        var m = LxMessage(
            dest: k.srcDest, source: k.dstDest, timestamp: try go.double("a_timestamp"), title: Array(try go.str("a_title").utf8),
            content: Array(try go.str("a_content").utf8))
        try m.pack(source: k.dst)
        XCTAssertEqual(m.packed, try go.hex("a_packed"))
        XCTAssertEqual(m.hash, try go.hex("a_hash"))
        XCTAssertEqual(m.contentSize(), try go.int("a_content_size"))
        XCTAssertEqual(m.signature, Array(try go.hex("a_packed")[32..<96]))
    }

    func testSwiftPacksAMidAndAttachmentsToGoBytes() throws {
        let g = try Vectors.golden()
        let go = try Vectors.go()
        let k = try keys(g)
        let mid = try XCTUnwrap(LxMid.parse(try go.str("b_mid")))
        let fields = try LxFields.withAttachments(
            LxMid.withMid([], mid),
            [.image(format: "webp", data: try go.hex("test_webp")), .audio(mode: LxFields.audioMode700C, data: try go.hex("test_frames"))])
        XCTAssertEqual(Msgpack.pack(.map(fields)), try go.hex("b_fields"))
        var b = LxMessage(
            dest: k.dstDest, source: k.srcDest, timestamp: try go.double("b_timestamp"), title: Array(try go.str("b_title").utf8),
            content: Array(try go.str("b_content").utf8), fields: fields)
        try b.pack(source: k.src)
        XCTAssertEqual(b.packed, try go.hex("b_packed"))
        XCTAssertEqual(b.hash, try go.hex("b_hash"))
        XCTAssertEqual(b.signature, try go.hex("b_sig"))
        XCTAssertEqual(b.contentSize(), try go.int("b_content_size"))
        XCTAssertEqual(LxMessage.representation(forContentSize: b.contentSize()), .packet)
        // Go's workblock and Go's stamp at cost 8.
        let wb = LxStamper.workblock(b.hash)
        XCTAssertEqual(wb.count, try go.int("b_workblock_len"))
        XCTAssertEqual(Rns.sha256(wb), try go.hex("b_workblock_sha256"))
        let stamp = try go.hex("b_stamp")
        XCTAssertTrue(LxStamper.stampValid(workblock: wb, stamp: stamp, cost: try go.int("b_stamp_cost")))
        XCTAssertEqual(LxStamper.stampValue(workblock: wb, stamp: stamp), try go.int("b_stamp_value"))
        // Packing with Go's stamp plugged in gives Go's stamped bytes; the hash is the same.
        var c = b
        c.packed = []
        try c.pack(source: k.src, stampCost: 8) { _, _ in stamp }
        XCTAssertEqual(c.packed, try go.hex("c_packed"))
        XCTAssertEqual(c.hash, try go.hex("c_hash"))
        XCTAssertEqual(c.hash, b.hash)
    }

    func testSwiftUnpacksTheGoFixtures() throws {
        let g = try Vectors.golden()
        let go = try Vectors.go()
        let k = try keys(g)
        let srcDest = k.srcDest
        for name in ["b_packed", "c_packed"] {
            let m = try LxMessage.unpack(try go.hex(name)) { source in source == srcDest ? k.src.sigPubRaw : nil }
            XCTAssertTrue(m.sourceKnown, name)
            XCTAssertTrue(m.signatureValid, name)
            XCTAssertEqual(m.hash, try go.hex("b_hash"), name)
            XCTAssertEqual(m.titleString, try go.str("b_title"))
            XCTAssertEqual(m.contentString, try go.str("b_content"))
            XCTAssertEqual(m.timestamp, try go.double("b_timestamp"))
            XCTAssertEqual(m.fields.count, 4)
            XCTAssertEqual(LxMid.midOf(m.fields).map(LxMid.format), try go.str("b_mid"))
            let atts = LxFields.attachmentsOf(m.fields)
            XCTAssertEqual(atts.count, 2)
            XCTAssertEqual(atts.first, .image(format: "webp", data: try go.hex("test_webp")))
            XCTAssertEqual(atts.last, .audio(mode: LxFields.audioMode700C, data: try go.hex("test_frames")))
            XCTAssertEqual(LxFields.describeAttachments(atts), "image webp 34 B, audio Codec2 700C 16 B")
            let wantStamp: [UInt8]? = try (name == "c_packed" ? go.hex("b_stamp") : nil)
            XCTAssertEqual(m.stamp, wantStamp, name)
            XCTAssertEqual(Msgpack.pack(.map(m.fields)), try go.hex("b_fields"))
            XCTAssertEqual(LxFields.withoutAttachments(m.fields), LxMid.fields(try XCTUnwrap(LxMid.midOf(m.fields))))
        }
    }

    func testGoAnnounceAppDataAndMidFieldsAreTheSameBytes() throws {
        let go = try Vectors.go()
        XCTAssertEqual(LxmfAppData.encode(displayName: "MeshSat kit", stampCost: 8, compression: true), try go.hex("app_data"))
        XCTAssertEqual(LxmfAppData.encode(displayName: nil, stampCost: 0, compression: true), try go.hex("app_data_noname"))
        XCTAssertEqual(
            LxmfAppData.parse(try go.hex("app_data_noname")), LxmfAppData.Info(displayName: nil, stampCost: 0, compression: true))
        let mid = try XCTUnwrap(LxMid.parse(try go.str("b_mid")))
        XCTAssertEqual(Msgpack.pack(.map(LxMid.fields(mid))), try go.hex("mid_fields"))
    }

    func testTheAttachmentMapsOfFieldsTestGo() throws {
        let go = try Vectors.go()
        let webp = try go.hex("test_webp")
        let frames = try go.hex("test_frames")
        let fields = try LxFields.withAttachments(
            [], [.image(format: "webp", data: webp), .audio(mode: LxFields.audioMode700C, data: frames)])
        XCTAssertEqual(Msgpack.pack(.map(fields)), try go.hex("fields_image_then_audio"))
        for key in ["fields_image_then_audio", "fields_audio_then_image"] {
            let (v, n) = try Msgpack.unpack(try go.hex(key))
            XCTAssertEqual(n, try go.hex(key).count)
            let atts = LxFields.attachmentsOf(try XCTUnwrap(v.asMap))
            XCTAssertEqual(atts, [.image(format: "webp", data: webp), .audio(mode: LxFields.audioMode700C, data: frames)], key)
        }
    }

    /// The mid's room at the packet limits (the Bridge's TestMidRoomAtThePacketLimits, with the
    /// LXMF 1.2.x single-packet limit of 287 instead of the Bridge's 295): with the mid, 252 bytes
    /// of content fill a single packet and 253 do not; 283 fill a link packet and 284 do not.
    /// Without it the limits are 287 and 319.
    func testMidRoomAtThePacketLimits() throws {
        let mid = [UInt8](repeating: 0, count: 16)
        func size(_ n: Int, _ fields: [MpEntry]) -> Int {
            LxMessage(dest: mid, source: mid, timestamp: 1, content: [UInt8](repeating: 0, count: n), fields: fields).contentSize()
        }
        struct Row {
            let n: Int
            let limit: Int
            let fields: [MpEntry]
            let fits: Bool
        }
        let cases = [
            Row(n: 252, limit: LxMessage.encryptedPacketMaxContent, fields: LxMid.fields(mid), fits: true),
            Row(n: 253, limit: LxMessage.encryptedPacketMaxContent, fields: LxMid.fields(mid), fits: false),
            Row(n: 283, limit: LxMessage.linkPacketMaxContent, fields: LxMid.fields(mid), fits: true),
            Row(n: 284, limit: LxMessage.linkPacketMaxContent, fields: LxMid.fields(mid), fits: false),
            Row(n: 287, limit: LxMessage.encryptedPacketMaxContent, fields: [], fits: true),
            Row(n: 288, limit: LxMessage.encryptedPacketMaxContent, fields: [], fits: false),
            Row(n: 319, limit: LxMessage.linkPacketMaxContent, fields: [], fits: true),
            Row(n: 320, limit: LxMessage.linkPacketMaxContent, fields: [], fits: false),
        ]
        for c in cases {
            XCTAssertEqual(size(c.n, c.fields) <= c.limit, c.fits, "\(c.n) bytes (content size \(size(c.n, c.fields))) within \(c.limit)")
        }
        XCTAssertEqual(size(259, LxMid.fields(mid)), 295, "the Bridge's 1.1.0 limit row, same arithmetic")
    }
}
