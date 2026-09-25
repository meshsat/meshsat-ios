// Mirrors hemb/HembEvents.kt: the observability events of the Bridge's internal/hemb/events.go.
import Foundation

public enum HembEventType: String, Sendable {
    case symbolSent, symbolReceived, generationDecoded, generationFailed, bearerDegraded, bearerRecovered, streamOpened, streamClosed,
        bondStats
}

public struct BearerRef: Sendable, Equatable {
    public var bearerIndex: Int
    public var bearerType: String
    public init(_ bearerIndex: Int, _ bearerType: String) {
        self.bearerIndex = bearerIndex
        self.bearerType = bearerType
    }
}

public struct SymbolRef: Sendable, Equatable {
    public var streamId: Int
    public var generationId: Int
    public var symbolIndex: Int
    public init(_ streamId: Int, _ generationId: Int, _ symbolIndex: Int) {
        self.streamId = streamId
        self.generationId = generationId
        self.symbolIndex = symbolIndex
    }
}

public struct BearerContribution: Sendable, Equatable {
    public var bearer: BearerRef
    public var symbolCount: Int
    public var firstMs: Int64
    public var lastMs: Int64
    public var cost: Double
}

public enum HembEventPayload: Sendable, Equatable {
    case symbolSent(symbol: SymbolRef, bearer: BearerRef, payloadBytes: Int, isRepair: Bool, costEstimate: Double)
    case symbolReceived(symbol: SymbolRef, bearer: BearerRef, payloadBytes: Int, received: Int, required: Int)
    case generationDecoded(
        streamId: Int, generationId: Int, k: Int, n: Int, received: Int, decodeTimeUs: Int64, payloadBytes: Int,
        bearers: [BearerContribution],
        costTotal: Double)
    case generationFailed(
        streamId: Int, generationId: Int, k: Int, received: Int, reason: String, bearers: [BearerContribution], costWasted: Double)
    case streamOpened(streamId: Int, bearerCount: Int, payloadBytes: Int, generations: Int, k: Int, n: Int)
    case bondStats(HembBondStats)
}

public struct HembEvent: Sendable, Equatable {
    public var type: HembEventType
    public var timestampMs: Int64
    public var payload: HembEventPayload
}

/// Never blocks the data path: a listener that throws or is slow only loses events.
public typealias HembEventListener = @Sendable (HembEvent) -> Void

func hembEmit(_ listener: HembEventListener?, _ type: HembEventType, _ payload: HembEventPayload, nowMs: Int64) {
    listener?(HembEvent(type: type, timestampMs: nowMs, payload: payload))
}

/// Aggregate bonding metrics (hemb/HembBearerProfile.kt's HembBondStats).
public struct HembBondStats: Sendable, Equatable {
    public var activeStreams = 0
    public var symbolsSent: Int64 = 0
    public var symbolsReceived: Int64 = 0
    public var generationsDecoded: Int64 = 0
    public var generationsFailed: Int64 = 0
    public var bytesFree: Int64 = 0
    public var bytesPaid: Int64 = 0
    public var costIncurred = 0.0
    public init() {}
}
