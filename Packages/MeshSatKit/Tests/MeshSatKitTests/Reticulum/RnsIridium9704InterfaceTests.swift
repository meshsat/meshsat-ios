// The Reticulum interface on the 9704 without a modem: framing and dedup on receive, the queue's
// limits, and a packet that waits for a modem that never comes up is dropped after its age limit on
// the injected clock (Android's RnsIridium9704Interface behaviour; the modem leg is the phone's).
import Foundation
import XCTest

@testable import MeshSatMeshtastic
@testable import MeshSatNet
@testable import MeshSatReticulum

final class RnsIridium9704InterfaceTests: XCTestCase {
    /// A clock whose sleeps advance it at once.
    final class FastClock: DriverClock, @unchecked Sendable {
        private let lock = NSLock()
        private var now: Int64 = 1_000_000
        func nowMs() -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            return now
        }
        func sleep(ms: Int64) async {
            advance(ms)
            await Task.yield()
        }
        private func advance(_ ms: Int64) {
            lock.lock()
            now += ms
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

    private func packet() -> [UInt8] { [0x00, 0x00] + [UInt8](repeating: 0xAB, count: 16) + [0x00, 0x01, 0x02] }

    func testFramedMtsReachTheNodeOnceAndTextsFallThrough() {
        let clock = FastClock()
        let iface = RnsIridium9704Interface(driver: Iridium9704Driver(clock: clock), clock: clock)
        let got = Box<[UInt8]>()
        iface.setReceiveCallback { id, raw in
            XCTAssertEqual(id, "iridium9704_0")
            got.add(raw)
        }
        let p = packet()
        XCTAssertTrue(iface.deliverMt(RnsImtFraming.encode(p)))
        XCTAssertEqual(got.all, [p])
        XCTAssertTrue(iface.deliverMt(RnsImtFraming.encode(p)), "a repeat is taken and dropped")
        XCTAssertEqual(got.all.count, 1)
        XCTAssertFalse(iface.deliverMt(Array("a text for the conversation".utf8)))
        XCTAssertFalse(iface.deliverMt(RnsImtFraming.header + [0x00]), "a frame whose rest is not a packet is not one")
        XCTAssertEqual(got.all.count, 1)
    }

    func testAnOversizePacketIsRefusedAndTheQueueFillsUp() async {
        let clock = FastClock()
        let iface = RnsIridium9704Interface(driver: Iridium9704Driver(clock: clock), queueSize: 2, maxAgeMs: 1_000_000_000, clock: clock)
        let big = [UInt8](repeating: 1, count: Iridium9704Driver.imtMaxSize)
        let tooBig = await iface.send(big)
        XCTAssertEqual(tooBig, "packet exceeds IMT MTU")
        // The modem never comes up: the first packet sits in its retry loop and the next ones queue behind it.
        for _ in 0..<3 {
            let r = await iface.send(packet())
            XCTAssertNil(r)
        }
        let full = await iface.send(packet())
        XCTAssertEqual(full, "9704 send queue full (2)")
        XCTAssertFalse(iface.isOnline)
        await iface.stop()
    }

    func testAPacketNoModemTakesIsDroppedAfterItsAgeLimit() async throws {
        let clock = FastClock()
        let logged = Box<String>()
        let iface = RnsIridium9704Interface(
            driver: Iridium9704Driver(clock: clock), maxAgeMs: 20_000, retryBackoffMs: [5_000], clock: clock, log: { logged.add($0) })
        let queued = await iface.send(packet())
        XCTAssertNil(queued)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, iface.queueStats().dropped == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        let s = iface.queueStats()
        XCTAssertEqual(s.dropped, 1)
        XCTAssertEqual(s.sent, 0)
        XCTAssertGreaterThanOrEqual(s.retried, 4)
        XCTAssertTrue(logged.all.contains { $0.hasPrefix("RNS packet dropped") })
        await iface.stop()
    }
}
