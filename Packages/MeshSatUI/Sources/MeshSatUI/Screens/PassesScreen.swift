// Mirrors ui/screens/PassPredictorScreen.kt (MESHSAT-1300): laid out for a small phone. What
// matters first, the pass overhead or the next one, then the chart, then the settings that
// change it, and the bookkeeping last.
import MeshSatSatellite
import SwiftUI

public struct PassesScreen: View {
    @Environment(GatewayModel.self) private var model
    @State private var vm = PassesModel()

    public init() {}

    public var body: some View {
        @Bindable var vm = vm
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let active = vm.activePass {
                    PassBanner(label: "Overhead now", pass: active, accent: MSColors.signalExcellent, subtitle: "A message can go out now.")
                } else if let next = vm.nextPass {
                    PassBanner(
                        label: "Next pass", pass: next, accent: MSColors.iridium, showCountdown: true, countdownText: vm.countdownText)
                }
                VStack(alignment: .leading, spacing: 8) {
                    SegmentedChoice(options: PassesModel.windowOptions, selected: $vm.windowHours) { "\($0) h" }
                    chartCard
                }
                surroundings
                if !vm.loading, !vm.passes.isEmpty {
                    Button {
                        vm.expandedPassList.toggle()
                    } label: {
                        HStack {
                            Text("Every pass in the window (\(vm.passes.count))").msText(.bodyMedium)
                            Spacer(minLength: 0)
                            Image(systemName: vm.expandedPassList ? "chevron.up" : "chevron.down")
                                .font(.system(size: 20))
                                .foregroundStyle(MSColors.textMuted)
                                .accessibilityLabel(vm.expandedPassList ? "Hide the passes" : "Show the passes")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .msCard()
                }
                if vm.expandedPassList, !vm.loading {
                    ForEach(vm.passes, id: \.self) { PassRow(pass: $0, nowSec: vm.nowSec) }
                }
                bookkeeping
            }
            .padding(.horizontal, MSSpace.passesScreen)
            .padding(.vertical, MSSpace.passesScreen)
        }
        .background(MSColors.bg)
        .task { await vm.run(gateway: model.gateway) }
    }

    @ViewBuilder private var chartCard: some View {
        Group {
            if vm.loading {
                HStack(spacing: 8) {
                    MSCircularProgress(size: 20, stroke: 2, color: MSColors.iridium)
                    Text("Working out the passes").msText(.bodySmall, color: MSColors.textMuted)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 220)
            } else if vm.passes.isEmpty {
                let text: String =
                    if let e = vm.errorMsg {
                        e
                    } else if !vm.hasLocation {
                        "No position yet. Allow location, or wait for a fix."
                    } else {
                        "No passes above \(vm.minElevDeg)\u{00B0} in this window."
                    }
                Text(text)
                    .msText(.bodySmall, color: vm.errorMsg != nil ? MSColors.red : MSColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            } else {
                SkyChart(
                    passes: vm.passes, signals: vm.skySignals, sessions: vm.skySessions, startSec: vm.startSec, endSec: vm.endSec,
                    nowSec: vm.nowSec, compact: false)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .msCard()
    }

    private var surroundings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your surroundings").msText(.labelMedium, color: MSColors.textSecondary)
            HStack(spacing: 6) {
                ForEach(PassesModel.elevPresets) { p in
                    let on = vm.minElevDeg == p.value
                    Button {
                        vm.minElevDeg = p.value
                    } label: {
                        VStack(spacing: 0) {
                            Text("\(p.value)\u{00B0}").msText(
                                .titleSmall, mono: true, color: on ? MSColors.iridium : MSColors.textSecondary)
                            Text(p.label).msText(.labelSmall, color: on ? MSColors.iridium : MSColors.textMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            on ? MSColors.iridium.opacity(0.18) : MSColors.surface, in: RoundedRectangle(cornerRadius: MSRadius.card)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: MSRadius.card).stroke(
                                on ? MSColors.iridium.opacity(0.5) : MSColors.border, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            let chosen = PassesModel.elevPresets.first { $0.value == vm.minElevDeg }
            Text("\(chosen?.desc ?? "Custom"): counts the passes that climb above \(vm.minElevDeg)\u{00B0}.")
                .msText(.bodySmall, color: MSColors.textMuted)
        }
    }

    // The bookkeeping, quiet and last
    private var bookkeeping: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(vm.hasLocation ? MSColors.signalExcellent : MSColors.red).frame(width: 6, height: 6)
                Text(
                    vm.hasLocation
                        ? "Position from Location Services, \(String(format: "%.4f, %.4f", vm.lat, vm.lon))"
                        : "No position: allow location for predictions"
                )
                .msText(.labelSmall, color: vm.hasLocation ? MSColors.textMuted : MSColors.red)
            }
            HStack {
                Text("Orbit data: \(vm.tleSourceText)").msText(.labelSmall, color: MSColors.textMuted)
                Spacer(minLength: 0)
                MSTextButton(vm.refreshing ? "Updating" : "Update", color: MSColors.iridium) {
                    guard !vm.refreshing else { return }
                    Task {
                        if await !vm.refresh() {
                            model.showToast("Could not download new orbit data; predicting with the data on the phone.")
                        }
                    }
                }
                .disabled(vm.refreshing)
            }
        }
        .padding(.top, 4)
    }
}

/// A row of equal choices, the chosen one filled: sized to the screen, never cut off.
struct SegmentedChoice<T: Hashable>: View {
    let options: [T]
    @Binding var selected: T
    let label: (T) -> String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { o in
                let on = o == selected
                Button {
                    selected = o
                } label: {
                    Text(label(o))
                        .msText(.labelLarge, mono: true, color: on ? MSColors.iridium : MSColors.textMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(on ? MSColors.iridium.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .frame(height: 36)
        .background(MSColors.surface, in: RoundedRectangle(cornerRadius: MSRadius.card))
        .overlay(RoundedRectangle(cornerRadius: MSRadius.card).stroke(MSColors.border, lineWidth: 1))
    }
}

struct PassBanner: View {
    let label: String
    let pass: PassPrediction
    let accent: Color
    var subtitle: String?
    var showCountdown = false
    var countdownText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(label).msText(.labelMedium, color: accent.opacity(0.8))
                    Text(pass.satellite).msText(.titleMedium.weight(.semiBold), color: accent)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 0) {
                    if showCountdown, !countdownText.isEmpty {
                        Text(countdownText).msText(.headlineSmall.weight(.bold), mono: true, color: accent)
                    }
                    Text(PassesModel.formatTimeUtc(Int64(pass.aos.value)))
                        .msText(.titleMedium.weight(.bold), mono: true, color: showCountdown ? MSColors.textSecondary : accent)
                    Text("\(PassesModel.formatDateShort(Int64(pass.aos.value))) UTC").msText(.labelSmall, color: MSColors.textMuted)
                }
            }
            Spacer().frame(height: 8)
            HStack(spacing: 16) {
                PassDetailChip("Duration", PassesModel.formatDurationMin(pass.durationMin))
                PassDetailChip("Peak", "\(Int(pass.peakElevDeg.rounded()))\u{00B0}")
                PassDetailChip("Az", "\(Int(pass.peakAzimuthDeg.rounded()))\u{00B0}")
            }
            if let subtitle, !showCountdown {
                Spacer().frame(height: 4)
                Text(subtitle).msText(.labelSmall, color: accent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.05), in: RoundedRectangle(cornerRadius: MSRadius.sheet))
        .overlay(RoundedRectangle(cornerRadius: MSRadius.sheet).stroke(accent.opacity(0.2), lineWidth: 1))
        .animation(.default, value: showCountdown)
    }
}

struct PassDetailChip: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(label).msText(.labelSmall, color: MSColors.textMuted)
            Text(value).msText(.labelSmall, color: MSColors.textSecondary)
        }
    }
}

struct PassRow: View {
    let pass: PassPrediction
    let nowSec: Int64

    private static func elevationColor(_ elev: Double) -> Color {
        if elev >= 60 { return MSColors.iridium }
        if elev >= 30 { return MSColors.signalExcellent }
        if elev >= 15 { return MSColors.amber }
        return MSColors.textMuted
    }

    var body: some View {
        let aos = Int64(pass.aos.value)
        let los = Int64(pass.los.value)
        let isActive = aos <= nowSec && los >= nowSec
        let isPast = los < nowSec
        let alpha = isPast ? 0.4 : 1.0
        HStack(spacing: 8) {
            Circle().fill(isActive ? MSColors.iridium : MSColors.surfaceLight.opacity(alpha)).frame(width: 8, height: 8)
            Text(pass.satellite).msText(.labelSmall, color: MSColors.textPrimary.opacity(alpha)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1.2)
            Text("\(PassesModel.formatTimeUtc(aos))-\(PassesModel.formatTimeUtc(los))")
                .msText(.labelSmall, mono: true, color: MSColors.textSecondary.opacity(alpha))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(PassesModel.formatDurationMin(pass.durationMin))
                .msText(.labelSmall, mono: true, color: MSColors.textMuted.opacity(alpha))
                .frame(width: 40, alignment: .leading)
            HStack(spacing: 4) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(MSColors.surface)
                        RoundedRectangle(cornerRadius: 2).fill(Self.elevationColor(pass.peakElevDeg).opacity(alpha))
                            .frame(width: g.size.width * min(1, pass.peakElevDeg / 90))
                    }
                }
                .frame(height: 4)
                Text("\(Int(pass.peakElevDeg.rounded()))\u{00B0}").msText(.labelSmall, mono: true, color: MSColors.textMuted.opacity(alpha))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            isActive ? MSColors.iridium.opacity(0.1) : MSColors.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: MSRadius.card)
        )
        .overlay(RoundedRectangle(cornerRadius: MSRadius.card).stroke(isActive ? MSColors.iridium.opacity(0.2) : Color.clear, lineWidth: 1))
    }
}
