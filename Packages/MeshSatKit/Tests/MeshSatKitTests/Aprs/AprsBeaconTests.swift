// Mirrors AprsBeaconTest.kt and AprsMessageTrackerTest.kt, with the timing that Android's
// tests leave to the coroutine scope driven by an injected clock and sleep here.
import XCTest

@testable import MeshSatAprs

final class AprsBeaconTests: XCTestCase {
    func testConstants() {
        XCTAssertEqual(AprsBeacon.defaultSlowRateSec, 600)
        XCTAssertEqual(AprsBeacon.defaultFastRateSec, 90)
        XCTAssertEqual(AprsBeacon.minBeaconIntervalSec, 60)
        XCTAssertEqual(AprsBeacon.speedThresholdMps, 2.0, accuracy: 0.01)
        XCTAssertEqual(AprsBeacon.headingChangeDeg, 30.0, accuracy: 0.01)
    }

    func testBeaconStartsDisabled() {
        XCTAssertFalse(AprsBeacon().enabled)
    }

    func testPositionEncodingForBeaconComment() {
        let encoded = String(decoding: AprsCodec.encodePosition(lat: 47.3, lon: -122.5, comment: "MeshSat"), as: UTF8.self)
        XCTAssertTrue(encoded.hasPrefix("!"))
        XCTAssertTrue(encoded.contains("N"))
        XCTAssertTrue(encoded.contains("W"))
        XCTAssertTrue(encoded.hasSuffix("MeshSat"))
        let speed = String(decoding: AprsCodec.encodePosition(lat: 52.3676, lon: 4.9041, comment: "25km/h alt=15m MeshSat"), as: UTF8.self)
        XCTAssertTrue(speed.contains("5222"))
        XCTAssertTrue(speed.contains("00454"))
        XCTAssertTrue(speed.contains("25km/h"))
    }

    func testCommentFromFix() {
        XCTAssertEqual(AprsBeacon.comment(for: AprsFix(latitude: 0, longitude: 0, altitude: 15, speed: 25 / 3.6)), "25km/h alt=15m MeshSat")
        XCTAssertEqual(AprsBeacon.comment(for: AprsFix(latitude: 0, longitude: 0)), "MeshSat")
    }

    func testSmartBeaconingRates() {
        let clock = TestClock()
        let beacon = AprsBeacon(now: { clock.now }, sleep: { _ in })
        let sent = AprsReceived<Double>()
        beacon.setOnBeacon { _, _, _, _, speed, _ in sent.add(speed) }
        beacon.slowRateSec = 600
        beacon.fastRateSec = 90
        beacon.onLocationUpdate(AprsFix(latitude: 52, longitude: 4, speed: 0))
        // No fix time has passed since "never": the first check beacons.
        clock.now = 1_000_000
        beacon.checkAndBeacon()
        XCTAssertEqual(sent.all.count, 1)
        // Standing still: nothing for 599 s, one at 600 s.
        clock.now += 599_000
        beacon.checkAndBeacon()
        XCTAssertEqual(sent.all.count, 1)
        clock.now += 1_000
        beacon.checkAndBeacon()
        XCTAssertEqual(sent.all.count, 2)
        // Moving: every 90 s.
        beacon.onLocationUpdate(AprsFix(latitude: 52, longitude: 4, bearing: 10, speed: 10))
        clock.now += 89_000
        beacon.checkAndBeacon()
        XCTAssertEqual(sent.all.count, 2)
        clock.now += 1_000
        beacon.checkAndBeacon()
        XCTAssertEqual(sent.all.count, 3)
        // A rate below the courtesy minimum is raised to 60 s.
        beacon.fastRateSec = 5
        clock.now += 59_000
        beacon.checkAndBeacon()
        XCTAssertEqual(sent.all.count, 3)
        clock.now += 1_000
        beacon.checkAndBeacon()
        XCTAssertEqual(sent.all.count, 4)
    }

    func testCornerPegging() {
        let clock = TestClock()
        clock.now = 1_000_000
        let beacon = AprsBeacon(now: { clock.now }, sleep: { _ in })
        let sent = AprsReceived<Double>()
        beacon.setOnBeacon { _, _, _, course, _, _ in sent.add(course) }
        beacon.start()
        beacon.onLocationUpdate(AprsFix(latitude: 52, longitude: 4, bearing: 10, speed: 10))
        beacon.checkAndBeacon()
        XCTAssertEqual(sent.all.count, 1)
        // A 20 degree turn: no beacon. A 40 degree turn within 60 s: no beacon either.
        beacon.onLocationUpdate(AprsFix(latitude: 52, longitude: 4, bearing: 30, speed: 10))
        beacon.onLocationUpdate(AprsFix(latitude: 52, longitude: 4, bearing: 70, speed: 10))
        XCTAssertEqual(sent.all.count, 1)
        // The same turn after 60 s: a beacon at once.
        clock.now += 60_000
        beacon.onLocationUpdate(AprsFix(latitude: 52, longitude: 4, bearing: 110, speed: 10))
        XCTAssertEqual(sent.all, [10, 110])
        // A U-turn beacons too, but not twice within 60 s.
        clock.now += 60_000
        beacon.onLocationUpdate(AprsFix(latitude: 52, longitude: 4, bearing: 350, speed: 10))
        beacon.onLocationUpdate(AprsFix(latitude: 52, longitude: 4, bearing: 20, speed: 10))
        XCTAssertEqual(sent.all, [10, 110, 350])
        // Across the 360 wrap: 355 to 30 is a 35 degree turn, not 325.
        clock.now += 60_000
        beacon.onLocationUpdate(AprsFix(latitude: 52, longitude: 4, bearing: 355, speed: 10))
        XCTAssertEqual(sent.all.count, 3)
        beacon.onLocationUpdate(AprsFix(latitude: 52, longitude: 4, bearing: 30, speed: 10))
        XCTAssertEqual(sent.all.count, 4)
        // Walking pace turns never peg.
        clock.now += 60_000
        beacon.onLocationUpdate(AprsFix(latitude: 52, longitude: 4, bearing: 200, speed: 1))
        XCTAssertEqual(sent.all.count, 4)
        beacon.stop()
        XCTAssertFalse(beacon.enabled)
    }
}

final class AprsMessageTrackerTests: XCTestCase {
    private func tracker() -> (AprsMessageTracker, AprsReceived<String>) {
        let sent = AprsReceived<String>()
        let t = AprsMessageTracker(sleep: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) })
        t.setOnSend { _, _, msgId in sent.add(msgId) }
        return (t, sent)
    }

    func testSendAssignsSequentialIds() {
        let (t, sent) = tracker()
        XCTAssertEqual(t.send(to: "PA3ABC", text: "Hello"), "1")
        XCTAssertEqual(t.send(to: "PA3ABC", text: "World"), "2")
        XCTAssertEqual(sent.all, ["1", "2"])
        XCTAssertEqual(t.getStatus("1"), .pending)
        t.cancelAll()
    }

    func testAckAndRej() {
        let (t, _) = tracker()
        let statuses = AprsReceived<AprsMessageTracker.DeliveryStatus>()
        t.setOnStatusChange { _, s in statuses.add(s) }
        let a = t.send(to: "PA3ABC", text: "test")
        t.handleAck(a)
        XCTAssertEqual(t.getStatus(a), .acked)
        let r = t.send(to: "PA3ABC", text: "test")
        t.handleRej(r)
        XCTAssertEqual(t.getStatus(r), .rejected)
        XCTAssertEqual(statuses.all, [.acked, .rejected])
        t.cancelAll()
    }

    func testProcessInbound() {
        let (t, _) = tracker()
        let id = t.send(to: "PA3ABC", text: "test")
        XCTAssertTrue(t.processInbound(AprsPacket(source: "PA3ABC", dataType: ":", message: "ack\(id)", msgTo: "MYCALL")))
        XCTAssertEqual(t.getStatus(id), .acked)
        let id2 = t.send(to: "PA3ABC", text: "test")
        XCTAssertTrue(t.processInbound(AprsPacket(source: "PA3ABC", dataType: ":", message: "rej\(id2)", msgTo: "MYCALL")))
        XCTAssertEqual(t.getStatus(id2), .rejected)
        XCTAssertFalse(t.processInbound(AprsPacket(source: "N0CALL", dataType: "!")))
        XCTAssertFalse(t.processInbound(AprsPacket(source: "PA3ABC", dataType: ":", message: "ack999", msgTo: "MYCALL")))
        XCTAssertNil(t.getStatus("999"))
        t.cancelAll()
    }

    func testPendingAndCancel() {
        let (t, _) = tracker()
        t.send(to: "PA3ABC", text: "msg1")
        let id2 = t.send(to: "PA3ABC", text: "msg2")
        t.send(to: "PA3ABC", text: "msg3")
        t.handleAck(id2)
        XCTAssertEqual(t.getPending().map(\.msgId), ["1", "3"])
        t.cancelAll()
        XCTAssertEqual(t.getPending().count, 0)
    }

    func testRetriesThenFails() async throws {
        XCTAssertEqual(AprsMessageTracker.maxRetries, 3)
        XCTAssertEqual(AprsMessageTracker.retryIntervalMs, 30_000)
        let slept = AprsReceived<Int64>()
        let t = AprsMessageTracker(sleep: { slept.add($0) })
        let sent = AprsReceived<String>()
        t.setOnSend { _, _, id in sent.add(id) }
        let statuses = AprsReceived<AprsMessageTracker.DeliveryStatus>()
        t.setOnStatusChange { _, s in statuses.add(s) }
        let id = t.send(to: "PA3ABC", text: "x")
        _ = try await statuses.first(timeoutMs: 2_000)
        // One send, three resends 30 s apart, then failed.
        XCTAssertEqual(sent.all, [id, id, id, id])
        XCTAssertEqual(slept.all, [30_000, 30_000, 30_000])
        XCTAssertEqual(t.getStatus(id), .failed)
        XCTAssertEqual(t.getPending().count, 0)
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    var now: Int64 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}
