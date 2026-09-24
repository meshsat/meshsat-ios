// Mirrors the pure helpers of ui/screens/RulesScreen.kt and parseUtcStamp of AuditScreen.kt:
// which links a rule may name, the Hub duplicate warning, a rule's words, and the keyword
// filter kept apart from every other filter a rule carries.
import Foundation
import MeshSatEngine

enum RuleWords {
    /// The links a rule can name: the ones this phone is set up to use, plus `keep`, the one a
    /// saved rule already names, so opening an old rule never blanks its field. A link that is
    /// switched off holds whatever is routed to it for ever, so offering it writes a rule that
    /// silently delivers nothing (MESHSAT-1281).
    static func linkChoices(_ all: [(id: String, disabled: Bool)], keep: String) -> [String] {
        all.filter { !$0.disabled || $0.id == keep }.map(\.id)
    }

    /// Whether a rule would hand the Hub something it already has (MESHSAT-1276). A RockBLOCK's
    /// own message reaches the Hub through the provider's webhook; mesh and SMS have no other
    /// copy there, which is the point of forwarding them. hub_relay is a tunnel, not the Hub.
    static func duplicatesTheHub(_ source: String, _ destination: String) -> Bool {
        destination.range(of: #"^hub_\d+$"#, options: .regularExpression) != nil && source.hasPrefix("iridium")
    }

    /// A rule's action, as the user reads it: Forward, Drop, Log only.
    static func actionLabel(_ action: String) -> String {
        switch action.lowercased() {
        case "forward": "Forward"
        case "drop": "Drop"
        case "log": "Log only"
        default: action.prefix(1).uppercased() + action.dropFirst()
        }
    }

    /// "At most 5 messages per minute", or nil when the rule has no limit (both numbers are needed).
    static func rateLimitText(_ perWindow: Int, _ windowSeconds: Int) -> String? {
        guard perWindow > 0, windowSeconds > 0 else { return nil }
        let per = windowSeconds == 60 ? "per minute" : "per \(Words.count(windowSeconds, "second"))"
        return "At most \(Words.count(perWindow, "message")) \(per)"
    }

    /// What deleting `rule` changes, in one sentence.
    static func deleteConsequence(_ rule: AccessRule) -> String {
        switch rule.action {
        case "forward":
            rule.forwardTo.isEmpty
                ? "Messages that matched it will no longer be forwarded."
                : "Messages that matched it will no longer be forwarded to \(Words.channel(rule.forwardTo))."
        case "drop": "Messages it stopped can get through again, if another rule passes them on."
        case "log": "Its matches will no longer be counted. Messages are not affected."
        default: "Messages that matched it will no longer be handled by it."
        }
    }

    static func jsonObject(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A filter value as JSONObject.optString reads it: a string as is, anything else as JSON text.
    static func optString(_ obj: [String: Any], _ key: String) -> String {
        guard let v = obj[key], !(v is NSNull) else { return "" }
        if let s = v as? String { return s }
        if let data = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]),
            let s = String(data: data, encoding: .utf8)
        {
            return s
        }
        return "\(v)"
    }

    /// A JSON array of ids or numbers as "a, b, c"; anything else as it is.
    static func jsonListText(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8), let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return raw }
        return arr.map { "\($0)" }.joined(separator: ", ")
    }

    static func filterSummary(_ rule: AccessRule) -> String {
        var parts: [String] = []
        if !rule.filters.isEmpty, rule.filters != "{}", let obj = jsonObject(rule.filters) {
            let kw = optString(obj, "keyword")
            if !kw.isEmpty { parts.append("Contains \u{201C}\(kw)\u{201D}") }
            for (key, label) in [("channels", "Mesh channels"), ("nodes", "From nodes"), ("portnums", "Message types")] {
                let v = optString(obj, key)
                if !v.isEmpty, v != "[]" { parts.append("\(label) \(jsonListText(v))") }
            }
        }
        if let g = rule.filterNodeGroup, !g.isEmpty { parts.append("Node group \(g)") }
        if let g = rule.filterSenderGroup, !g.isEmpty { parts.append("Sender group \(g)") }
        if let g = rule.filterPortnumGroup, !g.isEmpty { parts.append("Message type group \(g)") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// The keyword filter of a rule, or "" when it has none.
    static func keyword(_ rule: AccessRule?) -> String {
        let raw = rule?.filters.trimmingCharacters(in: .whitespaces) ?? ""
        guard !raw.isEmpty, raw != "{}", let obj = jsonObject(raw) else { return "" }
        return optString(obj, "keyword")
    }

    /// The rule's filters with the keyword set to `keyword` (removed when blank). Every other
    /// filter is kept: saving used to replace them all with the keyword alone (B9). Filters this
    /// code cannot read are kept as they are unless a keyword was typed.
    static func mergeKeyword(_ existing: String?, _ keyword: String) -> String {
        let raw = existing?.trimmingCharacters(in: .whitespaces) ?? ""
        let blank = keyword.trimmingCharacters(in: .whitespaces).isEmpty
        var obj: [String: Any]
        if raw.isEmpty {
            obj = [:]
        } else if let parsed = jsonObject(raw) {
            obj = parsed
        } else {
            return blank ? raw : serialize(["keyword": keyword])
        }
        if blank { obj.removeValue(forKey: "keyword") } else { obj["keyword"] = keyword }
        return obj.isEmpty ? "{}" : serialize(obj)
    }

    static func serialize(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// The settings of `rule` that the editor does not show, which saving keeps.
    static func hiddenSettings(_ rule: AccessRule?) -> [String] {
        guard let rule else { return [] }
        var hidden: [String] = []
        let raw = rule.filters.trimmingCharacters(in: .whitespaces)
        if !raw.isEmpty, raw != "{}" {
            if let obj = jsonObject(raw) {
                for (key, label) in [("channels", "mesh channels"), ("nodes", "nodes"), ("portnums", "message types")] {
                    let v = optString(obj, key)
                    if !v.isEmpty, v != "[]" { hidden.append(label) }
                }
            } else {
                hidden.append("filters this screen cannot read")
            }
        }
        if let g = rule.filterPortnumGroup, !g.isEmpty { hidden.append("a message type group") }
        let options = rule.forwardOptions.trimmingCharacters(in: .whitespaces)
        if !options.isEmpty, options != "{}" { hidden.append("forwarding options") }
        return hidden
    }

    /// A stored timestamp ("2026-09-20T10:15:00Z", or "2026-09-20 10:15:00" meaning UTC) as epoch ms.
    static func parseUtcStamp(_ text: String?) -> Int64? {
        let t = text?.trimmingCharacters(in: .whitespaces) ?? ""
        if t.isEmpty { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: t) { return Int64(d.timeIntervalSince1970 * 1000) }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: t) { return Int64(d.timeIntervalSince1970 * 1000) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            f.dateFormat = pattern
            if let d = f.date(from: t.replacingOccurrences(of: " ", with: "T")) { return Int64(d.timeIntervalSince1970 * 1000) }
        }
        return nil
    }
}
