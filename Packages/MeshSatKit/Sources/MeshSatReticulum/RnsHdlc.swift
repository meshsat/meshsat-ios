// Mirrors the HDLC framing of reticulum/RnsTcpInterface.kt, used by the TCP, Tor and WireGuard
// interfaces and wire-compatible with the Python RNS TCPClientInterface:
//   [0x7E] [escaped payload] [0x7E], escaping 0x7D as 0x7D 0x5D and 0x7E as 0x7D 0x5E.
import Foundation

public enum RnsHdlc {
    public static let flag: UInt8 = 0x7E
    public static let esc: UInt8 = 0x7D
    public static let escMask: UInt8 = 0x20
    /// Minimum valid RNS packet size (2 header bytes + 1 hop + 16 dest hash).
    public static let headerMinSize = 19

    /// HDLC-escape a raw packet for transmission.
    public static func escape(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(data.count + 8)
        for b in data {
            switch b {
            case esc, flag:
                out.append(esc)
                out.append(b ^ escMask)
            default:
                out.append(b)
            }
        }
        return out
    }

    /// Reverse `escape`.
    public static func unescape(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        var i = 0
        while i < data.count {
            if data[i] == esc, i + 1 < data.count {
                out.append(data[i + 1] ^ escMask)
                i += 2
            } else {
                out.append(data[i])
                i += 1
            }
        }
        return out
    }

    /// One framed packet: flag, escaped payload, flag.
    public static func frame(_ packet: [UInt8]) -> [UInt8] { [flag] + escape(packet) + [flag] }

    /// The receive side of the read loop: feed bytes as they arrive, get complete unescaped
    /// frames of at least `headerMinSize` bytes back.
    public struct Deframer: Sendable {
        private var frame: [UInt8] = []
        private var inFrame = false
        public init() {}

        public mutating func feed(_ bytes: [UInt8]) -> [[UInt8]] {
            var out: [[UInt8]] = []
            for b in bytes {
                if b == flag {
                    if inFrame, !frame.isEmpty {
                        let unescaped = unescape(frame)
                        frame.removeAll(keepingCapacity: true)
                        if unescaped.count >= headerMinSize { out.append(unescaped) }
                    } else {
                        frame.removeAll(keepingCapacity: true)
                    }
                    inFrame = true
                } else if inFrame {
                    frame.append(b)
                }
            }
            return out
        }
    }
}
