// Mirrors test hubmsg/MemHubMsgStore.kt: the route's store in memory, with the semantics of the app's
// store: every method is one transaction, rolled back whole when a write in it fails. `fail` names
// the write to fail ("event", "missing", "message", "inbox", "op:read"), as the Bridge's tests used
// SQLite triggers. [MESHSAT-1584]
import Foundation

@testable import MeshSatHub

final class MemHubMsgStore: HubMsgStore, @unchecked Sendable {
    struct Row: Equatable {
        var id: Int64
        var transport: String
        var direction: String
        var sender: String
        var recipient: String
        var text: String
        var forwardedTo: String
    }

    struct TestFailure: Error, CustomStringConvertible {
        let description: String
    }

    private struct State {
        var rows: [Int64: Row] = [:]
        var ops: [String: HubOp] = [:]
        var events: [String: KeptHubEvent] = [:]
        var missing: [String: Int64] = [:]  // "op|event" -> since
        var inbox: [HubMsgInbox.Entry] = []
        var nextRow: Int64 = 1
    }

    private let lock = NSLock()
    private var s = State()

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
    private var failWrite: @Sendable (String) -> Bool = { _ in false }
    private var failEventWrite: @Sendable (HubEvent) -> Bool = { _ in false }

    /// Fails the named write ("event", "missing", "message", "inbox", "op:read").
    var fail: @Sendable (String) -> Bool {
        get { locked { failWrite } }
        set { locked { failWrite = newValue } }
    }

    /// Fails the write of one event (the Bridge tests' WHEN NEW.kind = ... triggers).
    var failEvent: @Sendable (HubEvent) -> Bool {
        get { locked { failEventWrite } }
        set { locked { failEventWrite = newValue } }
    }

    private static func key(_ op: String, _ event: String) -> String { op + "|" + event }
    private static func parts(_ k: String) -> (op: String, event: String) {
        let p = k.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(p[0]), p.count > 1 ? String(p[1]) : "")
    }

    private func check(_ write: String) throws {
        if failWrite(write) { throw TestFailure(description: "test: the \(write) write failed") }
    }

    private func tx<T>(_ body: (inout State) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        var copy = s
        let out = try body(&copy)
        s = copy
        return out
    }

    // MARK: What the tests read

    func rows() -> [Row] { locked { s.rows.values.sorted { $0.id < $1.id } } }
    func row(_ id: Int64) -> Row? { locked { s.rows[id] } }
    func ops() -> [HubOp] { locked { s.ops.values.sorted { ($0.createdAt, $0.opId) < ($1.createdAt, $1.opId) } } }
    func keptEvents(_ opId: String) -> [KeptHubEvent] { locked { s.events.values.filter { $0.event.opId == opId } } }

    // MARK: The status

    private func restatus(_ st: inout State, _ opId: String) throws {
        guard let op = st.ops[opId], let r = st.rows[op.messageId] else { return }
        try check("message")
        var row = r
        row.forwardedTo = HubMsgStatus.of(op, st.events.values.filter { $0.event.opId == opId })
        st.rows[r.id] = row
    }

    private func completedOp(_ st: State, _ opId: String) -> Bool {
        st.events.values.contains { $0.event.opId == opId && $0.valid && $0.event.cls == "completed" && !HubMsgStatus.isRefusal($0.event) }
    }

    private func terminalOp(_ st: State, _ opId: String) -> Bool {
        st.events.values.contains { $0.event.opId == opId && $0.valid && ["completed", "failed", "expired"].contains($0.event.cls) }
    }

    private func stillMissing(_ st: State, _ opId: String) -> Bool {
        st.missing.keys.contains { k in
            let (o, e) = Self.parts(k)
            return o == opId && st.events[e]?.event.opId != opId
        }
    }

    private func clearIdle(_ st: inout State, _ opId: String) {
        guard var op = st.ops[opId], op.replayAt != 0 else { return }
        if !st.missing.keys.contains(where: { Self.parts($0).op == opId }) {
            op.replayAt = 0
            st.ops[opId] = op
        }
    }

    // MARK: The sender

    func createOutgoing(_ op: HubOp, sender: String, text: String) async throws -> Int64 {
        try tx { st in
            try check("message")
            let id = st.nextRow
            st.nextRow += 1
            st.rows[id] = Row(
                id: id, transport: "hub", direction: "tx", sender: sender, recipient: op.recipient, text: text,
                forwardedTo: HubMsgStatus.queued)
            var o = op
            o.messageId = id
            st.ops[op.opId] = o
            return id
        }
    }

    func op(_ opId: String) async throws -> HubOp? {
        try tx { st in
            try check("op:read")
            return st.ops[opId]
        }
    }

    func unpublished(limit: Int) async throws -> [HubOp] {
        try tx { st in Array(st.ops.values.filter { $0.publishedAt == 0 }.sorted { $0.createdAt < $1.createdAt }.prefix(limit)) }
    }

    func markPublished(_ opId: String, atMs: Int64) async throws {
        try tx { st in
            guard var op = st.ops[opId] else { return }
            if op.publishedAt == 0 {
                op.publishedAt = atMs
                st.ops[opId] = op
            }
            try restatus(&st, opId)
        }
    }

    func keepEvent(_ e: HubEvent, valid: Bool, atMs: Int64) async throws -> KeptHubEvent {
        try tx { st in
            var kept: KeptHubEvent
            if var prev = st.events[e.eventId] {
                prev.added = false
                kept = prev
            } else {
                try check("event")
                if failEventWrite(e) { throw TestFailure(description: "test: the event \(e.kind) write failed") }
                kept = KeptHubEvent(event: e, valid: valid, added: true)
                var stored = kept
                stored.added = false
                st.events[e.eventId] = stored
            }
            if kept.valid && kept.event.cls == "completed" && !HubMsgStatus.isRefusal(kept.event) {
                for k in st.missing.keys where Self.parts(k).op == kept.event.opId { st.missing[k] = nil }
            } else {
                st.missing[Self.key(kept.event.opId, kept.event.eventId)] = nil
            }
            clearIdle(&st, kept.event.opId)
            try restatus(&st, kept.event.opId)
            return kept
        }
    }

    func wantReplay(_ opId: String, eventId: String, atMs: Int64) async throws {
        try tx { st in
            try check("missing")
            guard var op = st.ops[opId] else { return }
            if op.replayAt == 0 {
                op.replayAt = atMs
                st.ops[opId] = op
            }
            if st.missing[Self.key(opId, eventId)] == nil { st.missing[Self.key(opId, eventId)] = atMs }
        }
    }

    func resolveKeptMissing() async throws -> Int {
        try tx { st in
            let snapshot = st
            let gone = st.missing.keys.filter { k in
                let (o, e) = Self.parts(k)
                return (!e.isEmpty && snapshot.events[e] != nil) || completedOp(snapshot, o)
            }
            for k in gone { st.missing[k] = nil }
            for id in Array(st.ops.keys) { clearIdle(&st, id) }
            return gone.count
        }
    }

    func eventKept(_ eventId: String) async throws -> Bool { try tx { st in st.events[eventId] != nil } }
    func completed(_ opId: String) async throws -> Bool { try tx { st in completedOp(st, opId) } }
    func missing(_ opId: String) async throws -> [String] {
        try tx { st in st.missing.keys.map(Self.parts).filter { $0.op == opId }.map(\.event) }
    }

    private static func after(_ key: Int64, _ id: String, _ c: HubOpCursor) -> Bool { key > c.key || (key == c.key && id > c.opId) }

    func owed(nowMs: Int64, withinMs: Int64, after: HubOpCursor, limit: Int) async throws -> [HubOp] {
        try tx { st in
            let list = st.ops.values.filter {
                $0.replayAt != 0 && stillMissing(st, $0.opId) && !$0.submission.isEmpty && $0.replayGivenUpAt == 0
                    && $0.expiresAt + withinMs >= nowMs && Self.after($0.replayAt, $0.opId, after)
            }
            return Array(list.sorted { ($0.replayAt, $0.opId) < ($1.replayAt, $1.opId) }.prefix(limit))
        }
    }

    func toReconcile(nowMs: Int64, withinMs: Int64, after: HubOpCursor, limit: Int) async throws -> [HubOp] {
        try tx { st in
            let list = st.ops.values.filter {
                !$0.submission.isEmpty && $0.replayGivenUpAt == 0 && $0.expiresAt + withinMs >= nowMs && !completedOp(st, $0.opId)
                    && Self.after($0.createdAt, $0.opId, after)
            }
            return Array(list.sorted { ($0.createdAt, $0.opId) < ($1.createdAt, $1.opId) }.prefix(limit))
        }
    }

    func toGiveUp(nowMs: Int64, withinMs: Int64, limit: Int) async throws -> [HubOp] {
        try tx { st in
            let list = st.ops.values.filter {
                $0.replayGivenUpAt == 0 && $0.expiresAt + withinMs < nowMs && !completedOp(st, $0.opId)
                    && (stillMissing(st, $0.opId) || !terminalOp(st, $0.opId))
            }
            return Array(list.sorted { ($0.createdAt, $0.opId) < ($1.createdAt, $1.opId) }.prefix(limit))
        }
    }

    func giveUp(_ opId: String, atMs: Int64) async throws {
        try tx { st in
            guard var op = st.ops[opId] else { return }
            if op.replayGivenUpAt == 0 {
                op.replayGivenUpAt = atMs
                st.ops[opId] = op
            }
            try restatus(&st, opId)
        }
    }

    func pruneOps(nowMs: Int64) async throws -> Int {
        try tx { st in
            let gone = Set(st.ops.values.filter { HubMsgInbox.retainedUntil($0.expiresAt) < nowMs }.map(\.opId))
            for id in gone { st.ops[id] = nil }
            for (k, v) in st.events where gone.contains(v.event.opId) { st.events[k] = nil }
            for k in st.missing.keys where gone.contains(Self.parts(k).op) { st.missing[k] = nil }
            return gone.count
        }
    }

    // MARK: The receiver

    private final class InboxTx: HubMsgInbox.Transaction {
        var st: State
        let check: (String) throws -> Void
        init(_ st: State, check: @escaping (String) throws -> Void) {
            self.st = st
            self.check = check
        }
        func byOp(origin: String, opId: String) throws -> HubMsgInbox.Entry? { st.inbox.first { $0.origin == origin && $0.opId == opId } }
        func byMid(origin: String, mid: String) throws -> HubMsgInbox.Entry? {
            st.inbox.filter { $0.origin == origin && $0.mid == mid }.min { $0.committedAt < $1.committedAt }
        }
        func count() throws -> Int { st.inbox.count }
        func pruneBefore(_ nowMs: Int64) throws -> Int {
            let before = st.inbox.count
            st.inbox.removeAll { HubMsgInbox.retainedUntil($0.expiresAt) < nowMs }
            return before - st.inbox.count
        }
        func insert(_ e: HubMsgInbox.Entry, store: Bool, body: String) throws -> HubMsgInbox.Entry {
            var kept = e
            if store {
                try check("message")
                let id = st.nextRow
                st.nextRow += 1
                st.rows[id] = Row(
                    id: id, transport: "hub", direction: "rx", sender: e.origin, recipient: e.recipient, text: body, forwardedTo: "")
                kept.messageId = id
            }
            try check("inbox")
            st.inbox.append(kept)
            return kept
        }
    }

    func commitDelivery(_ d: HubDelivery, nowMs: Int64, clockEstablished: Bool, capacity: Int) async throws -> HubMsgInbox.Answer {
        try tx { st in
            let itx = InboxTx(st, check: { [self] w in try self.check(w) })
            let ans = try HubMsgInbox.commit(itx, d, nowMs: nowMs, clockEstablished: clockEstablished, capacity: capacity)
            st = itx.st
            return ans
        }
    }

    func pruneInbox(nowMs: Int64) async throws -> Int {
        try tx { st in
            let before = st.inbox.count
            st.inbox.removeAll { HubMsgInbox.retainedUntil($0.expiresAt) < nowMs }
            return before - st.inbox.count
        }
    }
}
