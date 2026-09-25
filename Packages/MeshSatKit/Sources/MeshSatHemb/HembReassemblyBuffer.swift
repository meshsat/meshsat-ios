// Mirrors hemb/HembReassemblyBuffer.kt: coded symbols from every bearer, decoded once K
// independent ones are in, wire-compatible with the Bridge's internal/hemb/reassemble.go. The
// clock is injected; stream age is measured on it, monotonic as the Bridge's time.Since.
import Foundation

public final class HembReassemblyBuffer: @unchecked Sendable {
    public typealias DeliverFn = @Sendable ([UInt8]) -> Void

    private final class GenerationState {
        let k: Int
        let symSize: Int
        let decoder: HembRlncDecoder
        var decoded = false
        var bearersSeen: Set<Int> = []
        let firstSymbolAt: Int64
        var symbolCount = 0
        init(k: Int, symSize: Int, at: Int64) {
            self.k = k
            self.symSize = symSize
            decoder = HembRlncDecoder(k: k, symSize: symSize)
            firstSymbolAt = at
        }
    }

    private final class StreamState {
        var generations: [Int: GenerationState] = [:]
        let createdAtMs: Int64
        init(at: Int64) { createdAtMs = at }
    }

    private let lock = NSLock()
    private var streams: [Int: StreamState] = [:]
    private let deliverFn: DeliverFn?
    private let eventListener: HembEventListener?
    private let now: @Sendable () -> Int64

    public init(
        deliverFn: DeliverFn? = nil, eventListener: HembEventListener? = nil,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.deliverFn = deliverFn
        self.eventListener = eventListener
        self.now = now
    }

    /// An inbound frame: the decoded payload when a generation just completed.
    @discardableResult
    public func addFrame(_ data: [UInt8]) -> [UInt8]? {
        guard let parsed = HembFrame.parseSymbol(data) else { return nil }
        return addSymbol(streamId: parsed.streamId, bearerIndex: parsed.bearerIndex, parsed.symbol)
    }

    /// A coded symbol: the decoded payload once K are in.
    @discardableResult
    public func addSymbol(streamId: Int, bearerIndex: Int, _ sym: HembCodedSymbol) -> [UInt8]? {
        let nowMs = now()
        lock.lock()
        let stream: StreamState
        if let s = streams[streamId] {
            stream = s
        } else {
            stream = StreamState(at: nowMs)
            streams[streamId] = stream
        }
        let gen: GenerationState
        if let g = stream.generations[sym.genId] {
            gen = g
        } else {
            gen = GenerationState(k: sym.k, symSize: sym.data.count, at: nowMs)
            stream.generations[sym.genId] = gen
        }
        if gen.decoded {
            lock.unlock()
            return nil
        }
        gen.bearersSeen.insert(bearerIndex)
        gen.symbolCount += 1
        gen.decoder.feed(sym)
        guard gen.decoder.isSolvable else {
            lock.unlock()
            return nil
        }
        gen.decoded = true
        let decodeStart = DispatchTime.now().uptimeNanoseconds
        guard let segments = gen.decoder.solve() else {
            lock.unlock()
            return nil
        }
        let decodeTimeUs = Int64((DispatchTime.now().uptimeNanoseconds - decodeStart) / 1000)
        let payload = segments.flatMap { $0 }
        let contributions = gen.bearersSeen.sorted().map {
            BearerContribution(bearer: BearerRef($0, ""), symbolCount: 0, firstMs: gen.firstSymbolAt, lastMs: nowMs, cost: 0)
        }
        let event = HembEventPayload.generationDecoded(
            streamId: streamId, generationId: sym.genId, k: gen.k, n: gen.symbolCount, received: gen.symbolCount,
            decodeTimeUs: decodeTimeUs,
            payloadBytes: payload.count, bearers: contributions, costTotal: 0)
        // The generation goes so the stream and generation ids can be reused, as the Bridge does.
        stream.generations[sym.genId] = nil
        if stream.generations.isEmpty { streams[streamId] = nil }
        lock.unlock()
        hembEmit(eventListener, .generationDecoded, event, nowMs: nowMs)
        deliverFn?(payload)
        return payload
    }

    /// Streams still waiting for symbols.
    public var activeStreamCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return streams.count
    }

    /// Drops streams older than maxAgeMs; the count removed.
    @discardableResult
    public func reap(maxAgeMs: Int64 = 5 * 60 * 1000) -> Int {
        let nowMs = now()
        var failed: [HembEventPayload] = []
        lock.lock()
        var removed = 0
        for (streamId, state) in streams where nowMs - state.createdAtMs > maxAgeMs {
            for (genId, gen) in state.generations where !gen.decoded {
                failed.append(
                    .generationFailed(
                        streamId: streamId, generationId: genId, k: gen.k, received: gen.symbolCount, reason: "timeout",
                        bearers: gen.bearersSeen.sorted().map {
                            BearerContribution(
                                bearer: BearerRef($0, ""), symbolCount: 0, firstMs: gen.firstSymbolAt, lastMs: nowMs, cost: 0)
                        }, costWasted: 0))
            }
            streams[streamId] = nil
            removed += 1
        }
        lock.unlock()
        for f in failed { hembEmit(eventListener, .generationFailed, f, nowMs: nowMs) }
        return removed
    }
}
