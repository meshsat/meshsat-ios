// Mirrors test hubmsg/ContractHub.kt: a Hub that does what the Hub does with a frame
// (docs/bridge-hub-protocol.md "Messaging v1"; the Hub's own tests run its real code), for the
// phone's route tests: a submission is admitted, delivered on the recipient's msg/in with
// hub_forwarded to the sender, and a repeat of one is answered with every event of it again; an
// answer becomes the sender's evidence by C5/C6a. A link that is not connected receives nothing
// (the phone's session is clean). Frames wait in a queue the test pumps. [MESHSAT-1584]
import Foundation

@testable import MeshSatHub

final class ContractHub: @unchecked Sendable {
    struct Frame: Equatable {
        let principal: String
        let kind: String
        let payload: String
    }

    var queue: [Frame] = []
    var routes: [String: HubMsgRoute] = [:]
    var links: [String: Link] = [:]
    var ops: [String: HubSubmission] = [:]
    var senders: [String: String] = [:]
    var statuses: [Frame] = []
    var deliveries: [Frame] = []
    var replays = 0
    var refuse: ((HubSubmission) -> String?)?

    /// One principal's session at this Hub.
    final class Link: HubMsgRoute.Publisher, @unchecked Sendable {
        let principal: String
        var up = true
        var answer: HubMsgRoute.Published = .ok
        weak var hub: ContractHub?

        init(_ principal: String, hub: ContractHub) {
            self.principal = principal
            self.hub = hub
        }

        func isConnected() async -> Bool { up }

        func publishMsg(kind: String, payload: String) async -> HubMsgRoute.Published {
            if !up { return .notSent }
            if answer != .notSent { hub?.queue.append(Frame(principal: principal, kind: kind, payload: payload)) }
            return answer
        }
    }

    func link(_ principal: String) -> Link {
        let l = Link(principal, hub: self)
        links[principal] = l
        return l
    }

    private func event(_ s: HubSubmission, _ kind: String, _ cls: String, _ authority: String, _ reason: String = "") -> String {
        HubEvent(
            opId: s.opId, mid: s.mid, recipient: s.to, eventId: HubMsgIds.newV7(Int64(Date().timeIntervalSince1970 * 1000)), rev: 1,
            cls: cls, kind: kind, reason: reason, authority: authority, at: "2026-10-19T00:00:00Z"
        ).toJson()
    }

    /// Publishes on to's msg/kind; a link that is down never gets it.
    func publish(_ to: String, _ kind: String, _ payload: String) async {
        let f = Frame(principal: to, kind: kind, payload: payload)
        if kind == "in" { deliveries.append(f) } else { statuses.append(f) }
        guard links[to]?.up == true, let r = routes[to] else { return }
        if kind == "in" { await r.handleIn(payload) } else { await r.handleStatus(payload) }
    }

    /// Publishes f again (a QoS 1 redelivery).
    func replay(_ f: Frame) async {
        guard links[f.principal]?.up == true, let r = routes[f.principal] else { return }
        if f.kind == "in" { await r.handleIn(f.payload) } else { await r.handleStatus(f.payload) }
    }

    /// Carries every queued frame until none is left.
    func pump() async {
        while await pumpOne() {}
    }

    /// Carries the first queued frame; false when there was none.
    @discardableResult
    func pumpOne() async -> Bool {
        guard !queue.isEmpty else { return false }
        let f = queue.removeFirst()
        switch f.kind {
        case "out":
            guard let s = HubSubmission.fromJson(f.payload) else { return true }
            if let prev = ops[s.opId], senders[s.opId] == f.principal {
                if prev != s {
                    await publish(f.principal, "status", HubRefusal(opId: s.opId, mid: s.mid, reason: "op_conflict").toJson())
                    return true
                }
                replays += 1
                for st in statuses where st.principal == f.principal && (HubMsgWire.parse(st.payload)?.string("op_id") == s.opId) {
                    await replay(st)
                }
                return true
            }
            if let reason = refuse?(s) {
                await publish(f.principal, "status", HubRefusal(opId: s.opId, mid: s.mid, reason: reason).toJson())
                return true
            }
            ops[s.opId] = s
            senders[s.opId] = f.principal
            await publish(
                s.to, "in",
                HubDelivery(
                    opId: s.opId, mid: s.mid, from: f.principal, to: s.to, contentType: s.contentType, midExpiresAt: s.midExpiresAt,
                    expiresAt: s.expiresAt, contentSha256: s.contentSha256, body: s.body
                ).toJson())
            await publish(f.principal, "status", event(s, "hub_forwarded", "forwarded", "hub"))
        case "ack":
            guard let a = HubAck.fromJson(f.payload), let s = ops[a.opId], let sender = senders[a.opId] else { return true }
            guard s.to == f.principal, sender == a.from, s.mid == a.mid else { return true }
            if a.result == "stored" {
                await publish(sender, "status", event(s, "recipient_app_stored", "completed", "recipient"))
            } else if a.reason == "receiver_busy" {
                await publish(sender, "status", event(s, "recipient_busy", "unknown", "recipient", a.reason))
            } else if a.reason == "expired_at_recipient" {
                await publish(sender, "status", event(s, "recipient_refused", "expired", "recipient", a.reason))
            } else {
                await publish(sender, "status", event(s, "recipient_refused", "failed", "recipient", a.reason))
            }
        default:
            break
        }
        return true
    }

    /// Publishes kind for the only operation, as the Hub would on its own (an expiry, a late answer).
    func emit(_ kind: String, _ cls: String, _ authority: String, _ reason: String = "") async {
        guard ops.count == 1, let (opId, s) = ops.first, let sender = senders[opId] else { return }
        await publish(sender, "status", event(s, kind, cls, authority, reason))
    }
}
