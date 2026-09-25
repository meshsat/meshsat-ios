// Mirrors tak/TakIntegration.kt: CoT events out, and inbound ones parsed and summarised for the
// message list. Android has two outputs, an ATAK broadcast intent and the MQTT publish to the
// Hub on meshsat/{deviceId}/tak/cot/out. iOS has no ATAK intent (the README says so), so the
// only output is the publisher this is given.
import Foundation

public final class TakIntegration: @unchecked Sendable {
    public typealias Publisher = @Sendable (_ xml: String) async -> Void

    public let deviceId: String
    public let callsign: String
    private let uid: String
    private let publish: Publisher?
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var mqttExportEnabledValue: Bool

    /// `publish` nil means the export is off for good (Android: TAK disabled in the settings).
    public init(
        deviceId: String, callsignPrefix: String = "MESHSAT", mqttExportEnabled: Bool = true, publish: Publisher?,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.deviceId = deviceId
        self.uid = "MESHSAT-\(deviceId)"
        self.callsign = CotBuilder.callsign(deviceId, prefix: callsignPrefix)
        self.mqttExportEnabledValue = mqttExportEnabled
        self.publish = publish
        self.log = log
    }

    public var mqttExportEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mqttExportEnabledValue
    }

    /// The runtime toggle from the settings screen.
    public func updateOutputFlags(mqttExport: Bool) {
        lock.lock()
        mqttExportEnabledValue = mqttExport
        lock.unlock()
    }

    public func sendPosition(lat: Double, lon: Double, alt: Double = 0, course: Double = 0, speed: Double = 0, battery: String = "") async {
        await emit(
            CotBuilder.position(uid: uid, callsign: callsign, lat: lat, lon: lon, alt: alt, course: course, speed: speed, battery: battery))
    }

    public func sendSOS(lat: Double, lon: Double, alt: Double = 0, reason: String = "SOS") async {
        await emit(CotBuilder.sos(uid: uid, callsign: callsign, lat: lat, lon: lon, alt: alt, reason: reason))
        log("SOS CoT event emitted: \(reason)")
    }

    public func sendDeadman(lat: Double, lon: Double, timeoutSec: Int) async {
        await emit(CotBuilder.deadman(uid: uid, callsign: callsign, lat: lat, lon: lon, timeoutSec: timeoutSec))
        log("Dead man CoT event emitted: \(timeoutSec)s timeout")
    }

    public func sendChat(_ text: String) async {
        await emit(CotBuilder.chat(uid: uid, callsign: callsign, text: text))
    }

    public func sendTelemetry(lat: Double, lon: Double, data: String) async {
        await emit(CotBuilder.telemetry(uid: uid, callsign: callsign, lat: lat, lon: lon, data: data))
    }

    public func parseInbound(_ xml: String) -> CotEvent? { CotXml.parse(xml) }

    /// One line for the message list.
    public func formatForDisplay(_ ev: CotEvent) -> String {
        let cs = ev.detail?.contact?.callsign ?? "unknown"
        if ev.type.hasPrefix("a-"), ev.point.lat != 0 {
            return "[TAK:\(cs)] " + String(format: "%.6f,%.6f", ev.point.lat, ev.point.lon)
        }
        if let e = ev.detail?.emergency { return "[TAK:\(cs)] EMERGENCY: \(e.text)" }
        if let r = ev.detail?.remarks { return "[TAK:\(cs)] \(r.text)" }
        return "[TAK:\(cs)] \(ev.type) event"
    }

    /// The topic Android and the Bridge publish on, under the tenant's prefix.
    public static func outTopic(prefix: String, deviceId: String) -> String { "\(prefix)/\(deviceId)/tak/cot/out" }

    private func emit(_ ev: CotEvent) async {
        let xml = CotXml.marshal(ev)
        if mqttExportEnabled, let publish { await publish(xml) }
        log("CoT emitted: type=\(ev.type) uid=\(ev.uid)")
    }
}
