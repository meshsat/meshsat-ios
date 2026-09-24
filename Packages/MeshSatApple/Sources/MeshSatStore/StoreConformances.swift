// The GRDB DAOs are the engine's stores: the protocols in MeshSatEngine name exactly the DAO
// methods the Dispatcher, AccessEvaluator, FailoverResolver, AckTracker and CreditTracker call.
import MeshSatEngine

extension MessageDeliveryDao: DeliveryStore {}
extension AccessRuleDao: AccessRuleStore {}
extension ObjectGroupDao: ObjectGroupStore {}
extension FailoverGroupDao: FailoverGroupStore {}
extension IridiumCreditDao: IridiumCreditStore {}

/// The health scorer's queries (engine/HealthScorer.kt), over the deliveries and signal tables.
public struct GrdbHealthStore: HealthStore {
    let deliveries: MessageDeliveryDao
    let signals: SignalDao

    public init(_ db: AppDatabase) {
        deliveries = db.deliveries
        signals = db.signals
    }

    public func latestSignal(source: String) async throws -> Int? { try await signals.getLatestForSource(source)?.value }
    public func countSentSince(channel: String, since: Int64) async throws -> Int {
        try await deliveries.countSentSince(channel: channel, since: since)
    }
    public func countFailedSince(channel: String, since: Int64) async throws -> Int {
        try await deliveries.countFailedSince(channel: channel, since: since)
    }
    public func avgLatencyMsSince(channel: String, since: Int64) async throws -> Int64 {
        try await deliveries.avgLatencyMsSince(channel: channel, since: since)
    }
}
