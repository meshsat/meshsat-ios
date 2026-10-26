// Mirrors tak/CotBuilder.kt: CoT v2.0 events in the Bridge's exact wire format. Callsigns are
// "{prefix}-{suffix}", the suffix being the last 4 characters of the device id. The clock is a
// parameter so tests are exact.
import Foundation

public enum CotBuilder {
    public static let defaultStaleSec = 300

    /// A contact reached through its server: what lets a TAK client offer chat with it (MESHSAT-1708).
    public static let takEndpoint = "*:-1:stcp"

    /// ATAK's name and id for the room every contact is in.
    public static let chatRoom = "All Chat Rooms"

    /// A GeoChat lives a day, as ATAK writes it.
    static let chatStaleSec = 86_400

    /// yyyy-MM-dd'T'HH:mm:ss'Z' in UTC, as SimpleDateFormat writes it.
    public static func formatTime(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func staleTime(_ date: Date, _ staleSec: Int) -> String {
        formatTime(date.addingTimeInterval(TimeInterval(staleSec)))
    }

    /// "MESHSAT-{last4}" from the device id, upper-cased; the prefix alone for an empty id.
    public static func callsign(_ deviceId: String, prefix: String = "MESHSAT") -> String {
        let suffix = String(deviceId.suffix(4)).uppercased()
        return suffix.isEmpty ? prefix : "\(prefix)-\(suffix)"
    }

    /// Position Location Information: a-f-G-U-C.
    public static func position(
        uid: String, callsign: String, lat: Double, lon: Double, alt: Double = 0, course: Double = 0, speed: Double = 0,
        battery: String = "", staleSec: Int = defaultStaleSec, now: Date = Date()
    ) -> CotEvent {
        let ts = formatTime(now)
        return CotEvent(
            uid: uid, type: CotType.position, how: CotHow.gps, time: ts, start: ts, stale: staleTime(now, staleSec),
            point: CotPoint(lat: lat, lon: lon, hae: alt, ce: 10, le: 10),
            detail: CotDetail(
                contact: CotContact(callsign: callsign, endpoint: takEndpoint), group: CotGroup(), precision: CotPrecision(),
                track: CotTrack(course: course, speed: speed), status: battery.isEmpty ? nil : CotStatus(battery: battery)))
    }

    /// SOS: a position with an emergency element.
    public static func sos(
        uid: String, callsign: String, lat: Double, lon: Double, alt: Double = 0, reason: String = "SOS", staleSec: Int = defaultStaleSec,
        now: Date = Date()
    ) -> CotEvent {
        var ev = position(uid: uid, callsign: callsign, lat: lat, lon: lon, alt: alt, staleSec: staleSec, now: now)
        ev.detail?.emergency = CotEmergency(type: "911 Alert", text: reason)
        ev.detail?.remarks = CotRemarks(source: "MeshSat", text: "Emergency: \(reason)")
        return ev
    }

    /// Dead man's switch timeout: b-a.
    public static func deadman(
        uid: String, callsign: String, lat: Double, lon: Double, timeoutSec: Int, staleSec: Int = defaultStaleSec, now: Date = Date()
    ) -> CotEvent {
        let ts = formatTime(now)
        return CotEvent(
            uid: "\(uid)-DEADMAN", type: CotType.alarm, how: CotHow.humanEntered, time: ts, start: ts, stale: staleTime(now, staleSec),
            point: CotPoint(lat: lat, lon: lon, hae: 0, ce: 100, le: 100),
            detail: CotDetail(
                contact: CotContact(callsign: callsign),
                remarks: CotRemarks(source: "MeshSat", text: "Dead man's switch timeout \u{2014} no check-in for \(timeoutSec)s")))
    }

    /// GeoChat: b-t-f, no position.
    public static func chat(uid: String, callsign: String, text: String, staleSec: Int = defaultStaleSec, now: Date = Date()) -> CotEvent {
        let ts = formatTime(now)
        let millis = Int64(now.timeIntervalSince1970 * 1000)
        return CotEvent(
            uid: "\(uid)-CHAT-\(String(millis, radix: 36))", type: CotType.chat, how: CotHow.humanGeochat, time: ts, start: ts,
            stale: staleTime(now, staleSec), point: CotPoint(lat: 0, lon: 0, hae: 0, ce: 9_999_999, le: 9_999_999),
            detail: CotDetail(contact: CotContact(callsign: callsign), remarks: CotRemarks(source: callsign, text: text)))
    }

    /// A GeoChat from one contact to another in the form ATAK writes it (MESHSAT-1708): __chat and
    /// chatgrp name both ends, link the sender, remarks the words and the recipient, and a dest asks
    /// the server to deliver it to the recipient only. Same shape as the Bridge's BuildGeoChat.
    public static func geoChat(
        fromUid: String, fromCallsign: String, toUid: String, toCallsign: String, text: String,
        messageId: String = UUID().uuidString.lowercased(), now: Date = Date()
    ) -> CotEvent {
        let ts = formatTime(now)
        return CotEvent(
            uid: "GeoChat.\(fromUid).\(toUid).\(messageId)", type: CotType.chat, how: CotHow.humanGeochat, time: ts, start: ts,
            stale: staleTime(now, chatStaleSec), point: CotPoint(lat: 0, lon: 0, hae: 9_999_999, ce: 9_999_999, le: 9_999_999),
            detail: CotDetail(
                remarks: CotRemarks(source: "BAO.F.ATAK.\(fromUid)", text: text, to: toUid, time: ts),
                chat: CotChat(
                    id: toUid, chatroom: toCallsign, senderCallsign: fromCallsign, messageId: messageId, uid0: fromUid, uid1: toUid),
                link: CotLink(uid: fromUid, type: CotType.position, relation: "p-p"),
                marti: [CotDest(uid: toUid, callsign: toCallsign)]))
    }

    /// Sensor data: t-x-d-d.
    public static func telemetry(
        uid: String, callsign: String, lat: Double, lon: Double, data: String, staleSec: Int = defaultStaleSec, now: Date = Date()
    ) -> CotEvent {
        let ts = formatTime(now)
        return CotEvent(
            uid: "\(uid)-SENSOR", type: CotType.sensor, how: CotHow.gps, time: ts, start: ts, stale: staleTime(now, staleSec),
            point: CotPoint(lat: lat, lon: lon, hae: 0, ce: 50, le: 50),
            detail: CotDetail(contact: CotContact(callsign: "\(callsign)-SENSOR"), remarks: CotRemarks(source: "MeshSat", text: data)))
    }

    /// A waypoint or marker.
    public static func waypoint(
        uid: String, callsign: String, lat: Double, lon: Double, name: String, description: String = "", staleSec: Int = defaultStaleSec,
        now: Date = Date()
    ) -> CotEvent {
        let ts = formatTime(now)
        let millis = Int64(now.timeIntervalSince1970 * 1000)
        return CotEvent(
            uid: "\(uid)-WP-\(String(millis, radix: 36))", type: CotType.waypoint, how: CotHow.humanEntered, time: ts, start: ts,
            stale: staleTime(now, staleSec), point: CotPoint(lat: lat, lon: lon, hae: 0, ce: 10, le: 10),
            detail: CotDetail(contact: CotContact(callsign: name), remarks: CotRemarks(source: callsign, text: description)))
    }

    /// A position with the fix quality in CE and LE (CE about HDOP x 5, LE about PDOP x 4).
    public static func enrichedPosition(
        uid: String, callsign: String, lat: Double, lon: Double, alt: Double = 0, course: Double = 0, speed: Double = 0,
        battery: String = "", hdop: Double = 0, pdop: Double = 0, staleSec: Int = defaultStaleSec, now: Date = Date()
    ) -> CotEvent {
        var ev = position(
            uid: uid, callsign: callsign, lat: lat, lon: lon, alt: alt, course: course, speed: speed, battery: battery, staleSec: staleSec,
            now: now)
        ev.point.ce = hdop > 0 ? hdop * 5 : (pdop > 0 ? pdop * 3 : 10)
        ev.point.le = pdop > 0 ? pdop * 4 : 10
        return ev
    }
}
