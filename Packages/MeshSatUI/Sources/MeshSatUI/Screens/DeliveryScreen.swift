// Mirrors ui/screens/DeliveryScreen.kt (MESHSAT-1249): the message queue, every message on its
// way out, by link, with what happened to it in plain words. Routing rules > Deliveries and >
// Queue are built from the same parts below, so a state, an urgency or a time reads the same
// on both screens.
import MeshSatEngine
import MeshSatStore
import SwiftUI

public struct DeliveryScreen: View {
    @Environment(GatewayModel.self) private var model
    @State private var deliveries: [MessageDelivery] = []
    @State private var selectedId: Int64?
    @State private var request: QueueRequest?

    public init() {}

    public var body: some View {
        DeliveryLedger(deliveries: deliveries) { selectedId = $0.id }
            .padding(MSSpace.screen)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(MSColors.bg)
            .task {
                do {
                    for try await list in model.gateway.db.deliveries.getRecent(limit: 200) { deliveries = list }
                } catch {}
            }
            .overlay { DeliveryDialogs(deliveries: deliveries, selectedId: $selectedId, request: $request) }
    }
}

// MARK: - Shared words for a delivery

enum DeliveryWords {
    /// Statuses of a message that has not gone out yet.
    static let waitingStatuses: Set<String> = ["queued", "retry", "held", "sending"]
    /// Statuses of a message that stopped without going out.
    static let gaveUpStatuses: Set<String> = ["failed", "dead", "expired", "denied", "cancelled"]

    /// A waiting message that can still be cancelled (one being sent cannot).
    static func canCancel(_ d: MessageDelivery) -> Bool { ["queued", "retry", "held"].contains(d.status) }
    /// A message that gave up and can be put back in the queue (what `retryNow` accepts).
    static func canRetry(_ d: MessageDelivery) -> Bool { ["failed", "dead"].contains(d.status) }
    static func isSatelliteChannel(_ channel: String) -> Bool { channel.hasPrefix("iridium") }
    static func isCancelledByUser(_ d: MessageDelivery) -> Bool { d.status == "dead" && d.lastError == "cancelled" }

    /// A delivery's state; a message the user cancelled says so instead of "Gave up".
    static func stateText(_ d: MessageDelivery) -> String { Words.deliveryState(isCancelledByUser(d) ? "cancelled" : d.status) }
    static func stateColor(_ d: MessageDelivery) -> Color { Words.deliveryColor(isCancelledByUser(d) ? "cancelled" : d.status) }

    /// How urgent a message is, from its priority number (lower goes first).
    static func urgency(_ priority: Int) -> String {
        switch priority {
        case 0: "Critical"
        case 1: "Normal"
        default: "Low"
        }
    }

    /// What the phone does when a send fails (QoS 0 has no retries; 1 and above retry).
    static func guarantee(_ qos: Int) -> String {
        if qos <= 0 { return "Try once" }
        if qos == 1 { return "Keep trying" }
        return "Keep trying (high)"
    }

    /// The last error of a delivery, in plain words where the app wrote it itself.
    static func problem(_ error: String) -> String {
        let e = error.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.isEmpty { return "" }
        if e == "cancelled" { return "You cancelled it." }
        if e.hasPrefix("cancelled: exceeded retry limit") { return "Stopped after too many tries." }
        if e.hasPrefix("TTL expired") { return "It waited too long and expired." }
        // Two very different waits (MESHSAT-615): the radio being out of reach is something a
        // person can act on, a satellite that is not overhead is not.
        if e.hasPrefix("Could not hand the message to the modem") {
            return "The phone cannot reach the node's radio. It is waiting for the radio, not for a satellite."
        }
        if e.contains("no network service") { return "The satellite modem found no network. It is waiting for a satellite to come over." }
        if e == "egress rules denied" { return "A rule on this link blocked it." }
        if e == "recovered after restart" { return "The app restarted while sending it, so it is tried again." }
        return e.prefix(1).uppercased() + e.dropFirst()
    }

    /// Whether the other end confirmed the message.
    static func ack(_ ack: String) -> String {
        switch ack.lowercased() {
        case "pending": "Waiting for confirmation"
        case "acked": "Confirmed received"
        case "nacked": "Refused by the other end"
        case "timeout": "No confirmation came back"
        default: ack.prefix(1).uppercased() + ack.dropFirst()
        }
    }

    /// "Retried 2 of 3 times", or nil before the first retry.
    static func tries(_ d: MessageDelivery) -> String? {
        if d.retries <= 0 { return nil }
        if d.maxRetries > 0 { return "Retried \(d.retries) of \(d.maxRetries) times" }
        return "Retried \(Words.count(d.retries, "time"))"
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

// MARK: - Retry and cancel, always confirmed

/// Retry (true) or cancel (false) one delivery, waiting for the user to confirm.
struct QueueRequest: Equatable {
    let delivery: MessageDelivery
    let retry: Bool
}

struct ConfirmQueueRequestDialog: View {
    let request: QueueRequest
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        let channel = request.delivery.channel
        let link = Words.channel(channel)
        let confirm = request.retry ? "Retry" : "Cancel message"
        let (title, text): (String, String) =
            if !request.retry {
                ("Cancel this message?", "It will not be sent by \(link). You can retry it later from the queue.")
            } else if DeliveryWords.isSatelliteChannel(channel) {
                (
                    "Retry by satellite?",
                    "Each satellite attempt that gets through uses at least 1 credit. "
                        + "The message goes back in the queue and is sent at the next chance."
                )
            } else if channel.hasPrefix("sms") {
                (
                    "Send again by SMS?",
                    "Your carrier may charge for the text. The message goes back in the queue and is sent when SMS is working."
                )
            } else {
                ("Send again by \(link)?", "The message goes back in the queue and is sent when \(link) is working.")
            }
        MSAlertDialog(
            title, onDismiss: onDismiss,
            content: { Text(text).msText(.bodyMedium, color: MSColors.textSecondary) },
            buttons: {
                MSTextButton(request.retry ? "Not now" : "Keep it", color: MSColors.textSecondary, action: onDismiss)
                MSTextButton(confirm, color: request.retry ? MSColors.teal : MSColors.red, action: onConfirm)
            })
    }
}

/// Carry out a confirmed request. Returns what to tell the user.
func applyQueueRequest(_ dao: MessageDeliveryDao, _ request: QueueRequest) async -> String {
    let link = Words.channel(request.delivery.channel)
    guard let id = request.delivery.id else { return "Nothing to do." }
    do {
        if request.retry {
            try await dao.retryNow(id: id)
            return "Back in the queue for \(link)"
        }
        let changed = try await dao.cancelWaiting(id: id)
        return changed > 0 ? "Cancelled. It will not be sent by \(link)." : "Nothing to cancel: it has already been sent or stopped."
    } catch {
        return "That did not work: \(error)"
    }
}

/// The details dialog of the selected delivery and the confirmation of a retry or cancel. The
/// selected delivery is looked up in `deliveries` by id, so the dialog follows its state live.
struct DeliveryDialogs: View {
    let deliveries: [MessageDelivery]
    @Binding var selectedId: Int64?
    @Binding var request: QueueRequest?
    @Environment(GatewayModel.self) private var model

    var body: some View {
        ZStack {
            if let id = selectedId, let d = deliveries.first(where: { $0.id == id }) {
                DeliveryDetailsDialog(
                    delivery: d, onDismiss: { selectedId = nil },
                    onRetry: {
                        selectedId = nil
                        request = QueueRequest(delivery: d, retry: true)
                    },
                    onCancel: {
                        selectedId = nil
                        request = QueueRequest(delivery: d, retry: false)
                    })
            }
            if let r = request {
                ConfirmQueueRequestDialog(
                    request: r,
                    onConfirm: {
                        request = nil
                        let dao = model.gateway.db.deliveries
                        Task { model.showToast(await applyQueueRequest(dao, r)) }
                    },
                    onDismiss: { request = nil })
            }
        }
    }
}

// MARK: - The list: counts by state, a filter per link, and one card per message

/// The state groups at the top of the list; tapping one filters by it.
enum LedgerGroup: String, CaseIterable {
    case waiting = "queued"
    case sending = "sending"
    case sent = "sent"
    case failed = "failed"
    case gaveUp = "dead"

    var statuses: Set<String> {
        switch self {
        case .waiting: ["queued", "retry", "held"]
        case .sending: ["sending"]
        case .sent: ["sent", "delivered"]
        case .failed: ["failed"]
        case .gaveUp: ["dead", "expired", "denied", "cancelled"]
        }
    }
}

struct DeliveryLedger: View {
    let deliveries: [MessageDelivery]
    let onSelect: (MessageDelivery) -> Void
    @State private var filterGroup: LedgerGroup?
    @State private var filterChannel: String?
    @State private var now = DeliveryWords.nowMs()

    var body: some View {
        let filtered = deliveries.filter { d in
            (filterGroup.map { $0.statuses.contains(d.status) } ?? true) && (filterChannel.map { d.channel == $0 } ?? true)
        }
        let channels = Array(Set(deliveries.map(\.channel))).sorted()
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(LedgerGroup.allCases, id: \.self) { g in groupCell(g) }
            }
            .padding(4)
            .msCard()
            if !channels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        MSFilterChip("All links", selected: filterChannel == nil) { filterChannel = nil }
                        ForEach(channels, id: \.self) { ch in
                            MSFilterChip("\u{25CF} " + Words.channel(ch), selected: filterChannel == ch) {
                                filterChannel = filterChannel == ch ? nil : ch
                            }
                        }
                    }
                }
            }
            if filtered.isEmpty {
                Text(
                    deliveries.isEmpty
                        ? "No messages here yet. Messages you send, and messages your rules pass on, show up here."
                        : "No messages match this filter."
                )
                .msText(.bodyMedium, color: MSColors.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filtered, id: \.id) { d in DeliveryCard(delivery: d, now: now) { onSelect(d) } }
                    }
                }
            }
        }
        // "4 min ago" moves on with the clock.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                now = DeliveryWords.nowMs()
            }
        }
    }

    private func groupCell(_ g: LedgerGroup) -> some View {
        let color = Words.deliveryColor(g.rawValue)
        let selected = filterGroup == g
        let count = deliveries.filter { g.statuses.contains($0.status) }.count
        return Button {
            filterGroup = selected ? nil : g
        } label: {
            VStack(spacing: 0) {
                Text("\(count)").msText(.titleMedium, mono: true, color: color)
                Text(Words.deliveryState(g.rawValue)).msText(.bodySmall, color: selected ? color : MSColors.textMuted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: MSSpace.touch)
            .padding(.vertical, 4)
            .background(selected ? color.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One message on its way: the link, its state, the text, when, and what went wrong. `onRetry`
/// and `onCancel` add buttons for a message that can be retried or cancelled; leave them nil to
/// keep the actions in the details dialog.
struct DeliveryCard: View {
    let delivery: MessageDelivery
    let now: Int64
    var onRetry: (() -> Void)?
    var onCancel: (() -> Void)?
    let onClick: () -> Void

    init(delivery: MessageDelivery, now: Int64, onRetry: (() -> Void)? = nil, onCancel: (() -> Void)? = nil, onClick: @escaping () -> Void)
    {
        self.delivery = delivery
        self.now = now
        self.onRetry = onRetry
        self.onCancel = onCancel
        self.onClick = onClick
    }

    var body: some View {
        let d = delivery
        let problem = ["sent", "delivered"].contains(d.status) ? "" : DeliveryWords.problem(d.lastError)
        let meta = [
            Words.ago(d.createdAt, nowMs: now), d.priority == 0 ? DeliveryWords.urgency(0) : nil, DeliveryWords.tries(d),
            d.ackStatus.map { DeliveryWords.ack($0) },
        ].compactMap { $0 }.joined(separator: " \u{00B7} ")
        let showCancel = onCancel != nil && DeliveryWords.canCancel(d)
        let showRetry = onRetry != nil && DeliveryWords.canRetry(d)
        Button(action: onClick) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Circle().fill(Words.channelColor(d.channel)).frame(width: 10, height: 10)
                    Text(Words.channel(d.channel)).msText(.titleSmall).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(DeliveryWords.stateText(d)).msText(.labelLarge, color: DeliveryWords.stateColor(d))
                }
                if !d.textPreview.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(d.textPreview).msText(.bodyMedium, color: MSColors.textSecondary).lineLimit(2)
                }
                Text(meta).msText(.bodySmall, color: MSColors.textMuted)
                if !problem.isEmpty {
                    let red = DeliveryWords.gaveUpStatuses.contains(d.status) && !DeliveryWords.isCancelledByUser(d)
                    Text(problem).msText(.bodySmall, color: red ? MSColors.red : MSColors.textMuted).lineLimit(2)
                }
                if showCancel || showRetry {
                    HStack {
                        Spacer(minLength: 0)
                        if showCancel, let onCancel { MSTextButton("Cancel", color: MSColors.red, action: onCancel) }
                        if showRetry, let onRetry { MSTextButton("Retry", color: MSColors.teal, action: onRetry) }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .msCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Everything about one message; the raw fields experts want sit behind "Show details".
struct DeliveryDetailsDialog: View {
    let delivery: MessageDelivery
    let onDismiss: () -> Void
    let onRetry: () -> Void
    let onCancel: () -> Void
    @State private var showDetails = false

    var body: some View {
        let d = delivery
        let now = DeliveryWords.nowMs()
        MSAlertDialog(
            "Message by \(Words.channel(d.channel))", onDismiss: onDismiss,
            content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        DeliveryFact("Status", DeliveryWords.stateText(d), color: DeliveryWords.stateColor(d))
                        DeliveryFact("Urgency", DeliveryWords.urgency(d.priority))
                        DeliveryFact("Added", "\(Words.ago(d.createdAt, nowMs: now)), \(Words.clock(d.createdAt, "MM/dd HH:mm"))")
                        DeliveryFact("Last change", Words.ago(d.updatedAt, nowMs: now))
                        if let t = DeliveryWords.tries(d) { DeliveryFact("Tries", t) }
                        if !d.lastError.isEmpty { DeliveryFact("Problem", DeliveryWords.problem(d.lastError)) }
                        if let a = d.ackStatus { DeliveryFact("Confirmation", DeliveryWords.ack(a)) }
                        if let at = d.expiresAt {
                            if at > now {
                                DeliveryFact("Gives up", Words.inTime(at, nowMs: now))
                            } else {
                                DeliveryFact("Expired", Words.ago(at, nowMs: now))
                            }
                        }
                        if !d.textPreview.isEmpty {
                            Text(d.textPreview).msText(.bodyMedium).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                .background(MSColors.surfaceLight, in: RoundedRectangle(cornerRadius: 4)).padding(.top, 4)
                        }
                        MSTextButton(showDetails ? "Hide details" : "Show details", color: MSColors.textSecondary) { showDetails.toggle() }
                        if showDetails { details(d) }
                    }
                }
                .frame(maxHeight: 420)
            },
            buttons: {
                if DeliveryWords.canRetry(d) { MSTextButton("Retry", color: MSColors.teal, action: onRetry) }
                if DeliveryWords.canCancel(d) { MSTextButton("Cancel message", color: MSColors.red, action: onCancel) }
                MSTextButton("Close", color: MSColors.textSecondary, action: onDismiss)
            })
    }

    @ViewBuilder private func details(_ d: MessageDelivery) -> some View {
        DeliveryFact("Delivery", "#\(d.id ?? 0)", mono: true)
        DeliveryFact("Link id", d.channel, mono: true)
        DeliveryFact("Stored status", d.status, mono: true)
        DeliveryFact("Priority", "\(d.priority)", mono: true)
        DeliveryFact("Message ref", d.msgRef, mono: true)
        if let r = d.ruleId { DeliveryFact("Rule", "#\(r)", mono: true) }
        DeliveryFact("QoS level", "\(d.qosLevel) (\(DeliveryWords.guarantee(d.qosLevel)))", mono: true)
        if d.seqNum > 0 { DeliveryFact("Sequence", "\(d.seqNum)", mono: true) }
        if d.ttlSeconds > 0 { DeliveryFact("TTL", "\(d.ttlSeconds) s", mono: true) }
        if let a = d.ackStatus { DeliveryFact("ACK", a, mono: true) }
        if let c = d.custodyStatus { DeliveryFact("Custody", c, mono: true) }
        if let b = d.bundleId { DeliveryFact("Bundle", b, mono: true) }
        if !d.lastError.isEmpty { DeliveryFact("Error", d.lastError, mono: true) }
    }
}

struct DeliveryFact: View {
    let label: String
    let value: String
    let color: Color
    let mono: Bool
    init(_ label: String, _ value: String, color: Color = MSColors.textPrimary, mono: Bool = false) {
        self.label = label
        self.value = value
        self.color = color
        self.mono = mono
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).msText(.bodySmall, color: MSColors.textMuted)
            Text(value).msText(.bodySmall, mono: mono, color: color).multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
