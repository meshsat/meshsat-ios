// Mirrors warnings/WarningText.kt, warnings/WarningIntake.kt and data/WarningEntity.kt (MESHSAT-1734,
// iOS MESHSAT-1819; spec meshsat-android/docs/WARNINGS.md): a public warning a MeshSat kit relays over
// the mesh, read back, and the state behind the alarm.
//
// The Bridge (`internal/warnings/relay.go`, `MeshText`) sends each verified warning twice: on
// ALERT_APP (port 11) with a BEL at the end, so a node with its alert setting on buzzes, and as a
// plain text on the primary channel. Both carry the same words, two lines:
//
//     [TEST ][UPDATE: ]WARNING <event> <severity>[ until HH:MM UTC][: <text>]
//     Relay of <source> warning, issued <d Mon HH:MM> UTC via MeshSat, not an official NL-Alert
//
// and a cancel is `[TEST ]CANCELLED: <event>[ - <text>]` over the same relay line. The first line may
// be cut to fit the mesh packet (200 bytes); the label is kept whole. A port-11 text of another shape
// is still an alert, kept whole; a port-1 text is a warning only with the kit's relay line, so a
// person typing "WARNING ..." in a chat stays a chat.
import Foundation

public enum WarningText {
    /// Meshtastic ALERT_APP.
    public static let portAlert = 11
    /// Meshtastic TEXT_MESSAGE_APP.
    public static let portText = 1
    /// How the kit's second line starts: its mark on a relayed text.
    public static let labelPrefix = "Relay of "

    public static let severities = ["Unknown", "Minor", "Moderate", "Severe", "Extreme"]

    public enum Kind: String, Sendable, Equatable {
        case alert, update, cancel
        public static func of(_ wire: String) -> Kind { Kind(rawValue: wire) ?? .alert }
    }

    public struct Parsed: Sendable, Equatable {
        public let kind: Kind
        public let test: Bool
        public let event: String
        /// One of `severities`, or "" when the line carried none (a cut line, a cancel).
        public let severity: String
        /// "HH:MM" UTC, or "".
        public let until: String
        public let text: String
        /// The kit's relay line, or "" (a port-11 alert from something else).
        public let label: String
        /// The first line as it came, without the BEL.
        public let headline: String
    }

    /// The text without the BEL and trailing whitespace.
    public static func clean(_ raw: String) -> String {
        var s = Substring(raw)
        while let last = s.unicodeScalars.last, last == "\u{07}" || last == " " || last == "\n" || last == "\r" || last == "\t" {
            s = Substring(s.unicodeScalars.dropLast())
        }
        return String(s)
    }

    /// The warning on `port`, or nil when the text is not one.
    public static func recognise(_ raw: String, port: Int) -> Parsed? {
        switch port {
        case portAlert: parse(raw) ?? fallbackAlert(raw)
        case portText: parse(raw).flatMap { $0.label.hasPrefix(labelPrefix) ? $0 : nil }
        default: nil
        }
    }

    /// True when a port-1 text is a relayed warning and not a chat.
    public static func isRelayedText(_ raw: String) -> Bool { recognise(raw, port: portText) != nil }

    /// The text in the kit's shape, or nil.
    public static func parse(_ raw: String) -> Parsed? {
        let text = clean(raw)
        guard !text.trimmed.isEmpty else { return nil }
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let headline = String(lines[0]).trimmed
        let label = lines.count > 1 ? String(lines[1]).trimmed : ""
        var rest = headline
        let test = rest.hasPrefix("TEST ")
        if test { rest.removeFirst("TEST ".count) }
        if rest.hasPrefix("CANCELLED: ") {
            let body = String(rest.dropFirst("CANCELLED: ".count))
            let sep = body.range(of: " - ")
            let event = (sep.map { String(body[..<$0.lowerBound]) } ?? body).trimmed
            guard !event.isEmpty else { return nil }
            let words = sep.map { String(body[$0.upperBound...]).trimmed } ?? ""
            return Parsed(kind: .cancel, test: test, event: event, severity: "", until: "", text: words, label: label, headline: headline)
        }
        if rest.hasPrefix("UPDATE: WARNING ") {
            return warning(.update, test, String(rest.dropFirst("UPDATE: WARNING ".count)), label, headline)
        }
        if rest.hasPrefix("WARNING ") { return warning(.alert, test, String(rest.dropFirst("WARNING ".count)), label, headline) }
        return nil
    }

    private static func warning(_ kind: Kind, _ test: Bool, _ body: String, _ label: String, _ headline: String) -> Parsed? {
        let colon = body.range(of: ": ")
        let lead = (colon.map { String(body[..<$0.lowerBound]) } ?? body).trimmed
        let text = colon.map { String(body[$0.upperBound...]).trimmed } ?? ""
        guard !lead.isEmpty else { return nil }
        // ^(\S+)(?: (\S+))?(?: until (\d{1,2}:\d{2}) UTC)?$, as Android's head regex.
        let words = lead.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if let m = matchHead(words) {
            return Parsed(
                kind: kind, test: test, event: m.event, severity: severities.contains(m.severity) ? m.severity : "", until: m.until,
                text: text, label: label, headline: headline)
        }
        // A line cut mid-way ("WARNING Wind Severe until 10:1"): the event and the severity still read.
        let present = words.filter { !$0.isEmpty }
        let sev = present.count > 1 && severities.contains(present[1]) ? present[1] : ""
        return Parsed(kind: kind, test: test, event: present[0], severity: sev, until: "", text: text, label: label, headline: headline)
    }

    private struct Head {
        let event: String
        let severity: String
        let until: String
    }

    private static func matchHead(_ w: [String]) -> Head? {
        guard w.allSatisfy({ !$0.isEmpty }) else { return nil }
        func isTime(_ s: String) -> Bool {
            let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2 else { return false }
            return parts.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isNumber } }
        }
        switch w.count {
        case 1: return Head(event: w[0], severity: "", until: "")
        case 2: return Head(event: w[0], severity: w[1], until: "")
        case 4 where w[1] == "until" && isTime(w[2]) && w[3] == "UTC": return Head(event: w[0], severity: "", until: w[2])
        case 5 where w[2] == "until" && isTime(w[3]) && w[4] == "UTC": return Head(event: w[0], severity: w[1], until: w[3])
        default: return nil
        }
    }

    private static func fallbackAlert(_ raw: String) -> Parsed? {
        let text = clean(raw)
        guard !text.trimmed.isEmpty else { return nil }
        let first = String(text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[0]).trimmed
        return Parsed(kind: .alert, test: false, event: "Alert", severity: "", until: "", text: text, label: "", headline: first)
    }

    /// The words that identify one relayed text wherever it came from: the two lines, spaces folded.
    public static func dedupKey(_ raw: String) -> String {
        clean(raw).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// "WARNING", "UPDATE", "CANCELLED", with "TEST" in front of a test.
    public static func kindLabel(_ kind: Kind, test: Bool) -> String {
        let word: String =
            switch kind {
            case .alert: "WARNING"
            case .update: "UPDATE"
            case .cancel: "CANCELLED"
            }
        return (test ? "TEST " : "") + word
    }

    /// "Wind Severe until 10:11 UTC", the parts that are there.
    public static func summary(event: String, severity: String, until: String) -> String {
        [event, severity, until.isEmpty ? "" : "until \(until) UTC"].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// A public warning a MeshSat kit relayed over the mesh, as this phone heard it: one row per text taken
/// in (Android's WarningEntity, table `warnings`, the same columns). A warning "stands" while it is not
/// a cancel and neither cancelled nor replaced; the banner shows the newest standing one not yet acknowledged.
public struct WarningRecord: Sendable, Equatable, Identifiable {
    public static let kindAlert = "alert"
    public static let kindUpdate = "update"
    public static let kindCancel = "cancel"

    public var id: Int64
    public var receivedAt: Int64
    /// The Meshtastic port it came on: 11 (ALERT_APP) or 1 (a text).
    public var port: Int
    /// The mesh node that sent it, "!a1b2c3d4".
    public var sender: String
    /// That node's long name when known, else "".
    public var senderName: String
    /// "alert", "update" or "cancel".
    public var kind: String
    public var test: Bool
    public var event: String
    public var severity: String
    /// "HH:MM" UTC, or "".
    public var until: String
    public var text: String
    /// The kit's relay line, or "".
    public var label: String
    /// The text as it came off the mesh, BEL dropped.
    public var raw: String
    public var dedupKey: String
    public var cancelledAt: Int64
    public var replacedAt: Int64
    public var acknowledgedAt: Int64

    public init(
        id: Int64 = 0, receivedAt: Int64, port: Int, sender: String, senderName: String, kind: String, test: Bool, event: String,
        severity: String, until: String, text: String, label: String, raw: String, dedupKey: String, cancelledAt: Int64 = 0,
        replacedAt: Int64 = 0, acknowledgedAt: Int64 = 0
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.port = port
        self.sender = sender
        self.senderName = senderName
        self.kind = kind
        self.test = test
        self.event = event
        self.severity = severity
        self.until = until
        self.text = text
        self.label = label
        self.raw = raw
        self.dedupKey = dedupKey
        self.cancelledAt = cancelledAt
        self.replacedAt = replacedAt
        self.acknowledgedAt = acknowledgedAt
    }

    public var isCancel: Bool { kind == Self.kindCancel }
    public var standing: Bool { !isCancel && cancelledAt == 0 && replacedAt == 0 }
}

/// Android's WarningDao: the queries the intake and the screens need.
public protocol WarningStore: Sendable {
    func insert(_ w: WarningRecord) async throws -> Int64
    func countRecent(key: String, since: Int64) async throws -> Int
    /// The warnings of one event that still stand, oldest first.
    func standingOf(event: String, test: Bool) async throws -> [WarningRecord]
    func markReplaced(_ ids: [Int64], at: Int64) async throws
    func markCancelled(_ ids: [Int64], at: Int64) async throws
    func acknowledge(_ id: Int64, at: Int64) async throws
    func byId(_ id: Int64) async throws -> WarningRecord?
    /// Newest first, every kind.
    func recent(limit: Int) async throws -> [WarningRecord]
    /// The newest standing warning the person has not dismissed, for the banner.
    func unacknowledged() async throws -> WarningRecord?
    func deleteOlderThan(_ before: Int64) async throws -> Int
}

/// What the phone does with a relayed warning it hears on the mesh: the same words within `dedupMs`
/// are one warning (the kit's two copies, a second kit, a rebroadcast: one alarm); an alert or an
/// update of an event replaces the warnings of that event that still stood; a cancel clears the
/// standing warnings of its event and is kept as the all-clear. A test cancel clears tests only.
public struct WarningIntake: Sendable {
    /// The same words heard again within this are the same warning.
    public static let dedupMs: Int64 = 15 * 60 * 1000
    /// Rows older than this go, as the kit's own table is pruned.
    public static let keepMs: Int64 = 30 * 24 * 60 * 60 * 1000

    public enum Outcome: Sendable, Equatable {
        /// A new warning stands: alarm (the normal sound for a test).
        case alarm(WarningRecord)
        /// A cancel: the cleared ones no longer stand; their alarms go.
        case cleared(cancel: WarningRecord, cleared: [WarningRecord])
        /// The same words again within the window: nothing to do.
        case duplicate
        /// Not a relayed warning: an ordinary text, left to the chat.
        case notAWarning
    }

    private let store: any WarningStore
    private let now: @Sendable () -> Int64

    public init(store: any WarningStore, now: @escaping @Sendable () -> Int64) {
        self.store = store
        self.now = now
    }

    /// One mesh packet. `sender` is "!a1b2c3d4", `senderName` its long name or "".
    public func onMesh(sender: String, senderName: String, port: Int, raw: String) async throws -> Outcome {
        guard let p = WarningText.recognise(raw, port: port) else { return .notAWarning }
        let t = now()
        let key = WarningText.dedupKey(raw)
        if try await store.countRecent(key: key, since: t - Self.dedupMs) > 0 { return .duplicate }
        let standing = try await store.standingOf(event: p.event, test: p.test)
        var row = WarningRecord(
            receivedAt: t, port: port, sender: sender, senderName: senderName, kind: p.kind.rawValue, test: p.test, event: p.event,
            severity: p.severity, until: p.until, text: p.text, label: p.label, raw: WarningText.clean(raw), dedupKey: key,
            // A cancel is history from the start: it never asks to be dismissed.
            acknowledgedAt: p.kind == .cancel ? t : 0)
        let ids = standing.map(\.id)
        if p.kind == .cancel {
            if !ids.isEmpty { try await store.markCancelled(ids, at: t) }
            row.id = try await store.insert(row)
            return .cleared(
                cancel: row,
                cleared: standing.map {
                    var w = $0
                    w.cancelledAt = t
                    return w
                })
        }
        if !ids.isEmpty { try await store.markReplaced(ids, at: t) }
        row.id = try await store.insert(row)
        return .alarm(row)
    }

    /// The person dismissed the banner: the warning stands, it just stops asking.
    public func acknowledge(_ id: Int64) async throws { try await store.acknowledge(id, at: now()) }
}

/// The words of a warning on a notification, the banner and the list (WarningNotifier.kt's title and
/// relayLine, WarningsScreen.kt's states), so the screens and the notifier say the same.
public enum WarningWords {
    /// "WARNING Wind Severe until 10:11 UTC".
    public static func title(_ w: WarningRecord) -> String {
        (WarningText.kindLabel(.of(w.kind), test: w.test) + " " + WarningText.summary(event: w.event, severity: w.severity, until: w.until))
            .trimmingCharacters(in: .whitespaces)
    }

    /// "Relay of tesseract (!4370c1d8)": who put it on the mesh.
    public static func relayLine(_ w: WarningRecord) -> String {
        "Relay of " + (w.senderName.trimmingCharacters(in: .whitespaces).isEmpty ? w.sender : "\(w.senderName) (\(w.sender))")
    }

    /// The notification's text: the warning's own words, the kit's relay line, then who relayed it.
    public static func body(_ w: WarningRecord) -> String {
        ([w.text, w.label].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } + [relayLine(w)]).joined(separator: "\n")
    }

    /// The notification identifier of the warnings of one event; a test keeps its own, so the cancel
    /// of an event takes its alarm down (Android's idFor).
    public static func notificationId(event: String, test: Bool) -> String {
        "meshsat.warning." + event.lowercased() + (test ? ".test" : "")
    }

    /// An alert or an update that is not a test: the alarm, not the quiet sound.
    public static func isAlarm(_ w: WarningRecord) -> Bool { !w.test && !w.isCancel }

    /// The state on the list: Standing, Test, Replaced <time>, Cancelled <time>, All-clear.
    public static func state(_ w: WarningRecord, time: (Int64) -> String) -> String {
        if w.isCancel { return "All-clear" }
        if w.cancelledAt > 0 { return "Cancelled \(time(w.cancelledAt))" }
        if w.replacedAt > 0 { return "Replaced \(time(w.replacedAt))" }
        return w.test ? "Test" : "Standing"
    }

    /// "Relay of <node>, alert|text, heard <time>", as Android's list row.
    public static func heard(_ w: WarningRecord, time: (Int64) -> String) -> String {
        "\(relayLine(w)), \(w.port == WarningText.portAlert ? "alert" : "text"), heard \(time(w.receivedAt))"
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
