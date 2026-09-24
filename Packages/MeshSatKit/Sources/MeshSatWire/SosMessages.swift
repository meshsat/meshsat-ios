// Mirrors sos/SosMessages.kt: what an SOS says on each route (MESHSAT-1249). The Hub raises an
// alarm for any incoming text that contains one of `hubAlarmWords`, anywhere and in any case
// (meshsat-hub internal/sos/detector.go), and a kit on the same mesh forwards what it hears to
// the Hub. So an SOS says "SOS", and a test or a cancellation must never contain one of those
// words, not even inside the sender's name. The satellite frames are byte for byte the
// Bridge's EncodeSatSOS and EncodeSatPosition (internal/hubreporter/satuplink.go).
import Foundation

public enum SosMessages {
    public static let hubAlarmWords = ["SOS", "MAYDAY", "EMERGENCY"]
    /// Longest name used in a message, so an SMS stays in one part.
    public static let maxName = 24
    /// Longest text inside the satellite frame (the Bridge's maxSOSMessageLen).
    static let maxFrameMessage = 64
    static let maxFrameId = 16
    /// A fix older than this is called the last known position.
    static let staleFixMs: Int64 = 2 * 60_000

    /// A position: where, how precise, and when the phone measured it.
    public struct Fix: Sendable, Equatable {
        public var lat: Double
        public var lon: Double
        public var accuracyM: Float?
        public var timeMs: Int64
        public init(lat: Double, lon: Double, accuracyM: Float?, timeMs: Int64) {
            self.lat = lat
            self.lon = lon
            self.accuracyM = accuracyM
            self.timeMs = timeMs
        }
    }

    public static func containsAlarmWord(_ text: String) -> Bool {
        let upper = text.uppercased()
        return hubAlarmWords.contains { upper.contains($0) }
    }

    /// The user's name as it goes into a message: printable, trimmed, short.
    public static func cleanName(_ name: String) -> String {
        let printable = name.filter { c in !c.unicodeScalars.contains { $0.properties.generalCategory == .control } }.trimmingCharacters(
            in: .whitespaces)
        let cut = String(printable.prefix(maxName)).trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? "A MeshSat user" : cut
    }

    /// The name for a message that must not raise an alarm.
    static func quietName(_ name: String) -> String {
        let clean = cleanName(name)
        return containsAlarmWord(clean) ? "This phone" : clean
    }

    private static func fixed(_ v: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), v)
    }

    public static func coordinates(_ fix: Fix) -> String { "\(fixed(fix.lat, 5)), \(fixed(fix.lon, 5))" }

    static func utcTime(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)) + " UTC"
    }

    /// "At 52.16207, 4.50974 (within 12 m) at 14:03 UTC.", or the last position, or none.
    public static func whereText(_ fix: Fix?, nowMs: Int64) -> String {
        guard let fix else { return "Position unknown." }
        var within = ""
        if let acc = fix.accuracyM, acc > 0 { within = " (within \(Int(acc.rounded())) m)" }
        let lead = nowMs - fix.timeMs > staleFixMs ? "Last position" : "At"
        return "\(lead) \(coordinates(fix))\(within) at \(utcTime(fix.timeMs))."
    }

    /// Broadcast on the mesh.
    public static func meshText(name: String, fix: Fix?, nowMs: Int64) -> String {
        "SOS: \(cleanName(name)) needs help. \(whereText(fix, nowMs: nowMs))"
    }

    /// To each emergency contact, from the phone's own SIM: plain ASCII with a map link, at
    /// most 160 characters so it goes as one SMS whatever the name and the position.
    public static func smsText(name: String, fix: Fix?, nowMs: Int64) -> String {
        var ascii = cleanName(name).filter { $0.isASCII && ($0.asciiValue ?? 0) >= 32 && ($0.asciiValue ?? 0) <= 126 }
        if ascii.isEmpty { ascii = "A MeshSat user" }
        let base = "SOS: \(ascii) needs help. \(whereText(fix, nowMs: nowMs))"
        guard let fix else { return "\(base) Sent by MeshSat." }
        return "\(base) https://osm.org/?mlat=\(fixed(fix.lat, 5))&mlon=\(fixed(fix.lon, 5))"
    }

    /// The alert text the Hub shows for the satellite frame.
    public static func frameMessage(name: String, fix: Fix?) -> String {
        let text = "SOS: \(cleanName(name)) needs help" + (fix == nil ? ", position unknown" : "")
        return truncateUtf8(text, maxBytes: maxFrameMessage)
    }

    /// Sent on every route that carried the SOS, once the user cancels it.
    public static func cancelText(name: String) -> String {
        "Alarm cancelled: \(quietName(name)) is safe and needs no help now."
    }

    /// A test of the alarm routes: says it is a test and raises nothing at the Hub.
    public static func testText(name: String) -> String {
        "Test from \(quietName(name)): checking the MeshSat alarm routes. No help needed."
    }

    /// The SOS frame the Hub decodes from any bearer (magic "MS", type 0x02): ids and message
    /// length-prefixed and cut to 16, 16 and 64 bytes, positions big-endian float32, the time
    /// uint32 Unix seconds. Without a fix the position is 0, 0, as on the Bridge.
    public static func satFrame(bridgeId: String, deviceId: String, fix: Fix?, message: String, nowSec: Int64) -> [UInt8] {
        let bridge = Array(truncateUtf8(bridgeId, maxBytes: maxFrameId).utf8)
        let device = Array(truncateUtf8(deviceId, maxBytes: maxFrameId).utf8)
        let msg = Array(truncateUtf8(message, maxBytes: maxFrameMessage).utf8)
        var out: [UInt8] = [0x4D, 0x53, 1, 0x02]
        out.append(UInt8(bridge.count))
        out += bridge
        out.append(UInt8(device.count))
        out += device
        out += be32(Float(fix?.lat ?? 0).bitPattern)
        out += be32(Float(fix?.lon ?? 0).bitPattern)
        out.append(UInt8(msg.count))
        out += msg
        out += be32(UInt32(truncatingIfNeeded: nowSec))
        return out
    }

    /// A position report (magic "MS", type 0x01), byte for byte the Bridge's EncodeSatPosition:
    /// the alarm test's satellite leg. Height in whole metres, cut toward zero like Go's
    /// int16(float32); source 1 is GPS.
    public static func positionFrame(bridgeId: String, fix: Fix, altitudeM: Double, nowSec: Int64) -> [UInt8] {
        let bridge = Array(truncateUtf8(bridgeId, maxBytes: maxFrameId).utf8)
        var out: [UInt8] = [0x4D, 0x53, 1, 0x01]
        out.append(UInt8(bridge.count))
        out += bridge
        out += be32(Float(fix.lat).bitPattern)
        out += be32(Float(fix.lon).bitPattern)
        let alt = Int16(clamping: Int(Float(altitudeM).rounded(.towardZero)))
        out += [UInt8(truncatingIfNeeded: Int(alt) >> 8), UInt8(truncatingIfNeeded: Int(alt))]
        out.append(1)
        out += be32(UInt32(truncatingIfNeeded: nowSec))
        return out
    }

    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    /// Cut `s` to at most `maxBytes` of UTF-8 without splitting a character.
    public static func truncateUtf8(_ s: String, maxBytes: Int) -> String {
        if s.utf8.count <= maxBytes { return s }
        var out = ""
        var used = 0
        for scalar in s.unicodeScalars {
            let bytes = String(scalar).utf8.count
            if used + bytes > maxBytes { break }
            out.unicodeScalars.append(scalar)
            used += bytes
        }
        return out
    }
}
