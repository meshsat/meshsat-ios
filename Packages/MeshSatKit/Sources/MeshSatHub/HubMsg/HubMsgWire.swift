// Mirrors hubmsg/HubMsgWire.kt: the payloads of hub_msg on the wire (the Hub's
// docs/bridge-hub-protocol.md "Messaging v1"): a sender's submission on its own msg/out (C4), the
// Hub's delivery on a recipient's msg/in, the recipient's answer on its msg/ack (C5), and on a
// sender's msg/status an event (C6) or the Hub's refusal record. This phone is a bridge principal
// (C4.1), so its topics are the bridges' topics under its own id. [MESHSAT-1584]
import Foundation

public enum HubMsgWire {
    /// The one content type of stage 2.
    public static let contentTypeText = "text/plain;charset=utf-8"

    /// The largest body the Hub admits, in bytes.
    public static let maxBody = 16 * 1024

    /// The bridge id of a "bridge:<id>" principal, or "".
    public static func bridgeOf(_ principal: String) -> String {
        guard principal.hasPrefix("bridge:") else { return "" }
        let id = String(principal.dropFirst("bridge:".count))
        return id.isEmpty || id.contains(where: { $0 == "/" || $0 == "+" || $0 == "#" }) ? "" : id
    }

    /// The principal of a bridge id.
    public static func principal(_ bridgeId: String) -> String { "bridge:" + bridgeId }

    static func parse(_ s: String) -> JSONBody? { JSONBody.parse(Data(s.utf8)) }
}

/// A sender's submission (C4). body is the text; its UTF-8 bytes are what the digest covers.
public struct HubSubmission: Sendable, Equatable {
    public var v = 1
    public var opId: String
    public var mid: String
    public var to: String
    public var contentType = HubMsgWire.contentTypeText
    public var midExpiresAt: Int64
    public var expiresAt: Int64
    public var contentSha256: String
    public var body: String

    public init(
        v: Int = 1, opId: String, mid: String, to: String, contentType: String = HubMsgWire.contentTypeText, midExpiresAt: Int64,
        expiresAt: Int64, contentSha256: String, body: String
    ) {
        self.v = v
        self.opId = opId
        self.mid = mid
        self.to = to
        self.contentType = contentType
        self.midExpiresAt = midExpiresAt
        self.expiresAt = expiresAt
        self.contentSha256 = contentSha256
        self.body = body
    }

    // swiftlint:disable function_parameter_count
    /// A submission with its digest.
    public static func create(opId: String, mid: String, to: String, body: String, midExpiresAt: Int64, expiresAt: Int64) -> HubSubmission {
        let digest =
            HubMsgDigest.sha256Hex(
                mid: mid, recipient: to, contentType: HubMsgWire.contentTypeText, midExpiresAt: midExpiresAt, body: Array(body.utf8)) ?? ""
        return HubSubmission(
            opId: opId, mid: mid, to: to, midExpiresAt: midExpiresAt, expiresAt: expiresAt, contentSha256: digest, body: body)
    }

    // swiftlint:enable function_parameter_count

    public func toJson() -> String {
        var j = JSONBody()
        j.put("v", v)
        j.put("op_id", opId)
        j.put("mid", mid)
        j.put("to", to)
        j.put("content_type", contentType)
        j.put("mid_expires_at", midExpiresAt)
        j.put("expires_at", expiresAt)
        j.put("content_sha256", contentSha256)
        j.put("body", body)
        return j.text()
    }

    public static func fromJson(_ s: String) -> HubSubmission? {
        guard let o = HubMsgWire.parse(s) else { return nil }
        return HubSubmission(
            v: Int(o.int("v") ?? 0), opId: o.string("op_id") ?? "", mid: o.string("mid") ?? "", to: o.string("to") ?? "",
            contentType: o.string("content_type") ?? "", midExpiresAt: o.int("mid_expires_at") ?? 0, expiresAt: o.int("expires_at") ?? 0,
            contentSha256: o.string("content_sha256") ?? "", body: o.string("body") ?? "")
    }
}

/// The Hub's delivery on a recipient's msg/in: the submission's fields and the sender (C3's origin).
public struct HubDelivery: Sendable, Equatable {
    public var v = 1
    public var opId: String
    public var mid: String
    public var from: String
    public var to: String
    public var contentType: String
    public var midExpiresAt: Int64
    public var expiresAt: Int64
    public var contentSha256: String
    public var body: String

    public init(
        v: Int = 1, opId: String, mid: String, from: String, to: String, contentType: String, midExpiresAt: Int64, expiresAt: Int64,
        contentSha256: String, body: String
    ) {
        self.v = v
        self.opId = opId
        self.mid = mid
        self.from = from
        self.to = to
        self.contentType = contentType
        self.midExpiresAt = midExpiresAt
        self.expiresAt = expiresAt
        self.contentSha256 = contentSha256
        self.body = body
    }

    public func toJson() -> String {
        var j = JSONBody()
        j.put("v", v)
        j.put("op_id", opId)
        j.put("mid", mid)
        j.put("from", from)
        j.put("to", to)
        j.put("content_type", contentType)
        j.put("mid_expires_at", midExpiresAt)
        j.put("expires_at", expiresAt)
        j.put("content_sha256", contentSha256)
        j.put("body", body)
        return j.text()
    }

    public static func fromJson(_ s: String) -> HubDelivery? {
        guard let o = HubMsgWire.parse(s) else { return nil }
        return HubDelivery(
            v: Int(o.int("v") ?? 0), opId: o.string("op_id") ?? "", mid: o.string("mid") ?? "", from: o.string("from") ?? "",
            to: o.string("to") ?? "", contentType: o.string("content_type") ?? "", midExpiresAt: o.int("mid_expires_at") ?? 0,
            expiresAt: o.int("expires_at") ?? 0, contentSha256: o.string("content_sha256") ?? "", body: o.string("body") ?? "")
    }
}

/// The recipient's answer on its own msg/ack (C5), naming the origin it committed under.
public struct HubAck: Sendable, Equatable {
    public var v = 1
    public var opId: String
    public var mid: String
    public var from: String
    public var result: String
    public var reason = ""

    public init(v: Int = 1, opId: String, mid: String, from: String, result: String, reason: String = "") {
        self.v = v
        self.opId = opId
        self.mid = mid
        self.from = from
        self.result = result
        self.reason = reason
    }

    public func toJson() -> String {
        var j = JSONBody()
        j.put("v", v)
        j.put("op_id", opId)
        j.put("mid", mid)
        j.put("from", from)
        j.put("result", result)
        j.put("reason", reason)
        return j.text()
    }

    public static func fromJson(_ s: String) -> HubAck? {
        guard let o = HubMsgWire.parse(s) else { return nil }
        return HubAck(
            v: Int(o.int("v") ?? 0), opId: o.string("op_id") ?? "", mid: o.string("mid") ?? "", from: o.string("from") ?? "",
            result: o.string("result") ?? "", reason: o.string("reason") ?? "")
    }
}

/// One piece of evidence about an operation (C6). source is where this phone took it from ("local"
/// for its own broker session, "status_topic" for its msg/status); it is never published.
public struct HubEvent: Sendable, Equatable {
    public var v = 1
    public var source = ""
    public var opId: String
    public var mid = ""
    public var recipient = ""
    public var eventId: String
    public var rev = 0
    public var cls: String
    public var kind: String
    public var reason = ""
    public var authority = ""
    public var scope = ""
    public var detail = ""
    public var at = ""

    public init(
        v: Int = 1, source: String = "", opId: String, mid: String = "", recipient: String = "", eventId: String, rev: Int = 0,
        cls: String, kind: String, reason: String = "", authority: String = "", scope: String = "", detail: String = "", at: String = ""
    ) {
        self.v = v
        self.source = source
        self.opId = opId
        self.mid = mid
        self.recipient = recipient
        self.eventId = eventId
        self.rev = rev
        self.cls = cls
        self.kind = kind
        self.reason = reason
        self.authority = authority
        self.scope = scope
        self.detail = detail
        self.at = at
    }

    public func toJson() -> String {
        var j = JSONBody()
        j.put("v", v)
        j.put("op_id", opId)
        j.put("mid", mid)
        j.put("recipient", recipient)
        j.put("event_id", eventId)
        j.put("rev", rev)
        j.put("class", cls)
        j.put("kind", kind)
        j.put("reason", reason)
        j.put("authority", authority)
        j.put("scope", scope)
        j.put("detail", detail)
        j.put("at", at)
        return j.text()
    }

    static func from(_ o: JSONBody) -> HubEvent {
        HubEvent(
            v: Int(o.int("v") ?? 0), source: o.string("source") ?? "", opId: o.string("op_id") ?? "", mid: o.string("mid") ?? "",
            recipient: o.string("recipient") ?? "", eventId: o.string("event_id") ?? "", rev: Int(o.int("rev") ?? 0),
            cls: o.string("class") ?? "", kind: o.string("kind") ?? "", reason: o.string("reason") ?? "",
            authority: o.string("authority") ?? "", scope: o.string("scope") ?? "", detail: o.string("detail") ?? "",
            at: o.string("at") ?? "")
    }
}

/// The Hub's answer to a submission it did not admit. Not evidence of an operation: no reducer takes it in.
public struct HubRefusal: Sendable, Equatable {
    public var v = 1
    public var opId: String
    public var mid: String
    public var reason: String

    public init(v: Int = 1, opId: String, mid: String, reason: String) {
        self.v = v
        self.opId = opId
        self.mid = mid
        self.reason = reason
    }

    public func toJson() -> String {
        var j = JSONBody()
        j.put("v", v)
        j.put("type", "refusal")
        j.put("op_id", opId)
        j.put("mid", mid)
        j.put("reason", reason)
        return j.text()
    }
}

/// One msg/status payload: an event, or a refusal.
public enum HubStatus: Sendable, Equatable {
    case event(HubEvent)
    case refusal(HubRefusal)

    /// Nil for a payload that is neither (not JSON, not version 1, another type).
    public static func parse(_ payload: String) -> HubStatus? {
        guard let o = HubMsgWire.parse(payload), o.int("v") == 1 else { return nil }
        switch o.string("type") ?? "" {
        case "refusal":
            return .refusal(HubRefusal(opId: o.string("op_id") ?? "", mid: o.string("mid") ?? "", reason: o.string("reason") ?? ""))
        case "":
            // The receiving party annotates where it took the event from.
            var e = HubEvent.from(o)
            e.source = ""
            return .event(e)
        default:
            return nil
        }
    }
}

/// The order-independent reducer of an operation's evidence (C6) and the receipt kinds (C6a), as the
/// Bridge's and the Hub's reducer.go: the set union of the valid events by event id; the state is the
/// strongest class in it; completed and failed together mark a conflict; rev decides nothing.
public enum HubMsgReducer {
    public struct Operation: Sendable, Equatable {
        public var opId: String
        public var mid: String
        public var recipient: String
        public init(opId: String, mid: String, recipient: String) {
            self.opId = opId
            self.mid = mid
            self.recipient = recipient
        }
    }

    public struct Projection: Sendable, Equatable {
        public var state: String
        public var conflict: Bool
        public var failedReasons: [String]
        public var evidence: [String]
        public var rejected: [String]
    }

    struct Kind: Hashable {
        let kind: String, cls: String, authority: String
    }

    /// Which kind may carry which class under which authority (C6a).
    static let allowedKinds: Set<Kind> = [
        Kind(kind: "hub_broker_puback", cls: "accepted", authority: "local"),
        Kind(kind: "hub_forwarded", cls: "forwarded", authority: "hub"),
        Kind(kind: "recipient_app_stored", cls: "completed", authority: "recipient"),
        Kind(kind: "recipient_refused", cls: "failed", authority: "recipient"),
        Kind(kind: "recipient_refused", cls: "expired", authority: "recipient"),
        Kind(kind: "hub_refused", cls: "failed", authority: "hub"),
        Kind(kind: "hub_expired", cls: "expired", authority: "hub"),
        Kind(kind: "hub_unknown", cls: "unknown", authority: "hub"),
        Kind(kind: "recipient_busy", cls: "unknown", authority: "recipient"),
    ]

    /// Where evidence of each authority may come from.
    static let sourceOf: [String: String] = ["local": "local", "hub": "status_topic", "recipient": "status_topic"]

    /// The strength of the classes, strongest first.
    public static let projectionOrder = ["completed", "failed", "expired", "forwarded", "unknown", "accepted", "pending"]

    /// Whether e may join op's evidence.
    public static func valid(_ op: Operation, _ e: HubEvent) -> Bool {
        e.opId == op.opId && e.mid == op.mid && e.recipient == op.recipient
            && allowedKinds.contains(Kind(kind: e.kind, cls: e.cls, authority: e.authority))
            && sourceOf[e.authority] != nil && sourceOf[e.authority] == e.source && HubMsgIds.validV7(e.eventId)
    }

    public static func reduce(_ op: Operation, _ events: [HubEvent]) -> Projection {
        var held: [String: HubEvent] = [:]
        var rejected: Set<String> = []
        for e in events {
            if valid(op, e) {
                if held[e.eventId] == nil { held[e.eventId] = e }
            } else {
                rejected.insert(e.eventId)
            }
        }
        let classes = Set(held.values.map(\.cls))
        let reasons = Set(held.values.filter { ($0.cls == "failed" || $0.cls == "expired") && !$0.reason.isEmpty }.map(\.reason))
        let state = projectionOrder.first { classes.contains($0) } ?? "pending"
        return Projection(
            state: state, conflict: classes.contains("completed") && classes.contains("failed"), failedReasons: reasons.sorted(),
            evidence: held.keys.sorted(), rejected: rejected.filter { held[$0] == nil }.sorted())
    }
}
