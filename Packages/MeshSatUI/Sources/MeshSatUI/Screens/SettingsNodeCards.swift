// Mirrors a node card of ui/screens/SettingsScreen.kt:
// - "Node light and screen" (MESHSAT-1671): the owner's switches for the node's status LED and
//   screen, written to the node firmware's CONTROL characteristic and read back from STATUS flags
//   bits 5 and 6, so a switch shows what the node did. A node without CONTROL (firmware before
//   24 Oct 2026) says why the switches are missing.
import MeshSatMeshtastic
import SwiftUI

struct NodeLightAndScreenCard: View {
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        SectionCard("Node light and screen") {
            if !settings.pipeHasControl {
                Text("This node's firmware has no switches for its light and screen. Update the node's firmware to use them.")
                    .msText(.bodySmall, color: MSColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                SettingRow("Status LED") {
                    MSSwitch(isOn: binding(.ledOff, IridiumPipeContract.controlLed), label: "Status LED")
                }
                SettingRow("Screen") {
                    MSSwitch(isOn: binding(.screenOff, IridiumPipeContract.controlScreen), label: "Screen")
                }
                Text("The node keeps these after a restart. A press on the node's button always brings the screen back.")
                    .msText(.bodySmall, color: MSColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// On while the node does not report the switch off; a change is written and shows once the
    /// node reports it.
    private func binding(_ offFlag: IridiumPipeContract.Flags, _ control: UInt8) -> Binding<Bool> {
        Binding(
            get: { settings.pipeStatus?.flags?.contains(offFlag) != true },
            set: { on in Task { _ = await settings.writeNodeControl(control, off: !on) } }
        )
    }
}
