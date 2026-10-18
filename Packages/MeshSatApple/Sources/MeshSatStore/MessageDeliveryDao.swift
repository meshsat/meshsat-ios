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

    /// What the worker may send now. Never a delivery the far end has confirmed (FE-R4, below).
    public func getPending(channel: String, now: Int64, limit: Int = 10) async throws -> [MessageDelivery] {
        try await db.read { db in
            try MessageDelivery.fetchAll(
                db,
                sql: """
                    SELECT * FROM message_deliveries
                    WHERE channel = ? AND status IN ('queued', 'retry')
                      AND (next_retry IS NULL OR next_retry <= ?)
                      AND (priority = 0 OR expires_at IS NULL OR expires_at > ?)
                      AND COALESCE(ack_status, '') != 'acked'
                    ORDER BY priority ASC, created_at ASC
                    LIMIT ?
                    """,
                arguments: [channel, now, now, limit])
        }
    }

    /// A status by id alone (the composer lane's sent and declined); the delivery worker writes through the guarded calls below.
    public func setStatus(id: Int64, _ status: String, lastError: String = "", now: Int64 = MeshSatStore.nowMs()) async throws {
        try await db.write { db in
            try db.execute(
                sql: "UPDATE message_deliveries SET status = ?, last_error = ?, updated_at = ? WHERE id = ?",
                arguments: [status, lastError, now, id])
        }
    }

    // MARK: The delivery worker's writes (review 2026-10-18 23:31, FE-R4, MESHSAT-1584)
    //
    // As MessageDeliveryDao.kt: a confirmation (an ACK, the Hub's satellite receipt) can commit at
    // any moment while a send is in flight. The worker takes a row in one statement (claimForSend)
    // and every later write of that send matches only a row that is still 'sending'. Every
    // confirmation moves the row out of 'sending' in its own statement (setAcked,
    // markAckedBySatRef), so a confirmed delivery is never set back to sent, pending, retry or dead.
    // No transaction is held while a send waits for the modem.

    /// Take a waiting delivery for one send. 0 when it is no longer waiting (confirmed, cancelled,
    /// held or taken since it was read); then nothing is sent.
    @discardableResult
    public func claimForSend(id: Int64, now: Int64 = MeshSatStore.nowMs()) async throws -> Int {
        try await db.write { db in
            try db.execute(
                sql: """
                    UPDATE message_deliveries SET status = 'sending', updated_at = ?
                    WHERE id = ? AND status IN ('queued', 'retry') AND COALESCE(ack_status, '') != 'acked'
                    """,
                arguments: [now, id])
            return db.changesCount
        }
    }

    /// The send went out: sent, its sequence number and, when `ackPending`, the wait for its ACK,
    /// in one statement. 0 when a confirmation came in first; it stays.
    @discardableResult
    public func markSent(id: Int64, seqNum: Int64, ackPending: Bool, now: Int64 = MeshSatStore.nowMs()) async throws -> Int {
        try await db.write { db in
            let wait = ackPending ? 1 : 0
            try db.execute(
                sql: """
                    UPDATE message_deliveries
                    SET status = 'sent', seq_num = ?, last_error = '',
                        ack_status = CASE WHEN ? AND COALESCE(ack_status, '') != 'acked' THEN 'pending' ELSE ack_status END,
                        ack_timestamp = CASE WHEN ? AND COALESCE(ack_status, '') != 'acked' THEN ? ELSE ack_timestamp END,
                        updated_at = ?
                    WHERE id = ? AND status = 'sending'
                    """,
                arguments: [seqNum, wait, wait, now, now, id])
            return db.changesCount
        }
    }

    /// A waiting delivery stops before it is sent ('dead' when cancelled, 'denied', 'expired', or
    /// parked for the user). 0 when it was confirmed, cancelled or taken since it was read.
    @discardableResult
    public func dropWaiting(id: Int64, _ status: String, lastError: String, now: Int64 = MeshSatStore.nowMs()) async throws -> Int {
        try await db.write { db in
            try db.execute(
                sql: """
                    UPDATE message_deliveries SET status = ?, last_error = ?, updated_at = ?
                    WHERE id = ? AND status IN ('queued', 'retry') AND COALESCE(ack_status, '') != 'acked'
                    """,
                arguments: [status, lastError, now, id])
            return db.changesCount
        }
    }

    /// This send ends for good ('dead'). 0 when it was confirmed meanwhile.
    @discardableResult
    public func finishSend(id: Int64, _ status: String, lastError: String, now: Int64 = MeshSatStore.nowMs()) async throws -> Int {
        try await db.write { db in
            try db.execute(
                sql: "UPDATE message_deliveries SET status = ?, last_error = ?, updated_at = ? WHERE id = ? AND status = 'sending'",
                arguments: [status, lastError, now, id])
            return db.changesCount
        }
    }

    /// This send failed and is tried again at `nextRetry`. 0 when it was confirmed meanwhile: no retry.
    @discardableResult
    public func scheduleRetry(id: Int64, retries: Int, nextRetry: Int64, lastError: String, now: Int64 = MeshSatStore.nowMs()) async throws
        -> Int
    {
        try await db.write { db in
            try db.execute(
                sql:
                    """
                    UPDATE message_deliveries SET status = 'retry', retries = ?, next_retry = ?, last_error = ?, updated_at = ?
                    WHERE id = ? AND status = 'sending'
                    """,
                arguments: [retries, nextRetry, lastError, now, id])
            return db.changesCount
        }
    }

    /// Wait until `nextRetry` without counting a try: the channel could not take it just now. 0
    /// when it was confirmed meanwhile.
    @discardableResult
    public func deferRetry(id: Int64, nextRetry: Int64, lastError: String, now: Int64 = MeshSatStore.nowMs()) async throws -> Int {
        try await db.write { db in
            try db.execute(
                sql: """
                    UPDATE message_deliveries SET status = 'retry', next_retry = ?, last_error = ?, updated_at = ?
                    WHERE id = ? AND status = 'sending'
                    """,
                arguments: [nextRetry, lastError, now, id])
            return db.changesCount
        }
    }

    /// A confirmed delivery left waiting by a worker from before FE-R4 is sent, not sent again.
    /// Sent is the claim that certainly holds; ack_status keeps the confirmation. Runs at start.
    @discardableResult
    public func settleConfirmed(now: Int64 = MeshSatStore.nowMs()) async throws -> Int {
        try await db.write { db in
            try db.execute(
                sql: """
                    UPDATE message_deliveries SET status = 'sent', next_retry = NULL, updated_at = ?
                    WHERE COALESCE(ack_status, '') = 'acked' AND status IN ('queued', 'retry', 'held', 'sending')
                    """,
                arguments: [now])
            return db.changesCount
        }
    }

    public func cancel(id: Int64, now: Int64 = MeshSatStore.nowMs()) async throws {
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

    public func retryNow(id: Int64, now: Int64 = MeshSatStore.nowMs()) async throws {
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
    public func cancelWaiting(id: Int64, now: Int64 = MeshSatStore.nowMs()) async throws -> Int {
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
    public func expireDeliveries(now: Int64 = MeshSatStore.nowMs()) async throws -> Int {
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
    public func holdForChannel(_ channel: String, now: Int64 = MeshSatStore.nowMs()) async throws -> Int {
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
    public func unholdForChannel(_ channel: String, now: Int64 = MeshSatStore.nowMs()) async throws -> Int {
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
    public func cancelRunaway(safetyLimit: Int = MessageDelivery.runawaySafetyLimit, now: Int64 = MeshSatStore.nowMs()) async throws -> Int
    {
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
    public func retryNowForChannel(_ channel: String, now: Int64 = MeshSatStore.nowMs()) async throws -> Int {
        try await db.write { db in
            try db.execute(
                sql: "UPDATE message_deliveries SET next_retry = ?, updated_at = ? WHERE channel = ? AND status = 'retry'",
                arguments: [now, now, channel])
            return db.changesCount
        }
    }

    @discardableResult
    public func recoverStale(now: Int64 = MeshSatStore.nowMs()) async throws -> Int {
        try await db.write { db in
            try db.execute(
                sql:
                    """
                    UPDATE message_deliveries
                    SET status = 'retry', last_error = 'recovered after restart', next_retry = ?, updated_at = ?
                    WHERE status = 'sending' AND COALESCE(ack_status, '') != 'acked'
                    """,
                arguments: [now, now])
            return db.changesCount
        }
    }

    /// The satellite session ("imei:momsn") a delivery went out in (MESHSAT-1246).
    public func setSatRef(id: Int64, _ ref: String, now: Int64 = MeshSatStore.nowMs()) async throws {
        try await db.write { db in
            try db.execute(sql: "UPDATE message_deliveries SET sat_ref = ?, updated_at = ? WHERE id = ?", arguments: [ref, now, id])
        }
    }

    public func getBySatRef(_ ref: String) async throws -> [MessageDelivery] {
        try await db.read { db in
            try MessageDelivery.fetchAll(db, sql: "SELECT * FROM message_deliveries WHERE sat_ref = ?", arguments: [ref])
        }
    }

    /// The Hub has the satellite session's message: the delivery is acknowledged. A row the worker
    /// still holds or would retry becomes sent in the same statement, so the worker's later writes
    /// leave the confirmation alone (FE-R4).
    @discardableResult
    public func markAckedBySatRef(_ ref: String, now: Int64 = MeshSatStore.nowMs()) async throws -> Int {
        try await db.write { db in
            try db.execute(
                sql: """
                    UPDATE message_deliveries
                    SET ack_status = 'acked', ack_timestamp = ?, updated_at = ?,
                        status = CASE WHEN status IN ('queued', 'retry', 'held', 'sending') THEN 'sent' ELSE status END
                    WHERE sat_ref = ?
                    """,
                arguments: [now, now, ref])
            return db.changesCount
        }
    }

    /// The deliveries of one SOS (msg_ref "sos:<run>:..."), for its result screen (MESHSAT-1249).
    /// The deliveries of a channel in one status, oldest first (the composer lane's queue).
    public func observeByChannelAndStatus(_ channel: String, _ status: String) -> AsyncValueObservation<[MessageDelivery]> {
        ValueObservation.tracking { db in
            try MessageDelivery.fetchAll(
                db, sql: "SELECT * FROM message_deliveries WHERE channel = ? AND status = ? ORDER BY created_at ASC, id ASC",
                arguments: [channel, status])
        }.values(in: db)
    }

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
    public func cancelWaitingByRefPrefix(_ prefix: String, now: Int64 = MeshSatStore.nowMs()) async throws -> Int {
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

    // The sequence number and the wait for an ACK are written with the send's outcome (markSent).

    /// ACKed: promotes the status to 'delivered', from any state, the worker's included: its later
    /// writes match only 'sending' and so leave this alone (FE-R4).
    public func setAcked(id: Int64, now: Int64 = MeshSatStore.nowMs()) async throws {
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

    public func setNacked(id: Int64, now: Int64 = MeshSatStore.nowMs()) async throws {
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
    public func timeoutPendingAcks(cutoff: Int64, now: Int64 = MeshSatStore.nowMs()) async throws -> Int {
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

    /// One channel's timed-out pending ACKs (MESHSAT-1584).
    @discardableResult
    public func timeoutPendingAcks(channel: String, cutoff: Int64, now: Int64 = MeshSatStore.nowMs()) async throws -> Int {
        try await db.write { db in
            try db.execute(
                sql: """
                    UPDATE message_deliveries
                    SET ack_status = 'timeout', updated_at = ?
                    WHERE ack_status = 'pending' AND ack_timestamp IS NOT NULL AND ack_timestamp <= ?
                    AND channel = ?
                    """,
                arguments: [now, cutoff, channel])
            return db.changesCount
        }
    }

    /// The channels with a delivery waiting for its ACK.
    public func pendingAckChannels() async throws -> [String] {
        try await db.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT channel FROM message_deliveries WHERE ack_status = 'pending'")
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
