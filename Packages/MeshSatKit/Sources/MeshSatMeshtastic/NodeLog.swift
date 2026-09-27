// Mirrors ble/NodeLog.kt (MESHSAT-1374): the node's live log over Bluetooth. Meshtastic streams
// every log line as a LogRecord protobuf on the LogRadio characteristic while
// security.debug_log_api_enabled is set and a phone is subscribed. Platform-free: the wire
// decode, the line format and the buffer have tests here and match Android's.
import Foundation
import MeshSatNet
import MeshSatProto

/// One line of the node's log.
public struct NodeLogLine: Sendable, Equatable {
    /// The node's clock, Unix seconds; 0 when the node has no valid time.
    public let timeSec: Int64
    /// DEBUG, INFO, WARN, ERROR, CRIT, TRACE; nil when the record left it unset.
    public let level: String?
    /// The thread that logged it, e.g. IridiumPipe, BleWatchdog; empty when unknown.
    public let source: String
    public let message: String
    /// When the phone received it, Unix milliseconds: the time shown when `timeSec` is 0.
    public let receivedMs: Int64

    public init(timeSec: Int64, level: String?, source: String, message: String, receivedMs: Int64) {
        self.timeSec = timeSec
        self.level = level
        self.source = source
        self.message = message
        self.receivedMs = receivedMs
    }
}

public enum NodeLog {
    /// Meshtastic's LogRadio characteristic (notify + read), on the Meshtastic service.
    public static let logRadioUUID = MeshtasticBleContract.logRadioUUID
    /// How many lines the buffer keeps; a burst on the node is longer than a screen anyway.
    public static let capacity = 2000

    /// Decode one notified value; nil when it is not a LogRecord.
    public static func parse(_ bytes: [UInt8], receivedMs: Int64) -> NodeLogLine? {
        guard !bytes.isEmpty, let record = try? Meshtastic_LogRecord(serializedBytes: bytes) else { return nil }
        // "\r\n" is one Character in Swift: trim by scalar, as Kotlin's trimEnd does.
        var scalars = record.message.unicodeScalars
        while let last = scalars.last, last == "\r" || last == "\n" { scalars.removeLast() }
        return NodeLogLine(
            timeSec: Int64(record.time), level: levelName(record.level), source: record.source, message: String(scalars),
            receivedMs: receivedMs)
    }

    /// DEBUG, INFO, WARN, ERROR, CRIT, TRACE; nil when unset.
    public static func levelName(_ level: Meshtastic_LogRecord.Level) -> String? {
        switch level {
        case .trace: "TRACE"
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        case .critical: "CRIT"
        case .unset, .UNRECOGNIZED: nil
        }
    }

    /// "HH:mm:ss LEVEL [source] message": the node's time when it has one, else the phone's.
    public static func format(_ line: NodeLogLine, timeZone: TimeZone = .current) -> String {
        let atSec = line.timeSec > 0 ? Double(line.timeSec) : Double(line.receivedMs) / 1000
        let at = Date(timeIntervalSince1970: atSec)
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = timeZone
        clock.dateFormat = "HH:mm:ss"
        var out = clock.string(from: at)
        if let level = line.level { out += " " + level }
        if !line.source.trimmingCharacters(in: .whitespaces).isEmpty { out += " [" + line.source + "]" }
        out += " " + line.message
        return out
    }
}

/// The lines kept for the screen, newest last, at most `capacity`. While paused, new lines are
/// held and appended on resume, so nothing that arrived during a look is lost.
public final class NodeLogBuffer: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var kept: [NodeLogLine] = []
    private var held: [NodeLogLine] = []

    public let lines = StateBroadcast<[NodeLogLine]>([])
    public let paused = StateBroadcast<Bool>(false)

    public init(capacity: Int = NodeLog.capacity) {
        self.capacity = capacity
    }

    public func add(_ line: NodeLogLine) {
        lock.lock()
        if paused.value {
            held.append(line)
            if held.count > capacity { held.removeFirst(held.count - capacity) }
            lock.unlock()
            return
        }
        append(line)
        let snapshot = kept
        lock.unlock()
        lines.send(snapshot)
    }

    public func pause() {
        paused.send(true)
    }

    public func resume() {
        lock.lock()
        paused.send(false)
        for line in held { append(line) }
        held.removeAll()
        let snapshot = kept
        lock.unlock()
        lines.send(snapshot)
    }

    public func clear() {
        lock.lock()
        kept.removeAll()
        held.removeAll()
        lock.unlock()
        lines.send([])
    }

    /// Every kept line, formatted, one per row: what Share and Copy hand over.
    public func text(timeZone: TimeZone = .current) -> String {
        lock.lock()
        let snapshot = kept
        lock.unlock()
        return snapshot.map { NodeLog.format($0, timeZone: timeZone) }.joined(separator: "\n")
    }

    private func append(_ line: NodeLogLine) {
        kept.append(line)
        if kept.count > capacity { kept.removeFirst(kept.count - capacity) }
    }
}
