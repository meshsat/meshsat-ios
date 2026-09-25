// Mirrors tak/CotXml.kt: the CoT XML serializer and parser. The output matches Android's byte
// for byte, including Kotlin's Double.toString layout for the numbers ("47.3", "0.0", "1.0E7").
// The parser is a small one of our own: Foundation's XMLParser lives in a different module on
// Linux, and CoT is flat enough (a root, a point, a detail with attribute-only children and two
// text-carrying ones).
import Foundation

public enum CotXml {
    /// A CotEvent as CoT v2.0 XML.
    public static func marshal(_ ev: CotEvent) -> String {
        var s = "<event"
        attr(&s, "version", ev.version)
        attr(&s, "uid", ev.uid)
        attr(&s, "type", ev.type)
        attr(&s, "how", ev.how)
        attr(&s, "time", ev.time)
        attr(&s, "start", ev.start)
        attr(&s, "stale", ev.stale)
        s += ">"
        s += "<point"
        attr(&s, "lat", kotlinDouble(ev.point.lat))
        attr(&s, "lon", kotlinDouble(ev.point.lon))
        attr(&s, "hae", kotlinDouble(ev.point.hae))
        attr(&s, "ce", kotlinDouble(ev.point.ce))
        attr(&s, "le", kotlinDouble(ev.point.le))
        s += "></point>"
        if let d = ev.detail {
            s += "<detail>"
            if let c = d.contact {
                s += "<contact"
                attr(&s, "callsign", c.callsign)
                s += "></contact>"
            }
            if let g = d.group {
                s += "<__group"
                attr(&s, "name", g.name)
                attr(&s, "role", g.role)
                s += "></__group>"
            }
            if let p = d.precision {
                s += "<precisionlocation"
                attr(&s, "altsrc", p.altSrc)
                attr(&s, "geopointsrc", p.geoPointSrc)
                s += "></precisionlocation>"
            }
            if let t = d.track {
                s += "<track"
                attr(&s, "course", kotlinDouble(t.course))
                attr(&s, "speed", kotlinDouble(t.speed))
                s += "></track>"
            }
            if let st = d.status, !st.battery.isEmpty {
                s += "<status"
                attr(&s, "battery", st.battery)
                s += "></status>"
            }
            if let e = d.emergency {
                s += "<emergency"
                attr(&s, "type", e.type)
                s += ">" + escape(e.text) + "</emergency>"
            }
            if let r = d.remarks {
                s += "<remarks"
                if !r.source.isEmpty { attr(&s, "source", r.source) }
                s += ">" + escape(r.text) + "</remarks>"
            }
            s += "</detail>"
        }
        s += "</event>"
        return s
    }

    /// A CotEvent from CoT XML, or nil when it is not one.
    public static func parse(_ xml: String) -> CotEvent? {
        guard let root = XmlLite.parse(xml), root.name == "event" else { return nil }
        let point = root.child("point")
        let detail = root.child("detail")
        return CotEvent(
            version: root.attributes["version"] ?? "", uid: root.attributes["uid"] ?? "", type: root.attributes["type"] ?? "",
            how: root.attributes["how"] ?? "", time: root.attributes["time"] ?? "", start: root.attributes["start"] ?? "",
            stale: root.attributes["stale"] ?? "",
            point: CotPoint(
                lat: point?.double("lat") ?? 0, lon: point?.double("lon") ?? 0, hae: point?.double("hae") ?? 0,
                ce: point?.double("ce") ?? 10, le: point?.double("le") ?? 10),
            detail: detail.map(parseDetail))
    }

    private static func parseDetail(_ node: XmlLite.Element) -> CotDetail {
        var d = CotDetail()
        for child in node.children {
            switch child.name {
            case "contact": d.contact = CotContact(callsign: child.attributes["callsign"] ?? "")
            case "__group": d.group = CotGroup(name: child.attributes["name"] ?? "Cyan", role: child.attributes["role"] ?? "Team Member")
            case "precisionlocation":
                d.precision = CotPrecision(
                    altSrc: child.attributes["altsrc"] ?? "GPS", geoPointSrc: child.attributes["geopointsrc"] ?? "GPS")
            case "track": d.track = CotTrack(course: child.double("course") ?? 0, speed: child.double("speed") ?? 0)
            case "status": d.status = CotStatus(battery: child.attributes["battery"] ?? "")
            case "emergency": d.emergency = CotEmergency(type: child.attributes["type"] ?? "", text: child.text)
            case "remarks": d.remarks = CotRemarks(source: child.attributes["source"] ?? "", text: child.text)
            default: break
            }
        }
        return d
    }

    private static func attr(_ s: inout String, _ name: String, _ value: String) {
        s += " \(name)=\"\(escape(value))\""
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(c)
            }
        }
        return out
    }

    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            rest = rest[amp...]
            guard let semi = rest.firstIndex(of: ";") else { break }
            let entity = rest[rest.index(after: rest.startIndex)..<semi]
            switch entity {
            case "amp": out += "&"
            case "lt": out += "<"
            case "gt": out += ">"
            case "quot": out += "\""
            case "apos": out += "'"
            default:
                if entity.hasPrefix("#x"), let v = UInt32(entity.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) {
                    out.unicodeScalars.append(u)
                } else if entity.hasPrefix("#"), let v = UInt32(entity.dropFirst()), let u = Unicode.Scalar(v) {
                    out.unicodeScalars.append(u)
                } else {
                    out += rest[...semi]
                }
            }
            rest = rest[rest.index(after: semi)...]
        }
        out += rest
        return out
    }

    /// Kotlin's Double.toString: the shortest round-trip digits, at least one decimal, and
    /// scientific notation ("1.0E7", "1.0E-4") outside [1e-3, 1e7).
    public static func kotlinDouble(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
        if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
        let a = abs(d)
        let sign = d < 0 ? "-" : ""
        if a >= 1e-3, a < 1e7 {
            let s = "\(a)"
            // Swift keeps plain notation in this range and always writes a fraction.
            return sign + s
        }
        // Digits and decimal exponent out of Swift's shortest representation.
        var (digits, exp) = shortestDigits(a)
        while digits.count > 1, digits.last == "0" { digits.removeLast() }
        let first = String(digits.prefix(1))
        let rest = digits.count > 1 ? String(digits.dropFirst()) : "0"
        _ = exp
        return "\(sign)\(first).\(rest)E\(exp)"
    }

    /// The significant digits of `a` and the exponent of its first digit (a = 0.d1d2... x 10^(exp+1)).
    private static func shortestDigits(_ a: Double) -> (String, Int) {
        let s = "\(a)"  // "1e-05", "1e+16", "12345678.9", "0.0001"
        var mantissa = s
        var exp10 = 0
        if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(s[..<e])
            exp10 = Int(s[s.index(after: e)...].replacingOccurrences(of: "+", with: "")) ?? 0
        }
        var intPart = mantissa
        var fracPart = ""
        if let dot = mantissa.firstIndex(of: ".") {
            intPart = String(mantissa[..<dot])
            fracPart = String(mantissa[mantissa.index(after: dot)...])
        }
        var digits = intPart + fracPart
        var pointPos = intPart.count + exp10  // digits before the decimal point
        // Strip leading zeros, moving the point.
        while digits.count > 1, digits.first == "0" {
            digits.removeFirst()
            pointPos -= 1
        }
        while digits.count > 1, digits.last == "0" { digits.removeLast() }
        return (digits, pointPos - 1)
    }
}

/// A flat XML reader: elements, attributes, text; enough for CoT.
enum XmlLite {
    struct Element {
        var name: String
        var attributes: [String: String] = [:]
        var children: [Element] = []
        var text = ""
        func child(_ name: String) -> Element? { children.first { $0.name == name } }
        func double(_ attribute: String) -> Double? { attributes[attribute].flatMap(Double.init) }
    }

    static func parse(_ xml: String) -> Element? {
        var scanner = Scanner(chars: Array(xml))
        scanner.skipProlog()
        guard let root = scanner.element() else { return nil }
        return root
    }

    private struct Scanner {
        let chars: [Character]
        var i = 0
        init(chars: [Character]) { self.chars = chars }

        var atEnd: Bool { i >= chars.count }

        mutating func skipWhitespace() { while !atEnd, chars[i].isWhitespace { i += 1 } }

        /// Skips "<?xml ...?>" and comments before the root.
        mutating func skipProlog() {
            while true {
                skipWhitespace()
                if starts("<?") {
                    guard let end = find("?>") else { return }
                    i = end + 2
                } else if starts("<!--") {
                    guard let end = find("-->") else { return }
                    i = end + 3
                } else {
                    return
                }
            }
        }

        func starts(_ s: String) -> Bool {
            let sc = Array(s)
            guard i + sc.count <= chars.count else { return false }
            return Array(chars[i..<(i + sc.count)]) == sc
        }

        func find(_ s: String) -> Int? {
            let sc = Array(s)
            var j = i
            while j + sc.count <= chars.count {
                if Array(chars[j..<(j + sc.count)]) == sc { return j }
                j += 1
            }
            return nil
        }

        mutating func name() -> String {
            var n = ""
            while !atEnd, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "-" || chars[i] == ":" || chars[i] == "."
            {
                n.append(chars[i])
                i += 1
            }
            return n
        }

        /// "<name attr="v" ...>" ... "</name>" or "<name .../>"; nil when the text here is not an element.
        mutating func element() -> Element? {
            guard !atEnd, chars[i] == "<", i + 1 < chars.count, chars[i + 1] != "/" else { return nil }
            i += 1
            let n = name()
            guard !n.isEmpty else { return nil }
            var el = Element(name: n)
            guard let selfClosing = attributes(into: &el) else { return nil }
            if selfClosing { return el }
            return content(into: &el) ? el : nil
        }

        /// The attributes up to ">" (false) or "/>" (true); nil when malformed.
        private mutating func attributes(into el: inout Element) -> Bool? {
            while true {
                skipWhitespace()
                guard !atEnd else { return nil }
                if chars[i] == "/" {
                    i += 1
                    guard !atEnd, chars[i] == ">" else { return nil }
                    i += 1
                    return true
                }
                if chars[i] == ">" {
                    i += 1
                    return false
                }
                let an = name()
                guard !an.isEmpty else { return nil }
                skipWhitespace()
                guard !atEnd, chars[i] == "=" else { return nil }
                i += 1
                skipWhitespace()
                guard !atEnd, chars[i] == "\"" || chars[i] == "'" else { return nil }
                let quote = chars[i]
                i += 1
                var v = ""
                while !atEnd, chars[i] != quote {
                    v.append(chars[i])
                    i += 1
                }
                guard !atEnd else { return nil }
                i += 1
                el.attributes[an] = CotXml.unescape(v)
            }
        }

        /// Text and child elements up to the matching close tag; false when malformed.
        private mutating func content(into el: inout Element) -> Bool {
            var text = ""
            while true {
                guard !atEnd else { return false }
                if starts("</") {
                    i += 2
                    guard name() == el.name else { return false }
                    skipWhitespace()
                    guard !atEnd, chars[i] == ">" else { return false }
                    i += 1
                    el.text = CotXml.unescape(text)
                    return true
                }
                if starts("<!--") {
                    guard let end = find("-->") else { return false }
                    i = end + 3
                } else if starts("<![CDATA[") {
                    guard let end = find("]]>") else { return false }
                    text += String(chars[(i + 9)..<end])
                    i = end + 3
                } else if chars[i] == "<" {
                    guard let child = element() else { return false }
                    el.children.append(child)
                } else {
                    text.append(chars[i])
                    i += 1
                }
            }
        }
    }
}
