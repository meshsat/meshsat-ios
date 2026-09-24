// Mirrors ble/NodeProfile.kt: a whole node configuration, applied in one go (MESHSAT-1285).
//
// The settings screens cover what a person changes in the field: a name, a region, a channel.
// Making two nodes the same for a stand, or stating what a node is really set to, needs the rest
// as well (its role, how often it announces itself, whether it listens to MQTT, its power
// settings) and needs it without a second tool on a second machine.
//
// Every field is optional and a field left out is left alone on the node. Nothing here guesses:
// a role or region the app does not know is refused, because the alternative is a radio quietly
// set to something nobody asked for.
import Crypto
import Foundation
import MeshSatProto
import SwiftProtobuf

public struct NodeProfile: Sendable, Equatable {
    public var longName: String?
    public var shortName: String?
    public var role: String?
    public var nodeInfoBroadcastSecs: Int?
    public var region: String?
    public var preset: String?
    public var txPower: Int?
    public var txEnabled: Bool?
    public var hopLimit: Int?
    public var rxBoostedGain: Bool?
    public var ignoreMqtt: Bool?
    public var channelName: String?
    public var channelPsk: [UInt8]?
    public var channelUplink: Bool?
    public var channelDownlink: Bool?
    /// 0 stops the node sharing a position on the channel at all; 32 is full precision.
    public var channelPositionPrecision: Int?
    public var gpsMode: String?
    public var positionBroadcastSecs: Int?
    public var positionSmart: Bool?
    public var powerSaving: Bool?
    /// Seconds before super deep sleep; `NodeProfiles.sdsNever` is the firmware's "never".
    public var sdsSecs: Int64?
    public var bluetoothEnabled: Bool?
    public var bluetoothFixedPin: Int?
    public var ntpServer: String?

    public init(
        longName: String? = nil, shortName: String? = nil, role: String? = nil, nodeInfoBroadcastSecs: Int? = nil,
        region: String? = nil, preset: String? = nil, txPower: Int? = nil, txEnabled: Bool? = nil, hopLimit: Int? = nil,
        rxBoostedGain: Bool? = nil, ignoreMqtt: Bool? = nil, channelName: String? = nil, channelPsk: [UInt8]? = nil,
        channelUplink: Bool? = nil, channelDownlink: Bool? = nil, channelPositionPrecision: Int? = nil,
        gpsMode: String? = nil, positionBroadcastSecs: Int? = nil, positionSmart: Bool? = nil, powerSaving: Bool? = nil,
        sdsSecs: Int64? = nil, bluetoothEnabled: Bool? = nil, bluetoothFixedPin: Int? = nil, ntpServer: String? = nil
    ) {
        self.longName = longName
        self.shortName = shortName
        self.role = role
        self.nodeInfoBroadcastSecs = nodeInfoBroadcastSecs
        self.region = region
        self.preset = preset
        self.txPower = txPower
        self.txEnabled = txEnabled
        self.hopLimit = hopLimit
        self.rxBoostedGain = rxBoostedGain
        self.ignoreMqtt = ignoreMqtt
        self.channelName = channelName
        self.channelPsk = channelPsk
        self.channelUplink = channelUplink
        self.channelDownlink = channelDownlink
        self.channelPositionPrecision = channelPositionPrecision
        self.gpsMode = gpsMode
        self.positionBroadcastSecs = positionBroadcastSecs
        self.positionSmart = positionSmart
        self.powerSaving = powerSaving
        self.sdsSecs = sdsSecs
        self.bluetoothEnabled = bluetoothEnabled
        self.bluetoothFixedPin = bluetoothFixedPin
        self.ntpServer = ntpServer
    }
}

/// What the node says it is set to now. A profile is written over these, never over blanks.
public struct NodeSections: Sendable, Equatable {
    public var device: Meshtastic_Config.DeviceConfig?
    public var lora: Meshtastic_Config.LoRaConfig?
    public var position: Meshtastic_Config.PositionConfig?
    public var power: Meshtastic_Config.PowerConfig?
    public var bluetooth: Meshtastic_Config.BluetoothConfig?
    public var network: Meshtastic_Config.NetworkConfig?
    public var primaryChannel: Meshtastic_Channel?

    public init(
        device: Meshtastic_Config.DeviceConfig? = nil, lora: Meshtastic_Config.LoRaConfig? = nil,
        position: Meshtastic_Config.PositionConfig? = nil, power: Meshtastic_Config.PowerConfig? = nil,
        bluetooth: Meshtastic_Config.BluetoothConfig? = nil, network: Meshtastic_Config.NetworkConfig? = nil,
        primaryChannel: Meshtastic_Channel? = nil
    ) {
        self.device = device
        self.lora = lora
        self.position = position
        self.power = power
        self.bluetooth = bluetooth
        self.network = network
        self.primaryChannel = primaryChannel
    }
}

public enum NodeProfiles {
    public static let sdsNever: Int64 = 0xFFFF_FFFF

    public enum Plan: Sendable, Equatable {
        /// `messages` go to the node in order; `sections` names what they touch, for the log.
        case ready(messages: [Meshtastic_AdminMessage], sections: [String])
        case refused(reason: String)

        public var isRefused: Bool {
            if case .refused = self { return true }
            return false
        }
    }

    private struct Refusal: Error {
        let reason: String
    }

    /// The admin messages that turn `now` into `profile`, wrapped in one begin/commit edit so
    /// the node saves once and restarts once. A section the profile does not mention is not
    /// sent. A section the node has not reported yet cannot be written: sending a fresh one
    /// would reset every field in it that the profile leaves out.
    public static func plan(now: NodeSections, profile: NodeProfile) -> Plan {
        do {
            let (messages, touched) = try build(now: now, profile: profile)
            if messages.isEmpty { return .refused(reason: "The profile changes nothing.") }
            var begin = Meshtastic_AdminMessage()
            begin.beginEditSettings = true
            var commit = Meshtastic_AdminMessage()
            commit.commitEditSettings = true
            return .ready(messages: [begin] + messages + [commit], sections: touched)
        } catch let r as Refusal {
            return .refused(reason: r.reason)
        } catch {
            return .refused(reason: "\(error)")
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func build(now: NodeSections, profile: NodeProfile) throws -> ([Meshtastic_AdminMessage], [String]) {
        var out: [Meshtastic_AdminMessage] = []
        var touched: [String] = []
        func config(_ name: String, _ build: (inout Meshtastic_Config) -> Void) {
            var c = Meshtastic_Config()
            build(&c)
            var admin = Meshtastic_AdminMessage()
            admin.setConfig = c
            out.append(admin)
            touched.append(name)
        }
        func missing(_ name: String) -> Refusal {
            Refusal(reason: "The node has not reported its \(name) settings yet. Read the node first.")
        }

        if profile.longName != nil || profile.shortName != nil {
            guard let long = profile.longName, let short = profile.shortName else {
                throw Refusal(reason: "A name needs both the long and the short name.")
            }
            if short.count > 4 { throw Refusal(reason: "The short name is at most 4 characters.") }
            var user = Meshtastic_User()
            user.longName = long
            user.shortName = short
            var admin = Meshtastic_AdminMessage()
            admin.setOwner = user
            out.append(admin)
            touched.append("name")
        }

        if profile.role != nil || profile.nodeInfoBroadcastSecs != nil {
            guard var b = now.device else { throw missing("device") }
            if let name = profile.role {
                guard let role = deviceRole(named: name) else { throw Refusal(reason: "Unknown role: \(name)") }
                b.role = role
            }
            if let secs = profile.nodeInfoBroadcastSecs { b.nodeInfoBroadcastSecs = UInt32(secs) }
            config("device") { $0.device = b }
        }

        let loraAsked =
            profile.region != nil || profile.preset != nil || profile.txPower != nil || profile.txEnabled != nil
            || profile.hopLimit != nil || profile.rxBoostedGain != nil || profile.ignoreMqtt != nil
        if loraAsked {
            guard var b = now.lora else { throw missing("radio") }
            if let name = profile.region {
                guard let region = regionCode(named: name) else { throw Refusal(reason: "Unknown region: \(name)") }
                b.region = region
            }
            if let name = profile.preset {
                guard let preset = modemPreset(named: name) else { throw Refusal(reason: "Unknown preset: \(name)") }
                b.usePreset = true
                b.modemPreset = preset
            }
            if let p = profile.txPower { b.txPower = Int32(p) }
            if let e = profile.txEnabled { b.txEnabled = e }
            if let h = profile.hopLimit {
                if !(1...7).contains(h) { throw Refusal(reason: "Hops are 1 to 7.") }
                b.hopLimit = UInt32(h)
            }
            if let g = profile.rxBoostedGain { b.sx126XRxBoostedGain = g }
            if let m = profile.ignoreMqtt { b.ignoreMqtt = m }
            config("radio") { $0.lora = b }
        }

        if profile.gpsMode != nil || profile.positionBroadcastSecs != nil || profile.positionSmart != nil {
            guard var b = now.position else { throw missing("position") }
            if let name = profile.gpsMode {
                guard let mode = gpsMode(named: name) else { throw Refusal(reason: "Unknown GPS mode: \(name)") }
                b.gpsMode = mode
            }
            if let secs = profile.positionBroadcastSecs { b.positionBroadcastSecs = UInt32(secs) }
            if let smart = profile.positionSmart { b.positionBroadcastSmartEnabled = smart }
            config("position") { $0.position = b }
        }

        if profile.powerSaving != nil || profile.sdsSecs != nil {
            guard var b = now.power else { throw missing("power") }
            if let saving = profile.powerSaving { b.isPowerSaving = saving }
            if let sds = profile.sdsSecs { b.sdsSecs = UInt32(truncatingIfNeeded: sds) }
            config("power") { $0.power = b }
        }

        if profile.bluetoothEnabled != nil || profile.bluetoothFixedPin != nil {
            guard var b = now.bluetooth else { throw missing("Bluetooth") }
            if let enabled = profile.bluetoothEnabled { b.enabled = enabled }
            if let pin = profile.bluetoothFixedPin {
                if !(100_000...999_999).contains(pin) { throw Refusal(reason: "A fixed PIN is six digits.") }
                b.mode = .fixedPin
                b.fixedPin = UInt32(pin)
            }
            config("Bluetooth") { $0.bluetooth = b }
        }

        if let ntp = profile.ntpServer {
            guard var b = now.network else { throw missing("network") }
            b.ntpServer = ntp
            config("network") { $0.network = b }
        }

        let channelAsked =
            profile.channelName != nil || profile.channelPsk != nil || profile.channelUplink != nil
            || profile.channelDownlink != nil || profile.channelPositionPrecision != nil
        if channelAsked {
            guard let channel = now.primaryChannel else { throw missing("channel") }
            var s = channel.settings
            if let name = profile.channelName {
                if name.utf8.count > 11 { throw Refusal(reason: "A channel name is at most 11 bytes.") }
                s.name = name
            }
            if let psk = profile.channelPsk {
                if ![0, 1, 16, 32].contains(psk.count) { throw Refusal(reason: "A channel key is 16 or 32 bytes.") }
                s.psk = Data(psk)
            }
            if let up = profile.channelUplink { s.uplinkEnabled = up }
            if let down = profile.channelDownlink { s.downlinkEnabled = down }
            if let precision = profile.channelPositionPrecision {
                if !(0...32).contains(precision) { throw Refusal(reason: "Position precision is 0 to 32.") }
                s.moduleSettings.positionPrecision = UInt32(precision)
            }
            var ch = channel
            ch.index = 0
            ch.role = .primary
            ch.settings = s
            var admin = Meshtastic_AdminMessage()
            admin.setChannel = ch
            out.append(admin)
            touched.append("channel")
        }

        return (out, touched)
    }

    /// A key as it may be shown: the first eight bytes of its SHA-256, enough to tell two keys
    /// apart and to check one against a note, useless for reading the channel.
    public static func keyFingerprint(_ psk: [UInt8]) -> String {
        if psk.isEmpty { return "none" }
        if psk.count == 1 { return "default (not private)" }
        let hex = SHA256.hash(data: Data(psk)).prefix(8).map { String(format: "%02x", $0) }.joined()
        var groups: [String] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 4, limitedBy: hex.endIndex) ?? hex.endIndex
            groups.append(String(hex[i..<j]))
            i = j
        }
        return groups.joined(separator: " ") + " (\(psk.count * 8)-bit)"
    }

    // MARK: Enum values by their proto names, as the Kotlin `values().firstOrNull { it.name == name }`

    static func deviceRole(named name: String) -> Meshtastic_Config.DeviceConfig.Role? {
        MeshtasticProtoAdapter.enumValue(named: name, field: "role", in: Meshtastic_Config.DeviceConfig()) { $0.role }
    }

    static func regionCode(named name: String) -> Meshtastic_Config.LoRaConfig.RegionCode? {
        MeshtasticProtoAdapter.enumValue(named: name, field: "region", in: Meshtastic_Config.LoRaConfig()) { $0.region }
    }

    static func modemPreset(named name: String) -> Meshtastic_Config.LoRaConfig.ModemPreset? {
        MeshtasticProtoAdapter.enumValue(named: name, field: "modem_preset", in: Meshtastic_Config.LoRaConfig()) { $0.modemPreset }
    }

    static func gpsMode(named name: String) -> Meshtastic_Config.PositionConfig.GpsMode? {
        MeshtasticProtoAdapter.enumValue(named: name, field: "gps_mode", in: Meshtastic_Config.PositionConfig()) { $0.gpsMode }
    }
}
