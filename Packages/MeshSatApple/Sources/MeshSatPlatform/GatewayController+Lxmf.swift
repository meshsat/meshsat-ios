// Mirrors GatewayService.kt's initRnsStack, sendLxmf, applyPaidPolicy and the LXMF rows (MESHSAT-1553,
// MESHSAT-1641; iOS MESHSAT-1735): the upstream-compatible Reticulum node and the LXMF endpoint on the
// app's interfaces. Inbound LXMF messages become rows of the messages table with transport "lxmf" and
// the peer's 32-hex address as the sender; an outbound one is inserted at queue time and its row
// follows the LXMF state in forwardedTo, as does its delivery-ledger row on the virtual channel lxmf_0.
import Foundation
import MeshSatCrypto
import MeshSatEngine
import MeshSatLXMF
import MeshSatMeshtastic
import MeshSatNet
import MeshSatReticulum
import MeshSatRns
import MeshSatStore
import MeshSatWire

/// The stack, its two extra interfaces and the rows that follow its messages, one locked value
/// (Android: GatewayService.rnsStack, lxmfRows and lxmfLedger).
final class LxmfParts: @unchecked Sendable {
    static let queued = "lxmf:queued"
    static let sent = "lxmf:sent"
    static let delivered = "lxmf:delivered"
    static let failed = "lxmf:failed"
    static let propagated = "lxmf:propagated"
    static let unverified = "lxmf:unverified"
    /// The delivery ledger's virtual channel for LXMF (the Bridge's class lxmf).
    static let channel = "lxmf_0"

    private let lock = NSLock()
    private var stackValue: RnsStack?
    private var imtValue: RnsIridium9704Interface?
    private var tcpServerValue: RnsTcpServerInterface?
    private var rnodeValue: RnsRnodeInterface?
    private var rows: [String: Int64] = [:]
    private var ledger: [String: Int64] = [:]

    var stack: RnsStack? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stackValue
        }
        set {
            lock.lock()
            stackValue = newValue
            lock.unlock()
        }
    }

    var imt9704: RnsIridium9704Interface? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return imtValue
        }
        set {
            lock.lock()
            imtValue = newValue
            lock.unlock()
        }
    }

    var tcpServer: RnsTcpServerInterface? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return tcpServerValue
        }
        set {
            lock.lock()
            tcpServerValue = newValue
            lock.unlock()
        }
    }

    /// The RNode over Bluetooth LE (MESHSAT-1735), when the settings name one.
    var rnode: RnsRnodeInterface? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return rnodeValue
        }
        set {
            lock.lock()
            rnodeValue = newValue
            lock.unlock()
        }
    }

    func remember(hash: String, row: Int64?, ledger ledgerId: Int64?) {
        lock.lock()
        if let row { rows[hash] = row }
        if let ledgerId { ledger[hash] = ledgerId }
        lock.unlock()
    }

    func ids(for hash: String) -> (row: Int64?, ledger: Int64?) {
        lock.lock()
        defer { lock.unlock() }
        return (rows[hash], ledger[hash])
    }

    func forget(hash: String) {
        lock.lock()
        rows[hash] = nil
        ledger[hash] = nil
        lock.unlock()
    }
}

extension KeychainIdentityStore: RnsStackStore {}

extension GatewayController {
    /// The upstream-compatible node with the lxmf.delivery endpoint on the same interfaces (GatewayService.initRnsStack).
    func initRnsStack(identity: Identity) -> RnsStack {
        var name = settings.get(SettingsKey.lxmfDisplayName).trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = settings.get(SettingsKey.hubBridgeId).trimmingCharacters(in: .whitespaces) }
        if name.isEmpty { name = "MeshSat phone" }
        // The LXMF message ids past their retention go at each start (MESHSAT-1641).
        let cutoff = clock.nowMs() - GRDBLxmfMidStore.retentionMs
        keep(Task { [self] in _ = try? await db.lxmfMids.pruneBefore(cutoff) })
        let stack = RnsStack(
            identity: identity, interfaces: { [weak self] in self?.rnsInterfaces() ?? [:] }, store: KeychainIdentityStore(settings.secure),
            displayName: name, clock: clock, onMessage: { [weak self] m in self?.onLxmfMessage(m) },
            onOutboundState: { [weak self] o in self?.onLxmfOutboundState(o) }, log: { Self.log.info("\($0)") })
        lxmf.stack = stack
        applyPaidPolicy(stack)
        stack.setPropagationNode(settings.get(SettingsKey.lxmfPropagationNode))
        stack.startSyncLoop(intervalMs: (Int64(settings.get(SettingsKey.lxmfSyncIntervalMin)) ?? 0) * 60_000)
        return stack
    }

    /// The Reticulum interface on the 9704 behind the node's pipe (Android's RnsIridium9704Interface on
    /// the HC-05 or the pipe): a paid interface, opened to named destinations by the paid policy.
    func initRns9704() {
        if lxmf.imt9704 != nil { return }
        let iface = RnsIridium9704Interface(driver: imt.driver, clock: clock, log: { Self.log.debug("\($0)") })
        iface.setReceiveCallback { [weak self] id, raw in self?.rnsNode?.onPacketReceived(sourceInterface: id, raw) }
        lxmf.imt9704 = iface
        keep(Task { await iface.start() })
    }

    /// Peers on this WiFi: the TCP listener a Sideband or an rnsd connects to, while the app is in the
    /// foreground (Android's TcpServerInterface behind rns_tcp_listen_enabled).
    func initRnsTcpListener() {
        guard settings.get(SettingsKey.rnsTcpListenEnabled), lxmf.tcpServer == nil else { return }
        let port = Int(settings.get(SettingsKey.rnsTcpListenPort)) ?? RnsTcpInterface.defaultPort
        let server = RnsTcpServerInterface(
            factory: NWByteStreamListenerFactory(), interfaceId: "tcp_server_0", bindAddress: "0.0.0.0", log: { Self.log.debug("\($0)") })
        server.setReceiveCallback { [weak self] id, raw in self?.rnsNode?.onPacketReceived(sourceInterface: id, raw) }
        lxmf.tcpServer = server
        keep(
            Task { [self] in
                do {
                    let bound = try await server.listen(port: port)
                    Self.log.info("Reticulum TCP listener on port \(bound)")
                    interfaceManager.setOnline(server.interfaceId)
                } catch {
                    Self.log.warning("Reticulum TCP listener could not bind port \(port): \(error)")
                    interfaceManager.setError(server.interfaceId, "\(error)")
                }
            })
    }

    func stopLxmf() {
        let stack = lxmf.stack
        let imt9704 = lxmf.imt9704
        let server = lxmf.tcpServer
        let rnode = lxmf.rnode
        lxmf.stack = nil
        lxmf.imt9704 = nil
        lxmf.tcpServer = nil
        lxmf.rnode = nil
        stack?.stop()
        Task {
            await imt9704?.stop()
            await server?.stop()
            await rnode?.stop()
        }
    }

    /// The satellite's allow-list and extra hops from settings (MESHSAT-1553 P6).
    func applyPaidPolicy(_ stack: RnsStack) {
        let dests = settings.get(SettingsKey.rnsPaidDests).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count == 32 }.compactMap { Hex.decode($0) }
        let extra = Int(settings.get(SettingsKey.rnsPaidExtraHops)) ?? 20
        let minutes = Int64(settings.get(SettingsKey.rnsPaidMinIntervalMin)) ?? 5
        stack.setPaidPolicy(dests: dests, extraHops: extra, minIntervalMs: minutes * 60_000)
    }

    /// The settings changed from the Reticulum card: the paid policy, the propagation node and the sync loop apply live.
    public func applyReticulumSettings() {
        guard let stack = lxmf.stack else { return }
        applyPaidPolicy(stack)
        stack.setPropagationNode(settings.get(SettingsKey.lxmfPropagationNode))
        stack.startSyncLoop(intervalMs: (Int64(settings.get(SettingsKey.lxmfSyncIntervalMin)) ?? 0) * 60_000)
    }

    /// Every accepted inbound LXMF message: a row (filed once per (sender, mid), MESHSAT-1641), a notification.
    func onLxmfMessage(_ m: LxMessage) {
        Task { [self] in
            let ts = Int64(m.timestamp * 1000)
            let row = MessageRecord(
                timestamp: ts > 0 ? ts : clock.nowMs(), transport: "lxmf", direction: "rx", sender: m.sourceHex, recipient: m.destHex,
                text: m.contentString, rawText: m.title.isEmpty ? "" : m.titleString,
                forwardedTo: m.signatureValid ? "" : LxmfParts.unverified)
            // A message with a mid is filed with its (sender, mid) in one transaction, and a repeat (same sender,
            // same mid) is dropped, even across a restart. Nothing is shown unless the message was filed.
            let id: Int64?
            do {
                if let mid = LxMid.midOf(m.fields) {
                    id = try await db.lxmfMids.insertLxmfOnce(origin: m.sourceHex, mid: LxMid.format(mid), now: clock.nowMs(), message: row)
                } else {
                    id = try await db.messages.insert(row)
                }
            } catch {
                Self.log.warning("LXMF: filing a message from \(m.sourceHex.prefix(8)) failed, nothing recorded: \(error)")
                return
            }
            guard id != nil else {
                Self.log.info("LXMF: a repeat of a message already taken from \(m.sourceHex.prefix(8)), dropped")
                return
            }
            // A voice note or a photo in the fields is kept with the message (MESHSAT-1735), within the
            // 64 KiB one message may carry; the store trims itself to 16 MiB, oldest first.
            let atts = LxFields.attachmentsOf(m.fields)
            if let id, !atts.isEmpty {
                if LxFields.attachmentBytes(atts) <= LxFields.maxAttachmentBytes {
                    _ = try? await db.attachments.insertAttachments(messageId: id, atts, now: clock.nowMs())
                } else {
                    Self.log.info("LXMF: attachments of \(LxFields.attachmentBytes(atts)) bytes from \(m.sourceHex.prefix(8)) not kept")
                }
            }
            let from = lxmf.stack?.lxmf.peerInfo(m.source)?.displayName ?? String(m.sourceHex.prefix(8))
            let words = atts.map { $0.kind == .audio ? "Voice note" : "Photo" }.joined(separator: " and ")
            messageNotifications.send((title: "Reticulum: \(from)", text: m.contentString.isEmpty ? words : m.contentString))
            interfaceManager.recordActivity(m.iface)
        }
    }

    /// An outbound LXMF message changed state: its row and its ledger entry follow.
    func onLxmfOutboundState(_ o: LxmfRouter.Outbound) {
        Task { [self] in
            let propagated = o.method == .propagated
            let state: String
            switch o.state {
            case .delivered: state = LxmfParts.delivered
            case .failed, .rejected, .cancelled: state = LxmfParts.failed
            case .sent: state = propagated ? LxmfParts.propagated : LxmfParts.sent
            case .sending: state = LxmfParts.sent
            default: state = LxmfParts.queued
            }
            let ids = lxmf.ids(for: o.hashHex)
            if let r = ids.row { try? await db.messages.setForwardedTo(id: r, state) }
            if let l = ids.ledger { try? await db.deliveries.setStatus(id: l, Self.lxmfLedgerStatus(o.state), lastError: o.lastError) }
            if o.state.terminal || (propagated && o.state == .sent) { lxmf.forget(hash: o.hashHex) }
        }
    }

    static func lxmfLedgerStatus(_ s: LxState) -> String {
        switch s {
        case .delivered: "delivered"
        case .failed, .rejected, .cancelled: "failed"
        case .sent: "sent"
        case .sending: "sending"
        default: "queued"
        }
    }

    /// Our LXMF address, or "" before the node runs.
    public var lxmfAddress: String { lxmf.stack?.lxmfAddress ?? "" }

    /// Whether the node runs (the Setup card's buttons depend on it).
    public var lxmfRunning: Bool { lxmf.stack != nil }

    /// Announces the LXMF destination now; false when nothing is up to send on (or the node is not running).
    public func announceLxmf() -> Bool { lxmf.stack?.announce() ?? false }

    /// Whether a path to this 32-hex LXMF address is known (the compose hint).
    public func lxmfPathKnown(_ hex: String) -> Bool {
        guard let d = Hex.decode(hex.lowercased()), d.count == 16, let s = lxmf.stack else { return false }
        return s.node.paths.has(d)
    }

    /// A Reticulum peer heard announcing, for the new-message dialog (LxmfRouter.Peer without the module).
    public struct LxmfPeerRow: Sendable, Equatable {
        public let destHash: String
        public let displayName: String?
        public let hops: Int
        public let lastSeenMs: Int64
    }

    /// The lxmf.delivery peers the node knows, nearest and most recent first.
    public func lxmfPeers() -> [LxmfPeerRow] {
        (lxmf.stack?.lxmf.peers() ?? []).map {
            LxmfPeerRow(destHash: $0.destHash, displayName: $0.displayName, hops: $0.hops, lastSeenMs: $0.lastSeenMs)
        }
        .sorted { a, b in a.hops != b.hops ? a.hops < b.hops : a.lastSeenMs > b.lastSeenMs }
    }

    /// The TCP listener's bound port and connected peers, nil when it is not up.
    public var reticulumListener: (port: Int, peers: Int)? {
        guard let s = lxmf.tcpServer, s.isOnline else { return nil }
        return (s.port, s.peerCount())
    }

    /// The LXMF endpoint, for the screens (peers, propagation nodes, the sync state).
    public var lxmfRouter: LxmfRouter? { lxmf.stack?.lxmf }

    /// Sends an LXMF message to a 32-hex delivery address and records it in the conversation; `method` nil is
    /// auto (direct across the satellite). Returns the message hash. Each message this phone writes carries
    /// its own mid (UUIDv7); the router's retries resend the same message, so the same mid (MESHSAT-1641).
    @discardableResult
    public func sendLxmf(destHex: String, text: String, method: LxMethod? = nil, attachments: [LxAttachment] = []) throws -> String {
        guard let stack = lxmf.stack else { throw LxmfError("Reticulum node not running") }
        guard let dest = Hex.decode(destHex), dest.count == 16 else { throw LxmfError("not a Reticulum address") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else {
            throw LxmfError("nothing to send")
        }
        guard LxFields.attachmentBytes(attachments) <= LxFields.maxAttachmentBytes else {
            throw LxmfError("the note and photo are too big")
        }
        // A voice note or a photo rides in the same message as FIELD_AUDIO / FIELD_IMAGE (MESHSAT-1735).
        let fields = try LxFields.withAttachments(LxMid.fields(LxMid.newMid(nowMs: clock.nowMs())), attachments)
        let o = try stack.send(dest, content: text, method: method, fields: fields)
        let hash = o.hashHex
        Task { [self] in
            let now = clock.nowMs()
            let id = try? await db.messages.insert(
                MessageRecord(
                    timestamp: now, transport: "lxmf", direction: "tx", sender: stack.lxmfAddress, recipient: destHex, text: text,
                    forwarded: true,
                    forwardedTo: LxmfParts.queued))
            let ledgerId = try? await db.deliveries.insert(
                MessageDelivery(
                    msgRef: "lxmf:\(hash)", channel: LxmfParts.channel, status: Self.lxmfLedgerStatus(o.state), payload: Data(text.utf8),
                    textPreview: String(text.prefix(80)), maxRetries: 0, createdAt: now, updatedAt: now, recipient: destHex))
            if let id, !attachments.isEmpty { _ = try? await db.attachments.insertAttachments(messageId: id, attachments, now: now) }
            lxmf.remember(hash: hash, row: id, ledger: ledgerId)
            if o.state.terminal {
                if let id { try? await db.messages.setForwardedTo(id: id, o.state == .delivered ? LxmfParts.delivered : LxmfParts.failed) }
                if let ledgerId { try? await db.deliveries.setStatus(id: ledgerId, Self.lxmfLedgerStatus(o.state), lastError: o.lastError) }
                lxmf.forget(hash: hash)
            }
        }
        return hash
    }

    /// A send the router refused (no node, a bad address): the conversation shows it failed, as Android does.
    public func recordLxmfRefused(destHex: String, text: String) {
        Task { [self] in
            try? await db.messages.insert(
                MessageRecord(
                    timestamp: clock.nowMs(), transport: "lxmf", direction: "tx", sender: lxmfAddress, recipient: destHex, text: text,
                    forwarded: true, forwardedTo: LxmfParts.failed))
        }
    }
}
