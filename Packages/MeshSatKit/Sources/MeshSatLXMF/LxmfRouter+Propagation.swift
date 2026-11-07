// Mirrors the propagation-node half of lxmf/LxmfRouter.kt (MESHSAT-1553 P3b): messages through an
// lxmf.propagation node (LXMRouter.process_outbound for PROPAGATED, the propagation stamp, the
// node's signalling) and syncing what a node holds for us (request_messages_from_propagation_node
// and the two /get rounds). The router's state it works on lives in LxmfRouter.swift.
import Foundation
import MeshSatNet
import MeshSatReticulum
import MeshSatRns
import MeshSatWire

extension LxmfRouter {
    // MARK: Propagation nodes (P3b): messages through an lxmf.propagation node, and syncing from one

    /// With no fixed node, the nearest announced propagation node is used, as Sideband's autoselect does.
    public var autoSelectPropagationNode: Bool {
        get { lock.locked { autoSelect } }
        set { lock.locked { autoSelect = newValue } }
    }
    public var syncState: SyncState { lock.locked { syncStateRaw } }
    public var syncProgress: Float { lock.locked { syncProgressRaw } }
    public var lastSync: SyncResult? { lock.locked { lastSyncRaw } }
    public var propagationNodeFixedHex: String? { lock.locked { propagationNodeFixed.map { Hex.encode($0) } } }

    func setSyncState(_ s: SyncState) { lock.locked { syncStateRaw = s } }

    /// Propagation nodes heard announcing, nearest first.
    public func propagationNodes() -> [PropagationNodeInfo] {
        node.paths.all()
            .filter { $0.announce.nameHash == pnNameHash }
            .compactMap { e -> PropagationNodeInfo? in
                let k = node.recall(e.destHash)
                guard var info = PnAppData.parse(dest: e.destHash, appData: k?.appData) else { return nil }
                info.hops = e.hops
                info.iface = e.iface
                info.lastSeenMs = k?.lastSeenMs ?? 0
                return info
            }
            .sorted { a, b in a.hops != b.hops ? a.hops < b.hops : a.lastSeenMs > b.lastSeenMs }
    }

    /// Pins the outbound propagation node (set_outbound_propagation_node); nil returns to automatic selection.
    public func setPropagationNode(_ dest: [UInt8]?) {
        let old = propagationNode()
        lock.locked { propagationNodeFixed = dest }
        let new = propagationNode()
        if let old, new == nil || old != new {
            let l: Link? = lock.locked {
                let l = propagationLink
                propagationLink = nil
                return l
            }
            if let l { node.links.teardown(l) }
        }
        let fixed = lock.locked { propagationNodeFixed == nil }
        log("lxmf: propagation node \(new.map { String(Hex.encode($0).prefix(8)) } ?? "none")\(fixed ? " (automatic)" : "")")
    }

    /// The node propagated messages go through and syncs come from, or nil when none is known.
    public func propagationNode() -> [UInt8]? {
        let (fixed, auto) = lock.locked { (propagationNodeFixed, autoSelect) }
        if let fixed { return fixed }
        return auto ? propagationNodes().first { $0.enabled }?.destHash : nil
    }

    public func propagationNodeInfo() -> PropagationNodeInfo? {
        guard let d = propagationNode() else { return nil }
        return propagationNodes().first { $0.destHash == d }
    }

    /// The first step of a propagated message: the recipient's identity and a propagation node must be known
    /// (paths are requested until they are), then the payload is built and stamped off the jobs task.
    private func preparePropagated(_ o: Outbound, _ peer: [UInt8]) {
        let k = node.recall(peer)
        let info = propagationNodeInfo()
        guard let k, let identity = k.identity, let info else {
            guard attemptDue(o, peer) else { return }
            o.update { $0.attempts += 1 }
            if o.attempts > o.maxAttempts {
                failMessage(o, k?.identity == nil ? "recipient identity unknown" : "no propagation node known")
                return
            }
            if k?.identity == nil {
                requestPathThrottled(peer)
            } else if let pn = propagationNode() {
                requestPathThrottled(pn)
            }
            scheduleAttempt(o, peer, pathRequest: true)
            return
        }
        setState(o, .generating)
        Task.detached(priority: .utility) { [weak self] in self?.buildPropagated(o, k, identity, info) }
    }

    /// process_outbound for PROPAGATED: pack and stamp first, then one link to the node, reused.
    func processPropagated(_ o: Outbound) {
        let peer = o.message.dest
        if o.read(\.propagationPacked) == nil {
            preparePropagated(o, peer)
            return
        }
        guard let pn = propagationNode() else {
            failMessage(o, "no propagation node known")
            return
        }
        if o.attempts > o.maxAttempts {
            if attemptDue(o, pn) { failMessage(o, "max delivery attempts reached (propagated)") }
            return
        }
        if let link = lock.locked({ propagationLink }) {
            switch link.state {
            case .active, .stale:
                if o.state != .sending, let packed = o.read(\.propagationPacked) {
                    let what = "propagation transfer via \(Hex.encode(pn).prefix(8))"
                    startTransfer(o, on: link, packed: packed, what: what) { [weak self] in self?.propagated(o) }
                }
            case .closed:
                lock.locked { if propagationLink === link { propagationLink = nil } }
                if o.state == .sending { setState(o, .outbound) }
                if o.attempts + 1 < o.maxAttempts { scheduleAttempt(o, pn) } else { failMessage(o, "propagation link closed") }
            default:
                break  // pending or in handshake
            }
            return
        }
        guard attemptDue(o, pn) else { return }
        o.update {
            $0.attempts += 1
            $0.awaitingPath = false
        }
        scheduleAttempt(o, pn)
        if o.attempts < o.maxAttempts {
            if node.paths.has(pn) {
                log("lxmf: establishing link to propagation node \(Hex.encode(pn).prefix(8)) for attempt \(o.attempts)")
                do {
                    _ = try openPropagationLink(pn)
                } catch {
                    log("lxmf: link to \(Hex.encode(pn).prefix(8)) not started: \(error)")
                }
            } else {
                log("lxmf: no path to propagation node \(Hex.encode(pn).prefix(8)) for attempt \(o.attempts), requesting one")
                requestPathThrottled(pn)
                scheduleAttempt(o, pn, pathRequest: true)
            }
        } else {
            failMessage(o, "max delivery attempts reached (propagated)")
        }
    }

    func openPropagationLink(_ pn: [UInt8]) throws -> Link {
        let l = try node.links.initiate(pn)
        l.onPacket = { [weak self] _, plain, _ in self?.propagationSignal(plain) }
        l.onEstablished = { [weak self] _ in self?.trigger() }
        l.onClosed = { [weak self] ll in
            guard let self else { return }
            self.lock.locked { if self.propagationLink === ll { self.propagationLink = nil } }
            self.trigger()
        }
        lock.locked { propagationLink = l }
        return l
    }

    /// The node's answer on the link to a single-packet upload with a bad stamp (propagation_transfer_signalling_packet).
    func propagationSignal(_ plain: [UInt8]) {
        guard let v = (try? Msgpack.unpack(plain))?.value.asArray, v.first?.asInt == Self.errorInvalidStamp else { return }
        let rejected = lock.locked { pendingOutbound.filter { $0.method == .propagated && $0.state == .sending } }
        for o in rejected {
            log("lxmf: the propagation node rejected the stamp of \(tag(o.message))")
            setState(o, .rejected, error: "invalid propagation stamp")
        }
        trigger()
    }

    /// Encrypts for the recipient, stamps for the node and packs (LXMessage.pack for PROPAGATED), off the jobs task.
    func buildPropagated(_ o: Outbound, _ k: KnownIdentity, _ id: RnsIdentity, _ info: PropagationNodeInfo) {
        do {
            if o.state == .cancelled { return }
            let nowMs = now()
            var ratchet: [UInt8]?
            if let r = k.ratchet, r.count == Rns.ratchetLen, nowMs < k.ratchetAtMs + Rns.ratchetExpiryMs { ratchet = r }
            let enc = try id.encrypt(Array(o.message.packed[LxMessage.destLen...]), ratchetPub: ratchet)
            var lxmfData = o.message.dest + enc
            let transientId = Rns.sha256(lxmfData)
            o.update { $0.transientId = transientId }
            if info.stampCost > 0 {
                log("lxmf: generating a propagation stamp at cost \(info.stampCost) for \(tag(o.message))")
                let st = LxStamper.generateStamp(
                    messageId: transientId, cost: info.stampCost, cancelled: { o.state == .cancelled },
                    expandRounds: LxStamper.workblockExpandRoundsPN)
                guard let st else {
                    if o.state != .cancelled { failMessage(o, "propagation stamp generation failed") }
                    return
                }
                lxmfData += st.stamp
            }
            let packed = Msgpack.pack(.array([.float(Double(nowMs) / 1000.0), .array([.bin(lxmfData)])]))
            o.update {
                $0.propagationPacked = packed
                $0.representation = packed.count <= LxMessage.linkPacketMaxContent ? .packet : .resource
            }
            setState(o, .outbound)
            trigger()
        } catch {
            failMessage(o, "propagation packing failed: \(error)")
        }
    }

    /// The node took the message: SENT is as far as a propagated message gets here (LXMessage.__mark_propagated).
    func propagated(_ o: Outbound) {
        lock.locked { pendingOutbound.removeAll { $0 === o } }
        log("lxmf: \(tag(o.message)) handed to the propagation node")
        setState(o, .sent)
        o.result.complete(.sent)
    }

    func transientSeen(_ id: [UInt8]) -> Bool {
        lock.locked {
            let h = Hex.encode(id)
            if processedTransientIds[h] != nil { return true }
            processedTransientIds[h] = now()
            processedOrder.append(h)
            if processedOrder.count > 10_000 {
                for k in processedOrder.prefix(1000) { processedTransientIds[k] = nil }
                processedOrder.removeFirst(1000)
            }
            return false
        }
    }

    /// One message from a node, dest || encrypted payload (lxmf_propagation on the client side).
    func ingestPropagated(_ data: [UInt8], iface: String) -> String {
        if data.count < LxMessage.overhead { return "too short" }
        if transientSeen(Rns.sha256(data)) { return "duplicate" }
        if Array(data[0..<LxMessage.destLen]) != dest.hash { return "not for us" }
        guard let plain = (try? cfg.identity.decrypt(Array(data[LxMessage.destLen...]), ratchetPrivs: dest.ratchetPrivs()))?.plaintext
        else {
            return "could not decrypt"
        }
        return inbound(dest.hash + plain, method: .propagated, iface: iface) != nil ? "delivered" : "dropped"
    }

    /// Downloads what the propagation node holds for us (request_messages_from_propagation_node and the two
    /// /get rounds): the list of transient ids, then the messages we lack, then the ids received so the node
    /// drops them. One sync at a time; the result also lands in `lastSync`.
    public func sync(maxMessages: Int = 0) -> Promise<SyncResult> {
        let (p, fresh): (Promise<SyncResult>, Bool) = lock.locked {
            if let s = syncPromise, !s.isDone { return (s, false) }
            let f = Promise<SyncResult>()
            syncPromise = f
            return (f, true)
        }
        if fresh { Task.detached(priority: .utility) { [weak self] in await self?.runSync(maxMessages, p) } }
        return p
    }

    func syncFail(_ f: Promise<SyncResult>, _ state: SyncState, _ why: String) {
        let r = SyncResult(state: state, received: 0, duplicates: 0, error: why)
        lock.locked {
            syncStateRaw = state
            lastSyncRaw = r
        }
        log("lxmf: sync failed: \(why) (\(state))")
        f.complete(r)
    }

    func syncDone(_ f: Promise<SyncResult>, received: Int, duplicates: Int, note: String) {
        let r = SyncResult(state: .complete, received: received, duplicates: duplicates)
        lock.locked {
            syncStateRaw = .complete
            syncProgressRaw = 1
            lastSyncRaw = r
        }
        log("lxmf: sync complete\(note)")
        f.complete(r)
    }

    /// The error a node answers a /get with, as a sync state; nil for a regular answer.
    private func syncError(_ v: MpValue) -> (SyncState, String)? {
        guard let code = v.asInt else { return nil }
        if code == Self.errorNoIdentity { return (.noIdentityRcvd, "the node wants identification") }
        if code == Self.errorNoAccess { return (.noAccess, "the node refused access") }
        return (.transferFailed, "the node answered error \(code)")
    }

    /// The active link to the propagation node, opened and awaited when there is none; nil when that failed (the sync is failed).
    private func syncLink(_ pn: [UInt8], _ f: Promise<SyncResult>) async -> Link? {
        if let l = lock.locked({ propagationLink.flatMap { $0.state == .active || $0.state == .stale ? $0 : nil } }) { return l }
        setSyncState(.linkEstablishing)
        let pendingLink = lock.locked { propagationLink.flatMap { $0.state == .pending || $0.state == .handshake ? $0 : nil } }
        do {
            let l = try pendingLink ?? openPropagationLink(pn)
            _ = try await l.established.wait(timeoutMs: l.establishTimeout + 2000)
            return l
        } catch {
            syncFail(f, .linkFailed, "link to \(Hex.encode(pn).prefix(8)) failed: \(error)")
            return nil
        }
    }

    /// One /get round trip on the link; nil when it failed (the link is torn down and the sync failed).
    private func syncRequest(_ link: Link, _ data: MpValue, timeoutMs: Int64, _ what: String, _ f: Promise<SyncResult>) async -> MpValue? {
        do {
            let v = try await node.links.request(link, path: Self.messageGetPath, data: data).result.wait(timeoutMs: timeoutMs)
            if let e = syncError(v) {
                node.links.teardown(link)
                syncFail(f, e.0, e.1)
                return nil
            }
            return v
        } catch {
            node.links.teardown(link)
            syncFail(f, .transferFailed, "\(what) failed: \(error)")
            return nil
        }
    }

    private func bins(_ v: MpValue) -> [[UInt8]] {
        (v.asArray ?? []).compactMap { item -> [UInt8]? in
            if case .bin(let b) = item { return b }
            return nil
        }
    }

    func runSync(_ maxMessages: Int, _ f: Promise<SyncResult>) async {
        lock.locked { syncProgressRaw = 0 }
        guard let pn = propagationNode() else { return syncFail(f, .noPath, "no propagation node known") }
        let pnShort = Hex.encode(pn).prefix(8)
        if !node.paths.has(pn) {
            setSyncState(.pathRequested)
            let wait = max(Self.prPathTimeoutMs, pathRequestWaitMs())
            _ = try? await node.requestPath(pn, timeoutMs: wait).wait(timeoutMs: wait + 1000)
            if !node.paths.has(pn) { return syncFail(f, .noPath, "no path to propagation node \(pnShort)") }
        }
        guard let link = await syncLink(pn, f) else { return }
        setSyncState(.linkEstablished)
        try? node.links.identify(link, cfg.identity)
        setSyncState(.requestSent)
        guard let list = await syncRequest(link, .array([.null, .null]), timeoutMs: Self.syncRequestTimeoutMs, "message list request", f)
        else { return }
        guard list.asArray != nil else {
            node.links.teardown(link)
            return syncFail(f, .transferFailed, "invalid message list")
        }
        let ids = bins(list)
        if ids.isEmpty { return syncDone(f, received: 0, duplicates: 0, note: ", nothing waiting at \(pnShort)") }
        var wants: [MpValue] = []
        var haves: [MpValue] = []
        for id in ids {
            if lock.locked({ processedTransientIds[Hex.encode(id)] != nil }) {
                haves.append(.bin(id))
            } else if maxMessages <= 0 || wants.count < maxMessages {
                wants.append(.bin(id))
            }
        }
        log("lxmf: requesting \(wants.count) message(s) from \(pnShort), \(haves.count) already here")
        setSyncState(.receiving)
        let request = MpValue.array([.array(wants), .array(haves), .int(Int64(cfg.deliveryLimit / 1000))])
        guard let got = await syncRequest(link, request, timeoutMs: Self.syncTransferTimeoutMs, "message download", f) else { return }
        setSyncState(.responseReceived)
        let msgs = bins(got)
        var received = 0
        var duplicates = 0
        var done: [MpValue] = []
        for m in msgs {
            switch ingestPropagated(m, iface: link.iface) {
            case "delivered": received += 1
            case "duplicate": duplicates += 1
            case let res: log("lxmf: propagated message not taken: \(res)")
            }
            done.append(.bin(Rns.sha256(m)))
        }
        if !done.isEmpty {
            // Tells the node which ones arrived so it deletes them; upstream waits for no answer.
            do {
                _ = try node.links.request(link, path: Self.messageGetPath, data: .array([.null, .array(done)]))
            } catch {
                log("lxmf: could not confirm the sync: \(error)")
            }
        }
        syncDone(
            f, received: received, duplicates: duplicates,
            note: ": \(received) new, \(duplicates) duplicate of \(msgs.count) from \(pnShort)")
    }
}
