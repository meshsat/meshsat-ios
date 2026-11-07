// Mirrors the "Ham radio (APRS)", "TAK" and "Reticulum" cards of ui/screens/SettingsScreen.kt
// (SetupSection.Integrations). The APRS transport is GatewayController+Aprs (MESHSAT-1327); TAK
// is not ported yet: its settings are kept as Android keeps them. The Reticulum card is Android's
// of MESHSAT-1553 (the LXMF address, name and announce, the propagation node, the satellite
// allow-list, peers on this WiFi, the TCP client); the AutoInterface switch waits for Apple's
// multicast entitlement (MESHSAT-1828) and is a line of text until then, never a dead switch.
import MeshSatAprs
import MeshSatEngine
import MeshSatLXMF
import MeshSatPlatform
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
    @State private var lxmfName = ""
    @State private var syncMin = ""
    @State private var paidDests = ""
    @State private var paidHops = ""
    /// The propagation node and listener lines re-read every two seconds while the card is shown (Android's pnTick).
    @State private var tick = 0

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
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                tick += 1
            }
        }
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
        lxmfName = settings.string(SettingsKey.lxmfDisplayName)
        syncMin = settings.string(SettingsKey.lxmfSyncIntervalMin)
        paidDests = settings.string(SettingsKey.rnsPaidDests)
        paidHops = settings.string(SettingsKey.rnsPaidExtraHops)
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

    // MARK: Reticulum (SettingsScreen.kt's "Reticulum" card, MESHSAT-1553)

    private var reticulumCard: some View {
        SectionCard("Reticulum") {
            lxmfAddressBlock
            MSDivider().padding(.vertical, 4)
            propagationBlock
            MSDivider().padding(.vertical, 4)
            satelliteBlock
            MSDivider().padding(.vertical, 4)
            wifiBlock
            MSDivider().padding(.vertical, 4)
            tcpClientBlock
        }
    }

    private var lxmfAddressBlock: some View {
        let address = model.gateway.lxmfAddress
        return VStack(alignment: .leading, spacing: 8) {
            Text("Your LXMF address").msText(.bodyMedium)
            HStack(spacing: 8) {
                Text(address.isEmpty ? "Starts with the gateway" : address)
                    .msText(.bodySmall, color: address.isEmpty ? MSColors.textMuted : MSColors.teal)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !address.isEmpty {
                    MSIconButton(MSIcon.contentCopy, label: "Copy the address", tint: MSColors.teal) {
                        UIPasteboard.general.string = address
                        model.showToast("Address copied")
                    }
                }
            }
            Text(
                "Sideband, CrossTalk, NomadNet and MeshChat reach this phone at this address. "
                    + "The name below is what they show for it; it takes effect when the gateway restarts."
            )
            .msText(.bodySmall, color: MSColors.textMuted)
            HStack(spacing: 8) {
                MSOutlinedTextField(text: $lxmfName, label: "Display name", focusedBorder: MSColors.teal)
                    .onChange(of: lxmfName) { _, v in if v.count > 40 { lxmfName = String(v.prefix(40)) } }
                MSFilledButton("Save", container: MSColors.teal, fullWidth: false) {
                    settings.set(SettingsKey.lxmfDisplayName, lxmfName.trimmingCharacters(in: .whitespaces))
                    model.showToast("Name saved")
                }
            }
            MSFilledButton("Announce now", container: MSColors.teal, fullWidth: false) {
                model.showToast(model.gateway.announceLxmf() ? "Announced" : "Nothing to announce on: no Reticulum link is up")
            }
            .disabled(!model.gateway.lxmfRunning)
            .opacity(model.gateway.lxmfRunning ? 1 : 0.4)
        }
    }

    private var propagationBlock: some View {
        let choice = settings.string(SettingsKey.lxmfPropagationNode)
        let router = model.gateway.lxmfRouter
        let nodes = router?.propagationNodes() ?? []
        let current = router?.propagationNodeInfo()
        _ = tick
        return VStack(alignment: .leading, spacing: 8) {
            Text("Propagation node").msText(.bodyMedium)
            Text(
                "A message sent as Propagated waits at an LXMF propagation node until the other side syncs, "
                    + "and Sync fetches what a node holds for this phone. Automatic takes the nearest node heard announcing."
            )
            .msText(.bodySmall, color: MSColors.textMuted)
            Text(propagationLine(choice: choice, running: router != nil, current: current))
                .msText(.bodySmall, color: current != nil && choice != "none" ? MSColors.teal : MSColors.textMuted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    MSFilterChip("Automatic", selected: choice.isEmpty, selectedContainer: MSColors.teal.opacity(0.2)) {
                        pickPropagation("")
                    }
                    MSFilterChip("Off", selected: choice == "none", selectedContainer: MSColors.teal.opacity(0.2)) {
                        pickPropagation("none")
                    }
                    ForEach(nodes, id: \.destHex) { n in
                        MSFilterChip(
                            n.name ?? String(n.destHex.prefix(8)), selected: choice == n.destHex,
                            selectedContainer: MSColors.teal.opacity(0.2)
                        ) {
                            pickPropagation(n.destHex)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                MSOutlinedTextField(
                    text: $syncMin, label: "Sync every (min, 0 = by hand)", focusedBorder: MSColors.teal, keyboard: .numberPad
                )
                .onChange(of: syncMin) { _, v in
                    let digits = String(v.filter(\.isNumber).prefix(4))
                    if digits != v {
                        syncMin = digits
                        return
                    }
                    settings.set(SettingsKey.lxmfSyncIntervalMin, digits.isEmpty ? "0" : digits)
                    model.gateway.applyReticulumSettings()
                }
                MSFilledButton("Sync now", container: MSColors.teal, fullWidth: false) {
                    _ = router?.sync()
                    tick += 1
                    model.showToast("Syncing from the propagation node")
                }
                .disabled(current == nil || choice == "none" || router?.syncState.busy == true)
                .opacity(current == nil || choice == "none" || router?.syncState.busy == true ? 0.4 : 1)
            }
            if let router { Text(syncLine(router)).msText(.bodySmall, color: MSColors.textMuted) }
        }
    }

    private func propagationLine(choice: String, running: Bool, current: PropagationNodeInfo?) -> String {
        if choice == "none" { return "Off" }
        if !running { return "Starts with the gateway" }
        guard let current else { return "No propagation node heard yet" }
        let name = current.name ?? String(current.destHex.prefix(8))
        return "Using \(name), \(Words.count(current.hops, "hop")) away, stamp cost \(current.stampCost)"
            + (choice.isEmpty ? " (automatic)" : "")
    }

    private func syncLine(_ router: LxmfRouter) -> String {
        if router.syncState.busy { return "Syncing: \(Self.words(router.syncState))" }
        guard let last = router.lastSync else { return "Not synced yet" }
        if last.state == .complete {
            return "Last sync: \(Words.count(last.received, "new message"))"
                + (last.duplicates > 0 ? ", \(last.duplicates) already here" : "")
        }
        return "Last sync failed: \(last.error)"
    }

    /// "linkEstablishing" -> "link establishing", as Android shows SyncState names.
    private static func words(_ state: SyncState) -> String {
        var out = ""
        for c in String(describing: state) {
            if c.isUppercase { out += " " }
            out.append(c.lowercased())
        }
        return out
    }

    private func pickPropagation(_ choice: String) {
        settings.set(SettingsKey.lxmfPropagationNode, choice)
        model.gateway.applyReticulumSettings()
        tick += 1
    }

    private var satelliteBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reticulum by satellite").msText(.bodyMedium)
            Text(
                "The satellite carries announces and path requests only for the addresses listed here (yours is always included), "
                    + "and every packet arriving over it counts as this many extra hops, so the far end waits for the satellite "
                    + "round trip: 20 covers a minute each way."
            )
            .msText(.bodySmall, color: MSColors.textMuted)
            MSOutlinedTextField(
                text: $paidDests, label: "Addresses across the satellite, comma separated", focusedBorder: MSColors.teal,
                lineLimit: 3, keyboard: .asciiCapable
            )
            .textInputAutocapitalization(.never)
            HStack(spacing: 8) {
                MSOutlinedTextField(text: $paidHops, label: "Extra hops", focusedBorder: MSColors.teal, keyboard: .numberPad)
                    .onChange(of: paidHops) { _, v in
                        let d = String(v.filter(\.isNumber).prefix(2))
                        if d != v { paidHops = d }
                    }
                MSFilledButton("Save", container: MSColors.teal, fullWidth: false) {
                    let dests = paidDests.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map { $0.lowercased() }
                        .filter { Peers.isLxmf($0) }
                    let hops = min(max(Int(paidHops) ?? 20, 0), 32)
                    settings.set(SettingsKey.rnsPaidDests, dests.joined(separator: ","))
                    settings.set(SettingsKey.rnsPaidExtraHops, String(hops))
                    paidDests = dests.joined(separator: ",")
                    paidHops = String(hops)
                    model.gateway.applyReticulumSettings()
                    model.showToast("Satellite list saved: \(Words.count(dests.count, "address", "addresses")), \(hops) extra hops")
                }
            }
        }
    }

    private var wifiBlock: some View {
        let listenOn = settings.bool(SettingsKey.rnsTcpListenEnabled)
        let port = settings.string(SettingsKey.rnsTcpListenPort)
        let listener = model.gateway.reticulumListener
        _ = tick
        return VStack(alignment: .leading, spacing: 8) {
            Text("Peers on this WiFi").msText(.bodyMedium)
            Text(
                "Finding Reticulum apps by themselves (AutoInterface) needs Apple's multicast networking entitlement, which is "
                    + "requested; until it is granted, give Sideband this phone's address by hand."
            )
            .msText(.bodySmall, color: MSColors.textMuted)
            SettingRow("Listen on TCP port \(port)") {
                MSSwitch(isOn: settings.binding(SettingsKey.rnsTcpListenEnabled), label: "Listen on TCP port \(port)")
            }
            Text(wifiLine(listenOn: listenOn, listener: listener)).msText(.bodySmall, color: MSColors.textMuted)
        }
    }

    private func wifiLine(listenOn: Bool, listener: (port: Int, peers: Int)?) -> String {
        if !listenOn { return "Off. Takes effect when the gateway restarts." }
        guard let listener else {
            return model.gateway.lxmfRunning ? "Not listening (the port may be taken)." : "Starts with the gateway."
        }
        let ip = LocalNetwork.wifiAddress() ?? "this phone's WiFi address"
        let peers = Words.count(listener.peers, "peer")
        return "Listening; \(peers) connected. In Sideband, add a TCP client interface to \(ip) port \(listener.port)."
    }

    private var tcpClientBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reticulum over TCP").msText(.bodyMedium)
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
