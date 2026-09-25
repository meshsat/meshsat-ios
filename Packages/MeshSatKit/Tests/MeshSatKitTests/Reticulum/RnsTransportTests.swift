// The announce handler and the transport node with stub interfaces, and the interfaces that
// need no hardware: Meshtastic fragmentation, TCP over a loopback stream, MQTT over a fake link.
import MeshSatHemb
import MeshSatNet
import XCTest

@testable import MeshSatCrypto
@testable import MeshSatReticulum

// Up to 10 s: on the shared CI runner, four test processes side by side, a link proof once took
// longer than the 3 s this allowed (pipeline 56379, 25 Sep 2026). A passing test returns at once.
private func waitUntil(_ test: @escaping () -> Bool) async {
    for _ in 0..<1000 {
        if test() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

final class RnsAnnounceHandlerTests: XCTestCase {
    func testOwnAnnounceVerifiesDedupsAndIsNeverRelayed() async {
        let id = Identity.generate()
        let relayed = Slept()
        let events = RelayReceived()
        let handler = RnsAnnounceHandler(
            identity: id, relayCallback: { packet, _ in relayed.add(Int64(packet.count)) },
            announceCallback: { events.add($0.sourceInterface, $0.destHash) },
            now: { 5_000 }, sleep: { _ in })
        let raw = handler.createAnnounce(capabilities: MeshSatAppData.capMesh)
        XCTAssertTrue(handler.handleAnnounce(raw, sourceInterface: "mesh_0"))
        XCTAssertFalse(handler.handleAnnounce(raw, sourceInterface: "tcp_0"), "the same announce a second time is a duplicate")
        XCTAssertEqual(handler.seenCount(), 1)
        XCTAssertEqual(events.items.count, 1)
        XCTAssertEqual(events.items.first?.1, handler.localDestHash)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(relayed.values.isEmpty, "our own announce is never relayed")
        XCTAssertTrue(handler.isLocal(handler.localDestHash))
    }

    func testAForeignAnnounceIsRelayedWithOneMoreHop() async throws {
        let other = Identity.generate()
        let otherHandler = RnsAnnounceHandler(identity: other, now: { 5_000 })
        let raw = otherHandler.createAnnounce()
        let me = Identity.generate()
        let relayedPackets = RelayReceived()
        let handler = RnsAnnounceHandler(
            identity: me, relayCallback: { packet, _ in relayedPackets.add("relay", packet) }, now: { 5_000 }, sleep: { _ in })
        XCTAssertTrue(handler.handleAnnounce(raw, sourceInterface: "mesh_0"))
        await waitUntil { !relayedPackets.items.isEmpty }
        let relayed = try RnsPacket.unmarshal(try XCTUnwrap(relayedPackets.items.first?.1))
        XCTAssertEqual(relayed.hops, 1)
        XCTAssertEqual(relayed.destHash, otherHandler.localDestHash)
        // Tampered or non-announce packets are refused.
        var bad = raw
        bad[30] ^= 0xFF
        XCTAssertFalse(handler.handleAnnounce(bad, sourceInterface: "mesh_0"))
        XCTAssertFalse(handler.handleAnnounce(RnsPacket.data(destHash: me.destHash, payload: [1]).marshal(), sourceInterface: "mesh_0"))
    }

    func testPruneDropsOldEntriesAndCapsTheCache() {
        let clock = Slept()
        clock.add(1_000)
        let handler = RnsAnnounceHandler(
            identity: Identity.generate(), dedupTtlMs: 100, maxDedupEntries: 2, now: { clock.values.reduce(0, +) })
        for _ in 0..<3 {
            let other = RnsAnnounceHandler(identity: Identity.generate(), now: { 5_000 })
            XCTAssertTrue(handler.handleAnnounce(other.createAnnounce(), sourceInterface: "x"))
        }
        XCTAssertEqual(handler.seenCount(), 3)
        handler.prune()
        XCTAssertEqual(handler.seenCount(), 2, "capped at maxDedupEntries")
        clock.add(200)
        handler.prune()
        XCTAssertEqual(handler.seenCount(), 0, "expired by TTL")
    }
}

final class RnsTransportNodeTests: XCTestCase {
    private var mesh = StubInterface("mesh_rns_0", cost: 0, latency: 200)
    private var iridium = StubInterface("iridium_rns_0", cost: 5, latency: 60000)
    private var tcp = StubInterface("tcp_rns_0", cost: 0, latency: 50)
    private var me = Identity.generate()
    private var handler: RnsAnnounceHandler!
    private var links: RnsLinkManager!
    private var paths: RnsPathTable!
    private var forwarding: RnsForwardingTable!
    private var node: RnsTransportNode!

    override func setUp() {
        mesh = StubInterface("mesh_rns_0", cost: 0, latency: 200)
        iridium = StubInterface("iridium_rns_0", cost: 5, latency: 60000)
        tcp = StubInterface("tcp_rns_0", cost: 0, latency: 50)
        // The HeMB compact header has no magic: any 8+ byte packet whose byte 7 happens to equal
        // the CRC-8 of bytes 0 to 6 reads as a HeMB frame (1 in 256; Android has the same
        // check). Byte 7 of a data packet is byte 5 of our destination hash, so pick an
        // identity whose hash does not collide, or the local-delivery test flakes (seen in CI).
        repeat {
            me = Identity.generate()
        } while HembFrame.isHembFrame(
            RnsPacket.data(
                destHash: RnsDestination.computeDestHash(encryptionPub: me.encryptionPubRaw, signingPub: me.signingPubRaw),
                payload: Array("hi".utf8)
            ).marshal())
        handler = RnsAnnounceHandler(identity: me, now: { 5_000 }, sleep: { _ in })
        links = RnsLinkManager(identity: me, localDestHash: handler.localDestHash)
        let all: [any RnsInterface] = [mesh, iridium, tcp]
        paths = RnsPathTable(interfaces: { all })
        forwarding = RnsForwardingTable()
        let map = Dictionary(uniqueKeysWithValues: all.map { ($0.interfaceId, $0) })
        node = RnsTransportNode(
            localDestHash: handler.localDestHash, announceHandler: handler, linkManager: links, pathTable: paths,
            forwardingTable: forwarding,
            interfaces: { map },
            // The announce and prune loops wait for ever; the zero relay delay returns at once.
            sleep: { ms in if ms > 0 { try await Task.sleep(nanoseconds: 3_600_000_000_000) } }, relayDelayMs: { 0 })
        node.start()
    }

    override func tearDown() { node.stop() }

    private func foreign() -> (RnsAnnounceHandler, Identity) {
        let id = Identity.generate()
        return (RnsAnnounceHandler(identity: id, now: { 5_000 }), id)
    }

    func testAnAnnounceIsLearnedAndRelayedOnFreeInterfacesOnly() async {
        let (other, _) = foreign()
        mesh.inject(other.createAnnounce())
        await waitUntil { self.tcp.sentCount == 1 }
        XCTAssertEqual(tcp.sentCount, 1, "relayed on the other free interface")
        XCTAssertEqual(iridium.sentCount, 0, "never on a paid one")
        XCTAssertEqual(mesh.sentCount, 0, "not back where it came from")
        XCTAssertEqual(forwarding.lookup(other.localDestHash)?.egressInterface, "mesh_rns_0")
        XCTAssertEqual(try? RnsPacket.unmarshal(tcp.sent.first ?? []).hops, 1)
    }

    func testDataForUsIsDeliveredLocallyAndOnceOnly() async {
        let got = RelayReceived()
        node.localDeliveryCallback = { packet, iface in got.add(iface, packet.data) }
        let raw = RnsPacket.data(destHash: handler.localDestHash, payload: Array("hi".utf8)).marshal()
        mesh.inject(raw)
        tcp.inject(raw)  // the same packet on a second interface is a duplicate
        await waitUntil { !got.items.isEmpty }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(got.items.count, 1)
        XCTAssertEqual(got.items.first?.0, "mesh_rns_0")
        XCTAssertEqual(got.items.first?.1, Array("hi".utf8))
        XCTAssertEqual(node.seenCount(), 1)
    }

    func testDataForSomeoneElseIsForwardedOnTheLearnedInterfaceWrappedForTransport() async throws {
        let (other, _) = foreign()
        tcp.inject(other.createAnnounce())  // other is reachable via tcp
        await waitUntil { self.forwarding.hasEntry(other.localDestHash) }
        mesh.inject(RnsPacket.data(destHash: other.localDestHash, payload: [1, 2, 3]).marshal())
        await waitUntil { self.tcp.sentCount >= 2 }
        let forwarded = try RnsPacket.unmarshal(try XCTUnwrap(tcp.sent.last))
        XCTAssertEqual(forwarded.headerType, RnsConstants.header2)
        XCTAssertEqual(forwarded.transportId, handler.localDestHash)
        XCTAssertEqual(forwarded.hops, 1)
        XCTAssertEqual(forwarded.data, [1, 2, 3])
    }

    func testUnknownDestinationIsFloodedExceptProtocolOverheadOnPaidInterfaces() async {
        let unknown = [UInt8](repeating: 0x77, count: 16)
        mesh.inject(RnsPacket.data(destHash: unknown, payload: [9]).marshal())
        await waitUntil { self.tcp.sentCount == 1 && self.iridium.sentCount == 1 }
        XCTAssertEqual(tcp.sentCount, 1)
        XCTAssertEqual(iridium.sentCount, 1, "user data may go to a paid interface")
        XCTAssertEqual(mesh.sentCount, 0)
        mesh.inject(RnsPacket.data(destHash: unknown, payload: [1], context: RnsConstants.ctxKeepalive).marshal())
        await waitUntil { self.tcp.sentCount == 2 }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(iridium.sentCount, 1, "a keepalive never goes to Iridium")
    }

    func testAPathRequestIsAnsweredWhenThePathIsKnown() async throws {
        let (other, _) = foreign()
        tcp.inject(other.createAnnounce())
        await waitUntil { self.forwarding.hasEntry(other.localDestHash) }
        // The announce from tcp was relayed onto mesh; the path response is what follows it.
        await waitUntil { self.mesh.sentCount == 1 }
        let requester = [UInt8](repeating: 0x55, count: 16)
        mesh.inject(
            RnsPacket.data(
                destHash: requester, payload: other.localDestHash, destType: RnsConstants.destPlain, context: RnsConstants.ctxPathResponse
            ).marshal())
        await waitUntil { self.mesh.sentCount == 2 }
        let response = try RnsPacket.unmarshal(try XCTUnwrap(mesh.sent.last))
        XCTAssertEqual(response.destHash, requester)
        XCTAssertEqual(response.context, RnsConstants.ctxPathResponse)
        let parsed = try XCTUnwrap(RnsPathDiscovery.parseResponse(response.data))
        XCTAssertEqual(parsed.target, other.localDestHash)
        XCTAssertEqual(parsed.nextHop, handler.localDestHash)
        XCTAssertEqual(parsed.hops, 0)
    }

    func testALinkRequestForUsGetsAProofOnTheSameInterface() async throws {
        let (_, other) = foreign()
        let otherLinks = RnsLinkManager(identity: other, localDestHash: other.destHash)
        let request = otherLinks.initiateLink(destHash: handler.localDestHash)
        tcp.inject(request)
        await waitUntil { self.tcp.sentCount == 1 }
        let proof = try XCTUnwrap(tcp.sent.first)
        XCTAssertEqual(try RnsPacket.unmarshal(proof).packetType, RnsConstants.packetProof)
        XCTAssertNotNil(otherLinks.handleLinkProof(proof, signingPubRaw: me.signingPubRaw))
        XCTAssertEqual(links.activeLinks().count, 1)
    }

    func testHembFramesGoToTheHembCallback() async {
        let frames = RelayReceived()
        node.hembCallback = { iface, frame in frames.add(iface, frame) }
        var frame = [UInt8](repeating: 0, count: 20)
        frame[0] = 0x48
        frame[1] = 0x4D
        frame[15] = MeshSatHembCrc.crc8(frame, length: 15)
        mesh.inject(frame)
        await waitUntil { !frames.items.isEmpty }
        XCTAssertEqual(frames.items.first?.1, frame)
        XCTAssertEqual(tcp.sentCount, 0)
    }

    func testSendDataUsesTheBestPathAndBroadcastAnnounceSkipsPaid() async throws {
        let (other, _) = foreign()
        tcp.inject(other.createAnnounce())
        await waitUntil { self.forwarding.hasEntry(other.localDestHash) }
        let before = tcp.sentCount
        let err = await node.sendData(destHash: other.localDestHash, data: Array("x".utf8))
        XCTAssertNil(err)
        XCTAssertEqual(tcp.sentCount, before + 1)
        let tooBig = await node.sendData(destHash: other.localDestHash, data: [UInt8](repeating: 0, count: 500))
        XCTAssertEqual(tooBig, "packet exceeds MTU")
        await waitUntil { self.mesh.sentCount == 1 }  // the relayed foreign announce
        await node.broadcastAnnounce()
        XCTAssertEqual(mesh.sentCount, 2)
        XCTAssertEqual(iridium.sentCount, 0)
        let announce = try RnsPacket.unmarshal(try XCTUnwrap(mesh.sent.last))
        XCTAssertEqual(announce.packetType, RnsConstants.packetAnnounce)
        XCTAssertEqual(announce.destHash, handler.localDestHash)
        XCTAssertEqual(node.destHashHex.count, 32)
        XCTAssertEqual(node.interfaceCount(), 3)
        XCTAssertEqual(node.onlineInterfaceCount(), 3)
    }
}

/// HembFrame.crc8 through the module the node uses, kept here so the test file needs no HeMB import.
enum MeshSatHembCrc {
    static func crc8(_ data: [UInt8], length: Int) -> UInt8 {
        var crc: UInt8 = 0
        for i in 0..<length {
            crc ^= data[i]
            for _ in 0..<8 { crc = (crc & 0x80) != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
        }
        return crc
    }
}

final class FakeRadio: MeshRadioLink, @unchecked Sendable {
    var isConnected = true
    let receivedData = Broadcast<[UInt8]>(bufferSize: 64)
    private let lock = NSLock()
    private(set) var toRadio: [[UInt8]] = []
    func sendToRadio(_ data: [UInt8]) {
        lock.lock()
        toRadio.append(data)
        lock.unlock()
    }
    var sentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return toRadio.count
    }
}

final class RnsMeshtasticBleInterfaceTests: XCTestCase {
    func testConstantsAndSingleFragmentEncoding() throws {
        XCTAssertEqual(RnsMeshtasticBleInterface.portnumPrivateApp, 256)
        XCTAssertEqual(RnsMeshtasticBleInterface.fragPayloadMax, 227)
        let packet = (0..<40).map { UInt8($0) }
        let frags = try RnsMeshtasticBleInterface.fragment(packet)
        XCTAssertEqual(frags, [[0x00] + packet])
        let toRadio = RnsMeshtasticBleInterface.encodePrivateAppToRadio(frags[0])
        XCTAssertGreaterThan(toRadio.count, packet.count)
        // A FromRadio carrying the same MeshPacket decodes back to the payload.
        let fromRadio = RnsInterfaceTestSupport.fromRadio(carrying: toRadio)
        XCTAssertEqual(RnsMeshtasticBleInterface.parsePrivateAppPayload(fromRadio), frags[0])
        // A text message is not a PRIVATE_APP payload.
        XCTAssertNil(RnsMeshtasticBleInterface.parsePrivateAppPayload(RnsInterfaceTestSupport.textFromRadio("text")))
    }

    func testAFivehundredBytePacketIsThreeFragmentsAndReassembles() async throws {
        let packet = (0..<500).map { UInt8($0 % 251) }
        let frags = try RnsMeshtasticBleInterface.fragment(packet)
        XCTAssertEqual(frags.count, 3)
        XCTAssertEqual(frags[0].count, 230)
        XCTAssertEqual(frags[0][0] & 0xC0, 0x40)
        XCTAssertEqual(frags[0][0] & 0x01, 1, "more follows")
        XCTAssertEqual(frags[2][0] & 0x01, 0, "the last one")
        XCTAssertEqual(Array(frags[0][1..<3]), Array(frags[2][1..<3]), "one reassembly id")
        let radio = FakeRadio()
        let iface = RnsMeshtasticBleInterface(radio: radio)
        let got = RelayReceived()
        iface.setReceiveCallback { id, pkt in got.add(id, pkt) }
        await iface.start()
        // Out of order and with a duplicate: still one packet.
        for f in [frags[2], frags[0], frags[0], frags[1]] {
            radio.receivedData.send(RnsInterfaceTestSupport.fromRadio(carrying: RnsMeshtasticBleInterface.encodePrivateAppToRadio(f)))
        }
        await waitUntil { !got.items.isEmpty }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(got.items.count, 1)
        XCTAssertEqual(got.items.first?.0, "mesh_rns_0")
        XCTAssertEqual(got.items.first?.1, packet)
        // Sending writes one ToRadio per fragment.
        let err = await iface.send(packet)
        XCTAssertNil(err)
        XCTAssertEqual(radio.sentCount, 3)
        radio.isConnected = false
        let offline = await iface.send(packet)
        XCTAssertEqual(offline, "BLE not connected")
        XCTAssertThrowsError(try RnsMeshtasticBleInterface.fragment([UInt8](repeating: 0, count: 33 * 227)))
        await iface.stop()
    }
}

/// Builds Meshtastic FromRadio protobufs for the tests without a protobuf import here.
enum RnsInterfaceTestSupport {
    static func varint(_ v: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        var v = v
        repeat {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }
    static func bytesField(_ n: Int, _ data: [UInt8]) -> [UInt8] { varint(UInt64(n << 3 | 2)) + varint(UInt64(data.count)) + data }
    static func varintField(_ n: Int, _ v: UInt64) -> [UInt8] { varint(UInt64(n << 3)) + varint(v) }

    /// ToRadio field 1 is the MeshPacket; FromRadio carries it in field 2.
    static func fromRadio(carrying toRadio: [UInt8]) -> [UInt8] {
        // ToRadio: tag 0x0A, length varint, MeshPacket
        var i = 1
        var len: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let b = toRadio[i]
            len |= UInt64(b & 0x7F) << shift
            i += 1
            if b & 0x80 == 0 { break }
            shift += 7
        }
        return bytesField(2, Array(toRadio[i..<i + Int(len)]))
    }

    static func textFromRadio(_ text: String) -> [UInt8] {
        let data = varintField(1, 1) + bytesField(2, Array(text.utf8))
        let packet = varintField(2, 0xFFFF_FFFF) + varintField(3, 0) + bytesField(4, data)
        return bytesField(2, packet)
    }
}

final class LoopbackDialer: ByteStreamDialer, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var peers: [LoopbackByteStream] = []
    struct Dial {
        let host: String
        let port: Int
        let tls: TlsClientOptions?
    }
    private(set) var dials: [Dial] = []
    var refuse = false

    func dial(host: String, port: Int, tls: TlsClientOptions?, timeoutSeconds: Double) async throws -> any ByteStream {
        try next(host, port, tls)
    }

    private func next(_ host: String, _ port: Int, _ tls: TlsClientOptions?) throws -> any ByteStream {
        lock.lock()
        defer { lock.unlock() }
        dials.append(Dial(host: host, port: port, tls: tls))
        if refuse { throw ByteStreamError.refused("connection refused") }
        let (a, b) = LoopbackByteStream.pair()
        peers.append(b)
        return a
    }

    var peer: LoopbackByteStream? {
        lock.lock()
        defer { lock.unlock() }
        return peers.last
    }
}

final class RnsTcpInterfaceTests: XCTestCase {
    func testFramesBothWaysAndReconnect() async throws {
        let dialer = LoopbackDialer()
        let slept = Slept()
        let iface = RnsTcpInterface(dialer: dialer, sleep: { slept.add($0) })
        XCTAssertEqual(iface.name, "TCP")
        XCTAssertEqual(iface.costCents, 0)
        let got = RelayReceived()
        iface.setReceiveCallback { id, pkt in got.add(id, pkt) }
        let offline = await iface.send([1])
        XCTAssertEqual(offline, "tcp interface offline")
        iface.connect(host: "rns.example", port: 4242, tls: TlsClientOptions(clientCertPem: "c", clientKeyPem: "k"))
        await waitUntil { iface.isOnline }
        XCTAssertEqual(dialer.dials.first?.host, "rns.example")
        XCTAssertEqual(dialer.dials.first?.tls?.hasClientIdentity, true)
        XCTAssertTrue(iface.useTls)
        let packet = (0..<40).map { UInt8($0 == 3 ? 0x7E : $0) }
        let err = await iface.send(packet)
        XCTAssertNil(err)
        let peer = try XCTUnwrap(dialer.peer)
        var it = peer.incoming.makeAsyncIterator()
        let wire = await it.next()
        XCTAssertEqual(wire, RnsHdlc.frame(packet))
        // Two packets in one read, one of them split across reads.
        let second = (0..<30).map { UInt8($0) }
        let framed = RnsHdlc.frame(packet) + RnsHdlc.frame(second)
        try await peer.send(Array(framed[0..<20]))
        try await peer.send(Array(framed[20...]))
        await waitUntil { got.items.count == 2 }
        XCTAssertEqual(got.items.map { $0.1 }, [packet, second])
        // The far side closes: offline, then a reconnect after the wait.
        await peer.close()
        await waitUntil { dialer.dials.count == 2 }
        XCTAssertEqual(slept.values, [RnsTcpInterface.reconnectWaitMs])
        await waitUntil { iface.isOnline }
        XCTAssertTrue(iface.isOnline)
        iface.disconnect()
        XCTAssertFalse(iface.isOnline)
        XCTAssertEqual(iface.state.value, .disconnected)
    }

    func testARefusedConnectionKeepsRetrying() async {
        let dialer = LoopbackDialer()
        dialer.refuse = true
        let slept = Slept()
        let iface = RnsTcpInterface(
            dialer: dialer,
            sleep: { ms in
                slept.add(ms)
                if slept.values.count >= 3 { throw CancellationError() }
            })
        iface.connect(host: "down.example")
        await waitUntil { slept.values.count == 3 }
        XCTAssertEqual(dialer.dials.count, 3)
        XCTAssertFalse(iface.error.value.isEmpty)
        iface.disconnect()
    }
}

final class FakeMqttLink: RnsMqttLink, @unchecked Sendable {
    var isConnected = true
    private let lock = NSLock()
    struct Published {
        let topic: String
        let payload: String
        let qos: Int
    }
    private(set) var published: [Published] = []
    func publishRaw(topic: String, qos: Int, retained: Bool, payload: String) async throws { record(topic, payload, qos) }
    private func record(_ t: String, _ p: String, _ q: Int) {
        lock.lock()
        published.append(Published(topic: t, payload: p, qos: q))
        lock.unlock()
    }
}

final class RnsMqttInterfaceTests: XCTestCase {
    func testTopicsAndBase64BothWays() async throws {
        XCTAssertEqual(RnsMqttInterface.topicTxSuffix, "/reticulum/tx")
        XCTAssertEqual(RnsMqttInterface.topicRxSuffix, "/reticulum/rx")
        let link = FakeMqttLink()
        let iface = RnsMqttInterface(mqtt: link, deviceId: { "phone-1" })
        XCTAssertEqual(iface.mtu, 500)
        let packet = (0..<20).map { UInt8($0) }
        let err = await iface.send(packet)
        XCTAssertNil(err)
        XCTAssertEqual(link.published.first?.topic, "meshsat/phone-1/reticulum/tx")
        XCTAssertEqual(link.published.first?.qos, 1)
        XCTAssertEqual(link.published.first?.payload, Data(packet).base64EncodedString())
        let got = RelayReceived()
        iface.setReceiveCallback { id, pkt in got.add(id, pkt) }
        XCTAssertTrue(iface.processIncomingMessage(topic: "meshsat/phone-1/reticulum/rx", payload: Data(packet).base64EncodedString()))
        XCTAssertEqual(got.items.first?.0, "mqtt_rns_0")
        XCTAssertEqual(got.items.first?.1, packet)
        XCTAssertFalse(iface.processIncomingMessage(topic: "meshsat/phone-1/mt", payload: "x"))
        XCTAssertFalse(iface.processIncomingMessage(topic: "a/reticulum/rx", payload: "not base64!"))
        link.isConnected = false
        let offline = await iface.send(packet)
        XCTAssertEqual(offline, "MQTT interface offline")
    }

    func testIridiumConstants() {
        XCTAssertEqual(RnsIridiumInterface.iridiumMoMtu, 340)
        XCTAssertEqual(RnsIridiumInterface.iridiumMtMtu, 270)
        XCTAssertEqual(RnsIridiumInterface.sbdRnsMagic, 0x52)
    }
}
