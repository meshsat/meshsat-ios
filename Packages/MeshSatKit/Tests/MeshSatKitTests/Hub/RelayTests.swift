// Ports RelayTunnelTest.kt and RelayBridgeTransportTest.kt: the client end of the Hub relay
// against a fake Hub end (a loopback WebSocket in place of OkHttp's MockWebServer).
import Foundation
import MeshSatNet
import XCTest

@testable import MeshSatHub

/// A dialer scripted per connection: refuse with an HTTP status, or hand out one end of a
/// loopback socket and keep the other for the test as the Hub end.
final class FakeDialer: WebSocketDialer, @unchecked Sendable {
    enum Answer { case refuse(Int), accept }
    private let lock = NSLock()
    private var script: [Answer]
    private(set) var dials: [(url: String, headers: [String: String])] = []
    private(set) var hubEnds: [LoopbackWebSocket] = []
    init(_ script: [Answer]) { self.script = script }

    func dial(_ url: String, headers: [String: String], timeoutSeconds: Double) async throws -> any WebSocketTransport {
        try next(url, headers).get()
    }

    private func next(_ url: String, _ headers: [String: String]) -> Result<any WebSocketTransport, WebSocketDialError> {
        lock.lock()
        defer { lock.unlock() }
        dials.append((url, headers))
        let answer = script.count > 1 ? script.removeFirst() : (script.first ?? .refuse(503))
        switch answer {
        case .refuse(let code):
            return .failure(.refused(code))
        case .accept:
            let (client, hub) = LoopbackWebSocket.pair()
            hubEnds.append(hub)
            return .success(client)
        }
    }

    var hub: LoopbackWebSocket? {
        lock.lock()
        defer { lock.unlock() }
        return hubEnds.last
    }

    var dialCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dials.count
    }
}

private func settle<T: Sendable>(_ state: StateBroadcast<T>, _ test: @escaping (T) -> Bool) async -> T {
    for _ in 0..<300 {
        if test(state.value) { return state.value }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return state.value
}

private func nextBinary(_ hub: LoopbackWebSocket, _ it: inout AsyncStream<WebSocketFrame>.AsyncIterator) async -> [UInt8]? {
    while let f = await it.next() {
        if case .binary(let b) = f { return b }
    }
    return nil
}

final class RelayTunnelTests: XCTestCase {
    private var tunnels: [RelayTunnel] = []
    override func tearDown() { tunnels.forEach { $0.close() } }

    private func tunnel(
        _ dialer: FakeDialer, target: String = "kit-a", own: String = "phone-1", password: String = "s3cret",
        frames: @escaping @Sendable ([UInt8]) -> Void = { _ in }
    ) -> RelayTunnel {
        let t = RelayTunnel(
            hubBaseUrl: "http://hub.test", targetBridgeId: target, ownBridgeId: own, password: password, dialer: dialer,
            frameListener: frames)
        tunnels.append(t)
        return t
    }

    func testUpgradeCarriesHttpBasicOwnIdColonPasswordAndNamesTheTargetInThePath() async {
        let dialer = FakeDialer([.accept])
        let t = tunnel(dialer, target: "kit-a", own: "phone-1", password: "pw/with:chars")
        t.open()
        let s = await settle(t.state) { $0 == .open }
        XCTAssertEqual(s, .open)
        XCTAssertEqual(dialer.dials.first?.url, "http://hub.test/api/relay/connect/kit-a")
        let expected = "Basic " + Data("phone-1:pw/with:chars".utf8).base64EncodedString()
        XCTAssertEqual(dialer.dials.first?.headers["Authorization"], expected)
    }

    func testHubApiBaseIsDerivedFromTheMqttUrlUnlessAnExplicitOneIsGiven() {
        XCTAssertEqual(RelayTunnel.deriveHubApiBase("wss://mqtt-hub.meshsat.net/mqtt"), "https://hub.meshsat.net")
        XCTAssertEqual(RelayTunnel.deriveHubApiBase("ssl://hub.example.org:8883"), "https://hub.example.org")
        XCTAssertEqual(RelayTunnel.deriveHubApiBase("tcp://broker.lan:1883"), "http://broker.lan")
        XCTAssertEqual(
            RelayTunnel.deriveHubApiBase("wss://mqtt-hub.meshsat.net/mqtt", explicitApiUrl: "https://hub.mine/"), "https://hub.mine")
        XCTAssertEqual(RelayTunnel.deriveHubApiBase("", explicitApiUrl: "hub.mine"), "https://hub.mine")
        XCTAssertEqual(RelayTunnel.deriveHubApiBase("not a url", explicitApiUrl: ""), "")
        XCTAssertEqual(RelayTunnel.connectUrl("wss://hub.meshsat.net", "kit/a"), "https://hub.meshsat.net/api/relay/connect/kit%2Fa")
        XCTAssertEqual(RelayTunnel.formEncode("a b.c-d*e_f~"), "a+b.c-d*e_f%7E")
    }

    func testA40KiBSendFrameGoesOutAsTwoFramesOf32KiBAnd8KiB() async {
        let dialer = FakeDialer([.accept])
        let t = tunnel(dialer)
        t.open()
        _ = await settle(t.state) { $0 == .open }
        let hub = dialer.hub!
        let payload = (0..<40 * 1024).map { UInt8($0 % 251) }
        let sent = await t.sendFrame(payload)
        XCTAssertTrue(sent)
        var it = hub.incoming.makeAsyncIterator()
        let first = await nextBinary(hub, &it)
        let second = await nextBinary(hub, &it)
        XCTAssertEqual(first?.count, 32 * 1024)
        XCTAssertEqual(second?.count, 8 * 1024)
        XCTAssertEqual((first ?? []) + (second ?? []), payload)
    }

    func testFramesFromTheHubReachTheListener() async {
        let dialer = FakeDialer([.accept])
        let got = Slept()
        let t = tunnel(dialer) { got.add(Int64($0.count)) }
        t.open()
        _ = await settle(t.state) { $0 == .open }
        try? await dialer.hub!.send(.binary(Array("hello phone".utf8)))
        try? await dialer.hub!.send(.text("ignored"))
        for _ in 0..<100 where got.values.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(got.values, [11])
    }

    func testHubClose1008MapsToClosedBudget() async {
        let dialer = FakeDialer([.accept])
        let t = tunnel(dialer)
        t.open()
        _ = await settle(t.state) { $0 == .open }
        await dialer.hub!.close(code: 1008, reason: "relay budget exhausted for this minute")
        let end = await settle(t.state) { $0.isTerminal }
        XCTAssertEqual(end, .closed(reason: .budget, detail: "relay budget exhausted for this minute"))
        XCTAssertFalse(t.isOpen)
        let sent = await t.sendFrame([1])
        XCTAssertFalse(sent, "nothing can be sent on a closed tunnel")
    }

    func testHubCloseCodesMap() {
        XCTAssertEqual(RelayTunnel.reasonFor(1001), .superseded)
        XCTAssertEqual(RelayTunnel.reasonFor(1003), .badFrame)
        XCTAssertEqual(RelayTunnel.reasonFor(1000), .normal)
        XCTAssertEqual(RelayTunnel.reasonFor(1006), .error)
    }

    func testHttp403And429BeforeTheUpgradeAreRefused() async {
        let a = tunnel(FakeDialer([.refuse(403)]), target: "somebody-elses-kit")
        a.open()
        let endA = await settle(a.state) { $0.isTerminal }
        XCTAssertEqual(endA, .refused(httpCode: 403))
        XCTAssertFalse(a.isOpen)
        let b = tunnel(FakeDialer([.refuse(429)]))
        b.open()
        let endB = await settle(b.state) { $0.isTerminal }
        XCTAssertEqual(endB, .refused(httpCode: 429))
    }

    func testCloseFromThisEndSendsANormalCloseAndReportsLocal() async {
        let dialer = FakeDialer([.accept])
        let t = tunnel(dialer)
        t.open()
        _ = await settle(t.state) { $0 == .open }
        t.close()
        let end = await settle(t.state) { $0.isTerminal }
        XCTAssertEqual(end, .closed(reason: .local, detail: "closed by client"))
        let hub = dialer.hub!
        for _ in 0..<100 where hub.closedWith == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(hub.closedWith?.code, 1000)
        t.open()  // idempotent, no second dial
        XCTAssertEqual(dialer.dialCount, 1)
    }
}

final class RelayBridgeTransportTests: XCTestCase {
    private var transports: [RelayBridgeTransport] = []
    override func tearDown() { transports.forEach { $0.shutdown() } }

    private let config = RelayBridgeTransport.Config(
        hubApiBase: "http://hub.test", targetBridgeId: "kit-a", ownBridgeId: "phone-1", password: "pw")

    private func transport(_ dialer: FakeDialer, slept: Slept? = nil) -> RelayBridgeTransport {
        // The recorded wait blocks until the test tears the transport down, so the state the
        // test looks at is the one the tunnel ended with, not the next attempt's.
        let t = RelayBridgeTransport(
            config: config, dialer: dialer,
            sleep: { ms in
                slept?.add(ms)
                try await Task.sleep(nanoseconds: 60_000_000_000)
            })
        transports.append(t)
        return t
    }

    func testIdentityIsHubRelayFreeAndBidirectional() async {
        let t = transport(FakeDialer([.accept]))
        XCTAssertEqual(t.interfaceId, "hub_relay")
        XCTAssertEqual(t.costCents, 0)
        XCTAssertTrue(t.isBidirectional)
        XCTAssertFalse(t.isOnline, "not online before start")
        let r = await t.send([1, 2, 3])
        XCTAssertEqual(r, "hub relay offline")
    }

    func testSendWritesOneFramePerPacketAndReceivedFramesReachTheCallbackWithTheInterfaceId() async {
        let dialer = FakeDialer([.accept])
        let t = transport(dialer)
        let received = RelayReceived()
        t.setReceiveCallback { id, pkt in received.add(id, pkt) }
        await t.start()
        _ = await settle(t.state) { $0 == .open }
        XCTAssertTrue(t.isOnline)
        let packet = (0..<300).map { UInt8($0 & 0xFF) }
        let r = await t.send(packet)
        XCTAssertNil(r)
        let hub = dialer.hub!
        var it = hub.incoming.makeAsyncIterator()
        let up = await nextBinary(hub, &it)
        XCTAssertEqual(up, packet)
        let down = (0..<120).map { UInt8(($0 * 3) & 0xFF) }
        try? await hub.send(.binary(down))
        for _ in 0..<100 where received.items.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(received.items.first?.0, "hub_relay")
        XCTAssertEqual(received.items.first?.1, down)
        XCTAssertEqual(dialer.dials.first?.url, "http://hub.test/api/relay/connect/kit-a")
    }

    func testHubClose1008TakesTheInterfaceOfflineWithReasonBudgetAndWaitsOutTheMinute() async {
        let dialer = FakeDialer([.accept, .refuse(503)])
        let slept = Slept()
        let t = transport(dialer, slept: slept)
        await t.start()
        _ = await settle(t.state) { $0 == .open }
        await dialer.hub!.close(code: 1008, reason: "relay budget exhausted for this minute")
        let end = await settle(t.state) { if case .closed(.budget, _) = $0 { return true } else { return false } }
        XCTAssertEqual(end, .closed(reason: .budget, detail: "relay budget exhausted for this minute"))
        XCTAssertFalse(t.isOnline)
        let r = await t.send([1])
        XCTAssertEqual(r, "hub relay offline")
        for _ in 0..<100 where slept.values.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(slept.values.first, RelayBridgeTransport.retryBudgetMs)
    }

    func testHttp403BeforeTheUpgradeIsRefusedAndRetriedSlowly() async {
        let slept = Slept()
        let t = transport(FakeDialer([.refuse(403)]), slept: slept)
        await t.start()
        let end = await settle(t.state) { if case .refused = $0 { return true } else { return false } }
        XCTAssertEqual(end, .refused(httpCode: 403))
        XCTAssertFalse(t.isOnline)
        for _ in 0..<100 where slept.values.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(slept.values.first, RelayBridgeTransport.retryRefusedMs)
    }

    func testRetryDelaysFollowTheContract() {
        XCTAssertEqual(RelayBridgeTransport.retryDelayMs(after: .refused(httpCode: 429), backoff: 5_000), 65_000)
        XCTAssertEqual(RelayBridgeTransport.retryDelayMs(after: .refused(httpCode: 401), backoff: 5_000), 300_000)
        XCTAssertEqual(RelayBridgeTransport.retryDelayMs(after: .refused(httpCode: 500), backoff: 7_000), 7_000)
        XCTAssertEqual(RelayBridgeTransport.retryDelayMs(after: .closed(reason: .superseded, detail: ""), backoff: 5_000), 60_000)
        XCTAssertEqual(RelayBridgeTransport.retryDelayMs(after: .closed(reason: .error, detail: ""), backoff: 10_000), 10_000)
    }

    func testStopClosesTheTunnelAndReportsOffline() async {
        let dialer = FakeDialer([.accept])
        let t = transport(dialer)
        await t.start()
        _ = await settle(t.state) { $0 == .open }
        await t.stop()
        XCTAssertFalse(t.isOnline)
        XCTAssertEqual(t.state.value, .closed(reason: .local, detail: "stopped"))
        let hub = dialer.hub!
        for _ in 0..<100 where hub.closedWith == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(hub.closedWith?.code, 1000)
    }
}

final class RelayReceived: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var items: [(String, [UInt8])] = []
    func add(_ id: String, _ pkt: [UInt8]) {
        lock.lock()
        items.append((id, pkt))
        lock.unlock()
    }
}
