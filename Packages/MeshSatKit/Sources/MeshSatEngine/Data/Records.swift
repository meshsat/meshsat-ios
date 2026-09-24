// Mirrors the Room entities of MeshSat Android's data/ package: one struct per table, with the
// same table and column names (the CodingKeys), so the SQL of the DAOs is the same text in both
// apps. Room's `@PrimaryKey(autoGenerate = true) val id: Long = 0` is `id: Int64?` here: nil
// until the row is inserted. Times are epoch milliseconds unless a field says otherwise.
// The GRDB conformances live in MeshSatStore (Packages/MeshSatApple); this file has no
// dependency, so the engine and the Linux tests see the records without a database.
import Foundation

/// data/Message.kt, table `messages`.
public struct MessageRecord: Codable, Sendable, Equatable {
    public var id: Int64?
    public var timestamp: Int64
    /// "sms", "mesh", "iridium", ...
    public var transport: String
    /// "rx" or "tx"
    public var direction: String
    /// Phone number, node id, callsign.
    public var sender: String
    public var recipient: String
    /// Decrypted plaintext.
    public var text: String
    /// Original ciphertext, when encrypted.
    public var rawText: String
    public var encrypted: Bool
    public var forwarded: Bool
    /// Where a sent message went, e.g. "iridium:queued" then "iridium:sbd" (MESHSAT-1243).
    public var forwardedTo: String

    public init(
        id: Int64? = nil, timestamp: Int64, transport: String, direction: String, sender: String, recipient: String = "",
        text: String, rawText: String = "", encrypted: Bool = false, forwarded: Bool = false, forwardedTo: String = ""
    ) {
        self.id = id
        self.timestamp = timestamp
        self.transport = transport
        self.direction = direction
        self.sender = sender
        self.recipient = recipient
        self.text = text
        self.rawText = rawText
        self.encrypted = encrypted
        self.forwarded = forwarded
        self.forwardedTo = forwardedTo
    }
}

/// data/ConversationSummary.kt: the projection of MessageDao.getConversations.
public struct ConversationSummary: Codable, Sendable, Equatable {
    public var sender: String
    public var lastMessage: String
    public var lastTimestamp: Int64
    public var messageCount: Int
    public var transport: String
    public var hasEncrypted: Bool

    public init(sender: String, lastMessage: String, lastTimestamp: Int64, messageCount: Int, transport: String, hasEncrypted: Bool) {
        self.sender = sender
        self.lastMessage = lastMessage
        self.lastTimestamp = lastTimestamp
        self.messageCount = messageCount
        self.transport = transport
        self.hasEncrypted = hasEncrypted
    }
}

/// data/MessageDeliveryEntity.kt, table `message_deliveries`: the delivery ledger, one row per
/// (message, channel). Statuses: queued, sending, sent, delivered, failed, retry, dead,
/// expired, denied, held. Port of Go's database.MessageDelivery.
public struct MessageDelivery: Codable, Sendable, Equatable {
    public var id: Int64?
    public var msgRef: String
    public var ruleId: Int64?
    /// Target interface id, e.g. "iridium_0", "sms_0".
    public var channel: String
    public var status: String
    public var priority: Int
    public var payload: Data?
    public var textPreview: String
    public var retries: Int
    public var maxRetries: Int
    public var nextRetry: Int64?
    public var lastError: String
    /// JSON array of visited interface ids.
    public var visited: String
    public var ttlSeconds: Int
    public var expiresAt: Int64?
    public var qosLevel: Int
    /// When moved to 'held'; the TTL clock pauses while held.
    public var heldAt: Int64?
    /// Per-interface monotonic sequence.
    public var seqNum: Int64
    /// nil, "pending", "acked", "nacked", "timeout".
    public var ackStatus: String?
    public var ackTimestamp: Int64?
    public var createdAt: Int64
    public var updatedAt: Int64
    /// DTN custody (MESHSAT-408): nil, "offered", "accepted", "transferred".
    public var custodyStatus: String?
    public var custodianHash: String?
    public var bundleId: String?
    /// Who this delivery is for on its channel when the channel has more than one destination:
    /// the phone number of an SOS emergency contact on "sms_0" (MESHSAT-1249).
    public var recipient: String
    /// "imei:momsn" of the satellite session that carried it, for the Hub's receipt (MESHSAT-1246).
    public var satRef: String
    /// Who the message came from, as the source link knows them (MESHSAT-1274).
    public var origin: String

    enum CodingKeys: String, CodingKey {
        case id
        case msgRef = "msg_ref"
        case ruleId = "rule_id"
        case channel, status, priority, payload
        case textPreview = "text_preview"
        case retries
        case maxRetries = "max_retries"
        case nextRetry = "next_retry"
        case lastError = "last_error"
        case visited
        case ttlSeconds = "ttl_seconds"
        case expiresAt = "expires_at"
        case qosLevel = "qos_level"
        case heldAt = "held_at"
        case seqNum = "seq_num"
        case ackStatus = "ack_status"
        case ackTimestamp = "ack_timestamp"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case custodyStatus = "custody_status"
        case custodianHash = "custodian_hash"
        case bundleId = "bundle_id"
        case recipient
        case satRef = "sat_ref"
        case origin
    }

    public init(
        id: Int64? = nil, msgRef: String, ruleId: Int64? = nil, channel: String, status: String = "queued", priority: Int = 10,
        payload: Data? = nil, textPreview: String = "", retries: Int = 0, maxRetries: Int = 3, nextRetry: Int64? = nil,
        lastError: String = "", visited: String = "[]", ttlSeconds: Int = 0, expiresAt: Int64? = nil, qosLevel: Int = 1,
        heldAt: Int64? = nil, seqNum: Int64 = 0, ackStatus: String? = nil, ackTimestamp: Int64? = nil, createdAt: Int64,
        updatedAt: Int64, custodyStatus: String? = nil, custodianHash: String? = nil, bundleId: String? = nil,
        recipient: String = "", satRef: String = "", origin: String = ""
    ) {
        self.id = id
        self.msgRef = msgRef
        self.ruleId = ruleId
        self.channel = channel
        self.status = status
        self.priority = priority
        self.payload = payload
        self.textPreview = textPreview
        self.retries = retries
        self.maxRetries = maxRetries
        self.nextRetry = nextRetry
        self.lastError = lastError
        self.visited = visited
        self.ttlSeconds = ttlSeconds
        self.expiresAt = expiresAt
        self.qosLevel = qosLevel
        self.heldAt = heldAt
        self.seqNum = seqNum
        self.ackStatus = ackStatus
        self.ackTimestamp = ackTimestamp
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.custodyStatus = custodyStatus
        self.custodianHash = custodianHash
        self.bundleId = bundleId
        self.recipient = recipient
        self.satRef = satRef
        self.origin = origin
    }

    /// How many tries a delivery with no retry cap of its own may have before the guard at
    /// start-up calls it a runaway: about six hours of satellite retries every 3 minutes.
    public static let runawaySafetyLimit = 120
}

/// MessageDeliveryDao.stats() row.
public struct DeliveryStatRow: Codable, Sendable, Equatable {
    public var channel: String
    public var status: String
    public var cnt: Int
    public init(channel: String, status: String, cnt: Int) {
        self.channel = channel
        self.status = status
        self.cnt = cnt
    }
}

/// data/ForwardingRuleEntity.kt, table `forwarding_rules`.
public struct ForwardingRuleRecord: Codable, Sendable, Equatable {
    public var id: Int64?
    public var name: String
    /// INBOUND, OUTBOUND, BIDIRECTIONAL
    public var direction: String
    /// MESH, IRIDIUM, SMS
    public var sourceTransport: String
    public var destTransport: String
    public var enabled: Bool
    public var encrypt: Bool
    public var filterPattern: String?
    public var filterSender: String?

    public init(
        id: Int64? = nil, name: String, direction: String, sourceTransport: String, destTransport: String, enabled: Bool = true,
        encrypt: Bool = false, filterPattern: String? = nil, filterSender: String? = nil
    ) {
        self.id = id
        self.name = name
        self.direction = direction
        self.sourceTransport = sourceTransport
        self.destTransport = destTransport
        self.enabled = enabled
        self.encrypt = encrypt
        self.filterPattern = filterPattern
        self.filterSender = filterSender
    }
}

/// data/SignalRecord.kt, table `signal_history`.
public struct SignalRecord: Codable, Sendable, Equatable {
    public var id: Int64?
    public var timestamp: Int64
    /// "iridium", "mesh", "cellular"
    public var source: String
    /// 0-5 for iridium, dBm for the others.
    public var value: Int

    public init(id: Int64? = nil, timestamp: Int64, source: String, value: Int) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.value = value
    }
}

/// data/NodePosition.kt, table `node_positions`.
public struct NodePosition: Codable, Sendable, Equatable {
    public var id: Int64?
    public var timestamp: Int64
    public var nodeId: Int64
    public var nodeName: String
    public var latitude: Double
    public var longitude: Double
    public var altitude: Int

    public init(
        id: Int64? = nil, timestamp: Int64, nodeId: Int64, nodeName: String = "", latitude: Double, longitude: Double, altitude: Int = 0
    ) {
        self.id = id
        self.timestamp = timestamp
        self.nodeId = nodeId
        self.nodeName = nodeName
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

/// data/ConversationKey.kt, table `conversation_keys`: a per-conversation AES-256-GCM key that
/// takes priority over the global key for that sender.
public struct ConversationKey: Codable, Sendable, Equatable {
    public var sender: String
    public var hexKey: String
    public var label: String
    public init(sender: String, hexKey: String, label: String = "") {
        self.sender = sender
        self.hexKey = hexKey
        self.label = label
    }
}

/// data/AccessRuleEntity.kt, table `access_rules`: Cisco ASA style, implicit deny.
public struct AccessRule: Codable, Sendable, Equatable {
    public var id: Int64?
    public var interfaceId: String
    /// "ingress" or "egress"
    public var direction: String
    public var priority: Int
    public var name: String
    public var enabled: Bool
    /// "forward", "drop", "log"
    public var action: String
    public var forwardTo: String
    /// JSON: keyword, channels, nodes, portnums
    public var filters: String
    public var filterNodeGroup: String?
    public var filterSenderGroup: String?
    public var filterPortnumGroup: String?
    public var forwardOptions: String
    public var qosLevel: Int
    public var rateLimitPerMin: Int
    public var rateLimitWindow: Int
    public var matchCount: Int64
    public var lastMatchAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case interfaceId = "interface_id"
        case direction, priority, name, enabled, action
        case forwardTo = "forward_to"
        case filters
        case filterNodeGroup = "filter_node_group"
        case filterSenderGroup = "filter_sender_group"
        case filterPortnumGroup = "filter_portnum_group"
        case forwardOptions = "forward_options"
        case qosLevel = "qos_level"
        case rateLimitPerMin = "rate_limit_per_min"
        case rateLimitWindow = "rate_limit_window"
        case matchCount = "match_count"
        case lastMatchAt = "last_match_at"
    }

    public init(
        id: Int64? = nil, interfaceId: String, direction: String, priority: Int = 10, name: String, enabled: Bool = true,
        action: String = "forward", forwardTo: String = "", filters: String = "{}", filterNodeGroup: String? = nil,
        filterSenderGroup: String? = nil, filterPortnumGroup: String? = nil, forwardOptions: String = "{}", qosLevel: Int = 1,
        rateLimitPerMin: Int = 0, rateLimitWindow: Int = 0, matchCount: Int64 = 0, lastMatchAt: String? = nil
    ) {
        self.id = id
        self.interfaceId = interfaceId
        self.direction = direction
        self.priority = priority
        self.name = name
        self.enabled = enabled
        self.action = action
        self.forwardTo = forwardTo
        self.filters = filters
        self.filterNodeGroup = filterNodeGroup
        self.filterSenderGroup = filterSenderGroup
        self.filterPortnumGroup = filterPortnumGroup
        self.forwardOptions = forwardOptions
        self.qosLevel = qosLevel
        self.rateLimitPerMin = rateLimitPerMin
        self.rateLimitWindow = rateLimitWindow
        self.matchCount = matchCount
        self.lastMatchAt = lastMatchAt
    }
}

/// data/ObjectGroupEntity.kt, table `object_groups`: node_group, sender_group, portnum_group,
/// contact_group; `members` is a JSON array of strings.
public struct ObjectGroup: Codable, Sendable, Equatable {
    public var id: String
    public var type: String
    public var label: String
    public var members: String
    public init(id: String, type: String, label: String, members: String = "[]") {
        self.id = id
        self.type = type
        self.label = label
        self.members = members
    }
}

/// data/FailoverGroupEntity.kt, table `failover_groups`.
public struct FailoverGroup: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    /// "failover" or "broadcast"
    public var mode: String
    public init(id: String, label: String, mode: String = "failover") {
        self.id = id
        self.label = label
        self.mode = mode
    }
}

/// data/FailoverGroupEntity.kt, table `failover_members` (primary key group_id + interface_id).
public struct FailoverMember: Codable, Sendable, Equatable {
    public var groupId: String
    public var interfaceId: String
    /// Lower is higher priority.
    public var priority: Int

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case interfaceId = "interface_id"
        case priority
    }

    public init(groupId: String, interfaceId: String, priority: Int) {
        self.groupId = groupId
        self.interfaceId = interfaceId
        self.priority = priority
    }
}

/// data/AuditLogEntity.kt, table `audit_log`: tamper-evident, SHA-256 hash chain.
public struct AuditLogEntry: Codable, Sendable, Equatable {
    public var id: Int64?
    public var timestamp: String
    public var interfaceId: String?
    public var direction: String?
    public var eventType: String
    public var deliveryId: Int64?
    public var ruleId: Int64?
    public var detail: String
    public var prevHash: String
    public var hash: String

    enum CodingKeys: String, CodingKey {
        case id, timestamp
        case interfaceId = "interface_id"
        case direction
        case eventType = "event_type"
        case deliveryId = "delivery_id"
        case ruleId = "rule_id"
        case detail
        case prevHash = "prev_hash"
        case hash
    }

    public init(
        id: Int64? = nil, timestamp: String, interfaceId: String? = nil, direction: String? = nil, eventType: String,
        deliveryId: Int64? = nil, ruleId: Int64? = nil, detail: String = "", prevHash: String = "", hash: String = ""
    ) {
        self.id = id
        self.timestamp = timestamp
        self.interfaceId = interfaceId
        self.direction = direction
        self.eventType = eventType
        self.deliveryId = deliveryId
        self.ruleId = ruleId
        self.detail = detail
        self.prevHash = prevHash
        self.hash = hash
    }
}

/// data/TleCacheEntity.kt, table `tle_cache`. `fetchedAt` is unix seconds.
public struct TleCacheEntry: Codable, Sendable, Equatable {
    public var id: Int64?
    public var satelliteName: String
    public var line1: String
    public var line2: String
    public var fetchedAt: Int64
    public init(id: Int64? = nil, satelliteName: String, line1: String, line2: String, fetchedAt: Int64) {
        self.id = id
        self.satelliteName = satelliteName
        self.line1 = line1
        self.line2 = line2
        self.fetchedAt = fetchedAt
    }
}

/// data/ProviderCredential.kt, table `provider_credentials`: provider TLS certificates and
/// credentials from the Hub or a QR code, stored as the already-encrypted blob.
public struct ProviderCredential: Codable, Sendable, Equatable {
    public var id: String
    /// cloudloop_mqtt, rockblock, ...
    public var provider: String
    public var name: String
    /// mtls_bundle, api_key, webhook_secret
    public var credType: String
    public var encryptedData: Data
    public var certNotAfter: String?
    public var certSubject: String
    public var certFingerprint: String
    public var version: Int
    /// local, hub, qr
    public var source: String
    public var receivedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, provider, name
        case credType = "cred_type"
        case encryptedData = "encrypted_data"
        case certNotAfter = "cert_not_after"
        case certSubject = "cert_subject"
        case certFingerprint = "cert_fingerprint"
        case version, source
        case receivedAt = "received_at"
    }

    public init(
        id: String, provider: String, name: String, credType: String, encryptedData: Data, certNotAfter: String? = nil,
        certSubject: String = "", certFingerprint: String = "", version: Int = 1, source: String = "local", receivedAt: Int64
    ) {
        self.id = id
        self.provider = provider
        self.name = name
        self.credType = credType
        self.encryptedData = encryptedData
        self.certNotAfter = certNotAfter
        self.certSubject = certSubject
        self.certFingerprint = certFingerprint
        self.version = version
        self.source = source
        self.receivedAt = receivedAt
    }
}

/// data/RnsTcpPeer.kt, table `rns_tcp_peers` (MESHSAT-392).
public struct RnsTcpPeer: Codable, Sendable, Equatable {
    public var id: Int64?
    public var host: String
    public var port: Int
    public var enabled: Bool
    public var label: String
    public init(id: Int64? = nil, host: String, port: Int = 4242, enabled: Bool = true, label: String = "") {
        self.id = id
        self.host = host
        self.port = port
        self.enabled = enabled
        self.label = label
    }
}

/// data/IridiumCreditEntry.kt, table `iridium_credit_log`: what satellite messages cost.
public struct IridiumCreditEntry: Codable, Sendable, Equatable {
    public var id: Int64?
    public var timestamp: Int64
    /// "mo", "mt", "burst"
    public var messageType: String
    /// USD cents (5 = $0.05).
    public var costCents: Int
    public var moMsn: Int
    public init(id: Int64? = nil, timestamp: Int64, messageType: String, costCents: Int, moMsn: Int = 0) {
        self.id = id
        self.timestamp = timestamp
        self.messageType = messageType
        self.costCents = costCents
        self.moMsn = moMsn
    }
}

/// data/HembBondGroupEntity.kt, table `hemb_bond_groups` (MESHSAT-431).
public struct HembBondGroup: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    /// JSON array of interface ids.
    public var members: String
    public var costBudget: Double
    public var createdAt: Int64
    public init(id: String, label: String = "", members: String = "[]", costBudget: Double = 0, createdAt: Int64) {
        self.id = id
        self.label = label
        self.members = members
        self.costBudget = costBudget
        self.createdAt = createdAt
    }
}

/// data/BridgeTrustEntity.kt, table `bridge_trust`: TOFU pinning of bridge signing keys (MESHSAT-495).
public struct BridgeTrust: Codable, Sendable, Equatable {
    /// Hex of the 16-byte bridge identifier from the bundle header.
    public var bridgeHash: String
    /// Raw 32-byte Ed25519 public key pinned on first use.
    public var pubkey: Data
    public var firstSeen: Int64
    public var lastSeen: Int64
    public var label: String
    public var importCount: Int
    public init(bridgeHash: String, pubkey: Data, firstSeen: Int64, lastSeen: Int64, label: String, importCount: Int) {
        self.bridgeHash = bridgeHash
        self.pubkey = pubkey
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.label = label
        self.importCount = importCount
    }
}

/// data/TelemetryEntity.kt, table `telemetry`: the release telemetry ring buffer (MESHSAT-494).
public struct TelemetryEntry: Codable, Sendable, Equatable {
    public var id: Int64?
    public var timestamp: Int64
    /// crash, heap, health, event
    public var type: String
    public var tag: String
    /// fatal, warn, info, sample
    public var severity: String
    public var message: String
    /// JSON with type-specific detail.
    public var detail: String
    public init(id: Int64? = nil, timestamp: Int64, type: String, tag: String, severity: String, message: String, detail: String) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.tag = tag
        self.severity = severity
        self.message = message
        self.detail = detail
    }
}

/// data/ContactEntity.kt, table `contacts`: someone whose card this phone took in by QR code
/// (MESHSAT-566, 575), keyed by the fingerprint of the key that signed it.
public struct Contact: Codable, Sendable, Equatable {
    public var fingerprint: String
    public var name: String
    /// Base64 of the raw 32-byte Ed25519 public key that signed the card.
    public var signingPub: String
    public var meshNodeId: String
    public var bridgeId: String
    /// "SCANNED" off a screen in person, or "IMPORTED" from text anyone could have passed on.
    public var trust: String
    public var issuedAt: Int64
    public var addedAt: Int64

    enum CodingKeys: String, CodingKey {
        case fingerprint, name
        case signingPub = "signing_pub"
        case meshNodeId = "mesh_node_id"
        case bridgeId = "bridge_id"
        case trust
        case issuedAt = "issued_at"
        case addedAt = "added_at"
    }

    public init(
        fingerprint: String, name: String, signingPub: String, meshNodeId: String = "", bridgeId: String = "",
        trust: String = "IMPORTED", issuedAt: Int64 = 0, addedAt: Int64 = 0
    ) {
        self.fingerprint = fingerprint
        self.name = name
        self.signingPub = signingPub
        self.meshNodeId = meshNodeId
        self.bridgeId = bridgeId
        self.trust = trust
        self.issuedAt = issuedAt
        self.addedAt = addedAt
    }
}
