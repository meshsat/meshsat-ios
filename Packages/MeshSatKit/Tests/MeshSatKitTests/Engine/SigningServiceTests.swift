// Mirrors the intent of signing.go's tests: the chain links entries, a changed entry is found,
// and the key survives a restart through the store.
import MeshSatEngine
import XCTest

private final class FakeAuditStore: AuditStore, @unchecked Sendable {
    var rows: [AuditLogEntry] = []
    func insert(_ entry: AuditLogEntry) async throws -> Int64 {
        var e = entry
        e.id = Int64(rows.count + 1)
        rows.append(e)
        return e.id!
    }
    func getRecent(limit: Int) async throws -> [AuditLogEntry] { Array(rows.suffix(limit).reversed()) }
}

final class SigningServiceTests: XCTestCase {
    func testEntriesChainAndTheChainVerifies() async {
        let store = FakeAuditStore()
        let svc = SigningService(audit: store, store: MemoryKeyValueStore())
        await svc.auditEvent("dispatch", interfaceId: "mesh_0", direction: "egress", deliveryId: 1, detail: "text")
        await svc.auditEvent("deliver", interfaceId: "mesh_0", direction: "egress", deliveryId: 1, detail: "text")
        XCTAssertEqual(store.rows[0].prevHash, "")
        XCTAssertEqual(store.rows[1].prevHash, store.rows[0].hash)
        XCTAssertEqual(store.rows[0].hash.count, 64)
        let r = await svc.verifyChain()
        XCTAssertEqual(r.valid, 2)
        XCTAssertEqual(r.brokenAt, -1)
    }

    func testAChangedEntryIsFound() async {
        let store = FakeAuditStore()
        let svc = SigningService(audit: store, store: MemoryKeyValueStore())
        for i in 0..<3 { await svc.auditEvent("deliver", detail: "m\(i)") }
        store.rows[1].detail = "tampered"
        let r = await svc.verifyChain()
        XCTAssertEqual(r.brokenAt, 1)
        XCTAssertEqual(r.valid, 1)
    }

    func testTheKeySurvivesARestartAndTheChainContinues() async {
        let kv = MemoryKeyValueStore()
        let store = FakeAuditStore()
        let first = SigningService(audit: store, store: kv)
        await first.auditEvent("connect")
        let again = SigningService(audit: store, store: kv)
        XCTAssertEqual(again.signerId, first.signerId)
        await again.loadLastHash()
        await again.auditEvent("disconnect")
        XCTAssertEqual(store.rows[1].prevHash, store.rows[0].hash)
        let sig = again.sign([1, 2, 3])
        XCTAssertEqual(sig.count, 64)
    }

    func testTheHashIsSha256OverTheFourFields() {
        // echo -n 'abc2026-09-25T00:00:00Zdeliverx' | sha256sum
        XCTAssertEqual(
            SigningService.chainHash(prevHash: "abc", timestamp: "2026-09-25T00:00:00Z", eventType: "deliver", detail: "x"),
            "1afe059d51dbc021095f35e23b2c9adbb96fb295167ec24f29e4fe72d977a7d8")
    }
}
