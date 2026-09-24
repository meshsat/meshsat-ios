// Mirrors sos/SosRun.kt: one SOS, or one test of the alarm (MESHSAT-1249). Its deliveries sit in
// the ordinary delivery queue with msg_ref "sos:<id>:<route>", so they survive a restart and are
// retried like any message; the cancellation that follows a cancelled SOS goes as
// "sos:<id>:cancel:<route>". The run itself is kept in the settings as JSON with Android's keys,
// so the banner, the result screen and the veto on a cancelled SOS survive a restart too.
import Foundation
import MeshSatWire

public struct SosRun: Sendable, Equatable {
    public struct Route: Sendable, Equatable {
        public let key: String
        public let label: String
        public init(key: String, label: String) {
            self.key = key
            self.label = label
        }
    }

    public var id: Int64
    public var test: Bool
    /// "button", or "checkin" when the check-in timer (dead man's switch) ran out.
    public var trigger: String
    public var name: String
    public var fix: SosMessages.Fix?
    /// What was queued, in order: `Route.key` is the msg_ref suffix.
    public var routes: [Route]
    /// Routes that were not possible, each as a sentence for the result screen.
    public var skipped: [String]
    /// The Hub is set up on this phone, so it is told over the internet as well.
    public var hubWanted: Bool
    public var deviceId: String
    public var hubAlertId: String
    public var hubSentAt: Int64?
    public var cancelledAt: Int64?
    public var cancelHubSentAt: Int64?
    /// A test that has run its course or was stopped.
    public var finishedAt: Int64?

    public init(
        id: Int64, test: Bool, trigger: String, name: String, fix: SosMessages.Fix?, routes: [Route], skipped: [String], hubWanted: Bool,
        deviceId: String, hubAlertId: String, hubSentAt: Int64? = nil, cancelledAt: Int64? = nil, cancelHubSentAt: Int64? = nil,
        finishedAt: Int64? = nil
    ) {
        self.id = id
        self.test = test
        self.trigger = trigger
        self.name = name
        self.fix = fix
        self.routes = routes
        self.skipped = skipped
        self.hubWanted = hubWanted
        self.deviceId = deviceId
        self.hubAlertId = hubAlertId
        self.hubSentAt = hubSentAt
        self.cancelledAt = cancelledAt
        self.cancelHubSentAt = cancelHubSentAt
        self.finishedAt = finishedAt
    }

    public var active: Bool { cancelledAt == nil && finishedAt == nil }
    public var refPrefix: String { SosRun.refPrefix(id) }
    public static func refPrefix(_ id: Int64) -> String { "sos:\(id):" }

    /// The run id in a msg_ref and whether the delivery is a cancellation; nil if not an SOS delivery.
    public static func parseRef(_ ref: String) -> (id: Int64, isCancel: Bool)? {
        guard ref.hasPrefix("sos:") else { return nil }
        let parts = ref.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count > 1, let id = Int64(parts[1]) else { return nil }
        return (id, parts.count > 2 && parts[2] == "cancel")
    }

    public func toJson() -> String {
        var o: [String: Any] = [
            "id": id, "test": test, "trigger": trigger, "name": name,
            "routes": routes.map { ["key": $0.key, "label": $0.label] }, "skipped": skipped, "hub_wanted": hubWanted,
            "device_id": deviceId, "hub_alert_id": hubAlertId,
        ]
        if let fix {
            o["lat"] = fix.lat
            o["lon"] = fix.lon
            o["fix_time"] = fix.timeMs
            if let a = fix.accuracyM { o["acc"] = Double(a) }
        }
        if let hubSentAt { o["hub_sent_at"] = hubSentAt }
        if let cancelledAt { o["cancelled_at"] = cancelledAt }
        if let cancelHubSentAt { o["cancel_hub_sent_at"] = cancelHubSentAt }
        if let finishedAt { o["finished_at"] = finishedAt }
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func fromJson(_ s: String) -> SosRun? {
        guard !s.trimmingCharacters(in: .whitespaces).isEmpty, let data = s.data(using: .utf8),
            let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = int64(o["id"])
        else { return nil }
        var fix: SosMessages.Fix?
        if let lat = o["lat"] as? Double, let lon = o["lon"] as? Double {
            fix = SosMessages.Fix(lat: lat, lon: lon, accuracyM: (o["acc"] as? Double).map { Float($0) }, timeMs: int64(o["fix_time"]) ?? 0)
        }
        let routes = ((o["routes"] as? [[String: Any]]) ?? []).compactMap { r -> Route? in
            guard let key = r["key"] as? String, let label = r["label"] as? String else { return nil }
            return Route(key: key, label: label)
        }
        return SosRun(
            id: id, test: o["test"] as? Bool ?? false, trigger: o["trigger"] as? String ?? "button", name: o["name"] as? String ?? "",
            fix: fix, routes: routes, skipped: (o["skipped"] as? [String]) ?? [], hubWanted: o["hub_wanted"] as? Bool ?? false,
            deviceId: o["device_id"] as? String ?? "", hubAlertId: o["hub_alert_id"] as? String ?? "", hubSentAt: int64(o["hub_sent_at"]),
            cancelledAt: int64(o["cancelled_at"]), cancelHubSentAt: int64(o["cancel_hub_sent_at"]), finishedAt: int64(o["finished_at"]))
    }

    private static func int64(_ v: Any?) -> Int64? {
        if let n = v as? Int64 { return n }
        if let n = v as? Int { return Int64(n) }
        if let n = v as? Double { return Int64(n) }
        if let n = v as? NSNumber { return n.int64Value }
        return nil
    }
}

/// Where one route of an SOS stands, as the result screen and the notification say it.
public struct SosRouteStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable { case waiting, sending, sent, stopped, failed }
    public let label: String
    public let state: State
    public let detail: String
    /// The same route's cancellation, once the SOS was cancelled.
    public let cancel: State?
    /// The route in a sentence: "satellite", "SMS to Anna".
    public let short: String

    public init(label: String, state: State, detail: String, cancel: State? = nil, short: String? = nil) {
        self.label = label
        self.state = state
        self.detail = detail
        self.cancel = cancel
        self.short = short ?? label
    }
}

public enum SosProgress {
    static let hubLabel = "Hub, over the internet"
    static let hubShort = "the Hub online"

    static func sentence(_ items: [String]) -> String {
        items.count == 1 ? items[0] : items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
    }

    /// One status per route of the run, from its deliveries, plus the Hub's internet link.
    public static func routes(_ run: SosRun, deliveries: [MessageDelivery]) -> [SosRouteStatus] {
        var byRef: [String: MessageDelivery] = [:]
        for d in deliveries { byRef[d.msgRef] = d }
        var out = run.routes.map { route -> SosRouteStatus in
            let del = byRef[run.refPrefix + route.key]
            let cancel = byRef[run.refPrefix + "cancel:" + route.key].map { stateOf($0) }
            let short: String
            switch route.key {
            case "sat": short = "satellite"
            case "mesh": short = "mesh"
            default: short = route.label
            }
            guard let del else { return SosRouteStatus(label: route.label, state: .failed, detail: "Could not be queued", short: short) }
            return SosRouteStatus(label: route.label, state: stateOf(del), detail: detailOf(del), cancel: cancel, short: short)
        }
        if run.hubWanted {
            if run.hubSentAt != nil {
                let cancel: SosRouteStatus.State? =
                    (run.cancelledAt == nil || run.test) ? nil : (run.cancelHubSentAt != nil ? .sent : .waiting)
                out.append(SosRouteStatus(label: hubLabel, state: .sent, detail: "Sent", cancel: cancel, short: hubShort))
            } else if !run.active {
                out.append(
                    SosRouteStatus(label: hubLabel, state: .stopped, detail: "Stopped before the Hub could be reached", short: hubShort))
            } else {
                out.append(SosRouteStatus(label: hubLabel, state: .waiting, detail: "Waiting for the Hub connection", short: hubShort))
            }
        }
        return out
    }

    public static func stateOf(_ d: MessageDelivery) -> SosRouteStatus.State {
        switch d.status {
        case "sent", "delivered": return .sent
        case "sending": return .sending
        case "queued", "retry", "held", Dispatcher.awaitingUser: return .waiting
        case "dead": return d.lastError == "cancelled" ? .stopped : .failed
        default: return .failed
        }
    }

    static func detailOf(_ d: MessageDelivery) -> String {
        switch stateOf(d) {
        // A confirmation from the far end (MESHSAT-1246): the Hub's receipt by satellite, the
        // carrier's delivery report by SMS.
        case .sent:
            if d.ackStatus != "acked" { return "Sent" }
            if d.channel.hasPrefix("iridium") { return "Sent, and the Hub has it" }
            if d.channel.hasPrefix("sms") { return "Delivered to their phone" }
            return "Sent"
        case .sending: return "Sending now"
        case .stopped: return "Stopped"
        case .waiting:
            if d.status == Dispatcher.awaitingUser { return "Waiting for you to send it in Messages" }
            return d.retries == 0 && d.lastError.isEmpty
                ? "Waiting to send" : "Trying again: \(d.lastError.isEmpty ? "not sent yet" : d.lastError)"
        case .failed: return d.lastError.isEmpty ? "Not sent" : d.lastError
        }
    }

    /// One line for the notification: "Sent by SMS to Anna and the Hub online. Still trying satellite."
    public static func summary(_ statuses: [SosRouteStatus]) -> String {
        if statuses.isEmpty { return "No way to send it: add emergency contacts or connect your node." }
        let sent = statuses.filter { $0.state == .sent }.map { $0.short }
        let waiting = statuses.filter { $0.state == .waiting || $0.state == .sending }.map { $0.short }
        var parts: [String] = []
        if !sent.isEmpty { parts.append("Sent by \(sentence(sent)).") }
        if !waiting.isEmpty { parts.append("Still trying \(sentence(waiting)).") }
        if parts.isEmpty { parts.append("Nothing could be sent.") }
        return parts.joined(separator: " ")
    }

    /// Everything a test sent has finished one way or the other.
    public static func allSettled(_ run: SosRun, statuses: [SosRouteStatus]) -> Bool {
        !statuses.contains { $0.state == .waiting || $0.state == .sending } && (!run.hubWanted || run.hubSentAt != nil)
    }
}
