// Mirrors test hubmsg/HubMsgRouteTest.kt: the phone's Hub app route against a Hub that follows the
// contract (ContractHub), with a second route as the kit at the far end: the delivery status up to
// "delivered to the MeshSat app", the queue and the repeats, the Hub's refusal, copies and
// reordering, what the Hub said while the phone was off the Hub, the recovery of an event the phone
// could not keep (A11-A15, also across a restart and after a weaker outcome), the bound, the walk,
// and the receiving side (C3). [MESHSAT-1584]
import Foundation
import XCTest

@testable import MeshSatHub

final class HubMsgRouteTests: XCTestCase {
    final class Clock: @unchecked Sendable {
        var t: Int64
        init(_ t: Int64) { self.t = t }
    }

    final class Stored: @unchecked Sendable {
        var lines: [String] = []
    }

    final class Pair {
        let clock = Clock(1_792_400_000_000)
        let hub = ContractHub()
        let storeA = MemHubMsgStore()
        let storeB = MemHubMsgStore()
        let linkA: ContractHub.Link
        let linkB: ContractHub.Link
        let storedAtB = Stored()
        var a: HubMsgRoute
        let b: HubMsgRoute

        init() {
            linkA = hub.link("bridge:phone-a")
            linkB = hub.link("bridge:kit-b")
            let c = clock
            let s = storedAtB
            a = HubMsgRoute(store: storeA, pub: linkA, now: { c.t })
            b = HubMsgRoute(store: storeB, pub: linkB, now: { c.t }, onStored: { from, text, _ in s.lines.append("\(from): \(text)") })
            hub.routes["bridge:phone-a"] = a
            hub.routes["bridge:kit-b"] = b
        }

        var t: Int64 {
            get { clock.t }
            set { clock.t = newValue }
        }

        /// phone-a's process stopping and starting over the same store: the route's memory is gone.
        func restartA() {
            let c = clock
            a = HubMsgRoute(store: storeA, pub: linkA, now: { c.t })
            hub.routes["bridge:phone-a"] = a
        }

        func send(_ text: String = "Water at the north gate") async throws -> Int64 {
            guard case .queued(let id) = try await a.send(to: "bridge:kit-b", text: text) else {
                throw MemHubMsgStore.TestFailure(description: "not queued")
            }
            return id
        }

        func statusA(_ id: Int64) -> String { storeA.row(id)?.forwardedTo ?? "" }
        func rxB() -> [MemHubMsgStore.Row] { storeB.rows().filter { $0.direction == "rx" } }
        func op() -> HubOp { storeA.ops()[0] }
        func op2(_ messageId: Int64) -> HubOp? { storeA.ops().first { $0.messageId == messageId } }
    }

    private func kind(_ f: ContractHub.Frame) -> String { HubMsgWire.parse(f.payload)?.string("kind") ?? "" }

    func testATextReachesTheFarAppAndReadsDelivered() async throws {
        let p = Pair()
        let id = try await p.send()
        XCTAssertEqual(HubMsgStatus.accepted, p.statusA(id))
        await p.hub.pump()
        XCTAssertEqual(HubMsgStatus.delivered, p.statusA(id))
        XCTAssertEqual(["bridge:phone-a: Water at the north gate"], p.storedAtB.lines)
        let rx = try XCTUnwrap(p.rxB().first)
        XCTAssertEqual(p.rxB().count, 1)
        XCTAssertEqual(rx.sender, "bridge:phone-a")
        XCTAssertEqual(rx.text, "Water at the north gate")
        XCTAssertEqual(Set(p.storeA.keptEvents(p.op().opId).map(\.event.cls)), ["forwarded", "completed"])
    }

    func testAnAddressThatIsNotABridgeThisPhoneAnEmptyOrAnOversizeTextNeverReachTheQueue() async throws {
        let p = Pair()
        let cases: [(String, String)] = [
            ("kit-b", "x"), ("bridge:", "x"), ("bridge:phone-a", "x"), ("bridge:kit-b", ""),
            ("bridge:kit-b", String(repeating: "x", count: HubMsgWire.maxBody + 1)),
        ]
        for (to, text) in cases {
            guard case .refused = try await p.a.send(to: to, text: text) else { return XCTFail("\(to)/\(text.count) not refused") }
        }
        XCTAssertTrue(p.storeA.rows().isEmpty && p.hub.queue.isEmpty)
        guard case .queued = try await p.a.send(to: "bridge:kit-b", text: String(repeating: "x", count: HubMsgWire.maxBody)) else {
            return XCTFail("the largest body was not queued")
        }
    }

    func testOffTheHubATextWaitsInTheQueueAndGoesAtTheNextConnect() async throws {
        let p = Pair()
        p.linkA.up = false
        let id = try await p.send()
        XCTAssertEqual(HubMsgStatus.queued, p.statusA(id))
        XCTAssertTrue(p.hub.queue.isEmpty)
        p.linkA.up = true
        p.a.onConnected()
        await p.a.pass()
        await p.hub.pump()
        XCTAssertEqual(HubMsgStatus.delivered, p.statusA(id))
        XCTAssertEqual(1, p.rxB().count)
    }

    func testAPublishWhoseAnswerDidNotComeGoesAgainUnchangedAndTheMessageIsStoredOnce() async throws {
        let p = Pair()
        p.linkA.answer = .unknown
        let id = try await p.send()
        XCTAssertEqual(HubMsgStatus.queued, p.statusA(id))
        p.linkA.answer = .ok
        await p.a.pass()
        await p.hub.pump()
        XCTAssertEqual(HubMsgStatus.delivered, p.statusA(id))
        XCTAssertEqual(1, p.rxB().count)
        XCTAssertEqual(1, p.hub.replays)  // the second publish was a repeat of the first, answered from what the Hub kept
    }

    func testTheHubsRefusalReadsNotSentAndIsKeptOnce() async throws {
        let p = Pair()
        p.hub.refuse = { _ in "refused_unknown_recipient" }
        let id = try await p.send()
        await p.hub.pump()
        XCTAssertEqual(HubMsgStatus.refusedPrefix + "refused_unknown_recipient", p.statusA(id))
        for f in p.hub.statuses { await p.hub.replay(f) }
        XCTAssertEqual(1, p.storeA.keptEvents(p.op().opId).count)
        XCTAssertEqual(0, p.rxB().count)
    }

    func testCopiesAndReorderingChangeNothing() async throws {
        let p = Pair()
        let id = try await p.send()
        await p.hub.pump()
        for f in p.hub.statuses.reversed() {
            await p.hub.replay(f)
            await p.hub.replay(f)
        }
        for f in p.hub.deliveries { await p.hub.replay(f) }
        await p.hub.pump()
        XCTAssertEqual(HubMsgStatus.delivered, p.statusA(id))
        XCTAssertEqual(1, p.rxB().count)
        XCTAssertEqual(["bridge:phone-a: Water at the north gate"], p.storedAtB.lines)
    }

    func testWhatTheHubSaidWhileThePhoneWasOffTheHubIsAskedForAtTheNextConnect() async throws {
        let p = Pair()
        let id = try await p.send()
        // The submission goes, kit-b stores it and answers, but the phone is off the Hub by then.
        await p.hub.pumpOne()  // out: delivered to kit-b (its answer queued) and hub_forwarded to the phone
        p.linkA.up = false
        await p.hub.pump()  // the answer: recipient_app_stored, published while the phone is away
        XCTAssertEqual(HubMsgStatus.forwarded, p.statusA(id))
        p.linkA.up = true
        p.a.onConnected()
        await p.a.pass()
        await p.hub.pump()
        XCTAssertEqual(HubMsgStatus.delivered, p.statusA(id))
        XCTAssertEqual(1, p.hub.replays)
        await p.a.pass()  // the walk is done for this connect, and nothing is owed
        await p.hub.pump()
        XCTAssertEqual(1, p.hub.replays)
    }

    func testAnEventThePhoneCouldNotKeepIsAskedForAgainAndKeptOnce() async throws {
        let p = Pair()
        await p.a.pass()  // the connect's walk, over nothing yet
        p.storeA.failEvent = { $0.kind == "recipient_app_stored" }
        let id = try await p.send()
        await p.hub.pump()
        XCTAssertEqual(HubMsgStatus.forwarded, p.statusA(id))
        let op = p.op()
        XCTAssertNotEqual(0, op.replayAt, "owed")
        let missing = try await p.storeA.missing(op.opId)
        XCTAssertEqual(1, missing.count)
        p.storeA.failEvent = { _ in false }
        await p.a.pass()
        await p.hub.pump()
        XCTAssertEqual(HubMsgStatus.delivered, p.statusA(id))
        XCTAssertEqual(0, p.op().replayAt)
        let after = try await p.storeA.missing(op.opId)
        XCTAssertTrue(after.isEmpty)
        XCTAssertEqual(1, p.rxB().count)
    }

    func testBothWritesFailingThenARestartStillRecoversIt() async throws {
        let p = Pair()
        p.storeA.failEvent = { $0.kind == "recipient_app_stored" }
        p.storeA.fail = { $0 == "missing" }
        let id = try await p.send()
        await p.hub.pump()
        XCTAssertEqual(0, p.op().replayAt)
        p.storeA.failEvent = { _ in false }
        p.storeA.fail = { _ in false }
        p.restartA()
        p.a.onConnected()
        await p.a.pass()
        await p.hub.pump()
        XCTAssertEqual(HubMsgStatus.delivered, p.statusA(id))
    }

    func testBothWritesFailingInARunningProcessThatAlreadyWalkedIsRecoveredFromMemory() async throws {
        let p = Pair()
        await p.a.pass()
        p.storeA.failEvent = { $0.kind == "recipient_app_stored" }
        p.storeA.fail = { $0 == "missing" }
        let id = try await p.send()
        await p.hub.pump()
        await p.a.pass()  // the send's own walk: nothing reconciled yet that was lost
        p.storeA.failEvent = { _ in false }
        p.storeA.fail = { _ in false }
        await p.hub.pump()
        await p.a.pass()
        await p.hub.pump()
        XCTAssertEqual(HubMsgStatus.delivered, p.statusA(id))
    }

    func testACompletionLostAfterAnExpiryIsStillAskedFor() async throws {
        let p = Pair()
        await p.a.pass()
        p.linkB.up = false  // kit-b is away: the delivery is lost there
        let id = try await p.send()
        await p.hub.pump()
        await p.hub.emit("hub_expired", "expired", "hub", "expired")
        XCTAssertEqual(HubMsgStatus.expired, p.statusA(id))
        p.storeA.failEvent = { $0.kind == "recipient_app_stored" }
        await p.hub.emit("recipient_app_stored", "completed", "recipient")  // a late stored answer the Hub records
        XCTAssertEqual(HubMsgStatus.expired, p.statusA(id))
        p.storeA.failEvent = { _ in false }
        let expiry = try XCTUnwrap(p.hub.statuses.first { kind($0) == "hub_expired" })
        await p.hub.replay(expiry)  // an old copy ends nothing
        XCTAssertNotEqual(0, p.op().replayAt)
        await p.a.pass()
        await p.hub.pump()
        XCTAssertEqual(HubMsgStatus.delivered, p.statusA(id))
    }

    func testAtTheBoundThePhoneStopsAskingForWhatIsReallyMissingAndOnlyThat() async throws {
        let p = Pair()
        await p.a.pass()
        p.linkB.up = false
        p.storeA.failEvent = { $0.kind == "recipient_app_stored" }
        let missingOne = try await p.send("a completion lost")
        await p.hub.pump()
        await p.hub.emit("recipient_app_stored", "completed", "recipient")
        p.storeA.failEvent = { _ in false }
        guard case .queued(let second) = try await p.a.send(to: "bridge:kit-b", text: "an expiry kept") else {
            return XCTFail("not queued")
        }
        await p.hub.pump()
        let opSecond = try XCTUnwrap(p.op2(second))
        await p.hub.publish(
            "bridge:phone-a", "status",
            HubEvent(
                opId: opSecond.opId, mid: opSecond.mid, recipient: opSecond.recipient, eventId: HubMsgIds.newV7(p.t), rev: 2,
                cls: "expired",
                kind: "hub_expired", reason: "expired", authority: "hub"
            ).toJson())
        XCTAssertEqual(HubMsgStatus.expired, p.statusA(second))
        p.linkA.up = false
        p.t = try XCTUnwrap(p.op2(missingOne)).expiresAt + HubMsgRoute.replayWithinMs + 1
        await p.a.pass()
        await p.a.pass()
        XCTAssertEqual(HubMsgStatus.unknown, p.statusA(missingOne))
        XCTAssertEqual(HubMsgStatus.expired, p.statusA(second))
        let given = try XCTUnwrap(p.op2(missingOne))
        XCTAssertTrue(given.replayGivenUpAt != 0 && given.replayAt != 0)  // given up, not recovered
        XCTAssertEqual(0, p.op2(second)?.replayGivenUpAt)
    }

    func testAConnectWalksEveryOperationWithoutACompletionABatchAPassOnce() async throws {
        let p = Pair()
        await p.a.pass()
        p.linkB.up = false
        for i in 0..<250 { _ = try await p.a.send(to: "bridge:kit-b", text: "text \(i)") }
        await p.hub.pump()
        let before = p.hub.replays
        p.a.onConnected()
        for _ in 0..<3 {
            await p.a.pass()
            await p.hub.pump()
        }
        XCTAssertEqual(250, p.hub.replays - before)
        for _ in 0..<3 {
            await p.a.pass()
            await p.hub.pump()
        }
        XCTAssertEqual(250, p.hub.replays - before)  // quiet: not asked again until the next connect
        p.a.onConnected()
        for _ in 0..<3 {
            await p.a.pass()
            await p.hub.pump()
        }
        XCTAssertEqual(500, p.hub.replays - before)
    }

    func testADeliveryIsStoredWithItsChatRowOnceAndAnsweredEveryTime() async throws {
        let p = Pair()
        _ = try await p.send()
        await p.hub.pump()
        let d = try XCTUnwrap(p.hub.deliveries.first)
        XCTAssertEqual(1, p.hub.deliveries.count)
        await p.hub.replay(d)
        await p.hub.replay(d)
        XCTAssertEqual(1, p.rxB().count)
        XCTAssertEqual(2, p.hub.queue.filter { $0.kind == "ack" && $0.principal == "bridge:kit-b" }.count)  // the first was pumped already
        await p.hub.pump()
        XCTAssertEqual(["bridge:phone-a: Water at the north gate"], p.storedAtB.lines)
    }

    func testADeliveryToAnotherPrincipalOrThatDoesNotParseIsIgnored() async throws {
        let p = Pair()
        _ = try await p.send()
        await p.hub.pump()
        let d = try XCTUnwrap(HubDelivery.fromJson(try XCTUnwrap(p.hub.deliveries.first).payload))
        // A whole, well-formed delivery of its own operation, only addressed to someone else.
        let other = HubSubmission.create(
            opId: HubMsgIds.newV7(p.t), mid: HubMsgIds.newV7(p.t), to: "bridge:someone-else", body: "not for kit-b",
            midExpiresAt: d.midExpiresAt, expiresAt: d.expiresAt)
        await p.b.handleIn(
            HubDelivery(
                opId: other.opId, mid: other.mid, from: "bridge:phone-a", to: other.to, contentType: other.contentType,
                midExpiresAt: other.midExpiresAt, expiresAt: other.expiresAt, contentSha256: other.contentSha256, body: other.body
            ).toJson())
        var fromNobody = d
        fromNobody.from = "kit-a"
        await p.b.handleIn(fromNobody.toJson())
        await p.b.handleIn("not json")
        XCTAssertEqual(1, p.rxB().count)
        XCTAssertEqual(["bridge:phone-a: Water at the north gate"], p.storedAtB.lines)
        XCTAssertTrue(p.hub.queue.allSatisfy { $0.kind != "ack" }, "an answer to what was not ours")
    }

    func testACompletionEndsAnObligationHeldOnlyInMemoryWithNoMoreRepeats() async throws {
        let p = Pair()
        await p.a.pass()  // the start's walk is done
        p.storeA.failEvent = { $0.kind == "hub_forwarded" }
        let id = try await p.send()
        await p.hub.pump()  // hub_forwarded not kept, then the completion kept
        XCTAssertEqual(HubMsgStatus.delivered, p.statusA(id))
        // A late copy of hub_forwarded whose event and obligation both cannot be written: an
        // obligation in memory, behind a completion that is already kept.
        p.storeA.fail = { $0 == "missing" }
        let fwd = try XCTUnwrap(p.hub.statuses.first { kind($0) == "hub_forwarded" })
        await p.hub.replay(fwd)
        p.storeA.failEvent = { _ in false }
        p.storeA.fail = { _ in false }
        let before = p.hub.replays
        for _ in 0..<3 {
            p.t += 31 * 60_000
            await p.a.pass()
            await p.hub.pump()
        }
        XCTAssertEqual(before, p.hub.replays, "a repeat for an event a completion made moot")
        XCTAssertEqual(HubMsgStatus.delivered, p.statusA(id))
    }

    func testACompletionThatComesAfterTheBoundStillReadsDelivered() async throws {
        let p = Pair()
        await p.a.pass()
        p.linkB.up = false
        p.storeA.failEvent = { $0.kind == "recipient_app_stored" }
        let id = try await p.send()
        await p.hub.pump()
        await p.hub.emit("recipient_app_stored", "completed", "recipient")  // lost on the phone
        p.storeA.failEvent = { _ in false }
        p.linkA.up = false
        p.t = p.op().expiresAt + HubMsgRoute.replayWithinMs + 1
        await p.a.pass()
        XCTAssertEqual(HubMsgStatus.unknown, p.statusA(id))
        p.linkA.up = true
        let done = try XCTUnwrap(p.hub.statuses.first { kind($0) == "recipient_app_stored" })
        await p.hub.replay(done)
        XCTAssertEqual(HubMsgStatus.delivered, p.statusA(id), "the recipient's own word beats the phone giving up")
    }
}
