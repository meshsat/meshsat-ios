// Mirrors satellite/TleParser.kt: two- and three-line element sets, their epoch, and the
// Julian-date helpers PassPredictor and Sgp4 share. Unix times in this module are SECONDS
// (MESHSAT-498: milliseconds passed into the predictor once ran the propagator 1000x too long
// and exhausted the heap), hence the UnixSeconds type.
import Foundation

public struct UnixSeconds: Sendable, Equatable, Hashable, Comparable {
    public let value: Double
    public init(_ value: Double) { self.value = value }
    public init(_ date: Date) { self.value = date.timeIntervalSince1970 }
    public var date: Date { Date(timeIntervalSince1970: value) }
    public static func < (a: UnixSeconds, b: UnixSeconds) -> Bool { a.value < b.value }
}

public struct TleElements: Sendable, Equatable, Hashable {
    public let name: String
    public let line1: String
    public let line2: String
    public let catalogNumber: Int
    /// Epoch as a Julian date (days).
    public let epochJd: Double
    public let bstar: Double
    /// First derivative of the mean motion, rev/day^2 (line 1 columns 34-43); read, not used by SGP4.
    public let meanMotionDot: Double
    /// Second derivative of the mean motion, rev/day^3 (line 1 columns 45-52); read, not used by SGP4.
    public let meanMotionDDot: Double
    public let inclinationDeg: Double
    public let raanDeg: Double
    public let eccentricity: Double
    public let argPerigeeDeg: Double
    public let meanAnomalyDeg: Double
    /// Revolutions per day.
    public let meanMotion: Double

    public init(
        name: String, line1: String, line2: String, catalogNumber: Int, epochJd: Double, bstar: Double,
        meanMotionDot: Double, meanMotionDDot: Double, inclinationDeg: Double, raanDeg: Double,
        eccentricity: Double, argPerigeeDeg: Double, meanAnomalyDeg: Double, meanMotion: Double
    ) {
        self.name = name
        self.line1 = line1
        self.line2 = line2
        self.catalogNumber = catalogNumber
        self.epochJd = epochJd
        self.bstar = bstar
        self.meanMotionDot = meanMotionDot
        self.meanMotionDDot = meanMotionDDot
        self.inclinationDeg = inclinationDeg
        self.raanDeg = raanDeg
        self.eccentricity = eccentricity
        self.argPerigeeDeg = argPerigeeDeg
        self.meanAnomalyDeg = meanAnomalyDeg
        self.meanMotion = meanMotion
    }

    public var epoch: UnixSeconds { TleParser.jdToUnix(epochJd) }
}

public enum TleParseError: Error, Equatable, Sendable {
    case lineTooShort(Int)
    case badLineNumber(Int)
    case badField(String)
}

public enum TleParser {
    /// Parse one set from its two data lines (a name is optional).
    public static func parse(name: String?, line1: String, line2: String) throws -> TleElements {
        let l1 = Array(line1), l2 = Array(line2)
        guard l1.count >= 69 else { throw TleParseError.lineTooShort(1) }
        guard l2.count >= 69 else { throw TleParseError.lineTooShort(2) }
        guard l1[0] == "1" else { throw TleParseError.badLineNumber(1) }
        guard l2[0] == "2" else { throw TleParseError.badLineNumber(2) }

        let catalog = try int(String(l2[2..<7]), "catalog")
        let epochYear2 = try int(String(l1[18..<20]), "epoch year")
        let epochDay = try double(String(l1[20..<32]), "epoch day")
        let year = epochYear2 < 57 ? 2000 + epochYear2 : 1900 + epochYear2
        let epochJd = julianDay(year: year, month: 1, day: 1) + epochDay - 1.0
        let bstar = try parseExponent(String(l1[53..<61]))
        let ndot = try double(String(l1[33..<43]), "mean motion dot")
        let nddot = try parseExponent(String(l1[44..<52]))
        let inc = try double(String(l2[8..<16]), "inclination")
        let raan = try double(String(l2[17..<25]), "raan")
        let ecc = try double("0." + String(l2[26..<33]).trimmingCharacters(in: .whitespaces), "eccentricity")
        let argp = try double(String(l2[34..<42]), "arg of perigee")
        let ma = try double(String(l2[43..<51]), "mean anomaly")
        let mm = try double(String(l2[52..<63]), "mean motion")

        let cleanName = (name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^0 ", with: "", options: .regularExpression)
        return TleElements(
            name: cleanName.isEmpty ? "SAT \(catalog)" : cleanName,
            line1: line1, line2: line2, catalogNumber: catalog, epochJd: epochJd, bstar: bstar,
            meanMotionDot: ndot, meanMotionDDot: nddot, inclinationDeg: inc, raanDeg: raan, eccentricity: ecc, argPerigeeDeg: argp,
            meanAnomalyDeg: ma, meanMotion: mm
        )
    }

    /// Parse a whole 3LE or 2LE file. Malformed sets are skipped, as Android's parseMulti does.
    public static func parseMulti(_ text: String) -> [TleElements] {
        let lines = text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
        var out = [TleElements]()
        var pendingName: String?
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("1 "), i + 1 < lines.count, lines[i + 1].hasPrefix("2 ") {
                if let set = try? parse(name: pendingName, line1: line, line2: lines[i + 1]) {
                    out.append(set)
                }
                pendingName = nil
                i += 2
                continue
            }
            pendingName = line.isEmpty ? nil : line
            i += 1
        }
        return out
    }

    /// TLE exponent notation: " 12345-3" means 0.12345e-3; "-11606-4" means -0.11606e-4.
    public static func parseExponent(_ field: String) throws -> Double {
        let s = field.trimmingCharacters(in: .whitespaces)
        guard s.count >= 3 else {
            if s.isEmpty || s == "0" { return 0 }
            throw TleParseError.badField("exponent \(field)")
        }
        let chars = Array(s)
        var sign = 1.0
        var idx = 0
        if chars[0] == "-" {
            sign = -1
            idx = 1
        } else if chars[0] == "+" {
            idx = 1
        }
        // the exponent is the last two characters (sign + digit)
        guard chars.count - idx >= 3 else { throw TleParseError.badField("exponent \(field)") }
        let expPart = String(chars[(chars.count - 2)...])
        let mantPart = String(chars[idx..<(chars.count - 2)])
        guard let mant = Double("0." + mantPart), let exp = Int(expPart) else {
            throw TleParseError.badField("exponent \(field)")
        }
        return sign * mant * pow(10.0, Double(exp))
    }

    /// Julian day number for a civil date at 0h UT (Vallado's algorithm, valid 1900 to 2100).
    public static func julianDay(year: Int, month: Int, day: Int) -> Double {
        367.0 * Double(year)
            - floor(7.0 * (Double(year) + floor((Double(month) + 9.0) / 12.0)) * 0.25)
            + floor(275.0 * Double(month) / 9.0)
            + Double(day) + 1721013.5
    }

    public static let unixEpochJd = 2440587.5

    public static func jdToUnix(_ jd: Double) -> UnixSeconds {
        UnixSeconds((jd - unixEpochJd) * 86400.0)
    }

    public static func unixToJd(_ t: UnixSeconds) -> Double {
        t.value / 86400.0 + unixEpochJd
    }

    private static func int(_ s: String, _ what: String) throws -> Int {
        guard let v = Int(s.trimmingCharacters(in: .whitespaces)) else { throw TleParseError.badField(what) }
        return v
    }

    private static func double(_ s: String, _ what: String) throws -> Double {
        guard let v = Double(s.trimmingCharacters(in: .whitespaces)) else { throw TleParseError.badField(what) }
        return v
    }
}

/// The Iridium NEXT element sets that ship with the app (Resources/tle/iridium-next.3le).
public enum BundledTle {
    public static func load() -> [TleElements] {
        guard let url = Bundle.module.url(forResource: "iridium-next", withExtension: "3le", subdirectory: "tle"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return TleParser.parseMulti(text)
    }
}
