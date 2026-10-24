// Mirrors node parts of ui/screens/SettingsScreen.kt:
// - "Node light and screen" (MESHSAT-1671): the owner's switches for the node's status LED and
//   screen, written to the node firmware's CONTROL characteristic and read back from STATUS flags
//   bits 5 and 6, so a switch shows what the node did. A node without CONTROL (firmware before
//   24 Oct 2026) says why the switches are missing.
// - "Node firmware" (MESHSAT-1672): the node's firmware updated over Bluetooth, from the
//   published release (only on a "Check for update" tap) or from a file. Versions end in a
//   commit hash, so a release is only ever the same or another one, never newer.
// - SignalReadingRow (MESHSAT-1670): the 9704's bars with their age once stale.
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
            case .failed(let reason, let canRetry, let inUpdater):
                Text(reason).msText(.bodySmall, color: MSColors.amber).frame(maxWidth: .infinity, alignment: .leading)
                if canRetry && settings.firmwareHasPending {
                    MSFilledButton("Retry with the same file", container: MSColors.teal) { settings.retryFirmwareUpdate() }
                }
                if inUpdater {
                    // Back to the card with no file: picking the same one sends it to the updater.
                    MSOutlinedButton("Choose the file again") {
                        picked = nil
                        settings.resetFirmwareUpdate()
                    }
                } else {
                    MSOutlinedButton("Close") { settings.resetFirmwareUpdate() }
                }
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
            if settings.nodeLinkUp {
                MSFilledButton("Update the node now", container: MSColors.teal) { settings.startFirmwareUpdate(image) }
            } else {
                MSFilledButton("Send it to the node's updater", container: MSColors.teal) { settings.sendFirmwareToUpdater(image) }
                Text(
                    "The node is not connected. If an update stopped and the node waits in its updater, "
                        + "send it the same file that update started with."
                )
                .msText(.bodySmall, color: MSColors.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
        // With no node connected the file goes to a waiting updater, which takes only the image whose
        // SHA-256 the node was handed: the loader is the build check then (MESHSAT-1684).
        let check =
            settings.nodeLinkUp || !settings.nodePioEnv.isEmpty
            ? NodeFirmwareImage.check([UInt8](data), nodeEnv: settings.nodePioEnv) : NodeFirmwareImage.checkForWaitingUpdater([UInt8](data))
        switch check {
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

/// The 9704's signal as the screens show it (MESHSAT-1670, SettingsScreen.kt's SignalReadingRow):
/// the bars, their age once stale, "?" before the first reading; looked at again every 5 s.
struct SignalReadingRow: View {
    let reading: SignalReading?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { timeline in
            let nowMs = Int64(timeline.date.timeIntervalSince1970 * 1000)
            let fresh = SignalFreshness.kind(reading, nowMs: nowMs) == .fresh
            HStack(alignment: .top, spacing: 8) {
                Text("Signal").msText(.bodySmall, color: MSColors.textMuted)
                Spacer(minLength: 8)
                Text(SignalFreshness.describe(reading, nowMs: nowMs))
                    .msText(.bodySmall, color: fresh ? MSColors.textPrimary : MSColors.textMuted)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}
