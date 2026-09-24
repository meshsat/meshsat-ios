// Mirrors the small engine/ files: SequenceTracker, SatelliteLimits, OutgoingText, HubOrigin,
// InterfaceStatusProvider, FailoverResolver, CreditTracker.
import Foundation
import Logging

/// Per-interface monotonic sequence counters, in memory (reset on restart): enough for
/// session-level ordering and ACK correlation.
public final class SequenceTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var egress: [String: Int64] = [:]
    private var ingress: [String: Int64] = [:]

    public init() {}

    public func nextEgressSeq(_ interfaceId: String) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let next = (egress[interfaceId] ?? 0) + 1
        egress[interfaceId] = next
        return next
    }

    public func nextIngressSeq(_ interfaceId: String) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let next = (ingress[interfaceId] ?? 0) + 1
        ingress[interfaceId] = next
        return next
    }

    public func currentEgressSeq(_ interfaceId: String) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return egress[interfaceId] ?? 0
    }

    public func currentIngressSeq(_ interfaceId: String) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return ingress[interfaceId] ?? 0
    }

    public func reset(_ interfaceId: String) {
        lock.lock()
        egress[interfaceId] = nil
        ingress[interfaceId] = nil
        lock.unlock()
    }

    public func resetAll() {
        lock.lock()
        egress.removeAll()
        ingress.removeAll()
        lock.unlock()
    }
}

/// One satellite message is one SBD frame: 340 bytes, and nothing longer is sent (MESHSAT-1280).
/// The 2-byte fragment header's first byte collided with the protocol version byte, and the Hub
/// settled that the version byte wins; the Bridge's driver refuses anything over 340 bytes, and
/// so does the phone, before the send rather than after.
public enum SatelliteLimits {
    public static let maxMoBytes = 340
    public static func fits(_ bytes: Int) -> Bool { bytes <= maxMoBytes }
    /// What to tell a person whose message is too long, in the words of the compose bar.
    public static func tooLong(_ bytes: Int) -> String {
        "Too long for a satellite message: \(bytes) bytes, \(maxMoBytes) at most. Shorten it or send it in two."
    }
}

/// A Meshtastic text channel is shared with radios that are not MeshSat (MESHSAT-1286): what is
/// typed is what goes on air, never a coded frame, a version byte or base64.
public enum OutgoingText {
    public static func onMesh(_ typed: String) -> String { typed }
}

/// Whose name goes on a message this phone passes on to the Hub (MESHSAT-1274): the id names who
/// originated it, `bridge_id` names the gateway that carried it.
public enum HubOrigin {
    private static let meshNode = try? NSRegularExpression(pattern: "^![0-9a-fA-F]{8}$")

    /// - sourceBearer: the link the message arrived on (sms_0, mesh_0, iridium_0, ...), empty for
    ///   a message written on this phone
    /// - origin: who sent it, as that link knows them; may be empty
    public static func deviceIdFor(sourceBearer: String, origin: String, modemImei: String, bridgeId: String) -> String {
        let sender = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let id: String
        if sourceBearer.hasPrefix("iridium") {
            // The modem did carry these: its IMEI is the truthful name, and the Hub keys the
            // satellite delivery receipt on it.
            id = modemImei
        } else if sourceBearer.hasPrefix("mesh") {
            let range = NSRange(sender.startIndex..., in: sender)
            id = meshNode?.firstMatch(in: sender, range: range) != nil ? sender : ""
        } else if sourceBearer.hasPrefix("sms") || sourceBearer.hasPrefix("aprs") {
            id = sender
        } else {
            // Written here: this phone is the originator.
            id = bridgeId
        }
        // Never nothing: an unknown sender is still this gateway's message, not the modem's.
        if !id.isEmpty { return id }
        if !bridgeId.isEmpty { return bridgeId }
        return modemImei
    }
}

/// Reports whether an interface is online; the InterfaceManager implements it.
public protocol InterfaceStatusProvider: Sendable {
    func isOnline(_ interfaceId: String) -> Bool
}

/// Resolves failover group ids to the best available interface. A plain interface id comes back
/// as is; a group answers its highest-priority online member, or its first member when none is
/// online (deliveries will be held), or "" when it has no members.
public final class FailoverResolver: Sendable {
    private static let log = Logger(label: "FailoverResolver")
    private let store: any FailoverGroupStore
    private let status: any InterfaceStatusProvider

    public init(store: any FailoverGroupStore, status: any InterfaceStatusProvider) {
        self.store = store
        self.status = status
    }

    public func resolve(_ targetId: String) async throws -> String {
        guard let group = try await store.getGroup(targetId) else { return targetId }
        let members = try await store.getMembers(group.id)
        if members.isEmpty {
            Self.log.warning("Failover group '\(group.id)': no members")
            return ""
        }
        for member in members where status.isOnline(member.interfaceId) {
            return member.interfaceId
        }
        let fallback = members[0].interfaceId
        Self.log.warning("Failover '\(group.id)': no online member, using \(fallback) (deliveries will be held)")
        return fallback
    }
}

/// Tracks Iridium satellite messaging costs. Default: 5 cents per SBD MO message.
public final class CreditTracker: Sendable {
    private let store: any IridiumCreditStore
    private let costPerMoCents: Int
    private let now: @Sendable () -> Int64

    public init(
        store: any IridiumCreditStore, costPerMoCents: Int = 5,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.store = store
        self.costPerMoCents = costPerMoCents
        self.now = now
    }

    public func recordMo(moMsn: Int = 0) async throws {
        try await store.insert(IridiumCreditEntry(timestamp: now(), messageType: "mo", costCents: costPerMoCents, moMsn: moMsn))
    }

    public func recordBurst(messageCount: Int) async throws {
        try await store.insert(IridiumCreditEntry(timestamp: now(), messageType: "burst", costCents: costPerMoCents * messageCount))
    }

    /// Midnight UTC of the current day, in epoch milliseconds.
    public static func startOfTodayUtc(nowMs: Int64) -> Int64 {
        let day: Int64 = 86_400_000
        return nowMs - (nowMs % day)
    }

    public func todayCostCents() async throws -> Int {
        try await store.costSince(Self.startOfTodayUtc(nowMs: now())) ?? 0
    }

    public func todayMessageCount() async throws -> Int {
        try await store.messagesSince(Self.startOfTodayUtc(nowMs: now()))
    }

    public func totalCostCents() async throws -> Int {
        try await store.totalCostCents() ?? 0
    }
}
