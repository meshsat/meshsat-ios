// Mirrors ui/screens/RulesScreen.kt (MESHSAT-1249): routing rules, which messages pass from one
// link to another, plus the messages those rules put in the queue.
import MeshSatEngine
import MeshSatStore
import SwiftUI

private enum BridgeTab: String, CaseIterable {
    case outbound = "From mesh"
    case inbound = "Into mesh"
    case crossBridge = "Between links"
    case deliveries = "Deliveries"
    case queue = "Queue"

    var isRuleTab: Bool { self == .outbound || self == .inbound || self == .crossBridge }
}

/// The tab a rule is listed under. Every rule lands on exactly one tab, whatever its action or
/// direction: before, a Drop or Log only rule vanished from the screen once saved (B10).
private func ruleTab(_ rule: AccessRule) -> BridgeTab {
    if rule.interfaceId.hasPrefix("mesh") { return .outbound }
    if rule.forwardTo.hasPrefix("mesh") { return .inbound }
    return .crossBridge
}

public struct RulesScreen: View {
    @Environment(GatewayModel.self) private var model
    @State private var allRules: [AccessRule] = []
    @State private var deliveries: [MessageDelivery] = []
    @State private var now = DeliveryWords.nowMs()
    @State private var activeTab: BridgeTab = .outbound
    @State private var showAdd = false
    @State private var editRule: AccessRule?
    @State private var ruleToDelete: AccessRule?
    @State private var selectedDeliveryId: Int64?
    @State private var queueRequest: QueueRequest?

    public init() {}

    private var db: AppDatabase { model.gateway.db }

    private func rules(_ tab: BridgeTab) -> [AccessRule] { allRules.filter { ruleTab($0) == tab } }

    private func reloadEvaluator() async { try? await model.gateway.accessEvaluator?.reloadFromDb() }

    public var body: some View {
        let queueCount = deliveries.filter {
            DeliveryWords.waitingStatuses.contains($0.status) || DeliveryWords.gaveUpStatuses.contains($0.status)
        }
        .count
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Rules decide which messages are passed from one link to another.").msText(.bodyMedium, color: MSColors.textSecondary)
                    .padding(.bottom, 8)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(BridgeTab.allCases, id: \.self) { tab in
                            let badge = tab.isRuleTab ? rules(tab).count : (tab == .queue ? queueCount : 0)
                            tabButton(tab, badge: badge)
                        }
                    }
                }
                Rectangle().fill(MSColors.border).frame(height: 1).padding(.top, 4).padding(.bottom, 12)
                content
            }
            .padding(MSSpace.screen)
            if activeTab.isRuleTab {
                Button {
                    showAdd = true
                } label: {
                    MSIcon.add.resizable().scaledToFit().frame(width: 24, height: 24).foregroundStyle(MSColors.ink)
                        .frame(width: 56, height: 56)
                        .background(MSColors.teal, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add rule")
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MSColors.bg)
        .task {
            do {
                for try await list in db.accessRules.getAll() { allRules = list }
            } catch {}
        }
        .task {
            do {
                for try await list in db.deliveries.getRecent(limit: 200) { deliveries = list }
            } catch {}
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                now = DeliveryWords.nowMs()
            }
        }
        .overlay { dialogs }
    }

    private func tabButton(_ tab: BridgeTab, badge: Int) -> some View {
        let selected = activeTab == tab
        return Button {
            activeTab = tab
        } label: {
            HStack(spacing: 6) {
                Text(tab.rawValue).msText(
                    selected ? .labelLarge.weight(.semiBold) : .labelLarge.weight(.regular),
                    color: selected ? MSColors.textPrimary : MSColors.textMuted)
                if badge > 0 {
                    Text("\(badge)").msText(.labelSmall, color: MSColors.textSecondary).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(MSColors.border, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: MSSpace.touch)
            .background(selected ? MSColors.surfaceLight : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var content: some View {
        switch activeTab {
        case .outbound:
            rulesList(
                rules(.outbound), empty: "No rules for mesh messages yet, so they stay on the mesh. Tap + to add one.",
                subtitle: "What happens to messages heard on the mesh.")
        case .inbound:
            rulesList(
                rules(.inbound), empty: "No rules pass messages into the mesh yet. Tap + to add one.",
                subtitle: "Messages from satellite, SMS or the Hub that are passed into the mesh.")
        case .crossBridge:
            rulesList(
                rules(.crossBridge), empty: "No rules between the other links yet. Tap + to add one.",
                subtitle: "Messages from satellite, SMS or the Hub that go to another link, or are stopped or only logged.")
        case .deliveries:
            DeliveryLedger(deliveries: deliveries) { selectedDeliveryId = $0.id }
        case .queue:
            QueueTabContent(deliveries: deliveries, now: now, onSelect: { selectedDeliveryId = $0.id }, onRequest: { queueRequest = $0 })
        }
    }

    private func rulesList(_ rules: [AccessRule], empty: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(subtitle).msText(.bodySmall, color: MSColors.textMuted).padding(.bottom, 8)
            if rules.isEmpty {
                Text(empty).msText(.bodyMedium, color: MSColors.textMuted).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(rules, id: \.id) { rule in
                            AccessRuleCard(
                                rule: rule, now: now,
                                onToggle: { on in
                                    var r = rule
                                    r.enabled = on
                                    Task {
                                        try? await db.accessRules.update(r)
                                        await reloadEvaluator()
                                    }
                                },
                                onDelete: { ruleToDelete = rule }, onEdit: { editRule = rule })
                        }
                        // Room under the last card for the add button
                        Spacer().frame(height: 72)
                    }
                }
            }
        }
    }

    @ViewBuilder private var dialogs: some View {
        if showAdd {
            AddEditRuleDialog(
                rule: nil, activeTab: activeTab, links: model.interfaces, onDismiss: { showAdd = false },
                onSave: { rule in
                    showAdd = false
                    // Show the tab the rule is listed under, so it never seems to disappear.
                    activeTab = ruleTab(rule)
                    Task {
                        _ = try? await db.accessRules.insert(rule)
                        await reloadEvaluator()
                    }
                    model.showToast("Rule added")
                })
        }
        if let rule = editRule {
            AddEditRuleDialog(
                rule: rule, activeTab: activeTab, links: model.interfaces, onDismiss: { editRule = nil },
                onSave: { updated in
                    editRule = nil
                    activeTab = ruleTab(updated)
                    Task {
                        try? await db.accessRules.update(updated)
                        await reloadEvaluator()
                    }
                    model.showToast("Rule saved")
                })
        }
        if let rule = ruleToDelete {
            MSAlertDialog(
                "Delete this rule?", onDismiss: { ruleToDelete = nil },
                content: { Text(RuleWords.deleteConsequence(rule) + " You cannot undo this.").msText(.bodyMedium) },
                buttons: {
                    MSTextButton("Keep it", color: MSColors.textSecondary) { ruleToDelete = nil }
                    MSTextButton("Delete", color: MSColors.red) {
                        ruleToDelete = nil
                        if let id = rule.id {
                            Task {
                                try? await db.accessRules.deleteById(id)
                                await reloadEvaluator()
                            }
                        }
                        model.showToast("Rule deleted")
                    }
                })
        }
        DeliveryDialogs(deliveries: deliveries, selectedId: $selectedDeliveryId, request: $queueRequest)
    }
}

private struct AccessRuleCard: View {
    let rule: AccessRule
    let now: Int64
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void
    let onEdit: () -> Void

    var body: some View {
        let name = rule.name.isEmpty ? "Rule \(rule.id ?? 0)" : rule.name
        let matches = Int(min(rule.matchCount, Int64(Int.max)))
        let meta = [
            matches == 0 ? "No matches yet" : Words.count(matches, "match", "matches"),
            RuleWords.parseUtcStamp(rule.lastMatchAt).map { "last \(Words.ago($0, nowMs: now))" },
            RuleWords.rateLimitText(rule.rateLimitPerMin, rule.rateLimitWindow),
            rule.qosLevel <= 0 ? DeliveryWords.guarantee(rule.qosLevel) : nil,
            rule.priority == 0 ? DeliveryWords.urgency(rule.priority) : nil,
        ].compactMap { $0 }.joined(separator: " \u{00B7} ")
        let filter = RuleWords.filterSummary(rule)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name).msText(.titleSmall).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                MSSwitch(isOn: Binding(get: { rule.enabled }, set: onToggle), label: "Rule \(name) is \(rule.enabled ? "on" : "off")")
                    .padding(.horizontal, 8)
            }
            routeText.padding(.trailing, 8)
            Text(meta).msText(.bodySmall, color: MSColors.textMuted).padding(.trailing, 8)
            if !filter.isEmpty { Text(filter).msText(.bodySmall, color: MSColors.textSecondary).padding(.trailing, 8) }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                MSIconButton(Image(systemName: "pencil"), label: "Edit rule \(name)", action: onEdit)
                MSIconButton(MSIcon.delete, label: "Delete rule \(name)", action: onDelete)
            }
        }
        .padding(.leading, 12).padding(.top, 8).padding(.trailing, 4).padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rule.enabled ? Color.clear : Color.black.opacity(0.3))
        .msCard()
    }

    private func link(_ id: String) -> Text { Text(Words.channel(id)).foregroundColor(Words.channelColor(id)) }

    /// "Forward: Mesh to Satellite", "Drop: messages from SMS", with each link in its colour.
    private var routeText: some View {
        let head = Text("\(RuleWords.actionLabel(rule.action)): ").font(MSFont.sans(14, .semiBold)).foregroundColor(MSColors.textPrimary)
        let rest: Text =
            if rule.direction == "egress" {
                Text("messages leaving by ") + link(rule.interfaceId)
            } else if rule.action == "forward", !rule.forwardTo.isEmpty {
                link(rule.interfaceId) + Text(" to ") + link(rule.forwardTo)
            } else {
                Text("messages from ") + link(rule.interfaceId)
            }
        return (head + rest).msText(.bodyMedium, color: MSColors.textSecondary)
    }
}

/// Waiting messages (with Cancel) and messages that gave up (with Retry). The tab used to list
/// only the ones that gave up while offering Cancel only to waiting ones, so Cancel never showed (B11).
private struct QueueTabContent: View {
    let deliveries: [MessageDelivery]
    let now: Int64
    let onSelect: (MessageDelivery) -> Void
    let onRequest: (QueueRequest) -> Void

    var body: some View {
        let waiting = deliveries.filter { DeliveryWords.waitingStatuses.contains($0.status) }
        let gaveUp = deliveries.filter { DeliveryWords.gaveUpStatuses.contains($0.status) }
        VStack(alignment: .leading, spacing: 0) {
            Text("Messages still waiting to go out, and messages that did not. Cancel one that is waiting, or retry one that gave up.")
                .msText(.bodySmall, color: MSColors.textMuted).padding(.bottom, 8)
            if waiting.isEmpty && gaveUp.isEmpty {
                Text("Nothing is waiting, and nothing has failed.").msText(.bodyMedium, color: MSColors.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if !waiting.isEmpty {
                            sectionTitle("Waiting to go out (\(waiting.count))")
                            ForEach(waiting, id: \.id) { d in
                                DeliveryCard(
                                    delivery: d, now: now, onCancel: { onRequest(QueueRequest(delivery: d, retry: false)) },
                                    onClick: {
                                        onSelect(d)
                                    })
                            }
                        }
                        if !gaveUp.isEmpty {
                            sectionTitle("Did not go out (\(gaveUp.count))")
                            ForEach(gaveUp, id: \.id) { d in
                                DeliveryCard(
                                    delivery: d, now: now, onRetry: { onRequest(QueueRequest(delivery: d, retry: true)) },
                                    onClick: {
                                        onSelect(d)
                                    })
                            }
                        }
                    }
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).msText(.titleSmall, color: MSColors.textSecondary).padding(.top, 8).padding(.bottom, 2)
    }
}

private struct AddEditRuleDialog: View {
    let rule: AccessRule?
    let activeTab: BridgeTab
    let links: [String: InterfaceStatus]
    let onDismiss: () -> Void
    let onSave: (AccessRule) -> Void

    @State private var name: String
    @State private var interfaceId: String
    @State private var forwardTo: String
    @State private var action: String
    @State private var enabled: Bool
    @State private var qosLevel: Int
    @State private var rateLimitPerMin: String
    @State private var rateLimitWindow: String
    @State private var priority: String
    @State private var filterKeyword: String
    @State private var filterNodeGroup: String
    @State private var filterSenderGroup: String
    @State private var triedToSave = false
    private let hiddenSettings: [String]

    init(
        rule: AccessRule?, activeTab: BridgeTab, links: [String: InterfaceStatus], onDismiss: @escaping () -> Void,
        onSave: @escaping (AccessRule) -> Void
    ) {
        self.rule = rule
        self.activeTab = activeTab
        self.links = links
        self.onDismiss = onDismiss
        self.onSave = onSave
        // Defaults based on the active tab
        let defaultInterface = activeTab == .inbound || activeTab == .crossBridge ? "iridium_0" : "mesh_0"
        let defaultForwardTo: String =
            switch activeTab {
            case .inbound: "mesh_0"
            case .crossBridge: "sms_0"
            default: "iridium_0"
            }
        _name = State(initialValue: rule?.name ?? "")
        _interfaceId = State(initialValue: rule?.interfaceId ?? defaultInterface)
        _forwardTo = State(initialValue: (rule?.forwardTo).flatMap { $0.isEmpty ? nil : $0 } ?? defaultForwardTo)
        _action = State(initialValue: rule?.action ?? "forward")
        _enabled = State(initialValue: rule?.enabled ?? true)
        _qosLevel = State(initialValue: rule?.qosLevel ?? 1)
        _rateLimitPerMin = State(initialValue: String(rule?.rateLimitPerMin ?? 0))
        _rateLimitWindow = State(initialValue: String(rule?.rateLimitWindow ?? 0))
        _priority = State(initialValue: String(rule?.priority ?? 10))
        _filterKeyword = State(initialValue: RuleWords.keyword(rule))
        _filterNodeGroup = State(initialValue: rule?.filterNodeGroup ?? "")
        _filterSenderGroup = State(initialValue: rule?.filterSenderGroup ?? "")
        hiddenSettings = RuleWords.hiddenSettings(rule)
    }

    // Android interface ids used by the gateway
    private func available(keep: String) -> [String] {
        let ids = RuleWords.linkChoices(
            links.values.sorted { $0.id < $1.id }.map { (id: $0.id, disabled: $0.state == .disabled) }, keep: keep)
        return ids.isEmpty ? ["mesh_0", "iridium_0", "sms_0"] : ids
    }

    private func digits(_ s: String) -> String { String(s.filter(\.isNumber).prefix(6)) }

    var body: some View {
        let isEgress = rule?.direction == "egress"
        let nameError = triedToSave && name.trimmingCharacters(in: .whitespaces).isEmpty
        let targetError = triedToSave && action == "forward" && (forwardTo.isEmpty || forwardTo == interfaceId)
        let priorityValue = Int(priority) ?? 10
        MSAlertDialog(
            rule == nil ? "New rule" : "Edit rule", onDismiss: onDismiss,
            content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        MSOutlinedTextField(text: $name, label: "Rule name", focusedBorder: MSColors.teal)
                        if nameError {
                            Text("Give the rule a name so you can find it later.").msText(.bodySmall, color: MSColors.red)
                        }
                        MSDropdownField(
                            label: isEgress ? "When a message leaves by" : "When a message arrives by", value: interfaceId,
                            options: available(keep: interfaceId), display: Words.channel
                        ) { interfaceId = $0 }
                        MSDropdownField(
                            label: "Then", value: action, options: ["forward", "drop", "log"], display: RuleWords.actionLabel,
                            supportingText: action == "forward"
                                ? "Pass it on to another link."
                                : (action == "drop"
                                    ? "Stop it. It is not passed on, whatever other rules say."
                                    : "Only count the match. Other rules still decide what happens.")
                        ) { action = $0 }
                        if action == "forward" { forwardFields(targetError) }
                        SettingRow("Rule is on") { MSSwitch(isOn: $enabled, label: "Rule is on") }
                        MSOutlinedTextField(text: $priority, label: "Urgency", focusedBorder: MSColors.teal, keyboard: .numberPad)
                            .onChange(of: priority) { _, v in if digits(v) != v { priority = digits(v) } }
                        Text("\(DeliveryWords.urgency(priorityValue)). Lower numbers go first and are checked first; 0 never expires.")
                            .msText(.bodySmall, color: MSColors.textMuted)
                        MSDropdownField(
                            label: "Delivery guarantee", value: String(qosLevel), options: ["0", "1", "2"],
                            display: { DeliveryWords.guarantee(Int($0) ?? 1) },
                            supportingText: "Try once gives up after one failed attempt. Keep trying retries until it goes out.",
                            onSelect: { qosLevel = Int($0) ?? 1 })
                        limitFields
                        Text("Only messages that match").msText(.titleSmall, color: MSColors.textSecondary).padding(.top, 8)
                        MSOutlinedTextField(text: $filterKeyword, label: "Contains the text (optional)", focusedBorder: MSColors.teal)
                        MSOutlinedTextField(
                            text: $filterNodeGroup, label: "From a node group (group id, optional)", focusedBorder: MSColors.teal)
                        MSOutlinedTextField(
                            text: $filterSenderGroup, label: "From a sender group (group id, optional)", focusedBorder: MSColors.teal)
                        if !hiddenSettings.isEmpty {
                            Text(
                                "This rule also has settings this screen does not show (\(hiddenSettings.joined(separator: ", "))). "
                                    + "Saving keeps them."
                            )
                            .msText(.bodySmall, color: MSColors.textMuted)
                        }
                    }
                }
                .frame(maxHeight: 460)
            },
            buttons: {
                MSTextButton("Cancel", color: MSColors.textSecondary, action: onDismiss)
                MSTextButton(rule == nil ? "Add" : "Save", color: MSColors.teal, action: save)
            })
    }

    @ViewBuilder private func forwardFields(_ targetError: Bool) -> some View {
        MSDropdownField(
            label: "Pass it on by", value: forwardTo, options: available(keep: forwardTo).filter { $0 != interfaceId },
            display: Words.channel,
            supportingText: targetError ? "Pick a different link from the one it arrives by." : nil, isError: targetError
        ) { forwardTo = $0 }
        // Satellite messages reach the Hub twice if this rule exists (MESHSAT-1276).
        if RuleWords.duplicatesTheHub(interfaceId, forwardTo) {
            Text(
                "The Hub already receives satellite messages straight from the provider. This rule sends a second copy, "
                    + "so anything the Hub does with them - alerts, TAK, webhooks - happens twice."
            )
            .msText(.bodySmall, color: MSColors.amber)
        }
    }

    @ViewBuilder private var limitFields: some View {
        Text("Limit").msText(.titleSmall, color: MSColors.textSecondary).padding(.top, 4)
        HStack(spacing: 8) {
            MSOutlinedTextField(text: $rateLimitPerMin, label: "At most (messages)", focusedBorder: MSColors.teal, keyboard: .numberPad)
                .onChange(of: rateLimitPerMin) { _, v in if digits(v) != v { rateLimitPerMin = digits(v) } }
            MSOutlinedTextField(text: $rateLimitWindow, label: "Every (seconds)", focusedBorder: MSColors.teal, keyboard: .numberPad)
                .onChange(of: rateLimitWindow) { _, v in if digits(v) != v { rateLimitWindow = digits(v) } }
        }
        Text(
            RuleWords.rateLimitText(Int(rateLimitPerMin) ?? 0, Int(rateLimitWindow) ?? 0).map {
                "\($0). Leave either box at 0 for no limit."
            }
                ?? "No limit. Fill in both boxes to set one, for example 5 messages every 60 seconds."
        )
        .msText(.bodySmall, color: MSColors.textMuted)
    }

    private func save() {
        triedToSave = true
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let badTarget = action == "forward" && (forwardTo.isEmpty || forwardTo == interfaceId)
        if trimmed.isEmpty || badTarget { return }
        // Start from the rule itself, so what the editor does not show (direction, message type
        // group, forwarding options, match count) survives a save.
        var r = rule ?? AccessRule(interfaceId: interfaceId, direction: "ingress", name: trimmed)
        r.interfaceId = interfaceId
        r.priority = Int(priority) ?? 10
        r.name = trimmed
        r.enabled = enabled
        r.action = action
        r.forwardTo = action == "forward" ? forwardTo : ""
        r.filters = RuleWords.mergeKeyword(rule?.filters, filterKeyword)
        let ng = filterNodeGroup.trimmingCharacters(in: .whitespaces)
        let sg = filterSenderGroup.trimmingCharacters(in: .whitespaces)
        r.filterNodeGroup = ng.isEmpty ? nil : ng
        r.filterSenderGroup = sg.isEmpty ? nil : sg
        r.qosLevel = qosLevel
        r.rateLimitPerMin = Int(rateLimitPerMin) ?? 0
        r.rateLimitWindow = Int(rateLimitWindow) ?? 0
        onSave(r)
    }
}
