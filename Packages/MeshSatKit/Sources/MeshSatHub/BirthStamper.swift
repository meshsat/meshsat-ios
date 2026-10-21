// Mirrors hub/BirthStamper.kt (MESHSAT-1623): the timestamp of the next Hub birth, as the
// Bridge's hubreporter.birthStamp reserves it: now, but always later than the last stamp stored,
// also across a restart. The Hub orders a bridge's births by it and writes a declaration only
// when it is not older than what it stored (HeMB-NG S3-2), so a phone clock that stepped back
// cannot make a newer birth look older.
//
// The floor is read until it is read, and a stamp is stored before it is handed out: one that
// could not be stored is never handed out, so a restart never hands out again a stamp a birth
// carried. [MESHSAT-1624]
import Foundation

/// A birth stamp: whole microseconds since 1970-01-01T00:00:00Z, the precision the Bridge
/// stamps with, so a stamp read back from the store is the stamp written.
public struct BirthStamp: Sendable, Hashable, Comparable {
    public static let epoch = BirthStamp(micros: 0)

    public let micros: Int64

    public init(micros: Int64) { self.micros = micros }

    /// A clock reading in nanoseconds since the epoch, cut to the microsecond (Java's
    /// Instant.truncatedTo(MICROS), which rounds towards the past).
    public init(nanos: Int64) {
        let (q, r) = nanos.quotientAndRemainder(dividingBy: 1000)
        micros = r < 0 ? q - 1 : q
    }

    public static func < (a: BirthStamp, b: BirthStamp) -> Bool { a.micros < b.micros }
}

/// Keeps the timestamp of the last birth stamped, across restarts. `lastBirthStamp` answers nil
/// when none was ever stored, and throws when it cannot be read or what is stored is not a
/// timestamp: an unknown floor is never "no floor". `saveBirthStamp` throws when it cannot store.
public protocol BirthStampStore: Sendable {
    func lastBirthStamp() throws -> BirthStamp?
    func saveBirthStamp(_ stamp: BirthStamp) throws
}

public struct BirthStampError: Error, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public final class BirthStamper: @unchecked Sendable {
    private let store: (any BirthStampStore)?
    private let lock = NSLock()
    private var last = BirthStamp.epoch
    private var loaded = false

    /// Without a store the order holds for this process only.
    public init(store: (any BirthStampStore)?) {
        self.store = store
    }

    /// The stamp of the next birth for a clock reading of `nowNanos` nanoseconds since the epoch.
    /// Throws `BirthStampError` when the floor cannot be read or the stamp cannot be stored; the
    /// floor does not move then.
    public func next(nowNanos: Int64) throws -> BirthStamp {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            if let store {
                let stored: BirthStamp?
                do {
                    stored = try store.lastBirthStamp()
                } catch {
                    throw BirthStampError("the last birth stamp could not be read: \(error)")
                }
                if let stored, stored > last { last = stored }
            }
            loaded = true
        }
        var stamp = BirthStamp(nanos: nowNanos)
        if stamp <= last { stamp = BirthStamp(micros: last.micros + 1) }
        if let store {
            do {
                try store.saveBirthStamp(stamp)
            } catch {
                throw BirthStampError("the birth stamp could not be stored: \(error)")
            }
        }
        last = stamp
        return stamp
    }

    // MARK: The stored and published form

    /// RFC 3339 in UTC with as many fraction digits as needed, as Java's ISO_INSTANT writes it and
    /// the Hub parses a birth's timestamp: none on a whole second, 3 on a whole millisecond, else 6
    /// ("2026-10-21T13:00:00Z", "2026-10-21T13:00:00.000001Z"). Years 0 to 9999.
    public static func format(_ stamp: BirthStamp) -> String {
        let (seconds, fraction) = floorDivMod(stamp.micros, 1_000_000)
        let (days, secondOfDay) = floorDivMod(seconds, 86_400)
        let date = civil(fromDays: days)
        var out = pad(date.year, 4) + "-" + pad(date.month, 2) + "-" + pad(date.day, 2) + "T"
        out += pad(secondOfDay / 3600, 2) + ":" + pad(secondOfDay / 60 % 60, 2) + ":" + pad(secondOfDay % 60, 2)
        if fraction != 0 {
            out += fraction % 1000 == 0 ? "." + pad(fraction / 1000, 3) : "." + pad(fraction, 6)
        }
        return out + "Z"
    }

    /// The stored form back; throws `BirthStampError` when it is not a timestamp. Takes what
    /// `format` writes, with any fraction of up to nine digits (cut to the microsecond).
    public static func parse(_ stored: String) throws -> BirthStamp {
        let b = Array(stored.utf8)
        func digits(_ from: Int, _ count: Int) -> Int64? {
            guard from + count <= b.count else { return nil }
            var v: Int64 = 0
            for c in b[from..<(from + count)] {
                guard (0x30...0x39).contains(c) else { return nil }
                v = v * 10 + Int64(c - 0x30)
            }
            return v
        }
        func at(_ i: Int, _ chars: String) -> Bool { i < b.count && chars.utf8.contains(b[i]) }
        let bad = BirthStampError("not a timestamp: \(stored.prefix(40))")
        guard b.count >= 20, at(4, "-"), at(7, "-"), at(10, "Tt"), at(13, ":"), at(16, ":"),
            let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
            let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2)
        else { throw bad }
        var i = 19
        var micros: Int64 = 0
        if at(i, ".") {
            var n = 0
            i += 1
            while i < b.count, (0x30...0x39).contains(b[i]) {
                if n < 6 { micros = micros * 10 + Int64(b[i] - 0x30) }
                n += 1
                i += 1
            }
            guard (1...9).contains(n) else { throw bad }
            for _ in min(n, 6)..<6 { micros *= 10 }
        }
        guard i == b.count - 1, at(i, "Zz"), (1...12).contains(month), (1...daysIn(month: month, year: year)).contains(day),
            hour < 24, minute < 60, second < 60
        else { throw bad }
        let seconds = days(fromCivil: year, month, day) * 86_400 + hour * 3600 + minute * 60 + second
        return BirthStamp(micros: seconds * 1_000_000 + micros)
    }

    private static func floorDivMod(_ a: Int64, _ b: Int64) -> (Int64, Int64) {
        let (q, r) = a.quotientAndRemainder(dividingBy: b)
        return r < 0 ? (q - 1, r + b) : (q, r)
    }

    private static func pad(_ v: Int64, _ width: Int) -> String {
        let s = String(v)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }

    private static func daysIn(month: Int64, year: Int64) -> Int64 {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    private struct CivilDate {
        let year: Int64
        let month: Int64
        let day: Int64
    }

    /// Days since 1970-01-01 to a proleptic Gregorian date (H. Hinnant's civil_from_days).
    private static func civil(fromDays days: Int64) -> CivilDate {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return CivilDate(year: yoe + era * 400 + (month <= 2 ? 1 : 0), month: month, day: day)
    }

    /// The inverse: a proleptic Gregorian date to days since 1970-01-01 (days_from_civil).
    private static func days(fromCivil year: Int64, _ month: Int64, _ day: Int64) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
