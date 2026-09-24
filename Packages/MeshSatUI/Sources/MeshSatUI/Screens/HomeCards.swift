// Mirrors the cards of ui/screens/DashboardScreen.kt and SetupChecklistCard of Onboarding.kt:
// the Getting started list, the satellite mailbox, the signal charts, the position, the
// message queue, the recent messages, and Arrange (MESHSAT-401), whose order the old layout
// saved but never applied (MESHSAT-1249).
import MeshSatEngine
import MeshSatPlatform
import MeshSatStore
import SwiftUI

enum HomeCards {
    /// Home's cards, in their default order, and what Arrange calls them. No "burst" card
    /// (MESHSAT-1249); a saved order that still names it simply loses it.
    static let all = ["sos", "queue", "location", "signals", "mailbox", "activity"]
    static let labels = [
        "sos": "SOS", "queue": "Message queue", "location": "Location", "signals": "Signal history", "mailbox": "Satellite mailbox",
        "activity": "Recent messages",
    ]

    /// The saved order, cleaned: cards that no longer exist are dropped, cards added since appended.
    static func order(_ saved: String) -> [String] {
        // Nobody arranged Home yet (empty, or the old built-in default): use the current default.
        if saved.trimmingCharacters(in: .whitespaces).isEmpty || saved == "transports,signals,sos,location,queue,burst,reticulum,activity" {
            return all
        }
        var kept: [String] = []
        for id in saved.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where all.contains(id) && !kept.contains(id)
        {
            kept.append(id)
        }
        return kept + all.filter { !kept.contains($0) }
    }
}

/// What the cards read that the model does not carry: the last six hours of signal, the recent
/// messages, the queue depths and stats every five seconds, and the age of the fix.
@Observable
@MainActor
final class HomeCardsModel {
    var meshHistory: [SignalRecord] = []
    var cellularHistory: [SignalRecord] = []
    var recentMessages: [MessageRecord] = []
    var smsToday = 0
    var deliveryStats: [DeliveryStatRow] = []
    var meshQueueDepth = 0
    var iridiumQueueDepth = 0
    var smsQueueDepth = 0
    var nowMs = Int64(Date().timeIntervalSince1970 * 1000)

    func statCount(_ status: String) -> Int { deliveryStats.filter { $0.status == status }.map(\.cnt).reduce(0, +) }

    func run(db: AppDatabase) async {
        let since = Int64(Date().timeIntervalSince1970 * 1000) - 6 * 3_600_000
        let mesh = Task { [weak self] in
            do {
                for try await rows in db.signals.getSince(source: "mesh", since: since) { self?.meshHistory = rows }
            } catch {}
        }
        let cell = Task { [weak self] in
            do {
                for try await rows in db.signals.getSince(source: "cellular", since: since) { self?.cellularHistory = rows }
            } catch {}
        }
        let recent = Task { [weak self] in
            do {
                for try await rows in db.messages.getRecent(limit: 20) { self?.recentMessages = rows }
            } catch {}
        }
        let sms = Task { [weak self] in
            do {
                for try await n in db.messages.countSince(HomeCardsModel.dayAgo(), transport: "sms") { self?.smsToday = n }
            } catch {}
        }
        defer {
            mesh.cancel()
            cell.cancel()
            recent.cancel()
            sms.cancel()
        }
        while !Task.isCancelled {
            deliveryStats = (try? await db.deliveries.stats()) ?? []
            meshQueueDepth = (try? await db.deliveries.queueDepth(channel: "mesh_0")) ?? 0
            iridiumQueueDepth = (try? await db.deliveries.queueDepth(channel: "iridium_0")) ?? 0
            smsQueueDepth = (try? await db.deliveries.queueDepth(channel: "sms_0")) ?? 0
            nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    static func dayAgo() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) - 86_400_000 }
}

/// Reusable card container: a title and its content.
struct DashboardCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).msText(.titleMedium)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .msCard()
    }
}

/// Home's "Getting started" list (MESHSAT-1249): the few things that make the app useful, each
/// done or one tap from done. It goes once everything is done, or when dismissed.
struct SetupChecklistCard: View {
    @Environment(GatewayModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    @Environment(Router.self) private var router

    private struct Step {
        let title: String
        let detail: String
        let done: Bool
        let route: Route
    }

    var body: some View {
        let steps: [Step] = [
            Step(
                title: "Pair your MeshSat node", detail: "The radios: mesh and satellite", done: model.meshPaired,
                route: .setupSection(.node)),
            Step(title: "Scan the Hub's QR code", detail: "Optional: the control room", done: model.hubSetUp, route: .setupSection(.hub)),
            Step(
                title: "Add emergency contacts", detail: "Who an SOS goes to by text", done: !model.sosContacts.isEmpty,
                route: .setupSection(.safety)),
        ]
        let done = steps.filter(\.done).count
        if !settings.bool(SettingsKey.checklistDismissed), done < steps.count {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Getting started").msText(.titleMedium)
                        Text("\(done) of \(steps.count) done").msText(.bodySmall, color: MSColors.textSecondary)
                    }
                    Spacer(minLength: 0)
                    MSTextButton("Hide", color: MSColors.offWhite) { settings.set(SettingsKey.checklistDismissed, true) }
                }
                .padding(.leading, 12).padding(.trailing, 4)
                ForEach(steps, id: \.title) { step in
                    Button {
                        if !step.done { router.navigate(step.route) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: step.done ? "checkmark.circle" : "circle").font(.system(size: 22))
                                .foregroundStyle(step.done ? MSColors.green : MSColors.textMuted)
                                .accessibilityLabel(step.done ? "Done" : "To do")
                            VStack(alignment: .leading, spacing: 0) {
                                Text(step.title).msText(.bodyLarge, color: step.done ? MSColors.textSecondary : MSColors.offWhite)
                                Text(step.detail).msText(.bodySmall, color: MSColors.textMuted)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(step.done)
                }
            }
            .padding(.vertical, 8)
            .msCard()
        }
    }
}

/// Signal sparkline chart with 30-min bucket averaging and area fill.
struct SignalChart: View {
    let title: String
    let records: [SignalRecord]
    let maxValue: Float
    let minValue: Float
    let color: Color
    let formatValue: (Float) -> String

    private var points: [Float] {
        var buckets: [Int64: [Float]] = [:]
        for r in records { buckets[r.timestamp / (30 * 60_000), default: []].append(Float(r.value)) }
        let averaged = buckets.keys.sorted().map { k in buckets[k]!.reduce(0, +) / Float(buckets[k]!.count) }
        return averaged.count >= 2 ? averaged : records.map { Float($0.value) }
    }

    var body: some View {
        let pts = points
        let range = maxValue - minValue
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).msText(.titleMedium)
                Spacer(minLength: 0)
                Text(formatValue(Float(records.last?.value ?? 0))).msText(.bodyMedium, color: color)
            }
            if records.count >= 2 {
                HStack {
                    Text(Words.clock(records[0].timestamp, "HH:mm")).msText(.labelSmall, color: MSColors.textMuted)
                    Spacer(minLength: 0)
                    Text(Words.clock(records[records.count - 1].timestamp, "HH:mm")).msText(.labelSmall, color: MSColors.textMuted)
                }
                .padding(.top, 2)
            }
            Canvas { ctx, size in
                guard pts.count >= 2 else { return }
                let w = size.width
                let h = size.height
                let stepX = w / CGFloat(max(pts.count - 1, 1))
                func y(_ v: Float) -> CGFloat { h - CGFloat(min(max((v - minValue) / range, 0), 1)) * h }
                for i in 0...4 {
                    var g = Path()
                    g.move(to: CGPoint(x: 0, y: h * CGFloat(i) / 4))
                    g.addLine(to: CGPoint(x: w, y: h * CGFloat(i) / 4))
                    ctx.stroke(g, with: .color(MSColors.border), lineWidth: 0.5)
                }
                var area = Path()
                area.move(to: CGPoint(x: 0, y: h))
                for (i, v) in pts.enumerated() { area.addLine(to: CGPoint(x: CGFloat(i) * stepX, y: y(v))) }
                area.addLine(to: CGPoint(x: CGFloat(pts.count - 1) * stepX, y: h))
                area.closeSubpath()
                ctx.fill(area, with: .color(color.opacity(0.12)))
                var line = Path()
                for (i, v) in pts.enumerated() {
                    let p = CGPoint(x: CGFloat(i) * stepX, y: y(v))
                    if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                }
                ctx.stroke(line, with: .color(color), lineWidth: 2)
                if pts.count < 30 {
                    for (i, v) in pts.enumerated() {
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: CGFloat(i) * stepX - 2.5, y: y(v) - 2.5, width: 5, height: 5)), with: .color(color))
                    }
                }
            }
            .frame(height: 80)
            .padding(.top, 4)
            if !pts.isEmpty {
                HStack {
                    Text("min: \(formatValue(pts.min() ?? 0))").msText(.labelSmall, color: MSColors.textMuted)
                    Spacer(minLength: 0)
                    Text("avg: \(formatValue(pts.reduce(0, +) / Float(pts.count)))").msText(.labelSmall, color: MSColors.textMuted)
                    Spacer(minLength: 0)
                    Text("max: \(formatValue(pts.max() ?? 0))").msText(.labelSmall, color: MSColors.textMuted)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .msCard()
    }
}

/// Plain words, and a decimal point whatever the phone's language (MESHSAT-1249).
struct LocationCard: View {
    let fix: PhoneFix?
    let nowMs: Int64

    var body: some View {
        DashboardCard("Your position") {
            if let loc = fix {
                let ageS = max(0, (nowMs - loc.timeMs) / 1000)
                let age = ageS < 5 ? "just now" : (ageS < 60 ? "\(ageS) s ago" : "\(ageS / 60) min ago")
                Text(String(format: "%.5f, %.5f", loc.latitude, loc.longitude)).msText(.titleMedium)
                Text((loc.horizontalAccuracyM >= 0 ? "within \(Int(loc.horizontalAccuracyM)) m, " : "") + age)
                    .msText(.bodySmall, color: MSColors.textSecondary)
                let extra = [
                    "Height \(Int(loc.altitude)) m",
                    loc.speedMps >= 0.5
                        ? String(format: "moving %.1f km/h", loc.speedMps * 3.6)
                            + (loc.courseDeg >= 0 ? ", heading \(Int(loc.courseDeg))\u{00B0}" : "")
                        : nil,
                ].compactMap { $0 }
                if !extra.isEmpty { Text(extra.joined(separator: ". ") + ".").msText(.bodySmall, color: MSColors.textMuted) }
            } else {
                Text("Waiting for a position. Location must be allowed, and the phone needs a view of the sky.")
                    .msText(.bodyMedium, color: MSColors.textMuted)
            }
        }
    }
}

/// The same words as the queue screen (Words.deliveryState), and a way to it.
struct QueueCard: View {
    let cards: HomeCardsModel
    @Environment(Router.self) private var router

    var body: some View {
        DashboardCard("Message queue") {
            QueueBar("Satellite", cards.iridiumQueueDepth, MSColors.iridium)
            QueueBar("Mesh", cards.meshQueueDepth, MSColors.mesh)
            QueueBar("SMS", cards.smsQueueDepth, MSColors.cellular)
            Spacer().frame(height: 8)
            HStack {
                StatBadge("Waiting", cards.statCount("queued") + cards.statCount("retry") + cards.statCount("held"), MSColors.amber)
                StatBadge("Sending", cards.statCount("sending"), MSColors.amber)
                StatBadge("Failed", cards.statCount("failed"), MSColors.red)
                StatBadge("Gave up", cards.statCount("dead"), MSColors.textMuted)
            }
            HStack { MSTextButton("Open the queue", color: MSColors.offWhite) { router.navigate(.deliveries) } }
        }
    }
}

/// Small queue depth bar for a single interface: 20 messages is a full bar.
struct QueueBar: View {
    let label: String
    let depth: Int
    let color: Color
    init(_ label: String, _ depth: Int, _ color: Color) {
        self.label = label
        self.depth = depth
        self.color = color
    }
    var body: some View {
        HStack(spacing: 8) {
            Text(label).msText(.bodySmall, color: MSColors.textMuted).frame(width: 64, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(MSColors.border)
                    if depth > 0 { Capsule().fill(color).frame(width: g.size.width * CGFloat(min(max(Double(depth) / 20, 0.05), 1))) }
                }
            }
            .frame(height: 6)
            Text("\(depth)").msText(.bodySmall.weight(.bold)).frame(width: 24, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

struct StatBadge: View {
    let label: String
    let count: Int
    let color: Color
    init(_ label: String, _ count: Int, _ color: Color) {
        self.label = label
        self.count = count
        self.color = color
    }
    var body: some View {
        VStack(spacing: 0) {
            Text("\(count)").msText(.titleMedium.weight(.bold), color: color)
            Text(label).msText(.labelSmall, color: MSColors.textMuted)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Single activity log entry.
struct ActivityLogEntry: View {
    let msg: MessageRecord
    var body: some View {
        let tx = msg.direction == "tx"
        HStack(alignment: .top, spacing: 6) {
            Text(Words.clock(msg.timestamp, "HH:mm")).msText(.labelSmall, color: MSColors.textMuted)
            Text(Words.transport(msg.transport)).msText(.labelSmall, color: Words.transportColor(msg.transport)).lineLimit(1)
                .frame(width: 64, alignment: .leading)
            Text(tx ? "\u{2191}" : "\u{2193}").msText(
                .bodySmall.weight(.bold), color: tx ? MSColors.green : (msg.direction == "rx" ? MSColors.teal : MSColors.textMuted))
            Text(String(msg.text.prefix(80)).replacingOccurrences(of: "\n", with: " ")).msText(.bodySmall).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
    }
}

/// Arrange Home (MESHSAT-401): move a card up or down. The lanes stay at the top.
struct ReorderDialog: View {
    let cards: [String]
    let onDismiss: () -> Void
    let onConfirm: ([String]) -> Void
    @State private var order: [String]

    init(cards: [String], onDismiss: @escaping () -> Void, onConfirm: @escaping ([String]) -> Void) {
        self.cards = cards
        self.onDismiss = onDismiss
        self.onConfirm = onConfirm
        _order = State(initialValue: cards)
    }

    var body: some View {
        MSAlertDialog(
            "Arrange Home", onDismiss: onDismiss,
            content: {
                VStack(spacing: 4) {
                    Text("Move a card up or down. The lanes stay at the top.").msText(.bodySmall, color: MSColors.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer().frame(height: 8)
                    ForEach(Array(order.enumerated()), id: \.element) { index, id in
                        HStack {
                            Text(HomeCards.labels[id] ?? id).msText(.bodyMedium).frame(maxWidth: .infinity, alignment: .leading)
                            MSIconButton(
                                Image(systemName: "arrowtriangle.up.fill"), label: "Move \(HomeCards.labels[id] ?? id) up",
                                tint: index > 0 ? MSColors.teal : MSColors.border, size: 40, glyph: 16, enabled: index > 0
                            ) { order.swapAt(index, index - 1) }
                            MSIconButton(
                                Image(systemName: "arrowtriangle.down.fill"), label: "Move \(HomeCards.labels[id] ?? id) down",
                                tint: index < order.count - 1 ? MSColors.teal : MSColors.border, size: 40, glyph: 16,
                                enabled: index < order.count - 1
                            ) { order.swapAt(index, index + 1) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(MSColors.surface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(MSColors.border, lineWidth: 1))
                    }
                }
            },
            buttons: {
                MSTextButton("Cancel", color: MSColors.textSecondary, action: onDismiss)
                MSFilledButton("Apply", container: MSColors.teal, fullWidth: false) { onConfirm(order) }
            })
    }
}
