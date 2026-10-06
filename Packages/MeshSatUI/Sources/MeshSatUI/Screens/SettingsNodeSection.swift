// Mirrors the "Bluetooth connection" section of ui/screens/SettingsScreen.kt (the
// SetupSection.Node part): the status row in the mesh colour; connected, the node id, its
// battery (MESHSAT-1315), its reboots, the mesh nodes and a red Disconnect; disconnected, a
// Scan button and the devices found, each of which connects on tap. iOS shows CoreBluetooth's
// permission prompt when the central is first created, so before the permission is decided
// the button reads "Continue" with a line saying why (App Review, guideline 5.1.1(iv), 6 Oct
// 2026: a screen that leads to a permission prompt continues with a neutral word, not with the
// feature's own), and once denied it opens Settings. Android has no such rule and keeps its one
// button; the two apps differ here on purpose (MESHSAT-1331).
import MeshSatMeshtastic
import SwiftUI
import UIKit

public struct SettingsNodeSection: View {
    @Environment(GatewayModel.self) private var model

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: MSSpace.screen) {
                SectionCard("Bluetooth connection") {
                    ConnectionStatusRow(
                        label: "Status", connected: model.meshState == .connected, statusText: model.meshStatusText, color: MSColors.mesh)
                    if model.meshState == .connected {
                        connectedRows
                        MSFilledButton("Disconnect", container: MSColors.red) { model.disconnect() }
                    } else if model.meshState == .disconnected || model.meshState == .scanning {
                        scanRows
                    }
                }
            }
            .padding(MSSpace.screen)
        }
        .background(MSColors.bg)
    }

    @ViewBuilder
    private var scanRows: some View {
        switch model.bluetoothAuthorization {
        case .undecided:
            Text("MeshSat finds your node over Bluetooth. iOS asks for your permission first.")
                .msText(.bodySmall, color: MSColors.textMuted)
            MSFilledButton("Continue", container: MSColors.teal) { model.startScan() }
        case .denied:
            Text("Bluetooth is off for MeshSat. Allow it in Settings to reach your node.")
                .msText(.bodySmall, color: MSColors.textMuted)
            MSFilledButton("Open Settings", container: MSColors.teal) {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        case .allowed:
            MSFilledButton(
                model.meshState == .scanning ? "Scanning..." : "Scan for Meshtastic devices", container: MSColors.teal
            ) {
                model.startScan()
            }
            if !model.scanResults.isEmpty {
                Text("Found devices:").msText(.bodySmall, color: MSColors.textMuted)
                ForEach(model.scanResults, id: \.id) { node in
                    DeviceRow(name: node.name ?? "Unknown", address: node.address) { model.connect(node) }
                }
            }
        }
    }

    @ViewBuilder
    private var connectedRows: some View {
        if let info = model.myInfo {
            if !info.firmwareVersion.isEmpty { InfoRow("Firmware", info.firmwareVersion) }
            InfoRow("Node ID", MeshtasticProtocol.formatNodeId(info.myNodeNum))
            if let b = model.nodeBattery, b.nodeNum == info.myNodeNum,
                let text = NodeBattery.describe(level: b.level, voltage: b.voltage, hoursLeft: b.hoursLeft)
            {
                InfoRow("Battery", text)
            }
            if info.rebootCount > 0 { InfoRow("Reboots", String(info.rebootCount)) }
        }
        if !model.nodes.isEmpty {
            Text("Mesh Nodes (\(model.nodes.count))").msText(.bodySmall, color: MSColors.textMuted).padding(.top, 4)
            ForEach(model.nodes, id: \.nodeNum) { node in
                HStack {
                    Text(node.longName.isEmpty ? MeshtasticProtocol.formatNodeId(node.nodeNum) : node.longName).msText(.bodySmall)
                    Spacer(minLength: 8)
                    Text(node.shortName).msText(.bodySmall, color: MSColors.mesh)
                }
                .padding(6)
                .background(MSColors.surfaceLight, in: RoundedRectangle(cornerRadius: MSRadius.control, style: .continuous))
            }
        }
    }
}
