// Mirrors hubmsg/HubMsgInbox.kt: the receiver's inbox (C3), as the Bridge's inbox.go: what a
// delivery on this phone's msg/in commits, and what the phone answers on its msg/ack. The commit
// key is (origin, op_id), with an index (origin, mid); the message is stored once per (origin,
// mid). On the phone the stored message is the chat row: it goes in the transaction that commits
// the operation. [MESHSAT-1584]
import Foundation

public enum HubMsgInbox {
    /// The clock skew a commit allows past an operation's deadline.
    public static let skewMs: Int64 = 120_000

    /// How long after deadline plus skew an entry is kept, so a late repeat is acknowledged, not refused.
    public static let retentionAfterExpiryMs: Int64 = 24 * 60 * 60 * 1000

    /// The target number of live entries: at it, with nothing past its retention, a new one is refused receiver_busy.
    public static let capacity = 50_000

    public struct Entry: Sendable, Equatable {
        public var origin: String
        public var opId: String
        public var mid: String
        public var recipient: String
        public var contentType: String
        public var midExpiresAt: Int64
        public var expiresAt: Int64
        public var contentSha256: String
        /// The stored message's row; operations of one (origin, mid) share it.
        public var messageId: Int64 = 0
        public var committedAt: Int64
        public var withinSkew = false
        public var unjudged = false

        public init(
            origin: String, opId: String, mid: String, recipient: String, contentType: String, midExpiresAt: Int64, expiresAt: Int64,
            contentSha256: String, messageId: Int64 = 0, committedAt: Int64, withinSkew: Bool = false, unjudged: Bool = false
        ) {
            self.origin = origin
            self.opId = opId
            self.mid = mid
            self.recipient = recipient
            self.contentType = contentType
            self.midExpiresAt = midExpiresAt
            self.expiresAt = expiresAt
            self.contentSha256 = contentSha256
            self.messageId = messageId
            self.committedAt = committedAt
            self.withinSkew = withinSkew
            self.unjudged = unjudged
        }
    }

    /// The inbox inside one transaction: commit's reads and its write are atomic.
    public protocol Transaction {
        func byOp(origin: String, opId: String) throws -> Entry?
        func byMid(origin: String, mid: String) throws -> Entry?
        func count() throws -> Int
        /// Deletes the entries whose deadline plus skew plus retention is before nowMs; returns how many.
        func pruneBefore(_ nowMs: Int64) throws -> Int
        /// Writes e; with store it also stores the message (body) and returns the entry with its row.
        func insert(_ e: Entry, store: Bool, body: String) throws -> Entry
    }

    public struct Answer: Sendable, Equatable {
        public var result: String
        public var reason = ""
        public var storedNow = false
        public var withinSkew = false
        public var unjudged = false
        /// The stored message's row on a stored answer.
        public var messageId: Int64 = 0

        public init(
            result: String, reason: String = "", storedNow: Bool = false, withinSkew: Bool = false, unjudged: Bool = false,
            messageId: Int64 = 0
        ) {
            self.result = result
            self.reason = reason
            self.storedNow = storedNow
            self.withinSkew = withinSkew
            self.unjudged = unjudged
            self.messageId = messageId
        }
    }

    private static func refused(_ reason: String) -> Answer { Answer(result: "refused", reason: reason) }

    /// Decides one delivery in the contract's order (C3): valid ids, the digest recomputed from the
    /// delivered fields, the deadline within the message's, a known (origin, op_id), a known (origin,
    /// mid), the deadline at commit, the capacity. Without clockEstablished the deadline is not
    /// judged: a wrong clock must not drop messages. capacity <= 0 is the default.
    public static func commit(
        _ tx: Transaction, _ d: HubDelivery, nowMs: Int64, clockEstablished: Bool, capacity limit: Int = HubMsgInbox.capacity
    ) throws -> Answer {
        let cap = limit <= 0 ? capacity : limit
        if !HubMsgIds.validV7(d.opId) || !HubMsgIds.validV7(d.mid) { return refused("bad_id") }
        let digest = HubMsgDigest.sha256Hex(
            mid: d.mid, recipient: d.to, contentType: d.contentType, midExpiresAt: d.midExpiresAt, body: Array(d.body.utf8))
        if digest == nil || digest != d.contentSha256 { return refused("digest_mismatch") }
        if d.expiresAt > d.midExpiresAt { return refused("bad_expiry") }
        if let e = try tx.byOp(origin: d.from, opId: d.opId) {
            // Committed before: acknowledged again, after its deadline too (it was in time).
            return e.mid == d.mid && e.contentSha256 == d.contentSha256
                ? Answer(result: "stored", messageId: e.messageId) : refused("op_conflict")
        }
        let known = try tx.byMid(origin: d.from, mid: d.mid)
        // Never an acknowledgement of the stored message for another payload.
        if let k = known, k.contentSha256 != d.contentSha256 { return refused("mid_conflict") }
        var withinSkew = false
        var unjudged = false
        if !clockEstablished {
            unjudged = true
        } else if nowMs > d.expiresAt + skewMs {
            return refused("expired_at_recipient")
        } else if nowMs > d.expiresAt {
            withinSkew = true
        }
        if try tx.count() >= cap {
            // An entry past its retention goes first; a live entry is never evicted.
            _ = try tx.pruneBefore(nowMs)
            if try tx.count() >= cap { return refused("receiver_busy") }
        }
        let store = known == nil
        let entry = Entry(
            origin: d.from, opId: d.opId, mid: d.mid, recipient: d.to, contentType: d.contentType, midExpiresAt: d.midExpiresAt,
            expiresAt: d.expiresAt, contentSha256: d.contentSha256, messageId: known?.messageId ?? 0, committedAt: nowMs,
            withinSkew: withinSkew, unjudged: unjudged)
        let kept = try tx.insert(entry, store: store, body: d.body)
        return Answer(result: "stored", storedNow: store, withinSkew: withinSkew, unjudged: unjudged, messageId: kept.messageId)
    }

    /// When an entry with this deadline may go.
    public static func retainedUntil(_ expiresAt: Int64) -> Int64 { expiresAt + skewMs + retentionAfterExpiryMs }
}
