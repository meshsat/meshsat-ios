// Mirrors hubmsg/HubMsgStore.kt: what the Hub app route keeps (contract C3-C6, A11-A15; the
// Bridge's hub_ops, hub_op_events, hub_op_missing and hub_inbox). On the phone the chat row is the
// ledger: an event is kept and the row's delivery status recomputed from every kept event in one
// transaction, so an event can never be kept without the status taking it in. [MESHSAT-1584]
import Foundation

/// One operation this phone publishes on its msg/out.
public struct HubOp: Sendable, Equatable {
    public var opId: String
    public var mid: String
    public var recipient: String
    /// The chat row it is the delivery of.
    public var messageId: Int64
    public var expiresAt: Int64
    public var createdAt: Int64
    /// The payload published, kept to publish again unchanged: a repeat asks for every event again (C4).
    public var submission: String
    /// When the broker took it (PUBACK), 0 before.
    public var publishedAt: Int64 = 0
    /// When an event of it was first found missing, 0 when none is.
    public var replayAt: Int64 = 0
    /// When this phone stopped asking at the bound, 0 while it asks.
    public var replayGivenUpAt: Int64 = 0

    public init(
        opId: String, mid: String, recipient: String, messageId: Int64, expiresAt: Int64, createdAt: Int64, submission: String,
        publishedAt: Int64 = 0, replayAt: Int64 = 0, replayGivenUpAt: Int64 = 0
    ) {
        self.opId = opId
        self.mid = mid
        self.recipient = recipient
        self.messageId = messageId
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.submission = submission
        self.publishedAt = publishedAt
        self.replayAt = replayAt
        self.replayGivenUpAt = replayGivenUpAt
    }
}

/// An event as kept: the first copy under its id decides what it says and whether it is valid.
public struct KeptHubEvent: Sendable, Equatable {
    public var event: HubEvent
    public var valid: Bool
    public var added: Bool
    public init(event: HubEvent, valid: Bool, added: Bool) {
        self.event = event
        self.valid = valid
        self.added = added
    }
}

/// A position in a listing of operations: the sort key and the op id of the last one taken, zero for the start.
public struct HubOpCursor: Sendable, Equatable {
    public var key: Int64 = 0
    public var opId = ""
    public init(key: Int64 = 0, opId: String = "") {
        self.key = key
        self.opId = opId
    }
}

public protocol HubMsgStore: Sendable {
    // MARK: The sender

    /// One transaction: the chat row (status queued) and the operation. Returns the chat row.
    func createOutgoing(_ op: HubOp, sender: String, text: String) async throws -> Int64
    func op(_ opId: String) async throws -> HubOp?
    /// The operations the broker has not taken yet, oldest first.
    func unpublished(limit: Int) async throws -> [HubOp]
    /// One transaction: published_at (once) and the chat row's status recomputed.
    func markPublished(_ opId: String, atMs: Int64) async throws
    /// One transaction: the event kept once per event id; the chat row's status recomputed from the
    /// operation's kept events; the obligations the event ends (its own id, and every obligation of
    /// the operation for a valid completion, C6's strongest class). Returns the event as kept.
    func keepEvent(_ e: HubEvent, valid: Bool, atMs: Int64) async throws -> KeptHubEvent
    /// One transaction: replay_at (when first owed) and the missing event named. Nothing for an operation not kept.
    func wantReplay(_ opId: String, eventId: String, atMs: Int64) async throws
    /// Ends the obligations whose event is kept by now, and those of completed operations.
    func resolveKeptMissing() async throws -> Int
    func eventKept(_ eventId: String) async throws -> Bool
    func completed(_ opId: String) async throws -> Bool
    func missing(_ opId: String) async throws -> [String]
    /// After `after`, by (replay_at, op_id): an event still missing (not one kept by now), not given up, inside the bound.
    func owed(nowMs: Int64, withinMs: Int64, after: HubOpCursor, limit: Int) async throws -> [HubOp]
    /// After `after`, by (created_at, op_id): a kept submission, no completion, not given up, inside the bound.
    func toReconcile(nowMs: Int64, withinMs: Int64, after: HubOpCursor, limit: Int) async throws -> [HubOp]
    /// Past the bound, no completion, not given up: an event still missing, or no outcome kept at all.
    func toGiveUp(nowMs: Int64, withinMs: Int64, limit: Int) async throws -> [HubOp]
    /// One transaction: given up, and the chat row's status recomputed. Its obligations stay.
    func giveUp(_ opId: String, atMs: Int64) async throws
    /// Deletes the operations, with their events and obligations, past their deadline plus the inbox's retention.
    func pruneOps(nowMs: Int64) async throws -> Int

    // MARK: The receiver

    /// One transaction (C3): the inbox entry and, for a message not stored before, its chat row.
    func commitDelivery(_ d: HubDelivery, nowMs: Int64, clockEstablished: Bool, capacity: Int) async throws -> HubMsgInbox.Answer
    func pruneInbox(nowMs: Int64) async throws -> Int
}

/// The delivery status a chat row shows, from what this phone keeps of its operation: the C6
/// projection of the valid Hub events; the Hub's refusal (a record, not evidence, so no reducer
/// takes it in) only when no event says more; the broker's PUBACK; the bound. Stored in the
/// message's forwardedTo.
public enum HubMsgStatus {
    public static let queued = "hub:queued"
    public static let accepted = "hub:accepted"
    public static let forwarded = "hub:forwarded"
    public static let busy = "hub:busy"
    public static let delivered = "hub:delivered"
    public static let expired = "hub:expired"
    public static let unknown = "hub:unknown"
    public static let failedPrefix = "hub:failed:"
    public static let refusedPrefix = "hub:refused:"

    /// A refusal is kept among the events under this id: one per reason. A Hub event id is a UUID, never this.
    public static func refusalEventId(_ opId: String, _ reason: String) -> String { "refusal:\(opId):\(reason)" }
    public static func isRefusal(_ e: HubEvent) -> Bool { e.eventId.hasPrefix("refusal:") }

    public static func of(_ op: HubOp, _ kept: [KeptHubEvent]) -> String {
        let operation = HubMsgReducer.Operation(opId: op.opId, mid: op.mid, recipient: op.recipient)
        let events = kept.filter { $0.valid && !isRefusal($0.event) }.map(\.event)
        let p = HubMsgReducer.reduce(operation, events)
        switch p.state {
        case "completed": return delivered
        case "failed": return failedPrefix + p.failedReasons.joined(separator: ",")
        case "expired": return expired
        default: break
        }
        if op.replayGivenUpAt > 0 { return unknown }
        switch p.state {
        case "forwarded": return forwarded
        case "unknown": return busy
        default: break
        }
        if let r = kept.first(where: { $0.valid && isRefusal($0.event) }) { return refusedPrefix + r.event.reason }
        return op.publishedAt > 0 ? accepted : queued
    }
}
