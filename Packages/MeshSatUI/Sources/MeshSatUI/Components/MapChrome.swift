// Mirrors ui/components/MapChrome.kt and MapFocus.kt (MESHSAT-1249): the pieces the Map tab and
// Zones share, so both maps draw the same tiles, markers and controls. The map itself is an
// MKMapView under a MeshSat tile overlay (OpenStreetMap, the user's MBTiles, the world
// overview), with the markers drawn by MarkerPainter, as osmdroid draws them on Android.
import MapKit
import MeshSatEngine
import MeshSatMeshtastic
import MeshSatPlatform
import MeshSatStore
import SwiftUI

/// A node not heard from for this long is drawn faded; People and Topology use the same 15 minutes.
let staleAfterMs: Int64 = 15 * 60_000

/// People > Show on map: the node number to centre on once its position is known.
@Observable
@MainActor
public final class MapFocus {
    public var node: Int64?
    public init() {}
    public func show(_ nodeNum: Int64) { node = nodeNum }
    public func consumed() { node = nil }
}

/// Names the radio knows, by node number. Position rows only carry the id ("!a1b2c3d4").
func meshNodeNames(_ nodes: [MeshtasticProtocol.MeshNodeInfo]) -> [Int64: String] {
    var out: [Int64: String] = [:]
    for n in nodes {
        let name = n.longName.isEmpty ? n.shortName : n.longName
        if !name.isEmpty { out[Int64(n.nodeNum)] = name }
    }
    return out
}

/// What a position is called on the map: the radio's name, else the name it came with, else its id.
func positionLabel(_ node: NodePosition, _ names: [Int64: String]) -> String {
    names[node.nodeId] ?? (node.nodeName.isEmpty ? MeshtasticProtocol.formatNodeId(UInt32(truncatingIfNeeded: node.nodeId)) : node.nodeName)
}

/// A zoom level that shows a span of `spanDegrees` (the larger of latitude and longitude spans).
func zoomForSpan(_ spanDegrees: Double) -> Double {
    if spanDegrees < 0.002 { return 16 }
    if spanDegrees < 0.01 { return 15 }
    if spanDegrees < 0.05 { return 13 }
    if spanDegrees < 0.2 { return 11 }
    if spanDegrees < 1.0 { return 9 }
    if spanDegrees < 5.0 { return 7 }
    if spanDegrees < 30.0 { return 5 }
    return 3
}

/// "Heard 3 min ago", or "Last heard 2 h ago" once the node is stale.
func heardLine(_ timestamp: Int64, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> String {
    let ago = Words.ago(timestamp, nowMs: now)
    return now - timestamp > staleAfterMs ? "Last heard \(ago)" : "Heard \(ago)"
}

/// "Within about 12 m", or "Accuracy unknown".
func accuracyLine(_ fix: PhoneFix) -> String {
    fix.horizontalAccuracyM >= 1 ? "Within about \(Int(fix.horizontalAccuracyM)) m" : "Accuracy unknown"
}

/// What a map is told to do, from the buttons and the panel: the map view keeps its own camera.
enum MapCommand: Equatable {
    case centre(lat: Double, lon: Double, minZoom: Double, animate: Bool)
    case fit(points: [(Double, Double)], animate: Bool)
    case zoomIn, zoomOut
    case maxZoom(Double)

    static func == (a: MapCommand, b: MapCommand) -> Bool {
        switch (a, b) {
        case (.centre(let la, let lo, let z, let an), .centre(let lb, let lob, let zb, let anb)):
            la == lb && lo == lob && z == zb && an == anb
        case (.fit(let pa, let an), .fit(let pb, let anb)):
            an == anb && pa.count == pb.count && zip(pa, pb).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.zoomIn, .zoomIn), (.zoomOut, .zoomOut): true
        case (.maxZoom(let a), .maxZoom(let b)): a == b
        default: false
        }
    }
}

/// A command with a serial number, so the same command twice still reaches the map.
struct MapCommandTicket: Equatable {
    let seq: Int
    let command: MapCommand
}

/// A round 48 dp button that sits on the map.
struct MapButton: View {
    let icon: Image
    let description: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            icon.resizable().scaledToFit().frame(width: 24, height: 24).foregroundStyle(MSColors.textPrimary)
                .frame(width: MSSpace.touch, height: MSSpace.touch)
                .background(MSColors.surface, in: Circle())
                .overlay(Circle().stroke(MSColors.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(description)
    }
}

/// The line in the map's corner: which offline map is showing while online tiles cannot load,
/// and the OpenStreetMap credit while they can.
struct MapStatusNote: View {
    let detailed: DetailedMap?
    let offline: Bool
    var worldOnlyNote: String?

    var body: some View {
        let text: String? =
            if offline, let detailed {
                "Offline map: \(detailed.name). Outside it, the world overview."
            } else if offline {
                worldOnlyNote ?? "Offline map: world overview, country level only. Add a detailed map in Setup > Maps."
            } else {
                nil
            }
        VStack(alignment: .leading, spacing: 4) {
            if let text {
                Text(text).msText(.bodySmall)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(MSColors.bg.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
            } else {
                Text("\u{00A9} OpenStreetMap contributors").msText(.bodySmall, color: MSColors.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(MSColors.bg.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
    }
}

final class NodeAnnotation: NSObject, MKAnnotation {
    let nodeId: Int64
    dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    var subtitle: String?
    var icon: MarkerIcon?
    init(nodeId: Int64, coordinate: CLLocationCoordinate2D) {
        self.nodeId = nodeId
        self.coordinate = coordinate
    }
}

final class TrackPolyline: MKPolyline {
    var label = ""
}

/// The map view: the tiles, three layers bottom to top (tracks, nodes, this phone), each
/// refilled on its own, so a phone fix no longer rebuilds every node marker and track.
struct MeshMapView: UIViewRepresentable {
    let detailed: DetailedMap?
    let night: Bool
    let nodes: [NodePosition]
    let tracks: [NodePosition]
    let names: [Int64: String]
    let phone: PhoneFix?
    let now: Int64
    let ticket: MapCommandTicket?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = .standard
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = false
        map.showsScale = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.overrideUserInterfaceStyle = .dark
        map.backgroundColor = UIColor(MSColors.bg)
        map.setRegion(Self.region(center: CLLocationCoordinate2D(latitude: 20, longitude: 0), zoom: 3, width: 390), animated: false)
        context.coordinator.install(map, detailed: detailed, night: night)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        if c.overlay?.detailedPath != detailed?.file.path || c.overlay?.night != night {
            c.install(map, detailed: detailed, night: night)
        }
        c.apply(self, to: map)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The region that shows `zoom` (slippy-map levels, 256 pt tiles) centred on `center`.
    static func region(center: CLLocationCoordinate2D, zoom: Double, width: CGFloat) -> MKCoordinateRegion {
        let lonDelta = 360 * Double(max(width, 1)) / (256 * pow(2, zoom))
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: lonDelta * 0.5, longitudeDelta: min(lonDelta, 360)))
    }

    static func zoom(of map: MKMapView) -> Double {
        let lonDelta = map.region.span.longitudeDelta
        guard lonDelta > 0 else { return 3 }
        return log2(360 * Double(max(map.bounds.width, 1)) / (256 * lonDelta))
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var overlay: MeshSatTileOverlay?
        private var nodeAnnotations: [Int64: NodeAnnotation] = [:]
        private var phoneAnnotation: NodeAnnotation?
        private var accuracyCircle: MKCircle?
        private var trackLines: [TrackPolyline] = []
        private var lastTicket: Int = -1
        private var lastNight: Bool?
        private var painter: MarkerPainter?
        private var lastTracksKey = ""
        private var lastNodesKey = ""
        private var lastPhoneKey = ""

        func install(_ map: MKMapView, detailed: DetailedMap?, night: Bool) {
            if let old = overlay { map.removeOverlay(old) }
            let fresh = MapTiles.newOverlay(detailed: detailed?.file, night: night)
            overlay = fresh
            map.insertOverlay(fresh, at: 0, level: .aboveLabels)
            if lastNight != night {
                lastNight = night
                let bg = UIColor(MSColors.bg)
                let primary = UIColor(MSColors.textPrimary)
                let muted = UIColor(MSColors.textMuted)
                painter = MarkerPainter(
                    labelPt: 12, maxLabelPt: 144, font: UIFont(name: MSFont.sansRegular, size: 12) ?? .systemFont(ofSize: 12),
                    bg: night ? bg.nightRed() : bg, textPrimary: night ? primary.nightRed() : primary,
                    textMuted: night ? muted.nightRed() : muted)
                lastNodesKey = ""
                lastPhoneKey = ""
                lastTracksKey = ""
            }
        }

        func apply(_ v: MeshMapView, to map: MKMapView) {
            guard let painter else { return }
            let night = v.night
            let mesh = night ? UIColor(MSColors.mesh).nightRed() : UIColor(MSColors.mesh)
            let teal = night ? UIColor(MSColors.teal).nightRed() : UIColor(MSColors.teal)
            let latest = Dictionary(v.nodes.map { ($0.nodeId, $0) }, uniquingKeysWith: { a, _ in a })

            let tracksKey = "\(v.tracks.count)|\(v.tracks.last?.id ?? 0)|\(v.nodes.map(\.timestamp).reduce(0, +))|\(v.names.count)"
            if tracksKey != lastTracksKey {
                lastTracksKey = tracksKey
                map.removeOverlays(trackLines)
                trackLines = []
                for (id, points) in Dictionary(grouping: v.tracks, by: \.nodeId) {
                    var path = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    // Tracks are re-read every 30 s; the newest position joins the line straight away.
                    if let last = latest[id], let end = points.last, last.timestamp > end.timestamp {
                        path.append(CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude))
                    }
                    if path.count < 2 { continue }
                    let line = TrackPolyline(coordinates: path, count: path.count)
                    line.label = "Track of " + positionLabel(latest[id] ?? points[points.count - 1], v.names)
                    trackLines.append(line)
                }
                map.addOverlays(trackLines, level: .aboveLabels)
            }

            let nodesKey = "\(v.nodes.map { "\($0.nodeId):\($0.timestamp)" }.joined())|\(v.names.count)|\(v.now / 60_000)"
            if nodesKey != lastNodesKey {
                lastNodesKey = nodesKey
                let keep = Set(v.nodes.map(\.nodeId))
                for (id, a) in nodeAnnotations where !keep.contains(id) {
                    map.removeAnnotation(a)
                    nodeAnnotations[id] = nil
                }
                for node in v.nodes {
                    let label = positionLabel(node, v.names)
                    let stale = v.now - node.timestamp > staleAfterMs
                    let coord = CLLocationCoordinate2D(latitude: node.latitude, longitude: node.longitude)
                    // Markers are kept per node, so an open bubble stays with its node when it moves.
                    let a: NodeAnnotation
                    if let existing = nodeAnnotations[node.nodeId] {
                        a = existing
                        a.coordinate = coord
                    } else {
                        a = NodeAnnotation(nodeId: node.nodeId, coordinate: coord)
                        nodeAnnotations[node.nodeId] = a
                        map.addAnnotation(a)
                    }
                    a.title = label
                    a.subtitle = heardLine(node.timestamp, now: v.now) + (node.altitude != 0 ? ", altitude \(node.altitude) m" : "")
                    a.icon = painter.node(label: label, fill: mesh, stale: stale)
                    if let view = map.view(for: a) { Self.style(view, a) }
                }
            }

            let phoneKey = v.phone.map { "\($0.latitude),\($0.longitude),\($0.horizontalAccuracyM)" } ?? "none"
            if phoneKey != lastPhoneKey {
                lastPhoneKey = phoneKey
                if let circle = accuracyCircle {
                    map.removeOverlay(circle)
                    accuracyCircle = nil
                }
                if let fix = v.phone {
                    let here = CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
                    let a = phoneAnnotation ?? NodeAnnotation(nodeId: 0, coordinate: here)
                    a.coordinate = here
                    a.title = "This phone"
                    a.subtitle = accuracyLine(fix)
                    a.icon = painter.dot(fill: teal, sizePt: 18)
                    if phoneAnnotation == nil {
                        phoneAnnotation = a
                        map.addAnnotation(a)
                    } else if let view = map.view(for: a) {
                        Self.style(view, a)
                    }
                    if fix.horizontalAccuracyM >= 1 {
                        let circle = MKCircle(center: here, radius: fix.horizontalAccuracyM)
                        accuracyCircle = circle
                        map.addOverlay(circle, level: .aboveLabels)
                    }
                } else if let a = phoneAnnotation {
                    map.removeAnnotation(a)
                    phoneAnnotation = nil
                }
            }

            if let t = v.ticket, t.seq != lastTicket {
                lastTicket = t.seq
                run(t.command, on: map)
            }
        }

        private func run(_ command: MapCommand, on map: MKMapView) {
            let width = map.bounds.width > 0 ? map.bounds.width : 390
            switch command {
            case .centre(let lat, let lon, let minZoom, let animate):
                let zoom = max(MeshMapView.zoom(of: map), minZoom)
                map.setRegion(
                    MeshMapView.region(center: CLLocationCoordinate2D(latitude: lat, longitude: lon), zoom: zoom, width: width),
                    animated: animate)
            case .fit(let points, let animate):
                guard let first = points.first else { return }
                var minLat = first.0
                var maxLat = first.0
                var minLon = first.1
                var maxLon = first.1
                for (lat, lon) in points {
                    minLat = min(minLat, lat)
                    maxLat = max(maxLat, lat)
                    minLon = min(minLon, lon)
                    maxLon = max(maxLon, lon)
                }
                let centre = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
                map.setRegion(
                    MeshMapView.region(center: centre, zoom: zoomForSpan(max(maxLat - minLat, maxLon - minLon)), width: width),
                    animated: animate)
            case .zoomIn:
                map.setRegion(
                    MeshMapView.region(center: map.centerCoordinate, zoom: min(19, MeshMapView.zoom(of: map) + 1), width: width),
                    animated: true)
            case .zoomOut:
                map.setRegion(
                    MeshMapView.region(center: map.centerCoordinate, zoom: max(2, MeshMapView.zoom(of: map) - 1), width: width),
                    animated: true)
            case .maxZoom(let z):
                if MeshMapView.zoom(of: map) > z {
                    map.setRegion(MeshMapView.region(center: map.centerCoordinate, zoom: z, width: width), animated: false)
                }
            }
        }

        static func style(_ view: MKAnnotationView, _ a: NodeAnnotation) {
            view.image = a.icon?.image
            view.centerOffset = a.icon?.centerOffset ?? .zero
            view.canShowCallout = true
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tiles) }
            if let circle = overlay as? MKCircle {
                let r = MKCircleRenderer(circle: circle)
                let teal = lastNight == true ? UIColor(MSColors.teal).nightRed() : UIColor(MSColors.teal)
                r.fillColor = teal.withAlphaComponent(0.12)
                r.strokeColor = teal.withAlphaComponent(0.5)
                r.lineWidth = 1.5
                return r
            }
            if let line = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: line)
                let mesh = lastNight == true ? UIColor(MSColors.mesh).nightRed() : UIColor(MSColors.mesh)
                r.strokeColor = mesh.withAlphaComponent(0.75)
                r.lineWidth = 3
                r.lineCap = .round
                r.lineDashPattern = [8, 5]
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            guard let a = annotation as? NodeAnnotation else { return nil }
            let id = "meshsat-marker"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) ?? MKAnnotationView(annotation: a, reuseIdentifier: id)
            view.annotation = a
            Self.style(view, a)
            return view
        }
    }
}
