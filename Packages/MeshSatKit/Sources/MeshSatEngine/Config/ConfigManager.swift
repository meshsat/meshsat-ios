// Mirrors config/ConfigManager.kt (a port of the Bridge's internal/api/config_export.go,
// Cisco's "show running-config"): the access rules, object groups and failover groups as one
// JSON or YAML document, validated, diffed and imported as a whole. The stores are protocols
// so the Kit tests run on fakes; the app's DAOs conform.
import Foundation

public protocol ConfigRuleStore: Sendable {
    func getAllSync() async throws -> [AccessRule]
    @discardableResult func insert(_ rule: AccessRule) async throws -> Int64
    func deleteAll() async throws
}

public protocol ConfigObjectGroupStore: Sendable {
    func getAll() async throws -> [ObjectGroup]
    func upsert(_ group: ObjectGroup) async throws
    func deleteAll() async throws
}

public protocol ConfigFailoverStore: Sendable {
    func getAllGroups() async throws -> [FailoverGroup]
    func upsertGroup(_ group: FailoverGroup) async throws
    func getMembers(_ groupId: String) async throws -> [FailoverMember]
    func upsertMember(_ member: FailoverMember) async throws
    func deleteAllMembersGlobal() async throws
    func deleteAllGroups() async throws
}

public struct ConfigError: Error, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public struct DiffCounts: Sendable, Equatable {
    public var add = 0
    public var remove = 0
    public var change = 0
    public init(add: Int = 0, remove: Int = 0, change: Int = 0) {
        self.add = add
        self.remove = remove
        self.change = change
    }
}

public struct DiffResult: Sendable, Equatable {
    public var accessRules = DiffCounts()
    public var objectGroups = DiffCounts()
    public var failoverGroups = DiffCounts()
    public init(accessRules: DiffCounts = DiffCounts(), objectGroups: DiffCounts = DiffCounts(), failoverGroups: DiffCounts = DiffCounts())
    {
        self.accessRules = accessRules
        self.objectGroups = objectGroups
        self.failoverGroups = failoverGroups
    }
}

public final class ConfigManager: Sendable {
    public static let configVersion = "0.4.0"

    private let rules: any ConfigRuleStore
    private let groups: any ConfigObjectGroupStore
    private let failover: any ConfigFailoverStore
    /// Told when an import replaced the rules, so the evaluator reads them again (MESHSAT-1274).
    private let onImported: (@Sendable () async -> Void)?
    private let now: @Sendable () -> Date

    public init(
        rules: any ConfigRuleStore, groups: any ConfigObjectGroupStore, failover: any ConfigFailoverStore,
        onImported: (@Sendable () async -> Void)? = nil, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rules = rules
        self.groups = groups
        self.failover = failover
        self.onImported = onImported
        self.now = now
    }

    // MARK: Export

    /// The configuration as JSON, indented by two, keys in the Bridge's order.
    public func export() async throws -> String {
        let doc = try await document()
        return JSONText.render(doc, indent: 2)
    }

    /// The configuration as YAML in the Bridge's layout.
    public func exportYaml() async throws -> String {
        let ruleList = try await rules.getAllSync()
        let groupList = try await groups.getAll()
        let fgroups = try await failover.getAllGroups()
        var out = ""
        out += "version: \"\(Self.configVersion)\"\n"
        out += "exported_at: \"\(utcNow())\"\n"
        out += "access_rules:\n"
        if ruleList.isEmpty { out += "  []\n" }
        for r in ruleList {
            out += "  - interface_id: \"\(Self.yamlEsc(r.interfaceId))\"\n"
            out += "    direction: \"\(Self.yamlEsc(r.direction))\"\n"
            out += "    priority: \(r.priority)\n"
            out += "    name: \"\(Self.yamlEsc(r.name))\"\n"
            out += "    enabled: \(r.enabled)\n"
            out += "    action: \"\(Self.yamlEsc(r.action))\"\n"
            out += "    forward_to: \"\(Self.yamlEsc(r.forwardTo))\"\n"
            out += "    filters: \"\(Self.yamlEsc(r.filters))\"\n"
            if let g = r.filterNodeGroup { out += "    filter_node_group: \"\(Self.yamlEsc(g))\"\n" }
            if let g = r.filterSenderGroup { out += "    filter_sender_group: \"\(Self.yamlEsc(g))\"\n" }
            if let g = r.filterPortnumGroup { out += "    filter_portnum_group: \"\(Self.yamlEsc(g))\"\n" }
            out += "    forward_options: \"\(Self.yamlEsc(r.forwardOptions))\"\n"
            out += "    qos_level: \(r.qosLevel)\n"
            out += "    rate_limit_per_min: \(r.rateLimitPerMin)\n"
            out += "    rate_limit_window: \(r.rateLimitWindow)\n"
        }
        out += "object_groups:\n"
        if groupList.isEmpty { out += "  []\n" }
        for g in groupList {
            out += "  - id: \"\(Self.yamlEsc(g.id))\"\n"
            out += "    type: \"\(Self.yamlEsc(g.type))\"\n"
            out += "    label: \"\(Self.yamlEsc(g.label))\"\n"
            out += "    members: \"\(Self.yamlEsc(g.members))\"\n"
        }
        out += "failover_groups:\n"
        if fgroups.isEmpty { out += "  []\n" }
        for fg in fgroups {
            out += "  - id: \"\(Self.yamlEsc(fg.id))\"\n"
            out += "    label: \"\(Self.yamlEsc(fg.label))\"\n"
            out += "    mode: \"\(Self.yamlEsc(fg.mode))\"\n"
            let members = try await failover.getMembers(fg.id)
            out += "    members:\n"
            if members.isEmpty { out += "      []\n" }
            for m in members {
                out += "      - interface_id: \"\(Self.yamlEsc(m.interfaceId))\"\n"
                out += "        priority: \(m.priority)\n"
            }
        }
        return out
    }

    private func document() async throws -> JSONText.Node {
        let ruleList = try await rules.getAllSync()
        let groupList = try await groups.getAll()
        let fgroups = try await failover.getAllGroups()
        var rulesArr: [JSONText.Node] = []
        for r in ruleList {
            var fields: [(String, JSONText.Node)] = [
                ("interface_id", .string(r.interfaceId)), ("direction", .string(r.direction)), ("priority", .int(r.priority)),
                ("name", .string(r.name)), ("enabled", .bool(r.enabled)), ("action", .string(r.action)),
                ("forward_to", .string(r.forwardTo)),
                ("filters", .string(r.filters)),
            ]
            if let g = r.filterNodeGroup { fields.append(("filter_node_group", .string(g))) }
            if let g = r.filterSenderGroup { fields.append(("filter_sender_group", .string(g))) }
            if let g = r.filterPortnumGroup { fields.append(("filter_portnum_group", .string(g))) }
            fields += [
                ("forward_options", .string(r.forwardOptions)), ("qos_level", .int(r.qosLevel)),
                ("rate_limit_per_min", .int(r.rateLimitPerMin)),
                ("rate_limit_window", .int(r.rateLimitWindow)),
            ]
            rulesArr.append(.object(fields))
        }
        let groupsArr: [JSONText.Node] = groupList.map {
            .object([("id", .string($0.id)), ("type", .string($0.type)), ("label", .string($0.label)), ("members", .string($0.members))])
        }
        var fgroupsArr: [JSONText.Node] = []
        for fg in fgroups {
            let members = try await failover.getMembers(fg.id)
            fgroupsArr.append(
                .object([
                    ("id", .string(fg.id)), ("label", .string(fg.label)), ("mode", .string(fg.mode)),
                    (
                        "members",
                        .array(members.map { .object([("interface_id", .string($0.interfaceId)), ("priority", .int($0.priority))]) })
                    ),
                ]))
        }
        return .object([
            ("version", .string(Self.configVersion)), ("exported_at", .string(utcNow())), ("access_rules", .array(rulesArr)),
            ("object_groups", .array(groupsArr)), ("failover_groups", .array(fgroupsArr)),
        ])
    }

    // MARK: Validate, import, diff

    /// Nil when the document is usable, else what is wrong.
    public func validate(_ json: String) -> String? {
        guard let root = Self.parse(json) else { return "invalid JSON" }
        guard root["version"] != nil else { return "missing version field" }
        for (i, r) in Self.objects(root["access_rules"]).enumerated()
        where (r["interface_id"] as? String ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return "access rule at index \(i) missing interface_id"
        }
        for (i, fg) in Self.objects(root["failover_groups"]).enumerated()
        where (fg["id"] as? String ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return "failover group at index \(i) missing id"
        }
        return nil
    }

    /// Replaces the whole configuration with the JSON document; the counts imported.
    @discardableResult
    public func importJson(_ json: String) async throws -> [String: Int] {
        if let error = validate(json) { throw ConfigError(error) }
        guard let root = Self.parse(json) else { throw ConfigError("invalid JSON") }
        try await failover.deleteAllMembersGlobal()
        try await failover.deleteAllGroups()
        try await rules.deleteAll()
        try await groups.deleteAll()
        var counts: [String: Int] = [:]
        let groupObjs = Self.objects(root["object_groups"])
        for g in groupObjs {
            try await groups.upsert(
                ObjectGroup(
                    id: Self.str(g["id"]), type: Self.str(g["type"]), label: Self.str(g["label"]), members: Self.str(g["members"], "[]")))
        }
        counts["object_groups"] = groupObjs.count
        let ruleObjs = Self.objects(root["access_rules"])
        for r in ruleObjs {
            try await rules.insert(
                AccessRule(
                    interfaceId: Self.str(r["interface_id"]), direction: Self.str(r["direction"]), priority: Self.int(r["priority"], 10),
                    name: Self.str(r["name"]), enabled: Self.bool(r["enabled"], true), action: Self.str(r["action"], "forward"),
                    forwardTo: Self.str(r["forward_to"]), filters: Self.str(r["filters"], "{}"),
                    filterNodeGroup: r["filter_node_group"] as? String,
                    filterSenderGroup: r["filter_sender_group"] as? String, filterPortnumGroup: r["filter_portnum_group"] as? String,
                    forwardOptions: Self.str(r["forward_options"], "{}"), qosLevel: Self.int(r["qos_level"], 1),
                    rateLimitPerMin: Self.int(r["rate_limit_per_min"], 0), rateLimitWindow: Self.int(r["rate_limit_window"], 0)))
        }
        counts["access_rules"] = ruleObjs.count
        let fgObjs = Self.objects(root["failover_groups"])
        for fg in fgObjs {
            let id = Self.str(fg["id"])
            try await failover.upsertGroup(FailoverGroup(id: id, label: Self.str(fg["label"]), mode: Self.str(fg["mode"], "failover")))
            for m in Self.objects(fg["members"]) {
                try await failover.upsertMember(
                    FailoverMember(groupId: id, interfaceId: Self.str(m["interface_id"]), priority: Self.int(m["priority"], 0)))
            }
        }
        counts["failover_groups"] = fgObjs.count
        await onImported?()
        return counts
    }

    /// JSON or YAML, told apart by the first character.
    @discardableResult
    public func importAuto(_ input: String) async throws -> [String: Int] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") ? try await importJson(trimmed) : try await importYaml(trimmed)
    }

    @discardableResult
    public func importYaml(_ yaml: String) async throws -> [String: Int] {
        try await importJson(Self.yamlToJson(yaml))
    }

    /// What an import would add, remove and change, by name or id.
    public func diff(_ json: String) async throws -> DiffResult {
        if let error = validate(json) { throw ConfigError(error) }
        guard let root = Self.parse(json) else { throw ConfigError("invalid JSON") }
        let currentRules = Set(try await rules.getAllSync().map(\.name))
        let currentGroups = Set(try await groups.getAll().map(\.id))
        let currentFGroups = Set(try await failover.getAllGroups().map(\.id))
        let incomingRules = Set(Self.objects(root["access_rules"]).map { Self.str($0["name"]) })
        let incomingGroups = Set(Self.objects(root["object_groups"]).map { Self.str($0["id"]) })
        let incomingFGroups = Set(Self.objects(root["failover_groups"]).map { Self.str($0["id"]) })
        return DiffResult(
            accessRules: Self.diffSets(currentRules, incomingRules), objectGroups: Self.diffSets(currentGroups, incomingGroups),
            failoverGroups: Self.diffSets(currentFGroups, incomingFGroups))
    }

    static func diffSets(_ current: Set<String>, _ incoming: Set<String>) -> DiffCounts {
        DiffCounts(
            add: incoming.filter { !current.contains($0) }.count, remove: current.filter { !incoming.contains($0) }.count,
            change: incoming.filter { current.contains($0) }.count)
    }

    // MARK: YAML in (the flat config format only, as Android converts it)

    /// The Bridge's flat YAML as JSON: top-level scalars, three arrays of flat objects, and
    /// a nested `members:` list under a failover group.
    public static func yamlToJson(_ yaml: String) -> String {
        var root: [(String, JSONText.Node)] = []
        var arrays: [String: [JSONText.Node]] = [:]
        var arrayOrder: [String] = []
        var currentArrayName: String?
        var currentObj: [(String, JSONText.Node)]?
        var currentMembers: [[(String, JSONText.Node)]]?

        func flush() {
            guard var obj = currentObj, let name = currentArrayName else { return }
            if let members = currentMembers { obj.append(("members", .array(members.map { .object($0) }))) }
            arrays[name, default: []].append(.object(obj))
            currentObj = nil
            currentMembers = nil
        }
        func put(_ target: inout [(String, JSONText.Node)], _ k: String, _ v: JSONText.Node) {
            if let i = target.firstIndex(where: { $0.0 == k }) { target[i] = (k, v) } else { target.append((k, v)) }
        }

        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent == 0, trimmed.hasSuffix(":") {
                flush()
                let name = String(trimmed.dropLast())
                currentArrayName = name
                if arrays[name] == nil {
                    arrays[name] = []
                    arrayOrder.append(name)
                }
            } else if indent == 0, let (k, v) = splitKeyValue(trimmed) {
                put(&root, k, yamlParseValue(v))
            } else if trimmed == "members:" {
                currentMembers = []
            } else if trimmed == "[]" {
                continue
            } else if trimmed.hasPrefix("- "), let members = currentMembers, indent >= 6 {
                var member: [(String, JSONText.Node)] = []
                if let (k, v) = splitKeyValue(String(trimmed.dropFirst(2))) { put(&member, k, yamlParseValue(v)) }
                currentMembers = members + [member]
            } else if trimmed.hasPrefix("- ") {
                flush()
                currentObj = []
                if let (k, v) = splitKeyValue(String(trimmed.dropFirst(2))) { put(&currentObj!, k, yamlParseValue(v)) }
            } else if let (k, v) = splitKeyValue(trimmed) {
                if var members = currentMembers, !members.isEmpty, indent >= 8 {
                    put(&members[members.count - 1], k, yamlParseValue(v))
                    currentMembers = members
                } else if currentObj != nil {
                    put(&currentObj!, k, yamlParseValue(v))
                }
            }
        }
        flush()
        for name in arrayOrder { root.append((name, .array(arrays[name] ?? []))) }
        return JSONText.render(.object(root), indent: 2)
    }

    static func splitKeyValue(_ s: String) -> (String, String)? {
        guard let r = s.range(of: ": ") else { return nil }
        return (
            String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces), String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        )
    }

    static func yamlParseValue(_ s: String) -> JSONText.Node {
        var v = s
        if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 {
            v = String(v.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        if v == "true" { return .bool(true) }
        if v == "false" { return .bool(false) }
        if let i = Int(v) { return .int(i) }
        return .string(v)
    }

    static func yamlEsc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: JSON helpers

    private func utcNow() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now())
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func parse(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }
    static func objects(_ v: Any?) -> [[String: Any]] { (v as? [Any])?.compactMap { $0 as? [String: Any] } ?? [] }
    static func str(_ v: Any?, _ fallback: String = "") -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return fallback
    }
    static func int(_ v: Any?, _ fallback: Int) -> Int { (v as? NSNumber)?.intValue ?? Int(v as? String ?? "") ?? fallback }
    static func bool(_ v: Any?, _ fallback: Bool) -> Bool {
        if let b = v as? Bool { return b }
        if let s = v as? String { return s == "true" ? true : (s == "false" ? false : fallback) }
        return fallback
    }
}

/// An ordered JSON writer, indented as org.json's toString(2) indents.
public enum JSONText {
    public indirect enum Node: Sendable, Equatable {
        case string(String)
        case int(Int)
        case bool(Bool)
        case null
        case array([Node])
        case object([(String, Node)])

        public static func == (a: Node, b: Node) -> Bool { render(a, indent: 0) == render(b, indent: 0) }
    }

    public static func render(_ node: Node, indent: Int) -> String {
        var out = ""
        write(node, into: &out, indent: indent, level: 0)
        return out
    }

    private static func write(_ node: Node, into out: inout String, indent: Int, level: Int) {
        let pad = indent > 0 ? String(repeating: " ", count: indent * (level + 1)) : ""
        let closePad = indent > 0 ? String(repeating: " ", count: indent * level) : ""
        let nl = indent > 0 ? "\n" : ""
        switch node {
        case .string(let s): out += "\"" + escape(s) + "\""
        case .int(let i): out += String(i)
        case .bool(let b): out += b ? "true" : "false"
        case .null: out += "null"
        case .array(let items):
            if items.isEmpty {
                out += "[]"
                return
            }
            out += "[" + nl
            for (i, item) in items.enumerated() {
                out += pad
                write(item, into: &out, indent: indent, level: level + 1)
                out += (i < items.count - 1 ? "," : "") + nl
            }
            out += closePad + "]"
        case .object(let fields):
            if fields.isEmpty {
                out += "{}"
                return
            }
            out += "{" + nl
            for (i, (k, v)) in fields.enumerated() {
                out += pad + "\"" + escape(k) + "\":" + (indent > 0 ? " " : "")
                write(v, into: &out, indent: indent, level: level + 1)
                out += (i < fields.count - 1 ? "," : "") + nl
            }
            out += closePad + "}"
        }
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }
}
