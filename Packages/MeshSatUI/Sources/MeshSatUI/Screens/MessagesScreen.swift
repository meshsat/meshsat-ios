// Mirrors ui/screens/MessagesScreen.kt: the Messages tab. Transport chips, the stats row, the
// Chats / All Messages / New message toggle, search, the conversation cards and the message
// cards. A conversation opens as its own screen (route chat/{peer}), so Back returns here
// (MESHSAT-1249). Android's SMS permission banner has no iOS counterpart: there is no SMS
// permission, the Messages composer is always the way.
import MeshSatEngine
import MeshSatMeshtastic
import MeshSatWire
import SwiftUI

public struct MessagesScreen: View {
    @Environment(Router.self) private var router
    @Environment(GatewayModel.self) private var model
    @Environment(MessagesModel.self) private var messages
    @State private var viewMode = "conversations"
    @State private var selectedTab = "all"
    @State private var showNewMessage = false

    public init() {}

    private var filteredMessages: [MessageRecord] {
        selectedTab == "all" ? messages.allMessages : messages.allMessages.filter { $0.transport == selectedTab }
    }

    private var filteredConversations: [ConversationSummary] {
        selectedTab == "all" ? messages.conversations : messages.conversations.filter { $0.transport == selectedTab }
    }

    private static let tabs = [("all", "All"), ("mesh", "Mesh"), ("iridium", "Satellite"), ("sms", "SMS")]

    private func chipColors(_ key: String) -> (Color, Color) {
        switch key {
        case "mesh": (MSColors.mesh.opacity(0.2), MSColors.mesh)
        case "iridium": (MSColors.iridium.opacity(0.2), MSColors.iridium)
        case "sms": (MSColors.cellular.opacity(0.2), MSColors.cellular)
        default: (MSColors.surfaceLight, MSColors.offWhite)
        }
    }

    public var body: some View {
        @Bindable var messages = messages
        VStack(alignment: .leading, spacing: 0) {
            Text("Messages").msText(.headlineMedium).padding(.bottom, 4)
            HStack(spacing: 8) {
                ForEach(Self.tabs, id: \.0) { key, label in
                    let colors = chipColors(key)
                    MSFilterChip(label, selected: selectedTab == key, selectedContainer: colors.0, selectedLabel: colors.1) {
                        selectedTab = key
                    }
                }
            }
            .padding(.bottom, 4)
            HStack(spacing: 16) {
                Text("\(model.nodes.count) nodes").msText(.bodySmall, color: MSColors.textMuted)
                Text("\(messages.messagesToday) today").msText(.bodySmall, color: MSColors.textMuted)
                Text("\(messages.allMessages.count) stored").msText(.bodySmall, color: MSColors.textMuted)
            }
            .padding(.bottom, 8)
            HStack(spacing: 8) {
                MSFilterChip("Chats", selected: viewMode == "conversations") { viewMode = "conversations" }
                MSFilterChip("All Messages", selected: viewMode == "all") { viewMode = "all" }
                // A message the app itself sends (satellite or mesh), even from an empty inbox.
                MSFilterChip("New message", selected: false) { showNewMessage = true }
            }
            .padding(.bottom, 8)
            if viewMode == "all" {
                MSOutlinedTextField(
                    text: $messages.searchQuery, placeholder: "Search messages...",
                    leading: { MSIcon.search.resizable().scaledToFit().frame(width: 20, height: 20).foregroundStyle(MSColors.textMuted) },
                    trailing: {
                        if !messages.searchQuery.isEmpty {
                            MSIconButton(MSIcon.clear, label: "Clear", tint: MSColors.textMuted, size: 32, glyph: 18) {
                                messages.searchQuery = ""
                            }
                        }
                    }
                )
                .padding(.bottom, 8)
                if filteredMessages.isEmpty {
                    emptyLine("No messages yet")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(filteredMessages, id: \.id) { msg in
                                MessageCard(msg: msg, activeKey: messages.activeKey(for: msg.sender))
                            }
                        }
                    }
                }
            } else if filteredConversations.isEmpty {
                emptyLine("No conversations yet")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredConversations, id: \.sender) { conv in
                            ConversationCard(conv: conv, nodes: model.nodes) { router.navigate(.chat(peer: conv.sender)) }
                        }
                    }
                }
            }
        }
        .padding(MSSpace.screen)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MSColors.bg)
        .overlay {
            if showNewMessage {
                NewMessageDialog(
                    onPick: { peer in
                        showNewMessage = false
                        router.navigate(.chat(peer: peer))
                    },
                    onDismiss: { showNewMessage = false })
            }
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).msText(.bodyLarge, color: MSColors.textMuted)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.top, 16)
    }
}

struct ConversationCard: View {
    let conv: ConversationSummary
    let nodes: [MeshtasticProtocol.MeshNodeInfo]
    let onClick: () -> Void

    var body: some View {
        let transportColor = Words.transportColor(conv.transport)
        Button(action: onClick) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    HStack(spacing: 8) {
                        Text(Peers.displayName(conv.sender, nodes: nodes)).msText(.titleMedium).lineLimit(1)
                        Text(Words.transport(conv.transport)).msText(.bodySmall, color: transportColor)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(transportColor.opacity(0.15), in: RoundedRectangle(cornerRadius: MSRadius.tag, style: .continuous))
                        if conv.hasEncrypted {
                            MSIcon.lock.resizable().scaledToFit().frame(width: 16, height: 16).foregroundStyle(MSColors.amber)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Words.clock(conv.lastTimestamp, "MM/dd HH:mm")).msText(.bodySmall, color: MSColors.textMuted)
                        Text("\(conv.messageCount)").msText(.bodySmall, color: MSColors.textSecondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(MSColors.surfaceLight, in: RoundedRectangle(cornerRadius: MSRadius.tag, style: .continuous))
                    }
                }
                Text(conv.lastMessage).msText(.bodyMedium, color: MSColors.textMuted).lineLimit(1).padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MSSpace.card)
            .msCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// What a message shows: its text, or the ciphertext when the key is missing or wrong (MESHSAT-447).
enum MessageDisplay {
    static func text(_ msg: MessageRecord, activeKey: String?) -> (text: String, ciphertext: Bool) {
        if msg.encrypted, !msg.text.isEmpty, msg.text != msg.rawText { return (msg.text, false) }
        if msg.encrypted, !msg.rawText.isEmpty {
            if let activeKey, let plain = try? AesGcmCrypto.decryptFromBase64(msg.rawText, hexKey: activeKey) { return (plain, false) }
            return (msg.rawText, true)
        }
        return (msg.text, false)
    }

    /// The delivery badge of a forwarded message: an Iridium send shows where it is in the queue.
    static func deliveryLabel(_ forwardedTo: String) -> String {
        switch forwardedTo {
        case "iridium:queued": "Queued"
        case "iridium:unconfirmed": "May have been sent"
        case "iridium:sbd", "sms:sent": "Sent"
        case "iridium:delivered": "The Hub has it"
        case "sms:delivered": "Delivered"
        case "sms:sending": "Sending"
        case "iridium:failed", "sms:failed": "Failed"
        default: "Forwarded"
        }
    }
}

/// Simple message card for the "All Messages" view. Also decrypts on the fly.
struct MessageCard: View {
    let msg: MessageRecord
    let activeKey: String?
    @Environment(GatewayModel.self) private var model

    var body: some View {
        let display = MessageDisplay.text(msg, activeKey: activeKey)
        let transportColor = Words.transportColor(msg.transport)
        let rx = msg.direction == "rx"
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Tag(msg.transport.uppercased(), color: transportColor)
                    Tag(rx ? "RX" : "TX", color: rx ? MSColors.teal : MSColors.amber)
                    if msg.encrypted {
                        (display.ciphertext ? MSIcon.lockOpen : MSIcon.lock).resizable().scaledToFit().frame(width: 16, height: 16)
                            .foregroundStyle(display.ciphertext ? MSColors.red : MSColors.amber)
                    }
                    if msg.forwarded { Tag(MessageDisplay.deliveryLabel(msg.forwardedTo), color: MSColors.textMuted) }
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Text(Words.clock(msg.timestamp, "HH:mm:ss")).msText(.bodySmall, color: MSColors.textMuted)
                    MSIconButton(MSIcon.contentCopy, label: "Copy", tint: MSColors.textMuted, size: 24, glyph: 16) {
                        UIPasteboard.general.string = msg.encrypted && !msg.rawText.isEmpty ? msg.rawText : msg.text
                        model.showToast("Copied")
                    }
                }
            }
            Text(msg.sender).msText(.bodySmall, color: MSColors.textMuted).padding(.top, 4)
            Text(display.text).msText(.bodyLarge, color: display.ciphertext ? MSColors.textMuted : MSColors.textPrimary)
                .textSelection(.enabled).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MSSpace.card)
        .msCard()
    }
}

/// A small coloured label on a 15 percent tint, as the screens tag transports and states.
struct Tag: View {
    let text: String
    let color: Color
    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text).msText(.bodySmall, color: color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: MSRadius.tag, style: .continuous))
    }
}

/// Who a new message is for (MESHSAT-1249): the satellite, everyone on the mesh, a node the
/// phone has heard, or a phone number.
struct NewMessageDialog: View {
    let onPick: (String) -> Void
    let onDismiss: () -> Void
    @Environment(GatewayModel.self) private var model
    @State private var number = ""

    private var numberOk: Bool {
        let n = number.trimmingCharacters(in: .whitespaces)
        return n.count >= 6 && n.allSatisfy { $0.isNumber || $0 == "+" || $0 == " " }
    }

    var body: some View {
        let myNum = model.myInfo?.myNodeNum ?? 0
        let imei = model.modemImei
        MSAlertDialog("New message", onDismiss: onDismiss) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    NewMessageRow(
                        title: "Satellite", detail: "Through Rock7 to the Hub, from anywhere with a view of the sky",
                        color: MSColors.iridium
                    ) {
                        onPick(imei.isEmpty ? Peers.satellite : imei)
                    }
                    NewMessageRow(title: "Everyone on the mesh", detail: "Every node on your channel", color: MSColors.mesh) {
                        onPick(Peers.meshAll)
                    }
                    let heard = model.nodes.filter { $0.nodeNum != myNum }.sorted { $0.lastHeard > $1.lastHeard }.prefix(20)
                    ForEach(heard, id: \.nodeNum) { node in
                        let id = MeshtasticProtocol.formatNodeId(node.nodeNum)
                        NewMessageRow(
                            title: node.longName.isEmpty ? "Node \(id)" : node.longName, detail: "On the mesh, \(id)", color: MSColors.mesh
                        ) {
                            onPick(id)
                        }
                    }
                    MSOutlinedTextField(text: $number, label: "Or a phone number, e.g. +31612345678", keyboard: .phonePad).padding(.top, 8)
                }
            }
            .frame(maxHeight: 360)
        } buttons: {
            MSTextButton("Cancel", color: MSColors.textSecondary, action: onDismiss)
            MSTextButton("Text this number") { onPick(number.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")) }
                .disabled(!numberOk).opacity(numberOk ? 1 : 0.4)
        }
    }
}

struct NewMessageRow: View {
    let title: String
    let detail: String
    let color: Color
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 12) {
                Circle().fill(color).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).msText(.titleMedium)
                    Text(detail).msText(.bodySmall, color: MSColors.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 56)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
