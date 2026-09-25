// Mirrors engine/BurstQueue.kt (a port of the Bridge's internal/engine/burst.go): messages
// queued for one satellite session, packed into an SBD-sized TLV frame.
//
//   [1B type=0x42] [2B count uint16 LE], then per message [2B payload_len uint16 LE] [payload]
import Foundation

public struct BurstMessage: Sendable, Equatable {
    public var payload: [UInt8]
    public var priority: Int
    /// Milliseconds since the epoch.
    public var queuedAt: Int64
    public var interfaceId: String
    public init(payload: [UInt8], priority: Int = 0, queuedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000), interfaceId: String = "")
    {
        self.payload = payload
        self.priority = priority
        self.queuedAt = queuedAt
        self.interfaceId = interfaceId
    }
}

public enum BurstError: Error, Equatable, Sendable {
    case emptyPayload
    case payloadTooLarge(Int, max: Int)
    case tooShort(Int)
    case wrongType(UInt8)
    case truncated(message: Int, offset: Int)
}

public final class BurstQueue: @unchecked Sendable {
    public static let burstTypeByte: UInt8 = 0x42
    /// The largest SBD payload.
    public static let iridiumMTU = 340
    /// 1 byte type, 2 bytes count.
    public static let burstHeaderLen = 3
    /// 2 bytes payload length.
    public static let burstMsgHeaderLen = 2
    public static var maxPayload: Int { iridiumMTU - burstHeaderLen - burstMsgHeaderLen }

    public let maxSize: Int
    public let maxAgeMs: Int64
    private let now: @Sendable () -> Int64
    private let lock = NSLock()
    private var pendingMessages: [BurstMessage] = []

    public init(maxSize: Int, maxAgeMs: Int64, now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.maxSize = maxSize
        self.maxAgeMs = maxAgeMs
        self.now = now
    }

    public func enqueue(_ msg: BurstMessage) throws {
        guard !msg.payload.isEmpty else { throw BurstError.emptyPayload }
        guard msg.payload.count <= Self.maxPayload else { throw BurstError.payloadTooLarge(msg.payload.count, max: Self.maxPayload) }
        lock.lock()
        pendingMessages.append(msg)
        lock.unlock()
    }

    /// Everything that fits, highest priority first, as one frame; what does not fit stays.
    /// Nil and 0 when nothing waits.
    public func flush() -> (payload: [UInt8]?, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard !pendingMessages.isEmpty else { return (nil, 0) }
        // A stable sort keeps arrival order within a priority, as Kotlin's sortByDescending does.
        pendingMessages = pendingMessages.enumerated().sorted { a, b in
            a.element.priority != b.element.priority ? a.element.priority > b.element.priority : a.offset < b.offset
        }.map(\.element)
        let (payload, count) = Self.packBurst(pendingMessages, mtu: Self.iridiumMTU)
        pendingMessages.removeFirst(min(count, pendingMessages.count))
        return (payload, count)
    }

    public func pending() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingMessages.count
    }

    /// True once the queue is full or its oldest message is older than maxAge.
    public func shouldFlush() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !pendingMessages.isEmpty else { return false }
        if pendingMessages.count >= maxSize { return true }
        let oldest = pendingMessages.map(\.queuedAt).min() ?? now()
        return now() - oldest >= maxAgeMs
    }

    /// The frame and how many messages it holds.
    public static func packBurst(_ msgs: [BurstMessage], mtu: Int) -> (payload: [UInt8], count: Int) {
        var buf: [UInt8] = [burstTypeByte, 0, 0]
        var count = 0
        for msg in msgs {
            let needed = burstMsgHeaderLen + msg.payload.count
            if buf.count + needed > mtu { break }
            buf.append(UInt8(msg.payload.count & 0xFF))
            buf.append(UInt8((msg.payload.count >> 8) & 0xFF))
            buf += msg.payload
            count += 1
        }
        buf[1] = UInt8(count & 0xFF)
        buf[2] = UInt8((count >> 8) & 0xFF)
        return (buf, count)
    }

    /// The payloads of a frame.
    public static func unpackBurst(_ data: [UInt8]) throws -> [[UInt8]] {
        guard data.count >= burstHeaderLen else { throw BurstError.tooShort(data.count) }
        guard data[0] == burstTypeByte else { throw BurstError.wrongType(data[0]) }
        let count = Int(data[1]) | (Int(data[2]) << 8)
        var offset = burstHeaderLen
        var payloads: [[UInt8]] = []
        for i in 0..<count {
            guard data.count - offset >= burstMsgHeaderLen else { throw BurstError.truncated(message: i, offset: offset) }
            let len = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += burstMsgHeaderLen
            guard data.count - offset >= len else { throw BurstError.truncated(message: i, offset: offset) }
            payloads.append(Array(data[offset..<(offset + len)]))
            offset += len
        }
        return payloads
    }
}
