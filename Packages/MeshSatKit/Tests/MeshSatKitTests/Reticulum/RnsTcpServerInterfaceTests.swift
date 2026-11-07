// The TCP server interface over real sockets (MeshSatNIO), as a stock TCPClientInterface would use it:
// two peers connect, a transmit reaches both, a peer's frame reaches the receive callback, a peer that
// leaves is forgotten. Runs on Linux CI; mirrors what rns/TcpServerInterface.kt is exercised for in the
// Android interop tests.
import Foundation
import XCTest

@testable import MeshSatNIO
@testable import MeshSatNet
@testable import MeshSatReticulum

final class RnsTcpServerInterfaceTests: XCTestCase {
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

    private func waitFor(_ what: String, timeoutMs: Int64 = 5000, file: StaticString = #filePath, line: UInt = #line, _ cond: () -> Bool)
        async throws
    {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if cond() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timeout waiting for \(what)", file: file, line: line)
    }

    func testPeersJoinReceiveEveryTransmitAndAreForgottenWhenTheyLeave() async throws {
        let server = RnsTcpServerInterface(factory: NIOByteStreamListenerFactory(), interfaceId: "tcp_0")
        let received = Box<[UInt8]>()
        server.setReceiveCallback { iface, raw in
            XCTAssertEqual(iface, "tcp_0")
            received.add(raw)
        }
        let port = try await server.listen(port: 0)
        XCTAssertGreaterThan(port, 0)
        XCTAssertTrue(server.isOnline)

        let dialer = NIOByteStreamDialer()
        let a = try await dialer.dial(host: "127.0.0.1", port: port, tls: nil, timeoutSeconds: 5)
        let b = try await dialer.dial(host: "127.0.0.1", port: port, tls: nil, timeoutSeconds: 5)
        try await waitFor("two peers") { server.peerCount() == 2 }

        // A packet from the server reaches both peers, HDLC framed.
        let packet: [UInt8] = [0x00, 0x00] + [UInt8](repeating: 0xAB, count: 16) + [0x00, 0x7E, 0x7D, 0x01]
        let sendErr = await server.send(packet)
        XCTAssertNil(sendErr)
        for s in [a, b] {
            var deframer = RnsHdlc.Deframer()
            var frames: [[UInt8]] = []
            for await bytes in s.incoming {
                frames += deframer.feed(bytes)
                if !frames.isEmpty { break }
            }
            XCTAssertEqual(frames.first, packet)
        }

        // A peer's frame reaches the callback whole, even split across two writes.
        let framed = RnsHdlc.frame(packet)
        try await a.send(Array(framed.prefix(7)))
        try await a.send(Array(framed.dropFirst(7)))
        try await waitFor("frame received") { !received.all.isEmpty }
        XCTAssertEqual(received.all.first, packet)

        // A peer that leaves is forgotten; the other still gets packets.
        await b.close()
        try await waitFor("peer forgotten") { server.peerCount() == 1 }
        let sendErr2 = await server.send(packet)
        XCTAssertNil(sendErr2)

        await server.stop()
        XCTAssertFalse(server.isOnline)
        XCTAssertEqual(server.peerCount(), 0)
        await a.close()
    }

    func testNoPeerIsNotAFailureAndStopClosesTheListener() async throws {
        let server = RnsTcpServerInterface(factory: NIOByteStreamListenerFactory(), interfaceId: "tcp_0")
        let port = try await server.listen(port: 0)
        let sendErr = await server.send([1, 2, 3])
        XCTAssertNil(sendErr)
        await server.stop()
        do {
            _ = try await NIOByteStreamDialer().dial(host: "127.0.0.1", port: port, tls: nil, timeoutSeconds: 2)
            XCTFail("the closed listener accepted a connection")
        } catch {
            // refused, as it should be
        }
    }
}
