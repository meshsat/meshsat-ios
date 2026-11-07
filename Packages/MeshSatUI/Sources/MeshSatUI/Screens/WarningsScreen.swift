// Mirrors ui/screens/WarningsScreen.kt (MESHSAT-1734, iOS MESHSAT-1819): a public warning a kit
// relayed, while the app is open (WarningOverlay: the whole screen, over whatever was there, until
// Dismiss; red for a warning, amber for a test), and Setup > Safety > Warnings, every relayed
// warning this phone heard, newest first. Dismissing marks the warning acknowledged; it still
// stands in the list until its cancel or a newer one.
import MeshSatEngine
import MeshSatPlatform
import SwiftUI

private func clock(_ ms: Int64) -> String {
    let f = DateFormatter()
    f.locale = Locale.current
    f.dateFormat = "d MMM HH:mm"
    return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
}

struct WarningOverlay: View {
    @Environment(GatewayModel.self) private var model
    let onOpen: () -> Void
    @State private var warning: WarningRecord?

    var body: some View {
        ZStack {
            // Always there, so the subscription below runs while no warning shows (modifiers on an
            // empty container never run); it takes no tap.
            Color.clear.allowsHitTesting(false)
            if let w = warning {
                let color = w.test ? MSColors.amber : MSColors.red
                MSColors.spaceBlack.opacity(0.94).ignoresSafeArea()
                    // Nothing under it takes a tap while it shows: the scrim takes them all, quietly.
                    .contentShape(Rectangle())
                    .onTapGesture {}
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(WarningWords.title(w)).msText(.headlineSmall, color: color)
                        if w.test { Text("A test. No action is needed.").msText(.bodyMedium, color: MSColors.amber) }
                        if !w.text.isEmpty { Text(w.text).msText(.bodyLarge) }
                        if !w.label.isEmpty { Text(w.label).msText(.bodySmall, color: MSColors.textSecondary) }
                        Text(WarningWords.relayLine(w)).msText(.bodySmall, color: MSColors.textMuted)
                        Text("Heard \(clock(w.receivedAt))").msText(.bodySmall, color: MSColors.textMuted)
                        HStack(spacing: 8) {
                            MSFilledButton("Dismiss", container: color, labelColor: MSColors.spaceBlack, fullWidth: false) {
                                acknowledge(w)
                            }
                            MSOutlinedButton("All warnings") {
                                acknowledge(w)
                                onOpen()
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MSColors.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(color, lineWidth: 3))
                    .padding(16)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Warning")
            }
        }
        .task {
            for await w in model.gateway.warningParts.banner.subscribe() { warning = w }
        }
    }

    private func acknowledge(_ w: WarningRecord) {
        warning = nil
        Task { await model.gateway.acknowledgeWarning(w.id) }
    }
}

public struct WarningsScreen: View {
    @Environment(GatewayModel.self) private var model
    @State private var rows: [WarningRecord] = []

    public init() {}

    public var body: some View {
        ScrollView {
            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No warning heard yet.").msText(.bodyLarge)
                    Text(
                        "A MeshSat kit in range puts the public warnings for its area on the mesh. This phone sounds "
                            + "the alarm for each one and keeps it here; a test warning says so and uses the normal sound."
                    )
                    .msText(.bodyMedium, color: MSColors.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(rows) { WarningRow(w: $0) }
                }
                .padding(16)
            }
        }
        .background(MSColors.bg)
        .task {
            for await _ in model.gateway.warningParts.changes.subscribe() { rows = await model.gateway.recentWarnings() }
        }
    }
}

private struct WarningRow: View {
    let w: WarningRecord

    private var stateColor: Color {
        if w.isCancel { return MSColors.green }
        if w.cancelledAt != 0 || w.replacedAt != 0 { return MSColors.textMuted }
        return w.test ? MSColors.amber : MSColors.red
    }

    var body: some View {
        let alarm = w.standing && !w.test
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(WarningWords.title(w)).msText(.titleMedium, color: alarm ? MSColors.red : MSColors.textPrimary)
                Spacer(minLength: 8)
                Text(WarningWords.state(w, time: clock)).msText(.bodySmall, color: stateColor)
            }
            if !w.text.isEmpty { Text(w.text).msText(.bodyMedium) }
            if !w.label.isEmpty { Text(w.label).msText(.bodySmall, color: MSColors.textSecondary) }
            Text(WarningWords.heard(w, time: clock)).msText(.bodySmall, color: MSColors.textMuted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MSColors.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(alarm ? MSColors.red : MSColors.border, lineWidth: 1))
    }
}
