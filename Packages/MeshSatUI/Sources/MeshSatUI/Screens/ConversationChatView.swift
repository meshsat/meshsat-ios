// Mirrors ConversationChatView, ChatBubble, DeliveryMark, KeyManagementSection, composeHint and
// sendMessage of ui/screens/MessagesScreen.kt: the chat with one peer, newest at the bottom,
// the compose bar whose route follows who the chat is with (a mesh node over the mesh, a phone
// number by SMS, the satellite conversation by satellite), and the per-conversation key.
import MeshSatEngine
import MeshSatWire
import SwiftUI

public struct ConversationChatView: View {
    let peer: String
    @Environment(Router.self) private var router
    @Environment(GatewayModel.self) private var model
    @Environment(MessagesModel.self) private var messagesModel
    @State private var messages: [MessageRecord] = []
    @State private var composeText = ""
    @State private var sendTransport = ""
    @State private var showKeySection = false
    @State private var showKey = false
    @State private var keyInput = ""

    public init(peer: String) { self.peer = peer }

    private var activeKey: String? { messagesModel.activeKey(for: peer) }
    private var convKey: ConversationKey? { messagesModel.conversationKey(for: peer) }
    private var meshConnected: Bool { model.meshState == .connected }
    private var iridiumConnected: Bool { model.modemState == .connected }
    private var transport: String { sendTransport.isEmpty ? Peers.defaultTransport(peer) : sendTransport }

    /// A satellite message that cannot fit one frame is stopped here, not after it has been
    /// queued and billed for (MESHSAT-1280).
    private var fitsTheLink: Bool {
        transport != "iridium" || SatelliteLimits.fits(composeText.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count)
    }

    private var canSend: Bool { !composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && fitsTheLink }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                MSIconButton(MSIcon.arrowBack, label: "Back", tint: MSColors.teal) { router.back() }
                VStack(alignment: .leading, spacing: 0) {
                    Text(Peers.displayName(peer, nodes: model.nodes)).msText(.titleLarge).lineLimit(1)
                    Text(Peers.detail(peer) ?? Words.transport(transport)).msText(.bodySmall, color: Words.transportColor(transport))
                }
                Spacer(minLength: 8)
                MSIconButton(
                    activeKey != nil ? MSIcon.lock : MSIcon.lockOpen, label: "Encryption key",
                    tint: activeKey != nil ? MSColors.amber : MSColors.textMuted
                ) {
                    showKeySection.toggle()
                }
            }
            .padding(.bottom, 8)
            if showKeySection {
                KeyManagementSection(
                    convKey: convKey, keyInput: $keyInput, showKey: $showKey,
                    onSave: { key in messagesModel.saveConversationKey(peer: peer, hexKey: key) },
                    onRemove: {
                        messagesModel.removeConversationKey(peer: peer)
                        keyInput = ""
                    })
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        // Newest at the bottom, as a chat: the store gives newest first.
                        ForEach(messages.reversed(), id: \.id) { msg in
                            ChatBubble(msg: msg, activeKey: activeKey).id(msg.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: messages.first?.id) { _, newest in
                    if let newest { proxy.scrollTo(newest, anchor: .bottom) }
                }
            }
            composeBar
        }
        .padding(MSSpace.screen)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MSColors.bg)
        .task(id: peer) {
            keyInput = convKey?.hexKey ?? ""
            for await list in messagesModel.observeConversation(peer) {
                messages = list
                // A reply goes back the way the conversation came in, when that way can reach this peer.
                let primary = list.first { $0.direction == "rx" }?.transport ?? Peers.defaultTransport(peer)
                if sendTransport.isEmpty, Peers.transportsFor(peer).contains(primary) { sendTransport = primary }
            }
        }
        .onChange(of: convKey?.hexKey) { _, new in keyInput = new ?? "" }
    }

    private var composeBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                MSOutlinedTextField(
                    text: $composeText, placeholder: placeholder, focusedBorder: MSColors.textSecondary, lineLimit: 4, submitLabel: .send,
                    onSubmit: send)
                MSIconButton(MSIcon.send, label: "Send", tint: canSend ? MSColors.teal : MSColors.textMuted, enabled: canSend, action: send)
            }
            Text(composeHint).msText(.bodySmall, color: MSColors.textSecondary).padding(.leading, 4)
        }
        .padding(8)
        .msCard()
    }

    private var placeholder: String {
        switch transport {
        case "iridium": "Message by satellite"
        case "mesh": peer == Peers.meshAll ? "Message everyone on the mesh" : "Message on the mesh"
        default: "Text message"
        }
    }

    /// The line under the message box: how this message goes, and for a satellite message its
    /// size and cost before it is sent (Rock7 bills up to 50 bytes per credit).
    private var composeHint: String {
        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = text.utf8.count
        switch transport {
        case "iridium":
            if !SatelliteLimits.fits(bytes) { return SatelliteLimits.tooLong(bytes) }
            let size = bytes == 0 ? "" : " \(bytes) bytes, \(Words.count((bytes + 49) / 50, "credit"))."
            return (iridiumConnected ? "By satellite." : "By satellite, when the modem is back.") + size
        case "mesh":
            if !meshConnected { return "On the mesh, when your node is connected." }
            return peer == Peers.meshAll ? "To everyone on the mesh channel." : "Directly to this node on the mesh."
        default:
            return bytes == 0 ? "By SMS from this phone." : "By SMS from this phone, \(text.count) characters."
        }
    }

    private func send() {
        guard canSend else { return }
        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch transport {
        case "sms":
            // The message appears in the chat with its state, and the Messages composer opens.
            model.queueSms(text, to: peer)
        case "mesh":
            guard meshConnected else {
                model.showToast("Not sent: your MeshSat node is not connected. Connect it in Setup.")
                return
            }
            // To this node directly, or to everyone on the channel (MESHSAT-1249).
            model.sendMesh(text, to: Peers.isMeshNode(peer) ? peer : Peers.meshAll)
        default:
            // Queued even without the modem: it goes out once a session succeeds (MESHSAT-1243).
            model.queueIridium(text, recipient: peer)
        }
        composeText = ""
    }
}

/// The delivery mark on a message the phone sent, as chat apps show it: a clock while an Iridium
/// message waits for the modem, one check once it has left the phone, a red mark when it failed,
/// and two checks only on a confirmation from the far end (MESHSAT-1246).
struct DeliveryMark: View {
    let forwardedTo: String

    var body: some View {
        let (icon, tint): (Image, Color) =
            switch forwardedTo {
            case "iridium:queued", "sms:sending": (MSIcon.schedule, MSColors.textMuted)
            case "iridium:unconfirmed": (MSIcon.helpOutline, MSColors.amber)
            case "iridium:failed", "sms:failed": (MSIcon.errorOutline, MSColors.red)
            case "iridium:delivered", "sms:delivered": (MSIcon.doneAll, MSColors.teal)
            default: (MSIcon.done, MSColors.teal)
            }
        icon.resizable().scaledToFit().frame(width: 14, height: 14).foregroundStyle(tint)
            .accessibilityLabel(MessageDisplay.deliveryLabel(forwardedTo))
    }
}

/// Chat bubble: decrypts on the fly with the active key; the ciphertext shows when the key is gone.
struct ChatBubble: View {
    let msg: MessageRecord
    let activeKey: String?
    @Environment(GatewayModel.self) private var model

    var body: some View {
        let isSelf = msg.direction == "tx"
        let display = MessageDisplay.text(msg, activeKey: activeKey)
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 12, bottomLeadingRadius: isSelf ? 12 : 4, bottomTrailingRadius: isSelf ? 4 : 12, topTrailingRadius: 12,
            style: .continuous)
        HStack {
            if isSelf { Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack(spacing: 4) {
                        Text(msg.transport.uppercased()).msText(.labelSmall, color: Words.transportColor(msg.transport))
                        if msg.encrypted {
                            (display.ciphertext ? MSIcon.lockOpen : MSIcon.lock).resizable().scaledToFit().frame(width: 12, height: 12)
                                .foregroundStyle(display.ciphertext ? MSColors.red : MSColors.amber)
                        }
                        if msg.forwarded, !isSelf { Text("Forwarded").msText(.labelSmall, color: MSColors.textMuted) }
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        Text(Words.clock(msg.timestamp, "HH:mm")).msText(.labelSmall, color: MSColors.textMuted)
                        if isSelf { DeliveryMark(forwardedTo: msg.forwardedTo) }
                        MSIconButton(MSIcon.contentCopy, label: "Copy", tint: MSColors.textMuted, size: 20, glyph: 12) {
                            UIPasteboard.general.string = msg.encrypted && !msg.rawText.isEmpty ? msg.rawText : msg.text
                            model.showToast("Copied")
                        }
                    }
                }
                Text(display.text).msText(.bodyMedium, color: display.ciphertext ? MSColors.textMuted : MSColors.textPrimary)
                    .textSelection(.enabled).padding(.top, 4)
            }
            .padding(10)
            .background(isSelf ? MSColors.teal.opacity(0.15) : MSColors.surface, in: shape)
            .overlay(shape.stroke(isSelf ? MSColors.teal.opacity(0.3) : MSColors.border, lineWidth: 0.5))
            .frame(maxWidth: UIScreen.main.bounds.width * 0.8, alignment: .leading)
            if !isSelf { Spacer(minLength: 0) }
        }
    }
}

struct KeyManagementSection: View {
    let convKey: ConversationKey?
    @Binding var keyInput: String
    @Binding var showKey: Bool
    let onSave: (String) -> Void
    let onRemove: () -> Void
    @Environment(GatewayModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Conversation Encryption Key").msText(.titleSmall)
            Text("AES-256-GCM key for this conversation. Messages are encrypted/decrypted with this key.").msText(
                .bodySmall, color: MSColors.textMuted)
            MSOutlinedTextField(text: $keyInput, label: "Hex key (64 chars)", secure: !showKey, keyboard: .asciiCapable)
            HStack(spacing: 8) {
                MSFilledButton(showKey ? "Hide" : "Show", container: MSColors.surface) { showKey.toggle() }
                MSFilledButton("Generate", container: MSColors.amber) { keyInput = AesGcmCrypto.generateKey() }
                MSFilledButton("Save", container: MSColors.teal) {
                    if AesGcmCrypto.isValidHexKey(keyInput) {
                        onSave(keyInput)
                        model.showToast("Key saved")
                    } else {
                        model.showToast("Invalid key: 64 hex chars required")
                    }
                }
            }
            HStack(spacing: 8) {
                MSFilledButton("Copy", container: MSColors.surface) {
                    if !keyInput.isEmpty {
                        UIPasteboard.general.string = keyInput
                        model.showToast("Key copied")
                    }
                }
                MSFilledButton("Paste", container: MSColors.surface) {
                    let clip = UIPasteboard.general.string ?? ""
                    if AesGcmCrypto.isValidHexKey(clip) {
                        keyInput = clip
                        model.showToast("Key pasted")
                    } else {
                        model.showToast("Clipboard doesn't contain a valid 64-char hex key")
                    }
                }
                if convKey != nil {
                    MSFilledButton("Remove", container: MSColors.surface) {
                        onRemove()
                        model.showToast("Key removed: messages will show encrypted")
                    }
                }
            }
        }
        .padding(MSSpace.card)
        .msCard()
        .padding(.bottom, 8)
    }
}
