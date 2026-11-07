// Mirrors interop/InteropLxmfTest.kt (the Bridge's lxmf_test.go): our LXMF endpoint against upstream
// Python LXMF 1.2.0 over TCP. Skipped without the venv (scripts/interop-docker.sh). [MESHSAT-1735]
import Foundation
import MeshSatWire
import XCTest

@testable import MeshSatLXMF
@testable import MeshSatNIO
@testable import MeshSatNet
@testable import MeshSatReticulum
@testable import MeshSatRns

final class InteropLxmfTests: XCTestCase {
    final class Kit: @unchecked Sendable {
        let id = RnsIdentity.generate()
        let server: RnsTcpServerInterface
        let tx: InterfaceTransmitter
        let got = InteropNodeTests.Queue<LxMessage>()
        let node: Node
        let router: LxmfRouter
        let port: Int

        init(stampCost: Int = 0) async throws {
            let log: @Sendable (String) -> Void = { FileHandle.standardError.write(Data("[kit] \($0)\n".utf8)) }
            let server = RnsTcpServerInterface(factory: NIOByteStreamListenerFactory(), interfaceId: "tcp_0", log: log)
            self.server = server
            tx = InterfaceTransmitter(interfaces: { ["tcp_0": server] }, hwMtu: { _ in 262_144 }, log: log)
            node = Node(cfg: NodeConfig(identity: id, log: log), tx: tx)
            var cfg = LxmfRouter.Config(identity: id, displayName: "MeshSat test kit")
            cfg.stampCost = stampCost
            cfg.enforceStamps = stampCost > 0
            let got = self.got
            cfg.onMessage = { got.add($0) }
            cfg.log = { FileHandle.standardError.write(Data("[lxmf] \($0)\n".utf8)) }
            router = LxmfRouter(node: node, config: cfg)
            let node = self.node
            server.setReceiveCallback { _, raw in node.inbound(raw, iface: "tcp_0") }
            port = try await server.listen(port: 0)
            node.start()
            router.start()
        }

        func stop() async {
            router.stop()
            node.stop()
            tx.stop()
            await server.stop()
        }
    }

    private var kits: [Kit] = []
    private var failed = false

    override func tearDown() async throws {
        for k in kits { await k.stop() }
        kits = []
        PyPeer.stopAll(dumpLogs: failed)
        try await super.tearDown()
    }

    private func kit(stampCost: Int = 0) async throws -> Kit {
        let k = try await Kit(stampCost: stampCost)
        kits.append(k)
        return k
    }

    private func waitFor(_ what: String, timeoutMs: Int64 = 10_000, file: StaticString = #filePath, line: UInt = #line, _ cond: () -> Bool)
        async throws
    {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if cond() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        failed = true
        XCTFail("timeout waiting for \(what)", file: file, line: line)
        throw PyPeer.Failure(description: "timeout waiting for \(what)")
    }

    private func h(_ hex: String) throws -> [UInt8] { try XCTUnwrap(Hex.decode(hex), "bad hex \(hex)") }

    private func take(_ k: Kit, timeoutMs: Int64, _ what: String) async throws -> LxMessage {
        do {
            return try await k.got.take(timeoutMs: timeoutMs, what)
        } catch {
            failed = true
            throw error
        }
    }

    private func bringUp(_ k: Kit, _ p: PyPeer) async throws {
        try await waitFor("tcp peer") { k.server.peerCount() > 0 }
        try p.send("announce")
        let pd = try h(p.delivery)
        try await waitFor("we learn python's delivery dest") { k.node.hopsTo(pd) == 1 }
        XCTAssertTrue(k.router.announce())
        try await p.wait("announce", { $0["dest"] as? String == k.router.hashHex })
    }

    func testSinglePacketBothWays() async throws {
        _ = try PyEnv.python()
        let k = try await kit()
        let p = try await PyPeer.start(.init(name: "A", connect: "127.0.0.1:\(k.port)"))
        try await waitFor("tcp peer") { k.server.peerCount() > 0 }
        try p.send("announce")
        let pd = try h(p.delivery)
        try await waitFor("we learn python's delivery dest") { k.node.hopsTo(pd) == 1 }
        XCTAssertTrue(k.router.announce())
        let dh = k.router.hashHex
        let ev = try await p.wait("announce", { $0["dest"] as? String == dh })
        let info = LxmfAppData.parse(try h(try XCTUnwrap(ev["app_data"] as? String)))
        XCTAssertEqual(info.displayName, "MeshSat test kit")

        // Python -> us, opportunistic single packet, we prove it.
        try p.send("send_lxm", ["dest": dh, "content": "hello kit", "title": "t1", "method": "opportunistic"])
        let sent = try await p.wait("lxm_sent")
        let m = try await take(k, timeoutMs: 15_000, "the LXMF message")
        XCTAssertEqual(m.contentString, "hello kit")
        XCTAssertEqual(m.titleString, "t1")
        XCTAssertTrue(m.signatureValid)
        XCTAssertEqual(m.method, .opportunistic)
        XCTAssertEqual(sent["hash"] as? String, m.hashHex)
        try await p.wait("lxm_delivered", timeoutMs: 15_000)

        // Us -> Python, opportunistic (auto: ratchet announced, no link), python proves it.
        let o = try k.router.send(pd, content: Array("hello python".utf8), title: Array("t2".utf8))
        XCTAssertEqual(o.method, .opportunistic)
        let rcv = try await p.wait("lxm_received", timeoutMs: 15_000)
        XCTAssertEqual(rcv["content"] as? String, "hello python")
        XCTAssertEqual(rcv["title"] as? String, "t2")
        XCTAssertTrue(bool(rcv["signature_validated"]))
        XCTAssertEqual(rcv["hash"] as? String, o.hashHex)
        let s = try await o.result.wait(timeoutMs: 15_000)
        XCTAssertEqual(s, .delivered)
        let peers = k.router.peers()
        XCTAssertEqual(peers.count, 1)
        XCTAssertEqual(peers.first?.destHash, p.delivery)
        XCTAssertEqual(peers.first?.displayName, "A")
    }

    /// The HeMB-NG mid (contract C2) crosses upstream LXMF both ways byte for byte: Python sends the fixture's
    /// fields map and we read the mid from it; we send ours and Python gets the fixture's bytes. [MESHSAT-1641]
    func testMidFieldBothWays() async throws {
        _ = try PyEnv.python()
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "lxmf_mid_field", withExtension: "json", subdirectory: "Fixtures/hemb-ng/v1"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let fieldsHex = try XCTUnwrap(fixture["fields_msgpack_hex"] as? String)
        let mid = try XCTUnwrap(LxMid.parse(try XCTUnwrap(fixture["mid"] as? String)))
        let k = try await kit()
        let p = try await PyPeer.start(.init(name: "A", connect: "127.0.0.1:\(k.port)"))
        try await bringUp(k, p)
        let pd = try h(p.delivery)

        try p.send("send_lxm", ["dest": k.router.hashHex, "content": "with an id", "method": "opportunistic", "fields_hex": fieldsHex])
        let m = try await take(k, timeoutMs: 15_000, "the LXMF message with a mid")
        XCTAssertTrue(m.signatureValid)
        XCTAssertEqual(LxMid.midOf(m.fields), mid)

        let o = try k.router.send(pd, content: Array("with an id".utf8), fields: LxMid.fields(mid))
        let rcv = try await p.wait("lxm_received", timeoutMs: 15_000)
        XCTAssertEqual(rcv["fields_hex"] as? String, fieldsHex)
        XCTAssertTrue(bool(rcv["signature_validated"]))
        let s = try await o.result.wait(timeoutMs: 15_000)
        XCTAssertEqual(s, .delivered)

        // The boundary with the mid (r40 review, decision 4): 252 bytes still go as one packet, 253 over a
        // link, and stock LXMF 1.2.0 takes both.
        for (n, want) in [(252, LxMethod.opportunistic), (253, LxMethod.direct)] {
            let body = String(repeating: "b", count: n)
            let out = try k.router.send(pd, content: Array(body.utf8), fields: LxMid.fields(mid))
            XCTAssertEqual(out.method, want, "\(n) bytes")
            let got = try await p.wait("lxm_received", { $0["content"] as? String == body }, timeoutMs: 20_000)
            XCTAssertEqual(got["fields_hex"] as? String, fieldsHex, "\(n) bytes")
            let st = try await out.result.wait(timeoutMs: 20_000)
            XCTAssertEqual(st, .delivered, "\(n) bytes")
        }
    }

    func testDirectLinkBothWays() async throws {
        _ = try PyEnv.python()
        let k = try await kit()
        let p = try await PyPeer.start(.init(name: "A", connect: "127.0.0.1:\(k.port)"))
        try await bringUp(k, p)
        let dh = k.router.hashHex
        let pd = try h(p.delivery)

        // Python -> us over a link (DIRECT), 310 bytes of content: a link packet.
        let content = String(repeating: "d", count: 310)
        try p.send("send_lxm", ["dest": dh, "content": content, "method": "direct"])
        let m = try await take(k, timeoutMs: 20_000, "the direct LXMF message")
        XCTAssertEqual(m.contentString, content)
        XCTAssertEqual(m.method, .direct)
        XCTAssertTrue(m.signatureValid)
        try await p.wait("lxm_delivered", timeoutMs: 15_000)

        // Us -> Python over a link we open, then a second one that must reuse it.
        let o = try k.router.send(pd, content: Array(String(repeating: "b", count: 300).utf8), method: .direct)
        let s = try await o.result.wait(timeoutMs: 20_000)
        XCTAssertEqual(s, .delivered)
        let rcv = try await p.wait("lxm_received", timeoutMs: 20_000)
        XCTAssertEqual(rcv["hash"] as? String, o.hashHex)
        XCTAssertTrue(bool(rcv["signature_validated"]))
        let before = k.node.links.all().count
        let o2 = try k.router.send(pd, content: Array(String(repeating: "c", count: 300).utf8), method: .direct)
        let s2 = try await o2.result.wait(timeoutMs: 20_000)
        XCTAssertEqual(s2, .delivered)
        try await p.wait("lxm_received", timeoutMs: 20_000)
        XCTAssertEqual(k.node.links.all().count, before)
        // Python replies with its own choice ("auto": a link exists, so direct on it) and we receive it.
        try p.send("send_lxm", ["dest": dh, "content": "auto reply", "method": "auto"])
        let reply = try await take(k, timeoutMs: 20_000, "python's auto reply")
        XCTAssertEqual(reply.contentString, "auto reply")
        try await p.wait("lxm_delivered", timeoutMs: 15_000)
    }

    func testStampsAtCost6() async throws {
        _ = try PyEnv.python()
        let k = try await kit(stampCost: 6)
        var opts = PyPeer.Opts(name: "S", connect: "127.0.0.1:\(k.port)")
        opts.stampCost = 6
        opts.enforce = true
        opts.loglevel = 6
        let p = try await PyPeer.start(opts)
        try await bringUp(k, p)
        let dh = k.router.hashHex
        let pd = try h(p.delivery)
        XCTAssertEqual(k.router.peerInfo(pd)?.stampCost, 6)

        try p.send("send_lxm", ["dest": dh, "content": "stamped from python", "method": "opportunistic"])
        let m = try await take(k, timeoutMs: 60_000, "the stamped message")
        XCTAssertTrue(m.stampValid)
        XCTAssertGreaterThanOrEqual(m.stampValue, 6)
        try await p.wait("lxm_delivered", timeoutMs: 15_000)

        let o = try k.router.send(pd, content: Array("stamped from swift".utf8))
        XCTAssertNotNil(o.message.stamp)
        let rcv = try await p.wait("lxm_received", timeoutMs: 30_000)
        XCTAssertTrue(bool(rcv["stamp_valid"]))
        let s = try await o.result.wait(timeoutMs: 20_000)
        XCTAssertEqual(s, .delivered)
    }

    func testResourceBothWays() async throws {
        _ = try PyEnv.python()
        let k = try await kit()
        var opts = PyPeer.Opts(name: "A", connect: "127.0.0.1:\(k.port)")
        opts.loglevel = 5
        let p = try await PyPeer.start(opts)
        try await bringUp(k, p)
        let dh = k.router.hashHex
        let pd = try h(p.delivery)

        // Python -> us: 2 KB of content forces an RNS resource on a link.
        let big = String(repeating: "resource payload from python. ", count: 70)
        try p.send("send_lxm", ["dest": dh, "content": big, "method": "direct"])
        let m = try await take(k, timeoutMs: 30_000, "the resource message")
        XCTAssertEqual(m.contentString, big)
        XCTAssertEqual(m.method, .direct)
        XCTAssertTrue(m.signatureValid)
        try await p.wait("lxm_delivered", timeoutMs: 30_000)

        // Us -> Python: 3 KB of content as a resource on our link.
        let big2 = String(repeating: "resource payload from swift. ", count: 100)
        let o = try k.router.send(pd, content: Array(big2.utf8), title: Array("big".utf8))
        XCTAssertEqual(o.method, .direct)
        XCTAssertEqual(o.representation, .resource)
        let rcv = try await p.wait("lxm_received", timeoutMs: 30_000)
        XCTAssertEqual(rcv["hash"] as? String, o.hashHex)
        XCTAssertTrue(bool(rcv["signature_validated"]))
        XCTAssertEqual(rcv["content"] as? String, big2)
        let s = try await o.result.wait(timeoutMs: 30_000)
        XCTAssertEqual(s, .delivered)
    }

    /// A Python propagation node N and a Python client B both behind our kit (the transport between them). We
    /// send PROPAGATED through N; B syncs from N and gets it.
    func testPropagatedToPythonViaNode() async throws {
        _ = try PyEnv.python()
        let k = try await kit()
        var nOpts = PyPeer.Opts(name: "N", connect: "127.0.0.1:\(k.port)")
        nOpts.propagationNode = true
        nOpts.loglevel = 5
        let n = try await PyPeer.start(nOpts)
        let b = try await PyPeer.start(.init(name: "B", connect: "127.0.0.1:\(k.port)"))
        try await waitFor("two tcp peers") { k.server.peerCount() == 2 }
        XCTAssertEqual(n.propagation.count, 32)
        try n.send("announce")
        try await waitFor("we learn the propagation node") { k.router.propagationNodes().contains { $0.destHex == n.propagation } }
        let info = try XCTUnwrap(k.router.propagationNodeInfo())
        XCTAssertEqual(info.destHex, n.propagation)
        XCTAssertTrue(info.enabled)
        XCTAssertEqual(info.stampCost, 13)
        XCTAssertEqual(info.hops, 1)
        try b.send("announce")
        let bd = try h(b.delivery)
        try await waitFor("we learn B's delivery dest") { k.node.hopsTo(bd) == 1 }
        try await b.wait("announce", { $0["dest"] as? String == n.propagation }, timeoutMs: 15_000)  // B hears the node through us

        let o = try k.router.send(bd, content: Array("through the node".utf8), title: Array("pn".utf8), method: .propagated)
        XCTAssertEqual(o.method, .propagated)
        let s = try await o.result.wait(timeoutMs: 90_000)
        XCTAssertEqual(s, .sent)
        XCTAssertNotNil(o.transientId)

        // B verifies the signature only once it knows us.
        XCTAssertTrue(k.router.announce())
        try await b.wait("announce", { $0["dest"] as? String == k.router.hashHex }, timeoutMs: 15_000)
        try b.send("set_propagation_node", ["dest": n.propagation])
        try await b.wait("propagation_node_set")
        try b.send("sync")
        let sync = try await b.wait("sync", timeoutMs: 120_000)
        XCTAssertEqual(num(sync["state"]), SyncState.complete.code)
        XCTAssertEqual(num(sync["result"]), 1)
        let rcv = try await b.wait("lxm_received", timeoutMs: 15_000)
        XCTAssertEqual(rcv["content"] as? String, "through the node")
        XCTAssertEqual(rcv["title"] as? String, "pn")
        XCTAssertEqual(rcv["hash"] as? String, o.hashHex)
        XCTAssertTrue(bool(rcv["signature_validated"]))
        XCTAssertEqual(rcv["method"] as? String, "3")  // LXMessage.PROPAGATED
    }

    /// B sends PROPAGATED through N for us; our sync downloads, decrypts and delivers it, and tells N.
    func testPropagatedFromPythonViaNode() async throws {
        _ = try PyEnv.python()
        let k = try await kit()
        var nOpts = PyPeer.Opts(name: "N", connect: "127.0.0.1:\(k.port)")
        nOpts.propagationNode = true
        nOpts.loglevel = 5
        let n = try await PyPeer.start(nOpts)
        var bOpts = PyPeer.Opts(name: "B", connect: "127.0.0.1:\(k.port)")
        bOpts.loglevel = 7
        let b = try await PyPeer.start(bOpts)
        try await waitFor("two tcp peers") { k.server.peerCount() == 2 }
        try n.send("announce")
        try await waitFor("we learn the propagation node") { k.router.propagationNodes().contains { $0.destHex == n.propagation } }
        try await b.wait("announce", { $0["dest"] as? String == n.propagation }, timeoutMs: 15_000)
        XCTAssertTrue(k.router.announce())
        try await b.wait("announce", { $0["dest"] as? String == k.router.hashHex }, timeoutMs: 15_000)
        try b.send("announce")
        let bd = try h(b.delivery)
        try await waitFor("we learn B's delivery dest") { k.node.hopsTo(bd) == 1 }  // to verify B's signature

        try b.send("set_propagation_node", ["dest": n.propagation])
        try await b.wait("propagation_node_set")
        try b.send("send_lxm", ["dest": k.router.hashHex, "content": "python via node", "title": "pn2", "method": "propagated"])
        let sent = try await b.wait("lxm_sent", timeoutMs: 60_000)
        // Nothing arrives by itself: a propagated message waits at the node.
        let early = try? await k.got.take(timeoutMs: 3000, "nothing")
        XCTAssertNil(early)
        try await b.wait("lxm_delivered", timeoutMs: 90_000)  // the node took it (SENT upstream)

        let r = try await k.router.sync().wait(timeoutMs: 120_000)
        XCTAssertEqual(r.state, .complete, r.error)
        XCTAssertEqual(r.received, 1)
        let m = try await take(k, timeoutMs: 5000, "the propagated message")
        XCTAssertEqual(m.contentString, "python via node")
        XCTAssertEqual(m.titleString, "pn2")
        XCTAssertEqual(m.method, .propagated)
        XCTAssertTrue(m.signatureValid)
        XCTAssertEqual(sent["hash"] as? String, m.hashHex)

        // A second sync finds nothing: the node deleted what we confirmed.
        let r2 = try await k.router.sync().wait(timeoutMs: 60_000)
        XCTAssertEqual(r2.state, .complete)
        XCTAssertEqual(r2.received, 0)
    }
}
