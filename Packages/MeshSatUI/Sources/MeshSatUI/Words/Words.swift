// Mirrors ui/Words.kt: the words the app shows for its own machinery (MESHSAT-1249), in one
// place so a channel or a state is called the same thing on every screen. Internal ids
// (iridium_0, sms_0) and raw states (dead, retry) never reach the user.
import Foundation
import SwiftUI

public enum Words {
    /// An interface or channel id, as the user knows it.
    public static func channel(_ id: String) -> String {
        if id.hasPrefix("iridium9704") { return "Satellite (RockBLOCK 9704)" }
        if id.hasPrefix("iridium") { return "Satellite" }
        if id.hasPrefix("mesh") { return "Mesh" }
        if id.hasPrefix("sms") { return "SMS" }
        // hub_relay before hub_0: the relay is a tunnel to another bridge, not the Hub itself.
        if id.contains("relay") { return "Hub relay" }
        if id.hasPrefix("hub") { return "Hub" }
        if id.hasPrefix("mqtt") { return "MQTT broker" }
        if id.hasPrefix("aprs") { return "Ham radio" }
        if id.hasPrefix("tcp_rns") || id.hasPrefix("rns") { return "Reticulum" }
        if id.trimmingCharacters(in: .whitespaces).isEmpty { return "Unknown" }
        return id
    }

    /// A message's transport field ("iridium", "mesh", "sms", ...), as the user knows it.
    public static func transport(_ t: String) -> String {
        switch t.lowercased() {
        case "iridium", "sbd", "iridium9704", "imt": return "Satellite"
        case "mesh", "meshtastic", "lora": return "Mesh"
        case "sms", "cellular": return "SMS"
        case "mqtt", "hub": return "Hub"
        case "aprs": return "Ham radio"
        case "reticulum", "rns": return "Reticulum"
        case "tak": return "TAK"
        default: return t.prefix(1).uppercased() + t.dropFirst()
        }
    }

    /// The colour of a transport, from the Bridge's route lanes.
    public static func transportColor(_ t: String) -> Color {
        switch transport(t) {
        case "Satellite": return MSColors.iridium
        case "Mesh": return MSColors.mesh
        case "SMS": return MSColors.cellular
        case "Hub", "Hub relay": return MSColors.hub
        case "Ham radio": return MSColors.radio
        default: return MSColors.textSecondary
        }
    }

    public static func channelColor(_ id: String) -> Color {
        if id.hasPrefix("iridium") { return transportColor("iridium") }
        if id.hasPrefix("mesh") { return transportColor("mesh") }
        if id.hasPrefix("sms") { return transportColor("sms") }
        if id.hasPrefix("mqtt") || id.hasPrefix("hub") || id.contains("relay") { return transportColor("hub") }
        if id.hasPrefix("aprs") { return transportColor("aprs") }
        return transportColor(id)
    }

    /// A delivery's status in the queue.
    public static func deliveryState(_ status: String) -> String {
        switch status.lowercased() {
        case "queued": return "Waiting"
        case "retry": return "Waiting to retry"
        case "held": return "On hold until the link is back"
        case "sending": return "Sending"
        case "awaiting_user": return "Waiting for you to send it"
        case "sent": return "Sent"
        case "delivered", "acked": return "Delivered"
        case "failed": return "Failed"
        case "dead": return "Gave up"
        case "expired": return "Expired"
        case "denied": return "Blocked by a rule"
        case "cancelled": return "Cancelled"
        default: return status.prefix(1).uppercased() + status.dropFirst()
        }
    }

    public static func deliveryColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "sent", "delivered", "acked": return MSColors.green
        case "queued", "retry", "held", "sending", "awaiting_user": return MSColors.amber
        case "failed", "dead", "expired", "denied": return MSColors.red
        default: return MSColors.textMuted
        }
    }

    /// An interface's link state.
    public static func linkState(_ state: String) -> String {
        switch state.lowercased() {
        case "online": return "Working"
        case "connecting": return "Connecting"
        case "offline": return "Off"
        case "error": return "Not working"
        case "disabled": return "Switched off"
        default: return state.prefix(1).uppercased() + state.dropFirst()
        }
    }

    /// "1 message", "3 messages".
    public static func count(_ n: Int, _ one: String, _ many: String? = nil) -> String { "\(n) \(n == 1 ? one : (many ?? one + "s"))" }

    /// A moment in the past, relative: "just now", "4 min ago", "2 h ago", "3 days ago".
    public static func ago(_ epochMs: Int64, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> String {
        if epochMs <= 0 { return "never" }
        let s = max(0, (nowMs - epochMs) / 1000)
        if s < 45 { return "just now" }
        if s < 3600 { return "\((s + 30) / 60) min ago" }
        if s < 86_400 { return "\(s / 3600) h ago" }
        return count(Int(s / 86_400), "day") + " ago"
    }

    /// A moment ahead, relative: "now", "in 4 min", "in 2 h 10 min".
    public static func inTime(_ epochMs: Int64, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> String {
        let s = (epochMs - nowMs) / 1000
        if s <= 30 { return "now" }
        if s < 3600 { return "in \((s + 30) / 60) min" }
        return "in \(s / 3600) h \((s % 3600) / 60) min"
    }

    /// "MM/dd HH:mm" and "HH:mm" and "HH:mm:ss" in the phone's zone, as the Kotlin SimpleDateFormats.
    public static func clock(_ epochMs: Int64, _ pattern: String) -> String {
        let f = DateFormatter()
        f.dateFormat = pattern
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date(timeIntervalSince1970: Double(epochMs) / 1000))
    }
}
