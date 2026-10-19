// Mirrors sos/SosV2.kt: an SOS under its own identity (HeMB-NG stage 2, C10, MESHSAT-1584). The
// contract is the Hub's docs/bridge-hub-protocol.md "SOS identity (C10)", the shared cases the
// fixture release fixtures-v1.1 (sos.json). While the Hub's retained hub/caps says sos_v2, a run
// keeps a sos_id (a UUIDv7 of its start), the satellite frame is the 0x07, the Hub is told by the v2
// event on this phone's sos/event, published again until the Hub's sos/ack, and the cancel goes
// until its ack, or for a day, on each route that carried the start: the event, and on the
// satellite the 0x08, once the ack has not come within the grace (at once with no Hub session). The
// decisions are here, pure; SosController acts on them.
import Foundation
import MeshSatEngine
import MeshSatWire

public enum SosV2 {
    public static let cap = "sos_v2"
    /// A start or a cancel is published again until its ack: 15 s, doubling to a minute.
    public static let repeatFirstMs: Int64 = 15_000
    public static let repeatMaxMs: Int64 = 60_000
    /// The cancel is followed for a day at most.
    public static let cancelForMs: Int64 = 24 * 3_600_000
    /// With the Hub's session up, the satellite's 0x08 waits this long for the Hub's ack first.
    public static let cancelAckGraceMs: Int64 = 30_000

    /// Whether a hub/caps payload says sos_v2; an empty one (the retained message cleared) does not.
    public static func capsSayV2(_ payload: String) -> Bool {
        guard let o = JSONBody.parse(Data(payload.utf8)), o.int("v") == 1, case .array(let caps)? = o["caps"] else { return false }
        return caps.contains(.string(cap))
    }

    /// The Hub's ack: it has the start or the cancel; state is the run's after it.
    public struct Ack: Sendable, Equatable {
        public let sosId: String
        public let kind: String
        public let state: String
        public let rev: Int64
    }

    public static func parseAck(_ payload: String) -> Ack? {
        guard let o = JSONBody.parse(Data(payload.utf8)), o.int("v") == 2, let id = o.string("sos_id"), !id.isEmpty,
            let kind = o.string("kind"), kind == "start" || kind == "cancel"
        else { return nil }
        return Ack(sosId: id, kind: kind, state: o.string("state") ?? "", rev: o.int("rev") ?? 0)
    }

    /// The run's start as the v2 event: run_start_ms always, the time the run's start in seconds.
    public static func startEvent(_ r: SosRun, text: String) -> JSONBody {
        var o = JSONBody()
        o.put("v", 2)
        o.put("kind", "start")
        o.put("sos_id", r.sosId)
        o.put("run_start_ms", r.id)
        if !r.deviceId.isEmpty { o.put("device_id", r.deviceId) }
        o.put("text", text)
        if let fix = r.fix {
            o.put("lat", fix.lat)
            o.put("lon", fix.lon)
        }
        o.put("timestamp", r.id / 1000)
        return o
    }

    /// The run's cancel as the v2 event, reason 0 (the person), at the time it was cancelled.
    public static func cancelEvent(_ r: SosRun) -> JSONBody {
        var o = JSONBody()
        o.put("v", 2)
        o.put("kind", "cancel")
        o.put("sos_id", r.sosId)
        o.put("run_start_ms", r.id)
        o.put("reason", Int(SosMessages.cancelOperator))
        o.put("timestamp", (r.cancelledAt ?? r.id) / 1000)
        return o
    }

    /// The wait before the next publish after `published` publishes without an ack.
    public static func repeatAfter(_ published: Int) -> Int64 {
        var d = repeatFirstMs
        for _ in 0..<max(published - 1, 0) { d = min(2 * d, repeatMaxMs) }
        return d
    }

    /// The hub leg of r goes as the v2 event now: a real SOS with its id, and the Hub says sos_v2.
    public static func hubLegV2(_ r: SosRun, capsV2: Bool) -> Bool { !r.test && !r.sosId.isEmpty && capsV2 }

    /// The cancel under the run's identity is still owed: not acked, not given up.
    public static func cancelPending(_ r: SosRun) -> Bool {
        r.cancelV2Owed && r.cancelledAt != nil && r.cancelHubAckedAt == nil && !r.cancelGaveUp
    }

    /// A day has passed since the cancel: it is no longer repeated.
    public static func cancelOver(_ r: SosRun, nowMs: Int64) -> Bool {
        guard let at = r.cancelledAt else { return false }
        return nowMs - at >= cancelForMs
    }

    /// The satellite's 0x08 is due: its start went as the 0x07, and the ack has not come in the grace.
    public static func cancelFrameDue(_ r: SosRun, nowMs: Int64, hubUp: Bool, satStartWent: Bool) -> Bool {
        guard let at = r.cancelledAt else { return false }
        return cancelPending(r) && r.satV2 && satStartWent && !r.cancelFrameDone && (!hubUp || nowMs - at >= cancelAckGraceMs)
    }
}
