// Mirrors hemb/HembBonder.kt and hemb/HembBondGroupManager.kt: RLNC-coded symbols spread
// over heterogeneous bearers, cost-weighted, free bearers first, wire-compatible with the
// Bridge's internal/hemb/bonder.go. One bearer means a zero-overhead passthrough. The bond
// group store lives with the platform; the parsers of a QR payload and a Hub push are here.
import Foundation

public enum HembBonderError: Error, Equatable {
    case noBearers
    case noHealthyBearers
    case mtuTooSmall
    case payloadTooLarge
    case bearerNotWired
}

public final class HembBonder: @unchecked Sendable {
    /// One counter for every bonder, so ephemeral instances never collide on a stream id.
    private static let globalStreamSeq = Counter()

    private let bearers: [HembBearerProfile]
    private let deliverFn: HembReassemblyBuffer.DeliverFn?
    private let eventListener: HembEventListener?
    private let reassembly: HembReassemblyBuffer?
    private let now: @Sendable () -> Int64
    private let lock = NSLock()
    private var symbolsSent: Int64 = 0
    private var symbolsReceived: Int64 = 0
    private var bytesFree: Int64 = 0
    private var bytesPaid: Int64 = 0
    private var costMicro: Int64 = 0

    public init(
        bearers: [HembBearerProfile], deliverFn: HembReassemblyBuffer.DeliverFn? = nil, eventListener: HembEventListener? = nil,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.bearers = bearers
        self.deliverFn = deliverFn
        self.eventListener = eventListener
        self.now = now
        reassembly = bearers.count > 1 ? HembReassemblyBuffer(deliverFn: deliverFn, eventListener: eventListener, now: now) : nil
    }

    /// A payload across every bearer, RLNC-coded when there is more than one.
    public func send(_ payload: [UInt8]) async throws {
        guard !bearers.isEmpty else { throw HembBonderError.noBearers }
        if bearers.count == 1 {
            await sendN1(payload, bearers[0])
            return
        }
        try await sendMulti(payload)
    }

    private func sendN1(_ payload: [UInt8], _ bearer: HembBearerProfile) async {
        hembEmit(
            eventListener, .symbolSent,
            .symbolSent(
                symbol: SymbolRef(0, 0, 0), bearer: BearerRef(bearer.index, bearer.channelType), payloadBytes: payload.count,
                isRepair: false, costEstimate: bearer.costPerMsg),
            nowMs: now())
        account(bearer, bytes: payload.count)
        try? await bearer.sendFn(payload)
    }

    struct BearerAlloc {
        let bearer: HembBearerProfile
        var source = 0
        var repair = 0
        var total: Int { source + repair }
    }

    private func sendMulti(_ payload: [UInt8]) async throws {
        let online = bearers.filter { $0.healthScore > 0 }
        guard !online.isEmpty else { throw HembBonderError.noHealthyBearers }
        if online.count == 1 {
            await sendN1(payload, online[0])
            return
        }
        let streamId = Self.globalStreamSeq.next() & 0xFF
        // The data room every bearer has, then K and the symbol size that fit it.
        let minMtu = online.map { $0.mtu - HembFrame.headerOverhead($0.headerMode) }.min() ?? 0
        guard minMtu > 2 else { throw HembBonderError.mtuTooSmall }
        var roughSymSize = minMtu - 1
        if roughSymSize <= 0 { roughSymSize = 1 }
        var k = min(max((payload.count + roughSymSize - 1) / roughSymSize, 1), 255)
        var symSize = minMtu - k
        if symSize <= 0 {
            k = max(minMtu / 2, 1)
            symSize = minMtu - k
        }
        guard symSize > 0 else { throw HembBonderError.payloadTooLarge }
        k = min(max((payload.count + symSize - 1) / symSize, 1), 255)
        let segments = HembRlncEncoder.segmentPayload(payload, symSize: symSize)
        let actualK = segments.count
        let allocs = allocateSymbols(online, k: actualK)
        let totalN = allocs.reduce(0) { $0 + $1.total }
        hembEmit(
            eventListener, .streamOpened,
            .streamOpened(
                streamId: streamId, bearerCount: online.count, payloadBytes: payload.count, generations: 1, k: actualK, n: totalN),
            nowMs: now())
        let symbols = try HembRlncEncoder.encode(genId: 0, segments: segments, n: totalN)
        var si = 0
        for alloc in allocs {
            for j in 0..<alloc.total {
                let sym = symbols[si]
                si += 1
                let isRepair = j >= alloc.source
                let frame = HembFrame.marshalExtended(
                    streamId: streamId, sym: sym, bearerIndex: alloc.bearer.index, totalN: totalN,
                    flags: isRepair ? HembFrame.flagRepair : HembFrame.flagData)
                hembEmit(
                    eventListener, .symbolSent,
                    .symbolSent(
                        symbol: SymbolRef(streamId, 0, sym.symbolIndex), bearer: BearerRef(alloc.bearer.index, alloc.bearer.channelType),
                        payloadBytes: frame.count, isRepair: isRepair, costEstimate: alloc.bearer.costPerMsg), nowMs: now())
                account(alloc.bearer, bytes: frame.count)
                // A failing bearer never stops the others.
                try? await alloc.bearer.sendFn(frame)
            }
        }
    }

    private func account(_ bearer: HembBearerProfile, bytes: Int) {
        lock.lock()
        if bearer.isFree {
            bytesFree += Int64(bytes)
        } else {
            bytesPaid += Int64(bytes)
            costMicro += Int64(bearer.costPerMsg * 1e6)
        }
        symbolsSent += 1
        lock.unlock()
    }

    /// Cost-weighted, free first (the Bridge's allocateSymbols).
    func allocateSymbols(_ bearers: [HembBearerProfile], k: Int) -> [BearerAlloc] {
        let free = bearers.filter(\.isFree).sorted { $0.mtu > $1.mtu }
        let paid = bearers.filter { !$0.isFree }.sorted { $0.costPerMsg < $1.costPerMsg }
        var allocMap: [Int: BearerAlloc] = [:]
        for b in bearers { allocMap[b.index] = BearerAlloc(bearer: b) }
        var remaining = k
        for fb in free where remaining > 0 {
            allocMap[fb.index]?.source = remaining
            remaining = 0
        }
        for pb in paid where remaining > 0 {
            allocMap[pb.index]?.source = remaining
            remaining = 0
        }
        return bearers.compactMap { b in
            guard var a = allocMap[b.index] else { return nil }
            a.repair =
                a.source == 0 && b.isFree
                ? HembProfiles.repairSymbols(b, sourceCount: k) : HembProfiles.repairSymbols(b, sourceCount: a.source)
            return a.total > 0 ? a : nil
        }
    }

    /// An inbound symbol from a bearer: with one bearer the raw payload, else into reassembly.
    @discardableResult
    public func receiveSymbol(bearerIndex: Int, _ data: [UInt8]) -> [UInt8]? {
        if bearers.count == 1 {
            lock.lock()
            symbolsReceived += 1
            lock.unlock()
            hembEmit(
                eventListener, .symbolReceived,
                .symbolReceived(
                    symbol: SymbolRef(0, 0, 0), bearer: BearerRef(bearerIndex, bearers[0].channelType), payloadBytes: data.count,
                    received: 1,
                    required: 1), nowMs: now())
            deliverFn?(data)
            return data
        }
        guard let parsed = HembFrame.parseSymbol(data) else { return nil }
        lock.lock()
        symbolsReceived += 1
        lock.unlock()
        hembEmit(
            eventListener, .symbolReceived,
            .symbolReceived(
                symbol: SymbolRef(parsed.streamId, parsed.symbol.genId, parsed.symbol.symbolIndex), bearer: BearerRef(bearerIndex, ""),
                payloadBytes: data.count, received: 0, required: 0), nowMs: now())
        return reassembly?.addSymbol(streamId: parsed.streamId, bearerIndex: bearerIndex, parsed.symbol)
    }

    public func stats() -> HembBondStats {
        lock.lock()
        defer { lock.unlock() }
        var s = HembBondStats()
        s.activeStreams = reassembly?.activeStreamCount ?? 0
        s.symbolsSent = symbolsSent
        s.symbolsReceived = symbolsReceived
        s.bytesFree = bytesFree
        s.bytesPaid = bytesPaid
        s.costIncurred = Double(costMicro) / 1e6
        return s
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }
}

/// The bond group formats (hemb/HembBondGroupManager.kt); the store is the platform's.
public enum HembBondGroupManager {
    public static let qrPrefix = "meshsat://bond/"

    /// meshsat://bond/<base64url, no padding> to a config; nil when it is not one.
    public static func parseQrUrl(_ url: String) -> HembConfig? {
        guard url.hasPrefix(qrPrefix) else { return nil }
        var text = String(url.dropFirst(qrPrefix.count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text) else { return nil }
        return parseQrPayload([UInt8](data))
    }

    /// Version(1) | GroupID(16) | LabelLen(1) | Label | MemberCount(1) | per member IdLen(1) Id | CostBudget(8, IEEE 754 double, big endian).
    public static func parseQrPayload(_ data: [UInt8]) -> HembConfig? {
        guard !data.isEmpty, data[0] == 1 else { return nil }
        var offset = 1
        guard offset + 16 <= data.count else { return nil }
        let groupId = data[offset..<(offset + 16)].map { String(format: "%02x", $0) }.joined()
        offset += 16
        guard offset < data.count else { return nil }
        let labelLen = Int(data[offset])
        offset += 1
        guard offset + labelLen <= data.count else { return nil }
        let label = String(decoding: data[offset..<(offset + labelLen)], as: UTF8.self)
        offset += labelLen
        guard offset < data.count else { return nil }
        let memberCount = Int(data[offset])
        offset += 1
        var members: [String] = []
        for _ in 0..<memberCount {
            guard offset < data.count else { return nil }
            let idLen = Int(data[offset])
            offset += 1
            guard offset + idLen <= data.count else { return nil }
            members.append(String(decoding: data[offset..<(offset + idLen)], as: UTF8.self))
            offset += idLen
        }
        var costBudget = 0.0
        if offset + 8 <= data.count {
            var bits: UInt64 = 0
            for i in 0..<8 { bits = (bits << 8) | UInt64(data[offset + i]) }
            costBudget = Double(bitPattern: bits)
        }
        return HembConfig(id: groupId, label: label, members: members, costBudget: costBudget)
    }

    /// The Hub's hemb_bond_create payload ({"bond_id", "label", "members", "cost_budget"}).
    public static func parseHubCreate(_ json: String) -> HembConfig? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
        let id = obj["bond_id"] as? String ?? ""
        guard !id.isEmpty else { return nil }
        let members = (obj["members"] as? [Any])?.compactMap { $0 as? String } ?? []
        return HembConfig(
            id: id, label: obj["label"] as? String ?? "", members: members, costBudget: (obj["cost_budget"] as? NSNumber)?.doubleValue ?? 0)
    }

    /// A bonder for a group over the selector's active bearers; nil when none is a member.
    public static func buildBonder(
        _ config: HembConfig, selector: BearerSelector, deliverFn: HembReassemblyBuffer.DeliverFn? = nil,
        eventListener: HembEventListener? = nil
    ) -> HembBonder? {
        let all = selector.activeBearers()
        let group = config.members.isEmpty ? all : all.filter { config.members.contains($0.interfaceId) }
        guard !group.isEmpty else { return nil }
        return HembBonder(bearers: group, deliverFn: deliverFn, eventListener: eventListener)
    }
}
