// What the engine needs from persistence, as protocols: the Room DAOs' methods the Dispatcher,
// the AccessEvaluator, the FailoverResolver, the AckTracker and the CreditTracker call. The
// GRDB DAOs in MeshSatStore conform; the tests use fakes. Times are epoch milliseconds.
import Foundation

public protocol DeliveryStore: Sendable {
    @discardableResult func insert(_ delivery: MessageDelivery) async throws -> Int64
    func getById(_ id: Int64) async throws -> MessageDelivery?
    func getPending(channel: String, now: Int64, limit: Int) async throws -> [MessageDelivery]
    func setStatus(id: Int64, _ status: String, lastError: String, now: Int64) async throws
    func scheduleRetry(id: Int64, retries: Int, nextRetry: Int64, lastError: String, now: Int64) async throws
    func deferRetry(id: Int64, nextRetry: Int64, lastError: String, now: Int64) async throws
    func queueDepth(channel: String) async throws -> Int
    @discardableResult func expireDeliveries(now: Int64) async throws -> Int
    @discardableResult func holdForChannel(_ channel: String, now: Int64) async throws -> Int
    @discardableResult func unholdForChannel(_ channel: String, now: Int64) async throws -> Int
    @discardableResult func cancelRunaway(safetyLimit: Int, now: Int64) async throws -> Int
    @discardableResult func retryNowForChannel(_ channel: String, now: Int64) async throws -> Int
    @discardableResult func recoverStale(now: Int64) async throws -> Int
    func setSeqNum(id: Int64, _ seqNum: Int64, now: Int64) async throws
    func setAckPending(id: Int64, now: Int64) async throws
    func setAcked(id: Int64, now: Int64) async throws
    func setNacked(id: Int64, now: Int64) async throws
    @discardableResult func timeoutPendingAcks(cutoff: Int64, now: Int64) async throws -> Int
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
