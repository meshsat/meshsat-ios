// Mirrors the section cards of ui/screens/SettingsScreen.kt other than the node's (which is
// SettingsNodeSection.swift) and Safety's SOS card (SosScreens.swift): Satellite, Hub,
// Messaging, the check-in timer, SMS and Diagnostics. Same titles, same words, same order.
// Android-only cards are named here, not hidden: the RockBLOCK 9704 on an HC-05 needs
// Bluetooth Classic, which iOS has not; SMS permissions do not exist on iOS.
import MeshSatEngine
import MeshSatHub
import MeshSatMeshtastic
import MeshSatPlatform
import MeshSatWire
import SwiftUI

// MARK: Satellite

public struct SettingsSatelliteSection: View {
    @Environment(GatewayModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    @Environment(Router.self) private var router

    public init() {}

    private var statusText: String {
        let nodePipe = settings.bool(SettingsKey.iridiumNodePipeEnabled)
        switch model.modemState {
        case .connected: return "Connected (Signal: \(model.modemSignal)/5)"
        case .connecting: return "Checking the modem..."
        case .disconnected:
            if !nodePipe { return "Off: the node keeps its modem" }
            if !settings.pipePresent { return "No MeshSat node connected" }
            if settings.pipeOwner == .node { return "The node is using its modem" }
            return "Waiting for the node"
        }
    }

    public var body: some View {
        ScrollView {
            // SetupPageLinks: the screen that belongs with these settings, at the top.
            NavRow(icon: MSIcon.schedule, title: "Satellite passes", detail: "When satellites are high overhead") {
                router.navigate(.passes)
            }
            VStack(spacing: MSSpace.screen) {
                SectionCard("Satellite modem on the node") {
                    ConnectionStatusRow(
                        label: "Status", connected: model.modemState == .connected, statusText: statusText, color: MSColors.iridium)
                    SettingRow("Use the node's modem") {
                        MSSwitch(isOn: settings.binding(SettingsKey.iridiumNodePipeEnabled), label: "Use the node's modem")
                    }
                    if model.modemState == .connected {
                        if !settings.modemInfo.manufacturer.isEmpty { InfoRow("Manufacturer", settings.modemInfo.manufacturer) }
                        if !settings.modemInfo.model.isEmpty { InfoRow("Model", settings.modemInfo.model) }
                        if !settings.modemInfo.imei.isEmpty { InfoRow("IMEI", settings.modemInfo.imei) }
                        MSFilledButton("Poll Signal", container: MSColors.teal) {
                            Task {
                                // A fresh reading (AT+CSQ) can take up to a minute.
                                let sig = await settings.pollSignal()
                                model.showToast("Signal: \(sig)/5")
                            }
                        }
                        CheckMailboxButton()
                    } else if !settings.pipePresent {
                        Text(
                            "The RockBLOCK 9603 is reached through your MeshSat node. "
                                + "Connect the node under Your MeshSat node; its modem appears here."
                        )
                        .msText(.bodySmall, color: MSColors.textMuted)
                    }
                }
                Text(
                    "A RockBLOCK 9704 on an HC-05 needs Bluetooth Classic, which iPhones do not have. "
                        + "MeshSat iOS uses the modem on the node."
                )
                .msText(.bodySmall, color: MSColors.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(MSSpace.screen)
        }
        .background(MSColors.bg)
    }
}

/// Mirrors ui/components/CheckMailboxButton.kt: one SBDIX to fetch waiting MT messages, with its
/// outcome in words (MESHSAT-1236).
struct CheckMailboxButton: View {
    @Environment(GatewayModel.self) private var model
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MSOutlinedButton(model.mailboxRunning ? "Checking the mailbox..." : "Check for messages", enabled: !model.mailboxRunning) {
                if !settings.checkMailbox() { model.showToast("The modem is busy, try again in a moment.") }
            }
            if let line = model.mailboxResultText { Text(line).msText(.bodySmall, color: MSColors.textSecondary) }
        }
    }
}

// MARK: Hub

public struct SettingsHubSection: View {
    @Environment(GatewayModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    @State private var scanning = false
    @State private var pingResult = ""
    @State private var pinging = false
    @State private var showDetails = false
    @State private var url = ""
    @State private var bridgeId = ""
    @State private var callsign = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var healthInterval = ""
    @State private var relayTarget = ""
    @State private var relayUrl = ""

    public init() {}

    private var ledColor: Color {
        switch settings.hubState {
        case .connected: MSColors.green
        case .connecting: MSColors.amber
        case .error: MSColors.red
        default: MSColors.textMuted
        }
    }

    private var statusLabel: String {
        let enabled = settings.bool(SettingsKey.hubEnabled)
        if !enabled { return "Switched off" }
        switch settings.hubState {
        case .connected: return "Connected as \(settings.hubBridgeIdLive.isEmpty ? bridgeId : settings.hubBridgeIdLive)"
        case .connecting: return "Connecting"
        case .error: return "Cannot reach the Hub"
        case .disconnected: return "Not connected"
        case nil: return "Not set up: scan the Hub's QR code"
        }
    }

    private func loadFields() {
        url = settings.string(SettingsKey.hubUrl)
        bridgeId = settings.string(SettingsKey.hubBridgeId)
        callsign = settings.string(SettingsKey.hubCallsign)
        username = settings.string(SettingsKey.hubUsername)
        password = settings.hubPassword
        healthInterval = settings.string(SettingsKey.hubHealthInterval)
        relayTarget = settings.string(SettingsKey.hubRelayTarget)
        relayUrl = settings.string(SettingsKey.hubRelayUrl)
    }

    public var body: some View {
        ScrollView {
            SectionCard("Hub connection") {
                HStack {
                    HStack(spacing: 8) {
                        Circle().fill(ledColor).frame(width: 10, height: 10)
                        Text(statusLabel).msText(.bodyMedium)
                    }
                    Spacer(minLength: 8)
                    MSSwitch(isOn: settings.binding(SettingsKey.hubEnabled), label: "Use the Hub")
                }
                // A provisioning claim still waiting for the Hub (MESHSAT-1306): shown here too,
                // for when its dialog was hidden.
                if case .waiting(_, _, let startedMs, _) = model.provisionState {
                    HStack(spacing: 8) {
                        MSCircularProgress(size: 14, stroke: 2)
                        WaitedSeconds(startedMs: startedMs)
                    }
                }
                if settings.bool(SettingsKey.hubEnabled), settings.hubState == .error, !settings.hubLastError.isEmpty {
                    Text("Why: \(settings.hubLastError)").msText(.bodySmall, color: MSColors.red)
                }
                MSFilledButton("Scan the Hub's QR code", container: MSColors.teal) { scanning = true }
                Text(
                    "On the Hub, open Fleet and add a bridge for this phone: "
                        + "the QR code it shows fills in everything, certificates included."
                )
                .msText(.bodySmall, color: MSColors.textMuted)
                HStack(spacing: 8) {
                    MSOutlinedButton("Test the connection", enabled: !pinging) {
                        pinging = true
                        pingResult = "..."
                        Task {
                            if let ms = await settings.pingHub() { pingResult = "\(ms)ms" } else { pingResult = "Not connected" }
                            pinging = false
                        }
                    }
                    Text(pingResult).msText(.bodyMedium, color: pingResult.hasSuffix("ms") ? MSColors.green : MSColors.textMuted)
                }
                MSTextButton(showDetails ? "Hide connection details" : "Connection details", color: MSColors.offWhite) {
                    if !showDetails { loadFields() }
                    showDetails.toggle()
                }
                if showDetails { details }
                Text(
                    "The Hub is the control room: with it, this phone shows in the fleet and on the map, "
                        + "and SOS alerts reach it over the internet as well as by satellite."
                )
                .msText(.bodySmall, color: MSColors.textMuted)
            }
            .padding(MSSpace.screen)
        }
        .background(MSColors.bg)
        .fullScreenCover(isPresented: $scanning) {
            QRScannerSheet(prompt: "Scan the Hub's QR code") { code in
                scanning = false
                guard let code else { return }
                if ProvisionImporter.isProvisionUrl(code) {
                    settings.provisionFromQr(code)
                } else {
                    model.showToast("That is not a Hub provisioning code")
                }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            MSOutlinedTextField(
                text: $url, placeholder: "wss://mqtt-hub.meshsat.net/mqtt", label: "Hub MQTT URL", focusedBorder: MSColors.teal,
                keyboard: .URL)
            HStack(spacing: 8) {
                MSOutlinedTextField(text: $bridgeId, placeholder: "auto", label: "Bridge ID", focusedBorder: MSColors.teal)
                MSOutlinedTextField(text: $callsign, placeholder: "TAK callsign", label: "Callsign", focusedBorder: MSColors.teal)
            }
            HStack(spacing: 8) {
                MSOutlinedTextField(text: $username, label: "Username", focusedBorder: MSColors.teal)
                MSOutlinedTextField(
                    text: $password, label: "Password", secure: !showPassword, focusedBorder: MSColors.teal,
                    trailing: {
                        MSIconButton(
                            showPassword ? MSIcon.lockOpen : MSIcon.lock, label: showPassword ? "Hide password" : "Show password", size: 32,
                            glyph: 18
                        ) {
                            showPassword.toggle()
                        }
                    })
            }
            MSOutlinedTextField(
                text: $healthInterval, label: "Health interval (seconds)", focusedBorder: MSColors.teal, keyboard: .numberPad)
            HStack {
                Text("Reach a kit through the Hub").msText(.bodyMedium)
                Spacer(minLength: 8)
                // Off, and not switchable, until there is a kit to relay to (MESHSAT-1249).
                MSSwitch(
                    isOn: Binding(
                        get: { settings.bool(SettingsKey.hubRelayEnabled) && !relayTarget.isEmpty },
                        set: { settings.set(SettingsKey.hubRelayEnabled, $0) }),
                    label: "Reach a kit through the Hub", enabled: !relayTarget.isEmpty)
            }
            HStack(spacing: 8) {
                MSOutlinedTextField(text: $relayTarget, placeholder: "kit-a", label: "Kit's bridge ID", focusedBorder: MSColors.teal)
                MSOutlinedTextField(
                    text: $relayUrl, placeholder: "derived from MQTT URL", label: "Hub API URL (optional)", focusedBorder: MSColors.teal,
                    keyboard: .URL)
            }
            MSFilledButton("Save", container: MSColors.teal, fullWidth: false) {
                settings.set(SettingsKey.hubUrl, url)
                settings.set(SettingsKey.hubBridgeId, bridgeId)
                settings.set(SettingsKey.hubCallsign, callsign)
                settings.set(SettingsKey.hubUsername, username)
                settings.setHubPassword(password)
                settings.set(SettingsKey.hubHealthInterval, healthInterval.filter { $0.isNumber }.prefix(4).description)
                settings.set(SettingsKey.hubRelayTarget, relayTarget)
                settings.set(SettingsKey.hubRelayUrl, relayUrl)
                settings.restartHub()
                model.showToast("Saved. The Hub connection starts again with them.")
            }
        }
    }
}

// MARK: Messaging

public struct SettingsMessagingSection: View {
    @Environment(GatewayModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    @State private var keyInput = ""
    @State private var showKey = false
    @State private var scanning = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: MSSpace.screen) {
                SectionCard("Encryption") {
                    SettingRow("Encryption enabled") {
                        MSSwitch(isOn: settings.binding(SettingsKey.encryptionEnabled), label: "Encryption enabled")
                    }
                    SettingRow("Auto-decrypt incoming SMS") {
                        MSSwitch(isOn: settings.binding(SettingsKey.autoDecryptSms), label: "Auto-decrypt incoming SMS")
                    }
                    MSOutlinedTextField(
                        text: $keyInput, label: "AES-256-GCM Key (hex)", secure: !showKey, focusedBorder: MSColors.teal,
                        keyboard: .asciiCapable)
                    HStack(spacing: 8) {
                        MSFilledButton(showKey ? "Hide" : "Show", container: MSColors.surface, labelColor: MSColors.offWhite) {
                            showKey.toggle()
                        }
                        MSFilledButton("Generate", container: MSColors.amber) {
                            keyInput = AesGcmCrypto.generateKey()
                            settings.setEncryptionKey(keyInput)
                            model.showToast("Key generated")
                        }
                        MSFilledButton("Save", container: MSColors.teal) {
                            settings.setEncryptionKey(keyInput)
                            model.showToast("Key saved")
                        }
                    }
                    HStack(spacing: 8) {
                        MSFilledButton("Copy", container: MSColors.surface, labelColor: MSColors.offWhite) {
                            if !keyInput.isEmpty {
                                UIPasteboard.general.string = keyInput
                                model.showToast("Key copied to clipboard")
                            }
                        }
                        MSFilledButton("Paste", container: MSColors.surface, labelColor: MSColors.offWhite) {
                            let clip = UIPasteboard.general.string ?? ""
                            if AesGcmCrypto.isValidHexKey(clip) {
                                keyInput = clip
                                settings.setEncryptionKey(clip)
                                model.showToast("Key imported from clipboard")
                            } else {
                                model.showToast("Clipboard doesn't contain a valid 64-char hex key")
                            }
                        }
                        ShareLink(item: keyInput, subject: Text("MeshSat Encryption Key")) {
                            Text("Share").msText(.bodySmall, color: MSColors.offWhite)
                                .padding(.horizontal, 24).frame(maxWidth: .infinity, minHeight: 40)
                                .background(MSColors.surface, in: Capsule())
                        }
                        .disabled(keyInput.isEmpty)
                    }
                    MSFilledButton("Scan QR Code (Hub Key Sync)", container: MSColors.teal) { scanning = true }
                    Text(
                        "Fallback key, used when no per-conversation key is set. To sync with the Hub: Hub dashboard > Devices > "
                            + "select device > Generate Key, then scan the QR code or paste the 64-char hex key."
                    )
                    .msText(.bodySmall, color: MSColors.textMuted)
                }
                SectionCard("Message compression") {
                    Text(
                        "Only for links where the other end is MeshSat too: anyone else sees a line of letters. MSVQ-SC keeps the "
                            + "meaning, not the exact words. Mesh messages always go out as typed, because a mesh channel is shared with "
                            + "other radios. Compressed messages coming in are always read, whatever is set here."
                    )
                    .msText(.bodySmall, color: MSColors.textMuted)
                    ForEach([("sms", "SMS"), ("iridium", "Iridium SBD"), ("mqtt", "MQTT (Hub)")], id: \.0) { channel, label in
                        HStack {
                            Text(label).msText(.bodyMedium)
                            Spacer(minLength: 8)
                            ModeChips([("off", "Off"), ("msvqsc", "MSVQ-SC")], selected: settings.compressMode(channel)) {
                                settings.setCompressMode(channel, $0)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    if settings.compressMode("sms") == "msvqsc" || settings.compressMode("iridium") == "msvqsc" {
                        Text("MSVQ-SC stages (fewer = smaller, lower fidelity)").msText(.bodySmall, color: MSColors.textMuted).padding(
                            .top, 8)
                        ModeChips(
                            [("2", "2 (5B)"), ("3", "3 (7B)"), ("4", "4 (9B)"), ("6", "6 (13B)"), ("8", "8 (17B)")],
                            selected: settings.string(SettingsKey.msvqscStages)
                        ) { settings.set(SettingsKey.msvqscStages, $0) }
                    }
                    Text("MSVQ-SC itself lands with MESHSAT-1329; until then a message set to it goes out as typed.")
                        .msText(.bodySmall, color: MSColors.amber)
                }
                SectionCard("Quick messages") {
                    Text("The brevity codes (2 bytes: 0xCA + message ID) land with the canned codebook port.").msText(
                        .bodySmall, color: MSColors.textMuted)
                }
            }
            .padding(MSSpace.screen)
        }
        .background(MSColors.bg)
        .onAppear { keyInput = settings.encryptionKey }
        .fullScreenCover(isPresented: $scanning) {
            QRScannerSheet(prompt: "Scan Hub encryption key QR code") { code in
                scanning = false
                guard let code else { return }
                if ProvisionImporter.isProvisionUrl(code) {
                    settings.provisionFromQr(code)
                } else if AesGcmCrypto.isValidHexKey(code) {
                    keyInput = code
                    settings.setEncryptionKey(code)
                    model.showToast("Key imported via QR")
                } else if code.hasPrefix("meshsat://key/") {
                    model.showToast("Signed key bundles land with the KeyBundleImporter port")
                } else {
                    model.showToast("QR code doesn't contain a valid key or bundle")
                }
            }
        }
    }
}

// MARK: Safety

public struct SettingsSafetySection: View {
    @Environment(GatewayModel.self) private var model
    @Environment(SettingsModel.self) private var settings

    @Environment(Router.self) private var router

    public init() {}

    public var body: some View {
        ScrollView {
            // SetupPageLinks: the screen that belongs with these settings, at the top.
            NavRow(icon: MSIcon.fence, title: "Zones", detail: "Alerts when someone enters or leaves an area") {
                router.navigate(.geofence)
            }
            VStack(spacing: MSSpace.screen) {
                SosSettingsCard()
                SectionCard("Check-in timer (dead man's switch)") {
                    SettingRow("Enabled") {
                        MSSwitch(
                            isOn: Binding(
                                get: { settings.bool(SettingsKey.deadmanEnabled) },
                                set: {
                                    settings.set(SettingsKey.deadmanEnabled, $0)
                                    model.gateway.applyDeadManSettings()
                                }), label: "Check-in timer enabled")
                    }
                    if settings.bool(SettingsKey.deadmanEnabled) {
                        Text("Timeout (triggers SOS if no activity)").msText(.bodySmall, color: MSColors.textMuted)
                        let timeouts = [("30", "30 min"), ("60", "1 hour"), ("120", "2 hours"), ("240", "4 hours"), ("480", "8 hours")]
                        ForEach(timeouts, id: \.0) { value, label in
                            let on = settings.string(SettingsKey.deadmanTimeoutMin) == value
                            Button {
                                settings.set(SettingsKey.deadmanTimeoutMin, value)
                                model.gateway.applyDeadManSettings()
                            } label: {
                                HStack {
                                    Text(label).msText(.bodySmall)
                                    Spacer(minLength: 8)
                                    if on { Text("selected").msText(.bodySmall, color: MSColors.teal) }
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(
                                    on ? MSColors.teal.opacity(0.15) : MSColors.surface,
                                    in: RoundedRectangle(cornerRadius: MSRadius.control, style: .continuous)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if model.deadManTriggered {
                            Button {
                                model.gateway.touchDeadMan()
                                model.refreshDeadMan()
                            } label: {
                                Text("TRIGGERED \u{2014} SOS was sent. Tap to reset.").msText(.bodySmall, color: MSColors.red)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text("Automatically sends SOS if no user activity (message send, button press) within the timeout period.")
                        .msText(.bodySmall, color: MSColors.textMuted)
                }
            }
            .padding(MSSpace.screen)
        }
        .background(MSColors.bg)
        .onAppear { model.refreshDeadMan() }
    }
}

// MARK: SMS

public struct SettingsSmsSection: View {
    @Environment(GatewayModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    @State private var phone = ""

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: MSSpace.screen) {
                SectionCard("Text messages") {
                    ConnectionStatusRow(
                        label: "SMS", connected: model.canSendSms,
                        statusText: model.canSendSms ? "Through the Messages app" : "This iPhone cannot send texts", color: MSColors.teal)
                    Text(
                        "iOS lets no app send a text by itself. MeshSat writes each one and opens the Messages app with it filled in; "
                            + "you tap Send. Incoming texts stay in Messages. Your carrier's normal rates apply."
                    )
                    .msText(.bodyMedium, color: MSColors.textSecondary)
                }
                SectionCard("Where a text goes with no recipient") {
                    MSOutlinedTextField(
                        text: $phone, label: "Optional number, e.g. +31612345678", focusedBorder: MSColors.teal, keyboard: .phonePad)
                    MSFilledButton("Save", container: MSColors.teal, fullWidth: false) {
                        settings.set(SettingsKey.meshsatPiPhone, phone)
                        model.showToast("Saved")
                    }
                    Text(
                        "Only used when a message has no recipient of its own: a routing rule that forwards to SMS without naming a "
                            + "number. Messages you write carry their own recipient, and SOS texts go to your emergency contacts under "
                            + "Safety. Leave it empty and a text with no recipient is not sent."
                    )
                    .msText(.bodySmall, color: MSColors.textMuted)
                }
            }
            .padding(MSSpace.screen)
        }
        .background(MSColors.bg)
        .onAppear { phone = settings.string(SettingsKey.meshsatPiPhone) }
    }
}

// MARK: Diagnostics

public struct SettingsDiagnosticsSection: View {
    @Environment(GatewayModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    @State private var confirmRestart = false
    @State private var scores: [String: HealthScore] = [:]
    @State private var burstPending = 0
    @State private var telemetry: [TelemetryEntry] = []
    @State private var configJson = ""
    @State private var configYaml = ""
    @State private var importPreview: (text: String, diff: DiffResult)?
    @State private var importError = ""

    public init() {}

    private var dismissRestart: () -> Void { { confirmRestart = false } }
    private var dismissImport: () -> Void { { importPreview = nil } }

    public var body: some View {
        ScrollView {
            VStack(spacing: MSSpace.screen) {
                SectionCard("App log") {
                    AppLogCard()
                }
                SectionCard("Link health") {
                    ForEach(["mesh_0", "iridium_0", "sms_0", "hub_0", "mqtt_0", "aprs_0"], id: \.self) { id in
                        let status = model.interfaces[id]
                        let score = scores[id]
                        HStack {
                            Text(Words.channel(id)).msText(.bodySmall, color: Words.channelColor(id))
                            Spacer(minLength: 8)
                            Text(status.map { Words.linkState($0.state.rawValue) } ?? "--")
                                .msText(
                                    .bodySmall,
                                    color: status.map {
                                        Words.deliveryColor($0.state == .online ? "sent" : ($0.state == .error ? "failed" : "queued"))
                                    } ?? MSColors.textMuted)
                            Text(score.map { "score: \($0.score)/100" } ?? "score: --")
                                .msText(.bodySmall, color: Self.scoreColor(score?.score))
                                .frame(width: 96, alignment: .trailing)
                        }
                        .padding(8)
                        .background(MSColors.surface, in: RoundedRectangle(cornerRadius: MSRadius.control, style: .continuous))
                    }
                    Text(
                        "Health = Signal(0.3) + SuccessRate(0.3) + Latency(0.2) + Cost(0.2). "
                            + "Scores update in real-time based on 24h delivery history."
                    )
                    .msText(.bodySmall, color: MSColors.textMuted)
                }
                SectionCard("Batch queue") {
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(burstPending) waiting for the next pass").msText(.bodyMedium)
                            Text("Small messages packed into one satellite session when a pass begins, or now.")
                                .msText(.bodySmall, color: MSColors.textMuted)
                        }
                        Spacer(minLength: 8)
                        MSOutlinedButton("Flush now") {
                            Task {
                                let n = await model.gateway.flushBurstNow()
                                model.showToast(n > 0 ? "Batch of \(n) queued for the satellite" : "Nothing waiting")
                                burstPending = model.gateway.burstPending
                            }
                        }
                        .frame(width: 120)
                    }
                }
                SectionCard("Crash reports") {
                    SettingRow("Enable local telemetry") {
                        MSSwitch(isOn: settings.binding(SettingsKey.telemetryEnabled), label: "Enable local telemetry")
                    }
                    Text("Captures crashes, heap samples and health heartbeats locally on this phone. Nothing is sent externally.")
                        .msText(.bodySmall, color: MSColors.textMuted)
                    if telemetry.isEmpty {
                        Text("No entries yet.").msText(.bodySmall, color: MSColors.textMuted)
                    } else {
                        ForEach(Array(telemetry.prefix(20).enumerated()), id: \.offset) { _, e in
                            HStack(alignment: .top, spacing: 8) {
                                Text(Words.clock(e.timestamp, "HH:mm:ss")).msText(.labelSmall, mono: true, color: MSColors.textMuted)
                                Text(e.type).msText(
                                    .labelSmall, mono: true, color: e.severity == "fatal" ? MSColors.red : MSColors.textSecondary
                                )
                                .frame(width: 44, alignment: .leading)
                                Text(e.message).msText(.labelSmall, color: MSColors.textSecondary).lineLimit(2)
                            }
                        }
                        ShareLink(
                            item: telemetry.map {
                                "\(Words.clock($0.timestamp, "HH:mm:ss")) \($0.type) \($0.severity) \($0.tag): \($0.message) \($0.detail)"
                            }.joined(separator: "\n")
                        ) {
                            Text("Share the telemetry").msText(.bodySmall, color: MSColors.offWhite).padding(.horizontal, 24)
                                .frame(maxWidth: .infinity, minHeight: 40).overlay(Capsule().stroke(MSColors.border, lineWidth: 1))
                        }
                    }
                }
                SectionCard("Configuration") {
                    Text("The routing rules, object groups and failover groups as one document, in the same format as the Bridge.")
                        .msText(.bodySmall, color: MSColors.textMuted)
                    HStack(spacing: 8) {
                        ShareLink(item: configJson, subject: Text("MeshSat configuration")) {
                            Text("Export JSON").msText(.bodySmall, color: MSColors.offWhite)
                                .frame(maxWidth: .infinity, minHeight: 40).overlay(Capsule().stroke(MSColors.border, lineWidth: 1))
                        }
                        ShareLink(item: configYaml, subject: Text("MeshSat configuration")) {
                            Text("Export YAML").msText(.bodySmall, color: MSColors.offWhite)
                                .frame(maxWidth: .infinity, minHeight: 40).overlay(Capsule().stroke(MSColors.border, lineWidth: 1))
                        }
                    }
                    MSOutlinedButton("Import from the clipboard") {
                        let text = UIPasteboard.general.string ?? ""
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            importError = "The clipboard is empty."
                            return
                        }
                        Task {
                            switch await model.gateway.previewConfiguration(text) {
                            case .success(let diff):
                                importError = ""
                                importPreview = (text, diff)
                            case .failure(let e):
                                importError = e.description
                            }
                        }
                    }
                    if !importError.isEmpty { Text(importError).msText(.bodySmall, color: MSColors.red) }
                }
                SectionCard("Background service") {
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Reconnect after a phone restart").msText(.bodyMedium)
                            Text(
                                "iOS relaunches MeshSat for its Bluetooth node after a restart, and the gateway reconnects. "
                                    + "Your position is read only once you open the app."
                            )
                            .msText(.bodySmall, color: MSColors.textMuted)
                        }
                        Spacer(minLength: 8)
                        MSSwitch(isOn: settings.binding(SettingsKey.startOnBoot), label: "Reconnect after a phone restart")
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Restart Gateway Service").msText(.bodyMedium)
                            Text("Stop and restart all transports").msText(.bodySmall, color: MSColors.textMuted)
                        }
                        Spacer(minLength: 8)
                        MSOutlinedButton("Restart") { confirmRestart = true }.frame(width: 120)
                    }
                }
            }
            .padding(MSSpace.screen)
        }
        .background(MSColors.bg)
        .task { await refresh() }
        .overlay {
            if confirmRestart {
                MSAlertDialog("Restart Service?", onDismiss: dismissRestart) {
                    Text("This will disconnect all transports and restart the gateway service. It should take a few seconds.").msText(
                        .bodyMedium)
                } buttons: {
                    MSTextButton("Cancel") { confirmRestart = false }
                    MSFilledButton("Restart", container: MSColors.red, fullWidth: false) {
                        confirmRestart = false
                        settings.restartGateway()
                        model.showToast("Service restarting...")
                    }
                }
            }
            if let preview = importPreview {
                MSAlertDialog("Replace the configuration?", onDismiss: dismissImport) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Everything stored is replaced by the document on the clipboard.").msText(.bodyMedium)
                        Text(Self.diffLine("Rules", preview.diff.accessRules)).msText(.bodySmall, color: MSColors.textSecondary)
                        Text(Self.diffLine("Object groups", preview.diff.objectGroups)).msText(.bodySmall, color: MSColors.textSecondary)
                        Text(Self.diffLine("Failover groups", preview.diff.failoverGroups)).msText(
                            .bodySmall, color: MSColors.textSecondary)
                    }
                } buttons: {
                    MSTextButton("Cancel") { importPreview = nil }
                    MSFilledButton("Import", container: MSColors.red, fullWidth: false) {
                        importPreview = nil
                        Task {
                            switch await model.gateway.importConfiguration(preview.text) {
                            case .success(let counts):
                                model.showToast("Imported \(counts["access_rules"] ?? 0) rules, \(counts["object_groups"] ?? 0) groups")
                                await refresh()
                            case .failure(let e):
                                importError = e.description
                            }
                        }
                    }
                }
            }
        }
    }

    private func refresh() async {
        let list = await model.gateway.healthScores()
        scores = Dictionary(uniqueKeysWithValues: list.map { ($0.interfaceId, $0) })
        burstPending = model.gateway.burstPending
        telemetry = await model.gateway.recentTelemetry()
        configJson = await model.gateway.exportConfiguration(yaml: false)
        configYaml = await model.gateway.exportConfiguration(yaml: true)
    }

    static func scoreColor(_ score: Int?) -> Color {
        guard let score else { return MSColors.textMuted }
        return score >= 70 ? MSColors.green : (score >= 40 ? MSColors.amber : MSColors.red)
    }

    static func diffLine(_ what: String, _ d: DiffCounts) -> String {
        "\(what): \(d.add) added, \(d.change) kept or changed, \(d.remove) removed"
    }
}

struct AppLogCard: View {
    @State private var lines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What the app did most recently. Share it when reporting a problem.").msText(.bodySmall, color: MSColors.textMuted)
            ScrollView {
                Text(lines.suffix(200).joined(separator: "\n"))
                    .msText(.labelSmall, mono: true, color: MSColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 240)
            .padding(8)
            .background(MSColors.surfaceLight, in: RoundedRectangle(cornerRadius: 4))
            HStack(spacing: 8) {
                MSOutlinedButton("Refresh") { lines = AppLog.shared.recent() }
                ShareLink(item: AppLog.shared.recent().joined(separator: "\n")) {
                    Text("Share the log").msText(.bodySmall, color: MSColors.offWhite).padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, minHeight: 40).overlay(Capsule().stroke(MSColors.border, lineWidth: 1))
                }
            }
        }
        .onAppear { lines = AppLog.shared.recent() }
    }
}
