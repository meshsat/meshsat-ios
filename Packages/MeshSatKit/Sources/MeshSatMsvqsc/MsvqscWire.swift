// Mirrors crypto/MsvqscWire.kt: the MSVQ-SC frame, [1B: stages high nibble, version low
// nibble] then one uint16 LE codebook index per stage; base64 when it rides an SMS.
import Foundation
import MeshSatWire

public enum MsvqscWire {
    public static let version = 1
    static let headerSize = 1
    static let indexSize = 2

    public enum WireError: Error, Equatable {
        case tooShort(need: Int, got: Int)
        case unsupportedVersion(Int)
    }

    public struct Unpacked: Sendable, Equatable {
        public let indices: [Int]
        public let stages: Int
        public let version: Int
    }

    public static func pack(_ indices: [Int]) -> [UInt8] {
        let stages = indices.count
        var buf: [UInt8] = [UInt8(((stages & 0x0F) << 4) | (version & 0x0F))]
        for idx in indices {
            buf.append(UInt8(idx & 0xFF))
            buf.append(UInt8((idx >> 8) & 0xFF))
        }
        return buf
    }

    public static func unpack(_ data: [UInt8]) throws -> Unpacked {
        guard data.count >= headerSize else { throw WireError.tooShort(need: headerSize, got: data.count) }
        let header = Int(data[0])
        let stages = (header >> 4) & 0x0F
        let ver = header & 0x0F
        guard ver == version else { throw WireError.unsupportedVersion(ver) }
        let expected = headerSize + stages * indexSize
        guard data.count >= expected else { throw WireError.tooShort(need: expected, got: data.count) }
        var indices: [Int] = []
        for s in 0..<stages {
            let offset = headerSize + s * indexSize
            indices.append(Int(data[offset]) | (Int(data[offset + 1]) << 8))
        }
        return Unpacked(indices: indices, stages: stages, version: ver)
    }

    public static func toBase64(_ wire: [UInt8]) -> String { Base64Std.encode(wire) }
    public static func fromBase64(_ text: String) -> [UInt8]? { Base64Std.decode(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    public static func wireSize(stages: Int) -> Int { headerSize + stages * indexSize }

    /// Version 1, 1 to 8 stages, and exactly the length that says.
    public static func looksLikeMsvqsc(_ data: [UInt8]) -> Bool {
        guard let first = data.first else { return false }
        let stages = (Int(first) >> 4) & 0x0F
        let ver = Int(first) & 0x0F
        guard ver == version, (1...8).contains(stages) else { return false }
        return data.count == headerSize + stages * indexSize
    }
}
