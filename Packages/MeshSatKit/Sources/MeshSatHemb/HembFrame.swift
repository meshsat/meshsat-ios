// Mirrors hemb/HembFrame.kt: the HeMB frame header, compact (8 B) and extended (16 B), wire
// compatible with the Bridge's internal/hemb/frame.go. This file holds the constants, the
// CRC-8 and the frame detector the Reticulum transport node needs; marshal and parse land
// with the HeMB port (MESHSAT-1319 phase 1, hemb/).
import Foundation

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
}
