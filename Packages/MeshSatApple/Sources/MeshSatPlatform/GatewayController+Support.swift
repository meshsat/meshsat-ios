// Mirrors support/SupportReport.kt (MESHSAT-1806, iOS MESHSAT-1810): gathers the texts of the
// debug.zip from the running app: what it is and runs on, the state of every link, the queue's
// counts, the local telemetry (crashes included), the app's own log and the node's log. Nothing here
// sends anything: the zip leaves the phone only through the mail app or share sheet the user picks.
//
// The entry names, their line formats and the zip name are Android's, a contract with paops'
// support-mail parser (PAOPS-81). iOS has no logcat: its `logcat.txt` holds the app's own log
// (AppLog, "HH:mm:ss.SSS LEVL [category] message" in UTC, this launch only).
import CoreBluetooth
import CoreLocation
import Foundation
import MeshSatEngine
import MeshSatMeshtastic
import UserNotifications

#if canImport(UIKit)
import UIKit
#endif

public enum SupportInstall {
    /// Where this build came from, as iOS lets an app tell: the App Store, TestFlight (a sandbox
    /// receipt), or a developer build (no receipt at all).
    public static var source: String {
        guard let receipt = Bundle.main.appStoreReceiptURL else { return "developer build" }
        if receipt.lastPathComponent == "sandboxReceipt" { return "TestFlight" }
        return FileManager.default.fileExists(atPath: receipt.path) ? "App Store" : "developer build"
    }

    /// "App Store edition", "TestFlight build", "developer build": the mail's `--` block.
    public static var edition: String {
        switch source {
        case "App Store": "App Store edition"
        case "TestFlight": "TestFlight build"
        default: "developer build"
        }
    }

    public static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    public static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    /// The hardware identifier (e.g. "iPhone17,3"): iOS gives apps no marketing name.
    public static var device: String {
        var u = utsname()
        uname(&u)
        let raw = withUnsafeBytes(of: &u.machine) { Array($0) }
        return String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// The mail's `--` block.
    public static var about: SupportBundle.About {
        SupportBundle.About(version: version, build: build, edition: edition, ios: ios, device: device)
    }

    public static var ios: String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }
}

extension GatewayController {
    /// The parts of the debug.zip; `withLogs` false leaves the two logs out.
    public func supportParts(withLogs: Bool = true) async -> [SupportBundle.Part] {
        let now = clock.nowMs()
        var parts = [
            SupportBundle.Part(name: "README.txt", text: supportReadme(now))
        ]
        let about = await supportAbout(now)
        let queue = await supportQueue()
        let telemetry = await supportTelemetry()
        parts += [
            SupportBundle.Part(name: "about.txt", text: about),
            SupportBundle.Part(name: "links.txt", text: supportLinks()),
            SupportBundle.Part(name: "queue.txt", text: queue),
            SupportBundle.Part(name: "telemetry.txt", text: telemetry),
        ]
        if withLogs {
            let log = AppLog.shared.recent().joined(separator: "\n")
            parts.append(SupportBundle.Part(name: "logcat.txt", text: log.isEmpty ? "(the app's log is empty)\n" : log + "\n"))
            let node = central.nodeLog.text()
            parts.append(
                SupportBundle.Part(
                    name: "node-log.txt",
                    text: node.isEmpty ? "(the node log is empty: it fills while Setup > Advanced > Node log is open)\n" : node))
        }
        return parts
    }

    /// The zip, written to the caches folder (any older one removed first), and its file.
    public func writeSupportZip() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("support", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = clock.nowMs()
        let file = dir.appendingPathComponent(SupportBundle.fileName(nowMs: now))
        let parts = await supportParts()
        try Data(SupportBundle.bytes(parts, nowMs: now)).write(to: file)
        return file
    }

    private static let supportStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss z"
        return f
    }()

    private func time(_ ms: Int64) -> String {
        ms <= 0 ? "never" : Self.supportStamp.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private func supportReadme(_ now: Int64) -> String {
        """
        MeshSat iOS debug report, made \(time(now)) on the user's request.

        about.txt      the app, the phone, permissions, the node
        links.txt      every way out and its state
        queue.txt      how many messages wait, went out or failed, per link (no message text)
        telemetry.txt  the app's own records: crashes, health and memory samples, events
        logcat.txt     the app's own log since it last started (iOS has no logcat; times in UTC)
        node-log.txt   the node's log, if it was being watched

        Blanked before the zip was written: keys and passwords, email addresses, phone numbers,
        IMEIs, and all but the last byte of Bluetooth and Wi-Fi addresses. The logs can still
        name nodes and contacts and show positions and the times messages were sent.

        """
    }

    private func supportAbout(_ now: Int64) async -> String {
        var out = "Report made: \(time(now))\n"
        out += "App: MeshSat iOS \(SupportInstall.version) (\(SupportInstall.build)), \(SupportInstall.edition), release\n"
        out += "Installed from: \(SupportInstall.source)\n"
        out += "iOS: \(SupportInstall.ios)\n"
        out += "Phone: \(SupportInstall.device)\n"
        out += "Language and time zone: \(Locale.current.identifier), \(TimeZone.current.identifier)\n"
        if let started = Self.processStartedAt {
            out += "App process running for: \(NodeStatsText.duration(UInt32(max(0, Date().timeIntervalSince(started)))))\n"
        }
        out += "Gateway: running\n\n"
        out += "Permissions:\n"
        out += "  Bluetooth: \(Self.bluetoothPermission)\n"
        out += "  Location: \(Self.locationPermission)\n"
        let notifications = await Self.notificationPermission()
        out += "  Notifications: \(notifications)\n\n"
        out += "Node:\n"
        out += "  Bluetooth on this phone: \(central.bluetoothOn.value ? "on" : "off")\n"
        out += "  link: \(central.state.value)\n"
        if let info = central.radio.myInfo.value { out += "  node: \(MeshtasticProtocol.formatNodeId(info.myNodeNum))\n" }
        out += "  nodes heard: \(central.radio.nodes.value.count)\n"
        if let pipe = central.iridiumPipe.value {
            out += "  satellite pipe owner: \(pipe.owner.value.map { String(describing: $0) } ?? "unknown")\n"
            if let flags = pipe.status.value?.flags { out += "  STATUS flags: 0x\(String(flags.rawValue, radix: 16))\n" }
            if let stats = pipe.stats.value { for row in NodeStatsText.rows(stats) { out += "  \(row.label): \(row.value)\n" } }
        } else {
            out += "  satellite pipe: none\n"
        }
        let modem = await driver.state
        out += "9603 driver: \(modem)\n"
        out += "9704 driver: \(imt.state)\n"
        if let hub = hubReporter { out += "Hub: \(hub.state.value)\n" }
        return out
    }

    /// When this process started, from the kernel's process table.
    private static var processStartedAt: Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }

    private static var locationPermission: String {
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways: "allowed always"
        case .denied: "not allowed"
        case .restricted: "restricted"
        case .notDetermined: "not asked yet"
        default: "allowed while the app is in use"
        }
    }

    private static var bluetoothPermission: String {
        switch CBManager.authorization {
        case .allowedAlways: "allowed"
        case .denied: "not allowed"
        case .restricted: "restricted"
        case .notDetermined: "not asked yet"
        @unknown default: "unknown"
        }
    }

    private static func notificationPermission() async -> String {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized: "allowed"
        case .provisional, .ephemeral: "allowed quietly"
        case .denied: "not allowed"
        case .notDetermined: "not asked yet"
        @unknown default: "unknown"
        }
    }

    private func supportLinks() -> String {
        let all = interfaceManager.getAllStatus()
        guard !all.isEmpty else { return "The gateway is not running, so there are no links to show.\n" }
        var out = ""
        for s in all.sorted(by: { $0.id < $1.id }) {
            out += "\(s.id) (\(s.channelType)): \(s.state.rawValue)\n"
            if !s.error.isEmpty { out += "  last error: \(s.error)\n" }
            out +=
                "  last online: \(time(s.lastOnline)), last activity: \(time(s.lastActivity)), reconnect attempts: \(s.reconnectAttempts)\n"
        }
        return out
    }

    private func supportQueue() async -> String {
        let rows: [DeliveryStatRow]
        do {
            rows = try await db.deliveries.stats()
        } catch {
            return "The queue could not be read: \(error)\n"
        }
        guard !rows.isEmpty else { return "The queue is empty.\n" }
        return rows.sorted { ($0.channel, $0.status) < ($1.channel, $1.status) }.map { "\($0.channel)  \($0.status)  \($0.cnt)\n" }.joined()
    }

    private func supportTelemetry() async -> String {
        let rows = await recentTelemetry(limit: 500)
        guard !rows.isEmpty else { return "No telemetry recorded (it may be switched off in Setup).\n" }
        var out = ""
        for t in rows {
            out += "\(time(t.timestamp))  \(t.type)/\(t.severity)  \(t.tag): \(t.message)\n"
            if !t.detail.isEmpty && t.detail != "{}" { out += "  \(t.detail)\n" }
        }
        return out
    }
}
