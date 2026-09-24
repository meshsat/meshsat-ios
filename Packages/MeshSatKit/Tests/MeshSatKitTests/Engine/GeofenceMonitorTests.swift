// Mirrors GeofenceMonitorTest.kt: point in polygon, enter and exit, the event log.
import MeshSatEngine
import XCTest

final class GeofenceMonitorTests: XCTestCase {
    private func squareZone(
        centerLat: Double = 47, centerLon: Double = -122, size: Double = 0.01, id: String = "test_zone", name: String = "Test Zone",
        alertOn: String = "both"
    ) -> GeofenceZone {
        GeofenceZone(
            id: id, name: name,
            polygon: [
                LatLon(lat: centerLat - size, lon: centerLon - size), LatLon(lat: centerLat - size, lon: centerLon + size),
                LatLon(lat: centerLat + size, lon: centerLon + size), LatLon(lat: centerLat + size, lon: centerLon - size),
            ], alertOn: alertOn)
    }

    func testPointInsidePolygonDetected() {
        XCTAssertTrue(GeofenceMonitor.pointInPolygon(lat: 47, lon: -122, polygon: squareZone().polygon))
    }

    func testPointOutsidePolygonNotDetected() {
        XCTAssertFalse(GeofenceMonitor.pointInPolygon(lat: 48, lon: -122, polygon: squareZone().polygon))
    }

    func testEnterEventTriggeredWhenNodeEntersZone() {
        let m = GeofenceMonitor()
        m.addZone(squareZone())
        XCTAssertEqual(m.checkPosition(nodeId: "node1", lat: 48, lon: -122).count, 0)
        let events = m.checkPosition(nodeId: "node1", lat: 47, lon: -122)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "enter")
    }

    func testExitEventTriggeredWhenNodeLeavesZone() {
        let m = GeofenceMonitor()
        m.addZone(squareZone())
        m.checkPosition(nodeId: "node1", lat: 47, lon: -122)
        let events = m.checkPosition(nodeId: "node1", lat: 48, lon: -122)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "exit")
    }

    func testNoEventWhenNodeStaysInside() {
        let m = GeofenceMonitor()
        m.addZone(squareZone())
        m.checkPosition(nodeId: "node1", lat: 47, lon: -122)
        XCTAssertEqual(m.checkPosition(nodeId: "node1", lat: 47.001, lon: -122.001).count, 0)
    }

    func testEnterOnlyZoneDoesNotTriggerExit() {
        let m = GeofenceMonitor()
        m.addZone(squareZone(alertOn: "enter"))
        m.checkPosition(nodeId: "node1", lat: 47, lon: -122)
        XCTAssertEqual(m.checkPosition(nodeId: "node1", lat: 48, lon: -122).count, 0)
    }

    func testEventLogRecordsEvents() {
        let m = GeofenceMonitor()
        m.addZone(squareZone())
        XCTAssertEqual(m.getEvents().count, 0)
        m.checkPosition(nodeId: "node1", lat: 47, lon: -122)
        XCTAssertEqual(m.getEvents().count, 1)
        XCTAssertEqual(m.getEvents()[0].event, "enter")
        m.checkPosition(nodeId: "node1", lat: 48, lon: -122)
        XCTAssertEqual(m.getEvents().count, 2)
    }

    func testMultipleZonesTrackedIndependently() {
        let m = GeofenceMonitor()
        m.addZone(squareZone(centerLat: 47, id: "z1", name: "Zone 1"))
        m.addZone(squareZone(centerLat: 48, id: "z2", name: "Zone 2"))
        let events = m.checkPosition(nodeId: "node1", lat: 47, lon: -122)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].zone.name, "Zone 1")
    }

    func testRemoveZoneStopsTracking() {
        let m = GeofenceMonitor()
        m.addZone(squareZone())
        m.removeZone("test_zone")
        XCTAssertEqual(m.checkPosition(nodeId: "node1", lat: 47, lon: -122).count, 0)
    }

    func testGetZonesReturnsCopy() {
        let m = GeofenceMonitor()
        m.addZone(squareZone())
        XCTAssertEqual(m.getZones().count, 1)
        XCTAssertEqual(m.getZones()[0].name, "Test Zone")
    }

    func testACirclePolygonHasItsRadius() {
        let poly = GeofenceMonitor.circlePolygon(centerLat: 52.37, centerLon: 4.89, radiusMeters: 200)
        XCTAssertEqual(poly.count, 32)
        XCTAssertEqual(GeofenceMonitor.zoneRadius(poly), 200, accuracy: 2)
        XCTAssertTrue(GeofenceMonitor.pointInPolygon(lat: 52.37, lon: 4.89, polygon: poly))
    }
}
