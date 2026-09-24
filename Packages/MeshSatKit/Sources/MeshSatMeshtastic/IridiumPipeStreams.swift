// Mirrors ble/IridiumPipeStreams.kt: the byte-stream half of the node's BLE Iridium pipe
// (MESHSAT-1236), free of platform types so it runs in the Linux tests. The contract is the
// node firmware's: raw bytes both ways, no framing.
import Foundation

/// Why a write to the pipe did not happen. Telling the two apart is what keeps a handover from
/// dropping the BLE connection (MESHSAT-1270).
public enum PipeError: Error, Equatable, Sendable {
    /// The node holds its own modem and discards what this phone writes. A normal state during a
    /// handover, nothing to do with the health of the link.
    case notOwned
    /// The write itself did not get through to the node. Counted towards a broken link.
    case writeFailed
}

/// The link the 9603 driver talks over: Android's ModemLink. The BLE pipe implements it on the
/// phone; a scripted fake does in the tests. `setReceiver` delivers every notification
/// synchronously, so what the modem says lands in the driver's buffer before the call returns.
public protocol ModemLink: AnyObject, Sendable {
    func write(_ bytes: [UInt8]) async throws
    func setReceiver(_ receiver: (@Sendable ([UInt8]) -> Void)?)
}

/// Bytes the node notified on TX, read by the AT driver. `offer` is called from the GATT
/// callback and never blocks; when the buffer is full the excess is dropped and counted, because
/// a stalled reader must not stall the Bluetooth stack.
public final class PipeInputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buf: [UInt8]
    private var head = 0
    private var size = 0
    private var closed = false

    public init(capacity: Int = 8192) {
        buf = [UInt8](repeating: 0, count: capacity)
    }

    /// Append; returns how many bytes did not fit.
    @discardableResult
    public func offer(_ data: [UInt8]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var dropped = 0
        for b in data {
            if size == buf.count {
                dropped += 1
                continue
            }
            buf[(head + size) % buf.count] = b
            size += 1
        }
        return dropped
    }

    /// Discard everything buffered (the modem changed hands).
    public func clear() {
        lock.lock()
        head = 0
        size = 0
        lock.unlock()
    }

    public var available: Int {
        lock.lock()
        defer { lock.unlock() }
        return size
    }

    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// One byte, or nil when nothing is buffered (never blocks; the driver polls).
    public func read() -> UInt8? {
        lock.lock()
        defer { lock.unlock() }
        guard size > 0 else { return nil }
        let b = buf[head]
        head = (head + 1) % buf.count
        size -= 1
        return b
    }

    /// Up to `max` bytes.
    public func read(max: Int) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        let n = min(max, size)
        var out = [UInt8]()
        out.reserveCapacity(n)
        for _ in 0..<n {
            out.append(buf[head])
            head = (head + 1) % buf.count
        }
        size -= n
        return out
    }

    public func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }
}

/// Bytes the AT driver writes, sent to RX in chunks of the link's size, each one acknowledged
/// before the next. A write is refused unless the phone owns the modem: the node discards bytes
/// from a phone that does not.
public struct PipeOutputChunker: Sendable {
    public let chunkSize: @Sendable () -> Int
    public let canWrite: @Sendable () -> Bool
    public let sendChunk: @Sendable ([UInt8]) async -> Bool

    public init(
        chunkSize: @escaping @Sendable () -> Int, canWrite: @escaping @Sendable () -> Bool,
        sendChunk: @escaping @Sendable ([UInt8]) async -> Bool
    ) {
        self.chunkSize = chunkSize
        self.canWrite = canWrite
        self.sendChunk = sendChunk
    }

    public func write(_ data: [UInt8]) async throws {
        guard !data.isEmpty else { return }
        guard canWrite() else { throw PipeError.notOwned }
        let size = max(chunkSize(), IridiumPipeContract.minChunkBytes)
        var off = 0
        while off < data.count {
            let end = min(off + size, data.count)
            guard await sendChunk(Array(data[off..<end])) else { throw PipeError.writeFailed }
            off = end
        }
    }
}

/// Watches the modem's output for an unsolicited line, "SBDRING" by default: the 9603 sends it
/// in-band when a mobile-terminated message waits (AT+SBDMTA=1). The node has no ring-indicator
/// wire, so this is the only ring alert there is. The match survives a line split across
/// notifications.
public final class LineWatcher: @unchecked Sendable {
    private let token: [UInt8]
    private let onMatch: @Sendable () -> Void
    private let lock = NSLock()
    private var matched = 0

    public init(line: String = "SBDRING", onMatch: @escaping @Sendable () -> Void) {
        token = Array((line + "\r").utf8)
        self.onMatch = onMatch
    }

    public func feed(_ data: [UInt8]) {
        var fire = 0
        lock.lock()
        for b in data {
            if b == token[matched] {
                matched += 1
            } else if b == token[0] {
                matched = 1
            } else {
                matched = 0
            }
            if matched == token.count {
                matched = 0
                fire += 1
            }
        }
        lock.unlock()
        for _ in 0..<fire { onMatch() }
    }
}
