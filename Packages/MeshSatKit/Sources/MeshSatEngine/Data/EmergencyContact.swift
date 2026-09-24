// Mirrors data/EmergencyContact.kt: someone an SOS goes to by SMS (MESHSAT-1249). Stored in
// settings as one "name<TAB>phone" per line; a name can hold neither a tab nor a line break, and
// `normalisePhone` leaves only digits and a leading plus in the number.
import Foundation

public struct EmergencyContact: Sendable, Equatable, Hashable {
    public static let max = 10

    public var name: String
    public var phone: String

    public init(name: String, phone: String) {
        self.name = name
        self.phone = phone
    }

    public static func encode(_ list: [EmergencyContact]) -> String {
        list.map { "\(cleanName($0.name))\t\($0.phone)" }.joined(separator: "\n")
    }

    public static func decode(_ s: String) -> [EmergencyContact] {
        var out: [EmergencyContact] = []
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            guard let phone = normalisePhone(String(line[line.index(after: tab)...])) else { continue }
            out.append(EmergencyContact(name: String(line[..<tab]).trimmingCharacters(in: .whitespaces), phone: phone))
            if out.count == max { break }
        }
        return out
    }

    /// What came of adding someone: the new list, or why not, in words for the screen.
    public enum Added: Sendable, Equatable {
        case ok([EmergencyContact])
        case no(String)
    }

    /// Add `name` and `rawPhone` to `list`, whether they were picked from the phone's contacts
    /// or typed. A contacts app hands numbers over as people wrote them ("06 12 34 56 78",
    /// "(020) 555-0100"), so the number is normalised here and nowhere else.
    public static func adding(_ list: [EmergencyContact], name: String, rawPhone: String) -> Added {
        if list.count >= max { return .no("The list is full: \(max) contacts at most.") }
        guard let phone = normalisePhone(rawPhone) else {
            let blank = rawPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return .no(blank ? "That contact has no phone number." : "That is not a phone number.")
        }
        if list.contains(where: { $0.phone == phone }) { return .no("That number is already on the list.") }
        let clean = String(cleanName(name).trimmingCharacters(in: .whitespaces).prefix(40))
        return .ok(list + [EmergencyContact(name: clean, phone: phone)])
    }

    private static func cleanName(_ name: String) -> String {
        name.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    /// A phone number as the phone's SMS service takes it: an optional leading +, then 3 to 15
    /// digits (E.164 at most), spaces, dashes, dots and brackets dropped. Nil when it is not one.
    public static func normalisePhone(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let plus = t.hasPrefix("+")
        let body = plus ? String(t.dropFirst()) : t
        let digits = body.filter { !" -.()".contains($0) }
        guard (3...15).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return plus ? "+" + digits : digits
    }
}
