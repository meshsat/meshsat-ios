// Mirrors engine/IridiumFragment.kt: the Iridium SBD 2-byte fragment header and the reassembly
// buffer, compatible with the Bridge's and the Hub's fragment protocol. Byte 0 is
// [index:4 | total-1:4], byte 1 the wrapping message id. The phone never SENDS fragments any
// more (SatelliteLimits, MESHSAT-1280); reassembly of parts coming IN stays, because the Hub
// still sends long messages to a modem that way.
import Foundation

public enum IridiumFragment {
    public static let headerSize = 2
    public static let moMtu = 340
    public static let mtMtu = 270
    public static let maxFragments = 16
    public static let fragPayload = moMtu - headerSize

    public struct Header: Sendable, Equatable {
        public let fragIndex: Int
        public let fragTotal: Int
        public let msgId: Int
        public init(fragIndex: Int, fragTotal: Int, msgId: Int) {
            self.fragIndex = fragIndex
            self.fragTotal = fragTotal
            self.msgId = msgId
        }
    }

    public static func encodeHeader(fragIndex: Int, fragTotal: Int, msgId: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: ((fragIndex & 0x0F) << 4) | ((fragTotal - 1) & 0x0F)), UInt8(truncatingIfNeeded: msgId & 0xFF)]
    }

    public static func decodeHeader(_ b0: UInt8, _ b1: UInt8) -> Header {
        Header(fragIndex: Int(b0 >> 4), fragTotal: Int(b0 & 0x0F) + 1, msgId: Int(b1))
    }

    /// Cut `data` into MTU-sized SBD payloads; nil when it fits one frame. `msgId` is a
    /// wrapping counter (0-255). More than 16 fragments are cut off, as the Bridge does.
    public static func fragment(_ data: [UInt8], mtu: Int = moMtu, msgId: Int) -> [[UInt8]]? {
        if data.count <= mtu { return nil }
        let payload = mtu - headerSize
        if payload <= 0 { return nil }
        var n = (data.count + payload - 1) / payload
        var body = data
        if n > maxFragments {
            n = maxFragments
            body = Array(data[0..<(n * payload)])
        }
        return (0..<n).map { i in
            let start = i * payload
            let end = min(start + payload, body.count)
            return encodeHeader(fragIndex: i, fragTotal: n, msgId: msgId) + body[start..<end]
        }
    }

    public struct FragmentError: Error, Equatable {
        public let reason: String
    }

    /// Thread-safe reassembly of incoming fragmented messages, keyed by message id.
    public final class ReassemblyBuffer: @unchecked Sendable {
        private struct Pending {
            var fragments: [[UInt8]?]
            let total: Int
            var received = 0
            let createdAt: Int64
        }

        private let lock = NSLock()
        private let maxAgeMs: Int64
        private let now: @Sendable () -> Int64
        private var pending: [Int: Pending] = [:]

        public init(maxAgeMs: Int64 = 5 * 60 * 1000, now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) })
        {
            self.maxAgeMs = maxAgeMs
            self.now = now
        }

        /// Add a fragment (header included). The whole message once every part is in, else nil.
        public func addFragment(_ data: [UInt8]) throws -> [UInt8]? {
            guard data.count >= headerSize else { throw FragmentError(reason: "fragment too short: \(data.count) bytes") }
            let h = decodeHeader(data[0], data[1])
            let payload = Array(data[headerSize...])
            lock.lock()
            defer { lock.unlock() }
            var pm = pending[h.msgId] ?? Pending(fragments: Array(repeating: nil, count: h.fragTotal), total: h.fragTotal, createdAt: now())
            guard h.fragIndex < pm.total else { throw FragmentError(reason: "fragment index \(h.fragIndex) >= total \(pm.total)") }
            if pm.fragments[h.fragIndex] == nil { pm.received += 1 }
            pm.fragments[h.fragIndex] = payload
            if pm.received < pm.total {
                pending[h.msgId] = pm
                return nil
            }
            pending[h.msgId] = nil
            return pm.fragments.flatMap { $0 ?? [] }
        }

        /// Drop reassemblies older than `maxAgeMs`; returns how many.
        @discardableResult
        public func expire() -> Int {
            let cutoff = now() - maxAgeMs
            lock.lock()
            defer { lock.unlock() }
            let old = pending.filter { $0.value.createdAt < cutoff }.map(\.key)
            for k in old { pending[k] = nil }
            return old.count
        }

        public var pendingCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return pending.count
        }
    }
}
