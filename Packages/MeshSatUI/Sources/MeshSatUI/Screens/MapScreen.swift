// Mirrors ui/screens/MapScreen.kt (MESHSAT-1249): the Map tab. It lives outside the navigation
// stacks and is never destroyed; `visible` says whether it is on screen, so tracks are only
// re-read while it is. The map takes the space; layers and the node list sit in a panel below
// that opens to at most half the height, so a long node list can no longer squeeze the map to
// nothing. Night mode reaches the map through its tile and marker pipeline, and the SwiftUI
// chrome around it through the usual colour effect, never a container holding the map view.
import MeshSatEngine
import MeshSatPlatform
import MeshSatStore
import SwiftUI

public struct MapScreen: View {
    let visible: Bool
    let nightMode: Bool
    @Environment(GatewayModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    @Environment(MapFocus.self) private var focus
    @State private var vm = MapModel()

    public init(visible: Bool, nightMode: Bool) {
        self.visible = visible
        self.nightMode = nightMode
    }

    public var body: some View {
        let offlineEnabled = settings.bool(SettingsKey.offlineMapEnabled)
        let offlineFile = settings.string(SettingsKey.offlineMapFile)
        VStack(alignment: .leading, spacing: 0) {
            Text("Map").msText(.headlineMedium).padding(.bottom, 8).nightMode(nightMode)
            GeometryReader { g in
                VStack(spacing: 8) {
                    ZStack(alignment: .topTrailing) {
                        MeshMapView(
                            detailed: vm.detailed, night: nightMode, nodes: vm.shownNodes, tracks: vm.shownTracks, names: vm.names,
                            phone: vm.showPhone ? model.phoneFix : nil, now: vm.now, ticket: vm.ticket)
                        VStack(spacing: 8) {
                            MapButton(icon: MSIcon.myLocation, description: "Centre on me") {
                                if !vm.centreOnMe(model.phoneFix) { model.showToast("Your position is not known yet.") }
                            }
                            MapButton(icon: MSIcon.zoomOutMap, description: "Show everyone on the map") {
                                if !vm.showEveryone(model.phoneFix) { model.showToast("No positions to show yet.") }
                            }
                        }
                        .padding(8)
                        .nightMode(nightMode)
                        VStack(spacing: 8) {
                            MapButton(icon: MSIcon.add, description: "Zoom in") { vm.send(.zoomIn) }
                            MapButton(icon: MSIcon.remove, description: "Zoom out") { vm.send(.zoomOut) }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .nightMode(nightMode)
                        MapStatusNote(detailed: vm.detailed, offline: vm.offline)
                            .padding(.leading, 8).padding(.bottom, 8).padding(.trailing, 64)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            .nightMode(nightMode)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: MSRadius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: MSRadius.card, style: .continuous).stroke(MSColors.border, lineWidth: 1))
                    MapPanel(vm: vm, phone: model.phoneFix, maxListHeight: g.size.height * 0.5).nightMode(nightMode)
                }
            }
        }
        .padding(MSSpace.screen)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MSColors.bg)
        .onAppear { vm.start(gateway: model.gateway, model: model) }
        .onChange(of: visible, initial: true) { _, on in vm.setVisible(on, gateway: model.gateway, model: model) }
        .onChange(of: model.phoneFix) { _, fix in vm.phoneChanged(fix) }
        .onChange(of: model.nodes.count) { _, _ in vm.setVisible(visible, gateway: model.gateway, model: model) }
        .task(id: "\(offlineEnabled)|\(offlineFile)") { await vm.loadDetailed(enabled: offlineEnabled, filename: offlineFile) }
        .onChange(of: focus.node, initial: true) { _, _ in consumeFocus() }
        .onChange(of: vm.nodes.count) { _, _ in consumeFocus() }
    }

    private func consumeFocus() {
        guard let want = focus.node else { return }
        guard let found = vm.focus(on: want) else { return }
        if !found { model.showToast("This node has not sent a position yet.") }
        focus.consumed()
    }
}

/// The panel under the map: a 56 dp bar that opens to the layers and the node list.
struct MapPanel: View {
    @Bindable var vm: MapModel
    let phone: PhoneFix?
    let maxListHeight: CGFloat

    var body: some View {
        let nodes = vm.mapNodes
        let shownCount = vm.showNodes ? nodes.filter { !vm.hidden.contains($0.nodeId) }.count : 0
        let summary = nodes.isEmpty ? "No node positions yet" : "\(shownCount) of \(Words.count(nodes.count, "node")) shown"
        VStack(spacing: 0) {
            Button {
                vm.panelOpen.toggle()
            } label: {
                HStack(spacing: 12) {
                    MSIcon.layers.resizable().scaledToFit().frame(width: 24, height: 24).foregroundStyle(MSColors.textSecondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Layers and nodes").msText(.titleSmall)
                        Text(summary).msText(.bodySmall, color: MSColors.textMuted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    (vm.panelOpen ? MSIcon.expandMore : MSIcon.expandLess).resizable().scaledToFit().frame(width: 24, height: 24)
                        .foregroundStyle(MSColors.textSecondary)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(vm.panelOpen ? "Close layers and nodes" : "Open layers and nodes")
            if vm.panelOpen {
                MSDivider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        panelHeading("Layers")
                        LayerRow(label: "This phone", dot: MSColors.teal, checked: $vm.showPhone)
                        LayerRow(label: "Nodes", dot: MSColors.mesh, checked: $vm.showNodes)
                        LayerRow(label: "Tracks from the last 24 hours", dot: MSColors.mesh, checked: $vm.showTracks)
                        if let phone { PhoneRow(fix: phone) }
                        HStack {
                            Text("Nodes").msText(.titleSmall, color: MSColors.textSecondary)
                            Spacer(minLength: 0)
                            if !nodes.isEmpty {
                                MSTextButton("Show all") { vm.hidden = [] }
                                MSTextButton("Hide all") { vm.hidden = Set(nodes.map(\.nodeId)) }
                            }
                        }
                        .padding(.leading, 12).padding(.trailing, 4).padding(.top, 8)
                        if nodes.isEmpty {
                            Text("Nodes appear here when they send a position.").msText(.bodyMedium, color: MSColors.textSecondary)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                        }
                        ForEach(nodes, id: \.nodeId) { node in
                            NodeListRow(
                                label: positionLabel(node, vm.names), node: node, shown: !vm.hidden.contains(node.nodeId),
                                stale: vm.now - node.timestamp > staleAfterMs,
                                onShownChange: { show in
                                    if show { vm.hidden.remove(node.nodeId) } else { vm.hidden.insert(node.nodeId) }
                                },
                                onCentre: { vm.centreOn(node) })
                        }
                    }
                }
                .frame(maxHeight: maxListHeight)
            }
        }
        .frame(maxWidth: .infinity)
        .msCard()
    }

    private func panelHeading(_ text: String) -> some View {
        Text(text).msText(.titleSmall, color: MSColors.textSecondary)
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
    }
}

/// One layer switch: the whole 48 dp row toggles it.
struct LayerRow: View {
    let label: String
    let dot: Color
    @Binding var checked: Bool

    var body: some View {
        Button {
            checked.toggle()
        } label: {
            HStack(spacing: 0) {
                MSCheckbox(checked: checked, label: label).padding(.horizontal, 8)
                Circle().fill(dot).frame(width: 10, height: 10)
                Text(label).msText(.bodyMedium).padding(.leading, 10)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(minHeight: MSSpace.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(checked ? "On" : "Off")
    }
}

struct PhoneRow: View {
    let fix: PhoneFix
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("This phone").msText(.bodyMedium)
            Text(String(format: "%.5f, %.5f", fix.latitude, fix.longitude) + ", " + lowerFirst(accuracyLine(fix)))
                .msText(.bodySmall, color: MSColors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func lowerFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }
}

/// One node: the checkbox shows or hides it on the map, the rest of the row centres the map on
/// it. The full name is shown, cut with an ellipsis only when it does not fit.
struct NodeListRow: View {
    let label: String
    let node: NodePosition
    let shown: Bool
    let stale: Bool
    let onShownChange: (Bool) -> Void
    let onCentre: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            MSCheckbox(checked: shown, label: "Show \(label) on the map", onChange: onShownChange)
            Button(action: onCentre) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(label).msText(.bodyMedium, color: stale ? MSColors.textSecondary : MSColors.textPrimary).lineLimit(1)
                    Text(heardLine(node.timestamp)).msText(.bodySmall, color: MSColors.textMuted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Centre the map on \(label)")
        }
        .padding(.leading, 4).padding(.trailing, 12)
    }
}
