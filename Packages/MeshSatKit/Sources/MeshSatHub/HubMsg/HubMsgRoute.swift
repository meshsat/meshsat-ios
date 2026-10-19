// Mirrors hubmsg/HubMsgRoute.kt: the Hub app route on the phone (hub_msg, HeMB-NG stage 2,
// MESHSAT-1584). A text to a contact's "bridge:<id>" goes to the Hub on this phone's msg/out, and
// what the Hub reports on msg/status is its delivery status in the chat, up to "delivered to the
// MeshSat app"; what the Hub delivers on msg/in is committed in the inbox (C3) with its chat row,
// then acknowledged on msg/ack. The phone is a bridge principal (C4.1). The contract is the Hub's
// docs/bridge-hub-protocol.md "Messaging v1"; this is the Bridge's internal/hubroute as its r12
// review accepted it (A11-A15), with one difference that the phone's session imposes:
//
// The phone's MQTT session is clean, so nothing the Hub publishes while it is off the Hub reaches
// it later. Every connect therefore walks once more over every operation without a completion
// inside the bound and repeats its submission (the walk the Bridge makes once per process start,
// A12); the Hub answers a repeat with every event of it under the same ids (C4).
import Foundation
import Logging

public final class HubMsgRoute: @unchecked Sendable {
    /// What the route needs from the Hub session (HubReporter).
    public protocol Publisher: Sendable {
        /// This phone's principal, "bridge:<its id>".
        var principal: String { get }
        func isConnected() async -> Bool
        /// Publishes on this phone's msg/<kind> at QoS 1 and waits for the broker: ok once it took
        /// it, notSent when nothing left the phone (not connected), unknown when it may have reached
        /// the broker (a timeout).
        func publishMsg(kind: String, payload: String) async -> Published
    }

    public enum Published: Sendable { case ok, notSent, unknown }

    public enum SendResult: Sendable, Equatable {
        case queued(messageId: Int64)
        case refused(String)
    }

    /// How long the Hub keeps trying a message from this phone.
    public static let messageLifetimeMs: Int64 = 24 * 60 * 60 * 1000
    /// Repeats stop this long after an operation's deadline. The Hub answers a repeat from what it
    /// stores for a day past the deadline (C4), so a repeat inside this bound is always a replay.
    public static let replayWithinMs: Int64 = 12 * 60 * 60 * 1000
    public static let passMs: Int64 = 30_000
    static let batch = 50
    static let owedBatch = 50
    static let walkBatch = 100

    private static let log = Logger(label: "HubMsg")

    /// An operation's repeats: how many, when, whether an answer failed since, and in which connect.
    private final class Ask {
        var n = 0
        var at: Int64 = 0
        var failed = false
        var connect = -1
    }

    private let store: HubMsgStore
    private let pub: Publisher
    private let now: @Sendable () -> Int64
    /// A message the moment it is stored, once per message (a notification).
    private let onStored: @Sendable (_ from: String, _ text: String, _ messageId: Int64) -> Void

    private let lock = NSLock()
    private var replay: [String: Set<String>] = [:]  // op id -> missing events held only in memory
    private var asks: [String: Ask] = [:]
    private var walk = HubOpCursor()
    private var walkDone = false
    private var connect = 0
    private var owedAt = HubOpCursor()
    private var lastPrune: Int64 = 0

    public init(
        store: HubMsgStore, pub: Publisher, now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        onStored: @escaping @Sendable (_ from: String, _ text: String, _ messageId: Int64) -> Void = { _, _, _ in }
    ) {
        self.store = store
        self.pub = pub
        self.now = now
        self.onStored = onStored
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: Send

    /// Takes a text for `to` ("bridge:<id>"): the chat row and the operation in one transaction,
    /// then a publish when the Hub is connected; otherwise it waits in the queue for the next one.
    public func send(to: String, text: String) async throws -> SendResult {
        if HubMsgWire.bridgeOf(to).isEmpty { return .refused("\"\(to)\" is not a bridge:<id> address") }
        if to == pub.principal { return .refused("the address is this phone") }
        let bytes = text.utf8.count
        if bytes == 0 { return .refused("an empty message") }
        if bytes > HubMsgWire.maxBody { return .refused("\(bytes) bytes, the Hub takes \(HubMsgWire.maxBody)") }
        let t = now()
        let mid = HubMsgIds.newV7(t)
        let opId = HubMsgIds.newV7(t)
        // No route follows the Hub on the phone, so the operation lives as long as the message.
        let expires = t + Self.messageLifetimeMs
        let sub = HubSubmission.create(opId: opId, mid: mid, to: to, body: text, midExpiresAt: expires, expiresAt: expires)
        let id = try await store.createOutgoing(
            HubOp(opId: opId, mid: mid, recipient: to, messageId: 0, expiresAt: expires, createdAt: t, submission: sub.toJson()),
            sender: pub.principal, text: text)
        try? await publishPending()
        return .queued(messageId: id)
    }

    /// Publishes the operations the broker has not taken yet. A publish whose answer did not come may
    /// have reached the Hub: it goes again, unchanged, and the Hub takes the repeat as one (C4).
    public func publishPending() async throws {
        guard await pub.isConnected() else { return }
        for op in try await store.unpublished(limit: Self.batch) {
            switch await pub.publishMsg(kind: "out", payload: op.submission) {
            case .ok:
                let t = now()
                // A first publish in this connect is as good as its repeat: the walk skips it.
                locked {
                    let a = asks[op.opId] ?? Ask()
                    a.at = t
                    a.connect = connect
                    asks[op.opId] = a
                }
                try await store.markPublished(op.opId, atMs: t)
            case .notSent, .unknown:
                return
            }
        }
    }

    // MARK: msg/status

    /// One msg/status payload: an event of one of this phone's operations, or the Hub's refusal of a
    /// submission. Kept and taken into the chat row in one transaction; an event that could not be
    /// kept makes its operation owed a repeat.
    public func handleStatus(_ payload: String) async {
        guard let st = HubStatus.parse(payload) else {
            Self.log.warning("a status that is neither an event nor a refusal, ignored")
            return
        }
        let opId: String
        let eventId: String
        switch st {
        case .event(let e):
            opId = e.opId
            eventId = e.eventId
        case .refusal(let r):
            opId = r.opId
            eventId = HubMsgStatus.refusalEventId(r.opId, r.reason)
        }
        let found: HubOp?
        do {
            found = try await store.op(opId)
        } catch {
            Self.log.warning("status not read against its operation; a repeat is owed: \(error)")
            await oweReplay(opId, eventId)
            return
        }
        guard let op = found else { return }  // not one of this phone's
        let event: HubEvent
        let valid: Bool
        switch st {
        case .refusal(let r):
            guard r.mid == op.mid else { return }
            event = HubEvent(opId: op.opId, eventId: eventId, cls: "failed", kind: "hub_refusal", reason: r.reason, authority: "hub")
            valid = true
        case .event(var e):
            e.source = "status_topic"
            event = e
            valid = HubMsgReducer.valid(HubMsgReducer.Operation(opId: op.opId, mid: op.mid, recipient: op.recipient), e)
        }
        do {
            let kept = try await store.keepEvent(event, valid: valid, atMs: now())
            locked {
                if kept.valid && kept.event.cls == "completed" {
                    replay[op.opId] = nil
                    asks[op.opId] = nil
                } else if var s = replay[op.opId] {
                    s.remove(kept.event.eventId)
                    replay[op.opId] = s.isEmpty ? nil : s
                }
            }
        } catch {
            Self.log.warning("event not kept; a repeat is owed: \(error)")
            await oweReplay(op.opId, event.eventId)
        }
    }

    /// An event of opId is missing: owed in the database when it can be written, in memory when not.
    private func oweReplay(_ opId: String, _ eventId: String) async {
        locked { asks[opId]?.failed = true }
        do {
            try await store.wantReplay(opId, eventId: eventId, atMs: now())
            return
        } catch {
            Self.log.warning("owed repeat not kept, held in memory: \(error)")
        }
        locked { replay[opId, default: []].insert(eventId) }
    }

    // MARK: Repeats

    /// A connect: the walk starts again over every operation without a completion (the session is
    /// clean), and asks each of them once in this connect, whatever its wait.
    public func onConnected() {
        locked {
            walk = HubOpCursor()
            walkDone = false
            connect += 1
        }
    }

    private func askedThisConnect(_ opId: String) -> Bool { locked { asks[opId]?.connect == connect } }

    private func due(_ opId: String, _ t: Int64) -> Bool {
        locked {
            guard let a = asks[opId] else { return true }
            if a.failed { return true }
            var wait: Int64 = 30_000
            var i = 1
            while i < a.n && wait < 30 * 60_000 {
                wait *= 2
                i += 1
            }
            return t - a.at >= min(wait, 30 * 60_000)
        }
    }

    private func repeatSubmission(_ op: HubOp, _ t: Int64) async -> Bool {
        // From here a failure to keep an answer counts against this repeat, one that comes before
        // the publish returns included.
        let a: Ask = locked {
            let a = asks[op.opId] ?? Ask()
            a.failed = false
            asks[op.opId] = a
            return a
        }
        guard await pub.publishMsg(kind: "out", payload: op.submission) == .ok else {
            locked { a.failed = true }  // nothing went out: not a reason to wait
            return false
        }
        locked {
            a.n += 1
            a.at = t
            a.connect = connect
        }
        if op.publishedAt == 0 { try? await store.markPublished(op.opId, atMs: t) }
        return true
    }

    /// Asks the Hub again, with the kept submission unchanged, for the events of every operation that
    /// may be missing one, a bounded batch of each kind per pass: the owed (in the database, round and
    /// round, and in memory), and while this connect's walk is not done, the next operations without a
    /// completion. An obligation ends when its event or a completion is kept, or at the bound, where
    /// the chat row reads "outcome unknown".
    public func requestReplays() async {
        let t = now()
        _ = try? await store.resolveKeptMissing()
        await giveUpPastBound(t)
        guard await pub.isConnected() else { return }
        var asked: Set<String> = []
        // An owed operation is asked as its wait allows; the walk asks each operation once per
        // connect, since what the Hub said while the phone was away is gone.
        func ask(_ op: HubOp, walking: Bool = false) async -> Bool {
            guard asked.insert(op.opId).inserted else { return true }
            if walking {
                if askedThisConnect(op.opId) { return true }
                return await repeatSubmission(op, t)
            }
            if !due(op.opId, t) { return true }
            return await repeatSubmission(op, t)
        }

        let cur = locked { owedAt }
        let owed = (try? await store.owed(nowMs: t, withinMs: Self.replayWithinMs, after: cur, limit: Self.owedBatch)) ?? []
        for op in owed { _ = await ask(op) }
        locked {
            if owed.count < Self.owedBatch {
                owedAt = HubOpCursor()
            } else if let last = owed.last {
                owedAt = HubOpCursor(key: last.replayAt, opId: last.opId)
            }
        }

        for id in locked({ Array(replay.keys) }) {
            let found: HubOp?
            do {
                found = try await store.op(id)
            } catch {
                continue  // still owed
            }
            guard let op = found, !op.submission.isEmpty, op.replayGivenUpAt == 0 else {
                locked { replay[id] = nil }
                continue
            }
            if op.expiresAt + Self.replayWithinMs < t {
                if await stillMissing(id) { await giveUp(op, t) }
                continue
            }
            if await stillMissing(id) { _ = await ask(op) }
        }

        let (done, wcur) = locked { (walkDone, walk) }
        if done { return }
        guard let ops = try? await store.toReconcile(nowMs: t, withinMs: Self.replayWithinMs, after: wcur, limit: Self.walkBatch) else {
            return
        }
        for op in ops {
            if await !ask(op, walking: true) { return }  // the walk stays here and goes on from it at the next pass
            locked { walk = HubOpCursor(key: op.createdAt, opId: op.opId) }
        }
        if ops.count < Self.walkBatch { locked { walkDone = true } }
    }

    /// Strikes from an operation's in-memory missing events those kept by now; whether any is left.
    private func stillMissing(_ opId: String) async -> Bool {
        if (try? await store.completed(opId)) == true {
            locked { replay[opId] = nil }
            return false
        }
        let ids = locked { Array(replay[opId] ?? []) }
        var left = 0
        for id in ids {
            if (try? await store.eventKept(id)) == true {
                locked {
                    replay[opId]?.remove(id)
                }
            } else {
                left += 1
            }
        }
        if left == 0 { locked { replay[opId] = nil } }
        return left > 0
    }

    private func giveUpPastBound(_ t: Int64) async {
        let ops = (try? await store.toGiveUp(nowMs: t, withinMs: Self.replayWithinMs, limit: Self.owedBatch)) ?? []
        for op in ops { await giveUp(op, t) }
    }

    private func giveUp(_ op: HubOp, _ t: Int64) async {
        do {
            try await store.giveUp(op.opId, atMs: t)
        } catch {
            return  // given up at the next pass
        }
        locked {
            replay[op.opId] = nil
            asks[op.opId] = nil
        }
        Self.log.warning("the Hub's outcome of an operation never reached this phone inside the bound; stopped asking")
    }

    // MARK: msg/in

    /// One delivery: commit (C3, the chat row with it), then the answer on msg/ack, then the notice.
    public func handleIn(_ payload: String) async {
        guard let d = HubDelivery.fromJson(payload), d.v == 1 else {
            Self.log.warning("a delivery that does not parse, ignored")
            return
        }
        if d.to != pub.principal || HubMsgWire.bridgeOf(d.from).isEmpty {
            Self.log.warning("a delivery not addressed to this phone, ignored")
            return
        }
        let ans: HubMsgInbox.Answer
        do {
            ans = try await store.commitDelivery(d, nowMs: now(), clockEstablished: true, capacity: HubMsgInbox.capacity)
        } catch {
            // Nothing committed, nothing answered: the Hub delivers it again.
            Self.log.warning("delivery not committed: \(error)")
            return
        }
        // Committed; a lost answer is given again from the inbox at the Hub's next delivery.
        _ = await pub.publishMsg(
            kind: "ack", payload: HubAck(opId: d.opId, mid: d.mid, from: d.from, result: ans.result, reason: ans.reason).toJson())
        if ans.storedNow { onStored(d.from, d.body, ans.messageId) }
    }

    // MARK: The pass

    /// What the gateway runs at each connect and every passMs: the queue, the repeats, and the hourly prune.
    public func pass() async {
        try? await publishPending()
        await requestReplays()
        let t = now()
        let prune = locked { t - lastPrune >= 60 * 60_000 }
        if prune {
            _ = try? await store.pruneInbox(nowMs: t)
            _ = try? await store.pruneOps(nowMs: t)
            locked { lastPrune = t }
        }
    }
}
