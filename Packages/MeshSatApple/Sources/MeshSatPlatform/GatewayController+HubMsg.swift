// Mirrors service/GatewayService.kt initHubMsg and sendHub: the Hub app route (hub_msg,
// MESHSAT-1584), texts to and from a contact's MeshSat app through the Hub, on this phone's own
// msg topics. Its pass runs at each connect and every 30 s.
import Foundation
import MeshSatEngine
import MeshSatHub
import MeshSatStore

/// What the route needs from the Hub session.
struct HubMsgPublisher: HubMsgRoute.Publisher {
    let reporter: HubReporter
    var principal: String { reporter.principal }
    /// Ready, not just connected: the session's msg subscriptions hold (PH-R2), as on Android.
    func isConnected() async -> Bool { reporter.isMsgReady }
    func publishMsg(kind: String, payload: String) async -> HubMsgRoute.Published {
        await reporter.publishMsg(kind: kind, payload: payload)
    }
}

extension GatewayController {
    func initHubMsg(_ reporter: HubReporter) {
        let notifications = messageNotifications
        let route = HubMsgRoute(
            store: db.hubMsg, pub: HubMsgPublisher(reporter: reporter),
            onStored: { from, text, _ in notifications.send((title: "Hub: \(HubMsgWire.bridgeOf(from))", text: text)) })
        reporter.setMsgCallbacks(
            onIn: { payload in Task { await route.handleIn(payload) } },
            onStatus: { payload in Task { await route.handleStatus(payload) } },
            onConnected: {
                route.onConnected()
                Task { await route.pass() }
            })
        keep(
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(HubMsgRoute.passMs) * 1_000_000)
                    if Task.isCancelled { break }
                    await route.pass()
                }
            })
        setHubMsgRoute(route)
        Self.log.info("hub_msg: route on as \(reporter.principal)")
    }

    /// A text through the Hub to recipient ("bridge:<id>"); a refused one is still shown in the chat, marked not sent.
    public func sendHub(to recipient: String, text: String) async {
        var why: String?
        if let route = hubMsgRoute {
            do {
                if case .refused(let w) = try await route.send(to: recipient, text: text) { why = w }
            } catch {
                why = "not stored: \(error)"
            }
        } else {
            why = "Messages through the Hub are off"
        }
        guard let why else { return }
        Self.log.warning("hub_msg send refused: \(why)")
        _ = try? await db.messages.insert(
            MessageRecord(
                timestamp: MeshSatStore.nowMs(), transport: "hub", direction: "tx", sender: hubReporter?.principal ?? "",
                recipient: recipient,
                text: text, forwarded: true, forwardedTo: HubMsgStatus.refusedPrefix + "not_sent"))
    }
}
