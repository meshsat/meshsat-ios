// The phone's signed directory (HeMB-NG C9.5, MESHSAT-1643) against the Hub's C7 fixture
// (fixtures-v1.1), answers made by the Hub's own relay directory handler
// (Fixtures/hubdirectory/relay_directory_answer.json, the same file Android tests) and the
// Bridge's apply rules. Mirrors HubDirectoryTest.kt.
import Crypto
import Foundation
import MeshSatNet
import XCTest

@testable import MeshSatHub

final class FakeDirectoryHttp: HttpGetter, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [HttpResponse] = []
    private(set) var requests: [(url: String, headers: [String: String])] = []

    func enqueue(_ r: HttpResponse) {
        lock.lock()
        defer { lock.unlock() }
        queue.append(r)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    /// Runs before each answer goes back: a test reprovisions the phone while a read is out.
    var beforeAnswer: (@Sendable () -> Void)?

    func get(_ url: String, headers: [String: String], timeoutSeconds: Double) async throws -> HttpResponse {
        let r = try take(url, headers)
        beforeAnswer?()
        return r
    }

    // NSLock is not for async code: the lock is held in this synchronous step only.
    private func take(_ url: String, _ headers: [String: String]) throws -> HttpResponse {
        lock.lock()
        defer { lock.unlock() }
        requests.append((url, headers))
        guard !queue.isEmpty else { throw HubDirectoryClient.Failure("no answer queued") }
        return queue.removeFirst()
    }
}

final class HubDirectoryTests: XCTestCase {
    private func json(_ path: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: path, withExtension: "json", subdirectory: "Fixtures"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func fixture() throws -> [String: Any] { try json("hemb-ng/v1/directory_v2") }
    private func hub() throws -> [String: Any] { try json("hubdirectory/relay_directory_answer") }
    private func obj(_ o: [String: Any], _ k: String) -> [String: Any] { o[k] as? [String: Any] ?? [:] }
    private func str(_ o: [String: Any], _ k: String) -> String { o[k] as? String ?? "" }
    private func b64(_ s: String) -> [UInt8] { Array(Data(base64Encoded: s) ?? Data()) }

    private func fixtureKey(_ f: [String: Any], _ name: String) -> String { str(obj(obj(f, "keys"), name), "pkix_b64") }
    private func fixtureCase(_ f: [String: Any], _ i: Int) -> [String: Any] { (f["cases"] as? [[String: Any]] ?? [])[i] }
    private func env(_ f: [String: Any], _ i: Int) -> [String: Any] { obj(fixtureCase(f, i), "envelope") }

    private func pinned(_ b64: String) -> DirectoryState {
        var s = DirectoryState()
        s.pinnedKey = b64
        s.pinSource = "bundle"
        return s
    }

    // A key of our own, sealing as the Hub does.
    private func seal(_ key: P256.Signing.PrivateKey, _ payload: [String: Any]) throws -> [String: Any] {
        let bytes = try JSONSerialization.data(withJSONObject: payload)
        let sig = try key.signature(for: bytes).derRepresentation
        return [
            "v": 2, "key_id": DirectoryEnvelope.keyId(Array(key.publicKey.derRepresentation)), "alg": "ES256",
            "payload": bytes.base64EncodedString(), "sig": sig.base64EncodedString(),
        ]
    }
    private func ownState(_ key: P256.Signing.PrivateKey) -> DirectoryState {
        pinned(key.publicKey.derRepresentation.base64EncodedString())
    }
    private func snap(_ tenant: String, _ version: Int, contacts: [[String: Any]] = [], groups: [[String: Any]] = []) -> [String: Any] {
        ["type": "snapshot", "tenant_id": tenant, "version": version, "contacts": contacts, "groups": groups]
    }
    private func contact(_ id: String, _ name: String, _ addresses: [(String, String)] = []) -> [String: Any] {
        ["id": id, "display_name": name, "addresses": addresses.map { ["kind": $0.0, "value": $0.1] }]
    }
    private func rotationRecord(_ tenant: String, _ version: Int, _ newKey: Data, id: String? = nil) -> [String: Any] {
        [
            "type": "rotation", "tenant_id": tenant, "version": version,
            "new_key_id": id ?? DirectoryEnvelope.keyId(Array(newKey)), "new_key_pkix": newKey.base64EncodedString(),
        ]
    }

    // MARK: the C7 fixture

    func testEveryFixtureEnvelopeVerifiesOrIsRefusedAsTheFixtureSays() throws {
        let f = try fixture()
        let cases = f["cases"] as? [[String: Any]] ?? []
        XCTAssertEqual(cases.count, 6)
        for c in cases {
            let trusted = b64(fixtureKey(f, str(c, "trusted_key")))
            let ok = (try? DirectoryEnvelope.open(obj(c, "envelope"), trusted: trusted)) != nil
            XCTAssertEqual(ok, c["verify"] as? Bool, str(c, "case"))
        }
    }

    func testTheFixtureChainMovesThePinAndTheNewKeysSnapshotApplies() throws {
        let f = try fixture()
        var r = DirectoryApply.snapshot(pinned(fixtureKey(f, "old")), env(f, 0), now: 1)
        XCTAssertTrue(r.applied, r.reason)
        XCTAssertEqual(r.state.version, 42)
        // The fixture's rows are not the Hub's REST shape ("name", "members"): the contact is
        // skipped as on the Bridge, the group stays, empty.
        XCTAssertEqual(r.state.skipped.map { "\($0.kind):\($0.id):\($0.reason)" }, ["contact:c-1:no_display_name"])
        XCTAssertEqual(r.state.groups.map(\.kind), ["TEAM"])
        let s = r.state

        XCTAssertEqual(DirectoryApply.snapshot(s, env(f, 1), now: 2).reason, DirectoryEnvelope.badSignature)
        XCTAssertEqual(DirectoryApply.rotation(s, env(f, 5), now: 3).reason, DirectoryEnvelope.unknownKey)
        XCTAssertEqual(DirectoryApply.snapshot(s, env(f, 4), now: 3).reason, DirectoryEnvelope.unknownKey)

        r = DirectoryApply.rotation(s, env(f, 2), now: 4)
        XCTAssertTrue(r.applied, r.reason)
        XCTAssertEqual(r.state.keyId, str(obj(obj(f, "keys"), "new"), "key_id"))
        XCTAssertEqual(r.state.pinSource, "rotation")
        XCTAssertEqual(r.state.keyVersion, 43)
        XCTAssertEqual(r.state.version, 42, "a rotation never moves the snapshot version")
        // Replayed under the new pin, the record is signed by a key the phone no longer trusts.
        XCTAssertEqual(DirectoryApply.rotation(r.state, env(f, 2), now: 5).reason, DirectoryEnvelope.unknownKey)
        r = DirectoryApply.snapshot(r.state, env(f, 3), now: 6)
        XCTAssertTrue(r.applied, r.reason)
        XCTAssertEqual(r.state.version, 44)
    }

    // MARK: the Hub's own answers

    func testTheHubsAnswerAppliesWithItsContactsGroupsAndAddresses() throws {
        let h = try hub()
        let r = DirectoryApply.answer(pinned(str(h, "old_key_pkix")), obj(h, "first"), now: 10)
        XCTAssertTrue(r.applied, r.reason)
        XCTAssertEqual(r.state.tenantId, "acme")
        XCTAssertEqual(r.state.version, (h["first_version"] as? NSNumber)?.int64Value)
        XCTAssertEqual(r.state.contacts.map(\.displayName), ["Kit A", "One", "Two"])
        let kitA = try XCTUnwrap(r.state.contacts.first { $0.id == "c3" })
        XCTAssertEqual(kitA.addresses.map { "\($0.kind) \($0.value)" }, ["MQTT bridge:kit-a", "TETRA tetra:1001"])
        XCTAssertEqual(kitA.role, "gateway")
        XCTAssertEqual(r.state.groups.map { "\($0.name) \($0.kind)" }, ["North team TEAM"])
        XCTAssertEqual(Set(r.state.groups.first?.memberIds ?? []), ["c1", "c3"])
        XCTAssertTrue(r.state.skipped.isEmpty)

        let again = DirectoryApply.answer(r.state, obj(h, "first"), now: 11)
        XCTAssertFalse(again.applied)
        XCTAssertEqual(again.reason, DirectoryApply.notNewer)
        XCTAssertEqual(again.state.contacts, r.state.contacts)
    }

    func testAfterARotationTheHubsChainLeadsThePhoneToTheNewKey() throws {
        let h = try hub()
        let held = DirectoryApply.answer(pinned(str(h, "old_key_pkix")), obj(h, "first"), now: 10).state
        let r = DirectoryApply.answer(held, obj(h, "after_rotation"), now: 20)
        XCTAssertTrue(r.applied, r.reason)
        XCTAssertEqual(r.state.keyId, str(h, "new_key_id"))
        XCTAssertEqual(r.state.pinSource, "rotation")
        XCTAssertGreaterThan(r.state.version, held.version)
        XCTAssertEqual(DirectoryApply.answer(r.state, obj(h, "first"), now: 21).reason, DirectoryEnvelope.unknownKey)
    }

    func testAnotherTenantsDirectoryIsRefused() throws {
        let h = try hub()
        let first = DirectoryApply.answer(pinned(str(h, "old_key_pkix")), obj(h, "first"), now: 9).state
        let held = DirectoryApply.answer(first, obj(h, "after_rotation"), now: 10).state
        XCTAssertEqual(held.keyId, str(h, "new_key_id"))
        let r = DirectoryApply.answer(held, obj(h, "other_tenant"), now: 11)
        XCTAssertFalse(r.applied)
        XCTAssertEqual(r.reason, DirectoryApply.otherTenant)
        XCTAssertEqual(r.state.tenantId, "acme")
        XCTAssertEqual(r.state.contacts, held.contacts)
        XCTAssertEqual(r.state.refusedAt, 11)
    }

    // MARK: the Bridge's rules

    func testRowsTheBridgeSkipsAreSkippedHereToo() throws {
        let key = P256.Signing.PrivateKey()
        let contacts = [
            contact("a", "Alpha", [("SMS", "+31600000001"), ("PIGEON", "loft 3"), ("MQTT", "")]),
            contact("b", "Bravo", [("SMS", "+31600000001"), ("TETRA", "2002")]),
            contact("n", ""),
        ]
        let groups: [[String: Any]] = [
            ["id": "g1", "name": "Ops", "kind": "team", "member_ids": ["a", "n", "zz"]],
            ["id": "g2", "name": "", "member_ids": ["b"]],
            ["id": "g3", "name": "X", "kind": "BROADCAST", "member_ids": [String]()],
        ]
        let r = DirectoryApply.snapshot(ownState(key), try seal(key, snap("t", 5, contacts: contacts, groups: groups)), now: 1)
        XCTAssertTrue(r.applied, r.reason)
        XCTAssertEqual(r.state.contacts.map(\.displayName), ["Alpha", "Bravo"])
        XCTAssertEqual(r.state.contacts[0].addresses.map(\.kind), ["SMS"])
        XCTAssertEqual(r.state.contacts[1].addresses.map(\.kind), ["TETRA"], "the second holder of an address goes without it")
        XCTAssertEqual(
            Set(r.state.skipped.map { "\($0.kind):\($0.id):\($0.reason)" }),
            [
                "address::unknown_kind", "address::address_taken", "contact:n:no_display_name", "member:g1/n:unknown_member",
                "member:g1/zz:unknown_member", "group:g3:unknown_kind",
            ])
        XCTAssertEqual(r.state.groups.map { "\($0.name) \($0.kind)" }, ["g2 LIST", "Ops TEAM"])
    }

    func testASnapshotNeedsATenantANewerVersionAndTheSnapshotType() throws {
        let key = P256.Signing.PrivateKey()
        let s = ownState(key)
        XCTAssertEqual(DirectoryApply.snapshot(s, try seal(key, snap("", 1)), now: 1).reason, DirectoryApply.otherTenant)
        let held = DirectoryApply.snapshot(s, try seal(key, snap("t", 7)), now: 1).state
        XCTAssertEqual(DirectoryApply.snapshot(held, try seal(key, snap("t", 7)), now: 2).reason, DirectoryApply.notNewer)
        var rot = snap("t", 8)
        rot["type"] = "rotation"
        XCTAssertEqual(DirectoryApply.snapshot(held, try seal(key, rot), now: 3).reason, DirectoryApply.notASnapshot)
        var untyped = snap("t", 8)
        untyped.removeValue(forKey: "type")
        XCTAssertTrue(DirectoryApply.snapshot(held, try seal(key, untyped), now: 4).applied, "no type is a snapshot, as on the Bridge")
    }

    func testARotationMustNameAP256KeyThatHashesToItsId() throws {
        let key = P256.Signing.PrivateKey()
        let s = ownState(key)
        let next = P256.Signing.PrivateKey().publicKey.derRepresentation
        XCTAssertEqual(
            DirectoryApply.rotation(s, try seal(key, rotationRecord("t", 2, next, id: String(repeating: "00", count: 32))), now: 1).reason,
            DirectoryEnvelope.unknownKey)
        let p384 = P384.Signing.PrivateKey().publicKey.derRepresentation
        XCTAssertEqual(DirectoryApply.rotation(s, try seal(key, rotationRecord("t", 2, p384)), now: 1).reason, DirectoryEnvelope.unknownKey)
        var wrongType = rotationRecord("t", 2, next)
        wrongType["type"] = "snapshot"
        XCTAssertEqual(DirectoryApply.rotation(s, try seal(key, wrongType), now: 1).reason, DirectoryApply.notARotation)
        let r = DirectoryApply.rotation(s, try seal(key, rotationRecord("t", 2, next)), now: 1)
        XCTAssertTrue(r.applied)
        XCTAssertEqual(r.state.keyId, DirectoryEnvelope.keyId(Array(next)))
    }

    func testAnAnswerStopsAtItsFirstRefusalAndKeepsWhatCameBefore() throws {
        let k1 = P256.Signing.PrivateKey()
        let k2 = P256.Signing.PrivateKey()
        let k3 = P256.Signing.PrivateKey()
        let answer: [String: Any] = [
            "rotations": [
                try seal(k1, rotationRecord("t", 2, k2.publicKey.derRepresentation)),
                // Signed by k1 again, but the pin is k2 by now.
                try seal(k1, rotationRecord("t", 3, k3.publicKey.derRepresentation)),
            ],
            "snapshot": try seal(k3, snap("t", 4)),
        ]
        let r = DirectoryApply.answer(ownState(k1), answer, now: 1)
        XCTAssertTrue(r.applied, "the first rotation stays applied")
        XCTAssertEqual(r.reason, DirectoryEnvelope.unknownKey)
        XCTAssertEqual(r.state.keyId, DirectoryEnvelope.keyId(Array(k2.publicKey.derRepresentation)))
        XCTAssertEqual(r.state.version, 0)
    }

    // MARK: the store

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hubdir-\(UUID().uuidString)").appendingPathComponent(
            "hub_directory.json")
    }

    func testTheStoreKeepsTheStateAcrossARestartAndSurvivesABrokenFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let h = try hub()
        let held = DirectoryApply.answer(pinned(str(h, "old_key_pkix")), obj(h, "first"), now: 10).state
        try HubDirectoryStore(url: url).save(held)
        XCTAssertEqual(HubDirectoryStore(url: url).current, held)
        // Android's file names.
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(raw["tenant_id"] as? String, "acme")
        XCTAssertNotNil(raw["pinned_key"] as? String)
        try Data("{ not json".utf8).write(to: url)
        XCTAssertEqual(HubDirectoryStore(url: url).current, DirectoryState())
    }

    func testTheStoreAnnouncesEverySavedState() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = HubDirectoryStore(url: url)
        var it = store.changes.subscribe().makeAsyncIterator()
        let first = await it.next()
        XCTAssertEqual(first, DirectoryState(), "the current state first")
        var next = DirectoryState()
        next.tenantId = "acme"
        try store.save(next)
        let second = await it.next()
        XCTAssertEqual(second?.tenantId, "acme")
        XCTAssertEqual(store.changes.value.tenantId, "acme")
    }

    // MARK: the client

    private func keyAnswer(_ pkixB64: String, id: String? = nil) -> HttpResponse {
        let body: [String: Any] = ["key_id": id ?? DirectoryEnvelope.keyId(b64(pkixB64)), "pkix": pkixB64, "alg": "ES256"]
        return HttpResponse(status: 200, body: Array((try? JSONSerialization.data(withJSONObject: body)) ?? Data()))
    }

    private func body(_ o: [String: Any]) -> HttpResponse {
        HttpResponse(status: 200, body: Array((try? JSONSerialization.data(withJSONObject: o)) ?? Data()))
    }

    func testPollPinsTheKeyOnceThenReadsTheDirectoryWithTheBridgeCredentials() async throws {
        let h = try hub()
        let store = HubDirectoryStore(url: tempURL())
        let http = FakeDirectoryHttp()
        let client = HubDirectoryClient(store: store, http: http, now: { 1000 })
        http.enqueue(keyAnswer(str(h, "old_key_pkix")))
        http.enqueue(body(obj(h, "first")))
        let o = await client.poll(hubApiBase: "https://hub.example", bridgeId: "phone-1", password: "phone-1-pw")
        guard case .applied = o else { return XCTFail("\(o)") }
        XCTAssertEqual(http.requests[0].url, "https://hub.example/api/relay/directory-key")
        XCTAssertNil(http.requests[0].headers["Authorization"], "the key is public: no credentials sent for it")
        XCTAssertEqual(http.requests[1].url, "https://hub.example/api/relay/directory?since=0&key_id=" + str(h, "old_key_id"))
        XCTAssertEqual(http.requests[1].headers["Authorization"], "Basic " + Data("phone-1:phone-1-pw".utf8).base64EncodedString())
        XCTAssertEqual(store.current.pinSource, "https")
        XCTAssertEqual(store.current.contacts.count, 3)

        http.enqueue(HttpResponse(status: 304))
        let o2 = await client.poll(hubApiBase: "https://hub.example", bridgeId: "phone-1", password: "phone-1-pw")
        XCTAssertEqual(o2, .notModified)
        XCTAssertEqual(store.current.checkedAt, 1000)
        XCTAssertEqual(http.count, 3, "no second key fetch")
        XCTAssertTrue(http.requests[2].url.hasSuffix("since=\(store.current.version)&key_id=" + str(h, "old_key_id")))
    }

    func testAPinnedKeyIsNeverReplacedByTheHttpsBootstrap() async throws {
        let store = HubDirectoryStore(url: tempURL())
        let http = FakeDirectoryHttp()
        let client = HubDirectoryClient(store: store, http: http)
        let bundleKey = Array(P256.Signing.PrivateKey().publicKey.derRepresentation)
        try client.applyProvisioning(context: "ctx", tenant: "acme", pkix: bundleKey)
        try await client.bootstrap(hubApiBase: "https://hub.example")
        XCTAssertEqual(http.count, 0, "nothing fetched")
        XCTAssertEqual(store.current.keyId, DirectoryEnvelope.keyId(bundleKey))
        XCTAssertEqual(store.current.pinSource, "bundle")
        http.enqueue(HttpResponse(status: 304))
        _ = await client.poll(hubApiBase: "https://hub.example", bridgeId: "p", password: "pw")
        XCTAssertTrue(http.requests[0].url.hasSuffix("key_id=" + DirectoryEnvelope.keyId(bundleKey)))
    }

    func testTheBootstrapRefusesARedirectABadKeyAndPlainHttp() async throws {
        let h = try hub()
        let store = HubDirectoryStore(url: tempURL())
        let http = FakeDirectoryHttp()
        let client = HubDirectoryClient(store: store, http: http)
        http.enqueue(HttpResponse(status: 302, headers: ["Location": "https://elsewhere.example/api/relay/directory-key"]))
        guard case .failed = await client.poll(hubApiBase: "https://hub.example", bridgeId: "p", password: "pw") else {
            return XCTFail("a redirect was taken")
        }
        http.enqueue(keyAnswer(str(h, "old_key_pkix"), id: String(repeating: "00", count: 32)))
        guard case .failed = await client.poll(hubApiBase: "https://hub.example", bridgeId: "p", password: "pw") else {
            return XCTFail("a key that does not hash to its id was taken")
        }
        XCTAssertEqual(store.current.pinnedKey, "")
        XCTAssertEqual(http.count, 2)
        let o = await client.poll(hubApiBase: "http://hub.example", bridgeId: "p", password: "pw")
        guard case .failed(let message) = o, message.contains("not an https URL") else { return XCTFail("\(o)") }
        XCTAssertEqual(http.count, 2, "no request over plain http")
    }

    func testTheProvisioningBundleCarriesTheDirectoryKeyAndTheTenant() throws {
        let h = try hub()
        let b = try ProvisionImporter.parseBundle(
            JSONSerialization.data(withJSONObject: ["bid": "phone-1", "dir_sign_pub": str(h, "old_key_pkix"), "tenant_id": "acme"]))
        XCTAssertEqual(DirectoryEnvelope.keyId(b64(b.dirSignPub)), str(h, "old_key_id"))
        XCTAssertEqual(b.tenantId, "acme")
        let old = try ProvisionImporter.parseBundle(Data(#"{"bid":"p"}"#.utf8))
        XCTAssertEqual([old.dirSignPub, old.tenantId], ["", ""])
    }

    // ---- the provisioning context (r40 review R40-R3) ----

    private let ctxA = HubDirectoryClient.provisioningContext(
        mqttUrl: "wss://mqtt-hub.example/mqtt", bridgeId: "phone-1", topicPrefix: "meshsat/acme", tenant: "acme")
    private let ctxB = HubDirectoryClient.provisioningContext(
        mqttUrl: "wss://mqtt-hub.example/mqtt", bridgeId: "phone-1", topicPrefix: "meshsat/other", tenant: "other")

    /// The review's probe: reprovisioned to another tenant on the same Hub, same key: the directory starts over.
    func testAReprovisionToAnotherTenantUnderTheSameKeyStartsOver() throws {
        let h = try hub()
        let store = HubDirectoryStore(url: tempURL())
        let c = HubDirectoryClient(store: store, http: FakeDirectoryHttp())
        try c.applyProvisioning(context: ctxA, tenant: "acme", pkix: b64(str(h, "old_key_pkix")))
        try store.update { DirectoryApply.answer($0, obj(h, "first"), now: 10).state }
        try store.update { DirectoryApply.answer($0, obj(h, "after_rotation"), now: 11).state }
        XCTAssertEqual(store.current.tenantId, "acme")
        XCTAssertEqual(store.current.contacts.count, 3)
        // The Hub's current key, the same for every tenant of it, in the new tenant's bundle.
        try c.applyProvisioning(context: ctxB, tenant: "other", pkix: b64(store.current.pinnedKey))
        XCTAssertEqual(store.current.tenantId, "")
        XCTAssertTrue(store.current.contacts.isEmpty, "the old tenant's contacts are gone")
        XCTAssertEqual([store.current.version, store.current.keyVersion], [0, 0])
        let r = DirectoryApply.answer(store.current, obj(h, "other_tenant"), now: 12)
        XCTAssertTrue(r.applied, r.reason)
        XCTAssertEqual(r.state.tenantId, "other")
        XCTAssertEqual(r.state.contacts.map(\.displayName), ["Nine"])
    }

    /// Tenant B's snapshot applies whether its version is below, equal to or above what A held.
    func testTheNewTenantsVersionMayBeLowerEqualOrHigher() throws {
        let key = P256.Signing.PrivateKey()
        let pkix = Array(key.publicKey.derRepresentation)
        for bVersion in [5, 10, 20] {
            let store = HubDirectoryStore(url: tempURL())
            let c = HubDirectoryClient(store: store, http: FakeDirectoryHttp())
            try c.applyProvisioning(context: ctxA, tenant: "acme", pkix: pkix)
            let a = try seal(key, snap("acme", 10, contacts: [contact("a1", "A one")]))
            try store.update { DirectoryApply.snapshot($0, a, now: 1).state }
            XCTAssertEqual(store.current.version, 10)
            try c.applyProvisioning(context: ctxB, tenant: "other", pkix: pkix)
            let b = try seal(key, snap("other", bVersion, contacts: [contact("b1", "B one")]))
            let r = DirectoryApply.snapshot(store.current, b, now: 2)
            XCTAssertTrue(r.applied, "B at \(bVersion): \(r.reason)")
            XCTAssertEqual(r.state.contacts.map(\.displayName), ["B one"])
        }
    }

    func testReScanningTheSameContextKeepsTheDirectory() throws {
        let h = try hub()
        let store = HubDirectoryStore(url: tempURL())
        let c = HubDirectoryClient(store: store, http: FakeDirectoryHttp())
        try c.applyProvisioning(context: ctxA, tenant: "acme", pkix: b64(str(h, "old_key_pkix")))
        try store.update { DirectoryApply.answer($0, obj(h, "first"), now: 10).state }
        let held = store.current
        try c.applyProvisioning(context: ctxA, tenant: "acme", pkix: b64(str(h, "old_key_pkix")))
        try c.applyProvisioning(context: ctxA, tenant: "acme", pkix: nil)
        XCTAssertEqual(store.current, held, "a bundle without a key keeps it in the same context")
        // Another key in the same context starts over under it.
        let other = Array(P256.Signing.PrivateKey().publicKey.derRepresentation)
        try c.applyProvisioning(context: ctxA, tenant: "acme", pkix: other)
        XCTAssertEqual(store.current.keyId, DirectoryEnvelope.keyId(other))
        XCTAssertEqual(store.current.version, 0)
        XCTAssertTrue(store.current.contacts.isEmpty)
        XCTAssertThrowsError(try c.applyProvisioning(context: ctxA, tenant: "acme", pkix: [UInt8](repeating: 1, count: 10)))
    }

    func testAnotherHubWithAnotherKeyAndNoKeyInTheBundle() async throws {
        let h = try hub()
        let store = HubDirectoryStore(url: tempURL())
        let http = FakeDirectoryHttp()
        let c = HubDirectoryClient(store: store, http: http)
        try c.applyProvisioning(context: ctxA, tenant: "acme", pkix: b64(str(h, "old_key_pkix")))
        try store.update { DirectoryApply.answer($0, obj(h, "first"), now: 10).state }
        let otherHub = HubDirectoryClient.provisioningContext(
            mqttUrl: "wss://mqtt-hub.elsewhere/mqtt", bridgeId: "phone-1", topicPrefix: "meshsat", tenant: "default")
        try c.applyProvisioning(context: otherHub, tenant: "default", pkix: nil)
        XCTAssertEqual(store.current.pinnedKey, "")
        XCTAssertTrue(store.current.contacts.isEmpty)
        // The bootstrap then fills the pin from the new Hub, once.
        http.enqueue(keyAnswer(str(h, "old_key_pkix")))
        try await c.bootstrap(hubApiBase: "https://hub.example")
        XCTAssertEqual(store.current.pinSource, "https")
    }

    /// A read that started before the reprovision cannot bring the old tenant back.
    func testAReplyFromBeforeTheSwitchIsDropped() async throws {
        let h = try hub()
        let store = HubDirectoryStore(url: tempURL())
        let http = FakeDirectoryHttp()
        let c = HubDirectoryClient(store: store, http: http)
        let key = b64(str(h, "old_key_pkix"))
        try c.applyProvisioning(context: ctxA, tenant: "acme", pkix: key)
        http.enqueue(body(obj(h, "first")))
        let ctxB = self.ctxB
        // The phone is reprovisioned while the read is out.
        http.beforeAnswer = { _ = try? c.applyProvisioning(context: ctxB, tenant: "other", pkix: key) }
        let o = await c.poll(hubApiBase: "https://hub.example", bridgeId: "phone-1", password: "pw")
        guard case .failed = o else { return XCTFail("\(o)") }
        XCTAssertEqual(store.current.context, ctxB)
        XCTAssertTrue(store.current.contacts.isEmpty)
        XCTAssertEqual(store.current.tenantId, "")
    }

    /// A bootstrap that started before the reprovision does not pin the old Hub's key.
    func testABootstrapFromBeforeTheSwitchPinsNothing() async throws {
        let h = try hub()
        let store = HubDirectoryStore(url: tempURL())
        let http = FakeDirectoryHttp()
        let c = HubDirectoryClient(store: store, http: http)
        try c.applyProvisioning(context: ctxA, tenant: "acme", pkix: nil)
        http.enqueue(keyAnswer(str(h, "old_key_pkix")))
        let ctxB = self.ctxB
        http.beforeAnswer = { _ = try? c.applyProvisioning(context: ctxB, tenant: "other", pkix: nil) }
        let o = await c.poll(hubApiBase: "https://hub.example", bridgeId: "phone-1", password: "pw")
        guard case .failed = o else { return XCTFail("\(o)") }
        XCTAssertEqual(store.current.pinnedKey, "")
        XCTAssertEqual(http.count, 1, "no directory read without a pinned key")
    }

    func testTheContextSurvivesARestartAndAnOldFileStillLoads() throws {
        let h = try hub()
        let url = tempURL()
        try HubDirectoryClient(store: HubDirectoryStore(url: url), http: FakeDirectoryHttp())
            .applyProvisioning(context: ctxB, tenant: "other", pkix: b64(str(h, "old_key_pkix")))
        let again = HubDirectoryStore(url: url).current
        XCTAssertEqual([again.context, again.expectedTenant], [ctxB, "other"])
        // A file from before R40-R3 has neither field: it loads with its pin kept.
        let old = #"{"pinned_key":"\#(str(h, "old_key_pkix"))","pin_source":"bundle","tenant_id":"acme","version":4}"#
        try Data(old.utf8).write(to: url)
        let loaded = HubDirectoryStore(url: url).current
        XCTAssertEqual(loaded.pinnedKey, str(h, "old_key_pkix"))
        XCTAssertEqual([loaded.context, loaded.expectedTenant, loaded.tenantId], ["", "", "acme"])
        XCTAssertEqual(loaded.version, 4)
    }

    /// The bundle's tenant binds the directory from the first snapshot on.
    func testASnapshotOfAnotherTenantIsRefusedFromTheFirstOne() throws {
        let key = P256.Signing.PrivateKey()
        let store = HubDirectoryStore(url: tempURL())
        try HubDirectoryClient(store: store, http: FakeDirectoryHttp())
            .applyProvisioning(context: ctxA, tenant: "acme", pkix: Array(key.publicKey.derRepresentation))
        XCTAssertEqual(DirectoryApply.snapshot(store.current, try seal(key, snap("other", 1)), now: 1).reason, DirectoryApply.otherTenant)
        XCTAssertTrue(DirectoryApply.snapshot(store.current, try seal(key, snap("acme", 1)), now: 1).applied)
    }
}
