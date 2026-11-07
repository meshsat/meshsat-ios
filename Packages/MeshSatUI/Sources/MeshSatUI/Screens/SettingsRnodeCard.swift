// Mirrors the "RNode (LoRa radio)" card of ui/screens/SettingsScreen.kt (MESHSAT-1553 P4, here
// MESHSAT-1735): use an RNode, find one over Bluetooth LE, CrossTalk's four presets or custom
// parameters, the airtime limits, Apply (restarts the radio without a gateway restart), and the
// radio's state. iOS has no USB OTG, so the USB chip of Android's card does not exist here.
import MeshSatBLE
import MeshSatEngine
import MeshSatPlatform
import MeshSatRns
import SwiftUI

struct SettingsRnodeCard: View {
    @Environment(GatewayModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    @State private var enabled = false
    @State private var port = ""
    @State private var preset = "eu-868"
    @State private var custom = ""
    @State private var airtime = "0,0"
    @State private var scanning = false
    @State private var found: [RnodeBleScanner.Found] = []
    @State private var scanner: RnodeBleScanner?
    @State private var tick = 0

    var body: some View {
        SectionCard("RNode (LoRa radio)") {
            Text(
                "A Reticulum LoRa radio (RNode firmware 1.52 or newer) over Bluetooth LE puts this phone on the same mesh as Sideband "
                    + "and the kits' radios. Peers must match frequency, bandwidth, spreading factor and coding rate exactly; the presets "
                    + "are CrossTalk's starting points, not legal requirements. An RNode on a USB cable is not possible on an iPhone."
            )
            .msText(.bodySmall, color: MSColors.textMuted)
            SettingRow("Use an RNode") { MSSwitch(isOn: $enabled, label: "Use an RNode") }
            radioPicker
            parameters
            MSFilledButton("Apply", container: MSColors.teal, fullWidth: false) { apply() }
            // `tick` turns after Apply, so the line is read again once the radio had time to come up.
            stateLine.id(tick)
        }
        .onAppear(perform: load)
        .onDisappear { stopScan() }
    }

    private var radioPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            let chosen = port.hasPrefix("ble:") ? String(port.dropFirst(4)) : ""
            Text(chosen.isEmpty ? "No RNode chosen" : "RNode \(chosen.prefix(8))").msText(.bodyMedium)
            MSOutlinedButton(scanning ? "Scanning..." : "Scan for RNodes") { scanning ? stopScan() : startScan() }
            ForEach(found) { f in
                MSTextButton("\(f.name)  \(f.rssi) dBm", color: port == "ble:\(f.id.uuidString)" ? MSColors.teal : MSColors.offWhite) {
                    port = "ble:\(f.id.uuidString)"
                }
            }
        }
    }

    private var parameters: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Radio parameters").msText(.bodyMedium)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(RnodeProtocol.presets, id: \.id) { p in
                        MSFilterChip(p.label, selected: preset == p.id, selectedContainer: MSColors.teal.opacity(0.2)) { preset = p.id }
                    }
                    MSFilterChip("Custom", selected: preset == "custom", selectedContainer: MSColors.teal.opacity(0.2)) {
                        preset = "custom"
                    }
                }
            }
            if preset == "custom" {
                MSOutlinedTextField(
                    text: $custom, label: "frequency Hz, bandwidth Hz, TX power dBm, SF, CR", focusedBorder: MSColors.teal,
                    keyboard: .numbersAndPunctuation)
            } else if let p = RnodeProtocol.preset(preset) {
                Text(p.description).msText(.bodySmall, color: MSColors.textMuted)
            }
            if let p = shownParams {
                Text(Self.summary(p)).msText(.bodySmall, color: p.validate() == nil ? MSColors.textSecondary : MSColors.red)
            }
            MSOutlinedTextField(
                text: $airtime, label: "Airtime limits % short,long (0 = none)", focusedBorder: MSColors.teal,
                keyboard: .numbersAndPunctuation)
        }
    }

    private var shownParams: RnodeProtocol.Params? {
        RnsRnodeInterface.params(preset: preset, custom: custom, airtime: airtime.isEmpty ? "0,0" : airtime)
    }

    static func summary(_ p: RnodeProtocol.Params) -> String {
        let line = String(
            format: "%.4f MHz, %d kHz, SF %d, CR 4/%d, %d dBm, about %.0f bit/s on air", Double(p.frequency) / 1e6, p.bandwidth / 1000,
            p.sf,
            p.cr, p.txPower, p.bitrate())
        return p.validate().map { line + "; " + $0 } ?? line
    }

    @ViewBuilder
    private var stateLine: some View {
        if let s = model.gateway.rnodeState {
            let st = s.stats
            let detail = st.map { " Firmware \($0.firmware), RSSI \($0.rssi) dBm, \($0.rxPackets) in, \($0.txPackets) out." } ?? ""
            Text("RNode: \(s.status).\(s.online ? detail : "")").msText(.bodySmall, color: s.online ? MSColors.teal : MSColors.textMuted)
        } else {
            Text(enabled ? "Not running: choose an RNode and Apply." : "Off.").msText(.bodySmall, color: MSColors.textMuted)
        }
    }

    private func load() {
        enabled = settings.bool(SettingsKey.rnodeEnabled)
        port = settings.string(SettingsKey.rnodePort)
        preset = settings.string(SettingsKey.rnodePreset)
        custom = settings.string(SettingsKey.rnodeCustomParams)
        airtime = settings.string(SettingsKey.rnodeAirtimeLimits)
    }

    private func apply() {
        if preset == "custom", shownParams?.validate() != nil || shownParams == nil {
            return model.showToast("The custom parameters are not valid")
        }
        if enabled, !port.hasPrefix("ble:") || port.count < 10 { return model.showToast("Scan for the RNode and pick it") }
        settings.set(SettingsKey.rnodeEnabled, enabled)
        settings.set(SettingsKey.rnodePort, port)
        settings.set(SettingsKey.rnodePreset, preset)
        settings.set(SettingsKey.rnodeCustomParams, custom)
        settings.set(SettingsKey.rnodeAirtimeLimits, airtime.isEmpty ? "0,0" : airtime)
        model.gateway.restartRnode()
        stopScan()
        model.showToast(enabled ? "RNode settings applied, reconnecting" : "RNode settings saved")
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            tick += 1
        }
    }

    private func startScan() {
        found = []
        let s = RnodeBleScanner()
        s.onFound = { f in
            Task { @MainActor in
                if let i = found.firstIndex(where: { $0.id == f.id }) { found[i] = f } else { found.append(f) }
            }
        }
        s.start()
        scanner = s
        scanning = true
        Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            stopScan()
        }
    }

    private func stopScan() {
        scanner?.stop()
        scanner = nil
        scanning = false
    }
}
