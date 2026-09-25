// Mirrors StatusStrip in ui/MeshSatUI.kt: a 36 dp strip on Surface with 12 dp side padding and
// 14 dp gaps, 16 dp icons for satellite ("n/5"), mesh (node count), SMS, Hub and GPS, each in
// its transport colour when working, amber while trying, muted when off and red when failed,
// and "HH:mm UTC" in Plex Mono 12 sp TextSecondary on the right, ticking every second.
import SwiftUI

public enum StripState: Sendable, Equatable {
    case working, trying, off, failed

    var colorFallback: Color {
        switch self {
        case .working: MSColors.green
        case .trying: MSColors.amber
        case .off: MSColors.textMuted
        case .failed: MSColors.red
        }
    }
}

public struct StatusStripModel: Sendable, Equatable {
    public var satellite: StripState = .off
    public var satelliteBars: Int = 0
    public var mesh: StripState = .off
    public var meshNodes: Int = 0
    public var sms: StripState = .off
    public var hub: StripState = .off
    public var gps: StripState = .off
    public init() {}
}

public struct StatusStrip: View {
    let model: StatusStripModel

    public init(model: StatusStripModel) { self.model = model }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 14) {
                item(
                    MSIcon.transportSatellite, tint(model.satellite, MSColors.iridium),
                    text: model.satellite == .off ? nil : "\(model.satelliteBars)/5")
                item(MSIcon.transportMesh, tint(model.mesh, MSColors.mesh), text: model.mesh == .working ? "\(model.meshNodes)" : nil)
                item(MSIcon.sms, tint(model.sms, MSColors.sms), text: nil)
                item(MSIcon.cloud, tint(model.hub, MSColors.hub), text: nil)
                item(MSIcon.myLocation, tint(model.gps, MSColors.green), text: nil)
                Spacer(minLength: 0)
                Text("\(Self.clock.string(from: context.date)) UTC")
                    .msText(.labelMedium, mono: true, color: MSColors.textSecondary)
            }
            .padding(.horizontal, 12)
            .frame(height: MSSpace.statusStrip)
            .frame(maxWidth: .infinity)
            .background(MSColors.surface)
        }
    }

    private func tint(_ state: StripState, _ working: Color) -> Color {
        state == .working ? working : state.colorFallback
    }

    @ViewBuilder
    private func item(_ icon: Image, _ color: Color, text: String?) -> some View {
        HStack(spacing: 4) {
            icon.resizable().scaledToFit().frame(width: 16, height: 16).foregroundStyle(color)
            if let text {
                Text(text).msText(.labelMedium, mono: true, color: color)
            }
        }
    }
}
