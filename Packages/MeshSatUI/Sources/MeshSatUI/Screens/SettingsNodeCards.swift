// Mirrors node parts of ui/screens/SettingsScreen.kt:
// - "Node light and screen" (MESHSAT-1671): the owner's switches for the node's status LED and
//   screen, written to the node firmware's CONTROL characteristic and read back from STATUS flags
//   bits 5 and 6, so a switch shows what the node did. A node without CONTROL (firmware before
//   24 Oct 2026) says why the switches are missing.
// - "Node firmware" (MESHSAT-1672): the node's firmware updated over Bluetooth, from the
//   published release (only on a "Check for update" tap) or from a file. Versions end in a
//   commit hash, so a release is only ever the same or another one, never newer.
import MeshSatMeshtastic
import MeshSatPlatform
import SwiftUI
import UniformTypeIdentifiers

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

struct NodeFirmwareCard: View {
    @Environment(SettingsModel.self) private var settings
    @State private var picked: NodeFirmwareImage?
    @State private var refusal: String?
    @State private var picking = false
    @State private var release: ReleaseCheck = .none

    var body: some View {
        SectionCard("Node firmware") {
            InfoRow("On the node", settings.nodeFirmwareVersion.isEmpty ? "unknown" : settings.nodeFirmwareVersion)
            InfoRow("Build", settings.nodePioEnv.isEmpty ? "unknown" : settings.nodePioEnv)
            switch settings.firmwareUpdate {
            case .idle: idle
            case .askingNode:
                working("Asking the node to get ready...", nil)
            case .working(let text, let fraction):
                working(text, fraction)
            case .done(let version):
                Text("Updated to \(version).").msText(.bodySmall, color: MSColors.teal).frame(maxWidth: .infinity, alignment: .leading)
                MSOutlinedButton("Done") {
                    picked = nil
                    settings.resetFirmwareUpdate()
                }
            case .failed(let reason, let canRetry):
                Text(reason).msText(.bodySmall, color: MSColors.amber).frame(maxWidth: .infinity, alignment: .leading)
                if canRetry { MSFilledButton("Retry with the same file", container: MSColors.teal) { settings.retryFirmwareUpdate() } }
                MSOutlinedButton("Close") { settings.resetFirmwareUpdate() }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.data, .item]) { result in
            guard case .success(let url) = result else { return }
            take(fileAt: url)
        }
    }

    @ViewBuilder private var idle: some View {
        if let image = picked {
            InfoRow("New firmware", image.version.isEmpty ? "unnamed" : image.version)
            InfoRow("Size", "\(image.size / 1024) KB, SHA-256 \(image.sha256Hex.prefix(8))")
            MSFilledButton("Update the node now", container: MSColors.teal) { settings.startFirmwareUpdate(image) }
            MSOutlinedButton("Choose another file") { picked = nil }
        } else {
            releaseRows
            if !release.busy {
                MSOutlinedButton("Check for update") { Task { await check() } }
                MSOutlinedButton("Update from a file...") { picking = true }
            }
        }
        if let refusal { Text(refusal).msText(.bodySmall, color: MSColors.amber).frame(maxWidth: .infinity, alignment: .leading) }
        Text(
            "Check for update asks GitHub for the published MeshSat release for this node's build. A file: pick "
                + "firmware-\(settings.nodePioEnv)-<version>.bin (not the .factory.bin). The node restarts twice; keep the phone close. "
                + "A few minutes."
        )
        .msText(.bodySmall, color: MSColors.textMuted)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Where "Check for update" stands; the published release is asked for only on that tap.
    @ViewBuilder private var releaseRows: some View {
        switch release {
        case .none: EmptyView()
        case .checking: working("Asking for the published firmware...", nil)
        case .downloading(let fraction): working("Downloading the firmware: \(Int(fraction * 100)) %", fraction)
        case .available(let manifest, let image):
            InfoRow("Available", manifest.version)
            MSFilledButton("Download \(manifest.version) (\(image.size / 1024) KB)", container: MSColors.teal) {
                Task { await download(manifest, image) }
            }
        case .upToDate(let version):
            Text("The node already runs the published firmware (\(version)).").msText(.bodySmall, color: MSColors.teal)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .refused(let reason):
            Text(reason).msText(.bodySmall, color: MSColors.amber).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func working(_ text: String, _ fraction: Double?) -> some View {
        Text(text).msText(.bodySmall, color: MSColors.offWhite).frame(maxWidth: .infinity, alignment: .leading)
        if let fraction {
            ProgressView(value: min(max(fraction, 0), 1)).tint(MSColors.teal)
        } else {
            ProgressView().tint(MSColors.teal).frame(maxWidth: .infinity)
        }
    }

    private func check() async {
        picked = nil
        refusal = nil
        release = .checking
        switch await NodeFirmwareFetcher().manifest() {
        case .refused(let reason): release = .refused(reason)
        case .ok(let manifest):
            switch NodeFirmwareRelease.pick(manifest, nodeEnv: settings.nodePioEnv) {
            case .refused(let reason): release = .refused(reason)
            case .found(let m, let image):
                release =
                    NodeFirmwareRelease.isCurrent(m, running: settings.nodeFirmwareVersion) ? .upToDate(m.version) : .available(m, image)
            }
        }
    }

    private func download(_ manifest: NodeFirmwareRelease.Manifest, _ image: NodeFirmwareRelease.Image) async {
        release = .downloading(0)
        // The progress comes back as a stream, so the fetch's closure holds nothing of this view.
        let (progress, sink) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
        let fetch = Task { () -> Result<[UInt8], Error> in
            defer { sink.finish() }
            do {
                return .success(try await NodeFirmwareFetcher().download(manifest, image) { sink.yield($0) })
            } catch {
                return .failure(error)
            }
        }
        for await f in progress { release = .downloading(min(max(f, 0), 1)) }
        let bytes: [UInt8]
        switch await fetch.value {
        case .success(let b): bytes = b
        case .failure(let error):
            release = .refused("The download failed: \(String(describing: error)).")
            return
        }
        if let why = NodeFirmwareRelease.verify(bytes, image) {
            release = .refused(why)
            return
        }
        switch NodeFirmwareImage.check(bytes, nodeEnv: settings.nodePioEnv) {
        case .refused(let reason): release = .refused(reason)
        case .ok(let checked):
            release = .none
            picked = checked
        }
    }

    private func take(fileAt url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        picked = nil
        refusal = nil
        guard let data = try? Data(contentsOf: url) else {
            refusal = "The file could not be read."
            return
        }
        switch NodeFirmwareImage.check([UInt8](data), nodeEnv: settings.nodePioEnv) {
        case .refused(let reason): refusal = reason
        case .ok(let image): picked = image
        }
    }
}

/// Where the Node firmware card's "Check for update" stands (MESHSAT-1672).
private enum ReleaseCheck: Equatable {
    case none
    case checking
    case available(NodeFirmwareRelease.Manifest, NodeFirmwareRelease.Image)
    case upToDate(String)
    case refused(String)
    case downloading(Double)

    var busy: Bool {
        switch self {
        case .checking, .downloading: true
        default: false
        }
    }
}
