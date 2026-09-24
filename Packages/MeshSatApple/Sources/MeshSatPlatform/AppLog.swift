// Where the app's log lines go on a phone (MESHSAT-1324). swift-log's default handler writes to
// stderr, which on a device outside Xcode reaches nobody, so the first Hub command bug could
// not be read off the phone. Every line now goes to the unified system log (subsystem
// net.meshsat.ios, readable over USB with idevicesyslog or Console), and the most recent lines
// stay in memory for Setup > Diagnostics to show and share. Secrets never go into log lines in
// this codebase, so the messages are marked public (otherwise iOS redacts them as <private>).
import Foundation
import Logging
import os

public final class AppLog: @unchecked Sendable {
    public static let shared = AppLog()
    public static let capacity = 2_000
    private let lock = NSLock()
    private var lines: [String] = []

    /// Once, before anything logs.
    public static func bootstrap(level: Logging.Logger.Level = .info) {
        LoggingSystem.bootstrap { label in
            var h = AppLogHandler(label: label)
            h.logLevel = level
            return h
        }
    }

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        if lines.count > Self.capacity { lines.removeFirst(lines.count - Self.capacity) }
        lock.unlock()
    }

    /// The most recent lines, oldest first.
    public func recent(_ limit: Int = capacity) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(lines.suffix(limit))
    }
}

public struct AppLogHandler: LogHandler {
    public var metadata: Logging.Logger.Metadata = [:]
    public var logLevel: Logging.Logger.Level = .info
    private let label: String
    private let sink: os.Logger
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    public init(label: String) {
        self.label = label
        sink = os.Logger(subsystem: "net.meshsat.ios", category: label)
    }

    public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    // swiftlint:disable:next function_parameter_count
    public func log(
        level: Logging.Logger.Level, message: Logging.Logger.Message, metadata: Logging.Logger.Metadata?, source: String, file: String,
        function: String, line: UInt
    ) {
        let text = message.description
        switch level {
        case .trace, .debug: sink.debug("\(text, privacy: .public)")
        case .info, .notice: sink.info("\(text, privacy: .public)")
        case .warning: sink.warning("\(text, privacy: .public)")
        case .error, .critical: sink.error("\(text, privacy: .public)")
        }
        AppLog.shared.append("\(Self.stamp.string(from: Date())) \(level.rawValue.uppercased().prefix(4)) [\(label)] \(text)")
    }
}
