// Mirrors rns/Wire.kt (class Header): a parsed packet header plus its data (RNS/Packet.py, the
// Bridge's internal/reticulum/packet.go). Every packet carries a context byte; the context FLAG
// (bit 5) is a separate signal, used by announces to say a ratchet is present.
import Foundation

public struct Header: Sendable, Equatable {
    public var headerType: Int
    public var contextFlag: Int
    public var transportType: Int
    public var destType: Int
    public var packetType: Int
    public var hops: Int
    public var transportId: [UInt8]?
    public var destHash: [UInt8]
    public var context: Int
    public var data: [UInt8]

    public init(
        headerType: Int = Rns.header1, contextFlag: Int = 0, transportType: Int = Rns.transportBroadcast,
        destType: Int = Rns.destSingle, packetType: Int = Rns.packetData, hops: Int = 0, transportId: [UInt8]? = nil,
        destHash: [UInt8], context: Int = Rns.ctxNone, data: [UInt8] = []
    ) {
        self.headerType = headerType
        self.contextFlag = contextFlag
        self.transportType = transportType
        self.destType = destType
        self.packetType = packetType
        self.hops = hops
        self.transportId = transportId
        self.destHash = destHash
        self.context = context
        self.data = data
    }

    /// [7:IFAC][6:header type][5:context flag][4:transport type][3..2:dest type][1..0:packet type]; IFAC is the interface's.
    public func flags() -> Int {
        ((headerType & 1) << 6) | ((contextFlag & 1) << 5) | ((transportType & 1) << 4) | ((destType & 3) << 2) | (packetType & 3)
    }

    public func headerSize() -> Int { headerType == Rns.header2 ? Rns.headerMaxSize : Rns.headerMinSize }

    public func pack() throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(headerSize() + data.count)
        out.append(UInt8(flags() & 0xFF))
        out.append(UInt8(hops & 0xFF))
        if headerType == Rns.header2 {
            guard let tid = transportId, tid.count == Rns.hashLen else { throw WireError("HEADER_2 packet needs a 16-byte transport id") }
            out += tid
        }
        guard destHash.count == Rns.hashLen else { throw WireError("destination hash must be 16 bytes") }
        out += destHash
        out.append(UInt8(context & 0xFF))
        out += data
        return out
    }

    /// Parses a raw packet. Like RNS Packet.unpack it rejects a hop count at or above
    /// PATHFINDER_M and an empty data field (a peer drops those too).
    public static func unpack(_ raw: [UInt8]) throws -> Header {
        guard raw.count >= Rns.headerMinSize else { throw WireError("packet too short: \(raw.count)") }
        let flags = Int(raw[0])
        var h = Header(
            headerType: (flags & 0x40) >> 6, contextFlag: (flags & 0x20) >> 5, transportType: (flags & 0x10) >> 4,
            destType: (flags & 0x0C) >> 2, packetType: flags & 0x03, hops: Int(raw[1]), destHash: [])
        if h.hops >= Rns.pathfinderM { throw WireError("hops \(h.hops) at or above PATHFINDER_M") }
        var pos = 2
        if h.headerType == Rns.header2 {
            guard raw.count >= Rns.headerMaxSize else { throw WireError("HEADER_2 packet too short: \(raw.count)") }
            h.transportId = Array(raw[pos..<pos + Rns.hashLen])
            pos += Rns.hashLen
        }
        h.destHash = Array(raw[pos..<pos + Rns.hashLen])
        pos += Rns.hashLen
        h.context = Int(raw[pos])
        pos += 1
        guard pos < raw.count else { throw WireError("zero-length data field") }
        h.data = Array(raw[pos...])
        return h
    }

    public static func unpackOrNil(_ raw: [UInt8]) -> Header? { try? unpack(raw) }

    /// The bytes RNS hashes: flags masked to dest type and packet type, then everything after
    /// the hops byte, skipping a HEADER_2 transport id. The hash so survives the HEADER_1 <->
    /// HEADER_2 rewrite in transport, which is what makes proofs and reverse tables work across
    /// hops (Packet.get_hashable_part).
    public static func hashablePart(_ raw: [UInt8]) -> [UInt8] {
        guard raw.count >= 2 else { return [] }
        let start = (raw[0] & 0x40) != 0 ? 2 + Rns.hashLen : 2
        guard raw.count >= start else { return [] }
        return [raw[0] & 0x0F] + raw[start...]
    }

    public static func packetHash(_ raw: [UInt8]) -> [UInt8] { Rns.sha256(hashablePart(raw)) }

    public static func truncatedPacketHash(_ raw: [UInt8]) -> [UInt8] { Array(packetHash(raw).prefix(Rns.hashLen)) }

    /// Converts a packet to the HEADER_2 form a transport node emits: header type 2, transport
    /// type TRANSPORT, the next hop's transport id after the hops byte. The hops byte is left
    /// alone; callers set it.
    public static func rewriteForTransport(_ raw: [UInt8], transportId: [UInt8]) -> [UInt8] {
        guard raw.count >= Rns.headerMinSize, transportId.count == Rns.hashLen else { return raw }
        let f = raw[0]
        if (f & 0x40) != 0 {
            var out = raw
            out.replaceSubrange(2..<2 + Rns.hashLen, with: transportId)
            out[0] = f | 0x10
            return out
        }
        var out = [UInt8]()
        out.reserveCapacity(raw.count + Rns.hashLen)
        out.append((f & 0x0F) | UInt8(Rns.header2 << 6) | UInt8(Rns.transportTransport << 4) | (f & 0x20))
        out.append(raw[1])
        out += transportId
        out += raw[2...]
        return out
    }

    /// The reverse: HEADER_2 back to HEADER_1 broadcast, as a transport does on the last hop.
    public static func stripTransport(_ raw: [UInt8]) -> [UInt8] {
        guard raw.count >= Rns.headerMaxSize, (raw[0] & 0x40) != 0 else { return raw }
        var out = [UInt8]()
        out.reserveCapacity(raw.count - Rns.hashLen)
        out.append((raw[0] & 0x0F) | (raw[0] & 0x20))
        out.append(raw[1])
        out += raw[(2 + Rns.hashLen)...]
        return out
    }
}
