// The SMS composer lane (MESHSAT-1328): iOS has no SMS API, so every sms_0 delivery the
// dispatcher parked as awaiting_user is offered to the person in the system Messages composer,
// one at a time, oldest first, with the recipient and the text filled in. What they do with it
// (Send or Cancel) goes back to the dispatcher. Android sends from the SIM directly (sms/SmsSender.kt).
import MeshSatEngine
import SwiftUI

#if canImport(MessageUI)
import MessageUI
#endif

public struct SmsComposerHost: View {
    @Environment(GatewayModel.self) private var model
    @State private var pending: [MessageDelivery] = []
    @State private var showing: MessageDelivery?

    public init() {}

    public var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                for await list in model.gateway.observeSmsAwaitingUser() { pending = list }
            }
            .onChange(of: pending.first?.id) { _, _ in
                if showing == nil, let next = pending.first, Self.canSend { showing = next }
            }
            .sheet(item: $showing) { del in
                #if canImport(MessageUI)
                // The payload is the wire body (compressed, encrypted, base64); the preview the typed text.
                MessageComposer(
                    recipient: del.recipient, body: del.payload.flatMap { String(data: $0, encoding: .utf8) } ?? del.textPreview
                ) { sent in
                    showing = nil
                    if let id = del.id { model.gateway.smsComposerFinished(deliveryId: id, sent: sent) }
                    pending.removeAll { $0.id == del.id }
                    if let next = pending.first { showing = next }
                }
                .ignoresSafeArea()
                #else
                EmptyView()
                #endif
            }
    }

    static var canSend: Bool {
        #if canImport(MessageUI)
        return MFMessageComposeViewController.canSendText()
        #else
        return false
        #endif
    }
}

extension MessageDelivery: @retroactive Identifiable {}

#if canImport(MessageUI)
struct MessageComposer: UIViewControllerRepresentable {
    let recipient: String
    let body: String
    let onFinish: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = [recipient]
        vc.body = body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: (Bool) -> Void
        init(onFinish: @escaping (Bool) -> Void) { self.onFinish = onFinish }
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            onFinish(result == .sent)
        }
    }
}
#endif
