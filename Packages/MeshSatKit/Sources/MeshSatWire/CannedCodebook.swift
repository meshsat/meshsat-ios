// Mirrors codec/CannedCodebook.kt (a port of the Bridge's internal/codec/canned.go): numbered
// brevity phrases, [0xCA] [id] on the wire.
import Foundation

public struct CannedCodebook: Sendable {
    public static let headerCanned: UInt8 = 0xCA

    public static let defaultEntries: [Int: String] = [
        1: "Copy.",
        2: "Roger.",
        3: "Negative.",
        4: "Affirmative.",
        5: "Stand by.",
        6: "All clear.",
        7: "Moving out.",
        8: "Returning to base.",
        9: "Position confirmed.",
        10: "Mission complete.",
        11: "Need resupply.",
        12: "Requesting backup.",
        13: "Medical emergency.",
        14: "Evacuate immediately.",
        15: "Hold position.",
        16: "Proceed to waypoint.",
        17: "Enemy contact.",
        18: "All personnel accounted for.",
        19: "Weather deteriorating.",
        20: "Low battery warning.",
        21: "Signal lost.",
        22: "Relay message.",
        23: "Check in.",
        24: "Going silent.",
        25: "SOS \u{2014} need immediate help.",
        26: "Camp established.",
        27: "Trail blocked \u{2014} rerouting.",
        28: "Water source found.",
        29: "Shelter located.",
        30: "Search area clear \u{2014} no findings.",
    ]

    public static let `default` = CannedCodebook(defaultEntries)

    private let forward: [Int: String]
    private let reverse: [String: Int]

    public init(_ entries: [Int: String]) {
        forward = entries
        var rev: [String: Int] = [:]
        for (id, text) in entries { rev[text] = id }
        reverse = rev
    }

    public enum CodecError: Error, Equatable { case tooShort, badHeader, unknownId(Int) }

    /// The text of a 2-byte frame.
    public func decode(_ data: [UInt8]) throws -> String {
        guard data.count >= 2 else { throw CodecError.tooShort }
        guard data[0] == Self.headerCanned else { throw CodecError.badHeader }
        let id = Int(data[1])
        guard let text = forward[id] else { throw CodecError.unknownId(id) }
        return text
    }

    public func lookupByText(_ text: String) -> Int? { reverse[text] }

    public static func encode(_ id: Int) -> [UInt8] { [headerCanned, UInt8(truncatingIfNeeded: id)] }
    public static func decodeDefault(_ data: [UInt8]) throws -> String { try `default`.decode(data) }
    public static func isCanned(_ data: [UInt8]) -> Bool { data.first == headerCanned }
    public static func lookupByTextDefault(_ text: String) -> Int? { `default`.lookupByText(text) }
}
