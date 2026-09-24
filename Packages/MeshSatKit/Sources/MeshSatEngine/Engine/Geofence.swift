// Mirrors engine/GeofenceMonitor.kt (port of meshsat/internal/engine/geofence.go): polygonal
// zones with enter and exit alerts, node positions checked by ray casting, the transitions
// remembered per zone and node, and the last 50 events kept. Zones live in memory, as on
// Android, until the gateway restarts.
import Foundation
import Logging

public struct LatLon: Sendable, Equatable, Hashable {
    public let lat: Double
    public let lon: Double
    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

public struct GeofenceZone: Sendable, Equatable {
    public let id: String
    public let name: String
    public let polygon: [LatLon]
    /// "enter", "exit", "both"
    public let alertOn: String
    public let message: String
    public init(id: String, name: String, polygon: [LatLon], alertOn: String, message: String = "") {
        self.id = id
        self.name = name
        self.polygon = polygon
        self.alertOn = alertOn
        self.message = message
    }
}

/// A node entering or exiting a zone.
public struct GeofenceEvent: Sendable, Equatable {
    public let zone: GeofenceZone
    public let nodeId: String
    /// "enter" or "exit"
    public let event: String
}

/// A remembered event with its time.
public struct GeofenceEventRecord: Sendable, Equatable {
    public let zoneName: String
    public let nodeId: String
    public let event: String
    public let timestamp: Int64
}

public final class GeofenceMonitor: @unchecked Sendable {
    private static let log = Logger(label: "GeofenceMonitor")
    private let lock = NSLock()
    private var zones: [GeofenceZone] = []
    /// zone id -> node id -> was inside
    private var inside: [String: [String: Bool]] = [:]
    private var events: [GeofenceEventRecord] = []
    private var callbackValue: (@Sendable (GeofenceZone, String, String) -> Void)?
    private let now: @Sendable () -> Int64

    public init(now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) { self.now = now }

    public func setCallback(_ cb: (@Sendable (GeofenceZone, String, String) -> Void)?) {
        lock.lock()
        callbackValue = cb
        lock.unlock()
    }

    /// The recent events, newest first, at most 50.
    public func getEvents() -> [GeofenceEventRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(events.suffix(50).reversed())
    }

    public func addZone(_ zone: GeofenceZone) {
        lock.lock()
        zones.append(zone)
        inside[zone.id] = [:]
        lock.unlock()
        Self.log.info("geofence zone added: \(zone.id) '\(zone.name)' (\(zone.polygon.count) vertices)")
    }

    public func removeZone(_ id: String) {
        lock.lock()
        let had = zones.contains { $0.id == id }
        zones.removeAll { $0.id == id }
        inside[id] = nil
        lock.unlock()
        if had { Self.log.info("geofence zone removed: \(id)") }
    }

    public func getZones() -> [GeofenceZone] {
        lock.lock()
        defer { lock.unlock() }
        return zones
    }

    /// A node's position against every zone: the enter and exit transitions it caused.
    @discardableResult
    public func checkPosition(nodeId: String, lat: Double, lon: Double) -> [GeofenceEvent] {
        lock.lock()
        var out: [GeofenceEvent] = []
        var fire: [(GeofenceZone, String)] = []
        let stamp = now()
        for zone in zones {
            let nowInside = Self.pointInPolygon(lat: lat, lon: lon, polygon: zone.polygon)
            let wasInside = inside[zone.id]?[nodeId] ?? false
            if nowInside, !wasInside {
                if zone.alertOn == "enter" || zone.alertOn == "both" {
                    out.append(GeofenceEvent(zone: zone, nodeId: nodeId, event: "enter"))
                    events.append(GeofenceEventRecord(zoneName: zone.name, nodeId: nodeId, event: "enter", timestamp: stamp))
                    fire.append((zone, "enter"))
                }
                inside[zone.id, default: [:]][nodeId] = true
            } else if !nowInside, wasInside {
                if zone.alertOn == "exit" || zone.alertOn == "both" {
                    out.append(GeofenceEvent(zone: zone, nodeId: nodeId, event: "exit"))
                    events.append(GeofenceEventRecord(zoneName: zone.name, nodeId: nodeId, event: "exit", timestamp: stamp))
                    fire.append((zone, "exit"))
                }
                inside[zone.id]?[nodeId] = false
            }
        }
        let cb = callbackValue
        lock.unlock()
        for (zone, event) in fire { cb?(zone, nodeId, event) }
        return out
    }

    /// Ray casting: whether a point is inside a polygon.
    public static func pointInPolygon(lat: Double, lon: Double, polygon: [LatLon]) -> Bool {
        let n = polygon.count
        if n < 3 { return false }
        var inside = false
        var j = n - 1
        for i in 0..<n {
            let yi = polygon[i].lat
            let xi = polygon[i].lon
            let yj = polygon[j].lat
            let xj = polygon[j].lon
            if (yi > lat) != (yj > lat), lon < (xj - xi) * (lat - yi) / (yj - yi) + xi { inside.toggle() }
            j = i
        }
        return inside
    }

    /// A circle as a polygon of `numPoints` corners around a centre, by the equirectangular
    /// approximation (good for the sizes a zone has).
    public static func circlePolygon(centerLat: Double, centerLon: Double, radiusMeters: Double, numPoints: Int = 32) -> [LatLon] {
        let earthRadius = 6_371_000.0
        return (0..<numPoints).map { i in
            let angle = 2 * Double.pi * Double(i) / Double(numPoints)
            let dLat = radiusMeters * cos(angle) / earthRadius
            let dLon = radiusMeters * sin(angle) / (earthRadius * cos(centerLat * .pi / 180))
            return LatLon(lat: centerLat + dLat * 180 / .pi, lon: centerLon + dLon * 180 / .pi)
        }
    }

    /// Metres between two points (haversine), as Location.distanceBetween gives.
    public static func distanceM(_ a: LatLon, _ b: LatLon) -> Double {
        let r = 6_371_000.0
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.lat * .pi / 180) * cos(b.lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, h.squareRoot()))
    }

    /// A zone's radius, as the mean distance from its middle to its corners (zones made in the
    /// app are circles).
    public static func zoneRadius(_ polygon: [LatLon]) -> Double {
        guard !polygon.isEmpty else { return 0 }
        let lat = polygon.map(\.lat).reduce(0, +) / Double(polygon.count)
        let lon = polygon.map(\.lon).reduce(0, +) / Double(polygon.count)
        let c = LatLon(lat: lat, lon: lon)
        return polygon.map { distanceM(c, $0) }.reduce(0, +) / Double(polygon.count)
    }

    /// The middle of a zone.
    public static func centre(_ polygon: [LatLon]) -> LatLon? {
        guard !polygon.isEmpty else { return nil }
        return LatLon(
            lat: polygon.map(\.lat).reduce(0, +) / Double(polygon.count), lon: polygon.map(\.lon).reduce(0, +) / Double(polygon.count))
    }
}
