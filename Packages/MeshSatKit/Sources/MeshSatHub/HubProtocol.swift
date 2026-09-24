// Mirrors hub/HubProtocol.kt: the meshsat-uplink/v1 types (Sparkplug B inspired, CoT native),
// the Bridge's internal/hubreporter/protocol.go on the phone. Bodies are JSON objects built
// in the order Android writes them; the Hub reads fields by name.
import Foundation

public enum HubProtocol {
    public static let version = "meshsat-uplink/v1"

    // CoT types (MIL-STD-2525)
    public static let cotBridge = "a-f-G-U-C-I"
    public static let cotMeshNode = "a-f-G-U-C"
    public static let cotSatModem = "a-f-G-E-S"
    public static let cotCellModem = "a-f-G-E-C"
    public static let cotMobile = "a-f-G-U-C"
    public static let cotEmergency = "b-a"

    // Device types
    public static let deviceMeshtastic = "meshtastic_node"
    public static let deviceIridiumSbd = "iridium_sbd"
    public static let deviceIridiumImt = "iridium_imt"
    public static let deviceCellular = "cellular"
    public static let deviceAprs = "aprs"

    /// "2026-09-24T14:03:00Z"
    public static func isoTimestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    public static func cotType(forDevice deviceType: String) -> String {
        switch deviceType {
        case deviceMeshtastic: cotMeshNode
        case deviceIridiumSbd, deviceIridiumImt: cotSatModem
        case deviceCellular: cotCellModem
        default: cotMeshNode
        }
    }
}

/// The Hub's topics under the tenant's namespace (MESHSAT-1324): the provisioning bundle's
/// `mqtt_topic_prefix`, "meshsat" for the platform tenant and "meshsat/{tenant}" for a
/// customer, used exactly as given (hubmqtt Namespace()). The broker confines a bridge to
/// `{prefix}/bridge/{bid}/#` and `{prefix}/+/...` device topics, so a wrong prefix is refused
/// on every publish. Every id in a segment is percent-encoded: NATS drops the connection on a
/// raw "+" in a publish (an SMS sender's number).
public struct HubTopics: Sendable, Equatable {
    public static let platformPrefix = "meshsat"
    public let prefix: String

    public init(prefix: String = HubTopics.platformPrefix) {
        let p = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        self.prefix = p.isEmpty ? Self.platformPrefix : p
    }

    private func bridge(_ bridgeId: String) -> String { "\(prefix)/bridge/\(Self.segment(bridgeId))" }
    private func device(_ deviceId: String) -> String { "\(prefix)/\(Self.segment(deviceId))" }

    public func bridgeBirth(_ bridgeId: String) -> String { bridge(bridgeId) + "/birth" }
    public func bridgeDeath(_ bridgeId: String) -> String { bridge(bridgeId) + "/death" }
    public func bridgeHealth(_ bridgeId: String) -> String { bridge(bridgeId) + "/health" }
    public func bridgeCmd(_ bridgeId: String) -> String { bridge(bridgeId) + "/cmd" }
    public func bridgeCmdResponse(_ bridgeId: String) -> String { bridge(bridgeId) + "/cmd/response" }
    /// The Hub's receipt for an MO from one of this bridge's modems (MESHSAT-1246).
    public func bridgeMOAck(_ bridgeId: String) -> String { bridge(bridgeId) + "/mo/ack" }
    public func deviceBirth(_ bridgeId: String, _ deviceId: String) -> String {
        bridge(bridgeId) + "/device/\(Self.segment(deviceId))/birth"
    }
    public func deviceDeath(_ bridgeId: String, _ deviceId: String) -> String {
        bridge(bridgeId) + "/device/\(Self.segment(deviceId))/death"
    }
    public func devicePosition(_ deviceId: String) -> String { device(deviceId) + "/position" }
    public func deviceTelemetry(_ deviceId: String) -> String { device(deviceId) + "/telemetry" }
    public func deviceSOS(_ deviceId: String) -> String { device(deviceId) + "/sos" }
    public func deviceMODecoded(_ deviceId: String) -> String { device(deviceId) + "/mo/decoded" }

    /// The operator's TAK picture: never under the prefix, and granted only to bridges of the
    /// platform tenant (a customer gets TAK from its own hosted TAK server).
    public static let takBroadcast = "meshsat/broadcast/tak/cot/in"
    public var mayReceiveTakBroadcast: Bool { prefix == Self.platformPrefix }

    /// A topic segment as the Hub writes it: + # / % percent-encoded (hubmqtt.EncodeSegment).
    public static func segment(_ id: String) -> String {
        id.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: "#", with: "%23").replacingOccurrences(of: "/", with: "%2F")
    }
}

/// A JSON object in insertion order, as Android's JSONObject writes it.
public struct JSONBody: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case string(String), int(Int64), double(Double), bool(Bool), null
        case object(JSONBody), array([Value])
    }

    public private(set) var entries: [(String, Value)] = []

    public init() {}

    public static func == (lhs: JSONBody, rhs: JSONBody) -> Bool {
        lhs.entries.count == rhs.entries.count && zip(lhs.entries, rhs.entries).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    public mutating func put(_ key: String, _ value: Value) {
        entries.removeAll { $0.0 == key }
        entries.append((key, value))
    }

    public mutating func put(_ key: String, _ s: String) { put(key, .string(s)) }
    public mutating func put(_ key: String, _ i: Int) { put(key, .int(Int64(i))) }
    public mutating func put(_ key: String, _ i: Int64) { put(key, .int(i)) }
    public mutating func put(_ key: String, _ d: Double) { put(key, .double(d)) }
    public mutating func put(_ key: String, _ b: Bool) { put(key, .bool(b)) }
    public mutating func put(_ key: String, _ o: JSONBody) { put(key, .object(o)) }
    public mutating func put(_ key: String, _ a: [String]) { put(key, .array(a.map { .string($0) })) }
    public mutating func put(_ key: String, objects: [JSONBody]) { put(key, .array(objects.map { .object($0) })) }
    public mutating func remove(_ key: String) { entries.removeAll { $0.0 == key } }

    public subscript(key: String) -> Value? { entries.first { $0.0 == key }?.1 }

    public func string(_ key: String) -> String? {
        if case .string(let s)? = self[key] { return s }
        return nil
    }

    /// The JSON text, keys in insertion order (Android) or sorted (canonical, for signing).
    public func text(sortedKeys: Bool = false) -> String {
        var out = ""
        Self.write(self, sorted: sortedKeys, into: &out)
        return out
    }

    static func write(_ body: JSONBody, sorted: Bool, into out: inout String) {
        out += "{"
        let items = sorted ? body.entries.sorted { $0.0 < $1.0 } : body.entries
        for (i, (k, v)) in items.enumerated() {
            if i > 0 { out += "," }
            out += "\"" + escape(k) + "\":"
            write(v, sorted: sorted, into: &out)
        }
        out += "}"
    }

    static func write(_ value: Value, sorted: Bool, into out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += Self.number(d)
        case .string(let s): out += "\"" + escape(s) + "\""
        case .object(let o): write(o, sorted: sorted, into: &out)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                write(v, sorted: sorted, into: &out)
            }
            out += "]"
        }
    }

    /// A double as Go's json.Marshal and Android's canonical writer spell it: an integral value
    /// without a fraction, otherwise the shortest round-trip form.
    ///
    /// Go writes the shortest digits in plain decimal for 1e-6 <= |d| < 1e21 and in exponent form
    /// outside it, with no leading zero in the exponent ("1e-7", "1e+21"); Swift's own text for
    /// the same doubles is "1e-07" and "1e-06". The Hub re-marshals a birth with Go to check its
    /// signature, so the digits come from Swift (shortest round-trip, as Go) and the layout is Go's.
    public static func number(_ d: Double) -> String {
        if d.isFinite, d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        guard d.isFinite else { return "null" }
        let a = abs(d)
        var text = "\(a)"
        var exp = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exp = Int(text[text.index(after: e)...]) ?? 0
            text = String(text[..<e])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        var digits = String(parts[0]) + (parts.count > 1 ? String(parts[1]) : "")
        var point = parts[0].count + exp
        while digits.count > 1, digits.first == "0" {
            digits.removeFirst()
            point -= 1
        }
        while digits.count > 1, digits.last == "0" { digits.removeLast() }
        let out: String
        if a < 1e-6 || a >= 1e21 {
            let e = point - 1
            let head: String = String(digits.prefix(1))
            let tail: String = digits.count > 1 ? "." + String(digits.dropFirst()) : ""
            let sign: String = e < 0 ? "-" : "+"
            out = head + tail + "e" + sign + String(abs(e))
        } else if point <= 0 {
            out = "0." + String(repeating: "0", count: -point) + digits
        } else if point >= digits.count {
            out = digits + String(repeating: "0", count: point - digits.count)
        } else {
            out = String(digits.prefix(point)) + "." + String(digits.dropFirst(point))
        }
        return (d < 0 ? "-" : "") + out
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            // Go's encoding/json escapes these for HTML safety, and the Hub re-marshals the birth
            // with it to check the signature, so the canonical text must too.
            case "<": out += "\\u003c"
            case ">": out += "\\u003e"
            case "&": out += "\\u0026"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if c.value < 0x20 { out += String(format: "\\u%04x", c.value) } else { out.unicodeScalars.append(c) }
            }
        }
        return out
    }

    /// Parse JSON text into a body (objects keep their key order as read).
    public static func parse(_ data: Data) -> JSONBody? {
        guard let obj = try? JSONSerialization.jsonObject(with: data), let dict = obj as? [String: Any] else { return nil }
        return fromDictionary(dict)
    }

    static func fromDictionary(_ dict: [String: Any]) -> JSONBody {
        var body = JSONBody()
        for key in dict.keys.sorted() { body.put(key, fromAny(dict[key] as Any)) }
        return body
    }

    static func fromAny(_ any: Any) -> Value {
        let typeName = "\(type(of: any))"
        if typeName == "Bool" || typeName.hasSuffix("Boolean"), let b = any as? Bool { return .bool(b) }
        // Linux Foundation hands a JSON true/false over as an NSNumber of objCType "c".
        if let n = any as? NSNumber, String(cString: n.objCType) == "c" { return .bool(n.boolValue) }
        if let s = any as? String { return .string(s) }
        if let i = any as? Int64 { return .int(i) }
        if let i = any as? Int { return .int(Int64(i)) }
        if let d = any as? Double {
            if d == d.rounded(), abs(d) < 1e15 { return .int(Int64(d)) }
            return .double(d)
        }
        if let n = any as? NSNumber {
            let d = n.doubleValue
            if d == d.rounded(), abs(d) < 1e15 { return .int(n.int64Value) }
            return .double(d)
        }
        if let dict = any as? [String: Any] { return .object(fromDictionary(dict)) }
        if let arr = any as? [Any] { return .array(arr.map(fromAny)) }
        return .null
    }

    public func int(_ key: String) -> Int64? {
        switch self[key] {
        case .int(let i)?: return i
        case .double(let d)?: return Int64(d)
        case .string(let s)?: return Int64(s)
        default: return nil
        }
    }

    public func bool(_ key: String) -> Bool? {
        if case .bool(let b)? = self[key] { return b }
        return nil
    }
}

// MARK: Shared types

public struct HubLocation: Sendable, Equatable {
    public var lat: Double
    public var lon: Double
    public var alt: Double
    public var source: String
    public init(lat: Double, lon: Double, alt: Double = 0, source: String = "gps") {
        self.lat = lat
        self.lon = lon
        self.alt = alt
        self.source = source
    }
    public func toJson() -> JSONBody {
        var j = JSONBody()
        j.put("lat", lat)
        j.put("lon", lon)
        j.put("alt", alt)
        j.put("source", source)
        return j
    }
}

public struct InterfaceInfo: Sendable, Equatable {
    public var name: String
    public var type: String
    public var status: String
    public var port: String
    public var imei: String
    public init(name: String, type: String, status: String, port: String = "", imei: String = "") {
        self.name = name
        self.type = type
        self.status = status
        self.port = port
        self.imei = imei
    }
    public func toJson() -> JSONBody {
        var j = JSONBody()
        j.put("name", name)
        j.put("type", type)
        j.put("status", status)
        if !port.isEmpty { j.put("port", port) }
        if !imei.isEmpty { j.put("imei", imei) }
        return j
    }
}

public struct InterfaceHealth: Sendable, Equatable {
    public var name: String
    public var status: String
    public var healthScore: Int
    public var signalBars: Int
    public var signalDBm: Int
    public var nodesSeen: Int
    public init(name: String, status: String, healthScore: Int = 0, signalBars: Int = 0, signalDBm: Int = 0, nodesSeen: Int = 0) {
        self.name = name
        self.status = status
        self.healthScore = healthScore
        self.signalBars = signalBars
        self.signalDBm = signalDBm
        self.nodesSeen = nodesSeen
    }
    public func toJson() -> JSONBody {
        var j = JSONBody()
        j.put("name", name)
        j.put("status", status)
        if healthScore > 0 { j.put("health_score", healthScore) }
        if signalBars > 0 { j.put("signal_bars", signalBars) }
        if signalDBm != 0 { j.put("signal_dbm", signalDBm) }
        if nodesSeen > 0 { j.put("nodes_seen", nodesSeen) }
        return j
    }
}

// MARK: Bridge lifecycle

public struct BridgeBirth: Sendable, Equatable {
    public var bridgeId: String
    public var version: String
    public var hostname: String
    public var mode: String
    public var tenantId: String
    public var location: HubLocation?
    public var interfaces: [InterfaceInfo]
    public var capabilities: [String]
    public var cotCallsign: String
    public var uptimeSec: Int64
    public init(
        bridgeId: String, version: String, hostname: String, mode: String = "ios", tenantId: String = "default",
        location: HubLocation? = nil,
        interfaces: [InterfaceInfo] = [], capabilities: [String] = [], cotCallsign: String = "", uptimeSec: Int64 = 0
    ) {
        self.bridgeId = bridgeId
        self.version = version
        self.hostname = hostname
        self.mode = mode
        self.tenantId = tenantId
        self.location = location
        self.interfaces = interfaces
        self.capabilities = capabilities
        self.cotCallsign = cotCallsign
        self.uptimeSec = uptimeSec
    }
    public func toJson(now: Date = Date()) -> JSONBody {
        var j = JSONBody()
        j.put("protocol", HubProtocol.version)
        j.put("bridge_id", bridgeId)
        j.put("version", version)
        j.put("hostname", hostname)
        j.put("mode", mode)
        j.put("tenant_id", tenantId)
        if let location { j.put("location", location.toJson()) }
        j.put("interfaces", objects: interfaces.map { $0.toJson() })
        j.put("capabilities", capabilities)
        j.put("cot_type", HubProtocol.cotMobile)
        j.put("cot_callsign", cotCallsign.isEmpty ? hostname : cotCallsign)
        j.put("uptime_sec", uptimeSec)
        j.put("timestamp", HubProtocol.isoTimestamp(now))
        return j
    }
}

public struct BridgeDeath: Sendable, Equatable {
    public var bridgeId: String
    public var reason: String
    public init(bridgeId: String, reason: String = "shutdown") {
        self.bridgeId = bridgeId
        self.reason = reason
    }
    public func toJson(now: Date = Date()) -> JSONBody {
        var j = JSONBody()
        j.put("protocol", HubProtocol.version)
        j.put("bridge_id", bridgeId)
        j.put("reason", reason)
        j.put("timestamp", HubProtocol.isoTimestamp(now))
        return j
    }
}

public struct BridgeHealth: Sendable, Equatable {
    public var bridgeId: String
    public var uptimeSec: Int64
    public var batteryPct: Double
    public var memPct: Double
    public var diskPct: Double
    public var interfaces: [InterfaceHealth]
    public init(
        bridgeId: String, uptimeSec: Int64, batteryPct: Double = 0, memPct: Double = 0, diskPct: Double = 0,
        interfaces: [InterfaceHealth] = []
    ) {
        self.bridgeId = bridgeId
        self.uptimeSec = uptimeSec
        self.batteryPct = batteryPct
        self.memPct = memPct
        self.diskPct = diskPct
        self.interfaces = interfaces
    }
    public func toJson(now: Date = Date()) -> JSONBody {
        var j = JSONBody()
        j.put("protocol", HubProtocol.version)
        j.put("bridge_id", bridgeId)
        j.put("uptime_sec", uptimeSec)
        j.put("cpu_pct", 0.0)
        j.put("mem_pct", memPct)
        j.put("disk_pct", diskPct)
        j.put("battery_pct", batteryPct)
        j.put("interfaces", objects: interfaces.map { $0.toJson() })
        j.put("timestamp", HubProtocol.isoTimestamp(now))
        return j
    }
}

// MARK: Device lifecycle and telemetry

public struct DeviceBirth: Sendable, Equatable {
    public var deviceId: String
    public var bridgeId: String
    public var type: String
    public var label: String
    public var hardware: String
    public var firmware: String
    public var imei: String
    public var position: HubLocation?
    public var cotCallsign: String
    public var capabilities: [String]
    public init(
        deviceId: String, bridgeId: String, type: String, label: String, hardware: String = "", firmware: String = "", imei: String = "",
        position: HubLocation? = nil, cotCallsign: String = "", capabilities: [String] = []
    ) {
        self.deviceId = deviceId
        self.bridgeId = bridgeId
        self.type = type
        self.label = label
        self.hardware = hardware
        self.firmware = firmware
        self.imei = imei
        self.position = position
        self.cotCallsign = cotCallsign
        self.capabilities = capabilities
    }
    public func toJson(now: Date = Date()) -> JSONBody {
        var j = JSONBody()
        j.put("protocol", HubProtocol.version)
        j.put("device_id", deviceId)
        j.put("bridge_id", bridgeId)
        j.put("type", type)
        j.put("label", label)
        if !hardware.isEmpty { j.put("hardware", hardware) }
        if !firmware.isEmpty { j.put("firmware", firmware) }
        if !imei.isEmpty { j.put("imei", imei) }
        if let position { j.put("position", position.toJson()) }
        j.put("cot_type", HubProtocol.cotType(forDevice: type))
        j.put("cot_callsign", cotCallsign.isEmpty ? label : cotCallsign)
        j.put("capabilities", capabilities)
        j.put("timestamp", HubProtocol.isoTimestamp(now))
        return j
    }
}

public struct DeviceDeath: Sendable, Equatable {
    public var deviceId: String
    public var bridgeId: String
    public var reason: String
    public init(deviceId: String, bridgeId: String, reason: String = "offline") {
        self.deviceId = deviceId
        self.bridgeId = bridgeId
        self.reason = reason
    }
    public func toJson(now: Date = Date()) -> JSONBody {
        var j = JSONBody()
        j.put("protocol", HubProtocol.version)
        j.put("device_id", deviceId)
        j.put("bridge_id", bridgeId)
        j.put("reason", reason)
        j.put("timestamp", HubProtocol.isoTimestamp(now))
        return j
    }
}

public struct DevicePosition: Sendable, Equatable {
    public var lat: Double
    public var lon: Double
    public var alt: Double
    public var speed: Double
    public var course: Double
    public var source: String
    public var bridgeId: String
    public init(
        lat: Double, lon: Double, alt: Double = 0, speed: Double = 0, course: Double = 0, source: String = "gps", bridgeId: String = ""
    ) {
        self.lat = lat
        self.lon = lon
        self.alt = alt
        self.speed = speed
        self.course = course
        self.source = source
        self.bridgeId = bridgeId
    }
    public func toJson(now: Date = Date()) -> JSONBody {
        var j = JSONBody()
        j.put("lat", lat)
        j.put("lon", lon)
        if alt != 0 { j.put("alt", alt) }
        if speed != 0 { j.put("speed", speed) }
        if course != 0 { j.put("course", course) }
        j.put("source", source)
        if !bridgeId.isEmpty { j.put("bridge_id", bridgeId) }
        j.put("timestamp", HubProtocol.isoTimestamp(now))
        return j
    }
}

public struct DeviceTelemetry: Sendable, Equatable {
    public var batteryLevel: Double
    public var voltage: Double
    public var temperature: Double
    public var uptimeSec: Int64
    public var bridgeId: String
    public init(batteryLevel: Double = 0, voltage: Double = 0, temperature: Double = 0, uptimeSec: Int64 = 0, bridgeId: String = "") {
        self.batteryLevel = batteryLevel
        self.voltage = voltage
        self.temperature = temperature
        self.uptimeSec = uptimeSec
        self.bridgeId = bridgeId
    }
    public func toJson(now: Date = Date()) -> JSONBody {
        var j = JSONBody()
        if batteryLevel != 0 { j.put("battery_level", batteryLevel) }
        if voltage != 0 { j.put("voltage", voltage) }
        if temperature != 0 { j.put("temperature", temperature) }
        if uptimeSec != 0 { j.put("uptime_sec", uptimeSec) }
        if !bridgeId.isEmpty { j.put("bridge_id", bridgeId) }
        j.put("timestamp", HubProtocol.isoTimestamp(now))
        return j
    }
}

// MARK: Command channel

public struct HubCommand: Sendable, Equatable {
    public var cmd: String
    public var requestId: String
    public var targetDevice: String
    public var payload: String
    public init(cmd: String, requestId: String, targetDevice: String = "", payload: String = "") {
        self.cmd = cmd
        self.requestId = requestId
        self.targetDevice = targetDevice
        self.payload = payload
    }
    public static func fromJson(_ j: JSONBody) -> HubCommand {
        HubCommand(
            cmd: j.string("cmd") ?? "", requestId: j.string("request_id") ?? "", targetDevice: j.string("target_device") ?? "",
            payload: j.string("payload") ?? "")
    }
}

public struct CommandResponse: Sendable, Equatable {
    public var requestId: String
    public var cmd: String
    public var status: String
    public var error: String
    public init(requestId: String, cmd: String, status: String, error: String = "") {
        self.requestId = requestId
        self.cmd = cmd
        self.status = status
        self.error = error
    }
    public func toJson(now: Date = Date()) -> JSONBody {
        var j = JSONBody()
        j.put("protocol", HubProtocol.version)
        j.put("request_id", requestId)
        j.put("cmd", cmd)
        j.put("status", status)
        if !error.isEmpty { j.put("error", error) }
        j.put("timestamp", HubProtocol.isoTimestamp(now))
        return j
    }
}
