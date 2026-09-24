// Mirrors ui/screens/AuditScreen.kt: a signed record of what the gateway did, in the phone's
// own time zone, checked against its hash chain, and saved as a text file (Android: the
// document picker; here the share sheet).
import MeshSatEngine
import MeshSatStore
import SwiftUI

/// How many entries the chain check covers by default.
private let verifyWindow = 1000
/// The most entries "Save a copy" writes out.
private let exportLimit = 100_000

/// A moment as local clock time: "14:04:09" today, "18 Sep 14:04:09" before.
func localStamp(_ epochMs: Int64, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> String {
    let at = Date(timeIntervalSince1970: Double(epochMs) / 1000)
    let today = Calendar.current.isDate(at, inSameDayAs: Date(timeIntervalSince1970: Double(nowMs) / 1000))
    let f = DateFormatter()
    f.locale = Locale.current
    f.dateFormat = today ? "HH:mm:ss" : "d MMM HH:mm:ss"
    return f.string(from: at)
}

enum AuditWords {
    static func eventColor(_ eventType: String) -> Color {
        let t = eventType.lowercased()
        if t.contains("forward") || t.contains("deliver") { return MSColors.green }
        if t.contains("deny") || t.contains("reject") { return MSColors.red }
        if t.contains("bind") || t.contains("connect") { return MSColors.blue }
        return MSColors.textMuted
    }

    /// An audit event type (the Bridge's names, e.g. "dispatch", "oob_reject") in plain words.
    static func eventLabel(_ eventType: String) -> String {
        let t = eventType.trimmingCharacters(in: .whitespaces)
        let known: String? =
            switch t.lowercased() {
            case "dispatch": "Queued"
            case "deliver", "delivered": "Sent"
            case "forward": "Passed on"
            case "drop": "Stopped"
            case "deny", "denied": "Blocked"
            case "reject", "rejected": "Refused"
            case "failover": "Switched to a backup link"
            case "delivery_preempt": "Held back for a more urgent message"
            case "sos_activated": "SOS started"
            case "oob_command": "Remote command"
            case "oob_reject": "Remote command refused"
            case "oob_address_learn": "Learned a reply address"
            case "oob_key_exported": "Remote control key exported"
            case "connect", "connected": "Connected"
            case "disconnect", "disconnected": "Disconnected"
            default: nil
            }
        if let known { return known }
        let words = t.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ").replacingOccurrences(
            of: ":", with: " "
        )
        .trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? "Event" : words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Which way a message went, from the direction field.
    static func directionLabel(_ direction: String) -> String? {
        switch direction.lowercased() {
        case "inbound", "in", "ingress", "rx": "received"
        case "outbound", "out", "egress", "tx": "sent"
        default: nil
        }
    }

    /// The whole log as tab-separated text, oldest first, with the hashes that make it checkable.
    static func exportText(newestFirst: [AuditLogEntry], signerId: String?) -> String {
        var s = "MeshSat audit log\nSaved: \(ISO8601DateFormatter().string(from: Date()))\n"
        if let signerId { s += "Signing key: \(signerId)\n" }
        s += "Entries: \(newestFirst.count)\n\n"
        s += "id\ttimestamp_utc\tinterface\tdirection\tevent\tdelivery_id\trule_id\tdetail\tprev_hash\thash\n"
        for e in newestFirst.reversed() {
            let detail = e.detail.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
            s +=
                [
                    "\(e.id ?? 0)", e.timestamp, e.interfaceId ?? "", e.direction ?? "", e.eventType, e.deliveryId.map { "\($0)" } ?? "",
                    e.ruleId.map { "\($0)" } ?? "", detail, e.prevHash, e.hash,
                ].joined(separator: "\t") + "\n"
        }
        return s
    }
}

/// The outcome of "Check the log".
private struct AuditCheck {
    let valid: Int
    let brokenAt: Int
    let brokenEntryId: Int64?
}

public struct AuditScreen: View {
    @Environment(GatewayModel.self) private var model
    @State private var events: [AuditLogEntry] = []
    @State private var totalCount = 0
    @State private var limit = 100
    @State private var filterInterface: String?
    @State private var check: AuditCheck?
    @State private var verifying = false
    @State private var ruleNames: [Int64: String] = [:]
    @State private var exportText: String?

    public init() {}

    private var dao: AuditLogDao { model.gateway.db.auditLog }
    private var signing: SigningService? { model.gateway.signingService }

    /// The links the filter offers: the ones the gateway has, or the three every phone has.
    private var interfaceFilters: [String] {
        let ids = model.interfaces.keys.sorted()
        return ids.isEmpty ? ["mesh_0", "iridium_0", "sms_0"] : ids
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Words.count(totalCount, "entry", "entries")).msText(.bodyMedium, color: MSColors.textSecondary)
                Spacer(minLength: 0)
                if let signing {
                    Button {
                        UIPasteboard.general.string = signing.signerId
                        model.showToast("Signing key copied")
                    } label: {
                        HStack(spacing: 0) {
                            Text("Signing key ").msText(.bodySmall, color: MSColors.textMuted)
                            Text(String(signing.signerId.prefix(12)) + "\u{2026}").msText(.bodySmall, mono: true)
                        }
                        .padding(.horizontal, 4)
                        .frame(minHeight: MSSpace.touch)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer().frame(height: 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    MSFilterChip("All links", selected: filterInterface == nil) {
                        filterInterface = nil
                        limit = 100
                    }
                    ForEach(interfaceFilters, id: \.self) { iface in
                        MSFilterChip("\u{25CF} " + Words.channel(iface), selected: filterInterface == iface) {
                            filterInterface = filterInterface == iface ? nil : iface
                            limit = 100
                        }
                    }
                }
            }
            Spacer().frame(height: 8)
            HStack(spacing: 8) {
                if signing != nil {
                    MSOutlinedButton(verifying ? "Checking\u{2026}" : "Check the log", enabled: !verifying) { Task { await runCheck() } }
                        .fixedSize()
                }
                MSOutlinedButton("Save a copy", enabled: totalCount > 0) { Task { await prepareExport() } }.fixedSize()
                if let exportText {
                    ShareLink(item: exportText, preview: SharePreview("MeshSat audit log")) {
                        Text("Share").msText(.bodySmall, color: MSColors.teal).padding(.horizontal, 12).frame(minHeight: 40)
                    }
                }
                Spacer(minLength: 0)
            }
            if let c = check { checkText(c).padding(.top, 8) }
            Spacer().frame(height: 8)
            if events.isEmpty {
                Text(filterInterface == nil ? "Nothing in the audit log yet." : "Nothing in the audit log for this link.")
                    .msText(.bodyMedium, color: MSColors.textMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(events, id: \.id) { AuditEventCard(event: $0, ruleNames: ruleNames) }
                        if events.count >= limit {
                            MSFilledButton("Show older entries", container: MSColors.surface, labelColor: MSColors.textPrimary) {
                                limit += 100
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .padding(MSSpace.screen)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MSColors.bg)
        .task(id: "\(limit)|\(filterInterface ?? "")") { await load() }
        .task {
            do {
                for try await rules in model.gateway.db.accessRules.getAll() {
                    ruleNames = Dictionary(rules.compactMap { r in r.id.map { ($0, r.name) } }, uniquingKeysWith: { a, _ in a })
                }
            } catch {}
        }
    }

    private func load() async {
        if let iface = filterInterface {
            events = (try? await dao.getByInterface(iface, limit: limit)) ?? []
        } else {
            events = (try? await dao.getRecent(limit: limit)) ?? []
        }
        totalCount = (try? await dao.count()) ?? 0
    }

    private func runCheck() async {
        guard let signing else { return }
        verifying = true
        let (valid, brokenAt) = await signing.verifyChain(limit: verifyWindow)
        var brokenId: Int64?
        if brokenAt >= 0, let recent = try? await dao.getRecent(limit: verifyWindow) {
            let ordered = Array(recent.reversed())
            if brokenAt < ordered.count { brokenId = ordered[brokenAt].id }
        }
        check = AuditCheck(valid: valid, brokenAt: brokenAt, brokenEntryId: brokenId)
        verifying = false
    }

    private func prepareExport() async {
        let rows = (try? await dao.getRecent(limit: exportLimit)) ?? []
        exportText = AuditWords.exportText(newestFirst: rows, signerId: signing?.signerId)
        model.showToast("Copy ready: tap Share")
    }

    @ViewBuilder private func checkText(_ c: AuditCheck) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if c.brokenAt >= 0 {
                Text("The log was changed after it was written.").msText(.bodyMedium, color: MSColors.red)
                Text("Save a copy and keep it, then contact your MeshSat admin.").msText(.bodyMedium, color: MSColors.textSecondary)
                Text(
                    c.brokenEntryId.map { "The first changed entry is number \($0)." }
                        ?? "The first changed entry is \(c.brokenAt + 1) from the oldest of the last \(verifyWindow)."
                )
                .msText(.bodySmall, color: MSColors.textMuted)
            } else if c.valid == 0 {
                Text("Nothing to check yet.").msText(.bodyMedium, color: MSColors.textSecondary)
            } else {
                Text("The last \(Words.count(c.valid, "entry", "entries")) are as they were written.").msText(
                    .bodyMedium, color: MSColors.green)
            }
        }
    }
}

private struct AuditEventCard: View {
    let event: AuditLogEntry
    let ruleNames: [Int64: String]

    var body: some View {
        // Stored in UTC; shown in the phone's time zone like every other screen.
        let time = RuleWords.parseUtcStamp(event.timestamp).map { localStamp($0) } ?? event.timestamp
        let link = event.interfaceId.flatMap { $0.isEmpty ? nil : Words.channel($0) }
        let way = event.direction.flatMap { AuditWords.directionLabel($0) }
        let whereText = [link, way].compactMap { $0 }.joined(separator: ", ")
        let refs = [
            event.deliveryId.map { "Message #\($0)" },
            event.ruleId.map { id in ruleNames[id].flatMap { $0.isEmpty ? nil : "Rule \u{201C}\($0)\u{201D}" } ?? "Rule #\(id)" },
        ].compactMap { $0 }.joined(separator: " \u{00B7} ")
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(AuditWords.eventColor(event.eventType)).frame(width: 10, height: 10).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(AuditWords.eventLabel(event.eventType)).msText(.titleSmall).lineLimit(1).frame(
                        maxWidth: .infinity, alignment: .leading)
                    Text(time).msText(.bodySmall, mono: true, color: MSColors.textMuted)
                }
                if !whereText.isEmpty {
                    Text(whereText).msText(.bodySmall, color: event.interfaceId.map { Words.channelColor($0) } ?? MSColors.textSecondary)
                }
                if !event.detail.isEmpty { Text(event.detail).msText(.bodySmall, color: MSColors.textSecondary).lineLimit(2) }
                if !refs.isEmpty { Text(refs).msText(.bodySmall, color: MSColors.textMuted) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .msCard()
    }
}
