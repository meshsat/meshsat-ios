// Mirrors ui/screens/DashboardScreen.kt and HomeLanes.kt: the HomeHeader (brand lockup at
// 26 dp, the night-mode moon, Arrange), the headline sentence with its follow-up line, one
// card of four TransportLanes, the Getting started checklist, then the cards in the order set
// with Arrange (HomeCards.swift).
import MeshSatEngine
import MeshSatMeshtastic
import MeshSatPlatform
import SwiftUI

public struct DashboardScreen: View {
    @Binding var nightMode: Bool
    @Environment(Router.self) private var router
    @Environment(GatewayModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    @State private var cards = HomeCardsModel()
    @State private var showReorder = false

    public init(nightMode: Binding<Bool>) { _nightMode = nightMode }

    // MARK: Lanes, as HomeLanes.kt derives them (one state and one sentence per way out)

    private static let highPassDeg = 40.0

    private var meshUp: Bool { model.meshState == .connected }
    private var reconnecting: Bool { !meshUp && model.meshPaired }
    private var bluetoothOffWithNode: Bool { !model.bluetoothOn && model.meshPaired }
    private var myNum: UInt32 { model.myInfo?.myNodeNum ?? 0 }
    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private var passLine: String? {
        let nowSec = nowMs / 1000
        if let overhead = model.passes.first(where: { $0.isActive && $0.peakElevDeg >= Self.highPassDeg && $0.los.value > Double(nowSec) })
        {
            _ = overhead
            return "A satellite is high overhead now."
        }
        if let next = model.passes.first(where: { $0.aos.value > Double(nowSec) && $0.peakElevDeg >= Self.highPassDeg }) {
            return "Next high pass \(Words.inTime(Int64(next.aos.value * 1000), nowMs: nowMs))."
        }
        return nil
    }

    private var satQueueLine: String {
        cards.iridiumQueueDepth > 0 ? "\(Words.count(cards.iridiumQueueDepth, "message")) waiting to go out. " : ""
    }

    private var satellite: (LaneState, String) {
        if bluetoothOffWithNode {
            return (.failed, (satQueueLine + "Bluetooth is off on this phone. Switch it on to reach the node's modem.").trimmed)
        }
        if model.modemLinkBroken {
            return (.failed, (satQueueLine + "The phone cannot reach the node's modem. Getting the link back.").trimmed)
        }
        switch model.modemState {
        case .connected: return (.working, (satQueueLine + (passLine ?? "Modem ready.")).trimmed)
        case .connecting:
            return model.modemSilent
                ? (.failed, "The node's modem does not answer. Check its power and cable.") : (.trying, "Checking the modem.")
        case .disconnected:
            if meshUp { return (.off, "This radio has no satellite modem.") }
            if reconnecting { return (.trying, (satQueueLine + "Reconnecting to your MeshSat node.").trimmed) }
            return (.off, "Connect a MeshSat node to use its satellite modem.")
        }
    }

    private var mesh: (LaneState, String) {
        if bluetoothOffWithNode { return (.failed, "Bluetooth is off on this phone. Switch it on to reach your node.") }
        if meshUp {
            let myName = model.nodes.first(where: { $0.nodeNum == myNum })?.longName ?? ""
            var line = myName.isEmpty ? "Connected" : "Connected to \(myName)"
            if model.bluetoothRssi != 0 { line += ", signal \(model.bluetoothRssi) dBm" }
            line += "."
            if let b = model.nodeBattery, b.nodeNum == myNum,
                let text = NodeBattery.describe(level: b.level, voltage: b.voltage, hoursLeft: b.hoursLeft, withVoltage: false)
            {
                line += b.level > 100 ? " \(text)." : " Battery \(text)."
            }
            return (.working, line)
        }
        switch model.meshState {
        case .connecting, .scanning: return (.trying, "Connecting to your node.")
        default: return reconnecting ? (.trying, "Reconnecting to your node.") : (.off, "Connect a MeshSat node or a Meshtastic radio.")
        }
    }

    private var sms: (LaneState, String) {
        // The Play edition of Android has no SMS lane; iOS hands texts to Messages.
        guard model.canSendSms else { return (.off, "This phone cannot send texts.") }
        if cards.smsQueueDepth > 0 { return (.working, "\(Words.count(cards.smsQueueDepth, "message")) waiting to go out.") }
        return (.working, "Through the Messages app.")
    }

    private var hub: (LaneState, String) {
        guard model.hubSetUp else { return (.off, "Scan the Hub's QR code to connect this phone.") }
        switch model.interfaces["hub_0"]?.state {
        case .online: return (.working, "Connected as \(settings.string(SettingsKey.hubBridgeId)).")
        case .connecting: return (.trying, "Connecting to the Hub.")
        case .error: return (.failed, "Cannot reach the Hub. It keeps trying by itself.")
        default: return (.trying, "Not connected. It keeps trying by itself.")
        }
    }

    private var headline: (String, String?) {
        var ways: [String] = []
        if satellite.0 == .working { ways.append("satellite") }
        if mesh.0 == .working { ways.append("mesh") }
        if sms.0 == .working { ways.append("SMS") }
        if hub.0 == .working { ways.append("the Hub") }
        let sentence = ways.isEmpty ? "Nothing can send yet." : "Messages can go out by \(Self.joinAnd(ways))."
        let waiting = cards.iridiumQueueDepth + cards.meshQueueDepth + cards.smsQueueDepth
        let next: String? =
            waiting > 0
            ? "\(Words.count(waiting, "message")) on the way." : (ways.isEmpty ? "Start with your MeshSat node, below." : nil)
        return (sentence, next)
    }

    private static func joinAnd(_ parts: [String]) -> String {
        switch parts.count {
        case 0: ""
        case 1: parts[0]
        case 2: "\(parts[0]) and \(parts[1])"
        default: parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MSSpace.list) {
                HomeHeader(nightMode: $nightMode) { showReorder = true }
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline.0).msText(.headlineSmall)
                    if let next = headline.1 { Text(next).msText(.bodyLarge, color: MSColors.textSecondary) }
                }
                .padding(.horizontal, 4)
                VStack(spacing: 0) {
                    let sat = satellite
                    TransportLane(
                        icon: MSIcon.transportSatellite, color: MSColors.iridium, name: "Satellite",
                        metric: model.modemState == .connected ? "\(model.modemSignal)/5" : nil,
                        detail: sat.1, state: sat.0, inFlight: cards.iridiumQueueDepth > 0
                    ) {
                        router.navigate(model.modemState == .connected ? .passes : .setupSection(.satellite))
                    }
                    MSDivider()
                    let meshLane = mesh
                    let others = model.nodes.filter { $0.nodeNum != myNum }.count
                    TransportLane(
                        icon: MSIcon.transportMesh, color: MSColors.mesh, name: "Mesh",
                        metric: meshUp ? Words.count(others, "node") : nil,
                        detail: meshLane.1, state: meshLane.0, inFlight: cards.meshQueueDepth > 0
                    ) {
                        if meshUp { router.selectTab(.people) } else { router.navigate(.setupSection(.node)) }
                    }
                    MSDivider()
                    let smsLane = sms
                    TransportLane(
                        icon: MSIcon.sms, color: MSColors.sms, name: "SMS",
                        metric: smsLane.0 == .working ? "\(cards.smsToday) today" : nil,
                        detail: smsLane.1, state: smsLane.0, inFlight: cards.smsQueueDepth > 0
                    ) {
                        router.navigate(.setupSection(.sms))
                    }
                    MSDivider()
                    let hubLane = hub
                    TransportLane(
                        icon: MSIcon.cloud, color: MSColors.hub, name: "Hub",
                        metric: nil, detail: hubLane.1, state: hubLane.0, inFlight: false
                    ) {
                        router.navigate(.setupSection(.hub))
                    }
                }
                .msCard()
                SetupChecklistCard()
                // The cards below follow the order set with Arrange (MESHSAT-401).
                ForEach(HomeCards.order(settings.string(SettingsKey.dashboardOrder)), id: \.self) { card in
                    switch card {
                    case "mailbox":
                        // On request only: each check is billed (MESHSAT-400).
                        if model.modemState == .connected { DashboardCard("Satellite mailbox") { CheckMailboxButton() } }
                    case "signals":
                        SatelliteSkyCard()
                        if !cards.meshHistory.isEmpty {
                            SignalChart(
                                title: "Mesh signal strength, last 6 hours", records: cards.meshHistory, maxValue: -30, minValue: -100,
                                color: MSColors.mesh, formatValue: { "\(Int($0)) dBm" })
                        }
                        if !cards.cellularHistory.isEmpty {
                            SignalChart(
                                title: "Mobile signal, last 6 hours", records: cards.cellularHistory, maxValue: -50, minValue: -120,
                                color: MSColors.cellular, formatValue: { "\(Int($0)) dBm" })
                        }
                    case "sos": SosCard()
                    case "location": LocationCard(fix: model.phoneFix, nowMs: cards.nowMs)
                    case "queue": QueueCard(cards: cards)
                    case "activity":
                        Text("Recent messages").msText(.titleMedium).padding(.top, 4)
                        if cards.recentMessages.isEmpty {
                            Text("No messages yet.").msText(.bodyMedium, color: MSColors.textMuted).padding(.vertical, 8)
                        } else {
                            ForEach(cards.recentMessages, id: \.id) { ActivityLogEntry(msg: $0) }
                        }
                    default: EmptyView()
                    }
                }
            }
            .padding(MSSpace.screen)
        }
        .background(MSColors.bg)
        .task { await cards.run(db: model.gateway.db) }
        .overlay {
            if showReorder {
                ReorderDialog(
                    cards: HomeCards.order(settings.string(SettingsKey.dashboardOrder)), onDismiss: { showReorder = false },
                    onConfirm: { order in
                        settings.set(SettingsKey.dashboardOrder, order.joined(separator: ","))
                        showReorder = false
                    })
            }
        }
    }
}

struct HomeHeader: View {
    @Binding var nightMode: Bool
    var onArrange: () -> Void = {}
    var body: some View {
        HStack(spacing: 0) {
            BrandLockup().frame(height: 26)
            Spacer(minLength: 0)
            Button {
                nightMode.toggle()
            } label: {
                MSIcon.nightsStay.resizable().scaledToFit().frame(width: 24, height: 24)
                    .foregroundStyle(MSColors.textSecondary)
                    .frame(width: MSSpace.touch, height: MSSpace.touch)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Night mode")
            Button(action: onArrange) {
                MSIcon.swapVert.resizable().scaledToFit().frame(width: 24, height: 24)
                    .foregroundStyle(MSColors.textSecondary)
                    .frame(width: MSSpace.touch, height: MSSpace.touch)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Arrange")
        }
        .padding(.leading, 4)
    }
}

/// The "MeshSat" wordmark (brand_lockup.png in Android, drawn at 26 dp high, leading-aligned).
struct BrandLockup: View {
    var body: some View {
        #if canImport(UIKit)
        if UIImage(named: "brand_lockup", in: .module, with: nil) != nil {
            Image("brand_lockup", bundle: .module).resizable().scaledToFit()
        } else {
            wordmark
        }
        #else
        wordmark
        #endif
    }

    private var wordmark: some View {
        HStack(spacing: 0) {
            Text("Mesh").msText(.headlineMedium, color: MSColors.offWhite)
            Text("Sat").msText(.headlineMedium, color: MSColors.signalOrange)
        }
    }
}

/// Mirrors TransportLane in ui/components/Lane.kt: a 76 dp row with a 24 dp icon in the transport
/// colour, the name in titleMedium with the metric in mono, a two-line detail, the LaneLine and a
/// muted chevron. LaneLine: solid when working, dashed while trying, dotted grey when off, dotted
/// red when failed; the travelling orange dot comes with the delivery queue.
public enum LaneState: Sendable, Equatable {
    case working, trying, off, failed
}

public struct TransportLane: View {
    let icon: Image
    let color: Color
    let name: String
    let metric: String?
    let detail: String
    let state: LaneState
    let inFlight: Bool
    let action: () -> Void

    public init(
        icon: Image, color: Color, name: String, metric: String?, detail: String, state: LaneState,
        inFlight: Bool = false, action: @escaping () -> Void
    ) {
        self.icon = icon
        self.color = color
        self.name = name
        self.metric = metric
        self.detail = detail
        self.state = state
        self.inFlight = inFlight
        self.action = action
    }

    private var iconTint: Color {
        switch state {
        case .working: color
        case .trying: color.opacity(0.75)
        case .off: MSColors.textMuted
        case .failed: MSColors.red
        }
    }

    public var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 16) {
                icon.resizable().scaledToFit().frame(width: 24, height: 24).foregroundStyle(iconTint)
                    .padding(.top, 14)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(name).msText(.titleMedium)
                        Spacer(minLength: 8)
                        if let metric {
                            Text(metric).msText(.bodyMedium, mono: true, color: state == .working ? color : MSColors.textSecondary)
                        }
                    }
                    Text(detail).msText(.bodyMedium, color: MSColors.textSecondary).lineLimit(2)
                    LaneLine(color: color, state: state, inFlight: inFlight).frame(height: 10)
                }
                Image(systemName: "chevron.right").foregroundStyle(MSColors.textMuted).font(.system(size: 17))
                    .padding(.top, 18)
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.top, 12).padding(.bottom, 12)
            .frame(minHeight: MSSpace.lane)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(detail)")
    }
}

public struct LaneLine: View {
    let color: Color
    let state: LaneState
    let inFlight: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(color: Color, state: LaneState, inFlight: Bool = false) {
        self.color = color
        self.state = state
        self.inFlight = inFlight
    }

    public var body: some View {
        // Lane.kt: a message on its way is an orange dot travelling along the line every 2.4 s;
        // with Reduce Motion the dot waits at 70 percent instead.
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !inFlight || reduceMotion)) { timeline in
            let travel =
                inFlight && !reduceMotion ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4 : 0.7
            line(travel: travel)
        }
        .accessibilityLabel(described)
    }

    private var described: String {
        let base =
            switch state {
            case .working: "working"
            case .trying: "trying"
            case .off: "not available"
            case .failed: "not working"
            }
        return base + (inFlight ? ", a message is on its way" : "")
    }

    private func line(travel: Double) -> some View {
        Canvas { context, size in
            let y = size.height / 2
            switch state {
            case .working:
                var path = Path()
                path.move(to: CGPoint(x: 1, y: y))
                path.addLine(to: CGPoint(x: size.width - 1, y: y))
                context.stroke(path, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            case .trying:
                var path = Path()
                path.move(to: CGPoint(x: 1, y: y))
                path.addLine(to: CGPoint(x: size.width - 1, y: y))
                context.stroke(path, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [10, 7]))
            case .off, .failed:
                let dot = state == .off ? MSColors.textMuted : MSColors.red
                var x: CGFloat = 2
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2)), with: .color(dot))
                    x += 9
                }
            }
            if inFlight {
                let r: CGFloat = 4.5
                let cx = r + (size.width - 2 * r) * travel
                context.fill(Path(ellipseIn: CGRect(x: cx - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(MSColors.signalOrange))
            }
        }
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
