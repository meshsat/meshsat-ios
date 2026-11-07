// Mirrors lxmf/LxmfPropagation.kt: what an lxmf.propagation destination announces
// (LXMRouter.get_propagation_node_app_data, LXMF 1.2.0): [legacy flag, timebase, enabled,
// per-transfer limit kB, per-sync limit kB, [stamp cost, flexibility, peering cost], metadata];
// and where a sync from a propagation node stands (LXMRouter.PR_*). [MESHSAT-1553 P3b]
import Foundation
import MeshSatRns
import MeshSatWire

public struct PropagationNodeInfo: Sendable, Equatable {
    public let destHash: [UInt8]
    public let timebase: Int64
    public let enabled: Bool
    public let transferLimitKb: Int64
    public let syncLimitKb: Int64
    /// The propagation stamp cost a client must meet (PROPAGATION_COST_MIN 13 and up).
    public let stampCost: Int
    public let stampCostFlex: Int
    public let peeringCost: Int
    public let name: String?
    public var hops = -1
    public var iface = ""
    public var lastSeenMs: Int64 = 0

    public var destHex: String { Hex.encode(destHash) }
}

public enum PnAppData {
    public static let pnMetaName: Int64 = 0x01

    /// The parsed announce, or nil when it is not a 1.2.0 propagation node announce (pn_announce_data_is_valid).
    public static func parse(dest: [UInt8], appData: [UInt8]?) -> PropagationNodeInfo? {
        guard let appData, !appData.isEmpty, let items = (try? Msgpack.unpack(appData))?.value.asArray, items.count >= 7 else { return nil }
        guard let timebase = items[1].asInt, case .bool(let enabled) = items[2], let transfer = items[3].asInt, let sync = items[4].asInt
        else {
            return nil
        }
        guard let costs = items[5].asArray, costs.count >= 3, let cost = costs[0].asInt, let flex = costs[1].asInt,
            let peering = costs[2].asInt
        else { return nil }
        guard items[6].asMap != nil else { return nil }
        var name: String?
        switch items[6][pnMetaName] {
        case .bin(let b)?: name = String(decoding: b, as: UTF8.self)
        case .str(let s)?: name = s
        default: name = nil
        }
        name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if name?.isEmpty == true { name = nil }
        return PropagationNodeInfo(
            destHash: dest, timebase: timebase, enabled: enabled, transferLimitKb: transfer, syncLimitKb: sync, stampCost: Int(cost),
            stampCostFlex: Int(flex), peeringCost: Int(peering), name: name)
    }
}

/// LXMRouter.PR_*: where a sync from a propagation node stands.
public enum SyncState: Int, Sendable, Equatable {
    case idle = 0x00
    case pathRequested = 0x01
    case linkEstablishing = 0x02
    case linkEstablished = 0x03
    case requestSent = 0x04
    case receiving = 0x05
    case responseReceived = 0x06
    case complete = 0x07
    case noPath = 0xf0
    case linkFailed = 0xf1
    case transferFailed = 0xf2
    case noIdentityRcvd = 0xf3
    case noAccess = 0xf4
    case failed = 0xfe

    public var code: Int { rawValue }
    public var isFailure: Bool { rawValue >= 0xf0 }
    public var busy: Bool { (0x01...0x06).contains(rawValue) }
}

public struct SyncResult: Sendable, Equatable {
    public let state: SyncState
    public let received: Int
    public let duplicates: Int
    public let error: String

    public init(state: SyncState, received: Int, duplicates: Int, error: String = "") {
        self.state = state
        self.received = received
        self.duplicates = duplicates
        self.error = error
    }
}
