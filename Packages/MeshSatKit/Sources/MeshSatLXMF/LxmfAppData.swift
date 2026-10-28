// Mirrors lxmf/LxmfAppData.kt (the Bridge's internal/lxmf/appdata.go): the lxmf.delivery
// announce app data (LXMRouter.get_announce_app_data and the display_name / stamp_cost /
// compression_support_from_app_data readers):
//   msgpack([display name | nil, stamp cost | nil, [supported functionality]]).
import Foundation
import MeshSatRns

public enum LxmfAppData {
    /// LXMF.SF_COMPRESSION: the peer accepts bzip2-compressed resources. The phone does not
    /// announce it (no bzip2 here, as on Android); the Bridge does.
    public static let sfCompression: Int64 = 0

    public static func encode(displayName: String?, stampCost: Int, compression: Bool = false) -> [UInt8] {
        let name: MpValue = (displayName ?? "").isEmpty ? .null : .bin(Array((displayName ?? "").utf8))
        let cost: MpValue = (1...254).contains(stampCost) ? .int(Int64(stampCost)) : .null
        let sf: MpValue = compression ? .array([.int(sfCompression)]) : .array([])
        return Msgpack.pack(.array([name, cost, sf]))
    }

    /// What a peer's announce app data says.
    public struct Info: Sendable, Equatable {
        public let displayName: String?
        /// 0 = none.
        public let stampCost: Int
        /// The peer accepts compressed resources.
        public let compression: Bool
        /// Pre-0.5.0 raw UTF-8 name.
        public let legacy: Bool

        public init(displayName: String? = nil, stampCost: Int = 0, compression: Bool = true, legacy: Bool = false) {
            self.displayName = displayName
            self.stampCost = stampCost
            self.compression = compression
            self.legacy = legacy
        }
    }

    public static func parse(_ appData: [UInt8]?) -> Info {
        guard let appData, !appData.isEmpty else { return Info() }
        let b0 = appData[0]
        guard (0x90...0x9F).contains(b0) || b0 == 0xDC else {
            return Info(displayName: String(decoding: appData, as: UTF8.self), stampCost: 0, compression: true, legacy: true)
        }
        guard let items = (try? Msgpack.unpack(appData))?.value.asArray else { return Info() }
        var name: String?
        if let first = items.first {
            switch first {
            case .bin(let b): name = String(decoding: b, as: UTF8.self)
            case .str(let s): name = s
            default: name = nil
            }
            name = name?.replacingOccurrences(of: "\u{0}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if name?.isEmpty == true { name = nil }
        }
        var cost = 0
        if items.count > 1, let c = items[1].asInt, (1...254).contains(c) { cost = Int(c) }
        var compression = true
        if items.count > 2, let sf = items[2].asArray { compression = sf.contains { $0.asInt == sfCompression } }
        return Info(displayName: name, stampCost: cost, compression: compression, legacy: false)
    }
}
