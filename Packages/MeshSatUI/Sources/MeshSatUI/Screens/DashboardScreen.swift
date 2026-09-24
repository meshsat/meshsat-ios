// Mirrors ui/screens/DashboardScreen.kt and HomeLanes.kt: the HomeHeader (brand lockup at
// 26 dp, the night-mode moon, Arrange), the headline sentence with its follow-up line, one
// card of four TransportLanes, then the reorderable cards. This first cut carries the header,
// the sentence and the lanes card with static states; the lanes' state machine, the
// travelling dot, the checklist and the cards follow under MESHSAT-1321.
import SwiftUI

public struct DashboardScreen: View {
    @Binding var nightMode: Bool
    @Environment(Router.self) private var router
    @Environment(GatewayModel.self) private var model

    public init(nightMode: Binding<Bool>) { _nightMode = nightMode }

    private var meshLane: LaneState {
        switch model.meshState {
        case .connected: .working
        case .connecting, .scanning: .trying
        case .disconnected: .off
        }
    }

    private var satelliteLane: LaneState {
        switch model.modemState {
        case .connected: model.modemSignal > 0 ? .working : .trying
        case .connecting: .trying
        case .disconnected: .off
        }
    }

    private var headline: (String, String) {
        switch (model.meshState == .connected, model.modemState == .connected) {
        case (true, true): ("Mesh and satellite are up.", "Messages can go out both ways.")
        case (true, false): ("The mesh is up.", "The node's modem is not there yet.")
        default: ("Nothing can send yet.", "Connect your node in Setup.")
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MSSpace.list) {
                HomeHeader(nightMode: $nightMode)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline.0).msText(.headlineSmall)
                    Text(headline.1).msText(.bodyLarge, color: MSColors.textSecondary)
                }
                .padding(4)
                VStack(spacing: 0) {
                    TransportLane(
                        icon: MSIcon.transportSatellite, color: MSColors.iridium, name: "Satellite",
                        metric: "\(model.modemSignal)/5",
                        detail: model.modemState == .connected ? "Modem on the node." : "No modem. Connect your node.",
                        state: satelliteLane
                    ) {
                        router.navigate(.setupSection(.node))
                    }
                    MSDivider()
                    TransportLane(
                        icon: MSIcon.transportMesh, color: MSColors.mesh, name: "Mesh",
                        metric: "\(model.nodes.count) nodes",
                        detail: model.meshState == .connected ? "Connected to your node." : "\(model.meshStatusText).",
                        state: meshLane
                    ) {
                        router.navigate(.setupSection(.node))
                    }
                    MSDivider()
                    TransportLane(
                        icon: MSIcon.sms, color: MSColors.sms, name: "SMS",
                        metric: "0 today", detail: "Through the Messages app.", state: .off
                    ) {
                        router.navigate(.setupSection(.sms))
                    }
                    MSDivider()
                    TransportLane(
                        icon: MSIcon.cloud, color: MSColors.hub, name: "Hub",
                        metric: "", detail: "Not set up.", state: .off
                    ) {
                        router.navigate(.setupSection(.hub))
                    }
                }
                .msCard()
                SatelliteSkyCard()
                SosCard()
            }
            .padding(MSSpace.screen)
        }
        .background(MSColors.bg)
    }
}

struct HomeHeader: View {
    @Binding var nightMode: Bool
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
            Button {
            } label: {
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
    let metric: String
    let detail: String
    let state: LaneState
    let action: () -> Void

    public init(
        icon: Image, color: Color, name: String, metric: String, detail: String, state: LaneState,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.color = color
        self.name = name
        self.metric = metric
        self.detail = detail
        self.state = state
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
                        Text(metric).msText(.bodyMedium, mono: true, color: state == .working ? color : MSColors.textSecondary)
                    }
                    Text(detail).msText(.bodyMedium, color: MSColors.textSecondary).lineLimit(2)
                    LaneLine(color: color, state: state).frame(height: 10)
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

    public init(color: Color, state: LaneState) {
        self.color = color
        self.state = state
    }

    public var body: some View {
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
        }
    }
}
