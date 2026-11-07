// Mirrors rns/RnsStack.kt (the Bridge's rnsstack): the upstream-compatible Reticulum node and the
// LXMF endpoint on the app's interfaces. Every packet an interface receives is offered to the node
// first through `inbound`; what it declines falls through to the MeshSat-private stack
// (meshsat.node, time sync, the Hub relay). The Transmitter over the interfaces is
// InterfaceTransmitter (one ordered queue per interface); the ratchets persist through a small
// key-value store (the Keychain on the phone). [MESHSAT-1553, MESHSAT-1735]
import Foundation
import MeshSatCrypto
import MeshSatNet
import MeshSatReticulum
import MeshSatRns
import MeshSatWire

/// Where the stack keeps the LXMF ratchets between runs (Android: SecureKeyStore; the phone: the Keychain).
public protocol RnsStackStore: Sendable {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
}

public final class RnsStack: @unchecked Sendable {
    public static let keyRatchets = "lxmf_ratchets"
    public static let keyRatchetsLatest = "lxmf_ratchets_latest_ms"
    /// The interface whose HEADER_1 packets for remote destinations are inserted into transport: the Meshtastic bearer.
    public static let forwardHeader1From: Set<String> = ["mesh_rns_0"]

    public let rnsIdentity: RnsIdentity
    public let node: Node
    public let lxmf: LxmfRouter
    public let transmitter: InterfaceTransmitter

    private let interfaces: @Sendable () -> [String: any RnsInterface]
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var announceTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?

    public init(
        identity: Identity, interfaces: @escaping @Sendable () -> [String: any RnsInterface], store: any RnsStackStore, displayName: String,
        clock: any DriverClock = SystemDriverClock(), onMessage: @escaping @Sendable (LxMessage) -> Void,
        onOutboundState: @escaping @Sendable (LxmfRouter.Outbound) -> Void, log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.interfaces = interfaces
        self.log = log
        rnsIdentity = RnsIdentity.fromRouting(identity)
        transmitter = InterfaceTransmitter(interfaces: interfaces, log: log)
        node = Node(
            cfg: NodeConfig(identity: rnsIdentity, forwardHeader1From: Self.forwardHeader1From, clock: clock, log: log), tx: transmitter)
        var cfg = LxmfRouter.Config(identity: rnsIdentity, displayName: displayName)
        cfg.ratchets = (store.get(Self.keyRatchets) ?? "").split(separator: ",").compactMap { Hex.decode(String($0)) }.filter {
            $0.count == Rns.ratchetLen
        }
        cfg.ratchetsLatestMs = Int64(store.get(Self.keyRatchetsLatest) ?? "") ?? 0
        cfg.onRatchetsChanged = { list, latest in
            store.set(Self.keyRatchets, list.map { Hex.encode($0) }.joined(separator: ","))
            store.set(Self.keyRatchetsLatest, String(latest))
        }
        cfg.onMessage = onMessage
        cfg.onOutboundState = onOutboundState
        cfg.log = log
        lxmf = LxmfRouter(node: node, config: cfg)
    }

    /// Our LXMF address, what a Sideband user types to reach this phone.
    public var lxmfAddress: String { lxmf.hashHex }

    /// Offers a received packet to the node. True when it consumed it; false for everything the node does not
    /// handle, which the legacy stack then takes.
    public func inbound(_ ifaceId: String, _ raw: [UInt8]) -> Bool { node.inbound(raw, iface: ifaceId) }

    public func start(announceIntervalMs: Int64) {
        node.start()
        lxmf.start()
        let clock = node.cfg.clock
        let t = Task.detached(priority: .utility) { [weak self] in
            await clock.sleep(ms: 5_000)
            while !Task.isCancelled {
                guard let self else { return }
                self.announce()
                await clock.sleep(ms: announceIntervalMs)
            }
        }
        lock.lock()
        announceTask = t
        lock.unlock()
        log("Reticulum node \(node.idHashHex.prefix(8)) started, LXMF address \(lxmfAddress) (\(lxmf.displayName))")
    }

    public func stop() {
        lock.lock()
        let a = announceTask
        let s = syncTask
        announceTask = nil
        syncTask = nil
        lock.unlock()
        a?.cancel()
        s?.cancel()
        lxmf.stop()
        node.stop()
        transmitter.stop()
    }

    /// Announces the LXMF destination on every floodable interface and every paid interface open to it.
    @discardableResult
    public func announce() -> Bool {
        let sent = lxmf.announce()
        log(sent ? "LXMF announce sent" : "LXMF announce: no interface to send on")
        return sent
    }

    /// Opens the paid interfaces (the satellite) to the listed destinations plus our own LXMF address, at most one
    /// announce per `minIntervalMs` per destination, and counts every packet arriving over them as `extraHops`
    /// more hops, so that a stock client's link and receipt timeouts cover the satellite round trip.
    public func setPaidPolicy(dests: [[UInt8]], extraHops: Int, minIntervalMs: Int64) {
        var all: [[UInt8]] = []
        for d in dests + [lxmf.hash] where !all.contains(d) { all.append(d) }
        let policy = PaidPolicy(
            dests: all, minIntervalMs: minIntervalMs, bitrate: 0, extraHops: min(max(extraHops, 0), PaidPolicy.maxExtraHops))
        let paid = interfaces().keys.filter { InterfaceTransmitter.isPaidInterface($0) }.sorted()
        for id in paid { node.setPaidPolicy(id, policy) }
        log("paid link policy: \(all.count) destinations, extra hops \(extraHops), every \(minIntervalMs / 60_000) min, on \(paid)")
    }

    /// The propagation node choice from settings: "" = the nearest heard, "none" = off, else a 32-hex address.
    public func setPropagationNode(_ choice: String) {
        let c = choice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if c == "none" {
            lxmf.autoSelectPropagationNode = false
            lxmf.setPropagationNode(nil)
        } else if c.count == 32, let d = Hex.decode(c) {
            lxmf.autoSelectPropagationNode = true
            lxmf.setPropagationNode(d)
        } else {
            lxmf.autoSelectPropagationNode = true
            lxmf.setPropagationNode(nil)
        }
    }

    /// Syncs from the propagation node every `intervalMs` (0 stops), the first time half a minute in.
    public func startSyncLoop(intervalMs: Int64) {
        lock.lock()
        let old = syncTask
        syncTask = nil
        lock.unlock()
        old?.cancel()
        guard intervalMs > 0 else { return }
        let clock = node.cfg.clock
        let t = Task.detached(priority: .utility) { [weak self] in
            await clock.sleep(ms: 30_000)
            while !Task.isCancelled {
                guard let self else { return }
                if self.lxmf.propagationNode() != nil { _ = self.lxmf.sync() }
                await clock.sleep(ms: intervalMs)
            }
        }
        lock.lock()
        syncTask = t
        lock.unlock()
    }

    /// Sends an LXMF message; `method` nil = auto (direct across the satellite).
    @discardableResult
    public func send(_ dest: [UInt8], content: String, title: String = "", method: LxMethod? = nil, fields: [MpEntry] = []) throws
        -> LxmfRouter.Outbound
    {
        try lxmf.send(dest, content: Array(content.utf8), title: Array(title.utf8), fields: fields, method: method)
    }

    /// Paid bearers never carry broadcast traffic: a policy opens them to named destinations.
    public static func isPaidInterface(_ id: String) -> Bool { InterfaceTransmitter.isPaidInterface(id) }

    /// The LXMF delivery hash of a routing identity, so settings can show it before the service runs.
    public static func lxmfAddress(of identity: Identity) -> String {
        Hex.encode(RnsIdentity.fromRouting(identity).destHash(LxMessage.deliveryName))
    }
}
