// Mirrors the "Ham radio (APRS)", "TAK" and "Reticulum" cards of ui/screens/SettingsScreen.kt
// (SetupSection.Integrations). The APRS transport is GatewayController+Aprs (MESHSAT-1327); TAK
// is not ported yet: its settings are kept as Android keeps them.
import MeshSatAprs
import MeshSatEngine
import SwiftUI

public struct SettingsIntegrationsSection: View {
    @Environment(GatewayModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    @State private var aprsCallsign = ""
    @State private var aprsSsid = ""
    @State private var aprsHost = ""
    @State private var aprsPort = ""
    @State private var aprsIsServer = ""
    @State private var aprsIsPort = ""
    @State private var aprsIsPasscode = ""
    @State private var aprsIsFilterRange = ""
    @State private var aprsIsBeaconInterval = ""
    @State private var takPrefix = ""
    @State private var rnsHost = ""
    @State private var rnsPort = ""

    public init() {}

    public var body: some View {
        let aprsMode = settings.string(SettingsKey.aprsMode)
        ScrollView {
            VStack(spacing: MSSpace.screen) {
                aprsCard(aprsMode)
                takCard
                reticulumCard
            }
            .padding(MSSpace.screen)
        }
        .background(MSColors.bg)
        .onAppear(perform: load)
    }

    private func load() {
        aprsCallsign = settings.string(SettingsKey.aprsCallsign)
        aprsSsid = settings.string(SettingsKey.aprsSsid)
        aprsHost = settings.string(SettingsKey.aprsKissHost)
        aprsPort = settings.string(SettingsKey.aprsKissPort)
        aprsIsServer = settings.string(SettingsKey.aprsIsServer)
        aprsIsPort = settings.string(SettingsKey.aprsIsPort)
        aprsIsPasscode = settings.string(SettingsKey.aprsIsPasscode)
        aprsIsFilterRange = settings.string(SettingsKey.aprsIsFilterRange)
        aprsIsBeaconInterval = settings.string(SettingsKey.aprsIsBeaconInterval)
        takPrefix = settings.string(SettingsKey.takCallsignPrefix)
        rnsHost = settings.string(SettingsKey.rnsTcpHost)
        rnsPort = settings.string(SettingsKey.rnsTcpPort)
    }

    private func linkStatus(_ id: String) -> (Bool, String) {
        switch model.interfaces[id]?.state {
        case .online: (true, "Connected")
        case .connecting: (false, "Connecting...")
        case .error: (false, "Error")
        default: (false, "Disconnected")
        }
    }

    private func aprsCard(_ mode: String) -> some View {
        SectionCard("Ham radio (APRS)") {
            SettingRow("Enable APRS") { MSSwitch(isOn: settings.binding(SettingsKey.aprsEnabled), label: "Enable APRS") }
            HStack(spacing: 8) {
                MSFilterChip("KISS TNC", selected: mode == "kiss", selectedContainer: MSColors.teal.opacity(0.2)) {
                    settings.set(SettingsKey.aprsMode, "kiss")
                }
                MSFilterChip("APRS-IS Direct", selected: mode == "is", selectedContainer: MSColors.teal.opacity(0.2)) {
                    settings.set(SettingsKey.aprsMode, "is")
                }
            }
            let (online, status) = linkStatus("aprs_0")
            ConnectionStatusRow(label: mode == "kiss" ? "KISS TNC" : "APRS-IS", connected: online, statusText: status, color: MSColors.teal)
            MSOutlinedTextField(text: $aprsCallsign, label: "Callsign", focusedBorder: MSColors.teal)
                .onChange(of: aprsCallsign) { _, v in
                    let up = String(v.uppercased().prefix(6))
                    if up != v { aprsCallsign = up }
                }
            MSOutlinedTextField(text: $aprsSsid, label: "SSID (0-15)", focusedBorder: MSColors.teal, keyboard: .numberPad)
                .onChange(of: aprsSsid) { _, v in
                    let d = String(v.filter(\.isNumber).prefix(2))
                    if d != v { aprsSsid = d }
                }
            if mode == "kiss" {
                HStack(spacing: 8) {
                    MSOutlinedTextField(text: $aprsHost, label: "KISS Host", focusedBorder: MSColors.teal).layoutPriority(2)
                    MSOutlinedTextField(text: $aprsPort, label: "Port", focusedBorder: MSColors.teal, keyboard: .numberPad).frame(
                        width: 110)
                }
                // A KISS TNC has no command for the radio's frequency (MESHSAT-1249).
                Text("The frequency is set on the radio itself: 144.800 MHz in Europe, 144.390 MHz in North America.")
                    .msText(.bodySmall, color: MSColors.textMuted)
            } else {
                HStack(spacing: 8) {
                    MSOutlinedTextField(text: $aprsIsServer, label: "APRS-IS Server", focusedBorder: MSColors.teal).layoutPriority(2)
                    MSOutlinedTextField(text: $aprsIsPort, label: "Port", focusedBorder: MSColors.teal, keyboard: .numberPad).frame(
                        width: 110)
                }
                HStack(spacing: 8) {
                    MSOutlinedTextField(
                        text: $aprsIsPasscode, label: "Passcode", focusedBorder: MSColors.teal, keyboard: .numbersAndPunctuation)
                    MSOutlinedButton("Auto") {
                        if !aprsCallsign.trimmingCharacters(in: .whitespaces).isEmpty {
                            aprsIsPasscode = AprsIsPasscode.calculate(aprsCallsign)
                        }
                    }
                    .fixedSize()
                }
                MSOutlinedTextField(
                    text: $aprsIsFilterRange, label: "Filter radius (km)", focusedBorder: MSColors.teal, keyboard: .numberPad)
                SettingRow("Position beacon") {
                    MSSwitch(isOn: settings.binding(SettingsKey.aprsIsBeaconEnabled), label: "Position beacon")
                }
                if settings.bool(SettingsKey.aprsIsBeaconEnabled) {
                    MSOutlinedTextField(
                        text: $aprsIsBeaconInterval, label: "Beacon interval (min)", focusedBorder: MSColors.teal, keyboard: .numberPad)
                }
            }
            MSFilledButton("Save", container: MSColors.teal, fullWidth: false) {
                settings.set(SettingsKey.aprsCallsign, aprsCallsign)
                settings.set(SettingsKey.aprsSsid, aprsSsid)
                if mode == "kiss" {
                    settings.set(SettingsKey.aprsKissHost, aprsHost)
                    settings.set(SettingsKey.aprsKissPort, aprsPort)
                } else {
                    settings.set(SettingsKey.aprsIsServer, aprsIsServer)
                    settings.set(SettingsKey.aprsIsPort, aprsIsPort)
                    settings.set(SettingsKey.aprsIsPasscode, aprsIsPasscode)
                    settings.set(SettingsKey.aprsIsFilterRange, aprsIsFilterRange)
                    settings.set(SettingsKey.aprsIsBeaconInterval, aprsIsBeaconInterval)
                }
                model.showToast("APRS settings saved")
            }
            Text(
                mode == "kiss"
                    ? "Connect to a KISS TCP server, for example Direwolf on your network, for local RF APRS through a radio. "
                        + "SSID 7 = handheld, 10 = igate. EU: 144.800 MHz, NA: 144.390 MHz."
                    : "Connect directly to APRS-IS (rotate.aprs2.net) over the internet. No radio needed. Use passcode -1 for "
                        + "receive-only, or Auto to calculate from callsign. Position beacon sends GPS location at the configured interval."
            )
            .msText(.bodySmall, color: MSColors.textMuted)
        }
    }

    private var takCard: some View {
        SectionCard("TAK") {
            SettingRow("Enable TAK") { MSSwitch(isOn: settings.binding(SettingsKey.takEnabled), label: "Enable TAK") }
            MSOutlinedTextField(text: $takPrefix, label: "Callsign Prefix", focusedBorder: MSColors.teal)
                .onChange(of: takPrefix) { _, v in
                    let up = String(v.uppercased().prefix(10))
                    if up != v { takPrefix = up }
                }
            SettingRow("MQTT Export to Hub") { MSSwitch(isOn: settings.binding(SettingsKey.takMqttExport), label: "MQTT Export to Hub") }
            MSFilledButton("Save", container: MSColors.teal, fullWidth: false) {
                settings.set(SettingsKey.takCallsignPrefix, takPrefix)
                model.showToast("TAK settings saved")
            }
            Text(
                "Generates CoT (Cursor on Target) events for positions, SOS, telemetry, and chat. MQTT Export sends them to the Hub for "
                    + "relay to a TAK server. There is no ATAK on iPhone, so the local broadcast Android offers does not exist here. "
                    + "Callsign format: PREFIX-XXXX (last 4 hex of device ID)."
            )
            .msText(.bodySmall, color: MSColors.textMuted)
        }
    }

    private var reticulumCard: some View {
        SectionCard("Reticulum") {
            SettingRow("Enable RNS TCP") { MSSwitch(isOn: settings.binding(SettingsKey.rnsTcpEnabled), label: "Enable RNS TCP") }
            let (online, status) = linkStatus("tcp_rns_0")
            ConnectionStatusRow(label: "RNS TCP", connected: online, statusText: status, color: MSColors.teal)
            HStack(spacing: 8) {
                MSOutlinedTextField(text: $rnsHost, label: "Host", focusedBorder: MSColors.teal).layoutPriority(2)
                MSOutlinedTextField(text: $rnsPort, label: "Port", focusedBorder: MSColors.teal, keyboard: .numberPad).frame(width: 110)
            }
            SettingRow("TLS") { MSSwitch(isOn: settings.binding(SettingsKey.rnsTcpTls), label: "TLS") }
            MSFilledButton("Save", container: MSColors.teal, fullWidth: false) {
                settings.set(SettingsKey.rnsTcpHost, rnsHost)
                settings.set(SettingsKey.rnsTcpPort, String(rnsPort.filter(\.isNumber).prefix(5)))
                model.showToast("RNS TCP settings saved")
            }
            Text(
                "Connect to a stock Reticulum (Python RNS) node over TCP/IP. Enable TLS for public endpoints (e.g. port 443 via "
                    + "HAProxy/stunnel). Default port 4242. Uses HDLC framing for wire compatibility."
            )
            .msText(.bodySmall, color: MSColors.textMuted)
        }
    }
}
