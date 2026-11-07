// Mirrors GatewayService.postMessageNotification and its callers (MESHSAT-1829): every incoming
// message (mesh, satellite, the node's 9704, the Hub, TAK, Reticulum) and every failed send that
// the gateway announces on `messageNotifications` is a notification, also while the app is open,
// as Android posts it whatever is on screen. A tap opens the Messages tab (Android opens the
// app). Each gets its own identifier, so several messages stack in the list.
import Foundation
import UserNotifications

extension GatewayController {
    /// The user's notification setting is iOS's own: a denied permission makes `add` fail quietly.
    func initMessageNotifications() {
        keep(
            Task { [self] in
                for await n in messageNotifications.subscribe() {
                    await postMessageNotification(title: n.title, text: n.text)
                }
            })
    }

    private func postMessageNotification(title: String, text: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = text
        content.sound = .default
        content.userInfo = ["route": "messages"]
        content.threadIdentifier = "messages:" + title
        let request = UNNotificationRequest(identifier: "message:" + UUID().uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Self.log.info("Message notification not shown: \(error)")
        }
    }
}
