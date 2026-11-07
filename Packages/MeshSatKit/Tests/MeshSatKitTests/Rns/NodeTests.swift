// Mirrors rns/NodeTest.kt (the Bridge's node_test.go): nodes wired back to back in memory, a packet a
// node transmits on "ab" arrives at the peer on "ba" a moment later, like a wire. [MESHSAT-1735]
import XCTest

@testable import MeshSatNet
@testable import MeshSatRns

final class NodeTests: XCTestCase {
    final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var v: T
        init(_ v: T) { self.v = v }
        var value: T {
            get {
                lock.lock()
                defer { lock.unlock() }
                return v
            }
            set {
                lock.lock()
                v = newValue
                lock.unlock()
            }
        }
    }

    final class FakeNet: @unchecked Sendable {
        struct Wire: Sendable {
            let peer: Node
            let peerIface: String
        }
        private let lock = NSLock()
        private var wires: [String: Wire] = [:]

        /// One end of a wire: a node, its name and the interface id on that node.
        struct End {
            let node: Node
            let name: String
            let iface: String
            init(_ node: Node, _ name: String, _ iface: String) {
                self.node = node
                self.name = name
                self.iface = iface
            }
        }

        func connect(_ a: End, _ b: End) {
            lock.lock()
            defer { lock.unlock() }
            wires["\(a.name)/\(a.iface)"] = Wire(peer: b.node, peerIface: b.iface)
            wires["\(b.name)/\(b.iface)"] = Wire(peer: a.node, peerIface: a.iface)
        }

        func wire(_ key: String) -> Wire? {
            lock.lock()
            defer { lock.unlock() }
            return wires[key]
        }

        func ifaces(of name: String) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return wires.keys.filter { $0.hasPrefix("\(name)/") }.map { String($0.dropFirst(name.count + 1)) }
        }
    }

    final class FakeTx: Transmitter, @unchecked Sendable {
        let net: FakeNet
        let name: String
        private let lock = NSLock()
        private var sentRaw: [String: Int] = [:]
        private var paid: Set<String> = []

        init(net: FakeNet, name: String) {
            self.net = net
            self.name = name
        }

        func sent(_ iface: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return sentRaw[iface] ?? 0
        }

        func addPaid(_ iface: String) {
            lock.lock()
            defer { lock.unlock() }
            paid.insert(iface)
        }

        func transmit(ifaceId: String, raw: [UInt8]) -> Bool {
            lock.lock()
            sentRaw[ifaceId, default: 0] += 1
            lock.unlock()
            guard let w = net.wire("\(name)/\(ifaceId)") else { return true }
            let cp = raw
            Task.detached { w.peer.inbound(cp, iface: w.peerIface) }
            return true
        }

        func floodable() -> [String] {
            let p: Set<String> = {
                lock.lock()
                defer { lock.unlock() }
                return paid
            }()
            return net.ifaces(of: name).filter { !p.contains($0) }.sorted()
        }

        func hwMtu(ifaceId: String) -> Int { 500 }
    }

    private var net = FakeNet()
    private var nodes: [Node] = []

    override func setUp() {
        super.setUp()
        net = FakeNet()
        nodes = []
    }

    override func tearDown() {
        for n in nodes { n.stop() }
        super.tearDown()
    }

    private func node(_ name: String) -> (Node, FakeTx) {
        let tx = FakeTx(net: net, name: name)
        let n = Node(cfg: NodeConfig(identity: RnsIdentity.generate()), tx: tx)
        nodes.append(n)
        return (n, tx)
    }

    private func waitFor(
        _ what: String, timeoutMs: Int64 = 5000, file: StaticString = #filePath, line: UInt = #line, _ cond: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if cond() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timeout waiting for \(what)", file: file, line: line)
        throw NodeError("timeout waiting for \(what)")
    }

    private func text(_ b: [UInt8]?) -> String? { b.map { String(decoding: $0, as: UTF8.self) } }

    func testThreeNodesInALineWithTTheTransport() async throws {
        let (a, _) = node("a")
        let (t, _) = node("t")
        let (b, _) = node("b")
        net.connect(.init(a, "a", "at"), .init(t, "t", "ta"))
        net.connect(.init(t, "t", "tb"), .init(b, "b", "bt"))
        a.start()
        t.start()
        b.start()

        let got = Box<[UInt8]?>(nil)
        let linkGot = Box<[UInt8]?>(nil)
        let bDest = b.addDestination("test.delivery") { d in
            d.acceptLinks = true
            d.proveAll = true
            d.onPacket = { plain, _ in got.value = plain }
            d.onLinkPacket = { _, plain, _ in linkGot.value = plain }
        }
        a.addDestination("test.delivery")

        // B announces; T learns it at 1 hop and rebroadcasts as HEADER_2; A learns it at 2 hops.
        XCTAssertTrue(b.announce(bDest))
        try await waitFor("T learns B") { t.paths.hops(bDest.hash) == 1 }
        try await waitFor("A learns B via T", timeoutMs: 10_000) { a.paths.hops(bDest.hash) == 2 }
        XCTAssertEqual(a.paths.get(bDest.hash)?.nextHop, t.idHash)
        XCTAssertNotNil(a.recall(bDest.hash)?.identity)

        // Single packet A -> B through T, proof back through the reverse table.
        let r = try XCTUnwrap(try a.sendData(bDest.hash, Array("hello through transport".utf8)))
        try await waitFor("B receives") { text(got.value) == "hello through transport" }
        let delivered = try await r.result.wait(timeoutMs: 5000)
        XCTAssertTrue(delivered.delivered)

        // Link A -> B through T: request in transit, proof validated in transit, data proved.
        let l = try a.links.initiate(bDest.hash)
        _ = try await l.established.wait(timeoutMs: 5000)
        try await waitFor("responder active") { b.links.all().contains { $0.id == l.id && $0.state == .active } }
        let lr = try a.links.send(l, Array("over the link".utf8))
        try await waitFor("link data at B") { text(linkGot.value) == "over the link" }
        let linkDelivered = try await lr.result.wait(timeoutMs: 5000)
        XCTAssertTrue(linkDelivered.delivered)
        try a.links.identify(l, a.identity)
        try await waitFor("B identified A") { b.links.all().contains { $0.id == l.id && $0.remoteIdentity != nil } }
        XCTAssertEqual(b.links.get(l.id)?.remoteIdentity, a.identity.publicBytes)
        a.links.teardown(l)
        try await waitFor("B closed") { b.links.get(l.id) == nil }

        // Path request from A for a destination C that only announces later.
        let (c, _) = node("c")
        net.connect(.init(b, "b", "bc"), .init(c, "c", "cb"))
        c.start()
        let cDest = c.addDestination("test.delivery")
        let f = a.requestPath(cDest.hash, timeoutMs: 5000)
        try await Task.sleep(nanoseconds: 200_000_000)
        c.announce(cDest)
        let found = try await f.wait(timeoutMs: 6000)
        XCTAssertTrue(found)
        XCTAssertEqual(a.paths.hops(cDest.hash), 3)
    }

    func testAResourceCrossesALinkAndASecondOneReusesIt() async throws {
        let (a, _) = node("a")
        let (b, _) = node("b")
        net.connect(.init(a, "a", "ab"), .init(b, "b", "ba"))
        a.start()
        b.start()
        let got = Box<[UInt8]?>(nil)
        let bDest = b.addDestination("test.delivery") { d in
            d.acceptLinks = true
            d.acceptResources = { size in (1...(1 << 20)).contains(size) }
            d.onLinkResource = { _, data in got.value = data }
        }
        b.announce(bDest)
        try await waitFor("A learns B") { a.paths.hops(bDest.hash) == 1 }
        let l = try a.links.initiate(bDest.hash)
        _ = try await l.established.wait(timeoutMs: 5000)
        let payload = (0..<3000).map { UInt8($0 % 251) }
        let res = try a.links.sendResource(l, payload)
        let out = try await res.result.wait(timeoutMs: 10_000)
        XCTAssertTrue(out.delivered, out.error ?? "")
        try await waitFor("resource at B") { got.value != nil }
        XCTAssertEqual(got.value, payload)
        let res2 = try a.links.sendResource(l, (0..<20_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let out2 = try await res2.result.wait(timeoutMs: 15_000)
        XCTAssertTrue(out2.delivered, out2.error ?? "")
        XCTAssertEqual(a.links.all().count, 1)
    }

    func testThePacketFilterDropsDuplicatesAndPacketsForAnotherTransport() throws {
        let (a, _) = node("a")
        let id = RnsIdentity.generate()
        let raw = try Header(destType: Rns.destSingle, packetType: Rns.packetData, destHash: id.destHash("x"), data: Array("d".utf8)).pack()
        // A SINGLE packet for an unknown remote destination is not ours: declined, so the legacy framing may
        // try, but it enters the hash list and a second copy is filtered.
        XCTAssertFalse(a.inbound(raw, iface: "x"))
        let before = a.stats().filtered
        a.inbound(raw, iface: "x")
        XCTAssertEqual(a.stats().filtered, before + 1)
        var other = [UInt8](repeating: 0, count: 16)
        other[0] = 1
        var raw2 = Header.rewriteForTransport(raw, transportId: other)
        raw2[raw2.count - 1] ^= 0xFF
        a.inbound(raw2, iface: "x")
        XCTAssertEqual(a.stats().filtered, before + 2)
        // Things the node never handles fall through for the legacy stack.
        XCTAssertFalse(a.inbound([UInt8](repeating: 0, count: 10), iface: "x"))
        let plain = try Header(destType: Rns.destPlain, destHash: Rns.plainDestHash("meshsat.legacy"), data: Array("x".utf8)).pack()
        XCTAssertFalse(a.inbound(plain, iface: "x"))
    }

    func testANewerAnnounceReplacesThePathAnOlderOneDoesNot() throws {
        let (a, _) = node("a")
        let id = RnsIdentity.generate()
        let old = try Announce.create(identity: id, name: "lxmf.delivery", appData: nil, nowSec: 1_700_000_000)
        let newer = try Announce.create(identity: id, name: "lxmf.delivery", appData: nil, nowSec: 1_700_000_100)
        XCTAssertTrue(a.inbound(try newer.packet(), iface: "x"))
        XCTAssertEqual(a.paths.hops(newer.destHash), 1)
        let first = try XCTUnwrap(a.paths.get(newer.destHash))
        // Older emission, more hops: kept out.
        let oldRaw = try old.transportPacket(transportId: Rns.randomBytes(16), hops: 2, context: Rns.ctxNone)
        a.inbound(oldRaw, iface: "y")
        XCTAssertTrue(a.paths.get(newer.destHash) === first)
        // Newer emission at more hops replaces (the path's blob set is older).
        let newest = try Announce.create(identity: id, name: "lxmf.delivery", appData: nil, nowSec: 1_700_000_200)
        a.inbound(try newest.transportPacket(transportId: Rns.randomBytes(16), hops: 2, context: Rns.ctxNone), iface: "y")
        XCTAssertEqual(a.paths.hops(newer.destHash), 3)  // the packet's 2 plus this hop
        XCTAssertEqual(a.paths.get(newer.destHash)?.iface, "y")
    }

    func testANeighbourHeardAcrossAPaidLinkGetsHeader1PacketsHoweverManyHopsItCounts() async throws {
        let (a, _) = node("a")
        let (b, _) = node("b")
        net.connect(.init(a, "a", "sat"), .init(b, "b", "sat"))
        for n in [a, b] { n.setPaidPolicy("sat", PaidPolicy(dests: [], extraHops: 8)) }
        let seen = Box<[Int]>([])
        let bDest = b.addDestination("test.delivery") { d in
            d.proveAll = true
            d.onPacket = { _, pkt in seen.value.append(pkt.hdr.headerType) }
        }
        for n in [a, b] { n.setPaidPolicy("sat", PaidPolicy(dests: [bDest.hash], extraHops: 8)) }
        a.start()
        b.start()
        XCTAssertTrue(b.announce(bDest))
        try await waitFor("A learns B over the paid link") { a.paths.has(bDest.hash) }
        XCTAssertEqual(a.paths.hops(bDest.hash), 9)
        XCTAssertTrue(try XCTUnwrap(a.paths.get(bDest.hash)).direct)  // next hop is B itself
        let r = try XCTUnwrap(try a.sendData(bDest.hash, Array("to the neighbour".utf8)))
        let res = try await r.result.wait(timeoutMs: 5000)
        XCTAssertTrue(res.delivered)
        XCTAssertEqual(seen.value, [Rns.header1])
        // A HEADER_2 naming B's own destination as the transport id is still taken as local (older senders).
        let enc = try XCTUnwrap(a.recall(bDest.hash)?.identity).encrypt(Array("tolerated".utf8))
        let raw = Header.rewriteForTransport(try Header(destHash: bDest.hash, data: enc).pack(), transportId: bDest.hash)
        XCTAssertTrue(b.inbound(raw, iface: "sat"))
        try await waitFor("tolerated packet delivered") { seen.value.count == 2 }
    }

    func testAPaidInterfaceCarriesOnlyListedDestinationsWithExtraHops() async throws {
        let (a, txA) = node("a")
        let (b, txB) = node("b")
        net.connect(.init(a, "a", "sat"), .init(b, "b", "sat"))
        txA.addPaid("sat")
        txB.addPaid("sat")
        a.start()
        b.start()
        let listed = b.addDestination("lxmf.delivery")
        let unlisted = b.addDestination("meshsat.node")
        // Nothing floodable: an announce goes nowhere without a policy.
        XCTAssertFalse(b.announce(unlisted))
        XCTAssertEqual(txB.sent("sat"), 0)
        for n in [a, b] { n.setPaidPolicy("sat", PaidPolicy(dests: [listed.hash], extraHops: 20)) }
        XCTAssertFalse(b.announce(unlisted))
        XCTAssertTrue(b.announce(listed))
        try await waitFor("A learns the listed destination over the paid link") { a.paths.has(listed.hash) }
        XCTAssertEqual(a.paths.hops(listed.hash), 21)  // 1 + 20 extra
        XCTAssertTrue(a.crossesPaidLink(listed.hash))
        XCTAssertNil(a.paths.get(unlisted.hash))
        // The interval gate: a second announce inside five minutes is held back, so nothing is sent.
        let tx = b.stats().paidTx
        XCTAssertFalse(b.announce(listed))
        XCTAssertEqual(b.stats().paidTx, tx)
        XCTAssertGreaterThan(b.stats().paidSuppressed, 0)
    }
}
