// Mirrors test hubmsg/HubMsgLiveTest.kt: the phone's Hub app route against the real Hub
// (MESHSAT-1584): two phone identities of one tenant, each the app's own HubReporter (mTLS over wss
// through MqttNioSession, the msg subscriptions, the PUBACK wait) and HubMsgRoute, over a store that
// outlives a restart as the app's database does:
//
//  1. a text and its reply, both read delivered;
//  2. an unknown recipient reads refused;
//  3. the recipient off the Hub, then the sender off the Hub while the completion is published: the
//     Hub's redelivery reaches the recipient once, and the sender's next connect asks again and
//     reads delivered (the session is clean, so the walk is what recovers it).
//
// Skipped unless MESHSAT_HUBMSG_LIVE=1. MESHSAT_HUBMSG_A and MESHSAT_HUBMSG_B are paths to two
// provisioning bundles (the claim's JSON, mode 0600); nothing of them is printed.
import Foundation
import MeshSatMQTT
import MeshSatNet
import XCTest

@testable import MeshSatHub

final class HubMsgLiveTests: XCTestCase {
    /// No position, no modems: a test identity tells the Hub nothing about anyone.
    final class LiveHost: HubReporterHost, @unchecked Sendable {
        func interfaces() -> [InterfaceInfo] { [] }
        func interfaceHealth() -> [InterfaceHealth] { [] }
        func capabilities() -> [String] { ["ios"] }
        func location() -> HubLocation? { nil }
        func batteryPct() -> Double { 0 }
        func memPct() -> Double { 0 }
        func diskPct() -> Double { 0 }
        var appVersion: String { "hubmsg-live" }
        var deviceModel: String { "hubmsg-live" }
    }

    struct Pub: HubMsgRoute.Publisher {
        let reporter: HubReporter
        var principal: String { reporter.principal }
        func isConnected() async -> Bool { await reporter.isConnected }
        func publishMsg(kind: String, payload: String) async -> HubMsgRoute.Published {
            await reporter.publishMsg(kind: kind, payload: payload)
        }
    }

    final class Stored: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ s: String) {
            lock.lock()
            lines.append(s)
            lock.unlock()
        }
        func all() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }

    /// One phone: a provisioned identity, its reporter and route; the store survives stop().
    final class End: @unchecked Sendable {
        let bundle: ProvisionImporter.ProvisionBundle
        let store = MemHubMsgStore()
        let stored = Stored()
        var reporter: HubReporter?
        var route: HubMsgRoute?
        var principal: String { HubMsgWire.principal(bundle.bridgeId) }

        init(_ path: String) throws {
            bundle = try ProvisionImporter.parseBundle(try Data(contentsOf: URL(fileURLWithPath: path)))
        }

        static func session(_ c: HubReporterConfig) -> any MQTTSession {
            var endpoint =
                MqttEndpoint.parse(c.hubUrl, clientId: c.clientId)
                ?? MqttEndpoint(host: c.hubUrl, port: 8883, useTLS: true, useWebSockets: false, clientId: c.clientId)
            endpoint.username = c.username
            endpoint.password = c.password
            endpoint.clientCertPem = c.clientCertPem
            endpoint.clientKeyPem = c.clientKeyPem
            endpoint.caCertPem = c.caCertPem
            return MqttNioSession(endpoint: endpoint)
        }

        func start() {
            let cfg = HubReporterConfig(
                hubUrl: bundle.mqttUrl, bridgeId: bundle.bridgeId, callsign: "hubmsg-live", username: bundle.username,
                password: bundle.password, healthIntervalSec: 300, clientCertPem: bundle.clientCertPem, clientKeyPem: bundle.clientKeyPem,
                caCertPem: bundle.caCertPem, topicPrefix: bundle.topicPrefix)
            let r = HubReporter(config: cfg, host: LiveHost(), makeSession: { Self.session($0) })
            let stored = self.stored
            let rt = HubMsgRoute(store: store, pub: Pub(reporter: r), onStored: { from, text, _ in stored.append("\(from): \(text)") })
            r.setMsgCallbacks(
                onIn: { p in Task { await rt.handleIn(p) } }, onStatus: { p in Task { await rt.handleStatus(p) } },
                onConnected: {
                    rt.onConnected()
                    Task { await rt.pass() }
                })
            reporter = r
            route = rt
            r.start()
        }

        func stop() async {
            await reporter?.stop()
            reporter = nil
            route = nil
        }

        func send(_ to: String, _ text: String) async throws -> Int64 {
            guard let route, case .queued(let id) = try await route.send(to: to, text: text) else {
                throw MemHubMsgStore.TestFailure(description: "not queued")
            }
            return id
        }

        func status(_ id: Int64) -> String { store.row(id)?.forwardedTo ?? "" }
    }

    private func env(_ name: String) throws -> String {
        let v = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespaces) ?? ""
        if v.isEmpty { throw XCTSkip("\(name) not set") }
        return v
    }

    private func until(_ what: String, _ ms: Int, _ ok: () -> Bool) async throws {
        let t0 = Date()
        while !ok() {
            if Date().timeIntervalSince(t0) * 1000 > Double(ms) { throw MemHubMsgStore.TestFailure(description: "timed out: \(what)") }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        print("hubmsg live: \(what) after \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    }

    func testPhoneToPhoneThroughTheRealHubOfflineBothWays() async throws {
        guard ProcessInfo.processInfo.environment["MESHSAT_HUBMSG_LIVE"] == "1" else { throw XCTSkip("MESHSAT_HUBMSG_LIVE is not 1") }
        let a = try End(try env("MESHSAT_HUBMSG_A"))
        let b = try End(try env("MESHSAT_HUBMSG_B"))
        // The gateway's pass, every 2 s here instead of 30 s.
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await a.route?.pass()
                await b.route?.pass()
            }
        }
        defer { ticker.cancel() }
        a.start()
        b.start()
        let ra = try XCTUnwrap(a.reporter)
        let rb = try XCTUnwrap(b.reporter)
        let t0 = Date()
        while true {
            let upA = await ra.isConnected
            let upB = await rb.isConnected
            if upA && upB { break }
            if Date().timeIntervalSince(t0) > 60 { throw MemHubMsgStore.TestFailure(description: "not on the Hub") }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        print("hubmsg live: both on the Hub after \(Int(Date().timeIntervalSince(t0) * 1000)) ms")

        // 1. A text and its reply.
        let run = String(UUID().uuidString.prefix(8)).lowercased()
        let t1 = "hub_msg live ios \(run) one"
        let id1 = try await a.send(b.principal, t1)
        try await until("one delivered", 60_000) { a.status(id1) == HubMsgStatus.delivered }
        try await until("one stored at b", 10_000) { b.stored.all().contains("\(a.principal): \(t1)") }
        let t2 = "hub_msg live ios \(run) reply"
        let id2 = try await b.send(a.principal, t2)
        try await until("reply delivered", 60_000) { b.status(id2) == HubMsgStatus.delivered }
        XCTAssertTrue(a.stored.all().contains("\(b.principal): \(t2)"))

        // 2. An unknown recipient.
        let id3 = try await a.send("bridge:hubmsg-live-nobody-\(run)", "hub_msg live ios \(run) nobody")
        try await until("nobody refused", 60_000) {
            a.status(id3).hasPrefix(HubMsgStatus.refusedPrefix) || a.status(id3).hasPrefix(HubMsgStatus.failedPrefix)
        }
        XCTAssertTrue(a.status(id3).hasSuffix("refused_unknown_recipient"), a.status(id3))

        // 3. The recipient off the Hub; then the sender off it while the completion goes out.
        await b.stop()
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let t4 = "hub_msg live ios \(run) offline"
        let id4 = try await a.send(b.principal, t4)
        try await until("offline one forwarded", 60_000) { a.status(id4) == HubMsgStatus.forwarded }
        await a.stop()
        b.start()
        try await until("offline one stored at b", 240_000) { b.stored.all().contains("\(a.principal): \(t4)") }
        try await Task.sleep(nanoseconds: 10_000_000_000)  // the completion reaches nobody: a is off the Hub
        XCTAssertEqual(HubMsgStatus.forwarded, a.status(id4), "the completion was not missed")
        a.start()  // a fresh route over the same store, as after a restart
        try await until("offline one delivered after a's connect", 90_000) { a.status(id4) == HubMsgStatus.delivered }
        XCTAssertEqual(1, b.stored.all().filter { $0 == "\(a.principal): \(t4)" }.count)
        XCTAssertEqual(1, b.store.rows().filter { $0.direction == "rx" && $0.text == t4 }.count)
        print("hubmsg live: run \(run) passed, a=\(a.principal) b=\(b.principal)")
        await a.stop()
        await b.stop()
    }

    /// A far end for a phone running the app (MESHSAT_HUBMSG_ECHO = seconds): end B answers every
    /// text it stores with "echo: <text>" through the Hub, until the time is up.
    func testAnEchoEndForAPhoneRunningTheApp() async throws {
        let seconds = Int(ProcessInfo.processInfo.environment["MESHSAT_HUBMSG_ECHO"] ?? "") ?? 0
        guard ProcessInfo.processInfo.environment["MESHSAT_HUBMSG_LIVE"] == "1", seconds > 0 else {
            throw XCTSkip("MESHSAT_HUBMSG_ECHO not set")
        }
        let b = try End(try env("MESHSAT_HUBMSG_B"))
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await b.route?.pass()
            }
        }
        defer { ticker.cancel() }
        b.start()
        var answered = 0
        let end = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < end {
            let lines = b.stored.all()
            while answered < lines.count {
                let parts = lines[answered].components(separatedBy: ": ")
                answered += 1
                guard parts.count >= 2 else { continue }
                let id = try await b.send(parts[0], "echo: " + parts.dropFirst().joined(separator: ": "))
                print("hubmsg live: echo to \(parts[0]), row \(id)")
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        for row in b.store.rows() where row.direction == "tx" { print("hubmsg live: echo row to \(row.recipient): \(row.forwardedTo)") }
        await b.stop()
    }
}
