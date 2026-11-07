// The stack over RnsInterfaces (the app's shape): two stacks on in-memory interfaces wired back to back
// exchange an LXMF text, the paid policy always lists our own address, the propagation choice parses as
// Android's does, and bytes that are not a Reticulum packet fall through to the legacy stack.
import Foundation
import XCTest

@testable import MeshSatCrypto
@testable import MeshSatLXMF
@testable import MeshSatNet
@testable import MeshSatReticulum
@testable import MeshSatRns

final class RnsStackTests: XCTestCase {
    /// An in-memory RnsInterface: what one end sends, the other's receive callback gets a moment later.
    final class PipeInterface: RnsInterface, @unchecked Sendable {
        let interfaceId: String
        let name = "pipe"
        let mtu = 500
        let costCents = 0
        let latencyMs = 1
        let isBidirectional = true
        var isOnline = true
        private let lock = NSLock()
        private var callback: RnsReceiveCallback?
        private var peerValue: PipeInterface?

        init(_ id: String) { interfaceId = id }

        var peer: PipeInterface? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return peerValue
            }
            set {
                lock.lock()
                peerValue = newValue
                lock.unlock()
            }
        }

        func setReceiveCallback(_ callback: RnsReceiveCallback?) {
            lock.lock()
            self.callback = callback
            lock.unlock()
        }

        func deliver(_ raw: [UInt8]) {
            lock.lock()
            let cb = callback
            lock.unlock()
            cb?(interfaceId, raw)
        }

        func send(_ packet: [UInt8]) async -> String? {
            guard let p = peer else { return "no peer" }
            try? await Task.sleep(nanoseconds: 1_000_000)
            p.deliver(packet)
            return nil
        }

        func start() async {}
        func stop() async {}
    }

    final class MemoryStore: RnsStackStore, @unchecked Sendable {
        private let lock = NSLock()
        private var m: [String: String] = [:]
        func get(_ key: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return m[key]
        }
        func set(_ key: String, _ value: String) {
            lock.lock()
            m[key] = value
            lock.unlock()
        }
    }

    final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var v: [T] = []
        func add(_ x: T) {
            lock.lock()
            v.append(x)
            lock.unlock()
        }
        var all: [T] {
            lock.lock()
            defer { lock.unlock() }
            return v
        }
    }

    private var stacks: [RnsStack] = []

    override func tearDown() {
        for s in stacks { s.stop() }
        stacks = []
        super.tearDown()
    }

    private func stack(_ name: String, iface: PipeInterface, store: MemoryStore = MemoryStore(), got: Box<LxMessage>) -> RnsStack {
        let log: @Sendable (String) -> Void = { FileHandle.standardError.write(Data("[\(name)] \($0)\n".utf8)) }
        let s = RnsStack(
            identity: Identity.generate(), interfaces: { [iface.interfaceId: iface] }, store: store, displayName: "Phone \(name)",
            onMessage: { got.add($0) }, onOutboundState: { _ in }, log: log)
        iface.setReceiveCallback { id, raw in _ = s.inbound(id, raw) }
        stacks.append(s)
        return s
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

    func testTwoStacksExchangeATextAndTheRatchetsPersist() async throws {
        let ia = PipeInterface("tcp_rns_0")
        let ib = PipeInterface("tcp_rns_0")
        ia.peer = ib
        ib.peer = ia
        let gotA = Box<LxMessage>()
        let gotB = Box<LxMessage>()
        let storeA = MemoryStore()
        let a = stack("a", iface: ia, store: storeA, got: gotA)
        let b = stack("b", iface: ib, got: gotB)
        a.start(announceIntervalMs: 600_000)
        b.start(announceIntervalMs: 600_000)
        XCTAssertTrue(b.announce())
        XCTAssertTrue(a.announce())
        try await waitFor("A knows B") { a.node.paths.has(b.lxmf.hash) }
        try await waitFor("B knows A") { b.node.paths.has(a.lxmf.hash) }
        XCTAssertNotNil(storeA.get(RnsStack.keyRatchets), "the announce rotated a ratchet and the store kept it")
        let o = try a.send(b.lxmf.hash, content: "hello from a", title: "t")
        let state = try await o.result.wait(timeoutMs: 20_000)
        XCTAssertEqual(state, .delivered)
        try await waitFor("B has the text") { !gotB.all.isEmpty }
        XCTAssertEqual(gotB.all.first?.contentString, "hello from a")
        XCTAssertEqual(gotB.all.first?.sourceHex, a.lxmfAddress)
        XCTAssertEqual(RnsStack.lxmfAddress(of: Identity.generate()).count, 32)
    }

    func testThePaidPolicyListsOurOwnAddressAndOnlyPaidInterfacesGetIt() throws {
        let sat = PipeInterface("iridium9704_rns_0")
        let tcp = PipeInterface("tcp_rns_0")
        let log: @Sendable (String) -> Void = { _ in }
        let s = RnsStack(
            identity: Identity.generate(), interfaces: { ["iridium9704_rns_0": sat, "tcp_rns_0": tcp] }, store: MemoryStore(),
            displayName: "p",
            onMessage: { _ in }, onOutboundState: { _ in }, log: log)
        stacks.append(s)
        let other = RnsIdentity.generate().destHash(LxMessage.deliveryName)
        s.setPaidPolicy(dests: [other, other], extraHops: 99, minIntervalMs: 60_000)
        let policies = s.node.paidPolicies()
        XCTAssertEqual(Array(policies.keys), ["iridium9704_rns_0"])
        let p = try XCTUnwrap(policies["iridium9704_rns_0"])
        XCTAssertEqual(p.dests, [other, s.lxmf.hash])
        XCTAssertEqual(p.extraHops, PaidPolicy.maxExtraHops)
        XCTAssertTrue(RnsStack.isPaidInterface("iridium9704_rns_0"))
        XCTAssertFalse(RnsStack.isPaidInterface("tcp_rns_0"))
        XCTAssertEqual(s.transmitter.floodable(), ["tcp_rns_0"])
    }

    func testThePropagationChoiceParsesAsAndroids() {
        let s = RnsStack(
            identity: Identity.generate(), interfaces: { [:] }, store: MemoryStore(), displayName: "p", onMessage: { _ in },
            onOutboundState: { _ in })
        stacks.append(s)
        s.setPropagationNode("none")
        XCTAssertFalse(s.lxmf.autoSelectPropagationNode)
        XCTAssertNil(s.lxmf.propagationNodeFixedHex)
        s.setPropagationNode(" 00112233445566778899AABBCCDDEEFF ")
        XCTAssertTrue(s.lxmf.autoSelectPropagationNode)
        XCTAssertEqual(s.lxmf.propagationNodeFixedHex, "00112233445566778899aabbccddeeff")
        s.setPropagationNode("")
        XCTAssertTrue(s.lxmf.autoSelectPropagationNode)
        XCTAssertNil(s.lxmf.propagationNodeFixedHex)
        // Not a Reticulum packet: the legacy stack's turn.
        XCTAssertFalse(s.inbound("tcp_rns_0", [1, 2, 3]))
        XCTAssertFalse(s.inbound("tcp_rns_0", [0x00, 0xFF] + [UInt8](repeating: 0x55, count: 38)))  // hops 255: not a packet a peer keeps
    }
}
