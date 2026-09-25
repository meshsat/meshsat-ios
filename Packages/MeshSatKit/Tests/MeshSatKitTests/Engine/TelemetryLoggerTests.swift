// Mirrors TelemetryLoggerTest.kt: heap, health and event paths, retention, opt-out; plus the
// crash recovery that Android tests on the device, and the canonical JSON.
import XCTest

@testable import MeshSatEngine

final class TelemetryLoggerTests: XCTestCase {
    private final class FakeStore: TelemetryStore, @unchecked Sendable {
        private let lock = NSLock()
        private var rowsValue: [TelemetryEntry] = []
        private var nextId: Int64 = 1
        var rows: [TelemetryEntry] {
            lock.lock()
            defer { lock.unlock() }
            return rowsValue
        }

        func insert(_ entry: TelemetryEntry) async throws -> Int64 { append(entry) }

        func trimType(_ type: String, keep: Int) async throws { trim(type, keep: keep) }

        // The lock is taken in synchronous helpers (Swift 6 rejects it inside an async function).
        private func append(_ entry: TelemetryEntry) -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            var e = entry
            e.id = nextId
            nextId += 1
            rowsValue.append(e)
            return e.id ?? 0
        }

        private func trim(_ type: String, keep: Int) {
            lock.lock()
            defer { lock.unlock() }
            let keepIds = Set(rowsValue.filter { $0.type == type }.sorted { ($0.id ?? 0) > ($1.id ?? 0) }.prefix(keep).map { $0.id ?? 0 })
            rowsValue.removeAll { $0.type == type && !keepIds.contains($0.id ?? 0) }
        }

        func count(_ type: String) -> Int { rows.filter { $0.type == type }.count }
    }

    private final class Toggle: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        var enabled: Bool {
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

    private func logger(_ store: FakeStore, enabled: Bool = true) -> TelemetryLogger {
        TelemetryLogger(
            store: store, enabled: { enabled }, now: { 1_700_000_000_000 },
            heapSampler: { ("Footprint 42/512 MB", ["physFootprint": 44_040_192, "physicalMemory": 536_870_912]) })
    }

    func testRecordHeapWritesASample() async {
        let store = FakeStore()
        let log = logger(store)
        log.recordHeap()
        await log.drain()
        XCTAssertEqual(store.rows.count, 1)
        let entry = store.rows[0]
        XCTAssertEqual(entry.type, TelemetryLogger.typeHeap)
        XCTAssertEqual(entry.severity, TelemetryLogger.sevSample)
        XCTAssertEqual(entry.tag, "HeapSampler")
        XCTAssertEqual(entry.message, "Footprint 42/512 MB")
        XCTAssertEqual(entry.detail, "{\"physFootprint\":44040192,\"physicalMemory\":536870912}")
    }

    func testRecordHealthSerializesToJson() async {
        let store = FakeStore()
        let log = logger(store)
        log.recordHealth(
            message: "iface 3/5 online, pass mode Active",
            detail: [
                "interfacesOnline": 3, "interfacesTotal": 5, "passMode": "Active", "sosActive": false, "nested": .object(["inner": 42]),
            ])
        await log.drain()
        let entry = store.rows[0]
        XCTAssertEqual(entry.type, TelemetryLogger.typeHealth)
        XCTAssertEqual(entry.message, "iface 3/5 online, pass mode Active")
        XCTAssertEqual(
            entry.detail,
            "{\"interfacesOnline\":3,\"interfacesTotal\":5,\"nested\":{\"inner\":42},\"passMode\":\"Active\",\"sosActive\":false}")
    }

    func testRecordEventSeverities() async {
        let store = FakeStore()
        let log = logger(store)
        log.recordEvent(tag: "KeyBundleImporter", message: "Bridge pinned", detail: ["hash": "deadbeef"])
        log.recordEvent(
            tag: "PassScheduler", message: "Predictor call exceeded 500ms", detail: ["elapsedMs": 1234], severity: TelemetryLogger.sevWarn)
        await log.drain()
        XCTAssertEqual(store.rows.count, 2)
        XCTAssertEqual(store.rows[0].severity, TelemetryLogger.sevInfo)
        XCTAssertEqual(store.rows[0].tag, "KeyBundleImporter")
        XCTAssertEqual(store.rows[0].detail, "{\"hash\":\"deadbeef\"}")
        XCTAssertEqual(store.rows[1].severity, TelemetryLogger.sevWarn)
    }

    func testEventRetentionTrimsOldestAboveCap() async {
        let store = FakeStore()
        let log = logger(store)
        let cap = TelemetryLogger.maxEvents
        for i in 0..<(cap + 5) { log.recordEvent(tag: "Test", message: "event-\(i)", detail: ["i": .int(Int64(i))]) }
        await log.drain()
        XCTAssertEqual(store.count(TelemetryLogger.typeEvent), cap)
    }

    func testDisabledDiscardsAllWrites() async {
        let store = FakeStore()
        let log = logger(store, enabled: false)
        log.recordHeap()
        log.recordHealth(message: "test", detail: ["k": "v"])
        log.recordEvent(tag: "Test", message: "should not persist")
        await log.drain()
        XCTAssertEqual(store.rows.count, 0)
    }

    func testToggleIsReadPerWrite() async {
        let store = FakeStore()
        let toggle = Toggle()
        let log = TelemetryLogger(store: store, enabled: { toggle.enabled })
        log.recordEvent(tag: "Test", message: "first")
        await log.drain()
        XCTAssertEqual(store.rows.count, 1)
        toggle.enabled = false
        log.recordEvent(tag: "Test", message: "second should be dropped")
        await log.drain()
        XCTAssertEqual(store.rows.count, 1)
        toggle.enabled = true
        log.recordEvent(tag: "Test", message: "third resumed")
        await log.drain()
        XCTAssertEqual(store.rows.count, 2)
    }

    func testRetentionPerTypeIsIndependent() async {
        let store = FakeStore()
        let log = logger(store)
        log.recordEvent(tag: "Test", message: "e1")
        log.recordEvent(tag: "Test", message: "e2")
        log.recordHealth(message: "h1", detail: [:])
        log.recordHeap()
        await log.drain()
        XCTAssertEqual(store.count(TelemetryLogger.typeEvent), 2)
        XCTAssertEqual(store.count(TelemetryLogger.typeHealth), 1)
        XCTAssertEqual(store.count(TelemetryLogger.typeHeap), 1)
        XCTAssertEqual(store.count(TelemetryLogger.typeCrash), 0)
    }

    func testRecoverPendingCrash() async {
        let store = FakeStore()
        let log = logger(store)
        let dump = CanonicalJSON.encode([
            "timestamp": 1_699_999_999_000, "thread": "main", "exception": "SIGABRT",
            "message": "Fatal error: Index out of range \"x\" <y>", "stack": "0 MeshSat 0x1\n1 MeshSat 0x2", "versionName": "0.1.0",
        ])
        await log.recoverPendingCrash(dump)
        XCTAssertEqual(store.rows.count, 1)
        let entry = store.rows[0]
        XCTAssertEqual(entry.type, TelemetryLogger.typeCrash)
        XCTAssertEqual(entry.severity, TelemetryLogger.sevFatal)
        XCTAssertEqual(entry.timestamp, 1_699_999_999_000)
        XCTAssertEqual(entry.message, "SIGABRT: Fatal error: Index out of range \"x\" <y>")
        XCTAssertEqual(entry.detail, dump)
        // Disabled: the file's content is dropped.
        let off = logger(FakeStore(), enabled: false)
        await off.recoverPendingCrash(dump)
        // An empty file (the handler's untouched file from a clean run) is not a crash.
        let empty = FakeStore()
        await logger(empty).recoverPendingCrash("")
        await logger(empty).recoverPendingCrash("  \n")
        XCTAssertEqual(empty.rows.count, 0)
    }

    func testCanonicalJson() {
        XCTAssertEqual(
            CanonicalJSON.encode(["b": 1, "a": "x<y>&z", "c": .null, "d": true, "e": 2.5, "f": .array([1, "two"])]),
            "{\"a\":\"x\\u003cy\\u003e\\u0026z\",\"b\":1,\"c\":null,\"d\":true,\"e\":2.5,\"f\":[1,\"two\"]}")
        XCTAssertEqual(CanonicalJSON.encode(["n": 3.0]), "{\"n\":3}")
        XCTAssertEqual(CanonicalJSON.encode(["q": "a\"b\\c\nd"]), "{\"q\":\"a\\\"b\\\\c\\nd\"}")
        XCTAssertEqual(TelemetryLogger.jsonInt("{\"timestamp\":-5,\"x\":1}", "timestamp"), -5)
        XCTAssertNil(TelemetryLogger.jsonInt("{}", "timestamp"))
        XCTAssertEqual(TelemetryLogger.jsonString("{\"exception\":\"a\\\"b\",\"m\":1}", "exception"), "a\"b")
    }
}
