// Mirrors ui/components/NodeLinkBanner.kt (MESHSAT-615): a line across every screen while the
// phone cannot reach its node, saying which link is down and since when, gone the moment the link
// is back. Shown only once a node has been paired; an active SOS outranks it (one banner at a
// time). "Since" is this phone's own timestamp of the moment the link went, not the interface
// manager's lastOnline, which is the moment a link came up.
import SwiftUI
import UIKit

public struct NodeLinkBanner: View {
    @Environment(GatewayModel.self) private var model
    let onOpen: () -> Void
    @State private var downSince: Date?
    @State private var now = Date()
    private let ticker = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    public init(onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
    }

    private var down: Bool {
        let meshUp = model.meshState == .connected
        return !meshUp || model.modemLinkBroken
    }

    public var body: some View {
        let shown = model.sosRun?.active != true && model.meshPaired && down
        // A VStack, not a Group: modifiers on an empty Group never run, so onChange would never
        // record downSince and the banner would never appear (seen on the phone, 25 Sep 2026).
        VStack(spacing: 0) {
            if shown, let since = downSince {
                let minutes = max(0, Int(now.timeIntervalSince(since) / 60))
                Button {
                    if !model.bluetoothOn {
                        // Android asks the system to enable Bluetooth; iOS has no such dialog,
                        // so the Settings app opens instead.
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } else {
                        onOpen()
                    }
                } label: {
                    Text(
                        Self.text(
                            bluetoothOff: !model.bluetoothOn, meshUp: model.meshState == .connected,
                            since: Self.clock.string(from: since), minutes: minutes)
                    )
                    .msText(.bodyMedium, color: MSColors.spaceBlack)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(MSColors.amber)
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: down, initial: true) { _, isDown in
            downSince = isDown ? Date() : nil
        }
        .onReceive(ticker) { now = $0 }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// nodeLinkBannerText in NodeLinkBanner.kt, word for word.
    static func text(bluetoothOff: Bool, meshUp: Bool, since: String?, minutes: Int) -> String {
        let when = (since.map { " since \($0)" } ?? "") + (minutes >= 1 ? " (\(minutes) min)" : "")
        if bluetoothOff {
            return "Bluetooth is off\(when), so the phone cannot reach your MeshSat node. "
                + "Nothing goes out by mesh or satellite. Tap to switch it on."
        }
        let what = meshUp ? "the node's modem" : "your MeshSat node"
        return "Cannot reach \(what)\(when). Nothing goes out by mesh or satellite. Tap to see."
    }
}
