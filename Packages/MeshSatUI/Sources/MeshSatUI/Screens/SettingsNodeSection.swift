// Mirrors the "Bluetooth connection" section of ui/screens/SettingsScreen.kt (the
// SetupSection.Node part): the status row in the mesh colour; connected, the node id, its
// battery (MESHSAT-1315), its reboots, the mesh nodes and a red Disconnect; disconnected, a
// Scan button and the devices found, each of which connects on tap. iOS shows CoreBluetooth's
// permission prompt on the first scan by itself.
import MeshSatMeshtastic
import SwiftUI

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
            }
            .padding(MSSpace.screen)
        }
        .background(MSColors.bg)
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
