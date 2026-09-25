// Mirrors aprs/Ax25Codec.kt, aprs/KissCodec.kt, aprs/AprsPacket.kt and aprs/AprsIsPasscode.kt
// (ports of the Bridge's internal/gateway/aprs_packet.go and aprs_kiss.go): AX.25 UI frames,
// the KISS TNC framing (TNC-2), APRS position and message encoding and parsing, and the
// APRS-IS passcode.
import Foundation

public struct Ax25Address: Sendable, Equatable, Hashable {
    public let call: String
    public let ssid: Int
    public init(_ call: String, _ ssid: Int = 0) {
        self.call = call
        self.ssid = ssid
    }
    public var formatted: String { ssid == 0 ? call : "\(call)-\(ssid)" }
}

public struct Ax25Frame: Sendable, Equatable {
    public let dst: Ax25Address
    public let src: Ax25Address
    public let path: [Ax25Address]
    public let info: [UInt8]
    public init(dst: Ax25Address, src: Ax25Address, path: [Ax25Address] = [], info: [UInt8] = []) {
        self.dst = dst
        self.src = src
        self.path = path
        self.info = info
    }
}

public enum Ax25Codec {
    /// An AX.25 UI frame for transmission.
    public static func encode(dst: Ax25Address, src: Ax25Address, path: [Ax25Address], info: [UInt8]) -> [UInt8] {
        var buf: [UInt8] = []
        buf += encodeAddress(dst, last: false)
        buf += encodeAddress(src, last: path.isEmpty)
        for (i, p) in path.enumerated() { buf += encodeAddress(p, last: i == path.count - 1) }
        // Control: UI frame (0x03), PID: no layer 3 (0xF0)
        buf += [0x03, 0xF0]
        buf += info
        return buf
    }

    /// An AX.25 UI frame from raw bytes, or nil when invalid.
    public static func decode(_ data: [UInt8]) -> Ax25Frame? {
        guard data.count >= 16 else { return nil }  // dst(7) + src(7) + ctrl(1) + pid(1)
        let dst = decodeAddress(data, 0)
        let src = decodeAddress(data, 7)
        var offset = 14
        var path: [Ax25Address] = []
        // The source's "last" flag unset means a path follows.
        if data[13] & 0x01 == 0 {
            while offset + 7 <= data.count {
                path.append(decodeAddress(data, offset))
                let last = data[offset + 6] & 0x01 == 1
                offset += 7
                if last { break }
            }
        }
        guard offset + 2 <= data.count, data[offset] == 0x03, data[offset + 1] == 0xF0 else { return nil }
        offset += 2
        return Ax25Frame(dst: dst, src: src, path: path, info: offset < data.count ? Array(data[offset...]) : [])
    }

    static func encodeAddress(_ addr: Ax25Address, last: Bool) -> [UInt8] {
        let call = Array(addr.call.uppercased().padding(toLength: 6, withPad: " ", startingAt: 0).utf8.prefix(6))
        var buf = call.map { $0 << 1 }
        // SSID byte: bits 4-1 = SSID, bit 0 = last flag, bits 6-5 reserved (set).
        buf.append(UInt8((addr.ssid & 0x0F) << 1) | 0x60 | (last ? 0x01 : 0x00))
        return buf
    }

    static func decodeAddress(_ data: [UInt8], _ offset: Int) -> Ax25Address {
        var call = ""
        for i in 0..<6 {
            let c = Character(UnicodeScalar(data[offset + i] >> 1))
            if c != " " { call.append(c) }
        }
        return Ax25Address(call, Int((data[offset + 6] >> 1) & 0x0F))
    }
}

public enum KissCodec {
    public static let fend: UInt8 = 0xC0
    public static let fesc: UInt8 = 0xDB
    public static let tfend: UInt8 = 0xDC
    public static let tfesc: UInt8 = 0xDD
    public static let data: UInt8 = 0x00

    /// FEND + command (0x00) + escaped data + FEND.
    public static func encode(_ payload: [UInt8]) -> [UInt8] {
        var buf: [UInt8] = [fend, data]
        buf.reserveCapacity(payload.count + 10)
        for b in payload {
            switch b {
            case fend: buf += [fesc, tfend]
            case fesc: buf += [fesc, tfesc]
            default: buf.append(b)
            }
        }
        buf.append(fend)
        return buf
    }

    /// The unescaped data of a KISS frame without its outer FENDs, or nil when invalid.
    public static func decode(_ frame: [UInt8]) -> [UInt8]? {
        guard frame.count >= 2, frame[0] & 0x0F == 0 else { return nil }
        var buf: [UInt8] = []
        var escaped = false
        for b in frame.dropFirst() {
            if escaped {
                switch b {
                case tfend: buf.append(fend)
                case tfesc: buf.append(fesc)
                default: return nil
                }
                escaped = false
            } else if b == fesc {
                escaped = true
            } else {
                buf.append(b)
            }
        }
        return escaped ? nil : buf
    }

    /// Splits a byte stream into KISS frames (the bytes between FENDs, command byte included).
    public struct Deframer: Sendable {
        private var buffer: [UInt8] = []
        private var inFrame = false
        public init() {}

        public mutating func feed(_ bytes: [UInt8]) -> [[UInt8]] {
            var out: [[UInt8]] = []
            for b in bytes {
                if b == KissCodec.fend {
                    if inFrame, !buffer.isEmpty { out.append(buffer) }
                    buffer.removeAll(keepingCapacity: true)
                    inFrame = true
                } else if inFrame {
                    buffer.append(b)
                }
            }
            return out
        }
    }
}

public struct AprsPacket: Sendable, Equatable {
    public var source = ""
    public var dest = ""
    public var path = ""
    public var dataType: Character = " "
    public var lat = 0.0
    public var lon = 0.0
    public var symbol = ""
    public var comment = ""
    public var message = ""
    public var msgTo = ""
    public var msgId = ""
    public var raw = ""
    public init(
        source: String = "", dest: String = "", path: String = "", dataType: Character = " ", lat: Double = 0, lon: Double = 0,
        symbol: String = "", comment: String = "", message: String = "", msgTo: String = "", msgId: String = "", raw: String = ""
    ) {
        self.source = source
        self.dest = dest
        self.path = path
        self.dataType = dataType
        self.lat = lat
        self.lon = lon
        self.symbol = symbol
        self.comment = comment
        self.message = message
        self.msgTo = msgTo
        self.msgId = msgId
        self.raw = raw
    }
}

public enum AprsCodec {
    /// An APRS packet from a decoded AX.25 frame.
    public static func parse(_ frame: Ax25Frame) -> AprsPacket {
        let pathStr = frame.path.map(\.formatted).joined(separator: ",")
        let info = String(decoding: frame.info, as: UTF8.self)
        var pkt = AprsPacket(source: frame.src.formatted, dest: frame.dst.formatted, path: pathStr, raw: info)
        guard let first = info.first else { return pkt }
        pkt.dataType = first
        return parseBody(pkt, info)
    }

    /// The data-type-specific fields of a packet whose `raw` is the info field.
    static func parseBody(_ packet: AprsPacket, _ info: String) -> AprsPacket {
        var pkt = packet
        let body = String(info.dropFirst())
        switch pkt.dataType {
        case "!", "=": pkt = parsePosition(pkt, body)
        case "/", "@":
            // Position with timestamp: skip the 7-character timestamp.
            if info.count > 8 { pkt = parsePosition(pkt, String(info.dropFirst(8))) }
        case ":": pkt = parseMessage(pkt, body)
        default: break
        }
        return pkt
    }

    /// An uncompressed position: !DDMM.MMN/DDDMM.MMW-comment
    public static func encodePosition(
        lat: Double, lon: Double, symbolTable: Character = "/", symbolCode: Character = "-", comment: String = ""
    ) -> [UInt8] {
        let absLat = abs(lat)
        let latDeg = Int(absLat)
        let latMin = (absLat - Double(latDeg)) * 60
        let absLon = abs(lon)
        let lonDeg = Int(absLon)
        let lonMin = (absLon - Double(lonDeg)) * 60
        let s = String(
            format: "!%02d%05.2f%@%@%03d%05.2f%@%@%@", locale: Locale(identifier: "en_US_POSIX"), latDeg, latMin, lat >= 0 ? "N" : "S",
            String(symbolTable), lonDeg, lonMin, lon >= 0 ? "E" : "W", String(symbolCode), comment)
        return Array(s.utf8)
    }

    /// A message: :ADDRESSEE :message text{seq
    public static func encodeMessage(to: String, text: String, msgId: String = "") -> [UInt8] {
        let padded = to.padding(toLength: max(9, to.count), withPad: " ", startingAt: 0)
        return Array((msgId.isEmpty ? ":\(padded):\(text)" : ":\(padded):\(text){\(msgId)").utf8)
    }

    static func parsePosition(_ packet: AprsPacket, _ s: String) -> AprsPacket {
        var pkt = packet
        let chars = Array(s)
        guard chars.count >= 19, let lat = parseLat(String(chars[0..<8])), let lon = parseLon(String(chars[9..<18])) else {
            pkt.comment = s
            return pkt
        }
        pkt.lat = lat
        pkt.lon = lon
        pkt.symbol = String(chars[8]) + String(chars[18])
        pkt.comment = chars.count > 19 ? String(chars[19...]) : ""
        return pkt
    }

    static func parseMessage(_ packet: AprsPacket, _ s: String) -> AprsPacket {
        var pkt = packet
        let chars = Array(s)
        guard chars.count >= 11 else { return pkt }
        pkt.msgTo = String(chars[0..<9]).trimmingCharacters(in: .whitespaces)
        guard chars[9] == ":" else { return pkt }
        var msg = String(chars[10...])
        if let brace = msg.lastIndex(of: "{") {
            pkt.msgId = String(msg[msg.index(after: brace)...])
            msg = String(msg[..<brace])
        }
        pkt.message = msg
        return pkt
    }

    /// "DDMM.MMN"
    static func parseLat(_ s: String) -> Double? {
        let c = Array(s)
        guard c.count == 8, let deg = Double(String(c[0..<2])), let min = Double(String(c[2..<7])) else { return nil }
        let lat = deg + min / 60
        return c[7] == "S" ? -lat : lat
    }

    /// "DDDMM.MMW"
    static func parseLon(_ s: String) -> Double? {
        let c = Array(s)
        guard c.count == 9, let deg = Double(String(c[0..<3])), let min = Double(String(c[3..<8])) else { return nil }
        let lon = deg + min / 60
        return c[8] == "W" ? -lon : lon
    }

    /// APRS messages carry at most 67 characters of text.
    public static let maxMessageLength = 67

    /// "@CALLSIGN text" is a directed message (MESHSAT-232): the addressee (1 to 9 characters
    /// of letters, digits and dashes, upper-cased) and the text, cut to 67 characters. Anything
    /// else is a bulletin.
    public static func directedMessage(_ text: String) -> (to: String, text: String)? {
        guard text.hasPrefix("@") else { return nil }
        let body = text.dropFirst()
        guard let space = body.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "\n" }) else { return nil }
        let call = body[..<space]
        guard (1...9).contains(call.count), call.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        let rest = body[space...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }
        return (call.uppercased(), String(rest.prefix(maxMessageLength)))
    }

    /// A TNC-2 line (SOURCE>DEST,PATH:payload), as APRS-IS sends them, or nil when malformed.
    public static func parseTnc2Line(_ line: String) -> AprsPacket? {
        guard let gt = line.firstIndex(of: ">"), gt > line.startIndex else { return nil }
        let source = String(line[..<gt])
        let rest = String(line[line.index(after: gt)...])
        guard let colon = rest.firstIndex(of: ":"), colon > rest.startIndex, rest.index(after: colon) < rest.endIndex else { return nil }
        let destPath = String(rest[..<colon])
        let payload = String(rest[rest.index(after: colon)...])
        let parts = destPath.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !payload.isEmpty, let first = payload.first else { return nil }
        let pkt = AprsPacket(
            source: source, dest: parts[0], path: parts.count > 1 ? parts[1...].joined(separator: ",") : "", dataType: first, raw: payload)
        return parseBody(pkt, payload)
    }
}

/// The APRS-IS passcode: a public hash of the base callsign (http://www.aprs-is.net/Connecting.aspx).
public enum AprsIsPasscode {
    public static func calculate(_ callsign: String) -> String {
        let base = callsign.split(separator: "-").first.map { String($0).uppercased() } ?? ""
        if base.isEmpty { return "-1" }
        var hash = 0x73E2
        let chars = Array(base.utf8)
        var i = 0
        while i < chars.count {
            hash ^= Int(chars[i]) << 8
            if i + 1 < chars.count { hash ^= Int(chars[i + 1]) }
            i += 2
        }
        return String(hash & 0x7FFF)
    }
}
