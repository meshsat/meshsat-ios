// Mirrors codec/ProtocolVersion.kt: the optional version byte in front of MeshSat-originated
// payloads. 0x01 is protocol v1 (SMAZ2/MSVQ-SC, AES-256-GCM, 2-byte fragments); 0x50, 0x44
// and 0xCA are magic bytes of known payload types, not versions; anything else is legacy.
// Optional and backwards compatible: devices without it work unchanged.
public enum ProtocolVersion {
    public static let protoVersion1: UInt8 = 0x01
    static let magicGpsBridgeFull: UInt8 = 0x50
    static let magicGpsBridgeDelta: UInt8 = 0x44
    static let magicCannedMessage: UInt8 = 0xCA

    /// `version` is 0 for a legacy payload (no version byte); `data` has the byte removed.
    public struct VersionResult: Sendable, Equatable {
        public let version: UInt8
        public let data: [UInt8]
        public init(version: UInt8, data: [UInt8]) {
            self.version = version
            self.data = data
        }
    }

    public static func stripVersionByte(_ payload: [UInt8]) -> VersionResult {
        guard let first = payload.first else { return VersionResult(version: 0, data: payload) }
        if first == magicGpsBridgeFull || first == magicGpsBridgeDelta || first == magicCannedMessage {
            return VersionResult(version: 0, data: payload)
        }
        if first == protoVersion1 { return VersionResult(version: first, data: Array(payload.dropFirst())) }
        return VersionResult(version: 0, data: payload)
    }

    public static func prependVersionByte(_ payload: [UInt8]) -> [UInt8] {
        [protoVersion1] + payload
    }
}
