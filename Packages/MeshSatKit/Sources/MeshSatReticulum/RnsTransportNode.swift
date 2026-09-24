// Mirrors reticulum/RnsTransportNode.kt: the cross-interface packet relay that makes the phone a
// full Transport Node, not just a client (MESHSAT-199). It receives from every interface,
// delivers local packets to the handlers, forwards the rest, relays announces, answers path
// requests, and enforces hop limits and deduplication. Protocol overhead never goes to a paid
// interface. Time and waits are injected for the tests.
import Foundation
import MeshSatHemb
import MeshSatWire

public final class RnsTransportNode: @unchecked Sendable {
    public static let maxHops = 128
    /// Paid interface prefixes: protocol overhead MUST NOT be broadcast to these.
    static let paidPrefixes = ["iridium", "sms", "cellular"]
    public static let dedupTtlMs: Int64 = 5 * 60_000
    public static let maxDedupEntries = 10_000
    public static let pruneIntervalMs: Int64 = 2 * 60_000
    public static let announceIntervalMs: Int64 = 10 * 60_000
    static let protocolOverheadContexts: Set<UInt8> = [
        RnsConstants.ctxTimeSyncReq, RnsConstants.ctxTimeSyncResp, RnsConstants.ctxCustodyOffer, RnsConstants.ctxCustodyAck,
        RnsConstants.ctxRlnc, RnsConstants.ctxKeepalive,
    ]

    /// Paid transports (Iridium SBD/IMT, SMS): only user-initiated messages go there.
    public static func isPaidInterface(_ id: String) -> Bool { paidPrefixes.contains { id.hasPrefix($0) } }

    public typealias LocalDeliveryCallback = @Sendable (_ packet: RnsPacket, _ sourceInterface: String) -> Void
    public typealias HembFrameCallback = @Sendable (_ sourceInterface: String, _ frame: [UInt8]) -> Void

    private let localDestHash: [UInt8]
    private let announceHandler: RnsAnnounceHandler
    private let linkManager: RnsLinkManager
    private let pathTable: RnsPathTable
    private let forwardingTable: RnsForwardingTable
    private let interfaces: @Sendable () -> [String: any RnsInterface]
    private let announceIntervalMs: Int64
    private let deviceType: UInt8
    private let capabilities: UInt8
    private let now: @Sendable () -> Int64
    private let sleep: @Sendable (Int64) async throws -> Void
    private let relayDelayMs: @Sendable () -> Int64
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var localDeliveryCallbackValue: LocalDeliveryCallback?
    private var hembCallbackValue: HembFrameCallback?
    private var seenPackets: [String: Int64] = [:]
    private var running = false
    private var tasks: [Task<Void, Never>] = []

    public init(
        localDestHash: [UInt8], announceHandler: RnsAnnounceHandler, linkManager: RnsLinkManager, pathTable: RnsPathTable,
        forwardingTable: RnsForwardingTable, interfaces: @escaping @Sendable () -> [String: any RnsInterface],
        announceIntervalMs: Int64 = RnsTransportNode.announceIntervalMs, deviceType: UInt8 = MeshSatAppData.deviceIos,
        capabilities: UInt8 = MeshSatAppData.capMesh | MeshSatAppData.capSatellite | MeshSatAppData.capMqtt
            | MeshSatAppData.capTransportNode,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        sleep: @escaping @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) },
        relayDelayMs: @escaping @Sendable () -> Int64 = { Int64.random(in: 100...2000) },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.localDestHash = localDestHash
        self.announceHandler = announceHandler
        self.linkManager = linkManager
        self.pathTable = pathTable
        self.forwardingTable = forwardingTable
        self.interfaces = interfaces
        self.announceIntervalMs = announceIntervalMs
        self.deviceType = deviceType
        self.capabilities = capabilities
        self.now = now
        self.sleep = sleep
        self.relayDelayMs = relayDelayMs
        self.log = log
    }

    /// Locally addressed data packets go here.
    public var localDeliveryCallback: LocalDeliveryCallback? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return localDeliveryCallbackValue
        }
        set {
            lock.lock()
            localDeliveryCallbackValue = newValue
            lock.unlock()
        }
    }

    /// HeMB frames found inside Reticulum data packets go here.
    public var hembCallback: HembFrameCallback? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return hembCallbackValue
        }
        set {
            lock.lock()
            hembCallbackValue = newValue
            lock.unlock()
        }
    }

    // Accessors for the dashboard and settings widgets (MESHSAT-394/396).
    public var destHashHex: String { Hex.encode(localDestHash) }
    public func interfaceCount() -> Int { interfaces().count }
    public func onlineInterfaceCount() -> Int { interfaces().values.filter { $0.isOnline }.count }
    public func destCount() -> Int { pathTable.destCount() }
    public func pathCount() -> Int { pathTable.pathCount() }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func keep(_ task: Task<Void, Never>) {
        lock.lock()
        tasks.append(task)
        lock.unlock()
    }

    // MARK: Lifecycle

    public func start() {
        lock.lock()
        running = true
        lock.unlock()
        for (id, iface) in interfaces() {
            iface.setReceiveCallback { [weak self] _, raw in self?.onPacketReceived(sourceInterface: id, raw) }
        }
        keep(Task { [self] in await pruneLoop() })
        keep(Task { [self] in await announceLoop() })
        log("Transport node started (\(interfaces().count) interfaces)")
    }

    public func stop() {
        lock.lock()
        running = false
        let t = tasks
        tasks.removeAll()
        lock.unlock()
        for task in t { task.cancel() }
        for (_, iface) in interfaces() { iface.setReceiveCallback(nil) }
        log("Transport node stopped")
    }

    // MARK: Packet reception, the one entry point

    /// A raw packet from an interface: to the announce handler, the link manager, local
    /// delivery or forwarding.
    public func onPacketReceived(sourceInterface: String, _ raw: [UInt8]) {
        guard isRunning() else { return }
        // HeMB frame detection, before the Reticulum unmarshal.
        if !raw.isEmpty, HembFrame.isHembFrame(raw) {
            hembCallback?(sourceInterface, raw)
            return
        }
        guard let packet = try? RnsPacket.unmarshal(raw) else { return }
        let hash = Hex.encode(RnsDestination.truncatedHash(raw))
        let t = now()
        lock.lock()
        if seenPackets[hash] != nil {
            lock.unlock()
            return
        }
        seenPackets[hash] = t
        let tooMany = seenPackets.count > Self.maxDedupEntries
        lock.unlock()
        if tooMany { pruneSeenCache() }
        switch packet.packetType {
        case RnsConstants.packetAnnounce: handleAnnounce(packet, raw: raw, sourceInterface: sourceInterface)
        case RnsConstants.packetLinkRequest: handleLinkRequest(packet, raw: raw, sourceInterface: sourceInterface)
        case RnsConstants.packetProof: forwardPacket(packet, ingressInterface: sourceInterface)
        default: handleData(packet, raw: raw, sourceInterface: sourceInterface)
        }
    }

    // MARK: Announces: relay and learn forwarding paths

    private func handleAnnounce(_ packet: RnsPacket, raw: [UInt8], sourceInterface: String) {
        let map = interfaces()
        forwardingTable.learn(
            destHash: packet.destHash, nextHop: nil, egressInterface: sourceInterface, hops: packet.hops,
            costCents: map[sourceInterface]?.costCents ?? 0)
        announceHandler.handleAnnounce(raw, sourceInterface: sourceInterface)
        // Relay on every OTHER free interface (transport node duty); never to a paid one.
        guard packet.hops < Self.maxHops else { return }
        var relayed = packet
        relayed.hops = packet.hops + 1
        let relayRaw = relayed.marshal()
        for (id, iface) in map where id != sourceInterface && iface.isOnline && !Self.isPaidInterface(id) {
            let delay = relayDelayMs()
            keep(
                Task { [self] in
                    guard (try? await sleep(delay)) != nil else { return }
                    _ = await iface.send(relayRaw)
                })
        }
    }

    // MARK: Links

    private func handleLinkRequest(_ packet: RnsPacket, raw: [UInt8], sourceInterface: String) {
        guard isLocalDest(packet.destHash) else {
            forwardPacket(packet, ingressInterface: sourceInterface)
            return
        }
        guard let proofRaw = linkManager.handleLinkRequest(raw), let iface = interfaces()[sourceInterface] else { return }
        keep(Task { _ = await iface.send(proofRaw) })
    }

    // MARK: Data: local delivery or forwarding

    private func handleData(_ packet: RnsPacket, raw: [UInt8], sourceInterface: String) {
        if !packet.data.isEmpty, HembFrame.isHembFrame(packet.data) {
            hembCallback?(sourceInterface, packet.data)
            return
        }
        if isLocalDest(packet.destHash) {
            localDeliveryCallback?(packet, sourceInterface)
            return
        }
        if packet.context == RnsConstants.ctxPathResponse, packet.data.count >= RnsConstants.destHashLen {
            handlePathRequest(packet, sourceInterface: sourceInterface)
            return
        }
        forwardPacket(packet, ingressInterface: sourceInterface)
    }

    // MARK: Path discovery

    private func handlePathRequest(_ packet: RnsPacket, sourceInterface: String) {
        let target = Array(packet.data.prefix(RnsConstants.destHashLen))
        let nextHop: [UInt8]
        let hops: Int
        if let entry = forwardingTable.lookup(target) {
            nextHop = entry.nextHop ?? localDestHash
            hops = entry.hops
        } else if let path = pathTable.bestPath(target) {
            nextHop = path.nextHop ?? localDestHash
            hops = path.hops
        } else {
            // Unknown here: flood the request on the other interfaces.
            forwardPacket(packet, ingressInterface: sourceInterface)
            return
        }
        let response = RnsPacket.data(
            destHash: packet.destHash, payload: target + nextHop + [UInt8(hops & 0xFF)], context: RnsConstants.ctxPathResponse)
        guard let iface = interfaces()[sourceInterface] else { return }
        keep(Task { _ = await iface.send(response.marshal()) })
    }

    // MARK: Forwarding

    /// Forward to the destination on the best interface; increments hops, drops when the TTL is spent.
    private func forwardPacket(_ packet: RnsPacket, ingressInterface: String) {
        guard packet.hops < Self.maxHops else { return }
        let entry = forwardingTable.lookup(packet.destHash)
        let path = entry == nil ? pathTable.bestPath(packet.destHash) : nil
        guard let egressId = entry?.egressInterface ?? path?.interfaceId else {
            floodPacket(packet, ingressInterface: ingressInterface)
            return
        }
        if egressId == ingressInterface {
            // Never back out the way it came: an alternative or nothing.
            guard let alt = forwardingTable.allEntries(packet.destHash).first(where: { $0.egressInterface != ingressInterface }) else {
                return
            }
            sendOnInterface(packet, alt.egressInterface)
            return
        }
        sendOnInterface(packet, egressId)
    }

    /// Wrapped for transport (HEADER_2 with our hash) and one hop older.
    private func forTransport(_ packet: RnsPacket) -> RnsPacket? {
        var forwarded = packet
        forwarded.hops = packet.hops + 1
        let wire =
            forwarded.headerType == RnsConstants.header1 ? RnsPacket.wrapForTransport(forwarded, transportId: localDestHash) : forwarded
        return RnsPacket.validateSize(wire) ? wire : nil
    }

    /// Flood on every interface but the ingress; protocol overhead skips paid interfaces.
    private func floodPacket(_ packet: RnsPacket, ingressInterface: String) {
        guard let wire = forTransport(packet) else { return }
        let overhead = Self.protocolOverheadContexts.contains(packet.context)
        let raw = wire.marshal()
        for (id, iface) in interfaces() where id != ingressInterface && iface.isOnline {
            if overhead, Self.isPaidInterface(id) { continue }
            keep(Task { _ = await iface.send(raw) })
        }
    }

    private func sendOnInterface(_ packet: RnsPacket, _ interfaceId: String) {
        guard let wire = forTransport(packet), let iface = interfaces()[interfaceId], iface.isOnline else { return }
        let raw = wire.marshal()
        keep(
            Task { [log] in
                if let err = await iface.send(raw) { log("Forward to \(interfaceId) failed: \(err)") }
            })
    }

    // MARK: Sending from this node

    /// A data packet to a destination on the best known path; flooded when there is none.
    public func sendData(destHash: [UInt8], data: [UInt8], context: UInt8 = RnsConstants.ctxNone) async -> String? {
        let packet = RnsPacket.data(destHash: destHash, payload: data, context: context)
        guard RnsPacket.validateSize(packet) else { return "packet exceeds MTU" }
        let map = interfaces()
        let entry = forwardingTable.lookup(destHash)
        let path = entry == nil ? pathTable.bestPath(destHash) : nil
        if let egressId = entry?.egressInterface ?? path?.interfaceId, let iface = map[egressId], iface.isOnline {
            return await iface.send(packet.marshal())
        }
        let raw = packet.marshal()
        for (_, iface) in map where iface.isOnline { _ = await iface.send(raw) }
        return nil
    }

    /// Our announce on every online free interface.
    public func broadcastAnnounce() async {
        let raw = announceHandler.createAnnounce(deviceType: deviceType, capabilities: capabilities)
        var sent = 0
        let map = interfaces()
        for (id, iface) in map where iface.isOnline && !Self.isPaidInterface(id) {
            if let err = await iface.send(raw) { log("Announce send failed on \(id): \(err)") } else { sent += 1 }
        }
        log("Announce broadcast on \(sent)/\(map.count) interfaces")
    }

    // MARK: Helpers

    private func isLocalDest(_ destHash: [UInt8]) -> Bool { destHash == localDestHash || announceHandler.isLocal(destHash) }

    func seenCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return seenPackets.count
    }

    private func pruneSeenCache() {
        let t = now()
        lock.lock()
        seenPackets = seenPackets.filter { t - $0.value <= Self.dedupTtlMs }
        lock.unlock()
    }

    private func pruneLoop() async {
        while isRunning(), !Task.isCancelled {
            guard (try? await sleep(Self.pruneIntervalMs)) != nil else { return }
            forwardingTable.prune()
            pruneSeenCache()
        }
    }

    private func announceLoop() async {
        guard (try? await sleep(5_000)) != nil else { return }
        if isRunning() { await broadcastAnnounce() }
        while isRunning(), !Task.isCancelled {
            guard (try? await sleep(announceIntervalMs)) != nil else { return }
            if isRunning() { await broadcastAnnounce() }
        }
    }
}
