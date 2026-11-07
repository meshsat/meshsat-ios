// Mirrors support/SupportBundle.kt and support/SupportRedactor.kt (MESHSAT-1806, iOS MESHSAT-1810):
// the debug.zip a user can attach to feedback, a few plain-text files, each redacted on the way in,
// and the mail it travels with. Pure Swift, Linux-tested; MeshSatPlatform's SupportReport gathers
// the texts from the running app.
//
// The zip and the mail body's `--` block are a contract with paops' support-mail parser (PAOPS-81):
// entry names, line formats, the zip name and that block change only after telling the paops side.
import Foundation

public enum SupportBundle {
    /// One file in the zip.
    public struct Part: Sendable, Equatable {
        public let name: String
        public let text: String
        public init(name: String, text: String) {
            self.name = name
            self.text = text
        }
    }

    /// Where the desk's mail goes: the MeshSat Support desk's mailbox.
    public static let supportAddress = "support@meshsat.net"

    /// The ceiling for any one text, so a runaway log cannot make an attachment mail refuses.
    public static let maxPartChars = 4_000_000

    public enum Topic: String, Sendable, CaseIterable {
        case problem, idea, question
        public var label: String {
            switch self {
            case .problem: "Something is wrong"
            case .idea: "An idea"
            case .question: "A question"
            }
        }
        public var subject: String {
            switch self {
            case .problem: "a problem"
            case .idea: "an idea"
            case .question: "a question"
            }
        }
    }

    /// `meshsat-debug-yyyyMMdd-HHmmss.zip` in `zone`'s time.
    public static func fileName(nowMs: Int64, zone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "meshsat-debug-\(f.string(from: Date(timeIntervalSince1970: Double(nowMs) / 1000))).zip"
    }

    /// The zip of `parts`, every text redacted and cut to `maxPartChars` (the newest end kept: a
    /// log's last lines are the ones that matter). Entry times are `nowMs`.
    public static func bytes(_ parts: [Part], nowMs: Int64, zone: TimeZone = .current) -> [UInt8] {
        var zip = ZipWriter(modified: Date(timeIntervalSince1970: Double(nowMs) / 1000), zone: zone)
        for part in parts { zip.add(name: part.name, data: Array(SupportRedactor.redact(cut(part.text)).utf8)) }
        return zip.finish()
    }

    static func cut(_ text: String) -> String {
        guard text.count > maxPartChars else { return text }
        return "[the first \(text.count - maxPartChars) characters were cut]\n" + String(text.suffix(maxPartChars))
    }

    /// What the mail says about the app and the phone, under the `--`.
    public struct About: Sendable, Equatable {
        public let version: String
        public let build: String
        /// "App Store edition", "TestFlight build", "developer build".
        public let edition: String
        public let ios: String
        /// The hardware identifier, e.g. "iPhone17,3".
        public let device: String
        public init(version: String, build: String, edition: String, ios: String, device: String) {
            self.version = version
            self.build = build
            self.edition = edition
            self.ios = ios
            self.device = device
        }
    }

    /// The mail body under the user's own words: enough for the desk to know the version and the
    /// phone even when no zip is attached. No identifier of the phone or its owner.
    public static func mailBody(_ userText: String, about a: About, attached: Bool) -> String {
        var out = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        out += "\n\n--\n"
        out += "MeshSat iOS \(a.version) (\(a.build)), \(a.edition)\n"
        out += "iOS \(a.ios), \(a.device)\n"
        if attached { out += "A debug.zip with the app's logs is attached.\n" }
        return out
    }

    /// Subject line by topic, so the desk can sort without opening the mail.
    public static func subject(_ topic: Topic, version: String) -> String { "MeshSat iOS \(version): \(topic.subject)" }

    /// mailto: link with subject and body, for when no mail account takes the file. RFC 6068:
    /// percent-encoded, a space is %20, never "+" (as java.net.URLEncoder with "+" turned into %20).
    public static func mailtoUri(address: String, subject: String, body: String) -> String {
        "mailto:\(address)?subject=\(encode(subject))&body=\(encode(body))"
    }

    private static let unreserved: Set<UInt8> = Set(Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-*_".utf8))

    private static func encode(_ v: String) -> String {
        var out = ""
        for b in v.utf8 {
            if unreserved.contains(b) {
                out.unicodeScalars.append(UnicodeScalar(b))
            } else {
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }
}

/// Blanks what a debug report must not carry before it leaves the phone: keys and secrets, email
/// addresses, phone numbers, IMEIs, and all but the last byte of a Bluetooth or Wi-Fi address. What
/// stays readable is what support needs to follow a fault: times, states, interface names, error
/// texts, node ids. A safety net, not a licence to log private data: the app's own log lines are
/// meant to carry none of this in the first place. Android's regexes, rule for rule.
public enum SupportRedactor {
    private struct Rule: @unchecked Sendable {
        let regex: NSRegularExpression
        let replace: @Sendable ([String]) -> String
    }

    private static func rule(_ pattern: String, _ replace: @escaping @Sendable ([String]) -> String) -> Rule {
        // The patterns are constants and covered by the tests.
        // swiftlint:disable:next force_try
        Rule(regex: try! NSRegularExpression(pattern: pattern), replace: replace)
    }

    private static let rules: [Rule] = [
        // PEM blocks first, before the base64 inside them can look like anything else.
        rule(#"-----BEGIN [A-Z0-9 ]+-----[\s\S]*?-----END [A-Z0-9 ]+-----"#) { _ in "[key removed]" },
        rule(#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#) { _ in "Bearer [removed]" },
        // name=value or "name": "value" for the names a secret goes by.
        rule(#"(?i)\b(password|passwd|token|secret|api[_-]?key|psk)("?\s*[:=]\s*"?)([^\s"',;&}]+)"#) { g in "\(g[1])\(g[2])[removed]" },
        // Starts only where a run of address characters starts, and never backtracks into it.
        rule(#"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]++@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#) { _ in "[email]" },
        // International numbers: + then 7 to 15 digits, single spaces or dashes allowed between them.
        rule(#"(?<![\w+])\+\d(?:[ -]?\d){6,14}(?!\d)"#) { _ in "[phone]" },
        // National numbers written with the leading 0 (ten digits); unix seconds never start with 0.
        rule(#"(?<![\w.])0\d{9}(?![\w])"#) { _ in "[phone]" },
        // An IMEI is exactly 15 digits; millisecond timestamps have 13.
        rule(#"(?<![\w.])\d{15}(?![\w.])"#) { _ in "[imei]" },
        // MAC addresses keep their last byte, enough to tell two devices apart in one report.
        rule(#"(?i)\b(?:[0-9a-f]{2}[:-]){5}([0-9a-f]{2})\b"#) { g in "XX:XX:XX:XX:XX:\(g[1])" },
    ]

    public static func redact(_ text: String) -> String {
        var out = text
        for r in rules {
            let ns = out as NSString
            let matches = r.regex.matches(in: out, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            var result = ""
            var last = 0
            for m in matches {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let groups = (0..<m.numberOfRanges).map { i -> String in
                    let g = m.range(at: i)
                    return g.location == NSNotFound ? "" : ns.substring(with: g)
                }
                result += r.replace(groups)
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out
    }
}

/// A zip of stored (uncompressed) entries with CRC-32, enough for a debug report: every unzip tool
/// and mail scanner reads it, and it needs no compression library on either platform.
struct ZipWriter {
    private var out: [UInt8] = []
    private var central: [UInt8] = []
    private var count = 0
    private let dosTime: UInt16
    private let dosDate: UInt16

    init(modified: Date, zone: TimeZone) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: modified)
        let year: Int = max(1980, c.year ?? 1980)
        let hour: Int = c.hour ?? 0
        let minute: Int = c.minute ?? 0
        let second: Int = c.second ?? 0
        let month: Int = c.month ?? 1
        let day: Int = c.day ?? 1
        let time: Int = (hour << 11) | (minute << 5) | (second / 2)
        let date: Int = ((year - 1980) << 9) | (month << 5) | day
        dosTime = UInt16(truncatingIfNeeded: time)
        dosDate = UInt16(truncatingIfNeeded: date)
    }

    mutating func add(name: String, data: [UInt8]) {
        let nameBytes = Array(name.utf8)
        let crc = CRC32.checksum(data)
        let offset = UInt32(out.count)
        // Local file header; flag bit 11: the name is UTF-8.
        Self.put32(&out, 0x0403_4B50)
        for v: UInt16 in [20, 0x0800, 0, dosTime, dosDate] { Self.put16(&out, v) }
        for v: UInt32 in [crc, UInt32(data.count), UInt32(data.count)] { Self.put32(&out, v) }
        for v: UInt16 in [UInt16(nameBytes.count), 0] { Self.put16(&out, v) }
        out.append(contentsOf: nameBytes)
        out.append(contentsOf: data)
        // Its central directory record.
        Self.put32(&central, 0x0201_4B50)
        for v: UInt16 in [20, 20, 0x0800, 0, dosTime, dosDate] { Self.put16(&central, v) }
        for v: UInt32 in [crc, UInt32(data.count), UInt32(data.count)] { Self.put32(&central, v) }
        for v: UInt16 in [UInt16(nameBytes.count), 0, 0, 0, 0] { Self.put16(&central, v) }
        for v: UInt32 in [0, offset] { Self.put32(&central, v) }
        central.append(contentsOf: nameBytes)
        count += 1
    }

    mutating func finish() -> [UInt8] {
        let start = UInt32(out.count)
        var all = out
        all.append(contentsOf: central)
        Self.put32(&all, 0x0605_4B50)
        for v: UInt16 in [0, 0, UInt16(count), UInt16(count)] { Self.put16(&all, v) }
        for v: UInt32 in [UInt32(central.count), start] { Self.put32(&all, v) }
        Self.put16(&all, 0)
        return all
    }

    private static func put16(_ b: inout [UInt8], _ v: UInt16) {
        b.append(UInt8(v & 0xFF))
        b.append(UInt8(v >> 8))
    }

    private static func put32(_ b: inout [UInt8], _ v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { b.append(UInt8((v >> UInt32(shift)) & 0xFF)) }
    }
}

/// CRC-32 (IEEE 802.3, the zip one).
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
