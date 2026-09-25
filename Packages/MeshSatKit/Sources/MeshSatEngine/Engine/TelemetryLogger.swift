// Mirrors engine/TelemetryLogger.kt (MESHSAT-494): crash records, heap samples, health
// heartbeats and events into the telemetry ring buffer, all on the device. The crash file is
// written by the platform's handler and handed in here as text; the heap sample comes from a
// platform closure, since a Linux test has no mach task to ask.
import Foundation
import Logging

public protocol TelemetryStore: Sendable {
    @discardableResult func insert(_ entry: TelemetryEntry) async throws -> Int64
    func trimType(_ type: String, keep: Int) async throws
}

/// A JSON value for a telemetry detail, encoded with sorted keys as Android's BirthSigner does.
public indirect enum TelemetryValue: Sendable, Equatable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null
    case object([String: TelemetryValue])
    case array([TelemetryValue])
}

extension TelemetryValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
}

public enum CanonicalJSON {
    /// {"a":1,"b":"x"} with the keys sorted, no spaces, Go's HTML-safe escapes.
    public static func encode(_ value: TelemetryValue) -> String {
        var out = ""
        write(value, into: &out)
        return out
    }

    public static func encode(_ object: [String: TelemetryValue]) -> String { encode(.object(object)) }

    private static func write(_ value: TelemetryValue, into out: inout String) {
        switch value {
        case .string(let s): out += "\"" + escape(s) + "\""
        case .int(let i): out += String(i)
        case .double(let d):
            if d == d.rounded(), abs(d) < 1e15 {
                out += String(Int64(d))
            } else {
                out += "\(d)"
            }
        case .bool(let b): out += b ? "true" : "false"
        case .null: out += "null"
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case .object(let fields):
            out += "{"
            for (i, key) in fields.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                out += "\"" + escape(key) + "\":"
                write(fields[key] ?? .null, into: &out)
            }
            out += "}"
        }
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "<": out += "\\u003c"
            case ">": out += "\\u003e"
            case "&": out += "\\u0026"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}

public final class TelemetryLogger: @unchecked Sendable {
    public static let maxCrashes = 50
    /// 24 hours at 5 minutes.
    public static let maxHeapSamples = 288
    /// 24 hours at 1 minute.
    public static let maxHealthSamples = 1440
    public static let maxEvents = 1000

    public static let typeCrash = "crash"
    public static let typeHeap = "heap"
    public static let typeHealth = "health"
    public static let typeEvent = "event"

    public static let sevFatal = "fatal"
    public static let sevWarn = "warn"
    public static let sevInfo = "info"
    public static let sevSample = "sample"

    /// The heap figures the platform can give: a one-line summary and the numbers.
    public typealias HeapSampler = @Sendable () -> (message: String, detail: [String: TelemetryValue])

    private static let log = Logger(label: "TelemetryLogger")
    private let store: any TelemetryStore
    private let enabled: @Sendable () async -> Bool
    private let now: @Sendable () -> Int64
    private let heapSampler: HeapSampler
    private let lock = NSLock()
    private var writers: [Task<Void, Never>] = []
    private var lastWriter: Task<Void, Never>?

    public init(
        store: any TelemetryStore, enabled: @escaping @Sendable () async -> Bool = { true },
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        heapSampler: @escaping HeapSampler = { ("heap sample unavailable", [:]) }
    ) {
        self.store = store
        self.enabled = enabled
        self.now = now
        self.heapSampler = heapSampler
    }

    // MARK: Crash recovery

    /// The crash file the handler wrote on the last run, into the table (when telemetry is on).
    public func recoverPendingCrash(_ text: String) async {
        let exception = Self.jsonString(text, "exception")
        let message = Self.jsonString(text, "message")
        let ts = Self.jsonInt(text, "timestamp") ?? now()
        guard await enabled() else {
            Self.log.debug("Telemetry disabled, discarding the pending crash file")
            return
        }
        do {
            try await store.insert(
                TelemetryEntry(
                    timestamp: ts, type: Self.typeCrash, tag: "UncaughtExceptionHandler", severity: Self.sevFatal,
                    message: "\(exception): \(message.prefix(120))", detail: text))
            try await store.trimType(Self.typeCrash, keep: Self.maxCrashes)
            Self.log.info("Recovered pending crash: \(exception)")
        } catch {
            Self.log.warning("Failed to recover pending crash: \(error)")
        }
    }

    static func jsonString(_ json: String, _ key: String) -> String {
        guard let range = json.range(of: "\"\(key)\":\"") else { return "" }
        var out = ""
        var rest = json[range.upperBound...]
        while let c = rest.first {
            rest = rest.dropFirst()
            if c == "\"" { break }
            guard c == "\\", let e = rest.first else {
                out.append(c)
                continue
            }
            rest = rest.dropFirst()
            switch e {
            case "n": out += "\n"
            case "t": out += "\t"
            case "r": out += "\r"
            case "u":
                let hex = rest.prefix(4)
                if hex.count == 4, let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) {
                    out.unicodeScalars.append(scalar)
                    rest = rest.dropFirst(4)
                } else {
                    out += "\\u"
                }
            default: out.append(e)
            }
        }
        return out
    }

    static func jsonInt(_ json: String, _ key: String) -> Int64? {
        guard let range = json.range(of: "\"\(key)\":") else { return nil }
        let digits = json[range.upperBound...].prefix { $0 == "-" || $0.isNumber }
        return Int64(digits)
    }

    // MARK: Samples and events

    /// A heap snapshot; every 5 minutes from the gateway.
    public func recordHeap() {
        fireAndForget(Self.typeHeap) { [heapSampler, now] in
            let sample = heapSampler()
            return TelemetryEntry(
                timestamp: now(), type: Self.typeHeap, tag: "HeapSampler", severity: Self.sevSample, message: sample.message,
                detail: CanonicalJSON.encode(sample.detail))
        }
    }

    /// A health snapshot; every minute from the gateway.
    public func recordHealth(message: String, detail: [String: TelemetryValue]) {
        fireAndForget(Self.typeHealth) { [now] in
            TelemetryEntry(
                timestamp: now(), type: Self.typeHealth, tag: "HealthSampler", severity: Self.sevSample, message: message,
                detail: CanonicalJSON.encode(detail))
        }
    }

    /// A notable event: mode change, key import, burst flush; warn for recoverable trouble.
    public func recordEvent(
        tag: String, message: String, detail: [String: TelemetryValue] = [:], severity: String = TelemetryLogger.sevInfo
    ) {
        fireAndForget(Self.typeEvent) { [now] in
            TelemetryEntry(
                timestamp: now(), type: Self.typeEvent, tag: tag, severity: severity, message: message, detail: CanonicalJSON.encode(detail)
            )
        }
    }

    /// Waits for every write started so far (the tests, and the gateway's stop).
    public func drain() async {
        for task in takeWriters() { await task.value }
    }

    private func takeWriters() -> [Task<Void, Never>] {
        lock.lock()
        defer { lock.unlock() }
        let pending = writers
        writers.removeAll()
        return pending
    }

    private func fireAndForget(_ type: String, _ build: @escaping @Sendable () -> TelemetryEntry) {
        let previous = takeLastWriter()
        let task = Task { [self] in
            // In order: a later record never lands before an earlier one.
            await previous?.value
            guard await enabled() else { return }
            do {
                try await store.insert(build())
                try await store.trimType(type, keep: Self.keep(type))
            } catch {
                Self.log.warning("Telemetry write failed (\(type)): \(error)")
            }
        }
        lock.lock()
        writers = writers.filter { !$0.isCancelled } + [task]
        lastWriter = task
        lock.unlock()
    }

    private func takeLastWriter() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return lastWriter
    }

    static func keep(_ type: String) -> Int {
        switch type {
        case typeCrash: return maxCrashes
        case typeHeap: return maxHeapSamples
        case typeHealth: return maxHealthSamples
        case typeEvent: return maxEvents
        default: return 1000
        }
    }
}
