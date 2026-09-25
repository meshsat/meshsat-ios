// Mirrors tak/CotEvent.kt: the Cursor on Target v2.0 model, wire-compatible with the Bridge
// (tak_cot.go) and the Hub.
//
// <event version="2.0" uid="..." type="..." how="..." time="..." start="..." stale="...">
//   <point lat="..." lon="..." hae="..." ce="..." le="..."/>
//   <detail>
//     <contact callsign="..."/>
//     <__group name="..." role="..."/>
//     <precisionlocation altsrc="..." geopointsrc="..."/>
//     <track course="..." speed="..."/>
//     <status battery="..."/>
//     <emergency type="...">...</emergency>
//     <remarks source="...">...</remarks>
//   </detail>
// </event>
import Foundation

public struct CotEvent: Sendable, Equatable {
    public var version = "2.0"
    public var uid: String
    public var type: String
    public var how: String
    public var time: String
    public var start: String
    public var stale: String
    public var point: CotPoint
    public var detail: CotDetail?

    public init(
        version: String = "2.0", uid: String, type: String, how: String, time: String, start: String, stale: String, point: CotPoint,
        detail: CotDetail? = nil
    ) {
        self.version = version
        self.uid = uid
        self.type = type
        self.how = how
        self.time = time
        self.start = start
        self.stale = stale
        self.point = point
        self.detail = detail
    }
}

public struct CotPoint: Sendable, Equatable {
    public var lat: Double
    public var lon: Double
    public var hae = 0.0
    public var ce = 10.0
    public var le = 10.0
    public init(lat: Double, lon: Double, hae: Double = 0, ce: Double = 10, le: Double = 10) {
        self.lat = lat
        self.lon = lon
        self.hae = hae
        self.ce = ce
        self.le = le
    }
}

public struct CotDetail: Sendable, Equatable {
    public var contact: CotContact?
    public var group: CotGroup?
    public var precision: CotPrecision?
    public var track: CotTrack?
    public var status: CotStatus?
    public var emergency: CotEmergency?
    public var remarks: CotRemarks?
    public init(
        contact: CotContact? = nil, group: CotGroup? = nil, precision: CotPrecision? = nil, track: CotTrack? = nil,
        status: CotStatus? = nil, emergency: CotEmergency? = nil, remarks: CotRemarks? = nil
    ) {
        self.contact = contact
        self.group = group
        self.precision = precision
        self.track = track
        self.status = status
        self.emergency = emergency
        self.remarks = remarks
    }
}

public struct CotContact: Sendable, Equatable {
    public var callsign: String
    public init(callsign: String) { self.callsign = callsign }
}

public struct CotGroup: Sendable, Equatable {
    public var name = "Cyan"
    public var role = "Team Member"
    public init(name: String = "Cyan", role: String = "Team Member") {
        self.name = name
        self.role = role
    }
}

public struct CotPrecision: Sendable, Equatable {
    public var altSrc = "GPS"
    public var geoPointSrc = "GPS"
    public init(altSrc: String = "GPS", geoPointSrc: String = "GPS") {
        self.altSrc = altSrc
        self.geoPointSrc = geoPointSrc
    }
}

public struct CotTrack: Sendable, Equatable {
    public var course = 0.0
    public var speed = 0.0
    public init(course: Double = 0, speed: Double = 0) {
        self.course = course
        self.speed = speed
    }
}

public struct CotStatus: Sendable, Equatable {
    public var battery = ""
    public init(battery: String = "") { self.battery = battery }
}

public struct CotEmergency: Sendable, Equatable {
    public var type: String
    public var text: String
    public init(type: String, text: String) {
        self.type = type
        self.text = text
    }
}

public struct CotRemarks: Sendable, Equatable {
    public var source = ""
    public var text: String
    public init(source: String = "", text: String) {
        self.source = source
        self.text = text
    }
}

/// CoT event types; they match the Bridge and the Hub exactly.
public enum CotType {
    /// Friendly ground unit position (PLI).
    public static let position = "a-f-G-U-C"
    /// Sensor/telemetry data.
    public static let sensor = "t-x-d-d"
    /// Alarm (dead man's switch, emergency).
    public static let alarm = "b-a"
    /// GeoChat/freetext message.
    public static let chat = "b-t-f"
    /// Waypoint/map marker.
    public static let waypoint = "b-m-p-s-p-loc"
    /// Circle drawing (geofence).
    public static let circle = "u-d-c-c"
}

/// CoT "how" values.
public enum CotHow {
    public static let gps = "m-g"
    public static let humanEntered = "h-e"
    public static let humanGeochat = "h-g-i-g-o"
}
