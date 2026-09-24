// Mirrors ui/screens/InterfacesScreen.kt: Links, each way the phone sends and receives, its
// rules, capabilities, groups, backup links and health.
import MeshSatEngine
import MeshSatStore
import SwiftUI

private enum IfaceTab: String, CaseIterable {
    case interfaces = "Links"
    case accessRules = "Rules"
    case channels = "Capabilities"
    case objectGroups = "Groups"
    case failover = "Backup links"
    case health = "Health"
}

/// How often the groups and backup links tabs re-read the database.
private let groupsRefreshNs: UInt64 = 10_000_000_000

public struct InterfacesScreen: View {
    @Environment(GatewayModel.self) private var model
    @State private var activeTab: IfaceTab = .interfaces
    @State private var confirmOff: String?
    @State private var healthScores: [HealthScore] = []

    public init() {}

    public var body: some View {
        let states = model.interfaces
        VStack(alignment: .leading, spacing: 0) {
            Text("Each way this phone can send and receive messages, and how well it is working.")
                .msText(.bodyMedium, color: MSColors.textSecondary).padding(.bottom, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(IfaceTab.allCases, id: \.self) { tab in
                        let badge =
                            switch tab {
                            case .interfaces: states.values.filter { $0.state == .online }.count
                            case .health: healthScores.filter { $0.score < 50 && $0.available }.count
                            default: 0
                            }
                        tabButton(tab, badge: badge)
                    }
                }
            }
            Rectangle().fill(MSColors.border).frame(height: 1).padding(.top, 4).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) { content(states) }
            }
        }
        .padding(MSSpace.screen)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MSColors.bg)
        // Health scores, refreshed every 30 s
        .task {
            let gateway = model.gateway
            let scorer = HealthScorer(statuses: { gateway.interfaceManager.getAllStatus() }, store: GrdbHealthStore(gateway.db))
            while !Task.isCancelled {
                healthScores = await scorer.scoreAll().sorted { $0.interfaceId < $1.interfaceId }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .overlay {
            if let id = confirmOff { confirmOffDialog(id) }
        }
    }

    private func tabButton(_ tab: IfaceTab, badge: Int) -> some View {
        let selected = activeTab == tab
        let badgeColor: Color = tab == .interfaces ? MSColors.green : (tab == .health ? MSColors.amber : MSColors.textSecondary)
        return Button {
            activeTab = tab
        } label: {
            HStack(spacing: 6) {
                Text(tab.rawValue).msText(
                    selected ? .labelLarge.weight(.semiBold) : .labelLarge.weight(.regular),
                    color: selected ? MSColors.textPrimary : MSColors.textMuted)
                if badge > 0 {
                    Text("\(badge)").msText(.labelSmall, color: badgeColor).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(badgeColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: MSSpace.touch)
            .background(selected ? MSColors.surfaceLight : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func content(_ states: [String: InterfaceStatus]) -> some View {
        switch activeTab {
        case .interfaces: interfacesTab(states)
        case .accessRules: AccessRulesTab()
        case .channels: channelsTab
        case .objectGroups: ObjectGroupsTab()
        case .failover: FailoverTab()
        case .health: healthTab
        }
    }

    // MARK: Links: live status with controls

    @ViewBuilder private func interfacesTab(_ states: [String: InterfaceStatus]) -> some View {
        if states.isEmpty { emptyText("No links yet. They appear once the MeshSat service is running.") }
        // Sort: mesh first, then satellite, then SMS
        let order: (String) -> Int = { id in id.hasPrefix("mesh") ? 0 : (id.hasPrefix("iridium") ? 1 : (id.hasPrefix("sms") ? 2 : 3)) }
        let sorted = states.values.sorted { (order($0.id), $0.id) < (order($1.id), $1.id) }
        ForEach(sorted, id: \.id) { status in
            InterfaceCard(
                status: status,
                onEnable: {
                    model.gateway.interfaceManager.enable(status.id)
                    model.showToast("\(Words.channel(status.id)) switched on")
                },
                // Switching a link off is confirmed first: it stops everything that goes by it.
                onDisable: { confirmOff = status.id },
                onReconnect: {
                    model.gateway.interfaceManager.reconnectNow(status.id)
                    model.showToast("Trying to connect \(Words.channel(status.id)) now")
                })
        }
    }

    private func confirmOffDialog(_ id: String) -> some View {
        let link = Words.channel(id)
        return MSAlertDialog(
            "Switch off \(link)?", onDismiss: { confirmOff = nil },
            content: {
                Text(
                    id.hasPrefix("iridium")
                        ? "The phone stops using the satellite modem and stops reconnecting to it. Nothing goes out or comes in by "
                            + "satellite until you switch it back on. Messages waiting for it stay in the queue."
                        : "Messages stop going out by \(link) until you switch it back on. Messages waiting for it stay in the queue."
                )
                .msText(.bodyMedium)
            },
            buttons: {
                MSTextButton("Keep it on", color: MSColors.textSecondary) { confirmOff = nil }
                MSTextButton("Switch off", color: MSColors.red) {
                    confirmOff = nil
                    model.gateway.interfaceManager.disable(id)
                    model.showToast("\(link) switched off")
                }
            })
    }

    // MARK: Capabilities: what each link can carry (read-only)

    @ViewBuilder private var channelsTab: some View {
        let channels = model.gateway.registry.list()
        Text("What each link can carry, and how it retries.").msText(.bodySmall, color: MSColors.textMuted).padding(.bottom, 4)
        if channels.isEmpty { emptyText("Nothing to show yet. It appears once the MeshSat service is running.") }
        ForEach(channels, id: \.id) { ch in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(Words.channelColor(ch.id)).frame(width: 10, height: 10)
                    Text(Words.channel(ch.id)).msText(.titleSmall).frame(maxWidth: .infinity, alignment: .leading)
                    Text(ch.label).msText(.bodySmall, color: MSColors.textMuted)
                }
                CapabilityRow("Largest message", ch.maxPayload > 0 ? "\(ch.maxPayload) bytes" : "No limit")
                CapabilityRow("Sends", ch.canSend ? "Yes" : "No")
                CapabilityRow("Receives", ch.canReceive ? "Yes" : "No")
                CapabilityRow("Carries data, not only text", ch.binaryCapable ? "Yes" : "No")
                CapabilityRow("Cost", ch.isPaid ? "Paid" : "Free")
                if ch.retryConfig.enabled {
                    let rc = ch.retryConfig
                    let howOften =
                        rc.backoffFunc == "isu"
                        ? "waits for the next satellite pass"
                        : "first after \(rc.initialWaitMs / 1000) s, then up to \(rc.maxWaitMs / 1000) s apart"
                    Text("Retries: \(howOften)" + (rc.maxRetries > 0 ? ", at most \(Words.count(rc.maxRetries, "time"))." : "."))
                        .msText(.bodySmall, color: MSColors.textSecondary).padding(.top, 2)
                }
            }
            .padding(12)
            .msCard()
        }
    }

    // MARK: Health: one score per link

    @ViewBuilder private var healthTab: some View {
        Text("A score out of 100 for each link, from its signal, how many messages got through, how fast, and what it costs.")
            .msText(.bodySmall, color: MSColors.textMuted).padding(.bottom, 4)
        if healthScores.isEmpty { emptyText("No scores yet. They appear once the MeshSat service is running.") }
        ForEach(healthScores, id: \.interfaceId) { hs in HealthCard(hs: hs) }
    }

    private func emptyText(_ text: String) -> some View {
        Text(text).msText(.bodyMedium, color: MSColors.textMuted).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.vertical, 48)
    }
}

/// Working, trying, failed; a link that is off or switched off is grey, never red.
private func linkStateColor(_ state: InterfaceState) -> Color {
    switch state {
    case .online: MSColors.green
    case .connecting: MSColors.amber
    case .error: MSColors.red
    case .offline, .disabled: MSColors.textMuted
    }
}

private func healthScoreColor(_ score: Int) -> Color {
    if score >= 80 { return MSColors.green }
    if score >= 50 { return MSColors.amber }
    if score > 0 { return MSColors.red }
    return MSColors.textMuted
}

private struct InterfaceCard: View {
    let status: InterfaceStatus
    let onEnable: () -> Void
    let onDisable: () -> Void
    let onReconnect: () -> Void
    @State private var now = DeliveryWords.nowMs()

    var body: some View {
        let stateColor = linkStateColor(status.state)
        let link = Words.channel(status.id)
        let isDisabled = status.state == .disabled
        let times = [
            status.lastOnline > 0 ? "Last working \(Words.ago(status.lastOnline, nowMs: now))" : nil,
            status.lastActivity > 0 ? "last message \(Words.ago(status.lastActivity, nowMs: now))" : nil,
        ].compactMap { $0 }.joined(separator: " \u{00B7} ")
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Words.channelColor(status.id)).frame(width: 10, height: 10)
                Text(link).msText(.titleSmall).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                MSSwitch(isOn: Binding(get: { !isDisabled }, set: { $0 ? onEnable() : onDisable() }), label: "Use \(link)")
            }
            HStack(spacing: 8) {
                Text(Words.linkState(status.state.rawValue)).msText(.labelLarge, color: stateColor).padding(.horizontal, 6).padding(
                    .vertical, 2
                )
                .background(stateColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                if !status.error.isEmpty { Text(status.error).msText(.bodySmall, color: MSColors.red).lineLimit(2) }
            }
            .padding(.top, 4)
            if !times.isEmpty || status.reconnectAttempts > 0 {
                VStack(alignment: .leading, spacing: 0) {
                    if !times.isEmpty { Text(times).msText(.bodySmall, color: MSColors.textMuted) }
                    if status.reconnectAttempts > 0 {
                        Text("Tried to reconnect \(Words.count(status.reconnectAttempts, "time"))").msText(
                            .bodySmall, color: MSColors.amber)
                    }
                }
                .padding(.top, 6)
            }
            // Reconnect (only when off or not working)
            if status.state == .offline || status.state == .error {
                HStack {
                    MSOutlinedButton("Try to connect now", action: onReconnect).fixedSize()
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isDisabled ? Color.black.opacity(0.3) : Color.clear)
        .msCard()
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                now = DeliveryWords.nowMs()
            }
        }
    }
}

private struct CapabilityRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label).msText(.bodySmall, color: MSColors.textMuted).frame(maxWidth: .infinity, alignment: .leading)
            Text(value).msText(
                .bodySmall, mono: value.first?.isNumber == true, color: value == "Yes" ? MSColors.textPrimary : MSColors.textSecondary)
        }
    }
}

private struct HealthCard: View {
    let hs: HealthScore

    var body: some View {
        let color = healthScoreColor(hs.score)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Words.channelColor(hs.interfaceId)).frame(width: 10, height: 10)
                Text(Words.channel(hs.interfaceId)).msText(.titleSmall).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                if !hs.available {
                    Text("Not connected").msText(.labelLarge, color: MSColors.textMuted).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(MSColors.textMuted.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
                Text("\(hs.score)").msText(.titleMedium, mono: true, color: color).padding(.horizontal, 10).padding(.vertical, 4)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(MSColors.border)
                    RoundedRectangle(cornerRadius: 3).fill(color).frame(width: g.size.width * CGFloat(min(max(hs.score, 0), 100)) / 100)
                }
            }
            .frame(height: 6)
            // The parts of the score, each out of 100
            HStack {
                ScoreColumn("Signal", hs.signal)
                ScoreColumn("Got through", Int(hs.successRate * 100))
                ScoreColumn("Speed", hs.latencyMs > 0 ? 100 - min(hs.latencyMs / 1000, 100) : 0)
                ScoreColumn("Low cost", hs.costScore)
            }
        }
        .padding(12)
        .msCard()
    }
}

private struct ScoreColumn: View {
    let label: String
    let value: Int
    init(_ label: String, _ value: Int) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("\(value)").msText(.titleSmall, mono: true)
            Text(label).msText(.bodySmall, color: MSColors.textMuted)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The routing rules of every link (read-only).
private struct AccessRulesTab: View {
    @Environment(GatewayModel.self) private var model
    @State private var rules: [AccessRule] = []

    var body: some View {
        Text("The routing rules of every link. Change them in Routing rules.").msText(.bodySmall, color: MSColors.textMuted).padding(
            .bottom, 4)
        Group {
            if rules.isEmpty {
                Text("No routing rules yet. Add them in Routing rules.").msText(.bodyMedium, color: MSColors.textMuted)
                    .frame(maxWidth: .infinity).padding(.vertical, 48)
            }
            ForEach(rules, id: \.id) { rule in card(rule) }
        }
        .task {
            do {
                for try await list in model.gateway.db.accessRules.getAll() { rules = list }
            } catch {}
        }
    }

    private func card(_ rule: AccessRule) -> some View {
        let route: String =
            if rule.direction == "egress" {
                "Messages leaving by \(Words.channel(rule.interfaceId))"
            } else if rule.action == "forward", !rule.forwardTo.isEmpty {
                "\(Words.channel(rule.interfaceId)) to \(Words.channel(rule.forwardTo))"
            } else {
                "Messages from \(Words.channel(rule.interfaceId))"
            }
        let stateColor = rule.enabled ? MSColors.green : MSColors.textMuted
        let matches = Int(min(rule.matchCount, Int64(Int.max)))
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(rule.name.isEmpty ? "Rule \(rule.id ?? 0)" : rule.name).msText(.titleSmall).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(rule.enabled ? "On" : "Off").msText(.labelLarge, color: stateColor).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(stateColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            }
            Text("\(RuleWords.actionLabel(rule.action)): \(route)").msText(.bodyMedium, color: MSColors.textSecondary)
            Text(matches == 0 ? "No matches yet" : Words.count(matches, "match", "matches")).msText(.bodySmall, color: MSColors.textMuted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rule.enabled ? Color.clear : Color.black.opacity(0.3))
        .msCard()
    }
}

/// A group's type ("node_group", "sender_group", ...) in plain words.
func groupTypeLabel(_ type: String) -> String {
    var t = type.lowercased()
    if t.hasSuffix("_group") { t = String(t.dropLast("_group".count)) }
    switch t {
    case "node": return "Nodes"
    case "sender": return "Senders"
    case "portnum": return "Message types"
    case "contact": return "Contacts"
    default:
        let s = type.replacingOccurrences(of: "_", with: " ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}

/// Named groups of nodes, senders or message types (read-only), re-read now and then so a group
/// added through a config import shows up without leaving the screen.
private struct ObjectGroupsTab: View {
    @Environment(GatewayModel.self) private var model
    @State private var groups: [ObjectGroup] = []

    var body: some View {
        Text("Named groups of nodes, senders or message types that rules can match.").msText(.bodySmall, color: MSColors.textMuted)
            .padding(.bottom, 4)
        Group {
            if groups.isEmpty {
                Text("No groups yet.").msText(.bodyMedium, color: MSColors.textMuted).frame(maxWidth: .infinity).padding(.vertical, 48)
            }
            ForEach(groups, id: \.id) { g in
                let members = (try? JSONSerialization.jsonObject(with: Data(g.members.utf8)) as? [Any])?.count ?? 0
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(g.label.isEmpty ? g.id : g.label).msText(.titleSmall).lineLimit(1).frame(
                            maxWidth: .infinity, alignment: .leading)
                        Text(Words.count(members, "member")).msText(.bodySmall, color: MSColors.textSecondary)
                    }
                    Text(groupTypeLabel(g.type)).msText(.bodySmall, color: MSColors.textMuted)
                }
                .padding(12)
                .msCard()
            }
        }
        .task {
            while !Task.isCancelled {
                if let list = try? await model.gateway.db.objectGroups.getAll() { groups = list }
                try? await Task.sleep(nanoseconds: groupsRefreshNs)
            }
        }
    }
}

/// Failover and broadcast groups (read-only).
private struct FailoverTab: View {
    @Environment(GatewayModel.self) private var model
    @State private var groups: [FailoverGroup] = []
    @State private var memberCounts: [String: Int] = [:]

    var body: some View {
        Text("Groups of links that stand in for each other, or that all carry the same message.").msText(
            .bodySmall, color: MSColors.textMuted
        )
        .padding(.bottom, 4)
        Group {
            if groups.isEmpty {
                Text("No backup links set up.").msText(.bodyMedium, color: MSColors.textMuted).frame(maxWidth: .infinity).padding(
                    .vertical, 48)
            }
            ForEach(groups, id: \.id) { g in
                let mode =
                    switch g.mode {
                    case "failover": "Uses the first link that works"
                    case "broadcast": "Sends on every link"
                    default: g.mode.prefix(1).uppercased() + g.mode.dropFirst()
                    }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(g.label.isEmpty ? g.id : g.label).msText(.titleSmall).lineLimit(1).frame(
                            maxWidth: .infinity, alignment: .leading)
                        Text(Words.count(memberCounts[g.id] ?? 0, "link")).msText(.bodySmall, color: MSColors.textSecondary)
                    }
                    Text(mode).msText(.bodySmall, color: MSColors.textMuted)
                }
                .padding(12)
                .msCard()
            }
        }
        .task {
            let dao = model.gateway.db.failoverGroups
            while !Task.isCancelled {
                if let all = try? await dao.getAllGroups() {
                    var counts: [String: Int] = [:]
                    for g in all { counts[g.id] = (try? await dao.getMembers(g.id).count) ?? 0 }
                    memberCounts = counts
                    groups = all
                }
                try? await Task.sleep(nanoseconds: groupsRefreshNs)
            }
        }
    }
}
