// Mirrors rnode/Kiss.kt (MESHSAT-1553 P4, here MESHSAT-1735): KISS framing as RNode speaks it
// (TNC-2), FEND-delimited frames whose first byte is a command, FESC escaping inside. A port of
// the Bridge's internal/kiss.
import Foundation

public enum Kiss {
    public static let fend: UInt8 = 0xC0
    public static let fesc: UInt8 = 0xDB
    public static let tfend: UInt8 = 0xDC
    public static let tfesc: UInt8 = 0xDD
    public static let cmdData: UInt8 = 0x00

    public static func escape(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count + data.count / 16 + 4)
        for b in data {
            switch b {
            case fesc: out += [fesc, tfesc]
            case fend: out += [fesc, tfend]
            default: out.append(b)
            }
        }
        return out
    }

    /// Reverses `escape`; an invalid escape pair keeps the escaped byte.
    public static func unescape(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var esc = false
        for v in data {
            if esc {
                switch v {
                case tfend: out.append(fend)
                case tfesc: out.append(fesc)
                default: out.append(v)
                }
                esc = false
                continue
            }
            if v == fesc {
                esc = true
                continue
            }
            out.append(v)
        }
        return out
    }

    /// One frame: FEND cmd escaped(payload) FEND.
    public static func encode(_ cmd: UInt8, _ payload: [UInt8] = []) -> [UInt8] { [fend, cmd] + escape(payload) + [fend] }

    public struct Frame: Sendable, Equatable {
        public let cmd: UInt8
        public let payload: [UInt8]
    }

    /// Turns a byte stream into frames. `feed` returns every complete frame so far; a partial frame
    /// older than `timeoutMs` is dropped (RNode's device read timeout), and one longer than `maxLen`
    /// is discarded. Not thread safe: the driver calls it under its lock.
    public final class Splitter {
        private let maxLen: Int
        private let timeoutMs: Int64
        private var buf: [UInt8] = []
        private var inFrame = false
        private var lastByteMs: Int64 = 0

        public init(maxLen: Int = 0, timeoutMs: Int64 = 0) {
            self.maxLen = maxLen
            self.timeoutMs = timeoutMs
        }

        public func feed(_ data: [UInt8], nowMs: Int64) -> [Frame] {
            if timeoutMs > 0, inFrame, !buf.isEmpty, nowMs - lastByteMs > timeoutMs {
                buf.removeAll()
                inFrame = false
            }
            if !data.isEmpty { lastByteMs = nowMs }
            var frames: [Frame] = []
            for v in data {
                if v == Kiss.fend {
                    if inFrame, let cmd = buf.first { frames.append(Frame(cmd: cmd, payload: Kiss.unescape(Array(buf.dropFirst())))) }
                    buf.removeAll()
                    inFrame = true
                    continue
                }
                guard inFrame else { continue }
                if maxLen > 0, buf.count > maxLen {
                    buf.removeAll()
                    inFrame = false
                    continue
                }
                buf.append(v)
            }
            return frames
        }

        public func reset() {
            buf.removeAll()
            inFrame = false
        }
    }
}
