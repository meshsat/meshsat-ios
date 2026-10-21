// Mirrors BirthStamperTest.kt (MESHSAT-1623, R32-R1): the birth stamps the Hub orders this phone's
// births by, the cases the Bridge's stamp tests hold: a clock behind, ahead or stepped back, a
// restart, a floor that cannot be read, a stamp that cannot be stored, and a stored value that
// is not a timestamp. Beyond Android, the reporter itself against the fake broker: births carry
// their stamps and the 9704's declaration, and one that did not go out is tried again.
// [MESHSAT-1624]
import Foundation
import MeshSatHub
import MeshSatNet
import XCTest

/// A store whose reads and writes fail on cue, and which keeps what it stored like a file.
final class StampStore: BirthStampStore, @unchecked Sendable {
    struct Refused: Error {}
    private let lock = NSLock()
    private var storedValue: String?
    private var failReadValue = false
    private var failSaveValue = false
    private var savedList: [BirthStamp] = []

    init(stored: String? = nil) { storedValue = stored }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    var stored: String? { locked { storedValue } }
    var saved: [BirthStamp] { locked { savedList } }
    var failRead: Bool {
        get { locked { failReadValue } }
        set { locked { failReadValue = newValue } }
    }
    var failSave: Bool {
        get { locked { failSaveValue } }
        set { locked { failSaveValue = newValue } }
    }

    func lastBirthStamp() throws -> BirthStamp? {
        let (fail, value) = locked { (failReadValue, storedValue) }
        if fail { throw Refused() }
        return try value.map { try BirthStamper.parse($0) }
    }

    func saveBirthStamp(_ stamp: BirthStamp) throws {
        try locked {
            if failSaveValue { throw Refused() }
            storedValue = BirthStamper.format(stamp)
            savedList.append(stamp)
        }
    }
}

final class BirthStamperTests: XCTestCase {
    /// 2026-10-21T13:00:00Z.
    private let t0 = BirthStamp(micros: 1_792_587_600_000_000)

    private func ns(_ stamp: BirthStamp, plusSeconds: Int64 = 0, plusNanos: Int64 = 0) -> Int64 {
        (stamp.micros + plusSeconds * 1_000_000) * 1000 + plusNanos
    }

    private func micro(_ stamp: BirthStamp, _ n: Int64 = 1) -> BirthStamp { BirthStamp(micros: stamp.micros + n) }

    private func refused(_ block: () throws -> BirthStamp, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try block(), "not refused", file: file, line: line) { error in
            XCTAssertTrue(error is BirthStampError, "\(error)", file: file, line: line)
        }
    }

    func testStampsFollowTheClockAndNeverGoBack() throws {
        let s = BirthStamper(store: StampStore())
        let a = try s.next(nowNanos: ns(t0))
        XCTAssertEqual(a, t0)
        let behind = try s.next(nowNanos: ns(t0, plusSeconds: -3600))
        XCTAssertEqual(behind, micro(t0))
        let same = try s.next(nowNanos: ns(t0))
        XCTAssertGreaterThan(same, behind)
        let ahead = try s.next(nowNanos: ns(t0, plusSeconds: 60))
        XCTAssertEqual(ahead, BirthStamp(micros: t0.micros + 60_000_000))
    }

    func testARestartStampsLaterThanEveryBirthAlreadySentWithTheClockBehind() throws {
        let store = StampStore()
        let first = BirthStamper(store: store)
        let sent = [try first.next(nowNanos: ns(t0, plusSeconds: 3600)), try first.next(nowNanos: ns(t0, plusSeconds: 3600))]
        let after = try BirthStamper(store: store).next(nowNanos: ns(t0))
        XCTAssertTrue(sent.allSatisfy { after > $0 })
        XCTAssertEqual(after, micro(sent[1]))
    }

    func testAnUnreadableFloorHandsOutNothingUntilItIsRead() throws {
        let store = StampStore(stored: BirthStamper.format(t0))
        store.failRead = true
        let s = BirthStamper(store: store)
        refused { try s.next(nowNanos: self.ns(self.t0, plusSeconds: -60)) }
        refused { try s.next(nowNanos: self.ns(self.t0, plusSeconds: -60)) }
        XCTAssertEqual(store.saved, [])
        store.failRead = false
        XCTAssertEqual(try s.next(nowNanos: ns(t0, plusSeconds: -60)), micro(t0))
    }

    func testAStoredValueThatIsNotATimestampIsAnErrorNeverNoStamp() {
        let store = StampStore(stored: "not a time")
        refused { try BirthStamper(store: store).next(nowNanos: self.ns(self.t0)) }
        XCTAssertEqual(store.stored, "not a time")
    }

    func testAStampThatCannotBeStoredIsNotHandedOutAndTheFloorDoesNotMove() throws {
        let store = StampStore()
        let s = BirthStamper(store: store)
        let a = try s.next(nowNanos: ns(t0))
        store.failSave = true
        refused { try s.next(nowNanos: self.ns(self.t0, plusSeconds: -10)) }
        XCTAssertEqual(store.stored, BirthStamper.format(a))
        store.failSave = false
        let b = try s.next(nowNanos: ns(t0, plusSeconds: -10))
        XCTAssertEqual(b, micro(a))
        // A restart after the failure still stamps later than everything handed out.
        XCTAssertGreaterThan(try BirthStamper(store: store).next(nowNanos: ns(t0, plusSeconds: -10)), b)
    }

    func testNoStoreKeepsTheOrderForThisProcess() throws {
        let s = BirthStamper(store: nil)
        let a = try s.next(nowNanos: ns(t0))
        XCTAssertGreaterThan(try s.next(nowNanos: ns(t0, plusSeconds: -5)), a)
    }

    func testTheStampTravelsInTheBirthAsRfc3339WithItsMicroseconds() throws {
        let stamp = micro(t0)
        XCTAssertEqual(BirthStamper.format(stamp), "2026-10-21T13:00:00.000001Z")
        XCTAssertEqual(try BirthStamper.parse(BirthStamper.format(stamp)), stamp)
        // Sub-microsecond clock digits are cut, so a stored stamp reads back exactly.
        XCTAssertEqual(try BirthStamper(store: nil).next(nowNanos: ns(t0, plusNanos: 1999)), micro(t0))
        let json = BridgeBirth(bridgeId: "msa-test", version: "x", hostname: "h", timestamp: BirthStamper.format(stamp)).toJson()
        XCTAssertEqual(json.string("timestamp"), "2026-10-21T13:00:00.000001Z")
    }

    /// Java's ISO_INSTANT, which Android formats with: no fraction on a whole second, three digits
    /// on a whole millisecond, six otherwise; and Instant.parse's strictness on what is not one.
    func testTheFormIsJavasIsoInstant() throws {
        XCTAssertEqual(BirthStamper.format(t0), "2026-10-21T13:00:00Z")
        XCTAssertEqual(BirthStamper.format(micro(t0, 1000)), "2026-10-21T13:00:00.001Z")
        XCTAssertEqual(BirthStamper.format(micro(t0, 1500)), "2026-10-21T13:00:00.001500Z")
        XCTAssertEqual(BirthStamper.format(BirthStamp.epoch), "1970-01-01T00:00:00Z")
        XCTAssertEqual(BirthStamper.format(BirthStamp(micros: 1_709_164_799_999_999)), "2024-02-28T23:59:59.999999Z")
        XCTAssertEqual(try BirthStamper.parse("2026-10-21T13:00:00Z"), t0)
        XCTAssertEqual(try BirthStamper.parse("2026-10-21T13:00:00.5Z"), micro(t0, 500_000))
        XCTAssertEqual(try BirthStamper.parse("2026-10-21T13:00:00.000001999Z"), micro(t0))
        XCTAssertEqual(try BirthStamper.parse("2024-02-29T00:00:00Z"), BirthStamp(micros: 1_709_164_800_000_000))
        for bad in [
            "", "not a time", "2026-10-21 13:00:00Z", "2026-10-21T13:00:00", "2026-10-21T13:00:00.Z", "2026-02-30T00:00:00Z",
            "2026-13-01T00:00:00Z", "2026-10-21T24:00:00Z", "2026-10-21T13:00:00.0000000001Z", "2026-10-21T13:00:00Zjunk",
        ] {
            XCTAssertThrowsError(try BirthStamper.parse(bad), bad)
        }
    }

    // MARK: The reporter

    private func eventually(_ timeoutMs: Int = 10_000, _ cond: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return await cond()
    }

    private func births(_ session: FakeMQTTSession) -> [[String: Any]] {
        session.published.filter { $0.topic.hasSuffix("/birth") }.compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.payload.utf8))) as? [String: Any]
        }
    }

    private func modem(_ birth: [String: Any]) -> [String: Any]? {
        (birth["interfaces"] as? [[String: Any]])?.first { $0["type"] as? String == "iridium_imt" }
    }

    func testTheReporterStampsItsBirthsInOrderAndDeclaresThe9704sChain() async throws {
        let clock = PacedClock()
        // The floor is an hour ahead of the phone's clock, as after a clock stepped back.
        let floor = BirthStamp(micros: clock.nowMs() * 1000 + 3_600_000_000)
        let store = StampStore(stored: BirthStamper.format(floor))
        store.failRead = true
        let session = FakeMQTTSession()
        let host = FakeHubHost()
        let format = LockedText("sealed")
        let reporter = HubReporter(
            config: HubReporterConfig(hubUrl: "wss://hub.example/mqtt", bridgeId: "ios-test", healthIntervalSec: 1), host: host,
            makeSession: { _ in session }, clock: clock, birthStamps: store)
        reporter.setImtEgressFormat { format.value }
        reporter.start()

        // No birth while the floor cannot be read; the health reports go on.
        let healthy = await eventually { session.published.filter { $0.topic.hasSuffix("/health") }.count >= 3 }
        XCTAssertTrue(healthy)
        XCTAssertEqual(births(session).count, 0)
        // Read at last: the retry loop sends it, later than the floor.
        store.failRead = false
        let born = await eventually { self.births(session).count == 1 }
        XCTAssertTrue(born)
        XCTAssertEqual(births(session).first?["timestamp"] as? String, BirthStamper.format(micro(floor)))

        // The 9704 paired: re-announced with its chain, and stamped later.
        host.setInterfaces([
            InterfaceInfo(name: "ble_mesh_0", type: "meshtastic", status: "online"),
            InterfaceInfo(name: "iridium_imt_0", type: "iridium_imt", status: "online", imei: "300000000000001"),
        ])
        let paired = await eventually { self.births(session).count == 2 }
        XCTAssertTrue(paired)
        XCTAssertEqual(modem(births(session)[1])?["egress_format"] as? String, "sealed")
        XCTAssertEqual(modem(births(session)[1])?["egress_sealed"] as? Bool, true)
        XCTAssertEqual(births(session)[1]["timestamp"] as? String, BirthStamper.format(micro(floor, 2)))

        // The chain switched to plain: re-announced again.
        format.value = "plain"
        let switched = await eventually { self.births(session).count == 3 }
        XCTAssertTrue(switched)
        XCTAssertEqual(modem(births(session)[2])?["egress_format"] as? String, "plain")
        XCTAssertNil(modem(births(session)[2])?["egress_sealed"])
        XCTAssertEqual(store.stored, BirthStamper.format(micro(floor, 3)))
        await reporter.stop()
    }

    func testABirthTheBrokerDidNotTakeIsTriedAgain() async {
        let clock = PacedClock()
        let session = FakeMQTTSession()
        session.refuseBirths = 1
        let reporter = HubReporter(
            config: HubReporterConfig(hubUrl: "wss://hub.example/mqtt", bridgeId: "ios-test", healthIntervalSec: 1), host: FakeHubHost(),
            makeSession: { _ in session }, clock: clock)
        reporter.start()
        let retried = await eventually { self.births(session).count == 1 }
        XCTAssertTrue(retried)
        XCTAssertEqual(session.refuseBirths, 0, "the first birth was refused")
        await reporter.stop()
    }
}

/// A text a test changes while the code under test reads it from another task.
final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String

    init(_ value: String) { current = value }

    var value: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            lock.unlock()
        }
    }
}
