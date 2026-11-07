// Mirrors interop/InteropNodeTest.kt (the Bridge's harness_test.go): the node on a real TCP interface
// against upstream Python RNS peers from the pinned venv. Skipped without the venv; on the runner
// scripts/interop-docker.sh runs them with MESHSAT_INTEROP=1. [MESHSAT-1735]
import Foundation
import MeshSatWire
import XCTest

@testable import MeshSatNIO
@testable import MeshSatNet
@testable import MeshSatReticulum
@testable import MeshSatRns

final class InteropNodeTests: XCTestCase {
    /// A thread-safe FIFO the callbacks append to and the test awaits.
    final class Queue<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []

        func add(_ v: T) {
            lock.lock()
            items.append(v)
            lock.unlock()
        }

        func take(timeoutMs: Int64, _ what: String) async throws -> T {
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
            while Date() < deadline {
                let v: T? = {
                    lock.lock()
                    defer { lock.unlock() }
                    return items.isEmpty ? nil : items.removeFirst()
                }()
                if let v { return v }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            throw PyPeer.Failure(description: "timeout waiting for \(what)")
        }
    }

    /// Our node on a TCP server interface "tcp_0" (and optionally a client "tcp_c" to a listening peer).
    final class Kit: @unchecked Sendable {
        let id = RnsIdentity.generate()
        let server: RnsTcpServerInterface
        let client: RnsTcpInterface?
        let tx: InterfaceTransmitter
        let got = Queue<String>()
        let links = Queue<Link>()
        let node: Node
        let dest: Destination
        let port: Int

        init(connect: String? = nil) async throws {
            let log: @Sendable (String) -> Void = { FileHandle.standardError.write(Data("[kit] \($0)\n".utf8)) }
            let server = RnsTcpServerInterface(factory: NIOByteStreamListenerFactory(), interfaceId: "tcp_0", log: log)
            let client = connect.map { _ in RnsTcpInterface(dialer: NIOByteStreamDialer(), interfaceId: "tcp_c", log: log) }
            self.server = server
            self.client = client
            tx = InterfaceTransmitter(
                interfaces: {
                    var m: [String: any RnsInterface] = ["tcp_0": server]
                    if let client { m["tcp_c"] = client }
                    return m
                }, hwMtu: { _ in 262_144 }, log: log)
            node = Node(cfg: NodeConfig(identity: id, log: log), tx: tx)
            let got = self.got
            let links = self.links
            dest = node.addDestination("interop.raw") { d in
                d.acceptLinks = true
                d.proveAll = true
                d.onPacket = { plain, _ in got.add(String(decoding: plain, as: UTF8.self)) }
                d.onLink = { l in links.add(l) }
                d.onLinkPacket = { _, plain, _ in got.add(String(decoding: plain, as: UTF8.self)) }
            }
            let node = self.node
            server.setReceiveCallback { _, raw in node.inbound(raw, iface: "tcp_0") }
            port = try await server.listen(port: 0)
            if let client, let connect {
                client.setReceiveCallback { _, raw in node.inbound(raw, iface: "tcp_c") }
                let parts = connect.split(separator: ":")
                client.connect(host: String(parts[0]), port: Int(parts[1]) ?? 4242)
            }
            node.start()
        }

        func stop() async {
            node.stop()
            tx.stop()
            client?.disconnect()
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

    private func kit(connect: String? = nil) async throws -> Kit {
        let k = try await Kit(connect: connect)
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

    private func freePort() async throws -> Int {
        let l = try await NIOByteStreamListenerFactory().listen(host: "127.0.0.1", port: 0)
        let p = l.port
        await l.close()
        return p
    }

    func testAnnounceBothWays() async throws {
        _ = try PyEnv.python()
        let k = try await kit()
        let p = try await PyPeer.start(.init(name: "A", connect: "127.0.0.1:\(k.port)"))
        try await waitFor("tcp peer") { k.server.peerCount() > 0 }

        // Python -> us
        try p.send("announce")
        try await waitFor("we learn python's raw dest") { k.node.hopsTo((try? self.h(p.raw)) ?? []) == 1 }
        try await waitFor("we learn python's lxmf dest") { k.node.hopsTo((try? self.h(p.delivery)) ?? []) == 1 }
        let known = try XCTUnwrap(k.node.recall(try h(p.delivery)))
        XCTAssertFalse(known.appData?.isEmpty ?? true, "LXMF announce app data not stored")
        XCTAssertNotNil(known.ratchet, "ratchet from the lxmf announce not stored")

        // Us -> Python, twice: the second (newer) announce must be accepted too.
        XCTAssertTrue(k.node.announce(k.dest))
        let dh = k.dest.hashHex
        let ev = try await p.wait("announce", { $0["dest"] as? String == dh })
        XCTAssertEqual(num(ev["hops"]), 1)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertTrue(k.node.announce(k.dest))
        try await p.wait("announce", { $0["dest"] as? String == dh })
        try p.send("has_path", ["dest": dh])
        let pe = try await p.wait("path")
        XCTAssertTrue(bool(pe["known"]))
        XCTAssertEqual(num(pe["hops"]), 1)
    }

    func testPacketAndProofBothWays() async throws {
        _ = try PyEnv.python()
        let k = try await kit()
        let p = try await PyPeer.start(.init(name: "A", connect: "127.0.0.1:\(k.port)"))
        try await waitFor("tcp peer") { k.server.peerCount() > 0 }
        try p.send("announce")
        let praw = try h(p.raw)
        try await waitFor("we learn python") { k.node.hopsTo(praw) == 1 }
        k.node.announce(k.dest)
        let dh = k.dest.hashHex
        try await p.wait("announce", { $0["dest"] as? String == dh })

        // Python -> us, single packet, we prove it.
        try p.send("send_packet", ["dest": dh, "data": "ping from python"])
        let got = try await k.got.take(timeoutMs: 10_000, "packet from python")
        XCTAssertEqual(got, "ping from python")
        try await p.wait("packet_proved")

        // Us -> Python, python proves it.
        let r = try XCTUnwrap(try k.node.sendData(praw, Array("ping from swift".utf8)))
        let ev = try await p.wait("packet_received")
        XCTAssertEqual(ev["data"] as? String, "ping from swift")
        let res = try await r.result.wait(timeoutMs: 10_000)
        XCTAssertTrue(res.delivered)
    }

    func testLinkPythonToUs() async throws {
        _ = try PyEnv.python()
        let k = try await kit()
        let p = try await PyPeer.start(.init(name: "A", connect: "127.0.0.1:\(k.port)"))
        try await waitFor("tcp peer") { k.server.peerCount() > 0 }
        k.node.announce(k.dest)
        let dh = k.dest.hashHex
        try await p.wait("announce", { $0["dest"] as? String == dh })

        try p.send("link", ["dest": dh])
        let ev = try await p.wait("link_established", timeoutMs: 15_000)
        let linkId = try XCTUnwrap(ev["link"] as? String)
        let l = try await k.links.take(timeoutMs: 10_000, "our link active")
        XCTAssertEqual(l.idHex, linkId)
        // Data on the link, proved by us (proveAll).
        try p.send("link_send", ["link": linkId, "data": "link data from python"])
        let got = try await k.got.take(timeoutMs: 10_000, "link data")
        XCTAssertEqual(got, "link data from python")
        try await p.wait("link_proof")
        // Identify, keepalive round trip at a short interval, close.
        try p.send("link_identify", ["link": linkId])
        try await waitFor("identified") { l.remoteIdentity != nil }
        try p.send("set_keepalive", ["link": linkId, "seconds": 5])
        try await p.wait("keepalive_set")
        for i in 1...8 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            FileHandle.standardError.write(Data("t+\(i)s our link state \(l.state)\n".utf8))
        }
        XCTAssertEqual(l.state, .active)
        try p.send("link_close", ["link": linkId])
        try await waitFor("we see the close") { k.node.links.get(l.id) == nil }
    }

    func testLinkUsToPython() async throws {
        _ = try PyEnv.python()
        let k = try await kit()
        let p = try await PyPeer.start(.init(name: "A", connect: "127.0.0.1:\(k.port)"))
        try await waitFor("tcp peer") { k.server.peerCount() > 0 }
        try p.send("announce")
        let praw = try h(p.raw)
        try await waitFor("we learn python") { k.node.hopsTo(praw) == 1 }

        let l = try k.node.links.initiate(praw)
        _ = try await l.established.wait(timeoutMs: 15_000)
        let ev = try await p.wait("link_established")
        XCTAssertEqual(ev["link"] as? String, l.idHex)
        let r = try k.node.links.send(l, Array("hello over link".utf8))
        let pe = try await p.wait("link_packet")
        XCTAssertEqual(pe["data"] as? String, "hello over link")
        let res = try await r.result.wait(timeoutMs: 10_000)
        XCTAssertTrue(res.delivered)
        try k.node.links.identify(l, k.id)
        let ie = try await p.wait("link_identified")
        XCTAssertEqual(ie["identity"] as? String, k.id.hashHex)
        k.node.links.teardown(l)
        try await p.wait("link_closed")
    }

    /// Python A <-> us (transport) <-> Python B. A and B never connect to each other.
    func testThreeNodeTransport() async throws {
        _ = try PyEnv.python()
        let k = try await kit()
        let pa = try await PyPeer.start(.init(name: "A", connect: "127.0.0.1:\(k.port)"))
        let pb = try await PyPeer.start(.init(name: "B", connect: "127.0.0.1:\(k.port)"))
        try await waitFor("two tcp peers") { k.server.peerCount() >= 2 }

        try pa.send("announce")
        // B hears A's raw destination through our HEADER_2 rebroadcast at 2 hops.
        let ev = try await pb.wait("announce", { $0["dest"] as? String == pa.raw }, timeoutMs: 15_000)
        XCTAssertEqual(num(ev["hops"]), 2)
        try pb.send("has_path", ["dest": pa.raw])
        let pe = try await pb.wait("path")
        XCTAssertEqual(pe["next_hop"] as? String, k.node.idHashHex)

        // B -> A single packet through us, proof back via the reverse table.
        try pb.send("send_packet", ["dest": pa.raw, "data": "B to A through swift"])
        let got = try await pa.wait("packet_received", timeoutMs: 15_000)
        XCTAssertEqual(got["data"] as? String, "B to A through swift")
        XCTAssertEqual(num(got["hops"]), 2)
        try await pb.wait("packet_proved", timeoutMs: 15_000)

        // B -> A link through us: request in transit, proof validated in transit, data repeated both ways.
        try pb.send("link", ["dest": pa.raw])
        let le = try await pb.wait("link_established", timeoutMs: 20_000)
        let linkId = try XCTUnwrap(le["link"] as? String)
        try await pa.wait("link_established", { $0["link"] as? String == linkId }, timeoutMs: 20_000)
        try pb.send("link_send", ["link": linkId, "data": "on the transit link"])
        let lp = try await pa.wait("link_packet", timeoutMs: 15_000)
        XCTAssertEqual(lp["data"] as? String, "on the transit link")
        try await pb.wait("link_proof", timeoutMs: 15_000)
        try pb.send("link_close", ["link": linkId])
        try await pa.wait("link_closed", { $0["link"] as? String == linkId }, timeoutMs: 15_000)

        // Path request: B asks for our destination it has not heard (we announced nothing yet).
        let dh = k.dest.hashHex
        try pb.send("request_path", ["dest": dh])
        try await pb.wait("path_requested")
        try await waitFor("we count the path request") { k.node.stats().pathRequestsRx >= 1 }
        try await pb.wait("announce", { $0["dest"] as? String == dh }, timeoutMs: 15_000)  // the path response
        try pb.send("has_path", ["dest": dh])
        let pe2 = try await pb.wait("path")
        XCTAssertTrue(bool(pe2["known"]))
        XCTAssertEqual(num(pe2["hops"]), 1)
    }

    /// Us behind a stock rnsd transport: we learn a peer at 2 hops with the rnsd identity as next hop.
    func testBehindStockRnsd() async throws {
        _ = try PyEnv.python()
        let port = try await freePort()
        let tr = try await PyPeer.start(.init(name: "T", transport: true, listen: port))
        let pa = try await PyPeer.start(.init(name: "A", connect: "127.0.0.1:\(port)"))
        let k = try await kit(connect: "127.0.0.1:\(port)")
        try await waitFor("we are connected", timeoutMs: 15_000) { k.client?.isOnline == true }
        try await Task.sleep(nanoseconds: 500_000_000)

        try pa.send("announce")
        let praw = try h(pa.raw)
        try await waitFor("we learn A via T", timeoutMs: 20_000) { k.node.hopsTo(praw) == 2 }
        XCTAssertEqual(k.node.paths.get(praw)?.nextHop.hex, tr.transportId)
        // Us -> A through rnsd with proof back.
        let r = try XCTUnwrap(try k.node.sendData(praw, Array("swift to A via rnsd".utf8)))
        let got = try await pa.wait("packet_received", timeoutMs: 15_000)
        XCTAssertEqual(got["data"] as? String, "swift to A via rnsd")
        let res = try await r.result.wait(timeoutMs: 15_000)
        XCTAssertTrue(res.delivered)
        // We announce; A must see us at 2 hops via rnsd.
        k.node.announce(k.dest)
        let dh = k.dest.hashHex
        let ev = try await pa.wait("announce", { $0["dest"] as? String == dh }, timeoutMs: 15_000)
        XCTAssertEqual(num(ev["hops"]), 2)
        // A -> us link through rnsd.
        try pa.send("link", ["dest": dh])
        try await pa.wait("link_established", timeoutMs: 20_000)
        _ = try await k.links.take(timeoutMs: 15_000, "our link via rnsd")
        // (A path request answered by rnsd from its table is not asserted here: rnsd 1.5 rate-limits path
        // requests from a freshly connected peer, which made it time-dependent. Our own answering of path
        // requests is proven in testThreeNodeTransport.)
    }
}
