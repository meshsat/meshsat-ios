// Mirrors ui/screens/RadioConfigScreen.kt (MESHSAT-243, revamped in MESHSAT-1249). Every
// section is edited on top of what the radio reported: a field the user did not see loaded is
// never sent, and nothing can be applied before the radio's own settings have arrived. LoRa and
// channels apply live without a restart (older firmware restarts for LoRa); owner, position,
// Bluetooth and network changes restart the node about 5 s later, so BLE drops and reconnects.
import MeshSatMeshtastic
import MeshSatProto
import SwiftUI

private enum RadioTab: String, CaseIterable {
    case identity = "Name"
    case radio = "Radio"
    case channels = "Channels"
    case position = "Position"
    case bluetooth = "Bluetooth"
    case network = "WiFi"
    case admin = "Restart and reset"
}

private let reading = "Reading the radio's settings..."
private let restarts = "Sent to the radio. It restarts to apply the change."

/// What the tabs share: whether a command can go out, the node number, the send path.
struct RadioSender {
    let canSend: Bool
    let connected: Bool
    let myNodeNum: UInt32
    let send: ([UInt8]) -> Void
    let toast: (String) -> Void
    let readBack: () -> Void
}

public struct RadioConfigScreen: View {
    @Environment(GatewayModel.self) private var model
    @Environment(Router.self) private var router
    @State private var activeTab: RadioTab = .identity

    public init() {}

    public var body: some View {
        let connected = model.meshState == .connected
        let myNodeNum = model.myInfo?.myNodeNum ?? 0
        // Admin messages are addressed to our own node number; without it nothing can be sent.
        let sender = RadioSender(
            canSend: connected && myNodeNum != 0, connected: connected, myNodeNum: myNodeNum,
            send: { model.gateway.central.sendToRadio($0) }, toast: { model.showToast($0) },
            // After a change that applies without a restart, read the settings back so this screen
            // shows what the radio actually holds (it may also correct a value), not what was typed.
            readBack: {
                Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    model.gateway.central.sendToRadio(MeshtasticProtocol.encodeWantConfig(MeshtasticProtocol.wantConfigOnlyConfig))
                }
            })
        VStack(alignment: .leading, spacing: 0) {
            if !connected {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your phone is not connected to your node, so its settings cannot be read or changed.")
                        .msText(.bodyMedium, color: MSColors.textSecondary)
                    MSFilledButton("Connect your node", fullWidth: false) { router.navigate(.setupSection(.node)) }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .msCard()
                .padding(.bottom, 12)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(RadioTab.allCases, id: \.self) { tab in
                        let selected = activeTab == tab
                        Button {
                            activeTab = tab
                        } label: {
                            Text(tab.rawValue).msText(.labelLarge, color: selected ? MSColors.textPrimary : MSColors.textMuted)
                                .padding(.horizontal, 14).frame(minHeight: MSSpace.touch)
                                .background(selected ? MSColors.surfaceLight : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Rectangle().fill(MSColors.border).frame(height: 1).padding(.top, 8).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch activeTab {
                    case .identity: IdentityTab(sender: sender)
                    case .radio: RadioTabContent(sender: sender)
                    case .channels: ChannelsTab(sender: sender)
                    case .position: PositionTab(sender: sender)
                    case .bluetooth: BluetoothTab(sender: sender)
                    case .network: NetworkTab(sender: sender)
                    case .admin: DeviceAdminTab(sender: sender)
                    }
                }
            }
        }
        .padding(MSSpace.screen)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MSColors.bg)
        // The radio sends its settings with want_config on every connect. If they have not
        // arrived a few seconds later, ask once more for the settings alone.
        .task(id: connected) {
            guard connected else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if model.loraConfig == nil || model.channels.isEmpty {
                model.gateway.central.sendToRadio(MeshtasticProtocol.encodeWantConfig(MeshtasticProtocol.wantConfigOnlyConfig))
            }
        }
    }
}

/// Shown in place of a section until the radio has reported it.
private struct NotLoaded: View {
    let connected: Bool
    var body: some View {
        Text(connected ? reading : "Connect your node to read its settings.").msText(.bodyMedium, color: MSColors.textSecondary)
            .padding(.vertical, 8)
    }
}

// MARK: Name tab

private struct IdentityTab: View {
    let sender: RadioSender
    @Environment(GatewayModel.self) private var model
    @State private var editLongName = ""
    @State private var editShortName = ""

    var body: some View {
        let ownerName = model.ownerName
        let ownerShort = model.ownerShortName
        let metadata = model.deviceMetadata
        let myNode = model.nodes.first { $0.nodeNum == sender.myNodeNum }
        let ownerLoaded = !ownerName.isEmpty && myNode != nil
        let changed =
            editLongName.trimmingCharacters(in: .whitespaces) != ownerName
            || editShortName.trimmingCharacters(in: .whitespaces) != ownerShort
        let hw = (myNode?.hwModel).flatMap { $0 != 0 ? $0 : nil } ?? metadata?.hwModel ?? 0
        let has =
            metadata.map { md -> String in
                let parts = [
                    md.hasWifi ? "WiFi" : nil, md.hasBluetooth ? "Bluetooth" : nil, md.hasEthernet ? "Ethernet" : nil,
                    md.canShutdown ? "Power off" : nil,
                ]
                .compactMap { $0 }
                return parts.isEmpty ? "-" : parts.joined(separator: ", ")
            } ?? "-"
        ConfigCard("This node") {
            RadioInfoRow("Node ID", sender.myNodeNum != 0 ? MeshtasticProtocol.formatNodeId(sender.myNodeNum) : "-", mono: true)
            RadioInfoRow("Hardware", hw != 0 ? MeshtasticProtocol.hardwareName(hw) : "-")
            RadioInfoRow("Firmware", (metadata?.firmwareVersion).flatMap { $0.isEmpty ? nil : $0 } ?? "-", mono: true)
            RadioInfoRow("Has", has)
        }
        ConfigCard("Name") {
            Hint("The long name shows in other people's node lists. The short name, up to 4 characters, is used where space is tight.")
            if !ownerLoaded {
                NotLoaded(connected: sender.connected)
            } else {
                MSOutlinedTextField(text: $editLongName, label: "Long name").padding(.top, 8)
                    .onChange(of: editLongName) { _, v in if v.count > 39 { editLongName = String(v.prefix(39)) } }
                MSOutlinedTextField(text: $editShortName, label: "Short name").padding(.top, 8)
                    .onChange(of: editShortName) { _, v in if v.count > 4 { editShortName = String(v.prefix(4)) } }
                MSFilledButton("Save name") {
                    // is_licensed goes back as the radio reported it: sending false would switch a
                    // licensed (ham) node out of licensed mode and change its keys.
                    sender.send(
                        MeshtasticProtoAdapter.buildAdminSetOwner(
                            myNodeNum: sender.myNodeNum, longName: editLongName.trimmingCharacters(in: .whitespaces),
                            shortName: editShortName.trimmingCharacters(in: .whitespaces), isLicensed: myNode?.isLicensed ?? false))
                    sender.toast(restarts)
                }
                .padding(.top, 8)
                .disabled(
                    !(sender.canSend && changed && !editLongName.trimmingCharacters(in: .whitespaces).isEmpty
                        && !editShortName.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .onChange(of: ownerName, initial: true) { _, v in editLongName = v }
        .onChange(of: ownerShort, initial: true) { _, v in editShortName = v }
    }
}

// MARK: Radio tab

private struct RadioTabContent: View {
    let sender: RadioSender
    @Environment(GatewayModel.self) private var model
    @State private var region = 0
    @State private var preset = 0
    @State private var presetPicked = false
    @State private var txPower = ""
    @State private var hopLimit = ""
    @State private var txEnabled = false
    @State private var showRegionPicker = false
    @State private var showPresetPicker = false
    @State private var showDetails = false
    @State private var showConfirm = false
    @State private var loadedFor: Meshtastic_Config.LoRaConfig?

    var body: some View {
        if let loaded = model.loraConfig {
            content(loaded)
                .onChange(of: loaded, initial: true) { _, l in reset(l) }
        } else {
            NotLoaded(connected: sender.connected)
        }
    }

    private func reset(_ l: Meshtastic_Config.LoRaConfig) {
        // Enum values are read and written as numbers: a region or preset newer than the bundled
        // proto must survive an apply untouched.
        region = l.region.rawValue
        preset = l.modemPreset.rawValue
        presetPicked = false
        txPower = "\(l.txPower)"
        hopLimit = "\(l.hopLimit)"
        txEnabled = l.txEnabled
        loadedFor = l
    }

    @ViewBuilder private func content(_ loaded: Meshtastic_Config.LoRaConfig) -> some View {
        let phoneCountry = RegionCheck.phoneCountry()
        let power = Int(txPower)
        let hops = Int(hopLimit)
        // Whatever the radio reported is accepted as it is; a new value must be in range.
        let powerOk = power.map { (0...30).contains($0) || $0 == Int(loaded.txPower) } ?? false
        let hopsOk = hops.map { (1...7).contains($0) || $0 == Int(loaded.hopLimit) } ?? false
        let regionChanged = region != loaded.region.rawValue
        let presetChanged = presetPicked && (preset != loaded.modemPreset.rawValue || !loaded.usePreset)
        let powerChanged = powerOk && power != Int(loaded.txPower)
        let hopsChanged = hopsOk && hops != Int(loaded.hopLimit)
        let txChanged = txEnabled != loaded.txEnabled
        let changed = regionChanged || presetChanged || powerChanged || hopsChanged || txChanged
        let custom = !loaded.usePreset && !presetPicked
        let applyNow = {
            var b = loaded
            if regionChanged { b.region = Meshtastic_Config.LoRaConfig.RegionCode(rawValue: region) ?? b.region }
            if presetChanged {
                b.modemPreset = Meshtastic_Config.LoRaConfig.ModemPreset(rawValue: preset) ?? b.modemPreset
                b.usePreset = true
            }
            if powerChanged, let power { b.txPower = Int32(power) }
            if hopsChanged, let hops { b.hopLimit = UInt32(hops) }
            if txChanged { b.txEnabled = txEnabled }
            var config = Meshtastic_Config()
            config.lora = b
            sender.send(MeshtasticProtoAdapter.buildAdminSetConfig(myNodeNum: sender.myNodeNum, config: config))
            sender.toast("Sent to the radio. It switches over in a few seconds; older firmware restarts to do it.")
            sender.readBack()
        }
        ConfigCard("Region") {
            Hint("The radio band for the country you are in. Every node on your mesh uses the same one.")
            MSOutlinedButton(RadioWords.regionLabel(region), enabled: sender.canSend) { showRegionPicker = true }.padding(.top, 8)
            if let warning = RegionCheck.warning(region, phoneCountry) { StatusBanner(warning, MSColors.amber).padding(.top, 8) }
        }
        ConfigCard("Preset") {
            Hint("How far and how fast the radio talks. Every node on your mesh must use the same preset.")
            MSOutlinedButton(custom ? "Custom settings" : RadioWords.presetLabel(preset), enabled: sender.canSend) {
                showPresetPicker = true
            }
            .padding(.top, 8)
            HStack { MSTextButton(showDetails ? "Hide details" : "Details") { showDetails.toggle() } }
            if showDetails {
                Hint(
                    custom
                        ? "Custom: spreading factor \(loaded.spreadFactor), bandwidth \(loaded.bandwidth) kHz, "
                            + "coding rate 4/\(loaded.codingRate). Picking a preset replaces these."
                        : RadioWords.presetDetails(preset).map {
                            "\(RadioWords.presetLabel(preset)): \($0). Radios on 2.4 GHz use wider bandwidths."
                        }
                            ?? "This app does not know the details of this preset.")
            }
        }
        ConfigCard("Transmit power") {
            Hint("In dBm. 0 means the highest power allowed in your region.")
            NumberField(
                text: $txPower, label: "dBm", digits: 2, enabled: sender.canSend, error: powerOk ? nil : "Enter a number from 0 to 30."
            )
            .padding(.top, 8)
        }
        ConfigCard("Hops") {
            Hint("How many times other nodes pass your messages on, 1 to 7. Fewer keeps the mesh quieter.")
            NumberField(
                text: $hopLimit, label: "Hops", digits: 1, enabled: sender.canSend, error: hopsOk ? nil : "Enter a number from 1 to 7."
            )
            .padding(.top, 8)
        }
        ConfigCard("Transmit") {
            ToggleRow(
                "Transmit", isOn: $txEnabled, hint: "Off makes your node listen only: nothing you send leaves it.", enabled: sender.canSend)
        }
        MSFilledButton("Apply") {
            if regionChanged || presetChanged || (loaded.txEnabled && !txEnabled) { showConfirm = true } else { applyNow() }
        }
        .disabled(!(sender.canSend && changed && powerOk && hopsOk))
        if showRegionPicker {
            PickerDialog(
                title: "Region", options: MeshtasticProtocol.LoRaRegion.allCases.filter { $0 != .unset }.map { ($0.code, $0.label) },
                selected: region,
                onSelect: {
                    region = $0
                    showRegionPicker = false
                }, onDismiss: { showRegionPicker = false })
        }
        if showPresetPicker {
            PickerDialog(
                title: "Preset", options: MeshtasticProtocol.ModemPreset.allCases.map { ($0.code, $0.label) },
                selected: custom ? -1 : preset,
                onSelect: {
                    preset = $0
                    presetPicked = true
                    showPresetPicker = false
                }, onDismiss: { showPresetPicker = false })
        }
        if showConfirm {
            let consequences = [
                regionChanged || presetChanged
                    ? "Changing the region or preset can cut you off from other nodes until they change too." : nil,
                loaded.txEnabled && !txEnabled
                    ? "With transmit off, nothing you send reaches the mesh, and other nodes stop hearing your node." : nil,
            ].compactMap { $0 }.joined(separator: "\n\n")
            ConfirmDialog(
                title: "Apply these radio settings?", message: consequences, confirmLabel: "Apply",
                onConfirm: {
                    showConfirm = false
                    applyNow()
                }, onDismiss: { showConfirm = false })
        }
    }
}

// MARK: Channels tab

private struct ChannelsTab: View {
    let sender: RadioSender
    @Environment(GatewayModel.self) private var model
    @State private var editing: MeshtasticProtocol.MeshChannel?
    @State private var pendingSave: (MeshtasticProtocol.MeshChannel, MeshtasticProtocol.MeshChannel)?

    // Only what the user changed is written over the radio's own ChannelSettings.
    private func save(_ original: MeshtasticProtocol.MeshChannel, _ updated: MeshtasticProtocol.MeshChannel) {
        var settings = original.settings ?? Meshtastic_ChannelSettings()
        if original.settings == nil { settings.psk = Data(original.psk) }
        if updated.name != original.name { settings.name = updated.name }
        if updated.uplinkEnabled != original.uplinkEnabled { settings.uplinkEnabled = updated.uplinkEnabled }
        if updated.downlinkEnabled != original.downlinkEnabled { settings.downlinkEnabled = updated.downlinkEnabled }
        var channel = Meshtastic_Channel()
        channel.index = Int32(updated.index)
        channel.role = Meshtastic_Channel.Role(rawValue: updated.role) ?? .disabled
        channel.settings = settings
        sender.send(MeshtasticProtoAdapter.buildAdminSetChannel(myNodeNum: sender.myNodeNum, channel: channel))
        sender.toast("Sent to the radio.")
        sender.readBack()
    }

    var body: some View {
        let channels = model.channels
        if channels.isEmpty {
            NotLoaded(connected: sender.connected)
        } else {
            Hint("Nodes hear each other on a channel when they share its name and key.")
            ForEach(channels, id: \.index) { ch in
                let key = RadioWords.channelKey(ch.psk, role: ch.role)
                ConfigCard("Channel \(ch.index)") {
                    Text(ch.name.isEmpty ? (ch.role == 1 ? "Default name" : "No name") : ch.name).msText(.bodyLarge)
                    Text("\(RadioWords.roleLabel(ch.role)). \(RadioWords.roleHint(ch.role))")
                        .msText(.bodySmall, color: ch.role == 0 ? MSColors.textMuted : MSColors.textSecondary)
                    if ch.role != 0 {
                        Text(key.label).msText(.bodyMedium, color: MSColors.textSecondary).padding(.top, 4)
                        Hint(key.hint)
                        if ch.uplinkEnabled || ch.downlinkEnabled {
                            Text(
                                [ch.uplinkEnabled ? "Send to MQTT" : nil, ch.downlinkEnabled ? "Receive from MQTT" : nil].compactMap { $0 }
                                    .joined(separator: ", ")
                            )
                            .msText(.bodySmall, color: MSColors.textSecondary).padding(.top, 4)
                        }
                    }
                    MSOutlinedButton("Edit", enabled: sender.canSend) { editing = ch }.padding(.top, 8)
                }
            }
            if let ch = editing {
                ChannelEditDialog(
                    channel: ch, canSend: sender.canSend,
                    onSave: { updated in
                        editing = nil
                        let roleChanged = updated.role != ch.role
                        let renamedInUse = updated.name != ch.name && ch.role != 0
                        if roleChanged || renamedInUse { pendingSave = (ch, updated) } else { save(ch, updated) }
                    }, onDismiss: { editing = nil })
            }
            if let (original, updated) = pendingSave {
                ConfirmDialog(
                    title: "Change channel \(original.index)?",
                    message:
                        "Changing a channel's name or role can cut you off from nodes that still use the old one until they change too.",
                    confirmLabel: "Change",
                    onConfirm: {
                        pendingSave = nil
                        save(original, updated)
                    }, onDismiss: { pendingSave = nil })
            }
        }
    }
}

private struct ChannelEditDialog: View {
    let channel: MeshtasticProtocol.MeshChannel
    let canSend: Bool
    let onSave: (MeshtasticProtocol.MeshChannel) -> Void
    let onDismiss: () -> Void
    @State private var name: String
    @State private var role: Int
    @State private var uplinkEnabled: Bool
    @State private var downlinkEnabled: Bool
    @State private var showRolePicker = false

    init(
        channel: MeshtasticProtocol.MeshChannel, canSend: Bool, onSave: @escaping (MeshtasticProtocol.MeshChannel) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.channel = channel
        self.canSend = canSend
        self.onSave = onSave
        self.onDismiss = onDismiss
        _name = State(initialValue: channel.name)
        _role = State(initialValue: channel.role)
        _uplinkEnabled = State(initialValue: channel.uplinkEnabled)
        _downlinkEnabled = State(initialValue: channel.downlinkEnabled)
    }

    var body: some View {
        // Channel 0 is always the main channel, and there is only one: the picker cannot break that.
        let roleOptions: [(Int, String)] =
            (channel.role == 1 ? [(1, RadioWords.roleLabel(1))] : []) + [(2, RadioWords.roleLabel(2)), (0, RadioWords.roleLabel(0))]
        MSAlertDialog(
            "Channel \(channel.index)", onDismiss: onDismiss,
            content: {
                VStack(alignment: .leading, spacing: 8) {
                    MSOutlinedTextField(text: $name, label: "Channel name")
                        .onChange(of: name) { _, v in if v.count > 11 { name = String(v.prefix(11)) } }
                    if channel.index == 0 {
                        Text(RadioWords.roleLabel(1)).msText(.bodyMedium)
                        Hint("Channel 0 is always the main channel.")
                    } else {
                        MSOutlinedButton(RadioWords.roleLabel(role)) { showRolePicker = true }
                        Hint(RadioWords.roleHint(role))
                    }
                    ToggleRow(
                        "Send to MQTT", isOn: $uplinkEnabled,
                        hint: "Copies this channel's messages to an internet server when the node has internet.")
                    ToggleRow("Receive from MQTT", isOn: $downlinkEnabled, hint: "Brings messages from that server onto this channel.")
                    if showRolePicker {
                        ForEach(roleOptions, id: \.0) { code, label in
                            Button {
                                role = code
                                showRolePicker = false
                            } label: {
                                Text(label).msText(.bodyMedium, color: role == code ? MSColors.textPrimary : MSColors.textSecondary)
                                    .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: MSSpace.touch, alignment: .leading)
                                    .background(role == code ? MSColors.surfaceLight : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            },
            buttons: {
                MSTextButton("Cancel", color: MSColors.textSecondary, action: onDismiss)
                MSFilledButton("Save", fullWidth: false) {
                    var c = channel
                    c.name = name.trimmingCharacters(in: .whitespaces)
                    c.role = channel.index == 0 ? channel.role : role
                    c.uplinkEnabled = uplinkEnabled
                    c.downlinkEnabled = downlinkEnabled
                    onSave(c)
                }
                .disabled(!canSend)
            })
    }
}

// MARK: Position tab

private struct PositionTab: View {
    let sender: RadioSender
    @Environment(GatewayModel.self) private var model
    @State private var gpsEnabled = false
    @State private var fixedPosition = false
    @State private var broadcastSecs = ""
    @State private var smartEnabled = false

    var body: some View {
        if let loaded = model.positionConfig {
            let secs = Int(broadcastSecs)
            let changed =
                gpsEnabled != loaded.gpsEnabled || fixedPosition != loaded.fixedPosition
                || (secs != nil && secs != Int(loaded.positionBroadcastSecs))
                || smartEnabled != loaded.positionBroadcastSmartEnabled
            Group {
                ConfigCard("GPS") {
                    ToggleRow("GPS on", isOn: $gpsEnabled, enabled: sender.canSend)
                    ToggleRow(
                        "Fixed position", isOn: $fixedPosition, hint: "Use a position set by hand instead of the GPS.",
                        enabled: sender.canSend)
                }
                ConfigCard("Sharing") {
                    Hint("How often the node shares its position, in seconds. 0 uses the default, 15 minutes.")
                    NumberField(
                        text: $broadcastSecs, label: "Every (seconds)", digits: 5, enabled: sender.canSend,
                        error: secs == nil ? "Enter a number of seconds." : nil
                    )
                    .padding(.top, 8)
                    ToggleRow("Smart sharing", isOn: $smartEnabled, hint: "Shares sooner when the node moves.", enabled: sender.canSend)
                        .padding(.top, 8)
                }
                MSFilledButton("Apply") {
                    var b = loaded
                    if gpsEnabled != loaded.gpsEnabled { b.gpsEnabled = gpsEnabled }
                    if fixedPosition != loaded.fixedPosition { b.fixedPosition = fixedPosition }
                    if let secs, secs != Int(loaded.positionBroadcastSecs) { b.positionBroadcastSecs = UInt32(secs) }
                    if smartEnabled != loaded.positionBroadcastSmartEnabled { b.positionBroadcastSmartEnabled = smartEnabled }
                    var config = Meshtastic_Config()
                    config.position = b
                    sender.send(MeshtasticProtoAdapter.buildAdminSetConfig(myNodeNum: sender.myNodeNum, config: config))
                    sender.toast(restarts)
                }
                .disabled(!(sender.canSend && changed && secs != nil))
                Hint("Applying restarts the node. The phone reconnects by itself.")
            }
            .onChange(of: loaded, initial: true) { _, l in
                gpsEnabled = l.gpsEnabled
                fixedPosition = l.fixedPosition
                broadcastSecs = "\(l.positionBroadcastSecs)"
                smartEnabled = l.positionBroadcastSmartEnabled
            }
        } else {
            NotLoaded(connected: sender.connected)
        }
    }
}

// MARK: Bluetooth tab

private struct BluetoothTab: View {
    let sender: RadioSender
    @Environment(GatewayModel.self) private var model
    @State private var btEnabled = false
    @State private var pairingMode = 0
    @State private var fixedPin = ""
    @State private var showModePicker = false
    @State private var showConfirm = false

    var body: some View {
        if let loaded = model.bluetoothConfig {
            let pin = Int(fixedPin)
            let pinOk = pairingMode != 1 || (fixedPin.count == 6 && pin != nil)
            let pinChanged = pairingMode == 1 && pin != nil && pin != Int(loaded.fixedPin)
            let changed = btEnabled != loaded.enabled || pairingMode != loaded.mode.rawValue || pinChanged
            let applyNow = {
                var b = loaded
                if btEnabled != loaded.enabled { b.enabled = btEnabled }
                if pairingMode != loaded.mode.rawValue {
                    b.mode = Meshtastic_Config.BluetoothConfig.PairingMode(rawValue: pairingMode) ?? b.mode
                }
                if pinChanged, let pin { b.fixedPin = UInt32(pin) }
                var config = Meshtastic_Config()
                config.bluetooth = b
                sender.send(MeshtasticProtoAdapter.buildAdminSetConfig(myNodeNum: sender.myNodeNum, config: config))
                sender.toast(restarts)
            }
            Group {
                ConfigCard("Bluetooth") {
                    ToggleRow("Bluetooth on", isOn: $btEnabled, hint: "This is how your phone talks to the node.", enabled: sender.canSend)
                }
                ConfigCard("Pairing") {
                    MSOutlinedButton(RadioWords.pairingLabel(pairingMode), enabled: sender.canSend) { showModePicker = true }
                    if pairingMode == 2 { Hint("Anyone nearby can pair with the node.").padding(.top, 4) }
                    if pairingMode == 1 {
                        NumberField(
                            text: $fixedPin, label: "PIN", digits: 6, enabled: sender.canSend, error: pinOk ? nil : "Enter 6 digits."
                        ).padding(.top, 8)
                    }
                }
                MSFilledButton("Apply") { if loaded.enabled && !btEnabled { showConfirm = true } else { applyNow() } }
                    .disabled(!(sender.canSend && changed && pinOk))
                Hint("Applying restarts the node. The phone reconnects by itself.")
                if showModePicker {
                    PickerDialog(
                        title: "Pairing", options: [0, 1, 2].map { ($0, RadioWords.pairingLabel($0)) }, selected: pairingMode,
                        onSelect: {
                            pairingMode = $0
                            showModePicker = false
                        }, onDismiss: { showModePicker = false })
                }
                if showConfirm {
                    ConfirmDialog(
                        title: "Turn off Bluetooth?",
                        message: "You will lose the connection to this node from the phone, and with it the satellite modem. "
                            + "Turning it back on then needs the node itself or a USB cable.",
                        confirmLabel: "Turn off", danger: true,
                        onConfirm: {
                            showConfirm = false
                            applyNow()
                        }, onDismiss: { showConfirm = false })
                }
            }
            .onChange(of: loaded, initial: true) { _, l in
                btEnabled = l.enabled
                pairingMode = l.mode.rawValue
                fixedPin = l.fixedPin != 0 ? String(format: "%06d", l.fixedPin) : ""
            }
        } else {
            NotLoaded(connected: sender.connected)
        }
    }
}

// MARK: WiFi tab

private struct NetworkTab: View {
    let sender: RadioSender
    @Environment(GatewayModel.self) private var model
    @State private var wifiEnabled = false
    @State private var wifiSsid = ""
    @State private var wifiPsk = ""
    @State private var showPassword = false

    var body: some View {
        if let loaded = model.networkConfig {
            if let md = model.deviceMetadata, !md.hasWifi {
                Text("This node has no WiFi.").msText(.bodyMedium, color: MSColors.textSecondary).padding(.vertical, 8)
            } else {
                let changed = wifiEnabled != loaded.wifiEnabled || wifiSsid != loaded.wifiSsid || wifiPsk != loaded.wifiPsk
                Group {
                    ConfigCard("WiFi") {
                        ToggleRow(
                            "WiFi on", isOn: $wifiEnabled, hint: "Lets the node reach the internet, for MQTT, when a network is in range.",
                            enabled: sender.canSend)
                        if wifiEnabled {
                            MSOutlinedTextField(text: $wifiSsid, label: "Network name").padding(.top, 8)
                                .onChange(of: wifiSsid) { _, v in if v.count > 32 { wifiSsid = String(v.prefix(32)) } }
                            MSOutlinedTextField(
                                text: $wifiPsk, label: "Password", secure: !showPassword,
                                trailing: {
                                    MSIconButton(
                                        Image(systemName: showPassword ? "eye.slash" : "eye"),
                                        label: showPassword ? "Hide password" : "Show password",
                                        size: 32, glyph: 18
                                    ) { showPassword.toggle() }
                                }
                            )
                            .padding(.top, 8)
                            .onChange(of: wifiPsk) { _, v in if v.count > 64 { wifiPsk = String(v.prefix(64)) } }
                        }
                    }
                    MSFilledButton("Apply") {
                        var b = loaded
                        if wifiEnabled != loaded.wifiEnabled { b.wifiEnabled = wifiEnabled }
                        if wifiSsid != loaded.wifiSsid { b.wifiSsid = wifiSsid }
                        if wifiPsk != loaded.wifiPsk { b.wifiPsk = wifiPsk }
                        var config = Meshtastic_Config()
                        config.network = b
                        sender.send(MeshtasticProtoAdapter.buildAdminSetConfig(myNodeNum: sender.myNodeNum, config: config))
                        sender.toast(restarts)
                    }
                    .disabled(!(sender.canSend && changed))
                    Hint("Applying restarts the node. The phone reconnects by itself.")
                }
                .onChange(of: loaded, initial: true) { _, l in
                    wifiEnabled = l.wifiEnabled
                    wifiSsid = l.wifiSsid
                    wifiPsk = l.wifiPsk
                }
            }
        } else {
            NotLoaded(connected: sender.connected)
        }
    }
}

// MARK: Restart and reset tab

private struct DeviceAdminTab: View {
    let sender: RadioSender
    @Environment(GatewayModel.self) private var model
    @State private var rebootDelay = "5"
    @State private var showFactoryReset = false
    @State private var showReboot = false
    @State private var showShutdown = false
    @State private var showNodeDbReset = false

    var body: some View {
        let canShutdown = model.deviceMetadata?.canShutdown != false
        let secs = Int(rebootDelay) ?? 5
        ConfigCard("Clock") {
            Hint("Sets the node's clock to the phone's time.")
            MSOutlinedButton("Set the clock", enabled: sender.canSend) {
                sender.send(
                    MeshtasticProtoAdapter.buildAdminSetTime(myNodeNum: sender.myNodeNum, unixSec: Int64(Date().timeIntervalSince1970)))
                sender.toast("Sent to the radio.")
            }
            .padding(.top, 8)
        }
        ConfigCard("Restart") {
            Hint("Restarts the node after a delay. The phone reconnects by itself.")
            NumberField(text: $rebootDelay, label: "Delay (seconds)", digits: 4, enabled: sender.canSend, error: nil).padding(.top, 8)
            MSOutlinedButton("Restart the node", enabled: sender.canSend) { showReboot = true }.padding(.top, 8)
        }
        ConfigCard("Switch off") {
            Hint(
                canShutdown
                    ? "Switches the node off. Someone has to switch it on again at the node." : "This node cannot switch itself off.")
            MSOutlinedButton("Switch off the node", enabled: sender.canSend && canShutdown) { showShutdown = true }.padding(.top, 8)
        }
        ConfigCard("Forget heard nodes") {
            Hint("Clears the node's list of the nodes it has heard. They come back as they transmit again.")
            MSOutlinedButton("Forget heard nodes", enabled: sender.canSend) { showNodeDbReset = true }.padding(.top, 8)
        }
        ConfigCard("Factory reset") {
            Text("Erases every setting on the node and restores the factory ones. This cannot be undone.").msText(
                .bodySmall, color: MSColors.red)
            MSFilledButton("Factory reset", container: MSColors.red) { showFactoryReset = true }.padding(.top, 8).disabled(!sender.canSend)
        }
        if showFactoryReset {
            ConfirmDialog(
                title: "Erase every setting on your node?",
                message:
                    "Its region, channels, keys and name go back to the factory ones and it restarts. It will no longer hear your mesh "
                    + "until it is set up again, and the phone may have to pair with it again. This cannot be undone.",
                confirmLabel: "Erase", danger: true,
                onConfirm: {
                    showFactoryReset = false
                    sender.send(MeshtasticProtoAdapter.buildAdminFactoryReset(myNodeNum: sender.myNodeNum))
                    sender.toast("Sent to the radio. It erases its settings and restarts.")
                }, onDismiss: { showFactoryReset = false })
        }
        if showReboot {
            ConfirmDialog(
                title: "Restart your node?",
                message:
                    "In \(secs) seconds the phone loses the node, the mesh and the satellite modem until the node is back, usually within "
                    + "a minute. The phone reconnects by itself.",
                confirmLabel: "Restart",
                onConfirm: {
                    showReboot = false
                    sender.send(MeshtasticProtoAdapter.buildAdminReboot(myNodeNum: sender.myNodeNum, delaySecs: secs))
                    sender.toast("Sent to the radio. It restarts in \(secs) seconds.")
                }, onDismiss: { showReboot = false })
        }
        if showShutdown {
            ConfirmDialog(
                title: "Switch off your node?",
                message: "The phone loses the connection to it, and with it the mesh and the satellite modem, until someone switches it on "
                    + "again at the node.",
                confirmLabel: "Switch off", danger: true,
                onConfirm: {
                    showShutdown = false
                    sender.send(MeshtasticProtoAdapter.buildAdminShutdown(myNodeNum: sender.myNodeNum, delaySecs: 5))
                    sender.toast("Sent to the radio. It switches off in 5 seconds.")
                }, onDismiss: { showShutdown = false })
        }
        if showNodeDbReset {
            ConfirmDialog(
                title: "Forget heard nodes?",
                message: "Your node clears its list of the nodes it has heard. They come back as they transmit again.",
                confirmLabel: "Forget",
                onConfirm: {
                    showNodeDbReset = false
                    sender.send(MeshtasticProtoAdapter.buildAdminNodeDbReset(myNodeNum: sender.myNodeNum))
                    sender.toast("Sent to the radio.")
                }, onDismiss: { showNodeDbReset = false })
        }
    }
}

// MARK: Shared pieces

private struct ConfigCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).msText(.titleSmall).padding(.bottom, 4)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .msCard()
    }
}

private struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).msText(.bodySmall, color: MSColors.textMuted) }
}

private struct RadioInfoRow: View {
    let label: String
    let value: String
    let mono: Bool
    init(_ label: String, _ value: String, mono: Bool = false) {
        self.label = label
        self.value = value
        self.mono = mono
    }
    var body: some View {
        HStack {
            Text(label).msText(.bodySmall, color: MSColors.textMuted)
            Spacer(minLength: 12)
            Text(value).msText(.bodySmall, mono: mono, color: MSColors.textSecondary)
        }
        .padding(.vertical, 2)
    }
}

private struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool
    var hint: String?
    var enabled = true
    init(_ label: String, isOn: Binding<Bool>, hint: String? = nil, enabled: Bool = true) {
        self.label = label
        _isOn = isOn
        self.hint = hint
        self.enabled = enabled
    }
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text(label).msText(.bodyMedium)
                if let hint { Hint(hint) }
            }
            Spacer(minLength: 12)
            MSSwitch(isOn: $isOn, label: label, enabled: enabled)
        }
        .frame(minHeight: MSSpace.touch)
    }
}

/// A digits-only field with a supporting line, red on error.
private struct NumberField: View {
    @Binding var text: String
    let label: String
    let digits: Int
    let enabled: Bool
    let error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MSOutlinedTextField(text: $text, label: label, keyboard: .numberPad)
                .onChange(of: text) { _, v in
                    let d = String(v.filter(\.isNumber).prefix(digits))
                    if d != v { text = d }
                }
                .disabled(!enabled)
            if let error { Text(error).msText(.bodySmall, color: MSColors.red) }
        }
    }
}

private struct StatusBanner: View {
    let text: String
    let color: Color
    init(_ text: String, _ color: Color) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text).msText(.bodySmall, color: color).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.3), lineWidth: 1))
    }
}

private struct ConfirmDialog: View {
    let title: String
    let message: String
    let confirmLabel: String
    var danger = false
    let onConfirm: () -> Void
    let onDismiss: () -> Void
    init(
        title: String, message: String, confirmLabel: String, danger: Bool = false, onConfirm: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmLabel = confirmLabel
        self.danger = danger
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
    }
    var body: some View {
        MSAlertDialog(
            title, onDismiss: onDismiss, content: { Text(message).msText(.bodyMedium, color: MSColors.textSecondary) },
            buttons: {
                MSTextButton("Cancel", color: MSColors.textSecondary, action: onDismiss)
                MSFilledButton(confirmLabel, container: danger ? MSColors.red : MSColors.signalOrange, fullWidth: false, action: onConfirm)
            })
    }
}

private struct PickerDialog: View {
    let title: String
    let options: [(Int, String)]
    let selected: Int
    let onSelect: (Int) -> Void
    let onDismiss: () -> Void
    var body: some View {
        MSAlertDialog(
            title, onDismiss: onDismiss,
            content: {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(options, id: \.0) { code, label in
                            let on = code == selected
                            Button {
                                onSelect(code)
                            } label: {
                                Text(label).msText(.bodyMedium, color: on ? MSColors.textPrimary : MSColors.textSecondary)
                                    .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: MSSpace.touch, alignment: .leading)
                                    .background(on ? MSColors.surfaceLight : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 400)
            },
            buttons: { MSTextButton("Cancel", color: MSColors.textSecondary, action: onDismiss) })
    }
}
