// Mirrors ui/screens/GeofenceScreen.kt (MESHSAT-1249, B4): Zones. The same map as the Map tab
// with its offline fallback; a zone is a circle placed by long-pressing the map (or at this
// phone's position), sized with a radius slider, and never at 0,0.
import CoreLocation
import MeshSatEngine
import MeshSatPlatform
import MeshSatStore
import SwiftUI

private let minRadiusM = 10
private let maxRadiusM = 50_000
private let sliderMinM = 50.0
private let sliderMaxM = 5_000.0

/// What an alert does, from GeofenceMonitor and the gateway as they are: only Meshtastic position
/// reports are checked, a crossing is recorded in the list on this screen and nowhere else, and
/// zones are held in memory by the gateway.
private let alertExplainer =
    "When a mesh node reports a position that crosses a zone's edge, the alert is listed here. "
    + "It does not send a message or a notification, and zones are kept only until the MeshSat service restarts."

public struct GeofenceScreen: View {
    @Environment(GatewayModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    @State private var now = Int64(Date().timeIntervalSince1970 * 1000)
    @State private var changes = 0
    @State private var positions: [NodePosition] = []
    @State private var detailed: DetailedMap?
    @State private var offline = false
    @State private var ticket: MapCommandTicket?
    @State private var seq = 0
    @State private var fitted = false
    // The zone being placed.
    @State private var placing = false
    @State private var centre: CLLocationCoordinate2D?
    @State private var radius = 200.0
    @State private var radiusText = "200"
    @State private var name = ""
    @State private var alertOn = "enter"
    @State private var note = ""
    @State private var nameError = false
    @State private var centreError = false
    @State private var radiusError = false
    @State private var toDelete: GeofenceZone?

    public init() {}

    private var monitor: GeofenceMonitor { model.gateway.geofenceMonitor }

    private func send(_ c: MapCommand) {
        seq += 1
        ticket = MapCommandTicket(seq: seq, command: c)
    }

    private func resetDraft() {
        placing = false
        centre = nil
        radius = 200
        radiusText = "200"
        name = ""
        alertOn = "enter"
        note = ""
        nameError = false
        centreError = false
        radiusError = false
    }

    public var body: some View {
        // Read again on every tick (`changes`): the monitor has no change signal.
        let zones = changes >= 0 ? monitor.getZones() : []
        let events = changes >= 0 ? monitor.getEvents() : []
        let nodes = positions.filter { $0.nodeId != 0 }
        let names = meshNodeNames(model.nodes)
        let phone = model.phoneFix
        let mapZones = zones.map {
            MapZone(
                id: $0.id, name: $0.name, subtitle: "Alerts when a node \(alertWhen($0.alertOn))",
                polygon: $0.polygon.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
        }
        let draft = placing ? centre.map { MapDraft(center: $0, radiusM: radius) } : nil
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                MeshMapView(
                    detailed: detailed, night: false, nodes: nodes, tracks: [], names: names, phone: phone, now: now, ticket: ticket,
                    zones: mapZones,
                    draft: draft,
                    onLongPress: { p in
                        placing = true
                        centre = p
                        centreError = false
                    })
                let hint: String? =
                    placing && centre == nil
                    ? "Long-press the map where the zone should be."
                    : (placing ? "Long-press the map to move the zone." : "Long-press the map to place a zone.")
                if let hint {
                    Text(hint).msText(.bodySmall).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(MSColors.bg.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                        .frame(maxWidth: 280).padding(.leading, 8).padding(.top, 8).padding(.trailing, 64)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                MapButton(icon: MSIcon.myLocation, description: "Centre on me") {
                    if let phone {
                        send(.centre(lat: phone.latitude, lon: phone.longitude, minZoom: 15, animate: true))
                    } else {
                        model.showToast("Your position is not known yet.")
                    }
                }
                .padding(8)
                VStack(spacing: 8) {
                    MapButton(icon: MSIcon.add, description: "Zoom in") { send(.zoomIn) }
                    MapButton(icon: MSIcon.remove, description: "Zoom out") { send(.zoomOut) }
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                // The world overview stops at country level (zoom 3), far above any zone: the map
                // keeps its zoom and says what still works.
                MapStatusNote(
                    detailed: detailed, offline: offline,
                    worldOnlyNote:
                        "Offline, with no street detail here. Zones still work: place one around your position. "
                        + "For detail, add a map in Setup > Maps."
                )
                .padding(.leading, 8).padding(.bottom, 8).padding(.trailing, 64)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: MSRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: MSRadius.card, style: .continuous).stroke(MSColors.border, lineWidth: 1))
            .padding(.horizontal, 16).padding(.top, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if placing { editor } else { list(zones, events, names) }
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MSColors.bg)
        .task { await observe() }
        .task(id: "\(settings.bool(SettingsKey.offlineMapEnabled))|\(settings.string(SettingsKey.offlineMapFile))") {
            let enabled = settings.bool(SettingsKey.offlineMapEnabled)
            let file = settings.string(SettingsKey.offlineMapFile)
            detailed = enabled && !file.isEmpty ? await Task.detached { MapTiles.detailedMap(file) }.value : nil
        }
        .onChange(of: zones.count + (phone == nil ? 0 : 1), initial: true) { _, _ in firstView(zones, phone) }
        .overlay { if let zone = toDelete { deleteDialog(zone) } }
    }

    // First view, once: the zones if there are any, else this phone. Never again after that, so
    // the user's own zoom and position stay put.
    private func firstView(_ zones: [GeofenceZone], _ phone: PhoneFix?) {
        if fitted { return }
        let points = zones.flatMap { $0.polygon.map { ($0.lat, $0.lon) } }
        if !points.isEmpty {
            fitted = true
            send(.fit(points: points, animate: false))
        } else if let phone {
            fitted = true
            send(.centre(lat: phone.latitude, lon: phone.longitude, minZoom: 15, animate: false))
        }
    }

    private func observe() async {
        let db = model.gateway.db
        let positionsTask = Task {
            do {
                for try await rows in db.nodePositions.getLatestPerNode() { positions = rows }
            } catch {}
        }
        let offlineTask = Task {
            for await v in MapTiles.offline.subscribe() { offline = v }
        }
        // The monitor has no change signal, so zones and alerts are read again every few seconds.
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            now = Int64(Date().timeIntervalSince1970 * 1000)
            changes += 1
        }
        positionsTask.cancel()
        offlineTask.cancel()
    }

    private func startZone() {
        placing = true
        if let phone = model.phoneFix, centre == nil {
            centre = CLLocationCoordinate2D(latitude: phone.latitude, longitude: phone.longitude)
            send(.centre(lat: phone.latitude, lon: phone.longitude, minZoom: zoomForRadius(radius), animate: true))
        }
    }

    private func saveZone() {
        let r = Int(radiusText).flatMap { (minRadiusM...maxRadiusM).contains($0) ? $0 : nil }
        nameError = name.trimmingCharacters(in: .whitespaces).isEmpty
        centreError = centre == nil
        radiusError = r == nil
        guard !nameError, let c = centre, let r else { return }
        let zone = GeofenceZone(
            id: "zone_\(Int64(Date().timeIntervalSince1970 * 1000))", name: name.trimmingCharacters(in: .whitespaces),
            polygon: GeofenceMonitor.circlePolygon(centerLat: c.latitude, centerLon: c.longitude, radiusMeters: Double(r)),
            alertOn: alertOn,
            message: note.trimmingCharacters(in: .whitespaces))
        monitor.addZone(zone)
        changes += 1
        model.showToast("Zone added: \(zone.name)")
        resetDraft()
    }

    @ViewBuilder private var editor: some View {
        Text("New zone").msText(.titleMedium)
        Text(
            centre == nil ? "Long-press the map where the zone should be." : "The orange circle is the zone. Long-press the map to move it."
        )
        .msText(.bodyMedium, color: centreError && centre == nil ? MSColors.red : MSColors.textSecondary)
        MSOutlinedTextField(text: $name, label: "Name", focusedBorder: MSColors.teal, submitLabel: .next)
            .onChange(of: name) { _, v in if !v.trimmingCharacters(in: .whitespaces).isEmpty { nameError = false } }
        if nameError { Text("Give the zone a name.").msText(.bodySmall, color: MSColors.red) }
        Text("Radius").msText(.titleSmall, color: MSColors.textSecondary)
        MSSlider(
            value: Binding(
                get: { radiusToSlider(radius) },
                set: { t in
                    radius = sliderToRadius(t)
                    radiusText = "\(Int(radius.rounded()))"
                    radiusError = false
                }), label: "Radius")
        MSOutlinedTextField(
            text: $radiusText, label: "Radius in metres", focusedBorder: MSColors.teal, keyboard: .numberPad, submitLabel: .next
        )
        .onChange(of: radiusText) { _, text in
            let digits = String(text.filter(\.isNumber).prefix(5))
            if digits != text { radiusText = digits }
            if let v = Int(digits), (minRadiusM...maxRadiusM).contains(v) {
                radius = Double(v)
                radiusError = false
            }
        }
        Text(
            radiusError
                ? "Use a radius between \(minRadiusM) m and \(maxRadiusM / 1000) km." : "About \(formatDistance(radius * 2)) across."
        )
        .msText(.bodySmall, color: radiusError ? MSColors.red : MSColors.textMuted)
        Text("Alert when a node").msText(.titleSmall, color: MSColors.textSecondary)
        ForEach([("enter", "Enters the zone"), ("exit", "Leaves the zone"), ("both", "Enters or leaves")], id: \.0) { mode, label in
            Button {
                alertOn = mode
            } label: {
                HStack(spacing: 12) {
                    MSRadioButton(selected: alertOn == mode)
                    Text(label).msText(.bodyMedium)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: MSSpace.touch)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        MSOutlinedTextField(text: $note, label: "Note (optional)", focusedBorder: MSColors.teal)
        HStack(spacing: 8) {
            MSFilledButton("Save zone", fullWidth: false, action: saveZone)
            MSTextButton("Cancel") { resetDraft() }
        }
    }

    @ViewBuilder private func list(_ zones: [GeofenceZone], _ events: [GeofenceEventRecord], _ names: [Int64: String]) -> some View {
        Text(alertExplainer).msText(.bodyMedium, color: MSColors.textSecondary)
        MSFilledButton("+ Add zone", action: startZone)
        if zones.isEmpty { Text("No zones yet.").msText(.bodyMedium, color: MSColors.textMuted) }
        ForEach(zones, id: \.id) { zone in
            ZoneRow(
                zone: zone, onShow: { send(.fit(points: zone.polygon.map { ($0.lat, $0.lon) }, animate: true)) },
                onDelete: { toDelete = zone })
        }
        if !zones.isEmpty || !events.isEmpty {
            Text("Recent alerts").msText(.titleSmall, color: MSColors.textSecondary).padding(.top, 8)
            if events.isEmpty { Text("No alerts yet.").msText(.bodyMedium, color: MSColors.textMuted) }
            ForEach(Array(events.prefix(20).enumerated()), id: \.offset) { _, ev in
                HStack(spacing: 10) {
                    Circle().fill(MSColors.amber).frame(width: 8, height: 8)
                    Text(
                        "\(eventNodeName(ev.nodeId, names)) \(ev.event == "enter" ? "entered" : "left") \(ev.zoneName), "
                            + Words.ago(ev.timestamp, nowMs: now)
                    )
                    .msText(.bodyMedium)
                }
                .frame(minHeight: 40)
            }
        }
    }

    private func deleteDialog(_ zone: GeofenceZone) -> some View {
        MSAlertDialog(
            "Delete \(zone.name)?", onDismiss: { toDelete = nil },
            content: { Text("MeshSat stops watching this zone. Alerts it already raised stay in the list.").msText(.bodyMedium) },
            buttons: {
                MSTextButton("Keep it", color: MSColors.textSecondary) { toDelete = nil }
                MSTextButton("Delete zone", color: MSColors.red) {
                    monitor.removeZone(zone.id)
                    changes += 1
                    toDelete = nil
                }
            })
    }
}

/// One zone: tap to see it on the map; the bin asks before it deletes.
private struct ZoneRow: View {
    let zone: GeofenceZone
    let onShow: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onShow) {
                HStack(spacing: 12) {
                    Circle().fill(MSColors.amber).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(zone.name).msText(.titleSmall).lineLimit(1)
                        Text(
                            "Alerts when a node \(alertWhen(zone.alertOn)). "
                                + "Radius about \(formatDistance(GeofenceMonitor.zoneRadius(zone.polygon)))."
                        )
                        .msText(.bodySmall, color: MSColors.textSecondary)
                        if !zone.message.isEmpty { Text(zone.message).msText(.bodySmall, color: MSColors.textMuted).lineLimit(2) }
                    }
                    .padding(.vertical, 8)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show \(zone.name) on the map")
            MSIconButton(MSIcon.delete, label: "Delete zone \(zone.name)", action: onDelete)
        }
        .frame(minHeight: 64)
        .msCard()
    }
}

private func alertWhen(_ alertOn: String) -> String {
    switch alertOn {
    case "enter": "enters"
    case "exit": "leaves"
    default: "enters or leaves"
    }
}

/// The radio's name for an event's node ("!a1b2c3d4"), else the id itself.
private func eventNodeName(_ id: String, _ names: [Int64: String]) -> String {
    let hex = id.hasPrefix("!") ? String(id.dropFirst()) : id
    return Int64(hex, radix: 16).flatMap { names[$0] } ?? id
}

/// The slider runs on a log scale, so 50 m and 5 km are both easy to set.
private func radiusToSlider(_ r: Double) -> Float {
    Float(log(min(max(r, sliderMinM), sliderMaxM) / sliderMinM) / log(sliderMaxM / sliderMinM))
}

private func sliderToRadius(_ t: Float) -> Double {
    let raw = sliderMinM * exp(Double(t) * log(sliderMaxM / sliderMinM))
    let step: Double = raw < 200 ? 10 : (raw < 1_000 ? 25 : 100)
    return (raw / step).rounded() * step
}

private func zoomForRadius(_ r: Double) -> Double {
    if r <= 100 { return 17 }
    if r <= 250 { return 16 }
    if r <= 500 { return 15 }
    if r <= 1_000 { return 14 }
    if r <= 2_500 { return 13 }
    if r <= 5_000 { return 12 }
    if r <= 15_000 { return 11 }
    return 9
}

private func formatDistance(_ metres: Double) -> String {
    if metres < 1_000 { return "\(Int(metres.rounded())) m" }
    return String(format: "%.1f km", metres / 1_000).replacingOccurrences(of: ".0 km", with: " km")
}
