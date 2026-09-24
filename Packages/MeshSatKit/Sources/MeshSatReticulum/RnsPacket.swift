// Mirrors reticulum/RnsPacket.kt: the Reticulum wire-compatible packet header and framing.
//
// HEADER_1 layout (19+ bytes): flags(1) hops(1) dest_hash(16) [context(1)] data
// HEADER_2 layout (35+ bytes): flags(1) hops(1) transport_id(16) dest_hash(16) [context(1)] data
import Foundation

public struct RnsPacket: Sendable, Equatable {
    public var headerType: Int  // HEADER_1 or HEADER_2
    public var packetType: Int  // DATA, ANNOUNCE, LINKREQUEST, PROOF
    public var destType: Int  // SINGLE, GROUP, PLAIN, LINK
    public var propagationType: Int  // BROADCAST or TRANSPORT
    public var contextFlag: Bool  // whether the context byte is present
    public var hops: Int  // hop count (0 to 255)
    public var transportId: [UInt8]?  // 16 bytes, only for HEADER_2
    public var destHash: [UInt8]  // 16 bytes
    public var context: UInt8  // context byte (CTX_* constant)
    public var data: [UInt8]  // payload

    public init(
        headerType: Int, packetType: Int, destType: Int, propagationType: Int, contextFlag: Bool, hops: Int,
        transportId: [UInt8]?, destHash: [UInt8], context: UInt8, data: [UInt8]
    ) {
        self.headerType = headerType
        self.packetType = packetType
        self.destType = destType
        self.propagationType = propagationType
        self.contextFlag = contextFlag
        self.hops = hops
        self.transportId = transportId
        self.destHash = destHash
        self.context = context
        self.data = data
    }

    /// Decoded flag fields from the first header byte.
    public struct FlagFields: Sendable, Equatable {
        public let headerType: Int
        public let contextFlag: Bool
        public let propagationType: Int
        public let destType: Int
        public let packetType: Int
    }

    public struct FormatError: Error, Equatable, Sendable, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// The flags byte from the header fields.
    public func encodeFlags() -> Int {
        var flags = 0
        flags |= (headerType & 0x03) << 6
        flags |= contextFlag ? 1 << 5 : 0
        flags |= (propagationType & 0x01) << 4
        flags |= (destType & 0x03) << 2
        flags |= packetType & 0x03
        return flags
    }

    public static func decodeFlags(_ flags: Int) -> FlagFields {
        FlagFields(
            headerType: (flags >> 6) & 0x03, contextFlag: (flags >> 5) & 0x01 == 1, propagationType: (flags >> 4) & 0x01,
            destType: (flags >> 2) & 0x03, packetType: flags & 0x03)
    }

    private var addressFieldSize: Int { headerType == RnsConstants.header2 ? RnsConstants.destHashLen * 2 : RnsConstants.destHashLen }

    /// Total wire size of this packet.
    public func wireSize() -> Int { 2 + addressFieldSize + (contextFlag ? 1 : 0) + data.count }

    /// Serialize to wire format.
    public func marshal() -> [UInt8] {
        var buf = [UInt8]()
        buf.reserveCapacity(wireSize())
        buf.append(UInt8(encodeFlags() & 0xFF))
        buf.append(UInt8(hops & 0xFF))
        if headerType == RnsConstants.header2 {
            buf += transportId ?? [UInt8](repeating: 0, count: RnsConstants.destHashLen)
        }
        buf += destHash
        if contextFlag { buf.append(context) }
        buf += data
        return buf
    }

    /// Minimum wire size for unmarshal: flags(1) + hops(1) + dest(16) = 18.
    static let unmarshalMin = 2 + RnsConstants.destHashLen

    /// Parse a packet from wire format.
    public static func unmarshal(_ raw: [UInt8]) throws -> RnsPacket {
        guard raw.count >= unmarshalMin else { throw FormatError("packet too short: \(raw.count) < \(unmarshalMin)") }
        let fields = decodeFlags(Int(raw[0]))
        let hops = Int(raw[1])
        var i = 2
        var transportId: [UInt8]?
        if fields.headerType == RnsConstants.header2 {
            guard raw.count >= RnsConstants.headerMaxSize else {
                throw FormatError("HEADER_2 packet too short: \(raw.count) < \(RnsConstants.headerMaxSize)")
            }
            transportId = Array(raw[i..<i + RnsConstants.destHashLen])
            i += RnsConstants.destHashLen
        }
        let destHash = Array(raw[i..<i + RnsConstants.destHashLen])
        i += RnsConstants.destHashLen
        var context = RnsConstants.ctxNone
        if fields.contextFlag {
            guard i < raw.count else { throw FormatError("missing context byte") }
            context = raw[i]
            i += 1
        }
        return RnsPacket(
            headerType: fields.headerType, packetType: fields.packetType, destType: fields.destType,
            propagationType: fields.propagationType, contextFlag: fields.contextFlag, hops: hops, transportId: transportId,
            destHash: destHash, context: context, data: Array(raw[i...]))
    }

    /// A HEADER_1 data packet.
    public static func data(
        destHash: [UInt8], payload: [UInt8], destType: Int = RnsConstants.destSingle, context: UInt8 = RnsConstants.ctxNone
    ) -> RnsPacket {
        RnsPacket(
            headerType: RnsConstants.header1, packetType: RnsConstants.packetData, destType: destType,
            propagationType: RnsConstants.propagationBroadcast, contextFlag: context != RnsConstants.ctxNone, hops: 0,
            transportId: nil, destHash: destHash, context: context, data: payload)
    }

    /// A HEADER_1 announce packet.
    public static func announce(destHash: [UInt8], announceData: [UInt8]) -> RnsPacket {
        RnsPacket(
            headerType: RnsConstants.header1, packetType: RnsConstants.packetAnnounce, destType: RnsConstants.destSingle,
            propagationType: RnsConstants.propagationBroadcast, contextFlag: false, hops: 0, transportId: nil,
            destHash: destHash, context: RnsConstants.ctxNone, data: announceData)
    }

    /// A HEADER_1 link request packet.
    public static func linkRequest(destHash: [UInt8], requestData: [UInt8]) -> RnsPacket {
        RnsPacket(
            headerType: RnsConstants.header1, packetType: RnsConstants.packetLinkRequest, destType: RnsConstants.destSingle,
            propagationType: RnsConstants.propagationBroadcast, contextFlag: false, hops: 0, transportId: nil,
            destHash: destHash, context: RnsConstants.ctxNone, data: requestData)
    }

    /// A HEADER_1 proof packet.
    public static func proof(destHash: [UInt8], proofData: [UInt8], context: UInt8 = RnsConstants.ctxNone) -> RnsPacket {
        RnsPacket(
            headerType: RnsConstants.header1, packetType: RnsConstants.packetProof, destType: RnsConstants.destSingle,
            propagationType: RnsConstants.propagationBroadcast, contextFlag: context != RnsConstants.ctxNone, hops: 0,
            transportId: nil, destHash: destHash, context: context, data: proofData)
    }

    /// Wrap a HEADER_1 packet for transport (adds transport_id, becomes HEADER_2).
    public static func wrapForTransport(_ packet: RnsPacket, transportId: [UInt8]) -> RnsPacket {
        precondition(transportId.count == RnsConstants.destHashLen, "transport ID must be \(RnsConstants.destHashLen) bytes")
        var p = packet
        p.headerType = RnsConstants.header2
        p.propagationType = RnsConstants.propagationTransport
        p.transportId = transportId
        return p
    }

    /// Validate the packet size against the Reticulum MTU.
    public static func validateSize(_ packet: RnsPacket) -> Bool { packet.wireSize() <= RnsConstants.mtu }
}
