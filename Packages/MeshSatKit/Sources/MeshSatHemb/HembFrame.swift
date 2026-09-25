// Mirrors hemb/HembFrame.kt: the HeMB frame header, compact (8 B) and extended (16 B), wire
// compatible with the Bridge's internal/hemb/frame.go (the only implementation in the field,
// so the reference, MESHSAT-1264). The CRC-8 is ITU-T polynomial 0x07, not GF(256).
import Foundation

/// One linear combination of K source segments (hemb/HembRlnc.kt's HembCodedSymbol).
public struct HembCodedSymbol: Sendable, Equatable {
    public var genId: Int
    public var symbolIndex: Int
    public var k: Int
    /// K GF(256) coefficients.
    public var coefficients: [UInt8]
    /// The coded payload.
    public var data: [UInt8]
    public init(genId: Int, symbolIndex: Int, k: Int, coefficients: [UInt8], data: [UInt8]) {
        self.genId = genId
        self.symbolIndex = symbolIndex
        self.k = k
        self.coefficients = coefficients
        self.data = data
    }
}

public enum HembFrame {
    public static let extendedHeaderLen = 16
    public static let compactHeaderLen = 8
    public static let magic0: UInt8 = 0x48  // 'H'
    public static let magic1: UInt8 = 0x4D  // 'M'
    public static let headerModeCompact = "compact"
    public static let headerModeExtended = "extended"
    public static let headerModeImplicit = "implicit"
    public static let flagData = 0x00
    public static let flagRepair = 0x01
    public static let flagAck = 0x02
    public static let flagCtrl = 0x03

    public struct ParsedSymbol: Sendable, Equatable {
        public var streamId: Int
        public var bearerIndex: Int
        public var symbol: HembCodedSymbol
        public var n: Int
        public var flags = HembFrame.flagData
        public var headerMode = HembFrame.headerModeExtended
        /// Hops left; only the compact header carries one.
        public var ttl = 0
    }

    /// CRC-8, ITU-T polynomial 0x07 (not GF(256): a separate algorithm).
    public static func crc8(_ data: [UInt8], offset: Int = 0, length: Int? = nil) -> UInt8 {
        var crc: UInt8 = 0
        let end = offset + (length ?? (data.count - offset))
        for i in offset..<end {
            crc ^= data[i]
            for _ in 0..<8 { crc = (crc & 0x80) != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
        }
        return crc
    }

    /// True when the data starts with a valid HeMB frame header.
    public static func isHembFrame(_ data: [UInt8]) -> Bool {
        if data.count >= extendedHeaderLen, data[0] == magic0, data[1] == magic1 {
            return crc8(data, offset: 0, length: 15) == data[15]
        }
        if data.count >= compactHeaderLen {
            return crc8(data, offset: 0, length: 7) == data[7]
        }
        return false
    }

    /// Header overhead in bytes for a mode.
    public static func headerOverhead(_ mode: String) -> Int {
        switch mode {
        case headerModeCompact: return compactHeaderLen
        case headerModeExtended: return extendedHeaderLen
        case headerModeImplicit: return 0
        default: return extendedHeaderLen
        }
    }

    /// An extended header and the coded symbol as one frame.
    public static func marshalExtended(streamId: Int, sym: HembCodedSymbol, bearerIndex: Int, totalN: Int, flags: Int = flagData) -> [UInt8]
    {
        let k = sym.k
        var arr = [UInt8](repeating: 0, count: extendedHeaderLen)
        arr[0] = magic0
        arr[1] = magic1
        // Byte 2: version (2 bits), stream id low nibble, flags (2 bits).
        arr[2] = UInt8(((streamId & 0x0F) << 2) | (flags & 0x03))
        // Byte 3: the whole stream id.
        arr[3] = UInt8(streamId & 0xFF)
        // Bytes 4-5: sequence, little endian (the symbol index).
        arr[4] = UInt8(sym.symbolIndex & 0xFF)
        arr[5] = UInt8((sym.symbolIndex >> 8) & 0xFF)
        arr[6] = UInt8(k & 0xFF)
        arr[7] = UInt8(totalN & 0xFF)
        arr[8] = UInt8(bearerIndex & 0xFF)
        // Bytes 9-10: generation id, little endian.
        arr[9] = UInt8(sym.genId & 0xFF)
        arr[10] = UInt8((sym.genId >> 8) & 0xFF)
        // Bytes 11-12 total payload size, 13 TTL, 14 extended flags: zero.
        arr[15] = crc8(arr, offset: 0, length: 15)
        return arr + sym.coefficients.prefix(k) + sym.data
    }

    /// A compact header and the coded symbol as one frame, byte for byte the Bridge's MarshalCompact.
    public static func marshalCompact(
        streamId: Int, sym: HembCodedSymbol, bearerIndex: Int, totalN: Int, flags: Int = flagData, ttl: Int = 0
    )
        -> [UInt8]
    {
        let k = sym.k
        var arr = [UInt8](repeating: 0, count: compactHeaderLen)
        // Byte 0: version (2 bits), stream id (4 bits), flags (2 bits).
        arr[0] = UInt8(((streamId & 0x0F) << 2) | (flags & 0x03))
        // Byte 1: sequence bits 7:0.
        arr[1] = UInt8(sym.symbolIndex & 0xFF)
        arr[2] = UInt8(k & 0xFF)
        arr[3] = UInt8(totalN & 0xFF)
        // Byte 4: bearer index (4 bits), sequence bits 11:8.
        arr[4] = UInt8(((bearerIndex & 0x0F) << 4) | ((sym.symbolIndex >> 8) & 0x0F))
        // Byte 5: generation id bits 7:0.
        arr[5] = UInt8(sym.genId & 0xFF)
        // Byte 6: generation id bits 9:8 (2 bits), TTL (6 bits).
        arr[6] = UInt8((((sym.genId >> 8) & 0x03) << 6) | (ttl & 0x3F))
        arr[7] = crc8(arr, offset: 0, length: 7)
        return arr + sym.coefficients.prefix(k) + sym.data
    }

    /// The frame's fields, or nil when it is not a valid frame.
    public static func parseSymbol(_ data: [UInt8]) -> ParsedSymbol? {
        if data.count >= extendedHeaderLen, data[0] == magic0, data[1] == magic1 {
            guard crc8(data, offset: 0, length: 15) == data[15] else { return nil }
            let flags = Int(data[2] & 0x03)
            // Byte 3 holds the whole stream id; byte 2 repeats its low nibble for the compact
            // header's benefit (MESHSAT-1163: combining the two read 85 for stream 5).
            let streamId = Int(data[3])
            let sequence = Int(data[4]) | (Int(data[5]) << 8)
            let k = Int(data[6])
            let n = Int(data[7])
            let bearerIdx = Int(data[8])
            let genId = Int(data[9]) | (Int(data[10]) << 8)
            let coeffEnd = extendedHeaderLen + k
            guard data.count >= coeffEnd + 1 else { return nil }
            return ParsedSymbol(
                streamId: streamId, bearerIndex: bearerIdx,
                symbol: HembCodedSymbol(
                    genId: genId, symbolIndex: sequence, k: k, coefficients: Array(data[extendedHeaderLen..<coeffEnd]),
                    data: Array(data[coeffEnd...])),
                n: n, flags: flags, headerMode: headerModeExtended)
        }
        if data.count >= compactHeaderLen {
            guard crc8(data, offset: 0, length: 7) == data[7] else { return nil }
            // The Bridge's UnmarshalCompact, bit for bit (MESHSAT-1264).
            let flags = Int(data[0] & 0x03)
            let streamId = (Int(data[0]) >> 2) & 0x0F
            let k = Int(data[2])
            let n = Int(data[3])
            let bearerIdx = (Int(data[4]) >> 4) & 0x0F
            let sequence = Int(data[1]) | ((Int(data[4]) & 0x0F) << 8)
            let genId = Int(data[5]) | (((Int(data[6]) >> 6) & 0x03) << 8)
            let ttl = Int(data[6]) & 0x3F
            let coeffEnd = compactHeaderLen + k
            guard data.count >= coeffEnd + 1 else { return nil }
            return ParsedSymbol(
                streamId: streamId, bearerIndex: bearerIdx,
                symbol: HembCodedSymbol(
                    genId: genId, symbolIndex: sequence, k: k, coefficients: Array(data[compactHeaderLen..<coeffEnd]),
                    data: Array(data[coeffEnd...])),
                n: n, flags: flags, headerMode: headerModeCompact, ttl: ttl)
        }
        return nil
    }

    /// A compact frame as an extended one, for relay and DTN; an extended frame unchanged.
    public static func promoteHeader(_ compactFrame: [UInt8]) -> [UInt8]? {
        guard let parsed = parseSymbol(compactFrame) else { return nil }
        if parsed.headerMode == headerModeExtended { return compactFrame }
        return marshalExtended(
            streamId: parsed.streamId, sym: parsed.symbol, bearerIndex: parsed.bearerIndex, totalN: parsed.n, flags: parsed.flags)
    }
}
