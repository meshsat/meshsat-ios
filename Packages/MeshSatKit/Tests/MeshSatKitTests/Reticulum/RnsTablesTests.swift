// Ports RnsPathTableTest.kt, RnsResourceTest.kt and the forwarding-table half of
// RnsTransportNodeTest.kt.
import XCTest

@testable import MeshSatReticulum

/// An interface that is only its numbers, as Android's makeInterface.
final class StubInterface: RnsInterface, @unchecked Sendable {
    let interfaceId: String
    let name: String
    let mtu = 500
    let costCents: Int
    let latencyMs: Int
    let isBidirectional = true
    var isOnline: Bool
    private let lock = NSLock()
    private(set) var sent: [[UInt8]] = []
    private var callback: RnsReceiveCallback?
    var sendError: String?

    init(_ id: String, cost: Int = 0, latency: Int = 0, online: Bool = true) {
        interfaceId = id
        name = id
        costCents = cost
        latencyMs = latency
        isOnline = online
    }

    func setReceiveCallback(_ callback: RnsReceiveCallback?) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func send(_ packet: [UInt8]) async -> String? { record(packet) }

    private func record(_ packet: [UInt8]) -> String? {
        lock.lock()
        defer { lock.unlock() }
        sent.append(packet)
        return sendError
    }

    func start() async {}
    func stop() async {}

    /// A packet arriving from the far side.
    func inject(_ raw: [UInt8]) {
        lock.lock()
        let cb = callback
        lock.unlock()
        cb?(interfaceId, raw)
    }

    var sentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sent.count
    }
}

private func dest(_ b: UInt8 = 0x01) -> [UInt8] { [UInt8](repeating: b, count: 16) }

final class RnsPathTableTests: XCTestCase {
    func testUpdateFromAnnounceNewAndExisting() {
        let table = RnsPathTable(interfaces: { [StubInterface("mesh_0")] })
        XCTAssertTrue(table.updateFromAnnounce(destHash: dest(), interfaceId: "mesh_0", hops: 3))
        XCTAssertFalse(table.updateFromAnnounce(destHash: dest(), interfaceId: "mesh_0", hops: 2))
        let path = table.bestPath(dest())
        XCTAssertEqual(path?.interfaceId, "mesh_0")
        XCTAssertEqual(path?.hops, 2)
        XCTAssertTrue(table.hasPath(dest()))
        XCTAssertEqual(table.hopsTo(dest()), 2)
        XCTAssertNil(RnsPathTable(interfaces: { [] }).bestPath(dest()))
        XCTAssertEqual(RnsPathTable(interfaces: { [] }).hopsTo(dest()), -1)
    }

    func testCostAwareRouting() {
        let ifaces = [StubInterface("mesh_0", cost: 0, latency: 200), StubInterface("iridium_0", cost: 5, latency: 60000)]
        let table = RnsPathTable(interfaces: { ifaces })
        table.updateFromAnnounce(destHash: dest(), interfaceId: "mesh_0", hops: 3)
        table.updateFromAnnounce(destHash: dest(), interfaceId: "iridium_0", hops: 1)
        XCTAssertEqual(table.bestPath(dest())?.interfaceId, "mesh_0", "free, even though more hops")

        let free = [StubInterface("mesh_0"), StubInterface("aprs_0")]
        let t2 = RnsPathTable(interfaces: { free })
        t2.updateFromAnnounce(destHash: dest(), interfaceId: "mesh_0", hops: 5)
        t2.updateFromAnnounce(destHash: dest(), interfaceId: "aprs_0", hops: 2)
        XCTAssertEqual(t2.bestPath(dest())?.interfaceId, "aprs_0")

        let mixed = [StubInterface("mesh_0", cost: 0, online: false), StubInterface("sms_0", cost: 1, online: true)]
        let t3 = RnsPathTable(interfaces: { mixed })
        t3.updateFromAnnounce(destHash: dest(), interfaceId: "mesh_0", hops: 1)
        t3.updateFromAnnounce(destHash: dest(), interfaceId: "sms_0", hops: 1)
        XCTAssertEqual(t3.bestPath(dest())?.interfaceId, "sms_0", "online, even though more expensive")

        let three = [StubInterface("iridium_0", cost: 5), StubInterface("sms_0", cost: 1), StubInterface("mesh_0", cost: 0)]
        let t4 = RnsPathTable(interfaces: { three })
        for id in ["iridium_0", "sms_0", "mesh_0"] { t4.updateFromAnnounce(destHash: dest(), interfaceId: id, hops: 1) }
        XCTAssertEqual(t4.allPaths(dest()).map { $0.interfaceId }, ["mesh_0", "sms_0", "iridium_0"])
    }

    func testMultiPathRemovalAndScores() {
        let ifaces = [StubInterface("mesh_0"), StubInterface("sms_0")]
        let table = RnsPathTable(interfaces: { ifaces })
        table.updateFromAnnounce(destHash: dest(), interfaceId: "mesh_0", hops: 1)
        table.updateFromAnnounce(destHash: dest(), interfaceId: "sms_0", hops: 2)
        XCTAssertEqual(table.destCount(), 1)
        XCTAssertEqual(table.pathCount(), 2)
        table.removeInterface("mesh_0")
        XCTAssertEqual(table.pathCount(), 1)
        XCTAssertEqual(table.bestPath(dest())?.interfaceId, "sms_0")
        table.removeDest(dest())
        XCTAssertFalse(table.hasPath(dest()))

        let path = RnsPath(destHash: dest(), nextHop: nil, interfaceId: "mesh_0", hops: 3, costCents: 0, latencyMs: 200)
        XCTAssertEqual(path.score, 302)
        let paid = RnsPath(destHash: dest(), nextHop: nil, interfaceId: "iridium_0", hops: 1, costCents: 5, latencyMs: 60000)
        XCTAssertLessThan(path.score, paid.score)
    }

    func testUpdatePrefersLowerHopCountAndNeverRaisesIt() {
        let table = RnsPathTable(interfaces: { [StubInterface("mesh_0")] })
        table.updateFromAnnounce(destHash: dest(), interfaceId: "mesh_0", hops: 5)
        XCTAssertEqual(table.bestPath(dest())?.hops, 5)
        table.updateFromAnnounce(destHash: dest(), interfaceId: "mesh_0", hops: 2)
        XCTAssertEqual(table.bestPath(dest())?.hops, 2)
        table.updateFromAnnounce(destHash: dest(), interfaceId: "mesh_0", hops: 5)
        XCTAssertEqual(table.bestPath(dest())?.hops, 2)
        XCTAssertEqual(table.bestPath(dest())?.announceCount, 3)
    }

    func testExpiryStaleAndPrune() {
        let clock = Slept()
        clock.add(1_000)
        let now: @Sendable () -> Int64 = { clock.values.reduce(0, +) }
        let table = RnsPathTable(interfaces: { [StubInterface("mesh_0")] }, pathTtlMs: 10_000, now: now)
        table.updateFromAnnounce(destHash: dest(), interfaceId: "mesh_0", hops: 1)
        XCTAssertTrue(table.hasPath(dest()))
        table.markInterfaceStale("mesh_0")
        clock.add(5 * 60_000 + 1)
        XCTAssertFalse(table.hasPath(dest()), "stale paths get five minutes, not the full TTL")
        XCTAssertEqual(table.pathCount(), 1)
        table.prune()
        XCTAssertEqual(table.pathCount(), 0)
        XCTAssertEqual(table.destCount(), 0)
    }

    func testPathDiscoveryPackets() throws {
        XCTAssertGreaterThanOrEqual(RnsPathDiscovery.createRequest(targetDestHash: dest()).count, 18)
        let target = dest(0x01)
        let nextHop = dest(0x02)
        let raw = RnsPathDiscovery.createResponse(requesterDestHash: dest(0x03), targetDestHash: target, nextHop: nextHop, hops: 3)
        let packet = try RnsPacket.unmarshal(raw)
        XCTAssertEqual(packet.context, RnsConstants.ctxPathResponse)
        let parsed = try XCTUnwrap(RnsPathDiscovery.parseResponse(packet.data))
        XCTAssertEqual(parsed.target, target)
        XCTAssertEqual(parsed.nextHop, nextHop)
        XCTAssertEqual(parsed.hops, 3)
        XCTAssertNil(RnsPathDiscovery.parseResponse([UInt8](repeating: 0, count: 10)))
    }
}

final class RnsForwardingTableTests: XCTestCase {
    private let destA = dest(0x0A)
    private let destB = dest(0x0B)
    private let destC = dest(0x0C)
    private let nextHop1 = dest(0x01)

    func testLearnAndLookup() {
        let table = RnsForwardingTable()
        XCTAssertTrue(table.learn(destHash: destA, nextHop: nil, egressInterface: "mesh_0", hops: 2))
        XCTAssertFalse(table.learn(destHash: destA, nextHop: nil, egressInterface: "iridium_0", hops: 3))
        XCTAssertNil(table.lookup(destB))
        let t2 = RnsForwardingTable()
        t2.learn(destHash: destA, nextHop: nextHop1, egressInterface: "mesh_0", hops: 2)
        let entry = t2.lookup(destA)
        XCTAssertEqual(entry?.egressInterface, "mesh_0")
        XCTAssertEqual(entry?.hops, 2)
        XCTAssertEqual(entry?.nextHop, nextHop1)
    }

    func testPreferences() {
        let table = RnsForwardingTable()
        table.learn(destHash: destA, nextHop: nil, egressInterface: "iridium_0", hops: 1, costCents: 5)
        table.learn(destHash: destA, nextHop: nil, egressInterface: "mesh_0", hops: 2, costCents: 0)
        XCTAssertEqual(table.lookup(destA)?.egressInterface, "mesh_0")
        let t2 = RnsForwardingTable()
        t2.learn(destHash: destA, nextHop: nil, egressInterface: "mesh_0", hops: 5)
        t2.learn(destHash: destA, nextHop: nil, egressInterface: "aprs_0", hops: 2)
        XCTAssertEqual(t2.lookup(destA)?.egressInterface, "aprs_0")
        let t3 = RnsForwardingTable()
        t3.learn(destHash: destA, nextHop: nil, egressInterface: "mesh_0", hops: 5)
        t3.learn(destHash: destA, nextHop: nil, egressInterface: "mesh_0", hops: 2)
        XCTAssertEqual(t3.lookup(destA)?.hops, 2)
        t3.learn(destHash: destA, nextHop: nil, egressInterface: "mesh_0", hops: 5)
        XCTAssertEqual(t3.lookup(destA)?.hops, 2)
    }

    func testAllEntriesHasEntryRemove() {
        let table = RnsForwardingTable()
        table.learn(destHash: destA, nextHop: nil, egressInterface: "mesh_0", hops: 2, costCents: 0)
        table.learn(destHash: destA, nextHop: nil, egressInterface: "iridium_0", hops: 1, costCents: 5)
        table.learn(destHash: destA, nextHop: nil, egressInterface: "sms_0", hops: 3, costCents: 1)
        let entries = table.allEntries(destA)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].egressInterface, "mesh_0")
        XCTAssertTrue(table.allEntries(destB).isEmpty)
        XCTAssertTrue(table.hasEntry(destA))
        XCTAssertFalse(table.hasEntry(destB))
        table.remove(destA)
        XCTAssertFalse(table.hasEntry(destA))
        table.learn(destHash: destA, nextHop: nil, egressInterface: "mesh_0", hops: 1)
        table.learn(destHash: destB, nextHop: nil, egressInterface: "mesh_0", hops: 2)
        table.learn(destHash: destC, nextHop: nil, egressInterface: "iridium_0", hops: 1)
        table.removeInterface("mesh_0")
        XCTAssertFalse(table.hasEntry(destA))
        XCTAssertFalse(table.hasEntry(destB))
        XCTAssertTrue(table.hasEntry(destC))
    }

    func testPruneSizeAndSnapshot() {
        let clock = Slept()
        clock.add(1_000)
        let short = RnsForwardingTable(ttlMs: 1, now: { clock.values.reduce(0, +) })
        short.learn(destHash: destA, nextHop: nil, egressInterface: "mesh_0", hops: 1)
        clock.add(10)
        XCTAssertGreaterThan(short.prune(), 0)
        XCTAssertFalse(short.hasEntry(destA))
        let table = RnsForwardingTable()
        table.learn(destHash: destA, nextHop: nil, egressInterface: "mesh_0", hops: 1)
        XCTAssertEqual(table.prune(), 0)
        XCTAssertTrue(table.hasEntry(destA))
        table.learn(destHash: destA, nextHop: nil, egressInterface: "iridium_0", hops: 2, costCents: 5)
        table.learn(destHash: destB, nextHop: nil, egressInterface: "mesh_0", hops: 1)
        XCTAssertEqual(table.size(), 2)
        XCTAssertEqual(table.totalEntries(), 3)
        let snap = table.snapshot()
        XCTAssertEqual(snap.count, 2)
        XCTAssertEqual(
            snap[RnsForwardingTable.Entry(destHash: destA, nextHop: nil, egressInterface: "", hops: 0, costCents: 0).destHashHex]?
                .egressInterface, "mesh_0")
    }

    func testScores() {
        let free = RnsForwardingTable.Entry(destHash: destA, nextHop: nil, egressInterface: "mesh_0", hops: 5, costCents: 0)
        let paid = RnsForwardingTable.Entry(destHash: destA, nextHop: nil, egressInterface: "iridium_0", hops: 1, costCents: 5)
        XCTAssertLessThan(free.score, paid.score)
        let near = RnsForwardingTable.Entry(destHash: destA, nextHop: nil, egressInterface: "mesh_0", hops: 1, costCents: 0)
        XCTAssertLessThan(near.score, free.score)
        XCTAssertEqual(RnsTransportNode.maxHops, 128)
        XCTAssertEqual(RnsTransportNode.maxHops, RnsConstants.maxHops)
        XCTAssertTrue(RnsTransportNode.isPaidInterface("iridium_rns_0"))
        XCTAssertTrue(RnsTransportNode.isPaidInterface("sms_0"))
        XCTAssertFalse(RnsTransportNode.isPaidInterface("mesh_rns_0"))
    }
}

final class RnsResourceTests: XCTestCase {
    private let link = dest(0)

    func testForSendingChunks() {
        let (r, chunks) = RnsResource.forSending((0..<1000).map { UInt8($0 & 0xFF) }, chunkSize: 200, linkId: link)
        XCTAssertEqual(r.chunkCount, 5)
        XCTAssertEqual(chunks.count, 5)
        XCTAssertEqual(r.totalSize, 1000)
        XCTAssertEqual(r.chunkSize, 200)
        XCTAssertTrue(r.isOutbound)
        XCTAssertEqual(r.state, .advertising)
        let (r2, c2) = RnsResource.forSending((0..<350).map { UInt8($0 & 0xFF) }, chunkSize: 200, linkId: link)
        XCTAssertEqual(r2.chunkCount, 2)
        XCTAssertEqual(c2[0].count, 200)
        XCTAssertEqual(c2[1].count, 150)
        let (r3, c3) = RnsResource.forSending(Array("hello".utf8), chunkSize: 200, linkId: link)
        XCTAssertEqual(r3.chunkCount, 1)
        XCTAssertEqual(c3[0], Array("hello".utf8))
        XCTAssertEqual(r3.id.count, 16)
        XCTAssertEqual(r3.payloadHash.count, 32)
    }

    func testProgressAndCompletion() {
        let (r, _) = RnsResource.forSending([UInt8](repeating: 0, count: 400), chunkSize: 100, linkId: link)
        XCTAssertEqual(r.progress, 0, accuracy: 0.01)
        r.ackChunk(0)
        r.ackChunk(1)
        XCTAssertEqual(r.progress, 0.5, accuracy: 0.01)
        XCTAssertFalse(r.isComplete)
        r.ackChunk(2)
        r.ackChunk(3)
        XCTAssertTrue(r.isComplete)
        let (r2, _) = RnsResource.forSending([UInt8](repeating: 0, count: 400), chunkSize: 100, linkId: link)
        r2.ackChunk(0)
        r2.ackChunk(2)
        XCTAssertEqual(r2.pendingChunks(), [1, 3])
        let inbound = RnsResource.forReceiving(
            id: dest(), totalSize: 400, chunkSize: 100, chunkCount: 4, payloadHash: [UInt8](repeating: 0, count: 32), linkId: link)
        inbound.addChunk(index: 0, data: [UInt8](repeating: 0, count: 100))
        inbound.addChunk(index: 1, data: [UInt8](repeating: 0, count: 100))
        XCTAssertEqual(inbound.progress, 0.5, accuracy: 0.01)
        inbound.addChunk(index: 2, data: [UInt8](repeating: 0, count: 100))
        XCTAssertNil(inbound.reassemble())
    }

    func testReassembleAndHash() {
        let payload = (0..<350).map { UInt8($0 % 256) }
        let (r, chunks) = RnsResource.forSending(payload, chunkSize: 200, linkId: link)
        let inbound = RnsResource.forReceiving(
            id: r.id, totalSize: 350, chunkSize: 200, chunkCount: 2, payloadHash: r.payloadHash, linkId: link)
        for (i, c) in chunks.enumerated() { inbound.addChunk(index: i, data: c) }
        XCTAssertEqual(inbound.reassemble(), payload)
        XCTAssertTrue(r.verifyHash(payload))
        XCTAssertFalse(r.verifyHash(Array("wrong data".utf8)))
    }

    func testWireFormats() throws {
        XCTAssertEqual(RnsResourceAdv.size, 56)
        let (r, _) = RnsResource.forSending([UInt8](repeating: 0, count: 1000), chunkSize: 200, linkId: link)
        let adv = RnsResourceAdv.marshal(r)
        XCTAssertEqual(adv.count, 56)
        let parsed = try XCTUnwrap(RnsResourceAdv.unmarshal(adv))
        XCTAssertEqual(parsed.resourceId, r.id)
        XCTAssertEqual(parsed.payloadHash, r.payloadHash)
        XCTAssertEqual(parsed.totalSize, 1000)
        XCTAssertEqual(parsed.chunkSize, 200)
        XCTAssertEqual(parsed.chunkCount, 5)
        XCTAssertNil(RnsResourceAdv.unmarshal([UInt8](repeating: 0, count: 10)))

        XCTAssertEqual(RnsResourceChunk.headerSize, 18)
        let chunk = try XCTUnwrap(
            RnsResourceChunk.unmarshal(
                RnsResourceChunk.marshal(resourceId: dest(0xAA), chunkIndex: 7, chunkData: Array("chunk data here".utf8))))
        XCTAssertEqual(chunk.resourceId, dest(0xAA))
        XCTAssertEqual(chunk.chunkIndex, 7)
        XCTAssertEqual(chunk.chunkData, Array("chunk data here".utf8))

        XCTAssertEqual(RnsResourceProof.size, 18)
        let proof = try XCTUnwrap(RnsResourceProof.unmarshal(RnsResourceProof.marshal(resourceId: dest(0xBB), chunkIndex: 42)))
        XCTAssertEqual(proof.resourceId, dest(0xBB))
        XCTAssertEqual(proof.chunkIndex, 42)

        XCTAssertEqual(RnsResourceComplete.size, 17)
        XCTAssertEqual(RnsResourceComplete.unmarshal(RnsResourceComplete.marshal(resourceId: dest(0xCC), success: true))?.success, true)
        XCTAssertEqual(RnsResourceComplete.unmarshal(RnsResourceComplete.marshal(resourceId: dest(0xDD), success: false))?.success, false)
    }

    func testFullTransferSimulation() throws {
        let payload = (0..<500).map { UInt8($0 % 256) }
        let (sender, chunks) = RnsResource.forSending(payload, chunkSize: 200, linkId: dest(1))
        XCTAssertEqual(chunks.count, 3)
        let adv = try XCTUnwrap(RnsResourceAdv.unmarshal(RnsResourceAdv.marshal(sender)))
        let receiver = RnsResource.forReceiving(
            id: adv.resourceId, totalSize: adv.totalSize, chunkSize: adv.chunkSize, chunkCount: adv.chunkCount,
            payloadHash: adv.payloadHash,
            linkId: dest(1))
        for (i, c) in chunks.enumerated() {
            let parsedChunk = try XCTUnwrap(
                RnsResourceChunk.unmarshal(RnsResourceChunk.marshal(resourceId: sender.id, chunkIndex: i, chunkData: c)))
            receiver.addChunk(index: parsedChunk.chunkIndex, data: parsedChunk.chunkData)
            let ack = try XCTUnwrap(RnsResourceProof.unmarshal(RnsResourceProof.marshal(resourceId: sender.id, chunkIndex: i)))
            sender.ackChunk(ack.chunkIndex)
        }
        XCTAssertTrue(sender.isComplete)
        XCTAssertTrue(receiver.isComplete)
        XCTAssertEqual(sender.progress, 1, accuracy: 0.01)
        let reassembled = try XCTUnwrap(receiver.reassemble())
        XCTAssertEqual(reassembled, payload)
        XCTAssertTrue(receiver.verifyHash(reassembled))
        XCTAssertEqual(RnsResourceComplete.unmarshal(RnsResourceComplete.marshal(resourceId: sender.id, success: true))?.success, true)
    }
}
