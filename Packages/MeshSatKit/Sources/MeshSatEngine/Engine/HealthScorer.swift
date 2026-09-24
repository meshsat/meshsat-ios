// Mirrors engine/HealthScorer.kt (port of meshsat/internal/engine/health_score.go): a composite
// health score per transport interface. Signal(0.3) + SuccessRate(0.3) + LatencyScore(0.2) +
// CostScore(0.2); an interface that is not online scores 0.
import Foundation

public struct HealthScore: Sendable, Equatable {
    public var interfaceId: String
    /// 0-100
    public var score: Int
    /// 0-100 normalized
    public var signal: Int
    public var successRate: Double
    public var latencyMs: Int
    /// 100 = free, 0 = expensive
    public var costScore: Int
    public var available: Bool

    public init(
        interfaceId: String, score: Int = 0, signal: Int = 0, successRate: Double = 0, latencyMs: Int = 0, costScore: Int = 0,
        available: Bool = false
    ) {
        self.interfaceId = interfaceId
        self.score = score
        self.signal = signal
        self.successRate = successRate
        self.latencyMs = latencyMs
        self.costScore = costScore
        self.available = available
    }
}

/// The queries the scorer needs: the latest signal of a source, and a channel's sent, failed
/// and average latency since a time.
public protocol HealthStore: Sendable {
    func latestSignal(source: String) async throws -> Int?
    func countSentSince(channel: String, since: Int64) async throws -> Int
    func countFailedSince(channel: String, since: Int64) async throws -> Int
    func avgLatencyMsSince(channel: String, since: Int64) async throws -> Int64
}

public final class HealthScorer: Sendable {
    static let windowMs: Int64 = 24 * 60 * 60 * 1000

    private let statuses: @Sendable () -> [InterfaceStatus]
    private let store: any HealthStore
    private let now: @Sendable () -> Int64

    public init(
        statuses: @escaping @Sendable () -> [InterfaceStatus], store: any HealthStore,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.statuses = statuses
        self.store = store
        self.now = now
    }

    /// Cost score by channel type. 100 = free, 0 = expensive.
    public static func channelCostScore(_ channelType: String) -> Int {
        switch channelType {
        case "mesh", "mqtt", "webhook": 100
        case "cellular", "sms": 60
        case "iridium": 30
        default: 50
        }
    }

    public static func composite(available: Bool, signal: Int, successRate: Double, latencyMs: Int, costScore: Int) -> Int {
        guard available else { return 0 }
        let latencyScore = Double(100 - min(latencyMs / 1000, 100))
        return Int(Double(signal) * 0.3 + successRate * 100 * 0.3 + latencyScore * 0.2 + Double(costScore) * 0.2)
    }

    /// The health score of one interface.
    public func score(_ interfaceId: String) async -> HealthScore {
        let status = statuses().first { $0.id == interfaceId }
        let available = status?.state == .online
        let channelType = status?.channelType ?? interfaceId
        let since = now() - Self.windowMs
        // signal_history holds 0-5 bars; normalised to 0-100.
        let latest: Int? = (try? await store.latestSignal(source: channelType)).flatMap { $0 }
        let signal = latest.map { min(max($0 * 20, 0), 100) } ?? 0
        let sent = (try? await store.countSentSince(channel: interfaceId, since: since)) ?? 0
        let failed = (try? await store.countFailedSince(channel: interfaceId, since: since)) ?? 0
        let successRate = sent + failed == 0 ? 1.0 : Double(sent) / Double(sent + failed)
        let latencyMs = Int((try? await store.avgLatencyMsSince(channel: interfaceId, since: since)) ?? 0)
        let costScore = Self.channelCostScore(channelType)
        return HealthScore(
            interfaceId: interfaceId,
            score: Self.composite(
                available: available, signal: signal, successRate: successRate, latencyMs: latencyMs, costScore: costScore),
            signal: signal, successRate: successRate, latencyMs: latencyMs, costScore: costScore, available: available)
    }

    /// The health scores of every registered interface.
    public func scoreAll() async -> [HealthScore] {
        var out: [HealthScore] = []
        for s in statuses() { out.append(await score(s.id)) }
        return out
    }
}
