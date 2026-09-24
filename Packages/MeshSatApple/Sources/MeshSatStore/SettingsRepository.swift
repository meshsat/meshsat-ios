// Mirrors data/SettingsRepository.kt: the settings in a UserDefaults suite under Android's key
// names (MeshSatEngine.SettingsKey), the secrets in the Keychain (SecureKeyStore). Kotlin's
// per-setting Flows are one `changes` broadcast of the key that changed; a screen re-reads
// what it shows, SwiftUI can also bind with @AppStorage on the same suite.
import Foundation
import MeshSatEngine
import MeshSatNet

public final class SettingsRepository: @unchecked Sendable {
    public let defaults: UserDefaults
    public let secure: any KeyValueStore
    /// The key of every setting or secret written, after it was written.
    public let changes = Broadcast<String>(bufferSize: 32)

    public init(defaults: UserDefaults? = nil, secure: any KeyValueStore) {
        self.defaults = defaults ?? UserDefaults(suiteName: MeshSatStore.settingsSuite) ?? .standard
        self.secure = secure
    }

    // MARK: Generic access

    public func get(_ setting: Setting<String>) -> String {
        defaults.string(forKey: setting.key) ?? setting.defaultValue
    }

    public func get(_ setting: Setting<Bool>) -> Bool {
        defaults.object(forKey: setting.key) == nil ? setting.defaultValue : defaults.bool(forKey: setting.key)
    }

    public func set(_ setting: Setting<String>, _ value: String) {
        defaults.set(value, forKey: setting.key)
        changes.send(setting.key)
    }

    public func set(_ setting: Setting<Bool>, _ value: Bool) {
        defaults.set(value, forKey: setting.key)
        changes.send(setting.key)
    }

    public func remove<T>(_ setting: Setting<T>) {
        defaults.removeObject(forKey: setting.key)
        changes.send(setting.key)
    }

    /// A secret, "" when none is stored.
    public func secret(_ key: String) -> String { secure.get(key) ?? "" }

    public func setSecret(_ key: String, _ value: String) {
        secure.set(key, value)
        changes.send(key)
    }

    public func removeSecret(_ key: String) {
        secure.remove(key)
        changes.send(key)
    }

    // MARK: The Kotlin API, where it does more than read a key

    public var encryptionKey: String { secret(SecretKey.encryptionKey) }
    public func setEncryptionKey(_ key: String) { setSecret(SecretKey.encryptionKey, key) }

    /// The MeshSat node to reconnect to at start and after a drop; empty after Disconnect.
    public var meshtasticBleAddress: String { self.get(SettingsKey.meshtasticBleAddress) }
    public func setMeshtasticBleAddress(_ address: String) { set(SettingsKey.meshtasticBleAddress, address) }
    public func clearMeshtasticBleAddress() { remove(SettingsKey.meshtasticBleAddress) }

    public func compressMode(channel: String) -> String {
        guard let s = SettingsKey.compress(channel: channel) else { return "off" }
        return get(s)
    }

    public func setCompressMode(channel: String, _ mode: String) {
        guard let s = SettingsKey.compress(channel: channel) else { return }
        set(s, mode)
    }

    public var mqttPassword: String { secret(SecretKey.mqttPassword) }
    public func setMqttPassword(_ password: String) { setSecret(SecretKey.mqttPassword, password) }
    public var mqttCertPin: String { secret(SecretKey.mqttCertPin) }
    public func setMqttCertPin(_ pin: String) { setSecret(SecretKey.mqttCertPin, pin) }
    public var mqttCertPinBackup: String { secret(SecretKey.mqttCertPinBackup) }
    public func setMqttCertPinBackup(_ pin: String) { setSecret(SecretKey.mqttCertPinBackup, pin) }
    public var hubPassword: String { secret(SecretKey.hubPassword) }
    public func setHubPassword(_ password: String) { setSecret(SecretKey.hubPassword, password) }
    public var hubClientKeyPem: String { secret(SecretKey.hubClientKeyPem) }
    public func setHubClientKeyPem(_ pem: String) { setSecret(SecretKey.hubClientKeyPem, pem) }

    public func setHubRelayTarget(_ bridgeId: String) {
        set(SettingsKey.hubRelayTarget, bridgeId.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func setHubRelayUrl(_ url: String) {
        set(SettingsKey.hubRelayUrl, url.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The people an SOS goes to by SMS (MESHSAT-1249).
    public var sosContacts: [EmergencyContact] { EmergencyContact.decode(self.get(SettingsKey.sosContacts)) }
    public func setSosContacts(_ contacts: [EmergencyContact]) { set(SettingsKey.sosContacts, EmergencyContact.encode(contacts)) }
}
