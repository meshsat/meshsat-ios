// Mirrors HubDirectoryRestFixtureTest.kt: fixtures-v1.2's directory_v2_rest.json (r40 review,
// decision 1), envelopes the Hub's own store, signer and rotation made, in the REST shapes. The
// phone, bound to the fixture's tenant by its provisioning, ends each case holding the contacts
// (names and addresses), groups (memberships), versions and key the fixture names, refuses what it
// refuses with its state unchanged, and skips the rows it skips by kind, id and reason. The same
// file runs through the Bridge and Android.
import Foundation
import XCTest

@testable import MeshSatHub

final class HubDirectoryRestFixtureTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "directory_v2_rest", withExtension: "json", subdirectory: "Fixtures/hemb-ng/v1"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func cases(_ fx: [String: Any], _ list: String) -> [[String: Any]] { fx[list] as? [[String: Any]] ?? [] }
    private func key(_ fx: [String: Any], _ name: String) -> String {
        ((fx["keys"] as? [String: Any])?[name] as? [String: Any])?["pkix_b64"] as? String ?? ""
    }
    private func expect(_ c: [String: Any]) -> [String: Any] { c["expect"] as? [String: Any] ?? [:] }

    private func bound(_ fx: [String: Any], _ keyName: String) -> DirectoryState {
        var s = DirectoryState()
        s.pinnedKey = key(fx, keyName)
        s.pinSource = "bundle"
        s.context = "fixture"
        s.expectedTenant = fx["tenant"] as? String ?? ""
        return s
    }

    private func apply(_ s: DirectoryState, _ c: [String: Any], now: Int64) -> DirectoryApply.Result {
        let env = c["envelope"] as? [String: Any] ?? [:]
        return c["kind"] as? String == "rotation" ? DirectoryApply.rotation(s, env, now: now) : DirectoryApply.snapshot(s, env, now: now)
    }

    private func contacts(_ s: DirectoryState) -> [String] {
        s.contacts.map { c in "\(c.id) \"\(c.displayName)\" \(c.addresses.map { "\($0.kind) \($0.value)" }.sorted())" }.sorted()
    }
    private func groups(_ s: DirectoryState) -> [String] {
        s.groups.map { g in "\(g.id) \"\(g.name)\" \(g.kind) \(g.memberIds.sorted())" }.sorted()
    }
    private func contacts(_ e: [String: Any]) -> [String] {
        (e["contacts"] as? [[String: Any]] ?? []).map { c in
            let addrs = (c["addresses"] as? [[String: Any]] ?? []).map { "\($0["kind"] as? String ?? "") \($0["value"] as? String ?? "")" }
            return "\(c["id"] as? String ?? "") \"\(c["display_name"] as? String ?? "")\" \(addrs.sorted())"
        }.sorted()
    }
    private func groups(_ e: [String: Any]) -> [String] {
        (e["groups"] as? [[String: Any]] ?? []).map { g in
            let ids = (g["member_ids"] as? [String] ?? []).sorted()
            return "\(g["id"] as? String ?? "") \"\(g["name"] as? String ?? "")\" \(g["kind"] as? String ?? "") \(ids)"
        }.sorted()
    }
    private func skips(_ e: [String: Any]) -> [String] {
        (e["skipped"] as? [[String: Any]] ?? []).map { s in
            ["kind", "id", "reason"].map { s[$0] as? String ?? "" }.joined(separator: " ")
        }.sorted()
    }

    private func holds(_ name: String, _ fx: [String: Any], _ s: DirectoryState, _ e: [String: Any]) {
        XCTAssertEqual(s.version, (e["version"] as? NSNumber)?.int64Value, "\(name): version")
        XCTAssertEqual(s.keyVersion, (e["key_version"] as? NSNumber)?.int64Value, "\(name): key version")
        XCTAssertEqual(s.pinnedKey, key(fx, e["pinned"] as? String ?? ""), "\(name): pinned key")
        XCTAssertEqual(contacts(s), contacts(e), "\(name): contacts")
        XCTAssertEqual(groups(s), groups(e), "\(name): groups")
    }

    func testTheSequenceEndsEachStepWithTheHubsNamesAddressesAndMemberships() throws {
        let fx = try fixture()
        var s = bound(fx, "old")
        for (i, c) in cases(fx, "sequence").enumerated() {
            let name = c["name"] as? String ?? ""
            let r = apply(s, c, now: 10 + Int64(i))
            XCTAssertTrue(r.applied, "\(name): \(r.reason) \(r.detail)")
            s = r.state
            holds(name, fx, s, expect(c))
        }
        XCTAssertEqual(s.tenantId, fx["tenant"] as? String)
    }

    func testWhatThePhoneRefusesLeavesItAsItWas() throws {
        let fx = try fixture()
        var s = bound(fx, "old")
        for (i, c) in cases(fx, "sequence").enumerated() { s = apply(s, c, now: 10 + Int64(i)).state }
        let last = expect(try XCTUnwrap(cases(fx, "sequence").last))
        for c in cases(fx, "refused") {
            let name = c["name"] as? String ?? ""
            let r = apply(s, c, now: 99)
            XCTAssertFalse(r.applied, "\(name) was applied")
            if c["verify"] as? Bool == true { XCTAssertEqual(r.reason, expect(c)["reason"] as? String, name) }
            holds(name, fx, r.state, last)
        }
    }

    func testRowsAReceiverSkipsAreSkippedByKindIdAndReasonAndTheRestIsHeld() throws {
        let fx = try fixture()
        for c in cases(fx, "rows") {
            let name = c["name"] as? String ?? ""
            let r = apply(bound(fx, c["trusted_key"] as? String ?? ""), c, now: 1)
            XCTAssertTrue(r.applied, "\(name): \(r.reason) \(r.detail)")
            XCTAssertEqual(r.state.skipped.map { "\($0.kind) \($0.id) \($0.reason)" }.sorted(), skips(expect(c)), name)
            holds(name, fx, r.state, expect(c))
        }
    }

    func testTheFixtureHasEveryCase() throws {
        let fx = try fixture()
        XCTAssertEqual(["sequence", "refused", "rows"].map { cases(fx, $0).count }, [3, 5, 5])
    }
}
