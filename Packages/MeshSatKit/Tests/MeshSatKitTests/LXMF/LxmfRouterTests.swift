// Mirrors lxmf/LxmfRouterTest.kt: two LXMF endpoints on in-memory nodes, end to end, including the
// satellite rules. [MESHSAT-1553, MESHSAT-1735]
import Foundation
import XCTest

@testable import MeshSatLXMF
@testable import MeshSatNet
@testable import MeshSatRns

final class LxmfRouterTests: XCTestCase {
    final class Queue<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []

        func add(_ v: T) {
            lock.lock()
            items.append(v)
            lock.unlock()
        }

        func poll(timeoutMs: Int64) async throws -> T? {
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
            while Date() < deadline {
                let v: T? = {
                    lock.lock()
                    defer { lock.unlock() }
                    return items.isEmpty ? nil : items.removeFirst()
                }()
                if let v { return v }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return nil
        }
    }

    final class Wires: @unchecked Sendable {
        struct End {
            let node: Node
            let iface: String
        }
        private let lock = NSLock()
        private var m: [String: End] = [:]

        func set(_ key: String, _ end: End) {
            lock.lock()
            m[key] = end
            lock.unlock()
        }

        func get(_ key: String) -> End? {
            lock.lock()
            defer { lock.unlock() }
            return m[key]
        }

        func ifaces(of name: String) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return m.keys.filter { $0.hasPrefix("\(name)/") }.map { String($0.dropFirst(name.count + 1)) }
        }

        func clear() {
            lock.lock()
            m = [:]
            lock.unlock()
        }
    }

    final class WireTx: Transmitter, @unchecked Sendable {
        let wires: Wires
        let name: String
        let paid: Set<String>
        let delayMs: Int64

        init(wires: Wires, name: String, paid: Set<String>, delayMs: Int64) {
            self.wires = wires
            self.name = name
            self.paid = paid
            self.delayMs = delayMs
        }

        func transmit(ifaceId: String, raw: [UInt8]) -> Bool {
            guard let end = wires.get("\(name)/\(ifaceId)") else { return true }
            let cp = raw
            let delay = delayMs
            Task.detached {
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) }
                end.node.inbound(cp, iface: end.iface)
            }
            return true
        }

        func floodable() -> [String] { wires.ifaces(of: name).filter { !paid.contains($0) }.sorted() }
        func hwMtu(ifaceId: String) -> Int { 500 }
    }

    private let wires = Wires()
    private var nodes: [String: Node] = [:]
    private var routers: [LxmfRouter] = []

    override func tearDown() {
        for r in routers { r.stop() }
        for n in nodes.values { n.stop() }
        routers = []
        nodes = [:]
        super.tearDown()
    }

    private func endpoint(_ name: String, stampCost: Int = 0, paid: Set<String> = [], delayMs: Int64 = 0) -> (LxmfRouter, Queue<LxMessage>)
    {
        let got = Queue<LxMessage>()
        let log: @Sendable (String) -> Void = { FileHandle.standardError.write(Data("[\(name)] \($0)\n".utf8)) }
        let n = Node(
            cfg: NodeConfig(identity: RnsIdentity.generate(), log: log), tx: WireTx(wires: wires, name: name, paid: paid, delayMs: delayMs))
        var cfg = LxmfRouter.Config(identity: n.identity, displayName: "Endpoint \(name)")
        cfg.stampCost = stampCost
        cfg.enforceStamps = stampCost > 0
        cfg.onMessage = { got.add($0) }
        cfg.log = { FileHandle.standardError.write(Data("[\(name) lxmf] \($0)\n".utf8)) }
        let r = LxmfRouter(node: n, config: cfg)
        n.start()
        r.start()
        nodes[name] = n
        routers.append(r)
        return (r, got)
    }

    private func connect(_ a: String, _ aIface: String, _ b: String, _ bIface: String) {
        wires.set("\(a)/\(aIface)", .init(node: nodes[b]!, iface: bIface))
        wires.set("\(b)/\(bIface)", .init(node: nodes[a]!, iface: aIface))
    }

    private func waitFor(_ what: String, timeoutMs: Int64 = 10_000, file: StaticString = #filePath, line: UInt = #line, _ cond: () -> Bool)
        async throws
    {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if cond() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timeout waiting for \(what)", file: file, line: line)
        throw NodeError("timeout waiting for \(what)")
    }

    private func take(_ q: Queue<LxMessage>, _ what: String, timeoutMs: Int64 = 5000) async throws -> LxMessage {
        let m = try await q.poll(timeoutMs: timeoutMs)
        return try XCTUnwrap(m, "timeout waiting for \(what)")
    }

    func testOpportunisticDirectWithLinkReuseAResourceAndTheBackchannel() async throws {
        let (a, gotA) = endpoint("a")
        let (b, gotB) = endpoint("b")
        connect("a", "ab", "b", "ba")
        XCTAssertTrue(b.announce())
        XCTAssertTrue(a.announce())
        try await waitFor("A knows B") { a.node.paths.has(b.hash) }
        try await waitFor("B knows A") { b.node.paths.has(a.hash) }
        XCTAssertEqual(a.peerInfo(b.hash)?.displayName, "Endpoint b")
        XCTAssertTrue(a.peers().contains { $0.destHash == b.hashHex && $0.hasRatchet })

        // Auto picks opportunistic for a short message to a peer with a ratchet and no link.
        let o1 = try a.send(b.hash, content: Array("hello b".utf8), title: Array("t1".utf8))
        XCTAssertEqual(o1.method, .opportunistic)
        let s1 = try await o1.result.wait(timeoutMs: 15_000)
        XCTAssertEqual(s1, .delivered)
        let m1 = try await take(gotB, "m1")
        XCTAssertEqual(m1.contentString, "hello b")
        XCTAssertEqual(m1.titleString, "t1")
        XCTAssertTrue(m1.signatureValid)
        XCTAssertEqual(m1.method, .opportunistic)
        XCTAssertEqual(m1.hashHex, o1.hashHex)

        // Direct: a link, then a second message reuses it.
        let o2 = try a.send(b.hash, content: Array(String(repeating: "d", count: 310).utf8), method: .direct)
        let s2 = try await o2.result.wait(timeoutMs: 20_000)
        XCTAssertEqual(s2, .delivered)
        let got1 = try await take(gotB, "m2")
        XCTAssertEqual(got1.method, .direct)
        let linksBefore = a.node.links.all().count
        let o3 = try a.send(b.hash, content: Array(String(repeating: "e", count: 300).utf8), method: .direct)
        let s3 = try await o3.result.wait(timeoutMs: 20_000)
        XCTAssertEqual(s3, .delivered)
        _ = try await take(gotB, "m3")
        XCTAssertEqual(a.node.links.all().count, linksBefore)

        // A resource for a large message on the same link.
        let big = String(repeating: "resource payload from a. ", count: 120)
        let o4 = try a.send(b.hash, content: Array(big.utf8), title: Array("big".utf8), method: .direct)
        XCTAssertEqual(o4.representation, .resource)
        let s4 = try await o4.result.wait(timeoutMs: 30_000)
        XCTAssertEqual(s4, .delivered)
        let got2 = try await take(gotB, "m4")
        XCTAssertEqual(got2.contentString, big)

        // The backchannel: B answers on the link A opened and identified on, no new link.
        try await waitFor("B sees A's identity on the link") { b.deliveryLinkAvailable(a.hash) }
        let before = b.node.links.all().count
        let o5 = try b.send(a.hash, content: Array("reply on the backchannel".utf8), method: .direct)
        let s5 = try await o5.result.wait(timeoutMs: 20_000)
        XCTAssertEqual(s5, .delivered)
        let got3 = try await take(gotA, "m5")
        XCTAssertEqual(got3.contentString, "reply on the backchannel")
        XCTAssertEqual(b.node.links.all().count, before)
    }

    func testStampsAtCost6AreGeneratedForAPeerThatDemandsThemAndCheckedOnReceipt() async throws {
        let (a, _) = endpoint("a", stampCost: 6)
        let (b, gotB) = endpoint("b", stampCost: 6)
        connect("a", "ab", "b", "ba")
        b.announce()
        a.announce()
        try await waitFor("A knows B") { a.node.paths.has(b.hash) }
        try await waitFor("B knows A") { b.node.paths.has(a.hash) }
        XCTAssertEqual(a.peerInfo(b.hash)?.stampCost, 6)
        let o = try a.send(b.hash, content: Array("stamped".utf8))
        XCTAssertNotNil(o.message.stamp)
        let s = try await o.result.wait(timeoutMs: 20_000)
        XCTAssertEqual(s, .delivered)
        let m = try await take(gotB, "the stamped message")
        XCTAssertTrue(m.stampChecked)
        XCTAssertTrue(m.stampValid)
        XCTAssertGreaterThanOrEqual(m.stampValue, 6)
    }

    func testAcrossAPaidLinkAutoPicksDirectAndWaitsForTheSlowRoundTrip() async throws {
        // a =sat= b, both ends with a policy that lists both delivery destinations and 4 extra hops, 2 s each
        // way: 6 x (1 + 4 + 1) s of link patience covers 4 s round trips with room.
        let (a, gotA) = endpoint("a", paid: ["sat"], delayMs: 2000)
        let (b, gotB) = endpoint("b", paid: ["sat"], delayMs: 2000)
        connect("a", "sat", "b", "sat")
        for r in routers { r.node.setPaidPolicy("sat", PaidPolicy(dests: [a.hash, b.hash], extraHops: 4)) }
        XCTAssertTrue(b.announce())
        XCTAssertTrue(a.announce())
        try await waitFor("A knows B over the satellite", timeoutMs: 15_000) { a.node.paths.has(b.hash) }
        try await waitFor("B knows A over the satellite", timeoutMs: 15_000) { b.node.paths.has(a.hash) }
        XCTAssertEqual(a.node.paths.hops(b.hash), 5)
        XCTAssertTrue(a.node.crossesPaidLink(b.hash))
        let o = try a.send(b.hash, content: Array("across the sky".utf8))
        XCTAssertEqual(o.method, .direct)
        let s = try await o.result.wait(timeoutMs: 60_000)
        XCTAssertEqual(s, .delivered)
        let got4 = try await take(gotB, "across")
        XCTAssertEqual(got4.contentString, "across the sky")
        // The reply comes back on the same link.
        let r = try b.send(a.hash, content: Array("and back".utf8))
        XCTAssertEqual(r.method, .direct)
        let rs = try await r.result.wait(timeoutMs: 60_000)
        XCTAssertEqual(rs, .delivered)
        let got5 = try await take(gotA, "back")
        XCTAssertEqual(got5.contentString, "and back")
    }

    func testAMessageToAnUnreachablePeerFailsAfterTheAttempts() async throws {
        let (a, _) = endpoint("a")
        let (b, _) = endpoint("b")
        connect("a", "ab", "b", "ba")
        b.announce()
        try await waitFor("A knows B") { a.node.paths.has(b.hash) }
        wires.clear()  // the wire breaks
        let o = try a.send(b.hash, content: Array("lost".utf8), method: .opportunistic)
        let s = try await o.result.wait(timeoutMs: 120_000)
        XCTAssertEqual(s, .failed)
        XCTAssertGreaterThanOrEqual(o.attempts, 3)
    }
}
