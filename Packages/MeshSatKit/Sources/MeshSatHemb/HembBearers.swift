// Mirrors hemb/HembBearerProfile.kt, hemb/HembProfiles.kt, hemb/HembConfig.kt and
// hemb/BearerSelector.kt: what a bearer is, its redundancy, a bond group, and the runtime
// registry of transports that can carry HeMB symbols.
import Foundation

/// One physical bearer (the Bridge's internal/hemb/bearer.go BearerProfile). Cost is a primary
/// input to allocation: free bearers are exhausted before any paid one gets a symbol.
public struct HembBearerProfile: Sendable {
    public typealias SendFn = @Sendable ([UInt8]) async throws -> Void
    public var index: Int
    public var interfaceId: String
    public var channelType: String
    public var mtu: Int
    public var costPerMsg: Double
    public var lossRate: Double
    public var latencyMs: Int
    public var healthScore: Int
    public var sendFn: SendFn
    public var relayCapable: Bool
    public var headerMode: String

    public init(
        index: Int, interfaceId: String, channelType: String, mtu: Int, costPerMsg: Double = 0, lossRate: Double = 0, latencyMs: Int = 0,
        healthScore: Int = 100, sendFn: @escaping SendFn, relayCapable: Bool = true, headerMode: String = HembFrame.headerModeExtended
    ) {
        self.index = index
        self.interfaceId = interfaceId
        self.channelType = channelType
        self.mtu = mtu
        self.costPerMsg = costPerMsg
        self.lossRate = lossRate
        self.latencyMs = latencyMs
        self.healthScore = healthScore
        self.sendFn = sendFn
        self.relayCapable = relayCapable
        self.headerMode = headerMode
    }

    public var isFree: Bool { costPerMsg == 0 }
}

/// Bond group tuning, pushed from the Hub or set locally.
public struct HembBondConfig: Sendable, Equatable {
    public var costBudget = 0.0
    public var minReliability = 0.0
    public var preferFree = true
    public init(costBudget: Double = 0, minReliability: Double = 0, preferFree: Bool = true) {
        self.costBudget = costBudget
        self.minReliability = minReliability
        self.preferFree = preferFree
    }
}

/// A bond group: which bearers are bonded together (hemb/HembConfig.kt).
public struct HembConfig: Sendable, Equatable {
    public var id: String
    public var label: String
    /// Interface ids; empty means every bearer.
    public var members: [String]
    public var costBudget: Double
    public init(id: String, label: String, members: [String], costBudget: Double = 0) {
        self.id = id
        self.label = label
        self.members = members
        self.costBudget = costBudget
    }
}

/// Per-bearer RLNC redundancy (the Bridge's internal/hemb/profiles.go).
public enum HembProfiles {
    static let defaultRedundancy: [String: Double] = [
        "mesh": 1.30, "iridium_sbd": 1.00, "iridium_imt": 1.00, "cellular": 1.10, "sms": 1.10, "zigbee": 1.30, "aprs": 1.30,
        "ipougrs": 2.00,
        "tcp": 1.00, "mqtt": 1.00, "webhook": 1.00, "ble": 1.20,
    ]

    /// The global factor R >= 1 for a bearer set, N = ceil(K x R); priority 0 is critical, 1 normal, 2 and up best effort.
    public static func selectRedundancy(_ bearers: [HembBearerProfile], priority: Int = 2) -> Double {
        guard !bearers.isEmpty else { return 1.0 }
        var totalWeight = 0.0
        var weightedLoss = 0.0
        for b in bearers {
            totalWeight += Double(b.mtu)
            weightedLoss += Double(b.mtu) * b.lossRate
        }
        let avgLoss = totalWeight > 0 ? weightedLoss / totalWeight : 0
        var baseR: Double
        if avgLoss < 0.05 {
            baseR = 1.10
        } else if avgLoss < 0.15 {
            baseR = 1.25
        } else if avgLoss < 0.30 {
            baseR = 1.40
        } else {
            baseR = 1.60
        }
        switch priority {
        case 0: baseR *= 1.30
        case 1: baseR *= 1.10
        default: break
        }
        let paidFrac = Double(bearers.filter { !$0.isFree }.count) / Double(bearers.count)
        if paidFrac > 0.5 { baseR = max(baseR * 0.85, 1.05) }
        return min(baseR, 2.0)
    }

    /// Per-bearer factor; paid bearers capped at 1.10.
    public static func bearerRedundancy(_ b: HembBearerProfile) -> Double {
        let r = defaultRedundancy[b.channelType] ?? (b.isFree ? 1.30 : 1.05)
        return b.isFree ? r : min(r, 1.10)
    }

    /// Repair symbols for a bearer's loss rate and source count; paid bearers get at most one.
    public static func repairSymbols(_ b: HembBearerProfile, sourceCount: Int) -> Int {
        if sourceCount == 0 { return 0 }
        var repair = Int((Double(sourceCount) * b.lossRate * 1.5).rounded(.up))
        if !b.isFree, repair > 1 { repair = 1 }
        return repair
    }
}

/// The transports registered as bearers at runtime; re-evaluated on each send.
public final class BearerSelector: @unchecked Sendable {
    public struct Registration: Sendable {
        public var interfaceId: String
        public var channelType: String
        public var mtu: Int
        public var costPerMsg: Double
        public var lossRate: Double
        public var latencyMs: Int
        public var relayCapable: Bool
        public var headerMode: String
        public var sendFn: HembBearerProfile.SendFn
        /// 0 to 100.
        public var healthFn: @Sendable () -> Int
        public var onlineFn: @Sendable () -> Bool

        public init(
            interfaceId: String, channelType: String, mtu: Int, costPerMsg: Double, lossRate: Double, latencyMs: Int, relayCapable: Bool,
            headerMode: String, sendFn: @escaping HembBearerProfile.SendFn, healthFn: @escaping @Sendable () -> Int,
            onlineFn: @escaping @Sendable () -> Bool
        ) {
            self.interfaceId = interfaceId
            self.channelType = channelType
            self.mtu = mtu
            self.costPerMsg = costPerMsg
            self.lossRate = lossRate
            self.latencyMs = latencyMs
            self.relayCapable = relayCapable
            self.headerMode = headerMode
            self.sendFn = sendFn
            self.healthFn = healthFn
            self.onlineFn = onlineFn
        }
    }

    private let lock = NSLock()
    private var registered: [String: Registration] = [:]
    private var order: [String] = []

    public init() {}

    public func register(_ reg: Registration) {
        lock.lock()
        if registered[reg.interfaceId] == nil { order.append(reg.interfaceId) }
        registered[reg.interfaceId] = reg
        lock.unlock()
    }

    public func unregister(_ interfaceId: String) {
        lock.lock()
        registered[interfaceId] = nil
        order.removeAll { $0 == interfaceId }
        lock.unlock()
    }

    private func all() -> [Registration] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { registered[$0] }
    }

    /// The bearers that are online with a health above zero, indexed in registration order.
    public func activeBearers() -> [HembBearerProfile] {
        var index = 0
        var out: [HembBearerProfile] = []
        for reg in all() where reg.onlineFn() && reg.healthFn() > 0 {
            out.append(
                HembBearerProfile(
                    index: index, interfaceId: reg.interfaceId, channelType: reg.channelType, mtu: reg.mtu, costPerMsg: reg.costPerMsg,
                    lossRate: reg.lossRate, latencyMs: reg.latencyMs, healthScore: reg.healthFn(), sendFn: reg.sendFn,
                    relayCapable: reg.relayCapable, headerMode: reg.headerMode))
            index += 1
        }
        return out
    }

    public func registeredIds() -> [String] { all().map(\.interfaceId) }

    public var onlineCount: Int { all().filter { $0.onlineFn() }.count }

    static let unwired: HembBearerProfile.SendFn = { _ in throw HembBonderError.bearerNotWired }

    /// The BLE mesh bearer's defaults.
    public static func bleDefaults() -> Registration {
        Registration(
            interfaceId: "ble_0", channelType: "mesh", mtu: 237, costPerMsg: 0, lossRate: 0.15, latencyMs: 500, relayCapable: true,
            headerMode: HembFrame.headerModeCompact, sendFn: unwired, healthFn: { 0 }, onlineFn: { false })
    }

    /// The SMS bearer's defaults (binary SMS payload).
    public static func smsDefaults() -> Registration {
        Registration(
            interfaceId: "sms_0", channelType: "sms", mtu: 140, costPerMsg: 0, lossRate: 0.05, latencyMs: 3000, relayCapable: true,
            headerMode: HembFrame.headerModeCompact, sendFn: unwired, healthFn: { 0 }, onlineFn: { false })
    }

    /// The cellular data bearer's defaults.
    public static func cellularDefaults() -> Registration {
        Registration(
            interfaceId: "cellular_0", channelType: "cellular", mtu: 65535, costPerMsg: 0, lossRate: 0.02, latencyMs: 100,
            relayCapable: true,
            headerMode: HembFrame.headerModeExtended, sendFn: unwired, healthFn: { 0 }, onlineFn: { false })
    }

    /// The Iridium modem bearer's defaults.
    public static func iridiumSppDefaults() -> Registration {
        Registration(
            interfaceId: "iridium_spp_0", channelType: "iridium_sbd", mtu: 340, costPerMsg: 0.05, lossRate: 0.01, latencyMs: 30000,
            relayCapable: true, headerMode: HembFrame.headerModeExtended, sendFn: unwired, healthFn: { 0 }, onlineFn: { false })
    }
}
