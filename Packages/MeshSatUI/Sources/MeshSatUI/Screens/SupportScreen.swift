// Mirrors ui/screens/SupportScreen.kt (MESHSAT-1806, iOS MESHSAT-1810): Setup > Help > Support, feedback
// to the MeshSat Support desk through the user's own mail, with an optional debug.zip of the app's log,
// the links, the queue's counts, crash reports and the node's log (numbers, emails, IMEIs and keys
// blanked). The mail opens filled in, so the person sees everything before it is sent.
//
// iOS lets no app list the phone's mail apps or hand a file to one of them by name, as Android 2.26.3
// does: Send feedback opens Mail's composer with the zip attached when Mail has an account, and the
// share sheet with the zip otherwise (any mail app there takes it); the address can be copied either way.
import MeshSatEngine
import MeshSatPlatform
import SwiftUI
import UIKit

#if canImport(MessageUI)
import MessageUI
#endif

public struct SupportScreen: View {
    @Environment(GatewayModel.self) private var model
    @State private var topic: SupportBundle.Topic = .problem
    @State private var message = ""
    @State private var attach = true
    @State private var busy = false
    @State private var mail: SupportMail?
    @State private var sharing: SupportShare?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Tell us what happened, what you expected and what you were doing at the time. "
                        + "Your email app opens with the message addressed to \(SupportBundle.supportAddress), "
                        + "so you see everything before it is sent."
                )
                .msText(.bodyMedium, color: MSColors.textSecondary)
                HStack(spacing: 8) {
                    ForEach(SupportBundle.Topic.allCases, id: \.self) { t in
                        MSFilterChip(t.label, selected: topic == t) { topic = t }
                    }
                }
                MSOutlinedTextField(text: $message, label: "Your message", lineLimit: 8)
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Attach debug.zip").msText(.bodyLarge)
                        Text(
                            "The app's log, the state of each link, the queue's counts, crash reports and the "
                                + "node's log. Phone numbers, email addresses, IMEIs and keys are blanked out; node names, "
                                + "positions and the times of messages stay in."
                        )
                        .msText(.bodySmall, color: MSColors.textMuted)
                    }
                    Spacer(minLength: 0)
                    MSSwitch(isOn: $attach, label: "Attach debug.zip")
                }
                MSFilledButton(busy ? "Collecting the logs" : "Send feedback") { send() }
                    .disabled(busy)
                MSOutlinedButton("Share debug.zip another way", enabled: !busy) { shareZip() }
                Text("No email app on this phone? Write to \(SupportBundle.supportAddress) from any device.")
                    .msText(.bodySmall, color: MSColors.textMuted)
                    .padding(.top, 4)
                MSTextButton("Copy the address") {
                    UIPasteboard.general.string = SupportBundle.supportAddress
                    model.showToast("Address copied.")
                }
                Text("A security problem? Report it privately to security@meshsat.net, not in feedback.")
                    .msText(.bodySmall, color: MSColors.textMuted)
            }
            .padding(MSSpace.screen)
        }
        .background(MSColors.bg)
        .sheet(item: $mail) { m in
            #if canImport(MessageUI)
            MailComposer(mail: m) { mail = nil }.ignoresSafeArea()
            #else
            EmptyView()
            #endif
        }
        .sheet(item: $sharing) { s in
            ActivityView(items: s.items).ignoresSafeArea()
        }
    }

    private var subject: String { SupportBundle.subject(topic, version: SupportInstall.version) }

    private func mailText(attached: Bool) -> String {
        SupportBundle.mailBody(message, about: SupportInstall.about, attached: attached)
    }

    private func send() {
        busy = true
        Task {
            var zip: URL?
            if attach {
                zip = try? await model.gateway.writeSupportZip()
                // A zip that could not be made is said, and the mail still goes without it.
                if zip == nil { model.showToast("The debug.zip could not be made; sending without it.") }
            }
            busy = false
            if MailComposer.canSend {
                mail = SupportMail(subject: subject, body: mailText(attached: zip != nil), zip: zip)
            } else if let zip {
                // No Mail account: the share sheet takes the zip to any mail app, with the words in the text.
                sharing = SupportShare(items: [mailText(attached: true), zip])
            } else if let url = URL(
                string: SupportBundle.mailtoUri(address: SupportBundle.supportAddress, subject: subject, body: mailText(attached: false)))
            {
                await UIApplication.shared.open(url)
            }
        }
    }

    private func shareZip() {
        busy = true
        Task {
            let zip = try? await model.gateway.writeSupportZip()
            busy = false
            if let zip { sharing = SupportShare(items: [zip]) } else { model.showToast("The debug.zip could not be made.") }
        }
    }
}

struct SupportMail: Identifiable {
    let id = UUID()
    let subject: String
    let body: String
    let zip: URL?
}

struct SupportShare: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// UIActivityViewController, for a file made on the tap (ShareLink needs it before).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#if canImport(MessageUI)
/// Mail's composer, addressed to the desk, the zip attached as application/zip.
struct MailComposer: UIViewControllerRepresentable {
    let mail: SupportMail
    let onFinish: () -> Void

    static var canSend: Bool { MFMailComposeViewController.canSendMail() }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.setToRecipients([SupportBundle.supportAddress])
        vc.setSubject(mail.subject)
        vc.setMessageBody(mail.body, isHTML: false)
        if let zip = mail.zip, let data = try? Data(contentsOf: zip) {
            vc.addAttachmentData(data, mimeType: "application/zip", fileName: zip.lastPathComponent)
        }
        vc.mailComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            onFinish()
        }
    }
}
#else
enum MailComposer {
    static var canSend: Bool { false }
}
#endif
