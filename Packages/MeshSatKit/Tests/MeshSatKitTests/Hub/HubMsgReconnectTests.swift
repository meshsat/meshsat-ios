// Mirrors test hubmsg/HubMsgReconnectTest.kt and ReviewR13Test.kt: a reconnect in the middle of the
// route's own work (r13 review, PH-R1): during a first publish (the review's reproduction), during a
// repeat, during a delayed listing, during a listing that comes back empty, just before an old walk
// marks itself done, and with an owed operation still in its wait; two passes at once; and a pass
// that began before a reconnect, which must neither send nor read anything for the new connection.
// Each recovery case loses the Hub's answer while the phone is off the Hub, then reconnects once;
// the new connection's walk must recover it with no further reconnect, under the same operation
// and event ids, with one chat row at the far end. [MESHSAT-1584]
import Foundation
import XCTest

@testable import MeshSatHub

final class HubMsgReconnectTests: XCTestCase {
    /// The route's store, with a hook inside the walk's listing (a slow database).
    final class SlowStore: HubMsgStore, @unchecked Sendable {
        let inner: MemHubMsgStore
        var onListing: (() async -> Void)?
        var listings = 0
        init(_ inner: MemHubMsgStore) { self.inner = inner }

        func toReconcile(nowMs: Int64, withinMs: Int64, after: HubOpCursor, limit: Int) async throws -> [HubOp] {
            listings += 1
            if let hook = onListing {
                onListing = nil
                await hook()
            }
            return try await inner.toReconcile(nowMs: nowMs, withinMs: withinMs, after: after, limit: limit)
        }
        func createOutgoing(_ op: HubOp, sender: String, text: String) async throws -> Int64 {
            try await inner.createOutgoing(op, sender: sender, text: text)
        }
        func op(_ opId: String) async throws -> HubOp? { try await inner.op(opId) }
        func unpublished(limit: Int) async throws -> [HubOp] { try await inner.unpublished(limit: limit) }
        func markPublished(_ opId: String, atMs: Int64) async throws { try await inner.markPublished(opId, atMs: atMs) }
        func keepEvent(_ e: HubEvent, valid: Bool, atMs: Int64) async throws -> KeptHubEvent {
            try await inner.keepEvent(e, valid: valid, atMs: atMs)
        }
        func wantReplay(_ opId: String, eventId: String, atMs: Int64) async throws {
            try await inner.wantReplay(opId, eventId: eventId, atMs: atMs)
        }
        func resolveKeptMissing() async throws -> Int { try await inner.resolveKeptMissing() }
        func eventKept(_ eventId: String) async throws -> Bool { try await inner.eventKept(eventId) }
        func completed(_ opId: String) async throws -> Bool { try await inner.completed(opId) }
        func missing(_ opId: String) async throws -> [String] { try await inner.missing(opId) }
        func owed(nowMs: Int64, withinMs: Int64, after: HubOpCursor, limit: Int) async throws -> [HubOp] {
            try await inner.owed(nowMs: nowMs, withinMs: withinMs, after: after, limit: limit)
        }
        func toGiveUp(nowMs: Int64, withinMs: Int64, limit: Int) async throws -> [HubOp] {
            try await inner.toGiveUp(nowMs: nowMs, withinMs: withinMs, limit: limit)
        }
        func giveUp(_ opId: String, atMs: Int64) async throws { try await inner.giveUp(opId, atMs: atMs) }
        func pruneOps(nowMs: Int64) async throws -> Int { try await inner.pruneOps(nowMs: nowMs) }
        func commitDelivery(_ d: HubDelivery, nowMs: Int64, clockEstablished: Bool, capacity: Int) async throws -> HubMsgInbox.Answer {
            try await inner.commitDelivery(d, nowMs: nowMs, clockEstablished: clockEstablished, capacity: capacity)
        }
        func pruneInbox(nowMs: Int64) async throws -> Int { try await inner.pruneInbox(nowMs: nowMs) }
    }

    final class World: @unchecked Sendable {
        let clock = HubMsgRouteTests.Clock(1_792_400_000_000)
        let hub = ContractHub()
        let memA = MemHubMsgStore()
        let storeA: SlowStore
        let storeB = MemHubMsgStore()
        let la: ContractHub.Link
        let lb: ContractHub.Link
        var a: HubMsgRoute!
        /// Runs once, inside the publish of the nth "out" (1-based), after the frame left.
        var onOut: [Int: () async -> Void] = [:]
        var outs = 0

        struct Pub: HubMsgRoute.Publisher {
            let world: World
            var principal: String { world.la.principal }
            func isConnected() async -> Bool { await world.la.isConnected() }
            func publishMsg(kind: String, payload: String) async -> HubMsgRoute.Published {
                let result = await world.la.publishMsg(kind: kind, payload: payload)
                if kind == "out" {
                    world.outs += 1
                    if let hook = world.onOut.removeValue(forKey: world.outs) { await hook() }
                }
                return result
            }
        }

        init() {
            storeA = SlowStore(memA)
            la = hub.link("bridge:phone-a")
            lb = hub.link("bridge:kit-b")
            let c = clock
            a = HubMsgRoute(store: storeA, pub: Pub(world: self), now: { c.t })
            hub.routes[la.principal] = a
            hub.routes[lb.principal] = HubMsgRoute(store: storeB, pub: lb, now: { c.t })
        }

        var t: Int64 {
            get { clock.t }
            set { clock.t = newValue }
        }

        /// The phone off the Hub while everything queued is carried (its answers are lost), then back.
        func dropAndReconnect() async {
            la.up = false
            await hub.pump()
            la.up = true
            a.onConnected()
        }

        /// A text whose completion is lost while the phone is off the Hub; the phone is back after.
        func sendAndLoseCompletion(_ text: String) async throws -> Int64 {
            guard case .queued(let id) = try await a.send(to: lb.principal, text: text) else {
                throw MemHubMsgStore.TestFailure(description: "not queued")
            }
            await hub.pumpOne()  // delivered to kit-b; hub_forwarded reaches the phone
            la.up = false
            await hub.pump()  // kit-b's answer: recipient_app_stored, published while the phone is away
            la.up = true
            return id
        }

        /// n texts the Hub holds for kit-b while it is away: operations without a completion.
        func held(_ n: Int) async throws {
            lb.up = false
            for i in 0..<n { _ = try await a.send(to: lb.principal, text: "held \(i)") }
            await hub.pump()
        }

        func status(_ id: Int64) -> String { memA.row(id)?.forwardedTo ?? "" }
        func opIds() -> Set<String> { Set(memA.ops().map(\.opId)) }

        func passes(_ n: Int) async {
            for _ in 0..<n {
                t += 60_000
                await a.pass()
                await hub.pump()
            }
        }
    }

    /// What every case must show: delivered, the same operations and events, one row each at kit-b.
    private func assertRecovered(_ w: World, _ ids: [Int64], _ opsBefore: Set<String>, file: StaticString = #filePath, line: UInt = #line) {
        for id in ids {
            XCTAssertEqual(HubMsgStatus.delivered, w.status(id), "delivered without another reconnect", file: file, line: line)
        }
        XCTAssertEqual(opsBefore, w.opIds(), "the same operations", file: file, line: line)
        XCTAssertEqual(opsBefore, Set(w.hub.ops.keys), "the Hub kept one operation each", file: file, line: line)
        for op in opsBefore {
            let events = w.memA.keptEvents(op).map(\.event.eventId)
            XCTAssertEqual(Set(events).count, events.count, "each event kept once", file: file, line: line)
        }
        XCTAssertEqual(
            ids.count, w.storeB.rows().filter { $0.direction == "rx" }.count, "one chat row each at kit-b", file: file, line: line)
    }

    /// The review's reproduction (r13 appendix), ported.
    func testReconnectDuringSuccessfulPublishMustStillRecover() async throws {
        let w = World()
        w.a.onConnected()
        w.onOut[1] = { await w.dropAndReconnect() }
        guard case .queued(let id) = try await w.a.send(to: w.lb.principal, text: "generation boundary") else {
            return XCTFail("not queued")
        }
        let ops = w.opIds()
        await w.passes(3)
        assertRecovered(w, [id], ops)
    }

    func testAReconnectDuringARepeatDoesNotCountTheRepeatForTheNewConnection() async throws {
        let w = World()
        w.a.onConnected()
        await w.a.pass()  // the walk over nothing
        let id = try await w.sendAndLoseCompletion("lost during a repeat")
        let ops = w.opIds()
        w.a.onConnected()  // generation 2: its walk repeats the submission...
        w.onOut[2] = { await w.dropAndReconnect() }  // ...and the answer to that repeat is lost too: generation 3
        await w.a.pass()
        await w.passes(3)
        assertRecovered(w, [id], ops)
    }

    func testAReconnectDuringADelayedListingLeavesTheNewWalkWhole() async throws {
        let w = World()
        w.a.onConnected()
        await w.a.pass()
        let ids = [try await w.sendAndLoseCompletion("one"), try await w.sendAndLoseCompletion("two")]
        let ops = w.opIds()
        w.a.onConnected()
        // The listing of generation 2's walk is slow; the phone drops and comes back meanwhile, and
        // the old pass's repeats then lose their answers in one more drop.
        w.storeA.onListing = {
            w.la.up = false
            w.la.up = true
            w.a.onConnected()
        }
        w.onOut[3] = { await w.dropAndReconnect() }
        await w.a.pass()
        await w.passes(3)
        assertRecovered(w, ids, ops)
    }

    func testAReconnectJustBeforeAnOldWalkMarksItselfDoneDoesNotEndTheNewWalk() async throws {
        let w = World()
        w.a.onConnected()
        await w.a.pass()
        let ids = [try await w.sendAndLoseCompletion("first"), try await w.sendAndLoseCompletion("lost at the end")]
        let ops = w.opIds()
        w.a.onConnected()
        // The walk's last repeat loses its answer and the phone reconnects before the walk ends.
        w.onOut[4] = { await w.dropAndReconnect() }
        await w.a.pass()
        await w.hub.pump()
        await w.passes(3)
        assertRecovered(w, ids, ops)
    }

    final class TaskBox: @unchecked Sendable {
        var task: Task<Void, Never>?
    }

    /// The connect's pass and the periodic one at the same time: one waits for the other, so the
    /// walk repeats each operation once for its connection (PH-R1).
    func testTwoPassesAtOnceRepeatAnOperationOnceForTheConnection() async throws {
        let w = World()
        w.a.onConnected()
        await w.a.pass()
        let id = try await w.sendAndLoseCompletion("two passes")
        let ops = w.opIds()
        w.a.onConnected()
        let second = TaskBox()
        // A second pass starts while the first one's repeat is on the way.
        w.onOut[2] = {
            second.task = Task { await w.a.pass() }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        await w.a.pass()
        await second.task?.value
        await w.hub.pump()
        XCTAssertEqual(1, w.hub.replays, "one repeat for the connection")
        assertRecovered(w, [id], ops)
    }

    func testAnOwedOperationStillInItsWaitIsAskedByTheNewConnectionsWalkAtOnce() async throws {
        let w = World()
        w.a.onConnected()
        await w.a.pass()
        // hub_forwarded cannot be kept: the operation is owed in the database.
        w.memA.failEvent = { $0.kind == "hub_forwarded" }
        let id = try await w.sendAndLoseCompletion("owed and waiting")
        w.memA.failEvent = { _ in false }
        let ops = w.opIds()
        w.t += 31_000
        // The owed repeat goes out, and its answers are lost in a drop: a new connection, before
        // this pass reaches the walk, which it then leaves unread.
        w.onOut[2] = { await w.dropAndReconnect() }
        let listings = w.storeA.listings
        await w.a.pass()
        XCTAssertEqual(listings, w.storeA.listings, "the old pass read the new connection's walk")
        // 10 s later the operation is still in its 30 s wait; the new connection's walk asks anyway.
        w.t += 10_000
        await w.a.pass()
        await w.hub.pump()
        assertRecovered(w, [id], ops)
    }

    func testAReconnectDuringAListingThatComesBackEmptyDoesNotEndTheNewWalk() async throws {
        let w = World()
        w.a.onConnected()
        await w.a.pass()
        try await w.held(HubMsgRoute.walkBatch)
        w.a.onConnected()
        let before = w.hub.replays
        await w.a.pass()  // a full batch: every operation asked, the walk not done yet
        await w.hub.pump()
        XCTAssertEqual(HubMsgRoute.walkBatch, w.hub.replays - before)
        // The next listing, past the last operation, comes back empty; the phone reconnects meanwhile.
        w.storeA.onListing = { w.a.onConnected() }
        await w.a.pass()
        await w.hub.pump()
        await w.passes(2)
        XCTAssertEqual(2 * HubMsgRoute.walkBatch, w.hub.replays - before, "the new connection's walk asked every operation")
    }

    func testAPassThatBeganBeforeAReconnectSendsNothingAfterIt() async throws {
        let w = World()
        w.a.onConnected()
        await w.a.pass()
        try await w.held(3)
        w.a.onConnected()
        w.storeA.onListing = { w.a.onConnected() }  // the walk's listing is slow; the phone reconnects meanwhile
        let outs = w.outs
        await w.a.pass()
        XCTAssertEqual(outs, w.outs, "the old pass repeated for the new connection")
        await w.hub.pump()
        await w.a.pass()
        await w.hub.pump()
        XCTAssertEqual(3, w.outs - outs, "the new connection's walk, once each")
    }
}
