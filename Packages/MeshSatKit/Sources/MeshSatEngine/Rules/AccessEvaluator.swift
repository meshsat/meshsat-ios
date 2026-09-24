// Mirrors rules/RouteMessage.kt and rules/AccessEvaluator.kt (the Bridge's rules package):
// v0.3.0 access rules, Cisco ASA style, implicit deny. The rules and object groups are loaded
// from the store on `reloadFromDb`; evaluation is synchronous and lock-protected.
import Foundation
import Logging

/// Transport-agnostic message envelope for rule evaluation.
public struct RouteMessage: Sendable {
    public var text: String
    public var from: String
    public var to: String
    /// Mesh channel (0 if non-mesh).
    public var channel: Int
    /// Portnum (1 = text, 67 = telemetry).
    public var portNum: Int
    public var rawData: [UInt8]?
    /// Visited interface ids, for loop prevention.
    public var visited: [String]

    public init(
        text: String = "", from: String = "", to: String = "", channel: Int = 0, portNum: Int = 1, rawData: [UInt8]? = nil,
        visited: [String] = []
    ) {
        self.text = text
        self.from = from
        self.to = to
        self.channel = channel
        self.portNum = portNum
        self.rawData = rawData
        self.visited = visited
    }
}

/// An access rule match: the rule and where it forwards to.
public struct AccessMatchResult: Sendable, Equatable {
    public let rule: AccessRule
    public let forwardTo: String
    public init(rule: AccessRule, forwardTo: String) {
        self.rule = rule
        self.forwardTo = forwardTo
    }
}

public final class AccessEvaluator: @unchecked Sendable {
    private static let log = Logger(label: "AccessEvaluator")
    private let rulesStore: any AccessRuleStore
    private let groupsStore: any ObjectGroupStore
    private let lock = NSLock()
    private var rules: [AccessRule] = []
    private var rates: [Int64: TokenBucket] = [:]
    private var groups: [String: [String]] = [:]

    public init(rules: any AccessRuleStore, groups: any ObjectGroupStore) {
        self.rulesStore = rules
        self.groupsStore = groups
    }

    /// Reload rules and object groups from the store.
    public func reloadFromDb() async throws {
        let dbRules = try await rulesStore.getAllSync()
        let dbGroups = try await groupsStore.getAll()
        var newRates: [Int64: TokenBucket] = [:]
        for rule in dbRules where rule.rateLimitPerMin > 0 && rule.rateLimitWindow > 0 {
            if let id = rule.id, let limiter = TokenBucket.ruleLimiter(perWindow: rule.rateLimitPerMin, windowSeconds: rule.rateLimitWindow)
            {
                newRates[id] = limiter
            }
        }
        var newGroups: [String: [String]] = [:]
        for group in dbGroups {
            let members = Self.parseJsonStringArray(group.members)
            if !members.isEmpty { newGroups[group.id] = members }
        }
        load(rules: dbRules, groups: newGroups, rates: newRates)
        Self.log.info("Access rules loaded: \(dbRules.count) rules, \(newGroups.count) groups")
    }

    /// Rules straight in, for tests and previews.
    public func load(rules newRules: [AccessRule], groups newGroups: [String: [String]] = [:], rates newRates: [Int64: TokenBucket] = [:]) {
        lock.lock()
        rules = newRules
        groups = newGroups
        rates = newRates
        lock.unlock()
    }

    public func ruleCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return rules.count
    }

    public func evaluateIngress(_ interfaceId: String, _ msg: RouteMessage) -> [AccessMatchResult] {
        evaluate(interfaceId, "ingress", msg)
    }

    public func evaluateEgress(_ interfaceId: String, _ msg: RouteMessage) -> [AccessMatchResult] {
        evaluate(interfaceId, "egress", msg)
    }

    public func hasEgressRules(_ interfaceId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return rules.contains { $0.enabled && $0.interfaceId == interfaceId && $0.direction == "egress" }
    }

    private func evaluate(_ interfaceId: String, _ direction: String, _ msg: RouteMessage) -> [AccessMatchResult] {
        lock.lock()
        let snapshot = rules
        let limiters = rates
        let groupsNow = groups
        lock.unlock()
        var results: [AccessMatchResult] = []
        for rule in snapshot {
            if !rule.enabled || rule.interfaceId != interfaceId || rule.direction != direction { continue }
            // Self-loop prevention, and targets already visited.
            if direction == "ingress" && rule.forwardTo == interfaceId { continue }
            if direction == "ingress" && !msg.visited.isEmpty && msg.visited.contains(rule.forwardTo) { continue }
            if !Self.matchFilters(rule, msg) { continue }
            if !Self.matchObjectGroups(rule, msg, groups: groupsNow) { continue }
            if let id = rule.id, let limiter = limiters[id], !limiter.allow() { continue }
            switch rule.action {
            case "drop":
                recordMatch(rule.id)
                return []
            case "log":
                recordMatch(rule.id)
            case "forward":
                recordMatch(rule.id)
                results.append(AccessMatchResult(rule: rule, forwardTo: rule.forwardTo))
            default:
                break
            }
        }
        return results
    }

    static func matchFilters(_ rule: AccessRule, _ msg: RouteMessage) -> Bool {
        if rule.filters.isEmpty || rule.filters == "{}" { return true }
        guard let data = rule.filters.data(using: .utf8),
            let filters = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return true }  // malformed = permissive
        if let keyword = filters["keyword"] as? String, !keyword.isEmpty, !msg.text.localizedCaseInsensitiveContains(keyword) {
            return false
        }
        // Android stores these as JSON strings inside the JSON: "[0, 1]".
        if let channels = jsonInts(filters["channels"]), !channels.isEmpty, !channels.contains(msg.channel) { return false }
        if let nodes = jsonStrings(filters["nodes"]), !nodes.isEmpty, !nodes.contains(msg.from) { return false }
        if let portnums = jsonInts(filters["portnums"]), !portnums.isEmpty, !portnums.contains(msg.portNum) { return false }
        return true
    }

    private static func jsonInts(_ value: Any?) -> [Int]? {
        if let s = value as? String { return s.isEmpty || s == "[]" ? nil : parseJsonIntArray(s) }
        if let a = value as? [Any] { return a.compactMap { ($0 as? NSNumber)?.intValue } }
        return nil
    }

    private static func jsonStrings(_ value: Any?) -> [String]? {
        if let s = value as? String { return s.isEmpty || s == "[]" ? nil : parseJsonStringArray(s) }
        if let a = value as? [Any] { return a.compactMap { $0 as? String } }
        return nil
    }

    static func matchObjectGroups(_ rule: AccessRule, _ msg: RouteMessage, groups: [String: [String]]) -> Bool {
        if let g = rule.filterNodeGroup, !g.isEmpty, let members = groups[g], !members.isEmpty, !members.contains(msg.from) { return false }
        if let g = rule.filterSenderGroup, !g.isEmpty, let members = groups[g], !members.isEmpty, !members.contains(msg.from) {
            return false
        }
        if let g = rule.filterPortnumGroup, !g.isEmpty, let members = groups[g], !members.isEmpty, !members.contains(String(msg.portNum)) {
            return false
        }
        return true
    }

    private func recordMatch(_ ruleId: Int64?) {
        guard let ruleId else { return }
        let store = rulesStore
        Task {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            try? await store.recordMatch(id: ruleId, timestamp: f.string(from: Date()))
        }
    }

    public static func parseJsonStringArray(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8), let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        return arr.compactMap { $0 as? String }
    }

    public static func parseJsonIntArray(_ json: String) -> [Int] {
        guard let data = json.data(using: .utf8), let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        return arr.compactMap { ($0 as? NSNumber)?.intValue }
    }
}
