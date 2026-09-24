// The settings as the Setup sections show them (ui/screens/SettingsScreen.kt collects them from
// the DataStore flows): one @Observable mirror of the SettingsRepository, re-read on every
// change it broadcasts, plus the live states the cards need (the Hub client, the modem, the
// node's Iridium pipe).
import Foundation
import MeshSatEngine
import MeshSatHub
import MeshSatMeshtastic
import MeshSatPlatform
import MeshSatStore
import Observation
import SwiftUI

@Observable
@MainActor
public final class SettingsModel {
    public let gateway: GatewayController
    public private(set) var values: [String: String] = [:]
    public private(set) var hubState: HubReporter.State?
    public private(set) var hubLastError = ""
    public private(set) var hubBridgeIdLive = ""
    public private(set) var modemInfo = IridiumATDriver.ModemInfo()
    public private(set) var pipePresent = false
    public private(set) var pipeOwner: IridiumPipeContract.Owner?
    private var tasks: [Task<Void, Never>] = []
    private var hubTasks: [Task<Void, Never>] = []

    public init(gateway: GatewayController) {
        self.gateway = gateway
        reload()
        let settings = gateway.settings
        tasks.append(
            Task { [weak self] in
                for await _ in settings.changes.subscribe() { self?.reload() }
            })
        tasks.append(
            Task { [weak self] in
                for await hub in gateway.hubReporters.subscribe() { self?.followHub(hub) }
            })
        let driver = gateway.driver
        tasks.append(
            Task { [weak self] in
                for await s in driver.stateChanges.subscribe() {
                    let info = await driver.modemInfo
                    self?.modemInfo = s == .connected ? info : IridiumATDriver.ModemInfo()
                }
            })
        let central = gateway.central
        tasks.append(
            Task { [weak self] in
                var ownerTask: Task<Void, Never>?
                for await pipe in central.iridiumPipe.subscribe() {
                    ownerTask?.cancel()
                    self?.pipePresent = pipe != nil
                    self?.pipeOwner = nil
                    guard let pipe else { continue }
                    let stream = pipe.owner.subscribe()
                    ownerTask = Task { [weak self] in
                        for await o in stream { self?.pipeOwner = o }
                    }
                }
            })
    }

    private func followHub(_ hub: HubReporter?) {
        hubTasks.forEach { $0.cancel() }
        hubTasks.removeAll()
        hubBridgeIdLive = hub?.bridgeId ?? ""
        guard let hub else {
            hubState = nil
            hubLastError = ""
            return
        }
        hubTasks.append(
            Task { [weak self] in
                for await s in hub.state.subscribe() { self?.hubState = s }
            })
        hubTasks.append(
            Task { [weak self] in
                for await e in hub.lastError.subscribe() { self?.hubLastError = e }
            })
    }

    /// Every setting the sections read, keyed by Android's key names.
    private func reload() {
        let s = gateway.settings
        var v: [String: String] = [:]
        for key in Self.stringKeys { v[key.key] = s.get(key) }
        for key in Self.boolKeys { v[key.key] = s.get(key) ? "1" : "0" }
        for channel in ["sms", "iridium", "mqtt"] {
            if let k = SettingsKey.compress(channel: channel) { v[k.key] = s.get(k) }
        }
        v[SecretKey.encryptionKey] = s.encryptionKey
        v[SecretKey.hubPassword] = s.hubPassword
        values = v
    }

    static let stringKeys: [Setting<String>] = [
        SettingsKey.meshsatPiPhone, SettingsKey.msvqscStages, SettingsKey.deadmanTimeoutMin, SettingsKey.hubUrl, SettingsKey.hubBridgeId,
        SettingsKey.hubCallsign, SettingsKey.hubUsername, SettingsKey.hubHealthInterval, SettingsKey.hubRelayTarget,
        SettingsKey.hubRelayUrl,
    ]
    static let boolKeys: [Setting<Bool>] = [
        SettingsKey.encryptionEnabled, SettingsKey.autoDecryptSms, SettingsKey.iridiumNodePipeEnabled, SettingsKey.deadmanEnabled,
        SettingsKey.hubEnabled, SettingsKey.hubRelayEnabled, SettingsKey.telemetryEnabled, SettingsKey.startOnBoot,
    ]

    public func string(_ key: Setting<String>) -> String { values[key.key] ?? key.defaultValue }
    public func bool(_ key: Setting<Bool>) -> Bool { (values[key.key] ?? (key.defaultValue ? "1" : "0")) == "1" }
    public func compressMode(_ channel: String) -> String {
        SettingsKey.compress(channel: channel).map { values[$0.key] ?? $0.defaultValue } ?? "off"
    }
    public var encryptionKey: String { values[SecretKey.encryptionKey] ?? "" }
    public var hubPassword: String { values[SecretKey.hubPassword] ?? "" }

    public func set(_ key: Setting<String>, _ value: String) { gateway.settings.set(key, value) }
    public func set(_ key: Setting<Bool>, _ value: Bool) { gateway.settings.set(key, value) }
    public func setCompressMode(_ channel: String, _ mode: String) { gateway.settings.setCompressMode(channel: channel, mode) }
    public func setEncryptionKey(_ key: String) { gateway.settings.setEncryptionKey(key) }
    public func setHubPassword(_ password: String) { gateway.settings.setHubPassword(password) }

    /// A binding onto a bool setting, for the switches.
    public func binding(_ key: Setting<Bool>) -> Binding<Bool> {
        Binding(get: { self.bool(key) }, set: { self.set(key, $0) })
    }

    // MARK: Actions

    public func pollSignal() async -> Int { await gateway.pollSignal() }
    public func checkMailbox() -> Bool { gateway.checkIridiumMailbox() }
    public func pingHub() async -> Int64? { await gateway.pingHub() }
    public func restartGateway() { gateway.restart() }
    public func provisionFromQr(_ url: String) { gateway.provisionClaim.fromQr(url) }
    /// After the Hub settings were typed by hand: the client starts again on them.
    public func restartHub() { Task { await gateway.restartHubReporter() } }
}
