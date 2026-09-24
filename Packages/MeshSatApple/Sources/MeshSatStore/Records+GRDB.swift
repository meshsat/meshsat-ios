// The GRDB conformances of the MeshSatEngine records: table names and row ids. The records
// themselves (and their column names) are in MeshSatEngine so the Linux tests see them.
import GRDB
import MeshSatEngine

extension MessageRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "messages"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension ConversationSummary: FetchableRecord {}
extension DeliveryStatRow: FetchableRecord {}

extension MessageDelivery: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "message_deliveries"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension ForwardingRuleRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "forwarding_rules"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension SignalRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "signal_history"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension NodePosition: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "node_positions"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension ConversationKey: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "conversation_keys"
}

extension AccessRule: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "access_rules"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension ObjectGroup: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "object_groups"
}

extension FailoverGroup: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "failover_groups"
}

extension FailoverMember: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "failover_members"
}

extension AuditLogEntry: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "audit_log"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension TleCacheEntry: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "tle_cache"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension ProviderCredential: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "provider_credentials"
}

extension RnsTcpPeer: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "rns_tcp_peers"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension IridiumCreditEntry: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "iridium_credit_log"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension HembBondGroup: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "hemb_bond_groups"
}

extension BridgeTrust: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "bridge_trust"
}

extension TelemetryEntry: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "telemetry"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension Contact: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "contacts"
}
