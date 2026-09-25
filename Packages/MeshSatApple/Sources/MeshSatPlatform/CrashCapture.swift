// Mirrors TelemetryLogger.installCrashHandler and recoverPendingCrashes in
// engine/TelemetryLogger.kt (MESHSAT-494): a crash is written as one small JSON file at the
// moment it happens, and read into the telemetry table on the next launch. Android hooks the
// JVM's uncaught exception handler; iOS has Objective-C exceptions (NSSetUncaughtExceptionHandler)
// and the signals a Swift runtime trap raises (SIGTRAP, SIGABRT, SIGILL, SIGSEGV, SIGBUS,
// SIGFPE). The signal handler may only call async-signal-safe functions, so the file's prefix
// is prepared at install time and the handler adds the signal's name with write(2).
import Foundation
import MeshSatEngine

public enum CrashCapture {
    public static let pendingFileName = "pending_crash.json"
    private static let signals: [Int32] = [SIGTRAP, SIGABRT, SIGILL, SIGSEGV, SIGBUS, SIGFPE]
    nonisolated(unsafe) private static var fd: Int32 = -1
    nonisolated(unsafe) private static var prefix: [UInt8] = []
    nonisolated(unsafe) private static var previousHandlers: [Int32: sigaction] = [:]

    /// Where the crash file lives: next to the database, not in Documents (it is not for the user).
    public static func pendingFileURL() -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(pendingFileName)
    }

    /// The previous launch's crash, if any, and the file removed. Call once, before the samplers.
    public static func takePending() -> String? {
        let url = pendingFileURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        // install() leaves an empty, open file behind on every clean run; only a written
        // record is a crash (an empty "crash" was logged on the phone, 25 Sep 2026).
        let text = String(decoding: data, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// Installs the handlers. Call once, from the app delegate's init.
    public static func install(versionName: String, versionCode: String, deviceModel: String, osVersion: String) {
        let url = pendingFileURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The file is opened now and kept open: open(2) is signal-safe but the path lookup is not.
        fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return }
        let head = CanonicalJSON.encode([
            "deviceModel": .string(deviceModel), "osVersion": .string(osVersion), "versionCode": .string(versionCode),
            "versionName": .string(versionName), "thread": "unknown",
        ])
        // The handler completes this with "timestamp", "exception" and "message".
        prefix = Array(head.dropLast().utf8) + Array(",".utf8)
        NSSetUncaughtExceptionHandler { exception in
            let message = "\(exception.name.rawValue): \(exception.reason ?? "")"
            CrashCapture.writeCrash(exception: "NSException", message: message, stack: exception.callStackSymbols.joined(separator: "\n"))
        }
        for sig in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { signal in
                CrashCapture.writeSignal(signal)
                // Then the previous disposition, so the process still dies as it would have.
                CrashCapture.restore(signal)
                raise(signal)
            }
            action.sa_flags = SA_NODEFER
            var previous = sigaction()
            if sigaction(sig, &action, &previous) == 0 { previousHandlers[sig] = previous }
        }
    }

    /// An Objective-C exception: not signal-restricted, so the full record is written.
    private static func writeCrash(exception: String, message: String, stack: String) {
        guard fd >= 0 else { return }
        let tail = CanonicalJSON.encode([
            "timestamp": .int(Int64(Date().timeIntervalSince1970 * 1000)), "exception": .string(exception), "message": .string(message),
            "stack": .string(stack),
        ])
        let bytes = prefix + Array(tail.dropFirst().utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        fsync(fd)
    }

    /// From the signal handler: only write(2) on the open descriptor, no allocation.
    private static func writeSignal(_ signal: Int32) {
        guard fd >= 0 else { return }
        let name: StaticString
        switch signal {
        case SIGTRAP: name = "SIGTRAP"
        case SIGABRT: name = "SIGABRT"
        case SIGILL: name = "SIGILL"
        case SIGSEGV: name = "SIGSEGV"
        case SIGBUS: name = "SIGBUS"
        case SIGFPE: name = "SIGFPE"
        default: name = "SIGNAL"
        }
        var seconds = time(nil)
        _ = prefix.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        writeLiteral("\"exception\":\"")
        name.withUTF8Buffer { _ = write(fd, $0.baseAddress, $0.count) }
        writeLiteral("\",\"message\":\"signal\",\"timestamp\":")
        // Digits by hand: no formatting call is signal-safe.
        var digits: [UInt8] = []
        if seconds <= 0 { digits = [0x30] }
        while seconds > 0 {
            digits.insert(UInt8(0x30 + seconds % 10), at: 0)
            seconds /= 10
        }
        _ = digits.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        writeLiteral("000}")
        fsync(fd)
    }

    private static func writeLiteral(_ s: StaticString) {
        s.withUTF8Buffer { _ = write(fd, $0.baseAddress, $0.count) }
    }

    private static func restore(_ signal: Int32) {
        if var previous = previousHandlers[signal] {
            sigaction(signal, &previous, nil)
        } else {
            var dfl = sigaction()
            dfl.__sigaction_u.__sa_handler = SIG_DFL
            sigaction(signal, &dfl, nil)
        }
    }
}
