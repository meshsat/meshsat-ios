// ConfigManager has no Android unit test; these pin export in both formats, validate, import
// (replace everything, then the evaluator's reload), diff, and the flat YAML reader.
import XCTest

@testable import MeshSatEngine

final class ConfigManagerTests: XCTestCase {
    private final class FakeStores: ConfigRuleStore, ConfigObjectGroupStore, ConfigFailoverStore, @unchecked Sendable {
        private let lock = NSLock()
        private var rules: [AccessRule] = []
        private var groups: [ObjectGroup] = []
        private var fgroups: [FailoverGroup] = []
        private var members: [FailoverMember] = []
        private var nextId: Int64 = 1
        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
        func getAllSync() async throws -> [AccessRule] { locked { rules } }
        func insert(_ rule: AccessRule) async throws -> Int64 {
            locked {
                var r = rule
                r.id = nextId
                nextId += 1
                rules.append(r)
                return r.id ?? 0
            }
        }
        func deleteAll() async throws { locked { rules.removeAll() } }
        func getAll() async throws -> [ObjectGroup] { locked { groups } }
        func upsert(_ group: ObjectGroup) async throws {
            locked {
                groups.removeAll { $0.id == group.id }
                groups.append(group)
            }
        }
        func deleteAllGroupsObjects() {}
        func getAllGroups() async throws -> [FailoverGroup] { locked { fgroups } }
        func upsertGroup(_ group: FailoverGroup) async throws {
            locked {
                fgroups.removeAll { $0.id == group.id }
                fgroups.append(group)
            }
        }
        func getMembers(_ groupId: String) async throws -> [FailoverMember] { locked { members.filter { $0.groupId == groupId } } }
        func upsertMember(_ member: FailoverMember) async throws { locked { members.append(member) } }
        func deleteAllMembersGlobal() async throws { locked { members.removeAll() } }
        func deleteAllGroups() async throws { locked { fgroups.removeAll() } }
        var objectGroupCount: Int { locked { groups.count } }
    }

    /// The object-group store's deleteAll is the rule store's name too; a wrapper keeps them apart.
    /// The object-group store's deleteAll is the rule store's name too; a wrapper keeps them apart.
    private final class GroupStore: ConfigObjectGroupStore, @unchecked Sendable {
        let stores: FakeStores
        private let lock = NSLock()
        private var groups: [ObjectGroup] = []
        init(_ stores: FakeStores) { self.stores = stores }
        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
        func getAll() async throws -> [ObjectGroup] { locked { groups } }
        func upsert(_ group: ObjectGroup) async throws {
            locked {
                groups.removeAll { $0.id == group.id }
                groups.append(group)
            }
        }
        func deleteAll() async throws { locked { groups.removeAll() } }
    }

    private func manager(_ stores: FakeStores, groups: GroupStore, imported: AprsReceived<Int>? = nil) -> ConfigManager {
        ConfigManager(
            rules: stores, groups: groups, failover: stores, onImported: { imported?.add(1) },
            now: { Date(timeIntervalSince1970: 1_790_331_630) })
    }

    private let sample = """
        {
          "version": "0.4.0",
          "exported_at": "2026-09-25T10:20:30Z",
          "access_rules": [
            {
              "interface_id": "mesh_0",
              "direction": "in",
              "priority": 5,
              "name": "mesh to sat",
              "enabled": true,
              "action": "forward",
              "forward_to": "iridium_0",
              "filters": "{}",
              "filter_sender_group": "team",
              "forward_options": "{}",
              "qos_level": 1,
              "rate_limit_per_min": 3,
              "rate_limit_window": 60
            }
          ],
          "object_groups": [
            {
              "id": "team",
              "type": "sender",
              "label": "Team",
              "members": "[\\"!aabbccdd\\"]"
            }
          ],
          "failover_groups": [
            {
              "id": "uplink",
              "label": "Uplink",
              "mode": "failover",
              "members": [
                {
                  "interface_id": "hub_0",
                  "priority": 0
                },
                {
                  "interface_id": "iridium_0",
                  "priority": 1
                }
              ]
            }
          ]
        }
        """

    func testValidate() {
        let m = manager(FakeStores(), groups: GroupStore(FakeStores()))
        XCTAssertNil(m.validate(sample))
        XCTAssertEqual(m.validate("nope"), "invalid JSON")
        XCTAssertEqual(m.validate("{}"), "missing version field")
        XCTAssertEqual(m.validate("{\"version\":\"1\",\"access_rules\":[{\"name\":\"x\"}]}"), "access rule at index 0 missing interface_id")
        XCTAssertEqual(m.validate("{\"version\":\"1\",\"failover_groups\":[{\"label\":\"x\"}]}"), "failover group at index 0 missing id")
    }

    func testImportReplacesEverythingAndExportsItBack() async throws {
        let stores = FakeStores()
        let groups = GroupStore(stores)
        let imported = AprsReceived<Int>()
        let m = manager(stores, groups: groups, imported: imported)
        try await stores.insert(AccessRule(interfaceId: "old_0", direction: "in", name: "old"))
        try await groups.upsert(ObjectGroup(id: "old", type: "node", label: "Old"))
        let counts = try await m.importJson(sample)
        XCTAssertEqual(counts, ["object_groups": 1, "access_rules": 1, "failover_groups": 1])
        XCTAssertEqual(imported.all.count, 1)
        let rules = try await stores.getAllSync()
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].name, "mesh to sat")
        XCTAssertEqual(rules[0].filterSenderGroup, "team")
        XCTAssertNil(rules[0].filterNodeGroup)
        XCTAssertEqual(rules[0].rateLimitWindow, 60)
        let groupIds = try await groups.getAll().map(\.id)
        XCTAssertEqual(groupIds, ["team"])
        let memberIds = try await stores.getMembers("uplink").map(\.interfaceId)
        XCTAssertEqual(memberIds, ["hub_0", "iridium_0"])
        // The export is the document again, byte for byte.
        let exported = try await m.export()
        XCTAssertEqual(exported, sample)
        // Defaults fill what a document leaves out.
        try await m.importJson("{\"version\":\"0.4.0\",\"access_rules\":[{\"interface_id\":\"a\",\"direction\":\"in\",\"name\":\"n\"}]}")
        let r = try await stores.getAllSync()[0]
        XCTAssertEqual(r.priority, 10)
        XCTAssertEqual(r.action, "forward")
        XCTAssertEqual(r.qosLevel, 1)
        XCTAssertTrue(r.enabled)
        let remaining = try await groups.getAll().count
        XCTAssertEqual(remaining, 0)
        do {
            try await m.importJson("{}")
            XCTFail("invalid")
        } catch {
            XCTAssertEqual(error as? ConfigError, ConfigError("missing version field"))
        }
    }

    func testDiff() async throws {
        let stores = FakeStores()
        let groups = GroupStore(stores)
        let m = manager(stores, groups: groups)
        try await stores.insert(AccessRule(interfaceId: "mesh_0", direction: "in", name: "mesh to sat"))
        try await stores.insert(AccessRule(interfaceId: "sms_0", direction: "in", name: "gone"))
        try await groups.upsert(ObjectGroup(id: "team", type: "sender", label: "Team"))
        let d = try await m.diff(sample)
        XCTAssertEqual(d.accessRules, DiffCounts(add: 0, remove: 1, change: 1))
        XCTAssertEqual(d.objectGroups, DiffCounts(add: 0, remove: 0, change: 1))
        XCTAssertEqual(d.failoverGroups, DiffCounts(add: 1, remove: 0, change: 0))
    }

    func testYamlExportAndImportRoundTrip() async throws {
        let stores = FakeStores()
        let groups = GroupStore(stores)
        let m = manager(stores, groups: groups)
        try await m.importJson(sample)
        let yaml = try await m.exportYaml()
        XCTAssertEqual(
            yaml,
            """
            version: "0.4.0"
            exported_at: "2026-09-25T10:20:30Z"
            access_rules:
              - interface_id: "mesh_0"
                direction: "in"
                priority: 5
                name: "mesh to sat"
                enabled: true
                action: "forward"
                forward_to: "iridium_0"
                filters: "{}"
                filter_sender_group: "team"
                forward_options: "{}"
                qos_level: 1
                rate_limit_per_min: 3
                rate_limit_window: 60
            object_groups:
              - id: "team"
                type: "sender"
                label: "Team"
                members: "[\\"!aabbccdd\\"]"
            failover_groups:
              - id: "uplink"
                label: "Uplink"
                mode: "failover"
                members:
                  - interface_id: "hub_0"
                    priority: 0
                  - interface_id: "iridium_0"
                    priority: 1

            """)
        // Back in through the YAML reader: the same JSON as the original document.
        let stores2 = FakeStores()
        let groups2 = GroupStore(stores2)
        let m2 = manager(stores2, groups: groups2)
        let counts = try await m2.importAuto(yaml)
        XCTAssertEqual(counts, ["object_groups": 1, "access_rules": 1, "failover_groups": 1])
        let exported2 = try await m2.export()
        XCTAssertEqual(exported2, sample)
        let jsonCounts = try await m2.importAuto(sample)
        XCTAssertEqual(jsonCounts["access_rules"], 1)
    }

    func testYamlReaderEdgeCases() {
        let json = ConfigManager.yamlToJson(
            """
            # a comment
            version: "0.4.0"
            access_rules:
              []
            object_groups:
              []
            failover_groups:
              - id: "solo"
                label: "Solo"
                mode: "failover"
                members:
                  []
            """)
        let expected = [
            "{", "  \"version\": \"0.4.0\",", "  \"access_rules\": [],", "  \"object_groups\": [],", "  \"failover_groups\": [", "    {",
            "      \"id\": \"solo\",", "      \"label\": \"Solo\",", "      \"mode\": \"failover\",", "      \"members\": []", "    }",
            "  ]", "}",
        ].joined(separator: "\n")
        XCTAssertEqual(json, expected)
        XCTAssertEqual(ConfigManager.yamlParseValue("\"a \\\"q\\\" b\""), .string("a \"q\" b"))
        XCTAssertEqual(ConfigManager.yamlParseValue("42"), .int(42))
        XCTAssertEqual(ConfigManager.yamlParseValue("true"), .bool(true))
        XCTAssertEqual(ConfigManager.yamlEsc("a\\b\"c"), "a\\\\b\\\"c")
    }
}
