// Mirrors ble/NodeStatsText.kt: the node health card's wording (Setup > Satellite,
// MESHSAT-1378), free of platform types so it has a test and matches Android row for row.
// Each entry is a label and its value.

public enum NodeStatsText {
    public typealias Stats = IridiumPipeContract.Stats

    /// The card's rows, in order.
    public static func rows(_ s: Stats) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        // `.none` on an Optional would read as nil: the owner's own case is spelt out.
        let held: String =
            switch s.owner {
            case .phone?: "Held by this phone"
            case .node?: "Used by the node"
            case IridiumPipeContract.Owner.none?: "Free"
            case nil: "Unknown owner"
            }
        rows.append(("Modem", held + (s.flags.contains(.modemAnswers) ? ", answers" : ", not answering")))
        if s.flags.contains(.sessionInFlight) { rows.append(("Session", "In flight now")) }
        let signal: String =
            if let csq = s.csq {
                "\(csq) of 5" + (s.csqAgeS.map { ", " + ago($0) } ?? "")
            } else {
                "Never read"
            }
        rows.append(("Signal", signal))
        rows.append(("Sessions since boot", String(s.sessions)))
        let last: String =
            if s.lastMoStatus < 0 {
                "None yet"
            } else {
                "MO \(s.lastMoStatus), \(IridiumATDriver.moStatusText(s.lastMoStatus)), MOMSN \(s.lastMomsn)"
                    + (s.lastSessionAgeS.map { ", " + ago($0) } ?? "")
            }
        rows.append(("Last session", last))
        if s.lastMtQueued > 0 {
            rows.append(("Gateway", "\(s.lastMtQueued) waiting at the gateway"))
        } else if s.flags.contains(.messageWaiting) {
            rows.append(("Gateway", "A message is waiting at the gateway"))
        }
        if s.daySessionsCap > 0 || s.nodeSessions > 0 {
            rows.append(
                (
                    "Node's own routing",
                    "\(s.daySessionsUsed) of \(s.daySessionsCap) sessions today, sent \(s.nodeSent), received \(s.nodeReceived)"
                ))
        }
        rows.append(("Node uptime", duration(s.uptimeS)))
        if s.watchdogReboots > 0 { rows.append(("Bluetooth watchdog reboots", String(s.watchdogReboots))) }
        if s.phoneBytesDropped > 0 { rows.append(("Bytes the node could not take", String(s.phoneBytesDropped))) }
        return rows
    }

    /// A line under the rows when something needs attention, or nil.
    public static func warning(_ s: Stats) -> String? {
        if s.flags.contains(.inboundCongested) {
            return "The node's incoming buffer is nearly full: the phone writes faster than the modem takes."
        }
        if !s.flags.contains(.modemAnswers) { return "The node's modem is not answering AT commands." }
        return nil
    }

    /// "just now", "12 s ago", "4 min ago", "2 h ago", "3 d ago".
    public static func ago(_ seconds: UInt32) -> String {
        switch seconds {
        case ..<5: "just now"
        case ..<60: "\(seconds) s ago"
        case ..<3600: "\(seconds / 60) min ago"
        case ..<86_400: "\(seconds / 3600) h ago"
        default: "\(seconds / 86_400) d ago"
        }
    }

    /// "30 s", "45 min", "2 h 14 min", "3 d 2 h".
    public static func duration(_ seconds: UInt32) -> String {
        switch seconds {
        case ..<60: "\(seconds) s"
        case ..<3600: "\(seconds / 60) min"
        case ..<86_400: "\(seconds / 3600) h \((seconds % 3600) / 60) min"
        default: "\(seconds / 86_400) d \((seconds % 86_400) / 3600) h"
        }
    }
}
