// Mirrors AprsIsClientTest.kt (the TNC-2 parser), plus loopback runs of both clients that
// Android has no test for: the APRS-IS login exchange and the KISS frame path.
import MeshSatNet
import XCTest

@testable import MeshSatAprs

final class AprsIsClientTests: XCTestCase {
    func testParsePositionWithoutTimestamp() throws {
        let pkt = try XCTUnwrap(AprsIsClient.parseTnc2Line("PA3XYZ-10>APMSHT,WIDE1-1:!5222.06N/00454.25E-MeshSat Gateway"))
        XCTAssertEqual(pkt.source, "PA3XYZ-10")
        XCTAssertEqual(pkt.dest, "APMSHT")
        XCTAssertEqual(pkt.path, "WIDE1-1")
        XCTAssertEqual(pkt.dataType, "!")
        XCTAssertEqual(pkt.lat, 52.3676, accuracy: 0.001)
        XCTAssertEqual(pkt.lon, 4.9041, accuracy: 0.001)
        XCTAssertTrue(pkt.comment.contains("MeshSat"))
    }

    func testParsePositionWithTimestamp() throws {
        let pkt = try XCTUnwrap(AprsIsClient.parseTnc2Line("N0CALL>APRS,TCPIP*:/092345z4903.50N/07201.75W-PHG2360"))
        XCTAssertEqual(pkt.source, "N0CALL")
        XCTAssertEqual(pkt.dataType, "/")
        XCTAssertEqual(pkt.lat, 49.0583, accuracy: 0.01)
        XCTAssertEqual(pkt.lon, -72.0291, accuracy: 0.01)
    }

    func testParseMessages() throws {
        let withId = try XCTUnwrap(AprsIsClient.parseTnc2Line("PA3ABC-5>APRS,TCPIP*::PA3XYZ-10:Hello from APRS-IS{42"))
        XCTAssertEqual(withId.source, "PA3ABC-5")
        XCTAssertEqual(withId.dataType, ":")
        XCTAssertEqual(withId.msgTo, "PA3XYZ-10")
        XCTAssertEqual(withId.message, "Hello from APRS-IS")
        XCTAssertEqual(withId.msgId, "42")
        let noId = try XCTUnwrap(AprsIsClient.parseTnc2Line("W3ADO-1>APRS::PA3XYZ   :Weather alert"))
        XCTAssertEqual(noId.msgTo, "PA3XYZ")
        XCTAssertEqual(noId.message, "Weather alert")
        XCTAssertEqual(noId.msgId, "")
        let ack = try XCTUnwrap(AprsIsClient.parseTnc2Line("PA3XYZ-10>APRS,TCPIP*::PA3ABC-5 :ack42"))
        XCTAssertEqual(ack.msgTo, "PA3ABC-5")
        XCTAssertEqual(ack.message, "ack42")
    }

    func testParseSouthWestAndMultiHop() throws {
        let sw = try XCTUnwrap(AprsIsClient.parseTnc2Line("VK2ABC>APRS:!3352.00S/15112.00W-Test"))
        XCTAssertLessThan(sw.lat, 0)
        XCTAssertLessThan(sw.lon, 0)
        let hops = try XCTUnwrap(AprsIsClient.parseTnc2Line("N0CALL>APRS,WIDE1-1,WIDE2-1,qAR,RELAY:!0000.00N/00000.00E-test"))
        XCTAssertEqual(hops.path, "WIDE1-1,WIDE2-1,qAR,RELAY")
    }

    func testRejectsMalformed() {
        XCTAssertNil(AprsIsClient.parseTnc2Line("malformed line"))
        XCTAssertNil(AprsIsClient.parseTnc2Line("SRC>DST"))
        XCTAssertNil(AprsIsClient.parseTnc2Line(">DST:data"))
        XCTAssertNil(AprsIsClient.parseTnc2Line("SRC>DST:"))
    }

    func testUnknownDataTypeKeepsRaw() throws {
        let pkt = try XCTUnwrap(AprsIsClient.parseTnc2Line("N0CALL>APRS:>Status text here"))
        XCTAssertEqual(pkt.dataType, ">")
        XCTAssertEqual(pkt.raw, ">Status text here")
    }

    func testPositionPrecision() throws {
        let pkt = try XCTUnwrap(AprsIsClient.parseTnc2Line("TEST>APRS:!4903.50N/07201.75W-test"))
        XCTAssertEqual(pkt.lat, 49.0583, accuracy: 0.0005)
        XCTAssertEqual(pkt.lon, -72.0291, accuracy: 0.0005)
    }

    func testLoginLine() {
        XCTAssertEqual(
            AprsIsClient.loginLine(callsign: "PA3XYZ-10", passcode: "12345", filterLat: 52.4, filterLon: 4.9, filterRange: 100),
            "user PA3XYZ-10 pass 12345 vers MeshSat 1.0 filter r/52.4/4.9/100")
        XCTAssertEqual(
            AprsIsClient.loginLine(callsign: "N0CALL", passcode: "-1", filterLat: 0, filterLon: 0, filterRange: 100),
            "user N0CALL pass -1 vers MeshSat 1.0")
    }

    // MARK: Loopback runs

    func testAprsIsLoginAndTraffic() async throws {
        let dialer = LoopbackDialer()
        let client = AprsIsClient(dialer: dialer)
        let received = AprsReceived<AprsPacket>()
        client.setPacketCallback { received.add($0) }
        let server = Task {
            // The peer appears once the client dialled.
            var peer: LoopbackByteStream?
            while peer == nil {
                peer = dialer.peer
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard let peer else { return }
            try await peer.send(Array("# aprsc 2.1.15-gc67551b\r\n".utf8))
            var lines = LineReader()
            let login = try await lines.readLine(from: peer)
            XCTAssertEqual(login, "user PA3XYZ-10 pass 12345 vers MeshSat 1.0 filter r/52.4/4.9/50")
            try await peer.send(Array("# logresp PA3XYZ-10 verified, server T2TEST\r\n".utf8))
            try await peer.send(Array("# comment line\r\nN0CALL>APRS,TCPIP*::PA3XYZ-10:Hi there{7\r\n".utf8))
            let tx = try await lines.readLine(from: peer)
            XCTAssertEqual(tx, "PA3XYZ-10>APMSHT,TCPIP*::N0CALL   :ack7")
        }
        await client.connect(
            server: "rotate.aprs2.net", port: 14580, callsign: "PA3XYZ-10", passcode: "12345", filterLat: 52.4, filterLon: 4.9,
            filterRange: 50)
        XCTAssertEqual(client.state.value, .connected)
        XCTAssertTrue(client.verified)
        XCTAssertEqual(client.serverBanner, "# aprsc 2.1.15-gc67551b")
        XCTAssertEqual(dialer.dials.first?.host, "rotate.aprs2.net")
        let pkt = try await received.first(timeoutMs: 2_000)
        XCTAssertEqual(pkt.message, "Hi there")
        XCTAssertEqual(pkt.msgId, "7")
        await client.sendAck(callsign: "PA3XYZ-10", to: "N0CALL", msgId: "7")
        try await server.value
        // The server closing the socket ends the connection: state, not error.
        await dialer.peer?.close()
        for _ in 0..<200 where client.state.value == .connected { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(client.state.value, .disconnected)
    }

    func testAprsIsRefusedIsError() async {
        let dialer = LoopbackDialer()
        dialer.refuse = true
        let client = AprsIsClient(dialer: dialer)
        await client.connect(server: "x", callsign: "N0CALL")
        XCTAssertEqual(client.state.value, .error)
        XCTAssertFalse(client.isConnected)
    }

    func testKissClientFramesBothWays() async throws {
        let dialer = LoopbackDialer()
        let client = KissClient(dialer: dialer)
        let received = AprsReceived<Ax25Frame>()
        client.setFrameCallback { received.add($0) }
        await client.connect(host: "localhost", port: 8001)
        XCTAssertEqual(client.state.value, .connected)
        let peer = try XCTUnwrap(dialer.peer)
        let inbound = Ax25Codec.encode(
            dst: Ax25Address("APRS"), src: Ax25Address("PA3ABC", 5), path: [], info: Array("!5222.06N/00454.25E-hi".utf8))
        // Two frames in one write, split oddly, still two frames out.
        let bytes = KissCodec.encode(inbound) + KissCodec.encode(inbound)
        try await peer.send(Array(bytes[0..<7]))
        try await peer.send(Array(bytes[7...]))
        let first = try await received.first(timeoutMs: 2_000)
        XCTAssertEqual(first.src, Ax25Address("PA3ABC", 5))
        XCTAssertEqual(AprsCodec.parse(first).lat, 52.3677, accuracy: 0.001)
        let outbound = Ax25Codec.encode(dst: Ax25Address("APMSHT"), src: Ax25Address("PA3XYZ", 10), path: [], info: Array("test".utf8))
        await client.sendFrame(outbound)
        var got: [UInt8] = []
        for await chunk in peer.incoming {
            got += chunk
            if got.count >= KissCodec.encode(outbound).count { break }
        }
        XCTAssertEqual(got, KissCodec.encode(outbound))
        client.disconnect()
        XCTAssertEqual(client.state.value, .disconnected)
    }
}

/// Values a callback delivered, with a wait for the first one.
final class AprsReceived<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func add(_ item: T) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func first(timeoutMs: Int) async throws -> T {
        for _ in 0..<(timeoutMs / 5) {
            if let item = all.first { return item }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw ByteStreamError.timeout
    }
}
