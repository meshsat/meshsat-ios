// Mirrors ble/NodeBattery.kt: the battery of the phone's own MeshSat node, from the device
// metrics the node sends the phone (MESHSAT-1315). The XIAO could not measure its supply; the
// T-Beam's power chip reports a percentage and a voltage, and Meshtastic reports
// `externalPower` while the node runs on USB.
import Foundation

public enum NodeBattery {
    /// What Meshtastic sends as the battery level of a node on external power.
    public static let externalPower = 101
    /// Readings older than this do not count towards the estimate.
    public static let windowMs: Int64 = 3 * 3_600_000
    /// An estimate needs this much time on battery, and `minDrop` points of drop, behind it.
    public static let minSpanMs: Int64 = 30 * 60_000
    public static let minDrop = 2

    public struct Reading: Sendable, Equatable {
        public let atMs: Int64
        public let level: Int
        public init(atMs: Int64, level: Int) {
            self.atMs = atMs
            self.level = level
        }
    }

    /// True for a level that means a battery reading rather than external power or none.
    public static func isBatteryLevel(_ level: Int) -> Bool { (0...100).contains(level) }

    /// Hours left at the rate the level has actually been falling: a least-squares line through
    /// the battery readings of the last `windowMs` since the node last ran on external power.
    /// Nil until those readings span `minSpanMs` and fell by `minDrop` points, so nothing is
    /// shown from a guess about the cell's capacity.
    public static func hoursLeft(_ readings: [Reading], nowMs: Int64) -> Double? {
        let recent = readings.filter { $0.atMs >= nowMs - windowMs }.sorted { $0.atMs < $1.atMs }
        let lastExternal = recent.lastIndex { $0.level > 100 }
        let sinceUnplugged = recent.dropFirst(lastExternal.map { $0 + 1 } ?? 0)
        let onBattery = sinceUnplugged.filter { isBatteryLevel($0.level) }
        guard onBattery.count >= 3, let first = onBattery.first, let last = onBattery.last else { return nil }
        if last.atMs - first.atMs < minSpanMs { return nil }
        if (onBattery.map(\.level).max() ?? 0) - last.level < minDrop { return nil }

        let t0 = first.atMs
        let xs = onBattery.map { Double($0.atMs - t0) / 3_600_000.0 }
        let ys = onBattery.map { Double($0.level) }
        let mx = xs.reduce(0, +) / Double(xs.count)
        let my = ys.reduce(0, +) / Double(ys.count)
        let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        if sxx == 0 { return nil }
        var sxy = 0.0
        for i in xs.indices { sxy += (xs[i] - mx) * (ys[i] - my) }
        let slopePerHour = sxy / sxx
        if slopePerHour >= 0 { return nil }
        return Double(last.level) / -slopePerHour
    }

    /// "about 40 min left", "about 14 h left", "about 3 days left".
    public static func timeLeftText(_ hours: Double) -> String {
        if hours < 1 {
            let minutes = max(5, Int((hours * 60 / 5).rounded()) * 5)
            return "about \(minutes) min left"
        }
        if hours < 48 { return "about \(Int(hours.rounded())) h left" }
        return "about \(Int((hours / 24).rounded())) days left"
    }

    /// The node's battery in a few words: "82%, 3.98 V, about 14 h left", or "On USB power";
    /// nil when it has reported none.
    public static func describe(level: Int, voltage: Float, hoursLeft: Double?, withVoltage: Bool = true) -> String? {
        if level > 100 { return "On USB power" }
        guard isBatteryLevel(level) else { return nil }
        var out = "\(level)%"
        if withVoltage && voltage > 0 { out += ", " + String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), voltage) + " V" }
        if let hoursLeft { out += ", " + timeLeftText(hoursLeft) }
        return out
    }

    /// A table cell: "82%", "USB", or "-" for a node that reports nothing.
    public static func cell(_ level: Int) -> String {
        if level > 100 { return "USB" }
        if isBatteryLevel(level) { return "\(level)%" }
        return "-"
    }
}
