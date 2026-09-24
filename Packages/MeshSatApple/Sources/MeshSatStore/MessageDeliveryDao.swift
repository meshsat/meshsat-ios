// Mirrors data/MessageDeliveryDao.kt: the delivery ledger's queries, the same SQL.
import Foundation
import GRDB
import MeshSatEngine

public struct MessageDeliveryDao: Sendable {
    let db: any DatabaseWriter

    @discardableResult
    public func insert(_ delivery: MessageDelivery) async throws -> Int64 {
        try await db.write { db in
            var d = delivery
            try d.insert(db)
            return d.id ?? 0
        }
    }

    public func getById(_ id: Int64) async throws -> MessageDelivery? {
        try await db.read { db in try MessageDelivery.fetchOne(db, sql: "SELECT * FROM message_deliveries WHERE id = ?", arguments: [id]) }
    }

    public func getPending(channel: String, now: Int64, limit: Int = 10) async throws -> [MessageDelivery] {
        try await db.read { db in
            try MessageDelivery.fetchAll(
                db,
                sql: """
                    SELECT * FROM message_deliveries
                    WHERE channel = ? AND status IN ('queued', 'retry')
                      AND (next_retry IS NULL OR next_retry <= ?)
                      AND (priority = 0 OR expires_at IS NULL OR expires_at > ?)
                    ORDER BY priority ASC, created_at ASC
                    LIMIT ?
                    """,
                arguments: [channel, now, now, limit])
        }
    }

    public func setStatus(id: Int64, _ status: String, lastError: String = "", now: Int64 = nowMs()) async throws {
        try await db.write { db in
            try db.execute(
                sql: "UPDATE message_deliveries SET status = ?, last_error = ?, updated_at = ? WHERE id = ?",
                arguments: [status, lastError, now, id])
        }
    }

    public func scheduleRetry(id: Int64, retries: Int, nextRetry: Int64, lastError: String, now: Int64 = nowMs()) async throws {
        try await db.write { db in
            try db.execute(
                sql:
                    """
                    UPDATE message_deliveries SET status = 'retry', retries = ?, next_retry = ?, last_error = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [retries, nextRetry, lastError, now, id])
        }
    }

    /// Wait until `nextRetry` without counting a try: the channel could not take it just now.
    public func deferRetry(id: Int64, nextRetry: Int64, lastError: String, now: Int64 = nowMs()) async throws {
        try await db.write { db in
            try db.execute(
                sql: "UPDATE message_deliveries SET status = 'retry', next_retry = ?, last_error = ?, updated_at = ? WHERE id = ?",
                arguments: [nextRetry, lastError, now, id])
        }
    }

    public func cancel(id: Int64, now: Int64 = nowMs()) async throws {
        try await db.write { db in
            try db.execute(
                sql:
                    """
                    UPDATE message_deliveries SET status = 'dead', last_error = 'cancelled', updated_at = ? WHERE id = ?
                    AND status IN ('queued', 'retry')
                    """,
                arguments: [now, id])
        }
    }

    public func retryNow(id: Int64, now: Int64 = nowMs()) async throws {
        try await db.write { db in
            try db.execute(
                sql:
                    """
                    UPDATE message_deliveries SET status = 'queued', next_retry = NULL, updated_at = ? WHERE id = ?
                    AND status IN ('failed', 'dead')
                    """,
                arguments: [now, id])
        }
    }

    /// Cancel a delivery that is still waiting, including one on hold until its link is back
    /// (MESHSAT-1249). Returns the rows changed: 0 when it was sent or stopped in the meantime.
    @discardableResult
    public func cancelWaiting(id: Int64, now: Int64 = nowMs()) async throws -> Int {
        try await db.write { db in
            try db.execute(
                sql:
                    """
                    UPDATE message_deliveries SET status = 'dead', last_error = 'cancelled', held_at = NULL, updated_at = ?
                    WHERE id = ? AND status IN ('queued', 'retry', 'held')
                    """,
                arguments: [now, id])
            return db.changesCount
        }
    }

    public func queueDepth(channel: String) async throws -> Int {
        try await db.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM message_deliveries WHERE channel = ? AND status IN ('queued', 'retry', 'held', 'sending')",
                arguments: [channel]) ?? 0
        }
    }

    public func queueBytes(channel: String) async throws -> Int64 {
        try await db.read { db in
            try Int64.fetchOne(
                db,
                sql:
                    """
                    SELECT COALESCE(SUM(LENGTH(payload)), 0) FROM message_deliveries WHERE channel = ?
                    AND status IN ('queued', 'retry', 'held', 'sending')
                    """,
                arguments: [channel]) ?? 0
        }
    }

    @discardableResult
    public func expireDeliveries(now: Int64 = nowMs()) async throws -> Int {
        try await db.write { db in
            try db.execute(
                sql: """
                    UPDATE message_deliveries SET status = 'expired', updated_at = ?
                    WHERE status IN ('queued', 'retry') AND expires_at IS NOT NULL AND expires_at <= ? AND priority > 0
                    """,
                arguments: [now, now])
            return db.changesCount
        }
    }

    /// Hold deliveries for a channel going offline; held_at pauses the TTL clock.
    @discardableResult
    public func holdForChannel(_ channel: String, now: Int64 = nowMs()) async throws -> Int {
        try await db.write { db in
            try db.execute(
                sql:
                    """
                    UPDATE message_deliveries SET status = 'held', held_at = ?, updated_at = ? WHERE channel = ?
                    AND status IN ('queued', 'retry')
                    """,
                arguments: [now, now, channel])
            return db.changesCount
        }
    }

    /// Unhold when the channel comes back: expires_at moves by the time spent held.
    @discardableResult
    public func unholdForChannel(_ channel: String, now: Int64 = nowMs()) async throws -> Int {
        try await db.write { db in
            try db.execute(
                sql: """
                    UPDATE message_deliveries
                    SET status = 'queued',
                        expires_at = CASE
                            WHEN expires_at IS NOT NULL AND held_at IS NOT NULL
                            THEN expires_at + (? - held_at)
                            ELSE expires_at
                        END,
                        held_at = NULL,
                        updated_at = ?
                    WHERE channel = ? AND status = 'held'
                    """,
                arguments: [now, now, channel])
            return db.changesCount
        }
    }

    @discardableResult
    public func cancelRunaway(safetyLimit: Int = MessageDelivery.runawaySafetyLimit, now: Int64 = nowMs()) async throws -> Int {
        try await db.write { db in
            try db.execute(
                sql: """
                    UPDATE message_deliveries SET status = 'dead', last_error = 'cancelled: exceeded retry limit', updated_at = ?
                    WHERE status IN ('queued', 'retry')
                      AND ((max_retries > 0 AND retries >= max_retries) OR (max_retries = 0 AND retries >= ?))
                    """,
                arguments: [now, safetyLimit])
            return db.changesCount
        }
    }

    /// Make every waiting retry of `channel` due now: the interface has just come online.
    @discardableResult
    public func retryNowForChannel(_ channel: String, now: Int64 = nowMs()) async throws -> Int {
        try await db.write { db in
            try db.execute(
                sql: "UPDATE message_deliveries SET next_retry = ?, updated_at = ? WHERE channel = ? AND status = 'retry'",
                arguments: [now, now, channel])
            return db.changesCount
        }
    }

    @discardableResult
    public func recoverStale(now: Int64 = nowMs()) async throws -> Int {
        try await db.write { db in
            try db.execute(
                sql:
                    """
                    UPDATE message_deliveries
                    SET status = 'retry', last_error = 'recovered after restart', next_retry = ?, updated_at = ?
                    WHERE status = 'sending'
                    """,
                arguments: [now, now])
            return db.changesCount
        }
    }

    /// The satellite session ("imei:momsn") a delivery went out in (MESHSAT-1246).
    public func setSatRef(id: Int64, _ ref: String, now: Int64 = nowMs()) async throws {
        try await db.write { db in
            try db.execute(sql: "UPDATE message_deliveries SET sat_ref = ?, updated_at = ? WHERE id = ?", arguments: [ref, now, id])
        }
    }

    public func getBySatRef(_ ref: String) async throws -> [MessageDelivery] {
        try await db.read { db in
            try MessageDelivery.fetchAll(db, sql: "SELECT * FROM message_deliveries WHERE sat_ref = ?", arguments: [ref])
        }
    }

    /// The far end confirmed it: the Hub's receipt for a satellite session, or an SMS report.
    @discardableResult
    public func markAckedBySatRef(_ ref: String, now: Int64 = nowMs()) async throws -> Int {
        try await db.write { db in
            try db.execute(
                sql: "UPDATE message_deliveries SET ack_status = 'acked', ack_timestamp = ?, updated_at = ? WHERE sat_ref = ?",
                arguments: [now, now, ref])
            return db.changesCount
        }
    }

    @discardableResult
    public func markAcked(id: Int64, now: Int64 = nowMs()) async throws -> Int {
        try await db.write { db in
            try db.execute(
                sql: "UPDATE message_deliveries SET ack_status = 'acked', ack_timestamp = ?, updated_at = ? WHERE id = ?",
                arguments: [now, now, id])
            return db.changesCount
        }
    }

    /// The deliveries of one SOS (msg_ref "sos:<run>:..."), for its result screen (MESHSAT-1249).
    public func observeByRefPrefix(_ prefix: String) -> AsyncValueObservation<[MessageDelivery]> {
        ValueObservation.tracking { db in
            try MessageDelivery.fetchAll(
                db, sql: "SELECT * FROM message_deliveries WHERE msg_ref LIKE ? || '%' ORDER BY created_at ASC, id ASC", arguments: [prefix]
            )
        }.values(in: db)
    }

    public func getByRefPrefix(_ prefix: String) async throws -> [MessageDelivery] {
        try await db.read { db in
            try MessageDelivery.fetchAll(
                db, sql: "SELECT * FROM message_deliveries WHERE msg_ref LIKE ? || '%' ORDER BY created_at ASC, id ASC", arguments: [prefix]
            )
        }
    }

    /// Stop every delivery of one SOS that has not gone out yet.
    @discardableResult
    public func cancelWaitingByRefPrefix(_ prefix: String, now: Int64 = nowMs()) async throws -> Int {
        try await db.write { db in
            try db.execute(
                sql:
                    """
                    UPDATE message_deliveries SET status = 'dead', last_error = 'cancelled', held_at = NULL, updated_at = ?
                    WHERE msg_ref LIKE ? || '%' AND status IN ('queued', 'retry', 'held')
                    """,
                arguments: [now, prefix])
            return db.changesCount
        }
    }

    public func getRecent(limit: Int = 100) -> AsyncValueObservation<[MessageDelivery]> {
        ValueObservation.tracking { db in
            try MessageDelivery.fetchAll(db, sql: "SELECT * FROM message_deliveries ORDER BY created_at DESC LIMIT ?", arguments: [limit])
        }.values(in: db)
    }

    public func getRecentSync(limit: Int = 50) async throws -> [MessageDelivery] {
        try await db.read { db in
            try MessageDelivery.fetchAll(db, sql: "SELECT * FROM message_deliveries ORDER BY created_at DESC LIMIT ?", arguments: [limit])
        }
    }

    public func stats() async throws -> [DeliveryStatRow] {
        try await db.read { db in
            try DeliveryStatRow.fetchAll(
                db, sql: "SELECT channel, status, COUNT(*) as cnt FROM message_deliveries GROUP BY channel, status ORDER BY channel, status"
            )
        }
    }

    // MARK: Sequence numbers and ACK tracking (Phase C)

    public func setSeqNum(id: Int64, _ seqNum: Int64, now: Int64 = nowMs()) async throws {
        try await db.write { db in
            try db.execute(sql: "UPDATE message_deliveries SET seq_num = ?, updated_at = ? WHERE id = ?", arguments: [seqNum, now, id])
        }
    }

    public func setAckPending(id: Int64, now: Int64 = nowMs()) async throws {
        try await db.write { db in
            try db.execute(
                sql: "UPDATE message_deliveries SET ack_status = 'pending', ack_timestamp = ?, updated_at = ? WHERE id = ?",
                arguments: [now, now, id])
        }
    }

    /// ACKed: promotes the status to 'delivered'.
    public func setAcked(id: Int64, now: Int64 = nowMs()) async throws {
        try await db.write { db in
            try db.execute(
                sql:
                    """
                    UPDATE message_deliveries SET ack_status = 'acked', ack_timestamp = ?, status = 'delivered', updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [now, now, id])
        }
    }

    public func setNacked(id: Int64, now: Int64 = nowMs()) async throws {
        try await db.write { db in
            try db.execute(
                sql: "UPDATE message_deliveries SET ack_status = 'nacked', ack_timestamp = ?, updated_at = ? WHERE id = ?",
                arguments: [now, now, id])
        }
    }

    public func getPendingAcks(channel: String, cutoff: Int64) async throws -> [MessageDelivery] {
        try await db.read { db in
            try MessageDelivery.fetchAll(
                db,
                sql: """
                    SELECT * FROM message_deliveries
                    WHERE channel = ? AND ack_status = 'pending'
                      AND ack_timestamp IS NOT NULL AND ack_timestamp <= ?
                    ORDER BY created_at ASC
                    """,
                arguments: [channel, cutoff])
        }
    }

    @discardableResult
    public func timeoutPendingAcks(cutoff: Int64, now: Int64 = nowMs()) async throws -> Int {
        try await db.write { db in
            try db.execute(
                sql: """
                    UPDATE message_deliveries
                    SET ack_status = 'timeout', updated_at = ?
                    WHERE ack_status = 'pending' AND ack_timestamp IS NOT NULL AND ack_timestamp <= ?
                    """,
                arguments: [now, cutoff])
            return db.changesCount
        }
    }

    public func getByChannelAndSeq(channel: String, seqNum: Int64) async throws -> MessageDelivery? {
        try await db.read { db in
            try MessageDelivery.fetchOne(
                db, sql: "SELECT * FROM message_deliveries WHERE channel = ? AND seq_num = ? AND seq_num > 0 LIMIT 1",
                arguments: [channel, seqNum])
        }
    }

    // MARK: Health scorer (Phase D)

    public func countSentSince(channel: String, since: Int64) async throws -> Int {
        try await db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM message_deliveries WHERE channel = ? AND status IN ('sent', 'delivered') AND created_at >= ?",
                arguments: [channel, since]) ?? 0
        }
    }

    public func countFailedSince(channel: String, since: Int64) async throws -> Int {
        try await db.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM message_deliveries WHERE channel = ? AND status IN ('failed', 'dead') AND created_at >= ?",
                arguments: [channel, since]) ?? 0
        }
    }

    public func avgLatencyMsSince(channel: String, since: Int64) async throws -> Int64 {
        try await db.read { db in
            try Int64.fetchOne(
                db,
                sql:
                    """
                    SELECT COALESCE(AVG(updated_at - created_at), 0) FROM message_deliveries WHERE channel = ?
                    AND status IN ('sent', 'delivered') AND created_at >= ?
                    """,
                arguments: [channel, since]) ?? 0
        }
    }
}
