// Mirrors tak/TakProto.kt: CotEvent to and from TAK Protocol v1 (protobuf), and the two
// framings: 0xBF <varint length> <protobuf> on a TCP stream, 0xBF 0x01 0xBF <protobuf> on
// UDP multicast.
import Foundation
import MeshSatProto
import SwiftProtobuf

public enum TakProto {
    public static let magic: UInt8 = 0xBF
    public static let version: UInt8 = 0x01

    /// A CotEvent as TakMessage bytes, unframed.
    public static func cotEventToProto(_ ev: CotEvent) -> [UInt8] {
        var cot = Atakmap_Commoncommo_Protobuf_V1_CotEvent()
        cot.type = ev.type
        cot.uid = ev.uid
        cot.how = ev.how
        cot.sendTime = parseTime(ev.time)
        cot.startTime = parseTime(ev.start)
        cot.staleTime = parseTime(ev.stale)
        cot.lat = ev.point.lat
        cot.lon = ev.point.lon
        cot.hae = ev.point.hae
        cot.ce = ev.point.ce
        cot.le = ev.point.le
        var detail = Atakmap_Commoncommo_Protobuf_V1_Detail()
        if let c = ev.detail?.contact {
            var contact = Atakmap_Commoncommo_Protobuf_V1_Contact()
            contact.callsign = c.callsign
            detail.contact = contact
        }
        if let g = ev.detail?.group {
            var group = Atakmap_Commoncommo_Protobuf_V1_Group()
            group.name = g.name
            group.role = g.role
            detail.group = group
        }
        if let p = ev.detail?.precision {
            var precision = Atakmap_Commoncommo_Protobuf_V1_PrecisionLocation()
            precision.geopointsrc = p.geoPointSrc
            precision.altsrc = p.altSrc
            detail.precisionLocation = precision
        }
        if let t = ev.detail?.track {
            var track = Atakmap_Commoncommo_Protobuf_V1_Track()
            track.speed = t.speed
            track.course = t.course
            detail.track = track
        }
        if let s = ev.detail?.status, let bat = Int(s.battery), bat > 0 {
            var status = Atakmap_Commoncommo_Protobuf_V1_Status()
            status.battery = UInt32(bat)
            detail.status = status
        }
        // Emergency and remarks travel as xmlDetail, unescaped as Android writes them.
        var xmlExtra = ""
        if let e = ev.detail?.emergency { xmlExtra += "<emergency type=\"\(e.type)\">\(e.text)</emergency>" }
        if let r = ev.detail?.remarks { xmlExtra += "<remarks source=\"\(r.source)\">\(r.text)</remarks>" }
        if !xmlExtra.isEmpty { detail.xmlDetail = xmlExtra }
        cot.detail = detail
        var msg = Atakmap_Commoncommo_Protobuf_V1_TakMessage()
        msg.cotEvent = cot
        return (try? msg.serializedBytes()) ?? []
    }

    /// 0xBF <varint length> <payload>, for a TCP stream.
    public static func frameForStream(_ payload: [UInt8]) -> [UInt8] {
        [magic] + encodeVarint(UInt64(payload.count)) + payload
    }

    /// 0xBF 0x01 0xBF <payload>, for UDP multicast.
    public static func frameForMulticast(_ payload: [UInt8]) -> [UInt8] {
        [magic, version, magic] + payload
    }

    /// A CotEvent from TakMessage bytes; nil when they are not one or carry no event.
    public static func protoToCotEvent(_ data: [UInt8]) -> CotEvent? {
        guard let msg = try? Atakmap_Commoncommo_Protobuf_V1_TakMessage(serializedBytes: data), msg.hasCotEvent else { return nil }
        let c = msg.cotEvent
        let d = c.hasDetail ? c.detail : nil
        let contact =
            (d?.hasContact ?? false) && !(d?.contact.callsign.isEmpty ?? true) ? CotContact(callsign: d?.contact.callsign ?? "") : nil
        let group =
            (d?.hasGroup ?? false) && !(d?.group.name.isEmpty ?? true)
            ? CotGroup(name: d?.group.name ?? "", role: d?.group.role ?? "") : nil
        let precision =
            (d?.hasPrecisionLocation ?? false) && !(d?.precisionLocation.geopointsrc.isEmpty ?? true)
            ? CotPrecision(altSrc: d?.precisionLocation.altsrc ?? "", geoPointSrc: d?.precisionLocation.geopointsrc ?? "") : nil
        // Android's TakProto swaps speed and course here; the Bridge does not, and its order is
        // the one kept (course, then speed).
        let track =
            (d?.hasTrack ?? false) && (d?.track.speed != 0 || d?.track.course != 0)
            ? CotTrack(course: d?.track.course ?? 0, speed: d?.track.speed ?? 0) : nil
        let status = (d?.hasStatus ?? false) && (d?.status.battery ?? 0) > 0 ? CotStatus(battery: String(d?.status.battery ?? 0)) : nil
        return CotEvent(
            uid: c.uid, type: c.type, how: c.how, time: formatTime(c.sendTime), start: formatTime(c.startTime),
            stale: formatTime(c.staleTime),
            point: CotPoint(lat: c.lat, lon: c.lon, hae: c.hae, ce: c.ce, le: c.le),
            detail: CotDetail(contact: contact, group: group, precision: precision, track: track, status: status))
    }

    /// Milliseconds since the epoch from yyyy-MM-dd'T'HH:mm:ss'Z'; 0 when malformed.
    static func parseTime(_ iso: String) -> UInt64 {
        let parts = iso.split(whereSeparator: { "-T:Z".contains($0) }).compactMap { Int($0) }
        guard parts.count == 6 else { return 0 }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let comps = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], second: parts[5])
        guard let date = cal.date(from: comps), date.timeIntervalSince1970 > 0 else { return 0 }
        return UInt64(date.timeIntervalSince1970 * 1000)
    }

    static func formatTime(_ millis: UInt64) -> String {
        millis > 0 ? CotBuilder.formatTime(Date(timeIntervalSince1970: TimeInterval(millis) / 1000)) : ""
    }

    static func encodeVarint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        while v > 0x7F {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v & 0x7F))
        return out
    }
}
