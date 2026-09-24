// Mirrors the "Offline maps" card of ui/screens/SettingsScreen.kt (SetupSection.Maps): the world
// overview that ships inside the app, the detailed MBTiles files the user added, which one is
// in use, and adding one from the Files app.
import MeshSatEngine
import MeshSatPlatform
import MeshSatStore
import SwiftUI
import UniformTypeIdentifiers

public struct SettingsMapsSection: View {
    @Environment(GatewayModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    @State private var mapFiles: [MBTilesInfo] = []
    @State private var importing = false
    @State private var picking = false
    @State private var confirmDelete: MBTilesInfo?

    public init() {}

    public var body: some View {
        let offlineEnabled = settings.bool(SettingsKey.offlineMapEnabled)
        let offlineFile = settings.string(SettingsKey.offlineMapFile)
        // The world overview ships inside the app and is copied next to the added maps, so it is
        // shown on its own line and can never be deleted from the list.
        let detailedMaps = mapFiles.filter { $0.filename != MBTilesManager.bundledWorldMap }
        let usableMaps = detailedMaps.filter { !$0.isVector }
        let inUse = offlineEnabled && usableMaps.contains { $0.filename == offlineFile }
        ScrollView {
            VStack(spacing: MSSpace.screen) {
                SectionCard("Offline maps") {
                    Text("The map downloads its detail from the internet. Without internet it shows what is installed here.")
                        .msText(.bodyMedium, color: MSColors.textSecondary)
                    Text("Installed").msText(.titleSmall, color: MSColors.textSecondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("World overview").msText(.bodyMedium)
                        Text(
                            "Built in and always installed. Countries and coastlines at a zoomed-out scale, "
                                + "shown when there is no internet."
                        )
                        .msText(.bodySmall, color: MSColors.textMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(MSColors.border, lineWidth: 1))
                    ForEach(detailedMaps) { info in
                        mapRow(info, active: inUse && info.filename == offlineFile)
                    }
                    if !usableMaps.isEmpty {
                        HStack {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Use my detailed map").msText(.bodyMedium)
                                Text("Shown first. Outside it the map uses online tiles, or the world overview without internet.")
                                    .msText(.bodySmall, color: MSColors.textMuted)
                            }
                            .padding(.trailing, 12)
                            Spacer(minLength: 0)
                            MSSwitch(
                                isOn: Binding(
                                    get: { inUse },
                                    set: { on in
                                        if on {
                                            let pick = usableMaps.first { $0.filename == offlineFile } ?? usableMaps[0]
                                            useMap(pick.filename)
                                        } else {
                                            settings.set(SettingsKey.offlineMapEnabled, false)
                                        }
                                    }), label: "Use my detailed map")
                        }
                    }
                    HStack(spacing: 8) {
                        MSOutlinedButton("Add a detailed map", enabled: !importing) { picking = true }
                        if importing {
                            MSCircularProgress(size: 20, stroke: 2)
                            Text("Adding the map").msText(.bodySmall, color: MSColors.textMuted)
                        }
                    }
                    Text(
                        "Use an MBTiles file with PNG or JPEG tiles, for example one exported from OpenStreetMap for your area. "
                            + "Files with vector tiles cannot be shown."
                    )
                    .msText(.bodySmall, color: MSColors.textMuted)
                }
            }
            .padding(MSSpace.screen)
        }
        .background(MSColors.bg)
        .task { await reload() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.data, .item]) { result in
            guard case .success(let url) = result else { return }
            Task { await importMap(url) }
        }
        .overlay {
            if let info = confirmDelete {
                MSAlertDialog(
                    "Delete this map?", onDismiss: { confirmDelete = nil },
                    content: {
                        Text("\(info.name) is removed from this phone. You can add it again from a file.").msText(
                            .bodyMedium, color: MSColors.textSecondary)
                    },
                    buttons: {
                        MSTextButton("Cancel") { confirmDelete = nil }
                        MSTextButton("Delete", color: MSColors.red) {
                            confirmDelete = nil
                            Task { await delete(info) }
                        }
                    })
            }
        }
    }

    private func mapRow(_ info: MBTilesInfo, active: Bool) -> some View {
        Button {
            if !info.isVector { useMap(info.filename) }
        } label: {
            HStack(spacing: 0) {
                MSRadioButton(selected: active, enabled: !info.isVector)
                VStack(alignment: .leading, spacing: 0) {
                    Text(info.name).msText(.bodyMedium).lineLimit(1)
                    let sizeMb = String(format: "%.1f MB", Double(info.sizeBytes) / 1_048_576)
                    let zoomRange = if let lo = info.minZoom, let hi = info.maxZoom { "zoom \(lo) to \(hi)" } else { "" }
                    Text([sizeMb, zoomRange].filter { !$0.isEmpty }.joined(separator: ", ")).msText(.bodySmall, color: MSColors.textMuted)
                    if info.isVector {
                        Text("Vector tiles: the map cannot show this file.").msText(.bodySmall, color: MSColors.amber)
                    } else if active {
                        Text("In use").msText(.bodySmall, color: MSColors.teal)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                MSIconButton(MSIcon.delete, label: "Delete \(info.name)", tint: MSColors.textMuted) { confirmDelete = info }
            }
            .padding(.leading, 4)
            .background(active ? MSColors.teal.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? MSColors.teal.opacity(0.4) : MSColors.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(info.isVector)
        .accessibilityLabel("Use \(info.name)")
    }

    private func useMap(_ filename: String) {
        settings.set(SettingsKey.offlineMapFile, filename)
        settings.set(SettingsKey.offlineMapEnabled, true)
    }

    private func reload() async {
        mapFiles = await Task.detached { MBTilesManager.listFiles() }.value
    }

    private func importMap(_ url: URL) async {
        importing = true
        defer { importing = false }
        let result: Result<String, Error> = await Task.detached {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { return .success(try MBTilesManager.importFile(from: url)) } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let filename):
            await reload()
            let added = mapFiles.first { $0.filename == filename }
            if let added, added.isVector {
                model.showToast("Added, but this file has vector tiles, which the map cannot show.")
            } else {
                useMap(filename)
                model.showToast("Map added: \(added?.name ?? filename)")
            }
        case .failure(let error):
            model.showToast("Could not add this map: \(error)")
        }
    }

    private func delete(_ info: MBTilesInfo) async {
        await Task.detached { MBTilesManager.delete(info.filename) }.value
        await reload()
        if settings.string(SettingsKey.offlineMapFile) == info.filename {
            settings.set(SettingsKey.offlineMapFile, "")
            settings.set(SettingsKey.offlineMapEnabled, false)
        }
        model.showToast("Map deleted: \(info.name)")
    }
}
