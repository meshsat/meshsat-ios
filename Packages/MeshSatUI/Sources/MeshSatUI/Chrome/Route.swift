// Mirrors the route strings and the tab mapping of ui/MeshSatUI.kt (NavHost with start
// destination "home"; tabOf(route) keeps Home lit for passes, Messages for chats, People for
// topology, and Setup for everything else).
import Foundation

public enum Tab: String, CaseIterable, Sendable, Hashable {
    case home, messages, map, people, setup

    public var title: String {
        switch self {
        case .home: "Home"
        case .messages: "Messages"
        case .map: "Map"
        case .people: "People"
        case .setup: "Setup"
        }
    }
}

public enum SetupSection: String, CaseIterable, Sendable, Hashable {
    case node, satellite, hub, sms, safety, messaging, maps, integrations, diagnostics

    public var title: String {
        switch self {
        case .node: "Your MeshSat node"
        case .satellite: "Satellite"
        case .hub: "Hub"
        case .sms: "SMS"
        case .safety: "Safety"
        case .messaging: "Messaging"
        case .maps: "Maps"
        case .integrations: "Ham radio, TAK and Reticulum"
        case .diagnostics: "Diagnostics"
        }
    }
}

public enum Route: Hashable, Sendable {
    case home, messages, map, people, setup
    case chat(peer: String)
    case setupSection(SetupSection)
    case setupAdvanced
    case passes, radioConfig, rules, interfaces, deliveries, topology, geofence
    case audit, credentials, decrypt, about, sos

    /// The Android route string, so logs and notification extras read the same.
    public var string: String {
        switch self {
        case .home: "home"
        case .messages: "messages"
        case .map: "map"
        case .people: "people"
        case .setup: "setup"
        case .chat(let peer): "chat/\(peer.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? peer)"
        case .setupSection(let s): "setup/\(s.rawValue)"
        case .setupAdvanced: "setup/advanced"
        case .passes: "passes"
        case .radioConfig: "radio-config"
        case .rules: "rules"
        case .interfaces: "interfaces"
        case .deliveries: "deliveries"
        case .topology: "topology"
        case .geofence: "geofence"
        case .audit: "audit"
        case .credentials: "credentials"
        case .decrypt: "decrypt"
        case .about: "about"
        case .sos: "sos"
        }
    }

    public init?(string: String) {
        switch string {
        case "home": self = .home
        case "messages": self = .messages
        case "map": self = .map
        case "people": self = .people
        case "setup": self = .setup
        case "setup/advanced": self = .setupAdvanced
        case "passes": self = .passes
        case "radio-config": self = .radioConfig
        case "rules": self = .rules
        case "interfaces": self = .interfaces
        case "deliveries": self = .deliveries
        case "topology": self = .topology
        case "geofence": self = .geofence
        case "audit": self = .audit
        case "credentials": self = .credentials
        case "decrypt": self = .decrypt
        case "about": self = .about
        case "sos": self = .sos
        default:
            if string.hasPrefix("chat/") {
                let raw = String(string.dropFirst(5))
                self = .chat(peer: raw.removingPercentEncoding ?? raw)
            } else if string.hasPrefix("setup/"), let s = SetupSection(rawValue: String(string.dropFirst(6))) {
                self = .setupSection(s)
            } else {
                return nil
            }
        }
    }

    /// tabOf(route) in MeshSatUI.kt.
    public var tab: Tab {
        switch self {
        case .home, .passes: .home
        case .messages, .chat: .messages
        case .map: .map
        case .people, .topology: .people
        default: .setup
        }
    }

    /// The SubScreen title, nil for the tab roots and the chat (which draws its own header).
    public var subScreenTitle: String? {
        switch self {
        case .setupSection(let s): s.title
        case .setupAdvanced: "Advanced"
        case .passes: "Satellite passes"
        case .radioConfig: "Mesh radio settings"
        case .rules: "Routing rules"
        case .interfaces: "Links"
        case .deliveries: "Message queue"
        case .topology: "Mesh topology"
        case .geofence: "Zones"
        case .audit: "Audit log"
        case .credentials: "Certificates and keys"
        case .decrypt: "Encrypt or decrypt text"
        case .about: "About"
        case .sos: "SOS"
        default: nil
        }
    }
}
