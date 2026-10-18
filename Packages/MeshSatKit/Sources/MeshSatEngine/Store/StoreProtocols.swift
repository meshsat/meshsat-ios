// What the engine needs from persistence, as protocols: the Room DAOs' methods the Dispatcher,
// the AccessEvaluator, the FailoverResolver, the AckTracker and the CreditTracker call. The
// GRDB DAOs in MeshSatStore conform; the tests use fakes. Times are epoch milliseconds.
import Foundation

public protocol DeliveryStore: Sendable {
    @discardableResult func insert(_ delivery: MessageDelivery) async throws -> Int64
    func getById(_ id: Int64) async throws -> MessageDelivery?
    func getPending(channel: String, now: Int64, limit: Int) async throws -> [MessageDelivery]
    func setStatus(id: Int64, _ status: String, lastError: String, now: Int64) async throws
    // The worker's writes (review 2026-10-18 23:31, FE-R4): each changes a row only while the
    // worker may still own it, and answers how many rows it changed; 0 means a confirmation, a
    // cancel or another worker came first, and the row stays as that left it.
    /// Take a waiting, unconfirmed delivery for one send ('sending').
    @discardableResult func claimForSend(id: Int64, now: Int64) async throws -> Int
    /// The send went out: sent, its sequence number and the ACK wait, in one write, while 'sending'.
    @discardableResult func markSent(id: Int64, seqNum: Int64, ackPending: Bool, now: Int64) async throws -> Int
    /// A waiting, unconfirmed delivery stops before it is sent.
    @discardableResult func dropWaiting(id: Int64, _ status: String, lastError: String, now: Int64) async throws -> Int
    /// The send ends for good, while 'sending'.
    @discardableResult func finishSend(id: Int64, _ status: String, lastError: String, now: Int64) async throws -> Int
    @discardableResult func scheduleRetry(id: Int64, retries: Int, nextRetry: Int64, lastError: String, now: Int64) async throws -> Int
    @discardableResult func deferRetry(id: Int64, nextRetry: Int64, lastError: String, now: Int64) async throws -> Int
    /// A confirmed delivery left waiting by an older worker becomes sent (at start).
    @discardableResult func settleConfirmed(now: Int64) async throws -> Int
    func queueDepth(channel: String) async throws -> Int
    @discardableResult func expireDeliveries(now: Int64) async throws -> Int
    @discardableResult func holdForChannel(_ channel: String, now: Int64) async throws -> Int
    @discardableResult func unholdForChannel(_ channel: String, now: Int64) async throws -> Int
    @discardableResult func cancelRunaway(safetyLimit: Int, now: Int64) async throws -> Int
    @discardableResult func retryNowForChannel(_ channel: String, now: Int64) async throws -> Int
    @discardableResult func recoverStale(now: Int64) async throws -> Int
    func setAcked(id: Int64, now: Int64) async throws
    func setNacked(id: Int64, now: Int64) async throws
    @discardableResult func timeoutPendingAcks(cutoff: Int64, now: Int64) async throws -> Int
    /// One channel's timed-out pending ACKs; the sweep is per channel (MESHSAT-1584).
    @discardableResult func timeoutPendingAcks(channel: String, cutoff: Int64, now: Int64) async throws -> Int
    /// The channels with a delivery waiting for its ACK.
    func pendingAckChannels() async throws -> [String]
    func getByChannelAndSeq(channel: String, seqNum: Int64) async throws -> MessageDelivery?
}

public protocol AccessRuleStore: Sendable {
    func getAllSync() async throws -> [AccessRule]
    func recordMatch(id: Int64, timestamp: String) async throws
}

public protocol ObjectGroupStore: Sendable {
    func getAll() async throws -> [ObjectGroup]
}

public protocol FailoverGroupStore: Sendable {
    func getGroup(_ id: String) async throws -> FailoverGroup?
    func getMembers(_ groupId: String) async throws -> [FailoverMember]
}

public protocol IridiumCreditStore: Sendable {
    func insert(_ entry: IridiumCreditEntry) async throws
    func totalCostCents() async throws -> Int?
    func costSince(_ since: Int64) async throws -> Int?
    func messagesSince(_ since: Int64) async throws -> Int
}
