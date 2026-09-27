// Mirrors ui/screens/NodeLogScreen.kt (MESHSAT-1374): Settings > Advanced > Node log, the
// node's live log over Bluetooth, the same lines its serial console prints, so a bench session
// needs no USB cable. The switch sets security.debug_log_api_enabled on the node (a setting the
// node keeps; a security set_config makes the node restart once, and the link comes back by
// itself in about 15 s, the switch reading the config dump again after it); the screen follows
// LogRadio only while it is open. Lines newest at the bottom, paused lines held and appended on
// resume, at most 2000 kept. Same screen on Android.
import MeshSatMeshtastic
import SwiftUI

public struct NodeLogScreen: View {
    @Environment(GatewayModel.self) private var model
    @State private var setting = false
    @State private var following = false

    public init() {}

    private var connected: Bool { model.meshState == .connected }
    private var streaming: Bool { model.nodeDebugLog }

    public var body: some View {
        VStack(spacing: 8) {
            SettingRow("Stream the node's log") {
                MSSwitch(isOn: streamingBinding, label: "Stream the node's log", enabled: connected && !setting)
            }
            .padding(.top, 8)
            Text(hint).msText(.bodySmall, color: MSColors.textMuted).frame(maxWidth: .infinity, alignment: .leading)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.nodeLogLines.enumerated()), id: \.offset) { i, line in
                            Text(NodeLog.format(line)).msText(.labelSmall, mono: true, color: Self.color(line.level))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(8)
                    .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MSColors.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(MSColors.border, lineWidth: 1))
                .onChange(of: model.nodeLogLines.count) { _, count in
                    if !model.nodeLogPaused, count > 0 { withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) } }
                }
            }
            HStack(spacing: 8) {
                MSOutlinedButton(model.nodeLogPaused ? "Resume" : "Pause") {
                    let buffer = model.gateway.central.nodeLog
                    if model.nodeLogPaused { buffer.resume() } else { buffer.pause() }
                }
                MSOutlinedButton("Clear") { model.gateway.central.nodeLog.clear() }
                ShareLink(item: model.gateway.central.nodeLog.text(), subject: Text("MeshSat node log")) {
                    Text("Share").msText(.bodySmall, color: MSColors.offWhite).padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, minHeight: 40).overlay(Capsule().stroke(MSColors.border, lineWidth: 1))
                }
                .disabled(model.nodeLogLines.isEmpty)
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal, MSSpace.screen)
        .background(MSColors.bg)
        .onAppear { follow(connected && streaming) }
        .onChange(of: connected) { _, _ in follow(connected && streaming) }
        .onChange(of: streaming) { _, _ in follow(connected && streaming) }
        .onDisappear { follow(false) }
    }

    private var hint: String {
        if !connected { return "Connect your MeshSat node first." }
        if streaming { return "The node sends every log line while this switch is on; it may drop lines in a burst. Newest at the bottom." }
        return "Sets the node's debug log over Bluetooth (security.debug_log_api_enabled); a setting the node keeps. "
            + "The node restarts once to apply it, and the link comes back by itself."
    }

    private var streamingBinding: Binding<Bool> {
        Binding(
            get: { streaming },
            set: { on in
                if let why = model.gateway.setNodeDebugLog(on) {
                    model.showToast(why)
                } else {
                    setting = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(1_500))
                        setting = false
                    }
                }
            })
    }

    /// Follow LogRadio while the screen is open and the node streams; stop when it is left.
    private func follow(_ on: Bool) {
        guard on != following else { return }
        following = on
        let central = model.gateway.central
        guard on || central.state.value == .connected else { return }
        Task {
            let status = await central.followNodeLog(on)
            if on, status != GattOpQueue.statusSuccess { model.showToast("The node's log could not be followed: \(status).") }
        }
    }

    static func color(_ level: String?) -> Color {
        switch level {
        case "ERROR", "CRIT": MSColors.red
        case "WARN": MSColors.amber
        case "DEBUG", "TRACE": MSColors.textMuted
        default: MSColors.textPrimary
        }
    }
}
